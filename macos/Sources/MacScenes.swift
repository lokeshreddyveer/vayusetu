import Combine
import SwiftUI
import VayuSetuCore

// MARK: - Home: your route

/// Where your traffic goes right now, drawn from the real state: nothing switched on, DNS only, VPN only, or both. The number of packets on
/// screen follows how much your connection is actually carrying. The packets are an illustration, not a capture.
struct MacRouteScene: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tracker: SpeedTracker
    @AppStorage("animated-scenes") private var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var summary: String {
        switch store.powerTone {
        case .off: return "Nothing is protecting this path: traffic and name lookups go straight out."
        case .dnsOnly: return "Name lookups are checked by VayuSetu DNS and asked over encryption. Your other traffic goes direct."
        case .vpnOnly: return "All traffic goes through the VPN" + (store.active.map { " (\($0.name))" } ?? "") + " before it reaches the internet."
        case .vpnWithDNS: return "All traffic goes through the VPN, and name lookups are filtered first."
        case .busy: return "Setting up the route…"
        case .error: return "The route could not be set up. Nothing is being protected."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if reduceMotion || !animated {
                Text(summary).font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                SceneTimeline(interval: SceneDraw.frameInterval, held: store.powerTone == .off || store.powerTone == .error) { timeline in
                    let tone = store.powerTone, rate = tracker.down + tracker.up, serverName = store.active?.name ?? "VPN server"
                    let symbols = SceneDraw.nodeSymbols(["This Mac", "Internet", "VayuSetu DNS", SceneDraw.short(serverName, 18)])
                    Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, size in
                        Self.draw(&context, size: size, now: timeline.date, tone: tone, rate: rate, serverName: serverName)
                    } symbols: {
                        ForEach(symbols) { symbol in SceneDraw.symbolView(symbol).tag(symbol.id) }
                    }
                }.frame(height: 150).frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore).accessibilityLabel(summary)
                Text(summary).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity).macAnimate(value: summary)
            }
        }
    }

    private static func draw(_ context: inout GraphicsContext, size: CGSize, now: Date, tone: PowerTone, rate: Double, serverName: String) {
        let w = size.width, mid = size.height / 2 - 6
        let mac = CGPoint(x: 50, y: mid), net = CGPoint(x: w - 50, y: mid)
        let t = now.timeIntervalSinceReferenceDate
        // The more the connection carries, the more packets are on screen (a logarithmic scale, so a trickle still shows).
        let count = max(2, min(14, Int(2 + max(0, log10(max(rate, 1)) - 2) * 2.4)))

        switch tone {
        case .off:
            line(&context, [mac, net], color: .secondary, dashed: true)
            packets(&context, [mac, net], count: count, t: t, speed: 0.22, color: .secondary)
            SceneDraw.node(&context, icon: "laptopcomputer", label: "This Mac", at: mac, color: .secondary)
            SceneDraw.node(&context, icon: "globe", label: "Internet", at: net, color: .secondary)
        case .dnsOnly:
            let dns = CGPoint(x: w * 0.46, y: mid + 34), top = [CGPoint(x: mac.x, y: mid - 28), CGPoint(x: net.x, y: mid - 28)]
            line(&context, top, color: .secondary, dashed: true)
            packets(&context, top, count: count, t: t, speed: 0.22, color: .secondary)
            let lane = [CGPoint(x: mac.x, y: mid + 34), dns, CGPoint(x: net.x, y: mid + 34)]
            line(&context, lane, color: SceneDraw.teal, dashed: false)
            packets(&context, lane, count: max(2, count / 2), t: t, speed: 0.3, color: SceneDraw.teal, small: true)
            SceneDraw.node(&context, icon: "laptopcomputer", label: "This Mac", at: CGPoint(x: mac.x, y: mid + 4), color: .secondary)
            SceneDraw.node(&context, icon: "shield.checkered", label: "VayuSetu DNS", at: dns, color: SceneDraw.teal, glow: 0.6 + 0.4 * sin(t * 3))
            SceneDraw.node(&context, icon: "globe", label: "Internet", at: CGPoint(x: net.x, y: mid + 4), color: SceneDraw.blue)
        case .vpnOnly, .vpnWithDNS:
            let server = CGPoint(x: w * 0.62, y: mid)
            let path = [mac, server, net]
            pipe(&context, from: mac, to: server)
            packets(&context, [mac, server], count: count, t: t, speed: 0.3, color: SceneDraw.blue, lock: true)
            packets(&context, [server, net], count: max(2, count - 2), t: t, speed: 0.22, color: .secondary)
            line(&context, [server, net], color: .secondary, dashed: true)
            _ = path
            SceneDraw.node(&context, icon: "laptopcomputer", label: "This Mac", at: mac, color: .secondary)
            if tone == .vpnWithDNS {
                SceneDraw.node(&context, icon: "shield.checkered", label: "VayuSetu DNS", at: CGPoint(x: w * 0.3, y: mid), color: SceneDraw.teal, glow: 0.6 + 0.4 * sin(t * 3))
            }
            SceneDraw.node(&context, icon: "server.rack", label: SceneDraw.short(serverName, 18), at: server, color: SceneDraw.blue, glow: 0.4)
            SceneDraw.node(&context, icon: "globe", label: "Internet", at: net, color: SceneDraw.blue)
        case .busy:
            // The pipe draws itself, over and over, while the route is being made.
            let progress = SceneDraw.fract(t / 1.6)
            line(&context, [mac, net], color: .orange.opacity(0.35), dashed: true)
            var drawn = Path(); drawn.move(to: mac); drawn.addLine(to: CGPoint(x: mac.x + (net.x - mac.x) * CGFloat(progress), y: mid))
            context.stroke(drawn, with: .color(Color.orange), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            SceneDraw.node(&context, icon: "laptopcomputer", label: "This Mac", at: mac, color: .secondary)
            SceneDraw.node(&context, icon: "globe", label: "Internet", at: net, color: .orange)
        case .error:
            let breakX = w * 0.5
            line(&context, [mac, CGPoint(x: breakX - 14, y: mid)], color: .red, dashed: true)
            line(&context, [CGPoint(x: breakX + 14, y: mid), net], color: .red, dashed: true)
            SceneDraw.icon(&context, "xmark.octagon.fill", at: CGPoint(x: breakX, y: mid), size: 26 + CGFloat(sin(t * 4)) * 2, color: .red)
            SceneDraw.node(&context, icon: "laptopcomputer", label: "This Mac", at: mac, color: .secondary)
            SceneDraw.node(&context, icon: "globe", label: "Internet", at: net, color: .red)
        }
    }

    private static func line(_ context: inout GraphicsContext, _ points: [CGPoint], color: Color, dashed: Bool) {
        var path = Path(); path.move(to: points[0]); for p in points.dropFirst() { path.addLine(to: p) }
        context.stroke(path, with: .color(color.opacity(0.35)), style: StrokeStyle(lineWidth: dashed ? 1.5 : 2.5, lineCap: .round, dash: dashed ? [4, 5] : []))
    }
    private static func pipe(_ context: inout GraphicsContext, from a: CGPoint, to b: CGPoint) {
        let rect = CGRect(x: a.x, y: a.y - 15, width: b.x - a.x, height: 30)
        context.fill(Path(roundedRect: rect, cornerRadius: 15), with: .color(SceneDraw.blue.opacity(0.12)))
        context.stroke(Path(roundedRect: rect, cornerRadius: 15), with: .color(SceneDraw.blue.opacity(0.45)), lineWidth: 1.5)
    }
    private static func packets(_ context: inout GraphicsContext, _ points: [CGPoint], count: Int, t: Double, speed: Double, color: Color, small: Bool = false, lock: Bool = false) {
        guard points.count > 1 else { return }
        for i in 0..<count {
            let u = SceneDraw.fract(t * speed + Double(i) / Double(count) + SceneDraw.unit("p\(i)") * 0.05)
            let p = SceneDraw.along(points, u)
            let edge = min(1, min(u, 1 - u) * 8)               // fade in and out at the ends
            let size: CGFloat = small ? 5 : 8
            var c = context; c.opacity = edge
            c.fill(Path(roundedRect: CGRect(x: p.x - size / 2, y: p.y - size / 3, width: size, height: size * 0.66), cornerRadius: 2), with: .color(color.opacity(0.95)))
            if lock && i % 3 == 0 { SceneDraw.icon(&c, "lock.fill", at: CGPoint(x: p.x, y: p.y - 11), size: 7, color: color) }
        }
    }
}

