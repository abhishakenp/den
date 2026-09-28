import AppKit
import WebKit

/// How den's windows reach the screen. `invisible` (`--background`) is for automation: an
/// accessory app (no Dock icon), never activated, and every window placed on a virtual screen far
/// off every display, so nothing ever shows on the user's screen. Windows are still ordered in, so
/// layout, `--snapshot` (cacheDisplay + WKWebView `takeSnapshot`) and key-window logic behave as
/// usual. (Test processes hide their windows their own way: DenTestSupport.)
@MainActor
public enum Presentation {
  public static var invisible = false

  /// The off-display area invisible windows live in (sized like a laptop's visible frame).
  public static let virtualScreen = NSRect(x: -40000, y: -40000, width: 1470, height: 920)

  /// Where a new window should be placed: the window's screen, or the virtual one when invisible.
  public static func visibleFrame(near window: NSWindow?) -> NSRect {
    if invisible { return virtualScreen }
    return (window?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1470, height: 920)
  }

  /// Moves `window` onto the virtual screen (invisible only; keeps its size). AppKit would pull a
  /// titled window back onto a display when it's ordered in; den's windows (`DenNSWindow`,
  /// `DenNSPanel`) skip that while invisible, and never animate in.
  public static func park(_ window: NSWindow) {
    guard invisible else { return }
    window.animationBehavior = .none
    guard NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) else { return }
    window.setFrameOrigin(NSPoint(x: virtualScreen.minX + 20, y: virtualScreen.minY + 20))
  }

  /// `makeKeyAndOrderFront` / `orderFront`, parked first when invisible.
  public static func show(_ window: NSWindow, key: Bool = true) {
    park(window)
    if key { window.makeKeyAndOrderFront(nil) } else { window.orderFront(nil) }
  }

  /// `NSApp.activate()`, except when invisible (automation never takes focus).
  public static func activate() {
    if !invisible { NSApp.activate() }
  }

  /// A web view entered a window: if that window is ordered in while invisible, its page paints.
  static func webViewMoved(_ web: WKWebView) {
    guard invisible, let w = web.window, w.isVisible else { return }
    ignoreOcclusion(web)
  }

  /// An invisible window was ordered in: every page in it paints (a window that is never ordered
  /// in keeps WebKit's usual hidden-page rules).
  static func windowOrderedIn(_ window: NSWindow) {
    guard invisible, window.isVisible, let root = window.contentView else { return }
    var stack: [NSView] = [root]
    while let v = stack.popLast() {
      if let web = v as? WKWebView { ignoreOcclusion(web) } else { stack += v.subviews }
    }
  }

  /// An off-display window counts as occluded, and WebKit stops painting its pages (snapshots come
  /// back blank or never). WebKit's own switch for this (`_windowOcclusionDetectionEnabled`, used
  /// by its test runners) makes an ordered-in window count as visible. Invisible mode only.
  public static func ignoreOcclusion(_ web: WKWebView) {
    let sel = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
    guard web.responds(to: sel) else { return }
    typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
    unsafeBitCast(web.method(for: sel), to: Setter.self)(web, sel, false)
  }
}

/// den's windows: AppKit keeps a titled window's title bar on a display when it's ordered in or
/// resized. Invisible windows (`Presentation.invisible`) stay where they were parked.
public final class DenNSWindow: NSWindow {
  public override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    Presentation.windowOrderedIn(self)
  }

  public override func orderFrontRegardless() {
    super.orderFrontRegardless()
    Presentation.windowOrderedIn(self)
  }

  public override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    Presentation.invisible ? frameRect : super.constrainFrameRect(frameRect, to: screen)
  }

  // Key-downs pass `ModalFocus` first: an open dialog / sheet / popover takes focus back from a
  // page that grabbed it, so Esc and Return reach it.
  public override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown { ModalFocus.route(event, in: self) }
    super.sendEvent(event)
  }

  public override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if event.type == .keyDown { ModalFocus.route(event, in: self) }
    return super.performKeyEquivalent(with: event)
  }
}

/// `DenNSWindow` for panels (Little Arc).
public final class DenNSPanel: NSPanel {
  public override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    Presentation.windowOrderedIn(self)
  }

  public override func orderFrontRegardless() {
    super.orderFrontRegardless()
    Presentation.windowOrderedIn(self)
  }

  public override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    Presentation.invisible ? frameRect : super.constrainFrameRect(frameRect, to: screen)
  }

  public override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown { ModalFocus.route(event, in: self) }
    super.sendEvent(event)
  }

  public override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if event.type == .keyDown { ModalFocus.route(event, in: self) }
    return super.performKeyEquivalent(with: event)
  }
}
