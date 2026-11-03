import SwiftUI
import VayuSetuCore

/// "Get VayuSetu ready": a checklist whose ticks come from what the app observes (an installed extension, a saved profile, Safari's
/// reported state), not from clicks. It disappears once every required step is done, and can be put away until the next launch.
struct MacSetupGuide: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    @ObservedObject var filter: FilterClient
    @ObservedObject var extensions: ExtensionManager
    /// Put away for good once the user says "Not now" or every step has been done once. It does not come back on every launch.
    @AppStorage("setup-guide-dismissed") private var dismissed = false
    @AppStorage("setup-guide-completed") private var completed = false
    /// "Check that it works" is done once protection has been seen working, and stays done after protection is switched off.
    @AppStorage("setup-proof-seen") private var proofSeen = false
    private var proofNow: Bool { store.vpnPill == .active || store.dnsPill == .active }
    private var proofWorking: Bool { proofNow || proofSeen }

    private var steps: [SetupStep] {
        var o = SetupObservations()
        let tunnelComponent = extensions.components.first { $0.id.hasSuffix(".tunnel") }
        o.tunnelInstalled = tunnelComponent.map { $0.installed != nil && $0.enabled && !$0.waitingForApproval } ?? false
        o.tunnelNeedsApproval = tunnelComponent?.waitingForApproval ?? false
        o.filterAvailable = filter.supported
        o.filterInstalled = filter.status == .running
        o.hasVPNProfile = !store.profiles.isEmpty
        o.hasDNSChoice = !store.dnsProfiles.isEmpty
        let needed = store.filtering.neededExtensions
        if !needed.isEmpty {
            o.safariExtensionsNeeded = needed.count
            let states = needed.map { store.filtering.extensionStates[$0]?.enabled }
            if states.contains(where: { $0 != nil }) { o.safariExtensionsOn = states.filter { $0 == true }.count }
        }
        o.proofWorking = proofWorking
        return SetupGuide.steps(o)
    }

    var body: some View {
        let all = steps
        Group { guide(all) }
            .onChange(of: proofNow) { _, now in if now { proofSeen = true } }
            .onChange(of: proofSeen) { _, _ in if SetupGuide.isComplete(steps) { completed = true } }
            .onAppear { if proofNow { proofSeen = true }; if SetupGuide.isComplete(all) { completed = true } }
    }

    @ViewBuilder private func guide(_ all: [SetupStep]) -> some View {
        if !dismissed, !completed, !SetupGuide.isComplete(all) {
            let progress = SetupGuide.progress(all)
            MacPanel("Get VayuSetu ready", icon: "list.bullet.clipboard", trailing: { MacChip(text: "\(progress.done) of \(progress.total)", tint: VSDesign.accent) }) {
                VStack(alignment: .leading, spacing: 10) {
                    MacSetupRoad(done: progress.done, total: progress.total)
                    ForEach(all) { step in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: icon(step.state)).foregroundStyle(color(step.state)).frame(width: 18).contentTransition(.symbolEffect(.replace)).macAnimate(.bouncy(duration: 0.4), value: step.state)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.title).font(.system(size: 13, weight: step.state == .done ? .regular : .semibold)).foregroundStyle(step.state == .done ? .secondary : .primary)
                                if step.state != .done { Text(step.detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                            }
                        }
                    }
                    HStack {
                        if extensions.needsAttention { Button("Update now") { extensions.updateComponents() }.buttonStyle(MacHoverButtonStyle(prominent: true)) }
                        Spacer()
                        Button("Not now") { dismissed = true }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    private func icon(_ s: SetupStep.State) -> String { switch s { case .done: "checkmark.circle.fill"; case .blocked: "exclamationmark.circle.fill"; case .todo: "circle"; case .optionalTodo: "circle.dashed" } }
    private func color(_ s: SetupStep.State) -> Color { switch s { case .done: .green; case .blocked: .orange; case .todo: .accentColor; case .optionalTodo: .secondary } }
}
