import AppKit
import CordisValue

/// Rounded floating panel surface with shadow, tinted by the palette.
@MainActor
class PanelView: FlippedView, Themable {
  var radius: CGFloat
  let surface = FlippedView()
  init(radius: CGFloat) {
    self.radius = radius
    super.init(frame: .zero)
    wantsLayer = true
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowOpacity = 0.28  // estimate
    layer?.shadowRadius = 24  // estimate
    layer?.shadowOffset = CGSize(width: 0, height: -8)
    surface.wantsLayer = true
    surface.layer?.cornerRadius = radius
    surface.layer?.cornerCurve = .continuous
    surface.layer?.masksToBounds = true
    surface.layer?.borderWidth = 0.5
    addSubview(surface)
  }
  required init?(coder: NSCoder) { fatalError() }
  func apply(_ p: Palette) {
    surface.layer?.backgroundColor = p.panel.cgColor
    surface.layer?.borderColor = NSColor(white: p.dark ? 1 : 0, alpha: 0.1).cgColor
  }
  override func layout() {
    super.layout()
    surface.frame = bounds
    layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
  }
}

// MARK: - Command bar

/// {type:"commandBar", id, query, placeholder?, selected: rowId,
///  sections: [{title?, rows: [{id, icon, title, subtitle?, accessory?}]}]}
/// actions (id = bar id): input {text}, select {row}, submit {row, query, modifiers}, tab {query}, dismiss
@MainActor
final class CommandBarView: PanelView, NSTextFieldDelegate {
  final class Row: FlippedView {
    let icon = IconView(), title = makeLabel(size: 14), subtitle = makeLabel(size: 13), accessory = makeLabel(size: 12, weight: .medium)
    let keycap = Keycap()
    var rowId = ""
    var selected = false { didSet { needsDisplay = true } }
    var hovering = false { didSet { needsDisplay = true } }
    var accent: NSColor = .controlAccentColor
    var hoverFill: NSColor = .clear
    var onClick: (() -> Void)?
    override init(frame: NSRect) {
      super.init(frame: frame)
      [icon, title, subtitle, accessory, keycap].forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError() }
    /// Spec §2: highlight inset 10 horizontally and 2 vertically inside the 50 pt row, radius 6.
    var highlight: NSRect { bounds.insetBy(dx: Tokens.commandBarHighlightInsetX, dy: Tokens.commandBarHighlightInsetY) }
    override func draw(_ dirtyRect: NSRect) {
      guard selected || hovering else { return }
      (selected ? accent : hoverFill).setFill()
      NSBezierPath(roundedRect: highlight, xRadius: Tokens.commandBarHighlightRadius, yRadius: Tokens.commandBarHighlightRadius).fill()
    }
    override func layout() {
      // Spec §2: favicon 16x16 at +16, title at +43, trailing accessory label + 21x21 keycap.
      let h = bounds.height
      icon.frame = NSRect(x: 16, y: (h - 16) / 2, width: 16, height: 16)
      var right = bounds.width - 16
      keycap.isHidden = keycap.text.isEmpty
      if !keycap.isHidden { keycap.frame = NSRect(x: right - 21, y: (h - 21) / 2, width: 21, height: 21); right -= 29 }
      let aw = accessory.stringValue.isEmpty ? 0 : ceil(accessory.textWidth) + 4
      accessory.frame = NSRect(x: right - aw, y: (h - 16) / 2, width: aw, height: 16)
      right -= aw + 12
      let tw = min(ceil(title.textWidth) + 6, max(0, right - 43))
      title.frame = NSRect(x: 43, y: (h - 18) / 2, width: tw, height: 18)
      let sx = 43 + tw + 6
      subtitle.frame = NSRect(x: sx, y: (h - 17) / 2, width: max(0, right - sx), height: 17)
    }
    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      trackingAreas.forEach(removeTrackingArea)
      addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) { onClick?() }
  }

  let input = NSTextField()
  let searchIcon = IconView()
  let list = FlippedView()
  let separator = NSView()
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
    input.font = .systemFont(ofSize: Tokens.commandBarInputFontSize)
    input.delegate = self
    input.cell?.isScrollable = true
    input.cell?.wraps = false
    searchIcon.spec = "sf:magnifyingglass"
    separator.wantsLayer = true
    [searchIcon, input, separator, list].forEach { surface.addSubview($0) }
  }
  required init?(coder: NSCoder) { fatalError() }

  var barId: String { node.str("id", "commandBar") }

  func update(_ v: Value, palette p: Palette) {
    node = v
    palette = p
    let q = v.str("query")
    // Don't fight the user's typing: only replace text the plugin changed on purpose.
    if input.currentEditor() == nil || v.flag("replaceQuery") || input.stringValue.isEmpty { input.stringValue = q }
    input.placeholderString = v.str("placeholder", "Search or Enter URL…")
    rows.forEach { $0.removeFromSuperview() }
    headers.forEach { $0.removeFromSuperview() }
    rows = []
    headers = []
    rowIds = []
    for sec in v.list("sections") {
      let t = sec.str("title")
      if !t.isEmpty {
        let h = makeLabel(t, size: 11, weight: .semibold)
        headers.append(h)
        list.addSubview(h)
      } else {
        headers.append(makeLabel(""))
      }
      for rv in sec.list("rows") {
        let r = Row()
        r.rowId = rv.str("id")
        r.icon.spec = rv.str("icon", "sf:globe")
        r.icon.fallbackLetter = rv.str("title")
        r.title.stringValue = rv.str("title")
        r.subtitle.stringValue = rv.str("subtitle")
        r.accessory.stringValue = rv.str("accessory")
        r.keycap.text = rv.str("keycap")
        r.onClick = { [weak self, rid = r.rowId] in self?.submit(rid, modifiers: []) }
        r.toolTip = rv.str("subtitle")
        rows.append(r)
        rowIds.append(r.rowId)
        list.addSubview(r)
      }
    }
    selected = v.str("selected", rowIds.first ?? "")
    apply(p)
    needsLayout = true
  }

  override func apply(_ p: Palette) {
    super.apply(p)
    palette = p
    input.textColor = p.panelText
    searchIcon.tint = p.panelSecondaryText
    separator.layer?.backgroundColor = NSColor(white: p.dark ? 1 : 0, alpha: 0.10).cgColor  // HairlineDivider
    // Spec §2 measured a theme/accent-tinted highlight; den uses the space accent.
    let accent = p.accentStrong
    for r in rows {
      r.selected = r.rowId == selected
      r.accent = accent
      r.hoverFill = p.rowHover
      r.title.textColor = r.selected ? .white : p.panelText
      r.subtitle.textColor = r.selected ? NSColor(white: 1, alpha: 0.7) : p.panelSecondaryText
      r.accessory.textColor = r.selected ? NSColor(white: 1, alpha: 0.85) : p.panelSecondaryText
      r.icon.tint = r.selected ? .white : p.panelText
      r.keycap.apply(p, onAccent: r.selected)
    }
    for h in headers { h.textColor = p.panelSecondaryText }
  }

  var contentHeight: CGFloat {
    let n = min(rows.count, Tokens.commandBarMaxRows)
    let sections = headers.filter { !$0.stringValue.isEmpty }.count
    return Tokens.commandBarInputHeight + (n > 0 ? CGFloat(n) * Tokens.commandBarRowHeight + CGFloat(sections) * 26 + 12 : 0)
  }

  override func layout() {
    super.layout()
    let ih = Tokens.commandBarInputHeight
    // Spec §2: search icon 18x18 at x 23, text field starting at x 53 (panel coords).
    searchIcon.frame = NSRect(x: 23, y: (ih - 18) / 2, width: 18, height: 18)
    input.frame = NSRect(x: 53, y: (ih - 24) / 2, width: bounds.width - 53 - 20, height: 24)
    separator.frame = NSRect(x: 0, y: ih, width: bounds.width, height: rows.isEmpty ? 0 : 1)
    list.frame = NSRect(x: 0, y: ih + 1, width: bounds.width, height: bounds.height - ih - 1)
    var y: CGFloat = 4
    var ri = 0
    var shown = 0
    for (si, sec) in node.list("sections").enumerated() {
      let h = headers[si]
      if !h.stringValue.isEmpty {
        h.frame = NSRect(x: 23, y: y + 6, width: bounds.width - 46, height: 16)
        y += 26
      }
      for _ in sec.list("rows") {
        let r = rows[ri]
        ri += 1
        r.isHidden = shown >= Tokens.commandBarMaxRows
        if r.isHidden { continue }
        shown += 1
        r.frame = NSRect(x: Tokens.commandBarRowInset, y: y, width: bounds.width - 2 * Tokens.commandBarRowInset, height: Tokens.commandBarRowHeight)
        y += Tokens.commandBarRowHeight
      }
    }
  }

  func move(_ d: Int) {
    guard !rowIds.isEmpty else { return }
    let i = rowIds.firstIndex(of: selected) ?? -1
    selected = rowIds[((i + d) % rowIds.count + rowIds.count) % rowIds.count]
    if let p = palette { apply(p) }
    emit(barId, "select", ["row": .string(selected)])
  }

  func submit(_ row: String, modifiers: [Value]) {
    emit(barId, "submit", ["row": .string(row), "query": .string(input.stringValue), "modifiers": .array(modifiers)])
  }

  func controlTextDidChange(_ obj: Notification) {
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

// MARK: - Dialog

/// {type:"dialog", id, title, message?, icon?, buttons: [{id, title, style: default|cancel|destructive|secondary}], checkbox?: {id, title, checked}}
/// action (id = dialog id): button {button, checked}. Return/Escape press the default/cancel buttons.
/// Layout follows Arc's quit sheet (spec §5): left-aligned icon and title, buttons in a row at the
/// bottom right, each with its keyboard hint as a keycap.
@MainActor
final class DialogView: PanelView {
  let icon = IconView()
  let title = makeLabel(size: 17, weight: .semibold)  // estimate: size UNVERIFIED
  let message = NSTextField(wrappingLabelWithString: "")
  var buttons: [PillButton] = []
  var checkbox: NSButton?
  var node: Value = .null
  let emit: (String, String, Value) -> Void

  init(emit: @escaping (String, String, Value) -> Void) {
    self.emit = emit
    super.init(radius: Tokens.dialogCornerRadius)
    message.font = .systemFont(ofSize: 13)
    [icon, title, message].forEach { surface.addSubview($0) }
  }
  required init?(coder: NSCoder) { fatalError() }

  func update(_ v: Value, palette p: Palette) {
    node = v
    icon.spec = v.str("icon")
    icon.isHidden = icon.spec.isEmpty
    title.stringValue = v.str("title")
    message.stringValue = v.str("message")
    message.isHidden = message.stringValue.isEmpty
    buttons.forEach { $0.removeFromSuperview() }
    buttons = v.list("buttons").enumerated().map { i, b in
      let style = b.str("style", "secondary")
      let key = style == "default" ? "↩" : (style == "cancel" ? "esc" : "")
      let btn = PillButton(title: b.str("title"), style: style, keycap: key) { [weak self] in self?.pressed(i) }
      surface.addSubview(btn)
      return btn
    }
    checkbox?.removeFromSuperview()
    checkbox = nil
    if !v["checkbox"].isNull {
      let c = NSButton(checkboxWithTitle: v["checkbox"].str("title"), target: nil, action: nil)
      c.state = v["checkbox"].flag("checked") ? .on : .off
      surface.addSubview(c)
      checkbox = c
    }
    apply(p)
    needsLayout = true
  }

  override func apply(_ p: Palette) {
    super.apply(p)
    surface.layer?.backgroundColor = p.popover.cgColor
    title.textColor = p.text
    message.textColor = p.secondaryText
    icon.tint = p.accent
    buttons.forEach { $0.apply(p) }
  }

  func pressed(_ i: Int) {
    let spec = node.list("buttons")[i]
    emit(node.str("id", "dialog"), "button", ["button": .string(spec.str("id")), "checked": .bool(checkbox?.state == .on)])
  }

  /// Return / Escape trigger the default / cancel buttons.
  override func keyDown(with event: NSEvent) {
    let styles = node.list("buttons").map { $0.str("style") }
    if event.keyCode == 36 || event.keyCode == 76, let i = styles.firstIndex(of: "default") { pressed(i); return }
    if event.keyCode == 53, let i = styles.firstIndex(of: "cancel") { pressed(i); return }
    super.keyDown(with: event)
  }
  override func cancelOperation(_ sender: Any?) {
    if let i = node.list("buttons").firstIndex(where: { $0.str("style") == "cancel" }) { pressed(i) }
  }
  override var acceptsFirstResponder: Bool { true }

  var messageHeight: CGFloat {
    message.isHidden ? 0 : message.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: Tokens.dialogWidth - 2 * Tokens.dialogPadding, height: 1000)).height
  }

  var contentHeight: CGFloat {
    // Spec §5: 450x248 with icon (62) at 38, title at 117, no message.
    let pad = Tokens.dialogPadding
    var h = pad + (icon.isHidden ? 0 : Tokens.dialogIconSize + 17) + 22
    if !message.isHidden { h += 8 + messageHeight }
    if checkbox != nil { h += 30 }
    h += 33 + Tokens.dialogButtonHeight + pad
    return max(icon.isHidden ? 0 : 248, h)
  }

  override func layout() {
    super.layout()
    let pad = Tokens.dialogPadding, w = bounds.width - 2 * pad
    var y = pad
    if !icon.isHidden { icon.frame = NSRect(x: pad, y: y, width: Tokens.dialogIconSize, height: Tokens.dialogIconSize); y += Tokens.dialogIconSize + 17 }
    title.frame = NSRect(x: pad, y: y, width: w, height: 22); y += 22
    if !message.isHidden { message.frame = NSRect(x: pad, y: y + 8, width: w, height: messageHeight); y += 8 + messageHeight }
    if let c = checkbox { c.sizeToFit(); c.frame.origin = NSPoint(x: pad - 2, y: y + 8) }
    // Buttons: one row, right-aligned, 7 pt apart, bottom padding 38.
    var x = bounds.width - pad
    let by = bounds.height - pad - Tokens.dialogButtonHeight
    for b in buttons.reversed() {
      let bw = b.preferredWidth
      x -= bw
      b.frame = NSRect(x: x, y: by, width: bw, height: Tokens.dialogButtonHeight)
      x -= Tokens.dialogButtonGap
    }
  }
}

