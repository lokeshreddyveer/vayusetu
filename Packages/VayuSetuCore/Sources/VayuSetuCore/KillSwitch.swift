import Foundation

/// The fail-closed state of the VPN, stated honestly. Strict routing asks macOS to capture all network traffic into the tunnel, so when the
/// tunnel drops nothing is sent around it; macOS enforces that, not VayuSetu. VayuSetu can tell whether it asked and whether the saved system
/// configuration says so. It cannot prove the behaviour without cutting your connection, and it says that instead of claiming a green tick.
public enum KillSwitchState: Equatable, Sendable {
    /// Strict routing is switched off: if the VPN drops, traffic uses the ordinary network.
    case off
    /// Switched on, and no VPN is running. It takes effect the next time a VPN connects.
    case armed
    /// A VPN is connected and the saved configuration asks macOS to capture all traffic.
    case enforced
    /// The VPN is connecting or reconnecting with capture on: macOS holds traffic until it is back.
    case holding
    /// Switched on, but the running VPN's saved configuration does not capture all traffic.
    case notEnforced
    /// Strict routing is on and a VPN is running, but the saved configuration could not be read, so it cannot be known whether traffic is blocked if the VPN
    /// drops. This is treated as seriously as `notEnforced`: not being able to confirm protection is not the same as having it.
    case unknown

    public static func assess(settingOn: Bool, vpnRunning: Bool, connected: Bool, savedCapture: Bool?) -> KillSwitchState {
        guard settingOn else { return .off }
        guard vpnRunning else { return .armed }
        guard let savedCapture else { return .unknown }
        guard savedCapture else { return .notEnforced }
        return connected ? .enforced : .holding
    }

    public var title: String {
        switch self {
        case .off: return "Kill switch off"
        case .armed: return "Kill switch ready"
        case .enforced: return "Kill switch on"
        case .holding: return "Holding traffic"
        case .notEnforced: return "Kill switch not in force"
        case .unknown: return "Kill switch cannot be verified"
        }
    }
    public var detail: String {
        switch self {
        case .off: return "If the VPN drops, traffic goes out the ordinary network."
        case .armed: return "Applies when a VPN connects: if it drops, traffic stops instead of leaking."
        case .enforced: return "macOS blocks traffic outside the tunnel if it drops. VayuSetu does not test this, because that would cut your connection."
        case .holding: return "The VPN is reconnecting, and macOS is holding traffic until it is back."
        case .notEnforced: return "This connection was set up without capturing all traffic, so a drop could leak. Reconnect to apply strict routing."
        case .unknown: return "VayuSetu could not read the saved VPN configuration, so it cannot confirm that traffic is blocked if the VPN drops. Treat it as not protected until you reconnect."
        }
    }
    /// Whether this deserves the person's attention: protection that is missing, and protection that cannot be confirmed, get the same urgency.
    public var needsAttention: Bool { self == .notEnforced || self == .unknown }
    /// Whether the VPN's protection against a drop is confirmed. Only an enforced switch (or one that is holding traffic) is; "off" and "ready" are
    /// honest about not protecting yet, and the other two are the ones that need a look.
    public var isConfirmedProtective: Bool { self == .enforced || self == .holding }
}
