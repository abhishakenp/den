// The `tabs` service: favorites, pinned tabs and folders, today tabs, the archive, undo, idle
// archiving and suspension, the sidebar header/favorites/pinned/today slots and the tab
// shortcuts. See docs/plugin-services.md and docs/research/arc.md §2-§4.

#if !hasFeature(Embedded)
  import CordisValue
#endif

final class TabsCore {
  struct Tab {
    var id: String
    var title: String
    var customTitle: String?
    var url: String
    var pinnedUrl: String?
    var favicon: String?
    var lastActive: Int64
    var audio = false

    var displayTitle: String {
      if let c = customTitle, !c.isEmpty { return c }
      return title.isEmpty ? URLs.display(url) : title
    }
    var icon: String { favicon ?? URLs.favicon(url) }
    var drift: Bool { URLs.drifted(url: url, pinned: pinnedUrl) }

    var value: Value {
      ["id": .string(id), "title": .string(title), "customTitle": .str(customTitle), "url": .string(url),
       "pinnedUrl": .str(pinnedUrl), "favicon": .str(favicon), "lastActive": .int(lastActive)]
    }

    init(id: String, title: String, url: String, pinnedUrl: String? = nil, favicon: String? = nil, lastActive: Int64) {
      self.id = id
      self.title = title
      self.url = url
      self.pinnedUrl = pinnedUrl
      self.favicon = favicon
      self.lastActive = lastActive
    }

    init?(_ v: Value) {
      guard let id = v["id"].string else { return nil }
      self.init(id: id, title: v.s("title"), url: v.s("url"), pinnedUrl: v.sOpt("pinnedUrl"), favicon: v.sOpt("favicon"), lastActive: v.i("lastActive"))
      customTitle = v.sOpt("customTitle")
    }
  }

  struct Folder {
    var id: String
    var spaceId: String
    var title: String
    var open: Bool
    var children: [String]

    var value: Value {
      ["id": .string(id), "spaceId": .string(spaceId), "title": .string(title), "open": .bool(open), "children": .array(children.map { .string($0) })]
    }
  }

  /// Where a tab or folder lives. Favorites are shared by every space.
  enum Box: Equatable {
    case favorites
    case pinned(String)  // space id
    case folder(String)  // folder id
    case today(String)  // space id
  }

  static let ns = "tabs"
  static let maxFavorites = 12
  static let defaultArchiveAfterMs: Int64 = 12 * 3_600_000  // Arc's default: 12 hours
  static let defaultSuspendAfterMs: Int64 = 30 * 60_000  // den's choice: 30 minutes
  static let tickMs: UInt64 = 60_000

  let env: PluginEnv

  // State (persisted)
  var tabs: [String: Tab] = [:]
  var folders: [String: Folder] = [:]
  var favorites: [String] = []
  var pinned: [String: [String]] = [:]
  var today: [String: [String]] = [:]
  var selected: [String: String] = [:]  // space id -> tab id
  var archive: [Value] = []  // newest first: {id, title, url, favicon, closedAt, spaceId}
  var mru: [String] = []  // tab ids, most recent first
  var nextId: Int64 = 1
  var archiveAfterMs = TabsCore.defaultArchiveAfterMs
  var suspendAfterMs = TabsCore.defaultSuspendAfterMs

  // Runtime
  var spaces: [Value] = []  // cached spaces.list
  var currentSpace = ""
  var undoStack: [(state: Value, tabIds: [String])] = []
  var saveScheduled = false
  var dirty = false
  var shown = ""  // tab id currently in the content area

  init(env: PluginEnv) { self.env = env }

  // MARK: - Lifecycle

  func start() {
    refreshSpaces()
    currentSpace = env.call("spaces", "current").s("id")
    load()
    for t in tabs.values { ensureWebview(t.id) }
    bindKeys()
    subscribe()
    renderAll()
    showSelected()
    tick()
    env.timer(Self.tickMs, true) { [self] in tick() }
    for u in env.call("app", "pendingURLs").array ?? [] {
      if let s = u.string { _ = open(s, space: currentSpace, kind: "today", background: false, index: nil) }
    }
  }

  /// Called from the plugin's dispose (hot reload, unload): flush a pending save.
  func stop() {
    if dirty { save() }
  }

  func refreshSpaces() { spaces = env.call("spaces", "list").array ?? [] }
  var spaceIds: [String] { spaces.map { $0.s("id") } }
  func pageIndex(_ sid: String) -> Int? { spaceIds.firstIndex(of: sid) }
  func spaceName(_ sid: String) -> String { spaces.first { $0.s("id") == sid }?.s("name") ?? "Space" }
  func profile(_ sid: String?) -> String {
    guard let sid else { return "default" }
    return spaces.first { $0.s("id") == sid }?.sOpt("profile") ?? "default"
  }

  // MARK: - Persistence

  func stateValue() -> Value {
    var spaceStates: [Value] = []
    var ids = Set(pinned.keys)
    for k in today.keys { ids.insert(k) }
    for k in selected.keys { ids.insert(k) }
    for sid in ids.sorted() {
      spaceStates.append([
        "id": .string(sid), "pinned": .array((pinned[sid] ?? []).map { .string($0) }),
        "today": .array((today[sid] ?? []).map { .string($0) }), "selected": .str(selected[sid]),
      ])
    }
    return [
      "version": 1, "nextId": .int(nextId),
      "tabs": .array(tabs.keys.sorted().map { tabs[$0]!.value }),
      "folders": .array(folders.keys.sorted().map { folders[$0]!.value }),
      "favorites": .array(favorites.map { .string($0) }),
      "spaces": .array(spaceStates),
      "archive": .array(archive),
      "mru": .array(mru.map { .string($0) }),
    ]
  }

  func apply(state v: Value) {
    tabs = [:]
    folders = [:]
    pinned = [:]
    today = [:]
    selected = [:]
    for t in v.a("tabs") { if let tab = Tab(t) { tabs[tab.id] = tab } }
    for f in v.a("folders") {
      guard let id = f["id"].string else { continue }
      folders[id] = Folder(id: id, spaceId: f.s("spaceId"), title: f.s("title"), open: f.b("open", true), children: f.a("children").compactMap { $0.string })
    }
    favorites = v.a("favorites").compactMap { $0.string }
    for s in v.a("spaces") {
      let sid = s.s("id")
      pinned[sid] = s.a("pinned").compactMap { $0.string }
      today[sid] = s.a("today").compactMap { $0.string }
      if let sel = s.sOpt("selected") { selected[sid] = sel }
    }
    archive = v.a("archive")
    mru = v.a("mru").compactMap { $0.string }
    nextId = max(nextId, v.i("nextId", 1))
  }

