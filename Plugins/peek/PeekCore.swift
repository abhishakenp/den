// The `peek` service: Peek (cross-site links from pinned and favorite tabs open in a floating
// card), split view shortcuts on top of `tabs.split`, and Little Arc (links from other apps open
// in a small floating window). See docs/plugin-services.md and docs/research/arc.md §6-§8.

#if !hasFeature(Embedded)
  import CordisValue
#endif

final class PeekCore {
  static let ns = "peek"
  /// The link-rule event every routed click arrives on.
  static let linkEvent = "peek.link"
  /// Arc's default: "Archive Little Arcs after" 6 hours.
  static let defaultLittleArcArchiveMs: Int64 = 6 * 3_600_000
  /// den's choice: how long Cmd-Z reopens a just-closed peek before it goes back to Edit > Undo.
  static let reopenWindowMs: UInt64 = 15_000
  static let tickMs: UInt64 = 60_000

  struct Closed {
    var url: String
    var source: String?
    var at: Int64
  }

  struct LittleArc {
    var window: String
    var webview: String
    var url: String
    var lastActive: Int64
  }

  let env: PluginEnv

  // Settings (persisted in storage ns "peek", key "settings")
  var peekLinks = true  // "Open a Peek window when clicking on links to other sites"
  var littleArcEnabled = true  // "Links from other apps open in Little Arc"
  var littleArcArchiveMs = PeekCore.defaultLittleArcArchiveMs

  // Runtime
  var peek: String?  // webview id of the open peek
  var peekSource: String?
  var closed: Closed?
  var undoBound = false
  var undoToken = 0
  var escBound = false
  var policyIds: Set<String> = []  // webviews that carry the cross-site rule
  var littleArcs: [LittleArc] = []
  var nextId: Int64 = 1

  init(env: PluginEnv) { self.env = env }

  // MARK: - Lifecycle

  func start() {
    let s = env.call("storage", "get", ["ns": .string(Self.ns), "key": "settings"])
    if let v = s["peekLinks"].bool { peekLinks = v }
    if let v = s["littleArc"].bool { littleArcEnabled = v }
    if let v = s["littleArcArchiveMs"].int { littleArcArchiveMs = v }
    bindKeys()
    subscribe()
    syncPolicy()
    env.timer(Self.tickMs, true) { [self] in tick() }
  }

  func stop() {
    hide(record: false)
    for id in policyIds { env.call("webviews", "setLinkPolicy", ["id": .string(id), "rules": []]) }
    env.call("webviews", "setLinkPolicy", ["id": "*", "rules": []])
    policyIds = []
  }

  func newId(_ prefix: String) -> String {
    defer { nextId += 1 }
    return prefix + String(nextId)
  }

  // MARK: - Service

  func handle(_ method: String, _ args: Value) -> Value {
    switch method {
    case "open":
      let url = args.s("url")
      guard !url.isEmpty else { return .err("peek: open needs a url") }
      return open(url, source: args.sOpt("sourceId"))
    case "close":
      guard peek != nil else { return .err("peek: no peek is open") }
      hide(record: true)
    case "expand":
      guard let id = expand() else { return .err("peek: no peek is open") }
      return ["id": .string(id)]
    case "split":
      let ids = args.a("ids")
      guard !ids.isEmpty else { return .err("peek: split needs ids") }
      return env.call("tabs", "split", ["ids": .array(ids), "layout": .string(args.sOpt("layout") ?? "horizontal"), "focus": args["focus"]])
    case "unsplit":
      return env.call("tabs", "unsplit", ["id": args["id"]])
    case "reopen":
      guard let c = closed, c.at >= args.i("after") else { return .err("peek: nothing to reopen") }
      return open(c.url, source: c.source)
    case "openExternal":
      return ["claimed": .bool(openExternal(args.a("urls").compactMap { $0.string }))]
    case "settings":
      if let v = args["peekLinks"].bool { peekLinks = v }
      if let v = args["littleArc"].bool { littleArcEnabled = v }
      if let v = args["littleArcArchiveMs"].int { littleArcArchiveMs = max(0, v) }
      let v: Value = ["peekLinks": .bool(peekLinks), "littleArc": .bool(littleArcEnabled), "littleArcArchiveMs": .int(littleArcArchiveMs)]
      if !args.isNull {
        env.call("storage", "set", ["ns": .string(Self.ns), "key": "settings", "value": v])
        syncPolicy()
      }
      return v
    case "get":
      return ["peek": .str(peek), "sourceId": .str(peekSource),
              "littleArcs": .array(littleArcs.map { ["window": .string($0.window), "webview": .string($0.webview), "url": .string($0.url)] })]
    default:
      return .err("peek: unknown method " + method)
    }
    return .okay
  }

