// Imported browsing history for the command bar (`commands.importHistory`): what the `importer`
// plugin reads from Arc, Chrome, Safari, Firefox and the rest. It feeds the bar's History rows and
// their frecency. Kept apart from the bar's own `usage` (400 entries, rewritten on every pick):
// storage ns `commandbar.history`, key `items`, read only when the bar first needs history (never
// at launch). Each entry is lowercased and masked once (like CommandIndex), so a keystroke over
// 20,000 entries is one AND per entry plus byte compares on the few that pass.

#if !hasFeature(Embedded)
  import CordisValue
#endif

final class CommandHistory {
  static let ns = "commandbar.history"
  static let maxItems = 20_000
  /// Visits beyond this don't raise the score (a page visited 5,000 times is not 100x a page
  /// visited 50 times).
  static let maxVisits: Int64 = 50

  final class Item {
    var url: String
    var title: String
    var visits: Int64
    var last: Int64
    var batch: String
    let norm: String
    // Precomputed, lowercased UTF-8.
    var t: [UInt8]
    let u: [UInt8]
    let host: [UInt8]
    var mask: UInt64

    init(url: String, title: String, visits: Int64, last: Int64, batch: String) {
      self.url = url
      self.title = title
      self.visits = visits
      self.last = last
      self.batch = batch
      norm = URLs.normalize(url)
      t = Matcher.bytes(title)
      u = Matcher.bytes(url)
      host = Matcher.bytes(URLs.host(url))
      mask = Matcher.mask(t) | Matcher.mask(u)
    }

    func retitle(_ s: String) {
      title = s
      t = Matcher.bytes(s)
      mask = Matcher.mask(t) | Matcher.mask(u)
    }

    var value: Value {
      ["url": .string(url), "title": .string(title), "visits": .int(visits), "last": .int(last), "batch": .string(batch)]
    }
  }

  let env: PluginEnv
  var items: [Item] = []
  var byNorm: [String: Int] = [:]
  private(set) var loaded = false

  init(env: PluginEnv) { self.env = env }

  // MARK: - Store

  func load() {
    guard !loaded else { return }
    loaded = true
    let v = env.call("storage", "get", ["ns": .string(Self.ns), "key": "items"])
    for e in v.array ?? [] {
      let url = e.s("url")
      guard !url.isEmpty else { continue }
      let it = Item(url: url, title: e.s("title"), visits: e.i("visits"), last: e.i("last"), batch: e.s("batch"))
      guard byNorm[it.norm] == nil else { continue }
      byNorm[it.norm] = items.count
      items.append(it)
    }
  }

  func save() {
    env.call("storage", "set", ["ns": .string(Self.ns), "key": "items", "value": .array(items.map { $0.value })])
  }

  func reindex() {
    byNorm = [:]
    for (j, it) in items.enumerated() { byNorm[it.norm] = j }
  }

  var count: Int {
    load()
    return items.count
  }

