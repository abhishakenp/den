import AppKit
import CordisValue
import Foundation
import DenTestSupport
import Testing
import WebKit

@testable import DenHost

/// The page context menu (PageContextMenu.swift) for every context, on a local page from
/// MockServices (a link, an http image, text, a text field and a video): the page's own
/// `contextmenu` event reports the hit, WebKit's recorded menu for that context goes through den's
/// real `willOpenMenu`, and the test checks the items, their order and shortcuts, and runs den's
/// items (as a click on them would).
@MainActor
@Suite(.serialized, .watchdog)
struct ContextMenuTests {
  static let html = """
    <title>Menus</title><style>body{margin:0;font:16px -apple-system}.x{position:absolute;width:150px;height:150px;margin:0}</style>
    <a class=x href="/target" style="left:0;top:0;display:block">A link text</a>
    <img class=x src="/i.png" style="left:160px;top:0">
    <p id=t class=x style="left:320px;top:0">selected words here</p>
    <textarea id=f class=x style="left:480px;top:0">some text</textarea>
    <video id=v class=x src="/v.mp4" muted controls style="left:0;top:200px;width:300px;height:150px"></video>
    """

  static let png: Data = {
    let img = NSImage(size: NSSize(width: 8, height: 8))
    img.lockFocus()
    NSColor.systemTeal.setFill()
    NSRect(x: 0, y: 0, width: 8, height: 8).fill()
    img.unlockFocus()
    return NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
  }()

  struct Page {
    let rt: DenRuntime
    let id: String
    let w: DenWebView
    let mock: MockServices
    var base: String { mock.base }
  }

  /// The page on screen, its image and video loaded; the menu bar installed (shortcut hints).
  static func page() async throws -> Page {
    let rt = ServiceTests.runtime()
    let mock = MockServices()
    try mock.start()
    var files: [String: (type: String, data: Data)] = ["/p.html": ("text/html", Data(html.utf8)), "/i.png": ("image/png", png)]
    if let v = MediaScenarios.fixture() { files["/v.mp4"] = ("video/mp4", v) }
    mock.files = files
    NSApp.mainMenu = NSMenu()
    MainMenu.install()
    let id = rt.call("webviews", "create", ["url": .string(mock.base + "/p.html")])["id"].string!
    _ = rt.call("content", "show", ["panes": [.string(id)]])
    rt.window.window.orderFrontRegardless()
    let w = try #require(rt.webviews.record(id)?.webView as? DenWebView)
    try await PageActionTests.until { !w.isLoading && w.url != nil }
    let ready = await Wait.until("the image and video loaded", seconds: 30, every: .milliseconds(100)) {
      (await Wait.js(w, "document.querySelector('img').complete && document.querySelector('img').naturalWidth > 0 && document.querySelector('video').readyState >= 1", seconds: 5) as? Bool) == true
    }
    try #require(ready, "the page's image or video never loaded")
    DenWebView.pasteboard = NSPasteboard(name: NSPasteboard.Name("den-test-menu-\(UUID())"))
    return Page(rt: rt, id: id, w: w, mock: mock)
  }

  static func close(_ p: Page) {
    DenWebView.menuOpened = nil
    DenWebView.pasteboard = .general
    _ = p.rt.call("media", "exit")
    for id in Array(p.rt.webviews.records.keys) { _ = p.rt.call("webviews", "close", ["id": .string(id)]) }
    for w in p.rt.windows.all { w.window.orderOut(nil) }
    p.mock.stop()
  }

