import Foundation

@main struct SafariPlannerTests {
    static var count = 0
    static func check(_ condition: Bool, _ line: Int = #line) { if !condition { fatalError("SafariPlannerTests failed at line \(line)") }; count += 1 }
    static func rule(_ d: String, _ a: FilterAction = .block, _ t: FilterTier = .subscription) -> FilterRule { try! FilterRule(domain: d, action: a, scope: .domainAndSubdomains, tier: t, source: "t") }
    static func url(_ name: String) -> String { FilterCatalog.all.first { $0.name == name }!.url }
    static func main() {
        // Ownership comes from the catalogue category and a few named lists
        func owner(_ name: String) -> SafariExtensionID { let e = FilterCatalog.all.first { $0.name == name }!; return SafariRulesetPlanner.owner(ofListNamed: e.name, category: e.category) }
        check(owner("HaGeZi Pro") == .ads && owner("Peter Lowe’s ad servers") == .privacy && owner("Anti-Malware (DandelionSprout)") == .security)
        check(owner("NoCoin (cryptojacking)") == .security && owner("Social media (StevenBlack)") == .social && owner("Smart TV tracking") == .privacy)
        check(owner("Adult content (StevenBlack)") == .custom)
        check(SafariRulesetPlanner.owner(ofListNamed: nil, category: nil) == .custom)   // unknown / user-added list

        let plan = SafariRulesetPlanner.plan(sources: [
            .init(url: url("HaGeZi Pro"), rules: [rule("ads.example.com"), rule("keep.example.org", .allow)]),
            .init(url: url("NoCoin (cryptojacking)"), rules: [rule("coin.example.net")]),
            .init(url: "https://example.invalid/list.txt", rules: [rule("custom-list.example.io")])
        ], userRules: [rule("mine.example.dev", .block, .user), rule("allowed.example.com", .allow, .user)])
        func domains(_ id: SafariExtensionID, _ a: FilterAction = .block) -> Set<String> { Set((plan[id] ?? []).filter { $0.action == a }.map(\.domain)) }
        check(domains(.ads) == ["ads.example.com"] && domains(.security) == ["coin.example.net"])
        check(domains(.custom) == ["custom-list.example.io", "mine.example.dev"])
        check(owner("Crypto miners & scams (Blocklist Project)") == .security && owner("EasyPrivacy (domains)") == .privacy && owner("EasyList (domains)") == .ads && owner("Tracking (Blocklist Project)") == .privacy)
        check(owner("French · Liste FR") == .ads)
        check(domains(.privacy).isEmpty && domains(.social).isEmpty && domains(.annoyances).isEmpty)
        // Exceptions reach every extension
        for id in SafariExtensionID.allCases { check(domains(id, .allow) == ["keep.example.org", "allowed.example.com"]) }

        // Compile: an extension with only exceptions gets the empty placeholder and counts nothing
        let compiled = try! SafariRulesetPlanner.compileAll(plan, resourceBlocks: [.font])
        check(compiled[.ads]!.applied == 3 && compiled[.privacy]!.applied == 0 && compiled[.social]!.applied == 0)
        check(String(data: compiled[.privacy]!.data, encoding: .utf8)!.contains("vayusetu-no-rules"))
        check(!String(data: compiled[.privacy]!.data, encoding: .utf8)!.contains("\"^$\""))        // the old placeholder blocked every page
        // The placeholder is valid JSON whose filter is exactly the unmatchable one
        let parsed = try! JSONSerialization.jsonObject(with: SafariRuleCompiler.placeholder) as! [[String: Any]]
        check(((parsed[0]["trigger"] as! [String: Any])["url-filter"] as! String) == SafariRuleCompiler.placeholderFilter)
        check(compiled[.custom]!.applied == 2 + 2 + 1)      // two blocks, two exceptions, one font rule
        check(String(data: compiled[.custom]!.data, encoding: .utf8)!.contains("\"font\""))
        check(!String(data: compiled[.ads]!.data, encoding: .utf8)!.contains("\"font\""))

        // Overflow from a big Ads list moves into idle extensions instead of being cut off, duplicates are dropped, short domains win
        var bigAds: [FilterRule] = (0..<(SafariRuleCompiler.fitBudget + 300)).map { rule("host\($0).adsbig.org") }
        bigAds.append(rule("host0.adsbig.org"))                       // duplicate
        let bigPlan: [SafariExtensionID: [FilterRule]] = [.ads: bigAds]
        let balanced = SafariRulesetPlanner.balance(bigPlan)
        check(balanced[.ads]!.count == SafariRuleCompiler.fitBudget)
        check(balanced[.annoyances]!.count == 300)
        check(balanced.values.reduce(0) { $0 + $1.count } == SafariRuleCompiler.fitBudget + 300)
        let shortWins = SafariRulesetPlanner.balance([.ads: (0..<(SafariRuleCompiler.fitBudget + 5)).map { rule("longer-host-name\($0).example.org") } + [rule("a.io")]])
        check(shortWins[.ads]!.contains { $0.domain == "a.io" })
        // A domain several lists agree on outranks a shorter one only one list has, even when it is long and would otherwise be cut
        let agreed = rule("very-long-famous-ad-network-name.com")
        let crowd = (0..<(SafariRuleCompiler.fitBudget + 50)).map { rule("t\($0).io") }
        let ranking = SafariRulesetPlanner.balance([.ads: crowd + [agreed], .privacy: [agreed]])
        check(ranking.values.flatMap { $0 }.filter { $0.domain == agreed.domain }.count == 1)       // kept once
        check(ranking[.ads]!.contains { $0.domain == agreed.domain })                                // and in the extension that is full, not cut

        // Page rules: routed by list, ordered resource blocks -> URL blocks -> hides -> domain rules -> exceptions, valid JSON, counted
        var easy = ContentRuleSet(); easy.blocks = ["{\"action\":{\"type\":\"block\"},\"trigger\":{\"url-filter\":\"^https?://x\\\\.example/ads/.*\"}}"]
        easy.hides = ["{\"action\":{\"selector\":\".ad\",\"type\":\"css-display-none\"},\"trigger\":{\"url-filter\":\".*\"}}"]
        easy.allows = ["{\"action\":{\"type\":\"ignore-previous-rules\"},\"trigger\":{\"url-filter\":\"^https?://ok\\\\.example/.*\"}}"]
        let sources = [SafariRulesetPlanner.Source(url: url("HaGeZi Pro"), rules: [rule("ads.example.com")], content: easy), SafariRulesetPlanner.Source(url: url("Fanboy Annoyances"), rules: [], content: easy)]
        let contentPlan = SafariRulesetPlanner.planContent(sources: sources, siteExceptions: ["broken.example.com"])
        check(contentPlan[.ads]!.blocks.count == 1 && contentPlan[.annoyances]!.hides.count == 1 && contentPlan[.privacy]!.allows.count == 1)   // site exception reaches every extension
        let withContent = try! SafariRulesetPlanner.compileAll(SafariRulesetPlanner.plan(sources: sources, userRules: []), resourceBlocks: [.script], content: contentPlan)
        let adsJSON = try! JSONSerialization.jsonObject(with: withContent[.ads]!.data) as! [[String: Any]]
        let kinds = adsJSON.map { (($0["action"] as! [String: Any])["type"] as! String) }
        check(kinds == ["block", "css-display-none", "block", "ignore-previous-rules", "ignore-previous-rules"])
        check(withContent[.ads]!.applied == 5)           // URL block + hide + domain rule + the list's exception + the site exception
        check(withContent[.annoyances]!.applied > 0 && withContent[.privacy]!.applied == 0)   // only exceptions: placeholder
        check(SafariRulesetPlanner.siteException("broken.example.com")!.contains("*broken.example.com"))

        // A name under an already blocked parent is dropped everywhere; an exact-scope parent does not cover children
        let nested = SafariRulesetPlanner.balance([.ads: [rule("example.com"), rule("deep.ads.example.com")], .privacy: [rule("other.org"), rule("x.other.org")]])
        check(Set(nested.values.flatMap { $0 }.map(\.domain)) == ["example.com", "other.org"])

        // Identifiers and files are stable
        check(SafariExtensionID.allCases.map(\.rawValue) == ["ads", "privacy", "security", "social", "annoyances", "custom"])
        check(SafariExtensionID.ads.bundleSuffix == "safariads" && SafariExtensionID.custom.fileName == "safari-rules-custom.json")
        print("Safari planner checks passed: \(count)")
    }
}
