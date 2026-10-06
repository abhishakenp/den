import AppKit
import CordisValue
import DenTestSupport
import Foundation
import Testing
import WebKit

@testable import DenHost
@testable import PluginCores

/// The `pwa` plugin against the real host: real pages and manifests served by `MockServices` on
/// 127.0.0.1, real manifest detection through `webviews.inject` in the plugin's isolated world,
/// real installation records in storage, standalone windows on the app's own profile.
@MainActor
@Suite(.serialized, .watchdog)
struct PwaTests {
  @MainActor final class Rig {
    let h = Harness()
    let mock = MockServices()
    var core: PwaCore!
    var toasts: [String] = []
    var commands: [String: Value] = [:]  // command id -> register args (absent: unregistered)
    var timersBefore = 0

    init() throws {
      try mock.start()
      h.rt.permissions.grant("pwa", ["pages:*"])
      h.startTabs()
      var env = h.env
      let base = env.invoke
      env.invoke = { [unowned self] s, m, a in
        if s == "ui", m == "set", a.s("slot") == "toast" { toasts.append(a["tree"].s("text")); return .okay }
        if s == "commands", m == "register" { commands[a.s("id")] = a; return .okay }
        if s == "commands", m == "unregister" { commands[a.s("id")] = nil; return .okay }
        return base(s, m, a)
      }
      let core = PwaCore(env: env)
      self.core = core
      h.rt.plugins.provide("pwa") { m, a in core.handle(m, a) }
      timersBefore = h.timers.count
      core.start()
    }

    func startNow() { core.startNow() }

    /// A real page (with its manifest) on the mock server, open and selected in a tab.
    @discardableResult
    func tab(_ path: String = "/mail") async -> String {
      let id = h.tabs("open", ["url": .string(mock.base + path)])["id"].string!
      _ = h.tabs("select", ["id": .string(id)])
      return id
    }

    func until(_ seconds: Double = 20, line: UInt = #line, _ cond: () async -> Bool) async -> Bool {
      await Wait.until("a condition", seconds: seconds, line: line) { await cond() }
    }

    func serveManifest(_ body: String) {
      mock.page("/manifest.webmanifest", body, type: "application/manifest+json")
    }

