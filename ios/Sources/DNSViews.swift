import SwiftUI
import VayuSetuCore

struct VSResolverDraft: Identifiable {
    let id = UUID()
    var profileID: UUID?
    var name: String
    var endpoint: String
    var bootstrapAddresses: [String] = []
}
private struct DNSRouteKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }
private struct AdblockRouteKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }
extension EnvironmentValues { var openAdblockTab: (() -> Void)? { get { self[AdblockRouteKey.self] } set { self[AdblockRouteKey.self] = newValue } } }
extension EnvironmentValues { var openDNSTab: (() -> Void)? { get { self[DNSRouteKey.self] } set { self[DNSRouteKey.self] = newValue } } }

struct VSDNSScreen: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    @ObservedObject var systemDNS: SystemDNSController
    var isRootTab: Bool
    var resolverManagementOnly: Bool
    @ScaledMetric(relativeTo: .title) private var headerSize = 28
    init(store: AppStore, tunnel: TunnelController, isRootTab: Bool = false, resolverManagementOnly: Bool = false) { self.store = store; self.tunnel = tunnel; self.isRootTab = isRootTab; self.resolverManagementOnly = resolverManagementOnly; systemDNS = store.systemDNS }
    @State private var draft: VSResolverDraft?
    @State private var inspected: UUID?
    @State private var search = ""
    @State private var showingAdvanced = false
    @State private var showingResolvers = false
    @State private var enablingDNS = false
    @State private var activationOutcome = ""
    @State private var showingVerification = false
    @State private var showingMode = false
    @State private var showingActivation = false
    @State private var showingCompatibility = false
    @AppStorage("dns-vpn-notice-dismissed") private var noticeDismissed = false
    @Environment(\.openDNSTab) private var openDNSTab
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) fileprivate var dynamicTypeSize
    @StateObject private var overviewNetwork = NetworkDiagnostics()
    var locked: Bool { store.testing || tunnel.running || tunnel.busy || systemDNS.busy || store.connectionOperation }
    var matchingResolvers: [DNSProfile] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.dnsProfiles.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        AnyView(content
        #if os(iOS)
        .navigationTitle(resolverManagementOnly ? "DNS Resolvers" : isRootTab ? "" : "Encrypted DNS")
        .vsInlineTitle()
        .toolbar(isRootTab ? .hidden : .visible, for: .navigationBar)
        #else
        .vsHeader("Encrypted DNS").searchable(text: $search, prompt: "Search resolvers")
        .toolbar { ToolbarItem { Button { draft = VSResolverDraft(name: "", endpoint: "") } label: { Image(systemName: "plus").accessibilityLabel("Add resolver") }.disabled(locked) } }
        #endif
        .navigationDestination(isPresented: $showingMode) { VSModeScreen(store: store, tunnel: tunnel) }
        .navigationDestination(isPresented: $showingVerification) { VSVerificationScreen(store: store, tunnel: tunnel, network: overviewNetwork) }
        .navigationDestination(isPresented: $showingAdvanced) { advancedSettings }
        .navigationDestination(isPresented: $showingResolvers) { resolverLibrary }
        .sheet(isPresented: $showingActivation) { activationGuide.vsSheetChrome([.medium, .large]) }
        .onAppear { if !isRootTab && !resolverManagementOnly, let openDNSTab { dismiss(); openDNSTab() } }
        .sheet(item: $draft) { item in NavigationStack { VSResolverEditor(store: store, tunnel: tunnel, draft: item) }.vsDialogHost().vsSheetChrome() })
    }
    private var dnsHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Encrypted DNS").font(.system(size: headerSize, weight: .semibold))
                Text("Private. Encrypted. Under your control.").font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button { showingAdvanced = true } label: {
                Image(systemName: "gearshape").font(.system(size: 20, weight: .medium))
                    .frame(width: 44, height: 44).background(VSDesign.surface, in: Circle())
                    .overlay(Circle().stroke(VSDesign.separator, lineWidth: 1))
            }.buttonStyle(VSPlainButtonStyle()).accessibilityLabel("Advanced DNS Settings")
        }.padding(.top, 12)
    }
    private var dnsSnapshot: ProtectionSnapshot { store.protection(.dns) }
    private var nativeDNS: Bool { tunnel.running && tunnel.protocolName == "IKEv2" }
    private var observedMode: String {
        if dnsSnapshot.observed == .starting { return "DNS configuration pending" }
        if [.connecting, .reasserting, .disconnecting].contains(tunnel.status) { return tunnel.localDNSRunning ? "Local DNS tunnel starting" : "VPN transition" }
        if tunnel.localDNSRunning && tunnel.status == .connected { return "Encrypted DNS · local tunnel" }
        if tunnel.status == .connected { return "VPN-Managed DNS" }
        if systemDNS.hasForeignConfiguration { return "Other DNS configuration" }
        if systemDNS.enabled == nil { return "DNS status unknown" }
        return systemDNS.enabled == true ? "Independent encrypted DNS" : "System DNS"
    }
    private var observedResolver: String {
        if nativeDNS { return "Server-managed" }
        if tunnel.localDNSRunning { return store.dnsName + " · local tunnel" }
        if systemDNS.hasForeignConfiguration && !tunnel.running { return "External configuration · unverified" }
        if tunnel.running { return tunnel.acceptedResolverMatches(store.endpoint) ? store.dnsName + " · settings accepted" : "VPN resolver · identity unconfirmed" }
        if systemDNS.enabled == true { return systemDNS.configuredResolverMatches(store.endpoint) ? store.dnsName + " · configured" : "System encrypted configuration" }
        if systemDNS.enabled == nil { return "Configuration unavailable" }
        return "Network-provided"
    }
    private var configuredTransport: String {
        if nativeDNS { return "Server-provided DNS" }
        if tunnel.localDNSRunning { return store.endpoint.isEmpty ? "Unavailable" : DNSService.transport(store.endpoint) }
        if tunnel.acceptedResolverMatches(store.endpoint) || systemDNS.enabled == true && systemDNS.configuredResolverMatches(store.endpoint) { return store.endpoint.isEmpty ? "Unavailable" : DNSService.transport(store.endpoint) }
        if systemDNS.enabled == true { return "OS encrypted DNS · identity unverified" }
        if systemDNS.enabled == nil { return "Not observed" }
        return "System DNS"
    }
    private var statusTitle: String {
        switch dnsSnapshot.observed {
        case .active: return "DNS ACTIVE"
        case .inactive: return systemDNS.hasForeignConfiguration ? "OTHER DNS CONFIGURATION" : "SYSTEM DNS"
        case .enabledNotVerified: return "NOT VERIFIED"
        case .starting: return "CONFIGURING"
        case .limited: return "LIMITED"
        case .needsAttention: return "NEEDS ATTENTION"
        case .error: return "DNS ERROR"
        case .unknown: return "STATUS UNKNOWN"
        }
    }
    private var statusColor: Color {
        switch dnsSnapshot.observed {
        case .active: return Color.green
        case .starting, .enabledNotVerified, .limited, .needsAttention: return Color.orange
        case .error: return Color.red
        case .inactive, .unknown: return .secondary
        }
    }
    // Encrypted DNS runs in VayuSetu's own tunnel; no iOS DNS profile is ever installed or activated.
    private var activationRequired: Bool { false }
    private var preferredConfigured: Bool { tunnel.acceptedResolverMatches(store.endpoint) || !tunnel.running && systemDNS.enabled == true && systemDNS.configuredResolverMatches(store.endpoint) }
    private var protectionTitle: String {
        if enablingDNS || tunnel.busy { return "Configuring" }
        if tunnel.localDNSRunning { return dnsSnapshot.observed == .active ? "Local DNS · answering queries" : "Local DNS · not verified" }
        if preferredConfigured { return "Enabled · not verified" }
        if activationRequired { return "Awaiting iOS activation" }
        if tunnel.running { return "VPN DNS · not verified" }
        if systemDNS.hasForeignConfiguration { return "Configuration conflict" }
        if systemDNS.enabled == nil { return "Status unknown" }
        return systemDNS.hasSavedConfiguration ? "Needs attention" : "Not installed"
    }
    private var dnsStatusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("DNS Protection").font(.headline)
                Spacer(minLength: 4)
                Text(protectionTitle).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("DNSObservedStatus")
            }
            VSEvidenceRow(title: "Current DNS", value: observedMode).accessibilityIdentifier("DNSObservedMode")
            VSEvidenceRow(title: "Preferred provider", value: store.endpoint.isEmpty ? "Choose a provider" : preferredName).accessibilityIdentifier("DNSPreferredResolver")
            VSEvidenceRow(title: "Encryption", value: "Not independently verified").accessibilityIdentifier("DNSObservedResolver")
            if store.dnsVerifying { VSEvidenceRow(title: "DNS verification", value: "Checking…") }
            else if let check = store.dnsVerification {
                VSEvidenceRow(title: "Last DNS verification", value: (check.passed ? "Passed" : "Failed") + " · " + check.date.formatted(date: .omitted, time: .shortened)).accessibilityIdentifier("DNSVerification")
                Text(check.detail).font(.caption).foregroundStyle(.secondary)
            }
            if tunnel.running, let counters = tunnel.stats?.dnsCounters {
                // Counts come from the extension itself; apps with their own DNS never appear here.
                VSEvidenceRow(title: "Queries answered", value: "\(counters.answered) of \(counters.queries)").accessibilityIdentifier("DNSLocalAnswered")
                VSEvidenceRow(title: "Upstream failures", value: "\(counters.failed)")
                if store.isVayuSetuDNSSelected {
                    VSEvidenceRow(title: "Blocked by VayuSetu lists", value: "\(counters.blocked)").accessibilityIdentifier("DNSLocalBlocked")
                    VSEvidenceRow(title: "Filter rules loaded", value: counters.rules == 0 ? "None · nothing is blocked" : "\(counters.rules)")
                }
            }
            if tunnel.running {
                Text(observedResolver).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("DNSAcceptedResolver")
                if systemDNS.desiredEnabled == true && systemDNS.hasSuspendedConfiguration {
                    Text("Independent DNS is paused for this VPN. Its configuration will be restored when the VPN stops; iOS activation may be required.")
                        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("DNSSuspendedPreference")
                }
            }
            Button {
                if tunnel.localDNSRunning {
                    enablingDNS = true
                    Task { activationOutcome = await store.changeDNSMode(.system); enablingDNS = false }
                }
                else if preferredConfigured { showingVerification = true }
                else if tunnel.running { showingMode = true }
                else if activationRequired { showingActivation = true }
                else if store.endpoint.isEmpty { showingResolvers = true }
                else {
                    enablingDNS = true
                    Task {
                        activationOutcome = await store.changeDNSMode(.encrypted)
                        enablingDNS = false
                        if activationRequired { showingActivation = true }
                    }
                }
            } label: {
                Text(tunnel.localDNSRunning ? "Disable Encrypted DNS" : preferredConfigured ? "Verify DNS" : tunnel.running ? "Review VPN DNS" : activationRequired ? "Finish Activation in iOS Settings" : store.endpoint.isEmpty ? "Choose Provider" : "Enable Encrypted DNS")
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.borderedProminent).vsTapHaptic().accessibilityIdentifier("DNSEnableProtection")
                .disabled(enablingDNS || systemDNS.busy || tunnel.busy || store.connectionOperation || store.testing)
            HStack(spacing: 10) {
                Button("Change Provider") { showingResolvers = true }
                    .accessibilityIdentifier("DNSChangeResolver")
                Spacer()
                Button("Verify DNS") { Task { tunnel.refreshStatus(); tunnel.refreshStats(); await systemDNS.refresh(); await store.verifyLocalDNS() } }
                    .accessibilityIdentifier("DNSRefreshStatus").disabled(systemDNS.busy)
            }.font(.subheadline).frame(minHeight: 44)
            if activationRequired {
                Text("Configuration installed. Finish activation in iOS Settings; no reinstall is needed.")
                    .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("DNSActivationHandoff")
            } else if !activationOutcome.isEmpty {
                Text(activationOutcome).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("DNSEnableOutcome")
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(VSDesign.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(VSDesign.separator, lineWidth: 1))
    }
    private var preferredName: String {
        // Hide only the legacy migration prefix; retain the persisted user label.
        store.dnsName.hasPrefix("Recovered ") ? String(store.dnsName.dropFirst(10)) : store.dnsName
    }
    private var activationGuide: some View {
        NavigationStack {
            VSCardList {
                VSSection {
                    Text("Your resolver configuration is installed. iOS requires you to select it before it can be used.")
                    Text("1. Open the Settings app.")
                    Text("2. Choose General → VPN & Device Management → DNS.")
                    Text("3. Select VayuSetu encrypted DNS.")
                    Text("4. Return to VayuSetu. Its status will refresh automatically.")
                } header: { Text("Finish activation") }
                VSSection {
                    Button("I’ve Returned — Check Status") {
                        Task { await systemDNS.refresh(); showingActivation = false }
                    }.accessibilityIdentifier("DNSActivationCheck")
                } footer: { Text("An enabled configuration does not by itself verify DNS traffic or filtering. Use Verify DNS afterwards.") }
            }.vsList().vsHeader("Activate Encrypted DNS")
                .toolbar { ToolbarItem(placement: .confirmationAction) { VSCloseButton(label: "Done") { showingActivation = false } } }
        }
    }
    private var resolverLibrary: some View {
        List {
            VSFormSection {
                TextField("Search resolvers", text: $search).autocorrectionDisabled().frame(minHeight: 26)
                ForEach(matchingResolvers) { resolver in
                    Button { store.loadDNS(resolver) } label: {
                        VSRow(title: resolver.name, subtitle: store.selectedDNS == resolver.id ? "Preferred · saved choice, not proof of active DNS" : "Saved encrypted resolver", icon: "network", selected: store.selectedDNS == resolver.id)
                    }.buttonStyle(VSPlainButtonStyle()).disabled(locked)
                        .contextMenu { Button("Edit Resolver") { edit(resolver) }.disabled(locked) }
                }
                if store.dnsProfiles.isEmpty { Text("Add your provider’s encrypted DNS endpoint.").foregroundStyle(.secondary) }
                else if matchingResolvers.isEmpty { ContentUnavailableView.search(text: search) }
            } header: { Text("Saved resolvers") } footer: { Text("The checkmark identifies your preferred configuration. It does not indicate active or verified DNS."); if locked { Text("Resolver changes are unavailable while a VPN or DNS operation is active. Disconnect first; your current connection is preserved.") } }
            VSFormSection { Button { draft = VSResolverDraft(name: "", endpoint: "") } label: { Label("Add Custom Resolver", systemImage: "plus").frame(minHeight: 26) }.disabled(locked).accessibilityLabel("Add resolver") }
        }.vsList().vsCompactDetails().vsHeader("DNS Resolvers").vsEditor()
    }
    private var advancedSettings: some View {
        VSCardList {
            VSSection("Configuration") {
                Button("Edit Selected Resolver") { edit(store.dnsProfiles.first { $0.id == store.selectedDNS }) }
                    .disabled(locked || store.endpoint.isEmpty)
                VSNavLink("Protection Modes") { VSModeScreen(store: store, tunnel: tunnel) }
                VSNavLink("DNS Security") { VSDNSSecurityScreen(store: store, tunnel: tunnel) }
            }
            VSSection("Runtime capabilities") {
                let runtime = tunnel.localDNSRunning ? ProtectionRuntime.localDNSTunnel : tunnel.running ? store.observedVPNRuntime : ProtectionRuntime.localDNSTunnel
                VSEvidenceRow(title: "Selected encrypted resolver", value: runtime.capabilities.selectedEncryptedResolver ? "Supported by configuration" : "Unavailable")
                VSEvidenceRow(title: "Local DNS filtering", value: runtime.capabilities.localDNSFiltering ? "Supported" : "Unavailable")
                Text(runtime.capabilities.limitation).font(.footnote).foregroundStyle(.secondary)
            }
            VSSection("Verification") {
                VSNavLink("DNS Diagnostics") { VSDNSDiagnosticsScreen(store: store, tunnel: tunnel) }
                Text("Saved configuration does not prove the DNS route or filtering behavior.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.vsList().vsHeader("Advanced DNS Settings")
    }
    var content: AnyView {
        if resolverManagementOnly { return AnyView(resolverLibrary) }
        #if os(macOS)
        return AnyView(HSplitView { resolverList.frame(minWidth: 220, idealWidth: 260, maxWidth: 340); resolverDetail.frame(minWidth: 280, maxWidth: .infinity) })
        #else
        return AnyView(iosOverview)
        #endif
    }
    private var iosOverview: some View { dashboard }
    var resolverList: some View {
        List {
            VSFormSection {
                dnsHeader.listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 12, trailing: 20))
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            VSFormSection {
                dnsStatusCard.listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            if tunnel.running && tunnel.protocolName == "IKEv2" {
                VSFormSection { Text("IKEv2 uses server-managed DNS. The encrypted resolver selected below is not applied by the native adapter.").font(.footnote).foregroundStyle(.orange) }
            }
            VSFormSection("Protection modes") {
                NavigationLink { VSModeScreen(store: store, tunnel: tunnel) } label: {
                    VSRow(title: "Protection modes", subtitle: "Which mode the power button starts", icon: "arrow.triangle.branch", value: store.savedModeTitle).frame(minHeight: 26)
                }.accessibilityIdentifier("DNSModeSelection")
            }
            if store.isVayuSetuDNSSelected {
                VSFormSection {
                    NavigationLink { VSFilterListsScreen(filtering: store.filtering) } label: {
                        VSRow(title: "VayuSetu filter lists", subtitle: "\(store.filtering.configuration.subscriptions.filter(\.enabled).count) enabled · \(store.filtering.configuration.effective.count) rules", icon: "line.3.horizontal.decrease.circle", chevron: true)
                    }.accessibilityIdentifier("DNSFilterLists")
                    Toggle("Resolve outside the VPN", isOn: $store.dnsUpstreamDirect).disabled(tunnel.running || tunnel.busy)
                        .accessibilityIdentifier("DNSUpstreamDirect")
                } footer: {
                    Text(tunnel.running && tunnel.protocolName == "IKEv2"
                         ? "This connection is Apple’s system IKEv2. Its DNS packets never reach VayuSetu, so the lists cannot be applied. Use a WireGuard profile or DNS Only for filtering."
                         : "Enabled lists are applied on this device to every DNS query while VayuSetu DNS is running, with DNS Only or a WireGuard VPN. Add HaGeZi, OISD, AdGuard or StevenBlack lists there. Anything you allow overrides a list. With a VPN, filtered DNS goes through the VPN unless you turn on ‘Resolve outside the VPN’ (use it only if names stop resolving).")
                }
            }
            if store.selectedVPNKind == .ikev2 || (tunnel.running && tunnel.protocolName == "IKEv2") {
                // Apple's Personal VPN API gives an app no DNS control over IKEv2; only the server (or an installed
                // configuration profile) decides. State the real capabilities instead of implying the resolver applies.
                VSFormSection {
                    VSRow(title: "Resolver", value: "Set by the VPN server")
                    VSRow(title: "\(store.dnsName.isEmpty ? "Selected resolver" : store.dnsName)", value: "Not applied")
                    VSRow(title: "VayuSetu filter lists", value: "Not applied")
                    VSRow(title: "Provider-side blocking", value: "Only if the server uses a filtering DNS")
                    VSRow(title: "Safari adblocking", value: "Works independently")
                } header: { Text("IKEv2 and DNS") } footer: {
                    Text("Apple’s IKEv2 takes its DNS from the VPN server, and iOS ignores the encrypted resolver you choose here while it is connected. To use \(store.dnsName.isEmpty ? "your resolver" : store.dnsName) or the filter lists: ask your VPN provider to use that DNS, use a WireGuard profile, or turn the VPN pill off to run DNS Only.")
                }
            }
            VSFormSection("Current configuration") {
                VSRow(title: "Resolver", value: observedResolver)
                VSRow(title: "Protocol", value: configuredTransport)
                VSRow(title: "Encryption", value: nativeDNS ? "Unverified" : tunnel.running || systemDNS.enabled == true ? "Required by configuration" : "Not configured")
                VSRow(title: "DNS verification", value: "Behavior not verified")
                VSRow(title: "Last behavior check", value: "No current evidence")
            }
            VSFormSection {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search resolvers", text: $search).autocorrectionDisabled()
                }.frame(minHeight: 26)
                ForEach(matchingResolvers) { resolver in
                    Button {
                        #if os(macOS)
                        inspected = resolver.id
                        #else
                        if !locked { store.loadDNS(resolver) }
                        #endif
                    } label: { VSRow(title: resolver.name, subtitle: store.selectedDNS == resolver.id ? DNSService.transport(store.endpoint) : "Encrypted resolver", icon: "network", selected: store.selectedDNS == resolver.id) }.buttonStyle(VSPlainButtonStyle())
                        .listRowBackground(store.selectedDNS == resolver.id ? VSDesign.accent.opacity(0.08) : VSDesign.surface)
                        .contextMenu { Button("Edit Resolver") { edit(resolver) }.disabled(locked) }
                        .disabled(locked)
                }
                if store.dnsProfiles.isEmpty { Text("Add your provider’s encrypted DNS endpoint.").foregroundStyle(.secondary) }
                else if matchingResolvers.isEmpty { ContentUnavailableView.search(text: search) }
                Button { draft = VSResolverDraft(name: "", endpoint: "") } label: {
                    Label("Add Custom Resolver", systemImage: "plus").frame(minHeight: 26)
                }.disabled(locked).accessibilityLabel("Add resolver")
            } header: { Text("Resolvers") } footer: { if locked { Text(systemDNS.busy ? "Wait for the DNS operation to finish." : store.testing ? "Wait for the DNS check to finish." : "Disconnect to change resolvers.") } }
            if !store.endpoint.isEmpty {
                VSFormSection {
                    Button { edit(store.dnsProfiles.first(where: { $0.id == store.selectedDNS })) } label: { VSRow(title: "Resolver details", subtitle: store.dnsName, icon: "slider.horizontal.3", chevron: true) }.buttonStyle(VSPlainButtonStyle()).disabled(locked)
                }
            }
            VSFormSection {
                NavigationLink { VSModeScreen(store: store, tunnel: tunnel) } label: { VSRow(title: "Protection modes", icon: "arrow.triangle.branch", value: store.savedModeTitle) }
                NavigationLink { VSDNSSecurityScreen(store: store, tunnel: tunnel) } label: { VSRow(title: "DNS Security", icon: "hand.raised") }
                NavigationLink { VSDNSDiagnosticsScreen(store: store, tunnel: tunnel) } label: { VSRow(title: "DNS Diagnostics", icon: "waveform.path.ecg") }
            } footer: { Text("Routing verification pending.") }
        }.vsList()
    }
    var resolverDetail: some View {
        List {
            if let profile = store.dnsProfiles.first(where: { $0.id == inspected }) ?? store.dnsProfiles.first(where: { $0.id == store.selectedDNS }) {
                VSFormSection(profile.name) { VSRow(title: "Endpoint", subtitle: "Stored securely in Keychain", icon: "lock"); VSRow(title: "Identity", value: "Not verified"); Button(store.selectedDNS == profile.id ? "Preferred Resolver" : "Set Preferred") { store.loadDNS(profile) }.disabled(locked || store.selectedDNS == profile.id); Button("Edit Resolver") { edit(profile) }.disabled(locked) }
            } else { VSFormSection { Text("Select or add an encrypted DNS resolver.").foregroundStyle(.secondary) } }
            if !store.endpoint.isEmpty { VSFormSection("Preferred resolver response test") { Button(store.testing ? "Testing…" : "Test DNS Response") { store.testDNS() }.disabled(store.testing); if !store.result.isEmpty { Text(store.result).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) } } }
        }.vsList()
    }
    func edit(_ profile: DNSProfile?) {
        do {
            let endpoint: String
            if let profile { guard let data = try Vault.get("dns-" + profile.id.uuidString), let value = String(data: data, encoding: .utf8) else { throw AppIssue(message: "Missing resolver endpoint.") }; endpoint = value }
            else { endpoint = store.endpoint }
            draft = VSResolverDraft(profileID: profile?.id, name: profile?.name ?? store.dnsName, endpoint: endpoint, bootstrapAddresses: profile?.bootstrapAddresses ?? store.bootstrapAddresses)
        } catch { store.notice = "Could not read the resolver endpoint from Keychain." }
    }
}
struct VSResolverEditor: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    let draft: VSResolverDraft
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var endpoint: String
    @State private var bootstrapText: String
    @State private var transport: String
    @State private var reveal = false
    @State private var error = ""
    @State private var removing = false
    @State private var showError = false
    init(store: AppStore, tunnel: TunnelController, draft: VSResolverDraft) { self.store = store; self.tunnel = tunnel; self.draft = draft; _bootstrapText = State(initialValue: draft.bootstrapAddresses.joined(separator: ", ")); _name = State(initialValue: draft.name); _endpoint = State(initialValue: draft.endpoint); _transport = State(initialValue: draft.endpoint.lowercased().hasPrefix("tls:") ? "DoT" : "DoH") }
    var locked: Bool { tunnel.running || tunnel.busy || store.testing || store.systemDNS.busy || store.connectionOperation }
    var body: some View {
        AnyView(Form {
            VSFormSection("Resolver") { TextField("Name", text: $name) }
            VSFormSection {
                Picker("Transport", selection: $transport) { Text("DNS-over-HTTPS").tag("DoH"); Text("DNS-over-TLS").tag("DoT") }
                HStack { Group { if reveal { TextField(transport == "DoH" ? "https://hostname/path" : "tls://hostname", text: $endpoint) } else { SecureField(transport == "DoH" ? "HTTPS endpoint" : "TLS hostname URI", text: $endpoint) } }.vsInput(); Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }.buttonStyle(.borderless).accessibilityLabel(reveal ? "Hide resolver endpoint" : "Reveal resolver endpoint") }
                VSRow(title: "Port", value: transport == "DoH" ? "443" : "853")
                TextField("Provider bootstrap IPs (optional)", text: $bootstrapText).vsInput()
                Text("Use only addresses published by your resolver provider. Leave empty for a bounded system lookup before the VPN starts. Supplied addresses keep hostname certificate validation and never bypass the VPN.").font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Advanced") } footer: { Text("Saved in Keychain. Custom ports and authentication headers are unsupported.") }
            if !error.isEmpty { VSFormSection { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.footnote) } }
            if draft.profileID != nil, draft.profileID == store.selectedDNS { VSFormSection { Button("Delete Resolver", role: .destructive) { removing = true }.disabled(locked) } }
        }.formStyle(.grouped).vsFormLook().buttonStyle(VSDefaultButtonStyle()).scrollIndicators(.hidden).vsHeader(draft.profileID == nil ? "New Resolver" : "Edit Resolver").vsEditor()
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.vsTapHaptic() }; ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.vsTapHaptic().disabled(locked || name.isEmpty || endpoint.isEmpty || (draft.profileID != nil && name == draft.name && endpoint == draft.endpoint && bootstrapText == draft.bootstrapAddresses.joined(separator: ", "))) } }
        .vsAlert(isPresented: $showError, tone: .danger, icon: "xmark.octagon.fill", title: "Could not save", message: error)
        .vsConfirm(isPresented: $removing, title: "Delete this resolver?", message: "The resolver and its saved VPN configuration are removed. Other profiles are preserved.", confirm: "Delete Resolver", destructive: true, icon: "trash.fill") { Task { if await store.forgetEndpoint() { dismiss() } } })
    }
    func save() {
        do { let url = try DNSService.endpoint(endpoint); guard (url.scheme?.lowercased() == "tls" ? "DoT" : "DoH") == transport else { throw AppIssue(message: "Enter an endpoint matching the selected transport. DoH uses https://hostname/path; DoT uses tls://hostname.") } }
        catch { self.error = error.localizedDescription; showError = true; return }
        let values = bootstrapText.split { $0 == "," || $0.isWhitespace }.map(String.init)
        do { if !values.isEmpty { _ = try ResolverBootstrap.validated(values) } }
        catch { self.error = error.localizedDescription; showError = true; return }
        let previous = (store.selectedDNS, store.dnsName, store.endpoint, store.result, store.bootstrapAddresses)
        store.selectedDNS = draft.profileID; store.dnsName = name; store.endpoint = endpoint; store.bootstrapAddresses = values; store.notice = ""; store.saveEndpoint()
        if store.notice.hasPrefix("Resolver profile saved.") {
            if let old = previous.0, draft.profileID != nil, old != draft.profileID, let profile = store.dnsProfiles.first(where: { $0.id == old }) { store.loadDNS(profile) }
            dismiss()
        } else { error = store.notice; showError = true; store.notice = ""; store.selectedDNS = previous.0; store.dnsName = previous.1; store.endpoint = previous.2; store.result = previous.3; store.bootstrapAddresses = previous.4 }
    }
}
struct VSModeScreen: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    private struct Choice: Identifiable { let id: String; let title: String; let detail: String; let icon: String; let vpn: Bool; let dns: Bool }
    private var choices: [Choice] {
        let resolver = store.dnsName.isEmpty ? "your DNS resolver" : store.dnsName
        return [
            Choice(id: "vpnDNS", title: "VPN + DNS", detail: "Your VPN profile with \(resolver). WireGuard uses it, with your filter lists; IKEv2 uses the VPN server’s own DNS.", icon: "shield.lefthalf.filled", vpn: true, dns: true),
            Choice(id: "vpn", title: "VPN Only", detail: "Your VPN profile and the DNS it provides. VayuSetu changes nothing about DNS.", icon: "lock.shield", vpn: true, dns: false),
            Choice(id: "dns", title: "DNS Only", detail: "VayuSetu’s own DNS tunnel with \(resolver) and your filter lists. No VPN server, no VPN profile needed.", icon: "network", vpn: false, dns: true)
        ]
    }
    private var current: String? { store.savedNetwork.flatMap { saved in choices.first { $0.vpn == saved.vpn && $0.dns == saved.dns }?.id } }
    var body: some View {
        VSCardList {
            VSSection {
                ForEach(choices) { choice in
                    Button { store.saveMode(vpn: choice.vpn, dns: choice.dns) } label: {
                        VSRow(title: choice.title, subtitle: choice.detail, icon: choice.icon, selected: current == choice.id)
                    }.buttonStyle(VSPlainButtonStyle()).accessibilityIdentifier("ProtectionMode-" + choice.id)
                }
            } header: { Text("Mode the power button starts") } footer: { Text("This is the mode used the next time you tap the power button on Home. Now running: \(store.observedMode.title). To switch right now, touch and hold the power button on Home.") }
            VSSection("Safari adblocking") { Text("Adblock in Safari is separate. It works with every mode above, or on its own, and is switched on the Adblock tab or the Adblock pill on Home.").font(.footnote).foregroundStyle(.secondary) }
            VSSection("Independent DNS next to a VPN") { Text("Not possible on iOS for a VPN profile. While a VPN is on, DNS either goes through it or is set by it. For VayuSetu’s encrypted DNS and filtering without a VPN server, use DNS Only.").font(.footnote).foregroundStyle(.secondary) }
        }.vsList().vsHeader("Protection Modes").vsEditor()
    }
}

