import AppKit
import CordisValue

// Node types for the briefing page and the connections sheet (see Sheet.swift and the `ui`
// section of docs/host-api.md). Every size is an estimate: this UI is den's own, not Arc's.

/// Wrapping label.
@MainActor
func makeWrappingLabel(size: CGFloat, weight: NSFont.Weight = .regular) -> NSTextField {
  let l = NSTextField(wrappingLabelWithString: "")
  l.font = .systemFont(ofSize: size, weight: weight)
  l.isSelectable = false
  l.lineBreakMode = .byWordWrapping
  return l
}

extension NSTextField {
  /// Height of the wrapped text at `width`.
  @MainActor func wrappedHeight(_ width: CGFloat) -> CGFloat {
    guard !stringValue.isEmpty, let cell else { return 0 }
    return ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: max(1, width), height: 10_000)).height)
  }
}

/// Row with a rounded hover fill that emits `open` on click.
@MainActor
class SheetRowNode: NodeView, Hoverable {
  var hoverGroup: HoverGroup { .row }
  var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
  override func draw(_ dirtyRect: NSRect) {
    guard hovering else { return }
    palette.rowHover.withAlphaComponent(palette.dark ? 0.06 : 0.04).setFill()
    NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 3), xRadius: Tokens.sheetRowRadius, yRadius: Tokens.sheetRowRadius).fill()
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }
  override func mouseEntered(with event: NSEvent) { HoverTracker.refresh(window) }
  override func mouseExited(with event: NSEvent) { HoverTracker.refresh(window) }
  override func mouseDown(with event: NSEvent) {}
  override func mouseUp(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    if bounds.contains(p) { clicked(at: p) }
  }
  func clicked(at p: NSPoint) { emit("open") }
}

// MARK: - Text

/// {type:"heading", text, subtitle?}
final class HeadingNode: NodeView {
  let title = makeLabel(size: 26, weight: .semibold)
  let subtitle = makeLabel(size: 13)
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    addSubview(title)
    addSubview(subtitle)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func update(_ v: Value) {
    super.update(v)
    title.stringValue = v.str("text")
    subtitle.stringValue = v.str("subtitle")
    subtitle.isHidden = subtitle.stringValue.isEmpty
    apply(r.palette)
  }
  override func apply(_ p: Palette) { title.textColor = p.textPrimary; subtitle.textColor = p.textSecondary }
  override func height(for w: CGFloat) -> CGFloat { subtitle.isHidden ? 34 : 54 }
  override func layout() {
    subtitle.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 17)
    title.frame = NSRect(x: 0, y: subtitle.isHidden ? 0 : 18, width: bounds.width, height: 34)
  }
}

/// {type:"paragraph", text, style?: body|secondary|caption, icon?}
final class ParagraphNode: NodeView {
  let label = makeWrappingLabel(size: 13.5)
  let icon = IconView()
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    addSubview(icon)
    addSubview(label)
  }
  required init?(coder: NSCoder) { fatalError() }
  var style: String { node.str("style", "body") }
  override func update(_ v: Value) {
    super.update(v)
    let size: CGFloat = style == "caption" ? 11.5 : (style == "secondary" ? 12.5 : 13.5)
    let para = NSMutableParagraphStyle()
    para.lineSpacing = style == "body" ? 3 : 1.5
    para.lineBreakMode = .byWordWrapping
    label.attributedStringValue = NSAttributedString(string: v.str("text"), attributes: [.font: NSFont.systemFont(ofSize: size), .paragraphStyle: para])
    icon.spec = v.str("icon")
    icon.isHidden = icon.spec.isEmpty
    apply(r.palette)
    needsLayout = true
  }
  override func apply(_ p: Palette) {
    let color = style == "body" ? p.textPrimary : p.textSecondary
    let s = NSMutableAttributedString(attributedString: label.attributedStringValue)
    s.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: s.length))
    label.attributedStringValue = s
    icon.tint = p.accentStrong
  }
  var textX: CGFloat { icon.isHidden ? 0 : 24 }
  override func height(for w: CGFloat) -> CGFloat {
    guard !node.str("text").isEmpty else { return 0 }
    return max(icon.isHidden ? 0 : 18, label.wrappedHeight(w - textX - 4))
  }
  override func layout() {
    icon.frame = NSRect(x: 0, y: 2, width: 15, height: 15)
    label.frame = NSRect(x: textX, y: 0, width: bounds.width - textX, height: bounds.height)
  }
}