  func load() {
    let settings = env.call("storage", "get", ["ns": .string(Self.ns), "key": "settings"])
    if let a = settings["archiveAfterMs"].int { archiveAfterMs = a }
    if let s = settings["suspendAfterMs"].int { suspendAfterMs = s }
    let state = env.call("storage", "get", ["ns": .string(Self.ns), "key": "state"])
    if state.isNull || state.isErr {
      seed()
      save()
    } else {
      apply(state: state)
    }
    for sid in spaceIds {
      if pinned[sid] == nil { pinned[sid] = [] }
      if today[sid] == nil { today[sid] = [] }
    }
    // Drop dangling references so a bad state file can never wedge the plugin.
    favorites = favorites.filter { tabs[$0] != nil }
    for (k, v) in pinned { pinned[k] = v.filter { tabs[$0] != nil || folders[$0] != nil } }
    for (k, v) in today { today[k] = v.filter { tabs[$0] != nil } }
    for (k, f) in folders { folders[k]!.children = f.children.filter { tabs[$0] != nil || folders[$0] != nil } }
    for (sid, id) in selected where tabs[id] == nil { selected[sid] = nil }
  }

  func save() {
    dirty = false
    env.call("storage", "set", ["ns": .string(Self.ns), "key": "state", "value": stateValue()])
  }

  /// Coalesces the many page events (title, favicon, url) into one write.
  func saveSoon() {
    dirty = true
    guard !saveScheduled else { return }
    saveScheduled = true
    env.timer(400, false) { [self] in
      saveScheduled = false
      if dirty { save() }
    }
  }

  func newId(_ prefix: String) -> String {
    defer { nextId += 1 }
    return prefix + String(nextId)
  }

  // MARK: - Seed (first run)

  func seed() {
    let now = env.now()
    func tab(_ title: String, _ url: String, pinnedUrl: Bool, favicon: String? = nil) -> String {
      let id = newId("tab-")
      tabs[id] = Tab(id: id, title: title, url: url, pinnedUrl: pinnedUrl ? url : nil, favicon: favicon, lastActive: now)
      return id
    }
    favorites = [
      tab("GitHub", "https://github.com", pinnedUrl: true),
      tab("Gmail", "https://mail.google.com", pinnedUrl: true, favicon: "https://ssl.gstatic.com/ui/v1/icons/mail/rfr/gmail.ico"),
      tab("Calendar", "https://calendar.google.com", pinnedUrl: true, favicon: "https://calendar.google.com/googlecalendar/images/favicons_2020q4/calendar_31.ico"),
      tab("YouTube", "https://www.youtube.com", pinnedUrl: true),
    ]
    let ids = spaceIds
    if ids.count > 0 {
      let s = ids[0]
      let folder = newId("folder-")
      folders[folder] = Folder(id: folder, spaceId: s, title: "Reading", open: true, children: [tab("The Swift Programming Language", "https://docs.swift.org/swift-book/", pinnedUrl: true)])
      pinned[s] = [
        tab("Apple Developer Documentation", "https://developer.apple.com/documentation", pinnedUrl: true),
        tab("Linear", "https://linear.app", pinnedUrl: true),
        folder,
      ]
      today[s] = [
        tab("Arc (web browser) - Wikipedia", "https://en.wikipedia.org/wiki/Arc_(web_browser)", pinnedUrl: false),
        tab("Hacker News", "https://news.ycombinator.com", pinnedUrl: false),
        tab("WebKit Blog", "https://webkit.org/blog/", pinnedUrl: false),
        tab("The Verge", "https://www.theverge.com", pinnedUrl: false),
      ]
      selected[s] = today[s]![0]
    }
    if ids.count > 1 {
      let s = ids[1]
      pinned[s] = [tab("Linear — My Issues", "https://linear.app", pinnedUrl: true), tab("Figma", "https://www.figma.com", pinnedUrl: true)]
      today[s] = [tab("Swift.org", "https://www.swift.org", pinnedUrl: false), tab("MDN Web Docs", "https://developer.mozilla.org", pinnedUrl: false)]
      selected[s] = today[s]![0]
    }
    if ids.count > 2 {
      let s = ids[2]
      pinned[s] = [tab("abhishakenp/den", "https://github.com/abhishakenp/den", pinnedUrl: true)]
      today[s] = [tab("Example Domain", "https://example.com", pinnedUrl: false)]
      selected[s] = today[s]![0]
    }
  }

  // MARK: - Locating

  func ids(_ b: Box) -> [String] {
    switch b {
    case .favorites: return favorites
    case let .pinned(s): return pinned[s] ?? []
    case let .folder(f): return folders[f]?.children ?? []
    case let .today(s): return today[s] ?? []
    }
  }

  func setIds(_ b: Box, _ v: [String]) {
    switch b {
    case .favorites: favorites = v
    case let .pinned(s): pinned[s] = v
    case let .folder(f): folders[f]?.children = v
    case let .today(s): today[s] = v
    }
  }

  func locate(_ id: String) -> (Box, Int)? {
    if let i = favorites.firstIndex(of: id) { return (.favorites, i) }
    for (s, list) in pinned { if let i = list.firstIndex(of: id) { return (.pinned(s), i) } }
    for (s, list) in today { if let i = list.firstIndex(of: id) { return (.today(s), i) } }
    for (f, folder) in folders { if let i = folder.children.firstIndex(of: id) { return (.folder(f), i) } }
    return nil
  }

  func space(of b: Box) -> String? {
    switch b {
    case .favorites: return nil
    case let .pinned(s), let .today(s): return s
    case let .folder(f): return folders[f]?.spaceId
    }
  }

  func kind(of b: Box) -> String {
    switch b {
    case .favorites: return "favorite"
    case .pinned, .folder: return "pinned"
    case .today: return "today"
    }
  }

  func spaceOf(_ id: String) -> String? { locate(id).flatMap { space(of: $0.0) } }
  func kindOf(_ id: String) -> String { locate(id).map { kind(of: $0.0) } ?? "today" }

  /// Tab ids inside a folder, depth first.
  func tabsIn(folder f: String) -> [String] {
    var out: [String] = []
    for c in folders[f]?.children ?? [] {
      if folders[c] != nil { out += tabsIn(folder: c) } else { out.append(c) }
    }
    return out
  }

