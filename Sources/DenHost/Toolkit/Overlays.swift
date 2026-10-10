import AppKit
import PluginCores
import CordisValue

/// Rounded floating panel: an elevated surface (Elevation.swift: layered shadow, rim, edge) tinted
/// by the palette. Subclasses pick their `elevation` level.
@MainActor
class PanelView: FlippedView, Themable {
  var radius: CGFloat
  let surface = FlippedView()
  var elevation: Elevation = .modal
  var showsRim = true
  var showsEdge = true
  var palette: Palette?
  init(radius: CGFloat) {
    self.radius = radius
    super.init(frame: .zero)
    wantsLayer = true
    surface.wantsLayer = true
    surface.layer?.cornerRadius = radius
    surface.layer?.cornerCurve = .continuous
    surface.layer?.masksToBounds = true
    addSubview(surface)
  }
  required init?(coder: NSCoder) { fatalError() }
  func apply(_ p: Palette) {
    palette = p
    surface.layer?.backgroundColor = p.surface.cgColor
    SurfaceGrain.apply(to: surface, palette: p)
    Elevation.apply(elevation, host: self, surface: surface, radius: radius, palette: p, rim: showsRim, edge: showsEdge)
  }
  override func layout() {
    super.layout()
    surface.frame = bounds
    if let p = palette { Elevation.apply(elevation, host: self, surface: surface, radius: radius, palette: p, rim: showsRim, edge: showsEdge) }
  }
}

// MARK: - Command bar

// CommandBarView lives in CommandBarView.swift.

// MARK: - Dialog

/// {type:"dialog", id, title, message?, icon?, iconStyle?: accent|destructive|plain,
///  buttons: [{id, title, style: default|cancel|destructive|secondary, default?, keycap?}], checkbox?: {id, title, checked},
///  fields?: [{id, placeholder?, value?, secure?}], choices?: [{id, title, subtitle?, icon?}], multiple?}
/// action (id = dialog id): button {button, checked, fields?: {id: text}, choices?: [id]}.
/// Choices (the upload picker) are rows under the message: one is selected (the first at the start);
/// a click on a row presses the default button with it, or with `multiple` ticks it on and off. Fields (a web page's prompt(),
/// HTTP sign-in) stack under the message; the first one takes focus, and Return in any of them
/// presses the default button. Return presses the `default` style button or the
/// button flagged `default: true` (e.g. a destructive confirm); Escape presses the cancel button.
/// Icons: `app:icon` (or an image file, e.g. an extension's icon) draws at 62 pt (quit sheet, spec §5);
/// an `sf:` symbol is a 76 pt hero icon (spec §5 "Dialog hero icons"): the symbol on a tinted disc.
/// Layout follows Arc's quit sheet (spec §5): left-aligned icon and title, buttons in a row at the
/// bottom right, each with its keyboard hint as a keycap.
@MainActor
final class DialogView: PanelView {
  let icon = IconView()
  let hero = FlippedView()
  let title = NSTextField(wrappingLabelWithString: "")
  let message = NSTextField(wrappingLabelWithString: "")
  var buttons: [PillButton] = []
  var checkbox: NSButton?
  var fields: [NSTextField] = []
  var choices: [ChoiceRow] = []
  var node: Value = .null
  let emit: (String, String, Value) -> Void
  static let choiceHeight: CGFloat = 48

  init(emit: @escaping (String, String, Value) -> Void) {
    self.emit = emit
    super.init(radius: Tokens.dialogCornerRadius)
    message.font = .systemFont(ofSize: 13)
    title.font = .systemFont(ofSize: 18, weight: .medium)  // PX: 13 pt cap height on arc_quit_dialog.png
    hero.wantsLayer = true
    hero.layer?.cornerRadius = Tokens.dialogHeroIconSize / 2
    [hero, icon, title, message].forEach { surface.addSubview($0) }
  }
  required init?(coder: NSCoder) { fatalError() }

