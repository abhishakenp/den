// Windows for the `tabs` plugin: every normal window shows the same spaces and tabs and keeps its
// own place (Arc: "Cmd-N opens another window on the same Spaces and tabs", research/arc.md §1);
// private windows (⇧⌘N) have tabs of their own that are never saved; closed windows can be
// reopened (⇧⌘T right after a window close, File ▸ Reopen Closed Window); open windows come back
// after a relaunch. The host's `window` service owns the windows; this file decides what they show.
//
// With one window nothing here runs: `places` is empty, renders carry no `window`, and the state
// has no `windows` key.

#if !hasFeature(Embedded)
  import CordisValue
#endif

extension TabsCore {
  // MARK: - Per-window rendering

  /// Runs a sidebar render once per normal window, each with that window's selection. With one
  /// normal window it runs once, addressed to no window in particular (every normal window).
  func eachWindow(_ body: () -> Void) {
    if places.isEmpty || renderWin != nil { body(); return }
    let saved = renderWin
    if !normalWin.isEmpty {
      renderWin = normalWin
      body()
    }
    for w in places.keys.sorted() {
      renderWin = w
      body()
    }
    renderWin = saved
  }

  /// `ui.set`, addressed to the window being rendered for (if any).
  func uiSet(_ args: Value) {
    var a = args
    if let w = renderWin { a.put("window", .string(w)) }
    env.call("ui", "set", a)
  }

  /// The tab highlighted in `sid`'s list in the window being rendered for.
  func selOf(_ sid: String) -> String? {
    if let w = renderWin, w != normalWin, let p = places[w] { return p.space == sid ? p.tab : selected[sid] }
    return blankWin && sid == currentSpace ? nil : selected[sid]
  }

  /// The tab the window being rendered for shows (its header and favorites).
  var shownTabForRender: String? {
    if let w = renderWin, w != normalWin, let p = places[w] { return p.tab }
    return selectedId
  }

  /// The window title of the normal window (addressed while a private window is in front).
  func setTitle(_ title: String) {
    var a: Value = ["title": .string(title)]
    if activeWin != normalWin, !normalWin.isEmpty { a.put("window", .string(normalWin)) }
    env.call("window", "setTitle", a)
  }

  /// The tab in front: the private window's own tab while one is active, else the normal selection.
  var frontTab: String? {
    if let w = activePrivate { return privates[w]?.selected }
    return selectedId
  }

  var activePrivate: String? { privates[activeWin] != nil ? activeWin : nil }

  // MARK: - Which window shows what

  /// Another normal window showing `id` (or its split), when a tab may show in one window only.
  func windowShowing(_ id: String) -> String? {
    guard !sameTabInWindows else { return nil }
    let s = splitOf(id)
    for w in places.keys.sorted() {
      guard let t = places[w]?.tab else { continue }
      if t == id || (s != nil && splitOf(t) == s) { return w }
    }
    return nil
  }

  func isShownElsewhere(_ id: String) -> Bool {
    for p in places.values where p.tab == id { return true }
    return false
  }

  /// `id` is closing: windows in the background that show it are left empty.
  func leaveOtherWindows(_ id: String) {
    let s = splitOf(id)
    for w in places.keys.sorted() {
      guard let t = places[w]?.tab, t == id || (s != nil && splitOf(t) == s) else { continue }
      places[w]?.tab = nil
      env.call("content", "show", ["window": .string(w), "panes": []])
      env.call("window", "setTitle", ["window": .string(w), "title": .string(spaceName(places[w]?.space ?? currentSpace))])
    }
  }

  /// Shows `tab` (or its split) in window `w`, which is in the background.
  func show(_ tab: String?, inWindow w: String) {
    var a: Value = ["window": .string(w), "panes": []]
    var title = spaceName(places[w]?.space ?? currentSpace)
    if let t = tab, tabs[t] != nil {
      if let s = splitOf(t), let sp = splits[s] {
        a = ["window": .string(w), "panes": .array(sp.children.map { .string($0) }), "orientation": .string(sp.layout), "focus": .string(t)]
      } else {
        a.put("panes", [.string(t)])
      }
      title = tabs[t]?.displayTitle ?? "den"
    }
    env.call("content", "show", a)
    env.call("window", "setTitle", ["window": .string(w), "title": .string(title)])
  }

