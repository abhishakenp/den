// Dev fixture: compiled only with the `Scenarios` package trait (on by default; release bundles leave it out).
#if Scenarios
import Foundation
import SQLite3

/// A fake home folder with other browsers' data, for the importer's tests and `--scenario import*`.
/// Never the user's real data: everything here is synthetic.
///
/// - Checked in (Tests/Fixtures/import): Arc's `StorableSidebar.json`, Chrome's `Bookmarks`, Safari's
///   `Bookmarks.plist` (written out as a binary plist, as Safari keeps it).
/// - Built here: Chromium `History` databases (Arc, Chrome), a Chrome `Sessions/Session_*` file
///   (SNSS), Safari's `History.db`, Firefox's and Zen's `places.sqlite` (Zen with its workspace and
///   pin tables), with the real tables and columns the importer reads.
public enum ImportFixtures {
  /// Tests/Fixtures/import in the checkout this was built from.
  public static let source: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Tests/Fixtures/import", isDirectory: true)

  /// Seconds between 1601-01-01 and 1970-01-01 (Chromium times are µs since 1601).
  static let chromiumEpoch: Int64 = 11_644_473_600

  public struct Counts {
    public var chromeHistory = 0
    public var arcHistory = 0
    public var safariHistory = 0
    public var firefoxHistory = 0
  }

  /// Builds the fake home in `dir` (a new temporary folder by default) and returns it.
  /// `chromeHistory`: rows in Chrome's History (big-history tests use tens of thousands).
  @discardableResult
  public static func makeHome(_ dir: URL? = nil, chromeHistory: Int = 1200, now: Date = Date()) throws -> URL {
    let home = dir ?? FileManager.default.temporaryDirectory.appendingPathComponent("den-import-home-\(UUID().uuidString)", isDirectory: true)
    let fm = FileManager.default
    let lib = home.appendingPathComponent("Library", isDirectory: true)
    let support = lib.appendingPathComponent("Application Support", isDirectory: true)
    func mkdir(_ u: URL) throws { try fm.createDirectory(at: u, withIntermediateDirectories: true) }

    // Arc: the sidebar and its Chromium profiles' history.
    let arc = support.appendingPathComponent("Arc", isDirectory: true)
    try mkdir(arc.appendingPathComponent("User Data/Default"))
    try mkdir(arc.appendingPathComponent("User Data/Profile 1"))
    try mkdir(arc.appendingPathComponent("User Data/System Profile"))
    try copy("Arc/StorableSidebar.json", to: arc.appendingPathComponent("StorableSidebar.json"))
    try chromiumHistory(arc.appendingPathComponent("User Data/Default/History"), rows: 300, seed: 7, now: now)
    try chromiumHistory(arc.appendingPathComponent("User Data/Profile 1/History"), rows: 20, seed: 11, now: now)

    // Chrome: bookmarks, history and the open tabs of the last session.
    let chrome = support.appendingPathComponent("Google/Chrome", isDirectory: true)
    try mkdir(chrome.appendingPathComponent("Default/Sessions"))
    try Data("{\"profile\":{\"info_cache\":{\"Default\":{\"name\":\"Person 1\"}}}}".utf8).write(to: chrome.appendingPathComponent("Local State"))
    try copy("Chrome/Default/Bookmarks", to: chrome.appendingPathComponent("Default/Bookmarks"))
    try chromiumHistory(chrome.appendingPathComponent("Default/History"), rows: chromeHistory, seed: 3, now: now)
    try session(old: true).write(to: chrome.appendingPathComponent("Default/Sessions/Session_13370000000000000"))
    try session(old: false).write(to: chrome.appendingPathComponent("Default/Sessions/Session_13401234599999999"))

    // Safari (binary plist, like Safari's own) and its history.
    let safari = lib.appendingPathComponent("Safari", isDirectory: true)
    try mkdir(safari)
    let xml = try Data(contentsOf: source.appendingPathComponent("Safari/Bookmarks.plist"))
    let plist = try PropertyListSerialization.propertyList(from: xml, format: nil)
    try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: safari.appendingPathComponent("Bookmarks.plist"))
    try safariHistory(safari.appendingPathComponent("History.db"), now: now)

