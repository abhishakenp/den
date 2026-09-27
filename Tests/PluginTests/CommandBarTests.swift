import AppKit
import CordisValue
import Testing

@testable import DenHost
@testable import PluginCores

extension Harness {
  /// Starts spaces, tabs and the command bar, like the real load order.
  @discardableResult
  func startCommandBar() -> CommandBarCore {
    if rt.plugins.serviceNames.contains("tabs") == false { startTabs() }
    let core = CommandBarCore(env: env)
    rt.plugins.provide("commands") { m, a in core.handle(m, a) }
    core.start()
    return core
  }

  var bar: Value { rt.ui.commandBarOpen ? rt.ui.commandBar.node : .null }
  var barRows: [Value] { bar.list("sections").flatMap { $0.list("rows") } }
  var barRowIds: [String] { barRows.map { $0.str("id") } }
  /// Types into the real text field, then sends what the host sends.
  func type(_ text: String) {
    rt.ui.commandBar.input.stringValue = text
    action("commandBar", "input", ["text": .string(text)])
  }
  func submit(_ row: String? = nil, shift: Bool = false) {
    action("commandBar", "submit", [
      "row": .string(row ?? bar.str("selected")), "query": .string(rt.ui.commandBar.input.stringValue),
      "modifiers": .array(shift ? ["shift"] : []),
    ])
  }
  func allTabIds() -> [String] { spaceIds.flatMap { ids("pinned", $0) + ids("today", $0) } + ids("favorites") }
}

@MainActor
@Suite(.serialized)
struct CommandBarTests {
  @Test func shortcutsOpenAndCloseTheBar() {
    let h = Harness()
    h.startCommandBar()
    let chords = Set((h.rt.call("keys", "list").array ?? []).map { $0.s("chord") })
    #expect(chords.contains("cmd+t") && chords.contains("cmd+l"))

    h.key("cmd+t")
    #expect(h.rt.ui.commandBarOpen)
    #expect(h.bar.str("query") == "")
    #expect(h.bar.str("placeholder") == "Search or Enter URL…")
    // Nothing typed: recent tabs.
    #expect(h.bar.list("sections").first?.str("title") == "Tabs")
    h.key("cmd+t")  // the same shortcut again closes it
    #expect(!h.rt.ui.commandBarOpen)

    // Cmd-L: pre-filled with the current URL, text selected; Enter reloads.
    let url = h.tabs("list")["today"][0].s("url")
    h.key("cmd+l")
    #expect(h.bar.str("query") == url)
    #expect(h.rt.ui.commandBar.input.stringValue == url)
    #expect(h.barRowIds.first == "reload")
    h.key("cmd+t")  // the other shortcut switches mode instead of closing
    #expect(h.rt.ui.commandBarOpen && h.bar.str("query") == "")
    h.key("cmd+l")
    h.key("cmd+l")
    #expect(!h.rt.ui.commandBarOpen)

    // Esc and a click outside both send dismiss.
    h.rt.call("commands", "open", ["mode": "new"])
    h.action("commandBar", "dismiss")
    #expect(!h.rt.ui.commandBarOpen)
    h.rt.call("commands", "open", ["mode": "new"])
    h.rt.ui.commandBackdrop.onClick?()
    #expect(!h.rt.ui.commandBarOpen)
  }

  @Test func oneInputSearchesTabsInEverySpaceAndSwitchesInsteadOfDuplicating() {
    let h = Harness()
    h.startCommandBar()
    let before = h.allTabIds().count
    h.key("cmd+t")
    h.type("swi")
    let rows = h.barRows
    // Web search is the first row, then tabs across spaces.
    #expect(rows.first?.str("id") == "search")
    #expect(rows.first?.str("title") == "swi")
    #expect(rows.first?.str("subtitle") == "— Search Google")
    #expect(rows.first?.str("keycap") == "↩")
    let titles = rows.map { $0.str("title") }
    #expect(titles.contains("The Swift Programming Language"))
    #expect(titles.contains("Swift.org"))
    let swiftOrg = rows.first { $0.str("title") == "Swift.org" }!
    #expect(swiftOrg.str("accessory") == "Switch to Tab")
    #expect(swiftOrg.str("subtitle") == "swift.org · Work")
    #expect(h.bar.list("sections").map { $0.str("title") }.contains("Tabs"))

    h.submit(swiftOrg.str("id"))
    #expect(!h.rt.ui.commandBarOpen)
    #expect(h.selected == String(swiftOrg.str("id").dropFirst(4)))
    #expect(h.rt.call("spaces", "current")["id"].string == h.spaceIds[1])
    #expect(h.allTabIds().count == before)
  }

