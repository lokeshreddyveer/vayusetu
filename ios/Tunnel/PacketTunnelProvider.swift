import Foundation
import NetworkExtension
import Network

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var resolverURL: URL?
    private var resolverAddresses: [String] = []
    private var mode: RoutingMode = .vpnFirst
    private var ipv6Blocked = false
    private let policyStore = AppliedPolicyStore()
    private let lifecycle = TunnelLifecycleGate()
    private var dnsFilteringOn = false
    /// Virtual DNS address when the Go filter fronts WireGuard (VayuSetu DNS over a VPN).
    private var filterServer: String?
    private let runtimeLock = NSLock()
    private var localDNS: DNSOnlyRuntime?
    private var dnsRuntime: DNSOnlyRuntime? {
        get { runtimeLock.lock(); defer { runtimeLock.unlock() }; return localDNS }
        set { runtimeLock.lock(); defer { runtimeLock.unlock() }; localDNS = newValue }
    }
    private lazy var adapter = WireGuardAdapter(with: self) { _, _ in
        // Upstream verbose messages can contain endpoint or key material; never persist them.
    }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let token = lifecycle.begin(completionHandler) else { completionHandler(AppIssue(message: "Tunnel startup is already active.")); return }
        DispatchQueue.global(qos: .userInitiated).async {
            var phase = TunnelStartupEvent.Stage.loadingSecret
            TunnelStartupEvent.record(phase)
            do {
                guard let proto = self.protocolConfiguration as? NETunnelProviderProtocol, let ref = proto.passwordReference else { throw AppIssue(message: "No tunnel configuration reference.") }
                let secret = try JSONDecoder().decode(TunnelSecret.self, from: Vault.readReference(ref))
                guard secret.configurationVersion == nil || secret.configurationVersion == 1 else { throw AppIssue(message: "Unsupported tunnel configuration version.") }
                if secret.requireStrictRouting == true {
                    guard proto.includeAllNetworks, RoutingSecurityPolicy.matches(proto, strict: true, allowLAN: false) else { throw AppIssue(message: "Required strict routing policy is missing.") }
                }
                guard secret.mode.supported else { throw AppIssue(message: RoutingMode.directDNSUnavailable) }
                // ADR-011: the local DNS-only runtime owns the tunnel instead of a remote VPN.
                if secret.runtime == "dnsOnly" { try self.startDNSOnly(secret, token: token, phase: &phase); return }
                phase = .validatingProfile; TunnelStartupEvent.record(phase)
                let prepared = try WireGuardConfigPolicy.prepare(secret.wireguard)
                guard secret.requireNativeIPv6 != true || !prepared.blockIPv6 else { throw AppIssue(message: "Native IPv6 is required by this policy.") }
                let config = prepared.configuration
                // VPN Only (applyResolver == false) skips the resolver entirely: the profile's own DNS stays in force.
                let applyResolver = secret.applyResolver != false
                var resolver: URL?
                var addresses: [String] = []
                if applyResolver {
                    phase = .validatingResolver; TunnelStartupEvent.record(phase)
                    let validated = try DNSService.endpoint(secret.resolver)
                    guard let host = validated.host else { throw AppIssue(message: "Resolver hostname is missing.") }
                    resolver = validated
                    phase = .resolverBootstrap; TunnelStartupEvent.record(phase)
                    if let supplied = secret.resolverBootstrapAddresses, !supplied.isEmpty { addresses = try ResolverBootstrap.validated(supplied) }
                    else { addresses = try ResolverBootstrap.resolve(host: host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) }
                }
                // VayuSetu DNS: stage (or clear) the Go-side DNS filter before WireGuard starts; it wraps the tun device.
                let filterOn = applyResolver && secret.filtering == true
                if filterOn, let resolver {
                    guard let rulesPath = DNSRuleStore.url?.path else { throw AppIssue(message: "App Group access is unavailable.") }
                    var settings: [String: Any] = ["rulesPath": rulesPath, "resolver": resolver.absoluteString, "bootstrap": addresses,
                                                   "viaVPN": secret.dnsUpstreamDirect != true, "server": DNSTunnelAddress.server, "filtering": true]
                    if let backup = self.fallback(secret) { settings["fallback"] = backup.url.absoluteString; settings["fallbackBootstrap"] = backup.addresses }
                    let json = String(decoding: try JSONSerialization.data(withJSONObject: settings), as: UTF8.self)
                    guard wgDNSConfigure(json) == 0 else { throw AppIssue(message: "DNS filter configuration was rejected.") }
                } else { _ = wgDNSConfigure(nil) }
                // Stop may arrive while system resolution is blocked. Never enqueue a stale start.
                self.lifecycle.withCurrent(token) {
                    self.dnsFilteringOn = filterOn; self.filterServer = filterOn ? DNSTunnelAddress.server : nil
                    self.resolverURL = resolver; self.resolverAddresses = addresses
                    self.mode = secret.mode; self.ipv6Blocked = prepared.blockIPv6
                    phase = .startingAdapter; TunnelStartupEvent.record(phase)
                    self.adapter.start(tunnelConfiguration: config) { error in
                    if let error { TunnelStartupEvent.record(.startingAdapter, error: error); self.lifecycle.finish(token, error: AppIssue(message: "WireGuard could not start. Check the server profile and tunnel provisioning.")) }
                    else { self.lifecycle.withCurrent(token) { TunnelStartupEvent.record(.established) }; self.lifecycle.finish(token, error: nil) }
                }
                }
            } catch { TunnelStartupEvent.record(phase, error: error); self.lifecycle.finish(token, error: AppIssue(message: "Tunnel setup failed. Check your profile, resolver, Keychain sharing, and Network Extension provisioning.")) }
        }
    }

    /// The optional backup resolver and its bootstrap addresses. A problem with the backup is never allowed to stop the tunnel.
    private func fallback(_ secret: TunnelSecret) -> (url: URL, addresses: [String])? {
        guard let text = secret.fallbackResolver, let url = try? DNSService.endpoint(text), let host = url.host else { return nil }
        let addresses: [String]?
        if let supplied = secret.fallbackBootstrapAddresses, !supplied.isEmpty { addresses = try? ResolverBootstrap.validated(supplied) }
        else { addresses = try? ResolverBootstrap.resolve(host: host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) }
        guard let addresses, !addresses.isEmpty else { return nil }
        return (url, addresses)
    }

    /// Routes only the virtual DNS address into this tunnel; all other traffic keeps its normal path.
    private func startDNSOnly(_ secret: TunnelSecret, token: UUID, phase: inout TunnelStartupEvent.Stage) throws {
        phase = .validatingResolver; TunnelStartupEvent.record(phase)
        let resolver = try DNSService.endpoint(secret.resolver)
        guard let host = resolver.host else { throw AppIssue(message: "Resolver hostname is missing.") }
        phase = .resolverBootstrap; TunnelStartupEvent.record(phase)
        // Resolved before the tunnel exists; afterwards the system resolver is this tunnel itself.
        let addresses: [String]
        if let supplied = secret.resolverBootstrapAddresses, !supplied.isEmpty { addresses = try ResolverBootstrap.validated(supplied) }
        else { addresses = try ResolverBootstrap.resolve(host: host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) }
        // Validated by the same rules as before, then handed to the shared Go client (HTTP/2, DoT, bootstrap dialing).
        _ = try DNSUpstreamConfiguration(endpoint: resolver, addresses: addresses)
        var upstream: any DNSUpstreaming = try GoDNSUpstream(resolver: resolver, bootstrap: addresses)
        if let backup = fallback(secret), let second = try? GoDNSUpstream(resolver: backup.url, bootstrap: backup.addresses) { upstream = FallbackUpstream(primary: upstream, backup: second) }
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: DNSTunnelAddress.interface)
        let ipv4 = NEIPv4Settings(addresses: [DNSTunnelAddress.interface], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: DNSTunnelAddress.server, subnetMask: "255.255.255.255")]
        ipv4.excludedRoutes = []
        settings.ipv4Settings = ipv4; settings.mtu = NSNumber(value: DNSTunnelAddress.mtu)
        let dns = NEDNSSettings(servers: [DNSTunnelAddress.server])
        dns.matchDomains = [""]; dns.matchDomainsNoSearch = true
        settings.dnsSettings = dns
        // Filtering belongs to the VayuSetu DNS provider; other resolvers pass queries through untouched.
        dnsFilteringOn = secret.filtering == true
        let runtime = DNSOnlyRuntime(upstream: upstream, rules: dnsFilteringOn ? DNSRuleStore.load() : nil) { [weak self] packet in
            self?.packetFlow.writePackets([packet], withProtocols: [NSNumber(value: AF_INET)])
        }
        phase = .applyingSettings
        let revision = policyStore.invalidate()
        let started = lifecycle.withCurrent(token) {
            self.resolverURL = resolver; self.resolverAddresses = addresses
            self.dnsRuntime = runtime
            super.setTunnelNetworkSettings(settings) { error in
                if let error {
                    TunnelStartupEvent.record(.applyingSettings, error: error)
                    self.dnsRuntime = nil
                    self.lifecycle.finish(token, error: AppIssue(message: "The local DNS tunnel could not be configured. Check Network Extension provisioning."))
                    return
                }
                TunnelStartupEvent.record(.settingsAccepted)
                // Accepted settings only: the resolver is reached over the upstream, not this record.
                let policy = AppliedTunnelPolicy(version: 1, acceptedAt: Date(), ipv4Default: false, ipv6Default: false, excludedRouteCount: 0, encryptedDNS: false, allDNSDomains: true, ipv6Restricted: false)
                self.lifecycle.withCurrent(token) { self.policyStore.record(policy, revision: revision); TunnelStartupEvent.record(.established) }
                self.pump(runtime)
                self.lifecycle.finish(token, error: nil)
            }
        }
        if !started { throw CancellationError() }
    }
    private func pump(_ runtime: DNSOnlyRuntime) {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self, self.dnsRuntime === runtime else { return }
            for packet in packets { runtime.handle(packet) }
            self.pump(runtime)
        }
    }

    // WireGuard calls this for initial start and path changes, so DNS and routes are reapplied together.
    override func setTunnelNetworkSettings(_ tunnelNetworkSettings: NETunnelNetworkSettings?, completionHandler: ((Error?) -> Void)? = nil) {
        let policyRevision = policyStore.invalidate()
        // Nil is a deliberate withdrawal used by WireGuard during shutdown/path recovery.
        guard tunnelNetworkSettings != nil else { super.setTunnelNetworkSettings(nil, completionHandler: completionHandler); return }
        guard let settingsToken = lifecycle.currentToken, let settings = tunnelNetworkSettings as? NEPacketTunnelNetworkSettings else {
            completionHandler?(AppIssue(message: "Tunnel settings were rejected because startup is inactive or incomplete.")); return
        }
        TunnelStartupEvent.record(.applyingSettings)
        do { try RoutePolicy.apply(to: settings, resolverURL: resolverURL, addresses: resolverAddresses, mode: mode, blockIPv6: ipv6Blocked, filterServer: filterServer) }
        catch { TunnelStartupEvent.record(.applyingSettings, error: error); completionHandler?(error); cancelTunnelWithError(AppIssue(message: "Required tunnel policy could not be applied.")); return }
        let ipv4Default = settings.ipv4Settings?.includedRoutes?.contains { $0.destinationAddress == "0.0.0.0" && $0.destinationSubnetMask == "0.0.0.0" } == true
        let ipv6Default = settings.ipv6Settings?.includedRoutes?.contains { $0.destinationAddress == "::" && $0.destinationNetworkPrefixLength.intValue == 0 } == true
        let excluded = (settings.ipv4Settings?.excludedRoutes?.count ?? 0) + (settings.ipv6Settings?.excludedRoutes?.count ?? 0)
        // With the filter, system DNS is plain but local to the device; the filter's upstream is DoH/DoT by construction.
        let encrypted = settings.dnsSettings is NEDNSOverHTTPSSettings || settings.dnsSettings is NEDNSOverTLSSettings || filterServer != nil
        let resolverFingerprint = filterServer != nil ? resolverURL.flatMap { DNSConfigurationIdentity.fingerprint($0.absoluteString) } : RoutePolicy.resolverFingerprint(from: settings.dnsSettings)
        let allDNS = settings.dnsSettings?.matchDomains == [""] && settings.dnsSettings?.matchDomainsNoSearch == true
        super.setTunnelNetworkSettings(settings) { error in
            TunnelStartupEvent.record(error == nil ? .settingsAccepted : .applyingSettings, error: error)
            if error == nil {
                let policy = AppliedTunnelPolicy(version: 1, acceptedAt: Date(), ipv4Default: ipv4Default, ipv6Default: ipv6Default, excludedRouteCount: excluded, encryptedDNS: encrypted, allDNSDomains: allDNS, ipv6Restricted: self.ipv6Blocked, resolverFingerprint: resolverFingerprint)
                self.lifecycle.withCurrent(settingsToken) { self.policyStore.record(policy, revision: policyRevision) }
            }
            completionHandler?(error)
        }
    }
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        lifecycle.stop {
            policyStore.invalidate(); TunnelStartupEvent.record(.stopped);            if let runtime = dnsRuntime { runtime.stop(); dnsRuntime = nil; completionHandler(); return }
            adapter.stop { _ in completionHandler() }
        }
    }
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard TunnelDiagnosticRequest.supported(messageData), let completionHandler else { completionHandler?(nil); return }
        if let runtime = dnsRuntime {
            // The local DNS tunnel has no WireGuard counters; report only what this runtime observed.
            if TunnelDiagnosticRequest.isReload(messageData), dnsFilteringOn { runtime.replaceRules(DNSRuleStore.load()) }
            var stats = TunnelStats(); stats.resolverAddresses = resolverAddresses; stats.diagnosticVersion = 1
            stats.appliedPolicy = policyStore.snapshot; stats.dnsCounters = runtime.snapshot
            completionHandler(try? JSONEncoder().encode(stats)); return
        }
        if TunnelDiagnosticRequest.isReload(messageData), dnsFilteringOn { wgDNSReload() }
        adapter.getRuntimeConfiguration { config in
            var stats = TunnelStats(); stats.resolverAddresses = self.resolverAddresses; stats.mode = self.mode; stats.ipv6Blocked = self.ipv6Blocked
            stats.diagnosticVersion = 1
            if self.dnsFilteringOn, let raw = wgDNSStats() {
                defer { free(raw) }
                stats.dnsCounters = try? JSONDecoder().decode(DNSOnlyCounters.self, from: Data(String(cString: raw).utf8))
            }
            stats.appliedPolicy = self.policyStore.snapshot
            // Only counters and handshake timestamps cross the IPC boundary, never the raw config or keys.
            for line in (config ?? "").split(separator: "\n") {
                let pair = line.split(separator: "=", maxSplits: 1)
                guard pair.count == 2, let number = UInt64(pair[1]) else { continue }
                if pair[0] == "rx_bytes" { stats.received = stats.received &+ number }
                if pair[0] == "tx_bytes" { stats.sent = stats.sent &+ number }
                if pair[0] == "last_handshake_time_sec", number > 0 {
                    let date = Date(timeIntervalSince1970: TimeInterval(number))
                    if stats.latestHandshake == nil || date > stats.latestHandshake! { stats.latestHandshake = date }
                }
            }
            completionHandler(try? JSONEncoder().encode(stats))
        }
    }
}


