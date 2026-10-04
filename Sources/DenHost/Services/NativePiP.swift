import AppKit
import WebKit

/// WebKit's own picture in picture, as Safari drives it. Every call ends in WebKit's video
/// presentation code, which puts the video in the system PiP window (the "Picture in Picture"
/// agent's window, the one Safari uses: above every app, on every Space, with its own play/pause,
/// skip, close and return-to-tab buttons). den never draws a player of its own.
///
/// WKWebView SPI, checked on the system WebKit (macOS 26) and guarded with `responds(to:)`, so a
/// WebKit without one of them just falls back to the page's standard API
/// (`HTMLVideoElement.requestPictureInPicture()`, run with a user gesture by `callAsyncJavaScript`):
/// - `_canTogglePictureInPicture` / `_togglePictureInPicture`: the video WebKit's playback
///   controls manager picked as the page's main content (what Safari's tab audio button menu,
///   "Enter Picture in Picture", acts on; any frame, paused or not).
/// - `_isPictureInPictureActive`: that video is in PiP.
///
/// The `WKUIDelegate` side (WebViewsService) gets `_webView:hasVideoInPictureInPictureDidChange:`
/// when a page's video enters or leaves PiP, and `_webViewFullscreenMayReturnToInline:` when the
/// PiP window's return button is clicked (WebKit's `pipShouldClose:`). Its close button pauses the
/// video and sends no such call.
@MainActor
enum NativePiP {
  static func flag(_ w: WKWebView, _ sel: String) -> Bool {
    let s = NSSelectorFromString(sel)
    guard w.responds(to: s), let imp = w.method(for: s) else { return false }
    typealias F = @convention(c) (AnyObject, Selector) -> Bool
    return unsafeBitCast(imp, to: F.self)(w, s)
  }

  /// WebKit has a main-content video it can toggle into PiP.
  static func canToggle(_ w: WKWebView) -> Bool { flag(w, "_canTogglePictureInPicture") }
  /// The page's main-content video is in PiP.
  static func isActive(_ w: WKWebView) -> Bool { flag(w, "_isPictureInPictureActive") }

  /// Toggles WebKit's main-content video in or out of PiP. False when this WebKit can't.
  @discardableResult
  static func toggle(_ w: WKWebView) -> Bool {
    let s = NSSelectorFromString("_togglePictureInPicture")
    guard canToggle(w), w.responds(to: s) else { return false }
    w.perform(s)
    return true
  }

  /// The system PiP windows on screen right now (CGWindowList: the "Picture in Picture" agent's
  /// windows). For checks and diagnostics; den doesn't need it to work.
  static func systemWindows() -> [[String: Any]] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.filter { w in
      (w[kCGWindowOwnerName as String] as? String) == "Picture in Picture" || (w[kCGWindowName as String] as? String) == "Picture in Picture"
    }
  }
}
