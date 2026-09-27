import AppKit
import CordisValue
import Foundation
import Testing
import WebKit

@testable import DenHost
@testable import PluginCores

/// The `pagetools` plugin against the real host: real WebKit pages (fake origins), the real
/// vendored Readability / text-fragments scripts, real speech (muted) and real on-device
/// translation. The clipboard is never touched: `app.copy` is intercepted, captures go to a
/// temporary folder.
@MainActor
@Suite(.serialized)
struct PageToolsTests {
  @MainActor final class Rig {
    let h = Harness()
    var core: PageToolsCore!
    var copied: [String] = []
    var toasts: [String] = []
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("den-pagetools-\(UUID())")

    init() {
      h.rt.permissions.grant("pagetools", ["pages:*"])
      h.startTabs()
      var env = h.env
      let base = env.invoke
      env.invoke = { [unowned self] s, m, a in
        if s == "app", m == "copy" { copied.append(a.s("text")); return .okay }
        if s == "speech", m == "speak" { var b = a; b.put("volume", 0); return base(s, m, b) }
        if s == "ui", m == "set", a.s("slot") == "toast" { toasts.append(a["tree"].s("text")) }
        return base(s, m, a)
      }
      core = PageToolsCore(env: env)
      let timers = h.timers.count
      core.start()
      // Before the deferred start: nothing bound, nothing registered, one timer.
      idleAtStart = h.rt.keys.bindings["cmd+shift+2"] == nil && h.rt.webviews.contextMenu == nil && h.timers.count == timers + 1
      core.startNow()
    }
    var idleAtStart = false

    var rt: DenRuntime { h.rt }

    /// A selected tab showing `html` as `url`. Returns its web view id.
    func tab(_ html: String, url: String = "https://news.test/story") async throws -> String {
      let id = h.tabs("open", ["url": "about:blank"])["id"].string!
      _ = h.tabs("select", ["id": .string(id)])
      try await load(id, html, url: url)
      return id
    }

    func load(_ id: String, _ html: String, url: String) async throws {
      let w = try #require(rt.webviews.record(id)?.webView)
      w.loadHTMLString(html, baseURL: URL(string: url))
      for _ in 0..<100 where w.isLoading || w.url?.absoluteString != url { try await Task.sleep(for: .milliseconds(30)) }
      try await Task.sleep(for: .milliseconds(150))
    }

    /// Page JS with a timeout: a hung web content process fails the check instead of hanging.
    func js(_ id: String, _ script: String) async -> Any? {
      guard let w = rt.webviews.record(id)?.webView else { return nil }
      return await awaitCallback(10, UncheckedBox<Any?>(nil)) { done in w.evaluateJavaScript(script) { r, _ in done(UncheckedBox(r)) } }.value
    }

    func until(_ timeout: Int = 400, _ cond: () async -> Bool) async -> Bool {
      for _ in 0..<timeout {
        if await cond() { return true }
        try? await Task.sleep(for: .milliseconds(50))
      }
      return await cond()
    }

    func pillButtons() -> [String] {
      let header = h.tree("sidebar.header", 0)
      let pill = header.a("children").first { $0.s("type") == "urlPill" } ?? .null
      return pill.a("buttons").map { $0.s("id") + ($0.b("active") ? "*" : "") }
    }
  }

  static let article: String = {
    let para = "The committee met on Tuesday to review the proposal in detail, and after a long discussion about costs, timelines and the effect on nearby residents, most members agreed that the plan should move forward with a few changes to the schedule. "
    let body = (1...8).map { "<p>\(para)Paragraph \($0) adds a little more context to the story.</p>" }.joined()
    return "<html lang=en><head><title>Council approves the plan</title></head><body><header style='position:fixed;top:0;left:0;right:0;height:50px;background:#eee'>Site header</header>"
      + "<div id=banner>Subscribe to our newsletter</div><article><h1>Council approves the plan</h1>\(body)</article></body></html>"
  }()

  static let french = """
    <html lang=fr><head><title>Le chat et la table</title></head><body><article><h1>Le chat et la table</h1>
    <p>Le chat dort sur la table de la cuisine depuis ce matin, et personne ne veut le déranger.</p>
    <p>Ma sœur prépare le déjeuner pendant que mon frère lit le journal dans le salon.</p>
    <p id=last>Nous irons à la plage demain si le temps le permet.</p></article></body></html>
    """

