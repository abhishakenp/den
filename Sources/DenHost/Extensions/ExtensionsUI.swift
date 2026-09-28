import AppKit
import CordisValue
import WebKit

/// Host UI for extensions: the extensions menu (from the URL pill's puzzle button), action popups,
/// and the pinned extension buttons the URL pill shows on hover. All of it is created on first use.
///
/// Arc shows pinned extensions in the URL bar and every extension in the Site Control Center.
/// Its popover geometry was never measured (spec §12), so sizes here are estimates (`Tokens.extension*`).
@MainActor
final class ExtensionsUI {
  struct Item {
    var id: String
    var title: String
    var image: NSImage?
    var badge: String
    var pinned: Bool
    var enabled: Bool
    var loaded: Bool
  }

  /// Each window's extensions UI, for its URL pill (rendered by the shared toolkit). Weak both ways.
  private static let byWindow = NSMapTable<NSWindow, ExtensionsUI>.weakToWeakObjects()
  static func of(_ window: NSWindow?) -> ExtensionsUI? { window.flatMap { byWindow.object(forKey: $0) } }

  weak var svc: ExtensionsService?
  let wc: DenWindowController
  private(set) var items: [Item] = []
  private lazy var backdrop: BackdropView = {
    let b = BackdropView()
    b.onClick = { [weak self] in self?.close() }
    return b
  }()
  private lazy var panel = ExtensionPanelView()
  private var menuView: ExtensionsMenuView?
  private(set) var menuOpen = false
  private(set) var popupFor: String?
  private var popupAction: WKWebExtension.Action?
  private var popupWeb: WKWebView?
  private var popupSize: CGSize = .zero
  var popupSizeForTesting: CGSize { popupSize }
  var popupWebForTesting: WKWebView? { popupWeb }
  private var sizeTimer: Timer?
  private var keyMonitor: Any?
  var pendingAnchor: NSRect?
  var pendingPopup: String?
  private(set) var storePending: String?

  init(window: DenWindowController) {
    wc = window
    Self.byWindow.setObject(self, forKey: window.window)
  }

  var palette: Palette { Palette(theme: wc.currentTheme, dark: wc.isDark) }

  // MARK: State

  /// Re-reads the items (pill, open menu). Cheap: nothing happens while no extension is installed.
  func refresh() {
    guard let svc else { return }
    items = svc.menuItems()
    storeOffer = svc.selectedStoreOffer()
    NotificationCenter.default.post(name: Self.changedNotification, object: self)
    if menuOpen { menuView?.update(items, palette: palette); layout() }
  }
  static let changedNotification = Notification.Name("den.extensionsChanged")

  var pinnedItems: [Item] { items.filter { $0.pinned && $0.loaded } }
  var hasExtensions: Bool { !items.isEmpty }

  func storeState(pending: String?) {
    storePending = pending
    NotificationCenter.default.post(name: Self.changedNotification, object: self)
    guard let svc else { return }
    for r in svc.webviews.records.values { if let w = r.webView, let h = w.url?.host, ExtensionPackage.isStoreHost(h) { svc.pageChanged(w) } }
  }

  // MARK: Store offer

  /// The store item the selected tab shows, while it isn't installed: the URL pill offers
  /// "Add to den" for it. den's own button, so installing never depends on the store's page.
  private(set) var storeOffer: StoreRef?

  func refreshStoreOffer() {
    let o = svc?.selectedStoreOffer()
    guard o != storeOffer else { return }
    storeOffer = o
    NotificationCenter.default.post(name: Self.changedNotification, object: self)
  }

  func addStoreOffer() {
    guard let o = storeOffer, storePending == nil else { return }
    svc?.installCurrentStorePage(o)
  }

  // MARK: Pill

  weak var pill: NSView?

  /// Pill button clicked: an extension's action, or the menu.
  func pillClicked(_ id: String, from view: NSView) {
    let anchor = wc.overlays.convert(view.bounds, from: view)
    if id == "menu" {
      if menuOpen { close() } else { showMenu(anchor: anchor) }
    } else {
      _ = svc?.performAction(id, anchor: anchor)
    }
  }

