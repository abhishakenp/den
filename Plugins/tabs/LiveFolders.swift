// Live folders: a pinned folder filled by a connection instead of tabs (Zen's live folders,
// Dia's live groups). Part of the `tabs` plugin; TabsCore owns one `LiveFolders`.

#if !hasFeature(Embedded)
  import CordisValue
#endif

/// A live folder (`Folder.live`, e.g. "github") shows its source's feed items as rows:
///
/// - **Unread**: an item you haven't opened gets a dot; a collapsed folder shows a dot on its icon
///   while any row is unread. The items present when the folder is made start as read.
/// - **Done**: an item that leaves the feed (review given, PR merged, issue closed) or that you
///   mark done (the row's ×) goes into the header's "N ✓" chip; clicking it opens a Recently
///   Closed popover where each one can be reopened. Kept 7 days, at most 20.
/// - **PR stacks**: pull requests whose base branch is another open PR's head branch (the
///   `github` plugin adds `head`/`base` to your PRs) are grouped under a collapsible stack row.
/// - **Reauth cue**: signed out of the source, the folder shows one "Sign in" row.
/// - **Cost**: nothing of its own. Rows come from the `feed.items` the briefing's refresh already
///   gets (every 15 minutes while connected); a new folder, launch and "Refresh" ask once.
/// Per-folder state (seen keys, done items, closed stacks) persists in storage ns `tabs` key `live`.
final class LiveFolders {
  struct Source {
    var id: String
    var title: String
    var icon: String
  }

  static let sources: [Source] = [
    Source(id: "github", title: "GitHub", icon: "https://github.com/favicon.ico"),
  ]
  static let maxDone = 20
  static let doneKeepMs: Int64 = 7 * 86_400_000
  static let maxSeen = 300
  static let donePopover = "tabs.liveDone:"

  let core: TabsCore
  var env: PluginEnv { core.env }
  /// Source -> its latest feed items (memory only).
  var items: [String: [Value]] = [:]
  /// Folder id -> {seen: [key], done: [{key, title, url, icon, at}], dismissed: [key], closed: [stack key], primed}.
  var state: [String: Value] = [:]
  var registered: [String] = []
  var registerAttempts = 0
  var retrying = false
  var popoverFor = ""

  init(core: TabsCore) { self.core = core }

  func start() {
    if case let .object(pairs) = env.call("storage", "get", ["ns": .string(TabsCore.ns), "key": "live"]) { for (k, v) in pairs { state[k] = v } }
    env.on("feed.items") { [self] v in received(v) }
    env.on("connections.changed") { [self] _ in
      registerCommands()
      rerender()
    }
    env.on("commands.run") { [self] v in command(v.s("id")) }
    registerCommands()
    // Fill existing live folders once after launch (a moment later: providers load after tabs).
    if core.folders.values.contains(where: { !$0.live.isEmpty }) {
      env.timer(3000, false) { [self] in refresh() }
    }
  }

  static func source(_ id: String) -> Source? { sources.first { $0.id == id } }

  func folders(of source: String) -> [TabsCore.Folder] { core.folders.values.filter { $0.live == source } }

  func save() {
    env.call("storage", "set", ["ns": .string(TabsCore.ns), "key": "live", "value": .object(state.keys.sorted().map { ($0, state[$0]!) })])
  }

  func strings(_ fid: String, _ key: String) -> [String] { state[fid]?.a(key).compactMap { $0.string } ?? [] }
  func setStrings(_ fid: String, _ key: String, _ list: [String]) {
    var s = state[fid] ?? [:]
    s.put(key, .array(list.map { .string($0) }))
    state[fid] = s
  }

  func connected(_ source: String) -> Bool {
    return env.call("connections", "get", ["id": .string(source)]).b("connected")
  }
  // MARK: Feed

  /// Asks the source for fresh items (the same `feed.refresh` the briefing sends).
  func refresh() {
    let live = Set(core.folders.values.map { $0.live }.filter { !$0.isEmpty })
    for s in live.sorted() where connected(s) {
      env.emit("feed.refresh", ["reason": "live", "sources": [.string(s)]])
    }
  }

