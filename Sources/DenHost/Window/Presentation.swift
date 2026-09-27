import AppKit
import WebKit

/// How den's windows reach the screen. `invisible` (`--background`, and automatically inside a
/// test runner) is for automation: an accessory app (no Dock icon), never activated, and every
/// window placed on a virtual screen far off every display, so nothing ever shows on the user's
/// screen. Windows are still ordered in, so layout, `--snapshot` (cacheDisplay + WKWebView
/// `takeSnapshot`) and key-window logic behave as usual.
@MainActor
public enum Presentation {
  public static var invisible = isTestHarness

  /// Running inside `swift test` (XCTest or swift-testing's helper). `DEN_TEST_VISIBLE=1` opts out.
  public nonisolated static let isTestHarness: Bool = {
    let p = ProcessInfo.processInfo
    guard p.environment["DEN_TEST_VISIBLE"] == nil else { return false }
    return p.processName == "xctest" || p.processName.hasPrefix("swiftpm-testing-helper") || p.environment["XCTestConfigurationFilePath"] != nil
  }()

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
    guard !virtualScreen.contains(window.frame.origin) else { return }
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
  public override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    Presentation.invisible ? frameRect : super.constrainFrameRect(frameRect, to: screen)
  }
}

/// `DenNSWindow` for panels (Little Arc).
public final class DenNSPanel: NSPanel {
  public override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    Presentation.invisible ? frameRect : super.constrainFrameRect(frameRect, to: screen)
  }
}
