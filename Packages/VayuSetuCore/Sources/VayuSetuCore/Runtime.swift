import Foundation

// Evidence never upgrades a configured route into a verified packet path.
public enum Verdict: String, Codable, CaseIterable { case passed, failed, unsupported, inconclusive, unverified }
public enum ConnectionStage: String, Codable {
    case connected, blocked, disconnected, validating, preparing, connecting, tunnelEstablished, verifying, degraded, reconnecting, disconnecting, failed, suspended
    public var title: String {
        switch self {
        case .connected: return "Connected · checks verified"
        case .blocked: return "Policy blocked"
        case .disconnected: return "Disconnected"
        case .validating: return "Validating configuration"
        case .preparing: return "Preparing tunnel"
        case .connecting: return "Connecting"
        case .tunnelEstablished: return "Tunnel established · unverified"
        case .verifying: return "Running connection checks"
        case .degraded: return "Tunnel established · verification incomplete"
        case .reconnecting: return "Reconnecting"
        case .disconnecting: return "Disconnecting"
        case .failed: return "Connection failed"
        case .suspended: return "Network unavailable"
        }
    }
}
public struct Evidence: Codable, Identifiable {
    public let id: UUID
    public let name: String
    public let verdict: Verdict
    public let method: String
    public let timestamp: Date
    public init(_ name: String, _ verdict: Verdict, _ method: String) {
        id = UUID(); self.name = name; self.verdict = verdict; self.method = method; timestamp = Date()
    }
}
public struct SessionRecord: Codable, Identifiable {
    public let id: UUID
    public let started: Date
    public var ended: Date?
    public var received: UInt64
    public var sent: UInt64
    public var outcome: ConnectionStage
    public var profileID: UUID?
    public init(id: UUID, started: Date, ended: Date?, received: UInt64, sent: UInt64, outcome: ConnectionStage, profileID: UUID? = nil) { self.profileID = profileID; self.id = id; self.started = started; self.ended = ended; self.received = received; self.sent = sent; self.outcome = outcome }
}
public struct RetryPolicy {
    public let maximumAttempts: Int
    public init(maximumAttempts: Int) { self.maximumAttempts = max(0, min(10, maximumAttempts)) }
    public func delay(after attempt: Int) -> TimeInterval? {
        guard attempt >= 0, attempt < maximumAttempts else { return nil }
        return min(pow(2, Double(attempt)), 16)
    }
}
public struct HealthPolicy {
    public static func complete(_ evidence: [Evidence]) -> Bool {
        let required = ["Handshake", "IPv4 exit", "IPv6 policy", "DNS transport", "Routing isolation"]
        return required.allSatisfy { name in evidence.contains { $0.name == name && $0.verdict == .passed } }
    }
}
public struct HistoryArchive: Codable { public let version: Int; public let sessions: [SessionRecord]; public init(version: Int, sessions: [SessionRecord]) { self.version = version; self.sessions = sessions } }

/// Presence gate for provisioned macOS builds; release signing separately
/// validates profile capabilities and the code signature. macOS embeds the
/// profile directly in Contents, outside the resource directory.
public enum EmbeddedMacProfile {
    public static func present(in bundleURL: URL) -> Bool {
        let profile = bundleURL.appendingPathComponent("Contents/embedded.provisionprofile")
        return (try? profile.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
}
