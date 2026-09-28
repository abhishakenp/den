// The `spaces` service: the list of Spaces, the current one, per-Space themes, the sidebar's
// space header and footer, the space shortcuts and swipe paging. See docs/plugin-services.md.

#if !hasFeature(Embedded)
  import CordisValue
#endif

final class SpacesCore {
  struct Space {
    var id: String
    var name: String
    var icon: String
    var theme: Value
    var profile: String

    var value: Value {
      ["id": .string(id), "name": .string(name), "icon": .string(icon), "theme": theme, "profile": .string(profile)]
    }

    init(id: String, name: String, icon: String, theme: Value, profile: String) {
      self.id = id
      self.name = name
      self.icon = icon
      self.theme = theme
      self.profile = profile
    }

    init?(_ v: Value) {
      guard let id = v["id"].string else { return nil }
      self.init(id: id, name: v.s("name"), icon: v.s("icon"), theme: v["theme"], profile: v.sOpt("profile") ?? "default")
    }
  }

  static let ns = "spaces"

  /// Arc-like gradients: the first three seed the default Spaces, the rest are offered to new ones.
  static let palettes: [[String]] = [
    ["#c3b1ff", "#ffb3d1"],
    ["#8fd3ff", "#9af0d0"],
    ["#ffc78a", "#ff9b9b", "#ffe38a"],
    ["#b6e3a8", "#8fdcc9"],
    ["#a9c1ff", "#d7b8ff"],
    ["#ffb5a7", "#ffd6a5"],
    ["#9be7ff", "#c5b8ff", "#ffc2e2"],
    ["#d0d4dc", "#aab4c3"],
  ]

  static func theme(_ colors: [String]) -> Value {
    ["colors": .array(colors.map { .string($0) }), "intensity": 0.6, "grain": 0.3, "appearance": "auto"]
  }

  let env: PluginEnv
  var spaces: [Space] = []
  var current = ""
  var nextId: Int64 = 1
  /// True until the first render has placed the pager; later renders never jump pages.
  var placedPager = false
  /// The footer's download indicator (host `downloads.changed`): running downloads, finished ones
  /// not looked at yet, and overall progress in percent (-1 unknown). Absent when all are 0.
  var dlActive: Int64 = 0
  var dlUnseen: Int64 = 0
  var dlPercent: Int64 = -1

  init(env: PluginEnv) { self.env = env }

  // MARK: Lifecycle

  func start() {
    load()
    bindKeys()
    env.on("ui.action") { [self] v in action(v.s("id"), v.s("action"), v["value"]) }
    env.on("downloads.changed") { [self] v in downloadsChanged(v) }
    env.on("spaces.key.jump") { [self] v in
      let i = Int(v["payload"].int ?? 0)
      if i < spaces.count { switchTo(i, direction: "jump", animated: true) }
    }
    env.on("spaces.key.next") { [self] _ in step(1) }
    env.on("spaces.key.prev") { [self] _ in step(-1) }
    renderAll(themes: true)
    emitChanged()
  }

  func load() {
    let stored = env.call("storage", "get", ["ns": .string(Self.ns), "key": "spaces"])
    spaces = (stored.array ?? []).compactMap { Space($0) }
    nextId = env.call("storage", "get", ["ns": .string(Self.ns), "key": "nextId"]).int ?? 1
    if spaces.isEmpty {
      let seed: [(String, String)] = [("Personal", "sf:house.fill"), ("Work", "sf:briefcase.fill"), ("Side Project", "sf:hammer.fill")]
      for (j, s) in seed.enumerated() {
        spaces.append(Space(id: newId(), name: s.0, icon: s.1, theme: Self.theme(Self.palettes[j]), profile: "default"))
      }
    }
    current = env.call("storage", "get", ["ns": .string(Self.ns), "key": "current"]).string ?? ""
    if index(of: current) == nil { current = spaces[0].id }
    save()
  }

  func save() {
    env.call("storage", "set", ["ns": .string(Self.ns), "key": "spaces", "value": .array(spaces.map { $0.value })])
    env.call("storage", "set", ["ns": .string(Self.ns), "key": "current", "value": .string(current)])
    env.call("storage", "set", ["ns": .string(Self.ns), "key": "nextId", "value": .int(nextId)])
  }

