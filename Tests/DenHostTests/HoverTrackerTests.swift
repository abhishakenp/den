import AppKit
import CordisValue
import Foundation
import DenTestSupport
import Testing

@testable import DenHost

/// Hover has one source of truth (HoverTracker): at most one row is hovered, the one under the
/// pointer, however the list re-renders or scrolls. The pointer is faked; the real one never moves.
@MainActor
@Suite(.serialized, .watchdog)
struct HoverTrackerTests {
  static func rows(_ n: Int, loading: Int = -1, tick: Int = 0) -> Value {
    var kids: [Value] = []
    for i in 0..<n {
      // Titles and favicons change while pages load, as in the sidebar during a restore.
      let title = i == loading ? "Loading… \(tick)" : "Tab \(i)"
      kids.append(["type": "tabRow", "id": .string("t\(i)"), "title": .string(title), "icon": .string(tick % 2 == 0 ? "sf:globe" : "sf:doc"), "selected": .bool(i == 0)])
    }
    return ["type": "list", "id": "today", "children": .array(kids)]
  }

  func rowViews(_ rt: DenRuntime) -> [TabRowNode] {
    var out: [TabRowNode] = []
    func walk(_ v: NSView) { if let r = v as? TabRowNode { out.append(r) }; v.subviews.forEach(walk) }
    walk(rt.ui.sidebarView)
    return out.sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
  }

  @Test func exactlyOneRowIsHoveredWhileTheListRerendersUnderAMovingPointer() throws {
    let rt = ServiceTests.runtime()
    let w = rt.window.window
    w.orderFront(nil)
    defer { HoverTracker.pointer = { $0.mouseLocationOutsideOfEventStream } }
    var pointer = NSPoint(x: -100, y: -100)
    HoverTracker.pointer = { _ in pointer }
    _ = rt.call("ui", "set", ["slot": "sidebar.today", "tree": Self.rows(15)])
    w.contentView?.layoutSubtreeIfNeeded()
    let rows = rowViews(rt)
    #expect(rows.count == 15)
    // Stale flags from before (what AppKit's missed exits used to leave behind) get cleared.
    for i in [1, 3, 6, 10, 12, 14] { rows[i].hovering = true }
    for (step, i) in [0, 2, 4, 5, 7, 9, 11, 13, 14, 8, 1].enumerated() {
      let r = rowViews(rt)[i]
      pointer = r.convert(NSPoint(x: r.bounds.midX, y: r.bounds.midY), to: nil)
      r.mouseEntered(with: NSEvent())  // the tracking area's enter
      // The list re-renders while the pointer is there (a page loading changes its row).
      _ = rt.call("ui", "set", ["slot": "sidebar.today", "tree": Self.rows(15, loading: (i + 3) % 15, tick: step)])
      HoverTracker.refresh(w)
      let hot = HoverTracker.hovered(in: w)
      #expect(hot.count == 1, "step \(step): \(hot.count) rows hovered")
      #expect((hot.first as? TabRowNode)?.nodeId == "t\(i)")
      // Only that row shows its × (the close button appears with hover).
      #expect(rowViews(rt).filter { !$0.close.isHidden }.map(\.nodeId) == ["t\(i)"])
    }
    // Leaving the sidebar: nothing is hovered.
    pointer = NSPoint(x: w.frame.width - 20, y: 20)
    HoverTracker.refresh(w)
    #expect(HoverTracker.hovered(in: w).isEmpty)
    #expect(rowViews(rt).allSatisfy { $0.close.isHidden })
  }

  @Test func scrollingUnderAStillPointerMovesTheHover() async throws {
    let rt = ServiceTests.runtime()
    let w = rt.window.window
    w.setContentSize(NSSize(width: 1000, height: 420))  // short, so 15 rows scroll
    w.orderFront(nil)
    defer { HoverTracker.pointer = { $0.mouseLocationOutsideOfEventStream } }
    _ = rt.call("ui", "set", ["slot": "sidebar.today", "tree": Self.rows(15)])
    w.contentView?.layoutSubtreeIfNeeded()
    let first = rowViews(rt)[2]
    let still = first.convert(NSPoint(x: first.bounds.midX, y: first.bounds.midY), to: nil)
    HoverTracker.pointer = { _ in still }
    HoverTracker.refresh(w)
    #expect((HoverTracker.hovered(in: w).first as? TabRowNode)?.nodeId == "t2")
    // Scroll the page down by three rows; the pointer doesn't move.
    let page = try #require(rt.ui.sidebarView.pager.pages.first)
    page.contentView.scroll(to: NSPoint(x: 0, y: Tokens.tabRowHeight * 3))
    page.reflectScrolledClipView(page.contentView)
    // The coalesced refresh runs on a later turn: wait for the highlight to leave t2.
    _ = await Wait.until("the hover highlight to follow the scroll") {
      HoverTracker.hovered(in: w).count == 1 && (HoverTracker.hovered(in: w).first as? TabRowNode)?.nodeId != "t2"
    }
    let hot = HoverTracker.hovered(in: w)
    let under = rowViews(rt).first { $0.convert($0.bounds, to: nil).contains(still) }
    #expect(hot.count == 1)
    #expect(under != nil && under?.nodeId != "t2")
    #expect((hot.first as? TabRowNode)?.nodeId == under?.nodeId)
    // Resigning key clears hover.
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: w)
    #expect(HoverTracker.hovered(in: w).isEmpty)
  }
}
