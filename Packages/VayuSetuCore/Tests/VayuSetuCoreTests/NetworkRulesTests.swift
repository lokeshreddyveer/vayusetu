import XCTest
@testable import VayuSetuCore

final class NetworkRulesTests: XCTestCase {
    private func set(_ rules: [WiFiRule] = [], other: NetworkAction? = nil, open: NetworkAction? = nil, enabled: Bool = true) -> NetworkRuleSet {
        NetworkRuleSet(enabled: enabled, rules: rules, otherNetworks: other, openNetworks: open)
    }
    func testDisabledOrUnknownNetworkDoesNothing() {
        XCTAssertNil(NetworkRulePlanner.decide(ssid: "Home", open: false, rules: set([WiFiRule(ssid: "Home", action: .off)], enabled: false), current: .vpnWithDNS))
        XCTAssertNil(NetworkRulePlanner.decide(ssid: nil, open: nil, rules: set([WiFiRule(ssid: "Home", action: .off)]), current: .vpnWithDNS))
        XCTAssertNil(NetworkRulePlanner.decide(ssid: "  ", open: nil, rules: set([WiFiRule(ssid: "Home", action: .off)]), current: .off))
        XCTAssertNil(NetworkRulePlanner.decide(ssid: "Cafe", open: false, rules: set([WiFiRule(ssid: "Home", action: .off)]), current: .off))
    }
    func testExactRuleIgnoringCaseAndNoChangeWhenAlreadyInForce() {
        let rules = set([WiFiRule(ssid: "Home Wi-Fi", action: .dnsOnly)])
        XCTAssertEqual(NetworkRulePlanner.decide(ssid: "home wi-fi", open: false, rules: rules, current: .vpnWithDNS)?.action, .dnsOnly)
        XCTAssertNil(NetworkRulePlanner.decide(ssid: "Home Wi-Fi", open: false, rules: rules, current: .dnsOnly))
    }
    func testOrderOfPrecedence() {
        let rules = set([WiFiRule(ssid: "Cafe", action: .off)], other: .dnsOnly, open: .vpnWithDNS)
        // an exact rule beats the open-network rule, which beats "other networks"
        XCTAssertEqual(NetworkRulePlanner.decide(ssid: "Cafe", open: true, rules: rules, current: .vpnOnly)?.action, .off)
        XCTAssertEqual(NetworkRulePlanner.decide(ssid: "Airport", open: true, rules: rules, current: .off)?.action, .vpnWithDNS)
        XCTAssertEqual(NetworkRulePlanner.decide(ssid: "Office", open: false, rules: rules, current: .off)?.action, .dnsOnly)
        // open-network status unknown behaves like a network with a password
        XCTAssertEqual(NetworkRulePlanner.decide(ssid: "Airport", open: nil, rules: rules, current: .off)?.action, .dnsOnly)
    }
    func testReasonNamesTheNetworkAndTheAction() {
        let reason = NetworkRulePlanner.decide(ssid: "Airport", open: true, rules: set(open: .vpnWithDNS), current: .off)?.reason ?? ""
        XCTAssertTrue(reason.contains("Airport") && reason.contains("VPN + DNS") && reason.contains("open"))
    }
    func testNormalizedCleansAndLimits() {
        let cleaned = NetworkRulePlanner.normalized([WiFiRule(ssid: " Home ", action: .dnsOnly), WiFiRule(ssid: "home", action: .off), WiFiRule(ssid: "", action: .off), WiFiRule(ssid: String(repeating: "x", count: 40), action: .off)].map { $0 })
        XCTAssertEqual(cleaned.map(\.ssid), ["Home"])
        let many = (0..<80).map { WiFiRule(ssid: "n\($0)", action: .off) }
        XCTAssertEqual(NetworkRulePlanner.normalized(many).count, NetworkRuleSet.maximumRules)
    }
    func testActionFlagsAndCurrent() {
        XCTAssertTrue(NetworkAction.vpnWithDNS.vpn && NetworkAction.vpnWithDNS.dns && !NetworkAction.off.vpn && !NetworkAction.dnsOnly.vpn && NetworkAction.dnsOnly.dns)
        XCTAssertEqual(NetworkRulePlanner.current(vpn: true, dns: false), .vpnOnly)
        XCTAssertEqual(NetworkRulePlanner.current(vpn: false, dns: false), .off)
    }
    func testRoundTrip() throws {
        let value = set([WiFiRule(ssid: "Home", action: .dnsOnly)], other: .vpnWithDNS, open: .vpnOnly)
        XCTAssertEqual(try JSONDecoder().decode(NetworkRuleSet.self, from: JSONEncoder().encode(value)), value)
    }
}