  var pillAnchor: NSRect {
    if let p = pill, p.window != nil, !p.isHiddenOrHasHiddenAncestor { return wc.overlays.convert(p.bounds, from: p) }
    // Sidebar hidden: under the top-left corner of the content.
    let c = wc.overlays.convert(wc.contentArea.frame, from: wc.contentArea.superview)
    return NSRect(x: c.minX + 12, y: c.minY + 6, width: 200, height: 1)
  }

  // MARK: Menu

  // thin-host: feature-specific, migrate to plugin
  func showMenu(anchor: NSRect? = nil) {
    refresh()
    closePopup()
    let m = menuView ?? ExtensionsMenuView()
    menuView = m
    m.onPick = { [weak self] id in
      guard let self else { return }
      let a = self.panelAnchor
      self.close()
      _ = self.svc?.performAction(id, anchor: a)
    }
    m.onPin = { [weak self] id, on in _ = self?.svc?.setPinned(id, on) }
    m.onFooter = { [weak self] which in
      guard let self, let svc = self.svc else { return }
      self.close()
      if which == "manage" {
        svc.host.emit("webext.openPage", .null)
      } else {
        _ = svc.openTab(URL(string: "https://chromewebstore.google.com/category/extensions"), active: true, pinned: false)
      }
    }
    m.update(items, palette: palette)
    panelAnchor = anchor ?? pillAnchor
    present(m)
    menuOpen = true
    layout()
  }

  private var panelAnchor: NSRect = .zero

  private func present(_ v: NSView) {
    TestMode.keepActive(v)  // tests: the invisible window mustn't throttle the popup's page
    panel.setContent(v)
    panel.apply(palette)
    if backdrop.superview == nil { wc.overlays.addSubview(backdrop) }
    if panel.superview == nil { wc.overlays.addSubview(panel) }
    if keyMonitor == nil {
      keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
        guard e.keyCode == 53, let self, self.menuOpen || self.popupFor != nil else { return e }
        MainActor.assumeIsolated { self.close() }
        return nil
      }
    }
    let prev = wc.onLayout
    if !layoutHooked {
      layoutHooked = true
      wc.onLayout = { [weak self] in prev?(); self?.layout() }
    }
  }
  private var layoutHooked = false

  func layout() {
    guard panel.superview != nil else { return }
    let b = wc.overlays.bounds
    backdrop.frame = b
    let size: CGSize
    if menuOpen, let m = menuView {
      size = CGSize(width: Tokens.extensionMenuWidth, height: m.contentHeight)
    } else {
      size = popupSize
    }
    let x = min(max(10, panelAnchor.minX), max(10, b.width - size.width - 10))
    let y = min(max(10, panelAnchor.maxY + Tokens.extensionPanelGap), max(10, b.height - size.height - 10))
    panel.frame = NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
  }

  // MARK: Popups

  func showPopup(_ web: WKWebView, action: WKWebExtension.Action, id: String) {
    if menuOpen { menuOpen = false }
    closePopup()
    popupFor = id
    popupAction = action
    popupWeb = web
    panelAnchor = pendingAnchor ?? pillAnchor
    pendingAnchor = nil
    pendingPopup = nil
    // Measured at the largest size first; shown once the page reports its own size.
    popupSize = CGSize(width: Tokens.extensionPopupMax.width, height: Tokens.extensionPopupMin.height)
    panel.alphaValue = 0
    present(web)
    layout()
    measurePopup(attempt: 0)
    wc.window.makeFirstResponder(web)
  }

  /// Chrome sizes popups to their content, between 25x25 and 800x600: the width is the page's
  /// fit-content width, the height its scroll height at that width. Re-measured while open, so
  /// popups that grow after loading data resize.
  private func measurePopup(attempt: Int) {
    guard let web = popupWeb else { return }
    let js = """
      (() => { const d = document.documentElement, b = document.body; if (!b) return null;
        const old = d.style.width; d.style.width = 'fit-content'; const w = d.getBoundingClientRect().width; d.style.width = old;
        return [Math.ceil(w), Math.ceil(Math.max(d.scrollHeight, b.scrollHeight))]; })()
      """
    web.evaluateJavaScript(js) { [weak self] r, _ in
      MainActor.assumeIsolated {
        guard let self, self.popupWeb === web else { return }
        if let a = r as? [NSNumber], a.count == 2, a[0].doubleValue > 1, a[1].doubleValue > 1 {
          let mn = Tokens.extensionPopupMin, mx = Tokens.extensionPopupMax
          let s = CGSize(width: min(mx.width, max(mn.width, a[0].doubleValue)), height: min(mx.height, max(mn.height, a[1].doubleValue)))
          if s != self.popupSize {
            self.popupSize = s
            self.layout()
          }
          if self.panel.alphaValue == 0 { self.reveal() }
        }
        // Fast at first (the page is loading), then twice a second while open.
        let delays = [50, 100, 150, 250, 400, 600]
        let ms = attempt < delays.count ? delays[attempt] : 500
        if attempt > 12, self.panel.alphaValue == 0 { self.reveal() }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) { [weak self] in self?.measurePopup(attempt: attempt + 1) }
      }
    }
  }

  private func reveal() {
    let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    if reduce { panel.alphaValue = 1; return }
    let final = panel.frame
    panel.frame = final.offsetBy(dx: 0, dy: -4)
    NSAnimationContext.runAnimationGroup { c in
      c.duration = 0.16  // estimate: the hover card's fade (Dia curve)
      c.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
      panel.animator().alphaValue = 1
      panel.animator().frame = final
    }
  }

  private func closePopup() {
    guard popupFor != nil else { return }
    popupAction?.closePopup()
    popupWeb?.removeFromSuperview()
    popupFor = nil
    popupAction = nil
    popupWeb = nil
  }

  func close() {
    closePopup()
    menuOpen = false
    panel.removeFromSuperview()
    backdrop.removeFromSuperview()
    panel.alphaValue = 1
    if let k = keyMonitor { NSEvent.removeMonitor(k) }
    keyMonitor = nil
  }
}

