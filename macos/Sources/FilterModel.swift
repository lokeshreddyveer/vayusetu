import CryptoKit
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
    /// Rules in this group live until the filter restarts.
    static let sessionGroup = "Session"
    static let clientRequirement = "anchor apple generic and identifier \"app.vayusetu.macos\" and certificate leaf[subject.OU] = \"\(team)\""
}

enum NetAction: String, Codable, CaseIterable, Identifiable { case allow, block; var id: String { rawValue } }
enum AskPolicy: String, Codable, CaseIterable, Identifiable {
    case newApplication, everyConnection
    var id: String { rawValue }
    var title: String { self == .newApplication ? "New applications" : "Every uncovered connection" }
    var detail: String { self == .newApplication ? "Ask once per application session; remember a rule only when chosen." : "Ask for every app and destination not covered by a rule." }
}

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
    // Who the app is. Optional so that history saved by an earlier build still loads.
    var team: String? = nil
    /// A warning about the app's identity, or nil: "Invalid signature" or "Signer changed".
    var identity: String? = nil
    var parent: String? = nil
    var remoteAddress: String? = nil
    /// The block or allow list that decided it, when one did.
    var list: String? = nil
    /// Bytes seen on the connection. Only counted while "Count traffic" is on, so nil otherwise.
    var bytesIn: Int64? = nil
    var bytesOut: Int64? = nil
}

/// A weekly window. `days` use Calendar weekdays (1 = Sunday … 7 = Saturday); times are minutes after midnight.
/// A window whose end is earlier than its start runs overnight into the next day.
struct NetSchedule: Codable, Hashable {
    var days: [Int]
    var start: Int
    var end: Int
    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let day = c.weekday, let hour = c.hour, let minute = c.minute else { return false }
        let m = hour * 60 + minute
        if start == end { return days.contains(day) }                       // a whole day
        if start < end { return days.contains(day) && m >= start && m < end }
        let before = day == 1 ? 7 : day - 1                                   // overnight: today after the start, or tomorrow morning before the end
        return (days.contains(day) && m >= start) || (days.contains(before) && m < end)
    }
}

/// Which way a connection was started. A rule with no direction covers both.
enum NetDirection: String, Codable, CaseIterable, Identifiable {
    case any, outbound, inbound
    var id: String { rawValue }
    var title: String { switch self { case .any: "Either way"; case .outbound: "Outgoing"; case .inbound: "Incoming" } }
}

/// What an answer in the connection alert covers, and for how long. Built by the app, applied by the extension.
enum AlertScope: String, CaseIterable, Identifiable {
    case app, domain, host, hostPort
    var id: String { rawValue }
    var title: String { switch self { case .app: "This app, any destination"; case .domain: "This domain"; case .host: "This server"; case .hostPort: "This server and port" } }
}
enum AlertLifetime: String, CaseIterable, Identifiable {
    case once, hour, restart, forever
    var id: String { rawValue }
    var title: String { switch self { case .once: "Once"; case .hour: "For an hour"; case .restart: "Until restart"; case .forever: "Forever" } }
}
enum AlertRule {
    /// `example.com` for `www.example.com` and `example.co.uk` for `shop.example.co.uk`. A name that is already short, or an address, is kept.
    static func domain(of host: String) -> String {
        let h = NetRuleEngine.normalise(host)
        guard !NetRuleEngine.isAddress(h) else { return h }
        let labels = h.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return h }
        let secondLevel: Set<String> = ["co", "com", "org", "net", "ac", "gov", "edu", "ne", "or"]
        let keep = labels[labels.count - 1].count == 2 && secondLevel.contains(labels[labels.count - 2]) ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }
    /// The rule for an answer, or nil for "once" (the answer applies to this connection only).
    static func make(for q: PendingQuestion, allow: Bool, scope: AlertScope, lifetime: AlertLifetime, now: Date = Date()) -> NetRule? {
        guard lifetime != .once else { return nil }
        var rule = NetRule(app: q.app, host: "*", port: "*", action: allow ? .allow : .block, note: "From a question")
        rule.team = q.team; rule.parent = q.parent
        switch scope {
        case .app: break
        case .domain: rule.host = domain(of: q.host)
        case .host: rule.host = q.host
        case .hostPort: rule.host = q.host; rule.port = q.port.isEmpty ? "*" : q.port
        }
        switch lifetime {
        case .hour: rule.expires = now.addingTimeInterval(3600); rule.group = "Temporary"
        case .restart: rule.group = FilterNames.sessionGroup
        default: break
        }
        return rule
    }
}

