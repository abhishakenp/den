import AppKit
import CordisValue
import DenTestSupport
import Testing

@testable import DenHost
@testable import PluginCores

@MainActor
@Suite(.serialized, .watchdog)
struct TabsTests {
  @Test func firstRunSeedRendersEverySection() {
    let h = Harness()
    h.startTabs()
    let l = h.tabs("list")
    #expect(l["favorites"].array?.count == 4)
    #expect(l["favorites"][0]["spaceId"] == .null)
    #expect(l["favorites"][0]["kind"] == "favorite")
    let pinned = l["pinned"].array ?? []
    #expect(pinned.count == 3)
    #expect(pinned[2]["folder"] == true)
    #expect(pinned[2]["children"][0]["kind"] == "pinned")
    #expect(pinned[2]["children"][0]["folderId"] == pinned[2]["id"])
    #expect(l["today"].array?.count == 4)
    #expect(h.selected == l["today"][0]["id"].string)
    // The selected tab is in the content area, and the URL pill shows its simplified domain.
    #expect(h.rt.call("content", "get")["panes"] == [.string(h.selected!)])
    let pill = h.tree("sidebar.header", 0)["children"][1]
    #expect(pill["text"] == "apple.com")
    #expect(h.rt.call("ui", "get")["pages"] == 3)
  }

  @Test func closeArchivesTodayAndReopenRestores() {
    let h = Harness()
    h.startTabs()
    h.record(["tabs.closed", "tabs.opened", "tabs.selected"])
    let id = h.tabs("open", ["url": "https://swift.org/blog"])["id"].string!
    #expect(h.ids("today").first == id)
    #expect(h.selected == id)
    h.key("cmd+w")
    #expect(!h.ids("today").contains(id))
    #expect(h.tabs("archive")[0]["id"].string == id)
    #expect(h.tabs("archive")[0]["url"] == "https://swift.org/blog")
    #expect(h.selected != nil && h.selected != id)
    h.key("cmd+shift+t")
    #expect(h.ids("today").first == id)
    #expect(h.selected == id)
    #expect(h.tabs("archive").array?.first?["id"].string != id)
    #expect(h.events.map(\.0).contains("tabs.closed"))
  }

  @Test func closingPinnedOnlyUnloadsAndResetClearsDrift() async {
    let h = Harness()
    h.startTabs()
    let pid = h.ids("pinned")[0]
    h.tabs("select", ["id": .string(pid)])
    #expect(h.rt.call("webviews", "get", ["id": .string(pid)])["live"] == true)
    // The page navigates away from its pinned URL: the "/" marker shows.
    h.rt.plugins.emit("webviews.url", ["id": .string(pid), "url": "https://developer.apple.com/swift/"])
    #expect(h.tabs("list")["pinned"][0]["url"] == "https://developer.apple.com/swift/")
    let row = h.tree("sidebar.pinned", 0)["children"][0]
    #expect(row["drift"] == true)
    h.action(pid, "reset")
    #expect(h.tabs("list")["pinned"][0]["url"] == "https://developer.apple.com/documentation")
    #expect(h.tree("sidebar.pinned", 0)["children"][0]["drift"] != true)  // flags are left out when false
    h.tabs("close", ["id": .string(pid)])
    #expect(h.ids("pinned").contains(pid))
    #expect(await h.waitUnloaded(pid))
    #expect(h.tabs("archive").array?.isEmpty == true)
  }

  @Test func clearTodayToastAndUndo() {
    let h = Harness()
    h.startTabs()
    let before = h.ids("today")
    let keep = h.selected!
    h.key("cmd+shift+k")
    #expect(h.ids("today") == [keep])
    #expect(h.tabs("archive").array?.count == 3)
    #expect(h.rt.ui.toasts.count == 1)
    h.key("ctrl+z")
    #expect(h.ids("today") == before)
    #expect(h.tabs("archive").array?.isEmpty == true)
    #expect(h.tabs("undo").isError)
  }

