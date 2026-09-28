import AppKit
import CordisValue

/// Native context menus built from a node's `menu` field.
///
/// Item shapes:
///   {id, title, icon?, key?, alternate?, destructive?, enabled=true, checked?, items?: [item]}   (items = submenu)
/// - `alternate`: shown instead of the item above it while ⌥ is held (NSMenuItem.isAlternate).
/// - `paste: true, titleURL?`: a clipboard item (Paste and Go). Shown only while the clipboard holds
///   one line of text; titled `titleURL` when that text is an address, `title` otherwise. The
///   plugin reads the text with `app.pasteboard` when it's picked.
///   {separator: true}
///   {header: "Title"}                                                                 (section header)
/// - `icon`: `sf:<symbol>` (tinted red when destructive).
/// - `key`: a chord hint shown on the right (`cmd+w`, `ctrl+shift+=`); display only, the real
///   binding lives in the `keys` service.
/// - `keyFor`: the action's menu bar item id or bound event (`tabs.pin`, `tabs.key.pin`): the hint
///   is read from the menu bar when the menu opens, so a `[shortcuts]` remap shows here too
///   (`Shortcuts`). Falls back to `key`.
/// Picking an item emits `menu` with the item's id (submenu items too).
@MainActor
enum ContextMenu {
  static let destructiveColor = NSColor(srgbRed: 0xF5 / 255, green: 0x37 / 255, blue: 0x14 / 255, alpha: 1)  // spec §3 DestructiveButtonFace

  static func build(_ items: [Value], target: AnyObject, action: Selector) -> NSMenu {
    let m = NSMenu()
    m.autoenablesItems = false
    for it in items {
      if it.flag("separator") { m.addItem(.separator()); continue }
      if let h = it["header"].string { m.addItem(.sectionHeader(title: h)); continue }
      var title = it.str("title")
      if it.flag("paste") {
        // Paste and Go / Paste and Search: named for what's on the clipboard now; left out when
        // there's no one-line text to paste.
        guard let t = PasteText.title(url: it.str("titleURL", title), search: title) else { continue }
        title = t
      }
      let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      mi.representedObject = it.str("id")
      mi.isEnabled = it.flag("enabled", true)
      mi.state = it.flag("checked") ? .on : .off
      let destructive = it.flag("destructive")
      if it.str("icon").hasPrefix("sf:"), let img = IconView.symbol(String(it.str("icon").dropFirst(3))) {
        if destructive {
          let cfg = NSImage.SymbolConfiguration(paletteColors: [destructiveColor])
          mi.image = img.withSymbolConfiguration(cfg) ?? img
        } else {
          mi.image = img
        }
      }
      if destructive {
        mi.attributedTitle = NSAttributedString(string: mi.title, attributes: [.foregroundColor: destructiveColor, .font: NSFont.menuFont(ofSize: 0)])
      }
      if Shortcuts.apply(it.str("keyFor"), to: mi) {
        // Read from the menu bar (remaps included).
      } else if let chord = Chord.parse(it.str("key")) {
        mi.keyEquivalent = chord.key
        var mask: NSEvent.ModifierFlags = []
        if chord.mods.contains(.cmd) { mask.insert(.command) }
        if chord.mods.contains(.shift) { mask.insert(.shift) }
        if chord.mods.contains(.opt) { mask.insert(.option) }
        if chord.mods.contains(.ctrl) { mask.insert(.control) }
        mi.keyEquivalentModifierMask = mask
      } else {
        // No shortcut: an empty mask, so an ⌥ alternate below can differ from it by ⌥ alone.
        mi.keyEquivalentModifierMask = it.flag("alternate") ? [.option] : []
      }
      // `alternate`: replaces the item above it while ⌥ is held (same key, ⌥ added to its mask).
      // A remap can leave the two with different keys; AppKit would then show both anyway, so
      // they stay two plain items with their real chords.
      if it.flag("alternate"), let above = m.items.last, !above.isSeparatorItem, above.keyEquivalent == mi.keyEquivalent,
         above.keyEquivalentModifierMask.union(.option) == mi.keyEquivalentModifierMask.union(.option) {
        mi.isAlternate = true
        mi.keyEquivalentModifierMask.insert(.option)
      }
      let sub = it.list("items")
      if !sub.isEmpty {
        mi.submenu = build(sub, target: target, action: action)
      } else {
        mi.target = target
        mi.action = action
      }
      m.addItem(mi)
    }
    return m
  }
}
