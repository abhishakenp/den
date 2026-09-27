// TEMPORARY stand-in for the spaces/tabs/command-bar plugins (enabled with --demo).
// It only talks to the host through service calls and events, exactly like a plugin will.
// Delete this file once the real plugins exist.
import AppKit
import CordisValue
import DenHost

@MainActor
final class DemoDriver {
  struct Tab { var id: String; var title: String; var url: String; var icon: String; var pinnedURL: String? = nil; var audio = false }
  struct Folder { var id: String; var title: String; var open: Bool; var tabs: [Tab] }
  struct Space { var name: String; var icon: String; var colors: [String]; var pinned: [Tab]; var folders: [Folder]; var today: [Tab]; var selected: String }

  let rt: DenRuntime
  var spaces: [Space] = []
  var favorites: [Tab] = []
  var current = 0
  var appearance = "light"
  var commandOpen = false
  var query = ""
  var commandSelected = ""
  var nextTab = 100
  var split: [String]? = nil
  var peeking: String?

  init(runtime: DenRuntime) { rt = runtime }

  static func fav(_ domain: String) -> String { "https://www.google.com/s2/favicons?domain=\(domain)&sz=64" }

  func start(appearance: String = "light") {
    self.appearance = appearance
    favorites = [
      Tab(id: "fav-github", title: "GitHub", url: "https://github.com", icon: Self.fav("github.com"), pinnedURL: "https://github.com"),
      Tab(id: "fav-gmail", title: "Gmail", url: "https://mail.google.com", icon: "https://ssl.gstatic.com/ui/v1/icons/mail/rfr/gmail.ico", pinnedURL: "https://mail.google.com"),
      Tab(id: "fav-cal", title: "Calendar", url: "https://calendar.google.com", icon: "https://calendar.google.com/googlecalendar/images/favicons_2020q4/calendar_31.ico", pinnedURL: "https://calendar.google.com"),
      Tab(id: "fav-yt", title: "YouTube", url: "https://www.youtube.com", icon: Self.fav("youtube.com"), pinnedURL: "https://www.youtube.com", audio: true),
    ]
    spaces = [
      Space(name: "Personal", icon: "sf:house.fill", colors: ["#c3b1ff", "#ffb3d1"], pinned: [
        Tab(id: "p-docs", title: "Apple Developer Documentation", url: "https://developer.apple.com/documentation", icon: Self.fav("developer.apple.com"), pinnedURL: "https://developer.apple.com/documentation"),
        Tab(id: "p-linear", title: "Linear", url: "https://linear.app", icon: Self.fav("linear.app"), pinnedURL: "https://linear.app"),
      ], folders: [
        Folder(id: "f-read", title: "Reading", open: true, tabs: [
          Tab(id: "p-swift", title: "The Swift Programming Language", url: "https://docs.swift.org/swift-book/", icon: Self.fav("swift.org")),
        ]),
      ], today: [
        Tab(id: "t-wiki", title: "Arc (web browser) - Wikipedia", url: "https://en.wikipedia.org/wiki/Arc_(web_browser)", icon: Self.fav("wikipedia.org")),
        Tab(id: "t-hn", title: "Hacker News", url: "https://news.ycombinator.com", icon: Self.fav("news.ycombinator.com")),
        Tab(id: "t-webkit", title: "WebKit Features for Safari 27.0", url: "https://webkit.org/blog/", icon: Self.fav("webkit.org")),
        Tab(id: "t-verge", title: "The Verge", url: "https://www.theverge.com", icon: Self.fav("theverge.com")),
      ], selected: "t-wiki"),
      Space(name: "Work", icon: "sf:briefcase.fill", colors: ["#8fd3ff", "#9af0d0"], pinned: [
        Tab(id: "w-linear", title: "Linear — My Issues", url: "https://linear.app", icon: Self.fav("linear.app"), pinnedURL: "https://linear.app"),
        Tab(id: "w-figma", title: "Figma", url: "https://www.figma.com", icon: Self.fav("figma.com"), pinnedURL: "https://www.figma.com"),
      ], folders: [], today: [
        Tab(id: "w-swift", title: "Swift.org", url: "https://www.swift.org", icon: Self.fav("swift.org")),
        Tab(id: "w-mdn", title: "MDN Web Docs", url: "https://developer.mozilla.org", icon: Self.fav("developer.mozilla.org")),
      ], selected: "w-swift"),
      Space(name: "Side Project", icon: "sf:hammer.fill", colors: ["#ffc78a", "#ff9b9b", "#ffe38a"], pinned: [
        Tab(id: "s-repo", title: "abhishakenp/den", url: "https://github.com/abhishakenp/den", icon: Self.fav("github.com"), pinnedURL: "https://github.com/abhishakenp/den"),
      ], folders: [], today: [
        Tab(id: "s-ex", title: "Example Domain", url: "https://example.com", icon: Self.fav("example.com")),
      ], selected: "s-ex"),
    ]
    // Register every tab lazily: no WKWebView is created until the tab is shown.
    for t in favorites + spaces.flatMap({ $0.pinned + $0.folders.flatMap(\.tabs) + $0.today }) {
      rt.call("webviews", "create", ["id": .string(t.id), "url": .string(t.url)])
    }
    // Pinned + favorite tabs open cross-site links in Peek.
    for t in favorites + spaces.flatMap(\.pinned) {
      rt.call("webviews", "setLinkPolicy", ["id": .string(t.id), "rules": [["when": "crossSite", "event": "demo.peek"]]])
    }
    rt.call("ui", "setPages", ["count": .int(Int64(spaces.count)), "current": 0])
    for (i, s) in spaces.enumerated() {
      rt.call("window", "setTheme", ["colors": .array(s.colors.map { .string($0) }), "intensity": 0.6, "grain": 0.3, "appearance": .string(appearance), "page": .int(Int64(i))])
      renderSpace(i)
    }
    renderGlobal()
    bindKeys()
    subscribe()
    showSelected()
  }

