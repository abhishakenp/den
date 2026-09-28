// The `panels` plugin: web panels. Narrow web apps (chat, AI chat sites, reference, dashboards)
// docked left of the page, the same across every tab and space, sliding out from the sidebar
// edge. Optional: `[plugins] disabled = ["panels"]` in config.toml removes it. See
// docs/plugin-services.md.

#if !hasFeature(Embedded)
  import CordisValue
#endif

/// Web panels over two host primitives: `content.side` (one web view in a column beside the
/// panes, with the `side.header` ui slot above it) and ordinary `webviews` (each panel is a web
/// view `panel-<n>`, created on first show, with Safari's iPhone user agent when "Phone layout"
/// is on for it).
///
/// - ⌃⌘S shows or hides the last panel (with none yet, it opens Settings ▸ Web Panels).
/// - The header: a button per panel (its site icon) to switch, the panel's name, "+" (add this
///   tab, or a suggested site: Claude, Gemini, ChatGPT, WhatsApp, Slack, Discord), a "…" menu
///   (open as a tab, reload, phone layout, remove) and hide (⌃⌘S).
/// - Hidden panels sleep: 30 s after a panel leaves the screen its web view is discarded
///   (`webviews.suspend`, the same full discard as a tab; one playing audio keeps going).
/// - Settings ▸ Web Panels: add a panel by address, the list with Remove.
///
/// Storage ns `panels`: `list [{id, url, title, mobile}]`, `state {open, last, width}`.
/// Cost: nothing but one key binding, a command and a settings section until a panel is shown.
final class PanelsCore {
  struct Panel {
    var id: String
    var url: String
    var title: String
    var mobile: Bool
    var created = false
    var value: Value { ["id": .string(id), "url": .string(url), "title": .string(title), "mobile": .bool(mobile)] }
  }

  static let ns = "panels"
  static let toggleChord = "ctrl+cmd+s"
  static let sleepAfterMs: UInt64 = 30_000
  static let defaultWidth = 390
  /// Suggested in the "+" menu: (title, URL).
  static let suggestions: [(String, String)] = [
    ("Claude", "https://claude.ai"), ("Gemini", "https://gemini.google.com"), ("ChatGPT", "https://chatgpt.com"),
    ("WhatsApp", "https://web.whatsapp.com"), ("Slack", "https://app.slack.com"), ("Discord", "https://discord.com/app"),
  ]

  let env: PluginEnv
  var panels: [Panel] = []
  /// The panel on screen, and the last one shown (⌃⌘S brings it back).
  var open: String?
  var last: String?
  var width = PanelsCore.defaultWidth
  var nextId = 1
  /// Bumped whenever a panel is shown: a pending sleep for an older hide is dropped.
  var sleepGeneration: [String: Int] = [:]
  var commandsRegistered = false
  var registerAttempts = 0

  init(env: PluginEnv) { self.env = env }

  func start() {
    let list = env.call("storage", "get", ["ns": .string(Self.ns), "key": "list"]).array ?? []
    panels = list.compactMap { v in
      let id = v.s("id"), url = v.s("url")
      guard !id.isEmpty, !url.isEmpty else { return nil }
      return Panel(id: id, url: url, title: v.s("title"), mobile: v.b("mobile"))
    }
    for p in panels { if let n = Text.int(Text.dropPrefix(p.id, "panel-")), n >= nextId { nextId = n + 1 } }
    let st = env.call("storage", "get", ["ns": .string(Self.ns), "key": "state"])
    last = st.sOpt("last")
    width = Int(st.i("width", Int64(Self.defaultWidth)))
    env.call("keys", "bind", ["chord": .string(Self.toggleChord), "event": "panels.key.toggle", "title": "Toggle Web Panel", "menu": "View"])
    env.on("panels.key.toggle") { [self] _ in toggle() }
    env.on("ui.action") { [self] v in action(v.s("id"), v.s("action"), v["value"]) }
    env.on("commands.run") { [self] v in command(v.s("id")) }
    env.on("settings.action") { [self] v in settingsAction(v) }
    env.on("webviews.title") { [self] v in
      guard let i = index(v.s("id")), panels[i].title != v.s("title"), !v.s("title").isEmpty else { return }
      panels[i].title = v.s("title")
      save()
      if open == panels[i].id { renderHeader() }
    }
    env.on("webviews.favicon") { [self] v in if open == v.s("id") { renderHeader() } }
    registerSettings()
    registerCommands()
    // The panel that was open when den quit comes back, after launch (not on its critical path).
    if st.b("open"), let l = last, index(l) != nil {
      env.timer(1500, false) { [self] in if open == nil, index(l) != nil { show(l) } }
    }
  }

