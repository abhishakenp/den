import AppKit
import CordisValue
import Foundation
import DenTestSupport
import Testing
import WebKit

@testable import DenHost

/// Picture in picture (WebKit's native PiP, the system window Safari uses) and the page's
/// media/form reports, on a local page playing Tests/Fixtures/test-video.mp4 from MockServices
/// (no network). den has no player window of its own.
@MainActor
@Suite(.serialized, .watchdog)
struct MediaTests {
  static func served() throws -> MockServices {
    let mock = MockServices()
    try mock.start()
    let video = try #require(MediaScenarios.fixture())
    mock.files = [
      "/v.html": ("text/html", Data("<title>V</title><video src='/v.mp4' style='width:640px' loop></video><input id=i>".utf8)),
      "/v.mp4": ("video/mp4", video),
    ]
    return mock
  }

  func wait(_ s: Double = 20, line: UInt = #line, _ cond: () -> Bool) async -> Bool {
    await Wait.until("a condition", seconds: s, line: line) { cond() }
  }

  /// Before a PiP test: the previous test's system PiP window has finished closing (PiP is
  /// system-wide, so a lingering one would be the window this test's buttons and checks find).
  func noPipLeft(line: UInt = #line) async {
    #expect(await Wait.until("no PiP window left from an earlier test", seconds: 15, line: line) { NativePiP.systemWindows().isEmpty })
  }

  /// After a PiP test: out of PiP, and the system window gone, so the next test starts clean.
  func closePip(_ rt: DenRuntime, line: UInt = #line) async {
    if !rt.media.active.isEmpty { _ = rt.call("media", "exit") }
    _ = await Wait.until("PiP closed at the end of the test", seconds: 15, line: line) { rt.media.active.isEmpty && NativePiP.systemWindows().isEmpty }
  }

  /// The PiP window is up with its buttons wired to WebKit and done opening: it appears a moment
  /// after WebKit's delegate says the video entered, then animates; its frame unchanged across
  /// two looks 150 ms apart means the animation is over.
  func pipButtonsReady(_ selector: String, line: UInt = #line) async -> Bool {
    var last = ""
    return await Wait.until("the PiP window's \(selector) button, opened", seconds: 15, every: .milliseconds(150), line: line) {
      guard MediaScenarios.pipButtonsReady(selector), let w = NativePiP.systemWindows().first else { return false }
      let frame = "\(w[kCGWindowBounds as String] ?? "")"
      defer { last = frame }
      return frame == last
    }
  }

  @Test func rangeRequestsAnswer206() throws {
    let mock = MockServices()
    let r = mock.file("video/mp4", Data(0..<100), range: "bytes=10-19")
    #expect(r.0 == 206 && r.2 == Data(10..<20) && r.1.contains { $0 == ("Content-Range", "bytes 10-19/100") })
    #expect(mock.file("video/mp4", Data(0..<100), range: "bytes=90-").2 == Data(90..<100))
    #expect(mock.file("video/mp4", Data(0..<100), range: nil).0 == 200)
  }

