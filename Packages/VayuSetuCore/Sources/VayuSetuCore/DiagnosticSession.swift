import Foundation

// A shared record of what happened during a stall. Each part of VayuSetu (the Wi-Fi monitor, the tunnel, the DNS resolver, the speed and scheduled
// checks) adds what it saw to the same incident. Every observation says when it was measured, on which connection, in which VPN session and how
// it was obtained, so evidence from another network or an older tunnel is refused instead of being merged in. A sequence in time is evidence of
// order, not of cause: how an observation relates to the incident is a separate, labelled judgement.

public enum EvidenceLayer: String, Codable, Sendable { case wifi, router, internet, dns, vpn, path, wake, speed, scheduled, domains }
public enum EvidenceProvenance: String, Codable, Sendable { case measured = "Measured", inferred = "Inferred", notAvailable = "Not available" }

public enum EvidenceRelation: String, Codable, Sendable {
    case confirmedObservation = "Confirmed observation"
    case correlated = "Correlated"
    case probableConsequence = "Probable consequence"
    case independentFailure = "Independent failure"
    case inconclusive = "Inconclusive"
}

public struct EvidenceObservation: Codable, Equatable, Sendable {
    public var layer: EvidenceLayer
    /// The interval the observation covers, not the moment it arrived: a DNS result can reach the ledger well after the network event.
    public var start: Date
    public var end: Date
    /// The physical interface (for example "en0") and the hashed identity of the network, when known.
    public var interface: String?
    public var networkKey: String?
    /// Which VPN or tunnel session this belongs to. It changes each time a tunnel starts.
    public var tunnelGeneration: Int
    public var provenance: EvidenceProvenance
    /// Whether this layer was failing during the interval (for events such as a wake or a path change this stays false).
    public var failed: Bool
    public var summary: String
    public init(layer: EvidenceLayer, start: Date, end: Date, interface: String? = nil, networkKey: String? = nil, tunnelGeneration: Int = 0,
                provenance: EvidenceProvenance = .measured, failed: Bool = false, summary: String) {
        self.layer = layer; self.start = start; self.end = end; self.interface = interface; self.networkKey = networkKey
        self.tunnelGeneration = tunnelGeneration; self.provenance = provenance; self.failed = failed; self.summary = summary
    }
}

public struct AttachedEvidence: Codable, Equatable, Sendable {
    public var observation: EvidenceObservation
    public var relation: EvidenceRelation
    /// It arrived while the incident was already recovering.
    public var delayed: Bool
}

public enum IncidentPhase: String, Codable, Sendable { case open, recovering, closed }
public enum IncidentCloseReason: String, Codable, Sendable { case recovered, networkChanged, splitForLength }

public struct DiagnosticIncident: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// The same for every continuation of one long incident, so the timeline and the report can show one outage without merging unrelated ones.
    public var parentID: UUID
    public var sequence: Int
    public var openedAt: Date
    public var recoveredAt: Date?
    public var closedAt: Date?
    public var closeReason: IncidentCloseReason?
    public var phase: IncidentPhase
    public var networkKey: String?
    public var interface: String?
    /// Every tunnel session seen during the incident. A VPN reconnecting adds a session; it does not end a physical-network incident.
    public var tunnelGenerations: [Int]
    public var evidence: [AttachedEvidence]
    public static let maximumEvidence = 200
}

public enum AttachResult: Equatable, Sendable {
    case attached(incident: UUID, relation: EvidenceRelation, delayed: Bool)
    case rejected(RejectReason)
    public enum RejectReason: String, Sendable { case noIncident, otherNetwork, otherInterface, olderTunnelSession, outsideWindow, closed }
}

public struct LedgerConfig: Codable, Equatable, Sendable {
    /// An incident this long is split into continuations (same parent) so one outage cannot absorb everything that follows.
    public var maximumDuration: TimeInterval = 1800
    /// How long after recovery evidence may still arrive and be attached.
    public var lateEvidenceWindow: TimeInterval = 60
    /// Evidence that ended up to this long before the incident opened may belong to it (the failure began before the detector noticed).
    public var preRoll: TimeInterval = 30
    public init() {}
}

public struct IncidentLedger: Codable, Equatable, Sendable {
    public private(set) var incidents: [DiagnosticIncident] = []
    public var config = LedgerConfig()
    public static let maximumIncidents = 100
    public init() {}

