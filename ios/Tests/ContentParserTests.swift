import Foundation

@main struct ContentParserTests {
    static var count = 0
    static func check(_ condition: Bool, _ line: Int = #line) { if !condition { fatalError("ContentParserTests failed at line \(line)") }; count += 1 }
    static func parse(_ text: String) -> ContentRuleSet { ABPContentParser.parse(Data(text.utf8)) }
    static func object(_ json: String) -> [String: Any] { try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any] }
    static func main() {
        // Generic hiding is grouped into one rule
        let hides = parse("##.ad-banner\n##div#sponsor\n##.ad-banner\n")
        check(hides.hides.count == 1 && hides.blocks.isEmpty)
        let hide = object(hides.hides[0])
        check((hide["action"] as! [String: Any])["type"] as? String == "css-display-none")
        check(((hide["action"] as! [String: Any])["selector"] as! String) == ".ad-banner, div#sponsor")      // deduped, sorted
        check((hide["trigger"] as! [String: Any])["if-domain"] == nil)
        // Domain-specific hiding uses if-domain with a wildcard prefix; negation uses unless-domain
        let scoped = parse("news.example.com,other.org##.promo\n~good.com##.sticky\n")
        check(scoped.hides.count == 2)
        let triggers = scoped.hides.map { object($0)["trigger"] as! [String: Any] }
        check(triggers.contains { ($0["if-domain"] as? [String]) == ["*news.example.com", "*other.org"] })
        check(triggers.contains { ($0["unless-domain"] as? [String]) == ["*good.com"] })
        // Selectors Safari cannot do are counted, not converted
        let bad = parse("example.com##.a:-abp-has(.b)\n##.x:xpath(//div)\n##a:hover\n##.y::before\nexample.com#?#.z\nexample.com#@#.q\n##+js(set, a, b)\n")
        check(bad.hides.isEmpty && bad.unsupported >= 5)
        check(ABPContentParser.safeSelector("div.ad > a[href*=\"track\"]:not(.keep)") && !ABPContentParser.safeSelector("div[") && !ABPContentParser.safeSelector("a:hover"))

        // URL-pattern rules
        let net = parse("||ads.example.com/banners/*$third-party,image\n/ads/frame.\n|https://x.example.org/p.js|\n||tracker.net^$script,domain=a.com|b.com\n")
        check(net.blocks.count == 4 && net.allows.isEmpty)
        let first = object(net.blocks[0])
        let t1 = first["trigger"] as! [String: Any]
        check(t1["url-filter"] as? String == "^https?://([^/]+\\.)?ads\\.example\\.com/banners/.*")
        check(t1["load-type"] as? [String] == ["third-party"] && t1["resource-type"] as? [String] == ["image"])
        let regexes = net.blocks.map { (object($0)["trigger"] as! [String: Any])["url-filter"] as! String }
        check(regexes.contains("/ads/frame\\."))                       // unanchored substring
        check(regexes.contains("^https://x\\.example\\.org/p\\.js$"))   // | start and end anchors
        let scripted = net.blocks.map { object($0)["trigger"] as! [String: Any] }.first { ($0["url-filter"] as! String).contains("tracker") }!
        check(scripted["if-domain"] as? [String] == ["*a.com", "*b.com"] && scripted["resource-type"] as? [String] == ["script"])
        // Exceptions become ignore-previous-rules
        let allow = parse("@@||cdn.example.com/lib/*$script\n")
        check(allow.allows.count == 1 && (object(allow.allows[0])["action"] as! [String: Any])["type"] as? String == "ignore-previous-rules" && allow.blocks.isEmpty)
        // A plain ||domain^ belongs to the domain parser; regex rules and unsupported options are counted
        let skipped = parse("||plain.example.com^\n/banner\\d+/\n||a.example.com/x$redirect=noop.js\n||b.example.com/y$removeparam=utm\n||c.example.com/z$important\n! comment\n[Adblock Plus 2.0]\n")
        check(skipped.count == 0 && skipped.unsupported == 4)
        // Too-short patterns would match far too much
        check(parse("/a/\n").count == 0 && parse("*^\n").count == 0)
        // Every generated rule is valid JSON with a trigger and an action
        for json in hides.hides + scoped.hides + net.blocks + allow.allows { let o = object(json); check(o["trigger"] != nil && o["action"] != nil) }
        // Limit
        let many = (0..<50).map { "||site\($0).example.com/ads/*$script" }.joined(separator: "\n")
        check(ABPContentParser.parse(Data(many.utf8), limit: 10).blocks.count == 10)
        print("Content parser checks passed: \(count)")
    }
}
