import AppKit
import CordisValue

/// Node with hover tracking, a rounded fill for hover/selected, and click/double-click.
class HoverNode: NodeView, Hoverable {
  var hoverGroup: HoverGroup { .row }
  var hovering = false {
    didSet { if hovering != oldValue { needsDisplay = true; hoverChanged() } }
  }
  var selected: Bool { node.flag("selected") }
  var cornerRadius: CGFloat { Tokens.tabRowCornerRadius }
  var fillRect: NSRect { bounds }
  var baseFill: NSColor? { nil }
  var hoverColor: NSColor { palette.hoverFill }
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
      if let c = palette.selectedShadow {
        let sh = NSShadow()
        sh.shadowColor = c  // spec §3 TabCellShadowSelected; blur/offset UNVERIFIED (estimate)
        sh.shadowBlurRadius = 2
        sh.shadowOffset = NSSize(width: 0, height: -0.5)
        sh.set()
      }
      palette.selectedFill.setFill()
      path.fill()
      NSGraphicsContext.restoreGraphicsState()
    } else if hovering {
      hoverColor.setFill()
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
  override func mouseEntered(with event: NSEvent) {
    HoverTracker.refresh(window)
    r.hover?.entered(self)
  }
  override func mouseExited(with event: NSEvent) {
    HoverTracker.refresh(window)
    r.hover?.exited(self)
  }

  override func mouseDown(with event: NSEvent) {
    r.hover?.pressed(self)
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
    // Spec §1 (sidebar coordinates): toggle at x 77, back/forward/reload at x 122/156/190, y 7, 32x32.
    // This node sits inside the sidebar padding, so convert from sidebar x.
    let s = Tokens.navButtonSize, pad = Tokens.sidebarPadding, y: CGFloat = 7
    buttons[0].frame = NSRect(x: 77 - pad, y: y, width: s, height: s)
    // Right-aligned so they track the sidebar width: at 228 wide (node width 212) the x values are
    // 114/148/182 in node coordinates = 122/156/190 in the sidebar.
    for (i, b) in buttons[1...].enumerated() {
      b.frame = NSRect(x: bounds.width - 98 + CGFloat(i) * 34, y: y, width: s, height: s)
    }
  }

}