  /// Sidebar order for a space: favorites, pinned (folders expanded when open), today.
  func order(_ sid: String, onlyVisible: Bool) -> [String] {
    var out = favorites
    func walk(_ list: [String]) {
      for id in list {
        if let f = folders[id] {
          if f.open || !onlyVisible { walk(f.children) }
        } else {
          out.append(id)
        }
      }
    }
    walk(pinned[sid] ?? [])
    out += today[sid] ?? []
    return out
  }

  var selectedId: String? { selected[currentSpace] }

  // MARK: - Service

  func handle(_ method: String, _ args: Value) -> Value {
    switch method {
    case "list":
      return list(args.sOpt("spaceId") ?? currentSpace)
    case "selected":
      return selectedId.map { ["id": .string($0)] } ?? .null
    case "open":
      let url = args.s("url")
      guard !url.isEmpty else { return .err("tabs: open needs a url") }
      let kind = args.sOpt("kind") ?? "today"
      guard kind == "today" || kind == "pinned" || kind == "favorite" else { return .err("tabs: bad kind " + kind) }
      if kind == "favorite" && favorites.count >= Self.maxFavorites { return .err("tabs: favorites are full") }
      let id = open(url, space: args.sOpt("spaceId") ?? currentSpace, kind: kind, background: args.b("background"), index: args["index"].int.map { Int($0) })
      return ["id": .string(id)]
    case "select":
      guard tabs[args.s("id")] != nil else { return .err("tabs: no tab '" + args.s("id") + "'") }
      select(args.s("id"))
    case "close":
      guard tabs[args.s("id")] != nil else { return .err("tabs: no tab '" + args.s("id") + "'") }
      close(args.s("id"))
    case "pin", "unpin", "favorite":
      let id = args.s("id")
      guard tabs[id] != nil else { return .err("tabs: no tab '" + id + "'") }
      if method == "favorite" && favorites.count >= Self.maxFavorites && kindOf(id) != "favorite" { return .err("tabs: favorites are full") }
      setKind(id, method == "pin" ? "pinned" : method == "unpin" ? "today" : "favorite", toast: false)
    case "move":
      return move(args)
    case "reset":
      guard tabs[args.s("id")] != nil else { return .err("tabs: no tab '" + args.s("id") + "'") }
      reset(args.s("id"))
    case "duplicate":
      guard tabs[args.s("id")] != nil else { return .err("tabs: no tab '" + args.s("id") + "'") }
      return ["id": .string(duplicate(args.s("id")))]
    case "rename":
      let id = args.s("id")
      guard tabs[id] != nil || folders[id] != nil else { return .err("tabs: no tab '" + id + "'") }
      rename(id, args.s("title"))
    case "navigate":
      guard let id = args.sOpt("id") ?? selectedId, tabs[id] != nil else { return .err("tabs: no tab to navigate") }
      let r = env.call("webviews", "navigate", ["id": .string(id), "url": args["url"]])
      if r.isErr { return r }
      tabs[id]?.url = env.call("webviews", "get", ["id": .string(id)]).s("url")
      changed(spaceOf(id))
    case "clearToday":
      clearToday(args.sOpt("spaceId") ?? currentSpace)
    case "undo":
      guard undo() else { return .err("tabs: nothing to undo") }
    case "archive":
      return .array(archive)
    case "restore":
      guard let id = restore(args.s("id")) else { return .err("tabs: no archived tab '" + args.s("id") + "'") }
      return ["id": .string(id)]
    case "createFolder":
      let tabIds = args.a("tabIds").compactMap { $0.string }.filter { tabs[$0] != nil }
      return ["id": .string(createFolder(space: args.sOpt("spaceId") ?? currentSpace, title: args.sOpt("title"), tabIds: tabIds))]
    case "deleteFolder":
      guard folders[args.s("id")] != nil else { return .err("tabs: no folder '" + args.s("id") + "'") }
      deleteFolder(args.s("id"))
    case "settings":
      if let a = args["archiveAfterMs"].int { archiveAfterMs = max(0, a) }
      if let s = args["suspendAfterMs"].int { suspendAfterMs = max(0, s) }
      let v: Value = ["archiveAfterMs": .int(archiveAfterMs), "suspendAfterMs": .int(suspendAfterMs)]
      if !args.isNull { env.call("storage", "set", ["ns": .string(Self.ns), "key": "settings", "value": v]) }
      return v
    default:
      return .err("tabs: unknown method " + method)
    }
    return .okay
  }

  func tabValue(_ id: String) -> Value {
    guard let t = tabs[id] else { return .null }
    let loc = locate(id)
    var folderId: Value = .null
    if let (b, _) = loc, case let .folder(f) = b { folderId = .string(f) }
    return [
      "id": .string(id), "spaceId": .str(loc.flatMap { space(of: $0.0) }), "kind": .string(loc.map { kind(of: $0.0) } ?? "today"),
      "folderId": folderId, "title": .string(t.displayTitle), "customTitle": .str(t.customTitle), "url": .string(t.url),
      "pinnedUrl": .str(t.pinnedUrl), "favicon": .str(t.favicon), "webviewId": .string(id), "lastActive": .int(t.lastActive),
      "audio": .bool(t.audio),
    ]
  }

  func list(_ sid: String) -> Value {
    func item(_ id: String) -> Value {
      if let f = folders[id] {
        return ["id": .string(id), "folder": true, "title": .string(f.title), "open": .bool(f.open), "children": .array(f.children.map { item($0) })]
      }
      return tabValue(id)
    }
    return [
      "favorites": .array(favorites.map { tabValue($0) }),
      "pinned": .array((pinned[sid] ?? []).map { item($0) }),
      "today": .array((today[sid] ?? []).map { tabValue($0) }),
    ]
  }

  // MARK: - Undo

  func checkpoint() {
    undoStack.append((stateValue(), Array(tabs.keys)))
    if undoStack.count > 30 { undoStack.removeFirst() }
  }

  func undo() -> Bool {
    guard let snap = undoStack.popLast() else { return false }
    apply(state: snap.state)
    for sid in spaceIds {
      if pinned[sid] == nil { pinned[sid] = [] }
      if today[sid] == nil { today[sid] = [] }
    }
    for id in tabs.keys { ensureWebview(id) }
    collectWebviews()
    save()
    renderAll()
    showSelected()
    env.emit("tabs.changed", ["spaceId": .string(currentSpace)])
    return true
  }

