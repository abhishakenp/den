import AppKit
import CordisValue
import Foundation
import Testing
import WebKit

@testable import DenHost

/// Browser basics behind the `webviews` page actions and den's WKWebView subclass: per-site zoom,
/// find in page, view source, link-click conventions, the context menu, mouse back/forward,
/// dropped links and files, and full screen hiding the sidebar. Real WKWebViews, local HTML.
@MainActor
@Suite(.serialized)
struct PageActionTests {
  /// A runtime with one shown page loaded from `html` at `base`.
  static func page(_ html: String, base: String = "https://www.zoom.test/") async throws -> (DenRuntime, String, WKWebView) {
    let rt = ServiceTests.runtime()
    let id = rt.call("webviews", "create")["id"].string!
    _ = rt.call("content", "show", ["panes": [.string(id)]])
    let w = try #require(rt.webviews.record(id)?.webView)
    w.loadHTMLString(html, baseURL: URL(string: base))
    try await until { !w.isLoading && w.url?.absoluteString == base }
    return (rt, id, w)
  }

  /// Polls (50 ms) until `cond` holds, failing after `seconds` instead of hanging. Generous,
  /// because WebContent launches slowly on a loaded machine (seen: load average 577).
  static func until(_ seconds: Double = 60, line: Int = #line, _ cond: () -> Bool) async throws {
    let end = Date().addingTimeInterval(seconds)
    while !cond() {
      if Date() > end { Issue.record("timed out waiting at line \(line)"); return }
      try await Task.sleep(for: .milliseconds(50))
    }
  }

  @Test func zoomStepsLikeSafariAndIsRememberedPerSite() async throws {
    let (rt, id, w) = try await Self.page("<p>zoom me</p>")
    var zooms: [Double] = []
    rt.host.on("webviews.zoom") { v in zooms.append(v.num("zoom")) }
    // No id: the focused pane.
    #expect(rt.call("webviews", "zoom", ["action": "in"])["zoom"] == 1.15)
    #expect(rt.call("webviews", "zoom", ["id": .string(id), "action": "in"])["zoom"] == 1.25)
    #expect(abs(w.pageZoom - 1.25) < 0.001)
    #expect(rt.call("webviews", "get", ["id": .string(id)])["zoom"] == 1.25)
    #expect(rt.call("storage", "get", ["ns": "_zoom", "key": "zoom.test"]) == 1.25)
    for _ in 0..<20 { _ = rt.call("webviews", "zoom", ["action": "in"]) }
    #expect(w.pageZoom == 3)  // capped at 300%
    for _ in 0..<20 { _ = rt.call("webviews", "zoom", ["action": "out"]) }
    #expect(w.pageZoom == 0.5)  // 50%
    _ = rt.call("webviews", "zoom", ["action": "in"])  // 75%
    #expect(zooms.last == 0.75)
    // Another page of the same site in a new web view opens at the remembered zoom; other sites at 100%.
    let other = rt.call("webviews", "create")["id"].string!
    _ = rt.call("content", "show", ["panes": [.string(other)]])
    let w2 = try #require(rt.webviews.record(other)?.webView)
    w2.loadHTMLString("<p>two</p>", baseURL: URL(string: "https://zoom.test/two"))
    try await Self.until { abs(w2.pageZoom - 0.75) < 0.001 }
    w2.loadHTMLString("<p>elsewhere</p>", baseURL: URL(string: "https://elsewhere.test/"))
    try await Self.until { w2.url?.host == "elsewhere.test" }
    #expect(w2.pageZoom == 1)
    // Reset forgets the site.
    _ = rt.call("webviews", "zoom", ["id": .string(id), "action": "reset"])
    #expect(w.pageZoom == 1)
    #expect(rt.call("storage", "get", ["ns": "_zoom", "key": "zoom.test"]).isNull)
    #expect(rt.call("webviews", "zoom", ["action": "sideways"]).isError)
  }