  func newId() -> String {
    defer { nextId += 1 }
    return "space-" + String(nextId)
  }

  func index(of id: String) -> Int? { spaces.firstIndex { $0.id == id } }
  var currentIndex: Int { index(of: current) ?? 0 }

  // MARK: Service

  func handle(_ method: String, _ args: Value) -> Value {
    switch method {
    case "list":
      return .array(spaces.map { $0.value })
    case "current":
      return ["id": .string(current)]
    case "switch":
      if let id = args["id"].string {
        guard let i = index(of: id) else { return .err("spaces: no space '" + id + "'") }
        switchTo(i, direction: "jump", animated: args.b("animated", true))
      } else {
        let d = args.s("direction")
        guard d == "next" || d == "prev" else { return .err("spaces: switch needs id or direction") }
        step(d == "next" ? 1 : -1)
      }
      return .okay
    case "create":
      let id = create(name: args.sOpt("name"), icon: args["icon"].string, theme: args["theme"], profile: args.sOpt("profile"))
      return ["id": .string(id)]
    case "update":
      guard let i = index(of: args.s("id")) else { return .err("spaces: no space '" + args.s("id") + "'") }
      if let n = args["name"].string { spaces[i].name = n }
      if let ic = args["icon"].string { spaces[i].icon = ic }
      if let p = args["profile"].string { spaces[i].profile = p }
      var themed = false
      if case let .object(pairs) = args["theme"] {
        for (k, v) in pairs { spaces[i].theme.put(k, v) }
        themed = true
      }
      commit(themes: themed)
      return .okay
    case "delete":
      guard let i = index(of: args.s("id")) else { return .err("spaces: no space '" + args.s("id") + "'") }
      guard spaces.count > 1 else { return .err("spaces: cannot delete the last space") }
      delete(i)
      return .okay
    case "move":
      guard let i = index(of: args.s("id")) else { return .err("spaces: no space '" + args.s("id") + "'") }
      let to = max(0, min(Int(args.i("index")), spaces.count - 1))
      guard to != i else { return .okay }
      let s = spaces.remove(at: i)
      spaces.insert(s, at: to)
      commit(themes: true, showCurrent: true)
      return .okay
    case "duplicate":
      // A new space right after the original, with its icon, theme and profile ("Work Copy").
      guard let i = index(of: args.s("id")) else { return .err("spaces: no space '" + args.s("id") + "'") }
      let src = spaces[i]
      let id = newId()
      spaces.insert(Space(id: id, name: src.name + " Copy", icon: src.icon, theme: src.theme, profile: src.profile), at: i + 1)
      commit(themes: true, showCurrent: true)
      return ["id": .string(id)]
    default:
      return .err("spaces: unknown method " + method)
    }
  }

  // MARK: Mutations

  func create(name: String?, icon: String?, theme: Value, profile: String?) -> String {
    let id = newId()
    let palette = Self.palettes[(spaces.count) % Self.palettes.count]
    var t = Self.theme(palette)
    if case let .object(pairs) = theme { for (k, v) in pairs { t.put(k, v) } }
    spaces.append(Space(id: id, name: name ?? ("Space " + String(spaces.count + 1)), icon: icon ?? "", theme: t, profile: profile ?? "default"))
    commit(themes: true)
    return id
  }

  func delete(_ i: Int) {
    let wasCurrent = spaces[i].id == current
    spaces.remove(at: i)
    if wasCurrent {
      let prev = current
      current = spaces[max(0, i - 1)].id
      env.call("ui", "setPages", ["count": .int(Int64(spaces.count)), "current": .int(Int64(currentIndex))])
      commit(themes: true)
      env.emit("spaces.current", ["id": .string(current), "previous": .string(prev), "direction": "jump"])
    } else {
      commit(themes: true, showCurrent: true)
    }
  }

  func commit(themes: Bool, showCurrent: Bool = false) {
    save()
    renderAll(themes: themes)
    if showCurrent { env.call("ui", "showPage", ["page": .int(Int64(currentIndex)), "animated": false]) }
    bindKeys()
    emitChanged()
  }

  func emitChanged() { env.emit("spaces.changed", ["spaces": .array(spaces.map { $0.value })]) }

  func step(_ delta: Int) {
    let i = currentIndex + delta
    guard i >= 0, i < spaces.count else { return }
    switchTo(i, direction: delta > 0 ? "next" : "prev", animated: true)
  }

