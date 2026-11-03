import SwiftUI

/// Lays its children out left to right and starts a new line when the row is full, so a form made of several controls stays usable in
/// a narrow window instead of squeezing a text field to nothing or running past the edge.
struct MacWrap: Layout {
    var spacing: CGFloat = 10
    var lineSpacing: CGFloat = 10
    /// Lines the items would fall into at this width: each line's item indexes, and its height.
    private func lines(width: CGFloat, subviews: Subviews) -> [(items: [Int], height: CGFloat)] {
        var out: [(items: [Int], height: CGFloat)] = []; var current: [Int] = []; var x: CGFloat = 0, height: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.init(width: width.isFinite ? width : nil, height: nil))
            if x > 0, x + size.width > width { out.append((current, height)); current = []; x = 0; height = 0 }
            current.append(index); x += size.width + spacing; height = max(height, size.height)
        }
        if !current.isEmpty { out.append((current, height)) }
        return out
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.init(width: width.isFinite ? width : nil, height: nil))
            if x > 0, x + size.width > width { widest = max(widest, x - spacing); x = 0; y += line + lineSpacing; line = 0 }
            x += size.width + spacing; line = max(line, size.height)
        }
        widest = max(widest, x - spacing)
        return CGSize(width: width.isFinite ? width : widest, height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in line.items {
                let size = subviews[index].sizeThatFits(.init(width: bounds.width, height: nil))
                // each item is centred in its line, so a tall search box and a short checkbox share one centre line
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2), anchor: .topLeading, proposal: .init(width: min(size.width, bounds.width), height: size.height))
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }
}

/// A segmented control drawn by VayuSetu, so every segment has the same height as the buttons and fields beside it and the left edge sits exactly
/// on the content edge. The system one added its own inset and a different height.
struct MacSegmented<Option: Hashable>: View {
    @Binding var selection: Option
    let options: [Option]
    let title: (Option) -> String
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let chosen = option == selection
                Button { selection = option } label: {
                    Text(title(option)).font(.system(size: 13, weight: chosen ? .semibold : .regular))
                        .foregroundStyle(chosen ? VSDesign.actionInk : Color.primary.opacity(0.85))
                        .padding(.horizontal, 14).frame(height: 24)
                        .background(chosen ? VSDesign.accent : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(chosen ? .isSelected : []).perfTarget("tab.\(title(option))")
            }
        }
        .padding(2).background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous)).fixedSize()
    }
}
