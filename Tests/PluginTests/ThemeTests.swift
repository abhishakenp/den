import AppKit
import CordisValue
import Testing

@testable import DenHost
@testable import PluginCores

@MainActor
@Suite(.serialized)
struct ThemeTests {
  @discardableResult
  func start(_ h: Harness) -> ThemeCore {
    h.startSpaces()
    let core = ThemeCore(env: h.env)
    core.start()
    return core
  }

  func space(_ h: Harness, _ i: Int) -> Value { h.rt.call("spaces", "list")[i] }
  func pickerTree(_ h: Harness) -> Value { (h.rt.ui.popover.content?.node) ?? .null }
  func change(_ h: Harness, _ colors: [String], intensity: Double = 0.6, grain: Double = 0.3, appearance: String = "auto", action: String = "change") {
    h.action("theme", action, ["colors": .array(colors.map { .string($0) }), "intensity": .double(intensity), "grain": .double(grain), "appearance": .string(appearance)])
  }

  @Test func rulesParseHarmonizeAndSuggest() {
    #expect(ThemeRules.normalizeHex("#ABC") == "#aabbcc")
    #expect(ThemeRules.normalizeHex("3139FB") == "#3139fb")
    #expect(ThemeRules.normalizeHex("#12345") == nil)
    for hex in ["#3139fb", "#ff3c19", "#73e59c", "#808080"] {
      #expect(ThemeRules.hex(ThemeRules.hsb(hex)!) == hex)  // round trip
    }
    // Sanitize: ≤3 valid colors, clamped numbers, known appearance.
    let t = ThemeRules.sanitize(["colors": ["#f00", "nope", "#0f0", "#00f", "#fff"], "intensity": 3, "grain": -1, "appearance": "sepia"])
    #expect(t["colors"] == ["#ff0000", "#00ff00", "#0000ff"])
    #expect(t["intensity"] == 1.0 && t["grain"] == 0.0 && t["appearance"] == "auto")

    // Adding a color suggests the primary's complement, then a free triadic partner.
    let red = ThemeRules.hsb("#e05050")!
    let two = ThemeRules.harmonize(prev: ["#e05050"], next: ["#e05050", "#123456"])
    #expect(abs(ThemeRules.hsb(two[1])!.h - (red.h + 0.5)) < 0.01)
    let three = ThemeRules.harmonize(prev: two, next: two + ["#654321"])
    let hues = three.map { ThemeRules.hsb($0)!.h }
    #expect(ThemeRules.hueDistance(hues[2], hues[0]) > 0.3 && ThemeRules.hueDistance(hues[2], hues[1]) > 0.1)

    // Moving only the primary rotates the others by the same hue step.
    let moved = ThemeRules.hsb("#50e050")!  // red -> green
    let rotated = ThemeRules.harmonize(prev: two, next: ["#50e050", two[1]])
    let dh = moved.h - red.h
    #expect(ThemeRules.hueDistance(ThemeRules.hsb(rotated[1])!.h, ThemeRules.hsb(two[1])!.h + dh) < 0.01)

    // A muddy secondary next to a pastel primary is pulled into the primary's band.
    let banded = ThemeRules.harmonize(prev: ["#ffd0d0", "#ffe0d0"], next: ["#ffd0d0", "#202010"])
    let p = ThemeRules.hsb("#ffd0d0")!, b = ThemeRules.hsb(banded[1])!
    #expect(abs(b.v - p.v) <= ThemeRules.band + 0.01 && abs(b.s - p.s) <= ThemeRules.band + 0.01)

    // Positions invert the host pad mapping (ThemePickerMath).
    for hex in ["#e05050", "#73e59c", "#7eb8d6"] {
      let mine = ThemeRules.position(for: hex)
      let host = ThemePickerMath.position(for: RGB(hex: hex)!)
      #expect(abs(mine[0] - host.x) < 0.001 && abs(mine[1] - host.y) < 0.001)
    }
  }

  @Test func editThemeOpensPickerAnchoredToTheSpaceTitle() throws {
    let h = Harness()
    let core = start(h)
    let s1 = space(h, 1)
    h.rt.call("spaces", "switch", ["id": s1["id"], "animated": false])
    h.action("spaces.title:" + s1.s("id"), "more")  // the "…" button: spaces emits spaces.editTheme
    #expect(core.isOpen)
    #expect(h.rt.call("ui", "get")["overlays"] == ["popover"])
    let tree = pickerTree(h)
    #expect(tree["type"] == "themePicker" && tree["anchor"].string == "spaces.title:" + s1.s("id"))
    #expect(tree["colors"] == s1["theme"]["colors"])
    let picker = try #require(h.rt.ui.popover.content as? ThemePickerNode)
    #expect(picker.colors.map(\.hex) == ThemeRules.colors(s1["theme"]))
  }