// MARK: - Section

/// {type:"section", id?, title, accessory?, children}: a caption header over a rounded card
/// whose rows are separated by hairlines inset 44 from the left.
final class SectionNode: NodeView {
  let title = makeLabel(size: 11, weight: .semibold)
  let accessory = makeLabel(size: 11, weight: .medium)
  let card = FlippedView()
  var kids: [NodeView] = []
  var dividers: [NSView] = []
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    card.wantsLayer = true
    card.layer?.cornerRadius = Tokens.sectionCardRadius
    card.layer?.cornerCurve = .continuous
    card.layer?.borderWidth = 0.5
    accessory.alignment = .right
    [title, accessory, card].forEach { addSubview($0) }
  }
  required init?(coder: NSCoder) { fatalError() }
  override func update(_ v: Value) {
    super.update(v)
    title.stringValue = v.str("title").uppercased()
    accessory.stringValue = v.str("accessory")
    kids = r.reconcile(v.list("children"), existing: kids, in: card)
    while dividers.count < max(0, kids.count - 1) {
      let d = NSView()
      d.wantsLayer = true
      card.addSubview(d)
      dividers.append(d)
    }
    while dividers.count > max(0, kids.count - 1) { dividers.removeLast().removeFromSuperview() }
    card.isHidden = kids.isEmpty
    apply(r.palette)
    needsLayout = true
  }
  override func apply(_ p: Palette) {
    title.textColor = p.textSecondary
    accessory.textColor = p.textSecondary
    card.layer?.backgroundColor = p.sectionFill.cgColor
    card.layer?.borderColor = p.sectionBorder.cgColor
    dividers.forEach { $0.layer?.backgroundColor = p.hairline.cgColor }
  }
  override func height(for w: CGFloat) -> CGFloat {
    let rows = kids.map { $0.height(for: w) }.reduce(0, +)
    return Tokens.sectionHeaderHeight + (kids.isEmpty ? 0 : rows)
  }
  override func layout() {
    let hh = Tokens.sectionHeaderHeight
    let aw = accessory.stringValue.isEmpty ? 0 : min(bounds.width / 2, ceil(accessory.textWidth) + 8)
    title.frame = NSRect(x: 4, y: hh - 20, width: bounds.width - aw - 12, height: 15)
    accessory.frame = NSRect(x: bounds.width - aw - 4, y: hh - 20, width: aw, height: 15)
    card.frame = NSRect(x: 0, y: hh, width: bounds.width, height: max(0, bounds.height - hh))
    var y: CGFloat = 0
    for (i, k) in kids.enumerated() {
      let h = k.height(for: bounds.width)
      k.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
      y += h
      if i < dividers.count {
        dividers[i].frame = NSRect(x: Tokens.sectionDividerInset, y: y - 0.5, width: bounds.width - Tokens.sectionDividerInset, height: 1 / max(1, window?.backingScaleFactor ?? 2))
      }
    }
  }
}

// MARK: - Rows