  func switchTo(_ i: Int, direction: String, animated: Bool) {
    guard i >= 0, i < spaces.count else { return }
    env.call("ui", "showPage", ["page": .int(Int64(i)), "animated": .bool(animated)])
    didChange(to: i, direction: direction)
  }

  /// The pager is already on page `i` (after a swipe or showPage): record and announce it.
  func didChange(to i: Int, direction: String) {
    let prev = current
    guard spaces[i].id != prev else { return }
    current = spaces[i].id
    env.call("storage", "set", ["ns": .string(Self.ns), "key": "current", "value": .string(current)])
    renderFooter()
    env.emit("spaces.current", ["id": .string(current), "previous": .string(prev), "direction": .string(direction)])
  }

  // MARK: UI

  func renderAll(themes: Bool) {
    if placedPager {
      env.call("ui", "setPages", ["count": .int(Int64(spaces.count))])
    } else {
      env.call("ui", "setPages", ["count": .int(Int64(spaces.count)), "current": .int(Int64(currentIndex))])
      placedPager = true
    }
    for (i, s) in spaces.enumerated() {
      if themes {
        var t = s.theme
        t.put("page", .int(Int64(i)))
        env.call("window", "setTheme", t)
      }
      renderHeader(i)
    }
    renderFooter()
  }

  /// Profiles offered in a space's Profile submenu: "default", then every other profile a space
  /// uses, in first-use order.
  var profiles: [String] {
    var out = ["default"]
    for s in spaces where !out.contains(s.profile) { out.append(s.profile) }
    return out
  }

  static func profileTitle(_ p: String) -> String { p == "default" ? "Default" : p }

  /// The space context menu, the same from the space title and its footer icon (Arc's
  /// SpaceMenu: Rename, Change Space Icon, Edit Theme Color, Profile, … Delete; den's wording).
  func menu(_ i: Int) -> [Value] {
    let s = spaces[i]
    var profileItems: [Value] = profiles.map {
      ["id": .string("profile:" + $0), "title": .string(Self.profileTitle($0)), "checked": .bool($0 == s.profile)]
    }
    profileItems.append(["separator": true])
    profileItems.append(["id": "profile.new", "title": "New Profile", "icon": "sf:plus"])
    return [
      ["id": "rename", "title": "Rename Space", "icon": "sf:pencil"],
      ["id": "icon", "title": "Change Space Icon…", "icon": "sf:face.smiling"],
      ["id": "theme", "title": "Edit Theme Color…", "icon": "sf:paintpalette"],
      ["id": "profile", "title": "Profile", "icon": "sf:person.crop.circle", "items": .array(profileItems)],
      ["separator": true],
      ["id": "duplicate", "title": "Duplicate Space", "icon": "sf:plus.square.on.square"],
      ["id": "moveLeft", "title": "Move Left", "icon": "sf:arrow.left", "enabled": .bool(i > 0)],
      ["id": "moveRight", "title": "Move Right", "icon": "sf:arrow.right", "enabled": .bool(i < spaces.count - 1)],
      ["separator": true],
      ["id": "new", "title": "New Space", "icon": "sf:plus"],
      ["separator": true],
      ["id": "delete", "title": "Delete Space…", "icon": "sf:trash", "destructive": true, "enabled": .bool(spaces.count > 1)],
    ]
  }

  func renderHeader(_ i: Int) {
    let s = spaces[i]
    var tree: Value = ["type": "spaceTitle", "id": .string("spaces.title:" + s.id), "title": .string(s.name), "icon": .string(s.icon), "menu": .array(menu(i))]
    if editing == s.id { tree.put("editing", true) }
    env.call("ui", "set", ["slot": "sidebar.spaceHeader", "page": .int(Int64(i)), "tree": tree])
  }

  func downloadsChanged(_ v: Value) {
    let p = v["progress"].double ?? -1
    let percent: Int64 = p < 0 ? -1 : Int64(p * 50) * 2  // 2% steps: at most 50 redraws per download
    let next = (v.i("active"), v.i("unseen"), percent)
    guard next != (dlActive, dlUnseen, dlPercent) else { return }
    (dlActive, dlUnseen, dlPercent) = next
    renderFooter()
  }