  // MARK: - Window events

  func subscribeWindows() {
    env.on("window.opened") { [self] v in windowOpened(v) }
    env.on("window.activated") { [self] v in windowActivated(v) }
    env.on("window.closed") { [self] v in windowClosed(v) }
    env.on("window.reopen") { [self] _ in reopenWindow() }
  }

  func space(atPage v: Value) -> String {
    let p = Int(v.i("page"))
    return p >= 0 && p < spaceIds.count ? spaceIds[p] : currentSpace
  }

  /// A new window. ⌘N: the space of the window in front, nothing shown yet, and the command bar
  /// asks what to open (Arc). A reopened or restored window takes its old place. A private window
  /// starts empty with the command bar too.
  func windowOpened(_ v: Value) {
    let id = v.s("id")
    if v.b("private") {
      privates[id] = PrivateWindow()
      renderPrivate(id)
      if v.b("focus") { commandBarFor = id }
      return
    }
    if let r = reopening {
      let sid = pageIndex(r.s("spaceId")) != nil ? r.s("spaceId") : currentSpace
      let tab = r.sOpt("tab").flatMap { tabs[$0] != nil ? $0 : nil }
      places[id] = Place(space: sid, tab: tab)
      show(tab, inWindow: id)
    } else {
      places[id] = Place(space: space(atPage: v), tab: nil)
      show(nil, inWindow: id)
      if v.b("focus") { commandBarFor = id }
    }
    renderAll()
    saveSoon()
  }

  /// The window in front changed. A normal window brings its place with it: its space becomes
  /// the current one and its tab the selected one (the window already shows it: nothing reloads).
  func windowActivated(_ v: Value) {
    let id = v.s("id")
    guard id != activeWin else { return }
    if privates[id] != nil || id == normalWin {
      activeWin = id
      // The normal window in use closed and a private one came forward: another normal window
      // takes over the current space and selection.
      if normalWin.isEmpty, let next = places.keys.sorted().first, let p = places.removeValue(forKey: next) {
        adoptPlace(next, space: p.space, tab: p.tab)
        renderAll()
      }
      openPendingCommandBar(id)
      return
    }
    if !normalWin.isEmpty { places[normalWin] = Place(space: currentSpace, tab: selectedId) }
    let p = places.removeValue(forKey: id) ?? Place(space: space(atPage: v), tab: nil)
    // What the window really shows wins over what was recorded.
    var tab = p.tab
    if let f = v["focus"].string, tabs[f] != nil { tab = f }
    if let t = tab, tabs[t] == nil { tab = nil }
    adoptPlace(id, space: p.space, tab: tab)
    activeWin = id
    renderAll()
    saveSoon()
    openPendingCommandBar(id)
  }

  /// Makes `id` the normal window `currentSpace` and `selected` describe.
  func adoptPlace(_ id: String, space: String, tab: String?) {
    normalWin = id
    let sid = tab.flatMap { spaceOf($0) } ?? (pageIndex(space) != nil ? space : currentSpace)
    if sid != currentSpace {
      activating = true
      env.call("spaces", "switch", ["id": .string(sid), "animated": false])
      activating = false
      currentSpace = sid
    }
    blankWin = tab == nil
    if let t = tab { selected[sid] = t }
    shown = tab ?? ""
  }

  func openPendingCommandBar(_ id: String) {
    guard commandBarFor == id else { return }
    commandBarFor = nil
    openCommandBar("new")
  }

  /// A window closed. A private window's tabs close with it and nothing of it is kept; a normal
  /// window is remembered (newest first) so it can be reopened.
  func windowClosed(_ v: Value) {
    let id = v.s("id")
    if let pw = privates.removeValue(forKey: id) {
      for t in pw.tabs {
        ptabs[t] = nil
        env.call("webviews", "close", ["id": .string(t)])
      }
      if activeWin == id { activeWin = "" }
      if commandBarFor == id { commandBarFor = nil }
      return
    }
    var entry: Value = ["id": .string(id), "closedAt": .int(env.now())]
    if id == normalWin {
      entry.put("spaceId", .string(currentSpace))
      entry.put("tab", .str(selectedId))
      // The window that comes forward next takes over (windowActivated).
      normalWin = ""
    } else if let p = places.removeValue(forKey: id) {
      entry.put("spaceId", .string(p.space))
      entry.put("tab", .str(p.tab))
    } else {
      return
    }
    closedWindows.insert(entry, at: 0)
    if closedWindows.count > 10 { closedWindows.removeLast() }
    lastClosedWasWindow = true
    if activeWin == id { activeWin = "" }
    if commandBarFor == id { commandBarFor = nil }
    renderAll()
    saveSoon()
  }

