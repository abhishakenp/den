import AppKit
import CordisValue
import WebKit

/// `--scenario discard`: a tab is discarded and restored through the real code paths, on local
/// pages (MockServices, no network). One line per check (`scenario.discard <name> ok=…`), then
/// `scenario.done ok=…`, and den exits 0 or 1 (unless `--stay`).
///
/// 1. A tab navigates page 1 → page 2 and scrolls; another tab holds unsaved form input.
/// 2. Both leave the screen. An idle discard (`webviews.suspend` without force) frees the first
///    (its snapshot is on disk, small) and refuses the second (`reason: form`).
/// 3. Selecting the first again shows its snapshot at once, then the restored page: same URL,
///    back list and scroll position.
@MainActor
public enum DiscardScenarios {
  public static let names = ["discard"]

  static func pageHTML(_ n: Int) -> String {
    let paras = (1...60).map { "<p>Paragraph \($0) of page \(n). den keeps only this page's URL, history and a small snapshot on disk once it is discarded.</p>" }.joined()
    return "<!doctype html><title>Long page \(n)</title><body style='font:16px -apple-system;padding:40px 60px;background:#f7f5ff'><h1>Long page \(n)</h1>\(paras)</body>"
  }

  public static func apply(_ name: String, runtime rt: DenRuntime) {
    Task { @MainActor in await run(rt) }
  }

  static func run(_ rt: DenRuntime) async {
    let mock = MockServices()
    try? mock.start()
    mock.files = [
      "/1.html": ("text/html; charset=utf-8", Data(pageHTML(1).utf8)), "/2.html": ("text/html; charset=utf-8", Data(pageHTML(2).utf8)),
      "/form.html": ("text/html; charset=utf-8", Data("<!doctype html><title>Draft</title><body style='font:16px -apple-system;padding:40px'><h1>Compose</h1><form><textarea name=t rows=6 cols=60></textarea></form></body>".utf8)),
    ]
    var allOK = true
    func check(_ what: String, _ ok: Bool, _ detail: String = "") {
      allOK = allOK && ok
      print("scenario.discard \(what) ok=\(ok)\(detail.isEmpty ? "" : " " + detail)")
    }
    func js(_ id: String, _ s: String) async -> Value { await MediaScenarios.js(rt, id, s) }
    func loaded(_ id: String) async -> Bool { await MediaScenarios.until(15) { rt.webviews.record(id)?.webView.map { !$0.isLoading && $0.url != nil } ?? false } }

    let other = rt.call("tabs", "selected")["id"].string ?? ""
    let id = rt.call("tabs", "open", ["url": .string(mock.base + "/1.html")])["id"].string ?? ""
    _ = await loaded(id)
    rt.call("webviews", "navigate", ["id": .string(id), "url": .string(mock.base + "/2.html")])
    await MediaScenarios.sleep(0.3)
    _ = await loaded(id)
    let scrolled = await js(id, "window.scrollTo(0, 1500); return window.scrollY").double ?? -1
    let form = rt.call("tabs", "open", ["url": .string(mock.base + "/form.html")])["id"].string ?? ""
    _ = await loaded(form)
    _ = await js(form, "const t = document.querySelector('textarea'); t.focus(); t.value = 'An unsent draft'; t.dispatchEvent(new Event('input', {bubbles: true})); return true")
    await MediaScenarios.sleep(0.3)
    let t0 = Date()
    rt.call("tabs", "select", ["id": .string(other)])
    check("switch", true, String(format: "ms=%.1f", Date().timeIntervalSince(t0) * 1000))
    _ = await MediaScenarios.until(6) { rt.webviews.record(id)?.snapshotPath != nil }

    // 2. Idle discard.
    let path = rt.webviews.record(id)?.snapshotPath ?? ""
    let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    let px = rt.webviews.storedSnapshot(id).map { "\($0.width)x\($0.height)" } ?? "-"
    check("snapshot.onDisk", bytes > 0, "bytes=\(bytes) px=\(px)")
    let stateBytes = (rt.webviews.record(id)?.webView?.interactionState as? Data)?.count ?? -1
    let r1 = rt.call("webviews", "suspend", ["id": .string(id)])
    check("discard.idle", r1["suspended"] == true && rt.webviews.record(id)?.webView == nil, "interactionStateBytes=\(stateBytes)")
    let r2 = rt.call("webviews", "suspend", ["id": .string(form)])
    check("discard.keepsForm", r2["suspended"] == false && r2["reason"] == "form", "reason=\(r2.str("reason"))")
    let r3 = rt.call("webviews", "suspend", ["id": .string(other)])
    check("discard.keepsVisible", r3["reason"] == "visible")
    check("record.metadataOnly", rt.webviews.record(id)?.isSuspended == true && rt.webviews.record(id)?.webView == nil)

    // 3. Restore.
    var finished: Date?
    let prev = rt.webviews.onFinish
    rt.webviews.onFinish = { fid in prev?(fid); if fid == id, finished == nil { finished = Date() } }
    let tr = Date()
    rt.call("tabs", "select", ["id": .string(id)])
    let showMs = Date().timeIntervalSince(tr) * 1000
    check("restore.coverAtOnce", rt.content.isCovered(id), String(format: "selectMs=%.1f", showMs))
    _ = await MediaScenarios.until(10) { finished != nil }
    check("restore.loaded", finished != nil, String(format: "loadMs=%.0f", (finished ?? Date()).timeIntervalSince(tr) * 1000))
    _ = await MediaScenarios.until(3) { !rt.content.isCovered(id) }
    check("restore.coverGone", !rt.content.isCovered(id))
    let w = rt.webviews.record(id)?.webView
    check("restore.url", w?.url?.absoluteString == mock.base + "/2.html", w?.url?.absoluteString ?? "-")
    check("restore.history", w?.canGoBack == true)
    await MediaScenarios.sleep(0.5)
    let y = await js(id, "return window.scrollY").double ?? -1
    check("restore.scroll", scrolled > 500 && abs(y - scrolled) < 2, "before=\(scrolled) after=\(y)")
    print("scenario.done ok=\(allOK)")
    if !CommandLine.arguments.contains("--stay") { exit(allOK ? 0 : 1) }
  }
}
