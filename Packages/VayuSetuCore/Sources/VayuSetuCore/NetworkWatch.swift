import CryptoKit
import Foundation

/// The watching and reporting rules of Connection Health, the pure part: how often to sample, whether a router has been swapped for another,
/// whether a network is slower than it usually is, and the internet-quality report. Nothing here touches the network.

// MARK: Sampling policy
public enum SamplingPolicy {
    public struct Conditions: Equatable, Sendable {
        public var expensive = false          // a hotspot or a metered link
        public var constrained = false        // Low Data Mode
        public var lowPower = false           // Low Power Mode
        public var onBattery = false
        public var windowInBackground = false // the app has nothing on screen
        public var stable = false             // no stall or suspicion for a while
        public init(expensive: Bool = false, constrained: Bool = false, lowPower: Bool = false, onBattery: Bool = false, windowInBackground: Bool = false, stable: Bool = false) {
            self.expensive = expensive; self.constrained = constrained; self.lowPower = lowPower; self.onBattery = onBattery; self.windowInBackground = windowInBackground; self.stable = stable
        }
    }
    public static let fastest = 3.0, slowest = 30.0

    /// Seconds between rounds. It starts at 3 and only ever gets slower: on a metered link, in Low Power Mode, on battery with nothing on screen,
    /// and when everything has been steady for a while. A suspected stall always returns to the fastest rate so an incident is captured in detail.
    public static func interval(_ c: Conditions, suspicious: Bool) -> Double {
        if suspicious { return fastest }
        var seconds = fastest
        if c.expensive || c.constrained { seconds = max(seconds, 12) }
        if c.lowPower { seconds = max(seconds, 15) }
        if c.onBattery && c.windowInBackground { seconds = max(seconds, 10) }
        if c.stable { seconds *= 2 }
        return min(slowest, seconds)
    }
}

// MARK: Gateway identity
public struct ARPEntry: Equatable, Sendable { public let ip: String; public let mac: String
    public init(ip: String, mac: String) { self.ip = ip; self.mac = mac } }

public enum ARPParser {
    /// Parses `arp -n` or `arp -an` lines such as `? (192.168.1.1) at a4:2b:b0:12:34:56 on en0 ifscope [ethernet]` or `192.168.1.1 ether a4:2b:...`.
    public static func parse(_ output: String) -> [ARPEntry] {
        var out: [ARPEntry] = []
        for line in output.split(separator: "\n") {
            guard !line.contains("(incomplete)") else { continue }
            var ip: String?, mac: String?
            if let open = line.firstIndex(of: "("), let close = line.firstIndex(of: ")"), open < close { ip = String(line[line.index(after: open)..<close]) }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if ip == nil, let first = tokens.first, first.split(separator: ".").count == 4 { ip = first }
            if let at = tokens.firstIndex(of: "at"), at + 1 < tokens.count { mac = tokens[at + 1] }
            else if let eth = tokens.firstIndex(where: { $0 == "ether" || $0 == "ethernet" }), eth + 1 < tokens.count { mac = tokens[eth + 1] }
            if let ip, let mac, mac.contains(":") { out.append(ARPEntry(ip: ip, mac: normalise(mac))) }
        }
        return out
    }
    /// Pads each byte to two digits, since macOS prints `a:b:0:1:2:3` for `0a:0b:00:01:02:03`.
    public static func normalise(_ mac: String) -> String {
        mac.split(separator: ":").map { $0.count == 1 ? "0" + $0 : String($0) }.joined(separator: ":").lowercased()
    }
    /// Another machine on the network answering for the same address shows up as one address with two different hardware addresses over time, or
    /// one hardware address claiming several addresses (normal for a router, suspicious for anything else).
    public static func duplicates(_ entries: [ARPEntry], gateway: String?) -> [String] {
        var byMAC: [String: [String]] = [:]
        for e in entries { byMAC[e.mac, default: []].append(e.ip) }
        var out: [String] = []
        for (mac, addresses) in byMAC where addresses.count > 1 {
            if let gateway, addresses.contains(gateway) { continue }
            out.append("\(mac) answers for \(addresses.sorted().joined(separator: ", "))")
        }
        return out.sorted()
    }
}

public enum GatewayIdentity {
    public struct Verdict: Equatable, Sendable { public let changed: Bool; public let text: String }
    /// The router's hardware address, compared with the one seen last time for the same network. A change on a network you stayed on is the sign
    /// of a swapped router, a second DHCP server, or a device pretending to be the router. It is a prompt to look, not proof of an attack: a
    /// router restart or a mesh handover can also do it.
    public static func compare(known: [String: String], key: String, mac: String) -> Verdict {
        guard let old = known[key] else { return Verdict(changed: false, text: "First time this router is seen, so there is nothing to compare with yet.") }
        if old == mac { return Verdict(changed: false, text: "The router's hardware address is the same as before.") }
        return Verdict(changed: true, text: "The router's hardware address changed from \(old) to \(mac) on a network you stayed on. A restart, a mesh handover or a replaced router can cause this; so can another device answering as the router.")
    }
}

