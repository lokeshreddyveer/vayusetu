import Foundation

/// The best speeds seen in one mode, in bytes per second, kept as two different kinds of figure that are never mixed.
///
/// - **Test** (`testDown`, `testUp`): the best speed test. This is the only figure that is called the mode's speed (`topDown`, `topUp`), because a test
///   measures the internet connection: its own transfers, over a stated server and method.
/// - **Live** (`liveDown`, `liveUp`): the highest three-second average the network port carried while the app was watching. That counts everything the port
///   carried (other apps, copies on the local network), so it is a peak of activity, not a measurement of the connection. It is shown only as such, labelled,
///   and it never stands in for a speed: with no test yet, a mode has no speed (`isEmpty`), however much was seen on the port.
///
/// The stored layout is unchanged from earlier versions, so saved values load as they were.
public struct SpeedBest: Codable, Equatable, Sendable {
    public var liveDown = 0.0, liveUp = 0.0
    public var testDown = 0.0, testUp = 0.0
    public var latencyMs: Double?
    public var testDate: Date?
    public init() {}
    private enum CodingKeys: String, CodingKey { case liveDown, liveUp, testDown, testUp, latencyMs, testDate }
    /// A record with a missing field reads as zero for it. The plain generated decoder refuses the whole record, and the app's saved bests are one
    /// dictionary, so one damaged record would otherwise cost every mode its saved speed.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        liveDown = try c.decodeIfPresent(Double.self, forKey: .liveDown) ?? 0; liveUp = try c.decodeIfPresent(Double.self, forKey: .liveUp) ?? 0
        testDown = try c.decodeIfPresent(Double.self, forKey: .testDown) ?? 0; testUp = try c.decodeIfPresent(Double.self, forKey: .testUp) ?? 0
        latencyMs = try c.decodeIfPresent(Double.self, forKey: .latencyMs); testDate = try c.decodeIfPresent(Date.self, forKey: .testDate)
    }

    /// The figure shown as this mode's speed: the best speed test.
    public var topDown: Double { testDown }
    public var topUp: Double { testUp }
    /// True until a speed test has been made in this mode.
    public var isEmpty: Bool { testDown == 0 && testUp == 0 }
    /// Whether a live peak has been seen (it is shown apart from the speed, and only when there is one).
    public var hasActivityPeak: Bool { liveDown > 0 || liveUp > 0 }

    /// Notes a three-second average of what the port carried. Raises the live peaks only; the mode's speed is not touched. Returns whether a peak rose.
    @discardableResult
    public mutating func noteLive(down: Double, up: Double) -> Bool {
        var raised = false
        if down > liveDown { liveDown = down; raised = true }
        if up > liveUp { liveUp = up; raised = true }
        return raised
    }

    /// Notes a finished speed test. The best of each direction is kept; the latency and date are those of the latest test.
    public mutating func noteTest(down: Double, up: Double, latencyMs: Double?, date: Date) {
        testDown = max(testDown, down); testUp = max(testUp, up)
        self.latencyMs = latencyMs; testDate = date
    }
}