/// The Go upstream client behind a Swift interface. Calls block, so they run on a global queue.
final class GoDNSUpstream: DNSUpstreaming, @unchecked Sendable {
    private let handle: Int32
    init(resolver: URL, bootstrap: [String]) throws {
        let settings: [String: Any] = ["resolver": resolver.absoluteString, "bootstrap": bootstrap]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: settings), as: UTF8.self)
        handle = wgDNSUpstreamOpen(json)
        guard handle >= 0 else { throw AppIssue(message: "The encrypted DNS upstream could not be configured.") }
    }
    deinit { wgDNSUpstreamClose(handle) }
    func exchange(_ query: Data) async throws -> Data {
        let handle = self.handle
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var out = [UInt8](repeating: 0, count: DNSPacketCodec.maximumPayload + 64)
                let count = query.withUnsafeBytes { bytes in
                    wgDNSUpstreamExchange(handle, bytes.bindMemory(to: UInt8.self).baseAddress, Int32(query.count), &out, Int32(out.count))
                }
                if count >= 12 {
                    let reply = Data(out[0..<Int(count)])
                    do { try DNSPacketCodec.validateReply(reply, query: query); continuation.resume(returning: reply) }
                    catch { continuation.resume(throwing: error) }
                } else { continuation.resume(throwing: AppIssue(message: count == -2 ? "Upstream reply does not fit the tunnel." : "The encrypted upstream did not answer.")) }
            }
        }
    }
}