  /// Merges imported entries by normalized URL: visits and last visit take the larger value, the
  /// title the newer non-empty one; an entry remembers every batch that brought it (`forget`).
  func merge(_ list: [Value], batch: String, now: Int64) -> (added: Int, updated: Int) {
    load()
    var added = 0, updated = 0
    for e in list {
      let url = e.s("url")
      guard URLs.isWeb(url) else { continue }
      let visits = max(1, e.i("visits", 1)), last = e.i("last"), title = e.s("title")
      if let j = byNorm[URLs.normalize(url)] {
        let it = items[j]
        if !title.isEmpty && (it.title.isEmpty || last > it.last) && title != it.title { it.retitle(title) }
        it.visits = max(it.visits, visits)
        it.last = max(it.last, last)
        // Every import that brought it is remembered, so undoing one keeps what another brought.
        if !batch.isEmpty && !Self.batches(it.batch).contains(batch) { it.batch = it.batch.isEmpty ? batch : it.batch + " " + batch }
        updated += 1
      } else {
        let it = Item(url: url, title: title, visits: visits, last: last, batch: batch)
        byNorm[it.norm] = items.count
        items.append(it)
        added += 1
      }
    }
    if items.count > Self.maxItems {
      // Keep the most frecent; ties keep the more recent visit.
      let scored = items.map { (Self.frecency($0.visits, $0.last, now), $0) }
      items = scored.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1.last > $1.1.last }.prefix(Self.maxItems).map { $0.1 }
      reindex()
    }
    save()
    return (added, updated)
  }

  /// The imports an entry came from: `batch` holds their ids, space-separated (ids have no spaces).
  static func batches(_ s: String) -> [String] {
    var out: [String] = []
    var cur: [UInt8] = []
    for c in s.utf8 {
      if c == 32 {
        if !cur.isEmpty { out.append(String(decoding: cur, as: UTF8.self)) }
        cur = []
      } else {
        cur.append(c)
      }
    }
    if !cur.isEmpty { out.append(String(decoding: cur, as: UTF8.self)) }
    return out
  }

  /// Undoes `batch`: entries only it brought go; entries another import also brought stay.
  func forget(batch: String) -> Int {
    load()
    let before = items.count
    var changed = false
    var kept: [Item] = []
    for it in items {
      let bs = Self.batches(it.batch)
      guard bs.contains(batch) else {
        kept.append(it)
        continue
      }
      changed = true
      let rest = bs.filter { $0 != batch }
      if rest.isEmpty { continue }
      var s = ""
      for b in rest { s += (s.isEmpty ? "" : " ") + b }
      it.batch = s
      kept.append(it)
    }
    guard changed else { return 0 }
    items = kept
    reindex()
    save()
    return before - items.count
  }

  // MARK: - Ranking

  /// The command bar's frecency weights (CommandBarCore.frecency), with visits capped.
  static func frecency(_ visits: Int64, _ last: Int64, _ now: Int64) -> Int {
    let day: Int64 = 86_400_000
    let age = now - last
    let w: Int64
    if age < day { w = 100 } else if age < 4 * day { w = 80 } else if age < 14 * day { w = 60 } else if age < 31 * day { w = 40 } else if age < 90 * day { w = 20 } else { w = 10 }
    return Int(min(visits, maxVisits) * w)
  }

  /// How well the query matches an entry, with the bar's own rules for history (`match`): title
  /// prefix 100, word prefix 70, substring 40; host prefix 60, anywhere in the URL 20. nil = no match.
  static func match(_ q: (words: [[UInt8]], phrase: [UInt8], mask: UInt64), _ it: Item) -> Int? {
    if q.words.isEmpty { return 0 }
    if q.mask & ~it.mask != 0 { return nil }
    var total = 0
    for w in q.words {
      var best = 0
      if Matcher.prefix(it.t, w) { best = 100 } else if Matcher.wordPrefix(it.t, w) { best = 70 } else if Matcher.contains(it.t, w) { best = 40 }
      if best < 60 {
        if Matcher.prefix(it.host, w) { best = 60 } else if Matcher.contains(it.u, w) { best = max(best, 20) }
      }
      if best == 0 { return nil }
      total += best
    }
    return total / q.words.count
  }

  /// The best `limit` matches (match + capped frecency), skipping normalized URLs in `exclude`.
  func search(_ query: String, exclude: Set<String>, limit: Int, now: Int64) -> [(item: Item, match: Int, score: Int)] {
    load()
    let q = Matcher.words(query)
    guard !q.words.isEmpty, limit > 0 else { return [] }
    var best: [(item: Item, match: Int, score: Int)] = []
    for it in items {
      guard let m = Self.match(q, it) else { continue }
      let s = m + min(Self.frecency(it.visits, it.last, now) / 2, 150)
      if best.count == limit, let lastScore = best.last?.score, s <= lastScore { continue }
      if exclude.contains(it.norm) { continue }
      var j = best.count
      while j > 0 && best[j - 1].score < s { j -= 1 }
      best.insert((it, m, s), at: j)
      if best.count > limit { best.removeLast() }
    }
    return best
  }
}
