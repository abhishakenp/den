import AppKit
import CordisValue
import WebKit

/// `--scenario extensionsVerify`: installs real extensions through the real code path (store page,
/// injected "Add to den" button, download, permission dialog, WebKit load) and checks them.
/// Needs `--demo` (the tabs and extensions plugins) and the network. Prints `ext.verify …` lines,
/// writes snapshots to `$DEN_SNAPSHOT_DIR` (default: the current directory), then exits.
///
///   1. A test page on 127.0.0.1 loads well-known ad/tracker scripts: all load (baseline).
///   2. uBlock Origin Lite from the Chrome Web Store; the same page again: the requests are blocked.
///   3. ColorPick Eyedropper (Chrome Web Store) and its popup.
///   4. Dark Reader from Firefox Add-ons; its content script darkens the test page.
///   5. The extensions menu and the Extensions page.
@MainActor
public enum ExtensionScenarios {
  public static let names = ["extensionsVerify", "extensionsBlockCheck"]
  static let ublock = "ddkjiahejlhfcafbddmgiahcphecmpfh"
  static let colorPick = "ohcpnigalekghcmgcdcenkpelffpdolg"
  /// Scripts every mainstream filter list blocks (EasyList / EasyPrivacy / Peter Lowe's list).
  static let adScripts = [
    "https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js",
    "https://securepubads.g.doubleclick.net/tag/js/gpt.js",
    "https://www.google-analytics.com/analytics.js",
  ]

  public static func apply(_ name: String, runtime rt: DenRuntime) {
    if name == "extensionsBlockCheck" { Task { @MainActor in await blockCheck(rt) } }
    guard name == "extensionsVerify" else { return }
    Task { @MainActor in await verify(rt) }
  }

  /// `--scenario extensionsBlockCheck` on a store that already has extensions: loads the ad test
  /// page every 5 s for up to 3 minutes and prints what loaded (how long blockers take to apply).
  static func blockCheck(_ rt: DenRuntime) async {
    let mock = MockServices()
    try? mock.start()
    var page = "<!doctype html><title>Ad test</title><script>window.__results={};window.__done=0;</script>"
    for s in adScripts {
      page += "<script src='\(s)' onload=\"__results['\(s)']='loaded';__done++\" onerror=\"__results['\(s)']='blocked';__done++\"></script>"
    }
    mock.page("/adtest", page)
    guard await wait(10, { rt.call("tabs", "selected")["id"].string != nil }) else { exit(1) }
    tab = rt.call("tabs", "open", ["url": .string(mock.base + "/adtest")]).str("id")
    rt.call("tabs", "select", ["id": .string(tab)])
    let t0 = Date()
    while Date().timeIntervalSince(t0) < 180 {
      let r = await adResults(rt, mock.base)
      log(String(format: "t=%.0fs ", Date().timeIntervalSince(t0)) + adScripts.map { "\(URL(string: $0)!.host!)=\(r[$0] ?? "?")" }.joined(separator: " ") + " loaded=\(rt.extensions.contexts.keys.sorted())")
      if !r.isEmpty, adScripts.allSatisfy({ r[$0] == "blocked" }) { log("result blocked"); exit(0) }
      try? await Task.sleep(for: .seconds(5))
    }
    log("result notBlocked")
    exit(1)
  }

  static func log(_ s: String) { print("ext.verify " + s) }

  static func wait(_ seconds: Double, _ cond: () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
      if await cond() { return true }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return await cond()
  }

  static func snap(_ rt: DenRuntime, _ file: String) async {
    let dir = ProcessInfo.processInfo.environment["DEN_SNAPSHOT_DIR"] ?? FileManager.default.currentDirectoryPath
    let path = (dir as NSString).appendingPathComponent(file)
    // A key window draws active controls (switches, traffic lights).
    NSApp.activate()
    rt.window.window.makeKeyAndOrderFront(nil)
    try? await Task.sleep(for: .milliseconds(400))
    let ok = await Snapshotter.write(rt.window.window, to: path)
    log("snapshot \(file) ok=\(ok)")
  }

  static func eval(_ w: WKWebView?, _ js: String, world: WKContentWorld = .page) async -> Any? {
    guard let w else { return nil }
    return try? await w.evaluateJavaScript(js, contentWorld: world)
  }

  static var tab = ""
  static func web(_ rt: DenRuntime) -> WKWebView? { rt.webviews.record(tab)?.webView }

  static func navigate(_ rt: DenRuntime, _ url: String) async -> Bool {
    rt.call("tabs", "navigate", ["id": .string(tab), "url": .string(url)])
    try? await Task.sleep(for: .milliseconds(300))
    return await wait(30) { rt.webviews.record(tab)?.loading == false && rt.webviews.record(tab)?.url.hasPrefix(String(url.prefix(20))) == true }
  }