  /// A download arrow next to the Library button while something downloads (a progress ring) or
  /// finished since you last looked (a dot). Opens Library ▸ Downloads.
  var downloadsButton: Value? {
    guard dlActive > 0 || dlUnseen > 0 else { return nil }
    var b: Value = ["type": "button", "id": "spaces.downloads", "icon": "sf:arrow.down", "tooltip": "Downloads (⌥⌘L)", "size": 32]
    if dlActive > 0 { b.put("progress", .double(dlPercent < 0 ? -1 : Double(dlPercent) / 100)) } else { b.put("dot", true) }
    return b
  }

  func renderFooter() {
    var row: [Value] = [
      ["type": "button", "id": "spaces.library", "icon": "sf:tray.full", "tooltip": "Library (⌘Y)", "size": 32],
    ]
    if let d = downloadsButton { row.append(d) }
    row.append(["type": "spacer"])
    for (i, s) in spaces.enumerated() {
      row.append(["type": "spaceIcon", "id": .string("spaces.icon:" + s.id), "icon": .string(s.icon), "title": .string(s.name), "selected": .bool(s.id == current),
                  "spaceId": .string(s.id), "reorderable": true, "menu": .array(menu(i))])
    }
    row.append(["type": "spacer"])
    row.append(["type": "button", "id": "spaces.new", "icon": "sf:plus", "tooltip": "New Space", "size": 32])
    env.call("ui", "set", ["slot": "sidebar.footer", "tree": ["type": "row", "id": "spaces.footer", "height": 50, "spacing": 2, "children": .array(row)]])
  }

  func bindKeys() {
    for n in 1...9 {
      let title = n <= spaces.count ? spaces[n - 1].name : "Space " + String(n)
      env.call("keys", "bind", ["chord": .string("ctrl+" + String(n)), "event": "spaces.key.jump", "title": .string(title), "menu": "Spaces", "payload": .int(Int64(n - 1))])
    }
    env.call("keys", "bind", ["chord": "cmd+opt+right", "event": "spaces.key.next", "title": "Next Space", "menu": "Spaces"])
    env.call("keys", "bind", ["chord": "cmd+opt+left", "event": "spaces.key.prev", "title": "Previous Space", "menu": "Spaces"])
  }

  // MARK: Space menu

  static let iconPickerId = "spaces.iconPicker"
  /// The space whose title is being renamed in place.
  var editing: String?
  /// The space whose icon picker is open.
  var iconEditing: String?

  func menuPicked(_ sid: String, _ item: String, from: String) {
    guard let i = index(of: sid) else { return }
    switch item {
    case "rename":
      if sid != current { switchTo(i, direction: "jump", animated: true) }
      beginRename(sid)
    case "icon": openIconPicker(sid, anchor: (from == "icon" ? "spaces.icon:" : "spaces.title:") + sid)
    case "theme":
      if sid != current { switchTo(i, direction: "jump", animated: true) }
      env.emit("spaces.editTheme", ["id": .string(sid)])
    case "duplicate":
      let r = handle("duplicate", ["id": .string(sid)])
      if let nid = r["id"].string, let j = index(of: nid) { switchTo(j, direction: "jump", animated: true) }
    case "moveLeft", "moveRight":
      _ = handle("move", ["id": .string(sid), "index": .int(Int64(i + (item == "moveLeft" ? -1 : 1)))])
    case "new": newSpace()
    case "delete": confirmDelete(sid)
    case "profile.new":
      // A new profile named after the space ("Work", or "Work 2" if taken): its own cookies and site data.
      var name = spaces[i].name, n = 2
      while profiles.contains(where: { Text.lower($0) == Text.lower(name) }) || Text.lower(name) == "default" {
        name = spaces[i].name + " " + String(n)
        n += 1
      }
      setProfile(sid, name)
    default:
      if Text.hasPrefix(item, "profile:") { setProfile(sid, Text.dropPrefix(item, "profile:")) }
    }
  }

  func setProfile(_ sid: String, _ p: String) {
    guard let i = index(of: sid), spaces[i].profile != p else { return }
    _ = handle("update", ["id": .string(sid), "profile": .string(p)])
    env.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": .string(spaces[i].name + " now uses the " + Self.profileTitle(p) + " profile"), "icon": "sf:person.crop.circle"]])
  }

