import AppKit
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
    @Published var message = ""
    private var connection: NSXPCConnection?
    private var task: Task<Void, Never>?
    private var lastID: Int64 = 0
    private var wanted = false
    static let maximumShown = 1500

    var supported: Bool { ExtensionManager.filterBundled }

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
        }
    }
    private func tell(_ call: @escaping (VayuFilterXPC, @escaping (Bool) -> Void) -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            let once = Once()
            guard let proxy = proxy({ _ in if once.first() { continuation.resume(returning: false) } }) else { continuation.resume(returning: false); return }
            call(proxy) { ok in if once.first() { continuation.resume(returning: ok) } }
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
        }
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
    func answer(_ question: PendingQuestion, allow: Bool, remember: Bool) {
        pending.removeAll { $0.id == question.id }
        Task { _ = await tell { proxy, reply in proxy.answer(question.id, allow: allow, remember: remember, reply: reply) }; await refreshRules() }
    }
    private func refreshRules() async { if let d = await ask({ $0.rules(reply: $1) }), let r = try? JSONDecoder().decode([NetRule].self, from: d) { rules = r } }
    func clearFlows() { flows = []; Task { _ = await tell { proxy, reply in proxy.clearFlows(reply: reply) } } }
}

// MARK: - The page
struct MacNetwork: View {
    @ObservedObject var client: FilterClient
    @ObservedObject var extensions: ExtensionManager
    @State private var search = ""
    @State private var paused = false
    @State private var frozen: [FlowRecord] = []
    @State private var selection = Set<Int64>()
    @State private var view = View_.live
    @State private var newRule = NetRule(app: "*", host: "*", port: "*", action: .block)
    @State private var confirmingBlockAll = false
    private enum View_: String, CaseIterable, Identifiable { case live = "Connections", apps = "By app", rules = "Rules"; var id: String { rawValue } }