  func stop() {
    registerAttempts = Int.max / 2
    env.call("keys", "unbind", ["chord": .string(Self.toggleChord)])
    if open != nil { env.call("content", "side") }
    env.call("ui", "set", ["slot": "side.header", "tree": .null])
    for p in panels where p.created { env.call("webviews", "close", ["id": .string(p.id)]) }
    env.call("settings", "unregister", ["id": .string(Self.ns)])
    for c in ["panels.toggle", "panels.addTab", "panels.add"] { env.call("commands", "unregister", ["id": .string(c)]) }
  }

  func index(_ id: String) -> Int? { panels.firstIndex { $0.id == id } }

  func save() {
    env.call("storage", "set", ["ns": .string(Self.ns), "key": "list", "value": .array(panels.map { $0.value })])
    env.call("storage", "set", ["ns": .string(Self.ns), "key": "state", "value": [
      "open": .bool(open != nil), "last": .str(last), "width": .int(Int64(width)),
    ]])
  }

  // MARK: Showing and hiding

  func toggle() {
    if open != nil { hide(); return }
    if let l = last, index(l) != nil { show(l); return }
    if let first = panels.first { show(first.id); return }
    env.call("settings", "open", ["id": .string(Self.ns)])
  }

  func show(_ id: String) {
    guard let i = index(id) else { return }
    if !panels[i].created {
      // An earlier den (or a discard) may have left the id behind: start from the saved URL.
      env.call("webviews", "close", ["id": .string(id)])
      var args: Value = ["id": .string(id), "url": .string(panels[i].url)]
      if panels[i].mobile { args.put("userAgent", "mobile") }
      env.call("webviews", "create", args)
      panels[i].created = true
    }
    let previous = open
    open = id
    last = id
    sleepGeneration[id, default: 0] += 1
    env.call("content", "side", ["webview": .string(id), "width": .int(Int64(width))])
    renderHeader()
    if let p = previous, p != id { scheduleSleep(p) }
    save()
  }

  func hide() {
    guard let id = open else { return }
    open = nil
    env.call("content", "side")
    env.call("ui", "set", ["slot": "side.header", "tree": .null])
    scheduleSleep(id)
    save()
  }

  /// A hidden panel is discarded after `sleepAfterMs` unless it was shown again meanwhile. The
  /// host refuses one that plays audio (it keeps playing; the next hide tries again).
  func scheduleSleep(_ id: String) {
    let gen = sleepGeneration[id, default: 0] + 1
    sleepGeneration[id] = gen
    env.timer(Self.sleepAfterMs, false) { [self] in
      guard sleepGeneration[id] == gen, open != id, index(id) != nil else { return }
      env.call("webviews", "suspend", ["id": .string(id)])
    }
  }

  // MARK: Adding and removing

  @discardableResult
  func add(_ raw: String, title: String = "", show now: Bool = true) -> String? {
    let url = Self.normalize(raw)
    guard !url.isEmpty else { return nil }
    let id = "panel-" + String(nextId)
    nextId += 1
    panels.append(Panel(id: id, url: url, title: title.isEmpty ? URLs.title(url) : title, mobile: false))
    save()
    registerSettings()
    if now { show(id) } else if open != nil { renderHeader() }
    return id
  }

  /// "claude.ai" -> "https://claude.ai". Only http(s) pages can be panels.
  static func normalize(_ raw: String) -> String {
    var b = Array(raw.utf8)
    while let f = b.first, f == 32 || f == 9 || f == 10 { b.removeFirst() }
    while let l = b.last, l == 32 || l == 9 || l == 10 { b.removeLast() }
    let s = String(decoding: b, as: UTF8.self)
    if s.isEmpty || b.contains(32) { return "" }
    if URLs.isWeb(s) { return s }
    if Text.contains(s, "://") { return "" }
    return b.contains(46) ? "https://" + s : ""  // needs a dot: "claude.ai"
  }

