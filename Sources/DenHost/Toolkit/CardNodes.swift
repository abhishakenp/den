import AppKit
import CordisValue

// Generic composition nodes (docs/host-api.md "Generic nodes"). Feature-free: a plugin composes
// cards and popovers from these; every string, count and layout decision comes from the tree.
//
//   stack  {axis: v|h, spacing?, padding?: n | [top, right, bottom, left], distribute?: fill|equal,
//           align?: start|center|end, height?, children}
//   label  {text | runs: [{text, tone?, weight?}], size?, weight?, tone?, lines?, align?}
//   icon   {spec, size?, tone?}                      sf:/URL/path/emoji glyph
//   image  {src, width?, height?, aspect?, radius?}  bitmap, aspect-filled, placeholder while loading
//   badge  {text, tone?, icon?}                      pill
//   meter  {segments: [{value, tone}], height?}      segmented capsule over a track
//   note   {id?, text, tone?}                        tinted row with a leading accent bar; click
//   item   {id, title, subtitle?, icon?, accessory?, tone?, clickable?}   row; click
//   action {id, icon?, title?, variant?: icon|pill, tone?: default|primary|strong|destructive,
//           tooltip?, shortcut?, shortcutFor?, enabled?, menu?, height?} button; click / menu
//
// Tones: primary, secondary, glyph, success, warning, danger, add, del, accent, plus the fills
// above. Colors come from the theme tokens (`ThemeTokens.card`), never from the tree.

@MainActor
enum CardTone {
  static func color(_ tone: String, _ p: Palette, fallback: String = "primary") -> NSColor {
    let c = p.tokens.card
    switch tone.isEmpty ? fallback : tone {
    case "primary": return c.text.ns
    case "secondary": return c.secondary.ns
    case "glyph": return c.glyph.ns
    case "success": return c.success.ns
    case "warning": return c.warning.ns
    case "danger": return c.danger.ns
    case "add": return c.addText.ns
    case "del": return c.delText.ns
    case "accent": return p.primaryButton
    case "track", "neutral": return c.track.ns
    default: return c.text.ns
    }
  }

  static func weight(_ s: String) -> NSFont.Weight {
    switch s {
    case "medium": return .medium
    case "semibold": return .semibold
    case "bold": return .bold
    default: return .regular
    }
  }

  static func insets(_ v: Value) -> NSEdgeInsets {
    if let n = v.double { let f = CGFloat(n); return NSEdgeInsets(top: f, left: f, bottom: f, right: f) }
    let a = v.array ?? []
    func at(_ i: Int) -> CGFloat { i < a.count ? CGFloat(a[i].double ?? 0) : 0 }
    return a.count == 4 ? NSEdgeInsets(top: at(0), left: at(3), bottom: at(2), right: at(1)) : NSEdgeInsets()
  }
}

/// An icon whose tint its node sets: the recursive palette pass (`applyPaletteRecursively`) would
/// otherwise reset it to the sidebar's text color after the node chose a tone.
final class CardIconView: IconView {
  override func apply(_ p: Palette) {}
}

/// Width a label needs to draw its text untruncated on one line.
@MainActor
func naturalWidth(_ l: NSTextField) -> CGFloat {
  ceil(l.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000, height: 100)).width ?? l.textWidth) + 1
}

// MARK: - stack

final class CardStackNode: NodeView {
  var kids: [NodeView] = []
  var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
  override func update(_ v: Value) {
    super.update(v)
    kids = r.reconcile(v.list("children"), existing: kids, in: self)
    needsLayout = true
    needsDisplay = true
    updateTrackingAreas()
  }

