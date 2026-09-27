import AppKit
import CordisValue
import CryptoKit
import WebKit

/// One tab's web content. The WKWebView exists only while materialized (shown at least once and
/// not discarded); otherwise the record keeps url + interactionState + snapshot.
@MainActor
public final class WebRecord {
  public let id: String
  public let profile: String
  public var url: String
  public var title = ""
  public var favicon = ""
  public var progress: Double = 0
  public var loading = false
  public var audio = false
  public var rules: [LinkRule] = []
  public var interactionState: Any?
  public var snapshot: NSImage?
  public fileprivate(set) var webView: WKWebView?
  fileprivate var observers: [NSKeyValueObservation] = []

  init(id: String, profile: String, url: String) { (self.id, self.profile, self.url) = (id, profile, url) }

  public var isSuspended: Bool { webView == nil && (interactionState != nil || snapshot != nil) }
}

/// `webviews` service.
///
/// Methods:
///   create {id?, url?, profile?}              -> {id}   (lazy: no WKWebView until shown)
///   navigate {id, url}  back {id}  forward {id}  reload {id}  stop {id}
///   close {id}                                 -> destroys the web view and record
///   suspend {id}                               -> full discard: saves interactionState + snapshot, destroys the view
///   snapshot {id, path}                        -> {pending}; later event webviews.snapshot {id, path, ok}
///   get {id}                                   -> {id, url, title, favicon, loading, progress, canGoBack, canGoForward, audio, suspended, live}
///   list                                       -> [id]
///   setLinkPolicy {id | "*", rules: [{when: crossSite|sameSite|any, hosts?: [suffix], modifiers?: [cmd,...], event}]}
///
/// Events: webviews.title {id,title}  webviews.url {id,url}  webviews.favicon {id,url}
///   webviews.progress {id,progress,loading}  webviews.state {id,canGoBack,canGoForward}
///   webviews.audio {id,playing}  webviews.newWindow {id,url}  webviews.crashed {id}
///   webviews.suspended {id}  webviews.snapshot {id,path,ok}  + any event named by a link rule: {id,url,source}
@MainActor
public final class WebViewsService: NSObject, HostService, WKNavigationDelegate, WKUIDelegate {
  public let name = "webviews"
  let host: ServiceHost
  public private(set) var records: [String: WebRecord] = [:]
  private var order: [String] = []
  private var defaultRules: [LinkRule] = []
  private var stores: [String: WKWebsiteDataStore] = [:]
  private var nextId = 1
  private lazy var scriptHandler = ScriptMessageProxy { [weak self] msg in self?.didReceive(msg) }

  public init(host: ServiceHost) { self.host = host }

  public func handle(method: String, args: Value) -> Value {
    if method == "create" { return create(args) }
    if method == "list" { return .array(order.map { .string($0) }) }
    if method == "setLinkPolicy", args.str("id") == "*" {
      defaultRules = args.list("rules").compactMap(LinkRule.init)
      return .ok
    }
    guard let r = records[args.str("id")] else { return .error("webviews: no webview '\(args.str("id"))'") }
    switch method {
    case "navigate":
      guard let url = Self.normalize(args.str("url")) else { return .error("webviews: bad url") }
      r.url = url.absoluteString
      r.interactionState = nil
      r.webView?.load(URLRequest(url: url))
    case "back": r.webView?.goBack()
    case "forward": r.webView?.goForward()
    case "reload": r.webView?.reload()
    case "stop": r.webView?.stopLoading()
    case "close": close(r)
    case "suspend": suspend(r)
    case "snapshot": snapshot(r, path: args.str("path"))
      return ["pending": true]
    case "get": return state(r)
    case "setLinkPolicy": r.rules = args.list("rules").compactMap(LinkRule.init)
    default: return .error("webviews: unknown method '\(method)'")
    }
    return .ok
  }

  // MARK: Records

  func create(_ args: Value) -> Value {
    var id = args.str("id")
    if id.isEmpty {
      repeat { id = "w\(nextId)"; nextId += 1 } while records[id] != nil
    }
    guard records[id] == nil else { return .error("webviews: id '\(id)' exists") }
    let url = Self.normalize(args.str("url"))?.absoluteString ?? "about:blank"
    records[id] = WebRecord(id: id, profile: args.str("profile", "default"), url: url)
    order.append(id)
    return ["id": .string(id)]
  }

  public func record(_ id: String) -> WebRecord? { records[id] }