  /// WebKit's own menus on macOS 26 for each context, as WebKit hands them to `willOpenMenu`
  /// (identifier without the `WKMenuItemIdentifier` prefix, or nil; title; "-" = separator),
  /// recorded from real right-clicks (a test process can't show a WebKit context menu: WebKit
  /// only pops it up from a running app's event loop; the menus' screenshots come from the app,
  /// scripts/snapshots.sh page-menu-*).
  static let webkitMenus: [String: [(String?, String)]] = [
    "link": [("OpenLink", "Open Link"), ("OpenLinkInNewWindow", "Open Link in New Window"), ("DownloadLinkedFile", "Download Linked File"),
             ("CopyLink", "Copy Link"), (nil, "-"), ("ShareMenu", "Share…"), (nil, "-"), ("InspectElement", "Inspect Element")],
    "image": [("OpenImageInNewWindow", "Open Image in New Window"), ("DownloadImage", "Download Image"), ("CopyImage", "Copy Image"),
              ("CopySubject", "Copy Subject"), ("RevealImage", "Look Up"), (nil, "-"), ("ShareMenu", "Share…"), (nil, "-"), ("InspectElement", "Inspect Element")],
    "selection": [("LookUp", "Look Up “selected words here”"), ("Translate", "Translate “selected words here”"), (nil, "-"), ("SearchWeb", "Search with Google"),
                  (nil, "-"), ("Copy", "Copy"), ("CopyLinkWithHighlight", "Copy Link with Highlight"), (nil, "-"), ("ShareMenu", "Share…"), (nil, "-"), (nil, "-"),
                  ("WritingTools", "Show Writing Tools"), ("Summarize", "Summarize"), (nil, "-"), ("SpeechMenu", "Speech"), (nil, "-"), ("InspectElement", "Inspect Element")],
    "editable": [("LookUp", "Look Up “some”"), ("Translate", "Translate “some”"), (nil, "-"), ("SearchWeb", "Search with Google"), (nil, "-"),
                 (nil, "Cut"), ("Copy", "Copy"), ("Paste", "Paste"), (nil, "-"), ("SpellingMenu", "Spelling and Grammar"), (nil, "Substitutions"),
                 (nil, "-"), ("ShareMenu", "Share…"), (nil, "-"), ("InspectElement", "Inspect Element")],
    "video": [(nil, "Play"), (nil, "Unmute"), ("ShowHideMediaControls", "Hide Controls"), (nil, "Loop"), ("ToggleFullScreen", "Enter Full Screen"),
              ("ToggleEnhancedFullScreen", "Enter Picture in Picture"), ("ToggleVideoViewer", "Enter Viewer"), (nil, "-"), (nil, "-"),
              ("InspectElement", "Inspect Element"), ("ShowHideMediaStats", "Show Media Statistics")],
    "page": [("Reload", "Reload"), (nil, "-"), (nil, "-"), ("InspectElement", "Inspect Element")],
  ]

  /// A right-click at `point` (page points from the top left): the page's real `contextmenu`
  /// event there (den's hit report), then WebKit's menu for `kind` through den's real
  /// `willOpenMenu` (den's items, plugins', extensions', Inspect Element last). Returns the
  /// finished items; `pick` (a title) is then chosen, as a click on it would.
  static func rightClick(_ w: DenWebView, at point: NSPoint, _ kind: String, pick: String? = nil, line: UInt = #line) async throws -> [NSMenuItem] {
    w.context = .init()
    let js = "var e=document.elementFromPoint(\(point.x),\(point.y));e.dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,cancelable:true,clientX:\(point.x),clientY:\(point.y),button:2}));e.tagName"
    _ = await Wait.js(w, js)
    // The page reports what it hit (a page background reports nothing new).
    if kind != "page" { _ = await Wait.until("the page's hit report", seconds: 10, line: line) { w.context != .init() } }
    let menu = NSMenu()
    for (id, title) in try #require(webkitMenus[kind]) {
      if title == "-" { menu.addItem(.separator()); continue }
      let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      if let id { it.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifier" + id) }
      menu.addItem(it)
    }
    let win = try #require(w.window)
    let e = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: w.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    var seen: NSMenu?
    DenWebView.menuOpened = { _, m in seen = m }
    defer { DenWebView.menuOpened = nil }
    w.willOpenMenu(menu, with: e)
    #expect(seen === menu, "line \(line): den's menu hook didn't run")
    let got = menu.items
    if let pick {
      let it = try #require(got.first { $0.title == pick }, "line \(line): no “\(pick)” in \(titles(got))")
      let a = try #require(it.action, "line \(line): “\(pick)” does nothing")
      #expect(NSApp.sendAction(a, to: it.target, from: it), "line \(line): “\(pick)” wasn't handled")
      try await Task.sleep(for: .milliseconds(200))
    }
    return got
  }

