import AppKit
import SwiftUI
import VayuSetuCore

enum Page: String, CaseIterable, Identifiable {
    case home = "Home", profiles = "VPN Profiles", dns = "Encrypted DNS", adblock = "Adblock", network = "Network", health = "Connection Health", security = "Security Center", checks = "Diagnostics", logs = "Logs", settings = "Settings"
    static let primary: [Page] = [.home, .profiles, .dns, .adblock, .network, .health, .security, .settings]
    var id: String { rawValue }
    var icon: String { switch self { case .home: "power"; case .profiles: "key.horizontal"; case .dns: "network"; case .adblock: "hand.raised"; case .network: "network.badge.shield.half.filled"; case .health: "waveform.path.ecg.rectangle"; case .security: "sparkles"; case .checks: "waveform.path.ecg"; case .logs: "text.alignleft"; case .settings: "gearshape" } }
}
@main struct VayuSetuMac: App {
    init() {
        CrashTrace.install()
        // A menu-bar app with its window closed looks idle, and macOS then quits it ("terminate after last window"), which also loses any
        // vayusetu:// command sent to it. VayuSetu keeps running until the user quits it.
        ProcessInfo.processInfo.disableAutomaticTermination("VayuSetu stays running in the menu bar")
        ProcessInfo.processInfo.disableSuddenTermination()
    }
    @StateObject private var store = AppStore()
    @StateObject private var extensions = ExtensionManager()
    @StateObject private var filterClient = FilterClient()
    @AppStorage("appearance") private var appearance = "dark"
    /// `open "vayusetu://protection/dns/on"` (or `vpn`, `adblock`; `on`, `off` or `toggle`) from Terminal, a shortcut or a script.
    private func handleProtectionLink(_ url: URL) async {
        guard url.scheme == "vayusetu", url.host == "protection" else { return }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2 else { return }
        // One request for both, so the app plans a single start instead of two in a row. `both/on` is VPN + DNS; `both/off` stops the network side.
        if parts[0] == "both" {
            if parts[1] == "on" { await withCheckedContinuation { continuation in extensions.activate { Task { await store.chooseMode(vpn: true, dns: true, source: "link"); continuation.resume() } } } }
            else if parts[1] == "off" { await store.powerOffNetwork(source: "link") }
            return
        }
        let pill: ProtectionPill, control: ProtectionControl
        switch parts[0] {
        case "vpn": pill = .vpn; control = .vpn
        case "dns": pill = .dns; control = .dns
        case "adblock": pill = .adblock; control = .adblock
        default: return
        }
        // "on" and "off" are explicit values and "toggle" is relative to what is running now. Asking for what is already so changes nothing.
        guard let wanted = ProtectionRequestPolicy.linkValue(parts[1], control: control, observed: store.observedSelection.target) else { return }
        if pill == .adblock { await store.setPill(pill, enabled: wanted, source: "link") }
        else { await withCheckedContinuation { continuation in extensions.activate { Task { await store.setPill(pill, enabled: wanted, source: "link"); continuation.resume() } } } }
    }
    var body: some Scene {
        Window("VayuSetu", id: "main") { DesktopView(store: store, extensions: extensions, filterClient: filterClient).onOpenURL { url in if !filterClient.handle(url: url) { Task { await handleProtectionLink(url) } } }.frame(minWidth: 940, minHeight: 620).preferredColorScheme(appearance == "system" ? nil : appearance == "light" ? .light : .dark).tint(VSDesign.accent).frame(minWidth: 760, minHeight: 560) }.defaultSize(width: 1080, height: 740)
        MenuBarExtra { MenuControls(store: store, extensions: extensions, filter: filterClient) } label: {
            MenuBarLabel(store: store, tunnel: store.tunnel, filter: filterClient)
        }
        .commands { CommandGroup(replacing: .appInfo) { Button("About VayuSetu") { NSApplication.shared.orderFrontStandardAboutPanel(options: [.applicationName: "VayuSetu", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown", .credits: NSAttributedString(string: "By R3dby · Native VPN and encrypted DNS control center")]) } } }
    }
}

/// A compact monochrome version of the VayuSetu mark for the menu bar. The
/// template rendering keeps it legible against both macOS menu-bar appearances.
struct DesktopView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var extensions: ExtensionManager
    @ObservedObject var tunnel: TunnelController
    @StateObject private var network = NetworkDiagnostics()
    @StateObject private var preferences = DesktopPreferences()
    @ObservedObject var filterClient: FilterClient
    @StateObject private var wifi = WiFiWatcher()
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
                Label(store.connectionLabel, systemImage: "circle.fill").font(.caption.weight(.medium)).foregroundStyle(store.connectionTint).padding(20).animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: store.connectionLabel)
            }.navigationSplitViewColumnWidth(min: 185, ideal: 210, max: 260)
        } detail: {
            HStack(spacing: 0) {
                if visibility == .detailOnly {
                    compactSidebar
                    Divider()
                }
                NavigationStack { content }.environment(\.openDNSTab, { selection = .dns }).environment(\.openAdblockTab, { selection = .adblock }).environment(\.openProfilesTab, { selection = .profiles }).environment(\.openChecksPage, { selection = .checks })
            }.background(VSDesign.background)
        }.navigationSplitViewStyle(.balanced).scrollIndicators(.hidden).environment(\.extensionManager, extensions).environment(\.wifiWatcher, wifi).vsDialogHost()
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
        // The DNS check expires after ten minutes, so look again every four while the DNS tunnel is up. Otherwise a working DNS tunnel
        // slides back to "not verified" for no reason. A check is a few small lookups and changes nothing.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(240))
                await store.verifyLocalDNS()
            }
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
            DomainHistoryStore.shared.startCollecting(tunnel: tunnel)
            extensions.checkComponents()
            wifi.current = { NetworkRulePlanner.current(vpn: store.vpnPill == .active || store.vpnPill == .pending, dns: store.dnsPill == .active || store.dnsPill == .pending) }
            wifi.apply = { decision in
                store.protectionNotice = decision.reason
                if decision.action == .off { Task { await store.powerOffNetwork(source: decision.automatic ? "Wi-Fi rule" : "Wi-Fi suggestion you accepted") } }
                else { extensions.activate { Task { await store.chooseMode(vpn: decision.action.vpn, dns: decision.action.dns, source: decision.automatic ? "Wi-Fi rule" : "Wi-Fi suggestion you accepted") } } }
            }
            wifi.start()
            TamperMonitor.shared.start(store: store, tunnel: tunnel)
            // Monitoring resumes at launch when it was switched on, not only once the Connection Health page has been opened.
            WiFiMonitor.shared.vpnActive = { [tunnel] in tunnel.running && !tunnel.localDNSRunning }
            WiFiMonitor.shared.tunnelSession = { [tunnel] in tunnel.sessionGeneration }
            WiFiMonitor.shared.tunnelResolverHealth = { [tunnel] in tunnel.resolverHealth() }
            NetLab.shared.tunnelVPNActive = { [tunnel] in tunnel.running && !tunnel.localDNSRunning }
            if UserDefaults.standard.bool(forKey: "wifi-monitor-on") { WiFiMonitor.shared.start() }
            var seconds = 0
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(1)); seconds += 1; if seconds % 90 == 0 { extensions.checkComponents() } }
            filterClient.stopPolling()
        }
        // The iPhone app feeds the tunnel's DNS counters into the activity history from its root view; the Mac needs the same.
        .onChange(of: tunnel.statsSampleRevision) { _, _ in store.filtering.ingest(tunnel.stats?.dnsCounters) }
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
        case .home: AnyView(MacHome(store: store, tunnel: tunnel, network: network, filter: filterClient, activate: { extensions.activate(onReady: $0) }))
        case .profiles: AnyView(MacProfiles(store: store, tunnel: tunnel, activate: { extensions.activate(onReady: $0) }))
        case .dns: AnyView(MacDNS(store: store, tunnel: tunnel, activate: { extensions.activate(onReady: $0) }))
        case .adblock: AnyView(MacAdblock(filtering: store.filtering, store: store))
        case .network: AnyView(MacNetwork(client: filterClient, extensions: extensions))
        case .health: AnyView(MacConnectionHealth(store: store, tunnel: tunnel, monitor: WiFiMonitor.shared))
        case .security: AnyView(MacSecurityInsights(filter: filterClient, store: store, tunnel: tunnel))
        case .checks: AnyView(VSChecksScreen(store: store, tunnel: tunnel, network: network))
        case .logs: AnyView(VSLogsScreen(tunnel: tunnel))
        case .settings: AnyView(MacSettings(store: store, tunnel: tunnel, preferences: preferences, wifi: wifi))
        }
    }
}
