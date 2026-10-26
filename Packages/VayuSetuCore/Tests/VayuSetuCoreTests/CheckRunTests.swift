import XCTest
@testable import VayuSetuCore

final class CheckRunTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testARunIsNotCompleteUntilItIsFinishedNotWhenItStarts() {
        var run = CheckRun()
        XCTAssertEqual(run.phase, .notRun); XCTAssertEqual(run.headline(coverage: "3 passed"), "Not tested")
        let token = run.begin(configuration: "A", now: t0)
        XCTAssertEqual(run.phase, .running)
        XCTAssertEqual(run.headline(coverage: "3 passed"), "Running…", "a count from earlier or from half-finished checks is never shown while running")
        XCTAssertTrue(run.finish(token: token, configuration: "A", at: t0.addingTimeInterval(9)))
        XCTAssertEqual(run.phase, .done); XCTAssertEqual(run.headline(coverage: "3 passed"), "3 passed"); XCTAssertEqual(run.finishedAt, t0.addingTimeInterval(9))
    }

    func testChangingTheResolverDuringARunVoidsItAndItCannotComplete() {
        var run = CheckRun(); let token = run.begin(configuration: "resolver-1", now: t0)
        XCTAssertFalse(run.finish(token: token, configuration: "resolver-2"), "the configuration changed while it ran")
        XCTAssertEqual(run.phase, .notRun); XCTAssertNil(run.startedAt)
        XCTAssertFalse(run.finish(token: token, configuration: "resolver-2"), "and it stays void")
    }

    func testACheckFromAnEarlierRunCannotCompleteOrAlterANewerOne() {
        var run = CheckRun()
        let old = run.begin(configuration: "A", now: t0)
        let new = run.begin(configuration: "A", now: t0.addingTimeInterval(5))
        XCTAssertFalse(run.finish(token: old, configuration: "A"), "the earlier run's check finished late")
        XCTAssertEqual(run.phase, .running); XCTAssertEqual(run.startedAt, t0.addingTimeInterval(5))
        XCTAssertTrue(run.finish(token: new, configuration: "A"))
    }

    func testInvalidatingRevokesTheTokenSoALateFinishDoesNothing() {
        var run = CheckRun(); let token = run.begin(configuration: "A", now: t0)
        run.invalidate()
        XCTAssertFalse(run.finish(token: token, configuration: "A")); XCTAssertEqual(run.phase, .notRun)
    }

    func testResultsAreValidOnlyForTheConfigurationTheyWereTakenUnder() {
        var run = CheckRun(); let token = run.begin(configuration: "A", now: t0); run.finish(token: token, configuration: "A")
        XCTAssertTrue(run.isValid(for: "A")); XCTAssertFalse(run.isValid(for: "B"))
        XCTAssertFalse(CheckRun().isValid(for: "A"), "nothing has been run")
    }

    func testOnlyEvidenceProducedAfterTheRunBeganCounts() {
        var run = CheckRun(); run.begin(configuration: "A", now: t0)
        XCTAssertTrue(run.isFresh(t0)); XCTAssertTrue(run.isFresh(t0.addingTimeInterval(3)))
        XCTAssertFalse(run.isFresh(t0.addingTimeInterval(-1)), "a stored result from before the run is stale")
        XCTAssertFalse(run.isFresh(nil)); XCTAssertFalse(CheckRun().isFresh(t0))
    }

    func testTheSignatureChangesWithAnyPart() {
        let a = CheckRun.signature(["https://resolver-1", "wireguard", "connected"])
        XCTAssertNotEqual(a, CheckRun.signature(["https://resolver-2", "wireguard", "connected"]))
        XCTAssertNotEqual(a, CheckRun.signature(["https://resolver-1", "wireguard", "disconnected"]))
        XCTAssertEqual(a, CheckRun.signature(["https://resolver-1", "wireguard", "connected"]))
        XCTAssertNotEqual(CheckRun.signature(["ab", "c"]), CheckRun.signature(["a", "bc"]), "the parts cannot run together into the same string")
    }
}
