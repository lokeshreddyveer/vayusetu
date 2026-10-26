import XCTest
@testable import VayuSetuCore

final class IntegrationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Health components
    private func rounds(router: Bool?, internet: Bool?, dns: Bool?, n: Int = 20, failEvery: Int = 1) -> [ProbeRound] {
        (0..<n).map { i in
            let fail = failEvery > 0 && i % failEvery == 0
            return ProbeRound(date: t0.addingTimeInterval(Double(i)), gatewayMs: 5, gatewayAnswered: router.map { $0 || !fail }, internetMs: 20, internetAnswered: internet.map { $0 || !fail }, dnsMs: 30, dnsAnswered: dns.map { $0 || !fail })
        }
    }
    private func component(_ list: [HealthComponent], _ name: ComponentName) -> HealthComponent { list.first { $0.name == name }! }
    private func resolver(answered: Int, timeouts: Int, errors: Int, fast: Int? = nil) -> ResolverHealth {
        var buckets = [Int](repeating: 0, count: ResolverHealth.bucketLimits.count + 1); buckets[1] = fast ?? answered
        return ResolverHealth(windowStart: t0, windowEnd: t0.addingTimeInterval(600), answered: answered, timeouts: timeouts, errors: errors, rttBuckets: buckets, generation: 1)
    }

    func testAResolverOutageDoesNotMakeTheWiFiLookPoor() {
        let r = rounds(router: true, internet: true, dns: false)
        let list = HealthAssessor.assess(rounds: r, resolver: resolver(answered: 40, timeouts: 60, errors: 0), vpn: nil)
        XCTAssertEqual(component(list, .wifiRouter).state, .good); XCTAssertEqual(component(list, .internet).state, .good)
        XCTAssertEqual(component(list, .dns).state, .failing)
    }
    func testADeadRouterIsOneProblemNotThree() {
        let list = HealthAssessor.assess(rounds: rounds(router: false, internet: false, dns: false), resolver: nil, vpn: nil)
        XCTAssertEqual(component(list, .wifiRouter).state, .failing)
        XCTAssertEqual(component(list, .internet).state, .unknown); XCTAssertEqual(component(list, .dns).state, .unknown)
    }
    func testDNSWithoutTunnelFiguresSaysSoAndUsesTheAppsOwnCheck() {
        let list = HealthAssessor.assess(rounds: rounds(router: true, internet: true, dns: true), resolver: nil, vpn: nil)
        XCTAssertEqual(component(list, .dns).state, .good); XCTAssertTrue(component(list, .dns).reason.hasPrefix("Tunnel resolver health unavailable"))
    }
    func testTooFewLookupsIsUnknownNotGood() {
        let few = resolver(answered: 5, timeouts: 0, errors: 0)
        XCTAssertNil(few.failureShare)
        let list = HealthAssessor.assess(rounds: rounds(router: true, internet: true, dns: nil), resolver: few, vpn: nil)
        XCTAssertEqual(component(list, .dns).state, .unknown)
    }
    func testSlowButAnsweringResolverIsDegraded() {
        var buckets = [Int](repeating: 0, count: ResolverHealth.bucketLimits.count + 1); buckets[6] = 50      // 800-1600 ms
        let slow = ResolverHealth(windowStart: t0, windowEnd: t0, answered: 50, timeouts: 0, errors: 0, rttBuckets: buckets, generation: 1)
        XCTAssertEqual(slow.roundTripMs(percentile: 0.95), 1600)
        XCTAssertEqual(component(HealthAssessor.assess(rounds: rounds(router: true, internet: true, dns: nil), resolver: slow, vpn: nil), .dns).state, .degraded)
    }
    func testCountersFromAnOlderTunnelRunAreReplacedNotAdded() {
        let old = resolver(answered: 100, timeouts: 0, errors: 0), fresh = ResolverHealth(windowStart: t0, windowEnd: t0, answered: 3, timeouts: 0, errors: 0, generation: 2)
        XCTAssertEqual(old.accepting(newer: fresh).generation, 2)
        XCTAssertEqual(fresh.accepting(newer: old).generation, 2, "an older generation never replaces a newer one")
    }
    func testTheVPNComponentReportsItsOwnState() {
        func vpn(_ v: VPNHealthInput?) -> ComponentState { component(HealthAssessor.assess(rounds: [], resolver: nil, vpn: v), .vpn).state }
        XCTAssertEqual(vpn(nil), .unknown); XCTAssertEqual(vpn(VPNHealthInput(running: true, connected: true, handshakeAge: 30)), .good)
        XCTAssertEqual(vpn(VPNHealthInput(running: true, connected: true, handshakeAge: 900)), .degraded)
        XCTAssertEqual(vpn(VPNHealthInput(running: true, connected: false)), .degraded); XCTAssertEqual(vpn(VPNHealthInput(running: true, connected: false, failed: true)), .failing)
    }

    // MARK: Speed comparison
    private func ctx(net: String? = "N1", vpn: Bool = false, mode: String = "direct", endpoint: String = "speed.example", streams: Int = 4, metered: Bool? = false) -> SpeedContext {
        SpeedContext(networkKey: net, vpnOn: vpn, mode: mode, method: "http-download", endpoint: endpoint, transport: "https", streams: streams, metered: metered)
    }
    private func hist(_ c: SpeedContext?, _ downs: [Double]) -> [SpeedSample] { downs.enumerated().map { SpeedSample(context: c, down: $0.element, up: 1, date: t0.addingTimeInterval(Double($0.offset))) } }

    func testOnlyIdenticalConditionsAreCompared() {
        let a = ctx()
        XCTAssertTrue(a.comparable(to: ctx()))
        for other in [ctx(net: "N2"), ctx(vpn: true), ctx(mode: "both"), ctx(endpoint: "other.example"), ctx(streams: 8), ctx(metered: true)] { XCTAssertFalse(a.comparable(to: other)) }
        var viaServer1 = ctx(vpn: true), viaServer2 = ctx(vpn: true); viaServer1.vpnProfile = "P1"; viaServer2.vpnProfile = "P2"
        XCTAssertFalse(viaServer1.comparable(to: viaServer2), "a test through another VPN server is another path")
        XCTAssertTrue(viaServer1.comparable(to: viaServer1))
        XCTAssertFalse(ctx(net: nil).comparable(to: ctx(net: nil)), "an unknown network is never assumed to be the same")
        XCTAssertTrue(ctx(metered: nil).comparable(to: ctx(metered: true)), "an unknown metered state does not block a match")
    }
    func testASlowResultIsJudgedOnlyAgainstFairHistory() {
        let h = hist(ctx(), [100, 110, 90, 105]) + hist(ctx(vpn: true), [10, 10, 10, 10])
        let now = SpeedSample(context: ctx(), down: 60, up: 1, date: t0.addingTimeInterval(100))
        guard case .slower(let pct, let median) = SpeedComparison.compare(now, history: h) else { return XCTFail() }
        XCTAssertEqual(median, 102.5, accuracy: 0.1); XCTAssertEqual(pct, 41)
        XCTAssertEqual(SpeedComparison.compare(SpeedSample(context: ctx(), down: 100, up: 1, date: now.date), history: h), .usual(medianDown: 102.5))
    }
    func testOldResultsAndThinHistoryGetNoComparison() {
        let old = SpeedSample(context: nil, down: 50, up: 1, date: t0.addingTimeInterval(100))
        guard case .noComparison(let why) = SpeedComparison.compare(old, history: hist(ctx(), [1, 2, 3])) else { return XCTFail() }
        XCTAssertTrue(why.contains("before"))
        guard case .noComparison = SpeedComparison.compare(SpeedSample(context: ctx(), down: 5, up: 1, date: t0.addingTimeInterval(100)), history: hist(ctx(), [5, 6])) else { return XCTFail() }
    }

    // MARK: Scheduled checks in the report
    func testTheReportSectionStatesThePeriodAndLeavesOutAddresses() {
        let recs = [ScheduledCheckRecord(date: t0, skipped: false, signInPageSeen: false, publicAddressChanged: false, slowestNameServerMs: 40),
                    ScheduledCheckRecord(date: t0.addingTimeInterval(86_400), skipped: false, signInPageSeen: true, publicAddressChanged: true, slowestNameServerMs: 90),
                    ScheduledCheckRecord(date: t0.addingTimeInterval(2 * 86_400), skipped: true),
                    ScheduledCheckRecord(date: t0.addingTimeInterval(3 * 86_400), skipped: false, signInPageSeen: false, publicAddressChanged: false, slowestNameServerMs: 55)]
        let lines = ScheduledReport.section(recs, dayName: { "D\($0)" })
        let text = lines.joined(separator: "\n")
        XCTAssertTrue(text.contains("Measured")); XCTAssertTrue(text.contains("3 runs")); XCTAssertTrue(text.contains("1 skipped"))
        XCTAssertTrue(text.contains("between D") && text.contains(" and D"))
        XCTAssertTrue(text.contains("sign-in page was blocking the internet in 1 of 3")); XCTAssertTrue(text.contains("changed between checks 1 time"))
        XCTAssertFalse(text.contains("http") || text.contains("192.") || text.contains("://"), "no addresses in the report")
    }
    func testNoRecordsSaysTheyAreOffAndTheListIsBounded() {
        XCTAssertTrue(ScheduledReport.section([], dayName: { "\($0)" })[0].contains("off unless"))
        var list: [ScheduledCheckRecord] = []
        for i in 0..<(ScheduledReport.maximumRecords + 30) { list = ScheduledReport.appended(list, ScheduledCheckRecord(date: t0.addingTimeInterval(Double(i)), skipped: false)) }
        XCTAssertEqual(list.count, ScheduledReport.maximumRecords)
    }

    // MARK: Domains before a stall
    func testTheRingKeepsNothingUntilAllowedAndForgetsWhenSwitchedOff() {
        var ring = RecentDomainRing()
        ring.add(name: "a.example", allowed: 3, blocked: 0, at: t0); XCTAssertTrue(ring.entries.isEmpty, "off by default")
        ring.setEnabled(true); ring.add(name: "a.example", allowed: 3, blocked: 1, at: t0); ring.add(name: "b.example", allowed: 1, blocked: 0, at: t0.addingTimeInterval(10))
        XCTAssertEqual(ring.top(from: t0, to: t0.addingTimeInterval(20)).map(\.name), ["a.example", "b.example"])
        ring.setEnabled(false); XCTAssertTrue(ring.entries.isEmpty); XCTAssertTrue(ring.top(from: t0, to: t0.addingTimeInterval(20)).isEmpty)
    }
    func testTheRingForgetsOldEntriesAndOnlySpeaksForWhatItCovered() {
        var ring = RecentDomainRing(); ring.setEnabled(true)
        ring.add(name: "old.example", allowed: 1, blocked: 0, at: t0)
        ring.add(name: "new.example", allowed: 1, blocked: 0, at: t0.addingTimeInterval(RecentDomainRing.retention + 5))
        XCTAssertEqual(ring.entries.map(\.name), ["new.example"])
        XCTAssertFalse(ring.covers(from: t0), "it was not on for that window")
    }

    // MARK: Resolver suggestion
    private let controlD = ResolverCandidate(name: "Control D", filtering: .provider, worksThroughVPN: true)
    private func alt(_ name: String, filtering: ResolverCandidate.Filtering, vpn: Bool = true, reachable: Bool? = true) -> ResolverCandidate { .init(name: name, filtering: filtering, worksThroughVPN: vpn, reachableNow: reachable, probeMs: 40) }

    func testASuggestionNeedsRealFailuresWhileTheConnectionWasFine() {
        let bad = resolver(answered: 60, timeouts: 40, errors: 0)
        XCTAssertNotNil(ResolverRecommendation.evaluate(current: controlD, health: bad, connectionHealthy: true, vpnOn: false, others: [alt("VayuSetu DNS", filtering: .vayusetuLists)]))
        XCTAssertNil(ResolverRecommendation.evaluate(current: controlD, health: bad, connectionHealthy: false, vpnOn: false, others: [alt("VayuSetu DNS", filtering: .vayusetuLists)]), "the network is the problem, not the resolver")
        XCTAssertNil(ResolverRecommendation.evaluate(current: controlD, health: resolver(answered: 99, timeouts: 1, errors: 0), connectionHealthy: true, vpnOn: false, others: [alt("X", filtering: .vayusetuLists)]))
        XCTAssertNil(ResolverRecommendation.evaluate(current: controlD, health: resolver(answered: 3, timeouts: 7, errors: 0), connectionHealthy: true, vpnOn: false, others: [alt("X", filtering: .vayusetuLists)]), "ten lookups are not enough")
    }
    func testNeverSuggestsSomethingWorseOrUnreachableOrIncompatibleWithTheVPN() {
        let bad = resolver(answered: 60, timeouts: 40, errors: 0)
        XCTAssertNil(ResolverRecommendation.evaluate(current: controlD, health: bad, connectionHealthy: true, vpnOn: false, others: [alt("Plain", filtering: .none)]), "it would give up filtering")
        XCTAssertNil(ResolverRecommendation.evaluate(current: controlD, health: bad, connectionHealthy: true, vpnOn: false, others: [alt("Down", filtering: .vayusetuLists, reachable: false), alt("Untested", filtering: .vayusetuLists, reachable: nil)]))
        XCTAssertNil(ResolverRecommendation.evaluate(current: controlD, health: bad, connectionHealthy: true, vpnOn: true, others: [alt("NoVPN", filtering: .vayusetuLists, vpn: false)]), "does not work through the VPN")
        XCTAssertNil(ResolverRecommendation.evaluate(current: controlD, health: bad, connectionHealthy: true, vpnOn: false, privacyPrefersCurrent: true, others: [alt("VayuSetu DNS", filtering: .vayusetuLists)]))
    }
    func testASuggestionExplainsItselfAndNeverActs() {
        let s = ResolverRecommendation.evaluate(current: controlD, health: resolver(answered: 60, timeouts: 40, errors: 0), connectionHealthy: true, vpnOn: false, others: [alt("VayuSetu DNS", filtering: .vayusetuLists)])!
        XCTAssertEqual(s.candidate, "VayuSetu DNS"); XCTAssertTrue(s.reasons[0].contains("40%")); XCTAssertTrue(s.caveats.contains { $0.contains("will not change your resolver") })
    }
}

