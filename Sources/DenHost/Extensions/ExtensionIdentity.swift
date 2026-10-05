// thin-host: feature-specific, migrate to plugin (whole file)
import AppKit
import CordisValue
import CryptoKit
import WebKit

/// `identity.launchWebAuthFlow` (Chrome and Firefox): the extension's own OAuth sign-in in a den
/// window. The provider's page loads with the selected tab's cookies (so a site you're signed in
/// to can approve without asking again, as in Chrome); when it sends the browser to the
/// extension's redirect URL (`getRedirectURL()`: `https://<id>.chromiumapp.org/…`, or Firefox's
/// `https://<sha1 of the add-on id>.extensions.allizom.org/…`), den stops that navigation, closes
/// the window and hands the URL (with its code or token) to the extension. Nothing is ever
/// requested from the redirect host.
///
/// Interactive flows load hidden first and show the window only when the page doesn't redirect
/// right away (already approved: no flash). Non-interactive ones never show a window and fail
/// with "User interaction required." when the page settles without redirecting.
///
/// `getAuthToken` (a Google account signed in to Chrome itself) has no den equivalent.
@MainActor
final class ExtensionIdentity {
  /// `https://<id>.chromiumapp.org/` for Chrome extensions; Firefox's form for AMO installs.
  static func redirectBase(id: String, geckoId: String?) -> String {
    if let g = geckoId, !g.isEmpty {
      let hex = Insecure.SHA1.hash(data: Data(g.utf8)).map { String(format: "%02x", $0) }.joined()
      return "https://\(hex).extensions.allizom.org/"
    }
    return "https://\(id).chromiumapp.org/"
  }

  /// Both redirect forms den accepts for an extension (an extension may use either).
  static func matches(_ url: URL, id: String, geckoId: String?) -> Bool {
    guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
    if host == "\(id.lowercased()).chromiumapp.org" { return true }
    if let base = URL(string: redirectBase(id: id, geckoId: geckoId)), host == base.host { return true }
    return false
  }

  @MainActor final class Flow: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    let id: String
    let geckoId: String?
    let interactive: Bool
    let abortOnLoad: Bool
    let web: WKWebView
    var window: NSWindow?
    var done: ((Result<String, Error>) -> Void)?
    var showTimer: DispatchWorkItem?
    let parent: NSWindow?

    init(id: String, geckoId: String?, url: URL, interactive: Bool, abortOnLoad: Bool, store: WKWebsiteDataStore, parent: NSWindow?, done: @escaping (Result<String, Error>) -> Void) {
      self.id = id
      self.geckoId = geckoId
      self.interactive = interactive
      self.abortOnLoad = abortOnLoad
      self.parent = parent
      self.done = done
      let cfg = WKWebViewConfiguration()
      cfg.websiteDataStore = store
      cfg.applicationNameForUserAgent = WebViewsService.applicationNameForUserAgent
      web = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 680), configuration: cfg)
      super.init()
      web.navigationDelegate = self
      web.uiDelegate = self
      web.load(URLRequest(url: url))
    }

    func finish(_ r: Result<String, Error>) {
      guard let d = done else { return }
      done = nil
      showTimer?.cancel()
      web.stopLoading()
      web.navigationDelegate = nil
      web.uiDelegate = nil
      if let w = window {
        w.delegate = nil
        w.orderOut(nil)
        window = nil
      }
      d(r)
    }

    /// The sign-in window, centered on den's window.
    func show() {
      guard window == nil, done != nil else { return }
      let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 680), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
      w.isReleasedWhenClosed = false
      w.title = "Sign in · " + (web.url?.host ?? "")
      w.contentView = web
      w.delegate = self
      if let p = parent { w.setFrameOrigin(NSPoint(x: p.frame.midX - 250, y: p.frame.midY - 340)) } else { w.center() }
      window = w
      Presentation.show(w)
    }

    func check(_ url: URL?) -> Bool {
      guard let url, ExtensionIdentity.matches(url, id: id, geckoId: geckoId) else { return false }
      finish(.success(url.absoluteString))
      return true
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
      decisionHandler(check(navigationAction.request.url) ? .cancel : .allow)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
      _ = check(webView.url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      if done == nil { return }
      if !interactive {
        // A page that settles without redirecting needs the user.
        if abortOnLoad { finish(.failure(ExtensionsService.failure("User interaction required."))) }
        return
      }
      if window == nil {
        // A short grace for script redirects, then show the page.
        let t = DispatchWorkItem { [weak self] in self?.show() }
        showTimer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: t)
      }
      window?.title = "Sign in · " + (webView.url?.host ?? "")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }

    func failed(_ error: Error) {
      let e = error as NSError
      // A cancelled navigation is den stopping the redirect (or a new one replacing it).
      if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
      if e.domain == "WebKitErrorDomain" && e.code == 102 { return }  // frame load interrupted
      if interactive && window != nil { return }  // the user sees the error page
      finish(.failure(ExtensionsService.failure("Authorization page could not be loaded.")))
    }

    /// A pop-up from the sign-in page opens in the same window.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
      if !check(navigationAction.request.url) { webView.load(navigationAction.request) }
      return nil
    }

    func windowWillClose(_ notification: Notification) {
      window = nil
      finish(.failure(ExtensionsService.failure("The user did not approve access.")))
    }
  }

  /// Running flows by extension id (one at a time each, like Chrome).
  var flows: [String: Flow] = [:]

  func launch(_ o: Value, id: String, geckoId: String?, store: WKWebsiteDataStore, parent: NSWindow?, done: @escaping (Value) -> Void) {
    guard let u = URL(string: o.str("url")), u.scheme == "https" || u.scheme == "http" else { return done(.error("Authorization page could not be loaded.")) }
    if let old = flows[id] { old.finish(.failure(ExtensionsService.failure("Interactive auth flow was cancelled."))) }
    let interactive = o.flag("interactive")
    let flow = Flow(id: id, geckoId: geckoId, url: u, interactive: interactive, abortOnLoad: o.flag("abortOnLoadForNonInteractive", true), store: store, parent: parent) {
      [weak self] r in
      MainActor.assumeIsolated {
        self?.flows[id] = nil
        switch r {
        case .success(let url): done(.string(url))
        case .failure(let e): done(.error(e.localizedDescription))
        }
      }
    }
    flows[id] = flow
    let limit = o["timeoutMsForNonInteractive"].double.map { $0 / 1000 } ?? (interactive ? 0 : 60)
    if limit > 0 {
      DispatchQueue.main.asyncAfter(deadline: .now() + limit) { [weak flow] in
        MainActor.assumeIsolated { flow?.finish(.failure(ExtensionsService.failure("User interaction required."))) }
      }
    }
  }
}
