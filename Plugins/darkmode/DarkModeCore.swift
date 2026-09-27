#if !hasFeature(Embedded)
  import CordisValue
#endif

/// Dark mode for every website, tied to den's appearance (docs/plugin-services.md `darkmode`).
///
/// The host's `pagestyle` service applies user stylesheets and a per-site appearance to each web
/// view; this plugin owns the CSS, the per-site choices and the cache of natively dark sites.
///
/// - Web views follow den's window appearance, so `prefers-color-scheme` is den's appearance and
///   sites with their own dark mode use it.
/// - Sites that stay light while den is dark get the `den.dark` sheet: an inverted, hue-rotated
///   root filter with images, video, canvases, embeds and inline background images inverted back.
///   It sits inside `@media (prefers-color-scheme: dark)`, so switching den's appearance applies at
///   once with no round trip, and it keys on the host detector's `data-den-tone`, so a page that
///   is already dark is never inverted.
/// - Hosts measured dark under a dark scheme are remembered (`tones`) and get no sheet at all on
///   the next visit (no flash, no filter cost).
/// - Per site (`sites`): `auto` (follow den), `dark` (dark appearance + `den.dark`), `light` (light
///   appearance + `den.light`, which inverts pages that are dark even in a light scheme), `off`.
final class DarkModeCore {
  static let ns = "darkmode"
  static let darkSheet = "den.dark"
  static let lightSheet = "den.light"
  static let maxTones = 400
  static let modes = ["auto", "dark", "light", "off"]

  /// Filter and the elements that get it back (so photos and video keep their colors). Iframes
  /// are re-inverted: the sheets are main-frame only, so embedded documents show as they are.
  static let invert = "filter: invert(1) hue-rotate(180deg) !important;"
  static func sheet(scheme: String, when: String) -> String {
    "@media (prefers-color-scheme: " + scheme + ") {\n"
      + "html" + when + " { " + invert + " }\n"
      + "html" + when + " :is(img, video, canvas, embed, object, iframe, svg image, [style*=\"background-image\"]) { " + invert + " }\n"
      + "html" + when + " [style*=\"background-image\"] :is(img, video, canvas) { filter: none !important; }\n"
      + "}\n"
  }
  static let darkCSS = sheet(scheme: "dark", when: ":not([data-den-tone=dark])")
  static let lightCSS = sheet(scheme: "light", when: "[data-den-tone=dark]")

  let env: PluginEnv
  var enabled = true
  var sites: [(String, String)] = []  // host -> dark|light|off
  var tones: [String] = []  // hosts that are dark under a dark scheme, newest last
  var commandsRegistered = false
  var registerAttempts = 0

  init(env: PluginEnv) { self.env = env }

  func start() {
    let s = load("settings")
    enabled = s["enabled"].bool ?? true
    if case let .object(pairs) = load("sites") {
      for (h, m) in pairs { if let m = m.string, Self.modes.contains(m), m != "auto" { sites.append((h, m)) } }
    }
    tones = load("tones").array?.compactMap { $0.string } ?? []
    env.call("pagestyle", "define", ["name": .string(Self.darkSheet), "css": .string(Self.darkCSS)])
    env.call("pagestyle", "define", ["name": .string(Self.lightSheet), "css": .string(Self.lightCSS)])
    push()
    env.on("pagestyle.tone") { [self] v in measured(host: v.s("host"), tone: v.s("tone"), darkScheme: v.b("dark")) }
    env.on("commands.run") { [self] v in run(v.s("id")) }
    registerCommands()
  }

  func stop() {
    registerAttempts = Int.max / 2
    env.call("pagestyle", "rules", ["default": ["sheets": []], "hosts": [:], "detect": false])
  }

  // MARK: Service

  func handle(_ method: String, _ args: Value) -> Value {
    switch method {
    case "get":
      let h = URLs.host(args.s("host"))
      return ["enabled": .bool(enabled), "mode": .string(mode(h)), "sites": sitesValue, "dark": .bool(tones.contains(h))]
    case "site":
      let m = args.s("mode")
      guard Self.modes.contains(m), !args.s("host").isEmpty else { return .err("darkmode: site needs host and mode auto|dark|light|off") }
      setSite(URLs.host(args.s("host")), m)
      return .okay
    case "settings":
      if let e = args["enabled"].bool, e != enabled {
        enabled = e
        save("settings", ["enabled": .bool(e)])
        push()
      }
      return ["enabled": .bool(enabled)]
    default:
      return .err("darkmode: unknown method " + method)
    }
  }

