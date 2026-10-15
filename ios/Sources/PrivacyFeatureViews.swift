import SwiftUI
#if os(macOS)
import AppKit
#endif
import SafariServices
import UniformTypeIdentifiers
import VayuSetuCore
import NetworkExtension
import Charts
import WebKit

/// Hand-drawn optical grid shared by native tabs and protection tiles.
struct PrivacyIcon: Shape {
    let subsystem: ProtectionSubsystem
    func path(in rect: CGRect) -> Path {
        var p = Path()
        func move(_ x: CGFloat, _ y: CGFloat) { p.move(to: CGPoint(x: x, y: y)) }
        func line(_ x: CGFloat, _ y: CGFloat) { p.addLine(to: CGPoint(x: x, y: y)) }
        switch subsystem {
        case .vpn:
            move(4, 7); line(12, 3); line(20, 7); line(20, 12)
            p.addQuadCurve(to: CGPoint(x: 12, y: 21), control: CGPoint(x: 20, y: 18))
            p.addQuadCurve(to: CGPoint(x: 4, y: 12), control: CGPoint(x: 4, y: 18)); line(4, 7)
            move(8, 12); line(16, 12); move(12, 8); line(12, 16)
        case .dns:
            for point in [CGPoint(x: 12, y: 5), CGPoint(x: 5, y: 18), CGPoint(x: 19, y: 18)] { p.addEllipse(in: CGRect(x: point.x-2.5, y: point.y-2.5, width: 5, height: 5)) }
            move(10.5, 7.5); line(6.5, 15.5); move(13.5, 7.5); line(17.5, 15.5); move(8, 18); line(16, 18)
        case .safari:
            p.addEllipse(in: CGRect(x: 3, y: 3, width: 18, height: 18))
            move(16, 8); line(14, 14); line(8, 16); line(10, 10); line(16, 8)
        case .adblock:
            move(7, 3); line(17, 3); line(21, 7); line(21, 17); line(17, 21); line(7, 21); line(3, 17); line(3, 7); p.closeSubpath()
            move(8, 12); line(16, 12)
        }
        return p.applying(CGAffineTransform(scaleX: rect.width/24, y: rect.height/24).translatedBy(x: rect.minX, y: rect.minY))
    }
}
struct VSPrivacyGlyph: View {
    let subsystem: ProtectionSubsystem
    var body: some View { PrivacyIcon(subsystem: subsystem).stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)).frame(width: 24, height: 24).accessibilityHidden(true) }
}
extension ProtectionSnapshot {
    var tint: Color {
        switch observed {
        case .active: Color(red: 0.302, green: 0.871, blue: 0.663)
        case .inactive, .unknown: Color(red: 0.537, green: 0.592, blue: 0.663)
        case .error: Color(red: 0.945, green: 0.431, blue: 0.459)
        default: Color(red: 0.949, green: 0.718, blue: 0.369)
        }
    }
}
struct VSProtectionGrid: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    @ObservedObject var filtering: FilteringController
    @ObservedObject var systemDNS: SystemDNSController
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    init(store: AppStore, tunnel: TunnelController) { self.store = store; self.tunnel = tunnel; filtering = store.filtering; systemDNS = store.systemDNS }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            VStack(alignment: .leading, spacing: 12) {
                Text("PROTECTION STATUS").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(.secondary)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(ProtectionSubsystem.allCases, id: \.self) { subsystem in
                        let snapshot = store.protection(subsystem, now: context.date)
                        NavigationLink { detail(subsystem) } label: {
                            tile(subsystem, snapshot: snapshot)
                        }.buttonStyle(VSPlainButtonStyle())
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(title(subsystem) + ", " + snapshot.label)
                            .accessibilityHint("Opens " + title(subsystem) + " details. " + snapshot.reason)
                            .accessibilityIdentifier("HomeProtection-" + subsystem.rawValue)
                    }
                }
            }
        }
    }
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: dynamicTypeSize >= .xLarge ? 2 : 4)
    }
    private func title(_ subsystem: ProtectionSubsystem) -> String {
        switch subsystem { case .vpn: "VPN"; case .dns: "DNS"; case .safari: "Safari"; case .adblock: "Adblock" }
    }
    @ViewBuilder private func tile(_ subsystem: ProtectionSubsystem, snapshot: ProtectionSnapshot) -> some View {
        VStack(spacing: 6) {
            VSPrivacyGlyph(subsystem: subsystem).foregroundStyle(.secondary).frame(height: 18)
            Text(title(subsystem)).font(.caption.weight(.semibold)).foregroundStyle(.primary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Circle().fill(snapshot.tint).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                Text(snapshot.label).font(.system(size: 11)).foregroundStyle(snapshot.tint).lineLimit(2).multilineTextAlignment(.leading).minimumScaleFactor(0.8)
            }
        }.padding(.vertical, 10).padding(.horizontal, 6).frame(maxWidth: .infinity, minHeight: 82, alignment: .top)
            .background(VSDesign.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(VSDesign.separator, lineWidth: 1))
    }
    @ViewBuilder private func detail(_ subsystem: ProtectionSubsystem) -> some View {
        switch subsystem {
        case .vpn: VSConnectionDetailsScreen(store: store, tunnel: tunnel)
        case .dns: VSDNSScreen(store: store, tunnel: tunnel)
        case .safari: VSSafariScreen(filtering: filtering)
        case .adblock: VSAdblockScreen(filtering: filtering, store: store)
        }
    }
}
struct VSAdblockScreen: View {
    @ObservedObject var filtering: FilteringController
    @ObservedObject var store: AppStore
    var isRootTab = false
    @Environment(\.openDNSTab) private var openDNSTab
    @Environment(\.openAdblockTab) private var openAdblockTab
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    private var config: FilterConfiguration { filtering.configuration }
    private var selectedCount: Int { config.subscriptions.filter(\.enabled).count }
    private func count(_ category: FilterCategory) -> Int {
        config.subscriptions.filter { $0.enabled && FilterCatalog.entry(forURL: $0.url)?.category == category }.count
    }
    /// One honest line for Safari, from what the system reports and what the last reload acknowledged.
    private var safariState: (label: String, detail: String, tint: Color) {
        if !config.safariDesired { return ("Off", "VayuSetu is not blocking in Safari.", .secondary) }
        if config.effective.isEmpty { return ("No lists", "Turn on a filter list to give Safari rules.", .orange) }
        switch filtering.enabled {
        case .some(true) where filtering.packageReady: return ("Active", "Rules loaded in \(filtering.neededExtensions.count) extension\(filtering.neededExtensions.count == 1 ? "" : "s") and enabled in Safari.", .green)
        case .some(true): return ("Not loaded", "The extension is enabled; rules have not loaded yet.", .orange)
        case .some(false): return ("Extension off", "\(filtering.extensionSummary). Enable the VayuSetu extensions in Settings → Apps → Safari → Extensions.", .orange)
        case .none: return ("Not verified", "Safari’s extension state could not be read.", .secondary)
        }
    }
    private var rulesLoaded: String {
        guard filtering.packageReady, config.safariDesired else { return "None" }
        let applied = config.safariApplied ?? config.effective.count
        if let total = config.safariCandidates, applied < total { return "\(applied.formatted()) of \(total.formatted())" }
        return applied.formatted()
    }
    /// One row per extension that holds rules, ticked from what the system reports. Safari's own switches cannot be changed by the app.
    private var setupChecklist: some View {
        let needed = filtering.neededExtensions
        let allOn = needed.allSatisfy { filtering.extensionStates[$0]?.enabled == true }
        return VStack(alignment: .leading, spacing: 8) {
            Text(allOn ? "Extensions" : "Finish setup in Settings").font(.footnote.weight(.semibold))
            ForEach(needed) { id in
                let state = filtering.extensionStates[id]
                HStack(spacing: 8) {
                    Image(systemName: state?.enabled == true ? "checkmark.circle.fill" : "circle").foregroundStyle(state?.enabled == true ? Color.green : Color.secondary)
                    Text("VayuSetu " + id.title).font(.footnote)
                    Spacer()
                    Text(state?.enabled == true ? (state?.reloaded == true ? "On · loaded" : "On") : "Off").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !allOn { Text("Settings → Apps → Safari → Extensions, then turn on each one above. Extensions with no rules need no switch.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(VSDesign.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    private var oldestList: (days: Int, name: String)? {
        let enabled = config.subscriptions.filter { $0.enabled && $0.url != "Local file" }
        guard let oldest = enabled.min(by: { ($0.updated ?? .distantPast) < ($1.updated ?? .distantPast) }) else { return nil }
        return (oldest.updated.map { Calendar.current.dateComponents([.day], from: $0, to: Date()).day ?? 0 } ?? 999, oldest.name)
    }
    @State private var testResult: String?
    @State private var testing = false
    private func tone(_ label: String) -> Color { label == "Active" ? .green : label == "Off" || label == "Not verified" ? .secondary : .orange }
    private var siteExceptionCount: Int { filtering.configuration.rules.filter { $0.source == FilteringController.siteExceptionSource }.count }
    private func linkRow(_ icon: String, _ title: String, _ subtitle: String = "", value: String = "", chevron: Bool = true) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            if !value.isEmpty { Text(value).font(.subheadline).foregroundStyle(.secondary) }
            if chevron { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
        }.contentShape(Rectangle())
    }
    private func detail(_ title: String, _ value: String) -> some View {
        HStack { Text(title).font(.subheadline); Spacer(minLength: 12); Text(value).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
    }
    private func categoryTile(_ icon: String, _ title: String, _ category: FilterCategory) -> some View {
        let n = count(category)
        return VSStatTile(icon: icon, title: title, value: n == 0 ? "Off" : "\(n) on", tint: n == 0 ? .secondary : .green)
    }
    var body: some View {
        let state = safariState
        ScrollView {
            VStack(spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Adblock").font(.system(size: 28, weight: .semibold))
                        Text("Block distractions. Protect your privacy.").font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    NavigationLink { VSFilteringSettingsScreen(filtering: filtering) } label: {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 18, weight: .medium)).frame(width: 44, height: 44)
                            .background(VSDesign.surface, in: Circle()).overlay(Circle().stroke(VSDesign.separator, lineWidth: 1))
                    }.buttonStyle(VSPlainButtonStyle()).accessibilityLabel("Filter configuration")
                }.padding(.top, 12)

                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Safari Protection").font(.title3.weight(.semibold))
                            Text("Block ads and trackers in Safari. Works without a VPN or DNS.").font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Toggle("Safari Protection", isOn: Binding(get: { config.safariDesired }, set: { value in Task { await filtering.setSafari(value) } }))
                            .labelsHidden().disabled(filtering.busy).frame(minHeight: 44).accessibilityIdentifier("SafariProtectionToggle")
                    }
                    HStack(alignment: .top, spacing: 12) {
                        Circle().fill(tone(state.label)).frame(width: 10, height: 10).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(state.label).font(.subheadline.weight(.semibold))
                            Text(state.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(VSDesign.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    #if os(iOS)
                    if config.safariDesired && filtering.enabled != true, #available(iOS 26.2, *) {
                        Button("Open Safari Extension Settings") { Task { try? await SFSafariSettings.openExtensionsSettings(forIdentifiers: filtering.neededIdentifiers) } }.buttonStyle(VSCompactButtonStyle(prominent: true))
                    }
                    #endif
                    if config.safariDesired { setupChecklist }
                    if filtering.busy { ProgressView("Applying rules…").font(.footnote) }
                    if !filtering.message.isEmpty { Text(filtering.message).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }.vsCard()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Filtering mode").font(.subheadline.weight(.semibold))
                    VSFilterModePicker(filtering: filtering)
                }.vsCard()

                VSSection("Manage") {
                    VSNavLink { VSFilteringSettingsScreen(filtering: filtering) } label: { linkRow("switch.2", "Filtering Settings", "General, regional, advanced and custom", chevron: false) }
                    VSNavLink { VSCustomRulesScreen(filtering: filtering) } label: { linkRow("slider.horizontal.3", "Custom Rules", "Allowlist and blocklist", value: config.rules.isEmpty ? "" : "\(config.rules.count)", chevron: false) }
                    Button { Task { await filtering.updateSelectedLists() } } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 17)).foregroundStyle(VSDesign.accent).frame(width: 28)
                            Text("Update Filter Lists").font(.subheadline.weight(.semibold)).foregroundStyle(VSDesign.accent)
                            Spacer(); if filtering.busy { ProgressView() }
                        }.contentShape(Rectangle())
                    }.buttonStyle(VSPlainButtonStyle()).disabled(filtering.busy || selectedCount == 0)
                }

                VSSection("Protection details") {
                    detail("Last successful update", filtering.lastReload.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Not available")
                    detail("Rules in Safari", rulesLoaded)
                    detail("Extension status", filtering.enabled == nil ? "Not verified" : filtering.extensionSummary)
                    if let oldest = oldestList {
                        HStack { Text("Oldest list update").font(.subheadline); Spacer(minLength: 12); Text(oldest.days >= 999 ? "Never" : oldest.days == 0 ? "Today" : "\(oldest.days) day\(oldest.days == 1 ? "" : "s") ago").font(.subheadline).foregroundStyle(oldest.days > 14 ? Color.orange : Color.secondary) }
                    }
                } footer: {
                    if let applied = config.safariApplied, let total = config.safariCandidates, applied < total, config.safariDesired {
                        Text("Safari takes a limited number of rules, so it is using \(applied.formatted()) of your \(total.formatted()). DNS filtering uses all of them.")
                    }
                }

                VSSection("Tools") {
                    VSNavLink { VSWebsiteExceptionsScreen(filtering: filtering) } label: { linkRow("hand.raised.slash", "Website Exceptions", "Turn blocking off for one site", value: siteExceptionCount == 0 ? "" : "\(siteExceptionCount)", chevron: false) }
                    VSNavLink { VSAdblockTestScreen(filtering: filtering, store: store) } label: { linkRow("checkmark.shield", "Adblock Test", "Try real ad, tracker and analytics requests", chevron: false) }
                    VSNavLink { VSRuleMatchScreen(filtering: filtering) } label: { linkRow("magnifyingglass", "Test a Website", "Would VayuSetu block it, and which rule?", chevron: false) }
                    VSNavLink { VSFilterHealthScreen(filtering: filtering) } label: { linkRow("waveform.path.ecg", "Filter Health", "Are your lists downloaded and loaded?", chevron: false) }
                    VSNavLink { VSSafariScreen(filtering: filtering) } label: { linkRow("safari", "Safari Details", "The six extensions and what Safari loaded", chevron: false) }
                    Button { importing = true } label: { linkRow("square.and.arrow.down", "Import List from File", "Add your own blocklist", chevron: false) }.buttonStyle(VSPlainButtonStyle()).disabled(filtering.busy)
                }

                Button { openDNSTab?() } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "network").font(.system(size: 17)).foregroundStyle(.secondary).frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("DNS filtering is separate").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            Text("The same lists can block domains for all apps through VayuSetu DNS. Switch it on from the DNS tab.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }.contentShape(Rectangle())
                }.buttonStyle(VSPlainButtonStyle()).vsCard()
            }.padding(.horizontal, 16).padding(.bottom, 110)
        }.scrollIndicators(.hidden).background(VSDesign.background)
        .vsHideNavigationBar()
        .task { await filtering.refresh() }
        .onAppear { if !isRootTab, let openAdblockTab { dismiss(); openAdblockTab() } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText]) { result in
            do { let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }; let data = try LocalFiles.read(url, maximum: FilterParser.byteLimit); Task { await filtering.importList(data, name: url.deletingPathExtension().lastPathComponent) } }
            catch { filtering.report(error.localizedDescription) }
        }
    }
}
struct VSSafariScreen: View {
    @ObservedObject var filtering: FilteringController
    @State private var checkResult: String?
    @State private var checking = false
    private var config: FilterConfiguration { filtering.configuration }
    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 2).background(color.opacity(0.18), in: Capsule()).foregroundStyle(color)
    }
    private func extensionCard(_ id: SafariExtensionID) -> some View {
        let state = filtering.extensionStates[id]
        let rules = config.safariExtensionRules?[id.rawValue] ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("VayuSetu " + id.title).font(.subheadline.weight(.semibold))
                Spacer()
                pill(state?.enabled == true ? "On in Safari" : state?.enabled == false ? "Off in Safari" : "Unknown", state?.enabled == true ? .green : state?.enabled == false ? .orange : .secondary)
            }
            HStack(spacing: 6) {
                pill("\(rules.formatted()) rules", rules > 0 ? VSDesign.accent : .secondary)
                if rules > 0 { pill(state?.reloaded == true ? "Loaded" : "Not confirmed", state?.reloaded == true ? .green : .orange) }
                if let seconds = filtering.compileSeconds[id] { pill(String(format: "compiled %.1f s", seconds), .secondary) }
            }
            Text(rules == 0 ? "No rules for this extension, so it does not need to be switched on." : filtering.extensionLog(id)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let failure = state?.failure { Text(failure).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if rules > 0 { Button { Task { await filtering.reloadExtension(id) } } label: { Text("Reload this extension") }.buttonStyle(VSCompactButtonStyle()).disabled(filtering.busy) }
        }.vsCard()
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("Safari protection").font(.subheadline.weight(.semibold)); Spacer(); pill(config.safariDesired ? "On" : "Off", config.safariDesired ? .green : .secondary) }
                    detailRow("Extensions", filtering.extensionSummary)
                    detailRow("Rules in Safari", "\((config.safariApplied ?? 0).formatted()) of \((config.safariCandidates ?? 0).formatted()) selected")
                    detailRow("Last rebuild", filtering.lastReload.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Not yet")
                    HStack(spacing: 8) {
                        Button { Task { await filtering.reload(); await filtering.refresh() } } label: { Text("Rebuild all") }.buttonStyle(VSCompactButtonStyle(prominent: true)).disabled(filtering.busy)
                        Button { Task { await filtering.refresh() } } label: { Text("Refresh status") }.buttonStyle(VSCompactButtonStyle())
                        #if os(iOS)
                        if #available(iOS 26.2, *) { Button { Task { try? await SFSafariSettings.openExtensionsSettings(forIdentifiers: filtering.neededIdentifiers) } } label: { Text("Settings") }.buttonStyle(VSCompactButtonStyle()) }
                        #endif
                    }
                    if filtering.busy { ProgressView().frame(maxWidth: .infinity, alignment: .leading) }
                    if !filtering.message.isEmpty { Text(filtering.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }.vsCard()

                ForEach(SafariExtensionID.allCases) { extensionCard($0) }

                VStack(alignment: .leading, spacing: 8) {
                    Stepper(value: Binding(get: { SafariRuleCompiler.fitBudget }, set: { value in Task { await filtering.setRulesPerExtension(value) } }), in: 10_000...100_000, step: 10_000) {
                        HStack { Text("Rules per extension").font(.subheadline.weight(.semibold)); Spacer(); Text(SafariRuleCompiler.fitBudget.formatted()).foregroundStyle(.secondary) }
                    }.disabled(filtering.busy)
                    Text("Safari allows \(SafariRuleCompiler.ruleLimit.formatted()) per extension. More rules block more but make Safari slower to start. If pages stop loading, lower it. Rules left out still work in DNS filtering.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.vsCard()

                VStack(alignment: .leading, spacing: 8) {
                    Button { checking = true; Task { checkResult = await filtering.validateSafariCompiler(); checking = false } } label: {
                        HStack { Text("Check Safari’s compiler").font(.subheadline.weight(.semibold)); Spacer(); if checking { ProgressView() } }.frame(minHeight: 40).contentShape(Rectangle())
                    }.buttonStyle(VSPlainButtonStyle()).disabled(checking || filtering.busy)
                    if let checkResult { Text(checkResult).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    Text("Adds one harmless test rule to the Custom extension, asks Safari to load it, then puts the previous rules back.").font(.caption2).foregroundStyle(.secondary)
                }.vsCard()
            }.padding(.horizontal, 16).padding(.bottom, 110)
        }.vsHeader("Safari Details", "What each of the six extensions holds and whether Safari has it.").scrollIndicators(.hidden).background(VSDesign.background).vsInlineTitle().task { await filtering.refresh() }
    }
    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack { Text(title).font(.subheadline); Spacer(minLength: 12); Text(value).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
    }
}
struct VSRuleEditor: View {
    @ObservedObject var filtering: FilteringController
    @Environment(\.dismiss) private var dismiss
    let rule: FilterRule?
    @State private var enabled = true
    init(filtering: FilteringController, rule: FilterRule? = nil) { self.filtering = filtering; self.rule = rule; _domain = State(initialValue: rule?.domain ?? ""); _action = State(initialValue: rule?.action ?? .block); _scope = State(initialValue: rule?.scope ?? .domainAndSubdomains); _enabled = State(initialValue: rule?.enabled ?? true) }
    @State private var domain = ""
    @State private var action: FilterAction = .block
    @State private var scope: FilterScope = .domainAndSubdomains
    var body: some View {
        Form {
            VSFormSection { TextField("example.com", text: $domain).vsInput(); Picker("Action", selection: $action) { ForEach(FilterAction.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }; Picker("Scope", selection: $scope) { ForEach(FilterScope.allCases, id: \.self) { Text($0.label).tag($0) } } }
            VSRow(title: "Applies to", value: "Safari and VayuSetu DNS"); Toggle("Enabled", isOn: $enabled)
            Text("Your rules beat every filter list. A domain-wide rule includes its apex and all subdomains. DNS filtering applies while VayuSetu DNS is on.").font(.footnote).foregroundStyle(.secondary)
            if !filtering.message.isEmpty { Text(filtering.message).font(.footnote) }
            if let rule { VSFormSection { Button("Delete Rule", role: .destructive) { Task { await filtering.removeRule(rule.id); dismiss() } }.disabled(filtering.busy) } }
        }.formStyle(.grouped).vsFormLook().buttonStyle(VSDefaultButtonStyle()).scrollIndicators(.hidden).vsHeader(rule == nil ? "New Rule" : "Edit Rule").vsEditor().toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.vsTapHaptic() }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await filtering.upsertRule(id: rule?.id, domain: domain, action: action, scope: scope, enabled: enabled); if filtering.configuration.rules.contains(where: { $0.domain == (try? FilterDomain.normalize(domain)) && $0.action == action && $0.scope == scope && $0.enabled == enabled }) { dismiss() } } }.vsTapHaptic().disabled(domain.isEmpty || filtering.busy) }
        }
    }
}
struct VSListEditor: View {
    @ObservedObject var filtering: FilteringController
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    var body: some View {
        Form { TextField("List name", text: $name); TextField("https://provider/list.txt", text: $url).vsInput(); Text("Saving does not download the list. Enable it explicitly to fetch and validate it.").font(.footnote).foregroundStyle(.secondary); Text(filtering.message).font(.footnote) }
            .formStyle(.grouped).vsFormLook().buttonStyle(VSDefaultButtonStyle()).scrollIndicators(.hidden).vsHeader("New Filter List").vsEditor().toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.vsTapHaptic() }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { let count = filtering.configuration.subscriptions.count; filtering.addSubscription(name: name, url: url); if filtering.configuration.subscriptions.count > count { dismiss() } }.vsTapHaptic().disabled(name.isEmpty || url.isEmpty || filtering.busy) }
            }
    }
}
struct VSPrivacyScreen: View {
    @ObservedObject var filtering: FilteringController
    @State private var clearing = false
    var body: some View {
        VSCardList {
            VSSection("Privacy defaults") {
                VSRow(title: "Telemetry", value: "None")
                VSRow(title: "Cloud sync", value: "None")
                VSRow(title: "DNS query history", value: "Not kept")
                VSRow(title: "Activity statistics", value: "Counts only")
                Text("Activity statistics are counts of DNS requests and blocks per ten minutes, kept for up to a year with no website names. Clear them from Activity on the DNS tab. IP checks and resolver tests contact their named destinations only when requested. Downloading an enabled filter list reveals your network address to its host. Ordinary exports exclude secrets; encrypted backups require explicit consent.").font(.footnote).foregroundStyle(.secondary)
            }
            VSSection("Local privacy events · 7 days") {
                if filtering.events.isEmpty { Text("No recorded privacy events").foregroundStyle(.secondary) }
                ForEach(Array(filtering.events.enumerated()), id: \.offset) { _, event in Text(event).font(.footnote) }
                Button("Delete Privacy Event History", role: .destructive) { clearing = true }
            }
        }.vsList().vsHeader("Privacy").vsConfirm(isPresented: $clearing, title: "Delete local privacy events?", message: "Events recorded on this device are removed.", confirm: "Delete", destructive: true, icon: "trash.fill") { filtering.clearEvents() }
    }
}

