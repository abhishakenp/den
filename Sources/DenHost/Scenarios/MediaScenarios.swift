import AppKit
import CordisValue
import WebKit

/// `--scenario` runs for the mini player, in the real app with the demo tabs (they need the tabs
/// plugin). A local page plays `Tests/Fixtures/test-video.mp4` from `MockServices` (byte ranges,
/// no network), started through `callAsyncJavaScript` like a click would.
///
/// - `mini`: opens the video tab, plays it, switches to another tab: the mini player opens and
///   stays (for `--snapshot`, memory and CPU measurements). Prints `scenario.ready …`.
/// - `miniPlayer`: the whole check list, through the real code paths: tab switch, controls
///   (play/pause, seek, skip, volume, mute, speed), back to the tab (position kept, still
///   playing), den hidden / deactivated / minimized / window ordered out and back, a close that
///   is remembered, a video inside a cross-origin iframe, and the setting. One line per check
///   (`scenario.mini <name> ok=…`), then `scenario.done ok=…`, and it exits 0 or 1.
/// - `miniURL`: like `mini` with `DEN_MINI_URL` (e.g. a YouTube watch page), for manual checks.
@MainActor
public enum MediaScenarios {
  public static let names = ["mini", "miniOff", "miniInline", "miniPlayer", "miniURL"]

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
    p{max-width:640px;color:#555;line-height:1.5}</style></head>
    <body><h1>Test video</h1><p>A local page with a 30 s video. Switch to another tab while it plays and it follows you in den's mini player.</p>
    <video src="/test-video.mp4" controls playsinline loop></video>
    <p>Everything else on this page is hidden while the mini player shows the video.</p></body></html>
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

  static func run(_ name: String, _ rt: DenRuntime) async {
    let mock = MockServices()
    try? mock.start()
    guard let video = fixture() else { log("scenario.mini fixture missing"); exit(1) }
    mock.files = [
      "/video.html": ("text/html; charset=utf-8", Data(page.utf8)), "/test-video.mp4": ("video/mp4", video),
      "/embed.html": ("text/html; charset=utf-8", Data("<!doctype html><title>Embedded Video</title><body style='margin:0;padding:30px;background:#fff'><h2>Embed</h2><iframe src='http://localhost:\(mock.port)/video.html' width=760 height=560 style='border:0' allow='autoplay; picture-in-picture'></iframe></body>".utf8)),
    ]
    let url = name == "miniURL" ? (ProcessInfo.processInfo.environment["DEN_MINI_URL"] ?? "https://www.youtube.com") : mock.base + "/video.html"
    let other = rt.call("tabs", "selected")["id"].string ?? ""
    let id = rt.call("tabs", "open", ["url": .string(url)])["id"].string ?? ""
    var allOK = true
    func check(_ what: String, _ ok: Bool, _ detail: String = "") {
      allOK = allOK && ok
      log("scenario.mini \(what) ok=\(ok)\(detail.isEmpty ? "" : " " + detail)")
    }
    func probe() async -> Value { await js(rt, id, "return window.__denMedia.probe()", frame: rt.webviews.record(id)?.videoFrame?.frame) }
    func isolated() async -> Bool {
      await js(rt, id, "return document.documentElement.classList.contains('den-mini')", frame: rt.webviews.record(id)?.videoFrame?.frame) == true
    }
    func startVideo() async -> Bool {
      _ = await until(20) { rt.webviews.record(id)?.webView?.isLoading == false }
      await sleep(name == "miniURL" ? 3 : 0.3)
      // Like a click on play: callAsyncJavaScript runs with a user gesture.
      _ = await js(rt, id, "const v = document.querySelector('video'); if (!v) return false; v.muted = false; v.volume = 1; await v.play().catch(() => {}); return !v.paused", frame: nil)
      return await until(10) { rt.media.eligibleVideo(id) != nil }
    }

    check("playing", await startVideo(), rt.webviews.record(id)?.videoFrame?.media.video.map { "video=\($0.num("vw"))x\($0.num("vh")) dur=\($0.num("dur"))" } ?? "")
    if name == "miniInline" {
      // The same video playing inline, for the mini player's memory/CPU baseline.
      await sleep(3)
      log("scenario.ready inline t=\((await probe()).num("t"))")
      return
    }
    // 1. Switch away from the tab. (`miniOff`: the same with the setting off, the mini player's
    // memory/CPU baseline: the video keeps playing in its hidden tab.)
    if name == "miniOff" {
      rt.call("media", "settings", ["autoMiniPlayer": false])
      rt.call("tabs", "select", ["id": .string(other)])
      await sleep(3)
      log("scenario.ready off t=\((await probe()).num("t")) mini=\(rt.media.playerId ?? "-")")
      return
    }
    rt.call("tabs", "select", ["id": .string(other)])
    check("tabSwitch.opens", rt.media.playerId == id && rt.media.panel?.isVisible == true)
    _ = await until(3) { false }  // let isolation apply and a few frames play
    check("tabSwitch.isolated", await isolated())
    if name != "miniPlayer" {
      rt.media.panel?.player.showControls(true, animated: false)
      let p = await probe()
      log("scenario.ready mini=\(rt.media.playerId ?? "-") t=\(p.num("t")) paused=\(p.flag("paused")) frame=\(rt.media.panel.map { NSStringFromRect($0.frame) } ?? "-")")
      return
    }

    // 2. Controls, through the same entry point as the panel's buttons.
    rt.call("media", "control", ["action": "pause"])
    await sleep(0.4)
    check("control.pause", (await probe()).flag("paused"))
    check("control.pause.ui", rt.media.panel?.player.controls.paused == true)
    rt.call("media", "control", ["action": "toggle"])
    await sleep(0.4)
    check("control.play", !(await probe()).flag("paused"))
    rt.call("media", "control", ["action": "seek", "value": 12])
    await sleep(0.5)
    let t12 = (await probe()).num("t")
    check("control.seek", t12 >= 11.9 && t12 < 14, "t=\(t12)")
    rt.call("media", "control", ["action": "skip", "value": 10])
    await sleep(0.5)
    let t22 = (await probe()).num("t")
    check("control.skip", t22 >= 21.9 && t22 < 24.5, "t=\(t22)")
    rt.call("media", "control", ["action": "skip", "value": -10])
    await sleep(0.3)
    rt.call("media", "control", ["action": "volume", "value": 0.4])
    await sleep(0.3)
    check("control.volume", abs((await probe()).num("vol") - 0.4) < 0.01)
    rt.call("media", "control", ["action": "mute", "value": 1])
    await sleep(0.3)
    check("control.mute", (await probe()).flag("muted") && rt.media.panel?.player.controls.muted == true)
    rt.call("media", "control", ["action": "mute", "value": 0])
    rt.call("media", "control", ["action": "volume", "value": 1])
    rt.call("media", "control", ["action": "rate", "value": 1.5])
    await sleep(0.3)
    check("control.rate", (await probe()).num("rate") == 1.5 && rt.media.panel?.player.controls.speed.title == "1.5×")
    rt.call("media", "control", ["action": "rate", "value": 1])
    // Keyboard: space toggles.
    if let p = rt.media.panel {
      let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: p.windowNumber, context: nil,
                               characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
      p.keyDown(with: e)
      await sleep(0.3)
      check("key.space", (await probe()).flag("paused"))
      p.keyDown(with: e)
      await sleep(0.3)
      check("key.space.again", !(await probe()).flag("paused"))
    }
    let before = (await probe()).num("t")
    await sleep(1)

    // 3. Back to the tab: inline, same position, still playing.
    rt.call("tabs", "select", ["id": .string(id)])
    let web = rt.webviews.record(id)?.webView
    check("back.closes", rt.media.playerId == nil && rt.media.panel == nil)
    check("back.inline", web?.superview === rt.content.card(id)?.clip)
    await sleep(0.4)
    let after = await probe()
    check("back.position", after.num("t") >= before + 0.5 && after.num("t") < before + 3, "before=\(before) after=\(after.num("t"))")
    check("back.playing", !after.flag("paused"))
    check("back.unisolated", !(await isolated()))

    // 4. den away: hidden, deactivated, minimized, window ordered out; and back.
    let debounce = rt.media.debounce
    func away(_ what: String, _ go: () -> Void, _ back: () -> Void) async {
      // Another app (or another den) may have taken the focus: this check needs den in front.
      guard await until(3, { rt.media.windowVisible && rt.media.playerId == nil }) else {
        log("scenario.mini \(what) skipped: den's window isn't in front (resignedActive=\(!NSApp.isActive))")
        return
      }
      let t0 = Date()
      go()
      let opened = await until(3) { rt.media.playerId == id }
      check("\(what).opens", opened && rt.media.fromWindow, String(format: "after=%.0fms", Date().timeIntervalSince(t0) * 1000))
      await sleep(0.6)
      let tBack = Date()
      back()
      // macOS activation is cooperative: a den started by a script may not get activation back
      // after `unhide` + `activate()` while another app is in front (a click on den would). Then
      // the notification AppKit sends on activation is posted, and says so.
      if what == "hide" {
        await sleep(0.3)
        if !NSApp.isActive {
          log("scenario.mini hide: macOS didn't reactivate den within 300 ms; posting didBecomeActive")
          NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        }
      }
      let returned = await until(3) { rt.media.playerId == nil && web?.superview === rt.content.card(id)?.clip }
      check("\(what).returns", returned, String(format: "after=%.0fms", Date().timeIntervalSince(tBack) * 1000))
      check("\(what).playing", !(await probe()).flag("paused"))
      await sleep(0.4)
    }
    let w = rt.window.window
    await away("hide", { NSApp.hide(nil) }, { NSApp.unhide(nil); NSApp.activate() })
    // ⌘-Tab to another app: den can't make another app active here (and must not drive one), and
    // NSApp.deactivate() is undone by macOS at once when no other app takes over, so the two
    // notifications AppKit sends for it are posted; the observers and everything after are real.
    let nc = NotificationCenter.default
    await away("resignActive", { nc.post(name: NSApplication.didResignActiveNotification, object: NSApp) },
               { nc.post(name: NSApplication.didBecomeActiveNotification, object: NSApp) })
    await away("miniaturize", { w.miniaturize(nil) }, { w.deminiaturize(nil); NSApp.activate() })
    await away("orderOut", { w.orderOut(nil) }, { w.makeKeyAndOrderFront(nil); NSApp.activate() })
    // A quick away-and-back inside the debounce never opens the player.
    var flickered = false
    _ = await until(3) { rt.media.windowVisible }
    let obs = rt.host.on("media.miniPlayer") { _ in flickered = true }
    w.orderOut(nil)
    await sleep(debounce * 0.4)
    w.makeKeyAndOrderFront(nil)
    await sleep(debounce + 0.4)
    rt.host.off(obs)
    check("debounce.noFlicker", !flickered && rt.media.playerId == nil)
    log(String(format: "scenario.mini notifications %@", rt.media.lastNotifications.map { "\($0.0.replacingOccurrences(of: "NSApplication", with: "").replacingOccurrences(of: "NSWindow", with: "").replacingOccurrences(of: "Notification", with: ""))@\(Int(($0.1 - (rt.media.lastNotifications.first?.1 ?? 0)) * 1000))" }.joined(separator: " ")))

    // 5. Close: pauses, and the same video doesn't reopen it this session.
    rt.call("tabs", "select", ["id": .string(other)])
    check("again.opens", rt.media.playerId == id)
    rt.call("media", "close")
    await sleep(0.4)
    check("close.pauses", (await probe()).flag("paused") && rt.media.playerId == nil)
    rt.call("tabs", "select", ["id": .string(id)])
    _ = await js(rt, id, "await document.querySelector('video').play(); return true")
    _ = await until(3) { rt.webviews.record(id)?.videoFrame?.media.video?.flag("paused") == false }
    rt.call("tabs", "select", ["id": .string(other)])
    check("close.remembered", rt.media.playerId == nil)

    // 6. A video in a cross-origin iframe.
    let emb = rt.call("tabs", "open", ["url": .string(mock.base + "/embed.html")])["id"].string ?? ""
    _ = await until(10) { rt.webviews.record(emb)?.webView?.isLoading == false }
    await sleep(1)
    if let frame = rt.webviews.record(emb)?.frames.first(where: { !$0.value.frame.isMainFrame })?.value.frame {
      _ = await js(rt, emb, "const v = document.querySelector('video'); v.muted = false; await v.play(); return true", frame: frame)
    }
    _ = await until(5) { rt.media.eligibleVideo(emb) != nil }
    rt.call("tabs", "select", ["id": .string(other)])
    check("iframe.opens", rt.media.playerId == emb)
    await sleep(1)
    let frameIsolated = await js(rt, emb, "return document.querySelector('iframe').hasAttribute('data-den-mini') && document.documentElement.classList.contains('den-mini')")
    check("iframe.isolated", frameIsolated == true)
    rt.call("tabs", "select", ["id": .string(emb)])
    await sleep(0.4)
    let frameRestored = await js(rt, emb, "return !document.querySelector('[data-den-mini]') && !document.documentElement.classList.contains('den-mini')")
    check("iframe.restored", frameRestored == true)
    _ = await js(rt, emb, "return true")

    // 7. The setting turns it off.
    rt.call("media", "settings", ["autoMiniPlayer": false])
    rt.call("tabs", "select", ["id": .string(other)])
    check("setting.off", rt.media.playerId == nil)
    rt.call("media", "settings", ["autoMiniPlayer": true])

    log("scenario.done ok=\(allOK)")
    exit(allOK ? 0 : 1)
  }
}