/// Simplified URL pill. {type:"urlPill", id, text, progress?, loading?, secure?, placeholder?}
/// actions: click (open the command bar pre-filled), copy (hover button)
/// With extensions installed, hovering also shows the pinned extensions' buttons and the
/// extensions menu button (Arc shows pinned extensions in the URL bar on hover). They talk to the
/// host `extensions` service directly, so plugins that render the pill need no changes.
final class URLPillNode: HoverNode {
  let label = makeLabel(size: Tokens.urlPillFontSize, weight: .medium)
  let lock = IconView()
  lazy var copy = IconButton(symbol: "link", size: 22) { [weak self] in self?.emit("copy") }
  var extensionButtons: [PillExtensionButton] = []
  var extensionsObserver: NSObjectProtocol?
  /// Shows the hover accessories without a pointer (snapshots).
  var forceAccessories = false { didSet { hoverChanged() } }
  override var cornerRadius: CGFloat { Tokens.urlPillCornerRadius }
  override var baseFill: NSColor? { palette.pillFill }
  override var hoverColor: NSColor { palette.pillHoverFill }
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    addSubview(lock)
    addSubview(label)
    addSubview(copy)
    copy.isHidden = true
    extensionsObserver = NotificationCenter.default.addObserver(forName: ExtensionsUI.changedNotification, object: nil, queue: .main) { [weak self] note in
      let sender = note.object.map { ObjectIdentifier($0 as AnyObject) }
      MainActor.assumeIsolated {
        // Only this window's extensions (tests and future multi-window runs have several).
        guard let self, let ext = ExtensionsUI.of(self.window), sender == ObjectIdentifier(ext) else { return }
        self.syncExtensions()
      }
    }
    syncExtensions()
  }
  required init?(coder: NSCoder) { fatalError() }
  isolated deinit { if let o = extensionsObserver { NotificationCenter.default.removeObserver(o) } }
  var showsAccessories: Bool { hovering || forceAccessories }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil { syncExtensions() }
  }
  override func hoverChanged() {
    copy.isHidden = !showsAccessories || node.str("text").isEmpty
    extensionButtons.forEach { $0.isHidden = !showsAccessories }
    needsLayout = true
  }

  // thin-host: feature-specific, migrate to plugin
  /// Pinned extensions, then the extensions menu button. Nothing while none is installed.
  func syncExtensions() {
    guard let ext = ExtensionsUI.of(window), ext.hasExtensions else {
      extensionButtons.forEach { $0.removeFromSuperview() }
      extensionButtons = []
      return
    }
    ext.pill = self
    let pinned = ext.pinnedItems
    let ids = pinned.map(\.id) + ["menu"]
    if extensionButtons.map(\.id) != ids {
      extensionButtons.forEach { $0.removeFromSuperview() }
      extensionButtons = ids.map { id in
        let b = PillExtensionButton(id: id)
        b.onClick = { [weak ext] b in ext?.pillClicked(b.id, from: b) }
        addSubview(b)
        return b
      }
    }
    for (b, it) in zip(extensionButtons, pinned) { b.configure(it, tooltip: it.title) }
    extensionButtons.last?.configure(nil, symbol: "sf:puzzlepiece.extension", tooltip: "Extensions")
    apply(r.palette)
    hoverChanged()
  }
  override func update(_ v: Value) {
    super.update(v)
    let t = v.str("text")
    label.stringValue = t.isEmpty ? v.str("placeholder", "Search or Enter URL…") : t
    lock.isHidden = true  // Arc shows the bare domain (spec §1: text at x = 20)
    apply(r.palette)
    needsDisplay = true
    needsLayout = true
  }
  override func apply(_ p: Palette) {
    label.textColor = node.str("text").isEmpty ? p.secondaryText : p.text
    lock.tint = p.secondaryText
    copy.apply(p)
    for b in extensionButtons {
      b.icon.tint = p.text.withAlphaComponent(0.75)
      b.hoverFill = p.hoverFill
      b.badge.apply(p)
    }
    needsDisplay = true
  }
  override func height(for w: CGFloat) -> CGFloat { Tokens.urlPillHeight }
  override func layout() {
    let h = bounds.height
    let x: CGFloat = 12  // spec §1: text at sidebar x = 20
    copy.frame = NSRect(x: bounds.width - 28, y: (h - 22) / 2, width: 22, height: 22)
    // Extension buttons sit left of the copy button, right-aligned, while the pill is hovered.
    var right = bounds.width - (copy.isHidden ? 6 : 30)
    let s = Tokens.extensionPillButton
    for b in extensionButtons.reversed() where !b.isHidden {
      right -= s
      b.frame = NSRect(x: right, y: (h - s) / 2, width: s, height: s)
      if right < x + 40 { b.isHidden = true }  // a narrow sidebar keeps the domain readable
    }
    label.frame = NSRect(x: x, y: (h - 17) / 2, width: max(0, min(bounds.width - x - 32, right - x - 4)), height: 17)
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

/// {type:"spaceTitle", id, title, icon?, editing?, editText?}
/// actions: click, doubleClick, more (the "…" button), menu (right-click), rename {title} / renameCancel (while `editing`)
final class SpaceTitleNode: HoverNode {
  let label = makeLabel(size: 13.5, weight: .semibold)  // spec §1
  let icon = IconView()
  lazy var more = IconButton(symbol: "ellipsis", size: 22) { [weak self] in self?.emit("more") }
  lazy var rename = RenameSupport(owner: self, label: label)
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    addSubview(icon)
    addSubview(label)
    addSubview(more)
    more.isHidden = true
  }
  required init?(coder: NSCoder) { fatalError() }
  override var fillRect: NSRect { .zero }
  override func hoverChanged() { more.isHidden = !hovering || rename.active }
  override func update(_ v: Value) {
    super.update(v)
    label.stringValue = v.str("title")
    icon.spec = v.str("icon")
    icon.isHidden = icon.spec.isEmpty
    rename.update(v)
    more.isHidden = !hovering || rename.active
    needsLayout = true
  }
  override func apply(_ p: Palette) { label.textColor = p.text; rename.editor?.textColor = p.text; icon.tint = p.text; more.apply(p) }
  override func height(for w: CGFloat) -> CGFloat { Tokens.spaceTitleHeight }
  override func layout() {
    // Spec §1 (sidebar coords): icon 26x26 at x 13, name at x 41, "More" at x 213.
    let h = bounds.height, pad = Tokens.sidebarPadding
    icon.frame = NSRect(x: 13 - pad + 6, y: (h - 14) / 2, width: 14, height: 14)  // glyph drawn inside the 26 pt icon box
    label.frame = NSRect(x: 41 - pad, y: (h - 18) / 2, width: bounds.width - (41 - pad) - 30, height: 18)
    more.frame = NSRect(x: bounds.width - 24, y: (h - 22) / 2, width: 22, height: 22)
    rename.layout()
  }
}

