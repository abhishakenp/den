import AppKit
import CordisValue
import Foundation
import DenTestSupport
import Testing

@testable import DenHost

/// Hover intent timing, `ui.card` placement and motion, card shortcuts, the generic card nodes and
/// the card tokens (docs/reference/dia-ui-spec.md §2).
@MainActor
@Suite(.serialized, .watchdog)
struct CardTests {
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

  // MARK: Timing (spec §2.4)

  @Test func defaultsAreDiasMeasuredTimings() {
    #expect(Tokens.cardRowDelayMs == 700 && Tokens.cardTileDelayMs == 300)
    #expect(Tokens.cardGraceMs == 200 && Tokens.cardInMs == 180 && Tokens.cardOutMs == 100)
    #expect(Tokens.cardScale == 0.93 && Tokens.cardRadius == 12 && Tokens.cardGap == 3)
    #expect(Tokens.cardMinWidth == 170 && Tokens.cardMaxWidth == 200)
  }

  @Test func eachNodeDwellsForItsOwnDelayAndLeavingEarlyCancels() {
    let c = Clock()
    let (i, log) = intent(c)
    i.enter("row", delayMs: 700)
    c.advance(699)
    #expect(log().isEmpty)
    i.exit("row")
    c.advance(2000)
    #expect(log().isEmpty && i.idle)  // passed over: nothing, and no timer left behind
    i.enter("tile", delayMs: 300)
    c.advance(300)
    #expect(log() == ["show:tile"])
  }

  @Test func swapIsImmediateByDefaultAndWaitsWithRedwell() {
    let c = Clock()
    let (i, log) = intent(c)
    i.enter("a", delayMs: 700)
    c.advance(700)
    i.exit("a")
    i.enter("b", delayMs: 700)  // same turn: the old card is replaced at once (Arc)
    #expect(log() == ["show:a", "show:b"])
    // Dia: the old card stays until the new row's own dwell completes, then hard-cuts.
    i.redwell = true
    i.exit("b")
    i.enter("c", delayMs: 700)
    c.advance(400)
    #expect(log().last == "show:b" && i.anchor == "b")  // no grace close meanwhile
    c.advance(300)
    #expect(log().last == "show:c")
    // Leaving before the dwell: the old card closes after the grace.
    i.exit("c")
    i.enter("d", delayMs: 700)
    c.advance(100)
    i.exit("d")
    c.advance(Double(i.graceMs))
    #expect(log().last == "hide:c")
  }

  @Test func mouseOutClosesAfterGraceUnlessThePointerReachesTheCard() {
    let c = Clock()
    let (i, log) = intent(c)
    i.enter("a")
    c.advance(Double(i.delayMs))
    i.exit("a")
    c.advance(Double(i.graceMs) / 2)
    i.enterCard()  // crossed the 3 pt gap onto the card
    c.advance(1000)
    #expect(log() == ["show:a"])
    i.exitCard()
    c.advance(Double(i.graceMs) - 1)
    #expect(log() == ["show:a"])
    c.advance(1)
    #expect(log() == ["show:a", "hide:a"])
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
    i.enter("a")
    c.advance(2000)
    #expect(log().count == 2)
    i.exit("a")
    i.enter("b")
    c.advance(Double(i.delayMs))  // a click isn't a warm close: dwell again
    #expect(log().last == "show:b")
  }

  // MARK: Placement (spec §2.2, §3.1)

  @Test func placementFollowsTheSpec() {
    let b = NSRect(x: 0, y: 0, width: 1280, height: 800)
    let size = NSSize(width: 200, height: 109)
    // Beside a row: x = max(row maxX, sidebar edge) + 3, vertically centered (row 238–277 → 204–313).
    let row = NSRect(x: -1, y: 238, width: 192, height: 39)
    let f = CardPlacement.frame(.trailing, anchor: row, size: size, bounds: b)
    #expect(f.minX == 194 && f.minY == 203)  // center 257.5 (Dia's card centre measured 258.5)
    #expect(CardPlacement.frame(.trailing, anchor: NSRect(x: 8, y: 238, width: 170, height: 39), size: size, bounds: b, clearX: 190).minX == 193)
    // Pinned tile: hangs below-right, overlapping the tile by 3 pt.
    let tile = NSRect(x: 5, y: 53, width: 176, height: 39)
    let t = CardPlacement.frame(.tile, anchor: tile, size: size, bounds: b)
    #expect(t.minX == 178 && t.minY == 89)
    // Below a link: left-aligned, 8 pt down; flips above near the bottom; always inside the window.
    let link = NSRect(x: 600, y: 300, width: 80, height: 18)
    #expect(CardPlacement.frame(.below, anchor: link, size: size, bounds: b).origin == NSPoint(x: 600, y: 326))
    let low = CardPlacement.frame(.below, anchor: NSRect(x: 600, y: 760, width: 80, height: 18), size: size, bounds: b)
    #expect(low.maxY == 752)
    let right = CardPlacement.frame(.below, anchor: NSRect(x: 1250, y: 100, width: 20, height: 18), size: size, bounds: b)
    #expect(right.maxX == 1272)
  }

