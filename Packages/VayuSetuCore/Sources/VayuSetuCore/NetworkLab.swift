import Foundation

/// The network lab and the advisors, the pure part. The app runs the probes and commands; this file turns their output into answers, and every
/// verdict says what it was based on. Nothing here opens a socket or a process.

// MARK: Captive portal
public enum CaptivePortal {
    public enum Verdict: String, Sendable { case open = "Open internet", portal = "Sign-in page in the way", offline = "No connection", unknown = "Could not tell" }
    /// Apple's connectivity check answers a small page containing "Success" when the internet is open. A portal rewrites that answer (a redirect, or its
    /// own page), so any other answer from a reachable server means something stood in the way.
    public static func classify(status: Int?, body: String?, redirected: Bool, failed: Bool) -> Verdict {
        if failed { return .offline }
        guard let status else { return .unknown }
        if redirected || (300...399).contains(status) { return .portal }
        if status == 200 {
            if let body, body.contains("Success") { return .open }
            return body == nil ? .unknown : .portal
        }
        if status == 511 { return .portal }                      // "network authentication required"
        return .unknown
    }
}

// MARK: Traceroute
public struct TracerouteHop: Equatable, Identifiable, Sendable {
    public let index: Int
    public let host: String?          // nil when no router answered at this step
    public let ms: Double?
    public var id: Int { index }
    public init(index: Int, host: String?, ms: Double?) { self.index = index; self.host = host; self.ms = ms }
}

public enum TracerouteParser {
    /// Parses `traceroute -n` output. A line is a hop number followed by an address and times, or by `*` for a silent hop. Anything else (the header,
    /// warnings) is ignored.
    public static func parse(_ output: String) -> [TracerouteHop] {
        var hops: [TracerouteHop] = []
        for raw in output.split(separator: "\n") {
            let tokens = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let first = tokens.first, let index = Int(first), index >= 1, index <= 64 else { continue }
            var host: String?, times: [Double] = []
            var i = 1
            while i < tokens.count {
                let t = tokens[i]
                if t == "*" { i += 1; continue }
                if t == "ms" { i += 1; continue }
                if let value = Double(t), i + 1 < tokens.count, tokens[i + 1] == "ms" { times.append(value); i += 2; continue }
                if host == nil, t.contains(".") || t.contains(":") { host = t.trimmingCharacters(in: CharacterSet(charactersIn: "()")) }
                i += 1
            }
            hops.append(TracerouteHop(index: index, host: host, ms: times.min()))
        }
        return hops
    }

    /// The hop where the time first jumps by a lot, the usual sign of where a slow path begins. Silent hops are skipped: many routers refuse to
    /// answer these probes, and that says nothing about the traffic that passes through them.
    public static func jump(in hops: [TracerouteHop], threshold: Double = 60) -> TracerouteHop? {
        var previous: Double?
        for hop in hops {
            guard let ms = hop.ms else { continue }
            if let p = previous, ms - p >= threshold { return hop }
            previous = ms
        }
        return nil
    }
}

// MARK: Path MTU
public enum PathMTU {
    public static let ipAndICMPOverhead = 28
    /// The biggest payload that gets through, by bisection. `passes(size)` reports whether a packet of that payload size, marked "do not fragment",
    /// was answered. Returns nil when even the smallest does not pass (the path could not be tested), otherwise the MTU (payload plus 28).
    public static func search(low: Int = 1200, high: Int = 1472, passes: (Int) -> Bool) -> Int? {
        guard passes(low) else { return nil }
        var lo = low, hi = high
        if passes(hi) { return hi + ipAndICMPOverhead }
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if passes(mid) { lo = mid } else { hi = mid }
        }
        return lo + ipAndICMPOverhead
    }
    public static func comment(_ mtu: Int) -> String {
        switch mtu {
        case 1500...: return "Normal (1500). Nothing to change."
        case 1400..<1500: return "Slightly below 1500, which is typical behind a tunnel, PPPoE or a VPN. It is harmless unless pages stall on large uploads."
        default: return "Low. Large packets are being cut down, which can make some sites hang. A router or VPN setting is the likely cause."
        }
    }
}

