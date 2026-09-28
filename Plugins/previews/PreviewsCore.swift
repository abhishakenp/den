#if !hasFeature(Embedded)
  import CordisValue
#endif

/// Hover previews: the tab card (sidebar rows, tiles, folders, splits), the GitHub PR peek, and
/// ⇧-hover link cards on any page. The host gives generic pieces (hover intent on nodes,
/// `ui.card`, `webviews.watchLinks`, `net.fetch`); this plugin decides what a card shows and does.
/// Nothing is fetched, timed or captured until something is hovered. It also owns the link status
/// pill (Arc): the hovered link's address at the bottom of the page (`webviews.watchStatus`, the
/// `ui` `status` slot); after `statusFullMs` on one link it shows the whole address.
final class PreviewsCore {
  static let ns = "previews"
  static let snapshotTTL: Int64 = 30_000
  /// Compact page snapshot: twice the card's widest (200 pt) is plenty on Retina.
  static let snapshotWidth: Int64 = 400
  static let linkTTL: Int64 = 10 * 60_000
  static let linkCacheMax = 100
  /// Plain-hover link cards (a setting, off by default) wait like a list row does.
  static let linkHoverDelayMs: UInt64 = 700
  /// Sites with their own link previews: den's card stays out of their way.
  static let yieldTo: [Value] = [".mwe-popups", ".mw-mmv-overlay", "[data-testid=\"hoverCardParent\"]", ".Popover-message", ".hovercard"]
  /// `<head>` only: stop reading there (or at 256 KB).
  static let headBytes: Int64 = 262_144
  /// Arc: the status pill shows the full address after 1.5 s on the same link (docs/research/arc.md).
  static let statusFullMs: UInt64 = 1500
  /// Short form: the path is cut to this many bytes (plus "…").
  static let statusPathMax = 48

  struct Provider {
    var id: String
    var pattern: String
    var owner: String?
    var ttlMs: Int64
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
    var drift = false
    var audio = false
    var muted = false
    var inSplit = false
    var spaces: [Value] = []
    var panes: [Value]?
    var place = "trailing"
    /// A link under the pointer (⇧-hover) rather than a tab.
    var link = false
    var rect: Value = .null

    init(anchor: String, url: String, title: String, icon: String, webview: String, profile: String, selected: Bool, kind: String, items: [Value]) {
      (self.anchor, self.url, self.title, self.icon, self.webview, self.profile, self.selected, self.kind, self.items) =
        (anchor, url, title, icon, webview, profile, selected, kind, items)
    }
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
  var link: Request?
  var linkGen = 0
  var og: [String: Entry] = [:]
  var ogOrder: [String] = []
  var snapshots: [String: Snapshot] = [:]
  var snapshotPending: [String: Bool] = [:]
  var nextExternal = 1
  var snapshotDir = "/tmp"
  var slackTeams: [Value]?
  var fetches = 0
  /// Settings: link previews `shift` (default) | `hover` | `off`; `redwell`: wait again before
  /// swapping to another tab's card (Dia) instead of swapping at once (Arc, default).
  var linkMode = "shift"
  var redwell = false
  /// Settings: "Show link addresses" (the status pill), on by default.
  var showStatus = true
  var statusURL: String?
  var statusGen = 0

  init(env: PluginEnv) {
    self.env = env
    requests = PreviewRequests(env: env)
  }

  func start() {
    Builtins.register(self)
    env.on("ui.action") { [self] v in uiAction(v.s("id"), v.s("action"), v["value"]) }
    env.on("webviews.snapshot") { [self] v in
      let id = v.s("id")
      if v.s("path") == snapshotPath(id), snapshotPending.removeValue(forKey: id) != nil { snapshotDone(id, ok: v.b("ok")) }
    }
    env.on("tabs.closed") { [self] v in snapshots[v.s("id")] = nil }
    env.on("webviews.linkHover") { [self] v in linkHover(v) }
    env.on("webviews.linkHoverEnd") { [self] v in if link?.webview == v.s("id") { hideLink() } }
    env.on("webviews.linkStatus") { [self] v in linkStatus(v) }
    env.on("connections.changed") { [self] _ in connectionsChanged() }
    env.on("settings.changed") { [self] v in
      guard v.s("id") == Self.ns else { return }
      applySetting(v.s("key"), v["value"])
    }
    let saved = env.call("settings", "get", ["id": .string(Self.ns)])
    if !saved.isErr, !saved.isNull {
      if let m = saved.sOpt("links") { linkMode = m }
      if let r = saved["redwell"].bool { redwell = r }
      if let st = saved["status"].bool { showStatus = st }
    }
    registerSettings()
    applyLinkMode()
    applyStatus()
  }