  /// Closes tab webviews that neither the state nor the newest undo step refers to.
  func collectWebviews() {
    var keep = Set(tabs.keys)
    if let top = undoStack.last { for id in top.tabIds { keep.insert(id) } }
    for v in env.call("webviews", "list").array ?? [] {
      guard let id = v.string, Text.hasPrefix(id, "tab-"), !keep.contains(id) else { continue }
      env.call("webviews", "close", ["id": .string(id)])
    }
  }

  // MARK: - Mutations

  func ensureWebview(_ id: String) {
    guard let t = tabs[id] else { return }
    let r = env.call("webviews", "create", ["id": .string(id), "url": .string(t.url), "profile": .string(profile(spaceOf(id)))])
    if r.isErr {
      // It already exists (plugin reload): the live page is newer than our saved copy.
      let st = env.call("webviews", "get", ["id": .string(id)])
      if !st.isErr {
        if !st.s("url").isEmpty && st.s("url") != "about:blank" { tabs[id]?.url = st.s("url") }
        if !st.s("title").isEmpty { tabs[id]?.title = st.s("title") }
        if !st.s("favicon").isEmpty { tabs[id]?.favicon = st.s("favicon") }
        tabs[id]?.audio = st.b("audio")
      }
    }
  }

  func open(_ url: String, space sid: String, kind: String, background: Bool, index: Int?) -> String {
    let id = newId("tab-")
    let t = Tab(id: id, title: URLs.display(url), url: url, pinnedUrl: kind == "today" ? nil : url, lastActive: env.now())
    tabs[id] = t
    let box: Box = kind == "favorite" ? .favorites : kind == "pinned" ? .pinned(sid) : .today(sid)
    var list = ids(box)
    let at = index ?? (kind == "today" ? 0 : list.count)
    list.insert(id, at: max(0, min(at, list.count)))
    setIds(box, list)
    ensureWebview(id)
    tabs[id]?.url = env.call("webviews", "get", ["id": .string(id)]).sOpt("url") ?? url
    env.emit("tabs.opened", ["id": .string(id)])
    if background {
      changed(kind == "favorite" ? nil : sid)
    } else {
      select(id)
    }
    return id
  }

  func select(_ id: String) {
    guard tabs[id] != nil else { return }
    let sid = spaceOf(id) ?? currentSpace
    let previous = selectedId
    let now = env.now()
    if let p = previous { tabs[p]?.lastActive = now }
    tabs[id]?.lastActive = now
    mru.removeAll { $0 == id }
    mru.insert(id, at: 0)
    if mru.count > 50 { mru.removeLast() }
    selected[sid] = id
    // Reveal a tab inside a closed folder.
    if let (b, _) = locate(id), case let .folder(f) = b, folders[f]?.open == false { folders[f]?.open = true }
    if sid != currentSpace {
      // spaces.current comes back through our listener and shows the tab.
      env.call("spaces", "switch", ["id": .string(sid)])
      if currentSpace != sid {
        currentSpace = sid
        showSelected()
      }
    } else {
      showSelected()
    }
    renderPage(sid)
    saveSoon()
    env.emit("tabs.selected", ["id": .string(id), "previous": .str(previous)])
  }

  /// Picks what to show after `id` leaves `sid`'s selection.
  func replacement(for id: String, in sid: String) -> String? {
    if let list = today[sid], let i = list.firstIndex(of: id) {
      if i + 1 < list.count { return list[i + 1] }
      if i > 0 { return list[i - 1] }
    }
    let visible = Set(order(sid, onlyVisible: false))
    return mru.first { $0 != id && visible.contains($0) && tabs[$0] != nil }
  }

  func archiveEntry(_ id: String, space sid: String?) -> Value {
    let t = tabs[id]!
    return ["id": .string(id), "title": .string(t.displayTitle), "url": .string(t.url), "favicon": .string(t.icon),
            "closedAt": .int(env.now()), "spaceId": .str(sid)]
  }

  /// Moves a tab into the archive (webview suspended; collected later).
  func archiveTab(_ id: String, space sid: String?) {
    guard tabs[id] != nil, let (b, i) = locate(id) else { return }
    archive.insert(archiveEntry(id, space: sid), at: 0)
    if archive.count > 500 { archive.removeLast() }
    var list = ids(b)
    list.remove(at: i)
    setIds(b, list)
    tabs[id] = nil
    mru.removeAll { $0 == id }
    env.call("webviews", "suspend", ["id": .string(id)])
    env.emit("tabs.closed", ["id": .string(id)])
  }

  func close(_ id: String) {
    guard tabs[id] != nil else { return }
    let sid = spaceOf(id) ?? currentSpace
    let wasSelected = selectedId == id || selected[sid] == id
    let next = wasSelected ? replacement(for: id, in: sid) : nil
    if kindOf(id) == "today" {
      checkpoint()
      archiveTab(id, space: sid)
      collectWebviews()
    } else {
      // Pinned tabs and favorites are only unloaded.
      tabs[id]?.lastActive = env.now()
      env.call("webviews", "suspend", ["id": .string(id)])
    }
    if wasSelected {
      selected[sid] = nil
      if let n = next { select(n) } else { showSelected() }
    }
    changed(sid)
  }

  func setKind(_ id: String, _ kind: String, toast: Bool) {
    guard let (b, _) = locate(id) else { return }
    let sid = space(of: b) ?? currentSpace
    if kind == self.kind(of: b) { return }
    checkpoint()
    let target: Box = kind == "favorite" ? .favorites : kind == "pinned" ? .pinned(sid) : .today(sid)
    place(id, target, index: kind == "today" ? 0 : nil)
    if toast {
      let text = kind == "today" ? "Un-Pinned Tab from " + spaceName(sid) : kind == "pinned" ? "Pinned Tab to " + spaceName(sid) : "Added to Favorites"
      env.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": .string(text), "icon": "sf:pin.fill"]])
    }
  }

  /// Moves an item into `box`, fixing pinned URLs and selection. No checkpoint.
  func place(_ id: String, _ box: Box, index: Int?) {
    guard let (from, i) = locate(id) else { return }
    let oldSpace = space(of: from)
    var src = ids(from)
    src.remove(at: i)
    setIds(from, src)
    var dst = ids(box)
    let at = max(0, min(index ?? dst.count, dst.count))
    dst.insert(id, at: at)
    setIds(box, dst)
    let newSpace = space(of: box)
    if var t = tabs[id] {
      switch kind(of: box) {
      case "today": t.pinnedUrl = nil
      default: if t.pinnedUrl == nil { t.pinnedUrl = t.url }
      }
      tabs[id] = t
    }
    if let f = folders[id], let ns = newSpace, f.spaceId != ns { retag(folder: id, space: ns) }
    if let os = oldSpace, os != newSpace, selected[os] == id {
      selected[os] = nil
      if let ns = newSpace { selected[ns] = id } else { selected[os] = id }  // a new favorite stays selected
      if os == currentSpace && selected[os] == nil { if let n = replacement(for: id, in: os) { selected[os] = n } }
    }
    save()
    renderAll()
    showSelected()
    env.emit("tabs.changed", ["spaceId": .str(newSpace ?? oldSpace)])
  }

