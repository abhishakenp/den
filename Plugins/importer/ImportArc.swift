// Arc's sidebar: ~/Library/Application Support/Arc/StorableSidebar.json.
//
// The file holds a list of containers; the one with `spaces` and `items` is the sidebar. Both
// lists alternate an id string and the object it names. A space names its containers in
// `newContainerIDs` (older files: `containerIDs`), again alternating a label ({"pinned": {}} or
// "pinned", {"unpinned": …} or "unpinned") and the id of a container item whose `childrenIds` are
// the section's top-level items. An item's `data` says what it is: {"tab": {savedURL, savedTitle}},
// {"list": {}} (a folder), {"splitView": …} (its tabs), {"itemContainer": …} (a section root).
// Favorites (Arc's "top apps") are per profile: `topAppsContainerIDs` alternates a profile label
// and a container id. A space's look lives in `customInfo`: `iconType` (emoji_v2 / emoji) and
// `windowTheme`, whose colors are {red, green, blue, alpha} objects (0–1). Arc never documented this
// format; the parser only relies on those names and skips anything it doesn't recognise.

#if !hasFeature(Embedded)
  import CordisValue
#endif

enum ImportArc {
  /// Spaces (pinned and Today tabs, nested folders, icon, colors, profile) and favorites.
  static func parse(_ root: Value, into r: inout ImportResult) {
    guard let sidebar = findSidebar(root, depth: 0) else {
      r.problems.append("arc: no sidebar container")
      return
    }
    var items: [String: Value] = [:]
    for v in sidebar.a("items") {
      if case .object = v, let id = v["id"].string { items[id] = v }
    }
    var profileNames: [String: String] = [:]  // Arc profile folder -> den profile name
    var n = 0
    for sp in sidebar.a("spaces") {
      guard case .object = sp, let id = sp["id"].string else { continue }
      n += 1
      var title = sp.s("title")
      if title.isEmpty { title = "Space " + String(n) }
      var space = ImportSpace(key: "arc:space:" + id, name: title)
      let info = sp["customInfo"]
      space.icon = icon(info["iconType"])
      let theme = info["windowTheme"]
      var colors: [String] = []
      collectColors(theme["background"], &colors, depth: 0)
      if colors.isEmpty { collectColors(theme, &colors, depth: 0) }
      space.colors = colors
      space.grain = number(theme, containing: "noise", depth: 0).map { max(0, min(1, $0)) }
      if let folder = profileFolder(sp["profile"]) {
        if profileNames[folder] == nil { profileNames[folder] = title }
        space.profile = profileNames[folder]
      }
      let (pinned, unpinned) = sections(sp["newContainerIDs"].isNull ? sp["containerIDs"] : sp["newContainerIDs"])
      if let p = pinned { space.pinned = ImportNode.clean(nodes(items[p]?.a("childrenIds") ?? [], items, depth: 0)) }
      if let u = unpinned { space.today = ImportNode.clean(nodes(items[u]?.a("childrenIds") ?? [], items, depth: 0)) }
      r.spaces.append(space)
    }
    // Favorites: every profile's top apps, the default profile's first.
    var labels: [(Bool, String)] = []
    let top = sidebar.a("topAppsContainerIDs")
    var j = 0
    while j + 1 < top.count {
      if let cid = top[j + 1].string { labels.append((!top[j]["default"].isNull || top[j].string == "default", cid)) }
      j += 2
    }
    labels.sort { $0.0 && !$1.0 }
    var seen: [String] = []
    for (_, cid) in labels {
      for node in nodes(items[cid]?.a("childrenIds") ?? [], items, depth: 0) {
        for t in flatten(node) where URLs.isWeb(t.url) && !seen.contains(URLs.normalize(t.url)) {
          seen.append(URLs.normalize(t.url))
          r.favorites.append(t)
        }
      }
    }
    r.readSomething = true
  }