  func update(_ v: Value, palette p: Palette) {
    node = v
    icon.spec = v.str("icon")
    icon.isHidden = icon.spec.isEmpty
    hero.isHidden = icon.isHidden || !icon.spec.hasPrefix("sf:")
    title.stringValue = v.str("title")
    message.stringValue = v.str("message")
    message.isHidden = message.stringValue.isEmpty
    buttons.forEach { $0.removeFromSuperview() }
    buttons = v.list("buttons").enumerated().map { i, b in
      let style = b.str("style", "secondary")
      let key = b["keycap"].string ?? (Self.isDefault(b) ? "↩" : (style == "cancel" ? "ESC" : ""))
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
    fields.forEach { $0.removeFromSuperview() }
    fields = v.list("fields").map { f in
      let t: NSTextField = f.flag("secure") ? NSSecureTextField() : NSTextField()
      t.placeholderString = f.str("placeholder")
      t.stringValue = f.str("value")
      t.font = .systemFont(ofSize: 13)
      t.bezelStyle = .roundedBezel
      t.usesSingleLineMode = true
      t.cell?.isScrollable = true
      t.target = self
      t.action = #selector(fieldReturn(_:))
      surface.addSubview(t)
      return t
    }
    choices.forEach { $0.removeFromSuperview() }
    let multiple = v.flag("multiple")
    choices = v.list("choices").enumerated().map { i, c in
      let r = ChoiceRow()
      r.choiceId = c.str("id")
      r.icon.spec = c.str("icon", "sf:doc")
      r.title.stringValue = c.str("title")
      r.subtitle.stringValue = c.str("subtitle")
      r.multiple = multiple
      r.selected = !multiple && i == 0
      r.onClick = { [weak self] in self?.choiceClicked(i) }
      surface.addSubview(r)
      return r
    }
    apply(p)
    needsLayout = true
  }

  var selectedChoices: [String] { choices.filter(\.selected).map(\.choiceId) }

  func choiceClicked(_ i: Int) {
    guard i < choices.count else { return }
    if choices[i].multiple {
      choices[i].selected.toggle()
      return
    }
    for (j, c) in choices.enumerated() { c.selected = j == i }
    if let d = node.list("buttons").firstIndex(where: Self.isDefault) { pressed(d) }
  }

  override func apply(_ p: Palette) {
    super.apply(p)
    surface.layer?.backgroundColor = p.surface.cgColor
    title.textColor = p.textPrimary
    message.textColor = p.textSecondary
    let tint: NSColor
    switch node.str("iconStyle", "accent") {
    case "destructive": tint = p.destructive
    case "plain": tint = p.textPrimary
    default: tint = p.accentStrong
    }
    icon.tint = tint
    hero.layer?.backgroundColor = tint.withAlphaComponent(p.dark ? 0.2 : 0.12).cgColor  // estimate
    buttons.forEach { $0.apply(p) }
    choices.forEach { $0.apply(p) }
  }

  func pressed(_ i: Int) {
    let spec = node.list("buttons")[i]
    var value: Value = ["button": .string(spec.str("id")), "checked": .bool(checkbox?.state == .on)]
    if !choices.isEmpty { value = value.with("choices", .array(selectedChoices.map { .string($0) })) }
    if !fields.isEmpty {
      let ids = node.list("fields").map { $0.str("id") }
      value = value.with("fields", .object(zip(ids, fields).map { ($0, .string($1.stringValue)) }))
    }
    emit(node.str("id", "dialog"), "button", value)
  }

  /// Return in a text field presses the default button (a field's action also fires when it loses
  /// focus; only Return counts).
  @objc func fieldReturn(_ sender: NSTextField) {
    guard let e = NSApp.currentEvent, e.type == .keyDown, e.keyCode == 36 || e.keyCode == 76 else { return }
    if let i = node.list("buttons").firstIndex(where: Self.isDefault) { pressed(i) }
  }

  /// What takes focus when the dialog opens: the first field, or the dialog itself (Return / Esc).
  var focusTarget: NSView { fields.first ?? self }

  static func isDefault(_ b: Value) -> Bool { b["default"].bool ?? (b.str("style") == "default") }

  /// What Escape presses: the `cancel` button, or the only button of a one-button dialog (a page's
  /// alert(), like NSAlert).
  var cancelIndex: Int? {
    let b = node.list("buttons")
    return b.firstIndex { $0.str("style") == "cancel" } ?? (b.count == 1 ? 0 : nil)
  }

  /// Return / Escape trigger the default / cancel buttons.
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36 || event.keyCode == 76, let i = node.list("buttons").firstIndex(where: Self.isDefault) { pressed(i); return }
    // ↑/↓ move the selected choice.
    if !choices.isEmpty, !choices[0].multiple, event.keyCode == 125 || event.keyCode == 126 {
      let cur = choices.firstIndex(where: \.selected) ?? 0
      let next = min(max(0, cur + (event.keyCode == 125 ? 1 : -1)), choices.count - 1)
      for (j, c) in choices.enumerated() { c.selected = j == next }
      return
    }
    if event.keyCode == 53, let i = cancelIndex { pressed(i); return }
    super.keyDown(with: event)
  }
  override func cancelOperation(_ sender: Any?) {
    if let i = cancelIndex { pressed(i) }
  }
  /// A button whose keycap is a ⌘ chord ("⌘O" for the upload picker's Choose File…) takes that key
  /// before the main menu does.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if superview != nil, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, let ch = event.charactersIgnoringModifiers?.uppercased(),
       let i = node.list("buttons").firstIndex(where: { $0.str("keycap") == "⌘" + ch }) {
      pressed(i)
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
  override var acceptsFirstResponder: Bool { true }

  var messageHeight: CGFloat {
    message.isHidden ? 0 : message.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: Tokens.dialogWidth - 2 * Tokens.dialogPadding, height: 1000)).height
  }
  var titleHeight: CGFloat {
    max(22, ceil(title.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: Tokens.dialogWidth - 2 * Tokens.dialogPadding, height: 1000)).height))
  }
  var iconSize: CGFloat { icon.spec.hasPrefix("sf:") ? Tokens.dialogHeroIconSize : Tokens.dialogIconSize }

  var contentHeight: CGFloat {
    // Spec §5: 450x248 with icon (62) at 38, title at 117, no message.
    let pad = Tokens.dialogPadding
    var h = pad + (icon.isHidden ? 0 : iconSize + 17) + titleHeight
    if !message.isHidden { h += 8 + messageHeight }
    if checkbox != nil { h += 30 }
    if !fields.isEmpty { h += 14 + CGFloat(fields.count) * 36 - 8 }
    if !choices.isEmpty { h += 14 + CGFloat(choices.count) * Self.choiceHeight }
    h += 33 + Tokens.dialogButtonHeight + Tokens.dialogButtonInset
    return max(icon.isHidden ? 0 : 248, h)
  }

  override func layout() {
    super.layout()
    let pad = Tokens.dialogPadding, w = bounds.width - 2 * pad
    var y = pad
    if !icon.isHidden {
      let s = iconSize
      if hero.isHidden {
        icon.frame = NSRect(x: pad, y: y, width: s, height: s)
      } else {
        hero.frame = NSRect(x: pad, y: y, width: s, height: s)
        let g = Tokens.dialogHeroGlyphSize
        icon.frame = NSRect(x: pad + (s - g) / 2, y: y + (s - g) / 2, width: g, height: g)
      }
      y += s + 17
    }
    let th = titleHeight
    title.frame = NSRect(x: pad, y: y, width: w, height: th); y += th
    if !message.isHidden { message.frame = NSRect(x: pad, y: y + 8, width: w, height: messageHeight); y += 8 + messageHeight }
    if let c = checkbox { c.sizeToFit(); c.frame.origin = NSPoint(x: pad - 2, y: y + 8); y += 30 }
    if !fields.isEmpty {
      y += 14
      for f in fields { f.frame = NSRect(x: pad, y: y, width: w, height: 28); y += 36 }
    }
    if !choices.isEmpty {
      y += 14
      for c in choices { c.frame = NSRect(x: pad - 10, y: y, width: w + 20, height: Self.choiceHeight); y += Self.choiceHeight }
    }
    // Buttons: one row, 28 pt from the sides and bottom (PX). Cancel/default buttons pack to the
    // right 7 pt apart (spec §5); a leading secondary button ("Quit, and don’t ask again") sits left.
    let inset = Tokens.dialogButtonInset
    var x = bounds.width - inset
    let by = bounds.height - inset - Tokens.dialogButtonHeight
    let specs = node.list("buttons")
    var trailing = buttons
    if buttons.count > 1, let first = specs.first, first.str("style", "secondary") == "secondary", !Self.isDefault(first) {
      trailing = Array(buttons.dropFirst())
      buttons[0].frame = NSRect(x: inset, y: by, width: buttons[0].preferredWidth, height: Tokens.dialogButtonHeight)
    }
    for b in trailing.reversed() {
      let bw = b.preferredWidth
      x -= bw
      b.frame = NSRect(x: x, y: by, width: bw, height: Tokens.dialogButtonHeight)
      x -= Tokens.dialogButtonGap
    }
  }
}