// MARK: - Network: apps at the firewall

/// New connections from the network filter, each one an app's connection swimming towards the firewall: allowed ones pass, blocked ones shatter.
@MainActor final class FirewallSceneModel: ObservableObject {
    @Published private(set) var passed = 0
    @Published private(set) var blocked = 0
    @Published private(set) var caption = ""
    private(set) var particles: [GateParticle] = []
    private(set) var lanes: [String] = []
    private var lastID: Int64?
    private var lastCaption = Date.distantPast
    static let maxLanes = 5
    static let travel = SceneDraw.travel, afterGate = SceneDraw.afterGate

    private static let blockedLines = ["%@ was stopped at the firewall.", "%@ tried to connect. The firewall said no.", "No entry for %@."]
    private static let passedLines = ["%@ connected through.", "%@ phoned home and got through.", "%@ went out to the internet."]

    func ingest(_ flows: [FlowRecord], now: Date = Date()) {
        guard let newest = flows.last?.id else { return }
        guard let seen = lastID else { lastID = newest; return }              // start from "now", not from the whole history
        let fresh = flows.filter { $0.id > seen }
        lastID = newest
        var spawned = 0
        for flow in fresh {
            let isBlocked = flow.verdict == .block
            if isBlocked { blocked += 1 } else { passed += 1 }
            guard spawned < 26 else { continue }
            let name = flow.appName.isEmpty ? flow.app : flow.appName
            if !lanes.contains(name) { if lanes.count < Self.maxLanes { lanes.append(name) } }
            let laneIndex = lanes.firstIndex(of: name) ?? Int(SceneDraw.unit(name) * Double(Self.maxLanes))
            let lane = Self.maxLanes > 1 ? Double(min(laneIndex, Self.maxLanes - 1)) / Double(Self.maxLanes - 1) : 0.5
            particles.append(GateParticle(name: flow.host.isEmpty ? name : flow.host, kind: isBlocked ? .blocked : .passed, born: now.addingTimeInterval(Double.random(in: 0...1.6)), lane: lane))
            spawned += 1
            if now.timeIntervalSince(lastCaption) > 1.3 {
                let lines = isBlocked ? Self.blockedLines : Self.passedLines
                caption = String(format: lines.randomElement() ?? "%@", name); lastCaption = now
            }
        }
        prune(now: now)
    }
    func prune(now: Date = Date()) { particles.removeAll { now.timeIntervalSince($0.born) > SceneDraw.travel + SceneDraw.afterGate + 0.4 } }
    func reset() { passed = 0; blocked = 0; caption = ""; particles = []; lanes = []; lastID = nil }
    /// Lane labels in order, padded so each lane lines up with where its connections travel.
    var laneLabels: [String] { (0..<Self.maxLanes).map { $0 < lanes.count ? lanes[$0] : "" } }
}

