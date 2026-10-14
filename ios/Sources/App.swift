import SwiftUI
import NetworkExtension
import VayuSetuCore
import BackgroundTasks

@main struct VayuSetuApp: App {
    @StateObject private var store = AppStore()
    @AppStorage("appearance") private var appearance = "dark"
    var body: some Scene { WindowGroup { RootView(store: store).preferredColorScheme(appearance == "system" ? nil : appearance == "light" ? .light : .dark).tint(VSDesign.accent) }
        .backgroundTask(.appRefresh(FilterBackgroundRefresh.identifier)) {
            FilterBackgroundRefresh.schedule()
            await store.filtering.backgroundRefresh()
        }
    }
}
struct RootView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    @StateObject private var network = NetworkDiagnostics()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("live-activity-enabled") private var liveActivityEnabled = false
    @StateObject private var liveActivity = ConnectionActivityController()
    /// What is on right now, from what iOS and the tunnel confirm: a VPN, DNS-only mode, and Safari adblocking.
    private var activitySnapshot: ActivitySnapshot {
        let up = tunnel.running && tunnel.status == .connected
        return ActivitySnapshot(vpn: up && !tunnel.localDNSRunning, dnsOnly: up && tunnel.localDNSRunning, adblock: store.adblockPill == .active)
    }
    @State private var tab = 0
    @AppStorage("onboarding-complete") private var onboarded = false
    @State private var onboarding = false
    init(store: AppStore) {
        self.store = store; tunnel = store.tunnel
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--ui-tab"), args.indices.contains(index + 1), let value = Int(args[index + 1]), (0...4).contains(value) { _tab = State(initialValue: value) }
        #endif
    }
    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { AnyView(VSHomeScreen(store: store, tunnel: tunnel, network: network, connect: { store.connect() })) }.tabItem { Label("Home", systemImage: "power") }.tag(0)
            NavigationStack { AnyView(VSProfilesScreen(store: store, tunnel: tunnel, isRootTab: true)) }.tabItem { Label("Profiles", systemImage: "key.horizontal") }.tag(1)
            NavigationStack { AnyView(VSDNSScreen(store: store, tunnel: tunnel, isRootTab: true)) }.tabItem { Label { Text("DNS") } icon: { Image(uiImage: PrivacyTabArtwork.image(.dns)).renderingMode(.template) } }.tag(2)
            NavigationStack { AnyView(VSAdblockScreen(filtering: store.filtering, store: store, isRootTab: true)) }.tabItem { Label { Text("Adblock") } icon: { Image(uiImage: PrivacyTabArtwork.image(.adblock)).renderingMode(.template) } }.tag(3)
            NavigationStack { AnyView(VSSettingsScreen(store: store, tunnel: tunnel)) }.tabItem { Label("Settings", systemImage: "gearshape") }.tag(4)
        }.onChange(of: tunnel.stats?.dnsCounters) { _, counters in store.filtering.ingest(counters) }.environment(\.openDNSTab, { tab = 2 }).environment(\.openAdblockTab, { tab = 3 }).environment(\.openProfilesTab, { tab = 1 }).vsAlert(isPresented: Binding(get: { !store.notice.isEmpty }, set: { if !$0 { store.notice = "" } }), tone: .info, icon: "bell.badge.fill", title: "VayuSetu", message: store.notice, then: { store.notice = "" })
        .sensoryFeedback(.selection, trigger: tab)
        .onChange(of: "\(store.vpnPill)-\(store.dnsPill)-\(store.adblockPill)-\(store.connectionName ?? "")") { _, _ in store.publishWidgetStatus(); liveActivity.observe(activitySnapshot, enabled: liveActivityEnabled, canStart: scenePhase == .active) }
        .task { ProtectionActionInbox.handler = { action in Task { await store.perform(action) } } }
        .sheet(isPresented: $onboarding) { NavigationStack { VSOnboardingScreen(store: store) }.vsDialogHost().vsSheetChrome() }
        #if DEBUG
        // `--ui-screen <name>` opens one screen on its own, so every screen can be looked at without tapping through the app.
        .fullScreenCover(isPresented: .constant(DebugScreens.requested != nil)) {
            NavigationStack { DebugScreens.view(store: store, tunnel: tunnel, network: network) }.environment(\.openDNSTab, { }).environment(\.openAdblockTab, { }).environment(\.openProfilesTab, { })
        }
        #endif
        // Decisions can start from any tab (Home pills, DNS toggle), so the confirmation lives at the root.
        .vsDialog(isPresented: Binding(get: { store.pendingDecision != nil }, set: { if !$0 { store.pendingDecision = nil } }), tone: .warning, icon: "shield.lefthalf.filled", title: store.pendingDecision?.title ?? "Change protection?", message: store.pendingDecision?.message ?? "",
                  actions: [VSDialogAction(title: store.pendingDecision?.confirmTitle ?? "Continue", kind: .primary, run: { store.confirmPendingDecision() })]
                    + (store.pendingDecision?.ackKey != nil ? [VSDialogAction(title: "Connect, Don’t Ask Again", kind: .plain, run: { store.confirmPendingDecision(remember: true) })] : [])
                    + [VSDialogAction(title: "Cancel", kind: .cancel)])
        .vsDialogHost()
        .onAppear { if !onboarded && !ProcessInfo.processInfo.arguments.contains("--ui-testing") && store.profiles.isEmpty && store.dnsProfiles.isEmpty { onboarding = true } }
        .onChange(of: scenePhase) { _, phase in if phase == .background { FilterBackgroundRefresh.schedule() } }
        .task(id: "\(scenePhase)-\(liveActivityEnabled)") {
            guard scenePhase == .active else { return }
            liveActivity.observe(activitySnapshot, enabled: liveActivityEnabled, canStart: true)
            await store.reconcileNetworkState()
            while !Task.isCancelled {
                await store.reconcileNetworkState()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .onChange(of: tunnel.status.rawValue) { _, _ in store.invalidateDNS(); network.cancelQuality(); store.filtering.record("VPN system state changed · " + tunnel.statusText); Task { await store.reconcileNetworkState(); liveActivity.observe(activitySnapshot, enabled: liveActivityEnabled, canStart: scenePhase == .active) } }
        .onChange(of: network.routeRevision) { _, _ in store.invalidateDNS(); network.cancelQuality(); Task { await store.reconcileNetworkState() } }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--connection-audit") {
                await DebugConnectionAudit.run(store: store, tunnel: tunnel, network: network)
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--repair-wireguard-registration") {
                for _ in 0..<100 { if tunnel.ready { break }; try? await Task.sleep(for: .milliseconds(100)) }
                do { try await tunnel.repairWireGuardRegistration() }
                catch { store.notice = (error as? AppIssue)?.message ?? "Owned WireGuard registration repair failed." }
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--startup-check") {
                for _ in 0..<100 { if tunnel.ready { break }; try? await Task.sleep(for: .milliseconds(100)) }
                let report = tunnel.logReport + "\nStartup breadcrumbs\n" + TunnelStartupEvent.report
                try? LocalFiles.write(Data(report.utf8), to: LocalFiles.url("last-startup-diagnostic.txt"))
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--recover-configuration") {
                for _ in 0..<100 { if tunnel.ready { break }; try? await Task.sleep(for: .milliseconds(100)) }
                store.recoverSavedConfiguration()
                let report = "VPN profiles: " + String(store.profiles.count) + "\\nDNS profiles: " + String(store.dnsProfiles.count) + "\\nResolver loaded: " + String(!store.endpoint.isEmpty) + "\\n" + store.notice
                try? LocalFiles.write(Data(report.utf8), to: LocalFiles.url("configuration-recovery-report.txt"))
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--adblock-check") {
                for _ in 0..<100 { if tunnel.ready && network.path != "Checking network…" { break }; try? await Task.sleep(for: .milliseconds(100)) }
                await store.filtering.refresh()
                var lines = ["VayuSetu provider ad/tracker samples", "Measured: " + Date().formatted(.iso8601), "Tunnel: " + tunnel.statusText, "Network: " + network.path]
                if let endpoint = try? DNSService.endpoint(store.endpoint) {
                    let reference = URL(string: "https://cloudflare-dns.com/dns-query")!
                    for domain in ["ad.doubleclick.net", "pagead2.googlesyndication.com", "www.google-analytics.com"] {
                        let control = await FilteringDiagnostics.observeDetailed(reference, domain: domain)
                        let target = await FilteringDiagnostics.observeDetailed(endpoint, domain: domain)
                        let verdict = DNSFilterObservation.verdict(control: control.map(\.observation), target: target.map(\.observation))
                        lines.append(domain + ": " + verdict.rawValue)
                        lines += ["Reference: " + control.map(\.description).joined(separator: " | "), "Configured resolver: " + target.map(\.description).joined(separator: " | ")]
                    }
                } else { lines.append("No valid configured resolver endpoint.") }
                lines.append("These are explicit queries to the configured resolver and a reference on the current route. They do not prove that other apps use this DNS path, category-wide filtering, or first-party video ad removal. Resolver credentials and IPs are omitted.")
                try? LocalFiles.write(Data(lines.joined(separator: "\n").utf8), to: LocalFiles.url("last-adblock-diagnostic.txt"))
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--privacy-check") {
                await store.systemDNS.refresh()
                await store.filtering.reload()
                let compilerResult = await store.filtering.validateSafariCompiler()
                let snapshots = ProtectionSubsystem.allCases.map { store.protection($0) }
                let report = PrivacyCapabilityReport(timestamp: Date(), snapshots: snapshots, safariOSState: store.filtering.enabled, safariReloadAcknowledged: store.filtering.packageReady, filterRuleCount: store.filtering.configuration.effective.count, operation: store.filtering.message + " " + compilerResult + " " + store.filtering.failureDetails)
                if let data = try? JSONEncoder().encode(report) { try? LocalFiles.write(data, to: LocalFiles.url("last-privacy-diagnostic.json")) }
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--ip-check") {
                tab = 4
                for _ in 0..<100 {
                    if tunnel.ready && network.path != "Checking network…" { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                // Require five seconds of stable observations before each bounded retry.
                // This test never starts, stops, or changes the VPN.
                let requiresVPN = ProcessInfo.processInfo.arguments.contains("--vpn-ip-check")
                for _ in 0..<3 {
                    var stable = 0
                    for _ in 0..<45 {
                        let revision = network.routeRevision; let status = tunnel.status.rawValue
                        try? await Task.sleep(for: .seconds(1))
                        if revision == network.routeRevision && status == tunnel.status.rawValue && (!requiresVPN || tunnel.status == .connected) && network.path != "Checking network…" { stable += 1 } else { stable = 0 }
                        if stable >= 5 { break }
                    }
                    guard !Task.isCancelled, stable >= 5, !requiresVPN || tunnel.status == .connected else { return }
                    network.checkIP(status: tunnel.statusText, compareLegacy: true, counterSample: { tunnel.observedCounters() }, policyEvidence: tunnel.configuredPolicySummary)
                    while network.checkingIP { try? await Task.sleep(for: .milliseconds(200)); if Task.isCancelled { return } }
                    if network.ipv4Probe != nil { break }
                }
                var resolverEvidence = "Configured-resolver comparison unavailable."
                if let resolver = try? DNSService.endpoint(store.endpoint) {
                    let revision = network.routeRevision
                    async let ipv4DNS = FilteringDiagnostics.observeDetailed(resolver, domain: "api.ipify.org")
                    async let ipv6DNS = FilteringDiagnostics.observeDetailed(resolver, domain: "api6.ipify.org")
                    let observations = await (ipv4DNS, ipv6DNS)
                    if revision == network.routeRevision {
                        resolverEvidence = "Configured encrypted resolver, public diagnostic names only\napi.ipify.org\n" + observations.0.map(\.description).joined(separator: "\n") + "\napi6.ipify.org\n" + observations.1.map(\.description).joined(separator: "\n") + "\nThese DNS answers do not independently verify transport path."
                    } else { resolverEvidence = "Network changed during resolver comparison; observations discarded." }
                }
                if let url = try? LocalFiles.read(LocalFiles.url("last-ip-diagnostic.txt"), maximum: 16000), var report = String(data: url, encoding: .utf8) {
                    report += "\n" + resolverEvidence + "\nStartup breadcrumbs\n" + TunnelStartupEvent.report
                    try? LocalFiles.write(Data(report.utf8), to: LocalFiles.url("last-ip-diagnostic.txt"))
                }
            }
            #endif
        }
        .task {
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return }
            await store.filtering.enableDefaultListsOnFirstRun()
        }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return }
            #endif
            guard TunnelController.available, store.connectOnLaunch else { return }
            for _ in 0..<100 { if tunnel.ready || Task.isCancelled { break }; try? await Task.sleep(for: .milliseconds(100)) }
            if !Task.isCancelled { store.connect() }
        }
    }
}