  // MARK: Model helpers

  var space: Space {
    get { spaces[current] }
    set { spaces[current] = newValue }
  }

  func find(_ id: String) -> Tab? {
    (favorites + spaces.flatMap { $0.pinned + $0.folders.flatMap(\.tabs) + $0.today }).first { $0.id == id }
  }

  func update(_ id: String, _ f: (inout Tab) -> Void) {
    if let i = favorites.firstIndex(where: { $0.id == id }) { f(&favorites[i]); return }
    for s in spaces.indices {
      if let i = spaces[s].pinned.firstIndex(where: { $0.id == id }) { f(&spaces[s].pinned[i]); return }
      if let i = spaces[s].today.firstIndex(where: { $0.id == id }) { f(&spaces[s].today[i]); return }
      for fo in spaces[s].folders.indices {
        if let i = spaces[s].folders[fo].tabs.firstIndex(where: { $0.id == id }) { f(&spaces[s].folders[fo].tabs[i]); return }
      }
    }
  }

  func spaceIndex(of id: String) -> Int? {
    spaces.firstIndex { s in (s.pinned + s.folders.flatMap(\.tabs) + s.today).contains { $0.id == id } }
  }

  static func host(_ url: String) -> String {
    guard let h = URL(string: url)?.host else { return url }
    return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
  }

  func drift(_ t: Tab) -> Bool {
    guard let p = t.pinnedURL else { return false }
    return Self.host(p) != Self.host(t.url) || (URL(string: t.url)?.path.count ?? 0) > (URL(string: p)?.path.count ?? 0) + 1
  }

  // MARK: Rendering (Value trees -> ui slots)

