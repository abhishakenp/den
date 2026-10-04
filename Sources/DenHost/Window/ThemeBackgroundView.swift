import AppKit

extension RGB {
  public var ns: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
  public var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
}

/// Fills the whole window with the space theme: a linear gradient of up to 3 colors, washed
/// toward a light/dark base by intensity, with a tiled noise layer for grain.
/// Both are CALayers composited by the render server: CPU-drawing the full window cost
/// ~75 ms at launch (measured), the layers cost nothing on the main thread.
public final class ThemeBackgroundView: NSView {
  public var theme = Theme() { didSet { if theme != oldValue { applyTheme() } } }
  private let gradient = CAGradientLayer()
  private let grain = CALayer()

  public override var isFlipped: Bool { true }
  public override var mouseDownCanMoveWindow: Bool { true }
  public override var wantsUpdateLayer: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.addSublayer(gradient)
    layer?.addSublayer(grain)
    gradient.startPoint = CGPoint(x: 0, y: 0)
    gradient.endPoint = CGPoint(x: 0.9, y: 1)
    applyTheme()
  }
  required init?(coder: NSCoder) { fatalError() }

  public var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

  public var onAppearanceChange: (() -> Void)?
  public override func viewDidChangeEffectiveAppearance() {
    applyTheme()
    onAppearanceChange?()
  }

  public override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    gradient.frame = bounds
    grain.frame = bounds
    CATransaction.commit()
  }

  func applyTheme() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let dark = isDark
    let stops = theme.stops(dark: dark)
    gradient.colors = stops.map(\.cg)
    gradient.locations = stops.count == 2 ? [0, 1] : [0, 0.5, 1]
    let tile = dark ? Self.noiseLight : Self.noise
    grain.backgroundColor = tile.map { NSColor(patternImage: NSImage(cgImage: $0, size: NSSize(width: Tokens.grainTileSize, height: Tokens.grainTileSize))).cgColor }
    grain.opacity = Float(min(1, theme.grain * Tokens.grainMaxAlpha * 2))
    grain.isHidden = theme.grain < 0.001
    CATransaction.commit()
  }

  /// Speckle tiles (dark specks for light mode, light specks for dark mode) with per-pixel
  /// alpha, generated once with a deterministic LCG so snapshots are stable.
  nonisolated(unsafe) static let noise: CGImage? = makeNoise(white: false)
  nonisolated(unsafe) static let noiseLight: CGImage? = makeNoise(white: true)

  nonisolated static func makeNoise(white: Bool) -> CGImage? {
    let n = Tokens.grainTileSize
    var px = [UInt8](repeating: 0, count: n * n * 4)
    var seed: UInt32 = 0x9E37_79B9
    for i in 0..<(n * n) {
      seed = seed &* 1_664_525 &+ 1_013_904_223
      let a = UInt8(truncatingIfNeeded: seed >> 24)
      let c: UInt8 = white ? a : 0  // premultiplied
      px[i * 4] = c; px[i * 4 + 1] = c; px[i * 4 + 2] = c; px[i * 4 + 3] = a
    }
    guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
    return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }
}