  // MARK: ui.card with the real renderer

  static func runtime() -> DenRuntime { ServiceTests.runtime() }

  static func seed(_ rt: DenRuntime) {
    _ = rt.call("ui", "set", ["slot": "sidebar.today", "tree": ["type": "list", "id": "today", "children": [
      ["type": "tabRow", "id": "t1", "title": "Example", "icon": "sf:globe", "hoverIntent": 10],
      ["type": "tabRow", "id": "t2", "title": "Pull request", "icon": "sf:globe", "hoverIntent": 10],
      ["type": "newTabRow", "id": "newtab"],
    ]]])
    rt.window.window.contentView?.layoutSubtreeIfNeeded()
  }

  static func node(_ id: String, _ rt: DenRuntime) -> NodeView? { rt.ui.findNode(id, in: rt.ui.sidebarView) }

  /// A Dia tab card built from generic nodes only.
  static func tabCard(_ title: String, actions: Int = 4, shortcut: String = "cmd+d") -> Value {
    var acts: [Value] = []
    for n in 0..<actions {
      acts.append(["type": "action", "id": .string("act\(n)"), "icon": "sf:pin", "tooltip": "Pin Tab", "shortcut": .string(n == 0 ? shortcut : "")])
    }
    var kids: [Value] = [["type": "stack", "padding": [15, 14, 0, 13], "children": [
      ["type": "label", "text": .string(title), "weight": "semibold", "lines": 2],
      ["type": "label", "text": "example.com", "tone": "secondary", "lineHeight": 18],
    ]]]
    if actions > 0 {
      kids.append(["type": "spacer", "height": 6])
      kids.append(["type": "stack", "axis": "h", "spacing": 2, "padding": [0, 3, 0, 3], "distribute": "equal", "height": 34, "children": .array(acts)])
    }
    return ["type": "stack", "padding": [0, 0, actions > 0 ? 3 : 15, 0], "children": .array(kids)]
  }

