import SwiftUI
import WebKit
import NetworkExtension

struct VSVerificationScreen: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    @ObservedObject var network: NetworkDiagnostics
    @StateObject private var verification = ConnectionVerification()
    @State private var expected4 = ""
    @State private var expected6 = ""
    @State private var expectationsLoaded = false
    var connected: Bool { tunnel.status == .connected }
    var key: String { "expected-exit-" + (store.selected?.uuidString ?? "none") }
    var provider: String {
        let host = URL(string: store.endpoint)?.host?.lowercased() ?? ""
        if host == "controld.com" || host.hasSuffix(".controld.com") { return "Control D" }
        if host == "nextdns.io" || host.hasSuffix(".nextdns.io") { return "NextDNS" }
        return "Custom provider"
    }
    var body: some View {
        AnyView(VSCardList {
            VSSection {
                TextField("Expected IPv4 (optional)", text: $expected4).vsInput()
                TextField("Expected IPv6 (optional)", text: $expected6).vsInput()
                if invalidExpected { Text("Use valid IP addresses, separated by commas for multiple exits.").font(.footnote).foregroundStyle(.red) }
            } header: { Text("Expected VPN exit") } footer: { Text("Enter the public exit addresses from your VPN provider. A WireGuard endpoint is not necessarily the exit IP. Saved for the selected profile.") }
            VSSection("Public connectivity") {
                result("Public IPv4", verification.sample?.ipv4 ?? verification.sample?.ipv4Result.failure?.kind.rawValue ?? "Not tested", "globe", "An IPv4 public-address HTTPS request to ipify or ident.me using this app’s current route. Failure is inconclusive, not proof of blocking.")
                result("Public IPv6", verification.sample?.ipv6 ?? verification.sample?.ipv6Result.failure?.kind.rawValue ?? "Not tested", "globe", "An IPv6 public-address HTTPS request to ipify or ident.me. A failed request may reflect lack of IPv6, filtering, DNS failure or service failure.")
                result("IPv4 exit", comparison(4), "arrow.up.right", "Compares the measured address with your expected VPN exit. A match covers this sampled request only.")
                result("IPv6 exit", comparison(6), "arrow.up.right", "Compares the measured IPv6 address with your expected VPN exit. Reachable IPv6 while the tunnel reports blocking is flagged for investigation.")
            }
            VSSection("DNS evidence") {
                VSNavLink { VSDNSProviderChecksScreen(store: store, tunnel: tunnel, network: network) } label: { VSRow(title: "DNS Provider & Website Checks", subtitle: "Official providers · BrowserLeaks · DNSLeakTest", icon: "globe") }
                result("Provider identity", identity, "network", "Uses system DNS to resolve Control D’s published verification name. Matching answers support Control D identity for that sampled path, not your account/profile or every app. OS caching can affect the result. Other providers need an independent verification adapter.")
                result("Unexpected resolver", unexpected, "exclamationmark.magnifyingglass", "A provider disagreement is an investigation signal. Missing Control D evidence alone cannot distinguish a different resolver from DNS or verification-service failure.")
                result("Routing mode", store.mode.title + " · path unverified", "arrow.triangle.branch", "The configured policy sends DNS through the VPN. Proving the DNS request’s actual path requires provider-side source-IP evidence or packet observation. This identity check cannot prove routing order.")
            }
            VSSection("Security & Routing") {
                result("IPv4 leak check", leak(4), "shield.lefthalf.filled", "Flags a measured unexpected exit or a public address unchanged from your explicitly captured disconnected baseline. This is a possible leak, not a device-wide packet-path test.")
                result("IPv6 leak check", leak(6), "shield.lefthalf.filled", "Also flags reachable IPv6 when the connected tunnel reports IPv6 blocking. A failed IPv6 request does not prove leak protection.")
                result("DNS transport", "Inconclusive · independent path proof required", "arrow.triangle.branch", "Accepted DNS settings are configuration evidence. Provider-side source-IP observations or controlled packet observations are needed to verify transport through the VPN.")
                result("Tunnel-failure protection", "Inconclusive · interruption tests pending", "exclamationmark.shield", tunnel.configuredPolicySummary)
                result("Accepted routing policy", tunnel.currentAppliedPolicy.map { ($0.ipv4Default && $0.ipv6Default ? "All IPv4 and IPv6 captured" : "Partial capture") + " · \($0.excludedRouteCount) excluded routes · isolation unverified" } ?? "Not reported · connect and run checks", "point.3.connected.trianglepath.dotted", (tunnel.currentAppliedPolicy?.summary ?? "") + "\n\n" + tunnel.configuredPolicySummary)
            }
            VSSection("Disconnected baseline") {
                Button("Capture Disconnected Baseline") { verification.run(connected: false, captureBaseline: true, ipv6Supported: network.supportsIPv6, network: network.path, routingMode: "VPN disconnected") }.disabled(!canCaptureBaseline)
                Text(baselineHelp).font(.footnote).foregroundStyle(.secondary)
                if let baseline = verification.baseline { Text("Baseline captured \(baseline.date.formatted()). Kept only while this screen remains open.").font(.caption).foregroundStyle(.secondary) }
            }
            VSSection { Button { verification.run(connected: connected, ipv6Supported: network.supportsIPv6, network: network.path, routingMode: store.mode.title) } label: { HStack { if verification.running { ProgressView() }; Text(verification.running ? "Verifying…" : "Verify Connection") } }.buttonStyle(VSActionStyle(primary: true)).disabled(verification.running || invalidExpected || tunnel.busy || tunnel.status == .connecting || tunnel.status == .disconnecting) }
            if let sample = verification.sample { VSSection { Text("Measured \(sample.date.formatted())").font(.caption).foregroundStyle(.secondary); ShareLink(item: verification.sanitizedReport) { Label("Export Sanitized Report", systemImage: "square.and.arrow.up") } } }
            if !verification.message.isEmpty { VSSection { Text(verification.message).font(.footnote).foregroundStyle(.secondary) } }
            VSSection { Link("Control D verification guidance", destination: URL(string: "https://docs.controld.com/docs/check-if-dns-is-working")!) } header: { Text("Leak evidence") } footer: { Text("Checks contact ipify and query verify.controld.com through the system resolver. They do not change VPN or DNS settings.") }
        }.vsList().vsHeader("Verification").vsEditor()
        .onAppear { expected4 = UserDefaults.standard.string(forKey: key + "-4") ?? ""; expected6 = UserDefaults.standard.string(forKey: key + "-6") ?? ""; expectationsLoaded = true }
        .onChange(of: expected4) { _, value in if expectationsLoaded { UserDefaults.standard.set(value, forKey: key + "-4"); verification.invalidate() } }
        .onChange(of: expected6) { _, value in if expectationsLoaded { UserDefaults.standard.set(value, forKey: key + "-6"); verification.invalidate() } }
        .onChange(of: tunnel.status.rawValue) { _, _ in verification.invalidate() }
        .onChange(of: network.routeRevision) { _, _ in verification.invalidate() }
        .onChange(of: store.endpoint) { _, _ in verification.invalidate() }
        .onChange(of: store.selected) { _, _ in expectationsLoaded = false; expected4 = UserDefaults.standard.string(forKey: key + "-4") ?? ""; expected6 = UserDefaults.standard.string(forKey: key + "-6") ?? ""; expectationsLoaded = true; verification.invalidate() })
    }
    var canCaptureBaseline: Bool { !connected && !tunnel.running && !tunnel.busy && !verification.running && network.path != "Network unavailable" && network.path != "Checking network…" }
    var baselineHelp: String {
        if tunnel.running || connected { return "Disconnect the VPN to capture the ordinary network address. A baseline is optional and does not prove leak protection." }
        if tunnel.busy || verification.running { return "Wait for the current operation to finish." }
        if network.path == "Network unavailable" || network.path == "Checking network…" { return "A usable Wi-Fi or cellular connection is required." }
        return "Captures sampled addresses before connecting. Comparisons expire after 15 minutes and are ignored across network-type changes. The app cannot identify every Wi-Fi network change."
    }
    var invalidExpected: Bool { [(expected4, 4), (expected6, 6)].contains { text, family in !text.isEmpty && (text.split(separator: ",", omittingEmptySubsequences: false).count > 16 || text.split(separator: ",", omittingEmptySubsequences: false).contains { ExitComparison.canonical($0.trimmingCharacters(in: .whitespacesAndNewlines), family: family) == nil }) } }
    func comparison(_ family: Int) -> String { guard let sample = verification.sample else { return "Not tested" }; guard sample.connected else { return "VPN disconnected · comparison not applied" }; return ExitComparison.evaluate(observed: family == 4 ? sample.ipv4 : sample.ipv6, expected: family == 4 ? expected4 : expected6, family: family).rawValue }
    var identity: String { guard let sample = verification.sample else { return "Not tested" }; if sample.controlDEvidence == true { return "Control D evidence detected" }; return sample.controlDEvidence == nil ? "Inconclusive" : "Control D evidence not detected" }
    var unexpected: String { guard let sample = verification.sample else { return "Not tested" }; guard sample.connected else { return "VPN disconnected · comparison not applied" }; if sample.controlDEvidence == true && provider != "Control D" { return "Control D detected · differs from selection" }; return provider == "Control D" && sample.controlDEvidence == true ? "No mismatch in sampled path" : "Inconclusive" }
    func leak(_ family: Int) -> String {
        guard let sample = verification.sample else { return "Not tested" }
        guard sample.connected else { return "VPN disconnected" }
        let address = family == 4 ? sample.ipv4 : sample.ipv6
        if family == 6, address != nil, tunnel.stats?.ipv6Blocked == true { return "Possible bypass · IPv6 reachable despite block policy" }
        let verdict = ExitComparison.evaluate(observed: address, expected: family == 4 ? expected4 : expected6, family: family)
        if verdict == .mismatch { return "Possible leak · unexpected exit" }
        let baseline = family == 4 ? verification.comparableBaseline(family: 4) : verification.comparableBaseline(family: 6)
        if let address, let baseline, ExitComparison.canonical(address, family: family) == ExitComparison.canonical(baseline, family: family) { return "Possible leak · matches disconnected baseline" }
        return verdict == .matched ? "Expected exit matched · device-wide leaks unverified" : "Inconclusive · no independent path proof"
    }
    func result(_ title: String, _ value: String, _ icon: String, _ explanation: String) -> some View { VSNavLink { VSCheckDetail(title: title, explanation: explanation, output: value) } label: { VSRow(title: title, subtitle: value, icon: icon) } }
}

