import AppKit
import CordisValue
import Foundation
import Testing
import WebKit

@testable import DenHost
@testable import PluginCores

/// The `shields` plugin: its pure parts (tracking parameters, bounce redirects, Punycode and
/// lookalike domains) and the plugin on the real `sitepolicy`, `ui` and `settings` services.
@MainActor
@Suite(.serialized, .watchdog)
struct ShieldsTests {
  // MARK: Clean links

  @Test func stripsTrackingParametersAndKeepsTheRest() {
    let r = CleanLinks.strip("https://shop.example/p?id=7&utm_source=news&utm_medium=mail&fbclid=AbC&color=red#reviews")
    #expect(r.url == "https://shop.example/p?id=7&color=red#reviews")
    #expect(r.removed == ["utm_source", "utm_medium", "fbclid"])
    #expect(CleanLinks.strip("https://example.com/?gclid=1").url == "https://example.com/")
    #expect(CleanLinks.strip("https://example.com/a?q=utm_source").removed.isEmpty)  // a value, not a name
    #expect(CleanLinks.strip("https://example.com/#x?utm_source=1").removed.isEmpty)  // fragment only
    #expect(CleanLinks.strip("https://example.com/?MC_EID=1&Srsltid=2").url == "https://example.com/")
    // Site-scoped names only go where they are trackers.
    #expect(CleanLinks.strip("https://www.youtube.com/watch?v=abc&si=XYZ").url == "https://www.youtube.com/watch?v=abc")
    #expect(CleanLinks.strip("https://example.com/?si=1").removed.isEmpty)
    #expect(CleanLinks.strip("https://x.com/user/status/1?s=20&t=abc").url == "https://x.com/user/status/1")
  }

  @Test func unwrapsBounceTrackersButNotSecurityRedirectors() {
    let d = "https%3A%2F%2Fwww.example.com%2Fitem%3Fid%3D5%26utm_source%3Dx"
    #expect(CleanLinks.unwrap("https://click.linksynergy.com/deeplink?id=a&mid=1&murl=" + d) == "https://www.example.com/item?id=5&utm_source=x")
    #expect(CleanLinks.unwrap("https://www.awin1.com/cread.php?awinmid=1&ued=" + d) != nil)
    #expect(CleanLinks.unwrap("https://www.awin1.com/other.php?ued=" + d) == nil)  // path must match
    #expect(CleanLinks.unwrap("https://out.reddit.com/t3_x?url=" + d + "&token=z") != nil)
    #expect(CleanLinks.unwrap("https://www.google.com/url?q=" + d) == nil)
    #expect(CleanLinks.unwrap("https://l.facebook.com/l.php?u=" + d) == nil)
    #expect(CleanLinks.unwrap("https://click.linksynergy.com/deeplink?murl=javascript%3Aalert(1)") == nil)
  }

  // MARK: IDN and lookalikes

  @Test func punycodeDecodesRFC3492Samples() {
    #expect(IDN.string(IDN.punycode("bcher-kva")!) == "bücher")
    #expect(IDN.string(IDN.punycode("mnchen-3ya")!) == "münchen")
    #expect(IDN.string(IDN.punycode("pple-43d")!) == "\u{430}pple")
    #expect(IDN.string(IDN.punycode("wgv71a119e")!) == "日本語")
    #expect(IDN.punycode("99999999999999999") == nil)  // overflow
    #expect(IDN.punycode("abc-!!") == nil)
  }

  @Test func displayShowsSafeUnicodeAndKeepsSpoofsInPunycode() {
    #expect(IDN.display("xn--bcher-kva.de") == "bücher.de")
    #expect(IDN.display("xn--wgv71a119e.jp") == "日本語.jp")
    #expect(IDN.display("xn--pple-43d.com") == "xn--pple-43d.com")  // Latin + Cyrillic
    #expect(IDN.display("xn--80ak6aa92e.com") == "xn--80ak6aa92e.com")  // all-Cyrillic "аррӏе"
    #expect(IDN.display("xn--d1acufc.xn--p1ai") == "домен.рф")  // real Cyrillic words stay readable
    #expect(IDN.display("example.com") == "example.com")
    #expect(URLs.display("https://xn--bcher-kva.de/x") == "bücher.de")
  }

