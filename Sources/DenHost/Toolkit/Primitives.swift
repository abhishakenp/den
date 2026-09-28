import AppKit
import UniformTypeIdentifiers
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
  /// A small control inside a row (close X, speaker): must read over the row's own hover and
  /// selected fills, which are translucent white in light mode (estimate).
  public var controlHoverFill: NSColor { dark ? Self.snow(0.14) : Self.ink(0.08) }
  public var controlPressedFill: NSColor { dark ? Self.snow(0.22) : Self.ink(0.14) }
  public var pillFill: NSColor { dark ? Self.snow(0.10) : Self.ink(0.05) }  // SidebarItemBackground
  public var pillHoverFill: NSColor { dark ? Self.snow(0.15) : Self.ink(0.10) }  // SidebarItemHoveredBackground
  public var tileFill: NSColor { dark ? Self.snow(0.10) : Self.ink(0.05) }  // estimate: favorites use SidebarItemBackground
  public var divider: NSColor { NSColor(white: dark ? 1 : 0, alpha: 0.15) }  // SidebarSeparator
  /// A Today group's container panel: a step lighter than the sidebar, under row hover and
  /// selection (dia-ui-spec §6: dark about 8% white; the light value is den's estimate).
  public var groupFill: NSColor { dark ? Self.snow(0.06) : NSColor(white: 1, alpha: 0.24) }
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

  /// A favicon service's generic placeholder (Google s2 returns a 16x16 globe for sites it has no
  /// icon for, whatever size was asked).
  static func isServiceFallback(_ url: String, _ img: NSImage) -> Bool {
    guard url.contains("google.com/s2/favicons"), url.contains("sz=") else { return false }
    let px = img.representations.map { max($0.pixelsWide, $0.pixelsHigh) }.max() ?? 0
    return px > 0 && px <= 16
  }

  public func load(_ url: String, _ done: @escaping (NSImage?) -> Void) {
    if let i = images[url] { return done(i) }
    if failed.contains(url) { return done(nil) }
    if waiting[url] != nil { waiting[url]!.append(done); return }
    guard let u = URL(string: url) else { return done(nil) }
    waiting[url] = [done]
    session.dataTask(with: u) { data, response, _ in
      // An HTTP error is a failure even with a body (an error page, or a service's placeholder).
      let status = (response as? HTTPURLResponse)?.statusCode ?? 200
      let bytes = (200..<300).contains(status) ? data : nil
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          var img = bytes.flatMap { NSImage(data: $0) }
          // Google's favicon service answers an unknown site with its own 16 px globe, which
          // upscales to a blurry, pixelated icon: treat it as no favicon, so the view draws its
          // vector fallback (a letter tile, or the globe symbol) sharp at any scale.
          if let i = img, Self.isServiceFallback(url, i) { img = nil }
          if let img { self.images[url] = img } else { self.failed.insert(url) }
          let cbs = self.waiting.removeValue(forKey: url) ?? []
          cbs.forEach { $0(img) }
        }
      }
    }.resume()
  }
}

/// Site identity for pages without a usable icon or title: the domain shown in a letter tile,
/// and its color. Pure functions, so tests can pin the derivation.
public enum Sites {
  /// "https://www.example.com/a" -> "example.com"; "" for URLs without a web host (data:,
  /// file:, about:).
  public static func domain(_ url: String) -> String {
    guard let u = URL(string: url), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https",
          let h = u.host?.lowercased(), !h.isEmpty else { return "" }
    return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
  }

  /// The domain a remote icon stands for: Google s2's `domain=` parameter, else the icon's host.
  public static func domain(ofIcon spec: String) -> String {
    if spec.contains("/s2/favicons"), let c = URLComponents(string: spec),
       let d = c.queryItems?.first(where: { $0.name == "domain" })?.value {
      let h = domain("https://" + d)
      return h.contains(".") || h == "localhost" ? h : ""
    }
    return domain(spec)
  }

