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
    // MARK: One lookup that can be given up on
    /// Starts one system lookup and returns the function that stops it. The completion may run on any queue, at most once, and not at all after the stop.
    typealias Starter = (_ host: String, _ completion: @escaping (Result<[String], Error>) -> Void) -> (() -> Void)

    /// The attempts allowed in flight at once. A slot is taken when an attempt starts and given back exactly once on every way out of it (an answer, the
    /// deadline, a cancellation), so an attempt that was given up on can never keep a slot from the next one.
    final class Pool: @unchecked Sendable {
        static let shared = Pool(limit: 4)
        private let condition = NSCondition(); private let limit: Int; private var used = 0
        init(limit: Int) { self.limit = limit }
        var inFlight: Int { condition.lock(); defer { condition.unlock() }; return used }
        final class Lease: @unchecked Sendable {
            private let pool: Pool; private let lock = NSLock(); private var released = false
            fileprivate init(_ pool: Pool) { self.pool = pool }
            func release() { lock.lock(); let first = !released; released = true; lock.unlock(); if first { pool.give() } }
            deinit { release() }
        }
        /// A slot if one is free now.
        func take() -> Lease? { condition.lock(); defer { condition.unlock() }; guard used < limit else { return nil }; used += 1; return Lease(self) }
        /// A slot, waiting up to `wait` seconds for one to come back. Capacity that is merely busy is waited for, not treated as a failure; the wait ends
        /// early when `cancelled` turns true.
        func take(wait: TimeInterval, cancelled: () -> Bool = { false }) -> Lease? {
            let deadline = Date().addingTimeInterval(wait)
            condition.lock(); defer { condition.unlock() }
            while used >= limit {
                if cancelled() { return nil }
                let step = min(0.05, deadline.timeIntervalSinceNow)
                if step <= 0 { return nil }
                _ = condition.wait(until: Date().addingTimeInterval(step))
            }
            used += 1; return Lease(self)
        }
        fileprivate func give() { condition.lock(); used = max(0, used - 1); condition.signal(); condition.unlock() }
    }

    /// What one attempt ended with, kept apart from every other attempt: an answer that arrives after its attempt was given up on lands here and nowhere else.
    private final class Attempt: @unchecked Sendable {
        let lock = NSLock(); let signal = DispatchSemaphore(value: 0)
        var result: Result<[String], Error>?; var abandoned = false
        func finish(_ value: Result<[String], Error>) {
            lock.lock(); defer { lock.unlock() }
            guard !abandoned, result == nil else { return }          // late or repeated: ignored
            result = value; signal.signal()
        }
        /// Takes the answer if there is one, otherwise gives the attempt up so that nothing arriving later is used.
        func settle() -> Result<[String], Error>? {
            lock.lock(); defer { lock.unlock() }
            if let result { return result }
            abandoned = true; return nil
        }
    }
    /// Why a lookup did not produce an address. Kept apart so that waiting for capacity, a silent resolver, a cancelled start and an answer with nothing
    /// usable are each handled for what they are, and none of them is a connection.
    enum Failure: Error, Equatable {
        case capacity                     // every slot is in use and none came back in time
        case timedOut                     // the resolver did not answer before the deadline
        case cancelled                    // the start was stopped
        case noUsableAddress(String)      // it answered, but with nothing that may be used
        case lookup(String)               // the system could not be asked, or reported an error
        var message: String {
            switch self {
            case .capacity: return "the lookup pool stayed full"
            case .timedOut: return "no answer from the resolver in time"
            case .cancelled: return "the start was cancelled"
            case .noUsableAddress(let why): return why
            case .lookup(let why): return why
            }
        }
    }
    static func describe(_ error: Error) -> String { (error as? Failure)?.message ?? (error as? AppIssue)?.message ?? "lookup failed" }

    /// One bounded, cancellable lookup. The deadline stops the query itself, not just the wait for it. The slot is given back only after the query has
    /// fully stopped, and on every way out.
    static func resolve(host: String, timeout: TimeInterval = 5, start: Starter = systemStart, pool: Pool = .shared, cancelled: () -> Bool = { false }) throws -> [String] {
        guard timeout > 0, timeout <= 10, !host.isEmpty, host.utf8.count <= 253 else { throw AppIssue(message: "Invalid resolver bootstrap request.") }
        if ProfileParser.ipFamily(host) != nil { return try validated([host]) }
        guard let lease = pool.take(wait: min(timeout, 1.5), cancelled: cancelled) else { throw cancelled() ? Failure.cancelled : Failure.capacity }
        defer { lease.release() }
        let attempt = Attempt()
        let stop = start(host) { attempt.finish($0) }
        let deadline = Date().addingTimeInterval(timeout)
        while !cancelled() {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            if attempt.signal.wait(timeout: .now() + min(0.05, remaining)) == .success { break }
        }
        let outcome = attempt.settle()
        stop()                                                      // returns once the query is closed; only then does the slot go back
        guard let outcome else { throw cancelled() ? Failure.cancelled : Failure.timedOut }
        let found = try outcome.get()
        do { return try validated(found) } catch { throw Failure.noUsableAddress((error as? AppIssue)?.message ?? "nothing usable in the answer") }
    }
    /// For callers that only have a blocking lookup (tests, tools). It cannot be stopped; the deadline and the slot still hold.
    static func resolve(host: String, timeout: TimeInterval = 5, lookup: @escaping (String) throws -> [String]) throws -> [String] {
        try resolve(host: host, timeout: timeout, start: blocking(lookup))
    }
    /// Wraps a lookup that can only block (tests, or a platform without the cancellable query). It cannot be stopped, so the thread is left to finish.
    static func blocking(_ lookup: @escaping (String) throws -> [String]) -> Starter {
        { host, completion in
            DispatchQueue.global(qos: .utility).async { completion(Result { try lookup(host) }) }
            return {}
        }
    }
    /// The system resolver through DNSServiceGetAddrInfo, which can be stopped. Both address families are collected for a short moment after the first answer.
    static func systemStart(_ host: String, _ completion: @escaping (Result<[String], Error>) -> Void) -> () -> Void {
        final class Query: @unchecked Sendable {
            let lock = NSLock(); let queue = DispatchQueue(label: "app.vayusetu.bootstrap-lookup", qos: .utility)
            var ref: DNSServiceRef?; var addresses = Set<String>(); var done = false; var graceStarted = false
            var retained: Unmanaged<Query>?                       // the reference the system callback context holds; dropped once, after the query is closed
            let completion: (Result<[String], Error>) -> Void
            init(_ completion: @escaping (Result<[String], Error>) -> Void) { self.completion = completion }
            private func closeNow() { // on the query's own queue; after the deallocation no callback can follow
                lock.lock(); let r = ref; ref = nil; let held = retained; retained = nil; lock.unlock()
                if let r { DNSServiceRefDeallocate(r) }
                held?.release()
            }
            func close() { queue.async { [self] in closeNow() } }
            func deliver() {
                lock.lock(); if done { lock.unlock(); return }; done = true
                let found = Array(addresses.sorted().prefix(8)); lock.unlock()
                close(); completion(found.isEmpty ? .failure(Failure.noUsableAddress("the resolver answered with no usable address")) : .success(found))
            }
            /// Returns only when the query has been closed, so a caller that then gives back its slot never frees capacity that is still in use.
            func stop() { lock.lock(); done = true; lock.unlock(); queue.sync { closeNow() } }
        }
        let query = Query(completion)
        let context = Unmanaged.passRetained(query)
        query.retained = context
        var ref: DNSServiceRef?
        let callback: DNSServiceGetAddrInfoReply = { _, flags, _, error, _, address, _, context in
            guard let context else { return }
            let query = Unmanaged<Query>.fromOpaque(context).takeUnretainedValue()
            guard error == kDNSServiceErr_NoError, flags & kDNSServiceFlagsAdd != 0, let address else { return }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return }
            let text = String(cString: buffer)
            guard ResolverBootstrap.usable(text) else { return }
            query.lock.lock(); query.addresses.insert(text)
            let first = !query.graceStarted; query.graceStarted = true; query.lock.unlock()
            if first { query.queue.asyncAfter(deadline: .now() + 0.25) { query.deliver() } }   // let the other family arrive too
        }
        let status = DNSServiceGetAddrInfo(&ref, 0, 0, 0, host, callback, context.toOpaque())
        guard status == kDNSServiceErr_NoError, let ref else {
            query.lock.lock(); query.retained = nil; query.lock.unlock(); context.release()
            DispatchQueue.global(qos: .utility).async { completion(.failure(Failure.lookup("the system resolver could not be asked (\(status))"))) }
            return {}
        }
        query.lock.lock(); query.ref = ref; query.lock.unlock()
        DNSServiceSetDispatchQueue(ref, query.queue)
        return { query.stop() }
    }

    // MARK: Resolution that survives a network that is still settling
    // A tunnel is often asked to start in the moment the network is changing (right after another tunnel stopped, on a wake, on a Wi‑Fi switch). One
    // five-second lookup then fails the whole start. This tries a bounded number of times with growing pauses and checks the network path between
    // tries, and only as a last step reuses addresses this process resolved earlier, while they are still recent.
    struct RetryPolicy {
        var attemptTimeout: TimeInterval = 2.5
        var delays: [TimeInterval] = [0.5, 1, 2]                 // pause before the 2nd, 3rd and 4th try
        /// Everything together (lookups, pauses, path waits) stops here. The app's own connection deadline is 30 s by default and can be set as low as
        /// 10 s, so this has to leave room for the rest of start-up inside the shortest one.
        var totalBudget: TimeInterval = 8
        var maximumCacheAge: TimeInterval = 6 * 3600
        /// Saved addresses this recent are used straight after one failed lookup rather than after every try.
        var savedAddressAgeAfterFailure: TimeInterval = 3600
        var attempts: Int { delays.count + 1 }
        /// The policy for what is left of one shared start-up budget. The first resolver may use all of it; an optional one (the backup) only a small
        /// share, and none when too little remains, so the backup can never push the start past the connection deadline. Nil: no time left.
        static func within(remaining: TimeInterval, optional: Bool) -> RetryPolicy? {
            let usable = optional ? min(remaining, 2) : remaining
            guard usable >= (optional ? 1 : 0.5) else { return nil }
            var policy = RetryPolicy(); policy.totalBudget = usable
            if optional { policy.delays = [0.5] }
            return policy
        }
    }
    enum Source: Equatable { case live(attempt: Int), cached(age: TimeInterval) }
    /// Addresses a host resolved to earlier in this process. Only used after live lookups failed, only while recent, and always re-validated.
    final class Cache {
        private let lock = NSLock(); private var entries: [String: (addresses: [String], date: Date)] = [:]
        private let file: URL?
        /// With a file, the entries survive the tunnel process: a new process after a quick stop and start still has the last good addresses.
        init(file: URL? = nil) {
            self.file = file
            guard let file, let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode([String: Stored].self, from: data) else { return }
            for (host, entry) in stored { entries[host] = (entry.addresses, Date(timeIntervalSince1970: entry.at)) }
        }
        private struct Stored: Codable { var addresses: [String]; var at: TimeInterval }
        func store(_ host: String, _ addresses: [String], at date: Date) {
            lock.lock(); defer { lock.unlock() }
            entries[host.lowercased()] = (addresses, date)
            guard let file else { return }
            let stored = entries.mapValues { Stored(addresses: $0.addresses, at: $0.date.timeIntervalSince1970) }
            guard let data = try? JSONEncoder().encode(stored) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        func recent(_ host: String, now: Date, maximumAge: TimeInterval) -> (addresses: [String], age: TimeInterval)? {
            lock.lock(); defer { lock.unlock() }
            guard let entry = entries[host.lowercased()] else { return nil }
            let age = now.timeIntervalSince(entry.date)
            guard age >= 0, age <= maximumAge, let checked = try? validated(entry.addresses) else { return nil }
            return (checked, age)
        }
        func clear() { lock.lock(); entries = [:]; lock.unlock(); if let file { try? FileManager.default.removeItem(at: file) } }
    }
    /// Kept on disk in the process's own cache folder. The addresses are public provider addresses and are re-validated on every read.
    static let sharedCache = Cache(file: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("resolver-bootstrap.json"))

    enum PathState: Equatable, ExpressibleByBooleanLiteral {
        case satisfied, unsatisfied, unknown
        init(booleanLiteral value: Bool) { self = value ? .satisfied : .unsatisfied }
    }
    /// What the system says about the network path right now. "Unknown" means it did not answer in time; it is not the same as "usable", and the
    /// caller waits a short, bounded moment for a real answer before going on.
    static func networkPathState() -> PathState {
        final class Box: @unchecked Sendable { let lock = NSLock(); var value: PathState = .unknown }
        let box = Box(), monitor = NWPathMonitor(), answered = DispatchSemaphore(value: 0)
        monitor.pathUpdateHandler = { path in box.lock.lock(); box.value = path.status == .satisfied ? .satisfied : .unsatisfied; box.lock.unlock(); answered.signal() }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        _ = answered.wait(timeout: .now() + 0.5)
        monitor.cancel()
        box.lock.lock(); defer { box.lock.unlock() }
        return box.value
    }

    static func resolveResilient(host: String, policy: RetryPolicy = RetryPolicy(), cache: Cache = sharedCache, now: () -> Date = Date.init,
                                 lookup: @escaping (String) throws -> [String], pathSatisfied: () -> PathState = networkPathState,
                                 pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) throws -> (addresses: [String], source: Source) {
        try resolveResilient(host: host, policy: policy, cache: cache, now: now, start: blocking(lookup), pathSatisfied: pathSatisfied, pause: pause)
    }
    static func resolveResilient(host: String, policy: RetryPolicy = RetryPolicy(), cache: Cache = sharedCache, now: () -> Date = Date.init,
                                 start: Starter = systemStart, pool: Pool = .shared, cancelled: () -> Bool = { false }, pathSatisfied: () -> PathState = networkPathState,
                                 pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) throws -> (addresses: [String], source: Source) {
        if ProfileParser.ipFamily(host) != nil { return (try validated([host]), .live(attempt: 1)) }
        var lastIssue = "no answer"; var pathWasDown = false; var spent: TimeInterval = 0; var tries = 0; var capacityWaits = 0
        while tries < policy.attempts {
            if cancelled() { throw AppIssue(message: "Resolver bootstrap was cancelled.") }
            if tries > 0 {
                let wait = min(policy.delays[tries - 1], max(0, policy.totalBudget - spent))
                pause(wait); spent += wait
                // Give the path a short, bounded chance to settle before spending a lookup on it. "Unknown" waits too, but only half a second.
                var waited = 0.0
                while waited < policy.attemptTimeout && spent + 0.25 < policy.totalBudget {
                    let state = pathSatisfied()
                    if state == .satisfied { break }
                    if state == .unsatisfied { pathWasDown = true } else if waited >= 0.5 { break }
                    pause(0.25); waited += 0.25; spent += 0.25
                }
            }
            let remaining = policy.totalBudget - spent
            if remaining < 0.5 { break }                                    // not enough budget left for a lookup worth making
            let began = Date()
            do {
                let found = try resolve(host: host, timeout: min(policy.attemptTimeout, remaining), start: start, pool: pool, cancelled: cancelled)
                cache.store(host, found, at: now())
                return (found, .live(attempt: tries + 1))
            } catch Failure.cancelled {
                throw AppIssue(message: "Resolver bootstrap was cancelled.")
            } catch Failure.capacity {
                // Waiting for a slot is not a failed lookup: it uses up time from the budget, not one of the tries.
                capacityWaits += 1; lastIssue = Failure.capacity.message; spent += Date().timeIntervalSince(began)
                if capacityWaits >= 6 { break }
            } catch {
                if cancelled() { throw AppIssue(message: "Resolver bootstrap was cancelled.") }
                tries += 1; lastIssue = Self.describe(error); spent += Date().timeIntervalSince(began)
                // The provider's addresses rarely change. When the system resolver is stalled, a recent saved answer connects at once
                // instead of waiting out the budget; the TLS name check still protects against a wrong address.
                if let kept = cache.recent(host, now: now(), maximumAge: policy.savedAddressAgeAfterFailure) { return (kept.addresses, .cached(age: kept.age)) }
            }
        }
        if let kept = cache.recent(host, now: now(), maximumAge: policy.maximumCacheAge) { return (kept.addresses, .cached(age: kept.age)) }
        throw AppIssue(message: "Resolver bootstrap failed after \(tries) \(tries == 1 ? "try" : "tries")" + (capacityWaits > 0 ? " and \(capacityWaits) wait\(capacityWaits == 1 ? "" : "s") for a free lookup slot" : "") + (pathWasDown ? " while the network was unavailable" : "") + " (\(lastIssue)) and no recent addresses are saved. Add the provider’s bootstrap addresses, or retry when the network is steady.")
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