#if DEBUG
/// Device-test-only observer. It never starts a VPN or modifies a resolver.
@MainActor private enum DebugConnectionAudit {
    static func run(store: AppStore, tunnel: TunnelController, network: NetworkDiagnostics) async {
        var measured = Set<UUID>()
        let deadline = Date().addingTimeInterval(600)
        while !Task.isCancelled, Date() < deadline {
            guard tunnel.status == .connected, let profile = tunnel.configuredProfile, !measured.contains(profile) else {
                try? await Task.sleep(for: .seconds(1)); continue
            }
            let revision = network.routeRevision
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, tunnel.status == .connected, tunnel.configuredProfile == profile, network.routeRevision == revision else { continue }
            let proto = tunnel.protocolName
            let selected = DNSProviderSite.selected(endpoint: store.endpoint)?.rawValue ?? "Custom"
            var lines = ["Measured: " + Date().formatted(.iso8601), "Network: " + network.path, "Protocol: " + proto,
                "DNS source: " + (proto == "IKEv2" ? "Server-managed; saved encrypted resolver is not applied by IKEv2" : "Selected encrypted resolver: " + selected)]
            async let v4 = PublicIPProbe.run(.ipv4)
            async let v6 = PublicIPProbe.run(.ipv6, ipv6Supported: network.supportsIPv6)
            async let identity = ConnectionVerification.controlDSystemEvidence()
            let results = await (v4, v6, identity)
            for result in [results.0, results.1] {
                let family = result.family.rawValue
                let expected = UserDefaults.standard.string(forKey: "expected-exit-" + profile.uuidString + "-" + String(family)) ?? ""
                lines += ["IPv" + String(family) + ": " + (result.address ?? result.failure?.kind.rawValue ?? "Inconclusive"),
                    "Expected exit: " + ExitComparison.evaluate(observed: result.address, expected: expected, family: family).rawValue, result.detail]
            }
            lines.append("Control D system identity: " + (results.2 == true ? "Detected" : "Inconclusive"))
            for provider in DNSProviderSite.providers where provider != .controlD {
                let observation = await ProviderVerificationProbe.run(provider)
                lines += [provider.rawValue + ": " + observation.verdict.rawValue, observation.detail]
            }
            let reference = URL(string: "https://cloudflare-dns.com/dns-query")!
            for domain in ["example.com", "pagead2.googlesyndication.com", "www.google-analytics.com", "malware.testcategory.com"] {
                let system = await SystemDestinationObservation.resolveAuditHost(domain)
                lines += ["Domain: " + domain, system.summary]
                if let endpoint = try? DNSService.endpoint(store.endpoint) {
                    async let control = FilteringDiagnostics.observeDetailed(reference, domain: domain)
                    async let target = FilteringDiagnostics.observeDetailed(endpoint, domain: domain)
                    let observations = await (control, target)
                    let label = domain == "example.com" ? "Connectivity control (not expected blocked)" : "Explicit configured resolver filtering sample: " + DNSFilterObservation.verdict(control: observations.0.map(\.observation), target: observations.1.map(\.observation)).rawValue
                    lines += [label,
                        "Reference: " + observations.0.map(\.description).joined(separator: " | "),
                        "Configured resolver: " + observations.1.map(\.description).joined(separator: " | ")]
                }
            }
            guard !Task.isCancelled, tunnel.status == .connected, tunnel.configuredProfile == profile, network.routeRevision == revision else {
                tunnel.record("Connection audit discarded after route or VPN change", severity: .warning); continue
            }
            lines.append("No VPN bypass, system DNS substitution or settings change. Provider identity covers this app's sampled system path. Explicit resolver filtering samples do not establish IKEv2 filtering, other-app behavior, category-wide protection or leak isolation. Malware test name is safe Cloudflare test infrastructure, not universal provider coverage. example.com is a connectivity control, not expected to be blocked.")
            do {
                try LocalFiles.write(Data(lines.joined(separator: "\n").utf8), to: LocalFiles.url("connection-audit-" + proto.lowercased() + ".txt"))
                measured.insert(profile)
                store.notice = "Connection audit complete · " + proto
            } catch { store.notice = "Connection audit report could not be saved."; return }
        }
    }
}
#endif