  // `fill` (a surface behind the stack: `panel` = the sidebar's selected-tab fill, `card` =
  // the card surface, `hover` = the card hover fill) with `radius`; `clickable` with an `id`
  // emits `click {value}` for clicks that no child button takes, with the row hover fill.
  var clickable: Bool { !nodeId.isEmpty && node.flag("clickable") }
  func fillColor(_ name: String) -> NSColor? {
    switch name {
    case "panel": return palette.selectedFill
    case "card": return palette.tokens.card.fill.ns
    case "hover": return palette.tokens.card.hover.ns
    default: return nil
    }
  }
  override func draw(_ dirtyRect: NSRect) {
    var fill = fillColor(node.str("fill"))
    if hovering, clickable { fill = fill.map { $0.blended(withFraction: 0.08, of: palette.dark ? .white : .black) ?? $0 } ?? palette.hoverFill }
    guard let fill else { return }
    let r = CGFloat(node.num("radius", 8))
    fill.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    guard clickable else { hovering = false; return }
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }
  override func mouseEntered(with event: NSEvent) { hovering = true }
  override func mouseExited(with event: NSEvent) { hovering = false }
  override func mouseDown(with event: NSEvent) { if !clickable { super.mouseDown(with: event) } }
  override func mouseUp(with event: NSEvent) {
    guard clickable else { return super.mouseUp(with: event) }
    if bounds.contains(convert(event.locationInWindow, from: nil)) { emit("click", node["value"]) }
  }
  override func apply(_ p: Palette) { needsDisplay = true }
  var horizontal: Bool { node.str("axis", "v") == "h" }
  var spacing: CGFloat { CGFloat(node.num("spacing", 0)) }
  var pad: NSEdgeInsets { CardTone.insets(node["padding"]) }
  var equal: Bool { node.str("distribute") == "equal" }
  var visible: [NodeView] { kids.filter { !$0.node.flag("hidden") } }

  override var fitWidth: CGFloat? {
    let p = pad
    let ws = visible.compactMap(\.fitWidth)
    if horizontal {
      let each = equal ? CGFloat(visible.count) * (ws.max() ?? 0) : ws.reduce(0, +)
      return each + spacing * CGFloat(max(0, visible.count - 1)) + p.left + p.right
    }
    return (ws.max() ?? 0) + p.left + p.right
  }
  override var preferredWidth: CGFloat? { horizontal ? nil : node["width"].double.map { CGFloat($0) } }

  /// Widths of the children of a horizontal stack in `w` (padding already removed).
  func widths(_ w: CGFloat) -> [CGFloat] {
    let vs = visible
    guard !vs.isEmpty else { return [] }
    let gaps = spacing * CGFloat(vs.count - 1)
    if equal { return vs.map { _ in max(0, (w - gaps) / CGFloat(vs.count)) } }
    let fixed = vs.compactMap(\.preferredWidth).reduce(0, +)
    let flex = vs.filter { $0.preferredWidth == nil }.count
    let fw = flex > 0 ? max(0, (w - gaps - fixed) / CGFloat(flex)) : 0
    return vs.map { $0.preferredWidth ?? fw }
  }

  override func height(for w: CGFloat) -> CGFloat {
    let p = pad
    let inner = max(0, w - p.left - p.right)
    if horizontal {
      if let h = node["height"].double { return CGFloat(h) + p.top + p.bottom }
      let hs = zip(visible, widths(inner)).map { $0.height(for: $1) }
      return (hs.max() ?? 0) + p.top + p.bottom
    }
    let hs = visible.map { $0.height(for: inner) }.filter { $0 > 0 }
    guard !hs.isEmpty else { return 0 }
    return hs.reduce(0, +) + spacing * CGFloat(hs.count - 1) + p.top + p.bottom
  }

  override func layout() {
    super.layout()
    let p = pad
    let inner = NSRect(x: p.left, y: p.top, width: max(0, bounds.width - p.left - p.right), height: max(0, bounds.height - p.top - p.bottom))
    for k in kids where k.node.flag("hidden") { k.isHidden = true }
    if horizontal {
      var x = inner.minX
      let align = node.str("align", "center")
      for (k, w) in zip(visible, widths(inner.width)) {
        let h = min(inner.height, k.height(for: w))
        let y = align == "start" ? inner.minY : align == "end" ? inner.maxY - h : inner.minY + (inner.height - h) / 2
        k.frame = NSRect(x: x.rounded(), y: y.rounded(), width: w.rounded(.down), height: h)
        k.isHidden = false
        x += w + spacing
      }
      return
    }
    var y = inner.minY
    for k in visible {
      let h = k.height(for: inner.width)
      k.isHidden = h == 0
      guard h > 0 else { continue }
      var w = inner.width, x = inner.minX
      if let pw = k.preferredWidth, pw < inner.width {
        w = pw
        let align = node.str("align", "start")
        if align == "center" { x += ((inner.width - pw) / 2).rounded() } else if align == "end" { x = inner.maxX - pw }
      }
      k.frame = NSRect(x: x, y: y, width: w, height: h)
      y += h + spacing
    }
  }
}

