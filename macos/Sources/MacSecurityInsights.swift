import AppKit
import SwiftUI
import VayuSetuCore

/// The Security Center: what the network filter has seen, in order of what is worth your attention. Everything on it is built from the
/// connections the filter recorded (app, destination, signer, parent process, verdict, time). It never looks inside traffic, and it does not
/// claim to find every threat.
struct MacSecurityInsights: View {
    @ObservedObject var filter: FilterClient
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    @Environment(\.extensionManager) private var extensions
    @State private var digest = SecurityDigestBuilder.build([])
    @State private var updated = Date()

    private var flows: [DigestFlow] {
        filter.flows.map { DigestFlow(app: $0.app, appName: $0.appName.isEmpty ? $0.app : $0.appName, host: $0.host, blocked: $0.verdict == .block, time: $0.time, team: $0.team, identity: $0.identity, parent: $0.parent) }
    }
    private var filterRunning: Bool { filter.status == .running }

    var body: some View {
        MacPage(title: "Security Center", subtitle: "What your Mac has been connecting to, and what deserves a look.") {
            if !filterRunning { filterOff }
            healthRow
            MacPanelLayout(minimumColumnWidth: 460) {
                findingsPanel
                MacRadarScene(blockedDestinations: digest.blockedDestinations, blocked: digest.blocked, connections: digest.connections)
                appsPanel
                blockedPanel
                trustPanel
                MacDNSBypassPanel(flows: filter.flows)
                MacFirstSeenPanel(store: FirstSeenStore.shared)
            }
            auditPanel
        }
        .onAppear { recompute() }
        .onChange(of: filter.flows.count) { _, _ in recompute() }
    }

    // MARK: Top
    private var filterOff: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.shield").foregroundStyle(.orange).font(.system(size: 18))
            VStack(alignment: .leading, spacing: 4) {
                Text(filter.status == .off ? "The network filter is off" : "The network filter is not answering").font(.system(size: 13, weight: .semibold))
                Text("Without it, this page has nothing to show. Turn it on from the Network page" + (filter.status == .unreachable ? ", or restart it here." : ".")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if filter.status == .unreachable { Button("Restart the filter") { filter.repairNow() }.buttonStyle(MacHoverButtonStyle(prominent: true)) }
            Button("Open Network") { NotificationCenter.default.post(name: .init("VayuSetu.openNetwork"), object: nil) }.buttonStyle(MacHoverButtonStyle())
        }.padding(14).background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    private var healthRow: some View {
        MacWrap(spacing: 12, lineSpacing: 12) {
            metric("Connections", "\(digest.connections)", "waveform.path.ecg", .primary)
            metric("Apps", "\(digest.apps.count)", "app.badge", .primary)
            metric("Blocked", "\(digest.blocked)", "hand.raised.fill", digest.blocked > 0 ? .red : .primary, note: digest.connections == 0 ? nil : String(format: "%.0f%% of all", digest.blockedShare * 100))
            metric("Waiting", "\(filter.pending.count)", "questionmark.circle", filter.pending.isEmpty ? .primary : .orange)
            metric("Needs a look", "\(digest.findings.filter { $0.severity != .info }.count)", "exclamationmark.triangle", digest.findings.contains { $0.severity == .high } ? .red : digest.findings.contains { $0.severity == .attention } ? .orange : .green)
        }
    }
    private func metric(_ title: String, _ value: String, _ icon: String, _ tint: Color, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(tint)
            if let note { Text(note).font(.system(size: 10)).foregroundStyle(.secondary) }
        }
        .padding(14).frame(width: 150, alignment: .leading).macPanel()
    }