#if os(iOS)
import UIKit
/// UIKit tab bars need an Image; arbitrary SwiftUI Shapes are omitted from their tab labels.
@MainActor enum PrivacyTabArtwork {
    private static let images: [String: UIImage] = Dictionary(uniqueKeysWithValues: ProtectionSubsystem.allCases.map { subsystem in
        let content = PrivacyIcon(subsystem: subsystem).stroke(Color.white, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)).frame(width: 24, height: 24)
        let renderer = ImageRenderer(content: content); renderer.scale = 3
        return (subsystem.rawValue, (renderer.uiImage ?? UIImage(systemName: "network")!).withRenderingMode(.alwaysTemplate))
    })
    static func image(_ subsystem: ProtectionSubsystem) -> UIImage { images[subsystem.rawValue]! }
}
#endif

// MARK: - Shared activity UI (Home and Adblock read the same series from the same repository)
/// The reporting period is one setting shared by Home and Adblock, remembered until the user changes it.
enum ActivityPeriodStore { static let key = "activity.period" }

struct VSActivityChart: View {
    let series: ActivitySeries
    var height: CGFloat = 130
    var interactive = false
    var showsBlocked = true
    @State private var selected: Date?
    private var selectedPoint: ActivityPoint? {
        guard let selected else { return nil }
        return series.points.min { abs($0.date.timeIntervalSince(selected)) < abs($1.date.timeIntervalSince(selected)) }
    }
    private var xFormat: Date.FormatStyle {
        switch series.component { case .hour: .dateTime.hour(); case .month: .dateTime.month(.abbreviated); default: .dateTime.month(.abbreviated).day() }
    }
    var body: some View {
        Group {
            if series.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "chart.xyaxis.line").font(.title3).foregroundStyle(.tertiary)
                    Text("No DNS activity recorded").font(.footnote.weight(.medium))
                    Text("Counts appear while VayuSetu DNS protection is on.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, minHeight: height)
            } else {
                Chart {
                    ForEach(series.points) { point in
                        AreaMark(x: .value("Time", point.date), y: .value("Requests", point.requests), series: .value("Series", "Requests"))
                            .foregroundStyle(LinearGradient(colors: [VSDesign.accent.opacity(0.22), VSDesign.accent.opacity(0.02)], startPoint: .top, endPoint: .bottom)).interpolationMethod(.monotone)
                        LineMark(x: .value("Time", point.date), y: .value("Requests", point.requests), series: .value("Series", "Requests"))
                            .foregroundStyle(VSDesign.accent.opacity(0.85)).lineStyle(StrokeStyle(lineWidth: 1.5)).interpolationMethod(.monotone)
                        if showsBlocked {
                            LineMark(x: .value("Time", point.date), y: .value("Blocked", point.blocked), series: .value("Series", "Blocked"))
                                .foregroundStyle(Color.orange.opacity(0.9)).lineStyle(StrokeStyle(lineWidth: 1.5)).interpolationMethod(.monotone)
                        }
                    }
                    if interactive, let point = selectedPoint {
                        RuleMark(x: .value("Time", point.date)).foregroundStyle(Color.secondary.opacity(0.4))
                            .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(point.date.formatted(series.component == .hour ? .dateTime.month(.abbreviated).day().hour() : .dateTime.month(.abbreviated).day())).font(.caption2).foregroundStyle(.secondary)
                                    Text("\(point.requests.formatted()) requests").font(.caption2.weight(.semibold))
                                    Text("\(point.blocked.formatted()) blocked").font(.caption2).foregroundStyle(.orange)
                                }.padding(6).background(VSDesign.elevated, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(VSDesign.separator, lineWidth: 1))
                            }
                    }
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(VSDesign.separator.opacity(0.6)); AxisValueLabel(format: xFormat).font(.caption2) } }
                .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in AxisValueLabel().font(.caption2) } }
                .chartXSelection(value: interactive ? $selected : .constant(nil))
                .frame(height: height)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("DNS activity, \(series.period.title)")
                .accessibilityValue("\(series.requests) requests, \(series.blocked) blocked")
            }
        }
    }
}

