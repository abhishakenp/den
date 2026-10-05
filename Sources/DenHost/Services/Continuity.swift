import AppKit
import CordisValue
import CoreSpotlight
import UniformTypeIdentifiers

/// `spotlight` service: puts items in the system's Spotlight index for den (Core Spotlight), so
/// Spotlight finds them, and says when one is picked. Which items (open tabs, spaces) and what a
/// pick does is the `continuity` plugin's business; the host only indexes.
///
/// | Method | Args | Returns |
/// |---|---|---|
/// | `index` | `domain`, `items: [{id, title, url?, subtitle?, keywords?}]`, `replace?` (true: the domain's other items are removed) | `{indexed, removed}` |
/// | `remove` | `domain?`, `ids?` | ok. Without either: everything den indexed |
/// | `search` | `query`, `request?` | `{request}`, then `spotlight.results {request, ids, error?}` (an in-app query of den's own items) |
/// | `state` | – | `{available, domains: {domain: count}}` |
///
/// Events: `spotlight.open {id}` when the user picks one of den's items in Spotlight (the app
/// gets `CSSearchableItemActionType`), `spotlight.results`.
///
/// Items carry no page content: title, URL, subtitle and keywords only. Writes are diffed against
/// what this run already sent, so an unchanged tab list costs nothing.
@MainActor
public final class SpotlightService: HostService {
  public let name = "spotlight"
  let host: ServiceHost
  /// den's own index (the real profile), or one per storage root (tests, --demo).
  let index: CSSearchableIndex
  let indexName: String
  /// What this run indexed: domain → id → a fingerprint of the item.
  private(set) var sent: [String: [String: String]] = [:]
  private var queries: [String: CSSearchQuery] = [:]
  private var nextRequest = 1

  public init(host: ServiceHost, indexName: String = "den") {
    self.host = host
    self.indexName = indexName
    index = CSSearchableIndex(name: indexName)
  }

  public func handle(method: String, args: Value) -> Value {
    switch method {
    case "index": return indexItems(domain: args.str("domain", "default"), items: args.list("items"), replace: args.flag("replace", false))
    case "remove": return remove(domain: args["domain"].string, ids: args["ids"].array?.compactMap(\.string))
    case "search": return search(args.str("query"), request: args["request"].string)
    case "state":
      return ["available": .bool(CSSearchableIndex.isIndexingAvailable()),
              "domains": .object(sent.keys.sorted().map { ($0, .int(Int64(sent[$0]?.count ?? 0))) })]
    default: return .error("spotlight: unknown method '\(method)'")
    }
  }

  /// The id den gives Core Spotlight: the domain and the item's id, so two domains can share ids.
  static func uniqueId(_ domain: String, _ id: String) -> String { domain + ":" + id }

  func indexItems(domain: String, items: [Value], replace: Bool) -> Value {
    var known = sent[domain] ?? [:]
    var fresh: [CSSearchableItem] = []
    var seen = Set<String>()
    for v in items {
      let id = v.str("id")
      guard !id.isEmpty, !seen.contains(id) else { continue }
      seen.insert(id)
      let title = v.str("title"), url = v.str("url"), subtitle = v.str("subtitle")
      let keywords = v.list("keywords").compactMap(\.string)
      let print = [title, url, subtitle, keywords.joined(separator: ",")].joined(separator: "\u{1}")
      if known[id] == print { continue }
      known[id] = print
      let a = CSSearchableItemAttributeSet(contentType: url.isEmpty ? .content : .url)
      a.title = title
      a.displayName = title
      a.contentDescription = subtitle.isEmpty ? nil : subtitle
      if let u = URL(string: url), !url.isEmpty {
        a.url = u
        a.contentURL = u
      }
      a.keywords = keywords.isEmpty ? nil : keywords
      let item = CSSearchableItem(uniqueIdentifier: Self.uniqueId(domain, id), domainIdentifier: domain, attributeSet: a)
      // Open tabs change; anything not refreshed for a week drops out on its own.
      item.expirationDate = Date().addingTimeInterval(7 * 86_400)
      fresh.append(item)
    }
    var gone: [String] = []
    if replace {
      gone = known.keys.filter { !seen.contains($0) }.sorted()
      for id in gone { known[id] = nil }
    }
    sent[domain] = known
    if !fresh.isEmpty { index.indexSearchableItems(fresh) { _ in } }
    if !gone.isEmpty { index.deleteSearchableItems(withIdentifiers: gone.map { Self.uniqueId(domain, $0) }) { _ in } }
    return ["indexed": .int(Int64(fresh.count)), "removed": .int(Int64(gone.count))]
  }

