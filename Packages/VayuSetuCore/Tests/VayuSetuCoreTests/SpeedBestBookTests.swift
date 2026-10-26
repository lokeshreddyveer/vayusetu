import XCTest
@testable import VayuSetuCore

final class SpeedBestBookTests: XCTestCase {
    private let d = Date(timeIntervalSince1970: 1_800_000_000)
    private func key(_ mode: String = "both", net: String? = "N1", profile: String? = "P1") -> SpeedBestKey { SpeedBestKey(mode: mode, network: net, profile: profile) }

    func testABestBelongsToTheNetworkAndProfileItWasMeasuredOn() {
        var b = SpeedBestBook()
        b.noteTest(key(), down: 80e6, up: 20e6, latencyMs: 30, date: d, endpoint: "mensura.cdn-apple.com", method: "http-download")
        XCTAssertEqual(b.entry(for: key())?.best.topDown, 80e6)
        XCTAssertNil(b.entry(for: key(net: "N2")), "another network has no speed yet, so none is shown for it")
        XCTAssertNil(b.entry(for: key(profile: "P2")), "another VPN server is another path")
        XCTAssertNil(b.entry(for: key("vpn")))
        XCTAssertEqual(b.entry(for: key())?.endpoint, "mensura.cdn-apple.com"); XCTAssertEqual(b.entry(for: key())?.best.testDate, d)
    }

    func testNothingIsStoredOrShownForAnUnidentifiedNetwork() {
        var b = SpeedBestBook()
        XCTAssertFalse(b.noteTest(key(net: nil), down: 80e6, up: 20e6, latencyMs: nil, date: d, endpoint: nil, method: nil))
        XCTAssertFalse(b.noteLive(key(net: nil), down: 1, up: 1))
        XCTAssertTrue(b.entries.isEmpty); XCTAssertNil(b.entry(for: key(net: nil)))
    }

    func testTheBestOfAnEntryKeepsTheServerOfTheBestDownload() {
        var b = SpeedBestBook()
        b.noteTest(key(), down: 80e6, up: 5e6, latencyMs: 20, date: d, endpoint: "fast.example", method: "m")
        b.noteTest(key(), down: 40e6, up: 9e6, latencyMs: 35, date: d.addingTimeInterval(60), endpoint: "slow.example", method: "m")
        XCTAssertEqual(b.entry(for: key())?.endpoint, "fast.example"); XCTAssertEqual(b.entry(for: key())?.best.topDown, 80e6); XCTAssertEqual(b.entry(for: key())?.best.topUp, 9e6)
    }

    func testLivePeaksAreKeptPerConnectionAndNeverBecomeASpeed() {
        var b = SpeedBestBook()
        b.noteLive(key(), down: 90e6, up: 30e6, now: d)
        XCTAssertTrue(b.entry(for: key())!.best.isEmpty, "activity alone is not a speed")
        XCTAssertNil(b.entry(for: key(net: "N2")))
    }

    func testOlderResultsWithoutANetworkAreKeptButNeverShownAsTheCurrentConnection() {
        var old = SpeedBest(); old.noteTest(down: 200e6, up: 50e6, latencyMs: 10, date: d)
        let b = SpeedBestBook.migrating(legacy: ["both": old, "vpn": SpeedBest()])
        XCTAssertTrue(b.hasLegacy); XCTAssertEqual(b.legacy.count, 1, "an empty record is not carried over")
        XCTAssertNil(b.entry(for: key()), "the old 200 Mbit/s is not offered as this connection's speed")
    }

    func testElsewhereCountsOtherNetworksOnly() {
        var b = SpeedBestBook()
        b.noteTest(key(net: "N1"), down: 1, up: 1, latencyMs: nil, date: d, endpoint: nil, method: nil)
        b.noteTest(key(net: "N2"), down: 1, up: 1, latencyMs: nil, date: d, endpoint: nil, method: nil)
        b.noteTest(key("vpn", net: "N3"), down: 1, up: 1, latencyMs: nil, date: d, endpoint: nil, method: nil)
        XCTAssertEqual(b.elsewhere(than: key(net: "N1")), 2)
    }

    func testTheBookIsBoundedAndKeepsTheNewest() {
        var b = SpeedBestBook()
        for i in 0..<(SpeedBestBook.maximumEntries + 25) { b.noteTest(key(net: "N\(i)"), down: 1, up: 1, latencyMs: nil, date: d.addingTimeInterval(Double(i)), endpoint: nil, method: nil) }
        XCTAssertEqual(b.entries.count, SpeedBestBook.maximumEntries)
        XCTAssertNil(b.entry(for: key(net: "N0")), "the oldest went"); XCTAssertNotNil(b.entry(for: key(net: "N\(SpeedBestBook.maximumEntries + 24)")))
    }

    func testTokensDoNotRevealWhatTheyStandFor() {
        let t = SpeedBestKey.token("5A7E5E70-0000-4000-8000-0000000000D5")
        XCTAssertEqual(t.count, 16); XCTAssertFalse(t.contains("5A7E")); XCTAssertEqual(t, SpeedBestKey.token("5A7E5E70-0000-4000-8000-0000000000D5"))
        XCTAssertNotEqual(t, SpeedBestKey.token("another"))
    }

    func testTheBookSurvivesEncoding() throws {
        var b = SpeedBestBook(); b.noteTest(key(), down: 5, up: 2, latencyMs: 9, date: d, endpoint: "e", method: "m")
        XCTAssertEqual(try JSONDecoder().decode(SpeedBestBook.self, from: JSONEncoder().encode(b)), b)
    }
}