  static func titles(_ items: [NSMenuItem]) -> [String] { items.filter { !$0.isSeparatorItem && !$0.isHidden }.map(\.title) }

  /// `want` appears in `items`, in this order (other items may sit between).
  static func inOrder(_ items: [NSMenuItem], _ want: [String], line: UInt = #line) {
    let have = titles(items)
    var at = have.startIndex
    for t in want {
      guard let i = have[at...].firstIndex(where: { $0 == t || (t.hasSuffix("*") && $0.hasPrefix(String(t.dropLast()))) }) else {
        Issue.record("line \(line): “\(t)” missing or out of order in \(have)")
        return
      }
      at = have.index(after: i)
    }
  }

  static func item(_ items: [NSMenuItem], _ title: String) -> NSMenuItem? { items.first { $0.title == title } }

  static func events(_ rt: DenRuntime, _ name: String) -> () -> [Value] {
    var got: [Value] = []
    rt.host.on(name) { got.append($0) }
    return { got }
  }

  static let link = NSPoint(x: 75, y: 75), image = NSPoint(x: 235, y: 75), text = NSPoint(x: 360, y: 20)
  static let field = NSPoint(x: 550, y: 75), video = NSPoint(x: 150, y: 260), blank = NSPoint(x: 700, y: 500)

  @Test func linkMenu() async throws {
    let p = try await Self.page()
    defer { Self.close(p) }
    p.rt.host.on("peek.link") { _ in }
    p.rt.host.on("peek.splitLink") { _ in }
    let newWindow = Self.events(p.rt, "webviews.newWindow"), opened = Self.events(p.rt, "window.opened")
    let peek = Self.events(p.rt, "peek.link"), split = Self.events(p.rt, "peek.splitLink")
    let items = try await Self.rightClick(p.w, at: Self.link, "link", pick: "Open Link in New Tab")
    Self.inOrder(items, ["Open Link in New Tab", "Open Link in New Window", "Open Link in Private Window", "Open Link in Peek", "Open Link in Split View",
                         "Download Linked File", "Save Link As…", "Copy Link", "Copy Link as Markdown", "Share…", "Inspect Element"])
    #expect(!Self.titles(items).contains("Open Link"))
    #expect(Self.titles(items).last == "Inspect Element")
    let inspect = try #require(Self.item(items, "Inspect Element"))
    #expect(inspect.keyEquivalent == "c" && inspect.keyEquivalentModifierMask == [.command, .option])
    let target = p.base + "/target"
    try await PageActionTests.until(10) { newWindow().last?["url"].string == target }
    #expect(newWindow().last?["background"] == true && newWindow().last?["id"].string == p.id)
    // Copy Link as Markdown: the link's text and address.
    _ = try await Self.rightClick(p.w, at: Self.link, "link", pick: "Copy Link as Markdown")
    #expect(DenWebView.pasteboard.string(forType: .string) == "[A link text](\(target))")
    // New window / private window: the window service opens one with the link.
    _ = try await Self.rightClick(p.w, at: Self.link, "link", pick: "Open Link in New Window")
    try await PageActionTests.until(10) { opened().contains { $0["url"].string == target && $0["private"] != true } }
    _ = try await Self.rightClick(p.w, at: Self.link, "link", pick: "Open Link in Private Window")
    try await PageActionTests.until(10) { opened().contains { $0["url"].string == target && $0["private"] == true } }
    // Peek and Split View go to their plugin.
    _ = try await Self.rightClick(p.w, at: Self.link, "link", pick: "Open Link in Peek")
    try await PageActionTests.until(10) { peek().last?["url"].string == target }
    _ = try await Self.rightClick(p.w, at: Self.link, "link", pick: "Open Link in Split View")
    try await PageActionTests.until(10) { split().last?["url"].string == target && split().last?["id"].string == p.id }
  }