  @Test func pinUnpinFavoriteMoveAndFolders() {
    let h = Harness()
    h.startTabs()
    let spaces = h.spaceIds
    let t = h.ids("today")[1]
    h.tabs("select", ["id": .string(t)])
    h.key("cmd+d")
    #expect(h.ids("pinned").last == t)
    #expect(h.tabs("list")["pinned"].array?.last?["pinnedUrl"] == h.tabs("list")["pinned"].array?.last?["url"])
    h.key("cmd+d")
    #expect(h.ids("today").first == t)
    #expect(h.tabs("list")["today"][0]["pinnedUrl"] == .null)
    #expect(h.tabs("favorite", ["id": .string(t)]) == ["ok": true])
    #expect(h.ids("favorites").last == t)
    #expect(h.ids("favorites", spaces[1]).last == t)  // shared by every space
    // Favorites cap at 12.
    for n in 0..<7 { h.tabs("open", ["url": .string("https://example.com/\(n)"), "kind": "favorite", "background": true]) }
    #expect(h.ids("favorites").count == 12)
    #expect(h.tabs("open", ["url": "https://example.org", "kind": "favorite"]).isError)

    // Move a today tab to another space's pinned section, then into a nested folder.
    let u = h.ids("today")[1]
    #expect(h.tabs("move", ["id": .string(u), "spaceId": .string(spaces[1]), "kind": "pinned"]) == ["ok": true])
    #expect(h.ids("pinned", spaces[1]).last == u)
    let outer = h.tabs("createFolder", ["spaceId": .string(spaces[1]), "title": "Outer", "tabIds": [.string(u)]])["id"].string!
    let inner = h.tabs("createFolder", ["spaceId": .string(spaces[1]), "title": "Inner"])["id"].string!
    #expect(h.tabs("move", ["id": .string(inner), "folderId": .string(outer)]) == ["ok": true])
    #expect(h.tabs("move", ["id": .string(u), "folderId": .string(inner)]) == ["ok": true])
    let tree = h.tabs("list", ["spaceId": .string(spaces[1])])["pinned"].array!.first { $0.s("id") == outer }!
    #expect(tree["children"][0]["id"].string == inner)
    #expect(tree["children"][0]["children"][0]["id"].string == u)
    #expect(h.tabs("move", ["id": .string(outer), "folderId": .string(inner)]).isError)
    // Deleting the folder archives the tabs inside it.
    #expect(h.tabs("deleteFolder", ["id": .string(outer)]) == ["ok": true])
    #expect(h.tabs("archive")[0]["id"].string == u)
    #expect(!h.ids("pinned", spaces[1]).contains(outer))
  }

  @Test func dragReorderAcrossSections() {
    let h = Harness()
    h.startTabs()
    let today = h.ids("today"), pinned = h.ids("pinned")
    // Drag the last today tab above the first pinned tab: it becomes pinned.
    h.action(today[3], "reorder", ["source": .string(today[3]), "target": .string(pinned[0]), "position": "before"])
    #expect(h.ids("pinned").first == today[3])
    #expect(h.tabs("list")["pinned"][0]["kind"] == "pinned")
    // Drop it into the Reading folder.
    h.action(today[3], "reorder", ["source": .string(today[3]), "target": .string(pinned[2]), "position": "into"])
    #expect(h.tabs("list")["pinned"].array!.last!["children"].array!.last!["id"].string == today[3])
    // Reorder within today.
    h.action(today[0], "reorder", ["source": .string(today[0]), "target": .string(today[2]), "position": "after"])
    #expect(h.ids("today") == [today[1], today[2], today[0]])
    // Favorites reorder among tiles.
    let favs = h.ids("favorites")
    h.action(favs[0], "reorder", ["source": .string(favs[0]), "target": .string(favs[3]), "position": "after"])
    #expect(h.ids("favorites") == [favs[1], favs[2], favs[3], favs[0]])
    h.key("ctrl+z")
    #expect(h.ids("favorites") == favs)
  }

