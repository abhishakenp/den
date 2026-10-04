import AppKit
import CordisValue
import DenTestSupport
import Foundation
import Testing
import WebKit

@testable import DenHost
@testable import PluginCores

/// Pop-ups through the tabs plugin (TabsPopups.swift) on a local fixture: window.open from a click
/// becomes a selected tab right after its opener, keeping `window.opener`; `window.close()` closes
/// it and goes back to the opener; a blocked pop-up shows the pill's "Pop-up blocked" button, whose
/// click opens it. Private windows keep all of it in their own ephemeral profile, Peek included.
@MainActor
@Suite(.serialized, .watchdog)
struct PopupTabsTests {
  static func fixture() throws -> MockServices {
    let mock = MockServices()
    try mock.start()
    let popup = "http://localhost:\(mock.port)/signin"
    mock.page("/opener", """
      <!doctype html><title>Opener</title><script>
      window.got = [];
      addEventListener('message', e => window.got.push(e.data));
      function openPopup() { return window.open('\(popup)') ? 'opened' : 'blocked'; }
      </script>
      """)
    mock.page("/auto", "<!doctype html><title>Auto</title><script>setTimeout(() => window.open('\(popup)'), 30)</script>")
    mock.page("/signin", "<!doctype html><title>Sign in</title><script>if (window.opener) window.opener.postMessage('signed-in', '*')</script>")
    return mock
  }

  static func until(_ seconds: Double = 60, line: UInt = #line, _ cond: () -> Bool) async throws {
    if await !Wait.until("a condition", seconds: seconds, line: line, { cond() }) { Issue.record("timed out waiting at line \(line)") }
  }

  /// A selected tab at `url`, loaded.
  static func tab(_ h: Harness, _ url: String) async throws -> (String, WKWebView) {
    let id = h.tabs("open", ["url": .string(url)])["id"].string!
    let w = try #require(h.rt.webviews.record(id)?.webView)
    try await until { !w.isLoading && w.url?.absoluteString == url }
    return (id, w)
  }

  @Test func clickedWindowOpenIsATabNextToItsOpenerAndClosesBackToIt() async throws {
    let mock = try Self.fixture()
    defer { mock.stop() }
    let h = Harness()
    h.startTabs()
    let (opener, w) = try await Self.tab(h, mock.base + "/opener")
    #expect(await Wait.js(w, "openPopup()") as? String == "opened")
    try await Self.until { h.selected != opener }
    let pop = try #require(h.selected)
    #expect(pop.hasPrefix("tab-o"))
    let today = h.ids("today")
    #expect(today.firstIndex(of: pop) == (today.firstIndex(of: opener) ?? -9) + 1)  // right after its opener
    let pw = try #require(h.rt.webviews.record(pop)?.webView)
    #expect(h.rt.webviews.record(pop)?.opener == opener)
    try await Self.until { pw.url?.host == "localhost" && !pw.isLoading }
    var got: [String] = []
    _ = await Wait.until("the pop-up's message to its opener", seconds: 60, every: .milliseconds(100)) {
      got = await Wait.js(w, "window.got") as? [String] ?? []
      return !got.isEmpty
    }
    #expect(got == ["signed-in"])
    // window.close(): the tab closes and its opener is in front again.
    _ = await Wait.js(pw, "window.close(); 1")
    try await Self.until { !h.ids("today").contains(pop) }
    #expect(h.selected == opener)
  }

  @Test func blockedPopupShowsAPillButtonThatOpensIt() async throws {
    let mock = try Self.fixture()
    defer { mock.stop() }
    let h = Harness()
    let core = h.startTabs()
    let (id, _) = try await Self.tab(h, mock.base + "/auto")
    try await Self.until { core.pillButtons[id]?.contains { $0.0 == TabsCore.popupButton } == true }
    let before = h.ids("today").count
    h.action(TabsCore.popupButton, "click", ["webview": .string(id)])
    try await Self.until { h.ids("today").count == before + 1 }
    #expect(h.rt.call("webviews", "get", ["id": .string(h.selected ?? "")]).s("url").hasSuffix("/signin"))
    #expect(core.pillButtons[id]?.contains { $0.0 == TabsCore.popupButton } != true)
  }

  @Test func privateWindowPopupsAndPeeksStayPrivate() async throws {
    let mock = try Self.fixture()
    defer { mock.stop() }
    let h = Harness()
    h.startPeek()
    let p = h.rt.call("window", "new", ["private": true])["id"].string!
    // Peek from the command bar in an empty private window: that window's profile.
    let peek0 = try #require(h.peek("open", ["url": .string(mock.base + "/signin")])["id"].string)
    #expect(h.rt.webviews.record(peek0)?.profile == "private:" + p)
    h.peek("close")
    let (opener, w) = try await Self.tab(h, mock.base + "/opener")
    #expect(opener.hasPrefix("ptab-"))
    // Peek with no source (the command bar's Shift-Enter): the private tab's profile.
    let peek1 = try #require(h.peek("open", ["url": .string(mock.base + "/signin")])["id"].string)
    #expect(h.rt.webviews.record(peek1)?.profile == "private:" + p)
    h.peek("close")
    // A pop-up from the private tab: a private tab after it, in the same ephemeral store.
    #expect(await Wait.js(w, "openPopup()") as? String == "opened")
    try await Self.until { h.selected != opener }
    let pop = try #require(h.selected)
    let rec = try #require(h.rt.webviews.record(pop))
    #expect(rec.profile == "private:" + p && rec.opener == opener)
    #expect(rec.webView?.configuration.websiteDataStore === h.rt.webviews.store(for: "private:" + p))
    #expect(!h.ids("today").contains(pop))
    _ = await Wait.js(try #require(rec.webView), "window.close(); 1")
    try await Self.until { h.rt.webviews.record(pop) == nil }
    #expect(h.selected == opener)
  }
}
