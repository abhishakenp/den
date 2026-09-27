import AppKit
import CordisValue

/// Node with hover tracking, a rounded fill for hover/selected, and click/double-click.
class HoverNode: NodeView {
  var hovering = false {
    didSet { if hovering != oldValue { needsDisplay = true; hoverChanged() } }
  }
  var selected: Bool { node.flag("selected") }
  var cornerRadius: CGFloat { Tokens.tabRowCornerRadius }
  var fillRect: NSRect { bounds }
  var baseFill: NSColor? { nil }
  private var downPoint: NSPoint?
  private var dragging = false
  var draggable: Bool { false }

  func hoverChanged() {}

  override func update(_ v: Value) {
    let wasSel = node.flag("selected")
    super.update(v)
    if wasSel != v.flag("selected") { needsDisplay = true }
  }

  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(roundedRect: fillRect, xRadius: cornerRadius, yRadius: cornerRadius)
    if selected {
      NSGraphicsContext.saveGraphicsState()
      if !palette.dark {
        let sh = NSShadow()
        sh.shadowColor = NSColor(white: 0, alpha: 0.1)  // estimate
        sh.shadowBlurRadius = 2
        sh.shadowOffset = NSSize(width: 0, height: -0.5)
        sh.set()
      }
      palette.selectedFill.setFill()
      path.fill()
      NSGraphicsContext.restoreGraphicsState()
    } else if hovering {
      palette.hoverFill.setFill()
      path.fill()
    } else if let f = baseFill {
      f.setFill()
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

  override func mouseDown(with event: NSEvent) {
    downPoint = event.locationInWindow
    dragging = false
    if event.clickCount == 2 { emit("doubleClick") }
  }
  override func mouseDragged(with event: NSEvent) {
    guard draggable, let d = downPoint else { return }
    if !dragging, hypot(event.locationInWindow.x - d.x, event.locationInWindow.y - d.y) > 4 {
      dragging = true
      r.drag?.begin(self, event: event)
    } else if dragging {
      r.drag?.move(event)
    }
  }
  override func mouseUp(with event: NSEvent) {
    defer { downPoint = nil; dragging = false }
    if dragging { r.drag?.end(event); return }
    if event.clickCount == 1, bounds.contains(convert(event.locationInWindow, from: nil)) { clicked(at: convert(event.locationInWindow, from: nil), event: event) }
  }
  func clicked(at p: NSPoint, event: NSEvent) {
    var mods: [Value] = []
    if event.modifierFlags.contains(.command) { mods.append("cmd") }
    if event.modifierFlags.contains(.shift) { mods.append("shift") }
    if event.modifierFlags.contains(.option) { mods.append("opt") }
    emit("click", mods.isEmpty ? .null : ["modifiers": .array(mods)])
  }
  override func rightMouseDown(with event: NSEvent) {
    if node.list("menu").isEmpty { emit("contextMenu") } else { super.rightMouseDown(with: event) }
  }
}

// MARK: - Header

/// Row shared with the traffic lights: sidebar toggle, back, forward, reload/stop (right-aligned).
/// {type:"navBar", id, canGoBack, canGoForward, loading}
/// actions: toggleSidebar, back, forward, reload, stop
final class NavBarNode: NodeView {
  var buttons: [IconButton] = []
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    for (sym, act) in [("sidebar.left", "toggleSidebar"), ("arrow.left", "back"), ("arrow.right", "forward"), ("arrow.clockwise", "reload")] {
      let b = IconButton(symbol: sym, size: Tokens.navButtonSize) { [weak self] in
        guard let self else { return }
        self.emit(act == "reload" && self.node.flag("loading") ? "stop" : act)
      }
      buttons.append(b)
      addSubview(b)
    }
  }
  required init?(coder: NSCoder) { fatalError() }
  override func update(_ v: Value) {
    super.update(v)
    buttons[1].enabled = v.flag("canGoBack")
    buttons[2].enabled = v.flag("canGoForward")
    buttons[3].icon.spec = v.flag("loading") ? "sf:xmark" : "sf:arrow.clockwise"
  }
  override func apply(_ p: Palette) { buttons.forEach { $0.apply(p) } }
  override func height(for w: CGFloat) -> CGFloat { Tokens.navRowHeight }
  override var mouseDownCanMoveWindow: Bool { true }
  override func layout() {
    let s = Tokens.navButtonSize
    // Sidebar toggle sits right after the traffic lights; nav buttons are right-aligned.
    let y = Tokens.trafficLightCenterY - s / 2
    buttons[0].frame = NSRect(x: Tokens.trafficLightLeading + Tokens.trafficLightSpacing * 2 + 18 - Tokens.sidebarPadding, y: y, width: s, height: s)
    var x = bounds.width - s
    for b in buttons[1...].reversed() {
      b.frame = NSRect(x: x, y: y, width: s, height: s)
      x -= s + 2
    }
  }
}

