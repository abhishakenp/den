import AppKit
import CordisValue
import Foundation
import Testing

@testable import DenHost
@testable import PluginCores

/// An in-memory `settings` service shaped like the proposal in docs/plugin-services.md.
final class FakeSettings {
  var panes: [Value]
  var values: [String: Value] = [:]
  var opened: [Value] = []
  var sets: [(String, Value)] = []
  init(_ panes: [Value]) {
    self.panes = panes
    for p in panes { for s in p.a("schema") { values[s.s("key")] = s["value"] } }
  }
  /// `list` with the current values filled in.
  var list: Value {
    .array(panes.map { p in
      var p = p
      p.put("schema", .array(p.a("schema").map { s in
        var s = s
        s.put("value", values[s.s("key")] ?? .null)
        return s
      }))
      return p
    })
  }

  static let den: [Value] = [
    ["id": "general", "title": "General", "icon": "sf:gearshape", "schema": [
      ["key": "general.askQuit", "title": "Ask before quitting", "type": "toggle", "value": true],
      ["key": "general.engine", "title": "Default search engine", "type": "choice", "value": "google",
       "options": [["value": "google", "title": "Google"], ["value": "ddg", "title": "DuckDuckGo"], ["value": "kagi", "title": "Kagi"]]],
    ]],
    ["id": "appearance", "title": "Appearance", "icon": "sf:paintbrush", "schema": [
      ["key": "appearance.webDark", "title": "Dark mode for websites", "type": "toggle", "value": false, "keywords": ["night", "theme"]],
      ["key": "appearance.mode", "title": "Appearance", "type": "choice", "value": "auto",
       "options": [["value": "auto", "title": "Automatic"], ["value": "light", "title": "Light"], ["value": "dark", "title": "Dark"]]],
    ]],
    ["id": "privacy", "title": "Privacy", "icon": "sf:hand.raised", "schema": [
      ["key": "privacy.trackers", "title": "Block trackers", "type": "toggle", "value": true],
    ]],
  ]
}

extension Harness {
  /// Provides a fake `settings` service (and, optionally, empty destination services).
  @discardableResult
  func provideSettings(_ panes: [Value] = FakeSettings.den, destinations: [String] = []) -> FakeSettings {
    let f = FakeSettings(panes)
    let rt = rt
    rt.plugins.provide("settings") { m, a in
      MainActor.assumeIsolated {
        switch m {
        case "list": return f.list
        case "set":
          f.values[a.s("key")] = a["value"]
          f.sets.append((a.s("key"), a["value"]))
          rt.plugins.emit("settings.changed", ["key": a["key"], "value": a["value"]])
          return ["ok": true]
        case "open":
          f.opened.append(a)
          return ["ok": true]
        default: return ["error": .string("settings: unknown method " + m)]
        }
      }
    }
    for d in destinations {
      rt.plugins.provide(d) { m, _ in
        MainActor.assumeIsolated { h_destinationCalls.append(d + "." + m) }
        return ["ok": true]
      }
    }
    return f
  }
  var toastText: String? { rt.ui.toasts.last?.label.stringValue }
  /// A freshly opened bar (Cmd-T), whatever state it was in.
  func fresh() {
    if rt.ui.commandBarOpen { action("commandBar", "dismiss") }
    key("cmd+t")
  }
}

@MainActor var h_destinationCalls: [String] = []

