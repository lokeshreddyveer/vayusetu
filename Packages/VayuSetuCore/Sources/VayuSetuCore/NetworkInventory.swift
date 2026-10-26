import Foundation

/// The network inventory, daily quality history, DHCP parsing and VPN leak check: the pure parts of Connection Health's later phases.

// MARK: Interfaces
public enum InterfaceKind: String, Sendable, Equatable, CaseIterable {
    case wifi = "Wi-Fi", ethernet = "Ethernet", thunderbolt = "Thunderbolt", usb = "USB network", bridge = "Bridge", tunnel = "Tunnel (VPN)", cellular = "Cellular", loopback = "Loopback", virtual = "Virtual", other = "Other"
    public var icon: String {
        switch self {
        case .wifi: "wifi"; case .ethernet: "cable.connector"; case .thunderbolt: "bolt.horizontal"; case .usb: "cable.connector.horizontal"
        case .bridge: "rectangle.connected.to.line.below"; case .tunnel: "lock.shield"; case .cellular: "antenna.radiowaves.left.and.right"
        case .loopback: "arrow.triangle.2.circlepath"; case .virtual: "square.stack.3d.up"; case .other: "network"
        }
    }

    /// Works out what an interface is from its system type and display name (both from SystemConfiguration), falling back to its BSD name. The
    /// display name is how a USB or Thunderbolt adapter is recognised: macOS names them ("USB 10/100/1000 LAN", "Thunderbolt Ethernet").
    public static func classify(bsdName: String, systemType: String?, displayName: String?) -> InterfaceKind {
        let name = (displayName ?? "").lowercased()
        switch systemType {
        case "IEEE80211": return .wifi
        case "Bridge": return .bridge
        case "VPN", "PPP", "L2TP", "IPSec": return .tunnel
        case "WWAN": return .cellular
        default: break
        }
        if bsdName.hasPrefix("lo") { return .loopback }
        if bsdName.hasPrefix("utun") || bsdName.hasPrefix("ipsec") || bsdName.hasPrefix("ppp") { return .tunnel }
        if bsdName.hasPrefix("bridge") { return .bridge }
        if bsdName.hasPrefix("awdl") || bsdName.hasPrefix("llw") || bsdName.hasPrefix("anpi") || bsdName.hasPrefix("ap") || bsdName.hasPrefix("gif") || bsdName.hasPrefix("stf") { return .virtual }
        if name.contains("thunderbolt") { return .thunderbolt }
        if name.contains("usb") { return .usb }
        if name.contains("wi-fi") || name.contains("airport") { return .wifi }
        if systemType == "Ethernet" || name.contains("ethernet") || name.contains("lan") { return .ethernet }
        if bsdName.hasPrefix("en") { return .other }
        return .other
    }
}

public struct InterfaceInfo: Equatable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let kind: InterfaceKind
    public let display: String
    public let up: Bool
    public let running: Bool
    public let speedMbps: Double?
    public let mtu: Int?
    public let addresses: [String]
    public let rxBytes: UInt64
    public let txBytes: UInt64
    public init(name: String, kind: InterfaceKind, display: String, up: Bool, running: Bool, speedMbps: Double?, mtu: Int?, addresses: [String], rxBytes: UInt64, txBytes: UInt64) {
        self.name = name; self.kind = kind; self.display = display; self.up = up; self.running = running; self.speedMbps = speedMbps; self.mtu = mtu
        self.addresses = addresses; self.rxBytes = rxBytes; self.txBytes = txBytes
    }
    /// Carrying traffic: up, running, and holding an address that is not link-local.
    public var active: Bool { up && running && addresses.contains { !$0.hasPrefix("fe80") && !$0.hasPrefix("169.254") } }
    /// Only interfaces worth showing: real links and tunnels that are active, plus any real link that is up.
    public var worthShowing: Bool { kind != .loopback && kind != .virtual && (active || (up && [.wifi, .ethernet, .thunderbolt, .usb, .cellular].contains(kind))) }
}

