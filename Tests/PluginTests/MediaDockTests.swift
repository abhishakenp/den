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
  /// Starts the core with `webviews.mediaControl` / `setMuted` / `tabs.select` recorded (the
  /// fake ids have no pages).
  final class Calls { var list: [(String, Value)] = [] }

  @discardableResult
  func start(_ h: Harness, _ calls: Calls) -> MediaCore {
    let base = h.env
    var env = base
    env.invoke = { s, m, a in
      if (s == "webviews" && (m == "mediaControl" || m == "setMuted")) || (s == "tabs" && m == "select") {
        calls.list.append((s + "." + m, a))
        return ["ok": true]
      }
      return base.invoke(s, m, a)
    }
    let core = MediaCore(env: env)
    core.start()
    return core
  }

  func now(_ title: String, paused: Bool = false, next: Bool = false) -> Value {
    ["title": .string(title), "artist": "Artist", "album": "", "art": "", "paused": .bool(paused), "dur": 200, "video": false,
     "acts": next ? ["nexttrack", "previoustrack"] : []]
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

    // The tab on screen and the mini player's aren't listed.
    h.rt.plugins.emit("tabs.selected", ["id": "a"])
    #expect(titles(h) == ["Second"])
    h.rt.plugins.emit("media.miniPlayer", ["webview": "b", "open": true])
    #expect(dock(h).isNull)
    #expect(h.rt.nowPlaying.info.str("title") == "First", "the tab on screen is still what the media keys drive")
    h.rt.plugins.emit("media.miniPlayer", ["webview": "b", "open": false])
    #expect(titles(h) == ["Second"])

    // Stopped or closed: gone; the last one gone clears everything.
    emit(h, "b", nil)
    emit(h, "a", nil)
    #expect(dock(h).isNull && !h.rt.nowPlaying.active)
  }

  @Test func keysAreBoundInTheViewMenu() {
    let h = Harness()
    let core = start(h, Calls())
    for chord in ["ctrl+cmd+p", "ctrl+cmd+right", "ctrl+cmd+left"] { #expect(h.rt.keys.bindings[chord]?.menu == "View", "\(chord)") }
    core.stop()
    #expect(h.rt.keys.bindings["ctrl+cmd+p"] == nil)
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