/// The inset rounded "card" holding web content: an outer view carrying the shadow and an
/// inner clipping view with the corner radius.
public final class CardView: NSView {
  public let clip = NSView()
  public var cornerRadius: CGFloat = Tokens.cardCornerRadius { didSet { applyStyle() } }
  /// Focused pane in a split: a slightly stronger outline plus a theme-tinted ring.
  public var focused = false { didSet { if focused != oldValue { updateColors() } } }
  /// Ring color for the focused split pane (the space accent); nil = no ring.
  public var focusColor: NSColor? { didSet { updateColors() } }
  /// Split panes show close/separate controls on hover.
  public var showsPaneControls = false { didSet { if !showsPaneControls { controls.isHidden = true } } }
  public var onPaneAction: ((String) -> Void)?
  /// What shows behind a page that hasn't painted yet: the page's last known background colour
  /// (nil: den's plain card colour for the appearance). Never white in dark mode.
  public var pageColor: CGColor? { didSet { if pageColor != oldValue { updateColors() } } }
  let ring = NSView()
  let controls = PaneControlsView()

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    clip.wantsLayer = true
    addSubview(clip)
    ring.wantsLayer = true
    ring.isHidden = true
    addSubview(ring)
    controls.isHidden = true
    controls.onAction = { [weak self] a in self?.onPaneAction?(a) }
    addSubview(controls)
    applyStyle()
  }

  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
  }
  public override func mouseEntered(with event: NSEvent) { setControlsVisible(true) }
  public override func mouseExited(with event: NSEvent) { setControlsVisible(false) }

  /// Shows the hover controls (also used by snapshots and tests).
  public func setControlsVisible(_ on: Bool) {
    controls.isHidden = !(on && showsPaneControls)
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
    clip.layer?.backgroundColor = pageColor ?? (dark ? NSColor(white: 0.13, alpha: 1) : NSColor.white).cgColor
    clip.layer?.borderColor = NSColor(white: dark ? 1 : 0, alpha: Tokens.cardBorderOpacity * (dark ? 1.5 : 1) * (focused ? 4 : 1)).cgColor
    clip.layer?.borderWidth = focused ? 1.5 : 0.5
    ring.isHidden = !(focused && focusColor != nil)
    ring.layer?.borderColor = focusColor?.cgColor
    ring.layer?.borderWidth = Tokens.splitFocusRingWidth
    ring.layer?.cornerRadius = cornerRadius + Tokens.splitFocusRingOutset
    ring.layer?.cornerCurve = .continuous
  }

  public override func layout() {
    super.layout()
    clip.frame = bounds
    layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    // thin-host: feature-specific, migrate to plugin (floating views over a page should be a generic overlay layer)
    // A docked Web Inspector is WebKit's to place: it splits the card with the page whenever the
    // page's frame changes (DevTools).
    for v in clip.subviews where !(v is VaultSuggestionView) && !DevTools.isInspectorView(v) { v.frame = clip.bounds }
    let o = Tokens.splitFocusRingOutset
    ring.frame = bounds.insetBy(dx: -o, dy: -o)
    let cs = controls.size
    controls.frame = NSRect(x: ((bounds.width - cs.width) / 2).rounded(), y: Tokens.splitControlsTop, width: cs.width, height: cs.height)
  }
}

/// Hover controls at the top of a split pane: close the pane, or separate it into its own tab.
/// Every value is an estimate (Arc's split chrome is UNVERIFIED, spec §12).
public final class PaneControlsView: NSView {
  var onAction: ((String) -> Void)?
  var buttons: [IconButton] = []
  public override var isFlipped: Bool { true }
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.72).cgColor  // estimate (same as the peek bar)
    layer?.cornerRadius = Tokens.splitControlsHeight / 2
    layer?.cornerCurve = .continuous
    for (sym, action, tip, ref) in [("xmark", "close", "Close Split Pane", "view.closePane"), ("rectangle.portrait.and.arrow.right", "separate", "Separate Page from Split View", "")] {
      let b = IconButton(symbol: sym, size: 24) { [weak self] in self?.onAction?(action) }
      b.fixedTint = .white
      b.setTip(tip, shortcut: ref)
      buttons.append(b)
      addSubview(b)
    }
  }
  required init?(coder: NSCoder) { fatalError() }
  var size: CGSize { CGSize(width: CGFloat(buttons.count) * 26 + 6, height: Tokens.splitControlsHeight) }
  public override func layout() {
    super.layout()
    for (i, b) in buttons.enumerated() { b.frame = NSRect(x: 4 + CGFloat(i) * 26, y: (bounds.height - 24) / 2, width: 24, height: 24) }
  }
}
