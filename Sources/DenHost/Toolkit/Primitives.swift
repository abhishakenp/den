import AppKit
import CordisValue

/// Colors for chrome drawn on top of the themed background.
///
/// Surfaces (dialogs, the command bar, popovers, toasts, hover cards, sheets, Settings, Little Arc)
/// take their colors from `tokens` (ThemeTokens.swift): derived from the space theme and the
/// appearance, contrast-checked, and cached per theme. See docs/host-api.md "Theming".
@MainActor
public struct Palette: Equatable {
  public let dark: Bool
  public let theme: Theme
  public let tokens: ThemeTokens

  /// Settings > General > Accent color: the space's colors (Arc) or the system accent.
  public static var accentSource: AccentSource = .theme

  public init(theme: Theme, dark: Bool) {
    (self.theme, self.dark) = (theme, dark)
    var sys: RGB?
    if Self.accentSource == .system, let c = NSColor.controlAccentColor.usingColorSpace(.sRGB) { sys = RGB(c.redComponent, c.greenComponent, c.blueComponent) }
    tokens = ThemeTokens.make(theme: theme, dark: dark, systemAccent: sys)
  }

  nonisolated public static func == (a: Palette, b: Palette) -> Bool { a.tokens == b.tokens && a.theme == b.theme }

  // MARK: Tokens (docs/host-api.md "Theming")
  public var surface: NSColor { tokens.surface.ns }
  public var elevatedSurface: NSColor { tokens.elevated.ns }
  public var textPrimary: NSColor { tokens.textPrimary.ns }
  public var textSecondary: NSColor { tokens.textSecondary.ns }
  public var textTertiary: NSColor { tokens.textTertiary.ns }
  public var onAccent: NSColor { tokens.onAccent.ns }
  public var onDestructive: NSColor { tokens.onDestructive.ns }
  public var onToast: NSColor { tokens.onToast.ns }
  public var hairline: NSColor { tokens.hairline.ns }
  public var pressed: NSColor { tokens.pressed.ns }
  public var shadowColor: NSColor { tokens.shadow.rgb.ns }
  public var shadowOpacity: Float { Float(tokens.shadow.a) }
  public var dialogDim: CGFloat { tokens.dialogDim }
  public var sheetDim: CGFloat { tokens.sheetDim }

  // Values from docs/reference/arc-ui-spec.md §3 unless marked estimate.
  static func ink(_ a: CGFloat) -> NSColor { NSColor(srgbRed: 0x0E / 255, green: 0x0F / 255, blue: 0x10 / 255, alpha: a) }
  static func snow(_ a: CGFloat) -> NSColor { NSColor(srgbRed: 0xFA / 255, green: 0xFB / 255, blue: 1, alpha: a) }
  /// Sidebar text: ForegroundPrimary/Secondary, pushed for contrast on very light or dark themes.
  public var text: NSColor { tokens.sidebarText.ns }
  public var secondaryText: NSColor { tokens.sidebarSecondary.ns }
  public var tertiaryText: NSColor { NSColor(white: dark ? 1 : 0, alpha: 0.30) }  // ForegroundTertiary / TabCellSlash
  public var hoverFill: NSColor { dark ? Self.snow(0.08) : NSColor(white: 1, alpha: 0.32) }  // TabCellBackgroundPrevious (hover rule UNVERIFIED)
  public var selectedFill: NSColor { dark ? Self.snow(0.20) : NSColor(white: 1, alpha: 0.85) }  // TabCellBackgroundCurrent
  public var selectedShadow: NSColor? { dark ? nil : NSColor(white: 0, alpha: 0.20) }  // TabCellShadowSelected
  public var pressedFill: NSColor { dark ? Self.snow(0.06) : Self.ink(0.06) }  // TabCellBackgroundPressed
  public var pillFill: NSColor { dark ? Self.snow(0.10) : Self.ink(0.05) }  // SidebarItemBackground
  public var pillHoverFill: NSColor { dark ? Self.snow(0.15) : Self.ink(0.10) }  // SidebarItemHoveredBackground
  public var tileFill: NSColor { dark ? Self.snow(0.10) : Self.ink(0.05) }  // estimate: favorites use SidebarItemBackground
  public var divider: NSColor { NSColor(white: dark ? 1 : 0, alpha: 0.15) }  // SidebarSeparator
  /// The theme's accent (Arc's #3139FB is the no-theme default's cousin), with `onAccent` on it.
  public var primaryButton: NSColor { tokens.accent.ns }
  public var destructive: NSColor { tokens.destructive.ns }  // DestructiveButtonFace, darkened for a white label
  public var rowHover: NSColor { tokens.hover.ns }  // command bar RowHoverBackground
  public var panelText: NSColor { tokens.textPrimary.ns }  // command bar TextPrimary
  public var panelSecondaryText: NSColor { tokens.textSecondary.ns }  // command bar TextSecondary
  /// Saturated theme color that white text reads on (command bar selection, split drop
  /// indicators). Spec §2 measured (65,72,216) in the default theme; den derives it from the space.
  public var accentStrong: NSColor { tokens.accent.ns }
  public var accent: NSColor {
    guard let a = theme.accent else { return .controlAccentColor }
    return (dark ? a.mix(RGB(1, 1, 1), 0.25) : a.mix(RGB(0, 0, 0), 0.15)).ns
  }
  /// Command bar and dialog surfaces: PopoverBackground (#FAFBFF / #151C30, spec §3) tinted by the space.
  public var panel: NSColor { tokens.surface.ns }
  public var popover: NSColor { tokens.surface.ns }
  public var toast: NSColor { tokens.toast.ns }
}

