// The command bar as a launcher (Arc / Raycast): den's commands, destinations, settings panes and
// individual settings are searchable next to tabs and the web. Toggles flip on Enter; Tab or →
// drills into a setting's options or a pane's settings inside the bar. See
// docs/plugin-services.md (`commands`, "Launcher") and the proposed `settings` service.

#if !hasFeature(Embedded)
  import CordisValue
#endif

extension CommandBarCore {
  // MARK: - Settings source

  /// A setting den reaches through its own plugin's `settings` method. Used only while no
  /// `settings` service is loaded; once it is, its registry is the one source.
  struct PluginSetting {
    var service: String
    var field: String
    var title: String
    var pane: String
    var icon: String
    var type: String  // toggle | choice
    var options: [(Value, String)]
    var keywords: [String]
  }

  static let pluginSettings: [PluginSetting] = [
    PluginSetting(service: "peek", field: "peekLinks", title: "Open a Peek window when clicking on links to other sites", pane: "Links",
                  icon: "sf:macwindow.on.rectangle", type: "toggle", options: [], keywords: ["peek", "preview", "pinned"]),
    PluginSetting(service: "peek", field: "littleArc", title: "Links from other apps open in Little Arc", pane: "Links",
                  icon: "sf:macwindow", type: "toggle", options: [], keywords: ["little arc", "external", "default browser"]),
    PluginSetting(service: "tabs", field: "archiveAfterMs", title: "Archive today tabs after", pane: "Tabs", icon: "sf:archivebox",
                  type: "choice", options: [(.int(43_200_000), "12 hours"), (.int(86_400_000), "24 hours"), (.int(604_800_000), "7 days"),
                                            (.int(2_592_000_000), "30 days"), (.int(0), "Never")], keywords: ["auto archive", "close", "clean up"]),
    PluginSetting(service: "tabs", field: "suspendAfterMs", title: "Unload inactive tabs after", pane: "Tabs", icon: "sf:moon.zzz",
                  type: "choice", options: [(.int(300_000), "5 minutes"), (.int(900_000), "15 minutes"), (.int(1_800_000), "30 minutes"), (.int(3_600_000), "1 hour"), (.int(0), "Never")],
                  keywords: ["memory", "sleep", "suspend", "discard"]),
    PluginSetting(service: "tabs", field: "batterySaver", title: "Battery saver", pane: "Tabs", icon: "sf:battery.75percent",
                  type: "toggle", options: [], keywords: ["energy", "low power", "battery", "autoplay", "power"]),
    // Arc: "Enable Picture in Picture when you leave a video tab" (host `media` service).
    PluginSetting(service: "media", field: "autoPip", title: "Picture in Picture when you leave a playing video", pane: "Tabs", icon: "sf:pip",
                  type: "toggle", options: [], keywords: ["picture in picture", "pip", "video", "mini player", "youtube", "automatic"]),

    PluginSetting(service: "briefing", field: "enabled", title: "Morning briefing", pane: "Briefing", icon: "sf:sun.max", type: "toggle",
                  options: [], keywords: ["daily", "schedule", "summary"]),
  ]

  static let onOff: [(Value, String)] = [(.bool(true), "On"), (.bool(false), "Off")]

  // MARK: - Index

  /// Builds the index once per open (and after commands or settings change): commands and
  /// destinations, then settings panes and settings.
  func ensureIndex() {
    if isOpen && indexValid { return }
    var out: [IndexEntry] = []
    for c in commands() {
      let e = IndexEntry(kind: .command, id: c.id, title: c.title, icon: c.icon, section: "den", aliases: c.aliases, keywords: c.keywords)
      e.shortcut = c.shortcut
      out.append(e)
    }
    out += settingsEntries()
    // Frecency is read once here (it only changes when a row is picked, which closes the bar).
    for e in out { e.usage = usageScore(e.usageKey) }
    index = out
    indexValid = isOpen
  }