  @Test func liveChangesPreviewAndClickOutsideSaves() {
    let h = Harness()
    let core = start(h)
    let id = space(h, 0)["id"]
    let before = space(h, 0)["theme"]
    h.rt.plugins.emit("spaces.editTheme", ["id": id])
    change(h, ["#3139fb"], intensity: 0.9)
    change(h, ["#3139fb"], intensity: 0.9, action: "commit")  // the drag ended
    // Previewed on the window, not saved yet.
    #expect(h.rt.window.currentTheme.colors.map(\.hex) == ["#3139fb"])
    #expect(abs(h.rt.window.currentTheme.intensity - 0.9) < 0.001)
    #expect(space(h, 0)["theme"] == before)
    change(h, ["#3139fb", "#ff0000"], intensity: 0.9)  // "+" pressed: the new color becomes a suggestion
    let colors = ThemeRules.colors(core.session!.working)
    #expect(colors.count == 2 && colors[1] != "#ff0000")
    #expect(ThemeRules.hueDistance(ThemeRules.hsb(colors[1])!.h, ThemeRules.hsb("#3139fb")!.h) > 0.45)
    change(h, ["#3139fb", "#ff0000"], intensity: 0.9, action: "commit")  // the click's commit: dots updated
    #expect(ThemeRules.colors(pickerTree(h)).count == 2)
    #expect(pickerTree(h)["positions"].array?.count == 2)
    h.rt.ui.popoverBackdrop.onClick?()  // a click outside
    #expect(!core.isOpen)
    #expect(h.rt.call("ui", "get")["overlays"] == [])
    let saved = space(h, 0)["theme"]
    #expect(ThemeRules.colors(saved) == colors)
    #expect(saved["intensity"] == 0.9)
    // Remembered as a recent theme, and persisted.
    #expect(ThemeRules.colors(h.storage("theme", "recent")[0]) == colors)
  }

  @Test func draggingThePrimaryCarriesTheOthersAlong() {
    let h = Harness()
    let core = start(h)
    h.rt.plugins.emit("spaces.editTheme", ["id": space(h, 0)["id"]])
    change(h, ["#e05050", "#50e0e0"], action: "commit")  // start: red + its complement
    let start = ThemeRules.colors(core.session!.working)
    // A drag of the primary: the picker reports its own (unmoved) secondary at every step.
    change(h, ["#e0a050", start[1]])
    change(h, ["#a0e050", start[1]])
    change(h, ["#50e050", start[1]], action: "commit")
    let end = ThemeRules.colors(core.session!.working)
    let dh = ThemeRules.hsb("#50e050")!.h - ThemeRules.hsb(start[0])!.h
    #expect(ThemeRules.hueDistance(ThemeRules.hsb(end[1])!.h, ThemeRules.hsb(start[1])!.h + dh) < 0.01)
    #expect(ThemeRules.colors(pickerTree(h)) == end)  // the picker's dots follow
    #expect(h.rt.window.currentTheme.colors.map(\.hex) == end)  // and the preview
  }

  @Test func escapeRevertsThePreview() {
    let h = Harness()
    let core = start(h)
    let id = space(h, 0)["id"]
    let before = space(h, 0)["theme"]
    let beforeWindow = h.rt.window.currentTheme
    h.rt.plugins.emit("spaces.editTheme", ["id": id])
    change(h, ["#ff3c19"], intensity: 0.2, grain: 0.9, appearance: "dark")
    #expect(h.rt.window.currentTheme.colors.map(\.hex) == ["#ff3c19"])
    h.action("theme", "dismiss", ["reason": "escape"])
    #expect(!core.isOpen)
    #expect(space(h, 0)["theme"] == before)
    #expect(h.rt.window.currentTheme == beforeWindow)
    #expect(h.storage("theme", "recent").isNull)
  }

