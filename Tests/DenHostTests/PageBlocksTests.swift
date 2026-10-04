import AppKit
import CordisValue
import Foundation
import DenTestSupport
import Testing
import WebKit

@testable import DenHost

/// The generic blocks behind the page tools: `webviews.inject` / `message` / `setMenu` /
/// `setContentRules` / `snapshot` with a rect, and the `speech`, `translate` and
/// `ui.tokens` services. Real WebKit pages (loadHTMLString with a fake origin), real speech and
/// real on-device translation.
@MainActor
@Suite(.serialized, .watchdog)
struct PageBlocksTests {
  static func runtime() -> DenRuntime { ServiceTests.runtime() }

  /// A shown web view with `html` loaded as `origin`.
  static func page(_ rt: DenRuntime, _ id: String, _ html: String, origin: String = "https://news.test/a") async throws -> WKWebView {
    _ = rt.call("webviews", "create", ["id": .string(id)])
    _ = rt.call("content", "show", ["panes": [.string(id)]])
    let w = try #require(rt.webviews.record(id)?.webView)
    w.loadHTMLString(html, baseURL: URL(string: origin))
    _ = await Wait.until("w.isLoading || w.url?.host == nil") { !(w.isLoading || w.url?.host == nil) }
    try await Task.sleep(for: .milliseconds(100))
    return w
  }

  static func wait(_ rt: DenRuntime, _ event: String, timeout: Int = 400, where match: @escaping (Value) -> Bool = { _ in true }) async -> Value? {
    var got: Value?
    let token = rt.plugins.on(event) { v in if got == nil, match(v) { got = v } }
    _ = token
    _ = await Wait.until("event \(event)", seconds: Double(timeout) / 20) { got != nil }
    return got
  }

  /// Page JS with a timeout: a hung web content process fails the check instead of hanging.
  static func eval(_ w: WKWebView, _ js: String) async -> Any? {
    await awaitCallback(10, UncheckedBox<Any?>(nil)) { done in w.evaluateJavaScript(js) { r, _ in done(UncheckedBox(r)) } }.value
  }

  @Test func injectNeedsPagesPermissionAndReadsOnlyItsOwnFiles() async throws {
    let rt = Self.runtime()
    let w = try await Self.page(rt, "p", "<p id=x>hello</p>")
    _ = w
    #expect(rt.call("webviews", "inject", ["id": "p", "plugin": "pagetools", "script": "return 1"]).isError)  // no permission
    rt.permissions.grant("pagetools", ["pages:*"])
    #expect(rt.call("webviews", "inject", ["id": "p", "plugin": "pagetools", "files": ["../tabs/TabsCore.swift"]]).isError)
    #expect(rt.call("webviews", "inject", ["id": "p", "plugin": "pagetools", "files": ["nope.js"]]).isError)
    #expect(rt.webviews.scripting.loadedFiles.isEmpty)
    // pages:<domain> is scoped.
    rt.permissions.grant("other", ["pages:elsewhere.test"])
    #expect(rt.call("webviews", "inject", ["id": "p", "plugin": "other", "script": "return 1"]).isError)
    #expect(!rt.permissions.allowsNet("pagetools", host: "news.test"))
  }