/// Footer space switcher item. {type:"spaceIcon", id, icon?, title, selected, spaceId?, reorderable?}  (empty icon = dot)
/// With `spaceId`, a tab row dragged over the icon highlights it and drops as `dropOnSpace`.
/// With `reorderable`, dragging the icon sideways reorders the strip live (siblings slide aside,
/// a haptic tick per slot) and a drop that changed the slot emits `move {index}` (index among the
/// row's reorderable space icons).
final class SpaceIconNode: HoverNode {
  let icon = IconView()
  /// A dragged tab is over this icon.
  var dropTarget = false { didSet { if dropTarget != oldValue { apply(r.palette) } } }
  private var reorder: SpaceIconReorder?
  private var pressAt: NSPoint?

  override func mouseDown(with event: NSEvent) {
    pressAt = node.flag("reorderable") && event.clickCount == 1 ? event.locationInWindow : nil
    super.mouseDown(with: event)
  }
  override func mouseDragged(with event: NSEvent) {
    if let r = reorder { r.move(event); return }
    guard let d = pressAt, abs(event.locationInWindow.x - d.x) > 3 else { return }
    reorder = SpaceIconReorder(self, event: event)
  }
  override func mouseUp(with event: NSEvent) {
    pressAt = nil
    if let r = reorder {
      reorder = nil
      if let to = r.end() { emit("move", ["index": .int(Int64(to))]) }
      return
    }
    super.mouseUp(with: event)
  }
  override var cornerRadius: CGFloat { 6 }
  override var fillRect: NSRect { hovering || dropTarget ? bounds : .zero }
  override var hoverColor: NSColor { dropTarget ? palette.selectedFill : palette.hoverFill }
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
    icon.tint = node.flag("selected") || dropTarget ? p.text : p.secondaryText
    icon.alphaValue = node.flag("selected") || dropTarget ? 1 : 0.55
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
    if dropTarget && !hovering {
      palette.selectedFill.setFill()
      NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
    }
    super.draw(dirtyRect)
    guard icon.spec.isEmpty else { return }
    let d = Tokens.spaceDotSize * (node.flag("selected") ? 1.25 : 1)
    (node.flag("selected") || dropTarget ? palette.text : palette.secondaryText.withAlphaComponent(0.4)).setFill()
    NSBezierPath(ovalIn: NSRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)).fill()
  }
}

/// Live drag-reorder of the footer's space icons (Arc: rearrange Spaces by dragging their icons).
/// The dragged icon follows the pointer along the strip; the others glide into their new slots as
/// it passes their midpoints, with a haptic tick per slot. Nothing is emitted until the drop.
@MainActor
final class SpaceIconReorder {
  /// The drag in progress: its row keeps the live frames (a re-render mid-drag mustn't snap back).
  static weak var active: SpaceIconReorder?
  let icon: SpaceIconNode
  let icons: [SpaceIconNode]  // strip order at pick-up
  let slots: [NSRect]
  let start: Int
  private(set) var target: Int
  private let grabX: CGFloat
  private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