  // MARK: - Link policy

  /// Rules for pinned and favorite tabs: every cross-site click peeks. Shift- and Option-clicks
  /// peek from any tab (the `*` default); cmd-click keeps opening a background tab.
  static let modifierRules: [Value] = [
    ["when": "any", "modifiers": ["shift"], "event": .string(linkEvent)],
    ["when": "any", "modifiers": ["opt"], "event": .string(linkEvent)],
  ]
  static let pinnedRules: [Value] = [["when": "crossSite", "event": .string(linkEvent)]] + modifierRules

  /// Pinned and favorite tab ids in every space (inside folders and splits too).
  func pinnedTabIds() -> Set<String> {
    var out = Set<String>()
    func walk(_ items: [Value]) {
      for i in items {
        if i["folder"] == true || i["split"] == true { walk(i.a("children")) } else if let id = i["id"].string { out.insert(id) }
      }
    }
    for sp in env.call("spaces", "list").array ?? [] {
      let l = env.call("tabs", "list", ["spaceId": sp["id"]])
      if l.isErr { continue }
      walk(l.a("favorites"))
      walk(l.a("pinned"))
    }
    return out
  }

  /// Re-applies the policy to every pinned/favorite webview, and clears it from tabs that were
  /// unpinned. Always re-sent, because undo can recreate a webview without its rules.
  func syncPolicy() {
    env.call("webviews", "setLinkPolicy", ["id": "*", "rules": .array(Self.modifierRules)])
    let want = peekLinks ? pinnedTabIds() : []
    var applied = Set<String>()
    for id in want.sorted() {
      if !env.call("webviews", "setLinkPolicy", ["id": .string(id), "rules": .array(Self.pinnedRules)]).isErr { applied.insert(id) }
    }
    for id in policyIds.subtracting(applied).sorted() {
      env.call("webviews", "setLinkPolicy", ["id": .string(id), "rules": []])  // back to the `*` default
    }
    policyIds = applied
  }

  // MARK: - Peek

  func open(_ url: String, source: String?) -> Value {
    if peek != nil { hide(record: false) }
    let profile = source.map { env.call("webviews", "get", ["id": .string($0)]).sOpt("profile") ?? "default" } ?? "default"
    let id = newId("peek-")
    let r = env.call("webviews", "create", ["id": .string(id), "url": .string(url), "profile": .string(profile)])
    if r.isErr { return r }
    peek = id
    peekSource = source
    env.call("content", "peek", ["webview": .string(id), "title": .string(URLs.display(url))])
    if !escBound {
      env.call("keys", "bind", ["chord": "esc", "event": "peek.key.close", "title": "Close Peek", "menu": "View"])
      escBound = true
    }
    unbindUndo()
    env.emit("peek.opened", ["id": .string(id), "url": .string(url)])
    return ["id": .string(id)]
  }

  /// Current URL of the peek (it may have navigated since it opened).
  func peekURL() -> String? {
    guard let id = peek else { return nil }
    let u = env.call("webviews", "get", ["id": .string(id)]).s("url")
    return u.isEmpty || u == "about:blank" ? nil : u
  }

  func hide(record: Bool) {
    guard let id = peek else { return }
    let url = peekURL()
    peek = nil
    env.call("content", "peek", [:])
    env.call("webviews", "close", ["id": .string(id)])
    if escBound {
      env.call("keys", "unbind", ["chord": "esc"])
      escBound = false
    }
    if record, let url {
      closed = Closed(url: url, source: peekSource, at: env.now())
      bindUndo()
    }
    peekSource = nil
    env.emit("peek.closed", ["id": .string(id)])
  }

  /// Turns the peek into a normal today tab in the current space, selected.
  func expand() -> String? {
    guard peek != nil else { return nil }
    let url = peekURL() ?? ""
    hide(record: false)
    guard !url.isEmpty else { return nil }
    return env.call("tabs", "open", ["url": .string(url)])["id"].string
  }