  @Test func imageMenu() async throws {
    let p = try await Self.page()
    defer { Self.close(p) }
    let newWindow = Self.events(p.rt, "webviews.newWindow")
    let items = try await Self.rightClick(p.w, at: Self.image, "image", pick: "Copy Image Address")
    Self.inOrder(items, ["Open Image in New Tab", "Save Image As…", "Copy Image", "Copy Image Address", "Search Image with Google Lens", "Share…", "Inspect Element"])
    #expect(Self.titles(items).last == "Inspect Element")
    let src = p.base + "/i.png"
    #expect(DenWebView.pasteboard.string(forType: .string) == src)
    _ = try await Self.rightClick(p.w, at: Self.image, "image", pick: "Search Image with Google Lens")
    try await PageActionTests.until(10) { newWindow().last?["url"].string?.hasPrefix("https://lens.google.com/uploadbyurl?url=http%3A%2F%2F127%2E0%2E0%2E1") == true }
    _ = try await Self.rightClick(p.w, at: Self.image, "image", pick: "Open Image in New Tab")
    try await PageActionTests.until(10) { newWindow().last?["url"].string == src && newWindow().last?["background"] == true }
  }

  @Test func selectionMenu() async throws {
    let p = try await Self.page()
    defer { Self.close(p) }
    // A plugin's selection item (pagetools' Copy Link to Highlight) replaces WebKit's twin.
    _ = p.rt.call("webviews", "setMenu", ["plugin": "pagetools", "items": [["id": "pagetools.highlight", "title": "Copy Link to Highlight", "when": "selection"]]])
    let newWindow = Self.events(p.rt, "webviews.newWindow")
    _ = await Wait.js(p.w, "var r=document.createRange();r.selectNodeContents(document.getElementById('t'));getSelection().removeAllRanges();getSelection().addRange(r);1")
    let items = try await Self.rightClick(p.w, at: Self.text, "selection", pick: "Search Google for “selected words here”")
    Self.inOrder(items, ["Look Up*", "Search Google for “selected words here”", "Copy", "Copy Link to Highlight", "Share…", "Inspect Element"])
    #expect(!Self.titles(items).contains("Copy Link with Highlight"))
    #expect(Self.titles(items).contains("Speech") && Self.titles(items).last == "Inspect Element")
    let copy = try #require(Self.item(items, "Copy"))
    #expect(copy.keyEquivalent == "c" && copy.keyEquivalentModifierMask == .command)
    try await PageActionTests.until(10) { newWindow().last?["url"].string == "https://www.google.com/search?q=selected%20words%20here" }
  }

  @Test func editableMenu() async throws {
    let p = try await Self.page()
    defer { Self.close(p) }
    _ = await Wait.js(p.w, "var f=document.getElementById('f');f.focus();f.select();1")
    let items = try await Self.rightClick(p.w, at: Self.field, "editable")
    Self.inOrder(items, ["Cut", "Copy", "Paste", "Paste and Match Style", "Spelling and Grammar", "Substitutions", "Inspect Element"])
    let cut = try #require(Self.item(items, "Cut")), paste = try #require(Self.item(items, "Paste and Match Style"))
    #expect(cut.keyEquivalent == "x" && cut.keyEquivalentModifierMask == .command)
    #expect(paste.keyEquivalent == "v" && paste.keyEquivalentModifierMask == [.command, .option, .shift])
    #expect(paste.target === p.w && p.w.responds(to: paste.action!))
    // Paste and Match Style pastes plain text into the field.
    let pb = NSPasteboard.general
    let saved = pb.pasteboardItems?.compactMap { i in i.types.first.flatMap { t in i.data(forType: t).map { (t, $0) } } } ?? []
    defer {
      pb.clearContents()
      for (t, d) in saved { pb.setData(d, forType: t) }
    }
    pb.clearContents()
    pb.setString("plain words", forType: .string)
    _ = await Wait.js(p.w, "var f=document.getElementById('f');f.focus();f.select();1")
    p.rt.window.window.makeFirstResponder(p.w)
    _ = try await Self.rightClick(p.w, at: Self.field, "editable", pick: "Paste and Match Style")
    let value = await Wait.until("the pasted text", seconds: 10) { (await Wait.js(p.w, "document.getElementById('f').value", seconds: 5) as? String) == "plain words" }
    #expect(value)
  }

