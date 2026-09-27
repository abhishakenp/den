import CordisValue
import DenTestSupport
import Testing

@testable import DenHost
@testable import PluginCores

/// Title and icon fallbacks: no data:/raw URLs or empty strings where a title or icon belongs.
@MainActor
@Suite(.serialized, .watchdog)
struct URLsTests {
  @Test func titleFallsBackToAPrettifiedLocation() {
    #expect(URLs.title("https://www.news.ycombinator.com/item?id=1") == "news.ycombinator.com")
    #expect(URLs.title("http://Example.com:8080/a") == "example.com")
    #expect(URLs.title("file:///Users/me/My%20Notes.html") == "My Notes.html")
    #expect(URLs.title("file:///") == "File")
    #expect(URLs.title("data:text/html,<h1>hi</h1>") == "Untitled")
    #expect(URLs.title("data:image/png;base64,iVBOR") == "Image")
    #expect(URLs.title("about:blank") == "New Tab")
    #expect(URLs.title("") == "New Tab")
    #expect(URLs.title("mailto:a@b.c") == "Untitled")
  }

  @Test func pageTitleRejectsBlankAndURLTitles() {
    #expect(URLs.pageTitle("Hacker News", "https://news.ycombinator.com") == "Hacker News")
    #expect(URLs.pageTitle("   ", "https://news.ycombinator.com") == "news.ycombinator.com")
    #expect(URLs.pageTitle("data:text/html,<p>x", "data:text/html,<p>x") == "Untitled")
    #expect(URLs.pageTitle("https://example.com/a", "https://example.com/a") == "example.com")
    #expect(URLs.pageTitle("about:blank", "about:blank") == "New Tab")
    #expect(URLs.pageTitle("file:///tmp/a.pdf", "file:///tmp/a.pdf") == "a.pdf")
  }

  @Test func displayNeverShowsARawDataURL() {
    #expect(URLs.display("data:text/html;charset=utf-8,<h1>hi</h1>") == "data:text/html")
    #expect(URLs.display("data:,hello") == "data:text/plain")
    #expect(URLs.display("https://www.apple.com/mac") == "apple.com")
    #expect(URLs.display("about:blank") == "")
  }

  @Test func faviconIsASiteTileWithoutAWebHost() {
    #expect(URLs.favicon("https://www.swift.org/blog") == "https://www.google.com/s2/favicons?domain=swift.org&sz=64")
    for u in ["data:text/html,x", "file:///tmp/a.html", "about:blank", ""] { #expect(URLs.favicon(u) == "site:") }
    // Saved favicons: bogus ones and stale derived s2 URLs are recomputed.
    #expect(URLs.icon("null/favicon.ico", "data:text/html,x") == "site:")
    #expect(URLs.icon("https://www.google.com/s2/favicons?domain=data&sz=64", "data:text/html,x") == "site:")
    #expect(URLs.icon(nil, "https://a.io/") == "https://www.google.com/s2/favicons?domain=a.io&sz=64")
    #expect(URLs.icon("https://a.io/favicon.ico", "https://a.io/") == "https://a.io/favicon.ico")
    #expect(URLs.icon("data:image/png;base64,AA", "https://a.io/") == "data:image/png;base64,AA")
  }

  @Test func tabDisplayTitleAndIconFallBack() {
    var t = TabsCore.Tab(id: "t", title: "", url: "data:text/html,<p>hi", favicon: "null/favicon.ico", lastActive: 0)
    #expect(t.displayTitle == "Untitled")
    #expect(t.icon == "site:")
    t.title = "data:text/html,<p>hi"
    #expect(t.displayTitle == "Untitled")
    t.customTitle = "Mine"
    #expect(t.displayTitle == "Mine")
    let blank = TabsCore.Tab(id: "b", title: " ", url: "about:blank", lastActive: 0)
    #expect(blank.displayTitle == "New Tab")
  }

  @Test func sidebarRowWindowTitleAndArchiveUseFallbacks() {
    let h = Harness()
    h.startTabs()
    let url = "data:text/html,<p>no title</p>"
    let id = h.tabs("open", ["url": .string(url)])["id"].string!
    h.rt.plugins.emit("webviews.title", ["id": .string(id), "title": .string(url)])
    h.rt.plugins.emit("webviews.favicon", ["id": .string(id), "url": "null/favicon.ico"])
    let row = (h.tree("sidebar.today", 0)["children"].array ?? []).first { $0["id"].string == id }
    #expect(row?["title"] == "Untitled")
    #expect(row?["icon"] == "site:")
    #expect(h.tabs("list")["today"].array?.first { $0["id"].string == id }?["favicon"] == .null)
    // The URL pill shows the media type, not the payload.
    #expect(h.tree("sidebar.header", 0)["children"][1]["text"] == "data:text/html")
    h.key("cmd+w")
    let e = h.tabs("archive")[0]
    #expect(e["title"] == "Untitled")
    #expect(e["favicon"] == "site:")
  }
}