/// How connections that no rule covers are handled.
enum FilterMode: String, Codable, CaseIterable, Identifiable {
    /// Ask (or follow the default), as set in the other options.
    case normal
    /// No questions. Existing rules and lists still apply; everything else follows one fixed choice.
    case passive
    /// Everything is blocked except what a rule or an allow list lets through.
    case blockAll
    var id: String { rawValue }
    /// Product-facing names. The aliases preserve the on-disk names used by
    /// earlier builds while making the three operating modes explicit.
    static var requireApproval: Self { .normal }
    static var allowAll: Self { .passive }
    var title: String { switch self { case .normal: "Require approval"; case .passive: "Allow all"; case .blockAll: "Block all" } }
    var detail: String {
        switch self {
        case .normal: "Unknown applications pause until you approve or block them. Existing rules and lists still apply."
        case .passive: "No prompts. Rules and lists still apply; unmatched connections are allowed."
        case .blockAll: "Everything is blocked except what an allow rule or an allow list lets through."
        }
    }
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
    // Optional so that rules saved by an earlier build still load.
    var group: String? = nil
    var expires: Date? = nil
    var schedule: NetSchedule? = nil
    var direction: NetDirection? = nil
    /// Optional signer/process lineage constraints. Existing rules decode with
    /// nil and keep their previous behavior.
    var team: String? = nil
    var parent: String? = nil
    var groupName: String { group ?? "Default" }
}

/// A list of destinations, blocked or allowed as a whole. It can be typed in, pasted, or refreshed from a web address.
struct NetList: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var kind: NetAction
    var enabled = true
    /// Where the entries come from; nil for a list you typed or pasted.
    var source: String? = nil
    var refreshHours = 24
    var entries: [String] = []
    var updated: Date? = nil
    /// The outcome of the last refresh, in words.
    var status: String? = nil
    /// Optional enterprise pin. A normal user list remains backward compatible;
    /// a managed list refuses content whose checksum does not match this value.
    var expectedSHA256: String? = nil
    var checksum: String? = nil
    static let maximumEntries = 400_000
    var due: Bool { guard source != nil, enabled else { return false }; return updated.map { Date().timeIntervalSince($0) >= Double(refreshHours) * 3600 } ?? true }
}

/// How many times a rule or list decided a connection, and when it last did.
struct HitCount: Codable, Hashable { var count = 0; var last = Date.distantPast }
struct FilterUsage: Codable, Equatable {
    var rules: [String: HitCount] = [:]
    var lists: [String: HitCount] = [:]
}

struct FilterAuditRecord: Codable, Hashable, Identifiable {
    var id = UUID()
    var time = Date()
    var actor: String
    var action: String
    var detail: String
    var previousHash: String? = nil
    var hash: String
    init(time: Date = Date(), actor: String, action: String, detail: String, previousHash: String? = nil) {
        self.time = time; self.actor = actor; self.action = action; self.detail = detail; self.previousHash = previousHash
        let chain = previousHash ?? ""
        let material = "\(time.timeIntervalSince1970)|\(actor)|\(action)|\(detail)|\(chain)"
        hash = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func verifies() -> Bool {
        FilterAuditRecord(time: time, actor: actor, action: action, detail: detail, previousHash: previousHash).hash == hash
    }
}

struct FilterSettings: Codable, Equatable {
    /// Ask before a connection that no rule covers. New installs use the safer
    /// interactive mode; an existing saved preference remains unchanged.
    var askMode = true
    var askPolicy = AskPolicy.newApplication
    /// What happens to a connection that no rule covers.
    var defaultAction = NetAction.allow
    /// Seconds to wait for an answer in ask mode before the default applies.
    var askTimeout = 20
    /// Keep an unanswered alert stalled indefinitely unless the user opts into
    /// an automatic fallback for unattended/remote sessions.
    var automaticAskResolution = false
    /// Groups of rules that are switched off.
    var disabledGroups: [String]? = nil
    var mode = FilterMode.normal
    /// Passive mode: what a new connection gets, and whether that choice is saved as a rule for the app.
    var passiveAction = NetAction.allow
    var passiveCreatesRules = true
    /// Let software signed by Apple connect without asking.
    var allowAppleSigned = true
    /// What an incoming connection gets when no rule covers it; nil means the same as the default.
    var inboundAction: NetAction? = nil
    /// Count the bytes of each allowed connection. Off by default: the extension then sees the data of every connection.
    var countTraffic = false

