// Firefox and Zen (a Firefox fork): <root>/Profiles/<name>/places.sqlite, the profile in use being
// the one whose places.sqlite changed last.
// - moz_bookmarks (type 1 bookmark, 2 folder, 3 separator; parent, position, title, fk -> moz_places,
//   guid; roots by guid: toolbar_____, menu________, unfiled_____, mobile______)
// - moz_places (url, title, visit_count, hidden, last_visit_date in µs since 1970)
// - Zen ≤ 1.11 also keeps its workspaces and pinned tabs there: zen_workspaces (uuid, name, icon,
//   position, theme_colors: JSON like [{"c":[r,g,b],…}]) and zen_pins (uuid, title, url,
//   workspace_uuid, is_essential, is_group, parent_uuid, position). Later Zen versions moved them to
//   a compressed session file this importer doesn't read (their bookmarks and history still come).

#if !hasFeature(Embedded)
  import CordisValue
#endif

enum ImportFirefox {
  static let bookmarksSQL =
    "SELECT b.id, b.type, b.parent, b.position, b.title, p.url, b.guid FROM moz_bookmarks b LEFT JOIN moz_places p ON p.id = b.fk ORDER BY b.parent, b.position"
  static let historySQL =
    "SELECT url, title, visit_count, last_visit_date FROM moz_places WHERE hidden = 0 AND visit_count > 0 AND last_visit_date IS NOT NULL AND (url LIKE 'http://%' OR url LIKE 'https://%') ORDER BY last_visit_date DESC LIMIT 20000"
  static let zenTablesSQL = "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('zen_workspaces', 'zen_pins')"
  static let zenWorkspacesSQL = "SELECT * FROM zen_workspaces ORDER BY position"
  static let zenPinsSQL = "SELECT * FROM zen_pins ORDER BY position"

  /// The profile folder whose places.sqlite changed last, from `files.stat` of each candidate.
  static func currentProfile(_ stats: [Value]) -> String? {
    var best: (Int64, String)?
    for s in stats where s.b("exists") {
      let path = s.s("path")
      if best == nil || s.i("modified") > best!.0 { best = (s.i("modified"), path) }
    }
    return best?.1
  }

  struct Row {
    let id: Int64
    let type: Int64
    let parent: Int64
    let title: String
    let url: String
    let guid: String
  }

  static func bookmarks(_ rows: [Value], keyPrefix: String) -> [ImportNode] {
    var byParent: [Int64: [Row]] = [:]
    var roots: [String: Int64] = [:]
    for v in rows {
      guard let r = v.array, r.count >= 7, let id = r[0].int else { continue }
      let row = Row(id: id, type: r[1].int ?? 0, parent: r[2].int ?? 0, title: r[4].string ?? "", url: r[5].string ?? "", guid: r[6].string ?? "")
      byParent[row.parent, default: []].append(row)
      roots[row.guid] = row.id
    }
    func nodes(_ parent: Int64, _ depth: Int) -> [ImportNode] {
      guard depth < 32 else { return [] }
      var out: [ImportNode] = []
      for r in byParent[parent] ?? [] {
        let key = keyPrefix + (r.guid.isEmpty ? String(r.id) : r.guid)
        if r.type == 2 {
          out.append(.folder(key, r.title, nodes(r.id, depth + 1)))
        } else if r.type == 1 {
          out.append(.tab(key, r.title, r.url))
        }
      }
      return out
    }
    var out: [ImportNode] = []
    if let t = roots["toolbar_____"] { out += nodes(t, 0) }
    for (guid, title) in [("menu________", "Bookmarks Menu"), ("unfiled_____", "Other Bookmarks"), ("mobile______", "Mobile Bookmarks")] {
      guard let id = roots[guid] else { continue }
      let kids = nodes(id, 0)
      if !kids.isEmpty { out.append(.folder(keyPrefix + guid, title, kids)) }
    }
    return ImportNode.clean(out)
  }

  /// Rows of `historySQL` (url, title, visit_count, last_visit_date µs).
  static func history(_ rows: [Value]) -> [ImportVisit] {
    var out: [ImportVisit] = []
    for row in rows {
      guard let r = row.array, r.count >= 4, let url = r[0].string, URLs.isWeb(url) else { continue }
      let t = r[3].int ?? Int64(r[3].double ?? 0)
      out.append(ImportVisit(url: url, title: r[1].string ?? "", visits: max(1, r[2].int ?? 1), last: t / 1000))
    }
    return out
  }