  /// Creates the WKWebView on first show (or after a discard), restoring saved state.
  public func materialize(_ id: String) -> WKWebView? {
    guard let r = records[id] else { return nil }
    if let w = r.webView { return w }
    let config = WKWebViewConfiguration()
    config.websiteDataStore = store(for: r.profile)
    config.preferences.isElementFullscreenEnabled = true
    config.preferences.inactiveSchedulingPolicy = .suspend
    config.userContentController.addUserScript(WKUserScript(source: Self.mediaScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    config.userContentController.add(scriptHandler, name: "denMedia")
    let w = WKWebView(frame: .zero, configuration: config)
    w.navigationDelegate = self
    w.uiDelegate = self
    w.allowsBackForwardNavigationGestures = true
    w.allowsMagnification = true
    w.isInspectable = true
    w.underPageBackgroundColor = .clear
    r.webView = w
    observe(r, w)
    if let state = r.interactionState {
      w.interactionState = state
      r.interactionState = nil
      // Some states (e.g. loadHTMLString pages) don't restore; fall back to the last URL.
      if w.backForwardList.currentItem == nil, let url = URL(string: r.url), r.url != "about:blank" { w.load(URLRequest(url: url)) }
    } else if let url = URL(string: r.url), r.url != "about:blank" {
      w.load(URLRequest(url: url))
    }
    return w
  }

  func observe(_ r: WebRecord, _ w: WKWebView) {
    let id = r.id
    func on<T>(_ kp: KeyPath<WKWebView, T>, _ f: @escaping @MainActor (WKWebView) -> Void) -> NSKeyValueObservation {
      w.observe(kp, options: [.new]) { wv, _ in MainActor.assumeIsolated { f(wv) } }
    }
    r.observers = [
      on(\.title) { [weak self] wv in
        let t = wv.title ?? ""
        guard !t.isEmpty else { return }
        r.title = t
        self?.host.emit("webviews.title", ["id": .string(id), "title": .string(t)])
      },
      on(\.url) { [weak self] wv in
        guard let u = wv.url?.absoluteString else { return }
        r.url = u
        self?.host.emit("webviews.url", ["id": .string(id), "url": .string(u)])
      },
      on(\.estimatedProgress) { [weak self] wv in self?.progress(r, wv) },
      on(\.isLoading) { [weak self] wv in self?.progress(r, wv) },
      on(\.canGoBack) { [weak self] wv in self?.navState(r, wv) },
      on(\.canGoForward) { [weak self] wv in self?.navState(r, wv) },
    ]
  }

  func progress(_ r: WebRecord, _ w: WKWebView) {
    r.progress = w.estimatedProgress
    r.loading = w.isLoading
    host.emit("webviews.progress", ["id": .string(r.id), "progress": .double(r.progress), "loading": .bool(r.loading)])
  }

  func navState(_ r: WebRecord, _ w: WKWebView) {
    host.emit("webviews.state", ["id": .string(r.id), "canGoBack": .bool(w.canGoBack), "canGoForward": .bool(w.canGoForward)])
  }

  func state(_ r: WebRecord) -> Value {
    [
      "id": .string(r.id), "url": .string(r.url), "title": .string(r.title), "favicon": .string(r.favicon),
      "loading": .bool(r.loading), "progress": .double(r.progress),
      "canGoBack": .bool(r.webView?.canGoBack ?? false), "canGoForward": .bool(r.webView?.canGoForward ?? false),
      "audio": .bool(r.audio), "suspended": .bool(r.isSuspended), "live": .bool(r.webView != nil), "profile": .string(r.profile),
    ]
  }

  func destroyView(_ r: WebRecord) {
    guard let w = r.webView else { return }
    r.observers.forEach { $0.invalidate() }
    r.observers = []
    w.configuration.userContentController.removeScriptMessageHandler(forName: "denMedia")
    w.navigationDelegate = nil
    w.uiDelegate = nil
    w.stopLoading()
    w.removeFromSuperview()
    r.webView = nil
    host.emit("webviews.detached", ["id": .string(r.id)])
  }

  func close(_ r: WebRecord) {
    destroyView(r)
    records[r.id] = nil
    order.removeAll { $0 == r.id }
    host.emit("webviews.closed", ["id": .string(r.id)])
  }

  /// Full discard: keep back/forward + scroll state and a snapshot, free the WebContent process.
  func suspend(_ r: WebRecord) {
    guard let w = r.webView else { return }
    r.interactionState = w.interactionState
    w.takeSnapshot(with: nil) { [weak self] img, _ in
      MainActor.assumeIsolated {
        r.snapshot = img
        self?.destroyView(r)
        self?.host.emit("webviews.suspended", ["id": .string(r.id)])
      }
    }
  }

  func snapshot(_ r: WebRecord, path: String) {
    let id = r.id
    let done: @MainActor (NSImage?) -> Void = { [weak self] img in
      var ok = false
      if let img, !path.isEmpty, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
        ok = (try? png.write(to: URL(fileURLWithPath: path))) != nil
      }
      if let img { r.snapshot = img }
      self?.host.emit("webviews.snapshot", ["id": .string(id), "path": .string(path), "ok": .bool(ok)])
    }
    if let w = r.webView {
      w.takeSnapshot(with: nil) { img, _ in MainActor.assumeIsolated { done(img) } }
    } else {
      DispatchQueue.main.async { done(r.snapshot) }
    }
  }

  // MARK: Profiles

  public func store(for profile: String) -> WKWebsiteDataStore {
    if let s = stores[profile] { return s }
    let s: WKWebsiteDataStore
    switch profile {
    case "default", "": s = .default()
    case "private": s = .nonPersistent()
    default: s = WKWebsiteDataStore(forIdentifier: Self.profileUUID(profile))
    }
    stores[profile] = s
    return s
  }

  /// Stable UUID per profile name (SHA-256 based, version/variant bits set).
  public nonisolated static func profileUUID(_ name: String) -> UUID {
    var b = Array(SHA256.hash(data: Data(("den.profile." + name).utf8)).prefix(16))
    b[6] = (b[6] & 0x0F) | 0x50
    b[8] = (b[8] & 0x3F) | 0x80
    return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
  }

  public nonisolated static func normalize(_ s: String) -> URL? {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty { return nil }
    if let u = URL(string: t), let scheme = u.scheme, ["http", "https", "about", "file", "data"].contains(scheme.lowercased()) { return u }
    if !t.contains(" "), t.contains(".") || t.hasPrefix("localhost") { return URL(string: "https://" + t) }
    return nil
  }

  // MARK: Delegates

  func recordFor(_ w: WKWebView) -> WebRecord? { records.values.first { $0.webView === w } }

  public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
    guard let r = recordFor(webView), let target = action.request.url else { return decisionHandler(.allow) }
    let rules = r.rules.isEmpty ? defaultRules : r.rules
    var mods = Set<Chord.Mod>()
    let f = action.modifierFlags
    if f.contains(.command) { mods.insert(.cmd) }
    if f.contains(.shift) { mods.insert(.shift) }
    if f.contains(.option) { mods.insert(.opt) }
    if f.contains(.control) { mods.insert(.ctrl) }
    if let event = LinkPolicy.route(rules: rules, source: webView.url, target: target, isLinkClick: action.navigationType == .linkActivated, isMainFrame: action.targetFrame?.isMainFrame ?? true, modifiers: mods) {
      decisionHandler(.cancel)
      host.emit(event, ["id": .string(r.id), "url": .string(target.absoluteString), "source": .string(webView.url?.absoluteString ?? "")])
      return
    }
    decisionHandler(.allow)
  }

