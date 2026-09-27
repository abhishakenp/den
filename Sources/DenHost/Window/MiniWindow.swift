import AppKit
import CordisValue
import WebKit

/// Little Arc (spec §8): a small floating window with a 47 pt themed bar and one full-bleed web view.
///
/// Opened with `window.openMini {webview, space?, spaceIcon?}` -> `{id}`.
/// Bar: traffic lights, a URL field (site icon, centered domain, copy-link button) and an
/// "Open in <space> ⌘O" button. Emits `window.miniAction {id, webview, action: open|copy}` and
/// `window.miniClosed {id, webview}` when the window closes (the web view is detached, not destroyed).
@MainActor
final class MiniWindowController: NSObject, NSWindowDelegate {
  let id: String
  let webview: String
  let panel: NSPanel
  let root = FlippedView()
  let background = ThemeBackgroundView()
  let bar = MiniBarView()
  let content = FlippedView()
  var onEvent: (String, Value) -> Void = { _, _ in }
  var onClose: (() -> Void)?

  init(id: String, webview: String, web: WKWebView?, theme: Theme, dark: Bool, space: String, frame: NSRect) {
    self.id = id
    self.webview = webview
    panel = NSPanel(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    super.init()
    panel.titlebarAppearsTransparent = true
    panel.titleVisibility = .hidden
    panel.isFloatingPanel = true  // spec §8: AXSystemDialog-style floating panel
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior.insert(.fullScreenAuxiliary)
    panel.minSize = Tokens.miniMinSize
    panel.delegate = self
    panel.contentView = root
    background.theme = theme
    [background, content, bar].forEach { root.addSubview($0) }
    panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    bar.space = space
    bar.onAction = { [weak self] a in
      guard let self else { return }
      self.onEvent("window.miniAction", ["id": .string(self.id), "webview": .string(self.webview), "action": .string(a)])
    }
    content.wantsLayer = true
    content.layer?.masksToBounds = true
    if let web { setWeb(web) }
    applyPalette(Palette(theme: theme, dark: dark))
    NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: root, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.layout() }
    }
    root.postsFrameChangedNotifications = true
    layout()
  }

  func setWeb(_ w: WKWebView) {
    content.subviews.forEach { $0.removeFromSuperview() }
    content.addSubview(w)
    w.frame = content.bounds
    w.autoresizingMask = [.width, .height]
  }

  func applyPalette(_ p: Palette) { bar.apply(p) }

  func layout() {
    let b = root.bounds, h = Tokens.miniBarHeight
    background.frame = NSRect(x: 0, y: 0, width: b.width, height: h)
    bar.frame = background.frame
    content.frame = NSRect(x: 0, y: h, width: b.width, height: max(0, b.height - h))  // spec §8: full-bleed, no inset card
    layoutTrafficLights()
  }

  /// Spec §8: traffic lights at (9, 15) inside the 47 pt bar.
  func layoutTrafficLights() {
    let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    let buttons = kinds.compactMap { panel.standardWindowButton($0) }
    guard let container = buttons.first?.superview?.superview else { return }
    let h = Tokens.miniBarHeight
    container.frame = NSRect(x: 0, y: panel.frame.height - h, width: container.frame.width, height: h)
    for (i, b) in buttons.enumerated() {
      let s = b.frame.size
      b.setFrameOrigin(NSPoint(x: Tokens.miniTrafficLightOrigin.x + CGFloat(i) * Tokens.miniTrafficLightPitch, y: h - Tokens.miniTrafficLightOrigin.y - s.height))
    }
  }

  func windowDidResize(_ notification: Notification) { layout() }
  func windowWillClose(_ notification: Notification) {
    content.subviews.forEach { $0.removeFromSuperview() }
    onEvent("window.miniClosed", ["id": .string(id), "webview": .string(webview)])
    onClose?()
  }
}

/// The Little Arc bar: URL field and "Open in <space>" button (spec §8).
@MainActor
final class MiniBarView: FlippedView {
  let field = FlippedView()
  let siteIcon = IconView()
  let domain = makeLabel(size: 13, weight: .medium)
  lazy var copy = IconButton(symbol: "link", size: 22) { [weak self] in self?.onAction?("copy") }
  let open = OpenInButton()
  var onAction: ((String) -> Void)?
  var space = "" { didSet { open.space = space; needsLayout = true } }

