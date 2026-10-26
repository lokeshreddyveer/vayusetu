import Foundation

/// A suggestion about which saved resolver to use. It is only ever shown; nothing is switched. It is never based on speed alone: the resolver must
/// have been unreliable while the connection itself was fine, the alternative must be reachable now, and it must not give up what the person has
/// (filtering, and working with a VPN that manages DNS).
public struct ResolverCandidate: Equatable, Sendable {
    public enum Filtering: Int, Comparable, Sendable { case unknown = 0, none = 1, provider = 2, vayusetuLists = 3
        public static func < (a: Filtering, b: Filtering) -> Bool { a.rawValue < b.rawValue } }
    public var name: String
    public var filtering: Filtering
    /// Whether the resolver works while a VPN carries the traffic (VayuSetu's resolver always does; an arbitrary one is not assumed to).
    public var worksThroughVPN: Bool
    /// From a probe made now: did it answer, and in how long.
    public var reachableNow: Bool?
    public var probeMs: Double?
    public init(name: String, filtering: Filtering, worksThroughVPN: Bool, reachableNow: Bool? = nil, probeMs: Double? = nil) {
        self.name = name; self.filtering = filtering; self.worksThroughVPN = worksThroughVPN; self.reachableNow = reachableNow; self.probeMs = probeMs
    }
}

public struct ResolverSuggestion: Equatable, Sendable {
    public var candidate: String
    public var reasons: [String]
    public var caveats: [String]
}

public enum ResolverRecommendation {
    public static let minimumFailureShare = 0.10
    public static func evaluate(current: ResolverCandidate, health: ResolverHealth?, connectionHealthy: Bool, vpnOn: Bool, privacyPrefersCurrent: Bool = false,
                                others: [ResolverCandidate]) -> ResolverSuggestion? {
        // Only a resolver that has really been failing, with enough lookups to say so, while the router and internet were fine.
        guard connectionHealthy, let h = health, let share = h.failureShare, share >= minimumFailureShare else { return nil }
        guard !privacyPrefersCurrent else { return nil }
        let eligible = others.filter { c in
            c.name != current.name && c.reachableNow == true && c.filtering >= current.filtering && (!vpnOn || c.worksThroughVPN)
        }
        guard let best = eligible.sorted(by: { ($0.filtering.rawValue, -($0.probeMs ?? .infinity)) > ($1.filtering.rawValue, -($1.probeMs ?? .infinity)) }).first else { return nil }
        var reasons = ["\(current.name) failed \(Int(share * 100))% of \(h.forwarded) forwarded lookups (\(h.timeouts) timeouts, \(h.errors) errors) while the router and internet were fine."]
        reasons.append("\(best.name) answered a test lookup just now" + (best.probeMs.map { " in \(Int($0)) ms" } ?? "") + ".")
        var caveats = ["This is a suggestion. VayuSetu will not change your resolver for you."]
        if best.filtering == .unknown { caveats.append("It is not known whether \(best.name) filters ads or trackers.") }
        if h.forwarded < 100 { caveats.append("Based on a small number of lookups; check again later.") }
        return ResolverSuggestion(candidate: best.name, reasons: reasons, caveats: caveats)
    }
}
