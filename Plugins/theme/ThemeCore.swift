#if !hasFeature(Embedded)
  import CordisValue
#endif

/// The space theme picker (spec §4, research §5).
///
/// - Opens on `spaces.editTheme {id}` and on the "Theme…" command, anchored to that space's title.
/// - Every `change` from the picker is harmonized (ThemeRules) and previewed with
///   `window.setTheme` on that space's page. Nothing is saved while the picker is open.
/// - Closing it (a click outside, or switching space) saves through `spaces.update`. Esc
///   (`dismiss {reason: "escape"}`) reverts the preview.
/// - Appearance is global, as in Arc: a saved appearance is written to every space.
/// - Saved themes are remembered (storage ns `theme`, key `recent`, newest first, at most 8) and
///   offered as "Use Recent Theme" commands.
final class ThemeCore {
  static let ns = "theme"
  static let nodeId = "theme"
  static let commandId = "theme.edit"
  static let recentCommandPrefix = "theme.recent:"
  static let maxRecent = 8
  static let recentCommands = 3

  struct Session {
    var spaceId: String
    var page: Int
    var original: Value  // the space's theme when the picker opened
    var working: Value  // sanitized, harmonized theme being previewed
    /// The colors the picker shows when no drag is in progress. Rules are applied relative to
    /// it, so a whole drag of the primary rotates the others by the total hue change.
    var synced: [String]
  }

  let env: PluginEnv
  var session: Session?
  var recent: [Value] = []
  var presetPage: Int64 = 0
  var commandsRegistered = false
  var registerAttempts = 0

  init(env: PluginEnv) { self.env = env }

  var isOpen: Bool { session != nil }

  func start() {
    recent = env.call("storage", "get", ["ns": .string(Self.ns), "key": "recent"]).array ?? []
    presetPage = env.call("storage", "get", ["ns": .string(Self.ns), "key": "presetPage"]).int ?? 0
    env.on("spaces.editTheme") { [self] v in open(v.s("id")) }
    env.on("ui.action") { [self] v in
      guard v.s("id") == Self.nodeId else { return }
      action(v.s("action"), v["value"])
    }
    env.on("commands.run") { [self] v in run(v.s("id")) }
    env.on("spaces.current") { [self] v in
      if let s = session, s.spaceId != v.s("id") { close(save: true) }
    }
    env.on("spaces.changed") { [self] _ in
      // The edited space was deleted elsewhere: drop the picker without saving.
      if let s = session, spaceIndex(s.spaceId) == nil { close(save: false) }
    }
    registerCommands()
  }

  /// On unload (or hot reload), keep what the user picked and take the picker down.
  func stop() {
    registerAttempts = Int.max / 2
    close(save: true)
  }

  // MARK: Commands

  /// `commands` is optional (plugin `commandbar`). It may load after this plugin, so keep trying
  /// for a while (every 500 ms, up to 30 s).
  func registerCommands() {
    if tryRegister() { return }
    env.timer(500, false) { [self] in
      registerAttempts += 1
      if !tryRegister(), registerAttempts < 60 { registerCommands() }
    }
  }

  @discardableResult
  func tryRegister() -> Bool {
    if commandsRegistered { return true }
    let r = env.call("commands", "register", [
      "id": .string(Self.commandId), "title": "Theme…", "icon": "sf:paintpalette",
      "keywords": ["theme", "color", "colour", "gradient", "appearance", "dark mode", "light mode"],
    ])
    guard !r.isErr else { return false }
    commandsRegistered = true
    registerRecentCommands()
    return true
  }

  func registerRecentCommands() {
    guard commandsRegistered else { return }
    for (j, t) in recent.prefix(Self.recentCommands).enumerated() {
      let colors = ThemeRules.colors(t)
      env.call("commands", "register", [
        "id": .string(Self.recentCommandPrefix + String(j)),
        "title": .string("Use Recent Theme " + String(j + 1) + " (" + join(colors) + ")"),
        "icon": "sf:paintpalette.fill", "keywords": ["theme", "recent", "color"],
      ])
    }
  }

  func run(_ id: String) {
    if id == Self.commandId {
      open(currentSpace())
    } else if Text.hasPrefix(id, Self.recentCommandPrefix), let j = Text.int(Text.dropPrefix(id, Self.recentCommandPrefix)), j < recent.count {
      applyRecent(j)
    }
  }

  /// Applies a remembered theme (colors, intensity, grain) to the current space. Appearance is
  /// global and left alone.
  func applyRecent(_ j: Int) {
    let id = currentSpace()
    guard !id.isEmpty else { return }
    var t = recent[j]
    t.put("appearance", .null)
    let clean = ThemeRules.sanitize(t)
    var patch: Value = ["colors": clean["colors"], "intensity": clean["intensity"], "grain": clean["grain"]]
    if !clean["positions"].isNull { patch.put("positions", clean["positions"]) }
    env.call("spaces", "update", ["id": .string(id), "theme": patch])
    remember(clean)
  }

  // MARK: Picker

  func currentSpace() -> String { env.call("spaces", "current").s("id") }

