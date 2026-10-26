import AppKit
import SwiftUI
import VayuSetuCore

/// Home for the Mac: a status column on the left (power, mode, the three protections) and the live picture on the right.
/// It uses the same store, the same mode logic and the same power behaviour as the iPhone's Home.
struct MacHome: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    @ObservedObject var network: NetworkDiagnostics
    @ObservedObject var filter: FilterClient
    @Environment(\.extensionManager) private var extensionManager
    @Environment(\.wifiWatcher) private var wifiWatcher
    @ObservedObject private var tamper = TamperMonitor.shared
    /// Prepares the VPN extension, then runs the action.
    let activate: (@escaping () -> Void) -> Void
    /// Not observed here: the live meter changes every second and would redraw all of Home. The two panels that show it observe it themselves.
    private let speed = SpeedTracker.shared
    @State private var hoveringPower = false
    @State private var showingModes = false
    @State private var modeConnects = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openProfilesTab) private var openProfiles
    @Environment(\.openDNSTab) private var openDNS

    private var connected: Bool { tunnel.status == .connected }
    private var accent: Color {
        switch store.powerTone {
        case .off: return .secondary
        case .dnsOnly: return Color(red: 0.0, green: 0.78, blue: 0.82)
        case .vpnOnly: return VSDesign.accent
        case .vpnWithDNS: return Color(red: 0.196, green: 0.839, blue: 0.627)
        case .busy: return .orange
        case .error: return .red
        }
    }
    private var label: String {
        guard tunnel.ready else { return "Checking" }
        if tunnel.status == .disconnecting { return "Disconnecting" }
        if tunnel.status == .reasserting || tunnel.stage == .reconnecting { return "Reconnecting" }
        if tunnel.busy || tunnel.status == .connecting { return "Connecting" }
        if tunnel.stage == .failed || tunnel.stage == .blocked { return "Connection failed" }
        if connected && tunnel.localDNSRunning { return store.dnsPill == .active ? "Protection active" : "DNS up · not verified" }
        return connected ? "Protection active" : "Disconnected"
    }
    private var headline: String {
        if connected || store.observedMode != .off { return store.observedMode.title }
        return "Network protection is off"
    }

    var body: some View {
        MacPage(title: "Home", subtitle: "Your private connection, on your terms.") {
            if let wifiWatcher { MacWiFiSuggestionCard(watcher: wifiWatcher, store: store) }
            if let extensionManager { MacSetupGuide(store: store, tunnel: tunnel, filter: filter, extensions: extensionManager) }
            MacPanelLayout {
                powerPanel
                MacPanel("Your route", icon: "point.topleft.down.to.point.bottomright.curvepath", trailing: { ScenePauseButton() }) { MacRouteScene(store: store, tracker: speed) }
                protectionsPanel
                MacSpeedPanel(store: store, tunnel: tunnel, tracker: speed)
                connectionPanel
                livePanel
            }
            MacProtectionProof(store: store, tunnel: tunnel, filter: filter)
            VSHomeActivityPanel(filtering: store.filtering)
            MacFailureDetails(tunnel: tunnel, store: store)
            if let warning = tamper.verdict.message { Label(warning, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange).textSelection(.enabled) }
            if !tunnel.message.isEmpty, tunnel.running || tunnel.stage != .failed { Label(tunnel.message, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.orange).textSelection(.enabled) }
            if !TunnelController.available { Text("This copy cannot activate a VPN. Open the signed VayuSetu app from Applications.").font(.footnote).foregroundStyle(.secondary) }
        }
        .onAppear { SpeedTracker.shared.start(mode: { [store] in store.speedMode }, profile: { [store] in store.selected.map { SpeedBestKey.token($0.uuidString) } }) }
        .sheet(isPresented: $showingModes) { MacModeSheet(store: store, connectsAfterChoosing: modeConnects, activate: activate).frame(width: 460) }
    }

    // MARK: Power and mode
    private var powerPanel: some View {
        VStack(spacing: 18) {
            HStack(spacing: 7) { Circle().fill(accent).frame(width: 7, height: 7); Text(label.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundStyle(accent) }
            Button { power() } label: {
                ZStack {
                    Circle().stroke(accent.opacity(0.18), lineWidth: 1).frame(width: 176, height: 176)
                    Circle().stroke(accent.opacity(hoveringPower ? 0.55 : 0.35), lineWidth: 1.5).frame(width: 150, height: 150)
                    Circle().fill(RadialGradient(colors: [accent.opacity(hoveringPower ? 0.28 : 0.18), accent.opacity(0.04)], center: .center, startRadius: 4, endRadius: 70)).frame(width: 128, height: 128)
                    Image(systemName: "power").font(.system(size: 46, weight: .light)).foregroundStyle(accent)
                    if tunnel.busy || tunnel.status == .connecting || tunnel.status == .reasserting { ProgressView().controlSize(.small).offset(y: 92) }
                }.frame(width: 190, height: 190).contentShape(Circle())
            }.buttonStyle(.plain).onHover { hoveringPower = $0 }
                .disabled(!TunnelController.available || !tunnel.ready || tunnel.busy || store.protectionBusy || [.connecting, .reasserting, .disconnecting].contains(tunnel.status))
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .help(store.networkActive ? "Turn network protection off (⇧⌘P)" : "Turn network protection on (⇧⌘P)")
                .accessibilityLabel(store.networkActive ? "Turn network protection off" : "Turn network protection on")
            VStack(spacing: 6) {
                Text(headline).font(.system(size: 18, weight: .semibold, design: .rounded))
                Text(store.protectionSubtitle).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Button { modeConnects = false; showingModes = true } label: { Label("Choose mode…", systemImage: "slider.horizontal.3") }
                .buttonStyle(MacHoverButtonStyle()).keyboardShortcut("m", modifiers: [.command, .shift]).help("Choose VPN + DNS, VPN only, DNS only or Adblock only (⇧⌘M)")
            if connected { TimelineView(.periodic(from: .now, by: 1)) { _ in Label(tunnel.duration, systemImage: "clock").font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(.secondary) } }
        }.padding(22).frame(maxWidth: .infinity).macPanel().animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.powerTone)
    }
    private func power() {
        Task {
            if store.networkActive { _ = await store.powerTapped(); return }
            activate { Task { if await store.powerTapped() { modeConnects = true; showingModes = true } } }
        }
    }

    private var protectionsPanel: some View {
        MacPanel("Protections", icon: "checkmark.shield") {
            VStack(spacing: 10) {
                protection("VPN", icon: "shield.lefthalf.filled", state: store.vpnPill, which: .vpn, needsVPN: true)
                Divider()
                protection("Encrypted DNS", icon: "globe", state: store.dnsPill, which: .dns, needsVPN: true)
                Divider()
                protection("Safari adblock", icon: "hand.raised", state: store.adblockPill, which: .adblock, needsVPN: false)
                if extensionManager?.requesting == true {
                    Label("Waiting for macOS to start the VayuSetu extension…", systemImage: "hourglass").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if !store.protectionNotice.isEmpty {
                    Label(store.protectionNotice, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }.macAnimate(value: store.protectionNotice)
        }
    }
    private func protection(_ title: String, icon: String, state: PillState, which: ProtectionPill, needsVPN: Bool) -> some View {
        MacRow(icon: icon, title: title, detail: word(state), tint: color(state)) {
            Toggle("", isOn: Binding(get: { state != .off }, set: { enabled in
                if needsVPN { activate { Task { await store.setPill(which, enabled: enabled, source: "Home") } } } else { Task { await store.setPill(which, enabled: enabled, source: "Home") } }
            })).labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityLabel(title)
                .disabled(store.protectionBusy || tunnel.busy || (needsVPN && (!TunnelController.available || !tunnel.ready)))
        }
    }
    private func word(_ s: PillState) -> String { switch s { case .off: "Off"; case .active: "On"; case .pending: "Starting…"; case .limited: "Limited"; case .failed: "Failed" } }
    private func color(_ s: PillState) -> Color { switch s { case .off: .secondary; case .active: .green; case .pending: .orange; case .limited: .yellow; case .failed: .red } }

    // MARK: Right column
    private var connectionPanel: some View {
        MacPanel("Connection", icon: "point.3.connected.trianglepath.dotted") {
            VStack(spacing: 6) {
                MacRow(icon: "key.horizontal", title: store.active?.name ?? (store.dnsOnlyChosen ? "No VPN profile" : "Choose a VPN profile"), detail: store.active == nil ? "DNS only, no remote VPN" : "WireGuard · saved profile") {
                    Menu {
                        Button("No VPN profile (DNS only)") { store.selectNoVPNProfile() }
                        Divider()
                        ForEach(store.profiles) { profile in Button { store.selectProfile(profile) } label: { if store.selected == profile.id { Label(profile.name, systemImage: "checkmark") } else { Text(profile.name) } } }
                        Divider()
                        Button("Manage profiles…") { openProfiles?() }
                    } label: { Text("Change") }.menuStyle(.borderlessButton).fixedSize().disabled(tunnel.running || tunnel.busy)
                }
                Divider()
                MacRow(icon: "network", title: store.endpoint.isEmpty ? "Choose an encrypted resolver" : store.dnsName, detail: store.endpoint.isEmpty ? "No resolver selected" : "Encrypted DNS", tint: Color(red: 0.0, green: 0.78, blue: 0.82)) {
                    Menu {
                        ForEach(store.dnsProfiles) { profile in Button { store.loadDNS(profile) } label: { if store.selectedDNS == profile.id { Label(profile.name, systemImage: "checkmark") } else { Text(profile.name) } } }
                        Divider()
                        Button("Manage resolvers…") { openDNS?() }
                    } label: { Text("Change") }.menuStyle(.borderlessButton).fixedSize().disabled(tunnel.running || tunnel.busy)
                }
                if store.active != nil {
                    Divider()
                    let kill = KillSwitchState.assess(settingOn: store.strictRouting, vpnRunning: tunnel.running && !tunnel.localDNSRunning, connected: tunnel.status == .connected, savedCapture: tunnel.savedStrictCapture)
                    MacRow(icon: kill == .off || kill.needsAttention ? "lock.open" : "lock.shield", title: kill.title, detail: kill.detail, tint: kill.needsAttention ? .orange : (kill.isConfirmedProtective ? .green : .secondary)) {
                        Toggle("", isOn: $store.strictRouting).labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityLabel("Strict routing")
                            .disabled(tunnel.running || tunnel.busy)
                    }
                }
            }
        }
    }

    private var livePanel: some View {
        MacPanel("Traffic", icon: "arrow.up.arrow.down", trailing: { MacChip(text: tunnel.ratesAvailable ? "Tunnel" : "This Mac", tint: tunnel.ratesAvailable ? .green : .secondary) }) {
            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 16)], alignment: .leading, spacing: 14) {
                    MacFigure(caption: "Received", value: bytes(tunnel.stats?.received))
                    MacFigure(caption: "Sent", value: bytes(tunnel.stats?.sent))
                }
                TrafficChart(tunnel: tunnel)
            }
        }
    }

    private var statusPanel: some View {
        MacPanel("Status", icon: "waveform.path.ecg", trailing: {
            Button("Run checks") { openChecks() }.buttonStyle(MacHoverButtonStyle())
        }) {
            VSProtectionGrid(store: store, tunnel: tunnel)
            Text("A working tunnel alone does not verify DNS routing or leak isolation. Run checks to see what was observed.").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
    @Environment(\.openChecksPage) private var openChecksPage
    private func openChecks() { openChecksPage?() }
    private func bytes(_ value: UInt64?) -> String { value.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .binary) } ?? "—" }
}

