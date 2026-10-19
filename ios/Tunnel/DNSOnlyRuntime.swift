import Foundation
import Network

// ADR-011 spike: a local DNS-only tunnel. Only the virtual DNS address below is routed into the
// tunnel, so ordinary traffic is never captured. Queries are forwarded to the selected resolver
// over DoT/DoH, connecting to bootstrap IP addresses directly: resolving the resolver's hostname
// would send a query back into this tunnel. No plaintext fallback exists; failure is SERVFAIL.
// Limits of this spike: IPv4/UDP DNS only (no TCP/IPv6 transport), no cache, no filtering yet.

enum DNSTunnelAddress {
    static let interface = "198.18.0.1"
    static let server = "198.18.0.2"
    static let serverBytes: [UInt8] = [198, 18, 0, 2]
    static let mtu = 1400
}

struct DNSPacketQuery: Equatable {
    let source: [UInt8]
    let sourcePort: UInt16
    let payload: Data
}

enum DNSPacketCodec {
    /// Largest DNS payload that fits the tunnel MTU after the IPv4 and UDP headers.
    static let maximumPayload = DNSTunnelAddress.mtu - 28

    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0; var index = 0
        while index + 1 < bytes.count { sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1]); index += 2 }
        if index < bytes.count { sum += UInt32(bytes[index]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum & 0xffff)
    }

    /// Accepts only an unfragmented IPv4/UDP datagram for port 53 of the virtual DNS server.
    static func parseQuery(_ packet: Data) -> DNSPacketQuery? {
        let b = [UInt8](packet)
        guard b.count >= 28, b[0] >> 4 == 4 else { return nil }
        let headerLength = Int(b[0] & 0x0f) * 4
        let total = Int(b[2]) << 8 | Int(b[3])
        guard headerLength >= 20, total <= b.count, total >= headerLength + 8, b[9] == 17,
              b[6] & 0x3f == 0, b[7] == 0, Array(b[16..<20]) == DNSTunnelAddress.serverBytes else { return nil }
        let destinationPort = Int(b[headerLength + 2]) << 8 | Int(b[headerLength + 3])
        let udpLength = Int(b[headerLength + 4]) << 8 | Int(b[headerLength + 5])
        guard destinationPort == 53, udpLength >= 8 + 12, headerLength + udpLength <= total else { return nil }
        let payload = Data(b[(headerLength + 8)..<(headerLength + udpLength)])
        return DNSPacketQuery(source: Array(b[12..<16]), sourcePort: UInt16(b[headerLength]) << 8 | UInt16(b[headerLength + 1]), payload: payload)
    }

    /// Builds the IPv4/UDP datagram that answers `query` from the virtual DNS server.
    static func response(for query: DNSPacketQuery, payload: Data) -> Data? {
        guard payload.count >= 12, payload.count <= maximumPayload else { return nil }
        let udpLength = 8 + payload.count, total = 20 + udpLength
        var p = [UInt8](repeating: 0, count: total)
        p[0] = 0x45; p[2] = UInt8(total >> 8); p[3] = UInt8(total & 255)
        p[6] = 0x40; p[8] = 64; p[9] = 17
        p.replaceSubrange(12..<16, with: DNSTunnelAddress.serverBytes)
        p.replaceSubrange(16..<20, with: query.source)
        let header = checksum(Array(p[0..<20])); p[10] = UInt8(header >> 8); p[11] = UInt8(header & 255)
        p[21] = 53; p[22] = UInt8(query.sourcePort >> 8); p[23] = UInt8(query.sourcePort & 255)
        p[24] = UInt8(udpLength >> 8); p[25] = UInt8(udpLength & 255)
        p.replaceSubrange(28..<total, with: [UInt8](payload))
        let pseudo = Array(p[12..<20]) + [0, 17, UInt8(udpLength >> 8), UInt8(udpLength & 255)] + Array(p[20..<total])
        var udp = checksum(pseudo); if udp == 0 { udp = 0xffff }
        p[26] = UInt8(udp >> 8); p[27] = UInt8(udp & 255)
        return Data(p)
    }

    /// The single question of a standard query: lowercase name without trailing dot, type, and where the question ends.
    /// Pointers are not valid in a query's question, so any compression byte makes the query "unparseable" (it is then forwarded, never blocked).
    static func question(of payload: Data) -> (name: String, type: UInt16, end: Int)? {
        let b = [UInt8](payload)
        guard b.count >= 17, b[2] & 0xf8 == 0, b[4] == 0, b[5] == 1 else { return nil }   // QR=0, opcode 0, one question
        var labels: [String] = []; var offset = 12; var length = 0
        while true {
            guard offset < b.count else { return nil }
            let n = Int(b[offset])
            if n == 0 { offset += 1; break }
            guard n <= 63, offset + 1 + n <= b.count else { return nil }
            length += n + 1; guard length <= 254 else { return nil }
            labels.append(String(decoding: b[(offset + 1)..<(offset + 1 + n)], as: UTF8.self).lowercased())
            offset += 1 + n
        }
        guard !labels.isEmpty, offset + 4 <= b.count else { return nil }
        return (labels.joined(separator: "."), UInt16(b[offset]) << 8 | UInt16(b[offset + 1]), offset + 4)
    }
    /// A possibly compressed name at `offset`, lowercase without a trailing dot, and the offset just after it.
    static func name(in b: [UInt8], at start: Int) -> (name: String, next: Int)? {
        var labels: [String] = []; var offset = start; var next = -1
        for _ in 0..<64 {
            guard offset < b.count else { return nil }
            let n = Int(b[offset])
            if n == 0 { return (labels.joined(separator: ".").lowercased(), next >= 0 ? next : offset + 1) }
            if n & 0xC0 == 0xC0 {
                guard offset + 1 < b.count else { return nil }
                if next < 0 { next = offset + 2 }
                offset = (n & 0x3F) << 8 | Int(b[offset + 1]); continue
            }
            guard n & 0xC0 == 0, offset + 1 + n <= b.count else { return nil }
            labels.append(String(decoding: b[(offset + 1)..<(offset + 1 + n)], as: UTF8.self)); offset += 1 + n
        }
        return nil
    }
    /// The alias targets (CNAME records) in a reply's answer section, in order.
    static func cnameTargets(of reply: Data) -> [String] {
        let b = [UInt8](reply)
        guard b.count >= 12, b[2] & 0x80 != 0 else { return [] }
        let questions = Int(b[4]) << 8 | Int(b[5]), answers = Int(b[6]) << 8 | Int(b[7])
        var offset = 12
        for _ in 0..<questions { guard let n = name(in: b, at: offset), n.next + 4 <= b.count else { return [] }; offset = n.next + 4 }
        var targets: [String] = []
        for _ in 0..<answers {
            guard let n = name(in: b, at: offset), n.next + 10 <= b.count else { return targets }
            let type = Int(b[n.next]) << 8 | Int(b[n.next + 1]), length = Int(b[n.next + 8]) << 8 | Int(b[n.next + 9]), data = n.next + 10
            guard data + length <= b.count else { return targets }
            if type == 5, let target = name(in: b, at: data), !target.name.isEmpty { targets.append(target.name) }
            offset = data + length
        }
        return targets
    }
    /// Name-level block: NXDOMAIN for every record type, echoing the question (RFC 1035). Apps treat this as "does not exist".
    static func blockedResponse(for query: Data, questionEnd: Int) -> Data? {
        guard query.count >= questionEnd, questionEnd > 12 else { return nil }
        let b = [UInt8](query)
        return Data([b[0], b[1], 0x81, 0x83, 0, 1, 0, 0, 0, 0, 0, 0] + b[12..<questionEnd])
    }

    /// A reply that cannot fit one tunnel packet is answered with the truncated flag and just the question, so the client
    /// sees a real answer instead of waiting for a datagram that was silently dropped.
    static func truncated(for query: Data) -> Data? {
        guard query.count >= 12, let end = question(of: query)?.end, end <= query.count else { return nil }
        let b = [UInt8](query)
        return Data([b[0], b[1], 0x83, 0x80, 0, 1, 0, 0, 0, 0, 0, 0] + b[12..<end])
    }

    /// Fail-closed answer used when the encrypted upstream is unavailable.
    static func servfail(for query: Data) -> Data? {
        guard query.count >= 12 else { return nil }
        return Data([query[query.startIndex], query[query.startIndex + 1], 0x81, 0x82, 0, 0, 0, 0, 0, 0, 0, 0])
    }

    static func validateReply(_ reply: Data, query: Data) throws {
        guard reply.count >= 12, query.count >= 12, reply[reply.startIndex] == query[query.startIndex],
              reply[reply.startIndex + 1] == query[query.startIndex + 1], reply[reply.startIndex + 2] & 0x80 != 0 else {
            throw AppIssue(message: "Upstream returned an invalid DNS reply.")
        }
    }
}

