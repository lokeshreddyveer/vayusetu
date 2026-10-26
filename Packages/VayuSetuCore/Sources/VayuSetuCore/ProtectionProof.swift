import Foundation

/// One line of evidence in the protection proof: what was switched on, what was observed, and when.
public struct ProofCheck: Identifiable, Equatable, Sendable {
    public enum Outcome: String, Sendable { case passed, failed, unverified, notUsed }
    public let id: String
    public let title: String
    public let outcome: Outcome
    /// Plain words: what was seen, or what is missing.
    public let detail: String
    public let checkedAt: Date?
    public init(id: String, title: String, outcome: Outcome, detail: String, checkedAt: Date? = nil) {
        self.id = id; self.title = title; self.outcome = outcome; self.detail = detail; self.checkedAt = checkedAt
    }
}

public enum ProofVerdict: String, Sendable {
    /// Everything switched on has been seen working.
    case protected
    /// Something works, but something failed or has not been verified.
    case partial
    /// Something switched on has been seen not working.
    case notProtected
    /// Nothing is switched on.
    case off
}

public struct ProtectionProof: Equatable, Sendable {
    public let verdict: ProofVerdict
    public let headline: String
    public let checks: [ProofCheck]
}

/// What the app has actually observed. A value of nil means "not observed", which is never treated as success.
public struct ProofObservations: Sendable {
    // VPN
    public var vpnWanted = false
    public var vpnConnected: Bool?
    /// Public address now, and the address before the VPN was on; both observed by the app, not assumed.
    public var publicAddress: String?
    public var baselineAddress: String?
    public var addressCheckedAt: Date?
    public var handshakeAge: TimeInterval?
    // DNS
    public var dnsWanted = false
    public var dnsFilteringWanted = false
    public var dnsAnswered: Bool?
    public var blockedNameBlocked: Bool?
    public var dnsCheckedAt: Date?
    // Safari
    public var safariWanted = false
    public var safariRulesLoaded: Bool?
    public var safariCheckedAt: Date?
    // Network filter
    public var filterWanted = false
    public var filterRunning: Bool?
    public init() {}
}

public enum ProtectionProofEngine {
    /// Evidence older than this is shown as unverified instead of passed.
    public static let freshness: TimeInterval = 120
    public static let handshakeLimit: TimeInterval = 180

