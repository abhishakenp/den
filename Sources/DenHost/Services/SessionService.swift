import AppKit
import CordisValue
import WebKit

/// `session` service: what a site the user is logged into exposes, read from den's own
/// `WKWebsiteDataStore` for a profile. Nothing leaves the process and nothing is persisted: values
/// go back to the calling plugin, which keeps them in memory.
///
/// Every call needs `plugin` (the caller's id) with a `session:<domain>` permission covering the
/// domain or origin (see `Permissions`). Results arrive as `session.result {id, ok, ...}`.
///
///   cookies {plugin, domain, profile?, id?}  -> {id}; result {id, ok, cookies: [{name, value, domain, path, secure, httpOnly, expires?}]}
///                                             (cookies for `domain` and its subdomains)
///   eval {plugin, origin, script, profile?, id?, timeoutMs?}
///                                           -> {id}; result {id, ok, value} or {id, ok: false, error}
///       Runs `script` (a function body; `return` a JSON-compatible value, max 4 KB) in a hidden,
///       never-shown WKWebView whose document has `origin` (e.g. https://app.slack.com) in the
///       profile's data store, so it sees that origin's localStorage. The document is an empty
///       local page (no request is made), the script runs in an isolated content world, and any
///       navigation is refused.
@MainActor
public final class SessionService: NSObject, HostService, WKNavigationDelegate {
  public let name = "session"
  let host: ServiceHost
  let webviews: WebViewsService
  let permissions: Permissions
  private var nextId = 1
  /// Hidden views in flight, by request id.
  private var pending: [String: (view: WKWebView, script: String, timer: DispatchWorkItem)] = [:]
  public var maxScriptBytes = 4096

  public init(host: ServiceHost, webviews: WebViewsService, permissions: Permissions) {
    self.host = host
    self.webviews = webviews
    self.permissions = permissions
  }

  public var inFlight: Int { pending.count }

  public func handle(method: String, args: Value) -> Value {
    let plugin = args.str("plugin")
    switch method {
    case "cookies":
      let domain = args.str("domain").lowercased()
      guard !domain.isEmpty else { return .error("session: domain required") }
      guard permissions.allowsSession(plugin, host: domain) else { return .error("session: '\(plugin)' has no session:\(domain) permission") }
      let id = requestId(args)
      let store = webviews.store(for: args.str("profile", "default"))
      store.httpCookieStore.getAllCookies { [weak self] cookies in
        MainActor.assumeIsolated {
          let list = cookies.filter { Permissions.covers(domain: domain, host: Self.bare($0.domain)) }.map(Self.cookieValue)
          self?.host.emit("session.result", ["id": .string(id), "ok": true, "cookies": .array(list)])
        }
      }
      return ["id": .string(id)]
    case "eval":
      guard let origin = URL(string: args.str("origin")), let h = origin.host, ["http", "https"].contains(origin.scheme ?? "") else {
        return .error("session: origin must be an http(s) URL")
      }
      guard permissions.allowsSession(plugin, host: h) else { return .error("session: '\(plugin)' has no session:\(h) permission") }
      let script = args.str("script")
      guard !script.isEmpty, script.utf8.count <= maxScriptBytes else { return .error("session: script must be 1…\(maxScriptBytes) bytes") }
      let id = requestId(args)
      evaluate(id: id, origin: origin, script: script, profile: args.str("profile", "default"), timeoutMs: Int(args.num("timeoutMs", 10_000)))
      return ["id": .string(id)]
    default:
      return .error("session: unknown method '\(method)'")
    }
  }

  func requestId(_ args: Value) -> String {
    if let s = args["id"].string, !s.isEmpty { return s }
    defer { nextId += 1 }
    return "session-\(nextId)"
  }

  static func bare(_ domain: String) -> String { domain.hasPrefix(".") ? String(domain.dropFirst()) : domain }

  static func cookieValue(_ c: HTTPCookie) -> Value {
    var v: Value = ["name": .string(c.name), "value": .string(c.value), "domain": .string(c.domain), "path": .string(c.path),
                    "secure": .bool(c.isSecure), "httpOnly": .bool(c.isHTTPOnly)]
    if let e = c.expiresDate { v = v.with("expires", .double(e.timeIntervalSince1970 * 1000)) }
    return v
  }

  // MARK: Hidden evaluation

  func evaluate(id: String, origin: URL, script: String, profile: String, timeoutMs: Int) {
    let config = WKWebViewConfiguration()
    config.applicationNameForUserAgent = WebViewsService.applicationNameForUserAgent
    config.websiteDataStore = webviews.store(for: profile)
    let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 10, height: 10), configuration: config)
    w.navigationDelegate = self
    let timer = DispatchWorkItem { [weak self] in self?.finish(id, .error("session: timed out")) }
    pending[id] = (w, script, timer)
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(max(500, min(timeoutMs, 30_000))), execute: timer)
    // An empty local document with the site's origin: WebKit gives it that origin's storage.
    var base = URLComponents()
    base.scheme = origin.scheme
    base.host = origin.host
    base.port = origin.port
    base.path = "/"
    w.loadHTMLString("<!doctype html><title></title>", baseURL: base.url)
  }

  func finish(_ id: String, _ result: Value) {
    guard let p = pending.removeValue(forKey: id) else { return }
    started.remove(ObjectIdentifier(p.view))
    p.timer.cancel()
    p.view.navigationDelegate = nil
    p.view.stopLoading()
    var payload: Value = ["id": .string(id)]
    if result.isError {
      payload = payload.with("ok", false).with("error", result["error"])
    } else {
      payload = payload.with("ok", true).with("value", result["value"])
    }
    host.emit("session.result", payload)
  }

  /// Views whose one allowed load (the empty local document) has started.
  private var started = Set<ObjectIdentifier>()

  public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
    // Only the initial substitute document loads; the view never navigates anywhere.
    decisionHandler(started.insert(ObjectIdentifier(webView)).inserted ? .allow : .cancel)
  }

  public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    guard let (id, _) = pending.first(where: { $0.value.view === webView }) else { return }
    finish(id, .error("session: \(error.localizedDescription)"))
  }

  public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard let (id, p) = pending.first(where: { $0.value.view === webView }) else { return }
    let world = WKContentWorld.world(name: "den-session")
    webView.callAsyncJavaScript(p.script, arguments: [:], in: nil, in: world) { [weak self] result in
      MainActor.assumeIsolated {
        switch result {
        case let .success(v): self?.finish(id, ["value": ValueJSON.value(v)])
        case let .failure(e): self?.finish(id, .error("session: script failed: \(e.localizedDescription)"))
        }
      }
    }
  }

  public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    guard let (id, _) = pending.first(where: { $0.value.view === webView }) else { return }
    finish(id, .error("session: \(error.localizedDescription)"))
  }
}
