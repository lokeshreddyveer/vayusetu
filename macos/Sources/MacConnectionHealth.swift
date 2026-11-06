import Charts
import SwiftUI
import VayuSetuCore

/// Connection Health: how this Mac's connection is doing right now, and, when it stalls, what the evidence says caused it. It works with the VPN,
/// DNS and ad blocking all off. Every figure says whether it was measured, inferred or is not available.
struct MacConnectionHealth: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    @ObservedObject var monitor: WiFiMonitor
    @AppStorage("wifi-monitor-on") private var wanted = false
    @StateObject private var lab = NetLab.shared
    @State private var section = Section.overview
    @State private var confirmClear = false
    @State private var copied = false
    @State private var copiedReport = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var r: WiFiReading? { monitor.reading }

    enum Section: String, CaseIterable, Hashable {
        case overview = "Overview", wifi = "Wi-Fi", internet = "Internet", local = "Local network", lab = "Lab", history = "History"
    }

    var body: some View {
        MacPage(title: "Connection Health", subtitle: "How your connection is doing, and why it stalls when it does.") {
            monitorSwitch
            HStack { Spacer(minLength: 0); MacSegmented(selection: $section, options: Section.allCases, title: { $0.rawValue }); Spacer(minLength: 0) }
            content.id(section).transition(.opacity)
        }
        .macAnimate(.easeInOut(duration: 0.2), value: section)
        .onAppear {
            // The tunnel inputs are wired once, at launch (App.swift); this only starts watching if it was switched on.
            if wanted { monitor.start() }
        }
        .onDisappear { lab.cancelAll() }
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .overview: overview
        case .wifi: WiFiSection(monitor: monitor, lab: lab)
        case .internet: InternetSection(store: store, tunnel: tunnel, monitor: monitor, lab: lab)
        case .local: LocalSection(lab: lab)
        case .lab: LabSection(monitor: monitor, lab: lab)
        case .history: history
        }
    }

    @ViewBuilder private var overview: some View {
        if monitor.running {
            MacPanelLayout(minimumColumnWidth: 460) {
                healthPanel
                pathPanel
                componentsPanel
            }
            MacPanelLayout(minimumColumnWidth: 300) {
                signalTile
                routerTile
                lossTile
                linkTile
            }
            watchNotes
            latencyPanel
            advisorPanel
        } else {
            MacPanel("Not watching", icon: "waveform.path.ecg") {
                Text("Switch on \"Watch my connection\" above to see your signal, your router's latency and any stalls. The Internet, Local network and Lab tabs work without it.").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Short, factual notes under the tiles: a hotspot, a network slower than usual, a changed router, devices sharing a hardware address.
    @ViewBuilder private var watchNotes: some View {
        let hotspot = HotspotHint.detect(gateway: lab.gateway, expensive: monitor.path.expensive)
        let notes: [(String, String, Bool)] = [
            hotspot.map { ($0, "antenna.radiowaves.left.and.right", false) },
            monitor.baselineRemark.map { ($0, "tortoise", false) },
            monitor.gatewayVerdict.flatMap { $0.changed ? ($0.text, "wifi.router", true) : nil },
            monitor.arpDuplicates.isEmpty ? nil : ("Two or more addresses answer from one device: " + monitor.arpDuplicates.joined(separator: "; ") + ". That is normal for a device with several network adapters, and worth a look if you did not expect it.", "rectangle.on.rectangle", true)
        ].compactMap { $0 }
        if !notes.isEmpty {
            MacPanel("Worth knowing", icon: "info.circle") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(notes.enumerated()), id: \.offset) { _, n in
                        Label(n.0, systemImage: n.1).font(.system(size: 12)).foregroundStyle(n.2 ? Color.orange : Color.primary).fixedSize(horizontal: false, vertical: true)
                    }
                    provenance(.inferred)
                }
            }
        }
    }

    @ViewBuilder private var history: some View {
        qualityReport
        qualityPanel
        if monitor.running || !monitor.incidents.isEmpty { incidentsPanel }
        eventsPanel
    }

    private var qualityReport: some View {
        let summary = QualityReport.summarise(monitor.days)
        return MacPanel("Internet quality report", icon: "doc.text.magnifyingglass", trailing: {
            Button(copiedReport ? "Copied" : "Copy report") {
                let speeds = SpeedTracker.shared.history.prefix(10).map { ($0.mode.title, $0.down, $0.up, $0.latencyMs, $0.date) }
                let dayName: (Int) -> String = { Date(timeIntervalSince1970: Double($0) * 86400).formatted(date: .abbreviated, time: .omitted) }
                // The scheduled-check section states its own period and leaves out addresses; the domains shown beside a stall are never part of a report.
                let text = QualityReport.text(summary, speeds: Array(speeds), dayName: dayName) + "\n\n" + ScheduledReport.section(lab.scheduledRecords, dayName: dayName).joined(separator: "\n")
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                copiedReport = true; DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedReport = false }
            }.buttonStyle(MacHoverButtonStyle())
        }) {
            VStack(alignment: .leading, spacing: 8) {
                Text(summary.verdict).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                if let u = summary.uptime {
                    Text(String(format: "Router answered %.2f%% of checks over %d day%@", u * 100, summary.days, summary.days == 1 ? "" : "s") + (summary.medianMs.map { String(format: ", typically in about %.0f ms", $0) } ?? "") + ".").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("\(summary.stalls) stall\(summary.stalls == 1 ? "" : "s"), about \(summary.stallMinutes) minute\(summary.stallMinutes == 1 ? "" : "s") in all." + (summary.worstHour.map { String(format: " Most missed checks around %02d:00.", $0) } ?? "")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Text("The copied report has no addresses or network names. It measures this Mac's link to its router, so a poor result can be the Wi-Fi and not the provider: try a cable to tell them apart.").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                provenance(.inferred)
            }
        }
    }

    private var qualityPanel: some View {
        MacPanel("Last 30 days", icon: "calendar", trailing: { provenance(.measured) }) {
            let days = monitor.days.filter { $0.uptime != nil }
            if days.isEmpty { Text("Daily quality builds up while monitoring is on: how often your router answered, how fast, and how many stalls. It needs a few minutes of data for a day to appear.").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            else {
                Chart(days, id: \.day) { d in
                    BarMark(x: .value("Day", Date(timeIntervalSince1970: Double(d.day) * 86400), unit: .day), y: .value("Router answered", (d.uptime ?? 0) * 100)).foregroundStyle((d.uptime ?? 1) >= 0.99 ? Color.green : ((d.uptime ?? 1) >= 0.95 ? Color.orange : Color.red))
                }.chartYScale(domain: 80 ... 100).frame(height: 120)
                    .accessibilityLabel("Share of checks the router answered, per day")
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(days.suffix(7).reversed(), id: \.day) { d in
                        HStack {
                            Text(Date(timeIntervalSince1970: Double(d.day) * 86400), format: .dateTime.weekday(.abbreviated).month(.abbreviated).day()).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                            Text(String(format: "%.1f%% answered", (d.uptime ?? 0) * 100)).font(.system(size: 12)).monospacedDigit()
                            Spacer()
                            Text(d.medianMs.map { String(format: "~%.0f ms", $0) } ?? "").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                            Text(d.stalls == 0 ? "no stalls" : "\(d.stalls) stall" + (d.stalls == 1 ? "" : "s")).font(.system(size: 11)).foregroundStyle(d.stalls == 0 ? Color.secondary : Color.orange).frame(width: 70, alignment: .trailing)
                        }
                    }
                }
                Text("\"Answered\" is the share of checks your router replied to, measured only while monitoring was on. Latency is the typical router reply, grouped into bands, so it is approximate.").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var eventsPanel: some View {
        MacPanel("Timeline", icon: "list.bullet.below.rectangle", trailing: { if !lab.events.isEmpty { Button("Clear") { lab.clearEvents() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary) } }) {
            VStack(alignment: .leading, spacing: 8) {
                if lab.events.isEmpty { Text("Connection changes, wakes, stalls and recoveries will be listed here as they happen while monitoring is on.").font(.system(size: 12)).foregroundStyle(.secondary) }
                ForEach(lab.events.prefix(60)) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: icon(e.kind)).font(.system(size: 11)).foregroundStyle(e.kind == "stall" ? Color.orange : Color.secondary).frame(width: 16)
                        Text(e.date, format: .dateTime.month(.abbreviated).day().hour().minute().second()).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 118, alignment: .leading)
                        Text(e.text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
    private func icon(_ kind: String) -> String {
        switch kind { case "stall": "exclamationmark.triangle"; case "portal": "person.badge.key"; case "check": "checkmark.circle"; case "dns": "arrow.triangle.branch"; case "wake": "moon.zzz"; case "roam": "arrow.triangle.swap"; case "vpn": "lock.shield"; case "gateway": "wifi.router"; case "public-ip": "number"; case "recovery": "arrow.clockwise"; default: "arrow.triangle.swap" }
    }

    // MARK: Switch
    private var monitorSwitch: some View {
        MacPanel("Monitoring", icon: "waveform.path.ecg") {
            VStack(alignment: .leading, spacing: 10) {
                MacRow(icon: "dot.radiowaves.left.and.right", title: "Watch my connection",
                       detail: "Every few seconds VayuSetu sends one tiny packet to your router and one to Cloudflare's 1.1.1.1 (so Cloudflare sees your address), and a name lookup every ninth second through your normal resolver, then reads the Wi-Fi radio. When the connection stalls it records what it saw. Nothing is sent to VayuSetu, and it does not need the VPN, DNS or ad blocking on.") {
                    Toggle("", isOn: Binding(get: { monitor.running }, set: { on in wanted = on; if on { monitor.start() } else { monitor.stop() } })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .accessibilityLabel("Watch my connection")
                }
                if monitor.running {
                    Toggle("Tell me when a stall ends", isOn: $monitor.notifyOnStall).toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                    HStack {
                        Text("Run a quick check").font(.system(size: 12))
                        Picker("", selection: $lab.scheduleHours) { Text("never").tag(0); Text("every hour").tag(1); Text("every 3 hours").tag(3); Text("every 6 hours").tag(6) }.labelsHidden().frame(width: 150)
                        if let d = lab.lastScheduled { Text("last \(d.formatted(date: .omitted, time: .shortened))").font(.system(size: 11)).foregroundStyle(.secondary) }
                    }
                    MacExplainer(text: "The quick check asks Apple's connectivity page whether a sign-in page is in the way, asks api.ipify.org for your public address, and times the system resolver, Cloudflare and Google: about 20 small requests, never on a connection that costs data, and written to the Timeline only when something changed. It runs only while monitoring is on.")
                    Text("About 1 KB a minute. On a hotspot or low-data connection it slows to one check every 12 seconds.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Health ring and path
    private var healthPanel: some View {
        MacPanel("Connection health", icon: "heart.text.square", trailing: { MacChip(text: ConnectionHealth.label(monitor.score), tint: tint(monitor.score)) }) {
            HStack(spacing: 24) {
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.18), lineWidth: 12)
                    Circle().trim(from: 0, to: CGFloat(monitor.score ?? 0) / 100).stroke(tint(monitor.score), style: StrokeStyle(lineWidth: 12, lineCap: .round)).rotationEffect(.degrees(-90))
                        .macAnimate(.spring(response: 0.8, dampingFraction: 0.8), value: monitor.score)
                    VStack(spacing: 0) {
                        Text(monitor.score.map(String.init) ?? "—").font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit().contentTransition(.numericText()).macAnimate(value: monitor.score)
                        Text("out of 100").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.frame(width: 128, height: 128)
                VStack(alignment: .leading, spacing: 6) {
                    Text(stateLine).font(.system(size: 13, weight: .semibold)).foregroundStyle(stateTint)
                        .contentTransition(.opacity).macAnimate(value: stateLine)
                    Text("From the signal, the router's answers and how steady they are over the last minute or two. It is a summary: the numbers below are the detail.").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    provenance(.inferred)
                }
            }
        }
    }

    /// Four separate judgements, so a resolver outage never makes the Wi-Fi look poor and a dead router is not reported as three problems.
    private var componentsPanel: some View {
        let list = HealthAssessor.assess(rounds: monitor.rounds, resolver: tunnel.resolverHealth(),
                                         vpn: VPNHealthInput(running: tunnel.running && !tunnel.localDNSRunning, connected: tunnel.status == .connected, failed: tunnel.stage == .failed,
                                                             handshakeAge: tunnel.stats?.latestHandshake.map { Date().timeIntervalSince($0) }))
        return MacPanel("What is working", icon: "checklist") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(list, id: \.name) { c in
                    HStack(alignment: .top, spacing: 10) {
                        Circle().fill(color(c.state)).frame(width: 9, height: 9).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) { Text(c.name.rawValue).font(.system(size: 13, weight: .semibold)); provenance(c.provenance == .measured ? .measured : (c.provenance == .inferred ? .inferred : .unavailable)) }
                            Text(c.reason).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
    private func color(_ s: ComponentState) -> Color { switch s { case .good: .green; case .degraded: .yellow; case .failing: .red; case .unknown: .secondary } }

    private var pathPanel: some View {
        MacPanel("How you're connected", icon: monitor.path.icon, trailing: { MacChip(text: monitor.path.satisfied ? "Online" : "Offline", tint: monitor.path.satisfied ? .green : .red) }) {
            VStack(alignment: .leading, spacing: 10) {
                fact("Connection", monitor.path.primary, .measured)
                fact("Internet protocols", [monitor.path.supportsIPv4 ? "IPv4" : nil, monitor.path.supportsIPv6 ? "IPv6" : nil].compactMap { $0 }.joined(separator: " + ").nonEmpty ?? "None", .measured)
                fact("Costs data", monitor.path.expensive ? "Yes (hotspot or metered)" : "No", .measured)
                fact("Low-data mode", monitor.path.constrained ? "On" : "Off", .measured)
                fact("VayuSetu VPN", tunnel.running ? "On: the internet check goes through it, the router check stays local" : "Off", .measured)
                if let note = monitor.unavailableNote { Label(note, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
        }
    }

    // MARK: Tiles
    private var signalTile: some View {
        tile("Signal", icon: "wifi", value: r?.rssi.map { "\($0) dBm" } ?? "—", note: noteSignal, prov: r?.rssi == nil ? .unavailable : .measured)
    }
    private var routerTile: some View {
        let last = monitor.rounds.last(where: { $0.gatewayMs != nil })?.gatewayMs
        let usual = monitor.baselineMs
        return tile("Router latency", icon: "arrow.left.arrow.right", value: last.map { String(format: "%.0f ms", $0) } ?? "—",
                    note: usual.map { String(format: "Usually %.0f ms", $0) } ?? "Collecting…", prov: last == nil ? .unavailable : .measured)
    }
    private var lossTile: some View {
        let recent = monitor.rounds.suffix(30).compactMap(\.gatewayAnswered)
        let loss = recent.isEmpty ? nil : Int((Double(recent.filter { !$0 }.count) / Double(recent.count) * 100).rounded())
        return tile("Router packet loss", icon: "exclamationmark.arrow.triangle.2.circlepath", value: loss.map { "\($0)%" } ?? "—",
                    note: recent.isEmpty ? "Collecting…" : "Last \(recent.count) checks", prov: loss == nil ? .unavailable : .measured)
    }
    private var linkTile: some View {
        tile("Wi-Fi link", icon: "speedometer", value: r?.linkRateMbps.map { "\(Int($0)) Mbit/s" } ?? "—",
             note: [r?.band.rawValue, r?.channel.map { "ch \($0)" }, r?.widthMHz.map { "\($0) MHz" }].compactMap { $0 }.filter { $0 != "Unknown" }.joined(separator: " · ").nonEmpty ?? (monitor.path.wifi ? "Not reported" : "Not on Wi-Fi"),
             prov: r?.linkRateMbps == nil ? .unavailable : .measured)
    }
    private var noteSignal: String {
        guard let r, r.associated else { return monitor.path.wifi ? "Not reported" : "Not on Wi-Fi" }
        let quality = SignalQuality.from(rssi: r.rssi).rawValue
        return r.snr.map { "\(quality) · SNR \($0) dB" } ?? quality
    }

    // MARK: Chart
    private var latencyPanel: some View {
        MacPanel("Latency, last few minutes", icon: "chart.xyaxis.line", trailing: { provenance(.measured) }) {
            let data = Array(monitor.rounds.suffix(100))
            // The scale covers both lines (a VPN adds delay to the internet one) up to a ceiling; a reading above it is drawn at the ceiling
            // instead of off the chart, and anything that does reach the edge is clipped.
            let peak = max(data.compactMap(\.gatewayMs).max() ?? 0, data.compactMap(\.internetMs).max() ?? 0)
            let top = min(500.0, max(60.0, peak * 1.2))
            if data.count < 2 { Text("Collecting the first readings…").font(.system(size: 12)).foregroundStyle(.secondary) }
            else {
                Chart {
                    ForEach(data.indices, id: \.self) { i in
                        if let ms = data[i].gatewayMs { LineMark(x: .value("Time", data[i].date), y: .value("ms", min(Double(ms), top)), series: .value("Probe", "Router")).foregroundStyle(VSDesign.accent) }
                        if let ms = data[i].internetMs { LineMark(x: .value("Time", data[i].date), y: .value("ms", min(Double(ms), top)), series: .value("Probe", "Internet")).foregroundStyle(Color.green.opacity(0.8)) }
                        if data[i].gatewayAnswered == false { PointMark(x: .value("Time", data[i].date), y: .value("ms", 0)).foregroundStyle(Color.red).symbol(.cross) }
                    }
                }
                .chartYScale(domain: 0...top)
                .chartForegroundStyleScale(["Router": VSDesign.accent, "Internet": Color.green.opacity(0.8)])
                .frame(height: 170)
                .clipped()
                .accessibilityLabel("Latency to your router and to the internet over the last few minutes. Red crosses mark checks the router did not answer.")
                Text("Blue is your router, green the internet. A red cross is a check the router did not answer.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Advisor and history
    private var advisorPanel: some View {
        MacPanel("What to do", icon: "lightbulb") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(advice, id: \.self) { line in Label(line, systemImage: "arrow.turn.down.right").font(.system(size: 12)).fixedSize(horizontal: false, vertical: true) }
                provenance(.inferred)
            }
        }
    }

    private var incidentsPanel: some View {
        MacPanel("Stalls", icon: "clock.arrow.circlepath", trailing: {
            HStack(spacing: 8) {
                Button(copied ? "Copied" : "Copy report") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(monitor.report(), forType: .string); copied = true; DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false } }
                    .buttonStyle(MacHoverButtonStyle())
                if !monitor.incidents.isEmpty { Button("Clear") { confirmClear = true }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
        }) {
            VStack(alignment: .leading, spacing: 12) {
                if monitor.incidents.isEmpty {
                    Text("No stalls recorded yet. If the connection freezes while this is on, what VayuSetu saw is listed here, with the likely cause and how sure it is.").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    ForEach(monitor.incidents.prefix(12)) { incident in incidentRow(incident) }
                }
                Text("A stall is recorded only when the router fails to answer three checks, so a single slow reply is never called a fault. The report has no network name and no addresses.").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert("Clear the stall history?", isPresented: $confirmClear) { Button("Clear", role: .destructive) { monitor.clearHistory() }; Button("Cancel", role: .cancel) {} } message: { Text("The recorded stalls are deleted from this Mac.") }
    }

    private func incidentRow(_ i: WiFiIncident) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if let seq = i.sequence, seq > 0 { Label("Part \(seq + 1) of one continuing outage.", systemImage: "link").font(.system(size: 11)).foregroundStyle(.secondary) }
                ForEach(i.evidence, id: \.self) { Label($0, systemImage: "eye").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if let relations = i.relations, !relations.isEmpty {
                    Text("WHAT EACH PART SAW").font(.system(size: 10, weight: .semibold)).tracking(1.0).foregroundStyle(.tertiary).padding(.top, 2)
                    ForEach(relations, id: \.self) { Label($0, systemImage: "scope").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    Text("Order in time is not proof of cause: only a measured failure underneath is called a probable cause.").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                if let domains = i.domains {
                    Label(domains.isEmpty ? "No names were being looked up in the minute before." : "Looked up in the minute before: " + domains.joined(separator: ", "), systemImage: "globe").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(i.advice, id: \.self) { Label($0, systemImage: "arrow.turn.down.right").font(.system(size: 11)).fixedSize(horizontal: false, vertical: true) }
                Text("\(i.lostRounds) of \(i.rounds) router checks failed" + (i.worstLatencyMs.map { String(format: ", slowest reply %.0f ms", $0) } ?? "") + ".").font(.system(size: 10)).foregroundStyle(.tertiary)
            }.padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                Text(i.start, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
                Text(i.cause).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 6)
                MacChip(text: i.confidence + " confidence", tint: i.confidence == "High" ? .green : (i.confidence == "Medium" ? .orange : .secondary))
                Text("\(Int(i.duration)) s").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private var advice: [String] {
        if !monitor.path.satisfied { return ["There is no connection. Check that Wi-Fi is on or the cable is plugged in."] }
        if let r, r.associated, let rssi = r.rssi, rssi < -75 { return ["The signal is weak (\(rssi) dBm). Move closer to the router or remove obstacles between you."] }
        if let r, r.associated, r.band == .ghz2, monitor.path.wifi { return ["You are on 2.4 GHz. If your router also offers 5 GHz and you are near it, 5 GHz is usually faster and less crowded."] }
        if let last = monitor.incidents.first, Date().timeIntervalSince(last.start) < 600 { return last.advice }
        if monitor.state == .confirmed || monitor.state == .suspected { return ["The router is not answering as it should. VayuSetu is watching and will say what it finds if this turns into a stall."] }
        return ["Nothing needs doing. VayuSetu is watching, and will say if the connection starts to stall."]
    }

    // MARK: Pieces
    private var stateLine: String {
        switch monitor.state {
        case .healthy: return monitor.score == nil ? "Collecting the first readings…" : "No stall"
        case .suspected: return "The router missed a reply. Watching…"
        case .confirmed: return "A stall is in progress"
        case .recovering: return "Recovering…"
        }
    }
    private var stateTint: Color { monitor.state == .healthy ? .green : (monitor.state == .confirmed ? .red : .orange) }
    private func tint(_ score: Int?) -> Color {
        guard let score else { return .secondary }
        return score >= 90 ? .green : (score >= 75 ? Color(red: 0.2, green: 0.55, blue: 1.0) : (score >= 55 ? .orange : .red))
    }
    private func provenance(_ p: Provenance) -> some View {
        Text(p.rawValue).font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(.tertiary)
            .help(p == .measured ? "Read directly from the system or measured by a probe." : p == .inferred ? "Worked out from measured figures; it is a judgement, not a reading." : "macOS did not report this.")
    }
    private func fact(_ title: String, _ value: String, _ p: Provenance) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Text(value).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            provenance(p)
        }
    }
    private func tile(_ title: String, icon: String, value: String, note: String, prov: Provenance) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Label(title, systemImage: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary); Spacer(); provenance(prov) }
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                .contentTransition(.numericText()).macAnimate(.smooth(duration: 0.3), value: value)
            Text(note).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).macPanel().macAppear()
    }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }
