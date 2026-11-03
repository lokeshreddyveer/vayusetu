import SwiftUI
import VayuSetuCore

/// The four ways the Mac can be connected, as far as speed is concerned.
enum SpeedMode: String, CaseIterable, Codable, Identifiable {
    case direct, vpn, dns, both
    var id: String { rawValue }
    var title: String { switch self { case .direct: "No tunnel"; case .vpn: "VPN only"; case .dns: "DNS only"; case .both: "VPN + DNS" } }
    var icon: String { switch self { case .direct: "wifi"; case .vpn: "shield.lefthalf.filled"; case .dns: "globe"; case .both: "lock.shield" } }
    /// Whether a VPN carries the traffic in this mode, so the profile in use is part of what a result belongs to.
    var usesVPN: Bool { self == .vpn || self == .both }
}

struct SpeedTestResult: Codable, Equatable, Identifiable {
    var id = UUID()
    var mode: SpeedMode
    var down: Double          // bytes per second
    var up: Double
    var latencyMs: Double?
    var date: Date
    /// How the figure was measured, so a result can be judged: parallel connections and the seconds each direction was measured over.
    var streams = 0
    var seconds = 0.0
    var source = ""
    /// The conditions it was measured under (network, mode, server, method). Nil for results saved before this was recorded; those are shown but never compared.
    var context: SpeedContext? = nil
}

