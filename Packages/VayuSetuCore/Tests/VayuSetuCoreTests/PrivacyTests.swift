import XCTest
@testable import VayuSetuCore

final class PrivacyTests: XCTestCase {
    func rule(_ domain: String, _ action: FilterAction = .block, _ scope: FilterScope = .domainAndSubdomains, _ tier: FilterTier = .user, id: String = "test") throws -> FilterRule {
        try FilterRule(id: id, domain: domain, action: action, scope: scope, tier: tier, source: tier == .user ? "User" : "List")
    }
    func testUserAllowOverridesMoreSpecificSubscription() throws {
        let rules = try [rule("example.com", .allow), rule("ads.example.com", .block, .exact, .subscription)]
        XCTAssertEqual(try RuleEngine.match("ads.example.com", rules: rules)?.rule.action, .allow)
    }
    func testExactUserBlockOverridesBroadUserAllow() throws {
        let rules = try [rule("example.com", .allow), rule("ads.example.com", .block, .exact)]
        XCTAssertEqual(try RuleEngine.match("ads.example.com", rules: rules)?.rule.action, .block)
        XCTAssertEqual(try RuleEngine.match("cdn.example.com", rules: rules)?.rule.action, .allow)
    }
    func testLongestSuffixAndAllowTies() throws {
        let rules = try [rule("example.com"), rule("cdn.example.com", .allow), rule("cdn.example.com", .block, id: "second")]
        XCTAssertEqual(try RuleEngine.match("img.cdn.example.com", rules: rules)?.rule.action, .allow)
        XCTAssertNil(try RuleEngine.match("notexample.com", rules: rules))
    }
    func testStableSourceAndIDOrdering() throws {
        let a = try rule("example.com", id: "a"); let b = try rule("example.com", id: "b")
        XCTAssertEqual(try RuleEngine.match("example.com", rules: [a,b])?.rule.id, try RuleEngine.match("example.com", rules: [b,a])?.rule.id)
    }
    func testIDNAAndPublicSuffixSafety() throws {
        XCTAssertEqual(try FilterDomain.normalize("BÜCHER.de"), "xn--bcher-kva.de")
        for value in ["com", "co.uk", "github.io", "127.0.0.1", "a..com", "*.example.com", "user@example.com", "example.com/path", "example.com:443"] { XCTAssertThrowsError(try FilterDomain.normalize(value), value) }
        XCTAssertEqual(try FilterDomain.normalize("safe.github.io"), "safe.github.io")
        XCTAssertThrowsError(try FilterDomain.normalize("test.ck")) // PSL wildcard
        XCTAssertEqual(try FilterDomain.normalize("www.ck"), "www.ck") // PSL exception
    }
    func testHostsExactAndABPScopePreserved() throws {
        let result = try FilterParser.parse(Data("0.0.0.0 ads.example.com tracker.example.com # note\n||example.org^\n@@||safe.example.org^\nfoo.com$script\n".utf8), source: "fixture")
        XCTAssertEqual(result.rules.count, 4); XCTAssertEqual(result.rejected, 1)
        XCTAssertFalse(result.rules[0].matches("sub.ads.example.com"))
        XCTAssertEqual(result.rules[0].scope, .exact)
        XCTAssertTrue(result.rules[2].matches("sub.example.org"))
        XCTAssertEqual(result.rules[3].action, .allow)
    }
    func testMalformedOrEmptyImportDoesNotProducePackage() throws {
        XCTAssertThrowsError(try FilterParser.parse(Data("<html>error</html>".utf8), source: "fixture"))
        XCTAssertThrowsError(try FilterParser.parse(Data(repeating: 65, count: FilterParser.byteLimit + 1), source: "fixture"))
        XCTAssertThrowsError(try FilterParser.parse(Data([0xff,0xfe]), source: "fixture"))
    }
    func testSafariCompilerMatchesExactAndSubdomainScopes() throws {
        let rules = try [rule("example.com"), rule("example.org", .block, .exact)]
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: SafariRuleCompiler.compile(rules)) as? [[String: Any]])
        for row in json {
            let trigger = try XCTUnwrap(row["trigger"] as? [String:Any]); let pattern = try XCTUnwrap(trigger["url-filter"] as? String)
            let regex = try NSRegularExpression(pattern: pattern)
            func matches(_ text: String) -> Bool { regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
            if pattern.contains("com") { XCTAssertTrue(matches("https://cdn.example.com:443/path")); XCTAssertFalse(matches("https://notexample.com/")); XCTAssertFalse(matches("https://example.com.evil.org/")) }
            else { XCTAssertTrue(matches("https://example.org/")); XCTAssertFalse(matches("https://sub.example.org/")) }
        }
    }
    func testSafariCompilerUsesSamePrecedenceAsPreview() throws {
        let rules = try [rule("ads.example.com", .block, .exact), rule("example.com", .allow), rule("ads.example.com", .block, .exact, .subscription)]
        let compiled = try XCTUnwrap(JSONSerialization.jsonObject(with: SafariRuleCompiler.compile(rules)) as? [[String: Any]])
        let types = compiled.compactMap { ($0["action"] as? [String:String])?["type"] }
        XCTAssertEqual(types, ["block", "ignore-previous-rules", "block"])
    }
    func testBudgetFailsWithoutTruncation() throws {
        let value = try rule("example.com")
        XCTAssertThrowsError(try SafariRuleCompiler.compile(Array(repeating: value, count: FilterParser.domainLimit + 1)))
        let disabled = try XCTUnwrap(JSONSerialization.jsonObject(with: SafariRuleCompiler.compile([])) as? [[String:Any]])
        XCTAssertEqual((disabled.first?["trigger"] as? [String:String])?["url-filter"], SafariRuleCompiler.placeholderFilter)
    }
    func testUnknownIsDistinctAndStaleGreenExpires() {
        let now = Date()
        let active = ProtectionSnapshot(.safari, desired: true, state: .active, source: .osStatus, at: now.addingTimeInterval(-120), reason: "Enabled")
        let stale = PrivacyIntegrityEngine.reconcile(active, now: now)
        XCTAssertEqual(stale.observed, .enabledNotVerified); XCTAssertTrue(stale.stale)
        XCTAssertEqual(ProtectionSnapshot(.dns, desired: nil, state: .unknown, source: .unavailable, reason: "Unknown").label, "Unknown")
        XCTAssertEqual(ProtectionSnapshot(.safari, desired: true, state: .active, source: .osStatus, at: now, reason: "Enabled").label, "Enabled")
        let intentOnly = ProtectionSnapshot(.vpn, desired: true, state: .active, source: .userPreference, at: now, reason: "Toggle")
        XCTAssertEqual(PrivacyIntegrityEngine.reconcile(intentOnly, now: now).observed, .enabledNotVerified)
        let noEvidence = ProtectionSnapshot(.vpn, desired: true, state: .active, source: .userPreference, reason: "Toggle")
        XCTAssertEqual(PrivacyIntegrityEngine.reconcile(noEvidence, now: now).observed, .enabledNotVerified)
    }
    func testUnboundedSessionDays() {
        XCTAssertEqual(SessionClock.format(seconds: 0), "00:00:00:00")
        XCTAssertEqual(SessionClock.format(seconds: 100*86400+3661), "100:01:01:01")
        XCTAssertEqual(SessionClock.format(seconds: -1), "00:00:00:00")
    }
    func testDisabledRuleNeverOverridesActiveRuleAndLegacyDefaultsEnabled() throws {
        let block = try FilterRule(domain: "example.com", action: .block, scope: .domainAndSubdomains)
        let disabledAllow = try FilterRule(domain: "ads.example.com", action: .allow, scope: .exact, enabled: false)
        XCTAssertEqual(try RuleEngine.match("ads.example.com", rules: [block, disabledAllow])?.rule.action, .block)
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(block)) as? [String:Any])
        encoded.removeValue(forKey: "enabled")
        let legacy = try JSONDecoder().decode(FilterRule.self, from: JSONSerialization.data(withJSONObject: encoded))
        XCTAssertNotEqual(legacy.enabled, false)
        XCTAssertEqual(try RuleEngine.match("example.com", rules: [legacy])?.rule.action, .block)
    }

    func testFullLargeListPreservesEveryDomainAndUsesSupportedRegex() throws {
        let values = try (0..<55_500).map { try FilterRule(domain: "ad\($0).example.com", action: .block, scope: .domainAndSubdomains, tier: .subscription) }
        let compiled = try XCTUnwrap(JSONSerialization.jsonObject(with: SafariRuleCompiler.compile(values)) as? [[String:Any]])
        XCTAssertEqual(compiled.count, values.count)
        let patterns = compiled.compactMap { ($0["trigger"] as? [String:Any])?["url-filter"] as? String }
        let combined = patterns.joined()
        let extractor = try NSRegularExpression(pattern: "ad[0-9]+\\\\.example\\\\.com")
        let matches = extractor.matches(in: combined, range: NSRange(combined.startIndex..., in: combined))
        let recovered = Set(matches.compactMap { Range($0.range, in: combined).map { String(combined[$0]).replacingOccurrences(of: "\\.", with: ".") } })
        XCTAssertEqual(recovered, Set(values.map(\.domain)))
        let first = try NSRegularExpression(pattern: patterns[0])
        XCTAssertNil(first.firstMatch(in: "https://evil.example.org/", range: NSRange("https://evil.example.org/".startIndex..., in: "https://evil.example.org/")))
    }

}
