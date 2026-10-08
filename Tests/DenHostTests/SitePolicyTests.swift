import AppKit
import CordisValue
import CryptoKit
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
    _ = try? await w.evaluateJavaScript("window.open('https://pop.test/signin', 'signin'); 1")
    #expect(try await until { opened().contains { $0.str("url") == "https://pop.test/signin" } })
    #expect(opened().count == 1)
  }

  /// A newer version of a list compiles while the old one keeps blocking, then every live page
  /// swaps to it: the next loads in a page that was never reloaded follow the new rules.
  @Test func newerListSwapsIntoLivePagesWithoutAReload() async throws {
    let rt = ServiceTests.runtime()
    let loaded = events(rt, "sitepolicy.loaded")
    let v1 = #"[{"trigger":{"url-filter":"den-old-tracker"},"action":{"type":"block"}}]"#
    let v2 = #"[{"trigger":{"url-filter":"den-new-tracker"},"action":{"type":"block"}}]"#
    rt.call("sitepolicy", "define", ["name": "test.swap", "json": .string(v1)])
    #expect(try await until { loaded().count == 1 })
    rt.call("sitepolicy", "rules", ["default": ["lists": ["test.swap"]], "hosts": [:]])
    let w = try await page(rt, "w", "<p>page</p>", "https://news.test/")
    let load = { (name: String) in
      _ = try? await w.callAsyncJavaScript("const i = new Image(); i.src = 'https://tracker.invalid/' + n + '.png?' + Math.random(); document.body.append(i)",
                                           arguments: ["n": name], contentWorld: .page)
    }
    await load("den-old-tracker")
    #expect(try await until { rt.call("sitepolicy", "get", ["id": "w"])["blocked"].int ?? 0 == 1 })

    rt.call("sitepolicy", "define", ["name": "test.swap", "json": .string(v2)])
    // Until the new list is ready the old one still blocks.
    #expect(rt.sitePolicy.lists["test.swap"] != nil)
    #expect(try await until { loaded().count == 2 })
    #expect(loaded().last?.str("replaced").hasPrefix("test.swap@") == true)
    await load("den-new-tracker")
    #expect(try await until { rt.call("sitepolicy", "get", ["id": "w"])["blocked"].int ?? 0 == 2 })
    await load("den-old-tracker")  // no longer blocked
    try await Task.sleep(for: .milliseconds(400))
    #expect(rt.call("sitepolicy", "get", ["id": "w"])["blocked"].int == 2)
    #expect(w.url?.absoluteString == "https://news.test/")
  }

  /// `fetch` of a list source: the SHA-256 must match and it must inflate to a JSON array; older
  /// versions are pruned after a good download.
  @Test func fetchesListSourcesCheckedAndPrunesOldOnes() async throws {
    let rt = ServiceTests.runtime()
    let got = events(rt, "sitepolicy.fetched")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("den-upd-\(UUID())")
    rt.sitePolicy.resourceRoots = [dir]
    let old = dir.appendingPathComponent("shields/ads-2026.01.01-aaaa.json.lzfse")
    try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("old".utf8).write(to: old)
    let packed = try (Data(Self.blockJSON.utf8) as NSData).compressed(using: .lzfse) as Data
    let sha = SHA256.hash(data: packed).map { String(format: "%02x", $0) }.joined()
    let src = dir.appendingPathComponent("src.lzfse")
    try packed.write(to: src)
    let file = "ads-2026.10.04-bbbb.json.lzfse"
    // A file: URL stands in for the download (the session reads it like any response); https is
    // required of real callers, so the test calls the storing step directly.
    let bad = SitePolicyService.storeList(packed, HTTPURLResponse(url: src, statusCode: 200, httpVersion: nil, headerFields: nil), nil,
                                          sha256: String(repeating: "0", count: 64), at: dir.appendingPathComponent("shields/" + file))
    #expect(bad.0 == false && bad.3 == "sha256 mismatch")
    let good = SitePolicyService.storeList(packed, HTTPURLResponse(url: src, statusCode: 200, httpVersion: nil, headerFields: nil), nil,
                                           sha256: sha, at: dir.appendingPathComponent("shields/" + file))
    #expect(good.0 && good.1)
    SitePolicyService.prune(prefix: "ads-", keeping: dir.appendingPathComponent("shields/" + file))
    #expect(!FileManager.default.fileExists(atPath: old.path))
    // And the stored file loads as a list.
    let loaded = events(rt, "sitepolicy.loaded")
    rt.call("sitepolicy", "load", ["name": "shields.ads", "plugin": "shields", "file": .string(file), "version": "2026.10.04-bbbb"])
    #expect(try await until { loaded().contains { $0.flag("ok") } })
    // Callers must name the hash, and use https.
    #expect(rt.call("sitepolicy", "fetch", ["plugin": "shields", "file": .string(file), "url": "https://example.invalid/x"]).isError)
    #expect(rt.call("sitepolicy", "fetch", ["plugin": "shields", "file": "lists.json", "url": "http://example.invalid/x"]).isError)
    _ = got
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
  static func scriptletData(version: String = "1", hostsOverride: [String] = ["yt.test"]) throws -> URL {
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
    let obj: [String: Any] = ["version": version, "sets": [["hosts": hostsOverride, "rules": rules]]]
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
    return JSON.stringify({hooked: typeof window[tok] === 'function', ownKeys: Object.keys(window).filter(k => /den/i.test(k)).length, initAds: 'adPlacements' in r && r.adPlacements !== undefined,
      playerAds: r.playerAds !== undefined, video: !!(r.videoDetails && r.videoDetails.videoId),
      parsedAds: !!(window.parsed && (window.parsed.playerResponse.adPlacements || window.parsed.adPlacements)),
      parsedKept: !!(window.parsed && window.parsed.playerResponse.streamingData === 1 && window.parsed.other === 3),
      fetchAds: !!(f.adPlacements || f.playerResponse.adSlots), fetchKept: f.ok === 1 && f.playerResponse.x === 1, xhr: x,
      slotHidden: getComputedStyle(document.getElementById('slot')).display === 'none',
      keepShown: getComputedStyle(document.getElementById('keep')).display !== 'none'});
    """

  func pageState(_ rt: DenRuntime, _ w: WKWebView, _ js: String = Self.check) async throws -> [String: Any] {
    let s = try await w.callAsyncJavaScript(js, arguments: ["tok": rt.sitePolicy.pageToken], contentWorld: .page) as? String ?? "{}"
    return try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] ?? [:]
  }

  /// The shipped scriptlets.json, with its YouTube set moved to `hosts` (test sites).
  static func shippedData(hosts: [String]) throws -> URL {
    let src = repo.appendingPathComponent("Plugins/shields/resources/scriptlets.json")
    var obj = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: src)) as? [String: Any])
    var sets = try #require(obj["sets"] as? [[String: Any]])
    sets[0]["hosts"] = hosts
    obj["sets"] = sets
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("den-scr-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let u = dir.appendingPathComponent("scriptlets.json")
    try JSONSerialization.data(withJSONObject: obj).write(to: u)
    return u
  }

  func loadScript(_ rt: DenRuntime, _ data: URL, name: String = "test.scr") async throws {
    let loaded = events(rt, "sitepolicy.loaded")
    #expect(rt.call("sitepolicy", "script", ["name": .string(name), "file": .string(Self.engine.path), "data": .string(data.path)])["pending"] == true)
    #expect(try await until { loaded().contains { $0.str("name") == name && $0.flag("ok") } })
  }

  @Test func scriptletsRunOnlyWhereTheirDataAndRuleSay() async throws {
    let rt = ServiceTests.runtime()
    try await loadScript(rt, try Self.scriptletData())
    let info = (rt.call("sitepolicy", "list").array ?? []).first { $0.str("name") == "test.scr" }
    #expect(info?["kind"] == "script")
    #expect(info?["hosts"] == ["yt.test"])
    // macOS 26's WebKit has the match-pattern SPI: WebKit picks the frames.
    #expect(info?["allFrames"] == true)
    rt.call("sitepolicy", "rules", ["default": ["lists": [], "scripts": ["test.scr"]], "hosts": ["off.yt.test": ["lists": [], "scripts": []]]])

    // On the site: the player response is pruned at assignment, JSON.parse, fetch and XHR
    // bodies lose their ad fields and nothing else, ad slots are hidden. A bad rule is skipped.
    // The script leaves nothing named on window but its random-named count function.
    let w = try await page(rt, "y", Self.adPage, "https://www.yt.test/watch")
    // Wait for scriptlet injection to settle on slower CI runners
    var ready = false
    let end = Date().addingTimeInterval(15)
    while Date() < end {
      do {
        let s = try await pageState(rt, w)
        if (s["hooked"] as? Bool == true) && ((s["ownKeys"] as? Int ?? -1) <= 1) {
          ready = true; break
        }
      } catch {}
      try await Task.sleep(for: .milliseconds(200))
    }
    #expect(ready, "Scriptlet didn't settle within 15s")
    let on = try await pageState(rt, w)
    #expect(on["hooked"] as? Bool == true, "\(on)")
    let keys = (on["ownKeys"] as? Int) ?? 0
    #expect(keys <= 1, "ownKeys=\(keys) \(on)")
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
    #expect(rt.call("sitepolicy", "get", ["id": "y"])["scripts"] == .array([.string("test.scr")]))
    // What it removed joins the page's blocked count: 2 at assignment, 2 in JSON.parse, 2 in
    // fetch, 1 XHR replacement, 1 hidden element.
    let changed = events(rt, "sitepolicy.changed")
    _ = rt.call("sitepolicy", "get", ["id": "y"])
    #expect(try await until(30) { rt.call("sitepolicy", "get", ["id": "y"])["scripted"].int ?? -1 == 8 })
    let st = rt.call("sitepolicy", "get", ["id": "y"])
    #expect(st["blocked"] == st["scripted"], "\(st)")
    #expect(st["blockedByList"]["scripts"] == st["scripted"])
    _ = changed

    // Another site: the rule names the script, but its data doesn't list the host.
    let o = try await page(rt, "o", Self.adPage, "https://other.test/")
    let off = try await pageState(rt, o)
    #expect(off["hooked"] as? Bool == false, "\(off)")
    #expect(off["initAds"] as? Bool == true, "\(off)")
    #expect(off["parsedAds"] as? Bool == true, "\(off)")

    // A site whose own rule turns scripts off (Shields off there), in the same web view.
    let w2 = try await page(rt, "y", Self.adPage, "https://off.yt.test/")
    let siteOff = try await pageState(rt, w2)
    #expect(siteOff["hooked"] as? Bool == false, "\(siteOff)")
    #expect(siteOff["initAds"] as? Bool == true, "\(siteOff)")
    #expect(rt.call("sitepolicy", "get", ["id": "y"])["scripts"] == .array([]))
    // And back on: the web view's other user scripts survived the removal (den's media script).
    let w3 = try await page(rt, "y", Self.adPage, "https://yt.test/again")
    #expect(try await pageState(rt, w3)["hooked"] as? Bool == true)
    #expect(w3.configuration.userContentController.userScripts.contains { $0.source.contains("__denMedia") })
  }

  /// A YouTube embed on another site: WebKit injects the script into the embed's frame (its host
  /// is in the data), not into the page around it. The embed is served from 127.0.0.1.
  @Test func scriptletsRunInEmbedsOnAnySite() async throws {
    let rt = ServiceTests.runtime()
    let mock = MockServices()
    try mock.start()
    defer { mock.stop() }
    mock.page("/embed", Self.adPage + """
      <script>
      const tok = new URLSearchParams(location.search).get('t');
      addEventListener('load', () => parent.postMessage(JSON.stringify({hooked: typeof window[tok] === 'function',
        initAds: window.ytInitialPlayerResponse.adPlacements !== undefined,
        slotHidden: getComputedStyle(document.getElementById('slot')).display === 'none'}), '*'));
      </script>
      """)
    try await loadScript(rt, try Self.scriptletData(hostsOverride: ["127.0.0.1"]))
    rt.call("sitepolicy", "rules", ["default": ["lists": [], "scripts": ["test.scr"]], "hosts": [:]])
    let html = Self.adPage + """
      <script>addEventListener('message', e => { window.embed = e.data; });</script>
      <iframe src="\(mock.base)/embed?t=\(rt.sitePolicy.pageToken)"></iframe>
      """
    let w = try await page(rt, "e", html, "http://news.test/article")
    #expect(try await until { (try? await w.callAsyncJavaScript("return window.embed || ''", contentWorld: .page)) as? String ?? "" != "" })
    let embed = try JSONSerialization.jsonObject(with: Data(((try await w.callAsyncJavaScript("return window.embed", contentWorld: .page)) as? String ?? "{}").utf8)) as? [String: Any] ?? [:]
    #expect(embed["hooked"] as? Bool == true, "\(embed)")
    #expect(embed["initAds"] as? Bool == false, "\(embed)")
    #expect(embed["slotHidden"] as? Bool == true, "\(embed)")
    // The news page itself is untouched.
    let top = try await pageState(rt, w)
    #expect(top["hooked"] as? Bool == false, "\(top)")
    #expect(top["initAds"] as? Bool == true, "\(top)")
    #expect(top["slotHidden"] as? Bool == false, "\(top)")
  }

  /// YouTube's anti-adblock dialog, from its real markup (Tests/Fixtures), under the shipped rules:
  /// dialog, its view model and the dimming backdrop are hidden, and the page's count includes them.
  @Test func antiAdblockDialogIsHidden() async throws {
    let rt = ServiceTests.runtime()
    try await loadScript(rt, try Self.shippedData(hosts: ["yt.test"]))
    rt.call("sitepolicy", "rules", ["default": ["lists": [], "scripts": ["test.scr"]], "hosts": [:]])
    let markup = try String(contentsOf: Self.repo.appendingPathComponent("Tests/Fixtures/youtube-enforcement-dialog.html"), encoding: .utf8)
    // Shown without den: the fixture really draws a dialog.
    let plain = try await page(rt, "n", markup, "https://plain.test/")
    let visible = try await plain.callAsyncJavaScript("return getComputedStyle(document.querySelector('tp-yt-paper-dialog')).display", contentWorld: .page) as? String
    #expect(visible != "none")
    let w = try await page(rt, "d", markup, "https://www.yt.test/watch?v=x")
    let js = """
      const d = s => getComputedStyle(document.querySelector(s)).display;
      return JSON.stringify({dialog: d('tp-yt-paper-dialog'), model: d('ytd-enforcement-message-view-model'), backdrop: d('tp-yt-iron-overlay-backdrop'),
        count: window[tok]()});
      """
    let st = try await pageState(rt, w, js)
    #expect(st["dialog"] as? String == "none", "\(st)")
    #expect(st["model"] as? String == "none", "\(st)")
    #expect(st["backdrop"] as? String == "none", "\(st)")
    #expect(st["count"] as? Int ?? 0 >= 3, "\(st)")
  }

  /// The logged-in recovery (youtube-recover + edit-outbound-json + neutralize-callback, shipped
  /// rules) against a stand-in player. The response shapes are the ones uBlock Origin's quick fix
  /// reads (quick-fixes.txt); no recorded logged-in response was available.
  @Test func loggedInRecoveryRetriesAndSkipsStitchedAds() async throws {
    let rt = ServiceTests.runtime()
    try await loadScript(rt, try Self.shippedData(hosts: ["yt.test"]))
    rt.call("sitepolicy", "rules", ["default": ["lists": [], "scripts": ["test.scr"]], "hosts": [:]])
    let fake = """
      <div id=movie_player></div><div id=poke></div>
      <script>
      window.ytcfg = {data_: {INNERTUBE_CONTEXT: {client: {clientName: 'WEB', userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)'}}}};
      const S = window.S = {debug: 'USDAI, SABR, s:8', progress: {duration: 100, loaded: 50, current: 10}, buffering: false, seeks: [], loads: [], requests: [], abnormal: 0,
        response: {videoDetails: {videoId: 'abc'}, playabilityStatus: {status: 'OK'}}};
      const p = document.getElementById('movie_player');
      Object.assign(p, {
        getPlayerResponse: () => S.response, getStatsForNerds: () => ({debug_info: S.debug}), getProgressState: () => S.progress,
        getPlayerStateObject: () => ({isBuffering: S.buffering}), seekTo: t => S.seeks.push(t),
        loadVideoById: (id, start) => { S.loads.push(id + '@' + start);
          // The player's next request, as YouTube's client serializes it.
          S.requests.push(JSON.parse(JSON.stringify({context: ytcfg.data_.INNERTUBE_CONTEXT, attestationRequest: {omitBotguardData: true}, videoId: id,
            playbackContext: {contentPlaybackContext: {referer: 'https://www.youtube.com/watch?v=abc', lactMilliseconds: '-1'}}}))); },
      });
      window.poke = () => document.getElementById('poke').appendChild(document.createElement('i'));
      Promise.resolve().then(function onAbnormalityDetected() { S.abnormal++; });
      </script>
      """
    let w = try await page(rt, "r", fake, "https://www.yt.test/watch?v=abc")
    func state() async throws -> [String: Any] {
      let s = try await w.callAsyncJavaScript("return JSON.stringify(window.S)", contentWorld: .page) as? String ?? "{}"
      return try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] ?? [:]
    }
    func poke() async throws { _ = try await w.callAsyncJavaScript("poke()", contentWorld: .page) }

    // The page's abnormality callback never ran.
    #expect(try await state()["abnormal"] as? Int == 0)
    // A normal video: nothing happens.
    try await poke()
    try await Task.sleep(for: .milliseconds(300))
    #expect((try await state()["loads"] as? [Any])?.isEmpty == true)

    // A stitched ad (the player's stats say so): skipped to its end.
    _ = try await w.callAsyncJavaScript("S.debug = 'SSAP, AD 1/1'; S.progress = {duration: 15, loaded: 3, current: 2}; poke()", contentWorld: .page)
    #expect(try await until { (try? await state())?["seeks"] as? [Int] == [15] })

    // "This content isn't available" (YouTube's anti-adblock answer to a logged-in player request):
    // the client is tagged with the next marker and the video reloads where it was; the reload's
    // player request carries the edits that ask for a response without stitched ads.
    _ = try await w.callAsyncJavaScript("""
      S.debug = 'USDAI, SABR'; S.progress = {duration: 100, loaded: 0, current: 0};
      S.response = {videoDetails: {videoId: 'abc'}, playerConfig: {playbackStartConfig: {startSeconds: 42}}, playabilityStatus: {status: 'UNPLAYABLE',
        errorScreen: {playerErrorMessageRenderer: {subreason: {runs: [{text: 'Learn more', navigationEndpoint: {commandMetadata: {webCommandMetadata:
          {url: 'https://support.google.com/youtube/answer/3037019', webPageType: 'WEB_PAGE_TYPE_UNKNOWN'}}}}]}}}}};
      poke();
      """, contentWorld: .page)
    #expect(try await until { ((try? await state())?["loads"] as? [String])?.isEmpty == false })
    let s = try await state()
    #expect(s["loads"] as? [String] == ["abc@42"])
    let ua = try await w.callAsyncJavaScript("return ytcfg.data_.INNERTUBE_CONTEXT.client.userAgent", contentWorld: .page) as? String ?? ""
    #expect(ua.contains("(Macintosh; Intel Mac OS X 10_15_7; lactmilli)"), "\(ua)")
    let req = (s["requests"] as? [[String: Any]])?.first ?? [:]
    #expect(req["params"] as? String == "8AUB", "\(req)")
    let cpc = (req["playbackContext"] as? [String: Any])?["contentPlaybackContext"] as? [String: Any] ?? [:]
    #expect((cpc["referer"] as? String)?.hasSuffix("#reloadxhr") == true, "\(cpc)")
    #expect(cpc["lactMilliseconds"] as? String != "-1", "\(cpc)")
  }

  /// Site scriptlets split per site: a page gets only its site's sets (parent domains included).
  @Test func perSiteScriptsCarryOnlyTheirSitesRules() async throws {
    let rt = ServiceTests.runtime()
    // The layout scripts/shields/build-scriptlets.swift writes (hosts in byte order, one per line).
    let text = """
      {"version":"1","source":"test","hosts":{
      "a.test":[0],
      "b.test":[1],
      "c.test":[1]
      },"sets":[
      [["set","canRunAds","true"]],
      [["set","isAdBlockActive","false"]]
      ]}

      """
    #expect((try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("den-scr-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let data = dir.appendingPathComponent("sites.json")
    try Data(text.utf8).write(to: data)
    let loaded = events(rt, "sitepolicy.loaded")
    rt.call("sitepolicy", "script", ["name": "test.sites", "file": .string(Self.engine.path), "data": .string(data.path), "perSite": true])
    #expect(try await until { loaded().contains { $0.str("name") == "test.sites" && $0.flag("ok") } })
    let info = (rt.call("sitepolicy", "list").array ?? []).first { $0.str("name") == "test.sites" }
    #expect(info?["perSite"] == true && info?["siteHosts"] == .int(3) && info?["sets"] == .int(2))
    // The shipped file indexes too (every host line and set line found, lookups by binary search).
    let shipped = try #require(SitePolicyService.buildScript(js: Self.engine, data: [Self.repo.appendingPathComponent("Plugins/shields/resources/sites.json")], perSite: true)?.site)
    #expect(shipped.hostLines.count > 10_000 && shipped.setLines.count > 1_000)
    #expect(!shipped.sets(of: "theverge.com").isEmpty && shipped.sets(of: "example.com").isEmpty)
    #expect((try? JSONSerialization.jsonObject(with: Data(shipped.rules(shipped.sets(of: "theverge.com")[0]).utf8))) is [Any])
    rt.call("sitepolicy", "rules", ["default": ["lists": [], "scripts": ["test.sites"]], "hosts": [:]])
    let js = "return JSON.stringify({canRunAds: String(window.canRunAds), active: String(window.isAdBlockActive), hooked: typeof window[tok] === 'function'})"
    let a = try await pageState(rt, try await page(rt, "s", "<p>a</p>", "https://www.sub.a.test/"), js)
    #expect(a["canRunAds"] as? String == "true" && a["active"] as? String == "undefined", "\(a)")
    let w = try await page(rt, "s", "<p>c</p>", "https://c.test/")
    let c = try await pageState(rt, w, js)
    #expect(c["canRunAds"] as? String == "undefined" && c["active"] as? String == "false", "\(c)")
    // The page's script carries c.test's set only.
    let src = w.configuration.userContentController.userScripts.first { $0.source.contains("isAdBlockActive") }?.source ?? ""
    #expect(!src.contains("canRunAds"))
    let d = try await pageState(rt, try await page(rt, "s", "<p>d</p>", "https://d.test/"), js)
    #expect(d["hooked"] as? Bool == false, "\(d)")
  }

  /// uBO's common site scriptlets, each on its own trap, all on one page.
  @Test func siteScriptletsDefuseAdblockWalls() async throws {
    let rt = ServiceTests.runtime()
    let rules: [[String]] = [
      ["aopr", "adblockDetector"],
      ["acs", "document.createElement", "blockadblock"],
      ["nostif", "showWall", "1000"],
      ["aeld", "load", "detectAdblock"],
      ["nowoif", "popunder"],
      ["no-fetch-if", "pagead2"],
      ["ra", "data-wall", "#wall"],
      ["rc", "blurred", "body"],
      ["nofab"],
      ["set", "ads.ok", "trueFunc"],
    ]
    let obj: [String: Any] = ["version": "1", "sets": [["hosts": ["wall.test"], "rules": rules]]]
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("den-scr-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let data = dir.appendingPathComponent("d.json")
    try JSONSerialization.data(withJSONObject: obj).write(to: data)
    try await loadScript(rt, data)
    rt.call("sitepolicy", "rules", ["default": ["lists": [], "scripts": ["test.scr"]], "hosts": [:]])
    let html = """
      <body class="blurred keep"><div id=wall data-wall=1>wall</div>
      <script>
      const R = window.R = {};
      try { window.adblockDetector.run(); R.aopr = 'ran'; } catch (e) { R.aopr = 'aborted'; }
      R.acs = 'ran'; try { (function blockadblock() { eval('document.createElement("div"); R.acsInner = "ran"'); })(); } catch (e) { R.acs = 'aborted'; }
      R.timer = 'none'; setTimeout(function showWall() { R.timer = 'wall'; }, 1000); setTimeout(function fine() { R.fine = 'ran'; }, 10);
      window.addEventListener('load', function detectAdblock() { R.listener = 'ran'; });
      window.addEventListener('load', function other() { R.other = 'ran'; });
      R.open = String(window.open('https://popunder.test/x'));
      fetch('https://pagead2.googlesyndication.com/x.js').then(r => r.text()).then(t => { R.fetch = 'resolved:' + t.length; }, () => { R.fetch = 'failed'; });
      R.fab = typeof fuckAdBlock;
      window.ads = {}; R.set = typeof window.ads.ok === 'function' && window.ads.ok() === true;
      </script>
      """
    let w = try await page(rt, "f", html, "https://wall.test/")
    try await Task.sleep(for: .milliseconds(1500))
    let js = """
      return JSON.stringify(Object.assign({}, window.R, {attr: document.getElementById('wall').hasAttribute('data-wall'),
        blurred: document.body.classList.contains('blurred'), keep: document.body.classList.contains('keep'), count: window[tok]()}));
      """
    let r = try await pageState(rt, w, js)
    #expect(r["aopr"] as? String == "aborted", "\(r)")
    #expect(r["acs"] as? String == "aborted", "\(r)")
    #expect(r["timer"] as? String == "none" && r["fine"] as? String == "ran", "\(r)")
    #expect(r["listener"] == nil && r["other"] as? String == "ran", "\(r)")
    #expect(r["open"] as? String == "null", "\(r)")
    #expect(r["fetch"] as? String == "resolved:0", "\(r)")
    #expect(r["fab"] as? String == "object", "\(r)")
    #expect(r["set"] as? Bool == true, "\(r)")
    #expect(r["attr"] as? Bool == false && r["blurred"] as? Bool == false && r["keep"] as? Bool == true, "\(r)")
    #expect(r["count"] as? Int ?? 0 >= 8, "\(r)")
  }

  @Test func scriptDataPicksTheNewestCopy() throws {
    let old = try Self.scriptletData(version: "2026.01.01"), new = try Self.scriptletData(version: "2026.10.04")
    let a = try #require(SitePolicyService.buildScript(js: Self.engine, data: [old, new]))
    let b = try #require(SitePolicyService.buildScript(js: Self.engine, data: [new, old]))
    #expect(a.version == "2026.10.04" && b.version == "2026.10.04")
    #expect(a.hosts == ["yt.test"])
    #expect(a.source.hasPrefix("(function (denData, denToken) {\n"))
    #expect(SitePolicyService.matchPatterns(["youtube.com", "127.0.0.1"]) == ["*://*.youtube.com/*", "*://127.0.0.1/*"])
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
