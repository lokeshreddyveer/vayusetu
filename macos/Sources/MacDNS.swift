import AppKit
import SwiftUI
import VayuSetuCore

/// Encrypted DNS for the Mac: resolvers on the left; the chosen resolver, a live test and the DNS activity on the right.
/// It calls the same store functions as the iPhone's DNS tab.
struct MacDNS: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    @ObservedObject var systemDNS: SystemDNSController
    let activate: (@escaping () -> Void) -> Void
    @State private var draft: VSResolverDraft?
    @State private var search = ""
    @State private var removing = false
    @State private var pendingDelete: DNSProfile?
    @State private var hovered: UUID?
    @State private var path: [DNSRoute] = []
    private enum DNSRoute: Hashable { case modes, security, diagnostics, verification }
    init(store: AppStore, tunnel: TunnelController, activate: @escaping (@escaping () -> Void) -> Void) {
        self.store = store; self.tunnel = tunnel; self.systemDNS = store.systemDNS; self.activate = activate
    }
    private var locked: Bool { tunnel.running || tunnel.busy || systemDNS.busy || store.testing }
    private var matching: [DNSProfile] { store.dnsProfiles.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) } }
    private var teal: Color { Color(red: 0.0, green: 0.78, blue: 0.82) }

    var body: some View {
        MacPage(title: "Encrypted DNS", subtitle: "Choose the resolver that answers your lookups. VayuSetu DNS also filters ads and trackers on this Mac.") {
            MacPanelLayout {
                resolvers
                current
            }
            suggestion
            test
            trust
            activity
            more
        }
        .task {
            // Look again every few minutes while this page is open. Nothing runs unless the resolver has been failing, so most checks cost nothing.
            while !Task.isCancelled {
                let list = HealthAssessor.assess(rounds: WiFiMonitor.shared.rounds, resolver: nil, vpn: nil)
                let healthy = WiFiMonitor.shared.running && list.first { $0.name == .wifiRouter }?.state == .good && list.first { $0.name == .internet }?.state == .good
                await store.evaluateResolverSuggestion(connectionHealthy: healthy)
                try? await Task.sleep(for: .seconds(180))
            }
        }
        .toolbar { ToolbarItem { Button { draft = VSResolverDraft(name: "", endpoint: "") } label: { Label("Add resolver", systemImage: "plus") }.disabled(locked).help("Add an encrypted DNS resolver") } }
        .sheet(item: $draft) { item in NavigationStack { VSResolverEditor(store: store, tunnel: tunnel, draft: item) }.frame(minWidth: 520, minHeight: 520).vsDialogHost() }
        .vsConfirm(isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                   title: "Delete \(pendingDelete?.name ?? "this resolver")?", message: "The resolver is removed from this Mac. Other resolvers are kept.", confirm: "Delete resolver", destructive: true, icon: "trash.fill") {
            if let item = pendingDelete { pendingDelete = nil; Task { _ = await store.deleteResolver(item.id) } }
        }
    }

    // MARK: Resolvers
    private var resolvers: some View {
        MacPanel("Resolvers", icon: "network", trailing: { Text("\(store.dnsProfiles.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary) }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Search resolvers", text: $search).textFieldStyle(.plain) }
                    .padding(8).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                ForEach(matching) { resolver in
                    let on = store.selectedDNS == resolver.id
                    Button { if !locked { store.loadDNS(resolver) } } label: {
                        HStack(spacing: 10) {
                            Image(systemName: resolver.id == VayuSetuDNS.id ? "shield.lefthalf.filled" : "network").font(.system(size: 13, weight: .semibold)).foregroundStyle(teal)
                                .frame(width: 30, height: 30).background(teal.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(resolver.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                Text(resolver.id == VayuSetuDNS.id ? "Built-in · filters on this Mac" : "Encrypted resolver").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 6)
                            if on { Image(systemName: "checkmark.circle.fill").foregroundStyle(VSDesign.accent) }
                        }.padding(8).contentShape(Rectangle())
                            .background(on ? VSDesign.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }.buttonStyle(.plain).disabled(locked && !on)
                        .overlay(alignment: .trailing) {
                            if resolver.id != VayuSetuDNS.id, hovered == resolver.id {
                                Button { pendingDelete = resolver } label: { Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(store.resolverInUse(resolver.id) ? Color.secondary : Color.red).padding(8) }
                                    .buttonStyle(.plain).help(store.resolverInUse(resolver.id) ? "In use. Turn DNS off to delete it." : "Delete this resolver")
                                    .disabled(store.resolverInUse(resolver.id)).transition(.opacity)
                            }
                        }
                        .onHover { inside in withAnimation(.easeInOut(duration: 0.15)) { hovered = inside ? resolver.id : (hovered == resolver.id ? nil : hovered) } }
                        .contextMenu {
                            Button("Use this resolver") { store.loadDNS(resolver) }.disabled(locked)
                            Button("Edit…") { edit(resolver) }.disabled(locked)
                            if resolver.id != VayuSetuDNS.id { Divider(); Button("Delete…", role: .destructive) { pendingDelete = resolver }.disabled(store.resolverInUse(resolver.id)) }
                        }
                }
                if store.dnsProfiles.isEmpty { Text("Add your provider's encrypted DNS endpoint, for example from NextDNS or Control D.").font(.system(size: 12)).foregroundStyle(.secondary) }
                else if matching.isEmpty { Text("No resolver matches “\(search)”.").font(.system(size: 12)).foregroundStyle(.secondary) }
                if locked { Label(tunnel.running ? "Disconnect to change resolvers." : "Wait for the current operation to finish.", systemImage: "lock").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 4) }
            }
        }
    }
    private var current: some View {
        MacPanel("Selected resolver", icon: "checkmark.seal", trailing: { MacChip(text: pillWord, tint: pillColor) }) {
            if store.endpoint.isEmpty {
                Text("No resolver selected. Pick one from the list or add your own.").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 9) {
                        fact("Name", store.dnsName)
                        fact("Transport", DNSService.transport(store.endpoint))
                        fact("Endpoint", "Stored in the Keychain")
                        fact("Backup resolver", store.backupDNS.flatMap { id in store.dnsProfiles.first { $0.id == id }?.name } ?? "None")
                        fact("Filtering", store.isVayuSetuDNSSelected ? "VayuSetu lists, applied on this Mac" : "Up to your resolver")
                    }
                    HStack(spacing: 10) {
                        Button { edit(store.dnsProfiles.first { $0.id == store.selectedDNS }) } label: { Label("Edit", systemImage: "pencil") }.buttonStyle(MacHoverButtonStyle()).disabled(locked)
                        if let id = store.selectedDNS, id != VayuSetuDNS.id, let profile = store.dnsProfiles.first(where: { $0.id == id }) {
                            Button(role: .destructive) { pendingDelete = profile } label: { Label("Delete", systemImage: "trash") }.buttonStyle(MacHoverButtonStyle()).disabled(store.resolverInUse(id))
                        }
                    }
                    if let id = store.selectedDNS, id != VayuSetuDNS.id, store.resolverInUse(id) {
                        Text("This resolver is in use. Turn DNS off to delete it, or pick another resolver first.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    private var pillWord: String { switch store.dnsPill { case .off: "Off"; case .active: "Active"; case .pending: "Starting…"; case .limited: "Limited"; case .failed: "Failed" } }
    private var pillColor: Color { switch store.dnsPill { case .off: .secondary; case .active: .green; case .pending: .orange; case .limited: .yellow; case .failed: .red } }
    private func fact(_ title: String, _ value: String) -> some View {
        GridRow { Text(title).font(.system(size: 12)).foregroundStyle(.secondary).gridColumnAlignment(.trailing); Text(value).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading) }
    }

    /// Shown only when the resolver in use has really been failing while the network was fine. It never switches anything.
    @ViewBuilder private var suggestion: some View {
        if let s = store.resolverSuggestion {
            MacPanel("A resolver suggestion", icon: "lightbulb") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Consider \(s.candidate)").font(.system(size: 13, weight: .semibold))
                    ForEach(s.reasons, id: \.self) { Label($0, systemImage: "checkmark.circle").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    ForEach(s.caveats, id: \.self) { Label($0, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true) }
                    Text("To switch: disconnect, then choose it under Selected resolver.").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }.transition(.opacity)
        }
    }
    private var trust: some View {
        MacPanel("Check that answers are genuine", icon: "checkmark.shield", trailing: {
            Button(store.resolverTrustRunning ? "Checking…" : "Check now") { Task { await store.runResolverTrust() } }.buttonStyle(MacHoverButtonStyle(prominent: true)).disabled(store.resolverTrustRunning)
        }) {
            VStack(alignment: .leading, spacing: 10) {
                if let report = store.resolverTrust {
                    Label(report.verdict.title, systemImage: report.verdict == .consistent ? "checkmark.circle.fill" : (report.verdict == .inconclusive ? "questionmark.circle" : "exclamationmark.triangle.fill"))
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(report.verdict == .consistent ? Color.green : (report.verdict == .inconclusive ? Color.secondary : Color.orange))
                    Text(report.summary).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("Checked \(report.date.formatted(date: .omitted, time: .shortened)) through \(report.resolver).").font(.system(size: 11)).foregroundStyle(.tertiary)
                } else {
                    MacExplainer(text: "Asks for three well-known names whose addresses never change (Cloudflare, Google and Quad9's own) and compares what comes back. If your resolver or network rewrites answers, they will not match. It sends three lookups through the resolver you use and nothing to anyone else. A name your resolver blocks on purpose is not treated as tampering.")
                }
            }
        }
    }
    private var test: some View {
        MacPanel("Test the resolver", icon: "checkmark.circle", trailing: {
            Button(store.testing ? "Testing…" : "Test now") { store.testDNS() }.buttonStyle(MacHoverButtonStyle(prominent: true)).disabled(store.endpoint.isEmpty || store.testing)
        }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    TextField("Domain to test", text: $store.probeDomain).textFieldStyle(.roundedBorder).frame(maxWidth: 260).disabled(store.testing)
                    Picker("Record", selection: $store.probeRecordType) { ForEach(DNSRecordType.allCases) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 100).disabled(store.testing)
                    Toggle("Expect blocked", isOn: $store.expectNXDOMAIN).disabled(store.testing)
                }
                if store.result.isEmpty { Text("Asks the selected resolver for the domain over the current route. An answer shows the resolver works; it does not prove filtering or that other apps use it.").font(.system(size: 12)).foregroundStyle(.secondary) }
                else { Text(store.result).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous)) }
            }
        }
    }
    private var activity: some View {
        VStack(spacing: 20) {
            MacLiveGate(tunnel: tunnel, history: DomainHistoryStore.shared)
            MacPanel("DNS activity", icon: "chart.xyaxis.line") { VSActivityDashboard(filtering: store.filtering).padding(.horizontal, -4) }
            MacDomainPanel(tunnel: tunnel, history: DomainHistoryStore.shared)
            MacPanel("Recent lookups", icon: "list.bullet.rectangle") { VSLookupsPanel(tunnel: tunnel) }
        }
    }
    private var more: some View {
        MacPanel("More", icon: "ellipsis.circle") {
            VStack(spacing: 0) {
                link("Protection modes", "VPN + DNS, VPN only, DNS only", icon: "arrow.triangle.branch") { VSModeScreen(store: store, tunnel: tunnel) }
                Divider()
                link("DNS security", "Blocking, rebinding and filters", icon: "hand.raised") { VSDNSSecurityScreen(store: store, tunnel: tunnel) }
                Divider()
                link("DNS diagnostics", "Checks and measured evidence", icon: "waveform.path.ecg") { VSDNSDiagnosticsScreen(store: store, tunnel: tunnel) }
            }
        }
    }
    private func link<D: View>(_ title: String, _ detail: String, icon: String, @ViewBuilder destination: @escaping () -> D) -> some View {
        NavigationLink { destination().frame(maxWidth: 880) } label: { MacRow(icon: icon, title: title, detail: detail) { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }.contentShape(Rectangle()) }.buttonStyle(.plain).perfTarget("nav.\(title)")
    }
    private func edit(_ profile: DNSProfile?) {
        do {
            let endpoint: String
            if let profile { guard let data = try Vault.get("dns-" + profile.id.uuidString), let value = String(data: data, encoding: .utf8) else { throw AppIssue(message: "Missing resolver endpoint.") }; endpoint = value }
            else { endpoint = store.endpoint }
            draft = VSResolverDraft(profileID: profile?.id, name: profile?.name ?? store.dnsName, endpoint: endpoint, bootstrapAddresses: profile?.bootstrapAddresses ?? store.bootstrapAddresses)
        } catch { store.notice = "Could not read the resolver endpoint from Keychain." }
    }
}