  init(_ icon: SpaceIconNode, event: NSEvent) {
    self.icon = icon
    let row = icon.superview
    icons = (row?.subviews ?? []).compactMap { $0 as? SpaceIconNode }.filter { $0.node.flag("reorderable") && !$0.isHidden }.sorted { $0.frame.minX < $1.frame.minX }
    slots = icons.map(\.frame)
    start = icons.firstIndex { $0 === icon } ?? 0
    target = start
    grabX = (row.map { $0.convert(event.locationInWindow, from: nil).x } ?? 0) - icon.frame.minX
    // Lift: above its siblings, slightly larger (a pick-up haptic, like Arc's tab reordering).
    if let row { row.addSubview(icon, positioned: .above, relativeTo: nil) }
    icon.wantsLayer = true
    icon.layer?.zPosition = 1
    setLift(true)
    Self.active = self
    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
  }

  private func setLift(_ on: Bool) {
    guard let l = icon.layer else { return }
    let t = on ? CATransform3DMakeScale(Tokens.spaceIconLiftScale, Tokens.spaceIconLiftScale, 1) : CATransform3DIdentity
    // Scale around the center (layer-backed NSViews anchor at the origin).
    let b = icon.bounds
    let centered = CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-b.midX, -b.midY, 0), t), CATransform3DMakeTranslation(b.midX, b.midY, 0))
    if reduceMotion { l.transform = on ? centered : CATransform3DIdentity; return }
    let a = CABasicAnimation(keyPath: "transform")
    a.fromValue = l.presentation()?.transform ?? l.transform
    a.toValue = on ? centered : CATransform3DIdentity
    a.duration = Tokens.spaceIconReorderDuration
    a.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
    l.transform = on ? centered : CATransform3DIdentity
    l.add(a, forKey: "lift")
  }

  func move(_ event: NSEvent) {
    guard let row = icon.superview, slots.count > 1 else { return }
    let x = row.convert(event.locationInWindow, from: nil).x - grabX
    let minX = slots.first!.minX, maxX = slots.last!.minX
    icon.setFrameOrigin(NSPoint(x: min(max(x, minX), maxX), y: icon.frame.minY))
    let mid = icon.frame.midX
    let t = slots.indices.min { abs(slots[$0].midX - mid) < abs(slots[$1].midX - mid) } ?? start
    guard t != target else { return }
    target = t
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    var order = icons.filter { $0 !== icon }
    order.insert(icon, at: t)
    animate {
      for (k, v) in order.enumerated() where v !== self.icon { self.frame(v, self.slots[k]) }
    }
  }

  /// Settles the icon in its slot; returns the new index when it changed.
  func end() -> Int? {
    let slot = target < slots.count ? slots[target] : icon.frame
    animate { self.frame(self.icon, slot) }
    setLift(false)
    if Self.active === self { Self.active = nil }
    icon.layer?.zPosition = 0
    if target != start { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now) }
    return target != start ? target : nil
  }

  private func frame(_ v: NSView, _ f: NSRect) { if reduceMotion { v.frame = f } else { v.animator().frame = f } }
  private func animate(_ body: @escaping () -> Void) {
    if reduceMotion { body(); return }
    NSAnimationContext.runAnimationGroup { c in
      c.duration = Tokens.spaceIconReorderDuration
      c.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
      c.allowsImplicitAnimation = true
      body()
    }
  }
}

// MARK: - Inline rename

/// Arc's in-place rename field: the row's title becomes editable with all text selected.
/// Return commits, Esc cancels, clicking elsewhere commits (like Finder).
final class InlineTitleEditor: NSTextField, NSTextFieldDelegate {
  var onCommit: ((String) -> Void)?
  var onCancel: (() -> Void)?
  private var finished = false