    // Firefox: two profiles, the one in use changed last.
    let ff = support.appendingPathComponent("Firefox/Profiles", isDirectory: true)
    try mkdir(ff.appendingPathComponent("zz9plural.default"))
    try mkdir(ff.appendingPathComponent("a1b2c3d4.default-release"))
    try places(ff.appendingPathComponent("zz9plural.default/places.sqlite"), zen: false, stale: true, now: now)
    try places(ff.appendingPathComponent("a1b2c3d4.default-release/places.sqlite"), zen: false, stale: false, now: now)
    try fm.setAttributes([.modificationDate: now.addingTimeInterval(-400 * 86400)], ofItemAtPath: ff.appendingPathComponent("zz9plural.default/places.sqlite").path)

    // Zen: places.sqlite with its workspaces and pins.
    let zen = support.appendingPathComponent("zen/Profiles/q1w2e3r4.Default (release)", isDirectory: true)
    try mkdir(zen)
    try places(zen.appendingPathComponent("places.sqlite"), zen: true, stale: false, now: now)
    return home
  }

  static func copy(_ name: String, to dest: URL) throws {
    if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
    try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: dest)
  }

  // MARK: Synthetic history

  /// Real-looking sites, paths and titles; visit counts fall off like real browsing.
  static let sites: [(String, String, [String])] = [
    ("https://github.com", "GitHub", ["/abhishakenp/den/pulls", "/swiftlang/swift/issues", "/notifications", "/apple/swift-nio", "/settings/profile"]),
    ("https://news.ycombinator.com", "Hacker News", ["/", "/item?id=41000001", "/newest", "/ask", "/show"]),
    ("https://developer.apple.com", "Apple Developer", ["/documentation/webkit", "/documentation/swiftui", "/forums/", "/videos/", "/news/"]),
    ("https://www.youtube.com", "YouTube", ["/", "/watch?v=dQw4w9WgXcQ", "/feed/subscriptions", "/watch?v=jNQXAC9IVRw", "/results?search_query=swift"]),
    ("https://en.wikipedia.org", "Wikipedia", ["/wiki/WebKit", "/wiki/Swift_(programming_language)", "/wiki/Lisbon", "/wiki/SQLite", "/wiki/Main_Page"]),
    ("https://mail.google.com", "Gmail", ["/mail/u/0/#inbox", "/mail/u/0/#sent", "/mail/u/1/#inbox"]),
    ("https://docs.google.com", "Google Docs", ["/document/d/1AbCdEf/edit", "/spreadsheets/d/9XyZ/edit", "/presentation/d/5QrS/edit"]),
    ("https://www.figma.com", "Figma", ["/files/recents-and-sharing", "/design/abc/Design-System"]),
    ("https://linear.app", "Linear", ["/acme/view/my-issues", "/acme/issue/ENG-1234", "/acme/project/den-import"]),
    ("https://stackoverflow.com", "Stack Overflow", ["/questions/24002369", "/questions/tagged/swift", "/questions/1"]),
    ("https://www.reddit.com", "Reddit", ["/r/swift/", "/r/MacOS/", "/r/apple/"]),
    ("https://www.nytimes.com", "The New York Times", ["/", "/section/technology", "/section/world"]),
    ("https://webkit.org", "WebKit", ["/blog/", "/status/", "/downloads/"]),
    ("https://www.swift.org", "Swift.org", ["/documentation/", "/blog/", "/install/macos/"]),
    ("https://arxiv.org", "arXiv", ["/abs/1706.03762", "/list/cs.LG/recent", "/abs/2106.09685"]),
  ]

  struct Visit {
    let url: String
    let title: String
    let visits: Int
    let lastSeconds: Double  // since 1970
  }

  /// `count` rows: every site/path pair first, then numbered pages of those sites.
  static func visits(_ count: Int, seed: Int, now: Date) -> [Visit] {
    var out: [Visit] = []
    var rng = UInt64(seed) &* 0x9E37_79B9_7F4A_7C15 | 1
    func next() -> UInt64 {
      rng ^= rng << 13
      rng ^= rng >> 7
      rng ^= rng << 17
      return rng
    }
    var n = 0
    outer: for round in 0..<Int.max {
      for (base, name, paths) in sites {
        for p in paths {
          if n >= count { break outer }
          let path = round == 0 ? p : p + (p.contains("?") ? "&" : "?") + "page=\(round)"
          let rank = Double(n + 1)
          let visits = max(1, Int(400 / rank.squareRoot()) - Int(next() % 3))
          let ageDays = Double(next() % 90) + Double(next() % 1000) / 1000
          out.append(Visit(url: base + path, title: round == 0 ? "\(name) · \(p)" : "\(name) · \(p) (\(round))", visits: visits,
                           lastSeconds: now.timeIntervalSince1970 - ageDays * 86400))
          n += 1
        }
      }
      if n >= count { break }
    }
    return out
  }

  // MARK: SQLite

  final class DB {
    var db: OpaquePointer?
    init(_ url: URL) throws {
      try? FileManager.default.removeItem(at: url)
      guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw NSError(domain: "ImportFixtures", code: 1) }
    }
    deinit { sqlite3_close(db) }
    func exec(_ sql: String) throws {
      var err: UnsafeMutablePointer<CChar>?
      guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
        let m = err.map { String(cString: $0) } ?? "?"
        sqlite3_free(err)
        throw NSError(domain: "ImportFixtures", code: 2, userInfo: [NSLocalizedDescriptionKey: m + " in " + sql])
      }
    }
    /// Runs `sql` once per row; values are Int, Int64, Double, String or nil.
    func insert(_ sql: String, _ rows: [[Any?]]) throws {
      var st: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw NSError(domain: "ImportFixtures", code: 3, userInfo: [NSLocalizedDescriptionKey: sql]) }
      defer { sqlite3_finalize(st) }
      let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
      try exec("BEGIN")
      for row in rows {
        sqlite3_reset(st)
        for (i, v) in row.enumerated() {
          let k = Int32(i + 1)
          switch v {
          case let x as Int: sqlite3_bind_int64(st, k, Int64(x))
          case let x as Int64: sqlite3_bind_int64(st, k, x)
          case let x as Double: sqlite3_bind_double(st, k, x)
          case let x as String: sqlite3_bind_text(st, k, x, -1, transient)
          default: sqlite3_bind_null(st, k)
          }
        }
        guard sqlite3_step(st) == SQLITE_DONE else { throw NSError(domain: "ImportFixtures", code: 4, userInfo: [NSLocalizedDescriptionKey: sql]) }
      }
      try exec("COMMIT")
    }
  }

  /// Chromium's `History`: the `urls` table (and `visits`), with a hidden row and an internal page
  /// the importer must skip.
  static func chromiumHistory(_ url: URL, rows: Int, seed: Int, now: Date) throws {
    let db = try DB(url)
    try db.exec("""
      CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
      CREATE TABLE urls(id INTEGER PRIMARY KEY AUTOINCREMENT,url LONGVARCHAR,title LONGVARCHAR,visit_count INTEGER DEFAULT 0 NOT NULL,typed_count INTEGER DEFAULT 0 NOT NULL,last_visit_time INTEGER NOT NULL,hidden INTEGER DEFAULT 0 NOT NULL);
      CREATE TABLE visits(id INTEGER PRIMARY KEY AUTOINCREMENT,url INTEGER NOT NULL,visit_time INTEGER NOT NULL,from_visit INTEGER,transition INTEGER DEFAULT 0 NOT NULL,segment_id INTEGER,visit_duration INTEGER DEFAULT 0 NOT NULL);
      CREATE INDEX urls_url_index ON urls (url);
      INSERT INTO meta VALUES ('version', '69');
      """)
    var data: [[Any?]] = visits(rows, seed: seed, now: now).map { v in
      [v.url, v.title, v.visits, Int64((v.lastSeconds + Double(chromiumEpoch)) * 1_000_000), 0]
    }
    let t = Int64((now.timeIntervalSince1970 + Double(chromiumEpoch)) * 1_000_000)
    data.append(["https://accounts.google.com/o/oauth2/hidden-redirect", "Redirecting…", 3, t, 1])
    data.append(["chrome://settings/", "Settings", 2, t, 0])
    try db.insert("INSERT INTO urls (url, title, visit_count, last_visit_time, hidden) VALUES (?, ?, ?, ?, ?)", data)
  }

  /// Safari's History.db: history_items + history_visits (visit_time: seconds since 2001).
  static func safariHistory(_ url: URL, now: Date) throws {
    let db = try DB(url)
    try db.exec("""
      CREATE TABLE history_items (id INTEGER PRIMARY KEY AUTOINCREMENT,url TEXT NOT NULL UNIQUE,domain_expansion TEXT NULL,visit_count INTEGER NOT NULL,daily_visit_counts BLOB NOT NULL,weekly_visit_counts BLOB NULL,autocomplete_triggers BLOB NULL,should_recompute_derived_visit_counts INTEGER NOT NULL,visit_count_score INTEGER NOT NULL,status_code INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE history_visits (id INTEGER PRIMARY KEY AUTOINCREMENT,history_item INTEGER NOT NULL REFERENCES history_items(id) ON DELETE CASCADE,visit_time REAL NOT NULL,title TEXT NULL,load_successful BOOLEAN NOT NULL DEFAULT 1,http_non_get BOOLEAN NOT NULL DEFAULT 0,synthesized BOOLEAN NOT NULL DEFAULT 0,redirect_source INTEGER NULL UNIQUE,redirect_destination INTEGER NULL UNIQUE,origin INTEGER NOT NULL DEFAULT 0,generation INTEGER NOT NULL DEFAULT 0,attributes INTEGER NOT NULL DEFAULT 0,score INTEGER NOT NULL DEFAULT 0);
      """)
    let vs = visits(150, seed: 5, now: now)
    try db.insert("INSERT INTO history_items (id, url, visit_count, daily_visit_counts, should_recompute_derived_visit_counts, visit_count_score) VALUES (?, ?, ?, x'00', 0, 0)",
                  vs.enumerated().map { [$0.offset + 1, $0.element.url, $0.element.visits] })
    // Two visits per item: an older untitled one, then the latest with its title.
    var rows: [[Any?]] = []
    for (i, v) in vs.enumerated() {
      rows.append([i + 1, v.lastSeconds - 978_307_200 - 86400 * 3, nil])
      rows.append([i + 1, v.lastSeconds - 978_307_200, v.title])
    }
    try db.insert("INSERT INTO history_visits (history_item, visit_time, title) VALUES (?, ?, ?)", rows)
  }

  /// places.sqlite: moz_places and moz_bookmarks with Firefox's roots; Zen adds its workspaces and pins.
  static func places(_ url: URL, zen: Bool, stale: Bool, now: Date) throws {
    let db = try DB(url)
    try db.exec("""
      PRAGMA journal_mode = WAL;
      CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR, rev_host LONGVARCHAR, visit_count INTEGER DEFAULT 0, hidden INTEGER DEFAULT 0 NOT NULL, typed INTEGER DEFAULT 0 NOT NULL, frecency INTEGER DEFAULT -1 NOT NULL, last_visit_date INTEGER, guid TEXT, foreign_count INTEGER DEFAULT 0 NOT NULL, url_hash INTEGER DEFAULT 0 NOT NULL, description TEXT, preview_image_url TEXT, site_name TEXT, origin_id INTEGER, recalc_frecency INTEGER NOT NULL DEFAULT 0, alt_frecency INTEGER, recalc_alt_frecency INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER DEFAULT NULL, parent INTEGER, position INTEGER, title LONGVARCHAR, keyword_id INTEGER, folder_type TEXT, dateAdded INTEGER, lastModified INTEGER, guid TEXT, syncStatus INTEGER NOT NULL DEFAULT 0, syncChangeCounter INTEGER NOT NULL DEFAULT 1);
      """)
    let us = Int64(now.timeIntervalSince1970 * 1_000_000)
    var placeRows: [[Any?]] = []
    let history = stale ? [] : visits(zen ? 60 : 250, seed: zen ? 13 : 17, now: now)
    for (i, v) in history.enumerated() { placeRows.append([i + 1, v.url, v.title, v.visits, 0, Int64(v.lastSeconds * 1_000_000)]) }
    // Bookmarked pages (some never visited), a hidden redirect, and a smart-bookmark place: URL.
    let extra: [(String, String)] = zen
      ? [("https://zen-browser.app/", "Zen Browser"), ("https://docs.zen-browser.app/", "Zen Docs"), ("https://mastodon.social/home", "Mastodon"),
         ("https://www.notion.so/zen-notes", "Notes"), ("https://excalidraw.com/", "Excalidraw"), ("https://music.apple.com/", "Apple Music"),
         ("https://chat.openai.com/", "ChatGPT")]
      : [("https://www.mozilla.org/en-US/firefox/", "Firefox"), ("https://addons.mozilla.org/", "Add-ons for Firefox"), ("https://developer.mozilla.org/en-US/docs/Web/HTML", "HTML: HyperText Markup Language | MDN"),
         ("https://www.rust-lang.org/", "Rust Programming Language"), ("https://doc.rust-lang.org/book/", "The Rust Programming Language"), ("place:sort=8&maxResults=10", "Most Visited")]
    let base = placeRows.count
    for (j, e) in extra.enumerated() { placeRows.append([base + j + 1, e.0, e.1, 0, 0, nil]) }
    placeRows.append([base + extra.count + 1, "https://www.google.com/url?q=x", "Redirect", 4, 1, us])
    try db.insert("INSERT INTO moz_places (id, url, title, visit_count, hidden, last_visit_date) VALUES (?, ?, ?, ?, ?, ?)", placeRows)
    func place(_ url: String) -> Int { (placeRows.firstIndex { ($0[1] as? String) == url } ?? 0) + 1 }
    // Roots: root 1, menu 2, toolbar 3, tags 4, unfiled 5, mobile 6.
    var b: [[Any?]] = [
      [1, 2, nil, 0, 0, "", "root________"], [2, 2, nil, 1, 0, "menu", "menu________"], [3, 2, nil, 1, 1, "toolbar", "toolbar_____"],
      [4, 2, nil, 1, 2, "tags", "tags________"], [5, 2, nil, 1, 3, "unfiled", "unfiled_____"], [6, 2, nil, 1, 4, "mobile", "mobile______"],
    ]
    if zen {
      b += [
        [10, 1, place("https://zen-browser.app/"), 3, 0, "Zen Browser", "zenbm0000001"],
        [11, 1, place("https://docs.zen-browser.app/"), 3, 1, "Zen Docs", "zenbm0000002"],
      ]
    } else {
      b += [
        [10, 1, place("https://www.mozilla.org/en-US/firefox/"), 3, 0, "Firefox", "ffbm00000001"],
        [11, 2, nil, 3, 1, "Rust", "ffbm00000002"],
        [12, 1, place("https://www.rust-lang.org/"), 11, 0, "Rust", "ffbm00000003"],
        [13, 1, place("https://doc.rust-lang.org/book/"), 11, 1, "The Book", "ffbm00000004"],
        [14, 3, nil, 3, 2, "", "ffbm00000005"],  // separator
        [15, 1, place("place:sort=8&maxResults=10"), 3, 3, "Most Visited", "ffbm00000006"],
        [16, 1, place("https://addons.mozilla.org/"), 2, 0, "Add-ons", "ffbm00000007"],
        [17, 1, place("https://developer.mozilla.org/en-US/docs/Web/HTML"), 5, 0, "MDN HTML", "ffbm00000008"],
      ]
    }
    try db.insert("INSERT INTO moz_bookmarks (id, type, fk, parent, position, title, guid) VALUES (?, ?, ?, ?, ?, ?, ?)", b)
    guard zen else { return }
    try db.exec("""
      CREATE TABLE zen_workspaces (id INTEGER PRIMARY KEY, uuid TEXT UNIQUE NOT NULL, name TEXT NOT NULL, icon TEXT, is_default INTEGER NOT NULL DEFAULT 0, container_id INTEGER, position INTEGER NOT NULL DEFAULT 0, theme_type TEXT, theme_colors TEXT, theme_opacity REAL, theme_rotation INTEGER, theme_texture REAL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
      CREATE TABLE zen_pins (id INTEGER PRIMARY KEY, uuid TEXT UNIQUE NOT NULL, title TEXT NOT NULL, url TEXT, container_id INTEGER, workspace_uuid TEXT, position INTEGER NOT NULL, is_essential BOOLEAN NOT NULL DEFAULT 0, is_group BOOLEAN NOT NULL DEFAULT 0, parent_uuid TEXT DEFAULT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
      """)
    let ms = Int64(now.timeIntervalSince1970 * 1000)
    try db.insert("INSERT INTO zen_workspaces (uuid, name, icon, is_default, position, theme_type, theme_colors, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", [
      ["{zw-home}", "Home", "🌿", 1, 0, "gradient", "[{\"c\":[46,139,87],\"isCustom\":false,\"algorithm\":\"analogous\",\"isPrimary\":true},{\"c\":[144,238,144],\"isCustom\":false}]", ms, ms],
      ["{zw-study}", "Study", "📚", 0, 1, "gradient", "[{\"c\":[70,130,180],\"isPrimary\":true}]", ms, ms],
    ])
    try db.insert("INSERT INTO zen_pins (uuid, title, url, workspace_uuid, position, is_essential, is_group, parent_uuid, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", [
      ["{zp-music}", "Apple Music", "https://music.apple.com/", nil, 0, 1, 0, nil, ms, ms],
      ["{zp-chat}", "ChatGPT", "https://chat.openai.com/", nil, 1, 1, 0, nil, ms, ms],
      ["{zp-masto}", "Mastodon", "https://mastodon.social/home", "{zw-home}", 0, 0, 0, nil, ms, ms],
      ["{zp-grp}", "Notes", nil, "{zw-study}", 0, 0, 1, nil, ms, ms],
      ["{zp-notion}", "Notion notes", "https://www.notion.so/zen-notes", "{zw-study}", 0, 0, 0, "{zp-grp}", ms, ms],
      ["{zp-excal}", "Excalidraw", "https://excalidraw.com/", "{zw-study}", 1, 0, 0, "{zp-grp}", ms, ms],
    ])
  }

  // MARK: Chrome session (SNSS)

  /// A session file: two windows; window 1 has three tabs (one navigated back, one closed), window 2
  /// two tabs, the second window closed in the old file only.
  static func session(old: Bool) -> Data {
    var d = Data("SNSS".utf8)
    func i32(_ v: Int32, _ out: inout Data) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
    i32(3, &d)
    func command(_ id: UInt8, _ payload: Data) {
      let size = UInt16(payload.count + 1)
      withUnsafeBytes(of: size.littleEndian) { d.append(contentsOf: $0) }
      d.append(id)
      d.append(payload)
    }
    func ints(_ vs: [Int32]) -> Data {
      var p = Data()
      for v in vs { i32(v, &p) }
      return p
    }
    func pad(_ p: inout Data) { while p.count % 4 != 0 { p.append(0) } }
    func nav(_ tab: Int32, _ index: Int32, _ url: String, _ title: String) {
      var body = Data()
      i32(tab, &body)
      i32(index, &body)
      let u = Data(url.utf8)
      i32(Int32(u.count), &body)
      body.append(u)
      pad(&body)
      let t = Array(title.utf16)
      i32(Int32(t.count), &body)
      for c in t { withUnsafeBytes(of: c.littleEndian) { body.append(contentsOf: $0) } }
      pad(&body)
      // The rest of a real entry (encoded page state, transition, POST flag, referrer…), unread here.
      i32(0, &body)
      i32(1, &body)
      var pickle = Data()
      i32(Int32(body.count), &pickle)
      pickle.append(body)
      command(6, pickle)
    }
    if old {
      command(0, ints([1, 1]))
      nav(1, 0, "https://old.example.com/", "Old session tab")
      command(7, ints([1, 0]))
      return d
    }
    // Window 1: tabs 1, 2, 3.
    command(0, ints([1, 1]))
    command(2, ints([1, 0]))
    nav(1, 0, "https://www.google.com/search?q=den+browser", "den browser - Google Search")
    nav(1, 1, "https://github.com/abhishakenp/den", "abhishakenp/den: a browser on WebKit")
    command(7, ints([1, 1]))
    command(0, ints([1, 2]))
    command(2, ints([2, 1]))
    nav(2, 0, "https://webkit.org/blog/", "Blog | WebKit")
    nav(2, 1, "https://webkit.org/blog/16000/a-later-post/", "A later post | WebKit")
    command(7, ints([2, 0]))  // went back to the blog index
    command(0, ints([1, 3]))
    command(2, ints([3, 2]))
    nav(3, 0, "https://example.org/closed", "Closed tab")
    command(16, ints([3, 0, 0, 0]))  // TabClosed {tab, padding, int64 time}
    // Window 2: tabs 4, 5 (5 is an internal page, skipped).
    command(0, ints([2, 4]))
    command(2, ints([4, 0]))
    nav(4, 0, "https://www.swift.org/documentation/", "Documentation | Swift.org")
    command(7, ints([4, 0]))
    command(0, ints([2, 5]))
    command(2, ints([5, 1]))
    nav(5, 0, "chrome://newtab/", "New Tab")
    command(7, ints([5, 0]))
    return d
  }
}
#endif
