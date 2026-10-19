import Darwin
import Foundation
import Network
import NetworkExtension
import Security
import os

/// The network filter. It sees each new connection with the app that opened it and applies VayuSetu's rules. Every decision is recorded so the
/// app can show it, and VayuSetu's own connections and loopback traffic are never filtered.
final class VayuFilterProvider: NEFilterDataProvider {
    private let state = FilterStore.shared

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        state.provider = self
        state.load()
        FilterService.shared.start()
        // With no rules and a default of "filter data", every new socket flow reaches handleNewFlow.
        let settings = NEFilterSettings(rules: [], defaultAction: .filterData)
        apply(settings) { error in completionHandler(error) }
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        state.releaseAll()
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        guard let socket = flow as? NEFilterSocketFlow else { return .allow() }
        let info = Self.describe(socket)
        return state.decide(flow, info)
    }

    // Byte counting, only for flows the store chose to inspect (the "Count traffic" option).
    override func handleInboundData(from flow: NEFilterFlow, readBytesStartOffset offset: Int, readBytes: Data) -> NEFilterDataVerdict {
        state.addBytes(flow, inbound: true, count: readBytes.count)
        return NEFilterDataVerdict(passBytes: readBytes.count, peekBytes: FilterStore.peekSize)
    }
    override func handleOutboundData(from flow: NEFilterFlow, readBytesStartOffset offset: Int, readBytes: Data) -> NEFilterDataVerdict {
        state.addBytes(flow, inbound: false, count: readBytes.count)
        return NEFilterDataVerdict(passBytes: readBytes.count, peekBytes: FilterStore.peekSize)
    }
    override func handleInboundDataComplete(for flow: NEFilterFlow) -> NEFilterDataVerdict { state.finish(flow); return .allow() }
    override func handleOutboundDataComplete(for flow: NEFilterFlow) -> NEFilterDataVerdict { state.finish(flow); return .allow() }

    /// Who is connecting, and to where.
    static func describe(_ flow: NEFilterSocketFlow) -> FlowInfo {
        var app = "unknown"
        var name = "unknown"
        var team: String?
        var valid = false
        var parent: String?
        var appleSigned = false
        if let token = flow.sourceAppAuditToken, token.count == MemoryLayout<audit_token_t>.size {
            let pid = token.withUnsafeBytes { $0.load(fromByteOffset: 20, as: Int32.self) }     // audit_token_t.val[5]
            var buffer = [CChar](repeating: 0, count: 4096)
            if pid > 0, proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 { name = (String(cString: buffer) as NSString).lastPathComponent }
            if let details = AppIdentity.details(token) { app = details.identifier; team = details.team; valid = details.valid; appleSigned = details.appleSigned } else { app = name }
            if name == "unknown" { name = app }
            parent = AppIdentity.parentName(of: pid)
        }
        var host = flow.remoteHostname ?? ""
        var port = ""
        var remoteAddress: String?
        if #available(macOS 15.0, *), let endpoint = flow.remoteFlowEndpoint {
            if case let .hostPort(h, p) = endpoint { let address = "\(h)"; if NetRuleEngine.isAddress(address) { remoteAddress = address }; if host.isEmpty { host = address }; port = "\(p.rawValue)" }
        } else if let endpoint = flow.remoteEndpoint as? NWHostEndpoint {
            if NetRuleEngine.isAddress(endpoint.hostname) { remoteAddress = endpoint.hostname }; if host.isEmpty { host = endpoint.hostname }; port = endpoint.port
        }
        let proto: String
        switch flow.socketProtocol { case IPPROTO_TCP: proto = "TCP"; case IPPROTO_UDP: proto = "UDP"; case let other: proto = "IP \(other)" }
        return FlowInfo(app: app, appName: name, host: host.isEmpty ? "unknown" : NetRuleEngine.normalise(host), port: port, proto: proto, outbound: flow.direction != .inbound, team: team, valid: valid, parent: parent, appleSigned: appleSigned, remoteAddress: remoteAddress)
    }
}

struct FlowInfo { var app: String, appName: String, host: String, port: String, proto: String, outbound: Bool; var team: String? = nil; var valid = true; var parent: String? = nil; var appleSigned = false; var remoteAddress: String? = nil }