  func newSpace() {
    let nid = create(name: nil, icon: nil, theme: .null, profile: nil)
    if let i = index(of: nid) { switchTo(i, direction: "jump", animated: true) }
    env.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": "New Space Created", "icon": "sf:checkmark.circle.fill"]])
  }

  func beginRename(_ sid: String) {
    guard let i = index(of: sid) else { return }
    editing = sid
    renderHeader(i)
  }

  func openIconPicker(_ sid: String, anchor: String) {
    guard let i = index(of: sid) else { return }
    iconEditing = sid
    env.call("ui", "set", ["slot": "popover", "tree": [
      "type": "iconPicker", "id": .string(Self.iconPickerId), "anchor": .string(anchor),
      "title": .string(spaces[i].name + " Icon"), "selected": .string(spaces[i].icon),
    ]])
  }

  func closeIconPicker() {
    guard iconEditing != nil else { return }
    iconEditing = nil
    env.call("ui", "set", ["slot": "popover", "tree": nil])
  }

  func trimmed(_ s: String) -> String {
    var b = Array(s.utf8)
    while let f = b.first, f == 32 || f == 9 || f == 10 || f == 13 { b.removeFirst() }
    while let l = b.last, l == 32 || l == 9 || l == 10 || l == 13 { b.removeLast() }
    return String(decoding: b, as: UTF8.self)
  }

  func confirmDelete(_ id: String) {
    guard let i = index(of: id) else { return }
    env.call("ui", "set", ["slot": "dialog", "tree": [
      "type": "dialog", "id": .string("spaces.delete:" + id), "icon": "sf:trash",
      "title": .string("Delete your " + spaces[i].name + " Space?"),
      "message": "This will archive all the tabs and folders inside it.",
      "buttons": [["id": "cancel", "title": "Cancel", "style": "cancel"], ["id": "delete", "title": "Delete", "style": "destructive"]],
    ]])
  }

  func action(_ id: String, _ action: String, _ value: Value) {
    if id == "sidebar", action == "page" {
      let p = Int(value.int ?? 0)
      guard p >= 0, p < spaces.count else { return }
      let from = currentIndex
      didChange(to: p, direction: p > from ? "next" : "prev")
      return
    }
    if Text.hasPrefix(id, "spaces.icon:") {
      let sid = Text.dropPrefix(id, "spaces.icon:")
      switch action {
      case "click": if let i = index(of: sid) { switchTo(i, direction: "jump", animated: true) }
      case "move": _ = handle("move", ["id": .string(sid), "index": .int(value.i("index"))])  // footer drag-reorder
      case "menu": menuPicked(sid, value.string ?? "", from: "icon")
      default: break
      }
    } else if id == "spaces.new", action == "click" {
      newSpace()
    } else if id == "spaces.library", action == "click" {
      env.emit("spaces.library", .null)
    } else if id == "spaces.downloads", action == "click" {
      env.call("downloads", "open")
    } else if id == Self.iconPickerId {
      if action == "pick", let sid = iconEditing {
        _ = handle("update", ["id": .string(sid), "icon": .string(value.s("icon"))])
        closeIconPicker()
      } else if action == "dismiss" {
        closeIconPicker()
      }
    } else if Text.hasPrefix(id, "spaces.title:") {
      let sid = Text.dropPrefix(id, "spaces.title:")
      switch action {
      case "menu": menuPicked(sid, value.string ?? "", from: "title")
      case "more": env.emit("spaces.editTheme", ["id": .string(sid)])
      case "doubleClick": beginRename(sid)
      case "rename":
        editing = nil
        let t = trimmed(value.s("title"))
        if !t.isEmpty, let i = index(of: sid), spaces[i].name != t { _ = handle("update", ["id": .string(sid), "name": .string(t)]) } else if let i = index(of: sid) { renderHeader(i) }
      case "renameCancel":
        editing = nil
        if let i = index(of: sid) { renderHeader(i) }
      default: break
      }
    } else if Text.hasPrefix(id, "spaces.delete:"), action == "button" {
      env.call("ui", "set", ["slot": "dialog", "tree": nil])
      if value.s("button") == "delete" { _ = handle("delete", ["id": .string(Text.dropPrefix(id, "spaces.delete:"))]) }
    }
  }
}