// MARK: - Views

/// Arc-style popover surface: PopoverBackground #FAFBFF / #151C30 with a hairline border and shadow.
@MainActor
final class ExtensionPanelView: PanelView {
  private var content: NSView?
  init() {
    super.init(radius: Tokens.extensionPanelRadius)
    elevation = .popover
  }
  required init?(coder: NSCoder) { fatalError() }
  func setContent(_ v: NSView) {
    if content !== v { content?.removeFromSuperview() }
    content = v
    if v.superview !== surface { surface.addSubview(v) }
    needsLayout = true
  }
  override func apply(_ p: Palette) {
    super.apply(p)
    surface.layer?.backgroundColor = p.popover.cgColor
    content?.applyPaletteRecursively(p)
  }
  override func layout() {
    super.layout()
    content?.frame = surface.bounds
  }
}

/// The extensions menu: every enabled extension (click runs its action, the pin toggles it in the
/// URL pill), then "Manage Extensions" and "Get Extensions".
@MainActor
// thin-host: feature-specific, migrate to plugin
final class ExtensionsMenuView: FlippedView, Themable {
  var onPick: ((String) -> Void)?
  var onPin: ((String, Bool) -> Void)?
  var onFooter: ((String) -> Void)?
  private let header = makeLabel("Extensions", size: 12, weight: .semibold)
  private var rows: [ExtensionMenuRow] = []
  private var footer: [ExtensionMenuRow] = []
  private let divider = NSView()
  private let empty = makeLabel("No extensions yet", size: 13)

  override init(frame: NSRect) {
    super.init(frame: frame)
    divider.wantsLayer = true
    [header, divider, empty].forEach { addSubview($0) }
    footer = [("manage", "Manage Extensions", "sf:puzzlepiece.extension"), ("get", "Get Extensions", "sf:plus.circle")].map { id, title, icon in
      let r = ExtensionMenuRow()
      r.configure(id: id, title: title, image: nil, symbol: icon, badge: "", pinned: nil)
      r.onClick = { [weak self] in self?.onFooter?(id) }
      addSubview(r)
      return r
    }
  }
  required init?(coder: NSCoder) { fatalError() }

