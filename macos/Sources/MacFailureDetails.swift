import AppKit
import SwiftUI
import VayuSetuCore

/// What went wrong, in plain words, with the details a person (or a bug report) needs, and one button to copy them. It contains only
/// VayuSetu's own fixed messages, version numbers and the mode in use. It never contains keys, addresses, profile names or resolver names.
struct MacFailureDetails: View {
    @ObservedObject var tunnel: TunnelController
    @ObservedObject var store: AppStore
    @Environment(\.extensionManager) private var extensions
    @State private var open = false
    @State private var copied = false

    private var failing: Bool { tunnel.stage == .failed || (!tunnel.message.isEmpty && !tunnel.running) }

    var body: some View {
        if failing {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("The connection did not start").font(.system(size: 13, weight: .semibold))
                        if let advice = FailureAdvice.plain(tunnel.message) {
                            Text(advice.happened).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                            Text(advice.todo).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(tunnel.message.isEmpty ? "The tunnel stopped before it was ready." : tunnel.message).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 8)
                    Button(open ? "Hide details" : "Details") { open.toggle() }.buttonStyle(MacHoverButtonStyle())
                }
                if open {
                    Text(report).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    HStack {
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(report, forType: .string); copied = true } label: { Label(copied ? "Copied" : "Copy details", systemImage: "doc.on.doc") }.buttonStyle(MacHoverButtonStyle())
                        Text("Nothing here contains your keys, server or resolver names.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }.padding(14).background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    /// Plain text for a bug report.
    var report: String {
        var lines: [String] = []
        let info = ProcessInfo.processInfo
        lines.append("VayuSetu \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
        lines.append("macOS \(info.operatingSystemVersionString)")
        for component in extensions?.components ?? [] { lines.append("\(component.name): \(component.summary)") }
        lines.append("Stage: \(tunnel.stage) · status: \(tunnel.status.rawValue) · protocol: \(tunnel.protocolName)")
        lines.append("Switches: VPN \(store.vpnPill) · DNS \(store.dnsPill) · Adblock \(store.adblockPill)")
        lines.append("")
        lines.append("Recent events (newest first):")
        lines.append(contentsOf: tunnel.events.prefix(14).map { "  " + $0 })
        return lines.joined(separator: "\n")
    }
}
