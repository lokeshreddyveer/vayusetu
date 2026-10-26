import Foundation

/// One observed connection, reduced to what the Security Center needs. No addresses beyond the host, no payloads.
public struct DigestFlow: Sendable, Equatable {
    public let app: String          // signing identifier
    public let appName: String
    public let host: String
    public let blocked: Bool
    public let time: Date
    public let team: String?
    public let identity: String?    // "Signer changed", "Invalid signature" or nil
    public let parent: String?
    public init(app: String, appName: String, host: String, blocked: Bool, time: Date, team: String? = nil, identity: String? = nil, parent: String? = nil) {
        self.app = app; self.appName = appName; self.host = host; self.blocked = blocked; self.time = time; self.team = team; self.identity = identity; self.parent = parent
    }
}

public struct DigestApp: Identifiable, Equatable, Sendable {
    public var id: String { app }
    public let app: String
    public let name: String
    public let connections: Int
    public let blocked: Int
    public let destinations: Int
    public let firstSeen: Date
}
public struct DigestDestination: Identifiable, Equatable, Sendable {
    public var id: String { host }
    public let host: String
    public let count: Int
    public let apps: Int
}
public struct DigestFinding: Identifiable, Equatable, Sendable {
    public enum Severity: Int, Comparable, Sendable { case info = 0, attention = 1, high = 2; public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue } }
    public let id: String
    public let severity: Severity
    public let title: String
    public let detail: String
    /// The signing identifier the finding is about, so the screen can offer "Block this app".
    public let app: String?
}

public struct SecurityDigest: Equatable, Sendable {
    public let connections: Int
    public let blocked: Int
    public let apps: [DigestApp]                   // busiest first
    public let blockedDestinations: [DigestDestination]
    public let newApps: [DigestApp]                // first seen within the window, newest first
    public let findings: [DigestFinding]           // most serious first
    public var blockedShare: Double { connections == 0 ? 0 : Double(blocked) / Double(connections) }
}

public enum SecurityDigestBuilder {
    /// Command-line tools and interpreters: not suspicious by themselves, but worth noticing when they reach the internet.
    public static let toolNames: Set<String> = ["curl", "wget", "nc", "netcat", "ssh", "scp", "sftp", "python", "python3", "ruby", "perl", "osascript", "bash", "sh", "zsh", "node", "php"]

    public static func build(_ flows: [DigestFlow], now: Date = Date(), newAppWindow: TimeInterval = 3600, burstWindow: TimeInterval = 300, burstLimit: Int = 100) -> SecurityDigest {
        var perApp: [String: [DigestFlow]] = [:]
        for flow in flows { perApp[flow.app, default: []].append(flow) }
        let apps: [DigestApp] = perApp.map { key, list in
            DigestApp(app: key, name: list.last?.appName ?? key, connections: list.count, blocked: list.filter(\.blocked).count,
                      destinations: Set(list.map(\.host)).count, firstSeen: list.map(\.time).min() ?? now)
        }.sorted { $0.connections != $1.connections ? $0.connections > $1.connections : $0.name < $1.name }

        var perHost: [String: [DigestFlow]] = [:]
        for flow in flows where flow.blocked { perHost[flow.host, default: []].append(flow) }
        let blockedDestinations = perHost.map { DigestDestination(host: $0.key, count: $0.value.count, apps: Set($0.value.map(\.app)).count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.host < $1.host }

        // "New" needs a history that began before the window, or every app would look new on a fresh install.
        let historyStart = flows.map(\.time).min() ?? now
        let canJudgeNew = now.timeIntervalSince(historyStart) > newAppWindow
        let newApps = canJudgeNew ? apps.filter { now.timeIntervalSince($0.firstSeen) <= newAppWindow }.sorted { $0.firstSeen > $1.firstSeen } : []

        var findings: [DigestFinding] = []
        for (app, list) in perApp {
            let name = list.last?.appName ?? app
            if list.contains(where: { $0.identity == "Invalid signature" }) {
                findings.append(.init(id: "invalid-\(app)", severity: .high, title: "\(name) has an invalid signature", detail: "Its code does not match its signature, which can mean it was modified. It made \(list.count) connection\(list.count == 1 ? "" : "s").", app: app))
            } else if list.contains(where: { $0.identity == "Signer changed" }) {
                findings.append(.init(id: "signer-\(app)", severity: .high, title: "\(name) is signed by a different developer than before", detail: "An update from the same developer keeps the signer. A different one is worth checking.", app: app))
            }
        }
        for app in apps where toolNames.contains(app.name.lowercased()) {
            let parents = Set((perApp[app.app] ?? []).compactMap(\.parent))
            findings.append(.init(id: "tool-\(app.app)", severity: .attention, title: "\(app.name) reached the network", detail: "\(app.connections) connection\(app.connections == 1 ? "" : "s") to \(app.destinations) destination\(app.destinations == 1 ? "" : "s")" + (parents.isEmpty ? "." : ", started by \(parents.sorted().joined(separator: ", ")).") , app: app.app))
        }
        let unsigned = apps.filter { app in (perApp[app.app] ?? []).allSatisfy { $0.team == nil } && !toolNames.contains(app.name.lowercased()) && !app.app.hasPrefix("com.apple.") && app.app != "unknown" }
        if !unsigned.isEmpty {
            findings.append(.init(id: "unsigned", severity: .attention, title: "\(unsigned.count) app\(unsigned.count == 1 ? "" : "s") without a verified developer", detail: unsigned.prefix(4).map(\.name).joined(separator: ", ") + (unsigned.count > 4 ? " and more." : "."), app: unsigned.count == 1 ? unsigned[0].app : nil))
        }
        let recent = flows.filter { let age = now.timeIntervalSince($0.time); return age >= 0 && age < burstWindow }
        if recent.count >= burstLimit {
            let busiest = Dictionary(grouping: recent, by: \.appName).max { $0.value.count < $1.value.count }
            findings.append(.init(id: "burst", severity: .attention, title: "A burst of connections", detail: "\(recent.count) connections in the last \(Int(burstWindow / 60)) minutes" + (busiest.map { ", most from \($0.key) (\($0.value.count))." } ?? "."), app: busiest?.value.first?.app))
        }
        if !newApps.isEmpty {
            findings.append(.init(id: "new", severity: .info, title: "\(newApps.count) app\(newApps.count == 1 ? "" : "s") connected for the first time recently", detail: newApps.prefix(4).map(\.name).joined(separator: ", ") + (newApps.count > 4 ? " and more." : "."), app: newApps.count == 1 ? newApps[0].app : nil))
        }
        findings.sort { $0.severity != $1.severity ? $0.severity > $1.severity : $0.title < $1.title }
        return SecurityDigest(connections: flows.count, blocked: flows.filter(\.blocked).count, apps: apps, blockedDestinations: blockedDestinations, newApps: newApps, findings: findings)
    }
}
