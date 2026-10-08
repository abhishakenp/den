// Firefox/Zen session data: read open tabs from `sessions.sqlite` in the Firefox profile directory.
//
// Tables (Firefox 115+):
// - windows: id, internalId, name, type, lastModified
// - tabs: id, windowId, lastAccessed, index, hidden, title, url
// - forms: (autocomplete data, not needed)
//
// lastAccessed is in µs since 1970-01-01. `hidden` tabs are still in the session.
//
// For Zen ≤ 1.11, open tabs are also here. Zen ≥ 1.12 moved to a compressed session file
// we don't parse, but bookmarks and history still come from places.sqlite.

#if !hasFeature(Embedded)
  import CordisValue
#endif

enum ImportFirefoxSession {
  /// Rows from the SQL: (url, title, window_id).
  static func tabs(_ rows: [Value]) -> [ImportNode] {
    var out: [ImportNode] = []
    var seen: [String] = []
    for row in rows {
      guard let r = row.array, r.count >= 3, let url = r[0].string, url.isEmpty == false else { continue }
      guard URLs.isWeb(url) else { continue }
      let title = r[1].string ?? URLs.title(url)
      guard !seen.contains(URLs.normalize(url)) else { continue }
      seen.append(URLs.normalize(url))
      out.append(.tab("firefox:tab:" + URLs.normalize(url), title, url))
    }
    return out
  }

  /// One SQL string: join windows with tabs, only include tabs with a non-empty URL.
  static let sql = """
    SELECT t.url, COALESCE(t.title, ''), t.windowId \
    FROM tabs t \
    JOIN windows w ON w.id = t.windowId \
    WHERE t.url IS NOT NULL AND t.url != '' \
    AND (t.url LIKE 'http://%' OR t.url LIKE 'https://%') \
    ORDER BY t.lastAccessed DESC \
    LIMIT 5000
    """
}