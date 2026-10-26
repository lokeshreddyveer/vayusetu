import XCTest
@testable import VayuSetuCore

final class ResolverTrustTests: XCTestCase {
    func testKnownAddressesMatchIncludingIPv6Casing() {
        XCTAssertEqual(ResolverTrust.classify(name: "one.one.one.one", answers: ["1.1.1.1", "1.0.0.1"]), .matched)
        XCTAssertEqual(ResolverTrust.classify(name: "one.one.one.one", answers: ["2606:4700:4700::1111%en0"]), .matched)
        XCTAssertEqual(ResolverTrust.classify(name: "dns.quad9.net", answers: ["2620:FE::FE"]), .matched)
    }
    func testAForgedAddressIsDifferentAndNamed() {
        XCTAssertEqual(ResolverTrust.classify(name: "dns.google", answers: ["8.8.8.8", "203.0.113.9"]), .different(unexpected: ["203.0.113.9"]))
    }
    func testAResolversOwnBlockIsFilteringNotTampering() {
        XCTAssertEqual(ResolverTrust.classify(name: "dns.google", answers: ["0.0.0.0", "::"]), .filtered)
        XCTAssertEqual(ResolverTrust.classify(name: "dns.google", answers: ["8.8.8.8", "0.0.0.0"]), .matched, "a null address next to a real one is not a forgery")
    }
    func testNoAnswerOrUnknownNameIsNoAnswer() {
        XCTAssertEqual(ResolverTrust.classify(name: "dns.google", answers: []), .noAnswer)
        XCTAssertEqual(ResolverTrust.classify(name: "example.org", answers: ["1.2.3.4"]), .noAnswer, "only the pinned names are judged")
    }
    func testVerdictNeedsTwoMatchesToBeConsistentAndOneMismatchToBeSuspicious() {
        func r(_ n: String, _ o: ResolverTrust.Outcome) -> ResolverTrust.Result { .init(name: n, outcome: o) }
        XCTAssertEqual(ResolverTrust.verdict([r("a", .matched), r("b", .matched), r("c", .noAnswer)]), .consistent)
        XCTAssertEqual(ResolverTrust.verdict([r("a", .matched), r("b", .noAnswer), r("c", .noAnswer)]), .inconclusive)
        XCTAssertEqual(ResolverTrust.verdict([r("a", .filtered), r("b", .filtered), r("c", .filtered)]), .inconclusive)
        XCTAssertEqual(ResolverTrust.verdict([r("a", .matched), r("b", .different(unexpected: ["9.9.9.9"])), r("c", .matched)]), .suspicious(names: ["b"]))
    }
    func testTheSummaryNeverPrintsAnAddress() {
        let text = ResolverTrust.summary([.init(name: "dns.google", outcome: .different(unexpected: ["203.0.113.9"])), .init(name: "one.one.one.one", outcome: .matched)])
        XCTAssertFalse(text.contains("203.0.113.9")); XCTAssertTrue(text.contains("dns.google"))
    }
    func testThePinnedTableHasNoDuplicatesAndOnlyAnycastAddresses() {
        XCTAssertEqual(Set(ResolverTrust.known.map(\.name)).count, ResolverTrust.known.count)
        for k in ResolverTrust.known { XCTAssertFalse(k.addresses.isEmpty); XCTAssertFalse(k.addresses.contains("0.0.0.0")) }
    }
}
