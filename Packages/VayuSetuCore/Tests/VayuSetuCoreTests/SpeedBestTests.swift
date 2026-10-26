import XCTest
@testable import VayuSetuCore

final class SpeedBestTests: XCTestCase {
    private let d = Date(timeIntervalSince1970: 1_800_000_000)

    func testALivePeakIsNeverTheModesSpeed() {
        var b = SpeedBest()
        XCTAssertTrue(b.noteLive(down: 90e6, up: 40e6))
        XCTAssertEqual(b.liveDown, 90e6); XCTAssertEqual(b.liveUp, 40e6)
        XCTAssertEqual(b.topDown, 0, "no test has been made, so no speed is claimed"); XCTAssertEqual(b.topUp, 0)
        XCTAssertTrue(b.isEmpty); XCTAssertTrue(b.hasActivityPeak)
    }

    func testATestSetsTheSpeedAndDoesNotTouchTheLivePeaks() {
        var b = SpeedBest(); b.noteLive(down: 90e6, up: 40e6)
        b.noteTest(down: 30e6, up: 10e6, latencyMs: 24, date: d)
        XCTAssertEqual(b.topDown, 30e6, "the test value is shown even though the live peak is higher")
        XCTAssertEqual(b.topUp, 10e6); XCTAssertEqual(b.liveDown, 90e6); XCTAssertEqual(b.latencyMs, 24); XCTAssertEqual(b.testDate, d)
        XCTAssertFalse(b.isEmpty)
    }

    func testTheBestOfEachDirectionIsKeptButLatencyAndDateAreTheLatest() {
        var b = SpeedBest()
        b.noteTest(down: 50e6, up: 5e6, latencyMs: 20, date: d)
        b.noteTest(down: 30e6, up: 9e6, latencyMs: 35, date: d.addingTimeInterval(60))
        XCTAssertEqual(b.topDown, 50e6); XCTAssertEqual(b.topUp, 9e6, "each direction keeps its own best")
        XCTAssertEqual(b.latencyMs, 35); XCTAssertEqual(b.testDate, d.addingTimeInterval(60))
    }

    func testLivePeaksOnlyRiseAndSayWhetherTheyDid() {
        var b = SpeedBest()
        XCTAssertTrue(b.noteLive(down: 10, up: 5)); XCTAssertFalse(b.noteLive(down: 8, up: 4)); XCTAssertTrue(b.noteLive(down: 12, up: 1))
        XCTAssertEqual(b.liveDown, 12); XCTAssertEqual(b.liveUp, 5)
    }

    func testTheStoredLayoutIsUnchangedSoSavedValuesLoad() throws {
        let saved = #"{"liveDown":1000,"liveUp":500,"testDown":2000,"testUp":800,"latencyMs":18.5,"testDate":790000000}"#
        let b = try JSONDecoder().decode(SpeedBest.self, from: Data(saved.utf8))
        XCTAssertEqual(b.topDown, 2000); XCTAssertEqual(b.topUp, 800); XCTAssertEqual(b.liveDown, 1000); XCTAssertEqual(b.latencyMs, 18.5)
        let keys = (try JSONSerialization.jsonObject(with: JSONEncoder().encode(b)) as! [String: Any]).keys.sorted()
        XCTAssertEqual(keys, ["latencyMs", "liveDown", "liveUp", "testDate", "testDown", "testUp"])
        XCTAssertEqual(try JSONDecoder().decode(SpeedBest.self, from: Data("{}".utf8)), SpeedBest(), "an empty record is an empty best")
        let partial = try JSONDecoder().decode(SpeedBest.self, from: Data(#"{"testDown":7}"#.utf8))
        XCTAssertEqual(partial.topDown, 7); XCTAssertEqual(partial.topUp, 0); XCTAssertNil(partial.latencyMs)
        let whole = try JSONDecoder().decode([String: SpeedBest].self, from: Data(#"{"vpn":{"testDown":5},"dns":{"liveDown":1,"liveUp":1,"testDown":9,"testUp":3}}"#.utf8))
        XCTAssertEqual(whole["dns"]?.topDown, 9); XCTAssertEqual(whole["vpn"]?.topDown, 5, "one thin record does not cost the others")
    }
}
