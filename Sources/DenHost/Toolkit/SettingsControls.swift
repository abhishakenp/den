import AppKit
import CordisValue

/// One row of a Settings card: title and subtitle on the left, a native control on the right.
/// See `SettingsService` for the control types. A `list` control becomes one row per item.
@MainActor
final class SettingsRow: FlippedView, NSTextFieldDelegate {
  enum Kind { case control, listHeader, listItem(Value), listEmpty }
  let control: Value
  let kind: Kind
  let owner: String
  unowned let service: SettingsService
  let titleLabel = makeLabel("", size: 13)
  let subtitleLabel = NSTextField(wrappingLabelWithString: "")
  let icon = IconView()
  private(set) var accessory: NSView?
  private var valueLabel: NSTextField?
  private var buttons: [NSButton] = []
  var palette = SettingsPalette() { didSet { applyPalette() } }

  var key: String { control.str("key") }
  var type: String { control.str("type") }

  init(control: Value, kind: Kind = .control, owner: String, service: SettingsService) {
    self.control = control
    self.kind = kind
    self.owner = owner
    self.service = service
    super.init(frame: .zero)
    subtitleLabel.font = .systemFont(ofSize: 11.5)
    subtitleLabel.isSelectable = false
    addSubview(titleLabel)
    addSubview(subtitleLabel)
    switch kind {
    case .control: build()
    case .listHeader:
      titleLabel.stringValue = control.str("title")
      titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
      subtitleLabel.stringValue = control.str("subtitle")
    case let .listItem(item):
      titleLabel.stringValue = item.str("title")
      subtitleLabel.stringValue = item.str("subtitle")
      if !item.str("icon").isEmpty {
        icon.spec = item.str("icon")
        icon.fallbackLetter = item.str("title")
        addSubview(icon)
      }
      for b in item.list("buttons") { addButton(b.str("title"), style: b.str("style")) { [weak self] in self?.service.action(owner, control.str("key"), item: item.str("id"), button: b.str("id")) } }
    case .listEmpty:
      subtitleLabel.stringValue = control.str("empty", "Nothing here yet.")
    }
    subtitleLabel.isHidden = subtitleLabel.stringValue.isEmpty
  }
  required init?(coder: NSCoder) { fatalError() }

  /// Rows for one control: a list expands into a header, then its items (or an empty row).
  static func rows(for c: Value, owner: String, service: SettingsService) -> [SettingsRow] {
    guard c.str("type") == "list" else { return [SettingsRow(control: c, owner: owner, service: service)] }
    var out: [SettingsRow] = []
    if !c.str("title").isEmpty { out.append(SettingsRow(control: c, kind: .listHeader, owner: owner, service: service)) }
    let items = c.list("items")
    if items.isEmpty { out.append(SettingsRow(control: c, kind: .listEmpty, owner: owner, service: service)) }
    for i in items { out.append(SettingsRow(control: c, kind: .listItem(i), owner: owner, service: service)) }
    return out
  }

  // MARK: Build

  var current: Value { service.value(owner, key) }