struct MacFirewallScene: View {
    @ObservedObject var client: FilterClient
    @StateObject private var model = FirewallSceneModel()
    @AppStorage("network-scene-hidden") private var hidden = false
    @AppStorage("animated-scenes") private var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        MacPanel("Connections, live", icon: "bolt.horizontal.circle", trailing: {
            HStack(spacing: 8) {
                MacChip(text: client.status == .running ? "Live" : "Off", tint: client.status == .running ? .green : .secondary)
                ScenePauseButton()
                Button { withAnimation(.easeInOut(duration: 0.25)) { hidden.toggle() } } label: { Image(systemName: hidden ? "chevron.down" : "chevron.up").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.plain).help(hidden ? "Show the live view" : "Hide the live view")
            }
        }) {
            VStack(alignment: .leading, spacing: 12) {
                if hidden {
                    Text("The live view is hidden. \(model.passed) allowed and \(model.blocked) blocked since you opened this page.").font(.system(size: 12)).foregroundStyle(.secondary)
                } else if client.status != .running {
                    Text("Turn the network filter on and every app's connections appear here as they happen.").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    if reduceMotion || !animated { Text(model.caption.isEmpty ? "The animation is paused; see the table below." : model.caption).font(.system(size: 12)).foregroundStyle(.secondary) }
                    else {
                        SceneTimeline { timeline in
                            let snapshot = model.particles, style = SceneDraw.GateStyle(leftIcon: "square.grid.2x2", gateIcon: "flame.fill", laneLabels: model.laneLabels)
                            Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, size in
                                SceneDraw.drawGate(&context, size: size, now: timeline.date, particles: snapshot, style: style)
                            } symbols: {
                                ForEach(SceneDraw.gateSymbols(snapshot, style: style)) { symbol in SceneDraw.symbolView(symbol).tag(symbol.id) }
                            }
                        }.frame(height: 200).frame(maxWidth: .infinity)
                            .accessibilityElement(children: .ignore).accessibilityLabel("Live view of connections. \(model.passed) allowed, \(model.blocked) blocked.")
                        Text(model.caption.isEmpty ? "Waiting for the next connection…" : model.caption).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                            .contentTransition(.opacity).macAnimate(value: model.caption)
                    }
                    HStack(spacing: 22) {
                        MacFigure(caption: "Allowed since you opened this page", value: model.passed.formatted(), tint: VSDesign.accent, rolls: true)
                        MacFigure(caption: "Blocked", value: model.blocked.formatted(), tint: .orange, rolls: true)
                    }
                }
            }
        }
        .onAppear { model.ingest(client.flows) }
        .onChange(of: client.flows.last?.id) { _, _ in model.ingest(client.flows) }
        .task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(1)); model.prune() } }
    }
}

