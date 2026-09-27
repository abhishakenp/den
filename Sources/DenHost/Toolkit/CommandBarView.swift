import AppKit
import CordisValue

/// Arc's Command Bar (spec §2), drawn by the host from the `commands` plugin's tree.
///
/// {type:"commandBar", id, query, replaceQuery?, placeholder?, selected: rowId, headers?: bool,
///  inputMode?: "search"|"go", sections: [{title?, rows: [{id, icon, title, subtitle?, accessory?, keycap?}]}]}
/// actions (id = bar id): input {text}, select {row}, submit {row, query, modifiers}, tab {query}, dismiss
///
/// Geometry is in panel coordinates (the 1 pt border included), from the AX frames in
/// docs/reference/arc-ui-spec.md §2 (panel at x 352, y 295 in the dump):
/// search icon 18x18 at (23, 23); text field 23 tall at (53, 20); first row at y 68; rows 750x50 at x 8.
@MainActor
final class CommandBarView: PanelView, NSTextFieldDelegate {
  @MainActor enum M {
    static let iconOrigin = NSPoint(x: 23, y: 23)  // AX: image (375,318) - panel (352,295)
    static let fieldX: CGFloat = 53  // AX: text field x 405
    static let fieldY: CGFloat = 20  // AX: text field y 315
    static let fieldHeight: CGFloat = 23  // AX
    static let fieldTrailing: CGFloat = 57  // AX: 656 wide in a 766 panel (the info button sits there)
    static let listTop: CGFloat = 68  // AX: first row y 363
    static let dividerY: CGFloat = 64  // estimate: the input row is centered on y 32 (icon 23+9, field 20+11.5)
    static let rowX: CGFloat = 8  // AX: row x 360 (7 inside the 1 pt border)
    static let bottomPadding: CGFloat = 8  // estimate (Arc's measured bar ends in its banner)
    static let headerHeight: CGFloat = 28  // estimate (Arc's main list has no headers)
    // Fonts. Row text: SF 13.5 regular fits the AX label widths ("Switch to Tab" 86, "The Browser
    // Company" 142, "— youtube.com/c/thebrowsercompany" 241) within 2 pt; a 23 pt borderless field is SF 20.
    static var rowFont: NSFont { NSFont.systemFont(ofSize: 13.5) }
    static var fieldFont: NSFont { NSFont.systemFont(ofSize: 20, weight: .light) }
    static var headerFont: NSFont { NSFont.systemFont(ofSize: 11, weight: .semibold) }
    // Search-mode caret (spec §13, CAR): light (0.388,0.584,0.988), dark (0.290,0.467,0.831).
    static func searchCaret(_ dark: Bool) -> NSColor {
      dark ? NSColor(srgbRed: 0.290, green: 0.467, blue: 0.831, alpha: 1) : NSColor(srgbRed: 0.388, green: 0.584, blue: 0.988, alpha: 1)
    }
    // Border ramp (spec §2, PX dark): outer pixel (61,61,61), inner pixel (78,78,82).
    static let darkBorderOuter = NSColor(srgbRed: 61 / 255, green: 61 / 255, blue: 61 / 255, alpha: 1)
    static let darkBorderInner = NSColor(srgbRed: 78 / 255, green: 78 / 255, blue: 82 / 255, alpha: 1)
  }