  func mode(_ host: String) -> String {
    for (h, m) in sites where h == host { return m }
    return "auto"
  }

  var sitesValue: Value {
    var o: Value = .object([])
    for (h, m) in sites { o.put(h, .string(m)) }
    return o
  }

  func setSite(_ host: String, _ m: String) {
    sites.removeAll { $0.0 == host }
    if m != "auto" { sites.append((host, m)) }
    save("sites", sitesValue)
    push()
  }

  // MARK: Rules

  /// What `pagestyle` applies: the default for every site, and one rule per site that differs.
  func rules() -> Value {
    let none: Value = ["sheets": []]
    var hosts: Value = .object([])
    if enabled {
      for h in tones where mode(h) == "auto" { hosts.put(h, none) }
    }
    for (h, m) in sites {
      switch m {
      case "dark": hosts.put(h, ["sheets": [.string(Self.darkSheet)], "appearance": "dark"])
      case "light": hosts.put(h, ["sheets": [.string(Self.lightSheet)], "appearance": "light"])
      default: hosts.put(h, none)
      }
    }
    let def: Value = enabled ? ["sheets": [.string(Self.darkSheet)]] : none
    return ["default": def, "hosts": hosts, "detect": .bool(enabled || !sites.isEmpty)]
  }

  func push() { env.call("pagestyle", "rules", rules()) }

  /// The detector measured a page. Only measurements under a dark scheme say whether a site has
  /// its own dark mode; they update the cache (and the rules, when it changed).
  func measured(host: String, tone: String, darkScheme: Bool) {
    guard darkScheme, !host.isEmpty else { return }
    let known = tones.contains(host)
    if tone == "dark" && !known {
      tones.append(host)
      if tones.count > Self.maxTones { tones.removeFirst(tones.count - Self.maxTones) }
    } else if tone == "light" && known {
      tones.removeAll { $0 == host }
    } else {
      return
    }
    save("tones", .array(tones.map { .string($0) }))
    push()
  }

  // MARK: Commands

  static let commands: [(String, String, String)] = [
    ("darkmode.site.auto", "Dark Mode: Follow den on This Site", "sf:circle.lefthalf.filled"),
    ("darkmode.site.dark", "Dark Mode: Always Dark on This Site", "sf:moon.fill"),
    ("darkmode.site.light", "Dark Mode: Always Light on This Site", "sf:sun.max.fill"),
    ("darkmode.site.off", "Dark Mode: Off for This Site", "sf:circle.slash"),
    ("darkmode.toggle", "Dark Mode for Websites: On/Off", "sf:moon.circle"),
  ]

  func run(_ id: String) {
    if id == "darkmode.toggle" {
      _ = handle("settings", ["enabled": .bool(!enabled)])
      toast(enabled ? "Dark mode for websites is on" : "Dark mode for websites is off")
      return
    }
    guard Text.hasPrefix(id, "darkmode.site.") else { return }
    let m = Text.dropPrefix(id, "darkmode.site.")
    guard let h = currentHost() else { return }
    setSite(h, m)
    let text = m == "auto" ? "follows den" : m == "dark" ? "always dark" : m == "light" ? "always light" : "never changed"
    toast(h + " is " + text)
  }

  /// The focused pane's (or selected tab's) site.
  func currentHost() -> String? {
    let id = env.call("content", "get")["focus"].string ?? env.call("tabs", "selected")["id"].string
    guard let id else { return nil }
    let url = env.call("webviews", "get", ["id": .string(id)]).s("url")
    guard Text.hasPrefix(url, "http") else { return nil }
    let h = URLs.host(url)
    return h.isEmpty ? nil : h
  }

  func toast(_ text: String) {
    env.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": .string(text), "icon": "sf:moon.fill"]])
  }

  /// `commands` is optional (plugin `commandbar`): retry every 500 ms for 30 s.
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
    for (id, title, icon) in Self.commands {
      let r = env.call("commands", "register", [
        "id": .string(id), "title": .string(title), "icon": .string(icon), "owner": "darkmode",
        "keywords": ["dark", "light", "night", "theme", "appearance", "invert"],
      ])
      if r.isErr { return false }
    }
    commandsRegistered = true
    return true
  }

  // MARK: Storage

  func load(_ key: String) -> Value { env.call("storage", "get", ["ns": .string(Self.ns), "key": .string(key)]) }
  func save(_ key: String, _ v: Value) { env.call("storage", "set", ["ns": .string(Self.ns), "key": .string(key), "value": v]) }
}
