import SwiftUI
import Charts
import UniformTypeIdentifiers

struct EncryptedBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct BackupPanel: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    @State private var password = ""
    @State private var includeCredentials = false
    @State private var busy = false
    @State private var message = ""
    @State private var exporting = false
    @State private var importing = false
    @State private var confirming = false
    @State private var document = EncryptedBackupDocument()
    @State private var pending: ConfigurationBackup?
    var body: some View {
        AnyView(VStack(alignment: .leading, spacing: 14) {
            Label("Encrypted backup", systemImage: "externaldrive.badge.checkmark").font(.headline)
            Text("The default backup includes profile names, custom rules and list names. VPN keys, addresses, resolver endpoints and list URLs are excluded.").font(.caption).foregroundStyle(.secondary)
            Toggle("Include Credentials & Endpoints", isOn: $includeCredentials)
            if includeCredentials { Text("Includes private VPN keys and personalized URLs. Protect the file and password separately.").font(.caption).foregroundStyle(.orange) }
            SecureField("Backup password · 12+ characters", text: $password).textContentType(.newPassword)
            HStack {
                Button("Export Backup", systemImage: "square.and.arrow.up") { exportBackup() }
                Button("Restore Backup", systemImage: "square.and.arrow.down") { importing = true }.disabled(tunnel.running || tunnel.busy || store.testing)
            }.buttonStyle(.bordered).vsTapHaptic().disabled(busy || password.utf8.count < 12 || password.utf8.count > 1024)
            if busy { ProgressView("Protecting your configuration…") }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            Text("All backups are password encrypted. The password cannot be recovered. Metadata-only profiles need their configuration reimported before use.").font(.caption2).foregroundStyle(.secondary)
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .data, defaultFilename: "VayuSetu.vayubackup") { outcome in
            switch outcome { case .success: message = "Encrypted backup exported."; case .failure: message = "Backup export did not finish." }
            document = EncryptedBackupDocument()
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { outcome in
            switch outcome {
            case .success(let url): restorePreview(url)
            case .failure: message = "No backup was selected."
            }
        }
        .vsConfirm(isPresented: $confirming, title: "Restore \((pending?.vpn.count ?? 0) + (pending?.nativeIKEv2?.count ?? 0) + (pending?.metadata ?? []).filter { $0.kind == "vpn" || $0.kind == "ikev2" }.count) VPN and \((pending?.dns.count ?? 0) + (pending?.metadata ?? []).filter { $0.kind == "dns" }.count) DNS profiles?", message: "Existing profiles and connection preferences are preserved. Restore does not start a VPN. Metadata-only profiles require reimport; list names without sources are not activated.", confirm: "Add Restored Profiles", icon: "arrow.counterclockwise.circle.fill") {
                defer { pending = nil }
                if let backup = pending { busy = true; Task {
                    defer { busy = false }
                    do { try store.restoreBackup(backup)
                        do { try await store.filtering.restoreFilterMetadata(backup); message = backup.includesCredentials == false ? "Metadata restored. Reimport profile credentials and list sources before use. Custom rules were merged; existing data was preserved." : "Profiles and rules restored. New lists remain off until you select them." }
                        catch { message = "Profiles restored; filter metadata was not applied. Previous rules preserved. " + error.localizedDescription }
                    } catch { message = error.localizedDescription }
                } }
            }
        .onChange(of: confirming) { _, now in if !now { pending = nil } })
    }
    private func exportBackup() {
        do {
            let snapshot = try store.backupSnapshot(includeCredentials: includeCredentials); let secret = password
            busy = true; message = ""
            Task {
                defer { busy = false; password = "" }
                do {
                    let data = try await Task.detached(priority: .userInitiated) { try BackupCrypto.encrypt(snapshot, password: secret) }.value
                    document = EncryptedBackupDocument(data: data); exporting = true
                } catch { message = error.localizedDescription }
            }
        } catch { message = error.localizedDescription }
    }
    private func restorePreview(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try LocalFiles.read(url, maximum: 12_000_000); let secret = password
            busy = true; message = ""
            Task {
                defer { busy = false; password = "" }
                do {
                    pending = try await Task.detached(priority: .userInitiated) { try BackupCrypto.decrypt(data, password: secret) }.value
                    confirming = true
                } catch { message = error.localizedDescription }
            }
        } catch { message = "Could not read backup. Select a regular file smaller than 12 MB." }
    }
}

