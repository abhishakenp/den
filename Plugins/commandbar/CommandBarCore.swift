// The `commands` service and Arc's Command Bar (Cmd-T / Cmd-L): one input that searches open tabs
// in every space, the archive and history, spaces and commands, goes to URLs and searches the web.
// See docs/plugin-services.md and docs/research/arc.md §9.

#if !hasFeature(Embedded)
  import CordisValue
#endif

final class CommandBarCore {
  /// A search engine. `keyword` + Tab scopes the bar to it; `url` holds `%s` for the query.
  struct Engine: Equatable {
    var keyword: String
    var name: String
    var url: String

    var value: Value { ["keyword": .string(keyword), "name": .string(name), "url": .string(url)] }
    init(_ keyword: String, _ name: String, _ url: String) {
      self.keyword = keyword
      self.name = name
      self.url = url
    }
    init?(_ v: Value) {
      guard let k = v["keyword"].string, !k.isEmpty, let u = v["url"].string, !u.isEmpty else { return nil }
      self.init(Text.lower(k), v.sOpt("name") ?? k, u)
    }
  }

  struct Command {
    var id: String
    var title: String
    var icon: String
    var keywords: [String]
    var shortcut: String
    var owner: String?  // plugin id; the command goes away when that plugin is no longer active
    var aliases: [String] = []  // other names that match as well as the title ("prefs" → Settings)
  }

  /// What picking a row does.
  enum Act: Equatable {
    case url(String)  // go to a URL (typed, history)
    case search(String)  // a search URL
    case reload
    case tab(String)
    case space(String)
    case command(String)
    case archived(String, String)  // archive id, url
    case scope(Int)  // enter an engine's site search
    case rename(String)  // tab id; the query is the new title
    case setting(String)  // setting key: toggles, drills into a choice, or opens its pane
    case pane(String)  // settings pane id
    case option(String, Int)  // setting key, option index
    case window(String)  // Little Arc window id
    case shortcut(String)  // key chord: runs its binding
    case folder(String)  // a local folder's path: shows it in Finder (CommandFiles.swift)
    case complete(String)  // puts this text in the field (a folder's path while completing)
  }

  struct Row {
    var id: String
    var icon: String
    var title: String
    var subtitle = ""
    var accessory = ""
    var keycap = ""
    var act: Act
    var key = ""  // usage key for ranking
    var score = 0
    var strength = 0  // how well the text matched (no usage): decides the tier, so rows don't jump while typing
    var shortcut = ""  // drawn as keycaps ("⇧⌘C", menu order ⌃⌥⇧⌘)
    var toggle: Bool? = nil  // a switch showing a setting's state
    var drill = false  // Tab / → opens its options or settings in the bar
    var completion = ""  // Tab puts this in the field (file rows)
  }

  enum Scope: Equatable {
    case main
    case actions  // Tab: only commands
    case engine(Int)  // site search
    case rename(String)  // tab id
    case archive
    case split  // pick what opens on the right
    case options(String)  // a setting's options (setting key)
    case pane(String)  // one settings pane's settings
    case shortcuts  // every key binding
  }

  struct Usage {
    var n: Int64
    var t: Int64
    var title: String
    var url: String
  }

  static let ns = "commandbar"
  static let slot = "overlay.commandBar"
  static let barId = "commandBar"  // also the id the host uses for a click outside the bar
  static let defaultEngines: [Engine] = [
    Engine("g", "Google", "https://www.google.com/search?q=%s"),
    Engine("yt", "YouTube", "https://www.youtube.com/results?search_query=%s"),
    Engine("gh", "GitHub", "https://github.com/search?q=%s"),
    Engine("w", "Wikipedia", "https://en.wikipedia.org/w/index.php?search=%s"),
    Engine("maps", "Google Maps", "https://www.google.com/maps/search/%s"),
    Engine("x", "X", "https://x.com/search?q=%s"),
  ]
  static let maxUsage = 400
  /// Rows the bar shows at most (matches the host's `Tokens.commandBarMaxRows`).
  static let maxRows = 8
  static let maxSuggestions = 4
  /// Rows kept for web suggestions, so local matches never get pushed out when they arrive.
  static let reservedSuggestions = 2
  /// A match at least this good (prefix, word prefix, keyword or host) ranks above web suggestions.
  static let strongMatch = 60
  /// A den row this good (the query starts its title or an alias) goes above "Search Google".
  static let topHitMatch = 90
  /// Row and section-header heights in the host (`Tokens.commandBarRowHeight`, `M.headerHeight`):
  /// the rows and headers of one bar share `maxRows` rows of height.
  static let rowCost = 50
  static let headerCost = 28
  /// Default-browser banner: "×" hides it for good (Settings > Search brings it back; see
  /// docs/defaults.md); "Try for a week" asks after 7 days.
  static let trialMs: Int64 = 7 * 86_400_000
  static let trialDialog = "commandbar.trial"
  static let dayMs: Int64 = 86_400_000

  let env: PluginEnv
  var engines: [Engine] = CommandBarCore.defaultEngines
  var usage: [String: Usage] = [:]
  var registered: [String: Command] = [:]
  var registeredOrder: [String] = []

  // Bar state
  var isOpen = false
  var mode = "new"  // new | edit (Cmd-T / Cmd-L)
  var scope = Scope.main
  var query = ""
  var editURL = ""
  var selected = ""
  var rows: [Row] = []
  var sections: [(String, [Row])] = []
  // Web suggestions (WebSuggestions): the latest answer and what's on screen now.
  var suggestQuery = ""
  var suggestItems: [String] = []
  var shownSuggestions: [String] = []
  // Default browser (the banner): read lazily when the bar opens, cached until app.defaultBrowser.
  var browserChecked = false
  var isDefaultBrowser = true
  var currentBrowser = ""
  var currentBrowserName = ""
  var trialTimer = false
  // Launcher index (CommandLauncher.swift): rebuilt when the bar opens and when commands or
  // settings change, never per keystroke.
  var index: [IndexEntry] = []
  var indexValid = false
  var backStack: [(Scope, String)] = []  // where Backspace in an empty field goes back to (scope, query)
  // Per-open caches of other services' state, dropped on their change events.
  var tabsCache: [Value]? = nil
  var selectedCache: Value? = nil
  var windowsCache: [Value]? = nil
  var fileCache: (String, Value?)? = nil  // the last typed path and its `app.fileInfo` (nil: no such file)
  /// Settings > Search > "Search suggestions" (on): typed searches are sent to the search engine's
  /// suggestion service as you type. Off: nothing leaves den until you press Return.
  var suggestionsOn = true
  /// Web search autocomplete over `net.fetch` (WebSuggestions.swift).
  let suggest: WebSuggestions
  /// config.toml [shortcuts] and [search.keywords] (ConfigShortcuts.swift): chords bound for
  /// commands, and keywords merged into the engines.
  var configChords: [String] = []
  var configKeywords: [String] = []

  init(env: PluginEnv) {
    self.env = env
    suggest = WebSuggestions(env: env)
  }

  // MARK: - Lifecycle

  func start() {
    load()
    env.call("keys", "bind", ["chord": "cmd+t", "event": "commands.key.new", "title": "New Tab…", "menu": "File"])
    env.call("keys", "bind", ["chord": "cmd+l", "event": "commands.key.edit", "title": "Open Location…", "menu": "File"])
    env.on("commands.key.new") { [self] _ in toggle("new") }
    env.on("commands.key.edit") { [self] _ in toggle("edit") }
    env.on("ui.action") { [self] v in if v.s("id") == Self.barId { action(v.s("action"), v["value"]) } }
    suggest.arrived = { [self] q, items in suggestionsArrived(q, items) }
    suggest.start()
    startConfig()
    env.on("app.defaultBrowser") { [self] _ in
      browserChecked = false
      if isOpen { render() }
    }
    env.on("ui.action") { [self] v in if v.s("id") == Self.trialDialog { trialAnswered(v["value"].s("button")) } }
    // Other plugins' state, cached while the bar is open.
    for e in ["tabs.changed", "tabs.selected", "spaces.changed", "spaces.current"] {
      env.on(e) { [self] _ in
        tabsCache = nil
        selectedCache = nil
        indexValid = false  // tab commands depend on the selected tab
      }
    }
    env.on("window.miniClosed") { [self] _ in windowsCache = nil }
    env.on("connections.changed") { [self] _ in
      // A connect or disconnect surfaces or hides the new-document commands.
      indexValid = false
      if isOpen { render() }
    }
    env.on("settings.changed") { [self] _ in
      indexValid = false
      if isOpen { render() }
    }
    env.on("settings.changed") { [self] v in if v.s("id") == Self.ns { settingChanged(v.s("key"), v["value"]) } }
    env.on("settings.action") { [self] v in if v.s("id") == Self.ns { settingAction(v) } }
    checkTrial()
    syncSettings()
  }

