// The `continuity` plugin: den in the rest of macOS. Open tabs and spaces in Spotlight, and the
// page in front offered to your other devices (Handoff). The host's `spotlight` and `handoff`
// services do the system calls; what goes there, and what a Spotlight pick does, is decided here.
// See docs/plugin-services.md#continuity-plugin-continuity.

#if !hasFeature(Embedded)
  import CordisValue
#endif

/// - **Spotlight.** Every tab in the sidebar (favorites, pinned, folders, splits, Today) and every
///   space, as items of den's Spotlight index: the tab's title and address, "Tab in <space>",
///   keywords the site and "den". A refresh runs 2 s after the tabs, a title or an address
///   change (one at a time), and the host sends only what changed. Picking one selects that tab
///   (switching space) or that space. Private tabs never show (`tabs.list` has none).
/// - **Handoff.** The selected tab's page (http or https) is offered to your other devices; a
///   private window's never is. A page handed to den arrives as a link from another app.
/// - **Settings ▸ General ▸ Continuity:** both on by default; turning Spotlight off removes every
///   den item at once.
final class ContinuityCore {
  static let ns = "continuity"
  static let refreshMs: UInt64 = 2000

  let env: PluginEnv
  var spotlightOn = true
  var handoffOn = true
  /// A Spotlight refresh is waiting on its timer.
  var pending = false
  /// The selected tab in the window in front, and whether that window is private.
  var selected: String?
  var privateFront = false
  /// The last refresh's items, by domain (tests and `state`).
  var lastTabs: [Value] = []
  var lastSpaces: [Value] = []

  init(env: PluginEnv) { self.env = env }

  func start() {
    registerSettings()
    env.on("tabs.selected") { [self] v in
      selected = v.sOpt("id")
      privateFront = v.b("private")
      handoff()
    }
    env.on("window.activated") { [self] v in
      privateFront = v.b("private")
      handoff()
    }
    env.on("tabs.changed") { [self] _ in schedule() }
    env.on("spaces.changed") { [self] _ in schedule() }
    env.on("webviews.url") { [self] v in changed(v.s("id")) }
    env.on("webviews.title") { [self] v in changed(v.s("id")) }
    env.on("spotlight.open") { [self] v in open(v.s("id")) }
    let sel = env.call("tabs", "selected")
    selected = sel.sOpt("id")
    privateFront = sel.b("private")
    handoff()
    schedule()
  }

  func stop() {
    // A turned-off plugin leaves nothing offered; Spotlight items expire on their own.
    env.call("handoff", "clear")
  }

  func changed(_ id: String) {
    if id == selected { handoff() }
    schedule()
  }

  // MARK: Settings

  func registerSettings() {
    let r = env.call("settings", "register", [
      "id": .string(Self.ns), "title": "Continuity", "section": "general", "order": 60,
      "controls": [
        ["key": "spotlight", "type": "toggle", "title": "Show tabs and spaces in Spotlight",
         "subtitle": "Spotlight finds your open tabs and spaces by title and address. Private windows never show.", "default": true],
        ["key": "handoff", "type": "toggle", "title": "Hand off pages to your other devices",
         "subtitle": "The page you're on shows up on your iPhone and iPad (Handoff in System Settings ▸ General ▸ AirDrop & Handoff). Never from a private window.", "default": true],
      ],
    ])
    guard !r.isErr else { return }
    let v = env.call("settings", "get", ["id": .string(Self.ns)])
    spotlightOn = v["spotlight"].bool ?? true
    handoffOn = v["handoff"].bool ?? true
    env.on("settings.changed") { [self] v in
      guard v.s("id") == Self.ns else { return }
      let on = v["value"].bool ?? true
      if v.s("key") == "spotlight" {
        spotlightOn = on
        if on { schedule() } else { env.call("spotlight", "remove") }
      } else if v.s("key") == "handoff" {
        handoffOn = on
        handoff()
      }
    }
  }

  // MARK: Handoff

  func handoff() {
    guard handoffOn, !privateFront, let id = selected else {
      env.call("handoff", "clear")
      return
    }
    let w = env.call("webviews", "get", ["id": .string(id)])
    let url = w.s("url")
    guard URLs.isWeb(url) else {
      env.call("handoff", "clear")
      return
    }
    env.call("handoff", "set", ["url": .string(url), "title": .string(w.s("title"))])
  }

  // MARK: Spotlight

  func schedule() {
    guard spotlightOn, !pending else { return }
    pending = true
    env.timer(Self.refreshMs, false) { [self] in
      pending = false
      refresh()
    }
  }

  /// Sends every tab and space to the host's index (it diffs against what it already has).
  func refresh() {
    guard spotlightOn else { return }
    let spaces = env.call("spaces", "list").array ?? []
    var tabs: [Value] = []
    var seen: [String] = []
    var spaceItems: [Value] = []
    for (i, sp) in spaces.enumerated() {
      let sid = sp.s("id"), name = sp.s("name")
      spaceItems.append(["id": .string(sid), "title": .string(name.isEmpty ? "Space" : name), "subtitle": "Space in den",
                         "keywords": ["space", "den"]])
      let l = env.call("tabs", "list", ["spaceId": .string(sid)])
      // Favorites are shared by every space: once, from the first.
      let sections: [(String, String)] = i == 0 ? [("favorites", "Favorite"), ("pinned", ""), ("today", "")] : [("pinned", ""), ("today", "")]
      for (section, label) in sections {
        var stack: [Value] = l.a(section).reversed()
        while let item = stack.popLast() {
          if item.b("folder") || item.b("split") {
            stack.append(contentsOf: item.a("children").reversed())
            continue
          }
          let id = item.s("id"), url = item.s("url")
          guard !id.isEmpty, URLs.isWeb(url), !seen.contains(id) else { continue }
          seen.append(id)
          let custom = item.s("customTitle"), title = item.s("title")
          let shown = !custom.isEmpty ? custom : (!title.isEmpty ? title : URLs.display(url))
          let host = URLs.host(url)
          tabs.append(["id": .string(id), "title": .string(shown), "url": .string(url),
                       "subtitle": .string(label.isEmpty ? "Tab in " + (name.isEmpty ? "den" : name) : label + " in den"),
                       "keywords": .array([.string(host), "den", "tab"])])
        }
      }
    }
    lastTabs = tabs
    lastSpaces = spaceItems
    env.call("spotlight", "index", ["domain": "tabs", "items": .array(tabs), "replace": true])
    env.call("spotlight", "index", ["domain": "spaces", "items": .array(spaceItems), "replace": true])
  }

  /// A pick in Spotlight: `tabs:<tab id>` or `spaces:<space id>`.
  func open(_ unique: String) {
    if Text.hasPrefix(unique, "tabs:") {
      let id = Text.dropPrefix(unique, "tabs:")
      if env.call("tabs", "select", ["id": .string(id)]).isErr { schedule() }
    } else if Text.hasPrefix(unique, "spaces:") {
      env.call("spaces", "switch", ["id": .string(Text.dropPrefix(unique, "spaces:"))])
    }
  }
}
