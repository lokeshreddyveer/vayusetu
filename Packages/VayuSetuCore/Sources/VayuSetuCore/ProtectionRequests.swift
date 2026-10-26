import Foundation

/// What is switched on, as plain values, so the rules for accepting a protection request can be tested without the app.
public struct ProtectionTarget: Equatable, Sendable {
    public var vpn: Bool, dns: Bool, adblock: Bool
    public init(vpn: Bool = false, dns: Bool = false, adblock: Bool = false) { self.vpn = vpn; self.dns = dns; self.adblock = adblock }
}

public enum ProtectionControl: String, Sendable { case vpn, dns, adblock }

/// How a request to change protection is understood. A control that is told a value (a switch, a link, a rule) sets that value; it never
/// inverts what is running now. Asking for what is already so changes nothing, so a callback that is repeated or replayed cannot flip protection.
public enum ProtectionRequestPolicy {
    /// The target after one control is set to `enabled`, the others staying as they are now.
    public static func setting(_ control: ProtectionControl, to enabled: Bool, from observed: ProtectionTarget) -> ProtectionTarget {
        var next = observed
        switch control {
        case .vpn: next.vpn = enabled
        case .dns: next.dns = enabled
        case .adblock: next.adblock = enabled
        }
        return next
    }

    /// The value a link asks for: "on" and "off" are explicit, "toggle" is relative to now, anything else is not a request.
    public static func linkValue(_ action: String, control: ProtectionControl, observed: ProtectionTarget) -> Bool? {
        switch action {
        case "on": return true
        case "off": return false
        case "toggle":
            switch control { case .vpn: return !observed.vpn; case .dns: return !observed.dns; case .adblock: return !observed.adblock }
        default: return nil
        }
    }

    public static func isNoChange(_ requested: ProtectionTarget, from observed: ProtectionTarget) -> Bool { requested == observed }

    /// The controls that differ, in words ("VPN on", "DNS off").
    public static func differences(_ requested: ProtectionTarget, from observed: ProtectionTarget) -> [String] {
        var out: [String] = []
        if requested.vpn != observed.vpn { out.append("VPN " + (requested.vpn ? "on" : "off")) }
        if requested.dns != observed.dns { out.append("DNS " + (requested.dns ? "on" : "off")) }
        if requested.adblock != observed.adblock { out.append("Adblock " + (requested.adblock ? "on" : "off")) }
        return out
    }

    /// One line for the connection log: who asked, and what for. Every protection change carries its initiator.
    public static func logLine(source: String, requested: ProtectionTarget, observed: ProtectionTarget) -> String {
        let changes = differences(requested, from: observed)
        return "Protection requested by \(source): " + (changes.isEmpty ? "no change" : changes.joined(separator: ", "))
    }
}