struct VSDNSProviderChecksScreen: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    @ObservedObject var network: NetworkDiagnostics
    @StateObject private var checks = DNSProviderVerification()
    var selected: DNSProviderSite? { DNSProviderSite.selected(endpoint: store.endpoint) }
    var body: some View {
        VSCardList {
            VSSection {
                VSRow(title: "Expected provider", value: selected?.rawValue ?? "Custom / unknown")
                Text("Provider selection is inferred from the saved endpoint hostname. It is configuration, not verification.").font(.footnote).foregroundStyle(.secondary)
                Button(checks.running ? "Checking Providers…" : "Check All DNS Providers") { checks.run(endpoint: store.endpoint) }.disabled(checks.running || tunnel.busy || network.path == "Network unavailable")
                if checks.running { ProgressView() }
            } header: { Text("Selected resolver") } footer: { Text("Checks run only when requested, selected provider first. They contact verification services on your current network route; no credentials or personalized resolver URL are sent. Cloudflare's browser-driven check is available below.") }
            if !checks.observations.isEmpty {
                VSSection("Provider evidence") { ForEach(checks.observations) { observation in
                    VSNavLink { VSCheckDetail(title: observation.provider.rawValue, explanation: observation.method + ". " + observation.detail, output: observation.verdict.rawValue + "\n" + observation.date.formatted()) } label: { VSRow(title: observation.provider.rawValue, subtitle: observation.method, value: observation.verdict.rawValue) }
                } }
                VSSection("Comparison") {
                    Text(comparison).font(.footnote)
                    ShareLink(item: checks.sanitizedReport) { Label("Export Sanitized Provider Report", systemImage: "square.and.arrow.up") }
                }
            }
            VSSection {
                ForEach([DNSProviderSite.browserLeaks, .dnsLeakTest]) { site in VSNavLink { VSDNSWebsiteScreen(site: site) } label: { VSRow(title: site.rawValue, subtitle: "Run the actual DNS test inside VayuSetu", icon: "globe") } }
            } header: { Text("Independent DNS websites") } footer: { Text("These services observe resolvers answering randomized names for the embedded browser. Hosting/ASN names may differ from your DNS brand because of upstream forwarding. A different resolver is an investigation signal, not automatic proof of a leak. Websites receive your public connection metadata.") }
            VSSection("Official provider websites") {
                ForEach(DNSProviderSite.providers) { site in VSNavLink { VSDNSWebsiteScreen(site: site) } label: { VSRow(title: site.rawValue, subtitle: site.website.host ?? "", icon: "globe") } }
            }
            if !checks.message.isEmpty { VSSection { Text(checks.message).font(.footnote).foregroundStyle(.secondary) } }
            VSSection("Interpreting disagreements") { Text("Keep the VPN connected and compare the selected-provider check with BrowserLeaks and DNSLeakTest. If an ISP or unexpected resolver appears, check the VPN's DNS configuration and OS DNS-only conflicts. Do not turn protection off or change resolvers merely to get a green result. Browser caching, Private Relay, upstream forwarding and filtering of test hostnames can affect results.").font(.footnote).foregroundStyle(.secondary) }
        }.vsList().vsHeader("DNS Provider Checks")
        .onChange(of: tunnel.status.rawValue) { _, _ in checks.invalidate() }
        .onChange(of: network.routeRevision) { _, _ in checks.invalidate() }
        .onChange(of: store.endpoint) { _, _ in checks.invalidate() }
    }
    var comparison: String {
        let detected = checks.observations.filter { $0.verdict == .detected }.map(\.provider)
        if detected.count > 1 { return "Multiple providers reported evidence. Upstream forwarding, cached answers or mixed resolver paths may explain this; compare independent website results." }
        if let selected, detected.contains(selected) { return "Selected-provider evidence detected for the sampled path. Device-wide leaks and DNS routing order remain unverified." }
        if let selected, let other = detected.first { return "\(other.rawValue) evidence differs from selected \(selected.rawValue). Investigate configuration and compare independent tests." }
        return "The selected provider has not been confirmed. An unavailable or negative provider check does not establish which resolver replaced it."
    }
}
struct VSDNSWebsiteScreen: View {
    let site: DNSProviderSite
    @State private var reload = UUID()
    @State private var status = "Loading official test…"
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(site.website.host ?? "").font(.caption.weight(.semibold))
                Text("Website results describe this embedded browser's DNS path. They do not prove device-wide protection. No resolver or VPN route is changed.").font(.caption).foregroundStyle(.secondary)
                if !status.isEmpty { Text(status).font(.caption2).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            Divider()
            DNSVerificationWebView(site: site, status: $status).id(reload)
        }.vsHeader(site.rawValue).toolbar { ToolbarItem { Button("Reload", systemImage: "arrow.clockwise") { status = "Loading official test…"; reload = UUID() }.vsTapHaptic() } }
    }
}
private final class DNSWebsiteCoordinator: NSObject, WKNavigationDelegate {
    let site: DNSProviderSite
    var status: Binding<String>
    init(site: DNSProviderSite, status: Binding<String>) { self.site = site; self.status = status }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, url.scheme == "https" || (url.scheme == "about" && navigationAction.targetFrame?.isMainFrame == false), url.user == nil, url.password == nil else { decisionHandler(.cancel); return }
        if navigationAction.targetFrame?.isMainFrame != false {
            let host = url.host?.lowercased() ?? ""
            let allowed: [String]
            switch site {
            case .controlD: allowed = ["controld.com"]
            case .nextDNS: allowed = ["test.nextdns.io"]
            case .adguard: allowed = ["adguard.com", "adguard-dns.io"]
            case .cloudflare: allowed = ["one.one.one.one", "1.1.1.1"]
            case .quad9: allowed = ["on.quad9.net", "yes.quad9.net", "no.quad9.net"]
            case .browserLeaks: allowed = ["browserleaks.com"]
            case .dnsLeakTest: allowed = ["dnsleaktest.com"]
            }
            guard allowed.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { status.wrappedValue = "External navigation blocked. Stay on the verification site."; decisionHandler(.cancel); return }
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { status.wrappedValue = "Read the website's result below. Page loaded is not a verification pass." }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { status.wrappedValue = "Website unavailable · network code \((error as NSError).code). Protection settings were preserved." }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { didFailProvisionalNavigation(webView, navigation: navigation, withError: error) }
    private func didFailProvisionalNavigation(_ webView: WKWebView, navigation: WKNavigation!, withError error: Error) { status.wrappedValue = "Website unavailable · network code \((error as NSError).code). Protection settings were preserved." }
}
private func makeDNSWebView(site: DNSProviderSite, coordinator: DNSWebsiteCoordinator) -> WKWebView {
    let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
    let view = WKWebView(frame: .zero, configuration: configuration); view.navigationDelegate = coordinator
    view.load(URLRequest(url: site.website, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
    return view
}
#if os(iOS)
private struct DNSVerificationWebView: UIViewRepresentable {
    let site: DNSProviderSite; @Binding var status: String
    func makeCoordinator() -> DNSWebsiteCoordinator { DNSWebsiteCoordinator(site: site, status: $status) }
    func makeUIView(context: Context) -> WKWebView { makeDNSWebView(site: site, coordinator: context.coordinator) }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: DNSWebsiteCoordinator) { uiView.stopLoading(); uiView.navigationDelegate = nil }
}
#else
private struct DNSVerificationWebView: NSViewRepresentable {
    let site: DNSProviderSite; @Binding var status: String
    func makeCoordinator() -> DNSWebsiteCoordinator { DNSWebsiteCoordinator(site: site, status: $status) }
    func makeNSView(context: Context) -> WKWebView { makeDNSWebView(site: site, coordinator: context.coordinator) }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
    static func dismantleNSView(_ nsView: WKWebView, coordinator: DNSWebsiteCoordinator) { nsView.stopLoading(); nsView.navigationDelegate = nil }
}
#endif
