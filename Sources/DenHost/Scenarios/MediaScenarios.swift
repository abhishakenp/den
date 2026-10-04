// Dev fixture: compiled only with the `Scenarios` package trait (on by default; release bundles leave it out).
#if Scenarios
import AppKit
import CordisValue
import WebKit

/// `--scenario` runs for picture in picture (WebKit's native PiP, the system window Safari uses),
/// in the real app with the demo tabs (they need the tabs plugin). A local page plays
/// `Tests/Fixtures/test-video.mp4` from `MockServices` (byte ranges, no network), started through
/// `callAsyncJavaScript` like a click would.
///
/// - `pip`: the whole check list, through the real code paths, one line per check
///   (`scenario.pip <name> ok=…`), then `scenario.done ok=…`, exit 0 or 1: a tab switch puts the
///   video in the system PiP window (CGWindowList), it keeps playing there and the window shows the
///   whole frame (a screen capture of the PiP window, when this process may capture), also with the
///   video scrolled half and fully out of view; coming back takes it out; den minimized / hidden /
///   ordered out and back; the PiP window's return button (the call it makes into WebKit) goes back
///   to the tab, its close button pauses; Picture in Picture (⌥⌘P) by hand, which a tab switch
///   doesn't undo; a video in a cross-origin iframe; the setting. `DEN_PIP_FULLSCREEN=1` adds a
///   full-screen video whose Space is switched away from and back (a real Space switch through the
///   WindowServer: for CI's runner, `ci.yml` dispatch input `pip`, never a desktop someone uses).

/// - `pipAway`: plays the video, switches tabs, stays (memory and CPU with the video in PiP).
/// - `pipInline`: the same video playing in its tab (the baseline).
/// - `pipURL`: `DEN_PIP_URL` (default a YouTube video): plays it, scrolls `DEN_PIP_SCROLL` pt (default
///   400, the player partly out of view), switches tabs and prints the PiP window's id, so a script
///   can capture it (`screencapture -l <id>`).
@MainActor
public enum MediaScenarios {
  public static let names = ["pip", "pipAway", "pipInline", "pipURL"]

  public static func apply(_ name: String, runtime rt: DenRuntime) {
    Task { @MainActor in await run(name, rt) }
  }

  static func log(_ s: String) { print(s) }

  /// The repo's test video, found from the app bundle (build/den.app) or the working directory.
  static func fixture() -> Data? {
    var dir = Bundle.main.bundleURL
    for _ in 0..<4 {
      dir.deleteLastPathComponent()
      if let d = try? Data(contentsOf: dir.appendingPathComponent("Tests/Fixtures/test-video.mp4")) { return d }
    }
    return try? Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/test-video.mp4"))
  }

  static let page = """
    <!doctype html><html><head><title>Test Video</title><style>
    body{margin:0;font:15px -apple-system;background:#f6f4ff;color:#222;padding:40px 56px}
    video{width:640px;border-radius:10px;background:#000;display:block;margin:16px 0}
    p{max-width:640px;color:#555;line-height:1.5}.tall{height:3000px}</style></head>
    <body><h1>Test video</h1><p>A local page with a 30 s video. Switch to another tab while it plays and it goes to picture in picture.</p>
    <video src="/test-video.mp4" controls playsinline loop></video>
    <div class=tall></div></body></html>
    """

  static func sleep(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }

  /// Runs `js` in den's page world of `id` (main frame, or `frame`), returns its value.
  static func js(_ rt: DenRuntime, _ id: String, _ js: String, frame: WKFrameInfo? = nil) async -> Value {
    guard rt.webviews.record(id)?.webView != nil else { return .null }
    let box = await withCheckedContinuation { (c: CheckedContinuation<Box, Never>) in
      rt.webviews.runPageScript(id, js, frame: frame) { r in
        switch r {
        case let .success(v): c.resume(returning: Box(v: WebViewsService.jsValue(v)))
        case .failure: c.resume(returning: Box(v: .null))
        }
      }
    }
    return box.v
  }

  struct Box: @unchecked Sendable { let v: Value }