  init() {
    super.init(frame: .zero)
    isBordered = false
    drawsBackground = false
    focusRingType = .none
    isEditable = true
    isSelectable = true
    lineBreakMode = .byClipping
    usesSingleLineMode = true
    cell?.isScrollable = true
    cell?.wraps = false
    delegate = self
  }
  required init?(coder: NSCoder) { fatalError() }

  /// Shows the field with `text`, selected, as first responder.
  func begin(_ text: String, font: NSFont?, color: NSColor) {
    finished = false
    stringValue = text
    self.font = font
    textColor = color
    window?.makeFirstResponder(self)
    currentEditor()?.selectAll(nil)
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
    switch sel {
    case #selector(NSResponder.insertNewline(_:)): finish(commit: true); return true
    case #selector(NSResponder.cancelOperation(_:)): finish(commit: false); return true
    default: return false
    }
  }

  func controlTextDidEndEditing(_ obj: Notification) { finish(commit: true) }

  func finish(commit: Bool) {
    guard !finished else { return }
    finished = true
    let text = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if commit { onCommit?(text) } else { onCancel?() }
  }
}

/// Adds `editing` support to a row: {editing: true} swaps `label` for an `InlineTitleEditor`
/// and emits `rename {title}` (empty = reset) or `renameCancel`.
@MainActor
final class RenameSupport {
  unowned let owner: NodeView
  let label: NSTextField
  var editor: InlineTitleEditor?
  init(owner: NodeView, label: NSTextField) { (self.owner, self.label) = (owner, label) }

  var active: Bool { editor != nil }

  func update(_ v: Value) {
    if v.flag("editing") {
      guard editor == nil else { return }
      let e = InlineTitleEditor()
      e.onCommit = { [weak self] t in self?.end(); self?.owner.emit("rename", ["title": .string(t)]) }
      e.onCancel = { [weak self] in self?.end(); self?.owner.emit("renameCancel") }
      owner.addSubview(e)
      editor = e
      label.isHidden = true
      e.frame = label.frame
      // Begin once the row is in its window and laid out.
      DispatchQueue.main.async { [weak self, weak e] in
        guard let self, let e, self.editor === e else { return }
        e.frame = self.label.frame
        e.begin(v.str("editText", v.str("title")), font: self.label.font, color: self.label.textColor ?? .labelColor)
      }
    } else if editor != nil {
      end()
    }
  }

  func layout() { editor?.frame = label.frame.insetBy(dx: -1, dy: 0) }

  private func end() {
    guard let e = editor else { return }
    editor = nil
    let hadFocus = e.currentEditor() != nil
    e.onCommit = nil
    e.onCancel = nil
    e.removeFromSuperview()
    label.isHidden = false
    if hadFocus { owner.window?.makeFirstResponder(nil) }
  }
}

// MARK: - Tabs

