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

extension ComponentTests {
  @Test func littleArcWindowHostsOneWebView() throws {
    let rt = Self.runtime()
    var got: [(String, Value)] = []
    for e in ["window.miniAction", "window.miniClosed"] { rt.host.on(e) { got.append((e, $0)) } }
    #expect(rt.call("window", "openMini", ["webview": "nope"]).isError)
    let wid = rt.call("webviews", "create", ["url": "https://example.com"])["id"]
    let r = rt.call("window", "openMini", ["webview": wid, "space": "Work"])
    let id = try #require(r["id"].string)
    let m = try #require(rt.windowService.mini.windows[id])
    // Spec §8: 1185x832, 20 pt from the screen's right edge and below the menu bar.
    let vis = (rt.window.window.screen ?? NSScreen.main)!.visibleFrame
    #expect(m.panel.frame.size == CGSize(width: min(1185, vis.width - 40), height: min(832, vis.height - 40)))
    #expect(m.panel.frame.maxX == vis.maxX - 20 && m.panel.frame.maxY == vis.maxY - 20)
    #expect(m.panel.isFloatingPanel)
    let web = try #require(rt.webviews.record(wid.string!)?.webView)
    #expect(web.window === m.panel)
    m.root.layoutSubtreeIfNeeded()
    #expect(m.content.frame.minY == 47 && m.bar.open.name.stringValue == "Work")
    #expect(rt.call("window", "listMini") == [["id": .string(id), "webview": wid, "key": false]])
    m.bar.open.onClick?()
    #expect(got.last?.0 == "window.miniAction" && got.last?.1["action"] == "open" && got.last?.1["webview"] == wid)
    _ = rt.call("window", "updateMini", ["id": .string(id), "space": "Home"])
    #expect(m.bar.open.name.stringValue == "Home")
    #expect(rt.call("window", "closeMini", ["id": .string(id)]) == .ok)
    #expect(got.last?.0 == "window.miniClosed" && web.superview == nil)
    #expect(rt.call("window", "listMini") == [])
    // The detached web view can be shown in the main window again ("Open in space").
    _ = rt.call("content", "show", ["panes": [wid]])
    #expect(web.window === rt.window.window)
  }
}

extension ComponentTests {
  @Test func librarySheetFiltersGroupsAndEmits() throws {
    let rt = Self.runtime()
    var got: [Value] = []
    rt.host.on("ui.action") { got.append($0) }
    // Midday: the newest fixture item is 24 min old, which is "Yesterday" just after midnight.
    let now = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
    rt.ui.library.now = { now }
    _ = rt.call("ui", "set", ["slot": "overlay.library", "tree": ["type": "library", "id": "archive", "items": HostScenarios.archiveItems(now: now)]])
    #expect(rt.call("ui", "get")["overlays"] == ["overlay.library"])
    let lib = rt.ui.library
    #expect(lib.rows.count == 7 && lib.headers.first?.stringValue == "Today")
    // Centered over the content area, inset 40.
    let area = rt.window.overlays.convert(rt.window.contentArea.frame, from: rt.window.contentArea.superview)
    #expect(abs(lib.frame.midX - area.midX) <= 1 && lib.frame.minY == area.minY + 40)
    // Typing filters locally (title or URL) and reports the text.
    lib.input.stringValue = "swift"
    lib.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    #expect(lib.rows.map(\.title.stringValue) == ["Release notes", "Swift Forums"])
    #expect(got.last?["action"] == "input" && got.last?["value"]["text"] == "swift")
    lib.rows[1].onRestore?()
    #expect(got.last?["action"] == "restore" && got.last?["value"]["item"] == "arch-4")
    lib.clearButton.action()
    #expect(got.last?["id"] == "archive" && got.last?["action"] == "clear")
    rt.ui.libraryBackdrop.onClick?()
    #expect(got.last?["action"] == "dismiss")
    // Day buckets.
    let cal = Calendar.current
    #expect(LibraryView.section(for: now.timeIntervalSince1970 * 1000, now: now) == "Today")
    #expect(LibraryView.section(for: cal.date(byAdding: .day, value: -1, to: now)!.timeIntervalSince1970 * 1000, now: now) == "Yesterday")
    // Clear Archive confirmation stacks above the sheet.
    _ = rt.call("ui", "set", ["slot": "dialog", "tree": HostScenarios.dialogs["dialogClearArchive"]!])
    let subs = rt.window.overlays.subviews
    #expect(subs.firstIndex(of: rt.ui.dialog)! > subs.firstIndex(of: lib)!)
    _ = rt.call("ui", "set", ["slot": "overlay.library", "tree": nil])
    #expect(!(rt.call("ui", "get")["overlays"].array ?? []).contains("overlay.library"))
  }
}

