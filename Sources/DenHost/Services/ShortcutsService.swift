// The `shortcuts` service: manages the Settings > Shortcuts section.
//
// Methods:
//   registerSettings   -> registers a settings section with all menu bar shortcuts as shortcut controls
//   change {key, chord} -> applies a shortcut change (keys.remap / keys.bind) and persists to config.toml

import AppKit
import CordisValue

// Builtin command bar IDs used for filtering custom shortcuts.
// Kept in sync with CommandBarCore.builtins.
let shortcutBuiltinIds: Set<String> = [
  "den.new", "den.home", "den.search", "den.shortcuts", "den.about",
  "den.quit", "den.new.githubIssue",
]

@MainActor
public final class ShortcutsService: HostService {
  public let name = "shortcuts"
  let host: ServiceHost
  private let settings: SettingsService?
  private let keys: KeysService?

  init(host: ServiceHost, settings: SettingsService?, keys: KeysService?) {
    self.host = host
    self.settings = settings
    self.keys = keys
  }

  public func handle(method: String, args: Value) -> Value {
    switch method {
    case "registerSettings":
      registerShortcutsSettings()
      return .ok
    case "change":
      let key = args.str("key")
      let chord = args.str("chord")
      applyShortcutChange(key: key, chord: chord)
      return .ok
    default:
      return .error("shortcuts: unknown method '\(method)'")
    }
  }

  // MARK: - Settings registration

  private func registerShortcutsSettings() {
    let keysList = host.call("keys", "list").array ?? []
    var bindingsByEvent: [String: String] = [:]
    for b in keysList {
      guard let dict = b.object, let chord = dict.first(where: { $0.0 == "chord" })?.1.string,
            let event = dict.first(where: { $0.0 == "event" })?.1.string,
            !chord.isEmpty else { continue }
      bindingsByEvent[event] = chord
    }

    let menuIds = Set(MainMenu.entries.map(\.id))

    var controls: [Value] = []
    var idx = 0

    for (menuName, entries) in MainMenu.layout {
      for entry in entries {
        guard !entry.id.isEmpty else { continue }

        var chord: String? = nil

        // Check the actual installed menu item for current key equivalent.
        if let mi = MainMenu.item(entry.id) {
          let c = currentChord(of: mi)
          if !c.isEmpty { chord = c }
        }

        // If no key on the item itself, check if a keys.bind chord is overriding it.
        if chord?.isEmpty ?? true {
          if case let .event(ev) = entry.kind {
            chord = bindingsByEvent[ev]
          }
        }

        guard let chord else { continue }

        let key = "m" + String(idx)
        controls.append([
          "key": .string(key), "type": .string("shortcut"),
          "title": .string(entry.title), "subtitle": .string(menuName),
          "default": .string(chord),
        ])
        idx += 1
      }
    }

    // Custom shortcuts from config.toml that aren't standard menu items or builtins.
    let config = host.call("config", "get")
    if case let .object(pairs) = config["shortcuts"] {
      for (chord, target) in pairs {
        let id = target.string ?? ""
        guard !id.isEmpty, !menuIds.contains(id), shortcutBuiltinIds.contains(id) == false else { continue }
        let key = "c" + String(idx)
        controls.append([
          "key": .string(key), "type": .string("shortcut"),
          "title": .string(id), "subtitle": .string(displayChord(chord)),
          "default": .string(chord),
        ])
        idx += 1
      }
    }

    _ = host.call("settings", "register", [
      "id": .string("shortcuts"), "title": "Shortcuts", "icon": "sf:keyboard", "order": 25,
      "controls": .array(controls),
    ])
  }

  // MARK: - Change handling

  private func applyShortcutChange(key: String, chord: String) {
    // Parse the control key to determine if it's menu bar or custom.
    let isMenu = key.hasPrefix("m")
    let index = Int(String(key.dropFirst())) ?? -1

    if isMenu {
      // Find the corresponding menu bar entry.
      var idx = 0
      var targetId: String?
      for (_, entries) in MainMenu.layout {
        for entry in entries {
          guard !entry.id.isEmpty else { continue }
          var foundChord: String?
          if let mi = MainMenu.item(entry.id) {
            let c = currentChord(of: mi)
            if !c.isEmpty { foundChord = c }
          }
          if foundChord != nil {
            if idx == index { targetId = entry.id; break }
            idx += 1
          }
        }
        if targetId != nil { break }
      }
      guard let targetId else { return }

      guard let entry = MainMenu.entryById[targetId] else { return }

      if chord.isEmpty {
        // Restore default by removing from config.
        let config = host.call("config", "get")
        var pairs: [String: Value] = [:]
        if case let .object(p) = config["shortcuts"] {
          for (k, v) in p {
            if v.string != targetId { pairs[k] = v }
          }
        }
        _ = host.call("config", "save", ["config": config.with("shortcuts", .object(pairs.map { ($0.key, $0.value) }))])
      } else {
        // Remap.
        let c = chord.lowercased()
        guard Chord.parse(c) != nil else { return }
        host.call("keys", "remap", ["chord": .string(c), "item": .string(targetId)])
        // Persist to config.toml.
        persistShortcut(chord: c, target: targetId)
      }
    }
    else {
      // Custom shortcut: key is "c<idx>". Find target id from config.toml.
      let config = host.call("config", "get")
      var customTargets: [(chord: String, target: String)] = []
      if case let .object(pairs) = config["shortcuts"] {
        let menuIds = Set(MainMenu.entries.map(\.id))
        for (ch, t) in pairs {
          let id = t.string ?? ""
          if !id.isEmpty, !menuIds.contains(id), shortcutBuiltinIds.contains(id) == false {
            customTargets.append((ch, id))
          }
        }
      }
      guard index < customTargets.count else { return }
      let targetId = customTargets[index].target

      let c = chord.lowercased()
      if chord.isEmpty {
        // Unbind: remove from config.toml.
        removeShortcut(target: targetId)
      }
      else if Chord.parse(c) != nil {
        host.call("keys", "bind", [
          "chord": .string(c), "event": .string("commands.shortcut"),
          "title": .string(targetId), "menu": .string("Shortcuts"),
          "payload": ["id": .string(targetId)],
        ])
        persistShortcut(chord: c, target: targetId)
      }
    }

    // Refresh the panel.
    registerShortcutsSettings()
  }

