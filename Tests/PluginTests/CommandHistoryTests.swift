import AppKit
import CordisValue
import DenTestSupport
import Testing

@testable import DenHost
@testable import PluginCores

/// Imported browsing history in the command bar (Plugins/commandbar/CommandHistory.swift):
/// `commands.importHistory`, `forgetHistory`, `history`, and the History rows it feeds.
@MainActor
@Suite(.serialized, .watchdog)
struct CommandHistoryTests {
  static let day: Int64 = 86_400_000

  func entry(_ url: String, _ title: String, visits: Int64 = 3, last: Int64) -> Value {
    ["url": .string(url), "title": .string(title), "visits": .int(visits), "last": .int(last)]
  }

  func histIds(_ h: Harness) -> [String] { h.barRowIds.filter { $0.hasPrefix("hist:") } }

  @Test func importedPagesShowInHistoryAndLoadLazily() {
    let h = Harness()
    let core = h.startCommandBar()
    // Nothing read at launch, or for an empty bar.
    #expect(core.imported.loaded == false)
    h.key("cmd+t")
    #expect(core.imported.loaded == false)
    h.key("cmd+t")

    let r = h.rt.call("commands", "importHistory", ["batch": "a", "source": "chrome", "items": [
      entry("https://doc.rust-lang.org/book/", "The Rust Programming Language", last: h.clock - Self.day),
      entry("https://news.ycombinator.com/", "Hacker News", visits: 40, last: h.clock),
      entry("chrome://settings/", "Settings", last: h.clock),
    ]])
    #expect(r["added"] == 2 && r["updated"] == 0 && r["total"] == 2)
    #expect(h.rt.call("commands", "history")["count"] == 2)
    h.key("cmd+t")
    h.type("rust prog")
    #expect(histIds(h) == ["hist:doc.rust-lang.org/book"])
    #expect(h.bar.list("sections").contains { $0.str("title") == "History" })
    let row = h.barRows.first { $0.str("id") == "hist:doc.rust-lang.org/book" }!
    #expect(row.str("title") == "The Rust Programming Language")

    // Persisted in its own namespace, read again after a restart.
    let h2 = Harness(root: h.root)
    let core2 = h2.startCommandBar()
    #expect(core2.imported.loaded == false)
    #expect(h2.rt.call("commands", "history")["count"] == 2)
  }

  @Test func theBarsOwnHistoryAndOpenTabsWin() {
    let h = Harness()
    let core = h.startCommandBar()
    core.usage["url:example.org/page"] = .init(n: 2, t: h.clock, title: "Example page", url: "https://example.org/page")
    h.rt.call("commands", "importHistory", ["batch": "a", "source": "chrome", "items": [
      entry("https://example.org/page", "Example page", last: h.clock),
      entry("https://example.org/other", "Example other", last: h.clock),
      // Open in the sidebar already (the seed's Hacker News tab).
      entry("https://news.ycombinator.com", "Hacker News", last: h.clock),
    ]])
    h.key("cmd+t")
    h.type("example")
    let ids = histIds(h)
    #expect(ids.filter { $0 == "hist:example.org/page" }.count == 1)
    #expect(ids.contains("hist:example.org/other"))
    h.type("hacker")
    #expect(!histIds(h).contains("hist:news.ycombinator.com"))
  }

  @Test func reimportMergesAndForgetRemovesOnlyItsBatch() {
    let h = Harness()
    h.startCommandBar()
    h.rt.call("commands", "importHistory", ["batch": "a", "source": "chrome", "items": [
      entry("https://swift.org/", "Swift", visits: 2, last: h.clock - 10 * Self.day),
      entry("https://webkit.org/", "WebKit", last: h.clock),
    ]])
    let r = h.rt.call("commands", "importHistory", ["batch": "b", "source": "safari", "items": [
      entry("https://www.swift.org", "Swift.org - Welcome", visits: 9, last: h.clock),
      entry("https://developer.apple.com/", "Apple Developer", last: h.clock),
    ]])
    #expect(r["added"] == 1 && r["updated"] == 1 && r["total"] == 3)
    let core = CommandHistory(env: h.env)
    core.load()
    let swift = core.items[core.byNorm["swift.org"]!]
    #expect(swift.visits == 9 && swift.last == h.clock && swift.title == "Swift.org - Welcome" && swift.batch == "a b")

    // Undoing b drops what only b brought; swift.org stays (a brought it too).
    #expect(h.rt.call("commands", "forgetHistory", ["batch": "b"])["removed"] == 1)
    #expect(h.rt.call("commands", "history")["count"] == 2)
    #expect(h.rt.call("commands", "forgetHistory", ["batch": "b"])["removed"] == 0)
    let again = CommandHistory(env: h.env)
    again.load()
    #expect(again.items[again.byNorm["swift.org"]!].batch == "a")
    #expect(h.rt.call("commands", "forgetHistory", ["batch": "a"])["removed"] == 2)
    #expect(h.rt.call("commands", "history")["count"] == 0)
  }

