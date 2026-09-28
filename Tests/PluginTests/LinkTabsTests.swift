import AppKit
import CordisValue
import DenTestSupport
import Testing

@testable import DenHost
@testable import PluginCores

/// How the tabs plugin opens links the host hands it: ⌘-/middle-click (background), ⌘⇧-click and
/// target=_blank (selected), and links or files dropped on the sidebar or a page.
@MainActor
@Suite(.serialized, .watchdog)
struct LinkTabsTests {
  @Test func newWindowHonoursBackground() {
    let h = Harness()
    h.startTabs()
    // With "Group ⌘-clicked links" off: Arc's plain background tab at the top of Today.
    h.tabs("settings", ["groupLinks": false])
    let sel = h.selected!
    h.rt.plugins.emit("webviews.newWindow", ["id": .string(sel), "url": "https://a.test/bg", "background": true])
    let bg = h.tabs("list")["today"][0]
    #expect(bg["url"] == "https://a.test/bg")
    #expect(h.selected == sel)  // stayed on the current tab
    h.rt.plugins.emit("webviews.newWindow", ["id": .string(sel), "url": "https://a.test/fg"])
    #expect(h.tabs("list")["today"][0]["url"] == "https://a.test/fg")
    #expect(h.selected == h.tabs("list")["today"][0]["id"].string)
    // target=_blank (no `background`) never groups, even with the setting on.
    h.tabs("settings", ["groupLinks": true])
    let fg = h.selected!
    h.rt.plugins.emit("webviews.newWindow", ["id": .string(fg), "url": "https://a.test/blank"])
    #expect(h.tabs("list")["today"][0]["url"] == "https://a.test/blank")
    #expect(h.tabs("list")["today"].array?.contains { $0["folder"] == true } == false)
  }

  @Test func droppedURLsOpenAsTodayTabsLastSelected() {
    let h = Harness()
    h.startTabs()
    h.rt.plugins.emit("window.dropURLs", ["urls": ["https://a.test/1", "https://a.test/2"], "target": "sidebar"])
    let today = h.tabs("list")["today"].array ?? []
    #expect(today.prefix(2).map { $0.s("url") } == ["https://a.test/2", "https://a.test/1"])
    #expect(h.selected == today[0]["id"].string)
  }
}