    enum CodingKeys: String, CodingKey { case askMode, askPolicy, defaultAction, askTimeout, automaticAskResolution, disabledGroups, mode, passiveAction, passiveCreatesRules, allowAppleSigned, inboundAction, countTraffic }
    init(askMode: Bool = true, askPolicy: AskPolicy = .newApplication, defaultAction: NetAction = .allow, askTimeout: Int = 20, automaticAskResolution: Bool = false, disabledGroups: [String]? = nil) {
        self.askMode = askMode; self.askPolicy = askPolicy; self.defaultAction = defaultAction; self.askTimeout = askTimeout
        self.automaticAskResolution = automaticAskResolution; self.disabledGroups = disabledGroups
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        askMode = try c.decodeIfPresent(Bool.self, forKey: .askMode) ?? true
        askPolicy = try c.decodeIfPresent(AskPolicy.self, forKey: .askPolicy) ?? .newApplication
        defaultAction = try c.decodeIfPresent(NetAction.self, forKey: .defaultAction) ?? .allow
        askTimeout = try c.decodeIfPresent(Int.self, forKey: .askTimeout) ?? 20
        automaticAskResolution = try c.decodeIfPresent(Bool.self, forKey: .automaticAskResolution) ?? false
        disabledGroups = try c.decodeIfPresent([String].self, forKey: .disabledGroups)
        mode = try c.decodeIfPresent(FilterMode.self, forKey: .mode) ?? .normal
        passiveAction = try c.decodeIfPresent(NetAction.self, forKey: .passiveAction) ?? .allow
        passiveCreatesRules = try c.decodeIfPresent(Bool.self, forKey: .passiveCreatesRules) ?? true
        allowAppleSigned = try c.decodeIfPresent(Bool.self, forKey: .allowAppleSigned) ?? true
        inboundAction = try c.decodeIfPresent(NetAction.self, forKey: .inboundAction)
        countTraffic = try c.decodeIfPresent(Bool.self, forKey: .countTraffic) ?? false
    }
}

/// A named set of rules and settings, kept by the app so you can switch between, say, Home and Public Wi-Fi.
struct FilterProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var rules: [NetRule]
    var settings: FilterSettings
}

struct PendingQuestion: Codable, Identifiable, Hashable {
    var id: Int64
    var time: Date
    var app: String
    var appName: String
    var host: String
    var port: String
    var proto: String
    var team: String? = nil
    var identity: String? = nil
    var parent: String? = nil
    var remoteAddress: String? = nil
}

