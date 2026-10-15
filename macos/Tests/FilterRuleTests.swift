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
        print("Filter rule checks passed: \(count)")
    }
}