  func update(_ items: [ExtensionsUI.Item], palette p: Palette) {
    rows.forEach { $0.removeFromSuperview() }
    rows = items.map { it in
      let r = ExtensionMenuRow()
      r.configure(id: it.id, title: it.title, image: it.image, symbol: "sf:puzzlepiece.extension", badge: it.badge, pinned: it.pinned)
      r.dimmed = !it.enabled
      r.onClick = { [weak self] in self?.onPick?(it.id) }
      r.onPin = { [weak self] in self?.onPin?(it.id, !it.pinned) }
      addSubview(r)
      return r
    }
    empty.isHidden = !items.isEmpty
    apply(p)
    needsLayout = true
  }

  func apply(_ p: Palette) {
    header.textColor = p.secondaryText
    empty.textColor = p.secondaryText
    divider.layer?.backgroundColor = p.divider.cgColor
    (rows + footer).forEach { $0.apply(p) }
  }

  var contentHeight: CGFloat {
    let pad = Tokens.extensionMenuPadding, rh = Tokens.extensionMenuRowHeight
    return pad + 26 + (rows.isEmpty ? rh : CGFloat(rows.count) * rh) + 9 + CGFloat(footer.count) * rh + pad
  }

  override func layout() {
    super.layout()
    let pad = Tokens.extensionMenuPadding, rh = Tokens.extensionMenuRowHeight, w = bounds.width
    header.frame = NSRect(x: pad + 8, y: pad + 4, width: w - 2 * pad - 16, height: 16)
    var y = pad + 26
    if rows.isEmpty {
      empty.frame = NSRect(x: pad + 8, y: y + (rh - 17) / 2, width: w - 2 * pad - 16, height: 17)
      y += rh
    }
    for r in rows { r.frame = NSRect(x: pad, y: y, width: w - 2 * pad, height: rh); y += rh }
    divider.frame = NSRect(x: pad + 8, y: y + 4, width: w - 2 * pad - 16, height: 1)
    y += 9
    for r in footer { r.frame = NSRect(x: pad, y: y, width: w - 2 * pad, height: rh); y += rh }
  }
}

/// One menu row: icon, title, badge, and (for extensions) a pin toggle shown on hover or when pinned.
@MainActor
final class ExtensionMenuRow: FlippedView, Themable {
  var onClick: (() -> Void)?
  var onPin: (() -> Void)?
  var dimmed = false { didSet { alphaValue = dimmed ? 0.45 : 1 } }
  private let icon = IconView()
  private let image = NSImageView()
  private let title = makeLabel(size: 13)
  private let badge = ExtensionBadge()
  private lazy var pin = IconButton(symbol: "sf:pin", size: 24) { [weak self] in self?.onPin?() }
  private var pinned: Bool?
  private var hovering = false { didSet { needsDisplay = true; updatePin() } }
  private var palette: Palette?

  func configure(id: String, title t: String, image img: NSImage?, symbol: String, badge b: String, pinned p: Bool?) {
    [icon, image, title, badge].forEach { if $0.superview == nil { addSubview($0) } }
    image.image = img
    image.imageScaling = .scaleProportionallyUpOrDown
    image.isHidden = img == nil
    icon.spec = symbol
    icon.isHidden = img != nil
    title.stringValue = t
    badge.text = b
    badge.isHidden = b.isEmpty
    pinned = p
    if p != nil, pin.superview == nil { addSubview(pin) }
    pin.toolTip = p == true ? "Unpin from the URL bar" : "Pin to the URL bar"
    updatePin()
  }

  private func updatePin() {
    guard let p = pinned else { return }
    pin.icon.spec = p ? "sf:pin.fill" : "sf:pin"
    pin.isHidden = !(p || hovering)
  }

  func apply(_ p: Palette) {
    palette = p
    title.textColor = p.text
    icon.tint = p.text.withAlphaComponent(0.7)
    pin.apply(p)
    badge.apply(p)
    needsDisplay = true
  }

