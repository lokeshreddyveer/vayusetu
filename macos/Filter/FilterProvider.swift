import Darwin
import Foundation
import Network
import NetworkExtension
import Security

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

    /// Who is connecting, and to where.
    static func describe(_ flow: NEFilterSocketFlow) -> FlowInfo {
        var app = "unknown"
        var name = "unknown"
        var team: String?
        var valid = true
        var parent: String?
        if let token = flow.sourceAppAuditToken, token.count == MemoryLayout<audit_token_t>.size {
            let pid = token.withUnsafeBytes { $0.load(fromByteOffset: 20, as: Int32.self) }     // audit_token_t.val[5]
            var buffer = [CChar](repeating: 0, count: 4096)
            if pid > 0, proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 { name = (String(cString: buffer) as NSString).lastPathComponent }
            if let details = AppIdentity.details(token) { app = details.identifier; team = details.team; valid = details.valid } else { app = name }
            if name == "unknown" { name = app }
            parent = AppIdentity.parentName(of: pid)
        }
        var host = flow.remoteHostname ?? ""
        var port = ""
        if #available(macOS 15.0, *), let endpoint = flow.remoteFlowEndpoint {
            if case let .hostPort(h, p) = endpoint { if host.isEmpty { host = "\(h)" }; port = "\(p.rawValue)" }
        } else if let endpoint = flow.remoteEndpoint as? NWHostEndpoint {
            if host.isEmpty { host = endpoint.hostname }; port = endpoint.port
        }
        let proto: String
        switch flow.socketProtocol { case IPPROTO_TCP: proto = "TCP"; case IPPROTO_UDP: proto = "UDP"; case let other: proto = "IP \(other)" }
        return FlowInfo(app: app, appName: name, host: host.isEmpty ? "unknown" : NetRuleEngine.normalise(host), port: port, proto: proto, outbound: flow.direction != .inbound, team: team, valid: valid, parent: parent)
    }
}

struct FlowInfo { var app: String, appName: String, host: String, port: String, proto: String, outbound: Bool; var team: String? = nil; var valid = true; var parent: String? = nil }