  @Test func injectRunsFilesOnceInAnIsolatedWorldAndMessagesComeBack() async throws {
    let rt = Self.runtime()
    rt.permissions.grant("demo", ["pages:news.test"])
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("den-res-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try "window.__demo = {n: (window.__demo ? window.__demo.n : 0) + 1, hi: function (x) { webkit.messageHandlers.den.postMessage({said: x}); return 'sent'; }};"
      .write(to: dir.appendingPathComponent("demo.js"), atomically: true, encoding: .utf8)
    rt.permissions.setResources("demo", dir)
    let w = try await Self.page(rt, "p", "<script>window.pageSecret = 42</script><p>hi</p>")
    let first = rt.call("webviews", "inject", ["id": "p", "plugin": "demo", "files": ["demo.js"], "global": "__demo",
                                              "script": "return {n: window.__demo.n, secret: typeof window.pageSecret, x: a}", "args": ["a": [1, "two"]]])
    let r1 = await Self.wait(rt, "webviews.injectResult") { $0["request"] == first["request"] }
    #expect(r1?["ok"] == true)
    #expect(r1?["value"]["n"] == 1)
    #expect(r1?["value"]["secret"] == "undefined")  // the page's globals aren't visible
    #expect(r1?["value"]["x"] == [1, "two"])
    // The global exists now: the file isn't evaluated again.
    let second = rt.call("webviews", "inject", ["id": "p", "plugin": "demo", "files": ["demo.js"], "global": "__demo", "script": "return window.__demo.hi('yo')"])
    var m: Value?
    rt.plugins.on("webviews.message") { m = $0 }
    let r2 = await Self.wait(rt, "webviews.injectResult") { $0["request"] == second["request"] }
    #expect(r2?["value"] == "sent")
    _ = await Wait.until("m == nil") { !(m == nil) }
    #expect(m?["plugin"] == "demo" && m?["webview"] == "p" && m?["value"]["said"] == "yo")
    let again = rt.call("webviews", "inject", ["id": "p", "plugin": "demo", "script": "return window.__demo.n"])
    #expect(await Self.wait(rt, "webviews.injectResult") { $0["request"] == again["request"] }?["value"] == 1)
    // The page itself can't reach the plugin's world.
    #expect(await Self.eval(w, "typeof window.__demo") as? String == "undefined")
    // A throwing script comes back as an error.
    let bad = rt.call("webviews", "inject", ["id": "p", "plugin": "demo", "script": "throw new Error('boom')"])
    let r3 = await Self.wait(rt, "webviews.injectResult") { $0["request"] == bad["request"] }
    #expect(r3?["ok"] == false && r3?.str("error").contains("boom") == true)
  }

  @Test func contentRulesHideElementsPerSite() async throws {
    let rt = Self.runtime()
    let html = "<div id=banner>Subscribe!</div><p id=keep>text</p>"
    _ = rt.call("webviews", "setContentRules", ["plugin": "demo", "rules": [
      ["trigger": ["url-filter": ".*", "if-domain": ["*news.test"]], "action": ["type": "css-display-none", "selector": "#banner"]],
    ]])
    let compiled = await Self.wait(rt, "webviews.contentRules")
    #expect(compiled?["ok"] == true && compiled?["count"] == 1)
    let w = try await Self.page(rt, "p", html)
    try await Task.sleep(for: .milliseconds(200))
    #expect(await Self.eval(w, "getComputedStyle(document.getElementById('banner')).display") as? String == "none")
    #expect(await Self.eval(w, "getComputedStyle(document.getElementById('keep')).display") as? String == "block")
    // Other sites are untouched.
    let o = try await Self.page(rt, "o", html, origin: "https://other.test/")
    #expect(await Self.eval(o, "getComputedStyle(document.getElementById('banner')).display") as? String == "block")
    // Removing the rules.
    _ = rt.call("webviews", "setContentRules", ["plugin": "demo", "rules": []])
    #expect(await Self.wait(rt, "webviews.contentRules")?["count"] == 0)
    #expect(rt.webviews.ruleLists.isEmpty)
  }

  @Test func contextMenuItemsOnlyForSelections() throws {
    let rt = Self.runtime()
    _ = rt.call("webviews", "create", ["id": "p"])
    _ = rt.call("content", "show", ["panes": ["p"]])
    let w = try #require(rt.webviews.record("p")?.webView)
    _ = rt.call("webviews", "setMenu", ["plugin": "demo", "items": [["id": "demo.quote", "title": "Quote", "when": "selection"]]])
    let linkMenu = NSMenu()
    linkMenu.addItem(withTitle: "Open Link", action: nil, keyEquivalent: "")
    rt.webviews.scripting.extend(linkMenu, for: w)
    #expect(linkMenu.items.map(\.title) == ["Open Link"])
    let textMenu = NSMenu()
    let copy = NSMenuItem(title: "Copy", action: nil, keyEquivalent: "")
    copy.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierCopy")
    textMenu.addItem(withTitle: "Look Up", action: nil, keyEquivalent: "")
    textMenu.addItem(copy)
    textMenu.addItem(withTitle: "Share", action: nil, keyEquivalent: "")
    rt.webviews.scripting.extend(textMenu, for: w)
    #expect(textMenu.items.map(\.title) == ["Look Up", "Copy", "Quote", "Share"])
    var picked: Value?
    rt.plugins.on("webviews.menu") { picked = $0 }
    let item = textMenu.items[2]
    _ = (item.target as? NSObject)?.perform(item.action, with: item)
    #expect(picked == ["id": "demo.quote", "webview": "p", "plugin": "demo"])
  }

  @Test func snapshotOfARectTheFullPageAndAFolder() async throws {
    let rt = Self.runtime()
    rt.window.window.orderFront(nil)
    let html = "<body style='margin:0'><div id=box style='margin:40px;width:200px;height:100px;background:rgb(255,0,0)'></div><div style='height:3000px;background:linear-gradient(blue,green)'></div></body>"
    _ = try await Self.page(rt, "p", html)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("den-cap-\(UUID())")
    _ = rt.call("webviews", "snapshot", ["id": "p", "rect": ["x": 40, "y": 40, "width": 200, "height": 100], "folder": .string(dir.path), "name": "box.png"])
    let a = await Self.wait(rt, "webviews.snapshot")
    if a?["ok"] != true { print("snapshot.rect:", a ?? .null) }
    #expect(a?["ok"] == true)
    let scale = Int64(rt.window.window.backingScaleFactor)
    #expect(a?["width"] == .int(200 * scale) && a?["height"] == .int(100 * scale))
    let png = try #require(NSImage(contentsOfFile: a?.str("path") ?? ""))
    let rep = try #require(png.representations.first as? NSBitmapImageRep)
    let c = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
    #expect(c.redComponent > 0.9 && c.greenComponent < 0.15 && c.blueComponent < 0.15)
    // Same name again: a unique " 2" suffix.
    _ = rt.call("webviews", "snapshot", ["id": "p", "rect": ["x": 40, "y": 40, "width": 200, "height": 100], "folder": .string(dir.path), "name": "box.png"])
    #expect(await Self.wait(rt, "webviews.snapshot")?.str("path").hasSuffix("box 2.png") == true)
    // The full page is taller than the view.
    _ = rt.call("webviews", "snapshot", ["id": "p", "full": true, "folder": .string(dir.path), "name": "full.png"])
    let f = await Self.wait(rt, "webviews.snapshot")
    #expect(f?["ok"] == true)
    #expect((f?["height"].int ?? 0) >= 3100 * scale)
    // Rendered all the way down, not only the visible part: the gradient ends green.
    let full = try #require(NSImage(contentsOfFile: f?.str("path") ?? "")?.representations.first as? NSBitmapImageRep)
    let bottom = try #require(full.colorAt(x: 50, y: full.pixelsHigh - 20)?.usingColorSpace(.sRGB))
    #expect(bottom.greenComponent > 0.3 && bottom.blueComponent < 0.3, "\(bottom)")
    rt.window.window.orderOut(nil)
  }

  @Test func speechSpeaksQueuesAndReportsProgress() async throws {
    let rt = Self.runtime()
    var progress: [Int64] = []
    rt.plugins.on("speech.progress") { if let i = $0["index"].int { progress.append(i) } }
    let r = rt.call("speech", "speak", ["utterances": ["One.", "Two.", "Three."], "lang": "en", "volume": 0, "rate": 2, "request": "t"])
    #expect(r["request"] == "t")
    #expect(rt.call("speech", "state")["state"] == "playing")
    let done = await Self.wait(rt, "speech.state", timeout: 300) { $0["state"] == "done" }
    #expect(done?["count"] == 3)
    #expect(progress == [0, 1, 2])
    #expect(rt.call("speech", "speak", ["utterances": []]).isError)
    _ = rt.call("speech", "speak", ["utterances": ["A long sentence to be interrupted before it ends, surely."], "volume": 0])
    _ = rt.call("speech", "stop")
    #expect(rt.call("speech", "state")["state"] == "stopped")
  }

  @Test func translateDetectsAndTranslatesOnDevice() async throws {
    let rt = Self.runtime()
    let d = rt.call("translate", "detect", ["text": "Le chat dort sur la table de la cuisine depuis ce matin."])
    #expect(d["lang"] == "fr")
    #expect(rt.call("translate", "detect", ["text": "ok", "hint": "ja-JP"])["lang"] == "ja")
    #expect(!rt.call("translate", "userLanguage").str("lang").isEmpty)
    _ = rt.call("translate", "availability", ["from": "fr", "to": "en", "request": "av"])
    let av = await Self.wait(rt, "translate.availability", timeout: 400)
    print("translate.availability fr->en:", av?.str("status") ?? "none")
    guard av?["status"] == "installed" else { return }  // this Mac has no fr->en model: nothing more to check
    _ = rt.call("translate", "run", ["texts": ["Le chat est sur la table.", "", "Bonjour"], "from": "fr", "to": "en", "request": "r"])
    let r = await Self.wait(rt, "translate.result", timeout: 600)
    #expect(r?["ok"] == true)
    let out = r?.list("texts").compactMap(\.string) ?? []
    print("translate.run:", out, "ms", r?["ms"] ?? .null)
    #expect(out.count == 3 && out[1] == "")
    #expect(out[0].lowercased().contains("cat") && out[0].lowercased().contains("table"))
  }

  /// Test windows never show on the user's screen or float over other apps.
  @Test func testWindowsAreInvisible() {
    let rt = Self.runtime()
    #expect(TestMode.active)
    rt.window.window.orderFront(nil)
    #expect(rt.window.window.alphaValue == 0 && rt.window.window.ignoresMouseEvents && rt.window.window.level == .normal)
    // Its web views still run like visible ones (WebKit's occlusion detection is off).
    _ = rt.call("webviews", "create", ["id": "v"])
    _ = rt.call("content", "show", ["panes": ["v"]])
    let wv = rt.webviews.record("v")?.webView
    #expect((wv?.value(forKey: "_windowOcclusionDetectionEnabled") as? Bool) == false)
    let web = rt.call("webviews", "create", ["id": "m"])["id"]
    let mini = rt.call("window", "openMini", ["webview": web])
    // den's own panel (PIP.framework keeps an in-process PIPPanel of its own after a PiP test).
    let panel = NSApp.windows.first { $0 is DenNSPanel && $0.isVisible }

    #expect(!mini.isError && panel?.alphaValue == 0 && panel?.level == .normal)
    _ = rt.call("window", "closeMini", ["id": mini["id"]])
    rt.window.window.orderOut(nil)
  }

  @Test func tokensFollowThePalette() {
    let rt = Self.runtime()
    let t = rt.call("ui", "tokens")
    for k in ["bg", "panel", "text", "secondary", "border", "hover", "accent", "mark", "shadow"] { #expect(t.str(k).hasPrefix("rgba("), "\(k)") }
    #expect(t["dark"].bool != nil)
  }
}