  @Test func lookalikesPointAtTheSiteTheyImitate() {
    #expect(Lookalike.target("xn--pple-43d.com") == "apple.com")
    #expect(Lookalike.target("xn--80ak6aa92e.com") == "apple.com")
    #expect(Lookalike.target("g00gle.com") == "google.com")
    #expect(Lookalike.target("arnazon.com") == "amazon.com")
    #expect(Lookalike.target("paypa1.com") == "paypal.com")
    #expect(Lookalike.target("login.xn--pypal-4ve.com") == "paypal.com")  // "pаypal" with a Cyrillic а
    #expect(Lookalike.target("apple.com") == nil)
    #expect(Lookalike.target("mail.google.com") == nil)
    #expect(Lookalike.target("xn--bcher-kva.de") == nil)
    #expect(Lookalike.target("modern.com") == nil)
  }

  // MARK: The plugin

  func start(_ h: Harness) -> ShieldsCore {
    let core = ShieldsCore(env: h.env)
    h.rt.plugins.provide("shields") { m, a in core.handle(m, a) }
    core.start()
    return core
  }

  func until(_ seconds: Double = 20, _ f: () async -> Bool) async throws -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
      if await f() { return true }
      try await Task.sleep(for: .milliseconds(50))
    }
    return false
  }

  @Test func pushesRulesAndGuardsNavigations() {
    let h = Harness()
    let core = start(h)
    #expect(h.rt.sitePolicy.defaultRule.lists == ["shields.ads", "shields.trackers", "shields.cookies"])
    #expect(h.rt.sitePolicy.defaultRule.autoplay == "sound")
    #expect(h.rt.sitePolicy.defaultRule.scripts == ["shields.scriptlets", "shields.sites"])
    #expect(h.rt.sitePolicy.httpsFirst)
    // The guard: parameters, bounce, lookalike.
    let p = h.rt.call("shields", "navigate", ["url": "https://news.example/a?utm_campaign=x&id=2"])
    #expect(p["action"] == "rewrite")
    #expect(p["url"] == "https://news.example/a?id=2")
    let b = h.rt.call("shields", "navigate", ["url": "https://click.linksynergy.com/deeplink?murl=https%3A%2F%2Fshop.example%2F%3Fgclid%3D1"])
    #expect(b["url"] == "https://shop.example/")
    #expect(b["kind"] == "bounce")
    let l = h.rt.call("shields", "navigate", ["url": "https://xn--pple-43d.com/login"])
    #expect(l["action"] == "interstitial")
    #expect(l["page"]["title"] == "Did you mean apple.com?")
    #expect(h.rt.call("shields", "navigate", ["url": "https://example.com/"]).isNull)

    // Per site: blocker off drops the ad and tracker lists there and stops link cleaning.
    #expect(h.rt.call("shields", "site", ["host": "news.example", "blocker": false]).isError == false)
    #expect(h.rt.sitePolicy.rule(for: "www.news.example").lists == ["shields.cookies"])
    #expect(h.rt.sitePolicy.rule(for: "www.news.example").scripts.isEmpty)
    #expect(h.rt.call("shields", "navigate", ["url": "https://news.example/a?utm_campaign=x"]).isNull)
    #expect(h.storage("shields", "sites")["news.example"]["blocker"] == false)
    // Back to the global choice: no exception left.
    h.rt.call("shields", "site", ["host": "news.example", "blocker": true])
    #expect(h.storage("shields", "sites") == .object([]))
    #expect(core.pill("https://news.example/")["icon"] == "sf:shield.lefthalf.filled")

    // Settings: global switches arrive through the settings service.
    h.rt.call("settings", "set", ["id": "shields", "key": "cookies", "value": false])
    #expect(h.rt.sitePolicy.defaultRule.lists == ["shields.ads", "shields.trackers"])
    h.rt.call("settings", "set", ["id": "shields", "key": "https", "value": false])
    #expect(!h.rt.sitePolicy.httpsFirst)
    core.stop()
    #expect(h.rt.sitePolicy.defaultRule.lists.isEmpty)
    #expect(h.rt.sitePolicy.defaultRule.scripts.isEmpty)
  }

  /// The shipped scriptlet engine and data load (YouTube's hosts), and a refresh that brings
  /// changed data reloads them.
  @Test func scriptletsLoadForYouTube() async throws {
    let h = Harness()
    let core = start(h)
    #expect(try await until { core.scriptletsReady })
    let info = (h.rt.call("sitepolicy", "list").array ?? []).first { $0.str("name") == "shields.scriptlets" }
    #expect(info?["hosts"].array?.contains("youtube.com") == true)
    #expect(core.handle("get", ["host": "youtube.com"])["scriptlets"] == true)
    #expect(!core.scriptletsVersion.isEmpty)
    core.fetched(["plugin": "shields", "file": "scriptlets.json", "ok": true, "changed": true])
    #expect(h.storage("shields", "scriptletsChecked").int ?? 0 > 0)
    core.stop()
  }

  @Test func panelTogglesOfferAReloadAndWarnAboutUnsavedInput() async throws {
    let h = Harness()
    let tabs = h.startTabs()
    let core = start(h)
    let id = h.rt.call("tabs", "open", ["url": "https://example.com/"])["id"]
    h.rt.call("tabs", "select", ["id": id])
    let w = h.rt.webviews.materialize(id.string!)!
    w.loadHTMLString("<textarea id=t></textarea>", baseURL: URL(string: "https://example.com/"))
    #expect(try await until { !w.isLoading && w.url?.host == "example.com" })

    // The pill carries the shield; clicking it opens the panel in the popover slot.
    #expect(try await until { tabs.pillButtons[id.string!]?.first?.0 == "shields" })
    #expect(tabs.pillButtons[id.string!]?.first?.1.first?["icon"] == "sf:shield.lefthalf.filled")
    h.action("shields.pill", "click", ["webview": id])
    #expect(core.panelOpen)
    #expect(h.rt.call("ui", "get")["overlays"].array?.contains("popover") == true)
    let tree = core.panelTree()
    #expect(tree["type"] == "panel")
    #expect(tree["title"] == "example.com")
    let rows = tree["children"][0]["children"].array ?? []
    #expect(rows.first?["shortcut"] == "⌥⌘B")
    #expect(rows.contains { $0["id"] == "shields.zoom" })

    _ = try await w.evaluateJavaScript("document.getElementById('t').value = 'draft'")
    h.action("shields.blocker", "toggle", ["on": false])
    #expect(core.pendingReload)
    #expect(try await until { core.unsaved })
    let note = core.panelTree()["children"].array?.first { $0["id"] == "shields.reloadNote" }
    #expect(note?["text"].string?.contains("haven’t sent") == true)
    #expect(h.rt.sitePolicy.rule(for: "example.com").lists == ["shields.cookies"])
    #expect(core.pill("https://example.com/")["icon"] == "sf:shield.slash")

    h.action("shields.panel", "dismiss")
    #expect(!core.panelOpen)
    #expect(h.rt.call("ui", "get")["overlays"].array?.contains("popover") == false)
  }

  @Test func offersToStepAsideForUBlockOriginLite() {
    let h = Harness()
    let core = start(h)
    core.extensionsChanged([["id": "ddkjiahejlhfcafbddmgiahcphecmpfh", "name": "uBlock Origin Lite", "enabled": true]])
    #expect(core.uboInstalled)
    #expect(h.storage("shields", "uboOffered") == true)
    // The toast's "Turn Off" button.
    h.action("shields.ubo", "toast")
    #expect(!core.on("blocker"))
    #expect(h.rt.call("settings", "get", ["id": "shields", "key": "blocker"]) == false)
    #expect(h.rt.sitePolicy.defaultRule.lists == ["shields.cookies"])
  }
}