  /// The peek's Split button: the page joins the current tab in a split view.
  func splitFromPeek() {
    guard let url = peekURL() else { return hide(record: false) }
    let sel = env.call("tabs", "selected")["id"].string
    hide(record: false)
    guard let id = env.call("tabs", "open", ["url": .string(url), "background": true])["id"].string else { return }
    guard let s = sel else { return _ = env.call("tabs", "select", ["id": .string(id)]) }
    let r = env.call("tabs", "split", ["ids": [.string(s), .string(id)], "layout": .string(layoutOf(s) ?? "horizontal"), "focus": .string(id)])
    if r.isErr { env.call("tabs", "select", ["id": .string(id)]) }
  }

  /// Cmd-Z reopens a just-closed peek for a short while, then goes back to Edit > Undo.
  func bindUndo() {
    undoToken += 1
    let token = undoToken
    env.call("keys", "bind", ["chord": "cmd+z", "event": "peek.key.reopen", "title": "Reopen Peek", "menu": "Edit"])
    undoBound = true
    env.timer(Self.reopenWindowMs, false) { [self] in if undoToken == token { unbindUndo() } }
  }

  func unbindUndo() {
    guard undoBound else { return }
    undoBound = false
    env.call("keys", "unbind", ["chord": "cmd+z"])
  }

  // MARK: - Split view

  /// The split containing tab `id` in the current space's lists, if any: (splitId, layout, tabIds).
  func splitContaining(_ id: String) -> (String, String, [String])? {
    let l = env.call("tabs", "list")
    var found: (String, String, [String])?
    func walk(_ items: [Value]) {
      for i in items where found == nil {
        if i["split"] == true {
          let kids = i.a("children").compactMap { $0["id"].string }
          if kids.contains(id) { found = (i.s("id"), i.s("layout"), kids) }
        } else if i["folder"] == true {
          walk(i.a("children"))
        }
      }
    }
    walk(l.a("favorites"))
    walk(l.a("pinned"))
    walk(l.a("today"))
    return found
  }

  func layoutOf(_ id: String) -> String? { splitContaining(id)?.1 }

  /// Ctrl-Shift-=: a new pane next to the focused one, then the command bar to pick its page.
  func addSplit() {
    guard let sel = env.call("tabs", "selected")["id"].string else { return }
    if let (_, _, kids) = splitContaining(sel), kids.count >= 4 {
      env.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": "Split View holds up to 4 tabs", "icon": "sf:rectangle.split.2x2"]])
      return
    }
    guard let id = env.call("tabs", "open", ["url": "about:blank", "background": true])["id"].string else { return }
    let r = env.call("tabs", "split", ["ids": [.string(sel), .string(id)], "layout": .string(layoutOf(sel) ?? "horizontal"), "focus": .string(id)])
    if r.isErr {
      env.call("tabs", "close", ["id": .string(id)])
      return
    }
    env.call("commands", "open", ["mode": "edit", "query": ""])
  }

  /// Ctrl-Shift--: the focused pane leaves the split. A today tab is archived, a pinned one is
  /// only taken out of the split.
  func closePane() {
    let focus = env.call("content", "get")["focus"].string ?? env.call("tabs", "selected")["id"].string
    guard let id = focus, splitContaining(id) != nil else { return }
    let kind = env.call("tabs", "list")["today"].array.map { list in
      list.contains { item in item["id"].string == id || item.a("children").contains { $0["id"].string == id } }
    } ?? false
    if kind { env.call("tabs", "close", ["id": .string(id)]) } else { env.call("tabs", "unsplit", ["id": .string(id)]) }
  }

  /// Ctrl-Shift-1…4.
  func focusPane(_ n: Int) {
    let panes = env.call("content", "get").a("panes")
    guard n >= 1, n <= panes.count, let id = panes[n - 1].string else { return }
    env.call("content", "focus", ["id": .string(id)])
  }

  // MARK: - Little Arc

  /// Opens each URL in a Little Arc window. Returns false when Little Arc is off or the host has
  /// no mini windows, so the caller (tabs) opens them as tabs instead.
  func openExternal(_ urls: [String]) -> Bool {
    guard littleArcEnabled, !urls.isEmpty else { return false }
    var claimed = false
    for url in urls {
      // "Opening the same link again brings back the existing window."
      if let la = littleArcs.first(where: { URLs.normalize($0.url) == URLs.normalize(url) }) {
        env.call("window", "focusMini", ["id": .string(la.window)])
        claimed = true
        continue
      }
      let web = newId("mini-")
      if env.call("webviews", "create", ["id": .string(web), "url": .string(url)]).isErr { continue }
      let r = env.call("window", "openMini", ["webview": .string(web), "title": .string(URLs.display(url)), "space": .string(spaceName())])
      guard let win = r["id"].string else {
        env.call("webviews", "close", ["id": .string(web)])
        return claimed
      }
      littleArcs.append(LittleArc(window: win, webview: web, url: url, lastActive: env.now()))
      claimed = true
    }
    return claimed
  }