enum DNSUpstreamWire {
    enum Parse: Equatable { case incomplete, complete(Data), invalid }
    static let maximumReply = 65_535

    static func dotFrame(_ query: Data) -> Data {
        var framed = Data([UInt8(query.count >> 8), UInt8(query.count & 255)]); framed.append(query); return framed
    }
    static func parseDoT(_ buffer: Data) -> Parse {
        guard buffer.count >= 2 else { return .incomplete }
        let length = Int(buffer[buffer.startIndex]) << 8 | Int(buffer[buffer.startIndex + 1])
        guard length >= 12 else { return .invalid }
        guard buffer.count >= 2 + length else { return .incomplete }
        return .complete(Data(buffer.dropFirst(2).prefix(length)))
    }
    static func dohRequest(host: String, path: String, query: Data) -> Data {
        var request = Data("POST \(path) HTTP/1.1\r\nHost: \(host)\r\nContent-Type: application/dns-message\r\nAccept: application/dns-message\r\nContent-Length: \(query.count)\r\nConnection: close\r\n\r\n".utf8)
        request.append(query); return request
    }
    /// A 200 application/dns-message reply with Content-Length; chunked encoding is not supported.
    static func parseDoH(_ buffer: Data) -> Parse {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return buffer.count > 16_384 ? .invalid : .incomplete }
        let lines = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        guard let status = lines.first, status.hasPrefix("HTTP/1.1 200") || status.hasPrefix("HTTP/1.0 200") else { return .invalid }
        var length: Int?; var typeOK = false
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "content-length": length = Int(parts[1])
            case "content-type": typeOK = parts[1].lowercased().hasPrefix("application/dns-message")
            case "transfer-encoding": return .invalid
            default: break
            }
        }
        guard typeOK, let length, (12...maximumReply).contains(length) else { return .invalid }
        let body = buffer[end.upperBound...]
        return body.count >= length ? .complete(Data(body.prefix(length))) : .incomplete
    }
}