/// One choice in a dialog (the upload picker): a thumbnail or file icon, a name and a detail line.
/// Selected rows get the accent tint; with `multiple`, a checkmark.
@MainActor
final class ChoiceRow: FlippedView, Themable, Hoverable {
  var hoverGroup: HoverGroup { .row }
  let icon = IconView()
  let title = makeLabel(size: 13, weight: .medium)
  let subtitle = makeLabel(size: 11.5)
  let check = IconView()
  var choiceId = ""
  var multiple = false { didSet { needsLayout = true } }
  var selected = false { didSet { check.isHidden = !(multiple && selected); needsDisplay = true } }
  var hovering = false { didSet { needsDisplay = true } }
  var onClick: (() -> Void)?
  var fill: NSColor = .clear
  var selectedFill: NSColor = .clear

  override init(frame: NSRect) {
    super.init(frame: frame)
    check.spec = "sf:checkmark.circle.fill"
    check.isHidden = true
    [icon, title, subtitle, check].forEach { addSubview($0) }
  }
  required init?(coder: NSCoder) { fatalError() }

  func apply(_ p: Palette) {
    title.textColor = p.textPrimary
    subtitle.textColor = p.textSecondary
    icon.tint = p.textPrimary
    check.tint = p.accentStrong
    fill = p.rowHover.withAlphaComponent(p.dark ? 0.08 : 0.05)
    selectedFill = p.accentStrong.withAlphaComponent(p.dark ? 0.22 : 0.14)
    needsDisplay = true
  }
  override func draw(_ dirtyRect: NSRect) {
    guard selected || hovering else { return }
    (selected ? selectedFill : fill).setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
  }
  override func layout() {
    let h = bounds.height
    icon.frame = NSRect(x: 10, y: (h - 32) / 2, width: 32, height: 32)
    let right = bounds.width - (multiple ? 38 : 10)
    title.frame = NSRect(x: 52, y: h / 2 - 17, width: max(0, right - 52), height: 17)
    subtitle.frame = NSRect(x: 52, y: h / 2 + 1, width: max(0, right - 52), height: 15)
    check.frame = NSRect(x: bounds.width - 30, y: (h - 18) / 2, width: 18, height: 18)
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }
  override func mouseEntered(with event: NSEvent) { HoverTracker.refresh(window) }
  override func mouseExited(with event: NSEvent) { HoverTracker.refresh(window) }
  override var mouseDownCanMoveWindow: Bool { false }
  override func mouseDown(with event: NSEvent) {}
  override func mouseUp(with event: NSEvent) {
    if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
  }
}

