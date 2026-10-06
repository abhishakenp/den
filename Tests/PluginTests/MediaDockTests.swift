import AppKit
import CordisValue
import DenTestSupport
import Testing

@testable import DenHost
@testable import PluginCores

/// The `media` plugin's now-playing dock and Control Center entry, driven by the host's
/// `webviews.nowPlaying` events (what the page script sends), and the tab row's hover buttons.
@MainActor
@Suite(.serialized, .watchdog)
struct MediaDockTests {
  /// Starts the core with `webviews.mediaControl` / `setMuted` / `setVolume` / `setRate` /
  /// `tabs.select` recorded (the fake ids have no pages).
  final class Calls { var list: [(String, Value)] = [] }

  @discardableResult
  func start(_ h: Harness, _ calls: Calls) -> MediaCore {
    let base = h.env
    var env = base
    env.invoke = { s, m, a in
      if (s == "webviews" && (m == "mediaControl" || m == "setMuted" || m == "setVolume" || m == "setRate"))
        || (s == "tabs" && m == "select") || s == "media" {
        calls.list.append((s + "." + m, a))
        return ["ok": true]
      }
      return base.invoke(s, m, a)
    }
    let core = MediaCore(env: env)
    core.start()
    return core
  }

  func now(_ title: String, paused: Bool = false, next: Bool = false, video: Bool = false, vol: Double = 1, rate: Double = 1) -> Value {
    ["title": .string(title), "artist": "Artist", "album": "", "art": "", "paused": .bool(paused), "dur": 200, "video": .bool(video),
     "acts": next ? ["nexttrack", "previoustrack"] : [], "vol": .double(vol), "rate": .double(rate)]
  }

  func emit(_ h: Harness, _ id: String, _ now: Value?, muted: Bool = false) {
    h.rt.plugins.emit("webviews.nowPlaying", ["id": .string(id), "now": now ?? .null, "muted": .bool(muted)])
  }

  var dock: (Harness) -> Value = { $0.tree("sidebar.dock", 0) }
  /// Card titles, top to bottom.
  func titles(_ h: Harness) -> [String] {
    dock(h).list("children").filter { $0.str("id").hasPrefix("media.card:") }.map { $0.list("children")[0].list("children")[1].list("children")[0].str("text") }
  }

