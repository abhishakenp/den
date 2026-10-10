import AppKit
import PluginCores
import CordisValue

extension Palette {
  /// Surface of the briefing page and the connections sheet: the theme's surface token.
  var sheetSurface: NSColor { surface }
  /// Rounded `section` card on that surface: the elevated token (white-ish in light, a lift in dark).
  var sectionFill: NSColor { dark ? elevatedSurface : tokens.surface.mix(RGB(1, 1, 1), 0.7).ns }
  var sectionBorder: NSColor { hairline }
  var success: NSColor { NSColor(srgbRed: 0.20, green: 0.72, blue: 0.40, alpha: 1) }
}

/// Briefing page / connections sheet, shown in the `overlay.briefing` and `overlay.connections` slots.
///
/// {type:"sheet", id, style: page|sheet, title, subtitle?, icon?, headerButtons?: [{id, icon, tooltip?}], children}
/// - `page` covers the content area (a new-tab page): content card radius, no dim, a centered
///   column at most 680 wide.
/// - `sheet` is a centered 560-wide panel over a dim, as tall as its content allows.
/// Children are rendered by the shared `Renderer` (reused by type + id), stacked 14 pt apart in a
/// scroll view, so re-sending the tree keeps the scroll position.
/// actions: {id: <sheet id>, action: dismiss} (close button, Esc, dim click);
/// {id: <header button id>, action: click}.
@MainActor
final class SheetView: PanelView {
  let icon = IconView()
  let titleLabel = makeLabel(size: 20, weight: .semibold)
  let subtitleLabel = makeLabel(size: 13)
  lazy var closeButton = IconButton(symbol: "xmark", size: 28) { [weak self] in self?.send("dismiss") }
  var headerButtons: [IconButton] = []
  let scroll = NSScrollView()
  let doc = FlippedView()
  var kids: [NodeView] = []
  var node: Value = .null
  unowned(unsafe) let renderer: Renderer
  let emit: (String, String, Value) -> Void

  init(renderer: Renderer, emit: @escaping (String, String, Value) -> Void) {
    self.renderer = renderer
    self.emit = emit
    super.init(radius: Tokens.sheetCornerRadius)
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.scrollerStyle = .overlay
    scroll.autohidesScrollers = true
    scroll.contentView.drawsBackground = false
    scroll.documentView = doc
    [icon, titleLabel, subtitleLabel, closeButton, scroll].forEach { surface.addSubview($0) }
  }
  required init?(coder: NSCoder) { fatalError() }

  var sheetId: String { node.str("id", "sheet") }
  var isPage: Bool { node.str("style", "sheet") == "page" }
  func send(_ action: String, _ value: Value = .null) { emit(sheetId, action, value) }

  func update(_ v: Value, palette p: Palette) {
    let oldButtons = node.list("headerButtons")
    node = v
    radius = isPage ? Tokens.cardCornerRadius : Tokens.sheetCornerRadius
    surface.layer?.cornerRadius = radius
    // A sheet floats like a dialog; a page sits in the content area like a card, with no rim.
    elevation = isPage ? .card : .modal
    showsRim = !isPage
    showsEdge = !isPage
    icon.spec = v.str("icon")
    icon.isHidden = icon.spec.isEmpty
    titleLabel.stringValue = v.str("title")
    subtitleLabel.stringValue = v.str("subtitle")
    subtitleLabel.isHidden = subtitleLabel.stringValue.isEmpty
    if oldButtons != v.list("headerButtons") || headerButtons.isEmpty != oldButtons.isEmpty {
      headerButtons.forEach { $0.removeFromSuperview() }
      headerButtons = v.list("headerButtons").map { b in
        let id = b.str("id")
        let btn = IconButton(symbol: b.str("icon", "sf:circle"), size: 28) { [weak self] in self?.emit(id, "click", .null) }
        btn.setTip(b.str("tooltip"), shortcut: b.str("shortcutFor"), fallback: b.str("shortcut"))
        surface.addSubview(btn)
        return btn
      }
    }
    kids = renderer.reconcile(v.list("children"), existing: kids, in: doc)
    apply(p)
    needsLayout = true
  }

