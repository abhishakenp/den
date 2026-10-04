import AppKit
import CordisValue
import CryptoKit
import WebKit

/// What a page's media and forms are doing, as den's page script reports it (PageScripts).
public struct PageMedia: Equatable {
  /// Audible media is playing (the tab row's speaker).
  public var audible = false
  /// Any media is playing, muted or not.
  public var playing = false
  /// System picture in picture is active.
  public var pip = false
  /// A form field holds input that wasn't submitted.
  public var dirty = false
  /// The frame's main playing video (or the mini player's video, even while paused).
  public var video: Value?
  /// Now playing: the last media element that played with sound, and the page's Media Session
  /// info `{title, artist, album, art, paused, dur, video, acts}`. nil once it's gone or stopped.
  public var now: Value?

  init() {}
  init(_ v: Value) {
    audible = v.flag("a")
    playing = v.flag("p")
    pip = v.flag("pip")
    dirty = v.flag("d")
    video = v["v"].isNull ? nil : v["v"]
    // Not `isNull ? nil : v["n"]`: Value is ExpressibleByNilLiteral, so that `nil` would be `.null`.
    if !v["n"].isNull { now = v["n"] }
  }
}

/// A pop-up a page tried to open without a click (Safari's "Block and Notify").
public struct BlockedPopup: Equatable {
  public let url: String
  /// The size it asked for, when it asked for a pop-up window (`window.open` features).
  public let size: CGSize?
  public let popup: Bool
}

/// One tab's web content. The WKWebView exists only while materialized (shown at least once and
/// not discarded); otherwise the record keeps url + interactionState, and its snapshot on disk.
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
  /// The last snapshot of the page, a small JPEG on disk (never kept in memory).
  public var snapshotPath: String?
  /// Muted by the user (`setMuted`); survives discards while the tab lives.
  public var muted = false
  /// Media and form state per frame ("main", or the subframe's URL), and the frame it came from.
  public fileprivate(set) var frames: [String: (frame: WKFrameInfo, media: PageMedia)] = [:]
  /// Set while the view is being discarded, so nothing adopts it on the way out.
  public fileprivate(set) var discarding = false
  public fileprivate(set) var webView: WKWebView?
  fileprivate var observers: [NSKeyValueObservation] = []
  /// Set while a snapshot is being taken: what runs when it's done.
  fileprivate var snapshotWaiters: [@MainActor () -> Void]?
  /// A snapshot of the page is being taken right now.
  public var isCapturingSnapshot: Bool { snapshotWaiters != nil }
  /// The web process died (`webViewWebContentProcessDidTerminate`): the crash page shows the
  /// next time the page is on screen, and Reload brings the page back.
  public fileprivate(set) var crashed = false
  /// The page has painted (its first visually non-empty layout) since this view was created.
  /// Until then the view draws no background of its own, so the card's colour shows instead of
  /// WebKit's white.
  public fileprivate(set) var painted = false
  /// The page's background colour, sampled from its last snapshot (the card shows it while a
  /// restored or reloaded view has nothing to draw yet).
  public var backgroundColor: CGColor?

  init(id: String, profile: String, url: String) { (self.id, self.profile, self.url) = (id, profile, url) }

  /// The page that opened this one with `window.open` / `target=_blank` (its `window.opener`).
  public internal(set) var opener: String?
  /// Shown in a pop-up window (`window.open` with window features) rather than a tab.
  public internal(set) var popupWindow: String?
  /// Pop-ups this page tried to open without a click, since its last navigation.
  public internal(set) var blockedPopups: [BlockedPopup] = []

  public var isSuspended: Bool { webView == nil && (interactionState != nil || snapshotPath != nil) }
  /// A private window's page (`private` or `private:<window>` profile): nothing about it is
  /// written to disk (no snapshot, no remembered zoom).
  public var isPrivate: Bool { WebViewsService.isPrivate(profile) }

  /// The page's media state, all frames together.
  public var media: PageMedia {
    var m = PageMedia()
    for (_, f) in frames {
      m.audible = m.audible || f.media.audible
      m.playing = m.playing || f.media.playing
      m.pip = m.pip || f.media.pip
      m.dirty = m.dirty || f.media.dirty
    }
    m.video = videoFrame?.media.video
    m.now = nowFrame?.media.now
    return m
  }

  /// The now-playing info last reported as `webviews.nowPlaying` (nil: none).
  public fileprivate(set) var nowPlaying: Value?
  /// `create {userAgent}`: a custom user agent for this page (web panels ask for a phone's).
  public var userAgent: String?

  /// The frame whose media is "now playing": a playing one before a paused one, the main frame
  /// first.
  public var nowFrame: (frame: WKFrameInfo, media: PageMedia)? {
    var best: (frame: WKFrameInfo, media: PageMedia)?
    for key in frames.keys.sorted(by: { a, b in a == "main" && b != "main" }) {
      guard let f = frames[key], let n = f.media.now else { continue }
      if best == nil || (best?.media.now?.flag("paused") == true && !n.flag("paused")) { best = f }
    }
    return best
  }

  /// The frame with the biggest playing video (the main frame wins a tie).
  public var videoFrame: (frame: WKFrameInfo, media: PageMedia)? {
    var best: (frame: WKFrameInfo, media: PageMedia)?
    var area = -1.0
    for key in frames.keys.sorted(by: { a, b in a == "main" && b != "main" }) {
      guard let f = frames[key], let v = f.media.video else { continue }
      let a = v.num("cw") * v.num("ch")
      if a > area { area = a; best = f }
    }
    return best
  }
}