  @Test func renameDuplicateNavigate() {
    let h = Harness()
    h.startTabs()
    let t = h.ids("today")[0]
    h.tabs("rename", ["id": .string(t), "title": "My Wiki"])
    #expect(h.tabs("list")["today"][0]["title"] == "My Wiki")
    #expect(h.tree("sidebar.today", 0)["children"][2]["title"] == "My Wiki")
    h.tabs("rename", ["id": .string(t), "title": ""])
    #expect(h.tabs("list")["today"][0]["customTitle"] == .null)
    let d = h.tabs("duplicate", ["id": .string(t)])["id"].string!
    #expect(h.ids("today")[1] == d)
    #expect(h.selected == d)
    #expect(h.tabs("navigate", ["url": "example.net"]) == ["ok": true])
    #expect(h.tabs("list")["today"][1]["url"] == "https://example.net/")
  }

  /// Inline rename through the real sidebar row: double-click or the context menu opens the
  /// editor, Return commits, Esc cancels, an empty title resets to the page's.
  @Test func inlineRenameInTheSidebar() async throws {
    let h = Harness()
    h.startTabs()
    let t = h.ids("today")[0]
    // The seeded tab is a live site (apple.com): if it loads mid-test, its title becomes whatever the
    // site says now. "The page title" is the seeded one or, once loaded, the live one.
    let seededTitle = h.tabs("list")["today"][0]["title"].string!
    func isPageTitle(_ s: String?) -> Bool {
      let live = h.rt.webviews.record(t)?.title ?? ""
      return s == seededTitle || (!live.isEmpty && s == live)
    }
    func row() -> TabRowNode? { HostScenarios.find(t, in: h.rt.ui.sidebarView) as? TabRowNode }
    func editor() async throws -> InlineTitleEditor {
      _ = await Wait.until("the inline title editor") { row()?.rename.editor?.currentEditor() != nil }
      if let e = row()?.rename.editor, e.currentEditor() != nil { return e }
      throw CancellationError()
    }
    func type(_ text: String, _ command: Selector) async throws {
      let e = try await editor()
      let fieldEditor = try #require(e.currentEditor() as? NSTextView)
      fieldEditor.selectAll(nil)
      fieldEditor.insertText(text, replacementRange: fieldEditor.selectedRange())
      fieldEditor.doCommand(by: command)
    }
    let ret = #selector(NSResponder.insertNewline(_:)), esc = #selector(NSResponder.cancelOperation(_:))

    h.action(t, "doubleClick")
    #expect(h.tree("sidebar.today", 0)["children"][2]["editing"] == true)
    let shown = try await editor().stringValue
    #expect(isPageTitle(shown), "\(shown)")
    #expect(row()?.label.isHidden == true)
    try await type("Reading list", ret)
    #expect(h.tabs("list")["today"][0]["title"] == "Reading list")
    #expect(h.tree("sidebar.today", 0)["children"][2]["editing"] == .null)
    #expect(row()?.rename.editor == nil && row()?.label.stringValue == "Reading list")

    // Context menu > Rename…, then Esc keeps the title.
    #expect(h.tabs("menu", ["id": .string(t)]).array?.contains { $0["id"] == "rename" } == true)
    h.action(t, "menu", "rename")
    try await type("Something else", esc)
    #expect(h.tabs("list")["today"][0]["title"] == "Reading list")
    #expect(row()?.rename.editor == nil)

    // Empty resets to the page title; Ctrl-Z brings the custom one back.
    h.action(t, "doubleClick")
    try await type("", ret)
    #expect(h.tabs("list")["today"][0]["customTitle"] == .null)
    #expect(isPageTitle(h.tabs("list")["today"][0]["title"].string))
    h.key("ctrl+z")
    #expect(h.tabs("list")["today"][0]["title"] == "Reading list")

    // Folders: Rename Folder… from their menu.
    let folder = h.tabs("list")["pinned"].array!.first { $0["folder"] == true }!["id"].string!
    h.action(folder, "menu", "renameFolder")
    #expect(h.tree("sidebar.pinned", 0)["children"].array!.first { $0["id"].string == folder }?["editing"] == true)
    let header = try #require((HostScenarios.find(folder, in: h.rt.ui.sidebarView) as? FolderNode)?.header)
    _ = await Wait.until("header.rename.editor?.currentEditor() == nil") { !(header.rename.editor?.currentEditor() == nil) }
    let fe = try #require(header.rename.editor?.currentEditor() as? NSTextView)
    fe.selectAll(nil)
    fe.insertText("Docs", replacementRange: fe.selectedRange())
    fe.doCommand(by: ret)
    #expect(h.tabs("list")["pinned"].array!.first { $0["id"].string == folder }?["title"] == "Docs")
  }