/// {type:"todoRow", id, title, subtitle?, icon, done, url?}
/// actions: toggle {done} (checkbox; flips locally at once), open (anywhere else).
final class TodoRowNode: SheetRowNode {
  let icon = IconView()
  let title = makeLabel(size: 13.5, weight: .medium)
  let subtitle = makeLabel(size: 12)
  var done = false
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    [icon, title, subtitle].forEach { addSubview($0) }
  }
  required init?(coder: NSCoder) { fatalError() }
  override func update(_ v: Value) {
    super.update(v)
    done = v.flag("done")
    icon.spec = v.str("icon", "sf:circle")
    icon.fallbackLetter = v.str("title")
    subtitle.stringValue = v.str("subtitle")
    subtitle.isHidden = subtitle.stringValue.isEmpty
    apply(r.palette)
    needsLayout = true
  }
  override func apply(_ p: Palette) {
    var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13.5, weight: .medium), .foregroundColor: done ? p.textSecondary : p.textPrimary]
    if done { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
    title.attributedStringValue = NSAttributedString(string: node.str("title"), attributes: attrs)
    subtitle.textColor = p.textSecondary
    icon.tint = p.textPrimary
    icon.alphaValue = done ? 0.5 : 1
    needsDisplay = true
  }
  var checkRect: NSRect {
    let s = Tokens.todoCheckboxSize
    return NSRect(x: 14, y: (bounds.height - s) / 2, width: s, height: s)
  }
  override func height(for w: CGFloat) -> CGFloat { Tokens.todoRowHeight }
  override func layout() {
    let h = bounds.height
    icon.frame = NSRect(x: 44, y: (h - 16) / 2, width: 16, height: 16)
    let x: CGFloat = 70, tw = bounds.width - x - 14
    if subtitle.isHidden {
      title.frame = NSRect(x: x, y: (h - 18) / 2, width: tw, height: 18)
    } else {
      title.frame = NSRect(x: x, y: h / 2 - 17, width: tw, height: 18)
      subtitle.frame = NSRect(x: x, y: h / 2 + 1, width: tw, height: 16)
    }
  }
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let r = checkRect.insetBy(dx: 0.75, dy: 0.75)
    let circle = NSBezierPath(ovalIn: r)
    if done {
      palette.accentStrong.setFill()
      circle.fill()
      let check = NSBezierPath()
      check.move(to: NSPoint(x: r.minX + r.width * 0.27, y: r.midY + r.height * 0.02))
      check.line(to: NSPoint(x: r.minX + r.width * 0.44, y: r.minY + r.height * 0.70))
      check.line(to: NSPoint(x: r.minX + r.width * 0.74, y: r.minY + r.height * 0.32))
      check.lineWidth = 1.8
      check.lineCapStyle = .round
      check.lineJoinStyle = .round
      NSColor.white.setStroke()
      check.stroke()
    } else {
      circle.lineWidth = 1.5
      NSColor(white: palette.dark ? 1 : 0, alpha: 0.35).setStroke()
      circle.stroke()
    }
  }
  override func clicked(at p: NSPoint) {
    if checkRect.insetBy(dx: -8, dy: -8).contains(p) { toggle() } else { emit("open") }
  }
  func toggle() {
    done.toggle()
    apply(palette)
    emit("toggle", ["done": .bool(done)])
  }
}

/// Small rounded text badge ("Review", "CI failed").
@MainActor
final class BadgeView: NSView {
  var text = "" { didSet { needsDisplay = true } }
  var color: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
  var dark = false
  let font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
  var preferredWidth: CGFloat { text.isEmpty ? 0 : ceil((text as NSString).size(withAttributes: [.font: font]).width) + 14 }
  override func draw(_ dirtyRect: NSRect) {
    guard !text.isEmpty else { return }
    color.withAlphaComponent(dark ? 0.24 : 0.12).setFill()
    NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    let fg = dark ? color.blended(withFraction: 0.35, of: .white)! : color
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
    let s = (text as NSString).size(withAttributes: attrs)
    (text as NSString).draw(at: NSPoint(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2), withAttributes: attrs)
  }
}