  /// Realistic-ish history: 20,000 pages over 400 sites.
  static func bigHistory(_ now: Int64, count: Int = CommandHistory.maxItems) -> [Value] {
    let words = ["swift", "rust", "kernel", "design", "pricing", "docs", "blog", "release", "notes", "guide", "issue", "pull", "review",
                 "invoice", "calendar", "recipe", "travel", "flight", "hotel", "weather", "music", "video", "news", "sports"]
    var out: [Value] = []
    out.reserveCapacity(count)
    for n in 0..<count {
      let a = words[n % words.count], b = words[(n / 7) % words.count], c = words[(n / 31) % words.count]
      out.append(["url": .string("https://\(b)\(n % 400).example.com/\(a)/\(c)/\(n)"), "title": .string("\(a.capitalized) \(b) \(c) — page \(n)"),
                  "visits": .int(Int64(1 + n % 3)), "last": .int(now - 200 * day - Int64(n) * 1000)])
    }
    return out
  }

  @Test func capKeepsTheMostFrecent() {
    let h = Harness()
    h.startCommandBar()
    h.rt.call("commands", "importHistory", ["batch": "a", "source": "chrome", "items": .array(Self.bigHistory(h.clock))])
    #expect(h.rt.call("commands", "history")["count"] == .int(Int64(CommandHistory.maxItems)))
    var fresh: [Value] = []
    for n in 0..<5 { fresh.append(entry("https://fresh\(n).test/", "Fresh zebra \(n)", visits: 3, last: h.clock)) }
    let r = h.rt.call("commands", "importHistory", ["batch": "b", "source": "safari", "items": .array(fresh)])
    #expect(r["added"] == 5 && r["total"] == .int(Int64(CommandHistory.maxItems)))
    let core = CommandHistory(env: h.env)
    core.load()
    #expect(core.items.count == CommandHistory.maxItems)
    for n in 0..<5 { #expect(core.byNorm["fresh\(n).test"] != nil) }
    // The least frecent went: one visit, oldest (n = 19998); one visit but newest (n = 0) stays.
    let big = Self.bigHistory(h.clock)
    #expect(core.byNorm[URLs.normalize(big[19998].s("url"))] == nil)
    #expect(core.byNorm[URLs.normalize(big[0].s("url"))] != nil)
  }

  @Test func perKeystrokeLatencyOver20000Entries() {
    let h = Harness()
    let core = h.startCommandBar()
    h.rt.call("commands", "importHistory", ["batch": "a", "source": "chrome", "items": .array(Self.bigHistory(h.clock))])
    #expect(core.imported.items.count == CommandHistory.maxItems)
    let clock = ContinuousClock()
    func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
    var perKey: [Double] = []
    for q in ["swift", "rust kernel", "invoice", "travel flight", "page 1999", "zzqx"] {
      for n in 1...q.count {
        let prefix = String(q.prefix(n))
        let d = (0..<3).map { _ in clock.measure { _ = core.historyRows(prefix, exclude: []) } }.min()!
        perKey.append(ms(d))
      }
    }
    let sorted = perKey.sorted()
    let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
    print(String(format: "history.rows entries=%d keystrokes=%d mean=%.3fms p95=%.3fms max=%.3fms", core.imported.items.count, perKey.count,
                 perKey.reduce(0, +) / Double(perKey.count), p95, sorted.last!))
    #expect(!core.historyRows("invoice", exclude: []).isEmpty)
    // Debug builds run unoptimized and CI runners are loaded: this only guards blowups.
    #if DEBUG
      #expect(p95 < 150.0)
    #else
      #expect(p95 < 15.0)
    #endif
  }
}
