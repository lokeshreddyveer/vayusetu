import AppKit
import Combine
import CoreWLAN
import Darwin
import Foundation
import Network
import IOKit.ps
import SystemConfiguration
import UserNotifications
import VayuSetuCore

/// One stall, as shown in the history. Plain values only (no addresses, no network names), so it can be kept and shared without leaking anything.
struct WiFiIncident: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Date
    var end: Date?
    var cause: String
    var confidence: String
    var evidence: [String]
    var advice: [String]
    var worstLatencyMs: Double?
    var lostRounds = 0
    var rounds = 0
    var band: String?
    var rssiBefore: Int?
    var rssiDuring: Int?
    /// The same for every part of one long outage; `sequence` counts the parts (0 is the first). Nil for stalls recorded before this existed.
    var parentID: UUID? = nil
    var sequence: Int? = nil
    /// What each part of VayuSetu saw, with how it relates to the stall ("Probable consequence: ..."). Never a cause on timing alone.
    var relations: [String]? = nil
    /// Names looked up in the minute before the stall. Only when the person allowed it; never part of a shared report.
    var domains: [String]? = nil
    var duration: TimeInterval { (end ?? Date()).timeIntervalSince(start) }
}

struct SignalPoint: Identifiable, Equatable { var id: Date { date }; var date: Date; var rssi: Int }
struct RoamEvent: Identifiable, Equatable { var id = UUID(); var date: Date; var from: Int?; var to: Int? }

/// How a figure was obtained, shown beside it so nothing measured and nothing guessed look alike.
enum Provenance: String {
    case measured = "Measured", inferred = "Inferred", unavailable = "Not available"
}

/// Which ways this Mac is connected right now, from the system's own path report. This is the registry every other part reads, and it does not
/// depend on VayuSetu's VPN or DNS being on.
struct PathSummary: Equatable {
    var satisfied = false
    var wifi = false, ethernet = false, cellular = false, other = false
    /// A VPN or other virtual interface carries the default path.
    var tunnelled = false
    var expensive = false, constrained = false
    var supportsIPv4 = false, supportsIPv6 = false, supportsDNS = false
    /// The kind of connection without the "through a tunnel" suffix, so connecting or dropping a VPN is not mistaken for a different network.
    var physical: String {
        if !satisfied { return "Offline" }
        if ethernet { return "Ethernet" }
        if wifi { return "Wi-Fi" }
        if cellular { return "Cellular" }
        return other ? "Other connection" : "Unknown"
    }
    var primary: String {
        if !satisfied { return "Offline" }
        if tunnelled { return wifi ? "Wi-Fi through a tunnel" : ethernet ? "Ethernet through a tunnel" : "Tunnel" }
        if ethernet { return "Ethernet" }
        if wifi { return "Wi-Fi" }
        if cellular { return "Cellular" }
        return other ? "Other connection" : "Unknown"
    }
    var icon: String {
        if !satisfied { return "wifi.slash" }
        if ethernet && !tunnelled { return "cable.connector" }
        if cellular && !wifi { return "antenna.radiowaves.left.and.right" }
        return "wifi"
    }
    init() {}
    init(_ path: NWPath) {
        satisfied = path.status == .satisfied
        wifi = path.usesInterfaceType(.wifi); ethernet = path.usesInterfaceType(.wiredEthernet); cellular = path.usesInterfaceType(.cellular)
        other = path.usesInterfaceType(.other)
        // The default path is a tunnel when it reports a virtual interface alongside the physical one (utun, ipsec, ppp).
        tunnelled = path.availableInterfaces.contains { $0.name.hasPrefix("utun") || $0.name.hasPrefix("ipsec") || $0.name.hasPrefix("ppp") } && path.usesInterfaceType(.other)
        expensive = path.isExpensive; constrained = path.isConstrained
        supportsIPv4 = path.supportsIPv4; supportsIPv6 = path.supportsIPv6; supportsDNS = path.supportsDNS
    }
}

/// The ordinary-network probes. They use plain sockets and the system resolver: no packet capture, no extension, no privileges, and they work
/// with the VPN, DNS filtering and ad blocking all off. Each probe is one tiny packet or lookup.
enum WiFiProbe {
    enum Reply { case answered(Double), timedOut, unavailable }