extension ComponentTests {
  @Test func splitChromeRingControlsAndDropZone() throws {
    let rt = Self.runtime()
    rt.window.window.orderFront(nil)
    var got: [Value] = []
    rt.host.on("content.paneAction") { got.append($0) }
    let a = rt.call("webviews", "create")["id"].string!, b = rt.call("webviews", "create")["id"].string!
    _ = rt.call("content", "show", ["panes": [.string(a)]])
    let ca = try #require(rt.content.card(a))
    ca.setControlsVisible(true)
    #expect(ca.controls.isHidden)  // single pane: no split controls
    _ = rt.call("content", "show", ["panes": [.string(a), .string(b)], "focus": .string(b)])
    let cb = try #require(rt.content.card(b))
    #expect(cb.focused && !cb.ring.isHidden && ca.ring.isHidden)
    #expect(abs(ca.frame.maxX + Tokens.splitGap - cb.frame.minX) < 0.5)
    cb.setControlsVisible(true)
    #expect(!cb.controls.isHidden)
    cb.controls.buttons[1].action()
    #expect(got.last?["id"] == .string(b) && got.last?["action"] == "separate")
    cb.controls.buttons[0].action()
    #expect(got.last?["action"] == "close")
    // Dragging a tab over the content shows a theme-tinted drop zone on that side.
    _ = rt.call("content", "show", ["panes": [.string(a)]])
    _ = rt.call("ui", "set", ["slot": "sidebar.today", "tree": ["type": "list", "children": [["type": "tabRow", "id": "x", "title": "X"]]]])
    rt.window.root.layoutSubtreeIfNeeded()
    let row = try #require(rt.ui.sidebarView.slot("sidebar.today", page: 0)?.root as? StackNode).kids[0] as! HoverNode
    let cf = rt.window.contentArea.convert(rt.window.contentArea.bounds, to: nil)
    let w = rt.window.window
    func ev(_ t: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
      NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    rt.ui.drag.begin(row, event: ev(.leftMouseDown, row.convert(NSPoint(x: 20, y: 20), to: nil)))
    rt.ui.drag.move(ev(.leftMouseDragged, NSPoint(x: cf.minX + cf.width * 0.9, y: cf.midY)))
    #expect(rt.ui.drag.dropSide == "right" && rt.ui.drag.dropZone.superview === rt.window.overlays)
    let dz = rt.ui.drag.dropZone.frame
    let area = rt.window.overlays.convert(cf, from: nil)
    #expect(abs(dz.maxX - area.maxX) <= 1 && dz.minX > area.midX)
    rt.ui.drag.move(ev(.leftMouseDragged, NSPoint(x: cf.midX, y: cf.midY)))
    #expect(rt.ui.drag.dropSide == "center")
    rt.ui.drag.end(ev(.leftMouseUp, NSPoint(x: cf.midX, y: cf.midY)))
    #expect(rt.ui.drag.dropZone.superview == nil)
  }
}

extension ComponentTests {
  @Test func peekCardButtonsAndAnimation() async throws {
    let rt = Self.runtime()
    var got: [Value] = []
    rt.host.on("content.peekAction") { got.append($0) }
    let id = rt.call("webviews", "create")["id"]
    _ = rt.call("content", "peek", ["webview": id, "title": "swift.org"])
    let p = rt.content.peek
    p.layoutSubtreeIfNeeded()
    #expect(!p.isHidden && rt.call("content", "get")["peek"] == id)
    // Card inset in the content area; button column (34x33) just right of the card's top.
    #expect(p.card.frame == p.bounds.insetBy(dx: Tokens.peekInsetX, dy: Tokens.peekInsetY).integral)
    #expect(p.buttons.map(\.frame.size) == Array(repeating: CGSize(width: 34, height: 33), count: 3))
    #expect(p.buttons[0].frame.minX == p.card.frame.maxX + Tokens.peekButtonGap && p.buttons[0].frame.minY == p.card.frame.minY)
    #expect(p.card.layer?.animation(forKey: "peekIn") != nil || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    for (i, action) in ["close", "expand", "split"].enumerated() {
      p.buttons[i].action()
      #expect(got.last?["action"] == .string(action) && got.last?["webview"] == id)
    }
    _ = rt.call("content", "peek", [:])
    for _ in 0..<40 where !p.isHidden { try await Task.sleep(for: .milliseconds(25)) }
    #expect(p.isHidden && rt.call("content", "get")["peek"] == .null)
  }
}

