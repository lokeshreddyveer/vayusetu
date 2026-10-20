import SwiftUI
import VayuSetuCore
import NetworkExtension
import Security
import Network

struct VSHomeScreen: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    @ObservedObject var network: NetworkDiagnostics
    var connect: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @StateObject private var live = LiveDeviceSpeed()
    @State private var showingModes = false
    @Environment(\.openProfilesTab) private var openProfilesTab
    @State private var modeSheetConnects = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title) private var timerSize = 24
    @ScaledMetric(relativeTo: .title3) private var trafficSize = 22
    var connected: Bool { tunnel.status == .connected }
    var color: Color { connected ? Color(red: 0.196, green: 0.839, blue: 0.627) : tunnel.stage == .failed || tunnel.stage == .blocked ? .red : VSDesign.accent }
    var body: some View {
        AnyView(GeometryReader { geometry in ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                #if os(iOS)
                homeHeader.padding(.horizontal, -4)
                #else
                Text("Your private connection, on your terms.").font(.subheadline).foregroundStyle(.secondary)
                #endif
                hero
                sessionAndTraffic
                VSHomeActivity(filtering: store.filtering)
                VSProtectionGrid(store: store, tunnel: tunnel)
                VSHomeActions(store: store, tunnel: tunnel, network: network)
                if !tunnel.message.isEmpty { Label(tunnel.message, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.orange) }
                if !store.protectionNotice.isEmpty { Label(store.protectionNotice, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("HomeProtectionNotice") }
                if !TunnelController.available { Text("VPN connections require the signed VPN build. Profiles and diagnostics remain available.").font(.footnote).foregroundStyle(.secondary) }
            }.padding(16).frame(maxWidth: 820).frame(width: geometry.size.width)
        }.scrollIndicators(.hidden).background(VSDesign.background) }
        .sheet(isPresented: $showingModes) { VSProtectionModeSheet(store: store, connectsAfterChoosing: modeSheetConnects).vsDialogHost().vsSheetChrome([.fraction(0.86), .large]) }
        #if os(iOS)
        .navigationTitle("").toolbar(.hidden, for: .navigationBar)
        #else
        .navigationTitle("Overview")
        #endif
        )
    }
    #if os(iOS)
    @ScaledMetric(relativeTo: .title2) private var headerTitleSize = 24
    var homeHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Image("BrandMark").resizable().scaledToFit().frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 9)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("VayuSetu").font(.system(size: headerTitleSize, weight: .semibold))
                Text("Your network. Your control.").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            NavigationLink { VSSettingsScreen(store: store, tunnel: tunnel) } label: {
                Image(systemName: "gearshape").font(.system(size: 20, weight: .medium))
                    .frame(width: 44, height: 44)
                    .background(VSDesign.surface, in: Circle())
                    .overlay(Circle().stroke(VSDesign.separator, lineWidth: 1))
            }.buttonStyle(VSPlainButtonStyle()).accessibilityLabel("Open Settings")
        }.padding(.top, 12).accessibilityIdentifier("HomeHeader")
    }
    #endif
    private var sessionAndTraffic: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let timer = connected && tunnel.observedConnectedDate != nil ? tunnel.duration : "—:—:—:—"
            let parts = timer.split(separator: ":").map(String.init)
            let sample = tunnel.observedCounters()
            VStack(alignment: .leading, spacing: 16) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(0..<4) { index in
                            VStack(spacing: 3) {
                                Text(parts.count == 4 ? parts[index] : "—").font(.system(size: timerSize, weight: .medium, design: .monospaced)).monospacedDigit()
                                Text(["DAYS", "HRS", "MIN", "SEC"][index]).font(.system(size: 10, weight: .medium)).tracking(0.5).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity)
                            if index < 3 { Rectangle().fill(VSDesign.separator).frame(width: 1, height: 30).padding(.top, 2) }
                        }
                    }
                    Text(timer).font(.system(size: timerSize, weight: .medium, design: .monospaced)).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity).accessibilityElement(children: .ignore)
                    .accessibilityLabel("Session duration")
                    .accessibilityValue(connected && parts.count == 4 ? "\(parts[0]) days, \(parts[1]) hours, \(parts[2]) minutes, \(parts[3]) seconds" : "No active session")
                    .accessibilityIdentifier("HomeSessionTimer")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { trafficPill("Download", icon: "arrow.down", tint: VSDesign.accent, total: sample?.received, rate: tunnel.ratesAvailable ? tunnel.receivedPerSecond : nil, device: live.down); trafficPill("Upload", icon: "arrow.up", tint: .green, total: sample?.sent, rate: tunnel.ratesAvailable ? tunnel.sentPerSecond : nil, device: live.up) }
                    VStack(spacing: 8) { trafficPill("Download", icon: "arrow.down", tint: VSDesign.accent, total: sample?.received, rate: tunnel.ratesAvailable ? tunnel.receivedPerSecond : nil, device: live.down); trafficPill("Upload", icon: "arrow.up", tint: .green, total: sample?.sent, rate: tunnel.ratesAvailable ? tunnel.sentPerSecond : nil, device: live.up) }
                }
                if connected && sample == nil {
                    Text(tunnel.localDNSRunning ? "DNS Only does not carry your traffic, so there are no transfer totals." : "This connection type does not report transfer totals.").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
    /// Capsule with a real byte total from the active session, or an em dash when the connection type reports none (never 0 B for unknown).
    /// One row: arrow, name, and the live speed on the right. The tunnel's own speed is used when it reports one, otherwise this device's.
    private func trafficPill(_ title: String, icon: String, tint: Color, total: UInt64?, rate: Double?, device: Double?) -> some View {
        let speed = rate ?? device
        let text = speed.map { SpeedFormat.text($0) } ?? "—"
        return HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(tint)
                .frame(width: 22, height: 22).background(tint.opacity(0.18), in: Circle())
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 2)
            Text(text).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        }.padding(.horizontal, 9).frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(VSDesign.surface, in: Capsule()).overlay(Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 1))
            .accessibilityElement(children: .combine).accessibilityLabel("\(title) \(text)" + (total.map { ", \(bytes($0)) this session" } ?? ""))
    }
    private func dnsCard(_ title: String, icon: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value ?? "—").font(.system(size: trafficSize, weight: .semibold)).monospacedDigit()
            Text(value == nil ? "Unavailable" : "since the tunnel started").font(.caption).foregroundStyle(.secondary)
        }.padding(12).frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .background(VSDesign.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(VSDesign.separator, lineWidth: 1))
    }
    private func trafficCard(_ title: String, icon: String, rateValue: Double, total: UInt64?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(rate(rateValue)).font(.system(size: trafficSize, weight: .semibold)).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            Text(total.map { bytes($0) + " total" } ?? "Total unavailable").font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(12).frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .background(VSDesign.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(VSDesign.separator, lineWidth: 1))
    }
    // Power button colour follows the observed network mode: gray off, teal DNS only, blue VPN only, green VPN + DNS.
    private var connectionAccent: Color {
        if !tunnel.ready { return .secondary }
        switch store.powerTone {
        case .off: return .secondary
        case .dnsOnly: return Color(red: 0.0, green: 0.78, blue: 0.82)
        case .vpnOnly: return VSDesign.accent
        case .vpnWithDNS: return Color(red: 0.196, green: 0.839, blue: 0.627)
        case .busy: return .orange
        case .error: return .red
        }
    }
    private func pillColor(_ state: PillState) -> Color {
        switch state {
        case .active: return Color(red: 0.196, green: 0.839, blue: 0.627)
        case .pending, .limited: return .orange
        case .failed: return .red
        case .off: return .secondary
        }
    }
    private func pillWord(_ state: PillState) -> String {
        switch state { case .active: return "active"; case .pending: return "starting or not yet verified"; case .limited: return "limited"; case .failed: return "failed"; case .off: return "off" }
    }
    /// Independent toggles, not badges: each turns exactly one protection on or off through the coordinator.
    private var pillRow: some View {
        HStack(spacing: 10) {
            pill("VPN", state: store.vpnPill, id: "HomePillVPN", .vpn)
            pill("DNS", state: store.dnsPill, id: "HomePillDNS", .dns)
            pill("Adblock", state: store.adblockPill, id: "HomePillAdblock", .adblock)
        }
    }
    private func pillIcon(_ which: ProtectionPill) -> String {
        switch which { case .vpn: return "shield.lefthalf.filled"; case .dns: return "network"; case .adblock: return "hand.raised.slash" }
    }
    private func pill(_ title: String, state: PillState, id: String, _ which: ProtectionPill) -> some View {
        let color = pillColor(state)
        return Button { Task { await store.togglePill(which) } } label: {
            HStack(spacing: 6) {
                if state == .pending { ProgressView().controlSize(.mini).tint(color) }
                else { Image(systemName: pillIcon(which)).font(.system(size: 13, weight: .semibold)).foregroundStyle(color) }
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(state == .off ? Color.secondary : Color.primary).lineLimit(1).minimumScaleFactor(0.8)
            }.frame(maxWidth: .infinity).frame(height: 38)
                .background(color.opacity(state == .off ? 0.08 : 0.16), in: Capsule())
                .overlay(Capsule().stroke(color.opacity(state == .off ? 0.25 : 0.6), lineWidth: 1))
                .padding(.vertical, 3).contentShape(Rectangle())     // 44 pt touch target around the 38 pt pill
        }.buttonStyle(VSPlainButtonStyle()).disabled(store.protectionBusy || tunnel.busy || !tunnel.ready || !TunnelController.available && which != .adblock || [.connecting, .reasserting, .disconnecting].contains(tunnel.status) && which != .adblock)
            .accessibilityLabel("\(title), \(pillWord(state))").accessibilityHint("Double tap to turn \(state == .off ? "on" : "off")")
            .accessibilityIdentifier(id)
    }
    private var connectionLabel: String {
        guard tunnel.ready else { return "STATUS UNKNOWN" }
        if connected && tunnel.localDNSRunning { return store.dnsPill == .active ? "PROTECTION ACTIVE" : "DNS TUNNEL UP · NOT VERIFIED" }
        if connected { return "PROTECTION ACTIVE" }
        if tunnel.status == .disconnecting { return "DISCONNECTING" }
        if tunnel.status == .reasserting || tunnel.stage == .reconnecting { return "RECONNECTING" }
        if tunnel.busy || tunnel.status == .connecting { return "CONNECTING" }
        if tunnel.stage == .failed || tunnel.stage == .blocked { return "CONNECTION FAILED" }
        return "DISCONNECTED"
    }
    private var connectionMessage: String {
        if !tunnel.ready { return "Checking network status" }
        if tunnel.status == .disconnecting { return "Ending connection" }
        if tunnel.busy || store.protectionBusy || (tunnel.running && !connected) { return "Establishing connection" }
        if tunnel.stage == .failed || tunnel.stage == .blocked { return "Unable to connect" }
        if connected || store.observedMode != .off { return store.observedMode.title }
        return "Network protection is off"
    }
    private var connectionCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 7) {
                Circle().fill(connectionAccent).frame(width: 6, height: 6)
                Text(connectionLabel).font(.caption.weight(.semibold)).tracking(1.2)
            }.foregroundStyle(connectionAccent)
            Button {
                // Master power: off stops the network protection; on restores the last-used mode (selector the first time).
                Task { if await store.powerTapped() { modeSheetConnects = true; showingModes = true } }
            } label: {
                ZStack {
                    Circle().stroke(connectionAccent.opacity(0.45), lineWidth: 1).frame(width: 104, height: 104)
                    Circle().fill(VSDesign.elevated).frame(width: 82, height: 82)
                    VSHomePowerMark().stroke(connectionAccent, style: StrokeStyle(lineWidth: 3, lineCap: .round)).frame(width: 36, height: 36)
                    if tunnel.busy || tunnel.status == .connecting || tunnel.status == .reasserting {
                        ProgressView().tint(.orange).offset(y: 50)
                    }
                }.frame(width: 104, height: 104).contentShape(Circle())
            }.buttonStyle(VSPlainButtonStyle())
                .disabled(!TunnelController.available || !tunnel.ready || tunnel.busy || store.protectionBusy || [.connecting, .reasserting, .disconnecting].contains(tunnel.status))
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in VSHaptic.play(.firm); modeSheetConnects = false; showingModes = true })
                .sensoryFeedback(.selection, trigger: tunnel.status.rawValue)
                .accessibilityLabel(store.networkActive ? "Turn network protection off" : "Turn network protection on")
                .accessibilityHint("Touch and hold to choose a different mode")
                .accessibilityIdentifier("HomeVPNPower")
            VStack(spacing: 5) {
                Button { modeSheetConnects = false; showingModes = true } label: {
                    HStack(spacing: 5) { Text(connectionMessage).font(.headline); Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                }.buttonStyle(VSPlainButtonStyle())
                    .accessibilityHint("Opens the protection mode selector").accessibilityIdentifier("HomeModeLabel")
                Text(store.protectionSubtitle).font(.caption).foregroundStyle(.secondary)
                if connected && tunnel.stage != .connected && !tunnel.localDNSRunning {
                    Text("Protection verification pending").font(.caption).foregroundStyle(.secondary)
                }
            }.multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            pillRow
            Divider().overlay(VSDesign.separator)
            Menu {
                ForEach(store.profiles) { profile in
                    Button { store.selectProfile(profile) } label: {
                        if store.selected == profile.id && store.selectedManualProfile == nil { Label(profile.name, systemImage: "checkmark") } else { Text(profile.name) }
                    }
                }
                ForEach(store.manualDrafts) { draft in
                    Button {
                        if tunnel.running { store.notice = "Disconnect the VPN before switching to an \(draft.protocolKind == .ikev2 ? "IKEv2" : "OpenVPN") profile." }
                        else if draft.protocolKind != .ikev2 { store.notice = "OpenVPN is unavailable while its engine and licensing are on hold." }
                        else { store.selectManual(draft) }
                    } label: {
                        if store.selectedManualProfile == draft.id { Label(draft.name, systemImage: "checkmark") } else { Text(draft.name) }
                    }
                }
                Button { store.selectNoVPNProfile() } label: {
                    if store.selected == nil && store.selectedManualProfile == nil { Label("No VPN profile (DNS only)", systemImage: "checkmark") } else { Text("No VPN profile (DNS only)") }
                }
                Divider()
                Button { openProfilesTab?() } label: { Label(store.profiles.isEmpty ? "Add VPN Profile" : "Manage Profiles", systemImage: "gearshape") }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "key.horizontal").font(.system(size: 18)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.connectionName ?? "No VPN profile selected").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Text(store.connectionName == nil ? "Choose a profile" : store.connectionProtocol).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(VSPlainButtonStyle()).accessibilityIdentifier("HomeProfileSelector")
        }.padding(14).frame(maxWidth: .infinity).frame(minHeight: 0)
            .background(VSDesign.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(VSDesign.separator, lineWidth: 1))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: connectionLabel)
    }
    var hero: some View {
        connectionCard
    }
    var configuration: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("YOUR CONNECTION").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 14)
            #if os(macOS)
            NavigationLink { VSProfilesScreen(store: store, tunnel: tunnel) } label: { VSRow(title: store.active?.name ?? (store.dnsOnlyChosen ? "No VPN profile" : "Add a VPN profile"), subtitle: store.active?.endpoints.first ?? (store.dnsOnlyChosen ? "DNS only · local DNS tunnel" : "Import a WireGuard configuration"), icon: "key.horizontal", chevron: true) }.buttonStyle(VSPlainButtonStyle())
            Divider().padding(.vertical, 12)
            #endif
            NavigationLink { VSDNSScreen(store: store, tunnel: tunnel) } label: { VSRow(title: store.endpoint.isEmpty ? "Add a DNS resolver" : store.dnsName, subtitle: store.endpoint.isEmpty ? "Use your encrypted DNS provider" : DNSService.transport(store.endpoint) + " · identity unverified", icon: "network", chevron: true) }.buttonStyle(VSPlainButtonStyle())
            Divider().padding(.vertical, 12)
            NavigationLink { VSModeScreen(store: store, tunnel: tunnel) } label: { VSRow(title: "VPN → DNS", subtitle: "DNS and website traffic use the VPN", icon: "arrow.triangle.branch", chevron: true) }.buttonStyle(VSPlainButtonStyle())
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(VSDesign.surface, in: RoundedRectangle(cornerRadius: 12))
    }
    func metric(_ title: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 6) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.subheadline.weight(.medium)).monospacedDigit() }.frame(maxWidth: .infinity, alignment: .leading) }
    func rate(_ value: Double) -> String { tunnel.ratesAvailable ? String(format: "%.2f Mbps", value * 8 / 1_000_000) : "Unavailable" }
    func bytes(_ value: UInt64?) -> String { value.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .binary) } ?? "—" }
}
struct VSSettingsScreen: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    @AppStorage("appearance") private var appearance = "dark"
    @AppStorage("live-activity-enabled") private var liveActivityEnabled = false
    @State private var resetting = false
    @StateObject private var checksNetwork = NetworkDiagnostics()
    @State private var removing = false
    var locked: Bool { tunnel.running || tunnel.busy || store.connectionOperation }
    var body: some View {
        AnyView(VSCardList {
            VSSection {
                VSNavLink { VSProtectionPermissionsScreen(store: store, tunnel: tunnel) } label: { VSRow(title: "Permissions", subtitle: "VPN, Safari, DNS and notifications", icon: "hand.raised") }
                VSNavLink { VSModeScreen(store: store, tunnel: tunnel) } label: { VSRow(title: "Protection modes", icon: "arrow.triangle.branch", value: store.savedModeTitle) }
                VSNavLink { VSPrivacyLockScreen(store: store, tunnel: tunnel) } label: { VSRow(title: "Privacy Lock & connection rules", subtitle: "Strict routing, on-demand, local network", icon: "shield.lefthalf.filled") }
                Toggle("Connect on launch", isOn: $store.connectOnLaunch)
                Toggle("Automatic reconnect", isOn: Binding(get: { tunnel.autoReconnect }, set: { tunnel.autoReconnect = $0; UserDefaults.standard.set($0, forKey: "auto-reconnect") }))
            } header: { Text("Protection") } footer: { Text("Strict routing also enables on-demand and captures local-network, push-notification and internet-routable cellular-service traffic. Calling, notifications and local devices may be affected. Changes apply on the next connection, and leak protection still needs independent verification.") }
            VSSection {
                Toggle("Connection notifications", isOn: Binding(get: { tunnel.notificationsEnabled }, set: { tunnel.setNotifications($0) }))
                #if os(iOS)
                Toggle("Dynamic Island notifications", isOn: $liveActivityEnabled)
                #endif
                VSNavLink { VSNotificationsScreen(tunnel: tunnel) } label: { Text("Notification details") }
            } header: { Text("Notifications") } footer: { Text("The Dynamic Island and Lock Screen briefly announce VPN connected or disconnected, DNS-only connected, and Adblock activated. iOS only lets VayuSetu show them while the app is open.") }
            VSSection("Appearance") { VSNavLink { VSAppearanceScreen() } label: { Text("Appearance & accessibility") } }
            VSSection("Diagnostics") {
                VSNavLink { VSChecksScreen(store: store, tunnel: tunnel, network: checksNetwork) } label: { VSRow(title: "Checks", subtitle: "IP, DNS, route and network evidence", icon: "waveform.path.ecg") }
                VSNavLink { VSLogsScreen(tunnel: tunnel) } label: { VSRow(title: "Connection logs", icon: "text.alignleft") }
                VSNavLink { VSTrafficScreen(store: store, tunnel: tunnel) } label: { VSRow(title: "Traffic & sessions", icon: "arrow.up.arrow.down") }
                VSNavLink { VSActivityScreen(filtering: store.filtering, tunnel: tunnel) } label: { VSRow(title: "Privacy activity", icon: "clock") }
                VSNavLink { VSConflictsScreen(store: store, tunnel: tunnel) } label: { VSRow(title: "Compatibility", subtitle: "What each connection can do, and conflicts", icon: "exclamationmark.triangle") }
                VSNavLink { VSExtensionStatusScreen(store: store, tunnel: tunnel) } label: { VSRow(title: "Extension status", icon: "puzzlepiece.extension") }
            }
            VSSection("Data") {
                VSNavLink { VSPrivacyScreen(filtering: store.filtering) } label: { VSRow(title: "Data & logging", subtitle: "What is kept on this device", icon: "hand.raised") }
                VSNavLink { VSCardList { VSSection { BackupPanel(store: store, tunnel: tunnel) } }.vsList().vsHeader("Encrypted Backups") } label: { VSRow(title: "Encrypted backups", icon: "externaldrive") }
            }
            VSSection("Advanced") {
                VSNavLink { VSSecurityCenter(store: store, tunnel: tunnel) } label: { VSRow(title: "Security Center", subtitle: "Egress checks, provider filters, hardening", icon: "lock.shield") }
                VSNavLink { VSCardList { VSSection { RetryPreferences(tunnel: tunnel, store: store) } }.vsHeader("Connection Recovery") } label: { VSRow(title: "Connection recovery", subtitle: "Retries and timeouts", icon: "arrow.clockwise") }
                VSNavLink { VSEmergencyResetScreen(store: store, tunnel: tunnel) } label: { VSRow(title: "Emergency reset", icon: "arrow.counterclockwise") }
                Button("Remove Saved VPN Configuration", role: .destructive) { removing = true }.disabled(locked)
            }
            VSSection("About") { VSRow(title: "VayuSetu", subtitle: "By R3dby", value: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "Development"); VSNavLink { VSCheckDetail(title: "Acknowledgements", explanation: "VayuSetu uses the WireGuard backend. Credentials are retained in this device’s Keychain.", output: notices) } label: { Text("Acknowledgements") }; VSNavLink { VSFilterCreditsScreen() } label: { Text("Filter list credits") } }
        }.vsList().vsHeader("Settings")
        .vsConfirm(isPresented: $resetting, title: "Disable VayuSetu VPN and DNS?", message: "This stops automatic reconnect and removes managed VPN/DNS configuration. Profiles and keys are preserved. Safari filtering is controlled separately.", confirm: "Emergency Reset", destructive: true, icon: "power") { Task { await store.emergencyReset() } }
        .vsConfirm(isPresented: $removing, title: "Remove the saved VPN configuration?", message: "Your imported profiles and keys remain available.", confirm: "Remove", destructive: true, icon: "trash.fill") { Task { do { try await tunnel.removeConfiguration() } catch { store.notice = error.localizedDescription } } })
    }
    var notices: String { Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "WireGuard · https://www.wireguard.com" }
}

