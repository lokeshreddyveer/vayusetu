import Foundation
import Network
import Security

// All completion paths run on one queue: timeout, cancellation and network callbacks cannot resume twice.
final class DNSOverTLSRequest: @unchecked Sendable {
    private let queue = DispatchQueue(label: "VayuSetu.DoTProbe")
    private let connection: NWConnection
    private var continuation: CheckedContinuation<Data, Error>?
    private var finished = false
    private let query: Data
    init(host: String, query: Data) {
        let tls = NWProtocolTLS.Options()
        host.withCString { sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, $0) }
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        // Use system certificate validation. Never override trust with an accept-all verification block.
        connection = NWConnection(host: NWEndpoint.Host(host), port: 853, using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        self.query = query
    }
    func run() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { callback in
                queue.async {
                    if self.finished { callback.resume(throwing: CancellationError()); return }
                    self.continuation = callback
                    self.connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            var framed = Data([UInt8(self.query.count >> 8), UInt8(self.query.count & 255)]); framed.append(self.query)
                            self.connection.send(content: framed, completion: .contentProcessed { error in
                                if error != nil { self.finish(.failure(AppIssue(message: "TLS DNS send failed."))) }
                                else { self.receive(length: 2, buffer: Data(), header: true) }
                            })
                        case .failed: self.finish(.failure(AppIssue(message: "TLS DNS connection failed. Check the hostname and certificate.")))
                        case .cancelled: self.finish(.failure(CancellationError()))
                        default: break
                        }
                    }
                    self.connection.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + 12) { self.finish(.failure(AppIssue(message: "TLS DNS probe timed out."))) }
                }
            }
        } onCancel: { self.queue.async { self.finish(.failure(CancellationError())) } }
    }
    private func receive(length: Int, buffer: Data, header: Bool) {
        guard !finished else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: length - buffer.count) { data, _, complete, error in
            guard !self.finished else { return }
            var accumulated = buffer; if let data { accumulated.append(data) }
            if error != nil || (complete && accumulated.count < length) || data?.isEmpty != false {
                self.finish(.failure(AppIssue(message: "TLS DNS reply was interrupted."))); return
            }
            if accumulated.count < length { self.receive(length: length, buffer: accumulated, header: header); return }
            if header {
                let count = Int(accumulated[0]) * 256 + Int(accumulated[1])
                guard count >= 12 else { self.finish(.failure(AppIssue(message: "TLS DNS frame is invalid."))); return }
                self.receive(length: count, buffer: Data(), header: false)
            } else { self.finish(.success(accumulated)) }
        }
    }
    private func finish(_ outcome: Result<Data, Error>) {
        guard !finished else { return }; finished = true
        connection.stateUpdateHandler = nil; connection.cancel()
        continuation?.resume(with: outcome); continuation = nil
    }
}

/// Sends one UDP DNS query to the local DNS tunnel's virtual address, exactly as an app on this device would.
/// Routing decides the path: if the tunnel is up, the packet enters it and is answered (or blocked) by VayuSetu's runtime.
/// A reply therefore proves the on-device DNS path works; it says nothing about apps that use their own DNS.
enum LocalDNSProbe {
    static let virtualServer = "198.18.0.2"
    static func exchange(domain: String, type: DNSRecordType = .a, server: String = virtualServer, port: UInt16 = 53, timeout: TimeInterval = 3) async throws -> (UInt16, Data) {
        let id = UInt16.random(in: 0...65535)
        let query = try DNSService.queryForDomain(id: id, recordType: type, domain: domain)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw AppIssue(message: "Invalid DNS port.") }
        let connection = NWConnection(host: NWEndpoint.Host(server), port: nwPort, using: .udp)
        let queue = DispatchQueue(label: "VayuSetu.LocalDNSProbe")
        let reply: Data = try await withCheckedThrowingContinuation { continuation in
            var finished = false
            func finish(_ result: Result<Data, Error>) {
                queue.async {
                    guard !finished else { return }; finished = true
                    connection.stateUpdateHandler = nil; connection.cancel(); continuation.resume(with: result)
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: query, completion: .contentProcessed { error in
                        if error != nil { finish(.failure(AppIssue(message: "The local DNS address could not be reached."))); return }
                        connection.receiveMessage { data, _, _, error in
                            if let data, !data.isEmpty, error == nil { finish(.success(data)) } else { finish(.failure(AppIssue(message: "No answer from the local DNS address."))) }
                        }
                    })
                case .failed, .waiting: finish(.failure(AppIssue(message: "The local DNS address is unreachable. Is the tunnel running?")))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(.failure(AppIssue(message: "The local DNS address did not answer in time."))) }
        }
        return (id, reply)
    }
}
