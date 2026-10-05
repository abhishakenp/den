import AppKit
import CordisValue
import DenTestSupport
import Testing

@testable import DenHost
@testable import PluginCores

/// The system default browser, faked so tests never touch macOS.
final class FakeBrowsers: @unchecked Sendable {
  var current: URL? = URL(fileURLWithPath: "/Applications/Safari.app")
  var sets: [(URL, String)] = []
}

/// Web-suggestion requests a test hasn't answered yet, per harness.
@MainActor var fakeBrowsers: [ObjectIdentifier: FakeBrowsers] = [:]
@MainActor var pendingSuggest: [ObjectIdentifier: [(String, @Sendable ([String]?) -> Void)]] = [:]

extension Harness {
  /// Starts spaces, tabs and the command bar, like the real load order.
  @discardableResult
  func startCommandBar() -> CommandBarCore {
    // A fresh fake per harness: a finished test's Harness can leave its entry behind under an
    // ObjectIdentifier that a new Harness at the same address then reuses.
    fakeBrowsers[ObjectIdentifier(self)] = FakeBrowsers()
    pendingSuggest[ObjectIdentifier(self)] = nil
    if rt.plugins.serviceNames.contains("tabs") == false { startTabs() }
    // Offline: web suggestions never answer unless a test answers them (see `answerSuggestions`).
    suggest.fetch = { [weak self] q, done in
      MainActor.assumeIsolated { self?.suggestRequests.append((q, done)) }
      return {}
    }
    suggest.debounce = 0
    // A fresh fake per harness: a new Harness can reuse a finished one's address, and so its
    // ObjectIdentifier, which would hand this test the other test's browser state.
    let fake = FakeBrowsers()
    fakeBrowsers[ObjectIdentifier(self)] = fake
    pendingSuggest[ObjectIdentifier(self)] = nil
    rt.app.browserDefaults = BrowserDefaults(
      current: { fake.current },
      set: { url, scheme, done in
        fake.sets.append((url, scheme))
        fake.current = url
        done(nil)
      })
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
  var browsers: FakeBrowsers {
    if let b = fakeBrowsers[ObjectIdentifier(self)] { return b }
    let b = FakeBrowsers()
    fakeBrowsers[ObjectIdentifier(self)] = b
    return b
  }
  var suggest: SuggestService { rt.host.services["suggest"] as! SuggestService }
  /// Answers the latest pending web-suggestion request, then waits for the event to land.
  var suggestRequests: [(String, @Sendable ([String]?) -> Void)] {
    get { pendingSuggest[ObjectIdentifier(self)] ?? [] }
    set { pendingSuggest[ObjectIdentifier(self)] = newValue }
  }
  /// Answers the latest pending web-suggestion request, then lets the main queue deliver the event.
  func answerSuggestions(_ items: [String]) async {
    guard let (_, done) = suggestRequests.popLast() else { return }
    done(items)
    await Wait.mainQueueTurn()  // the answer is delivered with DispatchQueue.main.async
  }
  func allTabIds() -> [String] { spaceIds.flatMap { ids("pinned", $0) + ids("today", $0) } + ids("favorites") }
}

@MainActor
@Suite(.serialized, .watchdog)
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
    #expect(swiftOrg.str("subtitle") == "— swift.org · Work")
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

  /// Opening a site that has a keyword, or a web search starting with its keyword or name, hints
  /// at the keyword (the tips plugin shows it once); a search through the keyword says so.
  @Test func siteKeywordHints() {
    let h = Harness()
    h.startCommandBar()
    h.record(["commands.keywordHint", "commands.keywordSearch"])
    func hints() -> [String] { h.events.filter { $0.0 == "commands.keywordHint" }.map { $0.1.s("keyword") + " " + $0.1.s("name") } }
    for q in ["youtube.com", "yt cats", "wikipedia otters", "hello world", "google.com", "youtube"] {
      h.key("cmd+t")
      h.type(q)
      h.submit()
    }
    // youtube.com, "yt cats", "wikipedia otters"; not a plain search, the default engine's site, or one word.
    #expect(hints() == ["yt YouTube", "yt YouTube", "w Wikipedia"])
    #expect(h.events.allSatisfy { $0.0 != "commands.keywordSearch" })
    h.key("cmd+t")
    h.type("yt")
    h.action("commandBar", "tab", ["query": "yt"])
    h.type("lofi")
    h.submit()
    #expect(h.events.filter { $0.0 == "commands.keywordSearch" }.map { $0.1.s("keyword") } == ["yt"])
    #expect(hints().count == 3)
  }