  static func until(_ timeout: Double, _ cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
      if cond() { return true }
      await sleep(0.05)
    }
    return cond()
  }

  /// Presses a button of the system PiP window the way the window does: PIP.framework calls its
  /// delegate (WebKit's video presentation object) with `pipShouldClose:` for the return button
  /// and `pipActionStop:` for the close button. The PiP window itself belongs to the system agent
  /// and isn't driven. False when there's no PiP view controller in this process.
  @discardableResult
  public static func pressPipButton(_ selector: String) -> Bool {
    guard let vc = pipViewController(), let d = vc.value(forKey: "delegate") as? NSObject, d.responds(to: NSSelectorFromString(selector)) else { return false }
    _ = d.perform(NSSelectorFromString(selector), with: vc)
    return true
  }

  static func pipViewController() -> NSViewController? {
    NSApp.windows.compactMap(\.contentViewController).first { NSStringFromClass(type(of: $0)).contains("PIPViewController") }
  }

  /// The close button: WebKit's `pipActionStop:` (it pauses the video), then the window closes
  /// itself (PIP.framework's dismissal, which tells WebKit it closed).
  @discardableResult
  public static func pressPipCloseButton() -> Bool {
    guard pressPipButton("pipActionStop:"), let vc = pipViewController() else { return false }
    let s = NSSelectorFromString("dismissPictureInPictureWithCompletionHandler:")
    guard vc.responds(to: s) else { return false }
    let done: @convention(block) () -> Void = {}
    _ = vc.perform(s, with: done)
    return true

  }


  /// The system PiP window's id, size and layer, for the log.
  static func pipWindow() -> (id: Int, text: String)? {
    guard let w = NativePiP.systemWindows().first, let n = w[kCGWindowNumber as String] as? Int else { return nil }
    let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    return (n, "window=\(n) size=\(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0)) layer=\(w[kCGWindowLayer as String] as? Int ?? -1)")
  }

  /// Captures the system PiP window (`screencapture -l`) and measures how much of its lower three
  /// quarters is near-black (the old mini player's failure: only the top of the frame drawn).
  /// nil when this process may not capture the screen.
  static func pipBlackFraction(_ tag: String) -> Double? {
    guard let w = pipWindow() else { return nil }
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("den-pip-\(getpid())-\(tag).png").path
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o", "-l\(w.id)", path]
    guard (try? p.run()) != nil else { return nil }
    p.waitUntilExit()
    guard let data = FileManager.default.contents(atPath: path), let rep = NSBitmapImageRep(data: data), rep.pixelsWide > 40 else { return nil }
    var dark = 0, all = 0
    // Inset from the rounded corners; rows from a quarter down to the bottom.
    for y in stride(from: rep.pixelsHigh / 4, to: rep.pixelsHigh - 12, by: 6) {
      for x in stride(from: 12, to: rep.pixelsWide - 12, by: 6) {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        all += 1
        if c.redComponent + c.greenComponent + c.blueComponent < 0.12 { dark += 1 }
      }
    }
    log("scenario.pip capture \(tag) \(path)")
    return all == 0 ? nil : Double(dark) / Double(all)
  }

  /// Runs a command, waits for it (at most `timeout` s), returns its output.
  @discardableResult
  static func sh(_ path: String, _ args: [String], timeout: Double = 15) async -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    guard (try? p.run()) != nil else { return "(\(path) didn't run)" }
    _ = await until(timeout) { !p.isRunning }
    if p.isRunning { p.terminate() }
    return String(data: pipe.fileHandleForReading.availableData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  /// Ends the app the scenario switched to (CI's runner only), by process name.
  static func quitApp(_ name: String) async { await sh("/usr/bin/pkill", ["-x", name]) }

  /// The frontmost app's name.
  static var front: String { NSWorkspace.shared.frontmostApplication?.localizedName ?? "none" }

  /// den in front again, the way you would come back (LaunchServices reopening it, like a Dock
  /// click), else NSApp.activate.
  static func activateDen(_ rt: DenRuntime) async -> Bool {
    if NSApp.isActive { return true }
    await sh("/usr/bin/open", [Bundle.main.bundlePath])
    if await until(4, { NSApp.isActive }) { return true }
    NSApp.activate(ignoringOtherApps: true)
    rt.window.window.makeKeyAndOrderFront(nil)
    return await until(4) { NSApp.isActive }
  }

  /// How much of den's window other apps' windows in front of it cover (CGWindowList), 0-1.
  static func covered(_ rt: DenRuntime) -> Double {
    let num = rt.window.window.windowNumber
    let list = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], CGWindowID(num)) as? [[String: Any]] ?? []
    guard let mine = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(num)) as? [[String: Any]])?.first,
          let mb = mine[kCGWindowBounds as String] as? [String: CGFloat] else { return -1 }
    let den = CGRect(x: mb["X"] ?? 0, y: mb["Y"] ?? 0, width: mb["Width"] ?? 0, height: mb["Height"] ?? 0)
    // A coarse grid: the share of den's points under another app's window.
    var hit = 0, all = 0
    let rects = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) != getpid() && ($0[kCGWindowLayer as String] as? Int) == 0 }
      .compactMap { $0[kCGWindowBounds as String] as? [String: CGFloat] }
      .map { CGRect(x: $0["X"] ?? 0, y: $0["Y"] ?? 0, width: $0["Width"] ?? 0, height: $0["Height"] ?? 0) }
    for x in stride(from: den.minX + 5, to: den.maxX, by: max(den.width / 20, 1)) {
      for y in stride(from: den.minY + 5, to: den.maxY, by: max(den.height / 20, 1)) {
        all += 1
        if rects.contains(where: { $0.contains(CGPoint(x: x, y: y)) }) { hit += 1 }
      }
    }
    return all == 0 ? -1 : Double(hit) / Double(all)
  }

  /// 4b of `pip`: another app in front (Terminal over part of den; `DEN_PIP_COVER`, a built
  /// PipCover.app (scripts/ci/pip-cover.swift): one covering all of den, one in full screen).
  static func appSwitches(_ rt: DenRuntime, _ id: String, check: (String, Bool, String) -> Void, inPip: () -> Bool, out: () -> Bool,
                          advancing: () async -> (Bool, String)) async {
    let env = ProcessInfo.processInfo.environment
    struct Case { let name: String; let go: [String]; let app: String }
    var cases = [Case(name: "appSwitch.terminal", go: ["-a", "Terminal"], app: "Terminal")]
    if let cover = env["DEN_PIP_COVER"] {
      cases.append(Case(name: "appSwitch.covered", go: ["-n", cover, "--args", "full"], app: "PipCover"))
      cases.append(Case(name: "spaceSwitch.fullScreenApp", go: ["-n", cover, "--args", "fullscreen"], app: "PipCover"))
    } else {
      log("scenario.pip appSwitch.covered skipped: no DEN_PIP_COVER")
    }
    for c in cases {
      guard await activateDen(rt), await until(3, { rt.media.windowVisible && out() }) else {
        log("scenario.pip \(c.name) skipped: den isn't in front (front=\(front) active=\(NSApp.isActive) visible=\(rt.media.windowVisible))")
        continue
      }
      await sleep(0.5)
      let spacesBefore = Spaces.current()
      let t0 = Date()
      await sh("/usr/bin/open", c.go)
      let left = await until(8) { !NSApp.isActive }
      let entered = await until(8) { inPip() }
      if c.name.hasPrefix("spaceSwitch") { _ = await until(5) { Spaces.current() != spacesBefore } }
      await sleep(0.4)
      let state = "front=\(front) denActive=\(NSApp.isActive) covered=\(String(format: "%.0f%%", covered(rt) * 100)) windowVisible=\(rt.media.windowVisible) space=\(spacesBefore)->\(Spaces.current()) spaces=\(Spaces.list())"
      check("\(c.name).enters", left && entered, String(format: "after=%.0fms ", Date().timeIntervalSince(t0) * 1000) + state + " " + (pipWindow()?.text ?? "no PiP window"))
      if c.name.hasPrefix("spaceSwitch") {
        // Only a real Space switch counts; without one (no full-screen Space on this display) say so.
        if Spaces.current() == spacesBefore { log("scenario.pip \(c.name) note: the display didn't switch Space (\(Spaces.list()))") }
        else { check("\(c.name).spaceChanged", !rt.window.window.isOnActiveSpace, "denOnActiveSpace=\(rt.window.window.isOnActiveSpace)") }
      }
      if entered {
        let (live, d) = await advancing()
        check("\(c.name).live", live, d)
        frameCheck(c.name, check: check)
        // Den's window still partly showing behind the other app: PiP stays (no flicker back).
        await sleep(1)
        check("\(c.name).stays", inPip(), "")
      }
      // Back to den, the way you would: it comes forward, the video leaves PiP and plays on inline.
      let back = await activateDen(rt)
      let gone = await until(8) { out() && NativePiP.systemWindows().isEmpty }
      check("\(c.name).back", back && gone, "denActive=\(NSApp.isActive) visible=\(rt.media.windowVisible) space=\(Spaces.current())")
      await sleep(0.5)
      let p = await js(rt, id, "return window.__denMedia.probe()", frame: rt.webviews.record(id)?.videoFrame?.frame)
      check("\(c.name).playing", !p.flag("paused") && !p.flag("inPip"), "")
      await quitApp(c.app)
      await sleep(1.5)
    }
  }

  static func frameCheck(_ what: String, check: (String, Bool, String) -> Void) {
    guard let f = pipBlackFraction(what) else { log("scenario.pip \(what).frame skipped: no screen capture"); return }
    check("\(what).frame", f < 0.2, String(format: "black=%.0f%%", f * 100))
  }

  static func run(_ name: String, _ rt: DenRuntime) async {
    // Every automatic PiP decision, as den.log has it on a Mac (`media.log`).
    let prev = rt.media.log
    rt.media.log = { prev?($0); print("media.log \($0)") }
    log("scenario.pip start active=\(NSApp.isActive) front=\(front) spaces=\(Spaces.list()) current=\(Spaces.current())")
    let mock = MockServices()
    try? mock.start()
    guard let video = fixture() else { log("scenario.pip fixture missing"); exit(1) }
    mock.files = [
      "/video.html": ("text/html; charset=utf-8", Data(page.utf8)), "/test-video.mp4": ("video/mp4", video),
      "/embed.html": ("text/html; charset=utf-8", Data("<!doctype html><title>Embedded Video</title><body style='margin:0;padding:30px;background:#fff'><h2>Embed</h2><iframe src='http://localhost:\(mock.port)/video.html' width=760 height=560 style='border:0' allow='autoplay; picture-in-picture'></iframe></body>".utf8)),
    ]
    let env = ProcessInfo.processInfo.environment
    let url = name == "pipURL" ? (env["DEN_PIP_URL"] ?? "https://www.youtube.com/watch?v=aqz-KE-bpKQ") : mock.base + "/video.html"
    let other = rt.call("tabs", "selected")["id"].string ?? ""
    let id = rt.call("tabs", "open", ["url": .string(url)])["id"].string ?? ""
    var allOK = true
    func check(_ what: String, _ ok: Bool, _ detail: String = "") {
      allOK = allOK && ok
      log("scenario.pip \(what) ok=\(ok)\(detail.isEmpty ? "" : " " + detail)")
    }
    func probe(_ tab: String = id) async -> Value { await js(rt, tab, "return window.__denMedia.probe()", frame: rt.webviews.record(tab)?.videoFrame?.frame) }
    func inPip(_ tab: String = id) -> Bool { rt.media.active.contains(tab) && !NativePiP.systemWindows().isEmpty }
    func out(_ tab: String = id) -> Bool { !rt.media.active.contains(tab) }
    /// Still playing, and the clock moves (the video is live, not a frozen frame).
    func advancing(_ tab: String = id) async -> (Bool, String) {
      let a = await probe(tab)
      await sleep(1)
      let b = await probe(tab)
      // The test video loops: from its last second and a half back to its start moves too.
      let looped = a.num("dur") > 0 && a.num("t") > a.num("dur") - 1.5 && b.num("t") < 1.5
      return (!b.flag("paused") && (b.num("t") > a.num("t") + 0.5 || looped), "t=\(String(format: "%.1f", a.num("t")))->\(String(format: "%.1f", b.num("t")))")
    }
    func frameCheck(_ what: String) {
      guard let f = pipBlackFraction(what) else { log("scenario.pip \(what).frame skipped: no screen capture"); return }
      check("\(what).frame", f < 0.2, String(format: "black=%.0f%%", f * 100))
    }
    func startVideo(_ tab: String = id) async -> Bool {
      _ = await until(20) { rt.webviews.record(tab)?.webView?.isLoading == false }
      await sleep(name == "pipURL" ? 3 : 0.3)
      // Like a click on play: callAsyncJavaScript runs with a user gesture.
      _ = await js(rt, tab, "const v = document.querySelector('video'); if (!v) return false; v.muted = false; v.volume = 1; await v.play().catch(() => {}); return !v.paused", frame: nil)
      return await until(10) { rt.media.eligibleVideo(tab) != nil }
    }
    func scroll(_ y: Int) async { _ = await js(rt, id, "window.scrollTo(0, \(y)); return window.scrollY") }

    check("playing", await startVideo(), rt.webviews.record(id)?.videoFrame?.media.video.map { "video=\($0.num("vw"))x\($0.num("vh")) dur=\($0.num("dur"))" } ?? "")
    if name == "pipInline" {
      await sleep(3)
      log("scenario.ready inline t=\((await probe()).num("t"))")
      return
    }
    if name == "pipURL" {
      await scroll(Int(env["DEN_PIP_SCROLL"] ?? "400") ?? 400)
      await sleep(1)
      rt.call("tabs", "select", ["id": .string(other)])
      check("tabSwitch.enters", await until(5) { inPip() }, pipWindow()?.text ?? "no PiP window")
      let (live, d) = await advancing()
      check("tabSwitch.live", live, d)
      frameCheck("url")
      log("scenario.ready pip=\(rt.media.active.contains(id)) \(pipWindow()?.text ?? "")")
      return
    }
    // 1. Switch away from the tab: the system PiP window, live.
    rt.call("tabs", "select", ["id": .string(other)])
    check("tabSwitch.enters", await until(5) { inPip() }, pipWindow()?.text ?? "no PiP window")
    check("tabSwitch.auto", rt.media.auto.contains(id) && rt.call("webviews", "get", ["id": .string(id)])["media"]["pip"] == true)
    check("tabSwitch.keptLive", rt.call("webviews", "suspend", ["id": .string(id)])["reason"] == "pip")
    let (live, d) = await advancing()
    check("tabSwitch.live", live, d)
    frameCheck("tabSwitch")
    if name == "pipAway" {
      log("scenario.ready pip=\(rt.media.active.contains(id)) \(pipWindow()?.text ?? "")")
      return
    }

    // 2. Back to the tab: out of PiP, inline, still playing.
    rt.call("tabs", "select", ["id": .string(id)])
    check("back.exits", await until(5) { out() && NativePiP.systemWindows().isEmpty })
    await sleep(0.5)
    let back = await probe()
    check("back.inline", !back.flag("inPip") && rt.webviews.record(id)?.webView?.superview === rt.content.card(id)?.clip)
    check("back.playing", !back.flag("paused"))

    // 3. The video partly, then fully, scrolled out of view: the PiP window still shows the whole frame.
    for (what, y) in [("scrolledHalf", 260), ("scrolledAway", 1600)] {
      await scroll(y)
      await sleep(0.6)
      rt.call("tabs", "select", ["id": .string(other)])
      check("\(what).enters", await until(5) { inPip() })
      let (l, d) = await advancing()
      check("\(what).live", l, d)
      frameCheck(what)
      rt.call("tabs", "select", ["id": .string(id)])
      _ = await until(5) { out() }
      await scroll(0)
      await sleep(0.4)
    }

    // 4. den away: minimized, hidden, ordered out; and back.
    func away(_ what: String, _ go: () -> Void, _ comeBack: () -> Void) async {
      guard await until(3, { rt.media.windowVisible && out() }) else {
        log("scenario.pip \(what) skipped: den's window isn't visible")
        return
      }
      let t0 = Date()
      go()
      check("\(what).enters", await until(5) { inPip() }, String(format: "after=%.0fms", Date().timeIntervalSince(t0) * 1000))
      await sleep(0.6)
      comeBack()
      check("\(what).exits", await until(5) { out() })
      check("\(what).playing", !(await probe()).flag("paused"))
      await sleep(0.4)
    }
    let w = rt.window.window
    await away("miniaturize", { w.miniaturize(nil) }, { w.deminiaturize(nil) })
    // Coming back from ⌘H is a click in the Dock or ⌘-Tab: den unhidden and active.
    await away("hide", { NSApp.hide(nil) }, { NSApp.unhide(nil); NSApp.activate(ignoringOtherApps: true) })
    await away("orderOut", { w.orderOut(nil) }, { w.orderFront(nil) })

    // 4b. Switching to another app, as you would: Terminal over part of den (den's window still
    // showing), an app covering all of it, and a full-screen app (the display switches Space).
    await appSwitches(rt, id, check: check, inPip: { inPip() }, out: { out() }, advancing: { await advancing() })

    // 5. The PiP window's return button: back to the tab (selected), video inline and playing.
    rt.call("tabs", "select", ["id": .string(other)])
    _ = await until(5) { inPip() }
    await sleep(1)  // the PiP window's opening animation
    var backToTab = false
    let obs = rt.host.on("media.backToTab") { _ in backToTab = true }
    check("returnButton.pressed", pressPipButton("pipShouldClose:"))
    check("returnButton.backToTab", await until(5) { backToTab && out() && rt.call("tabs", "selected")["id"].string == id })
    await sleep(0.4)
    check("returnButton.playing", !(await probe()).flag("paused"))
    rt.host.off(obs)

    // 6. Its close button: pauses, stays on the other tab.
    rt.call("tabs", "select", ["id": .string(other)])
    _ = await until(5) { inPip() }
    await sleep(1)
    backToTab = false
    let obs2 = rt.host.on("media.backToTab") { _ in backToTab = true }
    check("closeButton.pressed", pressPipCloseButton())
    await sleep(1)
    let closed = await js(rt, id, "return document.querySelector('video').paused")
    check("closeButton.pauses", closed == true, "paused=\(closed)")

    check("closeButton.closes", await until(5) { out() && NativePiP.systemWindows().isEmpty })
    check("closeButton.staysAway", !backToTab && rt.call("tabs", "selected")["id"].string == other)
    rt.host.off(obs2)


    // 7. Picture in Picture by hand (⌥⌘P, the media plugin's key): a tab switch doesn't end it.
    rt.call("tabs", "select", ["id": .string(id)])
    _ = await js(rt, id, "await document.querySelector('video').play(); return true")
    _ = await until(5) { rt.media.eligibleVideo(id) != nil }
    rt.plugins.emit("media.key.pip")
    check("toggle.enters", await until(5) { inPip() && !rt.media.auto.contains(id) })
    rt.call("tabs", "select", ["id": .string(other)])
    rt.call("tabs", "select", ["id": .string(id)])
    await sleep(0.6)
    check("toggle.staysOnReturn", inPip())
    rt.plugins.emit("media.key.pip")
    check("toggle.exits", await until(5) { out() })

    // 8. A video in a cross-origin iframe.
    let emb = rt.call("tabs", "open", ["url": .string(mock.base + "/embed.html")])["id"].string ?? ""
    _ = await until(10) { rt.webviews.record(emb)?.webView?.isLoading == false }
    await sleep(1)
    if let frame = rt.webviews.record(emb)?.frames.first(where: { !$0.value.frame.isMainFrame })?.value.frame {
      _ = await js(rt, emb, "const v = document.querySelector('video'); v.muted = false; await v.play(); return true", frame: frame)
    }
    _ = await until(5) { rt.media.eligibleVideo(emb) != nil }
    rt.call("tabs", "select", ["id": .string(other)])
    check("iframe.enters", await until(5) { inPip(emb) })
    let (iframeLive, iframeD) = await advancing(emb)
    check("iframe.live", iframeLive, iframeD)
    rt.call("tabs", "select", ["id": .string(emb)])
    check("iframe.exits", await until(5) { out(emb) })
    _ = await js(rt, emb, "return true")

    // 9. A full-screen video whose Space is switched away from (a real Space switch through the
    // WindowServer: `DEN_PIP_FULLSCREEN=1`, for CI's runner, never on a desktop someone uses).
    if env["DEN_PIP_FULLSCREEN"] == "1" {
      rt.call("tabs", "select", ["id": .string(id)])
      // Full screen is for the app in front (a runner's den may not be).
      NSApp.activate(ignoringOtherApps: true)
      rt.window.window.makeKeyAndOrderFront(nil)
      await sleep(1)
      // Full screen first: the call's user gesture is short-lived (an awaited play() can outlast it).
      let res = await js(rt, id, "const v = document.querySelector('video'); const f = v.requestFullscreen(); v.play().catch(() => {}); try { await f; return 'ok'; } catch (e) { return String(e); }")

      let web = rt.webviews.record(id)?.webView
      let full = await until(10) { web?.window != nil && rt.windows.containing(web?.window) == nil }
      check("fullscreen.entered", full, "request=\(res) window=\(web?.window.map { NSStringFromClass(type(of: $0)) } ?? "none") active=\(NSApp.isActive)")
      await sleep(2)
      let spaces = Spaces.list()
      log("scenario.pip spaces \(spaces) current=\(Spaces.current())")
      if full, let fw = web?.window, let desk = spaces.first(where: { $0.type == 0 }), let fullSpace = spaces.first(where: { $0.type == 4 }) {
        Spaces.switchTo(desk)
        check("fullscreen.away.enters", await until(8) { inPip() }, "occluded=\(!fw.occlusionState.contains(.visible)) current=\(Spaces.current()) \(pipWindow()?.text ?? "")")
        let (l, d) = await advancing()
        check("fullscreen.away.live", l, d)
        frameCheck("fullscreen")
        Spaces.switchTo(fullSpace)
        check("fullscreen.back.exits", await until(8) { out() }, "current=\(Spaces.current())")
      } else if full {
        // WebKit's full-screen window shares the desktop's Space here (no Space of its own to leave).
        log("scenario.pip fullscreen.spaceSwitch skipped: no full-screen Space (spaces \(spaces))")
      }
      if full {

        _ = await js(rt, id, "await document.exitFullscreen().catch(() => {}); return true")
        _ = await until(8) { rt.windows.containing(web?.window) != nil }
        await sleep(1)
      }
      _ = rt.call("media", "exit")
      _ = await until(5) { out() }
    }

    // 9b. Real pages (`DEN_PIP_YOUTUBE`, a YouTube watch page with Shields and its YouTube
    // scriptlets on as they ship; `DEN_PIP_MSE`, a Media Source Extensions player whose video
    // size arrives after it starts playing): a tab switch and an app switch. A player that
    // never gets a source on this machine (YouTube's bot check on a datacenter IP) is said so,
    // not counted.
    for (label, key) in [("youtube", "DEN_PIP_YOUTUBE"), ("mse", "DEN_PIP_MSE")] {
      guard let url = env[key] else { continue }
      let y = rt.call("tabs", "open", ["url": .string(url)])["id"].string ?? ""
      _ = await until(30) { rt.webviews.record(y)?.webView?.isLoading == false }
      await sleep(5)
      let videoFrame = { rt.webviews.record(y)?.frames.values.first { $0.media.video != nil }?.frame }
      let played = await js(rt, y, "const v = document.querySelector('video'); if (!v) return 'no video element'; v.muted = false; v.volume = 1; try { await Promise.race([v.play(), new Promise(r => setTimeout(r, 4000))]); } catch (e) { return String(e); } return v.paused ? 'paused' : 'playing'")
      let ok = await until(20) { rt.media.eligibleVideo(y) != nil }
      let now = await js(rt, y, "const v = document.querySelector('video'); const e = document.querySelector('.ytp-error, .yt-playability-error-supported-renderers, #error-screen'); return (v ? JSON.stringify({t: v.currentTime, vw: v.videoWidth, vh: v.videoHeight, rs: v.readyState, paused: v.paused, w: v.clientWidth, h: v.clientHeight, src: String(v.currentSrc).slice(0, 50)}) : 'no video') + ' | ' + document.title + (e ? ' | error: ' + e.innerText.replace(/\\s+/g, ' ').slice(0, 160) : '')", frame: videoFrame())
      let detail = "play=\(played) why=\(rt.media.eligibility(y).why) now=\(now) shields=\(rt.call("sitepolicy", "get", ["id": .string(y)])["scripts"])"
      if !ok, now.string?.contains("\"rs\":0") == true, now.string?.contains("\"src\":\"\"") == true {
        log("scenario.pip \(label) skipped: the player got no source on this machine (\(detail))")
      } else {
        check("\(label).eligible", ok, detail)
      }
      if ok {
        rt.call("tabs", "select", ["id": .string(other)])
        check("\(label).tabSwitch.enters", await until(8) { inPip(y) }, pipWindow()?.text ?? "no PiP window")
        let (l1, d1) = await advancing(y)
        check("\(label).tabSwitch.live", l1, d1)
        frameCheck(label)
        rt.call("tabs", "select", ["id": .string(y)])
        check("\(label).tabSwitch.back", await until(8) { out(y) })
        await sleep(1)
        if await activateDen(rt), await until(3, { rt.media.windowVisible && out(y) }) {
          await sh("/usr/bin/open", ["-a", "Terminal"])
          check("\(label).appSwitch.enters", await until(8) { !NSApp.isActive && inPip(y) }, "front=\(front) covered=\(String(format: "%.0f%%", covered(rt) * 100)) \(pipWindow()?.text ?? "no PiP window")")
          let (l2, d2) = await advancing(y)
          check("\(label).appSwitch.live", l2, d2)
          let back = await activateDen(rt)
          let gone = await until(8) { out(y) }
          check("\(label).appSwitch.back", back && gone)
          await quitApp("Terminal")
        } else {
          log("scenario.pip \(label).appSwitch skipped: den isn't in front (front=\(front))")
        }
      }
      _ = await js(rt, y, "document.querySelectorAll('video').forEach(v => v.pause()); return true", frame: videoFrame())
      _ = rt.call("media", "exit")
      _ = await until(5) { out(y) }
      rt.call("tabs", "select", ["id": .string(other)])
    }

    // 10. The setting turns it off.
    rt.call("media", "settings", ["autoPip": false])
    rt.call("tabs", "select", ["id": .string(id)])
    _ = await until(5) { rt.webviews.record(id)?.videoFrame != nil }
    rt.call("tabs", "select", ["id": .string(other)])
    await sleep(1)
    check("setting.off", out() && NativePiP.systemWindows().isEmpty, "active=\(rt.media.active.sorted()) windows=\(NativePiP.systemWindows().count)")

    rt.call("media", "settings", ["autoPip": true])

    log("scenario.done ok=\(allOK)")
    exit(allOK ? 0 : 1)
  }
}