private struct ControlDProfile: Identifiable, Hashable {
    let id: String
    let name: String
}
private struct ControlDFilter: Identifiable, Hashable {
    let id: String
    let name: String
    var enabled: Bool
}

/// API token is held in this app's default Keychain service, never in the tunnel's shared access group.
@MainActor private final class ControlDProtectionModel: ObservableObject {
    @Published var tokenDraft = ""
    @Published var profiles: [ControlDProfile] = []
    @Published var selectedProfile = ""
    @Published var filters: [ControlDFilter] = []
    @Published var busy = false
    @Published var message = ""
    private var token: String?

    init() {
        if let data = try? Self.readToken(), let value = String(data: data, encoding: .utf8) {
            token = value
            Task { await refreshProfiles() }
        }
    }
    func saveToken() {
        let value = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 16, value.utf8.count <= 512 else { message = "Enter a valid Control D API token."; return }
        do {
            try Self.writeToken(Data(value.utf8)); token = value; tokenDraft = ""
            message = "Token stored in this app’s Keychain."; Task { await refreshProfiles() }
        } catch { message = "Could not store the token in Keychain." }
    }
    func removeToken() {
        do { try Self.deleteToken(); token = nil; profiles = []; filters = []; selectedProfile = ""; message = "Control D API token removed." }
        catch { message = "Could not remove the saved token." }
    }
    func refreshProfiles() async {
        guard let token else { message = "Add a Control D API token to load profiles."; return }
        busy = true; defer { busy = false }
        do {
            let data = try await ControlDAPI.request(path: "/profiles", token: token)
            profiles = try ControlDAPI.profiles(data)
            if !profiles.contains(where: { $0.id == selectedProfile }) { selectedProfile = profiles.first?.id ?? "" }
            message = profiles.isEmpty ? "No profiles returned by Control D." : "Profiles loaded. Choose the profile used by this resolver."
            if !selectedProfile.isEmpty { await refreshFilters() }
        } catch { message = error.localizedDescription }
    }
    func refreshFilters() async {
        guard let token, !selectedProfile.isEmpty,
              let safeID = selectedProfile.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) else { return }
        busy = true; defer { busy = false }
        do {
            let data = try await ControlDAPI.request(path: "/profiles/\(safeID)/filters", token: token)
            filters = try ControlDAPI.filters(data)
            message = "Filter states refreshed from Control D."
        } catch { message = error.localizedDescription }
    }
    func set(_ filter: ControlDFilter, enabled: Bool) {
        guard let token, !selectedProfile.isEmpty else { return }
        Task { @MainActor in
            busy = true; defer { busy = false }
            do {
                let profile = try ControlDAPI.pathComponent(selectedProfile)
                let key = try ControlDAPI.pathComponent(filter.id)
                try await ControlDAPI.update(profile: profile, filter: key, enabled: enabled, token: token)
                await refreshFilters()
            } catch { message = error.localizedDescription }
        }
    }
    private static func query() throws -> [String: Any] {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "VayuAppKeychainGroup") as? String, !group.isEmpty else {
            throw AppIssue(message: "The app-only Keychain entitlement is unavailable in this build.")
        }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.vayusetu.controld", kSecAttrAccount as String: "controld-api-write-token", kSecAttrAccessGroup as String: group]
    }
    private static func readToken() throws -> Data? {
        var q = try query(); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }; guard status == errSecSuccess else { throw AppIssue(message: "Keychain read failed.") }; return item as? Data
    }
    private static func writeToken(_ data: Data) throws {
        let fields: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let key = try query()
        let status = SecItemUpdate(key as CFDictionary, fields as CFDictionary)
        if status == errSecItemNotFound { var add = key; fields.forEach { add[$0] = $1 }; guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw AppIssue(message: "Keychain write failed.") } }
        else if status != errSecSuccess { throw AppIssue(message: "Keychain write failed.") }
    }
    private static func deleteToken() throws { let status = SecItemDelete(try query() as CFDictionary); if status != errSecSuccess && status != errSecItemNotFound { throw AppIssue(message: "Keychain delete failed.") } }
}

