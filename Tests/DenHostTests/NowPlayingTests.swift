import AppKit
import CordisValue
import DenTestSupport
import Foundation
import MediaPlayer
import Testing
import WebKit

@testable import DenHost

/// Now playing (the page script's Media Session report, `webviews.mediaControl`, the
/// `nowplaying` service), the side column and the sidebar dock slot.
/// Local pages from MockServices playing Tests/Fixtures/test-video.mp4 (no network).
@MainActor
@Suite(.serialized, .watchdog)
struct NowPlayingTests {
  static let sessionPage = """
    <title>Player</title><video src='/v.mp4' style='width:640px' loop></video>
    <script>
    navigator.mediaSession.metadata = new MediaMetadata({title: 'Slow Morning', artist: 'Tidal Rooms', album: 'Low Tide',
      artwork: [{src: '/art-small.png', sizes: '64x64'}, {src: '/art.png', sizes: '512x512'}]});
    window.calls = [];
    navigator.mediaSession.setActionHandler('nexttrack', () => { window.calls.push('next'); navigator.mediaSession.metadata.title = 'Track Two'; });
    navigator.mediaSession.setActionHandler('previoustrack', () => window.calls.push('previous'));
    </script>
    """

  static func served() throws -> MockServices {
    let mock = MockServices()
    try mock.start()
    let video = try #require(MediaScenarios.fixture())
    mock.files = [
      "/s.html": ("text/html", Data(sessionPage.utf8)),
      "/plain.html": ("text/html", Data("<title>Plain</title><video src='/v.mp4' style='width:640px' loop></video>".utf8)),
      "/v.mp4": ("video/mp4", video),
    ]
    return mock
  }

  func wait(_ s: Double = 20, _ what: String = "a condition", line: UInt = #line, _ cond: () -> Bool) async -> Bool {
    await Wait.until(what, seconds: s, line: line) { cond() }
  }

  /// A page shown in a pane, loaded, and playing with sound (like a click on play).
  func playing(_ rt: DenRuntime, _ mock: MockServices, _ path: String, id: String) async throws -> WKWebView {
    _ = rt.call("webviews", "create", ["id": .string(id), "url": .string(mock.base + path)])
    _ = rt.call("content", "show", ["panes": [.string(id)]])
    let web = try #require(rt.webviews.record(id)?.webView)
    #expect(await wait { !web.isLoading && web.url != nil })
    _ = await Wait.asyncJS(web, "const v = document.querySelector('video'); v.muted = false; v.volume = 1; await v.play(); return true")
    return web
  }

  @Test func mediaSessionMetadataAndActionsReachTheHost() async throws {
    let rt = ServiceTests.runtime()
    let mock = try Self.served()
    var events: [Value] = []
    let obs = rt.host.on("webviews.nowPlaying") { v in events.append(v) }
    defer { rt.host.off(obs) }
    let web = try await playing(rt, mock, "/s.html", id: "s")
    #expect(await wait(10, "now playing with metadata") { rt.webviews.record("s")?.nowPlaying?.str("title") == "Slow Morning" })
    let now = try #require(rt.webviews.record("s")?.nowPlaying)
    #expect(now.str("artist") == "Tidal Rooms" && now.str("album") == "Low Tide")
    #expect(now.str("art") == mock.base + "/art.png", "the largest artwork, as an absolute URL: \(now.str("art"))")
    #expect(now.flag("paused") == false && now.flag("video") == true)
    let acts = now.list("acts").compactMap(\.string)
    #expect(acts.contains("nexttrack") && acts.contains("previoustrack"), "acts \(acts)")
    #expect(events.last?.str("id") == "s" && events.last?["now"].str("title") == "Slow Morning")
    #expect(rt.call("webviews", "get", ["id": "s"])["media"]["now"]["title"] == "Slow Morning")

    // Next runs the page's own handler (page world); its metadata change is reported.
    #expect(rt.call("webviews", "mediaControl", ["id": "s", "action": "next"]) == .ok)
    #expect(await Wait.until("the page's nexttrack handler") { (await Wait.asyncJS(web, "return window.calls.join(',')") as? String) == "next" })
    #expect(await wait(10, "the new title") { rt.webviews.record("s")?.nowPlaying?.str("title") == "Track Two" })

    // Pause and play act on the element.
    #expect(rt.call("webviews", "mediaControl", ["id": "s", "action": "pause"]) == .ok)
    #expect(await wait(10, "paused") { rt.webviews.record("s")?.nowPlaying?.flag("paused") == true })
    #expect(rt.call("webviews", "mediaControl", ["id": "s", "action": "toggle"]) == .ok)
    #expect(await wait(10, "playing again") { rt.webviews.record("s")?.nowPlaying?.flag("paused") == false })

    // Stop: paused, and gone from now playing until it plays again.
    #expect(rt.call("webviews", "mediaControl", ["id": "s", "action": "stop"]) == .ok)
    #expect(await wait(10, "stopped") { (rt.webviews.record("s")?.nowPlaying?.isNull ?? true) })
    #expect(events.last?["now"].isNull == true)
    #expect(rt.call("webviews", "mediaControl", ["id": "s", "action": "play"]).str("error").contains("plays nothing"))
    #expect(rt.call("webviews", "mediaControl", ["id": "s", "action": "dance"]).str("error").contains("unknown media action"))
    // Closing the page: nothing playing.
    _ = rt.call("webviews", "close", ["id": "s"])
    mock.stop()
  }

