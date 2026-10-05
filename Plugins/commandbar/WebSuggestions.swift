#if !hasFeature(Embedded)
  import CordisValue
#endif

/// Web search autocomplete for the command bar, on the host's generic `net.fetch` (it was the host
/// `suggest` service; docs/architecture/thin-host.md §6 step 2). Google's public suggest endpoint,
/// the one browsers use with `client=firefox` (permission `net:suggestqueries.google.com`).
///
/// - `query(q)` answers from the in-memory cache at once (no network, no callback), else starts a
///   debounced fetch and returns nil; the answer comes through `arrived(q, items)`.
/// - Only the latest query ever reaches `arrived`: a slow answer for "ic" can't land after the one
///   for "icon". A superseded answer is still cached. A failed fetch reports `[]` and isn't cached.
/// - Queries are normalized (lowercased, trimmed, inner whitespace collapsed): that's the cache key.
final class WebSuggestions {
  static let plugin = "commandbar"
  static let endpoint = "https://suggestqueries.google.com/complete/search?client=firefox&q="
  static let cacheLimit = 256
  /// den choice: short enough to feel instant, long enough to skip most keystrokes of fast typing.
  var debounceMs: UInt64 = 50
  var timeoutMs: Int64 = 4000

  let env: PluginEnv
  /// The latest query's answer (normalized query, items).
  var arrived: (String, [String]) -> Void = { _, _ in }

  private var cache: [String: [String]] = [:]
  private var cacheOrder: [String] = []
  private(set) var latest = ""
  private var generation = 0
  private var waiting = false
  /// The `net.fetch` id in flight and the query it is for.
  private var inFlight: (id: String, q: String)?
  /// Fetches still on the wire: id -> query (superseded ones keep their entry, to be cached).
  private var requests: [String: String] = [:]

  init(env: PluginEnv) { self.env = env }

  func start() {
    env.on("net.result") { [self] v in
      let id = v.s("id")
      guard let q = requests[id] else { return }
      requests[id] = nil
      finish(id, q, v["ok"].bool == true && v.i("status") < 400 ? Self.parse(v["json"]) : nil)
    }
  }

  /// Cached items for `q`, or nil while a fetch is pending (the answer comes through `arrived`).
  func query(_ raw: String) -> [String]? {
    let q = Self.normalize(raw)
    guard !q.isEmpty else {
      stop()
      latest = ""
      return []
    }
    if let hit = cache[q] {
      stop()
      latest = q
      return hit
    }
    if q == latest && (waiting || inFlight != nil) { return nil }
    stop()
    latest = q
    let gen = generation
    if debounceMs == 0 { fetch(q, gen); return nil }
    waiting = true
    env.timer(debounceMs, false) { [self] in
      guard gen == generation else { return }
      waiting = false
      fetch(q, gen)
    }
    return nil
  }

  /// Drops the pending query (the bar closed, suggestions were turned off).
  func cancel() {
    stop()
    latest = ""
  }

  private func stop() {
    generation += 1
    waiting = false
    if let f = inFlight {
      env.call("net", "cancel", ["id": .string(f.id)])
      requests[f.id] = nil
      inFlight = nil
    }
  }

  private func fetch(_ q: String, _ gen: Int) {
    guard gen == generation else { return }
    let r = env.call("net", "fetch", ["plugin": .string(Self.plugin), "url": .string(Self.endpoint + CommandBarCore.encode(q)),
                                      "as": "json", "timeoutMs": .int(timeoutMs), "headers": ["Accept": "application/json"]])
    let id = r.s("id")
    // No `net` service or no permission: no suggestions, as with suggestions turned off.
    guard !id.isEmpty, !r.isErr else { return }
    requests[id] = q
    inFlight = (id, q)
  }

  private func finish(_ id: String, _ q: String, _ items: [String]?) {
    if let items { store(q, items) }
    // Superseded (the user typed on, or cancelled): cached, but not announced.
    guard q == latest, inFlight?.id == id else { return }
    inFlight = nil
    arrived(q, items ?? [])
  }

  private func store(_ q: String, _ items: [String]) {
    if cache[q] == nil { cacheOrder.append(q) }
    cache[q] = items
    if cacheOrder.count > Self.cacheLimit { cache[cacheOrder.removeFirst()] = nil }
  }

  /// `["icon", ["icon", "icons", ...], ...]` -> the suggestion strings.
  static func parse(_ json: Value) -> [String]? {
    guard let a = json.array, a.count >= 2, let list = a[1].array else { return nil }
    return list.compactMap { $0.string }
  }

  /// Lowercased, trimmed, inner whitespace collapsed.
  static func normalize(_ s: String) -> String { CommandBarCore.normQuery(s) }
}
