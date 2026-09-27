#if !hasFeature(Embedded)
  import CordisValue
#endif

/// Dia-style hover previews for sidebar tabs (docs/plugin-services.md, `previews`).
///
/// - The host decides *when* (hover intent, HoverCard.swift) and emits `ui.action {id, action: hover}`
///   for the row; `tabs` turns that into `previews.show {anchor, url, title, icon, webview}`.
/// - This plugin decides *what*: the best-matching provider for the URL answers asynchronously,
///   and the card goes into the host's `hoverCard` slot. The card appears at once with the tab's
///   header (and cached data when there is any), and fills in when the provider answers.
/// - Providers register by URL pattern (`register {pattern, provider}`). The built-in ones
///   (Providers.swift) cover GitHub pull requests and issues, Google Calendar, Gmail and Slack; any
///   other page gets a small cached snapshot of the tab (`webviews.snapshot {width}`).
/// - Nothing runs until a hover: no polling, no timers, no requests. Results are cached per URL
///   with a TTL, a stale card shows at once while it refreshes, and requests for the same URL are
///   shared.
final class PreviewsCore {
  static let slot = "hoverCard"
  static let cardId = "hoverCard"
  static let snapshotTTL: Int64 = 30_000
  static let snapshotWidth: Int64 = 320

  struct Provider {
    var id: String
    var pattern: String
    var owner: String?
    var ttlMs: Int64
    /// Built-in providers fetch here; external ones get `previews.request` and call `answer`.
    var fetch: ((Request, @escaping (Value) -> Void) -> Void)?
  }

  struct Request {
    var anchor: String
    var url: String
    var title: String
    var icon: String
    var webview: String
    var profile: String
    var selected: Bool
    var kind: String
    var items: [Value]
  }

  struct Entry {
    var data: Value
    var at: Int64
  }

  struct Snapshot {
    var url: String
    var path: String
    var at: Int64
    var version: Int64
    var ok: Bool
  }

  let env: PluginEnv
  let requests: PreviewRequests
  var providers: [Provider] = []
  var cache: [String: Entry] = [:]
  var inflight: [String: [(Value) -> Void]] = [:]
  var external: [String: (Value) -> Void] = [:]
  var current: Request?
  var snapshots: [String: Snapshot] = [:]
  var snapshotPending: [String: Bool] = [:]
  var nextExternal = 1
  var snapshotDir = "/tmp"
  /// Slack workspaces (with their web-client tokens) read on the first Slack hover; memory only.
  var slackTeams: [Value]?
  /// Fetch count, for tests and `get`.
  var fetches = 0

  init(env: PluginEnv) {
    self.env = env
    requests = PreviewRequests(env: env)
  }

  func start() {
    Builtins.register(self)
    env.on("ui.action") { [self] v in
      guard v.s("id") == Self.cardId else { return }
      action(v.s("action"), v["value"])
    }
    env.on("webviews.snapshot") { [self] v in
      let id = v.s("id")
      if v.s("path") == snapshotPath(id), snapshotPending.removeValue(forKey: id) != nil { snapshotDone(id, ok: v.b("ok")) }
    }
    env.on("tabs.closed") { [self] v in snapshots[v.s("id")] = nil }
  }

  // MARK: Service

  func handle(_ method: String, _ args: Value) -> Value {
    switch method {
    case "register":
      let pattern = args.s("pattern"), id = args.s("provider")
      guard !pattern.isEmpty, !id.isEmpty else { return .err("previews: register needs pattern and provider") }
      providers.removeAll { $0.id == id && $0.pattern == pattern }
      providers.append(Provider(id: id, pattern: pattern, owner: args.sOpt("owner"), ttlMs: args.i("ttlMs", 60_000), fetch: nil))
    case "unregister":
      let id = args.s("provider")
      providers.removeAll { $0.id == id && $0.fetch == nil }
    case "providers":
      return .array(providers.map { ["provider": .string($0.id), "pattern": .string($0.pattern), "builtin": .bool($0.fetch != nil)] })
    case "match":
      return ["provider": .str(match(args.s("url"))?.id)]
    case "show":
      show(args)
    case "hide":
      hide()
    case "answer":
      guard let done = external.removeValue(forKey: args.s("request")) else { return .err("previews: no request '" + args.s("request") + "'") }
      done(args["card"])
    case "get":
      let url = args.s("url")
      guard let p = match(url), let e = cache[key(p, url)] else { return .null }
      return ["provider": .string(p.id), "data": e.data, "at": .int(e.at)]
    case "clear":
      cache = [:]
      snapshots = [:]
    case "stats":
      return ["fetches": .int(Int64(fetches)), "cached": .int(Int64(cache.count)), "inflight": .int(Int64(inflight.count))]
    default:
      return .err("previews: unknown method '" + method + "'")
    }
    return .okay
  }

  // MARK: Matching

