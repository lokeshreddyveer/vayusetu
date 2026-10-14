import AppIntents
import Foundation

/// Shared by the app and the widget extension: what a Shortcut, Siri, the Action Button or a Control Center button can ask for, and the
/// small status record the app publishes for the Home Screen widget. The extension only describes buttons; the app, which owns the tunnels
/// and their permissions, carries every request out.
enum ProtectionShortcut: String { case dnsOnly, vpnOn, networkOff, adblockOn, adblockOff }

@MainActor enum ProtectionActionInbox {
    /// Set once the app's interface is up. A request made while the app was still launching waits in `pending`.
    static var handler: ((ProtectionShortcut) -> Void)? {
        didSet { if let handler, let waiting = pending { pending = nil; handler(waiting) } }
    }
    private static var pending: ProtectionShortcut?
    static func post(_ action: ProtectionShortcut) { if let handler { handler(action) } else { pending = action } }
}

struct TurnOnDNSOnlyIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn on DNS Only"
    static let description = IntentDescription("Starts VayuSetu’s encrypted DNS and filtering, with no VPN server.")
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult { ProtectionActionInbox.post(.dnsOnly); return .result() }
}
struct TurnOnVPNIntent: AppIntent {
    static let title: LocalizedStringResource = "Connect VPN"
    static let description = IntentDescription("Connects the VPN profile selected in VayuSetu.")
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult { ProtectionActionInbox.post(.vpnOn); return .result() }
}
struct TurnOffProtectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Off VPN and DNS"
    static let description = IntentDescription("Disconnects the VPN and stops DNS protection. Safari ad blocking is separate.")
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult { ProtectionActionInbox.post(.networkOff); return .result() }
}
struct TurnOnAdblockIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn on Safari Ad Blocking"
    static let description = IntentDescription("Switches Safari protection on in VayuSetu.")
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult { ProtectionActionInbox.post(.adblockOn); return .result() }
}
struct TurnOffAdblockIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn off Safari Ad Blocking"
    static let description = IntentDescription("Switches Safari protection off in VayuSetu.")
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult { ProtectionActionInbox.post(.adblockOff); return .result() }
}

/// What the Home Screen widget shows. Written by the app whenever protection changes, read by the widget. It holds only on/off facts.
struct WidgetStatus: Codable, Equatable {
    var mode = "Not protected"
    var vpn = false
    var dns = false
    var adblock = false
    var profile: String?
    var updated = Date()
    static let suite = "group.app.vayusetu.shared", key = "widget-status"
    static func read() -> WidgetStatus {
        guard let data = UserDefaults(suiteName: suite)?.data(forKey: key), let value = try? JSONDecoder().decode(WidgetStatus.self, from: data) else { return WidgetStatus() }
        return value
    }
    func write() { if let data = try? JSONEncoder().encode(self) { UserDefaults(suiteName: Self.suite)?.set(data, forKey: Self.key) } }
}
