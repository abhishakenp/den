import AppKit
import CordisValue
import DenHost
import WebKit

/// `--scenario ytsearch [--url <count>]`: YouTube's first search in a fresh tab, N times (default
/// 20). Each attempt opens youtube.com in a new muted tab, waits for it to load, types a query in
/// its search box and submits it, then after 10 s prints one line:
///   `scenario.yt n=<i> ok=<results shown> url=<page url> results=<videos> pid=<WebContent before>-><after>
///    title=<…> error=<YouTube's or den's error text> fails=<fetch/XHR failures the page saw>`
/// and closes the tab; `scenario.ytDone ok=<k>/<n>` at the end. Run with DEN_NAV_LOG=<file> for
/// every main-frame navigation event.
@MainActor
final class YouTubeSearchScenario {
  let rt: DenRuntime
  let count: Int
  var ok = 0

  init(rt: DenRuntime, count: Int) { (self.rt, self.count) = (rt, count) }

  func after(_ s: Double, _ f: @escaping @MainActor () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { f() } }
  }

  func out(_ s: String) { print(s); fflush(stdout) }

  func start() {
    // As in realtabs: the window is off every display; its pages run as on screen.
    rt.webviews.createdHooks.append { _, w in
      let sel = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
      guard w.responds(to: sel) else { return }
      typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
      unsafeBitCast(w.method(for: sel), to: Setter.self)(w, sel, false)
    }
    attempt(1)
  }

  func pid(_ id: String) -> Int { (rt.webviews.record(id)?.webView?.value(forKey: "_webProcessIdentifier") as? NSNumber)?.intValue ?? 0 }

  func attempt(_ n: Int) {
    guard n <= count else { return out("scenario.ytDone ok=\(ok)/\(count)") }
    let id = rt.call("tabs", "open", ["url": "https://www.youtube.com/"])["id"].string ?? ""
    rt.call("tabs", "select", ["id": .string(id)])
    rt.call("webviews", "setMuted", ["id": .string(id), "muted": true])
    waitLoaded(id, 0) { [self] in
      let w = rt.webviews.record(id)?.webView
      let p0 = pid(id)
      // Page world: every failed fetch/XHR is remembered, then the query is typed and submitted.
      let js = """
      window.__denFails = [];
      const of = window.fetch;
      window.fetch = function(...a) { return of.apply(this, a).catch(e => { window.__denFails.push('fetch ' + String(a[0] && a[0].url || a[0]).slice(0, 90) + ' ' + e); throw e; }); };
      const oo = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(m, u, ...r) { this.addEventListener('error', () => window.__denFails.push('xhr ' + String(u).slice(0, 90))); return oo.call(this, m, u, ...r); };
      const i = document.querySelector('input[name=search_query]');
      if (!i) { 'no search box'; } else {
        i.focus(); i.value = 'den search test \(n) ' + Date.now() % 1000;
        i.dispatchEvent(new Event('input', {bubbles: true}));
        const f = i.closest('form');
        const b = document.querySelector('button.ytSearchboxComponentSearchButton, #search-icon-legacy, button[aria-label=Search]');
        if (b) b.click(); else if (f) f.requestSubmit(); else i.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', keyCode: 13, bubbles: true}));
        'submitted ' + (b ? 'button' : f ? 'form' : 'enter');
      }
      """
      w?.evaluateJavaScript(js) { [self] res, err in
        let how = (res as? String) ?? "js error \(String(describing: err))"
        after(10) { [self] in report(n, id, p0, how) }
      }
    }
  }

  func waitLoaded(_ id: String, _ waited: Double, then: @escaping @MainActor () -> Void) {
    let w = rt.webviews.record(id)?.webView
    if let w, !w.isLoading, waited >= 4 { return after(2, then) }
    if waited > 30 { return then() }
    after(0.5) { [self] in waitLoaded(id, waited + 0.5, then: then) }
  }

  func report(_ n: Int, _ id: String, _ p0: Int, _ how: String) {
    guard let w = rt.webviews.record(id)?.webView else {
      out("scenario.yt n=\(n) ok=false no web view")
      return next(n, id)
    }
    let js = """
    (() => {
      const t = document.body ? document.body.innerText : '';
      const m = t.match(/(No internet|You're offline|you.re offline|Connect to the internet|Something went wrong|couldn.t load|This page crashed|Can.t open|Check your Wi)[^\\n]{0,80}/i);
      return JSON.stringify({url: location.href.slice(0, 90), results: document.querySelectorAll('ytd-video-renderer, yt-lockup-view-model').length,
        error: m ? m[0] : '', fails: (window.__denFails || []).slice(0, 4)});
    })()
    """
    w.evaluateJavaScript(js) { [self] res, err in
      let s = (res as? String) ?? "js error \(String(describing: err))"
      let good = s.contains("results\":") && !s.contains("\"results\":0") && s.contains("/results") && s.contains("\"error\":\"\"")
      if good { ok += 1 }
      out("scenario.yt n=\(n) ok=\(good) \(how) pid=\(p0)->\(pid(id)) title=\(w.title ?? "") \(s)")
      next(n, id)
    }
  }

  func next(_ n: Int, _ id: String) {
    rt.call("tabs", "close", ["id": .string(id)])
    after(1) { [self] in attempt(n + 1) }
  }
}
