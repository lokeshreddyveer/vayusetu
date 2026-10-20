import Foundation
import Combine
import ServiceManagement
import SwiftUI

@MainActor final class DesktopPreferences: ObservableObject {
    @Published var connectOnLaunch: Bool { didSet { UserDefaults.standard.set(connectOnLaunch, forKey: "connect-on-launch") } }
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var message = ""
    init() { connectOnLaunch = UserDefaults.standard.bool(forKey: "connect-on-launch") }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            message = SMAppService.mainApp.status == .requiresApproval ? "Approve VayuSetu in System Settings → Login Items." : ""
        } catch { loginEnabled = SMAppService.mainApp.status == .enabled; message = "Could not change login registration. Install the app in /Applications and check Login Items." }
    }
}
struct MenuControls: View {
    @ObservedObject var store: AppStore
    @ObservedObject var extensions: ExtensionManager
    @ObservedObject var tunnel: TunnelController
    @ObservedObject var filter: FilterClient
    @Environment(\.openWindow) private var openWindow
    init(store: AppStore, extensions: ExtensionManager, filter: FilterClient) { self.store = store; self.extensions = extensions; self.filter = filter; self.tunnel = store.tunnel }
    var body: some View {
        Text("VayuSetu · \(tunnel.statusText)")
        Text(store.active?.name ?? "No VPN profile selected")
        Divider()
        Button(store.networkActive ? "Turn protection off" : "Turn protection on") {
            if store.networkActive { Task { _ = await store.powerTapped() } }
            else { extensions.activate { Task { if await store.powerTapped() { openWindow(id: "main"); NSApplication.shared.activate(ignoringOtherApps: true) } } } }
        }.disabled(!TunnelController.available || !tunnel.ready || extensions.requesting || store.protectionBusy)
        Divider()
        Toggle(isOn: Binding(get: { store.vpnPill == .active || store.vpnPill == .pending }, set: { _ in extensions.activate { Task { await store.togglePill(.vpn) } } })) { Label("VPN", systemImage: "lock.shield") }.disabled(!TunnelController.available || !tunnel.ready || extensions.requesting)
        Toggle(isOn: Binding(get: { store.dnsPill == .active || store.dnsPill == .pending }, set: { _ in extensions.activate { Task { await store.togglePill(.dns) } } })) { Label("Encrypted DNS", systemImage: "network") }.disabled(!TunnelController.available || !tunnel.ready || extensions.requesting)
        Toggle(isOn: Binding(get: { store.adblockPill == .active || store.adblockPill == .pending }, set: { _ in Task { await store.togglePill(.adblock) } })) { Label("Adblock in Safari", systemImage: "hand.raised") }
        Divider()
        networkSection
        Divider()
        Button("Open VayuSetu") { openWindow(id: "main"); NSApplication.shared.activate(ignoringOtherApps: true) }
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }
    /// The network filter at a glance: what happened in the last minute, the latest blocks, and quick mode changes.
    @ViewBuilder private var networkSection: some View {
        if filter.status == .running {
            let minute = filter.flows.filter { $0.time > Date().addingTimeInterval(-60) }
            let blocked = minute.filter { $0.verdict == .block }.count
            let received = minute.reduce(Int64(0)) { $0 + ($1.bytesIn ?? 0) }
            let sent = minute.reduce(Int64(0)) { $0 + ($1.bytesOut ?? 0) }
            Label("Speed · ↓ (Self.rate(received / 60)) · ↑ (Self.rate(sent / 60))", systemImage: "arrow.up.arrow.down.circle")
            Text("Network filter · \(filter.settings.mode.title) · \(minute.count - blocked) allowed, \(blocked) blocked in the last minute")
            if !filter.pending.isEmpty { Button("\(filter.pending.count) connection\(filter.pending.count == 1 ? "" : "s") waiting for you…") { openWindow(id: "main"); NSApplication.shared.activate(ignoringOtherApps: true) } }
            ForEach(Array(filter.flows.filter { $0.verdict == .block }.suffix(5).reversed()), id: \.id) { flow in
                Text("Blocked: \(flow.appName) → \(flow.host)")
            }
            Menu("Filter mode") {
                ForEach(FilterMode.allCases) { mode in Button((filter.settings.mode == mode ? "✓ " : "") + mode.title) { filter.setMode(mode) } }
            }
            if !filter.profiles.isEmpty {
                Menu("Network profile") { ForEach(filter.profiles) { profile in Button((filter.activeProfile == profile.name ? "✓ " : "") + profile.name) { filter.applyProfile(named: profile.name) } } }
            }
        } else {
            Text("Network filter · \(filter.status == .off ? "off" : "not running")")
        }
    }
    private static func rate(_ bytesPerSecond: Int64) -> String {
        let value = Double(max(0, bytesPerSecond))
        if value >= 1_000_000 { return String(format: "%.1f MB/s", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1f KB/s", value / 1_000) }
        return "(Int(value)) B/s"
    }
}

import Darwin

/// Writes a short trace to ~/Library/Logs/VayuSetu/ when the app crashes, because macOS does not always keep a report. The trace has function
/// names and no personal data. Nothing is sent anywhere.
enum CrashTrace {
    nonisolated(unsafe) private static var descriptor: Int32 = -1
    nonisolated(unsafe) private static var stack = [UInt8](repeating: 0, count: 256 * 1024)
    static func install() {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/VayuSetu", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "crash-" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + ".txt"
        descriptor = open(folder.appendingPathComponent(name).path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        // A handler needs its own stack to run after a stack overflow.
        stack.withUnsafeMutableBytes { raw in
            var alt = stack_t(ss_sp: raw.baseAddress, ss_size: raw.count, ss_flags: 0)
            sigaltstack(&alt, nil)
        }
        for signalNumber in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE] {
            var action = sigaction()
            action.__sigaction_u.__sa_sigaction = { number, _, _ in
                let header = "VayuSetu crashed, signal \(number)\n"
                _ = header.withCString { write(CrashTrace.descriptor, $0, strlen($0)) }
                var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
                let count = backtrace(&frames, 64)
                backtrace_symbols_fd(&frames, count, CrashTrace.descriptor)
                signal(number, SIG_DFL); raise(number)
            }
            action.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_RESETHAND
            sigemptyset(&action.sa_mask)
            sigaction(signalNumber, &action, nil)
        }
        NSSetUncaughtExceptionHandler { exception in
            let text = "Uncaught exception: \(exception.name.rawValue) \(exception.reason ?? "")\n" + exception.callStackSymbols.joined(separator: "\n") + "\n"
            _ = text.withCString { write(CrashTrace.descriptor, $0, strlen($0)) }
        }
        // An empty file means no crash happened; remove earlier empty ones and keep the last ten traces.
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey])) ?? []).filter { $0.lastPathComponent.hasPrefix("crash-") }
        for file in files where file.lastPathComponent != name && ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) == 0 { try? FileManager.default.removeItem(at: file) }
    }
}
