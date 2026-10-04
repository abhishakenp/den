import AppKit
import CordisValue
import Foundation
import Testing
import WebKit

@testable import DenHost

/// The `sitepolicy` host service on real WebKit pages: rule lists compiled into den's store and
/// attached per site (with WebKit's per-list blocked counts), the navigation guard, interstitials,
/// the unsaved-input check and site data removal. Offline: every page is loaded with
/// `loadHTMLString`, and blocked loads never reach the network.
@MainActor
@Suite(.serialized, .watchdog)
struct SitePolicyTests {
  static let blockJSON = #"[{"trigger":{"url-filter":"den-test-tracker"},"action":{"type":"block"}}]"#

  func events(_ rt: DenRuntime, _ name: String) -> () -> [Value] {
    var got: [Value] = []
    rt.host.on(name) { got.append($0) }
    return { got }
  }

  func until(_ seconds: Double = 20, _ f: () async -> Bool) async throws -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
      if await f() { return true }
      try await Task.sleep(for: .milliseconds(50))
    }
    return false
  }

  func page(_ rt: DenRuntime, _ id: String, _ html: String, _ base: String) async throws -> WKWebView {
    if rt.webviews.record(id) == nil { rt.call("webviews", "create", ["id": .string(id)]) }
    let w = rt.webviews.materialize(id)!
    w.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    if w.superview == nil { rt.window.window.contentView?.addSubview(w) }
    w.loadHTMLString(html, baseURL: URL(string: base))
    _ = try await until { !w.isLoading && w.url?.absoluteString == base }
    return w
  }

  static let trackerPage = "<img src='https://tracker.invalid/den-test-tracker.png'><script src='https://tracker.invalid/den-test-tracker.js'></script>"

  @Test func definedListBlocksAndCountsPerSite() async throws {
    let rt = ServiceTests.runtime()
    let loaded = events(rt, "sitepolicy.loaded")
    #expect(rt.call("sitepolicy", "define", ["name": "test.block", "json": .string(Self.blockJSON)])["pending"] == true)
    #expect(try await until { loaded().contains { $0.str("name") == "test.block" && $0.flag("ok") } })
    #expect(rt.call("sitepolicy", "rules", ["default": ["lists": ["test.block"]], "hosts": ["off.test": ["lists": []]]]).isError == false)

    _ = try await page(rt, "a", Self.trackerPage, "https://www.on.test/")
    #expect(try await until { rt.call("sitepolicy", "get", ["id": "a"])["blocked"].int ?? 0 >= 2 })
    let st = rt.call("sitepolicy", "get", ["id": "a"])
    #expect(st["host"] == "on.test")
    #expect(st["lists"] == ["test.block"])
    #expect(st["blockedByList"]["test.block"].int ?? 0 >= 2)

    // The same page on a site whose rule has no lists loads the "tracker" (it fails on the
    // network instead, which WebKit doesn't count as a block).
    _ = try await page(rt, "b", Self.trackerPage, "https://off.test/")
    try await Task.sleep(for: .milliseconds(500))
    let off = rt.call("sitepolicy", "get", ["id": "b"])
    #expect(off["blocked"] == .int(0))
    #expect(off["active"] == .array([]))

    // A second define of the same JSON is a no-op (same identifier), not a recompile.
    #expect(rt.call("sitepolicy", "define", ["name": "test.block", "json": .string(Self.blockJSON)])["ready"] == true)
  }

  /// Shields' default rule is `popups: block`. It must never refuse a window a click opens
  /// (sign-in pop-ups, links a script opens from a click handler); only pop-ups without a click
  /// stay blocked. It used to map to WebKit's Block policy, which refuses both.
  @Test func popupsBlockedByRuleStillOpenFromAClick() async throws {
    let rt = ServiceTests.runtime()
    _ = rt.call("sitepolicy", "rules", ["default": ["popups": "block"]])
    let opened = events(rt, "webviews.newWindow")
    let w = try await page(rt, "p", "<script>setTimeout(() => { window.auto = window.open('https://pop.test/auto') ? 'opened' : 'blocked' }, 10)</script>", "https://pop.test/")
    // A page's own timer (no click): blocked.
    #expect(try await until { (try? await w.evaluateJavaScript("window.auto || ''")) as? String == "blocked" })
    #expect(opened().isEmpty)
    // A click (`evaluateJavaScript` runs as a user gesture): it opens.
    _ = try? await w.evaluateJavaScript("window.open('https://pop.test/signin', 'signin', 'width=500,height=600'); 1")
    #expect(try await until { opened().contains { $0.str("url") == "https://pop.test/signin" } })
    #expect(opened().count == 1)
  }

  @Test func loadLooksUpBeforeCompiling() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("den-sp-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("rules.json.lzfse")
    try ((Data(Self.blockJSON.utf8) as NSData).compressed(using: .lzfse) as Data).write(to: file)
    let storage = dir.appendingPathComponent("storage")
    for round in 0..<2 {
      _ = NSApplication.shared
      let rt = DenRuntime(storageRoot: storage)
      let loaded = events(rt, "sitepolicy.loaded")
      rt.call("sitepolicy", "load", ["name": "t", "file": .string(file.path), "version": "7"])
      #expect(try await until { !loaded().isEmpty })
      #expect(loaded().first?.flag("ok") == true)
      // The first run compiles; the next finds the compiled list in the store.
      #expect(loaded().first?["cached"] == .bool(round == 1))
    }
    #expect(DenRuntime(storageRoot: storage).call("sitepolicy", "load", ["name": "t", "file": "missing.json", "plugin": "nobody"]).isError)
  }

  @Test func guardRewritesAndInterstitialActionsArriveOnlyFromTheirPage() async throws {
    let rt = ServiceTests.runtime()
    var asked: [Value] = []
    rt.plugins.provide("fakeguard") { _, a in
      asked.append(a)
      let u = a.str("url")
      if u.contains("utm_source") { return ["action": "rewrite", "url": .string(u.replacingOccurrences(of: "?utm_source=x", with: "")), "kind": "params"] }
      if u.contains("stop.test") {
        return ["action": "interstitial", "page": ["kind": "t", "title": "Stop", "message": "m", "buttons": [["id": "go", "title": "Go", "style": "primary", "key": "return"]]]]
      }
      return .null
    }
    let rewritten = events(rt, "sitepolicy.rewritten")
    let actions = events(rt, "sitepolicy.interstitialAction")
    rt.call("sitepolicy", "guard", ["service": "fakeguard", "method": "navigate"])
    let w = try await page(rt, "g", "<a id=l href='https://dest.test/?utm_source=x'>x</a>", "https://from.test/")
    _ = try await w.evaluateJavaScript("document.getElementById('l').click()")
    #expect(try await until { rewritten().count == 1 })
    #expect(rewritten().first?["to"] == "https://dest.test/")
    #expect(rewritten().first?["kind"] == "params")
    #expect(asked.contains { $0.flag("link") && $0.str("source") == "https://from.test/" })

    rt.call("webviews", "navigate", ["id": "g", "url": "https://stop.test/"])
    #expect(try await until { rt.call("sitepolicy", "get", ["id": "g"])["interstitial"] == true && !w.isLoading })
    #expect(try await until { (try? await w.evaluateJavaScript("document.body.dataset.denInterstitial")) as? String == "t" })
    #expect(w.url?.absoluteString == "https://stop.test/")
    // Return presses the button with key "return": a den-action: link the host turns into an event.
    _ = try await w.evaluateJavaScript("document.querySelector('.btn').click()")
    #expect(try await until { actions().count == 1 })
    #expect(actions().first?["action"] == "go")
    #expect(actions().first?["url"] == "https://stop.test/")

    // Any other page can't fake it.
    _ = try await page(rt, "g", "<a id=f href='den-action:go'>f</a>", "https://evil.test/")
    _ = try await w.evaluateJavaScript("document.getElementById('f').click()")
    try await Task.sleep(for: .milliseconds(400))
    #expect(actions().count == 1)
  }

  // MARK: Page scripts (Shields' scriptlets engine, the real file, on offline pages)

  static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  static let engine = repo.appendingPathComponent("Plugins/shields/resources/scriptlets.js")

  /// A data file like scriptlets.json, for the site `yt.test`.
  static func scriptletData(version: String = "1") throws -> URL {
    let rules: [[String]] = [
      ["set", "ytInitialPlayerResponse.adPlacements", "undefined"],
      ["set", "ytInitialPlayerResponse.playerAds", "undefined"],
      ["json-prune", "playerResponse.adPlacements adPlacements"],
      ["json-prune-fetch-response", "adPlacements playerResponse.adSlots", "data:application/json"],
      ["replace-xhr-response", "\"adSlots\"", "\"no_ads\"", "data:application/json"],
      ["hide", ".ad-slot"],
      ["hide", "this is :not a selector {"],
      ["not-a-scriptlet", "x"],
    ]
    let obj: [String: Any] = ["version": version, "sets": [["hosts": ["yt.test"], "rules": rules]]]
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("den-scr-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let u = dir.appendingPathComponent("data.json")
    try JSONSerialization.data(withJSONObject: obj).write(to: u)
    return u
  }

  static let adPage = """
    <div class=ad-slot id=slot>ad</div><div id=keep>keep</div>
    <script>
    var ytInitialPlayerResponse = {adPlacements: [1], playerAds: [2], videoDetails: {videoId: 'v'}};
    window.parsed = JSON.parse('{"playerResponse":{"adPlacements":[1],"streamingData":1},"adPlacements":[2],"other":3}');
    </script>
    """

  static let check = """
    const r = window.ytInitialPlayerResponse || {};
    const f = await fetch('data:application/json,{"adPlacements":[1],"playerResponse":{"adSlots":[1],"x":1},"ok":1}').then(r => r.json());
    const x = await new Promise(res => { const q = new XMLHttpRequest(); q.open('GET', 'data:application/json,{"adSlots":[1]}');
      q.onload = () => res(q.responseText); q.onerror = () => res('error'); q.send(); });
    return JSON.stringify({hooked: !!window.__denScriptlets, initAds: 'adPlacements' in r && r.adPlacements !== undefined,
      playerAds: r.playerAds !== undefined, video: !!(r.videoDetails && r.videoDetails.videoId),
      parsedAds: !!(window.parsed && (window.parsed.playerResponse.adPlacements || window.parsed.adPlacements)),
      parsedKept: !!(window.parsed && window.parsed.playerResponse.streamingData === 1 && window.parsed.other === 3),
      fetchAds: !!(f.adPlacements || f.playerResponse.adSlots), fetchKept: f.ok === 1 && f.playerResponse.x === 1, xhr: x,
      slotHidden: getComputedStyle(document.getElementById('slot')).display === 'none',
      keepShown: getComputedStyle(document.getElementById('keep')).display !== 'none'});
    """

  func pageState(_ w: WKWebView) async throws -> [String: Any] {
    let s = try await w.callAsyncJavaScript(Self.check, contentWorld: .page) as? String ?? "{}"
    return try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] ?? [:]
  }

  @Test func scriptletsRunOnlyWhereTheirDataAndRuleSay() async throws {
    let rt = ServiceTests.runtime()
    let loaded = events(rt, "sitepolicy.loaded")
    let data = try Self.scriptletData()
    #expect(rt.call("sitepolicy", "script", ["name": "test.scr", "file": .string(Self.engine.path), "data": .string(data.path)])["pending"] == true)
    #expect(try await until { loaded().contains { $0.str("name") == "test.scr" && $0.flag("ok") } })
    let info = (rt.call("sitepolicy", "list").array ?? []).first { $0.str("name") == "test.scr" }
    #expect(info?["kind"] == "script")
    #expect(info?["hosts"] == ["yt.test"])
    rt.call("sitepolicy", "rules", ["default": ["lists": [], "scripts": ["test.scr"]], "hosts": ["off.yt.test": ["lists": [], "scripts": []]]])

    // On the site: the player response is pruned at assignment, JSON.parse, fetch and XHR
    // bodies lose their ad fields and nothing else, ad slots are hidden. A bad rule is skipped.
    let w = try await page(rt, "y", Self.adPage, "https://www.yt.test/watch")
    let on = try await pageState(w)
    #expect(on["hooked"] as? Bool == true, "\(on)")
    #expect(on["initAds"] as? Bool == false, "\(on)")
    #expect(on["playerAds"] as? Bool == false, "\(on)")
    #expect(on["video"] as? Bool == true, "\(on)")
    #expect(on["parsedAds"] as? Bool == false, "\(on)")
    #expect(on["parsedKept"] as? Bool == true, "\(on)")
    #expect(on["fetchAds"] as? Bool == false, "\(on)")
    #expect(on["fetchKept"] as? Bool == true, "\(on)")
    #expect(on["xhr"] as? String == #"{"no_ads":[1]}"#, "\(on)")
    #expect(on["slotHidden"] as? Bool == true, "\(on)")
    #expect(on["keepShown"] as? Bool == true, "\(on)")
    #expect(rt.call("sitepolicy", "get", ["id": "y"])["scripts"] == ["test.scr"])

    // Another site: the rule names the script, but its data doesn't list the host.
    let o = try await page(rt, "o", Self.adPage, "https://other.test/")
    let off = try await pageState(o)
    #expect(off["hooked"] as? Bool == false, "\(off)")
    #expect(off["initAds"] as? Bool == true, "\(off)")
    #expect(off["parsedAds"] as? Bool == true, "\(off)")
    #expect(rt.call("sitepolicy", "get", ["id": "o"])["scripts"] == .array([]))

    // A site whose own rule turns scripts off (Shields off there), in the same web view.
    let w2 = try await page(rt, "y", Self.adPage, "https://off.yt.test/")
    let siteOff = try await pageState(w2)
    #expect(siteOff["hooked"] as? Bool == false, "\(siteOff)")
    #expect(siteOff["initAds"] as? Bool == true, "\(siteOff)")
    // And back on: the web view's other user scripts survived the removal (den's media script).
    let w3 = try await page(rt, "y", Self.adPage, "https://yt.test/again")
    #expect(try await pageState(w3)["hooked"] as? Bool == true)
    #expect(w3.configuration.userContentController.userScripts.contains { $0.source.contains("__denMedia") })
  }

  @Test func scriptDataPicksTheNewestCopy() throws {
    let old = try Self.scriptletData(version: "2026.01.01"), new = try Self.scriptletData(version: "2026.10.04")
    let a = try #require(SitePolicyService.buildScript(js: Self.engine, data: [old, new]))
    let b = try #require(SitePolicyService.buildScript(js: Self.engine, data: [new, old]))
    #expect(a.version == "2026.10.04" && b.version == "2026.10.04")
    #expect(a.hosts == ["yt.test"])
    #expect(a.source.hasPrefix("(function (denData) {\n"))
    #expect(SitePolicyService.matches("www.yt.test", ["yt.test"]) && SitePolicyService.matches("yt.test", ["yt.test"]))
    #expect(!SitePolicyService.matches("notyt.test", ["yt.test"]))
  }

  @Test func unsavedInputIsDetected() async throws {
    let rt = ServiceTests.runtime()
    let got = events(rt, "sitepolicy.unsaved")
    let w = try await page(rt, "u", "<input id=i value=start><textarea id=t></textarea>", "https://form.test/")
    let r1 = rt.call("sitepolicy", "unsaved", ["id": "u"])["request"]
    #expect(try await until { got().contains { $0["request"] == r1 } })
    #expect(got().last?["unsaved"] == false)
    _ = try await w.evaluateJavaScript("document.getElementById('t').value = 'half a comment'")
    let r2 = rt.call("sitepolicy", "unsaved", ["id": "u"])["request"]
    #expect(try await until { got().contains { $0["request"] == r2 } })
    #expect(got().last?["unsaved"] == true)
  }

  @Test func localHostsAreNeverUpgradedAndSiteMatching() {
    for h in ["localhost", "127.0.0.1", "192.168.1.4", "10.0.0.2", "printer", "nas.local", "app.test"] { #expect(SitePolicyService.isLocal(h), "\(h)") }
    for h in ["example.com", "8.8.8.8", "neverssl.com"] { #expect(!SitePolicyService.isLocal(h), "\(h)") }
    #expect(SitePolicyService.sameSite("mail.example.co.uk", "example.co.uk"))
    #expect(SitePolicyService.sameSite("example.com", "example.com"))
    #expect(!SitePolicyService.sameSite("notexample.com", "example.com"))
  }

  @Test func interstitialHTMLEscapesAndMarksKeys() {
    let html = WebErrorPage.interstitial(["kind": "x", "title": "<b>", "message": "a&b",
                                          "buttons": [["id": "ok\"><script>", "title": "OK", "style": "primary", "key": "return"]]])
    #expect(html.contains("&lt;b&gt;"))
    #expect(html.contains("a&amp;b"))
    #expect(html.contains("href=\"den-action:okscript\""))
    #expect(html.contains("<kbd>↩</kbd>"))
  }
}