  /// Dragging a tab row onto another space's footer icon highlights it and moves the tab there,
  /// through the real drag controller.
  @Test func dragTabOntoSpaceIcon() throws {
    let h = Harness()
    h.startTabs()
    let w = h.rt.window.window
    w.orderFront(nil)
    w.contentView?.layoutSubtreeIfNeeded()
    h.rt.ui.sidebarView.layoutSubtreeIfNeeded()
    let (s0, s1) = (h.spaceIds[0], h.spaceIds[1])
    let t = h.ids("today", s0)[1]
    let row = try #require(HostScenarios.find(t, in: h.rt.ui.sidebarView) as? TabRowNode)
    let icon = try #require(HostScenarios.find("spaces.icon:" + s1, in: h.rt.ui.sidebarView) as? SpaceIconNode)
    icon.superview?.layoutSubtreeIfNeeded()
    func ev(_ type: NSEvent.EventType, _ v: NSView) -> NSEvent {
      let p = v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
      return NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    let drag = h.rt.ui.drag
    drag.begin(row, event: ev(.leftMouseDown, row))
    drag.move(ev(.leftMouseDragged, icon))
    #expect(icon.dropTarget)
    #expect(drag.spaceTarget === icon)
    drag.end(ev(.leftMouseUp, icon))
    #expect(!icon.dropTarget)
    #expect(!h.ids("today", s0).contains(t))
    #expect(h.ids("today", s1).first == t)
    // A pinned tab stays pinned; ctrl-z undoes.
    let p = h.ids("pinned", s0)[0]
    let prow = try #require(HostScenarios.find(p, in: h.rt.ui.sidebarView) as? TabRowNode)
    drag.begin(prow, event: ev(.leftMouseDown, prow))
    drag.move(ev(.leftMouseDragged, icon))
    drag.end(ev(.leftMouseUp, icon))
    #expect(h.ids("pinned", s1).last == p)
    h.key("ctrl+z")
    #expect(h.ids("pinned", s0).first == p)
    // Dropping on the current space's icon changes nothing.
    let own = try #require(HostScenarios.find("spaces.icon:" + s0, in: h.rt.ui.sidebarView) as? SpaceIconNode)
    let before = h.ids("today", s0)
    let r0 = try #require(HostScenarios.find(before[0], in: h.rt.ui.sidebarView) as? TabRowNode)
    drag.begin(r0, event: ev(.leftMouseDown, r0))
    drag.move(ev(.leftMouseDragged, own))
    drag.end(ev(.leftMouseUp, own))
    #expect(h.ids("today", s0) == before)
  }

  @Test func autoArchiveAndSuspension() async {
    let h = Harness()
    let core = h.startTabs()
    let today = h.ids("today")
    h.tabs("select", ["id": .string(today[1])])
    h.tabs("select", ["id": .string(today[0])])
    #expect(h.rt.call("webviews", "get", ["id": .string(today[1])])["live"] == true)
    // The page that left the screen waits in the window while its snapshot is taken.
    _ = await Wait.until("h.rt.webviews.record(today[1])?.webView?.window != nil") { !(h.rt.webviews.record(today[1])?.webView?.window != nil) }
    // Idle discard (default 5 min of den-frontmost time) spares the most recently used tabs:
    // this one was just used, so it stays (GroupTests.idleDiscard… covers the discard itself).
    h.rt.plugins.emit("app.active", ["active": true])
    h.clock += 6 * 60_000
    core.tick()
    #expect(h.rt.call("webviews", "get", ["id": .string(today[1])])["live"] == true)
    #expect(h.rt.call("webviews", "get", ["id": .string(today[0])])["live"] == true)
    // 25 hours idle (the default is 24 h, docs/defaults.md): every today tab but the selected one is archived, with a toast.
    h.clock += 25 * 3_600_000
    h.fireTimers()
    #expect(h.ids("today") == [today[0]])
    #expect(h.tabs("archive").array?.filter { $0.s("spaceId") == h.spaceIds[0] }.count == 3)
    #expect(h.rt.ui.toasts.count == 1)
    // Configurable, and 0 turns it off.
    #expect(h.tabs("settings", ["archiveAfterMs": 0])["archiveAfterMs"] == 0)
    h.tabs("open", ["url": "https://example.com", "background": true])
    h.clock += 48 * 3_600_000
    core.tick()
    #expect(h.ids("today").count == 2)
    #expect(h.storage("tabs", "settings")["archiveAfterMs"] == 0)
  }

  @Test func speakerMutesTheTab() async throws {
    let h = Harness()
    let core = h.startTabs()
    let id = h.ids("today")[0]
    h.tabs("select", ["id": .string(id)])
    // A page playing audio: the row shows the speaker.
    h.rt.plugins.emit("webviews.audio", ["id": .string(id), "playing": true])
    var row = h.tree("sidebar.today", 0)["children"].array?.first { $0.s("id") == id } ?? .null
    #expect(row["audio"] == true && row["muted"] != true)
    #expect(h.tabs("menu", ["id": .string(id)]).array?.contains { $0.s("id") == "mute" } == true)
    // Clicking the speaker mutes the page through the host; the row and menu follow.
    h.action(id, "mute")
    #expect(h.rt.call("webviews", "get", ["id": .string(id)])["muted"] == true)
    #expect(h.rt.webviews.pageMuted(id) == true)
    row = h.tree("sidebar.today", 0)["children"].array?.first { $0.s("id") == id } ?? .null
    #expect(row["muted"] == true && h.tabs("menu", ["id": .string(id)]).array?.contains { $0.s("id") == "unmute" } == true)
    #expect(core.tabValue(id)["muted"] == true)
    // The menu item unmutes.
    h.action(id, "menu", "unmute")
    #expect(h.rt.call("webviews", "get", ["id": .string(id)])["muted"] == false)
    // A favorite tile carries the same state.
    let fav = h.ids("favorites")[0]
    h.rt.plugins.emit("webviews.audio", ["id": .string(fav), "playing": true])
    h.action(fav, "mute")
    let tile = h.tree("sidebar.favorites", 0)["children"].array?.first { $0.s("id") == fav } ?? .null
    #expect(tile["audio"] == true && tile["muted"] == true)
  }

  /// Arc (Jan 2024): dropping a tab onto the middle of another makes a split of the two.
  @Test func dropOntoATabMakesASplit() {
    // Row geometry: the middle half is "into" for rows that take it, the edges reorder.
    #expect(DragController.position(rel: 0.1, into: true) == "before")
    #expect(DragController.position(rel: 0.3, into: true) == "into")
    #expect(DragController.position(rel: 0.7, into: true) == "into")
    #expect(DragController.position(rel: 0.9, into: true) == "after")
    #expect(DragController.position(rel: 0.4, into: false) == "before")
    #expect(DragController.position(rel: 0.6, into: false) == "after")
    let h = Harness()
    h.startTabs()
    let s0 = h.spaceIds[0]
    let today = h.ids("today", s0)
    let row = h.tree("sidebar.today", 0)["children"].array?.first { $0.s("id") == today[1] } ?? .null
    #expect(row["dropInto"] == true && row["dropIntoIcon"] == "sf:rectangle.split.2x1")
    // A tab onto itself: nothing.
    h.action(today[1], "reorder", ["source": .string(today[1]), "target": .string(today[1]), "position": "into"])
    #expect(h.ids("today", s0) == today)
    // today[2] onto today[0]: one split where today[0] was, today[2] on the right and selected.
    h.action(today[2], "reorder", ["source": .string(today[2]), "target": .string(today[0]), "position": "into"])
    let items = h.tabs("list", ["spaceId": .string(s0)])["today"].array ?? []
    #expect(items.count == today.count - 1)
    #expect(items[0]["split"] == true && items[0]["children"].array?.map { $0.s("id") } == [today[0], today[2]])
    #expect(h.selected == today[2])
    #expect(h.rt.call("content", "get")["panes"] == [.string(today[0]), .string(today[2])])
    // Undo puts both tabs back.
    h.key("ctrl+z")
    #expect(h.ids("today", s0) == today)
    // Pinned onto pinned: the split stays in pinned; a favorite onto a favorite stays in favorites.
    let pinned = h.ids("pinned", s0).filter { !$0.hasPrefix("folder-") }
    h.action(pinned[1], "reorder", ["source": .string(pinned[1]), "target": .string(pinned[0]), "position": "into"])
    #expect(h.tabs("list", ["spaceId": .string(s0)])["pinned"].array?.first?["split"] == true)
    let favs = h.ids("favorites")
    h.action(favs[1], "reorder", ["source": .string(favs[1]), "target": .string(favs[0]), "position": "into"])
    let fav0 = h.tabs("list")["favorites"].array?.first ?? .null
    #expect(fav0["split"] == true && fav0["children"].array?.map { $0.s("id") } == [favs[0], favs[1]])
    // A today tab onto a pinned tab joins the pinned side (it takes the pinned kind).
    h.action(today[3], "reorder", ["source": .string(today[3]), "target": .string(pinned.count > 2 ? pinned[2] : favs[2]), "position": "into"])
    #expect(!h.ids("today", s0).contains(today[3]))
    // A split dropped onto a tab takes the tab in.
    let sp = h.tabs("list", ["spaceId": .string(s0)])["pinned"].array?.first?.s("id") ?? ""
    h.action(sp, "reorder", ["source": .string(sp), "target": .string(today[1]), "position": "into"])
    #expect(!h.ids("today", s0).contains(today[1]))
  }

  /// Dragging the gap between split panes resizes them live; the split keeps the sizes (a tab
  /// switch and back, a relaunch), a double-click makes them equal again, and a new pane resets them.
  @Test func dragTheGapToResizeASplit() throws {
    let h = Harness()
    let core = h.startTabs()
    let s0 = h.spaceIds[0]
    let today = h.ids("today", s0)
    h.action(today[2], "reorder", ["source": .string(today[2]), "target": .string(today[0]), "position": "into"])
    let wc = h.rt.content.current
    #expect(wc.panes == [today[0], today[2]])
    let d = try #require(wc.dividers.first)
    #expect(wc.dividers.count == 1 && d.alongX && d.superview === h.rt.window.contentArea)
    // Above both cards, so the gap takes the drag.
    let area = h.rt.window.contentArea
    let cardIndex = area.subviews.lastIndex { $0 is CardView } ?? -1
    #expect((area.subviews.firstIndex(of: d) ?? -1) > cardIndex)
    let left = try #require(wc.cards[today[0]]), right = try #require(wc.cards[today[2]])
    let total = left.frame.width + right.frame.width
    let x = left.frame.minX + 300 + Tokens.splitGap / 2
    let drag = try #require(NSEvent.mouseEvent(with: .leftMouseDragged, location: area.convert(NSPoint(x: x, y: 100), to: nil), modifierFlags: [], timestamp: 0,
                                               windowNumber: h.rt.window.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    h.record(["content.ratios"])
    var queue = [drag]
    d.track(next: { _ in queue.isEmpty ? nil : queue.removeFirst() }, buttonDown: { false })
    #expect(left.frame.width == 300 && left.frame.width + right.frame.width == total)
    #expect(h.events.filter { $0.0 == "content.ratios" }.count == 1)
    // The split keeps it: switch away and back.
    h.tabs("select", ["id": .string(today[1])])
    h.tabs("select", ["id": .string(today[2])])
    #expect(h.rt.content.current.cards[today[0]]?.frame.width == 300)
    // And across a relaunch (plugin storage).
    core.save()
    let state = h.storage("tabs", "state")
    let saved = state["splits"].array?.first { $0["children"] == [.string(today[0]), .string(today[2])] } ?? .null
    #expect(saved["ratios"].array?.count == 2)
    // Double-click: equal again.
    let dbl = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: h.rt.window.window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
    d.mouseDown(with: dbl)
    #expect(abs(left.frame.width - right.frame.width) <= 1)
    h.tabs("select", ["id": .string(today[1])])
    h.tabs("select", ["id": .string(today[0])])
    let l2 = try #require(h.rt.content.current.cards[today[0]]), r2 = try #require(h.rt.content.current.cards[today[2]])
    #expect(abs(l2.frame.width - r2.frame.width) <= 1)
  }

  @Test func pipReturnButtonSelectsTheTab() {
    let h = Harness()
    h.startTabs()
    let id = h.ids("today")[2]
    h.rt.plugins.emit("media.backToTab", ["webview": .string(id)])
    #expect(h.selected == id)
  }

  @Test func shortcutsNavigateTabs() {
    let h = Harness()
    h.startTabs()
    let order = h.ids("favorites") + ["pinned0", "pinned1", "reading"] + h.ids("today")
    _ = order
    let favs = h.ids("favorites")
    h.key("cmd+1")
    #expect(h.selected == favs[0])
    h.key("cmd+9")
    #expect(h.selected == h.ids("today").last)
    h.key("cmd+opt+up")
    #expect(h.selected == h.ids("today")[2])
    h.key("ctrl+tab")
    #expect(h.selected == h.ids("today").last)
    let chords = Set((h.rt.call("keys", "list").array ?? []).map { $0.s("chord") })
    for c in ["cmd+w", "cmd+shift+t", "cmd+d", "cmd+shift+k", "cmd+1", "cmd+9", "ctrl+tab", "cmd+opt+up", "cmd+opt+down", "cmd+[", "cmd+]"] {
      #expect(chords.contains(c))
    }
  }

  @Test func spacesDriveTheSelectedTab() {
    let h = Harness()
    h.startTabs()
    let spaces = h.spaceIds
    let workToday = h.ids("today", spaces[1])
    h.key("ctrl+2")
    #expect(h.selected == workToday[0])
    #expect(h.rt.call("content", "get")["panes"] == [.string(workToday[0])])
    // Selecting a tab from another space switches to that space.
    let personal = h.ids("today", spaces[0])[2]
    h.tabs("select", ["id": .string(personal)])
    #expect(h.rt.call("spaces", "current")["id"].string == spaces[0])
    #expect(h.rt.call("ui", "get")["page"] == 0)
    // Deleting a space archives everything in it.
    #expect(h.rt.call("spaces", "delete", ["id": .string(spaces[2])]) == ["ok": true])
    #expect(h.tabs("archive").array?.contains { $0.s("spaceId") == spaces[2] } == true)
  }

  @Test func stateSurvivesRestart() {
    let h = Harness()
    let core = h.startTabs()
    let id = h.tabs("open", ["url": "https://www.swift.org/documentation/"])["id"].string!
    h.tabs("rename", ["id": .string(id), "title": "Swift Docs"])
    core.stop()
    let before = h.tabs("list")
    let h2 = Harness(root: h.root)
    h2.startTabs()
    #expect(h2.tabs("list") == before)
    #expect(h2.selected == id)
  }
}
