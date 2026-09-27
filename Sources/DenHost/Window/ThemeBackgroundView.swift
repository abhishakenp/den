import AppKit

extension RGB {
  public var ns: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
  public var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
}

/// Fills the whole window with the space theme: a linear gradient of up to 3 colors, washed
/// toward a light/dark base by intensity, with a tiled noise layer for grain.
/// Draws in `draw(_:)` (not sublayers) so `cacheDisplay` snapshots capture it.
public final class ThemeBackgroundView: NSView {
  public var theme = Theme() { didSet { if theme != oldValue { needsDisplay = true } } }

  public override var isFlipped: Bool { true }
  public override var mouseDownCanMoveWindow: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
  }
  required init?(coder: NSCoder) { fatalError() }

  public var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

  public var onAppearanceChange: (() -> Void)?
  public override func viewDidChangeEffectiveAppearance() {
    needsDisplay = true
    onAppearanceChange?()
  }

  public override func draw(_ dirtyRect: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    let stops = theme.stops(dark: isDark)
    let colors = stops.map(\.cg) as CFArray
    let locs: [CGFloat] = stops.count == 2 ? [0, 1] : [0, 0.5, 1]
    if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: locs) {
      // Top-left to bottom-right (flipped view: y grows down).
      ctx.drawLinearGradient(g, start: CGPoint(x: bounds.minX, y: bounds.minY), end: CGPoint(x: bounds.maxX * 0.9, y: bounds.maxY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    if theme.grain > 0.001, let noise = Self.noise {
      ctx.saveGState()
      ctx.setAlpha(theme.grain * Tokens.grainMaxAlpha)
      ctx.setBlendMode(isDark ? .screen : .multiply)
      let s = CGFloat(Tokens.grainTileSize)
      ctx.draw(noise, in: CGRect(x: 0, y: 0, width: s, height: s), byTiling: true)
      ctx.restoreGState()
    }
  }

  /// Grayscale noise tile, generated once (deterministic LCG so snapshots are stable).
  nonisolated(unsafe) static let noise: CGImage? = {
    let n = Tokens.grainTileSize
    var px = [UInt8](repeating: 0, count: n * n)
    var seed: UInt32 = 0x9E37_79B9
    for i in 0..<px.count {
      seed = seed &* 1_664_525 &+ 1_013_904_223
      px[i] = UInt8(truncatingIfNeeded: seed >> 24)
    }
    guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
    return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: n, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }()
}

/// The inset rounded "card" holding web content: an outer view carrying the shadow and an
/// inner clipping view with the corner radius.
public final class CardView: NSView {
  public let clip = NSView()
  public var cornerRadius: CGFloat = Tokens.cardCornerRadius { didSet { applyStyle() } }
  /// Focused pane in a split: a slightly stronger outline.
  public var focused = false { didSet { if focused != oldValue { updateColors() } } }

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    clip.wantsLayer = true
    addSubview(clip)
    applyStyle()
  }
  required init?(coder: NSCoder) { fatalError() }

  private func applyStyle() {
    guard let layer, let cl = clip.layer else { return }
    layer.masksToBounds = false
    layer.shadowColor = NSColor.black.cgColor
    layer.shadowOpacity = Tokens.cardShadowOpacity
    layer.shadowRadius = Tokens.cardShadowRadius
    layer.shadowOffset = CGSize(width: 0, height: Tokens.cardShadowOffsetY)
    cl.cornerRadius = cornerRadius
    cl.cornerCurve = .continuous
    cl.masksToBounds = true
    cl.borderWidth = 0.5
    updateColors()
  }

  public override func viewDidChangeEffectiveAppearance() { updateColors() }

  private func updateColors() {
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    clip.layer?.backgroundColor = (dark ? NSColor(white: 0.13, alpha: 1) : NSColor.white).cgColor
    clip.layer?.borderColor = NSColor(white: dark ? 1 : 0, alpha: Tokens.cardBorderOpacity * (dark ? 1.5 : 1) * (focused ? 4 : 1)).cgColor
    clip.layer?.borderWidth = focused ? 1.5 : 0.5
  }

  public override func layout() {
    super.layout()
    clip.frame = bounds
    layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    for v in clip.subviews { v.frame = clip.bounds }
  }
}