  /// Palette-derived colors (ARC_CommandBar tokens, spec §2).
  @MainActor struct Colors {
    let dark: Bool
    let text: NSColor, secondary: NSColor, hover: NSColor, accessory: NSColor, divider: NSColor, placeholder: NSColor
    let selection: NSColor, selectionKeycap: NSColor, tint: NSColor
    init(_ p: Palette) {
      dark = p.dark
      let ink = NSColor(white: p.dark ? 1 : 0, alpha: 1)
      text = ink.withAlphaComponent(0.80)  // TextPrimary
      secondary = ink.withAlphaComponent(0.33)  // TextSecondary
      hover = ink.withAlphaComponent(0.05)  // RowHoverBackground
      accessory = ink.withAlphaComponent(0.05)  // AccessoryBackground
      divider = ink.withAlphaComponent(0.10)  // HairlineDivider
      placeholder = ink.withAlphaComponent(0.30)  // PlaceholderPlaceholderText (spec §3)
      // Spec §2: the selected row is tinted by the theme ((65,72,216) in Arc's default theme). den keeps
      // the theme hue but lays it over the panel as a soft wash (estimate: α0.30 dark, 0.16 light),
      // so the text keeps TextPrimary instead of turning into a white-on-color slab.
      tint = p.accentStrong
      selection = p.accentStrong.withAlphaComponent(p.dark ? 0.30 : 0.16)
      selectionKeycap = p.accentStrong.withAlphaComponent(p.dark ? 0.45 : 0.22)  // estimate
    }
  }

