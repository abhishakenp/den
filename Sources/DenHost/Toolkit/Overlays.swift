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

// CommandBarView lives in CommandBarView.swift.

// MARK: - Dialog

/// {type:"dialog", id, title, message?, icon?, iconStyle?: accent|destructive|plain,
///  buttons: [{id, title, style: default|cancel|destructive|secondary, default?, keycap?}], checkbox?: {id, title, checked}}
/// action (id = dialog id): button {button, checked}. Return presses the `default` style button or the
/// button flagged `default: true` (e.g. a destructive confirm); Escape presses the cancel button.
/// Icons: `app:icon` draws at 62 pt (quit sheet, spec §5); any other icon is a 76 pt hero icon
/// (spec §5 "Dialog hero icons"): an `sf:` symbol on a tinted disc.
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
  var node: Value = .null
  let emit: (String, String, Value) -> Void

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
    hero.isHidden = icon.isHidden || icon.spec == "app:icon"
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
    apply(p)
    needsLayout = true
  }

  override func apply(_ p: Palette) {
    super.apply(p)
    surface.layer?.backgroundColor = p.popover.cgColor
    title.textColor = p.text
    message.textColor = p.secondaryText
    let tint: NSColor
    switch node.str("iconStyle", "accent") {
    case "destructive": tint = p.destructive
    case "plain": tint = p.text
    default: tint = p.accentStrong
    }
    icon.tint = tint
    hero.layer?.backgroundColor = tint.withAlphaComponent(p.dark ? 0.2 : 0.12).cgColor  // estimate
    buttons.forEach { $0.apply(p) }
  }

  func pressed(_ i: Int) {
    let spec = node.list("buttons")[i]
    emit(node.str("id", "dialog"), "button", ["button": .string(spec.str("id")), "checked": .bool(checkbox?.state == .on)])
  }

  static func isDefault(_ b: Value) -> Bool { b["default"].bool ?? (b.str("style") == "default") }

  /// Return / Escape trigger the default / cancel buttons.
  override func keyDown(with event: NSEvent) {
    let styles = node.list("buttons").map { $0.str("style") }
    if event.keyCode == 36 || event.keyCode == 76, let i = node.list("buttons").firstIndex(where: Self.isDefault) { pressed(i); return }
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
  var titleHeight: CGFloat {
    max(22, ceil(title.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: Tokens.dialogWidth - 2 * Tokens.dialogPadding, height: 1000)).height))
  }
  var iconSize: CGFloat { icon.spec == "app:icon" ? Tokens.dialogIconSize : Tokens.dialogHeroIconSize }

  var contentHeight: CGFloat {
    // Spec §5: 450x248 with icon (62) at 38, title at 117, no message.
    let pad = Tokens.dialogPadding
    var h = pad + (icon.isHidden ? 0 : iconSize + 17) + titleHeight
    if !message.isHidden { h += 8 + messageHeight }
    if checkbox != nil { h += 30 }
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
    if let c = checkbox { c.sizeToFit(); c.frame.origin = NSPoint(x: pad - 2, y: y + 8) }
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

/// Small keycap ("esc", "↩", "→") drawn inside buttons and command bar rows.
@MainActor
final class Keycap: NSView {
  var text = "" { didSet { needsDisplay = true } }
  var font = NSFont.systemFont(ofSize: 11, weight: .medium)
  var border: NSColor?
  var fill: NSColor = NSColor(white: 0, alpha: 0.05)
  var fg: NSColor = .secondaryLabelColor
  func apply(_ p: Palette, onAccent: Bool) {
    fill = onAccent ? NSColor(white: 1, alpha: 0.2) : NSColor(white: p.dark ? 1 : 0, alpha: 0.05)  // AccessoryBackground (spec §2)
    fg = onAccent ? NSColor(white: 1, alpha: 0.9) : p.panelSecondaryText
    needsDisplay = true
  }
  var preferredWidth: CGFloat { max(21, ceil((text as NSString).size(withAttributes: [.font: font]).width) + 10) }
  override func draw(_ dirtyRect: NSRect) {
    fill.setFill()
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
    path.fill()
    if let border { border.setStroke(); path.lineWidth = 1; path.stroke() }
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
    let sz = (text as NSString).size(withAttributes: attrs)
    (text as NSString).draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2), withAttributes: attrs)
  }
}

// MARK: - Toast

/// {type:"toast", id?, text, icon?, duration?: ms, action?: "Restart"}. Theme-tinted pill;
/// auto-dismisses. With `action`, a button at the end emits `ui.action {id, action: "toast"}` and
/// closes the toast; `duration: 0` keeps it until then.
@MainActor
final class ToastView: FlippedView, Themable {
  let icon = IconView()
  let label = makeLabel(size: 13, weight: .medium)
  let actionLabel = makeLabel(size: 13, weight: .semibold)
  let divider = NSView()
  var color: NSColor = .black
  var onAction: (() -> Void)?

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
    label.textColor = .white
    actionLabel.textColor = .white
    icon.tint = .white
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
    switch style {
    case "default": fill = p.primaryButton; label.textColor = .white
    case "destructive":
      // Spec §3 DestructiveButtonFace #F53714, hover #DD3112, pressed #D02F11.
      fill = p.destructive; label.textColor = .white
      hoverFill = NSColor(srgbRed: 0xDD / 255, green: 0x31 / 255, blue: 0x12 / 255, alpha: 1)
      pressedFill = NSColor(srgbRed: 0xD0 / 255, green: 0x2F / 255, blue: 0x11 / 255, alpha: 1)
    case "destructiveSecondary":  // estimate: red text on a faint red pill (e.g. "Clear Archive")
      fill = p.destructive.withAlphaComponent(p.dark ? 0.16 : 0.08)
      border = p.destructive.withAlphaComponent(0.35)
      label.textColor = p.dark ? p.destructive.blended(withFraction: 0.25, of: .white)! : p.destructive
    default:
      // PX (dark, arc_quit_dialog.png): fill (48,47,99), 1 pt border (99,98,174). Light: estimate.
      fill = p.dark ? NSColor(srgbRed: 48 / 255, green: 47 / 255, blue: 99 / 255, alpha: 1) : p.primaryButton.withAlphaComponent(0.08)
      border = p.dark ? NSColor(srgbRed: 99 / 255, green: 98 / 255, blue: 174 / 255, alpha: 1) : p.primaryButton.withAlphaComponent(0.28)
      label.textColor = p.dark ? .white : p.text
    }
    keycap.apply(p, onAccent: true)
    // PX: keycaps are white α≈0.12 over their button ((78,76,122) on (48,47,99); (70,77,251) on blue).
    keycap.fill = (style == "default" || style == "destructive" || p.dark) ? NSColor(white: 1, alpha: 0.12) : p.primaryButton.withAlphaComponent(0.1)
    keycap.border = style == "default" ? NSColor(white: 1, alpha: 0.35) : nil  // estimate: outlined ↩ cap on the primary button
    keycap.fg = (style == "default" || style == "destructive" || p.dark) ? NSColor(white: 1, alpha: 0.75) : p.primaryButton.withAlphaComponent(0.8)
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
