import AppKit
import CordisValue
import Foundation
import Testing

@testable import DenHost

/// Hover intent timing and the `hoverCard` slot.
@MainActor
@Suite(.serialized)
struct HoverCardTests {
  /// Manual clock: timers fire only when `advance` passes their deadline.
  final class Clock {
    var now: Double = 0
    var timers: [(at: Double, id: Int, f: @MainActor () -> Void)] = []
    var nextId = 0
    func schedule(_ ms: Int, _ f: @escaping @MainActor () -> Void) -> () -> Void {
      nextId += 1
      let id = nextId
      timers.append((now + Double(ms), id, f))
      return { [weak self] in self?.timers.removeAll { $0.id == id } }
    }
    @MainActor func advance(_ ms: Double) {
      let end = now + ms
      while let t = timers.filter({ $0.at <= end }).min(by: { $0.at < $1.at }) {
        timers.removeAll { $0.id == t.id }
        now = t.at
        t.f()
      }
      now = end
    }
  }

  func intent(_ c: Clock) -> (HoverIntent, () -> [String]) {
    let i = HoverIntent(schedule: { ms, f in c.schedule(ms, f) }, now: { c.now })
    var log: [String] = []
    i.onShow = { log.append("show:" + $0) }
    i.onHide = { log.append("hide:" + $0) }
    return (i, { log })
  }

  @Test func firstCardWaitsForTheDwellAndLeavingEarlyCancelsIt() {
    let c = Clock()
    let (i, log) = intent(c)
    i.enter("a")
    c.advance(Double(i.delayMs) - 10)
    #expect(log().isEmpty)
    i.exit("a")
    c.advance(1000)
    #expect(log().isEmpty)  // passed over quickly: nothing
    i.enter("a")
    c.advance(Double(i.delayMs))
    #expect(log() == ["show:a"])
    #expect(i.anchor == "a")
  }

  @Test func movingBetweenRowsSwapsInstantly() {
    let c = Clock()
    let (i, log) = intent(c)
    i.enter("a")
    c.advance(Double(i.delayMs))
    i.exit("a")
    i.enter("b")  // same turn as the exit: no dwell, no hide
    #expect(log() == ["show:a", "show:b"])
    c.advance(2)
    i.exit("b")
    c.advance(Double(i.graceMs) - 1)
    i.enter("c")
    #expect(log() == ["show:a", "show:b", "show:c"])
  }

  @Test func mouseOutClosesAfterGraceUnlessThePointerReachesTheCard() {
    let c = Clock()
    let (i, log) = intent(c)
    i.enter("a")
    c.advance(Double(i.delayMs))
    i.exit("a")
    c.advance(Double(i.graceMs) / 2)
    i.enterCard()  // crossed the gap onto the card
    c.advance(1000)
    #expect(log() == ["show:a"])
    i.exitCard()
    c.advance(Double(i.graceMs))
    #expect(log() == ["show:a", "hide:a"])
    #expect(i.anchor == nil)
    // Warm: right after a close the next row shows without the dwell.
    c.advance(Double(i.warmMs) / 2)
    i.enter("b")
    #expect(log().last == "show:b")
    i.hide()
    c.advance(Double(i.warmMs) + 1)
    i.enter("c")
    #expect(log().last == "hide:b")  // cold again: dwell first
    c.advance(Double(i.delayMs))
    #expect(log().last == "show:c")
  }

  @Test func clickingARowClosesItsCardUntilThePointerLeaves() {
    let c = Clock()
    let (i, log) = intent(c)
    i.enter("a")
    c.advance(Double(i.delayMs))
    i.press("a")
    #expect(log() == ["show:a", "hide:a"])
    i.enter("a")  // still over the clicked row (tracking re-enter)
    c.advance(2000)
    #expect(log().count == 2)
    i.exit("a")
    i.enter("b")
    c.advance(Double(i.delayMs))  // a click isn't a warm close: dwell again
    #expect(log().last == "show:b")
  }

  // MARK: Slot

  static func runtime() -> DenRuntime { ServiceTests.runtime() }

  static func seed(_ rt: DenRuntime) {
    _ = rt.call("ui", "set", ["slot": "sidebar.today", "tree": ["type": "list", "id": "today", "children": [
      ["type": "tabRow", "id": "t1", "title": "Example", "icon": "sf:globe"],
      ["type": "tabRow", "id": "t2", "title": "Pull request", "icon": "sf:globe"],
      ["type": "newTabRow", "id": "newtab"],
    ]]])
    rt.window.window.contentView?.layoutSubtreeIfNeeded()
  }

  static func node(_ id: String, _ rt: DenRuntime) -> NodeView? {
    func find(_ v: NSView) -> NodeView? {
      if let n = v as? NodeView, n.nodeId == id { return n }
      for s in v.subviews { if let f = find(s) { return f } }
      return nil
    }
    return find(rt.ui.sidebarView)
  }