  /// Leaving a tab whose video plays with sound puts that video in WebKit's picture in picture
  /// (WebKit's delegate says so, and the system PiP window is on screen); it keeps playing there
  /// and the page can't be discarded; coming back takes it out, still playing. The old mini
  /// player is gone: no den window or panel ever holds the web view.
  @Test func tabSwitchUsesNativePictureInPicture() async throws {
    let rt = ServiceTests.runtime()
    rt.window.window.orderFront(nil)
    defer { rt.window.window.orderOut(nil) }
    await noPipLeft()
    let mock = try Self.served()
    let id = rt.call("webviews", "create", ["id": "v", "url": .string(mock.base + "/v.html")])["id"].string!
    let other = rt.call("webviews", "create", ["id": "o"])["id"].string!
    _ = rt.call("content", "show", ["panes": [.string(id)]])
    let web = try #require(rt.webviews.record(id)?.webView)
    #expect(await wait { !web.isLoading && web.url != nil })
    _ = await Wait.asyncJS(web, "const v = document.querySelector('video'); v.muted = false; await v.play(); return true")
    #expect(await wait { rt.media.eligibleVideo(id) != nil })
    #expect(rt.call("webviews", "get", ["id": .string(id)])["audio"] == true)
    // Unsaved input is reported (and keeps a page from being discarded).
    _ = await Wait.asyncJS(web, "const i = document.getElementById('i'); i.value = 'draft'; i.dispatchEvent(new Event('input')); return true")
    #expect(await wait { rt.webviews.record(id)?.media.dirty == true })
    let windowsBefore = Set(NSApp.windows.map(ObjectIdentifier.init))

    _ = rt.call("content", "show", ["panes": [.string(other)]])
    #expect(await wait(10) { rt.media.active.contains(id) }, "WebKit reports the video in PiP")
    #expect(rt.media.auto.contains(id) && rt.call("media", "get")["pip"] == [.string(id)])
    #expect(rt.call("webviews", "get", ["id": .string(id)])["media"]["pip"] == true)
    #expect(await wait(5) { !NativePiP.systemWindows().isEmpty }, "the system PiP window is on screen")
    #expect(rt.call("webviews", "suspend", ["id": .string(id)])["reason"] == "pip")
    // den drew nothing: the web view is in none of den's windows, and no window of den's own
    // appeared (PIP.framework's in-process PIPPanel is the system's).
    #expect(web.window == nil || web.window === rt.window.window)
    let added = NSApp.windows.filter { !windowsBefore.contains(ObjectIdentifier($0)) }.map { NSStringFromClass(type(of: $0)) }
    #expect(!added.contains { $0.hasPrefix("DenHost.") || $0.contains("Mini") }, "\(added)")

    // Live in PiP: the clock moves.
    let t0 = await Wait.asyncJS(web, "return document.querySelector('video').currentTime") as? Double ?? 0
    #expect(await Wait.until("the video plays on in PiP") { (await Wait.asyncJS(web, "return document.querySelector('video').currentTime") as? Double ?? 0) > t0 + 1 })

    // Back: out of PiP, inline, still playing.
    _ = rt.call("content", "show", ["panes": [.string(id)]])
    #expect(await wait(10) { !rt.media.active.contains(id) && rt.media.auto.isEmpty })
    #expect(web.superview === rt.content.card(id)?.clip)
    // WebKit's exit animation may finish after its delegate call.
    #expect(await Wait.until("inline and playing") { await Wait.asyncJS(web, "return !document.pictureInPictureElement && !document.querySelector('video').paused") as? Bool == true })
    let state = await Wait.asyncJS(web, "const v = document.querySelector('video'); return JSON.stringify({pip: !!document.pictureInPictureElement, paused: v.paused, mode: v.webkitPresentationMode})")
    print("media-test: back inline \(state ?? "nil")")


    // Away and straight back, before WebKit is in: it ends up out of PiP, inline.
    _ = rt.call("content", "show", ["panes": [.string(other)]])
    _ = rt.call("content", "show", ["panes": [.string(id)]])
    try await Task.sleep(for: .seconds(3))
    #expect(rt.media.active.isEmpty && rt.media.auto.isEmpty)
    #expect(await Wait.asyncJS(web, "return !document.pictureInPictureElement") as? Bool == true)

    // Paused: nothing to put in PiP.

    _ = await Wait.asyncJS(web, "document.querySelector('video').pause(); return true")
    #expect(await wait { rt.media.eligibleVideo(id) == nil })
    _ = rt.call("content", "show", ["panes": [.string(other)]])
    try await Task.sleep(for: .seconds(1))
    #expect(rt.media.active.isEmpty)
    // Off: not even a playing one.
    _ = rt.call("content", "show", ["panes": [.string(id)]])
    _ = await Wait.asyncJS(web, "await document.querySelector('video').play(); return true")
    #expect(rt.call("media", "settings", ["autoPip": false]) == ["autoPip": false])
    #expect(rt.call("storage", "get", ["ns": "media", "key": "settings"])["autoPip"] == false)
    _ = rt.call("content", "show", ["panes": [.string(other)]])
    try await Task.sleep(for: .seconds(1))
    #expect(rt.media.active.isEmpty)
    _ = rt.call("media", "settings", ["autoPip": true])
    await closePip(rt)
    mock.stop()
  }