    /// An unprivileged ICMP echo (the datagram form macOS allows any app to use). Returns the round trip in milliseconds.
    static func ping(_ host: String, sequence: UInt16, timeout: TimeInterval = 1.5, bound: String? = nil) -> Reply {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return .unavailable }
        defer { close(fd) }
        if let bound {
            var index = if_nametoindex(bound)
            guard index != 0, setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size)) == 0 else { return .unavailable }
        }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return .unavailable }

        var packet = [UInt8](repeating: 0, count: 16)
        packet[0] = 8                                              // echo request
        packet[4] = 0x56; packet[5] = 0x53                         // identifier (the system may rewrite it)
        packet[6] = UInt8(sequence >> 8); packet[7] = UInt8(sequence & 0xff)
        for (i, byte) in "VayuSetu".utf8.enumerated() { packet[8 + i] = byte }
        var sum: UInt32 = 0
        for i in stride(from: 0, to: packet.count, by: 2) { sum += UInt32(packet[i]) << 8 | UInt32(packet[i + 1]) }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        let checksum = ~UInt16(sum & 0xffff)
        packet[2] = UInt8(checksum >> 8); packet[3] = UInt8(checksum & 0xff)

        let started = DispatchTime.now()
        let sent = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard sent == packet.count else { return errno == ENETUNREACH || errno == EHOSTUNREACH || errno == ENETDOWN ? .timedOut : .unavailable }
        var buffer = [UInt8](repeating: 0, count: 1500)
        let deadline = started.uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n < 0 { return .timedOut }
            var offset = 0
            if n > 0, buffer[0] >> 4 == 4 { offset = Int(buffer[0] & 0x0f) * 4 }          // the reply may include its IP header
            guard n >= offset + 8, buffer[offset] == 0 else { continue }                  // type 0 is an echo reply
            let seq = UInt16(buffer[offset + 6]) << 8 | UInt16(buffer[offset + 7])
            if seq == sequence { return .answered(Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000) }
        }
        return .timedOut
    }

    /// A lookup of a name that does not exist under a real domain, so the answer cannot come from a cache: "no such name" is an answer from the
    /// resolver, and only a failure or a long wait counts as the resolver not answering.
    static func dns(timeout: TimeInterval = 4) -> Reply {
        let name = "vs" + String(UInt32.random(in: 0...UInt32.max), radix: 36) + ".example.com"
        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var status: Int32 = -1; var ms = 0.0 }
        let box = Box()
        let started = DispatchTime.now()
        DispatchQueue.global(qos: .utility).async {
            var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            box.status = getaddrinfo(name, nil, &hints, &result)
            if let result { freeaddrinfo(result) }
            box.ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return .timedOut }
        let answered = box.status == 0 || box.status == EAI_NONAME || box.status == EAI_NODATA
        return answered ? .answered(box.ms) : .timedOut
    }

    /// The router's address, from the system's network configuration (nil with no network).
    static func gateway() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "VayuSetu" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] else { return nil }
        return global["Router"] as? String
    }
}