final class ResolverWindowTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func sample(_ at: TimeInterval, answered: Int, timeouts: Int = 0, errors: Int = 0, gen: Int = 1, fastBucket: Int? = nil) -> ResolverSample {
        var rtt = [Int](repeating: 0, count: ResolverHealth.bucketLimits.count + 1); rtt[1] = fastBucket ?? answered
        return ResolverSample(date: t0.addingTimeInterval(at), answered: answered, timeouts: timeouts, errors: errors, cacheHits: 0, rtt: rtt, generation: gen)
    }
    func testHealthIsTheDifferenceOverTheLastWindowNotTheWholeRun() {
        // 1000 good lookups in the first hour, then 10 minutes in which half of 100 forwarded lookups timed out.
        let samples = [sample(0, answered: 0), sample(3600, answered: 1000), sample(4200, answered: 1050, timeouts: 50)]
        let h = ResolverWindow.health(samples, now: t0.addingTimeInterval(4200))!
        XCTAssertEqual(h.answered, 50); XCTAssertEqual(h.timeouts, 50); XCTAssertEqual(h.failureShare ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(h.windowStart, t0.addingTimeInterval(3600))
    }
    func testANewTunnelRunReplacesTheOldReadingsAndNeverMixes() {
        var list = [sample(0, answered: 500, gen: 1), sample(60, answered: 600, gen: 1)]
        list = ResolverWindow.appending(list, sample(120, answered: 3, gen: 2))
        XCTAssertEqual(list.count, 1); XCTAssertEqual(list[0].generation, 2)
        XCTAssertNil(ResolverWindow.health(list, now: t0.addingTimeInterval(130)), "one reading is not a window")
        list = ResolverWindow.appending(list, sample(180, answered: 40, gen: 2))
        XCTAssertEqual(ResolverWindow.health(list, now: t0.addingTimeInterval(190))?.answered, 37)
    }
    func testAnOlderGenerationNeverReplacesANewerOne() {
        let list = ResolverWindow.appending([sample(0, answered: 5, gen: 3)], sample(10, answered: 9, gen: 2))
        XCTAssertEqual(list.map(\.generation), [3, 2].filter { $0 >= 3 })
    }
    func testCountersGoingBackwardsStartOver() {
        let list = ResolverWindow.appending([sample(0, answered: 500)], sample(60, answered: 10))
        XCTAssertEqual(list.count, 1)
    }
    func testTheListIsBounded() {
        var list: [ResolverSample] = []
        for i in 0..<(ResolverWindow.maximumSamples + 50) { list = ResolverWindow.appending(list, sample(Double(i), answered: i)) }
        XCTAssertEqual(list.count, ResolverWindow.maximumSamples)
    }
}