struct VSDNSSecurityScreen: View {
    @StateObject private var network = NetworkDiagnostics()
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    var body: some View {
        VSCardList {
            VSSection("Transport") { VSRow(title: "Selected transport", value: store.endpoint.isEmpty ? "Unavailable" : DNSService.transport(store.endpoint)); VSRow(title: "Requested routing", value: tunnel.protocolName == "IKEv2" ? "VPN server-managed" : "DNS through VPN"); VSRow(title: "Plaintext fallback", value: "Not configured"); Text("Encrypted configuration does not independently prove which route the OS used. Resolver policy and runtime evidence remain separate.").font(.footnote).foregroundStyle(.secondary) }
            VSSection("Provider protection") { Text("Provider-side filtering depends on the selected resolver’s policy; VayuSetu does not infer categories from an endpoint name. VayuSetu’s own filter lists apply only with VayuSetu DNS.").font(.footnote); VSNavLink { VSFilteringScreen(store: store, tunnel: tunnel, network: network) } label: { Text("Controlled Filtering Checks") } }
            VSSection("Compatibility") { VSNavLink { VSConflictsScreen(store: store, tunnel: tunnel) } label: { Text("Conflicts & Capability Status") }; VSNavLink { VSModeScreen(store: store, tunnel: tunnel) } label: { Text("Routing Policy") } }
        }.vsList().vsCompactDetails().vsHeader("DNS Security").vsEditor()
    }
}
struct VSDNSDiagnosticsScreen: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    @StateObject private var network = NetworkDiagnostics()
    private var runtimeName: String {
        if tunnel.localDNSRunning { return "Local DNS tunnel" }
        if tunnel.running { return tunnel.protocolName == "IKEv2" ? "IKEv2 · DNS set by the VPN server" : (tunnel.stats?.dnsCounters != nil ? "WireGuard · VayuSetu DNS filter" : "WireGuard · resolver or profile DNS") }
        return "None running"
    }
    var body: some View {
        VSCardList {
            VSSection("Runtime") {
                VSRow(title: "Active DNS runtime", value: runtimeName)
                VSRow(title: "Selected resolver", value: store.endpoint.isEmpty ? "None" : store.dnsName)
                VSRow(title: "Transport", value: store.endpoint.isEmpty ? "—" : DNSService.transport(store.endpoint))
                if tunnel.running, let c = tunnel.stats?.dnsCounters {
                    VSRow(title: "Queries", value: "\(c.queries) · answered \(c.answered) · failed \(c.failed)")
                    if store.isVayuSetuDNSSelected {
                        VSRow(title: "Blocked locally", value: "\(c.blocked)")
                        VSRow(title: "Filter rules loaded", value: "\(c.rules)")
                    }
                } else { VSRow(title: "Query counters", value: "Unavailable for this runtime") }
                VSRow(title: "Filter lists configured", value: "\(store.filtering.configuration.subscriptions.filter(\.enabled).count) lists · \((store.filtering.configuration.uniqueRules ?? store.filtering.configuration.effective.count).formatted()) rules")
                VSRow(title: "Last verification", value: store.dnsVerification.map { ($0.passed ? "Passed" : "Failed") + " · " + $0.date.formatted(date: .abbreviated, time: .shortened) } ?? "None yet")
                if let check = store.dnsVerification { Text(check.detail).font(.footnote).foregroundStyle(.secondary) }
            }
            VSSection("Resolver response") { VSRow(title: "Resolver", value: store.dnsName); Button(store.testing ? "Testing…" : "Test DNS Response") { store.testDNS() }.disabled(store.testing || store.endpoint.isEmpty); Text(store.result.isEmpty ? "No measured response yet" : store.result).font(.footnote).textSelection(.enabled); Text("A response proves endpoint responsiveness on the current route, not provider identity, DNS isolation or filtering effectiveness.").font(.footnote).foregroundStyle(.secondary) }
            VSSection("Independent evidence") { VSNavLink { VSDNSProviderChecksScreen(store: store, tunnel: tunnel, network: network) } label: { Text("DNS Provider & Website Checks") }; VSNavLink { VSVerificationScreen(store: store, tunnel: tunnel, network: network) } label: { Text("Connection Verification") }; VSNavLink { VSFilteringScreen(store: store, tunnel: tunnel, network: network) } label: { Text("Ad & Tracker Filtering Checks") } }
        }.vsList().vsCompactDetails().vsHeader("DNS Diagnostics").vsEditor()
    }
}