/// Watches the network port once a second, whatever is switched on, and keeps two separate things for each mode (see `SpeedBest`): the best speed TEST, which
/// is the mode's speed, and the highest ACTIVITY the port carried while watching, which is a peak and never a speed.
/// It reads the network interface counters only (nothing is sent anywhere), so it works with the VPN and DNS off.
/// The live figure is what crosses the Wi-Fi or Ethernet port, so with the VPN on it includes the tunnel's own overhead and everything else on the port.
@MainActor final class SpeedTracker: ObservableObject {
    static let shared = SpeedTracker()
    @Published private(set) var down = 0.0
    @Published private(set) var up = 0.0
    @Published private(set) var mode: SpeedMode?
    /// The best speeds and activity peaks, kept for each mode on each network and VPN profile separately (see `SpeedBestBook`).
    @Published private(set) var book = SpeedBestBook()
    /// The identity of the connection in use now (nil when the router cannot be identified), refreshed every few seconds.
    @Published private(set) var networkKey: String?
    private var profile: @MainActor () -> String? = { nil }
    private var identityAge = 100
    @Published private(set) var last: SpeedTestResult?
    /// The most recent tests, newest first, kept between launches.
    @Published private(set) var history: [SpeedTestResult] = []
    private var meter = InterfaceSpeedMeter()
    private var task: Task<Void, Never>?
    private var recent: [(down: Double, up: Double)] = []
    private var currentMode: @MainActor () -> SpeedMode? = { nil }
    private var lastSave = Date.distantPast
    private static let key = "speed-best-v2", oldKey = "speed-best-v1", historyKey = "speed-history-v1"
    static let historyLimit = 30

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key), let saved = try? JSONDecoder().decode(SpeedBestBook.self, from: data) {
            book = saved
        } else if let data = UserDefaults.standard.data(forKey: Self.oldKey), let saved = try? JSONDecoder().decode([String: SpeedBest].self, from: data) {
            // Bests saved before the network was recorded cannot be attributed to any connection. They are kept, and never shown as the speed of this one.
            book = SpeedBestBook.migrating(legacy: saved)
            if let data = try? JSONEncoder().encode(book) { UserDefaults.standard.set(data, forKey: Self.key) }
            UserDefaults.standard.removeObject(forKey: Self.oldKey)
        }
        if let data = UserDefaults.standard.data(forKey: Self.historyKey), let saved = try? JSONDecoder().decode([SpeedTestResult].self, from: data) {
            history = saved; last = saved.first
        }
    }

    /// Starts watching. `mode` returns nil while the connection is changing, and nothing is recorded then.
    func start(mode provider: @escaping @MainActor () -> SpeedMode?, profile profileProvider: @escaping @MainActor () -> String? = { nil }) {
        currentMode = provider; profile = profileProvider
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Where a figure for `mode` belongs: this network, and the VPN profile in use when a VPN carries the traffic.
    func key(for mode: SpeedMode) -> SpeedBestKey { SpeedBestKey(mode: mode.rawValue, network: networkKey, profile: mode.usesVPN ? profile() : nil) }
    /// The best for exactly this connection and mode, or nil. A figure measured elsewhere is never returned.
    func entry(for mode: SpeedMode) -> SpeedBestBook.Entry? { book.entry(for: key(for: mode)) }
    func profileToken() -> String? { profile() }
    /// Looks up the identity of the connection now, and drops the short average if it changed.
    func refreshIdentity() async {
        let fresh = await WiFiMonitor.shared.networkKeyNow()
        if fresh != networkKey { networkKey = fresh; recent.removeAll() }
    }

    private func tick() {
        identityAge += 1
        if identityAge >= 15 { identityAge = 0; Task { await refreshIdentity() } }
        let now = currentMode()
        if now != mode { recent.removeAll(); mode = now }
        guard let sample = meter.sample() else { return }
        if down != sample.down { down = sample.down }
        if up != sample.up { up = sample.up }
        guard let now else { return }
        // A three-second average, so one burst does not become the "top speed".
        recent.append(sample); if recent.count > 3 { recent.removeFirst() }
        guard recent.count == 3 else { return }
        let avgDown = recent.map(\.down).reduce(0, +) / 3, avgUp = recent.map(\.up).reduce(0, +) / 3
        var updated = book
        if updated.noteLive(key(for: now), down: avgDown, up: avgUp) { book = updated; saveSoon() }
    }

    /// How a result compares with earlier ones measured under the same conditions only (same network, mode, server, method and connection count).
    func verdict(for r: SpeedTestResult) -> SpeedVerdict {
        SpeedComparison.compare(SpeedSample(context: r.context, down: r.down, up: r.up, date: r.date), history: history.filter { $0.id != r.id }.map { SpeedSample(context: $0.context, down: $0.down, up: $0.up, date: $0.date) })
    }
    func record(_ result: SpeedTestResult) {
        last = result
        WiFiMonitor.shared.attachSpeed(down: result.down, seconds: result.seconds, at: result.date)
        history.insert(result, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        // The best belongs to the network and VPN profile the test was measured on, as recorded with it; a test with no identified network has no place to belong.
        let host = result.context?.endpoint
        var updated = book
        updated.noteTest(SpeedBestKey(mode: result.mode.rawValue, network: result.context?.networkKey, profile: result.context?.vpnProfile), down: result.down, up: result.up,
                         latencyMs: result.latencyMs, date: result.date, endpoint: host, method: result.context?.method)
        book = updated
        save()
    }

    /// Clears the best speeds, the history and the last result.
    func reset() { var cleared = book; cleared.clear(); book = cleared; last = nil; history = []; save() }

    private func saveSoon() { if Date().timeIntervalSince(lastSave) > 10 { save() } }
    private func save() {
        lastSave = Date()
        if let data = try? JSONEncoder().encode(book) { UserDefaults.standard.set(data, forKey: Self.key) }
        if let data = try? JSONEncoder().encode(history) { UserDefaults.standard.set(data, forKey: Self.historyKey) }
    }
}

/// An internet speed test: latency, then download, then upload, against Cloudflare's public speed endpoints.
/// It runs on whatever the Mac is using right now, so the result belongs to the current mode. It uses real data (roughly 8 seconds
/// of download and 6 of upload at full speed), so it only runs when asked.
@MainActor final class SpeedTest: ObservableObject {
    enum Phase: Equatable { case idle, latency, download, upload, done, failed(String) }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var liveRate = 0.0          // bytes per second during the current phase
    private var task: Task<Void, Never>?
    var running: Bool { [.latency, .download, .upload].contains(phase) }
    var phaseText: String {
        switch phase {
        case .latency: "Checking latency…"
        case .download: "Testing download…"
        case .upload: "Testing upload…"
        default: ""
        }
    }

    func start(mode: @escaping @MainActor () -> SpeedMode?, tracker: SpeedTracker) {
        guard !running else { return }
        guard let began = mode() else { phase = .failed("Wait for the connection to finish changing, then try again."); return }
        phase = .latency; liveRate = 0
        task = Task { [weak self] in
            guard let self else { return }
            let engine = SpeedEngine()
            defer { engine.close() }
            do {
                let startNetwork = await WiFiMonitor.shared.networkKeyNow()
                let latency = try await engine.latency()
                self.phase = .download
                let down = try await engine.download { rate in Task { @MainActor in self.liveRate = rate } }
                self.phase = .upload; self.liveRate = 0
                let up = try await engine.upload { rate in Task { @MainActor in self.liveRate = rate } }
                let endNetwork = await WiFiMonitor.shared.networkKeyNow()
                guard mode() == began, endNetwork == startNetwork else { self.phase = .failed("The connection changed during the test, so the result was not saved."); return }
                let host = down.source == "Apple" ? "mensura.cdn-apple.com" : "speed.cloudflare.com"
                let context = SpeedContext(networkKey: startNetwork, vpnOn: began.usesVPN, mode: began.rawValue, method: "http-download", endpoint: host,
                                           transport: "https", streams: down.streams, metered: WiFiMonitor.shared.path.expensive, vpnProfile: began.usesVPN ? tracker.profileToken() : nil)
                tracker.record(SpeedTestResult(mode: began, down: down.rate, up: up.rate, latencyMs: latency, date: Date(), streams: down.streams, seconds: down.seconds, source: down.source, context: context))
                self.phase = .done; self.liveRate = 0
            } catch is CancellationError {
                self.phase = .idle; self.liveRate = 0
            } catch {
                self.phase = .failed((error as? SpeedEngine.Failure)?.text ?? "The speed test could not finish. Check the connection and try again."); self.liveRate = 0
            }
        }
    }
    func cancel() { task?.cancel(); phase = .idle; liveRate = 0 }
}

/// The network side of the test. Several parallel connections, counted by what actually arrives or leaves, over a measured window.
///
/// Each worker has its own URLSession. One session multiplexes every request to a host over a single HTTP/2 connection, so a test run on one
/// session measures what one TCP connection can do, which on a fast or long path (a VPN, say) is far below the line. Separate sessions open
/// separate connections, as real speed tests do.
final class SpeedEngine: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    struct Failure: Error { let text: String }
    struct Measurement { let rate: Double; let streams: Int; let seconds: Double; let source: String }
    static let warmup = 2.0, measured = 7.0
    /// A test stops once it has moved this much, so a gigabit line does not spend a gigabyte on one test.
    static let downloadCap: Int64 = 600_000_000, uploadCap: Int64 = 300_000_000
    private let lock = NSLock()
    /// Each worker has its own session, and each session its own state (bytes and latest HTTP status). Nothing is shared between workers: a response to one is
    /// never read by another, and a late chunk from a cancelled run lands in that run's states, not the next run's.
    private var states: [ObjectIdentifier: SpeedStreamState] = [:]
    private var sessions: [URLSession] = []
    private let base = "https://speed.cloudflare.com/"

    /// One worker: its own session and its own state.
    private struct Stream { let session: URLSession; let state: SpeedStreamState }

    private func makeStreams(_ count: Int) -> [Stream] {
        let made = (0..<count).map { _ -> Stream in
            let c = URLSessionConfiguration.ephemeral
            c.requestCachePolicy = .reloadIgnoringLocalCacheData; c.timeoutIntervalForRequest = 15; c.httpMaximumConnectionsPerHost = 2
            c.waitsForConnectivity = false
            return Stream(session: URLSession(configuration: c, delegate: self, delegateQueue: nil), state: SpeedStreamState())
        }
        lock.lock(); for s in made { states[ObjectIdentifier(s.session)] = s.state; sessions.append(s.session) }; lock.unlock()
        return made
    }
    func close() { lock.lock(); let all = sessions; sessions = []; states = [:]; lock.unlock(); all.forEach { $0.invalidateAndCancel() } }
    /// The state of the worker that owns a session (nil after close, when late callbacks are ignored).
    private func state(of session: URLSession) -> SpeedStreamState? { lock.lock(); defer { lock.unlock() }; return states[ObjectIdentifier(session)] }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { state(of: session)?.add(bytes: Int64(data.count)) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            state(of: session)?.note(status: http.statusCode)
            completionHandler(http.statusCode == 200 ? .allow : .cancel)
        } else { completionHandler(.allow) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) { state(of: session)?.add(bytes: bytesSent) }

    /// Median time to the first byte of tiny requests on a warm connection, in milliseconds.
    func latency() async throws -> Double {
        let session = makeStreams(1)[0].session
        var times: [Double] = []
        for i in 0..<9 {
            try Task.checkCancellation()
            var request = URLRequest(url: URL(string: "https://speed.cloudflare.com/__down?bytes=0")!); request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let t0 = Date()
            guard let (_, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
            if i > 0 { times.append(Date().timeIntervalSince(t0) * 1000) }       // the first request carries the TLS handshake
        }
        guard !times.isEmpty else { throw Failure(text: "The speed service could not be reached.") }
        return times.sorted()[times.count / 2]
    }

    // MARK: Sources
    /// Cloudflare refuses a client that sends many requests in a short time (HTTP 429), so a test must use few, long transfers, never loops of small
    /// ones. Apple's public measurement servers (the ones behind `networkQuality`) serve one very large object per request, which is exactly that.
    private enum Source {
        case apple, cloudflare
        var name: String { self == .apple ? "Apple" : "Cloudflare" }
    }
    private let apple = "https://mensura.cdn-apple.com/api/v1/gm/"

    func download(rate: @escaping @Sendable (Double) -> Void) async throws -> Measurement {
        var reasons: [String] = []
        for source in [Source.apple, .cloudflare] {
            try Task.checkCancellation()
            if let m = try await runDownload(source, rate: rate, reasons: &reasons) { return m }
        }
        throw Failure(text: reasons.isEmpty ? "No data arrived during the download test." : "The download test got no data (" + reasons.joined(separator: "; ") + "). Check the connection, or try again in a minute.")
    }

    private func runDownload(_ source: Source, rate: @escaping @Sendable (Double) -> Void, reasons: inout [String]) async throws -> Measurement? {
        let streams = source == .apple ? 8 : 3
        let url = source == .apple ? URL(string: "https://mensura.cdn-apple.com/api/v1/gm/large")! : URL(string: "https://speed.cloudflare.com/__down?bytes=25000000")!
        let total = Self.warmup + Self.measured
        let run = makeStreams(streams)          // this run's workers: nothing from an earlier run can reach them
        let workers = run.map { stream in Task { [self] in
            let session = stream.session, state = stream.state
            let end = Date().addingTimeInterval(total + 1)
            // One long request per stream. If the server ends it early, start another (a few requests at most, never dozens).
            var starts = 0
            while Date() < end, !Task.isCancelled, starts < 6 {
                starts += 1
                var request = URLRequest(url: url); request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                let task = session.dataTask(with: request); task.resume()
                while task.state == .running || task.state == .suspended, Date() < end, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(30)) }
                if task.state != .completed { task.cancel() }
                if state.shouldStop { break }          // only this worker's own refusal stops it
            }
        } }
        defer { workers.forEach { $0.cancel() } }
        let states = run.map(\.state)
        let result = try await window(pick: { SpeedStreamReport.totalBytes(states) }, cap: Self.downloadCap, live: rate)
        if result.rate > 0 { return Measurement(rate: result.rate, streams: streams, seconds: result.seconds, source: source.name) }
        reasons.append(SpeedStreamReport.describe(source: source.name, statuses: states.map(\.status)))
        return nil
    }

    func upload(rate: @escaping @Sendable (Double) -> Void) async throws -> Measurement {
        var reasons: [String] = []
        for source in [Source.cloudflare, .apple] {
            try Task.checkCancellation()
            if let m = try await runUpload(source, rate: rate, reasons: &reasons) { return m }
        }
        throw Failure(text: "The upload test got no data (" + reasons.joined(separator: "; ") + "). Check the connection, or try again in a minute.")
    }

    private func runUpload(_ source: Source, rate: @escaping @Sendable (Double) -> Void, reasons: inout [String]) async throws -> Measurement? {
        let streams = 3
        let url = source == .apple ? URL(string: "https://mensura.cdn-apple.com/api/v1/gm/slurp")! : URL(string: "https://speed.cloudflare.com/__up")!
        let body = Data(count: 25_000_000)                               // big bodies: few requests, so no request limit is reached
        let total = Self.warmup + Self.measured
        let run = makeStreams(streams)
        let workers = run.map { stream in Task { [self] in
            let session = stream.session, state = stream.state
            let end = Date().addingTimeInterval(total + 1)
            var starts = 0
            while Date() < end, !Task.isCancelled, starts < 8 {
                starts += 1
                var request = URLRequest(url: url); request.httpMethod = "POST"
                let task = session.uploadTask(with: request, from: body); task.resume()
                while task.state == .running || task.state == .suspended, Date() < end, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(30)) }
                if task.state != .completed { task.cancel() }
                if state.shouldStop { break }
            }
        } }
        defer { workers.forEach { $0.cancel() } }
        let states = run.map(\.state)
        let result = try await window(pick: { SpeedStreamReport.totalBytes(states) }, cap: Self.uploadCap, live: rate)
        if result.rate > 0 { return Measurement(rate: result.rate, streams: streams, seconds: result.seconds, source: source.name) }
        reasons.append(SpeedStreamReport.describe(source: source.name, statuses: states.map(\.status)))
        return nil
    }

    /// Bytes per second over the measured part of the run: the first seconds (connections opening, slow start) are left out, and the clock
    /// stops when the run ends or the byte cap is reached, so the rate is always bytes divided by the time they really took.
    private func window(pick: @escaping () -> Int64, cap: Int64, live: @Sendable (Double) -> Void) async throws -> (rate: Double, seconds: Double) {
        let start = Date()
        var markTime: Date?, markBytes: Int64 = 0
        var previous = (Date(), pick())
        var last = (time: Date(), bytes: Int64(0))
        while Date().timeIntervalSince(start) < Self.warmup + Self.measured {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(200))
            let now = Date(), bytes = pick()
            let dt = now.timeIntervalSince(previous.0)
            if dt > 0 { live(Double(bytes - previous.1) / dt) }
            previous = (now, bytes)
            if markTime == nil, now.timeIntervalSince(start) >= Self.warmup { markTime = now; markBytes = bytes }
            last = (now, bytes)
            if markTime != nil, bytes >= cap { break }
        }
        guard let markTime else { return (0, 0) }
        let elapsed = last.time.timeIntervalSince(markTime)
        return elapsed > 0.5 ? (Double(last.bytes - markBytes) / elapsed, elapsed) : (0, 0)
    }
}

