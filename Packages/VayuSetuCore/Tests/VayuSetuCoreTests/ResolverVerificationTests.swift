import XCTest
@testable import VayuSetuCore

final class ResolverVerificationTests: XCTestCase {
    func testVerifiedNeedsBothTheAcceptedSettingsAndWorkingResolution() {
        XCTAssertEqual(ExternalResolverVerdict.decide(accepted: true, resolved: true), .verified)
    }
    func testResolutionFailingWithAcceptedSettingsIsAFailure() {
        XCTAssertEqual(ExternalResolverVerdict.decide(accepted: true, resolved: false), .failed)
    }
    func testUnconfirmedSettingsAreUnavailableNotAFailure() {
        XCTAssertEqual(ExternalResolverVerdict.decide(accepted: false, resolved: true), .unavailable)
        XCTAssertEqual(ExternalResolverVerdict.decide(accepted: nil, resolved: true), .unavailable)
        XCTAssertEqual(ExternalResolverVerdict.decide(accepted: false, resolved: false), .unavailable, "cannot blame a resolver the system did not apply")
    }
    func testNothingRunYetIsNotChecked() {
        XCTAssertEqual(ExternalResolverVerdict.decide(accepted: true, resolved: nil), .notChecked)
    }
    func testEachOutcomeHasItsOwnWords() {
        let all: [ExternalResolverVerdict] = [.verified, .failed, .unavailable, .notChecked]
        XCTAssertEqual(Set(all.map(\.detail)).count, 4)
        XCTAssertTrue(ExternalResolverVerdict.verified.detail.contains("Filtering is the resolver's own"), "it does not imply VayuSetu's lists are applied")
    }
}
