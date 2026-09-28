import AppKit
import CordisValue
import WebKit

/// `sitepolicy`: per-site web policy for every web view. The host half of the `shields` plugin;
/// generic like `pagestyle`: the host applies, the plugin owns the lists, strings and choices.
///
/// - Content rule lists: compiled once into den's own `WKContentRuleListStore` (identifier
///   `name@version`), looked up (milliseconds) on later launches, and attached per site.
/// - Web page preferences per site: autoplay and pop-ups (WebKit SPI on `WKWebpagePreferences`,
///   checked with `responds(to:)`), HTTPS-first (public `preferredHTTPSNavigationPolicy`).
/// - A navigation guard: a plugin service asked synchronously about main-frame navigations
///   (declarative rules can't express "is this a lookalike domain"); it may rewrite or stop one.
/// - Interstitial pages, per-page blocked counts, forgetting a site's data, an unsaved-input check.
///
/// Nothing is created until the first call: no store, no hooks, no per-page state.
@MainActor
public final class SitePolicyService: HostService {
  public let name = "sitepolicy"
  let host: ServiceHost
  let webviews: WebViewsService
  let storeRoot: URL
  /// Where `load {plugin, file}` looks first: `<root>/<plugin>/<file>` (`~/.den/updates/lists`:
  /// newer lists an updater could deliver), then the plugin's resource folder (`resource`).
  public var resourceRoots: [URL] = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".den/updates/lists", isDirectory: true)]
  /// The plugin's resource folder (`Permissions.resource`: the bundle's
  /// `Contents/Resources/plugin-resources/<id>/`, or the checkout's `Plugins/<id>/resources/`).
  var resource: (@MainActor (String, String) -> URL?)?
  /// Calls a plugin service (the navigation guard). Set by `DenRuntime`.
  var call: ((String, String, Value) -> Value)?
  /// Colors for interstitial pages (the space's palette), like error pages.
  var colors: () -> WebErrorPage.Colors? = { nil }
  /// Media-capture answers (camera, microphone) the host keeps for a site.
  weak var prompts: WebPrompts?

  public struct Rule: Equatable {
    public var lists: [String] = []
    /// `allow`, `sound` (autoplay only without sound) or `none`; nil leaves WebKit's default.
    public var autoplay: String?
    /// `allow` or `block`; nil leaves WebKit's default (pop-ups only from a click).
    public var popups: String?
  }

  public private(set) var defaultRule = Rule()
  public private(set) var hostRules: [String: Rule] = [:]
  public private(set) var httpsFirst = false
  private var httpAllowed: Set<String> = []
  private var guardTarget: (service: String, method: String)?

  private lazy var store: WKContentRuleListStore? = {
    try? FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
    return WKContentRuleListStore(url: storeRoot)
  }()
  /// Compiled lists by name, and the identifier each one was loaded as.
  public private(set) var lists: [String: WKContentRuleList] = [:]
  private var identifiers: [String: String] = [:]
  private var listInfo: [String: Value] = [:]

  final class Page {
    var lists: [String: WKContentRuleList] = [:]
    var blocked: [String: Int] = [:]
    var rewrites: [Value] = []
    var pendingRewrites: [Value] = []
    var rewriteTimes: [Date] = []
    /// The http URL being tried over https (HTTPS-first), until it commits or fails.
    var upgrading: URL?
    var upgraded = false
    var interstitial: (url: URL, actions: Set<String>)?
    /// The interstitial's own (simulated) load, which passes the policy check untouched.
    var loadingInterstitial: URL?
    var statsScheduled = false
  }
  private var pages: [String: Page] = [:]
  private var active = false

  public init(host: ServiceHost, webviews: WebViewsService, storeRoot: URL) {
    self.host = host
    self.webviews = webviews
    self.storeRoot = storeRoot
  }

  // MARK: Service

  public func handle(method: String, args: Value) -> Value {
    switch method {
    case "load": return load(args)
    case "define": return define(args)
    case "list":
      return .array(identifiers.keys.sorted().map { n in
        (listInfo[n] ?? ["name": .string(n)]).with("ready", .bool(lists[n] != nil))
      })
    case "rules":
      defaultRule = Self.rule(args["default"])
      var hosts: [String: Rule] = [:]
      for (h, v) in args["hosts"].object ?? [] { hosts[PageStyleService.key(h)] = Self.rule(v) }
      hostRules = hosts
      activate()
      applyAll()
      return .ok
    case "https":
      httpsFirst = args.flag("enabled")
      httpAllowed = Set(args.list("allow").compactMap { $0.string.map(PageStyleService.key) })
      activate()
      return .ok
    case "guard":
      let s = args.str("service")
      guardTarget = s.isEmpty ? nil : (s, args.str("method", "navigate"))
      activate()
      return .ok
    case "get":
      guard let r = webviews.record(args.str("id")) else { return .error("sitepolicy: no webview '\(args.str("id"))'") }
      return state(r)
    case "interstitial":
      guard let r = webviews.record(args.str("id")), let w = r.webView else { return .error("sitepolicy: '\(args.str("id"))' is not loaded") }
      guard let u = URL(string: args.str("url")) ?? w.url else { return .error("sitepolicy: interstitial needs a url") }
      showInterstitial(r, w, url: u, page: args["page"])
      return .ok
    case "forget": return forget(args)
    case "permissions":
      let h = PageStyleService.key(args.str("host"))
      return .array(mediaKeys(h).map { k, allowed in
        let parts = k.split(separator: " ")
        return ["origin": .string(String(parts.first ?? "")), "kind": .string(String(parts.last ?? "")), "allowed": .bool(allowed)]
      })
    case "resetPermissions":
      let h = PageStyleService.key(args.str("host"))
      for (k, _) in mediaKeys(h) { prompts?.forgetMedia(k) }
      return .ok
    case "unsaved": return unsaved(args)
    case "support":
      return ["autoplay": .bool(Self.canSetPolicy("_setAutoplayPolicy:")), "popups": .bool(Self.canSetPolicy("_setPopUpPolicy:")),
              "blockedCounts": .bool(NSClassFromString("_WKContentRuleListAction") != nil)]
    default:
      return .error("sitepolicy: unknown method '\(method)'")
    }
  }

  static func rule(_ v: Value) -> Rule {
    Rule(lists: v.list("lists").compactMap(\.string),
         autoplay: v["autoplay"].string.flatMap { ["allow", "sound", "none"].contains($0) ? $0 : nil },
         popups: v["popups"].string.flatMap { ["allow", "block"].contains($0) ? $0 : nil })
  }

  /// The rule for a host: the host, then each parent domain, then `default` (no `www.`).
  public func rule(for host: String) -> Rule {
    var h = PageStyleService.key(host)
    while !h.isEmpty {
      if let r = hostRules[h] { return r }
      guard let dot = h.firstIndex(of: ".") else { break }
      h = String(h[h.index(after: dot)...])
    }
    return defaultRule
  }

  // MARK: Content rule lists

  func resolve(_ args: Value) -> URL? {
    let file = args.str("file")
    guard !file.isEmpty, !file.contains("..") else { return nil }
    if file.hasPrefix("/") { return FileManager.default.fileExists(atPath: file) ? URL(fileURLWithPath: file) : nil }
    let plugin = args.str("plugin")
    guard !plugin.isEmpty, !plugin.contains("/") else { return nil }
    for root in resourceRoots {
      let u = root.appendingPathComponent(plugin, isDirectory: true).appendingPathComponent(file)
      if FileManager.default.fileExists(atPath: u.path) { return u }
    }
    return resource?(plugin, file)
  }

  static func validName(_ n: String) -> Bool {
    !n.isEmpty && n.count <= 64 && n.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
  }

  func load(_ args: Value) -> Value {
    let n = args.str("name")
    guard Self.validName(n) else { return .error("sitepolicy: load needs a name of letters, digits, . - _") }
    guard let url = resolve(args) else { return .error("sitepolicy: no rules file '\(args.str("file"))'") }
    let version = args.str("version", "1")
    return prepare(n, id: n + "@" + version) { url.pathExtension == "lzfse" ? Self.inflate(url) : try? String(contentsOf: url, encoding: .utf8) }
  }

  func define(_ args: Value) -> Value {
    let n = args.str("name")
    guard Self.validName(n) else { return .error("sitepolicy: define needs a name of letters, digits, . - _") }
    let json = args.str("json")
    guard !json.isEmpty, json.utf8.count <= 256 * 1024 else { return .error("sitepolicy: json must be 1 byte … 256 KB") }
    return prepare(n, id: n + "@" + Self.fnv(json)) { json }
  }

  nonisolated static func fnv(_ s: String) -> String {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
    return String(h, radix: 16)
  }

  nonisolated static func inflate(_ url: URL) -> String? {
    guard let data = try? Data(contentsOf: url), let out = try? (data as NSData).decompressed(using: .lzfse) else { return nil }
    return String(data: out as Data, encoding: .utf8)
  }

  /// Looks the list up in the store; compiles it from `source` (read off the main thread) only
  /// when this identifier was never compiled. Emits `sitepolicy.loaded`.
  func prepare(_ n: String, id: String, source: @escaping @Sendable () -> String?) -> Value {
    if identifiers[n] == id { return ["pending": .bool(lists[n] == nil), "ready": .bool(lists[n] != nil)] }
    identifiers[n] = id
    lists[n] = nil
    guard let store else { return .error("sitepolicy: no rule list store") }
    let t0 = Date()
    store.lookUpContentRuleList(forIdentifier: id) { [weak self] found, _ in
      MainActor.assumeIsolated {
        guard let self, self.identifiers[n] == id else { return }
        if let found { return self.ready(n, id, found, t0, cached: true) }
        DispatchQueue.global(qos: .utility).async {
          let json = source()
          DispatchQueue.main.async {
            MainActor.assumeIsolated {
              guard self.identifiers[n] == id else { return }
              guard let json else { return self.failed(n, "can't read the rules file") }
              store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) { list, error in
                MainActor.assumeIsolated {
                  guard self.identifiers[n] == id else { return }
                  if let list { self.ready(n, id, list, t0, cached: false) } else { self.failed(n, Self.describe(error)) }
                }
              }
            }
          }
        }
      }
    }
    return ["pending": true]
  }

  static func describe(_ e: Error?) -> String {
    guard let e = e as NSError? else { return "unknown error" }
    return (e.userInfo[NSHelpAnchorErrorKey] as? String) ?? e.localizedDescription
  }

  func ready(_ n: String, _ id: String, _ list: WKContentRuleList, _ t0: Date, cached: Bool) {
    lists[n] = list
    let ms = (Date().timeIntervalSince(t0) * 1000).rounded()
    listInfo[n] = ["name": .string(n), "id": .string(id), "cached": .bool(cached), "ms": .double(ms)]
    host.emit("sitepolicy.loaded", ["name": .string(n), "ok": true, "cached": .bool(cached), "ms": .double(ms)])
    applyAll()
    // Older compiled versions of this list only take disk space.
    store?.getAvailableContentRuleListIdentifiers { ids in
      MainActor.assumeIsolated {
        for old in ids ?? [] where old.hasPrefix(n + "@") && old != id { self.store?.removeContentRuleList(forIdentifier: old) { _ in } }
      }
    }
  }

  func failed(_ n: String, _ error: String) {
    listInfo[n] = ["name": .string(n), "error": .string(error)]
    identifiers[n] = nil
    host.emit("sitepolicy.loaded", ["name": .string(n), "ok": false, "error": .string(error)])
  }

  // MARK: Web view hooks

  func activate() {
    guard !active else { return }
    active = true
    webviews.sitePolicy = self
    webviews.configureHooks.append { [weak self] r, config in self?.configure(r, config) }
    host.on("webviews.closed") { [weak self] v in self?.pages[v.str("id")] = nil }
    host.on("webviews.detached") { [weak self] v in self?.pages[v.str("id")] = nil }
  }

  func page(_ id: String) -> Page {
    if let p = pages[id] { return p }
    let p = Page()
    pages[id] = p
    return p
  }

  func configure(_ r: WebRecord, _ config: WKWebViewConfiguration) {
    let p = Page()
    pages[r.id] = p
    apply(p, config.userContentController, rule(for: PageStyleService.host(of: URL(string: r.url))))
  }

  /// Makes the page's attached lists exactly the rule's (the ones compiled so far).
  func apply(_ p: Page, _ c: WKUserContentController, _ rule: Rule) {
    let want = Set(rule.lists)
    for (n, l) in p.lists where !want.contains(n) || lists[n] !== l {
      c.remove(l)
      p.lists[n] = nil
    }
    for n in rule.lists where p.lists[n] == nil {
      guard let l = lists[n] else { continue }
      c.add(l)
      p.lists[n] = l
    }
  }

  func applyAll() {
    for r in webviews.records.values {
      guard let w = r.webView else { continue }
      apply(page(r.id), w.configuration.userContentController, rule(for: PageStyleService.host(of: w.url ?? URL(string: r.url))))
    }
  }

  public enum Decision { case allow, cancel(then: () -> Void) }

  /// A main-frame navigation is about to start (called from `decidePolicyFor … preferences`).
  func decide(_ r: WebRecord, _ w: WKWebView, _ action: WKNavigationAction, _ prefs: WKWebpagePreferences) -> Decision {
    guard let url = action.request.url else { return .allow }
    let p = page(r.id)
    let scheme = url.scheme?.lowercased() ?? ""
    if scheme == "den-action" {
      // A button on an interstitial page. Only counts while that page is the one showing.
      let a = String(url.absoluteString.dropFirst("den-action:".count))
      if let i = p.interstitial, w.url == i.url, i.actions.contains(a) {
        return .cancel { [weak self] in self?.host.emit("sitepolicy.interstitialAction", ["id": .string(r.id), "action": .string(a), "url": .string(i.url.absoluteString)]) }
      }
      return .cancel {}
    }
    guard scheme == "http" || scheme == "https" else { return .allow }
    if let u = p.loadingInterstitial, u == url {
      p.loadingInterstitial = nil
      prefs.preferredHTTPSNavigationPolicy = .keepAsRequested
      return .allow
    }
    if p.interstitial != nil { p.interstitial = nil }
    let isGet = (action.request.httpMethod ?? "GET").uppercased() == "GET"
    if let g = guardTarget, isGet, action.navigationType != .backForward, action.navigationType != .reload, let call {
      let v = call(g.service, g.method, ["id": .string(r.id), "url": .string(url.absoluteString), "source": .string(w.url?.absoluteString ?? ""),
                                          "link": .bool(action.navigationType == .linkActivated)])
      switch v.str("action") {
      case "rewrite":
        if let to = URL(string: v.str("url")), to != url, ["http", "https"].contains(to.scheme?.lowercased() ?? ""), allowRewrite(p) {
          let record: Value = ["kind": .string(v.str("kind", "rewrite")), "from": .string(url.absoluteString), "to": .string(to.absoluteString)]
          p.pendingRewrites.append(record)
          return .cancel { [weak self, weak w] in
            self?.host.emit("sitepolicy.rewritten", record.with("id", .string(r.id)))
            w?.load(URLRequest(url: to))
          }
        }
      case "interstitial":
        let page = v["page"]
        return .cancel { [weak self, weak w] in
          guard let self, let w else { return }
          self.showInterstitial(r, w, url: url, page: page)
        }
      case "block":
        return .cancel {}
      default: break
      }
    }
    let rule = rule(for: PageStyleService.host(of: url))
    apply(p, w.configuration.userContentController, rule)
    Self.setPolicy(prefs, "_setAutoplayPolicy:", ["allow": 1, "sound": 2, "none": 3][rule.autoplay ?? ""] ?? 0)
    Self.setPolicy(prefs, "_setPopUpPolicy:", ["allow": 1, "block": 2][rule.popups ?? ""] ?? 0)
    if scheme == "http", httpsFirst, !Self.isLocal(url.host ?? ""), !httpAllowed.contains(PageStyleService.host(of: url)) {
      prefs.preferredHTTPSNavigationPolicy = .errorOnFailure
      p.upgrading = url
    } else {
      prefs.preferredHTTPSNavigationPolicy = .keepAsRequested
      p.upgrading = nil
    }
    return .allow
  }

  /// At most 4 rewrites in 2 s per page: a guard that keeps rewriting can't loop.
  func allowRewrite(_ p: Page) -> Bool {
    let now = Date()
    p.rewriteTimes = p.rewriteTimes.filter { now.timeIntervalSince($0) < 2 }
    guard p.rewriteTimes.count < 4 else { return false }
    p.rewriteTimes.append(now)
    return true
  }

  /// Hosts HTTPS-first leaves alone: loopback, `.local`, single-label names, private addresses.
  nonisolated static func isLocal(_ h: String) -> Bool {
    let h = h.lowercased()
    if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") || h.hasSuffix(".internal") || h.hasSuffix(".test") || !h.contains(".") { return true }
    let o = h.split(separator: ".").compactMap { Int($0) }
    guard o.count == 4 else { return h.hasPrefix("[") || h.contains(":") }
    return o[0] == 127 || o[0] == 10 || (o[0] == 192 && o[1] == 168) || (o[0] == 172 && (16...31).contains(o[1])) || (o[0] == 169 && o[1] == 254)
  }

  static func canSetPolicy(_ sel: String) -> Bool { WKWebpagePreferences.instancesRespond(to: NSSelectorFromString(sel)) }

  /// `-[WKWebpagePreferences _setAutoplayPolicy:]` / `_setPopUpPolicy:` (WebKit SPI, NSInteger enums).
  static func setPolicy(_ prefs: WKWebpagePreferences, _ sel: String, _ value: Int) {
    let s = NSSelectorFromString(sel)
    guard prefs.responds(to: s), let imp = prefs.method(for: s) else { return }
    typealias Setter = @convention(c) (AnyObject, Selector, Int) -> Void
    unsafeBitCast(imp, to: Setter.self)(prefs, s, value)
  }

  /// The next navigation to `url` is den's own simulated page (an error page): no guard, no upgrade.
  func passThrough(_ r: WebRecord, _ url: URL) {
    page(r.id).loadingInterstitial = url
  }

  func committed(_ r: WebRecord, _ w: WKWebView) {
    let p = page(r.id)
    p.blocked = [:]
    p.rewrites = p.pendingRewrites
    p.pendingRewrites = []
    p.upgraded = p.upgrading != nil && w.url?.scheme == "https"
    p.upgrading = nil
    changed(r.id)
  }

  /// WebKit's rule-list action callback (SPI): one blocked or upgraded load.
  func performed(_ r: WebRecord, list identifier: String, blocked: Bool) {
    guard blocked, let n = identifiers.first(where: { $0.value == identifier })?.key else { return }
    let p = page(r.id)
    p.blocked[n, default: 0] += 1
    changed(r.id)
  }

  /// `sitepolicy.changed {id}`, at most every 250 ms per page, and only while someone listens.
  func changed(_ id: String) {
    guard host.hasListeners("sitepolicy.changed"), let p = pages[id], !p.statsScheduled else { return }
    p.statsScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self, weak p] in
      MainActor.assumeIsolated {
        p?.statsScheduled = false
        self?.host.emit("sitepolicy.changed", ["id": .string(id)])
      }
    }
  }

  /// A provisional navigation failed. Returns true when the host showed something for it (the
  /// HTTPS-first page), so the generic error page isn't loaded over it.
  func failed(_ r: WebRecord, _ w: WKWebView, _ error: Error) -> Bool {
    let p = page(r.id)
    guard let http = p.upgrading else { return false }
    p.upgrading = nil
    let e = error as NSError
    if e.domain == NSURLErrorDomain, [NSURLErrorCancelled, NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed].contains(e.code) { return false }
    if e.domain == "WebKitErrorDomain" { return false }
    let failing = (e.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
    guard failing == nil || failing?.host?.lowercased() == http.host?.lowercased() else { return false }
    host.emit("sitepolicy.httpsUnavailable", ["id": .string(r.id), "url": .string(http.absoluteString), "error": .string(e.localizedDescription), "code": .int(Int64(e.code))])
    return p.interstitial != nil
  }

  // MARK: Interstitial pages

  func showInterstitial(_ r: WebRecord, _ w: WKWebView, url: URL, page v: Value) {
    let buttons = v.list("buttons").prefix(3)
    let p = page(r.id)
    p.interstitial = (url, Set(buttons.map { $0.str("id") }))
    p.loadingInterstitial = url
    p.upgrading = nil
    w.loadSimulatedRequest(URLRequest(url: url), responseHTML: WebErrorPage.interstitial(v, colors: colors()))
  }

  // MARK: State

  func state(_ r: WebRecord) -> Value {
    let p = page(r.id)
    let u = r.webView?.url ?? URL(string: r.url)
    let h = PageStyleService.host(of: u)
    let rule = rule(for: h)
    var byList: Value = .object([])
    var total = 0
    for n in rule.lists {
      byList = byList.with(n, .int(Int64(p.blocked[n] ?? 0)))
      total += p.blocked[n] ?? 0
    }
    let scheme = u?.scheme?.lowercased() ?? ""
    let secure = scheme == "https" && (r.webView?.hasOnlySecureContent ?? true)
    return [
      "host": .string(h), "url": .string(u?.absoluteString ?? ""), "lists": .array(rule.lists.map { .string($0) }),
      "active": .array(p.lists.keys.sorted().map { .string($0) }),
      "blocked": .int(Int64(total)), "blockedByList": byList,
      "blockedCounts": .bool(NSClassFromString("_WKContentRuleListAction") != nil),
      "rewrites": .array(p.rewrites), "upgraded": .bool(p.upgraded),
      "connection": .string(scheme == "https" ? (secure ? "secure" : "mixed") : (scheme == "http" ? "insecure" : "local")),
      "httpAllowed": .bool(httpAllowed.contains(h)),
      "autoplay": rule.autoplay.map { .string($0) } ?? .null, "popups": rule.popups.map { .string($0) } ?? .null,
      "interstitial": .bool(p.interstitial != nil),
    ]
  }

  func mediaKeys(_ h: String) -> [(String, Bool)] {
    guard !h.isEmpty, let prompts else { return [] }
    return prompts.mediaDecisions.filter { k, _ in
      let origin = k.split(separator: " ").first.map(String.init) ?? ""
      let oh = PageStyleService.host(of: URL(string: origin))
      return oh == h || oh.hasSuffix("." + h)
    }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
  }

  // MARK: Forget a site

  /// Removes every website data record (cookies, storage, caches, service workers…) of the site's
  /// registrable domain in a profile's data store. Emits `sitepolicy.forgotten {host, removed}`.
  func forget(_ args: Value) -> Value {
    let h = PageStyleService.key(args.str("host"))
    guard h.contains(".") || h == "localhost" else { return .error("sitepolicy: forget needs a host") }
    let store = webviews.store(for: args.str("profile", "default"))
    let types = WKWebsiteDataStore.allWebsiteDataTypes()
    for (k, _) in mediaKeys(h) { prompts?.forgetMedia(k) }
    store.fetchDataRecords(ofTypes: types) { [weak self] records in
      MainActor.assumeIsolated {
        let match = records.filter { Self.sameSite(h, $0.displayName) }
        store.removeData(ofTypes: types, for: match) {
          MainActor.assumeIsolated {
            self?.host.emit("sitepolicy.forgotten", ["host": .string(h), "removed": .array(match.map { .string($0.displayName) })])
          }
        }
      }
    }
    return ["pending": true]
  }

  /// A data record (named by its registrable domain, e.g. "example.co.uk") belongs to `host`
  /// when host is that domain or under it.
  nonisolated static func sameSite(_ host: String, _ displayName: String) -> Bool {
    let d = displayName.lowercased()
    return !d.isEmpty && (host == d || host.hasSuffix("." + d))
  }

  // MARK: Unsaved input

  private var nextRequest = 1
  static let unsavedScript = """
    const ok=e=>{if(e.disabled||e.readOnly)return false;const t=(e.type||'').toLowerCase();
    if(['hidden','submit','button','reset','image','file','range','color'].includes(t))return false;
    if(t==='checkbox'||t==='radio')return e.checked!==e.defaultChecked;
    if(e.tagName==='SELECT')return[...e.options].some(o=>o.selected!==o.defaultSelected);
    return(e.value||'')!==(e.defaultValue||'')};
    const f=[...document.querySelectorAll('input,textarea,select')].some(ok);
    const a=document.activeElement;const c=!!(a&&a.isContentEditable&&(a.textContent||'').trim().length>0);
    return f||c;
    """

  /// Whether the page has form input that a reload would lose: edited fields, or text in a focused
  /// editor. Main frame only. `{request}`, then `sitepolicy.unsaved {request, id, unsaved}`.
  func unsaved(_ args: Value) -> Value {
    var request = args.str("request")
    if request.isEmpty { request = "unsaved-\(nextRequest)"; nextRequest += 1 }
    let id = args.str("id")
    guard let w = webviews.record(id)?.webView else {
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated { self?.host.emit("sitepolicy.unsaved", ["request": .string(request), "id": .string(id), "unsaved": false]) }
      }
      return ["request": .string(request)]
    }
    w.callAsyncJavaScript(Self.unsavedScript, arguments: [:], in: nil, in: .world(name: "den-policy")) { [weak self] result in
      MainActor.assumeIsolated {
        let dirty = (try? result.get()) as? Bool ?? false
        self?.host.emit("sitepolicy.unsaved", ["request": .string(request), "id": .string(id), "unsaved": .bool(dirty)])
      }
    }
    return ["request": .string(request)]
  }
}
