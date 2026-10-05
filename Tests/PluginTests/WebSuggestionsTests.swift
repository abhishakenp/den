import CordisValue
import DenTestSupport
import Foundation
import Testing

@testable import DenHost
@testable import PluginCores

/// The command bar's web suggestions over `net.fetch` (they were the host `suggest` service:
/// docs/architecture/thin-host.md §6 step 2). Ported from SuggestServiceTests.
@MainActor
@Suite(.serialized, .watchdog)
struct WebSuggestionsTests {
  final class Fake {
    var fetched: [(id: String, url: String)] = []
    var cancelled: [String] = []
    var arrived: [(String, [String])] = []
    var timers: [() -> Void] = []
    var handlers: [String: [(Value) -> Void]] = [:]
    var next = 0
    func emit(_ e: String, _ v: Value) { for h in handlers[e] ?? [] { h(v) } }
    /// Answers fetch `i` the way `net` does.
    func answer(_ i: Int, _ items: [String]?) {
      let f = fetched[i]
      let q = String(f.url.dropFirst(WebSuggestions.endpoint.count))
      emit("net.result", items.map { ["id": .string(f.id), "ok": true, "status": 200, "json": [.string(q), .array($0.map { .string($0) }), [], ["google:suggestsubtypes": [[512]]]]] }
        ?? ["id": .string(f.id), "ok": false, "error": "offline"])
    }
  }

  static func make(debounceMs: UInt64 = 0) -> (WebSuggestions, Fake) {
    let fake = Fake()
    let env = PluginEnv(
      invoke: { s, m, a in
        switch (s, m) {
        case ("net", "fetch"):
          #expect(a.s("plugin") == "commandbar" && a.s("as") == "json")
          fake.next += 1
          let id = "n\(fake.next)"
          fake.fetched.append((id, a.s("url")))
          return ["id": .string(id)]
        case ("net", "cancel"):
          fake.cancelled.append(a.s("id"))
          return ["ok": true]
        default: return ["error": "no service"]
        }
      },
      emit: { _, _ in },
      on: { e, h in fake.handlers[e, default: []].append(h) },
      timer: { _, _, h in fake.timers.append(h) },
      now: { 0 },
      log: { _ in })
    let w = WebSuggestions(env: env)
    w.debounceMs = debounceMs
    w.arrived = { fake.arrived.append(($0, $1)) }
    w.start()
    return (w, fake)
  }

  @Test func parsesGoogleSuggestJSONAndEncodesTheQuery() {
    let body: Value = ["icon", ["icon", "icons", "iconic meaning"], [], ["google:suggestsubtypes": [[512]]]]
    #expect(WebSuggestions.parse(body) == ["icon", "icons", "iconic meaning"])
    #expect(WebSuggestions.parse("nope") == nil)
    let (w, fake) = Self.make()
    _ = w.query("café & co")
    #expect(fake.fetched.last?.url == "https://suggestqueries.google.com/complete/search?client=firefox&q=caf%C3%A9+%26+co")
  }

  @Test func answersOnlyTheLatestQueryAndCachesEveryAnswer() {
    let (w, fake) = Self.make()
    #expect(w.query("ic") == nil)
    #expect(w.query("Icon ") == nil)
    #expect(fake.fetched.map(\.url) == [WebSuggestions.endpoint + "ic", WebSuggestions.endpoint + "icon"])
    #expect(fake.cancelled == ["n1"])  // the stale request is cancelled
    // The stale answer still lands late: not announced (cancelled requests are forgotten).
    fake.answer(0, ["ice"])
    fake.answer(1, ["icon", "icons"])
    #expect(fake.arrived.map(\.0) == ["icon"])
    #expect(fake.arrived.last?.1 == ["icon", "icons"])
    // Cached answers come back synchronously, with no fetch and no callback.
    #expect(w.query(" icon") == ["icon", "icons"])
    #expect(fake.fetched.count == 2 && fake.arrived.count == 1)
    // A failed fetch announces an empty list and isn't cached.
    _ = w.query("iconic")
    fake.answer(2, nil)
    #expect(fake.arrived.last?.1 == [])
    _ = w.query("x")
    _ = w.query("iconic")
    #expect(fake.fetched.last?.url == WebSuggestions.endpoint + "iconic" && fake.fetched.count == 5)
    // A superseded answer that does arrive is cached for next time.
    _ = w.query("swi")
    _ = w.query("swif")
    #expect(fake.cancelled.contains(fake.fetched[5].id))
    #expect(w.query("") == [])
  }

  @Test func debouncesKeystrokesAndCancels() {
    let (w, fake) = Self.make(debounceMs: 50)
    for q in ["g", "gi", "git"] { #expect(w.query(q) == nil) }
    #expect(fake.fetched.isEmpty)  // inside the debounce window
    for t in fake.timers { t() }  // every keystroke's timer fires; only the last one is current
    #expect(fake.fetched.map(\.url) == [WebSuggestions.endpoint + "git"])
    w.cancel()
    #expect(fake.cancelled == ["n1"])
    fake.answer(0, ["github"])
    #expect(fake.arrived.isEmpty)
  }
}
