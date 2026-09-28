import AppKit
import CordisValue
import Foundation
import DenTestSupport
import Testing
import WebKit

@testable import DenHost

/// The mini player and the page's media/form reports, on a local page playing
/// Tests/Fixtures/test-video.mp4 from MockServices (no network).
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

  @Test func rangeRequestsAnswer206() throws {
    let mock = MockServices()
    let r = mock.file("video/mp4", Data(0..<100), range: "bytes=10-19")
    #expect(r.0 == 206 && r.2 == Data(10..<20) && r.1.contains { $0 == ("Content-Range", "bytes 10-19/100") })
    #expect(mock.file("video/mp4", Data(0..<100), range: "bytes=90-").2 == Data(90..<100))
    #expect(mock.file("video/mp4", Data(0..<100), range: nil).0 == 200)
  }

  @Test func miniPlayerFollowsTheVideoOnTabSwitch() async throws {
    let rt = ServiceTests.runtime()
    rt.window.window.orderFront(nil)
    defer { rt.window.window.orderOut(nil) }
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

    _ = rt.call("content", "show", ["panes": [.string(other)]])
    #expect(rt.media.playerId == id)
    #expect(web.window === rt.media.panel)
    #expect(rt.call("webviews", "suspend", ["id": .string(id)])["reason"] == "media")
    let isolated = { await Wait.asyncJS(web, "return document.documentElement.classList.contains('den-mini')", seconds: 5) as? Bool }
    #expect(await Wait.until("the page isolated in the mini player") { await isolated() == true })
    #expect(rt.call("media", "control", ["action": "pause"]) == .ok)
    #expect(await wait { rt.media.panel?.player.controls.paused == true })

    // Back: inline again, isolation undone, the player gone.
    _ = rt.call("content", "show", ["panes": [.string(id)]])
    #expect(rt.media.playerId == nil && rt.media.panel == nil)
    #expect(web.superview === rt.content.card(id)?.clip)
    #expect(await Wait.until("the page back inline") { await isolated() == false })
    // Paused: nothing to follow.
    _ = rt.call("content", "show", ["panes": [.string(other)]])
    #expect(rt.media.playerId == nil)
    mock.stop()
  }

  /// The controls darken the top and bottom edges (scrims) so white controls read over video.
  @Test func controlsDrawScrims() throws {
    let v = MiniControlsView(frame: NSRect(x: 0, y: 0, width: 400, height: 225))
    v.layoutSubtreeIfNeeded()
    let rep = try #require(v.bitmapImageRepForCachingDisplay(in: v.bounds))
    v.cacheDisplay(in: v.bounds, to: rep)
    let top = rep.colorAt(x: 200 * Int(rep.pixelsWide) / 400, y: 2)?.alphaComponent ?? 0
    // Sample in points, not pixels: 82 pt from the top is between the scrims (0–60 pt, 141–225 pt)
    // at any backing scale (a fixed pixel offset landed inside the top scrim on 1x displays).
    let mid = rep.colorAt(x: 150 * Int(rep.pixelsWide) / 400, y: 82 * rep.pixelsHigh / 225)?.alphaComponent ?? 1
    let bottom = rep.colorAt(x: 200 * Int(rep.pixelsWide) / 400, y: rep.pixelsHigh - 2)?.alphaComponent ?? 0
    #expect(top > 0.4 && bottom > 0.4 && mid < 0.05, "top \(top) mid \(mid) bottom \(bottom)")
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
    // Muted, so the mini player leaves it alone.
    _ = await Wait.asyncJS(web, "const v = document.querySelector('video'); v.muted = true; await v.play(); return true")
    #expect(await wait { rt.webviews.record(id)?.media.playing == true })
    #expect(rt.call("webviews", "get", ["id": .string(id)])["media"]["audible"] == false)
    #expect(rt.call("webviews", "pauseMedia", ["id": .string(id)])["reason"] == "visible")
    _ = rt.call("content", "show", ["panes": [.string(other)]])
    #expect(await wait { web.window == nil })
    #expect(rt.call("webviews", "pauseMedia", ["id": .string(id)])["paused"] == true)
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
    let state = rt.call("app", "state")
    #expect(state["battery"].bool != nil && state["lowPower"].bool != nil)
    rt.app.powerOverride = PowerState(battery: true, lowPower: false)
    rt.app.powerOverride = PowerState(battery: true, lowPower: false)  // no change, no event
    rt.app.powerOverride = PowerState(battery: true, lowPower: true)
    #expect(events.map { $0["battery"] } == [true, true] && events.map { $0["lowPower"] } == [false, true])
    #expect(rt.call("app", "state")["lowPower"] == true)
    mock.stop()
  }

  @Test func playerGeometry() {
    let vf = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let f = MiniPlayerPanel.frame(corner: .bottomRight, size: NSSize(width: 400, height: 225), in: vf)
    #expect(f == NSRect(x: 1024, y: 16, width: 400, height: 225))
    #expect(MiniPlayerPanel.nearestCorner(NSRect(x: 100, y: 700, width: 300, height: 150), in: vf) == .topLeft)
    #expect(MiniPlayerPanel.nearestCorner(f, in: vf) == .bottomRight)
    #expect(MiniControlsView.clock(65) == "1:05" && MiniControlsView.clock(3723) == "1:02:03")
    #expect(MiniControlsView.rateText(1.5) == "1.5×" && MiniControlsView.rateText(2) == "2×")
  }
}