// MARK: - Security Center: radar

/// Every blocked destination is a blip on a sweeping radar; a blip lights up when the sweep passes over it. Where a blip sits is decoration
/// (a fixed place for each name); how many there are, and how big, is real.
struct MacRadarScene: View {
    let blockedDestinations: [DigestDestination]
    let blocked: Int
    let connections: Int
    @AppStorage("animated-scenes") private var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        MacPanel("Radar", icon: "dot.radiowaves.left.and.right", trailing: { ScenePauseButton() }) {
            HStack(alignment: .center, spacing: 22) {
                Group {
                    if reduceMotion || !animated { radarCanvas(now: .distantPast, animate: false) }
                    else { SceneTimeline { timeline in radarCanvas(now: timeline.date, animate: true) } }
                }.frame(width: 190, height: 190)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Radar of blocked destinations. \(blockedDestinations.count) destinations were blocked.")
                VStack(alignment: .leading, spacing: 12) {
                    MacFigure(caption: "Blocked destinations", value: blockedDestinations.count.formatted(), tint: blockedDestinations.isEmpty ? .green : .orange)
                    MacFigure(caption: "Blocked connections", value: blocked.formatted(), tint: .orange)
                    Text(blockedDestinations.isEmpty ? "All clear: nothing was blocked in this period." : "Each dot is a place your Mac was stopped from reaching. Bigger dots were tried more often.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func radarCanvas(now: Date, animate: Bool) -> some View {
        let blockedDestinations = self.blockedDestinations
        return Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2), r = min(size.width, size.height) / 2 - 4
            let tint = blockedDestinations.isEmpty ? SceneDraw.green : Color.orange
            context.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(tint.opacity(0.06)))
            for f in [1.0, 0.66, 0.33] { context.stroke(Path(ellipseIn: CGRect(x: c.x - r * f, y: c.y - r * f, width: r * 2 * f, height: r * 2 * f)), with: .color(tint.opacity(0.28)), lineWidth: 1) }
            var cross = Path(); cross.move(to: CGPoint(x: c.x - r, y: c.y)); cross.addLine(to: CGPoint(x: c.x + r, y: c.y)); cross.move(to: CGPoint(x: c.x, y: c.y - r)); cross.addLine(to: CGPoint(x: c.x, y: c.y + r))
            context.stroke(cross, with: .color(tint.opacity(0.18)), lineWidth: 1)
            let sweep = animate ? SceneDraw.fract(now.timeIntervalSinceReferenceDate / 4.5) * 2 * .pi : 0
            if animate {
                // The sweep: a bright edge with a fading trail behind it.
                for i in 0..<28 {
                    let a0 = sweep - Double(i) * 0.045, a1 = sweep - Double(i + 1) * 0.045
                    var wedge = Path(); wedge.move(to: c)
                    wedge.addArc(center: c, radius: r, startAngle: .radians(a1), endAngle: .radians(a0), clockwise: false)
                    wedge.closeSubpath()
                    context.fill(wedge, with: .color(tint.opacity(0.30 * (1 - Double(i) / 28))))
                }
            }
            let top = blockedDestinations.prefix(14)
            let most = Double(top.map(\.count).max() ?? 1)
            for dest in top {
                let angle = SceneDraw.unit(dest.host) * 2 * .pi
                let radius = r * (0.22 + 0.72 * SceneDraw.unit(dest.host, salt: 7))
                let p = CGPoint(x: c.x + cos(angle) * radius, y: c.y + sin(angle) * radius)
                // How long ago the sweep passed this blip (0 right now, 1 a full turn ago): it flares, then settles.
                var since = (sweep - angle).truncatingRemainder(dividingBy: 2 * .pi); if since < 0 { since += 2 * .pi }
                let flare = animate ? max(0, 1 - since / 2.2) : 0.4
                let size = 5 + 7 * CGFloat(Double(dest.count) / most)
                context.fill(Path(ellipseIn: CGRect(x: p.x - size * (1 + flare) / 2 - 3, y: p.y - size * (1 + flare) / 2 - 3, width: size * (1 + flare) + 6, height: size * (1 + flare) + 6)), with: .color(tint.opacity(0.22 * flare)))
                context.fill(Path(ellipseIn: CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)), with: .color(tint.opacity(0.55 + 0.45 * flare)))
            }
            context.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(tint))
        }
    }
}