extension RGBA {
  public var ns: NSColor { NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: a) }
}

/// Everything in the toolkit that depends on theme/appearance implements this.
@MainActor
public protocol Themable: AnyObject {
  func apply(_ p: Palette)
}

extension NSView {
  @MainActor func applyPaletteRecursively(_ p: Palette) {
    (self as? Themable)?.apply(p)
    for v in subviews { v.applyPaletteRecursively(p) }
  }
}

// MARK: - Images

/// Async image loader with an in-memory cache (favicons, remote icons).
@MainActor
public final class ImageCache {
  public static let shared = ImageCache()
  private var images: [String: NSImage] = [:]
  private var failed: Set<String> = []
  private var waiting: [String: [(NSImage?) -> Void]] = [:]
  private let session: URLSession = {
    let c = URLSessionConfiguration.default
    c.requestCachePolicy = .returnCacheDataElseLoad
    c.urlCache = URLCache(memoryCapacity: 4 << 20, diskCapacity: 32 << 20, directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("den/icons"))
    return URLSession(configuration: c)
  }()

  public func cached(_ url: String) -> NSImage? { images[url] }
  /// Puts an already-decoded image in the cache (tests, preloaded icons).
  func store(_ url: String, _ img: NSImage) { images[url] = img; darkVariants[url] = nil }

  /// Per URL: the light variant of a dark monochrome icon, or nil (not dark monochrome).
  private var darkVariants: [String: NSImage?] = [:]
  /// For dark mode: GitHub's favicon (a black disc with the cat knocked out, or a black glyph)
  /// all but disappears on a dark sidebar. Such icons are drawn inverted (white disc, dark cat),
  /// like the site's own dark-mode favicon. Computed on the first dark-mode draw only, then cached.
  func darkVariant(_ url: String, _ img: NSImage) -> NSImage? {
    if let v = darkVariants[url] { return v }
    let v = Self.isDarkGlyph(img) ? Self.inverted(img) : nil
    darkVariants[url] = v
    return v
  }

  static let glyphSample = 32