  // MARK: Zen workspaces

  /// `files.sqlite` result rows as objects by column name.
  static func objects(_ result: Value) -> [Value] {
    let cols = result.a("columns").compactMap { $0.string }
    var out: [Value] = []
    for row in result.a("rows") {
      guard let r = row.array else { continue }
      var o: Value = .object([])
      for (j, c) in cols.enumerated() where j < r.count { o.put(c, r[j]) }
      out.append(o)
    }
    return out
  }

  /// Workspaces become spaces with their pinned tabs (folders from `is_group`/`parent_uuid`);
  /// essentials become favorites.
  static func zen(workspaces: [Value], pins: [Value], into r: inout ImportResult) {
    var spaces: [ImportSpace] = []
    for w in workspaces {
      let uuid = w.s("uuid")
      guard !uuid.isEmpty else { continue }
      var s = ImportSpace(key: "zen:space:" + uuid, name: w.s("name").isEmpty ? "Workspace" : w.s("name"))
      let icon = w.s("icon")
      // Zen icons are emoji or chrome:// image URLs; only an emoji carries over.
      if !icon.isEmpty, !Text.contains(icon, "://"), icon.utf8.count <= 16 { s.icon = icon }
      s.colors = themeColors(w.s("theme_colors"))
      spaces.append(s)
    }
    var children: [String: [Value]] = [:]
    for p in pins { children[p.s("parent_uuid"), default: []].append(p) }
    func node(_ p: Value, _ depth: Int) -> ImportNode? {
      let key = "zen:" + p.s("uuid")
      if p.i("is_group") != 0 || p.b("is_group") {
        guard depth < 16 else { return nil }
        return .folder(key, p.s("title").isEmpty ? "Folder" : p.s("title"), (children[p.s("uuid")] ?? []).compactMap { node($0, depth + 1) })
      }
      return .tab(key, p.s("title"), p.s("url"))
    }
    for p in children[""] ?? [] {
      guard let n = node(p, 0) else { continue }
      if p.i("is_essential") != 0 || p.b("is_essential") {
        r.favorites += ImportArc.flatten(n)
      } else if let j = spaces.firstIndex(where: { $0.key == "zen:space:" + p.s("workspace_uuid") }) {
        spaces[j].pinned.append(n)
      }
    }
    for j in spaces.indices { spaces[j].pinned = ImportNode.clean(spaces[j].pinned) }
    r.favorites = ImportNode.clean(r.favorites)
    r.spaces += spaces
  }

  /// The `c` triples of Zen's theme JSON ([{"c":[255,128,0],…},…]) as hex, at most 3.
  static func themeColors(_ json: String) -> [String] {
    let b = Array(json.utf8)
    var out: [String] = []
    var i = 0
    let key = Array("\"c\"".utf8)
    while i + key.count < b.count, out.count < 3 {
      guard Array(b[i..<(i + key.count)]) == key else { i += 1; continue }
      i += key.count
      while i < b.count, b[i] != 91 { i += 1 }  // [
      var nums: [Double] = []
      var cur: [UInt8] = []
      i += 1
      while i < b.count, b[i] != 93 {  // ]
        if (b[i] >= 48 && b[i] <= 57) || b[i] == 46 { cur.append(b[i]) } else if !cur.isEmpty {
          nums.append(number(cur))
          cur = []
        }
        i += 1
      }
      if !cur.isEmpty { nums.append(number(cur)) }
      if nums.count >= 3 {
        let h = ImportFormat.hex(nums)  // 0–255 here (hex() scales 0–1 values itself)
        if !out.contains(h) { out.append(h) }
      }
    }
    return out
  }

  static func number(_ digits: [UInt8]) -> Double {
    var v = 0.0, frac = 0.0, scale = 1.0
    var seenDot = false
    for d in digits {
      if d == 46 { seenDot = true; continue }
      if seenDot { scale /= 10; frac += Double(d - 48) * scale } else { v = v * 10 + Double(d - 48) }
    }
    return v + frac
  }
}
