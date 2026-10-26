import Foundation

/// Wi-Fi Intelligence, the pure part: what a reading means, how healthy a connection is, and what the likely cause of a stall was.
/// Nothing here touches the network. The app measures; this file only interprets, and it says "unknown" before it guesses.

public enum WiFiBand: String, Sendable, Equatable {
    case ghz2 = "2.4 GHz", ghz5 = "5 GHz", ghz6 = "6 GHz", unknown = "Unknown"
    /// The band a channel number sits in, given the band macOS reported when it knows it. Channel numbers overlap between bands (channel 1 exists
    /// in both 2.4 and 6 GHz), so a reported band always wins; the number is only a fallback.
    public static func from(channel: Int, reported: WiFiBand? = nil) -> WiFiBand {
        if let reported, reported != .unknown { return reported }
        switch channel {
        case 1...14: return .ghz2
        case 32...177: return .ghz5
        default: return .unknown
        }
    }
}

/// One reading of the Wi-Fi radio. Every field is optional because macOS hides some of them (the name needs Location permission, the rate is
/// missing when not associated), and "not available" must never be shown as zero.
public struct WiFiReading: Equatable, Sendable {
    public var date: Date
    public var associated: Bool
    public var ssid: String?
    public var bssid: String?
    public var rssi: Int?            // dBm, negative; nil when not associated
    public var noise: Int?           // dBm
    public var channel: Int?
    public var band: WiFiBand
    public var widthMHz: Int?
    public var linkRateMbps: Double?
    public var phyMode: String?
    public var security: String?
    public init(date: Date, associated: Bool, ssid: String? = nil, bssid: String? = nil, rssi: Int? = nil, noise: Int? = nil, channel: Int? = nil,
                band: WiFiBand = .unknown, widthMHz: Int? = nil, linkRateMbps: Double? = nil, phyMode: String? = nil, security: String? = nil) {
        self.date = date; self.associated = associated; self.ssid = ssid; self.bssid = bssid; self.rssi = rssi; self.noise = noise; self.channel = channel
        self.band = band; self.widthMHz = widthMHz; self.linkRateMbps = linkRateMbps; self.phyMode = phyMode; self.security = security
    }
    /// Signal minus noise, in dB.
    public var snr: Int? { if let rssi, let noise, rssi < 0, noise < 0 { return rssi - noise } else { return nil } }
}

public enum SignalQuality: String, Sendable {
    case excellent = "Excellent", good = "Good", fair = "Fair", weak = "Weak", unusable = "Very weak", unknown = "Unknown"
    /// From RSSI alone, using the usual thresholds. SNR is shown separately because noise changes what a given signal is worth.
    public static func from(rssi: Int?) -> SignalQuality {
        guard let rssi, rssi < 0 else { return .unknown }
        switch rssi {
        case (-55)...: return .excellent
        case (-67)...: return .good
        case (-75)...: return .fair
        case (-85)...: return .weak
        default: return .unusable
        }
    }
}

/// One round of probes, as the app measured it. nil means that probe was not run or not possible, which is different from failing.
public struct ProbeRound: Equatable, Sendable {
    public var date: Date
    public var gatewayMs: Double?      // nil with gatewayAnswered false means no reply
    public var gatewayAnswered: Bool?
    public var internetMs: Double?
    public var internetAnswered: Bool?
    public var dnsMs: Double?
    public var dnsAnswered: Bool?
    public init(date: Date, gatewayMs: Double? = nil, gatewayAnswered: Bool? = nil, internetMs: Double? = nil, internetAnswered: Bool? = nil, dnsMs: Double? = nil, dnsAnswered: Bool? = nil) {
        self.date = date; self.gatewayMs = gatewayMs; self.gatewayAnswered = gatewayAnswered; self.internetMs = internetMs
        self.internetAnswered = internetAnswered; self.dnsMs = dnsMs; self.dnsAnswered = dnsAnswered
    }
}

public enum ConnectionHealth {
    /// 0...100 from the signal, the router's latency, loss and stability. It is a summary for a glance, and the detail always sits beside it.
    /// Returns nil when there is not enough to say anything (no association, or no probes yet).
    public static func score(reading: WiFiReading?, rounds: [ProbeRound]) -> Int? {
        guard let reading, reading.associated else { return nil }
        let recent = rounds.suffix(30)
        guard recent.count >= 3 else { return nil }
        var score = 100.0
        // Signal: up to 25 points.
        switch SignalQuality.from(rssi: reading.rssi) {
        case .excellent: break
        case .good: score -= 4
        case .fair: score -= 12
        case .weak: score -= 20
        case .unusable: score -= 25
        case .unknown: break
        }
        if let snr = reading.snr, snr < 25 { score -= Double(min(10, 25 - snr)) / 2 }
        // Loss: up to 50 points, on the probe that matters most, the router.
        let gateway = recent.compactMap { $0.gatewayAnswered }
        if !gateway.isEmpty {
            let loss = Double(gateway.filter { !$0 }.count) / Double(gateway.count)
            score -= min(50, loss * 150)
        }
        // Latency and jitter on the router: up to 25 points.
        let latencies = recent.compactMap { $0.gatewayMs }.sorted()
        if let median = latencies.isEmpty ? nil : latencies[latencies.count / 2] {
            if median > 20 { score -= min(12, (median - 20) / 8) }
            if let worst = latencies.last, worst > max(100, median * 6) { score -= min(13, (worst - median) / 60) }
        }
        // Internet reachability: up to 10 points.
        let internet = recent.compactMap { $0.internetAnswered }
        if !internet.isEmpty { score -= min(10, Double(internet.filter { !$0 }.count) / Double(internet.count) * 30) }
        return max(0, min(100, Int(score.rounded())))
    }