  @Test func urlsGoAndSearchesOpenGoogle() {
    let h = Harness()
    h.startCommandBar()
    h.key("cmd+t")
    h.type("example.org/path?q=1")
    #expect(h.barRowIds.prefix(2) == ["go", "search"])
    let n = h.ids("today").count
    h.submit()
    #expect(h.ids("today").count == n + 1)
    #expect(h.tabs("list")["today"].array?.contains { $0.s("url") == "https://example.org/path?q=1" } == true)

    h.key("cmd+t")
    h.type("swift concurrency & actors")
    #expect(h.barRowIds.first == "search")
    h.submit()
    #expect(h.tabs("list")["today"].array?.contains { $0.s("url") == "https://www.google.com/search?q=swift+concurrency+%26+actors" } == true)

    // Cmd-L then a new URL navigates the current tab instead of opening one.
    let sel = h.selected!
    let count = h.ids("today").count
    h.key("cmd+l")
    h.type("webkit.org")
    #expect(h.barRowIds.first == "go")
    h.submit()
    #expect(h.ids("today").count == count)
    #expect(h.selected == sel)

    #expect(CommandBarCore.url(from: "localhost:3000") == "http://localhost:3000")
    #expect(CommandBarCore.url(from: "192.168.1.1") == "http://192.168.1.1")
    #expect(CommandBarCore.url(from: "hello world.com") == nil)
    #expect(CommandBarCore.url(from: "v1.2") == nil)
    #expect(CommandBarCore.url(from: "file.txt") == "https://file.txt")  // like any TLD-shaped input
  }

  @Test func siteSearchKeywordsScopeWithTabAndAreConfigurable() {
    let h = Harness()
    h.startCommandBar()
    h.key("cmd+t")
    h.type("yt")
    #expect(h.barRowIds.contains("scope:yt"))
    h.action("commandBar", "tab", ["query": "yt"])
    #expect(h.bar.str("placeholder") == "Search YouTube…")
    #expect(h.rt.call("commands", "state")["scope"] == "engine:yt")
    h.type("lofi beats")
    #expect(h.barRows.first?.str("subtitle") == "— Search YouTube")
    h.submit()
    #expect(h.tabs("list")["today"].array?.contains { $0.s("url") == "https://www.youtube.com/results?search_query=lofi+beats" } == true)

    // Configurable, stored in storage, and the first engine is the default.
    h.rt.call("commands", "engines", ["engines": [
      ["keyword": "ddg", "name": "DuckDuckGo", "url": "https://duckduckgo.com/?q=%s"],
      ["keyword": "yt", "name": "YouTube", "url": "https://www.youtube.com/results?search_query=%s"],
    ]])
    #expect(h.storage("commandbar", "engines").array?.count == 2)
    let h2 = Harness(root: h.root)
    h2.startCommandBar()
    h2.key("cmd+t")
    h2.type("hello")
    #expect(h2.barRows.first?.str("subtitle") == "— Search DuckDuckGo")
  }

  @Test func tabSwitchesIntoActionsMode() {
    let h = Harness()
    h.startCommandBar()
    h.key("cmd+t")
    h.action("commandBar", "tab", ["query": ""])
    #expect(h.rt.call("commands", "state")["scope"] == "actions")
    #expect(h.bar.str("placeholder") == "Search actions…")
    let titles = h.barRows.map { $0.str("title") }
    for t in ["New Space", "Rename Tab", "Pin Tab", "Duplicate Tab", "Copy URL", "Copy URL as Markdown", "Clear Today Tabs", "View Archive",
              "Toggle Sidebar", "Reload Page", "Quit den"] {
      #expect(titles.contains(t), "missing \(t)")
    }
    // No peek plugin and nobody listening for the theme editor: those are hidden, not broken.
    #expect(!titles.contains("Split Right"))
    #expect(!titles.contains("Edit Theme"))
    #expect(h.bar.list("sections").first?.str("title") == "Actions")
    h.type("side")
    #expect(h.barRows.map { $0.str("title") } == ["Toggle Sidebar"])
    #expect(h.barRows.first?.str("accessory") == "⌘S")
    h.action("commandBar", "tab", ["query": "side"])
    #expect(h.rt.call("commands", "state")["scope"] == "main")
    #expect(h.barRowIds.first == "search")
  }

