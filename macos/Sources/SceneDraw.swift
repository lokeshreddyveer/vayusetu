import AppKit
import SwiftUI
import VayuSetuCore

/// A piece of text a scene draws. Scenes hand these to the Canvas as symbols, so each is laid out once by SwiftUI instead of being
/// re-typeset every frame, which is what made the first version heavy.
struct SceneSymbol: Identifiable, Hashable {
    enum Style: Hashable { case pillBlue, pillOrange, shatter, lane, node }
    let id: String
    let text: String
    let style: Style
}

/// Drawing helpers shared by the animated scenes. Everything is drawn from real state and the clock; no scene invents traffic.
enum SceneDraw {
    static let blue = Color(red: 0.2, green: 0.55, blue: 1.0)
    static let teal = Color(red: 0.0, green: 0.78, blue: 0.82)
    static let green = Color(red: 0.196, green: 0.839, blue: 0.627)
    /// How long a lookup takes to reach the shield, and to leave the far side after it.
    static let travel = 1.15, afterGate = 1.0
    /// A scene is ambient, so 30 frames a second reads as smooth and costs half of 60.
    static let frameInterval = 1.0 / 30.0

    static func ease(_ x: Double) -> CGFloat { let c = min(max(x, 0), 1); return CGFloat(c * c * (3 - 2 * c)) }
    static func fract(_ x: Double) -> Double { x - x.rounded(.down) }
    /// A stable 0...1 number for a name, so a given app or host always lands in the same place.
    static func unit(_ text: String, salt: Int = 0) -> Double {
        var h: UInt64 = 1469598103934665603 &+ UInt64(salt)
        for byte in text.utf8 { h = (h ^ UInt64(byte)) &* 1099511628211 }
        return Double(h % 10_000) / 10_000
    }
    static func short(_ name: String, _ limit: Int = 24) -> String { name.count > limit ? String(name.prefix(limit - 2)) + "…" : name }

    // MARK: Symbols
    @ViewBuilder static func symbolView(_ s: SceneSymbol) -> some View {
        switch s.style {
        case .pillBlue: Text(s.text).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(.white).padding(.horizontal, 6).frame(height: 18).background(Capsule().fill(blue.opacity(0.92)))
        case .pillOrange: Text(s.text).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(.white).padding(.horizontal, 6).frame(height: 18).background(Capsule().fill(Color.orange.opacity(0.92)))
        case .shatter: Text(s.text).font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(Color.orange)
        case .lane: Text(s.text).font(.system(size: 10, weight: .medium)).foregroundStyle(Color.secondary)
        case .node: Text(s.text).font(.system(size: 10, weight: .medium)).foregroundStyle(Color.secondary)
        }
    }

    static func nodeSymbols(_ labels: [String]) -> [SceneSymbol] { labels.map { SceneSymbol(id: "nd:" + $0, text: $0, style: .node) } }

    static func gateSymbols(_ particles: [GateParticle], style: GateStyle) -> [SceneSymbol] {
        var seen = Set<String>(), out: [SceneSymbol] = []
        func add(_ id: String, _ text: String, _ s: SceneSymbol.Style) { if seen.insert(id).inserted { out.append(SceneSymbol(id: id, text: text, style: s)) } }
        for p in particles {
            let name = short(p.name, 26)
            if p.kind == .passed { add("pb:" + name, name, .pillBlue) } else { add("po:" + name, name, .pillOrange); add("sh:" + name, name, .shatter) }
        }
        for label in style.laneLabels where !label.isEmpty { add("ln:" + label, short(label, 16), .lane) }
        return out
    }