private enum ControlDAPI {
    private static let origin = URL(string: "https://api.controld.com")!
    private static let allowedFilters: [String: String] = ["ads": "Ads & Trackers", "malware": "Malware", "typo": "Phishing", "nrd": "New Domains"]
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    static func pathComponent(_ text: String) throws -> String {
        guard !text.isEmpty, text.utf8.count <= 128, text.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ .")).contains($0) }), !text.contains("..") else { throw AppIssue(message: "Control D returned an invalid profile or filter identifier.") }
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) else { throw AppIssue(message: "Invalid Control D identifier.") }
        return encoded
    }
    static func request(path: String, token: String) async throws -> Data { try await send(path: path, token: token, body: nil) }
    static func update(profile: String, filter: String, enabled: Bool, token: String) async throws {
        let body = Data("status=\(enabled ? 1 : 0)".utf8)
        _ = try await send(path: "/profiles/\(profile)/filters/filter/\(filter)", token: token, body: body)
    }
    private static func send(path: String, token: String, body: Data?) async throws -> Data {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), let url = URL(string: path, relativeTo: origin)?.absoluteURL,
              url.scheme == "https", url.host == origin.host, url.port == nil else { throw AppIssue(message: "Invalid Control D API request.") }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.httpMethod = body == nil ? "GET" : "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body { request.httpBody = body; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type") }
        let blocker = NoRedirect(); let session = URLSession(configuration: .ephemeral, delegate: blocker, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard data.count <= 1_000_000, let http = response as? HTTPURLResponse, http.url?.host == origin.host, (200..<300).contains(http.statusCode) else {
            throw AppIssue(message: "Control D API request failed. Check token permission, account access and profile selection.")
        }
        return data
    }
    static func profiles(_ data: Data) throws -> [ControlDProfile] {
        let rows = dictionaries(try JSONSerialization.jsonObject(with: data))
        let values = rows.compactMap { row -> ControlDProfile? in
            guard let id = string(row, keys: ["pk", "id"]), let name = string(row, keys: ["name", "label"]) else { return nil }
            return ControlDProfile(id: id, name: name)
        }
        let unique = Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard !unique.isEmpty else { throw AppIssue(message: "Control D returned no recognizable profiles.") }
        return unique.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    static func filters(_ data: Data) throws -> [ControlDFilter] {
        let root = try JSONSerialization.jsonObject(with: data)
        let rows = dictionaries(root)
        var found: [String: ControlDFilter] = [:]
        for row in rows {
            guard let id = string(row, keys: ["pk", "key", "id"]), let name = allowedFilters[id.lowercased()],
                  let raw = value(row, keys: ["status", "enabled", "active"]), let enabled = bool(raw) else { continue }
            found[id.lowercased()] = ControlDFilter(id: id.lowercased(), name: name, enabled: enabled)
        }
        collectMappedFilters(root, into: &found)
        guard !found.isEmpty else { throw AppIssue(message: "Control D returned an unsupported filter response.") }
        return found.values.sorted { $0.name < $1.name }
    }
    private static func collectMappedFilters(_ node: Any, into found: inout [String: ControlDFilter]) {
        if let object = node as? [String: Any] {
            for (key, raw) in object {
                let identifier = key.lowercased()
                if let name = allowedFilters[identifier] {
                    let stateValue: Any
                    if let state = raw as? [String: Any], let nested = value(state, keys: ["status", "enabled", "active"]) { stateValue = nested }
                    else { stateValue = raw }
                    if let enabled = bool(stateValue) { found[identifier] = ControlDFilter(id: identifier, name: name, enabled: enabled) }
                }
                collectMappedFilters(raw, into: &found)
            }
        } else if let array = node as? [Any] {
            array.forEach { collectMappedFilters($0, into: &found) }
        }
    }
    private static func dictionaries(_ value: Any) -> [[String: Any]] {
        if let dict = value as? [String: Any] { return [dict] + dict.values.flatMap(dictionaries) }
        if let array = value as? [Any] { return array.flatMap(dictionaries) }
        return []
    }
    private static func value(_ row: [String: Any], keys: [String]) -> Any? { for key in keys { if let value = row.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value { return value } }; return nil }
    private static func string(_ row: [String: Any], keys: [String]) -> String? { if let value = value(row, keys: keys) as? String { return value }; if let value = value(row, keys: keys) as? NSNumber { return value.stringValue }; return nil }
    private static func bool(_ value: Any) -> Bool? {
        if let number = value as? NSNumber { return number.intValue == 0 ? false : number.intValue == 1 ? true : nil }
        if let text = value as? String { switch text.lowercased() { case "1", "true", "on", "enabled": return true; case "0", "false", "off", "disabled": return false; default: return nil } }
        return nil
    }
}

