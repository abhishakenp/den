import AppKit
import CordisValue
import DenTestSupport
import Testing
import WebKit

@testable import DenHost

/// Several browser windows (docs/host-api.md#window): `window.new`, per-window content and sidebars,
/// a page live in one window at a time, private windows, and what closing a window does.
@MainActor
@Suite(.serialized, .watchdog)
struct WindowTests {
  @Test func newWindowIsActiveWithItsOwnContentAndSidebar() {
    let rt = ServiceTests.runtime()
    var events: [(String, Value)] = []
    for e in ["window.opened", "window.activated", "window.closed"] { rt.plugins.on(e) { events.append((e, $0)) } }
    let a = rt.call("webviews", "create", ["url": "about:blank"])["id"]
    rt.call("content", "show", ["panes": [a]])
    rt.call("ui", "set", ["slot": "sidebar.header", "tree": ["type": "text", "id": "t", "text": "shared"]])
    let w2 = rt.call("window", "new")["id"].string
    #expect(w2 == "w2")
    #expect(rt.window.id == "w2")
    #expect(rt.call("window", "get")["count"] == 2)
    // Opened, then activated, in that order.
    #expect(events.map(\.0) == ["window.opened", "window.activated"])
    #expect(events[1].1["previous"] == "w1")
    // The new window starts empty; the first keeps its page.
    #expect(rt.call("content", "get")["panes"] == [])
    #expect(rt.call("content", "get", ["window": "w1"])["panes"] == [a])
    // It starts with what the other window's sidebar shows, and later trees go to both.
    #expect(rt.ui.sidebar(of: "w2")?.slot("sidebar.header", page: 0)?.root?.node["text"] == "shared")
    rt.call("ui", "set", ["slot": "sidebar.header", "tree": ["type": "text", "id": "t", "text": "both"]])
    #expect(rt.ui.sidebar(of: "w1")?.slot("sidebar.header", page: 0)?.root?.node["text"] == "both")
    #expect(rt.ui.sidebar(of: "w2")?.slot("sidebar.header", page: 0)?.root?.node["text"] == "both")
    // A tree for one window goes to that window only.
    rt.call("ui", "set", ["slot": "sidebar.header", "window": "w1", "tree": ["type": "text", "id": "t", "text": "one"]])
    #expect(rt.ui.sidebar(of: "w1")?.slot("sidebar.header", page: 0)?.root?.node["text"] == "one")
    #expect(rt.ui.sidebar(of: "w2")?.slot("sidebar.header", page: 0)?.root?.node["text"] == "both")
    #expect(rt.call("ui", "set", ["slot": "sidebar.header", "window": "w9", "tree": .null]).isError)
    // Focusing the first window makes it active again.
    rt.call("window", "focus", ["id": "w1"])
    #expect(rt.window.id == "w1")
    #expect(rt.call("content", "get")["panes"] == [a])
    #expect((rt.call("window", "list").array ?? []).map { $0.str("id") } == ["w1", "w2"])
  }

  /// A page shows in one window at a time: showing it in a second window moves the live view there
  /// and the first says where it went, until it becomes active again and takes the page back.
  @Test func aPageMovesBetweenWindowsAndComesBack() throws {
    let rt = ServiceTests.runtime()
    let a = rt.call("webviews", "create", ["url": "about:blank"])["id"]
    rt.call("content", "show", ["panes": [a]])
    let web = try #require(rt.webviews.record(a.string!)?.webView)
    #expect(web.window === rt.windows.main.window)
    rt.call("window", "new")
    let w2 = try #require(rt.windows.find("w2"))
    rt.call("content", "show", ["panes": [a]])
    #expect(web.window === w2.window)
    let first = try #require(rt.content.content(of: "w1")?.cards[a.string!])
    #expect(first.clip.subviews.contains { $0 is ElsewhereView })
    // Back to the first window: it takes the page back, and the second now says where it went.
    rt.call("window", "focus", ["id": "w1"])
    #expect(web.window === rt.windows.main.window)
    #expect(web.superview === first.clip)
    #expect(!first.clip.subviews.contains { $0 is ElsewhereView })
    let second = try #require(rt.content.content(of: "w2")?.cards[a.string!])
    #expect(second.clip.subviews.contains { $0 is ElsewhereView })
  }

