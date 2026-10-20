import AppKit
import Charts
import CryptoKit
import NetworkExtension
import SwiftUI

/// The app's side of the network filter: switches it on, talks to the extension, and holds what the Network page shows.
@MainActor final class FilterClient: ObservableObject {
    enum Status: Equatable { case unavailable, off, starting, needsApproval, running, unreachable }
    @Published private(set) var status = Status.off
    @Published private(set) var flows: [FlowRecord] = []
    @Published private(set) var rules: [NetRule] = []
    @Published private(set) var settings = FilterSettings()
    @Published private(set) var pending: [PendingQuestion] = []
    @Published private(set) var lists: [NetList] = []
    @Published private(set) var usage = FilterUsage()
    @Published private(set) var audit: [FilterAuditRecord] = []
    @Published private(set) var profiles: [FilterProfile] = []
    @Published private(set) var activeProfile: String?
    @Published private(set) var refreshing = Set<UUID>()
    @Published var message = ""
    private var ticks = 0
    private var connection: NSXPCConnection?
    private var task: Task<Void, Never>?
    private var lastID: Int64 = 0
    private var wanted = false
    /// NSXPC callbacks are not guaranteed to arrive if a system extension is
    /// restarting. A bounded call prevents the Network page from hanging forever
    /// and lets the next poll recreate the connection.
    private let xpcTimeout: TimeInterval = 5
    static let maximumShown = 1500

    var supported: Bool { ExtensionManager.filterBundled }
    var auditChainValid: Bool {
        var previous: String?
        for event in audit {
            guard event.previousHash == previous, event.verifies() else { return false }
            previous = event.hash
        }
        return true
    }

    // MARK: Switching on and off
    func refreshState() async {
        guard supported else { status = .unavailable; return }
        let manager = NEFilterManager.shared()
        try? await manager.loadFromPreferences()
        wanted = manager.isEnabled
        if !manager.isEnabled { status = .off; return }
        await poll(first: true)
    }
    func setEnabled(_ on: Bool, extensions: ExtensionManager) {
        guard supported else { status = .unavailable; return }
        if on {
            status = .starting; message = ""
            extensions.activateFilter { [weak self] in Task { await self?.configure(true) } }
        } else { Task { await configure(false) } }
    }
    private func configure(_ on: Bool) async {
        let manager = NEFilterManager.shared()
        do {
            try await manager.loadFromPreferences()
            if manager.providerConfiguration == nil {
                let configuration = NEFilterProviderConfiguration()
                configuration.filterSockets = true; configuration.filterPackets = false
                manager.providerConfiguration = configuration
            }
            manager.localizedDescription = "VayuSetu Network Filter"
            manager.isEnabled = on
            try await manager.saveToPreferences()
            wanted = on
            if on { status = .starting; await poll(first: true) } else { status = .off; disconnect() }
        } catch {
            message = on ? "The network filter could not be turned on: \(error.localizedDescription)" : error.localizedDescription
            status = on ? .needsApproval : .off
        }
    }