  /// Without Media Session metadata: the page title, no next track, previous restarts it.
  @Test func plainMediaFallsBackToThePageTitle() async throws {
    let rt = ServiceTests.runtime()
    let mock = try Self.served()
    let web = try await playing(rt, mock, "/plain.html", id: "p")
    #expect(await wait(10, "now playing") { rt.webviews.record("p")?.nowPlaying?.str("title") == "Plain" })
    #expect(rt.webviews.record("p")?.nowPlaying?.list("acts").isEmpty == true)
    #expect(rt.call("webviews", "mediaControl", ["id": "p", "action": "next"]).str("error").contains("no next track"))
    _ = await Wait.asyncJS(web, "document.querySelector('video').currentTime = 12; return true")
    #expect(rt.call("webviews", "mediaControl", ["id": "p", "action": "previous"]) == .ok)
    #expect(await Wait.until("restarted") { ((await Wait.asyncJS(web, "return document.querySelector('video').currentTime") as? Double) ?? 99) < 5 })
    // A muted element never becomes "now playing".
    _ = rt.call("webviews", "create", ["id": "m", "url": .string(mock.base + "/plain.html")])
    _ = rt.call("content", "show", ["panes": ["m"]])
    let muted = try #require(rt.webviews.record("m")?.webView)
    #expect(await wait { !muted.isLoading && muted.url != nil })
    _ = await Wait.asyncJS(muted, "const v = document.querySelector('video'); v.muted = true; await v.play(); return true")
    #expect(await wait(10, "playing muted") { rt.webviews.record("m")?.media.playing == true })
    #expect(rt.webviews.record("m")?.nowPlaying?.isNull ?? true)
    mock.stop()
  }

  /// A phone user agent for web panels.
  @Test func mobileUserAgent() throws {
    let rt = ServiceTests.runtime()
    _ = rt.call("webviews", "create", ["id": "ua", "userAgent": "mobile"])
    let ua = try #require(rt.webviews.record("ua")?.userAgent)
    #expect(ua.contains("iPhone") && ua.contains("Mobile/") && ua.contains("Safari/604.1"), "\(ua)")
    _ = rt.call("content", "show", ["panes": ["ua"]])
    #expect(rt.webviews.record("ua")?.webView?.customUserAgent == ua)
    _ = rt.call("webviews", "create", ["id": "desk"])
    #expect(rt.webviews.record("desk")?.userAgent == nil)
  }

