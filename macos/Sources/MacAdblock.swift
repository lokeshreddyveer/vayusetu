import AppKit
import SafariServices
import SwiftUI
import UniformTypeIdentifiers
import VayuSetuCore

/// Adblock for the Mac: Safari protection and its setup on the left; filtering mode, lists and tools on the right.
/// It calls the same FilteringController as the iPhone's Adblock tab.
struct MacAdblock: View {
    @ObservedObject var filtering: FilteringController
    @ObservedObject var store: AppStore
    @State private var importing = false
    private var config: FilterConfiguration { filtering.configuration }
    private var selectedCount: Int { config.subscriptions.filter(\.enabled).count }
    private var siteExceptionCount: Int { config.rules.filter { $0.source == FilteringController.siteExceptionSource }.count }

    private var safari: (label: String, detail: String, tint: Color) {
        if !config.safariDesired { return ("Off", "VayuSetu is not blocking in Safari.", .secondary) }
        if config.effective.isEmpty { return ("No lists", "Turn on a filter list to give Safari rules.", .orange) }
        switch filtering.enabled {
        case .some(true) where filtering.packageReady: return ("Active", "Rules are loaded in \(filtering.neededExtensions.count) extension\(filtering.neededExtensions.count == 1 ? "" : "s") and enabled in Safari.", .green)
        case .some(true): return ("Not loaded", "The extension is enabled; rules have not loaded yet.", .orange)
        case .some(false): return ("Extension off", "\(filtering.extensionSummary). Enable the VayuSetu extensions in Safari Settings → Extensions.", .orange)
        case .none: return ("Needs Safari setup", "Open Safari Settings → Extensions and enable the VayuSetu blockers, then return here and refresh.", .orange)
        }
    }
    private var rulesLoaded: String {
        guard filtering.packageReady, config.safariDesired else { return "None" }
        let applied = config.safariApplied ?? config.effective.count
        if let total = config.safariCandidates, applied < total { return "\(applied.formatted()) of \(total.formatted())" }
        return applied.formatted()
    }