  private func build() {
    titleLabel.stringValue = control.str("title")
    subtitleLabel.stringValue = control.str("subtitle")
    switch type {
    case "toggle":
      let s = NSSwitch()
      s.controlSize = .small
      s.target = self
      s.action = #selector(toggled(_:))
      accessory = s
    case "choice":
      let p = NSPopUpButton(frame: .zero, pullsDown: false)
      p.controlSize = .small
      p.font = .systemFont(ofSize: 12)
      for o in control.list("options") { p.addItem(withTitle: o.str("title")) }
      p.target = self
      p.action = #selector(chose(_:))
      accessory = p
    case "text":
      let f = NSTextField(string: "")
      f.placeholderString = control.str("placeholder")
      f.bezelStyle = .roundedBezel
      f.controlSize = .small
      f.font = .systemFont(ofSize: 12)
      f.delegate = self
      f.cell?.isScrollable = true
      f.usesSingleLineMode = true
      accessory = f
    case "shortcut":
      let r = ShortcutRecorder()
      r.onChange = { [weak self] chord in
        guard let self else { return }
        self.service.set(self.owner, self.key, .string(chord))
      }
      accessory = r
    case "number":
      let s = NSSlider(value: 0, minValue: control.num("min", 0), maxValue: control.num("max", 100), target: self, action: #selector(slid(_:)))
      s.controlSize = .small
      s.isContinuous = true
      let step = control.num("step", 0)
      if step > 0 {
        s.numberOfTickMarks = min(60, Int(((s.maxValue - s.minValue) / step).rounded()) + 1)
        s.allowsTickMarkValuesOnly = true
        s.tickMarkPosition = .below
        if s.numberOfTickMarks > 13 { s.numberOfTickMarks = 0 }  // too dense to draw: snap in code instead
      }
      let l = makeLabel("", size: 12, weight: .medium)
      l.alignment = .right
      addSubview(l)
      valueLabel = l
      accessory = s
    case "button":
      let b = control["button"]
      addButton(b.str("title", "Open"), style: b.str("style")) { [weak self] in
        guard let self else { return }
        self.service.action(self.owner, self.key)
      }
    case "info":
      let l = makeLabel("", size: 12)
      l.lineBreakMode = .byTruncatingMiddle
      l.alignment = .right
      l.isSelectable = true
      valueLabel = l
      addSubview(l)
      for b in control.list("buttons") {
        addButton(b.str("title"), style: b.str("style")) { [weak self] in
          guard let self else { return }
          self.service.action(self.owner, self.key, button: b.str("id"))
        }
      }
    default: break
    }
    if let a = accessory { addSubview(a) }
    refresh()
  }

  private var buttonActions: [() -> Void] = []
  private func addButton(_ title: String, style: String, _ action: @escaping () -> Void) {
    let b = NSButton(title: title, target: self, action: #selector(pressed(_:)))
    b.bezelStyle = .push
    b.controlSize = .small
    b.font = .systemFont(ofSize: 12)
    b.tag = buttonActions.count
    if style == "primary" { b.keyEquivalent = "" ; b.bezelColor = palette.accent; b.hasDestructiveAction = false }
    if style == "destructive" { b.hasDestructiveAction = true }
    buttonActions.append(action)
    buttons.append(b)
    addSubview(b)
  }

  /// Shows the stored value (or the default) in the control.
  func refresh() {
    let v = current
    switch type {
    case "toggle": (accessory as? NSSwitch)?.state = v.bool == true ? .on : .off
    case "choice":
      if let p = accessory as? NSPopUpButton, let i = control.list("options").firstIndex(where: { $0["value"] == v }) { p.selectItem(at: i) }
    case "text":
      if let f = accessory as? NSTextField, !control.flag("submit"), f.currentEditor() == nil { f.stringValue = v.string ?? "" }
    case "shortcut": (accessory as? ShortcutRecorder)?.chord = v.string ?? ""
    case "number":
      let d = v.double ?? v.int.map(Double.init) ?? control.num("min", 0)
      (accessory as? NSSlider)?.doubleValue = d
      valueLabel?.stringValue = numberText(d)
    case "info": valueLabel?.stringValue = control.str("value")
    default: break
    }
    needsLayout = true
  }

  func numberText(_ d: Double) -> String {
    if let l = control.list("labels").first(where: { ($0["value"].double ?? $0["value"].int.map(Double.init)) == d }) { return l.str("title") }
    let n = d.rounded() == d ? String(Int(d)) : String(format: "%.1f", d)
    let unit = control.str("unit")
    return unit.isEmpty ? n : n + " " + unit
  }

  // MARK: Actions

  @objc func toggled(_ s: NSSwitch) { service.set(owner, key, .bool(s.state == .on)) }
  @objc func chose(_ p: NSPopUpButton) {
    let opts = control.list("options")
    guard p.indexOfSelectedItem >= 0, p.indexOfSelectedItem < opts.count else { return }
    service.set(owner, key, opts[p.indexOfSelectedItem]["value"])
  }
  @objc func slid(_ s: NSSlider) {
    let step = control.num("step", 0)
    var d = s.doubleValue
    if step > 0 { d = (d / step).rounded() * step }
    d = min(max(d, s.minValue), s.maxValue)
    valueLabel?.stringValue = numberText(d)
    // Commit when the drag ends (or on a click / key), so storage isn't written on every tick.
    let t = NSApp.currentEvent?.type
    if t != .leftMouseDragged { service.set(owner, key, d.rounded() == d ? .int(Int64(d)) : .double(d)) }
  }
  @objc func pressed(_ b: NSButton) { if b.tag < buttonActions.count { buttonActions[b.tag]() } }

  func controlTextDidEndEditing(_ obj: Notification) {
    guard let f = accessory as? NSTextField, !control.flag("submit") else { return }
    service.set(owner, key, .string(f.stringValue.trimmingCharacters(in: .whitespaces)))
  }
  func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
    guard sel == #selector(NSResponder.insertNewline(_:)), let f = accessory as? NSTextField else { return false }
    if self.control.flag("submit") {
      let t = f.stringValue.trimmingCharacters(in: .whitespaces)
      if !t.isEmpty { service.action(owner, key, value: t) }
      f.stringValue = ""
      return true
    }
    window?.makeFirstResponder(nil)
    return true
  }

  // MARK: Layout

  var textInset: CGFloat {
    if case .listItem = kind, !icon.spec.isEmpty { return SettingsMetrics.rowPadX + 30 }
    return SettingsMetrics.rowPadX
  }

  var buttonsWidth: CGFloat { buttons.reduce(0) { $0 + $1.intrinsicContentSize.width + 6 } }
  var accessoryWidth: CGFloat {
    guard case .control = kind else { return buttonsWidth }
    switch type {
    case "toggle": return 40
    case "choice": return min(220, max(110, ((accessory as? NSPopUpButton)?.intrinsicContentSize.width ?? 120)))
    case "text": return 230
    case "shortcut": return 130
    case "number": return 180 + 66
    case "info": return 250 + buttons.reduce(0) { $0 + $1.intrinsicContentSize.width + 6 }
    default: return buttons.reduce(0) { $0 + $1.intrinsicContentSize.width + 6 }
    }
  }

  func textWidth(_ w: CGFloat) -> CGFloat { max(120, w - textInset - SettingsMetrics.rowPadX - accessoryWidth - 16) }

  func height(for w: CGFloat) -> CGFloat {
    if case .listEmpty = kind { return 40 }
    let tw = textWidth(w)
    var h: CGFloat = 17
    if !subtitleLabel.stringValue.isEmpty {
      let r = (subtitleLabel.stringValue as NSString).boundingRect(with: NSSize(width: tw, height: 1000), options: [.usesLineFragmentOrigin], attributes: [.font: subtitleLabel.font!])
      h += 2 + ceil(r.height)
    }
    return max(SettingsMetrics.rowMinHeight, h + 22)
  }

  func layoutControls() {
    let w = bounds.width, h = bounds.height, pad = SettingsMetrics.rowPadX
    let tw = textWidth(w)
    if case .listEmpty = kind {
      subtitleLabel.frame = NSRect(x: pad, y: (h - 16) / 2, width: w - 2 * pad, height: 16)
      return
    }
    let subH = subtitleLabel.isHidden ? 0 : h - 22 - 17 - 2
    let top = (h - 17 - (subtitleLabel.isHidden ? 0 : 2 + subH)) / 2
    titleLabel.frame = NSRect(x: textInset, y: top, width: tw, height: 17)
    subtitleLabel.frame = NSRect(x: textInset, y: top + 19, width: tw, height: max(0, subH))
    if !icon.spec.isEmpty { icon.frame = NSRect(x: pad, y: (h - 20) / 2, width: 20, height: 20) }
    var right = w - pad
    for b in buttons.reversed() {
      let bw = b.intrinsicContentSize.width
      b.frame = NSRect(x: right - bw, y: (h - 22) / 2, width: bw, height: 22)
      right -= bw + 6
    }
    guard let a = accessory ?? valueLabel else { return }
    switch type {
    case "toggle": a.frame = NSRect(x: right - 32, y: (h - 18) / 2, width: 32, height: 18)
    case "choice":
      let cw = accessoryWidth
      a.frame = NSRect(x: right - cw, y: (h - 22) / 2, width: cw, height: 22)
    case "text": a.frame = NSRect(x: right - 230, y: (h - 22) / 2, width: 230, height: 22)
    case "shortcut": a.frame = NSRect(x: right - 130, y: (h - 24) / 2, width: 130, height: 24)
    case "number":
      valueLabel?.frame = NSRect(x: right - 60, y: (h - 16) / 2, width: 60, height: 16)
      a.frame = NSRect(x: right - 66 - 180, y: (h - 20) / 2, width: 180, height: 20)
    case "info": valueLabel?.frame = NSRect(x: right - 250, y: (h - 16) / 2, width: 246, height: 16)
    default: break
    }
  }

  func applyPalette() {
    titleLabel.textColor = palette.text
    subtitleLabel.textColor = palette.secondary
    valueLabel?.textColor = type == "info" ? palette.secondary : palette.text
    icon.tint = palette.text
    (accessory as? ShortcutRecorder)?.palette = palette
    for b in buttons where b.hasDestructiveAction { b.contentTintColor = palette.destructive }
  }
}

/// A shortcut field: shows the chord as keycaps ("⇧⌘B"); click, then press the new shortcut.
/// Esc cancels, Delete clears. The value is a `keys` chord string ("cmd+shift+b").
@MainActor
final class ShortcutRecorder: FlippedView {
  var chord = "" { didSet { label.stringValue = Self.display(chord); needsDisplay = true } }
  var onChange: ((String) -> Void)?
  var palette = SettingsPalette() { didSet { needsDisplay = true; updateLabel() } }
  private let label = makeLabel("", size: 12, weight: .medium)
  private(set) var recording = false { didSet { updateLabel(); needsDisplay = true } }

