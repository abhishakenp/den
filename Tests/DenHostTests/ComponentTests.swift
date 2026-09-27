import AppKit
import CordisValue
import Foundation
import Testing

@testable import DenHost

/// Host components added for the theme, commandbar, peek, quit and tabs plugins.
@MainActor
@Suite(.serialized)
struct ComponentTests {
  static func runtime() -> DenRuntime { ServiceTests.runtime() }

  static func mouse(_ type: NSEvent.EventType, at p: NSPoint, in v: NSView, window: NSWindow) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: v.convert(p, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
  }

  @Test func themePickerMathRoundTrips() {
    for p in [CGPoint(x: 0.9, y: 0.5), CGPoint(x: 0.3, y: 0.2), CGPoint(x: 0.55, y: 0.85)] {
      let c = ThemePickerMath.color(at: p)
      let back = ThemePickerMath.position(for: c)
      #expect(abs(back.x - p.x) < 0.02 && abs(back.y - p.y) < 0.02)
    }
    #expect(RGB(hex: "#3139fb")!.hex == "#3139fb")
    let s = ThemePickerMath.snap(CGPoint(x: 10, y: 3), pitch: 4.25, size: 340)
    #expect(s.point == CGPoint(x: 8.5, y: 4.25))
    #expect(ThemePickerMath.presetPages.count == 4 && ThemePickerMath.presetPages.allSatisfy { $0.count == 9 })
  }

  @Test func themePickerPopoverAnchorsAndEmitsLiveChanges() throws {
    let rt = Self.runtime()
    rt.window.window.orderFront(nil)
    _ = rt.call("ui", "set", ["slot": "sidebar.spaceHeader", "tree": ["type": "spaceTitle", "id": "space-0", "title": "Home"]])
    var got: [Value] = []
    rt.host.on("ui.action") { got.append($0) }
    #expect(rt.call("ui", "set", ["slot": "popover", "tree": ["type": "themePicker", "id": "theme", "anchor": "space-0", "colors": ["#ff0000"]]]) == .ok)
    #expect(rt.call("ui", "get")["overlays"] == ["popover"])
    rt.window.window.contentView?.layoutSubtreeIfNeeded()
    let f = rt.ui.popover.frame
    // Spec §4: 356x508 body, just right of the 228 pt sidebar (x = 241).
    #expect(f.size == CGSize(width: 356, height: 508))
    #expect(f.minX == 241)
    #expect(f.minY == 10)  // anchor top 32 - 40, clamped to the 10 pt window margin
    let picker = try #require(rt.ui.popover.content as? ThemePickerNode)
    #expect(picker.colors.first?.hex == "#ff0000")
    // Drag the handle across the pad: live `change` events with the new color, then `commit`.
    let w = rt.window.window
    let start = picker.padPoint(picker.positions[0])
    picker.mouseDown(with: Self.mouse(.leftMouseDown, at: start, in: picker, window: w))
    picker.mouseDragged(with: Self.mouse(.leftMouseDragged, at: NSPoint(x: 60, y: 60), in: picker, window: w))
    picker.mouseDragged(with: Self.mouse(.leftMouseDragged, at: NSPoint(x: 300, y: 300), in: picker, window: w))
    picker.mouseUp(with: Self.mouse(.leftMouseUp, at: NSPoint(x: 300, y: 300), in: picker, window: w))
    let changes = got.filter { $0["id"] == "theme" && $0["action"] == "change" }
    #expect(changes.count >= 2)
    #expect(changes.last?["value"]["colors"][0].string != "#ff0000")
    #expect(got.last?["action"] == "commit")
    // A tree re-sent mid-session doesn't reset the local state it already reported.
    // Mode buttons, presets and add/remove.
    picker.setMode("dark")
    #expect(got.last?["value"]["appearance"] == "dark")
    picker.pickSwatch("#73E59C")
    #expect(got.last?["value"]["colors"][0] == "#73e59c")
    picker.addColor()
    picker.addColor()
    picker.addColor()  // capped at 3
    #expect(picker.colors.count == 3)
    picker.removeColor()
    #expect(picker.colors.count == 2)
    // Escape and outside clicks dismiss; clearing closes.
    picker.cancelOperation(nil)
    #expect(got.last?["action"] == "dismiss" && got.last?["value"]["reason"] == "escape")
    rt.ui.popoverBackdrop.onClick?()
    #expect(got.last?["id"] == "theme" && got.last?["action"] == "dismiss" && got.last?["value"]["reason"].isNull == true)
    _ = rt.call("ui", "set", ["slot": "popover", "tree": nil])
    #expect(rt.call("ui", "get")["overlays"] == [])
  }
}