struct VSActivityPeriodButton: View {
    @Binding var period: ActivityPeriod
    @State private var choosing = false
    var body: some View {
        Button { choosing = true } label: {
            HStack(spacing: 4) { Text(period.title).font(.footnote.weight(.medium)); Image(systemName: "chevron.up.chevron.down").font(.caption2) }
                .padding(.horizontal, 10).frame(minHeight: 32).background(VSDesign.surface, in: Capsule()).overlay(Capsule().stroke(VSDesign.separator, lineWidth: 1))
                .padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(VSPlainButtonStyle()).accessibilityLabel("Period, \(period.title)").accessibilityIdentifier("ActivityPeriod")
            .sheet(isPresented: $choosing) {
                NavigationStack {
                    List(ActivityPeriod.allCases) { option in
                        Button { period = option; choosing = false } label: {
                            HStack { Text(option.title).foregroundStyle(.primary); Spacer(); if option == period { Image(systemName: "checkmark").foregroundStyle(VSDesign.accent) } }.frame(minHeight: 44).contentShape(Rectangle())
                        }
                    }.vsHeader("Period")
                        .toolbar { ToolbarItem(placement: .cancellationAction) { VSCloseButton { choosing = false } } }
                }.vsSheetChrome([.height(400)])
            }
    }
}

/// Compact Activity block for Home: header with period, chart, and three figures. Scope is DNS filtering only.
struct VSHomeActivity: View {
    @ObservedObject var filtering: FilteringController
    @AppStorage(ActivityPeriodStore.key) private var periodRaw = ActivityPeriod.day.rawValue
    private var period: Binding<ActivityPeriod> { Binding(get: { ActivityPeriod(rawValue: periodRaw) ?? .day }, set: { periodRaw = $0.rawValue }) }
    var body: some View {
        let series = filtering.activitySeries(period.wrappedValue)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ACTIVITY").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(.secondary)
                Spacer()
                VSActivityPeriodButton(period: period)
            }
            VSActivityChart(series: series, height: 120)
            HStack(alignment: .top, spacing: 0) {
                figure("Requests", series.requests.formatted(), .primary)
                Divider().frame(height: 34)
                figure("Blocked", series.blocked.formatted(), .orange)
                Divider().frame(height: 34)
                figure("Data Saved", "—", .green)
            }
            Text("Observed by VayuSetu DNS filtering only. Safari blocking and other DNS are not counted. Data saved is not estimated.").font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.accessibilityIdentifier("HomeActivity")
    }
    private func figure(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(size: 20, weight: .semibold)).monospacedDigit().foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }
}