  // MARK: Settings

  func registerSettings() {
    env.call("settings", "register", [
      "id": .string(Self.ns), "title": "Previews", "icon": "sf:rectangle.on.rectangle", "order": 25,
      "controls": [
        ["key": "links", "type": "choice", "title": "Link previews", "default": "shift",
         "subtitle": "A card with the link's picture, title and summary. den reads only the page's head, and only when you ask.",
         "options": [["value": "shift", "title": "Hold ⇧ and hover"], ["value": "hover", "title": "Hover"], ["value": "off", "title": "Off"]]],
        ["key": "status", "type": "toggle", "title": "Show link addresses", "default": true,
         "subtitle": "Hovering a link shows where it goes at the bottom of the page. Stay on it to see the whole address."],
        ["key": "redwell", "type": "toggle", "title": "Wait before switching tab cards", "default": false,
         "subtitle": "With a card open, moving to another tab waits for its own delay instead of switching at once."],
      ],
    ])
  }

  func applySetting(_ key: String, _ v: Value) {
    switch key {
    case "links":
      linkMode = v.string ?? "shift"
      applyLinkMode()
    case "redwell":
      redwell = v.bool ?? false
    case "status":
      showStatus = v.bool ?? true
      applyStatus()
    default: break
    }
  }

  func applyLinkMode() {
    let modifier = linkMode == "hover" ? "none" : linkMode == "off" ? "off" : "shift"
    env.call("webviews", "watchLinks", ["modifier": .string(modifier), "yieldTo": .array(Self.yieldTo)])
    if linkMode == "off" { hideLink() }
  }

  // MARK: Link status pill

  func applyStatus() {
    env.call("webviews", "watchStatus", ["enabled": .bool(showStatus)])
    if !showStatus { hideStatus() }
  }

  func linkStatus(_ v: Value) {
    guard showStatus else { return }
    let url = v.s("url"), id = v.s("id")
    statusGen += 1
    guard !url.isEmpty else { hideStatus(); return }
    statusURL = url
    setStatus(id, url, full: false)
    // Staying on one link shows the whole address (only when there's more to show).
    let short = Self.statusParts(url, full: false), long = Self.statusParts(url, full: true)
    guard short.lead != long.lead || short.text != long.text else { return }
    let gen = statusGen
    env.timer(Self.statusFullMs, false) { [self] in
      if statusGen == gen, statusURL == url { setStatus(id, url, full: true) }
    }
  }

  func setStatus(_ webview: String, _ url: String, full: Bool) {
    let p = Self.statusParts(url, full: full)
    env.call("ui", "set", ["slot": "status", "tree": ["webview": .string(webview), "lead": .string(p.lead), "text": .string(p.text), "url": .string(url)]])
  }

  func hideStatus() {
    guard statusURL != nil else { return }
    statusURL = nil
    statusGen += 1
    env.call("ui", "set", ["slot": "status", "tree": .null])
  }

