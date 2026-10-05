// Dev fixture: compiled only with the `Scenarios` package trait (on by default; release bundles leave it out).
#if Scenarios
import AppKit
import CordisValue
import WebKit

/// `--scenario extensionAPIs` (needs `--demo` and the network): real Chrome Web Store extensions
/// that use the APIs den answers itself (ExtensionAPIs), installed through den's real path, then
/// checked in their own UI and context. Prints `ext.apis …` lines (`result ok=…` last) and exits.
///
///   - Bookmark Sidebar (bookmarks, sidePanel): its side panel in den's panel column lists den's
///     Favorites and pinned tabs.
///   - History Trends Unlimited (history): its background starts; history.search sees a page a
///     tab just visited.
///   - Chrono Download Manager (downloads, downloads.open, downloads.ui): a download a page starts
///     shows in its popup's list.
///   - Image Downloader (downloads, sidePanel): its side panel opens; chrome.downloads.download
///     from its context saves a file.
///   - Grammarly (identity, sidePanel): its background starts; identity.getRedirectURL is its
///     chromiumapp.org URL.
@MainActor
public enum ExtensionAPIScenarios {
  public static let names = ["extensionAPIs"]
  static let bookmarkSidebar = "jdbnofccmhefkmjbkkdkfiicjkgofkdh"
  static let historyTrends = "pnmchffiealhkdloeffcdnbgdnedheme"
  static let chrono = "mciiogijehkdemklbdcbfkefimifhecn"
  static let imageDownloader = "cnpniohnfphhjihaiiggeabnkjhpaldj"
  static let grammarly = "kbfnbcaeplbcioakkpcpgfkobkghlhen"

  public static func apply(_ name: String, runtime rt: DenRuntime) {
    Task { @MainActor in await run(rt) }
  }

  static func log(_ s: String) { print("ext.apis " + s) }
  static var failures = 0
  static func check(_ what: String, _ ok: Bool, _ detail: String = "") {
    if !ok { failures += 1 }
    log((ok ? "PASS " : "FAIL ") + what + (detail.isEmpty ? "" : " — " + detail))
  }

