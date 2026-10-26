import Foundation

/// A known-answer check of the resolver in use. A DNS resolver that has been tampered with, or a network that rewrites answers, can send you to the
/// wrong place without anything looking different. This asks for a few names whose answers do not change and do not depend on where you are
/// (the public resolvers' own names, which resolve to their fixed anycast addresses) and compares what comes back with what is known.
/// It sends three lookups through the resolver you already use and nothing to any third party. A name that a resolver blocks on purpose
/// (answered with 0.0.0.0) is reported as filtering, never as tampering.
public enum ResolverTrust {
    public struct KnownName: Sendable { public let name: String; public let addresses: Set<String> }
    public static let known: [KnownName] = [
        KnownName(name: "one.one.one.one", addresses: ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"]),
        KnownName(name: "dns.google", addresses: ["8.8.8.8", "8.8.4.4", "2001:4860:4860::8888", "2001:4860:4860::8844"]),
        KnownName(name: "dns.quad9.net", addresses: ["9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9"]),
    ]

    public enum Outcome: Equatable, Sendable {
        /// Every address that came back is one of the known addresses.
        case matched
        /// An address came back that is not one of the known ones.
        case different(unexpected: [String])
        /// The resolver answered with a null address (0.0.0.0 or ::): its own filtering, not a forged answer.
        case filtered
        /// No answer at all (offline, timeout, the name does not exist for this resolver).
        case noAnswer
    }
    public struct Result: Equatable, Sendable {
        public let name: String; public let outcome: Outcome
        public init(name: String, outcome: Outcome) { self.name = name; self.outcome = outcome }
    }

    public enum Verdict: Equatable, Sendable {
        case consistent
        /// At least one known name came back with an address that is not its own. `names` says which.
        case suspicious(names: [String])
        /// Too little to say: no answers, or only filtered ones.
        case inconclusive
        public var title: String {
            switch self { case .consistent: return "Answers match"; case .suspicious: return "Answers differ"; case .inconclusive: return "Could not check" }
        }
    }

    /// Normalises addresses the way the table is written (lowercase IPv6, no zone, no brackets).
    public static func normalize(_ address: String) -> String {
        var a = address.lowercased()
        if let percent = a.firstIndex(of: "%") { a = String(a[..<percent]) }
        return a.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    public static func classify(name: String, answers: [String]) -> Outcome {
        guard let expected = known.first(where: { $0.name == name })?.addresses else { return .noAnswer }
        let got = answers.map(normalize).filter { !$0.isEmpty }
        guard !got.isEmpty else { return .noAnswer }
        if got.allSatisfy({ $0 == "0.0.0.0" || $0 == "::" }) { return .filtered }
        let unexpected = got.filter { !expected.contains($0) && $0 != "0.0.0.0" && $0 != "::" }
        return unexpected.isEmpty ? .matched : .different(unexpected: unexpected)
    }

    public static func verdict(_ results: [Result]) -> Verdict {
        let different = results.compactMap { r -> String? in if case .different = r.outcome { return r.name }; return nil }
        if !different.isEmpty { return .suspicious(names: different) }
        // One mismatch is evidence; "consistent" needs at least two names that really matched.
        return results.filter { $0.outcome == .matched }.count >= 2 ? .consistent : .inconclusive
    }

    /// The words for the result, never printing an address.
    public static func summary(_ results: [Result]) -> String {
        switch verdict(results) {
        case .consistent: return "\(results.filter { $0.outcome == .matched }.count) of \(results.count) well-known names came back with their known addresses."
        case .suspicious(let names): return "\(names.joined(separator: ", ")) came back with an address that is not theirs. Your resolver or network may be altering answers, or a captive portal or filter is in the way."
        case .inconclusive:
            let filtered = results.filter { $0.outcome == .filtered }.count
            return filtered > 0 ? "\(filtered) name(s) were filtered by your resolver, so there was too little to compare." : "Too few names answered to compare."
        }
    }
}
