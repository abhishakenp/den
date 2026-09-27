import AppKit
import CordisValue

/// A small space-icon picker for the `popover` slot (the space menu's "Change Space Icon…").
///
/// {type:"iconPicker", id, anchor?, title?, selected?}
/// actions (id = picker id):
///   pick {icon}        a symbol (`sf:<name>`), an emoji, or "" (Remove: the footer shows a dot)
///   dismiss {reason?}  Esc ({reason: "escape"}) or a click outside (no value)
///
/// Arc's icon editor was never measured (spec §12 lists it nowhere), so this is den's own layout:
/// a 300 pt panel with the theme picker's 20 pt continuous radius, a field that takes any emoji
/// (typed, pasted or from the Character Viewer), then a grid of symbols and a grid of emoji.
final class IconPickerNode: NodeView, NSTextFieldDelegate {
  static let symbols = [
    "house.fill", "briefcase.fill", "hammer.fill", "book.fill", "graduationcap.fill", "heart.fill", "star.fill", "bolt.fill",
    "flame.fill", "leaf.fill", "globe.americas.fill", "airplane", "cart.fill", "gamecontroller.fill", "music.note", "film.fill",
    "camera.fill", "paintbrush.pointed.fill", "chevron.left.forwardslash.chevron.right", "terminal.fill", "sparkles", "moon.fill",
    "sun.max.fill", "cup.and.saucer.fill", "dumbbell.fill", "pawprint.fill", "building.2.fill", "person.2.fill", "newspaper.fill",
    "flask.fill", "lightbulb.fill", "tray.full.fill",
  ]
  static let emoji = [
    "🏠", "💼", "🛠️", "📚", "🎓", "❤️", "⭐️", "⚡️", "🔥", "🌿", "🌍", "✈️", "🛒", "🎮", "🎵", "🎬",
    "📷", "🎨", "💻", "🧪", "💡", "🌙", "☀️", "☕️", "🏋️", "🐾", "🏢", "👥", "📰", "🚀", "🍕", "🎯",
  ]

  private let title = makeLabel("Space Icon", size: 13, weight: .semibold)
  private lazy var remove = PillLink(title: "Remove") { [weak self] in self?.emit("pick", ["icon": ""]) }
  private let field = NSTextField()
  private let symbolsLabel = makeLabel("Symbols", size: 11, weight: .medium)
  private let emojiLabel = makeLabel("Emoji", size: 11, weight: .medium)
  private var cells: [IconCell] = []

  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    field.placeholderString = "Type or paste an emoji"
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = .systemFont(ofSize: 13)
    field.usesSingleLineMode = true
    field.cell?.isScrollable = true
    field.delegate = self
    field.wantsLayer = true
    for v in [title, remove, field, symbolsLabel, emojiLabel] as [NSView] { addSubview(v) }
    for s in Self.symbols { cells.append(IconCell(spec: "sf:" + s) { [weak self] in self?.emit("pick", ["icon": .string("sf:" + s)]) }) }
    for e in Self.emoji { cells.append(IconCell(spec: e) { [weak self] in self?.emit("pick", ["icon": .string(e)]) }) }
    cells.forEach { addSubview($0) }
  }
  required init?(coder: NSCoder) { fatalError() }

  override var acceptsFirstResponder: Bool { true }
  override var preferredWidth: CGFloat? { Tokens.iconPickerWidth }

  override func update(_ v: Value) {
    super.update(v)
    title.stringValue = v.str("title", "Space Icon")
    let sel = v.str("selected")
    for c in cells { c.selected = c.spec == sel }
    remove.isHidden = sel.isEmpty
  }

  private var rows: Int { (Self.symbols.count + Tokens.iconPickerColumns - 1) / Tokens.iconPickerColumns }
  private var gridHeight: CGFloat { CGFloat(rows) * Tokens.iconPickerCell + CGFloat(rows - 1) * 2 }
  override func height(for w: CGFloat) -> CGFloat {
    let p = Tokens.iconPickerPadding
    return p + 22 + 10 + 32 + 14 + 18 + gridHeight + 12 + 18 + gridHeight + p
  }

  override func layout() {
    super.layout()
    let p = Tokens.iconPickerPadding, w = Tokens.iconPickerWidth  // fixed width: never lay out against a zero-size frame
    var y = p
    title.frame = NSRect(x: p, y: y + 2, width: 160, height: 18)
    let rw = remove.preferredWidth
    remove.frame = NSRect(x: w - p - rw, y: y, width: rw, height: 22)
    y += 22 + 10
    field.frame = NSRect(x: p + 10, y: y + 7, width: w - 2 * p - 20, height: 18)
    fieldRect = NSRect(x: p, y: y, width: w - 2 * p, height: 32)
    y += 32 + 14
    let gap: CGFloat = 2, cols = Tokens.iconPickerColumns, s = Tokens.iconPickerCell
    let gridW = CGFloat(cols) * s + CGFloat(cols - 1) * gap
    let x0 = ((w - gridW) / 2).rounded()
    func grid(_ label: NSTextField, _ range: Range<Int>) {
      label.frame = NSRect(x: x0 + 2, y: y, width: 200, height: 14)
      y += 18
      for (k, i) in range.enumerated() {
        cells[i].frame = NSRect(x: x0 + CGFloat(k % cols) * (s + gap), y: y + CGFloat(k / cols) * (s + gap), width: s, height: s)
      }
      y += gridHeight
    }
    grid(symbolsLabel, 0..<Self.symbols.count)
    y += 12
    grid(emojiLabel, Self.symbols.count..<cells.count)
  }
  private var fieldRect = NSRect.zero

  override func apply(_ p: Palette) {
    title.textColor = p.panelText
    field.textColor = p.panelText
    field.placeholderAttributedString = NSAttributedString(string: "Type or paste an emoji", attributes: [.foregroundColor: p.panelSecondaryText, .font: NSFont.systemFont(ofSize: 13)])
    symbolsLabel.textColor = p.panelSecondaryText
    emojiLabel.textColor = p.panelSecondaryText
    remove.apply(p)
    cells.forEach { $0.apply(p) }
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    // The emoji field sits in a pill like the URL pill (SidebarItemBackground, spec §3).
    (r.palette.dark ? Palette.snow(0.08) : Palette.ink(0.05)).setFill()
    NSBezierPath(roundedRect: fieldRect, xRadius: 9, yRadius: 9).fill()
  }

  func controlTextDidChange(_ obj: Notification) {
    // Any single emoji (or other glyph) typed or pasted becomes the icon at once.
    guard let first = field.stringValue.trimmingCharacters(in: .whitespaces).first else { return }
    field.stringValue = ""
    emit("pick", ["icon": .string(String(first))])
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
    if sel == #selector(NSResponder.cancelOperation(_:)) { emit("dismiss", ["reason": "escape"]); return true }
    return false
  }
  override func cancelOperation(_ sender: Any?) { emit("dismiss", ["reason": "escape"]) }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 { emit("dismiss", ["reason": "escape"]) } else { super.keyDown(with: event) }
  }
}

