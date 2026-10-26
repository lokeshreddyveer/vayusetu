import XCTest
@testable import VayuSetuCore

final class SetupGuideTests: XCTestCase {
    private func steps(_ build: (inout SetupObservations) -> Void) -> [SetupStep] { var o = SetupObservations(); build(&o); return SetupGuide.steps(o) }
    private func state(_ s: [SetupStep], _ id: String) -> SetupStep.State? { s.first { $0.id == id }?.state }

    func testFreshInstallStartsAtTheExtension() {
        let s = steps { _ in }
        XCTAssertEqual(SetupGuide.next(s)?.id, "tunnel"); XCTAssertFalse(SetupGuide.isComplete(s))
        XCTAssertEqual(SetupGuide.progress(s).done, 0)
    }
    func testWaitingForApprovalIsBlockedWithInstructions() {
        let s = steps { $0.tunnelNeedsApproval = true }
        XCTAssertEqual(state(s, "tunnel"), .blocked); XCTAssertTrue(s[0].detail.contains("Network Extensions"))
    }
    func testStepsAdvanceFromObservations() {
        let s = steps { $0.tunnelInstalled = true; $0.hasDNSChoice = true }
        XCTAssertEqual(state(s, "tunnel"), .done); XCTAssertEqual(state(s, "profile"), .done)
        XCTAssertEqual(SetupGuide.next(s)?.id, "proof")
    }
    func testCompleteOnlyWhenRequiredStepsAreDone() {
        let all = steps { $0.tunnelInstalled = true; $0.hasVPNProfile = true; $0.proofWorking = true }
        XCTAssertTrue(SetupGuide.isComplete(all), "optional steps do not hold completion back")
        XCTAssertEqual(state(all, "filter"), .optionalTodo)
    }
    func testSafariIsOptionalAndCountsExtensions() {
        XCTAssertNil(state(steps { _ in }, "safari"), "not shown until Safari's state has been read")
        XCTAssertEqual(state(steps { $0.safariExtensionsOn = 2; $0.safariExtensionsNeeded = 6 }, "safari"), .optionalTodo)
        XCTAssertEqual(state(steps { $0.safariExtensionsOn = 6; $0.safariExtensionsNeeded = 6 }, "safari"), .done)
        XCTAssertEqual(state(steps { $0.safariExtensionsOn = 0; $0.safariExtensionsNeeded = 0 }, "safari"), .optionalTodo)
    }
    func testFilterStepHiddenWhereUnavailable() { XCTAssertNil(state(steps { $0.filterAvailable = false }, "filter")) }

    func testFailureAdviceRecognisesTheMessagesWeShip() {
        let cases: [(String, String)] = [
            ("App Group access is unavailable.", "folder"),
            ("The saved keys for us-den are missing. Edit the profile and import its configuration file again.", "keys"),
            ("A valid private key and at least one peer are required.", "keys"),
            ("The profile has no [Peer] section.", "no server"),
            ("Another VPN tunnel is active. Disconnect it before starting VayuSetu.", "Another VPN"),
            ("Disconnect before changing the active configuration.", "still running"),
            ("The system extension did not finish starting the tunnel.", "did not finish"),
            ("Resolver bootstrap timed out.", "look up"),
            ("Tunnel setup failed. Check your profile, resolver, Keychain sharing, and Network Extension provisioning.", "stopped while"),
            ("Keychain operation failed (-25308).", "saved keys"),
        ]
        for (raw, expect) in cases {
            let advice = FailureAdvice.plain(raw)
            XCTAssertNotNil(advice, raw)
            XCTAssertTrue((advice?.happened ?? "").contains(expect), raw + " -> " + (advice?.happened ?? "nil"))
            XCTAssertFalse((advice?.todo ?? "").isEmpty)
        }
        XCTAssertNil(FailureAdvice.plain("something we have never seen"))
    }
}