  static func pixels(_ img: NSImage) -> (CGContext, UnsafeMutablePointer<UInt8>)? {
    let n = glyphSample
    guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil), let data = ctx.data else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
    return (ctx, data.bindMemory(to: UInt8.self, capacity: n * n * 4))
  }

  /// Samples the image at 32x32. A dark monochrome icon has a transparent background (at least
  /// 15% of pixels nearly clear), its visible pixels are colorless (90%), and most of them are
  /// dark (60%). A glyph on an opaque square, or anything colorful, keeps its own colors.
  static func isDarkGlyph(_ img: NSImage) -> Bool {
    guard let (ctx, px) = pixels(img) else { return false }
    defer { withExtendedLifetime(ctx) {} }  // px points into ctx's buffer
    let n = glyphSample
    var clear = 0, visible = 0, grey = 0, dark = 0
    for i in 0..<(n * n) {
      let a = Double(px[i * 4 + 3]) / 255
      if a < 0.1 { clear += 1; continue }
      guard a > 0.5 else { continue }
      visible += 1
      let r = Double(px[i * 4]) / 255 / a, g = Double(px[i * 4 + 1]) / 255 / a, b = Double(px[i * 4 + 2]) / 255 / a
      if max(r, g, b) - min(r, g, b) < 0.15 { grey += 1 }
      if 0.2126 * r + 0.7152 * g + 0.0722 * b < 0.3 { dark += 1 }
    }
    guard visible > 0 else { return false }
    return Double(clear) >= 0.15 * Double(n * n) && Double(grey) >= 0.9 * Double(visible) && Double(dark) >= 0.6 * Double(visible)
  }

  /// The image with its colors inverted and its alpha kept.
  static func inverted(_ img: NSImage) -> NSImage? {
    guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let w = cg.width, h = cg.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = ctx.data else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
    for i in 0..<(w * h) {
      let a = px[i * 4 + 3]
      for c in 0..<3 { px[i * 4 + c] = a &- min(px[i * 4 + c], a) }  // premultiplied: a - c
    }
    guard let out = ctx.makeImage() else { return nil }
    return NSImage(cgImage: out, size: img.size)
  }

  /// A local image file (extension icons): read once, then cached.
  public func file(_ path: String) -> NSImage? {
    if let i = images[path] { return i }
    guard let img = NSImage(contentsOfFile: path) else { return nil }
    images[path] = img
    return img
  }

  /// Drops a cached entry (a file that was rewritten).
  public func forget(_ key: String) {
    images[key] = nil
    failed.remove(key)
  }

  public func load(_ url: String, _ done: @escaping (NSImage?) -> Void) {
    if let i = images[url] { return done(i) }
    if failed.contains(url) { return done(nil) }
    if waiting[url] != nil { waiting[url]!.append(done); return }
    guard let u = URL(string: url) else { return done(nil) }
    waiting[url] = [done]
    session.dataTask(with: u) { data, _, _ in
      let bytes = data
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          let img = bytes.flatMap { NSImage(data: $0) }
          if let img { self.images[url] = img } else { self.failed.insert(url) }
          let cbs = self.waiting.removeValue(forKey: url) ?? []
          cbs.forEach { $0(img) }
        }
      }
    }.resume()
  }
}

/// Draws an icon spec: "sf:<symbol>", an http(s) image URL, an absolute file path, or text/emoji. Falls back to a
/// letter tile when a remote image fails.
public final class IconView: NSView, Themable {
  public var spec = "" { didSet { if spec != oldValue { reload() } } }
  public var fallbackLetter = "" { didSet { needsDisplay = true } }
  public var tint: NSColor = .labelColor { didSet { needsDisplay = true } }
  private var image: NSImage?
  private var isSymbol = false

  public override var isFlipped: Bool { true }

  public override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  var isDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

  func reload() {
    image = nil
    isSymbol = false
    if spec == "app:icon" {
      image = NSApp.applicationIconImage
    } else if spec.hasPrefix("sf:") {
      image = NSImage(systemSymbolName: String(spec.dropFirst(3)), accessibilityDescription: nil)
      isSymbol = true
    } else if spec.hasPrefix("/") {
      image = ImageCache.shared.file(spec)
    } else if spec.hasPrefix("http://") || spec.hasPrefix("https://") || spec.hasPrefix("data:") {
      let s = spec
      if let c = ImageCache.shared.cached(s) { image = c } else {
        ImageCache.shared.load(s) { [weak self] img in
          guard let self, self.spec == s else { return }
          self.image = img
          self.needsDisplay = true
        }
      }
    }
    needsDisplay = true
  }

  public func apply(_ p: Palette) { tint = p.text }

