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

  /// The page menu's Copy Link (`webviews.cleanLink`, set by DenRuntime) goes through the real
  /// plugin's `clean`, so it follows Settings > Shields > Remove tracking parameters.
  @Test func copyLinkUsesShields() throws {
    let h = Harness()
    let clean = try #require(h.rt.webviews.cleanLink)
    let dirty = "https://example.com/a?id=1&utm_source=x&fbclid=y"
    #expect(clean(dirty) == dirty)  // no shields loaded: copied as it is
    _ = start(h)
    #expect(clean(dirty) == "https://example.com/a?id=1")
    #expect(clean("https://example.com/a?id=1") == "https://example.com/a?id=1")
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
    // Copy Link (the page menu): the same cleaning as a navigation, and a clean link unchanged.
    let c = h.rt.call("shields", "clean", ["url": "https://example.com/a?id=1&utm_source=x&fbclid=y#top"])
    #expect(c["url"] == "https://example.com/a?id=1#top")
    #expect(c["removed"] == ["utm_source", "fbclid"])
    #expect(h.rt.call("shields", "clean", ["url": "https://click.linksynergy.com/deeplink?murl=https%3A%2F%2Fshop.example%2F%3Fgclid%3D1"])["url"] == "https://shop.example/")
    #expect(h.rt.call("shields", "clean", ["url": "https://example.com/a?id=1"]) == ["url": "https://example.com/a?id=1", "removed": []])

    // Per site: blocker off drops the ad and tracker lists there and stops link cleaning.
    #expect(h.rt.call("shields", "site", ["host": "news.example", "blocker": false]).isError == false)
    #expect(h.rt.sitePolicy.rule(for: "www.news.example").lists == ["shields.cookies"])
    #expect(h.rt.sitePolicy.rule(for: "www.news.example").scripts.isEmpty)
    #expect(h.rt.call("shields", "navigate", ["url": "https://news.example/a?utm_campaign=x"]).isNull)
    #expect(h.rt.call("shields", "clean", ["url": "https://news.example/a?utm_campaign=x"])["url"] == "https://news.example/a?utm_campaign=x")
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

  /// Daily lists: a newer lists.json starts three checked downloads; when all three are in, the
  /// plugin loads them under the new version (a compile and swap in `sitepolicy`); a downloaded list
  /// that won't load sends it back to the bundled ones. An older or incomplete manifest does nothing.
  @Test func newerDailyListsAreDownloadedAndLoaded() async throws {
    let h = Harness()
    let core = start(h)
    core.listsBase = "https://127.0.0.1:9/"  // nothing listens: the real downloads fail, the test drives the results
    let sha = String(repeating: "a", count: 64)
    func manifest(_ v: String) -> Value {
      ["version": .string(v), "lists": ["ads": ["file": .string("ads-" + v + ".json.lzfse"), "sha256": .string(sha)],
                                        "trackers": ["file": .string("trackers-" + v + ".json.lzfse"), "sha256": .string(sha)],
                                        "cookies": ["file": .string("cookies-" + v + ".json.lzfse"), "sha256": .string(sha)]]]
    }
    core.listsManifest(manifest("2020.01.01-old"))
    #expect(core.pendingVersion.isEmpty)
    var incomplete = manifest("2099.01.01-x")
    incomplete.put("lists", ["ads": ["file": "ads-2099.01.01-x.json.lzfse", "sha256": .string(sha)]])
    core.listsManifest(incomplete)
    #expect(core.pendingVersion.isEmpty)

    let v = "2099.01.01-test"
    // What the three downloads would leave in the update root: small valid lists.
    let dir = try #require(h.rt.sitePolicy.resourceRoots.first).appendingPathComponent("shields")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for n in ["ads", "trackers", "cookies"] {
      let json = #"[{"trigger":{"url-filter":"den-daily-"# + n + #""},"action":{"type":"block"}}]"#
      try ((Data(json.utf8) as NSData).compressed(using: .lzfse) as Data).write(to: dir.appendingPathComponent(n + "-" + v + ".json.lzfse"))
    }
    core.listsManifest(manifest(v))
    #expect(core.pendingVersion == v && core.pendingFiles.count == 3)
    for n in ["ads", "trackers"] { core.listFileFetched(["plugin": "shields", "file": .string(n + "-" + v + ".json.lzfse"), "ok": true, "changed": true]) }
    #expect(core.listsVersion.isEmpty)
    core.listFileFetched(["plugin": "shields", "file": .string("cookies-" + v + ".json.lzfse"), "ok": true, "changed": true])
    #expect(core.listsVersion == v)
    #expect(h.storage("shields", "listsVersion") == .string(v))
    #expect(core.listFile(ShieldsLists.ads) == "ads-" + v + ".json.lzfse")
    // sitepolicy compiles them and swaps them in under the new version.
    #expect(try await until(150) {  // behind the bundled lists' compiles of earlier tests
      (h.rt.call("sitepolicy", "list").array ?? []).filter { $0.str("id").hasSuffix("@" + v) && $0.flag("ready") }.count == 3
    }, "\(h.rt.call("sitepolicy", "list")) roots=\(h.rt.sitePolicy.resourceRoots)")
    #expect(h.rt.sitePolicy.defaultRule.lists.contains("shields.ads"))
    // A downloaded list that won't load sends den back to the bundled lists.
    core.listLoaded(["name": "shields.ads", "ok": false, "error": "gone"])
    #expect(core.listsVersion.isEmpty)
    #expect(h.storage("shields", "listsVersion") == "")
    #expect(core.listFile(ShieldsLists.ads) == "ads.json.lzfse")
    // A failed download abandons that version.
    core.listsManifest(manifest(v))
    core.listFileFetched(["plugin": "shields", "file": .string("ads-" + v + ".json.lzfse"), "ok": false, "error": "sha256 mismatch"])
    #expect(core.pendingVersion.isEmpty && core.listsVersion.isEmpty)
    #expect(ShieldsCore.newer("2026.10.04-7f6dd3ec", "2026.09.27-989747b8") && !ShieldsCore.newer("2026.09.27-989747b8", "2026.10.04-7f6dd3ec"))
    core.stop()
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

  /// The panel's camera/microphone rows: one per remembered answer, each changed on its own
  /// (Allow / Block / Ask First, which forgets it, so the site asks again) through
  /// `sitepolicy.setPermission`; the summary row still resets them all.
  @Test func panelPermissionRowsChangeOneAnswerAtATime() async throws {
    let h = Harness()
    let tabs = h.startTabs()
    let core = start(h)
    let id = h.rt.call("tabs", "open", ["url": "https://example.com/"])["id"]
    h.rt.call("tabs", "select", ["id": id])
    let w = h.rt.webviews.materialize(id.string!)!
    w.loadHTMLString("<p>cam</p>", baseURL: URL(string: "https://example.com/"))
    #expect(try await until { !w.isLoading && w.url?.host == "example.com" })

    // The page answered Allow for the camera and Block for the microphone: both remembered.
    let p = try #require(h.rt.webviews.prompts)
    p.setMedia("https://example.com camera", true)
    p.setMedia("https://example.com microphone", false)

    h.action("shields.pill", "click", ["webview": id])
    #expect(core.panelOpen)
    func rows() -> [Value] {
      (core.panelTree()["children"].array ?? []).flatMap { $0["children"].array ?? [] }.filter { $0.str("id").hasPrefix("shields.permission.") }
    }
    func row(_ device: String) -> Value? { rows().first { $0["title"] == .string(device + " · https://example.com") } }
    #expect(rows().count == 2)
    #expect(row("Camera")?["selected"] == "allow")
    #expect(row("Microphone")?["selected"] == "block")
    #expect((row("Camera")?["options"].array ?? []).map { $0.str("id") } == ["allow", "block", "ask"])

    // Ask First forgets the camera's answer: its row goes, the microphone's stays.
    h.action("shields.permission.0", "select", ["option": "ask"])
    #expect(rows().count == 1 && rows().first?["title"] == .string("Microphone · https://example.com"))
    #expect(h.rt.call("sitepolicy", "permissions", ["host": "example.com"]).array?.map { $0.str("kind") } == ["microphone"])
    // Block the microphone, then Allow it: the remembered answer follows each choice.
    h.action("shields.permission.0", "select", ["option": "block"])
    #expect(h.rt.call("sitepolicy", "permissions", ["host": "example.com"]).array?.first?["allowed"] == false)
    h.action("shields.permission.0", "select", ["option": "allow"])
    #expect(h.rt.call("sitepolicy", "permissions", ["host": "example.com"]).array?.first?["allowed"] == true)
    let summary = (core.panelTree()["children"].array ?? []).flatMap { $0["children"].array ?? [] }.first { $0["id"] == "shields.permissions" }
    #expect(summary?["value"] == "Allowed")
    // The reset button still clears every answer.
    h.action("shields.permissions", "click")
    #expect(h.rt.call("sitepolicy", "permissions", ["host": "example.com"]).array?.isEmpty == true)
    #expect(rows().isEmpty)
    core.stop()
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