// MARK: - label

final class LabelNode: NodeView {
  let label = makeLabel()
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    label.cell?.wraps = true
    label.cell?.truncatesLastVisibleLine = true
    label.lineBreakMode = .byTruncatingTail
    addSubview(label)
  }
  required init?(coder: NSCoder) { fatalError() }

  var font: NSFont { .systemFont(ofSize: CGFloat(node.num("size", 13)), weight: CardTone.weight(node.str("weight"))) }
  var lines: Int { max(1, Int(node.num("lines", 1))) }

  override func update(_ v: Value) {
    super.update(v)
    label.maximumNumberOfLines = lines
    label.cell?.wraps = lines > 1
    label.lineBreakMode = lines > 1 ? .byWordWrapping : .byTruncatingTail
    label.alignment = v.str("align") == "center" ? .center : v.str("align") == "right" ? .right : .natural
    apply(r.palette)
    needsLayout = true
  }

  override func apply(_ p: Palette) {
    let base = font
    let para = NSMutableParagraphStyle()
    // Wrapped labels word-wrap; `truncatesLastVisibleLine` still ends the last line in "…".
    para.lineBreakMode = lines > 1 ? .byWordWrapping : .byTruncatingTail
    para.alignment = label.alignment
    let runs = node.list("runs")
    let s = NSMutableAttributedString()
    if runs.isEmpty {
      s.append(NSAttributedString(string: node.str("text"), attributes: [.font: base, .foregroundColor: CardTone.color(node.str("tone"), p)]))
    } else {
      for run in runs {
        let f = run["weight"].isNull ? base : NSFont.systemFont(ofSize: base.pointSize, weight: CardTone.weight(run.str("weight")))
        let tone = run.str("tone", node.str("tone"))
        s.append(NSAttributedString(string: run.str("text"), attributes: [.font: f, .foregroundColor: CardTone.color(tone, p)]))
      }
    }
    s.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: s.length))
    label.attributedStringValue = s
    needsLayout = true
  }

  /// One line's height: `lineHeight` from the tree, else 1.3 x the font size (17 pt at 13 pt:
  /// Dia's title pitch, spec §2.3).
  var lineHeight: CGFloat { node["lineHeight"].double.map { CGFloat($0) } ?? ceil(font.pointSize * 1.3) }

  override func height(for w: CGFloat) -> CGFloat {
    if label.attributedStringValue.length == 0 { return 0 }
    if lines == 1 { return lineHeight }
    // Lines the text wraps to at this width (measured against one line), at the label's pitch.
    guard let cell = label.cell else { return lineHeight }
    let one = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000, height: 10_000)).height
    let all = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: max(1, w), height: 10_000)).height
    let n = CGFloat(min(max(1, one > 0 ? Int((all / one).rounded()) : 1), lines))
    // Wrapped lines sit 1 pt tighter than the first (Dia: 1 line 93 pt, 2 lines 109 pt, §2.3).
    return lineHeight * n - (n - 1)
  }
  override var fitWidth: CGFloat? { naturalWidth(label) }
  override var preferredWidth: CGFloat? { node["width"].double.map { CGFloat($0) } ?? (node.flag("fit") ? naturalWidth(label) : nil) }
  override func layout() { label.frame = bounds }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - icon

