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