  func row(_ t: Tab, selected: String) -> Value {
    [
      "type": "tabRow", "id": .string(t.id), "title": .string(t.title), "icon": .string(t.icon), "selected": .bool(t.id == selected),
      "audio": .bool(t.audio), "drift": .bool(drift(t)),
      "menu": [["id": "copy", "title": "Copy Link", "icon": "sf:link"], ["separator": true], ["id": "close", "title": "Close Tab", "icon": "sf:xmark"]],
    ]
  }

  func renderSpace(_ i: Int) {
    let s = spaces[i]
    rt.call("ui", "set", ["slot": "sidebar.spaceHeader", "page": .int(Int64(i)), "tree": ["type": "spaceTitle", "id": .string("space-\(i)"), "title": .string(s.name), "icon": .string(s.icon)]])
    var pinned: [Value] = s.pinned.map { row($0, selected: s.selected) }
    for f in s.folders {
      pinned.append(["type": "folder", "id": .string(f.id), "title": .string(f.title), "open": .bool(f.open), "children": .array(f.tabs.map { row($0, selected: s.selected) })])
    }
    rt.call("ui", "set", ["slot": "sidebar.pinned", "page": .int(Int64(i)), "tree": ["type": "list", "id": "pinned", "children": .array(pinned)]])
    var today: [Value] = [["type": "divider", "id": "div", "action": "Clear"], ["type": "newTabRow", "id": "newtab"]]
    today += s.today.map { row($0, selected: s.selected) }
    rt.call("ui", "set", ["slot": "sidebar.today", "page": .int(Int64(i)), "tree": ["type": "list", "id": "today", "children": .array(today)]])
  }

  func renderGlobal() {
    let sel = space.selected
    let t = find(sel)
    let st = rt.call("webviews", "get", ["id": .string(sel)])
    rt.call("ui", "set", ["slot": "sidebar.header", "tree": ["type": "list", "spacing": 0, "children": [
      ["type": "navBar", "id": "nav", "canGoBack": st["canGoBack"], "canGoForward": st["canGoForward"], "loading": st["loading"]],
      ["type": "urlPill", "id": "url", "text": .string(t.map { Self.host($0.url) } ?? ""), "secure": .bool(t?.url.hasPrefix("https") ?? false),
       "loading": st["loading"], "progress": st["progress"]],
    ]]])
    rt.call("ui", "set", ["slot": "sidebar.favorites", "tree": ["type": "grid", "id": "favs", "children": .array(favorites.map {
      ["type": "favoriteTile", "id": .string($0.id), "icon": .string($0.icon), "title": .string($0.title), "selected": .bool($0.id == sel), "audio": .bool($0.audio)]
    })]])
    var footer: [Value] = [["type": "button", "id": "library", "icon": "sf:tray.full", "tooltip": "Library"], ["type": "spacer"]]
    for (i, s) in spaces.enumerated() {
      footer.append(["type": "spaceIcon", "id": .string("space-\(i)"), "icon": .string(s.icon), "title": .string(s.name), "selected": .bool(i == current)])
    }
    footer += [["type": "spacer"], ["type": "button", "id": "newSpace", "icon": "sf:plus", "tooltip": "New Space"]]
    rt.call("ui", "set", ["slot": "sidebar.footer", "tree": ["type": "row", "id": "footer", "height": 32, "spacing": 2, "children": .array(footer)]])
  }

  func showSelected() {
    if let split {
      rt.call("content", "show", ["panes": .array(split.map { .string($0) }), "orientation": "horizontal"])
    } else {
      rt.call("content", "show", ["panes": [.string(space.selected)]])
    }
    renderGlobal()
  }

  func select(_ id: String) {
    if let si = spaceIndex(of: id), si != current { switchSpace(si, animated: true) }
    space.selected = id
    split = nil
    renderSpace(current)
    showSelected()
  }

  func switchSpace(_ i: Int, animated: Bool) {
    guard i >= 0, i < spaces.count else { return }
    current = i
    rt.call("ui", "showPage", ["page": .int(Int64(i)), "animated": .bool(animated)])
    split = nil
    showSelected()
  }

