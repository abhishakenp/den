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
///   snapshot {id, path, width?, format?}      -> {pending}; later event webviews.snapshot {id, path, ok}
///                                                 width (pt) makes a small copy (hover previews); format png|jpeg
///   eval {id, plugin, script, request?, timeoutMs?} -> {request}; later webviews.evalResult {request, webview, ok, value | error}
///                                                 reads a live page; needs `allowScript(plugin, host)` (session:<host>)
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
  /// The `extensions` service: attaches its controller to new configurations, supplies extension
  /// pages' configurations, and watches store pages. nil (or nothing installed) costs nothing.
  weak var extensionHooks: ExtensionsService?
  /// zoom / find / print / inspect / viewSource (PageActions.swift); set by `DenRuntime`.
  public internal(set) var pageActions: PageActions?

  public init(host: ServiceHost) { self.host = host }

  /// Hooks for host services that style or script pages per web view (`pagestyle`, `vault`).
  /// `configure` runs before each WKWebView is created, `created` right after, and
  /// `navigating` on every main-frame navigation decision, before the new document exists
  /// (so a user stylesheet set there applies from the first paint).
  public var configureHooks: [@MainActor (WebRecord, WKWebViewConfiguration) -> Void] = []
  public var createdHooks: [@MainActor (WebRecord, WKWebView) -> Void] = []
  public var navigatingHooks: [@MainActor (WebRecord, WKWebView, URL) -> Void] = []

  /// Safari's `Version/x.y Safari/605.1.15` suffix, so den's user agent is exactly Safari's for
  /// this macOS (WKWebView's default omits it, and Google's sign-in then refuses the browser as
  /// an embedded web view). Read once, at the first web view, from Safari's own Info.plist.
  public nonisolated static let applicationNameForUserAgent: String = {
    let plist = NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist")
    var version = plist?["CFBundleShortVersionString"] as? String ?? ""
    if version.isEmpty {
      let v = ProcessInfo.processInfo.operatingSystemVersion
      version = "\(v.majorVersion).\(v.minorVersion)"
    }
    return "Version/\(version) Safari/605.1.15"
  }()

  public func handle(method: String, args: Value) -> Value {
    if method == "create" { return create(args) }
    if method == "list" { return .array(order.map { .string($0) }) }
    if method == "setLinkPolicy", args.str("id") == "*" {
      defaultRules = args.list("rules").compactMap(LinkRule.init)
      return .ok
    }
    var args = args
    // Page actions (menu bar): `id` defaults to the page in front (peek, else the focused pane).
    if args.str("id").isEmpty, PageActions.methods.contains(method) || ["back", "forward", "reload", "stop", "get"].contains(method),
       let front = pageActions?.frontId {
      args = args.with("id", .string(front))
    }
    guard let r = records[args.str("id")] else { return .error("webviews: no webview '\(args.str("id"))'") }
    if PageActions.methods.contains(method) { return pageActions?.handle(method, r, args) ?? .error("webviews: no page actions") }
    switch method {
    case "navigate":
      guard let url = Self.normalize(args.str("url")) else { return .error("webviews: bad url") }
      r.url = url.absoluteString
      r.interactionState = nil
      r.webView?.open(url)
    case "back": r.webView?.goBack()
    case "forward": r.webView?.goForward()
    case "reload": if args.flag("fromOrigin") { r.webView?.reloadFromOrigin() } else { r.webView?.reload() }
    case "stop": r.webView?.stopLoading()
    case "close": close(r)
    case "suspend": suspend(r)
    case "snapshot":
      snapshot(r, path: args.str("path"), width: args["width"].double.map { CGFloat($0) }, jpeg: args.str("format") == "jpeg")
      return ["pending": true]
    case "eval": return evaluate(r, args)
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
    // Extension pages (options, popups opened as tabs) run in their extension's configuration.
    let extensionPage = extensionHooks?.configuration(for: r.url)
    let config = extensionPage ?? WKWebViewConfiguration()
    if extensionPage == nil {
      config.websiteDataStore = store(for: r.profile)
      extensionHooks?.prepare(config)
    }
    config.preferences.isElementFullscreenEnabled = true
    config.preferences.inactiveSchedulingPolicy = .suspend
    config.applicationNameForUserAgent = Self.applicationNameForUserAgent
    config.userContentController.addUserScript(WKUserScript(source: Self.mediaScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    config.userContentController.add(scriptHandler, name: "denMedia")
    for h in configureHooks { h(r, config) }
    config.userContentController.addUserScript(WKUserScript(source: DenWebView.contextScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    config.userContentController.add(scriptHandler, name: "denContext")
    let w = DenWebView(frame: .zero, configuration: config)
    w.service = self
    w.recordId = r.id
    w.navigationDelegate = self
    w.uiDelegate = self
    w.allowsBackForwardNavigationGestures = true
    w.allowsMagnification = true
    w.isInspectable = true
    w.underPageBackgroundColor = .clear
    r.webView = w
    observe(r, w)
    for h in createdHooks { h(r, w) }
    let start = { [weak w] in
      guard let w else { return }
      if let state = r.interactionState {
        w.interactionState = state
        r.interactionState = nil
        // Some states (e.g. loadHTMLString pages) don't restore; fall back to the last URL.
        if w.backForwardList.currentItem == nil, let url = URL(string: r.url), r.url != "about:blank" { w.open(url) }
      } else if let url = URL(string: r.url), r.url != "about:blank" {
        w.open(url)
      }
    }
    // With extensions, the first load waits (briefly) for them, so blockers apply to it too.
    if let ext = extensionHooks { ext.whenReady(start) } else { start() }
    return w
  }

  /// Re-creates a live web view with a fresh configuration, keeping its back/forward state
  /// (the extension controller can only be attached before a web view exists).
  func rebuild(_ r: WebRecord) {
    guard let w = r.webView else { return }
    r.interactionState = w.interactionState
    destroyView(r)
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
        self?.pageActions?.urlChanged(r, wv)  // per-site zoom
        self?.host.emit("webviews.url", ["id": .string(id), "url": .string(u)])
        self?.extensionHooks?.pageChanged(wv)
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
      "zoom": .double(Double(r.webView?.pageZoom ?? 1)),
    ]
  }

  func destroyView(_ r: WebRecord) {
    guard let w = r.webView else { return }
    r.observers.forEach { $0.invalidate() }
    r.observers = []
    w.configuration.userContentController.removeAllScriptMessageHandlers()
    w.navigationDelegate = nil
    w.uiDelegate = nil
    prompts?.cancel(for: w)
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

  func snapshot(_ r: WebRecord, path: String, width: CGFloat? = nil, jpeg: Bool = false) {
    let id = r.id
    let done: @MainActor (NSImage?) -> Void = { [weak self] taken in
      // A web view that isn't in a window can't draw: fall back to the last snapshot.
      let img = taken ?? r.snapshot
      var ok = false
      if let img, !path.isEmpty, let data = Self.encode(img, width: width, jpeg: jpeg) {
        ok = (try? data.write(to: URL(fileURLWithPath: path))) != nil
      }
      // Only full-size snapshots replace the one a suspended tab shows.
      if let taken, width == nil { r.snapshot = taken }
      self?.host.emit("webviews.snapshot", ["id": .string(id), "path": .string(path), "ok": .bool(ok)])
    }
    if let w = r.webView {
      let config = WKSnapshotConfiguration()
      if let width { config.snapshotWidth = NSNumber(value: Double(width)) }
      w.takeSnapshot(with: config) { img, _ in MainActor.assumeIsolated { done(img) } }
    } else {
      DispatchQueue.main.async { done(nil) }
    }
  }

  /// PNG (or JPEG, quality 0.72) of `img`, scaled to `width` points at 2x when given.
  static func encode(_ img: NSImage, width: CGFloat?, jpeg: Bool) -> Data? {
    var rep: NSBitmapImageRep?
    if let width, img.size.width > 0 {
      let px = Int((width * 2).rounded()), py = Int((img.size.height * width * 2 / img.size.width).rounded())
      guard px > 0, py > 0, let b = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: py, bitsPerSample: 8, samplesPerPixel: 4,
                                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: b)
      NSGraphicsContext.current?.imageInterpolation = .high
      img.draw(in: NSRect(x: 0, y: 0, width: px, height: py))
      NSGraphicsContext.restoreGraphicsState()
      rep = b
    } else if let tiff = img.tiffRepresentation {
      rep = NSBitmapImageRep(data: tiff)
    }
    return jpeg ? rep?.representation(using: .jpeg, properties: [.compressionFactor: 0.72]) : rep?.representation(using: .png, properties: [:])
  }

  // MARK: Page reads

  /// Gate for `eval`: may `plugin` read a page on `host`? The runtime wires this to the plugin's
  /// declared `session:<domain>` permissions; nil denies everything.
  public var allowScript: ((_ plugin: String, _ host: String) -> Bool)?
  public var maxScriptBytes = 4096
  private var nextEval = 1

  /// Runs `script` (a function body that `return`s JSON-compatible data) in the live page, in an
  /// isolated content world the page's own scripts can't see. Only live views: reading a page never
  /// loads or wakes one.
  func evaluate(_ r: WebRecord, _ args: Value) -> Value {
    let plugin = args.str("plugin")
    guard let w = r.webView else { return .error("webviews: '\(r.id)' is not loaded") }
    let host = (w.url ?? URL(string: r.url))?.host?.lowercased() ?? ""
    guard !host.isEmpty, allowScript?(plugin, host) == true else { return .error("webviews: '\(plugin)' may not read \(host.isEmpty ? "this page" : host)") }
    let script = args.str("script")
    guard !script.isEmpty, script.utf8.count <= maxScriptBytes else { return .error("webviews: script must be 1…\(maxScriptBytes) bytes") }
    var request = args.str("request")
    if request.isEmpty { request = "eval-\(nextEval)"; nextEval += 1 }
    let id = r.id
    var finished = false
    let finish: @MainActor (Value) -> Void = { [weak self] payload in
      guard !finished else { return }
      finished = true
      self?.host.emit("webviews.evalResult", payload.with("request", .string(request)).with("webview", .string(id)))
    }
    let timeout = DispatchWorkItem { MainActor.assumeIsolated { finish(["ok": false, "error": "webviews: script timed out"]) } }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(max(200, min(Int(args.num("timeoutMs", 5000)), 20_000))), execute: timeout)
    w.callAsyncJavaScript(script, arguments: [:], in: nil, in: .world(name: "den-plugins")) { result in
      MainActor.assumeIsolated {
        timeout.cancel()
        switch result {
        case let .success(v): finish(["ok": true, "value": Self.jsValue(v)])
        case let .failure(e): finish(["ok": false, "error": .string("webviews: script failed: \(e.localizedDescription)")])
        }
      }
    }
    return ["request": .string(request)]
  }

  /// WebKit's bridged JS values (NSNumber, NSString, NSArray, NSDictionary, NSNull) as `Value`.
  nonisolated static func jsValue(_ any: Any?, depth: Int = 0) -> Value {
    guard let any, depth < 12 else { return .null }
    switch any {
    case let n as NSNumber:
      if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
      let d = n.doubleValue
      return d == d.rounded() && abs(d) < 9e15 ? .int(Int64(d)) : .double(d)
    case let s as String: return .string(s)
    case let a as [Any]: return .array(a.prefix(500).map { jsValue($0, depth: depth + 1) })
    case let o as [String: Any]: return .object(o.keys.sorted().map { ($0, jsValue(o[$0], depth: depth + 1)) })
    default: return .null
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
    if let u = URL(string: t), let scheme = u.scheme, ["http", "https", "about", "file", "data", "webkit-extension"].contains(scheme.lowercased()) { return u }
    if !t.contains(" "), t.contains(".") || t.hasPrefix("localhost") { return URL(string: "https://" + t) }
    return nil
  }

  // MARK: Delegates

  func recordFor(_ w: WKWebView) -> WebRecord? { records.values.first { $0.webView === w } }

  public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
    guard let r = recordFor(webView), let target = action.request.url else { return decisionHandler(.allow) }
    let mainFrame = action.targetFrame?.isMainFrame ?? true
    let rules = r.rules.isEmpty ? defaultRules : r.rules
    var mods = Set<Chord.Mod>()
    let f = action.modifierFlags
    if f.contains(.command) { mods.insert(.cmd) }
    if f.contains(.shift) { mods.insert(.shift) }
    if f.contains(.option) { mods.insert(.opt) }
    if f.contains(.control) { mods.insert(.ctrl) }
    if let event = LinkPolicy.route(rules: rules, source: webView.url, target: target, isLinkClick: action.navigationType == .linkActivated, isMainFrame: mainFrame, modifiers: mods) {
      decisionHandler(.cancel)
      host.emit(event, ["id": .string(r.id), "url": .string(target.absoluteString), "source": .string(webView.url?.absoluteString ?? "")])
      return
    }
    if mainFrame { for h in navigatingHooks { h(r, webView, target) } }
    // Browser link clicks: ⌘-click and middle-click open a background tab, ⌘⇧-click a selected one.
    if let bg = LinkPolicy.newTab(isLinkClick: action.navigationType == .linkActivated, target: target, modifiers: mods, buttonNumber: action.buttonNumber) {
      decisionHandler(.cancel)
      host.emit("webviews.newWindow", ["id": .string(r.id), "url": .string(target.absoluteString), "background": .bool(bg)])
      return
    }
    decisionHandler(.allow)
  }

  public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard let r = recordFor(webView) else { return }
    extensionHooks?.pageChanged(webView)
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

  // MARK: Page prompts and error pages (WebPrompts.swift, WebErrorPage.swift)

  /// Host-drawn dialogs for alert/confirm/prompt, HTTP sign-in and camera/mic (set by DenRuntime).
  public var prompts: WebPrompts?

  public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
    guard let prompts else { return completionHandler() }
    prompts.alert(message, frame: frame, webView: webView, done: completionHandler)
  }

  public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
    guard let prompts else { return completionHandler(false) }
    prompts.confirm(message, frame: frame, webView: webView, done: completionHandler)
  }

  public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
    guard let prompts else { return completionHandler(nil) }
    prompts.prompt(prompt, defaultText: defaultText, frame: frame, webView: webView, done: completionHandler)
  }

  public func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
    guard let prompts else { return decisionHandler(.deny) }
    prompts.media(origin, type: type, webView: webView, done: decisionHandler)
  }

  /// `<input type=file>`: an open panel as a sheet on the page's window.
  public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
    let panel = Self.openPanel(multiple: parameters.allowsMultipleSelection, directories: parameters.allowsDirectories)
    let done: (NSApplication.ModalResponse) -> Void = { r in MainActor.assumeIsolated { completionHandler(r == .OK ? panel.urls : nil) } }
    if let w = webView.window { panel.beginSheetModal(for: w, completionHandler: done) } else { panel.begin(completionHandler: done) }
  }

  static func openPanel(multiple: Bool, directories: Bool) -> NSOpenPanel {
    let p = NSOpenPanel()
    p.canChooseFiles = true
    p.canChooseDirectories = directories
    p.allowsMultipleSelection = multiple
    p.resolvesAliases = true
    p.prompt = "Choose"
    return p
  }

  /// HTTP Basic/Digest/NTLM ask for a username and password; everything else (server trust,
  /// client certificates) gets WebKit's default handling. Cancel lets the server's 401 page show.
  public func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    let m = challenge.protectionSpace.authenticationMethod
    guard let prompts, [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM].contains(m) else {
      return completionHandler(.performDefaultHandling, nil)
    }
    prompts.signIn(challenge.protectionSpace, previousFailures: challenge.previousFailureCount, proposedUser: challenge.proposedCredential?.user, webView: webView) { cred in
      if let cred { completionHandler(.useCredential, cred) } else { completionHandler(.rejectProtectionSpace, nil) }
    }
  }

  public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    let url = ((error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url
    guard let url, let page = WebErrorPage.page(for: error, url: url) else { return }
    webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: WebErrorPage.html(page, url: url, colors: prompts?.errorPageColors))
  }

  func didReceive(_ msg: WKScriptMessage) {
    if msg.name == "denContext" {
      guard let w = msg.webView as? DenWebView, let b = msg.body as? [String: Any] else { return }
      w.context = .init(link: b["link"] as? String ?? "", image: b["image"] as? String ?? "", selection: b["selection"] as? String ?? "")
      return
    }
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
