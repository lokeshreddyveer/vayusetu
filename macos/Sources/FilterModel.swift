import Foundation

/// Shared by the Mac app and the network-filter system extension: what a connection looks like, what a rule looks like, how a rule is chosen,
/// and the XPC contract between the two. Nothing here touches the network.

enum FilterNames {
    static let team = "X4MH29QNRS"
    static let extensionBundleID = "app.vayusetu.macos.filter"
    /// A Mach service name must start with an application group the extension belongs to.
    static let appGroup = team + ".app.vayusetu.filter"
    static let machService = appGroup + ".xpc"
    /// The only code allowed to talk to the extension.
    static let clientRequirement = "anchor apple generic and identifier \"app.vayusetu.macos\" and certificate leaf[subject.OU] = \"\(team)\""
}

enum NetAction: String, Codable, CaseIterable, Identifiable { case allow, block; var id: String { rawValue } }

struct FlowRecord: Codable, Identifiable, Hashable {
    var id: Int64
    var time: Date
    /// Code-signing identifier, for example `com.apple.Safari`.
    var app: String
    /// A readable name: the executable's file name when known, otherwise the identifier.
    var appName: String
    var host: String
    var port: String
    var proto: String
    var outbound: Bool
    var verdict: NetAction
    /// The rule that decided it; nil when nothing matched and the default applied.
    var rule: UUID?
}

struct NetRule: Codable, Identifiable, Hashable {
    var id = UUID()
    /// Code-signing identifier, or `*` for every app.
    var app: String
    /// `*` for any destination, `example.com` for that domain and its subdomains, or an exact address.
    var host: String
    /// `*` or a port number.
    var port: String
    var action: NetAction
    var created = Date()
    var note = ""
}

struct FilterSettings: Codable, Equatable {
    /// Ask before a connection that no rule covers (off by default).
    var askMode = false
    /// What happens to a connection that no rule covers.
    var defaultAction = NetAction.allow
    /// Seconds to wait for an answer in ask mode before the default applies.
    var askTimeout = 20
}

struct PendingQuestion: Codable, Identifiable, Hashable {
    var id: Int64
    var time: Date
    var app: String
    var appName: String
    var host: String
    var port: String
    var proto: String
}

/// Chooses the rule that applies to a connection. The most specific rule wins; at equal specificity a block beats an allow.
/// Specificity counts: a named app (2), a destination host (exact address 3, a domain 2), a port (1).
enum NetRuleEngine {
    static func decide(app: String, host: String, port: String, rules: [NetRule], settings: FilterSettings) -> (action: NetAction, rule: NetRule?) {
        var best: (score: Int, rule: NetRule)?
        for rule in rules where matches(rule, app: app, host: host, port: port) {
            let score = specificity(rule)
            if let current = best {
                if score > current.score || (score == current.score && rule.action == .block && current.rule.action == .allow) { best = (score, rule) }
            } else { best = (score, rule) }
        }
        if let best { return (best.rule.action, best.rule) }
        return (settings.defaultAction, nil)
    }
    static func specificity(_ rule: NetRule) -> Int {
        var score = rule.app == "*" ? 0 : 2
        if rule.host != "*" { score += isAddress(rule.host) ? 3 : 2 }
        if rule.port != "*" { score += 1 }
        return score
    }
    static func matches(_ rule: NetRule, app: String, host: String, port: String) -> Bool {
        guard rule.app == "*" || rule.app == app else { return false }
        guard rule.port == "*" || rule.port == port else { return false }
        return hostMatches(rule.host, host)
    }
    static func hostMatches(_ pattern: String, _ host: String) -> Bool {
        let p = normalise(pattern), h = normalise(host)
        if p == "*" { return true }
        if p == h { return true }
        if isAddress(p) { return false }                  // an address matches only itself
        return h.hasSuffix("." + p)                       // a domain covers its subdomains, on whole labels only
    }
    static func normalise(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespaces).lowercased()
        if value.hasSuffix(".") { value.removeLast() }
        if let percent = value.firstIndex(of: "%") { value = String(value[..<percent]) }   // an interface scope on an IPv6 address
        return value
    }
    static func isAddress(_ text: String) -> Bool {
        let v = normalise(text)
        if v.contains(":") { return true }                // IPv6
        let parts = v.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }
    /// Connections that are never filtered: VayuSetu's own, and this Mac talking to itself.
    static func isExempt(app: String, host: String) -> Bool {
        if app == "app.vayusetu" || app.hasPrefix("app.vayusetu.") { return true }
        let h = normalise(host)
        return h == "localhost" || h == "::1" || h.hasPrefix("127.")
    }
}

/// The contract between the app and the filter extension.
@objc protocol VayuFilterXPC {
    func recentFlows(after id: Int64, reply: @escaping (Data) -> Void)
    func rules(reply: @escaping (Data) -> Void)
    func setRules(_ data: Data, reply: @escaping (Bool) -> Void)
    func settings(reply: @escaping (Data) -> Void)
    func setSettings(_ data: Data, reply: @escaping (Bool) -> Void)
    func pending(reply: @escaping (Data) -> Void)
    func answer(_ id: Int64, allow: Bool, remember: Bool, reply: @escaping (Bool) -> Void)
    func clearFlows(reply: @escaping (Bool) -> Void)
}