    static let acmeManifest = #"""
      {
        "id": "/mail",
        "name": "Acme Mail",
        "short_name": "Acme",
        "start_url": "/home?source=pwa",
        "scope": "/",
        "display": "standalone",
        "theme_color": "#3367d6",
        "icons": [
          {"src": "icons/mail-192.png", "sizes": "192x192", "type": "image/png"},
          {"src": "icons/mail-512.png", "sizes": "512x512", "type": "image/png"},
          {"src": "icons/mail-mono.svg", "sizes": "any", "purpose": "monochrome"}
        ]
      }
      """#

    static let mailPage = #"""
      <!doctype html><title>Acme Mail</title><link rel="manifest" href="/manifest.webmanifest"><body>Inbox</body>
      """#
  }

  /// Nothing is built before the first window: one timer, no menu, no commands, no storage.
  @Test func nothingRunsBeforeTheFirstWindow() throws {
    let rig = try Rig()
    defer { rig.mock.stop() }
    #expect(rig.h.rt.webviews.contextMenu == nil)
    #expect(rig.commands.isEmpty)
    #expect(rig.h.storage("pwa", "apps").isNull)
    #expect(rig.h.timers.count == rig.timersBefore + 1)
  }

  /// Manifest detection: the page's link is found, the manifest is fetched with the page's own
  /// session, and every URL comes back resolved against the manifest's URL.
  @Test func manifestDetection() async throws {
    let rig = try Rig()
    defer { rig.mock.stop() }
    rig.serveManifest(Rig.acmeManifest)
    rig.mock.page("/mail", Rig.mailPage)
    rig.h.record(["pwa.detected"])
    rig.startNow()

    let tab = await rig.tab()
    #expect(await rig.until { rig.core.detections[tab] != nil })
    let m = try #require(rig.core.detections[tab]?.manifest)
    #expect(m.s("url") == rig.mock.base + "/manifest.webmanifest")
    #expect(m.s("id") == rig.mock.base + "/mail")
    #expect(m.s("name") == "Acme Mail")
    #expect(m.s("shortName") == "Acme")
    #expect(m.s("startUrl") == rig.mock.base + "/home?source=pwa")
    #expect(m.s("scope") == rig.mock.base + "/")
    #expect(m.s("display") == "standalone")
    #expect(m.a("icons").count == 3)
    #expect(m.a("icons")[1].s("src") == rig.mock.base + "/icons/mail-512.png")
    // The offer: pwa.detected names the page and the parsed manifest.
    #expect(await rig.until { rig.h.events.contains { $0.0 == "pwa.detected" && $0.1.s("webview") == tab && $0.1["manifest"].s("name") == "Acme Mail" } })
    // The page context menu carries "Install as Web App".
    #expect(rig.h.rt.webviews.contextMenu != nil)
    #expect(rig.commands["pwa.install"]?.s("title") == "Install This Page as a Web App")
  }

  /// A page without a manifest costs one probe per load and offers nothing.
  @Test func pageWithoutManifestOffersNothing() async throws {
    let rig = try Rig()
    defer { rig.mock.stop() }
    rig.mock.page("/plain", "<!doctype html><title>Plain</title><body>no manifest here</body>")
    rig.h.record(["pwa.detected"])
    rig.startNow()

    let tab = await rig.tab("/plain")
    #expect(await rig.until { rig.core.detections[tab] != nil })
    #expect(rig.core.detections[tab]?.manifest.isNull == true)
    #expect(!rig.h.events.contains { $0.0 == "pwa.detected" && $0.1.s("webview") == tab })
    let r = rig.h.rt.call("pwa", "install", ["webview": .string(tab)])
    #expect(r.isErr)
    #expect(r.s("error") == "pwa: no web app manifest detected on this page")
  }

  /// Installation records: the app lands in storage with its resolved fields; installing the
  /// same site again updates the one record (the W3C identity), it doesn't add a second.
  @Test func installationRecords() async throws {
    let rig = try Rig()
    defer { rig.mock.stop() }
    rig.serveManifest(Rig.acmeManifest)
    rig.mock.page("/mail", Rig.mailPage)
    rig.h.record(["pwa.installed"])
    rig.startNow()

    let tab = await rig.tab()
    #expect(await rig.until { rig.core.detections[tab] != nil })

    let r = rig.h.rt.call("pwa", "install", ["webview": .string(tab)])
    let appId = rig.mock.base + "/mail"
    #expect(r["app"].s("id") == appId)
    #expect(r["updated"] == false)
    #expect(r["app"].s("name") == "Acme Mail")
    #expect(r["app"].s("startUrl") == rig.mock.base + "/home?source=pwa")
    #expect(r["app"].s("scope") == rig.mock.base + "/")
    #expect(r["app"].s("display") == "standalone")
    // The 512 icon wins; the monochrome "any" one is skipped.
    #expect(r["app"].s("icon") == rig.mock.base + "/icons/mail-512.png")

    // The stored record (ns "pwa", key "apps"), stamped with the install time.
    let stored = rig.h.storage("pwa", "apps")[appId]
    #expect(stored.s("name") == "Acme Mail")
    #expect(stored.s("startUrl") == rig.mock.base + "/home?source=pwa")
    #expect(stored.s("manifestUrl") == rig.mock.base + "/manifest.webmanifest")
    #expect(stored.i("installedAt") == rig.h.clock)
    #expect(rig.h.events.contains { $0.0 == "pwa.installed" && $0.1.s("id") == appId })
    #expect(rig.toasts.last == "Installed Acme Mail")
    // One "Open Acme Mail" command per installed app.
    #expect(rig.commands["pwa.open:" + appId]?.s("title") == "Open Acme Mail")
    #expect(rig.h.rt.call("pwa", "list")["apps"].array?.count == 1)

    // The site ships a renamed manifest: installing again updates the record in place.
    rig.serveManifest(#"{"id": "/mail", "name": "Acme Mail 2", "start_url": "/home?source=pwa", "icons": []}"#)
    _ = rig.h.rt.call("pwa", "detect", ["webview": .string(tab), "refresh": true])
    #expect(await rig.until { rig.core.detections[tab]?.manifest.s("name") == "Acme Mail 2" })
    let r2 = rig.h.rt.call("pwa", "install", ["webview": .string(tab)])
    #expect(r2["updated"] == true)
    #expect(rig.h.storage("pwa", "apps")[appId].s("name") == "Acme Mail 2")
    #expect(rig.h.rt.call("pwa", "list")["apps"].array?.count == 1)
    #expect(rig.toasts.last == "Updated Acme Mail 2")
  }

  /// A manifest without a name is not an installable app.
  @Test func namelessManifestCannotInstall() async throws {
    let rig = try Rig()
    defer { rig.mock.stop() }
    rig.serveManifest(#"{"start_url": "/home", "display": "standalone"}"#)
    rig.mock.page("/mail", Rig.mailPage)
    rig.startNow()

    let tab = await rig.tab()
    #expect(await rig.until { rig.core.detections[tab]?.manifest.isNull == false })
    let r = rig.h.rt.call("pwa", "install", ["webview": .string(tab)])
    #expect(r.isErr)
    #expect(r.s("error") == "pwa: the manifest has no name or start URL")
    #expect(rig.h.storage("pwa", "apps").isNull)
  }

  /// Uninstall: the record and its command go; an open window of the app closes with it.
  @Test func uninstallRemovesTheRecord() async throws {
    let rig = try Rig()
    defer { rig.mock.stop() }
    rig.serveManifest(Rig.acmeManifest)
    rig.mock.page("/mail", Rig.mailPage)
    rig.h.record(["pwa.uninstalled"])
    rig.startNow()

    let tab = await rig.tab()
    #expect(await rig.until { rig.core.detections[tab] != nil })
    let appId = rig.mock.base + "/mail"
    _ = rig.h.rt.call("pwa", "install", ["webview": .string(tab)])
    let opened = rig.h.rt.call("pwa", "open", ["id": .string(appId)])
    #expect(opened.s("window").isEmpty == false)

    #expect(rig.h.rt.call("pwa", "uninstall", ["id": .string(appId)])["ok"] == true)
    #expect(rig.h.storage("pwa", "apps")[appId].isNull)
    #expect(rig.commands["pwa.open:" + appId] == nil)
    #expect(rig.h.events.contains { $0.0 == "pwa.uninstalled" && $0.1.s("id") == appId })
    #expect(await rig.until { rig.h.rt.call("window", "listMini").array?.isEmpty == true })
    #expect(rig.h.rt.call("pwa", "uninstall", ["id": .string(appId)]).isErr)
  }

  /// The standalone window: the app's page runs on its own profile (its own website data);
  /// opening again brings the same window forward; closing the window closes the page.
  @Test func standaloneWindowWithOwnData() async throws {
    let rig = try Rig()
    defer { rig.mock.stop() }
    rig.serveManifest(Rig.acmeManifest)
    rig.mock.page("/mail", Rig.mailPage)
    rig.mock.page("/home", "<!doctype html><title>Acme Home</title><body>the app</body>")
    rig.h.record(["pwa.opened", "pwa.windowClosed"])
    rig.startNow()

    let tab = await rig.tab()
    #expect(await rig.until { rig.core.detections[tab] != nil })
    let appId = rig.mock.base + "/mail"
    _ = rig.h.rt.call("pwa", "install", ["webview": .string(tab)])

    let r = rig.h.rt.call("pwa", "open", ["id": .string(appId)])
    let win = try #require(r["window"].string)
    let web = try #require(r["webview"].string)
    #expect(r["existing"].isNull)
    // Its own data: a profile of its own, so cookies and storage are the app's, not the browser's.
    #expect(rig.h.rt.call("webviews", "get", ["id": .string(web)]).s("profile") == "pwa:" + appId)
    #expect(rig.h.rt.call("webviews", "get", ["id": .string(web)]).s("url") == rig.mock.base + "/home?source=pwa")
    #expect(rig.h.rt.call("window", "listMini")[0]["id"].string == win)
    #expect(rig.h.events.contains { $0.0 == "pwa.opened" && $0.1.s("id") == appId })

    // Opening again focuses the same window.
    let r2 = rig.h.rt.call("pwa", "open", ["id": .string(appId)])
    #expect(r2["existing"] == true)
    #expect(r2.s("window") == win)
    #expect(rig.h.rt.call("window", "listMini").array?.count == 1)

    // Closing the window closes the app's page.
    _ = rig.h.rt.call("window", "closeMini", ["id": .string(win)])
    #expect(await rig.until { rig.core.open.isEmpty })
    #expect(await rig.until { rig.h.rt.call("webviews", "get", ["id": .string(web)]).isErr })
    #expect(rig.h.events.contains { $0.0 == "pwa.windowClosed" && $0.1.s("id") == appId })
  }

  /// The window's "Open in <space>": the app's page becomes a today tab, keeping its web view.
  @Test func standaloneWindowOpensInSpace() async throws {
    let rig = try Rig()
    defer { rig.mock.stop() }
    rig.serveManifest(Rig.acmeManifest)
    rig.mock.page("/mail", Rig.mailPage)
    rig.mock.page("/home", "<!doctype html><title>Acme Home</title><body>the app</body>")
    rig.startNow()

    let tab = await rig.tab()
    #expect(await rig.until { rig.core.detections[tab] != nil })
    let appId = rig.mock.base + "/mail"
    _ = rig.h.rt.call("pwa", "install", ["webview": .string(tab)])
    let r = rig.h.rt.call("pwa", "open", ["id": .string(appId)])
    let (win, web) = (r.s("window"), r.s("webview"))

    rig.h.rt.plugins.emit("window.miniAction", ["id": .string(win), "webview": .string(web), "action": "open"])
    #expect(await rig.until { rig.h.rt.call("window", "listMini").array?.isEmpty == true })
    #expect(rig.core.open.isEmpty)
    #expect(rig.h.ids("today").contains(web))
  }

  /// `PwaCore.app(from:)`: the installable-app rule and the record fields, no host needed.
  @Test func appFromManifest() {
    let page = "https://mail.test/inbox"
    let m: Value = [
      "url": "https://mail.test/manifest.json",
      "name": "Mail",
      "startUrl": "https://mail.test/home",
      "scope": "https://mail.test/",
      "display": "standalone",
      "icons": [["src": "https://mail.test/64.png", "sizes": "64x64"], ["src": "https://mail.test/512.png", "sizes": "512x512"]],
    ]
    let app = PwaCore.app(from: m, pageUrl: page, at: 42)
    #expect(app?.id == "https://mail.test/home")  // no manifest `id`: the start URL is the identity
    #expect(app?.name == "Mail")
    #expect(app?.icon == "https://mail.test/512.png")
    #expect(app?.installedAt == 42)

    // The short name stands in; the page URL is the start when the manifest says none; display
    // defaults to "browser"; a scalable ("any") icon beats every raster size.
    let sparse: Value = ["url": "https://other.test/m.json", "shortName": "Notes", "icons": [["src": "https://other.test/512.png", "sizes": "512x512"], ["src": "https://other.test/app.svg", "sizes": "any"]]]
    let s = PwaCore.app(from: sparse, pageUrl: page, at: 1)
    #expect(s?.name == "Notes")
    #expect(s?.startUrl == page)
    #expect(s?.display == "browser")
    #expect(s?.icon == "https://other.test/app.svg")

    // No icons: the site's favicon. No name at all or an unreadable manifest: not installable.
    let noIcons = PwaCore.app(from: ["name": "Plain"], pageUrl: page, at: 1)
    #expect(noIcons?.icon == URLs.favicon(page))
    #expect(PwaCore.app(from: ["startUrl": "https://mail.test/home"], pageUrl: page, at: 1) == nil)
    #expect(PwaCore.app(from: .null, pageUrl: page, at: 1) == nil)
    #expect(PwaCore.app(from: ["url": "https://mail.test/m.json", "error": "the manifest answered HTTP 404"], pageUrl: page, at: 1) == nil)
    #expect(PwaCore.iconSize("192x192 512x512") == 512)
    #expect(PwaCore.iconSize("any") == 100_000)
    #expect(PwaCore.iconSize("") == 0)
  }
}