    // MARK: Talking to the extension
    private func proxy(_ onError: @escaping (Error) -> Void) -> VayuFilterXPC? {
        if connection == nil {
            let c = NSXPCConnection(machServiceName: FilterNames.machService, options: [])
            c.remoteObjectInterface = NSXPCInterface(with: VayuFilterXPC.self)
            c.invalidationHandler = { [weak self] in Task { @MainActor in self?.connection = nil } }
            c.resume(); connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler(onError) as? VayuFilterXPC
    }
    private func disconnect() { connection?.invalidate(); connection = nil }
    private final class Once { private let lock = NSLock(); private var done = false; func first() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true } }
    private func ask(_ call: @escaping (VayuFilterXPC, @escaping (Data) -> Void) -> Void) async -> Data? {
        await withCheckedContinuation { continuation in
            let once = Once()
            guard let proxy = proxy({ _ in if once.first() { continuation.resume(returning: nil) } }) else { continuation.resume(returning: nil); return }
            call(proxy) { data in if once.first() { continuation.resume(returning: data) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + xpcTimeout) { [weak self] in
                if once.first() { self?.disconnect(); continuation.resume(returning: nil) }
            }
        }
    }
    private func tell(_ call: @escaping (VayuFilterXPC, @escaping (Bool) -> Void) -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            let once = Once()
            guard let proxy = proxy({ _ in if once.first() { continuation.resume(returning: false) } }) else { continuation.resume(returning: false); return }
            call(proxy) { ok in if once.first() { continuation.resume(returning: ok) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + xpcTimeout) { [weak self] in
                if once.first() { self?.disconnect(); continuation.resume(returning: false) }
            }
        }
    }

    func poll(first: Bool = false) async {
        guard wanted else { return }
        let after = lastID
        guard let data = await ask({ $0.recentFlows(after: after, reply: $1) }), let new = try? JSONDecoder().decode([FlowRecord].self, from: data) else {
            if status != .off { status = first ? .needsApproval : .unreachable }
            return
        }
        status = .running
        if !new.isEmpty {
            flows.append(contentsOf: new); lastID = new.last?.id ?? lastID
            if flows.count > Self.maximumShown { flows.removeFirst(flows.count - Self.maximumShown) }
        }
        if first {
            if let d = await ask({ $0.rules(reply: $1) }), let r = try? JSONDecoder().decode([NetRule].self, from: d) { rules = r }
            if let d = await ask({ $0.settings(reply: $1) }), let s = try? JSONDecoder().decode(FilterSettings.self, from: d) { settings = s }
            if let d = await ask({ $0.lists(reply: $1) }), let l = try? JSONDecoder().decode([NetList].self, from: d) { lists = l }
            loadProfiles()
        }
        ticks += 1
        if ticks % 5 == 0, let d = await ask({ $0.usage(reply: $1) }), let u = try? JSONDecoder().decode(FilterUsage.self, from: d) { usage = u }
        if first, let d = await ask({ $0.audit(reply: $1) }), let a = try? JSONDecoder().decode([FilterAuditRecord].self, from: d) { audit = a }
        if ticks % 600 == 1 { await refreshDueLists() }
        if let d = await ask({ $0.pending(reply: $1) }), let q = try? JSONDecoder().decode([PendingQuestion].self, from: d) {
            if !q.isEmpty && q.map(\.id) != pending.map(\.id) { NSApplication.shared.dockTile.badgeLabel = "\(q.count)" }
            if q.isEmpty { NSApplication.shared.dockTile.badgeLabel = nil }
            pending = q
        }
    }
    func startPolling() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.refreshState()
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(1)); await self?.poll() }
        }
    }
    func stopPolling() { task?.cancel(); task = nil }

    // MARK: Changing things
    func addRule(_ rule: NetRule) { push(rules + [rule]) }
    func removeRules(_ ids: Set<UUID>) { push(rules.filter { !ids.contains($0.id) }) }
    func setAction(_ id: UUID, _ action: NetAction) { push(rules.map { var r = $0; if r.id == id { r.action = action }; return r }) }
    private func push(_ new: [NetRule]) {
        rules = new
        Task { _ = await tell { proxy, reply in proxy.setRules((try? JSONEncoder().encode(new)) ?? Data("[]".utf8), reply: reply) } }
    }
    func update(settings new: FilterSettings) {
        settings = new
        Task { _ = await tell { proxy, reply in proxy.setSettings((try? JSONEncoder().encode(new)) ?? Data(), reply: reply) } }
    }
    /// An answer with a chosen scope and duration, for example "block this domain for an hour".
    func answer(_ question: PendingQuestion, allow: Bool, scope: AlertScope, lifetime: AlertLifetime) {
        guard let rule = AlertRule.make(for: question, allow: allow, scope: scope, lifetime: lifetime) else { answer(question, allow: allow, remember: false); return }
        pending.removeAll { $0.id == question.id }
        let data = (try? JSONEncoder().encode(rule)) ?? Data()
        Task { _ = await tell { proxy, reply in proxy.answerWithRule(question.id, allow: allow, rule: data, reply: reply) }; await refreshRules() }
    }
    func answer(_ question: PendingQuestion, allow: Bool, remember: Bool) {
        pending.removeAll { $0.id == question.id }
        Task { _ = await tell { proxy, reply in proxy.answer(question.id, allow: allow, remember: remember, reply: reply) }; await refreshRules() }
    }
    private func refreshRules() async { if let d = await ask({ $0.rules(reply: $1) }), let r = try? JSONDecoder().decode([NetRule].self, from: d) { rules = r } }
    func toggleGroup(_ name: String, on: Bool) {
        var s = settings; var off = Set(s.disabledGroups ?? [])
        if on { off.remove(name) } else { off.insert(name) }
        s.disabledGroups = off.isEmpty ? nil : off.sorted(); update(settings: s)
    }
    func removeExpired() { push(rules.filter { $0.expires.map { $0 > Date() } ?? true }) }
    func replaceRules(_ new: [NetRule]) { push(Array(new.prefix(5000))) }
    func clearFlows() { flows = []; Task { _ = await tell { proxy, reply in proxy.clearFlows(reply: reply) } } }

    // MARK: Lists
    private func pushLists(_ new: [NetList]) {
        lists = new
        Task { if !(await tell { proxy, reply in proxy.setLists((try? JSONEncoder().encode(new)) ?? Data("[]".utf8), reply: reply) }) { message = "The filter did not accept the lists. Update the filter extension and try again." } }
    }
    /// A list typed or pasted in (`text`), or one that is fetched from `source` now and then.
    func addList(name: String, kind: NetAction, source: String?, text: String) {
        if let source {
            guard let url = URL(string: source), url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.host != nil else {
                message = "List sources must be valid HTTPS addresses without login credentials."; return
            }
        }
        var list = NetList(name: name, kind: kind, source: source)
        if !text.isEmpty { list.entries = NetListParser.parse(text); list.updated = Date(); list.status = "\(list.entries.count) entries" }
        guard lists.count < 50 else { message = "That is the most lists the filter keeps (50)."; return }
        guard !lists.contains(where: { $0.name == name }) else { message = "A list called \(name) already exists."; return }
        pushLists(lists + [list])
        if source != nil { Task { await refreshList(list.id) } }
    }
    func removeList(_ id: UUID) { pushLists(lists.filter { $0.id != id }) }
    func setListEnabled(_ id: UUID, _ on: Bool) { pushLists(lists.map { var l = $0; if l.id == id { l.enabled = on }; return l }) }
    func setListHours(_ id: UUID, _ hours: Int) { pushLists(lists.map { var l = $0; if l.id == id { l.refreshHours = hours }; return l }) }
    func refreshDueLists() async { for list in lists where list.due { await refreshList(list.id) } }
    /// Fetches a list's source. A failed fetch keeps the entries it had and says what went wrong.
    func refreshList(_ id: UUID) async {
        guard let list = lists.first(where: { $0.id == id }), let text = list.source, let url = URL(string: text), url.scheme == "https" else {
            setStatus(id, "Only https addresses can be refreshed."); return
        }
        refreshing.insert(id); defer { refreshing.remove(id) }
        var request = URLRequest(url: url); request.timeoutInterval = 60
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { setStatus(id, "The server answered \((response as? HTTPURLResponse)?.statusCode ?? 0)."); return }
            guard data.count < 40_000_000 else { setStatus(id, "The list is larger than 40 MB."); return }
            let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if let expected = list.expectedSHA256?.lowercased(), expected != checksum { setStatus(id, "Checksum mismatch; kept the previous list."); return }
            let entries = await Task.detached { NetListParser.parse(String(decoding: data, as: UTF8.self)) }.value
            guard !entries.isEmpty else { setStatus(id, "The list had no usable entries; kept the old one."); return }
            pushLists(lists.map { var l = $0; if l.id == id { l.entries = entries; l.updated = Date(); l.checksum = checksum; l.status = "\(entries.count) entries" }; return l })
        } catch { setStatus(id, "Could not fetch: \(error.localizedDescription)") }
    }
    private func setStatus(_ id: UUID, _ text: String) {
        let updated = lists.map { var l = $0; if l.id == id { l.status = text }; return l }
        pushLists(updated)
    }
    func hits(for rule: NetRule) -> HitCount? { usage.rules[rule.id.uuidString] }
    func hits(for list: NetList) -> HitCount? { usage.lists[list.name] }

    // MARK: Profiles
    private var profilesURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VayuSetuVPN", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("network-profiles.json")
    }
    private func loadProfiles() {
        guard profiles.isEmpty, let data = try? Data(contentsOf: profilesURL), let saved = try? JSONDecoder().decode([FilterProfile].self, from: data) else { return }
        profiles = saved
        activeProfile = UserDefaults.standard.string(forKey: "network-active-profile")
    }
    private func saveProfiles() { try? JSONEncoder().encode(profiles).write(to: profilesURL, options: .atomic) }
    /// Keeps the current rules and settings under a name, replacing an earlier profile of that name.
    func saveProfile(named name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        var profile = FilterProfile(name: clean, rules: rules, settings: settings)
        if let existing = profiles.firstIndex(where: { $0.name.caseInsensitiveCompare(clean) == .orderedSame }) { profile.id = profiles[existing].id; profiles[existing] = profile } else { profiles.append(profile) }
        saveProfiles(); activeProfile = clean; UserDefaults.standard.set(clean, forKey: "network-active-profile")
    }
    @discardableResult func applyProfile(named name: String) -> Bool {
        guard let profile = profiles.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { message = "There is no network profile called \(name)."; return false }
        replaceRules(profile.rules); update(settings: profile.settings)
        activeProfile = profile.name; UserDefaults.standard.set(profile.name, forKey: "network-active-profile")
        return true
    }
    func deleteProfile(_ id: UUID) { profiles.removeAll { $0.id == id }; saveProfiles() }
    func setMode(_ mode: FilterMode) { var s = settings; s.mode = mode; update(settings: s) }

    /// `vayusetu://network/profile/Work` applies a profile; `vayusetu://network/mode/passive` (or `normal`, `blockall`) changes the mode.
    /// This is how scripts and shortcuts control the filter: `open "vayusetu://network/profile/Work"`.
    @discardableResult func handle(url: URL) -> Bool {
        guard url.scheme == "vayusetu", url.host == "network" else { return false }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2 else { return false }
        loadProfiles()
        switch parts[0] {
        case "profile": return applyProfile(named: parts[1])
        case "mode": guard let mode = FilterMode.allCases.first(where: { $0.rawValue.lowercased() == parts[1].lowercased() }) else { return false }; setMode(mode); return true
        default: return false
        }
    }
}

