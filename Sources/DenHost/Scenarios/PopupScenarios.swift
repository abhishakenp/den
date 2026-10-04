// Dev fixture: compiled only with the `Scenarios` package trait (on by default; release bundles leave it out).
#if Scenarios
import AppKit
import CordisValue
import WebKit

/// `--scenario popupClick --url <page>`: opens the page in an ephemeral profile (`DEN_CLICK_PROFILE`,
/// default `private:popupcheck`: no real session is read or written), then clicks the element matching
/// `DEN_CLICK` (a CSS selector, main frame; an `<iframe>` is clicked at `DEN_CLICK_AT` = "fx,fy",
/// fractions of its box, default its centre) with a real mouse click delivered to WebKit, waits
/// `DEN_CLICK_WAIT` seconds (default 10) and prints every pop-up event and every web view's state
/// (`scenario.event …`, `scenario.view …`), then exits. For checking sign-in pop-ups on real sites
/// up to the provider's page: it never types anything.
@MainActor
public enum PopupScenarios {
  public static let names = ["popupClick"]

  public static func apply(_ name: String, url: String?, runtime rt: DenRuntime) {
    guard let url else { print("scenario.popupClick needs --url"); exit(1) }
    Task { @MainActor in await run(rt, url) }
  }

  static func wait(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
      if cond() { return true }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return cond()
  }

  static func js(_ w: WKWebView, _ s: String) async -> Any? {
    try? await w.evaluateJavaScript(s)
  }

  static func run(_ rt: DenRuntime, _ url: String) async {
    let env = ProcessInfo.processInfo.environment
    for e in ["webviews.newWindow", "webviews.popup", "webviews.popupBlocked", "webviews.closeRequested"] {
      rt.host.on(e) { v in
        let line = "scenario.event \(e) \(ValueJSON.string(v))"
        print(line)
      }
    }
    // An ephemeral profile: nothing from (or into) any real session; its pop-ups inherit it.
    let id = rt.call("webviews", "create", ["url": .string(url), "profile": .string(env["DEN_CLICK_PROFILE"] ?? "private:popupcheck")])["id"]
    rt.call("content", "show", ["panes": [id]])
    guard let rec = rt.webviews.record(id.string ?? ""), await wait(30, { rec.webView != nil && rec.webView?.isLoading == false }), let w = rec.webView else {
      print("scenario.popupClick page never loaded"); exit(1)
    }
    try? await Task.sleep(for: .seconds(Double(env["DEN_CLICK_DELAY"] ?? "") ?? 4))
    if let sel = env["DEN_CLICK"], let q = try? String(data: JSONSerialization.data(withJSONObject: [sel]), encoding: .utf8) {
      let at = (env["DEN_CLICK_AT"] ?? "0.5,0.5").split(separator: ",").compactMap { Double($0) }
      let fx = at.first ?? 0.5, fy = at.count > 1 ? at[1] : 0.5
      let found = await js(w, "(() => { const e = document.querySelector(\(q)[0]); if (!e) return null; e.scrollIntoView({block: 'center'}); const r = e.getBoundingClientRect(); return [r.x + r.width * \(fx), r.y + r.height * \(fy), e.outerHTML.slice(0, 160)] })()") as? [Any]
      guard let found, let x = (found[0] as? NSNumber)?.doubleValue, let y = (found[1] as? NSNumber)?.doubleValue else {
        print("scenario.popupClick no element \(sel)"); exit(1)
      }
      print("scenario.click \(found[2]) at \(Int(x)),\(Int(y))")
      try? await Task.sleep(for: .milliseconds(500))
      click(w, at: NSPoint(x: x, y: y))
    }
    try? await Task.sleep(for: .seconds(Double(env["DEN_CLICK_WAIT"] ?? "") ?? 10))
    for r in rt.webviews.records.values.sorted(by: { $0.id < $1.id }) where r.webView != nil {
      print("scenario.view id=\(r.id) opener=\(r.opener ?? "-") window=\(r.popupWindow ?? "-") profile=\(r.profile) url=\(r.webView?.url?.absoluteString ?? r.url) title=\(r.webView?.title ?? "")")
    }
    print("scenario.done minis=\(rt.call("window", "listMini").array?.count ?? 0)")
    exit(0)
  }

  /// A real left click (mouse down + up) at a point in page (CSS) coordinates, delivered to the
  /// WebKit view under it.
  static func click(_ w: WKWebView, at p: NSPoint) {
    let local = NSPoint(x: p.x * w.magnification, y: w.isFlipped ? p.y * w.magnification : w.bounds.height - p.y * w.magnification)
    guard let win = w.window, let sup = w.superview else { return }
    let inWindow = w.convert(local, to: nil)
    guard let target = w.hitTest(sup.convert(inWindow, from: nil)) else { return }
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      guard let e = NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
      if type == .leftMouseDown { target.mouseDown(with: e) } else { target.mouseUp(with: e) }
    }
  }
}
#endif
