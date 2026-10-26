import XCTest
@testable import VayuSetuCore

final class ExtensionInstallTests: XCTestCase {
    func testRejectionsExplainTheCauseInPlainWords() {
        XCTAssertEqual(ExtensionFailure(code: 9), .validation)
        XCTAssertTrue(ExtensionFailure(code: 9).explanation.contains("notarized"))
        XCTAssertTrue(ExtensionFailure(code: 8).explanation.contains("signature"))
        XCTAssertTrue(ExtensionFailure(code: 13).explanation.contains("approval"))
        XCTAssertTrue(ExtensionFailure(code: 3).explanation.contains("Applications"))
        XCTAssertTrue(ExtensionFailure(code: 999).explanation.contains("999"))
    }
    /// The build 59 failure: macOS never answered, nothing was logged for 90 seconds.
    func testNoAnswerIsReportedAsTimedOutAfterSixtySeconds() {
        var watch = InstallWatch(); let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(watch.verdict(at: start), .waiting)            // nothing requested yet
        watch.begin(at: start)
        XCTAssertEqual(watch.verdict(at: start.addingTimeInterval(59)), .waiting)
        XCTAssertEqual(watch.verdict(at: start.addingTimeInterval(60)), .timedOut(after: 60))
        XCTAssertEqual(watch.verdict(at: start.addingTimeInterval(90)), .timedOut(after: 90))
    }
    func testApprovalWaitHasItsOwnLongerLimit() {
        var watch = InstallWatch(); let start = Date(timeIntervalSince1970: 1_000)
        watch.begin(at: start); watch.needsApproval(at: start.addingTimeInterval(5))
        XCTAssertTrue(watch.awaitingApproval)
        XCTAssertEqual(watch.verdict(at: start.addingTimeInterval(600)), .waiting)
        XCTAssertEqual(watch.verdict(at: start.addingTimeInterval(5 + 900)), .approvalTimedOut(after: 900))
    }
    func testFinishedRequestIsNeverReportedLate() {
        var watch = InstallWatch(); let start = Date(timeIntervalSince1970: 1_000)
        watch.begin(at: start); watch.finish()
        XCTAssertFalse(watch.active)
        XCTAssertEqual(watch.verdict(at: start.addingTimeInterval(500)), .waiting)
    }
    func testRemovalIsNoticedOnlyForSomethingThatWasInstalled() {
        XCTAssertNil(ExtensionPresence.removalNote(previouslyInstalled: nil, nowInstalled: nil, uninstalling: false))
        XCTAssertNotNil(ExtensionPresence.removalNote(previouslyInstalled: "44", nowInstalled: nil, uninstalling: false))
        XCTAssertNotNil(ExtensionPresence.removalNote(previouslyInstalled: "44", nowInstalled: "44", uninstalling: true))
        XCTAssertNil(ExtensionPresence.removalNote(previouslyInstalled: "44", nowInstalled: "45", uninstalling: false))
    }
}