  @Test func builtInCommandsDriveOtherServices() {
    let h = Harness()
    h.startCommandBar()
    h.record(["commands.run", "spaces.editTheme"])
    let sel = h.selected!

    // Pin (the selected tab is a today tab), then the same command reads "Unpin Tab".
    h.rt.call("commands", "run", ["id": "den.pinTab"])
    #expect(h.tabs("list")["pinned"].array?.contains { $0.s("id") == sel } == true)
    h.key("cmd+t")
    h.type("unpin")
    #expect(h.barRows.contains { $0.str("title") == "Unpin Tab" })
    h.submit("cmd:den.pinTab")
    #expect(h.ids("today").contains(sel))
    #expect(h.events.contains { $0.0 == "commands.run" && $0.1.s("id") == "den.pinTab" })

    let n = h.ids("today").count
    h.rt.call("commands", "run", ["id": "den.duplicateTab"])
    #expect(h.ids("today").count == n + 1)

    let hidden = h.rt.call("window", "get").b("hidden")
    h.rt.call("commands", "run", ["id": "den.toggleSidebar"])
    #expect(h.rt.call("window", "get").b("hidden") != hidden)

    let spaces = h.spaceIds.count
    h.rt.call("commands", "run", ["id": "den.newSpace"])
    #expect(h.spaceIds.count == spaces + 1)
    #expect(h.rt.call("spaces", "current")["id"].string == h.spaceIds.last)
    h.rt.call("spaces", "switch", ["id": .string(h.spaceIds[0]), "animated": false])

    // Rename continues inside the bar, pre-filled with the title.
    h.rt.call("commands", "run", ["id": "den.renameTab"])
    #expect(h.rt.call("commands", "state")["scope"] == "rename")
    #expect(h.bar.str("query") == h.tabs("list")["today"].array?.first { $0.s("id") == h.selected }?.s("title"))
    h.type("Reading list")
    h.submit()
    #expect(h.tabs("list")["today"].array?.first { $0.s("id") == h.selected }?.s("title") == "Reading list")

    // View Archive lists archived tabs; picking one restores it.
    h.rt.call("commands", "run", ["id": "den.clearToday"])
    #expect(h.ids("today") == [h.selected!])  // the selected tab stays
    h.rt.call("commands", "run", ["id": "den.viewArchive"])
    #expect(h.bar.list("sections").first?.str("title") == "Archive")
    h.type("hacker")
    #expect(h.barRows.first?.str("title") == "Hacker News")
    h.submit()
    #expect(h.tabs("list")["today"].array?.contains { $0.s("title") == "Hacker News" } == true)

    // Theme shows up once the theme plugin listens.
    h.rt.plugins.on("spaces.editTheme") { _ in }
    #expect((h.rt.call("commands", "list").array ?? []).contains { $0.s("id") == "den.theme" })
    h.rt.call("commands", "run", ["id": "den.theme"])
    #expect(h.events.contains { $0.0 == "spaces.editTheme" && $0.1.s("id") == h.spaceIds[0] })
  }

  @Test func peekServiceEnablesSplitAndShiftEnter() {
    let h = Harness()
    h.startCommandBar()
    var calls: [(String, Value)] = []
    h.rt.plugins.provide("peek") { m, a in
      calls.append((m, a))
      return ["ok": true]
    }
    #expect((h.rt.call("commands", "list").array ?? []).contains { $0.s("id") == "den.splitRight" })

    h.key("cmd+t")
    h.type("example.net")
    h.submit(shift: true)
    #expect(calls.last?.0 == "open")
    #expect(calls.last?.1.s("url") == "https://example.net")
    #expect(!h.rt.ui.commandBarOpen)

    // Split Right: pick what opens on the right.
    let sel = h.selected!
    h.rt.call("commands", "run", ["id": "den.splitRight"])
    #expect(h.bar.str("placeholder") == "Open on the right…")
    h.type("hacker")
    let row = h.barRows.first { $0.str("title") == "Hacker News" }!
    h.submit(row.str("id"))
    #expect(calls.last?.0 == "split")
    #expect(calls.last?.1["ids"] == [.string(sel), .string(String(row.str("id").dropFirst(4)))])
  }

