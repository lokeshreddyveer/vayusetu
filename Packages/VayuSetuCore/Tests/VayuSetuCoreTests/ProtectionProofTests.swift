import XCTest
@testable import VayuSetuCore

final class ProtectionProofTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func proof(_ build: (inout ProofObservations) -> Void) -> ProtectionProof { var o = ProofObservations(); build(&o); return ProtectionProofEngine.evaluate(o, now: now) }
    private func outcome(_ p: ProtectionProof, _ id: String) -> ProofCheck.Outcome? { p.checks.first { $0.id == id }?.outcome }

    func testNothingOn() {
        let p = proof { _ in }
        XCTAssertEqual(p.verdict, .off); XCTAssertTrue(p.checks.allSatisfy { $0.outcome == .notUsed })
    }
    func testVPNPassesOnlyWithAChangedFreshAddress() {
        let ok = proof { $0.vpnWanted = true; $0.vpnConnected = true; $0.publicAddress = "9.9.9.9"; $0.baselineAddress = "1.1.1.1"; $0.addressCheckedAt = now.addingTimeInterval(-10) }
        XCTAssertEqual(ok.verdict, .protected); XCTAssertEqual(outcome(ok, "vpn"), .passed)
        let same = proof { $0.vpnWanted = true; $0.vpnConnected = true; $0.publicAddress = "1.1.1.1"; $0.baselineAddress = "1.1.1.1"; $0.addressCheckedAt = now }
        XCTAssertEqual(same.verdict, .notProtected); XCTAssertEqual(outcome(same, "vpn"), .failed)
        let old = proof { $0.vpnWanted = true; $0.vpnConnected = true; $0.publicAddress = "9.9.9.9"; $0.baselineAddress = "1.1.1.1"; $0.addressCheckedAt = now.addingTimeInterval(-500) }
        XCTAssertEqual(outcome(old, "vpn"), .unverified); XCTAssertEqual(old.verdict, .partial)
        let noBaseline = proof { $0.vpnWanted = true; $0.vpnConnected = true; $0.publicAddress = "9.9.9.9" }
        XCTAssertEqual(outcome(noBaseline, "vpn"), .unverified)
        // A recent handshake is evidence even with no address to compare; an old one is not.
        XCTAssertEqual(outcome(proof { $0.vpnWanted = true; $0.vpnConnected = true; $0.handshakeAge = 40 }, "vpn"), .passed)
        XCTAssertEqual(outcome(proof { $0.vpnWanted = true; $0.vpnConnected = true; $0.handshakeAge = 40; $0.publicAddress = "1.1.1.1"; $0.baselineAddress = "1.1.1.1"; $0.addressCheckedAt = now }, "vpn"), .failed)
    }
    func testVPNDisconnectedOrStaleHandshakeFails() {
        XCTAssertEqual(outcome(proof { $0.vpnWanted = true; $0.vpnConnected = false }, "vpn"), .failed)
        XCTAssertEqual(outcome(proof { $0.vpnWanted = true }, "vpn"), .unverified)
        XCTAssertEqual(outcome(proof { $0.vpnWanted = true; $0.vpnConnected = true; $0.handshakeAge = 400; $0.publicAddress = "9.9.9.9"; $0.baselineAddress = "1.1.1.1"; $0.addressCheckedAt = now }, "vpn"), .failed)
    }
    func testDNSNeedsAnswerAndBlockedName() {
        let ok = proof { $0.dnsWanted = true; $0.dnsFilteringWanted = true; $0.dnsAnswered = true; $0.blockedNameBlocked = true; $0.dnsCheckedAt = now.addingTimeInterval(-5) }
        XCTAssertEqual(ok.verdict, .protected)
        let notBlocking = proof { $0.dnsWanted = true; $0.dnsFilteringWanted = true; $0.dnsAnswered = true; $0.blockedNameBlocked = false; $0.dnsCheckedAt = now }
        XCTAssertEqual(outcome(notBlocking, "dns"), .failed); XCTAssertTrue(notBlocking.checks[1].detail.contains("not active"))
        XCTAssertEqual(outcome(proof { $0.dnsWanted = true; $0.dnsFilteringWanted = true; $0.dnsAnswered = true; $0.dnsCheckedAt = now }, "dns"), .unverified)
        XCTAssertEqual(outcome(proof { $0.dnsWanted = true; $0.dnsAnswered = false; $0.dnsCheckedAt = now }, "dns"), .failed)
        XCTAssertEqual(outcome(proof { $0.dnsWanted = true }, "dns"), .unverified)
        // Without filtering there is nothing to block, so an answer is enough.
        XCTAssertEqual(outcome(proof { $0.dnsWanted = true; $0.dnsAnswered = true; $0.dnsCheckedAt = now }, "dns"), .passed)
        XCTAssertEqual(outcome(proof { $0.dnsWanted = true; $0.dnsAnswered = true; $0.dnsCheckedAt = now.addingTimeInterval(-900) }, "dns"), .unverified)
    }
    func testSafariAndFilter() {
        XCTAssertEqual(outcome(proof { $0.safariWanted = true; $0.safariRulesLoaded = true }, "safari"), .passed)
        XCTAssertEqual(outcome(proof { $0.safariWanted = true; $0.safariRulesLoaded = false }, "safari"), .failed)
        XCTAssertEqual(outcome(proof { $0.safariWanted = true }, "safari"), .unverified)
        XCTAssertEqual(outcome(proof { $0.filterWanted = true; $0.filterRunning = true }, "filter"), .passed)
        XCTAssertEqual(outcome(proof { $0.filterWanted = true; $0.filterRunning = false }, "filter"), .failed)
        XCTAssertNil(outcome(proof { _ in }, "filter"))
    }
    func testVerdictMixes() {
        let mixed = proof { $0.vpnWanted = true; $0.vpnConnected = true; $0.publicAddress = "9.9.9.9"; $0.baselineAddress = "1.1.1.1"; $0.addressCheckedAt = now
                            $0.dnsWanted = true; $0.dnsFilteringWanted = true; $0.dnsAnswered = true; $0.blockedNameBlocked = false; $0.dnsCheckedAt = now }
        XCTAssertEqual(mixed.verdict, .partial); XCTAssertTrue(mixed.headline.contains("Encrypted DNS"))
        let allBad = proof { $0.vpnWanted = true; $0.vpnConnected = false; $0.dnsWanted = true; $0.dnsAnswered = false; $0.dnsCheckedAt = now }
        XCTAssertEqual(allBad.verdict, .notProtected)
        // A claim is never made from nothing: wanted but unobserved is "partial", not "protected".
        XCTAssertEqual(proof { $0.vpnWanted = true; $0.dnsWanted = true }.verdict, .partial)
    }
}