  /// ⇧⌘T after a window close, or File ▸ Reopen Closed Window: the window comes back on its
  /// space with the tab (or split) it showed. Its tabs never left: every window shares them.
  func reopenWindow() {
    guard !closedWindows.isEmpty else { return }
    let e = closedWindows.removeFirst()
    lastClosedWasWindow = false
    let page = pageIndex(e.s("spaceId")) ?? pageIndex(currentSpace) ?? 0
    reopening = e
    env.call("window", "new", ["id": e["id"], "page": .int(Int64(page)), "focus": true])
    reopening = nil
  }

  // MARK: - Window restore

  /// The normal windows, the one in use first (window restore; `stateValue`).
  func windowsValue() -> Value {
    var out: [Value] = []
    if !normalWin.isEmpty { out.append(["id": .string(normalWin), "spaceId": .string(currentSpace), "tab": .str(selectedId)]) }
    for w in places.keys.sorted() {
      let p = places[w]!
      out.append(["id": .string(w), "spaceId": .string(p.space), "tab": .str(p.tab)])
    }
    return .array(out)
  }

  /// At launch: the first saved window is the one den opens with (the space and selection already
  /// came back); every other one opens again, in the background, where it was.
  func restoreWindows() {
    let saved = savedWindows
    savedWindows = []
    guard saved.count > 1 else { return }
    for w in saved.dropFirst() {
      guard pageIndex(w.s("spaceId")) != nil else { continue }
      reopening = w
      var args: Value = ["page": .int(Int64(pageIndex(w.s("spaceId")) ?? 0)), "focus": false, "restored": true]
      if w.s("id") != normalWin { args.put("id", w["id"]) }
      env.call("window", "new", args)
      reopening = nil
    }
  }

  // MARK: - Private windows

  func privateWindow(of tab: String) -> String? {
    for (w, p) in privates where p.tabs.contains(tab) { return w }
    return nil
  }

  /// A private tab: its own ephemeral data store per window (`private:<window>`), never in the
  /// state, the archive, the MRU or the undo stack.
  func openPrivate(_ url: String, in w: String, background: Bool, adopt: String? = nil, after: String? = nil) -> String {
    var id = adopt ?? ""
    if adopt == nil {
      for _ in 0..<1000 {
        id = "ptab-" + String(nextPrivate)
        nextPrivate += 1
        if !env.call("webviews", "create", ["id": .string(id), "url": .string(url), "profile": .string("private:" + w)]).isErr { break }
      }
    }
    ptabs[id] = Tab(id: id, title: URLs.title(url), url: url, lastActive: env.now())
    // At the top, or right after `after` (a pop-up's opener).
    let at = after.flatMap { a in privates[w]?.tabs.firstIndex(of: a).map { $0 + 1 } } ?? 0
    privates[w]?.tabs.insert(id, at: at)
    if background, privates[w]?.selected != nil { renderPrivate(w) } else { selectPrivate(id) }
    return id
  }

  func selectPrivate(_ id: String) {
    guard let w = privateWindow(of: id) else { return }
    privates[w]?.selected = id
    ptabs[id]?.lastActive = env.now()
    env.call("content", "show", ["window": .string(w), "panes": [.string(id)]])
    env.call("window", "setTitle", ["window": .string(w), "title": .string(ptabs[id]?.displayTitle ?? "Private")])
    renderPrivate(w)
    if activeWin != w { env.call("window", "focus", ["id": .string(w)]) }
  }