  /// The `settings` service's registry (`settings.list`), or den's plugin settings without it.
  func settingsEntries() -> [IndexEntry] {
    var out: [IndexEntry] = []
    if available("settings") {
      for p in env.call("settings", "list").array ?? [] {
        let pid = p.s("id"), ptitle = p.s("title")
        guard !pid.isEmpty, !ptitle.isEmpty else { continue }
        let picon = p.sOpt("icon") ?? "sf:gearshape"
        let pe = IndexEntry(kind: .pane, id: pid, title: ptitle, icon: picon, section: "Settings",
                            keywords: p.a("keywords").compactMap { $0.string } + ["settings"])
        pe.subtitle = "— Settings"
        out.append(pe)
        for s in p.a("schema") {
          let key = s.s("key")
          guard !key.isEmpty, !s.s("title").isEmpty else { continue }
          let e = IndexEntry(kind: .setting, id: key, title: s.s("title"), icon: s.sOpt("icon") ?? picon, section: "Settings",
                             keywords: s.a("keywords").compactMap { $0.string }, path: ptitle)
          e.subtitle = "— Settings › " + ptitle
          e.pane = pid
          e.type = s.s("type")
          e.value = s["value"]
          e.options = e.type == "toggle" ? Self.onOff : s.a("options").map { ($0["value"], $0.s("title")) }
          out.append(e)
        }
      }
      return out
    }
    var panes: [String] = []
    var current: [(String, Value)] = []  // service → its settings
    for d in Self.pluginSettings where available(d.service) {
      let pid = Text.lower(d.pane)
      if !panes.contains(pid) {
        panes.append(pid)
        let pe = IndexEntry(kind: .pane, id: pid, title: d.pane, icon: "sf:gearshape", section: "Settings", keywords: ["settings"])
        pe.subtitle = "— Settings"
        out.append(pe)
      }
      var v: Value = .null
      if let c = current.first(where: { $0.0 == d.service }) { v = c.1 } else {
        v = env.call(d.service, "settings")
        current.append((d.service, v))
      }
      let e = IndexEntry(kind: .setting, id: d.service + "." + d.field, title: d.title, icon: d.icon, section: "Settings", keywords: d.keywords, path: d.pane)
      e.subtitle = "— Settings › " + d.pane
      e.pane = pid
      e.type = d.type
      e.value = v[d.field]
      e.options = d.type == "toggle" ? Self.onOff : d.options
      e.plugin = d.service
      e.field = d.field
      out.append(e)
    }
    return out
  }

  func entry(_ kind: IndexEntry.Kind, _ id: String) -> IndexEntry? {
    for e in index where e.kind == kind && e.id == id { return e }
    return nil
  }

  func settingTitle(_ key: String) -> String { entry(.setting, key)?.title ?? "Options" }
  func paneTitle(_ id: String) -> String { entry(.pane, id)?.title ?? "Settings" }

  // MARK: - Matching

  /// Index positions matching `q` with (strength, score), best score first; ties keep index order.
  /// `settings`: nil = everything, true = panes and settings, false = commands.
  func launcherMatches(_ q: String, limit: Int, settings: Bool? = nil) -> [(Int, Int, Int)] {
    ensureIndex()
    let wq = Matcher.words(q)
    // The best `limit`, kept sorted by insertion: no sort of every match, no per-match allocation.
    var out: [(Int, Int, Int)] = []
    out.reserveCapacity(limit + 1)
    var i = 0
    for e in index {
      defer { i += 1 }
      if let settings, (e.kind != .command) != settings { continue }
      guard let m = Matcher.score(wq, e) else { continue }
      let s = m + e.usage
      if out.count == limit, let last = out.last, last.2 >= s { continue }
      var j = out.count
      while j > 0 && out[j - 1].2 < s { j -= 1 }
      out.insert((i, m, s), at: j)
      if out.count > limit { out.removeLast() }
    }
    return out
  }

  func launcherRows(_ q: String, settings: Bool, limit: Int) -> [Row] {
    launcherMatches(q, limit: limit, settings: settings).map { entryRow(index[$0.0], strength: $0.1, score: $0.2) }
  }

  /// The row that goes above "Search Google": the better of the best command and best setting,
  /// when its title or an alias starts with a query of two or more characters.
  func topHit(_ q: String, _ a: Row?, _ b: Row?) -> Row? {
    guard q.utf8.count >= 2, Self.url(from: q) == nil, !Self.pathLike(q) else { return nil }
    var best: Row?
    for r in [a, b] {
      guard let r, r.strength >= Self.topHitMatch else { continue }
      if best == nil || r.score > best!.score { best = r }
    }
    return best
  }

