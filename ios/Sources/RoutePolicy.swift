import Foundation
import Network
import NetworkExtension
import Security

enum RoutePolicy {
    static func resolverFingerprint(from settings: NEDNSSettings?) -> String? {
        if let doh = settings as? NEDNSOverHTTPSSettings, let url = doh.serverURL { return DNSConfigurationIdentity.fingerprint(url.absoluteString) }
        if let dot = settings as? NEDNSOverTLSSettings, let host = dot.serverName { return DNSConfigurationIdentity.fingerprint("tls://" + host.lowercased()) }
        return nil
    }

    /// `filterServer`: the virtual in-tunnel DNS address answered by the Go DNS filter (VayuSetu DNS). System DNS then
    /// talks plain DNS to that address, which never leaves the device; the filter forwards over DoH/DoT.
    static func apply(to settings: NEPacketTunnelNetworkSettings, resolverURL: URL?, addresses: [String], mode: RoutingMode, blockIPv6: Bool, filterServer: String? = nil) throws {
        guard mode.supported else { throw AppIssue(message: RoutingMode.directDNSUnavailable) }
        guard settings.ipv4Settings != nil else { throw AppIssue(message: "IPv4 tunnel settings are required.") }
        guard blockIPv6 || settings.ipv6Settings != nil else {
            throw AppIssue(message: "Native IPv6 policy requires IPv6 tunnel settings.")
        }
        // VPN Only passes no resolver: the DNS settings WireGuard derived from the imported profile stay exactly as they are.
        if let resolverURL {
            guard !addresses.isEmpty, addresses.count <= 8, addresses.allSatisfy({ ResolverBootstrap.usable($0) }) else {
                throw AppIssue(message: "Resolver addresses are required.")
            }
            let validated = try DNSService.endpoint(resolverURL.absoluteString)
            let dns: NEDNSSettings
            if let filterServer {
                dns = NEDNSSettings(servers: [filterServer])
            } else if validated.scheme?.lowercased() == "tls" {
                let tls = NEDNSOverTLSSettings(servers: addresses); tls.serverName = validated.host; dns = tls
            } else {
                let https = NEDNSOverHTTPSSettings(servers: addresses); https.serverURL = validated; dns = https
            }
            dns.matchDomains = [""]; dns.matchDomainsNoSearch = true
            settings.dnsSettings = dns
        }
        settings.ipv4Settings?.includedRoutes = [NEIPv4Route.default()]
        if blockIPv6 {
            // Capture IPv6. WireGuard drops it if the provider profile has no matching AllowedIPs.
            settings.ipv6Settings = NEIPv6Settings(addresses: ["fd93:3db7:5210::2"], networkPrefixLengths: [128])
        }
        settings.ipv6Settings?.includedRoutes = [NEIPv6Route.default()]
        // No resolver-IP bypass: an IP exception would permit arbitrary traffic to bypass.
        settings.ipv4Settings?.excludedRoutes = []
        settings.ipv6Settings?.excludedRoutes = []
    }
}

