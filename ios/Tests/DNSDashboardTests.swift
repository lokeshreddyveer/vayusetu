import Foundation

@main struct DNSDashboardTests {
    static var count = 0
    static func check(_ condition: Bool, _ line: Int = #line) { if !condition { fatalError("DNSDashboardTests failed at line \(line)") }; count += 1 }
    static func model(_ input: DNSDashboardInput) -> DNSDashboardModel { DNSDashboardModel.make(input) }

    static func main() {
        // Always exactly three tiles, in a fixed order, so every row renders identically
        for level in [DNSLevel.off, .active, .pending, .limited, .failed] {
            let m = model(.init(level: level, resolverName: "Control D"))
            check(m.tiles.map(\.id) == ["encrypted", "filtering", "private"])
        }
        // Off
        let off = model(.init(level: .off))
        check(off.status.title == "INACTIVE" && off.status.tone == .neutral && off.status.line == "Using system or network-provided DNS")
        check(model(.init(level: .off, vpnRunning: true)).status.line == "Using the VPN profile’s own DNS")
        check(off.tiles[0].value == "Not active" && off.tiles[1].value == "Disabled")
        // Connecting and pending are different
        let connecting = model(.init(level: .pending, connecting: true))
        check(connecting.status.title == "CONNECTING" && connecting.status.showsProgress)
        let pending = model(.init(level: .pending, failedCheckDetail: "A normal name did not resolve."))
        check(pending.status.title == "VERIFICATION PENDING" && !pending.status.showsProgress && pending.status.detail == "A normal name did not resolve.")
        check(pending.tiles[0].value == "Not verified" && pending.tiles[0].tone == .caution)
        // Active VayuSetu DNS with loaded rules
        let active = model(.init(level: .active, resolverName: "VayuSetu DNS", transport: .doh, localListsSelected: true, loadedRules: 28_000))
        check(active.status.title == "ACTIVE" && active.status.tone == .good && active.status.line == "VayuSetu DNS · Encrypted (DoH)")
        check(active.status.detail == "Filtering: 28000 rules · apps using system DNS")
        check(active.tiles[0].value == "DNS-over-HTTPS" && active.tiles[1].value == "Enabled" && active.tiles[1].tone == .good)
        // No rules loaded is never shown as enabled filtering
        let empty = model(.init(level: .active, resolverName: "VayuSetu DNS", localListsSelected: true, loadedRules: 0))
        check(empty.tiles[1].value == "No rules loaded" && empty.tiles[1].tone == .caution && empty.status.detail?.hasPrefix("No filter rules loaded") == true)
        check(model(.init(level: .active, localListsSelected: true, loadedRules: nil)).tiles[1].value == "Verification pending")   // not reported yet is not zero rules
        check(model(.init(level: .active, localListsSelected: true, loadedRules: nil)).status.detail == "Filtering: rule count not reported yet · apps using system DNS")
        // A custom resolver: filtering is the provider's, not VayuSetu's
        let custom = model(.init(level: .active, resolverName: "Control D", transport: .dot))
        check(custom.status.line == "Control D · Encrypted (DoT)" && custom.tiles[0].value == "DNS-over-TLS")
        check(custom.tiles[1].value == "Resolver-side" && custom.tiles[1].tone == .caution && custom.status.detail == "Filtering: resolver-side only · apps using system DNS")
        // IKEv2: limited and unsupported, never active
        let ike = model(.init(level: .limited, onIKEv2: true, vpnRunning: true, resolverName: "Control D", localListsSelected: true, loadedRules: 100))
        check(ike.status.title == "LIMITED" && ike.status.line == "The active VPN does not support the selected DNS enforcement method.")
        check(ike.tiles[1].value == "Unsupported" && ike.tiles[1].tone == .bad)
        // Failure shows the coordinator's reason
        let failed = model(.init(level: .failed, reason: "The tunnel did not start."))
        check(failed.status.tone == .bad && failed.status.line == "DNS is not working as expected." && failed.status.detail == "The tunnel did not start.")
        // No resolver chosen
        check(model(.init(level: .off, hasResolver: false)).tiles[0].value == "No resolver")
        // The privacy tile never claims a third-party "no logs" policy
        check(model(.init(level: .active, resolverName: "Control D")).tiles[2].value == "No local query log")
        print("DNS dashboard model checks passed: \(count)")
    }
}
