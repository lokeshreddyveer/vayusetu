import XCTest
@testable import VayuSetuCore

final class NetworkInventoryTests: XCTestCase {
    func testInterfaceClassification() {
        XCTAssertEqual(InterfaceKind.classify(bsdName: "en0", systemType: "IEEE80211", displayName: "Wi-Fi"), .wifi)
        XCTAssertEqual(InterfaceKind.classify(bsdName: "en5", systemType: "Ethernet", displayName: "USB 10/100/1000 LAN"), .usb)
        XCTAssertEqual(InterfaceKind.classify(bsdName: "en6", systemType: "Ethernet", displayName: "Thunderbolt Ethernet Slot 1"), .thunderbolt)
        XCTAssertEqual(InterfaceKind.classify(bsdName: "en7", systemType: "Ethernet", displayName: "Ethernet Adapter"), .ethernet)
        XCTAssertEqual(InterfaceKind.classify(bsdName: "utun4", systemType: nil, displayName: nil), .tunnel)
        XCTAssertEqual(InterfaceKind.classify(bsdName: "bridge0", systemType: "Bridge", displayName: "Thunderbolt Bridge"), .bridge)
        XCTAssertEqual(InterfaceKind.classify(bsdName: "lo0", systemType: nil, displayName: nil), .loopback)
        XCTAssertEqual(InterfaceKind.classify(bsdName: "awdl0", systemType: nil, displayName: nil), .virtual)
        XCTAssertEqual(InterfaceKind.classify(bsdName: "pdp_ip0", systemType: "WWAN", displayName: "iPhone USB"), .cellular)
    }

    func testWorthShowingHidesLoopbackAndVirtualButKeepsRealLinks() {
        func info(_ kind: InterfaceKind, up: Bool = true, running: Bool = true, addr: [String] = ["192.168.1.5"]) -> InterfaceInfo {
            InterfaceInfo(name: "x", kind: kind, display: "x", up: up, running: running, speedMbps: nil, mtu: 1500, addresses: addr, rxBytes: 0, txBytes: 0)
        }
        XCTAssertFalse(info(.loopback).worthShowing); XCTAssertFalse(info(.virtual).worthShowing)
        XCTAssertTrue(info(.wifi).worthShowing); XCTAssertTrue(info(.tunnel).worthShowing)
        XCTAssertTrue(info(.ethernet, running: false, addr: []).worthShowing, "a real link that is up is shown even with no address yet")
        XCTAssertFalse(info(.tunnel, up: false, running: false).worthShowing)
        XCTAssertFalse(info(.wifi, addr: ["fe80::1"]).active, "link-local only is not carrying traffic")
        XCTAssertEqual(ByteFormat.text(1_500_000_000), "1.5 GB"); XCTAssertEqual(ByteFormat.text(900), "900 B")
    }

    func testDHCPParsing() {
        let output = """
        op = BOOTREPLY
        yiaddr = 192.168.1.23
        subnet_mask (ip): 255.255.255.0
        router (ip_mult): {192.168.1.1}
        domain_name_server (ip_mult): {192.168.1.1, 1.1.1.1}
        server_identifier (ip): 192.168.1.1
        lease_time (uint32): 0x15180
        """
        let info = DHCPParser.parse(output)
        XCTAssertEqual(info.subnetMask, "255.255.255.0"); XCTAssertEqual(info.server, "192.168.1.1")
        XCTAssertEqual(info.leaseSeconds, 86400); XCTAssertEqual(info.leaseText, "1 day")
        XCTAssertEqual(info.routers, ["192.168.1.1"]); XCTAssertEqual(info.dns, ["192.168.1.1", "1.1.1.1"])
        XCTAssertNil(DHCPParser.parse("nothing useful").subnetMask)
    }

    func testDailyQualityCountsLossAndEstimatesTheMedian() {
        var days: [DayQuality] = []
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<20 { QualityHistory.record(ProbeRound(date: t, gatewayMs: 4, gatewayAnswered: true, internetMs: 20, internetAnswered: true), into: &days, today: 100 + (i < 0 ? 1 : 0)) }
        for _ in 0..<5 { QualityHistory.record(ProbeRound(date: t, gatewayMs: nil, gatewayAnswered: false, internetMs: nil, internetAnswered: false), into: &days, today: 100) }
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days[0].rounds, 25); XCTAssertEqual(days[0].gatewayLost, 5)
        XCTAssertEqual(days[0].uptime ?? 0, 0.8, accuracy: 0.001)
        XCTAssertEqual(days[0].medianMs ?? 0, 2.5, accuracy: 0.001, "the middle reading sits in the 0 to 5 ms bucket")
        QualityHistory.recordStall(seconds: 40, into: &days, today: 100)
        XCTAssertEqual(days[0].stalls, 1); XCTAssertEqual(days[0].stallSeconds, 40)
    }

    func testQualityRollsOverDaysAndForgetsOldOnes() {
        var days: [DayQuality] = []
        let r = ProbeRound(date: Date(), gatewayMs: 5, gatewayAnswered: true)
        QualityHistory.record(r, into: &days, today: 10)
        QualityHistory.record(r, into: &days, today: 11)
        XCTAssertEqual(days.map(\.day), [10, 11])
        QualityHistory.record(r, into: &days, today: 10 + QualityHistory.keepDays + 1)
        XCTAssertEqual(days.map(\.day), [11, 41].filter { $0 > 41 - QualityHistory.keepDays }, "day 10 is older than the window and is dropped")
        XCTAssertNil(DayQuality(day: 1).uptime, "no data is not 100%")
        XCTAssertNil(DayQuality(day: 1).medianMs)
    }

    func testLeakCheck() {
        XCTAssertEqual(LeakCheck.assess(vpnOn: false, publicIP: "1.2.3.4", baselineIP: nil, ipv6WorksDirectly: nil).first?.severity, .info)
        XCTAssertEqual(LeakCheck.assess(vpnOn: true, publicIP: "1.2.3.4", baselineIP: "1.2.3.4", ipv6WorksDirectly: nil).first?.severity, .attention)
        XCTAssertEqual(LeakCheck.assess(vpnOn: true, publicIP: "9.9.9.9", baselineIP: "1.2.3.4", ipv6WorksDirectly: nil).first?.severity, .ok)
        XCTAssertEqual(LeakCheck.assess(vpnOn: true, publicIP: "9.9.9.9", baselineIP: nil, ipv6WorksDirectly: nil).first?.title, "No address to compare with")
        XCTAssertTrue(LeakCheck.assess(vpnOn: true, publicIP: nil, baselineIP: nil, ipv6WorksDirectly: true).contains { $0.id == "ipv6" })
    }

    func testNewCausesRankBelowCertainOnesAndAreCappedWithFewRounds() {
        var e = IncidentEvidence(); e.roundsDuring = 5; e.vpnChangedAround = true; e.gatewayFailedDuring = true
        XCTAssertEqual(IncidentClassifier.diagnose(e).cause, .vpnChange)
        e = IncidentEvidence(); e.roundsDuring = 5; e.pathChangedAround = true; e.gatewayFailedDuring = true
        XCTAssertEqual(IncidentClassifier.diagnose(e).cause, .networkSwitch)
        e = IncidentEvidence(); e.roundsDuring = 5; e.associatedDuring = false; e.vpnChangedAround = true
        XCTAssertEqual(IncidentClassifier.diagnose(e).cause, .wifiDisconnected, "a lost association outranks a VPN change")
        e = IncidentEvidence(); e.roundsDuring = 1; e.vpnChangedAround = true
        XCTAssertEqual(IncidentClassifier.diagnose(e).confidence, .low)
    }
}
