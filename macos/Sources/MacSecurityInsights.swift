import SwiftUI
import VayuSetuCore

struct MacSecurityInsights: View {
    @ObservedObject var filter: FilterClient
    @State private var report = BehaviorReport(connections: 0, applications: 0, destinations: 0, blocked: 0, bytes: 0, insights: [])
    @State private var updated = Date()
    private var connections: [BehaviorConnection] {
        filter.flows.map { flow in BehaviorConnection(app: flow.appName.isEmpty ? flow.app : flow.appName, host: flow.host, team: flow.team, parent: flow.parent, verdict: flow.verdict.rawValue, time: flow.time, bytes: (flow.bytesIn ?? 0) + (flow.bytesOut ?? 0)) }
    }
    var body: some View {
        MacPage(title: "Security Center", subtitle: "Local behavior insights and explainable network evidence.") {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    metric("Connections", "\(report.connections)", "waveform.path.ecg")
                    metric("Apps", "\(report.applications)", "app.badge")
                    metric("Destinations", "\(report.destinations)", "globe")
                    metric("Blocked", "\(report.blocked)", "hand.raised")
                }
                MacPanel("Behavior review", icon: "sparkles") {
                    VStack(alignment: .leading, spacing: 10) {
                        if report.insights.isEmpty { Text("No local insights yet.").foregroundStyle(.secondary) }
                        ForEach(report.insights) { insight in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: insight.severity == .high ? "exclamationmark.octagon.fill" : insight.severity == .attention ? "exclamationmark.triangle.fill" : "info.circle.fill").foregroundStyle(insight.severity == .high ? .red : insight.severity == .attention ? .orange : .secondary)
                                VStack(alignment: .leading, spacing: 2) { Text(insight.title).font(.system(size: 13, weight: .semibold)); Text(insight.detail).font(.system(size: 12)).foregroundStyle(.secondary) }
                            }
                        }
                        Button("Re-analyze current evidence") { recompute() }.buttonStyle(MacHoverButtonStyle(prominent: true))
                        Text("This is local metadata analysis. It does not inspect payloads, decrypt traffic, or claim to detect every threat.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                MacPanel("Decision model", icon: "list.bullet.rectangle") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Use the Network view to inspect the exact rule, list, signer, parent process, destination, and map location behind each decision.").font(.system(size: 12))
                        Button("Open Network connections") { NotificationCenter.default.post(name: .init("VayuSetu.openNetwork"), object: nil) }.buttonStyle(MacHoverButtonStyle())
                        Text("Last analyzed \(updated.formatted(date: .abbreviated, time: .shortened)) · \(report.bytes) observed bytes").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }.onAppear { recompute() }.onChange(of: filter.flows) { _, _ in recompute() }
    }
    private func recompute() { report = BehaviorAnalyzer.report(connections); updated = Date() }
    private func metric(_ title: String, _ value: String, _ icon: String) -> some View { MacPanel(title, icon: icon) { Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit() }.frame(maxWidth: .infinity) }
}
