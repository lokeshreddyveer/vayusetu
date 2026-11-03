import AppKit
import SwiftUI
import NetworkExtension

struct MacBrandArtwork: View {
    private static let artwork = Bundle.main.url(forResource: "BrandArtwork", withExtension: "png").flatMap(NSImage.init(contentsOf:))
    var body: some View {
        if let image = Self.artwork { Image(nsImage: image).resizable().scaledToFit() }
        else { Image(systemName: "wind").resizable().scaledToFit().foregroundStyle(VSDesign.accent) }
    }
}

/// A raised card: the surface colour with a faint light from above and a hairline edge that is brighter at the top. There is deliberately no
/// drop shadow: SwiftUI blurs a shadow on the CPU every time the page redraws, which measured at about 3.4 points of CPU on Home alone.
private struct MacPanelStyle: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: VSDesign.panelRadius, style: .continuous)
        content
            .background(
                shape.fill(VSDesign.surface)
                    .overlay(shape.fill(LinearGradient(colors: [Color.white.opacity(0.04), .clear], startPoint: .top, endPoint: .center)))
            )
            .overlay(shape.strokeBorder(LinearGradient(colors: [Color.primary.opacity(0.12), Color.primary.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
    }
}
extension View {
    func macPanel() -> some View { modifier(MacPanelStyle()) }
}