/// Chooses the rule that applies to a connection. The most specific rule wins; at equal specificity a block beats an allow.
/// Specificity counts: a named app (2), a destination host (exact address 3, a domain, wildcard or address range 2), a port (1), a direction (1).
enum NetRuleEngine {
    static func isValidRule(_ rule: NetRule) -> Bool {
        guard !rule.app.isEmpty, rule.app.count <= 256, rule.app == "*" || rule.app.allSatisfy({ $0.isASCII && !$0.isWhitespace }),
              isValidDestination(rule.host), rule.port == "*" || (Int(rule.port).map { (1...65535).contains($0) } ?? false) else { return false }
        if let team = rule.team, team.count > 64 || team.contains(where: { $0.isWhitespace }) { return false }
        if let parent = rule.parent, parent.isEmpty || parent.count > 256 || parent.contains(where: { $0.isWhitespace }) { return false }
        return true
    }
    /// A rule counts only if it has not expired, its group is switched on, and the current time is inside its schedule (if it has one).
    static func isActive(_ rule: NetRule, now: Date, settings: FilterSettings) -> Bool {
        if let expires = rule.expires, expires <= now { return false }
        if let off = settings.disabledGroups, off.contains(rule.groupName) { return false }
        if let schedule = rule.schedule, !schedule.contains(now) { return false }
        return true
    }
    static func decide(app: String, host: String, port: String, address: String? = nil, outbound: Bool = true, team: String? = nil, parent: String? = nil, rules: [NetRule], settings: FilterSettings, now: Date = Date()) -> (action: NetAction, rule: NetRule?) {
        var best: (score: Int, rule: NetRule)?
        for rule in rules where isActive(rule, now: now, settings: settings) && matches(rule, app: app, host: host, port: port, address: address, outbound: outbound, team: team, parent: parent) {
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
        if let direction = rule.direction, direction != .any { score += 1 }
        if rule.team != nil { score += 2 }
        if rule.parent != nil { score += 1 }
        return score
    }
    static func matches(_ rule: NetRule, app: String, host: String, port: String, address: String? = nil, outbound: Bool = true, team: String? = nil, parent: String? = nil) -> Bool {
        guard rule.app == "*" || rule.app == app else { return false }
        guard rule.team == nil || rule.team == team else { return false }
        guard rule.parent == nil || rule.parent == parent else { return false }
        guard rule.port == "*" || rule.port == port else { return false }
        switch rule.direction ?? .any { case .any: break; case .outbound: if !outbound { return false }; case .inbound: if outbound { return false } }
        return hostMatches(rule.host, host, address: address)
    }
    /// `*` any destination; `example.com` that domain and its subdomains; `*.example.com` its subdomains only; `ads*.example.com` a pattern;
    /// an exact address; `10.0.0.0/8` or `fd00::/8` a block of addresses; `10.0.0.1-10.0.0.50` a range. A rule written with a name also
    /// matches the connection's numeric address when that is the only thing known.
    static func hostMatches(_ pattern: String, _ host: String, address: String? = nil) -> Bool {
        let p = normalise(pattern)
        if p == "*" { return true }
        if matchesOne(p, normalise(host)) { return true }
        if let address, matchesOne(p, normalise(address)) { return true }
        return false
    }
    private static func matchesOne(_ p: String, _ h: String) -> Bool {
        if p == h { return true }
        if let range = AddressRange(p) { return range.contains(h) }
        if p.hasPrefix("*.") && !p.dropFirst(2).contains("*") { return h.hasSuffix(String(p.dropFirst(1))) }
        if p.contains("*") { return glob(Array(p), Array(h)) }
        if isAddress(p) { return false }                  // an address matches only itself
        return h.hasSuffix("." + p)                       // a domain covers its subdomains, on whole labels only
    }
    private static func glob(_ p: [Character], _ h: [Character]) -> Bool {
        var pi = 0, hi = 0, star = -1, mark = 0
        while hi < h.count {
            if pi < p.count, p[pi] == "*" { star = pi; mark = hi; pi += 1 }
            else if pi < p.count, p[pi] == h[hi] { pi += 1; hi += 1 }
            else if star >= 0 { pi = star + 1; mark += 1; hi = mark }
            else { return false }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
    /// Whether text is something a rule or list can hold in its destination: `*`, a name, a wildcard, an address, a block or a range.
    static func isValidDestination(_ text: String) -> Bool {
        let v = normalise(text)
        guard !v.isEmpty, v.count <= 253, v.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-_*:/".contains($0)) }) else { return false }
        if v.contains("/") || (v.contains("-") && v.split(separator: "-").count == 2 && AddressRange(v) != nil) { return AddressRange(v) != nil }
        return true
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
    static func isExempt(app: String, host: String, team: String? = nil, valid: Bool = false) -> Bool {
        if valid && team == FilterNames.team && (app == "app.vayusetu" || app.hasPrefix("app.vayusetu.")) { return true }
        let h = normalise(host)
        return h == "localhost" || h == "::1" || (isAddress(h) && h.hasPrefix("127."))
    }
}

/// A block of addresses (`10.0.0.0/8`) or a range (`10.0.0.1-10.0.0.50`), IPv4 or IPv6.
struct AddressRange {
    private enum Kind { case prefix([UInt8], Int), span([UInt8], [UInt8]) }
    private let kind: Kind
    init?(_ text: String) {
        if let slash = text.firstIndex(of: "/") {
            guard let bytes = Self.bytes(String(text[..<slash])), let bits = Int(text[text.index(after: slash)...]), bits >= 0, bits <= bytes.count * 8 else { return nil }
            kind = .prefix(bytes, bits)
        } else if let dash = text.firstIndex(of: "-"), let low = Self.bytes(String(text[..<dash])), let high = Self.bytes(String(text[text.index(after: dash)...])), low.count == high.count, low.lexicographicallyPrecedes(high) || low == high {
            kind = .span(low, high)
        } else { return nil }
    }
    static func bytes(_ text: String) -> [UInt8]? {
        var v4 = in_addr(); if inet_pton(AF_INET, text, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        var v6 = in6_addr(); if inet_pton(AF_INET6, text, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
        return nil
    }
    func contains(_ text: String) -> Bool {
        guard let address = Self.bytes(text) else { return false }
        switch kind {
        case let .prefix(base, bits):
            guard address.count == base.count else { return false }
            let whole = bits / 8, rest = bits % 8
            if whole > 0, Array(address[..<whole]) != Array(base[..<whole]) { return false }
            if rest == 0 { return true }
            let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - rest))
            return address[whole] & mask == base[whole] & mask
        case let .span(low, high):
            guard address.count == low.count else { return false }
            return !address.lexicographicallyPrecedes(low) && !high.lexicographicallyPrecedes(address)
        }
    }
}

/// Reads a block or allow list in the formats people actually find: a hosts file, one name per line, or an ad-blocker `||name^` list.
enum NetListParser {
    static func parse(_ text: String, limit: Int = NetList.maximumEntries) -> [String] {
        var out: [String] = []; var seen = Set<String>()
        let skip: Set<String> = ["localhost", "local", "broadcasthost", "localhost.localdomain", "ip6-localhost", "ip6-loopback", "0.0.0.0"]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("!") || line.hasPrefix("[") || line.hasPrefix("@@") { continue }
            if let hash = line.range(of: " #") { line = String(line[..<hash.lowerBound]) }
            var tokens: [String]
            if line.hasPrefix("||") {
                var name = String(line.dropFirst(2))
                guard name.hasSuffix("^") else { continue }
                name.removeLast()
                if name.contains("/") || name.contains("$") || name.contains("^") || name.contains("*") { continue }
                tokens = [name]
            } else {
                tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                if tokens.count >= 2, NetRuleEngine.isAddress(tokens[0]) { tokens.removeFirst() }       // hosts-file form: "0.0.0.0 name"
            }
            for token in tokens {
                let name = NetRuleEngine.normalise(token)
                guard !skip.contains(name), !name.hasPrefix("ip6-"), NetRuleEngine.isValidDestination(name), name != "*" else { continue }
                if !NetRuleEngine.isAddress(name), !name.contains("/"), !name.contains("*"), !name.contains(".") { continue }   // a bare label such as "com" would block everything
                if seen.insert(name).inserted { out.append(name); if out.count >= limit { return out } }
            }
        }
        return out
    }
}

/// Looks up a destination in the enabled lists. Whole names are found by a hash lookup on the name and each parent domain, so a list of
/// hundreds of thousands of entries costs the same as a short one; patterns and address blocks are checked one by one.
struct NetListIndex {
    private struct Side { var names: [String: String] = [:]; var addresses: [String: String] = [:]; var patterns: [(String, String)] = [] }
    private var block = Side(), allow = Side()
    var isEmpty: Bool { block.names.isEmpty && block.addresses.isEmpty && block.patterns.isEmpty && allow.names.isEmpty && allow.addresses.isEmpty && allow.patterns.isEmpty }
    init(_ lists: [NetList] = []) {
        for list in lists where list.enabled {
            var side = list.kind == .block ? block : allow
            for entry in list.entries.prefix(NetList.maximumEntries) {
                let e = NetRuleEngine.normalise(entry)
                if e.contains("*") || e.contains("/") || AddressRange(e) != nil { if side.patterns.count < 5000 { side.patterns.append((e, list.name)) } }
                else if NetRuleEngine.isAddress(e) { side.addresses[e] = side.addresses[e] ?? list.name }
                else { side.names[e] = side.names[e] ?? list.name }
            }
            if list.kind == .block { block = side } else { allow = side }
        }
    }
    /// The name of the list that matches, or nil.
    func match(_ kind: NetAction, host: String, address: String?) -> String? {
        let side = kind == .block ? block : allow
        let h = NetRuleEngine.normalise(host)
        for candidate in [h] + (address.map { [NetRuleEngine.normalise($0)] } ?? []) {
            if let name = side.addresses[candidate] { return name }
        }
        if !NetRuleEngine.isAddress(h) {
            var rest = Substring(h)
            while true {
                if let name = side.names[String(rest)] { return name }
                guard let dot = rest.firstIndex(of: ".") else { break }
                rest = rest[rest.index(after: dot)...]
            }
        }
        for (pattern, name) in side.patterns where NetRuleEngine.hostMatches(pattern, h, address: address) { return name }
        return nil
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
    /// Answers a question and, when `rule` is given (a NetRule, encoded), keeps it as the answer's scope and lifetime.
    func answerWithRule(_ id: Int64, allow: Bool, rule: Data, reply: @escaping (Bool) -> Void)
    func lists(reply: @escaping (Data) -> Void)
    func setLists(_ data: Data, reply: @escaping (Bool) -> Void)
    func usage(reply: @escaping (Data) -> Void)
    func audit(reply: @escaping (Data) -> Void)
}
