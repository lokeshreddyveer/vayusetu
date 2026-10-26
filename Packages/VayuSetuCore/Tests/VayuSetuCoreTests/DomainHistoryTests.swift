import XCTest
@testable import VayuSetuCore

final class DomainHistoryTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Chicago")!; return c }
    private let now = Date(timeIntervalSince1970: 1_792_000_000)
    private func row(_ day: Int, _ name: String, _ a: Int, _ b: Int) -> DomainDayCount { DomainDayCount(day: day, name: name, allowed: a, blocked: b) }

    func testDayNumbersFollowTheLocalCalendar() {
        let today = DomainHistory.day(for: now, calendar: calendar)
        XCTAssertEqual(DomainHistory.day(for: now.addingTimeInterval(86400), calendar: calendar), today + 1)
        XCTAssertEqual(DomainHistory.firstDayKept(now: now, retentionDays: 7, calendar: calendar), today - 6)
    }

    func testRangesPerPeriod() {
        let today = DomainHistory.day(for: now, calendar: calendar)
        XCTAssertEqual(DomainHistory.dayRange(period: .hour, now: now, custom: nil, calendar: calendar), today...today)
        XCTAssertEqual(DomainHistory.dayRange(period: .day, now: now, custom: nil, calendar: calendar), (today - 1)...today)
        XCTAssertEqual(DomainHistory.dayRange(period: .week, now: now, custom: nil, calendar: calendar), (today - 6)...today)
        XCTAssertEqual(DomainHistory.dayRange(period: .year, now: now, custom: nil, calendar: calendar), (today - 364)...today)
        XCTAssertNil(DomainHistory.dayRange(period: .custom, now: now, custom: nil, calendar: calendar))
        let custom = now.addingTimeInterval(-5 * 86400)...now.addingTimeInterval(-3 * 86400)
        XCTAssertEqual(DomainHistory.dayRange(period: .custom, now: now, custom: custom, calendar: calendar)?.count, 3)
    }

    func testRankingSumsDaysIgnoresOtherRowsAndKeepsTheShareOfEverything() {
        let rows = [row(10, "ads.example", 0, 6), row(11, "ads.example", 0, 4), row(10, "track.example", 0, 5), row(10, "", 0, 5), row(10, "site.example", 20, 0), row(30, "old.example", 0, 99)]
        let blocked = DomainHistory.rank(rows, kind: .blocked, days: 10...12, limit: 5)
        XCTAssertEqual(blocked.map(\.name), ["ads.example", "track.example"])
        XCTAssertEqual(blocked.first?.count, 10)
        XCTAssertEqual(blocked.first?.share ?? 0, 0.5, accuracy: 0.0001, "10 of the 20 blocked lookups, the unnamed ones included")
        XCTAssertEqual(DomainHistory.rank(rows, kind: .allowed, days: 10...12, limit: 5).map(\.name), ["site.example"])
        XCTAssertTrue(DomainHistory.rank(rows, kind: .blocked, days: 50...60, limit: 5).isEmpty)
    }

    func testTotalsAndBlockedShare() {
        let rows = [row(1, "a", 30, 10), row(2, "b", 10, 0), row(9, "c", 500, 500)]
        let totals = DomainHistory.totals(rows, days: 1...2)
        XCTAssertEqual(totals.total, 50)
        XCTAssertEqual(totals.blockedShare, 0.2, accuracy: 0.0001)
        XCTAssertEqual(DomainHistory.totals([], days: 1...2).blockedShare, 0)
    }

    func testSeriesFillsQuietDaysWithZero() {
        let rows = [row(3, "x", 1, 2), row(5, "x", 4, 0), row(5, "y", 9, 9)]
        let s = DomainHistory.series(for: "x", rows: rows, days: 1...6)
        XCTAssertEqual(s.map(\.day), [3, 4, 5, 6])
        XCTAssertEqual(s.map { $0.allowed + $0.blocked }, [3, 0, 4, 0])
    }

    func testMergeAddsAndKeepsTotalsExactWhenTheDayIsTrimmed() {
        var table: [String: (allowed: Int, blocked: Int)] = [:]
        table = DomainHistory.merge(day: 1, existing: table, taken: [("a", 2, 0), ("b", 0, 1)])
        table = DomainHistory.merge(day: 1, existing: table, taken: [("a", 3, 1)])
        XCTAssertEqual(table["a"]?.allowed, 5); XCTAssertEqual(table["a"]?.blocked, 1)
        let many = (0..<(DomainHistory.perDayLimit + 40)).map { (name: "d\($0).example", allowed: 1 + $0 % 3, blocked: 0) }
        let trimmed = DomainHistory.merge(day: 1, existing: [:], taken: many)
        XCTAssertEqual(trimmed.filter { !$0.key.isEmpty }.count, DomainHistory.perDayLimit)
        XCTAssertEqual(trimmed.values.reduce(0) { $0 + $1.allowed }, many.reduce(0) { $0 + $1.allowed }, "nothing is lost from the totals")
    }
}
