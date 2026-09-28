// Dev fixture: compiled only with the `Scenarios` package trait (on by default; release bundles leave it out).
#if Scenarios
// thin-host: feature-specific, migrate to plugin (snapshot scenarios that drive the `pagetools`
// plugin; the feature itself lives in Plugins/pagetools).
import AppKit
import CordisValue
import WebKit

/// `--scenario` runs of the `pagetools` plugin on real pages (network needed), for snapshots and
/// checks: each prints `scenario.pagetools <name> …` lines with what it observed.
///
/// - `readerButton`: a Wikipedia article loads; the URL pill shows the Reader button.
/// - `reader` / `readAloud`: the reader over that article; read aloud (muted) highlights the sentence.
/// - `translate` / `translateJa`: a French / Japanese Wikipedia page translated on device.
/// - `captureRegion`: the capture picker over example.com. `captureFull`: MDN's full page saved
///   to a temporary folder (the toast shows).
/// - `zap` / `unstick`: MDN with the Zap panel after hiding an element / Remove Sticky Headers.
/// - `highlightLink`: "Copy Link to Highlight" on the article, then that link opened in a new tab
///   (WebKit scrolls to and marks the text). Like the command, it copies the link.
/// - `qrCode`: "QR Code for This Page" over example.com (the popover beside the URL pill).
/// - `copyToast`: ⇧⌘C on example.com; the toast names what was copied (it copies the link).
@MainActor
public enum PageToolsScenarios {
  public static let names = ["readerButton", "reader", "readAloud", "translate", "translateJa", "captureRegion", "captureFull", "zap", "unstick", "highlightLink", "qrCode", "copyToast"]
  static let article = "https://en.wikipedia.org/wiki/Arc_(web_browser)"
  static let sticky = "https://developer.mozilla.org/en-US/docs/Web/CSS/position"

  public static func apply(_ name: String, runtime rt: DenRuntime) -> Bool {
    guard names.contains(name) else { return false }
    guard rt.plugins.serviceNames.contains("tabs") else {
      print("scenario.pagetools \(name) needs the bundled plugins")
      return true
    }
    rt.speech.volumeOverride = 0
    func run(_ id: String) { rt.plugins.emit("commands.run", ["id": .string(id)]) }
    switch name {
    case "readerButton":
      open(rt, article) { w in
        after(rt, 3) { say(name, "pill=\(pill(rt))") }
        _ = w
      }
    case "reader", "readAloud":
      open(rt, article) { w in
        run(name == "reader" ? "pagetools.reader" : "pagetools.readAloud")
        after(rt, 4) {
          js(rt, w, "document.querySelector('den-reader') !== null") { open in
            say(name, "readerOpen=\(open ?? "nil") pill=\(pill(rt)) speech=\(rt.call("speech", "state"))")
          }
        }
      }
    case "translate", "translateJa":
      let url = name == "translate" ? "https://fr.wikipedia.org/wiki/Baguette_(pain)" : "https://ja.wikipedia.org/wiki/%E3%83%91%E3%83%B3"
      open(rt, url) { w in
        let t0 = Date()
        say(name, "pill=\(pill(rt))")
        var batches = 0
        rt.plugins.on("translate.result") { v in
          batches += 1
          if v["ok"] != true { say(name, "error=\(v.str("error"))") }
        }
        run("pagetools.translate")
        var first = false
        @MainActor func check() {
          js(rt, w, "document.documentElement.hasAttribute('data-den-translated') + '|' + document.title") { r in
            let started = (r as? String)?.hasPrefix("true") == true
            if started, !first {
              first = true
              say(name, String(format: "first batch (on-screen text) shown after %.1f s, title=%@", Date().timeIntervalSince(t0), (r as? String) ?? ""))
            }
            if started, pill(rt).contains("pagetools.pill.translate*") {
              say(name, String(format: "whole page translated in %.1f s, %d batches", Date().timeIntervalSince(t0), batches))
            } else if Date().timeIntervalSince(t0) < 120 {
              after(rt, 1) { check() }
            } else {
              say(name, "not translated after 120 s (batches \(batches))")
            }
          }
        }
        after(rt, 1) { check() }
      }
    case "captureRegion":
      open(rt, "https://example.com/") { _ in run("pagetools.capture.region") }
    case "captureFull":
      let dir = FileManager.default.temporaryDirectory.appendingPathComponent("den-captures-\(UUID().uuidString)")
      rt.call("storage", "set", ["ns": "pagetools", "key": "capture", "value": ["dest": "save", "folder": .string(dir.path)]])
      rt.plugins.on("webviews.snapshot") { v in
        if !v["bytes"].isNull { say(name, "ok=\(v["ok"]) \(v["width"])x\(v["height"]) px, \(v["bytes"]) bytes -> \(v.str("path"))") }
      }
      open(rt, sticky) { _ in run("pagetools.capture.full") }
    case "zap":
      open(rt, sticky) { w in
        run("pagetools.zap")
        rt.plugins.on("webviews.message") { v in
          if v["value"]["tool"] == "zap" { say(name, "selectors=\(v["value"]["value"]["selectors"])") }
        }
        after(rt, 1.5) {
          _ = rt.call("webviews", "inject", ["id": .string(w), "plugin": "pagetools", "script": "return window.__denZap.hide('.main-page-content > section:nth-of-type(2)') || window.__denZap.hide('main h2')"])
        }
      }
    case "unstick":
      open(rt, sticky) { w in
        rt.plugins.on("webviews.message") { v in
          if v["value"]["tool"] == "zap" { say(name, "selectors=\(v["value"]["value"]["selectors"])") }
        }
        run("pagetools.unstick")
        after(rt, 2) {
          js(rt, w, "Array.from(document.querySelectorAll('body *')).filter(function (e) { var s = getComputedStyle(e); return (s.position === 'fixed' || s.position === 'sticky') && s.display !== 'none' && e.getBoundingClientRect().height > 16; }).length") { n in
            say(name, "visible fixed/sticky boxes left=\(n ?? "nil")")
          }
        }
      }
    case "highlightLink":
      // The link comes from the plugin's inject result (the pasteboard is shared, so it isn't
      // read back here).
      var opened = false
      rt.plugins.on("webviews.injectResult") { v in
        let link = v["value"].str("url")
        guard !opened, link.contains("#:~:text=") else { return }
        opened = true
        say(name, "link=\(link)")
        // WebKit opens it: scrolls to the text and marks it.
        let id = rt.call("tabs", "open", ["url": .string(link)]).str("id")
        whenLoaded(rt, id) { v in
          after(rt, 2) {
            js(rt, v, "Math.round(scrollY) + '|' + location.href") { r in say(name, "opened scrollY|url=\(r ?? "nil")") }
          }
        }
      }
      open(rt, article) { w in
        // Select the start of a paragraph far down the article, as a user would.
        let select = "var ps = document.querySelectorAll('#mw-content-text p'), p = ps[Math.min(12, ps.length - 1)], t = document.createTreeWalker(p, 4), n = t.nextNode(); while (n && n.data.trim().length < 40) n = t.nextNode(); var r = document.createRange(); r.setStart(n, 0); r.setEnd(n, Math.min(n.data.length, 60)); getSelection().removeAllRanges(); getSelection().addRange(r); return n.data.slice(0, 60)"
        _ = rt.call("webviews", "inject", ["id": .string(w), "plugin": "pagetools", "script": .string(select)])
        after(rt, 1) { rt.plugins.emit("webviews.menu", ["id": "pagetools.highlight", "webview": .string(w), "plugin": "pagetools"]) }
      }
    case "qrCode":
      open(rt, "https://example.com/") { _ in
        run("pagetools.qrCode")
        after(rt, 0.5) { say(name, "popover=\(rt.ui.popoverOpen) overlays=\(rt.call("ui", "get")["overlays"])") }
      }
    case "copyToast":
      // At a fixed time (not after the load), so a 3.2 s snapshot lands inside the 2.2 s toast.
      let id = rt.call("tabs", "open", ["url": "https://example.com/"]).str("id")
      rt.call("tabs", "select", ["id": .string(id)])
      after(rt, 2.6) {
        rt.plugins.emit("tabs.key.copy")
        after(rt, 0.3) { say(name, "toast=\(rt.ui.toasts.last?.label.stringValue ?? "none")") }
      }
    default: break
    }
    return true
  }

