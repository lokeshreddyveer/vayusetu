import Foundation

/// The six Safari content-blocker extensions. Each one owns a slice of the rules and its own file in the App Group, so the
/// per-extension rule budget is multiplied and a problem in one slice does not take the others down.
public enum SafariExtensionID: String, CaseIterable, Codable, Identifiable, Sendable {
    case ads, privacy, security, social, annoyances, custom
    public var id: String { rawValue }
    public var title: String {
        switch self { case .ads: "Ads"; case .privacy: "Privacy"; case .security: "Security"; case .social: "Social"; case .annoyances: "Annoyances"; case .custom: "Custom" }
    }
    /// Bundle identifier suffix: `<app id>.safari<name>`. App Store validation allows only one dot after the app's own identifier.
    public var bundleSuffix: String { "safari" + rawValue }
    public var fileName: String { "safari-rules-\(rawValue).json" }
}

public enum SafariRulesetPlanner {
    /// Which extension owns a subscription's blocking rules. Lists the catalogue does not know (user-added or imported) go to Custom.
    public static func owner(ofListNamed name: String?, category: FilterCategory?) -> SafariExtensionID {
        guard let name, let category else { return .custom }
        if name.localizedCaseInsensitiveContains("NoCoin") || name.localizedCaseInsensitiveContains("mining") || name.localizedCaseInsensitiveContains("crypto") { return .security }
        if name.localizedCaseInsensitiveContains("social") { return .social }
        if name.localizedCaseInsensitiveContains("annoyance") || name.localizedCaseInsensitiveContains("cookie") { return .annoyances }
        let tracking = ["Peter Lowe’s ad servers", "Dan Pollock’s hosts", "ShadowWhisperer tracking", "EasyPrivacy (domains)"]
        switch category {
        case .adsTrackers: return tracking.contains(name) ? .privacy : .ads
        case .privacy: return .privacy
        case .malwarePhishing: return .security
        case .content: return .custom
        case .regional: return .ads        // regional ad and tracker rules
        }
    }

    public struct Source: Sendable {
        public let url: String, rules: [FilterRule], content: ContentRuleSet
        public init(url: String, rules: [FilterRule], content: ContentRuleSet = ContentRuleSet()) { self.url = url; self.rules = rules; self.content = content }
    }

    /// Splits the enabled rules between extensions. Blocks go to the owning extension (user blocks to Custom). Allow rules, from
    /// the user or a subscription, go to EVERY extension: an exception in only one extension could not cancel a block in another.
    public static func plan(sources: [Source], userRules: [FilterRule]) -> [SafariExtensionID: [FilterRule]] {
        var result: [SafariExtensionID: [FilterRule]] = Dictionary(uniqueKeysWithValues: SafariExtensionID.allCases.map { ($0, []) })
        var exceptions: [FilterRule] = []
        for source in sources {
            let entry = FilterCatalog.entry(forURL: source.url)
            let owner = owner(ofListNamed: entry?.name, category: entry?.category)
            for rule in source.rules where rule.enabled != false {
                if rule.action == .allow { exceptions.append(rule) } else { result[owner, default: []].append(rule) }
            }
        }
        for rule in userRules where rule.enabled != false {
            if rule.action == .allow { exceptions.append(rule) } else { result[.custom, default: []].append(rule) }
        }
        for id in SafariExtensionID.allCases { result[id, default: []].append(contentsOf: exceptions) }
        return result
    }

    /// Page-element and URL-pattern rules, routed to the extension that owns their list.
    public static func planContent(sources: [Source], siteExceptions: [String] = []) -> [SafariExtensionID: ContentRuleSet] {
        var out: [SafariExtensionID: ContentRuleSet] = [:]
        for source in sources where !source.content.isEmpty {
            let entry = FilterCatalog.entry(forURL: source.url)
            out[owner(ofListNamed: entry?.name, category: entry?.category), default: ContentRuleSet()].append(source.content)
        }
        // A website exception turns every earlier rule off on that site's pages, in every extension.
        if !siteExceptions.isEmpty {
            let rules = siteExceptions.compactMap(siteException)
            for id in SafariExtensionID.allCases { out[id, default: ContentRuleSet()].allows += rules }
        }
        return out
    }