  /// Best provider for `url`: the matching pattern with the most literal characters (so
  /// `github.com/*/*/pull/*` beats `github.com/*`); the generic page preview otherwise.
  func match(_ url: String) -> Provider? {
    let target = Pattern.target(url)
    var best: Provider?
    var bestScore = -1
    for p in providers where Pattern.matches(p.pattern, target) {
      let s = Pattern.specificity(p.pattern)
      if s > bestScore {
        best = p
        bestScore = s
      }
    }
    return best
  }

  func key(_ p: Provider, _ url: String) -> String { p.id + "|" + Pattern.target(url) }

  // MARK: Show

  func show(_ args: Value) {
    var req = Request(anchor: args.s("anchor"), url: args.s("url"), title: args.s("title"), icon: args.s("icon"),
                      webview: args.s("webview"), profile: args.s("profile"), selected: args.b("selected"),
                      kind: args.s("kind"), items: args.a("items"))
    guard !req.anchor.isEmpty else { return }
    if req.profile.isEmpty, !req.webview.isEmpty {
      req.profile = env.call("webviews", "get", ["id": .string(req.webview)]).sOpt("profile") ?? "default"
    }
    if req.profile.isEmpty { req.profile = "default" }
    current = req
    if req.kind == "folder" {
      render(req, Cards.folder(req, cached: { [self] url in cachedData(url) }), loading: false)
      return
    }
    guard let p = match(req.url), p.id != "page" else {
      // The selected tab's page is already on screen: a snapshot of it adds nothing.
      if req.selected { return }
      showPage(req)
      return
    }
    let k = key(p, req.url)
    let entry = cache[k]
    render(req, entry?.data ?? .null, loading: entry == nil)
    if let e = entry, env.now() - e.at < p.ttlMs { return }
    load(p, req, key: k)
  }

  func hide() {
    current = nil
    env.call("ui", "set", ["slot": .string(Self.slot), "tree": nil])
  }

  func cachedData(_ url: String) -> Value? {
    guard let p = match(url), p.id != "page" else { return nil }
    return cache[key(p, url)]?.data
  }

  /// Fetches once per key; every caller waiting on the same key gets the answer.
  func load(_ p: Provider, _ req: Request, key k: String) {
    let redraw: (Value) -> Void = { [self] data in
      if let c = current, c.anchor == req.anchor, c.url == req.url { render(c, data, loading: false) }
    }
    if inflight[k] != nil {
      inflight[k]!.append(redraw)
      return
    }
    inflight[k] = [redraw]
    fetches += 1
    let finish: (Value) -> Void = { [self] data in
      // Keep the old data when a refresh fails; answers marked `noCache` (sign-in hints, a page
      // that isn't loaded) are shown but refetched on the next hover.
      if data.isErr, let old = cache[k] {
        cache[k] = Entry(data: old.data, at: old.at)
      } else {
        cache[k] = Entry(data: data, at: data.isErr || data.b("noCache") ? 0 : env.now())
      }
      let shown = cache[k]!.data
      for f in inflight.removeValue(forKey: k) ?? [] { f(shown) }
    }
    if let fetch = p.fetch {
      fetch(req, finish)
      return
    }
    let rid = "preview-" + String(nextExternal)
    nextExternal += 1
    external[rid] = finish
    env.emit("previews.request", ["provider": .string(p.id), "request": .string(rid), "url": .string(req.url),
                                  "anchor": .string(req.anchor), "webview": .string(req.webview), "profile": .string(req.profile)])
  }

  func render(_ req: Request, _ data: Value, loading: Bool) {
    let tree = Cards.card(req, data, loading: loading)
    env.call("ui", "set", ["slot": .string(Self.slot), "tree": tree])
  }

  // MARK: Generic page preview

  func snapshotPath(_ webview: String) -> String { snapshotDir + "/den-preview-" + webview + ".jpg" }

  func showPage(_ req: Request) {
    var data: Value = ["kind": "page"]
    let snap = snapshots[req.webview]
    if let s = snap, s.ok, s.url == req.url {
      data.put("image", .string(s.path))
      data.put("imageVersion", .int(s.version))
    } else if !req.webview.isEmpty {
      data.put("imagePending", true)
    }
    render(req, data, loading: false)
    guard !req.webview.isEmpty else { return }
    let fresh = snap.map { $0.url == req.url && env.now() - $0.at < Self.snapshotTTL } ?? false
    if fresh || snapshotPending[req.webview] == true { return }
    snapshotPending[req.webview] = true
    let r = env.call("webviews", "snapshot", ["id": .string(req.webview), "path": .string(snapshotPath(req.webview)),
                                              "width": .int(Self.snapshotWidth), "format": "jpeg"])
    if r.isErr {
      snapshotPending[req.webview] = nil
      snapshotDone(req.webview, ok: false)
    } else {
      snapshots[req.webview] = Snapshot(url: req.url, path: snapshotPath(req.webview), at: env.now(), version: (snap?.version ?? 0), ok: snap?.ok ?? false)
    }
  }

