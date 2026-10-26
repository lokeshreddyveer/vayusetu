import Foundation

/// What the tunnel's DNS resolver did over a window, counted by what actually happened rather than lumped into "failed". Only lookups that were
/// forwarded upstream are timed: answers served from the cache and names blocked on the device never reached the resolver and say nothing about it.
public struct ResolverHealth: Codable, Equatable, Sendable {
    public var windowStart: Date
    public var windowEnd: Date
    /// Forwarded lookups that were answered, with their round-trip times in milliseconds (bucketed, see `bucketLimits`).
    public var answered: Int
    public var timeouts: Int
    /// The upstream refused, reset or broke the connection (not a timeout).
    public var errors: Int
    public var cacheHits: Int
    public var blockedLocally: Int
    public var rttBuckets: [Int]
    /// Changes each time the tunnel starts, so counters from an earlier run are never mistaken for this one.
    public var generation: Int
    public static let bucketLimits: [Double] = [25, 50, 100, 200, 400, 800, 1600]    // ms; one more bucket above the last
    public static let minimumSamples = 20
    public init(windowStart: Date, windowEnd: Date, answered: Int, timeouts: Int, errors: Int, cacheHits: Int = 0, blockedLocally: Int = 0, rttBuckets: [Int] = [], generation: Int = 0) {
        self.windowStart = windowStart; self.windowEnd = windowEnd; self.answered = answered; self.timeouts = timeouts; self.errors = errors
        self.cacheHits = cacheHits; self.blockedLocally = blockedLocally; self.rttBuckets = rttBuckets.count == Self.bucketLimits.count + 1 ? rttBuckets : [Int](repeating: 0, count: Self.bucketLimits.count + 1); self.generation = generation
    }
    public var forwarded: Int { answered + timeouts + errors }
    public var failureShare: Double? { forwarded >= Self.minimumSamples ? Double(timeouts + errors) / Double(forwarded) : nil }
    /// A percentile of the answered lookups' round trip, to the bucket's upper edge (an honest upper bound, never finer than the data).
    public func roundTripMs(percentile p: Double) -> Double? {
        let total = rttBuckets.reduce(0, +)
        guard total >= Self.minimumSamples else { return nil }
        var seen = 0
        for (i, c) in rttBuckets.enumerated() { seen += c; if Double(seen) >= p * Double(total) { return i < Self.bucketLimits.count ? Self.bucketLimits[i] : (Self.bucketLimits.last ?? 0) * 2 } }
        return nil
    }
    /// Counters from an older tunnel run are discarded: a new generation replaces, it is never added to.
    public func accepting(newer other: ResolverHealth) -> ResolverHealth { other.generation >= generation ? other : self }
}

public enum ComponentName: String, Codable, Sendable { case wifiRouter = "Wi-Fi and router", internet = "Internet", dns = "DNS", vpn = "VPN" }
public enum ComponentState: String, Codable, Sendable { case good, degraded, failing, unknown }

public struct HealthComponent: Equatable, Sendable {
    public var name: ComponentName
    public var state: ComponentState
    public var provenance: EvidenceProvenance
    public var reason: String
}

public struct VPNHealthInput: Equatable, Sendable {
    public var running: Bool, connected: Bool, failed: Bool
    /// Seconds since the last WireGuard handshake, when known.
    public var handshakeAge: Double?
    public init(running: Bool, connected: Bool, failed: Bool = false, handshakeAge: Double? = nil) { self.running = running; self.connected = connected; self.failed = failed; self.handshakeAge = handshakeAge }
}

