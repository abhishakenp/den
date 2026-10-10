#if !hasFeature(Embedded)
  import CordisValue
#endif

/// RSS live folders: read RSS/Atom feeds, poll via `net.fetch`, emit `feed.items` for
/// `LiveFolders` to show as sidebar rows with unread indicators.
///
/// - **Config**: `~/.den/config.toml` `[rss]` section (read via `config.get`):
///   ```toml
///   [rss]
///   feeds = [
///     { url = "https://github.com/...", name = "den Releases", icon = "..." },
///     { url = "https://...", name = "Swift Blog" },
///   ]
///   ```
/// - **Polling**: every 15 minutes via timer, on `feed.refresh`.
/// - **Feed item shape** (same as other providers):
///   `{id, key, source, title, url, ts, icon, kind, detail?, summary?}`
/// - **Seen keys**: stored in `LiveFolders` per folder (its `seen` array).

final class RssCore {
  static let ns = "rss"
  static let pollIntervalMs: UInt64 = 15 * 60 * 1000

  struct Feed {
    var url: String
    var name: String
    var icon: String
    var id: String
  }

  let env: PluginEnv
  let requests: Requests
  var feeds: [Feed] = []
  var registerAttempts = 0
  var registered = false

  init(env: PluginEnv) {
    self.env = env
    requests = Requests(env: env, prefix: "rss")
  }

  // MARK: Config

  /// Read feeds from config service (the `config` service parses config.toml).
  private func loadFeeds() -> [Feed] {
    // Config service: get "rss" section directly.
    let rss = env.call("config", "get", ["key": .string("rss")])
    guard case .object = rss else { return [] }
    let feedsVal = rss["feeds"]
    guard case .array = feedsVal else { return [] }
    var result: [Feed] = []
    for fv in feedsVal.array ?? [] {
      let url = fv.sOpt("url") ?? ""
      guard !url.isEmpty else { continue }
      let name = fv.sOpt("name") ?? feedUrlToName(url)
      let icon = fv.sOpt("icon") ?? ""
      result.append(Feed(url: url, name: name, icon: icon, id: url))
    }
    return result
  }

  /// A simple name from an RSS URL.
  private func feedUrlToName(_ url: String) -> String {
    let u = Array(url.utf8)
    if let end = URLs.find(u, Array("://".utf8)) {
      var i = end + 3
      while i < u.count, u[i] != 47, u[i] != 63, u[i] != 35 { i += 1 }
      var host = Array(u[(end + 3)..<i])
      if let at = host.lastIndex(of: 64) { host = Array(host[(at + 1)...]) }
      if let colon = host.lastIndex(of: 58) { host = Array(host[..<colon]) }
      let s = String(decoding: host, as: UTF8.self)
      return s.isEmpty ? "RSS Feed" : s.split(separator: ".").last.map { String($0) } ?? "RSS Feed"
    }
    return "RSS Feed"
  }

  // MARK: Start

  func start() {
    feeds = loadFeeds()
    for f in feeds {
      LiveFolders.registerSource(LiveFolders(id: f.id, title: f.name, icon: f.icon.isEmpty ? "sf:dot.radiowaves.left.and.right" : f.icon))
    }
    env.on("feed.refresh") { [self] _ in refresh() }
    env.on("config.changed") { [self] v in configChanged(v["config"]) }
    register()
    refresh()
    env.timer(Self.pollIntervalMs, true) { [self] in refresh() }
  }

  /// React to config reload (user edits config.toml).
  private func configChanged(_ cfg: Value) {
    let oldIds = Set(feeds.map { $0.id })
    feeds = loadFeeds()
    let newIds = Set(feeds.map { $0.id })
    // Register any newly added feeds.
    for added in newIds.subtracting(oldIds) {
      if let f = feeds.first(where: { $0.id == added }) {
        LiveFolders.registerSource(LiveFolders(id: f.id, title: f.name, icon: f.icon.isEmpty ? "sf:dot.radiowaves.left.and.right" : f.icon))
      }
    }
    // Refresh all feeds if config changed.
    if !oldIds.isEmpty || !newIds.isEmpty { refresh() }
  }

  // MARK: Refresh

  func refresh() {
    guard !feeds.isEmpty else { return }
    let steps: [(@escaping () -> Void) -> Void] = feeds.map { feed in
      { [self] next in
        requests.call("net", "fetch", ["plugin": .string("rss"), "url": .string(feed.url), "as": "text",
                                        "headers": ["Accept": "application/rss+xml, application/atom+xml, text/xml"]]) { [self] r in
          if r.b("ok"), let text = r.sOpt("text"), !text.isEmpty {
            let items = parseFeed(text, feed: feed)
            env.emit("feed.items", ["source": .string(feed.id), "items": .array(items)])
          }
          next()
        }
      }
    }
    sequence(steps) {}
  }

  // MARK: Feed Parsing (RSS 2.0 + Atom)

  func parseFeed(_ xml: String, feed: Feed) -> [Value] {
    let b = Array(xml.utf8)
    if xml.hasPrefix("<feed") {
      return parseAtom(b, feed: feed)
    }
    return parseRss(b, feed: feed)
  }

