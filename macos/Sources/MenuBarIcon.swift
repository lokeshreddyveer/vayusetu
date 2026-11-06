import AppKit
import Combine
import SwiftUI
import VayuSetuCore

/// What the menu bar icon says about protection, from what has been observed.
enum MenuBarState: Equatable, Hashable {
    case off            // nothing is switched on
    case working        // everything switched on has been seen working
    case unverified     // switched on, not yet seen working
    case problem        // something switched on failed its check
    var colour: Color? { switch self { case .off: nil; case .working: .green; case .unverified: .orange; case .problem: .red } }
    var nsColour: NSColor? { switch self { case .off: nil; case .working: .systemGreen; case .unverified: .systemOrange; case .problem: .systemRed } }
}

/// The icon as a real image, drawn each time it is shown so the arch takes the menu bar's own text colour (light or dark). Handing the
/// menu bar an image, rather than a SwiftUI view, is what status items expect; a view-based label did not appear at all.
enum MenuBarImage {
    /// One image per state, kept. Its drawing code reads the menu bar's text colour when it is drawn, so one image serves light and dark.
    /// Making a new image on every redraw (as this used to) allocated and drew one each time anything in the app changed.
    private static var cache: [MenuBarState: NSImage] = [:]
    static func image(_ state: MenuBarState) -> NSImage {
        if let kept = cache[state] { return kept }
        let made = make(state); cache[state] = made; return made
    }
    private static func make(_ state: MenuBarState) -> NSImage {
        let image = NSImage(size: NSSize(width: 21, height: 18), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setLineWidth(1.7); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.setStrokeColor(NSColor.labelColor.withAlphaComponent(state == .off ? 0.62 : 1).cgColor)
            ctx.addPath(MenuBarArch().path(in: CGRect(x: 1, y: 2, width: 17, height: 12)).cgPath)
            ctx.strokePath()
            if let colour = state.nsColour {
                let dot = CGRect(x: 12.5, y: 9.5, width: 6.5, height: 6.5)
                ctx.setFillColor(colour.cgColor); ctx.fillEllipse(in: dot)
                ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.35).cgColor); ctx.setLineWidth(0.5); ctx.strokeEllipse(in: dot)
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// The VayuSetu mark for the menu bar: a bridge (setu) made of one arch of air (vayu), two strokes, drawn as vectors so it is sharp at
/// every size and takes the menu bar's own colour. A small dot in the corner shows the state.
struct MenuBarArch: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        // outer arch
        p.move(to: CGPoint(x: rect.minX + w * 0.02, y: rect.minY + h * 0.80))
        p.addCurve(to: CGPoint(x: rect.minX + w * 0.5, y: rect.minY + h * 0.14), control1: CGPoint(x: rect.minX + w * 0.40, y: rect.minY + h * 0.80), control2: CGPoint(x: rect.minX + w * 0.20, y: rect.minY + h * 0.14))
        p.addCurve(to: CGPoint(x: rect.minX + w * 0.96, y: rect.minY + h * 0.78), control1: CGPoint(x: rect.minX + w * 0.80, y: rect.minY + h * 0.14), control2: CGPoint(x: rect.minX + w * 0.60, y: rect.minY + h * 0.80))
        // inner arch (the second ribbon)
        p.move(to: CGPoint(x: rect.minX + w * 0.24, y: rect.minY + h * 0.80))
        p.addCurve(to: CGPoint(x: rect.minX + w * 0.5, y: rect.minY + h * 0.46), control1: CGPoint(x: rect.minX + w * 0.40, y: rect.minY + h * 0.80), control2: CGPoint(x: rect.minX + w * 0.34, y: rect.minY + h * 0.46))
        p.addCurve(to: CGPoint(x: rect.minX + w * 0.76, y: rect.minY + h * 0.78), control1: CGPoint(x: rect.minX + w * 0.66, y: rect.minY + h * 0.46), control2: CGPoint(x: rect.minX + w * 0.60, y: rect.minY + h * 0.80))
        return p
    }
}

/// What the menu bar label needs, worked out at most every two seconds and published only when it changes. The label used to observe the whole
/// app, the tunnel and the network filter directly: every update from any of them (the tunnel's counters, live connections) re-ran the whole
/// protection check and drew a new image, many times a second for as long as the app was open.
@MainActor final class MenuBarStateModel: ObservableObject {
    @Published private(set) var state: MenuBarState = .off
    @Published private(set) var headline = "VayuSetu, off"
    private let store: AppStore, tunnel: TunnelController, filter: FilterClient
    private var subscriptions = Set<AnyCancellable>()
    init(store: AppStore, tunnel: TunnelController, filter: FilterClient) {
        self.store = store; self.tunnel = tunnel; self.filter = filter
        // objectWillChange fires before the change lands, so look a moment later; the throttle keeps a burst of updates to one look per 2 s,
        // and `latest` guarantees the last change in a burst is looked at.
        Publishers.MergeMany(store.objectWillChange.map { _ in () }, tunnel.objectWillChange.map { _ in () }, filter.objectWillChange.map { _ in () })
            .throttle(for: .seconds(2), scheduler: RunLoop.main, latest: true)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() }.store(in: &subscriptions)
        // Evidence also goes stale with time alone (a check expires), so look every ten seconds even when nothing changes.
        Timer.publish(every: 10, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        refresh()
    }
    func refresh() {
        let now = Date()
        let proof = ProtectionProofEngine.evaluate(MacProofSource.observations(store: store, tunnel: tunnel, filter: filter, now: now), now: now)
        let newState = MenuBarLabel.state(for: proof)
        let newHeadline = proof.verdict == .off ? "VayuSetu, off" : "VayuSetu. " + proof.headline
        if newState != state { state = newState }
        if newHeadline != headline { headline = newHeadline }
    }
}

/// The menu bar label: the mark, and a state that comes from the same evidence as the "Is it working?" panel.
struct MenuBarLabel: View {
    @StateObject private var model: MenuBarStateModel
    @Environment(\.colorScheme) private var scheme
    init(store: AppStore, tunnel: TunnelController, filter: FilterClient) { _model = StateObject(wrappedValue: MenuBarStateModel(store: store, tunnel: tunnel, filter: filter)) }

    static func state(for proof: ProtectionProof) -> MenuBarState {
        switch proof.verdict {
        case .off: return .off
        case .protected: return .working
        case .notProtected: return .problem
        case .partial: return proof.checks.contains { $0.outcome == .failed } ? .problem : .unverified
        }
    }
    var body: some View {
        Image(nsImage: MenuBarImage.image(model.state))
            .id(scheme)
            .accessibilityLabel(model.headline)
    }
}