  public override func draw(_ dirtyRect: NSRect) {
    let b = bounds
    if let img = image {
      if isSymbol {
        let cfg = NSImage.SymbolConfiguration(pointSize: b.height * 0.78, weight: .medium)
        let sym = img.withSymbolConfiguration(cfg) ?? img
        let s = sym.size
        let r = NSRect(x: b.midX - s.width / 2, y: b.midY - s.height / 2, width: s.width, height: s.height)
        // Fill with the opaque tint, then apply its alpha when compositing: filling a translucent
        // tint `.sourceAtop` would leave the black template showing through.
        let opaque = tint.withAlphaComponent(1)
        let tinted = NSImage(size: s, flipped: false) { rect in
          sym.draw(in: rect)
          opaque.set()
          rect.fill(using: .sourceAtop)
          return true
        }
        tinted.draw(in: r, from: .zero, operation: .sourceOver, fraction: tint.alphaComponent, respectFlipped: true, hints: nil)
      } else {
        NSGraphicsContext.current?.imageInterpolation = .high
        let path = NSBezierPath(roundedRect: b, xRadius: b.width * 0.2, yRadius: b.height * 0.2)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        // Dark monochrome icons (GitHub) are drawn inverted in dark mode, or they'd disappear.
        let drawn = isDark ? (ImageCache.shared.darkVariant(spec, img) ?? img) : img
        drawn.draw(in: b, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
      }
      return
    }
    let remote = spec.hasPrefix("http") || spec.hasPrefix("/") || spec.isEmpty
    let text = remote ? String(fallbackLetter.prefix(1)).uppercased() : spec
    guard !text.isEmpty else { return }
    if remote {
      tint.withAlphaComponent(0.18).setFill()
      NSBezierPath(roundedRect: b, xRadius: b.width * 0.25, yRadius: b.height * 0.25).fill()
    }
    let font = NSFont.systemFont(ofSize: b.height * (remote ? 0.62 : 0.86), weight: .semibold)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tint]
    let s = (text as NSString).size(withAttributes: attrs)
    (text as NSString).draw(at: NSPoint(x: b.midX - s.width / 2, y: b.midY - s.height / 2), withAttributes: attrs)
  }
}

/// Small borderless symbol button with a hover fill.
public final class IconButton: NSView, Themable {
  let icon = IconView()
  var action: () -> Void
  var enabled = true { didSet { alphaValue = enabled ? 1 : 0.35 } }
  var tint: NSColor = .labelColor { didSet { icon.tint = tint } }
  var hoverFill: NSColor = NSColor(white: 0, alpha: 0.06)
  private var hovering = false { didSet { needsDisplay = true } }
  private let size: CGFloat
  public override var tag: Int { get { _tag } set { _tag = newValue } }
  private var _tag = 0

  public init(symbol: String, size: CGFloat, action: @escaping () -> Void) {
    self.action = action
    self.size = size
    super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
    icon.spec = symbol.hasPrefix("sf:") ? symbol : "sf:" + symbol
    addSubview(icon)
  }
  required init?(coder: NSCoder) { fatalError() }

  public override var isFlipped: Bool { true }
  public override var mouseDownCanMoveWindow: Bool { false }
  /// When set, palette changes don't recolor the button (e.g. white icons on the peek bar).
  var fixedTint: NSColor? { didSet { if let f = fixedTint { tint = f; hoverFill = NSColor(white: 1, alpha: 0.15) } } }
  public func apply(_ p: Palette) {
    guard fixedTint == nil else { return }
    tint = p.text.withAlphaComponent(0.75)
    hoverFill = p.hoverFill
  }

  public override func layout() {
    super.layout()
    let s = min(bounds.width, bounds.height) * 0.62
    icon.frame = NSRect(x: (bounds.width - s) / 2, y: (bounds.height - s) / 2, width: s, height: s)
  }

  public override func draw(_ dirtyRect: NSRect) {
    guard hovering && enabled else { return }
    hoverFill.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
  }

  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }
  public override func mouseEntered(with event: NSEvent) { hovering = true }
  public override func mouseExited(with event: NSEvent) { hovering = false }
  public override func mouseDown(with event: NSEvent) {}
  public override func mouseUp(with event: NSEvent) {
    if enabled && bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
  }
}

/// Non-editable single-line label.
@MainActor
func makeLabel(_ s: String = "", size: CGFloat = Tokens.tabRowFontSize, weight: NSFont.Weight = .regular) -> NSTextField {
  let l = NSTextField(labelWithString: s)
  l.font = .systemFont(ofSize: size, weight: weight)
  l.lineBreakMode = .byTruncatingTail
  l.maximumNumberOfLines = 1
  l.cell?.truncatesLastVisibleLine = true
  return l
}

extension NSTextField {
  /// Width of the rendered string (intrinsicContentSize under-reports for truncating labels).
  var textWidth: CGFloat { ceil(attributedStringValue.size().width) + 2 }
}
