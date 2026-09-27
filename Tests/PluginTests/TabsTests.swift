import AppKit
import CordisValue
import Testing

@testable import DenHost
@testable import PluginCores

@MainActor
@Suite(.serialized)
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
    #expect(h.tree("sidebar.pinned", 0)["children"][0]["drift"] == false)
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
    let pageTitle = h.tabs("list")["today"][0]["title"].string!
    func row() -> TabRowNode? { HostScenarios.find(t, in: h.rt.ui.sidebarView) as? TabRowNode }
    func editor() async throws -> InlineTitleEditor {
      for _ in 0..<20 {
        if let e = row()?.rename.editor, e.currentEditor() != nil { return e }
        try await Task.sleep(for: .milliseconds(20))
      }
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
    #expect(try await editor().stringValue == pageTitle)
    #expect(row()?.label.isHidden == true)
    try await type("Reading list", ret)
    #expect(h.tabs("list")["today"][0]["title"] == "Reading list")
    #expect(h.tree("sidebar.today", 0)["children"][2]["editing"] == .null)
    #expect(row()?.rename.editor == nil && row()?.label.stringValue == "Reading list")

    // Context menu > Rename…, then Esc keeps the title.
    #expect(h.tree("sidebar.today", 0)["children"][2]["menu"].array?.contains { $0["id"] == "rename" } == true)
    h.action(t, "menu", "rename")
    try await type("Something else", esc)
    #expect(h.tabs("list")["today"][0]["title"] == "Reading list")
    #expect(row()?.rename.editor == nil)

    // Empty resets to the page title; Ctrl-Z brings the custom one back.
    h.action(t, "doubleClick")
    try await type("", ret)
    #expect(h.tabs("list")["today"][0]["customTitle"] == .null)
    #expect(h.tabs("list")["today"][0]["title"].string == pageTitle)
    h.key("ctrl+z")
    #expect(h.tabs("list")["today"][0]["title"] == "Reading list")

    // Folders: Rename Folder… from their menu.
    let folder = h.tabs("list")["pinned"].array!.first { $0["folder"] == true }!["id"].string!
    h.action(folder, "menu", "renameFolder")
    #expect(h.tree("sidebar.pinned", 0)["children"].array!.first { $0["id"].string == folder }?["editing"] == true)
    let header = try #require((HostScenarios.find(folder, in: h.rt.ui.sidebarView) as? FolderNode)?.header)
    for _ in 0..<20 where header.rename.editor?.currentEditor() == nil { try await Task.sleep(for: .milliseconds(20)) }
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
    // 31 minutes idle: the background tab is suspended, the visible one is not.
    h.clock += 31 * 60_000
    core.tick()
    #expect(await h.waitUnloaded(today[1]))
    #expect(h.rt.call("webviews", "get", ["id": .string(today[0])])["live"] == true)
    // 13 hours idle: every today tab but the selected one is archived, with a toast.
    h.clock += 13 * 3_600_000
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
