import AppKit
import CordisValue
import DenTestSupport
import Testing
import WebKit

@testable import DenHost
@testable import PluginCores

/// Popular store extensions through den's real install path (store download, CRX/XPI unpack,
/// manifest checks, permission prompt, `WKWebExtension` load), then what they do on a real page.
/// Needs the network (Chrome Web Store, addons.mozilla.org): CI has it.
@MainActor
@Suite(.serialized, .watchdog(seconds: 240))
struct ExtensionCompatTests {
  static let vimium = "dbepggeogbaibhgnhhndojpepiihcmeb"

  func wait(_ seconds: Double = 45, file: StaticString = #fileID, line: UInt = #line, _ cond: () async -> Bool) async -> Bool {
    await Wait.until("a condition", seconds: seconds, file: file, line: line) { await cond() }
  }

  static let linksPage = """
    <!doctype html><title>links</title><body style='margin:0;font:15px -apple-system'>
    <p style='padding:20px'><a href='#one' id=l1>One</a> <a href='#two' id=l2>Two</a> <a href='#three' id=l3>Three</a>
    <button id=b1>Button</button></p><div style='height:6000px;background:linear-gradient(#fff,#ccc)'>tall</div>
    <script>window.__keys=[];addEventListener('keydown',e=>__keys.push(e.key+(e.isTrusted?'':'?')),true);</script></body>
    """

  /// Installs a store item and accepts the prompt. Returns the den id, or nil (the failure is printed).
  func install(_ h: Harness, source: String, id: String) async -> String? {
    let before = h.events.count
    let r = h.rt.call("webext", "installFromStore", ["source": .string(source), "id": .string(id)])
    print("compat install \(source):\(id) -> \(r)")
    var accepted = 0
    let done = await wait(120) {
      if let p = h.rt.extensions.prompts.first {
        print("compat prompt \(h.rt.ui.dialog.title.stringValue) | \(h.rt.ui.dialog.message.stringValue.replacingOccurrences(of: "\n", with: " | "))")
        h.action(p.id, "button", ["button": "ok"])
        accepted += 1
      }
      return h.events[before...].contains { $0.0 == "webext.installed" || $0.0 == "webext.failed" }
    }
    let ev = h.events[before...].first { $0.0 == "webext.installed" || $0.0 == "webext.failed" }
    print("compat result \(id) done=\(done) accepted=\(accepted) event=\(ev.map { "\($0.0) \($0.1)" } ?? "none")")
    guard let ev, ev.0 == "webext.installed" else { return nil }
    return ev.1.s("id")
  }

  /// Everything den and WebKit know about an installed extension.
  func report(_ h: Harness, _ id: String) async {
    let d = h.rt.call("webext", "get", ["id": .string(id)])
    print("compat describe \(d)")
    if let ctx = h.rt.extensions.contexts[id] {
      print("compat ctx loaded=\(ctx.isLoaded) errors=\(ctx.errors.map(\.localizedDescription)) extErrors=\(ctx.webExtension.errors.map(\.localizedDescription))")
      print("compat granted=\(ctx.currentPermissions.map(\.rawValue).sorted()) patterns=\(ctx.currentPermissionMatchPatterns.map(\.string).sorted())")
      do { try await ctx.loadBackgroundContent(); print("compat background loaded ok") } catch { print("compat background error: \(error)") }
      print("compat ctx errors after background=\(ctx.errors.map(\.localizedDescription))")
    }
  }