/// Watches the Wi-Fi radio and the path behind it, finds stalls, and says what the evidence points at. It reads the radio through CoreWLAN and
/// probes with plain sockets, so it runs whether or not VayuSetu's VPN, DNS or ad blocking is on. It records numbers only, and keeps them here.
@MainActor final class WiFiMonitor: ObservableObject {
    static let shared = WiFiMonitor()
    @Published private(set) var reading: WiFiReading?
    @Published private(set) var rounds: [ProbeRound] = []
    @Published private(set) var incidents: [WiFiIncident] = []
    @Published private(set) var running = false
    @Published private(set) var state = StallDetector.State.healthy
    @Published private(set) var gatewayAddressKnown = false
    @Published private(set) var unavailableNote: String?
    @Published private(set) var path = PathSummary()
    @Published private(set) var signalHistory: [SignalPoint] = []
    @Published private(set) var baselineRemark: String?
    @Published private(set) var gatewayVerdict: GatewayIdentity.Verdict?
    @Published private(set) var arpDuplicates: [String] = []
    private var baselines: [String: NetworkBaseline] = {
        guard let d = UserDefaults.standard.data(forKey: "netlab-baselines-v2"), let v = try? JSONDecoder().decode([String: NetworkBaseline].self, from: d) else { return [:] }
        return v
    }()
    private var knownGatewayMACs: [String: String] = [:]
    private var gatewayMAC: String?
    private var lastIdentityCheck = Date.distantPast
    private var gatewayKey: String?
    private var roundsSinceBaseline = 0
    /// Nil until the router has been identified, so nothing is learned about a network that cannot yet be told from another.
    private var networkKey: String? { NetworkIdentity.key(primary: path.physical, ssid: reading?.ssid, gatewayIP: gatewayKey, gatewayMAC: gatewayMAC) }
    @Published private(set) var roams: [RoamEvent] = []
    @Published private(set) var days: [DayQuality] = []
    @Published var notifyOnStall = UserDefaults.standard.bool(forKey: "wifi-notify") { didSet { UserDefaults.standard.set(notifyOnStall, forKey: "wifi-notify"); if notifyOnStall { Self.askForNotifications() } } }
    /// Whether the VayuSetu VPN is carrying traffic. The view supplies it; the monitor uses it only to notice a change as a possible cause.
    var vpnActive: () -> Bool = { false }
    private var lastVPN = false
    /// The shared record of the stall in progress: each part of VayuSetu adds what it saw, and evidence from another network or an older tunnel is refused.
    private var ledger = IncidentLedger()
    private var currentSequence = 0
    private var vpnGeneration = 0
    /// Supplied by the view: the tunnel session counter, and what the tunnel's resolver has done lately.
    var tunnelSession: () -> Int = { 0 }
    var tunnelResolverHealth: () -> ResolverHealth? = { nil }
    private var generation: Int { tunnelSession() + vpnGeneration }
    /// Names looked up recently, in memory only, and only while "Show domains around stalls" is on.
    private var domainRing = RecentDomainRing()
    private var domainListener: AnyCancellable?
    static var stallDomainsOn: Bool { UserDefaults.standard.bool(forKey: "stall-domains") }
    func setStallDomains(_ on: Bool) { UserDefaults.standard.set(on, forKey: "stall-domains"); domainRing.setEnabled(on && running) }
    /// The identity of the connection in use, worked out now from what the system already knows (the router's address, its hardware address from the ARP table, the
    /// network name and the kind of connection). It does not need Watch my connection to be on, sends nothing, and is nil when the router cannot be identified.
    func networkKeyNow() async -> String? {
        guard path.satisfied, let gateway = WiFiProbe.gateway() else { return nil }
        let entries = ARPParser.parse(await NetLab.run("/usr/sbin/arp", ["-an"], timeout: 3))
        return NetworkIdentity.key(primary: path.physical, ssid: Self.readRadio(now: Date()).ssid, gatewayIP: gateway, gatewayMAC: entries.first(where: { $0.ip == gateway })?.mac)
    }
    private var lastVPNChange = Date.distantPast
    private var lastPathChange = Date.distantPast
    private var roundsSinceSave = 0
    private var pathMonitor: NWPathMonitor?
    private var detector = StallDetector()
    private var task: Task<Void, Never>?
    private var readings: [WiFiReading] = []
    private var openStart: Date?
    private var beforeReading: WiFiReading?
    private var sequence: UInt16 = 0
    private var lastWake: Date?
    private var dnsBusy = false
    private var observers: [NSObjectProtocol] = []
    /// Probes are a few bytes, but they slow down on a hotspot, in Low Power Mode, on battery with nothing on screen, and when it has been steady.
    var interval: TimeInterval {
        let conditions = SamplingPolicy.Conditions(expensive: path.expensive, constrained: path.constrained, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                                   onBattery: Self.onBattery(), windowInBackground: !NSApp.isActive || NSApp.keyWindow == nil,
                                                   stable: state == .healthy && Date().timeIntervalSince(lastTrouble) > 600)
        return SamplingPolicy.interval(conditions, suspicious: state != .healthy)
    }
    private var lastTrouble = Date.distantPast
    nonisolated static func onBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPSBatteryPowerValue
    }
    static let keepRounds = 200, keepIncidents = 100
    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("VayuSetuVPN", isDirectory: true).appendingPathComponent("wifi-incidents.json")
    }

    private init() {
        // Which connection this is, and whether it costs data, is read by every tool (the speed test and the lab ask before spending data),
        // so it is tracked from launch whether or not probing is switched on. It costs nothing: the system pushes changes.
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] update in
            let summary = PathSummary(update)
            Task { @MainActor in
                guard let self else { return }
                if summary != self.path, self.running { NetLab.shared.note("path", "Connection: \(summary.primary)" + (summary.expensive ? " (costs data)" : "")) }
                if summary.primary != self.path.primary, self.running { self.lastPathChange = Date() }
                if self.running, summary.physical != self.path.physical {
                    // Between two live connections the old readings belong to the connection that was left. Losing the connection is not that:
                    // it is an outage, which the rounds must keep recording, and coming back only forgets the router's identity.
                    if summary.satisfied && self.path.satisfied { self.startFreshSeries() }
                    else if summary.satisfied { self.resetIdentity() }
                }
                self.path = summary
            }
        }
        monitor.start(queue: DispatchQueue(label: "app.vayusetu.wifi.path", qos: .utility))
        pathMonitor = monitor
        UserDefaults.standard.removeObject(forKey: "netlab-gateway-macs")      // build 54 kept these across networks; they are now per connection
        UserDefaults.standard.removeObject(forKey: "netlab-baselines")         // keyed by router address alone, which different networks share
        if let data = try? Data(contentsOf: Self.url), let saved = try? JSONDecoder().decode([WiFiIncident].self, from: data) { incidents = saved }
        if let data = try? Data(contentsOf: Self.qualityURL), let saved = try? JSONDecoder().decode([DayQuality].self, from: data) { days = saved }
    }
    private static var qualityURL: URL { url.deletingLastPathComponent().appendingPathComponent("wifi-quality.json") }
    private func saveBaselines() {
        if let d = try? JSONEncoder().encode(baselines) { UserDefaults.standard.set(d, forKey: "netlab-baselines-v2") }
    }
    /// Reads the router's hardware address and the neighbours' addresses from the system's own table (nothing is sent), and compares with last time.
    private func checkIdentity(gateway: String) async {
        let out = await NetLab.run("/usr/sbin/arp", ["-an"], timeout: 3)
        let entries = ARPParser.parse(out)
        arpDuplicates = ARPParser.duplicates(entries, gateway: gateway)
        guard let mac = entries.first(where: { $0.ip == gateway })?.mac else { return }
        let verdict = GatewayIdentity.compare(known: knownGatewayMACs, key: gateway, mac: mac)
        gatewayVerdict = verdict
        if verdict.changed { NetLab.shared.note("gateway", "The router's hardware address changed during this connection.") }
        knownGatewayMACs[gateway] = mac
        gatewayMAC = mac
    }
    private func saveQuality() {
        try? FileManager.default.createDirectory(at: Self.qualityURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(days) { try? data.write(to: Self.qualityURL, options: .atomic) }
    }
    nonisolated static func askForNotifications() { UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in } }
    private func announce(_ incident: WiFiIncident) {
        guard notifyOnStall else { return }
        AlertNotifier.post(id: incident.id.uuidString, title: "Your connection stalled", body: "\(incident.cause) (\(Int(incident.duration)) s).")
    }

    var score: Int? { ConnectionHealth.score(reading: reading, rounds: rounds) }
    /// The router's usual round-trip time, from recent rounds that answered.
    var baselineMs: Double? {
        let ok = rounds.suffix(60).compactMap { $0.gatewayAnswered == true ? $0.gatewayMs : nil }.sorted()
        return ok.isEmpty ? nil : ok[ok.count / 2]
    }

    func start() {
        guard !running else { return }
        running = true
        domainRing.setEnabled(Self.stallDomainsOn)
        domainListener = DomainHistoryStore.shared.batches.receive(on: DispatchQueue.main).sink { [weak self] batch in self?.noteDomains(batch) }
        NetLab.shared.restartSchedule()
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.lastWake = Date(); NetLab.shared.note("wake", "The Mac woke from sleep.") } },
        ]
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(self?.interval ?? 3))
            }
        }
    }

    /// Forget the readings of the connection that was just left: the router, its usual latency and the score belong to that connection only.
    private func startFreshSeries() {
        if openStart != nil { closeIncident(at: Date()) }
        rounds = []; detector = StallDetector(); state = .healthy; beforeReading = nil
        resetIdentity()
    }
    /// The router's hardware address is compared only within one continuous connection. Moving to another network, or losing and regaining Wi-Fi,
    /// starts again, because two networks often share a router address and a different router there is not a change.
    private func resetIdentity() { knownGatewayMACs = [:]; gatewayVerdict = nil; arpDuplicates = []; gatewayMAC = nil; baselineRemark = nil }

    func stop() {
        saveQuality()
        running = false; task?.cancel(); task = nil
        domainListener = nil; domainRing.setEnabled(false)
        NetLab.shared.stopSchedule()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; observers = []
        if openStart != nil { closeIncident(at: Date()) }
        state = .healthy; detector = StallDetector()
    }

    // MARK: One round
    private func tick() async {
        let now = Date()
        let radio = await Self.readRadioOffMain(now: now)   // CoreWLAN answers over XPC; asking on the main thread stalls the interface for as long as it takes
        if let previous = readings.last, previous.associated, radio.associated, let a = previous.bssid, let b = radio.bssid, a != b {
            roams.insert(RoamEvent(date: now, from: previous.rssi, to: radio.rssi), at: 0); if roams.count > 100 { roams.removeLast(roams.count - 100) }
            NetLab.shared.note("roam", "Moved to another access point" + (previous.rssi.flatMap { a in radio.rssi.map { b in " (signal \(a) → \(b) dBm)" } } ?? "") + ".")
        }
        if let previous = readings.last {
            if previous.associated && !radio.associated { resetIdentity() }
            if let a = previous.ssid, let b = radio.ssid, a != b { resetIdentity() }
        }
        // Published only when something about the link changed; every round used to redraw every screen watching the monitor for a new timestamp alone.
        if let shown = reading { var same = shown; same.date = radio.date; if same != radio { reading = radio } } else { reading = radio }
        readings.append(radio); if readings.count > Self.keepRounds { readings.removeFirst(readings.count - Self.keepRounds) }
        if let rssi = radio.rssi { signalHistory.append(SignalPoint(date: now, rssi: rssi)); if signalHistory.count > Self.keepRounds { signalHistory.removeFirst(signalHistory.count - Self.keepRounds) } }
        let vpn = vpnActive()
        if vpn != lastVPN {
            lastVPN = vpn; lastVPNChange = now; vpnGeneration += 1; NetLab.shared.note("vpn", vpn ? "The VPN connected." : "The VPN disconnected.")
            ledger.tunnelTransition(generation: generation, at: now)
        }
        sequence &+= 1
        let seq = sequence
        let gateway = WiFiProbe.gateway()
        if gatewayAddressKnown != (gateway != nil) { gatewayAddressKnown = gateway != nil }
        let wantDNS = !dnsBusy && Int(seq) % 3 == 0 && radio.associated
        if wantDNS { dnsBusy = true }
        async let router = Self.run { gateway.map { WiFiProbe.ping($0, sequence: seq) } ?? .unavailable }
        async let internet = Self.run { WiFiProbe.ping("1.1.1.1", sequence: seq &+ 1000) }
        async let lookup = Self.run { wantDNS ? WiFiProbe.dns() : .unavailable }
        let (gw, net, dns) = await (router, internet, lookup)
        if wantDNS { dnsBusy = false }
        var round = ProbeRound(date: now)
        switch gw { case .answered(let ms): round.gatewayMs = ms; round.gatewayAnswered = true; case .timedOut: round.gatewayAnswered = false; case .unavailable: break }
        switch net { case .answered(let ms): round.internetMs = ms; round.internetAnswered = true; case .timedOut: round.internetAnswered = false; case .unavailable: break }
        if wantDNS { switch dns { case .answered(let ms): round.dnsMs = ms; round.dnsAnswered = true; case .timedOut: round.dnsAnswered = false; case .unavailable: break } }
        // No route at all, or a router address that was there a moment ago and is gone, is an outage and has to be recorded as one.
        if case .unavailable = gw, gateway == nil, gatewayKey != nil { round.gatewayAnswered = false }
        if case .unavailable = net, !path.satisfied { round.internetAnswered = false }
        let note: String? = { if case .unavailable = gw, gateway != nil { return "This Mac does not allow the router probe." }; return gateway == nil && radio.associated ? "No router address was found." : nil }()
        if unavailableNote != note { unavailableNote = note }
        gatewayKey = gateway
        if let gateway, now.timeIntervalSince(lastIdentityCheck) > 60 { lastIdentityCheck = now; Task { await self.checkIdentity(gateway: gateway) } }
        roundsSinceBaseline += 1
        if let key = networkKey {
            // One update per 60 rounds (about three minutes), only while healthy; the window it summarises is the last 60 rounds, so windows do not overlap.
            if roundsSinceBaseline >= 60, let median = baselineMs, state == .healthy {
                roundsSinceBaseline = 0
                baselines[key] = Baselines.update(baselines[key], median: median); saveBaselines()
            }
            let recentGateway = rounds.suffix(5).compactMap { $0.gatewayMs }.sorted()
            let remark = Baselines.remark(known: baselines[key], nowMs: recentGateway.isEmpty ? nil : recentGateway[recentGateway.count / 2])
            if baselineRemark != remark { baselineRemark = remark }
        } else if baselineRemark != nil { baselineRemark = nil }
        rounds.append(round); if rounds.count > Self.keepRounds { rounds.removeFirst(rounds.count - Self.keepRounds) }
        QualityHistory.record(round, into: &days, today: DomainHistory.day(for: now), hour: Calendar.current.component(.hour, from: now))
        roundsSinceSave += 1; if roundsSinceSave >= 20 { roundsSinceSave = 0; saveQuality() }
        let before = detector.state
        let outcome = detector.record(round, baselineMs: baselineMs)
        if state != detector.state { state = detector.state }
        if state != .healthy { lastTrouble = now }
        if before == .healthy, detector.state == .suspected { beforeReading = readings.dropLast().last ?? radio }
        if outcome.opened {
            openStart = detector.startedAt
            ledger.open(at: detector.startedAt ?? now, networkKey: networkKey, interface: path.physical, tunnelGeneration: generation)
            // A stall that resumes an outage still in its late-evidence window continues that outage's numbering instead of starting at 0 again.
            let parent = ledger.open?.parentID
            currentSequence = incidents.filter { $0.parentID == parent && parent != nil }.count
        }
        if outcome.closed { closeIncident(at: now) }
        // A stall that runs very long is recorded in parts that share one parent, so a long outage reads as one outage and cannot absorb what follows.
        if let start = openStart, now.timeIntervalSince(start) > ledger.config.maximumDuration { closeIncident(at: now, continuing: true) }
        ledger.advance(now: now)
    }

    private static func readRadioOffMain(now: Date) async -> WiFiReading {
        await withCheckedContinuation { continuation in DispatchQueue.global(qos: .utility).async { continuation.resume(returning: readRadio(now: now)) } }
    }
    private static func run(_ work: @escaping @Sendable () -> WiFiProbe.Reply) async -> WiFiProbe.Reply {
        await withCheckedContinuation { continuation in DispatchQueue.global(qos: .utility).async { continuation.resume(returning: work()) } }
    }

    // MARK: Reading the radio
    nonisolated static func readRadio(now: Date) -> WiFiReading {
        guard let interface = CWWiFiClient.shared().interface() else { return WiFiReading(date: now, associated: false) }
        let rssi = interface.rssiValue(), rate = interface.transmitRate()
        let associated = interface.powerOn() && (rssi != 0 || rate > 0)
        guard associated else { return WiFiReading(date: now, associated: false) }
        var channel: Int?, band = WiFiBand.unknown, width: Int?
        if let c = interface.wlanChannel() {
            channel = c.channelNumber
            switch c.channelBand { case .band2GHz: band = .ghz2; case .band5GHz: band = .ghz5; case .band6GHz: band = .ghz6; default: band = WiFiBand.from(channel: c.channelNumber) }
            switch c.channelWidth { case .width20MHz: width = 20; case .width40MHz: width = 40; case .width80MHz: width = 80; case .width160MHz: width = 160; default: width = nil }
        }
        let phy: String?
        switch interface.activePHYMode() {
        case .mode11a: phy = "802.11a"; case .mode11b: phy = "802.11b"; case .mode11g: phy = "802.11g"; case .mode11n: phy = "802.11n"
        case .mode11ac: phy = "802.11ac (Wi-Fi 5)"; case .mode11ax: phy = "802.11ax (Wi-Fi 6/6E)"; default: phy = nil
        }
        let security: String?
        switch interface.security() {
        case .none: security = "Open (no password)"; case .WEP: security = "WEP (weak)"; case .wpaPersonal, .wpaPersonalMixed: security = "WPA Personal"
        case .wpa2Personal: security = "WPA2 Personal"; case .personal: security = "Personal"; case .wpa3Personal: security = "WPA3 Personal"
        case .dynamicWEP: security = "Dynamic WEP (weak)"; case .wpaEnterprise, .wpaEnterpriseMixed: security = "WPA Enterprise"
        case .wpa2Enterprise: security = "WPA2 Enterprise"; case .enterprise: security = "Enterprise"; case .wpa3Enterprise: security = "WPA3 Enterprise"
        case .wpa3Transition: security = "WPA3 (transition)"; default: security = nil
        }
        let noise = interface.noiseMeasurement()
        return WiFiReading(date: now, associated: true, ssid: interface.ssid(), bssid: interface.bssid(), rssi: rssi < 0 ? rssi : nil, noise: noise < 0 ? noise : nil,
                           channel: channel, band: band, widthMHz: width, linkRateMbps: rate > 0 ? rate : nil, phyMode: phy, security: security)
    }

    // MARK: Incidents
    /// A speed test that finished while a stall is open is part of the evidence (it is measured, and it ran on this connection).
    func attachSpeed(down: Double, seconds: Double, at date: Date) {
        guard running, ledger.open != nil else { return }
        let observation = EvidenceObservation(layer: .speed, start: date.addingTimeInterval(-max(seconds, 1) * 2), end: date, interface: path.physical, networkKey: networkKey, tunnelGeneration: generation,
                                              provenance: .measured, failed: false, summary: "A speed test measured \(SpeedFormat.text(down)) down")
        ledger.attach(observation, now: date)
    }
    private func noteDomains(_ batch: [DomainCount]) {
        guard Self.stallDomainsOn else { domainRing.setEnabled(false); return }
        if !domainRing.enabled { domainRing.setEnabled(true) }
        let now = Date()
        for c in batch where !c.n.isEmpty { domainRing.add(name: c.n, allowed: Int(c.a), blocked: Int(c.b), at: now) }
    }

    /// What each layer showed during the stall, as dated, sourced observations for the shared record.
    private func observations(start: Date, end: Date, during: [ProbeRound], evidence e: IncidentEvidence) -> [EvidenceObservation] {
        func make(_ layer: EvidenceLayer, _ from: Date, _ to: Date, failed: Bool, _ summary: String, provenance: EvidenceProvenance = .measured) -> EvidenceObservation {
            EvidenceObservation(layer: layer, start: from, end: to, interface: path.physical, networkKey: networkKey, tunnelGeneration: generation, provenance: provenance, failed: failed, summary: summary)
        }
        func share(_ answers: [Bool]) -> String { "\(answers.filter { $0 }.count) of \(answers.count) answered" }
        var out: [EvidenceObservation] = []
        if let failed = e.gatewayFailedDuring { out.append(make(.router, start, end, failed: failed, "Router checks: " + share(during.compactMap(\.gatewayAnswered)))) }
        if let failed = e.internetFailedDuring { out.append(make(.internet, start, end, failed: failed, "Internet checks: " + share(during.compactMap(\.internetAnswered)))) }
        if !e.associatedDuring { out.append(make(.wifi, start, end, failed: true, "Wi-Fi was disconnected")) }
        if let failed = e.dnsFailedDuring { out.append(make(.dns, start, end, failed: failed, "The app's own DNS checks: " + share(during.compactMap(\.dnsAnswered)))) }
        if let h = tunnelResolverHealth(), let failureShare = h.failureShare, h.windowEnd >= start {
            out.append(make(.dns, max(h.windowStart, start.addingTimeInterval(-30)), min(h.windowEnd, end), failed: failureShare >= 0.10,
                            "Tunnel resolver over the last ten minutes: \(h.answered) answered, \(h.timeouts) timed out, \(h.errors) failed"))
        }
        if e.vpnChangedAround { out.append(make(.vpn, lastVPNChange, lastVPNChange, failed: false, "The VPN changed state")) }
        if e.pathChangedAround { out.append(make(.path, lastPathChange, lastPathChange, failed: false, "The connection type changed")) }
        if let wake = lastWake, e.secondsSinceWake != nil { out.append(make(.wake, wake, wake, failed: false, "The Mac woke from sleep")) }
        return out
    }

    private func closeIncident(at end: Date, continuing: Bool = false) {
        guard let start = openStart else { return }
        openStart = nil
        let during = rounds.filter { $0.date >= start && $0.date <= end }
        let readingsDuring = readings.filter { $0.date >= start && $0.date <= end }
        var e = IncidentEvidence()
        e.roundsDuring = during.count
        e.wasAssociatedBefore = beforeReading?.associated ?? true
        e.associatedDuring = readingsDuring.isEmpty ? true : !readingsDuring.contains { !$0.associated }
        e.bssidBefore = beforeReading?.bssid; e.bssidDuring = readingsDuring.last(where: { $0.associated })?.bssid
        e.rssiBefore = beforeReading?.rssi; e.rssiDuring = readingsDuring.compactMap(\.rssi).min()
        func failed(_ answers: [Bool]) -> Bool? { answers.isEmpty ? nil : Double(answers.filter { !$0 }.count) / Double(answers.count) >= 0.5 }
        e.gatewayFailedDuring = failed(during.compactMap(\.gatewayAnswered))
        e.internetFailedDuring = failed(during.compactMap(\.internetAnswered))
        e.dnsFailedDuring = failed(during.compactMap(\.dnsAnswered))
        if let wake = lastWake { let gap = start.timeIntervalSince(wake); if gap >= 0, gap < 60 { e.secondsSinceWake = gap } }
        e.pathChangedAround = abs(lastPathChange.timeIntervalSince(start)) < 15
        e.vpnChangedAround = abs(lastVPNChange.timeIntervalSince(start)) < 15
        let diagnosis = IncidentClassifier.diagnose(e)
        let lost = during.filter { $0.gatewayAnswered == false }.count
        // Evidence attached while the stall was still open (a speed test) comes first, then what is read now.
        var relations: [String] = (ledger.open?.evidence ?? []).map { "\($0.relation.rawValue): \($0.observation.summary)" }
        let parent = ledger.open?.parentID
        for observation in observations(start: start, end: end, during: during, evidence: e) {
            if case .attached(_, let relation, _) = ledger.attach(observation, now: end) { relations.append("\(relation.rawValue): \(observation.summary)") }
        }
        var domains: [String]?
        let lookback = start.addingTimeInterval(-60)
        if domainRing.covers(from: lookback) {
            let top = domainRing.top(from: lookback, to: start)
            domains = top.isEmpty ? [] : top.map { "\($0.name) (\($0.count))" }
        }
        var incident = WiFiIncident(start: start, end: end, cause: diagnosis.cause.title, confidence: diagnosis.confidence.rawValue, evidence: diagnosis.evidence, advice: diagnosis.advice,
                                    worstLatencyMs: during.compactMap(\.gatewayMs).max(), lostRounds: lost, rounds: during.count, band: beforeReading?.band.rawValue,
                                    rssiBefore: e.rssiBefore, rssiDuring: e.rssiDuring)
        incident.parentID = parent; incident.sequence = currentSequence; incident.relations = relations.isEmpty ? nil : relations; incident.domains = domains
        NetLab.shared.note("stall", "Stall of \(Int(incident.duration)) s: \(incident.cause) (\(incident.confidence) confidence)." + (continuing ? " The stall is continuing." : ""))
        if continuing {
            // The outage goes on: the next part shares this one's parent.
            ledger.continueIncident(at: end); currentSequence += 1; openStart = end
        } else { ledger.recover(at: end) }
        QualityHistory.recordStall(seconds: Int(incident.duration), into: &days, today: DomainHistory.day(for: end))
        saveQuality(); announce(incident)
        incidents.insert(incident, at: 0)
        if incidents.count > Self.keepIncidents { incidents.removeLast(incidents.count - Self.keepIncidents) }
        save()
    }

    func clearHistory() { incidents = []; save() }
    private func save() {
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(incidents) { try? data.write(to: Self.url, options: .atomic) }
    }

    /// A plain-text report with no network name, no addresses and nothing that identifies the Mac, safe to paste into a message.
    func report() -> String {
        var lines = ["VayuSetu Wi-Fi report", ""]
        if let r = reading, r.associated {
            lines.append("Now: signal \(r.rssi.map { "\($0) dBm" } ?? "n/a"), noise \(r.noise.map { "\($0) dBm" } ?? "n/a"), \(r.band.rawValue)" + (r.channel.map { " channel \($0)" } ?? "") + (r.linkRateMbps.map { ", link rate \(Int($0)) Mbit/s" } ?? ""))
        } else { lines.append("Now: not connected to Wi-Fi") }
        if let s = score { lines.append("Health score: \(s) (\(ConnectionHealth.label(s)))") }
        lines.append(""); lines.append("Stalls (\(incidents.count)):")
        for i in incidents.prefix(20) {
            lines.append("- \(i.start.formatted(date: .abbreviated, time: .shortened)), \(Int(i.duration)) s: \(i.cause) (\(i.confidence) confidence)")
            for e in i.evidence { lines.append("    seen: \(e)") }
        }
        return lines.joined(separator: "\n")
    }
}
