import XCTest
@testable import VayuSetuCore

final class ActivityPeriodTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func bucket(_ date: Date, requests: Int, blocked: Int = 0) -> ActivityBucket { ActivityBucket(bucket: Int(date.timeIntervalSince1970 / 600), requests: requests, blocked: blocked, threats: 0) }
    private let now = Date(timeIntervalSince1970: 1_792_000_000)

    func testLiveCoversTheLastHourInRecordedSlices() {
        let rows = [bucket(now.addingTimeInterval(-300), requests: 10, blocked: 2), bucket(now.addingTimeInterval(-7200), requests: 99)]
        let series = ActivitySeries.make(period: .hour, rows: rows, now: now, calendar: calendar)
        XCTAssertEqual(series.points.count, 7)
        XCTAssertEqual(series.requests, 10, "slices older than the hour are not counted")
        XCTAssertEqual(series.blocked, 2)
    }

    func testYearCountsEverythingWithinThreeHundredSixtyFiveDaysAndNothingOlder() {
        let rows = [bucket(now.addingTimeInterval(-200 * 86400), requests: 5), bucket(now.addingTimeInterval(-400 * 86400), requests: 7)]
        let from = ActivityPeriod.year.start(now: now, calendar: calendar)!
        let series = ActivitySeries.make(period: .year, rows: rows.filter { $0.date >= from }, now: now, calendar: calendar)
        XCTAssertEqual(series.requests, 5)
        XCTAssertEqual(series.component, .weekOfYear)
    }

    func testCustomRangeKeepsOnlyTheChosenDaysIncludingTheLastWholeDay() {
        let day = calendar.startOfDay(for: now.addingTimeInterval(-10 * 86400))
        let rows = [bucket(day.addingTimeInterval(3600), requests: 4), bucket(day.addingTimeInterval(86400 + 82_000), requests: 6), bucket(day.addingTimeInterval(3 * 86400), requests: 50)]
        let range = day...day.addingTimeInterval(86400 + 3600)        // two days, the second chosen at 01:00
        let series = ActivitySeries.make(period: .custom, rows: rows, now: now, calendar: calendar, custom: range)
        XCTAssertEqual(series.requests, 10, "the whole of the last chosen day counts")
        XCTAssertEqual(series.component, .hour)
    }

    func testCustomWithoutARangeIsEmptyAndLongRangesUseWeeks() {
        XCTAssertTrue(ActivitySeries.make(period: .custom, rows: [], now: now, calendar: calendar, custom: nil).points.isEmpty)
        let start = now.addingTimeInterval(-300 * 86400)
        let series = ActivitySeries.make(period: .custom, rows: [bucket(start.addingTimeInterval(5000), requests: 1)], now: now, calendar: calendar, custom: start...now)
        XCTAssertEqual(series.component, .weekOfYear)
        XCTAssertEqual(series.requests, 1)
    }

    func testEveryPeriodHasATitle() { for period in ActivityPeriod.allCases { XCTAssertFalse(period.title.isEmpty) } }
}
