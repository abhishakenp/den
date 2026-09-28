import AppKit
import CoreImage
import CordisValue
import DenTestSupport
import Foundation
import Testing

@testable import DenHost
@testable import PluginCores

/// Share and clipboard: Paste and Go / Paste and Search (URL pill and command bar menus), the share
/// sheet, the QR code popover, and copy toasts that say what was copied. A private pasteboard
/// stands in for the clipboard (`PasteText.board`), and the share picker is recorded, never shown.
@MainActor
@Suite(.serialized, .watchdog)
struct ShareTests {
  @MainActor final class Rig {
    let h = Harness()
    let board = NSPasteboard(name: NSPasteboard.Name("den-share-test-\(UUID())"))
    var shared: [(items: [Any], view: NSView)] = []

    init() {
      PasteText.board = board
      h.rt.app.share.present = { [unowned self] _, _, v, _ in self.shared.append((self.h.rt.app.share.lastItems, v)) }
    }
    func done() {
      PasteText.board = .general
      board.releaseGlobally()
    }
    func clip(_ s: String) {
      board.clearContents()
      board.setString(s, forType: .string)
    }
    var toast: String? { h.rt.ui.toasts.last?.label.stringValue }
    /// A selected tab at `url` (never loaded: the tests read the tab's URL, not the page).
    func tab(_ url: String) -> String {
      let id = h.tabs("open", ["url": .string(url)])["id"].string!
      _ = h.tabs("select", ["id": .string(id)])
      return id
    }
    var selectedURL: String { h.rt.call("webviews", "get", ["id": .string(h.selected ?? "")]).s("url") }
  }

  func wait(line: UInt = #line, _ cond: () -> Bool) async -> Bool {
    await Wait.until("a condition", seconds: 10, line: line) { cond() }
  }

  // MARK: Paste and Go

  /// The host labels the menu item with the command bar's own address-or-search rule.
  @Test func pasteRuleMatchesTheCommandBar() {
    let inputs = ["example.com", "https://a.b/c", "HTTP://X.ORG", "localhost:3000", "192.168.0.1:8080/x", "bücher.de", "swift concurrency",
                  "hello", "v1.2", "a.b1", "file:///tmp/x", "data:text/plain,hi", "about:blank", "news.test/path?q=1#f", "Example.COM/Path",
                  "foo_bar.com", "x.", ".com", "why is the sky blue?", "mailto:a@b.c", "a@b.com"]
    for s in inputs { #expect(PasteText.isURL(s) == (CommandBarCore.url(from: s) != nil), "\(s)") }
  }

  @Test func pasteMenuItemFollowsTheClipboard() {
    let r = Rig()
    defer { r.done() }
    let items: [Value] = [["id": "pasteGo", "title": "Paste and Search", "titleURL": "Paste and Go", "paste": true], ["id": "copy", "title": "Copy Link"]]
    func titles() -> [String] { ContextMenu.build(items, target: NSObject(), action: Selector(("denTestNoop:"))).items.map(\.title) }
    r.clip("  example.com/a  ")
    #expect(titles() == ["Paste and Go", "Copy Link"])
    r.clip("swift concurrency")
    #expect(titles() == ["Paste and Search", "Copy Link"])
    r.clip("two\nlines")
    #expect(titles() == ["Copy Link"])
    r.board.clearContents()
    #expect(titles() == ["Copy Link"])
    #expect(r.h.rt.call("app", "pasteboard") == .object([]))
    r.clip("news.test")
    #expect(r.h.rt.call("app", "pasteboard") == ["text": "news.test", "url": true])
  }

  /// The URL pill's context menu: Paste and Go navigates the selected tab, Paste and Search
  /// searches with the default engine.
  @Test func urlPillPasteAndGo() async throws {
    let r = Rig()
    defer { r.done() }
    _ = r.h.startCommandBar()
    _ = r.h.rt.call("commands", "engines", ["engines": [["keyword": "t", "name": "Test", "url": "https://search.test/?q=%s"]]])
    let id = r.tab("https://start.test/")
    let pill = try #require(r.h.rt.ui.nodeView("tabs.url") as? NodeView)
    let menu = pill.node.list("menu")
    #expect(menu.first?["paste"] == true && menu.contains { $0.str("id") == "share" })
    r.clip("news.test/story")
    let ns = ContextMenu.build(menu, target: NSObject(), action: Selector(("denTestNoop:")))
    #expect(ns.items.first?.title == "Paste and Go")
    r.h.action("tabs.url", "menu", "pasteGo")
    #expect(await wait { r.selectedURL == "https://news.test/story" })
    #expect(r.h.selected == id)
    r.clip("swift concurrency")
    r.h.action("tabs.url", "menu", "pasteGo")
    #expect(await wait { r.selectedURL == "https://search.test/?q=swift+concurrency" }, "\(r.selectedURL)")
    #expect(r.h.selected == id)
  }

  /// The command bar field's own context menu gets the same item, right after Paste.
  @Test func commandBarPasteAndGo() async throws {
    let r = Rig()
    defer { r.done() }
    _ = r.h.startCommandBar()
    let before = r.h.ids("today").count
    r.h.key("cmd+t")
    #expect(r.h.rt.ui.commandBarOpen)
    r.clip("https://news.test/from-bar")
    let menu = NSMenu()
    menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
    menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "")
    let field = r.h.rt.ui.commandBar.input
    let out = try #require(field.textView(NSTextView(), menu: menu, for: NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!, at: 0))
    #expect(out.items.map(\.title) == ["Copy", "Paste", "Paste and Go"])
    let item = out.items[2]
    _ = (item.target as? NSObject)?.perform(item.action, with: item)
    #expect(await wait { r.selectedURL == "https://news.test/from-bar" })
    #expect(r.h.ids("today").count == before + 1 && !r.h.rt.ui.commandBarOpen)
  }

