import AppKit
import CoreWLAN
import Darwin
import Foundation
import Network
import SystemConfiguration
import VayuSetuCore

/// One thing worth remembering about the network: it changed, a stall began or ended, the public address moved, the Mac woke.
struct NetEvent: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var kind: String          // "path", "gateway", "public-ip", "stall", "wake", "recovery"
    var text: String
}

struct SiteTiming: Identifiable, Equatable {
    var id: String { url }
    var url: String
    var status: Int?
    var dnsMs: Double?, connectMs: Double?, tlsMs: Double?, firstByteMs: Double?, totalMs: Double?
    var failure: String?
}

struct DNSTiming: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var medianMs: Double?
    var answered: Int
    var asked: Int
}

struct BonjourDevice: Identifiable, Hashable {
    var id: String { name + "|" + type }
    var name: String
    var type: String
    /// A readable name for the service type, or the type itself when it is not a well-known one.
    var kind: String
}

struct InterfaceCompare: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var kind: InterfaceKind
    var medianMs: Double?
    var answered: Int
    var asked: Int
}

struct RecoveryRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var action: String
    var outcome: String
}

/// Everything the lab can do. Each function does one clearly bounded thing, only when asked, and says what it used: no scanning of other
/// machines, no changing of settings except the one recovery action the user confirms.
@MainActor final class NetLab: ObservableObject {
    static let shared = NetLab()
    // Internet
    @Published private(set) var captive: CaptivePortal.Verdict?
    @Published private(set) var captiveBusy = false
    @Published private(set) var publicIP: String?
    @Published private(set) var publicIPDate: Date?
    @Published private(set) var ipv6Result: String?
    @Published private(set) var dnsTimings: [DNSTiming] = []
    @Published private(set) var sites: [SiteTiming] = []
    // Addresses and configuration (read from the system, no probe)
    @Published private(set) var localAddresses: [String] = []
    @Published private(set) var gateway: String?
    @Published private(set) var resolvers: [String] = []
    @Published private(set) var proxies: [String] = []
    @Published private(set) var interfaceName: String?
    @Published private(set) var mtu: Int?
    @Published private(set) var gatewayChanged = false
    // Local network and Wi-Fi
    @Published private(set) var devices: [BonjourDevice] = []
    @Published private(set) var browsing = false
    @Published private(set) var nearby: [NearbyNetwork] = []
    @Published private(set) var scanning = false
    @Published private(set) var scanNote: String?
    // Lab
    @Published private(set) var hops: [TracerouteHop] = []
    @Published private(set) var tracing = false
    @Published private(set) var pathMTU: Int?
    @Published private(set) var mtuBusy = false
    @Published private(set) var mtuNote: String?
    @Published private(set) var bloat: Bufferbloat.Result?
    @Published private(set) var bloatBusy = false
    @Published private(set) var bloatNote: String?
    @Published private(set) var portResult: String?
    @Published private(set) var busy = Set<String>()
    /// Everything started from a button, so each can be cancelled from the same button.
    @Published private(set) var running = Set<String>()
    @Published private(set) var interfaces: [InterfaceInfo] = []
    @Published private(set) var comparison: [InterfaceCompare] = []
    @Published private(set) var dhcp: DHCPInfo?
    @Published private(set) var baselineIP: String? = UserDefaults.standard.string(forKey: "netlab-baseline-ip")
    @Published private(set) var ipv6Direct: Bool?
    private var tasks: [String: Task<Void, Never>] = [:]
    // History
    @Published private(set) var events: [NetEvent] = []
    @Published private(set) var recoveries: [RecoveryRecord] = []
    @Published var customSite: String { didSet { UserDefaults.standard.set(customSite, forKey: "netlab-site") } }
    private var browser: [NWBrowser] = []
    private var lastGateway: String?
    private static let eventsKey = "netlab-events", recoveryKey = "netlab-recovery"

    private init() {
        customSite = UserDefaults.standard.string(forKey: "netlab-site") ?? ""
        if let d = UserDefaults.standard.data(forKey: Self.eventsKey), let v = try? JSONDecoder().decode([NetEvent].self, from: d) { events = v }
        if let d = UserDefaults.standard.data(forKey: Self.recoveryKey), let v = try? JSONDecoder().decode([RecoveryRecord].self, from: d) { recoveries = v }
    }

