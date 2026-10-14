import Foundation

@main struct FilterCatalogTests {
    static var count = 0
    static func check(_ condition: Bool, _ line: Int = #line) { if !condition { fatalError("FilterCatalogTests failed at line \(line)") }; count += 1 }
    static func main() {
        let all = FilterCatalog.all
        check(all.count >= 30)    // a broad, popular catalogue across four categories
        check(Set(all.map(\.url)).count == all.count && Set(all.map(\.name)).count == all.count)           // no duplicates
        check(all.allSatisfy { URL(string: $0.url)?.scheme == "https" && URL(string: $0.url)?.host != nil })  // HTTPS only
        check(all.allSatisfy { $0.approximateRules > 0 && $0.approximateRules <= FilterParser.domainLimit })    // each fits the per-list limit
        check(!all.contains { $0.url.contains("tif.txt") || $0.url.contains("gambling.txt") || $0.url.contains("pro.plus") })
        check(Set(FilterCatalog.defaults.map(\.name)) == ["HaGeZi Pro", "Anti-Malware (DandelionSprout)", "Peter Lowe’s ad servers", "uBlock badware risks"])
        check(FilterCatalog.entry(forURL: "https://small.oisd.nl/")?.name == "OISD Small" && FilterCatalog.entry(forURL: "https://example.invalid/") == nil)
        let groups = FilterCatalog.grouped()
        check(groups.map { $0.0 } == FilterCategory.allCases && groups.allSatisfy { !$0.1.isEmpty })
        check(groups.flatMap { $0.1 }.count == all.count)
        check(all.first { $0.name == "URLhaus malware" }?.sizeLabel == "~400 rules" && all.first { $0.name == "HaGeZi Light" }?.sizeLabel == "~56k rules")
        // Safari fitting: children of a blocked parent are dropped, user and allow rules always stay.
        func rule(_ d: String, _ a: FilterAction = .block, _ t: FilterTier = .subscription) -> FilterRule { try! FilterRule(domain: d, action: a, scope: .domainAndSubdomains, tier: t, source: "t") }
        let fit1 = try! SafariRuleCompiler.fit([rule("ads.example.com"), rule("example.com"), rule("other.org"), rule("a.b.other.org")])
        check(fit1.applied == 2 && fit1.candidates == 4)
        let many = (0..<(SafariRuleCompiler.fitBudget + 500)).map { rule("host\($0).test.com".replacingOccurrences(of: "test.com", with: "site\($0).org")) } + [rule("keep.net", .allow), rule("mine.net", .block, .user)]
        let fit2 = try! SafariRuleCompiler.fit(many)
        check(fit2.applied == SafariRuleCompiler.fitBudget && fit2.candidates == many.count)
        check(String(data: fit2.data, encoding: .utf8)!.contains("keep\\\\.net") && String(data: fit2.data, encoding: .utf8)!.contains("mine\\\\.net"))
        // Page-element rules must never become whole-site blocks (this once blocked github.com, reddit.com and google.com)
        let mixed = "||ads.example.com^\ngithub.com##.sidebar-ad\nreddit.com#@#.promo\ngoogle.com#?#div:has(.x)\n##.banner\nwww.bbc.com#$#abort-on-property-read x\nwikipedia.org#%#//scriptlet('x')\n0.0.0.0 tracker.example.net\n"
        let parsedMixed = try! FilterParser.parse(Data(mixed.utf8), source: "t")
        check(Set(parsedMixed.rules.map(\.domain)) == ["ads.example.com", "tracker.example.net"] && parsedMixed.rejected >= 5)
        check((try? FilterDomain.normalize("github.com##.ad")) == nil && (try? FilterDomain.normalize("example.com#fragment")) == nil && (try? FilterDomain.normalize("example.com?x=1")) == nil)
        check((try? FilterDomain.normalize("ads.example.com")) == "ads.example.com")
        print("Filter catalogue checks passed: \(count)")
    }
}
