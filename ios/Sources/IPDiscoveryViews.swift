import SwiftUI

struct VSIPDiscoveryScreen: View {
    @ObservedObject var network: NetworkDiagnostics
    @ObservedObject var tunnel: TunnelController
    @StateObject private var asn = ASNController()
    @State private var consent = false
    var body: some View {
        VSCardList {
            VSSection { Text("Public-IP discovery observes the address seen by each test service. It does not verify your VPN provider, routing isolation or leak protection.").font(.footnote).foregroundStyle(.secondary) }
            VSSection("IPv4") { family(network.ipv4Probe, .ipv4) }
            VSSection("IPv6") { family(network.ipv6Probe, .ipv6) }
            if network.ipv4Probe == nil, !network.checkingIP, !network.exitIP.isEmpty { VSSection { Text(network.exitIP).font(.footnote).foregroundStyle(.orange) } }
            VSSection { Button(network.checkingIP ? "Measuring…" : "Measure IPv4 & IPv6") { network.checkIP(status: tunnel.statusText, counterSample: { tunnel.observedCounters() }, policyEvidence: tunnel.configuredPolicySummary) }.buttonStyle(VSActionStyle(primary: true)).disabled(network.checkingIP || tunnel.busy) }
            if !network.counterEvidence.isEmpty { VSSection("Tunnel observations") { Text(network.counterEvidence).font(.footnote).foregroundStyle(.secondary) } }
            VSSection {
                Button(asn.busy ? "Looking up…" : "Look Up IPv4 ASN") { consent = true }.disabled(asn.busy || network.ipv4Probe?.address == nil)
                if !asn.result.isEmpty { Text(asn.result).font(.footnote).textSelection(.enabled) }
            } header: { Text("Network ownership") } footer: { Text("Optional: sends the measured IP to RIPEstat through your current route. Results are cached locally in memory for one hour. Network ownership is separate from VPN exit verification.") }
            VSSection("Method") { Text("ipify first, ident.me fallback. Family-specific hostnames; response address family validated. At most two requests per family, 8-second request and 10-second resource timeouts, 4 KB response limit. Default OS routing and system TLS validation apply. No VPN bypass.").font(.footnote); Text("On NAT64 networks, an IPv4 exit address may be reached using IPv6 transport. No successful IPv6 response is not proof of secure blocking.").font(.footnote).foregroundStyle(.secondary) }
        }.vsList().vsHeader("Public IP Discovery").vsEditor()
        .vsConfirm(isPresented: $consent, title: "Look up who owns this address?", message: "RIPEstat receives the queried public IP and the request’s network address. This lookup follows the current route.", confirm: "Look Up ASN", icon: "magnifyingglass.circle.fill") { if let address = network.ipv4Probe?.address { asn.lookup(address) } }
        .onChange(of: tunnel.status.rawValue) { _, _ in network.invalidateIP(); asn.cancel() }
        .onChange(of: network.routeRevision) { _, _ in asn.cancel() }
    }
    @ViewBuilder func family(_ result: IPProbeResult?, _ family: IPFamily) -> some View {
        VSRow(title: "Public IPv\(family.rawValue)", value: result?.address ?? (network.checkingIP ? "Measuring…" : result?.failure?.kind.rawValue ?? "Not measured"))
        if let result {
            if let failure = result.failure { Text(failure.errorDescription ?? "Inconclusive").font(.footnote).foregroundStyle(.orange); Text(action(failure.kind)).font(.footnote).foregroundStyle(.secondary) }
            ForEach(Array(result.attempts.enumerated()), id: \.offset) { _, attempt in VSRow(title: attempt.provider, subtitle: "\(attempt.endpointURL ?? "Endpoint unavailable")\n\(attempt.date.formatted()) · \(attempt.failure?.errorDescription ?? "Address received")", value: "\(attempt.milliseconds) ms") }
        }
    }
    func action(_ kind: IPFailureKind) -> String { switch kind { case .invalidURL: "The URL request was rejected. Inspect the sanitized validation and system-DNS evidence before attributing this to malformed URL construction."; case .dnsDestination: "System DNS returned only unspecified or loopback destinations for this service. Review the configured provider’s filtering policy if you want to allow it; the app keeps your DNS policy and uses the independent fallback."; case .dns: "Check resolver filtering and provider logs for the test hostnames, then rerun. The app will not use another DNS route to bypass filtering."; case .tls: "Check device date and TLS/network restrictions. Certificate validation remains enabled."; case .connectivity, .timeout: "Confirm the current VPN route has internet connectivity. Rerun on the same route or test Wi-Fi and cellular separately."; case .http: "The service rejected or redirected the request. The independent fallback is attempted once."; case .unsupported: "The OS path reports no IPv6 support. Confirm the VPN’s IPv6 policy separately."; case .family, .malformed: "The service returned an unexpected response. Inspect the independent fallback result."; case .cancelled: "Run again after the network or tunnel state stabilizes."; case .other: "Inspect the sanitized error domain and code for both endpoints." } }
}
