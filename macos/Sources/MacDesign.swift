import AppKit
import SwiftUI

/// Two readable columns when space permits, otherwise one. Each column grows
/// independently so a tall panel does not leave an empty grid cell beside it.
struct MacPanelLayout: Layout {
    var minimumColumnWidth: CGFloat = 440
    var spacing: CGFloat = 16

    private func arrangement(width: CGFloat, subviews: Subviews) -> (height: CGFloat, frames: [CGRect]) {
        let columns = width >= minimumColumnWidth * 2 + spacing ? 2 : 1
        let columnWidth = max(0, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        var heights = Array(repeating: CGFloat.zero, count: columns)
        var frames: [CGRect] = []
        for view in subviews {
            let column = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            let size = view.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))
            frames.append(CGRect(x: CGFloat(column) * (columnWidth + spacing), y: heights[column], width: columnWidth, height: size.height))
            heights[column] += size.height + spacing
        }
        return (max(0, (heights.max() ?? 0) - spacing), frames)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minimumColumnWidth
        return CGSize(width: width, height: arrangement(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, arrangement(width: bounds.width, subviews: subviews).frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                       proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}

/// The Mac look: wide, calm panels with a header row, hairline edges, hover feedback and desktop-sized controls.
/// The pages that use it read the same stores and call the same actions as the iPhone app; only the layout is different.
struct MacPanel<Content: View, Trailing: View>: View {
    let title: String
    var icon: String?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(VSDesign.accent) }
                Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(1.1).foregroundStyle(.secondary).lineLimit(1).layoutPriority(1)
                Spacer(minLength: 8)
                trailing.fixedSize()
            }
            content
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).macPanel().macAppear()
    }
}
extension MacPanel where Trailing == EmptyView {
    init(_ title: String, icon: String? = nil, @ViewBuilder content: () -> Content) { self.title = title; self.icon = icon; self.trailing = EmptyView(); self.content = content() }
}
extension MacPanel {
    init(_ title: String, icon: String? = nil, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) { self.title = title; self.icon = icon; self.trailing = trailing(); self.content = content() }
}

/// A page: a title bar area with a headline and one-line description, then the content, centred in a readable width.
struct MacPage<Content: View>: View {
    let title: String
    var subtitle = ""
    @ViewBuilder var content: Content
    @Environment(\.extensionManager) private var extensions
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let extensions { ExtensionBanner(extensions: extensions) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 26, weight: .semibold, design: .rounded))
                    if !subtitle.isEmpty { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
                }
                content
            }.frame(maxWidth: 1120, alignment: .leading).padding(24).frame(maxWidth: .infinity, alignment: .topLeading)
        }.scrollIndicators(.hidden).background(VSDesign.background).navigationTitle(title)
    }
}

/// Places a row's icon tile, text and control: side by side when the control and a readable column of text both fit, otherwise the control
/// drops under the text. (ViewThatFits cannot do this, because it judges a line of text by its unwrapped width.)
private struct MacRowLayout: Layout {
    var minimumText: CGFloat = 170
    var spacing: CGFloat = 12
    /// A row's control is optional: a row with no control (for example one whose checkmark is not showing) gives the layout only two subviews,
    /// and reading a third one used to trap. A missing control simply takes no room.
    private func sizes(_ subviews: Subviews, width: CGFloat) -> (side: Bool, text: CGSize, control: CGSize, tile: CGSize) {
        guard subviews.count >= 2 else { return (true, .zero, .zero, .zero) }
        let tile = subviews[0].sizeThatFits(.unspecified)
        let control = subviews.count > 2 ? subviews[2].sizeThatFits(.unspecified) : .zero
        let side = tile.width + spacing + minimumText + 10 + control.width <= width
        let textWidth = side ? width - tile.width - spacing - (control.width > 0 ? 10 + control.width + spacing : 0) : width - tile.width - spacing
        let text = subviews[1].sizeThatFits(ProposedViewSize(width: max(60, textWidth), height: nil))
        return (side, text, control, tile)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 520
        let m = sizes(subviews, width: width)
        let height = m.side ? max(m.tile.height, m.text.height, m.control.height) : max(m.tile.height, m.text.height) + (m.control.height > 0 ? 8 + m.control.height : 0)
        return CGSize(width: width, height: height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count >= 2 else { return }
        let m = sizes(subviews, width: bounds.width)
        let textX = bounds.minX + m.tile.width + spacing
        let hasControl = subviews.count > 2
        if m.side {
            let h = max(m.tile.height, m.text.height, m.control.height)
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + (h - m.tile.height) / 2), anchor: .topLeading, proposal: .unspecified)
            subviews[1].place(at: CGPoint(x: textX, y: bounds.minY + (h - m.text.height) / 2), anchor: .topLeading, proposal: ProposedViewSize(width: m.text.width, height: m.text.height))
            if hasControl { subviews[2].place(at: CGPoint(x: bounds.maxX - m.control.width, y: bounds.minY + (h - m.control.height) / 2), anchor: .topLeading, proposal: .unspecified) }
        } else {
            let top = max(m.tile.height, m.text.height)
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading, proposal: .unspecified)
            subviews[1].place(at: CGPoint(x: textX, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(width: m.text.width, height: m.text.height))
            if hasControl { subviews[2].place(at: CGPoint(x: textX, y: bounds.minY + top + 8), anchor: .topLeading, proposal: .unspecified) }
        }
    }
}

