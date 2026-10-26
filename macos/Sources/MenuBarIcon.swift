import AppKit
import SwiftUI
import VayuSetuCore

/// What the menu bar icon says about protection, from what has been observed.
enum MenuBarState: Equatable {
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
    static func make(_ state: MenuBarState) -> NSImage {
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

struct MenuBarIcon: View {
    let state: MenuBarState
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            MenuBarArch()
                .stroke(.primary.opacity(state == .off ? 0.62 : 1), style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                .frame(width: 18, height: 13)
                .padding(.trailing, 2).padding(.bottom, 2)
            if let colour = state.colour {
                Circle().fill(colour).frame(width: 6, height: 6)
                    .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 0.5))
                    .offset(x: 1.5, y: 1.5)
            }
        }.frame(width: 21, height: 18)
    }
}

/// The menu bar label: the mark, and a state that comes from the same evidence as the "Is it working?" panel.
struct MenuBarLabel: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    @ObservedObject var filter: FilterClient
    @State private var now = Date()
    private let tick = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    static func state(for proof: ProtectionProof) -> MenuBarState {
        switch proof.verdict {
        case .off: return .off
        case .protected: return .working
        case .notProtected: return .problem
        case .partial: return proof.checks.contains { $0.outcome == .failed } ? .problem : .unverified
        }
    }
    private var proof: ProtectionProof { ProtectionProofEngine.evaluate(MacProofSource.observations(store: store, tunnel: tunnel, filter: filter, now: now), now: now) }
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let state = Self.state(for: proof)
        Image(nsImage: MenuBarImage.make(state))
            .id(scheme)
            .onReceive(tick) { now = $0 }
            .accessibilityLabel(proof.verdict == .off ? "VayuSetu, off" : "VayuSetu. " + proof.headline)
    }
}