/// {type:"tabRow", id, title, icon, selected, audio, drift, closable=true, indent?, muted?, editing?, editText?}
/// actions: click {modifiers?}, doubleClick, close, reset (favicon click while drifted), mute, contextMenu/menu, reorder,
/// dropOnContent, rename {title} / renameCancel (while `editing`)
final class TabRowNode: HoverNode {
  let icon = IconView()
  let label = makeLabel()
  let drift = makeLabel("/", size: Tokens.tabRowFontSize, weight: .medium)
  let audio = IconView()
  lazy var close = IconButton(symbol: "xmark", size: 22) { [weak self] in self?.emit("close") }
  lazy var rename = RenameSupport(owner: self, label: label)
  override var draggable: Bool { node.flag("draggable", true) && !rename.active }
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    [icon, drift, label, audio, close].forEach { addSubview($0) }
    close.isHidden = true
  }
  required init?(coder: NSCoder) { fatalError() }
  var indent: CGFloat { CGFloat(node.num("indent", 0)) * Tokens.folderIndent }
  override var fillRect: NSRect { bounds.insetBy(dx: 0, dy: (bounds.height - 36) / 2) }  // spec §1: 212x36 highlight
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
    rename.update(v)
    needsLayout = true
  }
  override func apply(_ p: Palette) {
    label.textColor = p.text
    label.font = .systemFont(ofSize: Tokens.tabRowFontSize, weight: node.flag("selected") ? .medium : .regular)
    rename.editor?.textColor = p.text
    drift.textColor = p.tertiaryText
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
    label.frame = NSRect(x: x, y: (h - 18) / 2, width: max(0, right - x), height: 18)
    rename.layout()
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

/// A split view as one sidebar item (Arc §7: "a split is its own tab"): one 36 pt row holding a
/// segment per pane (favicon + title), split by hairlines. While the split is shown, the focused
/// pane sits in an inner chip and the others dim. Segment geometry is den's estimate (Arc's split
/// row was never measured, spec §12).
/// {type:"splitRow", id, selected, layout?, panes: [{id, title, icon, selected}], closable=true, indent?}
/// actions: click {pane}, close (hover X: separate), reorder, dropOnSpace, contextMenu/menu
final class SplitRowNode: HoverNode {
  @MainActor final class Segment {
    let icon = IconView()
    let label = makeLabel()
    var frame = NSRect.zero
    var id = ""
    var focused = false
  }
  var segments: [Segment] = []
  lazy var close = IconButton(symbol: "xmark", size: 22) { [weak self] in self?.emit("close") }
  let layoutIcon = IconView()
  static let chipInset: CGFloat = 4
  override var draggable: Bool { true }
  override var fillRect: NSRect { bounds.insetBy(dx: 0, dy: (bounds.height - 36) / 2) }
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    addSubview(close)
    close.isHidden = true
  }
  required init?(coder: NSCoder) { fatalError() }
  var indent: CGFloat { CGFloat(node.num("indent", 0)) * Tokens.folderIndent }
  override func hoverChanged() { close.isHidden = !(hovering && node.flag("closable", true)); needsLayout = true }
  override func update(_ v: Value) {
    super.update(v)
    let panes = v.list("panes")
    while segments.count < panes.count {
      let s = Segment()
      addSubview(s.icon)
      addSubview(s.label)
      segments.append(s)
    }
    while segments.count > panes.count {
      let s = segments.removeLast()
      s.icon.removeFromSuperview()
      s.label.removeFromSuperview()
    }
    for (s, p) in zip(segments, panes) {
      s.id = p.str("id")
      s.focused = p.flag("selected")
      s.label.stringValue = p.str("title", "Untitled")
      s.icon.spec = p.str("icon")
      s.icon.fallbackLetter = p.str("title")
    }
    toolTip = panes.map { $0.str("title") }.joined(separator: "  |  ")
    apply(r.palette)
    needsLayout = true
    needsDisplay = true
  }
  override func apply(_ p: Palette) {
    let shown = node.flag("selected")
    for s in segments {
      let strong = !shown || s.focused
      s.label.textColor = strong ? p.text : p.secondaryText
      s.label.font = .systemFont(ofSize: Tokens.tabRowFontSize, weight: shown && s.focused ? .medium : .regular)
      s.icon.tint = p.text
      s.icon.alphaValue = strong ? 1 : 0.6
    }
    close.apply(p)
    needsDisplay = true
  }
  override func height(for w: CGFloat) -> CGFloat { Tokens.tabRowHeight }
  override func layout() {
    let h = bounds.height, s = Tokens.tabRowIconSize
    var right = bounds.width - 4
    if !close.isHidden { close.frame = NSRect(x: right - 24, y: (h - 22) / 2, width: 22, height: 22); right -= 26 }
    let left = indent + 2
    let n = CGFloat(max(1, segments.count))
    let w = ((right - left) / n).rounded(.down)
    for (i, seg) in segments.enumerated() {
      seg.frame = NSRect(x: left + CGFloat(i) * w, y: fillRect.minY, width: w, height: fillRect.height)
      // Favicon + title; a narrow segment (3–4 panes) keeps only the favicon, centered.
      let pad: CGFloat = 7
      let titleRoom = w - pad * 2 - s - 6
      if titleRoom < 40 {
        seg.icon.frame = NSRect(x: seg.frame.midX - s / 2, y: (h - s) / 2, width: s, height: s)
        seg.label.isHidden = true
      } else {
        seg.icon.frame = NSRect(x: seg.frame.minX + pad, y: (h - s) / 2, width: s, height: s)
        seg.label.isHidden = false
        seg.label.frame = NSRect(x: seg.icon.frame.maxX + 6, y: (h - 18) / 2, width: titleRoom, height: 18)
      }
    }
  }
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let shown = node.flag("selected")
    let chip = segments.first { shown && $0.focused }
    if let c = chip {
      let r = c.frame.insetBy(dx: Self.chipInset - 2, dy: Self.chipInset)
      (palette.dark ? Palette.snow(0.10) : Palette.ink(0.06)).setFill()
      NSBezierPath(roundedRect: r, xRadius: Tokens.tabRowCornerRadius - 3, yRadius: Tokens.tabRowCornerRadius - 3).fill()
    }
    // Hairlines between segments, hidden next to the chip.
    palette.divider.setFill()
    for (a, b) in zip(segments, segments.dropFirst()) where a !== chip && b !== chip {
      NSRect(x: b.frame.minX - 0.5, y: bounds.midY - 8, width: 1, height: 16).fill()
    }
  }
  override func clicked(at p: NSPoint, event: NSEvent) {
    let seg = segments.first { $0.frame.contains(NSPoint(x: p.x, y: $0.frame.midY)) } ?? segments.first
    emit("click", ["pane": .string(seg?.id ?? "")])
  }
}

