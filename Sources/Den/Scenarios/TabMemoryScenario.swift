import AppKit
import CordisValue
import DenHost
import WebKit

/// `--scenario realtabs --url "<url> <url>…"`: background-tab memory and tab-return latency on
/// real sites (scripts/measure-tabs.sh). Every tab already in the store closes; each URL ("a>b":
/// a, then a link to b in the same tab) then
/// opens and stays on screen `DEN_DWELL` s (default 8), as if browsed, and the first one is shown
/// again: `scenario.ready live=<n>`. Then, whenever `<storage>/return.now` appears, every other
/// tab is shown in turn (3 s apart), one line each:
///   `scenario.return url=<url> live=<was live> snapshot_ms=<its snapshot placed over the page (a
///    restore; -1: none)> presented_ms=<view on screen and drawn>
///    painted_ms=<the page itself painted> `
/// and `scenario.returnDone` once they all came back.
@MainActor
final class TabMemoryScenario {
  let rt: DenRuntime
  let urls: [String]
  let storage: URL
  var ids: [String] = []

  init(rt: DenRuntime, urls: [String], storage: URL) {
    self.rt = rt
    self.urls = urls.filter { !$0.isEmpty }
    self.storage = storage
  }

  func start() {
    // The window is parked off every display (--background), so occluded: the tab on screen would
    // run as hidden. Its pages skip occlusion detection, as under tests, to run as on screen.
    rt.webviews.createdHooks.append { _, w in
      let sel = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
      guard w.responds(to: sel) else { return }
      typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
      unsafeBitCast(w.method(for: sel), to: Setter.self)(w, sel, false)
    }
    for sp in rt.call("spaces", "list").array ?? [] {
      let l = rt.call("tabs", "list", ["spaceId": sp["id"]])
      func walk(_ items: [Value]) { for i in items { if i.flag("folder") { walk(i.list("children")) } else { ids.append(i.str("id")) } } }
      walk(l.list("pinned")); walk(l.list("today")); walk(l.list("favorites"))
    }
    for id in ids { rt.call("tabs", "close", ["id": .string(id)]) }
    ids = []
    let dwell = Double(ProcessInfo.processInfo.environment["DEN_DWELL"] ?? "") ?? 8
    for (i, u) in urls.enumerated() {
      // "a>b": the tab opens a, then follows a link to b halfway through its dwell (so a waits
      // in the back/forward cache, as after any click to another site).
      let hops = u.split(separator: ">").map(String.init)
      DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(i) * dwell) { [self] in
        let id = rt.call("tabs", "open", ["url": .string(hops[0])])["id"]
        rt.call("tabs", "select", ["id": id])
        ids.append(id.string ?? "")
        guard hops.count > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + dwell / 2) { [self] in
          rt.webviews.record(id.string ?? "")?.webView?.load(URLRequest(url: URL(string: hops[1])!))
        }
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(urls.count) * dwell) { [self] in
      rt.call("tabs", "select", ["id": .string(ids[0])])
      print("scenario.ready live=\(liveCount()) \(pids())")
      print("scenario.pool \(poolInfo())")
      fflush(stdout)
      waitForReturn()
    }
  }

  /// Each tab's WebContent process: `url=pid` (pid 0: discarded).
  func pids() -> String {
    ids.map { id in
      let r = rt.webviews.record(id)
      let pid = (r?.webView?.value(forKey: "_webProcessIdentifier") as? NSNumber)?.intValue ?? 0
      return "\(r?.url ?? id)=\(pid)"
    }.joined(separator: " ")
  }

  /// WebKit's own process counts (WKProcessPool SPI, read only), to tell a page's process from a
  /// prewarmed, cached or service worker one.
  func poolInfo() -> String {
    guard let pool = ids.lazy.compactMap({ self.rt.webviews.record($0)?.webView }).first?.configuration.processPool else { return "no live page" }
    return ["_webProcessCount", "_webProcessCountIgnoringPrewarmed", "_webProcessCountIgnoringPrewarmedAndCached",
            "_processCacheSize", "_serviceWorkerProcessCount", "_hasPrewarmedWebProcess", "_webPageContentProcessCount"].map { k in
      let sel = NSSelectorFromString(k)
      guard pool.responds(to: sel) else { return k + "=?" }
      return k + "=" + String(describing: pool.value(forKey: k) ?? "nil")
    }.joined(separator: " ")
  }

  func liveCount() -> Int { ids.filter { rt.webviews.record($0)?.webView != nil }.count }

  func waitForReturn() {
    let flag = storage.appendingPathComponent("return.now").path
    if FileManager.default.fileExists(atPath: flag) {
      try? FileManager.default.removeItem(atPath: flag)
      // DEN_DISCARD=1: every background tab is discarded first (an idle discard: what must stay,
      // stays), so the return times are a restore's; they start 12 s later (measured meanwhile).
      if ProcessInfo.processInfo.environment["DEN_DISCARD"] == "1" {
        for id in ids.dropFirst() { rt.call("webviews", "suspend", ["id": .string(id)]) }
      }
      print("scenario.beforeReturn live=\(liveCount()) \(pids())")
      print("scenario.pool \(poolInfo())")
      for d in [2.0, 5, 10] { DispatchQueue.main.asyncAfter(deadline: .now() + d) { [self] in print("scenario.pool +\(d)s \(poolInfo())"); fflush(stdout) } }
      let discard = ProcessInfo.processInfo.environment["DEN_DISCARD"] == "1"
      DispatchQueue.main.asyncAfter(deadline: .now() + (discard ? 12 : 0)) { [self] in returnTo(Array(ids.dropFirst())) }
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in waitForReturn() }
  }

  /// Shows each tab and times it: `presented` once its web view is in the window and WebKit has
  /// committed a frame of it, `painted` once the page itself has painted (for a page that stayed
  /// live, both are the same moment; a discarded one shows its snapshot until it paints).
  func returnTo(_ rest: [String]) {
    guard let id = rest.first else {
      rt.call("tabs", "select", ["id": .string(ids[0])])
      print("scenario.returnDone live=\(liveCount()) \(pids())")
      print("scenario.pool \(poolInfo())")
      fflush(stdout)
      return
    }
    let wasLive = rt.webviews.record(id)?.webView != nil
    let url = rt.webviews.record(id)?.url ?? ""
    let t0 = CACurrentMediaTime()
    rt.call("tabs", "select", ["id": .string(id)])
    var presented: Double?
    var covered: Double?
    var asked = false
    func ms() -> Double { ((CACurrentMediaTime() - t0) * 10_000).rounded() / 10 }
    func poll() {
      let r = rt.webviews.record(id)
      if covered == nil, rt.content.isCovered(id) { covered = ms() }
      if !asked, let w = r?.webView, w.window != nil {
        asked = true
        let sel = NSSelectorFromString("_doAfterNextPresentationUpdate:")
        if w.responds(to: sel) {
          let done: @convention(block) () -> Void = { presented = ms() }
          w.perform(sel, with: done)
        } else {
          presented = ms()
        }
      }
      if let p = presented, r?.painted == true || ms() > 15_000 {
        print("scenario.return url=\(url) live=\(wasLive) snapshot_ms=\(covered ?? -1) presented_ms=\(p) painted_ms=\(r?.painted == true ? ms() : -1)")
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in returnTo(Array(rest.dropFirst())) }
        return
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.002) { poll() }
    }
    poll()
  }
}
