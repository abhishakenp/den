import AppKit
import CordisValue

/// Flipped root view that delegates layout to the controller.
final class RootView: NSView {
  var onLayout: (() -> Void)?
  override var isFlipped: Bool { true }
  override func layout() {
    super.layout()
    onLayout?()
  }
}

/// Plain flipped container.
public class FlippedView: NSView {
  public override var isFlipped: Bool { true }
}

/// Transparent container that lets clicks fall through where it has no subview.
public final class PassthroughView: FlippedView {
  public override func hitTest(_ point: NSPoint) -> NSView? {
    let v = super.hitTest(point)
    return v === self ? nil : v
  }
}

/// Arc window: no toolbar, full-size content, traffic lights inside the sidebar, themed
/// background everywhere, web content in inset cards, resizable/hideable sidebar.
@MainActor
public final class DenWindowController: NSObject, NSWindowDelegate {
  public let window: NSWindow
  let root = RootView()
  public let background = ThemeBackgroundView()
  /// Host for the sidebar UI (filled by the ui toolkit). Transparent when docked.
  public let sidebar = SidebarContainerView()
  /// Area right of the sidebar where content cards live. Managed by the content service.
  public let contentArea = FlippedView()
  /// Top-most layer for peek, command bar, dialogs and toasts.
  public let overlays = PassthroughView()
  let resizeHandle = SidebarResizeHandle()
  let edgeZone = EdgeHoverZone()

  public private(set) var sidebarWidth: CGFloat = Tokens.sidebarDefaultWidth
  public private(set) var sidebarHidden = false
  public private(set) var sidebarRevealed = false  // hover overlay while hidden
  private var hideRevealWork: DispatchWorkItem?

  /// Themes per sidebar page (space). The background shows `displayTheme`.
  public private(set) var themes: [Int: Theme] = [:]
  public private(set) var page = 0
  public var appearance: Appearance = .auto { didSet { applyAppearance() } }

  /// Emit an event on the host bus ("window.sidebarResized", ...).
  public var emit: (String, Value) -> Void = { _, _ in }
  public var onLayout: (() -> Void)?
  public var onCloseRequest: (() -> Bool)?

