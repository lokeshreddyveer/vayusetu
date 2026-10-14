import Foundation

// The Profiles screen draws these models and nothing else. Selection is a preference; "connected" is an observation,
// and the two are never mixed. DNS capability comes from the adapter's real abilities, not from the protocol's name.

public enum ProfileLinkState: String, Sendable { case off, connecting, connected, disconnecting, failed }
public enum ProfileStatus: Equatable, Sendable {
    case connected, connecting, disconnecting, failed
    case selected                   // chosen, not connected
    case lastUsed(Date), neverUsed
}

public struct ProfileRowInput: Sendable {
    public var id: UUID
    public var name: String
    public var kind: VPNKind
    public var selected: Bool
    /// What is observed for THIS profile (off when another profile or nothing is running).
    public var link: ProfileLinkState
    public var lastUsed: Date?
    public init(id: UUID, name: String, kind: VPNKind, selected: Bool, link: ProfileLinkState, lastUsed: Date? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.selected = selected; self.link = link; self.lastUsed = lastUsed
    }
}
public struct ProfileRowModel: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let protocolName: String
    public let icon: String
    /// One concise, factual DNS line derived from what the adapter can really do.
    public let dnsLine: String
    public let status: ProfileStatus
    public let isSelected: Bool
    public let isActive: Bool       // connected or connecting right now
    public let isUsable: Bool
}

public enum ProfilesModel {
    public static func protocolName(_ kind: VPNKind) -> String {
        switch kind { case .wireGuard: return "WireGuard"; case .ikev2: return "IKEv2"; case .openVPN: return "OpenVPN" }
    }
    public static func icon(_ kind: VPNKind) -> String {
        switch kind { case .wireGuard: return "point.3.connected.trianglepath.dotted"; case .ikev2: return "lock.shield"; case .openVPN: return "key.horizontal" }
    }
    public static func dnsLine(_ kind: VPNKind, abilities: (RuntimeKind) -> RuntimeAbilities = RuntimeAbilities.current) -> String {
        let ability = abilities(.vpn(kind))
        guard ability.available else { return "Not available yet" }
        if ability.appliesSelectedResolver && ability.hostsLocalFiltering { return "DNS: your resolver and VayuSetu lists" }
        if ability.appliesSelectedResolver { return "DNS: your resolver" }
        return "DNS: set by the VPN server"
    }
    public static func row(_ input: ProfileRowInput) -> ProfileRowModel {
        let status: ProfileStatus
        switch input.link {
        case .connected: status = .connected
        case .connecting: status = .connecting
        case .disconnecting: status = .disconnecting
        case .failed: status = .failed
        case .off:
            if input.selected { status = .selected }
            else if let date = input.lastUsed { status = .lastUsed(date) }
            else { status = .neverUsed }
        }
        let usable = RuntimeAbilities.current(.vpn(input.kind)).available
        return ProfileRowModel(id: input.id, name: input.name, protocolName: protocolName(input.kind), icon: icon(input.kind), dnsLine: dnsLine(input.kind), status: status,
                               isSelected: input.selected, isActive: input.link == .connected || input.link == .connecting, isUsable: usable)
    }
}

public enum SummaryAction: Equatable, Sendable { case connect, disconnect, cancel, none }
public struct ConnectionSummaryInput: Sendable {
    public var link: ProfileLinkState
    /// The remote VPN that is running or starting, if any.
    public var runningName: String?
    public var runningKind: VPNKind?
    public var selectedName: String?
    public var selectedKind: VPNKind?
    /// VayuSetu's local DNS tunnel is running (not a remote VPN).
    public var localDNSRunning: Bool
    public var busy: Bool
    public init(link: ProfileLinkState, runningName: String? = nil, runningKind: VPNKind? = nil, selectedName: String? = nil, selectedKind: VPNKind? = nil, localDNSRunning: Bool = false, busy: Bool = false) {
        self.link = link; self.runningName = runningName; self.runningKind = runningKind; self.selectedName = selectedName; self.selectedKind = selectedKind; self.localDNSRunning = localDNSRunning; self.busy = busy
    }
}
public struct ConnectionSummaryModel: Equatable, Sendable {
    public let stateLabel: String
    public let tone: DNSTone
    public let headline: String
    public let detail: String
    public let action: SummaryAction
    public let actionTitle: String
    public let showsProgress: Bool

    public static func make(_ i: ConnectionSummaryInput) -> ConnectionSummaryModel {
        func kindName(_ k: VPNKind?) -> String { k.map(ProfilesModel.protocolName) ?? "VPN" }
        switch i.link {
        case .connected:
            return .init(stateLabel: "CONNECTED", tone: .good, headline: i.runningName ?? "VPN", detail: kindName(i.runningKind) + " · remote VPN connection", action: .disconnect, actionTitle: "Disconnect", showsProgress: false)
        case .connecting:
            return .init(stateLabel: "CONNECTING", tone: .caution, headline: i.runningName ?? i.selectedName ?? "VPN", detail: kindName(i.runningKind ?? i.selectedKind) + " · waiting for the tunnel", action: .cancel, actionTitle: "Cancel", showsProgress: true)
        case .disconnecting:
            return .init(stateLabel: "DISCONNECTING", tone: .caution, headline: i.runningName ?? "VPN", detail: "Ending the connection", action: .none, actionTitle: "Please wait", showsProgress: true)
        case .failed:
            return .init(stateLabel: "CONNECTION FAILED", tone: .bad, headline: i.selectedName ?? "VPN", detail: "The last connection attempt did not complete.", action: i.selectedName == nil ? .none : .connect, actionTitle: "Retry", showsProgress: false)
        case .off:
            if i.localDNSRunning {
                // DNS Only is deliberately not presented as a VPN connection.
                return .init(stateLabel: "REMOTE VPN OFF", tone: .neutral, headline: "DNS Only is running", detail: "No remote VPN. DNS runs through VayuSetu’s local tunnel.", action: i.selectedName == nil ? .none : .connect, actionTitle: "Connect VPN", showsProgress: false)
            }
            if let name = i.selectedName {
                return .init(stateLabel: "NOT CONNECTED", tone: .neutral, headline: name, detail: kindName(i.selectedKind) + " · selected, not connected", action: .connect, actionTitle: "Connect", showsProgress: false)
            }
            return .init(stateLabel: "NO VPN PROFILE SELECTED", tone: .neutral, headline: "DNS Only", detail: "Choose a profile to use a VPN, or keep using DNS protection alone.", action: .none, actionTitle: "", showsProgress: false)
        }
    }
}