private struct ObserverReply: Decodable { let nonce: String; let address: String }
private final class ObserverSession: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct VSSecurityCenter: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    @StateObject private var controlD = ControlDProtectionModel()
    @State private var observerURL = UserDefaults.standard.string(forKey: "security-observer-url") ?? ""
    @State private var observerMessage = "Not configured"
    @State private var observerRunning = false
    @State private var observerAddress = ""
    @State private var expectedExit = UserDefaults.standard.string(forKey: "security-observer-expected-exit") ?? ""
    private var hasControlD: Bool {
        guard let host = URL(string: store.endpoint)?.host?.lowercased() else { return false }
        return host == "controld.com" || host.hasSuffix(".controld.com")
    }
    var body: some View {
        VSCardList {
            VSSection("Connection protection") {
                VSRow(title: "Tunnel", subtitle: tunnel.statusText, icon: "network.badge.shield.half.filled")
                VSNavLink { VSSecurityInsightsScreen(store: store, tunnel: tunnel) } label: { VSRow(title: "Security insights", subtitle: "Local evidence, recovery state and limitations", icon: "sparkles", chevron: true) }
                VSNavLink { VSNetworkCoverageScreen(tunnel: tunnel) } label: { VSRow(title: "Traffic routed outside the tunnel", subtitle: "Review configured and OS-required exceptions", icon: "arrow.triangle.branch", chevron: true) }
                Text("On-demand reconnect is enabled for strict routing. iOS still keeps some network-control and captive-portal traffic outside a personal packet tunnel.").font(.footnote).foregroundStyle(.secondary)
            }
            VSSection {
                TextField("https://your-domain.example", text: $observerURL)
                TextField("Expected VPN exit IP (optional)", text: $expectedExit)
                HStack { Button("Save endpoint") { saveObserver() }.disabled(!validObserverURL); Button(observerRunning ? "Checking…" : "Observe this connection") { Task { await runObserver() } }.disabled(observerRunning || !validObserverURL) }
                Text(observerMessage).font(.footnote).foregroundStyle(observerMessage.contains("mismatch") ? .orange : .secondary)
                if !observerAddress.isEmpty { VSRow(title: "Observer saw", icon: "globe", value: observerAddress) }
                Text("This samples the VayuSetu app’s HTTPS path to a server you control. It is not a device-wide leak test and does not prove DNS routing. A controlled endpoint and a VPN exit address from your provider are needed for a useful comparison.").font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Failure and egress checks") }
            VSSection {
                if !hasControlD { Text("The selected resolver is not recognized as Control D. Provider controls are unavailable for this resolver.").font(.footnote).foregroundStyle(.secondary) }
                SecureField("Control D API token", text: $controlD.tokenDraft)
                HStack { Button("Save token and load profiles") { controlD.saveToken() }.disabled(controlD.tokenDraft.isEmpty || controlD.busy || !hasControlD); Button("Remove token", role: .destructive) { controlD.removeToken() } }
                if !controlD.profiles.isEmpty {
                    Picker("Control D profile", selection: $controlD.selectedProfile) { ForEach(controlD.profiles) { Text($0.name).tag($0.id) } }.onChange(of: controlD.selectedProfile) { _, _ in Task { await controlD.refreshFilters() } }.disabled(controlD.busy)
                    ForEach(controlD.filters) { filter in Toggle(filter.name, isOn: Binding(get: { filter.enabled }, set: { controlD.set(filter, enabled: $0) })).disabled(controlD.busy || !hasControlD) }
                    Button("Refresh provider state") { Task { await controlD.refreshProfiles() } }.disabled(controlD.busy)
                }
                if !controlD.message.isEmpty { Text(controlD.message).font(.footnote).foregroundStyle(.secondary) }
                Text("Control D API tokens are account credentials. Use a write token only if you want VayuSetu to change filters; the provider currently offers broad read or write token scopes. Tokens stay in this app’s Keychain and are sent only to api.controld.com. Match the selected API profile to the resolver endpoint you use.").font(.footnote).foregroundStyle(.secondary)
            } header: { Text("DNS threat filters") } footer: { Text("Available categories depend on the provider profile. DNS filters cannot block every tracker, direct-IP connection or in-app content.") }
            VSSection("Managed Always On VPN") {
                Text("The personal WireGuard app cannot turn itself into Apple’s device-managed Always On VPN. Apple’s managed Always On configuration requires an organization’s device-management enrollment and IKEv2. It can block general traffic while the managed tunnel is down, subject to system exceptions.").font(.footnote)
                Text("For an organization deployment, ask its device-management administrator for an IKEv2 profile and server support. Do not import a placeholder profile or share VPN credentials here.").font(.footnote).foregroundStyle(.secondary)
                Link("Apple VPN deployment guide", destination: URL(string: "https://support.apple.com/guide/deployment/vpn-overview-depae3d361d0/1/web/1.0")!)
                Link("Apple IKEv2 configuration", destination: URL(string: "https://developer.apple.com/documentation/networkextension/nevpnprotocolikev2")!)
                Text("On supported OS and server configurations, IKEv2 can use Apple-supported post-quantum key exchange or PPK options. This is not enabled by VayuSetu’s current WireGuard profile and requires a matching server.").font(.footnote).foregroundStyle(.secondary)
            }
            VSSection("Targeted-device protection") {
                Text("A VPN protects network traffic; it cannot protect a compromised phone, account or trusted endpoint.").font(.footnote)
                Link("How Apple Lockdown Mode works", destination: URL(string: "https://support.apple.com/en-us/105120")!)
                Text("To review it: iPhone Settings → Privacy & Security → Lockdown Mode. Enable it only if its feature restrictions fit your needs; VayuSetu cannot read or switch this system setting.").font(.footnote).foregroundStyle(.secondary)
                Link("Apple Platform Security", destination: URL(string: "https://support.apple.com/guide/security/welcome/web")!)
            }
        }.vsList().vsHeader("Security Center")
    }
    private var validObserverURL: Bool {
        guard let url = URL(string: observerURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil && (url.path.isEmpty || url.path == "/") && (url.port == nil || url.port == 443)
    }
    private func saveObserver() {
        guard validObserverURL else { observerMessage = "Enter a valid HTTPS observer URL on port 443."; return }
        UserDefaults.standard.set(observerURL, forKey: "security-observer-url")
        UserDefaults.standard.set(expectedExit, forKey: "security-observer-expected-exit")
        observerMessage = "Saved. Results remain a sampled app connection only."
    }
    @MainActor private func runObserver() async {
        guard validObserverURL, let base = URL(string: observerURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { observerMessage = "Enter a valid HTTPS observer URL."; return }
        observerRunning = true; observerAddress = ""; defer { observerRunning = false }
        do {
            var nonceBytes = [UInt8](repeating: 0, count: 24); let status = SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes)
            guard status == errSecSuccess else { throw AppIssue(message: "Could not create a fresh probe nonce.") }
            let nonce = nonceBytes.map { String(format: "%02x", $0) }.joined()
            var url = base.appendingPathComponent("v1/observe")
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false); parts?.queryItems = [URLQueryItem(name: "nonce", value: nonce)]
            guard let requestURL = parts?.url, requestURL.host == base.host, requestURL.scheme == "https" else { throw AppIssue(message: "Invalid observer URL.") }
            url = requestURL
            var request = URLRequest(url: url, timeoutInterval: 10); request.httpMethod = "GET"; request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            let blocker = ObserverSession(); let session = URLSession(configuration: .ephemeral, delegate: blocker, delegateQueue: nil); defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            guard data.count <= 4096, let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.host == base.host,
                  let result = try? JSONDecoder().decode(ObserverReply.self, from: data), result.nonce == nonce,
                  let canonical = ExitComparison.canonical(result.address, family: ProfileParser.ipFamily(result.address) ?? 0) else { throw AppIssue(message: "Observer response failed verification. Check that it is your current VayuSetu observer.") }
            observerAddress = canonical
            let expected = expectedExit.trimmingCharacters(in: .whitespacesAndNewlines)
            if !expected.isEmpty, ExitComparison.canonical(expected, family: ProfileParser.ipFamily(expected) ?? 0) != canonical { observerMessage = "Observed address differs from the expected VPN exit · investigate. This sample is not a device-wide leak verdict." }
            else { observerMessage = "Observer returned a fresh response · \(tunnel.statusText). This sample does not prove device-wide isolation." }
        } catch { observerMessage = error is URLError ? "Observer unavailable on this route. That alone does not prove the tunnel failed." : error.localizedDescription }
    }
}

