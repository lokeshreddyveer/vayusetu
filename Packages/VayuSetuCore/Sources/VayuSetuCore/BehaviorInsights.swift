import Foundation

/// A privacy-preserving summary of one observed connection. The analyzer never
/// needs a URL path, payload, or remote content.
public struct BehaviorConnection: Codable, Hashable, Sendable {
    public let app: String
    public let host: String
    public let team: String?
    public let parent: String?
    public let verdict: String
    public let time: Date
    public let bytes: Int64
    public init(app: String, host: String, team: String? = nil, parent: String? = nil, verdict: String, time: Date = .now, bytes: Int64 = 0) {
        self.app = app; self.host = host; self.team = team; self.parent = parent; self.verdict = verdict; self.time = time; self.bytes = max(0, bytes)
    }
}

public enum BehaviorSeverity: String, Codable, CaseIterable, Sendable { case info, attention, high }
public struct BehaviorInsight: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let severity: BehaviorSeverity
    public init(id: String, title: String, detail: String, severity: BehaviorSeverity) { self.id = id; self.title = title; self.detail = detail; self.severity = severity }
}

public struct BehaviorReport: Codable, Hashable, Sendable {
    public let connections: Int
    public let applications: Int
    public let destinations: Int
    public let blocked: Int
    public let bytes: Int64
    public let insights: [BehaviorInsight]
    public init(connections: Int, applications: Int, destinations: Int, blocked: Int, bytes: Int64, insights: [BehaviorInsight]) {
        self.connections = connections; self.applications = applications; self.destinations = destinations; self.blocked = blocked; self.bytes = bytes; self.insights = insights
    }
}

public enum BehaviorAnalyzer {
    public static func report(_ connections: [BehaviorConnection], now: Date = .now) -> BehaviorReport {
        let apps = Set(connections.map(\.app)); let destinations = Set(connections.map(\.host))
        let blocked = connections.filter { $0.verdict == "block" }.count
        let bytes = connections.reduce(Int64(0)) { $0 + $1.bytes }
        var insights: [BehaviorInsight] = []
        let unknownSigner = Set(connections.filter { $0.team == nil || $0.team?.isEmpty == true }.map(\.app))
        if !unknownSigner.isEmpty { insights.append(.init(id: "unknown-signer", title: "Unsigned or unidentified applications", detail: "\(unknownSigner.count) application(s) have no verified signer identity in the observed flow metadata.", severity: .attention)) }
        let recent = connections.filter {
            let age = now.timeIntervalSince($0.time)
            return age >= 0 && age < 300
        }
        if recent.count >= 100 { insights.append(.init(id: "burst", title: "Connection burst", detail: "\(recent.count) connections were observed in the last five minutes. Review the app and destination groups before allowing broad access.", severity: .attention)) }
        if blocked > 0 { insights.append(.init(id: "blocked", title: "Blocked activity", detail: "\(blocked) connection(s) were blocked by a rule or list.", severity: .info)) }
        if connections.isEmpty { insights.append(.init(id: "empty", title: "No observations yet", detail: "Use the network or diagnostics view to collect local evidence.", severity: .info)) }
        return BehaviorReport(connections: connections.count, applications: apps.count, destinations: destinations.count, blocked: blocked, bytes: bytes, insights: insights)
    }
}