/// Domain-level history is off by default and VayuSetu does not collect it yet, so rankings show an honest empty state.
struct VSDomainRankingScreen: View {
    enum Kind { case active, blocked }
    let kind: Kind
    @ObservedObject var filtering: FilteringController
    @State private var confirmClear = false
    var body: some View {
        VSCardList {
            VSSection {
                VStack(spacing: 8) {
                    Image(systemName: "list.number").font(.title2).foregroundStyle(.tertiary)
                    Text("Per-domain lists are off").font(.headline)
                    Text(kind == .active ? "Most Active would list the domains your device asked for most often." : "Most Blocked would list the domains VayuSetu blocked most often.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 24)
            }
            VSSection {
                Text("VayuSetu stores only counts per time period. It does not keep a history of the websites you visit, and per-domain rankings would need that history, so they stay off unless a future version adds an explicit opt-in.").font(.footnote)
            } header: { Text("Privacy") }
            VSSection {
                Button("Clear Activity Statistics", role: .destructive) { confirmClear = true }
            } footer: { Text("Removes the request and blocked counts shown on Home and Adblock.") }
        }.vsList().vsHeader(kind == .active ? "Most Active" : "Most Blocked")
            .vsConfirm(isPresented: $confirmClear, title: "Clear activity statistics?", message: "Counts and rankings on this screen start again from zero.", confirm: "Clear", destructive: true, icon: "trash.fill") { filtering.clearActivity() }
    }
}

/// One user-facing filtering feature. `lists` are real catalogue entries; a feature with no lists cannot be expressed as Safari
/// URL rules and is shown as unavailable instead of pretending to work.
private struct FilteringFeature: Identifiable {
    let id: String, title: String, subtitle: String
    var lists: [String] = []
    /// Lists that also count as this switch being on (a lighter level uses them) and that it switches off with the others.
    var also: [String] = []
    var unavailable: String?
}
private let generalFeatures: [FilteringFeature] = [
    .init(id: "ads", title: "Block Ads", subtitle: "Advertising resources", lists: ["HaGeZi Multi", "EasyList"], also: ["HaGeZi Light", "HaGeZi Pro", "HaGeZi Pro++"]),
    .init(id: "tracking", title: "Stop Tracking Scripts", subtitle: "Known web trackers", lists: ["Peter Lowe’s ad servers", "Dan Pollock’s hosts", "EasyPrivacy"]),
    .init(id: "fingerprint", title: "Reduce Fingerprinting", subtitle: "Known tracking and fingerprinting script domains", lists: ["EasyPrivacy"], also: ["EasyPrivacy international"]),
    .init(id: "telemetry", title: "Block Telemetry", subtitle: "Device, TV and app telemetry endpoints", lists: ["Windows & Office trackers (HaGeZi)", "Smart TV tracking", "Samsung trackers (HaGeZi)", "Xiaomi trackers (HaGeZi)", "Amazon trackers (HaGeZi)", "TikTok trackers (HaGeZi)"], also: ["HaGeZi Pro++", "HaGeZi Pro"]),
    .init(id: "scams", title: "Block Scams & Ransomware", subtitle: "Scam sites and ransomware domains", lists: ["Scams (Blocklist Project)", "Ransomware (Blocklist Project)", "Scam blocklist (DurableNapkin)"]),
    .init(id: "safe", title: "Safe Browsing", subtitle: "Known malicious resources", lists: ["Anti-Malware (DandelionSprout)", "uBlock badware risks"]),
    .init(id: "mining", title: "Block Mining Scripts", subtitle: "Known browser mining scripts", lists: ["NoCoin (cryptojacking)", "Crypto miners & scams (Blocklist Project)"]),
    .init(id: "social", title: "Block Social Buttons", subtitle: "Social widgets and trackers", lists: ["Fanboy Social"]),
    .init(id: "cookies", title: "Hide Cookie Prompts", subtitle: "Cookie consent banners on supported sites", lists: ["Cookie notices (Fanboy)"]),
    .init(id: "popups", title: "Hide Popups", subtitle: "Newsletter, chat and promo overlays", lists: ["Fanboy Annoyances"]),
    .init(id: "banners", title: "Hide App Banners", subtitle: "App-install prompts and sticky banners", lists: ["Fanboy Annoyances"])
]

struct VSFilteringSettingsScreen: View {
    @ObservedObject var filtering: FilteringController
    private enum Section: String, CaseIterable, Identifiable { case general = "General", regional = "Regional", advanced = "Advanced", custom = "Custom"; var id: String { rawValue } }
    @AppStorage("filtering.settings.section") private var sectionRaw = Section.general.rawValue
    @State private var adding = false
    @State private var importing = false
    @State private var confirmBlock: SafariRuleCompiler.ResourceBlock?
    private var section: Section { Section(rawValue: sectionRaw) ?? .general }
    private var config: FilterConfiguration { filtering.configuration }

    /// Requested = switched on by the user. Applied needs Safari protection on, the extension enabled and a reload that Safari acknowledged.
    /// What the user just asked for, shown at once while the list downloads and rules are rebuilt (which takes a while). It is dropped when
    /// the operation ends, so the switch settles on what really happened.
    @State private var optimistic: [String: Bool] = [:]
    private func isOn(_ name: String) -> Bool { optimistic[name] ?? config.subscriptions.contains { $0.enabled && FilterCatalog.entry(forURL: $0.url)?.name == name } }
    private func listsOn(_ names: [String]) -> Bool { !names.isEmpty && names.allSatisfy(isOn) }
    /// A switch is on when any of its lists is on, so Light (which uses only the smaller lists) shows its switches on too.
    private func featureOn(_ feature: FilteringFeature) -> Bool { feature.unavailable == nil && (feature.lists + feature.also).contains(where: isOn) }
    private func remember(_ names: [String], _ on: Bool) { for name in names { optimistic[name] = on } }
    /// Switches stay as tapped until every queued change has finished, so a quick switch from one preset to another does not flicker.
    @State private var pendingOps = 0
    private func settle(_ names: [String]) { pendingOps -= 1; if pendingOps <= 0 { pendingOps = 0; optimistic.removeAll() } }
    private func begin() { pendingOps += 1 }
    private func subscription(named name: String) -> FilterSubscription? { config.subscriptions.first { FilterCatalog.entry(forURL: $0.url)?.name == name } }
    private func setFeature(_ feature: FilteringFeature, _ on: Bool) {
        let touched = on ? feature.lists : feature.lists + feature.also
        remember(touched, on); begin()
        Task {
            defer { settle(touched) }
            for name in touched {
                if let sub = subscription(named: name) { await filtering.setList(sub.id, enabled: on) }
                else if on, let entry = FilterCatalog.all.first(where: { $0.name == name }) { await filtering.addCatalogList(entry, enable: true) }
            }
        }
    }
    private func status(_ feature: FilteringFeature) -> (text: String, tint: Color) {
        let on = featureOn(feature)
        guard on else { return (feature.subtitle, .secondary) }
        if optimistic.contains(where: { feature.lists.contains($0.key) }) { return ("Applying…", .orange) }
        let active = (feature.lists + feature.also).filter(isOn)
        let loaded = active.allSatisfy { name in let sub = subscription(named: name); return !(sub?.rules.isEmpty ?? true) || sub?.content != nil }
        if !loaded { return ("Requested · rules not downloaded yet", .orange) }
        if !config.safariDesired { return ("Selected · Safari protection is off", .secondary) }
        if filtering.enabled == true && filtering.packageReady { return ("Applied in Safari · \(feature.subtitle)", .green) }
        return (feature.subtitle, .secondary)  // the banner above carries the "not confirmed by Safari" state once
    }
    private var sectionBlurb: String {
        switch section {
        case .general: return "Each switch turns on real blocklists. Rules go to Safari’s content blockers when Safari protection is on, and to DNS filtering when DNS is on."
        case .regional: return "Add filters for a country or language on top of the general ones."
        case .advanced: return "Blunt switches that refuse a whole kind of content on every site."
        case .custom: return "Your own allow and block rules and lists. Allow rules win over every blocklist."
        }
    }
    private var summary: (label: String, detail: String, tint: Color) {
        if !config.safariDesired { return ("Off", "Safari protection is switched off on the Adblock screen.", .secondary) }
        if config.effective.isEmpty && (config.resourceBlocks ?? []).isEmpty { return ("No filters", "Turn on a filter below.", .orange) }
        if filtering.enabled == true && filtering.packageReady { return ("Applied", "Extension enabled and rules loaded. Extension status and applied rules are verified separately.", .green) }
        if filtering.enabled == false { return ("Extension off", "Enable VayuSetu in Settings → Apps → Safari → Extensions.", .orange) }
        return ("Configured", "Saved, waiting for Safari to confirm the rules.", .orange)
    }
    var body: some View {
        let sum = summary
        ScrollView {
            VStack(spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    Circle().fill(sum.tint).frame(width: 10, height: 10).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Safari Filters · \(sum.label)").font(.subheadline.weight(.semibold))
                        Text(filtering.operationStatus.isEmpty ? sum.detail : filtering.operationStatus).font(.caption).foregroundStyle(filtering.operationStatus.isEmpty ? Color.secondary : VSDesign.accent).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if filtering.busy || !filtering.operationStatus.isEmpty { ProgressView() }
                }.vsCard(padding: 14)

                Picker("Section", selection: $sectionRaw) { ForEach(Section.allCases) { Text($0.rawValue).tag($0.rawValue) } }.pickerStyle(.segmented)

                Text(sectionBlurb).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                switch section {
                case .general: general
                case .regional: regional
                case .advanced: advanced
                case .custom: custom
                }
                if !filtering.message.isEmpty { Text(filtering.message).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
            }.padding(.horizontal, 16).padding(.bottom, 110)
        }.vsHeader("Filtering Settings", "Safari content protection").scrollIndicators(.hidden).background(VSDesign.background).vsInlineTitle().task { await filtering.refresh() }
        .sheet(isPresented: $adding) { NavigationStack { VSListEditor(filtering: filtering) }.vsSheetChrome() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText]) { result in
            do { let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }; let data = try LocalFiles.read(url, maximum: FilterParser.byteLimit); Task { await filtering.importList(data, name: url.deletingPathExtension().lastPathComponent) } }
            catch { filtering.report(error.localizedDescription) }
        }
        .vsConfirm(isPresented: Binding(get: { confirmBlock != nil }, set: { if !$0 { confirmBlock = nil } }), title: "Block every \(confirmBlock?.rawValue ?? "")?", message: "Many sites stop working properly without it. You can turn it off again here.", confirm: "Block", destructive: true, icon: "hand.raised.fill") { if let kind = confirmBlock { Task { await filtering.setResourceBlock(kind, true) } }; confirmBlock = nil }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).tracking(1).foregroundStyle(.secondary).padding(.horizontal, 4)
            VStack(spacing: 0) { content() }.vsCard(padding: 4)
        }
    }
    private var general: some View {
        VStack(spacing: 10) {
            VSFilterModePicker(filtering: filtering)
            generalToggles
        }
    }
    private var generalToggles: some View {
        group("RECOMMENDED") {
            ForEach(Array(generalFeatures.enumerated()), id: \.element.id) { index, feature in
                if index > 0 { Divider().overlay(VSDesign.separator).padding(.leading, 12) }
                let state = status(feature)
                Toggle(isOn: Binding(get: { featureOn(feature) }, set: { setFeature(feature, $0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feature.title).font(.subheadline.weight(.medium))
                        Text(feature.unavailable ?? state.text).font(.caption).foregroundStyle(feature.unavailable == nil ? state.tint : Color.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.disabled(feature.unavailable != nil).padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 52)
            }
        }
    }
    @State private var regionalSearch = ""
    private var regionalEntries: [CatalogList] {
        FilterCatalog.all.filter { $0.category == .regional && (regionalSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(regionalSearch) || $0.summary.localizedCaseInsensitiveContains(regionalSearch)) }
    }
    private func regionalStatus(_ entry: CatalogList) -> String {
        if optimistic[entry.name] == true { return "Downloading and applying…" }
        guard let sub = config.subscriptions.first(where: { $0.url == entry.url }), sub.enabled else { return entry.summary + " · " + entry.sizeLabel }
        if sub.rules.isEmpty { return "Downloading…" }
        let when = sub.updated.map { " · updated " + $0.formatted(.relative(presentation: .named)) } ?? ""
        return "\(sub.rules.count.formatted()) rules loaded" + when
    }
    private func setRegional(_ entry: CatalogList, _ on: Bool) {
        remember([entry.name], on); begin()
        Task {
            defer { settle([entry.name]) }
            if let sub = config.subscriptions.first(where: { $0.url == entry.url }) { await filtering.setList(sub.id, enabled: on) }
            else if on { await filtering.addCatalogList(entry, enable: true) }
        }
    }
    private var regional: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search language or country", text: $regionalSearch).vsInput()
            }.padding(.horizontal, 12).frame(minHeight: 40).background(VSDesign.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            group("\(regionalEntries.count) REGIONAL LISTS") {
                ForEach(Array(regionalEntries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider().overlay(VSDesign.separator).padding(.leading, 12) }
                    Toggle(isOn: Binding(get: { isOn(entry.name) }, set: { setRegional(entry, $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name).font(.subheadline.weight(.medium))
                            Text(regionalStatus(entry)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 52)
                }
                if regionalEntries.isEmpty { Text("No match").font(.footnote).foregroundStyle(.secondary).padding(14) }
            }
            Text("Every list here comes from the public AdGuard hostlists registry and was downloaded and checked by VayuSetu. The registry has no Telugu, Hindi or Tamil list, so none is offered. Regional lists are domain lists: they feed Safari’s Ads extension and DNS filtering, and cosmetic rules in them are ignored.").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var advanced: some View {
        VStack(spacing: 12) {
            group("BLOCK WHOLE RESOURCE TYPES") {
                ForEach(Array(SafariRuleCompiler.ResourceBlock.allCases.enumerated()), id: \.element) { index, kind in
                    if index > 0 { Divider().overlay(VSDesign.separator).padding(.leading, 12) }
                    Toggle(isOn: Binding(get: { (config.resourceBlocks ?? []).contains(kind.rawValue) }, set: { on in if on && (kind == .image || kind == .script) { confirmBlock = kind } else { Task { await filtering.setResourceBlock(kind, on) } } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind == .font ? "Block Webfonts" : kind == .image ? "Block Images" : kind == .script ? "Block Scripts" : "Force HTTPS").font(.subheadline.weight(.medium))
                            Text(kind == .font ? "Saves data; text may look different." : kind == .image ? "Pages load faster but look empty." : kind == .script ? "Most interactive sites stop working." : "Opens http addresses as https. Old sites that only offer http stop loading.").font(.caption).foregroundStyle(.secondary)
                        }
                    }.disabled(filtering.busy).padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 52)
                }
            }
            group("NOT AVAILABLE") {
                ForEach(["Anti-Adblock Rules", "Hide Article Comments"], id: \.self) { title in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                        Text("Needs page scripting or element hiding, which Safari’s content blocker cannot do from VayuSetu yet.").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
                }
            }
            Text("Safari accepts about \(SafariRuleCompiler.fitBudget.formatted()) of VayuSetu’s rules at a time so it stays responsive. DNS filtering uses the full lists.").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var custom: some View {
        group("YOUR RULES AND LISTS") {
            NavigationLink { VSCustomRulesScreen(filtering: filtering) } label: { customRow("slider.horizontal.3", "Custom Rules", "Allow or block a website", value: config.rules.isEmpty ? "" : "\(config.rules.count)") }.buttonStyle(VSPlainButtonStyle())
            Divider().overlay(VSDesign.separator).padding(.leading, 12)
            Button { adding = true } label: { customRow("link.badge.plus", "Add Filter List URL", "Download a list from a web address") }.buttonStyle(VSPlainButtonStyle())
            Divider().overlay(VSDesign.separator).padding(.leading, 12)
            Button { importing = true } label: { customRow("square.and.arrow.down", "Import From File", "Use a list stored on this device") }.buttonStyle(VSPlainButtonStyle()).disabled(filtering.busy)
            Divider().overlay(VSDesign.separator).padding(.leading, 12)
            NavigationLink { VSFilterListsScreen(filtering: filtering) } label: { customRow("line.3.horizontal.decrease", "All Filter Lists", "\(config.subscriptions.filter(\.enabled).count) on") }.buttonStyle(VSPlainButtonStyle())
            Divider().overlay(VSDesign.separator).padding(.leading, 12)
            NavigationLink { VSFilterCreditsScreen() } label: { customRow("heart.text.square", "Filter List Credits", "Who maintains each list") }.buttonStyle(VSPlainButtonStyle())
        }
    }
    private func customRow(_ icon: String, _ title: String, _ subtitle: String, value: String = "") -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) { Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            Spacer(minLength: 8)
            if !value.isEmpty { Text(value).font(.subheadline).foregroundStyle(.secondary) }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }.padding(.horizontal, 12).frame(minHeight: 52).contentShape(Rectangle())
    }
}

/// Turns blocking off for one website. The rule cancels every earlier Safari rule on that site's pages, in all six extensions.
struct VSWebsiteExceptionsScreen: View {
    @ObservedObject var filtering: FilteringController
    @State private var host = ""
    @State private var error = ""
    private var exceptions: [FilterRule] { filtering.configuration.rules.filter { $0.source == FilteringController.siteExceptionSource } }
    private func add() {
        let typed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let name = URL(string: typed.contains("://") ? typed : "https://" + typed)?.host ?? typed
        do { _ = try FilterDomain.normalize(name) } catch { self.error = "Enter a website such as example.com."; return }
        error = ""; host = ""
        Task { await filtering.upsertRule(id: nil, domain: name, action: .allow, scope: .domainAndSubdomains, enabled: true, source: FilteringController.siteExceptionSource) }
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Add a website").font(.subheadline.weight(.semibold))
                    HStack(spacing: 8) {
                        TextField("example.com", text: $host).vsInput().vsURLKeyboard().submitLabel(.done).onSubmit(add)
                            .padding(.horizontal, 12).frame(minHeight: 40).background(VSDesign.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        Button("Add", action: add).buttonStyle(VSCompactButtonStyle(prominent: true)).disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || filtering.busy)
                    }
                    if !error.isEmpty { Text(error).font(.footnote).foregroundStyle(.orange) }
                    Text("Safari stops blocking things on that site’s pages, and VayuSetu DNS stops blocking the site’s own name. Every other site stays protected.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.vsCard()

                VStack(alignment: .leading, spacing: 0) {
                    Text("Your exceptions").font(.subheadline.weight(.semibold)).padding(.bottom, 6)
                    if exceptions.isEmpty {
                        Text("No exceptions yet").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 56)
                    }
                    ForEach(Array(exceptions.enumerated()), id: \.element.id) { index, rule in
                        if index > 0 { Divider().overlay(VSDesign.separator) }
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(rule.domain).font(.subheadline.weight(.medium))
                                Text(rule.enabled == false ? "Blocking is back on for this site" : "Blocking is off for this site").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Toggle("", isOn: Binding(get: { rule.enabled != false }, set: { on in Task { await filtering.upsertRule(id: rule.id, domain: rule.domain, action: .allow, scope: rule.scope, enabled: on, source: FilteringController.siteExceptionSource) } })).labelsHidden().disabled(filtering.busy)
                            Button { Task { await filtering.removeRule(rule.id) } } label: { Image(systemName: "trash").font(.system(size: 16)).foregroundStyle(.red).frame(width: 36, height: 44) }.buttonStyle(VSPlainButtonStyle()).disabled(filtering.busy).accessibilityLabel("Delete \(rule.domain)")
                        }.frame(minHeight: 52)
                    }
                }.vsCard()

                if filtering.busy { ProgressView("Applying…").font(.footnote) }
                if !filtering.message.isEmpty { Text(filtering.message).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
            }.padding(.horizontal, 16).padding(.bottom, 110)
        }.vsHeader("Website Exceptions", "Turn blocking off for one site that does not work properly.").scrollIndicators(.hidden).background(VSDesign.background).vsInlineTitle()
    }
}


/// Every list VayuSetu can fetch, with its source. Lists stay under their maintainers' licences; VayuSetu downloads them at your request.
struct VSFilterCreditsScreen: View {
    private let notes: [String: String] = [
        "EasyList": "EasyList authors · GPLv3 / CC BY-SA 3.0", "EasyPrivacy": "EasyList authors · GPLv3 / CC BY-SA 3.0",
        "Cookie notices (Fanboy)": "Fanboy · CC BY 3.0", "Fanboy Annoyances": "Fanboy · CC BY 3.0", "Fanboy Social": "Fanboy · CC BY 3.0"
    ]
    var body: some View {
        VSCardList {
            VSSection { Text("VayuSetu does not bundle these lists. It downloads each one from its maintainer only after you switch it on. Open a source to read its licence and terms.").font(.footnote) }
            ForEach(FilterCatalog.grouped(), id: \.0) { category, items in
                VSSection(category.rawValue) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.subheadline.weight(.medium))
                            Text(notes[item.name] ?? "See source for licence").font(.caption).foregroundStyle(.secondary)
                            if let url = URL(string: item.url) { Link(url.host ?? item.url, destination: url).font(.caption) }
                        }
                    }
                }
            }
        }.vsList().vsHeader("Filter List Credits")
    }
}

