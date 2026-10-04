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
  public static let names = ["popupClick", "popupWindow", "popupBlocked"]

  public static func apply(_ name: String, url: String?, runtime rt: DenRuntime) {
    if name == "popupWindow" || name == "popupBlocked" {
      Task { @MainActor in await snapshotScene(rt, blocked: name == "popupBlocked") }
      return
    }
    guard let url else { print("scenario.popupClick needs --url"); exit(1) }
    Task { @MainActor in await run(rt, url) }
  }

  /// Kept alive for the scenario's lifetime.
  static var mock: MockServices?

  static let shopPage = """
    <!doctype html><title>Acme Store</title><body style="font:15px -apple-system;margin:0;background:#f6f5fb;color:#222">
    <div style="padding:48px 64px"><h1 style="font-size:30px">Acme Store</h1>
    <p>Sign in to see your orders and saved addresses.</p>
    <button style="font:15px -apple-system;padding:12px 22px;border-radius:10px;border:1px solid #ccc;background:#fff">Continue with Provider</button>
    <div style="margin-top:40px;display:grid;grid-template-columns:repeat(3,200px);gap:20px">
    <div style="height:160px;border-radius:14px;background:#e3dff7"></div><div style="height:160px;border-radius:14px;background:#dcecf5"></div><div style="height:160px;border-radius:14px;background:#f4e3dc"></div>
    </div></div>
    """
  static let signInPage = """
    <!doctype html><title>Sign in · Provider</title><body style="font:15px -apple-system;margin:0;background:#fff;color:#222">
    <div style="padding:40px 36px"><h2 style="margin:0 0 6px">Sign in</h2><p style="color:#666;margin:0 0 24px">to continue to Acme Store</p>
    <div style="border:1px solid #ccc;border-radius:8px;padding:12px;color:#888">Email or phone</div>
    <button style="margin-top:24px;font:15px -apple-system;padding:10px 22px;border-radius:8px;border:0;background:#3139fb;color:#fff">Next</button></div>
    """

  /// `--scenario popupWindow`: a store page whose "Continue with Provider" opened a sign-in pop-up
  /// window (snapshot: that window). `--scenario popupBlocked`: a page that tried to open a pop-up
  /// without a click; the URL pill shows "Pop-up blocked" (snapshot: the browser window). Local
  /// pages (MockServices), no network.
  static func snapshotScene(_ rt: DenRuntime, blocked: Bool) async {
    let m = MockServices()
    try? m.start()
    mock = m
    let signIn = "http://localhost:\(m.port)/signin"
    m.page("/signin", signInPage)
    m.page("/shop", shopPage + (blocked ? "<script>setTimeout(() => window.open('\(signIn)'), 300)</script>" : ""))
    let id = rt.call("tabs", "open", ["url": .string(m.base + "/shop")])["id"]
    rt.call("tabs", "select", ["id": id])
    guard let rec = rt.webviews.record(id.string ?? ""), await wait(20, { rec.webView?.isLoading == false && rec.webView?.url?.path == "/shop" }),
          let w = rec.webView else { print("scenario.popup page never loaded"); return }
    if blocked {
      _ = await wait(10) { !rec.blockedPopups.isEmpty }
      print("scenario.popupBlocked blocked=\(rec.blockedPopups.count)")
      return
    }
    // evaluateJavaScript runs as a user gesture: the click's window.open.
    _ = try? await w.evaluateJavaScript("window.open('\(signIn)', 'signin', 'width=420,height=520'); 1")
    _ = await wait(10) { rt.webviews.records.values.contains { $0.popupWindow != nil && $0.webView?.isLoading == false } }
    print("scenario.popupWindow minis=\(rt.call("window", "listMini").array?.count ?? 0)")
  }

  static func wait(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
      if cond() { return true }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return cond()
  }

  /// A JS string literal.
  static func quoted(_ s: String) -> String {
    let a = (try? String(data: JSONSerialization.data(withJSONObject: [s]), encoding: .utf8)) ?? "[\"\"]"
    return String(a.dropFirst().dropLast())
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
    // DEN_CLICK_TEXT: the smallest visible button / link / role=button whose text contains it.
    let byText = env["DEN_CLICK_TEXT"].map { t -> String in
      let needle = quoted(t.lowercased())
      return "[...document.querySelectorAll('button,a,[role=button],input[type=submit],input[type=button]')]"
        + ".filter(e => (e.innerText || e.value || e.getAttribute('aria-label') || '').toLowerCase().includes(\(needle)) && e.getBoundingClientRect().width > 0)"
        + ".sort((a, b) => (a.innerText || '').length - (b.innerText || '').length)[0]"
    }
    // DEN_JS: main-frame script run first (e.g. filling a demo's name field).
    if let pre = env["DEN_JS"] { print("scenario.js \(String(describing: await js(w, pre)))") }
    if let sel = env["DEN_CLICK"] ?? env["DEN_CLICK_TEXT"] {
      guard await clickElement(w, byText ?? "document.querySelector(\(quoted(sel)))", at: env["DEN_CLICK_AT"]) else {
        print("scenario.popupClick no element \(sel)"); exit(1)
      }
    }
    // DEN_TYPE: typed as key presses into whatever has focus after the click.
    if let text = env["DEN_TYPE"] {
      try? await Task.sleep(for: .seconds(1))
      for ch in text {
        type(w, ch)
        try? await Task.sleep(for: .milliseconds(80))
      }
    }
    // DEN_CLICK2: a second element (css) clicked after typing (a Pay button).
    if let sel2 = env["DEN_CLICK2"] {
      try? await Task.sleep(for: .seconds(1))
      guard await clickElement(w, "document.querySelector(\(quoted(sel2)))", at: nil) else { print("scenario.popupClick no element \(sel2)"); exit(1) }
    }
    try? await Task.sleep(for: .seconds(Double(env["DEN_CLICK_WAIT"] ?? "") ?? 10))
    for r in rt.webviews.records.values.sorted(by: { $0.id < $1.id }) where r.webView != nil {
      print("scenario.view id=\(r.id) opener=\(r.opener ?? "-") window=\(r.popupWindow ?? "-") profile=\(r.profile) url=\(r.webView?.url?.absoluteString ?? r.url) title=\(r.webView?.title ?? "")")
    }
    if let rep = env["DEN_REPORT"] { print("scenario.report \(String(describing: await js(w, rep)))") }
    print("scenario.done minis=\(rt.call("window", "listMini").array?.count ?? 0)")
    exit(0)
  }

  /// Scrolls the element `expr` evaluates to into view and clicks it at `at` ("fx,fy" of its box).
  static func clickElement(_ w: WKWebView, _ expr: String, at: String?) async -> Bool {
    let f = (at ?? "0.5,0.5").split(separator: ",").compactMap { Double($0) }
    let fx = f.first ?? 0.5, fy = f.count > 1 ? f[1] : 0.5
    let found = await js(w, "(() => { const e = \(expr); if (!e) return null; e.scrollIntoView({block: 'center'}); const r = e.getBoundingClientRect(); return [r.x + r.width * \(fx), r.y + r.height * \(fy), e.outerHTML.slice(0, 160)] })()") as? [Any]
    guard let found, let x = (found[0] as? NSNumber)?.doubleValue, let y = (found[1] as? NSNumber)?.doubleValue else { return false }
    print("scenario.click \(found[2]) at \(Int(x)),\(Int(y))")
    try? await Task.sleep(for: .milliseconds(500))
    click(w, at: NSPoint(x: x, y: y))
    return true
  }

  /// One key press (down + up) for a character, to the window's first responder (the page).
  static func type(_ w: WKWebView, _ ch: Character) {
    guard let win = w.window else { return }
    let s = String(ch)
    for t in [NSEvent.EventType.keyDown, .keyUp] {
      guard let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber,
                                     context: nil, characters: s, charactersIgnoringModifiers: s, isARepeat: false, keyCode: 0) else { continue }
      let r = win.firstResponder as? NSView ?? w
      if t == .keyDown { r.keyDown(with: e) } else { r.keyUp(with: e) }
    }
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