  override func apply(_ p: Palette) {
    super.apply(p)
    surface.layer?.backgroundColor = p.sheetSurface.cgColor
    surface.layer?.borderWidth = isPage ? 0 : 0.5
    titleLabel.textColor = p.textPrimary
    subtitleLabel.textColor = p.textSecondary
    icon.tint = p.textPrimary
    closeButton.apply(p)
    headerButtons.forEach { $0.apply(p) }
  }

  // MARK: Geometry

  /// Width of the content column for a sheet of width `w`.
  func columnWidth(_ w: CGFloat) -> CGFloat {
    isPage ? min(Tokens.pageColumnMaxWidth, max(200, w - 2 * Tokens.pageSideMargin)) : w - 2 * Tokens.sheetPadding
  }
  var topPadding: CGFloat { isPage ? Tokens.pageTopPadding : Tokens.sheetPadding }

  func stackHeight(_ cw: CGFloat) -> CGFloat {
    let hs = kids.map { $0.height(for: cw) }.filter { $0 > 0 }
    return hs.reduce(0, +) + Tokens.sheetStackSpacing * CGFloat(max(0, hs.count - 1))
  }

  /// Height the `sheet` style wants for width `w` (header, children, padding).
  func contentHeight(width w: CGFloat) -> CGFloat {
    topPadding + Tokens.sheetHeaderHeight + 16 + stackHeight(columnWidth(w)) + Tokens.sheetPadding
  }

  override func layout() {
    super.layout()
    let w = bounds.width, cw = columnWidth(w)
    let x0 = ((w - cw) / 2).rounded()
    let top = topPadding
    let hh = Tokens.sheetHeaderHeight
    var tx = x0
    if !icon.isHidden {
      icon.frame = NSRect(x: x0, y: top + (subtitleLabel.isHidden ? (hh - 22) / 2 : 3), width: 22, height: 22)
      tx += 32
    }
    // Header buttons pack right: [buttons…] [close].
    var right = x0 + cw
    closeButton.frame = NSRect(x: right - 28, y: top + (subtitleLabel.isHidden ? (hh - 28) / 2 : 0), width: 28, height: 28)
    right -= 28 + 6
    for b in headerButtons.reversed() {
      b.frame = NSRect(x: right - 28, y: closeButton.frame.minY, width: 28, height: 28)
      right -= 28 + 4
    }
    let lw = max(0, right - tx - 8)
    if subtitleLabel.isHidden {
      titleLabel.frame = NSRect(x: tx, y: top + (hh - 26) / 2, width: lw, height: 26)
    } else {
      titleLabel.frame = NSRect(x: tx, y: top, width: lw, height: 26)
      subtitleLabel.frame = NSRect(x: tx, y: top + 26, width: lw, height: 17)
    }
    let sy = top + hh + 16
    scroll.frame = NSRect(x: 0, y: sy, width: w, height: max(0, bounds.height - sy))
    let dw = scroll.contentSize.width
    let dx = ((dw - cw) / 2).rounded()
    var y: CGFloat = 0
    for k in kids {
      let h = k.height(for: cw)
      k.frame = NSRect(x: dx, y: y, width: cw, height: h)
      k.isHidden = h == 0
      if h > 0 { y += h + Tokens.sheetStackSpacing }
    }
    doc.frame = NSRect(x: 0, y: 0, width: dw, height: max(y + Tokens.sheetPadding, scroll.contentSize.height))
  }

  // MARK: Keys

  override var acceptsFirstResponder: Bool { true }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 { send("dismiss"); return }
    super.keyDown(with: event)
  }
  override func cancelOperation(_ sender: Any?) { send("dismiss") }
}