  @Test func findBarCountsAndStepsThroughMatches() async throws {
    let (rt, id, _) = try await Self.page("<p>apple pie</p><p>Apple tart</p><p>banana</p><p>an apple a day</p>")
    let pa = try #require(rt.webviews.pageActions)
    #expect(pa.bar == nil)  // lazy: nothing until the first ⌘F
    _ = rt.call("webviews", "find", ["action": "show"])
    let bar = try #require(pa.bar)
    #expect(bar.superview === rt.window.overlays)
    // Top right of the card, inside it.
    let card = rt.window.overlays.convert(rt.content.card(id)!.frame, from: rt.window.contentArea)
    #expect(bar.frame.maxX == (card.maxX - Tokens.findBarInset).rounded() && bar.frame.minY == (card.minY + Tokens.findBarInset).rounded())
    #expect(rt.window.window.firstResponder === bar.field.currentEditor())
    bar.field.stringValue = "apple"
    bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    try await Self.until { pa.matchCount == 3 && pa.matchIndex == 1 }
    #expect(bar.count.stringValue == "1 of 3")
    // Every match is highlighted, the current one separately.
    let w = try #require(rt.webviews.record(id)?.webView)
    let sizes = try await w.callAsyncJavaScript("return [CSS.highlights.get('den-find').size, CSS.highlights.get('den-find-current').size]", contentWorld: .defaultClient) as? [Int]
    #expect(sizes == [3, 1])
    _ = rt.call("webviews", "find", ["action": "next"])
    try await Self.until { pa.matchIndex == 2 }
    _ = rt.call("webviews", "find", ["action": "previous"])
    _ = rt.call("webviews", "find", ["action": "previous"])
    try await Self.until { pa.matchIndex == 3 }  // wraps
    #expect(bar.count.stringValue == "3 of 3")
    _ = rt.call("webviews", "find", ["action": "show", "query": "kiwi"])
    try await Self.until { bar.count.stringValue == "No matches" }
    _ = rt.call("webviews", "find", ["action": "hide"])
    #expect(!pa.findBarVisible)
    try await Self.until { pa.matchCount == 0 }
    let cleared = try await w.callAsyncJavaScript("return CSS.highlights.has('den-find')", contentWorld: .defaultClient) as? Bool
    #expect(cleared == false)
  }

  @Test func findUsesTheSelection() async throws {
    let (rt, _, w) = try await Self.page("<p id=p>banana split and banana bread</p>")
    _ = try await w.evaluateJavaScript("var r=document.createRange();var t=document.getElementById('p').firstChild;r.setStart(t,0);r.setEnd(t,6);getSelection().removeAllRanges();getSelection().addRange(r);1")
    _ = rt.call("webviews", "find", ["action": "selection"])
    let pa = try #require(rt.webviews.pageActions)
    try await Self.until { pa.query == "banana" && pa.matchCount == 2 }
    #expect(pa.findBarVisible)
  }

  @Test func viewSourceOpensTheEscapedDOMInANewTab() async throws {
    let (rt, id, _) = try await Self.page("<title>T</title><p class=x>a &amp; b</p>")
    var opened: Value = .null
    rt.host.on("webviews.newWindow") { v in opened = v }
    #expect(rt.call("webviews", "viewSource")["pending"] == true)
    try await Self.until { !opened.isNull }
    #expect(opened["id"].string == id && opened["background"] == false)
    let url = opened.str("url")
    #expect(url.hasPrefix("data:text/html;charset=utf-8;base64,"))
    let html = String(data: Data(base64Encoded: String(url.dropFirst("data:text/html;charset=utf-8;base64,".count)))!, encoding: .utf8)!
    #expect(html.contains("&lt;p class=\"x\"&gt;a &amp;amp; b&lt;/p&gt;"))
    #expect(html.contains("<title>Source of https://www.zoom.test/</title>"))
    // The data page loads in a web view.
    let src = rt.call("webviews", "create", ["url": .string(url)])["id"].string!
    _ = rt.call("content", "show", ["panes": [.string(src)]])
    try await Self.until { rt.call("webviews", "get", ["id": .string(src)]).str("title") == "Source of https://www.zoom.test/" }
  }

  @Test func reloadFromOriginAndInspector() async throws {
    let (rt, id, w) = try await Self.page("<p>x</p>")
    #expect(rt.call("webviews", "reload", ["fromOrigin": true]) == .ok)
    #expect(w.isInspectable)
    // WebKit's inspector entry point exists on this macOS (opening it is not exercised in tests).
    #expect(w.responds(to: NSSelectorFromString("_inspector")))
    #expect(rt.call("webviews", "get")["id"].string == id)
    #expect(rt.call("webviews", "print", ["id": "nope"]).isError)
  }

