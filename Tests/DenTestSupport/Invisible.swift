import AppKit
import ObjectiveC

/// Keeps every window the tests (or den's own code under test) put on screen invisible to the
/// user, without changing what the code under test sees.
///
/// The window server gets alpha 0 and no mouse events, but the window stays ordered in: it is
/// "on screen" for AppKit, its occlusion state is visible, and WebKit keeps pages running
/// (`document.visibilityState == "visible"`, requestAnimationFrame and timers tick). Moving
/// windows off screen does not work (AppKit constrains titled windows back on screen), and an
/// ordered-out window gets its pages suspended. The alpha den itself sets is remembered and
/// returned by `alphaValue`, so fade logic behaves as usual.
///
/// The test process never becomes a regular app (activation policy stays `.prohibited`), so no
/// Dock icon and no activation. Set `DEN_TEST_SHOW_WINDOWS=1` to watch a run.
public enum Invisible {
  nonisolated(unsafe) private static var installed = false
  private static let lock = NSLock()

  public static var enabled: Bool { ProcessInfo.processInfo.environment["DEN_TEST_SHOW_WINDOWS"] != "1" }

  public static func install() {
    lock.lock()
    defer { lock.unlock() }
    guard !installed else { return }
    installed = true
    guard enabled else { return }
    swap(#selector(setter: NSWindow.alphaValue), #selector(NSWindow.denTest_setAlphaValue(_:)))
    swap(#selector(getter: NSWindow.alphaValue), #selector(NSWindow.denTest_alphaValue))
    // Every public way to put a window on screen (they don't all funnel through one method).
    swap(#selector(NSWindow.order(_:relativeTo:)), #selector(NSWindow.denTest_order(_:relativeTo:)))
    swap(#selector(NSWindow.orderFront(_:)), #selector(NSWindow.denTest_orderFront(_:)))
    swap(#selector(NSWindow.orderBack(_:)), #selector(NSWindow.denTest_orderBack(_:)))
    swap(#selector(NSWindow.orderFrontRegardless), #selector(NSWindow.denTest_orderFrontRegardless))
    swap(#selector(NSWindow.makeKeyAndOrderFront(_:)), #selector(NSWindow.denTest_makeKeyAndOrderFront(_:)))
    swap(NSSelectorFromString("setIsVisible:"), #selector(NSWindow.denTest_setIsVisible(_:)))
  }

  private static func swap(_ a: Selector, _ b: Selector) {
    guard let m1 = class_getInstanceMethod(NSWindow.self, a), let m2 = class_getInstanceMethod(NSWindow.self, b) else {
      fatalError("Invisible: cannot swizzle \(a)")
    }
    method_exchangeImplementations(m1, m2)
  }
}

nonisolated(unsafe) private var requestedAlphaKey: UInt8 = 0

extension NSWindow {
  // After the exchange, calling `denTest_*` runs AppKit's original implementation.
  @objc dynamic func denTest_setAlphaValue(_ value: CGFloat) {
    objc_setAssociatedObject(self, &requestedAlphaKey, NSNumber(value: Double(value)), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    denTest_setAlphaValue(0)
  }

  @objc dynamic func denTest_alphaValue() -> CGFloat {
    (objc_getAssociatedObject(self, &requestedAlphaKey) as? NSNumber).map { CGFloat($0.doubleValue) } ?? 1
  }

  /// Alpha 0 in the window server (remembering the alpha the code believes it has) and no mouse.
  private func denTest_hide() {
    if objc_getAssociatedObject(self, &requestedAlphaKey) == nil {
      let current = denTest_alphaValue()  // AppKit's original getter
      objc_setAssociatedObject(self, &requestedAlphaKey, NSNumber(value: Double(current)), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    denTest_setAlphaValue(0)  // AppKit's original setter
    ignoresMouseEvents = true
  }

  @objc dynamic func denTest_order(_ place: NSWindow.OrderingMode, relativeTo other: Int) {
    if place != .out { denTest_hide() }
    denTest_order(place, relativeTo: other)
  }
  @objc dynamic func denTest_orderFront(_ sender: Any?) { denTest_hide(); denTest_orderFront(sender) }
  @objc dynamic func denTest_orderBack(_ sender: Any?) { denTest_hide(); denTest_orderBack(sender) }
  @objc dynamic func denTest_orderFrontRegardless() { denTest_hide(); denTest_orderFrontRegardless() }
  @objc dynamic func denTest_makeKeyAndOrderFront(_ sender: Any?) { denTest_hide(); denTest_makeKeyAndOrderFront(sender) }
  @objc dynamic func denTest_setIsVisible(_ flag: Bool) {
    if flag { denTest_hide() }
    denTest_setIsVisible(flag)
  }
}