// MARK: - In-app adblock test (same idea as adblock.turtlecute.org, run inside the app)
private struct TestTarget: Identifiable, Hashable { let category: String; let host: String; var id: String { category + host } }
private let testTargets: [TestTarget] = AdblockTestData.groups.flatMap { group in group.hosts.map { TestTarget(category: group.name, host: $0) } }

@MainActor private final class AdblockTestRunner: NSObject, ObservableObject {
    enum Verdict { case blockedByRules, blockedOther, notBlocked, unreachable }
    @Published var running = false
    @Published var progress = 0.0
    @Published var verdicts: [String: Verdict] = [:]
    @Published var message = ""
    private var lastError = ""
    @Published var rulesInTest = 0
    let container = PlatformView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    private var keepAlive: [LoadWaiter] = []
    private var dnsMatcher: DNSRuleSnapshot?
    private var withView: WKWebView?
    private var withoutView: WKWebView?
    var done: Bool { verdicts.count == testTargets.count }
    var total: Int { verdicts.values.filter { $0 != .unreachable }.count }
    var blocked: Int { verdicts.values.filter { $0 == .blockedByRules || $0 == .blockedOther }.count }
    var percent: Int { total == 0 ? 0 : Int((Double(blocked) / Double(total) * 100).rounded()) }

    func run(filtering: FilteringController, dnsFiltering: Bool, mode: String) async {
        guard !running else { return }
        dnsMatcher = dnsFiltering ? filtering.dnsRuleSnapshot() : nil
        running = true; progress = 0; verdicts = [:]; message = ""
        defer { running = false }
        let lists = await filtering.compiledRuleListsForTest()
        rulesInTest = lists.count
        let with = makeView(lists), without = makeView([])
        withView?.removeFromSuperview(); withoutView?.removeFromSuperview()
        withView = with; withoutView = without; container.addSubview(with); container.addSubview(without)
        let waiters = [LoadWaiter(), LoadWaiter()]
        await waiters[0].load("<html><body></body></html>", in: with); await waiters[1].load("<html><body></body></html>", in: without)
        keepAlive = waiters
        // A control request first: with no connection everything looks blocked.
        // Several well-known hosts and a longer wait, so one slow or filtered host cannot stop the test; one answer is enough to know the connection works.
        var control = await states(["www.apple.com/library/test/success.html", "www.gstatic.com/generate_204", "www.cloudflare.com/cdn-cgi/trace", "example.com"], in: without, timeout: 8000)
        if !control.values.contains("allowed") { control = await states(["www.apple.com/library/test/success.html", "example.com"], in: without, timeout: 12000) }
        guard control.values.contains("allowed") else {
            let seen = control.values.sorted().joined(separator: ", ")
            message = control.isEmpty ? "The test page could not run (\(lastError.isEmpty ? "no answer" : lastError))." : "No test host answered (\(seen)), so blocked cannot be told from unreachable. Your network may be filtering these sites, or another VPN, DNS profile or blocker is in the way. Check your connection and try again."
            await filtering.removeTestRuleLists(); return
        }
        // Step 1: which hosts answer with no rules at all. The answer is kept for six hours so every mode is scored on the same hosts;
        // otherwise a handful of slow hosts, different each run, would change the total and the percentage.
        struct Baseline: Codable { var time: Date; var dns: Bool; var total: Int; var hosts: [String] }
        let key = "adblocktest.baseline.v2"
        var reachable = Set<String>()
        var dnsBlocked = Set<String>()
        if let matcher = dnsMatcher { for target in testTargets where matcher.decide(target.host) == .block { dnsBlocked.insert(target.host) } }
        if let saved = UserDefaults.standard.data(forKey: key), let base = try? JSONDecoder().decode(Baseline.self, from: saved),
           Date().timeIntervalSince(base.time) < 6 * 3600, base.dns == (dnsMatcher != nil), base.total == testTargets.count { reachable = Set(base.hosts) }
        else {
            let toProbe = testTargets.map(\.host).filter { !dnsBlocked.contains($0) }
            let batches = stride(from: 0, to: toProbe.count, by: 160).map { Array(toProbe[$0..<min($0 + 160, toProbe.count)]) }
            for (position, batch) in batches.enumerated() {
                let answers = await states(batch, in: without)
                for (host, answer) in answers where answer == "allowed" { reachable.insert(host) }
                progress = 0.5 * Double(position + 1) / Double(batches.count)
            }
            if let data = try? JSONEncoder().encode(Baseline(time: Date(), dns: dnsMatcher != nil, total: testTargets.count, hosts: Array(reachable))) { UserDefaults.standard.set(data, forKey: key) }
        }
        // Step 2: the same hosts with the user's rules loaded.
        let probeNow = testTargets.filter { reachable.contains($0.host) }
        let rounds = stride(from: 0, to: probeNow.count, by: 160).map { Array(probeNow[$0..<min($0 + 160, probeNow.count)]) }
        for (position, round) in rounds.enumerated() {
            var answers = await states(round.map(\.host), in: with)
            let slow = round.map(\.host).filter { answers[$0] == "timeout" || answers[$0] == nil }
            if !slow.isEmpty { for (host, answer) in await states(slow, in: with) { answers[host] = answer } }      // one retry for hosts that were only slow
            for target in round {
                switch answers[target.host] {
                case "blocked": verdicts[target.id] = .blockedByRules
                case "allowed": verdicts[target.id] = .notBlocked
                default: verdicts[target.id] = .unreachable
                }
            }
            progress = 0.5 + 0.5 * Double(position + 1) / Double(max(rounds.count, 1))
        }
        for target in testTargets where verdicts[target.id] == nil { verdicts[target.id] = dnsBlocked.contains(target.host) ? .blockedOther : .unreachable }
        progress = 1
        await filtering.removeTestRuleLists()
        guard verdicts.count == testTargets.count else { return }
        var groups: [String: [Int]] = [:]
        for category in ["Ads", "Trackers", "Analytics", "Telemetry", "Device telemetry", "Ad scripts"] {
            let items = testTargets.filter { $0.category == category }.compactMap { verdicts[$0.id] }.filter { $0 != .unreachable }
            groups[category] = [items.filter { $0 == .blockedByRules || $0 == .blockedOther }.count, items.count]
        }
        filtering.saveTestRun(AdblockTestRun(percent: percent, tested: total, blocked: blocked, groups: groups, missed: testTargets.filter { verdicts[$0.id] == .notBlocked }.map(\.host), safariRulesLoaded: rulesInTest > 0, rulesExtensions: rulesInTest, dnsFiltering: dnsFiltering, listsOn: filtering.configuration.subscriptions.filter(\.enabled).count, mode: mode))
    }
    private func makeView(_ lists: [WKContentRuleList]) -> WKWebView {
        let config = WKWebViewConfiguration()
        for list in lists { config.userContentController.add(list) }
        return WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
    }
    private func states(_ hosts: [String], in view: WKWebView, timeout: Int = 3000) async -> [String: String] {
        let script = """
        const out = {};
        await Promise.all(hosts.map(async (h) => {
          const c = new AbortController(); const t = setTimeout(() => c.abort(), timeout);
          try { await fetch('https://' + h + (h.includes('/') ? '' : '/'), {mode: 'no-cors', signal: c.signal, cache: 'no-store'}); out[h] = 'allowed'; }
          catch (e) { out[h] = (e && e.name === 'AbortError') ? 'timeout' : 'blocked'; }
          clearTimeout(t);
        }));
        return out;
        """
        do {
            let result = try await view.callAsyncJavaScript(script, arguments: ["hosts": hosts, "timeout": timeout], in: nil, contentWorld: .page)
            if let typed = result as? [String: String] { return typed }
            if let loose = result as? [String: Any] { return loose.compactMapValues { $0 as? String } }
            lastError = "The test page returned no result."
        } catch { lastError = error.localizedDescription }
        return [:]
    }
}
#if os(iOS)
private struct TestHost: UIViewRepresentable {
    let view: PlatformView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
#else
private struct TestHost: NSViewRepresentable {
    let view: PlatformView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif

struct VSAdblockTestScreen: View {
    @ObservedObject var filtering: FilteringController
    @ObservedObject var store: AppStore
    /// Whether VayuSetu DNS filtering is running, recorded with each result because it changes what the test measures.
    private var dnsOn: Bool { store.dnsPill != .off }
    @AppStorage("adblocktest.autorun") private var autorun = true
    @StateObject private var runner = AdblockTestRunner()
    @State private var showMissed = false
    private var categories: [String] { ["Ads", "Trackers", "Analytics", "Telemetry", "Device telemetry", "Ad scripts"] }
    private func stats(_ category: String) -> (blocked: Int, total: Int) {
        let items = testTargets.filter { $0.category == category }
        let verdicts = items.compactMap { runner.verdicts[$0.id] }.filter { $0 != .unreachable }
        return (verdicts.filter { $0 == .blockedByRules || $0 == .blockedOther }.count, verdicts.count)
    }
    private func runTest() { Task { await runner.run(filtering: filtering, dnsFiltering: dnsOn, mode: VSFilterModePicker.name(filtering.configuration)) } }
    private var tint: Color { runner.percent >= 80 ? .green : runner.percent >= 50 ? .orange : .red }
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("Filtering mode").font(.subheadline.weight(.semibold)); Spacer(); Text(VSFilterModePicker.name(filtering.configuration)).font(.subheadline.weight(.semibold)).foregroundStyle(VSDesign.accent) }
                    VSFilterModePicker(filtering: filtering) { if autorun { runTest() } }.disabled(runner.running)
                    Divider().overlay(VSDesign.separator)
                    Toggle("Safari blocking", isOn: Binding(get: { filtering.configuration.safariDesired }, set: { value in Task { await filtering.setSafari(value); if autorun { runTest() } } })).disabled(runner.running || filtering.busy)
                    Toggle("VayuSetu DNS filtering", isOn: Binding(get: { store.dnsPill != .off }, set: { _ in Task { await store.togglePill(.dns); if autorun { runTest() } } })).disabled(runner.running || store.protectionBusy)
                    Toggle("Test again after each change", isOn: $autorun)
                }.font(.subheadline).vsCard()

