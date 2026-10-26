import SwiftUI

extension AppStore {
    /// The one-line connection status shown in the sidebar and the menu: what is switched on and working, nothing about verification.
    var connectionLabel: String {
        let pills = [vpnPill, dnsPill, adblockPill]
        if pills.contains(.pending) { return "Connecting…" }
        var parts: [String] = []
        if vpnPill == .active || vpnPill == .limited { parts.append("VPN") }
        if dnsPill == .active || dnsPill == .limited { parts.append("DNS") }
        if adblockPill == .active || adblockPill == .limited { parts.append("Safari") }
        return parts.isEmpty ? "Disconnected" : "Connected (" + parts.joined(separator: " + ") + ")"
    }
    /// Green when connected, orange while connecting, red when disconnected.
    var connectionTint: Color {
        let text = connectionLabel
        if text.hasPrefix("Connected") { return .green }
        if text.hasPrefix("Connecting") { return .orange }
        return .red
    }
}