/// All the filter's state, behind one lock: the rules, the settings, the recent connections and the connections waiting for an answer.
final class FilterStore {
    static let shared = FilterStore()
    weak var provider: NEFilterDataProvider?
    private let storageURL: URL?
    private let clientAvailable: () -> Bool
    init(storageURL: URL? = nil, clientAvailable: @escaping () -> Bool = { FilterService.shared.hasConnectedClient }) {
        self.storageURL = storageURL
        self.clientAvailable = clientAvailable
    }
    private let lock = NSLock()
    private var rules: [NetRule] = []
    private var settings = FilterSettings()
    private var flows: [FlowRecord] = []
    private var nextID: Int64 = 1
    private struct Waiting { var flow: NEFilterFlow; var question: PendingQuestion; var timer: DispatchSourceTimer? }
    private var waiting: [Int64: Waiting] = [:]
    private let maximumFlows = 5000
    private var teams: [String: String] = [:]          // the signer first seen for each app, to notice a change
    private var sessionDecisions: [String: NetAction] = [:] // balanced mode: one answer per app session
    private var dirty = false
    private var historyTimer: DispatchSourceTimer?
    private var lists: [NetList] = []
    private var index = NetListIndex()
    private var usage = FilterUsage()
    /// Connections whose bytes are being counted: the flow, and the history entry to add them to.
    private var tracked: [UUID: Int64] = [:]
    private var finished: [UUID: Int] = [:]
    static let peekSize = 1 << 16