                VStack(spacing: 14) {
                    ZStack {
                        Circle().stroke(VSDesign.separator, lineWidth: 10)
                        Circle().trim(from: 0, to: runner.running ? runner.progress : Double(runner.percent) / 100).stroke(runner.running ? VSDesign.accent : tint, style: StrokeStyle(lineWidth: 10, lineCap: .round)).rotationEffect(.degrees(-90)).animation(.easeOut(duration: 0.3), value: runner.progress)
                        VStack(spacing: 0) {
                            Text(runner.done || runner.running ? (runner.running ? "\(Int(runner.progress * 100))%" : "\(runner.percent)%") : "—").font(.system(size: 40, weight: .semibold)).monospacedDigit()
                            Text(runner.running ? "testing…" : runner.done ? "blocked" : "not run").font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(width: 150, height: 150).padding(.top, 6)
                    HStack(spacing: 0) {
                        figure("Tested", runner.done ? "\(runner.total)" : "—", .primary)
                        Divider().frame(height: 30)
                        figure("Blocked", runner.done ? "\(runner.blocked)" : "—", .green)
                        Divider().frame(height: 30)
                        figure("Not blocked", runner.done ? "\(runner.total - runner.blocked)" : "—", .red)
                    }
                    Button { runTest() } label: { Label(runner.done ? "Test Again" : "Run Test", systemImage: "play.fill").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 40) }
                        .buttonStyle(.borderedProminent).vsTapHaptic().disabled(runner.running || filtering.busy)
                    if !runner.message.isEmpty { Text(runner.message).font(.footnote).foregroundStyle(.orange) }
                }.vsCard()

                if runner.done {
                    VStack(spacing: 10) {
                        ForEach(categories, id: \.self) { category in
                            let s = stats(category)
                            if s.total > 0 {
                                VStack(spacing: 4) {
                                    HStack { Text(category).font(.subheadline); Spacer(); Text("\(s.blocked) / \(s.total)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
                                    ProgressView(value: Double(s.blocked), total: Double(max(s.total, 1))).tint(s.blocked * 10 >= s.total * 8 ? .green : s.blocked * 2 >= s.total ? .orange : .red)
                                }
                            }
                        }
                    }.vsCard()
                    let missed = testTargets.filter { runner.verdicts[$0.id] == .notBlocked }
                    if !missed.isEmpty {
                        DisclosureGroup("Not blocked (\(missed.count))", isExpanded: $showMissed) {
                            VStack(alignment: .leading, spacing: 6) { ForEach(missed) { Text($0.host).font(.caption.monospaced()).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) } }.padding(.top, 6)
                        }.vsCard()
                    }
                }

                if !filtering.testHistory.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack { Text("Past tests").font(.subheadline.weight(.semibold)); Spacer(); Button("Clear", role: .destructive) { filtering.clearTestHistory() }.font(.footnote) }.padding(.bottom, 6)
                        ForEach(Array(filtering.testHistory.prefix(showAllRuns ? filtering.testHistory.count : 10).enumerated()), id: \.element.id) { index, run in
                            if index > 0 { Divider().overlay(VSDesign.separator) }
                            pastRun(run)
                        }
                        if filtering.testHistory.count > 10 {
                            Divider().overlay(VSDesign.separator)
                            Button { withAnimation { showAllRuns.toggle() } } label: {
                                Text(showAllRuns ? "Show fewer" : "View more (\(filtering.testHistory.count - 10))").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 40)
                            }.buttonStyle(VSPlainButtonStyle()).foregroundStyle(VSDesign.accent)
                        }
                    }.vsCard()
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("What this test measures").font(.footnote.weight(.semibold))
                    Text("\(runner.running || runner.done ? (runner.rulesInTest > 0 ? "Your Safari rules (\(runner.rulesInTest) extension\(runner.rulesInTest == 1 ? "" : "s")) were loaded into WebKit, Safari’s engine" : "Safari protection is off or has no rules, so only DNS filtering could block") : "Your Safari rules are loaded into WebKit, Safari’s engine"). A request counts as blocked when it is refused with your rules, or when it fails even without them (for example, VayuSetu DNS filtering is on). Unreachable domains are left out. It is a sample, not every ad on the web.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading).vsCard()
                TestHost(view: runner.container).frame(width: 1, height: 1).opacity(0.01).accessibilityHidden(true)
            }.padding(.horizontal, 16).padding(.bottom, 110)
        }.vsHeader("Adblock Test", "Real ad, tracker and analytics requests, with and without your rules.").scrollIndicators(.hidden).background(VSDesign.background).vsInlineTitle().task { filtering.loadTestHistory() }
    }
    @State private var openRun: UUID?
    @State private var showAllRuns = false
    private func pastRun(_ run: AdblockTestRun) -> some View {
        let tint: Color = run.percent >= 80 ? .green : run.percent >= 50 ? .orange : .red
        return VStack(alignment: .leading, spacing: 6) {
            Button { openRun = openRun == run.id ? nil : run.id } label: {
                HStack(spacing: 10) {
                    Text("\(run.percent)%").font(.system(size: 17, weight: .semibold)).monospacedDigit().foregroundStyle(tint).frame(width: 52, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(run.date.formatted(date: .abbreviated, time: .shortened)).font(.subheadline)
                        Text("\(run.mode ?? "Custom") · \(run.blocked) of \(run.tested) · \(run.safariRulesLoaded ? "Safari" : "no Safari")\(run.dnsFiltering ? " + DNS" : "")").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: openRun == run.id ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.tertiary)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(VSPlainButtonStyle())
            if openRun == run.id {
                ForEach(["Ads", "Trackers", "Analytics", "Telemetry", "Device telemetry", "Ad scripts"], id: \.self) { name in
                    if let counts = run.groups[name], counts.count == 2, counts[1] > 0 { HStack { Text(name).font(.caption); Spacer(); Text("\(counts[0]) / \(counts[1])").font(.caption.monospacedDigit()).foregroundStyle(.secondary) } }
                }
                Text("\(run.listsOn) lists on" + (run.safariRulesLoaded ? " · \(run.rulesExtensions) extension\(run.rulesExtensions == 1 ? "" : "s") loaded" : "")).font(.caption).foregroundStyle(.secondary)
                if !run.missed.isEmpty { Text("Not blocked: " + run.missed.prefix(12).joined(separator: ", ") + (run.missed.count > 12 ? " and \(run.missed.count - 12) more" : "")).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }.padding(.vertical, 4)
    }
    private func figure(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 2) { Text(value).font(.system(size: 20, weight: .semibold)).monospacedDigit().foregroundStyle(color); Text(title).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity)
    }
}

/// DNS activity: requests and blocks that VayuSetu DNS filtering observed. Lives on the DNS tab because only DNS filtering can count them.
struct VSActivityDashboard: View {
    @ObservedObject var filtering: FilteringController
    @AppStorage(ActivityPeriodStore.key) private var periodRaw = ActivityPeriod.day.rawValue
    @State private var info: String?
    private var config: FilterConfiguration { filtering.configuration }
    private var periodBinding: Binding<ActivityPeriod> { Binding(get: { ActivityPeriod(rawValue: periodRaw) ?? .day }, set: { periodRaw = $0.rawValue }) }
    private func metric(_ title: String, _ value: String, _ color: Color, _ explanation: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Button { info = explanation } label: { Image(systemName: "info.circle").font(.caption).foregroundStyle(.tertiary).frame(width: 28, height: 28).contentShape(Rectangle()) }.buttonStyle(VSPlainButtonStyle()).accessibilityLabel("About \(title)")
            }
            Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit().foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    var body: some View {
        let series = filtering.activitySeries(periodBinding.wrappedValue)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Activity", systemImage: "chart.xyaxis.line").font(.title3.weight(.semibold))
                Spacer()
                VSActivityPeriodButton(period: periodBinding)
            }
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    metric("Requests", series.requests.formatted(), .primary, "DNS requests VayuSetu observed while DNS protection was on, in the selected period.")
                    metric("Blocked", series.blocked.formatted(), .orange, "Observed DNS requests answered as blocked by VayuSetu’s local filter. Safari’s content blocker does not report what it blocks, so those are not counted.")
                }
                HStack(alignment: .top, spacing: 12) {
                    metric("Data Saved", "—", .green, "Not estimated. There is no defensible way to know how much data a blocked DNS request would have used.")
                    metric("Companies", "—", .secondary, "Needs a maintained domain-to-company dataset, which VayuSetu does not include. Domain counts are not company counts.")
                }
            }
            VSActivityChart(series: series, height: 160, interactive: true)
            Text("Scope: DNS requests observed by VayuSetu DNS filtering. Not all device or Safari traffic.").font(.caption2).foregroundStyle(.secondary)
            Divider().overlay(VSDesign.separator)
            NavigationLink { VSDomainRankingScreen(kind: .active, filtering: filtering) } label: { rankingRow("Most Active", "Domains asked for most often") }.buttonStyle(VSPlainButtonStyle())
            Divider().overlay(VSDesign.separator)
            NavigationLink { VSDomainRankingScreen(kind: .blocked, filtering: filtering) } label: { rankingRow("Most Blocked", "Domains blocked most often") }.buttonStyle(VSPlainButtonStyle())
        }.vsCard()
        .vsAlert(isPresented: Binding(get: { info != nil }, set: { if !$0 { info = nil } }), tone: .info, icon: "questionmark.circle.fill", title: "About this number", message: info ?? "", then: { info = nil })
    }
    private func rankingRow(_ title: String, _ subtitle: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) { Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            Spacer(minLength: 8)
            Text("Not recorded").font(.caption).foregroundStyle(.secondary)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }.frame(minHeight: 44).contentShape(Rectangle())
    }
}