  func spaceName() -> String {
    let cur = env.call("spaces", "current").s("id")
    return (env.call("spaces", "list").array ?? []).first { $0.s("id") == cur }?.s("name") ?? "Space"
  }

  /// "Open in Space" (Cmd-O or the button): the page becomes a today tab in the current space.
  func littleArcToSpace(_ window: String) {
    guard let i = littleArcs.firstIndex(where: { $0.window == window }) else { return }
    let la = littleArcs.remove(at: i)
    var url = env.call("webviews", "get", ["id": .string(la.webview)]).s("url")
    if url.isEmpty || url == "about:blank" { url = la.url }
    env.call("window", "closeMini", ["id": .string(la.window)])
    env.call("webviews", "close", ["id": .string(la.webview)])
    env.call("tabs", "open", ["url": .string(url)])
    env.call("window", "focusMain")
  }

  func littleArcClosed(_ window: String) {
    guard let i = littleArcs.firstIndex(where: { $0.window == window }) else { return }
    env.call("webviews", "close", ["id": .string(littleArcs[i].webview)])
    littleArcs.remove(at: i)
  }

  /// Little Arc windows archive after `littleArcArchiveMs` without use (Arc default 6 h).
  func tick() {
    guard littleArcArchiveMs > 0 else { return }
    let now = env.now()
    for la in littleArcs where now - la.lastActive > littleArcArchiveMs {
      env.call("window", "closeMini", ["id": .string(la.window)])
      littleArcClosed(la.window)
    }
  }

  // MARK: - Input

  func bindKeys() {
    let binds: [(String, String, String, String)] = [
      ("cmd+o", "peek.key.expand", "Open Peek or Little Arc in Space", "File"),
      ("ctrl+shift+=", "peek.key.addSplit", "Add Split View", "View"),
      ("ctrl+shift+-", "peek.key.closePane", "Close Split Pane", "View"),
    ]
    for (c, e, t, m) in binds { env.call("keys", "bind", ["chord": .string(c), "event": .string(e), "title": .string(t), "menu": .string(m)]) }
    for n in 1...4 {
      env.call("keys", "bind", ["chord": .string("ctrl+shift+" + String(n)), "event": "peek.key.focusPane", "title": .string("Focus Split Pane " + String(n)),
                                "menu": "View", "payload": .int(Int64(n))])
    }
  }

  func subscribe() {
    env.on(Self.linkEvent) { [self] v in
      guard !v.s("url").isEmpty else { return }
      _ = open(v.s("url"), source: v.sOpt("id"))
    }
    env.on("content.peekAction") { [self] v in
      guard v.s("webview") == peek else { return }
      switch v.s("action") {
      case "close": hide(record: true)
      case "expand": _ = expand()
      case "split": splitFromPeek()
      default: break
      }
    }
    env.on("tabs.changed") { [self] _ in syncPolicy() }
    env.on("tabs.selected") { [self] _ in unbindUndo() }
    env.on("spaces.changed") { [self] _ in syncPolicy() }
    env.on("peek.key.close") { [self] _ in hide(record: true) }
    env.on("peek.key.reopen") { [self] _ in
      unbindUndo()
      if let c = closed { _ = open(c.url, source: c.source) }
    }
    env.on("peek.key.expand") { [self] _ in
      if peek != nil { _ = expand(); return }
      if let w = env.call("window", "keyMini")["id"].string { littleArcToSpace(w) }
    }
    env.on("peek.key.addSplit") { [self] _ in addSplit() }
    env.on("peek.key.closePane") { [self] _ in closePane() }
    env.on("peek.key.focusPane") { [self] v in focusPane(Int(v["payload"].int ?? 1)) }
    env.on("window.miniAction") { [self] v in
      let w = v.s("id")
      if let i = littleArcs.firstIndex(where: { $0.window == w }) { littleArcs[i].lastActive = env.now() }
      if v.s("action") == "openInSpace" { littleArcToSpace(w) }
    }
    env.on("window.miniClosed") { [self] v in littleArcClosed(v.s("id")) }
  }
}
