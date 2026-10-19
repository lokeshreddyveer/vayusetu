import Foundation
import NetworkExtension

/// A flow built by hand has no system identifier, so give it one.
final class TestFlow: NEFilterFlow {
    private let own = UUID()
    override var identifier: UUID { own }
}

@main enum FilterProviderTests {
    static var count = 0
    static func check(_ value: Bool, _ line: Int = #line) { precondition(value, "Provider check failed at \(line)"); count += 1 }
    static func main() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        func store(_ name: String, connected: Bool = true) -> FilterStore {
            let folder = base.appendingPathComponent(name)       // one folder per store: it keeps its lists and usage beside its rules
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return FilterStore(storageURL: folder.appendingPathComponent("filter.json"), clientAvailable: { connected })
        }
        let info = FlowInfo(app: "test.application", appName: "Test", host: "example.com", port: "443", proto: "TCP", outbound: true)
        let s = store("balanced")
        for _ in 0..<331 { _ = s.decide(NEFilterFlow(), info) }
        check(s.pendingQuestions().count == 1)
        check(s.resolve(s.pendingQuestions()[0].id, settings: false, remember: true))
        check(s.pendingQuestions().isEmpty)
        check(s.currentRules().count == 1 && s.currentRules()[0].action == .block)
        _ = s.decide(NEFilterFlow(), info)
        check(s.pendingQuestions().isEmpty && s.recent(after: 0).last?.verdict == .block)
        // Explicit blocks override the trusted-system baseline.
        var apple = info; apple.app = "com.apple.test"; apple.appleSigned = true
        s.setRules([NetRule(app: apple.app, host: "*", port: "*", action: .block)])
        _ = s.decide(NEFilterFlow(), apple)
        check(s.recent(after: 0).last?.verdict == .block)
        // An identifier that looks like a system app conveys no trust.
        let spoof = store("spoof")
        apple.appleSigned = false
        _ = spoof.decide(NEFilterFlow(), apple)
        check(spoof.pendingQuestions().count == 1)
        // GUI unavailable: no orphaned paused flows.
        let unattended = store("unattended", connected: false)
        _ = unattended.decide(NEFilterFlow(), info)
        check(unattended.pendingQuestions().isEmpty && unattended.recent(after: 0).last?.verdict == .allow)
        // Switching approval off resolves all existing questions.
        var settings = FilterSettings(); settings.askMode = false
        spoof.setSettings(settings)
        check(spoof.pendingQuestions().isEmpty)
        // Changing a rule invalidates an earlier session-only response.
        let session = store("session")
        _ = session.decide(NEFilterFlow(), info)
        _ = session.resolve(session.pendingQuestions()[0].id, settings: true, remember: false)
        session.setRules([])
        _ = session.decide(NEFilterFlow(), info)
        check(session.pendingQuestions().count == 1)
        // Block lists beat an ordinary allow rule; a rule that names the app and allows it wins.
        let lists = store("lists")
        lists.setSettings({ var x = FilterSettings(); x.askMode = false; return x }())
        lists.setLists([NetList(name: "Ads", kind: .block, entries: ["ads.example.com"]), NetList(name: "Mine", kind: .allow, entries: ["fine.example.com"])])
        var adHost = info; adHost.host = "cdn.ads.example.com"
        _ = lists.decide(NEFilterFlow(), adHost)
        check(lists.recent(after: 0).last?.verdict == .block && lists.recent(after: 0).last?.list == "Ads")
        lists.setRules([NetRule(app: "*", host: "ads.example.com", port: "*", action: .allow)])
        _ = lists.decide(NEFilterFlow(), adHost)
        check(lists.recent(after: 0).last?.verdict == .block)
        lists.setRules([NetRule(app: info.app, host: "ads.example.com", port: "*", action: .allow)])
        _ = lists.decide(NEFilterFlow(), adHost)
        check(lists.recent(after: 0).last?.verdict == .allow)
        check(lists.currentUsage().lists["Ads"]?.count == 2)
        // An allow list lets a connection through without a question, and records which list did.
        let asking = store("asking")
        asking.setLists([NetList(name: "Mine", kind: .allow, entries: ["fine.example.com"])])
        var fine = info; fine.host = "fine.example.com"
        _ = asking.decide(NEFilterFlow(), fine)
        check(asking.pendingQuestions().isEmpty && asking.recent(after: 0).last?.list == "Mine")
        // Block-all: everything blocked except an allow list or an allow rule.
        let lockdown = store("lockdown")
        lockdown.setSettings({ var x = FilterSettings(); x.mode = .blockAll; return x }())
        lockdown.setLists([NetList(name: "Mine", kind: .allow, entries: ["fine.example.com"])])
        lockdown.setRules([NetRule(app: info.app, host: "ruled.example.com", port: "*", action: .allow)])
        var ruled = info; ruled.host = "ruled.example.com"
        _ = lockdown.decide(NEFilterFlow(), info); check(lockdown.recent(after: 0).last?.verdict == .block)
        _ = lockdown.decide(NEFilterFlow(), fine); check(lockdown.recent(after: 0).last?.verdict == .allow)
        _ = lockdown.decide(NEFilterFlow(), ruled); check(lockdown.recent(after: 0).last?.verdict == .allow)
        var appleApp = info; appleApp.appleSigned = true
        _ = lockdown.decide(NEFilterFlow(), appleApp); check(lockdown.recent(after: 0).last?.verdict == .block)
        check(lockdown.pendingQuestions().isEmpty)
        // Passive: no questions; the choice is saved as a rule once per app, and rules still win.
        let quiet = store("quiet")
        quiet.setSettings({ var x = FilterSettings(); x.mode = .passive; x.passiveAction = .block; return x }())
        _ = quiet.decide(NEFilterFlow(), info)
        check(quiet.pendingQuestions().isEmpty && quiet.recent(after: 0).last?.verdict == .block && quiet.currentRules().count == 1 && quiet.currentRules()[0].group == "Passive")
        _ = quiet.decide(NEFilterFlow(), info)
        check(quiet.currentRules().count == 1 && quiet.currentUsage().rules[quiet.currentRules()[0].id.uuidString]?.count == 2)
        quiet.setRules([NetRule(app: info.app, host: "*", port: "*", action: .allow)])
        _ = quiet.decide(NEFilterFlow(), info); check(quiet.recent(after: 0).last?.verdict == .allow)
        // Passive without saved rules; and the Apple-signed switch.
        let forgetful = store("forgetful")
        forgetful.setSettings({ var x = FilterSettings(); x.mode = .passive; x.passiveCreatesRules = false; return x }())
        _ = forgetful.decide(NEFilterFlow(), info); check(forgetful.currentRules().isEmpty)
        let strict = store("strict")
        strict.setSettings({ var x = FilterSettings(); x.allowAppleSigned = false; return x }())
        _ = strict.decide(NEFilterFlow(), appleApp)
        check(strict.pendingQuestions().count == 1)
        // Incoming connections follow their own setting and are never asked about.
        let inbound = store("inbound")
        var incoming = info; incoming.outbound = false
        _ = inbound.decide(NEFilterFlow(), incoming); check(inbound.recent(after: 0).last?.verdict == .allow && inbound.pendingQuestions().isEmpty)
        inbound.setSettings({ var x = FilterSettings(); x.inboundAction = .block; return x }())
        _ = inbound.decide(NEFilterFlow(), incoming); check(inbound.recent(after: 0).last?.verdict == .block)
        _ = inbound.decide(NEFilterFlow(), info); check(inbound.pendingQuestions().count == 1)
        // Byte counting adds to the right history entry, and only when switched on.
        let counting = store("counting")
        counting.setSettings({ var x = FilterSettings(); x.askMode = false; x.countTraffic = true; return x }())
        let flowA = TestFlow(), flowB = TestFlow()
        _ = counting.decide(flowA, info); _ = counting.decide(flowB, info)
        counting.addBytes(flowA, inbound: true, count: 1000); counting.addBytes(flowA, inbound: false, count: 50); counting.addBytes(flowB, inbound: true, count: 7)
        let seen = counting.recent(after: 0)
        check(seen[0].bytesIn == 1000 && seen[0].bytesOut == 50 && seen[1].bytesIn == 7 && seen[1].bytesOut == nil)
        let uncounted = store("uncounted"); uncounted.setSettings({ var x = FilterSettings(); x.askMode = false; return x }())
        let flowC = TestFlow(); _ = uncounted.decide(flowC, info); uncounted.addBytes(flowC, inbound: true, count: 9)
        check(uncounted.recent(after: 0).last?.bytesIn == nil)
        // Lists and usage survive a restart.
        let reloaded = store("lists"); reloaded.load()
        check(reloaded.currentLists().count == 2)
        // A scoped answer keeps the chosen rule; a session rule does not survive a restart.
        let scoped = store("scoped")
        _ = scoped.decide(NEFilterFlow(), info)
        let ask = scoped.pendingQuestions()[0]
        check(scoped.resolve(ask.id, settings: false, remember: false, rule: AlertRule.make(for: ask, allow: false, scope: .domain, lifetime: .forever)))
        check(scoped.currentRules().count == 1 && scoped.currentRules()[0].host == "example.com" && scoped.currentRules()[0].app == info.app)
        let sessioned = store("sessioned")
        _ = sessioned.decide(NEFilterFlow(), info)
        let ask2 = sessioned.pendingQuestions()[0]
        check(sessioned.resolve(ask2.id, settings: true, remember: false, rule: AlertRule.make(for: ask2, allow: true, scope: .app, lifetime: .restart)))
        check(sessioned.currentRules().count == 1)
        let afterRestart = store("sessioned"); afterRestart.load()
        check(afterRestart.currentRules().isEmpty)
        print("Filter provider checks passed: \(count)")
    }
}
