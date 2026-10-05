import AppKit
import CordisValue
import DenTestSupport
import Testing

@testable import DenHost
@testable import PluginCores

/// The tabs plugin with several windows (TabsWindows.swift): every window shows the same spaces
/// and tabs and keeps its own place, a tab shows in one window at a time unless the setting says
/// otherwise, private windows keep nothing, closed windows reopen and open windows come back.
@MainActor
@Suite(.serialized, .watchdog)
struct WindowTabsTests {
  func rowSelected(_ h: Harness, window: String, _ id: String) -> Bool? {
    let tree = h.rt.ui.sidebar(of: window)?.slot("sidebar.today", page: 0)?.root?.node ?? .null
    return tree["children"].array?.first { $0["id"].string == id }.map { $0["selected"].bool ?? false }  // left out when false
  }

  @Test func eachWindowKeepsItsOwnPlace() {
    let h = Harness()
    let core = h.startTabs()
    let today = h.ids("today")
    let a = h.selected!
    let b = today.first { $0 != a }!
    #expect(h.rt.call("window", "new")["id"] == "w2")
    // A new window is on the same space, shows nothing yet, and highlights nothing.
    #expect(h.selected == nil)
    #expect(h.rt.call("content", "get")["panes"] == [])
    #expect(rowSelected(h, window: "w2", a) == false)
    #expect(rowSelected(h, window: "w1", a) == true)
    // Picking a tab there shows it there only.
    h.tabs("select", ["id": .string(b)])
    #expect(h.selected == b)
    #expect(h.rt.call("content", "get", ["window": "w2"])["panes"] == [.string(b)])
    #expect(h.rt.call("content", "get", ["window": "w1"])["panes"] == [.string(a)])
    #expect(rowSelected(h, window: "w2", b) == true)
    #expect(rowSelected(h, window: "w1", a) == true && rowSelected(h, window: "w1", b) == false)
    // Back to the first window: its tab is the selected one again, nothing reloaded or moved.
    h.rt.call("window", "focus", ["id": "w1"])
    #expect(h.selected == a)
    #expect(h.rt.call("content", "get", ["window": "w2"])["panes"] == [.string(b)])
    #expect(core.places["w2"]?.tab == b)
    // Closing a tab a background window shows leaves that window empty.
    h.tabs("close", ["id": .string(b)])
    #expect(h.rt.call("content", "get", ["window": "w2"])["panes"] == [])
    #expect(core.places["w2"]?.tab == nil)
  }

  @Test func aTabShownInAnotherWindowBringsThatWindowForward() {
    let h = Harness()
    h.startTabs()
    let a = h.selected!
    h.rt.call("window", "new")
    #expect(h.rt.window.id == "w2")
    h.tabs("select", ["id": .string(a)])
    // Off by default: den goes to the window that has it, and the new window stays empty.
    #expect(h.rt.window.id == "w1")
    #expect(h.selected == a)
    #expect(h.rt.call("content", "get", ["window": "w2"])["panes"] == [])
  }

  @Test func sameTabInTwoWindowsMovesTheTab() throws {
    let h = Harness()
    h.startTabs()
    h.rt.call("settings", "set", ["id": "tabs", "key": "sameTabInWindows", "value": true])
    let a = h.selected!
    let web = try #require(h.rt.webviews.record(a)?.webView)
    h.rt.call("window", "new")
    h.tabs("select", ["id": .string(a)])
    #expect(h.rt.window.id == "w2")
    #expect(h.rt.call("content", "get", ["window": "w2"])["panes"] == [.string(a)])
    #expect(web.window === h.rt.windows.find("w2")?.window)
    #expect(h.rt.content.content(of: "w1")?.cards[a]?.clip.subviews.contains { $0 is ElsewhereView } == true)
    // Clicking back into the first window takes the tab back (one web view, never two).
    h.rt.call("window", "focus", ["id": "w1"])
    #expect(web.window === h.rt.windows.main.window)
    #expect(h.selected == a)
  }