    // MARK: Scheduled checks
    @Published var scheduleHours: Int = UserDefaults.standard.integer(forKey: "netlab-schedule-hours") { didSet { UserDefaults.standard.set(scheduleHours, forKey: "netlab-schedule-hours"); restartSchedule() } }
    @Published private(set) var lastScheduled: Date?
    /// One entry per scheduled run (or skip), for the quality report. Dates and yes/no findings only: no addresses, no network names.
    @Published private(set) var scheduledRecords: [ScheduledCheckRecord] = {
        guard let d = UserDefaults.standard.data(forKey: "netlab-scheduled-records"), let v = try? JSONDecoder().decode([ScheduledCheckRecord].self, from: d) else { return [] }
        return v
    }()
    private func record(_ entry: ScheduledCheckRecord) {
        scheduledRecords = ScheduledReport.appended(scheduledRecords, entry)
        if let d = try? JSONEncoder().encode(scheduledRecords) { UserDefaults.standard.set(d, forKey: "netlab-scheduled-records") }
    }
    func clearScheduledRecords() { scheduledRecords = []; UserDefaults.standard.removeObject(forKey: "netlab-scheduled-records") }
    private var scheduleTask: Task<Void, Never>?
    /// While the app is running, every few hours: look for a sign-in page, see whether the public address moved, and time the name servers. It
    /// records only what changed, in the timeline, and sends a handful of small requests. 0 means off.
    func stopSchedule() { scheduleTask?.cancel(); scheduleTask = nil }
    func restartSchedule() {
        stopSchedule()
        // The schedule belongs to monitoring: it runs only while "Watch my connection" is on, and is off until the user picks an interval.
        guard scheduleHours > 0, WiFiMonitor.shared.running else { return }
        let hours = scheduleHours
        scheduleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double(hours) * 3600))
                guard let self, !Task.isCancelled else { return }
                await self.runScheduledCheck()
            }
        }
    }
    private var scheduledBusy = false
    func runScheduledCheck() async {
        guard !scheduledBusy else { return }                       // never two at once
        scheduledBusy = true; defer { scheduledBusy = false }
        let path = WiFiMonitor.shared.path
        if path.expensive || path.constrained {
            note("check", "Scheduled check skipped: this connection costs data or is in low-data mode.")
            record(ScheduledCheckRecord(date: Date(), skipped: true, vpnOn: tunnelVPNActive())); return
        }
        lastScheduled = Date()
        let before = publicIP
        await checkCaptive()
        guard !Task.isCancelled else { return }
        if captive == .portal { note("portal", "A sign-in page is blocking the internet.") }
        await lookupPublicIP(vpnOn: tunnelVPNActive())
        guard !Task.isCancelled else { return }
        if let before, let now = publicIP, before != now { note("public-ip", "The public address changed since the last check.") }
        await compareDNS()
        guard !Task.isCancelled else { return }
        if let slowest = dnsTimings.filter({ $0.medianMs != nil }).max(by: { ($0.medianMs ?? 0) < ($1.medianMs ?? 0) }), (slowest.medianMs ?? 0) > 300 { note("dns", "\(slowest.name) was slow: \(Int(slowest.medianMs ?? 0)) ms.") }
        let slowestMs = dnsTimings.compactMap(\.medianMs).max()
        record(ScheduledCheckRecord(date: Date(), skipped: false, signInPageSeen: captive == .portal, publicAddressChanged: (before != nil && publicIP != nil) ? before != publicIP : nil,
                                    slowestNameServerMs: slowestMs, vpnOn: tunnelVPNActive()))
        note("check", "Scheduled check done.")
    }

    /// Whether the VayuSetu VPN carries traffic, so a lookup made through it is not taken as the Mac's own address.
    var tunnelVPNActive: () -> Bool = { false }

    // MARK: Starting and stopping
    /// Starts `work` under `key`, or cancels it if it is already running. Every probe has its own timeout as well, so cancelling is quick.
    func toggle(_ key: String, _ work: @escaping @MainActor () async -> Void) {
        if let task = tasks[key] { task.cancel(); return }
        running.insert(key)
        tasks[key] = Task { [weak self] in
            await work()
            self?.tasks[key] = nil; self?.running.remove(key)
        }
    }
    func cancelAll() { tasks.values.forEach { $0.cancel() } }

    // MARK: Events
    func note(_ kind: String, _ text: String) {
        events.insert(NetEvent(kind: kind, text: text), at: 0)
        if events.count > 200 { events.removeLast(events.count - 200) }
        if let d = try? JSONEncoder().encode(events) { UserDefaults.standard.set(d, forKey: Self.eventsKey) }
    }
    func clearEvents() { events = []; UserDefaults.standard.removeObject(forKey: Self.eventsKey) }

    // MARK: Configuration the system already knows
    /// Reads addresses, router, name servers, proxies and the interface's packet size. No traffic is sent.
    func readConfiguration() {
        guard let store = SCDynamicStoreCreate(nil, "VayuSetu" as CFString, nil, nil) else { return }
        let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        let name = ipv4?["PrimaryInterface"] as? String
        let router = ipv4?["Router"] as? String
        if let router, let last = lastGateway, last != router { gatewayChanged = true; note("gateway", "The router's address changed from \(last) to \(router).") }
        if let router { lastGateway = router }
        gateway = router; interfaceName = name
        if let dns = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any] { resolvers = dns["ServerAddresses"] as? [String] ?? [] } else { resolvers = [] }
        var found: [String] = []
        if let proxy = SCDynamicStoreCopyProxies(store) as? [String: Any] {
            for (flag, host, port, label) in [("HTTPEnable", "HTTPProxy", "HTTPPort", "HTTP"), ("HTTPSEnable", "HTTPSProxy", "HTTPSPort", "HTTPS"), ("SOCKSEnable", "SOCKSProxy", "SOCKSPort", "SOCKS"), ("ProxyAutoConfigEnable", "ProxyAutoConfigURLString", "", "Auto-config")] {
                guard (proxy[flag] as? Int) == 1 else { continue }
                let h = proxy[host] as? String ?? "?"
                found.append(port.isEmpty ? "\(label) \(h)" : "\(label) \(h):\(proxy[port].map { "\($0)" } ?? "?")")
            }
        }
        proxies = found
        var addresses: [String] = []
        if let name {
            var head: UnsafeMutablePointer<ifaddrs>?
            if getifaddrs(&head) == 0, let first = head {
                var cursor: UnsafeMutablePointer<ifaddrs>? = first
                while let entry = cursor {
                    if String(cString: entry.pointee.ifa_name) == name, let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) || sa.pointee.sa_family == UInt8(AF_INET6) {
                        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                            let text = String(cString: host)
                            if !text.hasPrefix("fe80") { addresses.append(text) }
                        }
                    }
                    cursor = entry.pointee.ifa_next
                }
                freeifaddrs(head)
            }
            Task { [weak self] in
                let out = await Self.run("/sbin/ifconfig", [name], timeout: 3)
                let value = out.split(separator: "\n").first { $0.contains(" mtu ") }.flatMap { $0.components(separatedBy: " mtu ").last }.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                await MainActor.run { self?.mtu = value }
            }
        }
        localAddresses = addresses
    }

    // MARK: Every interface
    /// Reads every network interface the Mac has: what it is, whether it is up, its speed, address and traffic counters. Nothing is sent.
    func readInterfaces() {
        var system: [String: (type: String?, name: String?)] = [:]
        if let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for item in all { if let bsd = SCNetworkInterfaceGetBSDName(item) as String? { system[bsd] = (SCNetworkInterfaceGetInterfaceType(item) as String?, SCNetworkInterfaceGetLocalizedDisplayName(item) as String?) } }
        }
        struct Acc { var up = false, running = false, speed: Double?, mtu: Int?, addresses: [String] = [], rx: UInt64 = 0, tx: UInt64 = 0 }
        var acc: [String: Acc] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&head) == 0, let first = head {
            var cursor: UnsafeMutablePointer<ifaddrs>? = first
            while let entry = cursor {
                let name = String(cString: entry.pointee.ifa_name)
                var a = acc[name] ?? Acc()
                let flags = Int32(entry.pointee.ifa_flags)
                a.up = a.up || (flags & IFF_UP) != 0; a.running = a.running || (flags & IFF_RUNNING) != 0
                if let sa = entry.pointee.ifa_addr {
                    if sa.pointee.sa_family == UInt8(AF_LINK), let data = entry.pointee.ifa_data?.assumingMemoryBound(to: if_data.self).pointee {
                        a.rx = UInt64(data.ifi_ibytes); a.tx = UInt64(data.ifi_obytes); a.mtu = Int(data.ifi_mtu)
                        if data.ifi_baudrate > 0 { a.speed = Double(data.ifi_baudrate) / 1_000_000 }
                    } else if sa.pointee.sa_family == UInt8(AF_INET) || sa.pointee.sa_family == UInt8(AF_INET6) {
                        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { a.addresses.append(String(cString: host)) }
                    }
                }
                acc[name] = a
                cursor = entry.pointee.ifa_next
            }
            freeifaddrs(head)
        }
        interfaces = acc.map { name, a in
            let sys = system[name]
            let kind = InterfaceKind.classify(bsdName: name, systemType: sys?.type, displayName: sys?.name)
            return InterfaceInfo(name: name, kind: kind, display: sys?.name ?? name, up: a.up, running: a.running, speedMbps: a.speed, mtu: a.mtu, addresses: a.addresses, rxBytes: a.rx, txBytes: a.tx)
        }.filter(\.worthShowing).sorted { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }
    }

    /// Times the same internet check over each active real connection by binding the probe to it, so a Mac with Wi-Fi and Ethernet (or a hotspot)
    /// can see which is better. Five tiny packets per connection.
    func compareInterfaces() async {
        readInterfaces()
        let candidates = interfaces.filter { $0.active && [.wifi, .ethernet, .usb, .thunderbolt, .cellular].contains($0.kind) }
        var out: [InterfaceCompare] = []
        for item in candidates where !Task.isCancelled {
            var times: [Double] = [], answered = 0
            for i in 0..<5 where !Task.isCancelled {
                let seq = UInt16(truncatingIfNeeded: 6000 + i), name = item.name
                let reply: WiFiProbe.Reply = await withCheckedContinuation { c in DispatchQueue.global(qos: .utility).async { c.resume(returning: WiFiProbe.ping("1.1.1.1", sequence: seq, timeout: 1.5, bound: name)) } }
                if case .answered(let ms) = reply { times.append(ms); answered += 1 }
                try? await Task.sleep(for: .seconds(0.2))
            }
            times.sort()
            out.append(InterfaceCompare(name: item.name, kind: item.kind, medianMs: times.isEmpty ? nil : times[times.count / 2], answered: answered, asked: 5))
        }
        comparison = out
    }

    /// The lease the router handed this Mac: subnet, server, how long it lasts. Read with the system's own `ipconfig`.
    func readDHCP() async {
        guard let name = interfaceName else { dhcp = nil; return }
        let out = await Self.run("/usr/sbin/ipconfig", ["getpacket", name], timeout: 3)
        let info = DHCPParser.parse(out)
        dhcp = (info.subnetMask == nil && info.server == nil) ? nil : info
    }

    // MARK: Captive portal and public address
    /// A plain HTTP request to Apple's connectivity page over a raw connection (so no redirect is followed and no policy blocks it), then a verdict.
    func checkCaptive() async {
        captiveBusy = true; defer { captiveBusy = false }
        let result = await Self.rawHTTP(host: "captive.apple.com", path: "/hotspot-detect.html")
        captive = CaptivePortal.classify(status: result.status, body: result.body, redirected: result.location != nil, failed: result.failed)
    }

    func lookupPublicIP(vpnOn: Bool = false) async {
        busy.insert("ip"); defer { busy.remove("ip") }
        var request = URLRequest(url: URL(string: "https://api.ipify.org")!); request.timeoutInterval = 6; request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession(configuration: .ephemeral).data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), text.count < 46 else { return }
        if let old = publicIP, old != text { note("public-ip", "The public address changed.") }
        publicIP = text; publicIPDate = Date()
        if !vpnOn { baselineIP = text; UserDefaults.standard.set(text, forKey: "netlab-baseline-ip") }
    }

    // MARK: IPv6
    func testIPv6() async {
        busy.insert("ipv6"); defer { busy.remove("ipv6") }
        readConfiguration()
        let global = localAddresses.contains { $0.contains(":") && !$0.hasPrefix("fe80") }
        let tcp = await Self.tcpConnect(host: "2606:4700:4700::1111", port: 443, timeout: 3)
        let aaaa = await Self.aaaaLookup("ipv6.google.com")
        var lines: [String] = []
        lines.append(global ? "This Mac has a global IPv6 address." : "This Mac has no global IPv6 address, so IPv6 is not available on this network.")
        lines.append(tcp ? "A connection over IPv6 works." : "A connection over IPv6 did not work.")
        lines.append(aaaa ? "IPv6 name lookups (AAAA) are answered." : "IPv6 name lookups did not return an address.")
        ipv6Result = lines.joined(separator: " ")
        ipv6Direct = tcp
    }

    // MARK: Name servers compared
    /// Times the same kind of lookup on the system resolver and on two public ones. It uses names that do not exist, so no cache answers them.
    func compareDNS() async {
        busy.insert("dns"); defer { busy.remove("dns") }
        var out: [DNSTiming] = []
        out.append(await timing("System resolver") { _ in WiFiProbe.dns(timeout: 4) })
        out.append(await timing("Cloudflare (1.1.1.1)") { name in await Self.doh("https://cloudflare-dns.com/dns-query?name=\(name)&type=A") })
        out.append(await timing("Google (8.8.8.8)") { name in await Self.doh("https://dns.google/resolve?name=\(name)&type=A") })
        dnsTimings = out
    }
    private func timing(_ label: String, _ ask: @escaping @Sendable (String) async -> WiFiProbe.Reply) async -> DNSTiming {
        var times: [Double] = [], answered = 0
        for _ in 0..<5 where !Task.isCancelled {
            let name = "vs" + String(UInt32.random(in: 0...UInt32.max), radix: 36) + ".example.com"
            if case .answered(let ms) = await ask(name) { times.append(ms); answered += 1 }
        }
        times.sort()
        return DNSTiming(name: label, medianMs: times.isEmpty ? nil : times[times.count / 2], answered: answered, asked: 5)
    }
    private static func doh(_ url: String) async -> WiFiProbe.Reply {
        guard let url = URL(string: url) else { return .unavailable }
        var request = URLRequest(url: url); request.setValue("application/dns-json", forHTTPHeaderField: "Accept"); request.timeoutInterval = 4
        let started = DispatchTime.now()
        guard let (_, response) = try? await URLSession(configuration: .ephemeral).data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 else { return .timedOut }
        return .answered(Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
    }

    // MARK: Sites
    var siteList: [String] {
        var list = ["https://www.apple.com", "https://www.cloudflare.com", "https://github.com"]
        let extra = customSite.trimmingCharacters(in: .whitespaces)
        if !extra.isEmpty { list.append(extra.hasPrefix("http") ? extra : "https://" + extra) }
        return list
    }

    /// Fetches the front of each page and reports where the time went: name lookup, connecting, the secure handshake, and the first byte.
    func checkSites() async {
        busy.insert("sites"); defer { busy.remove("sites") }
        var results: [SiteTiming] = []
        for address in siteList where !Task.isCancelled {
            guard let url = URL(string: address), url.scheme == "https" else { results.append(SiteTiming(url: address, failure: "Only https:// addresses are checked.")); continue }
            results.append(await Self.timeSite(url))
        }
        sites = results
    }
    private static func timeSite(_ url: URL) async -> SiteTiming {
        final class Collector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
            var metrics: URLSessionTaskMetrics?
            func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) { self.metrics = metrics }
        }
        let collector = Collector()
        let session = URLSession(configuration: { let c = URLSessionConfiguration.ephemeral; c.requestCachePolicy = .reloadIgnoringLocalCacheData; c.timeoutIntervalForRequest = 8; return c }(), delegate: collector, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url); request.httpMethod = "HEAD"
        var site = SiteTiming(url: url.absoluteString)
        do {
            let (_, response) = try await session.data(for: request)
            site.status = (response as? HTTPURLResponse)?.statusCode
        } catch { site.failure = (error as NSError).code == NSURLErrorTimedOut ? "Timed out." : "Could not connect." }
        if let m = collector.metrics?.transactionMetrics.last {
            func ms(_ a: Date?, _ b: Date?) -> Double? { guard let a, let b else { return nil }; return b.timeIntervalSince(a) * 1000 }
            site.dnsMs = ms(m.domainLookupStartDate, m.domainLookupEndDate)
            site.connectMs = ms(m.connectStartDate, m.secureConnectionStartDate ?? m.connectEndDate)
            site.tlsMs = ms(m.secureConnectionStartDate, m.secureConnectionEndDate)
            site.firstByteMs = ms(m.requestStartDate, m.responseStartDate)
            site.totalMs = ms(m.fetchStartDate, m.responseEndDate)
        }
        return site
    }

    // MARK: Local network (Bonjour)
    private static let bonjourTypes: [(String, String)] = [
        ("_airplay._tcp", "AirPlay"), ("_raop._tcp", "AirPlay audio"), ("_ipp._tcp", "Printer"), ("_printer._tcp", "Printer"), ("_http._tcp", "Web server"),
        ("_smb._tcp", "File sharing (SMB)"), ("_afpovertcp._tcp", "File sharing (AFP)"), ("_ssh._tcp", "Remote login"), ("_workstation._tcp", "Computer"),
        ("_homekit._tcp", "HomeKit"), ("_googlecast._tcp", "Chromecast"), ("_spotify-connect._tcp", "Spotify Connect"), ("_companion-link._tcp", "Apple device"),
    ]
    func startBrowsing() {
        guard !browsing else { return }
        browsing = true; devices = []
        for (type, kind) in Self.bonjourTypes {
            let b = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
            b.browseResultsChangedHandler = { [weak self] results, _ in
                let found = results.compactMap { result -> BonjourDevice? in
                    if case let .service(name, serviceType, _, _) = result.endpoint { return BonjourDevice(name: name, type: serviceType, kind: kind) }
                    return nil
                }
                Task { @MainActor in
                    guard let self else { return }
                    self.devices = Array(Set(self.devices.filter { $0.kind != kind }).union(found)).sorted { ($0.kind, $0.name) < ($1.kind, $1.name) }
                }
            }
            b.start(queue: .main)
            browser.append(b)
        }
        Task { [weak self] in try? await Task.sleep(for: .seconds(20)); self?.stopBrowsing() }
    }
    func stopBrowsing() { browser.forEach { $0.cancel() }; browser = []; browsing = false }

    // MARK: Nearby Wi-Fi
    /// A scan listens on each channel in turn, which briefly interrupts the connection, so it only runs when asked.
    func scanWiFi() async {
        scanning = true; scanNote = nil; defer { scanning = false }
        let result: (networks: [NearbyNetwork], note: String?) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let interface = CWWiFiClient.shared().interface() else { continuation.resume(returning: ([], "This Mac has no Wi-Fi adapter.")); return }
                do {
                    let found = try interface.scanForNetworks(withSSID: nil)
                    let mapped = found.compactMap { n -> NearbyNetwork? in
                        guard let c = n.wlanChannel else { return nil }
                        let band: WiFiBand
                        switch c.channelBand { case .band2GHz: band = .ghz2; case .band5GHz: band = .ghz5; case .band6GHz: band = .ghz6; default: band = WiFiBand.from(channel: c.channelNumber) }
                        return NearbyNetwork(channel: c.channelNumber, band: band, rssi: n.rssiValue)
                    }
                    continuation.resume(returning: (mapped, mapped.isEmpty ? "The scan found no networks." : nil))
                } catch { continuation.resume(returning: ([], "macOS did not allow the scan. Location permission may be needed (System Settings → Privacy & Security → Location Services).")) }
            }
        }
        nearby = result.networks; scanNote = result.note
    }

    // MARK: Lab
    func traceroute(to host: String = "1.1.1.1") async {
        tracing = true; hops = []; defer { tracing = false }
        let output = await Self.run("/usr/sbin/traceroute", ["-n", "-q", "1", "-w", "1", "-m", "20", host], timeout: 45)
        hops = TracerouteParser.parse(output)
    }

    func findPathMTU() async {
        mtuBusy = true; mtuNote = nil; pathMTU = nil; defer { mtuBusy = false }
        // Each step is one echo of a given payload size, marked "do not fragment". The system `ping` is used because it can set that mark.
        func passes(_ size: Int) async -> Bool {
            let out = await Self.run("/sbin/ping", ["-D", "-c", "1", "-t", "2", "-s", String(size), "1.1.1.1"], timeout: 4)
            return out.contains("1 packets received") || out.contains("bytes from")
        }
        var low = 1200, high = 1472
        guard await passes(low) else { mtuNote = "The test could not run: even a small packet got no answer. The network may block this kind of test."; return }
        if await passes(high) { pathMTU = high + PathMTU.ipAndICMPOverhead; return }
        while high - low > 1, !Task.isCancelled {
            let mid = (low + high) / 2
            if await passes(mid) { low = mid } else { high = mid }
        }
        pathMTU = low + PathMTU.ipAndICMPOverhead
    }

    /// How much a busy line slows everything else: the round trip when idle against the round trip while downloading. It uses real data for
    /// about eight seconds, so it asks first on a metered connection (the caller decides).
    func measureBufferbloat() async {
        bloatBusy = true; bloat = nil; bloatNote = nil; defer { bloatBusy = false }
        let idle = await Self.pings(count: 8, gap: 0.25)
        guard !idle.isEmpty else { bloatNote = "No replies from the internet, so the test cannot run."; return }
        let loaded = await Self.pingsUnderLoad()
        guard !loaded.isEmpty else { bloatNote = "No replies while the line was busy. The line may have been saturated; try again."; return }
        let idleMs = idle.sorted()[idle.count / 2], loadedMs = loaded.sorted()[loaded.count / 2]
        bloat = Bufferbloat.grade(idleMs: idleMs, loadedMs: loadedMs)
        bloatNote = String(format: "Idle %.0f ms, busy %.0f ms.", idleMs, loadedMs)
    }
    private static func pings(count: Int, gap: Double) async -> [Double] {
        var out: [Double] = []
        for i in 0..<count where !Task.isCancelled {
            let seq = UInt16(truncatingIfNeeded: 4000 + i)
            if case .answered(let ms) = await withCheckedContinuation({ (c: CheckedContinuation<WiFiProbe.Reply, Never>) in DispatchQueue.global(qos: .utility).async { c.resume(returning: WiFiProbe.ping("1.1.1.1", sequence: seq, timeout: 1.5)) } }) { out.append(ms) }
            try? await Task.sleep(for: .seconds(gap))
        }
        return out
    }
    private static func pingsUnderLoad() async -> [Double] {
        let sessions = (0..<6).map { _ in URLSession(configuration: { let c = URLSessionConfiguration.ephemeral; c.timeoutIntervalForRequest = 15; return c }()) }
        defer { sessions.forEach { $0.invalidateAndCancel() } }
        let loaders = sessions.map { s in Task { var r = URLRequest(url: URL(string: "https://mensura.cdn-apple.com/api/v1/gm/large")!); r.cachePolicy = .reloadIgnoringLocalCacheData; _ = try? await s.data(for: r) } }
        defer { loaders.forEach { $0.cancel() } }
        try? await Task.sleep(for: .seconds(1.5))                  // let the line fill first
        var out: [Double] = []
        for i in 0..<20 where !Task.isCancelled {
            let seq = UInt16(truncatingIfNeeded: 5000 + i)
            if case .answered(let ms) = await withCheckedContinuation({ (c: CheckedContinuation<WiFiProbe.Reply, Never>) in DispatchQueue.global(qos: .utility).async { c.resume(returning: WiFiProbe.ping("1.1.1.1", sequence: seq, timeout: 2)) } }) { out.append(ms) }
            try? await Task.sleep(for: .seconds(0.3))
        }
        return out
    }

    /// One connection attempt to one address and port the user typed. It never scans a range.
    func checkPort(host: String, port: String) async {
        busy.insert("port"); portResult = nil; defer { busy.remove("port") }
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty, let p = UInt16(port), p > 0 else { portResult = "Enter a host and a port number."; return }
        let started = DispatchTime.now()
        let ok = await Self.tcpConnect(host: h, port: p, timeout: 4)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        portResult = ok ? String(format: "%@:%d accepted a connection in %.0f ms.", h, Int(p), ms) : "\(h):\(p) did not accept a connection within 4 seconds. It may be closed, filtered, or the name may not resolve."
    }

    // MARK: Recovery (only on the user's confirmation)
    /// Switches Wi-Fi off and on again. That is all it does: nothing is left changed, and the result is recorded.
    func restartWiFi() async {
        busy.insert("restart"); defer { busy.remove("restart") }
        guard let interface = CWWiFiClient.shared().interface() else { record("Restart Wi-Fi", "No Wi-Fi adapter found."); return }
        do {
            try interface.setPower(false)
            try? await Task.sleep(for: .seconds(3))
            try interface.setPower(true)
            record("Restart Wi-Fi", "Wi-Fi was switched off and on. It takes a few seconds to reconnect.")
            note("recovery", "Wi-Fi was restarted from VayuSetu.")
        } catch {
            try? interface.setPower(true)               // never leave the radio off
            record("Restart Wi-Fi", "macOS did not allow it, and Wi-Fi was left on.")
        }
    }
    private func record(_ action: String, _ outcome: String) {
        recoveries.insert(RecoveryRecord(action: action, outcome: outcome), at: 0)
        if recoveries.count > 30 { recoveries.removeLast(recoveries.count - 30) }
        if let d = try? JSONEncoder().encode(recoveries) { UserDefaults.standard.set(d, forKey: Self.recoveryKey) }
    }

    // MARK: Plumbing
    /// Runs a system tool and returns what it printed, giving up after `timeout` seconds, or at once if the task is cancelled.
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) async -> String {
        final class Box: @unchecked Sendable {
            let lock = NSLock(); var process: Process?
            func stop() { lock.lock(); if let p = process, p.isRunning { p.terminate() }; lock.unlock() }
        }
        let box = Box()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
                    let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
                    box.lock.lock(); box.process = process; box.lock.unlock()
                    guard (try? process.run()) != nil else { continuation.resume(returning: ""); return }
                    let killer = DispatchWorkItem { box.stop() }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit(); killer.cancel()
                    continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
                }
            }
        } onCancel: { box.stop() }
    }

    static func tcpConnect(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 443, using: .tcp)
            final class Once: @unchecked Sendable { var done = false; let lock = NSLock() }
            let once = Once()
            @Sendable func finish(_ ok: Bool) { once.lock.lock(); defer { once.lock.unlock() }; guard !once.done else { return }; once.done = true; connection.cancel(); continuation.resume(returning: ok) }
            connection.stateUpdateHandler = { state in
                switch state { case .ready: finish(true); case .failed, .cancelled: finish(false); default: break }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    static func aaaaLookup(_ name: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo(); hints.ai_family = AF_INET6; hints.ai_socktype = SOCK_STREAM
                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(name, nil, &hints, &result)
                if let result { freeaddrinfo(result) }
                continuation.resume(returning: status == 0)
            }
        }
    }

    struct RawResponse { var status: Int?; var body: String?; var location: String?; var failed: Bool }
    static func rawHTTP(host: String, path: String) async -> RawResponse {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: 80, using: .tcp)
            final class Once: @unchecked Sendable { var done = false; let lock = NSLock() }
            let once = Once()
            @Sendable func finish(_ r: RawResponse) { once.lock.lock(); defer { once.lock.unlock() }; guard !once.done else { return }; once.done = true; connection.cancel(); continuation.resume(returning: r) }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let request = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\nUser-Agent: CaptiveNetworkSupport\r\n\r\n"
                    connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                        guard let data, error == nil, let text = String(data: data, encoding: .utf8) else { finish(RawResponse(failed: true)); return }
                        let head = text.components(separatedBy: "\r\n\r\n")
                        let lines = head[0].components(separatedBy: "\r\n")
                        let status = lines.first.flatMap { $0.split(separator: " ").dropFirst().first }.flatMap { Int($0) }
                        let location = lines.first { $0.lowercased().hasPrefix("location:") }
                        finish(RawResponse(status: status, body: head.count > 1 ? head[1] : nil, location: location, failed: false))
                    }
                case .failed, .cancelled: finish(RawResponse(failed: true))
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { finish(RawResponse(failed: true)) }
        }
    }
}