    public static func label(_ score: Int?) -> String {
        guard let score else { return "Not enough data yet" }
        switch score {
        case 90...: return "Stable"
        case 75..<90: return "Good"
        case 55..<75: return "Unsteady"
        default: return "Poor"
        }
    }
}

public enum StallCause: String, Sendable, Equatable {
    case wifiDisconnected, weakSignal, roaming, localNetwork, upstream, dnsResolver, afterWake, networkSwitch, vpnChange, unknown
    public var title: String {
        switch self {
        case .wifiDisconnected: "Wi-Fi was disconnected"
        case .weakSignal: "The signal was weak"
        case .roaming: "The Mac switched access points"
        case .localNetwork: "The router or local network stopped answering"
        case .upstream: "The router answered, but the internet did not"
        case .dnsResolver: "Name lookups failed"
        case .afterWake: "The connection was returning after sleep"
        case .networkSwitch: "The Mac switched to another connection"
        case .vpnChange: "The VPN was connecting or disconnecting"
        case .unknown: "No single cause is clear"
        }
    }
}

public enum Confidence: String, Sendable { case low = "Low", medium = "Medium", high = "High" }

public struct Diagnosis: Equatable, Sendable {
    public var cause: StallCause
    public var confidence: Confidence
    /// What was observed, in plain words. A diagnosis with no evidence is never produced.
    public var evidence: [String]
    /// What the user can do about it. Every item is a suggestion; nothing here changes a setting.
    public var advice: [String]
}

/// What was observed around an incident, gathered by the app from the readings and probes before, during and after it.
public struct IncidentEvidence: Equatable, Sendable {
    public var wasAssociatedBefore = true
    public var associatedDuring = true
    public var bssidBefore: String?
    public var bssidDuring: String?
    public var rssiBefore: Int?
    public var rssiDuring: Int?
    public var gatewayFailedDuring: Bool?
    public var gatewayRecovered: Bool?
    public var internetFailedDuring: Bool?
    public var dnsFailedDuring: Bool?
    /// Seconds between the Mac waking and the incident starting, when it woke recently.
    public var secondsSinceWake: Double?
    /// How many probe rounds backed the verdict. Fewer than this and nothing above "low" is claimed.
    public var roundsDuring = 0
    /// The connection type (Wi-Fi, Ethernet, a hotspot) changed within seconds of the stall starting.
    public var pathChangedAround = false
    /// The VPN was switched on or off, or reconnected, within seconds of the stall starting.
    public var vpnChangedAround = false
    public init() {}
}

public enum IncidentClassifier {
    public static let minimumRoundsForConfidence = 3