  public override init() {
    window = NSWindow(
      contentRect: NSRect(origin: .zero, size: Tokens.windowDefaultSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: true)
    super.init()
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.title = "den"
    window.isReleasedWhenClosed = false
    window.minSize = Tokens.windowMinSize
    window.tabbingMode = .disallowed
    window.collectionBehavior.insert(.fullScreenPrimary)
    window.delegate = self
    window.setFrameAutosaveName("den.main")
    if window.frame.origin == .zero { window.center() }

    root.wantsLayer = true
    root.onLayout = { [weak self] in self?.layout() }
    window.contentView = root
    background.autoresizingMask = [.width, .height]
    root.addSubview(background)
    root.addSubview(contentArea)
    root.addSubview(sidebar)
    root.addSubview(resizeHandle)
    root.addSubview(edgeZone)
    root.addSubview(overlays)
    contentArea.wantsLayer = true
    overlays.wantsLayer = true

    resizeHandle.onDrag = { [weak self] x in self?.dragResize(to: x) }
    resizeHandle.onDragEnd = { [weak self] in self?.emit("window.sidebarResized", ["width": .double(Double(self?.sidebarWidth ?? 0))]) }
    resizeHandle.onDoubleClick = { [weak self] in self?.setSidebarWidth(Tokens.sidebarDefaultWidth, animated: true) }
    edgeZone.onEnter = { [weak self] in self?.setRevealed(true) }
    sidebar.onExit = { [weak self] in self?.scheduleConceal() }
    sidebar.onEnter = { [weak self] in self?.hideRevealWork?.cancel() }
  }

  // MARK: Layout

  var sidebarFrame: NSRect {
    let b = root.bounds
    if !sidebarHidden { return NSRect(x: 0, y: 0, width: sidebarWidth, height: b.height) }
    let i = Tokens.sidebarOverlayInset
    let x = sidebarRevealed ? i : -sidebarWidth - 20
    return NSRect(x: x, y: i, width: sidebarWidth, height: b.height - 2 * i)
  }

  public var contentFrame: NSRect {
    let b = root.bounds
    let i = Tokens.cardInset
    let full = window.styleMask.contains(.fullScreen)
    let left = sidebarHidden ? i : sidebarWidth
    let inset = full && sidebarHidden ? 0 : i
    return NSRect(x: sidebarHidden ? inset : left, y: inset, width: b.width - (sidebarHidden ? inset : left) - inset, height: b.height - 2 * inset)
  }

  func layout() {
    background.frame = root.bounds
    sidebar.frame = sidebarFrame
    sidebar.overlayMode = sidebarHidden
    contentArea.frame = contentFrame
    overlays.frame = root.bounds
    let hw = Tokens.sidebarResizeHandleWidth
    resizeHandle.frame = NSRect(x: sidebarWidth - hw / 2, y: 0, width: hw, height: root.bounds.height)
    resizeHandle.isHidden = sidebarHidden
    edgeZone.frame = NSRect(x: 0, y: 0, width: Tokens.sidebarHoverRevealZone, height: root.bounds.height)
    edgeZone.isHidden = !sidebarHidden || sidebarRevealed
    layoutTrafficLights()
    onLayout?()
  }

  /// Moves the traffic lights into the sidebar's first row; hides them with the sidebar.
  func layoutTrafficLights() {
    let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    let buttons = kinds.compactMap { window.standardWindowButton($0) }
    guard let first = buttons.first, let container = first.superview?.superview else { return }
    let fullScreen = window.styleMask.contains(.fullScreen)
    let visible = !sidebarHidden || sidebarRevealed
    for b in buttons { b.isHidden = !visible && !fullScreen }
    guard !fullScreen else { return }
    let h = Tokens.navRowHeight + (sidebarHidden ? Tokens.sidebarOverlayInset : 0)
    let wh = window.frame.height
    container.frame = NSRect(x: 0, y: wh - h, width: container.frame.width, height: h)
    let dx: CGFloat = sidebarHidden ? Tokens.sidebarOverlayInset : 0
    for (i, b) in buttons.enumerated() {
      let s = b.frame.size
      b.setFrameOrigin(NSPoint(x: Tokens.trafficLightLeading + dx + CGFloat(i) * Tokens.trafficLightSpacing - s.width / 2 + 6, y: h - Tokens.trafficLightCenterY - dx - s.height / 2))
    }
  }

  // MARK: Sidebar

  public func setSidebarWidth(_ w: CGFloat, animated: Bool) {
    sidebarWidth = min(max(w, Tokens.sidebarMinWidth), Tokens.sidebarMaxWidth)
    relayout(animated: animated)
    emit("window.sidebarResized", ["width": .double(Double(sidebarWidth))])
  }

  func dragResize(to x: CGFloat) {
    if x < Tokens.sidebarCollapseDragWidth {
      if !sidebarHidden { setSidebarHidden(true, animated: true) }
      return
    }
    if sidebarHidden { setSidebarHidden(false, animated: true) }
    sidebarWidth = min(max(x, Tokens.sidebarMinWidth), Tokens.sidebarMaxWidth)
    root.needsLayout = true
  }

  public func setSidebarHidden(_ hidden: Bool, animated: Bool) {
    guard hidden != sidebarHidden else { return }
    sidebarHidden = hidden
    sidebarRevealed = false
    relayout(animated: animated)
    emit("window.sidebarVisibility", ["hidden": .bool(hidden)])
  }

  func setRevealed(_ on: Bool) {
    guard sidebarHidden, on != sidebarRevealed else { return }
    hideRevealWork?.cancel()
    sidebarRevealed = on
    relayout(animated: true)
    emit("window.sidebarReveal", ["revealed": .bool(on)])
  }

  func scheduleConceal() {
    guard sidebarHidden, sidebarRevealed else { return }
    hideRevealWork?.cancel()
    let w = DispatchWorkItem { [weak self] in self?.setRevealed(false) }
    hideRevealWork = w
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)  // estimate: grace period
  }

