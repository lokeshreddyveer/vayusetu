import XCTest
@testable import VayuSetuCore

final class DiagnosticSessionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    private func obs(_ layer: EvidenceLayer, _ from: TimeInterval, _ to: TimeInterval, failed: Bool = false, net: String? = "N1", iface: String? = "en0", gen: Int = 1,
                     provenance: EvidenceProvenance = .measured) -> EvidenceObservation {
        EvidenceObservation(layer: layer, start: at(from), end: at(to), interface: iface, networkKey: net, tunnelGeneration: gen, provenance: provenance, failed: failed, summary: "\(layer)")
    }
    private func opened() -> (IncidentLedger, UUID) { var l = IncidentLedger(); let id = l.open(at: at(100), networkKey: "N1", interface: "en0", tunnelGeneration: 1); return (l, id) }

    // MARK: Lifecycle
    func testOpeningTwiceOnTheSameConnectionIsOneIncident() {
        var (l, id) = opened()
        XCTAssertEqual(l.open(at: at(110), networkKey: "N1", interface: "en0", tunnelGeneration: 1), id)
        XCTAssertEqual(l.incidents.count, 1)
    }
    func testAnIncidentOnAnotherNetworkClosesTheFirst() {
        var (l, first) = opened()
        let second = l.open(at: at(200), networkKey: "N2", interface: "en0", tunnelGeneration: 1)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(l.incidents.first?.closeReason, .networkChanged); XCTAssertEqual(l.open?.id, second)
    }
    func testRecoveryKeepsTheIncidentForTheLateWindowThenClosesIt() {
        var (l, _) = opened()
        l.recover(at: at(160)); XCTAssertEqual(l.open?.phase, .recovering)
        l.advance(now: at(200)); XCTAssertEqual(l.open?.phase, .recovering, "still inside the 60 s window")
        let changed = l.advance(now: at(221)); XCTAssertEqual(changed.count, 1); XCTAssertNil(l.open); XCTAssertEqual(l.incidents.last?.closeReason, .recovered)
    }
    func testAFlapDuringRecoveryResumesTheSameIncident() {
        var (l, id) = opened()
        l.recover(at: at(160))
        XCTAssertEqual(l.open(at: at(170), networkKey: "N1", interface: "en0", tunnelGeneration: 1), id)
        XCTAssertEqual(l.open?.phase, .open); XCTAssertNil(l.open?.recoveredAt)
    }
    func testALongIncidentIsSplitWithAStableParent() {
        var (l, first) = opened()
        l.advance(now: at(100 + 1801))
        let chain = l.chain(parent: first)
        XCTAssertEqual(chain.count, 2); XCTAssertEqual(chain[1].sequence, 1); XCTAssertEqual(chain[1].parentID, first)
        XCTAssertEqual(chain[0].closeReason, .splitForLength); XCTAssertEqual(l.open?.id, chain[1].id)
        l.advance(now: at(100 + 1801 + 1801)); XCTAssertEqual(l.chain(parent: first).count, 3, "and again, still one outage")
    }
    func testAnUnrelatedLaterIncidentHasItsOwnParent() {
        var (l, first) = opened()
        l.recover(at: at(150)); l.advance(now: at(300))
        let second = l.open(at: at(2000), networkKey: "N1", interface: "en0", tunnelGeneration: 1)
        XCTAssertEqual(l.incidents.last?.parentID, second); XCTAssertNotEqual(second, first)
    }

    // MARK: Attaching evidence
    func testEvidenceFromAnotherNetworkInterfaceOrOlderTunnelIsRefused() {
        var (l, _) = opened()
        l.tunnelTransition(generation: 3, at: at(105))
        XCTAssertEqual(l.attach(obs(.router, 100, 110, failed: true, net: "N2"), now: at(111)), .rejected(.otherNetwork))
        XCTAssertEqual(l.attach(obs(.router, 100, 110, failed: true, iface: "en1"), now: at(111)), .rejected(.otherInterface))
        XCTAssertEqual(l.attach(obs(.dns, 100, 110, failed: true, gen: 0), now: at(111)), .rejected(.olderTunnelSession))
        XCTAssertTrue(l.open!.evidence.isEmpty)
    }
    func testEvidenceMustFallInsideTheWindow() {
        var (l, _) = opened()
        XCTAssertEqual(l.attach(obs(.router, 0, 20, failed: true), now: at(120)), .rejected(.outsideWindow), "ended 80 s before the incident opened")
        if case .attached = l.attach(obs(.router, 80, 95, failed: true), now: at(120)) {} else { XCTFail("ended 5 s before opening: inside the 30 s pre-roll") }
    }
    func testLateEvidenceIsAttachedAndMarkedDelayedButNothingAfterClose() {
        var (l, _) = opened()
        l.recover(at: at(160))
        if case .attached(_, _, let delayed) = l.attach(obs(.dns, 120, 150, failed: true), now: at(190)) { XCTAssertTrue(delayed) } else { XCTFail("inside the late window") }
        l.advance(now: at(230))
        XCTAssertEqual(l.attach(obs(.dns, 120, 150, failed: true), now: at(240)), .rejected(.closed), "a closed incident is not reopened by late evidence")
    }
    func testAVPNReconnectDuringAWiFiOutageKeepsTheIncidentAndAddsASession() {
        var (l, id) = opened()
        l.tunnelTransition(generation: 2, at: at(130))
        XCTAssertEqual(l.open?.id, id); XCTAssertEqual(l.open?.tunnelGenerations, [1, 2])
        if case .attached = l.attach(obs(.dns, 135, 150, failed: true, gen: 2), now: at(151)) {} else { XCTFail("evidence from the new session belongs") }
    }
    func testEvidenceIsBounded() {
        var (l, _) = opened()
        for i in 0..<(DiagnosticIncident.maximumEvidence + 20) { _ = l.attach(obs(.router, 100, 101 + Double(i % 3), failed: true), now: at(120)) }
        XCTAssertEqual(l.open?.evidence.count, DiagnosticIncident.maximumEvidence)
    }

    // MARK: Relations
    func testDNSFailingWhileTheInternetFailedIsAProbableConsequenceNotACause() {
        var (l, _) = opened()
        _ = l.attach(obs(.internet, 100, 150, failed: true), now: at(151))
        guard case .attached(_, let relation, _) = l.attach(obs(.dns, 105, 150, failed: true), now: at(152)) else { return XCTFail() }
        XCTAssertEqual(relation, .probableConsequence)
    }
    func testDNSFailingWhileEverythingBelowWorkedIsIndependent() {
        var (l, _) = opened()
        _ = l.attach(obs(.router, 100, 150, failed: false), now: at(151)); _ = l.attach(obs(.internet, 100, 150, failed: false), now: at(151))
        guard case .attached(_, let relation, _) = l.attach(obs(.dns, 105, 150, failed: true), now: at(152)) else { return XCTFail() }
        XCTAssertEqual(relation, .independentFailure)
    }
    func testDNSFailingWithNothingElseKnownIsInconclusive() {
        var (l, _) = opened()
        guard case .attached(_, let relation, _) = l.attach(obs(.dns, 105, 150, failed: true), now: at(152)) else { return XCTFail() }
        XCTAssertEqual(relation, .inconclusive)
    }
    func testAnInferredOrUnavailableObservationIsNeverMoreThanInconclusive() {
        var (l, _) = opened()
        guard case .attached(_, let relation, _) = l.attach(obs(.router, 100, 150, failed: true, provenance: .notAvailable), now: at(152)) else { return XCTFail() }
        XCTAssertEqual(relation, .inconclusive)
    }
    func testAWakeNearTheStartIsCorrelatedAndAFarOneIsNot() {
        var (l, _) = opened()
        guard case .attached(_, let near, _) = l.attach(obs(.wake, 95, 96), now: at(120)), case .attached(_, let far, _) = l.attach(obs(.vpn, 60, 70), now: at(120)) else { return XCTFail() }
        XCTAssertEqual(near, .correlated); XCTAssertEqual(far, .inconclusive)
    }
    func testTheLedgerSurvivesEncoding() throws {
        var (l, _) = opened(); _ = l.attach(obs(.router, 100, 120, failed: true), now: at(121))
        XCTAssertEqual(try JSONDecoder().decode(IncidentLedger.self, from: JSONEncoder().encode(l)), l)
    }
}