  // MARK: - Settings window

  /// Settings > Search (host `settings` service): the default engine, the site-search keywords,
  /// adding one, and the default-browser banner. Re-registered when the engines change.
  func syncSettings() {
    let options: [Value] = engines.map { ["value": .string($0.keyword), "title": .string($0.name)] }
    let items: [Value] = engines.enumerated().map { i, e in
      var v: Value = ["id": .string(e.keyword), "title": .string(e.name), "subtitle": .string(e.keyword + " · " + URLs.host(e.url)), "icon": "sf:magnifyingglass"]
      if i > 0 { v.put("buttons", [["id": "remove", "title": "Remove"]]) }
      return v
    }
    env.call("settings", "register", [
      "id": .string(Self.ns), "title": "Search", "icon": "sf:magnifyingglass", "order": 20,
      "controls": [
        ["key": "defaultEngine", "type": "choice", "title": "Search engine",
         "subtitle": "What the command bar searches when you type something that isn't a web address.",
         "options": .array(options), "default": .string(engines[0].keyword)],
        ["key": "engines", "type": "list", "title": "Site search",
         "subtitle": "Type a keyword and press Tab in the command bar to search that site.", "items": .array(items)],
        ["key": "addEngine", "type": "text", "submit": true, "title": "Add a site search",
         "subtitle": "A keyword, then a URL with %s where the search goes, e.g. mdn https://developer.mozilla.org/search?q=%s",
         "placeholder": "keyword  https://…?q=%s"],
        ["key": "suggestions", "type": "toggle", "title": "Search suggestions",
         "subtitle": "Show suggestions from Google while you type. What you type is sent to Google as you type it.", "default": true],
        ["key": "banner", "type": "toggle", "title": "Offer to make den your default browser",
         "subtitle": "A small banner in the command bar while another browser opens your links.", "default": true],
      ],
    ])
    if let on = env.call("settings", "get", ["id": .string(Self.ns), "key": "suggestions"]).bool { suggestionsOn = on }
    // The stored choice always reflects the current first engine.
    env.call("settings", "set", ["id": .string(Self.ns), "key": "defaultEngine", "value": .string(engines[0].keyword)])
  }

  func settingChanged(_ key: String, _ v: Value) {
    switch key {
    case "defaultEngine":
      guard let k = v.string, let i = engines.firstIndex(where: { $0.keyword == k }), i > 0 else { return }
      var list = engines
      let e = list.remove(at: i)
      list.insert(e, at: 0)
      _ = handle("engines", ["engines": .array(list.map { $0.value })])
    case "suggestions":
      suggestionsOn = v.bool != false
      if !suggestionsOn { suggest.cancel() }
    case "banner":
      store("bannerDismissed", .bool(v.bool == false))
      if isOpen { render() }
    default: break
    }
  }

  func settingAction(_ v: Value) {
    switch v.s("key") {
    case "engines":
      guard v.s("button") == "remove", engines.count > 1 else { return }
      let list = engines.filter { $0.keyword != v.s("item") }
      _ = handle("engines", ["engines": .array(list.map { $0.value })])
    case "addEngine":
      // "kw url" or "kw Name words url": the last word with %s is the URL.
      var words: [String] = []
      var cur: [UInt8] = []
      for c in v.s("value").utf8 {
        if c == 32 || c == 9 { if !cur.isEmpty { words.append(String(decoding: cur, as: UTF8.self)); cur = [] } } else { cur.append(c) }
      }
      if !cur.isEmpty { words.append(String(decoding: cur, as: UTF8.self)) }
      guard words.count >= 2, Text.contains(words[words.count - 1], "%s") else {
        env.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": "Add a keyword, then a URL with %s", "icon": "sf:exclamationmark.triangle.fill"]])
        return
      }
      let kw = Text.lower(words[0]), url = words[words.count - 1]
      var name = URLs.host(url)
      if words.count > 2 {
        name = words[1]
        for w in words[2..<(words.count - 1)] { name += " " + w }
      }
      var list = engines.filter { $0.keyword != kw }
      list.append(Engine(kw, name, url))
      _ = handle("engines", ["engines": .array(list.map { $0.value })])
    default: break
    }
  }

  func stop() {
    if isOpen { env.call("ui", "set", ["slot": .string(Self.slot), "tree": .null]) }
  }

  func load() {
    let e = env.call("storage", "get", ["ns": .string(Self.ns), "key": "engines"])
    if let list = e.array {
      let parsed = list.compactMap { Engine($0) }
      if !parsed.isEmpty { engines = parsed }
    }
    if case let .object(pairs) = env.call("storage", "get", ["ns": .string(Self.ns), "key": "usage"]) {
      for (k, v) in pairs { usage[k] = Usage(n: v.i("n"), t: v.i("t"), title: v.s("title"), url: v.s("url")) }
    }
  }

  func saveUsage() {
    if usage.count > Self.maxUsage {
      let now = env.now()
      let keep = usage.keys.sorted { frecency(usage[$0]!, now) > frecency(usage[$1]!, now) }.prefix(Self.maxUsage)
      var trimmed: [String: Usage] = [:]
      for k in keep { trimmed[k] = usage[k] }
      usage = trimmed
    }
    var pairs: [(String, Value)] = []
    for k in usage.keys.sorted() {
      let u = usage[k]!
      var v: Value = ["n": .int(u.n), "t": .int(u.t)]
      if !u.title.isEmpty { v.put("title", .string(u.title)) }
      if !u.url.isEmpty { v.put("url", .string(u.url)) }
      pairs.append((k, v))
    }
    env.call("storage", "set", ["ns": .string(Self.ns), "key": "usage", "value": .object(pairs)])
  }

  // MARK: - Service