extension ComponentTests {
  @Test func briefingAndConnectionsSheetsOpenStackAndEmit() throws {
    let rt = Self.runtime()
    var got: [Value] = []
    rt.host.on("ui.action") { got.append($0) }
    #expect(rt.call("ui", "set", ["slot": "overlay.briefing", "tree": HostScenarios.briefingTree()]) == .ok)
    #expect(rt.call("ui", "get")["overlays"] == ["overlay.briefing"])
    rt.window.window.contentView?.layoutSubtreeIfNeeded()
    let page = try #require(rt.ui.sheets["overlay.briefing"])
    // `page` covers the content area.
    let area = rt.window.overlays.convert(rt.window.contentArea.frame, from: rt.window.contentArea.superview)
    #expect(page.frame == area && page.isPage)
    #expect(page.kids.map { $0.node.str("type") } == ["heading", "paragraph", "section", "section"])
    // Header buttons and close emit.
    page.headerButtons[0].action()
    #expect(got.last?["id"] == "briefing.refresh" && got.last?["action"] == "click")
    page.closeButton.action()
    #expect(got.last?["id"] == "briefing" && got.last?["action"] == "dismiss")
    page.cancelOperation(nil)
    #expect(got.last?["action"] == "dismiss")

    // todoRow: checkbox toggles (locally at once), elsewhere opens.
    let todos = try #require(page.kids[2] as? SectionNode)
    let row = try #require(todos.kids[0] as? TodoRowNode)
    todos.layoutSubtreeIfNeeded()
    row.clicked(at: NSPoint(x: row.checkRect.midX, y: row.checkRect.midY))
    #expect(got.last?["id"] == "td1" && got.last?["action"] == "toggle" && got.last?["value"]["done"] == true && row.done)
    row.clicked(at: NSPoint(x: 300, y: 20))
    #expect(got.last?["id"] == "td1" && got.last?["action"] == "open")
    #expect(todos.dividers.count == todos.kids.count - 1)

    // Views are reused across updates.
    let para = page.kids[1]
    _ = rt.call("ui", "set", ["slot": "overlay.briefing", "tree": HostScenarios.briefingTree()])
    #expect(page.kids[1] === para && rt.ui.sheets["overlay.briefing"] === page)

    // Connections stacks above briefing, over a dim that dismisses.
    _ = rt.call("ui", "set", ["slot": "overlay.connections", "tree": HostScenarios.connectionsTree])
    #expect(rt.call("ui", "get")["overlays"] == ["overlay.briefing", "overlay.connections"])
    let sheet = try #require(rt.ui.sheets["overlay.connections"])
    let subs = rt.window.overlays.subviews
    #expect(subs.firstIndex(of: sheet)! > subs.firstIndex(of: page)!)
    #expect(sheet.frame.width == 560 && abs(sheet.frame.midX - area.midX) <= 1)
    rt.ui.sheetBackdrops["overlay.connections"]?.onClick?()
    #expect(got.last?["id"] == "connections" && got.last?["action"] == "dismiss")
    let accounts = try #require(sheet.kids[0] as? SectionNode)
    let conn = try #require(accounts.kids[0] as? ConnectionRowNode)
    conn.buttons.last?.action()
    #expect(got.last?["id"] == "conn.slack" && got.last?["action"] == "click")
    let toggle = try #require((sheet.kids[1] as? SectionNode)?.kids[1] as? ToggleRowNode)
    #expect(toggle.toggle.state == .off)
    toggle.toggle.state = .on
    toggle.flipped()
    #expect(got.last?["id"] == "team.T2" && got.last?["value"]["on"] == true)
    let choice = try #require((sheet.kids[2] as? SectionNode)?.kids[0] as? ChoiceRowNode)
    #expect(choice.popup.titleOfSelectedItem == "8:00")
    choice.popup.selectItem(at: 3)
    choice.chose()
    #expect(got.last?["id"] == "briefing.time" && got.last?["value"]["option"] == "9")

    // A dialog opened later sits above both.
    _ = rt.call("ui", "set", ["slot": "dialog", "tree": HostScenarios.dialogs["dialogQuit"]!])
    let s2 = rt.window.overlays.subviews
    #expect(s2.firstIndex(of: rt.ui.dialog)! > s2.firstIndex(of: sheet)!)
    _ = rt.call("ui", "set", ["slot": "overlay.connections", "tree": nil])
    _ = rt.call("ui", "set", ["slot": "overlay.briefing", "tree": nil])
    #expect(rt.call("ui", "get")["overlays"] == ["dialog"])
    #expect(sheet.superview == nil && page.superview == nil)
  }