struct DNSUpstreamConfiguration {
    enum Kind: Equatable { case dot, doh(path: String) }
    let host: String
    let kind: Kind
    let addresses: [String]
    init(endpoint: URL, addresses: [String]) throws {
        let validated = try DNSService.endpoint(endpoint.absoluteString)
        guard let host = validated.host else { throw AppIssue(message: "Resolver hostname is missing.") }
        self.host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        kind = validated.scheme?.lowercased() == "tls" ? .dot : .doh(path: validated.path)
        self.addresses = try ResolverBootstrap.validated(addresses)
    }
}

/// One TLS exchange with a fixed IP address; all completion paths run on one queue.
private final class TLSExchange: @unchecked Sendable {
    private let queue = DispatchQueue(label: "VayuSetu.DNSUpstream")
    private let connection: NWConnection
    private let request: Data
    private let parse: (Data) -> DNSUpstreamWire.Parse
    private var continuation: CheckedContinuation<Data, Error>?
    private var finished = false
    private var buffer = Data()
    init(address: String, port: UInt16, serverName: String, alpn: String?, request: Data, parse: @escaping (Data) -> DNSUpstreamWire.Parse) throws {
        let tls = NWProtocolTLS.Options()
        serverName.withCString { sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, $0) }
        if let alpn { alpn.withCString { sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, $0) } }
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        // System trust evaluation applies to the server name above; never accept-all.
        let host: NWEndpoint.Host
        if let v4 = IPv4Address(address) { host = .ipv4(v4) } else if let v6 = IPv6Address(address) { host = .ipv6(v6) } else { throw AppIssue(message: "Resolver bootstrap address is not an IP literal.") }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw AppIssue(message: "Invalid resolver port.") }
        connection = NWConnection(host: host, port: nwPort, using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        self.request = request; self.parse = parse
    }
    func run(timeout: TimeInterval = 5) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { callback in
                queue.async {
                    if self.finished { callback.resume(throwing: CancellationError()); return }
                    self.continuation = callback
                    self.connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            self.connection.send(content: self.request, completion: .contentProcessed { error in
                                if error != nil { self.finish(.failure(AppIssue(message: "Upstream send failed."))) } else { self.receive() }
                            })
                        case .failed, .waiting: self.finish(.failure(AppIssue(message: "Upstream TLS connection failed.")))
                        case .cancelled: self.finish(.failure(CancellationError()))
                        default: break
                        }
                    }
                    self.connection.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + timeout) { self.finish(.failure(AppIssue(message: "Upstream timed out."))) }
                }
            }
        } onCancel: { self.queue.async { self.finish(.failure(CancellationError())) } }
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, complete, error in
            guard !self.finished else { return }
            if let data { self.buffer.append(data) }
            guard self.buffer.count <= DNSUpstreamWire.maximumReply + 16_384 else { self.finish(.failure(AppIssue(message: "Upstream reply too large."))); return }
            switch self.parse(self.buffer) {
            case .complete(let reply): self.finish(.success(reply))
            case .invalid: self.finish(.failure(AppIssue(message: "Upstream reply was invalid.")))
            case .incomplete:
                if error != nil || complete { self.finish(.failure(AppIssue(message: "Upstream closed before a full reply."))) } else { self.receive() }
            }
        }
    }
    private func finish(_ outcome: Result<Data, Error>) {
        guard !finished else { return }; finished = true
        connection.stateUpdateHandler = nil; connection.cancel()
        continuation?.resume(with: outcome); continuation = nil
    }
}