  func newTab(_ url: String, title: String) {
    let id = "t\(nextTab)"
    nextTab += 1
    rt.call("webviews", "create", ["id": .string(id), "url": .string(url)])
    space.today.insert(Tab(id: id, title: title, url: url, icon: Self.fav(Self.host(url))), at: 0)
    select(id)
  }

  func close(_ id: String) {
    var s = space
    s.today.removeAll { $0.id == id }
    for f in s.folders.indices { s.folders[f].tabs.removeAll { $0.id == id } }
    space = s
    if favorites.contains(where: { $0.id == id }) || s.pinned.contains(where: { $0.id == id }) {
      rt.call("webviews", "suspend", ["id": .string(id)])  // pinned tabs are not closed, just unloaded
    } else {
      rt.call("webviews", "close", ["id": .string(id)])
    }
    if space.selected == id { space.selected = space.today.first?.id ?? space.pinned.first?.id ?? "" }
    renderSpace(current)
    showSelected()
  }

  // MARK: Command bar

  func openCommandBar(prefill: String = "") {
    commandOpen = true
    query = prefill
    renderCommandBar(replace: true)
  }

  func closeCommandBar() {
    commandOpen = false
    rt.call("ui", "set", ["slot": "overlay.commandBar", "tree": nil])
  }

  func commandRows() -> [(String, [Value])] {
    let q = query.lowercased()
    let all = favorites + spaces.flatMap { $0.pinned + $0.folders.flatMap(\.tabs) + $0.today }
    let tabs = all.filter { q.isEmpty || $0.title.lowercased().contains(q) || $0.url.lowercased().contains(q) }.prefix(q.isEmpty ? 4 : 5)
    var sections: [(String, [Value])] = []
    if !q.isEmpty {
      let isURL = WebViewsService.normalize(query) != nil && !query.contains(" ")
      sections.append(("", [[
        "id": "go", "icon": .string(isURL ? "sf:globe" : "sf:magnifyingglass"), "title": .string(query),
        "subtitle": .string(isURL ? "— Open URL" : "— Search Google"), "accessory": "↩",
      ]]))
    }
    sections.append(("Tabs", tabs.map { ["id": .string("tab:" + $0.id), "icon": .string($0.icon), "title": .string($0.title), "subtitle": .string(Self.host($0.url)), "accessory": "Switch to Tab"] }))
    let actions: [(String, String, String)] = [("act:split", "sf:rectangle.split.2x1", "Add Split View"), ("act:sidebar", "sf:sidebar.left", "Toggle Sidebar"),
                                                ("act:copy", "sf:link", "Copy URL"), ("act:theme", "sf:paintpalette", "Toggle Dark Mode")]
    let acts = actions.filter { q.isEmpty || $0.2.lowercased().contains(q) }
    if !acts.isEmpty { sections.append(("Actions", acts.map { ["id": .string($0.0), "icon": .string($0.1), "title": .string($0.2), "accessory": "Action"] })) }
    return sections
  }

  func renderCommandBar(replace: Bool = false) {
    let secs = commandRows()
    let ids = secs.flatMap { $0.1.map { $0.str("id") } }
    if !ids.contains(commandSelected) { commandSelected = ids.first ?? "" }
    rt.call("ui", "set", ["slot": "overlay.commandBar", "tree": [
      "type": "commandBar", "id": "cmdbar", "query": .string(query), "replaceQuery": .bool(replace), "selected": .string(commandSelected),
      "sections": .array(secs.map { ["title": .string($0.0), "rows": .array($0.1)] }),
    ]])
  }

