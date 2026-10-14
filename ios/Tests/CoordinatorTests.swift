import Foundation

@main struct CoordinatorTests {
    static var count = 0
    static func check(_ condition: Bool, _ line: Int = #line) { if !condition { fatalError("CoordinatorTests failed at line \(line)") }; count += 1 }
    static func plan(_ r: ProtectionRequest, current: TunnelOwner = .idle, safariOn: Bool = false, resolverChanged: Bool = false) -> ProtectionPlan? {
        if case .success(let p) = ProtectionPlanner.plan(r, current: current, safariOn: safariOn, resolverChanged: resolverChanged) { return p }
        return nil
    }
    static func issue(_ r: ProtectionRequest) -> PlanIssue? {
        if case .failure(let e) = ProtectionPlanner.plan(r) { return e }
        return nil
    }

    static func main() {
        // The eight primary modes, with a resolver configured
        func req(_ vpn: VPNKind?, _ dns: Bool, _ safari: Bool) -> ProtectionRequest { ProtectionRequest(vpn: vpn, dns: dns, safari: safari, resolverConfigured: true) }
        check(plan(req(nil, false, false))?.mode == .off && plan(req(nil, false, false))?.owner == .idle)
        check(plan(req(nil, true, false))?.mode == .dnsOnly && plan(req(nil, true, false))?.owner == .localDNS)
        check(plan(req(.wireGuard, false, false))?.mode == .vpnOnly)
        check(plan(req(.wireGuard, true, false))?.mode == .vpnWithDNS)
        check(plan(req(nil, false, true))?.mode == .safariOnly && plan(req(nil, false, true))?.owner == .idle)
        check(plan(req(nil, true, true))?.mode == .dnsWithSafari)
        check(plan(req(.wireGuard, false, true))?.mode == .vpnWithSafari)
        check(plan(req(.wireGuard, true, true))?.mode == .vpnDNSSafari)
        check(Set(OperatingMode.allCases.map(\.title)).count == 8)

        // Safari is independent of the tunnel: it never changes the owner or DNS path
        for vpn in [nil, VPNKind.wireGuard] as [VPNKind?] {
            for dns in [false, true] {
                let off = plan(req(vpn, dns, false)), on = plan(req(vpn, dns, true))
                check(off?.owner == on?.owner && off?.dnsPath == on?.dnsPath)
            }
        }

        // DNS Only: local tunnel, selected resolver, no profile required
        let dnsOnly = plan(req(nil, true, false))!
        check(dnsOnly.dnsPath == .localTunnelResolver && dnsOnly.filtering == .off && dnsOnly.limitations.isEmpty)
        check(issue(ProtectionRequest(vpn: nil, dns: true, resolverConfigured: false)) == .resolverRequired)

        // Filtering is a separate dimension: it needs the DNS engine and is reported honestly
        check(issue(ProtectionRequest(vpn: nil, dns: false, dnsFiltering: true, resolverConfigured: true)) == .filteringNeedsDNS)
        // Filtering is enforced wherever VayuSetu sees the packets: the local tunnel and WireGuard
        let filtered = plan(ProtectionRequest(vpn: nil, dns: true, dnsFiltering: true, resolverConfigured: true))!
        check(filtered.filtering == .enforced && filtered.limitations.isEmpty)
        let wgFiltered = plan(ProtectionRequest(vpn: .wireGuard, dns: true, dnsFiltering: true, resolverConfigured: true))!
        check(wgFiltered.filtering == .enforced && wgFiltered.dnsPath == .vpnSelectedResolver)
        // Apple's system IKEv2 never exposes packets to the app: filtering is reported unavailable, with the reason
        let ikeFiltered = plan(ProtectionRequest(vpn: .ikev2, dns: true, dnsFiltering: true, resolverConfigured: true))!
        if case .unavailable(let reason) = ikeFiltered.filtering { check(reason.contains("IKEv2")) } else { check(false) }
        check(ikeFiltered.limitations.contains { $0.contains("IKEv2") })
        let encryptedNoBlocking = plan(ProtectionRequest(vpn: nil, dns: true, dnsFiltering: false, resolverConfigured: true))!
        check(encryptedNoBlocking.filtering == .off)  // encrypted DNS with no blocklists is valid

        // A runtime that does host the matcher reports enforcement
        let hosting: (RuntimeKind) -> RuntimeAbilities = { _ in .init(available: true, appliesSelectedResolver: true, usesProfileDNS: false, hostsLocalFiltering: true, enforcesStrictDNS: true) }
        if case .success(let p) = ProtectionPlanner.plan(ProtectionRequest(vpn: nil, dns: true, dnsFiltering: true, resolverConfigured: true), abilities: hosting) { check(p.filtering == .enforced && p.limitations.isEmpty) } else { check(false) }

        // VPN Only follows the imported profile's own DNS: no resolver is needed and no caveat is invented
        let wgOnly = plan(req(.wireGuard, false, false))!
        check(wgOnly.dnsPath == .vpnProfileDNS && wgOnly.limitations.isEmpty)
        check(plan(ProtectionRequest(vpn: .wireGuard, dns: false, resolverConfigured: false)) != nil)       // no resolver needed for VPN Only
        check(issue(ProtectionRequest(vpn: .wireGuard, dns: true, resolverConfigured: false)) == .resolverRequired)
        // Changing DNS on a running WireGuard tunnel restarts it (policy is applied at start); IKEv2 cannot restart for DNS
        check(plan(ProtectionRequest(vpn: .wireGuard, dns: true, resolverConfigured: true), current: .vpn(.wireGuard), resolverChanged: true)?.steps == [.restartForResolverChange])
        check(plan(req(.wireGuard, true, false))!.limitations.isEmpty)

        // IKEv2: server-managed DNS, selected resolver and strict DNS are not claimed
        let ike = plan(ProtectionRequest(vpn: .ikev2, dns: true, strictDNS: true, resolverConfigured: false))!
        check(ike.dnsPath == .vpnServerDNS && ike.limitations.count == 2)
        check(plan(ProtectionRequest(vpn: .ikev2, dns: false, resolverConfigured: false))?.dnsPath == .vpnServerDNS)

        // OpenVPN is unavailable and says why
        if case .runtimeUnavailable(let reason)? = issue(req(.openVPN, false, false)) { check(reason.contains("licensing")) } else { check(false) }

        // Transitions: one tunnel owner, visible gaps
        check(plan(req(nil, true, false), current: .idle)?.steps == [.startLocalDNS] && plan(req(nil, true, false), current: .idle)?.protectionGap == false)
        check(plan(req(nil, true, false), current: .localDNS)?.steps == [])
        let toVPN = plan(req(.wireGuard, true, false), current: .localDNS)!
        check(toVPN.steps == [.stopTunnel, .startVPN(.wireGuard)] && toVPN.protectionGap)
        let toDNS = plan(req(nil, true, false), current: .vpn(.wireGuard))!
        check(toDNS.steps == [.stopTunnel, .startLocalDNS] && toDNS.protectionGap)
        let toOff = plan(req(nil, false, false), current: .vpn(.wireGuard))!
        check(toOff.steps == [.stopTunnel] && !toOff.protectionGap)
        check(plan(req(.wireGuard, true, false), current: .vpn(.wireGuard))?.steps == [])
        let ikeToWG = plan(req(.wireGuard, true, false), current: .vpn(.ikev2))!
        check(ikeToWG.steps == [.stopTunnel, .startVPN(.wireGuard)])

        // Resolver change restarts the tunnel (no live update yet) except where the server owns DNS
        check(plan(req(nil, true, false), current: .localDNS, resolverChanged: true)?.steps == [.restartForResolverChange])
        check(plan(ProtectionRequest(vpn: .ikev2, dns: false), current: .vpn(.ikev2), resolverChanged: true)?.steps == [])

        // Safari steps are independent and never stop a tunnel
        let safariOn = plan(req(.wireGuard, true, true), current: .vpn(.wireGuard), safariOn: false)!
        check(safariOn.steps == [.enableSafari])
        let safariOff = plan(req(.wireGuard, true, false), current: .vpn(.wireGuard), safariOn: true)!
        check(safariOff.steps == [.disableSafari])
        let swap = plan(req(nil, true, true), current: .vpn(.wireGuard), safariOn: false)!
        check(swap.steps == [.stopTunnel, .startLocalDNS, .enableSafari])

        // Every combination of the three controls produces a plan or a named issue, never a crash
        for vpn in [nil, VPNKind.wireGuard, .ikev2, .openVPN] as [VPNKind?] {
            for dns in [false, true] { for filtering in [false, true] { for safari in [false, true] { for resolver in [false, true] {
                let request = ProtectionRequest(vpn: vpn, dns: dns, dnsFiltering: filtering, safari: safari, resolverConfigured: resolver)
                switch ProtectionPlanner.plan(request) {
                case .success(let p): check(p.mode == .resolve(vpn: vpn != nil, dns: dns, safari: safari))
                case .failure(let e): check(!e.message.isEmpty)
                }
            } } } }
        }
        print("Coordinator planner checks passed: \(count)")
    }
}
