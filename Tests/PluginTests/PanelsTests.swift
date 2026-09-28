import AppKit
import CordisValue
import DenTestSupport
import Foundation
import Testing

@testable import DenHost
@testable import PluginCores

/// The `panels` plugin: web panels in the side column, on a local page (MockServices).
@MainActor
@Suite(.serialized, .watchdog)
struct PanelsTests {
  static func served() throws -> MockServices {
    let mock = MockServices()
    try mock.start()
    mock.files = [
      "/chat.html": ("text/html", Data("<title>Team Chat</title><p>hi</p>".utf8)),
      "/docs.html": ("text/html", Data("<title>Docs</title><p>docs</p>".utf8)),
    ]
    return mock
  }

  func start(_ h: Harness) -> PanelsCore {
    let core = PanelsCore(env: h.env)
    core.start()
    return core
  }

  @Test func addressesAreNormalized() {
    #expect(PanelsCore.normalize("claude.ai") == "https://claude.ai")
    #expect(PanelsCore.normalize("  https://gemini.google.com/app ") == "https://gemini.google.com/app")
    #expect(PanelsCore.normalize("hello world") == "")
    #expect(PanelsCore.normalize("notes") == "")
    #expect(PanelsCore.normalize("ftp://x.org") == "")
  }

  @Test func addShowSwitchHideAndSleep() async throws {
    let h = Harness()
    let mock = try Self.served()
    let core = start(h)
    #expect(h.rt.content.sideId == nil && core.panels.isEmpty)
    // Settings ▸ Web Panels: the add field.
    h.rt.plugins.emit("settings.action", ["id": "panels", "key": "add", "value": .string(mock.base + "/chat.html")])
    let first = try #require(core.panels.first?.id)
    #expect(first == "panel-1" && core.open == first && h.rt.content.sideId == first)
    #expect(h.rt.webviews.record(first)?.userAgent == nil, "desktop user agent unless Phone Layout is on")
    let web = try #require(h.rt.webviews.record(first)?.webView)
    #expect(web.superview === h.rt.content.sideIfLoaded?.card.clip)
    #expect(await Wait.until("the panel's title") { core.panels.first?.title == "Team Chat" })
    // Header: a switch button per panel, add and options menus, hide with its shortcut.
    let header = try #require(h.rt.content.sideIfLoaded?.header.root?.node)
    let ids = header.list("children").map { $0.str("id") }
    #expect(ids.contains("panels.switch:" + first) && ids.contains("panels.add") && ids.contains("panels.more") && ids.contains("panels.hide"))
    #expect(header.list("children").first { $0.str("id") == "panels.hide" }?.str("shortcut") == "ctrl+cmd+s")
    // Saved, and listed in Settings.
    #expect(h.storage("panels", "list").array?.first?.str("url") == mock.base + "/chat.html")
    #expect(h.storage("panels", "state")["open"] == true)

    // A second panel; switching puts the first one to sleep after the grace.
    let second = try #require(core.add(mock.base + "/docs.html"))
    #expect(core.open == second && h.rt.content.sideId == second && web.superview == nil)
    h.fireTimers()
    #expect(await h.waitUnloaded(first), "the hidden panel was discarded")
    // ⌃⌘S hides; the sleep timer for the shown one is dropped if it's shown again in time.
    h.timers.removeAll()
    h.key("ctrl+cmd+s")
    #expect(core.open == nil && h.rt.content.sideId == nil)
    h.key("ctrl+cmd+s")
    #expect(core.open == second && h.rt.content.sideId == second)
    h.fireTimers()
    #expect(h.rt.webviews.record(second)?.webView != nil, "shown again before the grace ended: not discarded")
    // Switching back wakes the first one from its snapshot state.
    h.action("panels.switch:" + first, "click")
    #expect(core.open == first && h.rt.webviews.record(first)?.webView != nil)
    // Phone layout recreates the page with Safari's iPhone user agent.
    h.action("panels.more", "menu", "mobile")
    #expect(h.rt.webviews.record(first)?.userAgent == WebViewsService.mobileUserAgent && h.rt.content.sideId == first)
    #expect(core.panels.first?.mobile == true)
    // Remove.
    h.action("panels.more", "menu", "remove")
    #expect(core.panels.map(\.id) == [second] && core.open == nil && h.rt.webviews.record(first) == nil)
    core.stop()
    #expect(h.rt.webviews.record(second) == nil && h.rt.content.sideId == nil)
    mock.stop()
  }

  @Test func addingTheCurrentTab() async throws {
    let h = Harness()
    let mock = try Self.served()
    h.startTabs()
    let core = start(h)
    // The selected tab's page as a panel.
    let tab = h.tabs("open", ["url": .string(mock.base + "/docs.html")])["id"].string!
    _ = h.tabs("select", ["id": .string(tab)])
    #expect(await Wait.until("the tab's url") { h.rt.call("webviews", "get", ["id": .string(tab)]).str("url").hasSuffix("/docs.html") })
    h.rt.plugins.emit("commands.run", ["id": "panels.addTab"])
    #expect(core.panels.count == 1 && core.panels[0].url.hasSuffix("/docs.html") && h.rt.content.sideId == core.panels[0].id)
    #expect(h.rt.call("tabs", "selected")["id"].string == tab, "the tab stays")
    core.stop()
    mock.stop()
  }

  /// The panel open at quit comes back after launch.
  @Test func openPanelComesBack() throws {
    let h = Harness()
    let mock = try Self.served()
    let core = start(h)
    core.add(mock.base + "/chat.html")
    core.stop()
    let h2 = Harness(root: h.root)
    let again = start(h2)
    #expect(again.panels.count == 1 && again.open == nil)
    h2.fireTimers()
    #expect(again.open == "panel-1" && h2.rt.content.sideId == "panel-1")
    again.stop()
    mock.stop()
  }
}