/// `webviews` service.
///
/// Methods:
///   create {id?, url?, profile?, userAgent?}  -> {id}   (lazy: no WKWebView until shown; userAgent "mobile" = Safari on iPhone)
///   mediaControl {id, action, value?}          -> play|pause|toggle|next|previous|seek|skip|stop on the page's now-playing media
///   navigate {id, url}  back {id}  forward {id}  reload {id}  stop {id}
///   close {id}                                 -> destroys the web view and record
///   suspend {id, force?}                       -> full discard: saves interactionState (+ a snapshot on disk), destroys
///                                                 the view. Without force it refuses a tab that is on screen, plays
///                                                 media, is in picture in picture, uses the camera/mic or holds
///                                                 unsaved form input: {suspended: false, reason}
///   setMuted {id, muted}                       -> mutes the page (all frames, WebAudio too); kept across discards
///   pauseMedia {id}                            -> pauses every video and audio element of a page that is not on screen
///                                                 (no window, no PiP): {paused: true} or {paused: false, reason}
///   setAutoplay {allowed}                      -> all web views: whether media may start without a click. Applies to
///                                                 pages created from now on (WebKit fixes it per configuration)
///   snapshot {id, path, width?, format?}      -> {pending}; later event webviews.snapshot {id, path, ok}
///                                                 width (pt) makes a small copy (hover previews); format png|jpeg
///   eval {id, plugin, script, request?, timeoutMs?} -> {request}; later webviews.evalResult {request, webview, ok, value | error}
///                                                 reads a live page; needs `allowScript(plugin, host)` (session:<host>)
///   get {id}                                   -> {id, url, title, favicon, loading, progress, canGoBack, canGoForward, audio, muted,
///                                                 media: {playing, pip, dirty, video?}, suspended, live, snapshot,
///                                                 opener, popupWindow, blockedPopups: [url]}
///   openBlocked {id}                           -> opens the pop-ups the page tried without a click: {opened}
///   list                                       -> [id]
///   setLinkPolicy {id | "*", rules: [{when: crossSite|sameSite|any, hosts?: [suffix], modifiers?: [cmd,...], event}]}
///   watchLinks {modifier: shift|none|off, yieldTo?: [css selector]}  (all web views; LinkHover.swift)
///                                             -> events webviews.linkHover {id, url, text, rect: {x,y,w,h} (window pt,
///                                                top-left origin), yield} and webviews.linkHoverEnd {id}
///   watchStatus {enabled}                     -> events webviews.linkStatus {id, url} on plain hover or keyboard focus
///                                                (url "" when the pointer leaves the link); same script as watchLinks
///
/// Events: webviews.title {id,title}  webviews.url {id,url}  webviews.favicon {id,url}
///   webviews.progress {id,progress,loading}  webviews.state {id,canGoBack,canGoForward}
///   webviews.audio {id,playing}  webviews.newWindow {id,url,background?,webview?}  webviews.crashed {id}
///   webviews.popup {id,opener,url}  webviews.popupBlocked {id,url,count}  webviews.closeRequested {id,opener}  (Popups.swift)
///   webviews.suspended {id}  webviews.snapshot {id,path,ok}  webviews.muted {id,muted}  webviews.media {id, playing, pip, dirty}
///   webviews.nowPlaying {id, now: {title, artist, album, art, paused, dur, video, acts} | null, muted}
///   + any event named by a link rule: {id,url,source}
@MainActor
public final class WebViewsService: NSObject, HostService, WKNavigationDelegate, WKUIDelegate {
  public let name = "webviews"
  let host: ServiceHost
  public internal(set) var records: [String: WebRecord] = [:]
  var order: [String] = []
  private var defaultRules: [LinkRule] = []
  private var stores: [String: WKWebsiteDataStore] = [:]
  private var nextId = 1
  /// Pop-up web views (`popup-<n>`, `tab-o<n>`; Popups.swift).
  var nextPopup = 1
  /// Shows a pop-up's web view in a pop-up window (the `window` service): record id and the size
  /// the page asked for. False when there is no window to show it in.
  public var showPopupWindow: ((String, CGSize?) -> Bool)?
  /// Closes the pop-up window showing a record (its page called `window.close()`).
  public var closePopupWindow: ((String) -> Void)?
  private lazy var scriptHandler = ScriptMessageProxy { [weak self] msg in self?.didReceive(msg) }
  /// The `extensions` service: attaches its controller to new configurations, supplies extension
  /// pages' configurations, and watches store pages. nil (or nothing installed) costs nothing.
  weak var extensionHooks: ExtensionsService?
  /// zoom / find / print / inspect / viewSource (PageActions.swift); set by `DenRuntime`.
  public internal(set) var pageActions: PageActions?
  /// Playback updates (`{k: "t", ...}`) of a page whose video the mini player shows.
  public var onPlayback: ((String, Value) -> Void)?
  /// A page's media state changed (the mini player follows it).
  public var onMedia: ((WebRecord) -> Void)?
  /// A live view is about to be discarded or closed (the mini player lets go of it).
  public var willDestroy: ((String) -> Void)?
  /// A navigation finished or failed (the restore placeholder waits for it).
  public var onFinish: ((String) -> Void)?
  /// Where discarded pages' snapshots go: a per-process temporary folder, removed at quit.
  public let snapshotDir = FileManager.default.temporaryDirectory.appendingPathComponent("den-\(getpid())/snapshots", isDirectory: true)
  /// Widest stored snapshot, in pixels: sharp enough to stand in for the page for the moment a
  /// restore takes, and for 320 pt hover previews at 2x.
  public var snapshotMaxWidth: CGFloat = 1280

  public init(host: ServiceHost) { self.host = host }