  func retag(folder f: String, space sid: String) {
    folders[f]?.spaceId = sid
    for c in folders[f]?.children ?? [] where folders[c] != nil { retag(folder: c, space: sid) }
  }

  func move(_ args: Value) -> Value {
    let id = args.s("id")
    guard let (from, _) = locate(id) else { return .err("tabs: no tab '" + id + "'") }
    let curKind = kind(of: from)
    let kind = args.sOpt("kind") ?? curKind
    let sid = args.sOpt("spaceId") ?? space(of: from) ?? currentSpace
    if let s = args.sOpt("spaceId"), pageIndex(s) == nil { return .err("tabs: no space '" + s + "'") }
    let box: Box
    if let f = args.sOpt("folderId") {
      guard folders[f] != nil else { return .err("tabs: no folder '" + f + "'") }
      if f == id || (folders[id] != nil && tabsIn(folder: id).isEmpty == false && contains(folder: id, f)) { return .err("tabs: cannot move a folder into itself") }
      box = .folder(f)
    } else if kind == "favorite" {
      guard folders[id] == nil else { return .err("tabs: folders cannot be favorites") }
      if curKind != "favorite" && favorites.count >= Self.maxFavorites { return .err("tabs: favorites are full") }
      box = .favorites
    } else if kind == "pinned" {
      box = .pinned(sid)
    } else if kind == "today" {
      guard folders[id] == nil else { return .err("tabs: folders live in the pinned section") }
      box = .today(sid)
    } else {
      return .err("tabs: bad kind " + kind)
    }
    checkpoint()
    place(id, box, index: args["index"].int.map { Int($0) } ?? (kind == "today" && box != from ? 0 : nil))
    collectWebviews()
    return .okay
  }

  func contains(folder f: String, _ other: String) -> Bool {
    for c in folders[f]?.children ?? [] {
      if c == other { return true }
      if folders[c] != nil && contains(folder: c, other) { return true }
    }
    return false
  }

  func reset(_ id: String) {
    guard let p = tabs[id]?.pinnedUrl else { return }
    env.call("webviews", "navigate", ["id": .string(id), "url": .string(p)])
    tabs[id]?.url = p
    changed(spaceOf(id))
  }

  func duplicate(_ id: String) -> String {
    let t = tabs[id]!
    checkpoint()
    let nid = newId("tab-")
    var copy = t
    copy.id = nid
    copy.lastActive = env.now()
    tabs[nid] = copy
    if let (b, i) = locate(id) {
      var list = ids(b)
      list.insert(nid, at: i + 1)
      setIds(b, list)
    }
    ensureWebview(nid)
    env.emit("tabs.opened", ["id": .string(nid)])
    select(nid)
    changed(spaceOf(nid))
    return nid
  }

  func rename(_ id: String, _ title: String) {
    checkpoint()
    if folders[id] != nil {
      folders[id]?.title = title.isEmpty ? "Untitled" : title
    } else {
      tabs[id]?.customTitle = title.isEmpty ? nil : title
    }
    changed(spaceOf(id) ?? folders[id]?.spaceId)
  }

  func clearToday(_ sid: String) {
    let keep = selected[sid]
    let victims = (today[sid] ?? []).filter { $0 != keep }
    guard !victims.isEmpty else { return }
    checkpoint()
    for id in victims { archiveTab(id, space: sid) }
    collectWebviews()
    changed(sid)
    env.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": "Cleared Tabs! Use ⌃Z to undo.", "icon": "sf:checkmark.circle.fill"]])
  }

  func restore(_ archiveId: String) -> String? {
    guard let i = archive.firstIndex(where: { $0.s("id") == archiveId }) else { return nil }
    let e = archive.remove(at: i)
    var sid = e.s("spaceId")
    if pageIndex(sid) == nil { sid = currentSpace }
    let id = tabs[archiveId] == nil ? archiveId : newId("tab-")
    let icon = e.sOpt("favicon")
    tabs[id] = Tab(id: id, title: e.s("title"), url: e.s("url"), favicon: icon, lastActive: env.now())
    var list = today[sid] ?? []
    list.insert(id, at: 0)
    today[sid] = list
    ensureWebview(id)  // an archived tab whose webview is still suspended keeps its history
    env.emit("tabs.opened", ["id": .string(id)])
    select(id)
    changed(sid)
    return id
  }

  func createFolder(space sid: String, title: String?, tabIds: [String]) -> String {
    checkpoint()
    let fid = newId("folder-")
    var target: Box = .pinned(sid)
    var at: Int? = nil
    if let first = tabIds.first, let (b, i) = locate(first) {
      switch b {
      case .pinned, .folder:
        target = b
        at = i
      default: break
      }
    }
    folders[fid] = Folder(id: fid, spaceId: space(of: target) ?? sid, title: title ?? "New Folder", open: true, children: [])
    var list = ids(target)
    list.insert(fid, at: max(0, min(at ?? list.count, list.count)))
    setIds(target, list)
    for t in tabIds { place(t, .folder(fid), index: nil) }
    changed(sid)
    return fid
  }

  func deleteFolder(_ fid: String) {
    guard let f = folders[fid], let (b, i) = locate(fid) else { return }
    checkpoint()
    let sid = f.spaceId
    for t in tabsIn(folder: fid) {
      if selected[sid] == t { selected[sid] = nil }
      archiveTab(t, space: sid)
    }
    func drop(_ id: String) {
      for c in folders[id]?.children ?? [] where folders[c] != nil { drop(c) }
      folders[id] = nil
    }
    var list = ids(b)
    list.remove(at: i)
    setIds(b, list)
    drop(fid)
    if selected[sid] == nil, let n = mru.first(where: { spaceOf($0) == sid }) { selected[sid] = n }
    collectWebviews()
    changed(sid)
    showSelected()
  }

  func changed(_ sid: String?) {
    saveSoon()
    if let sid { renderPage(sid) }
    renderGlobal()
    env.emit("tabs.changed", ["spaceId": .str(sid)])
  }

  // MARK: - Idle: auto-archive and suspension

