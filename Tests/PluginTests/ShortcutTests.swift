import AppKit
import CordisValue
import Foundation
import DenTestSupport
import Testing

@testable import DenHost
@testable import PluginCores

/// docs/shortcuts.md as a test: every shortcut in den's table is a real key event that goes through
/// the main menu's key-equivalent path (NSMenu.performKeyEquivalent, what AppKit does when no view
/// claims the key) and lands on the right command.
@MainActor
@Suite(.serialized, .watchdog)
struct ShortcutTests {
  enum Want { case event(String), host(String), command(String), sel(String) }

  /// (chord, what it must do). Keep in step with docs/shortcuts.md.
  static let table: [(String, Want)] = [
    // Tabs
    ("cmd+t", .event("commands.key.new")), ("cmd+l", .event("commands.key.edit")),
    ("cmd+w", .event("tabs.key.close")), ("cmd+shift+t", .event("tabs.key.reopen")),
    ("cmd+shift+]", .event("tabs.key.nextTab")), ("cmd+shift+[", .event("tabs.key.prevTab")),
    ("cmd+opt+down", .event("tabs.key.nextTab")), ("cmd+opt+up", .event("tabs.key.prevTab")),
    ("ctrl+tab", .event("tabs.key.recent")), ("ctrl+shift+tab", .event("tabs.key.recentBack")),
    ("cmd+1", .event("tabs.key.nth")), ("cmd+5", .event("tabs.key.nth")), ("cmd+9", .event("tabs.key.nth")),
    ("cmd+d", .event("tabs.key.pin")), ("cmd+shift+k", .event("tabs.key.clear")), ("ctrl+shift+t", .event("tabs.key.tidy")), ("ctrl+z", .event("tabs.key.undo")),
    ("cmd+opt+w", .event("tabs.key.closeOthers")), ("cmd+opt+t", .event("tabs.key.newTabInFolder")), ("cmd+ctrl+n", .event("tabs.key.newFolder")),
    ("cmd+o", .event("peek.key.expand")),
    // Navigation
    ("cmd+[", .event("tabs.key.back")), ("cmd+]", .event("tabs.key.forward")),
    ("cmd+left", .event("tabs.key.back")), ("cmd+right", .event("tabs.key.forward")),
    ("cmd+r", .event("tabs.key.reload")), ("cmd+shift+r", .host("page.reloadFromOrigin")), ("cmd+.", .event("tabs.key.stop")),
    // Page
    ("cmd+plus", .host("page.zoomIn")), ("cmd+=", .host("page.zoomIn")), ("cmd+-", .host("page.zoomOut")), ("cmd+0", .host("page.zoomReset")),
    ("cmd+f", .host("page.find")), ("cmd+g", .host("page.findNext")), ("cmd+shift+g", .host("page.findPrevious")), ("cmd+e", .host("page.findSelection")),
    ("cmd+p", .host("page.print")), ("cmd+shift+s", .host("page.save")),
    ("cmd+opt+u", .host("page.viewSource")), ("cmd+opt+i", .host("page.inspector")), ("cmd+opt+c", .host("page.inspectElement")), ("cmd+opt+j", .host("page.console")),
    ("cmd+ctrl+f", .sel("toggleFullScreen:")),
    // Sidebar, split view, briefing
    ("cmd+s", .event("tabs.key.sidebar")), ("ctrl+shift+=", .event("peek.key.addSplit")), ("ctrl+shift+-", .event("peek.key.closePane")),
    ("ctrl+shift+1", .event("peek.key.focusPane")), ("cmd+shift+b", .event("briefing.key.open")),
    // Address and sharing
    ("cmd+shift+c", .event("tabs.key.copy")), ("cmd+opt+shift+c", .command("den.copyMarkdown")),
    // App
    ("cmd+y", .event("tabs.key.library")), ("cmd+shift+l", .event("tabs.key.library")),
    ("cmd+,", .host("app.settings")), ("cmd+m", .sel("performMiniaturize:")), ("cmd+h", .sel("hide:")), ("cmd+q", .sel("terminate:")),
    ("cmd+shift+w", .sel("performClose:")),
    // Edit
    ("cmd+z", .sel("undo:")), ("cmd+shift+z", .sel("redo:")), ("cmd+x", .sel("cut:")), ("cmd+c", .sel("copy:")), ("cmd+v", .sel("paste:")),
    ("cmd+opt+shift+v", .sel("pasteAsPlainText:")), ("cmd+a", .sel("selectAll:")),
    // Spaces
    ("ctrl+1", .event("spaces.key.jump")), ("ctrl+3", .event("spaces.key.jump")),
    ("cmd+opt+right", .event("spaces.key.next")), ("cmd+opt+left", .event("spaces.key.prev")),
  ]

