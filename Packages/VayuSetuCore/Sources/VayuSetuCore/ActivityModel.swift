import Foundation

/// One 10-minute slice of observed DNS activity. Aggregate counts only; no domain names.
public struct ActivityBucket: Equatable, Sendable {
    public let bucket: Int, requests: Int, blocked: Int, threats: Int
    public init(bucket: Int, requests: Int, blocked: Int, threats: Int) { self.bucket = bucket; self.requests = requests; self.blocked = blocked; self.threats = threats }
    public var date: Date { Date(timeIntervalSince1970: TimeInterval(bucket * 600)) }
}

public enum ActivityPeriod: String, CaseIterable, Identifiable, Sendable {
    case hour, today, day, week, month, year, all, custom
    public var id: String { rawValue }
    public var title: String { switch self { case .hour: "Live (last hour)"; case .today: "Today"; case .day: "24 Hours"; case .week: "7 Days"; case .month: "30 Days"; case .year: "1 Year"; case .all: "All Time"; case .custom: "Custom range" } }
    /// First instant of the period; nil means everything recorded. A custom range supplies its own start, so it reports nil here.
    public func start(now: Date, calendar: Calendar) -> Date? {
        switch self {
        case .hour: return now.addingTimeInterval(-3600)
        case .year: return calendar.date(byAdding: .day, value: -364, to: calendar.startOfDay(for: now))
        case .custom: return nil
        case .today: return calendar.startOfDay(for: now)
        case .day: return now.addingTimeInterval(-24 * 3600)
        case .week: return calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))
        case .month: return calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now))
        case .all: return nil
        }
    }
}

public struct ActivityPoint: Identifiable, Equatable, Sendable {
    public let date: Date, requests: Int, blocked: Int, threats: Int
    public var id: Date { date }
}

public struct ActivitySeries: Equatable, Sendable {
    public let period: ActivityPeriod
    public let component: Calendar.Component
    public let points: [ActivityPoint]
    public var requests: Int { points.reduce(0) { $0 + $1.requests } }
    public var blocked: Int { points.reduce(0) { $0 + $1.blocked } }
    public var threats: Int { points.reduce(0) { $0 + $1.threats } }
    /// True when nothing at all was observed in the period (so the UI shows an empty state, not a flat line).
    public var isEmpty: Bool { requests == 0 && blocked == 0 }

    /// Aggregates buckets into hourly, daily, weekly or monthly points using calendar boundaries, so time zones and daylight saving are respected.
    /// `custom` is the chosen range when the period is `.custom`; its end covers that whole day.
    public static func make(period: ActivityPeriod, rows: [ActivityBucket], now: Date, calendar: Calendar, custom: ClosedRange<Date>? = nil) -> ActivitySeries {
        if period == .hour { return live(rows: rows, now: now) }
        var rows = rows
        var now = now
        var customStart: Date?
        if period == .custom {
            guard let custom else { return ActivitySeries(period: period, component: .day, points: []) }
            let start = calendar.startOfDay(for: custom.lowerBound)
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: custom.upperBound)).map { $0.addingTimeInterval(-1) } ?? custom.upperBound
            rows = rows.filter { $0.date >= start && $0.date <= end }
            customStart = start; now = min(now, end)
        }
        let first = customStart ?? rows.first?.date
        let component: Calendar.Component
        switch period {
        case .today, .day: component = .hour
        case .week, .month: component = .day
        case .year: component = .weekOfYear
        case .hour: component = .minute
        case .custom:
            let days = customStart.map { calendar.dateComponents([.day], from: $0, to: now).day ?? 0 } ?? 0
            component = days <= 2 ? .hour : days <= 120 ? .day : .weekOfYear
        case .all:
            let days = first.map { calendar.dateComponents([.day], from: $0, to: now).day ?? 0 } ?? 0
            component = days <= 60 ? .day : days <= 400 ? .weekOfYear : .month
        }
        func floor(_ date: Date) -> Date { calendar.dateInterval(of: component, for: date)?.start ?? date }
        var sums: [Date: (Int, Int, Int)] = [:]
        for row in rows { let key = floor(row.date); let old = sums[key] ?? (0, 0, 0); sums[key] = (old.0 + row.requests, old.1 + row.blocked, old.2 + row.threats) }
        guard let begin = customStart.map(floor) ?? period.start(now: now, calendar: calendar).map(floor) ?? first.map(floor) else { return ActivitySeries(period: period, component: component, points: []) }
        var points: [ActivityPoint] = []
        var cursor = begin
        while cursor <= now && points.count < 4000 {
            let v = sums[cursor] ?? (0, 0, 0)
            points.append(ActivityPoint(date: cursor, requests: v.0, blocked: v.1, threats: v.2))
            guard let next = calendar.date(byAdding: component, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        return ActivitySeries(period: period, component: component, points: points)
    }

    /// The last hour in the slices that are actually recorded (10 minutes each), so the chart follows the traffic as it arrives.
    private static func live(rows: [ActivityBucket], now: Date) -> ActivitySeries {
        let current = Int(now.timeIntervalSince1970 / 600)
        let byBucket = Dictionary(rows.map { ($0.bucket, $0) }, uniquingKeysWith: { a, _ in a })
        let points = (current - 6 ... current).map { bucket -> ActivityPoint in
            let row = byBucket[bucket]
            return ActivityPoint(date: Date(timeIntervalSince1970: TimeInterval(bucket * 600)), requests: row?.requests ?? 0, blocked: row?.blocked ?? 0, threats: row?.threats ?? 0)
        }
        return ActivitySeries(period: .hour, component: .minute, points: points)
    }
}
