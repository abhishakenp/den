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
    let icon = IconView(), title = makeLabel(size: 14), subtitle = makeLabel(size: 12), accessory = makeLabel(size: 11, weight: .medium)
    var rowId = ""
    var selected = false { didSet { needsDisplay = true } }
    var accent: NSColor = .controlAccentColor
    var onClick: (() -> Void)?
    override init(frame: NSRect) {
      super.init(frame: frame)
      [icon, title, subtitle, accessory].forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
      guard selected else { return }
      accent.setFill()
      NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
    override func layout() {
      let h = bounds.height
      icon.frame = NSRect(x: 12, y: (h - 18) / 2, width: 18, height: 18)
      let aw = ceil(accessory.intrinsicContentSize.width) + 4
      accessory.frame = NSRect(x: bounds.width - aw - 12, y: (h - 15) / 2, width: aw, height: 15)
      let tw = min(ceil(title.intrinsicContentSize.width) + 6, bounds.width * 0.62)
      title.frame = NSRect(x: 42, y: (h - 18) / 2, width: tw, height: 18)
      subtitle.frame = NSRect(x: 42 + tw + 8, y: (h - 16) / 2 + 1, width: max(0, bounds.width - aw - 30 - (42 + tw + 8)), height: 16)
    }
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
    input.textColor = p.dark ? .white : .black
    searchIcon.tint = p.secondaryText
    separator.layer?.backgroundColor = p.divider.cgColor
    let accent = p.accent
    for r in rows {
      r.selected = r.rowId == selected
      r.accent = accent
      let fg: NSColor = r.selected ? .white : (p.dark ? .white : .black)
      r.title.textColor = fg
      r.subtitle.textColor = r.selected ? NSColor(white: 1, alpha: 0.75) : p.secondaryText
      r.accessory.textColor = r.selected ? NSColor(white: 1, alpha: 0.85) : p.secondaryText
      r.icon.tint = fg
    }
    for h in headers { h.textColor = p.secondaryText }
  }

  var contentHeight: CGFloat {
    let n = min(rows.count, Tokens.commandBarMaxRows)
    let sections = headers.filter { !$0.stringValue.isEmpty }.count
    return Tokens.commandBarInputHeight + (n > 0 ? CGFloat(n) * Tokens.commandBarRowHeight + CGFloat(sections) * 24 + 14 : 0)
  }

  override func layout() {
    super.layout()
    let ih = Tokens.commandBarInputHeight
    searchIcon.frame = NSRect(x: 18, y: (ih - 18) / 2, width: 18, height: 18)
    input.frame = NSRect(x: 46, y: (ih - 24) / 2, width: bounds.width - 62, height: 24)
    separator.frame = NSRect(x: 0, y: ih, width: bounds.width, height: rows.isEmpty ? 0 : 1)
    list.frame = NSRect(x: 0, y: ih + 1, width: bounds.width, height: bounds.height - ih - 1)
    var y: CGFloat = 6
    var ri = 0
    var shown = 0
    for (si, sec) in node.list("sections").enumerated() {
      let h = headers[si]
      if !h.stringValue.isEmpty {
        h.frame = NSRect(x: 18, y: y + 5, width: bounds.width - 36, height: 16)
        y += 24
      }
      for _ in sec.list("rows") {
        let r = rows[ri]
        ri += 1
        r.isHidden = shown >= Tokens.commandBarMaxRows
        if r.isHidden { continue }
        shown += 1
        r.frame = NSRect(x: 8, y: y, width: bounds.width - 16, height: Tokens.commandBarRowHeight)
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

/// {type:"dialog", id, title, message?, icon?, buttons: [{id, title, style: default|cancel|destructive}], checkbox?: {id, title, checked}}
/// action (id = dialog id): button {button, checked}
@MainActor
final class DialogView: PanelView {
  let icon = IconView()
  let title = makeLabel(size: 15, weight: .semibold)
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
    title.alignment = .center
    message.stringValue = v.str("message")
    message.alignment = .center
    buttons.forEach { $0.removeFromSuperview() }
    buttons = v.list("buttons").enumerated().map { i, b in
      let btn = PillButton(title: b.str("title"), style: b.str("style")) { [weak self] in self?.pressed(i) }
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
    title.textColor = p.text
    message.textColor = p.secondaryText
    icon.tint = p.accent
    buttons.forEach { $0.apply(p) }
  }

  /// Return / Escape trigger the default / cancel buttons.
  override func keyDown(with event: NSEvent) {
    let styles = node.list("buttons").map { $0.str("style") }
    if event.keyCode == 36, let i = styles.firstIndex(of: "default") { pressed(i); return }
    if event.keyCode == 53, let i = styles.firstIndex(of: "cancel") { pressed(i); return }
    super.keyDown(with: event)
  }
  override var acceptsFirstResponder: Bool { true }

  func pressed(_ i: Int) {
    let spec = node.list("buttons")[i]
    emit(node.str("id", "dialog"), "button", ["button": .string(spec.str("id")), "checked": .bool(checkbox?.state == .on)])
  }

  var contentHeight: CGFloat {
    let w = Tokens.dialogWidth - 48
    let mh = message.stringValue.isEmpty ? 0 : message.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: w, height: 1000)).height
    return 24 + (icon.isHidden ? 0 : 52) + 22 + (mh > 0 ? mh + 8 : 0) + (checkbox == nil ? 0 : 30) + 20 + CGFloat(buttons.count) * 36 + 16
  }

  override func layout() {
    super.layout()
    let w = bounds.width - 48
    var y: CGFloat = 24
    if !icon.isHidden { icon.frame = NSRect(x: (bounds.width - 44) / 2, y: y, width: 44, height: 44); y += 52 }
    title.frame = NSRect(x: 24, y: y, width: w, height: 20); y += 26
    if !message.stringValue.isEmpty {
      let mh = message.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: w, height: 1000)).height
      message.frame = NSRect(x: 24, y: y, width: w, height: mh); y += mh + 8
    }
    if let c = checkbox {
      c.sizeToFit()
      c.frame.origin = NSPoint(x: (bounds.width - c.frame.width) / 2, y: y + 4); y += 30
    }
    y += 12
    // Arc stacks full-width buttons vertically.
    for b in buttons {
      b.frame = NSRect(x: 20, y: y, width: bounds.width - 40, height: 32); y += 36
    }
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
  var contentWidth: CGFloat { ceil(label.intrinsicContentSize.width) + (icon.isHidden ? 40 : 64) }
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

/// Full-width dialog button: accent-filled for the default action, subtle otherwise.
@MainActor
final class PillButton: FlippedView, Themable {
  let label = makeLabel(size: 13, weight: .medium)
  let style: String
  let action: () -> Void
  var fill: NSColor = .gray
  var pressedDown = false { didSet { needsDisplay = true } }
  init(title: String, style: String, action: @escaping () -> Void) {
    self.style = style
    self.action = action
    super.init(frame: .zero)
    label.stringValue = title
    label.alignment = .center
    addSubview(label)
  }
  required init?(coder: NSCoder) { fatalError() }
  func apply(_ p: Palette) {
    switch style {
    case "default": fill = p.accent; label.textColor = .white
    case "destructive": fill = p.pillFill; label.textColor = .systemRed
    default: fill = p.pillFill; label.textColor = p.dark ? .white : .black
    }
    needsDisplay = true
  }
  override func layout() { label.frame = NSRect(x: 8, y: (bounds.height - 17) / 2, width: bounds.width - 16, height: 17) }
  override func draw(_ dirtyRect: NSRect) {
    (pressedDown ? fill.blended(withFraction: 0.15, of: .black) ?? fill : fill).setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
  }
  override func mouseDown(with event: NSEvent) { pressedDown = true }
  override func mouseUp(with event: NSEvent) {
    pressedDown = false
    if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
  }
}
