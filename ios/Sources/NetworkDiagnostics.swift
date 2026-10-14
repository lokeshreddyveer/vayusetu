import Foundation
import Network
import Combine

@MainActor final class NetworkDiagnostics: ObservableObject {
    @Published var routeRevision = UUID()
    @Published var path = "Checking network…"
    @Published var exitIP = ""
    @Published var checkingIP = false
    @Published var ipv4Probe: IPProbeResult?
    @Published var ipv6Probe: IPProbeResult?
    @Published var counterEvidence = ""
    @Published var supportsIPv6: Bool?
    private var ipTask: Task<Void, Never>?
    @Published var qualityRunning = false
    @Published var qualityHistory: [QualityResult] = []
    @Published var qualityMessage = ""
    @Published var networkDetails = ""
    private var qualityTask: Task<Void, Never>?
    private var qualityWritable = true
    private let monitor = NWPathMonitor()
    private var pathSignature = ""
    init() {
        let url = LocalFiles.url("quality-history.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do { qualityHistory = Array(try JSONDecoder().decode([QualityResult].self, from: LocalFiles.read(url, maximum: 128_000)).prefix(30)) }
            catch { qualityWritable = false; qualityMessage = "Stored diagnostic history could not be read; the file has been preserved." }
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let label: String
            if path.status != .satisfied { label = "Network unavailable" }
            else if path.usesInterfaceType(.wifi) { label = "Wi-Fi available" }
            else if path.usesInterfaceType(.cellular) { label = "Cellular available" }
            else { label = "Network available" }
            let details = "IPv4: \(path.supportsIPv4 ? "available" : "unavailable") · IPv6: \(path.supportsIPv6 ? "available" : "unavailable")\n\(path.isExpensive ? "Metered network" : "Unmetered network") · \(path.isConstrained ? "Low Data Mode" : "Standard data mode")"
            let signature = "\(path.status)-\(path.supportsIPv4)-\(path.supportsIPv6)-\(path.supportsDNS)-\(path.isExpensive)-\(path.isConstrained)-" + path.availableInterfaces.map { "\($0.type)-\($0.index)-\($0.name)" }.sorted().joined(separator: ",") + path.gateways.map { String(describing: $0) }.sorted().joined(separator: ",")
            Task { @MainActor in
                guard let self else { return }
                self.path = label; self.networkDetails = details; self.supportsIPv6 = path.supportsIPv6
                // NWPathMonitor can repeat an equivalent path update. Discard
                // measurements only when the observed route properties change.
                if self.pathSignature != signature {
                    self.pathSignature = signature; self.routeRevision = UUID()
                    self.invalidateIP()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "VayuSetu.NetworkPath"))
    }
    deinit { monitor.cancel(); qualityTask?.cancel() }
    func runQuality(status: String) {
        guard !qualityRunning else { return }
        let revision = routeRevision
        qualityRunning = true; qualityMessage = "Running 5 HTTPS checks…"
        qualityTask = Task { [weak self] in
            guard let self else { return }
            defer { self.qualityRunning = false; self.qualityTask = nil }
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil; config.httpCookieStorage = nil; config.timeoutIntervalForResource = 10
            let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var timings: [Double] = []; var failures = 0
            for _ in 0..<5 {
                if Task.isCancelled { self.qualityMessage = "Check cancelled; partial results were discarded."; return }
                do {
                    var request = URLRequest(url: URL(string: "https://api64.ipify.org?format=json&probe=" + UUID().uuidString)!)
                    request.timeoutInterval = 8; request.cachePolicy = .reloadIgnoringLocalCacheData
                    let start = ContinuousClock.now
                    let (bytes, response) = try await session.bytes(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppIssue(message: "Probe failed.") }
                    var size = 0
                    for try await _ in bytes { size += 1; guard size <= 4096 else { throw AppIssue(message: "Reply exceeds limit.") } }
                    let duration = start.duration(to: .now).components
                    timings.append(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
                } catch { failures += 1 }
            }
            guard !Task.isCancelled, revision == self.routeRevision else { self.qualityMessage = "Network changed or check cancelled; partial results were discarded."; return }
            let result = QualityResult(id: UUID(), date: Date(), status: status, milliseconds: timings, failures: failures)
            self.qualityHistory.insert(result, at: 0); self.qualityHistory = Array(self.qualityHistory.prefix(30))
            self.qualityMessage = "Check complete. Results describe HTTPS requests from this app."
            if self.qualityWritable {
                do { try LocalFiles.write(JSONEncoder().encode(self.qualityHistory), to: LocalFiles.url("quality-history.json")) }
                catch { self.qualityMessage = "Check complete; local history could not be saved." }
            }
        }
    }
    func cancelQuality() { qualityTask?.cancel() }

    // MARK: Speed test
    /// Latency, download and upload against Cloudflare's public speed servers. Runs only when the user taps it, sends no identifiers, and keeps
    /// the results on this device so VPN-on and VPN-off runs can be compared.
    @Published var speedRunning = false
    @Published var speedHistory: [SpeedResult] = []
    @Published var speedMessage = ""
    @Published var speedPhase = ""
    private var speedTask: Task<Void, Never>?
    private var speedWritable = true
    private func loadSpeedHistory() {
        let url = LocalFiles.url("speed-history.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { speedHistory = Array(try JSONDecoder().decode([SpeedResult].self, from: LocalFiles.read(url, maximum: 128_000)).prefix(20)) }
        catch { speedWritable = false; speedMessage = "Stored speed results could not be read; the file has been preserved." }
    }
    func cancelSpeed() { speedTask?.cancel() }
    func runSpeed(status: String) {
        guard !speedRunning else { return }
        if speedHistory.isEmpty { loadSpeedHistory() }
        let revision = routeRevision
        speedRunning = true; speedMessage = ""; speedPhase = "Measuring latency…"
        speedTask = Task { [weak self] in
            guard let self else { return }
            defer { self.speedRunning = false; self.speedPhase = ""; self.speedTask = nil }
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil; config.httpCookieStorage = nil; config.timeoutIntervalForResource = 25
            let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            func request(_ path: String, method: String = "GET") -> URLRequest {
                var r = URLRequest(url: URL(string: "https://speed.cloudflare.com/" + path)!)
                r.httpMethod = method; r.cachePolicy = .reloadIgnoringLocalCacheData; r.timeoutInterval = 15; return r
            }
            // Latency: the median of five tiny requests (the first one pays for the TLS handshake and is dropped).
            var times: [Double] = []
            for index in 0..<6 {
                if Task.isCancelled { self.speedMessage = "Speed test cancelled."; return }
                let start = ContinuousClock.now
                if (try? await session.data(for: request("__down?bytes=0"))) != nil, index > 0 {
                    let d = start.duration(to: .now).components; times.append(Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15)
                }
            }
            let latency = times.sorted().isEmpty ? nil : times.sorted()[times.count / 2]
            // Download: count bytes for up to 8 seconds.
            self.speedPhase = "Measuring download…"
            var down: Double?
            do {
                // Counting in a delegate is far faster than iterating a 60 MB body one byte at a time, which would cap the result.
                let meter = DownloadMeter(limit: .seconds(8))
                let measured = try await meter.run(session: session, request: request("__down?bytes=60000000"))
                if measured.seconds > 0.2 { down = Double(measured.bytes) / measured.seconds }
            } catch { if Task.isCancelled { self.speedMessage = "Speed test cancelled."; return } }
            // Upload: one 8 MB body.
            self.speedPhase = "Measuring upload…"
            var up: Double?
            do {
                var post = request("__up", method: "POST"); post.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                let body = Data(count: 8_000_000); let start = ContinuousClock.now
                _ = try await session.upload(for: post, from: body)
                let d = start.duration(to: .now).components; let seconds = Double(d.seconds) + Double(d.attoseconds) / 1e18
                if seconds > 0.2 { up = Double(body.count) / seconds }
            } catch { if Task.isCancelled { self.speedMessage = "Speed test cancelled."; return } }
            guard revision == self.routeRevision else { self.speedMessage = "The network changed during the test, so the result was discarded."; return }
            guard down != nil || up != nil else { self.speedMessage = "No speed measured. The speed server could not be reached on this connection."; return }
            let result = SpeedResult(id: UUID(), date: Date(), status: status, downBytesPerSecond: down, upBytesPerSecond: up, latencyMs: latency)
            self.speedHistory.insert(result, at: 0); self.speedHistory = Array(self.speedHistory.prefix(20))
            self.speedMessage = "Done. This is the speed from this device to Cloudflare’s nearest server, through the current connection."
            if self.speedWritable { do { try LocalFiles.write(JSONEncoder().encode(self.speedHistory), to: LocalFiles.url("speed-history.json")) } catch { self.speedMessage = "Done; the result could not be saved." } }
        }
    }
    func clearSpeedHistory() {
        guard !speedRunning else { return }
        try? FileManager.default.removeItem(at: LocalFiles.url("speed-history.json")); speedHistory = []; speedWritable = true
    }
    func clearQualityHistory() {
        guard !qualityRunning else { return }
        do {
            let url = LocalFiles.url("quality-history.json")
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            qualityHistory = []; qualityWritable = true; qualityMessage = "Diagnostic history cleared."
        } catch { qualityMessage = "Could not remove stored history." }
    }
    var sanitizedReport: String {
        struct Report: Encodable { let version: Int; let results: [QualityResult] }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(Report(version: 1, results: qualityHistory))).flatMap { String(data: $0, encoding: .utf8) } ?? "Report unavailable."
    }
    static func probeIP(family: Int) async throws -> String {
        guard let value = IPFamily(rawValue: family) else { throw IPFailure(kind: .family, detail: "Unsupported address family.") }
        let result = await PublicIPProbe.run(value)
        guard let address = result.address else { throw result.failure ?? IPFailure(kind: .other, detail: "No successful public IP response.") }
        return address
    }
    func invalidateIP() { ipTask?.cancel(); ipv4Probe = nil; ipv6Probe = nil; exitIP = ""; counterEvidence = "" }
    func checkIP(status: String, compareLegacy: Bool = false, counterSample: (() -> TunnelCounterSample?)? = nil, policyEvidence: String = "") {
        guard !checkingIP else { return }
        checkingIP = true; ipv4Probe = nil; ipv6Probe = nil; exitIP = "Checking IPv4 and IPv6 independently…"
        let before = counterSample?(); counterEvidence = ""
        let revision = routeRevision; let ipv6 = supportsIPv6
        try? LocalFiles.write(Data("Started: \(Date().formatted(.iso8601))\nNetwork: \(path)\nStart state: \(status)\nIn progress; no current measurements.".utf8), to: LocalFiles.url("last-ip-diagnostic.txt"))
        ipTask = Task {
            defer { checkingIP = false; ipTask = nil }
            async let v4 = PublicIPProbe.run(.ipv4)
            async let v6 = PublicIPProbe.run(.ipv6, ipv6Supported: ipv6)
            let results = await (v4, v6)
            let legacy4 = compareLegacy ? await PublicIPProbe.legacyControl(family: .ipv4) : nil
            let legacy6 = compareLegacy ? await PublicIPProbe.legacyControl(family: .ipv6) : nil
            guard !Task.isCancelled, routeRevision == revision else { exitIP = "Network changed during the check. Rerun it."; try? LocalFiles.write(Data("Invalidated: \(Date().formatted(.iso8601))\nNetwork or tunnel changed during measurement; no current result.".utf8), to: LocalFiles.url("last-ip-diagnostic.txt")); return }
            counterEvidence = TunnelCounterSample.compare(before, counterSample?())
            ipv4Probe = results.0; ipv6Probe = results.1
            exitIP = [results.0, results.1].map { result in "IPv\(result.family.rawValue): \(result.address ?? result.failure?.kind.rawValue ?? "Inconclusive")\n\(result.detail)" }.joined(separator: "\n\n") + "\nStarted while: \(status). Public IP discovery does not verify VPN exit identity, DNS routing or leak protection."
            let report = "Measured: \(Date().formatted(.iso8601))\nNetwork: \(path)\nStart state: \(status)\n" + [results.0, results.1].map { "IPv\($0.family.rawValue): \($0.address == nil ? "no address" : "address received")\n\($0.detail)" }.joined(separator: "\n")
            let control = [legacy4, legacy6].compactMap { $0 }.map { "\nLegacy control: \($0.endpointURL ?? "unknown") · \($0.milliseconds) ms · \($0.failure?.errorDescription ?? "Address response received")" }.joined()
            try? LocalFiles.write(Data((report + control + "\n" + counterEvidence + "\n" + policyEvidence).utf8), to: LocalFiles.url("last-ip-diagnostic.txt"))
        }
    }

}

struct QualityResult: Codable, Identifiable {
    let id: UUID
    let date: Date
    let status: String
    let milliseconds: [Double]
    let failures: Int
    var mean: Double? { milliseconds.isEmpty ? nil : milliseconds.reduce(0, +) / Double(milliseconds.count) }
    var jitter: Double? {
        guard milliseconds.count > 1 else { return nil }
        return zip(milliseconds, milliseconds.dropFirst()).map { abs($0 - $1) }.reduce(0, +) / Double(milliseconds.count - 1)
    }
    var failurePercent: Double { Double(failures) / Double(max(1, failures + milliseconds.count)) * 100 }
}

struct SpeedResult: Codable, Identifiable {
    let id: UUID
    let date: Date
    /// What was running when it was measured, e.g. "Connected" or "Disconnected".
    let status: String
    let downBytesPerSecond: Double?
    let upBytesPerSecond: Double?
    let latencyMs: Double?
}

struct TrafficPoint: Identifiable {
    let id = UUID()
    let date: Date
    let received: Double
    let sent: Double
}

struct ConnectionEvent: Codable, Identifiable {
    enum Severity: String, Codable { case info, warning, error }
    let id: UUID
    let timestamp: Date
    let session: UUID?
    let severity: Severity
    let category: String
    let message: String
    var display: String { "\(timestamp.formatted(date: .omitted, time: .standard)) · \(severity.rawValue.uppercased()) · \(message)" }
}

enum LocalFiles {
    static func url(_ name: String) -> URL {
        let directory = (Bundle.main.object(forInfoDictionaryKey: "VayuStorageDirectory") as? String) ?? "VayuSetu"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(directory).appendingPathComponent(name)
    }
    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func read(_ url: URL, maximum: Int) throws -> Data {
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard attributes.isRegularFile == true, (attributes.fileSize ?? Int.max) <= maximum else { throw AppIssue(message: "Local file is invalid or too large.") }
        return try Data(contentsOf: url)
    }
}

struct TunnelCounterSample {
    let date: Date
    let received: UInt64
    let sent: UInt64
    static func compare(_ before: Self?, _ after: Self?) -> String {
        guard let before, let after, after.date > before.date, after.received >= before.received, after.sent >= before.sent else {
            return "Counter correlation inconclusive: missing, unchanged or reset samples. No packet-path proof."
        }
        return "Tunnel samples \(before.date.formatted(.iso8601)) → \(after.date.formatted(.iso8601)): \(after.received - before.received) received bytes, \(after.sent - before.sent) sent bytes. Concurrent traffic may contribute. Activity does not prove DNS routing or isolation."
    }
}

/// Counts downloaded bytes as they arrive and stops after a time limit.
final class DownloadMeter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0, first: ContinuousClock.Instant?, failure: Error?
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDataTask?
    private let limit: Duration
    init(limit: Duration) { self.limit = limit }
    func run(session: URLSession, request: URLRequest) async throws -> (bytes: Int, seconds: Double) {
        let delegate = self
        let local = URLSession(configuration: session.configuration, delegate: delegate, delegateQueue: nil)
        defer { local.invalidateAndCancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock(); continuation = c; lock.unlock()
                let t = local.dataTask(with: request); task = t; t.resume()
            }
        } onCancel: { task?.cancel() }
        lock.lock(); defer { lock.unlock() }
        guard let first else { throw URLError(.timedOut) }
        let d = first.duration(to: .now).components
        return (bytes, Double(d.seconds) + Double(d.attoseconds) / 1e18)
    }
    private func finish(_ error: Error?) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(with: error.map { .failure($0) } ?? .success(()))
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler((response as? HTTPURLResponse)?.statusCode == 200 ? .allow : .cancel)
    }
    private var began: ContinuousClock.Instant?
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        if first == nil { first = .now; began = .now }
        bytes += data.count
        let over = began.map { $0.duration(to: .now) > limit } ?? false
        lock.unlock()
        if over { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let enough = bytes > 0; lock.unlock()
        // A cancel after the time limit is the normal end of the test, not a failure.
        finish((error as? URLError)?.code == .cancelled && enough ? nil : error)
    }
}
