import Foundation

// ADR-011. One pure planner decides how the three user controls (VPN profile, DNS protection,
// Safari blocking) combine. It performs no I/O: the app executes the returned steps with its
// platform adapters, so every combination is testable without a device.

public enum VPNKind: String, Codable, CaseIterable, Sendable { case wireGuard, ikev2, openVPN }

public enum OperatingMode: String, Codable, CaseIterable, Sendable {
    case off, dnsOnly, vpnOnly, vpnWithDNS, safariOnly, dnsWithSafari, vpnWithSafari, vpnDNSSafari
    public var title: String {
        switch self {
        case .off: return "Everything Off"
        case .dnsOnly: return "DNS Only"
        case .vpnOnly: return "VPN Profile Only"
        case .vpnWithDNS: return "VPN + DNS"
        case .safariOnly: return "Safari Only"
        case .dnsWithSafari: return "DNS Only + Safari"
        case .vpnWithSafari: return "VPN Profile + Safari"
        case .vpnDNSSafari: return "VPN + DNS + Safari"
        }
    }
    public static func resolve(vpn: Bool, dns: Bool, safari: Bool) -> OperatingMode {
        switch (vpn, dns, safari) {
        case (false, false, false): return .off
        case (false, true, false): return .dnsOnly
        case (true, false, false): return .vpnOnly
        case (true, true, false): return .vpnWithDNS
        case (false, false, true): return .safariOnly
        case (false, true, true): return .dnsWithSafari
        case (true, false, true): return .vpnWithSafari
        case (true, true, true): return .vpnDNSSafari
        }
    }
}

/// What the user asked for. DNS engine and filtering are separate: encrypted DNS with no blocklists is valid.
public struct ProtectionRequest: Codable, Equatable, Sendable {
    public var vpn: VPNKind?            // nil = "No VPN profile"
    public var dns: Bool                // DNS protection (encrypted resolver through the DNS engine)
    public var dnsFiltering: Bool       // local blocklists on top of the DNS engine
    public var safari: Bool
    public var strictDNS: Bool          // never downgrade to plaintext
    public var resolverConfigured: Bool
    public init(vpn: VPNKind? = nil, dns: Bool = false, dnsFiltering: Bool = false, safari: Bool = false, strictDNS: Bool = true, resolverConfigured: Bool = false) {
        self.vpn = vpn; self.dns = dns; self.dnsFiltering = dnsFiltering; self.safari = safari; self.strictDNS = strictDNS; self.resolverConfigured = resolverConfigured
    }
}

/// What each runtime can really do today. Unimplemented abilities are false, never assumed.
public struct RuntimeAbilities: Equatable, Sendable {
    public let available: Bool
    public let appliesSelectedResolver: Bool   // DoH/DoT resolver chosen in VayuSetu is used
    public let usesProfileDNS: Bool            // the imported profile's own client-side DNS settings can be honored (IKEv2: no, the server decides)
    public let hostsLocalFiltering: Bool       // VayuSetu's rule matcher runs inside this runtime
    public let enforcesStrictDNS: Bool         // no plaintext fallback is enforceable
    public let unavailableReason: String?
    /// Why local filtering cannot run here (shown instead of an "active" claim).
    public let filteringUnavailableReason: String?
    public init(available: Bool, appliesSelectedResolver: Bool, usesProfileDNS: Bool, hostsLocalFiltering: Bool, enforcesStrictDNS: Bool, unavailableReason: String? = nil, filteringUnavailableReason: String? = nil) {
        self.available = available; self.appliesSelectedResolver = appliesSelectedResolver; self.usesProfileDNS = usesProfileDNS
        self.hostsLocalFiltering = hostsLocalFiltering; self.enforcesStrictDNS = enforcesStrictDNS; self.unavailableReason = unavailableReason
        self.filteringUnavailableReason = filteringUnavailableReason
    }
    /// Current build. Filtering runs wherever VayuSetu sees the packets: the local tunnel, and WireGuard (a Go filter in
    /// front of the engine). An engine that reads packets through iOS (OpenVPN, when added) can reuse the Swift
    /// interceptor. Apple's system IKEv2 never exposes packets to the app, so it cannot host filtering.
    public static func current(_ owner: RuntimeKind) -> RuntimeAbilities {
        switch owner {
        case .localDNS:
            return .init(available: true, appliesSelectedResolver: true, usesProfileDNS: false, hostsLocalFiltering: true, enforcesStrictDNS: true)
        case .vpn(.wireGuard):
            // DNS on: the selected encrypted resolver (optionally filtered). DNS off: the profile's own DNS, untouched.
            return .init(available: true, appliesSelectedResolver: true, usesProfileDNS: true, hostsLocalFiltering: true, enforcesStrictDNS: true)
        case .vpn(.ikev2):
            return .init(available: true, appliesSelectedResolver: false, usesProfileDNS: false, hostsLocalFiltering: false, enforcesStrictDNS: false,
                         filteringUnavailableReason: "Apple's system IKEv2 runs inside iOS, so VayuSetu never sees its DNS packets and cannot filter them. Use a WireGuard profile, or DNS Only.")
        case .vpn(.openVPN):
            return .init(available: false, appliesSelectedResolver: false, usesProfileDNS: false, hostsLocalFiltering: false, enforcesStrictDNS: false, unavailableReason: "OpenVPN is on hold pending an engine licensing decision.")
        }
    }
}

