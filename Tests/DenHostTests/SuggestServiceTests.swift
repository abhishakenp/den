import CordisValue
import Foundation
import DenTestSupport
import Testing

@testable import DenHost

@MainActor
@Suite(.serialized, .watchdog)
struct SuggestServiceTests {
  final class Fake {
    var started: [String] = []
    var cancelled: [String] = []
    var pending: [(String, @Sendable ([String]?) -> Void)] = []
  }

  static func make(debounce: TimeInterval = 0, clock: ManualClock = ManualClock()) -> (SuggestService, ServiceHost, Fake, () -> [Value]) {
    let host = ServiceHost()
    let s = SuggestService(host: host)
    let fake = Fake()
    s.debounce = debounce
    s.debounceTimer = clock.schedule
    s.fetch = { q, done in
      MainActor.assumeIsolated {
        fake.started.append(q)
        fake.pending.append((q, done))
      }
      return { MainActor.assumeIsolated { fake.cancelled.append(q) } }
    }
    var events: [Value] = []
    host.on("suggest.results") { events.append($0) }
    return (s, host, fake, { events })
  }

  /// Answers are delivered with `DispatchQueue.main.async`: one main-queue turn delivers them.
  static func settle() async { await Wait.mainQueueTurn() }

  @Test func parsesGoogleSuggestJSON() {
    let body = #"["icon",["icon","icons","iconic meaning"],[],{"google:suggestsubtypes":[[512]]}]"#
    #expect(SuggestService.parse(Data(body.utf8)) == ["icon", "icons", "iconic meaning"])
    #expect(SuggestService.parse(Data("nope".utf8)) == nil)
    #expect(SuggestService.url("café & co")?.absoluteString == "https://suggestqueries.google.com/complete/search?client=firefox&q=caf%C3%A9%20%26%20co")
  }

  @Test func answersOnlyTheLatestQueryAndCachesEveryAnswer() async {
    let (s, _, fake, events) = Self.make()
    #expect(s.handle(method: "query", args: ["q": "ic"])["pending"] == true)
    #expect(s.handle(method: "query", args: ["q": "Icon "])["pending"] == true)
    #expect(fake.started == ["ic", "icon"])
    #expect(fake.cancelled == ["ic"])  // the stale request is cancelled
    // The stale answer still lands late: cached, but not announced.
    fake.pending[0].1(["ice"])
    fake.pending[1].1(["icon", "icons"])
    await Self.settle()
    #expect(events().map { $0.str("q") } == ["icon"])
    #expect(events().last?["items"] == ["icon", "icons"])
    // Cached answers come back synchronously, with no fetch and no event.
    let hit = s.handle(method: "query", args: ["q": "ic"])
    #expect(hit["items"] == ["ice"])
    #expect(s.handle(method: "query", args: ["q": " icon"])["items"] == ["icon", "icons"])
    #expect(fake.started.count == 2 && events().count == 1)
    // A failed fetch announces an empty list and isn't cached.
    _ = s.handle(method: "query", args: ["q": "iconic"])
    fake.pending[2].1(nil)
    await Self.settle()
    #expect(events().last?["items"] == [])
    _ = s.handle(method: "query", args: ["q": "iconic"])
    #expect(fake.started.last == "iconic" && fake.started.count == 4)
  }

  @Test func debouncesKeystrokesAndCancels() async {
    let clock = ManualClock()
    let (s, _, fake, events) = Self.make(debounce: 0.03, clock: clock)
    for q in ["g", "gi", "git"] { _ = s.handle(method: "query", args: ["q": .string(q)]) }
    #expect(fake.started.isEmpty)
    clock.advance(ms: 29)
    #expect(fake.started.isEmpty)  // still inside the debounce window
    clock.advance(ms: 1)
    #expect(clock.pending == 0)
    #expect(fake.started == ["git"])  // only the last keystroke hits the network
    _ = s.handle(method: "cancel", args: .null)
    fake.pending[0].1(["github"])
    await Self.settle()
    #expect(events().isEmpty)
    #expect(s.handle(method: "query", args: ["q": ""])["items"] == [])
    #expect(s.handle(method: "nope", args: .null).isError)
  }
}
