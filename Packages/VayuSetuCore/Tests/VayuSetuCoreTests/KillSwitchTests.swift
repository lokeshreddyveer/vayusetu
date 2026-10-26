import XCTest
@testable import VayuSetuCore

final class KillSwitchTests: XCTestCase {
    func testOffMeansOffWhateverElseIsTrue() {
        XCTAssertEqual(KillSwitchState.assess(settingOn: false, vpnRunning: true, connected: true, savedCapture: true), .off)
        XCTAssertEqual(KillSwitchState.assess(settingOn: false, vpnRunning: false, connected: false, savedCapture: nil), .off)
    }
    func testNoVPNRunningIsReadyNotEnforced() {
        XCTAssertEqual(KillSwitchState.assess(settingOn: true, vpnRunning: false, connected: false, savedCapture: false), .armed)
    }
    func testConnectedWithCaptureIsEnforcedAndReconnectingHolds() {
        XCTAssertEqual(KillSwitchState.assess(settingOn: true, vpnRunning: true, connected: true, savedCapture: true), .enforced)
        XCTAssertEqual(KillSwitchState.assess(settingOn: true, vpnRunning: true, connected: false, savedCapture: true), .holding)
    }
    func testASettingThatNeverReachedTheSavedConfigurationIsCalledOut() {
        let s = KillSwitchState.assess(settingOn: true, vpnRunning: true, connected: true, savedCapture: false)
        XCTAssertEqual(s, .notEnforced); XCTAssertTrue(s.needsAttention)
        XCTAssertEqual(KillSwitchState.assess(settingOn: true, vpnRunning: true, connected: true, savedCapture: nil), .unknown)
        XCTAssertTrue(KillSwitchState.unknown.needsAttention, "not being able to confirm protection is as urgent as it missing")
    }
    func testWordsNeverOverclaim() {
        let all: [KillSwitchState] = [.off, .armed, .enforced, .holding, .notEnforced, .unknown]
        XCTAssertEqual(Set(all.map(\.title)).count, 6)
        XCTAssertTrue(KillSwitchState.unknown.detail.contains("cannot confirm"), "it says what is not known, rather than reporting a quiet 'unknown'")
        XCTAssertTrue(KillSwitchState.unknown.title.contains("cannot be verified"))
        XCTAssertTrue(KillSwitchState.enforced.detail.contains("does not test"), "it says it did not test the drop")
    }

    func testOnlyAConfirmedSwitchCountsAsProtectingAndNothingUnconfirmedLooksCalm() {
        for state in [KillSwitchState.enforced, .holding] { XCTAssertTrue(state.isConfirmedProtective); XCTAssertFalse(state.needsAttention) }
        for state in [KillSwitchState.notEnforced, .unknown] { XCTAssertFalse(state.isConfirmedProtective); XCTAssertTrue(state.needsAttention) }
        for state in [KillSwitchState.off, .armed] { XCTAssertFalse(state.isConfirmedProtective); XCTAssertFalse(state.needsAttention, "these say plainly that nothing is protecting yet") }
    }
    func testAnUnreadableConfigurationWhileAVPNRunsIsNeverCalmWhateverTheOtherInputsAre() {
        for connected in [true, false] {
            let s = KillSwitchState.assess(settingOn: true, vpnRunning: true, connected: connected, savedCapture: nil)
            XCTAssertEqual(s, .unknown); XCTAssertTrue(s.needsAttention)
        }
    }
}