  @Test func startCostsNothing() {
    let r = Rig()
    #expect(r.idleAtStart)
    #expect(r.rt.webviews.scripting.loadedFiles.isEmpty)
    #expect(r.core.pending.isEmpty)
    for c in ["cmd+ctrl+r", "cmd+shift+2"] { #expect(r.rt.keys.bindings[c] != nil, "\(c)") }
    #expect(r.rt.webviews.ruleLists.isEmpty)
    #expect(r.rt.webviews.contextMenu != nil)
    // Settings > Reading, and changes there apply live.
    #expect(r.rt.call("settings", "list").array?.contains { $0.s("id") == "pagetools" } == true)
    _ = r.rt.call("settings", "set", ["id": "pagetools", "key": "size", "value": 24])
    _ = r.rt.call("settings", "set", ["id": "pagetools", "key": "captureDest", "value": "save"])
    #expect(r.core.size == 24 && r.h.storage("pagetools", "reader")["size"] == 24)
    #expect(r.h.storage("pagetools", "capture")["dest"] == "save")
  }

  @Test func readablePageGetsTheReaderButtonAndReaderOpens() async throws {
    let r = Rig()
    let id = try await r.tab(Self.article)
    #expect(await r.until { r.pillButtons() == ["pagetools.pill.reader"] })
    #expect(r.core.probes[id]?.lang == "en")
    #expect(r.rt.webviews.scripting.loadedFiles == ["Readability-readerable.js"])
    // The button (a click on it) opens the reader over the page.
    r.h.action("pagetools.pill.reader", "click", ["webview": .string(id)])
    #expect(await r.until { r.core.readerOpen.contains(id) })
    #expect(await r.js(id, "document.querySelector('den-reader') !== null") as? Bool == true)
    #expect(await r.js(id, "document.documentElement.style.overflow") as? String == "hidden")
    #expect(r.pillButtons() == ["pagetools.pill.reader*"])
    // Toolbar clicks come back as messages: larger text, sans font.
    r.core.message(id, ["tool": "reader", "action": "larger"])
    r.core.message(id, ["tool": "reader", "action": "font"])
    #expect(r.core.size == 21 && r.core.font == "sans")
    #expect(r.h.storage("pagetools", "reader")["size"] == 21)
    // ⌃⌘R closes it.
    r.h.key("cmd+ctrl+r")
    #expect(await r.until { await r.js(id, "document.querySelector('den-reader') === null") as? Bool == true })
    #expect(!r.core.readerOpen.contains(id))
  }

  @Test func alwaysUseReaderOnASite() async throws {
    let r = Rig()
    let id = try await r.tab(Self.article)
    #expect(await r.until { r.core.probes[id] != nil })
    r.core.run("pagetools.readerAlways")
    #expect(r.h.storage("pagetools", "readerSites") == ["news.test"])
    #expect(await r.until { r.core.readerOpen.contains(id) })
    // Another article on the same site opens in the reader by itself.
    try await r.load(id, Self.article, url: "https://news.test/other")
    #expect(await r.until { r.core.readerOpen.contains(id) })
    #expect(await r.until { await r.js(id, "document.querySelector('den-reader') !== null") as? Bool == true })
  }

  @Test func readAloudHighlightsTheSentence() async throws {
    let r = Rig()
    let id = try await r.tab(Self.article)
    #expect(await r.until { r.core.probes[id] != nil })
    var progress: [Int64] = []
    r.rt.plugins.on("speech.progress") { if let i = $0["index"].int { progress.append(i) } }
    r.core.run("pagetools.readAloud")  // opens the reader, then reads
    #expect(await r.until(400) { progress.count >= 2 })
    #expect(r.core.speaking == id)
    #expect(await r.js(id, "CSS.highlights.has('den-speak')") as? Bool == true)
    // Pause from the toolbar, then speed up.
    r.core.message(id, ["tool": "reader", "action": "speak"])
    #expect(await r.until { r.rt.call("speech", "state")["state"] == "paused" })
    r.core.message(id, ["tool": "reader", "action": "rate"])
    #expect(r.core.rate == 1.25 && r.rt.call("speech", "state")["rate"] == 1.25)
    r.core.closeReader(id)
    #expect(await r.until { r.rt.call("speech", "state")["state"] == "stopped" })
    #expect(r.core.speaking == nil)
  }

  @Test func translatesAFrenchPageAndRestoresIt() async throws {
    let r = Rig()
    _ = r.rt.call("translate", "availability", ["from": "fr", "to": "en", "request": "t"])
    var status = ""
    r.rt.plugins.on("translate.availability") { status = $0.s("status") }
    #expect(await r.until(400) { !status.isEmpty })
    guard status == "installed", r.rt.call("translate", "userLanguage").s("lang") == "en" else { return }
    let id = try await r.tab(Self.french, url: "https://journal.test/chat")
    #expect(await r.until { r.pillButtons().contains("pagetools.pill.translate") })
    r.h.action("pagetools.pill.translate", "click", ["webview": .string(id)])
    #expect(await r.until(400) { r.core.translated[id] != nil })
    // The last batch's write-back into the page lands a moment after its result.
    var last = ""
    #expect(await r.until(400) {
      last = await r.js(id, "document.getElementById('last').textContent") as? String ?? ""
      return last.lowercased().contains("beach")
    }, "\(last)")
    #expect((await r.js(id, "document.title") as? String ?? "").lowercased().contains("cat"))
    #expect(r.pillButtons().contains("pagetools.pill.translate*"))
    #expect(r.toasts.contains("Translated from French"))
    r.core.run("pagetools.showOriginal")
    #expect(await r.until { (await r.js(id, "document.getElementById('last').textContent") as? String) == "Nous irons à la plage demain si le temps le permet." })
    #expect(await r.js(id, "document.title") as? String == "Le chat et la table")
  }

  @Test func capturesAnElementTheVisibleAreaAndTheFullPage() async throws {
    let r = Rig()
    r.rt.window.window.orderFront(nil)
    _ = r.rt.call("storage", "set", ["ns": "pagetools", "key": "capture", "value": ["dest": "save", "folder": .string(r.dir.path)]])
    let html = "<body style='margin:0'><div id=box style='margin:30px;width:240px;height:120px;background:rgb(0,160,0)'></div><div style='height:2600px'></div></body>"
    let id = try await r.tab(html, url: "https://shots.test/")
    func shot() async -> Value? {
      var got: Value?
      r.rt.plugins.on("webviews.snapshot") { if got == nil, !$0["bytes"].isNull { got = $0 } }
      _ = await r.until(400) { got != nil }
      return got
    }
    // Element: the picker, then a click on #box (the test hook clicks for us).
    r.core.run("pagetools.capture.element")
    #expect(await r.until { await r.js(id, "document.querySelector('den-capture') !== null") as? Bool == true })
    _ = r.rt.call("webviews", "inject", ["id": .string(id), "plugin": "pagetools", "script": "return window.__denCapture.pick('#box')"])
    let e = await shot()
    print("capture.element:", e ?? .null)
    let scale = Int64(r.rt.window.window.backingScaleFactor)
    #expect(e?["width"] == .int(240 * scale) && e?["height"] == .int(120 * scale))
    #expect(e?.str("path").hasPrefix(r.dir.path) == true && e?.str("path").hasSuffix(".png") == true)
    #expect(await r.until { r.toasts.last?.hasPrefix("Saved den Capture ") == true })
    #expect(await r.js(id, "document.querySelector('den-capture') === null") as? Bool == true)  // not in the picture
    r.core.run("pagetools.capture.visible")
    let v = await shot()
    #expect(v?["ok"] == true)
    r.core.run("pagetools.capture.full")
    let f = await shot()
    #expect((f?["height"].int ?? 0) >= 2700 * scale && (f?["height"].int ?? 0) > (v?["height"].int ?? 0))
    let files = try FileManager.default.contentsOfDirectory(atPath: r.dir.path)
    #expect(files.count == 3)
    r.rt.window.window.orderOut(nil)
  }

  @Test func zapHidesElementsAndRemembersThemPerSite() async throws {
    let r = Rig()
    let id = try await r.tab(Self.article, url: "https://zap.test/a")
    r.core.run("pagetools.zap")
    #expect(await r.until { await r.js(id, "document.querySelector('den-zap') !== null") as? Bool == true })
    _ = r.rt.call("webviews", "inject", ["id": .string(id), "plugin": "pagetools", "script": "return window.__denZap.hide('#banner')"])
    #expect(await r.until { r.core.zaps["zap.test"] == ["#banner"] })
    #expect(await r.js(id, "getComputedStyle(document.getElementById('banner')).display") as? String == "none")
    #expect(r.h.storage("pagetools", "zaps")["zap.test"] == ["#banner"])
    // The content rule hides it at document start on the next load, without any script.
    #expect(await r.until { r.rt.webviews.ruleLists.count == 1 })
    try await r.load(id, Self.article, url: "https://zap.test/b")
    #expect(await r.js(id, "getComputedStyle(document.getElementById('banner')).display") as? String == "none")
    #expect(await r.js(id, "document.querySelector('den-zap') === null") as? Bool == true)
    // Remove Sticky Headers: the fixed header joins the list.
    r.core.run("pagetools.unstick")
    #expect(await r.until { (r.core.zaps["zap.test"] ?? []).count == 2 })
    #expect(r.core.zaps["zap.test"]?.last == "header")
    #expect(await r.js(id, "getComputedStyle(document.querySelector('header')).display") as? String == "none")
    // Show everything again.
    r.core.run("pagetools.zapClear")
    #expect(r.core.zaps["zap.test"] == nil)
  }

  @Test func copyLinkToHighlight() async throws {
    let r = Rig()
    let id = try await r.tab(Self.article, url: "https://news.test/story#top")
    _ = r.rt.call("webviews", "inject", ["id": .string(id), "plugin": "pagetools", "files": ["vendor/fragment-generation.js", "highlight.js"],
                                         "global": "__denHighlight", "script": "return window.__denHighlight.select('Paragraph 5 adds a little more context')"])
    try await Task.sleep(for: .milliseconds(300))
    r.core.highlight(id)
    #expect(await r.until { !r.copied.isEmpty })
    let url = r.copied.first ?? ""
    #expect(url.hasPrefix("https://news.test/story#:~:text="), "\(url)")
    #expect(url.lowercased().contains("paragraph%205"))
    #expect(r.toasts.contains("Copied link to highlight"))
  }

  @Test func captureNamesUseLocalTime() {
    #expect(PageToolsCore.civil(0) == (1970, 1, 1))
    #expect(PageToolsCore.civil(20_723) == (2026, 9, 27))
    #expect(PageToolsCore.civil(11_016) == (2000, 2, 29))
  }
}
