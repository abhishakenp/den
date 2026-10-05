// Chromium browsers (Chrome, Brave, Edge, Arc, Dia): one folder per profile ("Default",
// "Profile 1", …) with
// - `Bookmarks`: JSON, roots.bookmark_bar / other / synced, nodes {type: url|folder, name, url, children, guid}
// - `History`: SQLite, table `urls` (url, title, visit_count, last_visit_time in µs since 1601),
//   locked while the browser runs: the host's `files.sqlite` reads a copy
// - `Sessions/Session_<time>`: the open windows and tabs, Chromium's SNSS command log (below).

#if !hasFeature(Embedded)
  import CordisValue
#endif

enum ImportChromium {
  /// Newest visits first; den keeps at most this many (the command bar's cap).
  static let historyLimit = 20000
  static let historySQL =
    "SELECT url, title, visit_count, last_visit_time FROM urls WHERE hidden = 0 AND last_visit_time > 0 AND (url LIKE 'http://%' OR url LIKE 'https://%') ORDER BY last_visit_time DESC LIMIT 20000"
  /// Microseconds between 1601-01-01 (Windows FILETIME epoch, Chromium's) and 1970-01-01.
  static let epochDeltaMicros: Int64 = 11_644_473_600_000_000

  /// Profile folders, "Default" first.
  static func profiles(_ entries: [Value]) -> [String] {
    var out: [String] = []
    for e in entries where e.b("dir") {
      let n = e.s("name")
      if n == "Default" || Text.hasPrefix(n, "Profile ") { out.append(n) }
    }
    out.sort { a, b in a == "Default" ? b != "Default" : (b == "Default" ? false : profileNumber(a) < profileNumber(b)) }
    return out
  }

  static func profileNumber(_ n: String) -> Int { Text.int(Text.dropPrefix(n, "Profile ")) ?? 1_000_000 }

  // MARK: Bookmarks

  static func bookmarks(_ v: Value, keyPrefix: String) -> [ImportNode] {
    let roots = v["roots"]
    var out = nodes(roots["bookmark_bar"].a("children"), keyPrefix, depth: 0)
    let other = nodes(roots["other"].a("children"), keyPrefix, depth: 0)
    if !other.isEmpty { out.append(.folder(keyPrefix + "other", "Other Bookmarks", other)) }
    let synced = nodes(roots["synced"].a("children"), keyPrefix, depth: 0)
    if !synced.isEmpty { out.append(.folder(keyPrefix + "synced", "Mobile Bookmarks", synced)) }
    return ImportNode.clean(out)
  }

  static func nodes(_ list: [Value], _ prefix: String, depth: Int) -> [ImportNode] {
    guard depth < 32 else { return [] }
    var out: [ImportNode] = []
    for n in list {
      let id = n.sOpt("guid") ?? n.s("id")
      if n.s("type") == "folder" {
        out.append(.folder(prefix + id, n.s("name"), nodes(n.a("children"), prefix, depth: depth + 1)))
      } else if n.s("type") == "url" {
        out.append(.tab(prefix + id, n.s("name"), n.s("url")))
      }
    }
    return out
  }

  // MARK: History

  /// Rows of `historySQL` (url, title, visit_count, last_visit_time).
  static func history(_ rows: [Value]) -> [ImportVisit] {
    var out: [ImportVisit] = []
    for row in rows {
      guard let r = row.array, r.count >= 4, let url = r[0].string, URLs.isWeb(url) else { continue }
      let t = r[3].int ?? Int64(r[3].double ?? 0)
      out.append(ImportVisit(url: url, title: r[1].string ?? "", visits: max(1, r[2].int ?? 1), last: max(0, (t - epochDeltaMicros) / 1000)))
    }
    return out
  }

  // MARK: Sessions (SNSS)