final class IncidentContinuationTests: XCTestCase {
    func testContinuingKeepsTheParentAndTheConnectionAndTheLatestTunnelSession() {
        var l = IncidentLedger(); let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let first = l.open(at: t0, networkKey: "N1", interface: "Wi-Fi", tunnelGeneration: 1)
        l.tunnelTransition(generation: 4, at: t0.addingTimeInterval(10))
        let next = l.continueIncident(at: t0.addingTimeInterval(1000))
        XCTAssertNotNil(next)
        let chain = l.chain(parent: first)
        XCTAssertEqual(chain.map(\.sequence), [0, 1]); XCTAssertEqual(chain[0].closeReason, .splitForLength)
        XCTAssertEqual(chain[1].networkKey, "N1"); XCTAssertEqual(chain[1].tunnelGenerations, [4])
        var empty = IncidentLedger()
        XCTAssertNil(empty.continueIncident(at: t0), "nothing open, nothing to continue")
    }
}

final class IncidentResumeTests: XCTestCase {
    func testAStallThatResumesAnOutageKeepsItsParentSoTheAppCanNumberTheParts() {
        var l = IncidentLedger(); let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let first = l.open(at: t0, networkKey: "N1", interface: "Wi-Fi", tunnelGeneration: 1)
        l.recover(at: t0.addingTimeInterval(60))
        let again = l.open(at: t0.addingTimeInterval(90), networkKey: "N1", interface: "Wi-Fi", tunnelGeneration: 1)
        XCTAssertEqual(again, first); XCTAssertEqual(l.open?.parentID, first)
        l.recover(at: t0.addingTimeInterval(150)); l.advance(now: t0.addingTimeInterval(300))
        let later = l.open(at: t0.addingTimeInterval(3000), networkKey: "N1", interface: "Wi-Fi", tunnelGeneration: 1)
        XCTAssertNotEqual(l.open?.parentID, first, "after the window closed, a new stall is a new outage")
        XCTAssertEqual(l.open?.parentID, later)
    }
}