    public var open: DiagnosticIncident? { incidents.last { $0.phase != .closed } }
    private func index(of id: UUID) -> Int? { incidents.firstIndex { $0.id == id } }

    private func sameContext(_ i: DiagnosticIncident, networkKey: String?, interface: String?) -> Bool {
        if let a = i.networkKey, let b = networkKey, a != b { return false }
        if let a = i.interface, let b = interface, a != b { return false }
        return true
    }

    /// Opens an incident, or returns the one already open on this connection. An incident open on another connection is closed first.
    @discardableResult
    public mutating func open(at now: Date, networkKey: String?, interface: String?, tunnelGeneration: Int) -> UUID {
        if let current = open, let i = index(of: current.id) {
            if sameContext(current, networkKey: networkKey, interface: interface) {
                if incidents[i].phase == .recovering { incidents[i].phase = .open; incidents[i].recoveredAt = nil }   // it flapped: the same incident, not a new one
                if !incidents[i].tunnelGenerations.contains(tunnelGeneration) { incidents[i].tunnelGenerations.append(tunnelGeneration) }
                return current.id
            }
            close(i, at: now, reason: .networkChanged)
        }
        let id = UUID()
        incidents.append(DiagnosticIncident(id: id, parentID: id, sequence: 0, openedAt: now, recoveredAt: nil, closedAt: nil, closeReason: nil, phase: .open,
                                            networkKey: networkKey, interface: interface, tunnelGenerations: [tunnelGeneration], evidence: []))
        trim()
        return id
    }

    private mutating func close(_ i: Int, at now: Date, reason: IncidentCloseReason) {
        incidents[i].phase = .closed; incidents[i].closedAt = now; incidents[i].closeReason = reason
        if incidents[i].recoveredAt == nil, reason == .recovered { incidents[i].recoveredAt = now }
    }
    private mutating func trim() { if incidents.count > Self.maximumIncidents { incidents.removeFirst(incidents.count - Self.maximumIncidents) } }

    /// The connection came back. The incident stays open for the late-evidence window, then closes.
    public mutating func recover(at now: Date) {
        guard let current = open, let i = index(of: current.id), incidents[i].phase == .open else { return }
        incidents[i].phase = .recovering; incidents[i].recoveredAt = now
    }

    /// A VPN or tunnel session started or ended. It adds a session to an open incident; it never ends it.
    public mutating func tunnelTransition(generation: Int, at now: Date) {
        guard let current = open, let i = index(of: current.id), !incidents[i].tunnelGenerations.contains(generation) else { return }
        incidents[i].tunnelGenerations.append(generation)
    }

    /// Closes what has recovered and splits what has run too long. Returns the ids that changed.
    @discardableResult
    public mutating func advance(now: Date) -> [UUID] {
        var changed: [UUID] = []
        guard let current = open, let i = index(of: current.id) else { return changed }
        if incidents[i].phase == .recovering, let recovered = incidents[i].recoveredAt, now >= recovered.addingTimeInterval(config.lateEvidenceWindow) {
            close(i, at: now, reason: .recovered); changed.append(current.id)
        } else if incidents[i].phase == .open, now.timeIntervalSince(incidents[i].openedAt) > config.maximumDuration {
            changed.append(current.id)
            if let next = continueIncident(at: now) { changed.append(next) }
        }
        return changed
    }

    /// Ends the open incident because it has run long and starts its continuation: same parent, next sequence number, same connection.
    @discardableResult
    public mutating func continueIncident(at now: Date) -> UUID? {
        guard let current = open, let i = index(of: current.id), incidents[i].phase == .open else { return nil }
        let old = incidents[i]
        close(i, at: now, reason: .splitForLength)
        let id = UUID()
        incidents.append(DiagnosticIncident(id: id, parentID: old.parentID, sequence: old.sequence + 1, openedAt: now, recoveredAt: nil, closedAt: nil, closeReason: nil, phase: .open,
                                            networkKey: old.networkKey, interface: old.interface, tunnelGenerations: Array(old.tunnelGenerations.suffix(1)), evidence: []))
        trim()
        return id
    }