// MARK: - Speed: a gauge against your best, and a race

/// A dial: the needle is how fast the connection is going right now, and the scale tops out a little above the best speed this mode has reached,
/// so you can see how close you are to your own best.
struct MacSpeedGauge: View {
    let value: Double            // bytes per second
    let best: Double             // bytes per second, the best seen in this mode (0 when none)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = 0.0

    private var ceiling: Double {
        let bits = max(value, best) * 8 * 1.15
        return [10e6, 25e6, 50e6, 100e6, 250e6, 500e6, 1e9, 2.5e9, 10e9].first { $0 >= bits } ?? 10e9
    }
    private var fraction: Double { min(1, max(0, shown * 8 / ceiling)) }

    var body: some View {
        ZStack {
            Canvas { context, size in
                let c = CGPoint(x: size.width / 2, y: size.height - 36), r = min(size.width / 2, size.height - 36) - 10
                let start = Angle.degrees(180), end = Angle.degrees(360)
                var track = Path(); track.addArc(center: c, radius: r, startAngle: start, endAngle: end, clockwise: false)
                context.stroke(track, with: .color(Color.secondary.opacity(0.25)), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                var fill = Path(); fill.addArc(center: c, radius: r, startAngle: start, endAngle: .degrees(180 + 180 * fraction), clockwise: false)
                context.stroke(fill, with: .linearGradient(Gradient(colors: [SceneDraw.teal, SceneDraw.blue, Color.purple]), startPoint: CGPoint(x: c.x - r, y: c.y), endPoint: CGPoint(x: c.x + r, y: c.y)), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                if best > 0 {
                    let a = Angle.degrees(180 + 180 * min(1, best * 8 / ceiling)).radians
                    var tick = Path(); tick.move(to: CGPoint(x: c.x + cos(a) * (r - 10), y: c.y + sin(a) * (r - 10))); tick.addLine(to: CGPoint(x: c.x + cos(a) * (r + 8), y: c.y + sin(a) * (r + 8)))
                    context.stroke(tick, with: .color(Color.orange), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
                let a = Angle.degrees(180 + 180 * fraction).radians
                var needle = Path(); needle.move(to: c); needle.addLine(to: CGPoint(x: c.x + cos(a) * (r - 16), y: c.y + sin(a) * (r - 16)))
                context.stroke(needle, with: .color(Color.primary.opacity(0.85)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                context.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(Color.primary))
            }
            VStack(spacing: 1) {
                Spacer()
                Text(SpeedFormat.text(shown)).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(best > 0 ? "best \(SpeedFormat.text(best))" : "no best yet").font(.system(size: 9)).foregroundStyle(.secondary)
            }.padding(.bottom, 2)
        }
        .frame(width: 170, height: 132)
        .onChange(of: value) { _, new in withAnimation(reduceMotion ? nil : .spring(response: 0.7, dampingFraction: 0.72)) { shown = new } }
        .onAppear { shown = value }
        .accessibilityElement(children: .ignore).accessibilityLabel("Speed \(SpeedFormat.text(value))")
    }
}

/// One lane of the race: how far this mode's best download got, as a share of the fastest mode, with a runner at the end of it.
struct MacRaceLane: View {
    let title: String
    let icon: String
    let value: Double
    let fastest: Double
    let isNow: Bool
    @State private var progress = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 18).foregroundStyle(isNow ? VSDesign.accent : .secondary)
                Text(title).font(.system(size: 12, weight: isNow ? .semibold : .regular))
                if isNow { MacChip(text: "now", tint: .green) }
                Spacer(minLength: 6)
                Text(value > 0 ? SpeedFormat.text(value) : "—").font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                let share = fastest > 0 ? value / fastest : 0
                let x = max(8, (proxy.size.width - 16) * share * progress)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.14))
                    Capsule().fill(LinearGradient(colors: [SceneDraw.teal.opacity(0.7), SceneDraw.blue], startPoint: .leading, endPoint: .trailing)).frame(width: value > 0 ? x + 8 : 0)
                    if value > 0 { Image(systemName: progress < 0.98 ? "figure.run" : "flag.checkered").font(.system(size: 11, weight: .bold)).foregroundStyle(isNow ? Color.white : Color.primary.opacity(0.85)).offset(x: max(0, x - 6)) }
                }
            }.frame(height: 14)
        }
        .onAppear { if reduceMotion { progress = 1 } else { withAnimation(.spring(response: 1.1, dampingFraction: 0.8).delay(Double.random(in: 0...0.25))) { progress = 1 } } }
        .onChange(of: value) { _, _ in progress = reduceMotion ? 1 : 0.0; withAnimation(reduceMotion ? nil : .spring(response: 0.9, dampingFraction: 0.8)) { progress = 1 } }
    }
}