  func relayout(animated: Bool) {
    if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = Tokens.animationDuration
        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ctx.allowsImplicitAnimation = true
        root.layoutSubtreeIfNeeded()
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
      }
    } else {
      root.needsLayout = true
      root.layoutSubtreeIfNeeded()
    }
  }

  // MARK: Theme

  public func setTheme(_ t: Theme, page p: Int?) {
    themes[p ?? page] = t
    if t.appearance != appearance, p == nil || p == page { appearance = t.appearance }
    if p == nil || p == page { showTheme(for: page) }
  }

  public func showTheme(for p: Int) {
    page = p
    background.theme = themes[p] ?? themes[0] ?? Theme()
    sidebar.backdrop.theme = background.theme
  }

  /// Interactive swipe: blend page themes by fractional position.
  public func blendTheme(from a: Int, to b: Int, progress: CGFloat) {
    let ta = themes[a] ?? Theme(), tb = themes[b] ?? ta
    background.theme = ta.interpolated(to: tb, min(max(progress, 0), 1))
    sidebar.backdrop.theme = background.theme
  }

  public var currentTheme: Theme { background.theme }
  public var isDark: Bool { background.isDark }

  func applyAppearance() {
    switch appearance {
    case .light: window.appearance = NSAppearance(named: .aqua)
    case .dark: window.appearance = NSAppearance(named: .darkAqua)
    case .auto: window.appearance = nil
    }
  }

  // MARK: NSWindowDelegate

  public func windowDidResize(_ notification: Notification) { layoutTrafficLights() }
  public func windowDidEnterFullScreen(_ notification: Notification) { root.needsLayout = true }
  public func windowDidExitFullScreen(_ notification: Notification) { root.needsLayout = true }
  public func windowShouldClose(_ sender: NSWindow) -> Bool { onCloseRequest?() ?? true }
}

/// Drag handle on the sidebar edge.
final class SidebarResizeHandle: NSView {
  var onDrag: ((CGFloat) -> Void)?
  var onDragEnd: (() -> Void)?
  var onDoubleClick: (() -> Void)?

  override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
  override var mouseDownCanMoveWindow: Bool { false }

  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 { onDoubleClick?(); return }
    guard let window else { return }
    while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
      if e.type == .leftMouseUp { onDragEnd?(); return }
      let p = superview!.convert(e.locationInWindow, from: nil)
      onDrag?(p.x)
    }
  }
}

/// Invisible hot zone on the left window edge; entering it reveals the hidden sidebar.
final class EdgeHoverZone: NSView {
  var onEnter: (() -> Void)?
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
  }
  override func mouseEntered(with event: NSEvent) { onEnter?() }
}

/// Sidebar host. Docked: transparent over the window background. Hidden+revealed: a floating
/// themed panel with rounded corners and a shadow.
public final class SidebarContainerView: FlippedView {
  public let backdrop = ThemeBackgroundView()
  /// Where the toolkit puts sidebar content.
  public let body = FlippedView()
  var onEnter: (() -> Void)?
  var onExit: (() -> Void)?

  var overlayMode = false {
    didSet {
      guard overlayMode != oldValue else { return }
      backdrop.isHidden = !overlayMode
      layer?.shadowOpacity = overlayMode ? 0.25 : 0
    }
  }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = false
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowRadius = 12
    layer?.shadowOffset = CGSize(width: 0, height: -2)
    backdrop.isHidden = true
    backdrop.wantsLayer = true
    backdrop.layer?.cornerRadius = Tokens.sidebarOverlayCornerRadius
    backdrop.layer?.cornerCurve = .continuous
    backdrop.layer?.masksToBounds = true
    addSubview(backdrop)
    addSubview(body)
  }
  required init?(coder: NSCoder) { fatalError() }

  public override var mouseDownCanMoveWindow: Bool { true }

  public override func layout() {
    super.layout()
    backdrop.frame = bounds
    body.frame = bounds
    for v in body.subviews { v.frame = body.bounds }
  }

  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
  }
  public override func mouseEntered(with event: NSEvent) { onEnter?() }
  public override func mouseExited(with event: NSEvent) { onExit?() }
}

extension DenWindowController {
  /// Shows the hover-reveal overlay without a mouse (snapshots, tests).
  public func revealSidebarForTesting() { setRevealed(true) }
}
