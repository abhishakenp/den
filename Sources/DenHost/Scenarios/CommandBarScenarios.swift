// Dev fixture: compiled only with the `Scenarios` package trait (on by default; release bundles leave it out).
#if Scenarios
import AppKit
import CordisValue

extension HostScenarios {
  /// `commandBar:<query>`: opens the Command Bar (the `commands` plugin) with `<query>` typed, or
  /// empty (Cmd-T) for `commandBar:`. Web suggestions come from the live `suggest` service.
  /// Needs the plugins, so run it on a fresh `--storage` (the first-run seed).
  static func commandBar(_ name: String, runtime rt: DenRuntime) -> NSWindow? {
    guard name.hasPrefix("commandBar:") else { return nil }
    let q = String(name.dropFirst("commandBar:".count))
    rt.call("commands", "open", ["mode": "new", "query": .string(q)])
    // As if typed: caret at the end, nothing selected.
    rt.ui.commandBar.input.currentEditor()?.selectedRange = NSRange(location: (q as NSString).length, length: 0)
    return rt.window.window
  }

  /// `launcher:<query>`: the command bar as a launcher, with a stand-in `settings` registry (the
  /// proposed service in docs/plugin-services.md) and a stub `extensions` service (the host provides `downloads`), so
  /// den's destinations and settings show as they will once those land. Needs the plugins.
  static func launcher(_ name: String, runtime rt: DenRuntime) -> NSWindow? {
    guard name.hasPrefix("launcher:") else { return nil }
    let q = String(name.dropFirst("launcher:".count))
    let stub = LauncherSettingsStub()
    for d in ["extensions"] where !rt.plugins.serviceNames.contains(d) { rt.plugins.provide(d) { _, _ in ["ok": true] } }
    if !rt.plugins.serviceNames.contains("settings") { rt.plugins.provide("settings") { m, a in stub.handle(m, a) } }
    rt.call("commands", "open", ["mode": "new", "query": .string(q)])
    rt.ui.commandBar.input.currentEditor()?.selectedRange = NSRange(location: (q as NSString).length, length: 0)
    return rt.window.window
  }
}

// thin-host: feature-specific, migrate to plugin. Snapshot-only stand-in for the settings plugin's
// registry (its strings belong to that plugin); delete once the `settings` service lands.
/// A small in-memory settings registry shaped like the proposed `settings` service (list, set, open).
final class LauncherSettingsStub: @unchecked Sendable {
  var values: [String: Value] = ["appearance.webDark": false, "appearance.mode": "auto", "general.askQuit": true, "privacy.trackers": true]

  func pane(_ id: String, _ title: String, _ icon: String, _ schema: [Value]) -> Value {
    ["id": .string(id), "title": .string(title), "icon": .string(icon), "schema": .array(schema.map { s in
      guard case var .object(pairs) = s else { return s }
      pairs.append(("value", values[s.str("key")] ?? .null))
      return .object(pairs)
    })]
  }

  func handle(_ m: String, _ a: Value) -> Value {
    switch m {
    case "list":
      let modes: Value = [["value": "auto", "title": "Automatic"], ["value": "light", "title": "Light"], ["value": "dark", "title": "Dark"]]
      return [
        pane("general", "General", "sf:gearshape", [["key": "general.askQuit", "title": "Ask before quitting", "type": "toggle"]]),
        pane("appearance", "Appearance", "sf:paintbrush", [
          ["key": "appearance.webDark", "title": "Dark mode for websites", "type": "toggle", "icon": "sf:moon", "keywords": ["night"]],
          ["key": "appearance.mode", "title": "Appearance", "type": "choice", "icon": "sf:circle.lefthalf.filled", "options": modes],
        ]),
        pane("privacy", "Privacy", "sf:hand.raised", [["key": "privacy.trackers", "title": "Block trackers", "type": "toggle"]]),
      ]
    case "set":
      values[a.str("key")] = a["value"]
      return ["ok": true]
    default:
      return ["ok": true]
    }
  }
}
#endif