  /// The PiP window's buttons, as PIP.framework calls them on WebKit (`pipShouldClose:` is the
  /// return button, `pipActionStop:` the close button): return goes back to the tab
  /// (`media.backToTab`), close pauses and stays away. And Picture in Picture by hand
  /// (`media.toggle`, ⌥⌘P) isn't undone by a tab switch, like Safari.
  @Test func pipWindowButtonsAndToggle() async throws {
    let rt = ServiceTests.runtime()
    rt.window.window.orderFront(nil)
    defer { rt.window.window.orderOut(nil) }
    await noPipLeft()
    let mock = try Self.served()
    let id = rt.call("webviews", "create", ["id": "b", "url": .string(mock.base + "/v.html")])["id"].string!
    let other = rt.call("webviews", "create", ["id": "c"])["id"].string!
    _ = rt.call("content", "show", ["panes": [.string(id)]])
    let web = try #require(rt.webviews.record(id)?.webView)
    #expect(await wait { !web.isLoading && web.url != nil })
    let play = "const v = document.querySelector('video'); v.muted = false; await v.play(); return true"
    _ = await Wait.asyncJS(web, play)
    #expect(await wait { rt.media.eligibleVideo(id) != nil })
    var back: [Value] = []
    var lines: [String] = []
    rt.media.log = { lines.append($0) }
    defer { rt.media.log = nil }
    // What the tabs plugin does: select the tab, so its web view is back in the window, where
    // WebKit puts the video back.
    _ = rt.host.on("media.backToTab") { v in
      back.append(v)
      _ = rt.call("content", "show", ["panes": [v["webview"]]])
    }


    // Return button.
    _ = rt.call("content", "show", ["panes": [.string(other)]])
    #expect(await wait(10) { rt.media.active.contains(id) })
    #expect(await pipButtonsReady("pipShouldClose:"))
    #expect(MediaScenarios.pressPipButton("pipShouldClose:"))
    #expect(await wait(10) { !rt.media.active.contains(id) })
    #expect(back == [["webview": .string(id)]])
    #expect(await Wait.asyncJS(web, "return document.querySelector('video').paused") as? Bool == false)

    // Close button.
    _ = rt.call("content", "show", ["panes": [.string(id)]])
    _ = rt.call("content", "show", ["panes": [.string(other)]])
    #expect(await wait(10) { rt.media.active.contains(id) })
    #expect(await pipButtonsReady("pipActionStop:"))
    #expect(MediaScenarios.pressPipCloseButton())
    #expect(await Wait.until("the close button pauses") { await Wait.asyncJS(web, "return document.querySelector('video').paused") as? Bool == true })
    #expect(await wait(10) { rt.media.active.isEmpty })
    #expect(back.count == 1, "the close button doesn't go back to the tab")
    // The system window finishes closing before the next one opens.
    #expect(await wait(10) { NativePiP.systemWindows().isEmpty })
    try await Task.sleep(for: .seconds(1))
    var pipEvents: [String] = []
    _ = rt.host.on("media.pip") { v in pipEvents.append("\(v.str("webview")):\(v["open"] == true ? "open" : "closed")") }


    // By hand: the focused pane's video, kept across a tab switch, toggled back out.
    _ = rt.call("content", "show", ["panes": [.string(id)]])
    _ = await Wait.asyncJS(web, play)
    #expect(await wait { rt.media.eligibleVideo(id) != nil })
    #expect(rt.call("media", "toggle") == ["webview": .string(id), "pip": true])
    #expect(await wait(10) { rt.media.active.contains(id) && !rt.media.auto.contains(id) })
    _ = rt.call("content", "show", ["panes": [.string(other)]])
    _ = rt.call("content", "show", ["panes": [.string(id)]])
    try await Task.sleep(for: .seconds(1))
    #expect(rt.media.active.contains(id), "a PiP you started stays when you come back: \(pipEvents) \(lines)")

    #expect(rt.call("media", "toggle") == ["webview": .string(id), "pip": false])
    #expect(await wait(10) { rt.media.active.isEmpty })
    #expect(rt.call("media", "toggle", ["webview": "nope"])["error"].string != nil)
    await closePip(rt)
    mock.stop()
  }

