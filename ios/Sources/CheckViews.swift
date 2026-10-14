import SwiftUI
import VayuSetuCore
import NetworkExtension

struct VSCheckDetail: View {
    let title: String
    let explanation: String
    let output: String
    var body: some View {
        VSCardList {
            VSSection("What this checks") { Text(explanation).font(.body) }
            VSSection("Latest result") { Text(output.isEmpty ? "Not tested" : output).font(.system(.footnote, design: .monospaced)).textSelection(.enabled) }
            VSSection { Button("Copy Result", systemImage: "doc.on.doc") { VSDesign.copy(output.isEmpty ? "Not tested" : output) } }
        }.vsList().vsHeader(title).vsEditor()
    }
}
struct VSChecksScreen: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    @ObservedObject var network: NetworkDiagnostics
    @State private var hasRun = false
    var health: TunnelHealth {
        TunnelHealth.assess(running: tunnel.running, connected: tunnel.status == .connected, kind: tunnel.protocolName, stats: tunnel.stats,
                            statsAge: tunnel.statsAge, uptime: tunnel.uptimeSeconds)
    }
    var working: Bool { store.testing || store.dnsVerifying || network.checkingIP || network.qualityRunning || tunnel.checkingHealth }
    var body: some View {
        AnyView(VSCardList {
            VSSection {
                Button {
                    hasRun = true; store.result = ""
                    if !store.endpoint.isEmpty { store.testDNS() }
                    network.checkIP(status: tunnel.statusText, counterSample: { tunnel.observedCounters() }, policyEvidence: tunnel.configuredPolicySummary)
                    network.runQuality(status: tunnel.statusText)
                    Task { await store.verifyLocalDNS() }
                    if tunnel.status == .connected { tunnel.refreshStats(); tunnel.verifyConnection(resolver: store.endpoint, includeIPProbes: false) }
                } label: { Text(working ? "Running checks…" : "Run Available Checks") }.buttonStyle(VSActionStyle(primary: true)).disabled(working || tunnel.busy)
            } footer: { Text("Filtering requires controlled names and a reference resolver; run it separately. Provider attribution, packet-path proof and failure-isolation tests are unsupported here and are never marked passed.") }
            VSSection("Diagnostic coverage") {
                Text(hasRun ? coverage : "Not tested").font(.headline)
                if hasRun, !failedNames.isEmpty { Text("Failed: " + failedNames).font(.subheadline).foregroundStyle(.orange) }
                Text("Looks at the state of what is running: the tunnel, its handshake or answered DNS queries, a DNS lookup and your public IP. It cannot prove that no other app leaks, so it is not a privacy score.").font(.footnote).foregroundStyle(.secondary)
                if working { ProgressView("Running supported checks…") }
            }
            VSSection("VPN Health") {
                detail("Tunnel", health.summary, "power", "Combines what iOS reports with what the tunnel itself counts: a recent handshake and returning data for WireGuard, answered lookups for DNS-only. It tells you whether the tunnel is doing its job, not that nothing else leaks.", health.lines.joined(separator: "\n"), health.verdict == .healthy ? "checkmark.circle.fill" : health.verdict == .down ? "xmark.circle.fill" : health.verdict == .degraded ? "exclamationmark.triangle.fill" : health.verdict == .off ? "circle" : "questionmark.circle")

                VSNavLink { VSIPDiscoveryScreen(network: network, tunnel: tunnel) } label: {
                    HStack { VSRow(title: "Public IPv4 / IPv6", subtitle: publicIPSummary, icon: "globe"); Image(systemName: publicIPGlyph).foregroundStyle(.secondary).accessibilityLabel(publicIPSummary) }
                }
                detail("Handshake", handshake.summary, "arrow.triangle.2.circlepath", "A WireGuard handshake is the tunnel proving itself to the server; it repeats about every two minutes while data flows. A recent one means the server answered. It does not prove that websites load.", handshake.detail, handshake.glyph)
            }
            VSSection("DNS Health") {
                detail("DNS resolves", dnsSummary, "network", "Asks the selected resolver for the domain in DNS test options, over the route you are on now. An answer shows the resolver works; it does not verify filtering or that other apps use it.", dnsDetail, dnsGlyph)
                VSNavLink { VSDNSTestScreen(store: store) } label: { VSRow(title: "DNS test options", subtitle: "\(store.probeDomain) · \(store.probeRecordType.title)" + (store.expectNXDOMAIN ? " · expect blocked" : ""), icon: "slider.horizontal.3") }
                VSNavLink { VSFilteringScreen(store: store, tunnel: tunnel, network: network) } label: {
                    HStack { VSRow(title: "Ad & tracker protection", subtitle: adSummary.text, icon: "hand.raised"); Image(systemName: adSummary.glyph).foregroundStyle(.secondary).accessibilityLabel(adSummary.text) }
                }
            }
            VSSection("Leak Protection") {
                VSNavLink { VSVerificationScreen(store: store, tunnel: tunnel, network: network) } label: { VSRow(title: "Connection verification", subtitle: "IPv4, IPv6, DNS identity and leaks", icon: "checkmark.shield") }
                detail("Accepted routing policy", policy.summary, "point.3.connected.trianglepath.dotted", "What iOS accepted when the tunnel started: which traffic the tunnel captures, any routes left outside it, and how DNS is set. This is the configuration iOS agreed to, not proof of where each packet goes.", policy.detail, policy.glyph)
                detail("DNS routing / leaks", dnsRouting.summary, "shield.lefthalf.filled", "Looks for signs that device lookups reach the tunnel: answered lookups counted by the tunnel and the DNS settings iOS accepted. Apps that bring their own DNS can bypass any resolver, and no app can prove that nothing leaks.", dnsRouting.detail, dnsRouting.glyph)
                detail("IPv6 policy", ipv6Report.summary, "point.3.connected.trianglepath.dotted", "Whether IPv6 is blocked or carried by the tunnel, compared with what the public IP check actually saw. If blocking is set but an IPv6 address still answers, that is flagged as a possible leak.", evidence("IPv6 policy") + (network.ipv6Probe.map { "\nPublic IPv6 probe: " + ($0.address ?? "no address received") } ?? ""), ipv6Report.glyph)
            }
            VSSection("Network Quality") {
                VSNavLink { VSCardList { VSSection { QualityPanel(network: network, status: tunnel.statusText) } }.vsList().vsHeader("Connection Quality") } label: { VSRow(title: "Connection quality", subtitle: qualitySummary, icon: "waveform.path") }
                VSNavLink { VSTrafficScreen(store: store, tunnel: tunnel) } label: { VSRow(title: "Traffic", subtitle: trafficSummary, icon: "arrow.up.arrow.down") }
            }
        }.vsList().vsHeader("Checks")
        .onAppear { if tunnel.status == .connected { tunnel.refreshStats() } }
        .onChange(of: tunnel.status.rawValue) { _, _ in hasRun = false }
        .onChange(of: network.routeRevision) { _, _ in hasRun = false }
        .onChange(of: store.endpoint) { _, _ in hasRun = false }
        .onChange(of: store.selected) { _, _ in hasRun = false })
    }
    /// Only checks that apply to what is running now: a VPN has a handshake and public IP, DNS Only has answered queries and the DNS check.
    /// Every check that counts toward the summary, by name, so a failure says which one it was.
    var coverageItems: [(name: String, passed: Bool?)] {
        var items: [(String, Bool?)] = []
        switch health.verdict {
        case .healthy: items.append(("Tunnel", true))
        case .down, .degraded: items.append(("Tunnel", false))
        case .limited, .starting: items.append(("Tunnel", nil))
        case .off: break
        }
        if tunnel.localDNSRunning || tunnel.protocolName == "WireGuard", tunnel.running, let check = store.dnsVerification { items.append(("DNS through the tunnel", check.passed)) }
        if !store.result.isEmpty && !store.testing { items.append(("DNS lookup", store.result.hasPrefix("Probe passed"))) }
        if let v4 = network.ipv4Probe { items.append(("Public IPv4", v4.address != nil)) }
        // No IPv6 is not a failure when the network has none or the tunnel blocks it on purpose; only an unexpected answer is flagged.
        if let v6 = network.ipv6Probe {
            let blocked = tunnel.currentAppliedPolicy?.ipv6Restricted ?? tunnel.stats?.ipv6Blocked
            if v6.address != nil { items.append(("IPv6 policy", blocked == true ? false : true)) }
            else if network.supportsIPv6 == true, blocked != true, tunnel.running { items.append(("Public IPv6", nil)) }
        }
        return items
    }
    var coverage: String {
        let results = coverageItems.map(\.passed)
        let passed = results.filter { $0 == true }.count, failed = results.filter { $0 == false }.count, untested = results.filter { $0 == nil }.count
        if results.isEmpty { return "Nothing is running, so there is nothing to check yet." }
        return "\(passed) passed · \(failed) failed" + (untested > 0 ? " · \(untested) waiting" : "")
    }
    var failedNames: String {
        coverageItems.filter { $0.passed == false }.map { item in
            // Say why the DNS lookup failed, using the resolver's own error text.
            guard item.name == "DNS lookup", let reason = store.result.split(separator: "\n").first else { return item.name }
            return item.name + " (" + reason.replacingOccurrences(of: "Probe failed · ", with: "") + ")"
        }.joined(separator: ", ")
    }
    /// What the last public-IP probe actually saw, next to what the tunnel was configured to do.
    var ipv6Summary: String {
        let configured = tunnel.stats.map { $0.ipv6Blocked ? "blocking configured" : "tunnel configured" }
        guard let probe = network.ipv6Probe else { return configured.map { $0.capitalized + " · run checks to observe" } ?? "Not verified" }
        if let address = probe.address { return "IPv6 reachable as \(address)" }
        return "No IPv6 address seen" + (configured.map { " · " + $0 } ?? "")
    }
    // MARK: Public IP
    var publicIPSummary: String {
        if network.checkingIP { return "Measuring…" }
        guard let v4 = network.ipv4Probe, let v6 = network.ipv6Probe else { return "Not measured · run checks" }
        func part(_ name: String, _ r: IPProbeResult) -> String { r.address.map { "\(name) \($0)" } ?? "\(name) none" + (r.failure.map { " (\($0.kind.rawValue))" } ?? "") }
        return part("IPv4", v4) + " · " + part("IPv6", v6)
    }
    var publicIPGlyph: String {
        guard let v4 = network.ipv4Probe, network.ipv6Probe != nil else { return network.checkingIP ? "clock" : "circle" }
        return v4.address != nil ? "checkmark.circle.fill" : "xmark.circle.fill"
    }
    // MARK: Handshake
    var handshake: (summary: String, detail: String, glyph: String) {
        guard tunnel.running, tunnel.status == .connected else { return ("No tunnel", "Nothing is connected, so there is no handshake.", "circle") }
        guard tunnel.protocolName == "WireGuard" else {
            return (tunnel.protocolName == "IKEv2" ? "Handled by iOS" : "Not used", tunnel.protocolName == "IKEv2" ? "IKEv2 negotiates its own keys inside iOS and does not report them to the app." : "DNS-only mode has no VPN server, so there is no handshake.", "minus.circle")
        }
        guard let when = tunnel.stats?.latestHandshake else {
            return ((tunnel.uptimeSeconds ?? 0) > 20 ? "None yet" : "Waiting…", "No handshake has been reported. Right after connecting this is normal; if it stays like this the server may be unreachable or the keys may not match.", (tunnel.uptimeSeconds ?? 0) > 20 ? "xmark.circle.fill" : "clock")
        }
        let age = max(0, Int(Date().timeIntervalSince(when)))
        let fresh = age < 180
        let ago = age < 60 ? "\(age)s ago" : "\(age / 60) min ago"
        return ("\(ago) · " + (fresh ? "recent" : "old"), "Last handshake: \(when.formatted(date: .abbreviated, time: .standard)) (\(ago)).\n" + (fresh ? "The server answered recently." : "An idle tunnel stops handshaking. Send some traffic and run the check again."), fresh ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
    }
    // MARK: DNS resolvers
    var resolverName: String { store.dnsName.isEmpty ? "No resolver selected" : store.dnsName }
    var dnsSummary: String {
        if store.testing { return "Running…" }
        if store.endpoint.isEmpty { return "No resolver selected" }
        if store.result.isEmpty { return "\(resolverName) · not tested" }
        return store.result.hasPrefix("Probe passed") ? "\(resolverName) answered" : "\(resolverName) did not answer"
    }
    var dnsGlyph: String { store.testing ? "clock" : store.result.isEmpty ? "circle" : store.result.hasPrefix("Probe passed") ? "checkmark.circle.fill" : "xmark.circle.fill" }
    var dnsDetail: String {
        var lines = ["Resolver: \(resolverName)", "Test: \(store.probeDomain) · \(store.probeRecordType.title)" + (store.expectNXDOMAIN ? " · expecting a blocked answer" : "")]
        if let backup = store.backupDNS.flatMap({ id in store.dnsProfiles.first { $0.id == id } }) { lines.append("Backup resolver: \(backup.name) (used only if the main one fails)") }
        return lines.joined(separator: "\n") + "\n\n" + (store.result.isEmpty ? "Not tested" : store.result)
    }
    // MARK: Ad & tracker protection
    var adSummary: (text: String, glyph: String) {
        guard tunnel.running, tunnel.status == .connected else { return ("Off · start DNS to filter ads and trackers", "circle") }
        guard store.isVayuSetuDNSSelected else { return ("Filtering is up to your resolver · compare in this screen", "info.circle") }
        let blocked = tunnel.stats?.dnsCounters?.blocked ?? 0
        let counted = blocked > 0 ? " · \(blocked) blocked so far" : ""
        if store.dnsVerifying { return ("Testing a listed ad name…", "clock") }
        guard let check = store.dnsVerification else { return ("Not tested · run checks" + counted, "circle") }
        if check.passed && check.blockedChecked { return ("Blocking confirmed: a listed ad name was refused" + counted, "checkmark.circle.fill") }
        if check.passed { return ("DNS works · blocking not tested" + counted, "info.circle") }
        return ("Not confirmed: " + check.detail, "xmark.circle.fill")
    }
    // MARK: Routing policy, DNS routing, IPv6
    var policy: (summary: String, detail: String, glyph: String) {
        guard tunnel.running, tunnel.status == .connected else { return ("No tunnel", "Nothing is connected, so iOS has accepted no routing settings.", "circle") }
        guard let applied = tunnel.currentAppliedPolicy else {
            return ("Waiting for the tunnel to report", tunnel.protocolName == "IKEv2" ? "IKEv2 routing is set by iOS and is not reported to the app." : "Run the checks to read what iOS accepted.", "clock")
        }
        let captured = applied.ipv4Default && applied.ipv6Default ? "All IPv4 and IPv6 captured" : applied.ipv4Default ? "IPv4 captured" : "Partial capture"
        let routes = applied.excludedRouteCount == 0 ? "no excluded routes" : "\(applied.excludedRouteCount) excluded route\(applied.excludedRouteCount == 1 ? "" : "s")"
        return (captured + " · " + routes, applied.summary + "\n\n" + tunnel.configuredPolicySummary, applied.capturesBothFamilies ? "checkmark.circle.fill" : "info.circle")
    }
    var dnsRouting: (summary: String, detail: String, glyph: String) {
        guard tunnel.running, tunnel.status == .connected else { return ("No tunnel", "Nothing is connected, so lookups use the network's own DNS.", "circle") }
        if tunnel.protocolName == "IKEv2" { return ("Decided by the VPN server", "IKEv2 gets its DNS from the VPN server. The app cannot see which resolver is used.", "minus.circle") }
        let counters = tunnel.stats?.dnsCounters
        var lines: [String] = []
        if let applied = tunnel.currentAppliedPolicy { lines.append("DNS accepted by iOS: encrypted \(applied.encryptedDNS) · for all domains \(applied.allDNSDomains)") }
        guard let counters else { return ("Resolver set · not counted", (lines + ["This VPN uses your resolver without VayuSetu's local runtime, so lookups cannot be counted."]).joined(separator: "\n"), "info.circle") }
        lines.append("Lookups that reached the tunnel: \(counters.queries) · answered \(counters.answered)")
        if counters.queries > 0 { return ("Device lookups are reaching the tunnel", (lines + ["Apps that use their own DNS settings bypass this, and cannot be seen from here."]).joined(separator: "\n"), "checkmark.circle.fill") }
        return ("No device lookups seen yet", (lines + ["Open a page, then check again. Nothing has used the tunnel's DNS so far."]).joined(separator: "\n"), "questionmark.circle")
    }
    var ipv6Report: (summary: String, glyph: String) {
        guard tunnel.running, tunnel.status == .connected else { return ("No tunnel", "circle") }
        let blocked = tunnel.currentAppliedPolicy?.ipv6Restricted ?? tunnel.stats?.ipv6Blocked
        let policyText = blocked.map { $0 ? "blocked by the tunnel" : "carried by the tunnel" }
        guard let probe = network.ipv6Probe else { return ((policyText.map { $0.capitalized } ?? "Not reported") + " · run checks to confirm", "questionmark.circle") }
        if probe.address != nil, blocked == true { return ("Blocking is set, but IPv6 is reachable: possible leak", "exclamationmark.triangle.fill") }
        if probe.address != nil { return ("IPv6 \(policyText ?? "reachable")", "checkmark.circle.fill") }
        return ("No IPv6 seen" + (policyText.map { " · " + $0 } ?? ""), blocked == true ? "checkmark.circle.fill" : "info.circle")
    }
    // MARK: Quality and traffic
    var qualitySummary: String {
        if network.qualityRunning { return "Measuring…" }
        var parts: [String] = []
        if let q = network.qualityHistory.first {
            parts.append(q.mean.map { String(format: "%.0f ms", $0) + (q.failurePercent > 0 ? String(format: " · %.0f%% failed", q.failurePercent) : "") } ?? "all requests failed")
        }
        if let sp = network.speedHistory.first { parts.append("↓ " + SpeedFormat.text(sp.downBytesPerSecond)) }
        return parts.isEmpty ? "Not measured · timing and speed" : parts.joined(separator: " · ")
    }
    var trafficSummary: String {
        let bytes = { (v: UInt64) in ByteCountFormatter.string(fromByteCount: Int64(clamping: v), countStyle: .binary) }
        if tunnel.running, tunnel.status == .connected, let st = tunnel.stats { return "↓ \(bytes(st.received)) · ↑ \(bytes(st.sent)) this session" }
        return tunnel.history.isEmpty ? "No sessions yet" : "No active session · \(tunnel.history.count) past"
    }
    func evidence(_ name: String) -> String { guard let item = tunnel.evidence.first(where: { $0.name == name }) else { return "Not tested" }; return "\(item.timestamp.formatted()) · \(item.verdict.rawValue)\n\(item.method)" }
    func detail(_ title: String, _ summary: String, _ icon: String, _ explanation: String, _ output: String, _ glyph: String) -> some View {
        VSNavLink { VSCheckDetail(title: title, explanation: explanation, output: output) } label: {
            HStack { VSRow(title: title, subtitle: summary, icon: icon); Image(systemName: glyph).foregroundStyle(.secondary).accessibilityLabel(summary) }
        }
    }
}
struct VSLogsScreen: View {
    @ObservedObject var tunnel: TunnelController
    @State private var filter = "All"
    @State private var category = "All"
    @State private var search = ""
    @State private var paused = false
    @State private var following = true
    @State private var snapshot: [ConnectionEvent] = []
    @State private var clearing = false
    var rows: [ConnectionEvent] { (paused ? snapshot : tunnel.structuredEvents).filter { (filter == "All" || $0.severity == .error) && (category == "All" || $0.category == category) && (search.isEmpty || $0.message.localizedCaseInsensitiveContains(search)) } }
    var body: some View {
        AnyView(ScrollViewReader { proxy in VSCardList {
            VSSection { Picker("Severity", selection: $filter) { Text("All").tag("All"); Text("Errors").tag("Errors") }.pickerStyle(.segmented); Picker("Category", selection: $category) { Text("All categories").tag("All"); ForEach(Array(Set(tunnel.structuredEvents.map(\.category))).sorted(), id: \.self) { Text($0.capitalized).tag($0) } } }
            VSSection { ForEach(rows) { item in VStack(alignment: .leading, spacing: 5) { HStack { Image(systemName: item.severity == .error ? "exclamationmark.circle" : item.severity == .warning ? "exclamationmark.triangle" : "circle.fill").font(.caption2).foregroundStyle(item.severity == .error ? .red : item.severity == .warning ? .orange : .secondary); Text(item.timestamp.formatted(date: .omitted, time: .standard)).foregroundStyle(.secondary); Text(item.category).foregroundStyle(.secondary) }; Text(item.message) }.font(.system(.caption, design: .monospaced)).textSelection(.enabled).contextMenu { Button("Copy Event") { VSDesign.copy(item.display) } } }; if rows.isEmpty { Text("No matching events").foregroundStyle(.secondary) } }
        }.vsList().vsHeader("Logs").searchable(text: $search, prompt: "Search events")
        .toolbar { ToolbarItem { Toggle("Follow live", isOn: $following).toggleStyle(.button) }; ToolbarItem { Button(paused ? "Resume" : "Pause") { if !paused { snapshot = tunnel.structuredEvents }; paused.toggle() }.vsTapHaptic() }; ToolbarItem { ShareLink(item: tunnel.logReport) { Image(systemName: "square.and.arrow.up") } }; ToolbarItem { Button { clearing = true } label: { Image(systemName: "trash") }.accessibilityLabel("Clear saved logs") } }
        .vsConfirm(isPresented: $clearing, title: "Clear connection logs?", message: "The saved log of connection events is deleted from this device.", confirm: "Clear Logs", destructive: true, icon: "trash.fill") { tunnel.clearLogs(); snapshot = [] }
        .onChange(of: tunnel.structuredEvents.first?.id) { _, _ in if following && !paused, let id = rows.first?.id { proxy.scrollTo(id, anchor: .top) } } })
    }
}
struct VSTrafficScreen: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    @State private var clearing = false
    var body: some View {
        VSCardList {
            VSSection("Current tunnel") {
                VSRow(title: "Downloaded", value: bytes(tunnel.stats?.received))
                VSRow(title: "Uploaded", value: bytes(tunnel.stats?.sent))
                VSRow(title: "Duration", value: tunnel.duration)
                TrafficChart(tunnel: tunnel)
            }
            VSSection { ProfileUsagePanel(store: store, tunnel: tunnel) }
            VSSection("Recent sessions") { ForEach(tunnel.history) { item in VSRow(title: item.started.formatted(date: .abbreviated, time: .shortened), subtitle: item.ended.map { "Lasted " + Duration.seconds(max(0, $0.timeIntervalSince(item.started))).formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)) } ?? "Ended", value: bytes(item.received) + " ↓ · " + bytes(item.sent) + " ↑") }; if tunnel.history.isEmpty { Text("No completed sessions").foregroundStyle(.secondary) }; Button("Clear Session History", role: .destructive) { clearing = true } }
        }.vsList().vsHeader("Traffic").vsConfirm(isPresented: $clearing, title: "Clear session history?", message: "Completed sessions and their traffic totals are deleted.", confirm: "Clear History", destructive: true, icon: "trash.fill") { tunnel.clearHistory() }
    }
    func bytes(_ value: UInt64?) -> String { value.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .binary) } ?? "Not available" }
}