// MARK: - Setup: a road with milestones

/// The setup checklist as a road: a dot has driven as far as the steps that are done, and the next one pulses.
struct MacSetupRoad: View {
    let done: Int
    let total: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    /// The marker pulses a few times when it appears or moves, then rests. Pulsing forever redraws every frame for as long as the window is open.
    private func pulseMarker() {
        guard !reduceMotion, done < total else { return }
        pulse = false
        withAnimation(.easeInOut(duration: 1.1).repeatCount(SceneActivity.pulseCycles * 2, autoreverses: true)) { pulse = true }
        Task { try? await Task.sleep(for: .seconds(1.1 * Double(SceneActivity.pulseCycles * 2) + 0.2)); withAnimation(.easeOut(duration: 0.3)) { pulse = false } }
    }

    var body: some View {
        GeometryReader { proxy in
            let step = total > 1 ? (proxy.size.width - 24) / CGFloat(total - 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2)).frame(height: 4).padding(.horizontal, 12)
                Capsule().fill(LinearGradient(colors: [SceneDraw.teal, SceneDraw.green], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 12 + step * CGFloat(max(0, min(done, total - 1))), height: 4).padding(.leading, 12)
                    .macAnimate(.spring(response: 0.7, dampingFraction: 0.8), value: done)
                ForEach(0..<total, id: \.self) { i in
                    let reached = i < done, next = i == done
                    ZStack {
                        if next && !reduceMotion { Circle().fill(SceneDraw.teal.opacity(0.25)).frame(width: 24, height: 24).scaleEffect(pulse ? 1.25 : 0.85).opacity(pulse ? 0.2 : 0.7) }
                        Circle().fill(reached ? SceneDraw.green : Color.secondary.opacity(0.35)).frame(width: 14, height: 14)
                        if reached { Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white).transition(.scale) }
                    }.position(x: 12 + step * CGFloat(i), y: proxy.size.height / 2)
                    .macAnimate(.bouncy(duration: 0.45), value: reached)
                }
            }
        }
        .frame(height: 26)
        .onAppear { pulseMarker() }
        .onChange(of: done) { _, _ in pulseMarker() }
        .accessibilityElement(children: .ignore).accessibilityLabel("\(done) of \(total) steps done")
    }
}