    // MARK: Primitives
    static func icon(_ context: inout GraphicsContext, _ name: String, at point: CGPoint, size: CGFloat, color: Color) {
        var image = context.resolve(Image(systemName: name))
        image.shading = .color(color)
        context.draw(image, in: CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size))
    }

    /// A node: a soft disc with an icon, and a label under it (the label is a symbol the scene supplied with `nodeSymbols`).
    static func node(_ context: inout GraphicsContext, icon name: String, label: String, at point: CGPoint, color: Color, glow: Double = 0) {
        if glow > 0 { context.fill(Path(ellipseIn: CGRect(x: point.x - 30, y: point.y - 30, width: 60, height: 60)), with: .color(color.opacity(0.18 * glow))) }
        context.fill(Path(ellipseIn: CGRect(x: point.x - 21, y: point.y - 21, width: 42, height: 42)), with: .color(color.opacity(0.16)))
        context.stroke(Path(ellipseIn: CGRect(x: point.x - 21, y: point.y - 21, width: 42, height: 42)), with: .color(color.opacity(0.55)), lineWidth: 1.2)
        icon(&context, name, at: point, size: 20, color: color)
        if let text = context.resolveSymbol(id: "nd:" + label) { context.draw(text, at: CGPoint(x: point.x, y: point.y + 33)) }
    }

    /// A point along a polyline, 0 at the first point and 1 at the last, by distance.
    static func along(_ points: [CGPoint], _ u: Double) -> CGPoint {
        guard points.count > 1 else { return points.first ?? .zero }
        var lengths: [CGFloat] = []
        var total: CGFloat = 0
        for i in 1..<points.count { let d = hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y); lengths.append(d); total += d }
        var remaining = CGFloat(min(max(u, 0), 1)) * total
        for i in 0..<lengths.count {
            if remaining <= lengths[i] || i == lengths.count - 1 {
                let f = lengths[i] == 0 ? 0 : min(1, remaining / lengths[i])
                return CGPoint(x: points[i].x + (points[i + 1].x - points[i].x) * f, y: points[i].y + (points[i + 1].y - points[i].y) * f)
            }
            remaining -= lengths[i]
        }
        return points.last ?? .zero
    }

    // MARK: The gate scene (a lookup or connection swims towards a shield; allowed ones glide through, blocked ones shatter)
    struct GateStyle: Hashable {
        var leftIcon = "laptopcomputer"
        var rightIcon = "globe"
        var gateIcon = "shield.lefthalf.filled"
        var laneLabels: [String] = []
    }

    static func drawGate(_ context: inout GraphicsContext, size: CGSize, now: Date, particles: [GateParticle], style: GateStyle) {
        let w = size.width, h = size.height
        let labelled = style.laneLabels.contains { !$0.isEmpty }
        let leftX: CGFloat = labelled ? 124 : 76, rightX = w - 76
        let tunnelTop: CGFloat = 36, tunnelHeight: CGFloat = h - 78
        let gateX = leftX + (rightX - leftX) * 0.52
        let orange = Color.orange

        let pipe = CGRect(x: leftX, y: tunnelTop, width: rightX - leftX, height: tunnelHeight)
        context.fill(Path(roundedRect: pipe, cornerRadius: 22), with: .linearGradient(Gradient(colors: [blue.opacity(0.07), blue.opacity(0.16), blue.opacity(0.07)]), startPoint: CGPoint(x: 0, y: pipe.minY), endPoint: CGPoint(x: 0, y: pipe.maxY)))
        context.stroke(Path(roundedRect: pipe, cornerRadius: 22), with: .color(blue.opacity(0.35)), lineWidth: 1.5)
        let phase = fract(now.timeIntervalSinceReferenceDate / 2)
        for i in 0..<14 {
            let x = leftX + 14 + (CGFloat(i) + CGFloat(phase)) * ((rightX - leftX - 28) / 14)
            context.fill(Path(ellipseIn: CGRect(x: x, y: pipe.midY - 1, width: 3, height: 2)), with: .color(blue.opacity(0.18)))
        }
        // With app labels the apps icon sits above the label column, so nothing overlaps it.
        icon(&context, style.leftIcon, at: labelled ? CGPoint(x: leftX - 70, y: tunnelTop - 16) : CGPoint(x: leftX - 36, y: pipe.midY), size: labelled ? 22 : 30, color: .secondary)
        icon(&context, style.rightIcon, at: CGPoint(x: rightX + 36, y: pipe.midY), size: 30, color: blue)
        for (index, label) in style.laneLabels.enumerated() where !label.isEmpty {
            let lane = style.laneLabels.count > 1 ? Double(index) / Double(style.laneLabels.count - 1) : 0.5
            let y = pipe.minY + 14 + CGFloat(lane) * (pipe.height - 28)
            if let text = context.resolveSymbol(id: "ln:" + label) { context.draw(text, at: CGPoint(x: leftX - 10, y: y), anchor: .trailing) }
        }

        var hit: Double = 0
        for p in particles where p.kind == .blocked {
            let t = now.timeIntervalSince(p.born) - travel
            if t >= 0, t < 0.35 { hit = max(hit, 1 - t / 0.35) }
        }
        let wobble = CGFloat(sin(now.timeIntervalSinceReferenceDate * 40) * 3 * hit)
        let shield = CGRect(x: gateX - 5 + wobble, y: pipe.minY - 10, width: 10, height: pipe.height + 20)
        context.fill(Path(roundedRect: shield.insetBy(dx: -8 * hit, dy: 0), cornerRadius: 5), with: .color(orange.opacity(0.10 + 0.35 * hit)))
        context.fill(Path(roundedRect: shield, cornerRadius: 5), with: .linearGradient(Gradient(colors: [orange, orange.opacity(0.65)]), startPoint: CGPoint(x: shield.minX, y: 0), endPoint: CGPoint(x: shield.maxX, y: 0)))
        icon(&context, style.gateIcon, at: CGPoint(x: gateX + wobble, y: pipe.minY - 22), size: 18, color: orange)

        for p in particles {
            let t = now.timeIntervalSince(p.born)
            guard t >= 0 else { continue }
            let name = short(p.name, 26)
            let y = pipe.minY + 14 + CGFloat(p.lane) * (pipe.height - 28)
            if t < travel {
                let x = leftX + 6 + (gateX - 14 - (leftX + 6)) * ease(t / travel)
                chip(&context, id: (p.kind == .passed ? "pb:" : "po:") + name, at: CGPoint(x: x, y: y), alpha: min(1, t / 0.2), glow: false, tint: p.kind == .passed ? blue : orange)
            } else if p.kind == .passed {
                let u = (t - travel) / afterGate
                guard u < 1 else { continue }
                let x = gateX - 14 + (rightX - gateX + 8) * ease(u)
                chip(&context, id: "pb:" + name, at: CGPoint(x: x, y: y), alpha: 1 - max(0, (u - 0.6) / 0.4), glow: true, tint: blue)
            } else {
                let u = (t - travel) / 0.8
                guard u < 1 else { continue }
                shatter(&context, p, name: name, y: y, gateX: gateX, u: u)
            }
        }
    }

    private static func chip(_ context: inout GraphicsContext, id: String, at point: CGPoint, alpha: Double, glow: Bool, tint: Color) {
        guard let symbol = context.resolveSymbol(id: id) else { return }
        var c = context
        c.opacity = alpha
        if glow { c.fill(Path(roundedRect: CGRect(x: point.x - symbol.size.width / 2 - 3, y: point.y - symbol.size.height / 2 - 3, width: symbol.size.width + 6, height: symbol.size.height + 6), cornerRadius: 12), with: .color(tint.opacity(0.25))) }
        c.draw(symbol, at: point)
    }

    private static func shatter(_ context: inout GraphicsContext, _ p: GateParticle, name: String, y: CGFloat, gateX: CGFloat, u: Double) {
        var c = context
        c.opacity = 1 - u
        let origin = CGPoint(x: gateX - 14, y: y)
        let seed = unit(p.name, salt: Int(p.lane * 1000))
        for i in 0..<7 {
            let angle = (Double(i) / 7) * 2 * .pi + seed * 2
            let speed = 26 + 24 * Double((i * 37 + Int(seed * 100)) % 10) / 10
            let dx = -abs(cos(angle)) * speed * u * 1.1 - 4 * u
            let dy = sin(angle) * speed * u + 38 * u * u
            let size: CGFloat = 5 - CGFloat(u) * 2.5
            c.fill(Path(roundedRect: CGRect(x: origin.x + dx, y: origin.y + dy, width: size, height: size), cornerRadius: 1.5), with: .color(Color.orange))
        }
        c.stroke(Path(ellipseIn: CGRect(x: origin.x - 6 - 16 * u, y: origin.y - 6 - 16 * u, width: 12 + 32 * u, height: 12 + 32 * u)), with: .color(Color.orange.opacity(0.7)), lineWidth: 1.5)
        if let label = c.resolveSymbol(id: "sh:" + name) { c.draw(label, at: CGPoint(x: origin.x - 18, y: origin.y + 14 + 30 * CGFloat(u * u))) }
    }
}


