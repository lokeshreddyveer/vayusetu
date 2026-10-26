import XCTest
@testable import VayuSetuCore

/// Validation tests for build 54's monitoring rules, written against the claims made for them.
final class NetworkValidationTests: XCTestCase {
    // MARK: Baselines
    private func learned(_ ms: Double, rounds: Int = 120) -> NetworkBaseline {
        var b: NetworkBaseline?
        for _ in 0..<rounds { b = Baselines.update(b, median: ms) }
        return b!
    }

    func testAnHourOfSustainedSlownessDoesNotBecomeTheNewNormal() {
        // One update is made about every three minutes, so an hour is 20 updates.
        var b = learned(5)
        for _ in 0..<20 { b = Baselines.update(b, median: 200) }
        XCTAssertLessThan(b.medianMs, 10, "a slow hour must not drag the usual latency up to \(Int(b.medianMs)) ms")
        XCTAssertNotNil(Baselines.remark(known: b, nowMs: 200), "and the slowness is still reported as unusual")
    }

    func testARealChangeIsAcceptedAfterLongEnough() {
        var b = learned(5)
        for _ in 0..<(Baselines.acceptAfterOutliers + 20) { b = Baselines.update(b, median: 120) }
        XCTAssertGreaterThan(b.medianMs, 60, "after about 15 hours the new level is accepted, so a replaced router is not 'slow' forever")
        XCTAssertEqual(b.outlierStreak >= 0, true)
    }

    func testOneNormalReadingEndsAnOutlierRun() {
        var b = learned(5)
        for _ in 0..<10 { b = Baselines.update(b, median: 200) }
        XCTAssertEqual(b.outlierStreak, 10)
        b = Baselines.update(b, median: 6)
        XCTAssertEqual(b.outlierStreak, 0)
    }

    func testEarlyLearningIsAnAverageAndLaterLearningIsSlow() {
        var b = Baselines.update(nil, median: 10)
        b = Baselines.update(b, median: 20)
        XCTAssertEqual(b.medianMs, 15, accuracy: 0.01, "the second reading counts as much as the first while little is known")
        let settled = learned(10, rounds: 200)
        let after = Baselines.update(settled, median: 20)
        XCTAssertLessThan(after.medianMs - settled.medianMs, 0.5, "once settled, a single reading moves it by about 2%")
    }

    func testOldBaselinesStillDecode() throws {
        let old = #"{"medianMs":6.5,"samples":90}"#
        let b = try JSONDecoder().decode(NetworkBaseline.self, from: Data(old.utf8))
        XCTAssertEqual(b.medianMs, 6.5); XCTAssertEqual(b.outlierStreak, 0)
    }

    // MARK: Network identity
    func testTwoNetworksWithTheSameRouterAddressDoNotShareAHistory() {
        let home = NetworkIdentity.key(primary: "Wi-Fi", ssid: "Home", gatewayIP: "192.168.1.1", gatewayMAC: "aa:aa:aa:aa:aa:aa")
        let cafe = NetworkIdentity.key(primary: "Wi-Fi", ssid: "Cafe", gatewayIP: "192.168.1.1", gatewayMAC: "bb:bb:bb:bb:bb:bb")
        XCTAssertNotNil(home); XCTAssertNotEqual(home, cafe, "both routers are 192.168.1.1, but they are different networks")
        let sameSSIDOtherRouter = NetworkIdentity.key(primary: "Wi-Fi", ssid: "Home", gatewayIP: "192.168.1.1", gatewayMAC: "cc:cc:cc:cc:cc:cc")
        XCTAssertNotEqual(home, sameSSIDOtherRouter, "a hidden name (no Location permission) must not merge networks: the router's hardware address tells them apart")
        XCTAssertEqual(home, NetworkIdentity.key(primary: "Wi-Fi", ssid: "Home", gatewayIP: "192.168.1.1", gatewayMAC: "aa:aa:aa:aa:aa:aa"))
        XCTAssertNil(NetworkIdentity.key(primary: "Wi-Fi", ssid: "Home", gatewayIP: "192.168.1.1", gatewayMAC: nil), "no history is kept until the router is identified")
        XCTAssertFalse(home!.contains("Home") || home!.contains("192.168"), "the stored key must not hold the name or an address in the clear")
    }

