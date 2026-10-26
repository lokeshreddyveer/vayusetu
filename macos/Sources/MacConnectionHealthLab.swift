import Charts
import SwiftUI
import VayuSetuCore

// The sections of Connection Health that run on request: Wi-Fi details, Internet, Local network and the Lab. None of them needs the monitor
// to be running, and none changes a setting except the one recovery action, which asks first.

private func provenanceTag(_ p: Provenance) -> some View {
    Text(p.rawValue).font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(.tertiary)
}
private func factRow(_ title: String, _ value: String, _ p: Provenance) -> some View {
    HStack(alignment: .firstTextBaseline) {
        Text(title).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 140, alignment: .leading)
        Text(value).font(.system(size: 12, weight: .medium)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 6)
        provenanceTag(p)
    }
}
private func note(_ text: String) -> some View {
    Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
}
/// A button that starts something and turns into Cancel while it runs.
struct LabButton: View {
    @ObservedObject var lab: NetLab
    let key: String
    let title: String
    var disabled = false
    let work: @MainActor () async -> Void
    var body: some View {
        let on = lab.running.contains(key)
        Button { lab.toggle(key, work) } label: { Text(on ? "Cancel" : title) }.buttonStyle(MacHoverButtonStyle()).disabled(disabled && !on)
            .accessibilityLabel(on ? "Cancel \(title)" : title)
    }
}
private func ms(_ value: Double?) -> String { value.map { String(format: "%.0f ms", $0) } ?? "—" }

// MARK: Wi-Fi
struct WiFiSection: View {
    @ObservedObject var monitor: WiFiMonitor
    @ObservedObject var lab: NetLab
    @State private var confirmRestart = false

    var body: some View {
        MacPanelLayout(minimumColumnWidth: 460) {
            details
            signalPanel
            nearbyPanel
            roamPanel
            recoveryPanel
        }
    }

    private var details: some View {
        let r = monitor.reading
        return MacPanel("Your Wi-Fi", icon: "wifi", trailing: { MacChip(text: r?.associated == true ? "Connected" : "Not connected", tint: r?.associated == true ? .green : .secondary) }) {
            VStack(alignment: .leading, spacing: 9) {
                if monitor.running == false { note("Switch on \"Watch my connection\" on the Overview tab to read the radio.") }
                else if r?.associated != true { note("This Mac is not connected to a Wi-Fi network.") }
                else {
                    factRow("Network", r?.ssid ?? "Hidden until Location is allowed", r?.ssid == nil ? .unavailable : .measured)
                    factRow("Signal", r?.rssi.map { "\($0) dBm (\(SignalQuality.from(rssi: $0).rawValue))" } ?? "—", r?.rssi == nil ? .unavailable : .measured)
                    factRow("Noise", r?.noise.map { "\($0) dBm" } ?? "—", r?.noise == nil ? .unavailable : .measured)
                    factRow("Signal to noise", r?.snr.map { "\($0) dB" } ?? "—", r?.snr == nil ? .unavailable : .inferred)
                    factRow("Band and channel", [r?.band.rawValue, r?.channel.map { "channel \($0)" }, r?.widthMHz.map { "\($0) MHz wide" }].compactMap { $0 }.joined(separator: ", "), r?.channel == nil ? .unavailable : .measured)
                    factRow("Standard", r?.phyMode ?? "—", r?.phyMode == nil ? .unavailable : .measured)
                    factRow("Link rate", r?.linkRateMbps.map { "\(Int($0)) Mbit/s" } ?? "—", r?.linkRateMbps == nil ? .unavailable : .measured)
                    factRow("Security", r?.security ?? "—", r?.security == nil ? .unavailable : .measured)
                    note("The link rate is what the radio negotiated with the router, not your internet speed. A weak signal lowers it.")
                }
            }
        }
    }

    private var signalPanel: some View {
        MacPanel("Signal over time", icon: "waveform.path", trailing: { provenanceTag(.measured) }) {
            let points = Array(monitor.signalHistory.suffix(120))
            if points.count < 3 { note("Collecting readings. The signal is read every few seconds while monitoring is on.") }
            else {
                Chart(points) { p in LineMark(x: .value("Time", p.date), y: .value("dBm", p.rssi)).foregroundStyle(VSDesign.accent) }
                    .chartYScale(domain: -100 ... -30).frame(height: 130)
                    .accessibilityLabel("Wi-Fi signal strength over the last few minutes")
                note("Higher is stronger: about −50 is excellent, −70 is fair, below −80 is weak. A drop that lines up with a stall is the signal's doing.")
            }
        }
    }