  func tick() {
    let now = env.now()
    var archived = 0
    if archiveAfterMs > 0 {
      for sid in spaceIds {
        for id in today[sid] ?? [] where id != selected[sid] {
          guard let t = tabs[id], now - t.lastActive > archiveAfterMs, !t.audio else { continue }
          archiveTab(id, space: sid)
          archived += 1
        }
      }
    }
    if suspendAfterMs > 0 {
      for (id, t) in tabs where id != shown && !t.audio && now - t.lastActive > suspendAfterMs {
        if env.call("webviews", "get", ["id": .string(id)]).b("live") {
          env.call("webviews", "suspend", ["id": .string(id)])
        }
      }
    }
    if archived > 0 {
      undoStack.removeAll()
      collectWebviews()
      save()
      renderAll()
      env.emit("tabs.changed", ["spaceId": .string(currentSpace)])
      env.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": .string("Auto archived " + String(archived) + (archived == 1 ? " tab" : " tabs")), "icon": "sf:archivebox"]])
    }
  }

  // MARK: - Rendering

  func renderAll() {
    for sid in spaceIds { renderPage(sid) }
    renderGlobal()
  }

  func renderGlobal() {
    renderHeader()
    renderFavorites()
  }

  func showSelected() {
    let id = selectedId
    if let p = shown as String?, !p.isEmpty, p != id, tabs[p] != nil { tabs[p]?.lastActive = env.now() }
    shown = id ?? ""
    if let id {
      env.call("content", "show", ["panes": [.string(id)]])
      env.call("window", "setTitle", ["title": .string(tabs[id]?.displayTitle ?? "den")])
    } else {
      env.call("content", "show", ["panes": []])
      env.call("window", "setTitle", ["title": .string(spaceName(currentSpace))])
    }
    renderGlobal()
  }

  func renderHeader() {
    var st: Value = .null
    var text = ""
    if let id = selectedId, let t = tabs[id] {
      st = env.call("webviews", "get", ["id": .string(id)])
      text = URLs.display(t.url)
    }
    env.call("ui", "set", ["slot": "sidebar.header", "tree": ["type": "list", "id": "tabs.header", "spacing": 0, "children": [
      ["type": "navBar", "id": "tabs.nav", "canGoBack": .bool(st.b("canGoBack")), "canGoForward": .bool(st.b("canGoForward")), "loading": .bool(st.b("loading"))],
      ["type": "urlPill", "id": "tabs.url", "text": .string(text), "secure": .bool(Text.hasPrefix(tabs[selectedId ?? ""]?.url ?? "", "https:")),
       "loading": .bool(st.b("loading")), "progress": .double(st["progress"].double ?? 0), "placeholder": "Search or Enter URL…"],
    ]]])
  }

  func renderFavorites() {
    let sel = selectedId
    env.call("ui", "set", ["slot": "sidebar.favorites", "tree": ["type": "grid", "id": "tabs.favorites", "children": .array(favorites.compactMap { id in
      guard let t = tabs[id] else { return nil }
      return ["type": "favoriteTile", "id": .string(id), "icon": .string(t.icon), "title": .string(t.displayTitle), "selected": .bool(id == sel),
              "audio": .bool(t.audio), "menu": .array(menu(for: id, box: .favorites))]
    })]])
  }

  func row(_ id: String, _ sid: String, box: Box) -> Value {
    let t = tabs[id]!
    return ["type": "tabRow", "id": .string(id), "title": .string(t.displayTitle), "icon": .string(t.icon), "selected": .bool(selected[sid] == id),
            "audio": .bool(t.audio), "drift": .bool(kind(of: box) != "today" && t.drift), "menu": .array(menu(for: id, box: box))]
  }

  func node(_ id: String, _ sid: String, parent: Box) -> Value? {
    if let f = folders[id] {
      return ["type": "folder", "id": .string(id), "title": .string(f.title), "icon": "sf:folder", "open": .bool(f.open),
              "children": .array(f.children.compactMap { node($0, sid, parent: .folder(id)) }),
              "menu": [["id": "newFolder", "title": "New Folder Inside", "icon": "sf:folder.badge.plus"],
                       ["separator": true], ["id": "deleteFolder", "title": "Delete Folder…", "icon": "sf:trash"]]]
    }
    guard tabs[id] != nil else { return nil }
    return row(id, sid, box: parent)
  }

  func renderPage(_ sid: String) {
    guard let page = pageIndex(sid) else { return }
    let p: Value = .int(Int64(page))
    env.call("ui", "set", ["slot": "sidebar.pinned", "page": p, "tree": ["type": "list", "id": .string("tabs.pinned:" + sid),
      "children": .array((pinned[sid] ?? []).compactMap { node($0, sid, parent: .pinned(sid)) })]])
    let list = today[sid] ?? []
    var kids: [Value] = [
      list.isEmpty ? ["type": "divider", "id": .string("tabs.divider:" + sid)] : ["type": "divider", "id": .string("tabs.divider:" + sid), "action": "Clear"],
      ["type": "newTabRow", "id": .string("tabs.newtab:" + sid), "title": "New Tab"],
    ]
    kids += list.compactMap { tabs[$0] != nil ? row($0, sid, box: .today(sid)) : nil }
    env.call("ui", "set", ["slot": "sidebar.today", "page": p, "tree": ["type": "list", "id": .string("tabs.today:" + sid), "children": .array(kids)]])
  }

  func menu(for id: String, box: Box) -> [Value] {
    guard let t = tabs[id] else { return [] }
    var m: [Value] = [["id": "copy", "title": "Copy Link", "icon": "sf:link"], ["id": "duplicate", "title": "Duplicate", "icon": "sf:plus.square.on.square"]]
    let k = kind(of: box)
    if k != "today" && t.drift {
      m.append(["id": "reset", "title": "Go Back to Pinned URL", "icon": "sf:arrow.uturn.backward"])
      m.append(["id": "replacePinned", "title": "Replace Pinned URL with Current", "icon": "sf:pin"])
    }
    m.append(["separator": true])
    if k == "today" { m.append(["id": "pin", "title": "Pin Tab", "icon": "sf:pin"]) }
    if k == "pinned" { m.append(["id": "unpin", "title": "Unpin Tab", "icon": "sf:pin.slash"]) }
    if k != "favorite" && favorites.count < Self.maxFavorites { m.append(["id": "favorite", "title": "Add to Favorites", "icon": "sf:star"]) }
    if k == "favorite" { m.append(["id": "unpin", "title": "Remove from Favorites", "icon": "sf:star.slash"]) }
    if k != "favorite" { m.append(["id": "newFolder", "title": "New Folder with Tab", "icon": "sf:folder.badge.plus"]) }
    let here = space(of: box)
    for s in spaces where s.s("id") != here && k != "favorite" {
      m.append(["id": .string("move:" + s.s("id")), "title": .string("Move to " + s.s("name")), "icon": "sf:arrow.right.square"])
    }
    m.append(["separator": true])
    m.append(["id": "close", "title": k == "today" ? "Archive Tab" : "Close Tab", "icon": "sf:xmark"])
    return m
  }