  @Test func nowPlayingServiceFeedsControlCenter() throws {
    let rt = ServiceTests.runtime()
    defer { _ = rt.call("nowplaying", "clear") }
    var commands: [String] = []
    let obs = rt.host.on("nowplaying.command") { v in commands.append(v.str("command")) }
    defer { rt.host.off(obs) }
    #expect(rt.call("nowplaying", "get")["active"] == false)
    rt.nowPlaying.fire("toggle")
    #expect(commands.isEmpty, "nothing registered, nothing fires")
    #expect(rt.call("nowplaying", "set", ["title": "Slow Morning", "artist": "Tidal Rooms", "duration": 214, "playing": true,
                                          "commands": ["toggle", "play", "pause", "next"]]) == .ok)
    let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
    #expect(info[MPMediaItemPropertyTitle] as? String == "Slow Morning")
    #expect(info[MPMediaItemPropertyArtist] as? String == "Tidal Rooms")
    #expect((info[MPMediaItemPropertyPlaybackDuration] as? Double) == 214)
    #expect(MPNowPlayingInfoCenter.default().playbackState == .playing)
    #expect(MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled && !MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled)
    rt.nowPlaying.fire("next")
    rt.nowPlaying.fire("previous")  // not enabled: dropped
    #expect(commands == ["next"])
    _ = rt.call("nowplaying", "set", ["title": "Slow Morning", "playing": false])
    #expect(MPNowPlayingInfoCenter.default().playbackState == .paused)
    #expect(rt.call("nowplaying", "clear") == .ok)
    #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo == nil)
    #expect(rt.call("nowplaying", "get")["active"] == false)
  }

  /// `content.side`: a web view beside the panes, the panes making room; hidden, it leaves the window.
  @Test func sideColumn() async throws {
    let rt = ServiceTests.runtime()
    _ = rt.call("webviews", "create", ["id": "tab"])
    _ = rt.call("webviews", "create", ["id": "panel", "userAgent": "mobile"])
    _ = rt.call("content", "show", ["panes": ["tab"]])
    let full = try #require(rt.content.card("tab")).frame
    #expect(rt.call("content", "side", ["webview": "panel", "width": 380]) == .ok)
    rt.window.window.contentView?.layoutSubtreeIfNeeded()
    let side = try #require(rt.content.sideIfLoaded)
    let web = try #require(rt.webviews.record("panel")?.webView)
    #expect(rt.content.sideId == "panel" && web.superview === side.card.clip)
    #expect(await wait(5, "the column open") { side.frame.width == 380 })
    let card = try #require(rt.content.card("tab")).frame
    #expect(card.minX >= 380 && card.width < full.width, "\(card) vs \(full)")
    #expect(rt.call("content", "get")["side"] == "panel")
    // The header slot.
    #expect(rt.call("ui", "set", ["slot": "side.header", "tree": ["type": "stack", "id": "h", "axis": "h", "height": 30,
                                                                   "children": [["type": "label", "text": "Chat"]]]]) == .ok)
    side.layoutSubtreeIfNeeded()
    #expect(side.header.frame.height == 30 && side.card.frame.minY > 30)
    // Tabs switch, the panel stays.
    _ = rt.call("webviews", "create", ["id": "tab2"])
    _ = rt.call("content", "show", ["panes": ["tab2"]])
    #expect(web.superview === side.card.clip)
    // Hidden: out of the window, so it can be discarded like a tab.
    #expect(rt.call("content", "side") == .ok)
    #expect(rt.content.sideId == nil && web.superview == nil)
    #expect(await wait(5, "the panes take the width back") { (rt.content.card("tab2")?.frame.minX ?? 999) < 50 })
    #expect(rt.call("webviews", "suspend", ["id": "panel"])["suspended"] == true || rt.webviews.record("panel")?.webView?.window == nil)
    #expect(rt.call("content", "side", ["webview": "nope"]).str("error").contains("no webview"))
  }

  /// `sidebar.dock`: above the footer, sized by its tree, the pager above it.
  @Test func sidebarDockSlot() throws {
    let rt = ServiceTests.runtime()
    let sv = rt.ui.sidebarView
    _ = rt.call("ui", "set", ["slot": "sidebar.footer", "tree": ["type": "row", "id": "f", "height": 50, "children": [["type": "text", "text": "x"]]]])
    sv.layoutSubtreeIfNeeded()
    let pagerBefore = sv.pager.frame.height
    #expect(sv.dock.frame.height == 0)
    #expect(rt.call("ui", "set", ["slot": "sidebar.dock", "tree": ["type": "stack", "id": "d", "fill": "panel", "radius": 10, "padding": 6,
                                                                   "children": [["type": "label", "text": "Playing"], ["type": "stack", "id": "go", "clickable": true, "height": 20, "axis": "h",
                                                                                                                      "children": [["type": "label", "text": "Go"]]]]]]) == .ok)
    sv.layoutSubtreeIfNeeded()
    #expect(sv.dock.frame.height > 20 && sv.dock.frame.maxY == sv.footer.frame.minY)
    #expect(sv.pager.frame.height < pagerBefore && sv.pager.frame.maxY <= sv.dock.frame.minY)
    _ = rt.call("ui", "set", ["slot": "sidebar.dock", "tree": .null])
    sv.layoutSubtreeIfNeeded()
    #expect(sv.dock.frame.height == 0 && sv.pager.frame.height == pagerBefore)
  }

  /// A tab row with `media` shows previous / play-pause / next while hovered, and emits `media`.
  @Test func tabRowHoverPlayback() throws {
    let rt = ServiceTests.runtime()
    var actions: [Value] = []
    let obs = rt.host.on("ui.action") { v in actions.append(v) }
    defer { rt.host.off(obs) }
    _ = rt.call("ui", "set", ["slot": "sidebar.today", "tree": ["type": "list", "id": "l", "children": [
      ["type": "tabRow", "id": "t1", "title": "Music", "icon": "sf:music.note", "selected": false, "audio": true,
       "media": ["paused": false, "next": true, "previous": false]],
    ]]])
    rt.ui.sidebarView.layoutSubtreeIfNeeded()
    func find(_ v: NSView) -> TabRowNode? {
      if let r = v as? TabRowNode { return r }
      for s in v.subviews { if let r = find(s) { return r } }
      return nil
    }
    let row = try #require(find(rt.ui.sidebarView))
    #expect(row.playPause.isHidden && row.next.isHidden, "hidden until hovered")
    row.hovering = true
    row.layoutSubtreeIfNeeded()
    #expect(!row.playPause.isHidden && !row.next.isHidden && row.previous.isHidden)
    #expect(row.playPause.icon.spec == "sf:pause.fill" && row.label.frame.maxX <= row.next.frame.minX)
    row.playPause.action()
    row.next.action()
    let media = actions.filter { $0.str("id") == "t1" && $0.str("action") == "media" }.map { $0["value"].str("action") }
    #expect(media == ["toggle", "next"])
    row.hovering = false
    #expect(row.playPause.isHidden)
  }

  /// A favorite tile with `media`: hovered, play/pause takes the icon's place; a wide tile (one
  /// favorite fills the row) also gets previous / next, a narrow one (four in a row) doesn't.
  @Test func favoriteTileHoverPlayback() throws {
    let rt = ServiceTests.runtime()
    var actions: [Value] = []
    let obs = rt.host.on("ui.action") { v in actions.append(v) }
    defer { rt.host.off(obs) }
    let tile: (String) -> Value = { id in
      ["type": "favoriteTile", "id": .string(id), "icon": "sf:music.note", "title": "Music", "audio": true,
       "media": ["paused": true, "next": true, "previous": true]]
    }
    func tiles() -> [FavoriteTileNode] {
      func walk(_ v: NSView) -> [FavoriteTileNode] { (v as? FavoriteTileNode).map { [$0] } ?? v.subviews.flatMap(walk) }
      return walk(rt.ui.sidebarView)
    }
    _ = rt.call("ui", "set", ["slot": "sidebar.favorites", "tree": ["type": "grid", "id": "g", "children": [tile("f1")]]])
    rt.ui.sidebarView.layoutSubtreeIfNeeded()
    let wide = try #require(tiles().first)
    #expect(wide.media.playPause.isHidden && !wide.icon.isHidden, "hidden until hovered")
    wide.hovering = true
    wide.layoutSubtreeIfNeeded()
    #expect(!wide.media.playPause.isHidden && !wide.media.next.isHidden && !wide.media.previous.isHidden && wide.icon.isHidden)
    #expect(wide.media.playPause.icon.spec == "sf:play.fill" && wide.media.playPause.toolTip == "Play")
    #expect(wide.media.previous.frame.maxX <= wide.media.playPause.frame.minX && wide.media.playPause.frame.maxX <= wide.media.next.frame.minX)
    #expect(abs(wide.media.playPause.frame.midX - wide.bounds.midX) < 1)
    wide.media.playPause.action()
    wide.media.next.action()
    let media = actions.filter { $0.str("id") == "f1" && $0.str("action") == "media" }.map { $0["value"].str("action") }
    #expect(media == ["toggle", "next"])
    wide.hovering = false
    #expect(wide.media.playPause.isHidden && !wide.icon.isHidden)

    _ = rt.call("ui", "set", ["slot": "sidebar.favorites", "tree": ["type": "grid", "id": "g", "children": .array(["a", "b", "c", "d"].map(tile))]])
    rt.ui.sidebarView.layoutSubtreeIfNeeded()
    let narrow = try #require(tiles().first { $0.node.str("id") == "a" })
    #expect(narrow.bounds.width < FavoriteTileNode.skipsWidth)
    narrow.hovering = true
    narrow.layoutSubtreeIfNeeded()
    #expect(!narrow.media.playPause.isHidden && narrow.media.next.isHidden && narrow.media.previous.isHidden)
    #expect(narrow.bounds.contains(narrow.media.playPause.frame))
  }
}
