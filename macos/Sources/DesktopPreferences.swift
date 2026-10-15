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
    @Environment(\.openWindow) private var openWindow
    init(store: AppStore, extensions: ExtensionManager) { self.store = store; self.extensions = extensions; self.tunnel = store.tunnel }
    var body: some View {
        Text("VayuSetu · \(tunnel.statusText)")
        Text(store.active?.name ?? "No VPN profile selected")
        Divider()
        Button(store.networkActive ? "Turn protection off" : "Turn protection on") {
            if store.networkActive { Task { _ = await store.powerTapped() } }
            else { extensions.activate { Task { if await store.powerTapped() { openWindow(id: "main"); NSApplication.shared.activate(ignoringOtherApps: true) } } } }
        }.disabled(!TunnelController.available || !tunnel.ready || extensions.requesting || store.protectionBusy)
        Divider()
        Toggle("VPN", isOn: Binding(get: { store.vpnPill == .active || store.vpnPill == .pending }, set: { _ in extensions.activate { Task { await store.togglePill(.vpn) } } })).disabled(!TunnelController.available || !tunnel.ready || extensions.requesting)
        Toggle("Encrypted DNS", isOn: Binding(get: { store.dnsPill == .active || store.dnsPill == .pending }, set: { _ in extensions.activate { Task { await store.togglePill(.dns) } } })).disabled(!TunnelController.available || !tunnel.ready || extensions.requesting)
        Toggle("Adblock in Safari", isOn: Binding(get: { store.adblockPill == .active || store.adblockPill == .pending }, set: { _ in Task { await store.togglePill(.adblock) } }))
        Divider()
        Button("Open VayuSetu") { openWindow(id: "main"); NSApplication.shared.activate(ignoringOtherApps: true) }
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }
}
