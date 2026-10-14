import ActivityKit
import Foundation

/// What is switched on right now, as far as the system confirms it.
struct ActivitySnapshot: Equatable {
    var vpn: Bool
    var dnsOnly: Bool
    var adblock: Bool
}

/// The Dynamic Island and Lock Screen announce what just happened: "VPN connected", "VPN disconnected", "DNS-only connected",
/// "Adblock activated". Each message stays for a few seconds and then goes away; nothing is shown in between.
///
/// iOS lets an app start a Live Activity only while it is on screen, so a change that happens while VayuSetu is in the background is not announced.
@MainActor final class ConnectionActivityController: ObservableObject {
    typealias State = ConnectionActivityAttributes.ContentState
    private var last: ActivitySnapshot?
    private var pending: [State] = []
    private var showing: Task<Void, Never>?
    private var canStart = false
    private var enabled = false

    func observe(_ now: ActivitySnapshot, enabled: Bool, canStart: Bool) {
        self.enabled = enabled; self.canStart = canStart
        defer { last = now }
        guard enabled else { pending = []; showing?.cancel(); showing = nil; end(); return }
        guard let before = last, before != now else { return }
        if before.vpn != now.vpn { pending.append(now.vpn ? State(title: "VPN connected", detail: "Your traffic is protected", short: "On", symbol: "lock.shield.fill", tone: .on) : State(title: "VPN disconnected", detail: "Your traffic is no longer tunnelled", short: "Off", symbol: "lock.open.fill", tone: .off)) }
        if before.dnsOnly != now.dnsOnly { pending.append(now.dnsOnly ? State(title: "DNS-only connected", detail: "Encrypted DNS is on", short: "DNS", symbol: "network.badge.shield.half.filled", tone: .on) : State(title: "DNS-only disconnected", detail: "Encrypted DNS is off", short: "Off", symbol: "network.slash", tone: .off)) }
        if before.adblock != now.adblock { pending.append(now.adblock ? State(title: "Adblock activated", detail: "Safari is blocking ads and trackers", short: "On", symbol: "hand.raised.fill", tone: .on) : State(title: "Adblock turned off", detail: "Safari blocking is off", short: "Off", symbol: "hand.raised.slash.fill", tone: .off)) }
        startShowing()
    }

    private func startShowing() {
        guard showing == nil, !pending.isEmpty else { return }
        showing = Task { [weak self] in
            while let self, !Task.isCancelled, !self.pending.isEmpty {
                let next = self.pending.removeFirst()
                await self.present(next)
                try? await Task.sleep(for: .seconds(3.5))
            }
            await self?.finish()
        }
    }

    private func present(_ state: State) async {
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(30))
        if let activity = Activity<ConnectionActivityAttributes>.activities.first {
            await activity.update(content, alertConfiguration: AlertConfiguration(title: LocalizedStringResource(stringLiteral: state.title), body: LocalizedStringResource(stringLiteral: state.detail), sound: .default))
        } else if canStart, ActivityAuthorizationInfo().areActivitiesEnabled {
            _ = try? Activity.request(attributes: ConnectionActivityAttributes(sessionID: UUID().uuidString), content: content, pushType: nil)
        }
    }

    private func finish() async {
        showing = nil
        if !pending.isEmpty { startShowing(); return }
        end()
    }
    private func end() { for activity in Activity<ConnectionActivityAttributes>.activities { Task { await activity.end(nil, dismissalPolicy: .immediate) } } }
}
