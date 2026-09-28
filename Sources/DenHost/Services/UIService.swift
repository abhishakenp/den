import AppKit
import CordisValue

/// `ui` service: the Arc UI toolkit, rendered natively from `Value` trees.
///
/// Methods:
///   set {slot, tree, page?}      slots: sidebar.header, sidebar.favorites, sidebar.spaceHeader*, sidebar.pinned*,
///                                sidebar.today*, sidebar.footer, overlay.commandBar, overlay.peek, dialog, toast
///                                (* = per space page; `page` defaults to the current page). tree null clears.
///   setPages {count, current?}   number of space pages in the swipeable sidebar pager
///   showPage {page, animated?}   slide to a page (also blends the window theme)
///   get                          -> {page, pages, overlays: [slot], cards: [id]}
///   card {id, tree|null, anchor?, rect?, place?, width?, gap?, swap?, graceMs?}
///                                a generic popover card (Card.swift; docs/host-api.md "ui.card"):
///                                next to the node `anchor` (hover intent: shown while that node is hovered),
///                                or below a window `rect` {x, y, w, h} (top-left origin). tree null closes it.
///   hoverIntent {redwell?}        hover intent options (a second dwell before swapping cards)
/// Event: ui.action {id, action, value}. Node actions are documented on each node type;
///   sidebar-level: {id:"sidebar", action:"page", value:n} after a swipe, {id:"sidebar", action:"doubleClick"}.
@MainActor
public final class UIService: HostService {
  public let name = "ui"
  let host: ServiceHost
  let wc: DenWindowController
  let content: ContentService?
  public let sidebarView = SidebarView()
  var renderer: Renderer!
  let drag: DragController
  lazy var commandBar = CommandBarView(emit: { [weak self] in self?.emit($0, $1, $2) })
  lazy var dialog = DialogView(emit: { [weak self] in self?.emit($0, $1, $2) })
  let commandBackdrop = BackdropView()
  let dialogBackdrop = ModalBackdrop(dim: Tokens.dialogBackdropAlpha)
  var toasts: [ToastView] = []
  lazy var library = LibraryView(emit: { [weak self] in self?.emit($0, $1, $2) })
  let libraryBackdrop = BackdropView()
  var libraryOpen = false
  let popover = PopoverPanel()
  let popoverBackdrop = BackdropView()
  var popoverOpen = false
  var commandBarOpen = false
  var dialogOpen = false
  /// `overlay.briefing`, `overlay.connections`, `overlay.passwords` and `overlay.extensions`: one `SheetView` each (in that order, bottom to top).
  // thin-host: feature-specific, migrate to plugin (`overlay.passwords` is a feature-named slot; a generic sheet slot per plugin would do)
  static let sheetSlots = ["overlay.briefing", "overlay.connections", "overlay.passwords", "overlay.extensions"]
  var sheets: [String: SheetView] = [:]
  var sheetBackdrops: [String: BackdropView] = [:]
  /// `ui.card`: generic popover cards and the hover intent of nodes with `hoverIntent` (Card.swift).
  public private(set) var cards: CardController!