  static func card(_ anchor: String, title: String = "Fix the parser") -> Value {
    ["type": "hoverCard", "anchor": .string(anchor), "icon": "sf:globe", "title": .string(title), "subtitle": "github.com",
     "badges": [["text": "2 failing", "style": "failure", "icon": "sf:xmark.circle.fill"], ["text": "Conflicts", "style": "attention"]],
     "sections": [["title": "Checks", "rows": [["id": "c1", "title": "build", "icon": "sf:xmark.circle.fill", "status": "failure", "accessory": "Failed", "url": "https://example.com/c1"]]]],
     "actions": [["id": "join", "title": "Join", "style": "primary", "url": "https://meet.example.com/x"]]]
  }

  @Test func hoverEmitsForTheRowAndTheCardShowsBesideTheSidebar() async throws {
    let rt = Self.runtime()
    rt.window.window.orderFront(nil)
    Self.seed(rt)
    rt.ui.hoverCard.intent.delayMs = 10
    var actions: [Value] = []
    rt.host.on("ui.action") { actions.append($0) }
    // Rows that don't preview (new tab row) never start intent.
    rt.ui.hoverCard.entered(try #require(Self.node("newtab", rt)))
    #expect(rt.ui.hoverCard.intent.pendingId == nil)
    rt.ui.hoverCard.entered(try #require(Self.node("t2", rt)))
    try await Task.sleep(for: .milliseconds(80))
    #expect(actions.contains { $0.str("id") == "t2" && $0.str("action") == "hover" })
    // A card for another row is dropped; the hovered row's card shows.
    _ = rt.call("ui", "set", ["slot": "hoverCard", "tree": Self.card("t1")])
    #expect(!rt.ui.hoverCard.visible)
    _ = rt.call("ui", "set", ["slot": "hoverCard", "tree": Self.card("t2")])
    #expect(rt.ui.hoverCard.visible)
    #expect(rt.ui.hoverCard.lastShownMs != nil)
    #expect(rt.call("ui", "get")["overlays"].array?.contains("hoverCard") == true)
    let card = try #require(rt.ui.hoverCard.card)
    let sidebarRight = rt.window.sidebar.frame.maxX
    #expect(card.frame.minX == (sidebarRight + Tokens.hoverCardGap).rounded())
    #expect(card.frame.width == Tokens.hoverCardWidth)
    #expect(card.frame.height > 150)  // header + badges + a section + a button
    #expect(card.badges.count == 2 && card.sections.count == 1 && card.buttons.count == 1)
    // A button emits its action with the url, and closes the card.
    card.buttons[0].action()
    #expect(actions.contains { $0.str("id") == "hoverCard" && $0.str("action") == "action" && $0["value"].str("url") == "https://meet.example.com/x" })
    #expect(rt.ui.hoverCard.intent.anchor == nil)
    #expect(actions.contains { $0.str("id") == "hoverCard" && $0.str("action") == "close" && $0["value"].str("anchor") == "t2" })
  }

  @Test func overlaysAndNullTreesCloseTheCard() async throws {
    let rt = Self.runtime()
    rt.window.window.orderFront(nil)
    Self.seed(rt)
    rt.ui.hoverCard.intent.delayMs = 5
    rt.ui.hoverCard.entered(try #require(Self.node("t1", rt)))
    try await Task.sleep(for: .milliseconds(50))
    _ = rt.call("ui", "set", ["slot": "hoverCard", "tree": Self.card("t1")])
    #expect(rt.ui.hoverCard.intent.anchor == "t1")
    _ = rt.call("ui", "set", ["slot": "overlay.library", "tree": ["type": "library", "id": "archive", "items": []]])
    #expect(rt.ui.hoverCard.intent.anchor == nil)
    _ = rt.call("ui", "set", ["slot": "overlay.library", "tree": nil])
    rt.ui.hoverCard.exited(try #require(Self.node("t1", rt)))
    rt.ui.hoverCard.entered(try #require(Self.node("t1", rt)))
    try await Task.sleep(for: .milliseconds(50))
    _ = rt.call("ui", "set", ["slot": "hoverCard", "tree": Self.card("t1")])
    #expect(rt.ui.hoverCard.intent.anchor == "t1")
    _ = rt.call("ui", "set", ["slot": "hoverCard", "tree": nil])
    #expect(rt.ui.hoverCard.intent.anchor == nil)
  }

  @Test func snapshotWritesASmallJPEG() async throws {
    let img = NSImage(size: NSSize(width: 1200, height: 800), flipped: false) { r in
      NSColor.systemTeal.setFill()
      r.fill()
      return true
    }
    let data = try #require(WebViewsService.encode(img, width: 320, jpeg: true))
    let rep = try #require(NSBitmapImageRep(data: data))
    #expect(rep.pixelsWide == 640 && rep.pixelsHigh == 427)
    #expect(data.count < 60_000)
  }
}