/// A row with an icon tile, a title and detail text, and a control on the right (a switch, a menu or a button). The control keeps its natural
/// size; if the row is too narrow for both, the control moves below the text instead of squeezing it into a column of single letters.
struct MacRow<Control: View>: View {
    let icon: String
    let title: String
    var detail = ""
    var tint: Color = VSDesign.accent
    @ViewBuilder var control: Control
    var body: some View {
        MacRowLayout {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 34, height: 34).background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .macAnimate(.easeInOut(duration: 0.3), value: detail)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                if !detail.isEmpty { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).contentTransition(.opacity).macAnimate(value: detail) }
            }
            control.fixedSize()
        }.padding(.vertical, 4)
    }
}

/// A big number with a caption, for live figures.
struct MacFigure: View {
    let caption: String
    let value: String
    var tint: Color = .primary
    /// Counts that change now and then roll from one number to the next. Figures that update every second (speeds) just change: rolling them
    /// every second leaves the digits permanently half-blurred.
    var rolls = false
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(caption).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.6)
                .contentTransition(rolls ? .numericText() : .identity).macAnimate(.smooth(duration: 0.35), value: rolls ? value : "")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MacChip: View {
    let text: String
    var tint: Color = .secondary
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 3).background(tint.opacity(0.14), in: Capsule())
            .contentTransition(.interpolate).macAnimate(.easeInOut(duration: 0.25), value: text)
    }
}

/// A button that lightens under the pointer, as Mac controls do.
struct MacHoverButtonStyle: ButtonStyle {
    var prominent = false
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundStyle(prominent ? Color.white : VSDesign.accent)
            .background((prominent ? VSDesign.accent : VSDesign.accent.opacity(hovering ? 0.22 : 0.13)).opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .macAnimate(.easeOut(duration: 0.12), value: configuration.isPressed).macAnimate(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
    }
}


// MARK: - Motion
/// Motion that respects "Reduce motion": the animation is dropped, and the change simply happens.
private struct MacAnimate<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View { content.animation(reduceMotion ? nil : animation, value: value) }
}
extension View {
    /// Animates changes of `value`, unless the user has asked for reduced motion.
    func macAnimate<Value: Equatable>(_ animation: Animation = .easeInOut(duration: 0.25), value: Value) -> some View { modifier(MacAnimate(animation: animation, value: value)) }
}

/// A panel eases in the first time it appears (a short fade and rise), so a page does not pop into place.
private struct MacAppear: ViewModifier {
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.opacity(shown || reduceMotion ? 1 : 0).offset(y: shown || reduceMotion ? 0 : 8)
            .onAppear { withAnimation(.easeOut(duration: 0.3)) { shown = true } }
    }
}
extension View { func macAppear() -> some View { modifier(MacAppear()) } }