  func runCommand(_ row: String) {
    closeCommandBar()
    if row == "go" {
      if let u = WebViewsService.normalize(query), !query.contains(" ") { newTab(u.absoluteString, title: Self.host(u.absoluteString)) } else {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        newTab("https://www.google.com/search?q=\(q)", title: query)
      }
    } else if row.hasPrefix("tab:") {
      select(String(row.dropFirst(4)))
    } else if row == "act:split" {
      addSplit()
    } else if row == "act:sidebar" {
      rt.call("window", "toggleSidebar")
    } else if row == "act:copy" {
      copyURL()
    } else if row == "act:theme" {
      appearance = appearance == "dark" ? "light" : "dark"
      for (i, s) in spaces.enumerated() {
        rt.call("window", "setTheme", ["colors": .array(s.colors.map { .string($0) }), "intensity": 0.6, "grain": 0.3, "appearance": .string(appearance), "page": .int(Int64(i))])
      }
    }
  }

  func addSplit() {
    let others = space.today.map(\.id).filter { $0 != space.selected }
    guard let second = others.first else { return }
    split = [space.selected, second]
    showSelected()
  }

  func copyURL() {
    guard let t = find(space.selected) else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(t.url, forType: .string)
    rt.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": "Copied URL to clipboard", "icon": "sf:link"]])
  }

  // MARK: Events

  func bindKeys() {
    let binds: [(String, String, String, String)] = [
      ("cmd+t", "demo.commandBar", "New Tab…", "File"), ("cmd+l", "demo.editURL", "Open Location…", "File"),
      ("cmd+w", "demo.closeTab", "Close Tab", "File"), ("cmd+s", "demo.toggleSidebar", "Toggle Sidebar", "View"),
      ("cmd+shift+c", "demo.copyURL", "Copy URL", "Edit"), ("cmd+r", "demo.reload", "Reload Page", "View"),
      ("cmd+[", "demo.back", "Back", "View"), ("cmd+]", "demo.forward", "Forward", "View"),
      ("cmd+opt+left", "demo.prevSpace", "Previous Space", "Spaces"), ("cmd+opt+right", "demo.nextSpace", "Next Space", "Spaces"),
      ("ctrl+shift+=", "demo.split", "Add Split View", "View"),
    ]
    for (c, e, t, m) in binds { rt.call("keys", "bind", ["chord": .string(c), "event": .string(e), "title": .string(t), "menu": .string(m)]) }
    for i in 1...spaces.count {
      rt.call("keys", "bind", ["chord": .string("ctrl+\(i)"), "event": "demo.space", "title": .string("Space \(i)"), "menu": "Spaces", "payload": .int(Int64(i - 1))])
    }
  }

  func subscribe() {
    let h = rt.host
    h.on("demo.commandBar") { [weak self] _ in self.map { $0.commandOpen ? $0.closeCommandBar() : $0.openCommandBar() } }
    h.on("demo.editURL") { [weak self] _ in
      guard let self else { return }
      if self.commandOpen { self.closeCommandBar() } else { self.openCommandBar(prefill: self.find(self.space.selected)?.url ?? "") }
    }
    h.on("demo.closeTab") { [weak self] _ in
      guard let self else { return }
      if self.commandOpen { self.closeCommandBar() } else if let p = self.peeking { self.endPeek(p) } else { self.close(self.space.selected) }
    }
    h.on("demo.toggleSidebar") { [weak self] _ in self?.rt.call("window", "toggleSidebar") }
    h.on("demo.copyURL") { [weak self] _ in self?.copyURL() }
    h.on("demo.reload") { [weak self] _ in self.map { $0.rt.call("webviews", "reload", ["id": .string($0.space.selected)]) } }
    h.on("demo.back") { [weak self] _ in self.map { $0.rt.call("webviews", "back", ["id": .string($0.space.selected)]) } }
    h.on("demo.forward") { [weak self] _ in self.map { $0.rt.call("webviews", "forward", ["id": .string($0.space.selected)]) } }
    h.on("demo.prevSpace") { [weak self] _ in self.map { $0.switchSpace($0.current - 1, animated: true) } }
    h.on("demo.nextSpace") { [weak self] _ in self.map { $0.switchSpace($0.current + 1, animated: true) } }
    h.on("demo.space") { [weak self] v in self?.switchSpace(Int(v["payload"].int ?? 0), animated: true) }
    h.on("demo.split") { [weak self] _ in self?.addSplit() }
    h.on("demo.peek") { [weak self] v in self?.peek(v.str("url")) }
    h.on("content.peekAction") { [weak self] v in self?.peekAction(v.str("action"), v.str("webview")) }
    h.on("ui.action") { [weak self] v in self?.action(v.str("id"), v.str("action"), v["value"]) }
    for e in ["webviews.title", "webviews.url", "webviews.favicon", "webviews.progress", "webviews.state", "webviews.audio"] {
      h.on(e) { [weak self] v in self?.webEvent(e, v) }
    }
    h.on("webviews.newWindow") { [weak self] v in self?.newTab(v.str("url"), title: Self.host(v.str("url"))) }
    h.on("app.openURL") { [weak self] v in v.list("urls").compactMap(\.string).forEach { self?.newTab($0, title: Self.host($0)) } }
    rt.call("app", "interceptQuit", ["enabled": true])
    h.on("app.quitRequested") { [weak self] _ in self?.showQuitDialog() }
  }

