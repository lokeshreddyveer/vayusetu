import XCTest
@testable import VayuSetuCore

final class OpenNetworkPromptTests: XCTestCase {
    func testOnlyARuleForThisExactNetworkActsByItself() {
        var set = NetworkRuleSet(enabled: true, rules: [WiFiRule(ssid: "Home", action: .off)], otherNetworks: .dnsOnly, openNetworks: .vpnWithDNS)
        let home = NetworkRulePlanner.decide(ssid: "home", open: false, rules: set, current: .vpnWithDNS)
        XCTAssertEqual(home?.action, .off); XCTAssertEqual(home?.automatic, true)
        let cafe = NetworkRulePlanner.decide(ssid: "Cafe", open: true, rules: set, current: .off)
        XCTAssertEqual(cafe?.action, .vpnWithDNS); XCTAssertEqual(cafe?.automatic, false, "a general open-network rule is a suggestion")
        let other = NetworkRulePlanner.decide(ssid: "Office", open: false, rules: set, current: .off)
        XCTAssertEqual(other?.action, .dnsOnly); XCTAssertEqual(other?.automatic, false)
        set.enabled = false
        XCTAssertNil(NetworkRulePlanner.decide(ssid: "Home", open: false, rules: set, current: .vpnWithDNS), "rules that are switched off do nothing")
    }

    func testAnEmptyRuleListAuthorizesNothing() {
        let empty = NetworkRuleSet(enabled: true)
        XCTAssertNil(NetworkRulePlanner.decide(ssid: "Cafe", open: true, rules: empty, current: .off))
        XCTAssertNil(NetworkRulePlanner.decide(ssid: nil, open: nil, rules: NetworkRuleSet(enabled: true, otherNetworks: .vpnWithDNS), current: .off), "an unreadable name is not a network")
    }

    func testOpenWifiWithNothingOnEarnsAQuestionNotAnAction() {
        let s = OpenNetworkPrompt.suggestion(ssid: "Airport Free WiFi", open: true, current: .off, enabled: true, ignored: [], dismissedNow: nil)
        XCTAssertEqual(s?.action, .vpnWithDNS)
        XCTAssertTrue(s!.message.hasSuffix("?"))
    }

    func testNoQuestionWhenAlreadyProtectedClosedOrSwitchedOff() {
        XCTAssertNil(OpenNetworkPrompt.suggestion(ssid: "X", open: true, current: .dnsOnly, enabled: true, ignored: [], dismissedNow: nil))
        XCTAssertNil(OpenNetworkPrompt.suggestion(ssid: "X", open: false, current: .off, enabled: true, ignored: [], dismissedNow: nil))
        XCTAssertNil(OpenNetworkPrompt.suggestion(ssid: "X", open: nil, current: .off, enabled: true, ignored: [], dismissedNow: nil), "unknown security is not open")
        XCTAssertNil(OpenNetworkPrompt.suggestion(ssid: "X", open: true, current: .off, enabled: false, ignored: [], dismissedNow: nil))
        XCTAssertNil(OpenNetworkPrompt.suggestion(ssid: "X", open: true, current: nil, enabled: true, ignored: [], dismissedNow: nil), "what is running is not known yet")
        XCTAssertNil(OpenNetworkPrompt.suggestion(ssid: " ", open: true, current: .off, enabled: true, ignored: [], dismissedNow: nil))
    }

    func testNotNowAndDontAskAgainAreRemembered() {
        XCTAssertNil(OpenNetworkPrompt.suggestion(ssid: "Cafe", open: true, current: .off, enabled: true, ignored: [], dismissedNow: "cafe"))
        XCTAssertNil(OpenNetworkPrompt.suggestion(ssid: "Cafe", open: true, current: .off, enabled: true, ignored: ["CAFE"], dismissedNow: nil))
        XCTAssertNotNil(OpenNetworkPrompt.suggestion(ssid: "Cafe 2", open: true, current: .off, enabled: true, ignored: ["Cafe"], dismissedNow: "Cafe"))
    }
}
