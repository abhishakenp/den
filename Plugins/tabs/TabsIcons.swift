// Emoji (and symbol) icons for tabs and folders (Arc): "Change Icon…" in the context menu, the
// icon at the row's left while renaming, or an emoji typed at the start of the name. The icon
// replaces the favicon (or the folder symbol) on the row, the favorites tile and the hover card,
// is saved with the tab or folder, and ⌃Z undoes it.

#if !hasFeature(Embedded)
  import CordisValue
#endif

extension TabsCore {
  static let iconPickerId = "tabs.iconPicker"

  /// The icon the user chose for a tab or folder, if any.
  func customIcon(_ id: String) -> String? { tabs[id]?.customIcon ?? folders[id]?.icon }

  /// "Change Icon…", plus "Remove Icon" once one is set (the same for tabs and folders).
  func iconMenuItems(hasIcon: Bool) -> [Value] {
    var m: [Value] = [["id": "changeIcon", "title": "Change Icon…", "icon": "sf:face.smiling"]]
    if hasIcon { m.append(["id": "removeIcon", "title": "Remove Icon", "icon": "sf:xmark.circle"]) }
    return m
  }

  /// Returns true when `item` was an icon item.
  func iconMenuPicked(_ id: String, _ item: String) -> Bool {
    switch item {
    case "changeIcon": openIconPicker(id)
    case "removeIcon": setIcon(id, nil)
    default: return false
    }
    return true
  }

  /// Sets a tab's or folder's icon; nil or "" goes back to the favicon / folder symbol. Undoable.
  func setIcon(_ id: String, _ icon: String?) {
    let v: String? = (icon ?? "").isEmpty ? nil : icon
    guard tabs[id] != nil || folders[id] != nil, customIcon(id) != v else { return }
    checkpoint()
    if tabs[id] != nil { tabs[id]?.customIcon = v } else { folders[id]?.icon = v }
    changed(spaceOf(id) ?? folders[id]?.spaceId)
  }

  /// The icon picker in the popover slot, next to the row (the host's `iconPicker` node, shared
  /// with the space menu).
  func openIconPicker(_ id: String) {
    guard tabs[id] != nil || folders[id] != nil else { return }
    iconEditing = id
    let title: String
    if folders[id] != nil { title = kindOfFolder(id) == "today" ? "Group Icon" : "Folder Icon" } else { title = "Tab Icon" }
    env.call("ui", "set", ["slot": "popover", "tree": [
      "type": "iconPicker", "id": .string(Self.iconPickerId), "anchor": .string(id),
      "title": .string(title), "selected": .string(customIcon(id) ?? ""),
    ]])
  }

  func closeIconPicker() {
    guard iconEditing != nil else { return }
    iconEditing = nil
    env.call("ui", "set", ["slot": "popover", "tree": nil])
  }

  func iconPickerAction(_ action: String, _ value: Value) {
    switch action {
    case "pick":
      if let id = iconEditing { setIcon(id, value.s("icon")) }
      closeIconPicker()
    case "dismiss": closeIconPicker()
    default: break
    }
  }

  /// "today" for a group in Today, else the section its top folder sits in.
  func kindOfFolder(_ fid: String) -> String {
    guard let (b, _) = locate(fid) else { return "pinned" }
    return kind(of: b)
  }

  /// An inline rename from the sidebar. A name that starts with an emoji ("🔥 Deals") makes the
  /// emoji the icon and the rest the title; just an emoji only changes the icon. One undo step.
  func renameFromSidebar(_ id: String, _ text: String) {
    guard let (emoji, rest) = Self.leadingEmoji(text) else { rename(id, text); return }
    checkpoint()
    if tabs[id] != nil {
      tabs[id]?.customIcon = emoji
      if !rest.isEmpty { tabs[id]?.customTitle = rest }
    } else if folders[id] != nil {
      folders[id]?.icon = emoji
      if !rest.isEmpty {
        folders[id]?.title = rest
        folders[id]?.auto = false
        naming.remove(id)
      }
    }
    changed(spaceOf(id) ?? folders[id]?.spaceId)
  }

  // MARK: Emoji at the start of a name (pure, tested; byte-level so it works in Embedded Swift)

  /// Splits "🚀 Launch" into ("🚀", "Launch"). A leading emoji is a pictographic scalar (or any
  /// non-ASCII scalar followed by U+FE0F, or a keycap), with its modifiers: variation selectors,
  /// skin tones, tags, keycap, ZWJ sequences and flag pairs. nil when the text doesn't start with one.
  static func leadingEmoji(_ text: String) -> (String, String)? {
    let b = Array(text.utf8)
    var scalars: [(UInt32, Int)] = []  // (scalar, end byte offset), up to 16 scalars
    var i = 0
    while i < b.count && scalars.count < 16 {
      let c = b[i]
      var n = 1
      var v = UInt32(c)
      if c >= 0xF0 { n = 4; v = UInt32(c & 0x07) } else if c >= 0xE0 { n = 3; v = UInt32(c & 0x0F) } else if c >= 0xC0 { n = 2; v = UInt32(c & 0x1F) }
      guard i + n <= b.count else { return nil }
      if n > 1 { for k in 1..<n { v = (v << 6) | UInt32(b[i + k] & 0x3F) } }
      i += n
      scalars.append((v, i))
    }
    guard let first = scalars.first else { return nil }
    func pictographic(_ v: UInt32) -> Bool {
      (v >= 0x1F000 && v <= 0x1FAFF && !(v >= 0x1F3FB && v <= 0x1F3FF)) || (v >= 0x2600 && v <= 0x27BF)
        || (v >= 0x2B00 && v <= 0x2BFF) || (v >= 0x2300 && v <= 0x23FF)
    }
    func regional(_ v: UInt32) -> Bool { v >= 0x1F1E6 && v <= 0x1F1FF }
    func modifier(_ v: UInt32) -> Bool {
      v == 0xFE0F || v == 0xFE0E || v == 0x20E3 || (v >= 0x1F3FB && v <= 0x1F3FF) || (v >= 0xE0020 && v <= 0xE007F)
    }
    let next = scalars.count > 1 ? scalars[1].0 : 0
    let keycap = (first.0 == 35 || first.0 == 42 || (first.0 >= 48 && first.0 <= 57)) && (next == 0x20E3 || (next == 0xFE0F && scalars.count > 2 && scalars[2].0 == 0x20E3))
    guard pictographic(first.0) || keycap || (first.0 >= 0xA0 && next == 0xFE0F) else { return nil }
    var k = 1
    if regional(first.0), k < scalars.count, regional(scalars[k].0) { k += 1 }
    while k < scalars.count {
      let v = scalars[k].0
      if modifier(v) { k += 1; continue }
      if v == 0x200D, k + 1 < scalars.count { k += 2; continue }
      break
    }
    let end = scalars[k - 1].1
    let emoji = String(decoding: b[0..<end], as: UTF8.self)
    var r = end
    while r < b.count && (b[r] == 32 || b[r] == 9) { r += 1 }
    var e = b.count
    while e > r && (b[e - 1] == 32 || b[e - 1] == 9) { e -= 1 }
    return (emoji, String(decoding: b[r..<e], as: UTF8.self))
  }
}