  @Test func registeredCommandsRunThroughTheBusAndGoAwayWithTheirPlugin() {
    let h = Harness()
    h.startCommandBar()
    h.record(["commands.run"])
    #expect(!h.rt.call("commands", "register", ["id": "den.quit", "title": "x"]).isNull)  // built-in ids are taken
    #expect(h.rt.call("commands", "register", ["id": "notes.new", "title": "New Note", "icon": "sf:note.text", "keywords": ["easel"], "shortcut": "⌘⌥N"])["ok"] == true)
    h.rt.call("commands", "register", ["id": "ghost.cmd", "title": "Ghostly Thing", "owner": "ghost"])

    h.key("cmd+t")
    h.type("easel")
    let row = h.barRows.first { $0.str("id") == "cmd:notes.new" }
    #expect(row?.str("title") == "New Note")
    #expect(row?.str("accessory") == "⌘⌥N")
    #expect(h.bar.list("sections").contains { $0.str("title") == "Actions" })
    h.submit("cmd:notes.new")
    #expect(h.events.last?.0 == "commands.run")
    #expect(h.events.last?.1.s("id") == "notes.new")

    // "ghost" isn't a loaded plugin, so its command is dropped.
    h.key("cmd+t")
    h.type("ghostly")
    #expect(!h.barRowIds.contains("cmd:ghost.cmd"))
    #expect(h.rt.call("commands", "run", ["id": "ghost.cmd"]).isErr)
    #expect(h.rt.call("commands", "run", ["id": "nope"]).isErr)
  }

  @Test func rankingUsesFrequencyAndRecencyAndPersists() {
    let h = Harness()
    h.startCommandBar()
    func linearOrder(_ h: Harness) -> [String] {
      h.key("cmd+t")
      h.type("linear")
      let t = h.barRows.filter { $0.str("id").hasPrefix("tab:") }.map { $0.str("title") }
      h.key("cmd+t")
      return t
    }
    // Equal matches keep sidebar order: space 1's "Linear" first.
    #expect(linearOrder(h) == ["Linear", "Linear — My Issues"])
    for _ in 0..<2 {
      h.key("cmd+t")
      h.type("linear")
      h.submit(h.barRows.first { $0.str("title") == "Linear — My Issues" }!.str("id"))
    }
    #expect(linearOrder(h) == ["Linear — My Issues", "Linear"])
    #expect(h.storage("commandbar", "usage").isNull == false)

    // Persisted: a restart ranks the same.
    let h2 = Harness(root: h.root)
    h2.startCommandBar()
    #expect(linearOrder(h2) == ["Linear — My Issues", "Linear"])

    // Recency: three uses 100 days ago lose to one use today.
    let core = CommandBarCore(env: h.env)
    let now = h.clock
    core.usage["a"] = .init(n: 3, t: now - 100 * CommandBarCore.dayMs, title: "", url: "")
    core.usage["b"] = .init(n: 1, t: now, title: "", url: "")
    #expect(core.usageScore("b") > core.usageScore("a"))

    // Pages opened from the bar come back as history once their tab is gone.
    h.key("cmd+t")
    h.type("example.org")
    h.submit()
    let id = h.selected!
    h.tabs("close", ["id": .string(id)])
    h.key("cmd+t")
    h.type("example.org")
    #expect(h.bar.list("sections").contains { $0.str("title") == "History" })
  }

  @Test func hoverMovesTheSelection() {
    let h = Harness()
    h.startCommandBar()
    h.key("cmd+t")
    h.type("linear")
    let ids = h.barRowIds
    #expect(h.bar.str("selected") == ids[0])
    let view = h.rt.ui.commandBar
    view.lastHoverPoint = NSPoint(x: 1, y: 1)
    view.hover(ids[1], at: NSPoint(x: 1, y: 1))  // a row rebuilt under a still mouse: no change
    #expect(h.rt.call("commands", "state")["selected"].string == ids[0])
    view.hover(ids[2], at: NSPoint(x: 5, y: 9))
    #expect(h.rt.call("commands", "state")["selected"].string == ids[2])
    #expect(h.bar.str("selected") == ids[2])
    #expect(h.barRows[2].str("keycap").isEmpty == false)
  }

  @Test func matchScoring() {
    #expect(CommandBarCore.match("sw", title: "Swift.org")! > CommandBarCore.match("sw", title: "The Swift Book")!)
    #expect(CommandBarCore.match("book swift", title: "The Swift Book") != nil)
    #expect(CommandBarCore.match("xyz", title: "Swift") == nil)
    #expect(CommandBarCore.match("ycomb", title: "Hacker News", url: "https://news.ycombinator.com") != nil)
    #expect(CommandBarCore.searchURL(.init("g", "Google", "https://www.google.com/search?q=%s"), "a/b c") == "https://www.google.com/search?q=a%2Fb+c")
  }
}