  /// The selected tab's page as a new panel (it stays a tab too).
  func addCurrentTab() {
    guard let tab = env.call("tabs", "selected")["id"].string else { return }
    let page = env.call("webviews", "get", ["id": .string(tab)])
    guard URLs.isWeb(page.s("url")) else {
      env.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": "Only web pages can be panels", "icon": "sf:exclamationmark.circle"]])
      return
    }
    add(page.s("url"), title: page.s("title"))
  }

  func remove(_ id: String) {
    guard let i = index(id) else { return }
    if open == id { hide() }
    if panels[i].created { env.call("webviews", "close", ["id": .string(id)]) }
    panels.remove(at: i)
    if last == id { last = panels.first?.id }
    sleepGeneration[id] = nil
    save()
    registerSettings()
  }

  /// Recreates the panel's web view with (or without) Safari's iPhone user agent.
  func setMobile(_ id: String, _ on: Bool) {
    guard let i = index(id) else { return }
    panels[i].mobile = on
    save()
    guard panels[i].created else { return }
    let wasOpen = open == id
    if wasOpen { env.call("content", "side") }
    env.call("webviews", "close", ["id": .string(id)])
    panels[i].created = false
    if wasOpen { open = nil; show(id) }
  }

  func openAsTab(_ id: String) {
    guard let p = panels.first(where: { $0.id == id }) else { return }
    let url = env.call("webviews", "get", ["id": .string(id)]).sOpt("url") ?? p.url
    env.call("tabs", "open", ["url": .string(url)])
  }

  // MARK: Header

  func renderHeader() {
    guard let id = open, let cur = panels.first(where: { $0.id == id }) else { return }
    var kids: [Value] = []
    for p in panels.prefix(8) {
      let icon = URLs.favicon(p.url)
      kids.append(["type": "action", "id": .string("panels.switch:" + p.id), "icon": .string(icon), "tooltip": .string(p.title),
                   "height": 30, "width": 30, "iconSize": 16, "tone": p.id == id ? "strong" : "default"])
    }
    var addMenu: [Value] = [["id": "addTab", "title": "Add This Tab", "icon": "sf:plus.square.on.square"], ["separator": true]]
    for (t, u) in Self.suggestions where !panels.contains(where: { URLs.host($0.url) == URLs.host(u) }) {
      addMenu.append(["id": .string("add:" + u), "title": .string(t), "icon": "sf:globe"])
    }
    addMenu.append(["separator": true])
    addMenu.append(["id": "addURL", "title": "Other Address…", "icon": "sf:link"])
    kids.append(["type": "label", "text": .string(cur.title), "size": 12, "weight": "medium", "tone": "secondary"])
    kids.append(["type": "action", "id": "panels.add", "icon": "sf:plus", "tooltip": "Add a Panel", "height": 30, "width": 30, "iconSize": 14, "menu": .array(addMenu)])
    kids.append(["type": "action", "id": "panels.more", "icon": "sf:ellipsis", "tooltip": "Panel Options", "height": 30, "width": 30, "iconSize": 14, "menu": [
      ["id": "tab", "title": "Open as Tab", "icon": "sf:arrow.up.forward.square"],
      ["id": "reload", "title": "Reload Panel", "icon": "sf:arrow.clockwise"],
      ["id": "mobile", "title": "Phone Layout", "icon": "sf:iphone", "checked": .bool(cur.mobile)],
      ["separator": true],
      ["id": "remove", "title": "Remove Panel", "icon": "sf:trash", "destructive": true],
    ]])
    kids.append(["type": "action", "id": "panels.hide", "icon": "sf:sidebar.left", "tooltip": "Hide Panel", "shortcut": .string(Self.toggleChord),
                 "height": 30, "width": 30, "iconSize": 14])
    env.call("ui", "set", ["slot": "side.header", "tree": ["type": "stack", "id": "panels.header", "axis": "h", "spacing": 2, "height": 30,
                                                           "padding": [2, 2, 0, 2], "children": .array(kids)]])
  }