/// Provider addresses avoid a pre-tunnel system DNS lookup. They never add excluded routes.
enum ResolverBootstrap {
    private static let workers = DispatchSemaphore(value: 2)
    static func validated(_ addresses: [String]) throws -> [String] {
        guard !addresses.isEmpty, addresses.count <= 8 else { throw AppIssue(message: "Use between 1 and 8 resolver bootstrap addresses.") }
        var result: [String] = []
        for address in addresses {
            guard usable(address) else { throw AppIssue(message: "Resolver bootstrap requires usable, unscoped IPv4 or IPv6 addresses.") }
            if !result.contains(address) { result.append(address) }
        }
        return result
    }
    static func usable(_ address: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            return withUnsafeBytes(of: v4) { b in b[0] != 0 && b[0] != 127 && b[0] < 224 && !(b[0] == 169 && b[1] == 254) }
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, address, &v6) == 1 else { return false }
        return withUnsafeBytes(of: v6) { b in
            if b.allSatisfy({ $0 == 0 }) || (b.prefix(15).allSatisfy({ $0 == 0 }) && b[15] == 1) { return false }
            if b[0] == 255 || (b[0] == 254 && b[1] & 0xc0 == 0x80) { return false }
            if b.prefix(10).allSatisfy({ $0 == 0 }) && b[10] == 255 && b[11] == 255 {
                return b[12] != 0 && b[12] != 127 && b[12] < 224 && !(b[12] == 169 && b[13] == 254)
            }
            // Deprecated IPv4-compatible addresses have ambiguous routing semantics.
            return !b.prefix(12).allSatisfy({ $0 == 0 })
        }
    }
    static func resolve(host: String, timeout: TimeInterval = 5, lookup: @escaping (String) throws -> [String] = systemLookup) throws -> [String] {
        guard timeout > 0, timeout <= 10, !host.isEmpty, host.utf8.count <= 253 else { throw AppIssue(message: "Invalid resolver bootstrap request.") }
        if ProfileParser.ipFamily(host) != nil { return try validated([host]) }
        guard workers.wait(timeout: .now()) == .success else { throw AppIssue(message: "Resolver bootstrap is busy. Retry shortly.") }
        let state = BootstrapResult()
        DispatchQueue.global(qos: .utility).async {
            defer { workers.signal() }
            let value = Result { try validated(lookup(host)) }
            state.condition.lock(); state.value = value; state.condition.broadcast(); state.condition.unlock()
        }
        let deadline = Date().addingTimeInterval(timeout)
        state.condition.lock(); defer { state.condition.unlock() }
        while state.value == nil {
            if !state.condition.wait(until: deadline), state.value == nil { throw AppIssue(message: "Resolver bootstrap timed out. Use your provider’s bootstrap addresses or retry.") }
        }
        guard let result = state.value else { throw AppIssue(message: "Resolver bootstrap finished without a result.") }
        return try result.get()
    }
    private final class BootstrapResult {
        let condition = NSCondition()
        var value: Result<[String], Error>?
    }

    // MARK: Resolution that survives a network that is still settling
    // A tunnel is often asked to start in the moment the network is changing (right after another tunnel stopped, on a wake, on a Wi‑Fi switch). One
    // five-second lookup then fails the whole start. This tries a bounded number of times with growing pauses and checks the network path between
    // tries, and only as a last step reuses addresses this process resolved earlier, while they are still recent.
    struct RetryPolicy {
        var attemptTimeout: TimeInterval = 3
        var delays: [TimeInterval] = [0.5, 1, 2]                 // pause before the 2nd, 3rd and 4th try: the whole wait is at most about 16 s
        var maximumCacheAge: TimeInterval = 6 * 3600
        var attempts: Int { delays.count + 1 }
    }
    enum Source: Equatable { case live(attempt: Int), cached(age: TimeInterval) }
    /// Addresses a host resolved to earlier in this process. Only used after live lookups failed, only while recent, and always re-validated.
    final class Cache {
        private let lock = NSLock(); private var entries: [String: (addresses: [String], date: Date)] = [:]
        func store(_ host: String, _ addresses: [String], at date: Date) { lock.lock(); entries[host.lowercased()] = (addresses, date); lock.unlock() }
        func recent(_ host: String, now: Date, maximumAge: TimeInterval) -> (addresses: [String], age: TimeInterval)? {
            lock.lock(); defer { lock.unlock() }
            guard let entry = entries[host.lowercased()] else { return nil }
            let age = now.timeIntervalSince(entry.date)
            guard age >= 0, age <= maximumAge, let checked = try? validated(entry.addresses) else { return nil }
            return (checked, age)
        }
        func clear() { lock.lock(); entries = [:]; lock.unlock() }
    }
    static let sharedCache = Cache()

    /// Whether the system currently reports a usable network path. A short-lived monitor; when it does not answer in time the answer is "yes", because
    /// the lookup itself is the real test and a missing answer must not block a start.
    static func networkPathSatisfied() -> Bool {
        final class Box: @unchecked Sendable { let lock = NSLock(); var value = true }
        let box = Box(), monitor = NWPathMonitor(), answered = DispatchSemaphore(value: 0)
        monitor.pathUpdateHandler = { path in box.lock.lock(); box.value = path.status == .satisfied; box.lock.unlock(); answered.signal() }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        let got = answered.wait(timeout: .now() + 0.5) == .success
        monitor.cancel()
        box.lock.lock(); defer { box.lock.unlock() }
        return got ? box.value : true
    }

    static func resolveResilient(host: String, policy: RetryPolicy = RetryPolicy(), cache: Cache = sharedCache, now: () -> Date = Date.init,
                                 lookup: @escaping (String) throws -> [String] = systemLookup, pathSatisfied: () -> Bool = networkPathSatisfied,
                                 pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) throws -> (addresses: [String], source: Source) {
        if ProfileParser.ipFamily(host) != nil { return (try validated([host]), .live(attempt: 1)) }
        var lastIssue = "no answer"; var pathWasDown = false
        for attempt in 1...policy.attempts {
            if attempt > 1 {
                pause(policy.delays[attempt - 2])
                // Give the path one more short chance to come back before spending a lookup on it.
                var waited = 0.0
                while !pathSatisfied() && waited < policy.attemptTimeout { pathWasDown = true; pause(0.25); waited += 0.25 }
            }
            do {
                let found = try resolve(host: host, timeout: policy.attemptTimeout, lookup: lookup)
                cache.store(host, found, at: now())
                return (found, .live(attempt: attempt))
            } catch { lastIssue = (error as? AppIssue)?.message ?? "lookup failed" }
        }
        if let kept = cache.recent(host, now: now(), maximumAge: policy.maximumCacheAge) { return (kept.addresses, .cached(age: kept.age)) }
        throw AppIssue(message: "Resolver bootstrap failed after \(policy.attempts) tries" + (pathWasDown ? " while the network was unavailable" : "") + " (\(lastIssue)) and no recent addresses are saved. Add the provider’s bootstrap addresses, or retry when the network is steady.")
    }
    private static func systemLookup(_ host: String) throws -> [String] {
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM; hints.ai_flags = AI_ADDRCONFIG
        var head: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &head) == 0, let first = head else { throw AppIssue(message: "Resolver bootstrap resolution failed.") }
        defer { freeaddrinfo(first) }
        var values = Set<String>(); var current: UnsafeMutablePointer<addrinfo>? = first
        while let item = current {
            var address = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(item.pointee.ai_addr, item.pointee.ai_addrlen, &address, socklen_t(address.count), nil, 0, NI_NUMERICHOST) == 0 {
                let value = String(cString: address)
                if usable(value) { values.insert(value) }
            }
            current = item.pointee.ai_next
        }
        // Bound multihomed answers after validation, preserving both address families.
        return Array(values.sorted().prefix(8))
    }
}