public enum ByteFormat {
    public static func text(_ bytes: UInt64) -> String {
        let b = Double(bytes)
        if b >= 1e9 { return String(format: "%.1f GB", b / 1e9) }
        if b >= 1e6 { return String(format: "%.0f MB", b / 1e6) }
        if b >= 1e3 { return String(format: "%.0f KB", b / 1e3) }
        return "\(bytes) B"
    }
}

// MARK: DHCP
public struct DHCPInfo: Equatable, Sendable {
    public var subnetMask: String?
    public var server: String?
    public var leaseSeconds: Int?
    public var routers: [String] = []
    public var dns: [String] = []
    public init() {}
    public var leaseText: String? {
        guard let s = leaseSeconds else { return nil }
        if s >= 86400 { return "\(s / 86400) day" + (s / 86400 == 1 ? "" : "s") }
        if s >= 3600 { return "\(s / 3600) hour" + (s / 3600 == 1 ? "" : "s") }
        return "\(max(1, s / 60)) minutes"
    }
}

public enum DHCPParser {
    /// Parses `ipconfig getpacket`. Lines look like `subnet_mask (ip): 255.255.255.0`, `lease_time (uint32): 0x15180`, `router (ip_mult): {192.168.1.1}`.
    public static func parse(_ output: String) -> DHCPInfo {
        var info = DHCPInfo()
        for line in output.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].split(separator: " ").first.map(String.init) ?? ""
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            func list() -> [String] { value.trimmingCharacters(in: CharacterSet(charactersIn: "{}")).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            switch key {
            case "subnet_mask": info.subnetMask = value
            case "server_identifier": info.server = value
            case "lease_time":
                if value.hasPrefix("0x") { info.leaseSeconds = Int(value.dropFirst(2), radix: 16) } else { info.leaseSeconds = Int(value) }
            case "router": info.routers = list()
            case "domain_name_server": info.dns = list()
            default: break
            }
        }
        return info
    }
}

// MARK: Daily quality history
/// One day of internet quality, kept as counts and a small histogram, so it stays tiny and exact enough to answer "how was this week".
public struct DayQuality: Codable, Equatable, Sendable {
    public static let bucketLimits: [Double] = [5, 10, 20, 50, 100, 300]          // upper bounds in ms; a last bucket holds everything above
    public var day: Int
    public var rounds = 0
    public var gatewayLost = 0
    public var internetRounds = 0
    public var internetLost = 0
    public var stalls = 0
    public var stallSeconds = 0
    public var latencyBuckets = [Int](repeating: 0, count: 7)
    /// Checks and lost checks by hour of the day (0...23), so the report can say when the line is worst. Files saved before this existed
    /// decode with zeros.
    public var hourRounds = [Int](repeating: 0, count: 24)
    public var hourLost = [Int](repeating: 0, count: 24)
    public init(day: Int) { self.day = day }

