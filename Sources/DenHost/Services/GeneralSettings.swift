import AppKit
import CordisValue

/// The host's own Settings section, "General": the default browser and where `~/.den` and
/// `config.toml` live. Built when the pane is shown (it asks macOS for the default browser then,
/// never at launch). Plugins join it with `settings.register {section: "general"}` (e.g. `quit`).
// thin-host: feature-specific, migrate to plugin (the General section: default browser, ~/.den, accent;
// its copy and policy belong to a `general` plugin; docs/architecture/thin-host.md)
@MainActor
enum GeneralSettings {
  static func install(_ rt: DenRuntime) {
    let s = rt.settings
    s.builtins["general"] = { [unowned rt] in
      SettingsService.Entry(id: "general", section: "general", title: "General", icon: "sf:gearshape", order: 0, controls: controls(rt))
    }
    s.builtinActions["general"] = { [unowned rt] key, _, button in
      switch key {
      case "defaultBrowser": rt.call("app", "setDefaultBrowser")
      case "config", "home":
        let paths = rt.call("config", "paths")
        let path = key == "config" ? paths.str("config") : paths.str("root")
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        if button == "open" {
          if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: Data(starter.utf8)) }
          NSWorkspace.shared.open(url)
        } else {
          NSWorkspace.shared.activateFileViewerSelecting([url])
        }
      default: break
      }
    }
    // macOS answers the default-browser change asynchronously.
    rt.host.on("app.defaultBrowser") { [weak s] _ in s?.window?.reload() }
    // Accent color: the space's colors (default) or the system accent. Read before the first
    // frame (one small storage read) so the window never flashes the other accent.
    if s.stored("general").first(where: { $0.0 == "accent" })?.1.string == "system" { Palette.accentSource = .system }
    // Passkey fallback (Passkeys.swift): applies to pages loaded in web views created afterwards.
    Passkeys.fallbackSetting = s.stored("general").first(where: { $0.0 == "passkeyFallback" })?.1.bool ?? true
    rt.host.on("settings.changed") { v in
      if v.str("id") == "general", v.str("key") == "passkeyFallback" { Passkeys.fallbackSetting = v["value"].bool ?? true }
    }
    // Translucent window (vibrancy): read before the first frame, so the window opens as it was.
    ThemeBackgroundView.translucency = s.stored("general").first(where: { $0.0 == "translucent" })?.1.bool ?? false
    if ThemeBackgroundView.translucency { applyTranslucency(rt) }
    rt.host.on("settings.changed") { [unowned rt] v in
      guard v.str("id") == "general", v.str("key") == "translucent" else { return }
      ThemeBackgroundView.translucency = v["value"].bool ?? false
      applyTranslucency(rt)
    }
    rt.windows.each { wc in
      wc.background.translucent = ThemeBackgroundView.translucency
      wc.sidebar.backdrop.translucent = ThemeBackgroundView.translucency
    }
    rt.host.on("settings.changed") { [unowned rt] v in
      guard v.str("id") == "general", v.str("key") == "accent" else { return }
      Palette.accentSource = v["value"].string == "system" ? .system : .theme
      rt.ui.refreshPalette()
    }
    // Sidebar position: apply to every window immediately.
    rt.host.on("settings.changed") { [unowned rt] v in
      guard v.str("id") == "general", v.str("key") == "sidebarPosition" else { return }
      let pos = v["value"].string ?? "left"
      for wc in rt.windows.all { wc.sidebarPosition = pos }
    }
    // The system accent changing while it's in use.
    NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { [weak rt] _ in
      MainActor.assumeIsolated { if Palette.accentSource == .system { rt?.ui.refreshPalette() } }
    }
  }

  /// Every open window's theme views follow the setting (new windows read it when created).
  static func applyTranslucency(_ rt: DenRuntime) {
    for wc in rt.windows.all {
      wc.background.translucent = ThemeBackgroundView.translucency
      wc.sidebar.backdrop.translucent = ThemeBackgroundView.translucency
    }
  }

  static let starter = """
    # den configuration (docs/den-home.md). Changes apply as soon as you save.
    #
    # [plugins]
    # disabled = ["peek"]
    #
    # [shortcuts]
    # "cmd+shift+y" = "den.copyMarkdown"
    #
    # [search.keywords]
    # mdn = { name = "MDN", url = "https://developer.mozilla.org/search?q=%s" }

    """

  static func controls(_ rt: DenRuntime) -> [Value] {
    var out: [Value] = [
      ["key": "accent", "type": "choice", "title": "Accent color",
       "subtitle": "Buttons, selection and toggles take their color from the current space, or from macOS.",
       "options": [["value": "theme", "title": "Space colors"], ["value": "system", "title": "System accent"]], "default": "theme"],
      ["key": "sidebarPosition", "type": "choice", "title": "Sidebar position",
       "subtitle": "Place the sidebar on the right instead of the left.",
       "options": [["value": "left", "title": "Left"], ["value": "right", "title": "Right"]], "default": "left"],
    ]
    out.append(["key": "translucent", "type": "toggle", "title": "Translucent window",
                "subtitle": "Your desktop shows faintly through the space's colors, like macOS sidebars. Off by default: it costs the system some graphics work while den is on screen.",
                "default": false])
    out.append(["key": "passkeyFallback", "type": "toggle", "title": "Skip passkey sign-in, use the password",
                "subtitle": .string(Passkeys.entitled
                  ? "den can use passkeys, so sites get WebKit's real answer and this has no effect."
                  : "den can't use passkeys yet (it needs Apple's browser entitlement). Sites then offer your password instead of a phone or Bluetooth prompt. Applies to newly opened tabs."),
                "default": true])
    let b = rt.call("app", "defaultBrowser")
    if b.flag("isDefault") {
      out.append(["key": "defaultBrowser", "type": "info", "title": "Default browser", "subtitle": "Links from other apps open in den.", "value": "den"])
    } else {
      let name = b.str("name").isEmpty ? "another browser" : b.str("name")
      out.append(["key": "defaultBrowser", "type": "button", "title": "Default browser",
                  "subtitle": .string("Links from other apps open in \(name)."), "button": ["title": "Make den Default", "style": "primary"]])
    }
    let paths = rt.call("config", "paths")
    if paths.isError || paths.str("config").isEmpty {
      out.append(["key": "config", "type": "info", "title": "Configuration", "subtitle": "~/.den is off for this run (--no-den-home).", "value": "~/.den/config.toml"])
    } else {
      let home = NSHomeDirectory()
      func tilde(_ p: String) -> String { p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p }
      let errors = rt.call("config", "errors").array?.compactMap(\.string) ?? []
      let sub = errors.first.map { "Problem: \($0)" } ?? "Plugins, themes, shortcuts and search keywords. Saved changes apply at once."
      out.append(["key": "config", "type": "info", "title": "config.toml", "subtitle": .string(sub), "value": .string(tilde(paths.str("config"))),
                  "buttons": [["id": "open", "title": "Open"], ["id": "reveal", "title": "Show in Finder"]]])
      out.append(["key": "home", "type": "info", "title": "den folder", "subtitle": "Drop plugins and themes here; den picks them up live.", "value": .string(tilde(paths.str("root"))),
                  "buttons": [["id": "reveal", "title": "Show in Finder"]]])
    }
    return out
  }
}
