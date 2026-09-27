import CordisValue
import Foundation

/// `suggest` service: web search autocomplete for the command bar (Google's public suggest
/// endpoint, the same one browsers use with `client=firefox`).
///
/// Methods:
///   query {q}   -> {q, items: [string]} when cached (no network, no event), else {q, pending: true}.
///                  A pending query is debounced, replaces (and cancels) any older one, and ends
///                  with a `suggest.results {q, items}` event. Failures emit `items: []`.
///   cancel      -> {ok}: drops the pending query.
///
/// Suggestions are cached in memory (per normalized query, capped). Only the latest query ever
/// emits: a slow response for "ic" can't arrive after the one for "icon".
@MainActor
public final class SuggestService: HostService {
  public let name = "suggest"
  /// A cancellable fetch: `(query, done) -> cancel`. `done` may run on any thread.
  public typealias Fetch = (String, @escaping @Sendable ([String]?) -> Void) -> (() -> Void)

  let host: ServiceHost
  public var fetch: Fetch = { SuggestService.google($0, $1) }
  /// den choice: short enough to feel instant, long enough to skip most keystrokes of fast typing.
  public var debounce: TimeInterval = 0.05
  public static let cacheLimit = 256

  private var cache: [String: [String]] = [:]
  private var cacheOrder: [String] = []
  private var latest = ""
  private var generation = 0
  private var timer: (() -> Void)?
  /// Debounce timer (tests swap in a manual clock).
  public var debounceTimer: HostSchedule = HostTimers.main
  private var cancelInFlight: (() -> Void)?

  public init(host: ServiceHost) { self.host = host }

  public func handle(method: String, args: Value) -> Value {
    switch method {
    case "query":
      let q = Self.normalize(args.str("q"))
      guard !q.isEmpty else {
        stop()
        return ["q": "", "items": []]
      }
      if let hit = cache[q] {
        stop()
        latest = q
        return ["q": .string(q), "items": .array(hit.map { .string($0) })]
      }
      if q == latest && (timer != nil || cancelInFlight != nil) { return ["q": .string(q), "pending": true] }
      schedule(q)
      return ["q": .string(q), "pending": true]
    case "cancel":
      stop()
      latest = ""
      return .ok
    default:
      return .error("suggest: unknown method '\(method)'")
    }
  }

  /// Cache key: trimmed, lowercased, inner whitespace collapsed.
  static func normalize(_ s: String) -> String {
    s.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ")
  }

  private func stop() {
    generation += 1
    timer?()
    timer = nil
    cancelInFlight?()
    cancelInFlight = nil
  }

  private func schedule(_ q: String) {
    stop()
    latest = q
    let gen = generation
    if debounce <= 0 { start(q, gen); return }
    timer = debounceTimer(Int((debounce * 1000).rounded())) { [weak self] in self?.start(q, gen) }
  }

  private func start(_ q: String, _ gen: Int) {
    guard gen == generation else { return }
    timer = nil
    cancelInFlight = fetch(q) { items in
      DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.finish(q, gen, items) } }
    }
  }

  private func finish(_ q: String, _ gen: Int, _ items: [String]?) {
    if let items { store(q, items) }
    guard gen == generation else { return }  // superseded: cached, but not announced
    cancelInFlight = nil
    host.emit("suggest.results", ["q": .string(q), "items": .array((items ?? []).map { .string($0) })])
  }

  private func store(_ q: String, _ items: [String]) {
    if cache[q] == nil { cacheOrder.append(q) }
    cache[q] = items
    if cacheOrder.count > Self.cacheLimit { cache[cacheOrder.removeFirst()] = nil }
  }

  // MARK: - Google

  nonisolated private static let session: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 4
    c.httpAdditionalHeaders = ["Accept": "application/json"]
    return URLSession(configuration: c)
  }()

  nonisolated public static func url(_ q: String) -> URL? {
    var c = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
    c.queryItems = [URLQueryItem(name: "client", value: "firefox"), URLQueryItem(name: "q", value: q)]
    return c.url
  }

  /// `["icon", ["icon", "icons", ...], ...]` -> the suggestion strings.
  nonisolated public static func parse(_ data: Data) -> [String]? {
    guard let arr = try? JSONSerialization.jsonObject(with: data) as? [Any], arr.count >= 2, let list = arr[1] as? [Any] else { return nil }
    return list.compactMap { $0 as? String }
  }

  nonisolated public static func google(_ q: String, _ done: @escaping @Sendable ([String]?) -> Void) -> (() -> Void) {
    guard let u = url(q) else {
      done(nil)
      return {}
    }
    let task = session.dataTask(with: u) { data, _, _ in done(data.flatMap(parse)) }
    task.resume()
    return { task.cancel() }
  }
}
