// thin-host: feature-specific, migrate to plugin (whole file)
import CordisValue
import CryptoKit
import Foundation

/// `chrome.history` and `chrome.sessions` over what den knows of where you've been:
///
/// - **Visits** den records while an extension with the `history` permission is loaded: every
///   main-frame address a normal (not private) page commits, with its title. Kept in
///   `<extensions root>/history.json` (newest 10,000), nothing recorded otherwise.
/// - **The archive** (the Library: tabs you closed, `tabs.archive`): one visit each, at the time
///   it was closed. This reaches back before any extension was installed.
/// - **Open tabs**: one visit each, when last selected.
///
/// `deleteUrl`, `deleteRange` and `deleteAll` remove matching visits and archive entries
/// (`tabs.removeArchived`): an extension that clears history clears den's Library too, as
/// clearing history does in any browser. `sessions` is the archive: `getRecentlyClosed` lists it
/// and `restore` reopens an entry (`tabs.restore`).
@MainActor
final class ExtensionHistory {
  struct Visit: Equatable {
    var url: String
    var title: String
    var time: Double
    var transition: String
  }

  let call: (String, String, Value) -> Value
  let file: URL?
  var now: () -> Double = { Date().timeIntervalSince1970 * 1000 }
  static let limit = 10_000
  private var loaded = false
  private(set) var visits: [Visit] = []  // oldest first
  private var saveScheduled = false
  /// Fires `history.onVisited` (set by `ExtensionAPIs`).
  var onVisited: (Value) -> Void = { _ in }
  var onVisitRemoved: (Value) -> Void = { _ in }

  init(call: @escaping (String, String, Value) -> Value, file: URL?) {
    self.call = call
    self.file = file
  }

  // MARK: Recording

  func load() {
    guard !loaded else { return }
    loaded = true
    guard let file, let data = try? Data(contentsOf: file), let v = ValueJSON.parse(data) else { return }
    visits = (v.array ?? []).compactMap { e in
      guard let u = e["url"].string else { return nil }
      return Visit(url: u, title: e.str("title"), time: e.num("time"), transition: e.str("transition", "link"))
    }
  }