  /// The pill's words for a link: `lead` (the host, emphasized) and `text` (the rest). Short form:
  /// no scheme, no "www.", just the path, cut at `statusPathMax` bytes. Full form: everything after
  /// the host (query and fragment too). Non-web links (mailto:, tel:) show as they are.
  static func statusParts(_ url: String, full: Bool) -> (lead: String, text: String) {
    let b = Array(url.utf8)
    let l = Text.lower(url)
    var start = 0
    if Text.hasPrefix(l, "https://") { start = 8 } else if Text.hasPrefix(l, "http://") { start = 7 }
    guard start > 0 else { return ("", full ? url : cut(url, statusPathMax + 16)) }
    var end = start
    while end < b.count, b[end] != 47, b[end] != 63, b[end] != 35 { end += 1 }  // / ? #
    var host = Array(b[start..<end])
    if let at = host.lastIndex(of: 64) { host = Array(host[(at + 1)...]) }  // user@
    var h = Text.lower(String(decoding: host, as: UTF8.self))
    h = Text.dropPrefix(h, "www.")
    h = IDN.display(h)
    var rest = Array(b[end...])
    if !full {
      var p = 0
      while p < rest.count, rest[p] != 63, rest[p] != 35 { p += 1 }
      rest = Array(rest[..<p])
    }
    if rest == [47] { rest = [] }
    let text = URLs.percentDecode(rest)
    return (h, full ? text : cut(text, statusPathMax))
  }

  /// At most `max` bytes, cut on a character boundary, with "…".
  static func cut(_ s: String, _ max: Int) -> String {
    let b = Array(s.utf8)
    guard b.count > max else { return s }
    var n = max
    while n > 0, b[n] & 0xC0 == 0x80 { n -= 1 }
    return String(decoding: b[..<n], as: UTF8.self) + "…"
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
      og = [:]
      ogOrder = []
    case "stats":
      return ["fetches": .int(Int64(fetches)), "cached": .int(Int64(cache.count)), "inflight": .int(Int64(inflight.count)),
              "links": .int(Int64(og.count))]
    default:
      return .err("previews: unknown method '" + method + "'")
    }
    return .okay
  }

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

  // MARK: Tab cards

  func show(_ args: Value) {
    var req = Request(anchor: args.s("anchor"), url: args.s("url"), title: args.s("title"), icon: args.s("icon"),
                      webview: args.s("webview"), profile: args.s("profile"), selected: args.b("selected"),
                      kind: args.s("kind"), items: args.a("items"))
    guard !req.anchor.isEmpty else { return }
    req.drift = args.b("drift")
    req.audio = args.b("audio")
    req.muted = args.b("muted")
    req.inSplit = args.b("inSplit")
    req.spaces = args.a("spaces")
    req.place = args.sOpt("place") ?? (req.kind == "favorite" ? "tile" : "trailing")
    if !args["panes"].isNull { req.panes = args.a("panes") }
    if req.profile.isEmpty, !req.webview.isEmpty {
      req.profile = env.call("webviews", "get", ["id": .string(req.webview)]).sOpt("profile") ?? "default"
    }
    if req.profile.isEmpty { req.profile = "default" }
    current = req
    hideLink()
    if req.kind == "folder" {
      present(req, Cards.folder(req, cached: { [self] url in cachedData(url) }), width: .int(Cards.wideWidth))
      return
    }
    if req.panes != nil {
      present(req, Cards.tab(req), width: Cards.width(actions: 3))
      return
    }
    guard let p = match(req.url), p.id != "page" else {
      showPage(req)
      return
    }
    let k = key(p, req.url)
    let entry = cache[k]
    render(req, entry?.data ?? .null, loading: entry == nil)
    if let e = entry, env.now() - e.at < p.ttlMs { return }
    load(p, req, key: k) { [self] data in
      if let c = current, c.anchor == req.anchor, c.url == req.url { render(c, data, loading: false) }
    }
  }

  func hide() {
    current = nil
    env.call("ui", "card", ["id": .string(Cards.tabCard), "tree": nil])
  }

  func cachedData(_ url: String) -> Value? {
    guard let p = match(url), p.id != "page" else { return nil }
    return cache[key(p, url)]?.data
  }

