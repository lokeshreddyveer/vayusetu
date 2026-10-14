import Foundation

public enum ProtectionSubsystem: String, Codable, CaseIterable, Sendable { case vpn, dns, safari, adblock }
public enum ObservedState: String, Codable, Sendable { case inactive, enabledNotVerified, starting, active, limited, needsAttention, error, unknown }
public enum EvidenceSource: String, Codable, Sendable { case osStatus, extensionAcknowledgement, routeObservation, resolverObservation, userPreference, unavailable }
public struct ProtectionSnapshot: Codable, Equatable, Sendable {
    public let subsystem: ProtectionSubsystem
    public let desiredEnabled: Bool?
    public let observed: ObservedState
    public let provenance: EvidenceSource
    public let observedAt: Date?
    public let stale: Bool
    public let reason: String
    public init(_ subsystem: ProtectionSubsystem, desired: Bool?, state: ObservedState, source: EvidenceSource, at: Date? = nil, stale: Bool = false, reason: String) {
        self.subsystem = subsystem; desiredEnabled = desired; observed = state; provenance = source; observedAt = at; self.stale = stale; self.reason = reason
    }
    public var label: String {
        switch observed {
        case .active: return subsystem == .safari ? "Enabled" : subsystem == .vpn ? "Connected" : "Active"
        case .inactive: return subsystem == .safari ? "Disabled" : subsystem == .vpn ? "Disconnected" : "Inactive"
        case .unknown: return "Unknown"
        case .enabledNotVerified: return "Enabled, not verified"
        case .starting: return subsystem == .vpn ? "Connecting" : "Starting"
        case .limited: return "Limited"
        case .needsAttention: return "Needs attention"
        case .error: return "Error"
        }
    }
}
/// All presentation surfaces use this normalization; preferences never manufacture observations.
public enum PrivacyIntegrityEngine {
    public static func reconcile(_ value: ProtectionSnapshot, now: Date, lifetime: TimeInterval = 60) -> ProtectionSnapshot {
        if value.observed == .active && (value.provenance == .userPreference || value.provenance == .unavailable) {
            return ProtectionSnapshot(value.subsystem, desired: value.desiredEnabled, state: .enabledNotVerified, source: value.provenance, at: value.observedAt, reason: "Configuration intent alone does not establish operation.")
        }
        guard let time = value.observedAt else {
            return ProtectionSnapshot(value.subsystem, desired: value.desiredEnabled, state: value.desiredEnabled == true ? .enabledNotVerified : .unknown, source: .unavailable, reason: value.reason)
        }
        guard now.timeIntervalSince(time) > lifetime || time.timeIntervalSince(now) > 5 else { return value }
        return ProtectionSnapshot(value.subsystem, desired: value.desiredEnabled, state: value.desiredEnabled == true ? .enabledNotVerified : .unknown, source: value.provenance, at: time, stale: true, reason: "Evidence is stale. Refresh the system observation.")
    }
}
public enum SessionClock {
    public static func format(seconds: Int64) -> String {
        let value = max(0, seconds)
        return String(format: "%02lld:%02lld:%02lld:%02lld", value / 86400, value / 3600 % 24, value / 60 % 60, value % 60)
    }
}

/// Implemented runtime abilities, not desired policy or independent verification.
public enum ProtectionRuntime: String, Codable, CaseIterable, Sendable {
    case nativeEncryptedDNS, wireGuard, ikev2, openVPN, localDNSTunnel
    public var capabilities: RuntimeCapabilities {
        switch self {
        case .nativeEncryptedDNS:
            return RuntimeCapabilities(available: true, remoteVPN: false, selectedEncryptedResolver: true, localDNSFiltering: false, systemSelectionRequired: true, limitation: "Native DoH/DoT requires system activation. Filtering belongs to the upstream provider.")
        case .wireGuard:
            return RuntimeCapabilities(available: true, remoteVPN: true, selectedEncryptedResolver: true, localDNSFiltering: true, systemSelectionRequired: false, limitation: "The tunnel applies your selected encrypted resolver. With VayuSetu DNS, VayuSetu’s filter lists also run in front of the tunnel. IPv4 UDP DNS only; apps with their own DNS bypass it. Verify on the DNS screen.")
        case .ikev2:
            return RuntimeCapabilities(available: true, remoteVPN: true, selectedEncryptedResolver: false, localDNSFiltering: false, systemSelectionRequired: false, limitation: "IKEv2 uses server-managed DNS. Selected encrypted resolver and local filtering are unavailable in this adapter.")
        case .openVPN:
            return RuntimeCapabilities(available: false, remoteVPN: false, selectedEncryptedResolver: false, localDNSFiltering: false, systemSelectionRequired: false, limitation: "OpenVPN is on hold pending an engine licensing decision.")
        case .localDNSTunnel:
            return RuntimeCapabilities(available: true, remoteVPN: false, selectedEncryptedResolver: true, localDNSFiltering: true, systemSelectionRequired: false, limitation: "A local tunnel answers DNS on this device with your selected DoH/DoT resolver; no VPN server is used and only DNS enters the tunnel. With VayuSetu DNS the filter lists apply. IPv4 UDP DNS only; apps with their own DNS bypass it. iOS asks once for VPN permission.")
        }
    }
}
public struct RuntimeCapabilities: Equatable, Sendable {
    public let available: Bool
    public let remoteVPN: Bool
    public let selectedEncryptedResolver: Bool
    public let localDNSFiltering: Bool
    public let systemSelectionRequired: Bool
    public let limitation: String
    /// Refuses unsupported requests instead of silently substituting another mode.
    public func rejection(remoteVPN requestedVPN: Bool = false, encryptedResolver: Bool = false, localFiltering: Bool = false) -> String? {
        guard available else { return limitation }
        if requestedVPN && !remoteVPN || encryptedResolver && !selectedEncryptedResolver || localFiltering && !localDNSFiltering { return limitation }
        return nil
    }
}
