import Combine
import SwiftUI

/// One domain knocking on the tunnel, for the live scene.
struct GateParticle: Identifiable {
    enum Kind { case passed, blocked }
    let id = UUID()
    let name: String
    let kind: Kind
    /// When it sets off. Particles from one batch are spread over a couple of seconds so a burst reads as a stream.
    let born: Date
    /// 0...1, how far up or down the tunnel it travels.
    let lane: Double
}

/// Turns the tunnel's per-domain counts into particles and keeps the running totals. It keeps no domain names beyond the few seconds a
/// particle is on screen, and nothing is stored.
@MainActor final class LiveGateModel: ObservableObject {
    @Published private(set) var passed = 0
    @Published private(set) var blocked = 0
    @Published private(set) var caption = ""
    private(set) var particles: [GateParticle] = []
    private var lastCaption = Date.distantPast
    private var listener: AnyCancellable?
    static let travel = SceneDraw.travel, afterGate = SceneDraw.afterGate, maxParticlesPerBatch = 32, perNameLimit = 3

    private static let blockedLines = ["%@ knocked. The shield said no.", "%@ tried to sneak in. Bonk.", "%@ was turned away at the door.", "%@ bounced right off.", "Not today, %@."]
    private static let passedLines = ["%@ went right through.", "%@ waved and walked in.", "%@ slid through the tunnel.", "Come on in, %@."]

    func listen(to store: DomainHistoryStore) {
        guard listener == nil else { return }
        listener = store.batches.receive(on: DispatchQueue.main).sink { [weak self] batch in self?.add(batch) }
    }
    func stop() { listener?.cancel(); listener = nil }
    func reset() { passed = 0; blocked = 0; caption = ""; particles = [] }

    func add(_ batch: [DomainCount], now: Date = Date()) {
        var spawned = 0
        for item in batch {
            passed += Int(item.a); blocked += Int(item.b)
            guard !item.n.isEmpty else { continue }
            for (count, kind) in [(item.b, GateParticle.Kind.blocked), (item.a, .passed)] {
                for _ in 0..<min(Int(count), Self.perNameLimit) where spawned < Self.maxParticlesPerBatch {
                    particles.append(GateParticle(name: item.n, kind: kind, born: now.addingTimeInterval(Double.random(in: 0...1.8)), lane: Double.random(in: 0...1)))
                    spawned += 1
                }
            }
        }
        prune(now: now)
        if now.timeIntervalSince(lastCaption) > 1.2, let pick = batch.first(where: { !$0.n.isEmpty && $0.b > 0 }) ?? batch.first(where: { !$0.n.isEmpty }) {
            let lines = pick.b > 0 ? Self.blockedLines : Self.passedLines
            caption = String(format: lines.randomElement() ?? "%@", pick.n)
            lastCaption = now
        }
    }

    func prune(now: Date = Date()) { particles.removeAll { now.timeIntervalSince($0.born) > Self.travel + Self.afterGate + 0.4 } }
}

/// The scene: your Mac on the left, a tunnel with a shield across it, the internet on the right. Every lookup is a little chip that
/// swims down the tunnel. Allowed ones glide through the shield; blocked ones hit it, make it flash, and shatter.
struct MacLiveGate: View {
    @ObservedObject var tunnel: TunnelController
    @ObservedObject var history: DomainHistoryStore
    @StateObject private var model = LiveGateModel()
    @AppStorage("animated-scenes") private var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        MacPanel("Live traffic", icon: "bolt.horizontal.circle", trailing: { HStack(spacing: 8) { MacChip(text: tunnel.domainsAvailable ? "Live" : "Waiting", tint: tunnel.domainsAvailable ? .green : .secondary); ScenePauseButton() } }) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: Binding(get: { tunnel.liveGateOn }, set: { tunnel.setLiveGate($0); history.startCollecting(tunnel: tunnel); if $0 { model.listen(to: history) } else { model.stop(); model.reset() } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Watch lookups arrive").font(.system(size: 13, weight: .semibold))
                        Text("Draws each domain as it is blocked or let through. Nothing is saved; it is gone a moment after it is drawn.").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.toggleStyle(.switch)
                if tunnel.liveGateOn {
                    if !tunnel.domainsAvailable { Label("Turn on DNS filtering (DNS only, or VPN + DNS) and the lookups start to arrive.", systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary) }
                    if reduceMotion || !animated { plainList } else { scene }
                    HStack(spacing: 22) {
                        MacFigure(caption: "Went through", value: model.passed.formatted(), tint: VSDesign.accent, rolls: true)
                        MacFigure(caption: "Stopped at the shield", value: model.blocked.formatted(), tint: .orange, rolls: true)
                    }
                    Text(model.caption.isEmpty ? "Waiting for the first lookup…" : model.caption).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .contentTransition(.opacity).animation(.easeInOut(duration: 0.25), value: model.caption)
                }
            }
        }
        .onAppear { if tunnel.liveGateOn { history.startCollecting(tunnel: tunnel); model.listen(to: history) } }
        .onDisappear { model.stop() }
        .task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(1)); model.prune() } }
    }

    private var plainList: some View {
        Text(model.caption.isEmpty ? "The animation is paused, so lookups are summarised here instead." : model.caption).font(.system(size: 12)).foregroundStyle(.secondary)
    }

    // MARK: The scene
    private var scene: some View {
        SceneTimeline { timeline in
            // The scene draws from a snapshot, off the main thread; the text is laid out once, as symbols.
            let snapshot = model.particles, style = SceneDraw.GateStyle()
            Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, size in
                SceneDraw.drawGate(&context, size: size, now: timeline.date, particles: snapshot, style: style)
            } symbols: {
                ForEach(SceneDraw.gateSymbols(snapshot, style: style)) { symbol in SceneDraw.symbolView(symbol).tag(symbol.id) }
            }
        }
        .frame(height: 190).frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live view of lookups. \(model.passed) went through, \(model.blocked) were stopped.")
    }
}
