import SwiftUI
import AppKit

// MARK: - Visual effect background

/// SwiftUI wrapper around NSVisualEffectView. Placed behind ContentView so the
/// window picks up macOS's native blurred-translucency look (adapts to dark/light
/// mode automatically, blurs whatever's behind the window).
struct VisualEffectBackground: NSViewRepresentable {
    let material:     NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material     = material
        v.blendingMode = blendingMode
        v.state        = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material     = material
        nsView.blendingMode = blendingMode
    }
}