extension ComponentTests {
  @Test func contextMenusSupportSubmenusIconsDestructiveAndKeys() throws {
    let rt = Self.runtime()
    var got: [Value] = []
    rt.host.on("ui.action") { got.append($0) }
    _ = rt.call("ui", "set", ["slot": "sidebar.today", "tree": ["type": "tabRow", "id": "t", "title": "T", "menu": [
      ["id": "copy", "title": "Copy Link", "icon": "sf:link", "key": "cmd+shift+c"],
      ["separator": true],
      ["id": "move", "title": "Move to Space", "icon": "sf:arrow.right.square", "items": [
        ["header": "Spaces"], ["id": "move:work", "title": "Work"], ["id": "move:home", "title": "Home", "checked": true, "enabled": false],
      ]],
      ["id": "archive", "title": "Archive Tab", "icon": "sf:archivebox", "key": "cmd+w", "destructive": true],
    ]]])
    let row = try #require(rt.ui.sidebarView.slot("sidebar.today", page: 0)?.root)
    let ev = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    let m = try #require(row.menu(for: ev))
    #expect(m.items.map(\.isSeparatorItem) == [false, true, false, false])
    #expect(m.items[0].keyEquivalent == "c" && m.items[0].keyEquivalentModifierMask == [.command, .shift] && m.items[0].image != nil)
    let sub = try #require(m.items[2].submenu)
    #expect(sub.items[0].isSectionHeader && sub.items[1].title == "Work")
    #expect(sub.items[2].state == .on && !sub.items[2].isEnabled)
    #expect(m.items[3].attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == ContextMenu.destructiveColor)
    #expect(m.items[3].keyEquivalent == "w")
    // Picking a submenu item emits `menu` with its id.
    _ = sub.items[1].target?.perform(sub.items[1].action, with: sub.items[1])
    #expect(got.last?["id"] == "t" && got.last?["action"] == "menu" && got.last?["value"] == "move:work")
  }
}

extension ComponentTests {
  @Test func dialogVariantsLayoutAndKeys() throws {
    let rt = Self.runtime()
    var got: [Value] = []
    rt.host.on("ui.action") { got.append($0) }
    // Quit sheet (spec §5): 450x248, secondary button on the left, Cancel + Quit packed right 7 pt apart.
    _ = rt.call("ui", "set", ["slot": "dialog", "tree": HostScenarios.dialogs["dialogQuit"]!])
    rt.window.window.contentView?.layoutSubtreeIfNeeded()
    let d = rt.ui.dialog
    d.layoutSubtreeIfNeeded()
    #expect(d.frame.size == CGSize(width: 450, height: 248))
    let b = d.buttons.map(\.frame)
    #expect(b[0].minX == 27.5 && abs(b[2].maxX - 422.5) < 0.01 && abs(b[2].minX - b[1].maxX - 7) < 0.01)
    #expect(abs(b[0].width - 176) <= 1.5 && abs(b[1].width - 110) <= 1.5 && abs(b[2].width - 86) <= 1.5)  // spec §5 widths
    #expect(d.hero.isHidden && d.icon.frame.width == 62)
    // Destructive confirm flagged default: Return presses it, Esc presses Cancel.
    _ = rt.call("ui", "set", ["slot": "dialog", "tree": HostScenarios.dialogs["dialogDeleteSpace"]!])
    d.layoutSubtreeIfNeeded()
    #expect(!d.hero.isHidden && d.hero.frame.width == 76)
    #expect(d.buttons[1].keycap.text == "↩" && d.buttons[0].keycap.text == "ESC")
    let ret = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                               characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    d.keyDown(with: ret)
    #expect(got.last?["id"] == "deleteSpace" && got.last?["value"]["button"] == "delete")
    d.cancelOperation(nil)
    #expect(got.last?["value"]["button"] == "cancel")
    _ = rt.call("ui", "set", ["slot": "dialog", "tree": HostScenarios.dialogs["dialogClearArchive"]!])
    #expect(d.title.stringValue == "Clear the Archive?" && d.frame.height > 248 - 1)
  }
}