  // MARK: - Input

  func bindKeys() {
    let binds: [(String, String, String, String)] = [
      ("cmd+w", "tabs.key.close", "Archive Tab", "File"),
      ("cmd+shift+t", "tabs.key.reopen", "Restore Last Closed Tab", "File"),
      ("cmd+d", "tabs.key.pin", "Pin/Unpin Tab", "Tabs"),
      ("cmd+shift+k", "tabs.key.clear", "Clear Unpinned Tabs", "Tabs"),
      ("ctrl+tab", "tabs.key.recent", "Switch to Recent Tab", "Tabs"),
      ("cmd+opt+up", "tabs.key.prevTab", "Previous Tab", "Tabs"),
      ("cmd+opt+down", "tabs.key.nextTab", "Next Tab", "Tabs"),
      ("ctrl+z", "tabs.key.undo", "Undo Sidebar Action", "Tabs"),
      ("cmd+[", "tabs.key.back", "Back", "View"),
      ("cmd+]", "tabs.key.forward", "Forward", "View"),
      ("cmd+r", "tabs.key.reload", "Reload Page", "View"),
      ("cmd+.", "tabs.key.stop", "Stop", "View"),
      ("cmd+s", "tabs.key.sidebar", "Show/Hide Sidebar", "View"),
      ("cmd+shift+c", "tabs.key.copy", "Copy URL", "Edit"),
    ]
    for (c, e, t, m) in binds { env.call("keys", "bind", ["chord": .string(c), "event": .string(e), "title": .string(t), "menu": .string(m)]) }
    for n in 1...9 {
      env.call("keys", "bind", ["chord": .string("cmd+" + String(n)), "event": "tabs.key.nth", "title": .string(n == 9 ? "Last Tab" : "Tab " + String(n)),
                                "menu": "Tabs", "payload": .int(Int64(n))])
    }
  }

  func subscribe() {
    env.on("ui.action") { [self] v in action(v.s("id"), v.s("action"), v["value"]) }
    env.on("spaces.current") { [self] v in
      if let p = shownTab() { tabs[p]?.lastActive = env.now() }
      currentSpace = v.s("id")
      showSelected()
    }
    env.on("spaces.changed") { [self] v in spacesChanged(v.a("spaces")) }
    env.on("tabs.key.close") { [self] _ in closeFromKey() }
    env.on("tabs.key.reopen") { [self] _ in if let e = archive.first { _ = restore(e.s("id")) } }
    env.on("tabs.key.pin") { [self] _ in
      guard let id = selectedId else { return }
      setKind(id, kindOf(id) == "today" ? "pinned" : "today", toast: true)
    }
    env.on("tabs.key.clear") { [self] _ in clearToday(currentSpace) }
    env.on("tabs.key.undo") { [self] _ in _ = undo() }
    env.on("tabs.key.recent") { [self] _ in
      if let id = mru.first(where: { $0 != selectedId && tabs[$0] != nil }) { select(id) }
    }
    env.on("tabs.key.nth") { [self] v in
      let list = order(currentSpace, onlyVisible: true)
      let n = Int(v["payload"].int ?? 1)
      guard !list.isEmpty else { return }
      if n == 9 { select(list[list.count - 1]) } else if n - 1 < list.count { select(list[n - 1]) }
    }
    env.on("tabs.key.prevTab") { [self] _ in stepTab(-1) }
    env.on("tabs.key.nextTab") { [self] _ in stepTab(1) }
    env.on("tabs.key.back") { [self] _ in web("back") }
    env.on("tabs.key.forward") { [self] _ in web("forward") }
    env.on("tabs.key.reload") { [self] _ in web("reload") }
    env.on("tabs.key.stop") { [self] _ in web("stop") }
    env.on("tabs.key.sidebar") { [self] _ in env.call("window", "toggleSidebar") }
    env.on("tabs.key.copy") { [self] _ in copyURL() }
    for e in ["webviews.title", "webviews.url", "webviews.favicon", "webviews.progress", "webviews.state", "webviews.audio"] {
      env.on(e) { [self] v in webEvent(e, v) }
    }
    env.on("webviews.newWindow") { [self] v in
      _ = open(v.s("url"), space: spaceOf(v.s("id")) ?? currentSpace, kind: "today", background: false, index: nil)
    }
    env.on("app.openURL") { [self] v in
      for u in v.a("urls") { if let s = u.string { _ = open(s, space: currentSpace, kind: "today", background: false, index: nil) } }
    }
  }

  func shownTab() -> String? { shown.isEmpty ? nil : shown }

  func web(_ method: String) {
    guard let id = selectedId else { return }
    env.call("webviews", method, ["id": .string(id)])
  }

  func stepTab(_ d: Int) {
    let list = order(currentSpace, onlyVisible: true)
    guard !list.isEmpty else { return }
    guard let cur = selectedId, let i = list.firstIndex(of: cur) else {
      select(list[0])
      return
    }
    let j = i + d
    if j >= 0 && j < list.count { select(list[j]) }
  }

  func closeFromKey() {
    // Cmd-W closes the topmost thing: the command bar, a peek, then the tab.
    let overlays = env.call("ui", "get").a("overlays")
    if overlays.contains(where: { $0.string == "overlay.commandBar" }) {
      env.call("commands", "close")
      return
    }
    if !env.call("content", "get")["peek"].isNull, !env.call("peek", "close").isErr { return }
    if let id = selectedId { close(id) }
  }

  func copyURL() {
    guard let id = selectedId, let t = tabs[id] else { return }
    env.call("app", "copy", ["text": .string(t.url)])
    env.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": "Copied Current URL", "icon": "sf:link"]])
  }

  func openCommandBar(_ mode: String) {
    var args: Value = ["mode": .string(mode)]
    if mode == "edit", let id = selectedId, let t = tabs[id] { args.put("query", .string(t.url)) }
    if env.call("commands", "open", args).isErr {
      env.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": "The Command Bar plugin isn't loaded", "icon": "sf:exclamationmark.triangle"]])
    }
  }