  override init(frame: NSRect) {
    super.init(frame: frame)
    field.wantsLayer = true
    field.layer?.cornerRadius = Tokens.miniFieldRadius
    field.layer?.cornerCurve = .continuous
    addSubview(field)
    domain.alignment = .center
    domain.lineBreakMode = .byTruncatingMiddle
    [siteIcon, domain, copy].forEach { field.addSubview($0) }
    copy.toolTip = "Copy Link"
    open.onClick = { [weak self] in self?.onAction?("open") }
    addSubview(open)
  }
  required init?(coder: NSCoder) { fatalError() }
  override var mouseDownCanMoveWindow: Bool { true }

  func set(url: String, favicon: String) {
    let host = URL(string: url)?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? url
    domain.stringValue = host
    siteIcon.spec = favicon.isEmpty ? "sf:magnifyingglass" : favicon
    siteIcon.fallbackLetter = host
  }

  func apply(_ p: Palette) {
    field.layer?.backgroundColor = p.pillFill.cgColor  // SidebarItemBackground (PX: (36,39,53) over (12,9,28))
    domain.textColor = p.text
    siteIcon.tint = p.secondaryText
    copy.apply(p)
    open.apply(p)
  }

  override func layout() {
    super.layout()
    // PX (1185 pt window): field x 83–1025, y 8–38.5; button 145x30 ending 7 pt from the right.
    let bw = open.preferredWidth
    open.frame = NSRect(x: bounds.width - Tokens.miniOpenButtonRightInset - bw, y: Tokens.miniFieldTop, width: bw, height: Tokens.miniFieldHeight)
    let fx = Tokens.miniFieldX
    field.frame = NSRect(x: fx, y: Tokens.miniFieldTop, width: max(0, open.frame.minX - 8 - fx), height: Tokens.miniFieldHeight)
    let fh = field.bounds.height
    siteIcon.frame = NSRect(x: 8, y: (fh - 16) / 2, width: 16, height: 16)  // spec §8: site icon 16x16 at (91, 15)
    copy.frame = NSRect(x: field.bounds.width - 30, y: (fh - 22) / 2, width: 22, height: 22)
    domain.frame = NSRect(x: 40, y: (fh - 17) / 2, width: max(0, field.bounds.width - 80), height: 17)
  }
}

/// "Open in <Space> ⌘O": dim "Open in", bright space name, keycap.
@MainActor
final class OpenInButton: FlippedView, Themable {
  let prefix = makeLabel("Open in", size: 13, weight: .medium)
  let name = makeLabel(size: 13, weight: .semibold)
  let keycap = Keycap()
  var onClick: (() -> Void)?
  var space = "" { didSet { name.stringValue = space.isEmpty ? "Space" : space; needsLayout = true } }
  var fill: NSColor = .black

  override init(frame: NSRect) {
    super.init(frame: frame)
    keycap.text = "⌘O"
    keycap.font = .systemFont(ofSize: 12, weight: .semibold)
    [prefix, name, keycap].forEach { addSubview($0) }
    toolTip = "Open in Space (⌘O)"
  }
  required init?(coder: NSCoder) { fatalError() }

  var keycapWidth: CGFloat { ceil(("⌘O" as NSString).size(withAttributes: [.font: keycap.font]).width) + 10 }
  var preferredWidth: CGFloat { 8 + ceil(prefix.textWidth) + 2 + ceil(name.textWidth) + 4 + keycapWidth + 6 }

  func apply(_ p: Palette) {
    // PX (dark): button (5,6,39), keycap (23,24,52): BrandBlue deepened toward black. Light: estimate.
    fill = p.dark ? p.primaryButton.blended(withFraction: 0.86, of: .black)! : p.primaryButton.withAlphaComponent(0.1)
    prefix.textColor = p.secondaryText
    name.textColor = p.dark ? NSColor(white: 1, alpha: 0.95) : p.text
    // PX (dark) keycap (23,24,52) = the accent deepened a little less than the button.
    keycap.fill = p.dark ? p.primaryButton.blended(withFraction: 0.72, of: .black)! : p.primaryButton.withAlphaComponent(0.1)
    keycap.fg = p.dark ? NSColor(white: 1, alpha: 0.7) : p.primaryButton
    needsDisplay = true
  }