    private enum CodingKeys: String, CodingKey { case day, rounds, gatewayLost, internetRounds, internetLost, stalls, stallSeconds, latencyBuckets, hourRounds, hourLost }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(Int.self, forKey: .day)
        rounds = try c.decodeIfPresent(Int.self, forKey: .rounds) ?? 0
        gatewayLost = try c.decodeIfPresent(Int.self, forKey: .gatewayLost) ?? 0
        internetRounds = try c.decodeIfPresent(Int.self, forKey: .internetRounds) ?? 0
        internetLost = try c.decodeIfPresent(Int.self, forKey: .internetLost) ?? 0
        stalls = try c.decodeIfPresent(Int.self, forKey: .stalls) ?? 0
        stallSeconds = try c.decodeIfPresent(Int.self, forKey: .stallSeconds) ?? 0
        let buckets = try c.decodeIfPresent([Int].self, forKey: .latencyBuckets) ?? []
        latencyBuckets = buckets.count == 7 ? buckets : [Int](repeating: 0, count: 7)
        let hr = try c.decodeIfPresent([Int].self, forKey: .hourRounds) ?? [], hl = try c.decodeIfPresent([Int].self, forKey: .hourLost) ?? []
        hourRounds = hr.count == 24 ? hr : [Int](repeating: 0, count: 24)
        hourLost = hl.count == 24 ? hl : [Int](repeating: 0, count: 24)
    }

    public mutating func add(_ round: ProbeRound, hour: Int? = nil) {
        rounds += 1
        if let hour, (0..<24).contains(hour) { hourRounds[hour] += 1; if round.gatewayAnswered == false { hourLost[hour] += 1 } }
        if round.gatewayAnswered == false { gatewayLost += 1 }
        if let internet = round.internetAnswered { internetRounds += 1; if !internet { internetLost += 1 } }
        if let ms = round.gatewayMs, round.gatewayAnswered == true {
            let index = Self.bucketLimits.firstIndex { ms <= $0 } ?? Self.bucketLimits.count
            latencyBuckets[index] += 1
        }
    }
    public mutating func addStall(seconds: Int) { stalls += 1; stallSeconds += seconds }

    /// The share of probe rounds in which the router answered, 0...1. Nil with too little data to say.
    public var uptime: Double? { rounds >= 10 ? 1 - Double(gatewayLost) / Double(rounds) : nil }
    /// An estimate of the median router latency, from the histogram (the middle of the bucket that holds the middle reading).
    public var medianMs: Double? {
        let total = latencyBuckets.reduce(0, +)
        guard total >= 10 else { return nil }
        var seen = 0
        for (i, count) in latencyBuckets.enumerated() {
            seen += count
            if seen * 2 >= total {
                let upper = i < Self.bucketLimits.count ? Self.bucketLimits[i] : 600
                let lower = i == 0 ? 0 : Self.bucketLimits[i - 1]
                return (lower + upper) / 2
            }
        }
        return nil
    }
}

public enum QualityHistory {
    public static let keepDays = 30
    /// Adds a round to today's record, starting a new day when the date moves on, and drops days older than `keepDays`.
    public static func record(_ round: ProbeRound, into days: inout [DayQuality], today: Int, hour: Int? = nil) {
        if days.last?.day != today { days.append(DayQuality(day: today)) }
        days[days.count - 1].add(round, hour: hour)
        days.removeAll { $0.day < today - keepDays + 1 }
    }
    public static func recordStall(seconds: Int, into days: inout [DayQuality], today: Int) {
        if days.last?.day != today { days.append(DayQuality(day: today)) }
        days[days.count - 1].addStall(seconds: seconds)
    }
}

// MARK: VPN leak check
public enum LeakCheck {
    /// Compares the address websites see now with the one seen when the VPN was off. A VPN that works changes it; an unchanged address with the
    /// VPN on means traffic is leaving outside the tunnel. IPv6 is reported separately, because a working IPv6 path under a VPN that does not
    /// carry IPv6 is the other common leak.
    public static func assess(vpnOn: Bool, publicIP: String?, baselineIP: String?, ipv6WorksDirectly: Bool?) -> [AdvisorFinding] {
        guard vpnOn else {
            return [AdvisorFinding(id: "leak", severity: .info, title: "The VPN is off", detail: "Your public address is your own. Look it up once with the VPN off, and VayuSetu can later tell whether the VPN changes it.")]
        }
        var out: [AdvisorFinding] = []
        if let publicIP, let baselineIP {
            if publicIP == baselineIP { out.append(AdvisorFinding(id: "leak", severity: .attention, title: "The VPN is on, but your address did not change", detail: "Websites still see the address you had without the VPN (\(publicIP)). Traffic may be leaving outside the tunnel. Reconnect the VPN and look the address up again.")) }
            else { out.append(AdvisorFinding(id: "leak", severity: .ok, title: "The VPN changes your public address", detail: "Websites see a different address from the one you had without the VPN.")) }
        } else if publicIP != nil {
            out.append(AdvisorFinding(id: "leak", severity: .info, title: "No address to compare with", detail: "Turn the VPN off, look up your public address, then turn it on and look again. VayuSetu then tells you if the address changed."))
        }
        if ipv6WorksDirectly == true {
            out.append(AdvisorFinding(id: "ipv6", severity: .info, title: "IPv6 works while the VPN is on", detail: "If your VPN server does not carry IPv6, that traffic bypasses it. VayuSetu's WireGuard setup blocks IPv6 by default; if you turned that off, check that the VPN supports it."))
        }
        return out
    }
}
