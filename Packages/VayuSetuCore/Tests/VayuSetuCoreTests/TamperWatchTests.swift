import XCTest
@testable import VayuSetuCore

final class TamperWatchTests: XCTestCase {
    // Taken from `scutil --dns` on a Mac running VayuSetu in each state (addresses and interface names as they appeared).
    private let dnsOnly = """
    DNS configuration

    resolver #1
      search domain[0] : attlocal.net
      nameserver[0] : 198.18.0.2
      if_index : 39 (utun10)
      flags    : Supplemental, Request A records, Request AAAA records
      order    : 106400

    resolver #2
      nameserver[0] : 2600:1700:6e0:be0::1
      nameserver[1] : 192.168.1.254
      if_index : 11 (en0)
      flags    : Request A records, Request AAAA records
      order    : 200000

    resolver #3
      domain   : local
      options  : mdns
      flags    : Request A records, Request AAAA records
      order    : 300000

    resolver #4
      domain   : 254.169.in-addr.arpa
      options  : mdns
      order    : 300200

    DNS configuration (for scoped queries)

    resolver #1
      nameserver[0] : 192.168.1.254
      if_index : 11 (en0)
      flags    : Scoped, Request A records
    """
    private let vpnAndDNS = """
    DNS configuration

    resolver #1
      nameserver[0] : 198.18.0.2
      flags    : Request A records, Request AAAA records

    resolver #2
      domain   : local
      options  : mdns
      order    : 300000
    """
    private let off = """
    DNS configuration

    resolver #1
      search domain[0] : attlocal.net
      nameserver[0] : 2600:1700:6e0:be0::1
      nameserver[1] : 192.168.1.254
      if_index : 11 (en0)
      flags    : Request A records, Request AAAA records
    """
    private let ours = "198.18.0.2"

    func testTheRealOutputIsParsedAndStopsAtTheScopedPart() {
        let r = SystemResolverParser.parse(dnsOnly)
        XCTAssertEqual(r.count, 4, "the scoped block is not part of the list")
        XCTAssertEqual(r[0].nameservers, ["198.18.0.2"]); XCTAssertEqual(r[0].interface, "utun10"); XCTAssertEqual(r[0].order, 106400); XCTAssertTrue(r[0].supplemental)
        XCTAssertEqual(r[1].nameservers.count, 2); XCTAssertEqual(r[1].interface, "en0")
        XCTAssertEqual(r[2].domain, "local")
    }

    func testTheNormalStatesAreIntact() {
        XCTAssertEqual(TamperWatch.assess(resolvers: SystemResolverParser.parse(dnsOnly), ourServer: ours, dnsExpected: true, vpnExpected: false, defaultInterface: "en0"), .intact)
        XCTAssertEqual(TamperWatch.assess(resolvers: SystemResolverParser.parse(vpnAndDNS), ourServer: ours, dnsExpected: true, vpnExpected: true, defaultInterface: "utun10"), .intact)
        XCTAssertEqual(TamperWatch.assess(resolvers: SystemResolverParser.parse(off), ourServer: ours, dnsExpected: false, vpnExpected: false, defaultInterface: "en0"), .intact, "nothing is expected, so nothing is wrong")
    }

    func testOurResolverDisappearingIsReported() {
        XCTAssertEqual(TamperWatch.assess(resolvers: SystemResolverParser.parse(off), ourServer: ours, dnsExpected: true, vpnExpected: false, defaultInterface: "en0"), .resolverMissing)
    }

    func testAnotherResolverTakingPrecedenceIsReportedByInterfaceNotAddress() {
        let hijacked = dnsOnly.replacingOccurrences(of: "order    : 200000", with: "order    : 100000")
        let verdict = TamperWatch.assess(resolvers: SystemResolverParser.parse(hijacked), ourServer: ours, dnsExpected: true, vpnExpected: false, defaultInterface: "en0")
        XCTAssertEqual(verdict, .resolverOutranked(by: "en0"))
        XCTAssertFalse(verdict.message!.contains("192.168"), "the alert never prints addresses")
    }

    func testLocalNameResolversDoNotCountAsTakingOver() {
        let mdnsFirst = dnsOnly.replacingOccurrences(of: "order    : 300000", with: "order    : 1000")
        XCTAssertEqual(TamperWatch.assess(resolvers: SystemResolverParser.parse(mdnsFirst), ourServer: ours, dnsExpected: true, vpnExpected: false, defaultInterface: "en0"), .intact, ".local is answered by mDNS on purpose")
    }

    func testAVPNWhoseTrafficLeavesAnotherWayIsReported() {
        XCTAssertEqual(TamperWatch.assess(resolvers: SystemResolverParser.parse(vpnAndDNS), ourServer: ours, dnsExpected: true, vpnExpected: true, defaultInterface: "en0"), .routeLeftTunnel(to: "en0"))
        XCTAssertEqual(TamperWatch.assess(resolvers: [], ourServer: ours, dnsExpected: true, vpnExpected: false, defaultInterface: nil), .unknown, "an unreadable list is not an accusation")
    }

    func testAnAlertNeedsTheSameVerdictTwiceAndIsNotRepeated() {
        let bad = TamperVerdict.resolverMissing
        XCTAssertFalse(TamperWatch.shouldAlert(previous: nil, current: bad, alreadyAlerted: nil), "the first sighting may be a network change settling")
        XCTAssertTrue(TamperWatch.shouldAlert(previous: bad, current: bad, alreadyAlerted: nil))
        XCTAssertFalse(TamperWatch.shouldAlert(previous: bad, current: bad, alreadyAlerted: bad), "once is enough")
        XCTAssertFalse(TamperWatch.shouldAlert(previous: bad, current: .intact, alreadyAlerted: nil))
    }
}