private extension DNSManagementMode {
    var icon: String {
        switch self { case .system: "network"; case .encrypted: "globe"; case .vpn: "point.3.connected.trianglepath.dotted" }
    }
    var detail: String {
        switch self {
        case .system: "Use network or system-provided DNS."
        case .encrypted: "Use the preferred DoH or DoT resolver through VayuSetu's local DNS tunnel. No VPN server and no iOS DNS profile."
        case .vpn: "Connect the selected VPN and use its DNS policy."
        }
    }
}


// MARK: - DNS dashboard. The view only draws `DNSDashboardModel`; facts come from the shared coordinator state.
private enum DashboardMetrics {
    static let screenInset: CGFloat = 16
    static let sectionGap: CGFloat = 12
    static let cardPadding: CGFloat = 12
    static let cardRadius: CGFloat = 12
    static let innerRadius: CGFloat = 10
    static let iconColumn: CGFloat = 28
    static let tileGap: CGFloat = 10
}

extension VSDNSScreen {
    fileprivate var cardBorder: Color { VSDesign.separator }
    fileprivate var teal: Color { Color(red: 0.0, green: 0.78, blue: 0.82) }
    fileprivate func color(_ tone: DNSTone) -> Color {
        switch tone {
        case .good: return Color.green
        case .caution: return Color.orange
        case .bad: return Color.red
        case .neutral: return .secondary
        }
    }
    fileprivate var pillState: PillState { store.dnsPill }
    /// The switch shows what the user asked for; the status panel shows what is observed.
    fileprivate var requested: Bool { pillState != .off || (store.protectionBusy && store.selection.dnsEnabled) }
    fileprivate var onIKEv2: Bool { tunnel.running && tunnel.protocolName == "IKEv2" }
    fileprivate var transportKind: DNSTransportKind { DNSService.transport(store.endpoint) == "DNS-over-TLS" ? .dot : .doh }
    fileprivate var counters: DNSOnlyCounters? { tunnel.running ? tunnel.stats?.dnsCounters : nil }
    fileprivate var dashboardModel: DNSDashboardModel {
        let level: DNSLevel
        switch pillState { case .off: level = .off; case .active: level = .active; case .pending: level = .pending; case .limited: level = .limited; case .failed: level = .failed }
        return DNSDashboardModel.make(DNSDashboardInput(
            level: level,
            connecting: store.protectionBusy || [.connecting, .reasserting].contains(tunnel.status),
            onIKEv2: onIKEv2, vpnRunning: tunnel.running && !tunnel.localDNSRunning,
            hasResolver: !store.endpoint.isEmpty, resolverName: preferredName, transport: transportKind,
            localListsSelected: store.isVayuSetuDNSSelected, loadedRules: counters.map { Int($0.rules) },
            reason: store.protection(.dns).reason, failedCheckDetail: store.dnsVerification.flatMap { $0.passed ? nil : $0.detail }))
    }
    fileprivate var dynamicTypeIsLarge: Bool { dynamicTypeSize >= .xxLarge }