  @Test func videoMenu() async throws {
    let p = try await Self.page()
    defer { Self.close(p) }
    let items = try await Self.rightClick(p.w, at: Self.video, "video", pick: "Copy Video Address")
    Self.inOrder(items, ["Play", "Loop", "Enter Full Screen", "Enter Picture in Picture", "Copy Video Address", "Inspect Element"])
    #expect(Self.titles(items).contains { $0 == "Mute" || $0 == "Unmute" } && Self.titles(items).contains { $0.hasSuffix("Controls") })
    #expect(Self.titles(items).last == "Inspect Element")
    let pip = try #require(Self.item(items, "Enter Picture in Picture"))
    #expect(pip.action == #selector(DenWebView.togglePictureInPicture(_:)) && pip.target === p.w)
    #expect(DenWebView.pasteboard.string(forType: .string) == p.base + "/v.mp4")
    // Picture in picture through the media service: WebKit's native PiP window.
    var pipEvents: [Value] = []
    p.rt.host.on("media.pip") { pipEvents.append($0) }
    _ = await Wait.asyncJS(p.w, "await document.getElementById('v').play(); return true")
    _ = try await Self.rightClick(p.w, at: Self.video, "video", pick: "Enter Picture in Picture")
    try await PageActionTests.until(30) { pipEvents.contains { $0["webview"].string == p.id && $0["open"] == true } }
    _ = p.rt.call("media", "exit", ["webview": .string(p.id)])
    try await PageActionTests.until(30) { pipEvents.contains { $0["webview"].string == p.id && $0["open"] == false } }
  }

  @Test func pageMenu() async throws {
    let p = try await Self.page()
    defer { Self.close(p) }
    let newWindow = Self.events(p.rt, "webviews.newWindow")
    let items = try await Self.rightClick(p.w, at: Self.blank, "page", pick: "View Page Source")
    Self.inOrder(items, ["Reload", "Save Page As…", "Print…", "View Page Source", "Inspect Element"])
    let save = try #require(Self.item(items, "Save Page As…")), print = try #require(Self.item(items, "Print…")), src = try #require(Self.item(items, "View Page Source"))
    #expect(save.keyEquivalent == "S" || (save.keyEquivalent == "s" && save.keyEquivalentModifierMask == [.command, .shift]))
    #expect(print.keyEquivalent == "p" && print.keyEquivalentModifierMask == .command)
    #expect(src.keyEquivalent == "u" && src.keyEquivalentModifierMask == [.command, .option])
    try await PageActionTests.until(10) { newWindow().last?["url"].string?.hasPrefix("data:text/html") == true }
    #expect(Self.titles(items).last == "Inspect Element")
    // Print… runs the print panel (not in a test); Save Page As… a save panel: both target the page.
    #expect(print.target === p.w && save.target === p.w)
    // Plugins' page items (pagetools: Translate Page, Zap Elements…) follow View Page Source.
    _ = p.rt.call("webviews", "setMenu", ["plugin": "pagetools", "items": [["id": "pagetools.translate", "title": "Translate Page", "when": "page", "icon": "sf:translate"]]])
    var picked: Value?
    p.rt.host.on("webviews.menu") { picked = $0 }
    let again = try await Self.rightClick(p.w, at: Self.blank, "page", pick: "Translate Page")
    Self.inOrder(again, ["Reload", "Save Page As…", "Print…", "View Page Source", "Translate Page", "Inspect Element"])
    #expect(Self.item(again, "Translate Page")?.image != nil)
    #expect(picked?["id"] == "pagetools.translate" && picked?["webview"].string == p.id)
    // No page items on a link's menu.
    let linkItems = try await Self.rightClick(p.w, at: Self.link, "link")
    #expect(!Self.titles(linkItems).contains("Translate Page"))
  }
}
