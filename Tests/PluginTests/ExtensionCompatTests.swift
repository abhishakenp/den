import AppKit
import CordisValue
import DenTestSupport
import Testing
import WebKit

@testable import DenHost
@testable import PluginCores

struct CompatJSOutcome: @unchecked Sendable {
  let value: Any?
  let error: Error?
}

/// Popular store extensions through den's real install path (store download, CRX/XPI unpack,
/// manifest checks, permission prompt, `WKWebExtension` load), then what they do on a real page.
/// Needs the network (Chrome Web Store, addons.mozilla.org): CI has it.
@MainActor
@Suite(.serialized, .watchdog(seconds: 360))
struct ExtensionCompatTests {
  static let vimium = "dbepggeogbaibhgnhhndojpepiihcmeb"

  func wait(_ seconds: Double = 45, file: StaticString = #fileID, line: UInt = #line, _ cond: () async -> Bool) async -> Bool {
    await Wait.until("a condition", seconds: seconds, file: file, line: line) { await cond() }
  }

  static let linksPage = """
    <!doctype html><title>links</title><body style='margin:0;font:15px -apple-system'>
    <p style='padding:20px'><a href='/links?one' id=l1>One</a> <a href='/links?two' id=l2>Two</a> <a href='/links?three' id=l3>Three</a>
    <button id=b1>Button</button></p><div style='height:6000px;background:linear-gradient(#fff,#ccc)'>tall</div>
    <script>window.__keys=[];addEventListener('keydown',e=>__keys.push(e.key+(e.isTrusted?'':'?')),true);
    window.__clicks=[];addEventListener('click',e=>__clicks.push((e.target.id||e.target.tagName)+(e.isTrusted?'':'?')+(e.metaKey?'+meta':'')),true);</script></body>
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
      var bg = "pending"
      ctx.loadBackgroundContent { err in bg = err.map { "error: \($0.localizedDescription)" } ?? "ok" }
      _ = await wait(25) { bg != "pending" }
      print("compat background load=\(bg)")
      print("compat ctx errors after background=\(ctx.errors.map(\.localizedDescription))")
    }
  }

  /// Runs `script` (async function body) in one of the extension's own pages, where `chrome.*` is.
  func probe(_ h: Harness, _ id: String, page: String, _ script: String) async -> Any? {
    guard let ctx = h.rt.extensions.contexts[id], let cfg = ctx.webViewConfiguration else { print("compat probe: no context"); return nil }
    let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: cfg)
    w.load(URLRequest(url: ctx.baseURL.appendingPathComponent(page)))
    _ = await wait(20) { !w.isLoading && w.url != nil }
    let r: CompatJSOutcome? = await Wait.callback("probe", seconds: 30) { done in
      w.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { res in
        switch res {
        case .success(let v): done(CompatJSOutcome(value: v, error: nil))
        case .failure(let e): done(CompatJSOutcome(value: nil, error: e))
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
    out.setAccessLevelNative = String(chrome.storage?.session?.setAccessLevel).includes('[native code]');
    const events = {webNavigation: ['onHistoryStateUpdated', 'onReferenceFragmentUpdated', 'onCommitted', 'onCompleted', 'onBeforeNavigate', 'onDOMContentLoaded'],
      tabs: ['onRemoved', 'onActivated', 'onReplaced', 'onUpdated', 'onCreated'], windows: ['onFocusChanged', 'onRemoved', 'onCreated'],
      runtime: ['onInstalled', 'onStartup', 'onMessage', 'onConnect'], storage: ['onChanged']};
    out.missingEvents = Object.entries(events).flatMap(([ns, es]) => es.filter(e => !chrome[ns] || !chrome[ns][e]).map(e => ns + '.' + e)).join(',');
    out.windowIdNone = String(chrome.windows?.WINDOW_ID_NONE);
    out.shimReport = JSON.stringify(globalThis.__denShimReport);
    // Vimium's background as a module here: the error that stops it, if any.
    try { await import('/background_scripts/main.js'); out.mainImport = 'ok'; } catch (e) { out.mainImport = 'error ' + e + ' ' + (e && e.stack || '').slice(0, 300); }
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

  /// Vimium's iframes (vomnibar, HUD, help), which live in open shadow roots: class:display.
  static let vimiumFrames = """
    JSON.stringify([...document.querySelectorAll('div.vimium-reset')].flatMap(d => d.shadowRoot ? [...d.shadowRoot.querySelectorAll('iframe')] : [])
      .map(f => f.className + ':' + getComputedStyle(f).display))
    """

  /// Key codes of Vimium's hint characters (US layout).
  static let hintKeys: [Character: UInt16] = ["a": 0, "s": 1, "d": 2, "f": 3, "g": 5, "h": 4, "j": 38, "k": 40, "l": 37]

  static let contentProbe = """
    const tabs = await chrome.tabs.query({});
    const t = tabs.find(t => /\\/links$/.test(t.url || ''));
    if (!t) return JSON.stringify({noTab: tabs.map(t => t.url)});
    const out = {tab: t.id + ' ' + t.url};
    // What a runtime message from the content script carries as its sender.
    chrome.runtime.onMessage.addListener((m, sender, send) => {
      if (!m || !m.denEcho) return false;
      send({tab: sender.tab ? {id: sender.tab.id, url: sender.tab.url, title: sender.tab.title} : null, url: sender.url, frameId: sender.frameId, origin: sender.origin, id: sender.id});
      return false;
    });
    chrome.runtime.onMessage.addListener((m, sender, send) => {
      if (!m || !m.denEchoAsync) return false;
      setTimeout(() => send({late: true}), 50);
      return true;
    });
    try {
      const [e] = await chrome.scripting.executeScript({target: {tabId: t.id}, func: async () => JSON.stringify(await chrome.runtime.sendMessage({denEcho: 1}))});
      out.echo = e && e.result;
      const [a] = await chrome.scripting.executeScript({target: {tabId: t.id}, func: async () => JSON.stringify(await chrome.runtime.sendMessage({denEchoAsync: 1}))});
      out.echoAsync = a && a.result;
    } catch (e) { out.echo = 'error ' + e; }
    try {
      const [a] = await chrome.scripting.executeScript({target: {tabId: t.id}, func: async () => {
        try { const r = await chrome.runtime.sendMessage({handler: 'initializeFrame'}); return 'resolved ' + JSON.stringify(r) + ' ' + typeof r; } catch (e) { return 'rejected ' + e; }
      }});
      out.initRaw = a && a.result;
    } catch (e) { out.initRaw = 'error ' + e; }
    try {
      const r = await chrome.scripting.executeScript({target: {tabId: t.id}, func: async () => {
        const o = {};
        o.utils = typeof Utils; o.shim = String(globalThis.__denShim);
        o.normalMode = typeof normalMode === 'undefined' ? 'undeclared' : String(normalMode);
        o.enabled = typeof isEnabledForUrl === 'undefined' ? 'undeclared' : String(isEnabledForUrl);
        o.frameId = String(globalThis.frameId);
        o.handlers = typeof handlerStack === 'undefined' ? 'undeclared' : String(handlerStack.stack && handlerStack.stack.length);
        const t = (p) => Promise.race([p, new Promise(r => setTimeout(() => r('timeout'), 5000))]);
        try { o.init = JSON.stringify(await t(chrome.runtime.sendMessage({handler: 'initializeFrame'}))); } catch (e) { o.init = 'error ' + e; }
        try { o.settingsLoaded = typeof Settings === 'undefined' ? 'undeclared' : String(Settings.isLoaded()); } catch (e) { o.settingsLoaded = 'error ' + e; }
        try { o.session = JSON.stringify(await t(chrome.storage.session.get('vimiumSecret'))).slice(0, 60); } catch (e) { o.session = 'error ' + e; }
        try { o.sync = JSON.stringify(await t(chrome.storage.sync.get(null))).slice(0, 60); } catch (e) { o.sync = 'error ' + e; }
        return JSON.stringify(o);
      }});
      out.results = r.map(x => x.result); out.errors = r.map(x => x.error && String(x.error));
    } catch (e) { out.executeScript = 'error ' + e; }
    try {
      const [x] = await chrome.scripting.executeScript({target: {tabId: t.id}, func: () => document.title});
      out.title = x && x.result;
    } catch (e) { out.title = 'error ' + e; }
    return JSON.stringify(out);
    """

  /// Vimium's keys on a real page, each from a freshly loaded page: scrolling (j, G, gg), link
  /// hints (f, then Esc), hints for a new tab (F), the vomnibar (o), find (/) and tab switching
  /// through chrome.tabs (K). Returns what worked.
  @discardableResult
  func vimiumOnPage(_ h: Harness, _ extId: String, mock: MockServices) async -> [String: Bool] {
    var ok: [String: Bool] = [:]
    let other = h.tabs("open", ["url": .string(mock.base + "/links#other")]).s("id")
    let tab = h.tabs("open", ["url": .string(mock.base + "/links")]).s("id")
    h.tabs("select", ["id": .string(tab)])
    #expect(await wait { h.rt.webviews.record(tab)?.loading == false && h.rt.webviews.record(tab)?.webView != nil })
    guard let w = h.rt.webviews.record(tab)?.webView else { return ok }
    TestMode.keepActive(w)
    ok["content script"] = await wait(20) { (await Wait.js(w, "getComputedStyle(document.documentElement).getPropertyValue('--vimium-background-color')") as? String ?? "") != "" }
    // What the extension's content scripts see, through its own scripting API (same world).
    _ = await probe(h, extId, page: "pages/options.html", Self.contentProbe)
    func y() async -> Double { await Wait.js(w, "window.scrollY") as? Double ?? -1 }
    func frames() async -> String { await Wait.js(w, Self.vimiumFrames) as? String ?? "" }
    func markers() async -> Int { await Wait.js(w, "document.querySelectorAll('.vimiumHintMarker').length") as? Int ?? -1 }
    /// A fresh page with Vimium in normal mode and keyboard focus.
    func fresh() async {
      h.tabs("select", ["id": .string(tab)])
      w.reload()
      _ = await wait(20) { !w.isLoading }
      _ = await wait(10) { (await Wait.js(w, "getComputedStyle(document.documentElement).getPropertyValue('--vimium-background-color')") as? String ?? "") != "" }
      h.rt.window.window.makeFirstResponder(w)
      try? await Task.sleep(for: .seconds(1.5))
    }
    var notes: [String] = []

    await fresh()
    // Vimium scrolls smoothly with requestAnimationFrame, which a window that is never on screen
    // (these tests) doesn't get: then check the scrolling itself with smooth scrolling off.
    let raf = await Wait.asyncJS(w, "return await Promise.race([new Promise(r => requestAnimationFrame(() => r('ran'))), new Promise(r => setTimeout(() => r('none'), 2000))])") as? String ?? "?"
    notes.append("requestAnimationFrame=\(raf)")
    press(w, "j", 38)
    let smooth = await wait(5) { await y() > 0 }
    notes.append("smooth j=\(smooth)")
    if !smooth {
      _ = await probe(h, extId, page: "pages/options.html", "await chrome.storage.sync.set({smoothScroll: false}); return JSON.stringify(await chrome.storage.sync.get('smoothScroll'));")
      await fresh()
      press(w, "j", 38)
    }
    ok["j scroll down"] = await wait(10) { await y() > 0 }
    press(w, "G", 5, shift: true)
    ok["G bottom"] = await wait(10) { await y() > 2000 }
    press(w, "g", 5)
    press(w, "g", 5)
    ok["gg top"] = await wait(10) { await y() == 0 }
    press(w, "d", 2)
    ok["d half page down"] = await wait(10) { await y() > 100 }

    await fresh()
    press(w, "f", 3)
    ok["f link hints"] = await wait(10) { await markers() > 0 }
    notes.append("hints=\(await Wait.js(w, "[...document.querySelectorAll('.vimiumHintMarker')].map(m => m.textContent).join(',')") ?? "?")")
    press(w, "\u{1b}", 53)
    ok["Esc leaves hints"] = await wait(5) { await markers() <= 0 }

    // f, then a hint: the link opens in this tab.
    await fresh()
    press(w, "f", 3)
    _ = await wait(10) { await markers() > 0 }
    let hintA = await Wait.js(w, "document.querySelector('.vimiumHintMarker')?.textContent || ''") as? String ?? ""
    for ch in hintA.lowercased() { press(w, String(ch), Self.hintKeys[ch] ?? 0) }
    ok["f follows a link"] = await wait(10) { w.url?.query != nil }
    notes.append("f \(hintA) -> \(w.url?.absoluteString ?? "?") markers=\(await markers()) clicks=\(await Wait.js(w, "JSON.stringify(window.__clicks)") ?? "?")")

    await fresh()
    let tabsBefore = h.ids("today").count
    press(w, "F", 3, shift: true)
    ok["F link hints"] = await wait(10) { await markers() > 0 }
    let first = await Wait.js(w, "document.querySelector('.vimiumHintMarker')?.textContent || ''") as? String ?? ""
    for ch in first.lowercased() { press(w, String(ch), Self.hintKeys[ch] ?? 0) }
    ok["F opens a new tab"] = await wait(10) { h.ids("today").count > tabsBefore }
    notes.append("F clicks=\(await Wait.js(w, "JSON.stringify(window.__clicks)") ?? "?") markers=\(await markers())")
    let newWindows = h.events.filter { $0.0 == "webviews.newWindow" }.map { $0.1.s("url") }
    notes.append("F first=\(first) tabs \(tabsBefore)->\(h.ids("today").count) newWindow=\(newWindows) pageURL=\(w.url?.absoluteString ?? "?")")

    await fresh()
    press(w, "o", 31)
    ok["o vomnibar"] = await wait(10) { (await frames()).range(of: "vomnibar-frame[^\"]*:block", options: .regularExpression) != nil }
    notes.append("afterO=\(await frames())")

    await fresh()
    press(w, "/", 44)
    ok["/ find"] = await wait(10) { (await frames()).range(of: "hud-frame[^\"]*:block", options: .regularExpression) != nil }
    notes.append("afterFind=\(await frames())")

    await fresh()
    let before = h.selected
    press(w, "K", 40, shift: true)
    ok["K next tab"] = await wait(10) { h.selected != before }
    notes.append("K \(String(describing: before))->\(String(describing: h.selected)) other=\(other)")

    let keys = await Wait.js(w, "JSON.stringify(window.__keys)") ?? "?"
    print("compat vimium \(extId) results=\(ok.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")) notes=\(notes) pageKeys=\(keys)")
    if let ctx = h.rt.extensions.contexts[extId] { print("compat vimium ctx errors=\(ctx.errors.map(\.localizedDescription))") }
    return ok
  }

  static func pill(_ v: NSView) -> URLPillNode? {
    if let p = v as? URLPillNode { return p }
    for s in v.subviews { if let p = pill(s) { return p } }
    return nil
  }

  /// The user's path: the store page, den's own "Add to den" in the URL pill, the prompt.
  func installFromPill(_ h: Harness, url: String, storeId: String) async -> String? {
    let tab = h.tabs("open", ["url": .string(url)]).s("id")
    h.tabs("select", ["id": .string(tab)])
    let loaded = await wait(60) { h.rt.webviews.record(tab)?.loading == false && h.rt.webviews.record(tab)?.url.contains(storeId) == true }
    let offered = await wait(20) { h.rt.extensions.ui.storeOffer?.id == storeId }
    let pill = Self.pill(h.rt.ui.sidebarView)
    let button = pill?.storeButton
    print("compat pill url=\(url) loaded=\(loaded) offer=\(String(describing: h.rt.extensions.ui.storeOffer)) pill=\(pill != nil) button=\(button?.label.stringValue ?? "none") frame=\(button?.frame ?? .zero)")
    if let w = h.rt.webviews.record(tab)?.webView {
      let inPage = await Wait.asyncJS(w, "return document.getElementById('den-add')?.textContent || 'none'", world: ExtensionsService.storeWorld)
      let banner = await Wait.js(w, "[...document.querySelectorAll('button, a')].map(b => (b.textContent||'').trim()).filter(t => /chrome/i.test(t)).slice(0, 6).join(' | ')")
      let ua = await Wait.js(w, "navigator.userAgent")
      print("compat store page: den-add=\(String(describing: inPage)) chromeButtons=\(String(describing: banner)) ua=\(String(describing: ua))")
    }
    #expect(offered && button != nil)
    let dir = FileManager.default.currentDirectoryPath + "/build/ci-logs"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    pill?.forceAccessories = true
    let snapped = await Snapshotter.write(h.rt.window.window, to: dir + "/add-to-den-pill.png")
    print("compat snapshot add-to-den-pill.png ok=\(snapped)")
    guard let button else { return nil }
    let before = h.events.count
    button.action()
    var accepted = false
    _ = await wait(120) {
      if !accepted, let p = h.rt.extensions.prompts.first {
        h.action(p.id, "button", ["button": "ok"])
        accepted = true
      }
      return h.events[before...].contains { $0.0 == "webext.installed" || $0.0 == "webext.failed" }
    }
    let ev = h.events[before...].first { $0.0 == "webext.installed" || $0.0 == "webext.failed" }
    print("compat pill install accepted=\(accepted) event=\(ev.map { "\($0.0) \($0.1)" } ?? "none")")
    #expect(await wait(10) { h.rt.extensions.ui.storeOffer == nil && Self.pill(h.rt.ui.sidebarView)?.storeButton == nil })
    guard let ev, ev.0 == "webext.installed" else { return nil }
    return ev.1.s("id")
  }

  @Test func vimiumFromChromeWebStore() async throws {
    let mock = MockServices()
    try mock.start()
    defer { mock.stop() }
    mock.page("/links", Self.linksPage)
    let h = Harness()
    h.startTabs()
    h.record(["webext.installed", "webext.failed", "webviews.newWindow"])
    var viaPill = await installFromPill(h, url: "https://chromewebstore.google.com/detail/vimium/\(Self.vimium)", storeId: Self.vimium)
    if viaPill == nil { viaPill = await install(h, source: "chrome", id: Self.vimium) }
    let id = try #require(viaPill)
    await report(h, id)
    _ = await probe(h, id, page: "pages/options.html", Self.apiProbe)
    let ok = await vimiumOnPage(h, id, mock: mock)
    #expect(ok["content script"] == true && ok["f link hints"] == true && ok["j scroll down"] == true)
  }

  @Test func vimiumFromFirefoxAddons() async throws {
    let mock = MockServices()
    try mock.start()
    defer { mock.stop() }
    mock.page("/links", Self.linksPage)
    let h = Harness()
    h.startTabs()
    h.record(["webext.installed", "webext.failed", "webviews.newWindow"])
    let id = try #require(await install(h, source: "firefox", id: "vimium-ff"))
    await report(h, id)
    _ = await probe(h, id, page: "pages/options.html", Self.apiProbe)
    let ok = await vimiumOnPage(h, id, mock: mock)
    #expect(ok["content script"] == true && ok["f link hints"] == true && ok["j scroll down"] == true)
  }

  @Test func otherPopularExtensions() async throws {
    let mock = MockServices()
    try mock.start()
    defer { mock.stop() }
    mock.page("/data.json", #"{"name": "den", "list": [1, 2, 3], "nested": {"ok": true}}"#, type: "application/json")
    let h = Harness()
    h.startTabs()
    h.record(["webext.installed", "webext.failed", "webviews.newWindow"])
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