    /// Adds an observation to the open incident if it belongs there. Refusals say why, so nothing is merged silently.
    @discardableResult
    public mutating func attach(_ obs: EvidenceObservation, now: Date) -> AttachResult {
        guard let current = open, let i = index(of: current.id) else { return .rejected(incidents.isEmpty ? .noIncident : .closed) }
        let inc = incidents[i]
        if let a = inc.networkKey, let b = obs.networkKey, a != b { return .rejected(.otherNetwork) }
        if let a = inc.interface, let b = obs.interface, a != b { return .rejected(.otherInterface) }
        // A DNS or VPN observation from a tunnel session older than the incident's first one cannot be about it.
        if obs.layer == .dns || obs.layer == .vpn, let oldest = inc.tunnelGenerations.min(), obs.tunnelGeneration < oldest { return .rejected(.olderTunnelSession) }
        let earliest = inc.openedAt.addingTimeInterval(-config.preRoll)
        let latest = (inc.recoveredAt ?? now).addingTimeInterval(inc.phase == .recovering ? config.lateEvidenceWindow : 0)
        guard obs.end >= earliest, obs.start <= latest else { return .rejected(.outsideWindow) }
        let relation = EvidenceCorrelator.relation(of: obs, in: inc)
        let delayed = inc.phase == .recovering
        incidents[i].evidence.append(AttachedEvidence(observation: obs, relation: relation, delayed: delayed))
        if incidents[i].evidence.count > DiagnosticIncident.maximumEvidence { incidents[i].evidence.removeFirst(incidents[i].evidence.count - DiagnosticIncident.maximumEvidence) }
        if !incidents[i].tunnelGenerations.contains(obs.tunnelGeneration), obs.layer == .vpn || obs.layer == .dns { incidents[i].tunnelGenerations.append(obs.tunnelGeneration) }
        return .attached(incident: inc.id, relation: relation, delayed: delayed)
    }

    /// All records belonging to one (possibly continued) outage, oldest first.
    public func chain(parent: UUID) -> [DiagnosticIncident] { incidents.filter { $0.parentID == parent }.sorted { $0.sequence < $1.sequence } }
}

/// Decides how an observation relates to an incident, from the evidence already attached. Order in time alone is "correlated"; a cause is only
/// proposed when a measurement of a lower layer supports it.
public enum EvidenceCorrelator {
    private static func overlaps(_ a: EvidenceObservation, _ b: EvidenceObservation, slack: TimeInterval = 5) -> Bool {
        a.start <= b.end.addingTimeInterval(slack) && b.start <= a.end.addingTimeInterval(slack)
    }

    public static func relation(of obs: EvidenceObservation, in incident: DiagnosticIncident) -> EvidenceRelation {
        guard obs.provenance != .notAvailable else { return .inconclusive }
        let others = incident.evidence.map(\.observation).filter { $0.provenance == .measured && overlaps($0, obs) }
        func has(_ layer: EvidenceLayer, failed: Bool) -> Bool { others.contains { $0.layer == layer && $0.failed == failed } }
        let nearOnset = abs(obs.start.timeIntervalSince(incident.openedAt)) <= 15 || (obs.start <= incident.openedAt && obs.end >= incident.openedAt)
        switch obs.layer {
        case .wifi, .router, .internet:
            return obs.provenance == .measured ? .confirmedObservation : .inconclusive
        case .dns:
            guard obs.failed else { return obs.provenance == .measured ? .confirmedObservation : .inconclusive }
            // DNS cannot work without a path. A failure while a lower layer was measured failing is consistent with that; a failure while the
            // internet was measured reachable is the resolver's own problem; with no lower-layer measurement there is nothing to say.
            if has(.internet, failed: true) || has(.router, failed: true) { return .probableConsequence }
            if has(.internet, failed: false) && has(.router, failed: false) { return .independentFailure }
            return others.isEmpty ? .inconclusive : .correlated
        case .vpn:
            if obs.failed {
                if has(.internet, failed: true) || has(.router, failed: true) { return .probableConsequence }
                if has(.internet, failed: false) { return .independentFailure }
                return .inconclusive
            }
            return nearOnset ? .correlated : .inconclusive
        case .path, .wake:
            return nearOnset ? .correlated : .inconclusive
        case .speed, .scheduled, .domains:
            return overlaps(obs, EvidenceObservation(layer: .wifi, start: incident.openedAt, end: incident.recoveredAt ?? incident.closedAt ?? Date.distantFuture, summary: ""), slack: 30) ? .correlated : .inconclusive
        }
    }
}