/// Mission Control's Spaces, through the WindowServer's private API (what Space-switching tools
/// use). Scenario-only: it changes which Space the display shows.
@MainActor
enum Spaces {
  struct Space: CustomStringConvertible {
    let id: UInt64, type: Int, display: String
    var description: String { "\(id):\(type)" }
  }
  @_silgen_name("CGSMainConnectionID") static func mainConnection() -> Int32
  @_silgen_name("CGSCopyManagedDisplaySpaces") static func copySpaces(_ cid: Int32) -> Unmanaged<CFArray>?
  @_silgen_name("CGSManagedDisplaySetCurrentSpace") static func setCurrent(_ cid: Int32, _ display: CFString, _ space: UInt64)

  static func displays() -> [[String: Any]] { copySpaces(mainConnection())?.takeRetainedValue() as? [[String: Any]] ?? [] }

  /// Every Space: `type` 0 a desktop, 4 a full-screen app's.
  static func list() -> [Space] {
    displays().flatMap { d -> [Space] in
      let display = d["Display Identifier"] as? String ?? "Main"
      return (d["Spaces"] as? [[String: Any]] ?? []).compactMap { s in
        guard let id = (s["ManagedSpaceID"] as? NSNumber)?.uint64Value else { return nil }
        return Space(id: id, type: (s["type"] as? NSNumber)?.intValue ?? -1, display: display)
      }
    }
  }

  static func current() -> String {
    displays().compactMap { ($0["Current Space"] as? [String: Any])?["ManagedSpaceID"].map { "\($0)" } }.joined(separator: ",")
  }

  static func switchTo(_ s: Space) { setCurrent(mainConnection(), s.display as CFString, s.id) }
}

#endif