  /// A short label for a page's location (Little Arc's field, library subtitles): the domain,
  /// a `file:` URL's file name, else "".
  public static func label(_ url: String) -> String {
    let d = domain(url)
    if !d.isEmpty { return d }
    if let u = URL(string: url), u.isFileURL { return u.lastPathComponent == "/" ? "" : u.lastPathComponent }
    return ""
  }

  /// The tile's letter: the domain's first character, uppercased ("www." dropped).
  public static func letter(_ domain: String) -> String {
    let d = domain.hasPrefix("www.") ? String(domain.dropFirst(4)) : domain
    return d.first.map { String($0).uppercased() } ?? ""
  }

  /// Hue in [0, 1) derived from the domain (FNV-1a), stable across launches and machines.
  public static func hue(_ domain: String) -> CGFloat {
    var d = domain.lowercased()
    if d.hasPrefix("www.") { d = String(d.dropFirst(4)) }
    var h: UInt32 = 2_166_136_261
    for b in d.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
    return CGFloat(h % 360) / 360
  }

  /// The tile color: the domain's hue at a soft saturation. Yellows and greens are luminous, so
  /// they get darker (peak at 72°) to keep the white letter readable.
  public static func tileColor(_ domain: String, dark: Bool) -> NSColor {
    let h = hue(domain)
    let luminous = max(0, 1 - abs(h - 0.2) / 0.2)
    return NSColor(hue: h, saturation: dark ? 0.52 : 0.58, brightness: (dark ? 0.68 : 0.80) - 0.18 * luminous, alpha: 1)
  }
}

/// Draws an icon spec: "sf:<symbol>", "app:icon", "site:<domain>" (a letter tile in a color
/// derived from the domain, or a globe when the domain is empty), an http(s) or data: image
/// URL, an absolute image file path (extension icons), "file:<path>" (Finder's icon for that file,
/// or for its type when it's gone), or text/emoji. A remote image that fails to load (or answers non-2xx) becomes the
/// `site:` tile for `fallbackDomain`, else for the domain the icon URL names (Google s2's
/// `domain=`, else its host); with no domain, a globe.
public class IconView: NSView, Themable {
  public var spec = "" { didSet { if spec != oldValue { reload() } } }
  /// Letter drawn on a plain tile when `spec` is empty.
  public var fallbackLetter = "" { didSet { needsDisplay = true } }
  /// Domain for the tile a failed remote icon falls back to (overrides the one derived from `spec`).
  public var fallbackDomain = "" { didSet { needsDisplay = true } }
  public var tint: NSColor = .labelColor { didSet { needsDisplay = true } }
  private var image: NSImage?
  private var isSymbol = false
  /// A Finder file icon: drawn as is, without the rounded clip.
  private var isFileIcon = false
  /// The remote icon failed: draw the site tile instead.
  private var failed = false

  public override var isFlipped: Bool { true }

