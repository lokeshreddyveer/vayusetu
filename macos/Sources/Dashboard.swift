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

extension View {
    /// A raised card: the surface colour with a faint light from above, a hairline edge that is brighter at the top, and a soft shadow.
    /// The shadow sits on the background shape only, so the content is not rendered offscreen and scrolling stays cheap.
    func macPanel() -> some View {
        let shape = RoundedRectangle(cornerRadius: VSDesign.panelRadius, style: .continuous)
        return background(
            shape.fill(VSDesign.surface)
                .overlay(shape.fill(LinearGradient(colors: [Color.white.opacity(0.035), .clear], startPoint: .top, endPoint: .center)))
                .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
        )
        .overlay(shape.strokeBorder(LinearGradient(colors: [Color.primary.opacity(0.11), Color.primary.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
    }
}