  /// The old player's failure: with the video scrolled partly or fully out of view, its window
  /// showed only what was still visible (the rest black). WebKit's PiP takes the whole video
  /// from its player, not from the page: it enters, and plays on, from a scrolled page.
  @Test func scrolledVideoEntersPictureInPicture() async throws {
    let rt = ServiceTests.runtime()
    rt.window.window.orderFront(nil)
    defer { rt.window.window.orderOut(nil) }
    await noPipLeft()
    let mock = try Self.served()
    mock.files["/tall.html"] = ("text/html", Data("<title>T</title><video src='/v.mp4' style='width:640px' loop></video><div style='height:4000px'></div>".utf8))
    let id = rt.call("webviews", "create", ["id": "s", "url": .string(mock.base + "/tall.html")])["id"].string!
    let other = rt.call("webviews", "create", ["id": "t"])["id"].string!
    _ = rt.call("content", "show", ["panes": [.string(id)]])
    let web = try #require(rt.webviews.record(id)?.webView)
    #expect(await wait { !web.isLoading && web.url != nil })
    _ = await Wait.asyncJS(web, "const v = document.querySelector('video'); v.muted = false; await v.play(); return true")
    #expect(await wait { rt.media.eligibleVideo(id) != nil })
    for y in [200, 2000] {
      _ = await Wait.asyncJS(web, "window.scrollTo(0, \(y)); return window.scrollY")
      try await Task.sleep(for: .milliseconds(400))
      _ = rt.call("content", "show", ["panes": [.string(other)]])
      #expect(await wait(10) { rt.media.active.contains(id) }, "scrolled \(y)")
      let t0 = await Wait.asyncJS(web, "return document.querySelector('video').currentTime") as? Double ?? 0
      #expect(await Wait.until("plays on in PiP, scrolled \(y)") { (await Wait.asyncJS(web, "return document.querySelector('video').currentTime") as? Double ?? 0) > t0 + 1 })
      _ = rt.call("content", "show", ["panes": [.string(id)]])
      #expect(await wait(10) { rt.media.active.isEmpty })
    }
    await closePip(rt)
    mock.stop()
  }

  /// Switching to another app (den resigns active) puts the video in PiP at once, even with
  /// den's window still showing; the window staying in sight doesn't take it back out while
  /// another app is in front; den active again does. In a split, the pane playing video goes,
  /// not the focused blank one. Each decision is a log line, with the reason when it's no.
  /// (The real notifications: `--scenario pip` on CI, with Terminal and other apps in front.)
  @Test func appSwitchEntersAndComingBackExits() async throws {
    let rt = ServiceTests.runtime()
    rt.window.window.orderFront(nil)
    defer { rt.window.window.orderOut(nil) }
    await noPipLeft()
    let mock = try Self.served()
    let id = rt.call("webviews", "create", ["id": "a", "url": .string(mock.base + "/v.html")])["id"].string!
    let other = rt.call("webviews", "create", ["id": "b"])["id"].string!
    _ = rt.call("content", "show", ["panes": [.string(other), .string(id)], "focus": .string(other)])
    let web = try #require(rt.webviews.record(id)?.webView)
    #expect(await wait { !web.isLoading && web.url != nil })
    var lines: [String] = []
    rt.media.log = { lines.append($0) }
    // The test window is never really on screen (Invisible): say it's in sight, behind the other app.
    rt.media.windowVisibleForTests = true
    defer { rt.media.windowVisibleForTests = nil }
    _ = await Wait.asyncJS(web, "const v = document.querySelector('video'); v.muted = true; await v.play(); return true")
    #expect(await wait { rt.media.eligibility(id).why == "video muted" })
    rt.media.appActiveChanged(false)
    #expect(rt.media.active.isEmpty && lines.contains("pip appSwitch \(id): skip, video muted"), "\(lines)")
    _ = await Wait.asyncJS(web, "document.querySelector('video').muted = false; return true")
    #expect(await wait { rt.media.eligibleVideo(id) != nil })
    #expect(rt.media.awayTarget() == id)

    rt.media.appActiveChanged(false)
    #expect(await wait(10) { rt.media.active.contains(id) }, "\(lines)")
    #expect(rt.media.auto.contains(id))
    #expect(lines.contains { $0.hasPrefix("pip appSwitch \(id): enter") }, "\(lines)")
    // The page's requestPictureInPicture() promise can resolve after WebKit's delegate reports the
    // video in PiP (CI run 37286259254): its log line is awaited, not expected to be there already.
    #expect(await wait(10) { lines.contains { $0.hasPrefix("pip enter \(id): js(main) -> true") } }, "\(lines)")
    #expect(lines.contains("pip webkit \(id): in (auto)") || lines.contains("pip webkit \(id): in (auto) systemWindow"), "\(lines)")
    // The window is in sight (another app in front of part of it): it stays in PiP.
    rt.media.evaluateWindow()
    try await Task.sleep(for: .milliseconds(600))
    #expect(rt.media.active.contains(id))
    // den active again: back inline, playing.
    rt.media.appActiveChanged(true)
    #expect(await wait(10) { rt.media.active.isEmpty && rt.media.auto.isEmpty }, "\(lines)")
    #expect(await Wait.until("inline and playing") { await Wait.asyncJS(web, "return !document.pictureInPictureElement && !document.querySelector('video').paused") as? Bool == true })
    print("media-test: appSwitch log\n" + lines.joined(separator: "\n"))
    rt.media.log = nil
    await closePip(rt)
    mock.stop()
  }

