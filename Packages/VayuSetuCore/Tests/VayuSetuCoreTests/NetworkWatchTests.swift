import XCTest
@testable import VayuSetuCore

final class NetworkWatchTests: XCTestCase {
    func testSamplingOnlyGetsSlowerAndReturnsToFastDuringASuspectedStall() {
        XCTAssertEqual(SamplingPolicy.interval(.init(), suspicious: false), 3)
        XCTAssertEqual(SamplingPolicy.interval(.init(expensive: true), suspicious: false), 12)
        XCTAssertEqual(SamplingPolicy.interval(.init(lowPower: true), suspicious: false), 15)
        XCTAssertEqual(SamplingPolicy.interval(.init(onBattery: true, windowInBackground: true), suspicious: false), 10)
        XCTAssertEqual(SamplingPolicy.interval(.init(onBattery: true), suspicious: false), 3, "on battery with the window in front stays quick")
        XCTAssertEqual(SamplingPolicy.interval(.init(stable: true), suspicious: false), 6)
        XCTAssertEqual(SamplingPolicy.interval(.init(lowPower: true, stable: true), suspicious: false), 30)
        XCTAssertLessThanOrEqual(SamplingPolicy.interval(.init(expensive: true, lowPower: true, onBattery: true, windowInBackground: true, stable: true), suspicious: false), SamplingPolicy.slowest)
        XCTAssertEqual(SamplingPolicy.interval(.init(expensive: true, lowPower: true, stable: true), suspicious: true), 3, "an incident is always captured at full rate")
    }

    func testARPParsingNormalisesAndSkipsIncompleteEntries() {
        let output = """
        ? (192.168.1.1) at a4:2b:b0:1:2:3 on en0 ifscope [ethernet]
        ? (192.168.1.20) at (incomplete) on en0 ifscope [ethernet]
        ? (192.168.1.30) at A4:2B:B0:1:2:3 on en0 ifscope [ethernet]
        ? (192.168.1.40) at 8:0:27:aa:bb:cc on en0 ifscope [ethernet]
        """
        let entries = ARPParser.parse(output)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0], ARPEntry(ip: "192.168.1.1", mac: "a4:2b:b0:01:02:03"))
        XCTAssertEqual(entries[2].mac, "08:00:27:aa:bb:cc")
        XCTAssertEqual(ARPParser.parse("192.168.1.1 ether a4:2b:b0:01:02:03 C en0").first?.ip, "192.168.1.1")
    }

    func testDuplicateHardwareAddressesAreFlaggedExceptForTheRouter() {
        let entries = [ARPEntry(ip: "192.168.1.1", mac: "aa:aa:aa:aa:aa:aa"), ARPEntry(ip: "192.168.1.9", mac: "aa:aa:aa:aa:aa:aa"),
                       ARPEntry(ip: "192.168.1.50", mac: "bb:bb:bb:bb:bb:bb"), ARPEntry(ip: "192.168.1.51", mac: "bb:bb:bb:bb:bb:bb")]
        let found = ARPParser.duplicates(entries, gateway: "192.168.1.1")
        XCTAssertEqual(found.count, 1, "the router answering for several addresses is normal")
        XCTAssertTrue(found[0].contains("bb:bb:bb:bb:bb:bb"))
    }

    func testGatewayIdentity() {
        XCTAssertFalse(GatewayIdentity.compare(known: [:], key: "n", mac: "aa").changed)
        XCTAssertFalse(GatewayIdentity.compare(known: ["n": "aa"], key: "n", mac: "aa").changed)
        let changed = GatewayIdentity.compare(known: ["n": "aa"], key: "n", mac: "bb")
        XCTAssertTrue(changed.changed); XCTAssertTrue(changed.text.contains("restart"), "it must not read as a verdict of attack")
    }

    func testBaselineLearnsSlowlyAndRemarksOnlyWithEnoughHistory() {
        var b: NetworkBaseline?
        for _ in 0..<80 { b = Baselines.update(b, median: 5) }
        XCTAssertEqual(b?.medianMs ?? 0, 5, accuracy: 0.001)
        let afterBadHour = Baselines.update(b, median: 200)
        XCTAssertLessThan(afterBadHour.medianMs, 10, "one bad reading must not become the new normal")
        XCTAssertNotNil(Baselines.remark(known: b, nowMs: 60))
        XCTAssertNil(Baselines.remark(known: b, nowMs: 8))
        XCTAssertNil(Baselines.remark(known: NetworkBaseline(medianMs: 5, samples: 10), nowMs: 500), "too little history to say")
        XCTAssertNil(Baselines.remark(known: b, nowMs: nil))
    }

    func testHotspotHints() {
        XCTAssertNotNil(HotspotHint.detect(gateway: "172.20.10.1", expensive: false))
        XCTAssertTrue(HotspotHint.detect(gateway: "172.20.10.1", expensive: false)!.contains("iPhone"))
        XCTAssertNotNil(HotspotHint.detect(gateway: "192.168.43.1", expensive: false))
        XCTAssertNil(HotspotHint.detect(gateway: "192.168.1.1", expensive: false))
        XCTAssertNotNil(HotspotHint.detect(gateway: "192.168.1.1", expensive: true))
        XCTAssertNil(HotspotHint.detect(gateway: nil, expensive: false))
    }

    func testOldQualityFilesStillDecodeAndNewOnesKeepHours() throws {
        let old = #"{"day":100,"rounds":50,"gatewayLost":2,"internetRounds":50,"internetLost":0,"stalls":1,"stallSeconds":30,"latencyBuckets":[40,5,5,0,0,0,0]}"#
        let decoded = try JSONDecoder().decode(DayQuality.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.rounds, 50); XCTAssertEqual(decoded.hourRounds, [Int](repeating: 0, count: 24))
        var d = DayQuality(day: 1)
        d.add(ProbeRound(date: Date(), gatewayMs: nil, gatewayAnswered: false), hour: 21)
        XCTAssertEqual(d.hourRounds[21], 1); XCTAssertEqual(d.hourLost[21], 1)
        let again = try JSONDecoder().decode(DayQuality.self, from: JSONEncoder().encode(d))
        XCTAssertEqual(again, d)
    }

    func testQualityReportFindsTheWorstHourAndNeverClaimsWithoutData() {
        XCTAssertNil(QualityReport.summarise([]).uptime)
        XCTAssertTrue(QualityReport.summarise([]).verdict.hasPrefix("Not enough"))
        var day = DayQuality(day: 200)
        for i in 0..<400 { day.add(ProbeRound(date: Date(), gatewayMs: 4, gatewayAnswered: !(i % 10 == 0 && i >= 200)), hour: i < 200 ? 10 : 21) }
        day.addStall(seconds: 120)
        let s = QualityReport.summarise([day])
        XCTAssertEqual(s.worstHour, 21)
        XCTAssertEqual(s.stalls, 1); XCTAssertEqual(s.stallMinutes, 2)
        XCTAssertGreaterThan(s.uptime ?? 0, 0.94); XCTAssertLessThan(s.uptime ?? 1, 0.99)
        let report = QualityReport.text(s, speeds: [("No tunnel", 12_500_000, 2_500_000, 14, Date())], dayName: { "day \($0)" })
        XCTAssertTrue(report.contains("21:00")); XCTAssertTrue(report.contains("100.0 Mbit/s")); XCTAssertTrue(report.contains("may be the Wi-Fi"))
        XCTAssertFalse(report.contains("192."), "no addresses in a report meant to be shared")
    }
}
