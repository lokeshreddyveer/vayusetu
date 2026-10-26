import Foundation

/// The optional domain history: how many times each domain was blocked or let through, per day. Counts only, no times of day, no apps.
/// This file is the pure part (ranking, totals, retention) so it can be tested; the database and the collection live in the app.
public struct DomainDayCount: Equatable, Sendable {
    /// Days since 1970-01-01 in the local calendar.
    public let day: Int
    public let name: String
    public let allowed: Int
    public let blocked: Int
    public init(day: Int, name: String, allowed: Int, blocked: Int) { self.day = day; self.name = name; self.allowed = allowed; self.blocked = blocked }
}

public struct DomainRow: Equatable, Identifiable, Sendable {
    public let name: String
    public let count: Int
    /// Share of the ranked kind's total (0...1), counting domains that were not listed individually too.
    public let share: Double
    public var id: String { name }
}

public struct DomainTotals: Equatable, Sendable {
    public let allowed: Int
    public let blocked: Int
    public var total: Int { allowed + blocked }
    /// 0...1; zero when nothing was counted.
    public var blockedShare: Double { total == 0 ? 0 : Double(blocked) / Double(total) }
}

public enum DomainHistory {
    public enum Kind: Sendable { case blocked, allowed }
    /// Days kept, by the user's choice.
    public static let retentionChoices = [7, 30, 365]
    /// Domains kept for each day; the least active are dropped first. The others are not lost from the totals.
    public static let perDayLimit = 500

    /// The day number for a date, in `calendar`'s time zone.
    public static func day(for date: Date, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: date)
        return Int((start.timeIntervalSince1970 + Double(calendar.timeZone.secondsFromGMT(for: start))) / 86400)
    }

    /// The first day to keep. Anything earlier is deleted.
    public static func firstDayKept(now: Date, retentionDays: Int, calendar: Calendar = .current) -> Int {
        day(for: now, calendar: calendar) - max(1, retentionDays) + 1
    }

    /// The first and last day for a reporting period. Domain history is daily, so a period shorter than a day is the whole of today,
    /// and 24 hours is today and yesterday. The caller says so in the interface.
    public static func dayRange(period: ActivityPeriod, now: Date, custom: ClosedRange<Date>?, calendar: Calendar = .current) -> ClosedRange<Int>? {
        let today = day(for: now, calendar: calendar)
        switch period {
        case .hour, .today: return today...today
        case .day: return (today - 1)...today
        case .week: return (today - 6)...today
        case .month: return (today - 29)...today
        case .year: return (today - 364)...today
        case .all: return Int.min...today
        case .custom:
            guard let custom else { return nil }
            let a = day(for: custom.lowerBound, calendar: calendar), b = min(day(for: custom.upperBound, calendar: calendar), today)
            return a <= b ? a...b : nil
        }
    }

    public static func totals(_ rows: [DomainDayCount], days: ClosedRange<Int>) -> DomainTotals {
        var allowed = 0, blocked = 0
        for r in rows where days.contains(r.day) { allowed += r.allowed; blocked += r.blocked }
        return DomainTotals(allowed: allowed, blocked: blocked)
    }

    /// The most active domains of one kind in a range of days. Domains not listed individually (an empty name) count towards the share
    /// but are never shown as a row.
    public static func rank(_ rows: [DomainDayCount], kind: Kind, days: ClosedRange<Int>, limit: Int) -> [DomainRow] {
        var sums: [String: Int] = [:]
        var all = 0
        for r in rows where days.contains(r.day) {
            let n = kind == .blocked ? r.blocked : r.allowed
            guard n > 0 else { continue }
            all += n
            if !r.name.isEmpty { sums[r.name, default: 0] += n }
        }
        guard all > 0 else { return [] }
        return sums.map { DomainRow(name: $0.key, count: $0.value, share: Double($0.value) / Double(all)) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
            .prefix(limit).map { $0 }
    }

    /// One domain's counts for each day in the range, oldest first, with days it was not seen as zero.
    public static func series(for name: String, rows: [DomainDayCount], days: ClosedRange<Int>) -> [DomainDayCount] {
        var byDay: [Int: DomainDayCount] = [:]
        for r in rows where r.name == name && days.contains(r.day) { byDay[r.day] = r }
        let first = max(days.lowerBound, byDay.keys.min() ?? days.upperBound), last = days.upperBound
        guard first <= last, last - first < 4000 else { return [] }
        return (first...last).map { byDay[$0] ?? DomainDayCount(day: $0, name: name, allowed: 0, blocked: 0) }
    }

    /// Merges counts taken from the tunnel into a day's table, keeping at most `perDayLimit` named domains. The ones dropped are added to
    /// the unnamed row so totals stay exact.
    public static func merge(day: Int, existing: [String: (allowed: Int, blocked: Int)], taken: [(name: String, allowed: Int, blocked: Int)]) -> [String: (allowed: Int, blocked: Int)] {
        var table = existing
        for t in taken {
            let old = table[t.name] ?? (0, 0)
            table[t.name] = (old.allowed + t.allowed, old.blocked + t.blocked)
        }
        var named = table.filter { !$0.key.isEmpty }
        guard named.count > perDayLimit else { return table }
        let drop = named.sorted { ($0.value.allowed + $0.value.blocked, $1.key) < ($1.value.allowed + $1.value.blocked, $0.key) }.prefix(named.count - perDayLimit)
        var other = table[""] ?? (0, 0)
        for (name, value) in drop { other.allowed += value.allowed; other.blocked += value.blocked; named[name] = nil }
        named[""] = other
        return named
    }
}