  func remove(domain: String?, ids: [String]?) -> Value {
    if let domain, let ids {
      for id in ids { sent[domain]?[id] = nil }
      index.deleteSearchableItems(withIdentifiers: ids.map { Self.uniqueId(domain, $0) }) { _ in }
    } else if let domain {
      sent[domain] = nil
      index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in }
    } else {
      sent = [:]
      index.deleteAllSearchableItems { _ in }
    }
    return .ok
  }

  /// An in-app query over den's own items (what Spotlight would find), for checks and tests.
  func search(_ text: String, request: String?) -> Value {
    let req = request ?? "spotlight-\(nextRequest)"
    nextRequest += 1
    let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let q = CSSearchQuery(queryString: "title == \"*\(escaped)*\"cd", queryContext: {
      let c = CSSearchQueryContext()
      c.fetchAttributes = ["title"]
      return c
    }())
    var ids: [String] = []
    q.foundItemsHandler = { items in
      let found = items.map(\.uniqueIdentifier)
      DispatchQueue.main.async { MainActor.assumeIsolated { ids += found } }
    }
    q.completionHandler = { [weak self] error in
      let message = error?.localizedDescription
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self else { return }
          self.queries[req] = nil
          var out: Value = ["request": .string(req), "ids": .array(ids.map { .string($0) })]
          if let message { out = out.with("error", .string(message)) }
          self.host.emit("spotlight.results", out)
        }
      }
    }
    queries[req] = q
    q.start()
    return ["request": .string(req)]
  }

  /// The user picked one of den's items in Spotlight. Returns whether it was one.
  @discardableResult
  public func continueActivity(_ activity: NSUserActivity) -> Bool {
    guard activity.activityType == CSSearchableItemActionType,
          let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return false }
    host.emit("spotlight.open", ["id": .string(id)])
    return true
  }
}

/// `handoff` service: the page den shows, offered to your other devices (Handoff), and pages
/// they hand to den. Which page (the selected tab, never a private one) is the `continuity`
/// plugin's call.
///
/// | Method | Args | Returns |
/// |---|---|---|
/// | `set` | `url` (http or https), `title?` | ok. Becomes the current `NSUserActivityTypeBrowsingWeb` activity |
/// | `clear` | – | ok. Nothing is offered |
/// | `get` | – | `{url, title, current}` |
///
/// A page another device hands over (Safari on an iPhone, with den as this Mac's default
/// browser) arrives as `app.openURL {urls, source: "handoff"}`, like a link from another app.
@MainActor
public final class HandoffService: HostService {
  public let name = "handoff"
  let host: ServiceHost
  private(set) var activity: NSUserActivity?
  /// Receives pages from other devices (`AppService.open`).
  public var open: ([URL]) -> Void = { _ in }

  public init(host: ServiceHost) { self.host = host }

  public func handle(method: String, args: Value) -> Value {
    switch method {
    case "set":
      guard let u = URL(string: args.str("url")), ["http", "https"].contains(u.scheme?.lowercased() ?? "") else {
        clear()
        return .error("handoff: only http(s) pages can be handed off")
      }
      set(u, title: args.str("title"))
      return .ok
    case "clear": clear(); return .ok
    case "get":
      return ["url": .string(activity?.webpageURL?.absoluteString ?? ""), "title": .string(activity?.title ?? ""),
              "current": .bool(activity != nil)]
    default: return .error("handoff: unknown method '\(method)'")
    }
  }

  func set(_ url: URL, title: String) {
    if let a = activity, a.webpageURL == url {
      if a.title != title { a.title = title; a.needsSave = true }
      return
    }
    activity?.invalidate()
    let a = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
    a.webpageURL = url
    a.title = title.isEmpty ? url.host : title
    a.isEligibleForHandoff = true
    // Spotlight and Siri suggestions get den's own items from `spotlight`, not browsing history.
    a.isEligibleForSearch = false
    a.becomeCurrent()
    activity = a
  }

  func clear() {
    activity?.invalidate()
    activity = nil
  }

  /// A page from another device. Returns whether it was one.
  @discardableResult
  public func continueActivity(_ activity: NSUserActivity) -> Bool {
    guard activity.activityType == NSUserActivityTypeBrowsingWeb, let u = activity.webpageURL,
          ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { return false }
    open([u])
    return true
  }
}