    // MARK: Findings
    private var findingsPanel: some View {
        MacPanel("Worth a look", icon: "sparkles", trailing: { Text("updated " + updated.formatted(date: .omitted, time: .shortened)).font(.system(size: 11)).foregroundStyle(.secondary) }) {
            VStack(alignment: .leading, spacing: 12) {
                if digest.findings.isEmpty {
                    Label(digest.connections == 0 ? "Nothing recorded yet. Use your Mac normally and this fills in." : "Nothing stands out in the connections recorded so far.", systemImage: digest.connections == 0 ? "clock" : "checkmark.circle").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(digest.findings) { finding in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: finding.severity == .high ? "exclamationmark.octagon.fill" : finding.severity == .attention ? "exclamationmark.triangle.fill" : "info.circle.fill")
                            .foregroundStyle(finding.severity == .high ? Color.red : finding.severity == .attention ? Color.orange : Color.blue).frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(finding.title).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                            Text(finding.detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if let app = finding.app, finding.severity != .info {
                                HStack(spacing: 8) {
                                    Button("Block this app") { filter.addRule(NetRule(app: app, host: "*", port: "*", action: .block, note: "From the Security Center")) }.buttonStyle(MacHoverButtonStyle())
                                    Button("See its connections") { filter.focusApp = app; NotificationCenter.default.post(name: .init("VayuSetu.openNetwork"), object: nil) }.buttonStyle(MacHoverButtonStyle())
                                }.padding(.top, 2)
                            }
                        }
                    }
                    if finding.id != digest.findings.last?.id { Divider() }
                }
                Text("Built from connection details only: app, destination, signer, who started it, and the verdict. Not from what was sent.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Apps and destinations
    private var appsPanel: some View {
        MacPanel("Apps by connections", icon: "app.badge", trailing: { Text("\(digest.apps.count) seen").font(.system(size: 11)).foregroundStyle(.secondary) }) {
            VStack(alignment: .leading, spacing: 8) {
                if digest.apps.isEmpty { Text("No apps recorded yet.").font(.system(size: 12)).foregroundStyle(.secondary) }
                let top = Array(digest.apps.prefix(8)); let peak = max(1, top.first?.connections ?? 1)
                ForEach(top) { app in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack { Text(app.name).font(.system(size: 12, weight: .medium)).lineLimit(1); Spacer(minLength: 6)
                            Text("\(app.connections)").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                            if app.blocked > 0 { MacChip(text: "\(app.blocked) blocked", tint: .red) } }
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.07))
                                Capsule().fill(Color.accentColor.opacity(0.65)).frame(width: max(4, g.size.width * CGFloat(app.connections) / CGFloat(peak)))
                            }
                        }.frame(height: 5)
                        Text("\(app.destinations) destination\(app.destinations == 1 ? "" : "s")").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    private var blockedPanel: some View {
        MacPanel("Most blocked destinations", icon: "hand.raised.fill") {
            VStack(alignment: .leading, spacing: 8) {
                if digest.blockedDestinations.isEmpty { Text("Nothing has been blocked yet.").font(.system(size: 12)).foregroundStyle(.secondary) }
                ForEach(Array(digest.blockedDestinations.prefix(8))) { destination in
                    HStack {
                        Text(destination.host).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Spacer(minLength: 6)
                        Text("\(destination.count)× · \(destination.apps) app\(destination.apps == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: How decisions are made
    private var trustPanel: some View {
        MacPanel("Your protection", icon: "checkmark.shield") {
            VStack(alignment: .leading, spacing: 10) {
                stateRow("Network filter", filterRunning ? "Running" : filter.status == .off ? "Off" : "Not answering", filterRunning ? .green : .orange)
                stateRow("Mode", filter.settings.mode.title, .secondary)
                stateRow("Rules", "\(filter.rules.count) · \(filter.rules.filter { $0.action == .block }.count) block", .secondary)
                stateRow("Lists", filter.lists.isEmpty ? "None" : "\(filter.lists.filter(\.enabled).count) of \(filter.lists.count) on", .secondary)
                stateRow("Apple-signed software", filter.settings.allowAppleSigned ? "Allowed without asking" : "Asked like any other", .secondary)
                stateRow("Audit trail", filter.audit.isEmpty ? "Empty" : filter.auditChainValid ? "Intact" : "Does not verify", filter.audit.isEmpty ? .secondary : filter.auditChainValid ? .green : .red)
                Button("Open Network") { NotificationCenter.default.post(name: .init("VayuSetu.openNetwork"), object: nil) }.buttonStyle(MacHoverButtonStyle())
            }
        }
    }
    private func stateRow(_ title: String, _ value: String, _ tint: Color) -> some View {
        HStack { Text(title).font(.system(size: 12)).foregroundStyle(.secondary); Spacer(minLength: 8); Text(value).font(.system(size: 12, weight: .medium)).foregroundStyle(tint) }
    }

    // MARK: Audit
    private var auditPanel: some View {
        MacPanel("Changes to your rules", icon: "list.bullet.rectangle", trailing: {
            MacChip(text: filter.audit.isEmpty ? "No entries" : filter.auditChainValid ? "Chain intact" : "Chain broken", tint: filter.audit.isEmpty ? .secondary : filter.auditChainValid ? .green : .red)
        }) {
            VStack(alignment: .leading, spacing: 6) {
                if filter.audit.isEmpty { Text("Every change to rules, lists and settings is written here, with each entry linked to the one before so that an edit made behind VayuSetu's back shows up.").font(.system(size: 12)).foregroundStyle(.secondary) }
                ForEach(Array(filter.audit.suffix(12).reversed())) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        Text(entry.time.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).frame(width: 118, alignment: .leading)
                        Text(entry.actor).font(.system(size: 11, weight: .medium)).frame(width: 40, alignment: .leading)
                        Text(entry.action + (entry.detail.isEmpty ? "" : " · " + entry.detail)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        }
    }

    private func recompute() { digest = SecurityDigestBuilder.build(flows); updated = Date() }
}
