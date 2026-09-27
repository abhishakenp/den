import AppKit
import Foundation

/// Tests (`swift test`) create real den windows: they must never show on the user's screen,
/// float over other apps or take clicks. Under a test runner every den window is transparent,
/// click-through and at the normal level; frames, layout and WebKit rendering are unchanged,
/// so snapshots and geometry checks still work.
public enum TestMode {
  public static let active: Bool = {
    let name = ProcessInfo.processInfo.processName
    return name.hasPrefix("swiftpm-testing-helper") || name == "xctest" || name.hasSuffix("PackageTests")
      || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
  }()

  /// An invisible window is occluded, and WebKit throttles and deprioritises the pages of occluded
  /// windows. Under tests, den's web views skip occlusion detection so pages run as they do on
  /// screen (WebKit's `_setWindowOcclusionDetectionEnabled:`, used only here, only in tests).
  @MainActor
  static func keepActive(_ view: NSView) {
    guard active else { return }
    let sel = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
    guard view.responds(to: sel) else { return }
    typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
    unsafeBitCast(view.method(for: sel), to: Setter.self)(view, sel, false)
  }

  @MainActor
  static func hide(_ w: NSWindow) {
    guard active else { return }
    w.alphaValue = 0
    w.ignoresMouseEvents = true
    w.level = .normal
    w.hasShadow = false
  }
}
