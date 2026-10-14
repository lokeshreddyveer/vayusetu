import Foundation
import Network

@main struct DNSOnlyTests {
    static var count = 0
    static func check(_ condition: Bool, _ line: Int = #line) { if !condition { fatalError("DNSOnlyTests failed at line \(line)") }; count += 1 }

    /// IPv4/UDP datagram from 198.18.0.1:`port` to `destination`:`destinationPort` carrying `payload`.
    static func datagram(payload: [UInt8], port: UInt16 = 51_000, destination: [UInt8] = DNSTunnelAddress.serverBytes, destinationPort: UInt16 = 53, proto: UInt8 = 17, flagsFragment: [UInt8] = [0x40, 0]) -> Data {
        let udp = 8 + payload.count, total = 20 + udp
        var p = [UInt8](repeating: 0, count: total)
        p[0] = 0x45; p[2] = UInt8(total >> 8); p[3] = UInt8(total & 255); p[6] = flagsFragment[0]; p[7] = flagsFragment[1]; p[8] = 64; p[9] = proto
        p.replaceSubrange(12..<16, with: [198, 18, 0, 1]); p.replaceSubrange(16..<20, with: destination)
        p[20] = UInt8(port >> 8); p[21] = UInt8(port & 255); p[22] = UInt8(destinationPort >> 8); p[23] = UInt8(destinationPort & 255)
        p[24] = UInt8(udp >> 8); p[25] = UInt8(udp & 255)
        p.replaceSubrange(28..<total, with: payload)
        return Data(p)
    }
    static let query: [UInt8] = [0xab, 0xcd, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0, 7, 101, 120, 97, 109, 112, 108, 101, 3, 99, 111, 109, 0, 0, 1, 0, 1]

    static func main() async throws {
        // Query parsing
        let parsed = DNSPacketCodec.parseQuery(datagram(payload: query))
        check(parsed?.payload == Data(query) && parsed?.sourcePort == 51_000 && parsed?.source == [198, 18, 0, 1])
        check(DNSPacketCodec.parseQuery(datagram(payload: query, destination: [8, 8, 8, 8])) == nil)
        check(DNSPacketCodec.parseQuery(datagram(payload: query, destinationPort: 853)) == nil)
        check(DNSPacketCodec.parseQuery(datagram(payload: query, proto: 6)) == nil)
        check(DNSPacketCodec.parseQuery(datagram(payload: query, flagsFragment: [0x20, 0])) == nil)   // more fragments
        check(DNSPacketCodec.parseQuery(datagram(payload: query, flagsFragment: [0x00, 1])) == nil)   // fragment offset
        check(DNSPacketCodec.parseQuery(datagram(payload: Array(query.prefix(8)))) == nil)             // shorter than a DNS header
        check(DNSPacketCodec.parseQuery(Data([0x60, 0, 0, 0])) == nil && DNSPacketCodec.parseQuery(Data()) == nil)
        var truncated = datagram(payload: query); truncated.removeLast(5)
        check(DNSPacketCodec.parseQuery(truncated) == nil)

        // Response construction and checksums
        let answer: [UInt8] = [0xab, 0xcd, 0x81, 0x80] + [UInt8](repeating: 0, count: 8)
        let reply = DNSPacketCodec.response(for: parsed!, payload: Data(answer))!
        let r = [UInt8](reply)
        check(r.count == 28 + answer.count && r[0] == 0x45 && r[9] == 17)
        check(Array(r[12..<16]) == DNSTunnelAddress.serverBytes && Array(r[16..<20]) == [198, 18, 0, 1])
        check(DNSPacketCodec.checksum(Array(r[0..<20])) == 0)  // a valid header checksums to zero
        check(r[20] == 0 && r[21] == 53 && Int(r[22]) << 8 | Int(r[23]) == 51_000)
        let udp = Int(r[24]) << 8 | Int(r[25])
        check(udp == 8 + answer.count)
        let pseudo = Array(r[12..<20]) + [0, 17, UInt8(udp >> 8), UInt8(udp & 255)] + Array(r[20...])
        check(DNSPacketCodec.checksum(pseudo) == 0)
        check(Array(r[28...]) == answer)
        check(DNSPacketCodec.response(for: parsed!, payload: Data(repeating: 0, count: DNSPacketCodec.maximumPayload + 1)) == nil)
        check(DNSPacketCodec.response(for: parsed!, payload: Data(repeating: 0, count: 5)) == nil)
        // Odd-length payloads still checksum correctly
        let odd = DNSPacketCodec.response(for: parsed!, payload: Data(answer + [9]))!
        let o = [UInt8](odd); let oddUDP = Int(o[24]) << 8 | Int(o[25])
        check(DNSPacketCodec.checksum(Array(o[12..<20]) + [0, 17, UInt8(oddUDP >> 8), UInt8(oddUDP & 255)] + Array(o[20...])) == 0)

        // Fail-closed answer and reply validation
        let servfail = DNSPacketCodec.servfail(for: Data(query))!
        check(servfail.count == 12 && servfail[0] == 0xab && servfail[1] == 0xcd && servfail[2] & 0x80 != 0 && servfail[3] & 0x0f == 2)
        check(DNSPacketCodec.servfail(for: Data([1, 2])) == nil)
        check((try? DNSPacketCodec.validateReply(Data(answer), query: Data(query))) != nil)
        check((try? DNSPacketCodec.validateReply(Data([0, 0, 0x81, 0x80] + [UInt8](repeating: 0, count: 8)), query: Data(query))) == nil)  // wrong id
        check((try? DNSPacketCodec.validateReply(Data([0xab, 0xcd, 0x01, 0x00] + [UInt8](repeating: 0, count: 8)), query: Data(query))) == nil) // not a response

        // DoT framing
        let framed = DNSUpstreamWire.dotFrame(Data(query))
        check(framed.count == query.count + 2 && Int(framed[0]) << 8 | Int(framed[1]) == query.count)
        check(DNSUpstreamWire.parseDoT(Data()) == .incomplete && DNSUpstreamWire.parseDoT(framed.prefix(10)) == .incomplete)
        check(DNSUpstreamWire.parseDoT(framed) == .complete(Data(query)))
        check(DNSUpstreamWire.parseDoT(framed + Data([1, 2, 3])) == .complete(Data(query)))
        check(DNSUpstreamWire.parseDoT(Data([0, 4, 1, 2, 3, 4])) == .invalid)

        // DoH request and reply
        let request = String(decoding: DNSUpstreamWire.dohRequest(host: "dns.example", path: "/dns-query/abc", query: Data(query)), as: UTF8.self)
        check(request.hasPrefix("POST /dns-query/abc HTTP/1.1\r\nHost: dns.example\r\n") && request.contains("Content-Length: \(query.count)\r\n") && request.contains("Connection: close"))
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/dns-message\r\nContent-Length: \(answer.count)\r\n\r\n"
        let body = Data(answer)
        check(DNSUpstreamWire.parseDoH(Data(head.utf8)) == .incomplete)
        check(DNSUpstreamWire.parseDoH(Data(head.utf8) + body.prefix(5)) == .incomplete)
        check(DNSUpstreamWire.parseDoH(Data(head.utf8) + body) == .complete(body))
        check(DNSUpstreamWire.parseDoH(Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n".utf8)) == .invalid)
        check(DNSUpstreamWire.parseDoH(Data("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 20\r\n\r\n".utf8) + Data(repeating: 0, count: 20)) == .invalid)
        check(DNSUpstreamWire.parseDoH(Data("HTTP/1.1 200 OK\r\nContent-Type: application/dns-message\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) == .invalid)
        check(DNSUpstreamWire.parseDoH(Data("HTTP/1.1 200 OK\r\nContent-Type: application/dns-message\r\n\r\n".utf8)) == .invalid)
        check(DNSUpstreamWire.parseDoH(Data(repeating: 65, count: 20_000)) == .invalid)

        // Upstream configuration: bootstrap addresses are mandatory and validated
        let doh = try DNSUpstreamConfiguration(endpoint: URL(string: "https://dns.example/dns-query/abc")!, addresses: ["9.9.9.9", "2620:fe::fe"])
        check(doh.kind == .doh(path: "/dns-query/abc") && doh.host == "dns.example" && doh.addresses.count == 2)
        let dot = try DNSUpstreamConfiguration(endpoint: URL(string: "tls://dns.example")!, addresses: ["9.9.9.9"])
        check(dot.kind == .dot)
        check((try? DNSUpstreamConfiguration(endpoint: URL(string: "https://dns.example/q")!, addresses: [])) == nil)
        check((try? DNSUpstreamConfiguration(endpoint: URL(string: "https://dns.example/q")!, addresses: ["127.0.0.1"])) == nil)
        check((try? DNSUpstreamConfiguration(endpoint: URL(string: "http://dns.example/q")!, addresses: ["9.9.9.9"])) == nil)

        // Runtime: the in-flight bound drops excess queries and counts every event
        let runtime = DNSOnlyRuntime(upstream: DNSUpstreamClient(doh)) { _ in }
        runtime.stop()
        runtime.handle(datagram(payload: query))
        check(runtime.snapshot == DNSOnlyCounters())  // a stopped runtime observes nothing

        // Question parsing and the NXDOMAIN block response
        let q = DNSPacketCodec.question(of: Data(query))!
        check(q.name == "example.com" && q.type == 1 && q.end == query.count)
        let upper: [UInt8] = [0xab, 0xcd, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 3, 65, 68, 83, 3, 67, 79, 77, 0, 0, 28, 0, 1]
        check(DNSPacketCodec.question(of: Data(upper))?.name == "ads.com" && DNSPacketCodec.question(of: Data(upper))?.type == 28)
        check(DNSPacketCodec.question(of: Data([UInt8](query.prefix(14)))) == nil)                       // truncated name
        check(DNSPacketCodec.question(of: Data([0xab, 0xcd, 0x81, 0, 0, 1] + [UInt8](repeating: 0, count: 12))) == nil) // a response, not a query
        var pointer = query; pointer[12] = 0xc0
        check(DNSPacketCodec.question(of: Data(pointer)) == nil)                                          // compression is never valid here
        let blocked = [UInt8](DNSPacketCodec.blockedResponse(for: Data(query), questionEnd: q.end)!)
        check(blocked[0] == 0xab && blocked[1] == 0xcd && blocked[2] & 0x80 != 0 && blocked[3] & 0x0f == 3)   // QR, NXDOMAIN
        check(blocked[5] == 1 && blocked[7] == 0 && Array(blocked[12...]) == Array(query[12...]))             // question echoed, no answers
        check((try? DNSPacketCodec.validateReply(Data(blocked), query: Data(query))) != nil)
        // CNAME uncloaking: parse alias targets from a compressed reply
        func labels(_ name: String) -> [UInt8] { name.split(separator: ".").flatMap { [UInt8($0.utf8.count)] + Array($0.utf8) } + [0] }
        var alias: [UInt8] = [0x12, 0x34, 0x81, 0x80, 0, 1, 0, 2, 0, 0, 0, 0] + labels("metrics.example.com") + [0, 1, 0, 1]
        alias += [0xC0, 12, 0, 5, 0, 1, 0, 0, 0, 60]
        let target = labels("Collector.Tracker-CDN.net")
        alias += [UInt8(target.count >> 8), UInt8(target.count & 255)]
        let targetOffset = alias.count
        alias += target + [0xC0 | UInt8(targetOffset >> 8), UInt8(targetOffset & 255), 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 1, 2, 3, 4]
        check(DNSPacketCodec.cnameTargets(of: Data(alias)) == ["collector.tracker-cdn.net"])
        check(DNSPacketCodec.cnameTargets(of: Data([1, 2, 3])).isEmpty)
        for n in 0..<alias.count { _ = DNSPacketCodec.cnameTargets(of: Data(alias.prefix(n))) }       // no truncation may crash
        let cut = [UInt8](DNSPacketCodec.truncated(for: Data(query))!)
        check(cut[0] == 0xab && cut[2] & 0x80 != 0 && cut[2] & 0x02 != 0 && cut[3] & 0x0f == 0)           // oversize answer: QR + TC, NOERROR
        check(cut[5] == 1 && cut[7] == 0 && Array(cut[12...]) == Array(query[12...]))                       // question echoed, no answers

        // Rule snapshot: suffix, exact, allow-wins, encoding round trip
        func h(_ s: String) -> UInt64 { DNSRuleSnapshot.hash(s) }
        var rules = DNSRuleSnapshot()
        rules.blockSuffix = [h("ads.example"), h("tracker.net")]; rules.blockExact = [h("exact.org")]; rules.allowSuffix = [h("ok.tracker.net")]; rules.allowExact = [h("www.ads.example")]
        check(rules.decide("ads.example") == .block && rules.decide("x.y.ads.example") == .block)
        check(rules.decide("notads.example") == .noMatch && rules.decide("example") == .noMatch)
        check(rules.decide("exact.org") == .block && rules.decide("sub.exact.org") == .noMatch)           // exact entries do not cover subdomains
        check(rules.decide("www.ads.example") == .allow && rules.decide("ok.tracker.net") == .allow && rules.decide("a.ok.tracker.net") == .allow)
        check(rules.decide("tracker.net") == .block && rules.decide("other.tracker.net") == .block)
        check(DNSRuleSnapshot().decide("ads.example") == .noMatch && rules.decide("") == .noMatch)
        // Cross-language fixture: the Go DNS filter must read exactly what the app writes (see dnsfilter_test.go).
        if let path = ProcessInfo.processInfo.environment["VS_RULE_FIXTURE"] { try rules.encoded().write(to: URL(fileURLWithPath: path)) }
        let restored = try DNSRuleSnapshot.decode(rules.encoded())
        check(restored == rules && restored.count == 5)
        check((try? DNSRuleSnapshot.decode(Data("junk".utf8))) == nil)
        check((try? DNSRuleSnapshot.decode(rules.encoded().dropLast(3))) == nil)                          // truncated file is rejected
        var bad = rules.encoded(); bad[8] = 0xff; bad[9] = 0xff; bad[10] = 0xff                           // inflated count
        check((try? DNSRuleSnapshot.decode(bad)) == nil)

        // Runtime with rules: a blocked query is answered locally and counted; nothing is sent upstream
        var written: [Data] = []; let writeLock = NSLock()
        let filtering = DNSOnlyRuntime(upstream: DNSUpstreamClient(doh), rules: { var r = DNSRuleSnapshot(); r.blockSuffix = [h("example.com")]; return r }()) { packet in writeLock.lock(); written.append(packet); writeLock.unlock() }
        filtering.handle(datagram(payload: query))
        let counters = filtering.snapshot
        check(counters.queries == 1 && counters.blocked == 1 && counters.answered == 0 && counters.failed == 0 && counters.rules == 1)
        writeLock.lock(); check(written.count == 1); let echoed = DNSPacketCodec.parseQuery(Data()); _ = echoed
        let out = [UInt8](written[0]); writeLock.unlock()
        check(out[28 + 3] & 0x0f == 3 && Int(out[22]) << 8 | Int(out[23]) == 51_000)                    // NXDOMAIN to the asking port
        filtering.replaceRules(DNSRuleSnapshot())
        check(filtering.snapshot.rules == 0)

        // LocalDNSProbe against a local UDP responder: a blocked name must read as NXDOMAIN, a normal name as a real answer.
        let answerQueue = DispatchQueue(label: "test.udp")
        let listener = try NWListener(using: .udp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: answerQueue)
            connection.receiveMessage { data, _, _, _ in
                guard let data, let q = DNSPacketCodec.question(of: data) else { return }
                let b = [UInt8](data)
                let reply: Data
                if q.name == "blocked.example" { reply = DNSPacketCodec.blockedResponse(for: data, questionEnd: q.end)! }
                else { reply = Data([b[0], b[1], 0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0] + b[12..<q.end] + [0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 93, 184, 216, 34]) }
                connection.send(content: reply, completion: .idempotent)
            }
        }
        let port: UInt16 = await withCheckedContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { state in
                if case .ready = state, !resumed, let value = listener.port?.rawValue { resumed = true; continuation.resume(returning: value) }
            }
            listener.start(queue: answerQueue)
        }
        let (blockedID, blockedReply) = try await LocalDNSProbe.exchange(domain: "blocked.example", server: "127.0.0.1", port: port)
        check([UInt8](blockedReply)[3] & 0x0f == 3 && UInt16([UInt8](blockedReply)[0]) << 8 | UInt16([UInt8](blockedReply)[1]) == blockedID)
        let (okID, okReply) = try await LocalDNSProbe.exchange(domain: "example.com", server: "127.0.0.1", port: port)
        check(try DNSService.validateReply(okReply, id: okID, domain: "example.com") == 1)
        var unreachable = false
        do { _ = try await LocalDNSProbe.exchange(domain: "example.com", server: "127.0.0.1", port: 9, timeout: 1) } catch { unreachable = true }
        check(unreachable)    // nothing listening: an honest failure, never a pass
        listener.cancel()

        // Shared stats stay backward compatible
        let legacy = try JSONDecoder().decode(TunnelStats.self, from: JSONEncoder().encode(TunnelStats()))
        check(legacy.dnsCounters == nil)
        check(try JSONDecoder().decode(TunnelSecret.self, from: Data("{\"wireguard\":\"\",\"resolver\":\"tls://dns.example\",\"mode\":\"vpnFirst\"}".utf8)).runtime == nil)
        // Backup resolver: used only when the main one fails; cancellation never reaches it
        final class Stub: DNSUpstreaming, @unchecked Sendable {
            let reply: Data?; var calls = 0
            init(_ reply: Data?) { self.reply = reply }
            func exchange(_ query: Data) async throws -> Data { calls += 1; if let reply { return reply }; throw URLError(.cannotConnectToHost) }
        }
        let good = Stub(Data([1, 2, 3])), dead = Stub(nil), spare = Stub(Data([9]))
        check(try await FallbackUpstream(primary: good, backup: spare).exchange(Data()) == Data([1, 2, 3]) && spare.calls == 0)
        check(try await FallbackUpstream(primary: dead, backup: spare).exchange(Data()) == Data([9]) && dead.calls == 1)
        var bothFailed = false
        do { _ = try await FallbackUpstream(primary: dead, backup: Stub(nil)).exchange(Data()) } catch { bothFailed = true }
        check(bothFailed)
        // Tunnel health verdicts
        var wg = TunnelStats(); wg.received = 5_000; wg.sent = 2_000; wg.latestHandshake = Date().addingTimeInterval(-30)
        check(TunnelHealth.assess(running: false, connected: false, kind: "WireGuard", stats: nil, statsAge: nil, uptime: nil).verdict == .off)
        check(TunnelHealth.assess(running: true, connected: false, kind: "WireGuard", stats: nil, statsAge: nil, uptime: nil).verdict == .starting)
        check(TunnelHealth.assess(running: true, connected: true, kind: "IKEv2", stats: nil, statsAge: nil, uptime: 60).verdict == .limited)
        check(TunnelHealth.assess(running: true, connected: true, kind: "WireGuard", stats: wg, statsAge: 60, uptime: 60).verdict == .starting)   // stale numbers are not evidence
        check(TunnelHealth.assess(running: true, connected: true, kind: "WireGuard", stats: wg, statsAge: 2, uptime: 60).verdict == .healthy)
        wg.latestHandshake = nil
        check(TunnelHealth.assess(running: true, connected: true, kind: "WireGuard", stats: wg, statsAge: 2, uptime: 60).verdict == .down)
        check(TunnelHealth.assess(running: true, connected: true, kind: "WireGuard", stats: wg, statsAge: 2, uptime: 5).verdict != .down)
        wg.latestHandshake = Date().addingTimeInterval(-600)
        check(TunnelHealth.assess(running: true, connected: true, kind: "WireGuard", stats: wg, statsAge: 2, uptime: 900).verdict == .degraded)
        var dns = TunnelStats(); dns.dnsCounters = DNSOnlyCounters()
        check(TunnelHealth.assess(running: true, connected: true, kind: "Local DNS", stats: dns, statsAge: 2, uptime: 60).verdict == .limited)
        dns.dnsCounters?.queries = 10; dns.dnsCounters?.answered = 10
        check(TunnelHealth.assess(running: true, connected: true, kind: "Local DNS", stats: dns, statsAge: 2, uptime: 60).verdict == .healthy)
        dns.dnsCounters?.answered = 0; dns.dnsCounters?.failed = 10
        check(TunnelHealth.assess(running: true, connected: true, kind: "Local DNS", stats: dns, statsAge: 2, uptime: 60).verdict == .down)
        print("DNS-only runtime checks passed: \(count)")
    }
}
