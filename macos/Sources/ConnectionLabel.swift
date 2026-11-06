import SwiftUI

extension AppStore {
    /// The one-line connection status shown in the sidebar and the menu: what is switched on and working, nothing about verification.
    /// True only while something is really being brought up or down. A protection that is on but not yet confirmed is "pending" too, and
    /// calling that "Starting…" made a working connection look stuck for as long as the check had not passed.
    var isStarting: Bool { protectionBusy || tunnel.busy || filtering.busy || [.connecting, .reasserting].contains(tunnel.status) }
    /// The word for one protection's state: "Starting…" only while it really is starting, otherwise what is true ("Not verified yet").
    func pillWord(_ state: PillState, on: String = "On") -> String {
        switch state {
        case .off: "Off"
        case .active: on
        case .pending: isStarting ? "Starting…" : "Not verified yet"
        case .limited: "Limited"
        case .failed: "Failed"
        }
    }
    var connectionLabel: String {
        let pills = [vpnPill, dnsPill, adblockPill]
        if pills.contains(.pending) && isStarting { return "Connecting…" }
        var parts: [String] = []
        if vpnPill == .active || vpnPill == .limited { parts.append("VPN") }
        if dnsPill == .active || dnsPill == .limited { parts.append("DNS") }
        if adblockPill == .active || adblockPill == .limited { parts.append("Safari") }
        if parts.isEmpty { return "Disconnected" }
        return "Connected (" + parts.joined(separator: " + ") + ")" + (dnsPill == .pending ? " · DNS not verified" : "")
    }
    /// Green when connected, orange while connecting, red when disconnected.
    var connectionTint: Color {
        let text = connectionLabel
        if text.hasPrefix("Connected") { return .green }
        if text.hasPrefix("Connecting") { return .orange }
        return .red
    }
}