  @Test func privateWindowKeepsNothing() async throws {
    let h = Harness()
    let core = h.startTabs()
    let before = h.tabs("archive").array?.count ?? 0
    let p = h.rt.call("window", "new", ["private": true])["id"].string!
    let id = h.tabs("open", ["url": "https://example.com/secret"])["id"].string!
    #expect(id.hasPrefix("ptab-"))
    #expect(h.rt.call("webviews", "get", ["id": .string(id)])["profile"] == .string("private:" + p))
    #expect(h.rt.call("content", "get", ["window": .string(p)])["panes"] == [.string(id)])
    #expect(h.tabs("selected")["id"].string == id)
    // Not a normal tab: not listed, not in the saved state.
    #expect(!h.ids("today").contains(id))
    core.save()
    let state = h.storage("tabs", "state")
    let saved = (state["tabs"].array ?? []) + (state["archive"].array ?? [])
    #expect(!saved.isEmpty)
    #expect(!saved.contains { $0["id"].string == id || ($0["url"].string ?? "").contains("secret") })
    // Its sidebar lists it; the spaces' sidebars don't.
    let list = h.rt.ui.sidebar(of: p)?.slot("sidebar.today", page: 0)?.root?.node ?? .null
    #expect(list["children"].array?.contains { $0["id"].string == id } == true)
    #expect(rowSelected(h, window: "w1", id) == nil)
    // A second private tab, then ⌘W: closed for good (no archive, no reopen).
    let id2 = h.tabs("open", ["url": "https://example.org/"])["id"].string!
    #expect(h.tabs("selected")["id"].string == id2)
    h.key("cmd+w")
    #expect(h.tabs("selected")["id"].string == id)
    #expect(h.rt.call("webviews", "get", ["id": .string(id2)]).isError)
    #expect((h.tabs("archive").array?.count ?? 0) == before)
    // Closing the window closes its tabs.
    h.rt.call("window", "close", ["id": .string(p)])
    #expect(h.rt.call("webviews", "get", ["id": .string(id)]).isError)
    #expect(core.privates.isEmpty && core.ptabs.isEmpty)
    #expect(h.rt.window.id == "w1")
  }

  @Test func reopenClosedWindowBringsItsTabBack() {
    let h = Harness()
    let core = h.startTabs()
    let a = h.selected!
    let b = h.ids("today").first { $0 != a }!
    h.rt.call("window", "new")
    h.tabs("select", ["id": .string(b)])
    h.rt.call("window", "close", ["id": "w2"])
    #expect(h.rt.window.id == "w1")
    #expect(h.tabs("closedWindows")["count"] == 1)
    #expect(core.places.isEmpty)
    // ⇧⌘T right after a window close reopens the window, on its tab.
    h.key("cmd+shift+t")
    #expect(h.rt.call("window", "get")["count"] == 2)
    #expect(h.selected == b)
    #expect(h.rt.call("content", "get")["panes"] == [.string(b)])
    #expect(h.tabs("closedWindows")["count"] == 0)
    // The next ⇧⌘T is about tabs again.
    #expect(!core.lastClosedWasWindow)
  }

  @Test func windowsComeBackAfterARelaunch() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("den-windows-\(UUID())")
    var b = ""
    do {
      let h = Harness(root: root)
      let core = h.startTabs()
      let a = h.selected!
      b = h.ids("today").first { $0 != a }!
      h.rt.call("window", "new")
      h.tabs("select", ["id": .string(b)])
      h.rt.call("window", "focus", ["id": "w1"])
      core.save()
      #expect(h.storage("tabs", "state")["windows"].array?.count == 2)
      h.rt.tearDown()
    }
    let h2 = Harness(root: root)
    h2.startTabs()
    #expect(h2.rt.call("window", "get")["count"] == 2)
    #expect(h2.rt.window.id == "w1")
    #expect(h2.rt.call("content", "get", ["window": "w2"])["panes"] == [.string(b)])
  }

  /// One window: nothing about windows is saved, and renders address no window.
  @Test func oneWindowSavesNoWindows() {
    let h = Harness()
    let core = h.startTabs()
    core.save()
    #expect(h.storage("tabs", "state")["windows"].isNull)
    #expect(core.places.isEmpty)
  }
}
