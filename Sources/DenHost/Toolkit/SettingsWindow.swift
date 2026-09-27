import AppKit
import CordisValue

/// den's Settings window (⌘,): a native AppKit window, built the first time it opens.
///
/// A sidebar of sections on a tint of the current space's accent (Arc's sidebar, flattened), and a
/// pane of grouped cards: caption, rounded card, one row per control with hairlines between them,
/// native controls on the right. Arc's own Settings window was never measured (spec §11 only has its
/// copy), so sizes are den's (`SettingsMetrics`).
@MainActor
public final class SettingsWindowController: NSObject, NSWindowDelegate {
  unowned let service: SettingsService
  public let window: NSWindow
  let root = FlippedView()
  let sidebar = SettingsSidebar()
  let scroll = NSScrollView()
  let pane = SettingsPane()
  public private(set) var section = ""

  init(service: SettingsService) {
    self.service = service
    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsMetrics.windowSize.width, height: SettingsMetrics.windowSize.height),
                      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
    super.init()
    window.title = "Settings"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isReleasedWhenClosed = false
    window.minSize = SettingsMetrics.minSize
    window.tabbingMode = .disallowed
    window.collectionBehavior.insert(.fullScreenNone)
    window.delegate = self
    window.contentView = root
    root.addSubview(sidebar)
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder
    scroll.documentView = pane
    root.addSubview(scroll)
    sidebar.onSelect = { [weak self] id in self?.select(id) }
    pane.service = service
    root.postsFrameChangedNotifications = true
    NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: root, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.layout() }
    }
    window.center()
    window.setFrameAutosaveName("den.settings")
  }

  var dark: Bool { service.dark() }

  func show(section id: String?) {
    applyAppearance()
    reload()
    if let id, service.sections.contains(where: { $0.id == id }) { select(id) } else if section.isEmpty || !service.sections.contains(where: { $0.id == section }) {
      select(service.sections.first?.id ?? "")
    }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()
  }

  func applyAppearance() {
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let p = SettingsPalette(service.palette())
    window.backgroundColor = p.content
    sidebar.palette = p
    pane.palette = p
  }

  /// Registrations changed: rebuild the sidebar, and the pane if its section changed.
  func reload() {
    sidebar.set(service.sections.map { ($0.id, $0.title, $0.icon) }, selected: section)
    if window.isVisible || !section.isEmpty { pane.show(section: section, keepScroll: true) }
    layout()
  }

  func select(_ id: String) {
    guard id != section || pane.subviews.isEmpty else { return }
    section = id
    sidebar.selected = id
    pane.show(section: id, keepScroll: false)
    scroll.contentView.scroll(to: .zero)
    layout()
  }

  func valueChanged(_ id: String, _ key: String) { pane.refresh(id, key) }

  func layout() {
    let b = root.bounds, w = SettingsMetrics.sidebarWidth
    sidebar.frame = NSRect(x: 0, y: 0, width: w, height: b.height)
    scroll.frame = NSRect(x: w, y: 0, width: b.width - w, height: b.height)
    pane.width = scroll.contentSize.width
    pane.layoutRows()
  }

  public func windowDidChangeEffectiveAppearance() {}
  public func windowDidBecomeKey(_ notification: Notification) { applyAppearance() }
}

enum SettingsMetrics {
  static let windowSize = CGSize(width: 740, height: 540)  // den's own
  static let minSize = CGSize(width: 620, height: 420)
  static let sidebarWidth: CGFloat = 196
  static let titlebar: CGFloat = 52  // traffic lights zone
  static let sidebarRow: CGFloat = 32
  static let sidebarInset: CGFloat = 10
  static let paneInsetX: CGFloat = 28
  static let paneTop: CGFloat = 46
  static let cardRadius: CGFloat = 12
  static let rowMinHeight: CGFloat = 44
  static let rowPadX: CGFloat = 14
  static let groupGap: CGFloat = 22
  static let captionGap: CGFloat = 7
}

