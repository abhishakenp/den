import AppKit
import CordisValue

/// Colors for chrome drawn on top of the themed background.
@MainActor
public struct Palette {
  public let dark: Bool
  public let theme: Theme

  public init(theme: Theme, dark: Bool) { (self.theme, self.dark) = (theme, dark) }

  public var text: NSColor { dark ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 0, alpha: 0.82) }  // estimate
  public var secondaryText: NSColor { dark ? NSColor(white: 1, alpha: 0.55) : NSColor(white: 0, alpha: 0.5) }  // estimate
  public var hoverFill: NSColor { dark ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 1, alpha: 0.32) }  // estimate
  public var selectedFill: NSColor { dark ? NSColor(white: 1, alpha: 0.15) : NSColor(white: 1, alpha: 0.88) }  // estimate
  public var pillFill: NSColor { dark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.055) }  // estimate
  public var tileFill: NSColor { dark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 1, alpha: 0.38) }  // estimate
  public var divider: NSColor { dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.1) }  // estimate
  public var accent: NSColor {
    guard let a = theme.accent else { return .controlAccentColor }
    return (dark ? a.mix(RGB(1, 1, 1), 0.25) : a.mix(RGB(0, 0, 0), 0.15)).ns
  }
  /// Surface for floating panels (command bar, dialog, toast), tinted slightly with the theme.
  public var panel: NSColor {
    let base = dark ? RGB(0.16, 0.16, 0.17) : RGB(1, 1, 1)
    return (theme.accent.map { base.mix($0, dark ? 0.12 : 0.05) } ?? base).ns
  }
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
    if spec.hasPrefix("sf:") {
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
