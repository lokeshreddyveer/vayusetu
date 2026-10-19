import AppKit
import SwiftUI
import VayuSetuCore

/// Settings for the Mac, laid out as a macOS preferences page: grouped forms with switches, and one destination per row.
/// It binds to the same settings as the iPhone's Settings screen.
struct MacSettings: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    @ObservedObject var preferences: DesktopPreferences
    @AppStorage("appearance") private var appearance = "dark"
    @StateObject private var checksNetwork = NetworkDiagnostics()
    @State private var removing = false
    private var locked: Bool { tunnel.running || tunnel.busy || store.connectionOperation }
    private var version: String { (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "Development" }
    private var build: String { (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "" }

    var body: some View {
        MacPage(title: "Settings", subtitle: "Protection, startup, notifications and diagnostics.") {
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 20) { protection; startup; notifications; appearanceBox }.frame(maxWidth: .infinity)
                VStack(spacing: 20) { diagnostics; data; advanced; about }.frame(maxWidth: .infinity)
            }
        }
        .vsConfirm(isPresented: $removing, title: "Remove the saved VPN configuration?", message: "Your imported profiles and keys remain available.", confirm: "Remove", destructive: true, icon: "trash.fill") { Task { do { try await tunnel.removeConfiguration() } catch { store.notice = error.localizedDescription } } }
    }

    private var protection: some View {
        MacPanel("Protection", icon: "shield.lefthalf.filled") {
            VStack(alignment: .leading, spacing: 10) {
                link("Permissions", "VPN, Safari, DNS and notifications", icon: "hand.raised") { VSProtectionPermissionsScreen(store: store, tunnel: tunnel) }
                Divider()
                link("Protection modes", store.savedModeTitle, icon: "arrow.triangle.branch") { VSModeScreen(store: store, tunnel: tunnel) }
                Divider()
                link("Routing & connection rules", "Strict routing, local network, app reconnect", icon: "lock.shield") { VSPrivacyLockScreen(store: store, tunnel: tunnel) }
                Divider()
                switchRow("Connect on launch", "Starts protection when VayuSetu opens.", icon: "bolt", isOn: $store.connectOnLaunch)
                Divider()
                switchRow("Automatic reconnect", "Reconnects if the tunnel drops.", icon: "arrow.clockwise", isOn: Binding(get: { tunnel.autoReconnect }, set: { tunnel.autoReconnect = $0; UserDefaults.standard.set($0, forKey: "auto-reconnect") }))
                Text("Strict routing applies while connected. System on-demand is unavailable for this WireGuard build; the app can reconnect while running. Changes apply on the next connection, and leak protection still needs independent verification.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
    private var startup: some View {
        MacPanel("This Mac", icon: "laptopcomputer") {
            VStack(alignment: .leading, spacing: 10) {
                switchRow("Launch at login", "Opens VayuSetu in the menu bar when you sign in.", icon: "power", isOn: Binding(get: { preferences.loginEnabled }, set: { preferences.setLogin($0) }))
                if !preferences.message.isEmpty { Text(preferences.message).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
        }
    }
    private var notifications: some View {
        MacPanel("Notifications", icon: "bell") {
            VStack(alignment: .leading, spacing: 10) {
                switchRow("Connection notifications", "Tells you when the VPN or DNS connects or drops.", icon: "bell.badge", isOn: Binding(get: { tunnel.notificationsEnabled }, set: { tunnel.setNotifications($0) }))
                Divider()
                link("Notification details", "What is announced and when", icon: "text.bubble") { VSNotificationsScreen(tunnel: tunnel) }
            }
        }
    }
    private var appearanceBox: some View {
        MacPanel("Appearance", icon: "circle.lefthalf.filled") {
            VStack(alignment: .leading, spacing: 10) {
                MacRow(icon: "paintbrush", title: "Theme", detail: "Dark, light or follow the system.") {
                    Picker("", selection: $appearance) { Text("Dark").tag("dark"); Text("Light").tag("light"); Text("System").tag("system") }.labelsHidden().pickerStyle(.segmented).frame(width: 220)
                }
                Divider()
                link("Appearance & accessibility", "Text size, contrast and motion", icon: "accessibility") { VSAppearanceScreen() }
            }
        }
    }
    private var diagnostics: some View {
        MacPanel("Diagnostics", icon: "waveform.path.ecg") {
            VStack(spacing: 10) {
                link("Checks", "IP, DNS, route and network evidence", icon: "waveform.path.ecg") { VSChecksScreen(store: store, tunnel: tunnel, network: checksNetwork) }
                Divider()
                link("Connection logs", "What the tunnel did, and when", icon: "text.alignleft") { VSLogsScreen(tunnel: tunnel) }
                Divider()
                link("Traffic & sessions", "Totals and history per profile", icon: "arrow.up.arrow.down") { VSTrafficScreen(store: store, tunnel: tunnel) }
                Divider()
                link("Privacy activity", "Blocks and requests observed", icon: "clock") { VSActivityScreen(filtering: store.filtering, tunnel: tunnel) }
                Divider()
                link("Compatibility", "What each connection can do, and conflicts", icon: "exclamationmark.triangle") { VSConflictsScreen(store: store, tunnel: tunnel) }
                Divider()
                link("Extension status", "System extension and Safari extensions", icon: "puzzlepiece.extension") { VSExtensionStatusScreen(store: store, tunnel: tunnel) }
            }
        }
    }
    private var data: some View {
        MacPanel("Data", icon: "externaldrive") {
            VStack(spacing: 10) {
                link("Data & logging", "What is kept on this Mac", icon: "hand.raised") { VSPrivacyScreen(filtering: store.filtering) }
                Divider()
                link("Encrypted backups", "Back up and restore profiles and settings", icon: "externaldrive.badge.icloud") { VSCardList { VSSection { BackupPanel(store: store, tunnel: tunnel) } }.vsList().vsHeader("Encrypted Backups") }
            }
        }
    }
    private var advanced: some View {
        MacPanel("Advanced", icon: "gearshape.2") {
            VStack(spacing: 10) {
                link("Security Center", "Egress checks, provider filters, hardening", icon: "lock.shield") { VSSecurityCenter(store: store, tunnel: tunnel) }
                Divider()
                link("Connection recovery", "Retries, timeouts, backup resolver and profile", icon: "arrow.clockwise") { VSCardList { VSSection { RetryPreferences(tunnel: tunnel, store: store) } }.vsList().vsHeader("Connection Recovery") }
                Divider()
                link("Emergency reset", "Remove VayuSetu's VPN and DNS configuration", icon: "arrow.counterclockwise") { VSEmergencyResetScreen(store: store, tunnel: tunnel) }
                Divider()
                HStack { Button(role: .destructive) { removing = true } label: { Label("Remove saved VPN configuration…", systemImage: "trash") }.buttonStyle(MacHoverButtonStyle()).disabled(locked); Spacer() }
            }
        }
    }
    private var about: some View {
        MacPanel("About", icon: "info.circle") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    MacBrandArtwork().frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) { Text("VayuSetu").font(.system(size: 14, weight: .semibold)); Text("By R3dby · version \(version)\(build.isEmpty ? "" : " (\(build))")").font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                Divider()
                link("Acknowledgements", "WireGuard and the filter lists", icon: "heart") { VSCheckDetail(title: "Acknowledgements", explanation: "VayuSetu uses the WireGuard backend. Credentials are retained in the Keychain.", output: notices) }
            }
        }
    }
    private var notices: String { Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "WireGuard · https://www.wireguard.com" }

    private func switchRow(_ title: String, _ detail: String, icon: String, isOn: Binding<Bool>) -> some View {
        MacRow(icon: icon, title: title, detail: detail) { Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityLabel(title) }
    }
    private func link<D: View>(_ title: String, _ detail: String, icon: String, @ViewBuilder destination: @escaping () -> D) -> some View {
        NavigationLink { destination().frame(maxWidth: 880) } label: { MacRow(icon: icon, title: title, detail: detail) { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }.contentShape(Rectangle()) }.buttonStyle(.plain)
    }
}