/// A timeline for a scene: 30 frames a second while the window is in front, and nothing at all while it is not, so a scene left behind
/// another window costs no power.
struct SceneTimeline<Content: View>: View {
    @Environment(\.controlActiveState) private var active
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Seconds between frames. A scene that is only idling does not need the full rate.
    var interval = SceneDraw.frameInterval
    /// True when the scene has nothing to show that changes (protection off): it keeps its last frame and draws no more.
    var held = false
    @ViewBuilder let content: (TimelineViewDefaultContext) -> Content
    var body: some View {
        // Every few seconds this asks whether anybody is there to see the animation; the frames themselves stop when nobody is.
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
            let runs = SceneActivity.animates(windowActive: active != .inactive, held: held, idleSeconds: idle, reduceMotion: reduceMotion)
            TimelineView(.animation(minimumInterval: interval, paused: !runs)) { context in content(context) }
        }
    }
}

/// The scenes loop for as long as they are on screen, so each carries a pause button (and Settings has the same switch). Paused scenes show a
/// plain summary instead.
struct ScenePauseButton: View {
    @AppStorage("animated-scenes") private var animated = true
    var body: some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { animated.toggle() } } label: {
            Image(systemName: animated ? "pause.circle" : "play.circle").font(.system(size: 14))
        }.buttonStyle(.plain).foregroundStyle(.secondary)
            .help(animated ? "Pause the animated scenes" : "Play the animated scenes")
            .accessibilityLabel(animated ? "Pause animated scenes" : "Play animated scenes")
    }
}