/// All the filter's state, behind one lock: the rules, the settings, the recent connections and the connections waiting for an answer.
final class FilterStore {
    static let shared = FilterStore()
    weak var provider: NEFilterDataProvider?
    private let lock = NSLock()
    private var rules: [NetRule] = []
    private var settings = FilterSettings()
    private var flows: [FlowRecord] = []
    private var nextID: Int64 = 1
    private struct Waiting { var flow: NEFilterFlow; var question: PendingQuestion; var timer: DispatchSourceTimer }
    private var waiting: [Int64: Waiting] = [:]
    private let maximumFlows = 5000
    private var teams: [String: String] = [:]          // the signer first seen for each app, to notice a change
    private var dirty = false
    private var historyTimer: DispatchSourceTimer?

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VayuSetuFilter", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("filter.json")
    }
    private var historyURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("history.json") }
    private struct Saved: Codable { var rules: [NetRule]; var settings: FilterSettings; var teams: [String: String]? = nil }
    func load() {
        lock.lock(); defer { lock.unlock() }
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(Saved.self, from: data) { rules = saved.rules; settings = saved.settings; teams = saved.teams ?? [:] }
        if flows.isEmpty, let data = try? Data(contentsOf: historyURL), let old = try? JSONDecoder().decode([FlowRecord].self, from: data) {
            flows = Array(old.suffix(maximumFlows)); nextID = (flows.map(\.id).max() ?? 0) + 1
        }
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
        lock.lock(); guard dirty else { lock.unlock(); return }; dirty = false; let snapshot = flows; lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: historyURL, options: .atomic) }
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
    func decide(_ flow: NEFilterFlow, _ info: FlowInfo) -> NEFilterNewFlowVerdict {
        lock.lock(); defer { lock.unlock() }
        if NetRuleEngine.isExempt(app: info.app, host: info.host) { record(info, .allow, nil); return .allow() }
        let decision = NetRuleEngine.decide(app: info.app, host: info.host, port: info.port, rules: rules, settings: settings)
        if settings.askMode && decision.rule == nil && info.outbound { return askLocked(flow, info) }
        record(info, decision.action, decision.rule?.id)
        return decision.action == .block ? .drop() : .allow()
    }
    private func record(_ info: FlowInfo, _ verdict: NetAction, _ rule: UUID?) {
        let id = nextID; nextID += 1; dirty = true
        flows.append(FlowRecord(id: id, time: Date(), app: info.app, appName: info.appName, host: info.host, port: info.port, proto: info.proto, outbound: info.outbound, verdict: verdict, rule: rule, team: info.team, identity: identityNote(info), parent: info.parent))
        if flows.count > maximumFlows { flows.removeFirst(flows.count - maximumFlows) }
    }

    // MARK: Asking
    private func askLocked(_ flow: NEFilterFlow, _ info: FlowInfo) -> NEFilterNewFlowVerdict {
        let id = nextID; nextID += 1
        let question = PendingQuestion(id: id, time: Date(), app: info.app, appName: info.appName, host: info.host, port: info.port, proto: info.proto, team: info.team, identity: identityNote(info), parent: info.parent)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + .seconds(max(5, settings.askTimeout)))
        timer.setEventHandler { [weak self] in self?.resolve(id, settings: nil, remember: false, timedOut: true) }
        waiting[id] = Waiting(flow: flow, question: question, timer: timer)
        timer.resume()
        return .pause()
    }
    /// Answers a waiting connection. `allow == nil` means the question timed out and the default action applies.
    @discardableResult func resolve(_ id: Int64, settings answer: Bool?, remember: Bool, timedOut: Bool = false) -> Bool {
        lock.lock()
        guard let item = waiting.removeValue(forKey: id) else { lock.unlock(); return false }
        item.timer.cancel()
        let action: NetAction = timedOut ? settings.defaultAction : ((answer ?? true) ? .allow : .block)
        let q = item.question
        if remember && !timedOut {
            rules.append(NetRule(app: q.app, host: q.host, port: "*", action: action, note: "From a question"))
            saveLocked()
        }
        record(FlowInfo(app: q.app, appName: q.appName, host: q.host, port: q.port, proto: q.proto, outbound: true, team: q.team, valid: q.identity != "Invalid signature", parent: q.parent), action, nil)
        let provider = self.provider
        lock.unlock()
        provider?.resumeFlow(item.flow, with: action == .block ? NEFilterNewFlowVerdict.drop() : NEFilterNewFlowVerdict.allow())
        return true
    }
    func releaseAll() {
        saveHistory()
        lock.lock(); let items = waiting; waiting = [:]; lock.unlock()
        for (_, item) in items { item.timer.cancel(); provider?.resumeFlow(item.flow, with: NEFilterNewFlowVerdict.allow()) }
    }

    // MARK: For the app
    func recent(after id: Int64) -> [FlowRecord] { lock.lock(); defer { lock.unlock() }; return flows.filter { $0.id > id } }
    func clearFlows() { lock.lock(); flows.removeAll(); dirty = true; lock.unlock(); saveHistory() }
    func currentRules() -> [NetRule] { lock.lock(); defer { lock.unlock() }; return rules }
    func setRules(_ new: [NetRule]) { lock.lock(); rules = Array(new.prefix(5000)); saveLocked(); lock.unlock() }
    func currentSettings() -> FilterSettings { lock.lock(); defer { lock.unlock() }; return settings }
    func setSettings(_ new: FilterSettings) {
        lock.lock(); settings = new; saveLocked()
        let leaving = new.askMode ? [] : Array(waiting.keys)
        lock.unlock()
        for id in leaving { resolve(id, settings: nil, remember: false, timedOut: true) }     // asking was switched off: let waiting connections through by the default
    }
    func pendingQuestions() -> [PendingQuestion] { lock.lock(); defer { lock.unlock() }; return waiting.values.map(\.question).sorted { $0.id < $1.id } }
}

/// The connection to the app. Only VayuSetu itself, signed by the same team, may connect.
final class FilterService: NSObject, NSXPCListenerDelegate, VayuFilterXPC {
    static let shared = FilterService()
    private var listener: NSXPCListener?
    private let store = FilterStore.shared
    private let encoder = JSONEncoder(), decoder = JSONDecoder()

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
    func clearFlows(reply: @escaping (Bool) -> Void) { store.clearFlows(); reply(true) }
}

/// Who an app is, from its code signature: the identifier, the team that signed it, and whether the signature is valid.
struct AppDetails { var identifier: String; var team: String?; var valid: Bool }

enum AppIdentity {
    private static let lock = NSLock()
    private static var cache: [Data: AppDetails] = [:]
    static func details(_ token: Data) -> AppDetails? {
        lock.lock(); if let hit = cache[token] { lock.unlock(); return hit }; lock.unlock()
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: token] as CFDictionary, [], &guest) == errSecSuccess, let guest else { return nil }
        let valid = SecCodeCheckValidity(guest, [], nil) == errSecSuccess
        var code: SecStaticCode?
        guard SecCodeCopyStaticCode(guest, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any], let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String else { return nil }
        let found = AppDetails(identifier: identifier, team: dictionary[kSecCodeInfoTeamIdentifier as String] as? String, valid: valid)
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
