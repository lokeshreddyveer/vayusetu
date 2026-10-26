import Foundation

/// What to do when the system reports the tunnel stopped, judged against the start attempt that was under way. Pure, so the rule can be tested
/// without a tunnel: an attempt that ends before the tunnel was established is over, its deadline is over with it, and it is reported as failed
/// unless a reconnect is actually coming. It is never reported as connected.
public enum StartAttempt {
    public enum Outcome: Equatable, Sendable {
        case notAnAttempt          // the tunnel was not starting, or nobody wants a connection: nothing to decide here
        case retrying              // a reconnect is scheduled; the attempt's own deadline is cancelled and the next attempt arms its own
        case failed(reason: String)
    }
    public static func outcome(wasStarting: Bool, connectionWanted: Bool, retryScheduled: Bool, autoReconnect: Bool) -> Outcome {
        guard wasStarting, connectionWanted else { return .notAnAttempt }
        if retryScheduled { return .retrying }
        return .failed(reason: "The tunnel stopped while starting. " + (autoReconnect ? "The network was not available to reconnect." : "Automatic reconnect is off.") + " Connect again to retry.")
    }
}