  static func wait(_ seconds: Double, _ cond: () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
      if await cond() { return true }
      try? await Task.sleep(for: .milliseconds(200))
    }
    return await cond()
  }

  static func install(_ rt: DenRuntime, _ id: String) async -> Bool {
    _ = rt.call("webext", "installFromStore", ["source": "chrome", "id": .string(id)])
    let ok = await wait(600) {
      if let p = rt.extensions.prompts.first {
        log("prompt \(id): \(rt.ui.dialog.message.stringValue.replacingOccurrences(of: "\n", with: " | "))")
        rt.plugins.emit("ui.action", ["id": .string(p.id), "action": "button", "value": ["button": "ok"]])
      }
      return rt.extensions.contexts[id]?.isLoaded == true
    }
    let d = rt.call("webext", "get", ["id": .string(id)])
    log("installed \(id) \(d.str("name")) ok=\(ok) unsupported=\(d.list("unsupported").compactMap(\.string)) errors=\(d.list("errors").compactMap(\.string))")
    return ok
  }

  /// Starts the background and reports what WebKit says.
  static func background(_ rt: DenRuntime, _ id: String) async -> String {
    guard let ctx = rt.extensions.contexts[id] else { return "not loaded" }
    var r = "pending"
    ctx.loadBackgroundContent { e in r = e.map { "error \($0.localizedDescription)" } ?? "ok" }
    _ = await wait(30) { r != "pending" }
    try? await Task.sleep(for: .seconds(2))
    let errs = ctx.errors.map(\.localizedDescription)
    return r + (errs.isEmpty ? "" : " errors=\(errs)")
  }

  /// A page of the extension's own (written into den's copy, with den's shim), for probes.
  static func probe(_ rt: DenRuntime, _ id: String, _ script: String) async -> String {
    _ = await wait(30) { rt.extensions.contexts[id]?.webViewConfiguration != nil }
    guard let ctx = rt.extensions.contexts[id], let cfg = ctx.webViewConfiguration, let e = rt.extensions.registry.item(id) else {
      return "no context (loaded=\(rt.extensions.contexts[id]?.isLoaded ?? false) registry=\(rt.extensions.registry.item(id) != nil) loadError=\(rt.extensions.loadErrors[id] ?? "none"))"
    }
    let dir = URL(fileURLWithPath: rt.extensions.registry.path(e))
    try? "<!doctype html><title>probe</title><script src='/__den/shim.js'></script>".write(to: dir.appendingPathComponent("__den_probe.html"), atomically: true, encoding: .utf8)
    let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: cfg)
    w.load(URLRequest(url: ctx.baseURL.appendingPathComponent("__den_probe.html")))
    _ = await wait(20) { !w.isLoading && w.url != nil }
    let r = try? await w.callAsyncJavaScript("try { return JSON.stringify(await (async () => { \(script) })()); } catch (e) { return 'thrown ' + e; }", arguments: [:], contentWorld: .page)
    w.stopLoading()
    return (r as? String) ?? "nil"
  }

  /// Loads one of the extension's pages with its errors captured: what threw, and how much it drew.
  static func pageErrors(_ rt: DenRuntime, _ id: String, _ path: String, settle: Double = 6) async -> String {
    guard let ctx = rt.extensions.contexts[id], let base = ctx.webViewConfiguration, let cfg = base.copy() as? WKWebViewConfiguration else { return "no context" }
    let ucc = WKUserContentController()
    ucc.addUserScript(WKUserScript(source: """
      (() => {
        window.__errs = [];
        addEventListener('error', (e) => __errs.push((e.filename || '').split('/').pop() + ':' + e.lineno + ' ' + e.message), true);
        addEventListener('unhandledrejection', (e) => __errs.push('rejection ' + String(e.reason) + ' ' + String(e.reason && e.reason.stack).slice(0, 300)));
        const original = console.error.bind(console);
        console.error = (...a) => { __errs.push('console ' + a.map(String).join(' ').slice(0, 300)); original(...a); };
      })();
      """, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    cfg.userContentController = ucc
    let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 700), configuration: cfg)
    w.load(URLRequest(url: ctx.baseURL.appendingPathComponent(path)))
    try? await Task.sleep(for: .seconds(settle))
    let r = (try? await w.evaluateJavaScript("JSON.stringify({errs: window.__errs, text: (document.body && document.body.innerText || '').slice(0, 200), html: document.documentElement.outerHTML.length, frames: document.querySelectorAll('iframe').length, body: document.documentElement.outerHTML.slice(0, 1500), shadow: [...document.querySelectorAll('*')].filter(e => e.shadowRoot).length})")) as? String
    w.stopLoading()
    return r ?? "nil"
  }

  /// A background's scripts loaded one by one in a page of the extension's: what throws.
  static func backgroundErrors(_ rt: DenRuntime, _ id: String) async -> String {
    guard let ctx = rt.extensions.contexts[id], let e = rt.extensions.registry.item(id) else { return "no context" }
    let bg = ctx.webExtension.manifest["background"] as? [String: Any] ?? [:]
    let files = (bg["service_worker"] as? String).map { [$0] } ?? (bg["scripts"] as? [String] ?? [])
    let dir = URL(fileURLWithPath: rt.extensions.registry.path(e))
    // A classic worker's wrapper importScripts its files: run them as ordered script tags.
    var scripts: [String] = []
    for f in files {
      if f.hasSuffix(ExtensionShim.workerName), let w = try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8) {
        scripts += w.components(separatedBy: "\"").filter { $0.hasPrefix("/") }
      } else { scripts.append("/" + f) }
    }
    let tags = scripts.map { "<script src='\($0)'></script>" }.joined()
    try? "<!doctype html><title>bg</title>\(tags)".write(to: dir.appendingPathComponent("__den_bg.html"), atomically: true, encoding: .utf8)
    return "scripts=\(scripts) " + (await pageErrors(rt, id, "__den_bg.html", settle: 8))
  }

  static func text(_ w: WKWebView?) async -> String {
    guard let w else { return "" }
    // Frames of the same extension too (Chrono's list is in one).
    return (try? await w.evaluateJavaScript("[document, ...[...document.querySelectorAll('iframe')].map(f => { try { return f.contentDocument; } catch (e) { return null; } })].filter(d => d && d.body).map(d => d.body.innerText).join(' | ')")) as? String ?? ""
  }

  static func run(_ rt: DenRuntime) async {
    let mock = MockServices()
    do { try mock.start() } catch { log("mock server failed: \(error)"); exit(1) }
    mock.page("/visit", "<!doctype html><title>den history probe</title><body>visited</body>")
    mock.files = ["/den-report.zip": ("application/zip", Data(repeating: 9, count: 120_000))]
    mock.page("/dl", "<!doctype html><title>download page</title><a id=a href='/den-report.zip' download>get</a>")
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("den-ext-apis-downloads-\(UUID())", isDirectory: true)
    rt.downloads.folder = { folder }
    guard await wait(15, { rt.call("tabs", "selected")["id"].string != nil }) else { log("no tabs plugin (needs --demo)"); exit(1) }
    let only = ProcessInfo.processInfo.environment["DEN_EXT_APIS"].map { Set($0.split(separator: ",").map(String.init)) }
    func want(_ id: String) -> Bool { only?.contains(id) ?? true }

    // Bookmark Sidebar: den's Favorites and pinned tabs in its side panel.
    if want(bookmarkSidebar), await install(rt, bookmarkSidebar) {
      log("bookmarkSidebar background=\(await background(rt, bookmarkSidebar))")
      let tree = await probe(rt, bookmarkSidebar, "const t = await chrome.bookmarks.getTree(); return t[0].children.map(c => c.title + ':' + (c.children || []).length);")
      check("bookmarks.getTree from Bookmark Sidebar's context", tree.contains("Favorites:") && tree.contains("Pinned:"), tree)
      let pinnedTitles = (rt.call("tabs", "list")["pinned"].array ?? []).filter { !$0.flag("folder") }.map { $0.str("title") }
      let favTitles = (rt.call("tabs", "list")["favorites"].array ?? []).map { $0.str("title") }
      if let ctx = rt.extensions.contexts[bookmarkSidebar] {
        let r = rt.extensions.apis.sidePanel.open(ctx, icon: rt.extensions.registry.iconPath(bookmarkSidebar))
        let panel = "panel-ext-" + bookmarkSidebar
        let shown = await wait(20) { rt.content.sideId == panel && rt.webviews.record(panel)?.webView != nil }
        check("Bookmark Sidebar's side panel opens in den's panel column", shown && !r.isError, "\(r) side=\(rt.content.sideId ?? "none")")
        let listed = await wait(30) {
          let t = await text(rt.webviews.record(panel)?.webView)
          return (favTitles + pinnedTitles).contains { !$0.isEmpty && t.contains($0) }
        }
        let t = await text(rt.webviews.record(panel)?.webView)
        check("its panel lists den's bookmarks (favorites/pinned titles)", listed, "favorites=\(favTitles.prefix(3)) pinned=\(pinnedTitles.prefix(3)) panel text=\(t.prefix(300).replacingOccurrences(of: "\n", with: " | "))")
        if !listed {
          log("bookmarkSidebar panel page: \(await pageErrors(rt, bookmarkSidebar, "html/sidepanel.html"))")
          log("bookmarkSidebar background scripts: \(await backgroundErrors(rt, bookmarkSidebar))")
        }
        _ = rt.extensions.apis.sidePanel.close(ctx)
      }
    }

    // History Trends Unlimited: history.search sees a visit.
    if want(historyTrends), await install(rt, historyTrends) {
      log("historyTrends background=\(await background(rt, historyTrends))")
      let tab = rt.call("tabs", "open", ["url": .string(mock.base + "/visit")]).str("id")
      rt.call("tabs", "select", ["id": .string(tab)])
      _ = await wait(20) { rt.webviews.record(tab)?.title == "den history probe" }
      try? await Task.sleep(for: .seconds(1))
      let found = await probe(rt, historyTrends, "return (await chrome.history.search({text: 'history probe', startTime: 0})).map(h => h.title + ' ' + h.visitCount);")
      check("history.search from History Trends' context finds the visit", found.contains("den history probe"), found)
      let all = await probe(rt, historyTrends, "return (await chrome.history.search({text: '', startTime: 0, maxResults: 0})).length;")
      log("historyTrends history items (visits + archive + open tabs) = \(all)")
    }

    // Chrono: a download a page starts is in its list.
    if want(chrono), await install(rt, chrono) {
      let cbg = await background(rt, chrono)
      log("chrono background=\(cbg)")
      if !cbg.hasPrefix("ok") { log("chrono background scripts: \(await backgroundErrors(rt, chrono))") }
      let tab = rt.call("tabs", "open", ["url": .string(mock.base + "/dl")]).str("id")
      rt.call("tabs", "select", ["id": .string(tab)])
      _ = await wait(20) { rt.webviews.record(tab)?.title == "download page" }
      _ = try? await rt.webviews.record(tab)?.webView?.evaluateJavaScript("document.getElementById('a').click()")
      let done = await wait(30) { rt.downloads.items.contains { $0.name.hasPrefix("den-report") && $0.state == "done" } }
      check("a page's download finishes in den", done, "\(rt.downloads.items.map { "\($0.name) \($0.state)" })")
      let seen = await probe(rt, chrono, "return (await chrome.downloads.search({query: ['den-report']})).map(d => d.filename + ' ' + d.state);")
      check("Chrono's context sees it (downloads.search)", seen.contains("den-report") && seen.contains("complete"), seen)
      // Its popup page, loaded like den's popover loads it.
      if let ctx = rt.extensions.contexts[chrono], let cfg = ctx.webViewConfiguration,
         let path = ((ctx.webExtension.manifest["action"] as? [String: Any])?["default_popup"] as? String) {
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 500), configuration: cfg)
        w.load(URLRequest(url: ctx.baseURL.appendingPathComponent(path)))
        let listed = await wait(30) { await text(w).contains("den-report") }
        let t = await text(w)
        check("Chrono's popup lists the download", listed, String(t.prefix(300)).replacingOccurrences(of: "\n", with: " | "))
        if !listed { log("chrono popup page: \(await pageErrors(rt, chrono, path, settle: 8))") }
        w.stopLoading()
      }
    }

    // Image Downloader: side panel and a download from its context.
    if want(imageDownloader), await install(rt, imageDownloader) {
      log("imageDownloader background=\(await background(rt, imageDownloader))")
      if let ctx = rt.extensions.contexts[imageDownloader] {
        let r = rt.extensions.apis.sidePanel.open(ctx, icon: rt.extensions.registry.iconPath(imageDownloader))
        let panel = "panel-ext-" + imageDownloader
        let loaded = await wait(20) { rt.webviews.record(panel)?.webView?.isLoading == false && !(rt.webviews.record(panel)?.title ?? "").isEmpty }
        let t = await text(rt.webviews.record(panel)?.webView)
        check("Image Downloader's side panel opens", loaded && !r.isError, "title=\(rt.webviews.record(panel)?.title ?? "") text=\(t.prefix(200).replacingOccurrences(of: "\n", with: " | "))")
        _ = rt.extensions.apis.sidePanel.close(ctx)
      }
      let before = rt.downloads.items.count
      let n = await probe(rt, imageDownloader, "return await chrome.downloads.download({url: '\(mock.base)/den-report.zip', filename: 'image-downloader/den.zip'});")
      let done = await wait(30) { rt.downloads.items.count > before && rt.downloads.items.first?.state == "done" }
      check("chrome.downloads.download from Image Downloader's context", done && FileManager.default.fileExists(atPath: folder.appendingPathComponent("image-downloader/den.zip").path), "id=\(n)")
    }

    // Grammarly: identity is there, its background starts.
    if want(grammarly), await install(rt, grammarly) {
      let bg = await background(rt, grammarly)
      log("grammarly background=\(bg)")
      check("Grammarly's background starts", bg.hasPrefix("ok"), bg)
      let r = await probe(rt, grammarly, "return [typeof chrome.identity.launchWebAuthFlow, chrome.identity.getRedirectURL()];")
      check("Grammarly sees identity (launchWebAuthFlow, getRedirectURL)", r.contains("function") && r.contains("\(grammarly).chromiumapp.org"), r)
    }

    log("wakes \(rt.extensions.apis.wakes)")
    log("result ok=\(failures == 0) failures=\(failures)")
    exit(failures == 0 ? 0 : 1)
  }
}
#endif