  func load(_ p: Provider, _ req: Request, key k: String, _ redraw: @escaping (Value) -> Void) {
    if inflight[k] != nil {
      inflight[k]!.append(redraw)
      return
    }
    inflight[k] = [redraw]
    fetches += 1
    let finish: (Value) -> Void = { [self] data in
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

  /// The card for a tab whose provider has data (or is loading).
  func render(_ req: Request, _ data: Value, loading: Bool) {
    let acts = Cards.tabActions(req)
    if data.s("kind") == "pr" || (loading && match(req.url)?.id == "github.pr") {
      present(req, Cards.pr(data, title: req.title, loading: loading, actions: acts), width: ["min": .int(Cards.wideWidth), "max": .int(max(Cards.wideWidth, Int64(acts.count) * 32 + 6))])
    } else {
      present(req, Cards.fragment(req, data, loading: loading, actions: acts), width: ["min": .int(Cards.wideWidth), "max": .int(max(Cards.wideWidth, Int64(acts.count) * 32 + 6))])
    }
  }

  func present(_ req: Request, _ tree: Value, width: Value) {
    env.call("ui", "card", ["id": .string(Cards.tabCard), "anchor": .string(req.anchor), "tree": tree, "width": width,
                            "place": .string(req.place), "swap": .string(redwell ? "dwell" : "instant")])
  }

  func snapshotPath(_ webview: String) -> String { snapshotDir + "/den-preview-" + webview + ".jpg" }

  /// Any other page: the compact card, with a small snapshot of the page when it isn't the tab
  /// you're looking at (taken on hover, kept 30 s).
  func showPage(_ req: Request) {
    let acts = Cards.tabActions(req)
    let width = Cards.width(actions: acts.count)
    guard !req.selected, !req.webview.isEmpty else {
      present(req, Cards.tab(req), width: width)
      return
    }
    let snap = snapshots[req.webview]
    let fresh = snap.map { $0.url == req.url && env.now() - $0.at < Self.snapshotTTL } ?? false
    let pending = snapshotPending[req.webview] == true
    if let s = snap, s.ok, s.url == req.url {
      present(req, Cards.tab(req, image: s.path, imageVersion: s.version), width: width)
    } else if fresh && !pending {
      present(req, Cards.tab(req), width: width)  // a snapshot just failed: no picture
    } else {
      // The image's space is reserved while the snapshot is taken, so nothing jumps when it lands.
      present(req, Cards.tab(req, imagePending: true), width: width)
    }
    if fresh || pending { return }
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
    guard let c = current, c.webview == webview, c.kind != "folder", c.panes == nil, match(c.url)?.id ?? "page" == "page", !c.selected else { return }
    let acts = Cards.tabActions(c)
    present(c, ok ? Cards.tab(c, image: snapshotPath(webview), imageVersion: version) : Cards.tab(c), width: Cards.width(actions: acts.count))
  }

  // MARK: Actions

  func uiAction(_ id: String, _ action: String, _ value: Value) {
    if id == Cards.tabCard, action == "close" {
      if current?.anchor == value.s("anchor") { current = nil }
      return
    }
    if id == Cards.linkCard, action == "close" {
      link = nil
      return
    }
    guard Text.hasPrefix(id, "previews.") else { return }
    if Text.hasPrefix(id, "previews.tab.act:") {
      tabAction(Text.dropPrefix(id, "previews.tab.act:"), action, value)
    } else if Text.hasPrefix(id, "previews.link.act:") {
      linkAction(Text.dropPrefix(id, "previews.link.act:"))
    } else if Text.hasPrefix(id, "previews.pr:") {
      prAction(Text.dropPrefix(id, "previews.pr:"), value)
    } else if Text.hasPrefix(id, "previews.open:") {
      // A folder card: a row switches to its tab; "New Tab" adds one at the end of the folder.
      if let tab = value.sOpt("tab"), !env.call("tabs", "select", ["id": .string(tab)]).isErr { return hide() }
      if value.s("action") == "newTab", let c = current {
        env.call("tabs", "newTab", ["folderId": .string(c.anchor)])
        return hide()
      }
      open(value.s("url"))
    }
  }

  func tabAction(_ name: String, _ action: String, _ value: Value) {
    guard let c = current else { return }
    let tab = c.panes?.first?.s("id") ?? c.webview
    switch name {
    case "move":
      guard action == "menu", let sid = value.string, !sid.isEmpty else { return }
      env.call("tabs", "act", ["id": .string(tab), "action": "move", "value": ["spaceId": .string(sid)]])
    case "separate":
      env.call("tabs", "unsplit", ["id": .string(c.anchor)])
    case "mute", "unmute":
      env.call("tabs", "act", ["id": .string(tab), "action": .string(name)])
      // The card stays: it now offers the opposite.
      var r = c
      r.muted = name == "mute"
      show(requestArgs(r))
      return
    default:
      env.call("tabs", "act", ["id": .string(tab), "action": .string(name)])
    }
    hide()
  }

  /// A request as `show` args (re-rendering after an in-place change).
  func requestArgs(_ r: Request) -> Value {
    var v: Value = ["anchor": .string(r.anchor), "url": .string(r.url), "title": .string(r.title), "icon": .string(r.icon),
                    "webview": .string(r.webview), "profile": .string(r.profile), "selected": .bool(r.selected), "kind": .string(r.kind),
                    "drift": .bool(r.drift), "audio": .bool(r.audio), "muted": .bool(r.muted), "inSplit": .bool(r.inSplit),
                    "spaces": .array(r.spaces), "place": .string(r.place)]
    if let p = r.panes { v.put("panes", .array(p)) }
    return v
  }

  /// PR peek buttons and failing-check rows.
  func prAction(_ what: String, _ value: Value) {
    let req = link ?? current
    guard let r = req, let (repo, n) = GitHub.parse(r.url) else { return }
    let web = "https://github.com/" + repo + "/pull/" + String(n)
    switch what {
    case "connect":
      env.call("connections", "connect", ["id": "github"])
      return  // the card stays; it fills in when GitHub connects
    case "failures": open(web + "/checks", in: r)
    case "comments": open(web, in: r)
    case "conflicts": open(web + "/conflicts", in: r)
    default:
      if Text.hasPrefix(what, "check:") { open(value.s("url"), in: nil) }
    }
    link == nil ? hide() : hideLink(now: true)
  }

  /// Opens `url`: in the hovered tab itself when the card is a tab's (select + navigate), else
  /// in a new tab.
  func open(_ url: String, in req: Request?) {
    guard !url.isEmpty else { return }
    if let r = req, !r.link, !r.webview.isEmpty {
      env.call("tabs", "select", ["id": .string(r.webview)])
      env.call("tabs", "navigate", ["id": .string(r.webview), "url": .string(url)])
    } else {
      env.call("tabs", "open", ["url": .string(url)])
    }
  }

  func open(_ url: String) {
    if !url.isEmpty { env.call("tabs", "open", ["url": .string(url)]) }
    hide()
    hideLink(now: true)
  }

  /// GitHub connected (or disconnected): private-repo cards fill in live.
  func connectionsChanged() {
    var dropped = false
    for (k, e) in cache where e.data.b("private") || e.data.b("limited") {
      cache[k] = nil
      dropped = true
    }
    guard dropped else { return }
    if let c = current, GitHub.parse(c.url) != nil { show(requestArgs(c)) }
    if let l = link, GitHub.parse(l.url) != nil { showLink(l) }
  }

  // MARK: Link cards (⇧-hover)

  func linkHover(_ v: Value) {
    guard linkMode != "off" else { return }
    let url = v.s("url")
    guard !url.isEmpty, !v.b("yield") else {
      if v.b("yield") { hideLink(now: true) }
      return
    }
    var r = Request(anchor: "link", url: url, title: v.s("text"), icon: "", webview: v.s("id"), profile: "default", selected: false,
                    kind: "link", items: [])
    r.link = true
    r.rect = v["rect"]
    r.profile = env.call("webviews", "get", ["id": .string(r.webview)]).sOpt("profile") ?? "default"
    linkGen += 1
    let gen = linkGen
    link = r
    if linkMode == "hover" {
      env.timer(Self.linkHoverDelayMs, false) { [self] in if linkGen == gen, let l = link { showLink(l) } }
    } else {
      showLink(r)
    }
  }

  func hideLink(now: Bool = false) {
    linkGen += 1
    guard link != nil else { return }
    link = nil
    var a: Value = ["id": .string(Cards.linkCard), "tree": nil]
    if now { a.put("graceMs", 0) }
    env.call("ui", "card", a)
  }

  func presentLink(_ r: Request, _ tree: Value, width: Value) {
    env.call("ui", "card", ["id": .string(Cards.linkCard), "rect": r.rect, "place": "below", "tree": tree, "width": width])
  }

  func showLink(_ r: Request) {
    // Rich providers first: a pull request link gets the PR peek.
    if let p = match(r.url), p.id != "page" {
      let k = key(p, r.url)
      let draw: (Value, Bool) -> Void = { [self] data, loading in
        guard let l = link, l.url == r.url else { return }
        let acts = Cards.linkActions()
        let w: Value = .int(Cards.wideWidth)
        if data.s("kind") == "pr" || (loading && p.id == "github.pr") {
          presentLink(l, Cards.pr(data, title: l.title, loading: loading, actions: acts), width: w)
        } else {
          presentLink(l, Cards.fragment(l, data, loading: loading, actions: acts), width: w)
        }
      }
      let entry = cache[k]
      draw(entry?.data ?? .null, entry == nil)
      if let e = entry, env.now() - e.at < p.ttlMs { return }
      load(p, r, key: k) { data in draw(data, false) }
      return
    }
    let u = r.url
    if let e = og[u], env.now() - e.at < Self.linkTTL {
      presentLink(r, Cards.link(url: u, og: e.data, loading: false), width: .int(Cards.linkWidth))
      return
    }
    presentLink(r, Cards.link(url: u, og: ["title": .string(r.title)], loading: true), width: .int(Cards.linkWidth))
    fetchHead(u, profile: r.profile) { [self] data in
      guard let l = link, l.url == u else { return }
      presentLink(l, Cards.link(url: u, og: data, loading: false), width: .int(Cards.linkWidth))
    }
  }

  /// Reads the page's `<head>` only (a Range request, and the host stops at `</head>`), parses
  /// its OpenGraph tags, and caches the result for 10 minutes. No cookies are sent.
  func fetchHead(_ url: String, profile: String, _ done: @escaping (Value) -> Void) {
    if let wait = inflight["og|" + url] {
      inflight["og|" + url] = wait + [done]
      return
    }
    inflight["og|" + url] = [done]
    fetches += 1
    let args: Value = ["url": .string(url), "as": "text", "method": "GET", "timeoutMs": 8000, "maxBytes": .int(Self.headBytes),
                       "stopAfter": "</head>", "headers": ["Range": .string("bytes=0-" + String(Self.headBytes - 1)), "Accept": "text/html,application/xhtml+xml"]]
    requests.call("net", "fetch", args) { [self] r in
      var data: Value = r.b("ok") && r.i("status") < 400 ? OpenGraph.parse(OpenGraph.headOnly(r.s("text")), url: url) : [:]
      if data.s("title").isEmpty, let l = link, l.url == url, !l.title.isEmpty { data.put("title", .string(l.title)) }
      og[url] = Entry(data: data, at: r.b("ok") ? env.now() : 0)
      ogOrder.removeAll { $0 == url }
      ogOrder.append(url)
      while ogOrder.count > Self.linkCacheMax { og[ogOrder.removeFirst()] = nil }
      for f in inflight.removeValue(forKey: "og|" + url) ?? [] { f(data) }
    }
  }

  func linkAction(_ name: String) {
    guard let l = link else { return }
    switch name {
    case "peek":
      env.call("peek", "open", ["url": .string(l.url), "sourceId": .string(l.webview)])
    case "split":
      if let id = env.call("tabs", "open", ["url": .string(l.url), "background": true]).sOpt("id"),
         let sel = env.call("tabs", "selected").sOpt("id") {
        env.call("tabs", "split", ["ids": [.string(sel), .string(id)], "layout": "horizontal", "focus": .string(id)])
      }
    case "copy":
      env.call("app", "copy", ["text": .string(l.url)])
      env.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": "Copied Link", "icon": "sf:link"]])
    default: break
    }
    hideLink(now: true)
  }
}

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