  func snapshotDone(_ webview: String, ok: Bool) {
    let url = snapshots[webview]?.url ?? current?.url ?? ""
    let version = (snapshots[webview]?.version ?? 0) + 1
    snapshots[webview] = Snapshot(url: url, path: snapshotPath(webview), at: env.now(), version: version, ok: ok)
    guard let c = current, c.webview == webview, c.kind != "folder", match(c.url)?.id ?? "page" == "page" else { return }
    var data: Value = ["kind": "page"]
    if ok {
      data.put("image", .string(snapshotPath(webview)))
      data.put("imageVersion", .int(version))
    }
    render(c, data, loading: false)
  }

  // MARK: Card actions

  func action(_ action: String, _ value: Value) {
    switch action {
    case "close":
      if current?.anchor == value.s("anchor") { current = nil }
    case "open", "action":
      let url = value.s("url")
      if !url.isEmpty { env.call("tabs", "open", ["url": .string(url)]) }
      current = nil
    default:
      break
    }
  }
}

/// URL patterns: `host/path` with `*` wildcards, matched against the URL without its scheme,
/// `www.`, query or fragment. A leading `*.` also matches the bare domain.
enum Pattern {
  static func target(_ url: String) -> String {
    var b = Array(url.utf8)
    if let r = URLs.find(b, Array("://".utf8)) { b = Array(b[(r + 3)...]) }
    var end = b.count
    for (i, c) in b.enumerated() where c == 63 || c == 35 {  // ? #
      end = i
      break
    }
    b = Array(b[..<end])
    while b.last == 47 { b.removeLast() }
    return Text.dropPrefix(Text.lower(String(decoding: b, as: UTF8.self)), "www.")
  }

  static func matches(_ pattern: String, _ target: String) -> Bool {
    if glob(Array(pattern.utf8), Array(target.utf8)) { return true }
    // "*.slack.com/*" also matches "slack.com/…".
    if Text.hasPrefix(pattern, "*.") { return glob(Array(Text.dropPrefix(pattern, "*.").utf8), Array(target.utf8)) }
    return false
  }

  /// `*` matches any run of characters (including `/`); a trailing `/*` also matches nothing.
  static func glob(_ p: [UInt8], _ s: [UInt8]) -> Bool {
    var pi = 0, si = 0, star = -1, mark = 0
    while si < s.count {
      if pi < p.count && p[pi] != 42 && p[pi] == s[si] {
        pi += 1
        si += 1
      } else if pi < p.count && p[pi] == 42 {
        star = pi
        mark = si
        pi += 1
      } else if star >= 0 {
        pi = star + 1
        mark += 1
        si = mark
      } else {
        return false
      }
    }
    while pi < p.count && (p[pi] == 42 || (p[pi] == 47 && pi + 1 < p.count && p[pi + 1] == 42)) { pi += 1 }
    return pi == p.count
  }

  static func specificity(_ pattern: String) -> Int {
    var n = 0
    for c in pattern.utf8 where c != 42 { n += 1 }
    return n
  }

  /// Path segments of a URL: "https://github.com/a/b/pull/3/files" -> ["github.com", "a", "b", "pull", "3", "files"].
  static func segments(_ url: String) -> [String] {
    var out: [String] = []
    var cur: [UInt8] = []
    for c in target(url).utf8 {
      if c == 47 {
        if !cur.isEmpty { out.append(String(decoding: cur, as: UTF8.self)) }
        cur = []
      } else {
        cur.append(c)
      }
    }
    if !cur.isEmpty { out.append(String(decoding: cur, as: UTF8.self)) }
    return out
  }
}

/// Async service calls whose results come back as events (`net.result`, `session.result`,
/// `webviews.evalResult`), matched by request id.
final class PreviewRequests {
  let env: PluginEnv
  var next = 1
  var waiting: [String: (Value) -> Void] = [:]

  init(env: PluginEnv) {
    self.env = env
    for (e, key) in [("net.result", "id"), ("session.result", "id"), ("webviews.evalResult", "request")] {
      env.on(e) { [self] v in
        guard let done = waiting.removeValue(forKey: v.s(key)) else { return }
        done(v)
      }
    }
  }

  /// `idKey` is the argument that carries the request id (`id` for net/session, `request` for webviews).
  func call(_ service: String, _ method: String, _ args: Value, idKey: String = "id", _ done: @escaping (Value) -> Void) {
    let id = "previews-" + String(next)
    next += 1
    var a = args
    a.put(idKey, .string(id))
    a.put("plugin", "previews")
    waiting[id] = done
    let r = env.call(service, method, a)
    if r.isErr {
      waiting[id] = nil
      done(["ok": false, "error": r["error"]])
    }
  }

  func fetch(_ url: String, json: Bool = true, session: Bool = false, profile: String = "default", method: String = "GET",
             headers: Value = .null, body: String? = nil, _ done: @escaping (Value) -> Void) {
    var a: Value = ["url": .string(url), "as": json ? "json" : "text", "session": .bool(session), "profile": .string(profile),
                    "method": .string(method), "timeoutMs": 10_000, "maxBytes": 2_000_000]
    if !headers.isNull { a.put("headers", headers) }
    if let body { a.put("body", .string(body)) }
    call("net", "fetch", a, done)
  }

  var inFlight: Int { waiting.count }
}