/// Anything that can answer one DNS message over an encrypted transport. Failure means SERVFAIL, never plaintext.
protocol DNSUpstreaming: AnyObject, Sendable { func exchange(_ query: Data) async throws -> Data }

/// Swift/Network.framework client: DoT, and DoH over HTTP/1.1 only. Kept for host tests; the extension uses the Go client
/// (HTTP/2, connection reuse), because some resolvers (Quad9) reject HTTP/1.1.
final class DNSUpstreamClient: DNSUpstreaming, @unchecked Sendable {
    let configuration: DNSUpstreamConfiguration
    init(_ configuration: DNSUpstreamConfiguration) { self.configuration = configuration }
    func exchange(_ query: Data) async throws -> Data {
        var failure: Error = AppIssue(message: "No resolver address is available.")
        for address in configuration.addresses.prefix(4) {
            try Task.checkCancellation()
            do {
                let exchange: TLSExchange
                switch configuration.kind {
                case .dot:
                    exchange = try TLSExchange(address: address, port: 853, serverName: configuration.host, alpn: nil, request: DNSUpstreamWire.dotFrame(query), parse: DNSUpstreamWire.parseDoT)
                case .doh(let path):
                    exchange = try TLSExchange(address: address, port: 443, serverName: configuration.host, alpn: "http/1.1", request: DNSUpstreamWire.dohRequest(host: configuration.host, path: path, query: query), parse: DNSUpstreamWire.parseDoH)
                }
                let reply = try await exchange.run()
                try DNSPacketCodec.validateReply(reply, query: query)
                return reply
            } catch { failure = error }
        }
        throw failure
    }
}

/// Tries the main encrypted resolver, then the backup (also encrypted) if the main one fails. There is no plaintext step.
final class FallbackUpstream: DNSUpstreaming, @unchecked Sendable {
    private let primary: any DNSUpstreaming, backup: any DNSUpstreaming
    init(primary: any DNSUpstreaming, backup: any DNSUpstreaming) { self.primary = primary; self.backup = backup }
    func exchange(_ query: Data) async throws -> Data {
        do { return try await primary.exchange(query) }
        catch is CancellationError { throw CancellationError() }
        catch { return try await backup.exchange(query) }
    }
}