  @Test func hoverIntentNodesEmitHoverAndTheCardShowsBesideTheSidebar() async throws {
    let rt = Self.runtime()
    Self.seed(rt)
    var actions: [Value] = []
    rt.host.on("ui.action") { actions.append($0) }
    // A node without `hoverIntent` never starts intent.
    rt.ui.cards.entered(try #require(Self.node("newtab", rt)))
    #expect(rt.ui.cards.intent.pendingId == nil)
    rt.ui.cards.entered(try #require(Self.node("t2", rt)))
    #expect(rt.ui.cards.intent.pendingId == "t2")
    #expect(await Wait.until("the hover intent for t2") { actions.contains { $0.str("id") == "t2" && $0.str("action") == "hover" } })
    #expect(actions.contains { $0.str("id") == "t2" && $0.str("action") == "hover" })
    // A card for another node is stale and dropped; the hovered node's card shows.
    #expect(rt.call("ui", "card", ["id": "c", "anchor": "t1", "tree": Self.tabCard("Example Domain")])["shown"] == false)
    #expect(!rt.ui.cards.visible)
    #expect(rt.call("ui", "card", ["id": "c", "anchor": "t2", "tree": Self.tabCard("Example Domain")])["shown"] == true)
    #expect(rt.ui.cards.visible && rt.ui.cards.lastShownMs != nil)
    #expect(rt.call("ui", "get")["cards"] == ["c"])
    let card = try #require(rt.ui.cards.card("c"))
    let sidebarRight = rt.window.overlays.convert(NSPoint(x: rt.window.sidebar.frame.maxX, y: 0), from: rt.window.sidebar.superview).x
    #expect(card.frame.minX == (sidebarRight + Tokens.cardGap).rounded())
    let row = try #require(rt.ui.anchorFrame("t2"))
    #expect(abs(card.frame.midY - row.midY) <= 1)
    // Dia's measured sizes: a short 1-line title → 170 × 93 (spec §2.3).
    #expect(card.frame.width == 170 && card.frame.height == 93)
    #expect(card.layer?.animation(forKey: "cardIn") != nil)
    // A 2-line title: 200 wide (clamped), 109 tall; no actions (a New Tab): 65.
    _ = rt.call("ui", "card", ["id": "c", "anchor": "t2", "tree": Self.tabCard("A very long page title that has to wrap onto a second line in the card")])
    #expect(card.frame.width == 200 && card.frame.height == 109)
    _ = rt.call("ui", "card", ["id": "c", "anchor": "t2", "tree": Self.tabCard("New Tab", actions: 0)])
    #expect(card.frame.height == 65)
    // Swapping content is a hard cut: no new entrance animation on the same card.
    card.layer?.removeAllAnimations()
    _ = rt.call("ui", "card", ["id": "c", "anchor": "t2", "tree": Self.tabCard("Example Domain")])
    #expect(card.layer?.animation(forKey: "cardIn") == nil)
    // Equal-width buttons, 2 pt apart, inset 3 pt: 4 on a 170 card are 39 wide.
    let buttons = card.shortcuts()
    #expect(buttons.count == 1 && buttons[0].frame.width == 39 && buttons[0].frame.height == 34)
    // Closing: the intent closes it and tells the plugin.
    _ = rt.call("ui", "card", ["id": "c", "tree": nil])
    #expect(rt.ui.cards.intent.anchor == nil)
    #expect(actions.contains { $0.str("id") == "c" && $0.str("action") == "close" && $0["value"].str("anchor") == "t2" })
  }

  @Test func cardShortcutsActOnTheCardOnlyWhileItShows() async throws {
    let rt = Self.runtime()
    Self.seed(rt)
    var actions: [Value] = []
    rt.host.on("ui.action") { actions.append($0) }
    #expect(!rt.ui.cards.keysActive)
    rt.ui.cards.entered(try #require(Self.node("t1", rt)))
    #expect(await Wait.until("the hover intent for t1") { rt.ui.cards.intent.anchor == "t1" })
    _ = rt.call("ui", "card", ["id": "c", "anchor": "t1", "tree": Self.tabCard("Example", shortcut: "cmd+shift+c")])
    #expect(rt.ui.cards.keysActive)
    #expect(!rt.ui.cards.press(chord: "cmd+d"))
    #expect(rt.ui.cards.press(chord: "shift+cmd+c"))  // recorded order differs; same chord
    #expect(actions.contains { $0.str("id") == "act0" && $0.str("action") == "click" })
    let button = try #require(rt.ui.cards.card("c")?.shortcuts().first)
    #expect(button.tooltipText == "Pin Tab  ⇧⌘C")
    rt.ui.cards.hideAll()
    #expect(!rt.ui.cards.keysActive)
    #expect(CardController.normalized("ctrl+shift+=") == CardController.normalized("shift+ctrl++"))
  }

  @Test func freeCardsCloseAfterGraceButNotUnderThePointer() async throws {
    let rt = Self.runtime()
    Self.seed(rt)
    var actions: [Value] = []
    rt.host.on("ui.action") { actions.append($0) }
    let rect: Value = ["x": 600, "y": 300, "w": 80, "h": 18]
    _ = rt.call("ui", "card", ["id": "link", "rect": rect, "tree": Self.tabCard("Link"), "width": 300])
    let card = try #require(rt.ui.cards.card("link"))
    #expect(card.frame.width == 300)
    let a = rt.ui.cards.windowRect(NSRect(x: 600, y: 300, width: 80, height: 18))
    #expect(card.frame.minX == a.minX && card.frame.minY == a.maxY + Tokens.cardBelowGap)
    // Pointer on the card: a close request waits for it to leave.
    card.pointerInside = true
    _ = rt.call("ui", "card", ["id": "link", "tree": nil, "graceMs": 0])
    try await Task.sleep(for: .milliseconds(50))
    #expect(rt.ui.cards.visible)
    card.pointerInside = false
    card.onHover(false)
    try await Task.sleep(for: .milliseconds(Tokens.cardGraceMs + 150))
    #expect(!rt.ui.cards.visible)
    #expect(actions.contains { $0.str("id") == "link" && $0.str("action") == "close" })
    // A new tree during the grace keeps it.
    _ = rt.call("ui", "card", ["id": "link", "rect": rect, "tree": Self.tabCard("Link")])
    _ = rt.call("ui", "card", ["id": "link", "tree": nil])
    _ = rt.call("ui", "card", ["id": "link", "rect": rect, "tree": Self.tabCard("Other link")])
    try await Task.sleep(for: .milliseconds(Tokens.cardGraceMs + 100))
    #expect(rt.ui.cards.visible)
  }

  @Test func overlaysCloseCards() async throws {
    let rt = Self.runtime()
    Self.seed(rt)
    rt.ui.cards.entered(try #require(Self.node("t1", rt)))
    #expect(await Wait.until("the hover intent for t1") { rt.ui.cards.intent.anchor == "t1" })
    _ = rt.call("ui", "card", ["id": "c", "anchor": "t1", "tree": Self.tabCard("Example")])
    #expect(rt.ui.cards.intent.anchor == "t1")
    _ = rt.call("ui", "set", ["slot": "overlay.library", "tree": ["type": "library", "id": "archive", "items": []]])
    #expect(rt.ui.cards.intent.anchor == nil && !rt.ui.cards.visible)
  }

  // MARK: Nodes

  @Test func genericNodesMeasureAndDraw() throws {
    let rt = Self.runtime()
    let r = rt.ui.renderer!
    let meter = r.make(["type": "meter", "segments": [["value": 2, "tone": "success"], ["value": 1, "tone": "warning"], ["value": 2, "tone": "danger"]]])
    #expect(meter.height(for: 264) == 6)
    let note = r.make(["type": "note", "id": "n", "text": "PR / build (macOS) / test"])
    #expect(note.height(for: 264) == 22)
    let pill = r.make(["type": "action", "id": "p", "variant": "pill", "title": "Show comments", "tone": "strong"])
    #expect(pill.height(for: 100) == 32 && (pill.fitWidth ?? 0) > 100)
    let runs = r.make(["type": "label", "runs": [["text": "+1521", "tone": "add", "weight": "semibold"], ["text": " −36", "tone": "del"], ["text": " · 22 files"]]])
    #expect((runs as? LabelNode)?.label.attributedStringValue.string == "+1521 −36 · 22 files")
    let hidden = r.make(["type": "label", "text": ""])
    #expect(hidden.height(for: 100) == 0)
    let avatar = r.make(["type": "image", "src": "", "width": 16, "height": 16, "radius": 8, "placeholder": true])
    #expect(avatar.height(for: 100) == 16 && avatar.preferredWidth == 16)
    // A stack's natural width is its widest child plus padding (a card's content-fitted width).
    let s = r.make(["type": "stack", "padding": [0, 14, 0, 13], "children": [["type": "label", "text": "Example Domain", "weight": "semibold"]]])
    let label = try #require((s as? CardStackNode)?.kids.first as? LabelNode)
    #expect(s.fitWidth == naturalWidth(label.label) + 27)
  }

  // MARK: Tokens (spec §2.6)

  @Test func cardTokensAreDiasNeutralSurfaceAndStayReadable() {
    func hex(_ c: RGB) -> String { String(format: "#%02X%02X%02X", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded())) }
    let dark = ThemeTokens.make(theme: Theme(), dark: true).card
    let light = ThemeTokens.make(theme: Theme(), dark: false).card
    #expect(hex(dark.fill) == "#262626" && hex(dark.border) == "#3C3C3C" && hex(dark.hover) == "#373737" && dark.highlight == nil)
    #expect(hex(dark.text) == "#DEDEDE" && hex(dark.secondary) == "#9D9D9D")
    #expect(hex(light.fill) == "#F4F4F4" && hex(light.border) == "#DCDCDC" && light.highlight != nil)
    #expect(hex(light.text) == "#252525")
    #expect(hex(dark.tooltip) == "#474747" && hex(dark.onTooltip) == "#E4E4E4")
    // Contrast targets hold (Dia's light secondary is darkened to 4.5:1).
    for c in [dark, light] {
      #expect(c.text.contrast(c.fill) >= ThemeTokens.primaryContrast)
      #expect(c.secondary.contrast(c.fill) >= ThemeTokens.bodyContrast)
      #expect(c.onDangerSoft.contrast(c.dangerSoft) >= ThemeTokens.bodyContrast)
      #expect(c.onDestructive.contrast(c.destructive) >= ThemeTokens.bodyContrast)
      #expect(c.addText.contrast(c.fill) >= ThemeTokens.bodyContrast && c.delText.contrast(c.fill) >= ThemeTokens.bodyContrast)
    }
    // A themed space tints the card only slightly, and never to the Arc navy.
    let purple = Theme(colors: [RGB(0.55, 0.3, 0.9)], intensity: 1, grain: 0)
    let tinted = ThemeTokens.make(theme: purple, dark: true).card.fill
    #expect(abs(tinted.r - dark.fill.r) < 0.06 && abs(tinted.b - dark.fill.b) < 0.06)
    #expect(hex(tinted) != "#151C30")
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