  func entryRow(_ e: IndexEntry, strength: Int, score: Int) -> Row {
    var r = Row(id: e.rowId, icon: e.icon, title: e.title, subtitle: e.subtitle, act: .command(e.id), key: e.usageKey, score: score, strength: strength)
    switch e.kind {
    case .command:
      r.shortcut = e.shortcut
    case .pane:
      r.act = .pane(e.id)
      r.drill = true
      r.keycap = "→"
    case .setting:
      r.act = .setting(e.id)
      r.drill = !e.options.isEmpty
      if e.type == "toggle" {
        r.toggle = e.value.bool ?? false
      } else if e.type == "choice" {
        r.accessory = e.currentOption
        r.keycap = "→"
      }
    }
    return r
  }

  // MARK: - Settings actions

  /// A choice drills into its options instead of closing the bar.
  func pickSettingInBar(_ key: String) -> Bool {
    guard let e = entry(.setting, key), e.type == "choice" else { return false }
    drill(options: key)
    return true
  }

  /// Enter on a setting: a toggle flips (with a toast); anything else opens its pane.
  func pickSetting(_ key: String) {
    guard let e = entry(.setting, key) else { return }
    bump(e.usageKey, title: "", url: "")
    env.emit("commands.settingPicked", ["key": .string(key)])
    if e.type == "toggle" {
      let on = !(e.value.bool ?? false)
      if setSetting(e, .bool(on)) { toast(e.title + (on ? ": On" : ": Off"), e.icon) }
    } else if e.plugin.isEmpty {
      env.call("settings", "open", ["id": .string(e.pane), "key": .string(key)])
    }
  }

  func pickOption(_ key: String, _ i: Int) {
    guard let e = entry(.setting, key), i < e.options.count else { return }
    bump(e.usageKey, title: "", url: "")
    env.emit("commands.settingPicked", ["key": .string(key)])
    if setSetting(e, e.options[i].0) { toast(e.title + ": " + e.options[i].1, e.icon) }
  }

  /// Writes a setting through the `settings` service, or through its plugin's own `settings`.
  func setSetting(_ e: IndexEntry, _ value: Value) -> Bool {
    let r: Value
    if !e.plugin.isEmpty {
      var a: Value = .null
      a.put(e.field, value)
      r = env.call(e.plugin, "settings", a)
    } else {
      r = env.call("settings", "set", ["key": .string(e.id), "value": value])
    }
    indexValid = false
    if let i = index.firstIndex(where: { $0.kind == .setting && $0.id == e.id }), !r.isErr { index[i].value = value }
    return !r.isErr
  }

  // MARK: - Drilling in

  /// Tab / → on the selected row: a setting's options or a pane's settings.
  func drillSelected() -> Bool {
    guard let r = rows.first(where: { $0.id == selected }), r.drill else { return false }
    switch r.act {
    case let .setting(key): drill(options: key)
    case let .pane(id): drill(pane: id)
    default: return false
    }
    return true
  }

  func drill(options key: String) {
    guard let e = entry(.setting, key) else { return }
    backStack.append((scope, query))
    scope = .options(key)
    query = ""
    selected = "opt:" + String(e.options.firstIndex { $0.0 == e.value } ?? 0)
    env.call("ui", "set", ["slot": .string(Self.slot), "tree": .null])  // a fresh field for the new scope
    render(replace: true)
  }

  func drill(pane id: String) {
    backStack.append((scope, query))
    setScope(.pane(id), query: "", reopen: true)
  }

  /// Backspace in an empty field: back to where the drill started.
  func back() {
    guard let (s, q) = backStack.popLast() else { return }
    setScope(s, query: q, reopen: true)
  }

  func optionRows(_ key: String, _ q: String) -> [Row] {
    guard let e = entry(.setting, key) else { return [] }
    let wq = Matcher.words(q)
    var out: [Row] = []
    for (i, o) in e.options.enumerated() {
      guard Matcher.score(wq, IndexEntry(kind: .setting, id: "", title: o.1, icon: "", section: "")) != nil else { continue }
      let cur = o.0 == e.value
      out.append(Row(id: "opt:" + String(i), icon: cur ? "sf:checkmark.circle.fill" : "sf:circle", title: o.1, subtitle: "— " + e.title,
                     accessory: cur ? "Current" : "", act: .option(key, i)))
    }
    return out
  }

