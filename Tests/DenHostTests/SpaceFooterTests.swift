import AppKit
import CordisValue
import Foundation
import Testing

@testable import DenHost

/// The footer's space icons: live drag-reorder, the space title's inline rename, the icon picker.
@MainActor
@Suite(.serialized)
struct SpaceFooterTests {
  static func footer(_ n: Int) -> Value {
    var kids: [Value] = [["type": "button", "id": "lib", "icon": "sf:tray.full", "size": 32], ["type": "spacer"]]
    for i in 0..<n {
      kids.append(["type": "spaceIcon", "id": .string("s\(i)"), "icon": "sf:star", "title": .string("S\(i)"), "selected": .bool(i == 0),
                   "spaceId": .string("s\(i)"), "reorderable": true])
    }
    kids += [["type": "spacer"], ["type": "button", "id": "new", "icon": "sf:plus", "size": 32]]
    return ["type": "row", "id": "footer", "height": 50, "spacing": 2, "children": .array(kids)]
  }

  func icons(_ rt: DenRuntime) -> [SpaceIconNode] {
    (rt.ui.sidebarView.footer.root?.subviews ?? []).compactMap { $0 as? SpaceIconNode }.sorted { $0.frame.minX < $1.frame.minX }
  }

  @Test func draggingAnIconReordersLiveAndEmitsMoveOnDrop() {
    let rt = ServiceTests.runtime()
    let w = rt.window.window
    w.orderFront(nil)
    _ = rt.call("ui", "set", ["slot": "sidebar.footer", "tree": Self.footer(3)])
    w.contentView?.layoutSubtreeIfNeeded()
    var got: [Value] = []
    rt.host.on("ui.action") { got.append($0) }
    let row = icons(rt)
    #expect(row.count == 3)
    let slots = row.map(\.frame)
    let a = row[0]
    func ev(_ t: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
      ComponentTests.mouse(t, at: NSPoint(x: x, y: a.bounds.midY), in: a, window: w)
    }
    // Pick up the first icon and drag it right, past both neighbours.
    a.mouseDown(with: ev(.leftMouseDown, a.bounds.midX))
    let pitch = slots[1].minX - slots[0].minX
    a.mouseDragged(with: ev(.leftMouseDragged, a.bounds.midX + 5))
    a.mouseDragged(with: ev(.leftMouseDragged, a.bounds.midX + pitch))
    // Live: the second icon has already slid into the first slot (its animation target).
    #expect(row[1].animator().frame.minX == slots[0].minX)
    a.mouseDragged(with: ev(.leftMouseDragged, a.bounds.midX + pitch * 2 + 40))  // clamped to the last slot
    #expect(a.frame.minX == slots[2].minX)
    a.mouseUp(with: ev(.leftMouseUp, a.bounds.midX))
    let moves = got.filter { $0["action"] == "move" }
    #expect(moves.count == 1)
    #expect(moves.first?["id"] == "s0" && moves.first?["value"]["index"] == 2)
    #expect(!got.contains { $0["action"] == "click" })
    // A plain click still switches (no drag, no move).
    got = []
    let b = icons(rt)[1]
    b.mouseDown(with: ComponentTests.mouse(.leftMouseDown, at: NSPoint(x: b.bounds.midX, y: b.bounds.midY), in: b, window: w))
    b.mouseUp(with: ComponentTests.mouse(.leftMouseUp, at: NSPoint(x: b.bounds.midX, y: b.bounds.midY), in: b, window: w))
    #expect(got.map { $0["action"].string } == ["click"])
    // Dropping back in its own slot emits nothing.
    got = []
    let c = icons(rt)[2]
    c.mouseDown(with: ComponentTests.mouse(.leftMouseDown, at: NSPoint(x: c.bounds.midX, y: 10), in: c, window: w))
    c.mouseDragged(with: ComponentTests.mouse(.leftMouseDragged, at: NSPoint(x: c.bounds.midX - 8, y: 10), in: c, window: w))
    c.mouseUp(with: ComponentTests.mouse(.leftMouseUp, at: NSPoint(x: c.bounds.midX - 8, y: 10), in: c, window: w))
    #expect(got.isEmpty)
  }

  @Test func spaceTitleRenamesInPlace() async throws {
    let rt = ServiceTests.runtime()
    rt.window.window.orderFront(nil)
    var got: [Value] = []
    rt.host.on("ui.action") { got.append($0) }
    _ = rt.call("ui", "set", ["slot": "sidebar.spaceHeader", "tree": ["type": "spaceTitle", "id": "t", "title": "Home", "editing": true]])
    rt.window.window.contentView?.layoutSubtreeIfNeeded()
    let node = try #require(rt.ui.sidebarView.slot("sidebar.spaceHeader", page: 0)?.root as? SpaceTitleNode)
    try await Task.sleep(for: .milliseconds(50))
    let editor = try #require(node.rename.editor)
    #expect(editor.stringValue == "Home" && node.label.isHidden)
    editor.stringValue = "Reading"
    editor.finish(commit: true)
    #expect(got.last?["action"] == "rename" && got.last?["value"]["title"] == "Reading")
    _ = rt.call("ui", "set", ["slot": "sidebar.spaceHeader", "tree": ["type": "spaceTitle", "id": "t", "title": "Reading"]])
    #expect(node.rename.editor == nil && !node.label.isHidden)
  }

  @Test func iconPickerLaysOutInsideItsPanelAndPicks() throws {
    let rt = ServiceTests.runtime()
    let w = rt.window.window
    w.orderFront(nil)
    _ = rt.call("ui", "set", ["slot": "sidebar.footer", "tree": Self.footer(2)])
    var got: [Value] = []
    rt.host.on("ui.action") { got.append($0) }
    #expect(rt.call("ui", "set", ["slot": "popover", "tree": ["type": "iconPicker", "id": "ip", "anchor": "s1", "selected": "sf:star.fill"]]) == .ok)
    w.contentView?.layoutSubtreeIfNeeded()
    let picker = try #require(rt.ui.popover.content as? IconPickerNode)
    let f = rt.ui.popover.frame
    #expect(f.width == Tokens.iconPickerWidth && f.height == picker.height(for: f.width))
    #expect(f.maxY <= w.contentView!.bounds.height - 10)  // anchored to the footer, clamped inside the window
    // Every cell sits inside the panel with the padding on both sides.
    let cells = picker.subviews.compactMap { $0 as? IconCell }
    #expect(cells.count == IconPickerNode.symbols.count + IconPickerNode.emoji.count)
    #expect(cells.allSatisfy { $0.frame.minX >= Tokens.iconPickerPadding && $0.frame.maxX <= f.width - Tokens.iconPickerPadding && $0.frame.maxY <= f.height - Tokens.iconPickerPadding })
    #expect(cells.first { $0.spec == "sf:star.fill" }?.selected == true)
    let rocket = try #require(cells.first { $0.spec == "🚀" })
    rocket.mouseUp(with: ComponentTests.mouse(.leftMouseUp, at: NSPoint(x: 10, y: 10), in: rocket, window: w))
    #expect(got.last?["id"] == "ip" && got.last?["action"] == "pick" && got.last?["value"]["icon"] == "🚀")
    picker.cancelOperation(nil)
    #expect(got.last?["action"] == "dismiss" && got.last?["value"]["reason"] == "escape")
  }
}