// Live, widely blocked ad, tracker, analytics and telemetry hosts, plus ad-script URLs. Sources: hosts that at least five public blocklists agree on, and the hosts and scripts
// used by the public ad-block test pages (adblock.turtlecute.org, obfusgated.com, getblockify.com, adblock-tester.com, superadblocktest.com), with duplicates removed.
// The test asks the web view to reach each one with and without the user's rules; hosts that do not answer are left out of the score.
enum AdblockTestData {
    static let groups: [(name: String, hosts: [String])] = [
        ("Ads", [
            "33across.com", "a.teads.tv", "a11.click", "aaddzz.com", "acuityplatform.com",
            "ad-flow.com", "ad-server.co.za", "ad-srv.net", "ad.gt", "ad.nettvservices.com", "ad.period-calendar.com",
            "ad.style", "adbro.me", "adbuddiz.com", "adcel.co", "adcolony.com", "adecn.com", "ademails.com",
            "adexchangedirect.com", "adform.net", "adfox.yandex.ru", "adhealers.com", "adhese.be", "adhese.com", "adjug.com", "adland.ru",
            "admarketplace.net", "admedo.com", "admeridianads.com", "admob.googleapis.com", "adnet.ru", "adnico.jp", "adnxs.com", "adotmob.com",
            "adpatrof.com", "adpia.vn", "adreactor.com", "adrecreate.com", "adroll.com", "adrotic.girlonthenet.com", "ads-api.x.com",
            "ads-twitter.com", "ads.betfair.com", "ads.deezer.com", "ads.fotosidan.se", "ads.freewheel.tv", "ads.fyber.com", "ads.iheart.com",
            "ads.mozilla.org", "ads.pinterest.com", "ads.snapchat.com", "ads.soundcloud.com",
            "ads.tritondigital.com", "ads.x.com", "ads.yahoo.com", "ads5-adnow.com", "adsco.re",
            "adserverpub.com", "adservice.google.com", "adserving.unibet.com", "adsonar.com", "adspredictiv.com",
            "adsrvr.org", "adsserver.megaphone.fm", "adstanding.com", "adstub.net", "adsupply.com", "adsxyz.com", "adtaily.pl",
            "adtech.yahooinc.com", "adtlgc.com", "adtrue.com", "advertipros.com", "advertiserurl.com", "advice-ads.s3.amazonaws.com",
            "adx-exchange.toast.com", "affiliate.dtiserv.com", "affiliates.thrixxx.com", "aim4media.com", "alphonso.tv",
            "altitude-arena.com", "am15.net", "amazon-adsystem.com", "ambientplatform.vn", "anymind360.com", "apex.go.sonobi.com", "api.fyber.com",
            "api.rlcdn.com", "applovin.com", "aralego.com", "areasnap.com",
            "aso1.net", "assets.revcontent.com", "ay.delivery", "banners.alt.com", "belstat.com", "betr-for-tod.com",
            "bidswitch.net", "blogads.com", "bnserving.com", "brandreachsys.com", "btprmnav.com",
            "bugpuk.ru", "capi.connatix.com", "carambo.la", "carbonads.net", "casalemedia.com", "cbzxy.com",
            "cd.connatix.com", "cdn.teads.tv", "clickbooth.com", "clickcash.com", "clickxchange.com",
            "clrstm.com", "colossusssp.com", "comilar-efferiff.icu", "cpalead.com", "cpmstar.com", "craktraffic.com",
            "creativecdn.com", "criteo.com", "d3v3bqdndm4erx.cloudfront.net", "de17a.com", "decknetwork.net",
            "demandbase.com", "deostr.com", "dnsdelegation.io", "doubleclick.net", "dtscout.com", "eb2.3lift.com", "eclkmpsa.com",
            "edge.supersonicads.com", "eiv.baidu.com", "entrecard.s3.amazonaws.com", "et.nytimes.com", "etargetnet.com",
            "evs.sgmt.loom.com", "exoclick.com", "eyeota.net", "fam-ad.com", "fc.webmasterpro.de", "fimserve.com",
            "flairadscpc.com", "frtya.com", "fw.adsafeprotected.com", "ga.clearbit.com", "geoaddicted.net", "gmads.net", "googleadservices.com",
            "googlesyndication.com", "grapeshot.co.uk", "greystripe.com", "gumyfui.com", "gwallet.com", "harrenmedianetwork.com",
            "himediads.com", "hyperbanner.net", "iad.anm.co.uk",
            "idsync.rlcdn.com", "indieclick.com", "info.lgsmartad.com", "infolinks.com",
            "init.supersonicads.com", "inmobi.com", "iyfbodn.com", "jadcenter.com", "jads.co",
            "juicyads.com", "juicyads.me", "k5zoom.com", "keepinfit.net", "keywordblocks.com", "kliksaya.com", "kra18.com", "launchbit.com",
            "leadzu.com", "linkexchange.com", "linkreferral.com", "live.chartboost.com", "liverail.com", "loktrk.com", "lucidmedia.com", "lzjl.com",
            "m.trb.com", "m32.media", "madadsmedia.com", "mads-eu.amazon.com", "mail-ads.google.com", "maxonclick.com",
            "maxserving.com", "media.net", "medleyads.com", "methodcash.com", "mfadsrvr.com", "mgid.com",
            "mintegral.com", "ml314.com", "mmotraffic.com", "mobclix.com", "mpnrs.com", "mystat-in.net", "newads.bangbros.com",
            "nmcdn.us", "novem.pl", "nqslmtuswqdz.com", "nr.static.mmcdn.com", "ntvk1.ru", "nuseek.com", "obs.sd4823.spglobal.com",
            "octopuspop.com", "offerimage.com", "ogads-pa.googleapis.com", "onclickads.net", "open.oneplus.net", "openx.net",
            "outbrain.com", "outcome-ssp.supersonicads.com", "oxado.com",
            "pagefair.com", "partnerads.ysm.yahoo.com", "partnercash.de", "pbnet.ru", "peakclick.com", "peer39.com",
            "perfiliate.com", "pixel.adsafeprotected.com", "pointroll.com", "popads.net", "popcash.net", "popmyads.com",
            "porngraph.com", "powerad.ai", "prchecker.info", "predictiondisplay.com", "proext.com", "projectwonderful.com",
            "promos.fling.com", "promos.meetlocals.com", "propellerads.com", "propellerclick.com", "pub.network",
            "pubmatic.com", "pubmine.com", "pubnative.net", "qnsr.com", "relmaxtop.com",
            "rereddit.com", "rkv1.com", "ronracepub.com", "rtbadzesto.com", "rtbplatform.net", "rtmark.net",
            "rubiconproject.com", "run-syndicate.com", "s20dh7e9dh.com", "s2d6.com", "samsungads.com",
            "sedoparking.com", "seethisinaction.com", "sex-and-flirt.com",
            "sexlist.com", "sharethrough.com", "silvermob.com", "smartyads.com", "snoobi.com", "sponsorads.de", "spotxchange.com",
            "static.adsafeprotected.com", "static.criteo.net",
            "statistik-gallup.net", "steelhousemedia.com", "stickyadstv.com", "storetail.io", "sumome.com", "supertop.ru",
            "synchroscript.adswizz.com", "taboola.com", "tapad.com", "targetingnow.com", "tatsumi-sys.jp", "tealium.cbsnews.com",
            "the-ozone-project.com", "thrtle.com", "tlx.3lift.com", "toiletpaper.life", "toplist.cz", "topqualitylink.com",
            "tr.api.fanbyte.com", "trafficholder.com", "trafficshop.com", "trafficswarm.com", "trafforsrv.com",
            "tremorhub.com", "tribalfusion.com", "trustaffs.com", "ttoc8ok.com", "tubemogul.com", "turboadv.com", "twittad.com",
            "ufpcdn.com", "ukoffzeh.com", "upu.samsungelectronics.com", "us.a1.yimg.com",
            "valueclick.com", "vcommission.com", "velocecdn.com", "vid.connatix.com", "vidcpm.com", "voluumtrk.com", "voluumtrk2.com", "vungle.com",
            "wa.and.co.uk", "waardex.com", "waudeesestew.com", "web-stat.com", "webads.co.nz", "webstat.channel4.com",
            "webstat.com", "webstat.net", "wwwpromoter.com", "xad.com", "xml-v4.oceanfall.xyz",
            "youradexchange.com", "yumenetworks.com", "zanox-affiliate.de", "zanox.com", "zedo.com", "zeydoo.com", "zm232.com", "zoologyfibre.com"
        ]),
        ("Trackers", [
            "4jnzhl0d0.com", "aa.agkn.com", "aan.amazon.com", "accountsdoor.com", "ad.linksynergy.com", "ad.mail.ru", "adfstat.yandex.ru",
            "adjust.com", "adtago.s3.amazonaws.com", "alexandria.marfeelcdn.com", "analytics.twitter.com", "anrdoezrs.net", "api.content-ad.net",
            "api.viglink.com", "api2.branch.io",
            "app.usercentrics.eu", "appsflyer.com", "asumi.shinobi.jp", "async-px-eu.dynamicyield.com", "audience2media.com",
            "avalonalbum.com", "awin1.com", "awzbijw.com", "bam.nr-data.net", "basketballbelieve.com", "bat.bing.com",
            "beacon.netflix.com", "bewilderedblade.com", "birthdaybelief.com", "bleachbubble.com", "bluekai.com", "bluenest.net",
            "blushingbread.com", "boilingbeetle.com", "boilingmadsoup.com", "boredcrown.com", "brandybison.com", "btloader.com", "bttrack.com",
            "bubblyaction.com", "buf.lemonde.fr", "c.gumgum.com", "calculatorstatement.com", "calypsocapsule.com", "capitalopera.com",
            "captainstick.com", "carvecakes.com", "cautiouscredit.com", "cdn.dynamicyield.com",
            "cdn.imrworldwide.com", "cdn.kargo.com", "cdn.mxpnl.com",
            "cdn.viglink.com", "chairscrack.com", "clevertap-prod.com", "click.linksynergy.com", "clickadu.com",
            "coinimp.com", "collect.rewardstyle.com", "collect.usefathom.com", "collector.githubapp.com", "collector.xhamster.com",
            "confiant-integrations.global.ssl.fastly.net", "connect.facebook.net",
            "contextweb.com", "cookiebot.com", "copycarpenter.com", "crwdcntrl.net",
            "crypto-loot.org", "ct.pinterest.com", "curiousmetal.com", "cutechin.com", "d.impactradius-event.com", "damdoor.com", "data.queryly.com",
            "datapickles.com", "decisivebase.com", "delicatecascade.com", "desiredirt.com", "digestiondrawer.com", "discreetfield.com",
            "dogcollarfavourbluff.com", "doubleverify.com", "dpbolvw.net", "echoacloud.com", "emptyescort.com",
            "energeticladybug.com", "essaygiants.com", "events.brightline.tv", "events.redditmedia.com", "extmaps-api.yandex.net",
            "f-emc.ngsp.gov.vn", "fallingshoals.com", "farethief.com", "femalecook.com", "fingerprintjs.com", "flashtexting.com",
            "floweryflavor.com", "fontserif.com", "fpjs.io", "freshmarketer.com", "funtoyplanet.com", "g.jwpsrv.com",
            "ga-beacon.appspot.com", "gammamaximum.com", "gemini.yahoo.com", "geo.yahoo.com", "geolocation.onetrust.com", "glasscoyote.com",
            "go.skimresources.com", "grouchybrothers.com", "handsomehose.com", "haplesshydrant.com", "hfc195b.com",
            "hilariouszinc.com", "hocgeese.com", "homelycrown.com", "honorableland.com", "hystericalcloth.com", "id5-sync.com", "idsync.drawbrid.ge",
            "imasdk.googleapis.com", "impact.com", "indexexchange.com", "infinityid.condenastdigital.com", "inmobicdn.net", "is.com",
            "joyoussurprise.com", "js.driftt.com", "jsecoin.com", "juiceblocks.com", "kittentacos.com", "kochava.com", "kropka.onet.pl",
            "lameletters.com", "laurel.rovicorp.com", "liftoff.io", "linkedin.com", "linkstable.com", "list-manage.com", "livingsleet.com",
            "loadsurprise.com", "magicaljoin.com", "marketgid.com", "mc.yandex.ru", "mcs-va.tiktokv.com", "measlymiddle.com", "metajaws.com",
            "metrika.yandex.ru", "mineralt.io", "minero.cc", "mittencattle.com", "morefolks.com", "movemeal.com", "mssl.fwmrm.net",
            "munchkin.marketo.net", "muteknife.com", "nervoussummer.com", "net.rayjump.com", "ngfts.lge.com", "noiselessplough.com",
            "offerwall.yandex.net", "onaudience.com", "onetag-sys.com", "overconfidentfood.com", "overkick.com", "owlsr.us", "painstakingpickle.com",
            "pangleglobal.com", "panickypancake.com", "panoramicplane.com", "parentpicture.com", "partnerstack.com", "permutive.com",
            "pipedream.wistia.com", "pippio.com", "pixel.facebook.com", "pixel.quora.com",
            "pixiedust.buzzfeed.com", "platform.iteratehq.com", "pos.baidu.com", "prd-collector-anon.ex.co", "priceypies.com", "prod.uidapi.com",
            "profitrumour.com", "propeller-tracking.com", "publicsofa.com", "px.srvcs.tumblr.com", "q.quora.com", "quantcast.com", "quantserve.com",
            "quizzicalzephyr.com", "rabbitrifle.com", "railwayreason.com", "readingguilt.com", "redditstatic.com",
            "redirect.viglink.com", "redirector.skimresources.com", "refersion.com",
            "reporting-api.gannettinnovation.com", "resonantbrush.com", "retargeter.com", "rockagainst.com", "s.innovid.com", "s.ntv.io",
            "s.skimresources.com", "sc-static.net", "scarfsmash.com", "scatteredheat.com", "scintillatingsilver.com",
            "scorecardresearch.com", "screechingfurniture.com", "screechingstocking.com", "sdk.privacy-center.org", "sedotracker.com",
            "shareasale.com", "siftscience.com", "simulateswing.com", "singular.net", "sixscissors.com", "snap.licdn.com",
            "snazzypoodle.com", "soma.smaato.net", "sombersea.com", "sombersquirrel.com", "spookysleet.com", "spotlessstamp.com", "ssl.p.jwpcdn.com",
            "ssp.seznam.cz", "starrynets.com", "stat.cncenter.cz", "statdynamic.com", "steadfastsystem.com", "stiffgame.com",
            "stimulatingsneeze.com", "sulkycook.com", "sunsetcampfires.com", "supportwaves.com", "sync.kargo.com", "sync.shinobi.jp",
            "systemssummit.com", "t.skimresources.com", "tag.leadplace.fr", "tangyamount.com",
            "targeting.voxus.tv", "tendertest.com", "thetradedesk.com", "thewavebeats.com", "ticklesign.com", "tkqlhce.com", "top-fwz1.mail.ru",
            "tr.snapchat.com", "trace.qq.com", "track.hubspot.com", "track.linksynergy.com", "track.pricespider.com", "track.vscash.com",
            "trackcmp.net", "tracker.icerocket.com", "tracker.samplicio.us", "tracking.godatafeed.com", "tracking.intentsify.io",
            "tracking.miui.com", "tracking2.channeladvisor.com", "trafficjunky.net", "trk.pinterest.com", "trust.titanhq.com", "tvinteractive.tv",
            "tvpixel.com", "udcm.yahoo.com", "unbecominglamp.com", "unwieldyhealth.com", "upgradeyoga.com", "verybark.com",
            "vid.vidyard.com", "washbanana.com", "webminepool.com", "whiskyqueue.com", "whisperingcrib.com", "whisperingsummit.com",
            "widget.intercom.io", "widget.zemanta.com", "wzrkt.com", "zenaps.com",
            "zephyrlabyrinth.com"
        ]),
        ("Analytics", [
            "adblockanalytics.com", "addfreestats.com", "amazingcounters.com", "analyticcdn.globalmailer.com",
            "analytics-fe.digital-cloud-prem.medallia.eu", "analytics-sg.tiktok.com", "analytics-static.ugc.bazaarvoice.com",
            "analytics-tracker.thescore.com", "analytics.adobe.io", "analytics.aweber.com", "analytics.bitrix.info", "analytics.chase.com",
            "analytics.global.sky.com", "analytics.google.com", "analytics.htmedia.in", "analytics.jst.ai", "analytics.kaltura.com",
            "analytics.kongregate.io", "analytics.mailmunch.co", "analytics.mobile.yandex.net", "analytics.nike.com", "analytics.ostr.io",
            "analytics.picsart.com", "analytics.posttv.com", "analytics.query.yahoo.com",
            "analytics.reyrey.net", "analytics.rogersmedia.com", "analytics.s3.amazonaws.com", "analytics.sitewit.com",
            "analytics.slashdotmedia.com", "analytics.sleeknote.com", "analytics.strangeloopnetworks.com", "analytics.supplyframe.com",
            "analytics.tiktok.com", "analytics.yahoo.com", "analytics.yolacdn.net", "analytics.ziftsolutions.com",
            "analyticsengine.s3.amazonaws.com", "api.amplitude.com",
            "api.optimizely.com", "api2.amplitude.com", "app-analytics.snapchat.com", "blogcounter.de",
            "cdn.amplitude.com",
            "cdn.optimizely.com", "cdn.segment.com", "cgicounter.onlinehome.de", "cgicounter.puretec.de", "clarity.ms",
            "click.googleanalytics.com", "counter.bloke.com", "counter.cnw.cz", "counter.rambler.ru",
            "counter.snackly.co", "counters.freewebs.com", "cqcounter.com", "cs.luckyorange.net",
            "device-metrics-us-2.amazon.com", "device-metrics-us.amazon.com", "easyhits4u.com", "events.hotjar.io",
            "freestats.com", "freestats.tv", "fullstory.com", "getclicky.com", "goldstats.com", "google-analytics.com", "googletagmanager.com",
            "gostats.com", "heapanalytics.com", "hghit.com", "histats.com", "hitbox.com", "hitcpm.com", "hitlist.ru",
            "hits-i.iubenda.com", "hits.informer.com", "hits.theguardian.com", "hitslink.com", "hotjar.com",
            "indexstats.com", "insightexpress.com", "insightexpressai.com", "luckyorange.com",
            "markedmeasure.com", "measuremap.com", "mixpanel.com", "mouseflow.com", "mycounter.ua", "neocounter.neoworx-blog-tools.net",
            "netclickstats.com", "pages-stats.rbl.ms", "pixel.mathtag.com", "ranking-hits.de",
            "revenuehits.com", "rightstats.com", "sanalytics.disneyplus.com", "sc-analytics.appspot.com", "script.crazyegg.com",
            "segment-cdn.producthunt.com", "segment.io", "settings.luckyorange.net", "sexcounter.com",
            "shareasale-analytics.com", "stats-dev.brid.tv", "stats-newyork1.bloxcms.com",
            "stats.blogoscoop.net", "stats.bluebillywig.com", "stats.itweb.co.za", "stats.kaltura.com", "stats.olark.com",
            "stats.ozwebsites.biz", "stats.polldaddy.com", "stats.pusher.com", "stats.rip", "stats.shopify.com", "stats.townnews.com",
            "stats.vulture.com", "stats.wired.com", "stats.wordpress.com", "stats.wp.com", "stats2.self.com", "stats4all.com", "superstats.com",
            "sync.mathtag.com", "tns-counter.ru", "truehits.net",
            "truehits1.gits.net.th", "ucounter.ucoz.net", "unidentifiedanalytics.web.app", "upload.luckyorange.net", "usersegment.wpdigital.net",
            "visiblemeasures.com", "webcounter.goweb.de", "webstats.thaindian.com", "webstats1.com",
            "www-google-analytics.l.google.com", "xxxcounter.com", "zhihu-web-analytics.zhihu.com"
        ]),
        ("Telemetry", [
            "24log.com", "aa-metrics.beauty.hotpepper.jp", "aa-metrics.hotpepper.jp", "adlog.com.com", "amp-error-reporting.appspot.com",
            "api.bugsnag.com", "app-measurement.com", "app.bugsnag.com", "app.getsentry.com", "appmetrica.yandex.ru", "browser.sentry-cdn.com",
            "cakesdrum.com", "clickonometrics.pl", "crashchance.com", "crashlytics.com", "cushiondrum.com", "exportdialog.com",
            "freelogs.com", "hotlog.ru", "inetlog.ru", "kissmetrics.com", "log.cookieyes.com",
            "log.fc.yahoo.com", "log.medietall.no", "log.olark.com", "log.pinterest.com", "log.sina.cn", "log.snapdeal.com",
            "logs.netflix.com", "logs.roku.com", "logs.spilgames.com", "logx.optimizely.com", "metrics-a.wbx2.com", "metrics-logger.spot.im",
            "metrics.api.drift.com", "metrics.aviasales.ru", "metrics.baitoru.com", "metrics.brightcove.com", "metrics.cnn.com",
            "metrics.foxnews.com", "metrics.icloud.com", "metrics.kmsmep.com", "metrics.makemytrip.com", "metrics.mzstatic.com",
            "metrics.news.com.au", "metrics.ted.com", "metrics.timewarnercable.com", "metrics.toysrus.com", "mybloglog.com", "nmetrics.samsung.com",
            "notify.bugsnag.com", "sentry.io", "sessions.bugsnag.com", "smetrics.bestbuy.com", "smetrics.capitalone.com", "smetrics.cnn.com",
            "smetrics.ctv.ca", "smetrics.fedex.com", "smetrics.foxnews.com", "smetrics.jcb.co.jp", "smetrics.kone.vn", "smetrics.marriott.com",
            "smetrics.nfl.com", "smetrics.samsung.com", "smetrics.walgreens.com", "smetrics.washingtonpost.com", "spylog.com",
            "telemetry.goodlifefitness.com", "telemetry.malwarebytes.com", "vortex.data.microsoft.com", "zion-telemetry.api.cnn.io"
        ]),
        ("Device telemetry", [
            "a.lenovo.com", "ad.lgappstv.com", "adlog.vivo.com", "ads-api.tiktok.com", "ads-api.vivo.com", "ads-sg.tiktok.com", "ads.huawei.com",
            "ads.microsoft.com", "ads.roku.com", "ads.tiktok.com", "ads.vizio.com", "adsfs.oppomobile.com",
            "adx.ads.oppomobile.com", "analytics-api.samsunghealthcn.com", "api.ad.xiaomi.com",
            "bdapi-ads.realmemobile.com", "bdapi-in-ads.realmemobile.com", "bingads.microsoft.com", "business-api.tiktok.com",
            "ck.ads.oppomobile.com", "click.oneplus.cn", "data.ads.oppomobile.com",
            "data.mistat.india.xiaomi.com", "data.mistat.rus.xiaomi.com", "data.mistat.xiaomi.com", "grs.hicloud.com", "iot-eu-logser.realme.com",
            "iot-logser.realme.com", "log.byteoversea.com", "logbak.hicloud.com", "logservice.hicloud.com", "logservice1.hicloud.com",
            "metrics.data.hicloud.com", "metrics2.data.hicloud.com", "mon.byteoversea.com", "samsung-com.112.2o7.net",
            "sdkconfig.ad.intl.xiaomi.com", "sdkconfig.ad.xiaomi.com", "settings-win.data.microsoft.com", "smartclip.com", "smartclip.net",
            "telemetry.microsoft.com", "tracking.rus.miui.com", "unityads.unity3d.com", "us.ibs.lgappstv.com", "vortex-win.data.microsoft.com",
            "webview.unityads.unity3d.com"
        ]),
        ("Ad scripts", [
            "ads.pubmatic.com/AdServer/js/showad.js", "an.yandex.ru/system/context.js", "analytics.tiktok.com/i18n/pixel/events.js",
            "bat.bing.com/bat.js", "c.amazon-adsystem.com/aax2/apstag.js", "cdn.branch.io/branch-latest.min.js",
            "cdn.mxpnl.com/libs/mixpanel-2-latest.min.js", "cdn.segment.com/analytics.js/v1/x/analytics.min.js", "cdn.taboola.com/libtrc/loader.js",
            "connect.facebook.net/en_US/fbevents.js", "d2wy8f7a9ursnm.cloudfront.net/v4/bugsnag.min.js", "js.adsrvr.org/up_loader.1.1.0.js",
            "js.sentry-cdn.com/98eefed2636036c3bdb8377b11ff28fe.min.js", "mc.yandex.ru/metrika/tag.js",
            "pagead2.googlesyndication.com/pagead/js/adsbygoogle.js", "pagead2.googlesyndication.com/pagead/show_ads.js",
            "pixel.quantserve.com/pixel", "sb.scorecardresearch.com/beacon.js", "securepubads.g.doubleclick.net/gampad/ads",
            "snap.licdn.com/li.lms-analytics/insight.min.js", "static.ads-twitter.com/uwt.js", "static.criteo.net/js/ld/ld.js",
            "static.hotjar.com/c/hotjar-1639117.js", "widgets.outbrain.com/outbrain.js", "www.google-analytics.com/analytics.js",
            "www.googleadservices.com/pagead/conversion.js", "www.googletagmanager.com/gtm.js", "www.googletagservices.com/tag/js/gpt.js"
        ]),
    ]
}