  /// What the page last reported can be out of date (a video made bigger without any media
  /// event): den asks the page for a fresh report and decides again, instead of skipping it.
  @Test func staleReportIsRefreshedBeforeSkipping() async throws {
    let rt = ServiceTests.runtime()
    rt.window.window.orderFront(nil)
    defer { rt.window.window.orderOut(nil) }
    await noPipLeft()
    let mock = try Self.served()
    let id = rt.call("webviews", "create", ["id": "f", "url": .string(mock.base + "/v.html")])["id"].string!
    _ = rt.call("content", "show", ["panes": [.string(id)]])
    let web = try #require(rt.webviews.record(id)?.webView)
    #expect(await wait { !web.isLoading && web.url != nil })
    var lines: [String] = []
    rt.media.log = { lines.append($0) }
    defer { rt.media.log = nil }
    _ = await Wait.asyncJS(web, "const v = document.querySelector('video'); v.style.width = '120px'; v.muted = false; await v.play(); return true")
    #expect(await wait { rt.media.eligibility(id).why.hasPrefix("small") })
    _ = await Wait.asyncJS(web, "document.querySelector('video').style.width = '640px'; return true")
    try await Task.sleep(for: .milliseconds(300))
    #expect(rt.media.eligibility(id).why.hasPrefix("small"), "nothing told den about the new size")
    rt.media.appActiveChanged(false)
    #expect(await wait(10) { rt.media.active.contains(id) }, "\(lines)")
    #expect(lines.contains { $0.hasPrefix("pip appSwitch \(id): skip, small") } && lines.contains { $0.hasPrefix("pip appSwitch \(id): enter after a fresh report") }, "\(lines)")
    _ = rt.call("media", "exit")
    #expect(await wait(10) { rt.media.active.isEmpty })
    await closePip(rt)
    mock.stop()
  }

  /// A discarded page's WKWebView is released at once (nothing in den keeps it), which is what
  /// lets WebKit end its WebContent process. The process exit itself is WebKit's timing (seconds,
  /// longer on a busy Mac): measured in the real app with `scripts/measure-memory.sh`.
  @Test func discardReleasesTheWebView() async throws {
    let rt = ServiceTests.runtime()
    let mock = try Self.served()
    let ids = (0..<2).map { rt.call("webviews", "create", ["id": .string("d\($0)"), "url": .string(mock.base + "/v.html")])["id"].string! }
    for id in ids {
      _ = rt.call("content", "show", ["panes": [.string(id)]])
      let w = try #require(rt.webviews.record(id)?.webView)
      #expect(await wait { !w.isLoading && w.url != nil })
    }
    weak var gone = rt.webviews.record(ids[0])?.webView
    #expect(gone != nil)
    #expect(rt.call("webviews", "suspend", ["id": .string(ids[0]), "force": true])["suspended"] == true)
    #expect(await wait(5) { gone == nil })
    #expect(rt.webviews.record(ids[0])?.isSuspended == true)
    mock.stop()
  }

