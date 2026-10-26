import Foundation
import SwiftUI
import VayuSetuCore

/// Notices when something other than VayuSetu takes over this Mac's DNS or routing while VayuSetu says it is protecting: another VPN or app that
/// puts its own resolver ahead of VayuSetu's, a profile that removes it, or a VPN whose traffic no longer goes through the tunnel.
/// It reads the system's resolver list and default route (nothing is sent anywhere, nothing is changed), and only while protection is on.
/// It reports; it does not repair, because undoing another app's change could break that app.
@MainActor final class TamperMonitor: ObservableObject {
    static let shared = TamperMonitor()
    @Published private(set) var verdict: TamperVerdict = .intact
    private var task: Task<Void, Never>?
    private var previous: TamperVerdict?
    private var alerted: TamperVerdict?
    /// "Tell me if something changes my DNS": on unless switched off in Settings.
    var alertsOn: Bool { UserDefaults.standard.object(forKey: "tamper-alerts") as? Bool ?? true }

    func start(store: AppStore, tunnel: TunnelController) {
        guard task == nil else { return }
        task = Task { [weak self, weak store, weak tunnel] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, let store, let tunnel else { return }
                await self.check(store: store, tunnel: tunnel)
            }
        }
    }

    private func check(store: AppStore, tunnel: TunnelController) async {
        // Only while VayuSetu is connected and settled. During a start, stop or reconnect the lists are expected to change.
        guard alertsOn, tunnel.status == .connected, !tunnel.busy, !store.protectionBusy else { reset(); return }
        let ourDNS = tunnel.localDNSRunning || (store.dnsPill != .off && store.isVayuSetuDNSSelected)
        // Only a full tunnel sends the default route through the VPN; a split tunnel is not expected to.
        let fullTunnel = tunnel.stats?.appliedPolicy?.ipv4Default == true
        let ourVPN = !tunnel.localDNSRunning && fullTunnel
        guard ourDNS || ourVPN else { reset(); return }
        async let list = NetLab.run("/usr/sbin/scutil", ["--dns"], timeout: 4)
        async let route = NetLab.run("/sbin/route", ["-n", "get", "default"], timeout: 4)
        let (dns, routeText) = await (list, route)
        let iface = routeText.split(separator: "\n").first { $0.contains("interface:") }.map { $0.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "" }
        let now = TamperMonitor.assess(dnsText: dns, routeInterface: iface, dnsExpected: ourDNS, vpnExpected: ourVPN)
        if TamperWatch.shouldAlert(previous: previous, current: now, alreadyAlerted: alerted), let message = now.message {
            alerted = now
            tunnel.record(message, severity: .warning, category: "protection")
            AlertNotifier.post(id: "tamper", title: "Your protection may be bypassed", body: message)
        }
        if now == .intact { alerted = nil }
        previous = now; verdict = now
    }

    nonisolated static func assess(dnsText: String, routeInterface: String?, dnsExpected: Bool, vpnExpected: Bool) -> TamperVerdict {
        TamperWatch.assess(resolvers: SystemResolverParser.parse(dnsText), ourServer: LocalDNSProbe.virtualServer, dnsExpected: dnsExpected, vpnExpected: vpnExpected,
                                        defaultInterface: routeInterface?.isEmpty == false ? routeInterface : nil)
    }
    private func reset() { previous = nil; alerted = nil; if verdict != .intact { verdict = .intact } }
}