  /// Runs `script` (async function body) in one of the extension's own pages, where `chrome.*` is.
  func probe(_ h: Harness, _ id: String, page: String, _ script: String) async -> Any? {
    guard let ctx = h.rt.extensions.contexts[id], let cfg = ctx.webViewConfiguration else { print("compat probe: no context"); return nil }
    let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: cfg)
    w.load(URLRequest(url: ctx.baseURL.appendingPathComponent(page)))
    _ = await wait(20) { !w.isLoading && w.url != nil }
    let r: JSResult? = await Wait.callback("probe", seconds: 30) { done in
      w.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { res in
        switch res {
        case .success(let v): done(JSResult(value: v, error: nil))
        case .failure(let e): done(JSResult(value: nil, error: e))
        }
      }
    }
    print("compat probe \(page) url=\(String(describing: w.url)): value=\(String(describing: r?.value)) error=\(String(describing: r?.error))")
    w.stopLoading()
    return r?.value
  }

  static let apiProbe = """
    const out = {};
    for (const k of ['bookmarks','history','sessions','search','favicon','notifications','scripting','webNavigation','tabs','windows','commands','storage','runtime','action','contextMenus','clipboard'])
      out[k] = typeof chrome[k];
    out.session = typeof chrome.storage?.session;
    out.sync = typeof chrome.storage?.sync;
    out.setAccessLevel = typeof chrome.storage?.session?.setAccessLevel;
    out.getAllFrames = typeof chrome.webNavigation?.getAllFrames;
    out.setZoom = typeof chrome.tabs?.setZoom;
    out.getBrowserInfo = typeof chrome.runtime?.getBrowserInfo;
    out.browser = typeof browser;
    out.baseURL = chrome.runtime.getURL('');
    const d = Object.getOwnPropertyDescriptor(chrome.storage, 'session');
    out.sessionDescriptor = d ? JSON.stringify({w: d.writable, g: !!d.get, s: !!d.set, c: d.configurable}) : 'none (proto)';
    out.strictAssign = (() => { 'use strict'; try { const s = chrome.storage.session; chrome.storage.session = chrome.storage.local; const ok = chrome.storage.session === chrome.storage.local; chrome.storage.session = s; return 'ok ' + ok; } catch (e) { return 'throws ' + e; } })();
    const t = (p, ms) => Promise.race([p, new Promise(r => setTimeout(() => r('timeout'), ms))]);
    try { out.bgBrowserInfo = JSON.stringify(await t(chrome.runtime.sendMessage({handler: 'getBrowserInfo'}), 8000)); } catch (e) { out.bgBrowserInfo = 'error ' + e; }
    try { out.sync = JSON.stringify(await t(chrome.storage.sync.get(null), 5000)).slice(0, 200); } catch (e) { out.syncGet = 'error ' + e; }
    return JSON.stringify(out);
    """

  /// Sends a real key press (keyDown + keyUp) through the window to the focused web view.
  func press(_ w: WKWebView, _ ch: String, _ keyCode: UInt16, shift: Bool = false) {
    guard let win = w.window else { return }
    for type in [NSEvent.EventType.keyDown, .keyUp] {
      guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: shift ? .shift : [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: win.windowNumber, context: nil, characters: ch, charactersIgnoringModifiers: ch,
                                     isARepeat: false, keyCode: keyCode) else { continue }
      win.sendEvent(e)
    }
  }

  func vimiumOnPage(_ h: Harness, _ extId: String, mock: MockServices) async {
    let tab = h.tabs("open", ["url": .string(mock.base + "/links")]).s("id")
    h.tabs("select", ["id": .string(tab)])
    #expect(await wait { h.rt.webviews.record(tab)?.loading == false && h.rt.webviews.record(tab)?.webView != nil })
    guard let w = h.rt.webviews.record(tab)?.webView else { return }
    TestMode.keepActive(w)
    let css = await Wait.js(w, "getComputedStyle(document.documentElement).getPropertyValue('--vimium-background-color')") as? String ?? "?"
    print("compat vimium css injected=\(css)")
    h.rt.window.window.makeFirstResponder(w)
    print("compat firstResponder=\(String(describing: h.rt.window.window.firstResponder)) key=\(h.rt.window.window.isKeyWindow)")
    try? await Task.sleep(for: .seconds(2))
    press(w, "f", 3)
    let hints = await wait(10) { (await Wait.js(w, "document.querySelectorAll('.vimiumHintMarker').length") as? Int ?? 0) > 0 }
    let n = await Wait.js(w, "document.querySelectorAll('.vimiumHintMarker').length") as? Int ?? -1
    let keys = await Wait.js(w, "JSON.stringify(window.__keys)") as? String ?? "?"
    print("compat vimium f: hints=\(hints) markers=\(n) pageKeys=\(keys)")
    press(w, "\u{1b}", 53)
    try? await Task.sleep(for: .milliseconds(300))
    press(w, "j", 38)
    let scrolled = await wait(10) { (await Wait.js(w, "window.scrollY") as? Double ?? 0) > 0 }
    print("compat vimium j: scrolled=\(scrolled) y=\(await Wait.js(w, "window.scrollY") ?? "?") pageKeys=\(await Wait.js(w, "JSON.stringify(window.__keys)") ?? "?")")
  }

  @Test func vimiumFromChromeWebStore() async throws {
    let mock = MockServices()
    try mock.start()
    defer { mock.stop() }
    mock.page("/links", Self.linksPage)
    let h = Harness()
    h.startTabs()
    h.record(["webext.installed", "webext.failed"])
    let id = try #require(await install(h, source: "chrome", id: Self.vimium))
    await report(h, id)
    _ = await probe(h, id, page: "pages/options.html", Self.apiProbe)
    await vimiumOnPage(h, id, mock: mock)
  }

  @Test func vimiumFromFirefoxAddons() async throws {
    let mock = MockServices()
    try mock.start()
    defer { mock.stop() }
    mock.page("/links", Self.linksPage)
    let h = Harness()
    h.startTabs()
    h.record(["webext.installed", "webext.failed"])
    let id = try #require(await install(h, source: "firefox", id: "vimium-ff"))
    await report(h, id)
    _ = await probe(h, id, page: "pages/options.html", Self.apiProbe)
    await vimiumOnPage(h, id, mock: mock)
  }

  @Test func otherPopularExtensions() async throws {
    let mock = MockServices()
    try mock.start()
    defer { mock.stop() }
    mock.page("/data.json", #"{"name": "den", "list": [1, 2, 3], "nested": {"ok": true}}"#, type: "application/json")
    let h = Harness()
    h.startTabs()
    h.record(["webext.installed", "webext.failed"])
    for (source, id, label) in [("chrome", "nngceckbapebfimnlniiiahkandclblb", "Bitwarden"), ("chrome", "bcjindcccaagfpapjjmafapmmgkkhgoa", "JSON Formatter"),
                                ("chrome", "eimadpbcbfnmbkopoojfekhnkhdbieeh", "Dark Reader (Chrome)")] {
      print("compat === \(label)")
      guard let ext = await install(h, source: source, id: id) else { continue }
      await report(h, ext)
    }
    let tab = h.tabs("open", ["url": .string(mock.base + "/data.json")]).s("id")
    h.tabs("select", ["id": .string(tab)])
    _ = await wait { h.rt.webviews.record(tab)?.loading == false }
    try? await Task.sleep(for: .seconds(3))
    if let w = h.rt.webviews.record(tab)?.webView {
      print("compat json page: \(await Wait.js(w, "document.body ? document.body.innerHTML.slice(0, 400) : 'nobody'") ?? "?")")
    }
  }
}