  /// Opens a store page, waits for den's button, clicks it, accepts the dialog, waits for the install.
  static func installFromStorePage(_ rt: DenRuntime, _ url: String, id: String, snapshot: String?, promptSnapshot: String?) async -> Bool {
    let t0 = Date()
    guard await navigate(rt, url) else { log("store page did not load: \(url)"); return false }
    let world = ExtensionsService.storeWorld
    let found = await wait(30) { (await eval(web(rt), "document.getElementById('den-add')?.textContent || ''", world: world) as? String ?? "").contains("Add to den") }
    let label = await eval(web(rt), "document.getElementById('den-add')?.textContent || 'none'", world: world) as? String ?? "?"
    let hidden = await eval(web(rt), "document.querySelectorAll('[data-den-hidden]').length", world: world) as? Int ?? -1
    log("store button url=\(url) found=\(found) label=\(label) nativeHidden=\(hidden)")
    guard found else { return false }
    if let snapshot {
      _ = await eval(web(rt), "document.getElementById('den-add').scrollIntoView({block: 'center'})", world: world)
      await snap(rt, snapshot)
    }
    _ = await eval(web(rt), "document.getElementById('den-add').click(); 'clicked'", world: world)
    let prompted = await wait(90) { !rt.extensions.prompts.isEmpty }
    log("prompt shown=\(prompted) title=\(rt.ui.dialog.title.stringValue) message=\(rt.ui.dialog.message.stringValue.replacingOccurrences(of: "\n", with: " | "))")
    guard prompted, let p = rt.extensions.prompts.first else { return false }
    if let promptSnapshot { await snap(rt, promptSnapshot) }
    rt.plugins.emit("ui.action", ["id": .string(p.id), "action": "button", "value": ["button": "ok"]])
    let ok = await wait(60) { rt.extensions.contexts.keys.contains { $0 == id || rt.extensions.registry.item($0)?.storeId == id } }
    let label2 = await eval(web(rt), "document.getElementById('den-add')?.textContent || 'none'", world: world) as? String ?? "?"
    log("installed id=\(id) ok=\(ok) in \(Int(Date().timeIntervalSince(t0) * 1000)) ms (page load + download + unpack + prompt + load); button now=\(label2)")
    return ok
  }

  /// Loads the ad test page and reports which ad/tracker scripts loaded or failed.
  static func adResults(_ rt: DenRuntime, _ base: String) async -> [String: String] {
    guard await navigate(rt, base + "/adtest") else { return [:] }
    _ = await wait(20) { (await eval(web(rt), "window.__done === \(adScripts.count)") as? Bool) == true }
    let r = await eval(web(rt), "JSON.stringify(window.__results || {})") as? String ?? "{}"
    return (try? JSONSerialization.jsonObject(with: Data(r.utf8)) as? [String: String]) ?? [:]
  }

