import AppKit
import CordisValue
import Foundation
import DenTestSupport
import Testing
import WebKit

@testable import DenHost

/// The page context menu (PageContextMenu.swift) for every context, built by WebKit and den for
/// a real right-click in a real window (on a local page from MockServices: a link, an http image,
/// text, a text field and a video), read while AppKit shows it, then closed by the test (after
/// choosing an item, as a click on it would). Checks the items, their order and shortcuts, and
/// what the den items do.
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
    for w in p.rt.windows.all { w.window.orderOut(nil) }
    p.mock.stop()
  }

  /// A real right-click at `point` (page points from the top left). Returns the finished menu's
  /// items; `pick` (a title) is chosen once the menu is up.
  static func rightClick(_ w: DenWebView, at point: NSPoint, pick: String? = nil, line: UInt = #line) async throws -> [NSMenuItem] {
    var items: [NSMenuItem]?
    DenWebView.menuOpened = { _, m in
      items = m.items
      nonisolated(unsafe) let menu = m
      let t = Timer(timeInterval: 0.15, repeats: false) { _ in
        MainActor.assumeIsolated {
          menu.cancelTrackingWithoutAnimation()
          if let pick, let i = menu.items.firstIndex(where: { $0.title == pick }) { menu.performActionForItem(at: i) }
        }
      }
      RunLoop.main.add(t, forMode: .common)
    }
    defer { DenWebView.menuOpened = nil }
    let win = try #require(w.window)
    let wp = w.convert(point, to: nil)
    let target = try #require(w.hitTest(w.superview!.convert(wp, from: nil)))
    for _ in 0..<5 where items == nil {
      for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
        let e = try #require(NSEvent.mouseEvent(with: type, location: wp, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .rightMouseDown ? 1 : 0))
        if type == .rightMouseDown { target.rightMouseDown(with: e) } else { target.rightMouseUp(with: e) }
      }
      _ = await Wait.until("the context menu", seconds: 10, line: line) { items != nil }
    }
    let got = try #require(items, "no context menu at \(point)")
    // Let the picked item's action run (it is performed when the menu's timer fires).
    try await Task.sleep(for: .milliseconds(400))
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
    let items = try await Self.rightClick(p.w, at: Self.link, pick: "Open Link in New Tab")
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
    _ = try await Self.rightClick(p.w, at: Self.link, pick: "Copy Link as Markdown")
    #expect(DenWebView.pasteboard.string(forType: .string) == "[A link text](\(target))")
    // New window / private window: the window service opens one with the link.
    _ = try await Self.rightClick(p.w, at: Self.link, pick: "Open Link in New Window")
    try await PageActionTests.until(10) { opened().contains { $0["url"].string == target && $0["private"] != true } }
    _ = try await Self.rightClick(p.w, at: Self.link, pick: "Open Link in Private Window")
    try await PageActionTests.until(10) { opened().contains { $0["url"].string == target && $0["private"] == true } }
    // Peek and Split View go to their plugin.
    _ = try await Self.rightClick(p.w, at: Self.link, pick: "Open Link in Peek")
    try await PageActionTests.until(10) { peek().last?["url"].string == target }
    _ = try await Self.rightClick(p.w, at: Self.link, pick: "Open Link in Split View")
    try await PageActionTests.until(10) { split().last?["url"].string == target && split().last?["id"].string == p.id }
  }

  @Test func imageMenu() async throws {
    let p = try await Self.page()
    defer { Self.close(p) }
    let newWindow = Self.events(p.rt, "webviews.newWindow")
    let items = try await Self.rightClick(p.w, at: Self.image, pick: "Copy Image Address")
    Self.inOrder(items, ["Open Image in New Tab", "Save Image As…", "Copy Image", "Copy Image Address", "Search Image with Google Lens", "Share…", "Inspect Element"])
    #expect(Self.titles(items).last == "Inspect Element")
    let src = p.base + "/i.png"
    #expect(DenWebView.pasteboard.string(forType: .string) == src)
    _ = try await Self.rightClick(p.w, at: Self.image, pick: "Search Image with Google Lens")
    try await PageActionTests.until(10) { newWindow().last?["url"].string?.hasPrefix("https://lens.google.com/uploadbyurl?url=http%3A%2F%2F127%2E0%2E0%2E1") == true }
    _ = try await Self.rightClick(p.w, at: Self.image, pick: "Open Image in New Tab")
    try await PageActionTests.until(10) { newWindow().last?["url"].string == src && newWindow().last?["background"] == true }
  }

  @Test func selectionMenu() async throws {
    let p = try await Self.page()
    defer { Self.close(p) }
    // A plugin's selection item (pagetools' Copy Link to Highlight) replaces WebKit's twin.
    _ = p.rt.call("webviews", "setMenu", ["plugin": "pagetools", "items": [["id": "pagetools.highlight", "title": "Copy Link to Highlight", "when": "selection"]]])
    let newWindow = Self.events(p.rt, "webviews.newWindow")
    _ = await Wait.js(p.w, "var r=document.createRange();r.selectNodeContents(document.getElementById('t'));getSelection().removeAllRanges();getSelection().addRange(r);1")
    let items = try await Self.rightClick(p.w, at: Self.text, pick: "Search Google for “selected words here”")
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
    let items = try await Self.rightClick(p.w, at: Self.field)
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
    _ = try await Self.rightClick(p.w, at: Self.field, pick: "Paste and Match Style")
    let value = await Wait.until("the pasted text", seconds: 10) { (await Wait.js(p.w, "document.getElementById('f').value", seconds: 5) as? String) == "plain words" }
    #expect(value)
  }

  @Test func videoMenu() async throws {
    let p = try await Self.page()
    defer { Self.close(p) }
    let items = try await Self.rightClick(p.w, at: Self.video, pick: "Copy Video Address")
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
    _ = try await Self.rightClick(p.w, at: Self.video, pick: "Enter Picture in Picture")
    try await PageActionTests.until(30) { pipEvents.contains { $0["webview"].string == p.id && $0["open"] == true } }
    _ = p.rt.call("media", "exit", ["webview": .string(p.id)])
    try await PageActionTests.until(30) { pipEvents.contains { $0["webview"].string == p.id && $0["open"] == false } }
  }

  @Test func pageMenu() async throws {
    let p = try await Self.page()
    defer { Self.close(p) }
    let newWindow = Self.events(p.rt, "webviews.newWindow")
    let items = try await Self.rightClick(p.w, at: Self.blank, pick: "View Page Source")
    Self.inOrder(items, ["Reload", "Save Page As…", "Print…", "View Page Source", "Inspect Element"])
    let save = try #require(Self.item(items, "Save Page As…")), print = try #require(Self.item(items, "Print…")), src = try #require(Self.item(items, "View Page Source"))
    #expect(save.keyEquivalent == "S" || (save.keyEquivalent == "s" && save.keyEquivalentModifierMask == [.command, .shift]))
    #expect(print.keyEquivalent == "p" && print.keyEquivalentModifierMask == .command)
    #expect(src.keyEquivalent == "u" && src.keyEquivalentModifierMask == [.command, .option])
    try await PageActionTests.until(10) { newWindow().last?["url"].string?.hasPrefix("data:text/html") == true }
    // Inspect Element (WebKit's, last): the Web Inspector opens on the page.
    _ = try await Self.rightClick(p.w, at: Self.blank, pick: "Inspect Element")
    try await PageActionTests.until(30) { DevTools.isOpen(p.w) }
    DevTools.close(p.w)
    try await PageActionTests.until(30) { !DevTools.isOpen(p.w) }
  }
}