  func received(_ v: Value) {
    let src = v.s("source")
    guard Self.source(src) != nil else { return }
    let new = v.a("items")
    let failed = v.sOpt("error") != nil
    let now = env.now()
    var changed = false
    for f in folders(of: src) {
      let keys = new.map { $0.s("id") }
      var s = state[f.id] ?? [:]
      if !s.b("primed") {
        guard !failed else { continue }
        // A new folder: what's there now starts as read.
        s.put("primed", true)
        s.put("seen", .array(keys.map { .string($0) }))
        state[f.id] = s
        changed = true
        continue
      }
      // Items that left the feed are done (not on an error: a failed refresh says nothing).
      if !failed, let old = items[src] {
        var done = s.a("done")
        for it in old where !keys.contains(it.s("id")) && !done.contains(where: { $0.s("key") == it.s("id") }) {
          done.insert(["key": it["id"], "title": it["title"], "url": it["url"], "icon": .string(icon(it)), "at": .int(now)], at: 0)
        }
        s.put("done", .array(Array(done.filter { now - $0.i("at") < Self.doneKeepMs }.prefix(Self.maxDone))))
        // Dismissed rows that left the feed needn't be remembered.
        s.put("dismissed", .array(strings(f.id, "dismissed").filter { keys.contains($0) }.map { .string($0) }))
        // Seen: only what can still show, bounded.
        let seen = strings(f.id, "seen").filter { keys.contains($0) }
        s.put("seen", .array(Array(seen.suffix(Self.maxSeen)).map { .string($0) }))
      }
      state[f.id] = s
      changed = true
    }
    if !failed || new.isEmpty == false { items[src] = new }
    if changed { save() }
    rerender()
  }

  func rerender() {
    var spaces: [String] = []
    for f in core.folders.values where !f.live.isEmpty && !spaces.contains(f.spaceId) { spaces.append(f.spaceId) }
    for sid in spaces { core.renderPage(sid) }
  }

  // MARK: Rendering

  static func kindIcon(_ kind: String) -> String {
    switch kind {
    case "review": return "sf:eye"
    case "ci": return "sf:xmark.octagon"
    case "assigned": return "sf:smallcircle.filled.circle"
    case "mention": return "sf:at"
    case "authored": return "sf:arrow.triangle.pull"
    default: return "sf:circle"
    }
  }

  func icon(_ it: Value) -> String {
    return Self.kindIcon(it.s("kind"))
  }

  func visible(_ fid: String, _ source: String) -> [Value] {
    let dismissed = strings(fid, "dismissed")
    return (items[source] ?? []).filter { !dismissed.contains($0.s("id")) }
  }

  func unread(_ fid: String, _ source: String) -> Bool {
    let seen = strings(fid, "seen")
    return visible(fid, source).contains { !seen.contains($0.s("id")) }
  }

  /// The folder node for a live folder (TabsCore.node calls this).
  func node(_ f: TabsCore.Folder, indent: Double = 0) -> Value {
    let src = Self.source(f.live)
    let done = state[f.id]?.a("done") ?? []
    var menu: [Value] = [["id": "renameFolder", "title": "Rename Folder…", "icon": "sf:pencil"],
                         ["id": "liveRefresh", "title": "Refresh", "icon": "sf:arrow.clockwise"]]
    if unread(f.id, f.live) { menu.append(["id": "liveRead", "title": "Mark All as Read", "icon": "sf:checkmark.circle"]) }
    menu.append(["separator": true])
    menu.append(["id": "deleteFolder", "title": "Delete Live Folder…", "icon": "sf:trash"])
    var v: Value = ["type": "folder", "id": .string(f.id), "title": .string(f.title), "icon": .string(src?.icon ?? "sf:bolt.fill"),
                    "open": .bool(f.open), "editing": .bool(core.editing == f.id), "children": .array(f.open ? rows(f) : []), "menu": .array(menu)]
    if !f.open && unread(f.id, f.live) { v.put("unread", true) }
    if !done.isEmpty { v.put("badge", .string(String(done.count) + " ✓")) }
    return v
  }