// MARK: Network identity
public enum NetworkIdentity {
    /// A stable, opaque key for "this network", used to keep a network's baseline apart from every other. Two different networks very often share
    /// a router address (192.168.1.1 is the default of half the world's routers), and the network's name is hidden without Location permission, so
    /// the router's hardware address is part of the key. Nil until the router has been identified: nothing is learned about a network that cannot
    /// yet be told apart from another. The key is a hash, so the stored value holds no name and no address.
    public static func key(primary: String, ssid: String?, gatewayIP: String?, gatewayMAC: String?) -> String? {
        guard let gatewayIP, let gatewayMAC, !gatewayMAC.isEmpty else { return nil }
        let text = [primary, ssid ?? "", gatewayIP, gatewayMAC.lowercased()].joined(separator: "|")
        return SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: Per-network baselines
public struct NetworkBaseline: Codable, Equatable, Sendable {
    public var medianMs: Double
    public var samples: Int
    /// How many updates in a row have been far slower than the usual. A short run is a bad spell; a very long one means the network changed.
    public var outlierStreak: Int
    public init(medianMs: Double, samples: Int, outlierStreak: Int = 0) { self.medianMs = medianMs; self.samples = samples; self.outlierStreak = outlierStreak }
    private enum CodingKeys: String, CodingKey { case medianMs, samples, outlierStreak }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        medianMs = try c.decode(Double.self, forKey: .medianMs); samples = try c.decode(Int.self, forKey: .samples)
        outlierStreak = try c.decodeIfPresent(Int.self, forKey: .outlierStreak) ?? 0
    }
}

public enum Baselines {
    public static let minimumSamples = 60
    /// One update is made every 60 probe rounds (about three minutes at the usual rate), so this is roughly fifteen hours.
    public static let acceptAfterOutliers = 300
    public static let settledWeight = 0.02

    public static func isOutlier(_ known: NetworkBaseline, median: Double) -> Bool {
        known.samples >= minimumSamples && median > max(known.medianMs * 3, known.medianMs + 15)
    }

    /// Folds a typical-latency reading into what is known about this network. While little is known each reading counts as much as the ones
    /// before (a running average); once settled each counts about a fiftieth. A reading far slower than the usual is not folded in at all, so a
    /// bad hour cannot become the normal; only a very long run of them (the network really changed, a router was replaced) is accepted, quickly.
    public static func update(_ known: NetworkBaseline?, median: Double) -> NetworkBaseline {
        guard var next = known else { return NetworkBaseline(medianMs: median, samples: 1) }
        if isOutlier(next, median: median) {
            next.outlierStreak += 1
            if next.outlierStreak >= acceptAfterOutliers { next.medianMs += (median - next.medianMs) * 0.5; next.samples += 1 }
            return next
        }
        next.outlierStreak = 0
        let weight = max(settledWeight, 1 / Double(next.samples + 1))
        next.medianMs += (median - next.medianMs) * weight
        next.samples += 1
        return next
    }