/// Simplified URL pill. {type:"urlPill", id, text, progress?, loading?, secure?, placeholder?}
/// actions: click (open the command bar pre-filled), copy (hover button)
final class URLPillNode: HoverNode {
  let label = makeLabel(size: Tokens.urlPillFontSize, weight: .medium)
  let lock = IconView()
  lazy var copy = IconButton(symbol: "link", size: 22) { [weak self] in self?.emit("copy") }
  override var cornerRadius: CGFloat { Tokens.urlPillCornerRadius }
  override var baseFill: NSColor? { palette.pillFill }
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    addSubview(lock)
    addSubview(label)
    addSubview(copy)
    copy.isHidden = true
  }
  required init?(coder: NSCoder) { fatalError() }
  override func hoverChanged() { copy.isHidden = !hovering || node.str("text").isEmpty }
  override func update(_ v: Value) {
    super.update(v)
    let t = v.str("text")
    label.stringValue = t.isEmpty ? v.str("placeholder", "Search or Enter URL…") : t
    lock.spec = v.flag("secure") ? "sf:lock.fill" : ""
    lock.isHidden = !v.flag("secure")
    apply(r.palette)
    needsDisplay = true
    needsLayout = true
  }
  override func apply(_ p: Palette) {
    label.textColor = node.str("text").isEmpty ? p.secondaryText : p.text
    lock.tint = p.secondaryText
    copy.apply(p)
    needsDisplay = true
  }
  override func height(for w: CGFloat) -> CGFloat { Tokens.urlPillHeight }
  override func layout() {
    let h = bounds.height
    var x: CGFloat = 12
    if !lock.isHidden { lock.frame = NSRect(x: x, y: (h - 11) / 2, width: 11, height: 11); x += 17 }
    copy.frame = NSRect(x: bounds.width - 28, y: (h - 22) / 2, width: 22, height: 22)
    label.frame = NSRect(x: x, y: (h - 17) / 2, width: bounds.width - x - 32, height: 17)
  }
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let p = node.num("progress", 0)
    guard node.flag("loading"), p > 0, p < 1 else { return }
    let path = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    palette.accent.withAlphaComponent(0.85).setFill()
    NSRect(x: 0, y: bounds.height - 2, width: bounds.width * CGFloat(p), height: 2).fill()
    NSGraphicsContext.restoreGraphicsState()
  }
}

// MARK: - Favorites

/// {type:"grid", id?, columns?, children:[favoriteTile]}
final class GridNode: NodeView {
  var kids: [NodeView] = []
  var columns: Int { max(1, Int(node.num("columns", Double(Tokens.favoriteColumns)))) }
  override func update(_ v: Value) {
    super.update(v)
    kids = r.reconcile(v.list("children"), existing: kids, in: self)
    needsLayout = true
  }
  override func height(for w: CGFloat) -> CGFloat {
    guard !kids.isEmpty else { return 0 }
    let rows = (kids.count + columns - 1) / columns
    return CGFloat(rows) * Tokens.favoriteTileHeight + CGFloat(rows - 1) * Tokens.favoriteTileSpacing
  }
  override func layout() {
    let c = CGFloat(columns), sp = Tokens.favoriteTileSpacing
    let w = ((bounds.width - sp * (c - 1)) / c).rounded(.down)
    for (i, k) in kids.enumerated() {
      let col = CGFloat(i % columns), row = CGFloat(i / columns)
      k.frame = NSRect(x: col * (w + sp), y: row * (Tokens.favoriteTileHeight + sp), width: w, height: Tokens.favoriteTileHeight)
    }
  }
}

