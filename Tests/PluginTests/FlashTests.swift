import AppKit
import CordisValue
import Foundation
import Testing
import WebKit

@testable import DenHost
@testable import PluginCores

/// No white flash on a tab switch or load, measured with snapshots: the window rendered by
/// `Snapshotter` (den's own layers plus WebKit's snapshot of each page, what `--snapshot` uses)
/// right after a dark page is put on screen and while it loads, in dark appearance. Prints the
/// share of near-white pixels in the content card per snapshot.
@MainActor
@Suite(.serialized)
struct FlashTests {
  static let dark = "<html style='background:#121212'><title>Dark</title><body style='color:#eee;font:16px -apple-system'>A dark page</body></html>"

  func until(_ seconds: Double = 15, _ cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
      if cond() { return true }
      try? await Task.sleep(for: .milliseconds(30))
    }
    return cond()
  }

  /// Share of near-white pixels (every channel > 92%) inside `card`, in a window snapshot.
  static func whiteShare(_ rep: NSBitmapImageRep, card: NSView, window: NSWindow) -> Double {
    let f = card.convert(card.bounds, to: nil)
    let scale = CGFloat(rep.pixelsWide) / (window.contentView?.superview?.bounds.width ?? 1)
    var white = 0, n = 0
    for y in stride(from: Int(f.minY * scale), to: Int(f.maxY * scale), by: 6) {
      for x in stride(from: Int(f.minX * scale), to: Int(f.maxX * scale), by: 6) {
        guard let c = rep.colorAt(x: x, y: rep.pixelsHigh - 1 - y)?.usingColorSpace(.sRGB) else { continue }
        if c.redComponent > 0.92 && c.greenComponent > 0.92 && c.blueComponent > 0.92 { white += 1 }
        n += 1
      }
    }
    return n == 0 ? 0 : Double(white) / Double(n)
  }

  @Test(.timeLimit(.minutes(3))) func snapshotsDuringTheSwitchHaveNoWhite() async throws {
    let h = Harness()
    let mock = MockServices()
    try mock.start()
    defer { mock.stop() }
    mock.page("/dark", Self.dark)
    h.rt.window.window.appearance = NSAppearance(named: .darkAqua)
    let a = h.rt.call("webviews", "create", ["id": "flash-b", "url": .string(mock.base + "/dark")])["id"].string!
    _ = h.rt.call("content", "show", ["panes": [.string(a)]])
    var worst = 0.0
    var line = "flash.snapshots"
    for _ in 0..<6 {
      guard let rep = await Snapshotter.capture(h.rt.window.window), let card = h.rt.content.card(a) else { continue }
      let share = Self.whiteShare(rep, card: card, window: h.rt.window.window)
      worst = max(worst, share)
      line += String(format: " %.3f", share)
      try? await Task.sleep(for: .milliseconds(60))
    }
    print(line + String(format: " worst=%.3f", worst))
    #expect(worst < 0.05)
  }

  @Test(.timeLimit(.minutes(3))) func theOldPageStaysUntilTheNewOnePaints() async throws {
    let h = Harness()
    let mock = MockServices()
    try mock.start()
    defer { mock.stop() }
    mock.page("/a", Self.dark)
    mock.page("/b", Self.dark.replacingOccurrences(of: "<title>Dark", with: "<title>Other"))
    let a = h.rt.call("webviews", "create", ["id": "hold-a", "url": .string(mock.base + "/a")])["id"].string!
    let b = h.rt.call("webviews", "create", ["id": "hold-b", "url": .string(mock.base + "/b")])["id"].string!
    _ = h.rt.call("content", "show", ["panes": [.string(a)]])
    #expect(await until { h.rt.webviews.record(a)?.painted == true })
    // Switch to a page that has never drawn: the old one stays over it (and takes no clicks)…
    _ = h.rt.call("content", "show", ["panes": [.string(b)]])
    #expect(h.rt.content.held == a)
    #expect(h.rt.webviews.record(a)?.webView?.window != nil)
    // …the new one shows no background of its own until it paints, then the old one goes.
    #expect(h.rt.webviews.record(b)?.webView?.value(forKey: "drawsBackground") as? Bool == false || h.rt.webviews.record(b)?.painted == true)
    #expect(await until { h.rt.webviews.record(b)?.painted == true })
    #expect(await until { h.rt.content.held == nil })
    #expect(h.rt.webviews.record(b)?.webView?.value(forKey: "drawsBackground") as? Bool == true)
    // A painted page (switching back) is shown at once: nothing is held.
    _ = h.rt.call("content", "show", ["panes": [.string(a)]])
    #expect(h.rt.content.held == nil)
  }
}