/// {type:"feedRow", id, title, subtitle?, icon, time?, badge?, unread?} -> open
final class FeedRowNode: SheetRowNode {
  let icon = IconView()
  let title = makeLabel(size: 13.5, weight: .medium)
  let subtitle = makeLabel(size: 12)
  let time = makeLabel(size: 11)
  let badge = BadgeView()
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    time.alignment = .right
    [icon, title, subtitle, time, badge].forEach { addSubview($0) }
  }
  required init?(coder: NSCoder) { fatalError() }
  override func update(_ v: Value) {
    super.update(v)
    icon.spec = v.str("icon", "sf:circle")
    icon.fallbackLetter = v.str("title")
    title.stringValue = v.str("title")
    subtitle.stringValue = v.str("subtitle")
    time.stringValue = v.str("time")
    badge.text = v.str("badge")
    badge.isHidden = badge.text.isEmpty
    apply(r.palette)
    needsLayout = true
  }
  override func apply(_ p: Palette) {
    title.textColor = p.textPrimary
    subtitle.textColor = p.textSecondary
    time.textColor = p.textSecondary
    icon.tint = p.textPrimary
    badge.color = p.accentStrong
    badge.dark = p.dark
    needsDisplay = true
  }
  override func height(for w: CGFloat) -> CGFloat { Tokens.feedRowHeight }
  override func layout() {
    let h = bounds.height
    icon.frame = NSRect(x: 18, y: (h - 20) / 2, width: 20, height: 20)
    var right = bounds.width - 14
    let tw = time.stringValue.isEmpty ? 0 : ceil(time.textWidth) + 8
    time.frame = NSRect(x: right - tw, y: h / 2 - 16, width: tw, height: 14)
    let bw = badge.preferredWidth
    badge.frame = NSRect(x: right - bw, y: h / 2 + 1, width: bw, height: 17)
    right -= max(tw, bw) + 12
    let x: CGFloat = 50
    title.frame = NSRect(x: x, y: h / 2 - 18, width: max(0, right - x), height: 18)
    subtitle.frame = NSRect(x: x, y: h / 2 + 1, width: max(0, right - x), height: 16)
    if subtitle.stringValue.isEmpty { title.frame.origin.y = (h - 18) / 2 }
  }
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard node.flag("unread") else { return }
    palette.accentStrong.setFill()
    NSBezierPath(ovalIn: NSRect(x: 6, y: bounds.midY - 3, width: 6, height: 6)).fill()
  }
}

// MARK: - Buttons

/// {type:"actionButton", id, title, icon?, style: primary|secondary|destructive} -> click
final class ActionButtonNode: NodeView {
  var pill: PillButton?
  static func pillStyle(_ s: String) -> String {
    switch s {
    case "primary": return "default"
    case "destructive": return "destructiveSecondary"
    default: return "secondary"
    }
  }
  override func update(_ v: Value) {
    let old = node
    super.update(v)
    if pill == nil || old.str("title") != v.str("title") || old.str("style") != v.str("style") {
      pill?.removeFromSuperview()
      let p = PillButton(title: v.str("title"), style: Self.pillStyle(v.str("style", "secondary"))) { [weak self] in self?.emit("click") }
      addSubview(p)
      pill = p
      p.apply(r.palette)
      needsLayout = true
    }
  }
  override func apply(_ p: Palette) { pill?.apply(p) }
  override func height(for w: CGFloat) -> CGFloat { Tokens.sheetButtonHeight }
  override var preferredWidth: CGFloat? { max(64, pill?.preferredWidth ?? 64) }
  override func layout() { pill?.frame = bounds }
}

/// {type:"buttonRow", children, align?: leading|center}
final class ButtonRowNode: NodeView {
  var kids: [NodeView] = []
  override func update(_ v: Value) {
    super.update(v)
    kids = r.reconcile(v.list("children"), existing: kids, in: self)
    needsLayout = true
  }
  override func height(for w: CGFloat) -> CGFloat { kids.isEmpty ? 0 : Tokens.sheetButtonHeight }
  override func layout() {
    let widths = kids.map { $0.preferredWidth ?? 100 }
    let total = widths.reduce(0, +) + 8 * CGFloat(max(0, kids.count - 1))
    var x = node.str("align") == "center" ? ((bounds.width - total) / 2).rounded() : 0
    for (k, w) in zip(kids, widths) {
      k.frame = NSRect(x: x, y: 0, width: w, height: bounds.height)
      x += w + 8
    }
  }
}

// MARK: - Settings rows

