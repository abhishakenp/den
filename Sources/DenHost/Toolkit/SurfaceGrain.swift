import AppKit

/// The space's grain on a themed surface (dialogs, the command bar, popovers): the window's noise
/// tile at half the window's strength, so a grainy theme's dialogs feel like the same paper. One
/// shared tile, one sublayer per surface, removed when the theme has no grain.
@MainActor
enum SurfaceGrain {
  static let layerName = "den.surfaceGrain"

  static func apply(to v: NSView, palette p: Palette) {
    v.wantsLayer = true
    guard let host = v.layer else { return }
    let existing = host.sublayers?.first { $0.name == layerName }
    let g = p.tokens.grain
    guard g >= 0.01, let tile = p.dark ? ThemeBackgroundView.noiseLight : ThemeBackgroundView.noise else {
      existing?.removeFromSuperlayer()
      return
    }
    let l = existing ?? CALayer()
    if existing == nil {
      l.name = layerName
      l.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
      host.insertSublayer(l, at: 0)
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    l.frame = host.bounds
    let size = NSSize(width: Tokens.grainTileSize, height: Tokens.grainTileSize)
    l.backgroundColor = NSColor(patternImage: NSImage(cgImage: tile, size: size)).cgColor
    l.opacity = Float(min(1, g * Tokens.grainMaxAlpha * 2))
    CATransaction.commit()
  }
}