  // MARK: - Helpers

  /// "cmd+shift+c" → "⇧⌘C" (Apple's modifier order: ⌃⌥⇧⌘).
  private func displayChord(_ chord: String) -> String {
    guard !chord.isEmpty else { return "" }
    let parts = chord.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
    let key = parts.last ?? ""
    var s = ""
    if parts.contains("ctrl") || parts.contains("control") { s += "⌃" }
    if parts.contains("opt") || parts.contains("option") || parts.contains("alt") { s += "⌥" }
    if parts.contains("shift") { s += "⇧" }
    if parts.contains("cmd") || parts.contains("command") { s += "⌘" }
    let named: [String: String] = [
      "left": "←", "right": "→", "up": "↑", "down": "↓", "tab": "⇥",
      "return": "↩", "enter": "↩", "esc": "⎋", "escape": "⎋",
      "space": "Space", "delete": "⌫", "backspace": "⌫", "plus": "+", "minus": "-",
    ]
    return s + (named[key] ?? key.uppercased())
  }

  /// Current key equivalent from an NSMenuItem as a keys-style chord string.
  private func currentChord(of mi: NSMenuItem) -> String {
    var key = mi.keyEquivalent
    guard key.count == 1, let scalar = key.unicodeScalars.first else { return "" }
    let mask = mi.keyEquivalentModifierMask
    var parts: [String] = []
    if mask.contains(.control) { parts.append("ctrl") }
    if mask.contains(.option) { parts.append("opt") }
    if mask.contains(.shift) { parts.append("shift") }
    if mask.contains(.command) { parts.append("cmd") }
    guard !parts.isEmpty else { return "" }

    let named: [UInt32: String] = [
      0xF700: "up", 0xF701: "down", 0xF702: "left", 0xF703: "right",
      0x09: "tab", 0x0D: "return", 0x03: "enter", 0x1B: "esc",
      0x20: "space", 0x08: "delete", 0x7F: "delete", 0x2B: "plus",
    ]
    if let n = named[scalar.value] { key = n }
    else if (0xF704...0xF717).contains(scalar.value) { key = "f" + String(scalar.value - 0xF704 + 1) }
    else if key.lowercased() != key { parts.append("shift"); key = key.lowercased() }
    else if let base = Chord.shiftedPunctuation.first(where: { $0.value == key })?.key {
      parts.append("shift"); key = base
    }
    return (parts + [key]).joined(separator: "+")
  }

  // MARK: - Config persistence

  private func persistShortcut(chord: String, target: String) {
    var config = host.call("config", "get")
    guard var shortcuts: [(String, Value)] = extractObject(config["shortcuts"]) else {
      config.put("shortcuts", .object([("key", .string(chord.lowercased())), ("value", .string(target))]))
      _ = host.call("config", "save", ["config": config])
      return
    }
    if let i = shortcuts.firstIndex(where: { $0.0 == chord.lowercased() }) {
      shortcuts[i].1 = .string(target)
    }
    else {
      shortcuts.append((chord.lowercased(), .string(target)))
    }
    config.put("shortcuts", .object(shortcuts))
    _ = host.call("config", "save", ["config": config])
  }

  private func removeShortcut(target: String) {
    var config = host.call("config", "get")
    guard var shortcuts: [(String, Value)] = extractObject(config["shortcuts"]) else { return }
    shortcuts.removeAll { $0.1.string == target }
    config.put("shortcuts", .object(shortcuts))
    _ = host.call("config", "save", ["config": config])
  }

  private func extractObject(_ v: Value) -> [(String, Value)]? {
    guard case let .object(pairs) = v else { return nil }
    return pairs
  }
}
