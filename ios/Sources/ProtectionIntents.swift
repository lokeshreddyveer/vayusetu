import AppIntents
import Foundation
import WidgetKit

// The intents and the request queue are shared with the widget extension: Extensions/LiveActivity/ProtectionShared.swift.

struct VayuSetuShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TurnOnDNSOnlyIntent(), phrases: ["Turn on DNS in \(.applicationName)", "Start \(.applicationName) DNS"], shortTitle: "DNS Only", systemImageName: "network")
        AppShortcut(intent: TurnOnVPNIntent(), phrases: ["Connect \(.applicationName)", "Turn on VPN in \(.applicationName)"], shortTitle: "Connect VPN", systemImageName: "shield.lefthalf.filled")
        AppShortcut(intent: TurnOffProtectionIntent(), phrases: ["Turn off \(.applicationName)", "Disconnect \(.applicationName)"], shortTitle: "Turn Off", systemImageName: "power")
        AppShortcut(intent: TurnOnAdblockIntent(), phrases: ["Turn on ad blocking in \(.applicationName)"], shortTitle: "Ad Blocking On", systemImageName: "hand.raised.slash")
        AppShortcut(intent: TurnOffAdblockIntent(), phrases: ["Turn off ad blocking in \(.applicationName)"], shortTitle: "Ad Blocking Off", systemImageName: "hand.raised")
    }
}

extension AppStore {
    /// Carries out a request that arrived from outside the app, through the same planner every button uses.
    func perform(_ action: ProtectionShortcut) async {
        var next = observedSelection
        switch action {
        case .dnsOnly: next.vpnEnabled = false; next.dnsEnabled = true
        case .vpnOn: next.vpnEnabled = true
        case .networkOff: next.vpnEnabled = false; next.dnsEnabled = false
        case .adblockOn: next.safariAdblockEnabled = true
        case .adblockOff: next.safariAdblockEnabled = false
        }
        protectionNotice = await applySelection(next, confirmed: action == .networkOff)
    }
    /// Tells the Home Screen widget what is on, and only reloads it when that changed.
    func publishWidgetStatus() {
        let status = WidgetStatus(mode: observedMode.title, vpn: vpnPill == .active, dns: dnsPill == .active, adblock: adblockPill == .active, profile: connectionName)
        var old = WidgetStatus.read(); old.updated = status.updated
        guard old != status else { return }
        status.write(); WidgetCenter.shared.reloadAllTimelines()
    }
}