  @Test func dockListsWhatPlaysNewestFirstAndControlsIt() {
    let h = Harness()
    defer { _ = h.rt.call("nowplaying", "clear") }
    let calls = Calls()
    start(h, calls)
    #expect(dock(h).isNull, "nothing playing, nothing rendered")
    #expect(!h.rt.nowPlaying.active)
    emit(h, "a", now("First"))
    #expect(titles(h) == ["First"])
    #expect(h.rt.nowPlaying.active && h.rt.nowPlaying.info.str("title") == "First" && h.rt.nowPlaying.info.flag("playing"))
    emit(h, "b", now("Second", next: true))
    // Newest first, collapsed to one with "1 more playing".
    #expect(titles(h) == ["Second"])
    let more = dock(h).list("children").last
    #expect(more?.str("id") == "media.more" && more?.list("children")[0].str("text") == "1 more playing")
    #expect(h.rt.nowPlaying.info.str("title") == "Second" && h.rt.nowPlaying.commands.contains("next"))
    h.action("media.more", "click")
    #expect(titles(h) == ["Second", "First"])
    #expect(dock(h).list("children").last?.list("children")[0].str("text") == "Show less")
    // The newest card's buttons carry the shortcuts; the next button is off without a next track.
    let firstCard = dock(h).list("children")[0]
    let buttons = firstCard.list("children")[1].list("children")
    #expect(buttons.map { $0.str("id") } == ["media.previous:b", "media.toggle:b", "media.next:b", "media.mute:b", "media.stop:b"])
    #expect(buttons[1].str("shortcut") == "ctrl+cmd+p" && buttons[1].str("tooltip") == "Pause")
    let secondNext = dock(h).list("children")[1].list("children")[1].list("children")[2]
    #expect(secondNext["enabled"] == false && secondNext["shortcut"].isNull)

    // Buttons, the title (jump to the tab), Control Center and the keys.
    h.action("media.toggle:b", "click")
    h.action("media.mute:a", "click")
    h.action("media.jump:a", "click")
    h.rt.plugins.emit("nowplaying.command", ["command": "next"])
    h.key("ctrl+cmd+p")
    h.key("ctrl+cmd+left")
    #expect(calls.list.map { $0.0 + " " + $0.1.str("id") + " " + $0.1.str("action") } == [
      "webviews.mediaControl b toggle", "webviews.setMuted a ", "tabs.select a ", "webviews.mediaControl b next",
      "webviews.mediaControl b toggle", "webviews.mediaControl b previous",
    ])
    #expect(calls.list[1].1["muted"] == true)

    // A paused one playing again moves to the front; mute state shows.
    emit(h, "b", now("Second", paused: true, next: true))
    #expect(h.rt.nowPlaying.info.flag("playing") == false)
    emit(h, "a", now("First", paused: true))
    #expect(titles(h) == ["Second", "First"], "pausing doesn't reorder")
    emit(h, "a", now("First"), muted: true)
    #expect(titles(h) == ["First", "Second"])
    #expect(dock(h).list("children")[0].list("children")[1].list("children")[3].str("icon") == "sf:speaker.slash.fill")

    // The tab on screen isn't listed.
    h.rt.plugins.emit("tabs.selected", ["id": "a"])
    #expect(titles(h) == ["Second"])
    #expect(h.rt.nowPlaying.info.str("title") == "First", "the tab on screen is still what the media keys drive")

    // Stopped or closed: gone; the last one gone clears everything.
    emit(h, "b", nil)
    emit(h, "a", nil)
    #expect(dock(h).isNull && !h.rt.nowPlaying.active)
  }

  @Test func keysAreBoundInTheViewMenu() {
    let h = Harness()
    let core = start(h, Calls())
    for chord in ["ctrl+cmd+p", "ctrl+cmd+right", "ctrl+cmd+left", "cmd+opt+p"] { #expect(h.rt.keys.bindings[chord]?.menu == "View", "\(chord)") }
    #expect(h.rt.keys.bindings["cmd+opt+p"]?.title == "Picture in Picture")
    core.stop()
    #expect(h.rt.keys.bindings["ctrl+cmd+p"] == nil && h.rt.keys.bindings["cmd+opt+p"] == nil)
  }

  /// Picture in picture around the system window: ⌥⌘P asks the host to toggle (with the newest
  /// playing tab as the fallback), and a video's card has a PiP button that follows `media.pip`.
  /// The tab in PiP stays listed, so den's own controls (mute, play/pause, stop) work on it.
  @Test func pictureInPictureKeyAndButton() {
    let h = Harness()
    defer { _ = h.rt.call("nowplaying", "clear") }
    let calls = Calls()
    start(h, calls)
    emit(h, "a", now("Song"))
    emit(h, "v", now("Clip", video: true))
    func buttons(_ i: Int) -> [Value] { dock(h).list("children")[i].list("children")[1].list("children") }
    h.action("media.more", "click")
    #expect(buttons(0).map { $0.str("id") } == ["media.previous:v", "media.toggle:v", "media.next:v", "media.mute:v", "media.pip:v", "media.stop:v"])
    #expect(!buttons(1).contains { $0.str("id") == "media.pip:a" }, "audio has no PiP button")
    #expect(buttons(0)[4].str("icon") == "sf:pip.enter")
    h.key("cmd+opt+p")
    h.action("media.pip:v", "click")
    h.rt.plugins.emit("media.pip", ["webview": "v", "open": true, "auto": false])
    #expect(titles(h) == ["Clip", "Song"], "the tab in PiP is still listed")
    #expect(buttons(0)[4].str("icon") == "sf:pip.exit" && buttons(0)[4].str("tooltip") == "Exit Picture in Picture")
    h.action("media.pip:v", "click")
    h.rt.plugins.emit("media.pip", ["webview": "v", "open": false, "auto": false])
    #expect(buttons(0)[4].str("icon") == "sf:pip.enter")
    #expect(calls.list.map { $0.0 + " " + $0.1.str("webview") + $0.1.str("fallback") } == ["media.toggle v", "media.enter v", "media.exit v"])
  }


  /// The dock's volume and speed controls: step buttons and a meter around the tab's volume, and
  /// a menu of speeds on the rate pill. Each sends the host `setVolume` / `setRate`; the host's
  /// `webviews.volume` / `webviews.rate` reports (and the page's own nowPlaying update) change
  /// what the card shows.
  @Test func dockSetsVolumeAndPlaybackSpeed() {
    let h = Harness()
    defer { _ = h.rt.call("nowplaying", "clear") }
    let calls = Calls()
    start(h, calls)
    emit(h, "a", now("Song", vol: 0.5))
    func row() -> Value { dock(h).list("children")[0].list("children")[2] }
    func kids(_ i: Int) -> Value { row().list("children")[i] }
    #expect(kids(0).str("id") == "media.voldown:a" && kids(0).str("tooltip") == "Quieter")
    #expect(kids(2).str("id") == "media.volup:a" && kids(2).str("tooltip") == "Louder")
    #expect(kids(1).str("type") == "meter" && kids(1).list("segments")[0].num("value") == 0.5)
    #expect(kids(3).str("text") == "50%")
    #expect(kids(4).str("id") == "media.rate:a" && kids(4).str("title") == "1×" && kids(4).str("variant") == "pill")
    let menu = kids(4).list("menu")
    #expect(menu.map { $0.str("id") } == ["0.5", "0.75", "1", "1.25", "1.5", "2"])
    #expect(menu[2].flag("checked") && !menu[0].flag("checked"), "the current speed is checked")

    // Louder and quieter, one-hundredth steps; the label and meter follow at once.
    h.action("media.volup:a", "click")
    #expect(kids(3).str("text") == "60%")
    h.action("media.voldown:a", "click")
    h.action("media.voldown:a", "click")
    #expect(kids(3).str("text") == "40%" && kids(1).list("segments")[0].num("value") == 0.4)
    // A speed from the menu.
    h.action("media.rate:a", "menu", .string("1.5"))
    #expect(kids(4).str("title") == "1.5×")
    #expect(calls.list.map { $0.0 } == ["webviews.setVolume", "webviews.setVolume", "webviews.setVolume", "webviews.setRate"])
    #expect(calls.list[0].1["volume"] == 0.6 && calls.list[1].1["volume"] == 0.5 && calls.list[2].1["volume"] == 0.4)
    #expect(calls.list[3].1["rate"] == 1.5)
    // The host's report (the page applied it) updates the dock, and full volume clamps the steps.
    h.rt.plugins.emit("webviews.volume", ["id": "a", "volume": 1.0])
    #expect(kids(3).str("text") == "100%")
    h.action("media.volup:a", "click")
    #expect(calls.list.count == 5 && calls.list[4].1["volume"] == 1.0)
    h.rt.plugins.emit("webviews.rate", ["id": "a", "rate": 2.0])
    #expect(kids(4).str("title") == "2×")
  }

  /// The host's `setVolume` / `setRate`: kept across loads (set before the page exists, applied
  /// on its first media report) and applied at once to a live page; `webviews.get` reports them,
  /// the now-playing event carries them, and bad values are refused.
  @Test func setVolumeAndRateReachThePage() async throws {
    let h = Harness()
    let mock = MockServices()
    try mock.start()
    let video = try #require(MediaScenarios.fixture())
    mock.files = [
      "/m.html": ("text/html", Data("<title>M</title><video src='/m.mp4' style='width:640px' loop></video>".utf8)),
      "/m.mp4": ("video/mp4", video),
    ]
    let id = h.rt.call("webviews", "create", ["id": "m", "url": .string(mock.base + "/m.html")])["id"].string!
    // Before the page exists: kept like `setMuted`; bad values are refused.
    #expect(h.rt.call("webviews", "setVolume", ["id": .string(id), "volume": 0.4]) == .ok)
    #expect(h.rt.call("webviews", "setRate", ["id": .string(id), "rate": 1.5]) == .ok)
    #expect(h.rt.call("webviews", "setVolume", ["id": .string(id), "volume": 1.2])["error"].string != nil)
    #expect(h.rt.call("webviews", "setRate", ["id": .string(id), "rate": 20])["error"].string != nil)
    var nows: [Value] = []
    h.rt.host.on("webviews.nowPlaying") { nows.append($0) }
    _ = h.rt.call("content", "show", ["panes": [.string(id)]])
    let web = try #require(h.rt.webviews.record(id)?.webView)
    #expect(await Wait.until("the page to load") { !web.isLoading && web.url != nil })
    #expect(h.rt.call("webviews", "get", ["id": .string(id)])["volume"] == 0.4)
    #expect(h.rt.call("webviews", "get", ["id": .string(id)])["rate"] == 1.5)
    #expect(await Wait.asyncJS(web, "const v = document.querySelector('video'); await v.play(); return true") as? Bool == true)
    // The first media report applied the settings kept from before the load.
    #expect(await Wait.until("the kept volume and rate on the element") {
      (await Wait.asyncJS(web, "const v = document.querySelector('video'); return v.volume === 0.4 && v.playbackRate === 1.5") as? Bool) == true
    })
    // Changing them on a live page applies at once, and the page reports the new values back.
    _ = h.rt.call("webviews", "setVolume", ["id": .string(id), "volume": 0.9])
    _ = h.rt.call("webviews", "setRate", ["id": .string(id), "rate": 2])
    #expect(await Wait.until("the live volume and rate on the element") {
      (await Wait.asyncJS(web, "const v = document.querySelector('video'); return v.volume === 0.9 && v.playbackRate === 2") as? Bool) == true
    })
    #expect(await Wait.until("nowPlaying reports the volume and rate") {
      nows.contains { $0.str("id") == "m" && $0["now"].num("vol") == 0.9 && $0["now"].num("rate") == 2 }
    })
  }

  /// The tabs plugin puts the page's playback state on its row (the hover buttons) and sends
  /// their clicks to the page.
  @Test func tabRowGetsHoverPlayback() {
    let h = Harness()
    h.startTabs()
    guard let id = h.ids("today").first ?? h.ids("pinned").first else { Issue.record("no tabs"); return }
    func row() -> Value? {
      func find(_ v: Value) -> Value? {
        if v.str("id") == id, v.str("type") == "tabRow" { return v }
        for c in v.list("children") { if let r = find(c) { return r } }
        return nil
      }
      return find(h.tree("sidebar.today", 0)) ?? find(h.tree("sidebar.pinned", 0))
    }
    #expect(row()?["media"].isNull == true)
    emit(h, id, now("Song", next: true))
    #expect(row()?["media"]["paused"] == false && row()?["media"]["next"] == true && row()?["media"]["previous"] == true)
    emit(h, id, now("Song", paused: true))
    #expect(row()?["media"]["paused"] == true && row()?["media"]["next"] == false)
    emit(h, id, nil)
    #expect(row()?["media"].isNull == true)
  }
}