  func handle(_ method: String, _ args: Value) -> Value {
    switch method {
    case "register":
      let id = args.s("id")
      guard !id.isEmpty, !args.s("title").isEmpty else { return .err("commands: register needs id and title") }
      guard builtin(id) == nil else { return .err("commands: '" + id + "' is a built-in command") }
      if registered[id] == nil { registeredOrder.append(id) }
      registered[id] = Command(
        id: id, title: args.s("title"), icon: args.sOpt("icon") ?? "sf:command", keywords: args.a("keywords").compactMap { $0.string },
        shortcut: args.s("shortcut"), owner: args.sOpt("owner"), aliases: args.a("aliases").compactMap { $0.string })
      indexValid = false
      if isOpen { render() }
    case "unregister":
      registered[args.s("id")] = nil
      registeredOrder.removeAll { $0 == args.s("id") }
      indexValid = false
    case "list":
      return .array(commands().map { c in
        ["id": .string(c.id), "title": .string(c.title), "icon": .string(c.icon), "shortcut": .string(c.shortcut), "owner": .str(c.owner),
         "aliases": .array(c.aliases.map { .string($0) })]
      })
    case "search":
      // The launcher's den matches for a query, best first (tests, scripts and other plugins).
      if !isOpen { indexValid = false }
      return .array(launcherMatches(trim(args.s("q")), limit: Int(args.i("limit", 20))).map { m in
        ["id": .string(index[m.0].rowId), "title": .string(index[m.0].title), "strength": .int(Int64(m.1))]
      })
    case "run":
      let id = args.s("id")
      guard commands().contains(where: { $0.id == id }) else { return .err("commands: no command '" + id + "'") }
      run(id)
    case "open":
      let m = args.sOpt("mode") ?? "new"
      guard m == "new" || m == "edit" else { return .err("commands: bad mode " + m) }
      open(m, query: args["query"].string)
    case "close":
      close()
    case "paste":
      // Paste and Go / Paste and Search (the URL pill's menu): the text opens as an address when
      // it is one, else as a search with the default engine; `mode: edit` in the selected tab.
      let text = trim(args.s("text"))
      guard !text.isEmpty else { return .err("commands: paste needs text") }
      if let f = localFile(text) {
        if f.b("folder") {
          env.call("app", "openPath", ["path": .string(f.s("path"))])
          return ["kind": "folder", "url": .string(f.s("url"))]
        }
        bump("url:" + URLs.normalize(f.s("url")), title: text, url: f.s("url"))
        let was = mode
        mode = args.s("mode") == "edit" ? "edit" : "new"
        go(f.s("url"), peek: false, scope: .main)
        mode = was
        return ["kind": "file", "url": .string(f.s("url"))]
      }
      let u = Self.url(from: text)
      let target = u ?? Self.searchURL(defaultEngine, text)
      if u != nil { bump("url:" + URLs.normalize(target), title: text, url: target) } else { bump("q:" + Text.lower(text), title: text, url: target) }
      let was = mode
      mode = args.s("mode") == "edit" ? "edit" : "new"
      go(target, peek: false, scope: .main)
      mode = was
      return ["kind": .string(u == nil ? "search" : "url"), "url": .string(target)]
    case "engines":
      if let list = args["engines"].array {
        let parsed = list.compactMap { Engine($0) }
        guard !parsed.isEmpty else { return .err("commands: engines needs at least one {keyword, name, url}") }
        engines = parsed
        env.call("storage", "set", ["ns": .string(Self.ns), "key": "engines", "value": .array(engines.map { $0.value })])
        syncSettings()
      }
      return .array(engines.map { $0.value })
    case "state":
      return ["open": .bool(isOpen), "mode": .string(mode), "scope": .string(scopeName), "query": .string(query), "selected": .string(selected),
              "rows": .array(rows.map { .string($0.id) })]
    default:
      return .err("commands: unknown method " + method)
    }
    return .okay
  }

  var scopeName: String {
    switch scope {
    case .main: return "main"
    case .actions: return "actions"
    case let .engine(i): return "engine:" + engines[i].keyword
    case .rename: return "rename"
    case .archive: return "archive"
    case .split: return "split"
    case let .options(k): return "options:" + k
    case let .pane(p): return "pane:" + p
    case .shortcuts: return "shortcuts"
    }
  }

  // MARK: - Open / close

  func toggle(_ m: String) {
    // Pressing the same shortcut again closes the bar (Arc).
    if isOpen && mode == m && scope == .main { close() } else { open(m, query: nil) }
  }

  func open(_ m: String, query q: String?) {
    // Lazy plugins whose commands change at runtime load on this (their sidecar's `events`).
    if !isOpen { env.emit("commands.opened", ["mode": .string(m)]) }
    let reopen = isOpen
    mode = m
    scope = .main
    backStack = []
    editURL = ""
    if m == "edit" {
      editURL = q ?? selectedTab().s("url")
      query = editURL
    } else {
      query = q ?? ""
    }
    selected = ""
    isOpen = true
    dropCaches()
    shownSuggestions = []
    requestSuggestions()
    // Clearing first makes the host treat it as a fresh open, which selects the text (Cmd-L).
    if reopen { env.call("ui", "set", ["slot": .string(Self.slot), "tree": .null]) }
    render(replace: true)
  }

  func close() {
    guard isOpen else { return }
    isOpen = false
    scope = .main
    query = ""
    rows = []
    sections = []
    shownSuggestions = []
    backStack = []
    dropCaches()
    suggest.cancel()
    env.call("ui", "set", ["slot": .string(Self.slot), "tree": .null])
  }

  func setScope(_ s: Scope, query q: String, reopen: Bool = false) {
    scope = s
    query = q
    selected = ""
    requestSuggestions()
    if reopen { env.call("ui", "set", ["slot": .string(Self.slot), "tree": .null]) }
    render(replace: true)
  }

  // MARK: - UI actions

  func action(_ a: String, _ value: Value) {
    guard isOpen else { return }
    switch a {
    case "input":
      query = value.s("text")
      selected = ""
      requestSuggestions()
      render()
    case "select":
      selected = value.s("row")
      render()
    case "submit":
      if let q = value["query"].string, q != query {
        query = q
        compute()
      }
      let mods = value.a("modifiers").compactMap { $0.string }
      let row = rows.first { $0.id == value.s("row") } ?? rows.first { $0.id == selected } ?? rows.first
      if let r = row { pick(r, shift: mods.contains("shift")) }
    case "tab":
      if let q = value["query"].string { query = q }
      if !completeSelected(), !drillSelected() { tabKey() }
    case "right":
      // → at the end of the text: drills into the selected settings row (otherwise nothing).
      if let q = value["query"].string { query = q }
      if let r = value["row"].string, !r.isEmpty { selected = r }
      _ = drillSelected()
    case "back":
      // Backspace in an empty field: out of a drilled-in scope.
      back()
    case "dismiss":
      close()
    case "banner":
      bannerButton(value.s("button"))
    default:
      break
    }
  }

  /// Tab: a site-search keyword scopes the search to that site; otherwise it switches between
  /// the full results and actions only.
  func tabKey() {
    switch scope {
    case .main:
      if let i = engineIndex(Text.lower(trim(query))) { setScope(.engine(i), query: "") } else { setScope(.actions, query: query) }
    case .actions:
      setScope(.main, query: query)
    default:
      break
    }
  }

  func engineIndex(_ keyword: String) -> Int? {
    keyword.isEmpty ? nil : engines.firstIndex { $0.keyword == keyword }
  }

  // MARK: - Picking

  func pick(_ r: Row, shift: Bool) {
    switch r.act {
    case let .scope(i):
      setScope(.engine(i), query: "")
      return
    case let .command(id) where id == "den.renameTab" || id == "den.viewArchive" || id == "den.splitRight" || id == "den.shortcuts":
      run(id)  // these continue inside the bar
      return
    case let .setting(key) where pickSettingInBar(key):
      return
    case let .pane(id) where !available("settings"):
      drill(pane: id)
      return
    case let .complete(text):
      setScope(scope, query: text)  // into a folder, still typing
      return
    default:
      break
    }
    let peek = shift && available("peek")
    let s = scope
    close()
    switch r.act {
    case let .url(u), let .search(u):
      if case .url = r.act { bump("url:" + URLs.normalize(u), title: r.title, url: u) }
      if case .search = r.act { bump("q:" + Text.lower(r.title), title: r.title, url: u) }
      go(u, peek: peek, scope: s)
    case .reload:
      if let id = selectedTab().sOpt("id") { env.call("webviews", "reload", ["id": .string(id)]) }
    case let .tab(id):
      bump("tab:" + id, title: "", url: "")
      if s == .split { split(with: id) } else { env.call("tabs", "select", ["id": .string(id)]) }
    case let .space(id):
      bump("space:" + id, title: "", url: "")
      env.call("spaces", "switch", ["id": .string(id)])
    case let .command(id):
      run(id)
    case let .archived(id, u):
      bump("url:" + URLs.normalize(u), title: r.title, url: u)
      if peek { env.call("peek", "open", ["url": .string(u)]) } else { env.call("tabs", "restore", ["id": .string(id)]) }
    case let .rename(id):
      env.call("tabs", "rename", ["id": .string(id), "title": .string(trim(r.title))])
    case let .setting(key):
      pickSetting(key)
    case let .pane(id):
      bump("pane:" + id, title: "", url: "")
      env.call("settings", "open", ["id": .string(id)])
    case let .option(key, i):
      pickOption(key, i)
    case let .window(id):
      bump("win:" + id, title: "", url: "")
      env.call("window", "focusMini", ["id": .string(id)])
    case let .shortcut(chord):
      runShortcut(chord)
    case let .folder(path):
      env.call("app", "openPath", ["path": .string(path)])
    case .scope, .complete:
      break
    }
  }

