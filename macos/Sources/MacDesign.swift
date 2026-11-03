import AppKit
import SwiftUI

/// Two readable columns when space permits, otherwise one. Each column grows
/// independently so a tall panel does not leave an empty grid cell beside it.
struct MacPanelLayout: Layout {
    var minimumColumnWidth: CGFloat = 440
    var spacing: CGFloat = 16

    /// The column count is sticky: it changes only once the width is clearly past the switch point. Without that, a width near the point flips
    /// one column ⇄ two, the page height changes, the scroll bar comes and goes, the width moves by its thickness, and layout never settles.
    struct Cache { var columns: Int? }
    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) {}
    private static let margin: CGFloat = 24
    private func columns(for width: CGFloat, _ cache: inout Cache) -> Int {
        let switchPoint = minimumColumnWidth * 2 + spacing
        let count: Int
        switch cache.columns {
        case 2?: count = width < switchPoint - Self.margin ? 1 : 2
        case 1?: count = width >= switchPoint + Self.margin ? 2 : 1
        default: count = width >= switchPoint ? 2 : 1
        }
        cache.columns = count
        return count
    }

    private func arrangement(width: CGFloat, columns: Int, subviews: Subviews) -> (height: CGFloat, frames: [CGRect]) {
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

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? minimumColumnWidth
        return CGSize(width: width, height: arrangement(width: width, columns: columns(for: width, &cache), subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        for (view, frame) in zip(subviews, arrangement(width: bounds.width, columns: columns(for: bounds.width, &cache), subviews: subviews).frames) {
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
            HStack(spacing: 9) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(VSDesign.accent)
                        .frame(width: 24, height: 24).background(VSDesign.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary).lineLimit(1).layoutPriority(1)
                Spacer(minLength: 8)
                trailing.fixedSize()
            }
            content.lineSpacing(1.5)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading).macPanel().macAppear()
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
                HStack(alignment: .center, spacing: 14) {
                    if let icon = Page(rawValue: title)?.icon {
                        Image(systemName: icon).font(.system(size: 19, weight: .semibold)).foregroundStyle(VSDesign.actionInk)
                            .frame(width: 44, height: 44)
                            .background(LinearGradient(colors: [VSDesign.accent, VSDesign.accent.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: 26, weight: .bold, design: .rounded))
                        if !subtitle.isEmpty { Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary) }
                    }
                }.padding(.bottom, 4)
                content
            }.frame(maxWidth: 1120, alignment: .leading).padding(.horizontal, 28).padding(.vertical, 26).frame(maxWidth: .infinity, alignment: .top)
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

/// Background reading for a panel: a short "How this works" line that opens to the full explanation, so the panel leads with what it shows
/// and does instead of a paragraph.
struct MacExplainer: View {
    let text: String
    var title = "How this works"
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { open.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "info.circle")
                    Text(title)
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(open ? 90 : 0))
                }.font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityHint(open ? "Hides the explanation" : "Shows the explanation")
            if open {
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }.macAnimate(.easeInOut(duration: 0.22), value: open)
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
            .foregroundStyle(prominent ? VSDesign.actionInk : VSDesign.accent)
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
