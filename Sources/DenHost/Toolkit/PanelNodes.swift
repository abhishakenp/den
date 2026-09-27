import AppKit
import CordisValue

/// A popover body built from ordinary nodes (the `popover` slot), e.g. the Shields panel.
///
/// {type:"panel", id, width? (320), icon?, tone?: accent|warning|secondary, title, subtitle?, children}
/// A header (icon, title, subtitle) over children stacked 10 pt apart, 14 pt padding. Children are
/// any nodes: `section` with `toggleRow`/`choiceRow`/`valueRow`, `paragraph`, `buttonRow`…
/// Esc emits `dismiss` (a click outside does too, from the popover backdrop).
final class PopoverCardNode: NodeView {
  let icon = IconView()
  let title = makeLabel(size: 15, weight: .semibold)
  let subtitle = makeLabel(size: 12)
  var kids: [NodeView] = []
  static let padding: CGFloat = 14
  static let spacing: CGFloat = 10

  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    [icon, title, subtitle].forEach { addSubview($0) }
    title.lineBreakMode = .byTruncatingMiddle
    subtitle.lineBreakMode = .byTruncatingTail
  }
  required init?(coder: NSCoder) { fatalError() }

  override func update(_ v: Value) {
    super.update(v)
    icon.spec = v.str("icon")
    icon.isHidden = icon.spec.isEmpty
    title.stringValue = v.str("title")
    subtitle.stringValue = v.str("subtitle")
    subtitle.isHidden = subtitle.stringValue.isEmpty
    kids = r.reconcile(v.list("children"), existing: kids, in: self)
    apply(r.palette)
    needsLayout = true
  }

  override func apply(_ p: Palette) {
    title.textColor = p.textPrimary
    subtitle.textColor = p.textSecondary
    switch node.str("tone") {
    case "warning": icon.tint = p.destructive
    case "secondary": icon.tint = p.textSecondary
    default: icon.tint = p.accentStrong
    }
  }

  override var preferredWidth: CGFloat? { CGFloat(node.num("width", 320)) }
  var headerHeight: CGFloat { subtitle.isHidden ? 24 : 40 }
  var innerWidth: CGFloat { (preferredWidth ?? 320) - 2 * Self.padding }

  override func height(for w: CGFloat) -> CGFloat {
    let cw = w - 2 * Self.padding
    let hs = kids.map { $0.height(for: cw) }.filter { $0 > 0 }
    return Self.padding + headerHeight + (hs.isEmpty ? 0 : 12 + hs.reduce(0, +) + Self.spacing * CGFloat(hs.count - 1)) + Self.padding
  }

  override func layout() {
    let x0 = Self.padding, cw = bounds.width - 2 * Self.padding
    var tx = x0
    if !icon.isHidden {
      icon.frame = NSRect(x: x0, y: Self.padding + (headerHeight - 20) / 2, width: 20, height: 20)
      tx += 30
    }
    if subtitle.isHidden {
      title.frame = NSRect(x: tx, y: Self.padding + 2, width: x0 + cw - tx, height: 20)
    } else {
      title.frame = NSRect(x: tx, y: Self.padding, width: x0 + cw - tx, height: 20)
      subtitle.frame = NSRect(x: tx, y: Self.padding + 21, width: x0 + cw - tx, height: 16)
    }
    var y = Self.padding + headerHeight + 12
    for k in kids {
      let h = k.height(for: cw)
      k.frame = NSRect(x: x0, y: y, width: cw, height: h)
      k.isHidden = h == 0
      if h > 0 { y += h + Self.spacing }
    }
  }

  override var acceptsFirstResponder: Bool { true }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 { emit("dismiss"); return }
    super.keyDown(with: event)
  }
  override func cancelOperation(_ sender: Any?) { emit("dismiss") }
}

/// {type:"valueRow", id, title, subtitle?, icon?, value?, tone?: success|warning|secondary,
///  shortcut?, buttons?: [{id, icon}]} — a setting row showing a value (e.g. "110%", "Secure"),
/// with small icon buttons after it. A button emits `click {button}`.
final class ValueRowNode: SettingRowNode {
  let value = makeLabel(size: 12.5, weight: .medium)
  var buttons: [IconButton] = []
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    value.alignment = .right
    addSubview(value)
  }
  required init?(coder: NSCoder) { fatalError() }

  override func update(_ v: Value) {
    let old = node.list("buttons")
    super.update(v)
    value.stringValue = v.str("value")
    if old != v.list("buttons") || buttons.count != v.list("buttons").count {
      buttons.forEach { $0.removeFromSuperview() }
      buttons = v.list("buttons").map { b in
        let id = b.str("id")
        let btn = IconButton(symbol: b.str("icon", "sf:circle"), size: 24) { [weak self] in self?.emit("click", ["button": .string(id)]) }
        addSubview(btn)
        return btn
      }
    }
    apply(r.palette)
    needsLayout = true
  }

  override func apply(_ p: Palette) {
    super.apply(p)
    switch node.str("tone") {
    case "success": value.textColor = p.success
    case "warning": value.textColor = p.destructive
    default: value.textColor = p.textSecondary
    }
    for b in buttons { b.apply(p); b.tint = p.textPrimary.withAlphaComponent(0.8) }
  }

  override var trailingWidth: CGFloat {
    let bw = CGFloat(buttons.count) * 26
    let vw = value.stringValue.isEmpty ? 0 : ceil(value.textWidth) + 4
    return bw + vw + (bw > 0 && vw > 0 ? 4 : 0)
  }

  override func layoutTrailing(right: CGFloat) {
    let h = bounds.height
    var x = right
    for b in buttons.reversed() {
      x -= 24
      b.frame = NSRect(x: x, y: (h - 24) / 2, width: 24, height: 24)
      x -= 2
    }
    if !value.stringValue.isEmpty {
      let vw = ceil(value.textWidth) + 4
      if !buttons.isEmpty { x -= 2 }
      value.frame = NSRect(x: x - vw, y: (h - 16) / 2, width: vw, height: 16)
    }
  }
}