// MARK: Bufferbloat
public enum Bufferbloat {
    public struct Result: Equatable, Sendable { public let grade: String; public let addedMs: Double; public let text: String }
    /// Grades how much a busy line slows everything else down. This is the delay added by a saturated connection, compared with the same line idle.
    public static func grade(idleMs: Double, loadedMs: Double) -> Result {
        let added = max(0, loadedMs - idleMs)
        switch added {
        case ..<5: return Result(grade: "A+", addedMs: added, text: "Excellent. The connection stays responsive even while it is busy.")
        case ..<30: return Result(grade: "A", addedMs: added, text: "Very good. A busy line adds little delay.")
        case ..<60: return Result(grade: "B", addedMs: added, text: "Good. Fine for video calls, though a little delay builds up under load.")
        case ..<200: return Result(grade: "C", addedMs: added, text: "Noticeable. Calls and games can stutter while something large downloads. Turning on smart queue management (SQM) on the router helps.")
        case ..<400: return Result(grade: "D", addedMs: added, text: "Poor. The router queues too much while busy. Enable SQM or fq_codel if the router offers it.")
        default: return Result(grade: "F", addedMs: added, text: "Severe. Anything real-time will suffer while the line is busy. This is the main thing to fix on the router.")
        }
    }
}

// MARK: Wi-Fi channels
public struct NearbyNetwork: Equatable, Sendable {
    public let channel: Int
    public let band: WiFiBand
    public let rssi: Int
    public init(channel: Int, band: WiFiBand, rssi: Int) { self.channel = channel; self.band = band; self.rssi = rssi }
}

public enum ChannelAdvisor {
    /// How crowded a channel is: nearby networks add to it by how strong they are and how much their channel overlaps. On 2.4 GHz channels are
    /// 5 MHz apart but about 22 MHz wide, so channels within four numbers overlap; on 5 and 6 GHz only the same channel counts.
    public static func congestion(channel: Int, band: WiFiBand, networks: [NearbyNetwork]) -> Double {
        var total = 0.0
        for n in networks where n.band == band {
            let distance = abs(n.channel - channel)
            let overlap: Double
            if band == .ghz2 { overlap = distance >= 5 ? 0 : 1 - Double(distance) / 5 } else { overlap = distance == 0 ? 1 : 0 }
            guard overlap > 0 else { continue }
            let strength = max(0, min(1, Double(n.rssi + 95) / 50))     // -95 dBm counts as nothing, -45 dBm as everything
            total += overlap * strength
        }
        return total
    }

    /// Plain-language advice from the networks around. It names a better channel only when it is clearly better, and says plainly when the
    /// congestion looks fine.
    public static func advice(ownChannel: Int?, ownBand: WiFiBand, ownWidthMHz: Int?, networks: [NearbyNetwork]) -> [String] {
        guard let ownChannel, ownBand != .unknown else { return ["Connect to Wi-Fi and scan to see how crowded your channel is."] }
        var out: [String] = []
        let own = congestion(channel: ownChannel, band: ownBand, networks: networks)
        let candidates: [Int]
        switch ownBand { case .ghz2: candidates = [1, 6, 11]; case .ghz5: candidates = [36, 40, 44, 48, 149, 153, 157, 161]; case .ghz6: candidates = Array(stride(from: 1, through: 233, by: 16)); case .unknown: candidates = [] }
        let best = candidates.map { ($0, congestion(channel: $0, band: ownBand, networks: networks)) }.min { $0.1 < $1.1 }
        if own < 0.8 { out.append("Your channel (\(ownChannel)) is not crowded: about \(networks.filter { $0.band == ownBand }.count) other networks on this band, with little overlap.") }
        else if let best, best.0 != ownChannel, best.1 < own * 0.6 {
            out.append("Your channel (\(ownChannel)) is crowded. Channel \(best.0) looks clearer. If you control the router, set it there, or leave the channel on automatic.")
        } else { out.append("Your channel (\(ownChannel)) is busy, and none of the others is clearly better. More networks around than channels is normal in a flat or an office.") }
        if ownBand == .ghz2, let w = ownWidthMHz, w > 20 { out.append("On 2.4 GHz a 40 MHz width takes up more of a crowded band. Apple recommends 20 MHz there.") }
        if ownBand == .ghz2 && networks.contains(where: { $0.band == .ghz5 }) { out.append("5 GHz networks are visible. If the router offers 5 GHz and you are near it, it is usually faster and less crowded.") }
        return out
    }
}