  public init(host: ServiceHost, window: DenWindowController, content: ContentService?) {
    self.host = host
    self.wc = window
    self.content = content
    let emitter: (String, String, Value) -> Void = { id, action, value in
      host.emit("ui.action", ["id": .string(id), "action": .string(action), "value": value])
    }
    drag = DragController(emit: emitter)
    renderer = Renderer(palette: Palette(theme: wc.currentTheme, dark: wc.isDark), emit: emitter)
    renderer.drag = drag
    drag.root = sidebarView
    drag.contentFrame = { [weak wc] in wc.map { $0.contentArea.convert($0.contentArea.bounds, to: nil) } ?? .zero }
    drag.accent = { [weak self] in self?.renderer.palette.accentStrong ?? .controlAccentColor }
    drag.overlay = { [weak wc] in wc?.overlays }
    content?.accent = renderer.palette.accentStrong
    cards = CardController(renderer: renderer, emit: emitter)
    cards.overlays = wc.overlays
    cards.anchorFrame = { [weak self] id in self?.anchorFrame(id) }
    // Cards next to a sidebar node start right of the sidebar (Dia's rows span it: row maxX + 3).
    cards.clearX = { [weak self] id in
      guard let self, self.isInSidebar(id) else { return nil }
      let wc = self.wc
      let right = wc.sidebarHidden ? (wc.sidebarRevealed ? wc.sidebar.frame.maxX : 0) : wc.sidebar.frame.maxX
      return wc.overlays.convert(NSPoint(x: right, y: 0), from: wc.sidebar.superview).x
    }
    cards.windowRect = { [weak wc] r in
      guard let wc, let content = wc.window.contentView else { return r }
      // Window coordinates with a top-left origin (the content view spans the window) -> the
      // window's own bottom-left base coordinates -> overlays.
      let base = NSRect(x: r.minX, y: content.frame.height - r.maxY, width: r.width, height: r.height)
      return wc.overlays.convert(base, from: nil)
    }
    renderer.hover = cards

    wc.sidebar.body.addSubview(sidebarView)
    sidebarView.frame = wc.sidebar.body.bounds
    sidebarView.autoresizingMask = [.width, .height]
    sidebarView.pager.ensurePages(1)
    sidebarView.pager.onProgress = { [weak wc] a, b, t in wc?.blendTheme(from: a, to: b, progress: t) }
    sidebarView.pager.onCommit = { [weak self] p in
      HoverTracker.setNeedsRefresh(self?.wc.window)
      self?.wc.showTheme(for: p)
      self?.refreshPalette()
      emitter("sidebar", "page", .int(Int64(p)))
    }
    sidebarView.onDoubleClickEmpty = { emitter("sidebar", "doubleClick", .null) }

    commandBackdrop.onClick = { emitter("commandBar", "dismiss", .null) }
    libraryBackdrop.wantsLayer = true
    libraryBackdrop.layer?.backgroundColor = NSColor(white: 0, alpha: Tokens.libraryBackdropAlpha).cgColor
    libraryBackdrop.onClick = { [weak self] in self?.library.send("dismiss") }
    let prev = wc.onLayout
    wc.onLayout = { [weak self] in prev?(); self?.layoutOverlays() }
    wc.background.onAppearanceChange = { [weak self] in self?.refreshPalette() }
  }

  func emit(_ id: String, _ action: String, _ value: Value) {
    host.emit("ui.action", ["id": .string(id), "action": .string(action), "value": value])
  }

  public func handle(method: String, args: Value) -> Value {
    switch method {
    case "set":
      return set(args.str("slot"), args["tree"], page: args["page"].int.map(Int.init))
    case "setPages":
      let n = max(1, Int(args.num("count", 1)))
      sidebarView.pager.ensurePages(n)
      if let c = args["current"].int { sidebarView.pager.show(Int(c), animated: false); wc.showTheme(for: Int(c)); refreshPalette() }
      sidebarView.needsLayout = true
    case "showPage":
      let p = Int(args.num("page", 0))
      sidebarView.pager.show(p, animated: args.flag("animated", true))
      wc.showTheme(for: sidebarView.pager.current)
      refreshPalette()
    case "tokens":
      return Self.tokens(renderer.palette)
    case "get":
      var overlays: [Value] = []
      if commandBarOpen { overlays.append("overlay.commandBar") }
      if dialogOpen { overlays.append("dialog") }
      if popoverOpen { overlays.append("popover") }
      if libraryOpen { overlays.append("overlay.library") }
      for s in Self.sheetSlots where sheets[s] != nil { overlays.append(.string(s)) }
      let shown = cards.cards.filter { $0.value.superview != nil && !$0.value.leaving }.map(\.key).sorted().map { Value.string($0) }
      return ["page": .int(Int64(sidebarView.pager.current)), "pages": .int(Int64(sidebarView.pager.pages.count)), "overlays": .array(overlays),
              "cards": .array(shown)]
    case "card":
      let r = cards.set(args)
      HoverTracker.setNeedsRefresh(wc.window)
      return r
    case "hoverIntent":
      if let b = args["redwell"].bool { cards.intent.redwell = b }
    case "menu":
      return showMenu(args.str("id"), args.list("items"))
    default:
      return .error("ui: unknown method '\(method)'")
    }
    return .ok
  }