struct RetryPreferences: View {
    @ObservedObject var tunnel: TunnelController
    var store: AppStore? = nil
    var body: some View {
        AnyView(VStack(alignment: .leading, spacing: 12) {
            Label("Connection recovery", systemImage: "arrow.clockwise.circle").font(.headline)
            Stepper("Retry limit: \(tunnel.retryLimit)", value: $tunnel.retryLimit, in: 1...10)
            Stepper("Connection timeout: \(tunnel.connectionTimeout)s", value: $tunnel.connectionTimeout, in: 10...120, step: 5)
            Stepper(tunnel.usageBudgetMB == 0 ? "Tunnel data alert: off" : "Tunnel data alert: \(tunnel.usageBudgetMB) MiB", value: $tunnel.usageBudgetMB, in: 0...100_000, step: 100)
            Text("The data alert uses combined WireGuard counters, including encrypted transport overhead. Set to zero to disable. Notifications follow your notification preference.").font(.caption2).foregroundStyle(.secondary)
            Text("Retries use increasing delays, capped at 16 seconds. Applies while this app is active; background behavior is managed by the system.").font(.caption).foregroundStyle(.secondary)
            if let store { BackupChoices(store: store) }
        }.disabled(tunnel.running || tunnel.busy))
    }
}

/// Optional backups: a second encrypted resolver and a second VPN profile, used only when the first choice fails.
struct BackupChoices: View {
    @ObservedObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Picker("Backup resolver", selection: $store.backupDNS) {
                Text("None").tag(UUID?.none)
                ForEach(store.dnsProfiles.filter { $0.id != store.selectedDNS }) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            Text("Asked only when your main resolver does not answer. Always encrypted; it never falls back to plain DNS.").font(.caption).foregroundStyle(.secondary)
            Picker("Backup VPN profile", selection: $store.backupProfile) {
                Text("None").tag(UUID?.none)
                ForEach(store.profiles.filter { $0.id != store.selected }) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            Text("If the selected profile fails to connect, VayuSetu tries this one once and tells you.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct QualityPanel: View {
    @ObservedObject var network: NetworkDiagnostics
    let status: String
    @State private var clearing = false
    var body: some View {
        AnyView(VStack(alignment: .leading, spacing: 14) {
            Label("Connection quality", systemImage: "waveform.path").font(.headline)
            if !network.networkDetails.isEmpty { Text(network.networkDetails).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button(network.qualityRunning ? "Checking…" : "Run Quality Check") { network.runQuality(status: status) }.buttonStyle(.borderedProminent).vsTapHaptic().disabled(network.qualityRunning)
                if network.qualityRunning { Button("Cancel") { network.cancelQuality() }.buttonStyle(.bordered).vsTapHaptic() }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Label("Speed test", systemImage: "speedometer").font(.headline)
                Text("Measures latency, download and upload to Cloudflare’s nearest server through the connection you are on now. Run it with the VPN off and on to see what the VPN costs. It uses about 70 MB of data.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(network.speedRunning ? (network.speedPhase.isEmpty ? "Testing…" : network.speedPhase) : "Run Speed Test") { network.runSpeed(status: status) }.buttonStyle(.borderedProminent).vsTapHaptic().disabled(network.speedRunning)
                    if network.speedRunning { Button("Cancel") { network.cancelSpeed() }.buttonStyle(.bordered).vsTapHaptic() }
                }
                if let speed = network.speedHistory.first {
                    HStack(spacing: 20) {
                        metric("Download", SpeedFormat.text(speed.downBytesPerSecond))
                        metric("Upload", SpeedFormat.text(speed.upBytesPerSecond))
                        metric("Latency", speed.latencyMs.map { String(format: "%.0f ms", $0) } ?? "—")
                    }
                    Text("\(speed.status) · " + speed.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    if network.speedHistory.count > 1 {
                        DisclosureGroup("Earlier runs · \(network.speedHistory.count - 1)") {
                            ForEach(network.speedHistory.dropFirst().prefix(10)) { run in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(run.status + " · " + run.date.formatted(date: .abbreviated, time: .shortened)).font(.caption.bold())
                                    Text("↓ \(SpeedFormat.text(run.downBytesPerSecond))  ↑ \(SpeedFormat.text(run.upBytesPerSecond))  ·  " + (run.latencyMs.map { String(format: "%.0f ms", $0) } ?? "—")).font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 2)
                            }
                            Button("Clear speed results", role: .destructive) { network.clearSpeedHistory() }
                        }.font(.subheadline)
                    }
                }
                if !network.speedMessage.isEmpty { Text(network.speedMessage).font(.caption).foregroundStyle(.secondary) }
            }
            if let result = network.qualityHistory.first {
                HStack(spacing: 20) {
                    metric("HTTP mean", result.mean.map { String(format: "%.0f ms", $0) } ?? "No reply")
                    metric("Timing variation", result.jitter.map { String(format: "%.0f ms", $0) } ?? "—")
                    metric("Failed requests", String(format: "%.0f%%", result.failurePercent))
                }
                DisclosureGroup("Recent checks · \(network.qualityHistory.count)") {
                    ForEach(network.qualityHistory.prefix(10)) { check in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(check.date.formatted()).font(.caption.bold())
                            Text("\(check.milliseconds.count)/5 replies · \(check.status)").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                    HStack {
                        ShareLink("Export Report", item: network.sanitizedReport)
                        Button("Clear History", role: .destructive) { clearing = true }.disabled(network.qualityRunning)
                    }
                }.font(.caption)
            }
            if !network.qualityMessage.isEmpty { Text(network.qualityMessage).font(.caption).foregroundStyle(.secondary) }
            Text("Sends five HTTPS requests to ipify using the current route. Timing includes HTTPS and server processing. Failed requests are not packet loss; these checks do not prove protection. Results are stored locally, without observed IPs.").font(.caption2).foregroundStyle(.secondary)
        }.vsConfirm(isPresented: $clearing, title: "Clear quality history?", message: "Saved connection quality results are deleted.", confirm: "Clear History", destructive: true, icon: "trash.fill") { network.clearQualityHistory() })
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption2).foregroundStyle(.secondary); Text(value).font(.subheadline.monospacedDigit()) }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TrafficChart: View {
    @ObservedObject var tunnel: TunnelController
    var body: some View {
        AnyView(VStack(alignment: .leading, spacing: 10) {
            if tunnel.trafficPoints.count > 1 {
                Chart(tunnel.trafficPoints) { sample in
                    LineMark(x: .value("Time", sample.date), y: .value("Bytes/s", sample.received)).foregroundStyle(by: .value("Direction", "Download"))
                    LineMark(x: .value("Time", sample.date), y: .value("Bytes/s", sample.sent)).foregroundStyle(by: .value("Direction", "Upload"))
                }.chartForegroundStyleScale(["Download": Color.blue, "Upload": Color.mint]).chartYAxisLabel("Bytes / second").frame(height: 150)
                Text("Most recent 120 real counter samples. Sampled while the app is active.").font(.caption2).foregroundStyle(.secondary)
            } else { Text("Traffic chart appears after two tunnel counter samples.").font(.caption).foregroundStyle(.secondary) }
        })
    }
}


struct ProfileUsagePanel: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    var body: some View {
        AnyView(VStack(alignment: .leading, spacing: 12) {
            Label("Usage by profile", systemImage: "chart.bar").font(.headline)
            ForEach(store.profiles) { profile in
                let sessions = tunnel.history.filter { $0.profileID == profile.id }
                let received = sessions.reduce(0.0) { $0 + Double($1.received) }
                let sent = sessions.reduce(0.0) { $0 + Double($1.sent) }
                HStack {
                    VStack(alignment: .leading, spacing: 4) { Text(profile.name).font(.subheadline); Text("\(sessions.count) completed sessions").font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(min(Double(Int64.max - 1024), received + sent)), countStyle: .binary)).font(.caption.monospacedDigit())
                }
            }
            Text("Totals cover the most recent 100 saved sessions. Earlier sessions without a profile ID are excluded. These are WireGuard counters, not carrier billing usage.").font(.caption2).foregroundStyle(.secondary)
        })
    }
}


struct DNSProbeOptions: View {
    @ObservedObject var store: AppStore
    var body: some View {
        AnyView(DisclosureGroup("Advanced test options") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Domain to test", text: $store.probeDomain).textContentType(.URL).autocorrectionDisabled()
                Toggle("Expect NXDOMAIN", isOn: $store.expectNXDOMAIN)
                Text("For a domain you expect to be blocked. NXDOMAIN can also mean that a domain does not exist; provider filtering still needs independent verification.").font(.caption2).foregroundStyle(.secondary)
            }.padding(.top, 8).disabled(store.testing)
        }.font(.caption))
    }
}

/// "42.5 Mb/s" from bytes per second.
enum SpeedFormat {
    static func text(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond else { return "—" }
        let bits = bytesPerSecond * 8
        if bits >= 1_000_000_000 { return String(format: "%.2f Gb/s", bits / 1e9) }
        if bits >= 1_000_000 { return String(format: bits >= 100_000_000 ? "%.0f Mb/s" : "%.1f Mb/s", bits / 1e6) }
        return String(format: "%.0f Kb/s", bits / 1e3)
    }
}