  @Test func linkClickConventions() {
    let u = URL(string: "https://a.test/x")!
    // ⌘-click and middle-click: background tab; ⌘⇧-click: selected tab.
    #expect(LinkPolicy.newTab(isLinkClick: true, target: u, modifiers: [.cmd], buttonNumber: 1) == true)
    #expect(LinkPolicy.newTab(isLinkClick: true, target: u, modifiers: [], buttonNumber: 4) == true)
    #expect(LinkPolicy.newTab(isLinkClick: true, target: u, modifiers: [.cmd, .shift], buttonNumber: 1) == false)
    #expect(LinkPolicy.newTab(isLinkClick: true, target: u, modifiers: [.shift], buttonNumber: 4) == false)
    // Plain clicks, shift/opt-clicks (Peek's) and non-link navigations are left alone.
    #expect(LinkPolicy.newTab(isLinkClick: true, target: u, modifiers: [], buttonNumber: 1) == nil)
    #expect(LinkPolicy.newTab(isLinkClick: true, target: u, modifiers: [.shift], buttonNumber: 1) == nil)
    #expect(LinkPolicy.newTab(isLinkClick: false, target: u, modifiers: [.cmd], buttonNumber: 1) == nil)
    #expect(LinkPolicy.newTab(isLinkClick: true, target: URL(string: "mailto:a@b.c")!, modifiers: [.cmd], buttonNumber: 1) == nil)
  }