  /// `menu {id, items}`: the context menu of a node that carries no `menu` of its own (a right-click
  /// on it emitted `contextMenu`), built by the plugin only when asked, so a sidebar of hundreds of
  /// rows holds no menus. Shown at the pointer on the next turn; a pick emits the node's `menu`.
  var lastMenu: NSMenu?
  func showMenu(_ id: String, _ items: [Value]) -> Value {
    guard !items.isEmpty, let n = Self.node(id, in: sidebarView) else { return .error("ui: no node '\(id)'") }
    let m = ContextMenu.build(items, target: n, action: #selector(NodeView.menuPicked(_:)))
    lastMenu = m
    DispatchQueue.main.async { [weak n] in
      guard let n, let w = n.window, !TestMode.active else { return }
      m.popUp(positioning: nil, at: n.convert(w.mouseLocationOutsideOfEventStream, from: nil), in: n)
    }
    return ["shown": true]
  }

  static func node(_ id: String, in v: NSView) -> NodeView? {
    if let n = v as? NodeView, n.nodeId == id { return n }
    for s in v.subviews { if let f = node(id, in: s) { return f } }
    return nil
  }

  func set(_ slot: String, _ tree: Value, page: Int?) -> Value {
    // Anything modal (command bar, dialogs, sheets, popovers) closes the hover card.
    if !tree.isNull, slot.hasPrefix("overlay.") || slot == "dialog" || slot == "popover" { cards.hideAll() }
    switch slot {
    case "overlay.commandBar": setCommandBar(tree)
    case "dialog": setDialog(tree)
    case "toast": if !tree.isNull { showToast(tree) }
    case "popover": setPopover(tree)
    case "overlay.library": setLibrary(tree)
    case _ where Self.sheetSlots.contains(slot): setSheet(slot, tree)
    case "overlay.peek":
      _ = content?.handle(method: "peek", args: tree.isNull ? .null : ["webview": tree["webview"], "title": tree["title"]])
    default:
      guard slot.hasPrefix("sidebar."), let s = sidebarView.slot(slot, page: page ?? sidebarView.pager.current) else {
        return .error("ui: unknown slot '\(slot)'")
      }
      s.set(tree, renderer: renderer)
      sidebarView.needsLayout = true
    }
    // Rows were re-rendered, reused or reordered: hover follows the pointer, not stale flags.
    HoverTracker.setNeedsRefresh(wc.window)
    return .ok
  }

  /// Called after the palette (theme tokens) changed: Settings and other windows re-theme.
  public var onPalette: ((Palette) -> Void)?

  /// Re-themes every surface, but only when the tokens actually changed (a space switch between
  /// two identical themes, or a repeated setTheme, redraws nothing).
  public func refreshPalette() {
    let np = Palette(theme: wc.currentTheme, dark: wc.isDark)
    guard np != renderer.palette else { return }
    renderer.palette = np
    content?.accent = renderer.palette.accentStrong
    sidebarView.applyPaletteRecursively(renderer.palette)
    wc.overlays.applyPaletteRecursively(renderer.palette)
    cards.applyPalette(renderer.palette)
    onPalette?(renderer.palette)
  }

  // MARK: Overlays

  func setCommandBar(_ tree: Value) {
    if tree.isNull {
      guard commandBarOpen else { return }
      commandBarOpen = false
      commandBackdrop.removeFromSuperview()
      commandBar.removeFromSuperview()
      ModalFocus.dismiss(commandBar)
      return
    }
    commandBar.update(tree, palette: renderer.palette)
    if !commandBarOpen {
      commandBarOpen = true
      wc.overlays.addSubview(commandBackdrop)
      wc.overlays.addSubview(commandBar)
      layoutOverlays()
      ModalFocus.present(commandBar) { [weak self] in self?.commandBar.input }
      commandBar.input.currentEditor()?.selectAll(nil)
      // Spec §2/§7: the command bar appears and disappears in one frame, no animation.
    }
    layoutOverlays()
  }

  func setDialog(_ tree: Value) {
    if tree.isNull {
      guard dialogOpen else { return }
      dialogOpen = false
      ModalFocus.dismiss(dialog)
      // Elevation.swift: a quick fade and settle, then the views go (unless a new dialog came).
      Elevation.animateOut(dialog, backdrop: dialogBackdrop) { [weak self] in
        guard let self, !self.dialogOpen else { return }
        self.dialogBackdrop.removeFromSuperview()
        self.dialog.removeFromSuperview()
        Elevation.reset(self.dialog, self.dialogBackdrop)
      }
      return
    }
    dialog.update(tree, palette: renderer.palette)
    let isNew = !dialogOpen
    if isNew {
      dialogOpen = true
      Elevation.reset(dialog, dialogBackdrop)
      wc.overlays.addSubview(dialogBackdrop)
      wc.overlays.addSubview(dialog)
    }
    ModalFocus.present(dialog) { [weak self] in self?.dialog.focusTarget }
    layoutOverlays()
    if isNew {
      // Blur what's behind (one snapshot) under the spec's α0.55 dim; spring the dialog in.
      if let root = wc.window.contentView { dialogBackdrop.captureBlur(root: root, hiding: [wc.overlays]) }
      Elevation.animateIn(dialog, backdrop: dialogBackdrop)
    }
  }

  func showToast(_ tree: Value) {
    // A toast with an `id` replaces the one showing with that id; `dismiss: true` only removes it.
    let id = tree.str("id")
    if !id.isEmpty {
      for old in toasts where old.toastId == id { old.removeFromSuperview() }
      toasts.removeAll { $0.toastId == id }
      layoutOverlays()
      if tree.flag("dismiss") { return }
    }
    let t = ToastView()
    t.toastId = id
    t.update(tree, palette: renderer.palette)
    wc.overlays.addSubview(t)
    toasts.append(t)
    layoutOverlays()
    let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    if !reduce {
      t.alphaValue = 0
      let final = t.frame
      t.frame = final.offsetBy(dx: 0, dy: -8)
      NSAnimationContext.runAnimationGroup { c in
        c.duration = 0.22  // estimate
        c.timingFunction = CAMediaTimingFunction(name: .easeOut)
        t.animator().alphaValue = 1
        t.animator().frame = final
      }
    }
    let ms = Int(tree.num("duration", Double(Tokens.toastDefaultDurationMs)))
    let dismiss: () -> Void = { [weak self, weak t] in
      guard let t, t.superview != nil, t.alphaValue > 0 else { return }
      NSAnimationContext.runAnimationGroup({ c in
        c.duration = 0.2
        t.animator().alphaValue = 0
      }, completionHandler: {
        MainActor.assumeIsolated {
          t.removeFromSuperview()
          self?.toasts.removeAll { $0 === t }
          self?.layoutOverlays()
        }
      })
    }
    if t.hasAction {
      let id = tree.str("id")
      t.onAction = { [weak self] in
        self?.host.emit("ui.action", ["id": .string(id), "action": "toast"])
        dismiss()
      }
    }
    if ms > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) { dismiss() } }
  }

  /// `overlay.library` slot: the Archive / Library sheet over the content area.
  func setLibrary(_ tree: Value) {
    if tree.isNull {
      guard libraryOpen else { return }
      libraryOpen = false
      libraryBackdrop.removeFromSuperview()
      library.removeFromSuperview()
      library.node = .null
      ModalFocus.dismiss(library)
      return
    }
    library.update(tree, palette: renderer.palette)
    if !libraryOpen {
      libraryOpen = true
      // Below dialogs, so "Clear Archive" can confirm on top of the sheet.
      if dialogOpen {
        wc.overlays.addSubview(libraryBackdrop, positioned: .below, relativeTo: dialogBackdrop)
        wc.overlays.addSubview(library, positioned: .below, relativeTo: dialogBackdrop)
      } else {
        wc.overlays.addSubview(libraryBackdrop)
        wc.overlays.addSubview(library)
      }
      layoutOverlays()
      ModalFocus.present(library) { [weak self] in self?.library.input }
    }
    layoutOverlays()
  }

  /// `overlay.briefing` / `overlay.connections`: a `sheet` tree (see Sheet.swift). The `page` style
  /// covers the content area with no dim; the `sheet` style is a centered panel over a dim whose
  /// click emits `dismiss`. Connections stacks above briefing; dialogs stay above both.
  func setSheet(_ slot: String, _ tree: Value) {
    if tree.isNull {
      guard let v = sheets.removeValue(forKey: slot) else { return }
      v.removeFromSuperview()
      sheetBackdrops.removeValue(forKey: slot)?.removeFromSuperview()
      ModalFocus.dismiss(v)
      return
    }
    let isNew = sheets[slot] == nil
    let v = sheets[slot] ?? SheetView(renderer: renderer, emit: { [weak self] in self?.emit($0, $1, $2) })
    sheets[slot] = v
    v.update(tree, palette: renderer.palette)
    let wantsDim = tree.str("style", "sheet") == "sheet"
    if wantsDim, sheetBackdrops[slot] == nil {
      let b = BackdropView()
      b.wantsLayer = true
      b.layer?.backgroundColor = NSColor(white: 0, alpha: Tokens.libraryBackdropAlpha).cgColor
      sheetBackdrops[slot] = b
    } else if !wantsDim {
      sheetBackdrops.removeValue(forKey: slot)?.removeFromSuperview()
    }
    sheetBackdrops[slot]?.onClick = { [weak v] in v?.send("dismiss") }
    // Order: briefing, then connections, all below a dialog.
    var views: [NSView] = []
    for s in Self.sheetSlots {
      if let b = sheetBackdrops[s] { views.append(b) }
      if let sv = sheets[s] { views.append(sv) }
    }
    for x in views {
      if dialogOpen {
        wc.overlays.addSubview(x, positioned: .below, relativeTo: dialogBackdrop)
      } else {
        wc.overlays.addSubview(x)
      }
    }
    layoutOverlays()
    if isNew { ModalFocus.present(v) }
  }

  func layoutSheets(in b: NSRect) {
    guard !sheets.isEmpty else { return }
    let area = wc.overlays.convert(wc.contentArea.frame, from: wc.contentArea.superview)
    for (slot, v) in sheets {
      sheetBackdrops[slot]?.frame = b
      if v.isPage {
        v.frame = area
      } else {
        let w = min(Tokens.sheetWidth, area.width - 2 * Tokens.sheetInset)
        let maxH = max(160, area.height - 2 * Tokens.sheetInset)
        let h = min(maxH, v.contentHeight(width: w))
        v.frame = NSRect(x: (area.midX - w / 2).rounded(), y: (area.minY + Tokens.sheetInset + max(0, (maxH - h) * 0.35)).rounded(), width: w, height: h)
      }
      v.needsLayout = true
    }
  }

  /// `popover` slot: {type, id, anchor?, ...}. The popover opens just right of the sidebar, next to
  /// the node whose id is `anchor` (spec §4). A click outside emits `dismiss` for the content id.
  func setPopover(_ tree: Value) {
    if tree.isNull {
      popoverOpen = false
      popoverBackdrop.removeFromSuperview()
      popover.removeFromSuperview()
      popover.content?.removeFromSuperview()
      popover.content = nil
      ModalFocus.dismiss(popover)
      return
    }
    popover.anchor = tree.str("anchor")
    popover.content = renderer.reconcile([tree], existing: popover.content.map { [$0] } ?? [], in: popover.surface).first
    popoverBackdrop.onClick = { [weak self] in self?.emit(tree.str("id", "popover"), "dismiss", .null) }
    if !popoverOpen {
      popoverOpen = true
      wc.overlays.addSubview(popoverBackdrop)
      wc.overlays.addSubview(popover)
      popover.apply(renderer.palette)
    }
    layoutOverlays()
    ModalFocus.present(popover) { [weak self] in self?.popover.content }
  }

  /// True when the node `id` is rendered in the sidebar.
  func isInSidebar(_ id: String) -> Bool { findNode(id, in: sidebarView) != nil }

  func findNode(_ id: String, in v: NSView) -> NodeView? {
    if let n = v as? NodeView, n.nodeId == id, !n.isHiddenOrHasHiddenAncestor { return n }
    for s in v.subviews { if let f = findNode(id, in: s) { return f } }
    return nil
  }

  /// Frame of a rendered sidebar node (by id) in overlay coordinates.
  func anchorFrame(_ id: String) -> NSRect? {
    guard !id.isEmpty else { return nil }
    func find(_ v: NSView) -> NodeView? {
      if let n = v as? NodeView, n.nodeId == id, !n.isHiddenOrHasHiddenAncestor { return n }
      for s in v.subviews { if let f = find(s) { return f } }
      return nil
    }
    guard let n = find(sidebarView) else { return nil }
    return wc.overlays.convert(n.bounds, from: n)
  }

  func layoutPopover(in b: NSRect) {
    guard popoverOpen else { return }
    let size = popover.contentSize
    let sidebarRight = wc.sidebarHidden ? (wc.sidebarRevealed ? wc.sidebar.frame.maxX : 0) : wc.sidebar.frame.maxX
    let x = sidebarRight + Tokens.themePickerSidebarGap
    let top = (anchorFrame(popover.anchor)?.minY ?? 80) + Tokens.themePickerAnchorOffsetY
    let y = min(max(top, 10), max(10, b.height - size.height - 10))
    popover.frame = NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
  }

  func layoutOverlays() {
    let b = wc.overlays.bounds
    popoverBackdrop.frame = b
    layoutPopover(in: b)
    libraryBackdrop.frame = b
    layoutSheets(in: b)
    if libraryOpen {
      let area = wc.overlays.convert(wc.contentArea.frame, from: wc.contentArea.superview)
      let w = min(Tokens.libraryWidth, area.width - 2 * Tokens.libraryInset)
      let h = max(200, area.height - 2 * Tokens.libraryInset)
      library.frame = NSRect(x: (area.midX - w / 2).rounded(), y: (area.minY + Tokens.libraryInset).rounded(), width: w, height: h)
    }
    commandBackdrop.frame = b
    dialogBackdrop.frame = b
    if commandBarOpen {
      let w = min(Tokens.commandBarWidth, b.width - 80)
      let h = commandBar.contentHeight
      commandBar.frame = NSRect(x: ((b.width - w) / 2).rounded(), y: (b.height * Tokens.commandBarTopRatio).rounded(), width: w, height: h)
      commandBar.layer?.setAffineTransform(.identity)
    }
    if dialogOpen {
      let w = Tokens.dialogWidth, h = dialog.contentHeight
      dialog.frame = NSRect(x: ((b.width - w) / 2).rounded(), y: ((b.height - h) / 2 - 20).rounded(), width: w, height: h)
    }
    cards.layout()
    // Spec §6: toasts are anchored to the window's top-right corner.
    var y = Tokens.toastTopInset
    for t in toasts {
      let w = t.contentWidth, h = Tokens.toastHeight
      t.frame = NSRect(x: (b.width - Tokens.toastRightInset - w).rounded(), y: y, width: w, height: h)
      y += h + 8
    }
  }
}

// MARK: - Tokens for web content

extension UIService {
  /// `ui.tokens`: den's theme tokens (`ThemeTokens`: space theme + appearance, contrast-checked)
  /// as CSS colors, for UI a plugin draws inside a web page (a reader view, a picker bar):
  /// `{dark, bg, panel, text, secondary, border, hover, accent, onAccent, mark, shadow}`.
  static func tokens(_ p: Palette) -> Value {
    let t = p.tokens
    func css(_ c: RGB, _ a: CGFloat = 1) -> Value {
      let k = c.clamped
      return .string(String(format: "rgba(%d,%d,%d,%.3f)", Int((k.r * 255).rounded()), Int((k.g * 255).rounded()), Int((k.b * 255).rounded()), a))
    }
    return [
      "dark": .bool(t.dark), "bg": css(t.surface), "panel": css(t.elevated, 0.92), "text": css(t.textPrimary), "secondary": css(t.textSecondary),
      "border": css(t.hairline.rgb, t.hairline.a), "hover": css(t.hover.rgb, t.hover.a), "accent": css(t.accent), "onAccent": css(t.onAccent),
      "mark": css(t.accent, 0.28), "shadow": css(t.shadow.rgb, t.shadow.a),
    ]
  }
}