  /// Chromium's session file: "SNSS", an int32 version (1, or 3 with markers), then commands,
  /// each a uint16 size, a uint8 id and `size - 1` bytes of payload (session_service_commands.cc).
  /// Payloads used here:
  /// - 0 SetTabWindow {int32 window, int32 tab}
  /// - 2 SetTabIndexInWindow {int32 tab, int32 index}
  /// - 6 UpdateTabNavigation: a Pickle (uint32 size, then int32 tab, int32 nav index, string url,
  ///   string16 title, …; strings are an int32 length then the bytes, padded to 4)
  /// - 7 SetSelectedNavigationIndex {int32 tab, int32 index}
  /// - 16 TabClosed {int32 tab, …}, 17 WindowClosed {int32 window, …}
  /// Returns the tabs still open, window by window in tab order, each at its selected entry.
  static func sessionTabs(_ bytes: [UInt8], keyPrefix: String) -> [ImportNode] {
    var r = ByteReader(bytes)
    guard let m = r.bytes(4), m == Array("SNSS".utf8), let version = r.i32(), version >= 1 && version <= 3 else { return [] }
    struct T {
      var window = -1
      var index = 0
      var selected = -1
      var navs: [Int: (String, String)] = [:]
      var closed = false
    }
    var tabs: [Int: T] = [:]
    var order: [Int] = []
    var closedWindows: [Int] = []
    func touch(_ id: Int) {
      if tabs[id] == nil {
        tabs[id] = T()
        order.append(id)
      }
    }
    while r.remaining >= 3 {
      guard let size = r.u16(), size >= 1, let id = r.u8(), let payload = r.bytes(size - 1) else { break }
      var p = ByteReader(payload)
      switch id {
      case 0:
        if let w = p.i32(), let t = p.i32() { touch(t); tabs[t]!.window = w }
      case 2:
        if let t = p.i32(), let i = p.i32() { touch(t); tabs[t]!.index = i }
      case 6:
        _ = p.i32()  // pickle payload size
        guard let t = p.i32(), let i = p.i32(), let ulen = p.i32(), let ub = p.bytes(ulen) else { continue }
        p.align4()
        var title = ""
        if let tlen = p.i32(), tlen >= 0, let tb = p.bytes(tlen * 2) { title = UTF16Text.decode(tb) }
        touch(t)
        tabs[t]!.navs[i] = (String(decoding: ub, as: UTF8.self), title)
      case 7:
        if let t = p.i32(), let i = p.i32() { touch(t); tabs[t]!.selected = i }
      case 16:
        if let t = p.i32() { touch(t); tabs[t]!.closed = true }
      case 17:
        if let w = p.i32() { closedWindows.append(w) }
      default: break
      }
    }
    var open: [(Int, Int, Int)] = []  // window, index, tab
    for t in order {
      guard let tab = tabs[t], !tab.closed, !closedWindows.contains(tab.window), !tab.navs.isEmpty else { continue }
      open.append((tab.window, tab.index, t))
    }
    open.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
    var out: [ImportNode] = []
    var seen: [String] = []
    for (_, _, t) in open {
      let tab = tabs[t]!
      let nav = tab.navs[tab.selected] ?? tab.navs[tab.navs.keys.max() ?? 0]
      guard let (url, title) = nav, URLs.isWeb(url), !seen.contains(URLs.normalize(url)) else { continue }
      seen.append(URLs.normalize(url))
      out.append(.tab(keyPrefix + URLs.normalize(url), title, url))
    }
    return out
  }

  /// The newest `Session_<time>` (else `Current Session`) in a profile's file list.
  static func newestSession(_ entries: [Value]) -> String? {
    var best: (Int64, String)?
    for e in entries where !e.b("dir") {
      let n = e.s("name")
      guard Text.hasPrefix(n, "Session_") || n == "Current Session" else { continue }
      let stamp = Int64(Text.int(Text.dropPrefix(n, "Session_")) ?? 0)
      let key = max(stamp, e.i("modified"))
      if best == nil || key > best!.0 { best = (key, n) }
    }
    return best?.1
  }
}