/// The Home panel: a live speed readout, the speed-test pill, and the highest speed seen in each mode.
struct MacSpeedPanel: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    @ObservedObject var tracker: SpeedTracker
    @StateObject private var test = SpeedTest()
    @State private var confirmMetered = false

    private var currentMode: SpeedMode? { store.speedMode }

    var body: some View {
        MacPanel("Internet speed", icon: "speedometer", trailing: { testPill }) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 18) {
                    MacSpeedGauge(value: test.running && test.phase != .latency ? test.liveRate : tracker.down, best: currentMode.flatMap { tracker.entry(for: $0)?.best.topDown } ?? 0)
                    VStack(alignment: .leading, spacing: 14) {
                        MacFigure(caption: test.running ? test.phaseText : "Right now ↓", value: test.running && test.phase != .latency ? SpeedFormat.text(test.liveRate) : SpeedFormat.text(tracker.down), tint: VSDesign.accent)
                        MacFigure(caption: "Right now ↑", value: SpeedFormat.text(tracker.up), tint: .green)
                    }
                }
                if case .failed(let message) = test.phase { Label(message, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.orange) }
                if let last = tracker.last, !test.running { lastResult(last) }
                Divider()
                topSpeeds
                if !tracker.history.isEmpty { Divider(); historyList }
                MacExplainer(text: "Speeds are measured by the speed test, in each mode, and the best one is kept. \"Right now\" and the dial watch the network port and use no data; they count everything the port carries, so they show activity, not your connection's speed. A test opens several connections to Apple's or Cloudflare's public speed servers and uses data: up to about 600 MB down and 300 MB up on a fast line, less on a slow one.")
            }
        }
        .alert("This connection costs data", isPresented: $confirmMetered) {
            Button("Run anyway") { startTest() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("macOS reports this connection as a hotspot, metered, or in low-data mode. A speed test uses up to about 900 MB on a fast line.") }
    }

    private func startTest() { test.start(mode: { store.speedMode }, tracker: tracker) }
    private var testPill: some View {
        Button {
            if test.running { test.cancel() }
            else if WiFiMonitor.shared.path.expensive || WiFiMonitor.shared.path.constrained { confirmMetered = true }
            else { test.start(mode: { store.speedMode }, tracker: tracker) }
        } label: {
            HStack(spacing: 6) {
                if test.running { ProgressView().controlSize(.mini) } else { Image(systemName: "bolt.fill").font(.system(size: 10, weight: .bold)) }
                Text(test.running ? "Stop" : "Test speed")
            }
        }.buttonStyle(MacHoverButtonStyle(prominent: !test.running)).disabled(!test.running && currentMode == nil)
            .accessibilityLabel(test.running ? "Stop the speed test" : "Run an internet speed test")
    }

    private func lastResult(_ r: SpeedTestResult) -> some View {
        VStack(alignment: .leading, spacing: 4) { lastResultRow(r); verdictLine(r) }
    }
    private func lastResultRow(_ r: SpeedTestResult) -> some View {
        HStack(spacing: 8) {
            MacChip(text: "Last test · \(r.mode.title)", tint: VSDesign.accent)
            Text("↓ \(SpeedFormat.text(r.down))   ↑ \(SpeedFormat.text(r.up))" + (r.latencyMs.map { String(format: "   %.0f ms", $0) } ?? "")).font(.system(size: 12, weight: .medium)).monospacedDigit()
                .help(r.streams > 0 ? "Measured over \(String(format: "%.0f", r.seconds)) seconds on \(r.streams) connections to \(r.source.isEmpty ? "the speed service" : r.source)." : "")
            Spacer(minLength: 0)
            Text(r.date, style: .relative).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private func verdictLine(_ r: SpeedTestResult) -> some View {
        switch tracker.verdict(for: r) {
        case .usual(let median): Text("About what this network usually gives you under the same conditions (typically \(SpeedFormat.text(median))).").font(.system(size: 11)).foregroundStyle(.secondary)
        case .slower(let pct, let median): Text("\(pct)% slower than usual here under the same conditions (typically \(SpeedFormat.text(median))).").font(.system(size: 11)).foregroundStyle(.orange)
        case .faster(let pct, let median): Text("\(pct)% faster than usual here under the same conditions (typically \(SpeedFormat.text(median))).").font(.system(size: 11)).foregroundStyle(.green)
        case .noComparison(let why):
            Text((r.context?.networkKey == nil && r.context != nil ? "To compare tests by network, switch on Watch my connection (Connection Health). " : "") + why).font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The best speeds on THIS connection: this network, and the VPN profile in use. Nothing measured elsewhere is shown as this connection's speed.
    private var topSpeeds: some View {
        let here = tracker.networkKey != nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(here ? "Best measured download speed on this network (speed tests only)" : "Best measured download speed").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { tracker.reset() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if !here {
                Label("This network could not be identified (the router's address is not known yet), so best speeds are not kept or shown for it. Tests still appear under Recent tests.", systemImage: "questionmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                let fastest = SpeedMode.allCases.map { tracker.entry(for: $0)?.best.topDown ?? 0 }.max() ?? 0
                ForEach(SpeedMode.allCases) { mode in
                    MacRaceLane(title: mode.title, icon: mode.icon, value: tracker.entry(for: mode)?.best.topDown ?? 0, fastest: fastest, isNow: currentMode == mode)
                }
                let uploads = SpeedMode.allCases.compactMap { mode -> String? in
                    guard let up = tracker.entry(for: mode)?.best.topUp, up > 0 else { return nil }
                    return "\(mode.title) ↑ \(SpeedFormat.text(up))"
                }
                if !uploads.isEmpty {
                    Text("Best measured upload: " + uploads.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let mode = currentMode, let entry = tracker.entry(for: mode), !entry.best.isEmpty, let when = entry.best.testDate {
                    Text("\(mode.title): measured \(when.formatted(date: .abbreviated, time: .shortened))" + (entry.endpoint.map { " against \($0)" } ?? "") + (mode.usesVPN ? ", through the VPN profile in use" : "") + ". A different network or VPN profile has its own best.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                if let mode = currentMode, let best = tracker.entry(for: mode)?.best, best.hasActivityPeak {
                    Text("Highest activity seen on this Mac in this mode: ↓ \(SpeedFormat.text(best.liveDown))  ↑ \(SpeedFormat.text(best.liveUp)). That is everything the port carried, including other apps, so it is a peak of activity, not a speed test, and is not counted above.").font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                if SpeedMode.allCases.allSatisfy({ tracker.entry(for: $0)?.best.isEmpty ?? true }) {
                    Text("No speed test has been run on this network yet, so no mode has a speed here. Press the speed test to measure one.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let mode = currentMode {
                    let elsewhere = tracker.book.elsewhere(than: tracker.key(for: mode))
                    if elsewhere > 0 { Text("\(elsewhere) other connection\(elsewhere == 1 ? "" : "s") have saved speeds. They were measured elsewhere, so they are not shown or compared here.").font(.system(size: 10)).foregroundStyle(.tertiary) }
                }
            }
            if tracker.book.hasLegacy {
                Text("Best speeds saved before networks were recorded are kept but not shown, because they cannot be tied to this connection. Reset clears them.").font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var historyList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent tests").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(tracker.history.prefix(6)) { r in
                HStack(spacing: 8) {
                    Image(systemName: r.mode.icon).frame(width: 16).foregroundStyle(.secondary)
                    Text(r.mode.title).font(.system(size: 12))
                    Spacer(minLength: 6)
                    Text("↓ \(SpeedFormat.text(r.down))  ↑ \(SpeedFormat.text(r.up))" + (r.latencyMs.map { String(format: "  %.0f ms", $0) } ?? "")).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                    Text(r.date, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.system(size: 10)).foregroundStyle(.tertiary).frame(width: 96, alignment: .trailing)
                }
            }
        }
    }
}

extension AppStore {
    /// The speed mode right now, or nil while the connection is changing.
    var speedMode: SpeedMode? {
        if tunnel.status != .connected && tunnel.running { return nil }
        switch powerTone {
        case .off: return .direct
        case .dnsOnly: return .dns
        case .vpnOnly: return .vpn
        case .vpnWithDNS: return .both
        case .busy, .error: return nil
        }
    }
}
