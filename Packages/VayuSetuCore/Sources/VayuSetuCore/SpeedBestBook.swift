import Foundation
import CryptoKit

/// Where a best speed applies: one mode, on one network, through one VPN profile. A speed is only ever presented for the connection it was measured on.
public struct SpeedBestKey: Codable, Hashable, Sendable {
    public var mode: String
    /// The hashed identity of the physical network, or nil when it could not be identified (then nothing is ever shown as that connection's speed).
    public var network: String?
    public var profile: String?
    public init(mode: String, network: String?, profile: String?) { self.mode = mode; self.network = network; self.profile = profile }
    public var id: String { [mode, network ?? "-", profile ?? "-"].joined(separator: "|") }
    /// A short stable token for an identifier such as a profile's id, so what is stored holds neither its name nor its address.
    public static func token(_ text: String) -> String { SHA256.hash(data: Data(("vayusetu-speed|" + text).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() }
}

/// The best speed tests, and the live activity peaks, kept for each connection separately.
///
/// Each entry says when it was measured and against which server, and belongs to the network and VPN profile it was measured on. Results saved before this
/// existed carry no network (`legacy`, one per mode): they are kept so nothing is lost, but they are never shown as the speed of the current connection.
public struct SpeedBestBook: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var key: SpeedBestKey
        public var best: SpeedBest
        /// The server the best test ran against, and the method (for example "mensura.cdn-apple.com", "http-download").
        public var endpoint: String?
        public var method: String?
        /// When anything in this entry last changed, for keeping the book bounded.
        public var updated: Date
    }
    public private(set) var entries: [String: Entry] = [:]
    /// Bests from before the network was recorded, by mode.
    public private(set) var legacy: [String: SpeedBest] = [:]
    public static let maximumEntries = 200
    public init() {}

    /// Wraps the old per-mode dictionary. Nothing in it can be attributed to a connection.
    public static func migrating(legacy: [String: SpeedBest]) -> SpeedBestBook { var b = SpeedBestBook(); b.legacy = legacy.filter { !$0.value.isEmpty || $0.value.hasActivityPeak }; return b }

    /// The entry for exactly this connection, or nil. A nil network never matches anything.
    public func entry(for key: SpeedBestKey) -> Entry? { key.network == nil ? nil : entries[key.id] }

    @discardableResult
    public mutating func noteTest(_ key: SpeedBestKey, down: Double, up: Double, latencyMs: Double?, date: Date, endpoint: String?, method: String?) -> Bool {
        guard key.network != nil else { return false }          // an unidentified network is not a place a speed can belong to
        var e = entries[key.id] ?? Entry(key: key, best: SpeedBest(), endpoint: nil, method: nil, updated: date)
        e.best.noteTest(down: down, up: up, latencyMs: latencyMs, date: date)
        if down >= e.best.testDown { e.endpoint = endpoint; e.method = method }      // the server is the one the best download ran against
        e.updated = date; entries[key.id] = e; trim()
        return true
    }

    @discardableResult
    public mutating func noteLive(_ key: SpeedBestKey, down: Double, up: Double, now: Date = Date()) -> Bool {
        guard key.network != nil else { return false }
        var e = entries[key.id] ?? Entry(key: key, best: SpeedBest(), endpoint: nil, method: nil, updated: now)
        guard e.best.noteLive(down: down, up: up) else { return false }
        e.updated = now; entries[key.id] = e; trim()
        return true
    }

    private mutating func trim() {
        guard entries.count > Self.maximumEntries else { return }
        for id in entries.sorted(by: { $0.value.updated < $1.value.updated }).prefix(entries.count - Self.maximumEntries).map(\.key) { entries.removeValue(forKey: id) }
    }

    /// How many connections other than this one have saved results (shown as a count, never compared).
    public func elsewhere(than key: SpeedBestKey) -> Int { entries.values.filter { $0.key.network != nil && $0.key.network != key.network && !$0.best.isEmpty }.count }
    public var hasLegacy: Bool { legacy.values.contains { !$0.isEmpty } }
    public mutating func clear() { entries = [:]; legacy = [:] }
}