    public static func evaluate(_ o: ProofObservations, now: Date = Date()) -> ProtectionProof {
        var checks: [ProofCheck] = []
        func fresh(_ date: Date?) -> Bool { date.map { now.timeIntervalSince($0) <= freshness && $0.timeIntervalSince(now) < 5 } ?? false }

        // VPN
        if !o.vpnWanted { checks.append(.init(id: "vpn", title: "VPN", outcome: .notUsed, detail: "Not switched on.")) }
        else if o.vpnConnected == false { checks.append(.init(id: "vpn", title: "VPN", outcome: .failed, detail: "Switched on, but the tunnel is not connected.")) }
        else if o.vpnConnected == nil { checks.append(.init(id: "vpn", title: "VPN", outcome: .unverified, detail: "The tunnel's state has not been read yet.")) }
        else if let age = o.handshakeAge, age > handshakeLimit { checks.append(.init(id: "vpn", title: "VPN", outcome: .failed, detail: "Connected, but the last handshake with the server was \(Int(age)) seconds ago.", checkedAt: now)) }
        else if let now_ = o.publicAddress, let before = o.baselineAddress, now_ == before { checks.append(.init(id: "vpn", title: "VPN", outcome: .failed, detail: "Connected, but your public address did not change (\(now_)). Traffic may not be going through the VPN.", checkedAt: o.addressCheckedAt)) }
        else if let now_ = o.publicAddress, let before = o.baselineAddress, fresh(o.addressCheckedAt) { checks.append(.init(id: "vpn", title: "VPN", outcome: .passed, detail: "Connected, and your public address is \(now_) instead of \(before).", checkedAt: o.addressCheckedAt)) }
        // Without an address to compare, a recent handshake is still real evidence that the tunnel is talking to the server.
        else if let age = o.handshakeAge { checks.append(.init(id: "vpn", title: "VPN", outcome: .passed, detail: "Connected; the server completed a handshake \(Int(age)) seconds ago. Your public address has not been compared.", checkedAt: now.addingTimeInterval(-age))) }
        else { checks.append(.init(id: "vpn", title: "VPN", outcome: .unverified, detail: "Connected, but there is no handshake or address comparison to confirm it yet.", checkedAt: o.addressCheckedAt)) }

        // DNS
        if !o.dnsWanted { checks.append(.init(id: "dns", title: "Encrypted DNS", outcome: .notUsed, detail: "Not switched on.")) }
        else if o.dnsAnswered == false { checks.append(.init(id: "dns", title: "Encrypted DNS", outcome: .failed, detail: "A lookup through the tunnel got no answer.", checkedAt: o.dnsCheckedAt)) }
        else if o.dnsAnswered == nil { checks.append(.init(id: "dns", title: "Encrypted DNS", outcome: .unverified, detail: "No lookup has been tested through the tunnel yet.")) }
        else if o.dnsFilteringWanted && o.blockedNameBlocked == false { checks.append(.init(id: "dns", title: "Encrypted DNS", outcome: .failed, detail: "Lookups are answered, but a name on your block lists was not blocked, so ad blocking is not active.", checkedAt: o.dnsCheckedAt)) }
        else if o.dnsFilteringWanted && o.blockedNameBlocked == nil { checks.append(.init(id: "dns", title: "Encrypted DNS", outcome: .unverified, detail: "Lookups are answered. Blocking has not been tested.", checkedAt: o.dnsCheckedAt)) }
        else if fresh(o.dnsCheckedAt) { checks.append(.init(id: "dns", title: "Encrypted DNS", outcome: .passed, detail: o.dnsFilteringWanted ? "Lookups are answered through the tunnel, and a blocked name is refused." : "Lookups are answered through the tunnel.", checkedAt: o.dnsCheckedAt)) }
        else { checks.append(.init(id: "dns", title: "Encrypted DNS", outcome: .unverified, detail: "This worked when last tested, a while ago.", checkedAt: o.dnsCheckedAt)) }

        // Safari
        if !o.safariWanted { checks.append(.init(id: "safari", title: "Safari ad blocking", outcome: .notUsed, detail: "Not switched on.")) }
        else if o.safariRulesLoaded == true { checks.append(.init(id: "safari", title: "Safari ad blocking", outcome: .passed, detail: "Safari has loaded the rules.", checkedAt: o.safariCheckedAt)) }
        else if o.safariRulesLoaded == false { checks.append(.init(id: "safari", title: "Safari ad blocking", outcome: .failed, detail: "Safari has not loaded the rules. Check that the VayuSetu extensions are on in Safari.", checkedAt: o.safariCheckedAt)) }
        else { checks.append(.init(id: "safari", title: "Safari ad blocking", outcome: .unverified, detail: "Safari's state has not been read yet.")) }

        // Network filter
        if o.filterWanted {
            switch o.filterRunning {
            case true?: checks.append(.init(id: "filter", title: "Network filter", outcome: .passed, detail: "Running, and answering the app."))
            case false?: checks.append(.init(id: "filter", title: "Network filter", outcome: .failed, detail: "Switched on, but not responding."))
            case nil: checks.append(.init(id: "filter", title: "Network filter", outcome: .unverified, detail: "Not read yet."))
            }
        }

        let used = checks.filter { $0.outcome != .notUsed }
        if used.isEmpty { return ProtectionProof(verdict: .off, headline: "Nothing is switched on.", checks: checks) }
        let failed = used.filter { $0.outcome == .failed }, passed = used.filter { $0.outcome == .passed }
        if failed.isEmpty && used.allSatisfy({ $0.outcome == .passed }) { return ProtectionProof(verdict: .protected, headline: "Everything switched on has been seen working.", checks: checks) }
        if !failed.isEmpty {
            let names = failed.map(\.title).joined(separator: " and ")
            return ProtectionProof(verdict: passed.isEmpty ? .notProtected : .partial, headline: "\(names) did not pass its check.", checks: checks)
        }
        return ProtectionProof(verdict: .partial, headline: "Switched on, but not everything has been verified yet.", checks: checks)
    }
}
