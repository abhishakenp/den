import AppKit
import CordisValue
import Foundation
import Testing

@testable import DenHost
@testable import PluginCores

/// ⌘-click groups, Today folders and their shortcuts, the tab menu's shortcuts and ⌥ alternates,
/// split modifiers, and smarter idle discard (docs/research/dia-shortlist.md Top 15, dia-ui-spec §4, §6).
@MainActor
@Suite(.serialized, .watchdog)
struct GroupTests {
  /// An on-device model stand-in: always available, answers with `reply`.
  final class FakeAI: AIGenerator {
    var reply = "“WebKit & Apple.”"
    var available = true
    var prompts: [String] = []
    func availability() -> (available: Bool, reason: String?) { available ? (true, nil) : (false, "modelNotReady") }
    var contextSize: Int { 4096 }
    func respond(instructions: String, prompt: String) async throws -> String {
      prompts.append(prompt)
      return reply
    }
    func todo(instructions: String, text: String) async throws -> (actionable: Bool, title: String) { (false, "") }
  }

  func until(_ seconds: Double = 10, _ cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
      if cond() { return true }
      try? await Task.sleep(for: .milliseconds(30))
    }
    return cond()
  }

  func cmdClick(_ h: Harness, from src: String, _ url: String) {
    h.rt.plugins.emit("webviews.newWindow", ["id": .string(src), "url": .string(url), "background": true])
  }

  func todayRow(_ h: Harness, _ id: String) -> Value {
    func find(_ list: [Value]) -> Value? {
      for v in list {
        if v.s("id") == id { return v }
        if let hit = find(v.list("children")) ?? find(v.list("closedChildren")) { return hit }
      }
      return nil
    }
    return find(h.tree("sidebar.today", 0).list("children")) ?? .null
  }

  @Test func cmdClickGroupsTheSourceAndTheNewTab() {
    let h = Harness()
    let core = h.startTabs()
    let src = h.selected!
    let before = h.ids("today")
    cmdClick(h, from: src, "https://www.apple.com/iphone/")
    // The group takes the source's place, holding the source and the new tab, in the background.
    let today = h.tabs("list")["today"].array ?? []
    let g = today[0]
    #expect(g["folder"] == true && g["auto"] == true)
    let a = g.list("children").map { $0.s("id") }
    #expect(a.count == 2 && a[0] == src)
    let new = a[1]
    #expect(h.selected == src)
    #expect(h.rt.call("webviews", "get", ["id": .string(new)])["live"] == false)  // loads when first shown
    #expect(Array(h.ids("today").dropFirst()) == Array(before.dropFirst()))
    #expect(g.s("title") == "Apple")  // from the site, until (unless) the model names it
    // Rendered as a Today group: the panel style, children indented, the source's icon.
    let node = h.tree("sidebar.today", 0)["children"][2]
    #expect(node["type"] == "folder" && node["style"] == "group")
    // A second link from the source goes after the source's first link; one from the new tab
    // goes right after it (Chrome-style opener order, dia-ui-spec §6).
    cmdClick(h, from: src, "https://www.apple.com/ipad/")
    var kids = h.tabs("list")["today"][0].list("children").map { $0.s("id") }
    #expect(kids.count == 3 && kids[0] == src && kids[1] == new)
    let second = kids[2]
    cmdClick(h, from: new, "https://www.apple.com/iphone/compare/")
    kids = h.tabs("list")["today"][0].list("children").map { $0.s("id") }
    #expect(kids.count == 4 && kids[1] == new && kids[3] == second)
    // Closing tabs down to one dissolves the group into its last tab.
    for id in kids.dropFirst() { h.tabs("close", ["id": .string(id)]) }
    #expect(h.ids("today").first == src)
    #expect(h.tabs("list")["today"].array?.contains { $0["folder"] == true } == false)
    _ = core
  }

  @Test func undoTakesTheGroupAwayAndKeepsBothTabs() {
    let h = Harness()
    h.startTabs()
    let src = h.selected!
    cmdClick(h, from: src, "https://webkit.org/blog/")
    let new = h.tabs("list")["today"][0].list("children")[1].s("id")
    h.key("ctrl+z")
    #expect(Array(h.ids("today").prefix(2)) == [src, new])
    #expect(h.tabs("list")["today"].array?.contains { $0["folder"] == true } == false)
  }

  @Test func theOnDeviceModelNamesTheGroupWithAShimmerThenAReveal() async throws {
    let h = Harness()
    let fake = FakeAI()
    h.rt.ai.generator = fake
    h.startTabs()
    let src = h.selected!
    cmdClick(h, from: src, "https://en.wikipedia.org/wiki/WebKit")
    let fid = h.tabs("list")["today"][0].s("id")
    // Pending: the header shimmers over the site-based name.
    #expect(h.tree("sidebar.today", 0)["children"][2]["pending"] == true)
    let header = try #require(HostScenarios.find(fid, in: h.rt.ui.sidebarView) as? FolderNode)
    #expect(header.header.shimmering || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    // A still frame with the highlight band over the title: the band is masked to the glyphs,
    // the right way up (written for a look; prints its path).
    if let g = header.header.shimmer {
      g.locations = [0, 0.5, 1]
      let hv = header.header
      if let rep = hv.bitmapImageRepForCachingDisplay(in: hv.bounds) {
        hv.cacheDisplay(in: hv.bounds, to: rep)
        let path = NSTemporaryDirectory() + "den-shimmer-frame.png"
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("shimmer frame: \(path)")
      }
      g.locations = [1, 1.3, 1.6]
    }
    // The new tab's title (or the 4 s wait) asks the model; its answer is cleaned and revealed.
    h.fireTimers()
    #expect(await until { h.tabs("list")["today"][0].s("title") == "WebKit & Apple" })
    #expect(fake.prompts.first?.contains("macOS") == true)
    #expect(h.tree("sidebar.today", 0)["children"][2]["pending"] == .null)
    #expect(!header.header.shimmering)
    // Without Apple Intelligence: no shimmer, the site name stays.
    let h2 = Harness()
    let off = FakeAI()
    off.available = false
    h2.rt.ai.generator = off
    h2.startTabs()
    cmdClick(h2, from: h2.selected!, "https://www.apple.com/")
    #expect(h2.tree("sidebar.today", 0)["children"][2]["pending"] == .null)
    #expect(h2.tabs("list")["today"][0].s("title") == "Apple")
    #expect(off.prompts.isEmpty)
    // Names are cleaned: quotes, punctuation, extra lines and long replies.
    #expect(TabsCore.cleanName("\"Swift Concurrency.\"\nThese tabs are about…") == "Swift Concurrency")
    #expect(TabsCore.cleanName("A very long group name that rambles on") == "A very long group")
    #expect(TabsCore.cleanName("  ") == nil)
    #expect(TabsCore.siteName("https://en.wikipedia.org/wiki/X") == "Wikipedia")
    #expect(TabsCore.siteName("https://www.bbc.co.uk/news") == "BBC")
    #expect(TabsCore.siteName("https://github.com/a/b") == "GitHub")
  }

  @Test func newTabInGroupFolderFromSelectionDropAndRename() {
    let h = Harness()
    h.startTabs()
    let src = h.selected!
    cmdClick(h, from: src, "https://www.apple.com/mac/")
    let fid = h.tabs("list")["today"][0].s("id")
    // ⌥⌘T: a new tab at the end of the selected tab's group, selected.
    h.key("cmd+opt+t")
    var kids = h.tabs("list")["today"][0].list("children")
    #expect(kids.count == 3 && kids[2].s("url") == "about:blank")
    #expect(h.selected == kids[2].s("id"))
    // Outside a group it's a plain New Tab (the command bar; not loaded here: a toast says so).
    let plain = h.ids("today")[1]
    h.tabs("select", ["id": .string(plain)])
    let toasts = h.rt.ui.toasts.count
    h.key("cmd+opt+t")
    #expect(h.rt.ui.toasts.count == toasts + 1)
    // ⌘-click picks a second tab; ⌃⌘N makes a folder of both, name open for editing.
    let other = h.ids("today")[2]
    h.action(other, "click", ["modifiers": ["cmd"]])
    #expect(todayRow(h, other)["highlighted"] == true)
    #expect(h.selected == plain)
    h.key("cmd+ctrl+n")
    let f2 = h.tabs("list")["today"][1]
    #expect(f2["folder"] == true && f2["auto"] == false)
    #expect(f2.list("children").map { $0.s("id") } == [plain, other])
    let f2id = f2.s("id")
    #expect(todayRow(h, f2id)["editing"] == true)
    h.action(f2id, "rename", ["title": "Reading"])
    #expect(h.tabs("list")["today"][1].s("title") == "Reading")
    #expect(todayRow(h, other)["highlighted"] == .null)
    // Dragging a tab onto a folder adds it at the end; ⌃Z undoes it.
    let loose = h.ids("today")[2]
    h.action(loose, "reorder", ["source": .string(loose), "target": .string(fid), "position": "into"])
    kids = h.tabs("list")["today"][0].list("children")
    #expect(kids.last?.s("id") == loose)
    h.key("ctrl+z")
    #expect(h.ids("today").contains(loose))
    // A manual folder stays with one tab and goes when its last tab does.
    h.tabs("close", ["id": .string(other)])
    #expect(h.tabs("list")["today"][1]["folder"] == true)
    h.tabs("close", ["id": .string(plain)])
    #expect(!h.ids("today").contains(f2id))
  }

  @Test func aCollapsedFolderStillShowsItsActiveTab() throws {
    let h = Harness()
    h.startTabs()
    let src = h.selected!
    cmdClick(h, from: src, "https://www.apple.com/watch/")
    let fid = h.tabs("list")["today"][0].s("id")
    let new = h.tabs("list")["today"][0].list("children")[1].s("id")
    h.tabs("select", ["id": .string(new)])
    h.action(fid, "toggle")
    let node = h.tree("sidebar.today", 0)["children"][2]
    #expect(node["open"] == false)
    #expect(node.list("closedChildren").map { $0.s("id") } == [new])
    #expect(node.list("closedChildren").first?["selected"] == true)
    // Selecting a tab inside no longer opens the folder, and ⌥⌘↓ still walks the visible rows.
    h.tabs("select", ["id": .string(src)])
    #expect(h.tabs("list")["today"][0]["open"] == false)
    #expect(h.tree("sidebar.today", 0)["children"][2].list("closedChildren").map { $0.s("id") } == [src])
    let outside = h.ids("today")[1]
    h.tabs("select", ["id": .string(outside)])
    #expect(h.tree("sidebar.today", 0)["children"][2].list("closedChildren").isEmpty)
    // The folder's hover card lists its tabs; a row switches to that tab, "New Tab" adds one.
    let previews = PreviewsCore(env: h.env)
    h.rt.plugins.provide("previews") { m, a in previews.handle(m, a) }
    previews.start()
    let card = Cards.folder(PreviewsCore.Request(anchor: fid, url: "", title: "G", icon: "", webview: "", profile: "default", selected: false, kind: "folder",
                                                 items: [["id": .string(src), "title": "A", "url": "https://www.apple.com/macos/"], ["id": .string(new), "title": "B", "url": "https://www.apple.com/watch/"]]),
                            cached: { _ in nil })
    func clickable(_ v: Value) -> [Value] {
      var out: [Value] = []
      if Text.hasPrefix(v.s("id"), "previews.open:") { out.append(v) }
      for c in v.a("children") { out += clickable(c) }
      return out
    }
    let targets = clickable(card)
    let row = try #require(targets.first { $0["value"]["tab"].string == new })
    let newTab = try #require(targets.first { $0["value"]["action"] == "newTab" })
    h.action(fid, "hover")  // the card for this folder is the current one
    previews.uiAction(row.s("id"), "click", row["value"])
    #expect(h.selected == new)
    h.action(fid, "hover")
    previews.uiAction(newTab.s("id"), "click", newTab["value"])
    #expect(h.tabs("list")["today"][0].list("children").count == 3)
  }

  @Test func tabMenuShowsShortcutsAndOptionAlternates() throws {
    let h = Harness()
    h.startTabs()
    let today = h.ids("today")
    let menu = todayRow(h, today[1])["menu"].array ?? []
    func item(_ id: String) -> Value { menu.first { $0.s("id") == id } ?? .null }
    #expect(item("copy")["key"] == "cmd+shift+c")
    #expect(item("copyMarkdown")["alternate"] == true && item("copyMarkdown")["key"] == "cmd+opt+shift+c")
    #expect(item("pin")["key"] == "cmd+d")
    #expect(item("newFolder")["key"] == "cmd+ctrl+n")
    #expect(item("close")["key"] == "cmd+w")
    #expect(item("closeOthers")["alternate"] == true && item("closeOthers")["key"] == "cmd+opt+w")
    #expect(item("closeAbove")["alternate"] == true)
    // Each alternate sits right after its primary, and AppKit gets matching key equivalents.
    let ids = menu.map { $0.s("id") }
    #expect(ids.firstIndex(of: "copyMarkdown") == ids.firstIndex(of: "copy")! + 1)
    #expect(ids.firstIndex(of: "closeOthers") == ids.firstIndex(of: "close")! + 1)
    #expect(ids.firstIndex(of: "closeAbove") == ids.firstIndex(of: "closeBelow")! + 1)
    let ns = ContextMenu.build(menu, target: NSObject(), action: #selector(NSObject.description))
    let close = try #require(ns.items.first { ($0.representedObject as? String) == "close" })
    let others = try #require(ns.items.first { ($0.representedObject as? String) == "closeOthers" })
    #expect(!close.isAlternate && others.isAlternate)
    #expect(close.keyEquivalent == "w" && others.keyEquivalent == "w")
    #expect(close.keyEquivalentModifierMask == [.command] && others.keyEquivalentModifierMask == [.command, .option])
    let below = try #require(ns.items.first { ($0.representedObject as? String) == "closeBelow" })
    let above = try #require(ns.items.first { ($0.representedObject as? String) == "closeAbove" })
    #expect(below.keyEquivalentModifierMask == [] && above.isAlternate && above.keyEquivalentModifierMask == [.option])
    // Close Tabs Below / Other Tabs archive in one undoable step.
    h.action(today[1], "menu", "closeBelow")
    #expect(h.ids("today") == Array(today.prefix(2)))
    h.key("ctrl+z")
    #expect(h.ids("today") == today)
    h.tabs("select", ["id": .string(today[2])])
    h.key("cmd+opt+w")
    #expect(h.ids("today") == [today[2]])
    #expect(h.selected == today[2])
    h.key("ctrl+z")
    #expect(h.ids("today") == today)
  }

  @Test func splitModifiersShiftOptionClickAndOptionNewTab() {
    let h = Harness()
    h.startPeek()
    let src = h.selected!
    // ⇧⌥-click is its own link rule (not a Peek).
    let rules = PeekCore.modifierRules.compactMap(LinkRule.init)
    #expect(LinkPolicy.route(rules: rules, source: URL(string: "https://a.test/"), target: URL(string: "https://b.test/x")!, isLinkClick: true, isMainFrame: true,
                             modifiers: [.shift, .opt]) == PeekCore.splitLinkEvent)
    #expect(LinkPolicy.route(rules: rules, source: URL(string: "https://a.test/"), target: URL(string: "https://b.test/x")!, isLinkClick: true, isMainFrame: true,
                             modifiers: [.shift]) == PeekCore.linkEvent)
    h.rt.plugins.emit(PeekCore.splitLinkEvent, ["id": .string(src), "url": "https://b.test/x", "source": "https://a.test/"])
    #expect(h.panes.count == 2 && h.panes[0] == src)
    #expect(h.rt.call("webviews", "get", ["id": .string(h.panes[1])])["url"] == "https://b.test/x")
    #expect(h.selected == h.panes[1])
    // ⌥-click on New Tab: a new (blank) pane joins the split, focused.
    h.action("tabs.newtab:" + h.spaceIds[0], "click", ["modifiers": ["opt"]])
    #expect(h.panes.count == 3)
    #expect(h.rt.call("webviews", "get", ["id": .string(h.panes[2])])["url"] == "about:blank")
  }

  @Test func idleDiscardSparesRecentTabsAndCountsOnlyForegroundTime() async {
    let h = Harness()
    let core = h.startTabs()
    h.rt.plugins.emit("app.active", ["active": true])
    var ids: [String] = []
    for n in 0..<7 { ids.append(h.tabs("open", ["url": .string("https://example.com/\(n)"), "background": true])["id"].string!) }
    for id in ids { h.tabs("select", ["id": .string(id)]) }
    #expect(ids.allSatisfy { h.rt.call("webviews", "get", ["id": .string($0)])["live"] == true })
    // The oldest two are past the 5 most recent tabs; the newest is on screen.
    let spare = Array(ids[2...5]), old = Array(ids.prefix(2))
    // Pages that left the screen wait in the window while their snapshot is taken.
    #expect(await until(15) { ids.dropLast().allSatisfy { h.rt.webviews.record($0)?.webView?.window == nil } })
    h.clock += 4 * 60_000
    core.tick()
    #expect(old.allSatisfy { h.rt.call("webviews", "get", ["id": .string($0)])["live"] == true })
    // An hour in another app counts for nothing…
    h.rt.plugins.emit("app.active", ["active": false])
    h.clock += 60 * 60_000
    core.tick()
    #expect(old.allSatisfy { h.rt.call("webviews", "get", ["id": .string($0)])["live"] == true })
    // …two more minutes in den make six: the old ones unload, the recent ones never do.
    h.rt.plugins.emit("app.active", ["active": true])
    h.clock += 2 * 60_000
    core.tick()
    for id in old { #expect(await h.waitUnloaded(id)) }
    h.clock += 60 * 60_000
    core.tick()
    #expect(spare.allSatisfy { h.rt.call("webviews", "get", ["id": .string($0)])["live"] == true })
  }
}
