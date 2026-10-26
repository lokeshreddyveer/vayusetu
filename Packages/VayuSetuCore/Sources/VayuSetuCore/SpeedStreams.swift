import Foundation

/// What one speed-test worker has seen: its own bytes and its own latest HTTP status, behind its own lock.
///
/// Each worker has its own network session and its own `SpeedStreamState`, so a response to one worker is never read by another: one stream being
/// refused cannot end the others, and one stream being answered cannot hide that another was refused. A run owns its streams, so bytes that arrive late from
/// an earlier, cancelled run land in that run's states and are never added to the next one.
public final class SpeedStreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var counted: Int64 = 0
    private var latest = 0
    private var answeredOK = false
    public init() {}

    public func add(bytes: Int64) { guard bytes > 0 else { return }; lock.lock(); counted += bytes; lock.unlock() }
    public func note(status: Int) { lock.lock(); latest = status; if status == 200 { answeredOK = true }; lock.unlock() }
    public var bytes: Int64 { lock.lock(); defer { lock.unlock() }; return counted }
    /// The latest status this worker saw (0 when it has seen none).
    public var status: Int { lock.lock(); defer { lock.unlock() }; return latest }
    /// Whether this worker got a 200 at any point.
    public var everAnswered: Bool { lock.lock(); defer { lock.unlock() }; return answeredOK }
    /// A worker stops only for its own refusal.
    public var shouldStop: Bool { let s = status; return s != 0 && s != 200 }
}

public enum SpeedStreamReport {
    /// The bytes of all the given workers.
    public static func totalBytes(_ streams: [SpeedStreamState]) -> Int64 { streams.reduce(0) { $0 + $1.bytes } }

    /// A plain sentence about how the workers fared, from each worker's own latest status. Used when a run moved no data, so the person is told what
    /// actually happened ("5 of 8 streams were refused with 429") rather than whichever response arrived last.
    public static func describe(source: String, statuses: [Int]) -> String {
        guard !statuses.isEmpty else { return source + " did not answer" }
        var counts: [Int: Int] = [:]
        for s in statuses { counts[s, default: 0] += 1 }
        if counts.count == 1, let only = counts.first {
            if only.key == 0 { return source + " did not answer" }
            return source + " answered \(only.key)" + (statuses.count > 1 ? " on all \(statuses.count) streams" : "")
        }
        // Largest group first; ties by status, lowest first, with "did not answer" always last, so the same run always reads the same way.
        let ordered = counts.sorted { l, r in
            if l.value != r.value { return l.value > r.value }
            if (l.key == 0) != (r.key == 0) { return r.key == 0 }
            return l.key < r.key
        }
        let parts = ordered.map { status, n in
            status == 0 ? "\(n) did not answer" : "\(n) answered \(status)"
        }
        return source + ": " + parts.joined(separator: ", ") + " of \(statuses.count) streams"
    }
}