@MainActor
@Suite(.serialized)
struct LauncherTests {
  @Test func destinationsRankAboveGoogleAndHideWithoutTheirService() {
    let h = Harness()
    h.startCommandBar()
    h.key("cmd+t")
    h.type("extensions")
    // No extensions plugin: nothing local, so Google stays first.
    #expect(h.barRowIds.first == "search")
    #expect(!h.barRowIds.contains("cmd:den.extensions"))
    h.key("cmd+t")

    let f = h.provideSettings(destinations: ["extensions", "downloads", "passwords"])
    h_destinationCalls = []
    h.key("cmd+t")
    h.type("extensions")
    #expect(Array(h.barRowIds.prefix(2)) == ["cmd:den.extensions", "search"])
    #expect(h.bar.str("selected") == "cmd:den.extensions")
    #expect(h.barRows[0].str("title") == "Extensions")
    h.submit()
    #expect(h_destinationCalls == ["extensions.open"])
    #expect(!h.rt.ui.commandBarOpen)

    // Aliases: "prefs" → Settings, "dl" → Downloads, "addons" → Extensions, "archive" → Library.
    for (q, id) in [("prefs", "cmd:den.settings"), ("dl", "cmd:den.downloads"), ("addons", "cmd:den.extensions"), ("settings", "cmd:den.settings"),
                    ("archive", "cmd:den.library"), ("passw", "cmd:den.passwords"), ("new space", "cmd:den.newSpace")] {
      h.key("cmd+t")
      h.type(q)
      #expect(h.barRowIds.first == id, "\(q) → \(h.barRowIds)")
      #expect(h.barRowIds.dropFirst().first == "search", "\(q): Google right after the top hit")
      h.key("cmd+t")
    }
    // Nothing strong: web search stays first, and single letters never jump.
    for q in ["swi", "dark souls", "s", "news"] {
      h.key("cmd+t")
      h.type(q)
      #expect(h.barRowIds.first == "search", "\(q) → \(h.barRowIds)")
      h.key("cmd+t")
    }
    // Settings opens the Settings window through the service.
    h.key("cmd+t")
    h.type("prefs")
    h.submit()
    #expect(f.opened.count == 1)
  }

  @Test func settingsAreIndexedWithSectionsSubtitlesAndToggleState() {
    let h = Harness()
    h.startCommandBar()
    let f = h.provideSettings()
    h.key("cmd+t")
    h.type("dark")
    let first = h.barRows[0]
    #expect(first.str("id") == "set:appearance.webDark")
    #expect(first.str("subtitle") == "— Settings › Appearance")
    #expect(first["toggle"] == false)
    #expect(h.barRowIds[1] == "search")
    // Sections have headers: the top hit and search rows have none; then Settings.
    let secs = h.bar.list("sections")
    #expect(h.bar.flag("headers"))
    #expect(secs[0].str("title") == "")
    #expect(!secs.contains { $0.str("title") == "Settings" && $0.list("rows").contains { $0.str("id") == "set:appearance.webDark" } })  // not twice

    // "dark mode" as a phrase is still the toggle; the section name matches every setting in it.
    h.type("dark mode")
    #expect(h.barRowIds.first == "set:appearance.webDark")
    h.type("appearance")
    #expect(h.barRowIds.first == "set:appearance.mode" || h.barRowIds.first == "pane:appearance")
    #expect(h.barRowIds.contains("set:appearance.webDark"))
    #expect(h.bar.list("sections").contains { $0.str("title") == "Settings" })

    // A pane opens its Settings pane.
    h.type("privacy")
    #expect(h.barRowIds.first == "pane:privacy")
    h.submit()
    #expect(f.opened.last?.s("id") == "privacy")
  }

  @Test func enterFlipsAToggleWithAToastAndTheBarShowsTheNewState() {
    let h = Harness()
    h.startCommandBar()
    let f = h.provideSettings()
    h.key("cmd+t")
    h.type("dark mode")
    h.submit()
    #expect(f.sets.count == 1 && f.sets[0].0 == "appearance.webDark" && f.sets[0].1 == true)
    #expect(!h.rt.ui.commandBarOpen)
    #expect(h.toastText == "Dark mode for websites: On")
    h.key("cmd+t")
    h.type("dark mode")
    #expect(h.barRows[0]["toggle"] == true)
    // The host draws the switch on.
    #expect(h.rt.ui.commandBar.rows[0].toggle.isHidden == false && h.rt.ui.commandBar.rows[0].toggle.on)
    h.submit()
    #expect(f.values["appearance.webDark"] == false)
    #expect(h.toastText == "Dark mode for websites: Off")
    // Used settings rank higher next time (frecency).
    #expect(h.storage("commandbar", "usage")["set:appearance.webDark"].i("n") == 2)
  }

