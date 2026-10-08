import AppKit
import CordisValue

/// Node with hover tracking, a rounded fill for hover/selected, and click/double-click.
class HoverNode: NodeView, Hoverable {
  var hoverGroup: HoverGroup { .row }
  var hovering = false {
    didSet { if hovering != oldValue { needsDisplay = true; hoverChanged() } }
  }
  /// `highlighted`: picked into a multi-selection (⌘/⇧-click); drawn like the selected row.
  var selected: Bool { node.flag("selected") || node.flag("highlighted") }
  var cornerRadius: CGFloat { Tokens.tabRowCornerRadius }
  var fillRect: NSRect { bounds }
  var baseFill: NSColor? { nil }
  var hoverColor: NSColor { palette.hoverFill }
  private var downPoint: NSPoint?
  private var dragging = false
  var draggable: Bool { false }
  override var busy: Bool {
    hovering || downPoint != nil || (window?.firstResponder as? NSView)?.isDescendant(of: self) == true
  }

  func hoverChanged() {}

  override func update(_ v: Value) {
    let wasSel = selected
    super.update(v)
    if wasSel != selected { needsDisplay = true }
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
  /// (symbol, action, tooltip, menu bar item whose shortcut the tooltip shows).
  static let specs: [(String, String, String, String)] = [
    ("sidebar.left", "toggleSidebar", "Toggle Sidebar", "view.sidebar"), ("arrow.left", "back", "Back", "history.back"),
    ("arrow.right", "forward", "Forward", "history.forward"), ("arrow.clockwise", "reload", "Reload Page", "view.reload"),
  ]
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    for (sym, act, tip, ref) in Self.specs {
      let b = IconButton(symbol: sym, size: Tokens.navButtonSize) { [weak self] in
        guard let self else { return }
        self.emit(act == "reload" && self.node.flag("loading") ? "stop" : act)
      }
      b.setTip(tip, shortcut: ref)
      buttons.append(b)
      addSubview(b)
    }
  }
  required init?(coder: NSCoder) { fatalError() }
  override func update(_ v: Value) {
    super.update(v)
    buttons[1].enabled = v.flag("canGoBack")
    buttons[2].enabled = v.flag("canGoForward")
    let loading = v.flag("loading")
    buttons[3].icon.spec = loading ? "sf:xmark" : "sf:arrow.clockwise"
    buttons[3].setTip(loading ? "Stop Loading" : "Reload Page", shortcut: loading ? "view.stop" : "view.reload")
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

/// Simplified URL pill. {type:"urlPill", id, text, progress?, loading?, secure?, placeholder?,
/// buttons?: [{id, icon, tooltip?, active?}], webview?}
/// actions: click (open the command bar pre-filled), copy (hover button). A `buttons` item
/// (other plugins' page actions, e.g. Reader; always visible) emits
/// {id: <its id>, action: click, value: {webview}}.
/// With extensions installed, hovering also shows the pinned extensions' buttons and the
/// extensions menu button (Arc shows pinned extensions in the URL bar on hover). They talk to the
/// host `extensions` service directly, so plugins that render the pill need no changes.
final class URLPillNode: HoverNode {
  let label = makeLabel(size: Tokens.urlPillFontSize, weight: .medium)
  let lock = IconView()
  lazy var copy = IconButton(symbol: "link", size: 22) { [weak self] in self?.emit("copy") }
  var extensionButtons: [PillExtensionButton] = []
  var extensionsObserver: NSObjectProtocol?
  /// "Add to den" while the page is a store item that isn't installed (always visible).
  var storeButton: PillButton?
  /// Shows the hover accessories without a pointer (snapshots).
  var forceAccessories = false { didSet { hoverChanged() } }
  var extra: [IconButton] = []
  var extraKey = ""
  override var cornerRadius: CGFloat { Tokens.urlPillCornerRadius }
  override var baseFill: NSColor? { palette.pillFill }
  override var hoverColor: NSColor { palette.pillHoverFill }
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    addSubview(lock)
    addSubview(label)
    addSubview(copy)
    copy.isHidden = true
    copy.setTip("Copy Link", shortcut: "edit.copyURL")
    extensionsObserver = NotificationCenter.default.addObserver(forName: ExtensionsUI.changedNotification, object: nil, queue: .main) { [weak self] note in
      let sender = note.object.map { ObjectIdentifier($0 as AnyObject) }
      MainActor.assumeIsolated {
        // Only this window's extensions (tests and future multi-window runs have several).
        guard let self, let ext = ExtensionsUI.of(self.window), sender == ObjectIdentifier(ext) else { return }
        self.syncExtensions()
        self.syncStoreOffer()
      }
    }
    syncExtensions()
  }
  required init?(coder: NSCoder) { fatalError() }
  isolated deinit { if let o = extensionsObserver { NotificationCenter.default.removeObserver(o) } }
  var showsAccessories: Bool { hovering || forceAccessories }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil { syncExtensions(); syncStoreOffer() }
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
  // thin-host: feature-specific, migrate to plugin
  /// den's own install button for the store item on screen (ExtensionsUI.storeOffer).
  func syncStoreOffer() {
    let ext = ExtensionsUI.of(window)
    guard let ext, let offer = ext.storeOffer else {
      if storeButton != nil {
        storeButton?.removeFromSuperview()
        storeButton = nil
        needsLayout = true
      }
      return
    }
    let b: PillButton
    if let existing = storeButton {
      b = existing
    } else {
      b = PillButton(title: "Add to den", style: "default") { [weak ext] in ext?.addStoreOffer() }
      b.cornerRadius = Tokens.urlPillStoreButtonRadius
      addSubview(b)
      storeButton = b
    }
    let busy = ext.storePending == offer.id
    b.label.stringValue = busy ? "Adding…" : "Add to den"
    b.toolTip = busy ? "Installing this extension" : "Install this extension in den"
    b.alphaValue = busy ? 0.6 : 1
    b.apply(r.palette)
    needsLayout = true
  }

  override func update(_ v: Value) {
    super.update(v)
    let t = v.str("text")
    label.stringValue = t.isEmpty ? v.str("placeholder", "Search or Enter URL…") : t
    lock.isHidden = true  // Arc shows the bare domain (spec §1: text at x = 20)
    let buttons = v.list("buttons")
    let key = buttons.map { $0.str("id") + "|" + $0.str("icon") + "|" + $0.str("tooltip") + "|" + $0.str("shortcut") + "|" + $0.str("shortcutFor") }.joined(separator: ",")
    if key != extraKey {
      extraKey = key
      extra.forEach { $0.removeFromSuperview() }
      extra = buttons.map { b in
        let id = b.str("id")
        let btn = IconButton(symbol: "doc", size: 22) { [weak self] in
          guard let self else { return }
          self.r.emit(id, "click", ["webview": .string(self.node.str("webview"))])
        }
        btn.icon.spec = b.str("icon")
        btn.setTip(b.str("tooltip"), shortcut: b.str("shortcutFor"), fallback: b.str("shortcut"))
        addSubview(btn)
        return btn
      }
    }
    apply(r.palette)
    needsDisplay = true
    needsLayout = true
  }
  override func apply(_ p: Palette) {
    label.textColor = node.str("text").isEmpty ? p.secondaryText : p.text
    lock.tint = p.secondaryText
    copy.apply(p)
    storeButton?.apply(p)
    for b in extensionButtons {
      b.icon.tint = p.text.withAlphaComponent(0.75)
      b.hoverFill = p.hoverFill
      b.badge.apply(p)
    }
    let buttons = node.list("buttons")
    for (i, b) in extra.enumerated() {
      b.apply(p)
      if i < buttons.count, buttons[i].flag("active") { b.tint = p.accentStrong }
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
    if let b = storeButton {
      let w = b.preferredWidth, bh = Tokens.urlPillStoreButtonHeight
      right -= w + 2
      b.frame = NSRect(x: right, y: ((h - bh) / 2).rounded(), width: w, height: bh)
      right -= 2
    }
    // Page actions (plugins' `buttons`) sit left of those, always visible.
    for b in extra.reversed() {
      right -= 24
      b.frame = NSRect(x: right + 1, y: (h - 22) / 2, width: 22, height: 22)
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
/// {type:"grid", id, columns? (4), children}: Arc's favorites grid. Rows of up to `columns` tiles,
/// and every row's tiles stretch to fill the width: 1 tile is full width, 2 are halves, 3 thirds;
/// 5 tiles are a row of 4 and one full-width tile. Tile height is fixed. When the children change
/// (added, removed, reordered) the tiles that stay spring into their new frames (none with Reduce
/// Motion) with the reorder haptic; a resize relayouts at once.
final class GridNode: NodeView {
  var kids: [NodeView] = []
  var columns: Int { max(1, Int(node.num("columns", Double(Tokens.favoriteColumns)))) }
  private var animateNext = false

  /// Tiles per row at `width`: up to `max`, fewer when tiles would be narrower than
  /// `Tokens.favoriteMinTileWidth` (a narrow sidebar reflows to rows of 3, then 2).
  static func columns(for width: CGFloat, max: Int, spacing sp: CGFloat = Tokens.favoriteTileSpacing) -> Int {
    Swift.max(1, Swift.min(max, Int(((width + sp) / (Tokens.favoriteMinTileWidth + sp)).rounded(.down))))
  }

  /// Frames for `count` tiles in `width` (top-left origin). Widths are whole points; the leftover
  /// points go one each to the trailing tiles (so widths in a row differ by at most 1), and the
  /// last tile ends exactly at `width` with no gap.
  static func frames(count: Int, width: CGFloat, columns: Int, spacing sp: CGFloat = Tokens.favoriteTileSpacing,
                     height h: CGFloat = Tokens.favoriteTileHeight) -> [NSRect] {
    guard count > 0, columns > 0 else { return [] }
    var out: [NSRect] = []
    var i = 0, row = 0
    while i < count {
      let n = min(columns, count - i)
      let avail = width - sp * CGFloat(n - 1)
      let w = (avail / CGFloat(n)).rounded(.down)
      let extra = max(0, min(n, Int((avail - w * CGFloat(n)).rounded(.down))))
      var x: CGFloat = 0
      for c in 0..<n {
        let cw = c == n - 1 ? width - x : w + (c >= n - extra ? 1 : 0)
        out.append(NSRect(x: x, y: CGFloat(row) * (h + sp), width: max(0, cw), height: h))
        x += cw + sp
      }
      i += n
      row += 1
    }
    return out
  }

  override func update(_ v: Value) {
    super.update(v)
    let before = kids.map { ObjectIdentifier($0) }
    kids = r.reconcile(v.list("children"), existing: kids, in: self)
    // Only a change to the set or the order animates; a plain re-render (a title, a badge) doesn't.
    if window != nil, !before.isEmpty, before != kids.map({ ObjectIdentifier($0) }) { animateNext = true }
    needsLayout = true
  }
  override func height(for w: CGFloat) -> CGFloat {
    guard !kids.isEmpty else { return 0 }
    let cols = Self.columns(for: w, max: columns)
    let rows = (kids.count + cols - 1) / cols
    return CGFloat(rows) * Tokens.favoriteTileHeight + CGFloat(rows - 1) * Tokens.favoriteTileSpacing
  }
  override func layout() {
    let fs = Self.frames(count: kids.count, width: bounds.width, columns: Self.columns(for: bounds.width, max: columns))
    let animate = animateNext && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    animateNext = false
    guard animate else {
      for (k, f) in zip(kids, fs) { k.frame = f }
      return
    }
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    NSAnimationContext.runAnimationGroup { c in
      // A short spring: a slight overshoot that settles (den's values; Arc's aren't measured).
      c.duration = 0.32
      c.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.36, 0.64, 1)
      c.allowsImplicitAnimation = true
      for (k, f) in zip(kids, fs) {
        // A tile that just appeared starts at its final frame (it fades in with the row).
        if k.frame.isEmpty { k.frame = f } else { k.animator().frame = f }
      }
    }
  }
}

/// A tab using the camera, microphone, or screen share (`capture: {camera, microphone, screen}`):
/// a red video/mic/screen icon, always shown (not only on hover), like Safari's. A click emits
/// `stopCapture`; the owner turns them off.
@MainActor
final class CaptureButton {
  let button: IconButton
  let screenIcon: IconView
  init(_ emit: @escaping () -> Void) {
    button = IconButton(symbol: "video.fill", size: 22) { emit() }
    button.isHidden = true
    screenIcon = IconView()
    screenIcon.isHidden = true
  }
  func update(_ c: Value, screen: Bool) {
    let cam = c.str("camera"), mic = c.str("microphone")
    let camOn = cam == "active" || cam == "muted"
    let micOn = mic == "active" || mic == "muted"
    let hasCapture = camOn || micOn
    let on = hasCapture || screen
    button.isHidden = !on
    screenIcon.isHidden = !on || !screen || hasCapture  // show screen icon alone or camera/mic icon alone
    guard on else { return }
    if screen && !hasCapture {
      // Screen sharing only
      screenIcon.spec = "sf:rectangle.on.rectangle.angled.fill"
      screenIcon.setAccessibilityLabel("Turn Off Screen Share")
    } else {
      // Camera or mic only
      let camOn = cam == "active" || cam == "muted"
      let paused = (camOn ? cam : mic) == "muted"
      button.icon.spec = camOn ? (paused ? "sf:video.slash.fill" : "sf:video.fill") : (paused ? "sf:mic.slash.fill" : "sf:mic.fill")
      let what = camOn && micOn ? "Camera and Microphone" : camOn ? "Camera" : "Microphone"
      button.toolTip = "Turn Off " + what
      button.setAccessibilityLabel("Turn Off " + what)
    }
  }
  func apply(_ p: Palette) {
    button.apply(p)
    button.hoverFill = p.controlHoverFill
    button.tint = p.tokens.destructive.ns
    screenIcon.tint = p.tokens.destructive.ns
  }
}

/// Hover playback buttons for a tab playing (or paused) media: previous, play/pause, next. Shared
/// by tab rows and favorite tiles; `media` is the node's `{paused, next, previous}`.
@MainActor
final class MediaButtons {
  let previous: IconButton, playPause: IconButton, next: IconButton
  var all: [IconButton] { [previous, playPause, next] }
  init(_ emit: @escaping (String) -> Void) {
    previous = IconButton(symbol: "backward.fill", size: 22) { emit("previous") }
    playPause = IconButton(symbol: "pause.fill", size: 22) { emit("toggle") }
    next = IconButton(symbol: "forward.fill", size: 22) { emit("next") }
    previous.toolTip = "Previous Track"
    next.toolTip = "Next Track"
    all.forEach { $0.isHidden = true }
  }
  /// `skips`: room for previous / next too (a narrow favorite tile shows play/pause alone).
  func update(_ m: Value, show: Bool, skips: Bool = true) {
    let show = show && !m.isNull
    let paused = m.flag("paused")
    playPause.icon.spec = paused ? "sf:play.fill" : "sf:pause.fill"
    playPause.toolTip = paused ? "Play" : "Pause"
    playPause.isHidden = !show
    previous.isHidden = !show || !skips || !m.flag("previous")
    next.isHidden = !show || !skips || !m.flag("next")
  }
  func apply(_ p: Palette) {
    for b in all {
      b.apply(p)
      b.hoverFill = p.controlHoverFill
    }
  }
  var visible: [IconButton] { all.filter { !$0.isHidden } }
}

/// {type:"favoriteTile", id, icon, title, selected, audio, muted?, suspended?, badge?, media?: {paused, next, previous},
///  capture?: {camera, microphone}, screenCapture?: bool}  (stopCapture: the capture badge clicked)
/// actions: click, doubleClick, reorder, mute (speaker badge), media {action: toggle|next|previous}
/// `badge`: a short text chip at the bottom of the tile ("in 8m": a plugin's countdown).
/// `suspended`: the page was discarded; the icon dims until the page comes back.
/// `capture`: a red camera / mic button (stopCapture) while the page uses them.
/// `screenCapture`: a red screen share button when the page is sharing its screen.
/// `media`: while hovered, play/pause (and previous / next when the tile is wide enough) take the
/// icon's place, like a tab row's.
final class FavoriteTileNode: HoverNode {
  let icon = IconView()
  lazy var audio = SpeakerBadge { [weak self] in self?.emit("mute") }
  let chip = TextChip()
  lazy var media = MediaButtons { [weak self] a in self?.emit("media", ["action": .string(a)]) }
  lazy var capture = CaptureButton { [weak self] in self?.emit("stopCapture") }
  /// Shown while hovered (or `forceMedia`, for snapshots) when the tab has media.
  var forceMedia = false { didSet { updateMedia(); needsLayout = true } }
  static let skipsWidth: CGFloat = 3 * 22 + 8
  override var cornerRadius: CGFloat { Tokens.favoriteTileCornerRadius }
  override var baseFill: NSColor? { palette.tileFill }
  override var draggable: Bool { true }
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    addSubview(icon)
    addSubview(audio)
    addSubview(chip)
    media.all.forEach { addSubview($0) }
    addSubview(capture.button)
    addSubview(capture.screenIcon)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func hoverChanged() { updateMedia(); needsLayout = true }
  func updateMedia() {
    media.update(node["media"], show: hovering || forceMedia, skips: bounds.width >= Self.skipsWidth)
    icon.isHidden = !media.playPause.isHidden
  }
  override func update(_ v: Value) {
    super.update(v)
    icon.spec = v.str("icon")
    icon.fallbackLetter = v.str("title")
    audio.set(playing: v.flag("audio"), muted: v.flag("muted"))
    audio.isHidden = !(v.flag("audio") || v.flag("muted"))
    capture.update(v["capture"], screen: v.flag("screenCapture"))
    chip.text = v.str("badge")
    chip.isHidden = chip.text.isEmpty
    setAccessibilityValue(chip.text.isEmpty ? nil : chip.text)
    apply(r.palette)
    updateMedia()
    needsLayout = true
  }
  override func apply(_ p: Palette) {
    icon.tint = p.text
    icon.alphaValue = node.flag("suspended") ? 0.45 : 1  // a discarded tab's icon dims
    audio.apply(p); chip.apply(p)
    media.apply(p)
    capture.apply(p)
    needsDisplay = true
  }
  override func layout() {
    // The tile's width decides whether previous / next fit (it changes with the grid's columns).
    updateMedia()
    let s = Tokens.favoriteIconSize
    // With a chip, the icon moves up a little so both fit the tile.
    let lift: CGFloat = chip.isHidden ? 0 : 5
    icon.frame = NSRect(x: (bounds.width - s) / 2, y: (bounds.height - s) / 2 - lift, width: s, height: s)
    // The playback buttons, centered where the icon is.
    let shown = media.visible
    var bx = (bounds.width - CGFloat(shown.count) * 22) / 2
    for b in shown { b.frame = NSRect(x: bx, y: icon.frame.midY - 11, width: 22, height: 22); bx += 22 }
    // A small round badge in the top-right corner, clear of the icon (den's estimate).
    audio.frame = NSRect(x: bounds.width - 21, y: 3, width: 18, height: 18)
    // The capture badge in the top-left corner, opposite the speaker.
    let capOn = !capture.button.isHidden
    let scOn = !capture.screenIcon.isHidden
    let capX = capOn ? 2 : (scOn ? 2 : 0)
    capture.button.frame = NSRect(x: capX, y: 2, width: 20, height: 20)
    capture.screenIcon.frame = NSRect(x: scOn ? 2 : 0, y: 2, width: 20, height: 20)
    if !chip.isHidden {
      let w = min(bounds.width - 6, chip.width)
      chip.frame = NSRect(x: (bounds.width - w) / 2, y: bounds.height - TextChip.height - 3, width: w, height: TextChip.height)
    }
  }
}

/// A small accent capsule with a short text (a tile's countdown, a folder's "3 ✓"). With an
/// `action` it is a button (hover fill, pointer); without, a label.
@MainActor
final class TextChip: NSView, Themable, Hoverable {
  static let height: CGFloat = 15
  var hoverGroup: HoverGroup { .control }
  let label = makeLabel(size: 10, weight: .semibold)
  var action: (() -> Void)?
  var text = "" { didSet { label.stringValue = text; needsLayout = true } }
  /// `accent`: filled with the theme accent; otherwise a quiet neutral fill.
  var accent = true { didSet { apply(palette) } }
  private var fill = NSColor.controlAccentColor
  private var hoverFill = NSColor.controlAccentColor
  private var palette: Palette?
  var hovering = false { didSet { needsDisplay = true } }

  init() {
    super.init(frame: .zero)
    label.alignment = .center
    label.lineBreakMode = .byClipping
    addSubview(label)
  }
  required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { action == nil }
  var width: CGFloat { label.textWidth + 10 }

  func apply(_ p: Palette?) {
    guard let p else { return }
    palette = p
    fill = accent ? p.primaryButton : (p.dark ? Palette.snow(0.14) : Palette.ink(0.08))
    hoverFill = accent ? p.primaryButton.blended(withFraction: 0.15, of: p.dark ? .white : .black) ?? p.primaryButton
                       : (p.dark ? Palette.snow(0.22) : Palette.ink(0.14))
    label.textColor = accent ? p.onAccent : p.text
    needsDisplay = true
  }
  func apply(_ p: Palette) { apply(Optional(p)) }

  override func layout() {
    super.layout()
    label.frame = NSRect(x: 4, y: (bounds.height - 13) / 2, width: max(0, bounds.width - 8), height: 13)
  }
  override func draw(_ dirtyRect: NSRect) {
    (hovering && action != nil ? hoverFill : fill).setFill()
    NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    guard action != nil else { return }
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }
  override func mouseEntered(with event: NSEvent) { HoverTracker.refresh(window) }
  override func mouseExited(with event: NSEvent) { HoverTracker.refresh(window) }
  override func hitTest(_ point: NSPoint) -> NSView? { action == nil ? nil : super.hitTest(point) }
  override func mouseDown(with event: NSEvent) {}
  override func mouseUp(with e: NSEvent) {
    if bounds.contains(convert(e.locationInWindow, from: nil)) { action?() }
  }
  override func accessibilityPerformPress() -> Bool { action?(); return action != nil }
}

/// A small accent dot: something new in a row or a collapsed folder.
@MainActor
final class UnreadDot: NSView, Themable {
  private var color = NSColor.controlAccentColor
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  func apply(_ p: Palette) { color = p.primaryButton; needsDisplay = true }
  override func draw(_ dirtyRect: NSRect) {
    color.setFill()
    NSBezierPath(ovalIn: bounds).fill()
  }
}

/// The speaker on a tab row or favorite tile: shows that the tab plays audio (or is muted), and
/// mutes or unmutes it on click, like Arc. Hover fill, tooltip, and a quick cross-fade when the
/// state flips. `badge` draws it on a small round plate (favorite tiles).
@MainActor
final class SpeakerBadge: NSView, Themable, Hoverable {
  var hoverGroup: HoverGroup { .control }
  let icon = IconView()
  let action: () -> Void
  var badge = false
  private(set) var muted = false
  var hovering = false { didSet { needsDisplay = true } }
  private var pressed = false { didSet { needsDisplay = true } }
  private var fill = NSColor(white: 0, alpha: 0.06)
  private var hoverFill = NSColor(white: 0, alpha: 0.1)
  private var plate = NSColor.white

  init(badge: Bool = true, action: @escaping () -> Void) {
    self.action = action
    self.badge = badge
    super.init(frame: .zero)
    wantsLayer = true
    addSubview(icon)
    icon.wantsLayer = true
  }
  required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  func set(playing: Bool, muted m: Bool) {
    let spec = m ? "sf:speaker.slash.fill" : "sf:speaker.wave.2.fill"
    if spec != icon.spec, !icon.spec.isEmpty, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      let t = CATransition()
      t.type = .fade
      t.duration = 0.15
      icon.layer?.add(t, forKey: "flip")
    }
    icon.spec = spec
    muted = m
    toolTip = m ? "Unmute Tab" : "Mute Tab"
    setAccessibilityLabel(toolTip)
    setAccessibilityRole(.button)
  }

  func apply(_ p: Palette) {
    icon.tint = muted ? p.secondaryText : (badge ? p.accent : p.secondaryText)
    hoverFill = p.controlHoverFill
    fill = p.controlPressedFill
    plate = p.dark ? NSColor(white: 0.18, alpha: 0.95) : NSColor(white: 1, alpha: 0.95)
    needsDisplay = true
  }

  override func layout() {
    super.layout()
    let s = (bounds.height * (badge ? 0.58 : 0.66)).rounded()
    icon.frame = NSRect(x: (bounds.width - s) / 2, y: (bounds.height - s) / 2, width: s, height: s)
  }

  override func draw(_ dirtyRect: NSRect) {
    if badge {
      plate.setFill()
      NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
    }
    guard hovering || pressed else { return }
    (pressed ? fill : hoverFill).setFill()
    let r = badge ? bounds.height / 2 : 5
    NSBezierPath(roundedRect: bounds.insetBy(dx: badge ? 1 : 0, dy: badge ? 1 : 0), xRadius: r, yRadius: r).fill()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }
  override func mouseEntered(with event: NSEvent) { HoverTracker.refresh(window) }
  override func mouseExited(with event: NSEvent) { HoverTracker.refresh(window) }
  override func mouseDown(with event: NSEvent) { pressed = true }
  override func mouseUp(with e: NSEvent) {
    pressed = false
    if bounds.contains(convert(e.locationInWindow, from: nil)) { action() }
  }
  override func accessibilityPerformPress() -> Bool { action(); return true }
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
    // Icon only: the tooltip names the space and its ⌃N.
    toolTip = Shortcuts.tip(v.str("title"), v.str("shortcutFor"), fallback: v.str("shortcut"))
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

  /// While renaming, the row's icon is a button for the icon picker (Arc): a soft rounded fill
  /// marks it, and a click emits `pickIcon`. `iconPressed` swallows that click's mouse-up.
  var iconPressed = false
  func drawIconAffordance(_ icon: NSView, palette: Palette) {
    guard active else { return }
    let r = icon.frame.insetBy(dx: -4, dy: -4)
    palette.controlHoverFill.setFill()
    NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
  }
  /// True when the press hit the icon while renaming (and `pickIcon` was sent).
  func iconDown(_ icon: NSView, at p: NSPoint) -> Bool {
    guard active, icon.frame.insetBy(dx: -4, dy: -4).contains(p) else { return false }
    iconPressed = true
    owner.emit("pickIcon")
    return true
  }
  /// True when this mouse-up ends an icon press (nothing else should happen).
  func iconUp() -> Bool {
    defer { iconPressed = false }
    return iconPressed
  }

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

/// {type:"tabRow", id, title, icon, selected, audio, drift, closable=true, closeTitle?, indent?, muted?, suspended?, editing?, editText?, unread?,
///  media?: {paused, next, previous}, capture?: {camera, microphone}, screenCapture?: bool}
/// `capture`: a red camera / mic button (stopCapture) while the page uses them.
/// `screenCapture`: a red screen share badge when the page is sharing its screen.
/// `unread`: an accent dot on the right (a live folder's new item).
/// `suspended`: the page was discarded (its WebContent process exited); the icon dims until the
/// page comes back.
/// actions: click {modifiers?}, doubleClick, close, reset (favicon click while drifted), mute, contextMenu/menu, reorder,
/// dropOnContent, rename {title} / renameCancel (while `editing`), media {action: toggle|next|previous} (the hover
/// playback buttons of a tab with `media`)
/// dropOnContent, rename {title} / renameCancel / pickIcon (the icon clicked, while `editing`)
final class TabRowNode: HoverNode {
  let icon = IconView()
  let label = makeLabel()
  let drift = makeLabel("/", size: Tokens.tabRowFontSize, weight: .medium)
  lazy var audio = SpeakerBadge(badge: false) { [weak self] in self?.emit("mute") }
  lazy var close = IconButton(symbol: "xmark", size: 22) { [weak self] in self?.emit("close") }
  // Hover playback buttons for a tab with media (`media`): previous, play/pause, next.
  lazy var media = MediaButtons { [weak self] a in self?.emit("media", ["action": .string(a)]) }
  lazy var capture = CaptureButton { [weak self] in self?.emit("stopCapture") }
  var previous: IconButton { media.previous }
  var playPause: IconButton { media.playPause }
  var next: IconButton { media.next }
  var mediaButtons: [IconButton] { media.all }
  lazy var rename = RenameSupport(owner: self, label: label)
  let dot = UnreadDot()
  override var draggable: Bool { node.flag("draggable", true) && !rename.active }
  override class func fixedHeight(_ v: Value) -> CGFloat? { Tokens.tabRowHeight }
  override var busy: Bool { super.busy || rename.active }
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    [icon, drift, label, capture.button, capture.screenIcon, audio, dot, previous, playPause, next, close].forEach { addSubview($0) }
    close.isHidden = true
    dot.isHidden = true
  }
  required init?(coder: NSCoder) { fatalError() }
  var indent: CGFloat { CGFloat(node.num("indent", 0)) * Tokens.folderIndent }
  override var fillRect: NSRect { bounds.insetBy(dx: 0, dy: (bounds.height - 36) / 2) }  // spec §1: 212x36 highlight
  override func hoverChanged() {
    close.isHidden = !(hovering && node.flag("closable", true))
    updateMediaButtons()
    needsLayout = true
  }
  /// Shown while the row is hovered (or `forceMedia`, for snapshots) and the tab has media.
  var forceMedia = false { didSet { updateMediaButtons(); needsLayout = true } }
  func updateMediaButtons() { media.update(node["media"], show: (hovering || forceMedia) && !rename.active) }
  override func update(_ v: Value) {
    super.update(v)
    label.stringValue = v.str("title", "Untitled")
    icon.spec = v.str("icon")
    icon.fallbackLetter = v.str("title")
    drift.isHidden = !v.flag("drift")
    audio.set(playing: v.flag("audio"), muted: v.flag("muted"))
    audio.isHidden = !(v.flag("audio") || v.flag("muted"))
    capture.update(v["capture"], screen: v.flag("screenCapture"))
    close.toolTip = v.str("closeTitle", "Close Tab")
    dot.isHidden = !v.flag("unread")
    apply(r.palette)
    rename.update(v)
    updateMediaButtons()
    needsLayout = true
  }
  override func apply(_ p: Palette) {
    label.textColor = p.text
    label.font = .systemFont(ofSize: Tokens.tabRowFontSize, weight: node.flag("selected") ? .medium : .regular)
    rename.editor?.textColor = p.text
    drift.textColor = p.tertiaryText
    icon.tint = p.text
    icon.alphaValue = node.flag("suspended") ? 0.45 : 1  // a discarded tab's icon dims
    audio.apply(p)
    capture.apply(p)
    dot.apply(p)
    close.apply(p)
    close.hoverFill = p.controlHoverFill
    media.apply(p)
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
    if !audio.isHidden { audio.frame = NSRect(x: right - 22, y: (h - 22) / 2, width: 22, height: 22); right -= 24 }
    let capOn = !capture.button.isHidden || !capture.screenIcon.isHidden
    if capOn { capture.button.frame = NSRect(x: right - 22, y: (h - 22) / 2, width: 22, height: 22); capture.screenIcon.frame = capture.button.frame; right -= 24 }
    if !dot.isHidden { dot.frame = NSRect(x: right - 10, y: (h - 6) / 2, width: 6, height: 6); right -= 14 }
    for b in mediaButtons.reversed() where !b.isHidden { b.frame = NSRect(x: right - 22, y: (h - 22) / 2, width: 22, height: 22); right -= 22 }
    label.frame = NSRect(x: x, y: (h - 18) / 2, width: max(0, right - x), height: 18)
    rename.layout()
  }
  override func clicked(at p: NSPoint, event: NSEvent) {
    if node.flag("drift"), icon.frame.insetBy(dx: -4, dy: -4).contains(p) { emit("reset"); return }
    super.clicked(at: p, event: event)
  }
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    rename.drawIconAffordance(icon, palette: palette)
  }
  override func mouseDown(with event: NSEvent) {
    if rename.iconDown(icon, at: convert(event.locationInWindow, from: nil)) { return }
    super.mouseDown(with: event)
  }
  override func mouseUp(with event: NSEvent) {
    if rename.iconUp() { return }
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
  override class func fixedHeight(_ v: Value) -> CGFloat? { Tokens.tabRowHeight }
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
      s.label.stringValue = p.str("title").isEmpty ? "Untitled" : p.str("title")
      s.icon.spec = p.str("icon")
      s.icon.fallbackLetter = p.str("title")
    }
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
    close.hoverFill = p.controlHoverFill
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

/// {type:"folder", id, title, icon?, open, children, closedChildren?, style?: "group", pending?, reveal?, editing?, unread?, badge?}
/// - `unread`: a dot on the folder's icon (a collapsed live folder with something new).
/// - `badge`: a small chip before the chevron ("3 ✓"); clicking it emits `badge`.
/// - `closedChildren`: rows still shown while the folder is collapsed (its active tab).
/// - `style: "group"`: a Today group, drawn as a lighter rounded panel around the header and its
///   rows, with a bold name (dia-ui-spec §6).
/// - `pending`: a better name is on its way; a soft shimmer runs across the title (Reduce Motion:
///   the title dims instead). `reveal`: the new name just arrived; a colour sweep crosses it once.
/// actions: toggle, click, reorder (as target: position "into"), rename {title} / renameCancel (while `editing`), badge
/// actions: toggle, click, reorder (as target: position "into"), rename {title} / renameCancel / pickIcon (the icon
/// clicked, while `editing`)
final class FolderNode: NodeView {
  final class Header: HoverNode {
    let chevron = IconView()
    let icon = IconView()
    let label = makeLabel()
    let dot = UnreadDot()
    let chip = TextChip()
    lazy var rename = RenameSupport(owner: self, label: label)
    private(set) var shimmer: CAGradientLayer?
    override var draggable: Bool { !rename.active }
    override var fillRect: NSRect { bounds.insetBy(dx: 0, dy: (bounds.height - 36) / 2) }
    required init(renderer: Renderer) {
      super.init(renderer: renderer)
      wantsLayer = true
      [chevron, icon, label, dot, chip].forEach { addSubview($0) }
      dot.isHidden = true
      chip.isHidden = true
      chip.accent = false
      chip.action = { [weak self] in self?.emit("badge") }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func update(_ v: Value) {
      super.update(v)
      dot.isHidden = !v.flag("unread")
      chip.text = v.str("badge")
      chip.isHidden = chip.text.isEmpty
      chip.setAccessibilityLabel(chip.text)
      chip.setAccessibilityRole(.button)
      needsLayout = true
    }
    override func apply(_ p: Palette) {
      label.textColor = p.text
      label.font = .systemFont(ofSize: Tokens.tabRowFontSize, weight: node.str("style") == "group" ? .semibold : .regular)
      icon.tint = p.text
      chevron.tint = p.secondaryText
      dot.apply(p)
      chip.apply(p)
      needsDisplay = true
    }
    override func height(for w: CGFloat) -> CGFloat { Tokens.tabRowHeight }
    override func clicked(at p: NSPoint, event: NSEvent) { emit("toggle") }
    override func draw(_ dirtyRect: NSRect) {
      super.draw(dirtyRect)
      rename.drawIconAffordance(icon, palette: palette)
    }
    override func mouseDown(with event: NSEvent) {
      if rename.iconDown(icon, at: convert(event.locationInWindow, from: nil)) { return }
      super.mouseDown(with: event)
    }
    override func mouseUp(with event: NSEvent) {
      if rename.iconUp() { return }
      super.mouseUp(with: event)
    }
    override func layout() {
      let h = bounds.height, s = Tokens.tabRowIconSize
      let x = Tokens.tabRowPaddingX + CGFloat(node.num("indent", 0)) * Tokens.folderIndent
      icon.frame = NSRect(x: x, y: (h - s) / 2, width: s, height: s)
      dot.frame = NSRect(x: x + s - 4, y: (h - s) / 2 - 2, width: 7, height: 7)
      var room = bounds.width - x - s - 34
      if !chip.isHidden {
        let w = chip.width
        chip.frame = NSRect(x: bounds.width - 30 - w, y: (h - TextChip.height) / 2, width: w, height: TextChip.height)
        room -= w + 6
      }
      label.frame = NSRect(x: x + s + 8, y: (h - 17) / 2, width: max(0, room), height: 17)
      chevron.frame = NSRect(x: bounds.width - 22, y: (h - 10) / 2, width: 10, height: 10)
      rename.layout()
      if let g = shimmer { g.frame = textRect; g.mask?.frame = CGRect(origin: .zero, size: textRect.size) }
    }

    /// Where the title's glyphs are (the label is wider than its text).
    var textRect: CGRect {
      let w = min(label.frame.width, ceil(label.attributedStringValue.size().width) + 2)
      return CGRect(x: label.frame.minX, y: label.frame.minY, width: max(1, w), height: label.frame.height)
    }

    /// The title's glyphs as a mask, so effects tint only the text.
    func textMask() -> CALayer? {
      let r = CGRect(origin: .zero, size: textRect.size)
      guard r.width > 1, let rep = label.bitmapImageRepForCachingDisplay(in: r) else { return nil }
      label.cacheDisplay(in: r, to: rep)
      let m = CALayer()
      m.contents = rep.cgImage
      m.frame = r
      // The header's layer is flipped (a flipped view): draw the bitmap the right way up.
      if layer?.isGeometryFlipped == true || isFlipped { m.setAffineTransform(CGAffineTransform(scaleX: 1, y: -1)) }
      return m
    }

    func setPending(_ on: Bool) {
      let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      label.alphaValue = on && reduce ? 0.55 : 1
      guard on, !reduce else { shimmer?.removeFromSuperlayer(); shimmer = nil; return }
      layoutSubtreeIfNeeded()
      guard shimmer == nil, let layer, let mask = textMask() else { return }
      let g = CAGradientLayer()
      let hi = palette.dark ? NSColor(white: 1, alpha: 0.9) : NSColor(white: 1, alpha: 0.95)
      g.colors = [NSColor.clear.cgColor, hi.cgColor, NSColor.clear.cgColor]
      g.startPoint = CGPoint(x: 0, y: 0.5)
      g.endPoint = CGPoint(x: 1, y: 0.5)
      g.frame = textRect
      g.mask = mask
      g.locations = [1, 1.3, 1.6]  // at rest the band is past the text: a still frame shows the plain title
      let a = CABasicAnimation(keyPath: "locations")
      a.fromValue = [-0.6, -0.3, 0]
      a.toValue = [1, 1.3, 1.6]
      a.duration = Tokens.groupShimmerDuration
      a.repeatCount = .infinity
      g.add(a, forKey: "shimmer")
      layer.addSublayer(g)
      shimmer = g
    }

    /// The new name crosses in a sweep of colour, once (dia-ui-spec §6: about 0.4 s).
    func playReveal() {
      guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer else { return }
      layoutSubtreeIfNeeded()
      guard let mask = textMask() else { return }
      let g = CAGradientLayer()
      g.colors = [NSColor.clear, .systemPink, .systemOrange, .systemPurple, .systemBlue, .clear].map(\.cgColor)
      g.startPoint = CGPoint(x: 0, y: 0.5)
      g.endPoint = CGPoint(x: 1, y: 0.5)
      g.frame = textRect
      g.mask = mask
      g.locations = [1, 1.1, 1.2, 1.3, 1.4, 1.5]
      let a = CABasicAnimation(keyPath: "locations")
      a.fromValue = [-0.5, -0.4, -0.3, -0.2, -0.1, 0]
      a.toValue = [1, 1.1, 1.2, 1.3, 1.4, 1.5]
      a.duration = Tokens.groupRevealDuration
      a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      layer.addSublayer(g)
      CATransaction.begin()
      CATransaction.setCompletionBlock { g.removeFromSuperlayer() }
      g.add(a, forKey: "reveal")
      CATransaction.commit()
    }
    /// Whether the shimmer is running (tests, snapshots).
    var shimmering: Bool { shimmer != nil }
  }
  lazy var header = Header(renderer: r)
  let panel = NSView()
  var kids: [NodeView] = []
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    panel.wantsLayer = true
    panel.layer?.cornerRadius = Tokens.groupCornerRadius
    panel.layer?.cornerCurve = .continuous
    panel.isHidden = true
    addSubview(panel)
    addSubview(header)
  }
  required init?(coder: NSCoder) { fatalError() }
  var open: Bool { node.flag("open") }
  var group: Bool { node.str("style") == "group" }
  override func update(_ v: Value) {
    let wasPending = node.flag("pending"), wasReveal = node.flag("reveal"), oldTitle = node.str("title")
    super.update(v)
    header.update(v)
    header.label.stringValue = v.str("title", "Folder")
    header.rename.update(v)
    header.icon.spec = v.str("icon", open ? "sf:folder" : "sf:folder.fill")
    header.chevron.spec = open ? "sf:chevron.down" : "sf:chevron.right"
    let indent = v.num("indent", 0) + 1
    let children = (open ? v.list("children") : v.list("closedChildren")).map { $0.with("indent", .double(indent)) }
    kids = r.reconcile(children, existing: kids, in: self)
    panel.isHidden = !group
    apply(r.palette)
    header.needsLayout = true
    if v.flag("pending") != wasPending || (v.flag("pending") && oldTitle != v.str("title")) {
      header.setPending(false)
      if v.flag("pending") { header.setPending(true) }
    }
    if v.flag("reveal") && !wasReveal { header.playReveal() }
    needsLayout = true
  }
  override func apply(_ p: Palette) {
    header.apply(p)
    panel.layer?.backgroundColor = p.groupFill.cgColor
  }
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
    // The panel spans the header's highlight top to the last row's highlight bottom.
    let inset = (Tokens.tabRowHeight - 36) / 2
    panel.frame = NSRect(x: 0, y: inset, width: bounds.width, height: max(0, y - Tokens.tabRowSpacing - 2 * inset))
  }
}

/// Pinned/today divider with an optional action. {type:"divider", id, action?: "Clear",
/// secondary?: {id, title, icon?, always?}} -> action "clear", or the secondary's `id`.
/// The secondary button (Arc's "Tidy") sits left of the action and shows only while the divider
/// is hovered, unless `always` (e.g. while it's busy).
final class DividerNode: HoverNode {
  let button = makeLabel(size: 11, weight: .medium)
  let arrow = IconView()
  let second = makeLabel(size: 11, weight: .medium)
  let secondIcon = IconView()
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    addSubview(arrow)
    addSubview(button)
    addSubview(secondIcon)
    addSubview(second)
  }
  required init?(coder: NSCoder) { fatalError() }
  override var fillRect: NSRect { .zero }
  override func hoverChanged() {
    updateSecondary()
    apply(r.palette)
  }
  override func update(_ v: Value) {
    super.update(v)
    button.stringValue = v.str("action")
    button.isHidden = button.stringValue.isEmpty
    arrow.spec = "sf:arrow.down"
    arrow.isHidden = button.isHidden
    second.stringValue = v["secondary"].str("title")
    secondIcon.spec = v["secondary"].str("icon")
    updateSecondary()
    needsLayout = true
  }
  var hasSecondary: Bool { !node["secondary"].str("id").isEmpty && !second.stringValue.isEmpty }
  /// Hover-only, like Arc's Tidy; `always` keeps it up (a busy "Tidying…").
  var secondaryShown: Bool { hasSecondary && (hovering || node["secondary"].flag("always")) }
  func updateSecondary() {
    second.isHidden = !secondaryShown
    secondIcon.isHidden = second.isHidden || secondIcon.spec.isEmpty
    needsLayout = true
    needsDisplay = true
  }
  override func apply(_ p: Palette) {
    button.textColor = hovering ? p.text : p.secondaryText
    arrow.tint = button.textColor ?? p.secondaryText
    second.textColor = p.secondaryText
    secondIcon.tint = p.secondaryText
    needsDisplay = true
  }
  override func height(for w: CGFloat) -> CGFloat { Tokens.dividerHeight }
  var secondMinX: CGFloat { secondIcon.isHidden ? second.frame.minX : secondIcon.frame.minX }
  var lineEnd: CGFloat {
    if !second.isHidden { return secondMinX - 8 }
    return button.isHidden ? bounds.width - 8 : bounds.width - button.textWidth - 30
  }
  override func layout() {
    let bw = ceil(button.textWidth) + 4
    button.frame = NSRect(x: bounds.width - bw - 6, y: (bounds.height - 14) / 2, width: bw, height: 14)
    arrow.frame = NSRect(x: button.frame.minX - 13, y: (bounds.height - 9) / 2, width: 9, height: 9)
    let right = button.isHidden ? bounds.width - 6 : arrow.frame.minX - 12
    let sw = ceil(second.textWidth) + 4
    second.frame = NSRect(x: right - sw, y: (bounds.height - 14) / 2, width: sw, height: 14)
    secondIcon.frame = NSRect(x: second.frame.minX - 13, y: (bounds.height - 10) / 2, width: 10, height: 10)
  }
  override func draw(_ dirtyRect: NSRect) {
    palette.divider.setFill()
    NSRect(x: 8, y: (bounds.height / 2).rounded(), width: max(0, lineEnd - 8), height: 0.5).fill()  // spec §1: 0.5 pt
  }
  override func clicked(at p: NSPoint, event: NSEvent) {
    if !second.isHidden, p.x >= secondMinX - 4, p.x <= second.frame.maxX + 4 {
      emit(node["secondary"].str("id"))
      return
    }
    if !button.isHidden, p.x > arrow.frame.minX - 4 { emit("clear") }
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