  override func layout() {
    let h = bounds.height
    var x: CGFloat = 8
    let pw = ceil(prefix.textWidth)
    prefix.frame = NSRect(x: x - 2, y: (h - 17) / 2, width: pw + 4, height: 17); x += pw + 2
    let nw = ceil(name.textWidth)
    name.frame = NSRect(x: x - 2, y: (h - 17) / 2, width: nw + 4, height: 17); x += nw + 4
    keycap.frame = NSRect(x: x, y: (h - 20) / 2, width: keycapWidth, height: 20)
  }

  override func draw(_ dirtyRect: NSRect) {
    fill.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: Tokens.miniFieldRadius, yRadius: Tokens.miniFieldRadius).fill()
  }
  override var mouseDownCanMoveWindow: Bool { false }
  override func mouseUp(with event: NSEvent) {
    if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
  }
}

/// Owns the Little Arc windows for the `window` service.
@MainActor
final class MiniWindows {
  var windows: [String: MiniWindowController] = [:]
  var next = 1
  weak var webviews: WebViewsService?
  weak var host: ServiceHost?
  let wc: DenWindowController

  init(window: DenWindowController) { wc = window }

  /// Spec §8: placed 20 pt from the screen's right edge and 20 pt below the menu bar.
  static func frame(on screen: NSRect, size: CGSize) -> NSRect {
    let m = Tokens.miniScreenMargin
    let w = min(size.width, screen.width - 2 * m), h = min(size.height, screen.height - 2 * m)
    return NSRect(x: screen.maxX - m - w, y: screen.maxY - m - h, width: w, height: h)
  }

  func open(_ args: Value) -> Value {
    let wid = args.str("webview")
    guard let webviews, webviews.record(wid) != nil else { return .error("window: unknown webview '\(wid)'") }
    let id = "mini\(next)"
    next += 1
    let visible = (wc.window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1470, height: 920)
    let size = CGSize(width: args.num("width", Double(Tokens.miniDefaultSize.width)), height: args.num("height", Double(Tokens.miniDefaultSize.height)))
    let web = webviews.materialize(wid)
    let m = MiniWindowController(id: id, webview: wid, web: web, theme: wc.currentTheme, dark: wc.isDark, space: args.str("space", "Space"),
                                 frame: Self.frame(on: visible, size: size))
    let rec = webviews.record(wid)
    m.bar.set(url: rec?.url ?? "", favicon: rec?.favicon ?? "")
    m.onEvent = { [weak host] e, v in host?.emit(e, v) }
    m.onClose = { [weak self] in self?.windows[id] = nil }
    windows[id] = m
    m.panel.makeKeyAndOrderFront(nil)
    return ["id": .string(id)]
  }

  func update(_ args: Value) -> Value {
    guard let m = windows[args.str("id")] else { return .error("window: unknown mini window '\(args.str("id"))'") }
    if let s = args["space"].string { m.bar.space = s }
    return .ok
  }

  func close(_ args: Value) -> Value {
    guard let m = windows[args.str("id")] else { return .error("window: unknown mini window '\(args.str("id"))'") }
    m.panel.close()
    return .ok
  }

  /// Brings a Little Arc window to the front and makes it key (the command bar's Windows rows).
  func focus(_ args: Value) -> Value {
    guard let m = windows[args.str("id")] else { return .error("window: unknown mini window '\(args.str("id"))'") }
    m.panel.makeKeyAndOrderFront(nil)
    return .ok
  }

  func noteURL(_ v: Value) {
    for m in windows.values where m.webview == v.str("id") {
      let rec = webviews?.record(m.webview)
      m.bar.set(url: rec?.url ?? v.str("url"), favicon: rec?.favicon ?? "")
    }
  }

  func refreshTheme() {
    for m in windows.values {
      m.background.theme = wc.currentTheme
      m.panel.appearance = NSAppearance(named: wc.isDark ? .darkAqua : .aqua)
      m.applyPalette(Palette(theme: wc.currentTheme, dark: wc.isDark))
    }
  }
}