    /// Follows the decision matrix, in the order of what is most certain. A single failed probe is never a cause on its own: with too few
    /// rounds the result is capped at low confidence, and anything the evidence does not settle is reported as unknown.
    public static func diagnose(_ e: IncidentEvidence) -> Diagnosis {
        let enough = e.roundsDuring >= minimumRoundsForConfidence
        func confidence(_ strong: Bool) -> Confidence { !enough ? .low : (strong ? .high : .medium) }

        if e.wasAssociatedBefore && !e.associatedDuring {
            return Diagnosis(cause: .wifiDisconnected, confidence: .high,
                             evidence: ["The Mac's Wi-Fi lost its connection to the network."],
                             advice: ["Check whether the router restarted or the Wi-Fi was switched off.", "If it repeats, note the time and move closer to the router."])
        }
        if let wake = e.secondsSinceWake, wake < 20 {
            return Diagnosis(cause: .afterWake, confidence: confidence(false),
                             evidence: ["The Mac woke from sleep \(Int(wake)) seconds before this started, and reconnecting after sleep takes a few seconds."],
                             advice: ["This usually clears by itself within a minute. If it happens after every wake, restarting Wi-Fi once is worth trying."])
        }
        if e.vpnChangedAround {
            return Diagnosis(cause: .vpnChange, confidence: confidence(false),
                             evidence: ["The VPN changed state right around when this began. Starting, stopping or reconnecting a VPN replaces the Mac's routes, which pauses traffic for a few seconds."],
                             advice: ["This is expected and clears by itself. If it lasts longer than about ten seconds each time, the VPN server or the network it connects over is slow to answer."])
        }
        if e.pathChangedAround {
            return Diagnosis(cause: .networkSwitch, confidence: confidence(false),
                             evidence: ["The Mac changed which connection it uses (for example Wi-Fi to Ethernet, or onto a hotspot) right around when this began."],
                             advice: ["A short pause while the Mac moves to another connection is normal. If it keeps switching, one of the connections is unstable: check each one on its own."])
        }
        if let before = e.bssidBefore, let during = e.bssidDuring, before != during {
            return Diagnosis(cause: .roaming, confidence: confidence(true),
                             evidence: ["The Mac moved from one access point to another around the time of the stall."],
                             advice: ["If you have several routers or a mesh system, a stall while moving between them is typical. A stronger spot, or a single access point nearer to where you sit, avoids it."])
        }
        let weak = (e.rssiDuring ?? 0) < -78 && e.rssiDuring != nil
        let weakened = (e.rssiBefore != nil && e.rssiDuring != nil) && ((e.rssiDuring ?? 0) <= (e.rssiBefore ?? 0) - 12)
        if e.gatewayFailedDuring == true {
            if weak || weakened {
                return Diagnosis(cause: .weakSignal, confidence: confidence(weak && weakened),
                                 evidence: ["The router stopped answering while the signal was weak (\(e.rssiDuring ?? 0) dBm" + (weakened ? ", down from \(e.rssiBefore ?? 0))." : ").")],
                                 advice: ["Move closer to the router or remove obstacles between you.", "Check the band: 5 GHz is faster but reaches less far than 2.4 GHz."])
            }
            return Diagnosis(cause: .localNetwork, confidence: confidence(e.internetFailedDuring == true),
                             evidence: ["The router did not answer" + (e.internetFailedDuring == true ? ", and neither did the internet." : "."), "The signal itself looked normal, so this points at the router, radio interference or the wireless link rather than distance."],
                             advice: ["Try another channel on the router, or restart it.", "A busy channel or a nearby device (a USB 3 hub, a microwave, a baby monitor) can cause short freezes."])
        }
        if e.gatewayFailedDuring == false, e.internetFailedDuring == true {
            return Diagnosis(cause: .upstream, confidence: confidence(true),
                             evidence: ["The router answered normally, but sites on the internet did not."],
                             advice: ["The problem is past your router: the internet provider, or the router's own connection to it. Restarting the router or modem, or waiting a few minutes, is the usual remedy."])
        }
        if e.gatewayFailedDuring == false, e.internetFailedDuring == false, e.dnsFailedDuring == true {
            return Diagnosis(cause: .dnsResolver, confidence: confidence(true),
                             evidence: ["The router and internet answered, but looking up names did not."],
                             advice: ["Try another DNS resolver in VayuSetu's Encrypted DNS page."])
        }
        return Diagnosis(cause: .unknown, confidence: .low,
                         evidence: ["The probes did not agree on a single place where things failed."],
                         advice: ["Leaving monitoring on helps: with a few more incidents the pattern usually shows."])
    }
}

/// A stall, as the monitor tracks it: Healthy, then Suspected after a first bad sign, Confirmed once it persists, Recovering once the router
/// answers again. The thresholds are hysteresis: it takes more evidence to declare an incident than to suspect one, and a few good rounds to end it.
public struct StallDetector: Equatable, Sendable {
    public enum State: String, Sendable { case healthy, suspected, confirmed, recovering }
    public private(set) var state: State = .healthy
    public private(set) var startedAt: Date?
    public private(set) var badRounds = 0
    public private(set) var goodRounds = 0
    public static let confirmAfter = 3, recoverAfter = 3
    public init() {}

    public struct Outcome: Equatable, Sendable {
        public var opened = false      // a confirmed incident began at `startedAt`
        public var closed = false      // the incident ended
    }

    /// A round is "bad" when the router did not answer, or answered far slower than its norm.
    public static func isBad(_ round: ProbeRound, baselineMs: Double?) -> Bool {
        if round.gatewayAnswered == false { return true }
        if round.gatewayAnswered == true, let ms = round.gatewayMs {
            let normal = max(baselineMs ?? 10, 5)
            return ms > max(300, normal * 25)
        }
        return false
    }

    public mutating func record(_ round: ProbeRound, baselineMs: Double?) -> Outcome {
        var out = Outcome()
        let bad = Self.isBad(round, baselineMs: baselineMs)
        switch state {
        case .healthy:
            if bad { state = .suspected; startedAt = round.date; badRounds = 1; goodRounds = 0 }
        case .suspected:
            if bad { badRounds += 1; goodRounds = 0; if badRounds >= Self.confirmAfter { state = .confirmed; out.opened = true } }
            else { goodRounds += 1; if goodRounds >= 2 { state = .healthy; startedAt = nil; badRounds = 0; goodRounds = 0 } }
        case .confirmed:
            if bad { goodRounds = 0 } else { state = .recovering; goodRounds = 1 }
        case .recovering:
            if bad { state = .confirmed; goodRounds = 0 }
            else { goodRounds += 1; if goodRounds >= Self.recoverAfter { state = .healthy; out.closed = true; badRounds = 0; goodRounds = 0 } }
        }
        return out
    }

    /// Seconds a confirmed incident has lasted, counted to `now`.
    public func duration(at now: Date) -> TimeInterval? { startedAt.map { now.timeIntervalSince($0) } }
}