/// {type:"favoriteTile", id, icon, title, selected, audio}  actions: click, doubleClick, reorder
final class FavoriteTileNode: HoverNode {
  let icon = IconView()
  let audio = IconView()
  override var cornerRadius: CGFloat { Tokens.favoriteTileCornerRadius }
  override var baseFill: NSColor? { palette.tileFill }
  override var draggable: Bool { true }
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    addSubview(icon)
    addSubview(audio)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func update(_ v: Value) {
    super.update(v)
    icon.spec = v.str("icon")
    icon.fallbackLetter = v.str("title")
    toolTip = v.str("title")
    audio.spec = "sf:speaker.wave.2.fill"
    audio.isHidden = !v.flag("audio")
  }
  override func apply(_ p: Palette) { icon.tint = p.text; audio.tint = p.accent; needsDisplay = true }
  override func layout() {
    let s = Tokens.favoriteIconSize
    icon.frame = NSRect(x: (bounds.width - s) / 2, y: (bounds.height - s) / 2, width: s, height: s)
    audio.frame = NSRect(x: bounds.width - 15, y: 4, width: 11, height: 11)
  }
}

// MARK: - Space

/// {type:"spaceTitle", id, title, icon?}  actions: click, menu (the "…" button), toggle (collapse pinned)
final class SpaceTitleNode: HoverNode {
  let label = makeLabel(size: 12, weight: .semibold)
  let icon = IconView()
  lazy var more = IconButton(symbol: "ellipsis", size: 22) { [weak self] in self?.emit("more") }
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    addSubview(icon)
    addSubview(label)
    addSubview(more)
    more.isHidden = true
  }
  required init?(coder: NSCoder) { fatalError() }
  override var fillRect: NSRect { .zero }
  override func hoverChanged() { more.isHidden = !hovering }
  override func update(_ v: Value) {
    super.update(v)
    label.stringValue = v.str("title")
    icon.spec = v.str("icon")
    icon.isHidden = icon.spec.isEmpty
    needsLayout = true
  }
  override func apply(_ p: Palette) { label.textColor = p.secondaryText; icon.tint = p.secondaryText; more.apply(p) }
  override func height(for w: CGFloat) -> CGFloat { 28 }
  override func layout() {
    var x: CGFloat = 8
    if !icon.isHidden { icon.frame = NSRect(x: x, y: 7, width: 14, height: 14); x += 20 }
    label.frame = NSRect(x: x, y: 6, width: bounds.width - x - 30, height: 16)
    more.frame = NSRect(x: bounds.width - 26, y: 3, width: 22, height: 22)
  }
}

/// Footer space switcher item. {type:"spaceIcon", id, icon?, selected}  (empty icon = dot)
final class SpaceIconNode: HoverNode {
  let icon = IconView()
  override var cornerRadius: CGFloat { 6 }
  override var fillRect: NSRect { hovering ? bounds : .zero }
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    addSubview(icon)
  }
  required init?(coder: NSCoder) { fatalError() }
  override var selected: Bool { false }
  override func update(_ v: Value) {
    super.update(v)
    icon.spec = v.str("icon")
    toolTip = v.str("title")
    apply(r.palette)
    needsDisplay = true
  }
  override func apply(_ p: Palette) {
    icon.tint = node.flag("selected") ? p.text : p.secondaryText
    icon.alphaValue = node.flag("selected") ? 1 : 0.55
    needsDisplay = true
  }
  override func height(for w: CGFloat) -> CGFloat { Tokens.spaceIconSize + 4 }
  override var preferredWidth: CGFloat? { Tokens.spaceIconSize + 4 }
  override func layout() {
    let s: CGFloat = 16
    icon.frame = NSRect(x: (bounds.width - s) / 2, y: (bounds.height - s) / 2, width: s, height: s)
    icon.isHidden = icon.spec.isEmpty
  }
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard icon.spec.isEmpty else { return }
    let d = Tokens.spaceDotSize * (node.flag("selected") ? 1.25 : 1)
    (node.flag("selected") ? palette.text : palette.secondaryText.withAlphaComponent(0.4)).setFill()
    NSBezierPath(ovalIn: NSRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)).fill()
  }
}

// MARK: - Tabs