    fileprivate var dashboard: some View {
        ScrollView {
            VStack(spacing: DashboardMetrics.sectionGap) {
                dashboardHeader
                protectionCard
                VSActivityDashboard(filtering: store.filtering)
                securitySection
                if showCompatibilityNotice { compatibilityNotice }
            }.padding(.horizontal, DashboardMetrics.screenInset).padding(.top, 8).padding(.bottom, 110)    // clears the floating tab bar
        }
        .scrollIndicators(.hidden).background(VSDesign.background)
        .sheet(isPresented: $showingCompatibility) { compatibilityDetails.vsSheetChrome() }
        .task { await systemDNS.refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await systemDNS.refresh() } } }
    }
    fileprivate var dashboardHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Encrypted DNS").font(.system(size: headerSize, weight: .semibold))
                Text("Private. Encrypted. Under your control.").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            NavigationLink { VSSettingsScreen(store: store, tunnel: tunnel) } label: {
                Image(systemName: "gearshape").font(.system(size: 20, weight: .medium)).frame(width: 44, height: 44)
                    .background(VSDesign.surface, in: Circle()).overlay(Circle().stroke(cardBorder, lineWidth: 1))
            }.buttonStyle(VSPlainButtonStyle()).accessibilityLabel("Open Settings")
        }.padding(.top, 12).accessibilityIdentifier("DNSHeader")
    }
    fileprivate func card<Content: View>(spacing: CGFloat = 16, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: spacing) { content() }
            .frame(maxWidth: .infinity, alignment: .leading).padding(DashboardMetrics.cardPadding)
            .background(VSDesign.surface, in: RoundedRectangle(cornerRadius: DashboardMetrics.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: DashboardMetrics.cardRadius).stroke(cardBorder, lineWidth: 1))
    }
    fileprivate func inset<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().background(VSDesign.background.opacity(0.5), in: RoundedRectangle(cornerRadius: DashboardMetrics.innerRadius))
            .overlay(RoundedRectangle(cornerRadius: DashboardMetrics.innerRadius).stroke(cardBorder, lineWidth: 1))
    }

    // MARK: Protection card
    fileprivate var protectionCard: some View {
        card {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("DNS Protection").font(.title3.weight(.semibold))
                    Text("Encrypt DNS queries and optionally filter unwanted domains.").font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("DNS Protection", isOn: Binding(get: { requested }, set: { newValue in
                    guard newValue != requested else { return }
                    if newValue && store.endpoint.isEmpty { showingResolvers = true; return }
                    Task { await store.togglePill(.dns) }
                })).labelsHidden().disabled(store.protectionBusy || tunnel.busy).frame(minHeight: 44)
                    .accessibilityLabel("DNS Protection").accessibilityValue(requested ? "On" : "Off").accessibilityIdentifier("DNSProtectionToggle")
            }
            let model = dashboardModel
            statusPanel(model.status)
            capabilityTiles(model.tiles)
            Divider().overlay(cardBorder)
            providerSection
            Divider().overlay(cardBorder)
            encryptionRow
            Divider().overlay(cardBorder)
            filteringRow
            if !store.protectionNotice.isEmpty { Text(store.protectionNotice).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("DNSProtectionNotice") }
        }
    }
    fileprivate func statusPanel(_ status: DNSStatusPanel) -> some View {
        let tone = color(status.tone)
        return inset {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if status.showsProgress { ProgressView().tint(tone) } else { Circle().fill(tone).frame(width: 10, height: 10) }
                }.frame(width: 18, height: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(status.title).font(.footnote.weight(.semibold)).tracking(0.8).foregroundStyle(tone)
                    Text(status.line).font(.headline).fixedSize(horizontal: false, vertical: true)
                    if let detail = status.detail { Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 0)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityElement(children: .combine).accessibilityIdentifier("DNSStatusPanel")
    }

    // MARK: Capability tiles: small, centred, identical in size whatever the text length
    fileprivate func capabilityTiles(_ tiles: [DNSCapabilityTile]) -> some View {
        let layout = dynamicTypeIsLarge ? AnyLayout(VStackLayout(alignment: .center, spacing: 8)) : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
        return layout {
            ForEach(tiles) { tile in VSStatTile(icon: tile.icon, title: tile.title, value: tile.value, tint: color(tile.tone)).frame(minHeight: 84) }
        }.fixedSize(horizontal: false, vertical: true)      // every tile takes the tallest tile's height
    }

    // MARK: Rows share one label layout so icons, titles and values align everywhere
    fileprivate func rowLabel(icon: String, title: String, subtitle: String? = nil, value: String? = nil, chevron: Bool = true) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(.secondary).frame(width: DashboardMetrics.iconColumn)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            if let value { Text(value).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.trailing).lineLimit(2) }
            if chevron { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
        }.frame(minHeight: 48).contentShape(Rectangle())
    }
    fileprivate var providerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("DNS Provider").font(.headline)
                Spacer()
                Button("Change") { showingResolvers = true }.font(.subheadline.weight(.medium)).frame(minHeight: 44)
                    .accessibilityIdentifier("DNSChangeResolver")
            }
            Button { showingResolvers = true } label: {
                inset {
                    HStack(spacing: 12) {
                        Group {
                            if store.isVayuSetuDNSSelected { Image("BrandMark").resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 9)) }
                            else { Image(systemName: "network").font(.system(size: 22)).foregroundStyle(teal) }
                        }.frame(width: 44, height: 44).background(VSDesign.surface, in: RoundedRectangle(cornerRadius: 11))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(store.endpoint.isEmpty ? "Choose a provider" : preferredName).font(.headline)
                            Text(providerDescription).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 6)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }.padding(12).frame(minHeight: 68).contentShape(Rectangle())
                }
            }.buttonStyle(VSPlainButtonStyle()).accessibilityIdentifier("DNSProviderCard")
        }
    }
    fileprivate var providerDescription: String {
        if store.endpoint.isEmpty { return "Add a DoH or DoT resolver to begin." }
        if store.isVayuSetuDNSSelected { return "Your filter lists, applied on this device, then an encrypted upstream." }
        return DNSService.transport(store.endpoint) + " · custom resolver"
    }
    fileprivate var encryptionRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { edit(store.dnsProfiles.first { $0.id == store.selectedDNS }) } label: {
                rowLabel(icon: "lock", title: "Encryption Mode", value: store.endpoint.isEmpty ? "No resolver" : DNSService.transport(store.endpoint) + " (\(transportKind.short))")
            }.buttonStyle(VSPlainButtonStyle()).disabled(locked || store.endpoint.isEmpty).accessibilityIdentifier("DNSEncryptionMode")
            if locked && !store.endpoint.isEmpty { Text("Stop DNS protection or the VPN to change the transport. Your current connection is preserved.").font(.caption).foregroundStyle(.secondary).padding(.leading, DashboardMetrics.iconColumn + 12) }
        }
    }
    fileprivate var filteringSummary: String {
        let lists = store.filtering.configuration.subscriptions.filter(\.enabled)
        let own = store.filtering.configuration.rules.filter { $0.enabled != false }.count
        if lists.isEmpty && own == 0 { return store.isVayuSetuDNSSelected ? "No lists enabled" : "Resolver-side" }
        var parts = lists.prefix(2).map { $0.name }
        if lists.count > 2 { parts.append("+\(lists.count - 2)") }
        if own > 0 { parts.append("\(own) custom") }
        let total = store.filtering.configuration.effective.count
        return parts.joined(separator: ", ") + (total > 0 ? " · " + (total >= 1000 ? String(format: "%.0fk", Double(total) / 1000) : String(total)) : "")
    }
    /// VayuSetu's lists are applied only by VayuSetu DNS. With another resolver the row is informational and cannot be opened.
    @ViewBuilder fileprivate var filteringRow: some View {
        if store.isVayuSetuDNSSelected {
            NavigationLink { VSFilterListsScreen(filtering: store.filtering) } label: {
                rowLabel(icon: "list.bullet.rectangle", title: "Filtering Lists", value: filteringSummary)
            }.buttonStyle(VSPlainButtonStyle()).accessibilityIdentifier("DNSFilterLists")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                rowLabel(icon: "list.bullet.rectangle", title: "Filtering Lists", value: "Not used", chevron: false).opacity(0.55)
                    .accessibilityElement(children: .combine).accessibilityIdentifier("DNSFilterListsUnavailable")
                Text("VayuSetu’s filter lists apply only with VayuSetu DNS. \(store.endpoint.isEmpty ? "The selected resolver" : preferredName) filters at the provider, so these lists are not used with it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.leading, DashboardMetrics.iconColumn + 12)
                if let builtIn = store.dnsProfiles.first(where: { $0.id == VayuSetuDNS.id }) {
                    Button("Use VayuSetu DNS") { store.loadDNS(builtIn) }.font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                        .padding(.leading, DashboardMetrics.iconColumn + 12).disabled(locked).accessibilityIdentifier("DNSUseVayuSetuDNS")
                    if locked { Text("Stop DNS protection or the VPN to switch provider.").font(.caption).foregroundStyle(.secondary).padding(.leading, DashboardMetrics.iconColumn + 12) }
                }
            }
        }
    }

    // MARK: Security & verification
    fileprivate var securitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Security & verification").font(.headline).padding(.horizontal, 4)
            card {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: store.dnsVerification?.passed == true ? "checkmark.circle" : "checkmark.shield").font(.system(size: 22))
                        .foregroundStyle(store.dnsVerification?.passed == true ? color(.good) : .secondary).frame(width: DashboardMetrics.iconColumn)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Verify Connection").font(.headline)
                        Text("Check whether DNS queries use the expected resolver and encryption.").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    Button { Task { await store.runDNSCheck() } } label: {
                        Group { if store.dnsChecking { ProgressView() } else { Text("Run Check").font(.subheadline.weight(.semibold)) } }.frame(minWidth: 84, minHeight: 32)
                    }.buttonStyle(.bordered).vsTapHaptic().tint(VSDesign.accent).disabled(store.dnsChecking || store.endpoint.isEmpty)
                        .accessibilityIdentifier("DNSRunCheck")
                }
                if !store.dnsCheckLines.isEmpty {
                    inset {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(store.dnsCheckLines, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                            if let date = store.dnsCheckDate { Text("Checked " + date.formatted(date: .omitted, time: .shortened) + ". A passing lookup does not prove every app uses this resolver.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    }.accessibilityIdentifier("DNSCheckResult")
                }
                Divider().overlay(cardBorder)
                Button { showingAdvanced = true } label: {
                    rowLabel(icon: "slider.horizontal.3", title: "Advanced DNS Mode", subtitle: "Fallbacks, bootstrap, split DNS and network compatibility.")
                }.buttonStyle(VSPlainButtonStyle()).accessibilityIdentifier("DNSAdvanced")
                Divider().overlay(cardBorder)
                NavigationLink { VSDNSDiagnosticsScreen(store: store, tunnel: tunnel) } label: {
                    rowLabel(icon: "doc.text.magnifyingglass", title: "DNS Diagnostics", subtitle: "Resolver details, performance and troubleshooting.")
                }.buttonStyle(VSPlainButtonStyle()).accessibilityIdentifier("DNSDiagnostics")
            }
        }
    }

    // MARK: VPN compatibility notice: only when a VPN is selected or running, and dismissible
    fileprivate var showCompatibilityNotice: Bool { !noticeDismissed && (store.selectedVPNKind != nil || (tunnel.running && !tunnel.localDNSRunning)) }
    fileprivate var compatibilityNotice: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle").font(.system(size: 20)).foregroundStyle(VSDesign.accent).frame(width: DashboardMetrics.iconColumn).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("DNS behavior with VPN").font(.subheadline.weight(.semibold))
                Text("When a VPN profile is active, DNS behavior depends on the selected VPN protocol and its configuration.").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Learn more") { showingCompatibility = true }.font(.footnote.weight(.semibold)).frame(minHeight: 44, alignment: .leading)
            }
            Spacer(minLength: 0)
            Button { noticeDismissed = true } label: { Image(systemName: "xmark").font(.caption.weight(.semibold)).frame(width: 44, height: 44) }
                .buttonStyle(VSPlainButtonStyle()).foregroundStyle(.secondary).accessibilityLabel("Dismiss")
        }.padding(.leading, 14).padding(.vertical, 8).padding(.trailing, 2).frame(maxWidth: .infinity, alignment: .leading)
            .background(VSDesign.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(VSDesign.accent.opacity(0.35), lineWidth: 1))
            .accessibilityIdentifier("DNSCompatibilityNotice")
    }
    fileprivate var compatibilityDetails: some View {
        NavigationStack {
            List {
                VSFormSection("By VPN type") {
                    VSRow(title: "WireGuard", subtitle: "VayuSetu runs the tunnel, so your chosen resolver and VayuSetu’s filter lists can be applied to DNS inside it.", icon: "shield.lefthalf.filled")
                    VSRow(title: "OpenVPN", subtitle: "Planned. A compatible packet-tunnel engine could host DNS in the same way; it is not available yet.", icon: "lock.shield")
                    VSRow(title: "IKEv2", subtitle: "Apple runs this tunnel inside iOS. DNS comes from the VPN server or a configuration profile, so your resolver and VayuSetu’s lists are not applied.", icon: "network")
                }
                VSFormSection("Good to know") {
                    Text("A custom resolver is not the same as local filtering: blocking happens at the resolver unless VayuSetu DNS is selected.")
                    Text("Anything VayuSetu cannot enforce is shown as limited or unsupported, never as active.")
                    Text("Turning the VPN off while DNS stays on switches to DNS Only. Turning DNS off keeps the VPN connected.")
                }
            }.vsList().vsHeader("DNS with a VPN")
                .toolbar { ToolbarItem(placement: .confirmationAction) { VSCloseButton(label: "Done") { showingCompatibility = false } } }
        }
    }
}
