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
///   watchCookies {plugin, domain, profile?}   -> ok (idempotent)
///   unwatchCookies {plugin, domain, profile?} -> ok
///       Event `session.cookiesChanged {domain, profile}` (never cookie values) when the cookies
///       covering a watched `domain` change, e.g. the user signs in to or out of that site in den.
///       Event-driven: a `WKHTTPCookieStoreObserver` sits on a profile's cookie store only while
///       something watches it, backed by finished page loads on the watched domain (see
///       `observeLoads` for why); each burst is coalesced into one read (`coalesceMs`, a one-shot
///       work item) and compared with a fingerprint taken at watch time. Nothing polls.
@MainActor
public final class SessionService: NSObject, HostService, WKNavigationDelegate {
  public let name = "session"
  let host: ServiceHost
  let webviews: WebViewsService
  let permissions: Permissions
  private var nextId = 1
  /// Hidden views in flight, by request id.
  private var pending: [String: (view: WKWebView, script: String, cancelTimeout: () -> Void)] = [:]
  public var maxScriptBytes = 4096
  /// Deadline timer for `eval` (tests swap in a manual clock).
  public var schedule: HostSchedule = HostTimers.main

  // MARK: Cookie watches
  /// profile -> domain -> plugins watching it.
  private var watches: [String: [String: Set<String>]] = [:]
  /// profile -> domain -> fingerprint of the cookies covering it (nil until the baseline read).
  private var fingerprints: [String: [String: String]] = [:]
  /// One observer per watched profile's cookie store.
  private var observers: [String: CookieStoreObserver] = [:]
  /// One pending coalesced read per profile.
  private var pendingReads: [String: DispatchWorkItem] = [:]
  public var coalesceMs = 300
  /// Profiles whose cookie store is observed right now (tests).
  public var observedProfiles: [String] { observers.keys.sorted() }
  public var pendingCookieReads: Int { pendingReads.count }
  /// Change notifications received from WebKit (tests).
  public private(set) var cookieNotifications = 0
  /// True once the watch on (profile, domain) has its baseline fingerprint (tests).
  public func hasBaseline(_ domain: String, profile: String = "default") -> Bool { fingerprints[profile]?[domain.lowercased()] != nil }

  public init(host: ServiceHost, webviews: WebViewsService, permissions: Permissions) {
    self.host = host
    self.webviews = webviews
    self.permissions = permissions
  }

  public var inFlight: Int { pending.count }
  /// The hidden views of requests in flight.
  var liveViews: [WKWebView] { pending.values.map(\.view) }