enum RoutingSecurityPolicy {
    static func apply(to proto: NEVPNProtocol, strict: Bool, allowLAN: Bool) {
        // Apple's APIs treat includeAllNetworks and enforceRoutes as mutually exclusive.
        // Include-all is configured by the caller before this policy is applied.
        proto.enforceRoutes = !proto.includeAllNetworks; proto.excludeLocalNetworks = !strict && allowLAN
        if #available(iOS 16.4, macOS 13.3, *) {
            proto.excludeAPNs = !strict; proto.excludeCellularServices = !strict
        }
        if #available(iOS 17.4, macOS 14.4, *) {
            #if DEBUG
            proto.excludeDeviceCommunication = true // Preserve the real-device debugging transport.
            #else
            proto.excludeDeviceCommunication = !strict
            #endif
        }
    }
    static func matches(_ proto: NEVPNProtocol, strict: Bool, allowLAN: Bool) -> Bool {
        guard proto.enforceRoutes == !proto.includeAllNetworks,
              proto.excludeLocalNetworks == (!strict && allowLAN) else { return false }
        if #available(iOS 16.4, macOS 13.3, *) {
            guard proto.excludeAPNs == !strict, proto.excludeCellularServices == !strict else { return false }
        }
        if #available(iOS 17.4, macOS 14.4, *) {
            #if DEBUG
            guard proto.excludeDeviceCommunication else { return false }
            #else
            guard proto.excludeDeviceCommunication == !strict else { return false }
            #endif
        }
        return true
    }
    static func matchesOnDemand(_ rules: [NEOnDemandRule]?, enabled: Bool, trusted: [String] = []) -> Bool {
        if !enabled { return rules?.isEmpty != false }
        if !trusted.isEmpty {
            // Disconnect on the trusted Wi-Fi names, connect everywhere else.
            guard let rules, rules.count == 2, let off = rules[0] as? NEOnDemandRuleDisconnect, let on = rules[1] as? NEOnDemandRuleConnect else { return false }
            return off.interfaceTypeMatch == .wiFi && Set(off.ssidMatch ?? []) == Set(trusted) && off.dnsSearchDomainMatch == nil && off.dnsServerAddressMatch == nil && off.probeURL == nil
                && matchesOnDemand([on], enabled: true)
        }
        guard let rules, rules.count == 1, let rule = rules.first as? NEOnDemandRuleConnect else { return false }
        return rule.interfaceTypeMatch == .any && rule.dnsSearchDomainMatch == nil && rule.dnsServerAddressMatch == nil && rule.ssidMatch == nil && rule.probeURL == nil
    }
}