/// Small keycap ("esc", "↩", "→") drawn inside buttons and command bar rows.
@MainActor
final class Keycap: NSView {
  var text = "" { didSet { needsDisplay = true } }
  var fill: NSColor = NSColor(white: 0, alpha: 0.05)
  var fg: NSColor = .secondaryLabelColor
  func apply(_ p: Palette, onAccent: Bool) {
    fill = onAccent ? NSColor(white: 1, alpha: 0.2) : NSColor(white: p.dark ? 1 : 0, alpha: 0.05)  // AccessoryBackground (spec §2)
    fg = onAccent ? NSColor(white: 1, alpha: 0.9) : p.panelSecondaryText
    needsDisplay = true
  }
  var preferredWidth: CGFloat { max(21, ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]).width) + 10) }
  override func draw(_ dirtyRect: NSRect) {
    fill.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: fg]
    let sz = (text as NSString).size(withAttributes: attrs)
    (text as NSString).draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2), withAttributes: attrs)
  }
}

// MARK: - Toast

/// {type:"toast", id?, text, icon?, duration?: ms}. Theme-tinted pill; auto-dismisses.
@MainActor
final class ToastView: FlippedView, Themable {
  let icon = IconView()
  let label = makeLabel(size: 13, weight: .medium)
  var color: NSColor = .black

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = Tokens.toastCornerRadius
    layer?.cornerCurve = .continuous
    layer?.shadowOpacity = 0.25
    layer?.shadowRadius = 10
    layer?.shadowOffset = CGSize(width: 0, height: -3)
    addSubview(icon)
    addSubview(label)
  }
  required init?(coder: NSCoder) { fatalError() }

  func update(_ v: Value, palette p: Palette) {
    label.stringValue = v.str("text")
    icon.spec = v.str("icon")
    icon.isHidden = icon.spec.isEmpty
    apply(p)
  }
  func apply(_ p: Palette) {
    layer?.backgroundColor = p.toast.cgColor
    label.textColor = .white
    icon.tint = .white
  }
  var contentWidth: CGFloat { ceil(label.textWidth) + (icon.isHidden ? 40 : 64) }
  override func layout() {
    super.layout()
    var x: CGFloat = 16
    if !icon.isHidden { icon.frame = NSRect(x: x, y: (bounds.height - 15) / 2, width: 15, height: 15); x += 24 }
    label.frame = NSRect(x: x, y: (bounds.height - 17) / 2, width: bounds.width - x - 14, height: 17)
    layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Tokens.toastCornerRadius, cornerHeight: Tokens.toastCornerRadius, transform: nil)
  }
}

