import XCTest
@testable import VayuSetuCore

final class SecurityDigestTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func flow(_ app: String, _ host: String = "example.com", blocked: Bool = false, ago: TimeInterval = 10, team: String? = "T", identity: String? = nil, parent: String? = nil, name: String? = nil) -> DigestFlow {
        DigestFlow(app: app, appName: name ?? app, host: host, blocked: blocked, time: now.addingTimeInterval(-ago), team: team, identity: identity, parent: parent)
    }
    func testEmptyHistory() {
        let d = SecurityDigestBuilder.build([], now: now)
        XCTAssertEqual(d.connections, 0); XCTAssertTrue(d.apps.isEmpty && d.findings.isEmpty); XCTAssertEqual(d.blockedShare, 0)
    }
    func testAppsAndBlockedDestinationsAreRanked() {
        let flows = [flow("a", "x.com"), flow("a", "y.com", blocked: true), flow("a", "y.com", blocked: true), flow("b", "y.com", blocked: true), flow("b", "z.com")]
        let d = SecurityDigestBuilder.build(flows, now: now)
        XCTAssertEqual(d.apps.map(\.app), ["a", "b"]); XCTAssertEqual(d.apps[0].connections, 3); XCTAssertEqual(d.apps[0].blocked, 2); XCTAssertEqual(d.apps[0].destinations, 2)
        XCTAssertEqual(d.blockedDestinations.first?.host, "y.com"); XCTAssertEqual(d.blockedDestinations.first?.count, 3); XCTAssertEqual(d.blockedDestinations.first?.apps, 2)
        XCTAssertEqual(d.blocked, 3); XCTAssertEqual(d.blockedShare, 0.6, accuracy: 0.0001)
    }
    func testIdentityFindingsComeFirst() {
        let flows = [flow("tool", "x.com", team: nil, name: "curl"), flow("bad", team: "T", identity: "Invalid signature"), flow("swap", team: "T", identity: "Signer changed")]
        let d = SecurityDigestBuilder.build(flows, now: now)
        XCTAssertEqual(d.findings.first?.severity, .high)
        XCTAssertTrue(d.findings.contains { $0.id == "invalid-bad" } && d.findings.contains { $0.id == "signer-swap" } && d.findings.contains { $0.id == "tool-tool" })
        XCTAssertEqual(d.findings.filter { $0.severity == .high }.count, 2)
        XCTAssertEqual(d.findings.first { $0.id == "invalid-bad" }?.app, "bad")
    }
    func testToolsAreNoticedWithTheirParent() {
        let d = SecurityDigestBuilder.build([flow("python3", team: nil, parent: "Terminal"), flow("python3", team: nil, parent: "Terminal")], now: now)
        let finding = d.findings.first { $0.id == "tool-python3" }
        XCTAssertNotNil(finding); XCTAssertTrue(finding?.detail.contains("Terminal") == true && finding?.detail.contains("2 connections") == true)
    }
    func testUnsignedAppsExcludeAppleAndTools() {
        let d = SecurityDigestBuilder.build([flow("com.apple.Safari", team: nil), flow("vendor.thing", team: nil, name: "Thing"), flow("signed.app", team: "T")], now: now)
        let unsigned = d.findings.first { $0.id == "unsigned" }
        XCTAssertNotNil(unsigned); XCTAssertTrue(unsigned?.title.hasPrefix("1 app") == true); XCTAssertEqual(unsigned?.app, "vendor.thing")
    }
    func testBurst() {
        let many = (0..<120).map { flow("busy", "h\($0).com", ago: Double($0) * 2, name: "Busy") }
        XCTAssertTrue(SecurityDigestBuilder.build(many, now: now).findings.contains { $0.id == "burst" && $0.detail.contains("Busy") })
        XCTAssertFalse(SecurityDigestBuilder.build(Array(many.prefix(20)), now: now).findings.contains { $0.id == "burst" })
    }
    func testNewAppsNeedAHistoryThatBeganEarlier() {
        // A fresh install: everything is "new", so nothing is reported as new.
        XCTAssertTrue(SecurityDigestBuilder.build([flow("a", ago: 600), flow("b", ago: 20)], now: now).newApps.isEmpty)
        // History from two hours ago, and one app that first appeared ten minutes ago.
        let d = SecurityDigestBuilder.build([flow("old", ago: 7200), flow("old", ago: 100), flow("fresh", ago: 600)], now: now)
        XCTAssertEqual(d.newApps.map(\.app), ["fresh"]); XCTAssertTrue(d.findings.contains { $0.id == "new" })
    }
}