/// Maps validated configuration onto Apple's native IKEv2 engine; it never starts a VPN.
enum NativeIKEProtocolBuilder {
    static func build(_ draft: ManualVPNDraft, passwordReference: Data?, strict: Bool, allowLAN: Bool) throws -> NEVPNProtocolIKEv2 {
        guard draft.protocolKind == .ikev2 else { throw AppIssue(message: "Only IKEv2 can use the native adapter.") }
        try draft.validate()
        let proto = NEVPNProtocolIKEv2()
        proto.serverAddress = draft.server; proto.remoteIdentifier = draft.remoteIdentifier
        proto.localIdentifier = draft.localIdentifier.isEmpty ? nil : draft.localIdentifier
        proto.disconnectOnSleep = false; proto.deadPeerDetectionRate = .medium
        if draft.authentication == "Username & Password" {
            guard let passwordReference, !passwordReference.isEmpty else { throw AppIssue(message: "IKEv2 requires a persistent Keychain password reference.") }
            proto.authenticationMethod = .none; proto.useExtendedAuthentication = true
            proto.username = draft.username; proto.passwordReference = passwordReference
        } else {
            #if os(iOS)
            guard let data = Data(base64Encoded: draft.identityBase64.filter { !$0.isWhitespace }) else { throw AppIssue(message: "Invalid PKCS#12 identity encoding.") }
            var items: CFArray?
            let result = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: draft.identityPassword] as CFDictionary, &items)
            guard result == errSecSuccess, let entries = items as? [[String: Any]], entries.first?[kSecImportItemIdentity as String] != nil else { throw AppIssue(message: "The PKCS#12 identity could not be opened. Check its password and certificate.") }
            proto.authenticationMethod = .certificate; proto.useExtendedAuthentication = false
            proto.identityData = data; proto.identityDataPassword = draft.identityPassword
            #else
            throw AppIssue(message: "Certificate-based native IKEv2 on macOS requires a Keychain identity reference.")
            #endif
        }
        proto.includeAllNetworks = strict
        RoutingSecurityPolicy.apply(to: proto, strict: strict, allowLAN: allowLAN)
        return proto
    }
}

/// Only registration-invalid/stale start errors are candidates for a bounded reload.
enum VPNActivationRecovery {
    static func shouldReload(_ error: NSError, retries: Int) -> Bool {
        error.domain == NEVPNErrorDomain && retries < 2 &&
            [NEVPNError.configurationInvalid.rawValue, NEVPNError.configurationStale.rawValue].contains(error.code)
    }
}

/// Wi-Fi networks where the VPN stays off, because the network is already yours (home, office). Applies only when Privacy Lock is off:
/// Privacy Lock means "never unprotected", which a trusted-network exception would contradict.
enum TrustedNetworks {
    static let key = "trusted-wifi"
    static let limit = 20
    static var saved: [String] { normalized(UserDefaults.standard.stringArray(forKey: key) ?? []) }
    static func normalized(_ names: [String]) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for raw in names { let name = raw.trimmingCharacters(in: .whitespacesAndNewlines); if !name.isEmpty, name.utf8.count <= 32, seen.insert(name).inserted { out.append(name) } }
        return Array(out.prefix(limit))
    }
    static func save(_ names: [String]) { UserDefaults.standard.set(normalized(names), forKey: key) }
    /// The names that actually take effect for a connection.
    static func active(strict: Bool) -> [String] { strict ? [] : saved }
    static func rules(strict: Bool) -> [NEOnDemandRule] {
        var rules: [NEOnDemandRule] = []
        let trusted = active(strict: strict)
        if !trusted.isEmpty { let off = NEOnDemandRuleDisconnect(); off.interfaceTypeMatch = .wiFi; off.ssidMatch = trusted; rules.append(off) }
        let on = NEOnDemandRuleConnect(); on.interfaceTypeMatch = .any; rules.append(on)
        return rules
    }
}