final class IconNode: NodeView {
  let icon = CardIconView()
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    addSubview(icon)
  }
  required init?(coder: NSCoder) { fatalError() }
  var size: CGFloat { CGFloat(node.num("size", 16)) }
  override func update(_ v: Value) {
    super.update(v)
    icon.spec = v.str("spec")
    icon.fallbackLetter = v.str("letter")
    apply(r.palette)
    needsLayout = true
  }
  override func apply(_ p: Palette) { icon.tint = CardTone.color(node.str("tone"), p, fallback: "glyph") }
  override func height(for w: CGFloat) -> CGFloat { icon.spec.isEmpty && icon.fallbackLetter.isEmpty ? 0 : size }
  override var preferredWidth: CGFloat? { size }
  override var fitWidth: CGFloat? { size }
  override func layout() { icon.frame = NSRect(x: 0, y: (bounds.height - size) / 2, width: size, height: size) }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - image

final class ImageNode: NodeView {
  var image: NSImage? { didSet { needsDisplay = true } }
  private var source = ""
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    wantsLayer = true
    layer?.masksToBounds = true
    layer?.cornerCurve = .continuous
  }
  required init?(coder: NSCoder) { fatalError() }
  override func update(_ v: Value) {
    super.update(v)
    layer?.cornerRadius = CGFloat(v.num("radius", 0))
    let src = v.str("src") + "#" + v.str("version")
    if src != source {
      source = src
      load(v.str("src"))
    }
    needsDisplay = true
  }
  func load(_ src: String) {
    image = nil
    guard !src.isEmpty else { return }
    let key = source
    if src.hasPrefix("http") {
      if let c = ImageCache.shared.cached(src) { image = c; return }
      ImageCache.shared.load(src) { [weak self] img in if self?.source == key { self?.image = img } }
    } else {
      let path = src.hasPrefix("file://") ? String(src.dropFirst(7)) : src
      // Decoding a small image is cheap, but keep it off the hover path.
      DispatchQueue.global(qos: .userInitiated).async {
        let data = FileManager.default.contents(atPath: path)
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            guard self.source == key else { return }
            self.image = data.flatMap { NSImage(data: $0) }
          }
        }
      }
    }
  }
  override var preferredWidth: CGFloat? { node["width"].double.map { CGFloat($0) } }
  override var fitWidth: CGFloat? { node["width"].double.map { CGFloat($0) } }
  override func height(for w: CGFloat) -> CGFloat {
    if node.str("src").isEmpty && !node.flag("placeholder") { return 0 }
    if let h = node["height"].double { return CGFloat(h) }
    return ((preferredWidth ?? w) * CGFloat(node.num("aspect", 1))).rounded()
  }
  override func apply(_ p: Palette) { needsDisplay = true }
  override func draw(_ dirtyRect: NSRect) {
    palette.tokens.card.hover.ns.setFill()
    bounds.fill()
    guard let img = image, img.size.width > 0, img.size.height > 0 else { return }
    // Aspect fill, anchored to the top (page snapshots and social images keep their headline).
    let scale = max(bounds.width / img.size.width, bounds.height / img.size.height)
    let w = img.size.width * scale, h = img.size.height * scale
    NSGraphicsContext.current?.imageInterpolation = .high
    img.draw(in: NSRect(x: (bounds.width - w) / 2, y: 0, width: w, height: h), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
  }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - badge

final class BadgeNode: NodeView {
  static let height: CGFloat = 20
  let icon = CardIconView()
  let label = makeLabel(size: 11, weight: .semibold)
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    wantsLayer = true
    layer?.cornerRadius = Self.height / 2
    layer?.cornerCurve = .continuous
    addSubview(icon)
    addSubview(label)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func update(_ v: Value) {
    super.update(v)
    label.stringValue = v.str("text")
    icon.spec = v.str("icon")
    icon.isHidden = icon.spec.isEmpty
    apply(r.palette)
    needsLayout = true
  }
  override func apply(_ p: Palette) {
    let c = CardTone.color(node.str("tone"), p, fallback: "secondary")
    layer?.backgroundColor = c.withAlphaComponent(p.dark ? 0.2 : 0.12).cgColor
    label.textColor = c
    icon.tint = c
  }
  var width: CGFloat { naturalWidth(label) + (icon.isHidden ? 18 : 32) }
  override var preferredWidth: CGFloat? { width }
  override var fitWidth: CGFloat? { width }
  override func height(for w: CGFloat) -> CGFloat { label.stringValue.isEmpty ? 0 : Self.height }
  override func layout() {
    var x: CGFloat = 9
    if !icon.isHidden { icon.frame = NSRect(x: 8, y: (bounds.height - 12) / 2, width: 12, height: 12); x = 24 }
    label.frame = NSRect(x: x, y: (bounds.height - 15) / 2, width: max(0, bounds.width - x - 7), height: 15)
  }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - meter

/// A fully rounded capsule: segments left to right in the tree's order, each proportional to its
/// value, over the track (spec §3.2's CI bar: passed → pending → failed → not started).
final class MeterNode: NodeView {
  override func update(_ v: Value) {
    super.update(v)
    needsDisplay = true
  }
  var barHeight: CGFloat { CGFloat(node.num("height", 6)) }
  override func height(for w: CGFloat) -> CGFloat { node.list("segments").isEmpty && node["total"].isNull ? 0 : barHeight }
  override func draw(_ dirtyRect: NSRect) {
    let p = palette
    let r = bounds.height / 2
    let track = NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r)
    p.tokens.card.track.ns.setFill()
    track.fill()
    let segs = node.list("segments")
    let sum = segs.reduce(0.0) { $0 + max(0, $1.num("value")) }
    let total = max(node.num("total", sum), sum)
    guard total > 0 else { return }
    NSGraphicsContext.saveGraphicsState()
    track.addClip()
    var x: CGFloat = 0
    for s in segs {
      let w = bounds.width * CGFloat(max(0, s.num("value")) / total)
      guard w > 0 else { continue }
      CardTone.color(s.str("tone"), p).setFill()
      NSRect(x: x, y: 0, width: w, height: bounds.height).fill()
      x += w
    }
    NSGraphicsContext.restoreGraphicsState()
  }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - note

/// A tinted row with a 3 pt leading bar (spec §3.2's failing-check rows). Clickable with an `id`.
final class NoteNode: NodeView {
  let label = makeLabel(size: 12, weight: .medium)
  var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    addSubview(label)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func update(_ v: Value) {
    super.update(v)
    label.stringValue = v.str("text")
    apply(r.palette)
  }
  override func apply(_ p: Palette) {
    // Only the bar carries a non-danger tone: tinted text on a tinted fill wouldn't stay readable.
    label.textColor = node.str("tone", "danger") == "danger" ? p.tokens.card.onDangerSoft.ns : p.tokens.card.text.ns
    needsDisplay = true
  }
  override func height(for w: CGFloat) -> CGFloat { label.stringValue.isEmpty ? 0 : CGFloat(node.num("height", 22)) }
  override func layout() { label.frame = NSRect(x: 11, y: (bounds.height - 16) / 2, width: max(0, bounds.width - 17), height: 16) }
  override func draw(_ dirtyRect: NSRect) {
    let p = palette
    let danger = node.str("tone", "danger") == "danger"
    let accent = danger ? p.tokens.card.danger.ns : CardTone.color(node.str("tone"), p)
    var fill = danger ? p.tokens.card.dangerSoft.ns : accent.withAlphaComponent(p.dark ? 0.18 : 0.12)
    if hovering, !nodeId.isEmpty { fill = fill.blended(withFraction: 0.06, of: p.dark ? .white : .black) ?? fill }
    let path = NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5)
    fill.setFill()
    path.fill()
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    accent.setFill()
    NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
    NSGraphicsContext.restoreGraphicsState()
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
    guard !nodeId.isEmpty, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
    emit("click", node["value"])
  }
}

// MARK: - item

/// A row: optional icon, title, subtitle, trailing accessory. Clickable when it has an `id` and
/// `clickable` isn't false.
final class ItemNode: NodeView {
  let icon = CardIconView()
  let title = makeLabel(size: 12.5, weight: .medium)
  let subtitle = makeLabel(size: 11)
  let accessory = makeLabel(size: 11, weight: .medium)
  var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    [icon, title, subtitle, accessory].forEach { addSubview($0) }
  }
  required init?(coder: NSCoder) { fatalError() }
  var clickable: Bool { !nodeId.isEmpty && node.flag("clickable", true) }
  override func update(_ v: Value) {
    super.update(v)
    title.stringValue = v.str("title")
    subtitle.stringValue = v.str("subtitle")
    subtitle.isHidden = subtitle.stringValue.isEmpty
    accessory.stringValue = v.str("accessory")
    accessory.isHidden = accessory.stringValue.isEmpty
    icon.spec = v.str("icon")
    icon.isHidden = icon.spec.isEmpty
    icon.fallbackLetter = v.str("title")
    apply(r.palette)
    needsLayout = true
  }
  override func apply(_ p: Palette) {
    title.textColor = p.tokens.card.text.ns
    subtitle.textColor = p.tokens.card.secondary.ns
    let tone = node.str("tone")
    accessory.textColor = tone.isEmpty ? p.tokens.card.secondary.ns : CardTone.color(tone, p)
    icon.tint = tone.isEmpty ? p.tokens.card.glyph.ns : CardTone.color(tone, p)
    needsDisplay = true
  }
  override func height(for w: CGFloat) -> CGFloat { subtitle.isHidden ? 28 : 40 }
  override var fitWidth: CGFloat? {
    (icon.isHidden ? 12 : 34) + max(naturalWidth(title), subtitle.isHidden ? 0 : naturalWidth(subtitle)) + (accessory.isHidden ? 0 : naturalWidth(accessory) + 8)
  }
  override func layout() {
    let h = bounds.height
    var x: CGFloat = 6
    if !icon.isHidden {
      icon.frame = NSRect(x: x, y: subtitle.isHidden ? (h - 14) / 2 : 6, width: 14, height: 14)
      x += 22
    }
    let aw = accessory.isHidden ? 0 : min(naturalWidth(accessory), 150)
    let tw = max(0, bounds.width - x - 6 - (aw > 0 ? aw + 8 : 0))
    if subtitle.isHidden {
      title.frame = NSRect(x: x, y: (h - 16) / 2, width: tw, height: 16)
    } else {
      title.frame = NSRect(x: x, y: 4, width: tw, height: 16)
      subtitle.frame = NSRect(x: x, y: 21, width: max(0, bounds.width - x - 6), height: 14)
    }
    accessory.frame = NSRect(x: bounds.width - 6 - aw, y: subtitle.isHidden ? (h - 15) / 2 : 5, width: aw, height: 15)
  }
  override func draw(_ dirtyRect: NSRect) {
    guard hovering && clickable else { return }
    palette.tokens.card.hover.ns.setFill()
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
    guard clickable, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
    emit("click", node["value"])
  }
}