  override func layout() {
    super.layout()
    let h = bounds.height
    image.frame = NSRect(x: 8, y: (h - 18) / 2, width: 18, height: 18)
    icon.frame = image.frame
    var right = bounds.width - 6
    if pinned != nil {
      pin.frame = NSRect(x: right - 24, y: (h - 24) / 2, width: 24, height: 24)
      right -= 28
    }
    if !badge.isHidden {
      let bw = badge.preferredWidth
      badge.frame = NSRect(x: right - bw, y: (h - 16) / 2, width: bw, height: 16)
      right -= bw + 6
    }
    title.frame = NSRect(x: 36, y: (h - 17) / 2, width: max(0, right - 38), height: 17)
  }

  override func draw(_ dirtyRect: NSRect) {
    guard hovering, let p = palette else { return }
    p.rowHover.withAlphaComponent(p.dark ? 0.08 : 0.05).setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }
  override func mouseEntered(with event: NSEvent) { hovering = true }
  override func mouseExited(with event: NSEvent) { hovering = false }
  override func mouseDown(with event: NSEvent) {}
  override func mouseUp(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    guard bounds.contains(p) else { return }
    if !pin.isHidden, pin.superview != nil, pin.frame.contains(p) { return }  // the pin button handles its own click
    onClick?()
  }
  override var mouseDownCanMoveWindow: Bool { false }
}

/// Small rounded badge (extension badge text), drawn over or next to an icon.
@MainActor
final class ExtensionBadge: NSView, Themable {
  var text = "" { didSet { needsDisplay = true } }
  var fill = NSColor(srgbRed: 0x31 / 255, green: 0x39 / 255, blue: 0xFB / 255, alpha: 1)
  let font = NSFont.systemFont(ofSize: 9.5, weight: .bold)
  var preferredWidth: CGFloat { max(16, ceil((text as NSString).size(withAttributes: [.font: font]).width) + 8) }
  func apply(_ p: Palette) { fill = p.accentStrong; needsDisplay = true }
  override func draw(_ dirtyRect: NSRect) {
    guard !text.isEmpty else { return }
    fill.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
    let s = (text as NSString).size(withAttributes: attrs)
    (text as NSString).draw(at: NSPoint(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2), withAttributes: attrs)
  }
}

// thin-host: feature-specific, migrate to plugin
/// An extension button in the URL pill: its toolbar icon with the badge in the corner.
@MainActor
final class PillExtensionButton: NSView {
  let id: String
  let image = NSImageView()
  let icon = IconView()
  let badge = ExtensionBadge()
  var onClick: ((PillExtensionButton) -> Void)?
  var hoverFill = NSColor(white: 0, alpha: 0.06)
  private var hovering = false { didSet { needsDisplay = true } }

  init(id: String) {
    self.id = id
    super.init(frame: .zero)
    image.imageScaling = .scaleProportionallyUpOrDown
    [image, icon, badge].forEach { addSubview($0) }
  }
  required init?(coder: NSCoder) { fatalError() }

  func configure(_ it: ExtensionsUI.Item?, symbol: String = "sf:puzzlepiece.extension", tooltip: String) {
    image.image = it?.image
    image.isHidden = it?.image == nil
    icon.spec = symbol
    icon.isHidden = it?.image != nil
    badge.text = it?.badge ?? ""
    badge.isHidden = badge.text.isEmpty
    toolTip = tooltip
    needsLayout = true
  }

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override func layout() {
    super.layout()
    let s: CGFloat = 16
    image.frame = NSRect(x: (bounds.width - s) / 2, y: (bounds.height - s) / 2, width: s, height: s)
    icon.frame = image.frame.insetBy(dx: 0.5, dy: 0.5)
    let bw = min(bounds.width, badge.preferredWidth)
    badge.frame = NSRect(x: bounds.width - bw + 3, y: -2, width: bw, height: 12)
  }
  override func draw(_ dirtyRect: NSRect) {
    guard hovering else { return }
    hoverFill.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }
  override func mouseEntered(with event: NSEvent) { hovering = true }
  override func mouseExited(with event: NSEvent) { hovering = false }
  override func mouseDown(with event: NSEvent) {}
  override func mouseUp(with event: NSEvent) {
    if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?(self) }
  }
}