/// Colors for the Settings window, from the theme tokens (docs/host-api.md "Theming"): the pane
/// is the themed surface, the sidebar the space's background tint (Arc's sidebar, flattened), the
/// selected section TabCellBackgroundCurrent (spec §3), like a selected tab.
@MainActor
struct SettingsPalette {
  let tokens: ThemeTokens
  init(_ p: Palette) { tokens = p.tokens }
  init() { tokens = ThemeTokens.make(theme: Theme(), dark: false) }
  var dark: Bool { tokens.dark }
  var accent: NSColor { tokens.accent.ns }
  var content: NSColor { tokens.surface.ns }
  /// The space's gradient average, eased toward the surface so the sidebar stays calm.
  var sidebarRGB: RGB { tokens.background.mix(tokens.surface, 0.35) }
  var sidebar: NSColor { sidebarRGB.ns }
  var text: NSColor { tokens.textPrimary.ns }
  var secondary: NSColor { tokens.textSecondary.ns }
  var sidebarText: NSColor { ThemeTokens.ensure(tokens.textPrimary, on: sidebarRGB, ThemeTokens.bodyContrast).ns }
  var sidebarSecondary: NSColor { ThemeTokens.ensure(tokens.textSecondary, on: sidebarRGB, ThemeTokens.uiContrast).ns }
  var card: NSColor { dark ? tokens.elevated.ns : tokens.surface.mix(RGB(0, 0, 0), 0.035).ns }
  var cardBorder: NSColor { tokens.hairline.ns.withAlphaComponent(tokens.hairline.a * 0.7) }
  var hairline: NSColor { tokens.hairline.ns }
  var selected: NSColor { dark ? Palette.snow(0.14) : NSColor(white: 1, alpha: 0.85) }  // TabCellBackgroundCurrent
  var hover: NSColor { dark ? Palette.snow(0.07) : NSColor(white: 1, alpha: 0.45) }
  var destructive: NSColor { tokens.destructive.ns }
}

// MARK: - Sidebar

@MainActor
final class SettingsSidebar: FlippedView {
  var palette = SettingsPalette() { didSet { needsDisplay = true; rows.forEach { $0.palette = palette } } }
  var onSelect: ((String) -> Void)?
  private var rows: [SettingsSidebarRow] = []
  var selected = "" { didSet { rows.forEach { $0.selected = $0.id == selected } } }

  override var mouseDownCanMoveWindow: Bool { true }

  func set(_ items: [(String, String, String)], selected: String) {
    if rows.map(\.id) != items.map(\.0) || zip(rows, items).contains(where: { $0.label.stringValue != $1.1 || $0.icon.spec != $1.2 }) {
      rows.forEach { $0.removeFromSuperview() }
      rows = items.map { id, title, icon in
        let r = SettingsSidebarRow(id: id, title: title, icon: icon)
        r.onClick = { [weak self] in self?.onSelect?(id) }
        r.palette = palette
        addSubview(r)
        return r
      }
    }
    self.selected = selected
    needsLayout = true
  }

  override func layout() {
    super.layout()
    var y = SettingsMetrics.titlebar
    for r in rows {
      r.frame = NSRect(x: SettingsMetrics.sidebarInset, y: y, width: bounds.width - 2 * SettingsMetrics.sidebarInset, height: SettingsMetrics.sidebarRow)
      y += SettingsMetrics.sidebarRow + 2
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    palette.sidebar.setFill()
    bounds.fill()
    palette.hairline.setFill()
    NSRect(x: bounds.maxX - 0.5, y: 0, width: 0.5, height: bounds.height).fill()
  }
}

@MainActor
final class SettingsSidebarRow: FlippedView {
  let id: String
  let icon = IconView()
  let label: NSTextField
  var onClick: (() -> Void)?
  var palette = SettingsPalette() { didSet { apply() } }
  var selected = false { didSet { apply() } }
  private var hovering = false { didSet { needsDisplay = true } }

  init(id: String, title: String, icon spec: String) {
    self.id = id
    label = makeLabel(title, size: 13, weight: .medium)
    super.init(frame: .zero)
    icon.spec = spec
    addSubview(icon)
    addSubview(label)
    setAccessibilityRole(.button)
    setAccessibilityLabel(title)
  }
  required init?(coder: NSCoder) { fatalError() }
  override var mouseDownCanMoveWindow: Bool { false }

  func apply() {
    label.textColor = palette.sidebarText
    icon.tint = selected ? palette.sidebarText : palette.sidebarSecondary
    needsDisplay = true
  }
  override func layout() {
    super.layout()
    icon.frame = NSRect(x: 9, y: (bounds.height - 16) / 2, width: 16, height: 16)
    label.frame = NSRect(x: 34, y: (bounds.height - 17) / 2, width: bounds.width - 40, height: 17)
  }
  override func draw(_ dirtyRect: NSRect) {
    guard selected || hovering else { return }
    let path = NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9)
    if selected {
      NSGraphicsContext.saveGraphicsState()
      if !palette.dark {  // TabCellShadowSelected (spec §3)
        let s = NSShadow()
        s.shadowColor = NSColor(white: 0, alpha: 0.12)
        s.shadowBlurRadius = 2
        s.shadowOffset = NSSize(width: 0, height: -0.5)
        s.set()
      }
      palette.selected.setFill()
      path.fill()
      NSGraphicsContext.restoreGraphicsState()
    } else {
      palette.hover.setFill()
      path.fill()
    }
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }
  override func mouseEntered(with event: NSEvent) { hovering = true }
  override func mouseExited(with event: NSEvent) { hovering = false }
  override func mouseDown(with event: NSEvent) { onClick?() }
}