/// The DNS test settings, all visible, with the result right under the button.
struct VSDNSTestScreen: View {
    @ObservedObject var store: AppStore
    private let quick = ["example.com", "cloudflare.com", "apple.com", "doubleclick.net"]
    var valid: Bool { (try? DNSService.domain(store.probeDomain)) != nil }
    var body: some View {
        VSCardList {
            VSSection("Resolver") { VSRow(title: store.dnsName.isEmpty ? "None selected" : store.dnsName, subtitle: store.endpoint.isEmpty ? "Choose a resolver in the DNS tab first." : "The test asks this resolver.", icon: "network") }
            VSSection("Domain") {
                TextField("Domain to test", text: $store.probeDomain).textContentType(.URL).autocorrectionDisabled().vsNoCapitalize()
                if !valid { Text("Enter a valid domain, such as example.com.").font(.caption).foregroundStyle(.orange) }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack { ForEach(quick, id: \.self) { name in Button(name) { store.probeDomain = name }.buttonStyle(.bordered).vsTapHaptic() } }
                }
            } footer: { Text("doubleclick.net is a known ad domain: with filtering on and “Expect blocked” set, a blocked answer counts as a pass.") }
            VSSection("Query") {
                Picker("Record type", selection: $store.probeRecordType) { ForEach(DNSRecordType.allCases) { Text($0.title).tag($0) } }
                Toggle("Expect blocked (NXDOMAIN)", isOn: $store.expectNXDOMAIN)
            } footer: { Text("NXDOMAIN can also mean a domain does not exist, so this alone cannot prove filtering.") }
            VSSection {
                Button(store.testing ? "Testing…" : "Test Resolver") { store.testDNS() }.buttonStyle(VSActionStyle(primary: true)).disabled(store.endpoint.isEmpty || store.testing || !valid)
            }
            if !store.result.isEmpty { VSSection("Result") { Text(store.result).font(.footnote).textSelection(.enabled) } }
        }.vsList().vsHeader("DNS Test").vsEditor().disabled(false)
    }
}