  override init(frame: NSRect) {
    super.init(frame: frame)
    label.alignment = .center
    addSubview(label)
    setAccessibilityRole(.button)
  }
  required init?(coder: NSCoder) { fatalError() }
  override var acceptsFirstResponder: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  private func updateLabel() {
    label.stringValue = recording ? "Type a shortcut…" : (chord.isEmpty ? "None" : Self.display(chord))
    label.textColor = recording || chord.isEmpty ? palette.secondary : palette.text
  }
  override func layout() { label.frame = NSRect(x: 4, y: (bounds.height - 16) / 2, width: bounds.width - 8, height: 16) }
  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
    (palette.dark ? Palette.snow(0.08) : NSColor(white: 1, alpha: 0.9)).setFill()
    path.fill()
    (recording ? palette.accent : palette.cardBorder.withAlphaComponent(palette.dark ? 0.2 : 0.15)).setStroke()
    path.lineWidth = recording ? 1.5 : 1
    path.stroke()
  }
  override func mouseDown(with event: NSEvent) {
    recording = true
    window?.makeFirstResponder(self)
  }
  override func resignFirstResponder() -> Bool { recording = false; return true }
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    // While recording, every chord (even ⌘W) is captured instead of reaching the menu.
    guard recording else { return false }
    keyDown(with: event)
    return true
  }
  override func keyDown(with event: NSEvent) {
    guard recording else { return super.keyDown(with: event) }
    let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if event.keyCode == 53, mods.isEmpty { recording = false; return }  // Esc
    if event.keyCode == 51 || event.keyCode == 117, mods.isEmpty {  // Delete: no shortcut
      recording = false
      chord = ""
      onChange?("")
      return
    }
    guard let c = Self.chord(from: event) else { NSSound.beep(); return }
    recording = false
    chord = c
    onChange?(c)
    window?.makeFirstResponder(nil)
  }

  /// A key event as a `keys` chord string, or nil without a modifier (except function keys).
  static func chord(from e: NSEvent) -> String? {
    let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
    var parts: [String] = []
    if f.contains(.control) { parts.append("ctrl") }
    if f.contains(.option) { parts.append("opt") }
    if f.contains(.shift) { parts.append("shift") }
    if f.contains(.command) { parts.append("cmd") }
    let names: [UInt16: String] = [123: "left", 124: "right", 125: "down", 126: "up", 48: "tab", 36: "return", 49: "space", 51: "delete", 53: "esc",
                                   122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12"]
    let key: String
    if let n = names[e.keyCode] { key = n } else {
      guard let ch = e.charactersIgnoringModifiers?.lowercased(), ch.count == 1 else { return nil }
      key = ch == "+" ? "plus" : ch
    }
    let isF = key.hasPrefix("f") && key.count > 1
    guard !parts.isEmpty || isF else { return nil }
    guard parts != ["shift"] || isF else { return nil }  // Shift alone would steal typing
    return (parts + [key]).joined(separator: "+")
  }

  /// "cmd+shift+b" → "⇧⌘B" (Apple's modifier order: ⌃⌥⇧⌘).
  static func display(_ chord: String) -> String {
    guard !chord.isEmpty else { return "" }
    let parts = chord.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
    let key = parts.last ?? ""
    var s = ""
    if parts.contains("ctrl") || parts.contains("control") { s += "⌃" }
    if parts.contains("opt") || parts.contains("option") || parts.contains("alt") { s += "⌥" }
    if parts.contains("shift") { s += "⇧" }
    if parts.contains("cmd") || parts.contains("command") { s += "⌘" }
    let named = ["left": "←", "right": "→", "up": "↑", "down": "↓", "tab": "⇥", "return": "↩", "enter": "↩", "esc": "⎋", "escape": "⎋",
                 "space": "Space", "delete": "⌫", "backspace": "⌫", "plus": "+", "minus": "-", "": "+"]
    return s + (named[key] ?? key.uppercased())
  }
}
