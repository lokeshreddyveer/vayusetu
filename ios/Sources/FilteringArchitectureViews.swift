import SwiftUI
import UniformTypeIdentifiers
import VayuSetuCore

private let filterBorder = VSDesign.separator
private let filterGreen = Color.green
private let filterAmber = Color.orange

struct VSFilterListsScreen: View {
    @ObservedObject var filtering: FilteringController
    @State private var search = ""
    @State private var adding = false
    @State private var importing = false
    @State private var removing: UUID?
    @State private var detailID: UUID?
    /// A list switch moves the moment it is tapped; enabling one may download it first, which takes seconds.
    @State private var optimistic: [UUID: Bool] = [:]
    private func setEnabled(_ id: UUID, _ value: Bool) {
        optimistic[id] = value
        Task { await filtering.setList(id, enabled: value); optimistic[id] = nil }
    }
    private var subscriptions: [FilterSubscription] { filtering.configuration.subscriptions }
    private var visible: [FilterSubscription] { subscriptions.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) } }
    private var onLists: [FilterSubscription] { visible.filter(\.enabled) }
    private var offLists: [FilterSubscription] { visible.filter { !$0.enabled } }
    private var totalRules: Int { filtering.configuration.uniqueRules ?? filtering.configuration.effective.count }
    private var hasDownloadable: Bool { subscriptions.contains { $0.enabled && $0.url != "Local file" } }
    private var lastUpdate: Date? { subscriptions.filter(\.enabled).compactMap(\.updated).max() }
    private func compact(_ n: Int) -> String { n >= 1000 ? String(format: "%.0fk", Double(n) / 1000) : String(n) }
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                summaryCard
                if !onLists.isEmpty { listCard("On · \(onLists.count)", onLists) }
                if !offLists.isEmpty || onLists.isEmpty { listCard(onLists.isEmpty ? "Your lists" : "Off · \(offLists.count)", offLists, empty: subscriptions.isEmpty ? "No lists yet. Browse the catalogue to add some." : visible.isEmpty ? "No lists match your search." : nil) }
                addCard
                if !filtering.message.isEmpty { Text(filtering.message).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4) }
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 40)
        }.scrollIndicators(.hidden).background(VSDesign.background)
        .vsHeader("Filter Lists").searchable(text: $search, prompt: "Search lists")
        .navigationDestination(item: $detailID) { VSFilterListDetailsScreen(filtering: filtering, id: $0) }
        .sheet(isPresented: $adding) { NavigationStack { VSListEditor(filtering: filtering) }.vsSheetChrome() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text]) { result in
            do {
                let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try LocalFiles.read(url, maximum: FilterParser.byteLimit)
                Task { await filtering.importList(data, name: url.deletingPathExtension().lastPathComponent) }
            } catch { filtering.report(error.localizedDescription) }
        }
        .vsConfirm(isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), title: "Remove this list?", message: "Its downloaded rules are deleted. You can add it again from the catalogue.", confirm: "Remove", destructive: true, icon: "trash.fill") { if let id = removing { Task { await filtering.removeList(id) } }; removing = nil }
    }

    // MARK: Summary: three small tiles, usage bar, one compact action
    private var summaryCard: some View {
        let limit = FilterParser.combinedLimit
        let fraction = min(1, Double(totalRules) / Double(limit))
        let onCount = subscriptions.filter(\.enabled).count
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                VSStatTile(icon: "checklist", title: "Lists on", value: "\(onCount) of \(subscriptions.count)", tint: onCount > 0 ? filterGreen : .secondary)
                VSStatTile(icon: "number", title: "Rules", value: totalRules == 0 ? "None" : compact(totalRules), tint: fraction > 0.8 ? filterAmber : totalRules > 0 ? filterGreen : .secondary)
                VSStatTile(icon: "clock", title: "Updated", value: lastUpdate.map { $0.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)) } ?? "Never", tint: lastUpdate == nil ? filterAmber : VSDesign.accent)
            }.fixedSize(horizontal: false, vertical: true).frame(minHeight: 84)
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: fraction).tint(fraction > 0.8 ? filterAmber : VSDesign.accent)
                Text("\(totalRules.formatted()) of \(limit.formatted()) rules the phone will hold. Used by VayuSetu DNS and by Safari adblocking.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if totalRules > SafariRuleCompiler.fitBudget * 6 && filtering.configuration.safariDesired {
                Label("Safari takes about \((SafariRuleCompiler.fitBudget * 6).formatted()) of these across its six extensions. DNS filtering uses everything.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(filterAmber).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button { Task { await filtering.updateSelectedLists() } } label: {
                    HStack(spacing: 6) { if filtering.busy { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .bold)) }; Text(filtering.busy ? "Working…" : "Update all") }
                }.buttonStyle(VSCompactButtonStyle(prominent: true)).disabled(filtering.busy || !hasDownloadable)
            }
        }.vsCard()
    }

    // MARK: List cards
    private func listCard(_ title: String, _ lists: [FilterSubscription], empty: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).tracking(1).foregroundStyle(.secondary).padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(Array(lists.enumerated()), id: \.element.id) { index, list in
                    row(list)
                    if index < lists.count - 1 { Divider().overlay(filterBorder) }
                }
                if let empty { Text(empty).font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8) }
            }.vsCard(radius: 12, padding: 12)
        }
    }
    private func downloaded(_ list: FilterSubscription) -> Bool { !list.rules.isEmpty }
    private func subtitle(_ list: FilterSubscription) -> String {
        if downloaded(list) { return "\(list.rules.count.formatted()) rules" + (list.updated.map { " · updated " + $0.formatted(.relative(presentation: .named)) } ?? "") }
        if list.url == "Local file" { return "Imported file" }
        return "Not downloaded" + (FilterCatalog.entry(forURL: list.url).map { " · " + $0.sizeLabel } ?? "")
    }
    private func row(_ list: FilterSubscription) -> some View {
        let working = filtering.activeListID == list.id
        return HStack(spacing: 8) {
            Button { detailID = list.id } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(list.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.leading)
                    Text(subtitle(list)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(VSPlainButtonStyle())
            if working { ProgressView().controlSize(.small).frame(width: 44) }
            else if !downloaded(list) && list.url != "Local file" {
                Button { Task { await filtering.updateList(list.id) } } label: { Label("Get", systemImage: "arrow.down.circle").labelStyle(.titleAndIcon) }
                    .buttonStyle(VSCompactButtonStyle()).disabled(filtering.busy).accessibilityLabel("Download \(list.name)")
            }
            Toggle("Use \(list.name)", isOn: Binding(get: { optimistic[list.id] ?? list.enabled }, set: { setEnabled(list.id, $0) })).labelsHidden().disabled(filtering.busy && optimistic[list.id] == nil)
            Menu {
                Button("Details", systemImage: "info.circle") { detailID = list.id }
                if list.url != "Local file" { Button(downloaded(list) ? "Update now" : "Download", systemImage: "arrow.down.circle") { Task { await filtering.updateList(list.id) } }.disabled(filtering.busy) }
                Button("Remove", systemImage: "trash", role: .destructive) { removing = list.id }.disabled(filtering.busy)
            } label: { Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold)).foregroundStyle(.secondary).frame(width: 32, height: 44).contentShape(Rectangle()) }
                .accessibilityLabel("Actions for \(list.name)")
        }
    }

    // MARK: Add more
    private func addRow(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 1) { Text(title).font(.subheadline.weight(.semibold)); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }.frame(minHeight: 48).contentShape(Rectangle())
    }
    private var addCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ADD MORE").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(.secondary).padding(.horizontal, 4)
            VStack(spacing: 0) {
                NavigationLink { VSFilterCatalogScreen(filtering: filtering) } label: { addRow("square.grid.2x2", "Browse the catalogue", "\(FilterCatalog.all.count) popular lists by category") }.buttonStyle(VSPlainButtonStyle())
                Divider().overlay(filterBorder)
                Button { adding = true } label: { addRow("link", "Add from a URL", "Any HTTPS list in hosts or domain format") }.buttonStyle(VSPlainButtonStyle()).disabled(filtering.busy)
                Divider().overlay(filterBorder)
                Button { importing = true } label: { addRow("doc.badge.plus", "Import a file", "A list saved on this device") }.buttonStyle(VSPlainButtonStyle()).disabled(filtering.busy)
                Divider().overlay(filterBorder)
                NavigationLink { VSFilterHealthScreen(filtering: filtering) } label: { addRow("waveform.path.ecg", "Filter health", "Compile, reload and budget details") }.buttonStyle(VSPlainButtonStyle())
            }.vsCard(radius: 12, padding: 12)
        }
    }
}