struct ChecksRouteKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }
extension EnvironmentValues { var openChecksPage: (() -> Void)? { get { self[ChecksRouteKey.self] } set { self[ChecksRouteKey.self] = newValue } } }

/// Today's DNS counts in one line, with a way to the full activity. The charts, rankings and the live view are on the Encrypted DNS page, which
/// is the only place that counts DNS lookups; showing them again here and on the Adblock page said the same thing three times.
struct VSHomeActivityPanel: View {
    @ObservedObject var filtering: FilteringController
    @Environment(\.openDNSTab) private var openDNS
    /// Read from the activity database every few seconds, not on every redraw of the panel.
    @State private var today: ActivitySeries?
    var body: some View {
        let shown = today
        MacPanel("DNS today", icon: "chart.xyaxis.line", trailing: { Button("Open DNS activity") { openDNS?() }.buttonStyle(MacHoverButtonStyle()) }) {
            if shown?.isEmpty ?? true {
                Text("No lookups counted yet today. Counts appear while Encrypted DNS is on.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 24) {
                    MacFigure(caption: "Lookups", value: (shown?.requests ?? 0).formatted(), tint: VSDesign.accent, rolls: true)
                    MacFigure(caption: "Blocked", value: (shown?.blocked ?? 0).formatted(), tint: .orange, rolls: true)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                let fresh = filtering.activitySeries(.today)
                if fresh != today { today = fresh }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

/// Choose the network mode: a plain list of four modes with a short description each.
struct MacModeSheet: View {
    @ObservedObject var store: AppStore
    let connectsAfterChoosing: Bool
    let activate: (@escaping () -> Void) -> Void
    @Environment(\.dismiss) private var dismiss
    private struct Mode: Identifiable { let id: String; let title: String; let detail: String; let icon: String; let vpn: Bool; let dns: Bool; var safariOnly = false }
    private var modes: [Mode] {
        let resolver = store.dnsName.isEmpty ? "your DNS resolver" : store.dnsName
        return [
            Mode(id: "vpnDNS", title: "VPN + DNS", detail: "Your VPN profile with encrypted DNS from \(resolver).", icon: "shield.lefthalf.filled", vpn: true, dns: true),
            Mode(id: "vpn", title: "VPN only", detail: "Your VPN profile and its own DNS settings.", icon: "lock.shield", vpn: true, dns: false),
            Mode(id: "dns", title: "DNS only", detail: "Local encrypted DNS with \(resolver). No VPN server needed.", icon: "network", vpn: false, dns: true),
            Mode(id: "adblock", title: "Adblock only", detail: "Safari content blockers. No VPN and no DNS protection.", icon: "hand.raised", vpn: false, dns: false, safariOnly: true)
        ]
    }
    private var current: String? {
        if !store.networkActive && store.adblockPill != .off && !store.powerModeChosen { return "adblock" }
        return modes.first { !$0.safariOnly && $0.vpn == store.savedNetwork?.vpn && $0.dns == store.savedNetwork?.dns }?.id
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) { Text("Network protection").font(.system(size: 20, weight: .semibold, design: .rounded)); Text("Choose how VayuSetu protects this Mac.").font(.subheadline).foregroundStyle(.secondary) }
            VStack(spacing: 0) {
                ForEach(modes) { mode in
                    Button { choose(mode) } label: {
                        MacRow(icon: mode.icon, title: mode.title, detail: mode.detail) {
                            if current == mode.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(VSDesign.accent) }
                        }.padding(.horizontal, 12).padding(.vertical, 4).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if mode.id != modes.last?.id { Divider().padding(.leading, 58) }
                }
            }.macPanel()
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(22).background(VSDesign.background)
    }
    private func choose(_ mode: Mode) {
        if mode.safariOnly { Task { await store.chooseMode(vpn: false, dns: false, safari: true, source: "Home") }; dismiss(); return }
        if store.networkActive || connectsAfterChoosing { activate { Task { await store.chooseMode(vpn: mode.vpn, dns: mode.dns, source: "Home") } } }
        else { store.saveMode(vpn: mode.vpn, dns: mode.dns) }
        dismiss()
    }
}