  @Test func appearanceIsGlobalAcrossSpaces() {
    let h = Harness()
    start(h)
    let id = space(h, 0)["id"]
    h.rt.plugins.emit("spaces.editTheme", ["id": id])
    let colors = ThemeRules.colors(space(h, 0)["theme"])
    change(h, colors, appearance: "dark", action: "commit")
    h.action("theme", "dismiss")
    for s in h.rt.call("spaces", "list").array ?? [] { #expect(s["theme"]["appearance"] == "dark") }
    #expect(ThemeRules.colors(space(h, 1)["theme"]) != colors)  // other spaces keep their colors
    #expect(h.storage("theme", "recent").isNull)  // appearance alone isn't a new theme
  }

  @Test func switchingSpaceSavesAndCommandsWork() {
    let h = Harness()
    var registered: [Value] = []
    h.rt.plugins.provide("commands") { m, a in
      if m == "register" { registered.append(a) }
      return ["ok": true]
    }
    let core = start(h)
    #expect(registered.first?["id"] == "theme.edit" && registered.first?["title"] == "Theme…")
    // The command opens the picker for the current space.
    h.rt.plugins.emit("commands.run", ["id": "theme.edit"])
    #expect(core.session?.spaceId == space(h, 0).s("id"))
    change(h, ["#73e59c"])
    h.rt.call("spaces", "switch", ["id": space(h, 1)["id"], "animated": false])  // closes and saves
    #expect(!core.isOpen)
    #expect(ThemeRules.colors(space(h, 0)["theme"]) == ["#73e59c"])
    // The saved theme is offered as a recent-theme command and applies to the current space.
    let recent = registered.first { $0.s("id") == "theme.recent:0" }
    #expect(recent?["title"].string?.contains("#73e59c") == true)
    h.rt.plugins.emit("commands.run", ["id": "theme.recent:0"])
    #expect(ThemeRules.colors(space(h, 1)["theme"]) == ["#73e59c"])
    // The picker reopens on the preset page the user left it on.
    h.rt.plugins.emit("spaces.editTheme", ["id": space(h, 1)["id"]])
    h.action("theme", "page", ["page": 2])
    h.action("theme", "dismiss", ["reason": "escape"])
    let h2 = Harness(root: h.root)
    h2.startSpaces()
    let core2 = ThemeCore(env: h2.env)
    core2.start()
    #expect(core2.presetPage == 2)
    #expect(core2.recent.count == 1)
  }

  @Test func denHomeThemesBecomeCommandsAndStayLive() {
    let h = Harness()
    var registered: [String: Value] = [:]
    h.rt.plugins.provide("commands") { m, a in
      if m == "register" { registered[a.s("id")] = a }
      if m == "unregister" { registered[a.s("id")] = nil }
      return ["ok": true]
    }
    var themes: Value = [["name": "Dusk", "colors": ["#3139fb", "#ff3c19"], "intensity": 0.8, "appearance": "dark", "file": "dusk.json"]]
    h.rt.plugins.provide("config") { m, _ in m == "themes" ? themes : ["error": "config: unknown"] }
    start(h)
    #expect(registered["theme.user:0"]?["title"] == "Theme: Dusk")
    h.rt.plugins.emit("commands.run", ["id": "theme.user:0"])
    let s0 = space(h, 0)["theme"]
    #expect(ThemeRules.colors(s0) == ["#3139fb", "#ff3c19"] && s0["intensity"] == 0.8)
    #expect((h.rt.call("spaces", "list").array ?? []).allSatisfy { $0["theme"]["appearance"] == "dark" })
    // A file added or removed in ~/.den/themes: config.themesChanged replaces the commands.
    themes = [["name": "Aurora", "colors": ["#73e59c"], "file": "a.json"], ["name": "Sand", "colors": ["#e0c080"], "file": "s.toml"]]
    h.rt.plugins.emit("config.themesChanged", ["themes": themes])
    #expect(registered["theme.user:0"]?["title"] == "Theme: Aurora" && registered["theme.user:1"]?["title"] == "Theme: Sand")
    h.rt.plugins.emit("config.themesChanged", ["themes": []])
    #expect(registered.keys.filter { $0.hasPrefix("theme.user:") }.isEmpty)
  }

  @Test func commandsRegisterWhenTheCommandBarLoadsLater() {
    let h = Harness()
    let core = start(h)
    #expect(!core.commandsRegistered)
    var registered: [String] = []
    h.rt.plugins.provide("commands") { m, a in
      if m == "register" { registered.append(a.s("id")) }
      return ["ok": true]
    }
    h.fireTimers()
    #expect(core.commandsRegistered)
    #expect(registered == ["theme.edit"])
  }
}