  @Test func tabAndRightArrowDrillIntoOptionsAndBackspaceComesBack() {
    let h = Harness()
    h.startCommandBar()
    let f = h.provideSettings()
    h.key("cmd+t")
    h.type("search engine")
    let row = h.barRows[0]
    #expect(row.str("id") == "set:general.engine")
    #expect(row.str("accessory") == "Google")  // choices show the current option
    #expect(row.str("keycap") == "→")
    h.action("commandBar", "tab", ["query": "search engine"])
    #expect(h.rt.call("commands", "state")["scope"] == "options:general.engine")
    #expect(h.barRows.map { $0.str("title") } == ["Google", "DuckDuckGo", "Kagi"])
    #expect(h.bar.str("selected") == "opt:0")
    #expect(h.barRows[0].str("accessory") == "Current")
    #expect(h.bar.str("placeholder") == "Default search engine")
    // Backspace in the empty field: back to the query.
    h.action("commandBar", "back")
    #expect(h.rt.call("commands", "state")["scope"] == "main")
    #expect(h.bar.str("query") == "search engine")

    // → does the same; Enter on an option sets it.
    h.action("commandBar", "right", ["row": "set:general.engine", "query": "search engine"])
    #expect(h.rt.call("commands", "state")["scope"] == "options:general.engine")
    h.type("kag")
    #expect(h.barRowIds == ["opt:2"])
    h.submit()
    #expect(f.values["general.engine"] == "kagi")
    #expect(h.toastText == "Default search engine: Kagi")

    // Enter on a choice drills too; Tab on a toggle offers On / Off.
    h.fresh()
    h.type("appearance")
    h.submit("set:appearance.mode")
    #expect(h.rt.call("commands", "state")["scope"] == "options:appearance.mode")
    h.fresh()
    h.type("block trackers")
    h.action("commandBar", "tab", ["query": "block trackers"])
    #expect(h.barRows.map { $0.str("title") } == ["On", "Off"])
    #expect(h.bar.str("selected") == "opt:0")
    // Tab on a pane lists its settings.
    h.fresh()
    h.type("privacy")
    h.action("commandBar", "tab", ["query": "privacy"])
    #expect(h.rt.call("commands", "state")["scope"] == "pane:privacy")
    #expect(h.barRowIds == ["set:privacy.trackers"])
    // Tab on a plain row keeps its old meaning (actions mode).
    h.fresh()
    h.action("commandBar", "tab", ["query": ""])
    #expect(h.rt.call("commands", "state")["scope"] == "actions")
  }

  @Test func withoutASettingsServicePluginSettingsAreSearchable() {
    let h = Harness()
    h.startPeek()
    h.startCommandBar()
    h.key("cmd+t")
    h.type("little arc")
    let row = h.barRows.first { $0.str("id") == "set:peek.littleArc" }
    #expect(row?["toggle"] == false)
    #expect(row?.str("subtitle") == "— Settings › Links")
    h.submit("set:peek.littleArc")
    #expect(h.peek("settings")["littleArc"] == true)
    #expect(h.toastText == "Links from other apps open in Little Arc: On")
    #expect(!h.barRowIds.contains("cmd:den.settings"))  // no Settings window to open

    // A choice through `tabs.settings`.
    h.key("cmd+t")
    h.type("archive today")
    #expect(h.barRows.first { $0.str("id") == "set:tabs.archiveAfterMs" }?.str("accessory") == "12 hours")
    h.action("commandBar", "right", ["row": "set:tabs.archiveAfterMs", "query": "archive today"])
    h.type("never")
    h.submit()
    #expect(h.tabs("settings")["archiveAfterMs"] == 0)
    // Panes drill in the bar (Enter or Tab) when there's no window to open.
    h.key("cmd+t")
    h.type("links")
    h.submit("pane:links")
    #expect(h.rt.call("commands", "state")["scope"] == "pane:links")
    #expect(h.barRowIds == ["set:peek.peekLinks", "set:peek.littleArc"])
  }