struct VSFilterCatalogScreen: View {
    @ObservedObject var filtering: FilteringController
    @State private var search = ""
    private func existing(_ entry: CatalogList) -> FilterSubscription? { filtering.configuration.subscriptions.first { $0.url == entry.url } }
    private func matches(_ entry: CatalogList) -> Bool { search.isEmpty || entry.name.localizedCaseInsensitiveContains(search) || entry.summary.localizedCaseInsensitiveContains(search) }
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ForEach(FilterCatalog.grouped(), id: \.0) { category, all in
                    let entries = all.filter(matches)
                    if !entries.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(category.rawValue.uppercased()).font(.caption.weight(.semibold)).tracking(1).foregroundStyle(.secondary).padding(.horizontal, 4)
                            VStack(spacing: 0) {
                                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                    entryRow(entry)
                                    if index < entries.count - 1 { Divider().overlay(filterBorder) }
                                }
                            }.vsCard(radius: 12, padding: 12)
                        }
                    }
                }
                Text("Lists are public and maintained by their authors. VayuSetu downloads them straight from the author’s host and checks size and format before use. Very large lists are not offered because a phone cannot hold them.").font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 40)
        }.scrollIndicators(.hidden).background(VSDesign.background)
        .vsHeader("Catalogue").searchable(text: $search, prompt: "Search the catalogue")
    }
    private func entryRow(_ entry: CatalogList) -> some View {
        let present = existing(entry)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text(entry.sizeLabel + " · " + entry.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let present {
                Label(present.enabled ? "On" : "Added", systemImage: "checkmark.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(present.enabled ? filterGreen : .secondary)
            } else {
                Menu {
                    Button("Add and turn on", systemImage: "arrow.down.circle") { Task { await filtering.addCatalogList(entry, enable: true) } }
                    Button("Add only", systemImage: "plus") { Task { await filtering.addCatalogList(entry, enable: false) } }
                } label: { Text("Add") }.buttonStyle(VSCompactButtonStyle()).disabled(filtering.busy)
            }
        }.frame(minHeight: 52)
    }
}
struct VSFilterListDetailsScreen: View {
    @ObservedObject var filtering: FilteringController
    let id: UUID
    @State private var removing = false
    @State private var optimisticEnabled: Bool?
    @Environment(\.dismiss) private var dismiss
    var list: FilterSubscription? { filtering.configuration.subscriptions.first { $0.id == id } }
    var body: some View {
        VSCardList {
            if let list {
                let working = filtering.activeListID == id
                VSSection(list.name) {
                    Toggle("Use this list", isOn: Binding(get: { optimisticEnabled ?? list.enabled }, set: { value in optimisticEnabled = value; Task { await filtering.setList(id, enabled: value); optimisticEnabled = nil } })).disabled(filtering.busy && optimisticEnabled == nil).frame(minHeight: 26)
                    if list.url != "Local file" {
                        Button { Task { await filtering.updateList(id) } } label: {
                            HStack { if working { ProgressView().controlSize(.small) } else { Image(systemName: list.rules.isEmpty ? "arrow.down.circle" : "arrow.clockwise") }
                                Text(working ? "Working…" : list.rules.isEmpty ? "Download" : "Update now") }.frame(minHeight: 26)
                        }.disabled(filtering.busy)
                    }
                }
                VSSection("Status") {
                    VSRow(title: "Rules", value: list.rules.isEmpty ? "Not downloaded" : list.rules.count.formatted())
                    VSRow(title: "Unsupported entries", value: String(list.rejected))
                    VSRow(title: "Last update", value: list.updated?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                    VSRow(title: "Used by", value: "VayuSetu DNS and Safari")
                    if let entry = FilterCatalog.entry(forURL: list.url) { VSRow(title: "Category", value: entry.category.rawValue); Text(entry.summary).font(.footnote).foregroundStyle(.secondary) }
                    Text(list.rules.isEmpty ? "No downloaded rules yet. Use Download or turn the list on." : "Selection, Safari enablement and DNS use are separate from measured rule effectiveness.").font(.footnote).foregroundStyle(.secondary)
                }
                VSSection("Source & integrity") {
                    Text(list.url).font(.footnote).textSelection(.enabled)
                    if !list.checksum.isEmpty { Text("SHA-256: " + list.checksum).font(.caption.monospaced()).textSelection(.enabled) }
                }
                VSSection { Button("Remove list", role: .destructive) { removing = true }.disabled(filtering.busy).frame(minHeight: 26) } footer: { Text("Removing deletes the downloaded rules. Catalogue lists can be added again.") }
            } else { ContentUnavailableView("List removed", systemImage: "line.3.horizontal.decrease") }
        }.vsList().vsHeader("List Details")
            .vsConfirm(isPresented: $removing, title: "Remove this list?", message: "Its downloaded rules are deleted. You can add it again from the catalogue.", confirm: "Remove", destructive: true, icon: "trash.fill") { Task { await filtering.removeList(id); dismiss() } }
    }
}
struct VSFilterHealthScreen: View {
    @ObservedObject var filtering: FilteringController
    private var input: FilterHealthInput {
        let c = filtering.configuration
        let needed = filtering.neededExtensions
        let enabled = needed.filter { filtering.extensionStates[$0]?.enabled == true }.count
        let loaded = needed.filter { filtering.extensionStates[$0]?.reloaded == true }.count
        return FilterHealthInput(
            lists: c.subscriptions.map { FilterHealthInput.List(name: $0.name, enabled: $0.enabled, domainRules: $0.rules.count, pageRules: $0.content?.count ?? 0, unsupportedLines: $0.rejected + ($0.content?.unsupported ?? 0), updated: $0.updated) },
            safariOn: c.safariDesired, extensionsNeeded: (c.safariExtensionRules ?? [:]).values.filter { $0 > 0 }.count, extensionsEnabled: enabled, extensionsLoaded: loaded,
            safariApplied: c.safariApplied ?? 0, safariCandidates: c.safariCandidates ?? 0, uniqueRules: c.uniqueRules ?? c.effective.count, ruleLimit: FilterParser.combinedLimit,
            lastFailure: filtering.failureDetails, now: Date())
    }
    private func tint(_ s: HealthIssue.Severity) -> Color { s == .problem ? .red : s == .warning ? .orange : .secondary }
    private func icon(_ s: HealthIssue.Severity) -> String { s == .problem ? "xmark.octagon.fill" : s == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill" }
    var body: some View {
        let issues = FilterHealthModel.issues(input)
        let level = FilterHealthModel.level(issues)
        let enabledLists = filtering.configuration.subscriptions.filter(\.enabled)
        ScrollView {
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: level == .healthy ? "checkmark.seal.fill" : level == .attention ? "exclamationmark.triangle.fill" : "xmark.octagon.fill").font(.title2).foregroundStyle(level == .healthy ? Color.green : level == .attention ? Color.orange : Color.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(level.rawValue).font(.headline)
                            Text(issues.isEmpty ? "Nothing needs your attention." : "\(issues.count) thing\(issues.count == 1 ? "" : "s") to look at.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    ForEach(issues) { issue in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: icon(issue.severity)).font(.footnote).foregroundStyle(tint(issue.severity)).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) { Text(issue.title).font(.subheadline.weight(.medium)); Text(issue.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        }
                    }
                }.vsCard()

                HStack(spacing: 10) {
                    Button { Task { await filtering.updateSelectedLists() } } label: { Label("Update Lists", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity, minHeight: 40) }
                        .buttonStyle(.borderedProminent).vsTapHaptic().disabled(filtering.busy || enabledLists.isEmpty)
                    Button { Task { await filtering.reload(); await filtering.refresh() } } label: { Label("Rebuild Safari", systemImage: "hammer").frame(maxWidth: .infinity, minHeight: 40) }
                        .buttonStyle(.bordered).vsTapHaptic().disabled(filtering.busy)
                }.font(.subheadline.weight(.semibold))
                if filtering.busy || !filtering.operationStatus.isEmpty { HStack(spacing: 8) { ProgressView(); Text(filtering.operationStatus.isEmpty ? "Working…" : filtering.operationStatus).font(.footnote).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading) }

                VStack(alignment: .leading, spacing: 0) {
                    Text("Lists that are on").font(.subheadline.weight(.semibold)).padding(.bottom, 6)
                    if enabledLists.isEmpty { Text("No lists are on.").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8) }
                    ForEach(Array(enabledLists.enumerated()), id: \.element.id) { index, list in
                        if index > 0 { Divider().overlay(VSDesign.separator) }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack { Text(list.name).font(.subheadline.weight(.medium)); Spacer(); Text(list.updated.map { $0.formatted(.relative(presentation: .named)) } ?? "Never").font(.caption).foregroundStyle(.secondary) }
                            Text(detail(list)).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 8)
                    }
                }.vsCard()

