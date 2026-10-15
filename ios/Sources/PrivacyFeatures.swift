import Foundation
import Combine
import SafariServices
#if os(iOS)
import BackgroundTasks
#endif
import WebKit
import NetworkExtension
import SQLite3
import CryptoKit
import VayuSetuCore

struct LocalPrivacyEvent: Identifiable {
    let id: Int64
    let timestamp: Date
    let message: String
}

/// New filter metadata and privacy events live in SQLite; existing profile files retain their recovery semantics.
final class PrivacyDatabase {
    private var db: OpaquePointer?
    init(url: URL? = nil) throws {
        let directory = (url ?? LocalFiles.url("privacy.sqlite")).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = url ?? directory.appendingPathComponent("privacy.sqlite")
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw AppIssue(message: "Local privacy storage could not be opened.") }
        try execute("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY CHECK(id=1), data BLOB NOT NULL); CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY, time REAL NOT NULL, message TEXT NOT NULL); CREATE TABLE IF NOT EXISTS dns_intent (id INTEGER PRIMARY KEY CHECK(id=1), enabled INTEGER NOT NULL CHECK(enabled IN (0,1))); CREATE TABLE IF NOT EXISTS adblock_tests (id INTEGER PRIMARY KEY, time REAL NOT NULL, data BLOB NOT NULL); CREATE TABLE IF NOT EXISTS activity (bucket INTEGER PRIMARY KEY, requests INTEGER NOT NULL, blocked INTEGER NOT NULL, threats INTEGER NOT NULL);")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        // The settings used to hold every downloaded rule; once they are small again the file keeps its old size until it is compacted.
        if ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 20_000_000, let stateSize = try? stateLength(), stateSize < 5_000_000 { try? execute("VACUUM") }
    }
    private func stateLength() throws -> Int {
        var statement: OpaquePointer?; defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(LENGTH(data)),0) FROM state", -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else { throw AppIssue(message: "unreadable") }
        return Int(sqlite3_column_int64(statement, 0))
    }
    deinit { sqlite3_close(db) }
    private func execute(_ sql: String) throws { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw AppIssue(message: "Local privacy storage update failed.") } }
    func read() throws -> Data? {
        var statement: OpaquePointer?; defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT data FROM state WHERE id=1", -1, &statement, nil) == SQLITE_OK else { throw AppIssue(message: "Could not read privacy preferences.") }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let blob = sqlite3_column_blob(statement, 0) else { throw AppIssue(message: "Could not read privacy preferences.") }
        return Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 0)))
    }
    func save(_ data: Data) throws {
        var statement: OpaquePointer?; defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO state(id,data) VALUES(1,?)", -1, &statement, nil) == SQLITE_OK else { throw AppIssue(message: "Could not save privacy preferences.") }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let bound = data.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32($0.count), transient) }
        guard bound == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw AppIssue(message: "Could not save privacy preferences.") }
    }
    func event(_ message: String) throws {
        var statement: OpaquePointer?; defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "INSERT INTO events(time,message) VALUES(?,?)", -1, &statement, nil) == SQLITE_OK else { throw AppIssue(message: "Could not record privacy event.") }
        sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(statement, 2, message, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_DONE else { throw AppIssue(message: "Could not record privacy event.") }
        let chosen = UserDefaults.standard.integer(forKey: "local-events-retention-days")
        let days = [1,7,30].contains(chosen) ? chosen : 7
        try execute("DELETE FROM events WHERE time < \(Date().addingTimeInterval(-Double(days)*86400).timeIntervalSince1970); DELETE FROM events WHERE id NOT IN (SELECT id FROM events ORDER BY id DESC LIMIT 200);")
    }
    func recentEvents() -> [LocalPrivacyEvent] {
        var statement: OpaquePointer?; defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT id,time,message FROM events ORDER BY time DESC,id DESC LIMIT 200", -1, &statement, nil) == SQLITE_OK else { return [] }
        var result: [LocalPrivacyEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 2) {
                result.append(LocalPrivacyEvent(id: sqlite3_column_int64(statement, 0), timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)), message: String(cString: text)))
            }
        }
        return result
    }
    func events() -> [String] { recentEvents().map { $0.timestamp.formatted() + " · " + $0.message } }
    func dnsIntent() -> Bool? {
        var statement: OpaquePointer?; defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT enabled FROM dns_intent WHERE id=1", -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int(statement, 0) == 1
    }
    func setDNSIntent(_ enabled: Bool) throws { try execute("INSERT OR REPLACE INTO dns_intent(id,enabled) VALUES(1,\(enabled ? 1 : 0))") }
    /// DNS activity observed by VayuSetu, aggregated in 10-minute buckets and kept for a year. No domain names are stored.
    func addActivity(bucket: Int, requests: Int, blocked: Int, threats: Int) throws {
        try execute("INSERT INTO activity(bucket,requests,blocked,threats) VALUES(\(bucket),\(requests),\(blocked),\(threats)) ON CONFLICT(bucket) DO UPDATE SET requests=requests+\(requests), blocked=blocked+\(blocked), threats=threats+\(threats); DELETE FROM activity WHERE bucket < \(bucket - 366 * 144);")
    }
    func activity(fromBucket: Int) -> [ActivityBucket] {
        var statement: OpaquePointer?; defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT bucket,requests,blocked,threats FROM activity WHERE bucket >= \(fromBucket) ORDER BY bucket", -1, &statement, nil) == SQLITE_OK else { return [] }
        var rows: [ActivityBucket] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(ActivityBucket(bucket: Int(sqlite3_column_int64(statement, 0)), requests: Int(sqlite3_column_int64(statement, 1)), blocked: Int(sqlite3_column_int64(statement, 2)), threats: Int(sqlite3_column_int64(statement, 3))))
        }
        return rows
    }
    func clearActivity() throws { try execute("DELETE FROM activity") }
    func addTestRun(_ data: Data) throws {
        var statement: OpaquePointer?; defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "INSERT INTO adblock_tests(time,data) VALUES(?,?)", -1, &statement, nil) == SQLITE_OK else { throw AppIssue(message: "Could not save the test result.") }
        sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw AppIssue(message: "Could not save the test result.") }
        try execute("DELETE FROM adblock_tests WHERE id NOT IN (SELECT id FROM adblock_tests ORDER BY id DESC LIMIT 100)")
    }
    func testRuns() -> [Data] {
        var statement: OpaquePointer?; defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT data FROM adblock_tests ORDER BY id DESC LIMIT 100", -1, &statement, nil) == SQLITE_OK else { return [] }
        var rows: [Data] = []
        while sqlite3_step(statement) == SQLITE_ROW { if let blob = sqlite3_column_blob(statement, 0) { rows.append(Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 0)))) } }
        return rows
    }
    func clearTestRuns() throws { try execute("DELETE FROM adblock_tests") }
    func clearEvents() throws { try execute("DELETE FROM events") }
}
struct FilterSubscription: Codable, Identifiable {
    var id = UUID(); var name: String; var url: String; var enabled = false
    var rules: [FilterRule] = []; var updated: Date?; var rejected = 0; var checksum = ""; var etag: String?
    /// Page-element hiding and URL-pattern rules for Safari, read from lists that have them (EasyList and relatives). DNS ignores these.
    var content: ContentRuleSet?
}
/// The downloaded rules of one list. Stored in their own file so the saved settings stay small.
/// One finished run of the in-app adblock test, kept so results can be compared over time.
struct AdblockTestRun: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var percent: Int
    var tested: Int
    var blocked: Int
    /// Per group: blocked and tested counts.
    var groups: [String: [Int]]
    var missed: [String]
    var safariRulesLoaded: Bool
    var rulesExtensions: Int
    var dnsFiltering: Bool
    var listsOn: Int
    /// Light, Balanced, Strict or Custom when the test ran.
    var mode: String?
}
struct SubscriptionPayload: Codable {
    /// Compact form: one `<b|a><s|e> <domain>` line per rule, all sharing `source`. `rules` is the older, much larger form.
    var packed: String?; var source: String?
    var rules: [FilterRule]?; var content: ContentRuleSet?
    init(rules: [FilterRule], content: ContentRuleSet?) {
        self.content = content
        let sources = Set(rules.map(\.source))
        if sources.count == 1, rules.allSatisfy({ $0.tier == .subscription && $0.enabled != false }) {
            source = sources.first
            packed = rules.map { ($0.action == .allow ? "a" : "b") + ($0.scope == .exact ? "e" : "s") + " " + $0.domain }.joined(separator: "\n")
        } else { self.rules = rules }
    }
    var unpacked: [FilterRule] {
        if let rules { return rules }
        guard let packed, let source else { return [] }
        return packed.split(separator: "\n").compactMap { line in
            guard line.count > 3 else { return nil }
            let action: FilterAction = line.first == "a" ? .allow : .block
            let scope: FilterScope = line.dropFirst().first == "e" ? .exact : .domainAndSubdomains
            let domain = String(line.dropFirst(3))
            return FilterRule(trustedID: source + ":" + action.rawValue + ":" + scope.rawValue + ":" + domain, domain: domain, action: action, scope: scope, tier: .subscription, source: source)
        }
    }
}
struct FilterConfiguration: Codable {
    var version = 1; var generation: UUID?; var latestReload: Date?; var pendingApply: Bool?; var rules: [FilterRule] = []
    var subscriptions: [FilterSubscription] = FilterCatalog.defaults.map { FilterSubscription(name: $0.name, url: $0.url) }
    /// Catalogue lists the user removed; they are not re-added at launch (they can be added again from the catalogue).
    var removedCatalog: [String]? = nil
    var safariDesired = false
    /// Set once the preinstalled lists were switched on (fresh installs only; nil means an install that predates this).
    var defaultsEnabled: Bool? = nil
    /// Safari's budget fit at the last compile: rules sent to Safari, out of the rules selected.
    var safariApplied: Int? = nil
    /// Which version of the rule builder made the packages now in Safari; a newer app rebuilds them once so ranking fixes take effect.
    var compilerVersion: Int? = nil
    /// Version of the list parser that produced the stored rules. Version 1 read page-element lines as whole-site blocks, so those lists are fetched again.
    var parserVersion: Int? = nil
    static let currentParserVersion = 2
    static let currentCompilerVersion = 5
    /// Distinct rules across everything switched on, worked out when the settings are saved (counting them on every redraw would be slow).
    var uniqueRules: Int? = nil
    /// Resource classes Safari should refuse everywhere ("font", "image", "script").
    var resourceBlocks: [String]? = nil
    /// Rules compiled for each extension at the last update (keyed by SafariExtensionID.rawValue). An extension with 0 needs no enabling in Safari.
    var safariExtensionRules: [String: Int]? = nil
    var safariCandidates: Int? = nil
    var effective: [FilterRule] { rules.filter { $0.enabled != false } + subscriptions.filter(\.enabled).flatMap(\.rules) }
    /// Rules after removing repeats: two lists naming the same domain count once, which is what the phone really has to hold.
    var uniqueEffectiveCount: Int {
        var seen = Set<String>()
        for rule in effective { seen.insert(rule.domain + (rule.scope == .exact ? "|e" : "|s") + (rule.action == .allow ? "a" : "b")) }
        return seen.count
    }
}
private struct SafariUpdateJournal: Codable { let previous: [String: Data]; let pendingGeneration: UUID }
/// What the app last observed about one Safari extension.
struct SafariExtensionState: Equatable { var enabled: Bool?; var reloaded = false; var failure: String? }
private final class HTTPSListDelegate: NSObject, URLSessionTaskDelegate {
    static func valid(_ url: URL) -> Bool { url.scheme == "https" && url.user == nil && url.password == nil && url.host != nil && url.fragment == nil }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(Self.valid) == true ? request : nil)
    }
}
@MainActor final class FilteringController: ObservableObject {
    @Published private(set) var configuration = FilterConfiguration()
    @Published private(set) var enabled: Bool?
    @Published private(set) var observedAt: Date?
    @Published private(set) var packageReady = false
    @Published private(set) var lastReload: Date?
    @Published private(set) var busy = false
    /// The list being downloaded or updated right now, so its row can show progress.
    @Published private(set) var activeListID: UUID?
    @Published private(set) var message = ""
    @Published private(set) var events: [String] = []
    @Published private(set) var recentEvents: [LocalPrivacyEvent] = []
    @Published private(set) var failureDetails = ""
    /// What a long operation is doing right now, for the screens to show.
    @Published private(set) var operationStatus = ""
    private var database: PrivacyDatabase?
    private var persistedStamp: [UUID: String] = [:]
    private func payloadURL(_ id: UUID) -> URL { LocalFiles.url("lists/\(id.uuidString).json") }
    private func stamp(_ sub: FilterSubscription) -> String { "\(sub.checksum)|\(sub.updated?.timeIntervalSince1970 ?? 0)|\(sub.rules.count)|\(sub.content?.count ?? 0)" }
    /// Saves the settings without the downloaded rules (megabytes per list) and writes each list's rules to its own file, only when they changed.
    private func persist(_ config: FilterConfiguration) throws {
        var light = config
        for index in light.subscriptions.indices {
            let sub = config.subscriptions[index]
            if (!sub.rules.isEmpty || sub.content != nil), persistedStamp[sub.id] != stamp(sub) {
                try LocalFiles.write(JSONEncoder().encode(SubscriptionPayload(rules: sub.rules, content: sub.content)), to: payloadURL(sub.id))
                persistedStamp[sub.id] = stamp(sub)
            }
            light.subscriptions[index].rules = []; light.subscriptions[index].content = nil
        }
        try database?.save(JSONEncoder().encode(light))
        // Forget files of lists that no longer exist.
        let keep = Set(config.subscriptions.map { $0.id.uuidString + ".json" })
        let directory = payloadURL(UUID()).deletingLastPathComponent()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where !keep.contains(name) { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
    }
    private var writable = true
    private var recoveryReload = false
    private var launchReloadTried = false
    private var staleRebuildTried = false
    /// Lists whose stored rules were dropped by a parser fix and are downloaded again after launch.
    private var needsRefetch: [UUID] = []
    @Published private(set) var extensionStates: [SafariExtensionID: SafariExtensionState] = [:]
    /// How long WebKit took to compile each extension's rules in the last check, in seconds.
    @Published private(set) var compileSeconds: [SafariExtensionID: Double] = [:]
    /// What the extension itself last logged (when Safari asked for rules and what it returned).
    func extensionLog(_ id: SafariExtensionID) -> String {
        guard let directory = packageDirectory, let text = try? String(contentsOf: directory.appendingPathComponent(id.fileName.replacingOccurrences(of: ".json", with: ".log")), encoding: .utf8) else { return "Safari has not asked this extension for rules yet" }
        guard let line = text.split(separator: "\n").last else { return "No requests logged" }
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, let date = ISO8601DateFormatter().date(from: parts[0]) else { return String(line) }
        let when = date.formatted(.relative(presentation: .named, unitsStyle: .wide))
        let size = Int(parts[1].split(separator: " ").dropFirst().first ?? "").map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        return "Safari last loaded this \(when)" + (size.map { " · \($0) of rules" } ?? "")
    }
    /// Safari's own rule compiler (WebKit) is the authority on whether rules are valid. Compile here first so a rule it rejects, or a
    /// package it takes too long over, never reaches the extensions.
    private func validateWithWebKit(_ id: SafariExtensionID, _ data: Data) async throws {
        guard let text = String(data: data, encoding: .utf8), let store = WKContentRuleListStore.default() else { throw AppIssue(message: "Safari’s rule compiler is unavailable.") }
        let name = "vayusetu-check-" + id.rawValue
        let start = Date()
        do { _ = try await store.compileContentRuleList(forIdentifier: name, encodedContentRuleList: text) }
        catch { throw AppIssue(message: "Safari’s rule compiler rejected the \(id.title) rules: \(error.localizedDescription)") }
        compileSeconds[id] = Date().timeIntervalSince(start)
        record("WebKit compiled \(id.title) in \(String(format: "%.1f", compileSeconds[id] ?? 0)) s")
        try? await store.removeContentRuleList(forIdentifier: name)
    }
    private var packageDirectory: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "VayuAppGroup") as? String,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return container
    }
    private func fileURL(_ id: SafariExtensionID) -> URL? { packageDirectory?.appendingPathComponent(id.fileName) }
    func identifier(for id: SafariExtensionID) -> String { (Bundle.main.bundleIdentifier ?? "app.vayusetu.ios") + "." + id.bundleSuffix }
    /// Extensions that hold rules and so must be switched on in Safari. With nothing compiled yet, Ads stands in.
    var neededExtensions: [SafariExtensionID] {
        let counts = configuration.safariExtensionRules ?? [:]
        let needed = SafariExtensionID.allCases.filter { (counts[$0.rawValue] ?? 0) > 0 }
        return needed.isEmpty ? [.ads] : needed
    }
    var neededIdentifiers: [String] { neededExtensions.map(identifier(for:)) }
    /// The first needed extension, for callers that need a single identifier.
    var identifier: String { identifier(for: neededExtensions[0]) }
    var extensionSummary: String {
        let needed = neededExtensions
        let on = needed.filter { extensionStates[$0]?.enabled == true }.count
        return "\(on) of \(needed.count) extension\(needed.count == 1 ? "" : "s") enabled"
    }
    private func recomputeAggregates() {
        let needed = neededExtensions
        let values = needed.map { extensionStates[$0]?.enabled }
        enabled = values.allSatisfy { $0 == true } ? true : values.contains { $0 == nil } ? nil : false
        packageReady = needed.allSatisfy { extensionStates[$0]?.reloaded == true }
    }
    init() {
        if UserDefaults.standard.integer(forKey: "safari.fitBudget") > 0 { SafariRuleCompiler.fitBudget = UserDefaults.standard.integer(forKey: "safari.fitBudget") }
        do {
            database = try PrivacyDatabase()
            if let data = try database?.read() {
                var stored = try JSONDecoder().decode(FilterConfiguration.self, from: data)
                var oldBlob = data.count > 5_000_000
                var refetch = false
                // Downloaded rules live in per-list files; an older install still has them inside the settings blob (loaded above).
                for index in stored.subscriptions.indices {
                    let sub = stored.subscriptions[index]
                    guard sub.rules.isEmpty, sub.content == nil, let file = try? Data(contentsOf: payloadURL(sub.id)), let payload = try? JSONDecoder().decode(SubscriptionPayload.self, from: file) else { continue }
                    stored.subscriptions[index].rules = payload.unpacked; stored.subscriptions[index].content = payload.content
                    if payload.packed != nil { persistedStamp[sub.id] = stamp(stored.subscriptions[index]) } else { oldBlob = true }   // an older, larger file gets rewritten compactly
                }
                // Older rules from lists that contain page-element lines were parsed wrongly (sites like github.com became blocks): drop them so they are downloaded and read again.
                if (stored.parserVersion ?? 0) < FilterConfiguration.currentParserVersion {
                    for index in stored.subscriptions.indices where stored.subscriptions[index].content != nil {
                        stored.subscriptions[index].rules = []; stored.subscriptions[index].content = nil; stored.subscriptions[index].etag = nil; stored.subscriptions[index].checksum = ""
                        persistedStamp[stored.subscriptions[index].id] = nil; refetch = true
                    }
                    stored.parserVersion = FilterConfiguration.currentParserVersion; oldBlob = true
                }
                if refetch { needsRefetch = stored.subscriptions.filter { $0.enabled && $0.content == nil && $0.rules.isEmpty && FilterCatalog.entry(forURL: $0.url).map { _ in true } == true }.map(\.id) }
                defer { if oldBlob { try? persist(configuration) } }
                guard stored.version == 1, stored.effective.count <= FilterParser.combinedLimit else { throw FilteringIssue.capacity }
                // Rules a person typed are re-checked; downloaded rules were validated when they were parsed and are not re-parsed on every launch.
                for rule in stored.rules { guard try FilterDomain.normalize(rule.domain) == rule.domain else { throw FilteringIssue.invalidDomain } }
                var migrated = stored
                for index in migrated.subscriptions.indices where migrated.subscriptions[index].url == "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/domains/light.txt" {
                    migrated.subscriptions[index].url = "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/light.txt"
                }
                // Existing installs gain newly added catalog lists, never losing their own selection.
                for entry in FilterCatalog.defaults where !migrated.subscriptions.contains(where: { $0.url == entry.url }) && !(migrated.removedCatalog ?? []).contains(entry.url) {
                    migrated.subscriptions.append(FilterSubscription(name: entry.name, url: entry.url))
                }
                // An install that already switched lists on keeps its own selection; one with nothing on gets the preinstalled four.
                if migrated.defaultsEnabled == nil { migrated.defaultsEnabled = migrated.subscriptions.contains(where: \.enabled) }
                configuration = migrated; lastReload = migrated.latestReload
            } else { configuration.defaultsEnabled = false }
            if let directory = packageDirectory {
                let journalURL = directory.appendingPathComponent("safari-update-journal.json")
                if FileManager.default.fileExists(atPath: journalURL.path) {
                    guard (try journalURL.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max <= 160_000_000 else { throw FilteringIssue.tooLarge }
                    let journal = try JSONDecoder().decode(SafariUpdateJournal.self, from: Data(contentsOf: journalURL))
                    if configuration.generation != journal.pendingGeneration {
                        for (key, data) in journal.previous {
                            guard let id = SafariExtensionID(rawValue: key), data.count <= 25_000_000 else { throw FilteringIssue.tooLarge }
                            try data.write(to: directory.appendingPathComponent(id.fileName), options: .atomic)
                        }
                        recoveryReload = true
                    }
                    try FileManager.default.removeItem(at: journalURL)
                }
            }
            events = database?.events() ?? []; recentEvents = database?.recentEvents() ?? []
        } catch { writable = false; message = "Saved filtering data needs recovery. Original data has been preserved; updates are blocked." }
    }
    private func observedEnabled(_ id: SafariExtensionID) async -> Bool? {
        let identifier = identifier(for: id)
        return try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            SFContentBlockerManager.getStateOfContentBlocker(withIdentifier: identifier) { state, error in
                if let error { continuation.resume(throwing: error) } else if let state { continuation.resume(returning: state.isEnabled) } else { continuation.resume(throwing: AppIssue(message: "Safari state unavailable.")) }
            }
        }
    }
    func refresh() async {
        if !needsRefetch.isEmpty { let ids = needsRefetch; needsRefetch = []; record("Re-reading \(ids.count) lists with the corrected parser"); for id in ids { await updateList(id) } }
        let wasEnabled = enabled
        if recoveryReload {
            for id in SafariExtensionID.allCases where (try? FileManager.default.attributesOfItem(atPath: fileURL(id)?.path ?? ""))?[.size] != nil { try? await reloadSafari(id) }
            recoveryReload = false; record("Interrupted Safari update recovered; previous rules reloaded")
        }
        for id in SafariExtensionID.allCases {
            var state = extensionStates[id] ?? SafariExtensionState()
            state.enabled = await observedEnabled(id)
            if state.enabled != true { state.reloaded = false }
            // Safari keeps a loaded blocker across app launches. If it acknowledged this exact package earlier and the extension is
            // still switched on, it is still loaded: no need to show "not loaded" or to reload six large rule sets at every launch.
            else if !state.reloaded, let signature = packageSignature(id), UserDefaults.standard.string(forKey: "safari.ack." + id.rawValue) == signature { state.reloaded = true }
            extensionStates[id] = state
        }
        observedAt = Date(); recomputeAggregates()
        if neededExtensions.allSatisfy({ extensionStates[$0]?.enabled == nil }) { message = "Safari state unavailable."; return }
        if configuration.safariDesired, (configuration.compilerVersion ?? 0) < FilterConfiguration.currentCompilerVersion, !busy, !staleRebuildTried {
            staleRebuildTried = true; record("Rebuilding Safari rules with the newer rule builder"); await reload()
        } else if wasEnabled != true && enabled == true && configuration.pendingApply == true && !busy { await reload() }
        else if configuration.safariDesired, !packageReady, !busy, !launchReloadTried, configuration.latestReload != nil, configuration.pendingApply != true {
            // After a relaunch nothing has been acknowledged yet. Ask each enabled extension to load the package already published;
            // only Safari's acknowledgement turns the status green.
            launchReloadTried = true
            for id in neededExtensions where extensionStates[id]?.enabled == true {
                guard let url = fileURL(id), FileManager.default.fileExists(atPath: url.path) else { continue }
                do { try await reloadSafari(id); extensionStates[id]?.reloaded = true } catch { extensionStates[id]?.failure = Self.safariFailure(error); failureDetails = Self.safariFailure(error) }
            }
            recomputeAggregates()
            if packageReady { record("Safari rules reload acknowledged") }
        }
    }
    func snapshot(now: Date = .now) -> ProtectionSnapshot {
        let state: ObservedState = enabled == nil ? .unknown : enabled == false ? .inactive : packageReady ? .active : .enabledNotVerified
        return PrivacyIntegrityEngine.reconcile(ProtectionSnapshot(.safari, desired: configuration.safariDesired, state: state, source: .osStatus, at: observedAt, reason: enabled == true ? (packageReady ? "Safari reports enabled; rules reloaded. Individual rule effectiveness remains unmeasured." : "Safari reports enabled; reload the ruleset to establish readiness.") : "Enable VayuSetu in Safari’s extension settings, then refresh."), now: now)
    }
    func adblockSnapshot(now: Date = .now) -> ProtectionSnapshot {
        let safari = snapshot(now: now)
        let intent = configuration.safariDesired && !configuration.effective.isEmpty
        return ProtectionSnapshot(.adblock, desired: intent, state: !intent ? .inactive : safari.observed, source: .extensionAcknowledgement, at: safari.observedAt, stale: safari.stale, reason: "Safari rules: \(configuration.effective.count). Safari does not expose per-request blocking counts. Tunnel-local DNS enforcement is unavailable; upstream filtering is evaluated separately in Checks.")
    }
    func addRule(domain: String, action: FilterAction, scope: FilterScope) async {
        await exclusive { [self] in
        do { var draft = configuration; draft.rules.append(try FilterRule(domain: domain, action: action, scope: scope)); try await commit(draft) }
        catch { message = error.localizedDescription }
        }
    }
    static let siteExceptionSource = "Website exception"
    func upsertRule(id: String?, domain: String, action: FilterAction, scope: FilterScope, enabled: Bool, source: String = "User") async {
        await exclusive { [self] in
        do {
            let rule = try FilterRule(id: id ?? UUID().uuidString, domain: domain, action: action, scope: scope, source: source, enabled: enabled)
            var draft = configuration
            if let index = draft.rules.firstIndex(where: { $0.id == rule.id }) { draft.rules[index] = rule } else { draft.rules.append(rule) }
            try await commit(draft)
        } catch { message = error.localizedDescription }
        }
    }
    // MARK: DNS activity (Safari's blocker reports nothing, so this is DNS filtering only)
    @Published private(set) var statsRevision = 0
    private func counted(_ key: String) -> UInt64 { UInt64(UserDefaults.standard.integer(forKey: key)) }
    /// Feed the tunnel's cumulative counters; only the increase since the last sample is stored. A lower value means the tunnel restarted.
    func ingest(_ counters: DNSOnlyCounters?) {
        guard let counters, let database else { return }
        func delta(_ now: UInt64, _ key: String) -> UInt64 { let before = counted(key); UserDefaults.standard.set(Int(now), forKey: key); return now >= before ? now - before : now }
        let requests = delta(counters.queries, "activity.counted.queries"), blocked = delta(counters.blocked, "activity.counted.blocked"), threats = delta(counters.threats, "activity.counted.threats")
        guard requests > 0 || blocked > 0 else { return }
        let b = Int(min(blocked, requests == 0 ? blocked : max(requests, blocked)))
        try? database.addActivity(bucket: Int(Date().timeIntervalSince1970 / 600), requests: Int(max(requests, UInt64(b))), blocked: b, threats: Int(min(threats, UInt64(b))))
        statsRevision += 1
    }
    func activitySeries(_ period: ActivityPeriod, now: Date = .now) -> ActivitySeries {
        _ = statsRevision
        let calendar = Calendar.current
        let start = period.start(now: now, calendar: calendar)
        let rows = database?.activity(fromBucket: Int((start?.timeIntervalSince1970 ?? 0) / 600)) ?? []
        return ActivitySeries.make(period: period, rows: rows, now: now, calendar: calendar)
    }
    func clearActivity() { try? database?.clearActivity(); statsRevision += 1 }
    // MARK: Adblock test history
    @Published private(set) var testHistory: [AdblockTestRun] = []
    func loadTestHistory() { testHistory = (database?.testRuns() ?? []).compactMap { try? JSONDecoder().decode(AdblockTestRun.self, from: $0) } }
    func saveTestRun(_ run: AdblockTestRun) {
        if let data = try? JSONEncoder().encode(run) { try? database?.addTestRun(data) }
        loadTestHistory()
    }
    func clearTestHistory() { try? database?.clearTestRuns(); testHistory = [] }
    /// Runs when iOS wakes the app in the background: re-download lists that are over 12 hours old (at most four, to stay within the
    /// time iOS allows), which recompiles the rules, checks them with Safari's compiler and reloads the extensions.
    func backgroundRefresh() async {
        await refresh()
        let cutoff = Date().addingTimeInterval(-12 * 3600)
        let stale = configuration.subscriptions.filter { $0.enabled && $0.url != "Local file" && ($0.updated.map { $0 < cutoff } ?? true) }.prefix(4)
        for list in stale { guard !Task.isCancelled else { break }; await updateList(list.id) }
        record("Background refresh · \(stale.count) list\(stale.count == 1 ? "" : "s") updated")
    }
    // MARK: Presets, budget and the blocking test
    /// Switches the named catalogue lists on and every other catalogue list that a General switch manages off, with as few rebuilds as possible.
    /// Switches the named catalogue lists on and every other catalogue list that a General switch manages off. Lists that still need
    /// downloading are fetched first and everything is saved in ONE rebuild, so a preset costs one compile, not one per list.
    func applyLists(on names: Set<String>, managed: Set<String>) async {
        await exclusive { [self] in
            record("Preset: \(names.count) lists on, \(managed.subtracting(names).count) off")
            let before = configuration          // restored if the preset cannot be saved, so the screen never claims a state that was not applied
            var draft = configuration
            var pending: [UUID] = []
            for name in names {
                guard let entry = FilterCatalog.all.first(where: { $0.name == name }) else { record("Preset: \(name) is not in the catalogue"); continue }
                if let index = draft.subscriptions.firstIndex(where: { $0.url == entry.url }) {
                    draft.subscriptions[index].enabled = true
                    if draft.subscriptions[index].rules.isEmpty && draft.subscriptions[index].content == nil { pending.append(draft.subscriptions[index].id) }
                } else {
                    var sub = FilterSubscription(name: entry.name, url: entry.url); sub.enabled = true; draft.subscriptions.append(sub); pending.append(sub.id)
                    draft.removedCatalog = (draft.removedCatalog ?? []).filter { $0 != entry.url }
                }
            }
            for name in managed.subtracting(names) {
                if let entry = FilterCatalog.all.first(where: { $0.name == name }), let index = draft.subscriptions.firstIndex(where: { $0.url == entry.url }) { draft.subscriptions[index].enabled = false }
            }
            // The new subscriptions must exist in the live configuration before they can be downloaded.
            if !pending.isEmpty { configuration = draft }
            var failed: [String] = []
            busy = true
            for (position, id) in pending.enumerated() {
                let name = draft.subscriptions.first { $0.id == id }?.name ?? "list"
                operationStatus = "Downloading \(position + 1) of \(pending.count): \(name)"; activeListID = id
                do {
                    let sub = try await fetchSubscription(id)
                    if let index = draft.subscriptions.firstIndex(where: { $0.id == id }) { var fresh = sub; fresh.enabled = true; draft.subscriptions[index] = fresh }
                } catch {
                    failed.append(name); record("Filter-list update failed: \(name): \(failureText(error))")
                    if let index = draft.subscriptions.firstIndex(where: { $0.id == id }) { draft.subscriptions[index].enabled = false }
                }
            }
            busy = false; activeListID = nil; operationStatus = "Applying rules…"
            var saved = true
            do { try await commit(draft) } catch {
                saved = false
                configuration = before
                message = "Nothing was changed: " + error.localizedDescription
                record("Preset failed to save: \(error.localizedDescription)")
            }
            operationStatus = ""
            if saved {
                if !failed.isEmpty { message = "Could not download: " + failed.joined(separator: ", ") + ". The rest are on." }
                record("Preset done: \(names.count - failed.count) on\(failed.isEmpty ? "" : ", \(failed.count) failed")")
            }
        }
    }
    func setRulesPerExtension(_ value: Int) async {
        await exclusive { [self] in
        let clamped = min(max(value, 10_000), 100_000)
        UserDefaults.standard.set(clamped, forKey: "safari.fitBudget"); SafariRuleCompiler.fitBudget = clamped
        await reload()
        }
    }
    /// Compiles the published Safari packages into WebKit rule lists for an in-app test. Empty when Safari protection holds no rules.
    func compiledRuleListsForTest() async -> [WKContentRuleList] {
        guard let directory = packageDirectory, let store = WKContentRuleListStore.default() else { return [] }
        var lists: [WKContentRuleList] = []
        for id in SafariExtensionID.allCases {
            guard configuration.safariDesired, (configuration.safariExtensionRules?[id.rawValue] ?? 0) > 0, let data = try? Data(contentsOf: directory.appendingPathComponent(id.fileName)), let text = String(data: data, encoding: .utf8) else { continue }
            if let list = try? await store.compileContentRuleList(forIdentifier: "vayusetu-test-" + id.rawValue, encodedContentRuleList: text) { lists.append(list) }
        }
        return lists
    }
    func removeTestRuleLists() async {
        guard let store = WKContentRuleListStore.default() else { return }
        for id in SafariExtensionID.allCases { try? await store.removeContentRuleList(forIdentifier: "vayusetu-test-" + id.rawValue) }
    }
    /// Loads the compiled packages into a web view (WebKit is Safari's engine) and checks that a blocked name is refused while the same
    /// request without rules goes through. The test page runs in this app, not in Safari, so it proves the rules work, not that the
    /// Safari extensions are enabled. A DNS filter that is already blocking the name makes the check inconclusive.
    func testBlocking() async -> String {
        guard let directory = packageDirectory else { return "The shared rules folder is unavailable." }
        let store = WKContentRuleListStore.default()!
        var lists: [WKContentRuleList] = []
        for id in SafariExtensionID.allCases {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(id.fileName)), let text = String(data: data, encoding: .utf8), (configuration.safariExtensionRules?[id.rawValue] ?? 0) > 0 else { continue }
            if let list = try? await store.compileContentRuleList(forIdentifier: "vayusetu-test-" + id.rawValue, encodedContentRuleList: text) { lists.append(list) }
        }
        guard !lists.isEmpty else { return "There are no Safari rules to test yet. Turn on Block in Safari and pick a filter first." }
        let pool = Array(Set(configuration.subscriptions.filter(\.enabled).flatMap(\.rules).filter { $0.action == .block && $0.scope == .domainAndSubdomains }.map(\.domain)))
        guard !pool.isEmpty else { return "Your rules hold no domain blocks to sample." }
        let sample = Array(pool.shuffled().prefix(40))
        let with = await fetchStates(sample, lists: lists)
        let without = await fetchStates(sample, lists: [])
        for id in SafariExtensionID.allCases { try? await store.removeContentRuleList(forIdentifier: "vayusetu-test-" + id.rawValue) }
        // Only names that actually answer without the rules say anything: a dead domain looks blocked either way.
        let reachable = sample.filter { without[$0] == "allowed" }
        guard reachable.count >= 3 else { return "Inconclusive: only \(reachable.count) of \(sample.count) sampled domains answer at all, so there is nothing to compare. Try again on another network." }
        let blocked = reachable.filter { with[$0] == "blocked" }.count
        let percent = Int((Double(blocked) / Double(reachable.count) * 100).rounded())
        return "\(blocked) of \(reachable.count) reachable ad and tracker domains from your lists were blocked by your Safari rules (\(percent)%). This runs the rules in WebKit, Safari's engine, on a random sample; it does not measure real pages or show that the Safari extensions are switched on."
    }
    func fetchStates(_ domains: [String], lists: [WKContentRuleList]) async -> [String: String] {
        let config = WKWebViewConfiguration()
        for list in lists { config.userContentController.add(list) }
        let view = WKWebView(frame: .zero, configuration: config)
        defer { view.stopLoading() }
        // loadHTMLString returns at once; running the script before the page has loaded makes every fetch look blocked.
        let waiter = LoadWaiter()
        await waiter.load("<html><body></body></html>", in: view)
        defer { withExtendedLifetime(waiter) {} }
        let script = """
        const out = {};
        await Promise.all(domains.map(async (d) => {
          const c = new AbortController(); const t = setTimeout(() => c.abort(), 5000);
          try { await fetch('https://' + d + '/', {mode: 'no-cors', signal: c.signal, cache: 'no-store'}); out[d] = 'allowed'; } catch (e) { out[d] = 'blocked'; }
          clearTimeout(t);
        }));
        return out;
        """
        let result = try? await view.callAsyncJavaScript(script, arguments: ["domains": domains], in: nil, contentWorld: .page)
        return (result as? [String: String]) ?? [:]
    }
    // MARK: Test a website
    struct WebsiteCheck: Equatable {
        struct Verdict: Equatable { var title: String; var detail: String; var blocked: Bool? }
        var host: String
        var safari: Verdict
        var dns: Verdict
    }
    private func listName(forSource source: String) -> String {
        if source == FilteringController.siteExceptionSource { return "your website exception" }
        if source == "User" { return "your own rules" }
        return configuration.subscriptions.first { $0.id.uuidString == source }?.name ?? source
    }
    /// Answers "would VayuSetu block this?" for both engines from what is really installed, not from a guess: the DNS answer comes from the
    /// compiled DNS filter, and the Safari answer from the rules Safari actually received, checked by loading the site with and without them.
    func checkWebsite(_ input: String) async -> WebsiteCheck? {
        let typed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let host = URL(string: typed.contains("://") ? typed : "https://" + typed)?.host ?? typed
        guard let normal = try? FilterDomain.normalize(host) else { message = "Enter a website such as example.com."; return nil }
        // Rule that wins for this name (user rules beat lists, specific beats general).
        let match = try? RuleEngine.match(normal, rules: configuration.effective)
        let exception = configuration.rules.first { $0.source == FilteringController.siteExceptionSource && $0.enabled != false && (normal == $0.domain || normal.hasSuffix("." + $0.domain)) }

        // DNS
        let decision = dnsRuleSnapshot().decide(normal)
        var dns = WebsiteCheck.Verdict(title: "Not blocked", detail: "No rule matches \(normal).", blocked: false)
        if decision == .block, let rule = match?.rule { dns = .init(title: "Blocked", detail: "\(rule.domain) is on \(listName(forSource: rule.source)).", blocked: true) }
        else if decision == .allow { dns = .init(title: "Allowed", detail: "A rule from \(match.map { listName(forSource: $0.rule.source) } ?? "your rules") lets this through.", blocked: false) }
        dns.detail += " This applies while VayuSetu DNS is on."

        // Safari
        guard configuration.safariDesired else {
            return WebsiteCheck(host: normal, safari: .init(title: "Safari blocking is off", detail: "Turn on Block in Safari on the Adblock screen to use these rules in Safari.", blocked: nil), dns: dns)
        }
        if let exception { return WebsiteCheck(host: normal, safari: .init(title: "Allowed", detail: "You turned blocking off for \(exception.domain).", blocked: false), dns: dns) }
        let sources = configuration.subscriptions.filter(\.enabled).map { SafariRulesetPlanner.Source(url: $0.url, rules: $0.rules, content: $0.content ?? ContentRuleSet()) }
        let userRules = configuration.rules.filter { $0.enabled != false }
        let kept = await Task.detached(priority: .userInitiated) { SafariRulesetPlanner.balance(SafariRulesetPlanner.plan(sources: sources, userRules: userRules)) }.value
        var holder: SafariExtensionID?
        for (id, rules) in kept where rules.contains(where: { $0.action == .block && (normal == $0.domain || ($0.scope == .domainAndSubdomains && normal.hasSuffix("." + $0.domain))) }) { holder = id; break }
        let lists = await compiledRuleListsForTest()
        var live = "unknown"
        if !lists.isEmpty {
            let with = await fetchStates([normal], lists: lists)[normal] ?? "timeout", without = await fetchStates([normal], lists: [])[normal] ?? "timeout"
            live = with == "blocked" && without == "allowed" ? "blocked" : with == "allowed" ? "allowed" : "unreachable"
            await removeTestRuleLists()
        }
        var safari: WebsiteCheck.Verdict
        if let holder, let rule = match?.rule {
            safari = .init(title: "Blocked", detail: "\(rule.domain) from \(listName(forSource: rule.source)) is in the \(holder.title) extension.", blocked: true)
            if live == "allowed" { safari = .init(title: "Not blocked", detail: "The rule is in the \(holder.title) extension, but the site still loaded in the live check. Safari may not have loaded that extension yet.", blocked: false) }
        } else if let rule = match?.rule, rule.action == .block {
            safari = .init(title: "Not blocked in Safari", detail: "\(rule.domain) is on \(listName(forSource: rule.source)), but Safari’s limit left it out. DNS filtering still blocks it.", blocked: false)
        } else if live == "blocked" {
            safari = .init(title: "Blocked", detail: "A page rule blocks this site in Safari.", blocked: true)
        } else {
            safari = .init(title: "Not blocked", detail: "No Safari rule matches \(normal)." , blocked: false)
        }
        if live == "unreachable" { safari.detail += " The live check could not reach the site, so only the rules were compared." }
        return WebsiteCheck(host: normal, safari: safari, dns: dns)
    }
    /// Asks one extension to load the rules it already has, and records Safari's answer. Used by the Safari Details screen.
    func reloadExtension(_ id: SafariExtensionID) async {
        await exclusive { [self] in
            do { try await reloadSafari(id); extensionStates[id, default: SafariExtensionState()].reloaded = true; extensionStates[id]?.failure = nil; message = "\(id.title): Safari loaded the rules." }
            catch { let reason = Self.safariFailure(error); extensionStates[id, default: SafariExtensionState()].failure = reason; extensionStates[id]?.reloaded = false; message = "\(id.title): \(reason)" }
            recomputeAggregates()
        }
    }
    func updateSelectedLists() async {
        let ids = configuration.subscriptions.filter { $0.enabled && $0.url != "Local file" }.map(\.id)
        for id in ids { guard !Task.isCancelled else { return }; await updateList(id) }
    }
    func setupBasicProtection() async {
        await exclusive { [self] in
        guard !busy else { return }
        guard let starter = configuration.subscriptions.first(where: { $0.url == "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/light.txt" }) else { message = "Add HaGeZi Light from Filter Lists to use basic setup."; return }
        await setList(starter.id, enabled: true)
        guard configuration.subscriptions.first(where: { $0.id == starter.id })?.enabled == true else { return }
        await setSafari(true)
        }
    }
    /// Lets views surface a problem that happened outside a controller operation (for example a file the user picked).
    func report(_ text: String) { message = text }
    /// Called after the published rules change so a running local DNS tunnel reloads them.
    var onDNSRulesPublished: (() -> Void)?
    /// Compiles enabled lists and user rules into the snapshot the DNS tunnel reads. Independent of Safari state.
    /// The compiled DNS filter, built from what is switched on. Also used to tell, in the adblock test, which names DNS filtering blocks.
    func dnsRuleSnapshot() -> DNSRuleSnapshot {
        var snapshot = DNSRuleSnapshot()
        // Rules from security lists are also tagged so the counters can separate threats from ads and trackers.
        let securityLists = Set(configuration.subscriptions.filter { FilterCatalog.entry(forURL: $0.url)?.category == .malwarePhishing }.map { $0.id.uuidString })
        for rule in configuration.effective where rule.enabled != false {
            let value = DNSRuleSnapshot.hash(rule.domain)
            if rule.action == .block, securityLists.contains(rule.source) {
                if rule.scope == .exact { snapshot.threatExact.insert(value) } else { snapshot.threatSuffix.insert(value) }
            }
            switch (rule.action, rule.scope) {
            case (.block, .domainAndSubdomains): snapshot.blockSuffix.insert(value)
            case (.block, .exact): snapshot.blockExact.insert(value)
            case (.allow, .domainAndSubdomains): snapshot.allowSuffix.insert(value)
            case (.allow, .exact): snapshot.allowExact.insert(value)
            }
        }
        return snapshot
    }
    /// Background publishes (list toggles, updates) have no caller to throw to; a failure must still be visible, not silent.
    func publishDNSRulesReportingFailure() {
        do { try publishDNSRules() }
        catch { record("DNS filter rules could not be published; the running DNS tunnel keeps its previous rules"); message = "DNS filter rules could not be updated. Try Update Filter Lists again." }
    }
    @discardableResult func publishDNSRules() throws -> Int {
        let snapshot = dnsRuleSnapshot()
        guard snapshot.count <= DNSRuleSnapshot.maximumRules else { throw FilteringIssue.capacity }
        try DNSRuleStore.write(snapshot)
        onDNSRulesPublished?()
        return snapshot.count
    }
    /// VayuSetu DNS must filter out of the box: enable the starter list when nothing is enabled yet.
    /// Fresh installs: download and switch on the preinstalled lists once. A failed list stays off and can be retried from its row.
    func enableDefaultListsOnFirstRun() async {
        guard writable, configuration.defaultsEnabled == false else { return }
        for entry in FilterCatalog.defaults {
            guard let list = configuration.subscriptions.first(where: { $0.url == entry.url }) else { continue }
            await setList(list.id, enabled: true)
        }
        var draft = configuration; draft.defaultsEnabled = true
        try? persist(draft); configuration = draft
    }
    func ensureStarterListForDNS() async {
        guard configuration.effective.isEmpty,
              let starter = configuration.subscriptions.first(where: { $0.url == VayuSetuDNS.starterListURL }) else { return }
        await setList(starter.id, enabled: true)
    }
    func removeRule(_ id: String) async { await exclusive { [self] in var draft = configuration; draft.rules.removeAll { $0.id == id }; do { try await commit(draft) } catch { message = error.localizedDescription } } }
    func setResourceBlock(_ kind: SafariRuleCompiler.ResourceBlock, _ on: Bool) async {
        await exclusive { [self] in
        var draft = configuration; var list = Set(draft.resourceBlocks ?? [])
        if on { list.insert(kind.rawValue) } else { list.remove(kind.rawValue) }
        draft.resourceBlocks = list.sorted()
        do { try await commit(draft) } catch { message = error.localizedDescription }
        }
    }
    func setSafari(_ desired: Bool) async { await exclusive { [self] in var draft = configuration; draft.safariDesired = desired; do { try await commit(draft) } catch { message = error.localizedDescription } } }
    func reload() async { await exclusive { [self] in do { try await commit(configuration) } catch { message = error.localizedDescription } } }
    /// Every change to the filter settings runs one at a time, in the order it was made. Two changes overlapping (for example a quick
    /// switch from one preset to another) used to start from the same old settings and undo each other. A change started from inside a
    /// running change (a preset downloading its lists) joins that one instead of waiting for it.
    @TaskLocal private static var inOperation = false
    private var operationRunning = false
    private func exclusive(_ body: @MainActor () async -> Void) async {
        if Self.inOperation { await body(); return }
        var waited = 0
        while operationRunning && waited < 6000 { try? await Task.sleep(for: .milliseconds(100)); waited += 1 }
        operationRunning = true; defer { operationRunning = false }
        await Self.$inOperation.withValue(true) { await body() }
    }
    /// A change made while another is still being applied waits its turn instead of being dropped.
    func waitUntilIdle() async { var n = 0; while busy && n < 900 { try? await Task.sleep(for: .milliseconds(200)); n += 1 } }
    func setList(_ id: UUID, enabled: Bool) async {
        await exclusive { [self] in
        await waitUntilIdle()
        guard let index = configuration.subscriptions.firstIndex(where: { $0.id == id }) else { return }
        if enabled && configuration.subscriptions[index].rules.isEmpty { await updateList(id, enable: true); return }
        var draft = configuration; draft.subscriptions[index].enabled = enabled
        do { try await commit(draft) } catch { message = error.localizedDescription }
        }
    }
    func removeList(_ id: UUID) async {
        await exclusive { [self] in
        await waitUntilIdle()
        var draft = configuration
        if let url = draft.subscriptions.first(where: { $0.id == id })?.url, FilterCatalog.entry(forURL: url) != nil {
            var removed = draft.removedCatalog ?? []
            if !removed.contains(url) { removed.append(url) }
            draft.removedCatalog = removed
        }
        draft.subscriptions.removeAll { $0.id == id }
        do { try await commit(draft) } catch { message = error.localizedDescription }
        }
    }
    /// Adds a catalogue list (and optionally enables it, which downloads it). Re-adding clears an earlier removal.
    func addCatalogList(_ entry: CatalogList, enable: Bool) async {
        await exclusive { [self] in
        await waitUntilIdle()
        var draft = configuration
        draft.removedCatalog = (draft.removedCatalog ?? []).filter { $0 != entry.url }
        var id = draft.subscriptions.first(where: { $0.url == entry.url })?.id
        if id == nil {
            let subscription = FilterSubscription(name: entry.name, url: entry.url)
            draft.subscriptions.append(subscription); id = subscription.id
        }
        do { try persist(draft); configuration = draft } catch { message = "Could not save the list."; return }
        record("Catalogue list added; no download started")
        if enable, let id { await setList(id, enabled: true) }
        }
    }
    func importRules(_ data: Data) async {
        do {
            guard data.count <= FilterParser.byteLimit else { throw FilteringIssue.tooLarge }
            let raw = try JSONDecoder().decode([FilterRule].self, from: data)
            let sanitized = try raw.map { try FilterRule(domain: $0.domain, action: $0.action, scope: $0.scope, enabled: $0.enabled != false) }
            var draft = configuration; draft.rules.append(contentsOf: sanitized); try await commit(draft)
        } catch { message = "Rule import failed. Validate its JSON, domain scopes and ruleset size. Previous rules preserved." }
    }
    func restoreFilterMetadata(_ backup: ConfigurationBackup) async throws {
        var draft = configuration
        for item in backup.rules ?? [] {
            guard let action = FilterAction(rawValue: item.action), let scope = FilterScope(rawValue: item.scope) else { throw FilteringIssue.invalidDomain }
            let rule = try FilterRule(domain: item.domain, action: action, scope: scope, enabled: item.enabled)
            if !draft.rules.contains(where: { $0.domain == rule.domain && $0.action == rule.action && $0.scope == rule.scope }) { draft.rules.append(rule) }
        }
        for item in backup.lists ?? [] {
            guard let url = item.url else { continue } // Source-free names are shown in the restore summary; never guess a private endpoint.
            if !draft.subscriptions.contains(where: { $0.url == url }) { draft.subscriptions.append(FilterSubscription(name: item.name, url: url)) }
        }
        // Restored lists are unchecked and have no downloaded cache. Existing selection is preserved.
        if !(backup.rules ?? []).isEmpty || !(backup.lists ?? []).isEmpty { try await commit(draft) }
    }
    var exportedRules: Data { (try? JSONEncoder().encode(configuration.rules)) ?? Data("[]".utf8) }
    func addSubscription(name: String, url: String) {
        guard !busy, writable, name.count <= 80, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let parsed = URL(string: url), HTTPSListDelegate.valid(parsed) else { message = "Use a name and a valid HTTPS list URL without login credentials."; return }
        do {
            var draft = configuration; draft.subscriptions.append(FilterSubscription(name: name, url: url))
            try persist(draft); configuration = draft; record("Custom subscription added; no download started")
        } catch { message = "Could not save the subscription." }
    }
    func importList(_ data: Data, name: String) async {
        await exclusive { [self] in
        guard !busy else { return }
        do {
            let id = UUID(); let parsed = try await Task.detached(priority: .utility) { try FilterParser.parse(data, source: id.uuidString) }.value
            var draft = configuration
            var list = FilterSubscription(id: id, name: String(name.prefix(80)), url: "Local file", enabled: true)
            list.rules = parsed.rules; list.updated = Date(); list.rejected = parsed.rejected; list.checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            draft.subscriptions.append(list); try await commit(draft)
        } catch { message = error.localizedDescription }
        }
    }
    /// Downloads and parses one list and returns the subscription with its new rules. Nothing is saved; the caller decides when to commit.
    private func fetchSubscription(_ id: UUID) async throws -> FilterSubscription {
        guard let index = configuration.subscriptions.firstIndex(where: { $0.id == id }), let url = URL(string: configuration.subscriptions[index].url), HTTPSListDelegate.valid(url) else { throw AppIssue(message: "This list has no valid https address.") }
        let old = configuration.subscriptions[index]
        let settings = URLSessionConfiguration.ephemeral; settings.timeoutIntervalForRequest = 30; settings.timeoutIntervalForResource = 120
        let session = URLSession(configuration: settings, delegate: HTTPSListDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.setValue("text/plain", forHTTPHeaderField: "Accept")
        if let etag = old.etag, !old.rules.isEmpty || old.content != nil { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (fileURL, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        guard let http = response as? HTTPURLResponse, let final = http.url, HTTPSListDelegate.valid(final) else { throw AppIssue(message: "List download did not return a valid HTTPS response.") }
        var sub = old
        if http.statusCode == 304, !old.rules.isEmpty || old.content != nil { sub.updated = Date(); return sub }
        guard http.statusCode == 200 else { throw AppIssue(message: "Filter-list server returned HTTP \(http.statusCode).") }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard data.count <= FilterParser.byteLimit else { throw FilteringIssue.tooLarge }
        let (parsed, content) = try await Task.detached(priority: .utility) { () throws -> (FilterParseResult, ContentRuleSet) in
            let content = ABPContentParser.parse(data)
            do { return (try FilterParser.parse(data, source: id.uuidString), content) }
            catch FilteringIssue.empty where !content.isEmpty { return (FilterParseResult(rules: [], rejected: 0), content) }   // a list of only page rules
        }.value
        sub.rules = parsed.rules; sub.rejected = parsed.rejected; sub.content = content.isEmpty ? nil : content
        sub.updated = Date(); sub.etag = http.value(forHTTPHeaderField: "ETag")
        sub.checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return sub
    }
    private func failureText(_ error: Error) -> String {
        if let issue = error as? FilteringIssue { return issue.localizedDescription }
        if let issue = error as? AppIssue { return issue.message }
        if let url = error as? URLError { return "Network error (\(url.code.rawValue)): \(url.localizedDescription)" }
        return "Could not read the list (\((error as NSError).domain) \((error as NSError).code))."
    }
    func updateList(_ id: UUID, enable: Bool? = nil) async {
        await exclusive { [self] in
            await waitUntilIdle()
            guard let name = configuration.subscriptions.first(where: { $0.id == id })?.name else { return }
            busy = true; activeListID = id
            defer { busy = false; activeListID = nil }
            do {
                var sub = try await fetchSubscription(id)
                if let enable { sub.enabled = enable }
                guard let index = configuration.subscriptions.firstIndex(where: { $0.id == id }) else { return }
                var draft = configuration; draft.subscriptions[index] = sub
                busy = false; try await commit(draft)
            } catch {
                let reason = failureText(error)
                message = "\(name): \(reason) Previous rules preserved."
                record("Filter-list update failed: \(name): \(reason)")
            }
        }
    }
    private func commit(_ draft: FilterConfiguration) async throws {
        guard writable, !busy else { throw AppIssue(message: "Filtering is busy or its storage needs recovery.") }
        busy = true; defer { busy = false }
        let unique = draft.uniqueEffectiveCount
        guard unique <= FilterParser.combinedLimit else { throw FilteringIssue.capacity }
        var next = draft; next.generation = UUID(); next.uniqueRules = unique; next.compilerVersion = FilterConfiguration.currentCompilerVersion
        let rules = next.safariDesired ? next.effective : []
        // Split the rules between the six extensions and compile each slice within its own budget; DNS keeps everything.
        let sources = next.safariDesired ? next.subscriptions.filter(\.enabled).map { SafariRulesetPlanner.Source(url: $0.url, rules: $0.rules, content: $0.content ?? ContentRuleSet()) } : []
        let userRules = next.safariDesired ? next.rules.filter { $0.enabled != false } : []
        let blocks = next.safariDesired ? (next.resourceBlocks ?? []).compactMap(SafariRuleCompiler.ResourceBlock.init(rawValue:)) : []
        let siteExceptions = next.safariDesired ? next.rules.filter { $0.action == .allow && $0.source == FilteringController.siteExceptionSource && $0.enabled != false }.map(\.domain) : []
        var compiled: [SafariExtensionID: SafariRulesetPlanner.Compiled] = [:]
        do {
            compiled = try await Task.detached(priority: .utility) { try SafariRulesetPlanner.compileAll(SafariRulesetPlanner.plan(sources: sources, userRules: userRules), resourceBlocks: blocks, content: SafariRulesetPlanner.planContent(sources: sources, siteExceptions: siteExceptions)) }.value
            next.safariApplied = compiled.values.reduce(0) { $0 + $1.applied }; next.safariCandidates = rules.count + blocks.count + sources.reduce(0) { $0 + $1.content.count }
            next.safariExtensionRules = Dictionary(uniqueKeysWithValues: compiled.map { ($0.key.rawValue, $0.value.applied) })
        }
        catch FilteringIssue.capacity {
            try persist(next)
            configuration = next
            publishDNSRulesReportingFailure()
            message = "Saved. Safari could not fit these rules, so it keeps its previous rules. DNS filtering uses all selected lists."
            record("Filter configuration saved; Safari rules unchanged (budget)")
            return
        }
        // Ask WebKit to compile every non-empty slice first. A rejected rule fails the update and leaves the previous rules alone.
        var rejection: String?
        for id in SafariExtensionID.allCases where (compiled[id]?.applied ?? 0) > 0 {
            do { try await validateWithWebKit(id, compiled[id]!.data) } catch { rejection = error.localizedDescription; break }
        }
        if let rejection {
            // The selection still counts: save it, keep DNS filtering in step, and leave Safari on its previous rules.
            next.pendingApply = false
            try persist(next); configuration = next
            publishDNSRulesReportingFailure()
            message = "Saved. DNS filtering uses your selection. Safari kept its previous rules because \(rejection)"
            record("Filter configuration saved; Safari rules unchanged (\(rejection))")
            return
        }
        // Editing configuration must work before any extension is enabled. Stage the compiled slices in the App Group so
        // Safari picks them up when an extension is switched on; nothing is reloaded or claimed applied yet.
        let anyEnabled = extensionStates.values.contains { $0.enabled == true }
        if !anyEnabled && !packageReady {
            next.pendingApply = next.safariDesired; next.latestReload = nil
            try persist(next)
            configuration = next; lastReload = nil
            if let directory = packageDirectory { for (id, item) in compiled { try? item.data.write(to: directory.appendingPathComponent(id.fileName), options: .atomic) } }
            publishDNSRulesReportingFailure()
            message = next.safariDesired ? "Rules saved, not applied to Safari. Enable the VayuSetu extensions in \(Self.safariExtensionsPath), then return here. DNS filtering already uses them." : "Lists saved. VayuSetu DNS uses them on this device."
            record("Filter configuration saved; Safari application pending")
            recomputeAggregates()
            return
        }
        // Missing group is a signing error, not permission to replace the current config.
        guard let directory = packageDirectory else { throw AppIssue(message: "App Group access is unavailable. Rebuild with the Safari extensions’ provisioning before applying filters.") }
        let placeholder = try SafariRuleCompiler.compile([])
        var previous: [SafariExtensionID: Data] = [:]; var changed: [SafariExtensionID] = []
        for id in SafariExtensionID.allCases {
            let old = try? Data(contentsOf: directory.appendingPathComponent(id.fileName))
            previous[id] = old
            if old != compiled[id]?.data { changed.append(id) }
        }
        let journalURL = directory.appendingPathComponent("safari-update-journal.json")
        try JSONEncoder().encode(SafariUpdateJournal(previous: Dictionary(uniqueKeysWithValues: changed.map { ($0.rawValue, previous[$0] ?? placeholder) }), pendingGeneration: next.generation!)).write(to: journalURL, options: .atomic)
        // Each extension is its own transaction: write, reload, and restore that one extension if its reload fails.
        var failures: [SafariExtensionID: String] = [:]; var reloadedNow = 0; var waiting: [SafariExtensionID] = []
        for id in changed {
            let url = directory.appendingPathComponent(id.fileName)
            do {
                try compiled[id]!.data.write(to: url, options: .atomic)
                if extensionStates[id]?.enabled == false { waiting.append(id); extensionStates[id]?.reloaded = false; continue }   // Safari loads it when the user enables it
                guard (compiled[id]?.applied ?? 0) > 0 || previous[id] != nil else { extensionStates[id]?.reloaded = true; continue }       // untouched empty slice
                // Only an extension known to be on gets the long wait; if Safari's state is unknown, do not leave the switch spinning.
                let confirmedOn = extensionStates[id]?.enabled == true
                try await reloadSafari(id, timeout: confirmedOn ? 45 : 8); extensionStates[id]?.reloaded = true; extensionStates[id]?.failure = nil; reloadedNow += 1
            } catch {
                let reason = Self.safariFailure(error); failures[id] = reason; failureDetails = reason
                try? (previous[id] ?? placeholder).write(to: url, options: .atomic)
                if (try? await reloadSafari(id, timeout: 8)) == nil { record("Rollback of \(id.title) could not be confirmed") }
                extensionStates[id]?.failure = reason
            }
        }
        try? FileManager.default.removeItem(at: journalURL)
        if !failures.isEmpty && reloadedNow == 0 && waiting.isEmpty {
            recomputeAggregates()
            record("Filter update failed; previous rules restored")
            // Safari would not take the rules, but the selection is still the user's: save it so DNS filtering follows it.
            next.pendingApply = true
            try persist(next); configuration = next
            publishDNSRulesReportingFailure()
            message = "Saved. DNS filtering uses your selection, but Safari did not take the new rules and kept its previous ones. \(failureDetails)"
            return
        }
        next.latestReload = Date(); next.pendingApply = !failures.isEmpty || !waiting.isEmpty
        try persist(next)
        configuration = next; lastReload = next.latestReload
        publishDNSRulesReportingFailure()
        recomputeAggregates()
        if !failures.isEmpty || !waiting.isEmpty {
            let failed = failures.keys.sorted { $0.rawValue < $1.rawValue }.map(\.title) + waiting.map { $0.title + " (off in Settings)" }
            message = "Partially applied. Not applied: " + failed.joined(separator: ", ") + ". The others are active."
            record("Safari rules partially applied · \(rules.count) selected")
        } else {
            failureDetails = ""
            if let applied = next.safariApplied, let total = next.safariCandidates, applied < total {
                message = "Safari is using \(applied) of \(total) selected rules (its limit per extension). DNS filtering uses all of them."
            } else { message = "Rules reloaded. Safari’s enabled state and individual rule effectiveness are separate observations." }
            record("Safari rules reloaded · \(next.safariApplied ?? 0) compiled across \(neededExtensions.count) extension\(neededExtensions.count == 1 ? "" : "s")")
        }
        await refresh()
    }
    /// Controlled self-test on the Custom extension: append one reserved .invalid rule, reload, restore the exact previous file, reload again.
    func validateSafariCompiler() async -> String {
        guard !busy, writable, let url = fileURL(.custom), let directory = packageDirectory else { return "Compiler check unavailable: shared container or storage is unavailable." }
        busy = true; defer { busy = false }
        let previous = (try? Data(contentsOf: url)) ?? (try? SafariRuleCompiler.compile([])) ?? Data("[]".utf8)
        let journalURL = directory.appendingPathComponent("safari-update-journal.json")
        do {
            guard var current = try JSONSerialization.jsonObject(with: previous) as? [[String: Any]], current.count < SafariRuleCompiler.ruleLimit else { throw FilteringIssue.capacity }
            let probe = try FilterRule(domain: UUID().uuidString.lowercased() + ".invalid", action: .block, scope: .exact)
            let row = try JSONSerialization.jsonObject(with: SafariRuleCompiler.compile([probe])) as! [[String: Any]]
            current.append(contentsOf: row)
            try JSONEncoder().encode(SafariUpdateJournal(previous: [SafariExtensionID.custom.rawValue: previous], pendingGeneration: UUID())).write(to: journalURL, options: .atomic)
            try JSONSerialization.data(withJSONObject: current).write(to: url, options: .atomic)
            try await reloadSafari(.custom)
            try previous.write(to: url, options: .atomic); try await reloadSafari(.custom)
            try FileManager.default.removeItem(at: journalURL)
            extensionStates[.custom, default: SafariExtensionState()].reloaded = true; recomputeAggregates(); lastReload = Date(); record("Controlled Safari compilation and rollback passed")
            return "Controlled Safari rule compiled and the exact previous package reloaded. OS enablement and individual blocking effectiveness are separate observations."
        } catch {
            do { try previous.write(to: url, options: .atomic); try await reloadSafari(.custom); try? FileManager.default.removeItem(at: journalURL) } catch {}
            failureDetails = Self.safariFailure(error)
            return "Controlled Safari compiler check failed. " + failureDetails
        }
    }
    static func safariFailure(_ error: Error) -> String {
        let value = error as NSError
        if value.domain == SFErrorDomain {
            let explanation: String
            switch value.code {
            case 1: explanation = "Safari cannot find the installed content-blocker extension."
            case 2: explanation = "The extension returned no usable rules attachment."
            case 3: explanation = "Safari rule loading was interrupted."
            case 4: explanation = "Safari reported an internal loading failure."
            case 5: explanation = "Safari rejected an entitlement or permission."
            case 6: explanation = "Safari's reload attempt limit was reached."
            default: explanation = "Safari returned an unrecognized error."
            }
            return explanation + " (Safari code \(value.code))"
        }
        let knownDomain = ["WebKitErrorDomain", "WKErrorDomain", "NSCocoaErrorDomain", "NSExtensionErrorDomain"].contains(value.domain) ? value.domain : "operation"
        let description = value.localizedDescription.lowercased()
        let reason = description.contains("empty") ? " Empty rule list rejected." : description.contains("regular expression") ? " URL-filter regular expression rejected." : description.contains("json") ? " Rules JSON rejected." : ""
        return reason + " Rule operation failed (\(knownDomain) code \(value.code))."
    }
    /// Safari answers when it has compiled the rules, which can take a while for large sets. Never wait forever: after 45 s report it,
    /// so the switch stops spinning and the user sees a reason.
    static var safariExtensionsPath: String {
        #if os(macOS)
        "Safari → Settings → Extensions"
        #else
        "Settings → Apps → Safari → Extensions"
        #endif
    }
    func reloadSafari(_ id: SafariExtensionID, timeout: Double = 45) async throws {
        final class Once: @unchecked Sendable { let lock = NSLock(); var done = false; func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true } }
        let once = Once(); let identifier = identifier(for: id)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            SFContentBlockerManager.reloadContentBlocker(withIdentifier: identifier) { error in
                guard once.claim() else { return }
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: ()) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard once.claim() else { return }
                continuation.resume(throwing: AppIssue(message: timeout < 45 ? "Safari did not answer. The VayuSetu extension is probably switched off in Safari." : "Safari did not finish loading the rules in 45 seconds. Try again, or turn off a large list."))
            }
        }
        // Remember which exact package Safari acknowledged, so a relaunch can tell it is still loaded.
        if let signature = packageSignature(id) { UserDefaults.standard.set(signature, forKey: "safari.ack." + id.rawValue) }
    }
    /// Identifies the published rules file by size and modification time; a rebuild changes it, which invalidates the acknowledgement.
    private func packageSignature(_ id: SafariExtensionID) -> String? {
        guard let path = fileURL(id)?.path, let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber, let modified = attributes[.modificationDate] as? Date else { return nil }
        return "\(size.intValue):\(Int(modified.timeIntervalSince1970))"
    }
    func record(_ message: String) { do { try database?.event(message); events = database?.events() ?? []; recentEvents = database?.recentEvents() ?? [] } catch { self.message = "Privacy event storage unavailable." } }
    func clearEvents() { do { try database?.clearEvents(); events = []; recentEvents = [] } catch { message = "Could not clear privacy events." } }
}