/// {type:"connectionRow", id, title, icon, status, connected, button: {title, style}, secondaryButton?: {id, title, style}}
/// actions: click (main button), secondary.
final class ConnectionRowNode: NodeView {
  let icon = IconView()
  let title = makeLabel(size: 14, weight: .medium)
  let status = makeLabel(size: 12)
  var buttons: [PillButton] = []
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    [icon, title, status].forEach { addSubview($0) }
  }
  required init?(coder: NSCoder) { fatalError() }
  override func update(_ v: Value) {
    let old = node
    super.update(v)
    icon.spec = v.str("icon", "sf:link")
    icon.fallbackLetter = v.str("title")
    title.stringValue = v.str("title")
    if buttons.isEmpty || old["button"] != v["button"] || old["secondaryButton"] != v["secondaryButton"] {
      buttons.forEach { $0.removeFromSuperview() }
      buttons = []
      let s = v["secondaryButton"]
      if !s.isNull {
        buttons.append(PillButton(title: s.str("title"), style: ActionButtonNode.pillStyle(s.str("style", "secondary"))) { [weak self] in self?.emit("secondary") })
      }
      let b = v["button"]
      if !b.isNull {
        buttons.append(PillButton(title: b.str("title"), style: ActionButtonNode.pillStyle(b.str("style", "secondary"))) { [weak self] in self?.emit("click") })
      }
      buttons.forEach { addSubview($0) }
    }
    apply(r.palette)
    needsLayout = true
  }
  override func apply(_ p: Palette) {
    title.textColor = p.textPrimary
    icon.tint = p.textPrimary
    let text = node.str("status")
    if node.flag("connected") {
      let s = NSMutableAttributedString(string: "● ", attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: p.success, .baselineOffset: 1])
      s.append(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: p.textSecondary]))
      status.attributedStringValue = s
    } else {
      status.attributedStringValue = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: p.textSecondary])
    }
    buttons.forEach { $0.apply(p) }
  }
  override func height(for w: CGFloat) -> CGFloat { Tokens.connectionRowHeight }
  override func layout() {
    let h = bounds.height
    icon.frame = NSRect(x: 12, y: (h - 24) / 2, width: 24, height: 24)
    var right = bounds.width - 12
    for b in buttons.reversed() {
      let bw = b.preferredWidth
      b.frame = NSRect(x: right - bw, y: (h - 30) / 2, width: bw, height: 30)
      right -= bw + 8
    }
    let x: CGFloat = 50
    title.frame = NSRect(x: x, y: h / 2 - 18, width: max(0, right - x - 4), height: 18)
    status.frame = NSRect(x: x, y: h / 2 + 1, width: max(0, right - x - 4), height: 16)
  }
}

/// Shared layout for settings rows: optional icon, title + subtitle, a trailing control.
@MainActor
class SettingRowNode: NodeView {
  let icon = IconView()
  let title = makeLabel(size: 13.5)
  let subtitle = makeLabel(size: 11.5)
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    [icon, title, subtitle].forEach { addSubview($0) }
  }
  required init?(coder: NSCoder) { fatalError() }
  override func update(_ v: Value) {
    super.update(v)
    icon.spec = v.str("icon")
    icon.isHidden = icon.spec.isEmpty
    title.stringValue = v.str("title")
    subtitle.stringValue = v.str("subtitle")
    subtitle.isHidden = subtitle.stringValue.isEmpty
    apply(r.palette)
    needsLayout = true
  }
  override func apply(_ p: Palette) { title.textColor = p.textPrimary; subtitle.textColor = p.textSecondary; icon.tint = p.textPrimary }
  override func height(for w: CGFloat) -> CGFloat { subtitle.isHidden ? Tokens.settingRowHeight : Tokens.settingRowHeight + 8 }
  var control: NSView? { nil }
  override func layout() {
    let h = bounds.height
    var x: CGFloat = 14
    if !icon.isHidden {
      icon.frame = NSRect(x: 14, y: (h - 18) / 2, width: 18, height: 18)
      x = 44
    }
    var right = bounds.width - 12
    if let c = control {
      let s = c.fittingSize
      c.frame = NSRect(x: right - s.width, y: ((h - s.height) / 2).rounded(), width: s.width, height: s.height)
      right = c.frame.minX - 10
    }
    if subtitle.isHidden {
      title.frame = NSRect(x: x, y: (h - 18) / 2, width: max(0, right - x), height: 18)
    } else {
      title.frame = NSRect(x: x, y: h / 2 - 17, width: max(0, right - x), height: 18)
      subtitle.frame = NSRect(x: x, y: h / 2 + 2, width: max(0, right - x), height: 15)
    }
  }
}

/// {type:"toggleRow", id, title, subtitle?, icon?, on} -> toggle {on}
final class ToggleRowNode: SettingRowNode {
  let toggle = NSSwitch()
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    toggle.controlSize = .small
    toggle.target = self
    toggle.action = #selector(flipped)
    addSubview(toggle)
  }
  required init?(coder: NSCoder) { fatalError() }
  override var control: NSView? { toggle }
  override func update(_ v: Value) {
    super.update(v)
    toggle.state = v.flag("on") ? .on : .off
  }
  @objc func flipped() { emit("toggle", ["on": .bool(toggle.state == .on)]) }
}

