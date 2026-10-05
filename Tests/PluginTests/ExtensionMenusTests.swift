import AppKit
import CordisValue
import DenTestSupport
import Testing
import WebKit

@testable import DenHost
@testable import PluginCores

/// Extensions in den's menus, with a local probe extension (ExtensionMenuScenarios: `commands`
/// with and without keys, `_execute_action`, a key den already uses, and `contextMenus` items for
/// every context). The background reports what it received into the page (`data-cmd`,
/// `data-clicked`), through `scripting.executeScript`.
///
/// Key presses go through den's window (`DenNSWindow.sendEvent`, where they arrive from AppKit).
/// A page's right-click menu can't be popped up in a test process (WebKit only shows it from a
/// running app's event loop), so the items WebKit adds to it for each context, and the info their
/// clicks send, are checked in the app: `--scenario extensionMenus`.
@MainActor
@Suite(.serialized, .watchdog)
struct ExtensionMenusTests {
  func wait(_ seconds: Double = 45, file: StaticString = #fileID, line: UInt = #line, _ cond: () async -> Bool) async -> Bool {
    await Wait.until("a condition", seconds: seconds, file: file, line: line) { await cond() }
  }

  static func key(_ chars: String, _ ign: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags, _ win: NSWindow?) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win?.windowNumber ?? 0,
                     context: nil, characters: chars, charactersIgnoringModifiers: ign, isARepeat: false, keyCode: code)!
  }

  static func item(_ m: NSMenu?, _ title: String) -> NSMenuItem? {
    guard let m else { return nil }
    for i in m.items {
      if i.title == title { return i }
      if let f = item(i.submenu, title) { return f }
    }
    return nil
  }

  @Test func commandsAndMenus() async throws {
    let mock = MockServices()
    try mock.start()
    defer { mock.stop() }
    mock.page("/p", ExtensionMenuScenarios.page)
    mock.page("/frame", "<!doctype html><body>frame</body>")
    let h = Harness()
    NSApp.mainMenu = NSMenu()
    MainMenu.install()
    h.startTabs()
    // den's own ⌘T (the command bar plugin binds it in the app).
    #expect(h.rt.call("keys", "bind", ["chord": "cmd+t", "event": "commands.key.new", "title": "New Tab…", "menu": "File"]) == .ok)
    let tab = h.tabs("open", ["url": .string(mock.base + "/p")]).s("id")
    h.tabs("select", ["id": .string(tab)])
    #expect(await wait { h.rt.webviews.record(tab)?.title == "Probe" })

    h.record(["webext.installed"])
    let dir = try ExtensionMenuScenarios.fixture()
    #expect(h.rt.call("webext", "install", ["path": .string(dir.path)])["pending"] == true)
    #expect(await wait { h.rt.ui.dialogOpen })
    h.action("extensions.prompt:1", "button", ["button": "ok"])
    #expect(await wait { h.events.contains { $0.0 == "webext.installed" } })
    let extId = h.rt.call("webext", "list")[0].s("id")
    let ctx = try #require(h.rt.extensions.contexts[extId])
    let ctl = try #require(h.rt.extensions.controller)
    // The tab's web view is rebuilt with the controller on the first install.
    #expect(await wait { h.rt.webviews.record(tab)?.webView?.configuration.webExtensionController === ctl && h.rt.webviews.record(tab)?.loading == false })
    let w = try #require(h.rt.webviews.record(tab)?.webView)
    do { try await ctx.loadBackgroundContent() } catch { print("loadBackgroundContent:", error) }
    // The background made its 21 menu items (badge "M21").
    #expect(await wait { (ctx.action(for: nil)?.badgeText ?? "").hasPrefix("M") })

    func data(_ k: String) async -> String { await Wait.js(w, "document.documentElement.dataset.\(k) || ''") as? String ?? "" }
    func clear() async { _ = await Wait.js(w, "delete document.documentElement.dataset.cmd; delete document.documentElement.dataset.clicked; 1") }
    func fired(_ command: String) async -> Bool { await wait(15) { await data("cmd").contains("\"command\":\"\(command)\"") } }

    // The Extensions menu: every command, with its key; Chrome's Ctrl is ⌘ and MacCtrl ⌃; a key
    // den uses (⌘T) and a command without one are listed without a key.
    let menu = try #require(h.rt.extensions.commandsMenu)
    print("Extensions menu: \(menu.items.map { "\($0.title) [\($0.keyEquivalentModifierMask.rawValue >> 16):\($0.keyEquivalent)]" })")
    let alt = try #require(Self.item(menu, "Menu Probe: Probe Alt"))
    #expect(alt.keyEquivalent.lowercased() == "y" && alt.keyEquivalentModifierMask.isSuperset(of: [.option, .shift]))
    let mac = try #require(Self.item(menu, "Menu Probe: Probe MacCtrl"))
    #expect(mac.keyEquivalent.lowercased() == "u" && mac.keyEquivalentModifierMask.contains(.control) && !mac.keyEquivalentModifierMask.contains(.command))
    #expect(Self.item(menu, "Menu Probe: Probe Conflict")?.keyEquivalent == "")
    #expect(Self.item(menu, "Menu Probe: Probe No Key")?.keyEquivalent == "")
    #expect(Self.item(menu, "Menu Probe: Menu Probe")?.keyEquivalent.lowercased() == "p")  // _execute_action
    #expect(MainMenu.item("file.newTab")?.keyEquivalent == "t")  // den's ⌘T keeps its key

    // Keys: through den's window, before the focused page sees them (which swallows every
    // keydown here, as Vimium does), and with den's sidebar focused.
    let win = h.rt.window.window
    _ = await Wait.js(w, "window.addEventListener('keydown', e => { window.__seen = (window.__seen || '') + e.key; e.preventDefault(); e.stopPropagation(); }, true); 1")
    win.makeFirstResponder(w)
    await clear()
    win.sendEvent(Self.key("Á", "Y", 16, [.option, .shift], win))
    #expect(await fired("probe-alt"))
    #expect(await data("cmd").contains("\"tabId\":"))  // onCommand gets the active tab
    #expect(await Wait.js(w, "window.__seen || ''") as? String == "")  // the page never saw it
    win.makeFirstResponder(h.rt.ui.sidebarView)
    await clear()
    win.sendEvent(Self.key("\u{15}", "U", 32, [.control, .shift], win))
    #expect(await fired("probe-mac"))
    // den's own ⌘T wins over the extension's Ctrl+T.
    await clear()
    win.makeFirstResponder(w)
    #expect(!h.rt.extensions.performCommand(for: Self.key("t", "t", 17, [.command], win)))
    #expect(h.rt.extensions.performCommand(for: Self.key("Á", "Y", 16, [.option, .shift], win)))
    #expect(await fired("probe-alt"))
    // A key no extension uses is left alone; so is a plain letter.
    #expect(!h.rt.extensions.performCommand(for: Self.key("˙", "h", 4, [.option], win)))
    #expect(!h.rt.extensions.performCommand(for: Self.key("y", "y", 16, [], win)))
    // A command without a key runs from the Extensions menu.
    await clear()
    let noKey = try #require(Self.item(menu, "Menu Probe: Probe No Key"))
    menu.performActionForItem(at: menu.index(of: noKey))
    #expect(await fired("probe-nokey"))
    // _execute_action (⌥⇧P) opens the popup.
    win.sendEvent(Self.key("π", "P", 35, [.option, .shift], win))
    #expect(await wait(45) { h.rt.extensions.ui.popupFor == extId })
    h.rt.call("webext", "closePopup")

    // The extension button's right-click menu: its `contexts: ["action"]` items, then den's.
    let actionMenu = try #require(h.rt.extensions.ui.actionMenu(extId))
    print("action menu: \(actionMenu.items.map(\.title))")
    #expect(actionMenu.items.map(\.title).suffix(2) == ["Unpin from URL Bar", "Manage Extensions"])
    let actionItem = try #require(Self.item(actionMenu, "Probe action"))
    #expect(Self.item(actionMenu, "Probe page") == nil)
    await clear()
    actionItem.menu?.performActionForItem(at: actionItem.menu!.index(of: actionItem))
    #expect(await wait(15) { await data("clicked").contains("\"menuItemId\":\"ctx-action\"") })

    // A tab's right-click menu in the sidebar: its `contexts: ["tab"]` items; clicking one tells the
    // extension which tab.
    h.rt.ui.lastMenu = nil
    h.action(tab, "contextMenu")
    let tabMenu = try #require(h.rt.ui.lastMenu)
    print("tab menu: \(tabMenu.items.map(\.title))")
    let tabItem = try #require(Self.item(tabMenu, "Probe tab"))
    #expect(Self.item(tabMenu, "Probe page") == nil)
    await clear()
    tabItem.menu?.performActionForItem(at: tabItem.menu!.index(of: tabItem))
    #expect(await wait(15) { await data("clicked").contains("\"menuItemId\":\"tab\"") })
    #expect(await data("clicked").contains("\"tabUrl\":\"\(mock.base)/p\""))

    // den adds nothing of the extensions' to a page's menu itself: WebKit adds them (no duplicates).
    let pageMenu = NSMenu()
    let dw = try #require(w as? DenWebView)
    dw.willOpenMenu(pageMenu, with: NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: win.windowNumber,
                                                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
    #expect(Self.item(pageMenu, "Menu Probe") == nil && Self.item(pageMenu, "Probe all") == nil)

    // Disabled: no shortcuts, no menu; enabled: back; removed: gone.
    #expect(h.rt.call("webext", "setEnabled", ["id": .string(extId), "enabled": false]) == .ok)
    #expect(h.rt.extensions.commandsMenu == nil)
    #expect(!(NSApp.mainMenu?.items.contains { $0.title == "Extensions" } ?? true))
    #expect(!h.rt.extensions.performCommand(for: Self.key("Á", "Y", 16, [.option, .shift], win)))
    #expect(h.rt.call("webext", "setEnabled", ["id": .string(extId), "enabled": true]) == .ok)
    #expect(await wait { Self.item(h.rt.extensions.commandsMenu, "Menu Probe: Probe Alt") != nil })

    // A second extension: both are listed. Its ⌥⇧Y is already the first one's (by id), so it is
    // listed without a key.
    let other = try ExtensionsTests.fixture()
    h.rt.call("webext", "install", ["path": .string(other.path)])
    #expect(await wait { h.rt.ui.dialogOpen })
    h.action(try #require(h.rt.extensions.prompts.first?.id), "button", ["button": "ok"])
    #expect(await wait { h.rt.extensions.contexts.count == 2 })
    let both = try #require(h.rt.extensions.commandsMenu)
    print("Extensions menu, two extensions: \(both.items.map { "\($0.title) [\($0.keyEquivalentModifierMask.rawValue >> 16):\($0.keyEquivalent)]" })")
    let hello = try #require(Self.item(both, "Den Test: Say hello"))
    #expect(Self.item(both, "Menu Probe: Probe Alt") != nil)
    let otherId = try #require(h.rt.extensions.contexts.keys.first { $0 != extId })
    #expect((hello.keyEquivalent == "") == (otherId > extId))
    #expect(h.rt.call("webext", "uninstall", ["id": .string(otherId)]) == .ok)
    #expect(Self.item(h.rt.extensions.commandsMenu, "Den Test: Say hello") == nil)
    #expect(Self.item(h.rt.extensions.commandsMenu, "Menu Probe: Probe Alt")?.keyEquivalent.lowercased() == "y")

    #expect(h.rt.call("webext", "uninstall", ["id": .string(extId)]) == .ok)
    #expect(h.rt.extensions.commandsMenu == nil)
  }

  @Test func chords() {
    func mi(_ k: String, _ m: NSEvent.ModifierFlags) -> NSMenuItem {
      let i = NSMenuItem(title: "", action: nil, keyEquivalent: k)
      i.keyEquivalentModifierMask = m
      return i
    }
    #expect(ExtensionsService.chord(mi("y", [.option, .shift])) == "opt+shift+y")
    #expect(ExtensionsService.chord(mi("Y", [.option])) == "opt+shift+y")  // uppercase means shift
    #expect(ExtensionsService.chord(mi("t", [.command])) == "cmd+t")
    #expect(ExtensionsService.chord(mi("", [.command])) == nil)
    let w: NSWindow? = nil
    #expect(ExtensionsService.chord(Self.key("Á", "Y", 16, [.option, .shift], w)) == "opt+shift+y")
    #expect(ExtensionsService.chord(Self.key("t", "t", 17, [.command, .capsLock], w)) == "cmd+t")
  }
}
