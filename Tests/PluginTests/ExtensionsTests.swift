import AppKit
import CordisValue
import DenTestSupport
import Testing
import WebKit

@testable import DenHost
@testable import PluginCores

/// The `extensions` host service with a real `WKWebExtensionController`, a local MV3 extension
/// (content script, declarativeNetRequest rule, popup, background worker) and pages served by
/// `MockServices` on 127.0.0.1, plus the `extensions` plugin's page and commands.
@MainActor
@Suite(.serialized, .watchdog)
struct ExtensionsTests {
  static func fixture() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("den-ext-fixture-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    let files: [String: String] = [
      "manifest.json": """
        {"manifest_version": 3, "name": "Den Test", "version": "1.0", "description": "A test extension",
         "permissions": ["storage", "declarativeNetRequest", "tabs", "userScripts"],
         "host_permissions": ["http://127.0.0.1/*"],
         "action": {"default_popup": "popup.html", "default_title": "Den Test"},
         "background": {"service_worker": "bg.js"},
         "options_page": "options.html",
         "content_scripts": [{"matches": ["http://127.0.0.1/*"], "js": ["cs.js"], "run_at": "document_start"}],
         "declarative_net_request": {"rule_resources": [{"id": "r", "enabled": true, "path": "rules.json"}]},
         "icons": {"64": "icon.png"}}
        """,
      "rules.json": #"[{"id": 1, "priority": 1, "action": {"type": "block"}, "condition": {"urlFilter": "blocked.js", "resourceTypes": ["script"]}}]"#,
      "cs.js": "document.documentElement.dataset.denExt = '1';",
      "bg.js": "chrome.action.setBadgeText({text: '7'});",
      "popup.html": "<!doctype html><title>Den Test Popup</title><body style='margin:0;width:220px;height:140px;font:13px -apple-system'>Popup</body>",
      "options.html": "<!doctype html><title>Den Test Options</title><body>Options</body>",
    ]
    for (k, v) in files { try v.write(to: d.appendingPathComponent(k), atomically: true, encoding: .utf8) }
    let img = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { r in
      NSColor.systemPurple.setFill()
      NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14).fill()
      return true
    }
    try WebViewsService.encode(img, width: 32, jpeg: false)!.write(to: d.appendingPathComponent("icon.png"))
    return d
  }

  func wait(_ seconds: Double = 45, file: StaticString = #fileID, line: UInt = #line, _ cond: () -> Bool) async -> Bool {  // generous: loaded machine
    await Wait.until("a condition", seconds: seconds, file: file, line: line) { cond() }
  }

  func js(_ w: WKWebView, _ s: String, line: UInt = #line) async -> Any? { await Wait.js(w, s, line: line) }

  @Test func nothingInstalledCostsNothing() async {
    let h = Harness()
    h.startTabs()
    let id = h.ids("today").first!
    h.tabs("select", ["id": .string(id)])
    #expect(h.rt.webviews.record(id)?.webView != nil)
    #expect(h.rt.extensions.controller == nil)
    #expect(h.rt.webviews.record(id)?.webView?.configuration.webExtensionController == nil)
    #expect(h.rt.call("webext", "list") == [])
    #expect(h.rt.call("webext", "state")["controller"] == false)
    #expect(!FileManager.default.fileExists(atPath: h.rt.extensions.root.path))
  }

  @Test func installRunBlockPopupAndRemove() async throws {
    let mock = MockServices()
    try mock.start()
    defer { mock.stop() }
    mock.page("/page", "<!doctype html><title>start</title><script src='/blocked.js' onload=\"document.title='loaded'\" onerror=\"document.title='blocked'\"></script>")
    mock.page("/blocked.js", "window.adRan = true;", type: "text/javascript")
    let dir = try Self.fixture()
    let h = Harness()
    h.startTabs()
    h.record(["webext.installed", "webext.failed", "webext.changed"])
    // A tab open before the first install: its web view is rebuilt with the controller.
    let tab = h.tabs("open", ["url": .string(mock.base + "/page")]).s("id")
    h.tabs("select", ["id": .string(tab)])
    #expect(await wait { h.rt.webviews.record(tab)?.title == "loaded" })

    #expect(h.rt.call("webext", "install", ["path": .string(dir.path)])["pending"] == true)
    #expect(await wait { h.rt.ui.dialogOpen })
    #expect(h.rt.ui.dialog.title.stringValue == "Add “Den Test” to den?")
    #expect(h.rt.ui.dialog.message.stringValue.contains("Read and change your data on 127.0.0.1"))
    #expect(h.rt.ui.dialog.message.stringValue.contains("Block content on any page"))
    #expect(h.rt.ui.dialog.message.stringValue.contains("Not available in WebKit: userScripts"))
    h.action("extensions.prompt:1", "button", ["button": "ok"])
    #expect(await wait { h.events.contains { $0.0 == "webext.installed" } })
    #expect(!h.events.contains { $0.0 == "webext.failed" })

    let list = h.rt.call("webext", "list")
    #expect(list.array?.count == 1)
    let e = list[0]
    let extId = e.s("id")
    #expect(e.s("name") == "Den Test" && e.s("version") == "1.0" && e.b("enabled") && e.b("pinned"))
    #expect(e.b("loaded") && e.b("hasPopup") && e.b("hasOptions"))
    #expect(e.s("background") == "on demand")
    #expect(e.a("unsupported") == ["userScripts"])
    #expect(FileManager.default.fileExists(atPath: e.s("icon")))
    // Persisted: registry + unpacked copy in the extensions folder (not the source folder).
    let reg = ExtensionRegistry(root: h.rt.extensions.root)
    #expect(reg.item(extId)?.dir == reg.folder(extId).path)
    #expect(FileManager.default.fileExists(atPath: reg.folder(extId).appendingPathComponent("manifest.json").path))
    #expect(reg.item(extId)?.grantedPatterns == ["http://127.0.0.1/*"])

    // The old tab's web view now has the controller; the content script runs and the DNR rule blocks.
    let ctl = try #require(h.rt.extensions.controller)
    #expect(await wait { h.rt.webviews.record(tab)?.webView?.configuration.webExtensionController === ctl })
    var blocked = false
    for _ in 0..<20 where !blocked {
      h.rt.call("webviews", "reload", ["id": .string(tab)])
      blocked = await wait(3) { h.rt.webviews.record(tab)?.title == "blocked" }
    }
    #expect(blocked)
    let w = try #require(h.rt.webviews.record(tab)?.webView)
    #expect(await js(w, "document.documentElement.dataset.denExt") as? String == "1")
    #expect(await js(w, "String(window.adRan)") as? String == "undefined")

    // Tabs as WebKit sees them: the current space's tabs, with the selected one active.
    let ctx = try #require(h.rt.extensions.contexts[extId])
    let win = try #require(ctx.openWindows.first)
    #expect(win.tabs?(for: ctx).count == h.rt.extensions.tabIds().count)
    #expect((win.activeTab?(for: ctx) as? ExtTab)?.id == tab)

    // Popup: shown in den's popover, sized by its page.

    #expect(h.rt.call("webext", "action", ["id": .string(extId)]) == .ok)
    #expect(await wait(45) { h.rt.extensions.ui.popupFor == extId })  // a new web process: slow on a loaded machine
    #expect(await wait(30) { h.rt.extensions.ui.popupSizeForTesting == CGSize(width: 220, height: 140) })
    h.rt.call("webext", "closePopup")
    #expect(h.rt.extensions.ui.popupFor == nil)

    // Badge from the background worker reaches the menu items.
    #expect(await wait { h.rt.extensions.menuItems().first?.badge == "7" })

    // Pin, site access, disable, enable.
    #expect(h.rt.call("webext", "setPinned", ["id": .string(extId), "pinned": false]) == .ok)
    #expect(h.rt.call("webext", "get", ["id": .string(extId)])["pinned"] == false)
    #expect(h.rt.call("webext", "setSiteAccess", ["id": .string(extId), "mode": "click"]) == .ok)
    #expect(ctx.currentPermissionMatchPatterns.isEmpty)
    #expect(h.rt.call("webext", "allowSite", ["id": .string(extId), "site": "https://www.example.com/a", "allowed": true]) == .ok)
    #expect(h.rt.call("webext", "get", ["id": .string(extId)])["sites"] == ["example.com"])
    #expect(h.rt.call("webext", "get", ["id": .string(extId)])["siteAccess"] == "sites")
    #expect(h.rt.call("webext", "setEnabled", ["id": .string(extId), "enabled": false]) == .ok)
    #expect(h.rt.extensions.contexts[extId] == nil)
    #expect(h.rt.call("webext", "setEnabled", ["id": .string(extId), "enabled": true]) == .ok)
    #expect(await wait { h.rt.extensions.contexts[extId] != nil })

    // Uninstall removes the folder, the icon and the registry entry.
    #expect(h.rt.call("webext", "uninstall", ["id": .string(extId)]) == .ok)
    #expect(h.rt.call("webext", "list") == [])
    #expect(!FileManager.default.fileExists(atPath: reg.folder(extId).path))
    #expect(ExtensionRegistry(root: h.rt.extensions.root).isEmpty)
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("manifest.json").path))  // the source is untouched
  }

  @Test func cancelAndBadPackages() async throws {
    let h = Harness()
    h.record(["webext.failed", "webext.installed"])
    let dir = try Self.fixture()
    h.rt.call("webext", "install", ["path": .string(dir.path)])
    #expect(await wait { h.rt.ui.dialogOpen })
    h.action("extensions.prompt:1", "button", ["button": "cancel"])
    #expect(await wait { h.events.contains { $0.0 == "webext.failed" && $0.1.s("error") == "cancelled" } })
    #expect(h.rt.call("webext", "list") == [])
    let junk = FileManager.default.temporaryDirectory.appendingPathComponent("den-junk-\(UUID()).crx")
    try Data("definitely not a crx".utf8).write(to: junk)
    h.rt.call("webext", "install", ["path": .string(junk.path)])
    #expect(await wait { h.events.contains { $0.0 == "webext.failed" && $0.1.s("error") == "not a CRX or ZIP file" } })
    #expect(h.rt.call("webext", "install", ["path": "/nope/missing.crx"]).isError)
    #expect(h.rt.call("webext", "installFromStore", ["url": "https://example.com/detail/x"]).isError)
    #expect(!h.events.contains { $0.0 == "webext.installed" })
  }

  @Test func pageCommandsAndRemoveDialog() async throws {
    let h = Harness()
    h.startTabs()
    var registered: [Value] = []
    h.rt.plugins.provide("commands") { m, a in
      if m == "register" { registered.append(a) }
      return .okay
    }
    let core = ExtensionsCore(env: h.env)
    h.rt.plugins.provide("extensions") { m, a in core.handle(m, a) }
    core.start()
    // "Extensions" itself is the command bar's built-in destination (extensions.open).
    #expect(registered.map { $0.s("title") } == ["Install Extension from File…", "Get Extensions"])
    #expect(registered.allSatisfy { $0.s("owner") == "extensions" })

    // Empty page.
    #expect(h.rt.call("extensions", "open") == .okay)
    #expect(h.rt.ui.sheets["overlay.extensions"] != nil)
    #expect(h.rt.ui.sheets["overlay.extensions"]?.titleLabel.stringValue == "Extensions")
    let empty = h.rt.ui.sheets["overlay.extensions"]!.node
    #expect(empty.a("children").contains { $0.s("id") == "extensions.empty" })

    // Install, then the list shows a row; its details show access, permissions and buttons.
    let dir = try Self.fixture()
    h.record(["webext.installed"])
    h.rt.call("webext", "install", ["path": .string(dir.path)])
    #expect(await wait { h.rt.ui.dialogOpen })
    h.action("extensions.prompt:1", "button", ["button": "ok"])
    #expect(await wait { h.events.contains { $0.0 == "webext.installed" } })
    let extId = h.rt.call("webext", "list")[0].s("id")
    #expect(await wait { h.rt.ui.sheets["overlay.extensions"]?.node.a("children").first?.s("id") == "webext.installed" })
    let row = h.rt.ui.sheets["overlay.extensions"]!.node.a("children")[0].a("children")[0]
    #expect(row.s("type") == "extensionRow" && row.s("title") == "Den Test" && row.b("on"))
    h.action("extensions.row:" + extId, "open")
    let details = h.rt.ui.sheets["overlay.extensions"]!.node
    #expect(details.s("title") == "Den Test")
    let ids = details.a("children").flatMap { [$0.s("id")] + $0.a("children").map { $0.s("id") } }
    #expect(ids.contains("extensions.access") && ids.contains("extensions.options") && ids.contains("extensions.remove") && ids.contains("extensions.unsupported"))
    // Toggle off from the list row, back on from details.
    h.action("extensions.row:" + extId, "toggle", ["on": false])
    #expect(h.rt.call("webext", "get", ["id": .string(extId)])["enabled"] == false)
    h.action("extensions.enabled", "toggle", ["on": true])
    #expect(h.rt.call("webext", "get", ["id": .string(extId)])["enabled"] == true)
    // Remove asks first.
    h.action("extensions.remove", "click")
    #expect(h.rt.ui.dialogOpen && h.rt.ui.dialog.title.stringValue == "Remove “Den Test”?")
    h.action("extensions.remove.dialog", "button", ["button": "remove"])
    #expect(h.rt.call("webext", "list") == [])
    #expect(h.rt.ui.sheets["overlay.extensions"]?.node.a("children").contains { $0.s("id") == "extensions.empty" } == true)
    // Menu "Manage Extensions" → page; Esc closes it.
    h.action("extensions", "dismiss")
    #expect(h.rt.ui.sheets["overlay.extensions"] == nil)
    h.rt.plugins.emit("webext.openPage")
    #expect(h.rt.ui.sheets["overlay.extensions"] != nil)
    core.stop()
    #expect(h.rt.ui.sheets["overlay.extensions"] == nil)
  }
}