@MainActor final class SystemDNSController: ObservableObject {
    @Published private(set) var desiredEnabled: Bool?
    private var database: PrivacyDatabase?
    private var operationError: Date?
    init() { database = try? PrivacyDatabase(); desiredEnabled = database?.dnsIntent() }
    @Published private(set) var enabled: Bool?
    @Published private(set) var observedAt: Date?
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    private let manager = NEDNSSettingsManager.shared()
    private var managed = false
    @Published private(set) var hasForeignConfiguration = false
    private var refreshTask: Task<Void, Never>?
    func refresh() async {
        // Readers share one load, and never reload the singleton manager while a
        // writer has staged settings that have not yet been saved.
        if busy { return }
        if let refreshTask { await refreshTask.value; return }
        let task = Task { await reloadObservation() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }
    private func reloadObservation() async {
        do { try await manager.loadFromPreferences(); managed = manager.localizedDescription == "VayuSetu encrypted DNS"; enabled = managed && manager.isEnabled; hasForeignConfiguration = manager.dnsSettings != nil && !managed; observedAt = Date() }
        catch { enabled = nil; observedAt = nil; message = "DNS settings unavailable. Check the signed build’s DNS-settings entitlement." }
    }
    var hasSavedConfiguration: Bool { managed && observedAt != nil && manager.dnsSettings != nil }
    /// Configuration identity only; matching OS settings do not prove query transport or filtering.
    func configuredResolverMatches(_ endpoint: String) -> Bool {
        guard managed, observedAt != nil else { return false }
        return DNSConfigurationIdentity.matches(endpoint: endpoint, httpsURL: (manager.dnsSettings as? NEDNSOverHTTPSSettings)?.serverURL, tlsServerName: (manager.dnsSettings as? NEDNSOverTLSSettings)?.serverName)
    }
    @discardableResult func enable(endpoint: String, bootstrap: [String]) async -> Bool {
        if let refreshTask { await refreshTask.value }
        guard !busy else { return false }; busy = true; defer { busy = false }
        do {
            guard let database else { throw AppIssue(message: "Privacy configuration storage is unavailable.") }
            operationError = nil
            let url = try DNSService.endpoint(endpoint)
            guard let host = url.host else { throw AppIssue(message: "Resolver hostname is missing.") }
            let servers = bootstrap.isEmpty ? [] : try ResolverBootstrap.validated(bootstrap)
            try await manager.loadFromPreferences()
            guard manager.dnsSettings == nil || manager.localizedDescription == "VayuSetu encrypted DNS" else { throw AppIssue(message: "Another DNS configuration is present. Resolve the conflict in system settings before applying VayuSetu DNS.") }
            let settings: NEDNSSettings
            if url.scheme == "tls" { let tls = NEDNSOverTLSSettings(servers: servers); tls.serverName = host; settings = tls }
            else { let https = NEDNSOverHTTPSSettings(servers: servers); https.serverURL = url; settings = https }
            settings.matchDomains = [""]
            manager.dnsSettings = settings; manager.localizedDescription = "VayuSetu encrypted DNS"
            let rule = NEOnDemandRuleConnect(); rule.interfaceTypeMatch = .any; manager.onDemandRules = [rule]
            try await manager.saveToPreferences()
            try database.setDNSIntent(true); desiredEnabled = true
            await reloadObservation()
            guard enabled != nil, configuredResolverMatches(endpoint), Set(manager.dnsSettings?.servers ?? []) == Set(servers) else { throw AppIssue(message: "DNS configuration saved, but exact resolver readback could not be confirmed. Refresh before relying on it.") }
            try Vault.delete(suspensionAccount)
            message = enabled == true ? "Encrypted DNS is enabled in iOS. DNS traffic and filtering remain unverified." : "Configuration saved; activation required. In Settings → General → VPN & Device Management → DNS, select VayuSetu encrypted DNS, then return here."
            return true
        } catch { operationError = Date(); message = (error as? AppIssue)?.localizedDescription ?? "Encrypted DNS configuration failed. Check permission and provisioning. No fallback was enabled."; return false }
    }
    private let suspensionAccount = "independent-dns-suspended-v1"
    var hasSuspendedConfiguration: Bool { (try? Vault.get(suspensionAccount)) != nil }
    @discardableResult func restoreSuspendedConfiguration() async -> Bool {
        guard desiredEnabled == true, !busy, !hasSavedConfiguration, !hasForeignConfiguration, enabled != nil else { return false }
        do {
            guard let data = try Vault.get(suspensionAccount) else { return false }
            let saved = try JSONDecoder().decode(SuspendedDNSConfiguration.self, from: data)
            guard saved.version == 1 else { throw AppIssue(message: "Unsupported suspended DNS configuration.") }
            // Restore the exact suspended resolver, never a subsequently selected preference.
            guard await enable(endpoint: saved.endpoint, bootstrap: saved.bootstrap) else { return false }
            try Vault.delete(suspensionAccount)
            message = enabled == true ? "Independent encrypted DNS restored; traffic remains unverified." : "Independent DNS configuration restored. Finish activation in system Settings; DNS is not confirmed active."
            return true
        } catch { operationError = Date(); message = "Independent DNS recovery needs attention. Review DNS configuration; no fallback was enabled."; return false }
    }
    @discardableResult func disable(preservingPreference: Bool = false) async -> Bool {
        if let refreshTask { await refreshTask.value }
        for _ in 0..<50 { if !busy { break }; try? await Task.sleep(for: .milliseconds(100)) }
        guard !busy else { message = "DNS operation is still completing. Disable VayuSetu manually in system DNS settings."; return false }; busy = true; defer { busy = false }
        do {
            guard let database else { throw AppIssue(message: "Privacy configuration storage is unavailable.") }
            operationError = nil
            try await manager.loadFromPreferences()
            if preservingPreference && desiredEnabled == true && manager.localizedDescription == "VayuSetu encrypted DNS", let settings = manager.dnsSettings {
                let originalEndpoint: String
                if let https = settings as? NEDNSOverHTTPSSettings, let url = https.serverURL { originalEndpoint = url.absoluteString }
                else if let tls = settings as? NEDNSOverTLSSettings, let host = tls.serverName { originalEndpoint = "tls://" + host }
                else { throw AppIssue(message: "Existing DNS configuration cannot be safely suspended.") }
                _ = try DNSService.endpoint(originalEndpoint)
                let snapshot = SuspendedDNSConfiguration(version: 1, endpoint: originalEndpoint, bootstrap: settings.servers)
                // Persist before removal so interrupted transitions remain recoverable.
                try Vault.put(JSONEncoder().encode(snapshot), account: suspensionAccount)
            }
            if manager.localizedDescription == "VayuSetu encrypted DNS" { try await manager.removeFromPreferences() }
            if !preservingPreference {
                try database.setDNSIntent(false); desiredEnabled = false
                try Vault.delete(suspensionAccount)
            }
            await reloadObservation()
            guard enabled == false, !hasForeignConfiguration else { throw AppIssue(message: "VayuSetu DNS was removed, but the resulting system DNS state could not be confirmed.") }
            message = preservingPreference ? "Independent DNS suspended for the VPN. Its saved preference is preserved." : "VayuSetu DNS configuration removed. iOS supplies DNS; encryption and filtering are unverified."
            return true
        } catch { operationError = Date(); message = "Could not confirm removal of VayuSetu DNS. Review system network/DNS settings."; return false }
    }
    func snapshot(now: Date = .now) -> ProtectionSnapshot {
        if busy {
            return ProtectionSnapshot(.dns, desired: desiredEnabled, state: .starting, source: .userPreference, reason: "Applying DNS settings. Wait for the resulting system observation.")
        }
        let state: ObservedState = operationError != nil ? .error : desiredEnabled == true && enabled == false || desiredEnabled == false && enabled == true ? .needsAttention : enabled == true ? .enabledNotVerified : enabled == false ? .inactive : .unknown
        return PrivacyIntegrityEngine.reconcile(ProtectionSnapshot(.dns, desired: desiredEnabled, state: state, source: .osStatus, at: operationError ?? observedAt, reason: operationError != nil ? "The requested DNS operation failed. Review system DNS settings." : enabled == true ? "OS reports encrypted DNS enabled. Actual query path has not been independently measured." : "No observed VayuSetu OS encrypted DNS configuration."), now: now)
    }
}

@MainActor final class ASNController: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var result = ""
    private static var cache: [String: (Date, String)] = [:]
    private var request: Task<Void, Never>?
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    private var requestID = UUID()
    func cancel() { requestID = UUID(); request?.cancel(); request = nil; busy = false; result = "" }
    func lookup(_ value: String) {
        guard !busy, let address = PublicIPProbe.canonical(value, family: .ipv4) ?? PublicIPProbe.canonical(value, family: .ipv6) else { result = "Measure a valid public IP first."; return }
        if let cached = Self.cache[address], Date().timeIntervalSince(cached.0) < 3600 { result = cached.1 + "\nCached " + cached.0.formatted(); return }
        busy = true; let id = UUID(); requestID = id
        request = Task {
            defer { if requestID == id { busy = false; request = nil } }
            let settings = URLSessionConfiguration.ephemeral; settings.timeoutIntervalForRequest = 10; settings.timeoutIntervalForResource = 15
            let session = URLSession(configuration: settings, delegate: NoRedirect(), delegateQueue: nil); defer { session.invalidateAndCancel() }
            do {
                var components = URLComponents(string: "https://stat.ripe.net/data/network-info/data.json")!
                components.queryItems = [URLQueryItem(name: "resource", value: address)]
                let (bytes, response) = try await session.bytes(from: components.url!)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw AppIssue(message: "ASN lookup returned an unsuccessful HTTP response.") }
                var data = Data(); for try await byte in bytes { data.append(byte); guard data.count <= 64_000 else { throw AppIssue(message: "ASN response exceeds its size limit.") }; try Task.checkCancellation() }
                let output = try ASNResponse.parse(data)
                try Task.checkCancellation()
                guard requestID == id else { return }
                result = output + "\nMeasured " + Date().formatted() + "\nBGP announcement metadata from RIPE RIS; does not verify VPN ownership or leak protection."
                if Self.cache.count >= 16 { Self.cache.removeAll() }; Self.cache[address] = (Date(), result)
            } catch {
                guard !Task.isCancelled, requestID == id else { return }
                result = "ASN lookup failed. " + (IPFailure.classify(error).errorDescription ?? "Response unavailable.")
            }
        }
    }
}
enum ASNResponse {
    static func parse(_ data: Data) throws -> String {
        guard data.count <= 64_000, let root = try JSONSerialization.jsonObject(with: data) as? [String:Any], root["status"] as? String == "ok",
              let payload = root["data"] as? [String:Any], let prefix = payload["prefix"] as? String, prefix.count <= 64,
              let raw = payload["asns"] as? [Any], raw.count <= 64 else { throw AppIssue(message: "Malformed ASN response.") }
        let components = prefix.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, let length = Int(components[1]),
              (PublicIPProbe.canonical(String(components[0]), family: .ipv4) != nil && (0...32).contains(length)) || (PublicIPProbe.canonical(String(components[0]), family: .ipv6) != nil && (0...128).contains(length)) else { throw AppIssue(message: "Malformed ASN network prefix.") }
        let asns = raw.compactMap { item -> UInt32? in
            if let text = item as? String, let value = UInt32(text), value > 0 { return value }
            if let number = item as? NSNumber, number.doubleValue.rounded() == number.doubleValue, number.doubleValue > 0, number.doubleValue <= Double(UInt32.max) { return number.uint32Value }
            return nil
        }
        guard asns.count == raw.count else { throw AppIssue(message: "Malformed ASN identifiers.") }
        return "Prefix: \(prefix)\nAnnouncing ASN: " + (asns.isEmpty ? "Not reported" : asns.map { "AS\($0)" }.joined(separator: ", "))
    }
}

struct PrivacyCapabilityReport: Codable { let timestamp: Date; let snapshots: [ProtectionSnapshot]; let safariOSState: Bool?; let safariReloadAcknowledged: Bool; let filterRuleCount: Int; let operation: String }

enum FilterBackgroundRefresh {
    static let identifier = "app.vayusetu.ios.filter-refresh"
    /// Asks iOS to wake the app roughly every 12 hours. iOS decides the actual time.
    static func schedule() {
        #if os(iOS)
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date().addingTimeInterval(12 * 3600)
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }
}

/// Waits until a web view has really finished loading a page, so scripts run against it and not against an empty frame.
final class LoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    func load(_ html: String, in view: WKWebView) async {
        view.navigationDelegate = self
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            continuation = c
            view.loadHTMLString(html, baseURL: URL(string: "https://vayusetu.test/"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.finish() }
        }
    }
    private func finish() { continuation?.resume(); continuation = nil }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish() }
}