public enum RuntimeKind: Equatable, Sendable { case localDNS, vpn(VPNKind) }
/// Exactly one VayuSetu tunnel can run on iOS.
public enum TunnelOwner: Equatable, Sendable { case idle, localDNS, vpn(VPNKind)
    public var runtime: RuntimeKind? { switch self { case .idle: return nil; case .localDNS: return .localDNS; case .vpn(let kind): return .vpn(kind) } }
}

public enum DNSPath: String, Codable, Sendable {
    case system                 // network/iOS-provided DNS, nothing of ours in the path
    case localTunnelResolver    // our local tunnel -> selected DoH/DoT resolver
    case vpnProfileDNS          // VPN Only: the imported profile's own DNS settings
    case vpnSelectedResolver    // VPN tunnel carries DNS to the selected encrypted resolver
    case vpnServerDNS           // DNS chosen by the VPN server/OS configuration
}
public enum FilteringState: Equatable, Sendable {
    case off                        // not requested, or no DNS engine
    case enforced                   // local rules applied inside the active DNS runtime
    case unavailable(String)        // requested but the active runtime cannot enforce it
}

public enum PlanIssue: Error, Equatable, Sendable {
    case resolverRequired, runtimeUnavailable(String), filteringNeedsDNS
    public var message: String {
        switch self {
        case .resolverRequired: return "Choose a DNS provider first."
        case .runtimeUnavailable(let reason): return reason
        case .filteringNeedsDNS: return "DNS filtering needs DNS protection turned on."
        }
    }
}

public enum ProtectionStep: Equatable, Sendable {
    case stopTunnel
    case startLocalDNS
    case startVPN(VPNKind)
    case restartForResolverChange
    case enableSafari, disableSafari
}

public struct ProtectionPlan: Equatable, Sendable {
    public let request: ProtectionRequest
    public let mode: OperatingMode
    public let owner: TunnelOwner
    public let dnsPath: DNSPath
    public let filtering: FilteringState
    public let safari: Bool
    /// Honest caveats the UI must show; never hidden behind an "Active" badge.
    public let limitations: [String]
    /// True when the target needs the current tunnel stopped first, leaving a visible protection gap.
    public let protectionGap: Bool
    public let steps: [ProtectionStep]
}

public enum ProtectionPlanner {
    /// `current`: tunnel running now. `safariOn`: Safari blocking currently applied.
    /// `resolverChanged`: the resolver differs from the one the running tunnel was started with.
    public static func plan(_ request: ProtectionRequest, current: TunnelOwner = .idle, safariOn: Bool = false, resolverChanged: Bool = false,
                            abilities: (RuntimeKind) -> RuntimeAbilities = RuntimeAbilities.current) -> Result<ProtectionPlan, PlanIssue> {
        if request.dnsFiltering && !request.dns { return .failure(.filteringNeedsDNS) }
        let owner: TunnelOwner = request.vpn.map { .vpn($0) } ?? (request.dns ? .localDNS : .idle)
        var limitations: [String] = []
        var path: DNSPath = .system
        var filtering: FilteringState = .off
        if let runtime = owner.runtime {
            let ability = abilities(runtime)
            guard ability.available else { return .failure(.runtimeUnavailable(ability.unavailableReason ?? "This protocol is unavailable.")) }
            switch owner {
            case .localDNS:
                guard request.resolverConfigured else { return .failure(.resolverRequired) }
                path = .localTunnelResolver
            case .vpn(let kind):
                if !request.dns {
                    // VPN Only: VayuSetu adds nothing. DNS follows the profile (WireGuard `DNS =`) or the server (IKEv2).
                    path = ability.usesProfileDNS ? .vpnProfileDNS : .vpnServerDNS
                } else if ability.appliesSelectedResolver {
                    guard request.resolverConfigured else { return .failure(.resolverRequired) }
                    path = .vpnSelectedResolver
                } else {
                    path = .vpnServerDNS
                    limitations.append("\(kind == .ikev2 ? "IKEv2" : "This protocol") uses server-managed DNS. Your selected resolver is not applied.")
                }
                if request.dns && request.strictDNS && !ability.enforcesStrictDNS { limitations.append("Strict encrypted DNS cannot be enforced for this VPN type.") }
            case .idle: break
            }
            if request.dnsFiltering {
                if ability.hostsLocalFiltering { filtering = .enforced }
                else { filtering = .unavailable(ability.filteringUnavailableReason ?? "Local filtering does not run in this tunnel. Only provider-side filtering applies.") }
            }
            if request.dnsFiltering, case .unavailable(let reason) = filtering { limitations.append(reason) }
        }
        if request.dnsFiltering && owner == .idle { return .failure(.filteringNeedsDNS) }

        var steps: [ProtectionStep] = []
        var gap = false
        if current != owner {
            if current != .idle { steps.append(.stopTunnel); gap = owner != .idle }
            switch owner {
            case .idle: break
            case .localDNS: steps.append(.startLocalDNS)
            case .vpn(let kind): steps.append(.startVPN(kind))
            }
        } else if owner != .idle && resolverChanged && path != .vpnServerDNS {
            // Server-managed DNS (IKEv2) cannot change; every other runtime needs a restart to change its DNS policy.
            // The spike runtime has no live resolver update; a restart is an honest, brief gap.
            steps.append(.restartForResolverChange); gap = true
        }
        if request.safari != safariOn { steps.append(request.safari ? .enableSafari : .disableSafari) }

        return .success(ProtectionPlan(request: request, mode: .resolve(vpn: request.vpn != nil, dns: request.dns, safari: request.safari), owner: owner, dnsPath: path,
                                       filtering: filtering, safari: request.safari, limitations: limitations, protectionGap: gap, steps: steps))
    }
}