  static func verify(_ rt: DenRuntime) async {
    let mock = MockServices()
    do { try mock.start() } catch { log("mock server failed: \(error)"); exit(1) }
    var page = "<!doctype html><title>Ad test</title><body style='font:15px -apple-system;padding:40px'><h2>den extension test page</h2><p id=p>Ad and tracker scripts:</p><script>window.__results={};window.__done=0;</script>"
    for s in adScripts {
      page += "<script src='\(s)' onload=\"__results['\(s)']='loaded';__done++\" onerror=\"__results['\(s)']='blocked';__done++\"></script>"
    }
    mock.page("/adtest", page)
    mock.page("/plain", "<!doctype html><title>Plain page</title><body style='background:#fff;color:#111;font:15px -apple-system;padding:40px'><h1>den</h1><p>A plain white page for Dark Reader.</p></body>")

    guard await wait(10, { rt.call("tabs", "selected")["id"].string != nil }) else { log("no tabs plugin"); exit(1) }
    tab = rt.call("tabs", "open", ["url": .string(mock.base + "/plain")]).str("id")
    rt.call("tabs", "select", ["id": .string(tab)])
    _ = await wait(15) { rt.webviews.record(tab)?.loading == false }
    log("controller before install=\(rt.extensions.controller != nil)")

    let before = await adResults(rt, mock.base)
    log("baseline " + adScripts.map { "\(URL(string: $0)!.host!)=\(before[$0] ?? "?")" }.joined(separator: " "))

    // 1. uBlock Origin Lite
    var okAll = await installFromStorePage(rt, "https://chromewebstore.google.com/detail/ublock-origin-lite/\(ublock)", id: ublock,
                                           snapshot: "extensions-add-to-den.png", promptSnapshot: "extensions-permission-prompt.png")
    // WebKit compiles the declarativeNetRequest rulesets into content rule lists in the
    // background after the load, so blocking starts some seconds later: poll for up to 3 minutes.
    var blockedAll = false
    let installedAt = Date()
    while !blockedAll, Date().timeIntervalSince(installedAt) < 180 {
      let after = await adResults(rt, mock.base)
      let line = adScripts.map { "\(URL(string: $0)!.host!)=\(after[$0] ?? "?")" }.joined(separator: " ")
      blockedAll = !after.isEmpty && adScripts.allSatisfy { after[$0] == "blocked" }
      log(String(format: "with uBOL t=%.0fs ", Date().timeIntervalSince(installedAt)) + line)
      if !blockedAll { try? await Task.sleep(for: .seconds(3)) }
    }
    log(String(format: "ublock blocksAds=%@ afterSeconds=%.0f baselineLoaded=%@", "\(blockedAll)", Date().timeIntervalSince(installedAt), "\(adScripts.allSatisfy { before[$0] == "loaded" })"))
    okAll = okAll && blockedAll

    // 2. A popup extension
    let cp = await installFromStorePage(rt, "https://chromewebstore.google.com/detail/colorpick-eyedropper/\(colorPick)", id: colorPick, snapshot: nil, promptSnapshot: nil)
    okAll = okAll && cp
    _ = await navigate(rt, mock.base + "/plain")
    if cp {
      rt.call("extensions", "action", ["id": .string(colorPick)])
      let shown = await wait(15) { rt.extensions.ui.popupFor == colorPick }
      try? await Task.sleep(for: .seconds(2))
      let title = await eval(rt.extensions.ui.popupWebForTesting, "document.title") as? String ?? "?"
      log("popup shown=\(shown) size=\(rt.extensions.ui.popupSizeForTesting) title=\(title)")
      await snap(rt, "extensions-popup.png")
      rt.call("extensions", "closePopup")
      okAll = okAll && shown
    }

    // 3. Firefox add-on
    let dr = await installFromStorePage(rt, "https://addons.mozilla.org/en-US/firefox/addon/darkreader/", id: "darkreader", snapshot: "extensions-add-to-den-amo.png", promptSnapshot: nil)
    var darkened = false
    if dr {
      for _ in 1...10 where !darkened {
        _ = await navigate(rt, mock.base + "/plain")
        darkened = await wait(4) { (await eval(web(rt), "document.querySelectorAll('.darkreader').length") as? Int ?? 0) > 0 }
      }
      let bg = await eval(web(rt), "getComputedStyle(document.body).backgroundColor") as? String ?? "?"
      log("darkreader darkened=\(darkened) bodyBackground=\(bg)")
      await snap(rt, "extensions-firefox-darkreader.png")
    }
    okAll = okAll && dr && darkened

    // 4. Menu and page
    if let pill = find(rt.ui.sidebarView) {
      pill.forceAccessories = true
      pill.layoutSubtreeIfNeeded()
    }
    rt.call("extensions", "menu", ["open": true])
    try? await Task.sleep(for: .milliseconds(600))
    log("menu open=\(rt.extensions.ui.menuOpen) items=\(rt.extensions.ui.items.map(\.title))")
    await snap(rt, "extensions-menu.png")
    rt.call("extensions", "menu", ["open": false])
    find(rt.ui.sidebarView)?.forceAccessories = false
    rt.plugins.emit("extensions.openPage")
    _ = await wait(5) { rt.ui.sheets["overlay.extensions"] != nil }
    await snap(rt, "extensions-page.png")
    rt.plugins.emit("ui.action", ["id": .string("extensions.row:" + ublock), "action": "open"])
    await snap(rt, "extensions-details.png")
    rt.plugins.emit("ui.action", ["id": "extensions", "action": "dismiss"])

    let list = rt.call("extensions", "list").array ?? []
    for e in list {
      log("list \(e.str("name")) v\(e.str("version")) source=\(e.str("source")) mv=\(e["manifestVersion"].int ?? 0) background=\(e.str("background")) loaded=\(e.flag("loaded")) popup=\(e.flag("hasPopup")) unsupported=\(e.list("unsupported").compactMap(\.string)) errors=\(e.list("errors").compactMap(\.string))")
    }
    log("result ok=\(okAll)")
    mock.stop()
    exit(okAll ? 0 : 1)
  }

  static func find(_ v: NSView) -> URLPillNode? {
    if let p = v as? URLPillNode { return p }
    for s in v.subviews { if let p = find(s) { return p } }
    return nil
  }
}