  static let globe = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)

  /// Launch: the first SF Symbol den draws pays for loading the system glyph catalog on the main
  /// thread. Resolving and rasterizing one glyph on a background queue at process start does
  /// that in parallel with the rest of launch (NSImage and the catalog are thread-safe).
  public nonisolated static func prewarmSymbols() {
    DispatchQueue.global(qos: .userInitiated).async {
      guard let img = NSImage(systemSymbolName: "globe", accessibilityDescription: nil) else { return }
      var rect = NSRect(x: 0, y: 0, width: 16, height: 16)
      _ = img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
  }

  var isDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

  var isRemote: Bool { spec.hasPrefix("http://") || spec.hasPrefix("https://") || spec.hasPrefix("data:") }

  public override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  func reload() {
    image = nil
    isSymbol = false
    isFileIcon = false
    failed = false
    if spec.hasPrefix("file:") {
      image = Self.fileIcon(String(spec.dropFirst(5)))
      isFileIcon = true
    } else if spec == "app:icon" {
      image = NSApp.applicationIconImage
    } else if spec.hasPrefix("sf:") {
      image = Self.symbol(String(spec.dropFirst(3)))
      isSymbol = true
    } else if spec.hasPrefix("/") {
      image = ImageCache.shared.file(spec)
      failed = image == nil
    } else if isRemote {
      let s = spec
      if let c = ImageCache.shared.cached(s) { image = c } else {
        ImageCache.shared.load(s) { [weak self] img in
          guard let self, self.spec == s else { return }
          self.image = img
          self.failed = img == nil
          self.needsDisplay = true
        }
      }
    }
    needsDisplay = true
  }

  public func apply(_ p: Palette) { tint = p.text }

  /// Finder's icon for a file, or for its type when the file is gone (a deleted download).
  static func fileIcon(_ path: String) -> NSImage {
    if FileManager.default.fileExists(atPath: path) { return NSWorkspace.shared.icon(forFile: path) }
    let ext = (path as NSString).pathExtension
    return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
  }

  public override func draw(_ dirtyRect: NSRect) {
    let b = bounds
    if let img = image {
      if isSymbol { return drawSymbol(img, in: b) }
      if isFileIcon { return img.draw(in: b, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
      NSGraphicsContext.current?.imageInterpolation = .high
      let path = NSBezierPath(roundedRect: b, xRadius: b.width * 0.2, yRadius: b.height * 0.2)
      NSGraphicsContext.saveGraphicsState()
      path.addClip()
      // Dark monochrome icons (GitHub) are drawn inverted in dark mode, or they'd disappear.
      let drawn = isDark ? (ImageCache.shared.darkVariant(spec, img) ?? img) : img
      drawn.draw(in: b, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
      NSGraphicsContext.restoreGraphicsState()
      return
    }
    if spec.hasPrefix("site:") { return drawSite(String(spec.dropFirst(5)), in: b) }
    if isRemote || spec.hasPrefix("/") {
      // Loading or failed: the site tile (a cached favicon was already set in reload()).
      return drawSite(fallbackDomain.isEmpty ? Sites.domain(ofIcon: spec) : fallbackDomain, in: b)
    }
    if spec.isEmpty {
      let text = String(fallbackLetter.prefix(1)).uppercased()
      guard !text.isEmpty else { return }
      tint.withAlphaComponent(0.18).setFill()
      NSBezierPath(roundedRect: b, xRadius: b.width * 0.25, yRadius: b.height * 0.25).fill()
      return drawText(text, in: b, scale: 0.62, color: tint)
    }
    // Text/emoji icons only: an unknown spec ("xx:…", a long string) must never be drawn as text.
    guard Self.isTextIcon(spec) else {
      Self.reportBadSpec(spec)
      if let q = Self.symbol(Self.missingSymbol) { drawSymbol(q, in: b) }
      return
    }
    drawText(spec, in: b, scale: 0.86, color: tint)
  }

  /// Drawn in place of an SF Symbol name that doesn't resolve (a typo, or a symbol newer than the OS).
  public static let missingSymbol = "questionmark.square.dashed"
  private static var reported = Set<String>()

  /// An SF Symbol by name, or `missingSymbol` (logged once per name) when the name doesn't exist.
  public static func symbol(_ name: String) -> NSImage? {
    if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) { return img }
    reportBadSpec("sf:" + name)
    return NSImage(systemSymbolName: missingSymbol, accessibilityDescription: nil)
  }

  static func reportBadSpec(_ spec: String) {
    guard reported.insert(spec).inserted else { return }
    NSLog("den: icon spec %@ doesn't resolve; drawing %@ instead", spec, missingSymbol)
  }

  /// True for a spec that is meant to be drawn as text: an emoji or up to two characters, never
  /// something that looks like a `scheme:` spec.
  public static func isTextIcon(_ spec: String) -> Bool {
    guard !spec.isEmpty, spec.count <= 2 else { return false }
    if let colon = spec.firstIndex(of: ":"), colon != spec.startIndex { return false }
    return true
  }

  /// The `site:` tile: the domain's letter, white on its derived color; a globe without one.
  func drawSite(_ domain: String, in b: NSRect) {
    let letter = Sites.letter(domain)
    guard let c = letter.unicodeScalars.first, CharacterSet.alphanumerics.contains(c) else {
      if let g = Self.globe { drawSymbol(g, in: b, scale: 0.86) }
      return
    }
    Sites.tileColor(domain, dark: isDark).setFill()
    NSBezierPath(roundedRect: b, xRadius: b.width * 0.2, yRadius: b.height * 0.2).fill()
    drawText(letter, in: b, scale: 0.62, color: .white, weight: .bold)
  }

  func drawText(_ text: String, in b: NSRect, scale: CGFloat, color: NSColor, weight: NSFont.Weight = .semibold) {
    var font = NSFont.systemFont(ofSize: b.height * scale, weight: weight)
    if weight == .bold, let d = font.fontDescriptor.withDesign(.rounded) { font = NSFont(descriptor: d, size: font.pointSize) ?? font }
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let s = (text as NSString).size(withAttributes: attrs)
    (text as NSString).draw(at: NSPoint(x: b.midX - s.width / 2, y: b.midY - s.height / 2), withAttributes: attrs)
  }

  func drawSymbol(_ img: NSImage, in b: NSRect, scale: CGFloat = 0.78) {
    let cfg = NSImage.SymbolConfiguration(pointSize: b.height * scale, weight: .medium)
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
  }
}

/// Small borderless symbol button with a hover fill.
public final class IconButton: NSView, Themable, Hoverable {
  var hoverGroup: HoverGroup { .control }
  let icon = IconView()
  var action: () -> Void
  var enabled = true { didSet { alphaValue = enabled ? 1 : 0.35 } }
  var tint: NSColor = .labelColor { didSet { icon.tint = tint } }
  var hoverFill: NSColor = NSColor(white: 0, alpha: 0.06)
  var hovering = false { didSet { needsDisplay = true } }
  private let size: CGFloat
  public override var tag: Int { get { _tag } set { _tag = newValue } }
  private var _tag = 0

  public init(symbol: String, size: CGFloat, action: @escaping () -> Void) {
    self.action = action
    self.size = size
    super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
    icon.spec = symbol.hasPrefix("sf:") ? symbol : "sf:" + symbol
    addSubview(icon)
    // VoiceOver and Full Keyboard Access see a button (named by `setTip`).
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
  }
  public override func accessibilityPerformPress() -> Bool {
    guard enabled else { return false }
    action()
    return true
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

  /// Circular hover fill instead of the rounded square.
  var round = false

  public override func draw(_ dirtyRect: NSRect) {
    guard hovering && enabled else { return }
    hoverFill.setFill()
    let r = round ? bounds.height / 2 : 6
    NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
  }

  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }
  public override func mouseEntered(with event: NSEvent) {
    refreshTip()
    HoverTracker.refresh(window)
  }
  public override func mouseExited(with event: NSEvent) { HoverTracker.refresh(window) }

  // Tooltip with the action's shortcut ("Back  ⌘["), read from the menu bar on hover so a
  // `[shortcuts]` remap shows up (`Shortcuts`). Icon-only buttons are the one place den uses
  // native tooltips.
  private var tipTitle: String?
  private var tipRef = ""
  private var tipFallback = ""
  /// Names the button (tooltip and accessibility) and the action whose shortcut it shows.
  func setTip(_ title: String, shortcut ref: String = "", fallback: String = "") {
    (tipTitle, tipRef, tipFallback) = (title, ref, fallback)
    setAccessibilityLabel(title.isEmpty ? nil : title)
    refreshTip()
  }
  func refreshTip() {
    guard let t = tipTitle else { return }
    let tip = Shortcuts.tip(t, tipRef, fallback: tipFallback)
    if toolTip != tip { toolTip = tip.isEmpty ? nil : tip }
  }
  /// Acts on the click that also focuses its window (the mini player, which never activates den).
  var firstMouse = false
  public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { firstMouse }
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
