import Foundation

/// The conditions a speed test was measured under. Two results are only compared when these match, so a test over a VPN is never judged against
/// one without, a test against one server never against another, and a result from before this was recorded is shown but not compared.
public struct SpeedContext: Codable, Equatable, Hashable, Sendable {
    /// The hashed identity of the physical network (never its name or address).
    public var networkKey: String?
    public var vpnOn: Bool
    /// "direct", "vpn", "dns" or "both" - which VayuSetu mode was in force.
    public var mode: String
    /// The test's own method, endpoint and protocol, for example "http-download", "speed.cloudflare.com", "https".
    public var method: String
    public var endpoint: String
    public var transport: String
    public var streams: Int
    /// Whether the connection was metered when it ran (nil when unknown).
    public var metered: Bool?
    /// Which VPN profile (hashed, never its name or address) carried the test; nil when no VPN did. A test through another server is a different path.
    public var vpnProfile: String?
    public init(networkKey: String?, vpnOn: Bool, mode: String, method: String, endpoint: String, transport: String, streams: Int, metered: Bool?, vpnProfile: String? = nil) {
        self.networkKey = networkKey; self.vpnOn = vpnOn; self.mode = mode; self.method = method; self.endpoint = endpoint; self.transport = transport; self.streams = streams; self.metered = metered; self.vpnProfile = vpnProfile
    }
    /// Whether results under these two contexts may be compared. Unknown pieces never match.
    public func comparable(to other: SpeedContext) -> Bool {
        guard let a = networkKey, let b = other.networkKey, a == b else { return false }
        if let m = metered, let o = other.metered, m != o { return false }
        return vpnOn == other.vpnOn && vpnProfile == other.vpnProfile && mode == other.mode && method == other.method && endpoint == other.endpoint && transport == other.transport && streams == other.streams
    }
}

public struct SpeedSample: Equatable, Sendable {
    public var context: SpeedContext?
    public var down: Double, up: Double
    public var date: Date
    public init(context: SpeedContext?, down: Double, up: Double, date: Date) { self.context = context; self.down = down; self.up = up; self.date = date }
}

public enum SpeedVerdict: Equatable, Sendable {
    /// No fair comparison exists (the reason says why); the result is still shown.
    case noComparison(String)
    case usual(medianDown: Double)
    case slower(percent: Int, medianDown: Double)
    case faster(percent: Int, medianDown: Double)
}

public enum SpeedComparison {
    public static let minimumHistory = 3
    /// How far from the median counts as different.
    public static let tolerance = 0.25

    public static func compare(_ current: SpeedSample, history: [SpeedSample]) -> SpeedVerdict {
        guard let context = current.context else { return .noComparison("Measured before the conditions were recorded.") }
        let fair = history.filter { $0.date < current.date && $0.down > 0 && ($0.context?.comparable(to: context) ?? false) }
        guard fair.count >= minimumHistory else {
            return .noComparison(fair.isEmpty ? "No earlier test was made under the same conditions (same network, mode, server and method)." : "Only \(fair.count) earlier test\(fair.count == 1 ? "" : "s") under the same conditions; \(minimumHistory) are needed.")
        }
        let sorted = fair.map(\.down).sorted()
        let median = sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        let ratio = current.down / median
        if ratio < 1 - tolerance { return .slower(percent: Int(((1 - ratio) * 100).rounded()), medianDown: median) }
        if ratio > 1 + tolerance { return .faster(percent: Int(((ratio - 1) * 100).rounded()), medianDown: median) }
        return .usual(medianDown: median)
    }
}
