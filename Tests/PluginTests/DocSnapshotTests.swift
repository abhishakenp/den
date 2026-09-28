import AppKit
import CordisValue
import Foundation
import Testing
import WebKit

@testable import DenHost
@testable import PluginCores

/// Screenshots for docs/screenshots, rendered offscreen from a real runtime and the real plugins
/// (no window ever appears on screen). Pages are local HTML with a real URL as their base, so
/// nothing is fetched. Run with DEN_DOC_SNAPSHOTS=<dir>:
///   DEN_DOC_SNAPSHOTS=$PWD/docs/screenshots scripts/test.sh --filter DocSnapshotTests
@MainActor
@Suite(.serialized, .watchdog, .enabled(if: ProcessInfo.processInfo.environment["DEN_DOC_SNAPSHOTS"] != nil))
struct DocSnapshotTests {
  static var dir: String { ProcessInfo.processInfo.environment["DEN_DOC_SNAPSHOTS"] ?? NSTemporaryDirectory() }

  func until(_ seconds: Double = 15, _ cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
      if cond() { return true }
      try? await Task.sleep(for: .milliseconds(40))
    }
    return cond()
  }

  /// A runtime with spaces + tabs in `appearance`, Today cleared down to one local page.
  func scene(_ appearance: String) async -> (Harness, String) {
    let h = Harness()
    h.startTabs()
    for s in h.spaceIds { h.rt.call("spaces", "update", ["id": .string(s), "theme": ["appearance": .string(appearance)]]) }
    let dark = appearance == "dark"
    let src = h.tabs("open", ["url": "https://webkit.org/blog/"])["id"].string!
    h.tabs("clearToday")
    load(h, src, title: "WebKit Blog", url: "https://webkit.org/blog/", dark: dark,
         body: "News about WebKit, the web browser engine used by Safari. Command-click a link and it opens in the background, grouped with this tab.")
    return (h, src)
  }

  func load(_ h: Harness, _ id: String, title: String, url: String, dark: Bool, body: String) {
    let bg = dark ? "#18171c" : "#ffffff", fg = dark ? "#e8e6ee" : "#222", sub = dark ? "#b4b1bd" : "#444"
    let html = """
      <html><head><title>\(title)</title><style>body{font:16px -apple-system;margin:0;padding:64px 72px;background:\(bg);color:\(fg)}
      h1{font-size:30px;margin:0 0 16px}p{line-height:1.5;max-width:560px;color:\(sub)}a{color:#4f7cff}</style></head>
      <body><h1>\(title)</h1><p>\(body)</p><p><a href="https://developer.apple.com/safari/">Safari for developers</a> ·
      <a href="https://webkit.org/status/">Feature status</a></p></body></html>
      """
    h.rt.webviews.materialize(id)?.loadHTMLString(html, baseURL: URL(string: url))
  }

  func write(_ h: Harness, _ name: String) async {
    h.rt.window.window.contentView?.layoutSubtreeIfNeeded()
    try? await Task.sleep(for: .milliseconds(700))
    let path = (Self.dir as NSString).appendingPathComponent(name + ".png")
    let ok = await Snapshotter.write(h.rt.window.window, to: path)
    print("snapshot \(name): \(ok ? path : "FAILED")")
  }

  @Test func groupsAndCollapsedFolders() async {
    for appearance in ["light", "dark"] {
      let suffix = appearance == "dark" ? "-dark" : ""
      let (h, src) = await scene(appearance)
      #expect(await until { h.rt.webviews.record(src)?.webView?.title == "WebKit Blog" })
      // ⌘-click two links: one group, named from the two sites.
      h.rt.plugins.emit("webviews.newWindow", ["id": .string(src), "url": "https://developer.apple.com/safari/", "background": true])
      h.rt.plugins.emit("webviews.newWindow", ["id": .string(src), "url": "https://webkit.org/status/", "background": true])
      let kids = h.tabs("list")["today"][0].list("children").map { $0.s("id") }
      h.tabs("rename", ["id": .string(kids[1]), "title": "Safari for Developers"])
      h.tabs("rename", ["id": .string(kids[2]), "title": "WebKit Feature Status"])
      await write(h, "group-created" + suffix)
      // Collapsed: the header keeps the active tab under it.
      let fid = h.tabs("list")["today"][0].s("id")
      h.action(fid, "toggle")
      await write(h, "group-collapsed" + suffix)
    }
  }

  @Test func crashPageAndDialogLoop() async throws {
    for appearance in ["light", "dark"] {
      let suffix = appearance == "dark" ? "-dark" : ""
      let (h, src) = await scene(appearance)
      let w = try #require(h.rt.webviews.record(src)?.webView)
      #expect(await until { w.title == "WebKit Blog" })
      #expect(PageSafetyTests.crash(w))
      #expect(await until { w.title == "This page crashed" })
      await write(h, "crash-page" + suffix)
      _ = h.rt.call("webviews", "reload", ["id": .string(src)])
      // loadHTMLString pages come back as the page again only through the scene's loader.
      load(h, src, title: "WebKit Blog", url: "https://webkit.org/blog/", dark: appearance == "dark", body: "A page that keeps asking.")
      #expect(await until { w.title == "WebKit Blog" })
      let prompts = try #require(h.rt.webviews.prompts)
      // A page stuck in alert() can't be snapshotted by WebKit (it waits on the page): take the
      // picture first and stand it in for the page while the dialog is captured.
      try? await Task.sleep(for: .milliseconds(500))
      let still: NSImage? = await withCheckedContinuation { c in w.takeSnapshot(with: nil) { img, _ in c.resume(returning: img) } }
      w.evaluateJavaScript("for (let i = 0; i < 6; i++) alert('Are you still there?'); 1") { _, _ in }
      for _ in 0..<3 {
        #expect(await until { prompts.current != nil })
        prompts.press("ok")
      }
      #expect(await until { prompts.current?.tree["checkbox"].isNull == false })
      let stand = NSImageView(frame: w.frame)
      stand.image = still
      stand.imageScaling = .scaleAxesIndependently
      w.superview?.addSubview(stand, positioned: .above, relativeTo: w)
      w.isHidden = true
      await write(h, "dialog-loop" + suffix)
      w.isHidden = false
      stand.removeFromSuperview()
      prompts.press("ok", fields: [WebPrompts.checkedKey: "1"])
    }
  }

  /// The tab menu, drawn offscreen from the items the tabs plugin sends (a native menu is its own
  /// on-screen window, so it can't be captured without showing it). Left: as it opens; right:
  /// with ⌥ held, where the alternates replace their primaries.
  @Test func tabMenuWithShortcuts() async throws {
    for appearance in ["light", "dark"] {
      let (h, src) = await scene(appearance)
      let items = h.tree("sidebar.today", 0).list("children").first { $0.s("id") == src }?.list("menu") ?? []
      let view = MenuSketch(items: items, dark: appearance == "dark")
      let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: rep)
      let path = (Self.dir as NSString).appendingPathComponent("tab-menu-shortcuts" + (appearance == "dark" ? "-dark" : "") + ".png")
      try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
      print("snapshot tab-menu-shortcuts: \(path)")
    }
  }
}