/// Small keycap ("esc", "↩", "→") drawn inside buttons and command bar rows.
@MainActor
final class Keycap: NSView {
  var text = "" { didSet { needsDisplay = true } }
  var font = NSFont.systemFont(ofSize: 11, weight: .medium)
  var border: NSColor?
  var fill: NSColor = NSColor(white: 0, alpha: 0.05)
  var fg: NSColor = .secondaryLabelColor
  var radius: CGFloat = 5
  func apply(_ p: Palette, onAccent: Bool) {
    fill = onAccent ? p.onAccent.withAlphaComponent(0.2) : p.rowHover  // AccessoryBackground (spec §2)
    fg = onAccent ? p.onAccent.withAlphaComponent(0.9) : p.panelSecondaryText
    needsDisplay = true
  }
  var preferredWidth: CGFloat { max(21, ceil((text as NSString).size(withAttributes: [.font: font]).width) + 10) }
  override func draw(_ dirtyRect: NSRect) {
    fill.setFill()
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
    path.fill()
    if let border { border.setStroke(); path.lineWidth = 1; path.stroke() }
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
    let sz = (text as NSString).size(withAttributes: attrs)
    (text as NSString).draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2), withAttributes: attrs)
  }
}

// MARK: - Toast

/// {type:"toast", id?, text, icon?, duration?: ms, action?: "Restart", dismiss?, hold?=true}. Theme-tinted
/// pill; auto-dismisses, but not while the pointer is on it (`hold: false` opts out). With `action`, a button at the end emits `ui.action {id, action: "toast"}`
/// and closes the toast; `duration: 0` keeps it until then. A new toast with the same `id`
/// replaces it; `dismiss: true` removes it.
@MainActor
final class ToastView: FlippedView, Themable {
  let icon = IconView()
  let label = makeLabel(size: 13, weight: .medium)
  let actionLabel = makeLabel(size: 13, weight: .semibold)
  let divider = NSView()
  var color: NSColor = .black
  var onAction: (() -> Void)?
  var toastId = ""

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
    divider.wantsLayer = true
    divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.3).cgColor
    addSubview(divider)
    addSubview(actionLabel)
  }
  required init?(coder: NSCoder) { fatalError() }

  var hasAction: Bool { !actionLabel.stringValue.isEmpty }

  func update(_ v: Value, palette p: Palette) {
    label.stringValue = v.str("text")
    icon.spec = v.str("icon")
    icon.isHidden = icon.spec.isEmpty
    actionLabel.stringValue = v.str("action")
    actionLabel.isHidden = !hasAction
    divider.isHidden = !hasAction
    apply(p)
  }

  override func mouseDown(with event: NSEvent) {
    guard hasAction else { return super.mouseDown(with: event) }
    let p = convert(event.locationInWindow, from: nil)
    if p.x >= divider.frame.minX - 4 { onAction?() }
  }
  override func resetCursorRects() {
    if hasAction { addCursorRect(NSRect(x: divider.frame.minX, y: 0, width: bounds.width - divider.frame.minX, height: bounds.height), cursor: .pointingHand) }
  }
  override var mouseDownCanMoveWindow: Bool { false }
  func apply(_ p: Palette) {
    layer?.backgroundColor = p.toast.cgColor
    label.textColor = p.onToast
    actionLabel.textColor = p.onToast
    icon.tint = p.onToast
    layer?.shadowColor = p.shadowColor.cgColor
  }
  var actionWidth: CGFloat { hasAction ? ceil(actionLabel.textWidth) + 25 : 0 }
  var contentWidth: CGFloat { ceil(label.textWidth) + (icon.isHidden ? 40 : 64) + actionWidth }
  override func layout() {
    super.layout()
    var x: CGFloat = 16
    if !icon.isHidden { icon.frame = NSRect(x: x, y: (bounds.height - 15) / 2, width: 15, height: 15); x += 24 }
    label.frame = NSRect(x: x, y: (bounds.height - 17) / 2, width: bounds.width - x - 14 - actionWidth, height: 17)
    if hasAction {
      let ax = bounds.width - 14 - ceil(actionLabel.textWidth)
      actionLabel.frame = NSRect(x: ax, y: (bounds.height - 17) / 2, width: ceil(actionLabel.textWidth) + 2, height: 17)
      divider.frame = NSRect(x: ax - 12, y: 9, width: 1, height: bounds.height - 18)
    }
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
  let label = makeLabel(size: 13)  // PX: "Quit, and don’t ask again" is 150 pt of ink = SF 13 regular
  let keycap = Keycap()
  let style: String
  let action: () -> Void
  var fill: NSColor = .gray
  var border: NSColor?
  var pressedDown = false { didSet { needsDisplay = true } }
  var hovering = false { didSet { needsDisplay = true } }
  var hoverFill: NSColor?
  var pressedFill: NSColor?
  var cornerRadius = Tokens.dialogButtonCornerRadius
  init(title: String, style: String, keycap key: String = "", action: @escaping () -> Void) {
    self.style = style
    self.action = action
    super.init(frame: .zero)
    label.stringValue = title
    keycap.text = key
    keycap.font = .systemFont(ofSize: key == "↩" ? 13 : 10, weight: .bold)  // PX: "ESC" is 20.5 pt wide, 8 pt caps
    keycap.isHidden = key.isEmpty
    addSubview(label)
    addSubview(keycap)
  }
  required init?(coder: NSCoder) { fatalError() }
  // PX: 12.5 pt side padding, 8 pt label-to-keycap gap (176 / 110 / 86 pt buttons in spec §5).
  var preferredWidth: CGFloat { ceil(label.textWidth - 2) + 25 + (keycap.isHidden ? 0 : keycapWidth + 8) }
  var keycapWidth: CGFloat { max(28, ceil((keycap.text as NSString).size(withAttributes: [.font: keycap.font]).width) + 14) }
  func apply(_ p: Palette) {
    border = nil
    hoverFill = nil
    pressedFill = nil
    let t = p.tokens
    switch style {
    case "default":
      // The theme accent (Arc's #3139FB in its default theme) with its contrast-checked label.
      fill = p.primaryButton; label.textColor = p.onAccent
      hoverFill = t.accent.mix(RGB(0, 0, 0), 0.08).ns
    case "destructive":
      // Spec §3 DestructiveButtonFace #F53714 (hover #DD3112, pressed #D02F11), darkened by the
      // tokens just enough for its white label (WCAG AA).
      fill = p.destructive; label.textColor = p.onDestructive
      hoverFill = t.destructive.mix(RGB(0, 0, 0), 0.08).ns
      pressedFill = t.destructive.mix(RGB(0, 0, 0), 0.14).ns
    case "destructiveSecondary":  // estimate: red text on a faint red pill (e.g. "Clear Archive")
      fill = p.destructive.withAlphaComponent(p.dark ? 0.16 : 0.08)
      border = p.destructive.withAlphaComponent(0.35)
      label.textColor = ThemeTokens.ensure(p.dark ? t.destructive.mix(RGB(1, 1, 1), 0.3) : t.destructive, on: t.surface, ThemeTokens.bodyContrast).ns
    default:
      // PX (dark, arc_quit_dialog.png): fill (48,47,99) with a (99,98,174) border on #151C30: the
      // surface pulled toward the accent. den derives both from the theme's accent and surface.
      fill = t.surface.mix(t.accent, p.dark ? 0.2 : 0.07).ns
      border = t.surface.mix(t.accent, p.dark ? 0.5 : 0.28).ns
      label.textColor = ThemeTokens.ensure(t.textPrimary, on: t.surface.mix(t.accent, p.dark ? 0.2 : 0.07), ThemeTokens.bodyContrast).ns
    }
    // PX: keycaps are white α≈0.12 over their button ((78,76,122) on (48,47,99); (70,77,251) on blue).
    let onFill = style == "default" ? p.onAccent : (style == "destructive" ? p.onDestructive : label.textColor ?? p.textPrimary)
    keycap.fill = onFill.withAlphaComponent(0.13)
    keycap.border = style == "default" ? onFill.withAlphaComponent(0.35) : nil  // estimate: outlined ↩ cap on the primary button
    keycap.fg = onFill.withAlphaComponent(0.8)
    keycap.needsDisplay = true
    needsDisplay = true
  }
  override func layout() {
    let lw = ceil(label.textWidth)
    label.frame = NSRect(x: 10.5, y: (bounds.height - 17) / 2, width: lw + 4, height: 17)  // the cell insets text by 2
    keycap.frame = NSRect(x: bounds.width - 12.5 - keycapWidth, y: (bounds.height - 20) / 2, width: keycapWidth, height: 20)
  }
  override func draw(_ dirtyRect: NSRect) {
    let r = cornerRadius
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: r, yRadius: r)
    let f = pressedDown ? (pressedFill ?? fill.blended(withFraction: 0.15, of: .black) ?? fill) : (hovering ? (hoverFill ?? fill) : fill)
    f.setFill()
    path.fill()
    if let border { border.setStroke(); path.lineWidth = 1; path.stroke() }
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }
  override func mouseEntered(with event: NSEvent) { hovering = true }
  override func mouseExited(with event: NSEvent) { hovering = false }
  override func mouseDown(with event: NSEvent) { pressedDown = true }
  override func mouseUp(with event: NSEvent) {
    pressedDown = false
    if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
  }
}
