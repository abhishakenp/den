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
///   get                          -> {page, pages, overlays: [slot]}
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
  let dialogBackdrop = BackdropView()
  var toasts: [ToastView] = []
  var commandBarOpen = false
  var dialogOpen = false

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

    wc.sidebar.body.addSubview(sidebarView)
    sidebarView.frame = wc.sidebar.body.bounds
    sidebarView.autoresizingMask = [.width, .height]
    sidebarView.pager.ensurePages(1)
    sidebarView.pager.onProgress = { [weak wc] a, b, t in wc?.blendTheme(from: a, to: b, progress: t) }
    sidebarView.pager.onCommit = { [weak self] p in
      self?.wc.showTheme(for: p)
      self?.refreshPalette()
      emitter("sidebar", "page", .int(Int64(p)))
    }
    sidebarView.onDoubleClickEmpty = { emitter("sidebar", "doubleClick", .null) }

    commandBackdrop.onClick = { emitter("commandBar", "dismiss", .null) }
    dialogBackdrop.wantsLayer = true
    dialogBackdrop.layer?.backgroundColor = NSColor(white: 0, alpha: Tokens.dialogBackdropAlpha).cgColor
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
    case "get":
      var overlays: [Value] = []
      if commandBarOpen { overlays.append("overlay.commandBar") }
      if dialogOpen { overlays.append("dialog") }
      return ["page": .int(Int64(sidebarView.pager.current)), "pages": .int(Int64(sidebarView.pager.pages.count)), "overlays": .array(overlays)]
    default:
      return .error("ui: unknown method '\(method)'")
    }
    return .ok
  }

  func set(_ slot: String, _ tree: Value, page: Int?) -> Value {
    switch slot {
    case "overlay.commandBar": setCommandBar(tree)
    case "dialog": setDialog(tree)
    case "toast": if !tree.isNull { showToast(tree) }
    case "overlay.peek":
      _ = content?.handle(method: "peek", args: tree.isNull ? .null : ["webview": tree["webview"], "title": tree["title"]])
    default:
      guard slot.hasPrefix("sidebar."), let s = sidebarView.slot(slot, page: page ?? sidebarView.pager.current) else {
        return .error("ui: unknown slot '\(slot)'")
      }
      s.set(tree, renderer: renderer)
      sidebarView.needsLayout = true
    }
    return .ok
  }

  public func refreshPalette() {
    renderer.palette = Palette(theme: wc.currentTheme, dark: wc.isDark)
    sidebarView.applyPaletteRecursively(renderer.palette)
    wc.overlays.applyPaletteRecursively(renderer.palette)
  }

  // MARK: Overlays

  func setCommandBar(_ tree: Value) {
    if tree.isNull {
      guard commandBarOpen else { return }
      commandBarOpen = false
      commandBackdrop.removeFromSuperview()
      commandBar.removeFromSuperview()
      return
    }
    commandBar.update(tree, palette: renderer.palette)
    if !commandBarOpen {
      commandBarOpen = true
      wc.overlays.addSubview(commandBackdrop)
      wc.overlays.addSubview(commandBar)
      layoutOverlays()
      wc.window.makeFirstResponder(commandBar.input)
      commandBar.input.currentEditor()?.selectAll(nil)
      // Spec §2/§7: the command bar appears and disappears in one frame, no animation.
    }
    layoutOverlays()
  }

  func setDialog(_ tree: Value) {
    if tree.isNull {
      dialogOpen = false
      dialogBackdrop.removeFromSuperview()
      dialog.removeFromSuperview()
      return
    }
    dialog.update(tree, palette: renderer.palette)
    if !dialogOpen {
      dialogOpen = true
      wc.overlays.addSubview(dialogBackdrop)
      wc.overlays.addSubview(dialog)
    }
    wc.window.makeFirstResponder(dialog)
    layoutOverlays()
  }

  func showToast(_ tree: Value) {
    let t = ToastView()
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
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) { [weak self, weak t] in
      guard let t else { return }
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
  }

  func layoutOverlays() {
    let b = wc.overlays.bounds
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
    // Spec §6: toasts are anchored to the window's top-right corner.
    var y = Tokens.toastTopInset
    for t in toasts {
      let w = t.contentWidth, h = Tokens.toastHeight
      t.frame = NSRect(x: (b.width - Tokens.toastRightInset - w).rounded(), y: y, width: w, height: h)
      y += h + 8
    }
  }
}