  /// Hooks for host services that style or script pages per web view (`pagestyle`, `vault`).
  /// `configure` runs before each WKWebView is created, `created` right after, and
  /// `navigating` on every main-frame navigation decision, before the new document exists
  /// (so a user stylesheet set there applies from the first paint).
  public var configureHooks: [@MainActor (WebRecord, WKWebViewConfiguration) -> Void] = []
  /// `watchLinks`: nothing installed until a plugin asks.
  public let links = LinkHover()
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
    if method == "watchLinks" { return watchLinks(args) }
    if method == "watchStatus" { return watchStatus(args) }
    if method == "setLinkPolicy", args.str("id") == "*" {
      defaultRules = args.list("rules").compactMap(LinkRule.init)
      return .ok
    }
    if method == "setMenu" { return scripting.setMenu(args) }
    if method == "setContentRules" { return scripting.setContentRules(args) }
    if method == "setAutoplay" {
      autoplayAllowed = args.flag("allowed", true)
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
    case "suspend": return suspend(r, force: args.flag("force"))
    case "setMuted": setMuted(r, args.flag("muted"))
    case "pauseMedia": return pauseMedia(r)
    case "mediaControl": return mediaControl(r, args.str("action"), args.num("value"))
    case "snapshot":
      if !args["rect"].isNull || args.flag("full") || args.flag("clipboard") || !args.str("folder").isEmpty { return capture(r, args) }
      // A private page's picture is never written for previews (a capture you ask for still is).
      if r.isPrivate { return .error("webviews: '\(r.id)' is private") }
      snapshot(r, path: args.str("path"), width: args["width"].double.map { CGFloat($0) }, jpeg: args.str("format") == "jpeg")
      return ["pending": true]
    case "eval": return evaluate(r, args)
    case "inject": return scripting.inject(r, args)
    case "get": return state(r)
    case "openBlocked": return openBlocked(r)
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
    let r = WebRecord(id: id, profile: args.str("profile", "default"), url: url)
    let ua = args.str("userAgent")
    r.userAgent = ua == "mobile" ? Self.mobileUserAgent : (ua.isEmpty ? nil : ua)
    records[id] = r
    order.append(id)
    return ["id": .string(id)]
  }

  public func record(_ id: String) -> WebRecord? { records[id] }

  /// `create {userAgent: "mobile"}`: Safari on an iPhone, so sites send their phone layout (web
  /// panels). iOS 26 Safari reports its OS as 18_6 (Apple froze that part of the string).
  public nonisolated static var mobileUserAgent: String {
    let version = applicationNameForUserAgent.split(separator: " ").first.map { String($0.dropFirst("Version/".count)) } ?? "26.0"
    return "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version) Mobile/15E148 Safari/604.1"
  }

  /// `mediaControl {id, action, value?}`: plays, pauses, skips or stops the page's now-playing
  /// media (`PageMedia.now`), in the frame that reported it. `next` / `previous` run the page's
  /// Media Session handlers (without one, `previous` restarts the track and `next` fails).
  func mediaControl(_ r: WebRecord, _ action: String, _ value: Double) -> Value {
    guard ["play", "pause", "toggle", "next", "previous", "seek", "skip", "stop"].contains(action) else {
      return .error("webviews: unknown media action '\(action)'")
    }
    guard r.webView != nil, let f = r.nowFrame else { return .error("webviews: '\(r.id)' plays nothing") }
    if action == "next", !(f.media.now?["acts"].array ?? []).contains(.string("nexttrack")) { return .error("webviews: the page has no next track") }
    runPageScript(r.id, "return window.__denMedia.act(a, x)", arguments: ["a": action, "x": value], frame: f.frame)
    return .ok
  }