/// Two menus side by side, laid out like macOS's: 22 pt rows, SF Symbol, title, shortcut glyphs
/// right-aligned, separators.
@MainActor
final class MenuSketch: NSView {
  let items: [Value]
  let dark: Bool
  override var isFlipped: Bool { true }
  init(items: [Value], dark: Bool) {
    self.items = items
    self.dark = dark
    super.init(frame: NSRect(x: 0, y: 0, width: 620, height: 40 + CGFloat(items.count) * 22))
    appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
  }
  required init?(coder: NSCoder) { fatalError() }

  static func glyphs(_ chord: String) -> String {
    guard !chord.isEmpty else { return "" }
    let parts = chord.split(separator: "+").map(String.init)
    var s = ""
    if parts.contains("ctrl") { s += "⌃" }
    if parts.contains("opt") { s += "⌥" }
    if parts.contains("shift") { s += "⇧" }
    if parts.contains("cmd") { s += "⌘" }
    return s + (parts.last ?? "").uppercased()
  }

  override func draw(_ dirtyRect: NSRect) {
    (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
    bounds.fill()
    for (col, option) in [false, true].enumerated() {
      let x0 = 20 + CGFloat(col) * 300
      let shown = items.enumerated().filter { i, it in
        if option { return !(i + 1 < items.count && items[i + 1].flag("alternate")) }
        return !it.flag("alternate")
      }.map(\.1)
      let h = CGFloat(shown.reduce(0) { $0 + ($1.flag("separator") ? 11 : 22) }) + 10
      let panel = NSRect(x: x0, y: 28, width: 280, height: h)
      let path = NSBezierPath(roundedRect: panel, xRadius: 8, yRadius: 8)
      (dark ? NSColor(white: 0.2, alpha: 1) : NSColor(white: 0.99, alpha: 1)).setFill()
      path.fill()
      (dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.12)).setStroke()
      path.stroke()
      let caption = option ? "Holding ⌥" : "Right-click"
      caption.draw(at: NSPoint(x: x0 + 4, y: 8), withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor])
      var y = panel.minY + 5
      let text: NSColor = dark ? NSColor(white: 1, alpha: 0.9) : NSColor(white: 0, alpha: 0.85)
      for it in shown {
        if it.flag("separator") {
          (dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.1)).setFill()
          NSRect(x: panel.minX + 10, y: y + 5, width: panel.width - 20, height: 1).fill()
          y += 11
          continue
        }
        if it.str("icon").hasPrefix("sf:"), let img = NSImage(systemSymbolName: String(it.str("icon").dropFirst(3)), accessibilityDescription: nil)?
          .withSymbolConfiguration(.init(pointSize: 12, weight: .regular).applying(.init(paletteColors: [text]))) {
          img.draw(in: NSRect(x: panel.minX + 12, y: y + 4, width: 14, height: 14))
        }
        it.str("title").draw(at: NSPoint(x: panel.minX + 34, y: y + 3), withAttributes: [.font: NSFont.menuFont(ofSize: 13), .foregroundColor: text])
        let k = Self.glyphs(it.str("key"))
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]
        let kw = (k as NSString).size(withAttributes: attrs).width
        k.draw(at: NSPoint(x: panel.maxX - 14 - kw, y: y + 3), withAttributes: attrs)
        y += 22
      }
    }
  }
}
