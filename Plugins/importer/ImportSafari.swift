// Safari: ~/Library/Safari, readable only with Full Disk Access (macOS privacy protection).
// - `Bookmarks.plist` (binary plist): a tree of {WebBookmarkType: List|Leaf|Proxy, Title, Children,
//   URLString, URIDictionary.title, WebBookmarkUUID}; the root's lists are BookmarksBar,
//   BookmarksMenu and com.apple.ReadingList (proxies are History and such: skipped).
// - `History.db` (SQLite): history_items (url, visit_count) and history_visits (visit_time in
//   seconds since 2001-01-01, title).

#if !hasFeature(Embedded)
  import CordisValue
#endif

enum ImportSafari {
  static let historySQL = """
    SELECT i.url, (SELECT v.title FROM history_visits v WHERE v.history_item = i.id AND v.title IS NOT NULL AND v.title != '' ORDER BY v.visit_time DESC LIMIT 1), i.visit_count, (SELECT MAX(v.visit_time) FROM history_visits v WHERE v.history_item = i.id) AS last FROM history_items i WHERE last IS NOT NULL AND (i.url LIKE 'http://%' OR i.url LIKE 'https://%') ORDER BY last DESC LIMIT 20000
    """
  /// Seconds between 1970-01-01 and 2001-01-01 (Core Data's reference date).
  static let referenceDelta: Double = 978_307_200

  static func bookmarks(_ root: Value) -> [ImportNode] {
    var out: [ImportNode] = []
    for list in root.a("Children") where list.s("WebBookmarkType") == "WebBookmarkTypeList" {
      let kids = nodes(list.a("Children"), depth: 0)
      let id = "safari:" + (list.sOpt("WebBookmarkUUID") ?? list.s("Title"))
      switch list.s("Title") {
      case "BookmarksBar": out = kids + out
      case "BookmarksMenu": if !kids.isEmpty { out.append(.folder(id, "Bookmarks Menu", kids)) }
      case "com.apple.ReadingList": if !kids.isEmpty { out.append(.folder(id, "Reading List", kids)) }
      default: if !kids.isEmpty { out.append(.folder(id, list.s("Title"), kids)) }
      }
    }
    return ImportNode.clean(out)
  }

  static func nodes(_ list: [Value], depth: Int) -> [ImportNode] {
    guard depth < 32 else { return [] }
    var out: [ImportNode] = []
    for n in list {
      let id = "safari:" + (n.sOpt("WebBookmarkUUID") ?? (n.s("Title") + n.s("URLString")))
      switch n.s("WebBookmarkType") {
      case "WebBookmarkTypeList": out.append(.folder(id, n.s("Title"), nodes(n.a("Children"), depth: depth + 1)))
      case "WebBookmarkTypeLeaf": out.append(.tab(id, n["URIDictionary"].s("title"), n.s("URLString")))
      default: break
      }
    }
    return out
  }

  /// Rows of `historySQL` (url, title, visit_count, last visit in seconds since 2001).
  static func history(_ rows: [Value]) -> [ImportVisit] {
    var out: [ImportVisit] = []
    for row in rows {
      guard let r = row.array, r.count >= 4, let url = r[0].string, URLs.isWeb(url) else { continue }
      let t = r[3].double ?? 0
      out.append(ImportVisit(url: url, title: r[1].string ?? "", visits: max(1, r[2].int ?? 1), last: Int64((t + referenceDelta) * 1000)))
    }
    return out
  }
}