  @Test func littleArcWindowsAndShortcutsAreSearchable() {
    let h = Harness()
    h.startPeek()
    h.startCommandBar()
    h.peek("settings", ["littleArc": true])
    h.rt.app.open([URL(string: "https://www.swift.org/blog/")!])
    let win = h.rt.call("window", "listMini")[0]["id"].string!
    h.key("cmd+t")
    h.type("little arc")
    let row = h.barRows.first { $0.str("id") == "win:" + win }
    #expect(row?.str("accessory") == "Switch to Window")
    #expect(h.bar.list("sections").contains { $0.str("title") == "Windows" })
    h.submit("win:" + win)
    #expect(!h.rt.ui.commandBarOpen)

    // Keyboard Shortcuts lists every binding with its keycaps; picking one runs it.
    h.record(["commands.key.edit"])
    h.key("cmd+t")
    h.type("keyboard")
    h.submit("cmd:den.shortcuts")
    #expect(h.rt.call("commands", "state")["scope"] == "shortcuts")
    h.type("open location")
    let loc = h.barRows.first { $0.str("id") == "key:cmd+l" }
    #expect(loc?.str("shortcut") == "⌘L")
    h.submit("key:cmd+l")
    #expect(h.events.contains { $0.0 == "commands.key.edit" })
    #expect(CommandBarCore.chordGlyphs("cmd+shift+k") == "⇧⌘K")
    #expect(CommandBarCore.chordGlyphs("ctrl+opt+left") == "⌃⌥←")
    #expect(CommandBarCore.chordGlyphs("cmd+shift+=") == "⇧⌘=")
    #expect(CommandBarCore.chordGlyphs("cmd++") == "⌘+")
  }

  @Test func commandShortcutsRenderAsKeycaps() {
    let h = Harness()
    h.startCommandBar()
    h.key("cmd+t")
    h.type("copy url")
    let row = h.barRows.first { $0.str("id") == "cmd:den.copyURL" }
    #expect(row?.str("shortcut") == "⌘⇧C")
    let view = h.rt.ui.commandBar.rows.first { $0.rowId == "cmd:den.copyURL" }
    #expect(view?.shortcutCaps.map(\.text) == ["⌘", "⇧", "C"])
  }

  @Test func matcherScoresPrefixAliasInitialsAndFuzzy() {
    func s(_ q: String, _ title: String, aliases: [String] = [], keywords: [String] = [], path: String = "") -> Int? {
      Matcher.score(Matcher.words(q), IndexEntry(kind: .command, id: "x", title: title, icon: "", section: "", aliases: aliases, keywords: keywords, path: path))
    }
    #expect(s("ext", "Extensions") == Matcher.exact)
    #expect(s("dl", "Downloads", aliases: ["dl"]) == Matcher.exact)
    #expect(s("pref", "Settings", aliases: ["preferences"]) == Matcher.alias)
    #expect(s("mode", "Dark mode for websites") == Matcher.wordPrefix)
    #expect(s("dm", "Dark mode for websites") == Matcher.initialsPrefix)
    #expect(s("night", "Dark mode for websites", keywords: ["night"]) == Matcher.keyword)
    #expect(s("appear", "Block trackers", path: "Appearance") == Matcher.path)
    #expect(s("ension", "Extensions") == Matcher.substring)
    #expect(s("extns", "Extensions") == Matcher.fuzzy)
    #expect(s("dark mode", "Dark mode for websites") == Matcher.exact)
    #expect(s("search engine", "Default search engine") == Matcher.phrase)
    #expect(s("dark souls", "Dark mode for websites") == nil)
    #expect(s("zz", "Extensions") == nil)
    #expect(s("", "Anything") == 0)
  }