// MARK: - Pane

/// The right side: the section title, then one card per group.
@MainActor
final class SettingsPane: FlippedView {
  weak var service: SettingsService?
  var palette = SettingsPalette() { didSet { applyPalette() } }
  var width: CGFloat = 500
  private(set) var section = ""
  private let title = makeLabel("", size: 20, weight: .semibold)
  private(set) var groups: [SettingsGroupView] = []

  override init(frame: NSRect) {
    super.init(frame: frame)
    addSubview(title)
  }
  required init?(coder: NSCoder) { fatalError() }

  func show(section id: String, keepScroll: Bool) {
    guard let service else { return }
    section = id
    let gs = service.groups(of: id)
    title.stringValue = gs.first?.title ?? ""
    groups.forEach { $0.removeFromSuperview() }
    groups = gs.enumerated().map { i, e in
      let g = SettingsGroupView(entry: e, caption: i == 0 ? nil : e.title, service: service)
      addSubview(g)
      return g
    }
    applyPalette()
    layoutRows()
  }

  func refresh(_ id: String, _ key: String) { groups.first { $0.entry.id == id }?.refresh(key) }

  func applyPalette() {
    title.textColor = palette.text
    groups.forEach { $0.palette = palette }
  }

  func layoutRows() {
    let x = SettingsMetrics.paneInsetX, w = max(300, width - 2 * x)
    var y = SettingsMetrics.paneTop
    title.frame = NSRect(x: x, y: y, width: w, height: 26)
    y += 26 + 16
    for g in groups {
      let h = g.height(for: w)
      g.frame = NSRect(x: x, y: y, width: w, height: h)
      g.layoutRows()
      y += h + SettingsMetrics.groupGap
    }
    setFrameSize(NSSize(width: width, height: max(y + 10, superview?.bounds.height ?? 0)))
  }
}

/// One group: an optional caption above a rounded card of rows.
@MainActor
final class SettingsGroupView: FlippedView {
  let entry: SettingsService.Entry
  let caption: NSTextField?
  let card = SettingsCard()
  private(set) var rows: [SettingsRow] = []
  var palette = SettingsPalette() {
    didSet {
      caption?.textColor = palette.secondary
      card.palette = palette
      rows.forEach { $0.palette = palette }
    }
  }

  init(entry: SettingsService.Entry, caption: String?, service: SettingsService) {
    self.entry = entry
    self.caption = caption.map { makeLabel($0, size: 12, weight: .semibold) }
    super.init(frame: .zero)
    if let c = self.caption { addSubview(c) }
    addSubview(card)
    rows = entry.controls.flatMap { SettingsRow.rows(for: $0, owner: entry.id, service: service) }
    rows.forEach { card.addSubview($0) }
  }
  required init?(coder: NSCoder) { fatalError() }

  var captionHeight: CGFloat { caption == nil ? 0 : 16 + SettingsMetrics.captionGap }
  func height(for w: CGFloat) -> CGFloat { captionHeight + rows.reduce(0) { $0 + $1.height(for: w) } }

  func layoutRows() {
    caption?.frame = NSRect(x: 4, y: 0, width: bounds.width - 8, height: 16)
    card.frame = NSRect(x: 0, y: captionHeight, width: bounds.width, height: bounds.height - captionHeight)
    var y: CGFloat = 0
    card.dividers = []
    for (i, r) in rows.enumerated() {
      let h = r.height(for: bounds.width)
      r.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
      r.layoutControls()
      y += h
      if i < rows.count - 1 { card.dividers.append(y) }
    }
    card.needsDisplay = true
  }

  func refresh(_ key: String) {
    for r in rows where r.key == key { if case .control = r.kind { r.refresh() } }
  }
}

@MainActor
final class SettingsCard: FlippedView {
  var palette = SettingsPalette() { didSet { needsDisplay = true } }
  var dividers: [CGFloat] = []
  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: SettingsMetrics.cardRadius, yRadius: SettingsMetrics.cardRadius)
    palette.card.setFill()
    path.fill()
    palette.cardBorder.setStroke()
    path.lineWidth = 0.5
    path.stroke()
    palette.hairline.setFill()
    for y in dividers { NSRect(x: SettingsMetrics.rowPadX, y: y - 0.25, width: bounds.width - 2 * SettingsMetrics.rowPadX, height: 0.5).fill() }
  }
}