  func spaces() -> [Value] { env.call("spaces", "list").array ?? [] }

  func spaceIndex(_ id: String) -> Int? { spaces().firstIndex { $0.s("id") == id } }

  func open(_ id: String) {
    let list = spaces()
    guard let i = list.firstIndex(where: { $0.s("id") == id }) else { return }
    if let s = session {
      if s.spaceId == id { return }
      close(save: true)
    }
    let original = list[i]["theme"]
    let clean = ThemeRules.sanitize(original)
    session = Session(spaceId: id, page: i, original: original, working: clean, synced: ThemeRules.colors(clean))
    render()
  }

  func render() {
    guard let s = session else { return }
    let t = s.working
    var tree: Value = [
      "type": "themePicker", "id": .string(Self.nodeId), "anchor": .string("spaces.title:" + s.spaceId),
      "colors": t["colors"], "intensity": t["intensity"], "grain": t["grain"], "appearance": t["appearance"],
      "page": .int(presetPage),
    ]
    if !t["positions"].isNull { tree.put("positions", t["positions"]) }
    env.call("ui", "set", ["slot": "popover", "tree": tree])
  }

  func action(_ action: String, _ value: Value) {
    guard session != nil else { return }
    switch action {
    case "change": update(value, final: false)
    case "commit": update(value, final: true)
    case "page":
      presetPage = value["page"].int ?? 0
      env.call("storage", "set", ["ns": .string(Self.ns), "key": "presetPage", "value": .int(presetPage)])
    case "dismiss": close(save: value.s("reason") != "escape")
    default: break
    }
  }

  /// A picker edit: harmonize, preview. On `final` (a drag ended or a click), send the
  /// harmonized theme back to the picker.
  func update(_ value: Value, final: Bool) {
    guard var s = session else { return }
    let reported = ThemeRules.sanitize(value)
    let picked = ThemeRules.colors(reported)
    let colors = ThemeRules.harmonize(prev: s.synced, next: picked)
    var next = reported
    next.put("colors", .array(colors.map { .string($0) }))
    // Keep the picker's own dot positions where the rules left a color alone.
    let reportedPositions = reported["positions"].array ?? []
    var positions: [Value] = []
    for (j, c) in colors.enumerated() {
      if j < picked.count, picked[j] == c, j < reportedPositions.count {
        positions.append(reportedPositions[j])
      } else {
        positions.append(.array(ThemeRules.position(for: c).map { .double($0) }))
      }
    }
    next.put("positions", colors.isEmpty ? .null : .array(positions))
    s.working = next
    if final { s.synced = colors }
    session = s
    preview()
    if final { render() }  // not mid-drag, so the picker takes it; its dots show what the rules chose
  }

  func preview() {
    guard let s = session else { return }
    var t = s.working
    t.put("page", .int(Int64(s.page)))
    env.call("window", "setTheme", t)
  }

  func close(save: Bool) {
    guard let s = session else { return }
    session = nil
    env.call("ui", "set", ["slot": "popover", "tree": nil])
    let original = ThemeRules.sanitize(s.original)
    if !save || themeEqual(original, s.working) {
      // Revert the preview to the space's stored theme.
      var t = s.original
      t.put("page", .int(Int64(s.page)))
      env.call("window", "setTheme", t)
      return
    }
    env.call("spaces", "update", ["id": .string(s.spaceId), "theme": s.working])
    let appearance = s.working.s("appearance")
    if appearance != original.s("appearance") {
      for sp in spaces() where sp.s("id") != s.spaceId && sp["theme"].s("appearance") != appearance {
        env.call("spaces", "update", ["id": sp["id"], "theme": ["appearance": .string(appearance)]])
      }
    }
    if ThemeRules.colors(s.working) != ThemeRules.colors(original) || s.working["intensity"] != original["intensity"] || s.working["grain"] != original["grain"] {
      remember(s.working)
    }
  }

  func themeEqual(_ a: Value, _ b: Value) -> Bool {
    ThemeRules.colors(a) == ThemeRules.colors(b) && a["intensity"] == b["intensity"] && a["grain"] == b["grain"] && a.s("appearance") == b.s("appearance")
  }

  /// Adds a theme to the front of the recent list (deduplicated by colors).
  func remember(_ t: Value) {
    let colors = ThemeRules.colors(t)
    guard !colors.isEmpty else { return }
    var entry: Value = ["colors": t["colors"], "intensity": t["intensity"], "grain": t["grain"]]
    if !t["positions"].isNull { entry.put("positions", t["positions"]) }
    recent.removeAll { ThemeRules.colors($0) == colors }
    recent.insert(entry, at: 0)
    if recent.count > Self.maxRecent { recent.removeLast(recent.count - Self.maxRecent) }
    env.call("storage", "set", ["ns": .string(Self.ns), "key": "recent", "value": .array(recent)])
    registerRecentCommands()
  }

  func join(_ parts: [String]) -> String {
    var out = ""
    for (j, p) in parts.enumerated() { out += (j == 0 ? "" : ", ") + p }
    return out
  }
}
