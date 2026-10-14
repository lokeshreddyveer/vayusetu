import Foundation

@main struct ActivityTests {
    static var count = 0
    static func check(_ condition: Bool, _ line: Int = #line) { if !condition { fatalError("ActivityTests failed at line \(line)") }; count += 1 }
    static func main() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 15, minute: 25))!
        func bucket(_ date: Date, _ r: Int, _ b: Int, _ t: Int = 0) -> ActivityBucket { ActivityBucket(bucket: Int(date.timeIntervalSince1970 / 600), requests: r, blocked: b, threats: t) }
        let empty = ActivitySeries.make(period: .day, rows: [], now: now, calendar: calendar)
        check(empty.isEmpty && empty.points.count >= 24 && empty.component == .hour)
        // Two buckets in the same hour merge; another hour stays apart
        let rows = [bucket(now.addingTimeInterval(-3600 * 2), 10, 4, 1), bucket(now.addingTimeInterval(-3600 * 2 + 600), 5, 1), bucket(now.addingTimeInterval(-60), 7, 2)]
        let day = ActivitySeries.make(period: .day, rows: rows, now: now, calendar: calendar)
        check(day.requests == 22 && day.blocked == 7 && day.threats == 1 && !day.isEmpty)
        check(day.points.filter { $0.requests > 0 }.count == 2)
        // Today starts at local midnight: 16 hourly points at 15:25
        let today = ActivitySeries.make(period: .today, rows: [], now: now, calendar: calendar)
        check(today.points.count == 16 && today.points.first?.date == calendar.startOfDay(for: now))
        // Week = 7 calendar days, month = 30
        check(ActivitySeries.make(period: .week, rows: [], now: now, calendar: calendar).points.count == 7)
        check(ActivitySeries.make(period: .month, rows: [], now: now, calendar: calendar).points.count == 30)
        // A request before the period is excluded
        let old = [bucket(now.addingTimeInterval(-86400 * 3), 50, 10)]
        check(ActivitySeries.make(period: .today, rows: old, now: now, calendar: calendar).requests == 0)
        // All time: adaptive granularity
        let recent = ActivitySeries.make(period: .all, rows: [bucket(now.addingTimeInterval(-86400 * 5), 3, 1)], now: now, calendar: calendar)
        check(recent.component == .day && recent.requests == 3)
        let long = ActivitySeries.make(period: .all, rows: [bucket(now.addingTimeInterval(-86400 * 200), 3, 1)], now: now, calendar: calendar)
        check(long.component == .weekOfYear && long.requests == 3)
        let veryLong = ActivitySeries.make(period: .all, rows: [bucket(now.addingTimeInterval(-86400 * 700), 3, 1)], now: now, calendar: calendar)
        check(veryLong.component == .month)
        check(ActivitySeries.make(period: .all, rows: [], now: now, calendar: calendar).points.isEmpty)
        // DST: the fall-back day has 25 hourly slots but all counts survive
        let fall = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 20))!
        let dst = ActivitySeries.make(period: .today, rows: [bucket(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 9))!, 9, 3)], now: fall, calendar: calendar)
        check(dst.requests == 9 && dst.blocked == 3)
        check(ActivityPeriod.allCases.map(\.title) == ["Today", "24 Hours", "7 Days", "30 Days", "All Time"])
        print("Activity model checks passed: \(count)")
    }
}