  /// Creates the WKWebView on first show (or after a discard), restoring saved state.
  public func materialize(_ id: String) -> WKWebView? {
    guard let r = records[id] else { return nil }
    if let w = r.webView { return w }
    // Extension pages (options, popups opened as tabs) run in their extension's configuration.
    let extensionPage = extensionHooks?.configuration(for: r.url)
    // WebKit hands every page of an extension the same configuration: each tab gets its own copy
    // and content controller, or the second page re-adds den's handlers and WebKit throws.
    let config = (extensionPage?.copy() as? WKWebViewConfiguration) ?? WKWebViewConfiguration()
    if extensionPage != nil { config.userContentController = WKUserContentController() }
    if extensionPage == nil {
      config.websiteDataStore = store(for: r.profile)
      extensionHooks?.prepare(config)
    }
    let w = makeView(r, config)
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

  /// den's settings, scripts and hooks on `config`, then the web view itself (delegates,
  /// observers, created hooks), stored as `r`'s view. Loads nothing.
  func makeView(_ r: WebRecord, _ config: WKWebViewConfiguration) -> DenWebView {
    config.preferences.isElementFullscreenEnabled = true
    // Every window.open reaches `createWebViewWith`, which decides like Safari: a click opens it,
    // anything else is blocked with a notice (WebKit's own check would block it silently).
    config.preferences.javaScriptCanOpenWindowsAutomatically = true
    config.preferences.inactiveSchedulingPolicy = .suspend
    if !autoplayAllowed { config.mediaTypesRequiringUserActionForPlayback = .all }
    config.applicationNameForUserAgent = Self.applicationNameForUserAgent
    // Picture in picture is off in WKWebView on macOS unless this (private) preference is set:
    // without it `requestPictureInPicture()` fails with NotSupportedError. KVC finds the
    // `_setAllowsPictureInPictureMediaPlayback:` setter; guarded so a WebKit without it is fine.
    if config.preferences.responds(to: NSSelectorFromString("_setAllowsPictureInPictureMediaPlayback:")) {
      config.preferences.setValue(true, forKey: "allowsPictureInPictureMediaPlayback")
    }
    config.userContentController.addUserScript(WKUserScript(source: PageScripts.media, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: PageScripts.world))
    config.userContentController.add(scriptHandler, contentWorld: PageScripts.world, name: PageScripts.handler)
    config.userContentController.addUserScript(WKUserScript(source: PageScripts.sessionHook, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
    for h in configureHooks { h(r, config) }
    for list in ruleLists { config.userContentController.add(list) }
    config.userContentController.addUserScript(WKUserScript(source: DenWebView.contextScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    config.userContentController.add(scriptHandler, name: "denContext")
    let w = DenWebView(frame: .zero, configuration: config)
    w.service = self
    w.recordId = r.id
    TestMode.keepActive(w)
    w.navigationDelegate = self
    w.uiDelegate = self
    w.allowsBackForwardNavigationGestures = true
    w.allowsMagnification = true
    w.isInspectable = true
    if let ua = r.userAgent { w.customUserAgent = ua }
    w.underPageBackgroundColor = .clear
    // No white flash: until the page paints, the view draws nothing, so the card behind it (the
    // page's last known colour, or den's surface) shows instead of WebKit's white. WebKit's
    // `_drawsBackground` and rendering-progress events are SPI, checked before use.
    r.painted = false
    if w.responds(to: NSSelectorFromString("_setDrawsBackground:")) { w.setValue(false, forKey: "drawsBackground") }
    if w.responds(to: NSSelectorFromString("_setObservedRenderingProgressEvents:")) {
      w.setValue(NSNumber(value: Self.paintEvents), forKey: "observedRenderingProgressEvents")
    }
    r.webView = w
    r.discarding = false
    observe(r, w)
    if links.enabled { links.install(w, handler: scriptHandler) }
    if r.muted { Self.applyMuted(w, true) }
    for h in createdHooks { h(r, w) }
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
      "audio": .bool(r.audio), "muted": .bool(r.muted), "suspended": .bool(r.isSuspended), "live": .bool(r.webView != nil),
      "profile": .string(r.profile), "snapshot": r.snapshotPath.map { .string($0) } ?? .null, "media": mediaValue(r.media),
      "zoom": .double(Double(r.webView?.pageZoom ?? 1)),
      "opener": r.opener.map { .string($0) } ?? .null, "popupWindow": r.popupWindow.map { .string($0) } ?? .null,
      "blockedPopups": .array(r.blockedPopups.map { .string($0.url) }),
    ]
  }

  func mediaValue(_ m: PageMedia) -> Value {
    ["playing": .bool(m.playing), "audible": .bool(m.audible), "pip": .bool(m.pip), "dirty": .bool(m.dirty), "video": m.video ?? .null, "now": m.now ?? .null]
  }

  /// Tests only: WebContent pids of every web view destroyed so far, so a test harness can check
  /// they exited (see `DenRuntime.tearDown`).
  public private(set) var destroyedProcessIds = Set<pid_t>()

  static func webProcessId(_ w: WKWebView) -> pid_t? {
    guard w.responds(to: NSSelectorFromString("_webProcessIdentifier")),
          let p = (w.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, p > 0 else { return nil }
    return p
  }

  func destroyView(_ r: WebRecord) {
    guard let w = r.webView else { return }
    if TestMode.active, let p = Self.webProcessId(w) { destroyedProcessIds.insert(p) }
    willDestroy?(r.id)
    links.forget(w)
    r.observers.forEach { $0.invalidate() }
    r.observers = []
    r.frames = [:]
    if r.audio {
      r.audio = false
      host.emit("webviews.audio", ["id": .string(r.id), "playing": false])
    }
    if case .some = r.nowPlaying {
      r.nowPlaying = nil
      host.emit("webviews.nowPlaying", ["id": .string(r.id), "now": .null, "muted": .bool(r.muted)])
    }
    // denMedia, and plugins' `den` handlers in their content worlds (PageScripting).
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
    if let p = r.snapshotPath { try? FileManager.default.removeItem(atPath: p) }
    records[r.id] = nil
    order.removeAll { $0 == r.id }
    host.emit("webviews.closed", ["id": .string(r.id)])
  }

  /// `setAutoplay`: false makes media in pages created from now on wait for a click.
  public private(set) var autoplayAllowed = true

  /// Pauses a background page's media (battery saver). A page on screen (a pane, peek, Little
  /// Arc, the mini player) or in picture in picture keeps playing.
  func pauseMedia(_ r: WebRecord) -> Value {
    guard let w = r.webView else { return ["paused": false, "reason": "notLive"] }
    if r.media.pip { return ["paused": false, "reason": "pip"] }
    if w.window != nil { return ["paused": false, "reason": "visible"] }
    guard r.media.playing else { return ["paused": false, "reason": "notPlaying"] }
    w.pauseAllMediaPlayback {}
    return ["paused": true]
  }

  /// Why a live page must not be discarded right now, or nil. Checked on every idle discard; an
  /// explicit close (`force`) skips it.
  public func keepReason(_ r: WebRecord) -> String? {
    guard let w = r.webView else { return nil }
    let m = r.media
    if m.pip { return "pip" }
    if m.playing { return "media" }
    if w.cameraCaptureState != .none || w.microphoneCaptureState != .none { return "capture" }
    if m.dirty { return "form" }
    if w.window != nil { return "visible" }  // a pane, peek, Little Arc, the mini player (or its snapshot being taken)
    return nil
  }

  /// Full discard: keep back/forward + scroll state, free the WKWebView and its WebContent process.
  /// The snapshot was saved to disk when the page left the screen (`captureSnapshot`); a page still
  /// on screen (forced) is captured first.
  func suspend(_ r: WebRecord, force: Bool) -> Value {
    guard let w = r.webView, !r.discarding else { return ["suspended": true] }
    if !force, let why = keepReason(r) { return ["suspended": false, "reason": .string(why)] }
    r.discarding = true
    r.interactionState = w.interactionState
    let finish: @MainActor () -> Void = { [weak self] in
      guard r.discarding, r.webView === w else { return }
      self?.destroyView(r)
      self?.host.emit("webviews.suspended", ["id": .string(r.id)])
    }
    if w.window != nil { captureSnapshot(r, then: finish) } else { finish() }
    return ["suspended": true]
  }

  /// Saves a small JPEG of the page to disk (`snapshotPath`), for the placeholder a restored tab
  /// shows at once and for hover previews of pages that aren't live. Only a view in a window can
  /// draw; the encode runs off the main thread. `then` runs once the view is no longer needed
  /// (at most 3 s later).
  public func captureSnapshot(_ r: WebRecord, then: (@MainActor () -> Void)? = nil) {
    // Private pages leave no picture on disk.
    guard let w = r.webView, w.window != nil, w.bounds.width > 1, w.url != nil, !r.isPrivate else { then?(); return }
    // One capture at a time: a page closed right after it left the screen (⌘W) waits for the
    // snapshot already being taken instead of taking a second one.
    if r.snapshotWaiters != nil {
      if let then { r.snapshotWaiters?.append(then) }
      return
    }
    r.snapshotWaiters = then.map { [$0] } ?? []
    var done = false
    let finish: @MainActor () -> Void = {
      guard !done else { return }
      done = true
      let waiters = r.snapshotWaiters ?? []
      r.snapshotWaiters = nil
      waiters.forEach { $0() }
    }
    // WebKit usually answers in tens of ms; under heavy load it can take seconds.
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { finish() } }
    let config = WKSnapshotConfiguration()
    config.afterScreenUpdates = false
    // WebKit renders it at the final size (points x backing scale), so den never holds a
    // full-size bitmap or scales one down.
    let scale = w.window?.backingScaleFactor ?? 2
    config.snapshotWidth = NSNumber(value: Double(min(w.bounds.width, snapshotMaxWidth / scale)))
    let path = snapshotDir.appendingPathComponent("\(r.id).jpg")
    let maxPx = snapshotMaxWidth, dir = snapshotDir
    w.takeSnapshot(with: config) { [weak self] img, _ in
      MainActor.assumeIsolated {
        guard let cg = img.flatMap(Self.cgImage) else { return finish() }
        finish()  // the view may go now; the encode doesn't need it
        // userInitiated: a ~10 ms encode; at utility QoS a busy Mac can starve it for seconds.
        DispatchQueue.global(qos: .userInitiated).async {
          try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
          let ok = autoreleasepool { Self.writeSnapshot(cg, maxWidth: maxPx, to: path) }
          let bg = Self.backgroundColor(of: cg)
          // Give the freed bitmap and encoder buffers back to the system now rather than under
          // memory pressure (a moment later: the image is released when this block is).
          MemoryRelief.soon()
          DispatchQueue.main.async {
            MainActor.assumeIsolated {
              if ok { r.snapshotPath = path.path }
              if let bg {
                r.backgroundColor = bg
                if let host = URL(string: r.url)?.host?.lowercased(), let self {
                  if self.hostBackgrounds.count >= 300 { self.hostBackgrounds.removeAll() }  // a small bounded cache
                  self.hostBackgrounds[host] = bg
                }
              }
            }
          }
        }
      }
    }
  }

  /// The bitmap behind a WebKit snapshot. `cgImage(forProposedRect: nil)` returns nil for the
  /// fractional sizes a `snapshotWidth` snapshot has, so ask for its integral rect.
  static func cgImage(_ img: NSImage) -> CGImage? {
    if let rep = img.representations.first(where: { $0 is NSBitmapImageRep }) as? NSBitmapImageRep, let cg = rep.cgImage { return cg }
    var rect = NSRect(origin: .zero, size: NSSize(width: img.size.width.rounded(.down), height: img.size.height.rounded(.down)))
    return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
  }

  /// Scales `image` down to `maxWidth` pixels (never up) and writes it as JPEG at quality 0.55.
  /// Not HEIC, although its files are ~40% smaller: ImageIO's HEIC encoder kept ~4 MB of den's
  /// memory per encode (12 encodes, +51 MB, docs/perf/memory.md); JPEG keeps none.
  nonisolated static func writeSnapshot(_ image: CGImage, maxWidth: CGFloat, to url: URL) -> Bool {
    // Redrawn into an opaque sRGB bitmap (WebKit's snapshot has alpha and may be IOSurface-backed).
    let scale = min(1, maxWidth / CGFloat(max(1, image.width)))
    let w = max(1, Int((CGFloat(image.width) * scale).rounded())), h = max(1, Int((CGFloat(image.height) * scale).rounded()))
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return false }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let scaled = ctx.makeImage() else { return false }
    return encode(scaled, to: url)
  }

  nonisolated static func encode(_ image: CGImage, to url: URL) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.55] as CFDictionary)
    return CGImageDestinationFinalize(dest)
  }

