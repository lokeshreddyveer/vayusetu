import Foundation

/// One run of the Checks screen, and the rule for when its results may be shown.
///
/// A run is *complete* only when every check it started has finished, not when the button was pressed. Its results belong to the resolver, route and
/// tunnel they were measured under (`configuration`); when any of those change, the run is void and nothing from it may be shown or counted. A token
/// ties each finishing check to the run that started it, so a check from an earlier run that ends late cannot complete or alter a newer one.
public struct CheckRun: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case notRun, running, done }
    public private(set) var phase = Phase.notRun
    public private(set) var token = UUID()
    public private(set) var startedAt: Date?
    public private(set) var finishedAt: Date?
    /// A description of the resolver, route and tunnel in force when the run began.
    public private(set) var configuration = ""
    public init() {}

    /// Starts a run and returns its token. Anything shown from before this must already have been cleared by the caller.
    @discardableResult
    public mutating func begin(configuration: String, now: Date = Date()) -> UUID {
        token = UUID(); phase = .running; startedAt = now; finishedAt = nil; self.configuration = configuration
        return token
    }

    /// Completes the run, but only if it is still the current one and nothing it depends on changed while it ran. Returns whether it completed.
    @discardableResult
    public mutating func finish(token: UUID, configuration now: String, at date: Date = Date()) -> Bool {
        guard phase == .running, token == self.token else { return false }
        guard now == configuration else { invalidate(); return false }
        phase = .done; finishedAt = date
        return true
    }

    /// The configuration changed (or the results were discarded): the run no longer counts, and a late-finishing check cannot revive it.
    public mutating func invalidate() {
        token = UUID(); phase = .notRun; startedAt = nil; finishedAt = nil; configuration = ""
    }

    /// Whether results taken under `current` may still be shown.
    public func isValid(for current: String) -> Bool { phase != .notRun && configuration == current }

    /// An item of evidence counts only if it was produced after this run began.
    public func isFresh(_ date: Date?) -> Bool {
        guard let started = startedAt, let date else { return false }
        return date >= started
    }

    /// What to say about the run.
    public func headline(coverage: String) -> String {
        switch phase {
        case .notRun: return "Not tested"
        case .running: return "Running…"
        case .done: return coverage
        }
    }

    /// The configuration, as one comparable string. Anything that changes what a result means belongs in it.
    public static func signature(_ parts: [String]) -> String { parts.joined(separator: "\u{1F}") }
}