    private var roamPanel: some View {
        MacPanel("Access-point changes", icon: "arrow.triangle.swap", trailing: { provenanceTag(.measured) }) {
            VStack(alignment: .leading, spacing: 8) {
                if monitor.roams.isEmpty { note("None seen. A Mac moves between access points when you walk between routers or a mesh system's nodes; each move can pause traffic for a moment.") }
                ForEach(monitor.roams.prefix(8)) { r in
                    HStack {
                        Text(r.date, format: .dateTime.month(.abbreviated).day().hour().minute().second()).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
                        Text(r.from.flatMap { a in r.to.map { b in "\(a) → \(b) dBm" } } ?? "signal not reported").font(.system(size: 12)).monospacedDigit()
                    }
                }
                if monitor.roams.count > 4 { note("Many changes in a short time suggest the Mac is flipping between two access points. Moving the Mac or turning down the weaker one's power usually stops it.") }
            }
        }
    }

    private var nearbyPanel: some View {
        let own = monitor.reading
        let sorted = lab.nearby.sorted { $0.rssi > $1.rssi }
        return MacPanel("Nearby networks", icon: "dot.radiowaves.left.and.right", trailing: {
            LabButton(lab: lab, key: "scan", title: "Scan") { await lab.scanWiFi() }
        }) {
            VStack(alignment: .leading, spacing: 10) {
                if lab.nearby.isEmpty { note(lab.scanNote ?? "A scan listens on each channel for a few seconds and can briefly interrupt your connection, so it runs only when you press Scan.") }
                else {
                    ForEach(ChannelAdvisor.advice(ownChannel: own?.channel, ownBand: own?.band ?? .unknown, ownWidthMHz: own?.widthMHz, networks: lab.nearby), id: \.self) { line in
                        Label(line, systemImage: "lightbulb").font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    note("\(lab.nearby.count) networks heard. Their names are not shown here.")
                    ForEach(Array(sorted.prefix(8).enumerated()), id: \.offset) { _, n in
                        HStack {
                            Text("\(n.band.rawValue) · channel \(n.channel)").font(.system(size: 12))
                            Spacer()
                            Text("\(n.rssi) dBm").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    provenanceTag(.measured)
                }
            }
        }
    }

    private var recoveryPanel: some View {
        MacPanel("Fix it", icon: "wrench.and.screwdriver") {
            VStack(alignment: .leading, spacing: 10) {
                MacRow(icon: "arrow.clockwise", title: "Restart Wi-Fi", detail: "Switches Wi-Fi off for three seconds and on again. This is the first thing to try after a stall. Nothing else is changed.") {
                    Button(lab.busy.contains("restart") ? "Restarting…" : "Restart") { confirmRestart = true }.buttonStyle(MacHoverButtonStyle()).disabled(lab.busy.contains("restart"))
                }
                if !lab.recoveries.isEmpty {
                    Divider()
                    Text("What was done").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(lab.recoveries.prefix(5)) { r in
                        HStack(alignment: .firstTextBaseline) {
                            Text(r.date, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.system(size: 10)).foregroundStyle(.tertiary).frame(width: 90, alignment: .leading)
                            Text(r.outcome).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .alert("Restart Wi-Fi?", isPresented: $confirmRestart) {
            Button("Restart") { Task { await lab.restartWiFi() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Wi-Fi goes off for about three seconds. Downloads and calls in progress will pause and then continue or reconnect.") }
    }
}

// MARK: Internet
struct InternetSection: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    @ObservedObject var monitor: WiFiMonitor
    @ObservedObject var lab: NetLab

    private var findings: [AdvisorFinding] {
        let vpn = tunnel.running && !tunnel.localDNSRunning
        var list = [NetworkAdvisor.dnsFinding(resolvers: lab.resolvers, vayuDNSOn: store.dnsPill == .active || tunnel.localDNSRunning, vpnOn: vpn)]
        if vpn || lab.publicIP != nil { list += LeakCheck.assess(vpnOn: vpn, publicIP: lab.publicIP, baselineIP: lab.baselineIP, ipv6WorksDirectly: lab.ipv6Direct) }
        list += NetworkAdvisor.securityFindings(wifiSecurity: monitor.reading?.security, associated: monitor.reading?.associated ?? false, proxies: lab.proxies, gatewayChanged: lab.gatewayChanged, portal: lab.captive)
        return list
    }

    var body: some View {
        MacPanelLayout(minimumColumnWidth: 460) {
            advisorPanel
            configPanel
            reachPanel
            dnsPanel
            sitesPanel
        }
        .onAppear { lab.readConfiguration() }
    }

    private var advisorPanel: some View {
        MacPanel("Network checks", icon: "lock.shield", trailing: { Button("Refresh") { lab.readConfiguration() }.buttonStyle(MacHoverButtonStyle()) }) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(findings) { f in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: f.severity == .attention ? "exclamationmark.triangle.fill" : (f.severity == .ok ? "checkmark.circle.fill" : "info.circle.fill"))
                            .foregroundStyle(f.severity == .attention ? Color.orange : (f.severity == .ok ? Color.green : Color.secondary)).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.title).font(.system(size: 12, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                            note(f.detail)
                        }
                    }
                }
                provenanceTag(.inferred)
            }
        }
    }

    private var configPanel: some View {
        MacPanel("Addresses and settings", icon: "list.bullet.rectangle") {
            VStack(alignment: .leading, spacing: 9) {
                factRow("Connected through", lab.interfaceName ?? "—", lab.interfaceName == nil ? .unavailable : .measured)
                factRow("This Mac's address", lab.localAddresses.isEmpty ? "—" : lab.localAddresses.joined(separator: "\n"), lab.localAddresses.isEmpty ? .unavailable : .measured)
                factRow("Router", lab.gateway ?? "—", lab.gateway == nil ? .unavailable : .measured)
                factRow("Name servers", lab.resolvers.isEmpty ? "—" : lab.resolvers.joined(separator: ", "), lab.resolvers.isEmpty ? .unavailable : .measured)
                factRow("Proxy", lab.proxies.isEmpty ? "None set" : lab.proxies.joined(separator: ", "), .measured)
                factRow("Packet size (MTU)", lab.mtu.map { "\($0)" } ?? "—", lab.mtu == nil ? .unavailable : .measured)
                note("Read from the system's own settings; nothing is sent.")
            }
        }
    }

    private var reachPanel: some View {
        MacPanel("Reaching the internet", icon: "globe") {
            VStack(alignment: .leading, spacing: 12) {
                MacRow(icon: "person.badge.key", title: "Sign-in page check", detail: lab.captive.map { "Result: \($0.rawValue)" } ?? "Asks Apple's connectivity page whether something is asking you to sign in first, as hotel and café Wi-Fi does.") {
                    LabButton(lab: lab, key: "captive", title: "Check") { await lab.checkCaptive() }
                }
                Divider()
                MacRow(icon: "number", title: "Public address", detail: publicDetail) {
                    LabButton(lab: lab, key: "ip", title: "Look up") { await lab.lookupPublicIP(vpnOn: tunnel.running && !tunnel.localDNSRunning) }
                }
                Divider()
                MacRow(icon: "6.circle", title: "IPv6", detail: lab.ipv6Result ?? "Checks whether this network gives you IPv6 and whether it works.") {
                    LabButton(lab: lab, key: "ipv6", title: "Test") { await lab.testIPv6() }
                }
            }
        }
    }
    private var publicDetail: String {
        guard let ip = lab.publicIP else { return "The address websites see. Asks api.ipify.org, which sees it too. It changes when the VPN is on." }
        return "\(ip)" + (tunnel.running && !tunnel.localDNSRunning ? " (through the VPN)" : "")
    }

    private var dnsPanel: some View {
        MacPanel("Name servers compared", icon: "arrow.triangle.branch", trailing: {
            LabButton(lab: lab, key: "dns", title: "Compare") { await lab.compareDNS() }
        }) {
            VStack(alignment: .leading, spacing: 8) {
                if lab.dnsTimings.isEmpty { note("Asks five questions of the system's resolver, Cloudflare and Google, and shows how long each takes. About 15 small lookups in all.") }
                ForEach(lab.dnsTimings) { t in
                    HStack {
                        Text(t.name).font(.system(size: 12))
                        Spacer()
                        Text(t.medianMs.map { String(format: "%.0f ms", $0) } ?? "no answer").font(.system(size: 12, weight: .medium)).monospacedDigit()
                        Text("\(t.answered)/\(t.asked)").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
                if !lab.dnsTimings.isEmpty { note("Middle of five answers, in milliseconds. A resolver that is much slower than the others is worth changing, in Encrypted DNS.") }
            }
        }
    }

    private var sitesPanel: some View {
        MacPanel("Websites", icon: "network", trailing: {
            LabButton(lab: lab, key: "sites", title: "Check") { await lab.checkSites() }
        }) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Add a site (https://…)", text: $lab.customSite).textFieldStyle(.roundedBorder).font(.system(size: 12))
                if lab.sites.isEmpty { note("Shows where the time goes for each site: finding it, connecting, the secure handshake, and the first reply.") }
                ForEach(lab.sites) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(s.url.replacingOccurrences(of: "https://", with: "")).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Spacer()
                            if let status = s.status { MacChip(text: "\(status)", tint: (200..<400).contains(status) ? .green : .orange) }
                        }
                        if let failure = s.failure { Text(failure).font(.system(size: 11)).foregroundStyle(.orange) }
                        else { Text("lookup \(ms(s.dnsMs)) · connect \(ms(s.connectMs)) · secure \(ms(s.tlsMs)) · first reply \(ms(s.firstByteMs))").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit() }
                    }
                }
            }
        }
    }
}

// MARK: Local network
struct LocalSection: View {
    @ObservedObject var lab: NetLab

    var body: some View {
        MacPanelLayout(minimumColumnWidth: 460) {
            routerPanel
            interfacesPanel
            devicesPanel
        }
        .onAppear { lab.readConfiguration(); lab.readInterfaces(); Task { await lab.readDHCP() } }
        .onDisappear { lab.stopBrowsing() }
    }

    private var routerPanel: some View {
        MacPanel("Your router", icon: "wifi.router") {
            VStack(alignment: .leading, spacing: 9) {
                factRow("Address", lab.gateway ?? "—", lab.gateway == nil ? .unavailable : .measured)
                factRow("This Mac", lab.localAddresses.first ?? "—", lab.localAddresses.isEmpty ? .unavailable : .measured)
                if let d = lab.dhcp {
                    factRow("Subnet mask", d.subnetMask ?? "—", d.subnetMask == nil ? .unavailable : .measured)
                    factRow("Address given by", d.server ?? "—", d.server == nil ? .unavailable : .measured)
                    factRow("Lease lasts", d.leaseText ?? "—", d.leaseText == nil ? .unavailable : .measured)
                }
                note("Latency and loss to the router are on the Overview tab. If the router is slow to answer, the problem is between this Mac and it, not the internet.")
            }
        }
    }

    private var interfacesPanel: some View {
        MacPanel("Connections on this Mac", icon: "point.3.connected.trianglepath.dotted", trailing: {
            HStack(spacing: 8) {
                Button("Refresh") { lab.readInterfaces() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                LabButton(lab: lab, key: "compare", title: "Compare") { await lab.compareInterfaces() }
            }
        }) {
            VStack(alignment: .leading, spacing: 12) {
                if lab.interfaces.isEmpty { note("Reading the network interfaces…") }
                ForEach(lab.interfaces) { i in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: i.kind.icon).frame(width: 18).foregroundStyle(i.active ? Color.green : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(i.display) · \(i.name)").font(.system(size: 12, weight: .semibold))
                            Text(i.kind.rawValue + (i.active ? " · carrying traffic" : " · no connection") + (i.speedMbps.map { " · \(Int($0)) Mbit/s link" } ?? "")).font(.system(size: 11)).foregroundStyle(.secondary)
                            if let a = i.addresses.first(where: { !$0.hasPrefix("fe80") }) { Text(a).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled) }
                            Text("received \(ByteFormat.text(i.rxBytes)) · sent \(ByteFormat.text(i.txBytes)) since start-up").font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                }
                if !lab.comparison.isEmpty {
                    Divider()
                    Text("Internet latency on each connection").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(lab.comparison) { c in
                        HStack { Image(systemName: c.kind.icon).frame(width: 18); Text("\(c.kind.rawValue) (\(c.name))").font(.system(size: 12)); Spacer(); Text(c.medianMs.map { String(format: "%.0f ms", $0) } ?? "no answer").font(.system(size: 12, weight: .medium)).monospacedDigit(); Text("\(c.answered)/\(c.asked)").font(.system(size: 10)).foregroundStyle(.tertiary) }
                    }
                }
                note("Link speed is what the adapter negotiated, where macOS reports it. The comparison sends five small packets over each active connection, one at a time.")
            }
        }
    }

    private var devicesPanel: some View {
        MacPanel("Devices advertising services", icon: "printer", trailing: {
            Button(lab.browsing ? "Listening…" : "Look") { lab.startBrowsing() }.buttonStyle(MacHoverButtonStyle()).disabled(lab.browsing)
        }) {
            VStack(alignment: .leading, spacing: 10) {
                if lab.devices.isEmpty { note(lab.browsing ? "Listening for about 20 seconds…" : "Lists printers, speakers, computers and other devices on this network that announce themselves. VayuSetu only listens; it never connects to them. macOS may ask for permission to find devices on your local network.") }
                let grouped = Dictionary(grouping: lab.devices, by: \.kind)
                ForEach(grouped.keys.sorted(), id: \.self) { kind in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(kind.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
                        ForEach(grouped[kind] ?? []) { d in Text(d.name).font(.system(size: 12)) }
                    }
                }
                if !lab.devices.isEmpty { note("\(lab.devices.count) found. A device that does not announce itself is not listed.") }
            }
        }
    }
}

// MARK: Lab
struct LabSection: View {
    @ObservedObject var monitor: WiFiMonitor
    @ObservedObject var lab: NetLab
    @State private var target = "1.1.1.1"
    @State private var host = ""
    @State private var port = "443"

    private var metered: Bool { monitor.path.expensive || monitor.path.constrained }

    var body: some View {
        MacPanelLayout(minimumColumnWidth: 460) {
            tracePanel
            mtuPanel
            bloatPanel
            portPanel
        }
    }

    private var tracePanel: some View {
        MacPanel("Route to a server", icon: "point.topleft.down.to.point.bottomright.curvepath", trailing: {
            LabButton(lab: lab, key: "trace", title: "Trace") { await lab.traceroute(to: target) }
        }) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Address", text: $target).textFieldStyle(.roundedBorder).font(.system(size: 12))
                if lab.hops.isEmpty { note(lab.tracing ? "Following the route, up to 20 steps…" : "Shows each router your traffic passes on the way to the address. A step that does not answer is common and is not a fault.") }
                ForEach(lab.hops) { hop in
                    HStack {
                        Text("\(hop.index)").font(.system(size: 11)).foregroundStyle(.tertiary).frame(width: 22, alignment: .trailing)
                        Text(hop.host ?? "no reply").font(.system(size: 12)).foregroundStyle(hop.host == nil ? .secondary : .primary)
                        Spacer()
                        Text(ms(hop.ms)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                if let jump = TracerouteParser.jump(in: lab.hops) { note("The time jumps at step \(jump.index) (\(ms(jump.ms))). That is where the path to the destination gets slow, such as the hand-off to your provider or a long-distance link.") }
            }
        }
    }

    private var mtuPanel: some View {
        MacPanel("Packet size", icon: "arrow.left.and.right", trailing: {
            LabButton(lab: lab, key: "mtu", title: "Test") { await lab.findPathMTU() }
        }) {
            VStack(alignment: .leading, spacing: 8) {
                if let mtu = lab.pathMTU {
                    Text("\(mtu) bytes").font(.system(size: 22, weight: .semibold, design: .rounded))
                    note(PathMTU.comment(mtu))
                } else { note(lab.mtuNote ?? "Finds the largest packet that gets to the internet without being cut up. A low number behind a tunnel is normal; a low number on a plain connection can make some sites hang.") }
            }
        }
    }

    private var bloatPanel: some View {
        MacPanel("Latency under load", icon: "gauge.with.dots.needle.67percent", trailing: {
            LabButton(lab: lab, key: "bloat", title: "Test", disabled: metered) { await lab.measureBufferbloat() }
        }) {
            VStack(alignment: .leading, spacing: 8) {
                if metered { Label("This connection costs data or is in low-data mode, so the test is off. It downloads for about eight seconds.", systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(.orange) }
                if let b = lab.bloat {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(b.grade).font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(gradeTint(b.grade))
                        VStack(alignment: .leading, spacing: 2) { Text(String(format: "+%.0f ms when busy", b.addedMs)).font(.system(size: 13, weight: .semibold)); if let n = lab.bloatNote { note(n) } }
                    }
                    note(b.text)
                } else { note(lab.bloatNote ?? "Measures how much a busy line slows everything else down, which is what makes calls and games stutter while something downloads. It uses about eight seconds of download.") }
            }
        }
    }
    private func gradeTint(_ g: String) -> Color { g.hasPrefix("A") ? .green : (g == "B" ? Color(red: 0.2, green: 0.55, blue: 1.0) : (g == "C" ? .orange : .red)) }

    private var portPanel: some View {
        MacPanel("Is a port open?", icon: "door.left.hand.open") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Host or address", text: $host).textFieldStyle(.roundedBorder).font(.system(size: 12))
                    TextField("Port", text: $port).textFieldStyle(.roundedBorder).font(.system(size: 12)).frame(width: 70)
                    LabButton(lab: lab, key: "port", title: "Try") { await lab.checkPort(host: host, port: port) }
                }
                if let r = lab.portResult { Text(r).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true) }
                note("Makes one connection attempt to the one address and port you enter, and closes it. It never scans a range. Only use it on machines you own or run.")
            }
        }
    }
}