struct VSSecurityInsightsScreen: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    private var snapshots: [ProtectionSnapshot] { ProtectionSubsystem.allCases.map { store.protection($0) } }
    var body: some View {
        VSCardList {
            VSSection("Observed protection") {
                ForEach(snapshots, id: \.subsystem) { snapshot in
                    VSRow(title: snapshot.subsystem.rawValue.uppercased(), subtitle: snapshot.reason, icon: snapshot.observed == .active ? "checkmark.shield.fill" : "exclamationmark.shield.fill", value: snapshot.label)
                }
                Text("A green state reflects the strongest evidence VayuSetu has observed. Configuration alone never becomes a verified result.").font(.footnote).foregroundStyle(.secondary)
            }
            VSSection("Recovery posture") {
                VSRow(title: "Tunnel stage", subtitle: tunnel.stage.rawValue, icon: "arrow.clockwise", value: tunnel.statusText)
                VSRow(title: "Automatic reconnect", subtitle: "Retries are bounded and revalidated after network changes.", icon: "repeat", value: tunnel.autoReconnect ? "On" : "Off")
                VSRow(title: "Evidence", subtitle: "Run Connection Verification after Wi-Fi, cellular, sleep/wake or profile changes.", icon: "checkmark.circle", value: "Review")
            }
            VSSection("Known platform boundaries") {
                Text("iOS does not expose arbitrary per-app packet inspection or a universal process-level firewall. Safari filtering is declarative, and apps that implement their own DNS or use Apple-reserved control traffic may bypass parts of the observed path.").font(.footnote)
                Text("Use the verification screens and a controlled observer to validate the current route. VayuSetu does not claim that a saved VPN profile alone proves leak isolation.").font(.footnote).foregroundStyle(.secondary)
            }
        }.vsList().vsHeader("Security Insights")
    }
}

