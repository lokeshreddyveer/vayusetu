import Foundation

@main enum FilterRuleTests {
    static var count = 0
    static func check(_ condition: Bool, _ line: Int = #line) { if !condition { fatalError("FilterRuleTests failed at line \(line)") }; count += 1 }
    static func rule(_ app: String, _ host: String, port: String = "*", _ action: NetAction) -> NetRule { NetRule(app: app, host: host, port: port, action: action) }
    static func main() throws {
        let allowAll = FilterSettings()
        var denyAll = FilterSettings(); denyAll.defaultAction = .block
        func decide(_ app: String, _ host: String, _ rules: [NetRule], port: String = "443", _ s: FilterSettings = allowAll) -> NetAction { NetRuleEngine.decide(app: app, host: host, port: port, rules: rules, settings: s).action }

        // No rules: the default applies
        check(decide("com.apple.Safari", "example.com", []) == .allow && decide("com.apple.Safari", "example.com", [], denyAll) == .block)
        // An app rule applies to that app only
        let appBlock = [rule("com.evil.app", "*", .block)]
        check(decide("com.evil.app", "example.com", appBlock) == .block && decide("com.apple.Safari", "example.com", appBlock) == .allow)
        // A domain rule covers subdomains on whole labels
        let domain = [rule("*", "tracker.net", .block)]
        check(decide("a", "tracker.net", domain) == .block && decide("a", "x.y.tracker.net", domain) == .block)
        check(decide("a", "nottracker.net", domain) == .allow && decide("a", "tracker.net.evil.com", domain) == .allow)
        // An address matches only itself
        let address = [rule("*", "93.184.216.34", .block)]
        check(decide("a", "93.184.216.34", address) == .block && decide("a", "93.184.216.35", address) == .allow && decide("a", "x.93.184.216.34", address) == .allow)
        // Ports
        let portRule = [rule("*", "*", port: "25", .block)]
        check(decide("a", "mail.example.com", portRule, port: "25") == .block && decide("a", "mail.example.com", portRule, port: "587") == .allow)
        // The most specific rule wins: an app allowed to reach a blocked domain
        let specific = [rule("*", "tracker.net", .block), rule("com.good.app", "tracker.net", .allow)]
        check(decide("com.good.app", "tracker.net", specific) == .allow && decide("com.other.app", "tracker.net", specific) == .block)
        // Under a block-everything default, an allow for one app and one domain gets through
        let lockdown = [rule("com.apple.Safari", "example.com", port: "443", .allow)]
        check(decide("com.apple.Safari", "example.com", lockdown, denyAll) == .allow && decide("com.apple.Safari", "other.com", lockdown, denyAll) == .block)
        // At equal specificity a block beats an allow, whatever the order
        let tie1 = [rule("*", "example.com", .allow), rule("*", "example.com", .block)], tie2 = Array(tie1.reversed())
        check(decide("a", "example.com", tie1) == .block && decide("a", "example.com", tie2) == .block)
        // The deciding rule is reported
        let chosen = NetRuleEngine.decide(app: "a", host: "x.tracker.net", port: "80", rules: domain, settings: allowAll)
        check(chosen.rule?.id == domain[0].id && NetRuleEngine.decide(app: "a", host: "ok.com", port: "80", rules: domain, settings: allowAll).rule == nil)
        // Normalisation: case, a trailing dot and an IPv6 scope
        check(decide("a", "X.Tracker.NET.", domain) == .block)
        check(NetRuleEngine.hostMatches("fe80::1", "fe80::1%en0") && NetRuleEngine.isAddress("2001:db8::1") && !NetRuleEngine.isAddress("example.com"))
        // Exemptions: our own apps and this Mac
        check(NetRuleEngine.isExempt(app: "app.vayusetu.macos", host: "1.2.3.4") && NetRuleEngine.isExempt(app: "app.vayusetu.macos.filter", host: "x"))
        check(NetRuleEngine.isExempt(app: "com.apple.Safari", host: "127.0.0.1") && NetRuleEngine.isExempt(app: "x", host: "::1") && NetRuleEngine.isExempt(app: "x", host: "localhost"))
        check(!NetRuleEngine.isExempt(app: "com.apple.Safari", host: "example.com") && !NetRuleEngine.isExempt(app: "app.vayusetuevil", host: "example.com"))
        // Rules and records survive the wire format
        let wire = try JSONDecoder().decode([NetRule].self, from: JSONEncoder().encode(specific))
        check(wire == specific)
        let record = FlowRecord(id: 7, time: Date(timeIntervalSince1970: 1_700_000_000), app: "a", appName: "A", host: "h", port: "1", proto: "TCP", outbound: true, verdict: .block, rule: specific[0].id)
        check(try JSONDecoder().decode(FlowRecord.self, from: JSONEncoder().encode(record)) == record)
        // Expiry: a time-limited allow stops counting once it has run out
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var temporary = rule("com.good.app", "tracker.net", .allow); temporary.expires = now.addingTimeInterval(3600)
        let withTemporary = [rule("*", "tracker.net", .block), temporary]
        func at(_ date: Date, _ rules: [NetRule], _ s: FilterSettings = allowAll) -> NetAction { NetRuleEngine.decide(app: "com.good.app", host: "tracker.net", port: "443", rules: rules, settings: s, now: date).action }
        check(at(now, withTemporary) == .allow && at(now.addingTimeInterval(3599), withTemporary) == .allow)
        check(at(now.addingTimeInterval(3600), withTemporary) == .block && at(now.addingTimeInterval(86_400), withTemporary) == .block)
        // Groups: a switched-off group is ignored, other groups still apply
        var work = rule("*", "tracker.net", .block); work.group = "Work"
        var grouped = FilterSettings(); grouped.disabledGroups = ["Work"]
        check(at(now, [work]) == .block && at(now, [work], grouped) == .allow)
        check(at(now, [rule("*", "tracker.net", .block)], grouped) == .block)                       // the default group is unaffected
        // Schedules, in a fixed calendar and time zone so the test does not depend on this Mac
        var gregorian = Calendar(identifier: .gregorian); gregorian.timeZone = TimeZone(identifier: "UTC")!
        func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date { gregorian.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))! }
        // 2026-10-12 is a Monday (weekday 2); 2026-10-17 is a Saturday (weekday 7)
        let office = NetSchedule(days: [2, 3, 4, 5, 6], start: 9 * 60, end: 17 * 60)
        check(office.contains(date(2026, 10, 12, 9, 0), calendar: gregorian) && office.contains(date(2026, 10, 12, 16, 59), calendar: gregorian))
        check(!office.contains(date(2026, 10, 12, 17, 0), calendar: gregorian) && !office.contains(date(2026, 10, 12, 8, 59), calendar: gregorian))
        check(!office.contains(date(2026, 10, 17, 12, 0), calendar: gregorian))                       // a Saturday
        let night = NetSchedule(days: [6], start: 22 * 60, end: 6 * 60)                               // Friday 22:00 to Saturday 06:00
        check(night.contains(date(2026, 10, 16, 23, 0), calendar: gregorian) && night.contains(date(2026, 10, 17, 5, 59), calendar: gregorian))
        check(!night.contains(date(2026, 10, 17, 6, 0), calendar: gregorian) && !night.contains(date(2026, 10, 16, 21, 59), calendar: gregorian) && !night.contains(date(2026, 10, 18, 3, 0), calendar: gregorian))
        check(NetSchedule(days: [2], start: 0, end: 0).contains(date(2026, 10, 12, 13, 0), calendar: gregorian))     // equal start and end: the whole day
        // Backward compatibility: rules, settings and records saved by an earlier build still load
        let oldRule = Data(#"{"id":"00000000-0000-0000-0000-000000000001","app":"*","host":"x.com","port":"*","action":"block","created":0,"note":""}"#.utf8)
        let loaded = try JSONDecoder().decode(NetRule.self, from: oldRule)
        check(loaded.group == nil && loaded.groupName == "Default" && loaded.expires == nil && loaded.schedule == nil)
        let oldSettings = Data(#"{"askMode":true,"defaultAction":"allow","askTimeout":20}"#.utf8)
        check(try JSONDecoder().decode(FilterSettings.self, from: oldSettings).disabledGroups == nil)
        let oldFlow = Data(#"{"id":1,"time":0,"app":"a","appName":"A","host":"h","port":"1","proto":"TCP","outbound":true,"verdict":"allow"}"#.utf8)
        check(try JSONDecoder().decode(FlowRecord.self, from: oldFlow).identity == nil)
        // New fields survive the wire format
        var full = rule("com.apple.Safari", "example.com", .block); full.group = "Work"; full.expires = now; full.schedule = office
        check(try JSONDecoder().decode(NetRule.self, from: JSONEncoder().encode(full)) == full)
        print("Filter rule checks passed: \(count)")
    }
}