    var body: some View {
        MacPage(title: "Adblock", subtitle: "Block distractions and trackers in Safari, and across apps with VayuSetu DNS.") {
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 20) { protection; extensions }.frame(width: 380)
                VStack(spacing: 20) { mode; manage; details; tools; activity }.frame(maxWidth: .infinity)
            }
        }
        .task { await filtering.refresh() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText]) { result in
            do {
                let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try LocalFiles.read(url, maximum: FilterParser.byteLimit)
                Task { await filtering.importList(data, name: url.deletingPathExtension().lastPathComponent) }
            } catch { filtering.report(error.localizedDescription) }
        }
    }

    // MARK: Left
    private var protection: some View {
        MacPanel("Safari protection", icon: "safari", trailing: {
            Toggle("", isOn: Binding(get: { config.safariDesired }, set: { value in Task { await filtering.setSafari(value) } })).labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(filtering.busy)
        }) {
            let state = safari
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(state.tint).frame(width: 9, height: 9).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) { Text(state.label).font(.system(size: 14, weight: .semibold)); Text(state.detail).font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                Text("Blocks ads and trackers in Safari. Works without a VPN or DNS.").font(.system(size: 12)).foregroundStyle(.secondary)
                if filtering.busy { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Applying rules…").font(.system(size: 12)) } }
                if !filtering.message.isEmpty { Text(filtering.message).font(.system(size: 12)).foregroundStyle(.secondary) }
                Divider()
                HStack(spacing: 10) {
                    Button { Task { await filtering.updateSelectedLists() } } label: { Label("Update lists", systemImage: "arrow.triangle.2.circlepath") }.buttonStyle(MacHoverButtonStyle(prominent: true)).disabled(filtering.busy || selectedCount == 0)
                    Button { importing = true } label: { Label("Import list…", systemImage: "square.and.arrow.down") }.buttonStyle(MacHoverButtonStyle()).disabled(filtering.busy)
                }
            }
        }
    }
    private var extensions: some View {
        MacPanel("Safari extensions", icon: "puzzlepiece.extension", trailing: {
            Button("Open Safari settings") { openSafariExtensionSettings() }.buttonStyle(MacHoverButtonStyle())
        }) {
            let needed = filtering.neededExtensions
            VStack(alignment: .leading, spacing: 8) {
                if needed.isEmpty { Text("No extension holds rules yet. Turn on a filter list.").font(.system(size: 12)).foregroundStyle(.secondary) }
                ForEach(needed) { id in
                    let state = filtering.extensionStates[id]
                    HStack(spacing: 10) {
                        Image(systemName: state?.enabled == true ? "checkmark.circle.fill" : "circle").foregroundStyle(state?.enabled == true ? Color.green : Color.secondary)
                        Text("VayuSetu " + id.title).font(.system(size: 13))
                        Spacer()
                        if let rules = state?.rules { Text("\(rules.formatted()) of 150,000 rules").font(.system(size: 11)).monospacedDigit().foregroundStyle(rules > 140_000 ? Color.orange : Color.secondary).help("Safari allows 150,000 rules in each extension. VayuSetu spreads the lists you turn on across the extensions and keeps the most useful rules when one is full.") }
                        MacChip(text: state?.enabled == true ? (state?.reloaded == true ? "On · loaded" : "On") : "Off", tint: state?.enabled == true ? .green : .secondary)
                    }
                }
                if !needed.allSatisfy({ filtering.extensionStates[$0]?.enabled == true }) && !needed.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Safari requires a one-time manual enablement for each extension. Turn on the VayuSetu extensions in Safari → Settings → Extensions, then use Refresh in this app.").font(.system(size: 11)).foregroundStyle(.secondary)
                        Button("Refresh Safari status") { Task { await filtering.refresh() } }.buttonStyle(MacHoverButtonStyle())
                    }
                }
            }
        }
    }
    private func openSafariExtensionSettings() {
        for id in filtering.neededIdentifiers.prefix(1) { SFSafariApplication.showPreferencesForExtension(withIdentifier: id) { _ in } }
        if filtering.neededIdentifiers.isEmpty { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Safari.app")) }
    }

    // MARK: Right
    private var mode: some View {
        MacPanel("Filtering mode", icon: "dial.medium") {
            VStack(alignment: .leading, spacing: 10) {
                VSFilterModePicker(filtering: filtering)
            }
        }
    }
    private var manage: some View {
        MacPanel("Manage", icon: "switch.2") {
            VStack(spacing: 0) {
                link("Filtering settings", "General, regional, advanced and custom", icon: "switch.2") { VSFilteringSettingsScreen(filtering: filtering) }
                Divider()
                link("Filter lists", "Lists you added and their status", icon: "list.bullet.rectangle") { VSFilterListsScreen(filtering: filtering) }
                Divider()
                link("Catalogue", "Well-known lists, one click to add", icon: "books.vertical") { VSFilterCatalogScreen(filtering: filtering) }
                Divider()
                link("Custom rules", config.rules.isEmpty ? "Allow or block a domain" : "\(config.rules.count) rule\(config.rules.count == 1 ? "" : "s")", icon: "slider.horizontal.3") { VSCustomRulesScreen(filtering: filtering) }
            }
        }
    }
    private var details: some View {
        MacPanel("Protection details", icon: "info.circle") {
            Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 9) {
                fact("Last update", filtering.lastReload.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Not available")
                fact("Rules in Safari", rulesLoaded)
                fact("Lists on", "\(selectedCount)")
                fact("Extension status", filtering.enabled == nil ? "Not verified" : filtering.extensionSummary)
            }
            if let applied = config.safariApplied, let total = config.safariCandidates, applied < total, config.safariDesired {
                Text("Safari takes a limited number of rules, so it is using \(applied.formatted()) of your \(total.formatted()). DNS filtering uses all of them.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
    private func fact(_ title: String, _ value: String) -> some View {
        GridRow { Text(title).font(.system(size: 12)).foregroundStyle(.secondary).gridColumnAlignment(.trailing); Text(value).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading) }
    }
    private var tools: some View {
        MacPanel("Tools", icon: "wrench.and.screwdriver") {
            VStack(spacing: 0) {
                link("Adblock test", "Try real ad, tracker and analytics requests", icon: "checkmark.shield") { VSAdblockTestScreen(filtering: filtering, store: store) }
                Divider()
                link("Test a website", "Would VayuSetu block it, and which rule?", icon: "magnifyingglass") { VSRuleMatchScreen(filtering: filtering) }
                Divider()
                link("Website exceptions", siteExceptionCount == 0 ? "Turn blocking off for one site" : "\(siteExceptionCount) site\(siteExceptionCount == 1 ? "" : "s")", icon: "hand.raised.slash") { VSWebsiteExceptionsScreen(filtering: filtering) }
                Divider()
                link("Filter health", "Are your lists downloaded and loaded?", icon: "waveform.path.ecg") { VSFilterHealthScreen(filtering: filtering) }
                Divider()
                link("Safari details", "The six extensions and what Safari loaded", icon: "safari") { VSSafariScreen(filtering: filtering) }
            }
        }
    }
    private var activity: some View {
        MacPanel("DNS filtering activity", icon: "chart.xyaxis.line") {
            VStack(alignment: .leading, spacing: 8) {
                VSActivityDashboard(filtering: filtering).padding(.horizontal, -4)
                Text("DNS filtering is separate from Safari: the same lists can block domains for all apps through VayuSetu DNS. Switch it on from the DNS page.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
    private func link<D: View>(_ title: String, _ detail: String, icon: String, @ViewBuilder destination: @escaping () -> D) -> some View {
        NavigationLink { destination().frame(maxWidth: 880) } label: { MacRow(icon: icon, title: title, detail: detail) { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }.contentShape(Rectangle()) }.buttonStyle(.plain)
    }
}