  /// A real ⌘-click on a link: WebKit reports the modifier, den cancels and asks for a background tab.
  @Test func realCommandClickOpensBackgroundTab() async throws {
    let html = "<style>body{margin:0}a{display:block;width:100vw;height:100vh}</style><a href='https://www.zoom.test/next'>x</a>"
    let (rt, id, w) = try await Self.page(html)
    var opened: Value = .null
    rt.host.on("webviews.newWindow") { v in opened = v }
    // Root cause of the flake seen in full runs: the test window is never on screen, so WebKit
    // treats the page as hidden and (with `inactiveSchedulingPolicy = .suspend`) stops running its
    // WebContent process a moment later; the click then never reaches the page. Put the window on
    // screen (without activating den or touching any other app) for the duration of the click.
    rt.window.window.orderFrontRegardless()
    defer { rt.window.window.orderOut(nil) }
    // The link must be laid out in WebContent before a click can hit it.
    var laidOut = false
    for _ in 0..<600 where !laidOut {
      laidOut = ((try? await w.evaluateJavaScript("document.querySelector('a').getBoundingClientRect().height")) as? NSNumber)?.doubleValue ?? 0 > 0
      if !laidOut { try await Task.sleep(for: .milliseconds(50)) }
    }
    let win = try #require(w.window)
    let p = w.convert(NSPoint(x: w.bounds.midX, y: w.bounds.midY), to: nil)
    // Deliver to WebKit's own view under the point (never a sidebar or overlay view, whose
    // mouseDown could start a window drag and wait for a real mouse-up).
    let target = try #require(w.hitTest(w.superview!.convert(p, from: nil)))
    #expect(target === w || target.isDescendant(of: w))
    // WebKit handles the click asynchronously in WebContent; on a very loaded machine a click can be
    // dropped, so click again (at most 6 times, up to 10 s of wall time each) rather than wait forever.
    for _ in 0..<6 where opened.isNull {
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let e = try #require(NSEvent.mouseEvent(with: type, location: p, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        if type == .leftMouseDown { target.mouseDown(with: e) } else { target.mouseUp(with: e) }
        try await Task.sleep(for: .milliseconds(50))
      }
      let end = Date().addingTimeInterval(10)
      while opened.isNull, Date() < end { try await Task.sleep(for: .milliseconds(50)) }
    }
    #expect(opened["url"] == "https://www.zoom.test/next" && opened["background"] == true && opened["id"].string == id)
    #expect(w.url?.absoluteString == "https://www.zoom.test/")  // the page itself stayed
  }

  @Test func contextMenuSpeaksTabsAndSavesAs() {
    func menu(_ ids: [String]) -> NSMenu {
      let m = NSMenu()
      for i in ids {
        let it = NSMenuItem(title: i, action: nil, keyEquivalent: "")
        it.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifier" + i)
        m.addItem(it)
      }
      return m
    }
    let m = menu(["OpenLinkInNewWindow", "DownloadLinkedFile", "CopyLink", "OpenImageInNewWindow", "DownloadImage", "CopyImage", "SearchWeb"])
    let hit = DenWebView.ContextHit(link: "https://a.test/l", image: "https://a.test/i.png", selection: "  a rather long selected phrase here  ")
    DenWebView.customize(m, hit: hit, peek: true, engine: "Kagi", target: nil)
    #expect(m.items.map(\.title) == ["Open Link in New Tab", "Open Link in Peek", "Save Link As…", "CopyLink", "Open Image in New Tab", "Save Image As…",
                                     "CopyImage", "Search Kagi for “a rather long selected phrase…”"])
    #expect(m.items[0].representedObject as? String == "https://a.test/l")
    #expect(m.items[5].representedObject as? String == "https://a.test/i.png")
    #expect(m.items[7].representedObject as? String == "a rather long selected phrase here")
    // No Peek plugin: no Peek item; nothing hit: WebKit's own items, retitled.
    let m2 = menu(["OpenLinkInNewWindow", "DownloadLinkedFile", "OpenImageInNewWindow"])
    DenWebView.customize(m2, hit: .init(), peek: false, engine: "Google", target: nil)
    #expect(m2.items.map(\.title) == ["Open Link in New Tab", "Open Image in New Tab"])
    // The page reports what was right-clicked (the DOM contextmenu event).
    #expect(DenWebView.contextScript.contains("denContext"))
  }

  @Test func rightClickReportsTheHitElement() async throws {
    let html = "<a id=a href='https://a.test/l'><img id=i src='data:image/gif;base64,R0lGODlhAQABAAAAACw=' width=50 height=50></a>"
    let (_, _, w) = try await Self.page(html)
    let dw = try #require(w as? DenWebView)
    _ = try await w.evaluateJavaScript("document.getElementById('i').dispatchEvent(new MouseEvent('contextmenu',{bubbles:true})); 1")
    try await Self.until { dw.context.link == "https://a.test/l" }
    #expect(dw.context.image.hasPrefix("data:image/gif"))
  }

  @Test func searchUsesTheDefaultEngine() {
    let rt = ServiceTests.runtime()
    let pa = rt.webviews.pageActions!
    #expect(pa.searchEngineName == "Google")
    #expect(pa.searchURL(" a&b c ") == "https://www.google.com/search?q=a%26b%20c")
    pa.searchEngine = { ("Kagi", "https://kagi.com/search?q=%s") }
    #expect(pa.searchURL("x") == "https://kagi.com/search?q=x")
  }

  @Test func mouseBackAndForwardButtons() async throws {
    let (_, _, w) = try await Self.page("<p>zero</p>")
    // Real loads (data: URLs), so back/forward have history items to return to.
    let one = URL(string: "data:text/html,one")!, two = URL(string: "data:text/html,two")!
    w.load(URLRequest(url: one))
    try await Self.until { !w.isLoading && w.url == one }
    w.load(URLRequest(url: two))
    try await Self.until { !w.isLoading && w.url == two && w.canGoBack }
    // NSEvent.mouseEvent can't set buttonNumber; build it through CGEvent instead.
    func other(_ button: Int64) -> NSEvent {
      let cg = CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp, mouseCursorPosition: .zero, mouseButton: CGMouseButton(rawValue: UInt32(button))!)!
      return NSEvent(cgEvent: cg)!
    }
    #expect(other(3).buttonNumber == 3)
    w.otherMouseUp(with: other(3))
    try await Self.until { w.url == one && !w.isLoading && w.canGoForward }
    w.otherMouseUp(with: other(4))
    try await Self.until { w.url == two }
    #expect(w.allowsBackForwardNavigationGestures && w.allowsMagnification)
  }

  @Test func droppedLinksAndFiles() {
    let pb = NSPasteboard(name: NSPasteboard.Name("den-test-\(UUID())"))
    pb.clearContents()
    pb.writeObjects([URL(string: "https://a.test/x")! as NSURL, URL(fileURLWithPath: "/tmp/a.pdf") as NSURL])
    #expect(SidebarContainerView.droppedURLs(pb) == ["https://a.test/x", "file:///tmp/a.pdf"])
    #expect(DenWebView.fileURLs(pb) == [URL(fileURLWithPath: "/tmp/a.pdf")])
    pb.clearContents()
    pb.setString("swift.org", forType: .string)
    #expect(SidebarContainerView.droppedURLs(pb) == ["https://swift.org"])
    pb.clearContents()
    pb.setString("two words", forType: .string)
    #expect(SidebarContainerView.droppedURLs(pb).isEmpty)
    let rt = ServiceTests.runtime()
    var got: Value = .null
    rt.host.on("window.dropURLs") { v in got = v }
    rt.window.sidebar.onDropURLs?(["https://a.test/x"])
    #expect(got["urls"] == ["https://a.test/x"] && got["target"] == "sidebar")
    #expect(rt.window.sidebar.registeredDraggedTypes.contains(.URL))
  }

  @Test func fullScreenHidesTheSidebarAndRestoresIt() {
    let rt = ServiceTests.runtime()
    let wc = rt.window
    #expect(!wc.sidebarHidden)
    wc.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification))
    #expect(wc.sidebarHidden)
    wc.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification))
    #expect(!wc.sidebarHidden)
    // Already hidden before: stays hidden after.
    wc.setSidebarHidden(true, animated: false)
    wc.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification))
    wc.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification))
    #expect(wc.sidebarHidden)
  }
}