  func spacesChanged(_ list: [Value]) {
    let old = spaceIds
    spaces = list
    let now = Set(spaceIds)
    for sid in old where !now.contains(sid) {
      // A deleted space archives everything inside it.
      for id in (today[sid] ?? []) { archiveTab(id, space: sid) }
      for id in pinned[sid] ?? [] {
        if folders[id] != nil { for t in tabsIn(folder: id) { archiveTab(t, space: sid) } } else { archiveTab(id, space: sid) }
      }
      for (fid, f) in folders where f.spaceId == sid { folders[fid] = nil }
      pinned[sid] = nil
      today[sid] = nil
      selected[sid] = nil
      undoStack.removeAll()
    }
    for sid in spaceIds {
      if pinned[sid] == nil { pinned[sid] = [] }
      if today[sid] == nil { today[sid] = [] }
    }
    collectWebviews()
    save()
    renderAll()
  }

  func webEvent(_ e: String, _ v: Value) {
    let id = v.s("id")
    guard tabs[id] != nil else { return }
    let isSelected = id == selectedId
    switch e {
    case "webviews.title":
      tabs[id]?.title = v.s("title")
      if isSelected { env.call("window", "setTitle", ["title": .string(tabs[id]!.displayTitle)]) }
    case "webviews.url": tabs[id]?.url = v.s("url")
    case "webviews.favicon": if let u = v.sOpt("url") { tabs[id]?.favicon = u }
    case "webviews.audio": tabs[id]?.audio = v.b("playing")
    default:
      if isSelected { renderHeader() }  // progress / back-forward state
      return
    }
    saveSoon()
    if favorites.contains(id) { renderFavorites() } else if let sid = spaceOf(id) { renderPage(sid) }
    if isSelected && e == "webviews.url" { renderHeader() }
  }

  func handleReorder(_ value: Value) {
    let src = value.s("source"), dst = value.s("target"), pos = value.s("position")
    guard src != dst, tabs[src] != nil || folders[src] != nil, let (tb, ti) = locate(dst) else { return }
    var box = tb
    var index = pos == "after" ? ti + 1 : ti
    if pos == "into", folders[dst] != nil {
      box = .folder(dst)
      index = folders[dst]!.children.count
    }
    if folders[src] != nil {
      // Folders live in the pinned section, never inside themselves.
      if case .today = box { return }
      if box == .favorites { return }
      if case let .folder(f) = box, f == src || contains(folder: src, f) { return }
    }
    if box == .favorites && kindOf(src) != "favorite" && favorites.count >= Self.maxFavorites { return }
    if let (sb, si) = locate(src), sb == box, si < index { index -= 1 }
    checkpoint()
    place(src, box, index: index)
  }

  func action(_ id: String, _ action: String, _ value: Value) {
    if tabs[id] != nil {
      switch action {
      case "click": select(id)
      case "close": close(id)
      case "reset": reset(id)
      case "reorder": handleReorder(value)
      case "dropOnContent":
        if let sel = selectedId, sel != id {
          let side = value.s("side")
          env.call("peek", "split", ["ids": side == "left" ? [.string(id), .string(sel)] : [.string(sel), .string(id)], "layout": "horizontal"])
        }
      case "menu": menuPicked(id, value.string ?? "")
      default: break
      }
      return
    }
    if folders[id] != nil {
      switch action {
      case "toggle":
        folders[id]?.open.toggle()
        changed(folders[id]?.spaceId)
      case "reorder": handleReorder(value)
      case "menu":
        if value.string == "deleteFolder" { confirmDeleteFolder(id) }
        if value.string == "newFolder" {
          let sid = folders[id]!.spaceId
          let fid = newId("folder-")
          checkpoint()
          folders[fid] = Folder(id: fid, spaceId: sid, title: "New Folder", open: true, children: [])
          folders[id]?.children.append(fid)
          changed(sid)
        }
      default: break
      }
      return
    }
    switch id {
    case "tabs.nav":
      if action == "toggleSidebar" { env.call("window", "toggleSidebar") } else { web(action) }
    case "tabs.url":
      if action == "click" { openCommandBar("edit") }
      if action == "copy" { copyURL() }
    default:
      if Text.hasPrefix(id, "tabs.divider:"), action == "clear" { clearToday(Text.dropPrefix(id, "tabs.divider:")) }
      if Text.hasPrefix(id, "tabs.newtab:"), action == "click" { openCommandBar("new") }
      if Text.hasPrefix(id, "tabs.deleteFolder:"), action == "button" {
        env.call("ui", "set", ["slot": "dialog", "tree": nil])
        let fid = Text.dropPrefix(id, "tabs.deleteFolder:")
        if value.s("button") == "delete" && folders[fid] != nil { deleteFolder(fid) }
      }
    }
  }

  func confirmDeleteFolder(_ fid: String) {
    guard let f = folders[fid] else { return }
    env.call("ui", "set", ["slot": "dialog", "tree": [
      "type": "dialog", "id": .string("tabs.deleteFolder:" + fid), "icon": "sf:folder",
      "title": .string("Delete your " + f.title + " folder?"), "message": "Deleting this folder will archive the tabs inside it.",
      "buttons": [["id": "cancel", "title": "Cancel", "style": "cancel"], ["id": "delete", "title": "Delete", "style": "destructive"]],
    ]])
  }

  func menuPicked(_ id: String, _ item: String) {
    switch item {
    case "copy":
      if let t = tabs[id] {
        env.call("app", "copy", ["text": .string(t.url)])
        env.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": "Copied Link", "icon": "sf:link"]])
      }
    case "duplicate": _ = duplicate(id)
    case "reset": reset(id)
    case "replacePinned":
      checkpoint()
      let current = tabs[id]?.url
      tabs[id]?.pinnedUrl = current
      changed(spaceOf(id))
    case "pin": setKind(id, "pinned", toast: true)
    case "unpin": setKind(id, "today", toast: true)
    case "favorite": if favorites.count < Self.maxFavorites { setKind(id, "favorite", toast: false) }
    case "newFolder": _ = createFolder(space: spaceOf(id) ?? currentSpace, title: nil, tabIds: [id])
    case "close": close(id)
    default:
      if Text.hasPrefix(item, "move:") {
        let kind = kindOf(id)
        _ = move(["id": .string(id), "spaceId": .string(Text.dropPrefix(item, "move:")), "kind": .string(kind == "favorite" ? "today" : kind)])
      }
    }
  }
}
