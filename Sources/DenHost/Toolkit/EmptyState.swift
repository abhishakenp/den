import AppKit

/// An empty space's card (Arc spec, "Empty Space content": keycap art 62x46, a title and one
/// line). The keycap reads New Tab's chord from the menu bar, so a `[shortcuts]` remap shows.
/// System label colours follow the card's appearance; it takes no clicks.
@MainActor
final class EmptyStateView: NSView {
  let keycap = Keycap()
  let title = makeLabel("Open a tab.", size: 15, weight: .semibold)
  let body = makeLabel("", size: 13)
  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    keycap.font = .systemFont(ofSize: 20, weight: .medium)
    keycap.radius = 10
    title.alignment = .center
    body.alignment = .center
    body.lineBreakMode = .byWordWrapping
    body.maximumNumberOfLines = 2
    body.cell?.truncatesLastVisibleLine = true
    [keycap, title, body].forEach { addSubview($0) }
    refresh()
  }
  required init?(coder: NSCoder) { fatalError() }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func refresh() {
    let k = Shortcuts.glyphs(for: "file.newTab", fallback: "cmd+t")
    keycap.text = k
    body.stringValue = "Press \(k) to search or type an address, or click New Tab in the sidebar."
    updateColors()
    needsLayout = true
  }

  override func viewDidChangeEffectiveAppearance() { updateColors() }
  func updateColors() {
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    title.textColor = .labelColor
    body.textColor = .secondaryLabelColor
    keycap.fg = .secondaryLabelColor
    keycap.fill = NSColor(white: dark ? 1 : 0, alpha: 0.05)
    keycap.border = NSColor(white: dark ? 1 : 0, alpha: 0.14)
    keycap.needsDisplay = true
  }

  override func layout() {
    super.layout()
    let kw = max(62, keycap.preferredWidth + 18), kh: CGFloat = 46
    let bw = max(0, min(320, bounds.width - 48))
    let bh = ceil(body.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: bw, height: 60)).height ?? 17)
    let total = kh + 16 + 20 + 6 + bh
    // Centred, a little above the middle.
    var y = ((bounds.height - total) / 2 - bounds.height * 0.05).rounded()
    keycap.frame = NSRect(x: ((bounds.width - kw) / 2).rounded(), y: y, width: kw, height: kh)
    y += kh + 16
    title.frame = NSRect(x: 24, y: y, width: max(0, bounds.width - 48), height: 20)
    y += 26
    body.frame = NSRect(x: ((bounds.width - bw) / 2).rounded(), y: y, width: bw, height: bh)
  }
}
