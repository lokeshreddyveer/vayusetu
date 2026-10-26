import Foundation

/// One run of the scheduled diagnostic. Nothing in it identifies a network or an address.
public struct ScheduledCheckRecord: Codable, Equatable, Sendable {
    public var date: Date
    /// Skipped because the connection costs data or is in low-data mode.
    public var skipped: Bool
    public var signInPageSeen: Bool?
    public var publicAddressChanged: Bool?
    public var slowestNameServerMs: Double?
    public var vpnOn: Bool
    public init(date: Date, skipped: Bool, signInPageSeen: Bool? = nil, publicAddressChanged: Bool? = nil, slowestNameServerMs: Double? = nil, vpnOn: Bool = false) {
        self.date = date; self.skipped = skipped; self.signInPageSeen = signInPageSeen; self.publicAddressChanged = publicAddressChanged; self.slowestNameServerMs = slowestNameServerMs; self.vpnOn = vpnOn
    }
}

public enum ScheduledReport {
    public static let maximumRecords = 200
    public static func appended(_ records: [ScheduledCheckRecord], _ new: ScheduledCheckRecord) -> [ScheduledCheckRecord] { Array((records + [new]).suffix(maximumRecords)) }

    /// A section for the quality report: when the checks ran, what they found, and how each figure was obtained. It states the observation period
    /// and leaves out addresses, network names and the sign-in page's address.
    public static func section(_ records: [ScheduledCheckRecord], dayName: (Int) -> String, calendar: Calendar = .current) -> [String] {
        guard let first = records.map(\.date).min(), let last = records.map(\.date).max() else {
            return ["Scheduled checks: none have run (they are off unless you choose an interval)."]
        }
        let ran = records.filter { !$0.skipped }, skipped = records.count - ran.count
        func day(_ d: Date) -> String { dayName(DomainHistory.day(for: d, calendar: calendar)) }
        var lines = ["Scheduled checks (Measured): \(ran.count) run\(ran.count == 1 ? "" : "s") between \(day(first)) and \(day(last))" + (skipped > 0 ? ", \(skipped) skipped on a connection that costs data" : "")]
        let portal = ran.filter { $0.signInPageSeen == true }.count
        if ran.contains(where: { $0.signInPageSeen != nil }) { lines.append("- A sign-in page was blocking the internet in \(portal) of \(ran.filter { $0.signInPageSeen != nil }.count) checks")}
        let changed = ran.filter { $0.publicAddressChanged == true }.count
        if ran.contains(where: { $0.publicAddressChanged != nil }) { lines.append("- The public address changed between checks \(changed) time\(changed == 1 ? "" : "s")") }
        let slow = ran.compactMap(\.slowestNameServerMs).sorted()
        if slow.count >= 3 { lines.append(String(format: "- Slowest name server: typically about %.0f ms (worst %.0f ms)", slow[slow.count / 2], slow.last ?? 0)) }
        if ran.count < 3 { lines.append("- Too few checks to draw conclusions yet.") }
        return lines
    }
}

/// Domains the DNS tunnel counted in the minutes before a stall, kept in memory only and only while the person has allowed it. Names and counts, no
/// times within a batch, nothing written to disk by this type, and nothing that is ever put into the shareable quality report.
public struct RecentDomainRing: Equatable, Sendable {
    public struct Entry: Equatable, Sendable { public var at: Date; public var name: String; public var allowed: Int; public var blocked: Int }
    public private(set) var entries: [Entry] = []
    public static let retention: TimeInterval = 600
    public static let maximumEntries = 3000
    public private(set) var enabled = false
    public init() {}

    /// Turning it off forgets everything at once.
    public mutating func setEnabled(_ on: Bool) { enabled = on; if !on { entries.removeAll() } }
    public mutating func add(name: String, allowed: Int, blocked: Int, at: Date) {
        guard enabled, !name.isEmpty else { return }
        entries.append(Entry(at: at, name: name, allowed: allowed, blocked: blocked))
        prune(now: at)
    }
    public mutating func prune(now: Date) {
        entries.removeAll { now.timeIntervalSince($0.at) > Self.retention }
        if entries.count > Self.maximumEntries { entries.removeFirst(entries.count - Self.maximumEntries) }
    }
    /// The busiest names counted in `[from, to]`, for the minute before a stall.
    public func top(from: Date, to: Date, limit: Int = 5) -> [(name: String, count: Int)] {
        guard enabled else { return [] }
        var sums: [String: Int] = [:]
        for e in entries where e.at >= from && e.at <= to { sums[e.name, default: 0] += e.allowed + e.blocked }
        return sums.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(limit).map { ($0.key, $0.value) }
    }
    /// Whether the ring can speak for a window: it must have been on for all of it.
    public func covers(from: Date) -> Bool { enabled && (entries.first.map { $0.at <= from.addingTimeInterval(5) } ?? false) }
}