  // MARK: Share

  @Test func shareSheetFromTheURLPillAndTheTabMenu() throws {
    let r = Rig()
    defer { r.done() }
    r.h.startTabs()
    let id = r.tab("https://news.test/a")
    r.h.action("tabs.url", "menu", "share")
    #expect(r.shared.count == 1)
    #expect((r.shared.last?.items.first as? URL)?.absoluteString == "https://news.test/a")
    #expect((r.shared.last?.view as? NodeView)?.nodeId == "tabs.url")
    // The tab's own menu: anchored at its row.
    func find(_ list: [Value]) -> Value? {
      for v in list {
        if v.str("id") == id { return v }
        if let hit = find(v.list("children")) { return hit }
      }
      return nil
    }
    let row = find(r.h.tree("sidebar.today", 0).list("children")) ?? .null
    #expect(row.list("menu").map { $0.str("id") }.contains("share"))
    r.h.action(id, "menu", "share")
    #expect(r.shared.count == 2 && (r.shared.last?.items.first as? URL)?.absoluteString == "https://news.test/a")
    // No anchor on screen: the top of the page.
    #expect(r.h.rt.call("app", "share", ["url": "https://x.test/"]) == .ok)
    #expect(r.shared.last?.view === r.h.rt.window.contentArea)
    #expect(r.h.rt.call("app", "share", ["url": ""]).isErr)
  }

  // MARK: QR code

