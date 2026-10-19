import AppKit
import SwiftUI

/// A panel that can take the keyboard even though it has no title bar.
private final class AlertPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Owns the decision window independently of the main dashboard. A paused
/// network flow must remain actionable even when the user is on another page,
/// another Space, or has closed the main window.
///
/// The card is built once and shows whichever question is first in line. It is never rebuilt or resized while macOS is laying it out:
/// replacing the window's content every time the waiting list changed crashed the layout engine.
@MainActor
final class ConnectionAlertController: NSObject, NSWindowDelegate {
    static let shared = ConnectionAlertController()

    private var panel: NSPanel?
    private weak var client: FilterClient?
    private var shownID: Int64?
    private var lastSize = CGSize.zero

    func sync(client: FilterClient) {
        self.client = client
        guard let question = client.pending.first else {
            panel?.orderOut(nil); shownID = nil
            return
        }
        if panel == nil { makePanel(client) }
        // A new question comes to the front; the same one that was set aside with "Decide later" stays away until the next one arrives.
        if shownID != question.id { panel?.orderFrontRegardless(); panel?.makeKey() }
        shownID = question.id
    }
    private func makePanel(_ client: FilterClient) {
        let hosting = NSHostingView(rootView: ConnectionAlertRoot(client: client, controller: self).preferredColorScheme(.dark))
        let panel = AlertPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 200), styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        self.panel = panel
        if let screen = NSScreen.main { panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 400, y: screen.visibleFrame.maxY - 230)) }
    }
    /// Called by the card when its height changes (a warning line, the options). Done on the next turn of the run loop, never during layout,
    /// and the top edge stays where it is.
    func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0, size != lastSize else { return }
        lastSize = size
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel else { return }
            let frame = panel.frame
            panel.setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
        }
    }

    func answer(_ question: PendingQuestion, allow: Bool, scope: AlertScope, lifetime: AlertLifetime) {
        client?.answer(question, allow: allow, scope: scope, lifetime: lifetime)
        DispatchQueue.main.async { [weak self] in
            guard let self, let client = self.client else { return }
            self.sync(client: client)
        }
    }
    /// Sets the card aside. The connection stays paused and is still listed on the Network page and in the menu bar.
    func decideLater() { panel?.orderOut(nil) }
}

/// The one view the panel hosts for good. It follows the waiting list and shows the first question.
private struct ConnectionAlertRoot: View {
    @ObservedObject var client: FilterClient
    let controller: ConnectionAlertController
    var body: some View {
        if let question = client.pending.first {
            ConnectionAlertPanel(question: question, client: client, controller: controller)
                .id(question.id)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { controller.resize(to: $0) }
        }
    }
}

private struct ConnectionAlertPanel: View {
    let question: PendingQuestion
    @ObservedObject var client: FilterClient
    let controller: ConnectionAlertController
    @AppStorage("alert-scope") private var scopeRaw = AlertScope.domain.rawValue
    @AppStorage("alert-lifetime") private var lifetimeRaw = AlertLifetime.once.rawValue
    @State private var showOptions = false
    /// A stray Return or Escape right as the card appears should not answer it, so keys are ignored for the first second.
    @State private var armed = false
    private var scope: AlertScope { AlertScope(rawValue: scopeRaw) ?? .domain }
    private var lifetime: AlertLifetime { AlertLifetime(rawValue: lifetimeRaw) ?? .once }

    private var icon: NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: question.app) { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSWorkspace.shared.icon(for: .unixExecutable)
    }
    private var country: GeoCountry? { GeoDatabase.shared.country(for: question.remoteAddress ?? question.host) }
    private func flag(_ code: String) -> String { code.uppercased().unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }.map(String.init).joined() }
    /// "UDP port 53 · 🇺🇸 United States · started by Terminal"
    private var detail: String {
        var parts = [question.proto + (question.port.isEmpty ? "" : " port " + question.port)]
        if let country { parts.append(flag(country.code) + " " + country.name) }
        if let parent = question.parent { parts.append("started by " + parent) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: icon).resizable().frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(question.appName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text("wants to connect to **\(question.host)**").font(.system(size: 13)).lineLimit(2).textSelection(.enabled)
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    if let warning = question.identity {
                        Text(warning == "Signer changed" ? "Signed by a different developer than before" : "Signature is not valid").font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
                    }
                }
            }

            HStack(spacing: 8) {
                Button { controller.answer(question, allow: false, scope: scope, lifetime: lifetime) } label: { Text("Block").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).tint(.red)
                Button { controller.answer(question, allow: true, scope: scope, lifetime: lifetime) } label: { Text("Allow").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(armed ? KeyboardShortcut.defaultAction : nil)
            }.controlSize(.large)

            if showOptions {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Applies to", selection: $scopeRaw) {
                        Text("\(question.appName), any destination").tag(AlertScope.app.rawValue)
                        Text("Anything at \(AlertRule.domain(of: question.host))").tag(AlertScope.domain.rawValue)
                        Text("Only \(question.host)").tag(AlertScope.host.rawValue)
                        if !question.port.isEmpty { Text("Only \(question.host):\(question.port)").tag(AlertScope.hostPort.rawValue) }
                    }
                    Picker("For", selection: $lifetimeRaw) { ForEach(AlertLifetime.allCases) { Text($0.title).tag($0.rawValue) } }
                }.font(.system(size: 12)).pickerStyle(.menu)
            }

            HStack(spacing: 10) {
                Button { withAnimation(.easeOut(duration: 0.15)) { showOptions.toggle() } } label: {
                    Label(showOptions ? "Fewer options" : "Options", systemImage: showOptions ? "chevron.up" : "chevron.down").labelStyle(.titleAndIcon)
                }
                if client.pending.count > 1 { Text("\(client.pending.count - 1) more waiting").foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                Button("Later") { controller.decideLater() }.keyboardShortcut(armed ? KeyboardShortcut.cancelAction : nil)
            }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 380)
        .fixedSize()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .task(id: question.id) { armed = false; try? await Task.sleep(for: .seconds(1)); armed = true }
        .accessibilityElement(children: .contain)
    }
}
