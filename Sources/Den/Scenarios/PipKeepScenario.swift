import AppKit
import CordisValue
import DenHost
import WebKit

/// `--scenario pipkeep --url <page with a <video>>`: picture in picture must never be touched by
/// den's memory policy (idle unload, background-media pause). Opens the page, plays
/// its video (no sound needed: the page's own `muted` video), puts it in PiP as ⌥⌘P does
/// (`media.toggle`), then opens two more tabs so the video's tab is no longer one of the 2 most
/// recent (the idle discard may pick it). Every 10 s one line:
///   `scenario.pipkeep t=<s> pip=<in PiP> live=<web view alive> pid=<its WebContent> playing=<…>
///    time=<video currentTime> paused=<…>`
/// Commands, one per file write to `<storage>/cmd`: `activate` (den in front, so another app can
/// be switched to), `minimize`, `deminiaturize`, `select0`
/// (the video's tab), `select2` (the last tab), `quit`.
@MainActor
final class PipKeepScenario {
  let rt: DenRuntime
  let url: String
  let storage: URL
  var ids: [String] = []
  let t0 = Date()

  init(rt: DenRuntime, url: String, storage: URL) { (self.rt, self.url, self.storage) = (rt, url, storage) }

  func log(_ s: String) {
    print("scenario.pipkeep t=\(Int(Date().timeIntervalSince(t0))) " + s)
    fflush(stdout)
  }

  func start() {
    let id = rt.call("tabs", "open", ["url": .string(url)])["id"]
    rt.call("tabs", "select", ["id": id])
    ids.append(id.string ?? "")
    after(5) { [self] in
      rt.webviews.runPageScript(ids[0], "const v = document.querySelector('video'); await v.play(); return !v.paused") { [self] r in
        log("play \(r)")
        after(2) { [self] in
          log("toggle \(rt.call("media", "toggle", ["webview": .string(ids[0])]))")
          after(3) { [self] in
            for u in ["https://example.com/", "https://example.org/"] {
              let t = rt.call("tabs", "open", ["url": .string(u)])["id"]
              rt.call("tabs", "select", ["id": t])
              ids.append(t.string ?? "")
            }
            report()
            poll()
          }
        }
      }
    }
  }

  func after(_ s: Double, _ f: @escaping @MainActor () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { f() } }
  }

  func report() {
    let r = rt.webviews.record(ids[0])
    let pid = (r?.webView?.value(forKey: "_webProcessIdentifier") as? NSNumber)?.intValue ?? 0
    let st = rt.call("webviews", "get", ["id": .string(ids[0])])
    let head = "pip=\(rt.call("media", "get")["pip"]) live=\(st["live"]) pid=\(pid) playing=\(st["media"]["playing"]) idle=\(rt.call("app", "state")["idleSeconds"]) suspendAfterMs=\(rt.call("tabs", "energy")["suspendAfterMs"]) saving=\(rt.call("tabs", "energy")["saving"])"
    guard r?.webView != nil else { return log(head + " time=- paused=-") }
    rt.webviews.runPageScript(ids[0], "const v = document.querySelector('video'); return v.currentTime.toFixed(1) + ' paused=' + v.paused") { [self] res in
      if case .success(let v) = res { log(head + " time=\(v)") } else { log(head + " time=? \(res)") }
    }
  }

  func poll() {
    let f = storage.appendingPathComponent("cmd")
    if let c = try? String(contentsOf: f, encoding: .utf8) {
      try? FileManager.default.removeItem(at: f)
      let cmd = c.trimmingCharacters(in: .whitespacesAndNewlines)
      log("cmd \(cmd)")
      switch cmd {
      case "minimize": rt.window.window.miniaturize(nil)
      case "deminiaturize": rt.window.window.deminiaturize(nil)
      case "select0": rt.call("tabs", "select", ["id": .string(ids[0])])
      case "select2": rt.call("tabs", "select", ["id": .string(ids[2])])
      case "activate": NSApp.activate(ignoringOtherApps: true)
      case "quit": exit(0)
      default: break
      }
      report()
    }
    if Int(Date().timeIntervalSince(t0)) % 10 == 0 { report() }
    after(1) { [self] in poll() }
  }
}
