import XCTest
@testable import VayuSetuCore

final class InsightTests: XCTestCase {
    // MARK: DNS bypass
    private func flow(_ app: String, host: String = "", port: String, address: String? = nil, outbound: Bool = true) -> BypassFlow {
        BypassFlow(app: app, appName: app, host: host, port: port, proto: "tcp", remoteAddress: address, outbound: outbound)
    }
    func testDoTAndKnownDoHAreFoundAndOrdinaryWebIsNot() {
        let flows = [flow("org.mozilla.firefox", host: "mozilla.cloudflare-dns.com", port: "443"),
                     flow("org.mozilla.firefox", host: "mozilla.cloudflare-dns.com", port: "443"),
                     flow("com.example.app", host: "dns.example.net", port: "853"),
                     flow("com.apple.Safari", host: "www.apple.com", port: "443"),
                     flow("com.apple.Safari", host: "", port: "443", address: "1.1.1.1")]
        let found = DNSBypassDetector.findings(flows)
        XCTAssertEqual(found.map(\.app).sorted(), ["com.apple.Safari", "com.example.app", "org.mozilla.firefox"])
        let fx = found.first { $0.app == "org.mozilla.firefox" }!
        XCTAssertEqual(fx.kind, .dnsOverHTTPS); XCTAssertEqual(fx.resolver, "Cloudflare"); XCTAssertEqual(fx.connections, 2)
        XCTAssertEqual(found.first { $0.app == "com.example.app" }?.kind, .dnsOverTLS)
        XCTAssertTrue(fx.message.contains("do not see its lookups"))
    }
    func testVayuSetuItselfAndInboundAreNeverFlagged() {
        XCTAssertTrue(DNSBypassDetector.findings([flow("app.vayusetu.macos.tunnel", host: "dns.controld.com", port: "443"), flow("x", host: "dns.google", port: "443", outbound: false)]).isEmpty)
    }
    func testAnAddressOnPort443ThatIsNotAResolverIsIgnored() {
        XCTAssertTrue(DNSBypassDetector.findings([flow("a", host: "example.com", port: "443", address: "93.184.216.34")]).isEmpty)
    }

    // MARK: First seen
    func testNothingIsReportedWhileLearning() {
        var t = FirstSeenTracker()
        XCTAssertNil(t.record(app: "a", name: "A", host: "x.example.com", day: 100))
        XCTAssertNil(t.record(app: "b", name: "B", host: "y.example.com", day: 102), "still inside the three learning days")
        XCTAssertTrue(t.isLearning(on: 102)); XCTAssertFalse(t.isLearning(on: 103))
    }
    func testAfterLearningANewAppAndANewSiteAreReportedOnce() {
        var t = FirstSeenTracker()
        t.record(app: "a", name: "A", host: "x.example.com", day: 100)
        XCTAssertEqual(t.record(app: "n", name: "New", host: "n.example.org", day: 110), .newApp(app: "n", name: "New"))
        XCTAssertNil(t.record(app: "n", name: "New", host: "other.example.org", day: 110), "the same site again is not new")
        XCTAssertEqual(t.record(app: "a", name: "A", host: "cdn.fresh.net", day: 110), .newSite(app: "a", name: "A", site: "fresh.net"))
        XCTAssertNil(t.record(app: "a", name: "A", host: "x.example.com", day: 110), "seen during learning")
    }
    func testSubdomainsOfTheSameSiteAreOneSite() {
        XCTAssertEqual(FirstSeenTracker.site(of: "a1.cdn.Example.com"), "example.com")
        XCTAssertEqual(FirstSeenTracker.site(of: "shop.example.co.uk"), "example.co.uk")
        XCTAssertEqual(FirstSeenTracker.site(of: "93.184.216.34"), "93.184.216.34")
        XCTAssertEqual(FirstSeenTracker.site(of: "localhost"), "localhost")
    }
    func testTheSummaryListsWhatIsNewToday() {
        var t = FirstSeenTracker()
        t.record(app: "a", name: "A", host: "x.example.com", day: 100)
        t.record(app: "n", name: "New", host: "n.example.org", day: 110)
        t.record(app: "a", name: "A", host: "fresh.net", day: 110)
        let s = t.summary(day: 110)
        XCTAssertEqual(s.newApps, ["New"]); XCTAssertEqual(s.newSites.map(\.site), ["fresh.net"]); XCTAssertFalse(s.learning)
        XCTAssertTrue(t.summary(day: 101).newApps.isEmpty)
    }
    func testItIsBoundedAndSurvivesEncoding() throws {
        var t = FirstSeenTracker()
        t.record(app: "a", name: "A", host: "x.example.com", day: 1)
        for i in 0..<(FirstSeenTracker.maximumPairs + 50) { t.record(app: "a", name: "A", host: "h\(i).site\(i).com", day: 2 + i % 5) }
        XCTAssertLessThanOrEqual(t.pairs.count, FirstSeenTracker.maximumPairs)
        let back = try JSONDecoder().decode(FirstSeenTracker.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(back, t)
    }

    // MARK: Tracker owners
    func testOwnersMatchTheMostSpecificParent() {
        XCTAssertEqual(TrackerOwners.owner(of: "pagead2.googlesyndication.com"), "Google")
        XCTAssertEqual(TrackerOwners.owner(of: "G.DoubleClick.net."), "Google")
        XCTAssertEqual(TrackerOwners.owner(of: "connect.facebook.net"), "Meta")
        XCTAssertEqual(TrackerOwners.owner(of: "px.ads.linkedin.com"), "LinkedIn (Microsoft)")
        XCTAssertNil(TrackerOwners.owner(of: "example.com"))
        XCTAssertNil(TrackerOwners.owner(of: "notdoubleclick.net"), "a name that merely ends in the same letters is not the same domain")
        XCTAssertNil(TrackerOwners.owner(of: "facebook.com"), "a site people visit is not labelled as a tracker")
    }
    func testGroupingSumsByCompanyAndReportsTheRestApart() {
        let g = TrackerOwners.group(blocked: [("pagead2.googlesyndication.com", 40), ("www.google-analytics.com", 10), ("connect.facebook.net", 25), ("mystery.example", 7), ("zero.criteo.com", 0)])
        XCTAssertEqual(g.groups.map(\.company), ["Google", "Meta"]); XCTAssertEqual(g.groups[0].blocked, 50); XCTAssertEqual(g.unattributed, 7)
        XCTAssertEqual(g.groups[0].domains, ["pagead2.googlesyndication.com", "www.google-analytics.com"])
    }
    func testNoDuplicateDomainsInTheTable() {
        XCTAssertGreaterThan(TrackerOwners.table.count, 80)
    }
}