  /// Header nodes: `panels.switch:<id>`, `panels.add` (menu), `panels.more` (menu), `panels.hide`.
  func action(_ nodeId: String, _ action: String, _ value: Value) {
    guard Text.hasPrefix(nodeId, "panels.") else { return }
    if Text.hasPrefix(nodeId, "panels.switch:"), action == "click" {
      show(Text.dropPrefix(nodeId, "panels.switch:"))
      return
    }
    switch (nodeId, action) {
    case ("panels.hide", "click"): hide()
    case ("panels.add", "menu"):
      let item = value.string ?? ""
      if item == "addTab" { addCurrentTab() } else if item == "addURL" { env.call("settings", "open", ["id": .string(Self.ns)]) } else if Text.hasPrefix(item, "add:") {
        let u = Text.dropPrefix(item, "add:")
        add(u, title: Self.suggestions.first { $0.1 == u }?.0 ?? "")
      }
    case ("panels.more", "menu"):
      guard let id = open else { return }
      switch value.string ?? "" {
      case "tab": openAsTab(id)
      case "reload": env.call("webviews", "reload", ["id": .string(id)])
      case "mobile": setMobile(id, !(panels.first { $0.id == id }?.mobile ?? false))
      case "remove": remove(id)
      default: break
      }
    default: break
    }
  }

  // MARK: Commands and settings

  func command(_ id: String) {
    switch id {
    case "panels.toggle": toggle()
    case "panels.addTab": addCurrentTab()
    case "panels.add": env.call("settings", "open", ["id": .string(Self.ns)])
    default: break
    }
  }

  /// `commands` is optional (plugin `commandbar`) and may load later: retry every 500 ms for 30 s.
  func registerCommands() {
    if tryRegister() { return }
    env.timer(500, false) { [self] in
      registerAttempts += 1
      if !tryRegister(), registerAttempts < 60 { registerCommands() }
    }
  }

  @discardableResult
  func tryRegister() -> Bool {
    if commandsRegistered { return true }
    let r = env.call("commands", "register", ["id": "panels.toggle", "title": "Toggle Web Panel", "icon": "sf:sidebar.left", "shortcut": "⌃⌘S",
                                               "keywords": ["panel", "side", "chat", "dock"], "owner": "panels"])
    guard !r.isErr else { return false }
    env.call("commands", "register", ["id": "panels.addTab", "title": "Add This Tab as a Web Panel", "icon": "sf:plus.square.on.square",
                                      "keywords": ["panel", "side", "dock", "pin"], "owner": "panels"])
    env.call("commands", "register", ["id": "panels.add", "title": "Add a Web Panel…", "icon": "sf:plus", "keywords": ["panel", "side", "chat"], "owner": "panels"])
    commandsRegistered = true
    return true
  }

  /// Settings ▸ Web Panels: add by address, and the list with Remove.
  func registerSettings() {
    let items: [Value] = panels.map { p in
      ["id": .string(p.id), "title": .string(p.title), "subtitle": .string(URLs.display(p.url)), "icon": .string(URLs.favicon(p.url)),
       "buttons": [["id": "remove", "title": "Remove", "style": "destructive"]]]
    }
    env.call("settings", "register", [
      "id": .string(Self.ns), "title": "Web Panels", "icon": "sf:sidebar.left", "order": 42,
      "controls": [
        ["key": "add", "type": "text", "title": "Add a panel", "subtitle": "A site to keep beside every tab (⌃⌘S shows and hides it).",
         "placeholder": "claude.ai", "submit": true],
        ["key": "list", "type": "list", "title": "Panels", "items": .array(items), "empty": "No panels yet."],
      ],
    ])
  }

  func settingsAction(_ v: Value) {
    guard v.s("id") == Self.ns else { return }
    switch (v.s("key"), v.s("button")) {
    case ("add", _):
      if add(v.s("value")) == nil {
        env.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": "That doesn’t look like a web address", "icon": "sf:exclamationmark.circle"]])
      }
    case ("list", "remove"): remove(v.s("item"))
    default: break
    }
  }
}