/// {type:"tabRow", id, title, icon, selected, audio, drift, closable=true, indent?, muted?}
/// actions: click {modifiers?}, doubleClick, close, reset (favicon click while drifted), mute, contextMenu/menu, reorder, dropOnContent
final class TabRowNode: HoverNode {
  let icon = IconView()
  let label = makeLabel()
  let drift = makeLabel("/", size: Tokens.tabRowFontSize, weight: .medium)
  let audio = IconView()
  lazy var close = IconButton(symbol: "xmark", size: 22) { [weak self] in self?.emit("close") }
  override var draggable: Bool { node.flag("draggable", true) }
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    [icon, drift, label, audio, close].forEach { addSubview($0) }
    close.isHidden = true
  }
  required init?(coder: NSCoder) { fatalError() }
  var indent: CGFloat { CGFloat(node.num("indent", 0)) * Tokens.folderIndent }
  override var fillRect: NSRect { bounds.insetBy(dx: 0, dy: 0) }
  override func hoverChanged() { close.isHidden = !(hovering && node.flag("closable", true)) ; needsLayout = true }
  override func update(_ v: Value) {
    super.update(v)
    label.stringValue = v.str("title", "Untitled")
    icon.spec = v.str("icon")
    icon.fallbackLetter = v.str("title")
    drift.isHidden = !v.flag("drift")
    audio.spec = v.flag("muted") ? "sf:speaker.slash.fill" : "sf:speaker.wave.2.fill"
    audio.isHidden = !(v.flag("audio") || v.flag("muted"))
    toolTip = v.str("title")
    apply(r.palette)
    needsLayout = true
  }
  override func apply(_ p: Palette) {
    label.textColor = p.text
    label.font = .systemFont(ofSize: Tokens.tabRowFontSize, weight: node.flag("selected") ? .medium : .regular)
    drift.textColor = p.secondaryText
    icon.tint = p.text
    audio.tint = p.secondaryText
    close.apply(p)
    needsDisplay = true
  }
  override func height(for w: CGFloat) -> CGFloat { Tokens.tabRowHeight }
  override func layout() {
    let h = bounds.height, s = Tokens.tabRowIconSize
    var x = Tokens.tabRowPaddingX + indent
    icon.frame = NSRect(x: x, y: (h - s) / 2, width: s, height: s)
    x += s + 8
    if !drift.isHidden {
      drift.sizeToFit()
      drift.frame = NSRect(x: x - 2, y: (h - 17) / 2, width: drift.frame.width, height: 17)
      x += drift.frame.width + 2
    }
    var right = bounds.width - 6
    if !close.isHidden { close.frame = NSRect(x: right - 22, y: (h - 22) / 2, width: 22, height: 22); right -= 26 }
    if !audio.isHidden { audio.frame = NSRect(x: right - 16, y: (h - 13) / 2, width: 14, height: 13); right -= 20 }
    label.frame = NSRect(x: x, y: (h - 17) / 2, width: max(0, right - x), height: 17)
  }
  override func clicked(at p: NSPoint, event: NSEvent) {
    if node.flag("drift"), icon.frame.insetBy(dx: -4, dy: -4).contains(p) { emit("reset"); return }
    if !audio.isHidden, audio.frame.insetBy(dx: -4, dy: -4).contains(p) { emit("mute"); return }
    super.clicked(at: p, event: event)
  }
  override func mouseUp(with event: NSEvent) {
    // Middle-click / cmd-W style close is handled by keys; plain click here.
    super.mouseUp(with: event)
  }
  override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { emit("close") } }
}

