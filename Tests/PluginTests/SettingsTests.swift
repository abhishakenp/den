import AppKit
import CordisValue
import Foundation
import DenTestSupport
import Testing

@testable import DenHost
@testable import PluginCores

/// The `settings` host service and the sections the plugins contribute to the Settings window.
@MainActor
@Suite(.serialized, .watchdog)
struct SettingsTests {
  @Test func registerGetSetPersistAndEmit() {
    let h = Harness()
    h.record(["settings.changed"])
    let s = h.rt.settings
    #expect(h.rt.call("settings", "register", ["id": "demo", "title": "Demo", "icon": "sf:star", "controls": [
      ["key": "on", "type": "toggle", "title": "On", "default": true],
      ["key": "n", "type": "number", "title": "N", "min": 0, "max": 10, "default": 3],
    ]]) == .ok)
    #expect(h.rt.call("settings", "get", ["id": "demo"]) == ["on": true, "n": 3])
    #expect(h.rt.call("settings", "set", ["id": "demo", "key": "n", "value": 7]) == .ok)
    #expect(h.rt.call("settings", "get", ["id": "demo", "key": "n"]) == 7)
    // Per plugin, in its own storage namespace; one event per real change.
    #expect(h.storage("demo", "prefs") == ["n": 7])
    h.rt.call("settings", "set", ["id": "demo", "key": "n", "value": 7])
    #expect(h.events.count == 1 && h.events[0].1 == ["id": "demo", "key": "n", "value": 7])
    // A restart reads the stored value back.
    let h2 = Harness(root: h.root)
    h2.rt.call("settings", "register", ["id": "demo", "title": "Demo", "controls": [["key": "n", "type": "number", "default": 3]]])
    #expect(h2.rt.call("settings", "get", ["id": "demo", "key": "n"]) == 7)
    // Sections: General (host) first, then by order; a registration with `section` is a group.
    h.rt.call("settings", "register", ["id": "extra", "section": "demo", "title": "More", "controls": []])
    #expect(h.rt.call("settings", "list").array?.map { $0.s("id") } == ["general", "demo"])
    #expect(s.groups(of: "demo").map(\.id) == ["demo", "extra"])
    #expect(h.rt.call("settings", "set", ["id": "../x", "key": "k", "value": 1]).isError)
    // Nothing is built until Settings opens.
    #expect(s.window == nil)
  }

  @Test func windowOpensLazilyAndItsControlsWriteSettings() throws {
    let h = Harness()
    h.startTabs()
    #expect(h.rt.settings.window == nil)
    h.rt.call("settings", "open", ["section": "tabs"])
    let w = try #require(h.rt.settings.window)
    #expect(w.window.isVisible && w.section == "tabs")
    #expect(h.rt.call("settings", "state") == ["open": true, "section": "tabs"])
    w.window.contentView?.layoutSubtreeIfNeeded()
    let rows = w.pane.groups.flatMap(\.rows)
    // Tabs: archive choice + unload slider.
    let archive = try #require(rows.first { $0.key == "archiveAfterMs" }?.accessory as? NSPopUpButton)
    #expect(archive.titleOfSelectedItem == "After 24 hours")
    archive.selectItem(withTitle: "After 7 days")
    _ = archive.target?.perform(archive.action, with: archive)
    #expect(h.tabs("settings")["archiveAfterMs"] == .int(7 * 86_400_000))
    let slider = try #require(rows.first { $0.key == "suspendAfterMinutes" }?.accessory as? NSSlider)
    #expect(slider.doubleValue == 5)  // the default: discard after 5 minutes off screen
    slider.doubleValue = 0
    _ = slider.target?.perform(slider.action, with: slider)
    #expect(h.tabs("settings")["suspendAfterMs"] == 0)
    #expect(rows.first { $0.key == "suspendAfterMinutes" }.map { $0.numberText(0) } == "Never")
    // The plugin's own API changes show up in the open window.
    h.tabs("settings", ["archiveAfterMs": .int(3_600_000)])
    #expect(archive.titleOfSelectedItem == "After 1 hour")
    // Every row sits inside its card, and nothing overflows the pane.
    for g in w.pane.groups { for r in g.rows { #expect(r.frame.maxX <= g.card.bounds.width + 0.5 && r.subviews.allSatisfy { $0.isHidden || $0.frame.maxX <= r.bounds.width + 0.5 }) } }
    // Switching sections through the sidebar.
    w.select("general")
    #expect(w.pane.groups.first?.entry.id == "general")
    w.window.close()
  }

  @Test func quitPeekBriefingAndSearchSettingsApplyLive() {
    let h = Harness()
    h.startPeek()
    let quit = QuitCore(env: h.env)
    quit.start()
    let cmd = CommandBarCore(env: h.env)
    h.rt.plugins.provide("commands") { m, a in cmd.handle(m, a) }
    cmd.start()
    let briefing = BriefingCore(env: h.env)
    briefing.start()
    // General gains "Quitting"; Tabs gains "Links".
    #expect(h.rt.settings.groups(of: "general").map(\.id) == ["general", "quit"])
    #expect(h.rt.settings.groups(of: "tabs").map(\.id) == ["tabs", "peek"])
    #expect(h.rt.call("settings", "list").array?.map { $0.s("id") } == ["general", "tabs", "commandbar", "briefing"])
    // Quit prompt.
    #expect(quit.warn)
    h.rt.call("settings", "set", ["id": "quit", "key": "warn", "value": false])
    #expect(!quit.warn && h.storage("quit", "warn") == false)
    // Little Arc is opt-in, with the user's wording.
    let peekControls = h.rt.settings.entries["peek"]?.controls ?? []
    #expect(peekControls.first { $0.s("key") == "littleArc" }?["title"] == "Open links from other apps in a mini window")
    #expect(h.peek("settings")["littleArc"] == false)
    h.rt.call("settings", "set", ["id": "peek", "key": "littleArc", "value": true])
    #expect(h.peek("settings")["littleArc"] == true)
    h.rt.call("settings", "set", ["id": "peek", "key": "peekLinks", "value": false])
    #expect(h.rules(h.ids("pinned")[0]).isEmpty)
    // Briefing: time and shortcut rebind.
    h.rt.call("settings", "set", ["id": "briefing", "key": "time", "value": .int(7 * 60 + 30)])
    #expect(h.rt.call("briefing", "settings") == .null || briefing.hour == 7 && briefing.minute == 30)
    #expect(h.rt.keys.bindings["cmd+shift+b"] != nil)
    h.rt.call("settings", "set", ["id": "briefing", "key": "shortcut", "value": "cmd+opt+b"])
    #expect(h.rt.keys.bindings["cmd+shift+b"] == nil && h.rt.keys.bindings["cmd+opt+b"]?.event == "briefing.key.open")
    // Search: default engine, add and remove a keyword.
    h.rt.call("settings", "set", ["id": "commandbar", "key": "defaultEngine", "value": "w"])
    #expect(cmd.engines[0].keyword == "w")
    h.rt.settings.action("commandbar", "addEngine", value: "mdn MDN Web Docs https://developer.mozilla.org/search?q=%s")
    #expect(cmd.engines.last == CommandBarCore.Engine("mdn", "MDN Web Docs", "https://developer.mozilla.org/search?q=%s"))
    h.rt.settings.action("commandbar", "engines", item: "mdn", button: "remove")
    #expect(!cmd.engines.contains { $0.keyword == "mdn" })
    let list = h.rt.settings.entries["commandbar"]?.controls.first { $0.s("key") == "engines" }?["items"].array ?? []
    #expect(list.count == cmd.engines.count && list[0]["buttons"].isNull)
  }

  @Test func connectionsListButtonsDriveTheConnectFlow() {
    let h = Harness()
    h.startTabs()
    let conn = ConnectionsCore(env: h.env)
    h.rt.plugins.provide("connections") { m, a in conn.handle(m, a) }
    conn.start()
    h.rt.call("connections", "register", ["id": "gh", "title": "GitHub", "icon": "sf:chevron.left.forwardslash.chevron.right", "domain": "github.test", "signIn": "https://github.test/login", "owner": "t"])
    var items: [Value] { h.rt.settings.entries["connections"]?.controls.first?["items"].array ?? [] }
    #expect(items.count == 1 && items[0]["buttons"][0]["id"] == "connect")
    h.rt.settings.action("connections", "accounts", item: "gh", button: "connect")
    // Nobody answers the probe here: it waits for a sign-in, and offers Cancel.
    #expect(items[0]["buttons"][0]["id"] == "cancel")
    conn.report(["id": "gh", "connected": true, "account": "octo", "profile": "default"])
    #expect(items[0]["subtitle"].string?.contains("octo") == true && items[0]["buttons"][0]["id"] == "disconnect")
    h.rt.settings.action("connections", "accounts", item: "gh", button: "disconnect")
    #expect(h.rt.call("connections", "get", ["id": "gh"])["connected"] == false)
  }

  @Test func shortcutRecorderCapturesChords() throws {
    let r = ShortcutRecorder(frame: NSRect(x: 0, y: 0, width: 130, height: 24))
    func key(_ chars: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags) -> NSEvent {
      NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil,
                       characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }
    #expect(ShortcutRecorder.chord(from: key("b", 11, [.command, .shift])) == "shift+cmd+b")
    #expect(ShortcutRecorder.chord(from: key("b", 11, [])) == nil)  // a plain letter would steal typing
    #expect(ShortcutRecorder.chord(from: key("", 122, [])) == "f1")
    #expect(ShortcutRecorder.display("cmd+shift+b") == "⇧⌘B" && ShortcutRecorder.display("ctrl+opt+left") == "⌃⌥←")
    #expect(Chord.parse("shift+cmd+b") == Chord.parse("cmd+shift+b"))
    var got: [String] = []
    r.onChange = { got.append($0) }
    r.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
    #expect(r.recording)
    #expect(r.performKeyEquivalent(with: key("k", 40, [.command, .option])))
    #expect(got == ["opt+cmd+k"] && r.chord == "opt+cmd+k" && !r.recording)
  }
}