  /// A 50 pt suggestion row (spec §2): favicon 16 at +16, title at +43, subtitle right after it,
  /// trailing accessory label then a 21x21 keycap 17 pt from the right edge.
  final class Row: FlippedView {
    let icon = IconView()
    let title = makeLabel(size: 13.5), subtitle = makeLabel(size: 13.5), accessory = makeLabel(size: 13.5)
    let keycap = Keycap()
    var rowId = ""
    var selected = false { didSet { if selected != oldValue { needsDisplay = true } } }
    var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    var fill: NSColor = .clear
    var hoverFill: NSColor = .clear
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    override init(frame: NSRect) {
      super.init(frame: frame)
      [title, subtitle, accessory].forEach { $0.font = M.rowFont }
      keycap.font = .systemFont(ofSize: 11, weight: .semibold)
      [icon, title, subtitle, accessory, keycap].forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError() }
    /// Spec §2: highlight inset 10 horizontally and 2 vertically inside the 50 pt row, radius 6.
    var highlight: NSRect { bounds.insetBy(dx: Tokens.commandBarHighlightInsetX, dy: Tokens.commandBarHighlightInsetY) }
    override func draw(_ dirtyRect: NSRect) {
      guard selected || hovering else { return }
      (selected ? fill : hoverFill).setFill()
      let r = Tokens.commandBarHighlightRadius
      NSBezierPath(roundedRect: highlight, xRadius: r, yRadius: r).fill()
    }
    override func layout() {
      let h = bounds.height
      icon.frame = NSRect(x: 16, y: (h - 16) / 2, width: 16, height: 16)  // AX: +16, y +17
      // AX: keycap 21x21 ends 17 pt from the right; accessory label ends 8 pt before the keycap.
      var right = bounds.width - 17
      keycap.isHidden = keycap.text.isEmpty
      if !keycap.isHidden {
        let kw = max(21, keycap.preferredWidth)
        keycap.frame = NSRect(x: right - kw, y: (h - 21) / 2, width: kw, height: 21)
        right -= kw + 8
      }
      let aw = accessory.stringValue.isEmpty ? 0 : ceil(accessory.textWidth) + 4  // label cells pad 2 per side
      accessory.frame = NSRect(x: right - aw, y: (h - 18) / 2, width: aw, height: 18)
      if aw > 0 { right -= aw + 12 }
      let tw = min(ceil(title.textWidth) + 4, max(0, right - 43))
      title.frame = NSRect(x: 43, y: (h - 18) / 2, width: tw, height: 18)  // AX: +43, 18 tall, y +16
      let sx = 43 + tw + 2  // AX: "— youtube.com…" starts 2 pt after the title's frame
      subtitle.frame = NSRect(x: sx, y: (h - 18) / 2, width: max(0, right - sx), height: 18)
    }
    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      trackingAreas.forEach(removeTrackingArea)
      addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) {
      hovering = true
      onHover?()
    }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) { onClick?() }
  }

  /// The input field; tells the bar when it gains focus so the field editor's caret gets the mode color.
  final class Field: NSTextField {
    var onFocus: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
      let ok = super.becomeFirstResponder()
      if ok { onFocus?() }
      return ok
    }
  }

  /// Arc's default-browser banner (spec §2, AX): 764x60 at the bottom, inside the border.
  /// App icon 18x18 at (22, 21); text (SF 13.5, TextSecondary) at x 51; "Try for a week" 110x38
  /// and the primary button 131x38, 8 pt apart and 10 pt before a 24x24 close button 22 pt from
  /// the right edge. Background BannerBackground #161616 / #FDFDFE.
  /// Emits `banner {button: "try" | "set" | "close"}`.
  final class Banner: FlippedView {
    let icon = IconView()
    let label = makeLabel(size: 13.5)
    var secondary: PillButton?
    var primary: PillButton?
    let close = CloseButton()
    var onButton: ((String) -> Void)?
    var bg: NSColor = .clear
    override init(frame: NSRect) {
      super.init(frame: frame)
      icon.spec = "app:icon"
      label.font = M.rowFont
      close.onClick = { [weak self] in self?.onButton?("close") }
      [icon, label, close].forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ v: Value) {
      label.stringValue = v.str("text")
      if secondary?.label.stringValue != v.str("secondary") || primary?.label.stringValue != v.str("primary") {
        secondary?.removeFromSuperview()
        primary?.removeFromSuperview()
        let s = PillButton(title: v.str("secondary"), style: "secondary") { [weak self] in self?.onButton?("try") }
        let p = PillButton(title: v.str("primary"), style: "default") { [weak self] in self?.onButton?("set") }
        for b in [s, p] {
          b.cornerRadius = 8  // not measured; slightly rounder than the dialog buttons (6)
          addSubview(b)
        }
        (secondary, primary) = (s, p)
      }
      needsLayout = true
    }
    func apply(_ p: Palette) {
      bg = p.dark ? NSColor(srgbRed: 0x16 / 255, green: 0x16 / 255, blue: 0x16 / 255, alpha: 1) : NSColor(srgbRed: 0xFD / 255, green: 0xFD / 255, blue: 0xFE / 255, alpha: 1)
      label.textColor = NSColor(white: p.dark ? 1 : 0, alpha: 0.33)
      close.tint = NSColor(white: p.dark ? 1 : 0, alpha: 0.33)
      close.hoverFill = NSColor(white: p.dark ? 1 : 0, alpha: 0.05)
      for b in [secondary, primary].compactMap({ $0 }) {
        b.apply(p)
        if b.style == "secondary" && !p.dark {
          // Light: a quiet white pill with a hairline (estimate; Arc's light banner wasn't measured).
          b.fill = .white
          b.border = NSColor(white: 0, alpha: 0.12)
          b.label.textColor = NSColor(white: 0, alpha: 0.8)
        }
      }
      needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
      bg.setFill()
      bounds.fill()
    }
    override func layout() {
      let h = bounds.height
      icon.frame = NSRect(x: 22, y: (h - 18) / 2, width: 18, height: 18)
      close.frame = NSRect(x: bounds.width - 22 - 24, y: (h - 24) / 2, width: 24, height: 24)
      var x = close.frame.minX - 10
      if let p = primary {
        let w = max(131, p.preferredWidth)
        p.frame = NSRect(x: x - w, y: (h - 38) / 2, width: w, height: 38)
        x -= w + 8
      }
      if let s = secondary {
        let w = max(110, s.preferredWidth)
        s.frame = NSRect(x: x - w, y: (h - 38) / 2, width: w, height: 38)
        x -= w + 12
      }
      label.frame = NSRect(x: 51, y: (h - 18) / 2, width: max(0, x - 51), height: 18)
    }
  }

  /// The banner's 24x24 "×".
  final class CloseButton: FlippedView {
    let glyph = IconView()
    var onClick: (() -> Void)?
    var tint: NSColor = .secondaryLabelColor { didSet { glyph.tint = tint } }
    var hoverFill: NSColor = .clear
    var hovering = false { didSet { needsDisplay = true } }
    override init(frame: NSRect) {
      super.init(frame: frame)
      glyph.spec = "sf:xmark"
      addSubview(glyph)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { glyph.frame = bounds.insetBy(dx: 6.5, dy: 6.5) }
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
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
  }

  /// The 1 pt border as its measured two-pixel ramp: an outer and an inner half-point stroke.
  /// Drawn (not a layer border) so it also shows in `--snapshot` renders; ignores the mouse.
  final class Border: NSView {
    var outer: NSColor = .clear, inner: NSColor = .clear
    var radius: CGFloat = 15
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
      for (inset, color) in [(CGFloat(0.25), outer), (CGFloat(0.75), inner)] {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: radius - inset, yRadius: radius - inset)
        path.lineWidth = 0.5
        color.setStroke()
        path.stroke()
      }
    }
  }

  /// Where the mouse was when hover last moved the selection. Rows are rebuilt on every
  /// keystroke; a row appearing under a still mouse must not steal the selection.
  var lastHoverPoint: NSPoint?

  let input = Field()
  let searchIcon = IconView()
  let list = FlippedView()
  let separator = NSView()
  let border = Border()
  let banner = Banner()
  static let bannerHeight: CGFloat = 60  // AX
  var rows: [Row] = []
  var headers: [NSTextField] = []
  var node: Value = .null
  var rowIds: [String] = []
  var selected = ""
  var palette: Palette?
  let emit: (String, String, Value) -> Void

  init(emit: @escaping (String, String, Value) -> Void) {
    self.emit = emit
    super.init(radius: Tokens.commandBarCornerRadius)
    input.isBordered = false
    input.drawsBackground = false
    input.focusRingType = .none
    input.font = M.fieldFont
    input.delegate = self
    input.cell?.isScrollable = true
    input.cell?.wraps = false
    input.onFocus = { [weak self] in self?.applyCaret() }
    searchIcon.spec = "sf:magnifyingglass"
    separator.wantsLayer = true
    surface.layer?.borderWidth = 0
    banner.onButton = { [weak self] b in
      guard let self else { return }
      self.emit(self.barId, "banner", ["button": .string(b)])
    }
    [searchIcon, input, separator, list, banner, border].forEach { surface.addSubview($0) }
  }
  required init?(coder: NSCoder) { fatalError() }

  var barId: String { node.str("id", "commandBar") }
  var showsHeaders: Bool { node.flag("headers", true) }

  func update(_ v: Value, palette p: Palette) {
    node = v
    palette = p
    if lastHoverPoint == nil { lastHoverPoint = NSEvent.mouseLocation }
    let q = v.str("query")
    // Don't fight the user's typing: only replace text the plugin changed on purpose.
    if input.currentEditor() == nil || v.flag("replaceQuery") || input.stringValue.isEmpty { input.stringValue = q }
    placeholder = v.str("placeholder", "Search or Enter URL…")
    // Rows are reused by position, so a keystroke that keeps the same rows doesn't rebuild views.
    let specs = v.list("sections").flatMap { $0.list("rows") }
    while rows.count > specs.count { rows.removeLast().removeFromSuperview() }
    while rows.count < specs.count {
      let r = Row()
      rows.append(r)
      list.addSubview(r)
    }
    rowIds = []
    for (r, rv) in zip(rows, specs) {
      r.rowId = rv.str("id")
      r.icon.spec = rv.str("icon", "sf:globe")
      r.icon.fallbackLetter = rv.str("title")
      r.title.stringValue = rv.str("title")
      r.subtitle.stringValue = rv.str("subtitle")
      r.accessory.stringValue = rv.str("accessory")
      r.keycap.text = rv.str("keycap")
      r.onClick = { [weak self, rid = r.rowId] in self?.submit(rid, modifiers: []) }
      r.onHover = { [weak self, rid = r.rowId] in self?.hover(rid, at: NSEvent.mouseLocation) }
      r.toolTip = rv.str("subtitle").isEmpty ? nil : rv.str("subtitle")
      r.needsLayout = true
      rowIds.append(r.rowId)
    }
    headers.forEach { $0.removeFromSuperview() }
    headers = v.list("sections").map { sec in
      let t = showsHeaders ? sec.str("title") : ""
      let h = makeLabel(t, size: 11, weight: .semibold)
      h.font = M.headerFont
      if !t.isEmpty { list.addSubview(h) }
      return h
    }
    banner.isHidden = v["banner"].isNull
    if !banner.isHidden { banner.update(v["banner"]) }
    selected = v.str("selected", rowIds.first ?? "")
    apply(p)
    needsLayout = true
  }

  var placeholder = "" {
    didSet { if let p = palette { applyPlaceholder(Colors(p)) } }
  }

  func applyPlaceholder(_ c: Colors) {
    input.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.font: M.fieldFont, .foregroundColor: c.placeholder])
  }

  /// Search mode uses Arc's measured caret color; Go (URL) mode uses the space's accent (den choice,
  /// Arc's Go color wasn't measured). The text selection is the same hue, lighter.
  var caretColor: NSColor {
    guard let p = palette else { return .controlAccentColor }
    return node.str("inputMode") == "go" ? p.accentStrong : M.searchCaret(p.dark)
  }

  func applyCaret() {
    guard let ed = input.currentEditor() as? NSTextView else { return }
    let c = caretColor
    ed.insertionPointColor = c
    ed.selectedTextAttributes = [.backgroundColor: c.withAlphaComponent(palette?.dark == true ? 0.45 : 0.25)]  // estimate
  }

  override func apply(_ p: Palette) {
    super.apply(p)
    palette = p
    let c = Colors(p)
    surface.layer?.borderWidth = 0
    if p.dark {
      border.outer = M.darkBorderOuter
      border.inner = M.darkBorderInner
    } else {
      // Light border: not measured; a hairline at HairlineDivider strength (estimate).
      border.outer = NSColor(white: 0, alpha: 0.10)
      border.inner = NSColor(white: 0, alpha: 0.04)
    }
    border.needsDisplay = true
    input.textColor = c.text
    applyPlaceholder(c)
    applyCaret()
    searchIcon.tint = c.secondary
    separator.layer?.backgroundColor = c.divider.cgColor
    for r in rows {
      r.selected = r.rowId == selected
      r.fill = c.selection
      r.hoverFill = c.hover
      r.title.textColor = c.text
      r.subtitle.textColor = c.secondary
      r.accessory.textColor = c.secondary
      r.icon.tint = r.selected ? c.tint.blended(withFraction: p.dark ? 0.35 : 0, of: .white) ?? c.tint : c.text
      r.keycap.fill = r.selected ? c.selectionKeycap : c.accessory
      r.keycap.fg = r.selected ? c.text : c.secondary
      r.keycap.border = nil
      r.keycap.needsDisplay = true
    }
    for h in headers { h.textColor = c.secondary }
    banner.apply(p)
  }

  var shownRows: Int { min(rows.count, Tokens.commandBarMaxRows) }

  var contentHeight: CGFloat {
    let n = shownRows
    let b: CGFloat = banner.isHidden ? 0 : Self.bannerHeight + 1  // + the bottom border
    guard n > 0 else { return M.dividerY + b }
    let sections = headers.filter { !$0.stringValue.isEmpty }.count
    return M.listTop + CGFloat(n) * Tokens.commandBarRowHeight + CGFloat(sections) * M.headerHeight + M.bottomPadding + b
  }

  override func layout() {
    super.layout()
    let scale = window?.backingScaleFactor ?? 2
    border.frame = bounds
    border.radius = radius
    // AX: the banner is 764 wide at x 1, its bottom on the inner edge of the 1 pt border.
    banner.frame = NSRect(x: 1, y: bounds.height - 1 - Self.bannerHeight, width: bounds.width - 2, height: Self.bannerHeight)
    searchIcon.frame = NSRect(origin: M.iconOrigin, size: NSSize(width: 18, height: 18))
    input.frame = NSRect(x: M.fieldX, y: M.fieldY, width: bounds.width - M.fieldX - M.fieldTrailing, height: M.fieldHeight)
    separator.frame = NSRect(x: 0, y: M.dividerY - 1 / scale, width: bounds.width, height: rows.isEmpty ? 0 : 1 / scale)
    list.frame = NSRect(x: 0, y: M.dividerY, width: bounds.width, height: max(0, bounds.height - M.dividerY))
    var y = M.listTop - M.dividerY
    var ri = 0
    for (si, sec) in node.list("sections").enumerated() {
      let n = sec.list("rows").count
      if si < headers.count, !headers[si].stringValue.isEmpty, n > 0, ri < Tokens.commandBarMaxRows {
        headers[si].isHidden = false
        headers[si].frame = NSRect(x: M.rowX + 16, y: y + 8, width: bounds.width - 2 * (M.rowX + 16), height: 16)
        y += M.headerHeight
      } else if si < headers.count {
        headers[si].isHidden = true
      }
      for _ in 0..<n where ri < rows.count {
        let r = rows[ri]
        r.isHidden = ri >= Tokens.commandBarMaxRows
        ri += 1
        if r.isHidden { continue }
        r.frame = NSRect(x: M.rowX, y: y, width: bounds.width - 2 * M.rowX, height: Tokens.commandBarRowHeight)
        y += Tokens.commandBarRowHeight
      }
    }
  }

  func move(_ d: Int) {
    let visible = Array(rowIds.prefix(Tokens.commandBarMaxRows))
    guard !visible.isEmpty else { return }
    let i = visible.firstIndex(of: selected) ?? -1
    selected = visible[((i + d) % visible.count + visible.count) % visible.count]
    if let p = palette { apply(p) }
    emit(barId, "select", ["row": .string(selected)])
  }

  /// Arc: hovering a row selects it (emits `select`), as the arrow keys do.
  func hover(_ row: String, at point: NSPoint) {
    defer { lastHoverPoint = point }
    guard let last = lastHoverPoint, last != point, row != selected else { return }
    selected = row
    if let p = palette { apply(p) }
    emit(barId, "select", ["row": .string(row)])
  }

  func submit(_ row: String, modifiers: [Value]) {
    emit(barId, "submit", ["row": .string(row), "query": .string(input.stringValue), "modifiers": .array(modifiers)])
  }

  func controlTextDidChange(_ obj: Notification) {
    applyCaret()
    emit(barId, "input", ["text": .string(input.stringValue)])
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
    switch sel {
    case #selector(NSResponder.moveDown(_:)): move(1)
    case #selector(NSResponder.moveUp(_:)): move(-1)
    case #selector(NSResponder.insertNewline(_:)):
      var mods: [Value] = []
      let f = NSApp.currentEvent?.modifierFlags ?? []
      if f.contains(.shift) { mods.append("shift") }
      if f.contains(.command) { mods.append("cmd") }
      if f.contains(.option) { mods.append("opt") }
      submit(selected, modifiers: mods)
    case #selector(NSResponder.cancelOperation(_:)): emit(barId, "dismiss", .null)
    case #selector(NSResponder.insertTab(_:)): emit(barId, "tab", ["query": .string(input.stringValue)])
    default: return false
    }
    return true
  }
}