  /// Creation commands open each site's new-item URL in a new tab; New GitHub Issue only shows on
  /// a repository's page, and files in that repository.
  @Test func creationCommands() {
    let h = Harness()
    h.startCommandBar()
    func urls() -> [String] { (h.tabs("list")["today"].array ?? []).map { $0.s("url") } }
    for (q, id, url) in [("new google doc", "googleDoc", "https://docs.new"), ("new sheet", "googleSheet", "https://sheets.new"),
                         ("notion", "notionPage", "https://notion.new"), ("linear issue", "linearIssue", "https://linear.new"),
                         ("new gist", "gist", "https://gist.new"), ("figma", "figmaFile", "https://figma.new")] {
      h.key("cmd+t")
      h.type(q)
      #expect(h.barRowIds.contains("cmd:den.new." + id), "\(q)")
      h.submit("cmd:den.new." + id)
      #expect(urls().contains(url), "\(q)")
    }
    #expect(!h.rt.ui.commandBarOpen)
    // Not on a repository page: no New GitHub Issue.
    h.key("cmd+t")
    h.type("new issue")
    #expect(!h.barRowIds.contains("cmd:den.new.githubIssue") && h.barRowIds.contains("cmd:den.new.linearIssue"))
    h.key("cmd+t")  // closes it
    h.tabs("open", ["url": "https://github.com/abhishakenp/den/pull/12"])
    h.key("cmd+t")
    h.type("new issue")
    #expect(h.barRows.first { $0.str("id") == "cmd:den.new.githubIssue" }?.str("title") == "New GitHub Issue in abhishakenp/den")
    h.submit("cmd:den.new.githubIssue")
    #expect(urls().contains("https://github.com/abhishakenp/den/issues/new"))
    #expect(CommandBarCore.githubRepo("https://github.com/settings/profile") == nil)
    #expect(CommandBarCore.githubRepo("https://github.com/abhishakenp") == nil)
    #expect(CommandBarCore.githubRepo("https://gist.github.com/a/b") == nil)
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
    #expect(h.barRows.first?.str("shortcut") == "⌘S")
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
    #expect(row?.str("shortcut") == "⌘⌥N")
    #expect(h.bar.list("sections").contains { $0.str("title") == "den" })
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

  // MARK: - Web suggestions, merging and ranking

  @Test func mergeKeepsShownSuggestionsStableWhileTyping() {
    let m = CommandBarCore.mergeSuggestions
    // Fresh answer: the query itself and duplicates (any case/spacing) are left out; limit applies.
    #expect(m([], ["icon", "icons", "Icons", "iconic", "icon  tablet", "icon tablet", "icons8"], "icon", 4) == ["icons", "iconic", "icon  tablet", "icons8"])
    // Pending (no answer for this query yet): shown rows that still extend the query stay, in order.
    #expect(m(["icons", "iconic", "ice age"], nil, "icon", 4) == ["icons", "iconic"])
    #expect(m(["icons", "iconic"], nil, "  ICON ", 4) == ["icons", "iconic"])
    // Answer arrives: rows it confirms keep their place, its new rows follow in its order.
    #expect(m(["iconic", "icons"], ["icons", "icon pack", "iconic"], "icon", 4) == ["iconic", "icons", "icon pack"])
    // Rows the answer drops go away.
    #expect(m(["icons", "iconic"], ["iconify"], "iconi", 4) == ["iconify"])
    #expect(CommandBarCore.normQuery("  Git   HUB ") == "git hub")
  }

  @Test func webSuggestionsBlendBelowStrongLocalMatchesWithoutMovingThem() async {
    let h = Harness()
    h.startCommandBar()
    h.key("cmd+t")
    h.type("swi")
    #expect(h.suggestRequests.last?.0 == "swi")
    let before = h.barRowIds
    #expect(before.first == "search")
    #expect(!before.contains { $0.hasPrefix("sugg:") })
    await h.answerSuggestions(["swi", "swiggy", "swift", "switch 2", "swimming", "swiss"])
    let after = h.barRowIds
    // Everything that was on screen keeps its position; suggestions come after the strong tab matches
    // (as many as fit under their "Suggestions" header).
    #expect(Array(after.prefix(before.count)) == before)
    #expect(after.filter { $0.hasPrefix("sugg:") } == ["sugg:swiggy", "sugg:swift", "sugg:switch 2"])
    #expect(h.bar.list("sections").last?.str("title") == "Suggestions")
    #expect(after.count <= CommandBarCore.maxRows)
    let sugg = h.barRows.first { $0.str("id") == "sugg:swift" }!
    #expect(sugg.str("icon") == "sf:magnifyingglass")

    // Typing on: shown suggestions that still match stay put until the new answer lands.
    h.type("swif")
    #expect(h.barRowIds.filter { $0.hasPrefix("sugg:") } == ["sugg:swift"])
    // A late answer for the old query is ignored.
    h.rt.plugins.emit("suggest.results", ["q": "swi", "items": ["swiggy"]])
    #expect(!h.barRowIds.contains("sugg:swiggy"))
    await h.answerSuggestions(["swift", "swiftui", "swift codes"])
    #expect(h.barRowIds.filter { $0.hasPrefix("sugg:") } == ["sugg:swift", "sugg:swiftui", "sugg:swift codes"])

    // Picking a suggestion searches it with the default engine.
    h.submit("sugg:swiftui")
    #expect(h.tabs("list")["today"].array?.contains { $0.s("url") == "https://www.google.com/search?q=swiftui" } == true)
  }

  @Test func cachedSuggestionsShowAtOnceAndUrlsGoDirectly() async {
    let h = Harness()
    h.startCommandBar()
    h.key("cmd+t")
    h.type("news")
    await h.answerSuggestions(["news", "news.ycombinator.com", "news today"])
    h.key("cmd+t")  // close
    h.key("cmd+t")
    h.type("news")  // cached: no request, rows at once
    #expect(h.suggestRequests.isEmpty)
    let nav = h.barRows.first { $0.str("id") == "sugg:news.ycombinator.com" }
    #expect(nav?.str("subtitle") == "— Open URL")
    #expect(nav?.str("icon").hasPrefix("https://") == true)
    h.submit("sugg:news.ycombinator.com")
    #expect(h.tabs("list")["today"].array?.contains { $0.s("url") == "https://news.ycombinator.com" } == true)

    // A domain gets a Go row first (with its favicon); a full URL asks for no suggestions.
    h.key("cmd+t")
    h.type("news.ycombinator.com")
    #expect(h.barRowIds.prefix(2) == ["go", "search"])
    #expect(h.barRows[0].str("icon").hasPrefix("https://"))
    #expect(h.bar.str("inputMode") == "go")
    h.type("https://example.com/a")
    #expect(h.suggestRequests.last?.0 != "https://example.com/a")
    #expect(!h.barRowIds.contains { $0.hasPrefix("sugg:") })
  }

  @Test func emptyStateShowsRecentTabsThenSuggestedActions() {
    let h = Harness()
    h.startCommandBar()
    h.key("cmd+t")
    let secs = h.bar.list("sections")
    #expect(secs.map { $0.str("title") } == ["Tabs", "den"])
    #expect(h.bar.flag("headers") == true)
    let tabs = secs[0].list("rows"), actions = secs[1].list("rows")
    #expect(!tabs.isEmpty && tabs.count <= 4)
    #expect(tabs.allSatisfy { $0.str("accessory") == "Switch to Tab" && $0.str("keycap") == "→" })
    #expect(!actions.isEmpty)
    // Rows and the two headers fill the bar's height: 6 rows + 2 x 28 pt fit in 8 rows.
    #expect((tabs.count + actions.count) * CommandBarCore.rowCost + 2 * CommandBarCore.headerCost <= CommandBarCore.maxRows * CommandBarCore.rowCost)
    #expect(tabs.count + actions.count == 6)
  }

  // MARK: - Default-browser banner

  @Test func bannerShowsUntilDenIsTheDefaultOrDismissed() async {
    let h = Harness()
    h.startCommandBar()
    h.key("cmd+t")
    #expect(h.bar["banner"].str("primary") == "Set den as default")
    #expect(h.bar["banner"].str("secondary") == "Try for a week")
    #expect(!h.rt.ui.commandBar.banner.isHidden)
    // Its panel grows by the 60 pt banner (+ the bottom border).
    let withBanner = h.rt.ui.commandBar.contentHeight

    // "×" hides it for good (docs/defaults.md); Settings > Search brings it back.
    h.action("commandBar", "banner", ["button": "close"])
    #expect(h.bar["banner"].isNull)
    #expect(h.rt.ui.commandBar.contentHeight == withBanner - 61)
    #expect(h.rt.call("settings", "get", ["id": "commandbar", "key": "banner"]) == false)
    h.key("cmd+t")
    h.clock += 60 * CommandBarCore.dayMs
    h.key("cmd+t")
    #expect(h.bar["banner"].isNull)
    h.key("cmd+t")
    h.rt.call("settings", "set", ["id": "commandbar", "key": "banner", "value": true])
    h.key("cmd+t")
    #expect(!h.bar["banner"].isNull)

    // "Set den as default" asks macOS (for http and https); once den is the default it's gone.
    h.action("commandBar", "banner", ["button": "set"])
    #expect(h.browsers.sets.map { $0.1 } == ["http", "https"])
    #expect(h.browsers.sets.allSatisfy { $0.0 == Bundle.main.bundleURL })
    #expect(await Wait.until("den to be the default browser, and the banner gone") {
      h.rt.call("app", "defaultBrowser")["isDefault"] == true && h.bar["banner"].isNull
    })
  }

  @Test func tryForAWeekAsksAfterSevenDaysAndCanSwitchBack() async {
    let h = Harness()
    h.startCommandBar()
    h.key("cmd+t")
    #expect(h.rt.call("app", "defaultBrowser")["bundleId"] == "com.apple.Safari")
    h.action("commandBar", "banner", ["button": "try"])
    #expect(h.storage("commandbar", "browserTrial").s("previous") == "com.apple.Safari")
    #expect(h.browsers.current == Bundle.main.bundleURL)
    await Wait.mainQueueTurn()
    h.fireTimers()  // day 0: nothing to ask yet
    #expect(!h.rt.ui.dialogOpen)
    h.clock += 7 * CommandBarCore.dayMs
    h.fireTimers()
    #expect(h.rt.ui.dialogOpen)
    #expect(h.rt.ui.dialog.node.str("title") == "Keep den as your default browser?")
    h.action(CommandBarCore.trialDialog, "button", ["button": "switch"])
    #expect(!h.rt.ui.dialogOpen)
    #expect(h.browsers.current?.lastPathComponent == "Safari.app")
    #expect(h.storage("commandbar", "browserTrial").isNull)

    // Keep: den stays the default and the trial ends.
    h.action("commandBar", "banner", ["button": "try"])
    h.clock += 8 * CommandBarCore.dayMs
    h.fireTimers()
    #expect(h.rt.ui.dialogOpen)
    h.action(CommandBarCore.trialDialog, "button", ["button": "keep"])
    #expect(h.browsers.current == Bundle.main.bundleURL)
    #expect(h.storage("commandbar", "browserTrial").isNull)
  }

  @Test func selectionFillIsTheThemeHueAtArcsLuminance() {
    typealias C = CommandBarView.Colors
    let arc = C.selectionFill(nil).usingColorSpace(.sRGB)!
    #expect(Int((arc.redComponent * 255).rounded()) == 65 && Int((arc.greenComponent * 255).rounded()) == 72 && Int((arc.blueComponent * 255).rounded()) == 216)
    let target = C.luminance(C.arcSelection)
    for hex in [(0.72, 0.55, 1.0), (0.2, 0.5, 1.0), (1.0, 0.62, 0.78)] {  // purple, blue, pink themes
      let accent = NSColor(srgbRed: hex.0, green: hex.1, blue: hex.2, alpha: 1)
      let f = C.selectionFill(accent)
      #expect(abs(C.luminance(f) - target) < 0.002)
      #expect(abs(f.hueComponent - accent.usingColorSpace(.sRGB)!.hueComponent) < 0.01)
    }
  }
}
