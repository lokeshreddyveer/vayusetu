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
        // Resilient resolution: bounded tries with growing pauses, a path check between tries, saved addresses only as a last, recent resort.
        do {
            let cache = ResolverBootstrap.Cache(); var pauses: [TimeInterval] = []; var calls = 0; var clock = Date(timeIntervalSince1970: 1_000_000)
            let policy = ResolverBootstrap.RetryPolicy()
            let up = try ResolverBootstrap.resolveResilient(host: "settle.test", policy: policy, cache: cache, now: { clock }, lookup: { _ in calls += 1; if calls < 3 { throw AppIssue(message: "not yet") }; return ["1.1.1.1"] },
                                                           pathSatisfied: { true }, pause: { pauses.append($0) })
            require(up.addresses == ["1.1.1.1"] && up.source == .live(attempt: 3) && pauses == [0.5, 1], "bootstrap succeeds on the third try after pausing 0.5 s then 1 s")
            clock = clock.addingTimeInterval(3600); calls = 0; pauses = []
            let kept = try ResolverBootstrap.resolveResilient(host: "Settle.test", policy: policy, cache: cache, now: { clock }, lookup: { _ in calls += 1; throw AppIssue(message: "down") },
                                                             pathSatisfied: { true }, pause: { pauses.append($0) })
            require(kept.addresses == ["1.1.1.1"] && kept.source == .cached(age: 3600) && calls == policy.attempts, "saved addresses used only after every live try failed")
            require(pauses.reduce(0, +) <= 3.5, "waiting between tries is bounded: \(pauses.reduce(0, +)) s")
            clock = clock.addingTimeInterval(7 * 3600)
            do { _ = try ResolverBootstrap.resolveResilient(host: "settle.test", policy: policy, cache: cache, now: { clock }, lookup: { _ in throw AppIssue(message: "down") }, pathSatisfied: { true }, pause: { _ in }); fatalError("Expired saved addresses used") }
            catch { checks += 1; require((error as? AppIssue)?.message.contains("4 tries") == true, "failure after expiry says how many tries were made") }
            var waits = 0
            do { _ = try ResolverBootstrap.resolveResilient(host: "never.test", policy: policy, cache: ResolverBootstrap.Cache(), lookup: { _ in throw AppIssue(message: "down") }, pathSatisfied: { false }, pause: { _ in waits += 1 }); fatalError("Unresolvable host resolved") }
            catch { checks += 1; require((error as? AppIssue)?.message.contains("network was unavailable") == true, "failure reports that the network path was down") }
            require(waits <= 3 + 3 * 12, "path waiting is bounded: \(waits) pauses")
            var spentPauses: TimeInterval = 0; var shortCalls = 0
            var tight = ResolverBootstrap.RetryPolicy(); tight.totalBudget = 1.2
            do { _ = try ResolverBootstrap.resolveResilient(host: "tight.test", policy: tight, cache: ResolverBootstrap.Cache(), lookup: { _ in shortCalls += 1; throw AppIssue(message: "down") }, pathSatisfied: { false }, pause: { spentPauses += $0 }); fatalError("Unresolvable host resolved") }
            catch { checks += 1 }
            require(spentPauses <= tight.totalBudget + 0.001 && shortCalls < tight.attempts, "total waiting never exceeds the budget (\(spentPauses) s of \(tight.totalBudget) s, \(shortCalls) lookups)")
            var allPauses: TimeInterval = 0
            do { _ = try ResolverBootstrap.resolveResilient(host: "full.test", cache: ResolverBootstrap.Cache(), lookup: { _ in throw AppIssue(message: "down") }, pathSatisfied: { false }, pause: { allPauses += $0 }); fatalError("Unresolvable host resolved") }
            catch { checks += 1 }
            require(allPauses <= ResolverBootstrap.RetryPolicy().totalBudget + 0.001 && ResolverBootstrap.RetryPolicy().totalBudget < 10, "default budget stays inside the shortest connection deadline (10 s)")
        // Cancellable lookups: a hung query is stopped, its slot comes back on every exit, and a late answer can touch nothing.
        do {
            final class Counter: @unchecked Sendable { let lock = NSLock(); var value = 0; func bump() { lock.lock(); value += 1; lock.unlock() } }
            let pool = ResolverBootstrap.Pool(limit: 1)
            let stopped = Counter()
            let hung: ResolverBootstrap.Starter = { _, _ in { stopped.bump() } }       // never answers
            let began = Date()
            do { _ = try ResolverBootstrap.resolve(host: "hung.test", timeout: 0.2, start: hung, pool: pool); fatalError("Hung lookup returned") }
            catch { checks += 1; require(ResolverBootstrap.describe(error).contains("no answer"), "hung lookup reports a timeout") }
            require(Date().timeIntervalSince(began) < 0.6, "hung lookup is bounded by its deadline")
            require(stopped.value == 1 && pool.inFlight == 0, "deadline stops the query once and gives the slot back")
            // cancellation from outside ends the wait at once
            let flag = Counter(); let cancelBegan = Date()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { flag.bump() }
            do { _ = try ResolverBootstrap.resolve(host: "cancel.test", timeout: 5, start: hung, pool: pool, cancelled: { flag.value > 0 }); fatalError("Cancelled lookup returned") }
            catch { checks += 1; require(ResolverBootstrap.describe(error).contains("cancelled"), "cancelled lookup says so") }
            require(Date().timeIntervalSince(cancelBegan) < 1, "cancellation does not wait for the deadline")
            require(stopped.value == 2 && pool.inFlight == 0, "cancellation stops the query and gives the slot back")
            // many abandoned attempts in a row never exhaust a one-slot pool
            var busy = 0
            for _ in 0..<12 { do { _ = try ResolverBootstrap.resolve(host: "again.test", timeout: 0.03, start: hung, pool: pool) } catch { if ResolverBootstrap.describe(error).contains("pool") { busy += 1 } } }
            require(busy == 0 && pool.inFlight == 0 && stopped.value == 14, "twelve timed-out attempts never leave the pool busy")
            // busy means an attempt really is in flight, and clears when it ends
            let held = pool.take()
            do { _ = try ResolverBootstrap.resolve(host: "busy.test", timeout: 0.1, start: hung, pool: pool); fatalError("Ran with no free slot") }
            catch { checks += 1; require(ResolverBootstrap.describe(error).contains("pool"), "a full pool says so") }
            held?.release(); held?.release()
            require(pool.inFlight == 0, "releasing a slot twice gives back one slot")
            let answered = try ResolverBootstrap.resolve(host: "ok.test", timeout: 1, start: { _, done in done(.success(["1.1.1.1"])); return {} }, pool: pool)
            require(answered == ["1.1.1.1"] && pool.inFlight == 0, "an answered lookup gives the slot back")
            // a lookup whose answer fails validation is an error, not an address
            do { _ = try ResolverBootstrap.resolve(host: "loop.test", timeout: 1, start: { _, done in done(.success(["127.0.0.1"])); return {} }, pool: pool); fatalError("Loopback accepted") }
            catch { checks += 1 }
            require(pool.inFlight == 0, "a rejected answer still gives the slot back")
            // late completion: the first attempt is abandoned, the second answers, then the first answers too
            var firstCompletion: ((Result<[String], Error>) -> Void)?
            var starts = 0
            let cache = ResolverBootstrap.Cache()
            var tight = ResolverBootstrap.RetryPolicy(); tight.attemptTimeout = 0.05; tight.delays = [0]
            let outcome = try ResolverBootstrap.resolveResilient(host: "late.test", policy: tight, cache: cache, start: { _, done in
                starts += 1
                if starts == 1 { firstCompletion = done; return {} }
                done(.success(["9.9.9.9"])); return {}
            }, pool: pool, pathSatisfied: { true }, pause: { _ in })
            require(outcome.addresses == ["9.9.9.9"] && outcome.source == .live(attempt: 2), "second attempt answers on its own")
            firstCompletion?(.success(["1.1.1.1"]))        // the abandoned first attempt answers late
            Thread.sleep(forTimeInterval: 0.05)
            require(cache.recent("late.test", now: Date(), maximumAge: 60)?.addresses == ["9.9.9.9"], "a late answer from an abandoned attempt changes nothing")
            // no fallback to anything the profile did not name
            let empty = ResolverBootstrap.Cache(); empty.store("other.test", ["8.8.8.8"], at: Date())
            do { _ = try ResolverBootstrap.resolveResilient(host: "profile.test", cache: empty, start: { _, done in done(.failure(AppIssue(message: "down"))); return {} }, pool: pool, pathSatisfied: { true }, pause: { _ in }); fatalError("Fell back to another host's addresses") }
            catch { checks += 1; let text = (error as? AppIssue)?.message ?? ""; require(text.contains("no recent addresses are saved") && !text.contains("8.8.8.8") && !text.contains("1.1.1.1"), "failure names no resolver it did not use") }
            require(pool.inFlight == 0, "the slot count ends where it started")
            // contention: four attempts hold every slot, a fifth waits for capacity and gets it when one finishes
            do {
                final class Hold: @unchecked Sendable { let lock = NSLock(); var done: [(Result<[String], Error>) -> Void] = []; func add(_ f: @escaping (Result<[String], Error>) -> Void) { lock.lock(); done.append(f); lock.unlock() }; var count: Int { lock.lock(); defer { lock.unlock() }; return done.count } }
                final class Box: @unchecked Sendable { let lock = NSLock(); var results: [String: Result<[String], Error>] = [:]; func set(_ k: String, _ v: Result<[String], Error>) { lock.lock(); results[k] = v; lock.unlock() }; func get(_ k: String) -> Result<[String], Error>? { lock.lock(); defer { lock.unlock() }; return results[k] } }
                let four = ResolverBootstrap.Pool(limit: 4), hold = Hold(), box = Box()
                for i in 0..<4 {
                    DispatchQueue.global().async { box.set("held\(i)", Result { try ResolverBootstrap.resolve(host: "held.test", timeout: 5, start: { _, done in hold.add(done); return {} }, pool: four) }) }
                }
                while hold.count < 4 { Thread.sleep(forTimeInterval: 0.01) }
                require(four.inFlight == 4, "four attempts occupy every slot")
                DispatchQueue.global().async { box.set("fifth", Result { try ResolverBootstrap.resolve(host: "fifth.test", timeout: 5, start: { _, done in done(.success(["2.2.2.2"])); return {} }, pool: four) }) }
                Thread.sleep(forTimeInterval: 0.3)
                require(box.get("fifth") == nil, "the fifth request waits for capacity instead of failing at once")
                hold.done[0](.success(["3.3.3.3"]))
                var waited = 0.0; while box.get("fifth") == nil && waited < 2 { Thread.sleep(forTimeInterval: 0.01); waited += 0.01 }
                if case .success(let got)? = box.get("fifth") { require(got == ["2.2.2.2"], "the waiting request gets the freed slot and its own answer") } else { fatalError("FAIL: waiting request did not get the freed slot") }
                for i in 1..<4 { hold.done[i](.success(["3.3.3.3"])) }
                waited = 0; while four.inFlight > 0 && waited < 2 { Thread.sleep(forTimeInterval: 0.01); waited += 0.01 }
                require(four.inFlight == 0, "every slot comes back once the attempts finish")
            }
            // saturation inside the retry loop: waiting for a slot costs time, not one of the tries
            do {
                let one = ResolverBootstrap.Pool(limit: 1), lease = one.take()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { lease?.release() }
                let got = try ResolverBootstrap.resolveResilient(host: "cap.test", cache: ResolverBootstrap.Cache(), start: { _, done in done(.success(["4.4.4.4"])); return {} }, pool: one, pathSatisfied: { true }, pause: { _ in })
                require(got.addresses == ["4.4.4.4"] && got.source == .live(attempt: 1), "a slot that frees up shortly is waited for and the first try still counts as the first")
                let blocked = one.take()
                var small = ResolverBootstrap.RetryPolicy(); small.totalBudget = 1.2
                do { _ = try ResolverBootstrap.resolveResilient(host: "cap.test", policy: small, cache: ResolverBootstrap.Cache(), start: { _, done in done(.success(["4.4.4.4"])); return {} }, pool: one, pathSatisfied: { true }, pause: { _ in }); fatalError("Resolved with no free slot") }
                catch { checks += 1; let text = (error as? AppIssue)?.message ?? ""; require(text.contains("after 0 tries") && text.contains("free lookup slot"), "a pool that never frees fails clearly and uses no tries: \(text)") }
                blocked?.release()
                require(one.inFlight == 0, "slots are free again afterwards")
            }
            // the query is fully stopped before its slot goes back
            do {
                let one = ResolverBootstrap.Pool(limit: 1)
                final class Seen: @unchecked Sendable { let lock = NSLock(); var inFlightWhileStopping = -1; var closed = false }
                let seen = Seen()
                let slowStop: ResolverBootstrap.Starter = { _, _ in { seen.lock.lock(); seen.inFlightWhileStopping = one.inFlight; seen.lock.unlock(); Thread.sleep(forTimeInterval: 0.08); seen.lock.lock(); seen.closed = true; seen.lock.unlock() } }
                do { _ = try ResolverBootstrap.resolve(host: "stop.test", timeout: 0.1, start: slowStop, pool: one); fatalError("Hung lookup returned") } catch { checks += 1 }
                seen.lock.lock(); let closedBefore = seen.closed, during = seen.inFlightWhileStopping; seen.lock.unlock()
                require(closedBefore && during == 1 && one.inFlight == 0, "the slot is still held while the query closes and is given back only after")
                // the same on the answered path
                final class Stops: @unchecked Sendable { let lock = NSLock(); var n = 0 }
                let stops = Stops()
                _ = try ResolverBootstrap.resolve(host: "ok.test", timeout: 1, start: { _, done in done(.success(["5.5.5.5"])); return { stops.lock.lock(); stops.n += 1; stops.lock.unlock() } }, pool: one)
                require(stops.n == 1 && one.inFlight == 0, "an answered query is closed before its slot goes back")
            }
            // the network path answers "unknown": wait a short bounded time, then go on; "down" keeps waiting up to the limit
            do {
                var calls = 0; var pauses: [TimeInterval] = []; var tried = 0
                let states: [ResolverBootstrap.PathState] = [.unknown, .unknown, .satisfied]
                let ok = try ResolverBootstrap.resolveResilient(host: "path.test", cache: ResolverBootstrap.Cache(), start: { _, done in tried += 1; done(tried < 2 ? .failure(AppIssue(message: "down")) : .success(["6.6.6.6"])); return {} },
                                                               pool: ResolverBootstrap.Pool(limit: 2), pathSatisfied: { defer { calls += 1 }; return states[min(calls, 2)] }, pause: { pauses.append($0) })
                require(ok.addresses == ["6.6.6.6"] && pauses == [0.5, 0.25, 0.25], "unknown path is waited on in short steps until it answers: \(pauses)")
                var unknownPauses: [TimeInterval] = []; var attempts = 0
                _ = try? ResolverBootstrap.resolveResilient(host: "path2.test", cache: ResolverBootstrap.Cache(), start: { _, done in attempts += 1; done(attempts < 2 ? .failure(AppIssue(message: "down")) : .success(["6.6.6.6"])); return {} },
                                                           pool: ResolverBootstrap.Pool(limit: 2), pathSatisfied: { .unknown }, pause: { unknownPauses.append($0) })
                require(unknownPauses.dropFirst().reduce(0, +) <= 0.75, "a path that never answers delays the next try by at most half a second: \(unknownPauses)")
            }
            // one start-up budget for the first resolver and the optional backup
            do {
                require(ResolverBootstrap.RetryPolicy.within(remaining: 8, optional: false)?.totalBudget == 8, "the first resolver may use the whole budget")
                require((ResolverBootstrap.RetryPolicy.within(remaining: 5, optional: true)?.totalBudget ?? 99) <= 2, "the backup gets a small share only")
                require(ResolverBootstrap.RetryPolicy.within(remaining: 0.8, optional: true) == nil, "the backup is skipped when little time is left")
                require(ResolverBootstrap.RetryPolicy.within(remaining: 0.3, optional: false) == nil, "nothing is attempted with no time left")
                let primary = ResolverBootstrap.RetryPolicy.within(remaining: 8, optional: false)!, backup = ResolverBootstrap.RetryPolicy.within(remaining: 8 - primary.totalBudget + 2, optional: true)
                require(backup == nil || primary.totalBudget + backup!.totalBudget <= 8 + 2, "primary plus backup stay within one budget")
            }
            // a stop request while waiting for capacity ends the wait
            do {
                let one = ResolverBootstrap.Pool(limit: 1), blocker = one.take(); let flag = Counter()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { flag.bump() }
                let began = Date()
                do { _ = try ResolverBootstrap.resolve(host: "wait.test", timeout: 5, start: hung, pool: one, cancelled: { flag.value > 0 }); fatalError("Ran with no free slot") }
                catch { checks += 1; require(ResolverBootstrap.describe(error).contains("cancelled"), "cancelling while waiting for a slot says cancelled") }
                require(Date().timeIntervalSince(began) < 1, "the wait for capacity ends when the start is stopped")
                blocker?.release()
            }
            // the real system query: stopping it right away leaves nothing running and no slot taken
            let before = Date()
            do { _ = try ResolverBootstrap.resolve(host: "bootstrap-test.invalid", timeout: 1, pool: pool); fatalError("Invalid name resolved") } catch { checks += 1 }
            require(Date().timeIntervalSince(before) < 2 && pool.inFlight == 0, "the system query is bounded and releases its slot")
            var lateSystem = 0
            let stopSystem = ResolverBootstrap.systemStart("bootstrap-test.invalid") { _ in lateSystem += 1 }
            stopSystem(); stopSystem()
            Thread.sleep(forTimeInterval: 0.3)
            require(lateSystem == 0, "a stopped system query never reports")
        }
            let literalHost = try ResolverBootstrap.resolveResilient(host: "9.9.9.9", cache: ResolverBootstrap.Cache(), lookup: { _ in fatalError("Literal looked up") }, pathSatisfied: { false }, pause: { _ in fatalError("Literal waited") })
            require(literalHost.addresses == ["9.9.9.9"], "literal address never waits or looks up")
            let poisoned = ResolverBootstrap.Cache(); poisoned.store("bad.test", ["127.0.0.1"], at: Date())
            require(poisoned.recent("bad.test", now: Date(), maximumAge: 60) == nil, "saved addresses are re-validated before use")
        }
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