                if !filtering.message.isEmpty { VStack(alignment: .leading, spacing: 4) { Text("Last operation").font(.subheadline.weight(.semibold)); Text(filtering.message).font(.footnote).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).vsCard() }
                NavigationLink { VSSafariScreen(filtering: filtering) } label: {
                    HStack { Text("Safari extension details").font(.subheadline.weight(.semibold)); Spacer(); Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }.frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(VSPlainButtonStyle()).vsCard()
            }.padding(.horizontal, 16).padding(.bottom, 110)
        }.vsHeader("Filter Health", "Are your lists downloaded, current and loaded?").scrollIndicators(.hidden).background(VSDesign.background).vsInlineTitle().task { await filtering.refresh() }
    }
    private func detail(_ list: FilterSubscription) -> String {
        var parts = ["\(list.rules.count.formatted()) domain rules"]
        if let page = list.content?.count, page > 0 { parts.append("\(page.formatted()) page rules") }
        let skipped = list.rejected + (list.content?.unsupported ?? 0)
        if skipped > 0 { parts.append("\(skipped.formatted()) lines skipped (rules VayuSetu cannot apply)") }
        return parts.joined(separator: " · ")
    }
}
struct VSCustomRulesScreen: View {
    @ObservedObject var filtering: FilteringController
    @State private var search = ""
    @State private var action = "All"
    @State private var editor = false
    @State private var edited: FilterRule?
    @State private var removing: String?
    @State private var exporting = false
    @State private var importing = false
    @State private var document = EncryptedBackupDocument()
    @State private var notice = ""
    var rules: [FilterRule] { filtering.configuration.rules.filter { (search.isEmpty || $0.domain.localizedCaseInsensitiveContains(search)) && (action == "All" || $0.action.rawValue == action) } }
    var body: some View {
        VSCardList {
            VSSection { Picker("Action", selection: $action) { Text("All").tag("All"); Text("Allow").tag("allow"); Text("Block").tag("block") }.pickerStyle(.segmented) }
            VSSection {
                ForEach(rules) { rule in
                    Button { edited = rule; editor = true } label: { VSRow(title: rule.domain, subtitle: rule.action.rawValue.capitalized + " · " + rule.scope.label + " · Safari and DNS", value: rule.enabled == false ? "Off" : "Enabled", chevron: true) }.buttonStyle(VSPlainButtonStyle()).disabled(filtering.busy)
                        .contextMenu { Button("Delete", systemImage: "trash", role: .destructive) { removing = rule.id }.disabled(filtering.busy) }
                }
                if rules.isEmpty { ContentUnavailableView("No Matching Rules", systemImage: "line.3.horizontal.decrease", description: Text("Add a domain allow or block rule. Nothing is enabled automatically.")) }
                Button("Add Rule") { edited = nil; editor = true }.disabled(filtering.busy)
            }
            if !notice.isEmpty { VSSection { Text(notice).font(.footnote).foregroundStyle(.orange) } }
            VSSection { VSNavLink { VSRuleMatchScreen(filtering: filtering) } label: { Text("Test Rule Match") }; Button("Import Rules JSON") { importing = true }.disabled(filtering.busy); Button("Export Rules JSON") { document = EncryptedBackupDocument(data: filtering.exportedRules); exporting = true } }
        }.vsList().vsHeader("Custom Rules").searchable(text: $search, prompt: "Search domains")
        .sheet(isPresented: $editor) { NavigationStack { VSRuleEditor(filtering: filtering, rule: edited) }.vsSheetChrome() }
        .vsConfirm(isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), title: "Delete this rule?", message: "The rule stops applying right away.", confirm: "Delete", destructive: true, icon: "trash.fill") { if let id = removing { Task { await filtering.removeRule(id) } }; removing = nil }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "VayuSetu-rules.json") { result in
            if case .failure(let error) = result { notice = "Rule export failed: " + error.localizedDescription }
            document = EncryptedBackupDocument()
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do { let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }; let data = try LocalFiles.read(url, maximum: FilterParser.byteLimit); Task { await filtering.importRules(data) } }
            catch { notice = error.localizedDescription }
        }
    }
}
struct VSRuleMatchScreen: View {
    @ObservedObject var filtering: FilteringController
    @State private var input = ""
    @State private var result: FilteringController.WebsiteCheck?
    @State private var checking = false
    private func run() {
        guard !checking else { return }
        checking = true; result = nil
        Task { result = await filtering.checkWebsite(input); checking = false }
    }
    private func row(_ title: String, _ icon: String, _ verdict: FilteringController.WebsiteCheck.Verdict) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(.secondary).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(verdict.title).font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 2)
                        .background((verdict.blocked == true ? Color.green : verdict.blocked == false ? Color.secondary : Color.orange).opacity(0.18), in: Capsule())
                        .foregroundStyle(verdict.blocked == true ? Color.green : verdict.blocked == false ? Color.secondary : Color.orange)
                }
                Text(verdict.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        TextField("example.com or a full address", text: $input).vsInput().vsURLKeyboard().submitLabel(.go).onSubmit(run)
                            .padding(.horizontal, 12).frame(minHeight: 40).background(VSDesign.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        Button(action: run) { if checking { ProgressView() } else { Text("Check") } }.buttonStyle(VSCompactButtonStyle(prominent: true)).disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || checking)
                    }
                    Text("Safari: checked against the rules Safari actually received, then by loading the site with and without them. DNS: checked against the compiled DNS filter.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.vsCard()

                if let result {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(result.host).font(.headline)
                        row("Safari", "safari", result.safari)
                        Divider().overlay(VSDesign.separator)
                        row("DNS filtering", "network", result.dns)
                    }.vsCard()
                } else if checking {
                    HStack(spacing: 8) { ProgressView(); Text("Checking…").font(.footnote).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading)
                } else if !filtering.message.isEmpty {
                    Text(filtering.message).font(.footnote).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                }
                NavigationLink { VSWebsiteExceptionsScreen(filtering: filtering) } label: {
                    HStack { Text("Site not working? Add a website exception").font(.subheadline.weight(.semibold)); Spacer(); Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }.frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(VSPlainButtonStyle()).vsCard()
            }.padding(.horizontal, 16).padding(.bottom, 110)
        }.vsHeader("Test a Website", "Would VayuSetu block it, and which rule does?").scrollIndicators(.hidden).background(VSDesign.background).vsInlineTitle()
    }
}
struct VSAdblockStatisticsScreen: View {
    @ObservedObject var filtering: FilteringController
    var body: some View {
        VSCardList { VSSection("Configuration counts") { VSRow(title: "Surface", value: "Safari"); VSRow(title: "Selected lists", value: String(filtering.configuration.subscriptions.filter(\.enabled).count)); VSRow(title: "Enabled rules", value: String(filtering.configuration.effective.count)); VSRow(title: "Latest reload", value: filtering.lastReload?.formatted() ?? "Unavailable") }
            VSSection("Enforcement statistics") { VSRow(title: "Safari blocked requests", value: "Unavailable"); VSRow(title: "Per-domain DNS counts", value: "Unavailable"); Text("Safari’s declarative content blocker does not expose per-request counters. Local DNS interception is unavailable. Configuration counts above are not blocked-request counts.").font(.footnote).foregroundStyle(.secondary) }
        }.vsList().vsHeader("Available Statistics")
    }
}