private struct VSNetworkCoverageScreen: View {
    @ObservedObject var tunnel: TunnelController
    var body: some View {
        VSCardList {
            VSSection("Saved VayuSetu policy") { Text(tunnel.trafficExceptionSummary).font(.system(.footnote, design: .monospaced)).textSelection(.enabled) }
            VSSection("Always outside a personal packet tunnel") {
                Text("Apple excludes network-control traffic (such as DHCP), captive-portal negotiation, certain carrier-only services, and traffic for companion devices such as Apple Watch.").font(.footnote)
            }
            VSSection { Link("Apple: VPN traffic routing and exceptions", destination: URL(string: "https://developer.apple.com/documentation/networkextension/routing-your-vpn-network-traffic")!) }
            VSSection { Text("These are saved configuration values, not proof that every packet followed the intended path. Confirm behavior with a controlled observer on Wi-Fi, cellular, and tunnel failure.").font(.footnote).foregroundStyle(.secondary) }
        }.vsList().vsHeader("Routing Exceptions")
    }
}

/// A code-native power mark with rounded terminals at every display scale.
private struct VSHomePowerMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.05)
        path.addArc(center: center, radius: rect.width * 0.40,
                    startAngle: .degrees(-55), endAngle: .degrees(235), clockwise: false)
        path.move(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.02))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.midY - rect.height * 0.10))
        return path
    }
}

