import XCTest
@testable import VayuSetuCore

final class SpeedStreamTests: XCTestCase {
    func testOneWorkersRefusalDoesNotStopOrChangeTheOthers() {
        let refused = SpeedStreamState(), fine = SpeedStreamState(), quiet = SpeedStreamState()
        refused.note(status: 429); fine.note(status: 200)
        XCTAssertTrue(refused.shouldStop); XCTAssertFalse(fine.shouldStop, "a refusal on another stream is not this stream's")
        XCTAssertFalse(quiet.shouldStop); XCTAssertEqual(quiet.status, 0)
        XCTAssertEqual(fine.status, 200); XCTAssertEqual(refused.status, 429)
    }

    func testAnAnsweredStreamDoesNotHideARefusedOne() {
        let a = SpeedStreamState(), b = SpeedStreamState()
        a.note(status: 429); b.note(status: 200)         // b answers last, as the old shared status would have read it
        XCTAssertEqual(SpeedStreamReport.describe(source: "Apple", statuses: [a.status, b.status]), "Apple: 1 answered 200, 1 answered 429 of 2 streams")
    }

    func testTheDescriptionNamesWhatHappenedOnEveryStream() {
        XCTAssertEqual(SpeedStreamReport.describe(source: "Cloudflare", statuses: [429, 429, 429]), "Cloudflare answered 429 on all 3 streams")
        XCTAssertEqual(SpeedStreamReport.describe(source: "Cloudflare", statuses: [0, 0]), "Cloudflare did not answer")
        XCTAssertEqual(SpeedStreamReport.describe(source: "Apple", statuses: [503]), "Apple answered 503")
        XCTAssertEqual(SpeedStreamReport.describe(source: "Apple", statuses: []), "Apple did not answer")
        XCTAssertEqual(SpeedStreamReport.describe(source: "Apple", statuses: [429, 429, 200, 0]), "Apple: 2 answered 429, 1 answered 200, 1 did not answer of 4 streams")
    }

    func testBytesAreCountedPerWorkerAndSummedOnlyForTheRunThatOwnsThem() {
        let first = [SpeedStreamState(), SpeedStreamState()], second = [SpeedStreamState(), SpeedStreamState()]
        first[0].add(bytes: 1_000); first[1].add(bytes: 2_000)
        XCTAssertEqual(SpeedStreamReport.totalBytes(first), 3_000)
        // The first run was cancelled and a late chunk arrives for it; the second run, which owns different states, is untouched.
        first[0].add(bytes: 500)
        XCTAssertEqual(SpeedStreamReport.totalBytes(second), 0); XCTAssertEqual(SpeedStreamReport.totalBytes(first), 3_500)
        first[0].add(bytes: -5); first[0].add(bytes: 0)
        XCTAssertEqual(first[0].bytes, 1_500, "a negative or empty report adds nothing")
    }

    func testConcurrentWorkersNeverMixTheirCounts() {
        let streams = (0..<8).map { _ in SpeedStreamState() }
        DispatchQueue.concurrentPerform(iterations: 8) { i in
            for n in 0..<2_000 { streams[i].add(bytes: Int64(i + 1)); if n % 500 == 0 { streams[i].note(status: i % 2 == 0 ? 200 : 429) } }
        }
        for (i, s) in streams.enumerated() {
            XCTAssertEqual(s.bytes, Int64(2_000 * (i + 1)), "stream \(i) counted only its own bytes")
            XCTAssertEqual(s.status, i % 2 == 0 ? 200 : 429)
        }
        XCTAssertEqual(SpeedStreamReport.totalBytes(streams), Int64(2_000 * (1...8).reduce(0, +)))
    }

    func testEverAnsweredRemembersASuccessAfterALaterRefusal() {
        let s = SpeedStreamState(); s.note(status: 200); s.note(status: 429)
        XCTAssertTrue(s.everAnswered); XCTAssertTrue(s.shouldStop)
        XCTAssertFalse(SpeedStreamState().everAnswered)
    }
}
