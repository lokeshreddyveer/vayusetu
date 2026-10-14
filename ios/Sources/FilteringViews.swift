import SwiftUI
import VayuSetuCore

struct VSFilteringScreen: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    @ObservedObject var network: NetworkDiagnostics
    @StateObject private var diagnostics = FilteringDiagnostics()
    @AppStorage("filter-test-ads") private var ads = "doubleclick.net"
    @AppStorage("filter-test-trackers") private var trackers = "www.google-analytics.com"
    @AppStorage("filter-test-malware") private var malware = "malware.testcategory.com"
    @State private var selected: Set<UUID> = []
    @State private var reference: UUID? = Self.builtinReference
    /// A public, unfiltered resolver offered as the comparison point so the check works without setting anything up.
    static let builtinReference = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    /// VayuSetu DNS filters on this device, so asking its upstream directly would not exercise the lists; Run Checks tests that path instead.
    var comparable: [DNSProfile] { store.dnsProfiles.filter { $0.id != VayuSetuDNS.id } }
    @State private var clearing = false
    var body: some View {
        AnyView(VSCardList {
            VSSection {
                Text("Direct DNS queries only. No webpages, scripts, advertisements or malware content are loaded.").font(.footnote).foregroundStyle(.secondary)
                VSNavLink { VSCardList {
                    VSSection("Controlled test domains") { TextField("Ads test domain", text: $ads).vsInput(); TextField("Tracker / analytics test domain", text: $trackers).vsInput(); TextField("Malware test domain", text: $malware).vsInput() }
                    VSSection { Text("Use provider-supported test names or domains you control with an explicit block rule. Cloudflare’s malware.testcategory.com is safe test infrastructure; other providers may not classify it as malware. Passing a custom block rule tests that rule, not the provider’s category coverage.").font(.footnote); Link("Cloudflare test-domain documentation", destination: URL(string: "https://developers.cloudflare.com/cloudflare-one/traffic-policies/dns-policies/test-dns-filtering/")!) }
                }.vsList().vsHeader("Test Domains").disabled(diagnostics.running) } label: { VSRow(title: "Test domains", subtitle: "Provider-supported or controlled names", icon: "slider.horizontal.3") }
            }
            VSSection {
                ForEach(comparable) { profile in Toggle(profile.name, isOn: Binding(get: { selected.contains(profile.id) }, set: { if $0 { selected.insert(profile.id) } else { selected.remove(profile.id) } })).disabled(diagnostics.running) }
                Picker("Unfiltered reference", selection: $reference) { Text("Not selected").tag(UUID?.none); Text("Cloudflare 1.1.1.1 (built in)").tag(UUID?.some(Self.builtinReference)); ForEach(comparable) { Text($0.name).tag(Optional($0.id)) } }.disabled(diagnostics.running)
                if comparable.isEmpty { Text("Add a filtering resolver such as NextDNS or Control D in the DNS tab to compare it here. VayuSetu DNS filters on this device and is tested by Run Checks instead.").font(.footnote).foregroundStyle(.orange) }
                Text("Required to confirm DNS filtering: choose a trusted, unfiltered reference that resolves the controlled test names.").font(.footnote).foregroundStyle(reference == nil ? .orange : .secondary)
                Text("The reference receives only the test names you configure here. It never becomes device DNS or a fallback resolver.").font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Compare configured resolvers") } footer: { Text("Choose up to 10 profiles and an unfiltered reference that resolves the test names. The active resolver remains unchanged. Without a valid reference, results are inconclusive.") }
            VSSection { Button(diagnostics.running ? "Cancel Checks" : "Run DNS Filtering Checks") { if diagnostics.running { diagnostics.cancel() } else { run() } }.buttonStyle(VSActionStyle(primary: true)).disabled(!diagnostics.running && (reference == nil || selected.isEmpty || selected.count > 10 || tunnel.busy)) }
            if let run = diagnostics.history.first {
                VSSection("Latest DNS-only results") { rows(run); Text("\(run.date.formatted()) · \(run.tunnelStatus)").font(.caption).foregroundStyle(.secondary) }
            }
            VSSection("History") {
                ForEach(diagnostics.history.dropFirst()) { run in VSNavLink { VSCardList { rows(run) }.vsList().vsHeader(run.date.formatted()) } label: { VSRow(title: run.date.formatted(), subtitle: "\(run.results.count) DNS checks · \(run.tunnelStatus)", icon: "clock") } }
                if diagnostics.history.isEmpty { Text("No filtering checks yet").foregroundStyle(.secondary) }
                if !diagnostics.history.isEmpty { ShareLink(item: diagnostics.sanitizedReport) { Label("Export Sanitized History", systemImage: "square.and.arrow.up") }; Button("Clear History", role: .destructive) { clearing = true }.disabled(diagnostics.running) }
            }
            if !diagnostics.progress.isEmpty { VSSection { Text(diagnostics.progress).font(.footnote).foregroundStyle(.secondary) } }
            VSSection { Text("Passed means the target blocks every address family that the reference resolves for one test name. Failed means a test name resolved despite the expected block. Network errors, unsupported responses and missing controls are inconclusive. DNS filtering cannot block same-domain ads, browser scripts or all tracking.").font(.footnote).foregroundStyle(.secondary) }
        }.vsList().vsHeader("DNS Filtering").vsEditor()
        .onAppear { if selected.isEmpty, let id = store.selectedDNS, id != VayuSetuDNS.id { selected.insert(id) } }
        .onChange(of: tunnel.status.rawValue) { _, _ in diagnostics.cancel() }
        .onChange(of: network.routeRevision) { _, _ in diagnostics.cancel() }
        .vsConfirm(isPresented: $clearing, title: "Clear test history?", message: "Saved filtering check results are deleted.", confirm: "Clear History", destructive: true, icon: "trash.fill") { diagnostics.clear() })
    }
    @ViewBuilder func rows(_ run: FilteringRun) -> some View { ForEach(run.results) { result in VSNavLink { VSCheckDetail(title: result.category, explanation: result.detail + "\nFiltering results do not prove DNS transport routing.", output: "\(result.verdict.rawValue)\nDomain: \(result.domain)\n\(run.date.formatted())\n\nTarget\n\((result.targetMeasurements ?? []).map(\.description).joined(separator: "\n"))\n\nUnfiltered reference\n\((result.referenceMeasurements ?? []).map(\.description).joined(separator: "\n"))") } label: { VSRow(title: result.category, subtitle: store.dnsProfiles.first(where: { $0.id == result.profileID })?.name ?? "Removed profile", value: result.verdict.rawValue) } } }
    func endpoint(_ id: UUID) throws -> URL {
        if id == Self.builtinReference { return try DNSService.endpoint("https://cloudflare-dns.com/dns-query") }
        guard let data = try Vault.get("dns-" + id.uuidString), let text = String(data: data, encoding: .utf8) else { throw AppIssue(message: "Resolver endpoint unavailable.") }; return try DNSService.endpoint(text) }
    func run() {
        do { let targets = try store.dnsProfiles.filter { selected.contains($0.id) }.map { ($0.id, try endpoint($0.id)) }; let control = try reference.map(endpoint); diagnostics.run(targets: targets, reference: control, tests: [("Ads", ads), ("Trackers & analytics", trackers), ("Malware", malware)], status: tunnel.statusText) }
        catch { store.notice = "Could not read a selected resolver endpoint. Check its saved configuration." }
    }
}