    // MARK: Router identity and ARP
    func testALegitimateRouterWithManyAddressesIsNotFlaggedButAnotherDeviceIs() {
        let entries = [ARPEntry(ip: "192.168.1.1", mac: "aa:aa:aa:aa:aa:aa"), ARPEntry(ip: "192.168.1.2", mac: "aa:aa:aa:aa:aa:aa"),
                       ARPEntry(ip: "192.168.1.60", mac: "dd:dd:dd:dd:dd:dd"), ARPEntry(ip: "192.168.1.61", mac: "dd:dd:dd:dd:dd:dd")]
        let flagged = ARPParser.duplicates(entries, gateway: "192.168.1.1")
        XCTAssertEqual(flagged.count, 1)
        XCTAssertTrue(flagged[0].contains("dd:dd"))
    }

    func testIncompleteEntriesNeverCountAsTheRouter() {
        let entries = ARPParser.parse("? (192.168.1.1) at (incomplete) on en0 ifscope [ethernet]")
        XCTAssertTrue(entries.isEmpty, "an unanswered entry has no hardware address to compare")
    }

    func testARouterThatChangesOnlyCountsWithinOneSession() {
        var session: [String: String] = [:]
        XCTAssertFalse(GatewayIdentity.compare(known: session, key: "n", mac: "aa").changed)
        session["n"] = "aa"
        XCTAssertTrue(GatewayIdentity.compare(known: session, key: "n", mac: "bb").changed)
        session.removeAll()                                                    // the monitor does this when the connection or network changes
        XCTAssertFalse(GatewayIdentity.compare(known: session, key: "n", mac: "bb").changed, "after moving to another network the old router is forgotten")
    }

    // MARK: Sampling transitions
    func testSamplingThroughARealisticDay() {
        typealias C = SamplingPolicy.Conditions
        let steps: [(String, C, Bool, Double)] = [
            ("AC power, window open", C(), false, 3),
            ("AC power, steady for ten minutes", C(stable: true), false, 6),
            ("on battery, window open", C(onBattery: true), false, 3),
            ("on battery, window hidden", C(onBattery: true, windowInBackground: true), false, 10),
            ("battery, hidden, steady", C(onBattery: true, windowInBackground: true, stable: true), false, 20),
            ("Low Power Mode", C(lowPower: true), false, 15),
            ("Low Power Mode, steady", C(lowPower: true, stable: true), false, 30),
            ("phone hotspot", C(expensive: true), false, 12),
            ("hotspot, steady, on battery, hidden", C(expensive: true, onBattery: true, windowInBackground: true, stable: true), false, 24),
            ("a stall is suspected on a hotspot in Low Power Mode", C(expensive: true, lowPower: true), true, 3),
            ("a stall is suspected while everything is slowed", C(expensive: true, lowPower: true, onBattery: true, windowInBackground: true, stable: true), true, 3),
        ]
        for (name, conditions, suspicious, expected) in steps {
            XCTAssertEqual(SamplingPolicy.interval(conditions, suspicious: suspicious), expected, name)
        }
    }

    // MARK: Quality report
    func testTheReportNamesTheObservationPeriod() {
        var a = DayQuality(day: 20_000), b = DayQuality(day: 20_003)
        for _ in 0..<60 { a.add(ProbeRound(date: Date(), gatewayMs: 5, gatewayAnswered: true), hour: 9); b.add(ProbeRound(date: Date(), gatewayMs: 5, gatewayAnswered: true), hour: 9) }
        let s = QualityReport.summarise([a, b])
        XCTAssertEqual(s.firstDay, 20_000); XCTAssertEqual(s.lastDay, 20_003)
        let text = QualityReport.text(s, speeds: [], dayName: { "D\($0)" })
        XCTAssertTrue(text.contains("D20000"), "the first day of the period is stated"); XCTAssertTrue(text.contains("D20003"), "and the last")
        XCTAssertTrue(text.contains("2 days with monitoring"), "and how many of those days actually had monitoring")
    }

    func testTheReportOmitsDaysThatHadAlmostNoData() {
        var thin = DayQuality(day: 1); thin.add(ProbeRound(date: Date(), gatewayMs: 5, gatewayAnswered: true))
        XCTAssertEqual(QualityReport.summarise([thin]).days, 0, "a day with a few seconds of data is not a day of observation")
    }
}