// MARK: - The page
struct MacNetwork: View {
    @ObservedObject var client: FilterClient
    @ObservedObject var extensions: ExtensionManager
    @State private var search = ""
    @State private var paused = false
    @AppStorage("network-hide-local") private var hideLocal = true
    @State private var frozen: [FlowRecord] = []
    @State private var selection = Set<Int64>()
    @State private var view = View_.live
    @State private var newRule = NetRule(app: "*", host: "*", port: "*", action: .block)
    @State private var confirmingBlockAll = false
    @State private var expiry = Expiry.never
    @State private var scheduleOn = false
    @State private var days: Set<Int> = [2, 3, 4, 5, 6]
    @State private var startTime = Calendar.current.date(from: DateComponents(hour: 9, minute: 0)) ?? Date()
    @State private var endTime = Calendar.current.date(from: DateComponents(hour: 17, minute: 0)) ?? Date()
    @State private var importing = false
    @State private var exporting = false
    @State private var exportDocument = NetRulesDocument(rules: [])
    @State private var exportingAudit = false
    @State private var auditDocument = FilterAuditDocument(events: [])
    private enum Expiry: String, CaseIterable, Identifiable {
        case never = "Never", hour = "1 hour", workday = "8 hours", day = "1 day", week = "1 week"; var id: String { rawValue }
        var seconds: TimeInterval? { switch self { case .never: nil; case .hour: 3600; case .workday: 8 * 3600; case .day: 86_400; case .week: 604_800 } }
    }
    private enum View_: String, CaseIterable, Identifiable { case live = "Connections", apps = "By app", traffic = "Traffic", map = "Map", lists = "Lists", rules = "Rules"; var id: String { rawValue } }

    private var shown: [FlowRecord] {
        let source = paused ? frozen : client.flows
        let visible = hideLocal ? source.filter { !Self.isLocalChatter($0) } : source
        let matching = search.isEmpty ? visible : visible.filter { $0.appName.localizedCaseInsensitiveContains(search) || $0.host.localizedCaseInsensitiveContains(search) || $0.app.localizedCaseInsensitiveContains(search) }
        return Array(matching.reversed().prefix(800))
    }
    private var apps: [(app: String, name: String, total: Int, blocked: Int, hosts: Set<String>, last: Date)] {
        var table: [String: (name: String, total: Int, blocked: Int, hosts: Set<String>, last: Date)] = [:]
        for flow in client.flows {
            var row = table[flow.app] ?? (flow.appName, 0, 0, [], flow.time)
            row.total += 1; if flow.verdict == .block { row.blocked += 1 }; row.hosts.insert(flow.host); row.last = max(row.last, flow.time)
            table[flow.app] = row
        }
        return table.map { ($0.key, $0.value.name, $0.value.total, $0.value.blocked, $0.value.hosts, $0.value.last) }.sorted { $0.total > $1.total }
    }
    /// Keep the editor responsive when an imported ruleset or long-running
    /// session contains thousands of entries. The extension still enforces the
    /// complete set; the UI renders a bounded recent slice and offers export.
    private var rulesForDisplay: [NetRule] { Array(client.rules.reversed().prefix(25)) }