    /// A sentence when the network is clearly slower than usual, otherwise nil. It needs enough history to mean something.
    public static func remark(known: NetworkBaseline?, nowMs: Double?) -> String? {
        guard let known, known.samples >= minimumSamples, let nowMs else { return nil }
        let usual = max(known.medianMs, 1)
        if nowMs > max(usual * 3, usual + 15) { return String(format: "The router is answering in %.0f ms, about %.0f times its usual %.0f ms on this network.", nowMs, nowMs / usual, usual) }
        return nil
    }
}

// MARK: Hotspots
public enum HotspotHint {
    /// A phone sharing its connection hands out a recognisable router address: iPhone Personal Hotspot uses 172.20.10.1, Android 192.168.43.1 or
    /// 192.168.42.1. This is a guess from the address, so it is worded as a likelihood.
    public static func detect(gateway: String?, expensive: Bool) -> String? {
        guard let gateway else { return nil }
        if gateway.hasPrefix("172.20.10.") { return "This looks like an iPhone Personal Hotspot. It uses your phone's mobile data, so heavy tests are switched off." }
        if gateway.hasPrefix("192.168.43.") || gateway.hasPrefix("192.168.42.") { return "This looks like a phone's hotspot. It likely uses mobile data, so heavy tests are switched off." }
        return expensive ? "macOS reports this connection as costing data, so heavy tests are switched off." : nil
    }
}

// MARK: Internet quality report
public struct QualitySummary: Equatable, Sendable {
    public let days: Int
    public let uptime: Double?
    public let medianMs: Double?
    public let stalls: Int
    public let stallMinutes: Int
    public let worstDay: Int?
    public let worstHour: Int?
    /// The first and last day that had enough monitoring to count (days since 1970).
    public let firstDay: Int?
    public let lastDay: Int?
    public var verdict: String {
        guard let uptime else { return "Not enough monitoring yet to judge the connection." }
        if uptime >= 0.999 && stalls == 0 { return "Excellent: the router answered almost every check and nothing stalled." }
        if uptime >= 0.99 { return "Good: occasional lost checks, nothing that should be noticeable." }
        if uptime >= 0.95 { return "Fair: noticeable gaps. Worth looking at the stall history." }
        return "Poor: the router missed many checks. Compare a wired connection to tell the Wi-Fi from the line."
    }
}

public enum QualityReport {
    public static func summarise(_ days: [DayQuality]) -> QualitySummary {
        let counted = days.filter { $0.rounds >= 10 }
        let rounds = counted.reduce(0) { $0 + $1.rounds }, lost = counted.reduce(0) { $0 + $1.gatewayLost }
        let uptime = rounds >= 30 ? 1 - Double(lost) / Double(rounds) : nil
        var merged = [Int](repeating: 0, count: 7)
        for d in counted { for i in 0..<7 { merged[i] += d.latencyBuckets[i] } }
        let total = merged.reduce(0, +)
        var median: Double?
        if total >= 30 {
            var seen = 0
            for (i, c) in merged.enumerated() { seen += c; if seen * 2 >= total {
                let upper = i < DayQuality.bucketLimits.count ? DayQuality.bucketLimits[i] : 600
                let lower = i == 0 ? 0 : DayQuality.bucketLimits[i - 1]
                median = (lower + upper) / 2; break } }
        }
        let worstDay = counted.filter { $0.uptime != nil }.min { ($0.uptime ?? 1) < ($1.uptime ?? 1) }
        var hourRounds = [Int](repeating: 0, count: 24), hourLost = [Int](repeating: 0, count: 24)
        for d in counted { for h in 0..<24 { hourRounds[h] += d.hourRounds[h]; hourLost[h] += d.hourLost[h] } }
        let worstHour = (0..<24).filter { hourRounds[$0] >= 20 && hourLost[$0] > 0 }.max { Double(hourLost[$0]) / Double(hourRounds[$0]) < Double(hourLost[$1]) / Double(hourRounds[$1]) }
        return QualitySummary(days: counted.count, uptime: uptime, medianMs: median, stalls: counted.reduce(0) { $0 + $1.stalls }, stallMinutes: counted.reduce(0) { $0 + $1.stallSeconds } / 60,
                              worstDay: worstDay?.day, worstHour: worstHour, firstDay: counted.map(\.day).min(), lastDay: counted.map(\.day).max())
    }

    /// A report to paste into a message to a provider or a support desk. It has no addresses and no network names.
    public static func text(_ s: QualitySummary, speeds: [(mode: String, down: Double, up: Double, latencyMs: Double?, date: Date)], dayName: (Int) -> String) -> String {
        var lines = ["Internet quality report (from VayuSetu, measured on this Mac)", ""]
        if let first = s.firstDay, let last = s.lastDay {
            lines.append("Period observed: \(dayName(first)) to \(dayName(last)), \(s.days) day\(s.days == 1 ? "" : "s") with monitoring")
        } else { lines.append("Period observed: not enough monitoring yet") }
        if let u = s.uptime { lines.append(String(format: "Router answered: %.2f%% of checks", u * 100)) }
        if let m = s.medianMs { lines.append(String(format: "Typical router reply: about %.0f ms", m)) }
        lines.append("Stalls: \(s.stalls), about \(s.stallMinutes) minutes in all")
        if let d = s.worstDay { lines.append("Worst day: \(dayName(d))") }
        if let h = s.worstHour { lines.append(String(format: "Most missed checks around %02d:00", h)) }
        lines.append("Verdict: \(s.verdict)")
        if !speeds.isEmpty {
            lines.append(""); lines.append("Speed tests:")
            for t in speeds.prefix(10) {
                lines.append(String(format: "- %@: down %.1f Mbit/s, up %.1f Mbit/s", t.mode, t.down * 8 / 1e6, t.up * 8 / 1e6) + (t.latencyMs.map { String(format: ", %.0f ms", $0) } ?? ""))
            }
        }
        lines.append(""); lines.append("The router checks measure this Mac's link to its router, so a problem shown here may be the Wi-Fi, not the provider.")
        return lines.joined(separator: "\n")
    }
}
