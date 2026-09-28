import AppKit
import CordisValue

/// "Shortcuts everywhere an action appears" (docs/guide/_in-app-tips.md): the chord a surface
/// shows next to an action is read from the menu bar item that runs it, so a `[shortcuts]` remap
/// in config.toml shows up on every surface at once.
///
/// A `ref` names the action, any of:
/// - a menu bar item id (`tabs.pin`, `edit.copyURL`, `view.addSplit`; docs/shortcuts.md),
/// - a plugin event bound with `keys.bind` (`tabs.key.pin`),
/// - a command id bound by `[shortcuts]` (`den.duplicateTab`).
/// Nodes carry it as `keyFor` (context menu items) or `shortcutFor` (buttons, card actions); the
/// static `key` / `shortcut` stays the fallback. Resolved when the surface is built or hovered:
/// zero cost while nothing asks.
@MainActor
public enum Shortcuts {
  /// The live keys service (for plugin-owned items that have no menu bar slot).
  static weak var keys: KeysService?

  /// The menu item currently carrying the ref's key equivalent, or nil (unbound, no menu bar).
  static func item(_ ref: String) -> NSMenuItem? {
    guard !ref.isEmpty else { return nil }
    // Known ids only: a miss would walk the whole menu bar.
    let byId = MainMenu.entryById[ref] != nil ? MainMenu.item(ref) : nil
    // Not `isHidden`: command items hide while their command can't run, and an unbound slot has
    // no key equivalent anyway.
    if let mi = byId ?? MainMenu.slot(for: ref) ?? MainMenu.commandItem(ref), !mi.keyEquivalent.isEmpty, mi.menu != nil { return mi }
    guard let k = keys else { return nil }
    let live = k.bindings.values.filter { $0.item.menu != nil && !$0.item.keyEquivalent.isEmpty }
    let hit = live.filter { ($0.event == ref && $0.payload.isNull) || ($0.event == "config.shortcut" && $0.payload.str("id") == ref) }
    return (hit.first { !$0.item.isHidden } ?? hit.min { $0.chord < $1.chord })?.item
  }

  /// The chord the user presses now for `ref`, as a chord string ("cmd+shift+c"), or nil.
  public static func chord(for ref: String) -> String? {
    item(ref).flatMap(chord(of:))
  }

  /// A menu item's key equivalent as a chord string: `{"}", ⌘}` → "shift+cmd+]".
  static func chord(of mi: NSMenuItem) -> String? {
    var key = mi.keyEquivalent
    guard key.count == 1, let scalar = key.unicodeScalars.first else { return nil }
    let mask = mi.keyEquivalentModifierMask
    var shift = mask.contains(.shift)
    let named: [UInt32: String] = [0xF700: "up", 0xF701: "down", 0xF702: "left", 0xF703: "right", 0x09: "tab", 0x0D: "return", 0x03: "enter",
                                   0x1B: "esc", 0x20: "space", 0x08: "delete", 0x7F: "delete", 0x2B: "plus"]
    if let n = named[scalar.value] {
      key = n
    } else if (0xF704...0xF717).contains(scalar.value) {
      key = "f" + String(scalar.value - 0xF704 + 1)
    } else if key.lowercased() != key {
      shift = true
      key = key.lowercased()
    } else if let base = Chord.shiftedPunctuation.first(where: { $0.value == key })?.key {
      shift = true
      key = base
    }
    var parts: [String] = []
    if mask.contains(.control) { parts.append("ctrl") }
    if mask.contains(.option) { parts.append("opt") }
    if shift { parts.append("shift") }
    if mask.contains(.command) { parts.append("cmd") }
    return (parts + [key]).joined(separator: "+")
  }

  /// "⇧⌘C" for `ref`, else the fallback chord's glyphs, else "".
  public static func glyphs(for ref: String, fallback: String = "") -> String {
    ShortcutRecorder.display(chord(for: ref) ?? fallback)
  }

  /// A tooltip naming an action and its chord: "Copy Link  ⇧⌘C" (two spaces, like the card
  /// tooltips), or just the title when the action has no shortcut.
  public static func tip(_ title: String, _ ref: String = "", fallback: String = "") -> String {
    let g = glyphs(for: ref, fallback: fallback)
    guard !g.isEmpty else { return title }
    return title.isEmpty ? g : title + "  " + g
  }

  /// Sets a context menu item's key equivalent from `ref` (remap-aware); false when it has none.
  static func apply(_ ref: String, to mi: NSMenuItem) -> Bool {
    guard let src = item(ref) else { return false }
    mi.keyEquivalent = src.keyEquivalent
    mi.keyEquivalentModifierMask = src.keyEquivalentModifierMask
    return true
  }
}