  @Test func qrCodeIsSharpScannableAndCached() throws {
    let r = Rig()
    defer { r.done() }
    let text = "https://news.test/a?b=1"
    let v = r.h.rt.call("app", "qrCode", ["text": .string(text)])
    let path = try #require(v["path"].string)
    let modules = Int(v["modules"].int ?? 0)
    let rep = try #require(NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path))))
    let scale = rep.pixelsWide / (modules + 8)
    #expect(modules >= 21 && rep.pixelsWide == rep.pixelsHigh && rep.pixelsWide == (modules + 8) * scale && scale >= 8)
    func dark(_ x: Int, _ y: Int) -> Bool { (rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.brightnessComponent ?? 1) < 0.5 }
    #expect(!dark(1, 1) && !dark(4 * scale - 1, 4 * scale - 1))  // quiet zone
    #expect(dark(4 * scale, 4 * scale) && dark(4 * scale + scale / 2, 4 * scale + scale / 2))  // finder pattern corner, no blur
    let img = try #require(CIImage(contentsOf: URL(fileURLWithPath: path)))
    let found = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: nil)?.features(in: img).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    #expect(found == [text])
    #expect(r.h.rt.call("app", "qrCode", ["text": .string(text)])["path"].string == path)
    #expect(r.h.rt.call("app", "qrCode", ["text": ""]).isErr)
  }

  /// "QR Code for This Page" (pagetools): a popover beside the URL pill; Copy Image copies it.
  @Test func qrPopoverCopiesTheImage() async throws {
    let r = Rig()
    defer { r.done() }
    r.h.startTabs()
    _ = r.tab("https://news.test/a")
    let core = PageToolsCore(env: r.h.env)
    core.start()
    core.startNow()
    core.run("pagetools.qrCode")
    #expect(r.h.rt.ui.popoverOpen)
    let panel = try #require(r.h.rt.ui.popover.content as? NodeView)
    #expect(panel.node.str("id") == "pagetools.qr" && panel.node.str("anchor") == "tabs.url" && panel.node.str("subtitle") == "news.test/a")
    #expect(FileManager.default.fileExists(atPath: panel.node.list("children").first?.str("src") ?? ""))
    r.h.action("pagetools.qr.copy", "click")
    #expect(r.board.types?.contains(.png) == true || r.board.types?.contains(.tiff) == true)
    #expect(r.toast == "Copied QR code · news.test/a")
    #expect(!r.h.rt.ui.popoverOpen)
    // Esc or a click outside closes it.
    core.run("pagetools.qrCode")
    r.h.action("pagetools.qr", "dismiss")
    #expect(!r.h.rt.ui.popoverOpen && core.qr == nil)
    // A page without a web address has nothing to share.
    _ = r.tab("about:blank")
    core.run("pagetools.qrCode")
    #expect(!r.h.rt.ui.popoverOpen && r.toast == "This page has no web address to share")
  }

  // MARK: Copy toasts

  @Test func copyToastsSayWhatWasCopied() async throws {
    let r = Rig()
    defer { r.done() }
    _ = r.h.startCommandBar()
    let id = r.tab("https://www.news.test/2026/09/a-very-long-story-title-that-goes-on-and-on?ref=home")
    r.h.key("cmd+shift+c")
    #expect(r.board.string(forType: .string) == "https://www.news.test/2026/09/a-very-long-story-title-that-goes-on-and-on?ref=home")
    #expect(r.toast == "Copied link · news.test/2026/09/a-very-long-story-title-that-g…")
    r.h.action(id, "menu", "copyMarkdown")
    #expect(r.board.string(forType: .string)?.hasPrefix("[") == true)
    #expect(r.toast == "Copied Markdown link · news.test/2026/09/a-very-long-story-title-that-g…")
    _ = r.h.rt.call("commands", "run", ["id": "den.copyURL"])
    #expect(r.toast?.hasPrefix("Copied link · news.test/") == true)
  }

  @Test func copiedShortForms() {
    #expect(Copied.short("https://www.example.com/") == "example.com")
    #expect(Copied.short("http://example.com") == "example.com")
    #expect(Copied.short("https://xn--bcher-kva.de/a?b#c") == "bücher.de/a?b#c")
    #expect(Copied.short("data:text/html;base64,AAAA") == "data:text/html")
    #expect(Copied.short("https://a.test/" + String(repeating: "x", count: 80), max: 20) == "a.test/xxxxxxxxxxxxx…")
    // Never cut inside a character.
    #expect(Copied.clip("aéé", max: 2) == "a…")
    #expect(Copied.clip("short", max: 40) == "short")
    #expect(Copied.text("image", "") == "Copied image")
    #expect(Copied.link("https://news.test/a") == "Copied link · news.test/a")
  }
}