  /// The stored snapshot, decoded (for the restore placeholder and previews).
  public func storedSnapshot(_ id: String) -> CGImage? {
    guard let p = records[id]?.snapshotPath, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
  }

  /// Removes this process' snapshot folder (at quit).
  public func removeSnapshots() {
    try? FileManager.default.removeItem(at: snapshotDir.deletingLastPathComponent())
  }

  /// Removes snapshot folders of den processes that are gone (a crash), off the main thread.
  public func removeStaleSnapshots() {
    DispatchQueue.global(qos: .background).async {
      let tmp = FileManager.default.temporaryDirectory
      for name in (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [] where name.hasPrefix("den-") {
        guard let pid = Int32(name.dropFirst(4)), pid != getpid(), kill(pid, 0) != 0, errno == ESRCH else { continue }
        try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
      }
    }
  }

  // MARK: Mute

  /// Mutes the whole page with WebKit's page mute (`_setPageMuted:`, the mechanism behind Safari's
  /// tab mute): every frame, <audio>/<video> and WebAudio, without touching the page's own `muted`
  /// state. A WebKit without it falls back to muting the media elements of the main frame.
  func setMuted(_ r: WebRecord, _ muted: Bool) {
    guard r.muted != muted else { return }
    r.muted = muted
    if let w = r.webView { Self.applyMuted(w, muted) }
    host.emit("webviews.muted", ["id": .string(r.id), "muted": .bool(muted)])
  }

  @discardableResult
  static func applyMuted(_ w: WKWebView, _ muted: Bool) -> Bool {
    if w.responds(to: NSSelectorFromString("_setPageMuted:")) {
      w.setValue(NSNumber(value: muted ? 1 : 0), forKey: "pageMuted")  // _WKMediaAudioMuted = 1 << 0
      return true
    }
    w.callAsyncJavaScript("document.querySelectorAll('video,audio').forEach(m => m.muted = muted)", arguments: ["muted": muted], in: nil, in: PageScripts.world)
    return false
  }

  /// WebKit's page mute state (`_mediaMutedState` & audio), for tests. nil without the SPI.
  public func pageMuted(_ id: String) -> Bool? {
    guard let w = records[id]?.webView, w.responds(to: NSSelectorFromString("_mediaMutedState")) else { return nil }
    return ((w.value(forKey: "mediaMutedState") as? NSNumber)?.intValue ?? 0) & 1 == 1
  }

  /// Runs `js` (an async function body) in den's page world, in `frame` (default: main frame).
  public func runPageScript(_ id: String, _ js: String, arguments: [String: Any] = [:], frame: WKFrameInfo? = nil,
                            done: (@MainActor (Result<Any, Error>) -> Void)? = nil) {
    guard let w = records[id]?.webView else { return }
    w.callAsyncJavaScript(js, arguments: arguments, in: frame, in: PageScripts.world) { res in
      MainActor.assumeIsolated { done?(res) }
    }
  }

  func snapshot(_ r: WebRecord, path: String, width: CGFloat? = nil, jpeg: Bool = false) {
    let id = r.id
    let done: @MainActor (NSImage?) -> Void = { [weak self] taken in
      // A web view that isn't in a window can't draw: fall back to the stored snapshot on disk.
      let img = taken ?? self?.storedSnapshot(id).map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
      var ok = false
      if let img, !path.isEmpty, let data = Self.encode(img, width: width, jpeg: jpeg) {
        ok = (try? data.write(to: URL(fileURLWithPath: path))) != nil
      }
      self?.host.emit("webviews.snapshot", ["id": .string(id), "path": .string(path), "ok": .bool(ok)])
    }
    if let w = r.webView, w.window != nil {
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

  // MARK: Plugins in pages (PageScripting)

  lazy var scripting = PageScripting(web: self)
  /// Gate for `inject`: may `plugin` run scripts in a page on `host`? Wired to `pages:` (and
  /// `session:`) permissions; nil denies everything.
  public var allowPages: ((_ plugin: String, _ host: String) -> Bool)?
  /// A file in a plugin's resource folder (wired to `Permissions.resource`).
  public var resource: ((_ plugin: String, _ name: String) -> URL?)?

  /// Plugins' content rule lists, on every web view. Empty until a plugin sets rules;
  /// `setRuleLists` updates the live views too.
  public private(set) var ruleLists: [WKContentRuleList] = []
  public func setRuleLists(_ lists: [WKContentRuleList]) {
    for r in records.values {
      guard let c = r.webView?.configuration.userContentController else { continue }
      for l in ruleLists { c.remove(l) }
      for l in lists { c.add(l) }
    }
    ruleLists = lists
  }

  /// Adds items to a web page's context menu (plugins' `setMenu`).
  public var contextMenu: ((WKWebView, NSMenu) -> Void)?

  public func id(of w: WKWebView) -> String? { recordFor(w)?.id }

  // MARK: Page reads

  /// Gate for `eval`: may `plugin` read a page on `host`? The runtime wires this to the plugin's
  /// declared `session:<domain>` permissions; nil denies everything.
  public var allowScript: ((_ plugin: String, _ host: String) -> Bool)?
  public var maxScriptBytes = 4096
  private var nextEval = 1
  /// Deadline timer for `eval` (tests swap in a manual clock).
  public var evalSchedule: HostSchedule = HostTimers.main

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
    let cancelTimeout = evalSchedule(max(200, min(Int(args.num("timeoutMs", 5000)), 20_000))) { finish(["ok": false, "error": "webviews: script timed out"]) }
    w.callAsyncJavaScript(script, arguments: [:], in: nil, in: .world(name: "den-plugins")) { result in
      MainActor.assumeIsolated {
        cancelTimeout()
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
    case _ where Self.isPrivate(profile): s = .nonPersistent()  // `private:<window>`: one ephemeral store per private window
    default: s = WKWebsiteDataStore(forIdentifier: Self.profileUUID(profile))
    }
    stores[profile] = s
    return s
  }

  public nonisolated static func isPrivate(_ profile: String) -> Bool { profile == "private" || profile.hasPrefix("private:") }

  /// A private window closed: its ephemeral store is let go (WebKit drops its cookies and caches
  /// once no page uses it).
  public func releaseStore(_ profile: String) {
    guard Self.isPrivate(profile) else { return }
    stores[profile] = nil
    // Its pop-up windows go with it (they share the store).
    for r in records.values where r.profile == profile && r.popupWindow != nil { closePopupWindow?(r.id) }
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

  /// The preferences variant (WebKit calls only this one when it exists), so `sitepolicy` can set
  /// per-navigation web page preferences (HTTPS-first, autoplay, pop-ups).
  public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences,
                      decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
    decide(webView, action, preferences) { decisionHandler($0, preferences) }
  }

  func decide(_ webView: WKWebView, _ action: WKNavigationAction, _ preferences: WKWebpagePreferences, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
    guard let r = recordFor(webView), let target = action.request.url else { return decisionHandler(.allow) }
    let mainFrame = action.targetFrame?.isMainFrame ?? true
    // mailto:, tel:, zoommtg:… open in their app (ExternalLinks.swift), never as an error page.
    if ExternalLinks.isExternal(target) {
      decisionHandler(.cancel)
      openExternal(target, from: webView, userInitiated: Self.isUserInitiated(action), mainFrame: mainFrame)
      return
    }
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
    // `<a download>`: a download, not a navigation (DownloadsService).
    if action.shouldPerformDownload, downloads != nil {
      decisionHandler(.download)
      return
    }
    if mainFrame, let sp = sitePolicy, case let .cancel(then) = sp.decide(r, webView, action, preferences) {
      decisionHandler(.cancel)
      DispatchQueue.main.async { then() }
      return
    }
    decisionHandler(.allow)
  }

  /// Per-site policy (`sitepolicy`), set when that service is first used.
  weak var sitePolicy: SitePolicyService?
  /// Files pages hand over (`downloads` service, set by `DenRuntime`).
  public weak var downloads: DownloadsService?

  /// A response WebKit can't show, or a `Content-Disposition: attachment`, is downloaded into
  /// Downloads instead of failing (DownloadsService.shouldDownload).
  public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                      decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
    let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
    let download = downloads != nil && DownloadsService.shouldDownload(canShow: navigationResponse.canShowMIMEType, mainFrame: navigationResponse.isForMainFrame,
                                                                        disposition: disposition)
    decisionHandler(download ? .download : .allow)
  }

  public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
    downloads?.adopt(download, webview: recordFor(webView)?.id ?? "")
  }

  public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
    downloads?.adopt(download, webview: recordFor(webView)?.id ?? "")
  }