    /// `ignore-previous-rules` for every request made by pages on `domain` (and its subdomains).
    public static func siteException(_ domain: String) -> String? {
        let object: [String: Any] = ["trigger": ["url-filter": ".*", "if-domain": ["*" + domain]], "action": ["type": "ignore-previous-rules"]]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public struct Compiled: Sendable { public let data: Data, applied: Int, candidates: Int }

    /// Most useful first. A domain that several lists agree on is almost always a real, common ad or tracker host, so agreement ranks
    /// first; then whole-domain rules before exact hosts; then shorter names. (Length alone is a poor guide: doubleclick.net is
    /// longer than most throwaway tracker hosts but matters far more.)
    private static func ranked(_ rules: [FilterRule], counts: [String: Int]) -> [FilterRule] {
        func key(_ r: FilterRule) -> String { r.domain + "|" + r.scope.rawValue }
        /// Names (or the parent domain of names) that most blocklists agree on always rank above everything else.
        func weight(_ r: FilterRule) -> Int {
            var base = counts[key(r)] ?? 1
            let parts = r.domain.split(separator: ".", omittingEmptySubsequences: false)
            for start in parts.indices where parts.count - start >= 2 && SafariRankBoost.domains.contains(parts[start...].joined(separator: ".")) { base += 100; break }
            return base
        }
        // Weights and lengths are worked out once per rule: computing them inside the comparator costs minutes on a large list.
        let decorated = rules.map { (rule: $0, weight: weight($0), length: $0.domain.count) }
        return decorated.sorted { a, b in
            if a.weight != b.weight { return a.weight > b.weight }
            if a.rule.scope != b.rule.scope { return a.rule.scope == .domainAndSubdomains }
            if a.length != b.length { return a.length < b.length }
            return a.rule.domain < b.rule.domain
        }.map(\.rule)
    }
    /// Where blocks that do not fit their own extension go: extensions with the most spare room, in this order.
    private static let spillOrder: [SafariExtensionID] = [.annoyances, .social, .custom, .privacy, .security, .ads]

    /// Dedupes, keeps the best rules in each extension's budget, and moves overflow into extensions that have room, so a big Ads
    /// list uses the idle extensions instead of being cut off. Exceptions (allow rules) stay in every extension.
    public static func balance(_ plan: [SafariExtensionID: [FilterRule]], resourceBlockCount: Int = 0, contentCounts: [SafariExtensionID: Int] = [:], budget: Int = SafariRuleCompiler.fitBudget) -> [SafariExtensionID: [FilterRule]] {
        var exceptions: [FilterRule] = []; var seenAllow = Set<String>()
        var blocks: [SafariExtensionID: [FilterRule]] = [:]; var seen = Set<String>()
        var counts: [String: Int] = [:]
        for id in SafariExtensionID.allCases { for rule in plan[id] ?? [] where rule.action == .block { counts[rule.domain + "|" + rule.scope.rawValue, default: 0] += 1 } }
        for id in SafariExtensionID.allCases {
            for rule in plan[id] ?? [] {
                let key = rule.domain + "|" + rule.scope.rawValue
                if rule.action == .allow { if seenAllow.insert(key).inserted { exceptions.append(rule) } }
                else if seen.insert(key).inserted { blocks[id, default: []].append(rule) }
            }
        }
        // A rule for a name that a blocked parent domain already covers adds nothing, in whichever extension the parent is.
        let parents = Set(blocks.values.flatMap { $0 }.filter { $0.scope == .domainAndSubdomains }.map(\.domain))
        func covered(_ rule: FilterRule) -> Bool {
            let parts = rule.domain.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count > 2 else { return false }
            for start in 1..<(parts.count - 1) where parents.contains(parts[start...].joined(separator: ".")) { return true }
            return false
        }
        for id in SafariExtensionID.allCases { blocks[id] = (blocks[id] ?? []).filter { !covered($0) } }
        func room(_ id: SafariExtensionID) -> Int { max(0, budget - exceptions.count - (id == .custom ? resourceBlockCount : 0) - min(contentCounts[id] ?? 0, budget / 2 * 3)) }
        var overflow: [FilterRule] = []
        for id in SafariExtensionID.allCases {
            var list = ranked(blocks[id] ?? [], counts: counts)
            if list.count > room(id) { overflow.append(contentsOf: list[room(id)...]); list = Array(list[..<room(id)]) }
            blocks[id] = list
        }
        for rule in ranked(overflow, counts: counts) {
            guard let target = spillOrder.first(where: { (blocks[$0]?.count ?? 0) < room($0) }) else { break }
            blocks[target, default: []].append(rule)
        }
        return Dictionary(uniqueKeysWithValues: SafariExtensionID.allCases.map { ($0, (blocks[$0] ?? []) + (blocks[$0]?.isEmpty == false || $0 == .custom && resourceBlockCount > 0 ? exceptions : [])) })
    }

    /// Compiles every extension's slice. Resource-type blocks (fonts, images, scripts) live in Custom.
    public static func compileAll(_ plan: [SafariExtensionID: [FilterRule]], resourceBlocks: [SafariRuleCompiler.ResourceBlock], content: [SafariExtensionID: ContentRuleSet] = [:]) throws -> [SafariExtensionID: Compiled] {
        let balanced = balance(plan, resourceBlockCount: resourceBlocks.count, contentCounts: content.mapValues(\.count))
        var out: [SafariExtensionID: Compiled] = [:]
        for id in SafariExtensionID.allCases {
            let rules = balanced[id] ?? []
            let slice = content[id] ?? ContentRuleSet()
            let fit = try SafariRuleCompiler.fit(rules, resourceBlocks: id == .custom ? resourceBlocks : [], content: slice)
            // A slice that holds only copied exceptions has nothing to enforce.
            let blocks = rules.filter { $0.action == .block }.count + (id == .custom ? resourceBlocks.count : 0) + slice.blocks.count + slice.hides.count
            out[id] = Compiled(data: blocks == 0 ? SafariRuleCompiler.placeholder : fit.data, applied: blocks == 0 ? 0 : fit.applied, candidates: blocks)
        }
        return out
    }
}