/// Dim backdrop behind dialogs / command bar. Clicking it emits the owner's dismiss.
@MainActor
final class BackdropView: NSView {
  var onClick: (() -> Void)?
  override func mouseDown(with event: NSEvent) { onClick?() }
  override var mouseDownCanMoveWindow: Bool { false }
}

/// Dialog button: primary (#3139FB) for the default action, subtle otherwise, with an optional keycap.
@MainActor
final class PillButton: FlippedView, Themable {
  let label = makeLabel(size: 13, weight: .medium)
  let keycap = Keycap()
  let style: String
  let action: () -> Void
  var fill: NSColor = .gray
  var border: NSColor?
  var pressedDown = false { didSet { needsDisplay = true } }
  init(title: String, style: String, keycap key: String = "", action: @escaping () -> Void) {
    self.style = style
    self.action = action
    super.init(frame: .zero)
    label.stringValue = title
    keycap.text = key
    keycap.isHidden = key.isEmpty
    addSubview(label)
    addSubview(keycap)
  }
  required init?(coder: NSCoder) { fatalError() }
  var preferredWidth: CGFloat { ceil(label.textWidth) + 32 + (keycap.isHidden ? 0 : keycap.preferredWidth + 8) }
  func apply(_ p: Palette) {
    border = nil
    switch style {
    case "default": fill = p.primaryButton; label.textColor = .white
    case "destructive": fill = p.destructive; label.textColor = .white
    default:
      fill = p.pillFill
      border = NSColor(white: p.dark ? 1 : 0, alpha: 0.12)  // estimate
      label.textColor = p.text
    }
    keycap.apply(p, onAccent: style == "default" || style == "destructive")
    needsDisplay = true
  }
  override func layout() {
    let lw = ceil(label.textWidth) + 2
    label.frame = NSRect(x: 16, y: (bounds.height - 17) / 2, width: lw, height: 17)
    keycap.frame = NSRect(x: 16 + lw + 6, y: (bounds.height - 20) / 2, width: keycap.preferredWidth, height: 20)
  }
  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)  // estimate: radius
    (pressedDown ? fill.blended(withFraction: 0.15, of: .black) ?? fill : fill).setFill()
    path.fill()
    if let border { border.setStroke(); path.lineWidth = 1; path.stroke() }
  }
  override func mouseDown(with event: NSEvent) { pressedDown = true }
  override func mouseUp(with event: NSEvent) {
    pressedDown = false
    if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
  }
}