  public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard let r = recordFor(webView) else { return }
    webView.evaluateJavaScript(Self.faviconScript) { [weak self] result, _ in
      MainActor.assumeIsolated {
        guard let s = result as? String, !s.isEmpty, s != r.favicon else { return }
        r.favicon = s
        self?.host.emit("webviews.favicon", ["id": .string(r.id), "url": .string(s)])
      }
    }
  }

  public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    guard let r = recordFor(webView) else { return }
    host.emit("webviews.crashed", ["id": .string(r.id)])
  }

  public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    if let r = recordFor(webView), let u = action.request.url {
      host.emit("webviews.newWindow", ["id": .string(r.id), "url": .string(u.absoluteString)])
    }
    return nil
  }

  func didReceive(_ msg: WKScriptMessage) {
    guard let w = msg.webView, let r = recordFor(w), let playing = msg.body as? Bool, playing != r.audio else { return }
    r.audio = playing
    host.emit("webviews.audio", ["id": .string(r.id), "playing": .bool(playing)])
  }

  static let mediaScript = """
    (function(){var last=null;function s(){var p=false;document.querySelectorAll('video,audio').forEach(function(m){if(!m.paused&&!m.muted&&m.volume>0&&!m.ended)p=true});if(p!==last){last=p;try{webkit.messageHandlers.denMedia.postMessage(p)}catch(e){}}}
    ['play','playing','pause','ended','volumechange','emptied'].forEach(function(e){document.addEventListener(e,s,true)});})();
    """

  static let faviconScript = """
    (function(){var l=document.querySelector('link[rel~="apple-touch-icon"]')||document.querySelector('link[rel~="icon"]')||document.querySelector('link[rel="shortcut icon"]');return l?l.href:(location.origin+'/favicon.ico')})()
    """
}

/// Breaks the WKUserContentController -> handler retain cycle.
final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
  let fn: @MainActor (WKScriptMessage) -> Void
  init(_ fn: @escaping @MainActor (WKScriptMessage) -> Void) { self.fn = fn }
  func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
    MainActor.assumeIsolated { fn(message) }
  }
}