    var body: some View {
        MacPage(title: "Network", subtitle: "See which apps connect where, and block what you don't want.") {
            switchPanel
            if !client.pending.isEmpty { questions }
            if client.status == .running || client.status == .unreachable || client.status == .starting { content }
        }
        .onAppear { client.startPolling() }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json, defaultFilename: "VayuSetu-network-rules") { _ in }
        .fileExporter(isPresented: $exportingAudit, document: auditDocument, contentType: .json, defaultFilename: "VayuSetu-network-audit") { _ in }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                guard data.count < 4_000_000 else { client.message = "That rules file is too large."; return }
                let imported = try JSONDecoder().decode([NetRule].self, from: data)
                // Imported rules get new identifiers so they cannot collide with rules you already have.
                client.replaceRules(client.rules + imported.map { var r = $0; r.id = UUID(); return r })
                client.message = "Imported \(imported.count) rule\(imported.count == 1 ? "" : "s")."
            } catch { client.message = "That file is not a VayuSetu rules file." }
        }
        .alert("Block everything by default?", isPresented: $confirmingBlockAll) {
            Button("Block by default", role: .destructive) { var s = client.settings; s.defaultAction = .block; client.update(settings: s) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Any connection that no rule allows will be blocked, including the apps you rely on. Add allow rules first, and you can turn the filter off at the top of this page at any time.") }
    }

    // MARK: Switch
    private var statusChip: MacChip {
        switch client.status {
        case .unavailable: return MacChip(text: "Not in this build", tint: .secondary)
        case .off: return MacChip(text: "Off", tint: .secondary)
        case .starting: return MacChip(text: "Starting…", tint: .orange)
        case .needsApproval: return MacChip(text: "Needs approval", tint: .orange)
        case .running: return MacChip(text: "Running", tint: .green)
        case .unreachable: return MacChip(text: "Not responding", tint: .red)
        }
    }
    private var switchPanel: some View {
        MacPanel("Network filter", icon: "network.badge.shield.half.filled", trailing: { statusChip }) {
            VStack(alignment: .leading, spacing: 12) {
                MacRow(icon: "power", title: "Watch and filter this Mac's connections", detail: "Shows every app that connects, and applies your rules. VayuSetu's own connections and loopback traffic are never filtered.") {
                    Toggle("", isOn: Binding(get: { client.status != .off && client.status != .unavailable }, set: { client.setEnabled($0, extensions: extensions) })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .disabled(!client.supported || extensions.filterRequesting).accessibilityLabel("Network filter")
                }
                if client.status == .unavailable { Text("This build does not include the network filter. It is part of the VayuSetu download from GitHub.").font(.system(size: 12)).foregroundStyle(.secondary) }
                if !extensions.filterMessage.isEmpty { Label(extensions.filterMessage, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(.orange) }
                if !client.message.isEmpty { Label(client.message, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.orange) }
                if client.status == .needsApproval || client.status == .unreachable { Text("The first time, macOS asks you to allow the filter. Approve it in System Settings → General → Login Items & Extensions → Network Extensions, then switch it on again.").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
        }
    }

    // MARK: Questions
    private var questions: some View {
        MacPanel("Waiting for your decision", icon: "questionmark.circle", trailing: { MacChip(text: "\(client.pending.count)", tint: .orange) }) {
            VStack(spacing: 10) {
                ForEach(client.pending) { q in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(q.appName) wants to connect").font(.system(size: 13, weight: .semibold))
                            Text("\(q.host)\(q.port.isEmpty ? "" : ":" + q.port) · \(q.proto)").font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                            if q.identity != nil || q.parent != nil { Text([q.identity, q.parent.map { "started by " + $0 }].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 11, weight: .medium)).foregroundStyle(q.identity == nil ? Color.secondary : Color.orange) }
                        }
                        Spacer(minLength: 8)
                        Button("Allow once") { client.answer(q, allow: true, remember: false) }.buttonStyle(MacHoverButtonStyle())
                        Button("Always allow") { client.answer(q, allow: true, remember: true) }.buttonStyle(MacHoverButtonStyle())
                        Button("Block once") { client.answer(q, allow: false, remember: false) }.buttonStyle(MacHoverButtonStyle())
                        Button("Always block") { client.answer(q, allow: false, remember: true) }.buttonStyle(MacHoverButtonStyle(prominent: true))
                    }
                    if q.id != client.pending.last?.id { Divider() }
                }
                Text("If you do not answer, the connection follows the default (\(client.settings.defaultAction == .allow ? "allowed" : "blocked")) after \(client.settings.askTimeout) seconds.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Content
    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("", selection: $view) { ForEach(View_.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 560)
            if view != .rules && view != .lists {
                HStack(spacing: 10) {
                    HStack(spacing: 6) { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Search apps and destinations", text: $search).textFieldStyle(.plain) }
                        .padding(8).frame(maxWidth: 320).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Toggle("Hide local network chatter", isOn: $hideLocal).toggleStyle(.checkbox).font(.system(size: 12)).help("Hides connections to devices on your own network and to port 5353 (Bonjour), which fill the list without telling you much.")
                    Spacer(minLength: 8)
                    Button { paused.toggle(); if paused { frozen = client.flows } } label: { Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill") }.buttonStyle(MacHoverButtonStyle()).fixedSize()
                    Button { client.clearFlows(); frozen = [] } label: { Label("Clear", systemImage: "trash") }.buttonStyle(MacHoverButtonStyle()).fixedSize()
                }
            }
            switch view {
            case .live: connections
            case .apps: appsTable
            case .traffic: trafficView
            case .map: NetworkMap(flows: shown, client: client)
            case .lists: listsView
            case .rules: rulesView
            }
        }
    }
    private var connections: some View {
        MacPanel("Connections", icon: "arrow.left.arrow.right", trailing: { Text("\(client.flows.count) recorded").font(.system(size: 11)).foregroundStyle(.secondary) }) {
            if shown.isEmpty {
                Text(client.status == .running ? "No connections yet. Use any app and they appear here." : "Waiting for the filter to start…").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Table(shown, selection: $selection) {
                    TableColumn("Time") { Text($0.time, format: .dateTime.hour().minute().second()).monospacedDigit().foregroundStyle(.secondary) }.width(70)
                    TableColumn("App") { Text($0.appName).lineLimit(1) }.width(min: 110, ideal: 150)
                    TableColumn("Destination") { Text($0.host + ($0.port.isEmpty ? "" : ":" + $0.port)).lineLimit(1).textSelection(.enabled) }.width(min: 160, ideal: 260)
                    TableColumn("Protocol") { Text($0.proto).foregroundStyle(.secondary) }.width(60)
                    TableColumn("Data") { flow in
                        Text(flow.bytesIn == nil && flow.bytesOut == nil ? "" : "↓ " + Self.size(flow.bytesIn ?? 0) + "  ↑ " + Self.size(flow.bytesOut ?? 0)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    }.width(min: 90, ideal: 120)
                    TableColumn("Result") { MacChip(text: $0.verdict == .allow ? "Allowed" : "Blocked", tint: $0.verdict == .allow ? .green : .red) }.width(80)
                    TableColumn("Notes") { flow in
                        HStack(spacing: 6) {
                            if let warning = flow.identity { MacChip(text: warning, tint: .orange) }
                            if let list = flow.list { MacChip(text: list, tint: flow.verdict == .block ? .red : .green) }
                            if let parent = flow.parent { Text("via " + parent).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                        }.help(flow.team.map { "Signed by team " + $0 } ?? "Not signed by a developer team (Apple software has no team)")
                    }.width(min: 90, ideal: 170)
                }.frame(minHeight: 380)
                    .contextMenu(forSelectionType: Int64.self) { ids in
                        let chosen = shown.filter { ids.contains($0.id) }
                        if let first = chosen.first {
                            Button("Block \(first.appName)") { client.addRule(NetRule(app: first.app, host: "*", port: "*", action: .block, note: "From the connection list")) }
                            Button("Block \(first.host) for every app") { client.addRule(NetRule(app: "*", host: first.host, port: "*", action: .block, note: "From the connection list")) }
                            Button("Block \(first.appName) → \(first.host)") { client.addRule(NetRule(app: first.app, host: first.host, port: "*", action: .block, note: "From the connection list")) }
                            Divider()
                            Button("Always allow \(first.appName) → \(first.host)") { client.addRule(NetRule(app: first.app, host: first.host, port: "*", action: .allow, note: "From the connection list")) }
                            Button("Allow \(first.appName) → \(first.host) for 1 hour") { var r = NetRule(app: first.app, host: first.host, port: "*", action: .allow, note: "Temporary"); r.group = "Temporary"; r.expires = Date().addingTimeInterval(3600); client.addRule(r) }
                            Divider()
                            Button("Copy destination") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(first.host, forType: .string) }
                        }
                    }
            }
        }
    }
    private var appsTable: some View {
        MacPanel("Apps", icon: "square.grid.2x2") {
            let rows = apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.app.localizedCaseInsensitiveContains(search) }
            if rows.isEmpty { Text("No apps yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100) }
            VStack(spacing: 0) {
                ForEach(rows, id: \.app) { row in
                    MacRow(icon: "app.dashed", title: row.name, detail: "\(row.app) · \(row.hosts.count) destination\(row.hosts.count == 1 ? "" : "s") · last \(row.last.formatted(date: .omitted, time: .standard))") {
                        HStack(spacing: 8) {
                            MacChip(text: "\(row.total) connections", tint: .secondary)
                            if let bytes = trafficApps.first(where: { $0.name == row.name }) { MacChip(text: Self.size(bytes.bytesIn + bytes.bytesOut), tint: .blue) }
                            if row.blocked > 0 { MacChip(text: "\(row.blocked) blocked", tint: .red) }
                            Button("Block app") { client.addRule(NetRule(app: row.app, host: "*", port: "*", action: .block, note: "From the app list")) }.buttonStyle(MacHoverButtonStyle())
                        }
                    }
                    if row.app != rows.last?.app { Divider() }
                }
            }
        }
    }
    private var rulesView: some View {
        VStack(spacing: 20) {
            MacPanel("How connections are decided", icon: "gearshape") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Mode", selection: Binding(get: { client.settings.mode }, set: { client.setMode($0) })) { ForEach(FilterMode.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 330)
                    Text(client.settings.mode.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    Divider()
                    if client.settings.mode == .allowAll {
                        MacRow(icon: "checkmark.circle", title: "Unmatched connections are", detail: "Allowed without asking. Rules and lists still win.") {
                            Picker("", selection: Binding(get: { client.settings.passiveAction }, set: { var s = client.settings; s.passiveAction = $0; client.update(settings: s) })) { Text("Allowed").tag(NetAction.allow); Text("Blocked").tag(NetAction.block) }.labelsHidden().pickerStyle(.segmented).frame(width: 160)
                        }
                        Toggle("Save the choice as a rule for that app", isOn: Binding(get: { client.settings.passiveCreatesRules }, set: { var s = client.settings; s.passiveCreatesRules = $0; client.update(settings: s) })).font(.system(size: 12))
                        Divider()
                    }
                    if client.settings.mode == .requireApproval {
                        MacRow(icon: "arrow.triangle.branch", title: "Default for connections no rule covers", detail: client.settings.defaultAction == .allow ? "Allowed after the approval timeout." : "Blocked after the approval timeout.") {
                            Picker("", selection: Binding(get: { client.settings.defaultAction }, set: { value in
                                if value == .block { confirmingBlockAll = true } else { var s = client.settings; s.defaultAction = .allow; client.update(settings: s) }
                            })) { Text("Allow").tag(NetAction.allow); Text("Block").tag(NetAction.block) }.labelsHidden().pickerStyle(.segmented).frame(width: 150)
                        }
                        Divider()
                        MacRow(icon: "questionmark.bubble", title: "Ask me about new connections", detail: "Pauses each unknown outbound connection and asks you before it proceeds. The prompt remains available from every page.") {
                            Toggle("", isOn: Binding(get: { client.settings.askMode }, set: { var s = client.settings; s.askMode = $0; client.update(settings: s) })).labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityLabel("Ask me about new connections")
                        }
                        if client.settings.askMode {
                            Picker("Prompt policy", selection: Binding(get: { client.settings.askPolicy }, set: { var s = client.settings; s.askPolicy = $0; client.update(settings: s) })) {
                                ForEach(AskPolicy.allCases) { Text($0.title).tag($0) }
                            }
                            Text(client.settings.askPolicy.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                            Toggle("Automatically use the default after a timeout", isOn: Binding(get: { client.settings.automaticAskResolution }, set: { var s = client.settings; s.automaticAskResolution = $0; client.update(settings: s) })).font(.system(size: 12))
                            if client.settings.automaticAskResolution {
                                Stepper("Wait \(client.settings.askTimeout) seconds for an answer", value: Binding(get: { client.settings.askTimeout }, set: { var s = client.settings; s.askTimeout = $0; client.update(settings: s) }), in: 5...120, step: 5).font(.system(size: 12))
                            } else {
                                Text("Connections remain paused until you answer. Enable the timeout only for unattended or remote sessions.").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                    }
                    MacRow(icon: "apple.logo", title: "Let Apple-signed software connect", detail: "Skips the question for software Apple signed. Command-line tools such as curl and ssh are never skipped, and your own rules always come first.") {
                        Toggle("", isOn: Binding(get: { client.settings.allowAppleSigned }, set: { var s = client.settings; s.allowAppleSigned = $0; client.update(settings: s) })).labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityLabel("Let Apple-signed software connect")
                    }
                    Divider()
                    MacRow(icon: "arrow.down.left", title: "Incoming connections", detail: "What an app that accepts a connection gets when no rule covers it. This watches connections apps accept; it is not a packet-level firewall.") {
                        Picker("", selection: Binding(get: { client.settings.inboundAction.map { $0 == .allow ? 1 : 2 } ?? 0 }, set: { var s = client.settings; s.inboundAction = $0 == 0 ? nil : ($0 == 1 ? .allow : .block); client.update(settings: s) })) { Text("Same as default").tag(0); Text("Allow").tag(1); Text("Block").tag(2) }.labelsHidden().pickerStyle(.segmented).frame(width: 260)
                    }
                    Divider()
                    MacRow(icon: "chart.bar", title: "Count traffic per connection", detail: "Shows how much each app sends and receives. While this is on, the filter reads the data of every allowed connection to count it, which can slow heavy transfers. Off by default.") {
                        Toggle("", isOn: Binding(get: { client.settings.countTraffic }, set: { var s = client.settings; s.countTraffic = $0; client.update(settings: s) })).labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityLabel("Count traffic per connection")
                    }
                    Text("Order of decision: your own and loopback traffic → a block list (unless a rule names the app and allows it) → your rules, most specific first → an allow list → Apple-signed software → the mode. At equal specificity, a block beats an allow.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            profilesPanel
            MacPanel("Groups", icon: "folder", trailing: {
                HStack(spacing: 8) {
                    Button { importing = true } label: { Label("Import…", systemImage: "square.and.arrow.down") }.buttonStyle(MacHoverButtonStyle())
                    Button { exportDocument = NetRulesDocument(rules: client.rules); exporting = true } label: { Label("Export…", systemImage: "square.and.arrow.up") }.buttonStyle(MacHoverButtonStyle()).disabled(client.rules.isEmpty)
                }
            }) {
                LazyVStack(spacing: 0) {
                    ForEach(groupNames, id: \.self) { name in
                        let count = client.rules.filter { $0.groupName == name }.count
                        MacRow(icon: "folder", title: name, detail: "\(count) rule\(count == 1 ? "" : "s")") {
                            Toggle("", isOn: Binding(get: { !(client.settings.disabledGroups ?? []).contains(name) }, set: { client.toggleGroup(name, on: $0) })).labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityLabel(name)
                        }
                        if name != groupNames.last { Divider() }
                    }
                }
                Text("Switch a group off to stop all of its rules at once, for example Work or Public Wi-Fi, and back on when you need them.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            MacPanel("Audit trail", icon: "checkmark.shield") {
                HStack(spacing: 10) {
                    Text("Decision and policy changes are kept locally as a hash-chained record.").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Export audit…") { auditDocument = FilterAuditDocument(events: client.audit); exportingAudit = true }.buttonStyle(MacHoverButtonStyle()).disabled(client.audit.isEmpty)
                }
                if !client.auditChainValid {
                    Label("Audit history integrity could not be verified.", systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
            MacPanel("Add a rule", icon: "plus.circle") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Picker("App", selection: $newRule.app) {
                            Text("Every app").tag("*")
                            ForEach(apps.prefix(100), id: \.app) { Text($0.name).tag($0.app) }
                        }.frame(width: 240)
                        TextField("Destination (example.com, *.example.com, 10.0.0.0/8, or *)", text: $newRule.host).textFieldStyle(.roundedBorder)
                        TextField("Port", text: $newRule.port).textFieldStyle(.roundedBorder).frame(width: 70)
                        Picker("", selection: $newRule.action) { Text("Block").tag(NetAction.block); Text("Allow").tag(NetAction.allow) }.labelsHidden().pickerStyle(.segmented).frame(width: 130)
                        Picker("", selection: Binding(get: { newRule.direction ?? .any }, set: { newRule.direction = $0 == .any ? nil : $0 })) { ForEach(NetDirection.allCases) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 110)
                        Button("Add") { add() }.buttonStyle(MacHoverButtonStyle(prominent: true)).disabled(newRule.host.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    HStack(spacing: 10) {
                        HStack(spacing: 4) {
                            TextField("Group", text: Binding(get: { newRule.group ?? "" }, set: { newRule.group = $0 })).textFieldStyle(.roundedBorder).frame(width: 140)
                            Menu { ForEach(groupNames, id: \.self) { name in Button(name) { newRule.group = name } } } label: { Image(systemName: "chevron.down") }.menuStyle(.borderlessButton).fixedSize()
                        }
                        Picker("Expires", selection: $expiry) { ForEach(Expiry.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 190)
                        Toggle("Only at certain times", isOn: $scheduleOn).toggleStyle(.switch).controlSize(.small)
                    }
                    HStack(spacing: 10) {
                        TextField("Signer Team ID (optional)", text: Binding(get: { newRule.team ?? "" }, set: { newRule.team = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines) })).textFieldStyle(.roundedBorder).frame(width: 220)
                        TextField("Parent process (optional)", text: Binding(get: { newRule.parent ?? "" }, set: { newRule.parent = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines) })).textFieldStyle(.roundedBorder).frame(width: 220)
                        Text("Constrain the rule to a signer or process lineage.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if scheduleOn {
                        HStack(spacing: 10) {
                            ForEach([(2, "Mon"), (3, "Tue"), (4, "Wed"), (5, "Thu"), (6, "Fri"), (7, "Sat"), (1, "Sun")], id: \.0) { day in
                                Toggle(day.1, isOn: Binding(get: { days.contains(day.0) }, set: { if $0 { days.insert(day.0) } else { days.remove(day.0) } })).toggleStyle(.button).controlSize(.small)
                            }
                            DatePicker("from", selection: $startTime, displayedComponents: .hourAndMinute).labelsHidden().frame(width: 90)
                            Text("to").foregroundStyle(.secondary)
                            DatePicker("to", selection: $endTime, displayedComponents: .hourAndMinute).labelsHidden().frame(width: 90)
                        }
                        Text("A window that ends before it starts runs overnight into the next day.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Text("A domain such as example.com also covers its subdomains; *.example.com covers only the subdomains; 10.0.0.0/8 or 10.0.0.1-10.0.0.50 cover addresses. Use * for any destination or any port. Groups can be switched on and off together, and a rule with an expiry stops counting by itself.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            MacPanel("Your rules", icon: "list.bullet", trailing: {
                HStack(spacing: 8) {
                    if client.rules.contains(where: { ($0.expires ?? .distantFuture) <= Date() }) { Button("Remove expired") { client.removeExpired() }.buttonStyle(MacHoverButtonStyle()) }
                    Text("\(client.rules.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
            }) {
                if client.rules.isEmpty { Text("No rules yet. Right-click a connection to block it, or add a rule above.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80) }
                LazyVStack(spacing: 0) {
                    ForEach(rulesForDisplay) { rule in
                        MacRow(icon: rule.action == .block ? "hand.raised.fill" : "checkmark.circle", title: "\(rule.app == "*" ? "Every app" : rule.app) → \(rule.host)\(rule.port == "*" ? "" : ":" + rule.port)", detail: ruleDetail(rule), tint: rule.action == .block ? .red : .green) {
                            HStack(spacing: 8) {
                                Picker("", selection: Binding(get: { rule.action }, set: { client.setAction(rule.id, $0) })) { Text("Block").tag(NetAction.block); Text("Allow").tag(NetAction.allow) }.labelsHidden().pickerStyle(.segmented).frame(width: 130)
                                Button(role: .destructive) { client.removeRules([rule.id]) } label: { Image(systemName: "trash") }.buttonStyle(MacHoverButtonStyle()).help("Delete this rule")
                            }
                        }
                        if rule.id != client.rules.first?.id { Divider() }
                    }
                    if client.rules.count > rulesForDisplay.count {
                        Text("Showing the 25 most recent rules. Export the complete \(client.rules.count)-rule set for review or backup.").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 8)
                    }
                }
            }
        }
    }
    /// Bonjour (port 5353), and connections to private, link-local and multicast addresses on this network.
    static func isLocalChatter(_ flow: FlowRecord) -> Bool {
        if flow.port == "5353" { return true }
        let h = flow.remoteAddress ?? flow.host
        return h.hasPrefix("192.168.") || h.hasPrefix("10.") || h.hasPrefix("169.254.") || h.hasPrefix("fe80:") || h.hasPrefix("ff0") || h.hasPrefix("224.") || h.hasPrefix("239.") || h == "255.255.255.255"
    }
    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    // MARK: Profiles
    @State private var profileName = ""
    private var profilesPanel: some View {
        MacPanel("Profiles", icon: "person.2", trailing: { if let name = client.activeProfile { MacChip(text: name, tint: .blue) } }) {
            VStack(alignment: .leading, spacing: 10) {
                if client.profiles.isEmpty { Text("A profile keeps your rules and settings under a name, so you can switch between Home, Work or Public Wi-Fi in one click.").font(.system(size: 12)).foregroundStyle(.secondary) }
                ForEach(client.profiles) { profile in
                    MacRow(icon: "person.crop.circle", title: profile.name, detail: "\(profile.rules.count) rule\(profile.rules.count == 1 ? "" : "s") · \(profile.settings.mode.title)") {
                        HStack(spacing: 8) {
                            Button("Use") { client.applyProfile(named: profile.name) }.buttonStyle(MacHoverButtonStyle(prominent: client.activeProfile == profile.name))
                            Button(role: .destructive) { client.deleteProfile(profile.id) } label: { Image(systemName: "trash") }.buttonStyle(MacHoverButtonStyle())
                        }
                    }
                    Divider()
                }
                HStack(spacing: 10) {
                    TextField("Name for the current rules and settings", text: $profileName).textFieldStyle(.roundedBorder).frame(width: 300)
                    Button("Save") { client.saveProfile(named: profileName); profileName = "" }.buttonStyle(MacHoverButtonStyle(prominent: true)).disabled(profileName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("From Terminal or a shortcut: open \"vayusetu://network/profile/Work\" applies a profile, and open \"vayusetu://network/mode/passive\" (normal, passive or blockall) changes the mode.").font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    // MARK: Lists
    @State private var listName = ""
    @State private var listSource = ""
    @State private var listText = ""
    @State private var listKind = NetAction.block
    private static let presets: [(name: String, url: String, kind: NetAction, detail: String)] = [
        ("Ads and trackers (StevenBlack)", "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts", .block, "A widely used hosts list of ad, tracker and malware names."),
        ("Ad servers (Peter Lowe)", "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext", .block, "A small, long-maintained list of ad servers."),
        ("Malware (URLhaus)", "https://urlhaus.abuse.ch/downloads/hostfile/", .block, "Hosts currently serving malware, from abuse.ch."),
    ]
    private var listsView: some View {
        VStack(spacing: 20) {
            MacPanel("Block lists and allow lists", icon: "list.bullet.rectangle") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("A block list stops every connection to its destinations, for every app, unless one of your rules names an app and allows it. An allow list lets its destinations through without a question. Lists refresh on their own while VayuSetu is open.").font(.system(size: 12)).foregroundStyle(.secondary)
                    if client.lists.isEmpty { Text("No lists yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60) }
                    ForEach(client.lists) { list in
                        MacRow(icon: list.kind == .block ? "hand.raised.fill" : "checkmark.shield", title: list.name, detail: listDetail(list), tint: list.kind == .block ? .red : .green) {
                            HStack(spacing: 8) {
                                if client.refreshing.contains(list.id) { ProgressView().controlSize(.small) }
                                else if list.source != nil { Button { Task { await client.refreshList(list.id) } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(MacHoverButtonStyle()).help("Refresh now") }
                                Toggle("", isOn: Binding(get: { list.enabled }, set: { client.setListEnabled(list.id, $0) })).labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityLabel(list.name)
                                Button(role: .destructive) { client.removeList(list.id) } label: { Image(systemName: "trash") }.buttonStyle(MacHoverButtonStyle()).help("Remove this list")
                            }
                        }
                        Divider()
                    }
                }
            }
            MacPanel("Add a list", icon: "plus.circle") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Self.presets, id: \.name) { preset in
                        let have = client.lists.contains { $0.source == preset.url }
                        MacRow(icon: "sparkles", title: preset.name, detail: preset.detail) {
                            Button(have ? "Added" : "Add") { client.addList(name: preset.name, kind: preset.kind, source: preset.url, text: "") }.buttonStyle(MacHoverButtonStyle()).disabled(have)
                        }
                    }
                    Divider()
                    HStack(spacing: 10) {
                        TextField("Name", text: $listName).textFieldStyle(.roundedBorder).frame(width: 200)
                        Picker("", selection: $listKind) { Text("Block").tag(NetAction.block); Text("Allow").tag(NetAction.allow) }.labelsHidden().pickerStyle(.segmented).frame(width: 130)
                        TextField("https:// address to refresh from (optional)", text: $listSource).textFieldStyle(.roundedBorder)
                    }
                    TextEditor(text: $listText).font(.system(size: 12, design: .monospaced)).frame(height: 90)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
                    HStack {
                        Text("Paste names, addresses, wildcards (*.example.com) or address blocks, one per line. Hosts-file and ad-blocker (||name^) lines work too.").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Add list") {
                            let name = listName.trimmingCharacters(in: .whitespaces), source = listSource.trimmingCharacters(in: .whitespaces)
                            guard !name.isEmpty, !(source.isEmpty && listText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else { client.message = "Give the list a name and either an address or some entries."; return }
                            guard source.isEmpty || source.hasPrefix("https://") else { client.message = "Only https addresses can be refreshed."; return }
                            client.addList(name: name, kind: listKind, source: source.isEmpty ? nil : source, text: listText)
                            listName = ""; listSource = ""; listText = ""
                        }.buttonStyle(MacHoverButtonStyle(prominent: true))
                    }
                }
            }
        }
    }
    private func listDetail(_ list: NetList) -> String {
        var parts = [list.kind == .block ? "Block" : "Allow", list.status ?? "\(list.entries.count) entries"]
        if let updated = list.updated { parts.append("updated " + updated.formatted(.relative(presentation: .named))) }
        if let hit = client.hits(for: list), hit.count > 0 { parts.append("matched \(hit.count) time\(hit.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    // MARK: Traffic
    private var trafficApps: [(name: String, bytesIn: Int64, bytesOut: Int64)] {
        var table: [String: (Int64, Int64)] = [:]; var names: [String: String] = [:]
        for flow in client.flows { table[flow.app, default: (0, 0)].0 += flow.bytesIn ?? 0; table[flow.app, default: (0, 0)].1 += flow.bytesOut ?? 0; names[flow.app] = flow.appName }
        return table.map { (names[$0.key] ?? $0.key, $0.value.0, $0.value.1) }.filter { $0.1 + $0.2 > 0 }.sorted { $0.1 + $0.2 > $1.1 + $1.2 }
    }
    private struct MinutePoint { var time: Date; var bytes: Int64 }
    /// Bytes per minute for the last hour, counted at the minute each connection started.
    private var minutePoints: [MinutePoint] {
        let cutoff = Date().addingTimeInterval(-3600)
        var table: [Date: Int64] = [:]
        for flow in client.flows where flow.time > cutoff {
            let total: Int64 = (flow.bytesIn ?? 0) + (flow.bytesOut ?? 0)
            guard total > 0 else { continue }
            let minute: Date = Calendar.current.dateInterval(of: .minute, for: flow.time)?.start ?? flow.time
            table[minute, default: 0] += total
        }
        return table.map { MinutePoint(time: $0.key, bytes: $0.value) }.sorted { $0.time < $1.time }
    }
    private var trafficView: some View {
        VStack(spacing: 20) {
            if !client.settings.countTraffic {
                MacPanel("Traffic", icon: "chart.bar") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Byte counts are off. While counting is on, the filter reads the data of each allowed connection, which can slow heavy transfers, so it is your choice.").font(.system(size: 12)).foregroundStyle(.secondary)
                        Button("Count traffic") { var s = client.settings; s.countTraffic = true; client.update(settings: s) }.buttonStyle(MacHoverButtonStyle(prominent: true))
                    }
                }
            } else {
                let rows = Array(trafficApps.prefix(10))
                MacPanel("Busiest apps", icon: "chart.bar.xaxis", trailing: { Text("since the filter started recording").font(.system(size: 11)).foregroundStyle(.secondary) }) {
                    if rows.isEmpty { Text("Nothing counted yet. Use any app and the numbers appear here.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100) }
                    else {
                        Chart {
                            ForEach(rows, id: \.name) { row in
                                BarMark(x: .value("Bytes", row.bytesIn), y: .value("App", row.name)).foregroundStyle(by: .value("Direction", "Received"))
                                BarMark(x: .value("Bytes", row.bytesOut), y: .value("App", row.name)).foregroundStyle(by: .value("Direction", "Sent"))
                            }
                        }.chartForegroundStyleScale(["Received": Color.blue, "Sent": Color.orange])
                            .chartXAxis { AxisMarks { value in AxisGridLine(); AxisValueLabel { if let n = value.as(Int64.self) { Text(Self.size(n)) } } } }
                            .frame(height: max(140, CGFloat(rows.count) * 34))
                        ForEach(rows, id: \.name) { row in
                            HStack { Text(row.name).font(.system(size: 12)); Spacer(); Text("↓ " + Self.size(row.bytesIn) + "   ↑ " + Self.size(row.bytesOut)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary) }
                        }
                    }
                }
                MacPanel("Over time", icon: "chart.xyaxis.line", trailing: { Text("per minute, last hour").font(.system(size: 11)).foregroundStyle(.secondary) }) {
                    let points = minutePoints
                    if points.isEmpty { Text("No traffic counted in the last hour.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100) }
                    else {
                        Chart(points, id: \.time) { point in BarMark(x: .value("Minute", point.time, unit: .minute), y: .value("Bytes", point.bytes)) }
                            .chartYAxis { AxisMarks { value in AxisGridLine(); AxisValueLabel { if let n = value.as(Int64.self) { Text(Self.size(n)) } } } }
                            .frame(height: 180)
                        Text("Bytes are added to the minute a connection started, so a long download shows at its start.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var groupNames: [String] {
        let used = Set(client.rules.map(\.groupName))
        return Array(used.union(["Default", "Temporary", "Work", "Public Wi-Fi", "Lockdown"])).sorted { $0 == "Default" ? true : $1 == "Default" ? false : $0 < $1 }
    }
    private func ruleDetail(_ rule: NetRule) -> String {
        var parts = [rule.groupName]
        if let expires = rule.expires { parts.append(expires <= Date() ? "expired" : "until " + expires.formatted(date: .abbreviated, time: .shortened)) }
        if let schedule = rule.schedule {
            let names = [1: "Sun", 2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat"]
            func hm(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }
            parts.append(schedule.days.compactMap { names[$0] }.joined(separator: " ") + " " + hm(schedule.start) + "–" + hm(schedule.end))
        }
        if let direction = rule.direction, direction != .any { parts.append(direction.title.lowercased()) }
        if !rule.note.isEmpty { parts.append(rule.note) }
        if let hit = client.hits(for: rule), hit.count > 0 { parts.append("used \(hit.count) time\(hit.count == 1 ? "" : "s"), last \(hit.last.formatted(.relative(presentation: .named)))") } else { parts.append("not used yet") }
        return parts.joined(separator: " · ")
    }
    private func add() {
        var rule = newRule
        rule.host = rule.host.trimmingCharacters(in: .whitespaces); rule.port = rule.port.trimmingCharacters(in: .whitespaces).isEmpty ? "*" : rule.port.trimmingCharacters(in: .whitespaces)
        guard NetRuleEngine.isValidDestination(rule.host) else { client.message = "That destination is not a name, address, wildcard, address block or range."; return }
        guard rule.port == "*" || UInt16(rule.port) != nil else { client.message = "A port is a number from 1 to 65535, or *."; return }
        let group = (rule.group ?? "").trimmingCharacters(in: .whitespaces)
        rule.group = group.isEmpty || group == "Default" ? nil : group
        rule.expires = expiry.seconds.map { Date().addingTimeInterval($0) }
        if scheduleOn {
            guard !days.isEmpty else { client.message = "Choose at least one day for the schedule."; return }
            let cal = Calendar.current
            func minutes(_ d: Date) -> Int { cal.component(.hour, from: d) * 60 + cal.component(.minute, from: d) }
            rule.schedule = NetSchedule(days: days.sorted(), start: minutes(startTime), end: minutes(endTime))
        }
        client.addRule(rule); newRule = NetRule(app: "*", host: "*", port: "*", action: .block); expiry = .never; scheduleOn = false
    }
}

/// A global, non-modal prompt for a newly observed connection. It remains visible
/// on every page, so the filter behaves like a host firewall rather than a page-local
/// activity viewer. The full Network page still shows all pending questions.
struct ConnectionQuestionBanner: View {
    let question: PendingQuestion
    @ObservedObject var client: FilterClient

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.shield.fill").foregroundStyle(.orange)
                Text("New connection") .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(client.pending.count) waiting").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("\(question.appName) wants to connect")
                .font(.system(size: 13, weight: .medium))
            Text("\(question.host)\(question.port.isEmpty ? "" : ":" + question.port) · \(question.proto)")
                .font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
            if question.identity != nil || question.parent != nil {
                Text([question.identity, question.parent.map { "started by " + $0 }].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(question.identity == nil ? Color.secondary : Color.orange)
            }
            HStack(spacing: 8) {
                Button("Allow once") { client.answer(question, allow: true, remember: false) }
                Button("Always allow") { client.answer(question, allow: true, remember: true) }
                Button("Block once") { client.answer(question, allow: false, remember: false) }
                Button("Always block") { client.answer(question, allow: false, remember: true) }.buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.orange.opacity(0.35)))
        .shadow(radius: 12, y: 5)
        .accessibilityElement(children: .contain)
    }
}

import UniformTypeIdentifiers
/// Rules as a JSON file, for backup and for sharing a set of rules between Macs.
struct NetRulesDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var rules: [NetRule]
    init(rules: [NetRule]) { self.rules = rules }
    init(configuration: ReadConfiguration) throws { rules = (try? JSONDecoder().decode([NetRule].self, from: configuration.file.regularFileContents ?? Data())) ?? [] }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(rules))
    }
}

struct FilterAuditDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var events: [FilterAuditRecord]
    init(events: [FilterAuditRecord]) { self.events = events }
    init(configuration: ReadConfiguration) throws { events = (try? JSONDecoder().decode([FilterAuditRecord].self, from: configuration.file.regularFileContents ?? Data())) ?? [] }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return FileWrapper(regularFileWithContents: try encoder.encode(events))
    }
}