/// {type:"folder", id, title, icon?, open, children}  actions: toggle, click, reorder (as target: position "into")
final class FolderNode: NodeView {
  final class Header: HoverNode {
    let chevron = IconView()
    let icon = IconView()
    let label = makeLabel()
    override var draggable: Bool { true }
    required init(renderer: Renderer) {
      super.init(renderer: renderer)
      [chevron, icon, label].forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func apply(_ p: Palette) { label.textColor = p.text; icon.tint = p.text; chevron.tint = p.secondaryText; needsDisplay = true }
    override func height(for w: CGFloat) -> CGFloat { Tokens.tabRowHeight }
    override func clicked(at p: NSPoint, event: NSEvent) { emit("toggle") }
    override func layout() {
      let h = bounds.height, s = Tokens.tabRowIconSize
      let x = Tokens.tabRowPaddingX + CGFloat(node.num("indent", 0)) * Tokens.folderIndent
      icon.frame = NSRect(x: x, y: (h - s) / 2, width: s, height: s)
      label.frame = NSRect(x: x + s + 8, y: (h - 17) / 2, width: bounds.width - x - s - 34, height: 17)
      chevron.frame = NSRect(x: bounds.width - 22, y: (h - 10) / 2, width: 10, height: 10)
    }
  }
  lazy var header = Header(renderer: r)
  var kids: [NodeView] = []
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    addSubview(header)
  }
  required init?(coder: NSCoder) { fatalError() }
  var open: Bool { node.flag("open") }
  override func update(_ v: Value) {
    super.update(v)
    header.update(v)
    header.label.stringValue = v.str("title", "Folder")
    header.icon.spec = v.str("icon", open ? "sf:folder" : "sf:folder.fill")
    header.chevron.spec = open ? "sf:chevron.down" : "sf:chevron.right"
    let indent = v.num("indent", 0) + 1
    let children = open ? v.list("children").map { $0.with("indent", .double(indent)) } : []
    kids = r.reconcile(children, existing: kids, in: self)
    needsLayout = true
  }
  override func apply(_ p: Palette) { header.apply(p) }
  override func height(for w: CGFloat) -> CGFloat {
    Tokens.tabRowHeight + kids.map { $0.height(for: w) + Tokens.tabRowSpacing }.reduce(0, +)
  }
  override func layout() {
    header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Tokens.tabRowHeight)
    var y = Tokens.tabRowHeight + Tokens.tabRowSpacing
    for k in kids {
      let h = k.height(for: bounds.width)
      k.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
      y += h + Tokens.tabRowSpacing
    }
  }
}

/// Pinned/today divider with an optional action. {type:"divider", id, action?: "Clear"} -> action "clear"
final class DividerNode: HoverNode {
  let button = makeLabel(size: 11, weight: .medium)
  let arrow = IconView()
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    addSubview(arrow)
    addSubview(button)
  }
  required init?(coder: NSCoder) { fatalError() }
  override var fillRect: NSRect { .zero }
  override func hoverChanged() { apply(r.palette) }
  override func update(_ v: Value) {
    super.update(v)
    button.stringValue = v.str("action")
    button.isHidden = button.stringValue.isEmpty
    arrow.spec = "sf:arrow.down"
    arrow.isHidden = button.isHidden
    needsLayout = true
  }
  override func apply(_ p: Palette) {
    button.textColor = hovering ? p.text : p.secondaryText
    arrow.tint = button.textColor ?? p.secondaryText
    needsDisplay = true
  }
  override func height(for w: CGFloat) -> CGFloat { Tokens.dividerHeight }
  var lineEnd: CGFloat { button.isHidden ? bounds.width - 8 : bounds.width - button.intrinsicContentSize.width - 30 }
  override func layout() {
    let bw = ceil(button.intrinsicContentSize.width) + 4
    button.frame = NSRect(x: bounds.width - bw - 6, y: (bounds.height - 14) / 2, width: bw, height: 14)
    arrow.frame = NSRect(x: button.frame.minX - 13, y: (bounds.height - 9) / 2, width: 9, height: 9)
  }
  override func draw(_ dirtyRect: NSRect) {
    palette.divider.setFill()
    NSRect(x: 8, y: (bounds.height / 2).rounded(), width: max(0, lineEnd - 8), height: 1).fill()
  }
  override func clicked(at p: NSPoint, event: NSEvent) {
    if !button.isHidden, p.x > lineEnd { emit("clear") }
  }
}

/// {type:"newTabRow", id, title?} -> action "click"
final class NewTabRowNode: HoverNode {
  let icon = IconView()
  let label = makeLabel()
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    addSubview(icon)
    addSubview(label)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func update(_ v: Value) {
    super.update(v)
    icon.spec = "sf:plus"
    label.stringValue = v.str("title", "New Tab")
  }
  override func apply(_ p: Palette) { label.textColor = p.secondaryText; icon.tint = p.secondaryText; needsDisplay = true }
  override func height(for w: CGFloat) -> CGFloat { Tokens.tabRowHeight }
  override func layout() {
    let h = bounds.height, s: CGFloat = 13
    icon.frame = NSRect(x: Tokens.tabRowPaddingX + 1.5, y: (h - s) / 2, width: s, height: s)
    label.frame = NSRect(x: Tokens.tabRowPaddingX + Tokens.tabRowIconSize + 8, y: (h - 17) / 2, width: bounds.width - 44, height: 17)
  }
}
