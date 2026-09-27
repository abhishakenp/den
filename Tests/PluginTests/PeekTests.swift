import AppKit
import CordisValue
import Foundation
import Testing
import WebKit

@testable import DenHost
@testable import PluginCores

extension Harness {
  /// Starts spaces and tabs (if needed) and peek, like the real load order.
  @discardableResult
  func startPeek() -> PeekCore {
    if rt.plugins.serviceNames.contains("tabs") == false { startTabs() }
    let core = PeekCore(env: env)
    rt.plugins.provide("peek") { m, a in core.handle(m, a) }
    core.start()
    return core
  }

  func peek(_ method: String, _ args: Value = .null) -> Value { rt.call("peek", method, args) }
  var peekShown: String? { rt.call("content", "get")["peek"].string }
  var panes: [String] { (rt.call("content", "get")["panes"].array ?? []).compactMap(\.string) }
  func rules(_ id: String) -> [LinkRule] { rt.webviews.record(id)?.rules ?? [] }
  /// Today items of the current space: tab ids, or "split-n" for a split item.
  var todayItems: [Value] { tabs("list")["today"].array ?? [] }
}

@MainActor
@Suite(.serialized)
struct PeekTests {
  static let cross = LinkRule(when: .crossSite, event: PeekCore.linkEvent)

  @Test func linkPolicyFollowsPinnedAndFavoriteTabs() {
    let h = Harness()
    h.startPeek()
    let fav = h.ids("favorites")[0], pin = h.ids("pinned")[0], today = h.ids("today")[0]
    #expect(h.rules(fav).contains(Self.cross))
    #expect(h.rules(pin).contains(Self.cross))
    // A pinned tab inside a folder, and one in another space.
    let folderTab = h.tabs("list")["pinned"][2]["children"][0]["id"].string!
    #expect(h.rules(folderTab).contains(Self.cross))
    let other = h.ids("pinned", h.spaceIds[1])[0]
    #expect(h.rules(other).contains(Self.cross))
    // Today tabs only get the `*` default (shift/opt-click).
    #expect(h.rules(today).isEmpty)
    // Unpinning drops the rule; pinning adds it (kept in sync through tabs.changed).
    h.tabs("unpin", ["id": .string(pin)])
    #expect(h.rules(pin).isEmpty)
    h.tabs("pin", ["id": .string(today)])
    #expect(h.rules(today).contains(Self.cross))
    // Shift- and option-click rules come with it.
    #expect(h.rules(today).contains(LinkRule(when: .any, modifiers: [.shift], event: PeekCore.linkEvent)))
    #expect(h.rules(today).contains(LinkRule(when: .any, modifiers: [.opt], event: PeekCore.linkEvent)))
    // Turning the setting off clears every rule.
    h.peek("settings", ["peekLinks": false])
    #expect(h.rules(fav).isEmpty && h.rules(today).isEmpty)
    h.peek("settings", ["peekLinks": true])
    #expect(h.rules(fav).contains(Self.cross))
  }

  @Test func realCrossSiteClickFromPinnedTabOpensPeek() async throws {
    let h = Harness()
    h.startPeek()
    h.record(["peek.opened"])
    let pin = h.ids("pinned")[0]
    h.tabs("select", ["id": .string(pin)])
    let web = try #require(h.rt.webviews.record(pin)?.webView)
    let html = "<a id=x href='https://other.test/page'>x</a><a id=y href='https://docs.a.test/same'>y</a><script>document.getElementById('x').click()</script>"
    web.loadHTMLString(html, baseURL: URL(string: "https://www.a.test/"))
    for _ in 0..<100 where h.peekShown == nil { try await Task.sleep(for: .milliseconds(50)) }
    let pid = try #require(h.peekShown)
    #expect(h.peek("get")["sourceId"].string == pin)
    #expect(h.rt.webviews.record(pid)?.url == "https://other.test/page")
    // The pinned tab itself did not navigate away.
    #expect(h.panes == [pin])
    // A same-site click navigates in place.
    h.peek("close")
    _ = try? await web.evaluateJavaScript("document.getElementById('y').click()")
    try await Task.sleep(for: .milliseconds(400))
    #expect(h.peekShown == nil)
    #expect(h.events.count == 1)
  }

