import AppKit
import SwiftUI
import VayuSetuCore

enum Page: String, CaseIterable, Identifiable {
    case home = "Home", profiles = "VPN Profiles", dns = "Encrypted DNS", adblock = "Adblock", checks = "Diagnostics", logs = "Logs", settings = "Settings"
    static let primary: [Page] = [.home, .profiles, .dns, .adblock, .settings]
    var id: String { rawValue }
    var icon: String { switch self { case .home: "power"; case .profiles: "key.horizontal"; case .dns: "network"; case .adblock: "hand.raised"; case .checks: "waveform.path.ecg"; case .logs: "text.alignleft"; case .settings: "gearshape" } }
}
@main struct VayuSetuMac: App {
    @StateObject private var store = AppStore()
    @StateObject private var extensions = ExtensionManager()
    @AppStorage("appearance") private var appearance = "dark"
    var body: some Scene {
        WindowGroup("VayuSetu", id: "main") { DesktopView(store: store, extensions: extensions).preferredColorScheme(appearance == "system" ? nil : appearance == "light" ? .light : .dark).tint(VSDesign.accent).frame(minWidth: 760, minHeight: 560) }.defaultSize(width: 1080, height: 740)
        MenuBarExtra("VayuSetu", systemImage: "wind") { MenuControls(store: store, extensions: extensions) }
        .commands { CommandGroup(replacing: .appInfo) { Button("About VayuSetu") { NSApplication.shared.orderFrontStandardAboutPanel(options: [.applicationName: "VayuSetu", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown", .credits: NSAttributedString(string: "By R3dby · Native VPN and encrypted DNS control center")]) } } }
    }
}
struct DesktopView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var extensions: ExtensionManager
    @ObservedObject var tunnel: TunnelController
    @StateObject private var network = NetworkDiagnostics()
    @StateObject private var preferences = DesktopPreferences()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("onboarding-complete") private var onboarded = false
    @State private var onboarding = false
    @State private var selection: Page? = .home
    @State private var visibility: NavigationSplitViewVisibility = .all
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(store: AppStore, extensions: ExtensionManager) { self.store = store; self.extensions = extensions; tunnel = store.tunnel }
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
                    VStack(spacing: 12) { ForEach(Page.primary) { page in Button { selection = page } label: { Image(systemName: page.icon).font(.title3).frame(width: 44, height: 44).background(selection == page ? VSDesign.accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 10)) }.buttonStyle(.plain).help(page.rawValue).accessibilityLabel(page.rawValue).foregroundStyle(selection == page ? VSDesign.accent : .secondary) }; Spacer() }.padding(10).background(.regularMaterial)
                    Divider()
                }
                NavigationStack { content }
            }.background(VSDesign.background)
        }.navigationSplitViewStyle(.balanced)
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
    }
    var content: AnyView {
        switch selection ?? .home {
        case .home: AnyView(MacDashboard(store: store, tunnel: tunnel, network: network, connect: { extensions.activate { store.connect() } }))
        case .profiles: AnyView(VSProfilesScreen(store: store, tunnel: tunnel))
        case .dns: AnyView(VSDNSScreen(store: store, tunnel: tunnel))
        case .adblock: AnyView(VSAdblockScreen(filtering: store.filtering, store: store))
        case .checks: AnyView(VSChecksScreen(store: store, tunnel: tunnel, network: network))
        case .logs: AnyView(VSLogsScreen(tunnel: tunnel))
        case .settings: AnyView(VSSettingsScreen(store: store, tunnel: tunnel).toolbar { ToolbarItem { Menu("Mac Integration") { Toggle("Launch at login", isOn: Binding(get: { preferences.loginEnabled }, set: { preferences.setLogin($0) })); Button("Activate VPN Extension") { extensions.activate() }.disabled(extensions.requesting || !TunnelController.available) } } }.safeAreaInset(edge: .bottom) { if !extensions.message.isEmpty || !preferences.message.isEmpty { Text(extensions.message + "\n" + preferences.message).font(.footnote).foregroundStyle(.secondary).padding(16) } })
        }
    }
}