  func rows(_ f: TabsCore.Folder) -> [Value] {
    let title = Self.source(f.live)?.title ?? f.live
    if !connected(f.live) {
            return [["type": "tabRow", "id": .string("live:" + f.id + ":connect"), "title": .string("Sign in to " + title + " to fill this folder"),
               "icon": "sf:exclamationmark.triangle", "selected": false, "closable": false, "draggable": false]]
    }
    
        guard items[f.live] != nil else {
      return [["type": "tabRow", "id": .string("live:" + f.id + ":loading"), "title": "Loading…", "icon": "sf:hourglass",
               "selected": false, "closable": false, "draggable": false]]
    }
    let list = visible(f.id, f.live)
    if list.isEmpty {
      return [["type": "tabRow", "id": .string("live:" + f.id + ":empty"), "title": "Nothing needs you right now", "icon": "sf:checkmark.circle",
               "selected": false, "closable": false, "draggable": false]]
    }
    let seen = strings(f.id, "seen")
    let closed = strings(f.id, "closed")
    let stacks = Self.stacks(list)
    var inStack: [String: String] = [:]  // item key -> its stack's key
    for s in stacks { for k in s.members { inStack[k] = s.key } }
    var out: [Value] = []
    var placed: [String] = []
    for it in list {
      let k = it.s("id")
      if let sk = inStack[k] {
        guard !placed.contains(sk), let s = stacks.first(where: { $0.key == sk }) else { continue }
        placed.append(sk)
        let members = s.members.compactMap { m in list.first { $0.s("id") == m } }
        let open = !closed.contains(sk)
        var sv: Value = ["type": "folder", "id": .string("livestack:" + f.id + ":" + sk), "title": .string(s.title + " · " + String(members.count) + " PRs"),
                         "icon": "sf:square.stack.3d.up", "open": .bool(open),
                         "children": .array(open ? members.map { row(f.id, $0, seen: seen) } : [])]
        if !open && members.contains(where: { !seen.contains($0.s("id")) }) { sv.put("unread", true) }
        out.append(sv)
      } else {
        out.append(row(f.id, it, seen: seen))
      }
    }
    return out
  }

  func row(_ fid: String, _ it: Value, seen: [String]) -> Value {
    let k = it.s("id")
    var v: Value = ["type": "tabRow", "id": .string("live:" + fid + ":" + k), "title": .string(it.s("title")), "icon": .string(icon(it)),
                    "selected": false, "closable": true, "closeTitle": "Mark as Done", "draggable": false, "hoverIntent": .int(TabsCore.rowCardDelayMs),
                    "menu": [["id": "open", "title": "Open", "icon": "sf:arrow.up.right.square"], ["id": "copy", "title": "Copy Link", "icon": "sf:link"],
                             ["separator": true], ["id": "done", "title": "Mark as Done", "icon": "sf:checkmark"]]]
    if !seen.contains(k) { v.put("unread", true) }
    return v
  }

  struct Stack {
    var key: String
    var title: String
    var members: [String]  // bottom (the PR on the default branch) first
  }

  /// Chains of open PRs in one repository where each one's base is the previous one's head.
  static func stacks(_ list: [Value]) -> [Stack] {
    var out: [Stack] = []
    var repos: [String] = []
    for it in list where !it.s("head").isEmpty && !repos.contains(it.s("where")) { repos.append(it.s("where")) }
    for repo in repos {
      let prs = list.filter { $0.s("where") == repo && !$0.s("head").isEmpty }
      func parent(_ it: Value) -> Value? { prs.first { $0.s("head") == it.s("base") && $0.s("id") != it.s("id") } }
      func children(_ it: Value) -> [Value] {
        prs.filter { $0.s("base") == it.s("head") && $0.s("id") != it.s("id") }.sorted { $0.s("id") < $1.s("id") }
      }
      for root in prs where parent(root) == nil {
        var members: [String] = []
        var queue = [root]
        while let cur = queue.first, members.count < 20 {
          queue.removeFirst()
          if members.contains(cur.s("id")) { continue }
          members.append(cur.s("id"))
          queue += children(cur)
        }
        if members.count > 1 {
          let name = Array(repo.utf8).split(separator: 47).last.map { String(decoding: $0, as: UTF8.self) } ?? repo
          out.append(Stack(key: root.s("id"), title: name, members: members))
        }
      }
    }
    return out
  }

  // MARK: Actions