/// {type:"folder", id, title, icon?, open, children, editing?}  actions: toggle, click, reorder (as target: position "into"),
/// rename {title} / renameCancel (while `editing`)
final class FolderNode: NodeView {
  final class Header: HoverNode {
    let chevron = IconView()
    let icon = IconView()
    let label = makeLabel()
    lazy var rename = RenameSupport(owner: self, label: label)
    override var draggable: Bool { !rename.active }
    override var fillRect: NSRect { bounds.insetBy(dx: 0, dy: (bounds.height - 36) / 2) }
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
      rename.layout()
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
    header.rename.update(v)
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
  var lineEnd: CGFloat { button.isHidden ? bounds.width - 8 : bounds.width - button.textWidth - 30 }
  override func layout() {
    let bw = ceil(button.textWidth) + 4
    button.frame = NSRect(x: bounds.width - bw - 6, y: (bounds.height - 14) / 2, width: bw, height: 14)
    arrow.frame = NSRect(x: button.frame.minX - 13, y: (bounds.height - 9) / 2, width: 9, height: 9)
  }
  override func draw(_ dirtyRect: NSRect) {
    palette.divider.setFill()
    NSRect(x: 8, y: (bounds.height / 2).rounded(), width: max(0, lineEnd - 8), height: 0.5).fill()  // spec §1: 0.5 pt
  }
  override func clicked(at p: NSPoint, event: NSEvent) {
    if !button.isHidden, p.x > lineEnd { emit("clear") }
  }
}

/// {type:"newTabRow", id, title?} -> action "click"
final class NewTabRowNode: HoverNode {
  override var fillRect: NSRect { bounds.insetBy(dx: 0, dy: (bounds.height - 36) / 2) }
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
    let h = bounds.height, s: CGFloat = 14
    icon.frame = NSRect(x: Tokens.tabRowPaddingX + 2, y: (h - s) / 2, width: s, height: s)
    label.frame = NSRect(x: Tokens.tabRowPaddingX + Tokens.tabRowIconSize + 8, y: (h - 18) / 2, width: bounds.width - 44, height: 18)
  }
}