  func saveSoon() {
    guard !saveScheduled, file != nil else { return }
    saveScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in MainActor.assumeIsolated { self?.save() } }
  }

  func save() {
    saveScheduled = false
    guard let file else { return }
    let v: Value = .array(visits.map { ["url": .string($0.url), "title": .string($0.title), "time": .double($0.time), "transition": .string($0.transition)] })
    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(ValueJSON.string(v).utf8).write(to: file, options: .atomic)
  }

  /// Drops every recorded visit and the file (no extension with `history` is left).
  func forget() {
    loaded = true
    visits = []
    if let file { try? FileManager.default.removeItem(at: file) }
  }

  /// A page committed `url` (http/https only). Same URL again within 2 s is one visit
  /// (a redirect chain or a reload burst).
  func record(_ url: String, title: String = "", transition: String = "link", at time: Double? = nil) {
    guard url.hasPrefix("http://") || url.hasPrefix("https://") else { return }
    load()
    let t = time ?? now()
    if let last = visits.last, last.url == url, t - last.time < 2000 {
      if !title.isEmpty { visits[visits.count - 1].title = title }
      return
    }
    visits.append(Visit(url: url, title: title, time: t, transition: transition))
    if visits.count > Self.limit { visits.removeFirst(visits.count - Self.limit) }
    saveSoon()
    onVisited(item(url, in: all()) ?? ["id": .string(Self.id(url)), "url": .string(url), "title": .string(title), "lastVisitTime": .double(t), "visitCount": 1, "typedCount": 0])
  }

  /// The page's title arrived after its address: the newest visit of `url` gets it.
  func title(_ title: String, for url: String) {
    load()
    guard !title.isEmpty, let i = visits.lastIndex(where: { $0.url == url }), visits[i].title != title else { return }
    visits[i].title = title
    saveSoon()
  }

  // MARK: Everything den knows

  /// Recorded visits, the archive and open tabs, oldest first.
  func all() -> [Visit] {
    load()
    var out = visits
    for e in call("tabs", "archive", .null).array ?? [] {
      out.append(Visit(url: e.str("url"), title: e.str("title"), time: e.num("closedAt"), transition: "link"))
    }
    for t in openTabs() { out.append(Visit(url: t.str("url"), title: t.str("title"), time: t.num("lastActive"), transition: "link")) }
    return out.filter { $0.url.hasPrefix("http://") || $0.url.hasPrefix("https://") }.sorted { $0.time < $1.time }
  }

  func openTabs() -> [Value] {
    var out: [Value] = []
    let current = call("spaces", "current", .null).str("id")
    for s in call("spaces", "list", .null).array ?? [] {
      let l = call("tabs", "list", ["spaceId": .string(s.str("id"))])
      var stack: [Value] = l.list("pinned") + l.list("today") + (s.str("id") == current ? l.list("favorites") : [])
      while let i = stack.popLast() {
        if i.flag("folder") || i.flag("split") { stack += i.list("children") } else { out.append(i) }
      }
    }
    return out
  }

  /// Chrome's history item ids are strings of digits; den's are stable per URL.
  static func id(_ url: String) -> String {
    let h = SHA256.hash(data: Data(url.utf8))
    return String(h.prefix(6).reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
  }

  func item(_ url: String, in visits: [Visit]) -> Value? {
    let mine = visits.filter { $0.url == url }
    guard let last = mine.last else { return nil }
    let title = mine.last { !$0.title.isEmpty }?.title ?? ""
    return ["id": .string(Self.id(url)), "url": .string(url), "title": .string(title), "lastVisitTime": .double(last.time),
            "visitCount": .int(Int64(mine.count)), "typedCount": .int(Int64(mine.filter { $0.transition == "typed" }.count))]
  }

  // MARK: The API

  func handle(_ method: String, _ args: [Value]) -> Value {
    let a = args.first ?? .null
    switch method {
    case "search": return search(a)
    case "getVisits":
      let url = a.str("url")
      return .array(all().filter { $0.url == url }.enumerated().map { (k, v) in
        ["id": .string(Self.id(url)), "visitId": .string("\(Self.id(url)).\(k)"), "visitTime": .double(v.time), "referringVisitId": "0",
         "transition": .string(v.transition), "isLocal": true]
      })
    case "addUrl":
      let url = a.str("url")
      guard URL(string: url)?.scheme != nil else { return .error("Invalid URL.") }
      record(url, title: a.str("title"), transition: a.str("transition", "link"), at: a["visitTime"].double)
      return .null
    case "deleteUrl":
      let url = a.str("url")
      load()
      visits.removeAll { $0.url == url }
      save()
      _ = call("tabs", "removeArchived", ["urls": [.string(url)]])
      onVisitRemoved(["allHistory": false, "urls": [.string(url)]])
      return .null
    case "deleteRange":
      let start = a.num("startTime"), end = a.num("endTime")
      load()
      var urls = Set(visits.filter { $0.time >= start && $0.time <= end }.map(\.url))
      visits.removeAll { $0.time >= start && $0.time <= end }
      save()
      for e in call("tabs", "removeArchived", ["after": .int(Int64(start)), "before": .int(Int64(end))]).array ?? [] { urls.insert(e.str("url")) }
      onVisitRemoved(["allHistory": false, "urls": .array(urls.sorted().map { .string($0) })])
      return .null
    case "deleteAll":
      load()
      visits = []
      save()
      _ = call("tabs", "removeArchived", ["all": true])
      onVisitRemoved(["allHistory": true, "urls": []])
      return .null
    default: return .error("history.\(method) isn’t available in den")
    }
  }

  /// `search {text, startTime (default 24 h ago), endTime, maxResults (default 100, 0 = all)}`:
  /// pages with a visit in the window whose URL or title has every word, newest first.
  func search(_ q: Value) -> Value {
    let words = q.str("text").lowercased().split(separator: " ").map(String.init)
    let start = q["startTime"].double ?? (now() - 86_400_000), end = q["endTime"].double ?? .infinity
    let max = q["maxResults"].int.map { Int($0) } ?? 100
    let everything = all()
    var latest: [String: Visit] = [:]
    for v in everything where v.time >= start && v.time <= end {
      if let l = latest[v.url], l.time > v.time { continue }
      latest[v.url] = v
    }
    let hits = latest.values.filter { v in
      let title = everything.last { $0.url == v.url && !$0.title.isEmpty }?.title ?? ""
      let hay = (v.url + " " + title).lowercased()
      return words.allSatisfy { hay.contains($0) }
    }.sorted { $0.time > $1.time }
    let picked = max > 0 ? Array(hits.prefix(max)) : hits
    return .array(picked.compactMap { item($0.url, in: everything) })
  }

  // MARK: sessions (the archive)

  func sessions(_ method: String, _ args: [Value]) -> Value {
    switch method {
    case "getRecentlyClosed":
      let n = Swift.min(25, Int(args.first?["maxResults"].int ?? 25))
      return .array((call("tabs", "archive", .null).array ?? []).prefix(n).map(Self.session))
    case "restore":
      let archive = call("tabs", "archive", .null).array ?? []
      let want = args.first?.string
      let found: Value? = want.map { w in archive.first { $0.str("id") == w } } ?? archive.first
      guard let entry = found else { return .error("Invalid session id.") }
      let r = call("tabs", "restore", ["id": .string(entry.str("id"))])
      if r.isError { return r }
      return Self.session(entry)
    case "getDevices": return []
    default: return .error("sessions.\(method) isn’t available in den")
    }
  }

  static func session(_ e: Value) -> Value {
    ["lastModified": .int(Int64(e.num("closedAt") / 1000)),
     "tab": ["sessionId": .string(e.str("id")), "url": .string(e.str("url")), "title": .string(e.str("title")), "favIconUrl": e.str("favicon").hasPrefix("http") ? e["favicon"] : .null,
             "index": 0, "windowId": -1, "active": false, "pinned": false, "highlighted": false, "incognito": false, "selected": false]]
  }
}