#if DEBUG
struct SheetPreview: View {
    @ObservedObject var store: AppStore
    let kind: String
    @State private var shown = false
    var body: some View {
        Color(UIColor.systemGroupedBackground).ignoresSafeArea().vsHeader("Sheet")
            .sheet(isPresented: $shown) {
                if kind == "modes" { VSProtectionModeSheet(store: store, connectsAfterChoosing: false).vsDialogHost().vsSheetChrome([.fraction(0.86), .large]) }
                else { NavigationStack { VSAddProfileScreen { _ in } }.vsSheetChrome([.medium, .large]) }
            }
            .task { try? await Task.sleep(for: .milliseconds(500)); shown = true }
    }
}
struct DialogPreview: View {
    var destructive = true
    @State private var shown = false
    var body: some View {
        Color(UIColor.systemGroupedBackground).ignoresSafeArea().vsHeader("Dialog")
            .vsConfirm(isPresented: $shown, title: destructive ? "Delete profile and its keys?" : "Switch VPN profile?", message: destructive ? "The original imported file is preserved." : "Switching briefly disconnects the current VPN. The app waits for shutdown before connecting the selected profile.", confirm: destructive ? "Delete Profile" : "Switch Profile", destructive: destructive, icon: destructive ? "trash.fill" : "arrow.triangle.2.circlepath") { }
            .vsDialogHost()
            .task { try? await Task.sleep(for: .milliseconds(600)); shown = true }
    }
}
enum DebugScreens {
    static var requested: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--ui-screen"), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }
    @MainActor @ViewBuilder static func view(store: AppStore, tunnel: TunnelController, network: NetworkDiagnostics) -> some View {
        let f = store.filtering
        switch requested ?? "" {
        case "settings": VSSettingsScreen(store: store, tunnel: tunnel)
        case "privacyscreen": VSPrivacyScreen(filtering: f)
        case "connection": VSConnectionDetailsScreen(store: store, tunnel: tunnel)
        case "privacylock": VSPrivacyLockScreen(store: store, tunnel: tunnel)
        case "emergency": VSEmergencyResetScreen(store: store, tunnel: tunnel)
        case "compat": VSConflictsScreen(store: store, tunnel: tunnel)
        case "extensions": VSExtensionStatusScreen(store: store, tunnel: tunnel)
        case "activity": VSActivityScreen(filtering: f, tunnel: tunnel)
        case "appearance": VSAppearanceScreen()
        case "notifications": VSNotificationsScreen(tunnel: tunnel)
        case "permissions": VSProtectionPermissionsScreen(store: store, tunnel: tunnel)
        case "checks": VSChecksScreen(store: store, tunnel: tunnel, network: network)
        case "logs": VSLogsScreen(tunnel: tunnel)
        case "traffic": VSTrafficScreen(store: store, tunnel: tunnel)
        case "ip": VSIPDiscoveryScreen(network: network, tunnel: tunnel)
        case "verification": VSVerificationScreen(store: store, tunnel: tunnel, network: network)
        case "dnsprovider": VSDNSProviderChecksScreen(store: store, tunnel: tunnel, network: network)
        case "dnsdiag": VSDNSDiagnosticsScreen(store: store, tunnel: tunnel)
        case "dnssecurity": VSDNSSecurityScreen(store: store, tunnel: tunnel)
        case "modes": VSModeScreen(store: store, tunnel: tunnel)
        case "dnsfiltering": VSFilteringScreen(store: store, tunnel: tunnel, network: network)
        case "filterlists": VSFilterListsScreen(filtering: f)
        case "catalog": VSFilterCatalogScreen(filtering: f)
        case "customrules": VSCustomRulesScreen(filtering: f)
        case "health": VSFilterHealthScreen(filtering: f)
        case "website": VSRuleMatchScreen(filtering: f)
        case "safari": VSSafariScreen(filtering: f)
        case "exceptions": VSWebsiteExceptionsScreen(filtering: f)
        case "filteringsettings": VSFilteringSettingsScreen(filtering: f)
        case "adblocktest": VSAdblockTestScreen(filtering: f, store: store)
        case "privacy": VSPrivacyScreen(filtering: f)
        case "security": VSSecurityCenter(store: store, tunnel: tunnel)
        case "credits": VSFilterCreditsScreen()
        case "resolvers": VSDNSScreen(store: store, tunnel: tunnel, resolverManagementOnly: true)
        case "profiles": VSProfilesScreen(store: store, tunnel: tunnel, isRootTab: true)
        case "profileeditor": VSProfileEditor(store: store, tunnel: tunnel, draft: VSProfileDraft(name: "Example", text: "[Interface]\nPrivateKey = \nAddress = 10.0.0.2/32\n\n[Peer]\nPublicKey = \nEndpoint = vpn.example.com:51820\nAllowedIPs = 0.0.0.0/0\n"))
        case "resolvereditor": VSResolverEditor(store: store, tunnel: tunnel, draft: VSResolverDraft(name: "", endpoint: ""))
        case "ruleeditor": VSRuleEditor(filtering: f)
        case "onboarding": VSOnboardingScreen(store: store)
        case "sheet-modes": SheetPreview(store: store, kind: "modes")
        case "sheet-add": SheetPreview(store: store, kind: "add")
        case "dialog": DialogPreview()
        case "dialog2": DialogPreview(destructive: false)
        default: Text("Unknown screen")
        }
    }
}
#endif
