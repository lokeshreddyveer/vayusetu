import Foundation

/// What to do when the Mac joins a particular Wi-Fi network.
public enum NetworkAction: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Turn the network side off (VPN and DNS), for a network you trust or one that blocks VPNs.
    case off
    case dnsOnly
    case vpnOnly
    case vpnWithDNS
    public var id: String { rawValue }
    public var title: String {
        switch self { case .off: "Turn off"; case .dnsOnly: "DNS only"; case .vpnOnly: "VPN only"; case .vpnWithDNS: "VPN + DNS" }
    }
    public var vpn: Bool { self == .vpnOnly || self == .vpnWithDNS }
    public var dns: Bool { self == .dnsOnly || self == .vpnWithDNS }
}

public struct WiFiRule: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// The network's name (SSID), compared without regard to case.
    public var ssid: String
    public var action: NetworkAction
    public init(id: UUID = UUID(), ssid: String, action: NetworkAction) { self.id = id; self.ssid = ssid; self.action = action }
}

/// What the Mac should do about the network it just joined. Pure logic: the app reads the network name and applies the answer.
public struct NetworkRuleSet: Codable, Equatable, Sendable {
    public var enabled = false
    public var rules: [WiFiRule] = []
    /// For a network with no rule: leave things as they are (nil), or use this.
    public var otherNetworks: NetworkAction? = nil
    /// Applied to any network that has no password (open Wi-Fi). Checked before `otherNetworks`; a rule for the exact network still wins.
    public var openNetworks: NetworkAction? = nil
    public static let maximumRules = 50
    public init(enabled: Bool = false, rules: [WiFiRule] = [], otherNetworks: NetworkAction? = nil, openNetworks: NetworkAction? = nil) {
        self.enabled = enabled; self.rules = rules; self.otherNetworks = otherNetworks; self.openNetworks = openNetworks
    }
}

public enum NetworkRulePlanner {
    public struct Decision: Equatable, Sendable {
        public let action: NetworkAction
        /// Why, in words: shown to the user when the rule fires.
        public let reason: String
        /// True only for a rule the person wrote for this exact network. A general rule ("any open network", "any other network") is a
        /// suggestion: it is shown and waits for a yes, so joining a café's Wi-Fi never changes protection by itself.
        public let automatic: Bool
        public init(action: NetworkAction, reason: String, automatic: Bool = true) { self.action = action; self.reason = reason; self.automatic = automatic }
    }
    /// - Parameters:
    ///   - ssid: the network joined; nil when it cannot be read (no permission, or not on Wi-Fi).
    ///   - open: whether the network has no password, when known.
    ///   - current: what is on now, so nothing is changed when the answer is already in force.
    public static func decide(ssid: String?, open: Bool?, rules: NetworkRuleSet, current: NetworkAction?) -> Decision? {
        guard rules.enabled, let ssid = ssid?.trimmingCharacters(in: .whitespaces), !ssid.isEmpty else { return nil }
        let match = rules.rules.first { $0.ssid.caseInsensitiveCompare(ssid) == .orderedSame }
        let wanted: (NetworkAction, String, Bool)?
        if let match { wanted = (match.action, "“\(ssid)” has a rule: \(match.action.title).", true) }
        else if open == true, let action = rules.openNetworks { wanted = (action, "“\(ssid)” is an open network: \(action.title).", false) }
        else if let action = rules.otherNetworks { wanted = (action, "“\(ssid)” has no rule; other networks: \(action.title).", false) }
        else { wanted = nil }
        guard let (action, reason, automatic) = wanted, action != current else { return nil }
        return Decision(action: action, reason: reason, automatic: automatic)
    }
    /// Cleans a list as it is typed or loaded: trims, drops blanks and repeats (without regard to case), and keeps the first of each.
    public static func normalized(_ rules: [WiFiRule]) -> [WiFiRule] {
        var seen = Set<String>(); var out: [WiFiRule] = []
        for rule in rules {
            let name = rule.ssid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.utf8.count <= 32, seen.insert(name.lowercased()).inserted else { continue }
            out.append(WiFiRule(id: rule.id, ssid: name, action: rule.action))
        }
        return Array(out.prefix(NetworkRuleSet.maximumRules))
    }
    public static func current(vpn: Bool, dns: Bool) -> NetworkAction {
        switch (vpn, dns) { case (false, false): .off; case (false, true): .dnsOnly; case (true, false): .vpnOnly; case (true, true): .vpnWithDNS }
    }
}


/// The built-in prompt for open Wi-Fi. Anyone nearby can watch what crosses a network with no password, so joining one while nothing protects the
/// connection earns a suggestion. It is only ever a question: nothing is switched on until the person says yes.
public enum OpenNetworkPrompt {
    public struct Suggestion: Equatable, Sendable {
        public let ssid: String
        public let action: NetworkAction
        public var message: String { "“\(ssid)” has no password, so others on it can watch unprotected traffic. Turn on \(action.title)?" }
    }
    /// - Parameters:
    ///   - ignored: networks the person said "don't ask again" for (compared without regard to case).
    ///   - dismissedNow: the network the person said "not now" to during this connection.
    public static func suggestion(ssid: String?, open: Bool?, current: NetworkAction?, enabled: Bool, ignored: [String], dismissedNow: String?, offer: NetworkAction = .vpnWithDNS) -> Suggestion? {
        guard enabled, open == true, let name = ssid?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        guard current == NetworkAction.off else { return nil }          // already protected (or unknown): nothing to suggest
        if ignored.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return nil }
        if let dismissedNow, dismissedNow.caseInsensitiveCompare(name) == .orderedSame { return nil }
        return Suggestion(ssid: name, action: offer)
    }
}