  /// WebKit SPI (`_WKNavigationDelegatePrivate`): a content rule list acted on a load. WebKit only
  /// calls it because this object responds to it; the count stays in `sitepolicy`.
  @objc(_webView:contentRuleListWithIdentifier:performedAction:forURL:)
  func contentRuleList(_ webView: WKWebView, identifier: NSString, performedAction action: NSObject, forURL url: NSURL) {
    guard let sp = sitePolicy, let r = recordFor(webView) else { return }
    let blocked = action.responds(to: NSSelectorFromString("blockedLoad")) && (action.value(forKey: "blockedLoad") as? Bool ?? false)
    sp.performed(r, list: identifier as String, blocked: blocked)
  }

  public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    if let sp = sitePolicy, let r = recordFor(webView) { sp.committed(r, webView) }
    // A new page may show dialogs again (loop protection counts per page load).
    prompts?.pageChanged(webView)
    // Its blocked pop-ups were the old page's.
    if let r = recordFor(webView) { clearBlockedPopups(r) }
    // A new document: its script reports afresh.
    guard let r = recordFor(webView), !r.frames.isEmpty else { return }
    r.frames = [:]
    mediaChanged(r)
  }

  public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard let r = recordFor(webView) else { return }
    markPainted(r, webView)  // without WebKit's paint events, a finished load counts
    extensionHooks?.pageChanged(webView)
    onFinish?(r.id)
    webView.evaluateJavaScript(PageScripts.favicon) { [weak self] result, _ in
      MainActor.assumeIsolated {
        guard let s = result as? String, !s.isEmpty, s != r.favicon else { return }
        r.favicon = s
        self?.host.emit("webviews.favicon", ["id": .string(r.id), "url": .string(s)])
      }
    }
  }

  public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    if let r = recordFor(webView) { markPainted(r, webView); onFinish?(r.id) }
  }

  public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    guard let r = recordFor(webView) else { return }
    r.frames = [:]
    mediaChanged(r)
    r.crashed = true
    // On screen: the crash page at once. Off screen: when it's next shown (`showCrashPageIfNeeded`),
    // so a background crash starts no new web process.
    if webView.window != nil { showCrashPageIfNeeded(r.id) }
    host.emit("webviews.crashed", ["id": .string(r.id)])
  }

  /// den's "This page crashed · Reload" page in place of a dead page (Dia 0.45). The tab keeps
  /// its URL, so Reload (the button, ⌘R) loads the real page again. Never reloads by itself.
  public func showCrashPageIfNeeded(_ id: String) {
    guard let r = records[id], r.crashed, let w = r.webView else { return }
    r.crashed = false
    let url = w.url ?? URL(string: r.url) ?? URL(string: "about:blank")!
    w.loadSimulatedRequest(URLRequest(url: url), responseHTML: WebErrorPage.html(WebErrorPage.crashed, url: url, colors: prompts?.errorPageColors))
  }

  // MARK: First paint (no white flash)

  /// _WKRenderingProgressEvents: first visually non-empty layout, first paint with significant
  /// area, first paint (WebKit SPI; any of them means the page has drawn something).
  static let paintEvents: UInt = (1 << 1) | (1 << 2) | (1 << 6)
  /// A page painted for the first time since its view was created (the content area stops
  /// holding the previous page and lets the view draw its own background).
  public var onPainted: ((String) -> Void)?

  @objc(_webView:renderingProgressDidChange:)
  public func webView(_ webView: WKWebView, renderingProgressDidChange events: UInt) {
    guard events & Self.paintEvents != 0, let r = recordFor(webView) else { return }
    markPainted(r, webView)
  }

  func markPainted(_ r: WebRecord, _ w: WKWebView) {
    guard !r.painted else { return }
    r.painted = true
    if w.responds(to: NSSelectorFromString("_setDrawsBackground:")) { w.setValue(true, forKey: "drawsBackground") }
    onPainted?(r.id)
  }

  /// The colour a page's background most likely is, from a snapshot: the median-luminance pixel
  /// of an 8x8 reduction (headers and images rarely win it). Also kept per host, for new tabs.
  nonisolated static func backgroundColor(of image: CGImage) -> CGColor? {
    let n = 8
    var px = [UInt8](repeating: 0, count: n * n * 4)
    let ok: Bool = px.withUnsafeMutableBytes { buf in
      guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
      ctx.interpolationQuality = .medium
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
      return true
    }
    guard ok else { return nil }
    var samples: [(Double, Int)] = []
    for i in 0..<(n * n) {
      let l = 0.2126 * Double(px[i * 4]) + 0.7152 * Double(px[i * 4 + 1]) + 0.0722 * Double(px[i * 4 + 2])
      samples.append((l, i))
    }
    samples.sort { $0.0 < $1.0 }
    let i = samples[samples.count / 2].1
    return CGColor(srgbRed: CGFloat(px[i * 4]) / 255, green: CGFloat(px[i * 4 + 1]) / 255, blue: CGFloat(px[i * 4 + 2]) / 255, alpha: 1)
  }

  /// Last known background colour per host (from snapshots), for pages that have no snapshot yet.
  public private(set) var hostBackgrounds: [String: CGColor] = [:]

  /// The colour to show behind a page that hasn't painted: its own, else its host's.
  public func expectedBackground(_ id: String) -> CGColor? {
    guard let r = records[id] else { return nil }
    if let c = r.backgroundColor { return c }
    guard let host = URL(string: r.url)?.host?.lowercased() else { return nil }
    return hostBackgrounds[host]
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

  /// `<input type=file>`: den's upload picker first (recent downloads, screenshots, the clipboard;
  /// UploadPicker.swift), else straight to an open panel as a sheet on the page's window.
  public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
    let request = UploadPicker.Request(parameters)
    if let picker = uploadPicker, let prompts, picker.offer(request, webView: webView, prompts: prompts, done: completionHandler) { return }
    Self.runOpenPanel(request, webView: webView, done: completionHandler)
  }

  /// den's upload picker (set by `DenRuntime`; nil = always the system panel).
  public var uploadPicker: UploadPicker?

  static func runOpenPanel(_ request: UploadPicker.Request, webView: WKWebView, done completionHandler: @escaping @MainActor ([URL]?) -> Void) {
    let panel = Self.openPanel(multiple: request.multiple, directories: request.directories)
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
    if let r = recordFor(webView) { onFinish?(r.id) }
    if let sp = sitePolicy, let r = recordFor(webView), sp.failed(r, webView, error) { return }
    let url = ((error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url
    guard let url, let page = WebErrorPage.page(for: error, url: url) else { return }
    if let r = recordFor(webView) { sitePolicy?.passThrough(r, url) }
    webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: WebErrorPage.html(page, url: url, colors: prompts?.errorPageColors))
  }

  func didReceive(_ msg: WKScriptMessage) {
    if msg.name == LinkHover.handlerName {
      // The id is the host's own record for the sending view; the page only supplies the link.
      guard msg.frameInfo.isMainFrame, let w = msg.webView, let r = recordFor(w),
            let (name, payload) = LinkHover.event(id: r.id, body: msg.body, toWindow: { LinkHover.toWindow($0, in: w) }) else { return }
      host.emit(name, payload)
      return
    }
    if msg.name == "denContext" {
      guard let w = msg.webView as? DenWebView, let b = msg.body as? [String: Any] else { return }
      w.context = .init(link: b["link"] as? String ?? "", image: b["image"] as? String ?? "", selection: b["selection"] as? String ?? "")
      return
    }
    guard let w = msg.webView, let r = recordFor(w), r.webView === w else { return }
    let body = Self.jsValue(msg.body)
    if body.str("k") == "t" {
      onPlayback?(r.id, body)
      return
    }
    guard body.str("k") == "s" else { return }
    let key = msg.frameInfo.isMainFrame ? "main" : (msg.frameInfo.request.url?.absoluteString ?? "frame")
    let media = PageMedia(body)
    if !msg.frameInfo.isMainFrame && !media.playing && !media.dirty && !media.pip && media.video == nil && media.now.map({ _ in true }) != true {
      r.frames[key] = nil
    } else {
      r.frames[key] = (msg.frameInfo, media)
    }
    mediaChanged(r)
  }

  // MARK: Links

  func watchLinks(_ args: Value) -> Value {
    guard links.configure(modifier: args.str("modifier", "shift"), yieldTo: args.list("yieldTo").compactMap(\.string)) else {
      return .error("webviews: modifier must be shift, none or off")
    }
    applyLinks()
    return .ok
  }

  func watchStatus(_ args: Value) -> Value {
    links.configureStatus(args.flag("enabled", true))
    applyLinks()
    return .ok
  }

  /// Installs (or updates, or removes) the link script in every live web view.
  func applyLinks() {
    for r in records.values {
      guard let w = r.webView else { continue }
      if links.enabled { links.install(w, handler: scriptHandler) } else { links.uninstall(w) }
    }
  }

  func mediaChanged(_ r: WebRecord) {
    let m = r.media
    if m.audible != r.audio {
      r.audio = m.audible
      host.emit("webviews.audio", ["id": .string(r.id), "playing": .bool(m.audible)])
    }
    onMedia?(r)
    host.emit("webviews.media", ["id": .string(r.id), "playing": .bool(m.playing), "pip": .bool(m.pip), "dirty": .bool(m.dirty)])
    if m.now != r.nowPlaying {
      r.nowPlaying = m.now
      host.emit("webviews.nowPlaying", ["id": .string(r.id), "now": m.now ?? .null, "muted": .bool(r.muted)])
    }
  }
}

/// Breaks the WKUserContentController -> handler retain cycle.
final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
  let fn: @MainActor (WKScriptMessage) -> Void
  init(_ fn: @escaping @MainActor (WKScriptMessage) -> Void) { self.fn = fn }
  func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
    MainActor.assumeIsolated { fn(message) }
  }
}