/// Light, Balanced or Strict: one choice that switches the right filter lists on and the rest off. Used on the Adblock screen, in
/// Filtering Settings and in the Adblock Test, so the lists themselves never need to be shown to pick a level.
struct VSFilterModePicker: View {
    @ObservedObject var filtering: FilteringController
    /// Called once every queued change has been applied.
    var onFinished: (() -> Void)? = nil
    /// Each level is a complete set of lists, so a higher level always blocks everything the lower one does, and more.
    enum Mode: String, CaseIterable, Identifiable {
        case light = "Light", balanced = "Balanced", strict = "Strict"
        var id: String { rawValue }
        var lists: Set<String> {
            let light: Set<String> = ["HaGeZi Light", "Peter Lowe’s ad servers"]
            // Balanced blocks ads, malware and miners: HaGeZi's everyday Multi list, EasyList, and uBlock Origin's badware list, plus cookie banners.
            // Strict adds everything about privacy: HaGeZi's aggressive Pro++ in place of Multi (it already contains the device-telemetry lists, so
            // those are not repeated), EasyPrivacy, scams and annoyances. A list whose rules the others already hold is left out.
            let balanced: Set<String> = ["HaGeZi Multi", "EasyList", "Peter Lowe’s ad servers", "Anti-Malware (DandelionSprout)", "uBlock badware risks", "NoCoin (cryptojacking)", "Cookie notices (Fanboy)"]
            let strict: Set<String> = balanced.subtracting(["HaGeZi Multi"]).union(["HaGeZi Pro++", "EasyPrivacy", "Dan Pollock’s hosts", "Smart TV tracking", "Fanboy Annoyances", "Fanboy Social", "Scams (Blocklist Project)", "Ransomware (Blocklist Project)", "Scam blocklist (DurableNapkin)", "Crypto miners & scams (Blocklist Project)"])
            switch self { case .light: return light; case .balanced: return balanced; case .strict: return strict }
        }
        var blurb: String {
            switch self {
            case .light: return "Core ads and trackers. Fewest broken sites."
            case .balanced: return "Recommended. Ads, malware, miners and cookie banners."
            case .strict: return "Maximum. Adds trackers, telemetry, scams, popups and social widgets. A few sites may break."
            }
        }
        /// What the user should know before switching to this level; nil when there is nothing to warn about.
        var warning: String? {
            switch self {
            case .light: return nil
            case .balanced: return "⚠️ Balanced downloads about \(lists.count) lists and puts roughly 200,000 rules into Safari. A page may look different or, rarely, stop working. If that happens, add the site under Website Exceptions. The first rebuild takes a few seconds and uses mobile data if you are not on Wi-Fi."
            case .strict: return "⚠️ Strict is the most aggressive level: \(lists.count) lists and roughly 290,000 rules in Safari, including trackers, telemetry, popups and social widgets. Some sites, logins and embedded videos may stop working, and Safari can be slower to start after a rebuild. Use Website Exceptions for any site that breaks. The download is large; Wi-Fi is recommended."
            }
        }
        /// Every list any level or General switch can turn on; lists outside this set are never touched by a level.
        static var managed: Set<String> { Set(Mode.allCases.flatMap(\.lists)).union(generalFeatures.flatMap(\.lists)).union(["EasyList (domains)", "EasyPrivacy (domains)", "Social media (StevenBlack)", "HaGeZi Pro", "OISD Big", "HaGeZi Multi"]) }
    }
    /// What was tapped, shown at once until every queued change has finished.
    @State private var requested: Mode?
    @State private var pending = 0
    /// A level waiting for the user's confirmation after a warning.
    @State private var confirming: Mode?
    /// The mode whose lists match what is on right now, if any.
    static func detect(_ config: FilterConfiguration) -> Mode? {
        let on = Set(Mode.managed.filter { name in config.subscriptions.contains { $0.enabled && FilterCatalog.entry(forURL: $0.url)?.name == name } })
        return Mode.allCases.first { $0.lists == on }
    }
    static func name(_ config: FilterConfiguration) -> String { detect(config)?.rawValue ?? "Custom" }
    private var current: Mode? { Self.detect(filtering.configuration) }
    private func apply(_ mode: Mode) {
        requested = mode; pending += 1
        Task {
            await filtering.applyLists(on: mode.lists, managed: Mode.managed)
            pending -= 1; if pending <= 0 { pending = 0; requested = nil; onFinished?() }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Filtering mode", selection: Binding<Mode?>(get: { requested ?? current }, set: { value in
                guard let value, value != (requested ?? current) else { return }
                if value.warning != nil { confirming = value } else { apply(value) }
            })) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag(Optional($0)) }
            }.pickerStyle(.segmented)
            .vsConfirm(isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), title: "Switch to \(confirming?.rawValue ?? "")?", message: confirming?.warning ?? "", confirm: "Switch", destructive: true, icon: "exclamationmark.triangle.fill") { if let mode = confirming { apply(mode) }; confirming = nil }
            Group {
                if !filtering.operationStatus.isEmpty { Text(filtering.operationStatus).foregroundStyle(VSDesign.accent) }
                else { Text((requested ?? current)?.blurb ?? "Custom: your own mix of lists.").foregroundStyle(.secondary) }
            }.font(.caption).fixedSize(horizontal: false, vertical: true)
        }
    }
}
