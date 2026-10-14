import Foundation

@main struct ProfilesDashboardTests {
    static var count = 0
    static func check(_ condition: Bool, _ line: Int = #line) { if !condition { fatalError("ProfilesDashboardTests failed at line \(line)") }; count += 1 }
    static func row(_ kind: VPNKind, selected: Bool = false, link: ProfileLinkState = .off, lastUsed: Date? = nil) -> ProfileRowModel {
        ProfilesModel.row(ProfileRowInput(id: UUID(), name: "n", kind: kind, selected: selected, link: link, lastUsed: lastUsed))
    }

    static func main() {
        // DNS capability lines come from the real adapter abilities
        check(ProfilesModel.dnsLine(.wireGuard) == "DNS: your resolver and VayuSetu lists")
        check(ProfilesModel.dnsLine(.ikev2) == "DNS: set by the VPN server")
        check(ProfilesModel.dnsLine(.openVPN) == "Not available yet")
        check(row(.openVPN).isUsable == false && row(.wireGuard).isUsable && row(.ikev2).isUsable)

        // Selected is not connected
        let selected = row(.wireGuard, selected: true)
        check(selected.status == .selected && selected.isSelected && !selected.isActive)
        // Connected / connecting / failed come only from the observed link
        check(row(.ikev2, selected: true, link: .connected).status == .connected && row(.ikev2, selected: true, link: .connected).isActive)
        check(row(.ikev2, link: .connecting).status == .connecting && row(.ikev2, link: .connecting).isActive)
        check(row(.wireGuard, link: .disconnecting).status == .disconnecting && !row(.wireGuard, link: .disconnecting).isActive)
        check(row(.wireGuard, selected: true, link: .failed).status == .failed)
        // Measured information only
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        check(row(.wireGuard, lastUsed: date).status == .lastUsed(date) && row(.wireGuard).status == .neverUsed)
        check(row(.wireGuard, selected: true, lastUsed: date).status == .selected)     // selection wins over history
        check(row(.wireGuard).protocolName == "WireGuard" && row(.ikev2).protocolName == "IKEv2")

        // Connection summary
        let connected = ConnectionSummaryModel.make(.init(link: .connected, runningName: "us-den", runningKind: .wireGuard, selectedName: "us-den", selectedKind: .wireGuard))
        check(connected.stateLabel == "CONNECTED" && connected.tone == .good && connected.action == .disconnect && connected.detail == "WireGuard · remote VPN connection")
        let connecting = ConnectionSummaryModel.make(.init(link: .connecting, runningName: "Fast", runningKind: .ikev2))
        check(connecting.action == .cancel && connecting.showsProgress && connecting.tone == .caution)
        check(ConnectionSummaryModel.make(.init(link: .disconnecting, runningName: "Fast")).action == .none)
        let failed = ConnectionSummaryModel.make(.init(link: .failed, selectedName: "Fast", selectedKind: .ikev2))
        check(failed.tone == .bad && failed.action == .connect && failed.actionTitle == "Retry")
        check(ConnectionSummaryModel.make(.init(link: .failed)).action == .none)      // nothing to retry
        // Not connected, but selected: says so and never claims a connection
        let idle = ConnectionSummaryModel.make(.init(link: .off, selectedName: "us-den", selectedKind: .wireGuard))
        check(idle.stateLabel == "NOT CONNECTED" && idle.tone == .neutral && idle.action == .connect && idle.detail == "WireGuard · selected, not connected")
        // DNS Only is clearly not a remote VPN
        let dnsOnly = ConnectionSummaryModel.make(.init(link: .off, selectedName: "us-den", selectedKind: .wireGuard, localDNSRunning: true))
        check(dnsOnly.stateLabel == "REMOTE VPN OFF" && dnsOnly.headline == "DNS Only is running" && dnsOnly.tone == .neutral && dnsOnly.action == .connect)
        check(ConnectionSummaryModel.make(.init(link: .off, localDNSRunning: true)).action == .none)
        // No profile selected
        let none = ConnectionSummaryModel.make(.init(link: .off))
        check(none.stateLabel == "NO VPN PROFILE SELECTED" && none.action == .none)
        print("Profiles dashboard model checks passed: \(count)")
    }
}