  private func parseRss(_ b: [UInt8], feed: Feed) -> [Value] {
    var out: [Value] = []
    var pos = 0
    let maxItems = 50
    while out.count < maxItems, let (item, next) = Web.between(b, "<item>", "</item>", from: pos) {
      pos = next
      let ib = Array(item.utf8)
      func field(_ tag: String) -> String {
        Web.oneLine(Web.entities(Web.between(ib, "<" + tag + ">", "</" + tag + ">")?.0 ?? ""))
      }
      let title = field("title")
      let link = field("link")
      let pubDate = field("pubDate")
      let description = field("description")
      guard !title.isEmpty || !link.isEmpty else { continue }
      let itemId = makeItemId(link, title: title, pubDate: pubDate)
      let ts: Int64 = pubDate.isEmpty ? 0 : Web.isoMs(pubDate) / 1000
      out.append([
        "id": .string("rss:" + feed.id + ":" + itemId),
        "key": .string(itemId),
        "source": .string("rss"),
        "title": .string(title),
        "url": .string(link),
        "ts": .int(ts),
        "icon": .string(feed.icon.isEmpty ? "sf:dot.radiowaves.left.and.right" : feed.icon),
        "kind": .string("rss"),
        "detail": .string(description),
      ])
    }
    return out
  }

  private func parseAtom(_ b: [UInt8], feed: Feed) -> [Value] {
    var out: [Value] = []
    var pos = 0
    let maxItems = 50
    while out.count < maxItems, let (entry, next) = Web.between(b, "<entry>", "</entry>", from: pos) {
      pos = next
      let eb = Array(entry.utf8)
      func field(_ tag: String) -> String {
        Web.oneLine(Web.entities(Web.between(eb, "<" + tag + ">", "</" + tag + ">")?.0 ?? ""))
      }
      var link = ""
      if let l = Web.between(eb, "<link", ">")?.0, let h = Web.between(Array(l.utf8), "href=\"", "\"")?.0 {
        link = Web.entities(h)
      }
      let title = field("title")
      let published = field("published")
      let updated = field("updated")
      let summary = field("summary")
      let content = field("content")
      guard !title.isEmpty || !link.isEmpty else { continue }
      let date = published.isEmpty ? updated : published
      let itemId = makeItemId(link, title: title, pubDate: date)
      let ts: Int64 = date.isEmpty ? 0 : Web.isoMs(date) / 1000
      out.append([
        "id": .string("rss:" + feed.id + ":" + itemId),
        "key": .string(itemId),
        "source": .string("rss"),
        "title": .string(title),
        "url": .string(link),
        "ts": .int(ts),
        "icon": .string(feed.icon.isEmpty ? "sf:dot.radiowaves.left.and.right" : feed.icon),
        "kind": .string("rss"),
        "detail": .string(summary.isEmpty ? content : summary),
      ])
    }
    return out
  }

  /// Create a stable id for an RSS item from link + title + date.
  private func makeItemId(_ link: String, title: String, pubDate: String) -> String {
    let urlHash = stableHash(link)
    var slug: [UInt8] = []
    for c in title.prefix(30).utf8 {
      if (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) {
        slug.append(c >= 65 && c <= 90 ? c + 32 : c)
      } else {
        slug.append(45)
      }
    }
    return urlHash + "-" + String(decoding: slug, as: UTF8.self)
  }

  /// Simple hash for a URL string (deterministic, no crypto).
  private func stableHash(_ s: String) -> String {
    var hash: UInt64 = 5381
    for c in s.utf8 {
      hash = hash &* 33 &+ UInt64(c)
    }
    let hexChars = Array("0123456789abcdef".utf8)
    var result = [UInt8]()
    var h = hash
    for _ in 0..<12 {
      result.append(hexChars[Int(h & 0xF)])
      h >>= 4
    }
    return String(decoding: result.reversed(), as: UTF8.self)
  }

  // MARK: Service

  func handle(_ method: String, _ args: Value) -> Value {
    switch method {
    case "feeds":
      return .array(feeds.map { f in
        ["url": .string(f.url), "name": .string(f.name), "icon": .string(f.icon)]
      })
    case "refresh":
      let url = args.sOpt("url")
      if let url, let feed = feeds.first(where: { $0.url == url }) {
        requests.call("net", "fetch", ["plugin": .string("rss"), "url": .string(url), "as": "text",
                                        "headers": ["Accept": "application/rss+xml, application/atom+xml, text/xml"]]) { [self] r in
          if r.b("ok"), let text = r.sOpt("text"), !text.isEmpty {
            let items = parseFeed(text, feed: feed)
            env.emit("feed.items", ["source": .string(feed.id), "items": .array(items)])
          }
        }
        return .okay
      }
      refresh()
      return .okay
    default:
      return ["error": .string("rss: unknown method " + method)]
    }
  }

  // MARK: Registration

  func register() {
    let r = env.call("connections", "register", ["id": .string("rss"), "title": "RSS", "icon": "sf:dot.radiowaves.left.and.right",
                                                  "owner": .string("rss"), "order": 100])
    registered = !r.isErr
    if !registered && registerAttempts < 60 {
      registerAttempts += 1
      env.timer(500, false) { [self] in register() }
    }
  }
}