/// Receives raw packets from the tunnel, answers DNS queries and writes reply packets back.
final class DNSOnlyRuntime: @unchecked Sendable {
    static let maximumInFlight = 32
    private let upstream: any DNSUpstreaming
    private let write: (Data) -> Void
    private let lock = NSLock()
    private var inFlight = 0
    private var stopped = false
    private var counters = DNSOnlyCounters()
    private var rules: DNSRuleSnapshot?
    private var logging = false
    private var queryLog: [DNSQueryEntry] = []
    private var nextLogID: UInt64 = 1
    static let maximumLogged = 400
    /// `rules == nil` means filtering is off for this provider; an empty snapshot means it is on with nothing loaded.
    init(upstream: any DNSUpstreaming, rules: DNSRuleSnapshot? = nil, write: @escaping (Data) -> Void) { self.upstream = upstream; self.rules = rules; self.write = write; counters.rules = UInt64(rules?.count ?? 0) }
    var snapshot: DNSOnlyCounters { lock.lock(); defer { lock.unlock() }; return counters }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
    /// The lookup list lives in memory only; switching it off discards it.
    func setLogging(_ on: Bool) { lock.lock(); logging = on; if !on { queryLog.removeAll() }; lock.unlock() }
    func recentQueries(after id: UInt64) -> [DNSQueryEntry] { lock.lock(); defer { lock.unlock() }; return queryLog.filter { $0.id > id } }
    /// Call with the lock held.
    private func note(_ name: String, _ type: UInt16, _ result: String) {
        guard logging else { return }
        let label: String
        switch type { case 1: label = "A"; case 28: label = "AAAA"; case 5: label = "CNAME"; case 15: label = "MX"; case 16: label = "TXT"; case 65: label = "HTTPS"; case 12: label = "PTR"; default: label = "\(type)" }
        queryLog.append(DNSQueryEntry(id: nextLogID, time: Date(), name: name, type: label, result: result)); nextLogID += 1
        if queryLog.count > Self.maximumLogged { queryLog.removeFirst(queryLog.count - Self.maximumLogged) }
    }
    /// Atomically swaps the filter snapshot; in-flight queries keep the decision they already made.
    func replaceRules(_ new: DNSRuleSnapshot?) { lock.lock(); rules = new; counters.rules = UInt64(new?.count ?? 0); lock.unlock() }
    func handle(_ packet: Data) {
        guard let query = DNSPacketCodec.parseQuery(packet) else { return }
        lock.lock()
        if stopped { lock.unlock(); return }
        counters.queries += 1
        // Local rules first: a blocked name is answered here and never leaves the device.
        if let rules, let question = DNSPacketCodec.question(of: query.payload), rules.decide(question.name) == .block,
           let answer = DNSPacketCodec.blockedResponse(for: query.payload, questionEnd: question.end),
           let reply = DNSPacketCodec.response(for: query, payload: answer) {
            counters.blocked += 1; if rules.isThreat(question.name) { counters.threats += 1 }; note(question.name, question.type, "blocked"); lock.unlock(); write(reply); return
        }
        if inFlight >= Self.maximumInFlight { counters.dropped += 1; lock.unlock(); return }
        inFlight += 1; lock.unlock()
        let asked = DNSPacketCodec.question(of: query.payload)
        Task.detached { [self] in
            let answer: Data?
            var ok = true
            do { answer = try await upstream.exchange(query.payload) }
            catch { ok = false; answer = DNSPacketCodec.servfail(for: query.payload) }
            // An alias that leads to a blocked name is blocked too (tracker hidden behind a first-party name).
            if ok, let answer, let blockedReply = uncloakedAnswer(for: query, answer: answer) {
                if let asked { lock.lock(); note(asked.name, asked.type, "blocked"); lock.unlock() }
                if finishBlocked(), let packet = DNSPacketCodec.response(for: query, payload: blockedReply) { write(packet) }
                return
            }
            // A query counts as answered only after a validated upstream reply exists.
            if let asked { lock.lock(); note(asked.name, asked.type, ok ? "answered" : "failed"); lock.unlock() }
            guard complete(answered: ok), let answer else { return }
            if let packet = DNSPacketCodec.response(for: query, payload: answer) { write(packet) }
            else if answer.count > DNSPacketCodec.maximumPayload, let cut = DNSPacketCodec.truncated(for: query.payload),
                    let packet = DNSPacketCodec.response(for: query, payload: cut) { write(packet) }
        }
    }
    /// The blocked reply for a lookup whose answer is an alias to a blocked name, or nil. An explicit allow for the asked name wins.
    private func uncloakedAnswer(for query: DNSPacketQuery, answer: Data) -> Data? {
        lock.lock(); let snapshot = rules; lock.unlock()
        guard let snapshot, let question = DNSPacketCodec.question(of: query.payload), snapshot.decide(question.name) != .allow else { return nil }
        guard let target = DNSPacketCodec.cnameTargets(of: answer).first(where: { snapshot.decide($0) == .block }) else { return nil }
        lock.lock(); if snapshot.isThreat(target) { counters.threats += 1 }; lock.unlock()
        return DNSPacketCodec.blockedResponse(for: query.payload, questionEnd: question.end)
    }
    /// Counts a query that was answered by blocking it after the upstream replied. Returns whether the runtime is still live.
    private func finishBlocked() -> Bool {
        lock.lock(); defer { lock.unlock() }
        inFlight -= 1; counters.blocked += 1
        return !stopped
    }
    /// Returns whether the runtime is still live. Synchronous so locking stays out of async contexts.
    private func complete(answered: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        inFlight -= 1
        if answered { counters.answered += 1 } else { counters.failed += 1 }
        return !stopped
    }
}