/// One cell of the icon grid: an SF Symbol or an emoji, with hover and selected fills.
@MainActor
final class IconCell: NSView, Themable, Hoverable {
  var hoverGroup: HoverGroup { .row }
  let spec: String
  let icon = IconView()
  let action: () -> Void
  var selected = false { didSet { needsDisplay = true } }
  var hovering = false { didSet { needsDisplay = true } }
  private var palette: Palette?

  init(spec: String, action: @escaping () -> Void) {
    self.spec = spec
    self.action = action
    super.init(frame: .zero)
    icon.spec = spec
    addSubview(icon)
    toolTip = spec.hasPrefix("sf:") ? String(spec.dropFirst(3)) : nil
  }
  required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  func apply(_ p: Palette) { palette = p; icon.tint = p.panelText; needsDisplay = true }
  override func layout() {
    super.layout()
    let s: CGFloat = spec.hasPrefix("sf:") ? 18 : 20
    icon.frame = NSRect(x: (bounds.width - s) / 2, y: (bounds.height - s) / 2, width: s, height: s)
  }
  override func draw(_ dirtyRect: NSRect) {
    guard let p = palette, selected || hovering else { return }
    (selected ? p.accentStrong.withAlphaComponent(p.dark ? 0.55 : 0.25) : p.rowHover.withAlphaComponent(p.dark ? 0.1 : 0.07)).setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
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
    if bounds.contains(convert(event.locationInWindow, from: nil)) {
      NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
      action()
    }
  }
}

/// A small text button ("Remove") with a hover fill.
@MainActor
final class PillLink: NSView, Themable, Hoverable {
  var hoverGroup: HoverGroup { .control }
  let label: NSTextField
  let action: () -> Void
  var hovering = false { didSet { needsDisplay = true } }
  private var fill = NSColor.clear
  init(title: String, action: @escaping () -> Void) {
    label = makeLabel(title, size: 12, weight: .medium)
    self.action = action
    super.init(frame: .zero)
    addSubview(label)
  }
  required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  var preferredWidth: CGFloat { label.textWidth + 16 }
  func apply(_ p: Palette) { label.textColor = p.panelSecondaryText; fill = p.rowHover.withAlphaComponent(p.dark ? 0.1 : 0.07); needsDisplay = true }
  override func layout() { label.frame = NSRect(x: 8, y: (bounds.height - 16) / 2, width: bounds.width - 16, height: 16) }
  override func draw(_ dirtyRect: NSRect) {
    guard hovering else { return }
    fill.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }
  override func mouseEntered(with event: NSEvent) { HoverTracker.refresh(window) }
  override func mouseExited(with event: NSEvent) { HoverTracker.refresh(window) }
  override func mouseDown(with event: NSEvent) {}
  override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { action() } }
}
