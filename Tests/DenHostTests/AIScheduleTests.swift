import AppKit
import CordisValue
import Foundation
import FoundationModels
import Testing

@testable import DenHost

@MainActor
@Suite(.serialized)
struct AIScheduleTests {
  static func runtime() -> DenRuntime {
    _ = NSApplication.shared
    return DenRuntime(storageRoot: FileManager.default.temporaryDirectory.appendingPathComponent("den-ai-\(UUID())"))
  }

  func until(_ seconds: Double = 10, _ cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
      if cond() { return true }
      try? await Task.sleep(for: .milliseconds(30))
    }
    return cond()
  }

  /// Echoes sizes, and overflows above `limit` characters like the real model's context.
  @MainActor
  final class Fake: AIGenerator {
    var calls: [(String, String)] = []
    var limit = Int.max
    var available = true
    func availability() -> (available: Bool, reason: String?) { available ? (true, nil) : (false, "modelNotReady") }
    var contextSize: Int { 1000 }
    func respond(instructions: String, prompt: String) async throws -> String {
      if prompt.count > limit { throw AIError.contextOverflow }
      calls.append((instructions, prompt))
      return "S\(calls.count)(\(prompt.split(separator: "\n").count))"
    }
    func todo(instructions: String, text: String) async throws -> (actionable: Bool, title: String) {
      calls.append((instructions, text))
      return (!text.contains("thanks"), "Do: " + text)
    }
  }

  @Test func chunkingKeepsEachRequestInsideTheBudget() {
    let lines = (0..<50).map { "line \($0) " + String(repeating: "x", count: 90) }
    let chunks = AIService.chunk(lines, budget: 1000)
    #expect(chunks.flatMap { $0 } == lines)
    #expect(chunks.allSatisfy { c in c.reduce(0) { $0 + $1.count + 1 } <= 1000 })
    let long = AIService.chunk([String(repeating: "y", count: 5000)], budget: 1000)
    #expect(long.count == 1 && long[0][0].count == 501)  // truncated to half the budget + "…"
  }

  @Test func summarizeMapsThenReduces() async {
    let rt = Self.runtime()
    let fake = Fake()
    rt.ai.generator = fake
    rt.ai.charsPerToken = 1
    rt.ai.reservedTokens = 0  // budget = 1000 characters
    let lines = (0..<30).map { "notification \($0) " + String(repeating: "z", count: 80) }
    let text = try! await rt.ai.summarize(lines, instructions: "sum")
    // 30 lines of ~96 chars: 3 map calls (10 + 10 + 10 lines), then 1 reduce over 3 partials.
    #expect(fake.calls.count == 4)
    #expect(fake.calls.last!.0.contains("Merge these partial summaries"))
    #expect(text == "S4(3)")
  }

  @Test func contextOverflowSplitsTheChunk() async {
    let rt = Self.runtime()
    let fake = Fake()
    fake.limit = 400
    rt.ai.generator = fake
    rt.ai.charsPerToken = 1
    rt.ai.reservedTokens = 0
    let lines = (0..<8).map { "n\($0) " + String(repeating: "q", count: 90) }
    _ = try! await rt.ai.summarize(lines, instructions: "sum")
    // 8 lines (~760 chars) overflow at 400: split into halves of 4 (~380 chars) that fit.
    #expect(fake.calls.filter { !$0.0.contains("Merge") }.map { $0.1.split(separator: "\n").count } == [4, 4])
  }

  @Test func serviceRunsRequestsAsEventsAndFallsBackWhenUnavailable() async {
    let rt = Self.runtime()
    let fake = Fake()
    rt.ai.generator = fake
    var results: [Value] = []
    rt.plugins.on("ai.result") { results.append($0) }
    #expect(rt.call("ai", "availability") == ["available": true, "contextSize": 1000])
    #expect(rt.call("ai", "todos", ["id": "t", "items": [["id": "a", "text": "Ana needs a review"], ["id": "c", "text": "thanks for the fix"],
                                                        ["id": "a", "text": "duplicate"], ["id": "b", "text": "Build is red"]], "max": 2]) == ["id": "t"])
    #expect(rt.call("ai", "brief", ["id": "b", "sources": [["name": "Slack", "items": ["x", "y"]], ["name": "GitHub", "items": []]]]) == ["id": "b"])
    #expect(await until { results.count == 2 })
    let todos = results.first { $0.str("id") == "t" }!
    #expect(todos["todos"] == [["item": "a", "title": "Do: Ana needs a review"], ["item": "b", "title": "Do: Build is red"]])
    let brief = results.first { $0.str("id") == "b" }!
    #expect(brief.flag("ok") && brief.list("sources").count == 1 && !brief.str("text").isEmpty)
    fake.available = false
    #expect(rt.call("ai", "availability")["reason"] == "modelNotReady")
    _ = rt.call("ai", "summarize", ["id": "u", "items": ["x"]])
    #expect(await until { results.count == 3 })
    #expect(results[2]["error"] == "unavailable" && results[2]["reason"] == "modelNotReady")
  }

  /// The real on-device model, when this Mac has Apple Intelligence (skipped otherwise).
  @Test func realFoundationModelsBriefAndTodos() async throws {
    let rt = Self.runtime()
    let a = rt.call("ai", "availability")
    guard a.flag("available") else {
      print("Foundation Models unavailable: \(a.str("reason")) — skipping")
      return
    }
    #expect(a["contextSize"].int ?? 0 >= 4096)
    var results: [Value] = []
    rt.plugins.on("ai.result") { results.append($0) }
    let items: [Value] = [
      ["id": "r1", "text": "jonw requested your review on acme/web #1482: Checkout: retry card iframe load on Safari"],
      ["id": "d1", "text": "Maya Chen sent you a direct message: Can you look at the Q3 launch deck before the 2pm review?"],
      ["id": "m1", "text": "ana mentioned you in #launch: Launch checklist is up, you own the release notes"],
      ["id": "t1", "text": "jon mentioned you in #eng-web: thanks for the review!"],
      ["id": "c1", "text": "CI is failing on your PR abhishakenp/den #209: Briefing: rank feed by kind"],
    ]
    _ = rt.call("ai", "todos", ["id": "todos", "items": .array(items), "max": 5])
    _ = rt.call("ai", "brief", ["id": "brief", "sources": [["name": "Slack", "items": .array(items.prefix(3).map { $0["text"] })],
                                                         ["name": "GitHub", "items": [items[0]["text"], items[3]["text"]]]]])
    #expect(await until(180) { results.count == 2 })
    let todos = results.first { $0.str("id") == "todos" }!
    let brief = results.first { $0.str("id") == "brief" }!
    print("FM todos:", todos, "\nFM brief:", brief)
    #expect(todos.flag("ok"))
    let picked = todos.list("todos")
    #expect(picked.count >= 3 && picked.count <= 5)
    #expect(picked.allSatisfy { ["r1", "d1", "m1", "c1", "t1"].contains($0.str("item")) && !$0.str("title").isEmpty })
    // Whether the small model drops the thank-you (t1) varies; it is printed above, not asserted.
    // Each title belongs to its own item.
    #expect(picked.first { $0.str("item") == "r1" }.map { $0.str("title").lowercased().contains("review") || $0.str("title").contains("1482") } ?? true)
    #expect(picked.first { $0.str("item") == "m1" }.map { !$0.str("title").contains("Q3") } ?? true)  // no details from other items
    #expect(picked.first { $0.str("item") == "d1" }.map { $0.str("title").contains("Maya") || $0.str("title").lowercased().contains("deck") } ?? true)
    #expect(brief.flag("ok") && brief.list("sources").count == 2 && brief.str("text").count > 20)
  }

  // MARK: schedule

  @Test func dailyFiresAtTimeCatchesUpOnceAndPersists() async {
    let rt = Self.runtime()
    var fired: [Value] = []
    rt.plugins.on("schedule.fire") { fired.append($0) }
    let cal = Calendar.current
    var t = cal.date(bySettingHour: 7, minute: 0, second: 0, of: Date())!
    rt.schedule.now = { t }
    // First registration never catches up.
    #expect(rt.call("schedule", "daily", ["id": "m", "hour": 8, "minute": 0]) == .ok)
    #expect(rt.call("schedule", "daily", ["id": "bad", "hour": 25]).isError)
    t = t.addingTimeInterval(3600 + 10)  // 8:00:10
    rt.schedule.tick()
    #expect(fired == [["id": "m", "reason": "time"]])
    rt.schedule.tick()
    #expect(fired.count == 1)
    #expect(rt.call("schedule", "list")[0]["next"].double! > t.timeIntervalSince1970 * 1000 + 23 * 3_600_000)

    // Next launch the following day at 9:30: den missed 8:00, so it catches up once.
    let rt2 = DenRuntime(storageRoot: rt.storage.root)
    var fired2: [Value] = []
    rt2.plugins.on("schedule.fire") { fired2.append($0) }
    let t2 = t.addingTimeInterval(86_400 + 5400)
    rt2.schedule.now = { t2 }
    _ = rt2.call("schedule", "daily", ["id": "m", "hour": 8, "minute": 0])
    #expect(await until { fired2.count == 1 })
    #expect(fired2 == [["id": "m", "reason": "catchup"]])
    rt2.schedule.tick()
    #expect(fired2.count == 1)
    // Same day, relaunch again: already fired, nothing to catch up.
    let rt3 = DenRuntime(storageRoot: rt.storage.root)
    var fired3: [Value] = []
    rt3.plugins.on("schedule.fire") { fired3.append($0) }
    rt3.schedule.now = { t2.addingTimeInterval(60) }
    _ = rt3.call("schedule", "daily", ["id": "m", "hour": 8, "minute": 0])
    try? await Task.sleep(for: .milliseconds(100))
    #expect(fired3.isEmpty)
  }

  @Test func intervalAndWake() {
    let rt = Self.runtime()
    var fired: [Value] = []
    rt.plugins.on("schedule.fire") { fired.append($0) }
    var t = Date()
    rt.schedule.now = { t }
    _ = rt.call("schedule", "interval", ["id": "poll", "ms": 1000, "wake": true])  // clamped to 60 s
    t = t.addingTimeInterval(30)
    rt.schedule.tick()
    #expect(fired.isEmpty)
    t = t.addingTimeInterval(31)
    rt.schedule.tick()
    #expect(fired == [["id": "poll", "reason": "interval"]])
    rt.schedule.tick(wake: true)
    #expect(fired.last == ["id": "poll", "reason": "wake"])
    _ = rt.call("schedule", "cancel", ["id": "poll"])
    t = t.addingTimeInterval(600)
    rt.schedule.tick(wake: true)
    #expect(fired.count == 2)
    let clock = rt.call("schedule", "clock")
    #expect(clock["hour"].int != nil && !clock.str("date").isEmpty && clock.str("time").hasSuffix("M"))
  }
}
