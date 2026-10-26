import SwiftUI
import VayuSetuCore

/// "Is it really working?" in one panel. Every line comes from something the app observed, shows when, and can be re-checked; a
/// switch that is on but has not been seen working is never shown as protected.
struct MacProtectionProof: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    @ObservedObject var filter: FilterClient
    @State private var checking = false
    @Environment(\.openChecksPage) private var openChecks
    @State private var restarting = false
    @State private var previousResources: TunnelResources?
    @State private var cpuShare: Double?
    @Environment(\.extensionManager) private var extensions
    @State private var now = Date()
    private let tick = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private var proof: ProtectionProof { ProtectionProofEngine.evaluate(observations, now: now) }

    private var observations: ProofObservations { MacProofSource.observations(store: store, tunnel: tunnel, filter: filter, now: now) }

    private var tint: Color {
        switch proof.verdict { case .protected: .green; case .partial: .orange; case .notProtected: .red; case .off: .secondary }
    }
    private var verdictText: String {
        switch proof.verdict { case .protected: "Working"; case .partial: "Not fully verified"; case .notProtected: "Not working"; case .off: "Off" }
    }

    var body: some View {
        MacPanel("Is it working?", icon: "checkmark.shield", trailing: { MacChip(text: verdictText, tint: tint) }) {
            VStack(alignment: .leading, spacing: 10) {
                Text(proof.headline).font(.system(size: 13, weight: .medium))
                ForEach(proof.checks.filter { $0.outcome != .notUsed }) { check in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: icon(check.outcome)).foregroundStyle(color(check.outcome)).frame(width: 18).contentTransition(.symbolEffect(.replace)).macAnimate(.bouncy(duration: 0.4), value: check.outcome)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.title).font(.system(size: 13, weight: .semibold))
                            Text(check.detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if check.id == "dns", check.outcome == .failed, let note = store.dnsVerification?.detail, !note.isEmpty {
                                Text(note).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                            }
                            if let date = check.checkedAt { Text("Checked " + date.formatted(.relative(presentation: .named))).font(.system(size: 11)).foregroundStyle(.tertiary) }
                        }
                    }
                }
                if proof.verdict == .notProtected || proof.verdict == .partial, proof.checks.contains(where: { $0.outcome == .failed }) {
                    HStack(spacing: 10) {
                        Button { Task { await restart() } } label: { Label(restarting ? "Restarting…" : "Restart protection", systemImage: "arrow.triangle.2.circlepath") }
                            .buttonStyle(MacHoverButtonStyle(prominent: true)).disabled(restarting || checking)
                        Text("Turns the connection off and on again, then checks it. This often clears a stale tunnel.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                if let r = tunnel.stats?.resources, tunnel.running {
                    HStack(spacing: 6) {
                        Image(systemName: "gauge.with.dots.needle.33percent").foregroundStyle(.secondary).frame(width: 18)
                        Text("Cost of protection: the tunnel uses " + ByteCountFormatter.string(fromByteCount: Int64(clamping: r.memoryBytes), countStyle: .memory)
                             + (cpuShare.map { " and " + String(format: "%.1f", $0 * 100) + "% of one processor core" } ?? "") + ".")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                if proof.verdict != .off {
                    HStack {
                        Button { Task { await recheck() } } label: { Label(checking ? "Checking…" : "Check now", systemImage: "arrow.clockwise") }
                            .buttonStyle(MacHoverButtonStyle()).disabled(checking)
                        Button { openChecks?() } label: { Label("More checks", systemImage: "waveform.path.ecg") }.buttonStyle(MacHoverButtonStyle())
                        Text("A check sends a few small lookups through the tunnel. It never changes a setting.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onReceive(tick) { now = $0 }
        .onChange(of: tunnel.stats?.resources) { _, new in
            guard let new else { previousResources = nil; cpuShare = nil; return }
            if let old = previousResources, let share = TunnelResources.cpuShare(from: old, to: new) { cpuShare = share }
            if previousResources.map({ new.sampledAt.timeIntervalSince($0.sampledAt) >= 5 }) ?? true { previousResources = new }
        }
    }

    /// Off, then on again with the same mode, then a fresh check. The same path as the power button, so it keeps its confirmations.
    private func restart() async {
        restarting = true; defer { restarting = false }
        await store.powerOffNetwork()
        for _ in 0..<30 where store.networkActive { try? await Task.sleep(for: .seconds(1)) }
        try? await Task.sleep(for: .seconds(1))
        let turnOn: () -> Void = { Task { _ = await store.powerTapped() } }
        if let extensions { extensions.activate { turnOn() } } else { turnOn() }
        // Give the tunnel time to come up and the rules time to arrive, then look again.
        try? await Task.sleep(for: .seconds(12))
        await recheck()
    }
    private func recheck() async {
        checking = true; defer { checking = false }
        await store.verifyLocalDNS()
        await store.filtering.refresh()
        now = Date()
    }
    private func icon(_ outcome: ProofCheck.Outcome) -> String {
        switch outcome { case .passed: "checkmark.circle.fill"; case .failed: "xmark.octagon.fill"; case .unverified: "questionmark.circle.fill"; case .notUsed: "minus.circle" }
    }
    private func color(_ outcome: ProofCheck.Outcome) -> Color {
        switch outcome { case .passed: .green; case .failed: .red; case .unverified: .orange; case .notUsed: .secondary }
    }
}

/// Builds what the app has actually observed, for the proof panel and the menu bar icon alike.
enum MacProofSource {
    @MainActor static func observations(store: AppStore, tunnel: TunnelController, filter: FilterClient, now: Date) -> ProofObservations {
        var o = ProofObservations()
        // VPN
        o.vpnWanted = store.vpnPill != .off
        switch store.vpnPill {
        case .active: o.vpnConnected = tunnel.running && !tunnel.localDNSRunning && tunnel.status == .connected ? true : nil
        case .failed: o.vpnConnected = false
        default: o.vpnConnected = nil
        }
        if let handshake = tunnel.stats?.latestHandshake, (tunnel.statsAge ?? .infinity) < 30 { o.handshakeAge = max(0, now.timeIntervalSince(handshake)) }
        // DNS
        o.dnsWanted = store.dnsPill != .off
        o.dnsFilteringWanted = store.isVayuSetuDNSSelected
        if let check = store.dnsVerification {
            o.dnsCheckedAt = check.date
            o.dnsAnswered = check.passed || check.blockedChecked
            if store.isVayuSetuDNSSelected { o.blockedNameBlocked = check.blockedChecked ? true : (check.passed ? nil : false) }
        }
        // Safari
        o.safariWanted = store.adblockPill != .off
        switch store.filtering.snapshot().observed {
        case .active: o.safariRulesLoaded = true
        case .needsAttention, .error: o.safariRulesLoaded = false
        default: o.safariRulesLoaded = nil
        }
        o.safariCheckedAt = store.filtering.snapshot().observedAt
        // Network filter
        o.filterWanted = filter.status != .off && filter.status != .unavailable
        o.filterRunning = filter.status == .running ? true : (filter.status == .unreachable ? false : nil)
        return o
    }
}