  /// ~500 commands and settings: per-keystroke matching must stay well under 1 ms.
  @Test func perKeystrokeLatencyWith500Entries() {
    let h = Harness()
    let core = h.startCommandBar()
    let words = ["tab", "window", "sidebar", "page", "link", "download", "privacy", "cookie", "font", "zoom", "reader", "media", "audio",
                 "video", "space", "theme", "color", "search", "history", "password", "profile", "sync", "cache", "proxy"]
    var panes: [Value] = []
    for p in 0..<30 {
      var schema: [Value] = []
      for j in 0..<12 {
        let a = words[(p + j) % words.count], b = words[(p * 7 + j * 3) % words.count]
        schema.append(["key": .string("p\(p).s\(j)"), "title": .string("Show \(a) \(b) option \(j)"), "type": j % 3 == 0 ? "choice" : "toggle",
                       "value": false, "keywords": [.string(b)],
                       "options": [["value": "a", "title": "Always"], ["value": "n", "title": "Never"]]])
      }
      panes.append(["id": .string("pane\(p)"), "title": .string("Pane \(words[p % words.count]) \(p)"), "icon": "sf:gearshape", "schema": .array(schema)])
    }
    h.provideSettings(panes, destinations: ["extensions", "downloads", "passwords", "history"])
    for n in 0..<91 {
      h.rt.call("commands", "register", ["id": .string("ext.cmd\(n)"), "title": .string("Run \(words[n % words.count]) task \(n)"),
                                         "keywords": [.string(words[(n + 5) % words.count])], "aliases": [.string("r\(n)")]])
    }
    h.key("cmd+t")
    let clock = ContinuousClock()
    func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
    let build = clock.measure { core.indexValid = false; core.ensureIndex() }
    let count = core.index.count
    #expect(count >= 500)
    let wq = Matcher.words("dark mode")
    let pure = clock.measure { for _ in 0..<100 { for e in core.index { _ = Matcher.score(wq, e) } } }
    let ens = clock.measure { for _ in 0..<100 { core.ensureIndex() } }
    print(String(format: "launcher.score \"dark mode\" over the whole index (no ranking) %.4fms; cached-index check %.4fms", ms(pure) / 100, ms(ens) / 100))
    var perKey: [Double] = []
    var perRender: [Double] = []
    for q in ["extensions", "dark mode", "settings", "prefs", "dl", "show zoom", "xyzzy"] {
      for n in 1...q.count {
        let prefix = String(q.prefix(n))
        let reps = 200
        // What mainResults does per keystroke: the den rows and the Settings rows, ranked.
        let d = clock.measure {
          for _ in 0..<reps {
            _ = core.launcherRows(prefix, settings: false, limit: 4)
            _ = core.launcherRows(prefix, settings: true, limit: 4)
          }
        }
        perKey.append(ms(d) / Double(reps))
        core.query = prefix
        let r = clock.measure { core.compute() }
        perRender.append(ms(r))
      }
    }
    let sorted = perKey.sorted()
    let mean = perKey.reduce(0, +) / Double(perKey.count)
    let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
    let rs = perRender.sorted()
    print(String(format: "launcher.index entries=%d build=%.3fms", count, ms(build)))
    print(String(format: "launcher.match keystrokes=%d mean=%.4fms p95=%.4fms max=%.4fms", perKey.count, mean, p95, sorted.last!))
    print(String(format: "launcher.compute (tabs, history, spaces, windows, settings, commands) mean=%.4fms p95=%.4fms",
                 perRender.reduce(0, +) / Double(perRender.count), rs[Int(Double(rs.count - 1) * 0.95)]))
    // Shipped plugins are optimized; measure with `swift test -c release -Xswiftc -enable-testing`.
    // A debug build runs the same loops unoptimized (a few ms), so there it only guards blowups.
    #if DEBUG
      #expect(p95 < 25.0)
    #else
      #expect(p95 < 1.0)
    #endif
  }
}
