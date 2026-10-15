import AppKit
import SwiftUI

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
                Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(1.1).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                trailing
            }
            content
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).macPanel()
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
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 26, weight: .semibold, design: .rounded))
                    if !subtitle.isEmpty { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
                }
                content
            }.padding(28).frame(maxWidth: 1180, alignment: .leading).frame(maxWidth: .infinity)
        }.scrollIndicators(.automatic).background(VSDesign.background).navigationTitle(title)
    }
}

/// A row with an icon tile, a title and detail text, and a control on the right (a switch, a menu or a button).
struct MacRow<Control: View>: View {
    let icon: String
    let title: String
    var detail = ""
    var tint: Color = VSDesign.accent
    @ViewBuilder var control: Control
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 34, height: 34).background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if !detail.isEmpty { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 10)
            control
        }.padding(.vertical, 4)
    }
}

/// A big number with a caption, for live figures.
struct MacFigure: View {
    let caption: String
    let value: String
    var tint: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(caption).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.6)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MacChip: View {
    let text: String
    var tint: Color = .secondary
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 3).background(tint.opacity(0.14), in: Capsule())
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
            .onHover { hovering = $0 }
    }
}