// MARK: - action

/// A button. `icon` variant: Dia's card action (34 pt tall, a hover fill inset 1 pt, a line glyph
/// that brightens on hover). `pill` variant: a filled button with a title. The tooltip shows the
/// action's `shortcut` ("Pin Tab  ⌘D"); while a card shows, that shortcut presses this button.
final class ActionNode: NodeView {
  let icon = CardIconView()
  let label = makeLabel(size: 13, weight: .semibold)
  var hovering = false { didSet { if hovering != oldValue { apply(r.palette) } } }
  var pressedDown = false { didSet { if pressedDown != oldValue { needsDisplay = true } } }
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    addSubview(icon)
    addSubview(label)
    label.alignment = .center
  }
  required init?(coder: NSCoder) { fatalError() }

  var pill: Bool { node.str("variant", "icon") == "pill" }
  var enabled: Bool { node.flag("enabled", true) }
  /// The chord shown and pressed: `shortcutFor` (a menu bar item id or event) read from the menu
  /// bar, so a `[shortcuts]` remap applies to the card too; else `shortcut`.
  var shortcut: String { Shortcuts.chord(for: node.str("shortcutFor")) ?? node.str("shortcut") }
  var tooltipText: String {
    let t = node.str("tooltip")
    guard !shortcut.isEmpty else { return t }
    return t.isEmpty ? ShortcutRecorder.display(shortcut) : t + "  " + ShortcutRecorder.display(shortcut)
  }

  override func update(_ v: Value) {
    super.update(v)
    icon.spec = v.str("icon")
    icon.isHidden = icon.spec.isEmpty
    label.stringValue = v.str("title")
    label.isHidden = label.stringValue.isEmpty
    // Accessibility: the tooltip's words name the button (no native tooltip is shown).
    setAccessibilityRole(.button)
    setAccessibilityLabel(v.str("tooltip", v.str("title")))
    apply(r.palette)
    needsLayout = true
  }

  var fillColor: NSColor {
    let c = palette.tokens.card
    switch node.str("tone") {
    case "strong": return c.strong.ns
    case "destructive": return c.destructive.ns
    case "primary": return palette.primaryButton
    default: return pill ? c.hover.ns : .clear
    }
  }
  var textColor: NSColor {
    let c = palette.tokens.card
    switch node.str("tone") {
    case "strong": return c.onStrong.ns
    case "destructive": return c.onDestructive.ns
    case "primary": return palette.onAccent
    default: return pill || hovering ? c.text.ns : c.glyph.ns
    }
  }

  override func apply(_ p: Palette) {
    label.textColor = textColor
    icon.tint = textColor
    alphaValue = enabled ? 1 : 0.35
    needsDisplay = true
  }

  var buttonHeight: CGFloat { CGFloat(node.num("height", pill ? 32 : 34)) }
  override func height(for w: CGFloat) -> CGFloat { buttonHeight }
  override var fitWidth: CGFloat? {
    if pill { return (label.isHidden ? 0 : naturalWidth(label)) + (icon.isHidden ? 0 : 20) + 24 }
    return CGFloat(node.num("minWidth", 30))
  }
  override var preferredWidth: CGFloat? { node["width"].double.map { CGFloat($0) } }

  override func layout() {
    let size: CGFloat = pill ? 14 : CGFloat(node.num("iconSize", 15))
    let lw = label.isHidden ? 0 : min(naturalWidth(label), bounds.width - 16)
    let total = lw + (icon.isHidden ? 0 : size + (lw > 0 ? 6 : 0))
    var x = ((bounds.width - total) / 2).rounded()
    if !icon.isHidden {
      icon.frame = NSRect(x: x, y: ((bounds.height - size) / 2).rounded(), width: size, height: size)
      x += size + 6
    }
    label.frame = NSRect(x: x, y: ((bounds.height - 17) / 2).rounded(), width: lw, height: 17)
  }

  override func draw(_ dirtyRect: NSRect) {
    let r = bounds.insetBy(dx: pill ? 0 : 1, dy: pill ? 0 : 1)
    var fill = fillColor
    if pill {
      if hovering && enabled { fill = fill.blended(withFraction: 0.1, of: palette.dark && node.str("tone") != "strong" ? .white : .black) ?? fill }
    } else if (hovering || pressedDown) && enabled {
      fill = palette.tokens.card.hover.ns
    }
    guard fill.alphaComponent > 0 else { return }
    fill.setFill()
    NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }
  override func mouseEntered(with event: NSEvent) {
    hovering = true
    let text = tooltipText
    if !text.isEmpty, let cards = r.hover, let overlays = cards.overlays { cards.tooltips.show(text, below: self, in: overlays, palette: palette) }
  }
  override func mouseExited(with event: NSEvent) {
    hovering = false
    r.hover?.tooltips.hide(for: self)
  }
  override func mouseDown(with event: NSEvent) { if enabled { pressedDown = true } }
  override func mouseUp(with event: NSEvent) {
    pressedDown = false
    guard enabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
    activate()
  }

  /// Click, or the card shortcut: a `menu` pops up under the button; otherwise `click`.
  func activate() {
    guard enabled else { return }
    r.hover?.tooltips.hide()
    let items = node.list("menu")
    if !items.isEmpty {
      let m = ContextMenu.build(items, target: self, action: #selector(menuPicked(_:)))
      m.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 2), in: self)
      return
    }
    emit(node.str("action", "click"), node["value"])
  }

  // A button's `menu` opens on click; no second copy on right-click.
  override func menu(for event: NSEvent) -> NSMenu? { nil }
}
