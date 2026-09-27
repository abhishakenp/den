import AppKit
import CordisValue

/// Colors for chrome drawn on top of the themed background.
@MainActor
public struct Palette {
  public let dark: Bool
  public let theme: Theme

  public init(theme: Theme, dark: Bool) { (self.theme, self.dark) = (theme, dark) }

  // Values from docs/reference/arc-ui-spec.md §3 unless marked estimate.
  static func ink(_ a: CGFloat) -> NSColor { NSColor(srgbRed: 0x0E / 255, green: 0x0F / 255, blue: 0x10 / 255, alpha: a) }
  static func snow(_ a: CGFloat) -> NSColor { NSColor(srgbRed: 0xFA / 255, green: 0xFB / 255, blue: 1, alpha: a) }
  public var text: NSColor { dark ? NSColor(white: 1, alpha: 0.80) : Self.ink(0.90) }  // ForegroundPrimary
  public var secondaryText: NSColor { dark ? NSColor(white: 1, alpha: 0.50) : NSColor(white: 0, alpha: 0.50) }  // ForegroundSecondary
  public var tertiaryText: NSColor { NSColor(white: dark ? 1 : 0, alpha: 0.30) }  // ForegroundTertiary / TabCellSlash
  public var hoverFill: NSColor { dark ? Self.snow(0.08) : NSColor(white: 1, alpha: 0.32) }  // TabCellBackgroundPrevious (hover rule UNVERIFIED)
  public var selectedFill: NSColor { dark ? Self.snow(0.20) : NSColor(white: 1, alpha: 0.85) }  // TabCellBackgroundCurrent
  public var selectedShadow: NSColor? { dark ? nil : NSColor(white: 0, alpha: 0.20) }  // TabCellShadowSelected
  public var pressedFill: NSColor { dark ? Self.snow(0.06) : Self.ink(0.06) }  // TabCellBackgroundPressed
  public var pillFill: NSColor { dark ? Self.snow(0.10) : Self.ink(0.05) }  // SidebarItemBackground
  public var pillHoverFill: NSColor { dark ? Self.snow(0.15) : Self.ink(0.10) }  // SidebarItemHoveredBackground
  public var tileFill: NSColor { dark ? Self.snow(0.10) : Self.ink(0.05) }  // estimate: favorites use SidebarItemBackground
  public var divider: NSColor { NSColor(white: dark ? 1 : 0, alpha: 0.15) }  // SidebarSeparator
  public var primaryButton: NSColor { NSColor(srgbRed: 0x31 / 255, green: 0x39 / 255, blue: 0xFB / 255, alpha: 1) }  // primary button #3139FB
  public var destructive: NSColor { NSColor(srgbRed: 0xF5 / 255, green: 0x37 / 255, blue: 0x14 / 255, alpha: 1) }  // DestructiveButtonFace
  public var rowHover: NSColor { NSColor(white: dark ? 1 : 0, alpha: 0.05) }  // command bar RowHoverBackground
  public var panelText: NSColor { NSColor(white: dark ? 1 : 0, alpha: 0.80) }  // command bar TextPrimary
  public var panelSecondaryText: NSColor { NSColor(white: dark ? 1 : 0, alpha: 0.33) }  // command bar TextSecondary
  public var accent: NSColor {
    guard let a = theme.accent else { return .controlAccentColor }
    return (dark ? a.mix(RGB(1, 1, 1), 0.25) : a.mix(RGB(0, 0, 0), 0.15)).ns
  }
  /// Command bar surface: (28,27,34) dark measured (spec §2); light = PopoverBackground #FAFBFF.
  public var panel: NSColor { dark ? NSColor(srgbRed: 28 / 255, green: 27 / 255, blue: 34 / 255, alpha: 1) : Self.snow(1) }
  /// Dialog surface: PopoverBackground #FAFBFF / #151C30 (spec §3).
  public var popover: NSColor { dark ? NSColor(srgbRed: 0x15 / 255, green: 0x1C / 255, blue: 0x30 / 255, alpha: 1) : Self.snow(1) }
  public var toast: NSColor {
    let base = dark ? RGB(0.2, 0.2, 0.21) : RGB(0.12, 0.12, 0.13)
    return (theme.accent.map { base.mix($0, 0.45) } ?? base).ns
  }
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

/// Draws an icon spec: "sf:<symbol>", an http(s) image URL, or text/emoji. Falls back to a
/// letter tile when a remote image fails.
public final class IconView: NSView, Themable {
  public var spec = "" { didSet { if spec != oldValue { reload() } } }
  public var fallbackLetter = "" { didSet { needsDisplay = true } }
  public var tint: NSColor = .labelColor { didSet { needsDisplay = true } }
  private var image: NSImage?
  private var isSymbol = false

  public override var isFlipped: Bool { true }

  func reload() {
    image = nil
    isSymbol = false
    if spec == "app:icon" {
      image = NSApp.applicationIconImage
    } else if spec.hasPrefix("sf:") {
      image = NSImage(systemSymbolName: String(spec.dropFirst(3)), accessibilityDescription: nil)
      isSymbol = true
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
        let tinted = NSImage(size: s, flipped: false) { rect in
          sym.draw(in: rect)
          self.tint.set()
          rect.fill(using: .sourceAtop)
          return true
        }
        tinted.draw(in: r)
      } else {
        NSGraphicsContext.current?.imageInterpolation = .high
        let path = NSBezierPath(roundedRect: b, xRadius: b.width * 0.2, yRadius: b.height * 0.2)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        img.draw(in: b, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
      }
      return
    }
    let remote = spec.hasPrefix("http") || spec.isEmpty
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