  @Test func realShiftClickFromTodayTabOpensPeek() async throws {
    let h = Harness()
    h.startPeek()
    let today = h.selected!
    let web = try #require(h.rt.webviews.record(today)?.webView)
    // A same-site link filling the page, clicked with a real shift-modified mouse event
    // (WebKit ignores modifier flags of script-synthesized clicks).
    let html = "<style>body{margin:0}a{display:block;width:100vw;height:100vh}</style><a id=x href='https://www.a.test/next'>x</a>"
    web.loadHTMLString(html, baseURL: URL(string: "https://www.a.test/"))
    for _ in 0..<100 where web.isLoading || web.url?.host != "www.a.test" { try await Task.sleep(for: .milliseconds(50)) }
    try await Task.sleep(for: .milliseconds(300))
    let win = try #require(web.window)
    let p = web.convert(NSPoint(x: web.bounds.midX, y: web.bounds.midY), to: nil)
    let target = try #require(win.contentView?.superview?.hitTest(p) ?? win.contentView?.hitTest(p))
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      let e = try #require(NSEvent.mouseEvent(with: type, location: p, modifierFlags: .shift, timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
      if type == .leftMouseDown { target.mouseDown(with: e) } else { target.mouseUp(with: e) }
      try await Task.sleep(for: .milliseconds(50))
    }
    for _ in 0..<100 where h.peekShown == nil { try await Task.sleep(for: .milliseconds(50)) }
    let pid = try #require(h.peekShown)
    #expect(h.rt.webviews.record(pid)?.url == "https://www.a.test/next")
    #expect(web.url?.absoluteString == "https://www.a.test/")
  }

  @Test func closeReopenAndEscape() {
    let h = Harness()
    h.startPeek()
    h.peek("open", ["url": "https://swift.org/"])
    let first = h.peekShown
    #expect(first != nil)
    #expect(h.rt.keys.bindings["esc"] != nil)
    h.key("esc")
    #expect(h.peekShown == nil)
    #expect(h.rt.webviews.record(first!) == nil)
    #expect(h.rt.keys.bindings["esc"] == nil)
    // Cmd-Z right after closing reopens it.
    h.key("cmd+z")
    #expect(h.peekShown != nil)
    #expect(h.rt.webviews.record(h.peekShown!)?.url == "https://swift.org/")
    #expect(h.rt.keys.bindings["cmd+z"] == nil)
    // Cmd-W closes a peek before the tab (tabs asks peek first).
    let sel = h.selected
    h.key("cmd+w")
    #expect(h.peekShown == nil)
    #expect(h.selected == sel)
    // Cmd-Shift-T reopens the peek, since it closed after the last archived tab.
    h.clock += 1000
    h.key("cmd+shift+t")
    #expect(h.peekShown != nil)
    // Once a tab is archived later, Cmd-Shift-T restores that tab instead.
    h.peek("close")
    h.clock += 1000
    h.key("cmd+w")
    let archived = h.tabs("archive")[0]["id"].string
    h.key("cmd+shift+t")
    #expect(h.peekShown == nil)
    #expect(h.selected == archived)
    // The peek's X / outside click arrives as content.peekAction close.
    h.peek("open", ["url": "https://swift.org/"])
    h.rt.plugins.emit("content.peekAction", ["action": "close", "webview": .string(h.peekShown!)])
    #expect(h.peekShown == nil)
  }

  @Test func expandTurnsPeekIntoTodayTab() {
    let h = Harness()
    h.startPeek()
    h.peek("open", ["url": "https://swift.org/blog/"])
    let pid = h.peekShown!
    let web = h.rt.webviews.record(pid)?.webView
    h.key("cmd+o")
    #expect(h.peekShown == nil)
    let first = h.tabs("list")["today"][0]
    #expect(first["url"] == "https://swift.org/blog/")
    // The peek's own web view (history, scroll) became the tab.
    #expect(first["id"].string == pid)
    #expect(web != nil && h.rt.webviews.record(pid)?.webView === web)
    #expect(h.selected == first["id"].string)
    #expect(h.panes == [first["id"].string!])
    // The expand button, and the service call.
    h.peek("open", ["url": "https://webkit.org/"])
    h.rt.plugins.emit("content.peekAction", ["action": "expand", "webview": .string(h.peekShown!)])
    #expect(h.tabs("list")["today"][0]["url"] == "https://webkit.org/")
    #expect(h.peek("expand").isErr)
  }

  @Test func peekSplitButtonMakesSplitWithCurrentTab() {
    let h = Harness()
    h.startPeek()
    let sel = h.selected!
    h.peek("open", ["url": "https://webkit.org/"])
    h.rt.plugins.emit("content.peekAction", ["action": "split", "webview": .string(h.peekShown!)])
    #expect(h.peekShown == nil)
    let item = h.todayItems.first { $0["split"] == true }
    #expect(item != nil)
    let kids = (item?["children"].array ?? []).compactMap { $0["id"].string }
    #expect(kids.count == 2 && kids[0] == sel)
    #expect(item?["children"][1]["url"] == "https://webkit.org/")
    #expect(h.panes == kids)
    #expect(h.selected == kids[1])
  }

  @Test func splitStateShortcutsAndPersistence() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("den-peek-\(UUID())")
    let h = Harness(root: root)
    let tabsCore = h.startTabs()
    h.startPeek()
    let t = h.ids("today")
    let r = h.peek("split", ["ids": [.string(t[0]), .string(t[1])], "layout": "horizontal"])
    let sid = try! #require(r["id"].string)
    // One sidebar item in place of the two tabs.
    #expect(h.todayItems.count == 3)
    #expect(h.todayItems[0]["id"].string == sid)
    #expect(h.todayItems[0]["layout"] == "horizontal")
    #expect(h.panes == [t[0], t[1]])
    #expect(h.rt.call("content", "get")["orientation"] == "horizontal")
    // Rendered as one split row holding both tabs.
    let row = h.tree("sidebar.today", 0)["children"][2]
    #expect(row["type"] == "splitRow" && row["id"].string == sid)
    #expect(row["panes"].array?.map { $0.s("id") } == [t[0], t[1]])
    // Ctrl-Shift-2 focuses the second pane; tabs follows with the selection.
    h.key("ctrl+shift+2")
    #expect(h.rt.call("content", "get")["focus"].string == t[1])
    #expect(h.selected == t[1])
    h.key("ctrl+shift+1")
    #expect(h.selected == t[0])
    // Ctrl-Shift-= adds a third pane (a new tab), focused.
    h.key("ctrl+shift+=")
    #expect(h.panes.count == 3)
    let added = h.panes[2]
    #expect(h.selected == added)
    // Grid layout through the split's menu.
    h.action(sid, "menu", .string("layout:" + sid + ":grid"))
    #expect(h.rt.call("content", "get")["orientation"] == "grid")
    #expect(h.todayItems[0]["layout"] == "grid")
    // A fourth pane is allowed; a fifth is not.
    #expect(!h.peek("split", ["ids": [.string(t[0]), .string(t[2])], "layout": "grid"]).isErr)
    #expect(h.panes.count == 4)
    #expect(h.peek("split", ["ids": [.string(t[0]), .string(t[3])], "layout": "grid"]).isErr)
    // Ctrl-Shift-- archives the focused today pane.
    h.rt.call("content", "focus", ["id": .string(added)])
    h.key("ctrl+shift+-")
    #expect(h.panes.count == 3 && !h.panes.contains(added))
    #expect(h.tabs("archive")[0]["id"].string == added)
    // The split survives a restart.
    tabsCore.stop()
    let h2 = Harness(root: root)
    h2.startPeek()
    #expect(h2.todayItems[0]["split"] == true)
    #expect(h2.todayItems[0]["children"].array?.count == 3)
    #expect(h2.panes.count == 3)
    // "Separate All Tabs" puts the tabs back into the list in pane order.
    h2.peek("unsplit", ["id": .string(sid)])
    #expect(h2.todayItems.allSatisfy { $0["split"] != true })
    #expect(Array(h2.ids("today").prefix(3)) == [t[0], t[1], t[2]])
    #expect(h2.panes.count == 1)
  }

  /// The split's own sidebar row: a segment per pane, click focuses a pane, a tab dropped "into"
  /// the row joins the split, the hover X separates it.
  @Test func splitRowSegmentsClickDropAndClose() throws {
    let h = Harness()
    h.startPeek()
    let w = h.rt.window.window
    w.orderFront(nil)
    let t = h.ids("today")
    let sid = try #require(h.peek("split", ["ids": [.string(t[0]), .string(t[1])], "layout": "horizontal"])["id"].string)
    w.contentView?.layoutSubtreeIfNeeded()
    h.rt.ui.sidebarView.layoutSubtreeIfNeeded()
    let row = try #require(HostScenarios.find(sid, in: h.rt.ui.sidebarView) as? SplitRowNode)
    row.layoutSubtreeIfNeeded()
    #expect(row.segments.map(\.id) == [t[0], t[1]])
    #expect(row.node.flag("selected"))
    #expect(row.segments.filter(\.focused).map(\.id) == [h.selected!])
    // Segments split the row evenly and don't overlap.
    #expect(row.segments[0].frame.maxX <= row.segments[1].frame.minX)
    #expect(abs(row.segments[0].frame.width - row.segments[1].frame.width) < 1)
    #expect(!row.segments[0].label.isHidden)
    // A real click on the first segment focuses that pane.
    func ev(_ type: NSEvent.EventType, _ v: NSView, _ p: NSPoint) -> NSEvent {
      NSEvent.mouseEvent(with: type, location: v.convert(p, to: nil), modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    let p0 = NSPoint(x: row.segments[0].frame.midX, y: row.bounds.midY)
    row.mouseDown(with: ev(.leftMouseDown, row, p0))
    row.mouseUp(with: ev(.leftMouseUp, row, p0))
    #expect(h.selected == t[0])
    #expect(h.rt.call("content", "get")["focus"].string == t[0])
    #expect(row.segments.filter(\.focused).map(\.id) == [t[0]])
    // Drag the next today tab into the middle of the split row: it joins as a third pane.
    let other = try #require(HostScenarios.find(t[2], in: h.rt.ui.sidebarView) as? TabRowNode)
    let drag = h.rt.ui.drag
    drag.begin(other, event: ev(.leftMouseDown, other, NSPoint(x: other.bounds.midX, y: other.bounds.midY)))
    drag.move(ev(.leftMouseDragged, row, NSPoint(x: row.bounds.midX, y: row.bounds.midY)))
    drag.end(ev(.leftMouseUp, row, NSPoint(x: row.bounds.midX, y: row.bounds.midY)))
    #expect(h.panes == [t[0], t[1], t[2]])
    #expect(h.todayItems[0]["children"].array?.map { $0.s("id") } == [t[0], t[1], t[2]])
    let row3 = try #require(HostScenarios.find(sid, in: h.rt.ui.sidebarView) as? SplitRowNode)
    #expect(row3.segments.count == 3)
    // The hover X separates the split back into tabs.
    h.action(sid, "close")
    #expect(h.todayItems.prefix(3).map { $0.s("id") } == [t[0], t[1], t[2]])
    #expect(h.tree("sidebar.today", 0)["children"].array?.contains { $0["type"] == "splitRow" } == false)
    h.key("ctrl+z")
    #expect(h.todayItems[0]["split"] == true)
  }

  @Test func splitShrinksToOneTabAndDissolves() {
    let h = Harness()
    h.startPeek()
    let t = h.ids("today")
    let sid = h.peek("split", ["ids": [.string(t[0]), .string(t[1])], "layout": "vertical"])["id"].string!
    #expect(h.rt.call("content", "get")["orientation"] == "vertical")
    // Closing one of two panes leaves a plain tab.
    h.tabs("close", ["id": .string(t[1])])
    #expect(h.todayItems.allSatisfy { $0["split"] != true })
    #expect(h.ids("today").contains(t[0]))
    #expect(h.peek("unsplit", ["id": .string(sid)]).isErr)
    // Dropping a sidebar tab on the content (right side) splits it with the shown tab.
    h.tabs("select", ["id": .string(t[0])])
    h.action(t[2], "dropOnContent", ["side": "right"])
    #expect(h.panes == [t[0], t[2]])
    // Left side puts it first, joining the same split.
    h.action(t[3], "dropOnContent", ["side": "left"])
    #expect(h.panes.count == 3)
    #expect(h.todayItems.filter { $0["split"] == true }.count == 1)
    // Separating one tab puts it after the split.
    h.peek("unsplit", ["id": .string(t[2])])
    let items = h.todayItems
    #expect(items[0]["split"] == true && items[0]["children"].array?.count == 2)
    #expect(items[1]["id"].string == t[2])
    // The pane pill's separate and close (content.paneAction).
    h.peek("split", ["ids": [.string(t[0]), .string(t[2])], "layout": "horizontal"])
    #expect(h.panes.count == 3)
    h.rt.plugins.emit("content.paneAction", ["id": .string(t[2]), "action": "separate"])
    #expect(h.panes == [t[2]] && h.selected == t[2])
    #expect(h.todayItems[0]["children"].array?.count == 2)
    h.rt.plugins.emit("content.paneAction", ["id": .string(t[3]), "action": "close"])
    #expect(h.todayItems.allSatisfy { $0["split"] != true })
    #expect(h.tabs("archive")[0]["id"].string == t[3])
  }

  @Test func pinnedSplitKeepsPeekPolicy() {
    let h = Harness()
    h.startPeek()
    let p = h.ids("pinned")
    h.peek("split", ["ids": [.string(p[0]), .string(p[1])], "layout": "horizontal"])
    let item = h.tabs("list")["pinned"][0]
    #expect(item["split"] == true)
    #expect(item["children"][0]["kind"] == "pinned")
    #expect(h.rules(p[0]).contains(Self.cross) && h.rules(p[1]).contains(Self.cross))
    // Ctrl-Shift-- on a pinned pane only separates it.
    h.rt.call("content", "focus", ["id": .string(p[1])])
    h.key("ctrl+shift+-")
    #expect(h.ids("pinned").contains(p[1]))
    #expect(h.tabs("archive").array?.isEmpty == true)
  }

  @Test func littleArcTakesLinksFromOtherApps() {
    let h = Harness()
    h.startPeek()
    let today = h.ids("today")
    h.rt.app.open([URL(string: "https://www.swift.org/blog/")!])
    let minis = h.rt.call("window", "listMini").array ?? []
    #expect(minis.count == 1)
    #expect(h.ids("today") == today)  // no tab: it went to Little Arc
    let win = minis[0]["id"].string!, web = minis[0]["webview"].string!
    #expect(h.rt.webviews.record(web)?.url == "https://www.swift.org/blog/")
    #expect(h.peek("get")["littleArcs"][0]["window"].string == win)
    // The same link again brings back that page instead of a second one.
    h.rt.app.open([URL(string: "https://swift.org/blog")!])
    #expect(h.rt.call("window", "listMini").array?.count == 1)
    #expect(h.rt.call("window", "listMini")[0]["webview"].string == web)
    // "Open in <space>": the same web view becomes a today tab, selected.
    let win2 = h.rt.call("window", "listMini")[0]["id"].string!
    h.rt.plugins.emit("window.miniAction", ["id": .string(win2), "webview": .string(web), "action": "open"])
    #expect(h.rt.call("window", "listMini").array?.isEmpty == true)
    #expect(h.ids("today").first == web)
    #expect(h.selected == web)
    #expect(h.rt.webviews.record(web) != nil)
    #expect(h.panes == [web])
  }

  @Test func littleArcCloseArchiveAndSetting() {
    let h = Harness()
    h.startPeek()
    h.rt.app.open([URL(string: "https://webkit.org/")!])
    var web = h.rt.call("window", "listMini")[0]["webview"].string!
    // Closing the window (it emits window.miniClosed) drops its page.
    h.rt.call("window", "closeMini", ["id": h.rt.call("window", "listMini")[0]["id"]])
    #expect(h.rt.webviews.record(web) == nil)
    #expect(h.peek("get")["littleArcs"].array?.isEmpty == true)
    // Auto-archive after 6 h unused.
    h.rt.app.open([URL(string: "https://webkit.org/blog/")!])
    web = h.rt.call("window", "listMini")[0]["webview"].string!
    h.clock += PeekCore.defaultLittleArcArchiveMs - 1000
    h.fireTimers()
    #expect(h.rt.call("window", "listMini").array?.count == 1)
    h.clock += 2000
    h.fireTimers()
    #expect(h.rt.call("window", "listMini").array?.isEmpty == true)
    #expect(h.rt.webviews.record(web) == nil)
    // With Little Arc off, links from other apps open as today tabs.
    h.peek("settings", ["littleArc": false])
    h.rt.app.open([URL(string: "https://www.swift.org/")!])
    #expect(h.rt.call("window", "listMini").array?.isEmpty == true)
    #expect(h.tabs("list")["today"][0]["url"] == "https://www.swift.org/")
  }
}
