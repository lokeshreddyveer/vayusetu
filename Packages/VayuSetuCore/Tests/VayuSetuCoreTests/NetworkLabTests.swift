import XCTest
@testable import VayuSetuCore

final class NetworkLabTests: XCTestCase {
    func testCaptivePortalVerdicts() {
        XCTAssertEqual(CaptivePortal.classify(status: 200, body: "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>", redirected: false, failed: false), .open)
        XCTAssertEqual(CaptivePortal.classify(status: 200, body: "<html>Please sign in</html>", redirected: false, failed: false), .portal)
        XCTAssertEqual(CaptivePortal.classify(status: 302, body: nil, redirected: false, failed: false), .portal)
        XCTAssertEqual(CaptivePortal.classify(status: 200, body: "Success", redirected: true, failed: false), .portal)
        XCTAssertEqual(CaptivePortal.classify(status: nil, body: nil, redirected: false, failed: true), .offline)
        XCTAssertEqual(CaptivePortal.classify(status: 503, body: nil, redirected: false, failed: false), .unknown)
    }

    func testTracerouteParsingKeepsSilentHopsAndFindsTheJump() {
        let output = """
        traceroute to 1.1.1.1 (1.1.1.1), 20 hops max, 40 byte packets
         1  192.168.1.1  3.412 ms
         2  *
         3  10.20.0.1  9.8 ms
         4  72.14.1.1  11.0 ms
         5  1.1.1.1  145.2 ms
        """
        let hops = TracerouteParser.parse(output)
        XCTAssertEqual(hops.map(\.index), [1, 2, 3, 4, 5])
        XCTAssertEqual(hops[0].host, "192.168.1.1"); XCTAssertEqual(hops[0].ms ?? 0, 3.412, accuracy: 0.001)
        XCTAssertNil(hops[1].host); XCTAssertNil(hops[1].ms, "a silent hop is kept, not dropped")
        XCTAssertEqual(TracerouteParser.jump(in: hops)?.index, 5, "the jump from 11 ms to 145 ms is at hop 5")
        XCTAssertNil(TracerouteParser.jump(in: Array(hops.prefix(4))), "no jump on the early hops")
    }

    func testPathMTUBisection() {
        XCTAssertEqual(PathMTU.search { $0 <= 1472 }, 1500)
        XCTAssertEqual(PathMTU.search { $0 <= 1392 }, 1420, "behind a tunnel")
        XCTAssertEqual(PathMTU.search { $0 <= 1200 }, 1228)
        XCTAssertNil(PathMTU.search { _ in false }, "when even the smallest packet fails the path cannot be tested")
        XCTAssertTrue(PathMTU.comment(1500).hasPrefix("Normal"))
        XCTAssertTrue(PathMTU.comment(1280).hasPrefix("Low"))
    }

    func testBufferbloatGrades() {
        XCTAssertEqual(Bufferbloat.grade(idleMs: 10, loadedMs: 12).grade, "A+")
        XCTAssertEqual(Bufferbloat.grade(idleMs: 10, loadedMs: 30).grade, "A")
        XCTAssertEqual(Bufferbloat.grade(idleMs: 10, loadedMs: 60).grade, "B")
        XCTAssertEqual(Bufferbloat.grade(idleMs: 10, loadedMs: 150).grade, "C")
        XCTAssertEqual(Bufferbloat.grade(idleMs: 10, loadedMs: 450).grade, "F")
        XCTAssertEqual(Bufferbloat.grade(idleMs: 50, loadedMs: 20).addedMs, 0, "faster under load is not negative delay")
    }

    func testChannelCongestionOverlapsOn24GHzButNotOn5() {
        let around = [NearbyNetwork(channel: 6, band: .ghz2, rssi: -50), NearbyNetwork(channel: 7, band: .ghz2, rssi: -55), NearbyNetwork(channel: 1, band: .ghz2, rssi: -80)]
        XCTAssertGreaterThan(ChannelAdvisor.congestion(channel: 6, band: .ghz2, networks: around), ChannelAdvisor.congestion(channel: 11, band: .ghz2, networks: around))
        XCTAssertGreaterThan(ChannelAdvisor.congestion(channel: 8, band: .ghz2, networks: around), 0, "channels within four numbers overlap")
        let five = [NearbyNetwork(channel: 36, band: .ghz5, rssi: -50)]
        XCTAssertGreaterThan(ChannelAdvisor.congestion(channel: 36, band: .ghz5, networks: five), 0)
        XCTAssertEqual(ChannelAdvisor.congestion(channel: 40, band: .ghz5, networks: five), 0, "5 GHz channels do not overlap")
    }

    func testChannelAdviceNamesABetterChannelOnlyWhenClearlyBetter() {
        let crowded = (0..<4).map { _ in NearbyNetwork(channel: 6, band: .ghz2, rssi: -50) }
        let advice = ChannelAdvisor.advice(ownChannel: 6, ownBand: .ghz2, ownWidthMHz: 40, networks: crowded).joined(separator: " ")
        XCTAssertTrue(advice.contains("crowded")); XCTAssertTrue(advice.contains("20 MHz"))
        let quiet = ChannelAdvisor.advice(ownChannel: 11, ownBand: .ghz5, ownWidthMHz: 80, networks: [NearbyNetwork(channel: 36, band: .ghz5, rssi: -70)]).joined(separator: " ")
        XCTAssertTrue(quiet.contains("not crowded"))
        XCTAssertEqual(ChannelAdvisor.advice(ownChannel: nil, ownBand: .unknown, ownWidthMHz: nil, networks: []).count, 1)
    }

    func testDNSFindings() {
        XCTAssertEqual(NetworkAdvisor.dnsFinding(resolvers: ["198.18.0.2"], vayuDNSOn: true, vpnOn: false).severity, .ok)
        XCTAssertEqual(NetworkAdvisor.dnsFinding(resolvers: ["198.18.0.2", "192.168.1.1"], vayuDNSOn: true, vpnOn: false).severity, .attention, "another resolver beside VayuSetu's is a leak risk")
        XCTAssertEqual(NetworkAdvisor.dnsFinding(resolvers: ["192.168.1.1"], vayuDNSOn: false, vpnOn: false).severity, .info)
        XCTAssertTrue(NetworkAdvisor.dnsFinding(resolvers: ["192.168.1.1"], vayuDNSOn: false, vpnOn: true).detail.contains("outside the tunnel"))
        XCTAssertEqual(NetworkAdvisor.dnsFinding(resolvers: [], vayuDNSOn: false, vpnOn: false).severity, .info)
        XCTAssertTrue(NetworkAdvisor.isPrivate("172.20.1.1")); XCTAssertFalse(NetworkAdvisor.isPrivate("172.32.1.1")); XCTAssertFalse(NetworkAdvisor.isPrivate("1.1.1.1"))
    }

    func testSecurityFindings() {
        let weak = NetworkAdvisor.securityFindings(wifiSecurity: "Open (no password)", associated: true, proxies: [], gatewayChanged: false, portal: nil)
        XCTAssertEqual(weak.first?.severity, .attention)
        let fine = NetworkAdvisor.securityFindings(wifiSecurity: "WPA3 Personal", associated: true, proxies: ["HTTPS proxy.corp:8080"], gatewayChanged: true, portal: .portal)
        XCTAssertEqual(fine.map(\.id), ["wifi", "proxy", "gateway", "portal"])
        XCTAssertEqual(fine.first?.severity, .ok)
        XCTAssertTrue(NetworkAdvisor.securityFindings(wifiSecurity: nil, associated: false, proxies: [], gatewayChanged: false, portal: .open).isEmpty)
    }
}
