// Safari Session.sqlite: open tabs at the time of the last close or crash.
//
// Tables (macOS 15+):
// - windows: id, uuid, name, last_close_date
// - tabs: id, window_id, uuid, title, url, user_generated_title, last_visited_date
// - tab_items: tab_id, url, title, user_generated_title, last_visited_date
//
// url and title in `tabs` may be empty; `tab_items` holds the actual URL/title.
// last_visited_date is seconds since 2001-01-01 (same epoch as History.db).

#if !hasFeature(Embedded)
  import CordisValue
#endif

enum ImportSafariSession {
  /// Rows from the SQL query: (url, title, window_uuid).
  static func tabs(_ rows: [Value]) -> [ImportNode] {
    var out: [ImportNode] = []
    var seen: [String] = []
    for row in rows {
      guard let r = row.array, r.count >= 3, let url = r[0].string, url.isEmpty == false else { continue }
      guard URLs.isWeb(url) else { continue }
      let title = r[1].string ?? URLs.title(url)
      guard !seen.contains(URLs.normalize(url)) else { continue }
      seen.append(URLs.normalize(url))
      out.append(.tab("safari:tab:" + URLs.normalize(url), title, url))
    }
    return out
  }

  /// One SQL string: joins tabs with tab_items to get the best URL and title.
  static let sql = """
    SELECT ti.url, COALESCE(ti.user_generated_title, ti.title, t.user_generated_title, t.title, ''), w.uuid \
    FROM tabs t \
    LEFT JOIN tab_items ti ON ti.tab_id = t.id \
    LEFT JOIN windows w ON w.id = t.window_id \
    WHERE (ti.url IS NOT NULL AND ti.url != '') OR (t.url IS NOT NULL AND t.url != '') \
    AND (ti.url LIKE 'http://%' OR ti.url LIKE 'https://%') \
    ORDER BY COALESCE(ti.last_visited_date, t.last_visited_date, 0) DESC \
    LIMIT 5000
    """
}