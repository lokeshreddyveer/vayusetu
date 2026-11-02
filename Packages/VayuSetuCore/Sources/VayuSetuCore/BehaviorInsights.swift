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
