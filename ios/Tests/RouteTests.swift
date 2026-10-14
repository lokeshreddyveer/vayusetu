import Foundation
import NetworkExtension

@main struct RouteTests {
    static var checks = 0
    static func require(_ value: Bool, _ name: String) { guard value else { fatalError("FAIL: \(name)") }; checks += 1 }
    static func settings() -> NEPacketTunnelNetworkSettings {
        let s = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "192.0.2.1")
        s.ipv4Settings = NEIPv4Settings(addresses: ["10.0.0.2"], subnetMasks: ["255.255.255.0"])
        s.ipv6Settings = NEIPv6Settings(addresses: ["fd00::2"], networkPrefixLengths: [64])
        return s
    }
    static func main() throws {
        require(DNSManagementMode.observed(vpnConnected: false, dnsEnabled: nil, foreign: false) == nil, "unreadable DNS never becomes System DNS")
        require(DNSManagementMode.observed(vpnConnected: false, dnsEnabled: false, foreign: true) == nil, "foreign DNS never becomes System DNS")
        require(DNSManagementMode.observed(vpnConnected: true, dnsEnabled: nil, foreign: false) == .vpn, "connected VPN owns DNS mode independently of DNS settings availability")
        require(DNSManagementMode.observed(vpnConnected: false, dnsEnabled: true, foreign: false) == .encrypted, "OS enabled DNS is encrypted mode")
        require(DNSManagementMode.observed(vpnConnected: false, dnsEnabled: false, foreign: false) == .system, "disabled OS DNS is system mode")
        require(!DNSManagementMode.system.needsChange(current: .system, hasSavedDNS: false, resolverMatches: false), "unchanged system mode cannot apply")
        require(!DNSManagementMode.system.needsChange(current: .system, hasSavedDNS: true, resolverMatches: true), "unchanged system selection is disabled even with pending saved DNS")
        require(!DNSManagementMode.encrypted.needsChange(current: .encrypted, hasSavedDNS: true, resolverMatches: true), "same enabled resolver cannot reapply")
        require(DNSManagementMode.encrypted.needsChange(current: .encrypted, hasSavedDNS: true, resolverMatches: false), "changed encrypted resolver can apply")
        require(DNSManagementMode.encrypted.needsChange(current: .system, hasSavedDNS: false, resolverMatches: false), "encrypted DNS can be saved from system mode")
        require(DNSManagementMode.vpn.needsChange(current: .system, hasSavedDNS: false, resolverMatches: false), "VPN selection initiates a connection")
        require(!DNSManagementMode.vpn.needsChange(current: .vpn, hasSavedDNS: false, resolverMatches: false), "already active VPN is not reconnected")
        require(DNSManagementMode.encrypted.needsChange(current: .system, hasSavedDNS: true, resolverMatches: true), "a leftover iOS DNS profile does not block starting the local DNS tunnel")
        require(DNSManagementMode.observed(vpnConnected: true, localDNS: true, dnsEnabled: nil, foreign: false) == .encrypted, "the local DNS tunnel is encrypted mode, not VPN-managed DNS")
        require(DNSManagementMode.allCases.count == 3, "filtering is not a mutually exclusive DNS transport")
        let resolver = try DNSService.endpoint("https://dns.controld.com/test-id")
        let s = settings()
        let addresses = ["76.76.2.1", "2606:1a40::1"]
        try RoutePolicy.apply(to: s, resolverURL: resolver, addresses: addresses, mode: .vpnFirst, blockIPv6: false)
        require(s.ipv4Settings?.includedRoutes?.first?.destinationAddress == "0.0.0.0", "IPv4 default route")
        require(s.ipv6Settings?.includedRoutes?.first?.destinationAddress == "::", "IPv6 default route")
        require(s.ipv4Settings?.excludedRoutes?.isEmpty == true, "no IPv4 resolver bypass")
        require(s.ipv6Settings?.excludedRoutes?.isEmpty == true, "no IPv6 resolver bypass")
        require((s.dnsSettings as? NEDNSOverHTTPSSettings)?.serverURL == resolver, "DoH URL")
        require(s.dnsSettings?.servers == addresses && s.dnsSettings?.matchDomains == [""], "all system DNS uses configured resolver")
        try RoutePolicy.apply(to: s, resolverURL: resolver, addresses: addresses, mode: .vpnFirst, blockIPv6: false)
        require(s.ipv4Settings?.excludedRoutes?.isEmpty == true && s.ipv6Settings?.excludedRoutes?.isEmpty == true, "switching modes clears all resolver bypass routes")
        let originalDNS = s.dnsSettings
        do { try RoutePolicy.apply(to: s, resolverURL: resolver, addresses: addresses, mode: .dnsFirst, blockIPv6: false); fatalError("Unproven DNS-only bypass enabled") } catch { checks += 1 }
        require(s.dnsSettings === originalDNS && s.ipv4Settings?.excludedRoutes?.isEmpty == true, "unsupported mode rejected before network settings mutation")
        require(!RoutingMode.dnsFirst.supported && RoutingMode.vpnFirst.supported, "capability gate")
        let blocked = settings()
        try RoutePolicy.apply(to: blocked, resolverURL: resolver, addresses: addresses, mode: .vpnFirst, blockIPv6: true)
        require(blocked.ipv6Settings?.addresses == ["fd93:3db7:5210::2"] && blocked.ipv6Settings?.includedRoutes?.count == 1, "IPv4-only profile captures IPv6 instead of bypassing VPN")
        do { try RoutePolicy.apply(to: s, resolverURL: resolver, addresses: ["bad-ip"], mode: .dnsFirst, blockIPv6: false); fatalError("Invalid resolver allowed") } catch { checks += 1 }
        do { try RoutePolicy.apply(to: s, resolverURL: resolver, addresses: [], mode: .vpnFirst, blockIPv6: false); fatalError("Empty resolver allowed") } catch { checks += 1 }
        let missingIPv6 = settings(); missingIPv6.ipv6Settings = nil
        do { try RoutePolicy.apply(to: missingIPv6, resolverURL: resolver, addresses: addresses, mode: .vpnFirst, blockIPv6: false); fatalError("Native IPv6 without interface accepted") } catch { checks += 1 }
        require(missingIPv6.dnsSettings == nil, "reject missing IPv6 before mutating DNS")
        require(TunnelDiagnosticRequest.supported(Data([1])) && TunnelDiagnosticRequest.supported(TunnelDiagnosticRequest.statistics), "legacy and versioned statistics commands")
        require(!TunnelDiagnosticRequest.supported(try JSONEncoder().encode(TunnelDiagnosticRequest(version: 2, operation: "statistics"))), "future IPC version rejected")
        require(!TunnelDiagnosticRequest.supported(try JSONEncoder().encode(TunnelDiagnosticRequest(version: 1, operation: "credentials"))), "unknown IPC command rejected")
        require(!TunnelDiagnosticRequest.supported(Data(repeating: 1, count: 257)), "bounded IPC request")
        let policy = AppliedTunnelPolicy(version: 1, acceptedAt: Date(), ipv4Default: true, ipv6Default: true, excludedRouteCount: 0, encryptedDNS: true, allDNSDomains: true, ipv6Restricted: true)
        require(policy.capturesBothFamilies, "full-family accepted policy")
        let policyStore = AppliedPolicyStore()
        var identified = policy
        identified.resolverFingerprint = RoutePolicy.resolverFingerprint(from: s.dnsSettings)
        require(DNSConfigurationIdentity.matchesAccepted(identified, endpoint: resolver.absoluteString), "accepted DNS settings identify the configured DoH endpoint")
        require(!DNSConfigurationIdentity.matchesAccepted(identified, endpoint: "https://dns.controld.com/different-id"), "same provider different personalized endpoint cannot imply applied preference")
        require(!DNSConfigurationIdentity.matchesAccepted(policy, endpoint: resolver.absoluteString), "legacy accepted policy without identity does not prove preferred resolver")
        require(!DNSConfigurationIdentity.matchesAccepted(nil, endpoint: resolver.absoluteString), "missing current policy cannot prove preferred resolver")
        let encodedPolicy = String(decoding: try JSONEncoder().encode(identified), as: UTF8.self)
        require(!encodedPolicy.contains("test-id") && !encodedPolicy.contains("https://"), "accepted identity IPC omits personalized URL and token")
        require(DNSConfigurationIdentity.fingerprint("tls://DNS.EXAMPLE.COM") == DNSConfigurationIdentity.fingerprint("tls://dns.example.com"), "DoT identity normalizes DNS hostname case")
        require(DNSConfigurationIdentity.fingerprint("invalid") == nil, "invalid resolver cannot have accepted identity")
        let decodedPolicy = try JSONDecoder().decode(AppliedTunnelPolicy.self, from: JSONEncoder().encode(policy))
        require(decodedPolicy.resolverFingerprint == nil, "old extension policy decodes without endpoint identity")
        let originalRevision = policyStore.invalidate()
        policyStore.record(policy, revision: originalRevision)
        require(policyStore.snapshot != nil, "accepted callback records current evidence")
        let nextRevision = policyStore.invalidate()
        policyStore.record(policy, revision: originalRevision)
        require(policyStore.snapshot == nil, "late callback cannot revive withdrawn route evidence")
        policyStore.record(policy, revision: nextRevision)
        require(policyStore.snapshot != nil, "current route callback restores evidence")
        let bypass = AppliedTunnelPolicy(version: 1, acceptedAt: Date(), ipv4Default: true, ipv6Default: true, excludedRouteCount: 1, encryptedDNS: true, allDNSDomains: true, ipv6Restricted: true)
        require(!bypass.capturesBothFamilies, "excluded route cannot imply isolation")
        let legacyStats = try JSONDecoder().decode(TunnelStats.self, from: Data("{\"received\":0,\"sent\":0,\"resolverAddresses\":[],\"mode\":\"vpnFirst\",\"ipv6Blocked\":false}".utf8))
        require(legacyStats.appliedPolicy == nil && legacyStats.diagnosticVersion == nil, "legacy stats never create accepted policy evidence")
        let tls = settings()
        try RoutePolicy.apply(to: tls, resolverURL: DNSService.endpoint("tls://dns.example.com"), addresses: addresses, mode: .vpnFirst, blockIPv6: false)
        require((tls.dnsSettings as? NEDNSOverTLSSettings)?.serverName == "dns.example.com", "DoT certificate server name")
        require(tls.dnsSettings?.servers == addresses && tls.dnsSettings?.matchDomains == [""], "DoT captures all system DNS")
        require(tls.ipv4Settings?.excludedRoutes?.isEmpty == true && tls.ipv6Settings?.excludedRoutes?.isEmpty == true, "DoT has no resolver bypass")
        for invalid in ["tls://dns.example.com:853", "tls://dns.example.com/path", "tls://1.1.1.1"] {
            do { _ = try DNSService.endpoint(invalid); fatalError("Invalid TLS endpoint accepted") } catch { checks += 1 }
        }
        let secret = TunnelSecret(wireguard: "sample", resolver: resolver.absoluteString, mode: .dnsFirst)
        let decoded = try JSONDecoder().decode(TunnelSecret.self, from: JSONEncoder().encode(secret))
        require(decoded.mode == .dnsFirst && decoded.resolver == secret.resolver, "Keychain payload encoding")
        require(TunnelStartupEvent.sanitizedDomain("https://secret.example/token") == "OtherErrorDomain", "startup errors redact arbitrary domains")
        require(TunnelStartupEvent.sanitizedDomain("NEVPNErrorDomain") == "NEVPNErrorDomain", "system disconnect domain remains actionable")
        let gate = TunnelLifecycleGate()
        var completions = 0; var wasCancelled = false; var queued: [String] = []
        let first = gate.begin { error in completions += 1; wasCancelled = error is CancellationError }!
        require(gate.begin { _ in fatalError("Duplicate start accepted") } == nil, "duplicate startup rejected")
        gate.stop { queued.append("stop") }
        require(completions == 1 && wasCancelled && !gate.active, "stop cancels pending startup exactly once")
        require(!gate.withCurrent(first) { queued.append("late-start") }, "stopped bootstrap cannot enqueue start")
        gate.finish(first, error: nil)
        require(completions == 1 && queued == ["stop"], "late success cannot revive stopped startup")
        let next = gate.begin { error in require(error == nil, "replacement startup result"); completions += 1 }!
        require(!gate.withCurrent(first) {}, "previous token rejected after replacement")
        require(gate.withCurrent(next) { queued.append("start") }, "current startup queues adapter")
        gate.finish(next, error: nil); gate.finish(next, error: nil)
        require(completions == 2 && gate.active, "success completes once and permits active settings")
        gate.stop { queued.append("stop") }
        require(completions == 2 && queued == ["stop", "start", "stop"], "adapter stop follows queued start")
        let failed = gate.begin { _ in completions += 1 }!
        gate.finish(failed, error: AppIssue(message: "test"))
        require(!gate.active && !gate.withCurrent(failed) {}, "failed startup cannot apply settings")
        for address in ["0.0.0.0", "127.0.0.1", "224.0.0.1", "255.255.255.255", "169.254.1.2", "::", "::1", "ff02::1", "fe80::1", "fe80::1%en0", "::ffff:127.0.0.1", "::ffff:0.0.0.0", "::192.0.2.1", "bad"] {
            require(!ResolverBootstrap.usable(address), "unusable bootstrap rejected: \(address)")
        }
        require(ResolverBootstrap.usable("10.0.0.53") && ResolverBootstrap.usable("fd00::53"), "explicit private resolver addresses supported")
        let deduplicated = try ResolverBootstrap.validated(["1.1.1.1", "1.1.1.1"]); require(deduplicated == ["1.1.1.1"], "bootstrap duplicate removed")
        for addresses in [[], Array(repeating: "1.1.1.1", count: 9), ["::1"]] {
            do { _ = try ResolverBootstrap.validated(addresses); fatalError("Unsafe bootstrap accepted") } catch { checks += 1 }
        }
        let literal = try ResolverBootstrap.resolve(host: "1.1.1.1", lookup: { _ in fatalError("Literal caused DNS lookup") }); require(literal == ["1.1.1.1"], "literal skips system resolution")
        let dual = try ResolverBootstrap.resolve(host: "resolver.test", lookup: { _ in ["1.1.1.1", "2606:4700:4700::1111"] }); require(dual.count == 2, "bootstrap keeps both families")
        let began = Date()
        do { _ = try ResolverBootstrap.resolve(host: "slow.test", timeout: 0.02, lookup: { _ in Thread.sleep(forTimeInterval: 0.2); return ["1.1.1.1"] }); fatalError("Unbounded lookup") } catch { checks += 1 }
        require(Date().timeIntervalSince(began) < 0.15, "bootstrap timeout bounds startup wait")
        do { _ = try ResolverBootstrap.resolve(host: "blocked.test", lookup: { _ in ["0.0.0.0"] }); fatalError("Sinkhole accepted") } catch { checks += 1 }
        do { _ = try ResolverBootstrap.resolve(host: "failure.test", lookup: { _ in throw AppIssue(message: "test") }); fatalError("Lookup error ignored") } catch { checks += 1 }
        let strictSecret = TunnelSecret(wireguard: "test", resolver: resolver.absoluteString, mode: .vpnFirst, resolverBootstrapAddresses: ["1.1.1.1"], requireStrictRouting: true)
        let strictDecoded = try JSONDecoder().decode(TunnelSecret.self, from: JSONEncoder().encode(strictSecret))
        require(strictDecoded.requireStrictRouting == true && strictDecoded.resolverBootstrapAddresses == ["1.1.1.1"], "extension receives strict policy and bootstrap addresses")
        let legacySecret = try JSONDecoder().decode(TunnelSecret.self, from: Data("{\"wireguard\":\"test\",\"resolver\":\"https://dns.example.com/query\",\"mode\":\"vpnFirst\"}".utf8))
        require(legacySecret.requireStrictRouting == nil && legacySecret.resolverBootstrapAddresses == nil, "legacy secret remains readable without inferred strict policy")
        let proto = NETunnelProviderProtocol(); RoutingSecurityPolicy.apply(to: proto, strict: true, allowLAN: true)
        require(RoutingSecurityPolicy.matches(proto, strict: true, allowLAN: true) && !proto.excludeLocalNetworks, "strict policy overrides LAN bypass preference")
        proto.excludeLocalNetworks = true
        require(!RoutingSecurityPolicy.matches(proto, strict: true, allowLAN: true), "saved LAN policy mismatch rejected")
        RoutingSecurityPolicy.apply(to: proto, strict: false, allowLAN: true)
        require(RoutingSecurityPolicy.matches(proto, strict: false, allowLAN: true), "custom LAN preference preserved")
        let connect = NEOnDemandRuleConnect(); connect.interfaceTypeMatch = .any
        require(RoutingSecurityPolicy.matchesOnDemand([connect], enabled: true), "any-interface recovery accepted")
        connect.ssidMatch = ["Home"]
        require(!RoutingSecurityPolicy.matchesOnDemand([connect], enabled: true), "conditional recovery rejected as all-network policy")
        let everywhere = NEOnDemandRuleConnect(); everywhere.interfaceTypeMatch = .any
        let off = NEOnDemandRuleDisconnect(); off.interfaceTypeMatch = .wiFi; off.ssidMatch = ["Home"]
        require(RoutingSecurityPolicy.matchesOnDemand([off, everywhere], enabled: true, trusted: ["Home"]), "trusted Wi-Fi: disconnect on the named network, connect elsewhere")
        require(!RoutingSecurityPolicy.matchesOnDemand([everywhere], enabled: true, trusted: ["Home"]), "trusted names requested but not saved is rejected")
        require(!RoutingSecurityPolicy.matchesOnDemand([off, everywhere], enabled: true, trusted: ["Office"]), "different trusted names are rejected")
        require(!RoutingSecurityPolicy.matchesOnDemand([off, everywhere], enabled: true), "saved trusted rule without a trusted list is rejected")
        require(TrustedNetworks.normalized([" Home ", "Home", "", "Office"]) == ["Home", "Office"], "names are trimmed and de-duplicated")
        require(TrustedNetworks.active(strict: true).isEmpty, "Privacy Lock overrides trusted networks")
        require(!RoutingSecurityPolicy.matchesOnDemand([], enabled: true) && RoutingSecurityPolicy.matchesOnDemand([], enabled: false), "missing recovery rule detected")
        require(VPNActivationRecovery.shouldReload(NSError(domain: NEVPNErrorDomain, code: NEVPNError.configurationInvalid.rawValue), retries: 0), "invalid registration can reload")
        require(VPNActivationRecovery.shouldReload(NSError(domain: NEVPNErrorDomain, code: NEVPNError.configurationStale.rawValue), retries: 1), "stale registration can reload")
        require(!VPNActivationRecovery.shouldReload(NSError(domain: NEVPNErrorDomain, code: NEVPNError.configurationInvalid.rawValue), retries: 2), "registration recovery bounded")
        require(!VPNActivationRecovery.shouldReload(NSError(domain: NEVPNErrorDomain, code: NEVPNError.configurationReadWriteFailed.rawValue), retries: 0), "write failure is not activation recovery")
        require(!VPNActivationRecovery.shouldReload(NSError(domain: NSURLErrorDomain, code: 1), retries: 0), "unrelated error is not registration recovery")
        let configuredDNS = URL(string: "https://dns.example.com/first-profile")!
        require(DNSConfigurationIdentity.matches(endpoint: configuredDNS.absoluteString, httpsURL: configuredDNS, tlsServerName: nil), "configured DoH identity matches exact preference")
        require(!DNSConfigurationIdentity.matches(endpoint: "https://dns.example.com/other-profile", httpsURL: configuredDNS, tlsServerName: nil), "same provider with another account path does not match")
        require(!DNSConfigurationIdentity.matches(endpoint: "https://other.example.com/first-profile", httpsURL: configuredDNS, tlsServerName: nil), "different configured provider does not match")
        require(DNSConfigurationIdentity.matches(endpoint: "tls://dns.example.com", httpsURL: nil, tlsServerName: "DNS.EXAMPLE.COM"), "DoT configured hostname comparison ignores case")
        require(!DNSConfigurationIdentity.matches(endpoint: "https://dns.example.com/query", httpsURL: nil, tlsServerName: "dns.example.com"), "matching hostname does not confuse DoH and DoT")
        require(!DNSConfigurationIdentity.matches(endpoint: "not a resolver", httpsURL: configuredDNS, tlsServerName: nil), "invalid preference has no configuration evidence")
        require(!DNSConfigurationIdentity.matches(endpoint: configuredDNS.absoluteString, httpsURL: nil, tlsServerName: nil), "missing configuration cannot match a saved preference")
        require(IndependentDNSResumePolicy.shouldRestore(desired: true, suspended: true, saved: false, foreign: false, observationKnown: true, vpnSettledOff: true, operationPending: false), "suspended independent DNS restores after VPN")
        for variant in 0..<7 {
            require(!IndependentDNSResumePolicy.shouldRestore(desired: variant == 0 ? false : variant == 1 ? nil : true,
                suspended: variant != 2, saved: variant == 3, foreign: variant == 4,
                observationKnown: variant != 5, vpnSettledOff: true, operationPending: variant == 6), "resume rejects missing intent, snapshot, known observation, conflict or active operation")
        }
        require(!IndependentDNSResumePolicy.shouldRestore(desired: true, suspended: true, saved: false, foreign: false, observationKnown: true, vpnSettledOff: false, operationPending: false), "never restore into an active or unsettled VPN")
        print("Passed \(checks) routing checks. These validate configuration, not live packet paths.")
    }
}
