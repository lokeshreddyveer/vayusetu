import AppKit
import SwiftUI
import VayuSetuCore

enum Page: String, CaseIterable, Identifiable {
    case home = "Home", profiles = "VPN Profiles", dns = "Encrypted DNS", adblock = "Adblock", network = "Network", security = "Security Center", checks = "Diagnostics", logs = "Logs", settings = "Settings"
    static let primary: [Page] = [.home, .profiles, .dns, .adblock, .network, .security, .settings]
    var id: String { rawValue }
    var icon: String { switch self { case .home: "power"; case .profiles: "key.horizontal"; case .dns: "network"; case .adblock: "hand.raised"; case .network: "network.badge.shield.half.filled"; case .security: "sparkles"; case .checks: "waveform.path.ecg"; case .logs: "text.alignleft"; case .settings: "gearshape" } }
}
@main struct VayuSetuMac: App {
    init() { CrashTrace.install() }
    @StateObject private var store = AppStore()
    @StateObject private var extensions = ExtensionManager()
    @StateObject private var filterClient = FilterClient()
    @AppStorage("appearance") private var appearance = "dark"
    /// `open "vayusetu://protection/dns/on"` (or `vpn`, `adblock`; `on`, `off` or `toggle`) from Terminal, a shortcut or a script.
    private func handleProtectionLink(_ url: URL) async {
        guard url.scheme == "vayusetu", url.host == "protection" else { return }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2 else { return }
        let pill: ProtectionPill, state: PillState
        switch parts[0] {
        case "vpn": pill = .vpn; state = store.vpnPill
        case "dns": pill = .dns; state = store.dnsPill
        case "adblock": pill = .adblock; state = store.adblockPill
        default: return
        }
        let isOn = state == .active || state == .pending
        switch parts[1] {
        case "on": if isOn { return }
        case "off": if !isOn { return }
        case "toggle": break
        default: return
        }
        if pill == .adblock { await store.togglePill(pill) }
        else { await withCheckedContinuation { continuation in extensions.activate { Task { await store.togglePill(pill); continuation.resume() } } } }
    }
    var body: some Scene {
        Window("VayuSetu", id: "main") { DesktopView(store: store, extensions: extensions, filterClient: filterClient).onOpenURL { url in if !filterClient.handle(url: url) { Task { await handleProtectionLink(url) } } }.frame(minWidth: 940, minHeight: 620).preferredColorScheme(appearance == "system" ? nil : appearance == "light" ? .light : .dark).tint(VSDesign.accent).frame(minWidth: 760, minHeight: 560) }.defaultSize(width: 1080, height: 740)
        MenuBarExtra { MenuControls(store: store, extensions: extensions, filter: filterClient) } label: {
            Label { Text(menuBarTitle) } icon: { MenuBarMark(active: store.networkActive) }
        }
        .commands { CommandGroup(replacing: .appInfo) { Button("About VayuSetu") { NSApplication.shared.orderFrontStandardAboutPanel(options: [.applicationName: "VayuSetu", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown", .credits: NSAttributedString(string: "By R3dby · Native VPN and encrypted DNS control center")]) } } }
    }
    private var menuBarTitle: String { store.networkActive ? "VayuSetu On" : "VayuSetu" }
}

/// A compact monochrome version of the VayuSetu mark for the menu bar. The
/// template rendering keeps it legible against both macOS menu-bar appearances.
private struct MenuBarMark: View {
    let active: Bool
    private static let artwork = Bundle.main.url(forResource: "BrandArtwork", withExtension: "png").flatMap(NSImage.init(contentsOf:))
    var body: some View {
        if let artwork = Self.artwork {
            Image(nsImage: artwork).resizable().renderingMode(.template).foregroundStyle(active ? .green : .primary).scaledToFit().frame(width: 16, height: 16)
        } else {
            Image(systemName: active ? "checkmark.shield.fill" : "shield").foregroundStyle(active ? .green : .primary)
        }
    }
}
struct DesktopView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var extensions: ExtensionManager
    @ObservedObject var tunnel: TunnelController
    @StateObject private var network = NetworkDiagnostics()
    @StateObject private var preferences = DesktopPreferences()
    @ObservedObject var filterClient: FilterClient
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("onboarding-complete") private var onboarded = false
    @State private var onboarding = false
    @State private var selection: Page? = .home
    @State private var visibility: NavigationSplitViewVisibility = .all
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(store: AppStore, extensions: ExtensionManager, filterClient: FilterClient) { self.store = store; self.extensions = extensions; self.filterClient = filterClient; tunnel = store.tunnel }
    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) { MacBrandArtwork().frame(width: 38, height: 38).clipShape(RoundedRectangle(cornerRadius: 10)); VStack(alignment: .leading, spacing: 3) { Text("VayuSetu").font(.headline); Text("By R3dby").font(.caption2).foregroundStyle(.secondary) } }.padding(.horizontal, 18).padding(.top, 22)
                List(Page.primary, selection: $selection) { page in Label(page.rawValue, systemImage: page.icon).padding(.vertical, 6).tag(page) }.listStyle(.sidebar).scrollIndicators(.hidden)
                Label(tunnel.statusText, systemImage: "circle").font(.caption).foregroundStyle(.secondary).padding(20)
            }.navigationSplitViewColumnWidth(min: 185, ideal: 210, max: 260)
        } detail: {
            HStack(spacing: 0) {
                if visibility == .detailOnly {
                    compactSidebar
                    Divider()
                }
                NavigationStack { content }.environment(\.openDNSTab, { selection = .dns }).environment(\.openAdblockTab, { selection = .adblock }).environment(\.openProfilesTab, { selection = .profiles }).environment(\.openChecksPage, { selection = .checks })
            }.background(VSDesign.background)
        }.navigationSplitViewStyle(.balanced).environment(\.extensionManager, extensions).vsDialogHost()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: visibility)
        .alert("VayuSetu", isPresented: Binding(get: { !store.notice.isEmpty }, set: { if !$0 { store.notice = "" } })) { Button("OK") { store.notice = "" } } message: { Text(store.notice) }
        .sheet(isPresented: $onboarding) { NavigationStack { VSOnboardingScreen(store: store) }.frame(minWidth: 520, minHeight: 580) }
        .onAppear { if !onboarded && !ProcessInfo.processInfo.arguments.contains("--privacy-check") && store.profiles.isEmpty && store.dnsProfiles.isEmpty { onboarding = true } }
        .onChange(of: tunnel.status.rawValue) { _, _ in
            store.invalidateDNS(); network.cancelQuality()
            Task { await store.reconcileNetworkState() }
        }
        .onChange(of: network.routeRevision) { _, _ in
            store.invalidateDNS(); network.cancelQuality()
            Task { await store.reconcileNetworkState() }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await store.reconcileNetworkState()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .task {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("--privacy-check") {
                await store.systemDNS.refresh(); await store.filtering.reload(); tunnel.refreshStatus()
                let compilerResult = await store.filtering.validateSafariCompiler()
                let report = PrivacyCapabilityReport(timestamp: Date(), snapshots: ProtectionSubsystem.allCases.map { store.protection($0) }, safariOSState: store.filtering.enabled, safariReloadAcknowledged: store.filtering.packageReady, filterRuleCount: store.filtering.configuration.effective.count, operation: store.filtering.message + " " + compilerResult)
                if let data = try? JSONEncoder().encode(report) { try? LocalFiles.write(data, to: LocalFiles.url("last-privacy-diagnostic.json")) }
                return
            }
            if let index = args.firstIndex(of: "--page"), args.indices.contains(index + 1), let page = Page(rawValue: args[index + 1]) { selection = page }
            if preferences.connectOnLaunch && TunnelController.available { for _ in 0..<100 { if tunnel.ready || Task.isCancelled { break }; try? await Task.sleep(for: .milliseconds(100)) }; if !Task.isCancelled { extensions.activate { store.connect() } } }
        }
        // The filter must keep polling even when the user is on Home, Adblock, or has
        // only the menu-bar control visible. Otherwise a paused connection can time out
        // before the Network page is opened.
        .task {
            // Re-submit the bundled filter on every launch so macOS can replace
            // an older active system extension after an app update.
            extensions.activateFilter()
            filterClient.startPolling()
            extensions.checkComponents()
            var seconds = 0
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(1)); seconds += 1; if seconds % 90 == 0 { extensions.checkComponents() } }
            filterClient.stopPolling()
        }
        .onChange(of: filterClient.pending) { _, _ in
            ConnectionAlertController.shared.sync(client: filterClient)
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("VayuSetu.openNetwork"))) { _ in
            selection = .network
        }
    }
    private var compactSidebar: some View {
        VStack(spacing: 12) {
            ForEach(Page.primary) { page in
                Button { selection = page } label: {
                    Image(systemName: page.icon)
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .background(selection == page ? VSDesign.accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .help(page.rawValue)
                .accessibilityLabel(page.rawValue)
                .foregroundStyle(selection == page ? VSDesign.accent : .secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(.regularMaterial)
    }
    var content: AnyView {
        switch selection ?? .home {
        case .home: AnyView(MacHome(store: store, tunnel: tunnel, network: network, activate: { extensions.activate(onReady: $0) }))
        case .profiles: AnyView(MacProfiles(store: store, tunnel: tunnel, activate: { extensions.activate(onReady: $0) }))
        case .dns: AnyView(MacDNS(store: store, tunnel: tunnel, activate: { extensions.activate(onReady: $0) }))
        case .adblock: AnyView(MacAdblock(filtering: store.filtering, store: store))
        case .network: AnyView(MacNetwork(client: filterClient, extensions: extensions))
        case .security: AnyView(MacSecurityInsights(filter: filterClient))
        case .checks: AnyView(VSChecksScreen(store: store, tunnel: tunnel, network: network))
        case .logs: AnyView(VSLogsScreen(tunnel: tunnel))
        case .settings: AnyView(MacSettings(store: store, tunnel: tunnel, preferences: preferences))
        }
    }
}