/// {type:"choiceRow", id, title, subtitle?, options: [{id, title}], selected} -> select {option}
final class ChoiceRowNode: SettingRowNode {
  let popup = NSPopUpButton(frame: .zero, pullsDown: false)
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    popup.controlSize = .small
    popup.font = .systemFont(ofSize: 12)
    popup.target = self
    popup.action = #selector(chose)
    addSubview(popup)
  }
  required init?(coder: NSCoder) { fatalError() }
  override var control: NSView? { popup }
  override func update(_ v: Value) {
    super.update(v)
    popup.removeAllItems()
    for o in v.list("options") {
      popup.addItem(withTitle: o.str("title"))
      popup.lastItem?.representedObject = o.str("id")
    }
    if let i = v.list("options").firstIndex(where: { $0.str("id") == v.str("selected") }) { popup.selectItem(at: i) }
    needsLayout = true
  }
  @objc func chose() { emit("select", ["option": .string(popup.selectedItem?.representedObject as? String ?? "")]) }
}

// MARK: - Extensions page

/// {type:"extensionRow", id, icon, title, subtitle?, on, note?} -> toggle {on} (switch), open (row click)
/// An installed extension on the Extensions page: its icon, name, version line, an on/off switch
/// and a chevron to its details. `note` (e.g. "Update available") shows as an accent caption.
final class ExtensionRowNode: SheetRowNode {
  let icon = IconView()
  let title = makeLabel(size: 14, weight: .medium)
  let subtitle = makeLabel(size: 12)
  let note = makeLabel(size: 11, weight: .semibold)
  let chevron = IconView()
  let toggle = NSSwitch()
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    toggle.controlSize = .small
    toggle.target = self
    toggle.action = #selector(flipped)
    chevron.spec = "sf:chevron.right"
    [icon, title, subtitle, note, chevron, toggle].forEach { addSubview($0) }
  }
  required init?(coder: NSCoder) { fatalError() }
  override func update(_ v: Value) {
    super.update(v)
    icon.spec = v.str("icon", "sf:puzzlepiece.extension")
    icon.fallbackLetter = v.str("title")
    title.stringValue = v.str("title")
    subtitle.stringValue = v.str("subtitle")
    note.stringValue = v.str("note")
    note.isHidden = note.stringValue.isEmpty
    toggle.state = v.flag("on") ? .on : .off
    apply(r.palette)
    needsLayout = true
  }
  override func apply(_ p: Palette) {
    title.textColor = node.flag("on") ? p.text : p.secondaryText
    subtitle.textColor = p.secondaryText
    note.textColor = p.accentStrong
    icon.tint = p.text
    icon.alphaValue = node.flag("on") ? 1 : 0.45
    chevron.tint = p.tertiaryText
    needsDisplay = true
  }
  override func height(for w: CGFloat) -> CGFloat { Tokens.extensionRowHeight }
  override func layout() {
    let h = bounds.height
    icon.frame = NSRect(x: 14, y: (h - 32) / 2, width: 32, height: 32)
    chevron.frame = NSRect(x: bounds.width - 26, y: (h - 12) / 2, width: 12, height: 12)
    let s = toggle.fittingSize
    toggle.frame = NSRect(x: chevron.frame.minX - 12 - s.width, y: ((h - s.height) / 2).rounded(), width: s.width, height: s.height)
    let x: CGFloat = 60, right = toggle.frame.minX - 10
    var nw: CGFloat = 0
    if !note.isHidden {
      nw = min(160, ceil(note.textWidth))
      note.frame = NSRect(x: right - nw, y: (h - 15) / 2, width: nw, height: 15)
      nw += 8
    }
    title.frame = NSRect(x: x, y: h / 2 - 19, width: max(0, right - x - nw), height: 18)
    subtitle.frame = NSRect(x: x, y: h / 2 + 1, width: max(0, right - x - nw), height: 16)
  }
  override func clicked(at p: NSPoint) {
    if toggle.frame.insetBy(dx: -4, dy: -4).contains(p) { return }
    emit("open")
  }
  @objc func flipped() { emit("toggle", ["on": .bool(toggle.state == .on)]) }
}