  func showQuitDialog() {
    rt.call("ui", "set", ["slot": "dialog", "tree": [
      "type": "dialog", "id": "quit", "icon": "sf:power", "title": "Quit den?", "message": "Your spaces and pinned tabs are saved. Today tabs will be restored the next time you open den.",
      "buttons": [["id": "quit", "title": "Quit", "style": "default"], ["id": "cancel", "title": "Cancel", "style": "cancel"]],
      "checkbox": ["id": "dontAsk", "title": "Don't ask again", "checked": false],
    ]])
  }

  func peek(_ url: String) {
    let id = "peek\(nextTab)"
    nextTab += 1
    rt.call("webviews", "create", ["id": .string(id), "url": .string(url)])
    peeking = id
    rt.call("ui", "set", ["slot": "overlay.peek", "tree": ["type": "peek", "webview": .string(id), "title": .string(Self.host(url))]])
  }

  func endPeek(_ id: String) {
    peeking = nil
    rt.call("ui", "set", ["slot": "overlay.peek", "tree": nil])
    rt.call("webviews", "close", ["id": .string(id)])
  }

  func peekAction(_ action: String, _ id: String) {
    let url = rt.call("webviews", "get", ["id": .string(id)]).str("url")
    endPeek(id)
    if action == "expand" { newTab(url, title: Self.host(url)) }
    if action == "split" {
      let sel = space.selected
      newTab(url, title: Self.host(url))
      split = [sel, space.selected]
      showSelected()
    }
  }