// MARK: DNS leak and security
public struct AdvisorFinding: Equatable, Identifiable, Sendable {
    public enum Severity: String, Sendable { case ok = "OK", info = "Note", attention = "Attention" }
    public let id: String
    public let severity: Severity
    public let title: String
    public let detail: String
    public init(id: String, severity: Severity, title: String, detail: String) { self.id = id; self.severity = severity; self.title = title; self.detail = detail }
}

public enum NetworkAdvisor {
    public static let localDNS = "198.18.0.2"

    public static func isPrivate(_ address: String) -> Bool {
        if address.hasPrefix("10.") || address.hasPrefix("192.168.") || address.hasPrefix("127.") || address.hasPrefix("169.254.") { return true }
        if address.hasPrefix("172."), let second = Int(address.split(separator: ".").dropFirst().first ?? ""), (16...31).contains(second) { return true }
        if address.lowercased().hasPrefix("fe80") || address.lowercased().hasPrefix("fd") || address == "::1" { return true }
        return false
    }

    /// Which resolvers the Mac is using, and what that means given what VayuSetu has switched on. It cannot see inside an encrypted resolver, so it
    /// reports what the system is configured to ask and nothing more.
    public static func dnsFinding(resolvers: [String], vayuDNSOn: Bool, vpnOn: Bool) -> AdvisorFinding {
        guard !resolvers.isEmpty else { return AdvisorFinding(id: "dns", severity: .info, title: "No name servers reported", detail: "The system did not list any name servers. This is normal for a moment after the network changes.") }
        if vayuDNSOn {
            let others = resolvers.filter { $0 != localDNS }
            if others.isEmpty { return AdvisorFinding(id: "dns", severity: .ok, title: "Lookups go through VayuSetu DNS", detail: "The only name server in use is VayuSetu's local one, so lookups are filtered and encrypted.") }
            return AdvisorFinding(id: "dns", severity: .attention, title: "Other name servers are listed too", detail: "VayuSetu DNS is on, but the system also lists \(others.joined(separator: ", ")). A lookup that goes to those is not filtered or encrypted. Turn DNS off and on again, or check for another VPN or DNS tool.")
        }
        let privateOnly = resolvers.allSatisfy(isPrivate)
        if vpnOn { return AdvisorFinding(id: "dns", severity: .info, title: "Name servers: \(resolvers.joined(separator: ", "))", detail: "The VPN is on without VayuSetu DNS, so lookups use what the VPN set. If these are your router's own addresses, lookups may be leaving outside the tunnel.") }
        return AdvisorFinding(id: "dns", severity: .info, title: privateOnly ? "Using your router's name server" : "Using name servers: \(resolvers.joined(separator: ", "))",
                              detail: "VayuSetu's DNS is off, so lookups use the network's own resolver (usually your internet provider's). Turn on Encrypted DNS to encrypt and filter them.")
    }

    public static func securityFindings(wifiSecurity: String?, associated: Bool, proxies: [String], gatewayChanged: Bool, portal: CaptivePortal.Verdict?) -> [AdvisorFinding] {
        var out: [AdvisorFinding] = []
        if associated, let wifiSecurity {
            let weak = wifiSecurity.contains("Open") || wifiSecurity.contains("WEP")
            out.append(AdvisorFinding(id: "wifi", severity: weak ? .attention : .ok, title: weak ? "This Wi-Fi network is not properly protected" : "Wi-Fi security: \(wifiSecurity)",
                                      detail: weak ? "\(wifiSecurity). Anyone nearby can read or tamper with what is not itself encrypted. Use the VPN on this network, and avoid signing in to anything sensitive without it." : "The connection to the router is encrypted."))
        }
        if !proxies.isEmpty { out.append(AdvisorFinding(id: "proxy", severity: .info, title: "A proxy is set: \(proxies.joined(separator: ", "))", detail: "Traffic for those protocols goes through the proxy first. That is normal on a work network, and worth knowing if something is slow or blocked.")) }
        if gatewayChanged { out.append(AdvisorFinding(id: "gateway", severity: .attention, title: "The router's address changed", detail: "It changes when you join another network. If it changed while you stayed on the same one, that is unusual: check that nothing new is pretending to be the router.")) }
        if let portal, portal == .portal { out.append(AdvisorFinding(id: "portal", severity: .attention, title: "A sign-in page is blocking the internet", detail: "This network wants you to sign in or accept terms first. Open any plain web page (http://captive.apple.com) to see it. Until then the VPN cannot connect.")) }
        return out
    }
}
