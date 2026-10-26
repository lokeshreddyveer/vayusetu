import XCTest
@testable import VayuSetuCore

final class StartAttemptTests: XCTestCase {
    func testStopWhileStartingWithNoRetryFailsAtOnce() {
        guard case .failed(let reason) = StartAttempt.outcome(wasStarting: true, connectionWanted: true, retryScheduled: false, autoReconnect: false) else { return XCTFail("must fail") }
        XCTAssertTrue(reason.contains("Automatic reconnect is off"))
        guard case .failed(let network) = StartAttempt.outcome(wasStarting: true, connectionWanted: true, retryScheduled: false, autoReconnect: true) else { return XCTFail("must fail") }
        XCTAssertTrue(network.contains("network was not available"))
    }
    func testScheduledRetryIsNotReportedAsFailure() {
        XCTAssertEqual(StartAttempt.outcome(wasStarting: true, connectionWanted: true, retryScheduled: true, autoReconnect: true), .retrying)
    }
    func testStopsThatAreNotFailedStartsAreLeftAlone() {
        XCTAssertEqual(StartAttempt.outcome(wasStarting: false, connectionWanted: true, retryScheduled: false, autoReconnect: true), .notAnAttempt)   // was connected
        XCTAssertEqual(StartAttempt.outcome(wasStarting: true, connectionWanted: false, retryScheduled: false, autoReconnect: true), .notAnAttempt)  // the user asked to stop
    }
    func testNeverProducesAConnectedOutcome() {
        for starting in [true, false] { for wanted in [true, false] { for retry in [true, false] { for auto in [true, false] {
            let outcome = StartAttempt.outcome(wasStarting: starting, connectionWanted: wanted, retryScheduled: retry, autoReconnect: auto)
            if case .failed = outcome { XCTAssertTrue(starting && wanted && !retry) }
        } } } }
    }
}
