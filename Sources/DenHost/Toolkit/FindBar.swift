import AppKit

/// Find-in-page bar: a small floating pill at the top right of the content card (den's own design;
/// Arc's find bar was never measured). Magnifier, query field, "3 of 12", previous / next, close.
/// Return = next, Shift-Return = previous, Esc = close. Built on first use only.
@MainActor
final class FindBarView: FlippedView, NSTextFieldDelegate, Themable {
  let field = NSTextField()
  let count = makeLabel("", size: 12, weight: .medium)
  let glass = IconView()
  lazy var prev = IconButton(symbol: "chevron.up", size: 24) { [weak self] in self?.onStep?(false) }
  lazy var next = IconButton(symbol: "chevron.down", size: 24) { [weak self] in self?.onStep?(true) }
  lazy var close = IconButton(symbol: "xmark", size: 24) { [weak self] in self?.onClose?() }
  var onQuery: ((String) -> Void)?
  var onStep: ((Bool) -> Void)?
  var onClose: (() -> Void)?
  private var fill = NSColor.white
  private var border = NSColor.clear

  init() {
    super.init(frame: NSRect(x: 0, y: 0, width: Tokens.findBarWidth, height: Tokens.findBarHeight))
    wantsLayer = true
    layer?.cornerRadius = Tokens.findBarHeight / 2
    layer?.cornerCurve = .continuous
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowOpacity = 0.18  // estimate
    layer?.shadowRadius = 10
    layer?.shadowOffset = CGSize(width: 0, height: -3)
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = .systemFont(ofSize: 13)
    field.usesSingleLineMode = true
    field.cell?.isScrollable = true
    field.cell?.wraps = false
    field.placeholderString = "Find on page"
    field.delegate = self
    glass.spec = "sf:magnifyingglass"
    count.alignment = .right
    prev.toolTip = "Previous match (⇧⌘G)"
    next.toolTip = "Next match (⌘G)"
    close.toolTip = "Done (Esc)"
    [glass, field, count, prev, next, close].forEach { addSubview($0) }
  }
  required init?(coder: NSCoder) { fatalError() }
  override var mouseDownCanMoveWindow: Bool { false }

  func apply(_ p: Palette) {
    fill = p.panel
    border = p.divider  // every color comes from the palette, so a space/theme change re-themes it live
    layer?.backgroundColor = fill.cgColor
    layer?.borderWidth = 0.5
    layer?.borderColor = border.cgColor
    field.textColor = p.panelText
    field.placeholderAttributedString = NSAttributedString(string: "Find on page", attributes: [.foregroundColor: p.panelSecondaryText, .font: NSFont.systemFont(ofSize: 13)])
    count.textColor = p.panelSecondaryText
    glass.tint = p.panelSecondaryText
    for b in [prev, next, close] {
      b.apply(p)
      b.tint = p.panelText.withAlphaComponent(0.7)
      b.hoverFill = p.rowHover.withAlphaComponent(p.dark ? 0.12 : 0.08)
    }
  }

  func setCount(current: Int, total: Int, query: String) {
    count.stringValue = query.isEmpty ? "" : (total == 0 ? "No matches" : "\(current) of \(total)")
    prev.enabled = total > 0
    next.enabled = total > 0
    needsLayout = true
  }

  override func layout() {
    super.layout()
    let h = bounds.height, w = bounds.width
    glass.frame = NSRect(x: 12, y: (h - 14) / 2, width: 14, height: 14)
    var right = w - 6
    for b in [close, next, prev] {
      b.frame = NSRect(x: right - 24, y: (h - 24) / 2, width: 24, height: 24)
      right -= 26
    }
    let cw = count.stringValue.isEmpty ? 0 : ceil(count.textWidth) + 6  // the label cell's own insets
    count.frame = NSRect(x: right - cw - 4, y: (h - 16) / 2, width: cw, height: 16)
    let fx: CGFloat = 32
    field.frame = NSRect(x: fx, y: (h - 18) / 2, width: max(40, right - cw - 12 - fx), height: 18)
  }

  func focus() {
    window?.makeFirstResponder(field)
    field.currentEditor()?.selectAll(nil)
  }

  func controlTextDidChange(_ obj: Notification) { onQuery?(field.stringValue) }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
    switch sel {
    case #selector(NSResponder.insertNewline(_:)):
      onStep?(!(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      onClose?()
      return true
    default: return false
    }
  }
}
