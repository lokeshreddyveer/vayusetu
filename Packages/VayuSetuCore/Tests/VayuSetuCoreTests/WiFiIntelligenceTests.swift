import XCTest
@testable import VayuSetuCore

final class WiFiIntelligenceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func round(_ s: Double, gw: Double? = 5, gwOK: Bool? = true, net: Double? = 20, netOK: Bool? = true, dnsOK: Bool? = true) -> ProbeRound {
        ProbeRound(date: t0.addingTimeInterval(s), gatewayMs: gw, gatewayAnswered: gwOK, internetMs: net, internetAnswered: netOK, dnsMs: 15, dnsAnswered: dnsOK)
    }
    private func reading(rssi: Int = -54, noise: Int = -92, associated: Bool = true) -> WiFiReading {
        WiFiReading(date: t0, associated: associated, ssid: "Home", bssid: "aa:bb", rssi: rssi, noise: noise, channel: 44, band: .ghz5, linkRateMbps: 866)
    }

    func testBandPrefersWhatMacOSReportedBecauseChannelNumbersOverlap() {
        XCTAssertEqual(WiFiBand.from(channel: 1), .ghz2)
        XCTAssertEqual(WiFiBand.from(channel: 1, reported: .ghz6), .ghz6, "channel 1 exists in 6 GHz too")
        XCTAssertEqual(WiFiBand.from(channel: 44), .ghz5)
        XCTAssertEqual(WiFiBand.from(channel: 999), .unknown)
    }

    func testSignalQualityAndSNR() {
        XCTAssertEqual(SignalQuality.from(rssi: -50), .excellent)
        XCTAssertEqual(SignalQuality.from(rssi: -70), .fair)
        XCTAssertEqual(SignalQuality.from(rssi: -90), .unusable)
        XCTAssertEqual(SignalQuality.from(rssi: nil), .unknown)
        XCTAssertEqual(SignalQuality.from(rssi: 0), .unknown, "macOS reports 0 when not associated")
        XCTAssertEqual(reading().snr, 38)
        XCTAssertNil(WiFiReading(date: t0, associated: false).snr)
    }

    func testHealthScoreNeedsDataAndFallsWithLossAndSpikes() {
        XCTAssertNil(ConnectionHealth.score(reading: reading(), rounds: [round(0)]), "too few probes to say anything")
        XCTAssertNil(ConnectionHealth.score(reading: reading(associated: false), rounds: (0..<10).map { round(Double($0)) }))
        let clean = (0..<10).map { round(Double($0)) }
        let good = ConnectionHealth.score(reading: reading(), rounds: clean)
        XCTAssertGreaterThanOrEqual(good ?? 0, 95)
        let lossy = (0..<10).map { round(Double($0), gw: $0 % 2 == 0 ? nil : 5, gwOK: $0 % 2 != 0) }
        XCTAssertLessThan(ConnectionHealth.score(reading: reading(), rounds: lossy) ?? 100, 60, "half the router probes lost is poor")
        let spike = clean + [round(11, gw: 1005)]
        XCTAssertLessThan(ConnectionHealth.score(reading: reading(), rounds: spike) ?? 100, good ?? 0, "a 1 s spike lowers the score")
        XCTAssertLessThan(ConnectionHealth.score(reading: reading(rssi: -88), rounds: clean) ?? 100, good ?? 0)
        XCTAssertEqual(ConnectionHealth.label(nil), "Not enough data yet")
        XCTAssertEqual(ConnectionHealth.label(95), "Stable")
    }

    func testDetectorNeedsRepeatedEvidenceAndNeedsRecoveryToClose() {
        var d = StallDetector()
        var opened = false, closed = false
        func feed(_ r: ProbeRound) { let o = d.record(r, baselineMs: 5); if o.opened { opened = true }; if o.closed { closed = true } }
        feed(round(0, gw: nil, gwOK: false))
        XCTAssertEqual(d.state, .suspected)
        feed(round(1))                            // one good round does not clear a flaky link
        feed(round(2, gw: nil, gwOK: false))
        XCTAssertFalse(opened, "two bad rounds are only a suspicion")
        feed(round(3, gw: nil, gwOK: false))
        XCTAssertTrue(opened, "the third bad round confirms it")
        XCTAssertEqual(d.state, .confirmed)
        feed(round(5)); feed(round(6))
        XCTAssertFalse(closed, "two good rounds are not enough")
        feed(round(7))
        XCTAssertTrue(closed)
        XCTAssertEqual(d.state, .healthy)
    }

    func testOneSlowPingIsNotAnIncident() {
        var d = StallDetector()
        _ = d.record(round(0, gw: 1005), baselineMs: 5)         // the 1,005 ms spike
        XCTAssertEqual(d.state, .suspected)
        _ = d.record(round(1), baselineMs: 5); _ = d.record(round(2), baselineMs: 5)
        XCTAssertEqual(d.state, .healthy, "it recovered by itself, so no incident is recorded")
    }

    func testClassifierFollowsTheMatrix() {
        var e = IncidentEvidence(); e.roundsDuring = 5
        e.associatedDuring = false
        XCTAssertEqual(IncidentClassifier.diagnose(e).cause, .wifiDisconnected)

        e = IncidentEvidence(); e.roundsDuring = 5; e.gatewayFailedDuring = false; e.internetFailedDuring = true
        XCTAssertEqual(IncidentClassifier.diagnose(e).cause, .upstream)

        e = IncidentEvidence(); e.roundsDuring = 5; e.gatewayFailedDuring = false; e.internetFailedDuring = false; e.dnsFailedDuring = true
        XCTAssertEqual(IncidentClassifier.diagnose(e).cause, .dnsResolver)

        e = IncidentEvidence(); e.roundsDuring = 5; e.bssidBefore = "aa"; e.bssidDuring = "bb"; e.gatewayFailedDuring = true
        XCTAssertEqual(IncidentClassifier.diagnose(e).cause, .roaming)

        e = IncidentEvidence(); e.roundsDuring = 5; e.gatewayFailedDuring = true; e.rssiBefore = -55; e.rssiDuring = -82
        let weak = IncidentClassifier.diagnose(e)
        XCTAssertEqual(weak.cause, .weakSignal); XCTAssertEqual(weak.confidence, .high)

        e = IncidentEvidence(); e.roundsDuring = 5; e.gatewayFailedDuring = true; e.internetFailedDuring = true; e.rssiBefore = -52; e.rssiDuring = -53
        XCTAssertEqual(IncidentClassifier.diagnose(e).cause, .localNetwork)

        e = IncidentEvidence(); e.roundsDuring = 5; e.secondsSinceWake = 6; e.gatewayFailedDuring = true
        XCTAssertEqual(IncidentClassifier.diagnose(e).cause, .afterWake, "right after sleep, reconnecting explains it")
    }

    func testFewRoundsCapConfidenceAndNothingIsClaimedWithoutEvidence() {
        var e = IncidentEvidence(); e.roundsDuring = 1; e.gatewayFailedDuring = false; e.internetFailedDuring = true
        XCTAssertEqual(IncidentClassifier.diagnose(e).confidence, .low, "one round is not enough to be sure")
        let unknown = IncidentClassifier.diagnose(IncidentEvidence())
        XCTAssertEqual(unknown.cause, .unknown); XCTAssertEqual(unknown.confidence, .low)
        for cause in [StallCause.wifiDisconnected, .weakSignal, .roaming, .localNetwork, .upstream, .dnsResolver, .afterWake, .unknown] { XCTAssertFalse(cause.title.isEmpty) }
        XCTAssertFalse(unknown.evidence.isEmpty, "a diagnosis always says what it saw")
    }
}