  /// The container holding `spaces` and `items` (sidebar.containers[n] in today's files).
  static func findSidebar(_ v: Value, depth: Int) -> Value? {
    guard depth < 8 else { return nil }
    switch v {
    case let .object(pairs):
      if v["spaces"].array != nil && v["items"].array != nil { return v }
      for (_, x) in pairs { if let f = findSidebar(x, depth: depth + 1) { return f } }
    case let .array(list):
      for x in list { if let f = findSidebar(x, depth: depth + 1) { return f } }
    default: break
    }
    return nil
  }

  /// (pinned container id, unpinned container id) from a space's container list.
  static func sections(_ list: Value) -> (String?, String?) {
    let a = list.array ?? []
    var pinned: String?, unpinned: String?
    var j = 0
    while j + 1 < a.count {
      let label = a[j]
      if let id = a[j + 1].string {
        if label.string == "pinned" || !label["pinned"].isNull { pinned = id }
        if label.string == "unpinned" || !label["unpinned"].isNull { unpinned = id }
      }
      j += 2
    }
    return (pinned, unpinned)
  }

  static func nodes(_ ids: [Value], _ items: [String: Value], depth: Int) -> [ImportNode] {
    guard depth < 32 else { return [] }
    var out: [ImportNode] = []
    for idv in ids {
      guard let id = idv.string, let item = items[id] else { continue }
      let data = item["data"]
      let custom = item.s("title")
      if !data["tab"].isNull {
        let tab = data["tab"]
        let url = tab.s("savedURL")
        out.append(.tab("arc:" + id, custom.isEmpty ? tab.s("savedTitle") : custom, url))
      } else if !data["list"].isNull {
        out.append(.folder("arc:" + id, custom.isEmpty ? "Folder" : custom, nodes(item.a("childrenIds"), items, depth: depth + 1)))
      } else if !data["splitView"].isNull {
        // den's splits are made of open tabs; an imported split becomes its tabs, in order.
        out += nodes(item.a("childrenIds"), items, depth: depth + 1)
      }
    }
    return out
  }

  static func flatten(_ n: ImportNode) -> [ImportNode] {
    n.folder ? n.children.flatMap { flatten($0) } : [n]
  }

  /// emoji_v2 ("🚀"), else emoji (a code point). Arc's own symbol names aren't SF Symbols: skipped.
  static func icon(_ t: Value) -> String {
    if let e = t["emoji_v2"].string, !e.isEmpty { return e }
    if let c = t["emoji"].int { return UTF16Text.scalar(c) }
    if let e = t["emoji"].string { return e }
    return ""
  }

  /// "Profile 1" for {"custom": {"_0": {"directoryBasename": "Profile 1"}}}; nil for the default.
  static func profileFolder(_ p: Value) -> String? {
    let c = p["custom"]
    guard !c.isNull else { return nil }
    let name = c["_0"].s("directoryBasename")
    return name.isEmpty ? (c.s("directoryBasename").isEmpty ? nil : c.s("directoryBasename")) : name
  }

  /// Color objects ({red, green, blue}) in document order, as hex, at most 3, no repeats.
  static func collectColors(_ v: Value, _ out: inout [String], depth: Int) {
    guard out.count < 3, depth < 16 else { return }
    switch v {
    case let .object(pairs):
      if let r = v["red"].double, let g = v["green"].double, let b = v["blue"].double {
        let h = ImportFormat.hex([r, g, b])
        if !out.contains(h) { out.append(h) }
        return
      }
      for (_, x) in pairs { collectColors(x, &out, depth: depth + 1) }
    case let .array(list):
      for x in list { collectColors(x, &out, depth: depth + 1) }
    default: break
    }
  }

  /// The first number under a key containing `word` (Arc's grain: `noiseFactor`).
  static func number(_ v: Value, containing word: String, depth: Int) -> Double? {
    guard depth < 16 else { return nil }
    switch v {
    case let .object(pairs):
      for (k, x) in pairs {
        if Text.contains(k, word), let d = x.double { return d }
      }
      for (_, x) in pairs { if let d = number(x, containing: word, depth: depth + 1) { return d } }
    case let .array(list):
      for x in list { if let d = number(x, containing: word, depth: depth + 1) { return d } }
    default: break
    }
    return nil
  }
}
