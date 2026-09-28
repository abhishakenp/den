#if !hasFeature(Embedded)
  import CordisValue
#endif

/// den's quit confirmation (spec §5 "Quit (Cmd-Q)").
///
/// - While "Warn before quitting" is on (the default), quitting is intercepted
///   (`app.interceptQuit`) and `app.quitRequested` shows the quit dialog: the app icon, "Quit den?",
///   and the buttons "Always quit" (secondary: quit and stop asking), "Cancel" (esc) and "Quit" (↩).
/// - The choice persists in storage (ns `quit`, key `warn`). The "Ask Before Quitting" command
///   turns the prompt back on.
/// - Closing the window never asks (spec §5 "Close window": tabs are kept, nothing is lost).
final class QuitCore {
  static let ns = "quit"
  static let dialogId = "quit"
  static let enableCommandId = "quit.warn"

  let env: PluginEnv
  var warn = true
  var dialogOpen = false
  var commandsRegistered = false
  var registerAttempts = 0

  init(env: PluginEnv) { self.env = env }

  func start() {
    warn = env.call("storage", "get", ["ns": .string(Self.ns), "key": "warn"]).bool ?? true
    env.call("app", "interceptQuit", ["enabled": .bool(warn)])
    env.on("app.quitRequested") { [self] _ in requested() }
    env.on("ui.action") { [self] v in
      guard v.s("id") == Self.dialogId, v.s("action") == "button" else { return }
      pressed(v["value"].s("button"))
    }
    env.on("commands.run") { [self] v in
      if v.s("id") == Self.enableCommandId { setWarn(true, announce: true) }
    }
    registerCommands()
    registerSettings()
  }

  /// Settings > General > "Ask before quitting" (the host `settings` service; storage ns `quit`, `prefs`).
  func registerSettings() {
    let r = env.call("settings", "register", [
      "id": .string(Self.ns), "section": "general", "title": "Quitting", "order": 50,
      "controls": [["key": "warn", "type": "toggle", "title": "Ask before quitting",
                    "subtitle": "⌘Q shows a confirmation first. Your tabs come back either way.", "default": .bool(warn)]],
    ])
    guard !r.isErr else { return }
    if let w = env.call("settings", "get", ["id": .string(Self.ns), "key": "warn"]).bool, w != warn { setWarn(w, announce: false) }
    env.on("settings.changed") { [self] v in
      if v.s("id") == Self.ns, v.s("key") == "warn", let w = v["value"].bool, w != warn { setWarn(w, announce: false) }
    }
  }

  /// On unload, quitting must not wait for a dialog nobody will answer.
  func stop() {
    registerAttempts = Int.max / 2
    if dialogOpen { pressed("cancel") }
    env.call("app", "interceptQuit", ["enabled": false])
  }

  func requested() {
    guard warn else {
      env.call("app", "quit", ["confirm": true])
      return
    }
    dialogOpen = true
    env.call("ui", "set", ["slot": "dialog", "tree": [
      "type": "dialog", "id": .string(Self.dialogId), "icon": "app:icon", "title": "Quit den?",
      "buttons": [
        ["id": "always", "title": "Always quit", "style": "secondary"],
        ["id": "cancel", "title": "Cancel", "style": "cancel"],
        ["id": "quit", "title": "Quit", "style": "default"],
      ],
    ]])
  }

  func pressed(_ button: String) {
    guard dialogOpen else { return }
    dialogOpen = false
    env.call("ui", "set", ["slot": "dialog", "tree": nil])
    switch button {
    case "quit":
      env.call("app", "quit", ["confirm": true])
    case "always":
      setWarn(false, announce: false)
      env.call("app", "quit", ["confirm": true])
    default:
      env.call("app", "quit", ["confirm": false])
    }
  }

  func setWarn(_ on: Bool, announce: Bool) {
    warn = on
    env.call("storage", "set", ["ns": .string(Self.ns), "key": "warn", "value": .bool(on)])
    env.call("app", "interceptQuit", ["enabled": .bool(on)])
    env.call("settings", "set", ["id": .string(Self.ns), "key": "warn", "value": .bool(on)])
    if announce {
      env.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": "den will ask before quitting", "icon": "sf:checkmark.circle.fill"]])
    }
  }

  // MARK: Commands

  /// `commands` is optional (plugin `commandbar`) and may load later: retry every 500 ms for 30 s.
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
      "id": .string(Self.enableCommandId), "title": "Ask Before Quitting", "icon": "sf:power",
      "keywords": ["quit", "warn", "confirm", "dialog", "prompt"],
    ])
    commandsRegistered = !r.isErr
    return commandsRegistered
  }
}