  /// ⌘W in a private window: the tab is gone for good (no archive, no reopen).
  func closePrivate(_ id: String) {
    guard let w = privateWindow(of: id), var pw = privates[w], let i = pw.tabs.firstIndex(of: id) else { return }
    pw.tabs.remove(at: i)
    let wasSelected = pw.selected == id
    if wasSelected { pw.selected = i < pw.tabs.count ? pw.tabs[i] : pw.tabs.last }
    privates[w] = pw
    ptabs[id] = nil
    if wasSelected, let n = pw.selected {
      selectPrivate(n)
    } else if wasSelected {
      env.call("content", "show", ["window": .string(w), "panes": []])
      env.call("window", "setTitle", ["window": .string(w), "title": "Private"])
      renderPrivate(w)
    } else {
      renderPrivate(w)
    }
    env.call("webviews", "close", ["id": .string(id)])
  }

  /// A private window's sidebar: its URL pill, "Private", its tabs and a note that nothing is kept.
  func renderPrivate(_ w: String) {
    guard let pw = privates[w] else { return }
    let saved = renderWin
    renderWin = w
    renderHeader(tab: pw.selected, url: { ptabs[$0]?.url })
    uiSet(["slot": "sidebar.spaceHeader", "page": 0, "tree": ["type": "text", "id": .string("tabs.private.title:" + w), "text": "Private window", "style": "title"]])
    var kids: [Value] = [["type": "newTabRow", "id": .string("tabs.private.new:" + w), "title": "New Private Tab"]]
    for id in pw.tabs {
      guard let t = ptabs[id] else { continue }
      kids.append(["type": "tabRow", "id": .string(id), "title": .string(t.displayTitle), "icon": .string(t.icon), "selected": .bool(pw.selected == id),
                   "audio": .bool(t.audio), "muted": .bool(t.muted), "closeTitle": "Close Tab",
                   "menu": [["id": "copy", "title": "Copy Link", "icon": "sf:link", "key": .string(Self.chord("tabs.key.copy"))],
                            ["separator": true],
                            ["id": "close", "title": "Close Tab", "icon": "sf:xmark", "key": .string(Self.chord("tabs.key.close"))]]])
    }
    uiSet(["slot": "sidebar.today", "page": 0, "tree": ["type": "list", "id": .string("tabs.private:" + w), "children": .array(kids)]])
    uiSet(["slot": "sidebar.footer", "tree": ["type": "row", "id": .string("tabs.private.footer:" + w), "height": 50, "spacing": 6, "children": [
      ["type": "spacer"], ["type": "text", "id": .string("tabs.private.note:" + w), "text": "Nothing here is saved", "style": "caption"], ["type": "spacer"],
    ]]])
    renderWin = saved
  }

  func privateWebEvent(_ e: String, _ v: Value) {
    let id = v.s("id")
    guard let w = privateWindow(of: id) else { return }
    switch e {
    case "webviews.title":
      ptabs[id]?.title = v.s("title")
      if privates[w]?.selected == id { env.call("window", "setTitle", ["window": .string(w), "title": .string(ptabs[id]?.displayTitle ?? "Private")]) }
    case "webviews.url": ptabs[id]?.url = v.s("url")
    case "webviews.favicon": if let u = v.sOpt("url") { ptabs[id]?.favicon = u }
    case "webviews.audio": ptabs[id]?.audio = v.b("playing")
    case "webviews.muted": ptabs[id]?.muted = v.b("muted")
    default:
      if privates[w]?.selected != id { return }
    }
    renderPrivate(w)
  }

  /// Sidebar actions in a private window. Returns true when handled.
  func privateAction(_ id: String, _ action: String, _ value: Value) -> Bool {
    if ptabs[id] != nil {
      switch action {
      case "click": selectPrivate(id)
      case "close": closePrivate(id)
      case "mute":
        if let t = ptabs[id] { env.call("webviews", "setMuted", ["id": .string(id), "muted": .bool(!t.muted)]) }
      case "menu":
        let item = value.string ?? ""
        if item == "close" { closePrivate(id) }
        if item == "copy", let t = ptabs[id] {
          env.call("app", "copy", ["text": .string(t.url)])
          env.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": .string(Copied.link(t.url)), "icon": "sf:link"]])
        }
      default: break
      }
      return true
    }
    if Text.hasPrefix(id, "tabs.private.new:") {
      if action == "click" { openCommandBar("new") }
      return true
    }
    return Text.hasPrefix(id, "tabs.private.")
  }
}
