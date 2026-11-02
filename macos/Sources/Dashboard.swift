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
    func macPanel() -> some View {
        background(VSDesign.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.primary.opacity(0.055), lineWidth: 1))
    }
}
