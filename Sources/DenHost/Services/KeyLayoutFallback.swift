import AppKit

/// Shortcuts on non-US keyboards. AppKit matches menu key equivalents by the character a key
/// types (and localizes common ones for the current layout), which is right for Dvorak and
/// QWERTZ letters. It fails where a layout can't type the shortcut's character without extra
/// modifiers: AZERTY's number row (⌃1 is ⌃&), brackets behind dead keys (⌘[ is ⌘^), and every
/// letter on Cyrillic, Greek or Hebrew layouts. For those keys only, den falls back to the key's
/// US position, as Chrome and Firefox do (Dia 1.10.1).
///
/// The fallback runs only when nothing in the menu bar matches the typed character: a layout's
/// own shortcut always wins. It never applies to a Latin letter or digit typed as itself.
@MainActor
enum KeyLayoutFallback {
  /// The US (ANSI) character of each physical key (`NSEvent.keyCode`).
  static let usKeys: [UInt16: String] = [
    0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
    16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
    30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/",
    45: "n", 46: "m", 47: ".", 50: "`",
  ]

  static let relevant: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

  /// The menu item a key press should run by its US position, or nil to leave the event alone.
  static func item(for e: NSEvent, in menu: NSMenu?) -> NSMenuItem? {
    let flags = e.modifierFlags.intersection(relevant)
    guard flags.contains(.command) || flags.contains(.control), let us = usKeys[e.keyCode], let menu else { return nil }
    let typed = (e.charactersIgnoringModifiers ?? "").lowercased()
    guard !typed.isEmpty, typed != us, let t = typed.unicodeScalars.first else { return nil }
    // A Latin letter or digit typed as itself keeps its meaning (Dvorak, QWERTZ, AZERTY letters).
    if t.isASCII, CharacterSet.alphanumerics.contains(t) { return nil }
    // ASCII punctuation where US has a letter (Dvorak's , at W): by character too.
    if t.isASCII, us.unicodeScalars.first.map({ CharacterSet.letters.contains($0) }) == true { return nil }
    // The layout's own character is a shortcut: it wins.
    if find(typed, flags, in: menu) != nil { return nil }
    return find(us, flags, in: menu)
  }

  /// A menu item (hidden alternates included) whose key equivalent is `key` with `flags`.
  /// Shifted punctuation is stored as AppKit matches it: ⌘⇧] is "}" with ⌘ (MainMenu.setKey).
  static func find(_ key: String, _ flags: NSEvent.ModifierFlags, in menu: NSMenu) -> NSMenuItem? {
    var candidates = [(key, flags)]
    if flags.contains(.shift), let shifted = Chord.shiftedPunctuation[key] { candidates.append((shifted, flags.subtracting(.shift))) }
    // No `mi` inside an autoclosure (`a || mi.x`) or a where clause: a clean Swift 6.3 build flags
    // them as "sending 'mi' risks causing data races".
    @MainActor func walk(_ m: NSMenu) -> NSMenuItem? {
      for mi in m.items {
        if let s = mi.submenu, let hit = walk(s) { return hit }
        let hiddenOK = mi.allowsKeyEquivalentWhenHidden
        guard !mi.keyEquivalent.isEmpty, !mi.isHidden || hiddenOK else { continue }
        let mask = mi.keyEquivalentModifierMask.intersection(relevant)
        let key = mi.keyEquivalent.lowercased()
        if candidates.contains(where: { $0.0 == key && $0.1 == mask }) { return mi }
      }
      return nil
    }
    return walk(menu)
  }

  /// Runs `e` by position if it needs to; true when it did (the event is then consumed).
  static func perform(_ e: NSEvent, in menu: NSMenu? = NSApp.mainMenu) -> Bool {
    guard let mi = item(for: e, in: menu), let parent = mi.menu else { return false }
    let i = parent.index(of: mi)
    guard i >= 0 else { return false }
    parent.update()
    guard mi.isEnabled else { return false }
    parent.performActionForItem(at: i)
    return true
  }
}
