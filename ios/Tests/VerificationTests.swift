import Foundation

@main struct VerificationTests {
    @MainActor static func main() throws {
        var count = 0
        func check(_ value: Bool) { precondition(value); count += 1 }
        check(ExitComparison.evaluate(observed: "203.0.113.1", expected: "203.0.113.1", family: 4) == .matched)
        check(ExitComparison.evaluate(observed: "203.0.113.2", expected: "203.0.113.1", family: 4) == .mismatch)
        check(ExitComparison.evaluate(observed: "2001:db8::1", expected: "2001:0db8:0:0:0:0:0:1", family: 6) == .matched)
        check(ExitComparison.evaluate(observed: "203.0.113.2", expected: "203.0.113.1, 203.0.113.2", family: 4) == .matched)
        check(ExitComparison.evaluate(observed: nil, expected: "203.0.113.1", family: 4) == .unavailable)
        check(ExitComparison.evaluate(observed: "203.0.113.1", expected: "", family: 4) == .missing)
        check(ExitComparison.evaluate(observed: "203.0.113.1", expected: "not-an-ip", family: 4) == .unavailable)
        check(DNSFilterObservation.verdict(control: [], target: [.blocked, .blocked]) == .inconclusive)
        check(DNSFilterObservation.verdict(control: [.blocked, .blocked], target: [.blocked, .blocked]) == .inconclusive)
        check(DNSFilterObservation.verdict(control: [.resolved, .resolved], target: [.blocked, .blocked]) == .passed)
        check(DNSFilterObservation.verdict(control: [.resolved, .absent], target: [.blocked, .absent]) == .passed)
        check(DNSFilterObservation.verdict(control: [.resolved, .resolved], target: [.blocked, .resolved]) == .failed)
        check(DNSFilterObservation.verdict(control: [.resolved, .resolved], target: [.blocked, .inconclusive]) == .inconclusive)
        check(DNSFilterObservation.verdict(control: [.absent, .absent], target: [.blocked, .blocked]) == .inconclusive)
        func parse(_ json: String, _ provider: DNSProviderSite) -> ProviderVerdict { ProviderVerificationProbe.parse(Data(json.utf8), provider: provider).0 }
        check(parse("{\"status\":\"ok\",\"profile\":\"secret-id\",\"srcIP\":\"private-ip\"}", .nextDNS) == .detected)
        check(parse("{\"status\":\"unconfigured\"}", .nextDNS) == .inconclusive)
        check(parse("{\"status\":\"ko\"}", .nextDNS) == .notDetected)
        check(parse("{\"status\":\"new-schema\"}", .nextDNS) == .inconclusive)
        check(parse("<html>OK</html>", .nextDNS) == .inconclusive)
        check(parse("{\"server_name\":\"regular_1\",\"protocol\":\"doh-h2\"}", .adguard) == .detected)
        check(parse("{\"server_name\":\"unexpected\",\"protocol\":\"doh\"}", .adguard) == .inconclusive)
        check(parse("{\"server_name\":\"regular\",\"protocol\":\"invented\"}", .adguard) == .inconclusive)
        check(parse("<h1>YES</h1>", .quad9) == .detected)
        check(parse("<h1>NO</h1>", .quad9) == .notDetected)
        check(parse("<p>You might see YES or NO</p>", .quad9) == .inconclusive)
        check(ProviderVerificationProbe.parse(Data(repeating: 65, count: ProviderVerificationProbe.maximumBytes + 1), provider: .nextDNS).0 == .inconclusive)
        check(ProviderVerificationProbe.nextDNSHandoff(Data("xhr.open('GET', 'https://abc123.test.nextdns.io/', false)".utf8))?.host == "abc123.test.nextdns.io")
        check(ProviderVerificationProbe.nextDNSHandoff(Data("https://test.nextdns.io.evil.example/".utf8)) == nil)
        check(ProviderVerificationProbe.nextDNSHandoff(Data("https://user:secret@abc.test.nextdns.io/".utf8)) == nil)
        check(DNSProviderSite.selected(endpoint: "https://dns.controld.com/private-token") == .controlD)
        check(DNSProviderSite.selected(endpoint: "https://dns.controld.com.evil.example/token") == nil)
        check(DNSProviderSite.selected(endpoint: "tls://dns.quad9.net") == .quad9)
        check(DNSProviderSite.providers.count == 5)
        let redacted = ProviderVerificationProbe.parse(Data("{\"server_name\":\"clients_secret\",\"protocol\":\"dot-tls\",\"device_id\":\"secret-id\"}".utf8), provider: .adguard).1
        check(!redacted.contains("secret"))
        let name = "controlled.example.com"; let id: UInt16 = 42
        var reply = Array(try DNSService.queryForDomain(id: id, domain: name)); reply[2] = 0x81; reply[3] = 0x83
        check(try DNSFilterObservation.parse(Data(reply), id: id, domain: name, type: .a) == .blocked)
        reply[3] = 0x80
        check(try DNSFilterObservation.parse(Data(reply), id: id, domain: name, type: .a) == .absent)
        reply[7] = 1; reply += [0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 30, 0, 4, 0, 0, 0, 0]
        check(try DNSFilterObservation.parse(Data(reply), id: id, domain: name, type: .a) == .blocked)
        reply[reply.count - 1] = 1
        check(try DNSFilterObservation.parse(Data(reply), id: id, domain: name, type: .a) == .resolved)
        do { _ = try DNSFilterObservation.parse(Data(reply), id: id+1, domain: name, type: .a); preconditionFailure("Accepted wrong transaction") } catch { count += 1 }
        do { _ = try DNSFilterObservation.parse(Data(reply.dropLast()), id: id, domain: name, type: .a); preconditionFailure("Accepted truncation") } catch { count += 1 }
        do { _ = try DNSFilterObservation.parse(Data(reply), id: id, domain: "other.example.com", type: .a); preconditionFailure("Accepted wrong question") } catch { count += 1 }
        do { _ = try DNSFilterObservation.parse(Data(reply), id: id, domain: name, type: .aaaa); preconditionFailure("Accepted wrong family") } catch { count += 1 }
        let verification = ConnectionVerification()
        verification.run(connected: true, captureBaseline: true)
        check(!verification.running && verification.baseline == nil && verification.message.contains("Disconnect"))
        verification.run(connected: false, captureBaseline: true, network: "Network unavailable")
        check(!verification.running && verification.baseline == nil)
        let date = Date()
        let ipv4 = IPProbeResult(family: .ipv4, address: "203.0.113.1", attempts: [], failure: nil)
        let ipv6 = IPProbeResult(family: .ipv6, address: nil, attempts: [], failure: IPFailure(kind: .connectivity, detail: "No IPv6 path"))
        let baseline = VerificationSample(date: date, connected: false, ipv4Result: ipv4, ipv6Result: ipv6, controlDEvidence: nil, network: "Wi-Fi available")
        let fresh = VerificationSample(date: date.addingTimeInterval(60), connected: true, ipv4Result: ipv4, ipv6Result: ipv6, controlDEvidence: nil, network: "Wi-Fi available")
        let stale = VerificationSample(date: date.addingTimeInterval(901), connected: true, ipv4Result: ipv4, ipv6Result: ipv6, controlDEvidence: nil, network: "Wi-Fi available")
        let cellular = VerificationSample(date: date.addingTimeInterval(60), connected: true, ipv4Result: ipv4, ipv6Result: ipv6, controlDEvidence: nil, network: "Cellular available")
        check(ConnectionVerification.baselineAddress(sample: fresh, baseline: baseline, family: 4) == "203.0.113.1")
        check(ConnectionVerification.baselineAddress(sample: stale, baseline: baseline, family: 4) == nil)
        check(ConnectionVerification.baselineAddress(sample: cellular, baseline: baseline, family: 4) == nil)
        check(ConnectionVerification.baselineAddress(sample: fresh, baseline: fresh, family: 4) == nil)
        let historical = FilteringResult(id: UUID(), profileID: UUID(), category: "Ads", domain: "controlled.example.com", verdict: .inconclusive, detail: "No control")
        let recovered = try JSONDecoder().decode(FilteringResult.self, from: JSONEncoder().encode(historical))
        check(recovered.targetMeasurements == nil && recovered.referenceMeasurements == nil)
        let measurement = DNSFilterMeasurement(recordType: "A", date: date, milliseconds: 20, observation: .blocked, responseCode: 3, error: nil)
        check(measurement.description.contains("RCODE 3") && measurement.description.contains("20 ms"))
        print("Passed \(count) verification and DNS-filter evidence checks.")
    }
}
