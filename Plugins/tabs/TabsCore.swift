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
    var muted = false  // runtime only, like `audio`: a tab stays muted while it lives
    /// The page's now-playing media (`webviews.nowPlaying`), runtime only: the row's hover
    /// play/pause and skip buttons. nil when nothing played or it stopped.
    var media: Value?
    /// An icon the user chose (an emoji or `sf:` symbol, TabsIcons.swift); it replaces the favicon.
    var customIcon: String?

    var displayTitle: String {
      if let c = customTitle, !c.isEmpty { return c }
      return URLs.pageTitle(title, url)
    }
    var icon: String { customIcon ?? URLs.icon(favicon, url) }
    var drift: Bool { URLs.drifted(url: url, pinned: pinnedUrl) }

    var value: Value {
      ["id": .string(id), "title": .string(title), "customTitle": .str(customTitle), "url": .string(url),
       "pinnedUrl": .str(pinnedUrl), "favicon": .str(favicon), "icon": .str(customIcon), "lastActive": .int(lastActive)]
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
      customIcon = v.sOpt("icon")
    }
  }

  /// A folder in the pinned section (Arc) or a group in Today (Dia's tab groups, den-adapted).
  /// `auto` groups come from ⌘-clicking links: they dissolve back into a plain tab when one tab
  /// is left. Manual Today folders go away when their last tab does; pinned folders persist.
  struct Folder {
    var id: String
    var spaceId: String
    var title: String
    var open: Bool
    var children: [String]
    var auto = false
    /// A live folder's source ("github"): its rows come from that connection (LiveFolders.swift).
    var live = ""
    /// An icon the user chose (TabsIcons.swift); nil shows the folder symbol.
    var icon: String? = nil

    var value: Value {
      var v: Value = ["id": .string(id), "spaceId": .string(spaceId), "title": .string(title), "open": .bool(open), "children": .array(children.map { .string($0) })]
      if auto { v.put("auto", true) }
      if !live.isEmpty { v.put("live", .string(live)) }
      if let icon { v.put("icon", .string(icon)) }
      return v
    }
  }

  /// A split view: 2–4 tabs shown side by side, kept as one sidebar item (Arc §7). The split
  /// id sits in a favorites/pinned/folder/today list in place of its tabs.
  struct Split {
    var id: String
    var layout: String  // horizontal | vertical | grid
    var children: [String]
    /// Pane sizes from dragging the gaps (`content.ratios`), kept only for the panes and layout
    /// they were made for: adding, removing or reordering a pane, or a new layout, makes them equal.
    var ratios: [Double] = []
    var ratiosKey = ""

    var key: String {
      var k = layout
      for c in children { k += "|" + c }
      return k
    }
    /// The sizes `content.show` takes, or [] (equal panes).
    var showRatios: [Value] { ratiosKey == key ? ratios.map { .double($0) } : [] }

    var value: Value {
      var v: Value = ["id": .string(id), "layout": .string(layout), "children": .array(children.map { .string($0) })]
      if !showRatios.isEmpty {
        v.put("ratios", .array(showRatios))
        v.put("ratiosKey", .string(ratiosKey))
      }
      return v
    }
  }

  /// Where a tab, folder or split lives. Favorites are shared by every space.
  enum Box: Equatable {
    case favorites
    case pinned(String)  // space id
    case folder(String)  // folder id
    case today(String)  // space id
    case split(String)  // split id
  }

  static let ns = "tabs"
  static let maxFavorites = 12
  /// Hover-card dwell (docs/reference/dia-ui-spec.md §2.4): list rows 0.7 s, favorite tiles 0.3 s.
  static let rowCardDelayMs: Int64 = 700
  static let tileCardDelayMs: Int64 = 300
  static let maxPanes = 4
  /// 24 hours (Arc: 12). A tab opened late in the day is still there the next morning; see docs/defaults.md.
  static let defaultArchiveAfterMs: Int64 = 24 * 3_600_000
  // den's choice: 5 minutes in the background, then the page is discarded (its WebContent
  // process exits; the host keeps the URL, history and a snapshot on disk). The host refuses
  // tabs that play media, hold unsaved input or are on screen (docs/perf/memory.md).
  static let defaultSuspendAfterMs: Int64 = 5 * 60_000
  static let tickMs: UInt64 = 60_000

  let env: PluginEnv

  // State (persisted)
  var tabs: [String: Tab] = [:]
  var folders: [String: Folder] = [:]
  var splits: [String: Split] = [:]
  var favorites: [String] = []
  var pinned: [String: [String]] = [:]
  var today: [String: [String]] = [:]
  var selected: [String: String] = [:]  // space id -> tab id
  var archive: [Value] = []  // newest first: {id, title, url, favicon, closedAt, spaceId}
  var libraryOpen = false
  /// The Library's shown section: "archive" or "downloads" (TabsDownloads.swift).
  var librarySection = "archive"
  var downloadsArchiveMs = TabsCore.defaultDownloadsArchiveMs
  /// The download the last download toast was about (its action button).
  var toastDownload = ""
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
  var editing: String?  // tab or folder whose title is being renamed inline in the sidebar
  var iconEditing: String?  // tab or folder whose icon picker is open (TabsIcons.swift)
  /// Other plugins' buttons in the URL pill, per web view and owner (`pillButtons`).
  var pillButtons: [String: [(String, [Value])]] = [:]
  /// Recent distinct `pillButtons` lists. Shields sends every tab of a site the same shield, so
  /// hundreds of tabs share a few copies instead of holding one each (docs/perf/baseline.md).
  var pillPool: [[(String, [Value])]] = []
  /// Tab -> the tab it was ⌘-clicked from, so later links from a group land next to their
  /// opener (Chrome-style, dia-ui-spec §6). Runtime only.
  var opener: [String: String] = [:]
  /// Pop-up tab -> the page that opened it with window.open / target=_blank (TabsPopups.swift).
  var popupOpener: [String: String] = [:]
  /// Extra tabs picked with ⌘-click / ⇧-click in the sidebar (⌃⌘N makes a folder of them).
  var multi: [String] = []
  /// Groups waiting for an on-device name (the header shimmers), and ones revealing it now.
  var naming: Set<String> = []
  var revealing: Set<String> = []
  var aiAvailable: Bool?
  /// Setting: ⌘-clicking a link groups the new tab with its source (default on).
  var groupLinks = true
  /// Tidy Tabs (TabsTidy.swift): settings, the space being tidied, and the undo step it made.
  var tidyEnabled = false
  var tidyAuto = false
  var tidying: String?
  var tidyStartedAt: Int64 = 0
  var tidyUndoDepth = -1
  var tidyLastAuto: [String: Int64] = [:]
  var tidyUnavailable: String?
  var tidyCommandRegistered = false
  var tidyRegisterAttempts = 0
  var tidyReady = false
  /// Auto grouping (TabsTidy.swift): new loose Today tabs waiting for the next batch, per space,
  /// and the batch's debounce stamp.
  var autoGroup = false
  var autoGroupPending: [String: [String]] = [:]
  var autoGroupStamp: Int64 = 0
  /// Space -> the new tabs of the batch the model is grouping now.
  var autoGroupAsked: [String: [String]] = [:]
  var autoGroupDelayMs: UInt64 = TabsCore.autoGroupDefaultDelayMs
  var settingsListening = false
  /// Foreground clock: milliseconds den has been frontmost this session. Idle discard counts
  /// only this time, so tabs don't unload while you work in another app.
  var fgAccum: Int64 = 0
  var activeSince: Int64?
  var fgLastUse: [String: Int64] = [:]
  /// The most recently used tabs are never discarded for idleness (Dia 1.5/1.8).
  static let protectedRecent = 5
  /// Battery saver setting (TabsEnergy.swift), the Mac's power state, and sites kept active.
  var batterySaver = true
  var power: (battery: Bool, lowPower: Bool) = (false, false)
  var keepActive: [String] = []
  var settingsSubscribed = false

  /// Live folders (GitHub): rows fed by a connection. Countdown chips on favorites, by host.
  lazy var liveFolders = LiveFolders(core: self)
  var badges: [String: String] = [:]
  // Windows (TabsWindows.swift). Every window shows the same spaces and tabs; each keeps its own
  // place (space and tab, Arc). `currentSpace`/`selected` belong to `normalWin`, the normal window
  // used last; `places` holds where every other normal window is.
  struct Place {
    var space: String
    var tab: String?
  }
  /// The window in front (normal or private) and the normal window used last.
  var activeWin = "w1"
  var normalWin = "w1"
  var places: [String: Place] = [:]
  /// The active normal window shows no tab (a new ⌘N window before you pick one).
  var blankWin = false
  /// While set, `spaces.current` only records the space (a window change already shows it).
  var activating = false
  /// Rendering the sidebar for this window (per-window selection; nil = the only one).
  var renderWin: String?
  /// Normal windows closed this session, newest first (⇧⌘T / File ▸ Reopen Closed Window).
  var closedWindows: [Value] = []
  /// The last thing closed was a window, so ⇧⌘T reopens it rather than a tab.
  var lastClosedWasWindow = false
  /// Windows from the saved state, placed at launch.
  var savedWindows: [Value] = []
  /// A window that should open the command bar once it's in front (a new, empty window).
  var commandBarFor: String?
  /// Being reopened: the next window.opened takes this place.
  var reopening: Value?
  /// Setting: a tab can show in more than one window (it moves to the window you pick it in).
  /// Off: picking a tab shown in another window brings that window forward.
  var sameTabInWindows = false
  /// Private windows: their tabs live only here (never in `tabs`, the state or the archive).
  struct PrivateWindow {
    var tabs: [String] = []
    var selected: String?
  }
  var privates: [String: PrivateWindow] = [:]
  var ptabs: [String: Tab] = [:]
  var nextPrivate: Int64 = 1

  init(env: PluginEnv) { self.env = env }

  // MARK: - Lifecycle

  func start() {
    refreshSpaces()
    currentSpace = env.call("spaces", "current").s("id")
    load()
    for t in tabs.values { ensureWebview(t.id) }
    setActive(env.call("app", "state").b("active"))
    bindKeys()
    subscribe()
    startEnergy()
    liveFolders.start()
    registerSettings()
    startDownloads()
    tidyStart()
    tidyReady = true
    renderAll()
    showSelected()
    // Windows open at quit come back where they were (TabsWindows.swift).
    restoreWindows()
    tick()
    env.timer(Self.tickMs, true) { [self] in tick() }
    // Links that launched den: wait one turn so the peek plugin (Little Arc) is loaded too.
    env.timer(1, false) { [self] in openExternal(env.call("app", "pendingURLs").array ?? []) }
  }

  /// Links from other apps. The peek plugin claims them for Little Arc when that is on
  /// (Arc's default); otherwise they open as today tabs in the current space.
  func openExternal(_ urls: [Value]) {
    guard !urls.isEmpty else { return }
    if env.call("peek", "openExternal", ["urls": .array(urls)])["claimed"] == true { return }
    for u in urls { if let s = u.string { _ = open(s, space: currentSpace, kind: "today", background: false, index: nil) } }
  }

  /// Called from the plugin's dispose (hot reload, unload): flush a pending save.
  func stop() {
    if dirty { save() }
    closeLibrary()
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
    var v: Value = [
      "version": 1, "nextId": .int(nextId),
      "tabs": .array(tabs.keys.sorted().map { tabs[$0]!.value }),
      "folders": .array(folders.keys.sorted().map { folders[$0]!.value }),
      "splits": .array(splits.keys.sorted().map { splits[$0]!.value }),
      "favorites": .array(favorites.map { .string($0) }),
      "spaces": .array(spaceStates),
      "archive": .array(archive),
      "mru": .array(mru.map { .string($0) }),
    ]
    // Where each normal window is (window restore). Only with more than one window.
    if !places.isEmpty { v.put("windows", windowsValue()) }
    return v
  }

  func apply(state v: Value) {
    tabs = [:]
    folders = [:]
    splits = [:]
    pinned = [:]
    today = [:]
    selected = [:]
    for t in v.a("tabs") { if let tab = Tab(t) { tabs[tab.id] = tab } }
    for f in v.a("folders") {
      guard let id = f["id"].string else { continue }
      folders[id] = Folder(id: id, spaceId: f.s("spaceId"), title: f.s("title"), open: f.b("open", true), children: f.a("children").compactMap { $0.string }, auto: f.b("auto"),
                           live: f.s("live"), icon: f.sOpt("icon"))
    }
    for sp in v.a("splits") {
      guard let id = sp["id"].string else { continue }
      splits[id] = Split(id: id, layout: sp.sOpt("layout") ?? "horizontal", children: sp.a("children").compactMap { $0.string },
                         ratios: sp.a("ratios").compactMap { $0.double }, ratiosKey: sp.s("ratiosKey"))
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
      savedWindows = state.a("windows")
    }
    for sid in spaceIds {
      if pinned[sid] == nil { pinned[sid] = [] }
      if today[sid] == nil { today[sid] = [] }
    }
    // Drop dangling references so a bad state file can never wedge the plugin.
    for (k, sp) in splits { splits[k]!.children = sp.children.filter { tabs[$0] != nil } }
    favorites = favorites.filter { tabs[$0] != nil || splits[$0] != nil }
    for (k, v) in pinned { pinned[k] = v.filter { tabs[$0] != nil || folders[$0] != nil || splits[$0] != nil } }
    for (k, v) in today { today[k] = v.filter { tabs[$0] != nil || folders[$0] != nil || splits[$0] != nil } }
    for (k, f) in folders { folders[k]!.children = f.children.filter { tabs[$0] != nil || folders[$0] != nil || splits[$0] != nil } }
    for (sid, id) in selected where tabs[id] == nil { selected[sid] = nil }
    tidySplits()
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
        tab("macOS - Apple", "https://www.apple.com/macos/", pinnedUrl: false),
        tab("Hacker News", "https://news.ycombinator.com", pinnedUrl: false),
        tab("WebKit Blog", "https://webkit.org/blog/", pinnedUrl: false),
        tab("WebKit | Apple Developer Documentation", "https://developer.apple.com/documentation/webkit", pinnedUrl: false),
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
    case let .split(s): return splits[s]?.children ?? []
    }
  }

  func setIds(_ b: Box, _ v: [String]) {
    switch b {
    case .favorites: favorites = v
    case let .pinned(s): pinned[s] = v
    case let .folder(f): folders[f]?.children = v
    case let .today(s): today[s] = v
    case let .split(s): splits[s]?.children = v
    }
  }

  func locate(_ id: String) -> (Box, Int)? {
    if let i = favorites.firstIndex(of: id) { return (.favorites, i) }
    for (s, list) in pinned { if let i = list.firstIndex(of: id) { return (.pinned(s), i) } }
    for (s, list) in today { if let i = list.firstIndex(of: id) { return (.today(s), i) } }
    for (f, folder) in folders { if let i = folder.children.firstIndex(of: id) { return (.folder(f), i) } }
    for (s, split) in splits { if let i = split.children.firstIndex(of: id) { return (.split(s), i) } }
    return nil
  }

  func space(of b: Box) -> String? {
    switch b {
    case .favorites: return nil
    case let .pinned(s), let .today(s): return s
    case let .folder(f): return folders[f]?.spaceId
    case let .split(s): return locate(s).flatMap { space(of: $0.0) }
    }
  }

  func kind(of b: Box) -> String {
    switch b {
    case .favorites: return "favorite"
    case .pinned: return "pinned"
    // A folder takes the kind of the section it lives in (a Today group holds today tabs).
    case let .folder(f): return locate(f).map { kind(of: $0.0) } ?? "pinned"
    case .today: return "today"
    case let .split(s): return locate(s).map { kind(of: $0.0) } ?? "today"
    }
  }

  func spaceOf(_ id: String) -> String? { locate(id).flatMap { space(of: $0.0) } }
  func kindOf(_ id: String) -> String { locate(id).map { kind(of: $0.0) } ?? "today" }

  /// Tab ids inside a folder, depth first.
  func tabsIn(folder f: String) -> [String] {
    var out: [String] = []
    for c in folders[f]?.children ?? [] {
      if folders[c] != nil { out += tabsIn(folder: c) } else if let sp = splits[c] { out += sp.children } else { out.append(c) }
    }
    return out
  }

  /// The split a tab is shown in, if any.
  func splitOf(_ id: String) -> String? {
    for (s, sp) in splits where sp.children.contains(id) { return s }
    return nil
  }

  /// Sidebar order for a space: favorites, pinned (folders expanded when open), today.
  func order(_ sid: String, onlyVisible: Bool) -> [String] {
    var out: [String] = []
    // A split counts as one item (its first pane), like one sidebar row.
    func walk(_ list: [String]) {
      for id in list {
        if let f = folders[id] {
          if f.open || !onlyVisible {
            walk(f.children)
          } else if let sel = selected[sid], tabsIn(folder: id).contains(sel) {
            out.append(sel)  // a collapsed folder still shows its active tab
          }
        } else if let sp = splits[id] {
          if onlyVisible { out += sp.children.prefix(1) } else { out += sp.children }
        } else {
          out.append(id)
        }
      }
    }
    walk(favorites)
    walk(pinned[sid] ?? [])
    walk(today[sid] ?? [])
    return out
  }

  /// The normal window's selected tab (nil in a new, empty window).
  var selectedId: String? { blankWin ? nil : selected[currentSpace] }

  // MARK: - Service

  /// `list`, or an equal list already held for another web view (one copy shared by both).
  func sharedPill(_ list: [(String, [Value])]) -> [(String, [Value])] {
    for p in pillPool where p.count == list.count {
      var same = true
      for i in 0..<p.count where p[i].0 != list[i].0 || p[i].1 != list[i].1 { same = false; break }
      if same { return p }
    }
    // A handful of distinct lists (shield states, a pop-up's blocked count) is all there is.
    if pillPool.count >= 16 { pillPool.removeFirst() }
    pillPool.append(list)
    return list
  }

  func handle(_ method: String, _ args: Value) -> Value {
    switch method {
    case "list":
      return list(args.sOpt("spaceId") ?? currentSpace)
    case "selected":
      // The tab in front: a private window's own tab while one is active.
      guard let id = frontTab else { return .null }
      return ptabs[id] != nil ? ["id": .string(id), "private": true] : ["id": .string(id)]
    case "closedWindows":
      return ["count": .int(Int64(closedWindows.count))]
    case "open":
      let url = args.s("url")
      guard !url.isEmpty else { return .err("tabs: open needs a url") }
      // In a private window, a new tab is private (unless a space is named).
      if let w = activePrivate, args.sOpt("spaceId") == nil {
        if let a = args.sOpt("webview"), ptabs[a] != nil || tabs[a] != nil { return .err("tabs: cannot adopt webview '" + a + "'") }
        return ["id": .string(openPrivate(url, in: w, background: args.b("background"), adopt: args.sOpt("webview")))]
      }
      let kind = args.sOpt("kind") ?? "today"
      guard kind == "today" || kind == "pinned" || kind == "favorite" else { return .err("tabs: bad kind " + kind) }
      if kind == "favorite" && favorites.count >= Self.maxFavorites { return .err("tabs: favorites are full") }
      // `webview`: adopt an existing web view (a peek or Little Arc page) so it keeps its state.
      if let w = args.sOpt("webview") {
        guard tabs[w] == nil, !env.call("webviews", "get", ["id": .string(w)]).isErr else { return .err("tabs: cannot adopt webview '" + w + "'") }
      }
      let id = open(url, space: args.sOpt("spaceId") ?? currentSpace, kind: kind, background: args.b("background"), index: args["index"].int.map { Int($0) },
                    adopt: args.sOpt("webview"))
      return ["id": .string(id)]
    case "select":
      if ptabs[args.s("id")] != nil { selectPrivate(args.s("id")); return .okay }
      guard tabs[args.s("id")] != nil else { return .err("tabs: no tab '" + args.s("id") + "'") }
      select(args.s("id"))
    case "close":
      if ptabs[args.s("id")] != nil { closePrivate(args.s("id")); return .okay }
      guard tabs[args.s("id")] != nil else { return .err("tabs: no tab '" + args.s("id") + "'") }
      close(args.s("id"))
    case "pin", "unpin", "favorite":
      let id = args.s("id")
      guard tabs[id] != nil else { return .err("tabs: no tab '" + id + "'") }
      if method == "favorite" && favorites.count >= Self.maxFavorites && kindOf(id) != "favorite" { return .err("tabs: favorites are full") }
      setKind(id, method == "pin" ? "pinned" : method == "unpin" ? "today" : "favorite", toast: false)
    case "move":
      return move(args)
    case "act":
      return act(args.s("id"), args.s("action"), args["value"])
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
    case "setIcon":
      let id = args.s("id")
      guard tabs[id] != nil || folders[id] != nil else { return .err("tabs: no tab '" + id + "'") }
      setIcon(id, args.s("icon"))
    case "navigate":
      if let id = args.sOpt("id") ?? frontTab, ptabs[id] != nil {
        let r = env.call("webviews", "navigate", ["id": .string(id), "url": args["url"]])
        if r.isErr { return r }
        return .okay
      }
      guard let id = args.sOpt("id") ?? selectedId, tabs[id] != nil else { return .err("tabs: no tab to navigate") }
      let r = env.call("webviews", "navigate", ["id": .string(id), "url": args["url"]])
      if r.isErr { return r }
      tabs[id]?.url = env.call("webviews", "get", ["id": .string(id)]).s("url")
      changed(spaceOf(id))
    case "clearToday":
      clearToday(args.sOpt("spaceId") ?? currentSpace)
    case "menu":
      // {id}: the tab's context menu, as a right-click shows it.
      guard tabs[args.s("id")] != nil else { return .err("tabs: no tab '" + args.s("id") + "'") }
      return .array(contextMenu(args.s("id")))
    case "unloadSpace":
      return ["unloaded": .int(Int64(unloadSpace(args.sOpt("spaceId") ?? currentSpace)))]
    case "keepActive":
      // {id}: toggles the tab's site on the "Always keep active" list; no id: the list.
      if let id = args.sOpt("id") {
        guard tabs[id] != nil else { return .err("tabs: no tab '" + id + "'") }
        toggleKeepActive(id)
      }
      return .array(keepActive.map { .string($0) })
    case "energy":
      // What the energy policy sees now (tests, the command bar).
      return ["batterySaver": .bool(batterySaver), "saving": .bool(saving), "battery": .bool(power.battery), "lowPower": .bool(power.lowPower),
              "suspendAfterMs": .int(effectiveSuspendAfterMs), "keepActive": .array(keepActive.map { .string($0) })]
    case "undo":
      guard undo() else { return .err("tabs: nothing to undo") }
    case "archive":
      return .array(archive)
    case "library":
      if args.b("open", true) { openLibrary(section: args.sOpt("section") ?? "archive") } else { closeLibrary() }
    case "badge":
      // A short chip on the favorites whose host is `host` ("in 8m": the calendar's countdown). "" removes it.
      let host = URLs.host(args.s("host"))
      guard !host.isEmpty else { return .err("tabs: badge needs a host") }
      let text = args.s("text")
      if (badges[host] ?? "") != text {
        badges[host] = text.isEmpty ? nil : text
        renderFavorites()
      }
    case "newLiveFolder":
      guard let fid = liveFolders.create(args.s("source"), space: args.sOpt("spaceId")) else { return .err("tabs: no live source '" + args.s("source") + "'") }
      return ["id": .string(fid)]
    case "pillButtons":
      // Another plugin's buttons in the URL pill while `webview` is selected: [{id, icon, tooltip?, active?}].
      // A click emits ui.action {id: <button id>, action: click, value: {webview}}.
      let w = args.s("webview"), owner = args.s("owner")
      guard !w.isEmpty, !owner.isEmpty else { return .err("tabs: pillButtons needs webview and owner") }
      var list = pillButtons[w] ?? []
      list.removeAll { $0.0 == owner }
      if !args.a("buttons").isEmpty { list.append((owner, args.a("buttons"))) }
      pillButtons[w] = list.isEmpty ? nil : sharedPill(list)
      if w == selectedId { renderHeader() }
    case "addToArchive":
      // A page that was never a tab (an auto-closed Little Arc window) goes into the archive.
      let url = args.s("url")
      guard !url.isEmpty else { return .err("tabs: addToArchive needs a url") }
      let sid = args.sOpt("spaceId").flatMap { pageIndex($0) != nil ? $0 : nil } ?? currentSpace
      let id = newId("tab-")
      archive.insert(["id": .string(id), "title": .string(URLs.pageTitle(args.s("title"), url)), "url": .string(url),
                      "favicon": .string(URLs.icon(args.sOpt("favicon"), url)), "closedAt": .int(env.now()), "spaceId": .string(sid)], at: 0)
      if archive.count > 500 { archive.removeLast() }
      saveSoon()
      env.emit("tabs.changed", ["spaceId": .string(sid)])
      return ["id": .string(id)]
    case "restore":
      guard let id = restore(args.s("id")) else { return .err("tabs: no archived tab '" + args.s("id") + "'") }
      return ["id": .string(id)]
    case "removeArchived":
      // {urls?, after?, before?, all?}: archive entries leave (an extension's history.deleteUrl,
      // deleteRange, deleteAll). Returns the removed entries.
      let urls = args.a("urls").compactMap { $0.string }
      let after = args["after"].int, before = args["before"].int, all = args.b("all")
      guard all || !urls.isEmpty || after != nil || before != nil else { return .err("tabs: removeArchived needs urls, a range or all") }
      var removed: [Value] = []
      archive.removeAll { e in
        let t = e.i("closedAt")
        let hit = all || (!urls.isEmpty && urls.contains(e.s("url"))) || (urls.isEmpty && t >= (after ?? Int64.min) && t <= (before ?? Int64.max))
        if hit { removed.append(e) }
        return hit
      }
      if !removed.isEmpty {
        saveSoon()
        env.emit("tabs.changed", ["spaceId": .string(currentSpace)])
      }
      return .array(removed)
    case "setPinnedUrl":
      // A pinned tab or favorite's home address (the "/" reset target; an extension's bookmarks.update).
      let id = args.s("id"), url = args.s("url")
      guard tabs[id] != nil, kindOf(id) != "today" else { return .err("tabs: no pinned tab '" + id + "'") }
      guard !url.isEmpty else { return .err("tabs: setPinnedUrl needs a url") }
      // A tab that isn't open and sits at its home address goes to the new one (opening it then
      // loads that); a live page stays where it is and shows the "/" drift marker.
      let home = tabs[id]?.pinnedUrl
      if tabs[id]?.url == home, !env.call("webviews", "get", ["id": .string(id)]).b("live") {
        env.call("webviews", "navigate", ["id": .string(id), "url": .string(url)])
        tabs[id]?.url = url
      }
      tabs[id]?.pinnedUrl = url
      changed(spaceOf(id))
    case "createFolder":
      let tabIds = args.a("tabIds").compactMap { $0.string }.filter { tabs[$0] != nil }
      return ["id": .string(createFolder(space: args.sOpt("spaceId") ?? currentSpace, title: args.sOpt("title"), tabIds: tabIds))]
    case "deleteFolder":
      guard folders[args.s("id")] != nil else { return .err("tabs: no folder '" + args.s("id") + "'") }
      deleteFolder(args.s("id"))
    case "newTab":
      // A new tab at the end of a folder or group (⌥⌘T, the folder card's "New Tab").
      if let f = args.sOpt("folderId"), folders[f] == nil { return .err("tabs: no folder '" + f + "'") }
      newTabInFolder(args.sOpt("folderId"))
    case "split":
      let ids = args.a("ids").compactMap { $0.string }
      guard !ids.isEmpty, ids.allSatisfy({ tabs[$0] != nil }) else { return .err("tabs: split needs tab ids") }
      let layout = args.sOpt("layout") ?? "horizontal"
      guard layout == "horizontal" || layout == "vertical" || layout == "grid" else { return .err("tabs: bad layout " + layout) }
      return split(ids, layout: layout, focus: args.sOpt("focus"))
    case "unsplit":
      let id = args.s("id")
      if splits[id] != nil { unsplit(id) } else if tabs[id] != nil, splitOf(id) != nil { separate(id) } else { return .err("tabs: no split '" + id + "'") }
    case "settings":
      if let a = args["archiveAfterMs"].int { archiveAfterMs = max(0, a) }
      if let s = args["suspendAfterMs"].int { suspendAfterMs = max(0, s) }
      if let g = args["groupLinks"].bool {
        groupLinks = g
        env.call("settings", "set", ["id": .string(Self.ns), "key": "groupLinks", "value": .bool(g)])
      }
      if let b = args["batterySaver"].bool, b != batterySaver {
        batterySaver = b
        saveEnergy()
        applySaver()
        env.call("settings", "set", ["id": .string(Self.ns), "key": "batterySaver", "value": .bool(b)])
      }
      let v: Value = ["archiveAfterMs": .int(archiveAfterMs), "suspendAfterMs": .int(suspendAfterMs), "groupLinks": .bool(groupLinks),
                      "batterySaver": .bool(batterySaver)]
      if !args.isNull {
        env.call("storage", "set", ["ns": .string(Self.ns), "key": "settings", "value": v])
        // Keep the Settings window in step (a no-op when the change came from it).
        env.call("settings", "set", ["id": .string(Self.ns), "key": "archiveAfterMs", "value": .int(archiveAfterMs)])
        env.call("settings", "set", ["id": .string(Self.ns), "key": "suspendAfterMinutes", "value": .int(suspendAfterMs / 60_000)])
      }
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
      "pinnedUrl": .str(t.pinnedUrl), "favicon": .str(t.favicon.flatMap { URLs.usable($0) ? $0 : nil }), "webviewId": .string(id), "lastActive": .int(t.lastActive),
      "audio": .bool(t.audio), "muted": .bool(t.muted), "icon": .str(t.customIcon),
    ]
  }

  func list(_ sid: String) -> Value {
    func item(_ id: String) -> Value {
      if let f = folders[id] {
        return ["id": .string(id), "folder": true, "title": .string(f.title), "open": .bool(f.open), "auto": .bool(f.auto), "icon": .str(f.icon), "children": .array(f.children.map { item($0) })]
      }
      if let sp = splits[id] {
        return ["id": .string(id), "split": true, "layout": .string(sp.layout), "children": .array(sp.children.map { tabValue($0) })]
      }
      return tabValue(id)
    }
    return [
      "favorites": .array(favorites.map { item($0) }),
      "pinned": .array((pinned[sid] ?? []).map { item($0) }),
      "today": .array((today[sid] ?? []).map { item($0) }),
    ]
  }

  // MARK: - Split view

  /// Puts `ids` into one split (Arc: up to 4 panes). If the first tab is already in a split, the
  /// others join it; otherwise a new split takes the first tab's place in the sidebar.
  func split(_ requested: [String], layout: String, focus: String?) -> Value {
    var members: [String] = []
    for id in requested where !members.contains(id) { members.append(id) }
    // Join the first split one of the tabs is already in; new tabs go next to their neighbours
    // in `requested` (so a drop left of the shown tab lands before it).
    let existing = members.lazy.compactMap { self.splitOf($0) }.first
    var all = existing.map { splits[$0]!.children } ?? []
    for (k, id) in members.enumerated() where !all.contains(id) {
      if let next = members[(k + 1)...].first(where: { all.contains($0) }), let j = all.firstIndex(of: next) { all.insert(id, at: j) } else { all.append(id) }
    }
    guard all.count >= 2 else { return .err("tabs: a split needs two tabs") }
    guard all.count <= Self.maxPanes else { return .err("tabs: a split holds at most 4 tabs") }
    checkpoint()
    let sid: String
    if let e = existing {
      sid = e
    } else {
      guard let (b, i) = locate(members[0]) else { return .err("tabs: no tab '" + members[0] + "'") }
      sid = newId("split-")
      splits[sid] = Split(id: sid, layout: layout, children: [])
      var list = ids(b)
      list[i] = sid
      setIds(b, list)
      splits[sid]!.children = [members[0]]
    }
    let pinnedKind = kind(of: .split(sid)) != "today"
    for id in all where !(splits[sid]!.children.contains(id)) {
      guard let (b, i) = locate(id) else { continue }
      var list = ids(b)
      list.remove(at: i)
      setIds(b, list)
      // Tabs take on the kind of the place the split lives in.
      if pinnedKind { if tabs[id]?.pinnedUrl == nil, let u = tabs[id]?.url { tabs[id]?.pinnedUrl = u } } else { tabs[id]?.pinnedUrl = nil }
    }
    splits[sid]!.children = all
    splits[sid]!.layout = layout
    tidySplits()
    let target = focus.flatMap { all.contains($0) ? $0 : nil } ?? members[members.count - 1]
    let space = spaceOf(sid) ?? currentSpace
    select(target)
    changed(space)
    return ["id": .string(sid)]
  }

  /// "Separate All Tabs": the split's tabs go back into its list, in pane order.
  func unsplit(_ sid: String) {
    guard let sp = splits[sid], let (b, i) = locate(sid) else { return }
    checkpoint()
    var list = ids(b)
    list.replaceSubrange(i...i, with: sp.children)
    setIds(b, list)
    splits[sid] = nil
    showSelected()
    changed(space(of: b) ?? currentSpace)
  }

  /// Takes one tab out of its split and puts it right after the split.
  func separate(_ id: String) {
    guard let sid = splitOf(id), let (b, i) = locate(sid) else { return }
    checkpoint()
    splits[sid]!.children.removeAll { $0 == id }
    var list = ids(b)
    list.insert(id, at: i + 1)
    setIds(b, list)
    tidySplits()
    showSelected()
    changed(space(of: b) ?? currentSpace)
  }

  /// A split with fewer than two tabs dissolves into its remaining tab.
  func tidySplits() {
    for (sid, sp) in splits where sp.children.count < 2 {
      if let (b, i) = locate(sid) {
        var list = ids(b)
        list.replaceSubrange(i...i, with: sp.children)
        setIds(b, list)
      }
      splits[sid] = nil
    }
    tidyFolders()
  }

  /// Auto groups (⌘-clicked links) dissolve into their last tab; empty Today folders go away.
  /// Pinned folders persist, even empty (Arc).
  func tidyFolders() {
    var again = true
    while again {
      again = false
      for (fid, f) in folders {
        guard let (b, i) = locate(fid) else { continue }
        guard (f.auto && f.children.count <= 1) || (f.children.isEmpty && kind(of: b) == "today") else { continue }
        var list = ids(b)
        list.replaceSubrange(i...i, with: f.children)
        setIds(b, list)
        folders[fid] = nil
        naming.remove(fid)
        revealing.remove(fid)
        if editing == fid { editing = nil }
        again = true
        break
      }
    }
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
        tabs[id]?.muted = st.b("muted")
      }
    }
  }

  func open(_ url: String, space sid: String, kind: String, background: Bool, index: Int?, adopt: String? = nil) -> String {
    let id = adopt ?? newId("tab-")
    let t = Tab(id: id, title: URLs.title(url), url: url, pinnedUrl: kind == "today" ? nil : url, lastActive: env.now())
    tabs[id] = t
    let box: Box = kind == "favorite" ? .favorites : kind == "pinned" ? .pinned(sid) : .today(sid)
    var list = ids(box)
    let at = index ?? (kind == "today" ? 0 : list.count)
    list.insert(id, at: max(0, min(at, list.count)))
    setIds(box, list)
    ensureWebview(id)
    tabs[id]?.url = env.call("webviews", "get", ["id": .string(id)]).sOpt("url") ?? url
    env.emit("tabs.opened", ["id": .string(id)])
    if kind == "today" { autoGroupNoted(id, space: sid) }
    if background {
      changed(kind == "favorite" ? nil : sid)
    } else {
      select(id)
    }
    return id
  }

  func select(_ id: String) {
    if ptabs[id] != nil { return selectPrivate(id) }
    guard tabs[id] != nil else { return }
    // Shown in another window, and a tab shows in one window only: go to that window instead.
    if let w = windowShowing(id) {
      env.call("window", "focus", ["id": .string(w)])
      return
    }
    let fromPrivate = activeWin != normalWin
    blankWin = false
    let sid = spaceOf(id) ?? currentSpace
    let previous = selectedId
    let now = env.now()
    if let p = previous { tabs[p]?.lastActive = now; fgLastUse[p] = fgNow() }
    tabs[id]?.lastActive = now
    fgLastUse[id] = fgNow()
    mru.removeAll { $0 == id }
    mru.insert(id, at: 0)
    if mru.count > 50 { mru.removeLast() }
    selected[sid] = id
    // A tab inside a collapsed folder shows under its header (Dia 1.28); the folder stays closed.
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
    // Picked from a private window (the command bar's open tabs): the normal window shows it.
    if fromPrivate { env.call("window", "focus", ["id": .string(normalWin)]) }
  }

  /// Picks what to show after `id` leaves `sid`'s selection.
  func replacement(for id: String, in sid: String) -> String? {
    // The next Today tab below (inside groups too, dia-ui-spec §6), else the one above.
    var flat: [String] = []
    func walk(_ list: [String]) {
      for c in list {
        if let f = folders[c] { walk(f.children) } else if let sp = splits[c] { flat += sp.children.prefix(1) } else { flat.append(c) }
      }
    }
    walk(today[sid] ?? [])
    if let i = flat.firstIndex(of: id) {
      if i + 1 < flat.count { return flat[i + 1] }
      if i > 0 { return flat[i - 1] }
    }
    let visible = Set(order(sid, onlyVisible: false))
    return mru.first { $0 != id && visible.contains($0) && tabs[$0] != nil }
  }

  func archiveEntry(_ id: String, space sid: String?) -> Value {
    let t = tabs[id]!
    return ["id": .string(id), "title": .string(t.displayTitle), "url": .string(t.url), "favicon": .string(URLs.icon(t.favicon, t.url)),
            "icon": .str(t.customIcon), "closedAt": .int(env.now()), "spaceId": .str(sid)]
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
    tidySplits()
    env.call("webviews", "suspend", ["id": .string(id), "force": true])
    env.emit("tabs.closed", ["id": .string(id)])
  }

  /// ⌘W and the row's X. The next tab goes on screen first; the closed page is let go after
  /// (Dia 1.48: "show the next tab first, then tear down"), and the sidebar renders once.
  func close(_ id: String) {
    guard tabs[id] != nil else { return }
    lastClosedWasWindow = false
    // Other windows showing it are left empty (their sidebars re-render below).
    leaveOtherWindows(id)
    let sid = spaceOf(id) ?? currentSpace
    let wasSelected = selectedId == id || selected[sid] == id
    let next = wasSelected ? replacement(for: id, in: sid) : nil
    let today = kindOf(id) == "today"
    if today { checkpoint() }
    // A pane of a split leaves the split first (the split is shown again without it, below).
    if splitOf(id) != nil {
      if today { archiveTab(id, space: sid); collectWebviews() } else { tabs[id]?.lastActive = env.now(); env.call("webviews", "suspend", ["id": .string(id), "force": true]) }
      if wasSelected {
        selected[sid] = nil
        if let n = next { select(n) } else { showSelected() }
      }
      changed(sid)
      return
    }
    if wasSelected {
      selected[sid] = nil
      if let n = next { focusQuietly(n, in: sid) }
      showSelected()
    }
    if today {
      archiveTab(id, space: sid)
      collectWebviews()
    } else {
      // Pinned tabs and favorites are only unloaded.
      tabs[id]?.lastActive = env.now()
      env.call("webviews", "suspend", ["id": .string(id), "force": true])
    }
    multi.removeAll { $0 == id }
    changed(sid)
    if wasSelected, let n = next { env.emit("tabs.selected", ["id": .string(n), "previous": .string(id)]) }
  }

  /// `select` without its render and events (the caller renders once and emits).
  func focusQuietly(_ id: String, in sid: String) {
    let now = env.now()
    tabs[id]?.lastActive = now
    fgLastUse[id] = fgNow()
    mru.removeAll { $0 == id }
    mru.insert(id, at: 0)
    if mru.count > 50 { mru.removeLast() }
    selected[sid] = id
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
    if case .split = from { tidySplits() }
    // A group moved into the pinned section becomes a plain (persistent) folder.
    if folders[id] != nil, kind(of: box) == "pinned" { folders[id]?.auto = false }
    tidyFolders()
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
      box = .today(sid)
    } else {
      return .err("tabs: bad kind " + kind)
    }
    checkpoint()
    place(id, box, index: args["index"].int.map { Int($0) } ?? (kind == "today" && box != from ? 0 : nil))
    collectWebviews()
    return .okay
  }

  /// "Move to <Space>" and dropping a row on a footer space icon: the tab (or folder) keeps its
  /// section (pinned stays pinned) in the other space; a favorite lands in that space's today.
  func moveToSpace(_ id: String, _ sid: String) {
    guard pageIndex(sid) != nil, tabs[id] != nil || folders[id] != nil || splits[id] != nil else { return }
    let kind = kindOf(id)
    if kind != "favorite" && (spaceOf(id) ?? folders[id]?.spaceId) == sid { return }
    _ = move(["id": .string(id), "spaceId": .string(sid), "kind": .string(kind == "favorite" ? "today" : kind)])
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
      // Naming a group is a deliberate act: it becomes a folder that stays, and no on-device
      // name replaces the user's.
      folders[id]?.auto = false
      naming.remove(id)
    } else {
      tabs[id]?.customTitle = title.isEmpty ? nil : title
    }
    changed(spaceOf(id) ?? folders[id]?.spaceId)
  }

  /// Inline rename in the sidebar (Arc: double-click or right-click > Rename). The row shows an
  /// editor; `endRename` gets its text (nil = Esc). An empty tab title resets it to the page's.
  func beginRename(_ id: String) {
    guard tabs[id] != nil || folders[id] != nil else { return }
    let previous = editing
    editing = id
    if let p = previous, p != id, let ps = spaceOf(p) ?? folders[p]?.spaceId { renderPage(ps) }
    if let sid = spaceOf(id) ?? folders[id]?.spaceId { renderPage(sid) }
  }

  func endRename(_ id: String, _ title: String?) {
    guard editing == id else { return }
    editing = nil
    let sid = spaceOf(id) ?? folders[id]?.spaceId
    if let t = title {
      let changed = folders[id] != nil ? !t.isEmpty && t != folders[id]!.title
        : t.isEmpty ? tabs[id]?.customTitle != nil : t != tabs[id]?.displayTitle
      if changed { renameFromSidebar(id, t); return }
    }
    if let sid { renderPage(sid) }
  }

  /// Today tabs of a space, groups included (split panes excepted, as before).
  func todayTabs(_ sid: String) -> [String] {
    var out: [String] = []
    for id in today[sid] ?? [] {
      if folders[id] != nil { out += tabsIn(folder: id).filter { splitOf($0) == nil } } else if tabs[id] != nil { out.append(id) }
    }
    return out
  }

  func clearToday(_ sid: String) {
    let keep = selected[sid]
    let victims = todayTabs(sid).filter { $0 != keep }
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
    tabs[id]?.customIcon = e.sOpt("icon")
    var list = today[sid] ?? []
    list.insert(id, at: 0)
    today[sid] = list
    ensureWebview(id)  // an archived tab whose webview is still suspended keeps its history
    env.emit("tabs.opened", ["id": .string(id)])
    select(id)
    changed(sid)
    return id
  }

  /// A folder at the first tab's place: in the pinned section (Arc), or a group in Today when the
  /// tab is a Today tab. `rename` opens the name for editing right away (Dia: ⌃⌘N).
  func createFolder(space sid: String, title: String?, tabIds: [String], rename: Bool = false) -> String {
    checkpoint()
    let fid = newId("folder-")
    var target: Box = .pinned(sid)
    var at: Int? = nil
    if let first = tabIds.first, var (b, i) = locate(first) {
      // A tab in a split stands for its split's place.
      if case let .split(s) = b, let loc = locate(s) { (b, i) = loc }
      switch b {
      case .pinned, .folder, .today:
        target = b
        at = i
      default: break
      }
    }
    let inToday = kind(of: target) == "today"
    let name = title ?? (inToday ? groupName(tabIds) : "New Folder")
    folders[fid] = Folder(id: fid, spaceId: space(of: target) ?? sid, title: name, open: true, children: [])
    var list = ids(target)
    list.insert(fid, at: max(0, min(at ?? list.count, list.count)))
    setIds(target, list)
    for t in tabIds {
      // A split pane brings its whole split along.
      let item = splitOf(t) ?? t
      if locate(item).map({ $0.0 }) != .folder(fid) { place(item, .folder(fid), index: nil) }
    }
    multi = []
    if rename { editing = fid }
    changed(space(of: target) ?? sid)
    return fid
  }

  // MARK: - Groups from links (⌘-click)

  /// A site's short name for a group header: "https://en.wikipedia.org/wiki/X" -> "Wikipedia".
  static func siteName(_ url: String) -> String {
    let h = URLs.host(url)
    guard URLs.isWeb(url), !h.isEmpty, h != url else { return URLs.title(url) }
    var labels: [[UInt8]] = [[]]
    for c in h.utf8 { if c == 46 { labels.append([]) } else { labels[labels.count - 1].append(c) } }
    labels = labels.filter { !$0.isEmpty }
    guard labels.count >= 2 else { return capitalized(String(decoding: labels.first ?? [], as: UTF8.self)) }
    var k = labels.count - 2
    // co.uk, com.au and friends: the name is one label further left.
    let second = String(decoding: labels[k], as: UTF8.self)
    if labels.count >= 3, labels[labels.count - 1].count == 2, ["co", "com", "org", "net", "ac", "gov", "edu"].contains(second) { k -= 1 }
    let name = String(decoding: labels[k], as: UTF8.self)
    for (key, pretty) in siteNames where key == name { return pretty }
    return capitalized(name)
  }

  static let siteNames: [(String, String)] = [
    ("github", "GitHub"), ("youtube", "YouTube"), ("linkedin", "LinkedIn"), ("stackoverflow", "Stack Overflow"), ("ycombinator", "Hacker News"),
    ("webkit", "WebKit"), ("icloud", "iCloud"), ("bbc", "BBC"), ("cnn", "CNN"), ("nytimes", "NYTimes"), ("mozilla", "MDN"), ("swift", "Swift"),
  ]

  static func capitalized(_ s: String) -> String {
    var b = Array(s.utf8)
    if let f = b.first, f >= 97 && f <= 122 { b[0] = f - 32 }
    return String(decoding: b, as: UTF8.self)
  }

  /// "Wikipedia", or "GitHub & Apple" when the tabs come from two sites.
  func groupName(_ ids: [String]) -> String {
    var names: [String] = []
    for id in ids {
      let t = tabs[id] ?? splits[id].flatMap { tabs[$0.children.first ?? ""] }
      guard let t else { continue }
      let n = Self.siteName(t.url)
      if !n.isEmpty && !names.contains(n) { names.append(n) }
    }
    if names.isEmpty { return "New Folder" }
    return names.count == 1 ? names[0] : names[0] + " & " + names[1]
  }

  /// A link ⌘-clicked (or middle-clicked) in a Today tab: the new tab opens in the background
  /// grouped with its source (dia-ui-spec §6). From a plain tab, the two are wrapped into a new
  /// group at the source's place; from a tab already in a group, the new tab joins it right after
  /// the source's earlier links (Chrome-style opener order). Returns the new tab's id.
  func openFromLink(_ url: String, source src: String, background: Bool) -> String? {
    guard groupLinks, tabs[src] != nil, splitOf(src) == nil, kindOf(src) == "today", let (b, i) = locate(src) else { return nil }
    let sid = spaceOf(src) ?? currentSpace
    let id = newId("tab-")
    tabs[id] = Tab(id: id, title: URLs.title(url), url: url, lastActive: env.now())
    opener[id] = src
    var list = ids(b)
    if case .folder = b {
      // After the source and every tab it already opened.
      var at = i
      for (j, c) in list.enumerated() where j > i && opener[c] == src { at = j }
      list.insert(id, at: at + 1)
      setIds(b, list)
    } else {
      list.insert(id, at: i + 1)
      setIds(b, list)
      // Undo (⌃Z) takes the group away and leaves the two plain tabs.
      checkpoint()
      let fid = newId("folder-")
      folders[fid] = Folder(id: fid, spaceId: sid, title: groupName([src, id]), open: true, children: [src, id], auto: true)
      var l = ids(b)
      l.remove(at: i + 1)
      l[i] = fid
      setIds(b, l)
      nameLater(fid, waitingFor: id)
    }
    ensureWebview(id)
    env.emit("tabs.opened", ["id": .string(id)])
    if background { changed(sid) } else { select(id); changed(sid) }
    return id
  }

  /// The on-device model names a new group once its new tab has a title (lazily; only when
  /// Apple Intelligence can run). Until then the header shimmers over the site-based name.
  func nameLater(_ fid: String, waitingFor tab: String) {
    if aiAvailable == nil { aiAvailable = env.call("ai", "availability").b("available") }
    guard aiAvailable == true else { return }
    naming.insert(fid)
    pendingNames[tab] = fid
    // Don't wait forever for a title (a slow or failing page).
    env.timer(Self.nameWaitMs, false) { [self] in
      if pendingNames[tab] == fid { pendingNames[tab] = nil; askName(fid) }
    }
  }

  static let nameWaitMs: UInt64 = 4000
  /// New tab -> the group waiting for its title before it asks for a name.
  var pendingNames: [String: String] = [:]

  func askName(_ fid: String) {
    guard naming.contains(fid), let f = folders[fid] else { return }
    // Background tabs load when first shown, so a new tab may only have its address yet.
    let titles = tabsIn(folder: fid).compactMap { tabs[$0].map { $0.displayTitle + " (" + URLs.display($0.url) + ")" } }
    let r = env.call("ai", "summarize", [
      "id": .string("tabs.name:" + fid), "items": .array(titles.map { .string($0) }),
      "instructions": "These are the titles of browser tabs opened together. Name the group like a folder: one to three words, specific, Title Case. Reply with the name only: no quotes, no punctuation, no explanation.",
    ])
    if r.isErr {
      naming.remove(fid)
      if f.auto { changed(f.spaceId) }
    }
  }

  func nameArrived(_ v: Value) {
    let rid = v.s("id")
    guard Text.hasPrefix(rid, "tabs.name:") else { return }
    let fid = Text.dropPrefix(rid, "tabs.name:")
    guard naming.contains(fid), folders[fid] != nil else { return }
    naming.remove(fid)
    if v.b("ok"), let name = Self.cleanName(v.s("text")), name != folders[fid]!.title {
      folders[fid]?.title = name
      revealing.insert(fid)
      saveSoon()
      renderPage(folders[fid]!.spaceId)
      revealing.remove(fid)  // the reveal plays once, on this render
    } else {
      renderPage(folders[fid]!.spaceId)
    }
  }

  /// A model reply as a group name: the first line, without quotes or trailing punctuation, at
  /// most four words and 32 characters; nil when nothing usable is left.
  static func cleanName(_ s: String) -> String? {
    var b: [UInt8] = []
    for c in s.utf8 {
      if c == 10 || c == 13 { if b.contains(where: { $0 != 32 }) { break } else { continue } }
      b.append(c)
    }
    let strip: [UInt8] = [32, 9, 34, 39, 46, 58, 42, 35, 96, 33, 63]  // space tab " ' . : * # ` ! ?
    // Curly quotes (“ ” ‘ ’) and the ellipsis.
    let wide: [[UInt8]] = [[0xE2, 0x80, 0x9C], [0xE2, 0x80, 0x9D], [0xE2, 0x80, 0x98], [0xE2, 0x80, 0x99], [0xE2, 0x80, 0xA6]]
    var trimmed = true
    while trimmed && !b.isEmpty {
      trimmed = false
      if let f = b.first, strip.contains(f) { b.removeFirst(); trimmed = true }
      if let l = b.last, strip.contains(l) { b.removeLast(); trimmed = true }
      for q in wide {
        if b.count >= 3, Array(b.prefix(3)) == q { b.removeFirst(3); trimmed = true }
        if b.count >= 3, Array(b.suffix(3)) == q { b.removeLast(3); trimmed = true }
      }
    }
    var words = 0
    var out: [UInt8] = []
    var prevSpace = true
    for c in b {
      if c == 32 {
        if !prevSpace { words += 1; if words >= 4 { break } }
        prevSpace = true
      } else {
        prevSpace = false
      }
      out.append(c)
    }
    while out.last == 32 { out.removeLast() }
    let name = String(decoding: out, as: UTF8.self)
    guard !out.isEmpty, name.count <= 32 else { return nil }
    return name
  }

  /// ⌥⌘T: a new tab at the end of the selected tab's group, selected, with the command bar to
  /// pick its page. Outside a group it's a plain new tab (⌘T).
  func newTabInFolder(_ folderId: String?) {
    let fid = folderId ?? selectedId.flatMap { s -> String? in
      guard let (b, _) = locate(splitOf(s) ?? s), case let .folder(f) = b else { return nil }
      return f
    }
    guard let fid, let f = folders[fid] else { return openCommandBar("new") }
    let id = newId("tab-")
    // In a pinned folder the tab's pinned URL is taken from the first page it opens (webEvent).
    tabs[id] = Tab(id: id, title: "New Tab", url: "about:blank", pinnedUrl: kind(of: .folder(fid)) == "today" ? nil : "about:blank", lastActive: env.now())
    folders[fid]?.children.append(id)
    if !f.open { folders[fid]?.open = true }
    ensureWebview(id)
    env.emit("tabs.opened", ["id": .string(id)])
    select(id)
    changed(f.spaceId)
    if env.call("commands", "open", ["mode": "edit", "query": ""]).isErr {
      env.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": "The Command Bar plugin isn't loaded", "icon": "sf:exclamationmark.triangle"]])
    }
  }

  // MARK: - Foreground clock (idle discard)

  func fgNow() -> Int64 { fgAccum + (activeSince.map { env.now() - $0 } ?? 0) }

  func setActive(_ on: Bool) {
    let now = env.now()
    if on, activeSince == nil { activeSince = now }
    if !on, let s = activeSince { fgAccum += now - s; activeSince = nil }
  }

  /// Tabs that may be discarded now: off screen, not among the most recently used, not a site
  /// kept active, and unused for `suspendAfterMs` of den-frontmost time (a minute with battery
  /// saver on, on battery or in Low Power Mode).
  func idleCandidates() -> [String] {
    let onScreen = onScreenTabs()
    let recent = Set(mru.filter { tabs[$0] != nil }.prefix(Self.protectedRecent))
    let fg = fgNow(), after = effectiveSuspendAfterMs
    return tabs.keys.sorted().filter { id in
      !onScreen.contains(id) && !recent.contains(id) && fg - (fgLastUse[id] ?? 0) > after && !isKeptActive(id)
    }
  }

  /// ⌃⌘N: a folder of the selected tab plus any ⌘/⇧-clicked ones, named for editing.
  func folderFromSelection() {
    guard let sel = selectedId else { return }
    var picked = multi.filter { tabs[$0] != nil && kindOf($0) != "favorite" }
    if !picked.contains(sel) { picked.append(sel) }
    guard kindOf(sel) != "favorite" || picked.count > 1 else { return }
    // Sidebar order, so the folder keeps the tabs as you see them.
    let sid = spaceOf(sel) ?? currentSpace
    let order = order(sid, onlyVisible: false)
    picked.sort { (order.firstIndex(of: $0) ?? Int.max) < (order.firstIndex(of: $1) ?? Int.max) }
    _ = createFolder(space: sid, title: nil, tabIds: picked.filter { kindOf($0) != "favorite" }, rename: true)
  }

  /// ⌘-click toggles a tab in the multi-selection; ⇧-click picks the range from the selected tab.
  func pick(_ id: String, modifiers: [Value]) -> Bool {
    let cmd = modifiers.contains("cmd"), shift = modifiers.contains("shift")
    guard cmd || shift, let sel = selectedId, sel != id || cmd else { return false }
    let sid = spaceOf(id) ?? currentSpace
    if shift {
      let list = order(sid, onlyVisible: true)
      guard let a = list.firstIndex(of: sel), let z = list.firstIndex(of: id) else { return false }
      multi = Array(list[min(a, z)...max(a, z)]).filter { $0 != sel }
    } else if multi.contains(id) {
      multi.removeAll { $0 == id }
    } else if id != sel {
      multi.append(id)
    }
    renderPage(sid)
    return true
  }

  func clearMulti() {
    guard !multi.isEmpty else { return }
    multi = []
    renderAll()
  }

  /// "Close Other Tabs" (⌥⌘W), "Close Tabs Below/Above": Today tabs only, in sidebar order, undoable.
  func closeMany(_ keep: String, _ which: String) {
    let sid = spaceOf(keep) ?? currentSpace
    var flat: [String] = []
    func walk(_ list: [String]) {
      for c in list { if let f = folders[c] { walk(f.children) } else if tabs[c] != nil { flat.append(c) } }
    }
    walk(today[sid] ?? [])
    guard let i = flat.firstIndex(of: keep) ?? (which == "others" ? 0 : nil) else { return }
    let victims: [String]
    switch which {
    case "below": victims = Array(flat[(i + 1)...])
    case "above": victims = Array(flat[..<i])
    default: victims = flat.filter { $0 != keep }
    }
    guard !victims.isEmpty else { return }
    checkpoint()
    let wasSel = selected[sid]
    for id in victims { archiveTab(id, space: sid) }
    collectWebviews()
    if let w = wasSel, tabs[w] == nil {
      selected[sid] = nil
      if tabs[keep] != nil { select(keep) } else { showSelected() }
    }
    changed(sid)
    let n = victims.count
    env.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": .string("Closed " + String(n) + (n == 1 ? " tab" : " tabs") + ". Use ⌃Z to undo."), "icon": "sf:xmark.circle.fill"]])
  }

  /// "Ungroup Tabs": the group's tabs go back to where the group was, in order.
  func ungroup(_ fid: String) {
    guard let f = folders[fid], let (b, i) = locate(fid) else { return }
    checkpoint()
    var list = ids(b)
    list.replaceSubrange(i...i, with: f.children)
    setIds(b, list)
    folders[fid] = nil
    naming.remove(fid)
    changed(f.spaceId)
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
    if liveFolders.state.removeValue(forKey: fid) != nil { liveFolders.save() }
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

  // MARK: - Settings window

  /// The Tabs section of Settings (host `settings` service). Values live in storage ns `tabs`
  /// (`prefs`, kept by the host) and mirror `settings` here; changes arrive as settings.changed.
  static let archiveChoices: [(Int64, String)] = [
    (0, "Never"), (3_600_000, "After 1 hour"), (6 * 3_600_000, "After 6 hours"), (12 * 3_600_000, "After 12 hours"),
    (24 * 3_600_000, "After 24 hours"), (7 * 86_400_000, "After 7 days"), (30 * 86_400_000, "After 30 days"),
  ]

  func registerSettings() {
    var options: [Value] = Self.archiveChoices.map { ["value": .int($0.0), "title": .string($0.1)] }
    if !Self.archiveChoices.contains(where: { $0.0 == archiveAfterMs }) {
      options.append(["value": .int(archiveAfterMs), "title": .string("After " + String(archiveAfterMs / 60_000) + " minutes")])
    }
    let r = env.call("settings", "register", [
      "id": .string(Self.ns), "title": "Tabs", "icon": "sf:square.on.square", "order": 10,
      "controls": .array(([
        ["key": "archiveAfterMs", "type": "choice", "title": "Archive Today tabs",
         "subtitle": "Today tabs you haven't used for this long move to the Library. Pinned tabs and favorites stay. ⇧⌘T brings the last one back.",
         "options": .array(options), "default": .int(archiveAfterMs)],
        ["key": "suspendAfterMinutes", "type": "number", "title": "Unload idle tabs",
         "subtitle": "Background tabs unused for this long free their memory and reload when you come back. Tabs playing audio never unload.",
         "min": 0, "max": 240, "step": 5, "unit": "min", "labels": [["value": 0, "title": "Never"]], "default": .int(suspendAfterMs / 60_000)],
        ["key": "groupLinks", "type": "toggle", "title": "Group ⌘-clicked links",
         "subtitle": "⌘-clicking a link opens it in the background, in a group with the tab it came from. Off: a plain background tab.",
         "default": .bool(groupLinks)],
        ["key": "batterySaver", "type": "toggle", "title": "Battery saver",
         "subtitle": "On battery or in Low Power Mode, idle tabs unload after 1 minute, videos in background tabs pause, and new pages don't play videos by themselves. Music keeps playing.",
         "default": .bool(batterySaver)],
        ["key": "keepActive", "type": "list", "title": "Always keep active",
         "subtitle": "Tabs of these sites never unload when idle and their media is never paused. Unload Space (Control-Command-U) still unloads them.",
         "items": .array(keepActive.map { h -> Value in ["id": .string(h), "title": .string(h), "icon": "sf:bolt", "buttons": [["id": "remove", "title": "Remove"]]] }),
         "empty": "No sites yet. Right-click a tab and choose “Keep Site Active”."],
        ["key": "sameTabInWindows", "type": "toggle", "title": "Let a tab open in two windows",
         "subtitle": "On: picking a tab that's open in another window moves it to this one, and the other window says where it went. Off: den brings forward the window that has it.",
         "default": .bool(sameTabInWindows)],
      ] as [Value]) + tidyControls()),
    ])
    guard !r.isErr, !settingsSubscribed else { return }  // an older host without Settings; subscribed once
    settingsSubscribed = true
    let v = env.call("settings", "get", ["id": .string(Self.ns)])
    applySetting("archiveAfterMs", v["archiveAfterMs"])
    applySetting("suspendAfterMinutes", v["suspendAfterMinutes"])
    applySetting("groupLinks", v["groupLinks"])
    applySetting("batterySaver", v["batterySaver"])
    applySetting("sameTabInWindows", v["sameTabInWindows"])
    applySetting("tidy", v["tidy"])
    applySetting("tidyAuto", v["tidyAuto"])
    applySetting("autoGroup", v["autoGroup"])
    env.on("settings.changed") { [self] v in if v.s("id") == Self.ns { applySetting(v.s("key"), v["value"]) } }
    env.on("settings.action") { [self] v in
      guard v.s("id") == Self.ns, v.s("key") == "keepActive", v.s("button") == "remove" else { return }
      keepActive.removeAll { $0 == v.s("item") }
      saveEnergy()
      registerSettings()
      renderAll()
    }
  }

  func applySetting(_ key: String, _ v: Value) {
    if key == "tidy" || key == "tidyAuto" || key == "autoGroup" {
      applyTidySetting(key, v)
      return
    }
    if key == "groupLinks" {
      if let b = v.bool { groupLinks = b }
      return
    }
    if key == "sameTabInWindows" {
      if let b = v.bool { sameTabInWindows = b }
      return
    }
    if key == "batterySaver" {
      guard let b = v.bool, b != batterySaver else { return }
      batterySaver = b
      saveEnergy()
      applySaver()
      return
    }
    guard let n = v.int ?? v.double.map({ Int64($0) }) else { return }
    let before = (archiveAfterMs, suspendAfterMs)
    switch key {
    case "archiveAfterMs": archiveAfterMs = max(0, n)
    case "suspendAfterMinutes": suspendAfterMs = max(0, n) * 60_000
    default: return
    }
    guard before != (archiveAfterMs, suspendAfterMs) else { return }
    env.call("storage", "set", ["ns": .string(Self.ns), "key": "settings", "value": ["archiveAfterMs": .int(archiveAfterMs), "suspendAfterMs": .int(suspendAfterMs)]])
  }

  // MARK: - Idle: auto-archive and suspension

  func tick() {
    autoTidy()
    let now = env.now()
    var archived = 0
    if archiveAfterMs > 0 {
      for sid in spaceIds {
        for id in todayTabs(sid) where id != selected[sid] {
          guard let t = tabs[id], now - t.lastActive > archiveAfterMs, !t.audio else { continue }
          archiveTab(id, space: sid)
          archived += 1
        }
      }
    }
    // Media nobody sees or hears pauses first, so its tab can unload below.
    pauseBackgroundMedia(userIdle: (env.call("app", "state")["idleSeconds"].double ?? 0) >= Self.idlePauseSeconds)
    if effectiveSuspendAfterMs > 0 {
      // Idle discard, counted in den-frontmost time, never for the most recently used tabs. The
      // host refuses what must stay (on screen, media, PiP, camera/mic, unsaved input) and says
      // why; such a tab is asked again on the next tick.
      for id in idleCandidates() {
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
    if let p = shown as String?, !p.isEmpty, p != id, tabs[p] != nil { tabs[p]?.lastActive = env.now(); fgLastUse[p] = fgNow() }
    shown = id ?? ""
    // The normal window's content (named only while a private window is in front).
    var show: Value
    var title: Value
    if let id, let sid = splitOf(id), let sp = splits[sid] {
      show = ["panes": .array(sp.children.map { .string($0) }), "orientation": .string(sp.layout), "ratios": .array(sp.showRatios), "focus": .string(id)]
      title = ["title": .string(tabs[id]?.displayTitle ?? "den")]
    } else if let id {
      show = ["panes": [.string(id)]]
      title = ["title": .string(tabs[id]?.displayTitle ?? "den")]
    } else {
      show = ["panes": []]
      title = ["title": .string(spaceName(currentSpace))]
    }
    if activeWin != normalWin {
      show.put("window", .string(normalWin))
      title.put("window", .string(normalWin))
    }
    env.call("content", "show", show)
    env.call("window", "setTitle", title)
    renderGlobal()
  }

  func renderHeader() { eachWindow { renderHeader(tab: shownTabForRender, url: { tabs[$0]?.url }) } }

  /// The nav bar and URL pill for the tab a window shows (`url` finds a normal or private tab's URL).
  func renderHeader(tab: String?, url: (String) -> String?) {
    var st: Value = .null
    var text = ""
    let u = tab.flatMap { url($0) }
    if let id = tab, let u {
      st = env.call("webviews", "get", ["id": .string(id)])
      text = URLs.display(u)
    }
    uiSet(["slot": "sidebar.header", "tree": ["type": "list", "id": "tabs.header", "spacing": 0, "children": [
      ["type": "navBar", "id": "tabs.nav", "canGoBack": .bool(st.b("canGoBack")), "canGoForward": .bool(st.b("canGoForward")), "loading": .bool(st.b("loading"))],
      ["type": "urlPill", "id": "tabs.url", "text": .string(text), "secure": .bool(Text.hasPrefix(u ?? "", "https:")),
       "loading": .bool(st.b("loading")), "progress": .double(st["progress"].double ?? 0), "placeholder": "Search or Enter URL…",
       "buttons": .array((pillButtons[tab ?? ""] ?? []).flatMap { $0.1 }), "webview": .str(tab), "menu": .array(ptabs[tab ?? ""] != nil ? Array(pillMenu().prefix(1)) : pillMenu())],
    ]]])
  }

  func renderFavorites() { eachWindow { renderFavoritesNow() } }

  func renderFavoritesNow() {
    let sel = shownTabForRender
    uiSet(["slot": "sidebar.favorites", "tree": ["type": "grid", "id": "tabs.favorites", "children": .array(favorites.compactMap { fid in
      // A favorited split shows as its first tab's tile.
      let id = splits[fid]?.children.first ?? fid
      guard let t = tabs[id] else { return nil }
      var tile: Value = ["type": "favoriteTile", "id": .string(id), "icon": .string(t.icon), "title": .string(t.displayTitle), "selected": .bool(id == sel),
                         "audio": .bool(t.audio), "muted": .bool(t.muted), "dropInto": true,
                         "hoverIntent": .int(Self.tileCardDelayMs)]
      if !badges.isEmpty, let b = badges[URLs.host(t.url)] { tile.put("badge", .string(b)) }
      return tile
    })]])
  }

  func row(_ id: String, _ sid: String, box: Box) -> Value {
    let t = tabs[id]!
    var r: Value = ["type": "tabRow", "id": .string(id), "title": .string(t.displayTitle), "icon": .string(t.icon), "selected": .bool(selOf(sid) == id),
                    "audio": .bool(t.audio), "muted": .bool(t.muted), "drift": .bool(kind(of: box) != "today" && t.drift),
                    "closeTitle": .string(kind(of: box) == "today" ? "Archive Tab" : "Close Tab"),
                    "dropInto": true, "dropIntoIcon": "sf:rectangle.split.2x1",
                    "hoverIntent": .int(Self.rowCardDelayMs)]
    if let m = t.media {
      let acts = m.a("acts")
      r.put("media", ["paused": .bool(m.b("paused")), "next": .bool(acts.contains("nexttrack")), "previous": .bool(acts.contains("previoustrack"))])
    }
    if editing == id { r.put("editing", true) }
    if multi.contains(id) { r.put("highlighted", true) }
    return r
  }

  func node(_ id: String, _ sid: String, parent: Box) -> Value? {
    if let f = folders[id] {
      if !f.live.isEmpty { return liveFolders.node(f) }
      let group = kind(of: parent) == "today"
      var menu: [Value] = [["id": "renameFolder", "title": group ? "Rename Group…" : "Rename Folder…", "icon": "sf:pencil"]]
      menu += iconMenuItems(hasIcon: f.icon != nil)
      if !group { menu.append(["id": "newFolder", "title": "New Folder Inside", "icon": "sf:folder.badge.plus"]) }
      if group { menu.append(["id": "newTabInFolder", "title": "New Tab in Group", "icon": "sf:plus", "key": .string(Self.chord("tabs.key.newTabInFolder")), "keyFor": "tabs.key.newTabInFolder"]) }
      menu.append(["separator": true])
      if group { menu.append(["id": "ungroup", "title": "Ungroup Tabs", "icon": "sf:rectangle.stack.badge.minus"]) }
      menu.append(["id": "deleteFolder", "title": group ? "Close Group…" : "Delete Folder…", "icon": "sf:trash"])
      var v: Value = ["type": "folder", "id": .string(id), "title": .string(f.title), "icon": .string(folderIcon(f, group: group)), "open": .bool(f.open),
                      "editing": .bool(editing == id), "hoverIntent": .int(Self.rowCardDelayMs), "children": .array(f.children.compactMap { node($0, sid, parent: .folder(id)) }), "menu": .array(menu)]
      // Dia's group look in Today: a lighter rounded panel around the header and its tabs.
      if group { v.put("style", "group") }
      // Collapsed, the folder still shows its active tab under the header (Dia 1.28).
      if !f.open, let sel = selOf(sid), tabsIn(folder: id).contains(sel) {
        var shown: Value? = nil
        if let s = splitOf(sel) { shown = node(s, sid, parent: .folder(id)) } else if tabs[sel] != nil { shown = row(sel, sid, box: .folder(id)) }
        if let shown { v.put("closedChildren", .array([shown])) }
      }
      if naming.contains(id) { v.put("pending", true) }
      if revealing.contains(id) { v.put("reveal", true) }
      return v
    }
    if let sp = splits[id] {
      // One sidebar item: the split's tabs side by side (Arc §7). Clicking a pane's segment focuses it.
      let sel = selOf(sid)
      let on = sp.children.contains(sel ?? "")
      return ["type": "splitRow", "id": .string(id), "selected": .bool(on), "layout": .string(sp.layout), "menu": .array(splitMenu(id)),
              "hoverIntent": .int(Self.rowCardDelayMs),
              "panes": .array(sp.children.compactMap { c -> Value? in
                guard let t = tabs[c] else { return nil }
                return ["id": .string(c), "title": .string(t.displayTitle), "icon": .string(t.icon), "selected": .bool(c == sel)]
              })]
    }
    guard tabs[id] != nil else { return nil }
    return row(id, sid, box: parent)
  }

  func splitMenu(_ id: String) -> [Value] {
    let l = splits[id]?.layout ?? "horizontal"
    var m: [Value] = []
    if l != "horizontal" { m.append(["id": .string("layout:" + id + ":horizontal"), "title": "Side by Side", "icon": "sf:rectangle.split.2x1"]) }
    if l != "vertical" { m.append(["id": .string("layout:" + id + ":vertical"), "title": "Top and Bottom", "icon": "sf:rectangle.split.1x2"]) }
    if l != "grid" && (splits[id]?.children.count ?? 0) > 2 { m.append(["id": .string("layout:" + id + ":grid"), "title": "Grid", "icon": "sf:rectangle.split.2x2"]) }
    m.append(["separator": true])
    m.append(["id": .string("separate:" + id), "title": "Separate All Tabs", "icon": "sf:rectangle.split.2x1.slash"])
    return m
  }

  func renderPage(_ sid: String) {
    eachWindow { renderPageNow(sid) }
  }

  func renderPageNow(_ sid: String) {
    guard let page = pageIndex(sid) else { return }
    let p: Value = .int(Int64(page))
    uiSet(["slot": "sidebar.pinned", "page": p, "tree": ["type": "list", "id": .string("tabs.pinned:" + sid),
      "children": .array((pinned[sid] ?? []).compactMap { node($0, sid, parent: .pinned(sid)) })]])
    let list = today[sid] ?? []
    var kids: [Value] = [
      todayDivider(sid, empty: list.isEmpty),
      ["type": "newTabRow", "id": .string("tabs.newtab:" + sid), "title": "New Tab"],
    ]
    kids += list.compactMap { node($0, sid, parent: .today(sid)) }
    uiSet(["slot": "sidebar.today", "page": p, "tree": ["type": "list", "id": .string("tabs.today:" + sid), "children": .array(kids)]])
  }

  /// Every item that has a shortcut shows it on the right; holding ⌥ swaps in the alternates
  /// (Copy Link ↔ Copy Link as Markdown, Archive Tab ↔ Close Other Tabs, Close Tabs Below ↔
  /// Above; dia-ui-spec §4).
  /// The menu a right-click on tab `id` (row or favorite tile) shows.
  func contextMenu(_ id: String) -> [Value] {
    guard let (b, _) = locate(id) else { return [] }
    if case .split = b { return [] }
    return menu(for: id, box: b)
  }

  func menu(for id: String, box: Box) -> [Value] {
    guard let t = tabs[id] else { return [] }
    func item(_ id: String, _ title: String, _ icon: String, _ event: String? = nil) -> Value {
      var v: Value = ["id": .string(id), "title": .string(title), "icon": .string(icon)]
      if let e = event, !Self.chord(e).isEmpty { v.put("key", .string(Self.chord(e))) }
      // The menu bar's current chord (a [shortcuts] remap included) wins over the default.
      if let e = event { v.put("keyFor", .string(Self.menuRef(e))) }
      return v
    }
    func alt(_ v: Value) -> Value {
      var v = v
      v.put("alternate", true)
      return v
    }
    let k = kind(of: box)
    var m: [Value] = [item("copy", "Copy Link", "sf:link", "tabs.key.copy"), alt(item("copyMarkdown", "Copy Link as Markdown", "sf:link", "copyMarkdown")),
                      item("duplicate", "Duplicate", "sf:plus.square.on.square", "duplicate")]
    if URLs.isWeb(t.url) { m.insert(item("share", "Share…", "sf:square.and.arrow.up", "share"), at: 2) }
    // Favorites are icon tiles with no title to edit in place.
    if box != .favorites { m.append(item("rename", "Rename…", "sf:pencil", "rename")) }
    m += iconMenuItems(hasIcon: t.customIcon != nil)
    if t.audio || t.muted {
      m.append(t.muted ? item("unmute", "Unmute Tab", "sf:speaker.wave.2") : item("mute", "Mute Tab", "sf:speaker.slash"))
    }
    if k != "today" && t.drift {
      m.append(item("reset", "Go Back to Pinned URL", "sf:arrow.uturn.backward"))
      m.append(item("replacePinned", "Replace Pinned URL with Current", "sf:pin"))
    }
    m.append(["separator": true])
    if siteOf(id) != nil {
      var keep = item("keepActive", "Keep Site Active", "sf:bolt")
      keep.put("checked", .bool(isKeptActive(id)))
      m.append(keep)
    }
    m.append(["separator": true])
    if k == "today" { m.append(item("pin", "Pin Tab", "sf:pin", "tabs.key.pin")) }
    if k == "pinned" { m.append(item("unpin", "Unpin Tab", "sf:pin.slash", "tabs.key.pin")) }
    if k != "favorite" && favorites.count < Self.maxFavorites { m.append(item("favorite", "Add to Favorites", "sf:star")) }
    if k == "favorite" { m.append(item("unpin", "Remove from Favorites", "sf:star.slash")) }
    if case .folder = box {
      m.append(item("removeFromFolder", k == "today" ? "Remove from Group" : "Remove from Folder", "sf:rectangle.stack.badge.minus"))
    } else if k != "favorite" {
      m.append(item("newFolder", k == "today" ? "New Group with Tab" : "New Folder with Tab", "sf:folder.badge.plus", "tabs.key.newFolder"))
    }
    let here = space(of: box)
    for s in spaces where s.s("id") != here && k != "favorite" {
      m.append(["id": .string("move:" + s.s("id")), "title": .string("Move to " + s.s("name")), "icon": "sf:arrow.right.square"])
    }
    m.append(["separator": true])
    m.append(item("close", k == "today" ? "Archive Tab" : "Close Tab", "sf:xmark", "tabs.key.close"))
    if k == "today" {
      m.append(alt(item("closeOthers", "Close Other Tabs", "sf:xmark.square", "tabs.key.closeOthers")))
      m.append(item("closeBelow", "Close Tabs Below", "sf:arrow.down.to.line"))
      m.append(alt(item("closeAbove", "Close Tabs Above", "sf:arrow.up.to.line")))
    }
    return m
  }

  /// Menu bar items (docs/shortcuts.md ids) for tab-menu actions that aren't `keys.bind` events.
  static func menuRef(_ event: String) -> String {
    switch event {
    case "copyMarkdown": return "edit.copyMarkdown"
    case "duplicate": return "tabs.duplicate"
    case "rename": return "tabs.rename"
    case "share": return "file.share"
    default: return event
    }
  }

  /// The chord each tab action is bound to, for menus (the same table `bindKeys` binds).
  static func chord(_ event: String) -> String {
    for (c, e, _, _) in binds where e == event { return c }
    if event == "copyMarkdown" { return "cmd+opt+shift+c" }  // the Edit menu's Copy URL as Markdown
    return ""
  }

  func folderIcon(_ f: Folder, group: Bool) -> String {
    if let icon = f.icon { return icon }
    guard group else { return "sf:folder" }
    // A group shows its first tab's icon (Dia's resting state).
    for c in tabsIn(folder: f.id) { if let t = tabs[c] { return t.icon } }
    return "sf:folder"
  }

  // MARK: - Input

  static let binds: [(String, String, String, String)] = [
      ("cmd+w", "tabs.key.close", "Archive Tab", "File"),
      ("cmd+opt+w", "tabs.key.closeOthers", "Close Other Tabs", "File"),
      ("cmd+opt+t", "tabs.key.newTabInFolder", "New Tab in Group", "File"),
      ("cmd+ctrl+n", "tabs.key.newFolder", "New Folder with Selected Tabs", "Tabs"),
      ("cmd+shift+t", "tabs.key.reopen", "Restore Last Closed Tab", "File"),
      ("cmd+d", "tabs.key.pin", "Pin/Unpin Tab", "Tabs"),
      ("cmd+shift+k", "tabs.key.clear", "Clear Unpinned Tabs", "Tabs"),
      ("cmd+ctrl+u", "tabs.key.unloadSpace", "Unload Space", "Spaces"),
      ("ctrl+shift+t", "tabs.key.tidy", "Tidy Tabs", "Tabs"),
      ("ctrl+tab", "tabs.key.recent", "Switch to Recent Tab", "Tabs"),
      ("ctrl+shift+tab", "tabs.key.recentBack", "Switch to Oldest Recent Tab", "Tabs"),
      // Arc's ⌥⌘↑/↓ first (shown in the menu), then Safari's and Chrome's ⌘⇧[ / ⌘⇧] (docs/shortcuts.md).
      ("cmd+opt+up", "tabs.key.prevTab", "Previous Tab", "Tabs"),
      ("cmd+opt+down", "tabs.key.nextTab", "Next Tab", "Tabs"),
      ("cmd+shift+[", "tabs.key.prevTab", "Previous Tab", "Tabs"),
      ("cmd+shift+]", "tabs.key.nextTab", "Next Tab", "Tabs"),
      ("ctrl+z", "tabs.key.undo", "Undo Sidebar Action", "Tabs"),
      ("cmd+[", "tabs.key.back", "Back", "History"),
      ("cmd+]", "tabs.key.forward", "Forward", "History"),
      // ⌘←/⌘→ too; a text field being edited keeps them (the host stands these aside there).
      ("cmd+left", "tabs.key.back", "Back", "History"),
      ("cmd+right", "tabs.key.forward", "Forward", "History"),
      ("cmd+y", "tabs.key.library", "Show Library", "History"),
      ("cmd+shift+l", "tabs.key.library", "Show Library", "History"),
      ("cmd+r", "tabs.key.reload", "Reload Page", "View"),
      ("cmd+.", "tabs.key.stop", "Stop", "View"),
      ("cmd+s", "tabs.key.sidebar", "Show/Hide Sidebar", "View"),
      ("cmd+shift+c", "tabs.key.copy", "Copy URL", "Edit"),
  ]

  func bindKeys() {
    for (c, e, t, m) in Self.binds { env.call("keys", "bind", ["chord": .string(c), "event": .string(e), "title": .string(t), "menu": .string(m)]) }
    for n in 1...9 {
      env.call("keys", "bind", ["chord": .string("cmd+" + String(n)), "event": "tabs.key.nth", "title": .string(n == 9 ? "Last Tab" : "Tab " + String(n)),
                                "menu": "Tabs", "payload": .int(Int64(n))])
    }
  }

  func subscribe() {
    env.on("ui.action") { [self] v in action(v.s("id"), v.s("action"), v["value"]) }
    env.on("spaces.current") { [self] v in
      // A window coming forward already shows its place: only record the space.
      if activating { currentSpace = v.s("id"); return }
      if let p = shownTab() { tabs[p]?.lastActive = env.now(); fgLastUse[p] = fgNow() }
      currentSpace = v.s("id")
      blankWin = false
      showSelected()
    }
    subscribeWindows()
    env.on("spaces.changed") { [self] v in spacesChanged(v.a("spaces")) }
    env.on("content.focus") { [self] v in splitFocused(v.s("id")) }
    env.on("content.ratios") { [self] v in splitResized(v) }
    env.on("tabs.key.close") { [self] _ in closeFromKey() }
    env.on("tabs.key.reopen") { [self] _ in
      // A window closed after the last tab comes back first (then ⇧⌘T goes on with tabs).
      if lastClosedWasWindow, !closedWindows.isEmpty { reopenWindow(); return }
      // A peek closed after the last archived tab is reopened first (Arc §6).
      if env.call("peek", "reopen", ["after": .int(archive.first?.i("closedAt") ?? 0)])["ok"] == true { return }
      if let e = archive.first { _ = restore(e.s("id")) }
    }
    env.on("tabs.key.pin") { [self] _ in
      // Keys about the spaces' tabs do nothing in a private window.
      guard activePrivate == nil, let id = selectedId else { return }
      setKind(id, kindOf(id) == "today" ? "pinned" : "today", toast: true)
    }
    env.on("tabs.key.clear") { [self] _ in if activePrivate == nil { clearToday(currentSpace) } }
    env.on("tabs.key.closeOthers") { [self] _ in if activePrivate == nil, let id = selectedId { closeMany(id, "others") } }
    env.on("tabs.key.newTabInFolder") { [self] _ in if activePrivate == nil { newTabInFolder(nil) } }
    env.on("tabs.key.newFolder") { [self] _ in if activePrivate == nil { folderFromSelection() } }
    env.on("app.active") { [self] v in
      setActive(v.b("active"))
      if !v.b("active") { closeBlankTabs() }
    }
    env.on("ai.result") { [self] v in
      nameArrived(v)
      tidyArrived(v)
      autoGroupArrived(v)
    }
    env.on("tabs.key.undo") { [self] _ in _ = undo() }
    env.on("spaces.library") { [self] _ in openLibrary() }
    env.on("tabs.key.recent") { [self] _ in
      if activePrivate == nil, let id = mru.first(where: { $0 != selectedId && tabs[$0] != nil }) { select(id) }
    }
    env.on("tabs.key.nth") { [self] v in
      let list = activePrivate.map { privates[$0]?.tabs ?? [] } ?? order(currentSpace, onlyVisible: true)
      let n = Int(v["payload"].int ?? 1)
      guard !list.isEmpty else { return }
      if n == 9 { select(list[list.count - 1]) } else if n - 1 < list.count { select(list[n - 1]) }
    }
    env.on("tabs.key.recentBack") { [self] _ in
      // Arc's tab switcher backward from the current tab wraps to the least recent one.
      if activePrivate == nil, let id = mru.last(where: { $0 != selectedId && tabs[$0] != nil }) { select(id) }
    }
    env.on("tabs.key.library") { [self] _ in _ = handle("library", ["open": .bool(!(libraryOpen && librarySection == "archive"))]) }
    env.on("tabs.key.prevTab") { [self] _ in stepTab(-1) }
    env.on("tabs.key.nextTab") { [self] _ in stepTab(1) }
    env.on("tabs.key.back") { [self] _ in web("back") }
    env.on("tabs.key.forward") { [self] _ in web("forward") }
    env.on("tabs.key.reload") { [self] _ in web("reload") }
    env.on("tabs.key.stop") { [self] _ in web("stop") }
    env.on("tabs.key.sidebar") { [self] _ in env.call("window", "toggleSidebar") }
    env.on("tabs.key.copy") { [self] _ in copyURL() }
    for e in ["webviews.title", "webviews.url", "webviews.favicon", "webviews.progress", "webviews.state", "webviews.audio", "webviews.muted"] {
      env.on(e) { [self] v in webEvent(e, v) }
    }
    // Now-playing media: the row's hover playback buttons.
    env.on("webviews.nowPlaying") { [self] v in
      let id = v.s("id")
      guard tabs[id] != nil else { return }
      var m: Value?
      if !v["now"].isNull { m = v["now"] }
      // Only what the row shows: a new title or artwork doesn't re-render the sidebar.
      func shape(_ x: Value?) -> Value { x.map { ["paused": .bool($0.b("paused")), "acts": $0["acts"]] } ?? .null }
      let changed = shape(tabs[id]?.media) != shape(m)
      tabs[id]?.media = m
      guard changed else { return }
      if favorites.contains(id) { renderFavorites() } else if let sid = spaceOf(id) { renderPage(sid) }
    }
    // The picture-in-picture window's return button (host `media` service): its tab, in its
    // space and window.
    env.on("media.backToTab") { [self] v in if tabs[v.s("webview")] != nil || ptabs[v.s("webview")] != nil { select(v.s("webview")) } }

    // target=_blank and window.open (foreground); ⌘-click / middle-click / "Open Link in New Tab"
    // come with `background: true` (⌘⇧-click: false).
    startPopups()
    env.on("webviews.newWindow") { [self] v in
      // `webview`: a pop-up the host already made for the page (window.open / target=_blank from
      // a click; Popups.swift). It keeps `window.opener`, so it opens as a selected tab right
      // after its opener, and closes back to it.
      if let adopt = v.sOpt("webview") {
        openPopupTab(adopt, url: v.s("url"), opener: v.s("id"))
        return
      }
      // From a private tab: another private tab in the same window.
      if let w = privateWindow(of: v.s("id")) {
        _ = openPrivate(v.s("url"), in: w, background: v.b("background"))
        return
      }
      // A link click (⌘ / middle / ⌘⇧) carries `background`; from a Today tab it groups with
      // its source. target=_blank and window.open don't, and open a plain tab.
      if !v["background"].isNull, openFromLink(v.s("url"), source: v.s("id"), background: v.b("background")) != nil { return }
      _ = open(v.s("url"), space: spaceOf(v.s("id")) ?? currentSpace, kind: "today", background: v.b("background"), index: nil)
    }
    // Links, URLs and files dropped on the sidebar or a page: today tabs, the last one selected.
    env.on("window.dropURLs") { [self] v in
      let urls = v.a("urls").compactMap { $0.string }
      if let w = activePrivate {
        for (k, u) in urls.enumerated() { _ = openPrivate(u, in: w, background: k < urls.count - 1) }
        return
      }
      for (k, u) in urls.enumerated() { _ = open(u, space: currentSpace, kind: "today", background: k < urls.count - 1, index: nil) }
    }
    env.on("app.openURL") { [self] v in openExternal(v.a("urls")) }
  }

  func shownTab() -> String? { shown.isEmpty ? nil : shown }

  /// Mutes or unmutes a tab's page (the speaker on its row or tile, or its menu).
  func toggleMute(_ id: String) {
    guard let t = tabs[id] else { return }
    env.call("webviews", "setMuted", ["id": .string(id), "muted": .bool(!t.muted)])
  }

  /// A click in (or Ctrl-Shift-N to) another pane of the shown split selects that pane's tab,
  /// without re-laying out the content.
  /// A split's gap was dragged (or double-clicked back to equal): keep the sizes with the split,
  /// for its panes in this order and layout. Every window showing it uses them.
  func splitResized(_ v: Value) {
    let panes = v.a("panes").compactMap { $0.string }
    guard let first = panes.first, let sid = splitOf(first), var sp = splits[sid], sp.children == panes, sp.layout == v.s("orientation") else { return }
    sp.ratios = v.a("ratios").compactMap { $0.double }
    sp.ratiosKey = sp.ratios.isEmpty ? "" : sp.key
    splits[sid] = sp
    saveSoon()
  }

  func splitFocused(_ id: String) {
    guard tabs[id] != nil, let sid = splitOf(id), splitOf(shown) == sid, selectedId != id else { return }
    let space = spaceOf(id) ?? currentSpace
    let previous = selected[space]
    selected[space] = id
    shown = id
    tabs[id]?.lastActive = env.now()
    fgLastUse[id] = fgNow()
    mru.removeAll { $0 == id }
    mru.insert(id, at: 0)
    setTitle(tabs[id]?.displayTitle ?? "den")
    renderPage(space)
    renderGlobal()
    saveSoon()
    env.emit("tabs.selected", ["id": .string(id), "previous": .str(previous)])
  }

  func splitMenuPicked(_ item: String) -> Bool {
    if Text.hasPrefix(item, "separate:") {
      unsplit(Text.dropPrefix(item, "separate:"))
      return true
    }
    if Text.hasPrefix(item, "layout:") {
      // layout:<splitId>:<layout>
      let rest = Array(Text.dropPrefix(item, "layout:").utf8)
      guard let colon = rest.lastIndex(of: 58) else { return true }
      let sid = String(decoding: rest[..<colon], as: UTF8.self), layout = String(decoding: rest[(colon + 1)...], as: UTF8.self)
      guard splits[sid] != nil else { return true }
      checkpoint()
      splits[sid]!.layout = layout
      showSelected()
      changed(spaceOf(sid) ?? currentSpace)
      return true
    }
    return false
  }

  func web(_ method: String) {
    guard let id = frontTab else { return }
    env.call("webviews", method, ["id": .string(id)])
  }

  func stepTab(_ d: Int) {
    if let w = activePrivate {
      let list = privates[w]?.tabs ?? []
      guard let cur = privates[w]?.selected, let i = list.firstIndex(of: cur) else { if let f = list.first { selectPrivate(f) }; return }
      if i + d >= 0 && i + d < list.count { selectPrivate(list[i + d]) }
      return
    }
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
    if let w = activePrivate {
      if let id = privates[w]?.selected { closePrivate(id) }
      return
    }
    if let id = selectedId { close(id) }
  }

  func copyURL() {
    guard let id = frontTab, let t = tabs[id] ?? ptabs[id] else { return }
    env.call("app", "copy", ["text": .string(t.url)])
    env.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": .string(Copied.link(t.url)), "icon": "sf:link"]])
  }

  /// The URL pill's context menu: Paste and Go / Paste and Search (named by the host for what's on
  /// the clipboard when the menu opens), then the page's link.
  func pillMenu() -> [Value] {
    var m: [Value] = [["id": "pasteGo", "title": "Paste and Search", "titleURL": "Paste and Go", "icon": "sf:doc.on.clipboard", "paste": true]]
    guard let id = selectedId, let t = tabs[id], URLs.isWeb(t.url) else { return m }
    var copy: Value = ["id": "copy", "title": "Copy Link", "icon": "sf:link"]
    if !Self.chord("tabs.key.copy").isEmpty { copy.put("key", .string(Self.chord("tabs.key.copy"))) }
    var md: Value = ["id": "copyMarkdown", "title": "Copy Link as Markdown", "icon": "sf:link", "alternate": true]
    if !Self.chord("copyMarkdown").isEmpty { md.put("key", .string(Self.chord("copyMarkdown"))) }
    m.append(["separator": true])
    m.append(copy)
    m.append(md)
    m.append(["id": "share", "title": "Share…", "icon": "sf:square.and.arrow.up"])
    return m
  }

  /// Paste and Go / Paste and Search in the selected tab (a new tab when none is selected), through
  /// the command bar's own address-or-search rule and engine.
  func pasteAndGo() {
    let p = env.call("app", "pasteboard")
    guard let text = p["text"].string, !text.isEmpty else { return }
    let mode = selectedId == nil ? "new" : "edit"
    if env.call("commands", "paste", ["text": .string(text), "mode": .string(mode)]).isErr, p.b("url") {
      // No command bar plugin: an address still opens.
      if let id = selectedId { _ = handle("navigate", ["id": .string(id), "url": .string(text)]) } else { _ = open(text, space: currentSpace, kind: "today", background: false, index: nil) }
    }
  }

  /// macOS's share sheet (AirDrop, Messages…) for a tab's page, next to `anchor`.
  func share(_ id: String, anchor: String) {
    guard let t = tabs[id], URLs.isWeb(t.url) else { return }
    env.call("app", "share", ["url": .string(t.url), "title": .string(t.displayTitle), "anchor": .string(anchor)])
  }

  func openCommandBar(_ mode: String) {
    var args: Value = ["mode": .string(mode)]
    if mode == "edit", let id = frontTab, let t = tabs[id] ?? ptabs[id] { args.put("query", .string(t.url)) }
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
    if ptabs[id] != nil { return privateWebEvent(e, v) }
    guard tabs[id] != nil else { return }
    let isSelected = id == selectedId || isShownElsewhere(id)
    switch e {
    case "webviews.title":
      tabs[id]?.title = v.s("title")
      if id == selectedId { setTitle(tabs[id]!.displayTitle) }
      // A group waiting for its new tab's title can ask for a name now.
      if let fid = pendingNames.removeValue(forKey: id) { askName(fid) }
    case "webviews.url":
      tabs[id]?.url = v.s("url")
      // A new tab in a pinned folder (⌥⌘T) takes its first real page as its pinned URL.
      if tabs[id]?.pinnedUrl == "about:blank", v.s("url") != "about:blank" { tabs[id]?.pinnedUrl = v.s("url") }
    case "webviews.favicon": if let u = v.sOpt("url") { tabs[id]?.favicon = u }
    case "webviews.audio": tabs[id]?.audio = v.b("playing")
    case "webviews.muted": tabs[id]?.muted = v.b("muted")
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
    guard src != dst, tabs[src] != nil || folders[src] != nil || splits[src] != nil, let (tb, ti) = locate(dst) else { return }
    // A split never goes inside another split.
    if splits[src] != nil, case .split = tb { return }
    var box = tb
    var index = pos == "after" ? ti + 1 : ti
    if pos == "into", let f = folders[dst] {
      // A live folder's rows come from its connection: tabs can't be dropped into it.
      guard f.live.isEmpty else { return }
      box = .folder(dst)
      index = folders[dst]!.children.count
    }
    if pos == "into", let sp = splits[dst] {
      // A tab dropped on a split row joins it as its last pane (Arc: drag a tab onto another).
      guard tabs[src] != nil, !sp.children.contains(src) else { return }
      _ = split(sp.children + [src], layout: sp.layout, focus: src)
      return
    }
    if pos == "into", tabs[dst] != nil {
      // Onto a tab (Arc, Jan 2024): the two become a split where the target lives, the dragged
      // tab as the right pane and focused. A dragged split takes the tab in instead.
      if tabs[src] != nil, splitOf(src) == nil || splitOf(src) != splitOf(dst) {
        _ = split([dst, src], layout: "horizontal", focus: src)
      } else if let sp = splits[src], splitOf(dst) == nil {
        _ = split(sp.children + [dst], layout: sp.layout, focus: dst)
      }
      return
    }
    if folders[src] != nil {
      // Folders live in the pinned section or Today, never in favorites or inside themselves.
      if box == .favorites { return }
      if case let .folder(f) = box, f == src || contains(folder: src, f) { return }
    }
    if box == .favorites && kindOf(src) != "favorite" && favorites.count >= Self.maxFavorites { return }
    if let (sb, si) = locate(src), sb == box, si < index { index -= 1 }
    checkpoint()
    place(src, box, index: index)
  }

  func action(_ id: String, _ action: String, _ value: Value) {
    if id == Self.popupButton { allowPopups(value.s("webview")); return }
    if privateAction(id, action, value) { return }
    if liveFolders.action(id, action, value) { return }
    if id == Self.iconPickerId { iconPickerAction(action, value); return }
    if tabs[id] != nil {
      switch action {
      case "pickIcon": openIconPicker(id)
      case "click":
        // ⌘-click / ⇧-click pick more tabs (⌃⌘N groups them); a plain click selects.
        if pick(id, modifiers: value.a("modifiers")) { return }
        clearMulti()
        select(id)
      case "hover": preview(id)
      case "doubleClick": if kindOf(id) != "favorite" { beginRename(id) }
      case "rename": endRename(id, value.s("title"))
      case "renameCancel": endRename(id, nil)
      case "close": close(id)
      case "reset": reset(id)
      case "mute": toggleMute(id)
      case "media":
        // The row's hover playback buttons (toggle / next / previous).
        env.call("webviews", "mediaControl", ["id": .string(id), "action": .string(value.s("action"))])
      case "reorder": handleReorder(value)
      case "dropOnSpace": moveToSpace(id, value.s("spaceId"))
      case "dropOnContent":
        if let sel = selectedId, sel != id {
          let side = value.s("side")
          env.call("peek", "split", ["ids": side == "left" ? [.string(id), .string(sel)] : [.string(sel), .string(id)], "layout": "horizontal"])
        }
      case "menu": menuPicked(id, value.string ?? "")
      // Rows carry no menu (hundreds of rows would each hold one): it's built on right-click.
      case "contextMenu": env.call("ui", "menu", ["id": .string(id), "items": .array(contextMenu(id))])
      default: break
      }
      return
    }
    if folders[id] != nil {
      switch action {
      case "pickIcon": openIconPicker(id)
      case "hover": previewFolder(id)
      case "toggle":
        folders[id]?.open.toggle()
        changed(folders[id]?.spaceId)
      case "reorder": handleReorder(value)
      case "dropOnSpace": moveToSpace(id, value.s("spaceId"))
      case "rename": endRename(id, value.s("title"))
      case "renameCancel": endRename(id, nil)
      case "menu":
        if value.string == "renameFolder" { beginRename(id) }
        if let item = value.string, iconMenuPicked(id, item) { return }
        if value.string == "deleteFolder" { confirmDeleteFolder(id) }
        if value.string == "newTabInFolder" { newTabInFolder(id) }
        if value.string == "ungroup" { ungroup(id) }
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
    if let sp = splits[id] {
      switch action {
      case "click":
        let pane = value.s("pane")
        if sp.children.contains(pane) {
          select(pane)
        } else if let first = sp.children.first {
          select(first)
        }
      case "close": unsplit(id)
      case "hover":
        // The split's focused pane (or its first) stands for it.
        if let t = sp.children.first(where: { $0 == selectedId }) ?? sp.children.first { preview(t, anchor: id) }
      case "reorder": handleReorder(value)
      case "dropOnSpace": moveToSpace(id, value.s("spaceId"))
      case "menu": _ = splitMenuPicked(value.string ?? "")
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
      if action == "menu" {
        switch value.string ?? "" {
        case "pasteGo": pasteAndGo()
        case "copy": copyURL()
        case "copyMarkdown": if let id = selectedId { menuPicked(id, "copyMarkdown") }
        case "share": if let id = selectedId { share(id, anchor: "tabs.url") }
        default: break
        }
      }
    case Self.libraryId:
      libraryAction(action, value)
    case Self.downloadToastId:
      if action == "toast" { downloadToastAction() }
    case Self.clearArchiveId:
      env.call("ui", "set", ["slot": "dialog", "tree": nil])
      if action == "button", value.s("button") == "clear" { clearArchive() }
    default:
      if Text.hasPrefix(id, "tabs.divider:"), action == "clear" { clearToday(Text.dropPrefix(id, "tabs.divider:")) }
      if tidyAction(id, action, value) { return }
      if Text.hasPrefix(id, "tabs.newtab:"), action == "click" {
        // ⌥-click: the new tab opens as a split with the current one (Dia 0.47).
        if value.a("modifiers").contains("opt"), !env.call("peek", "addSplit").isErr { return }
        openCommandBar("new")
      }
      if Text.hasPrefix(id, "tabs.deleteFolder:"), action == "button" {
        env.call("ui", "set", ["slot": "dialog", "tree": nil])
        let fid = Text.dropPrefix(id, "tabs.deleteFolder:")
        if value.s("button") == "delete" && folders[fid] != nil { deleteFolder(fid) }
      }
    }
  }

  // MARK: - Hover previews

  /// The host saw hover intent on a sidebar row: ask the `previews` plugin for a card (if it's
  /// loaded; without it nothing happens). `anchor` is the row the card points at.
  func preview(_ id: String, anchor: String? = nil) {
    guard let t = tabs[id] else { return }
    let k = kindOf(id)
    var args: Value = [
      "anchor": .string(anchor ?? id), "url": .string(t.url), "title": .string(t.displayTitle), "icon": .string(t.icon),
      "webview": .string(id), "selected": .bool(id == selectedId), "kind": .string(k),
      // What the card's actions need (previews composes them; `tabs.act` runs them).
      "drift": .bool(k != "today" && t.drift), "audio": .bool(t.audio), "muted": .bool(t.muted),
      "place": .string(k == "favorite" ? "tile" : "trailing"),
    ]
    if k != "favorite" {
      let here = spaceOf(id)
      args.put("spaces", .array(spaces.filter { $0.s("id") != here }.map { ["id": $0["id"], "name": $0["name"]] }))
    }
    if let a = anchor, let sp = splits[a] {
      args.put("panes", .array(sp.children.compactMap { c -> Value? in
        guard let p = tabs[c] else { return nil }
        return ["id": .string(c), "title": .string(p.displayTitle), "url": .string(p.url), "icon": .string(p.icon), "audio": .bool(p.audio)]
      }))
      args.put("inSplit", true)
    } else if splitOf(id) != nil {
      args.put("inSplit", true)
    }
    env.call("previews", "show", args)
  }

  /// A hover-card action on tab `id` (docs/plugin-services.md "tabs.act").
  func act(_ id: String, _ action: String, _ value: Value) -> Value {
    guard tabs[id] != nil else { return .err("tabs: no tab '" + id + "'") }
    switch action {
    case "pin": setKind(id, "pinned", toast: false)
    case "unpin": setKind(id, "today", toast: false)
    case "reset": reset(id)
    case "duplicate": _ = duplicate(id)
    case "copy": menuPicked(id, "copy")
    case "close": close(id)
    case "mute", "unmute":
      let m = action == "mute"
      env.call("webviews", "setMuted", ["id": .string(id), "muted": .bool(m)])
      tabs[id]?.muted = m
      changed(spaceOf(id))
    case "move":
      let sid = value.s("spaceId")
      guard !sid.isEmpty else { return .err("tabs: move needs spaceId") }
      moveToSpace(id, sid)
    case "split":
      // Dia: the hovered tab joins the active one (50/50, hovered on the right). On the active
      // tab (or a tab already in a split) it's "add a split": a new pane and the command bar.
      if let sel = selectedId, sel != id, splitOf(id) == nil, splitOf(sel) == nil {
        return split([sel, id], layout: "horizontal", focus: id)
      }
      if selectedId != id { select(id) }
      env.emit("peek.key.addSplit", .null)
    default:
      return .err("tabs: unknown action '" + action + "'")
    }
    return .okay
  }

  func previewFolder(_ fid: String) {
    guard let f = folders[fid] else { return }
    var items: [Value] = []
    func add(_ ids: [String]) {
      for c in ids {
        if let t = tabs[c] {
          items.append(["id": .string(c), "title": .string(t.displayTitle), "url": .string(t.url), "icon": .string(t.icon)])
        } else if let sp = splits[c] {
          add(sp.children)
        } else if let sub = folders[c] {
          add(sub.children)
        }
      }
    }
    add(f.children)
    env.call("previews", "show", ["anchor": .string(fid), "kind": "folder", "title": .string(f.title), "icon": "sf:folder.fill", "items": .array(items)])
  }

  // MARK: - Library (archive sheet)

  static let libraryId = "tabs.library"
  static let clearArchiveId = "tabs.clearArchive"

  /// The footer's Library button (`spaces.library`) opens the archive in the host's
  /// `overlay.library` sheet; `tabs` owns that slot.
  func openLibrary(section: String = "archive") {
    libraryOpen = true
    librarySection = section
    if section == "downloads" { archiveOldDownloads() }
    renderLibrary()
  }

  func closeLibrary() {
    guard libraryOpen else { return }
    libraryOpen = false
    env.call("ui", "set", ["slot": "overlay.library", "tree": nil])
  }

  func renderLibrary() {
    guard libraryOpen else { return }
    let sections = hasDownloads
    if sections, librarySection == "downloads" {
      env.call("ui", "set", ["slot": "overlay.library", "tree": downloadsTree()])
      return
    }
    librarySection = "archive"
    let items: [Value] = archive.map { e in
      ["id": e["id"], "title": .string(URLs.pageTitle(e.s("title"), e.s("url"))), "url": e["url"], "icon": .string(URLs.icon(e.sOpt("favicon"), e.s("url"))),
       "closedAt": e["closedAt"]]
    }
    env.call("ui", "set", ["slot": "overlay.library", "tree": [
      "type": "library", "id": .string(Self.libraryId), "title": "Archive", "placeholder": "Search archived tabs",
      "empty": "Tabs you close or that archive themselves show up here.", "items": .array(items),
      "sections": sections ? Self.librarySections : .null, "section": "archive",
    ]])
  }

  func libraryAction(_ action: String, _ value: Value) {
    if action == "section" {
      librarySection = value.s("id") == "downloads" ? "downloads" : "archive"
      if librarySection == "downloads" { archiveOldDownloads() }
      renderLibrary()
      return
    }
    if librarySection == "downloads", action != "dismiss", action != "input" {
      downloadsAction(action, value)
      return
    }
    switch action {
    case "restore":
      closeLibrary()
      _ = restore(value.s("item"))
    case "clear":
      guard !archive.isEmpty else { return }
      env.call("ui", "set", ["slot": "dialog", "tree": [
        "type": "dialog", "id": .string(Self.clearArchiveId), "icon": "sf:archivebox", "iconStyle": "destructive",
        "title": "Clear the Archive?", "message": "Every archived tab is removed for good. This can’t be undone.",
        "buttons": [["id": "cancel", "title": "Cancel", "style": "cancel"], ["id": "clear", "title": "Clear Archive", "style": "destructive", "default": true]],
      ]])
    case "dismiss":
      closeLibrary()
    default:
      break  // `input`: the sheet filters locally
    }
  }

  func clearArchive() {
    archive = []
    collectWebviews()
    saveSoon()
    env.emit("tabs.changed", ["spaceId": .string(currentSpace)])
    renderLibrary()
  }

  func confirmDeleteFolder(_ fid: String) {
    guard let f = folders[fid] else { return }
    let group = kindOf(fid) == "today"
    env.call("ui", "set", ["slot": "dialog", "tree": [
      "type": "dialog", "id": .string("tabs.deleteFolder:" + fid), "icon": "sf:folder",
      "title": .string(group ? "Close the " + f.title + " group?" : "Delete your " + f.title + " folder?"),
      "message": .string(group ? "Its tabs go to the Archive. ⌃Z brings them back." : "Deleting this folder will archive the tabs inside it."),
      "buttons": [["id": "cancel", "title": "Cancel", "style": "cancel"], ["id": "delete", "title": group ? "Close Group" : "Delete", "style": "destructive"]],
    ]])
  }

  func menuPicked(_ id: String, _ item: String) {
    switch item {
    case "copy":
      if let t = tabs[id] {
        env.call("app", "copy", ["text": .string(t.url)])
        env.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": .string(Copied.link(t.url)), "icon": "sf:link"]])
      }
    case "duplicate": _ = duplicate(id)
    case "share": share(id, anchor: id)
    case "rename": beginRename(id)
    case "changeIcon", "removeIcon": _ = iconMenuPicked(id, item)
    case "mute", "unmute": toggleMute(id)
    case "keepActive": toggleKeepActive(id)
    case "reset": reset(id)
    case "replacePinned":
      checkpoint()
      let current = tabs[id]?.url
      tabs[id]?.pinnedUrl = current
      changed(spaceOf(id))
    case "pin": setKind(id, "pinned", toast: true)
    case "unpin": setKind(id, "today", toast: true)
    case "favorite": if favorites.count < Self.maxFavorites { setKind(id, "favorite", toast: false) }
    case "newFolder":
      var ids = multi.filter { tabs[$0] != nil && kindOf($0) != "favorite" }
      if !ids.contains(id) { ids.insert(id, at: 0) }
      _ = createFolder(space: spaceOf(id) ?? currentSpace, title: nil, tabIds: ids, rename: true)
    case "removeFromFolder":
      guard let (b, _) = locate(splitOf(id) ?? id), case let .folder(f) = b, let (fb, fi) = locate(f) else { return }
      checkpoint()
      place(splitOf(id) ?? id, fb, index: fi + 1)
    case "copyMarkdown":
      if let t = tabs[id] {
        env.call("app", "copy", ["text": .string("[" + t.displayTitle + "](" + t.url + ")")])
        env.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": .string(Copied.markdown(t.url)), "icon": "sf:link"]])
      }
    case "closeOthers": closeMany(id, "others")
    case "closeBelow": closeMany(id, "below")
    case "closeAbove": closeMany(id, "above")
    case "close": close(id)
    default:
      if splitMenuPicked(item) { return }
      if Text.hasPrefix(item, "move:") { moveToSpace(id, Text.dropPrefix(item, "move:")) }
    }
  }
}