  /// Handles live folder rows, stacks, the done chip and live-only menu items. Returns false for
  /// anything TabsCore handles itself (toggle, rename, delete, reorder of the folder).
  func action(_ id: String, _ action: String, _ value: Value) -> Bool {
    if Text.hasPrefix(id, "livestack:") {
      let rest = split(Text.dropPrefix(id, "livestack:"))
      guard let (fid, sk) = rest, action == "toggle" else { return true }
      var closed = strings(fid, "closed")
      if closed.contains(sk) { closed.removeAll { $0 == sk } } else { closed.append(sk) }
      setStrings(fid, "closed", closed)
      save()
      rerender()
      return true
    }
    if Text.hasPrefix(id, "live:") {
      guard let (fid, key) = split(Text.dropPrefix(id, "live:")), let f = core.folders[fid] else { return true }
      if key == "connect" {
        if action == "click" {
          
            env.call("connections", "connect", ["id": .string(f.live)])
          }
        }
        return true
      }
      guard let it = (items[f.live] ?? []).first(where: { $0.s("id") == key }) else { return true }
      switch action {
      case "click": open(fid, it)
      case "close": markDone(fid, it)
      case "hover":
        env.call("previews", "show", ["anchor": .string(id), "url": it["url"], "title": it["title"], "icon": .string(icon(it)),
                                      "kind": "live", "place": "trailing"])
      case "menu":
        switch value.string ?? "" {
        case "open": open(fid, it)
        case "copy":
          env.call("app", "copy", ["text": it["url"]])
          env.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": .string(Copied.link(it.s("url"))), "icon": "sf:link"]])
        case "done": markDone(fid, it)
        default: break
        }
      default: break
      }
      return true
    }
    if Text.hasPrefix(id, Self.donePopover) {
      if action == "dismiss" { closePopover() }
      return true
    }
    if Text.hasPrefix(id, "live.done:") {
      guard let (fid, key) = split(Text.dropPrefix(id, "live.done:")) else { return true }
      if action == "click" { restore(fid, key) }
      return true
    }
    if Text.hasPrefix(id, "live.doneClear:") {
      let fid = Text.dropPrefix(id, "live.doneClear:")
      var s = state[fid] ?? [:]
      s.put("done", [])
      state[fid] = s
      save()
      closePopover()
      rerender()
      return true
    }
    guard let f = core.folders[id], !f.live.isEmpty else { return false }
    switch action {
    case "badge":
      showDone(f)
      return true
    case "hover":
      return true  // the rows are the preview
    case "menu":
      switch value.string ?? "" {
      case "liveRefresh":
        refresh()
        return true
      case "liveRead":
        setStrings(f.id, "seen", visible(f.id, f.live).map { $0.s("id") })
        save()
        rerender()
        return true
      default: return false
      }
    default: return false
    }
  }

  /// "folder-3:github:acme/web#12" -> ("folder-3", "github:acme/web#12").
  func split(_ s: String) -> (String, String)? {
    let b = Array(s.utf8)
    guard let colon = b.firstIndex(of: 58) else { return nil }
    return (String(decoding: b[..<colon], as: UTF8.self), String(decoding: b[(colon + 1)...], as: UTF8.self))
  }

  func open(_ fid: String, _ it: Value) {
    var seen = strings(fid, "seen")
    if !seen.contains(it.s("id")) { seen.append(it.s("id")) }
    setStrings(fid, "seen", seen)
    save()
    let url = it.s("url")
    // The PR is already open in this space: go to it rather than open it twice.
    if let t = core.tabs.values.first(where: { URLs.normalize($0.url) == URLs.normalize(url) && core.spaceOf($0.id) == core.currentSpace }) {
      core.select(t.id)
    } else {
      _ = core.open(url, space: core.currentSpace, kind: "today", background: false, index: nil)
    }
    rerender()
  }

  func markDone(_ fid: String, _ it: Value) {
    var s = state[fid] ?? [:]
    var done = s.a("done")
    done.removeAll { $0.s("key") == it.s("id") }
    done.insert(["key": it["id"], "title": it["title"], "url": it["url"], "icon": .string(icon(it)), "at": .int(env.now())], at: 0)
    s.put("done", .array(Array(done.prefix(Self.maxDone))))
    state[fid] = s
    var dismissed = strings(fid, "dismissed")
    if !dismissed.contains(it.s("id")) { dismissed.append(it.s("id")) }
    setStrings(fid, "dismissed", dismissed)
    save()
    rerender()
  }

  func restore(_ fid: String, _ key: String) {
    var s = state[fid] ?? [:]
    let done = s.a("done")
    guard let d = done.first(where: { $0.s("key") == key }) else { return }
    s.put("done", .array(done.filter { $0.s("key") != key }))
    state[fid] = s
    setStrings(fid, "dismissed", strings(fid, "dismissed").filter { $0 != key })
    save()
    if !d.s("url").isEmpty { _ = core.open(d.s("url"), space: core.currentSpace, kind: "today", background: false, index: nil) }
    if let f = core.folders[fid], !(state[fid]?.a("done").isEmpty ?? true) { showDone(f) } else { closePopover() }
    rerender()
  }

  /// The "N ✓" chip's Recently Closed popover.
  func showDone(_ f: TabsCore.Folder) {
    let now = env.now()
    let rows: [Value] = (state[f.id]?.a("done") ?? []).map { d in
      ["type": "valueRow", "id": .string("live.done:" + f.id + ":" + d.s("key")), "title": d["title"], "subtitle": .string("Done " + Web.ago(d.i("at"), now: now) + " ago"),
       "icon": d["icon"], "buttons": [["id": "restore", "icon": "sf:arrow.uturn.backward"]]]
    }
    popoverFor = f.id
    env.call("ui", "set", ["slot": "popover", "tree": [
      "type": "panel", "id": .string(Self.donePopover + f.id), "anchor": .string(f.id), "width": 320, "icon": "sf:checkmark.circle", "tone": "secondary",
      "title": "Recently Closed", "subtitle": .string("Done in " + f.title + ". Reopen one to bring it back."),
      "children": [
        ["type": "section", "id": "live.done.list", "title": "", "children": .array(rows)],
        ["type": "buttonRow", "id": "live.done.buttons", "children": [
          ["type": "actionButton", "id": .string("live.doneClear:" + f.id), "title": "Clear", "style": "secondary"],
        ]],
      ],
    ]])
  }

  func closePopover() {
    guard !popoverFor.isEmpty else { return }
    popoverFor = ""
    env.call("ui", "set", ["slot": "popover", "tree": nil])
  }

  // MARK: Commands

  func command(_ id: String) {
    guard Text.hasPrefix(id, "tabs.liveNew:") else { return }
    create(Text.dropPrefix(id, "tabs.liveNew:"))
  }

  /// A new live folder at the top of the current space's pinned tabs.
  @discardableResult
  func create(_ source: String, space: String? = nil) -> String? {
    guard let src = Self.source(source) else { return nil }
    let sid = space ?? core.currentSpace
    let fid = core.newId("folder-")
    core.checkpoint()
    core.folders[fid] = TabsCore.Folder(id: fid, spaceId: sid, title: src.title, open: true, children: [], live: source)
    var list = core.pinned[sid] ?? []
    list.insert(fid, at: 0)
    core.pinned[sid] = list
    state[fid] = [:]
    // The feed already in memory primes it at once; otherwise the next refresh does.
    if let current = items[source] {
      state[fid] = ["primed": true, "seen": .array(current.map { $0["id"] })]
    }
    save()
    core.changed(sid)
    env.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "icon": "sf:bolt.fill",
                                                   "text": .string(src.title + " live folder: review requests, your pull requests, failing CI and mentions show up here and update on their own.")]])
    if items[source] == nil { refresh() }
    return fid
  }

  /// "New GitHub Live Folder" while that source is connected. `commands` may load later.
  func registerCommands() {
    var want: [(String, String, String)] = []
    for s in Self.sources {
      let isConnected = connected(s.id)
      guard isConnected else { continue }
      want.append(("tabs.liveNew:" + s.id, "New " + s.title + " Live Folder", s.icon))
    }
    for id in registered where !want.contains(where: { $0.0 == id }) { env.call("commands", "unregister", ["id": .string(id)]) }
    registered.removeAll { id in !want.contains { $0.0 == id } }
    for w in want where !registered.contains(w.0) {
      let r = env.call("commands", "register", ["id": .string(w.0), "title": .string(w.1), "icon": .string(w.2), "owner": "tabs",
                                                  "keywords": ["live folder", "folder", "pull requests", "github", "prs", "reviews"]])
      if r.isErr {
        guard !retrying, registerAttempts < 60 else { return }
        retrying = true
        env.timer(500, false) { [self] in
          retrying = false
          registerAttempts += 1
          registerCommands()
        }
        return
      }
      registered.append(w.0)
    }
  }
}