  static func say(_ name: String, _ s: String) { print("scenario.pagetools \(name) \(s)") }

  static func after(_ rt: DenRuntime, _ s: Double, _ f: @escaping @MainActor () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { f() } }
  }

  /// Opens `url` in a selected today tab and calls back once it has loaded (and been probed).
  static func open(_ rt: DenRuntime, _ url: String, _ then: @escaping @MainActor (String) -> Void) {
    let id = rt.call("tabs", "open", ["url": .string(url)]).str("id")
    whenLoaded(rt, id, then)
  }

  /// Loaded, or (pages that keep loading, like MDN) mostly loaded for a while.
  static func whenLoaded(_ rt: DenRuntime, _ id: String, tries: Int = 120, _ then: @escaping @MainActor (String) -> Void) {
    let st = rt.call("webviews", "get", ["id": .string(id)])
    if st["live"] == true, st["loading"] == false, st.num("progress") >= 1 {
      after(rt, 1.5) { then(id) }
    } else if tries > 0 {
      after(rt, 0.25) { whenLoaded(rt, id, tries: tries - 1, then) }
    } else if st["live"] == true, st.num("progress") >= 0.5 {
      print("scenario.pagetools page still loading (\(st.num("progress"))), going on")
      then(id)
    } else {
      print("scenario.pagetools page never loaded: \(st)")
    }
  }

  static func js(_ rt: DenRuntime, _ id: String, _ script: String, _ done: @escaping @MainActor (String?) -> Void) {
    guard let w = rt.webviews.record(id)?.webView else { return done(nil) }
    w.evaluateJavaScript(script) { r, _ in MainActor.assumeIsolated { done(r.map { "\($0)" }) } }
  }

  static func pill(_ rt: DenRuntime) -> [String] {
    let header = rt.ui.sidebarView.slot("sidebar.header", page: 0)?.root?.node ?? .null
    let p = header.list("children").first { $0.str("type") == "urlPill" } ?? .null
    return p.list("buttons").map { $0.str("id") + ($0.flag("active") ? "*" : "") }
  }
}
#endif