    private var fileURL: URL {
        if let storageURL { return storageURL }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VayuSetuFilter", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("filter.json")
    }
    private var historyURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("history.json") }
    private var listsURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("lists.json") }
    private var usageURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("usage.json") }
    private struct Saved: Codable { var rules: [NetRule]; var settings: FilterSettings; var teams: [String: String]? = nil }
    func load() {
        lock.lock(); defer { lock.unlock() }
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(Saved.self, from: data) { rules = saved.rules.filter { $0.group != FilterNames.sessionGroup }; settings = saved.settings; teams = saved.teams ?? [:] }
        if flows.isEmpty, let data = try? Data(contentsOf: historyURL), let old = try? JSONDecoder().decode([FlowRecord].self, from: data) {
            flows = Array(old.suffix(maximumFlows)); nextID = (flows.map(\.id).max() ?? 0) + 1
        }
        if let data = try? Data(contentsOf: listsURL), let saved = try? JSONDecoder().decode([NetList].self, from: data) { lists = saved; index = NetListIndex(saved) }
        if let data = try? Data(contentsOf: usageURL), let saved = try? JSONDecoder().decode(FilterUsage.self, from: data) { usage = saved }
        if historyTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            timer.schedule(deadline: .now() + 30, repeating: 30)
            timer.setEventHandler { [weak self] in self?.saveHistory() }
            timer.resume(); historyTimer = timer
        }
    }
    private func saveLocked() { if let data = try? JSONEncoder().encode(Saved(rules: rules, settings: settings, teams: teams)) { try? data.write(to: fileURL, options: .atomic) } }
    /// History is written every half minute while there is something new, so it survives a restart without writing on every connection.
    func saveHistory() {
        lock.lock(); guard dirty else { lock.unlock(); return }; dirty = false; let snapshot = flows; let counts = usage; lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: historyURL, options: .atomic) }
        if let data = try? JSONEncoder().encode(counts) { try? data.write(to: usageURL, options: .atomic) }
    }
    /// Notes an app whose signature is invalid, or whose signer is not the one seen before. Call with the lock held.
    private func identityNote(_ info: FlowInfo) -> String? {
        guard info.app != "unknown" else { return nil }
        if !info.valid { return "Invalid signature" }
        let signer = info.team ?? ""
        if let known = teams[info.app] { return known == signer ? nil : "Signer changed" }
        teams[info.app] = signer; saveLocked()
        return nil
    }

    // MARK: Deciding
    /// The order: our own and loopback traffic → a block list (unless a rule names the app and allows it) → your rules → an allow list →
    /// Apple-signed software → the mode (block all, passive, or ask) → the default.
    func decide(_ flow: NEFilterFlow, _ info: FlowInfo) -> NEFilterNewFlowVerdict {
        lock.lock(); defer { lock.unlock() }
        if NetRuleEngine.isExempt(app: info.app, host: info.host, team: info.team, valid: info.valid) { record(info, .allow, nil); return .allow() }
        let decision = NetRuleEngine.decide(app: info.app, host: info.host, port: info.port, address: info.remoteAddress, outbound: info.outbound, rules: rules, settings: settings)
        if let name = index.match(.block, host: info.host, address: info.remoteAddress) {
            let overridden = decision.rule.map { $0.action == .allow && $0.app != "*" } ?? false
            if !overridden { return finish(flow, info, .block, rule: nil, list: name) }
        }
        if let rule = decision.rule { return finish(flow, info, decision.action, rule: rule.id, list: nil) }
        if let name = index.match(.allow, host: info.host, address: info.remoteAddress) { return finish(flow, info, .allow, rule: nil, list: name) }
        if settings.mode == .blockAll { return finish(flow, info, .block, rule: nil, list: nil) }
        // Explicit rules always precede system trust. A signing identifier is
        // chosen by the developer and is not proof that Apple signed a process.
        let trusted = settings.allowAppleSigned && info.valid && info.appleSigned &&
            !["curl", "wget", "osascript", "python", "python3", "ruby", "perl", "nc", "netcat", "ssh", "bash", "sh", "zsh"].contains(info.appName)
        if trusted && (settings.mode == .passive || (settings.defaultAction == .allow && settings.askPolicy == .newApplication)) { return finish(flow, info, .allow, rule: nil, list: nil) }
        if !info.outbound { return finish(flow, info, settings.inboundAction ?? settings.defaultAction, rule: nil, list: nil) }
        if settings.mode == .passive {
            if settings.passiveCreatesRules && !hasApplicationRule(for: info.app) && rules.count < 5000 {
                var rule = NetRule(app: info.app, host: "*", port: "*", action: settings.passiveAction, note: "Passive mode"); rule.group = "Passive"
                rules.append(rule); saveLocked()
                return finish(flow, info, settings.passiveAction, rule: rule.id, list: nil)
            }
            return finish(flow, info, settings.passiveAction, rule: nil, list: nil)
        }
        if settings.askMode {
            // If the user client is unavailable, record and allow the flow for
            // later review. Never leave sockets paused with nobody able
            // to answer them (for example during login or after the UI crashes).
            if !clientAvailable() { return finish(flow, info, .allow, rule: nil, list: nil) }
            if settings.askPolicy == .newApplication, let session = sessionDecisions[info.app] { return finish(flow, info, session, rule: nil, list: nil) }
            if settings.askPolicy == .everyConnection || !hasApplicationRule(for: info.app) { return askLocked(flow, info) }
        }
        return finish(flow, info, decision.action, rule: nil, list: nil)
    }
    private func hasApplicationRule(for app: String) -> Bool {
        rules.contains { rule in
            NetRuleEngine.isActive(rule, now: Date(), settings: settings) && rule.app == app && rule.host == "*" && rule.port == "*"
        }
    }
    /// Records the decision and turns it into the verdict. An allowed connection is handed over for byte counting only when that is switched on.
    private func finish(_ flow: NEFilterFlow, _ info: FlowInfo, _ action: NetAction, rule: UUID?, list: String?) -> NEFilterNewFlowVerdict {
        let id = record(info, action, rule, list: list)
        return verdict(for: flow, action, recordID: id)
    }
    private func verdict(for flow: NEFilterFlow, _ action: NetAction, recordID: Int64) -> NEFilterNewFlowVerdict {
        if action == .block { return .drop() }
        guard settings.countTraffic else { return .allow() }
        if tracked.count > 20_000 { tracked.removeAll(); finished.removeAll() }
        tracked[flow.identifier] = recordID
        return .filterDataVerdict(withFilterInbound: true, peekInboundBytes: Self.peekSize, filterOutbound: true, peekOutboundBytes: Self.peekSize)
    }
    @discardableResult private func record(_ info: FlowInfo, _ verdict: NetAction, _ rule: UUID?, list: String? = nil) -> Int64 {
        let id = nextID; nextID += 1; dirty = true
        flows.append(FlowRecord(id: id, time: Date(), app: info.app, appName: info.appName, host: info.host, port: info.port, proto: info.proto, outbound: info.outbound, verdict: verdict, rule: rule, team: info.team, identity: identityNote(info), parent: info.parent, remoteAddress: info.remoteAddress, list: list))
        if flows.count > maximumFlows { flows.removeFirst(flows.count - maximumFlows) }
        if let rule { var hit = usage.rules[rule.uuidString] ?? HitCount(); hit.count += 1; hit.last = Date(); usage.rules[rule.uuidString] = hit }
        if let list { var hit = usage.lists[list] ?? HitCount(); hit.count += 1; hit.last = Date(); usage.lists[list] = hit }
        return id
    }

    // MARK: Counting bytes
    func addBytes(_ flow: NEFilterFlow, inbound: Bool, count: Int) {
        lock.lock(); defer { lock.unlock() }
        guard count > 0, let id = tracked[flow.identifier], let position = position(of: id) else { return }
        if inbound { flows[position].bytesIn = (flows[position].bytesIn ?? 0) + Int64(count) } else { flows[position].bytesOut = (flows[position].bytesOut ?? 0) + Int64(count) }
        dirty = true
    }
    /// Called when one direction has no more data; the flow is forgotten once both have finished.
    func finish(_ flow: NEFilterFlow) {
        lock.lock(); defer { lock.unlock() }
        let seen = (finished[flow.identifier] ?? 0) + 1
        if seen >= 2 { tracked[flow.identifier] = nil; finished[flow.identifier] = nil } else { finished[flow.identifier] = seen }
    }
    /// Entries are in order of identifier, so a binary search finds one.
    private func position(of id: Int64) -> Int? {
        var low = 0, high = flows.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if flows[mid].id == id { return mid }
            if flows[mid].id < id { low = mid + 1 } else { high = mid - 1 }
        }
        return nil
    }

    // MARK: Asking
    private func askLocked(_ flow: NEFilterFlow, _ info: FlowInfo) -> NEFilterNewFlowVerdict {
        guard waiting.count < 1024 else { record(info, .block, nil); return .drop() }
        let id = nextID; nextID += 1
        let question = PendingQuestion(id: id, time: Date(), app: info.app, appName: info.appName, host: info.host, port: info.port, proto: info.proto, team: info.team, identity: identityNote(info), parent: info.parent, remoteAddress: info.remoteAddress)
        var timer: DispatchSourceTimer?
        if settings.automaticAskResolution {
            let fallback = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            fallback.schedule(deadline: .now() + .seconds(max(5, settings.askTimeout)))
            fallback.setEventHandler { [weak self] in self?.resolve(id, settings: nil, remember: false, timedOut: true) }
            fallback.resume(); timer = fallback
        }
        waiting[id] = Waiting(flow: flow, question: question, timer: timer)
        return .pause()
    }
    /// Answers a waiting connection. `allow == nil` means the question timed out and the default action applies.
    @discardableResult func resolve(_ id: Int64, settings answer: Bool?, remember: Bool, rule chosen: NetRule? = nil, timedOut: Bool = false) -> Bool {
        lock.lock()
        guard waiting[id] != nil else { lock.unlock(); return false }
        let seed = waiting[id]!.question
        // In balanced mode one user decision applies to all sockets from the
        // same app that arrived while the alert was on screen.
        let ids = self.settings.askPolicy == .everyConnection
            ? [id]
            : waiting.filter { $0.value.question.app == seed.app }.map(\.key)
        let items = ids.compactMap { waiting.removeValue(forKey: $0) }
        let action: NetAction = timedOut ? self.settings.defaultAction : ((answer ?? true) ? .allow : .block)
        if !timedOut { sessionDecisions[seed.app] = action }
        if !timedOut, var chosen, rules.count < 5000 {
            chosen.app = seed.app; chosen.action = action
            rules.append(chosen); saveLocked()
        } else if remember && !timedOut {
            rules.append(NetRule(app: seed.app, host: "*", port: "*", action: action, note: "From a question"))
            saveLocked()
        }
        var verdicts: [(NEFilterFlow, NEFilterNewFlowVerdict)] = []
        for item in items {
            item.timer?.cancel()
            let q = item.question
            let recordID = record(FlowInfo(app: q.app, appName: q.appName, host: q.host, port: q.port, proto: q.proto, outbound: true, team: q.team, valid: q.identity != "Invalid signature", parent: q.parent), action, nil)
            verdicts.append((item.flow, verdict(for: item.flow, action, recordID: recordID)))
        }
        let provider = self.provider
        lock.unlock()
        for (flow, verdict) in verdicts { provider?.resumeFlow(flow, with: verdict) }
        return true
    }
    func releaseAll() {
        saveHistory()
        lock.lock(); let items = waiting; waiting = [:]; lock.unlock()
        for (_, item) in items { item.timer?.cancel(); provider?.resumeFlow(item.flow, with: NEFilterNewFlowVerdict.allow()) }
    }

    // MARK: For the app
    func recent(after id: Int64) -> [FlowRecord] { lock.lock(); defer { lock.unlock() }; return flows.filter { $0.id > id } }
    func clearFlows() { lock.lock(); flows.removeAll(); dirty = true; lock.unlock(); saveHistory() }
    func currentRules() -> [NetRule] { lock.lock(); defer { lock.unlock() }; return rules }
    func setRules(_ new: [NetRule]) { lock.lock(); rules = Array(new.prefix(5000)); sessionDecisions.removeAll(); saveLocked(); lock.unlock() }
    func currentSettings() -> FilterSettings { lock.lock(); defer { lock.unlock() }; return settings }
    func setSettings(_ new: FilterSettings) {
        lock.lock(); settings = new; sessionDecisions.removeAll(); saveLocked()
        let leaving = new.askMode ? [] : Array(waiting.keys)
        lock.unlock()
        for id in leaving { resolve(id, settings: nil, remember: false, timedOut: true) }     // asking was switched off: let waiting connections through by the default
    }
    func currentLists() -> [NetList] { lock.lock(); defer { lock.unlock() }; return lists }
    func setLists(_ new: [NetList]) {
        let built = NetListIndex(new)       // built before taking the lock: a large list takes a moment
        lock.lock(); lists = new; index = built; sessionDecisions.removeAll()
        if let data = try? JSONEncoder().encode(new) { try? data.write(to: listsURL, options: .atomic) }
        lock.unlock()
    }
    func currentUsage() -> FilterUsage { lock.lock(); defer { lock.unlock() }; return usage }
    func pendingQuestions() -> [PendingQuestion] {
        lock.lock(); defer { lock.unlock() }
        let questions = waiting.values.map(\.question).sorted { $0.id < $1.id }
        guard settings.askPolicy == .newApplication else { return questions }
        var seen = Set<String>()
        return questions.filter { seen.insert($0.app).inserted }
    }
}

