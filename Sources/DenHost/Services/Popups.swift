import AppKit
import CordisValue
import WebKit

// MARK: - Pop-ups (window.open, target=_blank), like Safari
//
// - A page opens a window from a click (or on a site whose pop-ups are allowed): the new page is a
//   web view built from the configuration WebKit hands over, so it shares the opener's web
//   process, website data store (a private window's ephemeral store too) and browsing context
//   group: `window.opener`, `postMessage` both ways and `window.close()` work, which is what OAuth
//   sign-in pop-ups (Google, Apple, GitHub, Microsoft, PayPal) rely on.
// - `window.open` with window features (`width=500,height=600`, `popup`; WebKit's `_wantsPopup`)
//   opens a small pop-up window over the opener's window; anything else (`target=_blank`,
//   `window.open(url)`) a tab next to the opener (`webviews.newWindow {id, url, webview}`).
// - Without a click: blocked, never silently: `webviews.popupBlocked {id, url, count}`, and
//   `openBlocked {id}` opens them (the URL pill's "Pop-up blocked" button).
// - `window.close()` from a page den opened for a script: a pop-up window closes (focus goes
//   back to the opener's window); a tab asks its owner with `webviews.closeRequested {id, opener}`.

extension WebViewsService {
  /// `-[WKNavigationAction _isUserInitiated]` (SPI): the page is handling a click or key press.
  /// Without it, only a link activation counts.
  nonisolated static func isUserInitiated(_ action: WKNavigationAction) -> Bool {
    if let v = boolSPI(action, "_isUserInitiated") { return v }
    return action.navigationType == .linkActivated
  }

  /// `-[WKWindowFeatures _wantsPopup]` (SPI): WebKit's reading of the HTML spec's "is popup"
  /// (a features string asking for a window, e.g. a size). Without it, a size counts.
  nonisolated static func wantsPopupWindow(_ f: WKWindowFeatures) -> Bool {
    if let v = boolSPI(f, "_wantsPopup") { return v }
    return f.width != nil || f.height != nil
  }

  nonisolated static func boolSPI(_ o: NSObject, _ name: String) -> Bool? {
    let sel = NSSelectorFromString(name)
    guard o.responds(to: sel), let imp = o.method(for: sel) else { return nil }
    typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
    return unsafeBitCast(imp, to: Getter.self)(o, sel)
  }

  /// The size a `window.open` asked for (content size, points), when it gave one.
  nonisolated static func requestedSize(_ f: WKWindowFeatures) -> CGSize? {
    guard f.width != nil || f.height != nil else { return nil }
    return CGSize(width: f.width?.doubleValue ?? 0, height: f.height?.doubleValue ?? 0)
  }

  /// Pop-ups without a click are allowed on this page's site (`sitepolicy` rule `popups: allow`).
  func popupsAllowed(on url: URL?) -> Bool {
    guard let sp = sitePolicy, let h = url?.host, !h.isEmpty else { return false }
    return sp.rule(for: h).popups == "allow"
  }

  func newPopupId(_ prefix: String) -> String {
    var id = ""
    repeat { id = "\(prefix)\(nextPopup)"; nextPopup += 1 } while records[id] != nil
    return id
  }

  public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                      windowFeatures: WKWindowFeatures) -> WKWebView? {
    guard let opener = recordFor(webView) else { return nil }
    // window.open('mailto:…') / a target=_blank app link: the app, not an empty window.
    if let u = action.request.url, ExternalLinks.isExternal(u) {
      openExternal(u, from: webView, userInitiated: Self.isUserInitiated(action), mainFrame: true)
      return nil
    }
    let url = action.request.url?.absoluteString ?? ""
    let wantsWindow = Self.wantsPopupWindow(windowFeatures)
    let size = Self.requestedSize(windowFeatures)
    guard Self.isUserInitiated(action) || popupsAllowed(on: webView.url) else {
      blockPopup(opener, BlockedPopup(url: url, size: size, popup: wantsWindow))
      return nil
    }
    // A tab only when something (the tabs plugin) takes it; otherwise a pop-up window.
    let asWindow = wantsWindow || !host.hasListeners("webviews.newWindow")
    let r = WebRecord(id: newPopupId(asWindow ? "popup-" : "tab-o"), profile: opener.profile, url: url.isEmpty ? "about:blank" : url)
    r.opener = opener.id
    r.userAgent = opener.userAgent
    records[r.id] = r
    order.append(r.id)
    // The handed-over configuration is a copy of the opener's: same process pool, data store and
    // related page (WebKit insists on it). Its script controller is the opener's own object, so
    // the new page gets a fresh one with den's scripts (handlers can't be added twice).
    configuration.userContentController = WKUserContentController()
    let w = makeView(r, configuration)
    if asWindow, let show = showPopupWindow, show(r.id, size) {
      host.emit("webviews.popup", ["id": .string(r.id), "opener": .string(opener.id), "url": .string(r.url)])
    } else {
      host.emit("webviews.newWindow", ["id": .string(opener.id), "url": .string(r.url), "webview": .string(r.id)])
    }
    return w
  }

  func blockPopup(_ r: WebRecord, _ b: BlockedPopup) {
    if r.blockedPopups.count >= 20 { r.blockedPopups.removeFirst() }
    r.blockedPopups.append(b)
    host.emit("webviews.popupBlocked", ["id": .string(r.id), "url": .string(b.url), "count": .int(Int64(r.blockedPopups.count))])
  }

  /// A new page in `r` (main-frame commit): its blocked pop-ups are forgotten.
  func clearBlockedPopups(_ r: WebRecord) {
    guard !r.blockedPopups.isEmpty else { return }
    r.blockedPopups = []
    host.emit("webviews.popupBlocked", ["id": .string(r.id), "url": "", "count": 0])
  }

  /// `openBlocked {id}`: opens the page's blocked pop-ups (without an opener: the script that
  /// asked has moved on, as in Safari), in a pop-up window or a tab as each asked.
  func openBlocked(_ r: WebRecord) -> Value {
    let list = r.blockedPopups
    clearBlockedPopups(r)
    for b in list where !b.url.isEmpty && b.url != "about:blank" {
      if b.popup, let show = showPopupWindow {
        let p = WebRecord(id: newPopupId("popup-"), profile: r.profile, url: b.url)
        p.userAgent = r.userAgent
        records[p.id] = p
        order.append(p.id)
        if show(p.id, b.size) { continue }
        close(p)
      }
      host.emit("webviews.newWindow", ["id": .string(r.id), "url": .string(b.url)])
    }
    return ["opened": .int(Int64(list.count))]
  }

  /// `window.close()` (WebKit asks only for windows a script opened).
  public func webViewDidClose(_ webView: WKWebView) {
    guard let r = recordFor(webView) else { return }
    if r.popupWindow != nil, let closeWindow = closePopupWindow {
      closeWindow(r.id)
      return
    }
    host.emit("webviews.closeRequested", ["id": .string(r.id), "opener": r.opener.map { .string($0) } ?? .null])
  }

  /// A pop-up window closed (by its page or the user): its page goes, and the opener's window
  /// comes back to the front.
  public func popupWindowClosed(_ id: String) {
    guard let r = records[id] else { return }
    let opener = r.opener.flatMap { records[$0]?.webView?.window }
    close(r)
    if let win = opener, win.isVisible { Presentation.show(win) }
  }
}
