import AppKit
import WebKit

extension DenRuntime {
  /// Tests register here to see every runtime they create (see Tests/DenTestSupport).
  @MainActor public static var onCreate: ((DenRuntime) -> Void)?

  /// Ends everything this runtime keeps alive in other processes, so nothing outlives it: plugin
  /// events stop, speech stops, hidden session views finish, and every web view is closed with
  /// WebKit's page closed even if something still holds the view (`_close`), which lets its
  /// WebContent process exit. Windows are ordered out. Returns the WebKit helper pids that were in
  /// use (WebContent), including those of views closed earlier under tests, so a caller can check they went away.
  @MainActor
  @discardableResult
  public func tearDown() -> [pid_t] {
    host.forward = { _, _ in }
    _ = speech.handle(method: "stop", args: .null)
    let views = webviews.records.values.compactMap(\.webView) + session.liveViews
    var pids = Set(views.compactMap(WebViewsService.webProcessId))
    session.cancelAll()
    // Extension background pages run in WebContent processes of their own.
    for ctx in extensions.contexts.values { try? extensions.controller?.unload(ctx) }
    extensions.contexts = [:]
    for r in Array(webviews.records.values) { webviews.close(r) }
    let close = NSSelectorFromString("_close")
    for w in views {
      w.stopLoading()
      w.removeFromSuperview()
      if w.responds(to: close) { w.perform(close) }
    }
    media.panel?.orderOut(nil)
    window.window.orderOut(nil)
    pids.formUnion(webviews.destroyedProcessIds)
    return pids.sorted()
  }
}