/// The connection to the app. Only VayuSetu itself, signed by the same team, may connect.
final class FilterService: NSObject, NSXPCListenerDelegate, VayuFilterXPC {
    static let shared = FilterService()
    private var listener: NSXPCListener?
    private let store = FilterStore.shared
    private let encoder = JSONEncoder(), decoder = JSONDecoder()
    private let clientsLock = NSLock()
    private var clientCount = 0
    var hasConnectedClient: Bool { clientsLock.lock(); defer { clientsLock.unlock() }; return clientCount > 0 }

    func start() {
        guard listener == nil else { return }
        let name = ((Bundle.main.object(forInfoDictionaryKey: "NetworkExtension") as? [String: Any])?["NEMachServiceName"] as? String) ?? FilterNames.machService
        let listener = NSXPCListener(machServiceName: name)
        listener.delegate = self
        listener.resume()
        self.listener = listener
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(FilterNames.clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: VayuFilterXPC.self)
        connection.exportedObject = self
        clientsLock.lock(); clientCount += 1; clientsLock.unlock()
        connection.invalidationHandler = { [weak self] in
            guard let self else { return }
            self.clientsLock.lock(); self.clientCount = max(0, self.clientCount - 1)
            let disconnected = self.clientCount == 0
            self.clientsLock.unlock()
            if disconnected { self.store.releaseAll() }
        }
        connection.resume()
        return true
    }
    func recentFlows(after id: Int64, reply: @escaping (Data) -> Void) { reply((try? encoder.encode(store.recent(after: id))) ?? Data("[]".utf8)) }
    func rules(reply: @escaping (Data) -> Void) { reply((try? encoder.encode(store.currentRules())) ?? Data("[]".utf8)) }
    func setRules(_ data: Data, reply: @escaping (Bool) -> Void) {
        guard data.count < 4_000_000, let rules = try? decoder.decode([NetRule].self, from: data) else { reply(false); return }
        store.setRules(rules); reply(true)
    }
    func settings(reply: @escaping (Data) -> Void) { reply((try? encoder.encode(store.currentSettings())) ?? Data()) }
    func setSettings(_ data: Data, reply: @escaping (Bool) -> Void) {
        guard let settings = try? decoder.decode(FilterSettings.self, from: data) else { reply(false); return }
        store.setSettings(settings); reply(true)
    }
    func pending(reply: @escaping (Data) -> Void) { reply((try? encoder.encode(store.pendingQuestions())) ?? Data("[]".utf8)) }
    func answer(_ id: Int64, allow: Bool, remember: Bool, reply: @escaping (Bool) -> Void) { reply(store.resolve(id, settings: allow, remember: remember)) }
    func answerWithRule(_ id: Int64, allow: Bool, rule: Data, reply: @escaping (Bool) -> Void) {
        reply(store.resolve(id, settings: allow, remember: false, rule: try? decoder.decode(NetRule.self, from: rule)))
    }
    func clearFlows(reply: @escaping (Bool) -> Void) { store.clearFlows(); reply(true) }
    func lists(reply: @escaping (Data) -> Void) { reply((try? encoder.encode(store.currentLists())) ?? Data("[]".utf8)) }
    func setLists(_ data: Data, reply: @escaping (Bool) -> Void) {
        guard data.count < 60_000_000, let lists = try? decoder.decode([NetList].self, from: data) else { reply(false); return }
        store.setLists(Array(lists.prefix(50))); reply(true)
    }
    func usage(reply: @escaping (Data) -> Void) { reply((try? encoder.encode(store.currentUsage())) ?? Data("{}".utf8)) }
}