  /// Opens `url`: in Peek (Shift-Enter), next to the selected tab (split), in the current tab
  /// (Cmd-L), or in a new tab.
  func go(_ url: String, peek: Bool, scope s: Scope) {
    if peek {
      var a: Value = ["url": .string(url)]
      if let id = selectedTab().sOpt("id") { a.put("sourceId", .string(id)) }
      env.call("peek", "open", a)
    } else if s == .split {
      let r = env.call("tabs", "open", ["url": .string(url), "background": true])
      if let id = r["id"].string { split(with: id) }
    } else if mode == "edit", let id = selectedTab().sOpt("id") {
      env.call("tabs", "navigate", ["id": .string(id), "url": .string(url)])
    } else {
      env.call("tabs", "open", ["url": .string(url)])
    }
  }

  func split(with id: String) {
    guard let sel = selectedTab().sOpt("id"), sel != id else {
      env.call("tabs", "select", ["id": .string(id)])
      return
    }
    env.call("peek", "split", ["ids": [.string(sel), .string(id)], "layout": "horizontal"])
  }

  // MARK: - Commands

  struct Builtin {
    var id: String
    var title: String
    var icon: String
    var keywords: [String]
    var shortcut: String
    var needsTab: Bool
    var service: String?  // hidden unless this service exists
    var listener: String?  // hidden unless someone listens to this event
    var connections: [String] = []  // hidden unless one of these connection ids is connected
    var aliases: [String] = []
    var method: String? = nil  // a destination: picking it calls `service.method`
    var url: String? = nil  // a creation URL: picking it opens this URL in a new tab
  }

  static let builtins: [Builtin] = [
    Builtin(id: "den.newSpace", title: "New Space", icon: "sf:plus.square.on.square", keywords: ["create", "space"], shortcut: "", needsTab: false, service: "spaces"),
    // Create-new-document commands: gated on a connected account (any id in `connections`), since
    // the account is what makes the service's creation URL usable. The provider's plugin registers
    // the connection, so a connection also means its service is there.
    Builtin(id: "den.newNotionPage", title: "New Notion Page", icon: "https://www.notion.so/images/favicon.ico",
            keywords: ["create", "page", "note", "blank", "write"], shortcut: "", needsTab: false, connections: ["notion"],
            url: "https://www.notion.so/new"),
    Builtin(id: "den.newGoogleDoc", title: "New Google Doc", icon: "https://docs.google.com/favicon.ico",
            keywords: ["create", "document", "docs", "word", "write", "blank", "google"], shortcut: "", needsTab: false,
            connections: ["gmail", "calendar"], url: "https://docs.google.com/document/create"),
    Builtin(id: "den.newLinearIssue", title: "New Linear Issue", icon: "https://linear.app/favicon.ico",
            keywords: ["create", "ticket", "task", "bug", "triage"], shortcut: "", needsTab: false, connections: ["linear"],
            url: "https://linear.app/new"),
    Builtin(id: "den.renameTab", title: "Rename Tab", icon: "sf:pencil", keywords: ["title"], shortcut: "", needsTab: true, service: "tabs"),
    Builtin(id: "den.pinTab", title: "Pin Tab", icon: "sf:pin", keywords: ["unpin", "pinned"], shortcut: "⌘D", needsTab: true, service: "tabs"),
    Builtin(id: "den.duplicateTab", title: "Duplicate Tab", icon: "sf:plus.rectangle.on.rectangle", keywords: ["copy", "clone"], shortcut: "", needsTab: true, service: "tabs"),
    Builtin(id: "den.copyURL", title: "Copy URL", icon: "sf:link", keywords: ["link", "share"], shortcut: "⇧⌘C", needsTab: true, service: "app"),
    Builtin(id: "den.copyMarkdown", title: "Copy URL as Markdown", icon: "sf:text.quote", keywords: ["link", "share", "md"], shortcut: "⌥⇧⌘C", needsTab: true, service: "app"),
    Builtin(id: "den.clearToday", title: "Clear Today Tabs", icon: "sf:arrow.down.to.line", keywords: ["unpinned", "archive", "close"], shortcut: "⇧⌘K", needsTab: false, service: "tabs"),
    Builtin(id: "den.viewArchive", title: "View Archive", icon: "sf:archivebox", keywords: ["history", "closed", "restore"], shortcut: "", needsTab: false, service: "tabs"),
    Builtin(id: "den.toggleSidebar", title: "Toggle Sidebar", icon: "sf:sidebar.left", keywords: ["hide", "show"], shortcut: "⌘S", needsTab: false, service: "window"),
    Builtin(id: "den.theme", title: "Edit Theme", icon: "sf:paintpalette", keywords: ["color", "appearance", "dark", "light"], shortcut: "", needsTab: false, service: nil, listener: "spaces.editTheme"),
    Builtin(id: "den.reload", title: "Reload Page", icon: "sf:arrow.clockwise", keywords: ["refresh"], shortcut: "⌘R", needsTab: true, service: "webviews"),
    // WebKit's own picture in picture (the system PiP window); the media plugin handles the key.
    Builtin(id: "den.pip", title: "Picture in Picture", icon: "sf:pip.enter", keywords: ["pip", "video", "float", "mini player", "exit picture in picture"],
            shortcut: "⌥⌘P", needsTab: false, service: nil, listener: "media.key.pip"),
    Builtin(id: "den.splitRight", title: "Split Right", icon: "sf:rectangle.split.2x1", keywords: ["split view", "side by side"], shortcut: "", needsTab: true, service: "peek"),
    Builtin(id: "den.quit", title: "Quit den", icon: "sf:power", keywords: ["exit", "close"], shortcut: "⌘Q", needsTab: false, service: "app"),
    // Destinations: den's own screens. Each is hidden until the service that owns it is loaded.
    Builtin(id: "den.settings", title: "Settings", icon: "sf:gearshape", keywords: ["general", "customize"], shortcut: "", needsTab: false,
            service: "settings", aliases: ["preferences", "prefs", "options", "config", "configuration"], method: "open"),
    Builtin(id: "den.extensions", title: "Extensions", icon: "sf:puzzlepiece.extension", keywords: ["web extensions", "safari"], shortcut: "",
            needsTab: false, service: "extensions", aliases: ["addons", "add-ons", "plugins"], method: "open"),
    Builtin(id: "den.downloads", title: "Downloads", icon: "sf:arrow.down.circle", keywords: ["files", "saved"], shortcut: "", needsTab: false,
            service: "downloads", aliases: ["dl", "dls"], method: "open"),
    Builtin(id: "den.history", title: "History", icon: "sf:clock.arrow.circlepath", keywords: ["visited", "recent pages"], shortcut: "",
            needsTab: false, service: "history", method: "open"),
    Builtin(id: "den.library", title: "Library", icon: "sf:books.vertical", keywords: ["closed tabs", "restore"], shortcut: "", needsTab: false,
            service: "tabs", aliases: ["archive"], method: "library"),
    Builtin(id: "den.passwords", title: "Passwords", icon: "sf:key", keywords: ["accounts", "autofill"], shortcut: "", needsTab: false,
            service: "passwords", aliases: ["logins", "credentials", "keychain"], method: "open"),
    Builtin(id: "den.shortcuts", title: "Keyboard Shortcuts", icon: "sf:keyboard", keywords: ["keys", "bindings", "hotkeys"], shortcut: "",
            needsTab: false, service: "keys", aliases: ["shortcuts", "keybindings"]),
    Builtin(id: "den.about", title: "About den", icon: "sf:info.circle", keywords: ["version", "build"], shortcut: "", needsTab: false,
            service: "app"),
  ]

  func builtin(_ id: String) -> Builtin? { Self.builtins.first { $0.id == id } }

