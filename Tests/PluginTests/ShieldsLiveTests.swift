import AppKit
import CordisValue
import Foundation
import Testing
import WebKit

@testable import DenHost
@testable import PluginCores

/// Shields against the real web: the shipped lists compiled into a throwaway store, real sites,
/// real WebKit. Opt-in (network, minutes): `DEN_LIVE=1 scripts/test.sh --filter ShieldsLiveTests`.
/// Prints `LIVE …` lines with what it saw; docs/guide/privacy-and-passwords.md quotes a run.
@MainActor
@Suite(.serialized, .watchdog, .enabled(if: ProcessInfo.processInfo.environment["DEN_LIVE"] != nil))
struct ShieldsLiveTests {
  static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  func until(_ seconds: Double, _ f: () async -> Bool) async throws -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
      if await f() { return true }
      try await Task.sleep(for: .milliseconds(100))
    }
    return false
  }

  /// A harness with the real shields plugin and its shipped lists, all compiled and ready.
  func shields() async throws -> (Harness, ShieldsCore) {
    let h = Harness()
    let res = h.root.appendingPathComponent("res")
    try FileManager.default.createDirectory(at: res, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: res.appendingPathComponent("shields"), withDestinationURL: Self.repo.appendingPathComponent("Plugins/shields/resources"))
    h.rt.sitePolicy.resourceRoots = [res]
    let t0 = Date()
    let core = ShieldsCore(env: h.env)
    h.rt.plugins.provide("shields") { m, a in core.handle(m, a) }
    core.start()
    let ok = try await until(240) { core.ready.count == 3 }
    #expect(ok, "lists not ready: \(core.ready)")
    let lists = h.rt.call("sitepolicy", "list").array ?? []
    print("LIVE lists ready in \(Int(Date().timeIntervalSince(t0) * 1000)) ms: \(lists.map { "\($0.str("name")) cached=\($0.flag("cached")) ms=\(Int($0.num("ms")))" })")
    return (h, core)
  }

  func view(_ h: Harness, _ id: String) -> WKWebView {
    if h.rt.webviews.record(id) == nil { h.rt.call("webviews", "create", ["id": .string(id)]) }
    let w = h.rt.webviews.materialize(id)!
    w.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
    if w.superview == nil { h.rt.window.window.contentView?.addSubview(w) }
    return w
  }

  /// Navigates like the address bar does and waits for the load to settle.
  func open(_ h: Harness, _ id: String, _ url: String, settle: Double = 2) async throws -> (WKWebView, Double) {
    let w = view(h, id)
    let t0 = Date()
    h.rt.call("webviews", "navigate", ["id": .string(id), "url": .string(url)])
    try await Task.sleep(for: .milliseconds(300))
    _ = try await until(45) { !w.isLoading }
    let ms = Date().timeIntervalSince(t0) * 1000
    try await Task.sleep(for: .seconds(settle))
    return (w, ms)
  }

  func js(_ w: WKWebView, _ s: String) async -> Any? { try? await w.callAsyncJavaScript(s, contentWorld: .defaultClient) }

  @Test(.timeLimit(.minutes(15))) func realPages() async throws {
    let (h, core) = try await shields()
    var rewritten: [Value] = []
    h.rt.host.on("sitepolicy.rewritten") { rewritten.append($0) }

    // 1. Tracking parameters, stripped on a typed navigation.
    let (w1, _) = try await open(h, "p", "https://example.com/?utm_source=den&fbclid=abc123&id=1")
    print("LIVE params: \(w1.url?.absoluteString ?? "nil") rewrites=\(rewritten.map { $0.str("from") + " -> " + $0.str("to") })")
    #expect(w1.url?.absoluteString == "https://example.com/?id=1")

    // 2. A bounce through Rakuten's click tracker, skipped before any request to it.
    rewritten = []
    let bounce = "https://click.linksynergy.com/deeplink?id=den&mid=1&murl=https%3A%2F%2Fexample.org%2F%3Futm_medium%3Daffiliate"
    let (w2, _) = try await open(h, "b", bounce)
    print("LIVE bounce: \(w2.url?.absoluteString ?? "nil") rewrites=\(rewritten.map { $0.str("kind") + ": " + $0.str("from") + " -> " + $0.str("to") })")
    #expect(w2.url?.absoluteString == "https://example.org/")
    #expect(rewritten.first?["kind"] == "bounce")

    // 3. A server redirect that adds tracking parameters: does WebKit ask the guard again?
    rewritten = []
    let (w3, _) = try await open(h, "r", "https://httpbin.org/redirect-to?url=https%3A%2F%2Fexample.net%2F%3Futm_campaign%3Dx")
    print("LIVE server redirect: \(w3.url?.absoluteString ?? "nil") rewrites=\(rewritten.count)")

    // 4. HTTPS-first: upgraded where HTTPS works, den's page where it doesn't.
    let (w4, _) = try await open(h, "h", "http://example.com/")
    let st4 = h.rt.call("sitepolicy", "get", ["id": "h"])
    print("LIVE https upgrade: \(w4.url?.absoluteString ?? "nil") upgraded=\(st4["upgraded"]) connection=\(st4["connection"])")
    #expect(w4.url?.scheme == "https")
    #expect(st4["upgraded"] == true)
    let (w5, _) = try await open(h, "n", "http://httpforever.com/", settle: 1)
    _ = try await until(30) { h.rt.call("sitepolicy", "get", ["id": "n"])["interstitial"] == true }
    let kind5 = await js(w5, "return document.body && document.body.dataset.denInterstitial") as? String
    print("LIVE https unavailable: url=\(w5.url?.absoluteString ?? "nil") interstitial=\(kind5 ?? "none")")
    #expect(kind5 == "https")
    var actions: [Value] = []
    h.rt.host.on("sitepolicy.interstitialAction") { actions.append($0) }
    _ = await js(w5, "document.querySelector('a[href=\"den-action:https.continue\"]').click(); return 1")
    _ = try await until(30) { !actions.isEmpty && !w5.isLoading && w5.url?.scheme == "http" && (w5.title ?? "").lowercased().contains("forever") }
    print("LIVE https continue: \(w5.url?.absoluteString ?? "nil") title=\(w5.title ?? "") allowed=\(core.httpAllowed)")
    // httpforever.com refuses the TLS handshake on purpose: an HTTP-only site.
    #expect(core.httpAllowed.contains("httpforever.com"))

    // 5. A lookalike domain ("аpple.com" with a Cyrillic а): stopped before any request.
    let (w6, _) = try await open(h, "l", "https://xn--pple-43d.com/", settle: 0.5)
    _ = try await until(10) { (await js(w6, "return document.body && document.body.dataset.denInterstitial") as? String) == "lookalike" }
    let title6 = await js(w6, "return document.querySelector('h1').textContent") as? String
    print("LIVE lookalike: url=\(w6.url?.absoluteString ?? "nil") heading=\(title6 ?? "none")")
    #expect(title6 == "Did you mean apple.com?")

    // 6. Autoplay with sound blocked by default; allowed per site.
    let autoplay = """
      const n=8000,b=new ArrayBuffer(44+n*2),v=new DataView(b);const s=(o,t)=>{for(let i=0;i<t.length;i++)v.setUint8(o+i,t.charCodeAt(i))};
      s(0,'RIFF');v.setUint32(4,36+n*2,true);s(8,'WAVEfmt ');v.setUint32(16,16,true);v.setUint16(20,1,true);v.setUint16(22,1,true);
      v.setUint32(24,8000,true);v.setUint32(28,16000,true);v.setUint16(32,2,true);v.setUint16(34,16,true);s(36,'data');v.setUint32(40,n*2,true);
      for(let i=0;i<n;i++)v.setInt16(44+i*2,Math.sin(i/4)*8000,true);
      const a=new Audio(URL.createObjectURL(new Blob([b],{type:'audio/wav'})));
      a.play().then(()=>window.result='played',e=>window.result=e.name);
      """
    // The page tries on its own: script the app evaluates counts as a user gesture in WebKit.
    let wa = view(h, "a")
    func pageResult(_ host: String, _ script: String) async throws -> String? {
      wa.loadHTMLString("<p>test</p><script>window.result=null;(async()=>{" + script + "})()</script>", baseURL: URL(string: "https://" + host + "/"))
      try await Task.sleep(for: .milliseconds(300))
      _ = try await until(10) { !wa.isLoading && wa.url?.host == host }
      var r: String?
      _ = try await until(10) {
        r = (try? await wa.callAsyncJavaScript("return window.result", contentWorld: .page)) as? String
        return r != nil
      }
      return r
    }
    let blocked = try await pageResult("autoplay.example", autoplay)
    h.rt.call("shields", "site", ["host": "autoplay.example", "autoplay": "allow"])
    let allowed = try await pageResult("autoplay.example", autoplay)
    print("LIVE autoplay: default=\(blocked ?? "nil") siteAllow=\(allowed ?? "nil")")
    #expect(blocked == "NotAllowedError")
    #expect(allowed == "played")

    // 7. Pop-ups without a click: blocked by default, allowed per site.
    var windows = 0
    h.rt.host.on("webviews.newWindow") { _ in windows += 1 }
    let popup = "setTimeout(()=>{window.open('https://example.com/');window.result='tried'},100);"
    _ = try await pageResult("popup.example", popup)
    try await Task.sleep(for: .seconds(1))
    let before = windows
    h.rt.call("shields", "site", ["host": "popup.example", "popups": "allow"])
    _ = try await pageResult("popup.example", popup)
    try await Task.sleep(for: .seconds(1))
    print("LIVE popups: default=\(before) siteAllow=\(windows - before)")
    #expect(before == 0)
    #expect(windows - before == 1)
  }

  /// What DuckDuckGo's autoconsent (MPL-2.0) would cost per page: its standalone bundle (script
  /// plus rules) evaluated in a real page. `DEN_AUTOCONSENT=<autoconsent.standalone.js>`.
  @Test(.timeLimit(.minutes(5)), .enabled(if: ProcessInfo.processInfo.environment["DEN_AUTOCONSENT"] != nil))
  func autoconsentCost() async throws {
    let path = ProcessInfo.processInfo.environment["DEN_AUTOCONSENT"]!
    let src = try String(contentsOfFile: path, encoding: .utf8)
    let h = Harness()
    for url in ["https://example.com/", "https://www.spiegel.de/", "https://www.lemonde.fr/"] {
      let (w, _) = try await open(h, "ac", url, settle: 2)
      var runs: [Int] = []
      for _ in 0..<3 {
        w.reload()
        try await Task.sleep(for: .milliseconds(300))
        _ = try await until(45) { !w.isLoading }
        let t0 = Date()
        _ = try? await w.callAsyncJavaScript(src + "\nreturn 1", contentWorld: .world(name: "ac"))
        runs.append(Int(Date().timeIntervalSince(t0) * 1000))
      }
      print("LIVE autoconsent \(URLs.host(url)): bytes=\(src.utf8.count) evalMs=\(runs)")
    }
  }

  /// Page-load cost with and without Shields: the same pages, alternating off/on, 3 rounds each.
  @Test(.timeLimit(.minutes(20))) func pageLoadCost() async throws {
    let (h, _) = try await shields()
    let sites = ["https://www.bbc.com/", "https://stackoverflow.com/questions", "https://www.theverge.com/"]
    func median(_ a: [Int]) -> Int { a.sorted()[a.count / 2] }
    for url in sites {
      let host = URLs.host(url)
      var ms: [Bool: [Int]] = [false: [], true: []], res: [Bool: [Int]] = [false: [], true: []], kb: [Bool: [Int]] = [false: [], true: []]
      for round in 0..<6 {
        let shieldsOn = round % 2 == 1
        h.rt.call("shields", "site", ["host": .string(host), "cookies": .bool(shieldsOn), "blocker": .bool(shieldsOn)])
        let (w, t) = try await open(h, "cost", url, settle: 3)
        ms[shieldsOn]!.append(Int(t))
        res[shieldsOn]!.append(await js(w, "return performance.getEntriesByType('resource').length") as? Int ?? -1)
        let bytes = await js(w, "return performance.getEntriesByType('resource').reduce((s,e)=>s+(e.transferSize||0),0)+(performance.getEntriesByType('navigation')[0]?.transferSize||0)") as? Int ?? 0
        kb[shieldsOn]!.append(bytes / 1024)
        h.rt.call("webviews", "close", ["id": "cost"])
      }
      print("LIVE cost \(host): loadMs off=\(ms[false]!) on=\(ms[true]!) median off=\(median(ms[false]!)) on=\(median(ms[true]!)) | resources off=\(median(res[false]!)) on=\(median(res[true]!)) | transferredKB off=\(median(kb[false]!)) on=\(median(kb[true]!))")
    }
  }

  static let bannerProbe = """
    const sel=['#onetrust-banner-sdk','#onetrust-consent-sdk','.fc-consent-root','#CybotCookiebotDialog','#didomi-host','#didomi-popup','.qc-cmp2-container',
    '[id^=sp_message_container]','#truste-consent-track','.osano-cm-window','#usercentrics-root','#cookie-law-info-bar','.cc-window','#cmpbox','#cmpwrapper',
    '.js-consent-banner','#gdpr-consent-tool-wrapper','[class*=cookie-banner]','[id*=cookie-banner]','[class*=CookieBanner]','[aria-label*=cookie i]','[aria-label*=consent i]',
    '#consent-banner','.consent-banner','#sn-b-custom','#bnp_container','#cookie-consent-banner'];
    const seen=[];for(const s of sel){for(const e of document.querySelectorAll(s)){const r=e.getBoundingClientRect(),cs=getComputedStyle(e);
    if(r.width>40&&r.height>20&&cs.display!=='none'&&cs.visibility!=='hidden'&&+cs.opacity>0.05)seen.push(s)}}
    return [...new Set(seen)].join(',');
    """

  /// Real sites with consent banners: which banners show with cookie-banner hiding off and on.
  @Test(.timeLimit(.minutes(20))) func cookieBannersAndTrackerBlocking() async throws {
    let (h, _) = try await shields()
    // Consent walls that lock the page ("accept or subscribe": spiegel.de, zeit.de, theguardian.com via
    // Sourcepoint) are left alone by the EasyList Cookie List on purpose (hiding one leaves a page that
    // can't scroll); a first run showed exactly that. These sites mostly have ordinary banners.
    let sites = ["https://stackoverflow.com/questions", "https://www.gov.uk/", "https://www.cookiebot.com/en/", "https://www.booking.com/",
                 "https://www.dell.com/en-us", "https://www.hp.com/us-en/home.html", "https://www.marca.com/", "https://www.spiegel.de/"]
    var hidden = 0
    for (i, url) in sites.enumerated() {
      let host = URLs.host(url)
      h.rt.call("shields", "site", ["host": .string(host), "cookies": false, "blocker": false])
      let (off, msOff) = try await open(h, "off\(i)", url, settle: 4)
      let offBanner = await js(off, Self.bannerProbe) as? String ?? "?"
      let offRes = await js(off, "return performance.getEntriesByType('resource').length") as? Int ?? -1
      h.rt.call("shields", "site", ["host": .string(host), "cookies": true, "blocker": true])
      let (on, msOn) = try await open(h, "on\(i)", url, settle: 4)
      let onBanner = await js(on, Self.bannerProbe) as? String ?? "?"
      let onRes = await js(on, "return performance.getEntriesByType('resource').length") as? Int ?? -1
      let st = h.rt.call("sitepolicy", "get", ["id": .string("on\(i)")])
      print("LIVE site \(host): off banner=[\(offBanner)] resources=\(offRes) loadMs=\(Int(msOff)) | on banner=[\(onBanner)] resources=\(onRes) loadMs=\(Int(msOn)) blocked=\(st["blocked"]) byList=\(st["blockedByList"])")
      if !offBanner.isEmpty && onBanner.isEmpty { hidden += 1 }
      h.rt.call("webviews", "close", ["id": .string("off\(i)")])
      h.rt.call("webviews", "close", ["id": .string("on\(i)")])
    }
    print("LIVE banners hidden on \(hidden) of \(sites.count) sites")
    #expect(hidden >= 2)
  }
}