    private var shown: [FlowRecord] {
        let source = paused ? frozen : client.flows
        let matching = search.isEmpty ? source : source.filter { $0.appName.localizedCaseInsensitiveContains(search) || $0.host.localizedCaseInsensitiveContains(search) || $0.app.localizedCaseInsensitiveContains(search) }
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

    var body: some View {
        MacPage(title: "Network", subtitle: "See which apps connect where, and block what you don't want.") {
            switchPanel
            if !client.pending.isEmpty { questions }
            if client.status == .running || client.status == .unreachable || client.status == .starting { content }
        }
        .onAppear { client.startPolling() }
        .onDisappear { client.stopPolling() }
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
            HStack(spacing: 12) {
                Picker("", selection: $view) { ForEach(View_.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 320)
                Spacer()
                if view != .rules {
                    HStack(spacing: 6) { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Search apps and destinations", text: $search).textFieldStyle(.plain) }
                        .padding(8).frame(width: 260).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Button { paused.toggle(); if paused { frozen = client.flows } } label: { Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill") }.buttonStyle(MacHoverButtonStyle())
                    Button { client.clearFlows(); frozen = [] } label: { Label("Clear", systemImage: "trash") }.buttonStyle(MacHoverButtonStyle())
                }
            }
            switch view {
            case .live: connections
            case .apps: appsTable
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
                    TableColumn("Result") { MacChip(text: $0.verdict == .allow ? "Allowed" : "Blocked", tint: $0.verdict == .allow ? .green : .red) }.width(80)
                }.frame(minHeight: 380)
                    .contextMenu(forSelectionType: Int64.self) { ids in
                        let chosen = shown.filter { ids.contains($0.id) }
                        if let first = chosen.first {
                            Button("Block \(first.appName)") { client.addRule(NetRule(app: first.app, host: "*", port: "*", action: .block, note: "From the connection list")) }
                            Button("Block \(first.host) for every app") { client.addRule(NetRule(app: "*", host: first.host, port: "*", action: .block, note: "From the connection list")) }
                            Button("Block \(first.appName) → \(first.host)") { client.addRule(NetRule(app: first.app, host: first.host, port: "*", action: .block, note: "From the connection list")) }
                            Divider()
                            Button("Always allow \(first.appName) → \(first.host)") { client.addRule(NetRule(app: first.app, host: first.host, port: "*", action: .allow, note: "From the connection list")) }
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
                    MacRow(icon: "arrow.triangle.branch", title: "Default for connections no rule covers", detail: client.settings.defaultAction == .allow ? "Allowed. Rules block what you choose." : "Blocked. Rules allow what you choose.") {
                        Picker("", selection: Binding(get: { client.settings.defaultAction }, set: { value in
                            if value == .block { confirmingBlockAll = true } else { var s = client.settings; s.defaultAction = .allow; client.update(settings: s) }
                        })) { Text("Allow").tag(NetAction.allow); Text("Block").tag(NetAction.block) }.labelsHidden().pickerStyle(.segmented).frame(width: 150)
                    }
                    Divider()
                    MacRow(icon: "questionmark.bubble", title: "Ask me about new connections", detail: "Pauses a connection that no rule covers and asks you. Off by default, because it can be busy.") {
                        Toggle("", isOn: Binding(get: { client.settings.askMode }, set: { var s = client.settings; s.askMode = $0; client.update(settings: s) })).labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityLabel("Ask me about new connections")
                    }
                    if client.settings.askMode {
                        Stepper("Wait \(client.settings.askTimeout) seconds for an answer", value: Binding(get: { client.settings.askTimeout }, set: { var s = client.settings; s.askTimeout = $0; client.update(settings: s) }), in: 5...120, step: 5).font(.system(size: 12))
                    }
                    Text("The most specific rule wins: a named app beats every app, an address beats a domain, and a port adds to it. At equal specificity, a block beats an allow.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            MacPanel("Add a rule", icon: "plus.circle") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Picker("App", selection: $newRule.app) {
                            Text("Every app").tag("*")
                            ForEach(apps, id: \.app) { Text($0.name).tag($0.app) }
                        }.frame(width: 240)
                        TextField("Destination (example.com, an address, or *)", text: $newRule.host).textFieldStyle(.roundedBorder)
                        TextField("Port", text: $newRule.port).textFieldStyle(.roundedBorder).frame(width: 70)
                        Picker("", selection: $newRule.action) { Text("Block").tag(NetAction.block); Text("Allow").tag(NetAction.allow) }.labelsHidden().pickerStyle(.segmented).frame(width: 130)
                        Button("Add") { add() }.buttonStyle(MacHoverButtonStyle(prominent: true)).disabled(newRule.host.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text("A domain such as example.com also covers its subdomains. Use * for any destination or any port.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            MacPanel("Your rules", icon: "list.bullet", trailing: { Text("\(client.rules.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary) }) {
                if client.rules.isEmpty { Text("No rules yet. Right-click a connection to block it, or add a rule above.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80) }
                VStack(spacing: 0) {
                    ForEach(client.rules.reversed()) { rule in
                        MacRow(icon: rule.action == .block ? "hand.raised.fill" : "checkmark.circle", title: "\(rule.app == "*" ? "Every app" : rule.app) → \(rule.host)\(rule.port == "*" ? "" : ":" + rule.port)", detail: rule.note.isEmpty ? "Added " + rule.created.formatted(date: .abbreviated, time: .shortened) : rule.note, tint: rule.action == .block ? .red : .green) {
                            HStack(spacing: 8) {
                                Picker("", selection: Binding(get: { rule.action }, set: { client.setAction(rule.id, $0) })) { Text("Block").tag(NetAction.block); Text("Allow").tag(NetAction.allow) }.labelsHidden().pickerStyle(.segmented).frame(width: 130)
                                Button(role: .destructive) { client.removeRules([rule.id]) } label: { Image(systemName: "trash") }.buttonStyle(MacHoverButtonStyle()).help("Delete this rule")
                            }
                        }
                        if rule.id != client.rules.first?.id { Divider() }
                    }
                }
            }
        }
    }
    private func add() {
        var rule = newRule
        rule.host = rule.host.trimmingCharacters(in: .whitespaces); rule.port = rule.port.trimmingCharacters(in: .whitespaces).isEmpty ? "*" : rule.port.trimmingCharacters(in: .whitespaces)
        guard rule.port == "*" || UInt16(rule.port) != nil else { client.message = "A port is a number from 1 to 65535, or *."; return }
        client.addRule(rule); newRule = NetRule(app: "*", host: "*", port: "*", action: .block)
    }
}