  /// Every command that can run right now: built-ins whose service (or listener) and tab exist,
  /// then registered commands whose owning plugin is still active.
  func commands() -> [Command] {
    let info = env.call("plugins", "get")
    let known = !info.isErr && !info.isNull
    let services = info.a("services").compactMap { $0.string }
    let active = info.a("plugins").filter { $0.b("active") }.map { $0.s("id") }
    let tab = selectedTab()
    // Connected connection ids, read once when a built-in needs one (no `connections`: none).
    let connected = Self.builtins.contains { !$0.connections.isEmpty }
      ? (env.call("connections", "list").array ?? []).filter { $0.b("connected") }.map { $0.s("id") } : []
    var out: [Command] = []
    for b in Self.builtins {
      if b.needsTab && tab.isNull { continue }
      if let s = b.service, known ? !services.contains(s) : !available(s) { continue }
      if let l = b.listener, !env.call("plugins", "listening", ["event": .string(l)]).b("listening") { continue }
      if !b.connections.isEmpty, !b.connections.contains(where: { connected.contains($0) }) { continue }
      var c = Command(id: b.id, title: b.title, icon: b.icon, keywords: b.keywords, shortcut: b.shortcut, owner: nil, aliases: b.aliases)
      if b.id == "den.pinTab", tab.s("kind") != "today" {
        c.title = "Unpin Tab"
        c.icon = "sf:pin.slash"
      }
      out.append(c)
    }
    for id in registeredOrder {
      guard let c = registered[id] else { continue }
      if known, let o = c.owner, !active.contains(o) {
        // Its plugin unloaded: the command goes with it.
        registered[id] = nil
        continue
      }
      out.append(c)
    }
    registeredOrder.removeAll { registered[$0] == nil }
    return out
  }

  /// True unless calling the service says it isn't there.
  func available(_ service: String) -> Bool {
    let info = env.call("plugins", "get")
    if !info.isErr && !info.isNull { return info.a("services").contains { $0.string == service } }
    let r = env.call(service, "")
    return !(r.isErr && Text.contains(r.s("error"), "not available"))
  }

  func run(_ id: String) {
    bump("cmd:" + id, title: "", url: "")
    if builtin(id) != nil { runBuiltin(id) }
    env.emit("commands.run", ["id": .string(id)])
  }

  func runBuiltin(_ id: String) {
    let tab = selectedTab()
    let tabId = tab.s("id")
    switch id {
    case "den.newSpace":
      let r = env.call("spaces", "create", ["name": "New Space"])
      if let sid = r["id"].string { env.call("spaces", "switch", ["id": .string(sid)]) }
    case "den.renameTab":
      guard !tabId.isEmpty else { return }
      if !isOpen {
        isOpen = true
        mode = "new"
      }
      setScope(.rename(tabId), query: tab.s("title"), reopen: true)
    case "den.pinTab":
      env.call("tabs", tab.s("kind") == "today" ? "pin" : "unpin", ["id": .string(tabId)])
    case "den.duplicateTab":
      env.call("tabs", "duplicate", ["id": .string(tabId)])
    case "den.copyURL":
      env.call("app", "copy", ["text": tab["url"]])
      toast(Copied.link(tab.s("url")), "sf:link")
    case "den.copyMarkdown":
      env.call("app", "copy", ["text": .string("[" + markdownEscape(tab.s("title")) + "](" + tab.s("url") + ")")])
      toast(Copied.markdown(tab.s("url")), "sf:link")
    case "den.clearToday":
      env.call("tabs", "clearToday")
    case "den.viewArchive":
      if !isOpen {
        isOpen = true
        mode = "new"
      }
      setScope(.archive, query: "")
    case "den.toggleSidebar":
      env.call("window", "toggleSidebar")
    case "den.theme":
      env.emit("spaces.editTheme", ["id": env.call("spaces", "current")["id"]])
    case "den.pip":
      env.emit("media.key.pip", [:])
    case "den.reload":

      env.call("webviews", "reload", ["id": .string(tabId)])
    case "den.splitRight":
      if !isOpen {
        isOpen = true
        mode = "new"
      }
      setScope(.split, query: "")
    case "den.quit":
      env.call("app", "quit", ["confirm": true])
    case "den.shortcuts":
      if !isOpen {
        isOpen = true
        mode = "new"
      }
      backStack.append((scope, query))
      setScope(.shortcuts, query: "")
    case "den.about":
      showAbout()
    default:
      if let b = builtin(id) {
        if let u = b.url { env.call("tabs", "open", ["url": .string(u)]); return }
        if let s = b.service, let m = b.method { env.call(s, m) }
      }
    }
  }

  func toast(_ text: String, _ icon: String) {
    env.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": .string(text), "icon": .string(icon)]])
  }

  func markdownEscape(_ s: String) -> String {
    var out: [UInt8] = []
    for c in s.utf8 {
      if c == 91 || c == 93 { out.append(92) }  // [ ] -> \[ \]
      out.append(c)
    }
    return String(decoding: out, as: UTF8.self)
  }

  // MARK: - Data

  func dropCaches() {
    tabsCache = nil
    selectedCache = nil
    windowsCache = nil
    fileCache = nil
    indexValid = false
  }

  func selectedTab() -> Value {
    if isOpen, let c = selectedCache { return c }
    var found: Value = .null
    if let id = env.call("tabs", "selected")["id"].string {
      for t in allTabs() where t.s("id") == id {
        found = t
        break
      }
    }
    if isOpen { selectedCache = found }
    return found
  }

  /// Open tabs in every space (favorites once), flattening folders and splits. Cached while the
  /// bar is open (until a tabs or spaces event), so typing doesn't re-read every space.
  func allTabs() -> [Value] {
    if isOpen, let c = tabsCache { return c }
    let out = readTabs()
    if isOpen { tabsCache = out }
    return out
  }

  func readTabs() -> [Value] {
    var out: [Value] = []
    var seen: [String] = []
    func add(_ items: [Value]) {
      for i in items {
        if let kids = i["children"].array {
          add(kids)
        } else if !i.s("id").isEmpty && !seen.contains(i.s("id")) {
          seen.append(i.s("id"))
          out.append(i)
        }
      }
    }
    let spaces = env.call("spaces", "list").array ?? []
    if spaces.isEmpty {
      let l = env.call("tabs", "list")
      add(l.a("favorites"))
      add(l.a("pinned"))
      add(l.a("today"))
    }
    for (n, sp) in spaces.enumerated() {
      let l = env.call("tabs", "list", ["spaceId": sp["id"]])
      if n == 0 { add(l.a("favorites")) }
      add(l.a("pinned"))
      add(l.a("today"))
    }
    return out
  }

  // MARK: - Ranking

  /// Frequency weighted by recency (a Firefox-style frecency). One use today is worth 100.
  func frecency(_ u: Usage, _ now: Int64) -> Int {
    let age = now - u.t
    let w: Int64
    if age < Self.dayMs { w = 100 } else if age < 4 * Self.dayMs { w = 80 } else if age < 14 * Self.dayMs { w = 60 } else if age < 31 * Self.dayMs {
      w = 40
    } else if age < 90 * Self.dayMs { w = 20 } else { w = 10 }
    return Int(u.n * w)
  }

  func usageScore(_ key: String) -> Int {
    guard let u = usage[key] else { return 0 }
    return min(frecency(u, env.now()) / 2, 150)
  }

  func bump(_ key: String, title: String, url: String) {
    // A private window leaves no history: nothing it opens is counted or remembered.
    if env.call("window", "get").b("private") { return }
    var u = usage[key] ?? Usage(n: 0, t: 0, title: title, url: url)
    u.n += 1
    u.t = env.now()
    if !title.isEmpty { u.title = title }
    if !url.isEmpty { u.url = url }
    usage[key] = u
    saveUsage()
  }

  /// How well `query` matches: every word must hit the title, a keyword or the URL. nil = no match.
  static func match(_ query: String, title: String, url: String = "", keywords: [String] = []) -> Int? {
    let words = split(Text.lower(query))
    if words.isEmpty { return 0 }
    let t = Text.lower(title), u = Text.lower(url)
    let host = URLs.host(u)
    var total = 0
    for w in words {
      var best = 0
      if Text.hasPrefix(t, w) { best = 100 } else if wordPrefix(t, w) { best = 70 } else if Text.contains(t, w) { best = 40 }
      for k in keywords where best < 80 {
        let kl = Text.lower(k)
        if Text.hasPrefix(kl, w) || wordPrefix(kl, w) { best = max(best, 60) }
      }
      if !u.isEmpty && best < 60 {
        if Text.hasPrefix(host, w) { best = max(best, 60) } else if Text.contains(u, w) { best = max(best, 20) }
      }
      if best == 0 { return nil }
      total += best
    }
    return total / words.count
  }