  @Test func closingAWindowActivatesAnotherAndTheLastOnlyHides() throws {
    let rt = ServiceTests.runtime()
    var closed: [Value] = []
    rt.plugins.on("window.closed") { closed.append($0) }
    let a = rt.call("webviews", "create", ["url": "about:blank"])["id"]
    rt.call("window", "new")
    rt.call("content", "show", ["panes": [a]])
    rt.call("window", "close", ["id": "w2"])
    #expect(closed.count == 1)
    #expect(closed.first?["id"] == "w2")
    #expect(closed.first?["panes"] == [a])
    #expect(!closed.first!["frame"].isNull)
    #expect(rt.window.id == "w1")
    #expect(rt.call("window", "get")["count"] == 1)
    #expect(rt.ui.sidebar(of: "w2") == nil)
    // The page outlives the window (tabs are shared); it is just no longer on screen.
    #expect(rt.webviews.record(a.string!)?.webView?.window == nil)
    // The last normal window is only hidden, like before (the Dock brings it back).
    rt.call("window", "close")
    #expect(closed.count == 1)
    #expect(rt.call("window", "get")["count"] == 1)
    // A freed id is used again.
    #expect(rt.call("window", "new")["id"] == "w2")
  }

  @Test func privateWindowIsDarkAndHasItsOwnEphemeralStore() throws {
    let rt = ServiceTests.runtime()
    let p = rt.call("window", "new", ["private": true])["id"].string
    #expect(p == "p1")
    let w = try #require(rt.windows.find("p1"))
    #expect(w.isPrivate)
    #expect(w.isDark)
    #expect(w.currentTheme == Tokens.privateTheme)
    #expect(rt.call("window", "get")["private"] == true)
    // Space themes don't reach it.
    rt.call("window", "setTheme", ["colors": ["#ffffff"], "page": 0])
    #expect(w.currentTheme == Tokens.privateTheme)
    // Space-wide sidebar trees skip it; trees addressed to it land.
    rt.call("ui", "set", ["slot": "sidebar.header", "tree": ["type": "text", "id": "t", "text": "spaces"]])
    #expect(rt.ui.sidebar(of: "p1")?.slot("sidebar.header", page: 0)?.root == nil)
    rt.call("ui", "set", ["slot": "sidebar.header", "window": "p1", "tree": ["type": "text", "id": "t", "text": "private"]])
    #expect(rt.ui.sidebar(of: "p1")?.slot("sidebar.header", page: 0)?.root?.node["text"] == "private")
    // Its pages share one ephemeral store, separate from other private windows and never persistent.
    let a = rt.call("webviews", "create", ["url": "about:blank", "profile": "private:p1"])["id"].string!
    let b = rt.call("webviews", "create", ["url": "about:blank", "profile": "private:p1"])["id"].string!
    let c = rt.call("webviews", "create", ["url": "about:blank", "profile": "private:p2"])["id"].string!
    #expect(rt.webviews.store(for: "private:p1") === rt.webviews.store(for: "private:p1"))
    #expect(rt.webviews.store(for: "private:p1") !== rt.webviews.store(for: "private:p2"))
    #expect(!rt.webviews.store(for: "private:p1").isPersistent)
    #expect(rt.webviews.record(a)?.isPrivate == true && rt.webviews.record(c)?.isPrivate == true)
    // Nothing is written for previews.
    #expect(rt.call("webviews", "snapshot", ["id": .string(b), "path": "/tmp/den-never.png"]).isError)
  }
}