/// Compact mode selector. Choosing while protection is off only saves the next start-up mode, unless the sheet was opened by a
/// first power tap. Choosing while protection is on offers "Switch Now" or "Use Next Time".
struct VSProtectionModeSheet: View {
    @ObservedObject var store: AppStore
    var connectsAfterChoosing: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var picked: String?
    @State private var asking: Option?
    fileprivate struct Option: Identifiable { let id: String; let title: String; let detail: String; let icon: String; let vpn: Bool; let dns: Bool; var safariOnly = false }
    /// Descriptions name the resolver the user actually selected; local blocklists only apply with VayuSetu DNS.
    private var options: [Option] {
        let resolver = store.dnsName.isEmpty ? "your selected DNS resolver" : store.dnsName
        let lists = store.isVayuSetuDNSSelected ? " with VayuSetu filter lists" : ""
        return [
            Option(id: "vpnDNS", title: "VPN + DNS", detail: "Imported VPN with encrypted DNS: \(resolver)\(lists).", icon: "shield.lefthalf.filled", vpn: true, dns: true),
            Option(id: "vpn", title: "VPN Only", detail: "Connect using the selected VPN profile and its own DNS settings.", icon: "lock.shield", vpn: true, dns: false),
            Option(id: "dns", title: "DNS Only", detail: "Local DNS protection with \(resolver)\(lists). No imported VPN profile required.", icon: "network", vpn: false, dns: true),
            Option(id: "adblock", title: "Adblock Only", detail: "Block ads and trackers in Safari. No VPN and no DNS protection.", icon: "hand.raised", vpn: false, dns: false, safariOnly: true)
        ]
    }
    private var currentID: String? {
        let mode = store.savedNetwork
        if !store.networkActive && store.adblockPill != .off && !store.powerModeChosen { return "adblock" }
        return options.first { !$0.safariOnly && $0.vpn == mode?.vpn && $0.dns == mode?.dns }?.id
    }
    /// The planner's own caveat for this combination, so limits are shown only when they really apply.
    private func note(_ option: Option) -> String? {
        if option.vpn && store.selectedVPNKind == nil && store.profiles.count != 1 { return "Choose a VPN profile in Profiles first." }
        var target = store.selection; target.vpnEnabled = option.vpn; target.dnsEnabled = option.dns
        var request = store.request(for: target)
        if option.vpn && request.vpn == nil { request.vpn = .wireGuard }
        switch ProtectionPlanner.plan(request) {
        case .failure(let issue): return issue.message
        case .success(let plan): return plan.limitations.first
        }
    }
    private func choose(_ option: Option) {
        picked = option.id
        if option.safariOnly {
            // Adblock needs no tunnel, so it applies immediately; any running tunnel is turned off by the planner's own confirmation.
            Task { await store.chooseMode(vpn: false, dns: false, safari: true) }; dismiss(); return
        }
        if store.networkActive { asking = option }
        else if connectsAfterChoosing { Task { await store.chooseMode(vpn: option.vpn, dns: option.dns) }; dismiss() }
        else { store.saveMode(vpn: option.vpn, dns: option.dns); dismiss() }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Choose how VayuSetu protects this device. You can change it any time.").font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 4).padding(.bottom, 4)
                    ForEach(options) { option in
                        let selected = (picked ?? currentID) == option.id
                        Button { choose(option) } label: {
                            HStack(spacing: 14) {
                                Image(systemName: option.icon).font(.system(size: 20, weight: .semibold)).foregroundStyle(selected ? Color.white : VSDesign.accent)
                                    .frame(width: 46, height: 46)
                                    .background(selected ? AnyShapeStyle(VSDesign.accent) : AnyShapeStyle(VSDesign.accent.opacity(0.14)), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(option.title).font(.headline).foregroundStyle(.primary)
                                    Text(option.detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    if let text = note(option) { Text(text).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                                }
                                Spacer(minLength: 6)
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 22)).foregroundStyle(selected ? VSDesign.accent : Color.secondary.opacity(0.4))
                            }
                            .padding(14).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            .background(VSSheet.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(selected ? VSDesign.accent.opacity(0.8) : Color.white.opacity(0.07), lineWidth: selected ? 1.5 : 1))
                            .shadow(color: selected ? VSDesign.accent.opacity(0.25) : .clear, radius: 12, y: 4)
                        }.buttonStyle(VSPlainButtonStyle()).accessibilityIdentifier("Mode-" + option.id)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                    Toggle(isOn: Binding(get: { store.adblockPill != .off }, set: { _ in Task { await store.togglePill(.adblock) } })) {
                        HStack(spacing: 14) {
                            Image(systemName: "hand.raised").font(.system(size: 20, weight: .semibold)).foregroundStyle(VSDesign.accent)
                                .frame(width: 46, height: 46).background(VSDesign.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Adblock in Safari").font(.headline)
                                Text("Add or remove Safari blocking with any mode above.").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(14).background(VSSheet.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
                        .padding(.top, 8).accessibilityIdentifier("Mode-adblock-toggle")
                    Text("Safari adblocking works with every mode and has its own switch on Home.").font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
                }.padding(.horizontal, 16).padding(.bottom, 24)
            }.vsHeader("Network Protection")
                .toolbar { ToolbarItem(placement: .cancellationAction) { VSCloseButton { dismiss() } } }
                .vsDialog(isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }), tone: .info, icon: "arrow.triangle.2.circlepath", title: "Change mode now?", message: "Switching to \(asking?.title ?? "this mode") briefly interrupts protection while the tunnel changes.",
                          actions: asking.map { option in [
                            VSDialogAction(title: "Switch Now", kind: .primary, run: { Task { await store.chooseMode(vpn: option.vpn, dns: option.dns) }; dismiss() }),
                            VSDialogAction(title: "Use Next Time", kind: .plain, run: { store.saveMode(vpn: option.vpn, dns: option.dns); dismiss() }),
                            VSDialogAction(title: "Cancel", kind: .cancel, run: { picked = nil })] } ?? [])
        }
    }
}

/// This device's own Wi-Fi/cellular speed, sampled once a second while Home is on screen. Reads local interface counters only; nothing is sent anywhere.
@MainActor final class LiveDeviceSpeed: ObservableObject {
    @Published private(set) var down: Double?
    @Published private(set) var up: Double?
    private var meter = InterfaceSpeedMeter()
    private var task: Task<Void, Never>?
    init() { start() }
    deinit { task?.cancel() }
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                if let self, let sample = self.meter.sample() { self.down = sample.down; self.up = sample.up }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