  /// Battery saver's host half: `pauseMedia` pauses a page that is off screen and refuses one on
  /// screen; `setAutoplay` makes new pages wait for a click; `app.power` reports the power state.
  @Test func pauseMediaAutoplayAndPower() async throws {
    let rt = ServiceTests.runtime()
    rt.window.window.orderFront(nil)
    defer { rt.window.window.orderOut(nil) }
    let mock = try Self.served()
    let id = rt.call("webviews", "create", ["id": "p", "url": .string(mock.base + "/v.html")])["id"].string!
    let other = rt.call("webviews", "create", ["id": "q"])["id"].string!
    _ = rt.call("content", "show", ["panes": [.string(id)]])
    let web = try #require(rt.webviews.record(id)?.webView)
    #expect(await wait { !web.isLoading && web.url != nil })
    // Audible (WebKit already pauses muted video that isn't visible); picture in picture is off
    // so the page really goes to the background.
    _ = rt.call("media", "settings", ["autoPip": false])
    defer { _ = rt.call("media", "settings", ["autoPip": true]) }
    _ = await Wait.asyncJS(web, "const v = document.querySelector('video'); v.muted = false; await v.play(); return true")
    #expect(await wait { rt.webviews.record(id)?.media.playing == true })
    #expect(rt.call("webviews", "get", ["id": .string(id)])["media"]["audible"] == true)
    #expect(rt.call("webviews", "pauseMedia", ["id": .string(id)])["reason"] == "visible")
    _ = rt.call("content", "show", ["panes": [.string(other)]])
    #expect(await wait { web.window == nil })
    let r = rt.call("webviews", "pauseMedia", ["id": .string(id)])
    #expect(r["paused"] == true, "pauseMedia: \(r)")
    let paused = { await Wait.asyncJS(web, "return document.querySelector('video').paused", seconds: 5) as? Bool }
    #expect(await Wait.until("the background video paused") { await paused() == true })
    #expect(await wait { rt.webviews.record(id)?.media.playing == false })
    #expect(rt.call("webviews", "pauseMedia", ["id": .string(id)])["reason"] == "notPlaying")

    // Autoplay: pages created from now on need a click to play.
    #expect(rt.webviews.record(other)?.webView?.configuration.mediaTypesRequiringUserActionForPlayback != .all)
    #expect(rt.call("webviews", "setAutoplay", ["allowed": false]) == .ok)
    let third = rt.call("webviews", "create", ["id": "r"])["id"].string!
    _ = rt.call("content", "show", ["panes": [.string(third)]])
    #expect(rt.webviews.record(third)?.webView?.configuration.mediaTypesRequiringUserActionForPlayback == .all)
    _ = rt.call("webviews", "setAutoplay", ["allowed": true])

    // Power: app.state carries it, a change is an event.
    var events: [Value] = []
    _ = rt.plugins.on("app.power") { events.append($0) }
    // Tests never read the Mac's power: a fixed source, plugged in, no Low Power Mode.
    let power = try #require(rt.app.powerSource as? FixedPower)
    #expect(rt.call("app", "state")["battery"] == false && rt.call("app", "state")["lowPower"] == false)
    power.state = PowerState(battery: true, lowPower: false)
    power.state = PowerState(battery: true, lowPower: false)  // no change, no event
    power.state = PowerState(battery: true, lowPower: true)
    #expect(events.map { $0["battery"] } == [true, true] && events.map { $0["lowPower"] } == [false, true])
    #expect(rt.call("app", "state")["lowPower"] == true)
    mock.stop()
  }

  /// The custom mini player is gone for good: no player panel class in den, no isolation CSS in
  /// the page script; picture in picture is the page's standard API (WebKit's native PiP).

  @Test func noCustomPlayerLeft() {
    #expect(NSClassFromString("DenHost.MiniPlayerPanel") == nil && NSClassFromString("MiniPlayerPanel") == nil)
    #expect(!PageScripts.media.contains("den-mini") && !PageScripts.media.contains("isolate("))
    #expect(PageScripts.media.contains("requestPictureInPicture"))
  }
}

