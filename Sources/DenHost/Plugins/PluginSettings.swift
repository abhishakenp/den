import Cordis
import CordisValue
import Foundation

/// Settings ▸ Plugins: what each third-party plugin may do (revoke it, turn it off or on), and
/// any plugin that crashed this run (reload it). Built when the pane is shown.
@MainActor
enum PluginSettings {
  static func install(_ rt: DenRuntime) {
    let s = rt.settings
    s.builtins["plugins"] = { [unowned rt] in
      SettingsService.Entry(id: "plugins", section: "plugins", title: "Plugins", icon: "sf:puzzlepiece.extension", order: 90, controls: controls(rt))
    }
    s.builtinActions["plugins"] = { [unowned rt] key, item, button in
      guard let id = item else { return }
      switch button {
      case "revoke": rt.consent.revoke(id)
      case "off": rt.consent.setDisabled(id, true)
      case "on": rt.consent.setDisabled(id, false)
      case "reload":
        if let r = rt.crashes.crashes[id] { rt.crashes.reload(id, URL(fileURLWithPath: r.path)) }
      default: break
      }
      rt.settings.window?.reload()
    }
  }

  static func controls(_ rt: DenRuntime) -> [Value] {
    var items: [Value] = []
    let loaded = Dictionary(rt.plugins.plugins.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let third = rt.consent.files.keys.sorted()
    for id in third {
      let info = loaded[id]
      var lines: [String] = []
      if rt.consent.disabled.contains(id) {
        lines.append("Turned off")
      } else if let g = rt.consent.grant(id) {
        lines.append(g.denied ? "Not allowed" : g.granted.isEmpty ? "Allowed with no permissions" : "Allowed: " + g.granted.joined(separator: ", "))
      } else {
        lines.append("Uses no permissions")
      }
      if let r = rt.crashes.crashes[id] { lines.append("Crashed (\(signalName(r.signal)))") } else if info?.state == .active { lines.append("Running in its own sandbox") }
      var buttons: [Value] = []
      if rt.crashes.crashes[id] != nil { buttons.append(["id": "reload", "title": "Reload"]) }
      if rt.consent.grant(id) != nil { buttons.append(["id": "revoke", "title": "Revoke", "style": "destructive"]) }
      buttons.append(rt.consent.disabled.contains(id) ? ["id": "on", "title": "Turn On"] : ["id": "off", "title": "Turn Off"])
      items.append(["id": .string(id), "title": .string(info?.name ?? id), "subtitle": .string(lines.joined(separator: " · ")), "icon": "sf:puzzlepiece.extension", "buttons": .array(buttons)])
    }
    // den's own plugins only show up here when one crashed this run.
    for (id, r) in rt.crashes.crashes.sorted(by: { $0.key < $1.key }) where !third.contains(id) {
      items.append(["id": .string(id), "title": .string(loaded[id]?.name ?? id), "subtitle": .string("Crashed (\(signalName(r.signal))); den keeps running without it"),
                    "icon": "sf:exclamationmark.triangle", "buttons": [["id": "reload", "title": "Reload"], ["id": "off", "title": "Turn Off"]]])
    }
    return [
      ["key": "list", "type": "list", "title": "Plugins",
       "subtitle": "Plugins in ~/.den/plugins run in their own sandbox and can only use what you allowed when they first loaded.",
       "items": .array(items), "empty": "No plugins from ~/.den/plugins yet."],
    ]
  }
}