/// Four separate judgements, so a resolver outage never makes the Wi-Fi look poor and a dead router is not reported as three problems.
public enum HealthAssessor {
    public static func assess(rounds: [ProbeRound], resolver: ResolverHealth?, vpn: VPNHealthInput?) -> [HealthComponent] {
        func loss(_ answers: [Bool]) -> Double? { answers.count >= 5 ? Double(answers.filter { !$0 }.count) / Double(answers.count) : nil }
        let routerLoss = loss(rounds.compactMap(\.gatewayAnswered))
        let internetLoss = loss(rounds.compactMap(\.internetAnswered))
        let dnsLoss = loss(rounds.compactMap(\.dnsAnswered))

        var router: HealthComponent
        switch routerLoss {
        case nil: router = HealthComponent(name: .wifiRouter, state: .unknown, provenance: .notAvailable, reason: "Not enough router checks yet.")
        case let l? where l >= 0.5: router = HealthComponent(name: .wifiRouter, state: .failing, provenance: .measured, reason: "The router answered \(Int((1 - l) * 100))% of checks.")
        case let l? where l >= 0.1: router = HealthComponent(name: .wifiRouter, state: .degraded, provenance: .measured, reason: "The router missed \(Int(l * 100))% of checks.")
        default: router = HealthComponent(name: .wifiRouter, state: .good, provenance: .measured, reason: "The router is answering.")
        }

        var internet: HealthComponent
        if router.state == .failing {
            internet = HealthComponent(name: .internet, state: .unknown, provenance: .notAvailable, reason: "Cannot be judged while the router is not answering.")
        } else {
            switch internetLoss {
            case nil: internet = HealthComponent(name: .internet, state: .unknown, provenance: .notAvailable, reason: "Not enough internet checks yet.")
            case let l? where l >= 0.5: internet = HealthComponent(name: .internet, state: .failing, provenance: .measured, reason: "The internet answered \(Int((1 - l) * 100))% of checks while the router was fine.")
            case let l? where l >= 0.1: internet = HealthComponent(name: .internet, state: .degraded, provenance: .measured, reason: "The internet missed \(Int(l * 100))% of checks.")
            default: internet = HealthComponent(name: .internet, state: .good, provenance: .measured, reason: "The internet is reachable.")
            }
        }

        var dns: HealthComponent
        if internet.state == .failing || router.state == .failing {
            dns = HealthComponent(name: .dns, state: .unknown, provenance: .notAvailable, reason: "Cannot be judged while the connection itself is down.")
        } else if let r = resolver, let share = r.failureShare {
            let p95 = r.roundTripMs(percentile: 0.95)
            if share >= 0.10 { dns = HealthComponent(name: .dns, state: .failing, provenance: .measured, reason: "The tunnel's resolver failed \(Int(share * 100))% of \(r.forwarded) forwarded lookups (\(r.timeouts) timeouts, \(r.errors) errors).") }
            else if share >= 0.02 || (p95 ?? 0) > 800 { dns = HealthComponent(name: .dns, state: .degraded, provenance: .measured, reason: "The tunnel's resolver is slow or missing some lookups" + (p95.map { " (95% answered within \(Int($0)) ms)" } ?? "") + ".") }
            else { dns = HealthComponent(name: .dns, state: .good, provenance: .measured, reason: "The tunnel's resolver answered \(r.answered) forwarded lookups" + (p95.map { ", 95% within \(Int($0)) ms" } ?? "") + ".") }
        } else if let l = dnsLoss {
            // No tunnel resolver figures: this is the app's own periodic lookup, a different measurement, and it says so.
            if l >= 0.5 { dns = HealthComponent(name: .dns, state: .failing, provenance: .measured, reason: "Tunnel resolver health unavailable. The app's own DNS check failed \(Int(l * 100))% of the time.") }
            else if l >= 0.1 { dns = HealthComponent(name: .dns, state: .degraded, provenance: .measured, reason: "Tunnel resolver health unavailable. The app's own DNS check missed \(Int(l * 100))%.") }
            else { dns = HealthComponent(name: .dns, state: .good, provenance: .measured, reason: "Tunnel resolver health unavailable. The app's own DNS check is answering.") }
        } else {
            dns = HealthComponent(name: .dns, state: .unknown, provenance: .notAvailable, reason: "No DNS measurements yet.")
        }

        var vpnC: HealthComponent
        if let v = vpn, v.running {
            if v.failed { vpnC = HealthComponent(name: .vpn, state: .failing, provenance: .measured, reason: "The VPN failed to connect.") }
            else if !v.connected { vpnC = HealthComponent(name: .vpn, state: .degraded, provenance: .measured, reason: "The VPN is connecting or reconnecting.") }
            else if let age = v.handshakeAge, age > 180 { vpnC = HealthComponent(name: .vpn, state: .degraded, provenance: .measured, reason: "No handshake with the VPN server for \(Int(age / 60)) minutes.") }
            else { vpnC = HealthComponent(name: .vpn, state: .good, provenance: .measured, reason: "The VPN is connected.") }
        } else {
            vpnC = HealthComponent(name: .vpn, state: .unknown, provenance: .notAvailable, reason: "The VPN is off.")
        }
        return [router, internet, dns, vpnC]
    }
}

/// One reading of the tunnel's cumulative resolver counters.
public struct ResolverSample: Equatable, Sendable {
    public var date: Date
    public var answered: Int, timeouts: Int, errors: Int, cacheHits: Int
    public var rtt: [Int]
    public var generation: Int
    public init(date: Date, answered: Int, timeouts: Int, errors: Int, cacheHits: Int, rtt: [Int], generation: Int) {
        self.date = date; self.answered = answered; self.timeouts = timeouts; self.errors = errors; self.cacheHits = cacheHits; self.rtt = rtt; self.generation = generation
    }
}

public enum ResolverWindow {
    public static let defaultWindow: TimeInterval = 600
    public static let maximumSamples = 400
    /// Adds a reading, keeping the list bounded. A new tunnel run (a newer generation) discards the older run's readings.
    public static func appending(_ samples: [ResolverSample], _ new: ResolverSample) -> [ResolverSample] {
        // A reading from an older tunnel run than the newest one already held is stale and is dropped.
        if let newest = samples.map(\.generation).max(), new.generation < newest { return samples }
        var kept = samples.filter { $0.generation >= new.generation }
        if let last = kept.last, last.generation == new.generation, new.answered < last.answered || new.timeouts < last.timeouts || new.errors < last.errors { kept = [] }   // counters went backwards: start over
        kept.append(new)
        return Array(kept.suffix(maximumSamples))
    }
    /// What the resolver did in the last `window`, as the difference between two readings of the same run (never across a restart).
    public static func health(_ samples: [ResolverSample], now: Date, window: TimeInterval = defaultWindow, blockedLocally: Int = 0) -> ResolverHealth? {
        guard let latest = samples.last else { return nil }
        let run = samples.filter { $0.generation == latest.generation }
        guard run.count >= 2 else { return nil }
        let base = run.last(where: { $0.date <= now.addingTimeInterval(-window) }) ?? run[0]
        guard base.date < latest.date else { return nil }
        func d(_ a: Int, _ b: Int) -> Int { max(0, a - b) }
        let buckets = (0..<(ResolverHealth.bucketLimits.count + 1)).map { i in d(i < latest.rtt.count ? latest.rtt[i] : 0, i < base.rtt.count ? base.rtt[i] : 0) }
        return ResolverHealth(windowStart: base.date, windowEnd: latest.date, answered: d(latest.answered, base.answered), timeouts: d(latest.timeouts, base.timeouts), errors: d(latest.errors, base.errors),
                              cacheHits: d(latest.cacheHits, base.cacheHits), blockedLocally: blockedLocally, rttBuckets: buckets, generation: latest.generation)
    }
}
