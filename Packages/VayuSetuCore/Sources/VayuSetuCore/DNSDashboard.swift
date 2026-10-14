import Foundation

// The DNS screen shows this model and nothing else: every word and colour is decided here from observed facts,
// so the view cannot claim more than the evidence supports and the rules are testable without a device.

public enum DNSLevel: String, Sendable { case off, active, pending, limited, failed }
public enum DNSTone: String, Sendable { case good, caution, bad, neutral }
public enum DNSTransportKind: String, Sendable {
    case doh, dot
    public var short: String { self == .dot ? "DoT" : "DoH" }
    public var long: String { self == .dot ? "DNS-over-TLS" : "DNS-over-HTTPS" }
}

public struct DNSDashboardInput: Sendable {
    public var level: DNSLevel
    /// A start, handoff or verification is in progress.
    public var connecting: Bool
    public var onIKEv2: Bool
    public var vpnRunning: Bool
    public var hasResolver: Bool
    public var resolverName: String
    public var transport: DNSTransportKind
    /// VayuSetu DNS is selected, so VayuSetu's own filter lists apply on this device.
    public var localListsSelected: Bool
    /// Rules loaded in the running runtime; nil when no runtime reports a count.
    public var loadedRules: Int?
    /// The coordinator's own explanation for limited or failed states.
    public var reason: String
    /// Detail of a failed end-to-end check, if the latest one failed.
    public var failedCheckDetail: String?
    public init(level: DNSLevel, connecting: Bool = false, onIKEv2: Bool = false, vpnRunning: Bool = false, hasResolver: Bool = true, resolverName: String = "", transport: DNSTransportKind = .doh,
                localListsSelected: Bool = false, loadedRules: Int? = nil, reason: String = "", failedCheckDetail: String? = nil) {
        self.level = level; self.connecting = connecting; self.onIKEv2 = onIKEv2; self.vpnRunning = vpnRunning; self.hasResolver = hasResolver; self.resolverName = resolverName
        self.transport = transport; self.localListsSelected = localListsSelected; self.loadedRules = loadedRules; self.reason = reason; self.failedCheckDetail = failedCheckDetail
    }
}

public struct DNSStatusPanel: Equatable, Sendable {
    public let title: String
    public let line: String
    public let detail: String?
    public let tone: DNSTone
    public let showsProgress: Bool
}
public struct DNSCapabilityTile: Equatable, Identifiable, Sendable {
    public let id: String
    public let icon: String
    public let title: String
    public let value: String
    public let tone: DNSTone
}
public struct DNSDashboardModel: Equatable, Sendable {
    public let status: DNSStatusPanel
    public let tiles: [DNSCapabilityTile]

    public static func make(_ input: DNSDashboardInput) -> DNSDashboardModel {
        DNSDashboardModel(status: status(input), tiles: tiles(input))
    }

    private static func status(_ i: DNSDashboardInput) -> DNSStatusPanel {
        let name = i.resolverName.isEmpty ? "Selected resolver" : i.resolverName
        switch i.level {
        case .off:
            return .init(title: "INACTIVE", line: i.vpnRunning ? "Using the VPN profile’s own DNS" : "Using system or network-provided DNS", detail: nil, tone: .neutral, showsProgress: false)
        case .pending:
            if i.connecting { return .init(title: "CONNECTING", line: "Establishing DNS protection…", detail: nil, tone: .caution, showsProgress: true) }
            return .init(title: "VERIFICATION PENDING", line: "Resolver configured, effective DNS path not confirmed.", detail: i.failedCheckDetail, tone: .caution, showsProgress: false)
        case .limited:
            return .init(title: "LIMITED", line: i.onIKEv2 ? "The active VPN does not support the selected DNS enforcement method." : i.reason, detail: nil, tone: .caution, showsProgress: false)
        case .failed:
            return .init(title: "FAILED", line: "DNS is not working as expected.", detail: i.reason.isEmpty ? nil : i.reason, tone: .bad, showsProgress: false)
        case .active:
            let lists: String
            if i.localListsSelected { lists = i.loadedRules.map { $0 > 0 ? "Filtering: \($0) rules" : "No filter rules loaded" } ?? "Filtering: rule count not reported yet" }
            else { lists = "Filtering: resolver-side only" }
            return .init(title: "ACTIVE", line: "\(name) · Encrypted (\(i.transport.short))", detail: lists + " · apps using system DNS", tone: .good, showsProgress: false)
        }
    }

    private static func tiles(_ i: DNSDashboardInput) -> [DNSCapabilityTile] {
        let encrypted: (String, DNSTone)
        if !i.hasResolver { encrypted = ("No resolver", .neutral) }
        else if i.level == .off { encrypted = ("Not active", .neutral) }
        else if i.level == .active { encrypted = (i.transport.long, .good) }
        else { encrypted = ("Not verified", .caution) }

        let filtering: (String, DNSTone)
        if i.level == .off { filtering = ("Disabled", .neutral) }
        else if i.onIKEv2 { filtering = ("Unsupported", .bad) }
        else if i.localListsSelected {
            // nil means the runtime has not reported yet; zero means it reported and nothing is loaded.
            if let rules = i.loadedRules {
                if rules > 0 { filtering = i.level == .active ? ("Enabled", .good) : ("Verification pending", .caution) }
                else { filtering = ("No rules loaded", .caution) }
            } else { filtering = ("Verification pending", .caution) }
        } else { filtering = ("Resolver-side", .caution) }

        // VayuSetu keeps only aggregate counters; third-party resolver logging is outside its knowledge.
        return [
            .init(id: "encrypted", icon: "checkmark.shield", title: "Encrypted", value: encrypted.0, tone: encrypted.1),
            .init(id: "filtering", icon: "line.3.horizontal.decrease", title: "Filtering", value: filtering.0, tone: filtering.1),
            .init(id: "private", icon: "lock", title: "Private", value: "No local query log", tone: .good)
        ]
    }
}