  func action(_ id: String, _ action: String, _ value: Value) {
    switch (id, action) {
    case ("cmdbar", "input"):
      query = value.str("text")
      renderCommandBar()
    case ("cmdbar", "select"): commandSelected = value.str("row")
    case ("cmdbar", "submit"):
      query = value.str("query")
      runCommand(value.str("row"))
    case ("cmdbar", "dismiss"), ("commandBar", "dismiss"): closeCommandBar()
    case ("quit", "button"):
      rt.call("ui", "set", ["slot": "dialog", "tree": nil])
      rt.call("app", "quit", ["confirm": .bool(value.str("button") == "quit")])
    case ("sidebar", "page"):
      current = Int(value.int ?? 0)
      split = nil
      showSelected()
    case ("sidebar", "doubleClick"), ("newtab", "click"): openCommandBar()
    case ("nav", "toggleSidebar"): rt.call("window", "toggleSidebar")
    case ("nav", "back"): rt.call("webviews", "back", ["id": .string(space.selected)])
    case ("nav", "forward"): rt.call("webviews", "forward", ["id": .string(space.selected)])
    case ("nav", "reload"): rt.call("webviews", "reload", ["id": .string(space.selected)])
    case ("nav", "stop"): rt.call("webviews", "stop", ["id": .string(space.selected)])
    case ("url", "click"): openCommandBar(prefill: find(space.selected)?.url ?? "")
    case ("url", "copy"): copyURL()
    case ("div", "clear"):
      for t in space.today { rt.call("webviews", "close", ["id": .string(t.id)]) }
      space.today = []
      if find(space.selected) == nil { space.selected = space.pinned.first?.id ?? "" }
      renderSpace(current)
      showSelected()
    case (_, "toggle"):
      if let i = space.folders.firstIndex(where: { $0.id == id }) { space.folders[i].open.toggle(); renderSpace(current) }
    case (_, "click") where id.hasPrefix("space-"):
      switchSpace(Int(id.dropFirst(6)) ?? 0, animated: true)
    case (_, "click"), (_, "menu") where value.string == "open":
      if find(id) != nil { select(id) }
    case (_, "close"): close(id)
    case (_, "menu"):
      if value.string == "close" { close(id) }
      if value.string == "copy", let t = find(id) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t.url, forType: .string)
        rt.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": "Copied link", "icon": "sf:link"]])
      }
    case (_, "reset"):
      if let t = find(id), let p = t.pinnedURL { rt.call("webviews", "navigate", ["id": .string(id), "url": .string(p)]) }
    case (_, "reorder"): reorder(value.str("source"), value.str("target"), value.str("position"))
    case (_, "dropOnContent"):
      let src = value.str("source")
      if src != space.selected, find(src) != nil { split = value.str("side") == "left" ? [src, space.selected] : [space.selected, src]; showSelected() }
    default: break
    }
  }

  func reorder(_ src: String, _ dst: String, _ pos: String) {
    guard let t = find(src), src != dst else { return }
    if favorites.contains(where: { $0.id == src }) {
      favorites.removeAll { $0.id == src }
      let i = favorites.firstIndex { $0.id == dst } ?? favorites.count
      favorites.insert(t, at: min(pos == "after" ? i + 1 : i, favorites.count))
      renderGlobal()
      return
    }
    var s = space
    s.pinned.removeAll { $0.id == src }
    s.today.removeAll { $0.id == src }
    for f in s.folders.indices { s.folders[f].tabs.removeAll { $0.id == src } }
    if pos == "into", let fi = s.folders.firstIndex(where: { $0.id == dst }) {
      s.folders[fi].tabs.append(t)
    } else if let i = s.pinned.firstIndex(where: { $0.id == dst }) {
      s.pinned.insert(t, at: pos == "after" ? i + 1 : i)
    } else if let i = s.today.firstIndex(where: { $0.id == dst }) {
      s.today.insert(t, at: pos == "after" ? i + 1 : i)
    } else if let fi = s.folders.firstIndex(where: { $0.tabs.contains { $0.id == dst } }), let i = s.folders[fi].tabs.firstIndex(where: { $0.id == dst }) {
      s.folders[fi].tabs.insert(t, at: pos == "after" ? i + 1 : i)
    } else if s.folders.contains(where: { $0.id == dst }) {
      s.pinned.append(t)
    } else {
      s.today.append(t)
    }
    space = s
    renderSpace(current)
  }

  func webEvent(_ e: String, _ v: Value) {
    let id = v.str("id")
    switch e {
    case "webviews.title": update(id) { $0.title = v.str("title") }
    case "webviews.url": update(id) { $0.url = v.str("url") }
    case "webviews.favicon": update(id) { $0.icon = v.str("url") }
    case "webviews.audio": update(id) { $0.audio = v.flag("playing") }
    default: break
    }
    if e != "webviews.progress" && e != "webviews.state", let si = spaceIndex(of: id) { renderSpace(si) }
    if id == space.selected || favorites.contains(where: { $0.id == id }) { renderGlobal() }
  }
}