  static let keyCodes: [String: UInt16] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33,
    "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, ",": 43, "n": 45, "m": 46, ".": 47, "tab": 48, "left": 123, "right": 124, "down": 125, "up": 126,
  ]

  /// The keyDown a real keyboard delivers for a chord: a CGEvent for the physical key (US
  /// positions) with its modifier flags, turned into an NSEvent, so the characters come from the
  /// current keyboard layout exactly as for a key press (⌘⇧] arrives as "}", ⌃⇧Tab as a tab with
  /// shift). Built in-process; no other app is involved.
  static func event(_ chord: String) -> NSEvent {
    let parts = chord.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
    var key = parts.last!.isEmpty ? "plus" : parts.last!
    var flags: CGEventFlags = []
    for m in parts.dropLast() {
      switch m {
      case "cmd": flags.insert(.maskCommand)
      case "shift": flags.insert(.maskShift)
      case "opt": flags.insert(.maskAlternate)
      case "ctrl": flags.insert(.maskControl)
      default: break
      }
    }
    if key == "plus" { key = "="; flags.insert(.maskShift) }  // ⌘+ is typed as ⌘⇧=
    let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCodes[key]!), keyDown: true)!
    e.flags = flags
    return NSEvent(cgEvent: e)!
  }

  /// The item AppKit's key-equivalent matching picks for an event (for responder-chain items, which
  /// a test process without a key window can't validate).
  static func match(_ e: NSEvent, in menu: NSMenu) -> NSMenuItem? {
    let dev: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
    let flags = e.modifierFlags.intersection(dev)
    var chars = e.charactersIgnoringModifiers ?? ""
    if chars == "\u{19}" { chars = "\t" }  // shift-tab arrives as backtab
    for mi in menu.items {
      if let s = mi.submenu, let f = match(e, in: s) { return f }
      guard !mi.keyEquivalent.isEmpty, !mi.isHidden || mi.allowsKeyEquivalentWhenHidden else { continue }
      var want = mi.keyEquivalentModifierMask.intersection(dev)
      var k = mi.keyEquivalent
      if k.count == 1, k.uppercased() == k, k.lowercased() != k { want.insert(.shift); k = k.lowercased() }
      let shiftedChar = Chord.shiftedPunctuation.values.contains(k)
      let f = shiftedChar ? flags.subtracting(.shift) : flags
      if k == chars.lowercased() && want == f { return mi }
    }
    return nil
  }

  @Test func everyShortcutDispatchesThroughTheMainMenu() throws {
    let h = Harness()
    NSApp.mainMenu = NSMenu()
    MainMenu.install()
    h.startPeek()
    let cmd = CommandBarCore(env: h.env)
    h.rt.plugins.provide("commands") { m, a in cmd.handle(m, a) }
    cmd.start()
    BriefingCore(env: h.env).start()
    var hosts: [String] = [], commands: [String] = []
    MainMenu.handler = { hosts.append($0) }
    MainMenu.canPerform = { _ in true }
    MainMenu.runCommand = { commands.append($0) }
    let events = Set(Self.table.compactMap { if case let .event(e) = $0.1 { return e }; return nil })
    h.record(Array(events))
    let menu = try #require(NSApp.mainMenu)
    for (chord, want) in Self.table {
      let e = Self.event(chord)
      let before = (h.events.count, hosts.count, commands.count)
      switch want {
      case let .sel(sel):
        let mi = Self.match(e, in: menu)
        #expect(mi?.action == NSSelectorFromString(sel), "\(chord) → \(mi?.title ?? "nothing")")
      default:
        #expect(menu.performKeyEquivalent(with: e), "\(chord): no menu item took it")
        switch want {
        case let .event(ev): #expect(h.events.count == before.0 + 1 && h.events.last?.0 == ev, "\(chord) → \(h.events.last?.0 ?? "-") want \(ev)")
        case let .host(a): #expect(hosts.count == before.1 + 1 && hosts.last == a, "\(chord) → \(hosts.last ?? "-") want \(a)")
        case let .command(c): #expect(commands.count == before.2 + 1 && commands.last == c, "\(chord) → \(commands.last ?? "-") want \(c)")
        case .sel: break
        }
      }
      // And it's discoverable: an item with this key equivalent exists (visible, or a hidden
      // alternate of a visible one).
      #expect(Self.match(e, in: menu) != nil, "\(chord) is not in the menu bar")
    }
  }

  @Test func menuBarHasDensStructureAndSlotsFillWhenPluginsBind() throws {
    let h = Harness()
    NSApp.mainMenu = NSMenu()
    MainMenu.install()
    let menu = try #require(NSApp.mainMenu)
    #expect(menu.items.map(\.title) == ["den", "File", "Edit", "View", "History", "Spaces", "Tabs", "Window", "Help"])
    #expect(MainMenu.item("app.settings")?.keyEquivalent == "," && MainMenu.item("app.settings")?.isHidden == false)
    // Plugin slots are hidden until their plugin binds them.
    #expect(MainMenu.item("tabs.next")?.isHidden == true)
    h.startTabs()
    let next = try #require(MainMenu.item("tabs.next"))
    #expect(!next.isHidden && next.keyEquivalent == "\u{F701}" && next.keyEquivalentModifierMask == [.command, .option])
    // ⌘⇧] is a hidden alternate right after it; ⌘1…9 are items in Tabs > Go to Tab.
    let tabsMenu = try #require(next.menu)
    let alt = tabsMenu.items[tabsMenu.index(of: next) + 1]
    #expect(alt.isHidden && alt.allowsKeyEquivalentWhenHidden && alt.keyEquivalent == "}" && alt.keyEquivalentModifierMask == .command)
    let goTo = try #require(MainMenu.item("tabs.goTo")?.submenu)
    #expect(goTo.items.filter { !$0.isHidden }.map(\.title) == ["Tab 1", "Tab 2", "Tab 3", "Tab 4", "Tab 5", "Tab 6", "Tab 7", "Tab 8", "Last Tab"])
    // Spaces lists each space with ⌃N.
    let spaces = try #require(MainMenu.item("spaces.next")?.menu)
    #expect(spaces.items.filter { !$0.isHidden && $0.keyEquivalentModifierMask == .control }.map(\.title).prefix(3) == ["Personal", "Work", "Side Project"])
    // Unbinding a slot hides it again (no dead items when a plugin unloads).
    h.rt.call("keys", "unbind", ["chord": "cmd+d"])
    #expect(MainMenu.item("tabs.pin")?.isHidden == true)
    // A [shortcuts] remap moves a menu item's key and survives the plugin rebinding it.
    #expect(h.rt.call("keys", "remap", ["chord": "cmd+shift+j", "item": "tabs.next"]) == .ok)
    #expect(next.keyEquivalent == "j" && next.keyEquivalentModifierMask == [.command, .shift])
    h.rt.call("keys", "bind", ["chord": "cmd+opt+down", "event": "tabs.key.nextTab", "title": "Next Tab", "menu": "Tabs"])
    #expect(MainMenu.item("tabs.next")?.keyEquivalent == "j")
    h.rt.call("keys", "resetRemaps")
    #expect(next.keyEquivalent == "\u{F701}")
    #expect(h.rt.call("keys", "remap", ["chord": "cmd+j", "item": "nope"]).isError)
  }

  @Test func cmdArrowsStandAsideWhileANativeTextFieldEdits() throws {
    let h = Harness()
    NSApp.mainMenu = NSMenu()
    MainMenu.install()
    h.startTabs()
    let back = try #require(MainMenu.item("history.back")?.menu?.items.first { $0.keyEquivalent == "\u{F702}" })
    #expect(h.rt.keys.validateMenuItem(back))
    let w = h.rt.window.window
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
    w.contentView?.addSubview(field)
    w.makeKeyAndOrderFront(nil)
    w.makeFirstResponder(field)
    if NSApp.keyWindow === w, w.firstResponder is NSText {
      #expect(!h.rt.keys.validateMenuItem(back))
    }
    field.removeFromSuperview()
  }
}