  /// Ends every request in flight (as cancelled) and releases its hidden view.
  func cancelAll() {
    for id in Array(pending.keys) { finish(id, .error("session: cancelled")) }
  }

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
    case "watchCookies", "unwatchCookies":
      let domain = args.str("domain").lowercased()
      guard !domain.isEmpty else { return .error("session: domain required") }
      guard permissions.allowsSession(plugin, host: domain) else { return .error("session: '\(plugin)' has no session:\(domain) permission") }
      let profile = args.str("profile", "default")
      if method == "watchCookies" { watch(plugin: plugin, domain: domain, profile: profile) } else { unwatch(plugin: plugin, domain: domain, profile: profile) }
      return .ok
    default:
      return .error("session: unknown method '\(method)'")
    }
  }

  func watch(plugin: String, domain: String, profile: String) {
    let isNewDomain = watches[profile]?[domain] == nil
    watches[profile, default: [:]][domain, default: []].insert(plugin)
    watchLoads()
    for r in webviews.records.values where r.profile == profile { if let w = r.webView { observeLoads(r, w) } }
    guard isNewDomain else { return }
    // Baseline first, observer second: on macOS 26 a cookie store read made after an observer
    // is added stops that observer's notifications for good (measured; see `observeLoads`).
    let store = webviews.store(for: profile).httpCookieStore
    store.getAllCookies { [weak self] cookies in
      MainActor.assumeIsolated {
        guard let self, self.watches[profile]?[domain] != nil else { return }
        if self.fingerprints[profile]?[domain] == nil { self.fingerprints[profile, default: [:]][domain] = Self.fingerprint(cookies, domain: domain) }
        if self.observers[profile] == nil {
          let o = CookieStoreObserver { [weak self] in self?.cookiesChanged(profile) }
          self.observers[profile] = o
          store.add(o)
        }
      }
    }
  }

  // MARK: Page loads (the observer's backstop)

  /// `WKHTTPCookieStoreObserver` stops firing once anything reads that cookie store after the
  /// observer was added (every `cookies` call and cookie-carrying `net.fetch` does), and re-adding
  /// it doesn't revive it (measured on macOS 26 with a local server: notifications for every
  /// Set-Cookie without reads, none after the first `getAllCookies`). Sign-ins end with a
  /// page load on the site, so a finished main-frame load on a watched domain also triggers the
  /// coalesced read. Still event-driven: KVO on `isLoading`, only for web views of watched
  /// profiles, only while something watches.
  private var loadWatches: [(view: WeakBox<WKWebView>, profile: String, token: NSKeyValueObservation)] = []
  private var loadHookInstalled = false
  /// Web views whose loads are observed right now (tests).
  public var observedLoads: Int { loadWatches.filter { $0.view.value != nil }.count }

  func watchLoads() {
    guard !loadHookInstalled else { return }
    loadHookInstalled = true
    webviews.createdHooks.append { [weak self] r, w in self?.observeLoads(r, w) }
  }

  func observeLoads(_ r: WebRecord, _ w: WKWebView) {
    guard watches[r.profile] != nil else { return }
    loadWatches.removeAll { $0.view.value == nil }
    guard !loadWatches.contains(where: { $0.view.value === w }) else { return }
    let profile = r.profile
    let token = w.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
      MainActor.assumeIsolated {
        guard let self, !wv.isLoading, let host = wv.url?.host?.lowercased(), let ds = self.watches[profile],
          ds.keys.contains(where: { Permissions.covers(domain: $0, host: host) })
        else { return }
        self.cookiesChanged(profile, fromObserver: false)
      }
    }
    loadWatches.append((WeakBox(w), profile, token))
  }

  func unwatch(plugin: String, domain: String, profile: String) {
    guard var ds = watches[profile], var ps = ds[domain] else { return }
    ps.remove(plugin)
    if ps.isEmpty {
      ds[domain] = nil
      fingerprints[profile]?[domain] = nil
    } else {
      ds[domain] = ps
    }
    guard ds.isEmpty else { watches[profile] = ds; return }
    watches[profile] = nil
    fingerprints[profile] = nil
    pendingReads.removeValue(forKey: profile)?.cancel()
    if let o = observers.removeValue(forKey: profile) { webviews.store(for: profile).httpCookieStore.remove(o) }
    for lw in loadWatches where lw.profile == profile { lw.token.invalidate() }
    loadWatches.removeAll { $0.profile == profile || $0.view.value == nil }
  }

  /// A burst of cookie changes (or a finished load on a watched site) in `profile`'s store: one
  /// read after `coalesceMs`.
  func cookiesChanged(_ profile: String, fromObserver: Bool = true) {
    if fromObserver { cookieNotifications += 1 }
    guard watches[profile] != nil, pendingReads[profile] == nil else { return }
    let item = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated { self?.readChanges(profile) }
    }
    pendingReads[profile] = item
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(coalesceMs), execute: item)
  }

  func readChanges(_ profile: String) {
    pendingReads[profile] = nil
    guard watches[profile] != nil else { return }
    webviews.store(for: profile).httpCookieStore.getAllCookies { [weak self] cookies in
      MainActor.assumeIsolated {
        guard let self, let domains = self.watches[profile] else { return }
        for domain in domains.keys.sorted() {
          let fp = Self.fingerprint(cookies, domain: domain)
          let old = self.fingerprints[profile]?[domain]
          self.fingerprints[profile, default: [:]][domain] = fp
          if let old, old != fp { self.host.emit("session.cookiesChanged", ["domain": .string(domain), "profile": .string(profile)]) }
        }
      }
    }
  }

  /// Sorted `name=value` of the cookies covering `domain` (kept in memory only, never emitted).
  static func fingerprint(_ cookies: [HTTPCookie], domain: String) -> String {
    cookies.filter { Permissions.covers(domain: domain, host: bare($0.domain)) }.map { $0.name + "=" + $0.value }.sorted().joined(separator: "\n")
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
    let cancel = schedule(max(500, min(timeoutMs, 30_000))) { [weak self] in self?.finish(id, .error("session: timed out")) }
    pending[id] = (w, script, cancel)
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
    p.cancelTimeout()
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

final class WeakBox<T: AnyObject> {
  weak var value: T?
  init(_ value: T) { self.value = value }
}

/// Forwards `WKHTTPCookieStore` change notifications (the store holds observers weakly).
final class CookieStoreObserver: NSObject, WKHTTPCookieStoreObserver, @unchecked Sendable {
  let changed: @MainActor () -> Void
  init(_ changed: @escaping @MainActor () -> Void) { self.changed = changed }
  func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
    if Thread.isMainThread {
      MainActor.assumeIsolated { changed() }
    } else {
      DispatchQueue.main.async { MainActor.assumeIsolated { self.changed() } }
    }
  }
}