/// Who an app is, from its code signature: the identifier, the team that signed it, and whether the signature is valid.
struct AppDetails { var identifier: String; var team: String?; var valid: Bool; var appleSigned: Bool }

enum AppIdentity {
    private static let logger = Logger(subsystem: "app.vayusetu.macos.filter", category: "identity")
    private static let lock = NSLock()
    private static var cache: [Data: AppDetails] = [:]
    static func details(_ token: Data) -> AppDetails? {
        lock.lock(); if let hit = cache[token] { lock.unlock(); return hit }; lock.unlock()
        var guest: SecCode?
        let guestStatus = SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: token] as CFDictionary, [], &guest)
        guard guestStatus == errSecSuccess, let guest else { logger.error("Guest identity lookup failed: \(guestStatus, privacy: .public)"); return nil }
        let valid = SecCodeCheckValidity(guest, [], nil) == errSecSuccess
        var code: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(guest, [], &code)
        guard staticStatus == errSecSuccess, let code else { logger.error("Static identity lookup failed: \(staticStatus, privacy: .public)"); return nil }
        var info: CFDictionary?
        let signingStatus = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        guard signingStatus == errSecSuccess,
              let dictionary = info as? [String: Any], let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String else { logger.error("Signing identity unavailable: \(signingStatus, privacy: .public)"); return nil }
        var appleRequirement: SecRequirement?
        let appleSigned = SecRequirementCreateWithString("anchor apple" as CFString, [], &appleRequirement) == errSecSuccess &&
            appleRequirement.map { SecCodeCheckValidity(guest, [], $0) == errSecSuccess } == true
        let found = AppDetails(identifier: identifier, team: dictionary[kSecCodeInfoTeamIdentifier as String] as? String, valid: valid, appleSigned: appleSigned)
        lock.lock(); if cache.count > 800 { cache.removeAll() }; cache[token] = found; lock.unlock()
        return found
    }
    /// The name of the process that started this one, for example Terminal for a command run from a shell.
    static func parentName(of pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size), info.pbi_ppid > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(Int32(info.pbi_ppid), &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return (String(cString: buffer) as NSString).lastPathComponent
    }
}