  func paneRows(_ id: String, _ q: String) -> [Row] {
    ensureIndex()
    let wq = Matcher.words(q)
    var out: [Row] = []
    for e in index where e.kind == .setting && e.pane == id {
      guard let m = Matcher.score(wq, e) else { continue }
      out.append(entryRow(e, strength: m, score: m))
    }
    return out
  }

  // MARK: - Windows

  /// Little Arc windows, by their page's title and URL (read once per open).
  func windowRows(_ q: String) -> [Row] {
    if windowsCache == nil || !isOpen {
      var list: [Value] = []
      for w in env.call("window", "listMini").array ?? [] {
        let page = env.call("webviews", "get", ["id": w["webview"]])
        list.append(["id": w["id"], "title": page["title"], "url": page["url"], "favicon": page["favicon"]])
      }
      windowsCache = list
    }
    var out: [Row] = []
    for w in windowsCache ?? [] {
      let url = w.s("url")
      guard let m = Self.match(q, title: w.s("title"), url: url, keywords: ["little arc", "window"]) else { continue }
      out.append(Row(id: "win:" + w.s("id"), icon: w.sOpt("favicon") ?? URLs.favicon(url), title: w.s("title").isEmpty ? URLs.display(url) : w.s("title"),
                     subtitle: "— Little Arc · " + URLs.host(url), accessory: "Switch to Window", act: .window(w.s("id")), score: m, strength: m))
    }
    return Self.top(out, 3)
  }

  // MARK: - Keyboard shortcuts

  /// Every key binding (`keys.list`), with its chord as keycaps. Picking one runs it.
  func shortcutRows(_ q: String) -> [Row] {
    var out: [Row] = []
    for k in env.call("keys", "list").array ?? [] {
      let title = k.sOpt("title") ?? k.s("event")
      guard let m = Self.match(q, title: title, keywords: [k.s("menu"), k.s("chord")]) else { continue }
      var r = Row(id: "key:" + k.s("chord"), icon: "sf:command", title: title, subtitle: k.s("menu").isEmpty ? "" : "— " + k.s("menu"),
                  act: .shortcut(k.s("chord")), score: m, strength: m)
      r.shortcut = Self.chordGlyphs(k.s("chord"))
      out.append(r)
    }
    return Self.top(out, 100)
  }

  func runShortcut(_ chord: String) {
    for k in env.call("keys", "list").array ?? [] where k.s("chord") == chord {
      env.emit(k.s("event"), ["chord": .string(chord), "payload": k["payload"]])
      return
    }
  }

  /// "cmd+shift+k" → "⇧⌘K" (modifiers in the macOS menu order ⌃⌥⇧⌘).
  static func chordGlyphs(_ chord: String) -> String {
    var mods = ""
    var key = ""
    var parts: [String] = []
    var cur: [UInt8] = []
    for c in chord.utf8 {
      if c == 43 && !cur.isEmpty {  // "+" (a trailing "+" is the key itself)
        parts.append(String(decoding: cur, as: UTF8.self))
        cur = []
      } else {
        cur.append(c)
      }
    }
    parts.append(String(decoding: cur, as: UTF8.self))
    let order: [(String, String)] = [("ctrl", "⌃"), ("opt", "⌥"), ("alt", "⌥"), ("shift", "⇧"), ("cmd", "⌘")]
    for (name, glyph) in order where parts.dropLast().contains(name) { mods += glyph }
    let names: [(String, String)] = [("left", "←"), ("right", "→"), ("up", "↑"), ("down", "↓"), ("tab", "⇥"), ("return", "↩"), ("enter", "↩"),
                                     ("esc", "⎋"), ("escape", "⎋"), ("space", "Space"), ("delete", "⌫"), ("backspace", "⌫")]
    let last = parts.last ?? ""
    key = names.first { $0.0 == last }?.1 ?? upper(last)
    return mods + key
  }

  static func upper(_ s: String) -> String {
    var out: [UInt8] = []
    for c in s.utf8 { out.append(c >= 97 && c <= 122 ? c - 32 : c) }
    return String(decoding: out, as: UTF8.self)
  }

  // MARK: - About

  /// The standard About panel (its credits come from the `updates` plugin's `app.setAbout`).
  func showAbout() { env.call("app", "showAbout") }
}
