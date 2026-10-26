import XCTest
@testable import VayuSetuCore

final class ProtectionRequestTests: XCTestCase {
    private let off = ProtectionTarget(adblock: true)
    private let dnsOnly = ProtectionTarget(dns: true, adblock: true)

    func testASwitchSetsItsValueAndNeverInvertsWhatIsRunning() {
        XCTAssertEqual(ProtectionRequestPolicy.setting(.dns, to: true, from: off), dnsOnly)
        XCTAssertEqual(ProtectionRequestPolicy.setting(.dns, to: true, from: dnsOnly), dnsOnly, "asking for what is already so is not a flip")
        XCTAssertEqual(ProtectionRequestPolicy.setting(.dns, to: false, from: off), off)
    }

    func testARepeatedOrReplayedCallbackChangesNothingAfterTheFirst() {
        var observed = off
        var applied = 0
        for _ in 0..<5 {   // SwiftUI may call a binding's setter again while a state settles
            let requested = ProtectionRequestPolicy.setting(.dns, to: true, from: observed)
            if !ProtectionRequestPolicy.isNoChange(requested, from: observed) { applied += 1; observed = requested }
        }
        XCTAssertEqual(applied, 1)
        XCTAssertEqual(observed, dnsOnly)
    }

    func testAMenuInteractionLeavesTheOtherControlsAlone() {
        let all = ProtectionTarget(vpn: true, dns: true, adblock: true)
        let next = ProtectionRequestPolicy.setting(.vpn, to: false, from: all)
        XCTAssertEqual(next, ProtectionTarget(vpn: false, dns: true, adblock: true))
        XCTAssertEqual(ProtectionRequestPolicy.differences(next, from: all), ["VPN off"])
    }

    func testLinksAreExplicitExceptToggle() {
        XCTAssertEqual(ProtectionRequestPolicy.linkValue("on", control: .dns, observed: dnsOnly), true)
        XCTAssertEqual(ProtectionRequestPolicy.linkValue("off", control: .dns, observed: off), false, "off while already off is still a clear request for off")
        XCTAssertEqual(ProtectionRequestPolicy.linkValue("toggle", control: .dns, observed: dnsOnly), false)
        XCTAssertEqual(ProtectionRequestPolicy.linkValue("toggle", control: .vpn, observed: dnsOnly), true)
        XCTAssertNil(ProtectionRequestPolicy.linkValue("maybe", control: .vpn, observed: off))
    }

    func testAppActivationAndWakeAskForNothing() {
        // Becoming active, waking or a path change are not requests: the planner is only given what a control asked for.
        let observed = dnsOnly
        XCTAssertTrue(ProtectionRequestPolicy.isNoChange(observed, from: observed))
        XCTAssertEqual(ProtectionRequestPolicy.differences(observed, from: observed), [])
    }

    func testEveryRequestIsLoggedWithItsInitiator() {
        let line = ProtectionRequestPolicy.logLine(source: "menu", requested: dnsOnly, observed: off)
        XCTAssertEqual(line, "Protection requested by menu: DNS on")
        XCTAssertEqual(ProtectionRequestPolicy.logLine(source: "Wi-Fi rule", requested: off, observed: off), "Protection requested by Wi-Fi rule: no change")
    }
}