  @Test func paragraphHeightGrowsWithTextAndButtonsEmit() throws {
    let rt = Self.runtime()
    var got: [Value] = []
    rt.host.on("ui.action") { got.append($0) }
    let short = rt.ui.renderer.make(["type": "paragraph", "id": "p", "text": "One line."])
    let long = rt.ui.renderer.make(["type": "paragraph", "id": "p2", "text": .string(String(repeating: "A longer summary sentence that wraps. ", count: 12))])
    #expect(short.height(for: 400) > 10)
    #expect(long.height(for: 400) > short.height(for: 400) * 3)
    #expect(long.height(for: 200) > long.height(for: 400))
    let row = rt.ui.renderer.make(["type": "buttonRow", "id": "br", "children": [
      ["type": "actionButton", "id": "a", "title": "Connect Slack", "style": "primary"],
      ["type": "actionButton", "id": "b", "title": "Connect GitHub", "style": "secondary"],
    ]])
    row.frame = NSRect(x: 0, y: 0, width: 500, height: 32)
    row.layoutSubtreeIfNeeded()
    let kids = (row as! ButtonRowNode).kids
    #expect(kids[1].frame.minX == kids[0].frame.maxX + 8 && kids[0].frame.width > 80)
    (kids[1] as! ActionButtonNode).pill?.action()
    #expect(got.last?["id"] == "b" && got.last?["action"] == "click")
    let feed = rt.ui.renderer.make(["type": "feedRow", "id": "f", "title": "T", "badge": "Review", "time": "9:12"]) as! FeedRowNode
    feed.clicked(at: .zero)
    #expect(got.last?["id"] == "f" && got.last?["action"] == "open" && feed.badge.text == "Review")
  }
}