  static func wordPrefix(_ s: String, _ w: String) -> Bool {
    let a = Array(s.utf8), b = Array(w.utf8)
    guard !b.isEmpty, a.count > b.count else { return false }
    for start in 1...(a.count - b.count) where !isWordByte(a[start - 1]) && isWordByte(a[start]) {
      var ok = true
      for j in 0..<b.count where a[start + j] != b[j] {
        ok = false
        break
      }
      if ok { return true }
    }
    return false
  }

  static func isWordByte(_ c: UInt8) -> Bool { (c >= 48 && c <= 57) || (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || c >= 128 }

  static func split(_ s: String) -> [String] {
    var out: [String] = []
    var cur: [UInt8] = []
    for c in s.utf8 {
      if c == 32 || c == 9 {
        if !cur.isEmpty { out.append(String(decoding: cur, as: UTF8.self)) }
        cur = []
      } else {
        cur.append(c)
      }
    }
    if !cur.isEmpty { out.append(String(decoding: cur, as: UTF8.self)) }
    return out
  }

  func trim(_ s: String) -> String {
    let b = Array(s.utf8)
    var i = 0, j = b.count
    while i < j, b[i] == 32 || b[i] == 9 || b[i] == 10 { i += 1 }
    while j > i, b[j - 1] == 32 || b[j - 1] == 9 || b[j - 1] == 10 { j -= 1 }
    return String(decoding: b[i..<j], as: UTF8.self)
  }

  // MARK: - URLs and search

  /// A typed string that should be opened as a URL, or nil. Mirrors WebViewsService.normalize.
  static func url(from input: String) -> String? {
    let s = input
    if s.isEmpty || Text.contains(s, " ") { return nil }
    let l = Text.lower(s)
    for scheme in ["http://", "https://", "about:", "file://", "data:"] where Text.hasPrefix(l, scheme) { return s }
    if Text.hasPrefix(l, "localhost") { return "http://" + s }
    // host[:port][/path] with a dot and a TLD of letters (example.com), or an IPv4 address.
    var hostEnd = s.utf8.count
    for (i, c) in s.utf8.enumerated() where c == 47 || c == 58 || c == 63 || c == 35 {
      hostEnd = i
      break
    }
    let host = Array(l.utf8)[0..<hostEnd]
    guard let lastDot = host.lastIndex(of: 46), lastDot > host.startIndex else { return nil }
    let tld = host[(lastDot + 1)...]
    let allDigits = host.allSatisfy { ($0 >= 48 && $0 <= 57) || $0 == 46 }
    if allDigits { return "http://" + s }
    guard tld.count >= 2, tld.allSatisfy({ $0 >= 97 && $0 <= 122 }) else { return nil }
    guard host.allSatisfy({ ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 46 || $0 >= 128 }) else { return nil }
    return "https://" + s
  }

  static func encode(_ s: String) -> String {
    let hex: [UInt8] = Array("0123456789ABCDEF".utf8)
    var out: [UInt8] = []
    for c in s.utf8 {
      let unreserved = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 45 || c == 46 || c == 95 || c == 126
      if unreserved {
        out.append(c)
      } else if c == 32 {
        out.append(43)  // +
      } else {
        out.append(37)
        out.append(hex[Int(c >> 4)])
        out.append(hex[Int(c & 15)])
      }
    }
    return String(decoding: out, as: UTF8.self)
  }

  static func searchURL(_ engine: Engine, _ q: String) -> String {
    let parts = Array(engine.url.utf8)
    guard let i = URLs.find(parts, Array("%s".utf8)) else { return engine.url + encode(q) }
    return String(decoding: parts[..<i], as: UTF8.self) + encode(q) + String(decoding: parts[(i + 2)...], as: UTF8.self)
  }

  var defaultEngine: Engine { engines[0] }

  // MARK: - Results

  func compute() {
    let q = trim(query)
    var secs: [(String, [Row])] = []
    switch scope {
    case .main:
      secs = mainResults(q)
    case .actions:
      secs = [("Actions", commandRows(q, limit: 50))]
    case let .engine(i):
      let e = engines[i]
      if !q.isEmpty {
        secs = [("", [Row(id: "search", icon: "sf:magnifyingglass", title: q, subtitle: "— Search " + e.name, act: .search(Self.searchURL(e, q)))])]
      }
    case let .rename(id):
      secs = [("", [Row(id: "rename", icon: "sf:pencil", title: q.isEmpty ? "Untitled" : q, subtitle: "— Rename Tab", act: .rename(id))])]
    case .archive:
      secs = [("Archive", archiveRows(q, limit: 50, exclude: []))]
    case .split:
      var top: [Row] = []
      if !q.isEmpty { top = goRows(q) }
      let sel = selectedTab().s("id")
      secs = [("", top), ("Tabs", tabRows(q, limit: 6).filter { $0.act != .tab(sel) })]
    case let .options(key):
      secs = [(settingTitle(key), optionRows(key, q))]
    case let .pane(id):
      secs = [(paneTitle(id), paneRows(id, q))]
    case .shortcuts:
      secs = [("Keyboard Shortcuts", shortcutRows(q))]
    }
    sections = secs.filter { !$0.1.isEmpty }
    rows = sections.flatMap { $0.1 }
    if !rows.contains(where: { $0.id == selected }) { selected = rows.first?.id ?? "" }
  }

  /// The top rows: reload (Cmd-L, unchanged URL), go to URL, web search, site-search hint.
  func goRows(_ q: String) -> [Row] {
    var top: [Row] = []
    let unchanged = mode == "edit" && q == editURL && !q.isEmpty
    if unchanged {
      // Cmd-L then Enter reloads (Arc).
      top.append(Row(id: "reload", icon: "sf:arrow.clockwise", title: URLs.display(q), subtitle: "— Reload", act: .reload))
    }
    // An existing local file or folder: open it (never a web search for a path on this Mac).
    if !unchanged, let f = localFile(q) {
      top.append(fileRow(q, f))
      return top
    }
    let u = Self.url(from: q)
    if let u, !unchanged {
      top.append(Row(id: "go", icon: URLs.favicon(u), title: q, subtitle: mode == "edit" ? "— Go to URL" : "— Open URL", act: .url(u), key: "url:" + URLs.normalize(u)))
    }
    // A full URL with a scheme is never a search.
    if u == nil || !Text.contains(q, "://") {
      top.append(Row(id: "search", icon: "sf:magnifyingglass", title: q, subtitle: "— Search " + defaultEngine.name, act: .search(Self.searchURL(defaultEngine, q))))
    }
    if let i = engineIndex(Text.lower(q)) {
      top.append(Row(id: "scope:" + engines[i].keyword, icon: "sf:magnifyingglass.circle", title: "Search " + engines[i].name, subtitle: "— Press Tab", keycap: "⇥", act: .scope(i)))
    }
    return top
  }

  /// Main results, in tiers so rows keep their place while typing and when web suggestions
  /// arrive: a top hit (a den command or setting whose title or alias starts with the query) above
  /// the go/search rows, then strong local matches (den, Settings, tabs, history, spaces, windows),
  /// web suggestions, then weak local matches. Rows and section headers share one height budget
  /// (`maxRows` rows); room for two suggestions stays reserved, so their arrival never pushes a
  /// strong match out.
  func mainResults(_ q: String) -> [(String, [Row])] {
    if q.isEmpty {
      // Nothing typed (Cmd-T): the most recent tabs, then suggested actions, like Arc.
      let tabs = allTabs().sorted { $0.i("lastActive") > $1.i("lastActive") }
      let sel = selectedTab().s("id")
      let recent = Array(tabs.filter { $0.s("id") != sel }.prefix(4).map { tabRow($0, score: 0) })
      let budget = Self.maxRows * Self.rowCost - 2 * Self.headerCost - recent.count * Self.rowCost
      return [("Tabs", recent), ("den", commandRows("", limit: budget / Self.rowCost))]
    }
    var go = goRows(q)
    let openURLs = allTabs().map { URLs.normalize($0.s("url")) }
    var den = launcherRows(q, settings: false, limit: 4)
    var settings = launcherRows(q, settings: true, limit: 4)
    // Top hit (Raycast/Arc): a well-matched den row goes above "Search Google".
    if let hit = topHit(q, den.first, settings.first) {
      den.removeAll { $0.id == hit.id }
      settings.removeAll { $0.id == hit.id }
      go.insert(hit, at: 0)
    }
    let local: [(String, [Row])] = [
      ("den", den),
      ("Settings", settings),
      ("Tabs", tabRows(q, limit: 3)),
      ("History", historyRows(q, exclude: openURLs)),
      ("Spaces", spaceRows(q)),
      ("Windows", windowRows(q)),
    ]
    let sugg = suggestionRows(q)
    let reserve = suggestible(q) ? Self.headerCost + min(Self.reservedSuggestions, Self.maxSuggestions) * Self.rowCost : 0
    var left = Self.maxRows * Self.rowCost - go.count * Self.rowCost
    var out: [(String, [Row])] = [("", go)]
    // A path: its folder's matching files right below (Finder-style completion).
    let files = fileRows(q, limit: 5)
    if !files.isEmpty {
      // A partial path that names no file yet: its first match is the first row (Enter opens it).
      if localFile(q) == nil { out.insert(("Files", files), at: 0) } else { out.append(("Files", files)) }
      left -= Self.headerCost + files.count * Self.rowCost
    }
    /// Adds up to `rows` to section `title` (merged into an earlier one of the same name) while
    /// `limit` points last; a new header costs `headerCost`.
    func add(_ title: String, _ rows: [Row], _ limit: inout Int) {
      guard !rows.isEmpty else { return }
      var i = out.firstIndex { $0.0 == title }
      var taken: [Row] = []
      for r in rows {
        let cost = Self.rowCost + (i == nil && taken.isEmpty ? Self.headerCost : 0)
        guard cost <= limit, cost <= left else { break }
        limit -= cost
        left -= cost
        taken.append(r)
      }
      guard !taken.isEmpty else { return }
      if i == nil {
        out.append((title, []))
        i = out.count - 1
      }
      out[i!].1 += taken
    }
    // Strong local matches, leaving room for the reserved suggestions.
    var strongLeft = max(0, left - reserve)
    for (title, rs) in local { add(title, rs.filter { $0.strength >= Self.strongMatch }, &strongLeft) }
    var suggLeft = Self.headerCost + Self.maxSuggestions * Self.rowCost
    add("Suggestions", sugg, &suggLeft)
    var weakLeft = left
    for (title, rs) in local { add(title, rs.filter { $0.strength < Self.strongMatch }, &weakLeft) }
    return out
  }

  // MARK: - Web suggestions

  /// Suggestions only make sense for a typed search in the main scope (not a full URL).
  func suggestible(_ q: String) -> Bool {
    // Never a local path: it stays on this Mac.
    suggestionsOn && scope == .main && !q.isEmpty && !Text.contains(q, "://") && !(mode == "edit" && q == editURL) && !Self.pathLike(q)
  }

  /// Asks for web suggestions (WebSuggestions). A cached answer comes back at once; otherwise it
  /// arrives later through `suggestionsArrived`. Nothing happens without the `net` service.
  func requestSuggestions() {
    let q = trim(query)
    guard isOpen, suggestible(q) else { return }
    if let items = suggest.query(q) {
      suggestQuery = WebSuggestions.normalize(q)
      suggestItems = items
    }
  }

  func suggestionsArrived(_ q: String, _ items: [String]) {
    guard isOpen, q == Self.normQuery(trim(query)) else { return }  // stale: the user typed on
    suggestQuery = q
    suggestItems = items
    render()
  }

  func suggestionRows(_ q: String) -> [Row] {
    guard suggestible(q) else { return [] }
    let nq = Self.normQuery(q)
    let fresh: [String]? = suggestQuery == nq ? suggestItems : nil
    shownSuggestions = Self.mergeSuggestions(shown: shownSuggestions, fresh: fresh, query: nq, limit: Self.maxSuggestions)
    return shownSuggestions.map { text in
      if !Text.contains(text, " "), let u = Self.url(from: text) {
        return Row(id: "sugg:" + text, icon: URLs.favicon(u), title: text, subtitle: "— Open URL", act: .url(u), key: "url:" + URLs.normalize(u))
      }
      return Row(id: "sugg:" + text, icon: "sf:magnifyingglass", title: text, act: .search(Self.searchURL(defaultEngine, text)), key: "q:" + Text.lower(text))
    }
  }

  /// Lowercased, trimmed, inner whitespace collapsed (the `suggest` service's cache key).
  static func normQuery(_ s: String) -> String {
    var out = ""
    for w in split(Text.lower(s)) { out += out.isEmpty ? w : " " + w }
    return out
  }

  /// The suggestions to show for `query`. Stable while typing: rows already on screen keep their
  /// order. While the answer for `query` is pending (`fresh == nil`), shown rows that still extend
  /// the query stay; when it arrives, shown rows it confirms come first, then its new ones.
  /// The query itself is left out (the search row covers it), as are duplicates.
  static func mergeSuggestions(shown: [String], fresh: [String]?, query: String, limit: Int) -> [String] {
    let q = normQuery(query)
    var out: [String] = []
    var keys: [String] = []
    func add(_ s: String) {
      let k = normQuery(s)
      guard out.count < limit, !k.isEmpty, k != q, !keys.contains(k) else { return }
      out.append(s)
      keys.append(k)
    }
    guard let fresh else {
      for s in shown where Text.hasPrefix(normQuery(s), q) { add(s) }
      return out
    }
    let freshKeys = fresh.map { normQuery($0) }
    for s in shown where freshKeys.contains(normQuery(s)) { add(s) }
    for s in fresh { add(s) }
    return out
  }

  func tabRow(_ t: Value, score: Int, strength: Int = 0) -> Row {
    let current = env.call("spaces", "current").s("id")
    var sub = Self.dash(URLs.display(t.s("url")))
    let sid = t.s("spaceId")
    if !sid.isEmpty && sid != current {
      for sp in env.call("spaces", "list").array ?? [] where sp.s("id") == sid { sub += " · " + sp.s("name") }
    }
    return Row(
      id: "tab:" + t.s("id"), icon: URLs.icon(t.sOpt("favicon"), t.s("url")), title: URLs.pageTitle(t.s("title"), t.s("url")), subtitle: sub, accessory: "Switch to Tab",
      keycap: "→", act: .tab(t.s("id")), key: "tab:" + t.s("id"), score: score, strength: strength)
  }

  func tabRows(_ q: String, limit: Int) -> [Row] {
    var out: [Row] = []
    for t in allTabs() {
      guard let m = Self.match(q, title: t.s("title"), url: t.s("url")) else { continue }
      let s = m + 10 + usageScore("tab:" + t.s("id")) + usageScore("url:" + URLs.normalize(t.s("url")))
      out.append(tabRow(t, score: s, strength: m))
    }
    return Self.top(out, limit)
  }

  /// Commands only (actions mode and the empty bar), matched through the launcher index.
  func commandRows(_ q: String, limit: Int) -> [Row] {
    ensureIndex()
    let wq = Matcher.words(q)
    var out: [Row] = []
    var n = 0
    for e in index where e.kind == .command {
      n += 1
      guard let m = Matcher.score(wq, e) else { continue }
      // Empty query: most used first, then the built-in order.
      let s = (q.isEmpty ? 0 : m) + usageScore(e.usageKey) - (q.isEmpty ? n : 0)
      out.append(entryRow(e, strength: m, score: s))
    }
    return Self.top(out, limit)
  }

  func spaceRows(_ q: String) -> [Row] {
    let current = env.call("spaces", "current").s("id")
    var out: [Row] = []
    for sp in env.call("spaces", "list").array ?? [] {
      let id = sp.s("id")
      guard id != current, let m = Self.match(q, title: sp.s("name"), keywords: ["space"]) else { continue }
      out.append(Row(
        id: "space:" + id, icon: sp.sOpt("icon") ?? "sf:square.stack", title: sp.s("name"), subtitle: "— Switch to Space", act: .space(id),
        key: "space:" + id, score: m + usageScore("space:" + id), strength: m))
    }
    return Self.top(out, 3)
  }

  /// Pages opened from the bar before, and archived tabs, minus what's open.
  func historyRows(_ q: String, exclude: [String]) -> [Row] {
    var out: [Row] = []
    var seen = exclude
    for k in usage.keys.sorted() where Text.hasPrefix(k, "url:") {
      let u = usage[k]!
      let norm = URLs.normalize(u.url)
      guard !u.url.isEmpty, !seen.contains(norm), let m = Self.match(q, title: u.title, url: u.url) else { continue }
      seen.append(norm)
      out.append(Row(id: "hist:" + norm, icon: URLs.favicon(u.url), title: URLs.pageTitle(u.title, u.url), subtitle: Self.dash(URLs.display(u.url)),
                     act: .url(u.url), key: k, score: m + usageScore(k), strength: m))
    }
    out += archiveRows(q, limit: 10, exclude: seen)
    return Self.top(out, 3)
  }

  func archiveRows(_ q: String, limit: Int, exclude: [String]) -> [Row] {
    var out: [Row] = []
    var seen = exclude
    for (n, e) in (env.call("tabs", "archive").array ?? []).enumerated() {
      let u = e.s("url")
      let norm = URLs.normalize(u)
      guard !seen.contains(norm), let m = Self.match(q, title: e.s("title"), url: u) else { continue }
      seen.append(norm)
      let key = "url:" + norm
      out.append(Row(id: "arch:" + e.s("id"), icon: URLs.icon(e.sOpt("favicon"), u), title: URLs.pageTitle(e.s("title"), u),
                     subtitle: Self.dash(URLs.display(u)), accessory: "Archived", act: .archived(e.s("id"), u), key: key,
                     score: (q.isEmpty ? -n : m - 5) + usageScore(key), strength: m))
    }
    return Self.top(out, limit)
  }

  /// "— example.com", or nothing when there is no domain to show.
  static func dash(_ s: String) -> String { s.isEmpty ? "" : "— " + s }

  /// The best `limit` rows, keeping the input order among equal scores.
  static func top(_ rows: [Row], _ limit: Int) -> [Row] {
    let order = Array(0..<rows.count).sorted { rows[$0].score != rows[$1].score ? rows[$0].score > rows[$1].score : $0 < $1 }
    return order.prefix(limit).map { rows[$0] }
  }

  // MARK: - Default-browser banner

  func stored(_ key: String) -> Value { env.call("storage", "get", ["ns": .string(Self.ns), "key": .string(key)]) }
  func store(_ key: String, _ v: Value) { env.call("storage", "set", ["ns": .string(Self.ns), "key": .string(key), "value": v]) }

  /// Arc's banner under the rows, in the main scope, while den isn't the default browser and the
  /// banner isn't snoozed. The default browser is read once per open-after-change (no launch cost).
  var bannerVisible: Bool {
    guard scope == .main else { return false }
    if !browserChecked {
      browserChecked = true
      let r = env.call("app", "defaultBrowser")
      isDefaultBrowser = r.isErr || r.isNull || r.b("isDefault")  // no `app` service: never nag
      currentBrowser = r.s("bundleId")
      currentBrowserName = r.s("name")
    }
    return !isDefaultBrowser && stored("bannerDismissed").bool != true
  }

  func bannerButton(_ b: String) {
    switch b {
    case "set":
      env.call("app", "setDefaultBrowser")
    case "try":
      // Remember what to go back to, then ask macOS to make den the default.
      store("browserTrial", ["previous": .string(currentBrowser), "name": .string(currentBrowserName), "start": .int(env.now())])
      env.call("app", "setDefaultBrowser")
      checkTrial()
    case "close":
      store("bannerDismissed", true)
      env.call("settings", "set", ["id": .string(Self.ns), "key": "banner", "value": false])
      render()
    default:
      break
    }
  }

  /// A running "Try for a week": after 7 days, ask whether to keep den. Checked at start and hourly
  /// while a trial runs.
  func checkTrial() {
    let t = stored("browserTrial")
    guard !t.isNull else { return }
    if env.now() - t.i("start") >= Self.trialMs {
      promptTrial(t)
    } else if !trialTimer {
      trialTimer = true
      env.timer(3_600_000, true) { [self] in checkTrial() }
    }
  }

  func promptTrial(_ t: Value) {
    let r = env.call("app", "defaultBrowser")
    guard !r.isErr, r.b("isDefault") else {
      store("browserTrial", .null)  // they switched away already (or declined): nothing to ask
      return
    }
    let prev = t.sOpt("name") ?? "your previous browser"
    env.call("ui", "set", [
      "slot": "dialog",
      "tree": [
        "type": "dialog", "id": .string(Self.trialDialog), "icon": "app:icon", "title": "Keep den as your default browser?",
        "message": .string("It’s been a week. You can switch back to " + prev + " now, or any time in System Settings."),
        "buttons": [
          ["id": "switch", "title": .string("Switch back to " + prev), "style": "secondary"],
          ["id": "keep", "title": "Keep den", "style": "default"],
        ],
      ],
    ])
  }

  func trialAnswered(_ button: String) {
    let t = stored("browserTrial")
    env.call("ui", "set", ["slot": "dialog", "tree": .null])
    store("browserTrial", .null)
    if button == "switch", let prev = t.sOpt("previous") { env.call("app", "setDefaultBrowser", ["bundleId": .string(prev)]) }
  }

  // MARK: - Render

  var placeholder: String {
    switch scope {
    case .main: return mode == "edit" ? "Enter URL or search" : "Search or Enter URL…"
    case .actions: return "Search actions…"
    case let .engine(i): return "Search " + engines[i].name + "…"
    case .rename: return "Tab name"
    case .archive: return "Search archived tabs…"
    case .split: return "Open on the right…"
    case let .options(k): return settingTitle(k)
    case let .pane(p): return "Search " + paneTitle(p) + " settings…"
    case .shortcuts: return "Search shortcuts…"
    }
  }

  func render(replace: Bool = false) {
    guard isOpen else { return }
    compute()
    var secs: [Value] = []
    for (title, rs) in sections {
      var list: [Value] = []
      for r in rs {
        var v: Value = ["id": .string(r.id), "icon": .string(r.icon), "title": .string(r.title)]
        if !r.subtitle.isEmpty { v.put("subtitle", .string(r.subtitle)) }
        if !r.accessory.isEmpty { v.put("accessory", .string(r.accessory)) }
        if !r.shortcut.isEmpty { v.put("shortcut", .string(r.shortcut)) }
        if let on = r.toggle { v.put("toggle", .bool(on)) }
        // Tab and settings rows always show their arrow keycap; other rows show ↩ when selected.
        let cap = r.keycap.isEmpty && r.id == selected ? "↩" : r.keycap
        if !cap.isEmpty { v.put("keycap", .string(cap)) }
        list.append(v)
      }
      var s: Value = ["rows": .array(list)]
      if !title.isEmpty { s.put("title", .string(title)) }
      secs.append(s)
    }
    var banner: Value = .null
    if bannerVisible {
      banner = ["text": "den works best as your default browser", "secondary": "Try for a week", "primary": "Set den as default"]
    }
    env.call("ui", "set", [
      "slot": .string(Self.slot),
      "tree": [
        "banner": banner,
        "type": "commandBar", "id": .string(Self.barId), "query": .string(query), "replaceQuery": .bool(replace), "placeholder": .string(placeholder),
        "selected": .string(selected), "sections": .array(secs),
        // Section headers (den, Settings, Tabs, Suggestions…); the go/search rows have none.
        "headers": true,
        // Caret and selection color follow the mode (Go for URL-shaped input, else Search).
        "inputMode": .string(Self.url(from: trim(query)) != nil || localFile(trim(query)) != nil ? "go" : "search"),
      ],
    ])
  }
}
