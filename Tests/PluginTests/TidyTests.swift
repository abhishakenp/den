import AppKit
import CordisValue
import DenTestSupport
import Foundation
import Testing

@testable import DenHost
@testable import PluginCores

/// Tidy Tabs: `ai.group` on the host, and the tabs plugin's setting, divider, command, key,
/// undo and toasts. The on-device model is faked (CI runners have no Apple Intelligence).
@MainActor
@Suite(.serialized, .watchdog)
struct TidyTests {
  final class TidyAI: AIGenerator {
    var available = true
    var reason = "modelNotReady"
    var prompts: [String] = []
    var answer: (String) -> [(name: String, items: [Int])] = TidyTests.byKeyword
    func availability() -> (available: Bool, reason: String?) { available ? (true, nil) : (false, reason) }
    var contextSize: Int { 4096 }
    func respond(instructions: String, prompt: String) async throws -> String { "" }
    func todo(instructions: String, text: String) async throws -> (actionable: Bool, title: String) { (false, "") }
    func group(instructions: String, prompt: String) async throws -> [(name: String, items: [Int])] {
      prompts.append(prompt)
      return answer(prompt)
    }
  }

  /// Lisbon pages in one group, Swift pages in another (plus a number that doesn't exist).
  static func byKeyword(_ prompt: String) -> [(name: String, items: [Int])] {
    var trip: [Int] = [], swift: [Int] = []
    for line in prompt.split(separator: "\n") {
      guard let dot = line.firstIndex(of: "."), let n = Int(line[..<dot]) else { continue }
      let l = line.lowercased()
      if l.contains("lisb") { trip.append(n) } else if l.contains("swift") { swift.append(n) }
    }
    return [("“Lisbon Trip.”", trip), ("Swift", swift + [999])]
  }

  static let urls = ["https://www.visitlisboa.com/", "https://www.swift.org/documentation/", "https://en.wikipedia.org/wiki/Lisbon",
                     "https://developer.apple.com/swift/", "https://example.com/"]

  func until(_ seconds: Double = 10, line: UInt = #line, _ cond: () -> Bool) async -> Bool {
    await Wait.until("a condition", seconds: seconds, line: line) { cond() }
  }

  func setUp(_ ai: TidyAI, tabs urls: [String] = TidyTests.urls) -> (Harness, TabsCore) {
    let h = Harness()
    h.rt.ai.generator = ai
    let core = h.startTabs()
    // Start from an empty Today (the first-run seed has a few tabs there).
    let sid = core.currentSpace
    for id in core.looseToday(sid) where id != core.selected[sid] { core.archiveTab(id, space: sid) }
    for u in urls { h.tabs("open", ["url": .string(u), "background": true]) }
    return (h, core)
  }

  func divider(_ h: Harness) -> Value { h.tree("sidebar.today", 0)["children"][0] }
  func folders(_ h: Harness) -> [Value] { (h.tabs("list")["today"].array ?? []).filter { $0["folder"] == true } }
  func toast(_ h: Harness) -> (id: String, text: String)? { h.rt.ui.toasts.last.map { ($0.toastId, $0.label.stringValue) } }

  @Test func aiGroupKeepsValidDisjointGroups() async {
    let h = Harness()
    let ai = TidyAI()
    ai.answer = { _ in [("A", [1, 1, 2, 9]), ("B", [2, 3]), ("", [4]), ("C", [0])] }
    h.rt.ai.generator = ai
    var results: [Value] = []
    h.rt.plugins.on("ai.result") { results.append($0) }
    let items: [Value] = [["id": "a", "text": "one"], ["id": "b", "text": "two"], ["id": "c", "text": "three"], ["id": "d", "text": "four"]]
    #expect(h.rt.call("ai", "group", ["id": "g", "items": .array(items), "maxGroups": 4]) == ["id": "g"])
    #expect(await until { results.count == 1 })
    #expect(results[0]["groups"] == [["name": "A", "items": ["a", "b"]], ["name": "B", "items": ["c"]]])
    #expect(ai.prompts.first == "1. one\n2. two\n3. three\n4. four")
    #expect(TabsCore.tidyAddress("https://www.en.wikipedia.org/wiki/Lisbon/") == "en.wikipedia.org/wiki/Lisbon")
    // Generators without guided generation answer in text lines.
    let parsed = AIService.parseGroups("1. Travel: 1, 3\n- **Work**: 2,4\nnothing here\n“Misc”: none")
    #expect(parsed.map(\.name) == ["Travel", "Work"] && parsed.map(\.items) == [[1, 3], [2, 4]])
  }

  @Test func offByDefaultAndSaysHowToTurnItOn() {
    let ai = TidyAI()
    let (h, _) = setUp(ai)
    // No Tidy button on the divider; its menu names Clear's shortcut.
    #expect(divider(h)["secondary"].isNull && divider(h)["action"] == "Clear")
    #expect(divider(h)["menu"] == [["id": "clear", "title": "Clear Today", "icon": "sf:arrow.down", "key": "cmd+shift+k", "keyFor": "tabs.key.clear"]])
    let tabs = (h.rt.call("settings", "list").array ?? []).first { $0.s("id") == "tabs" }
    let schema = tabs?["schema"].array ?? []
    #expect(schema.first { $0.s("key") == "tabs.tidy" }?["value"] == false)
    #expect(schema.first { $0.s("key") == "tabs.tidyAuto" }?["value"] == false)
    h.key("ctrl+shift+t")
    #expect(toast(h)?.id == "tabs.tidy.off")
    #expect(ai.prompts.isEmpty && folders(h).isEmpty)
    // The toast's button opens Settings at Tabs.
    h.action("tabs.tidy.off", "toast")
    #expect(h.rt.settings.window?.section == "tabs")
    h.rt.settings.window?.window.close()
  }

  @Test func tidySortsLooseTabsIntoNamedGroupsAndUndoes() async {
    let ai = TidyAI()
    let (h, _) = setUp(ai)
    #expect(h.rt.call("settings", "set", ["id": "tabs", "key": "tidy", "value": true]) == .ok)
    let before = h.ids("today")
    // On: Tidy on the divider (hover), and in its menu with ⌃⇧T.
    #expect(divider(h)["secondary"] == ["id": "tidy", "title": "Tidy", "icon": "sf:sparkles", "always": false])
    #expect(divider(h)["menu"].array?.first?["key"] == "ctrl+shift+t")
    h.record(["ai.result"])
    h.action(divider(h).s("id"), "tidy")
    // Busy: the button stays up as "Tidying…".
    #expect(divider(h)["secondary"]["title"] == "Tidying…" && divider(h)["secondary"]["always"] == true)
    let done = await until { folders(h).count == 2 }
    #expect(done, "ai.result: \(h.events.map { $0.1 }); prompts: \(ai.prompts); toasts: \(h.rt.ui.toasts.map { $0.label.stringValue })")
    let f = folders(h)
    #expect(Set(f.map { $0.s("title") }) == ["Lisbon Trip", "Swift"])
    #expect(f.allSatisfy { $0["open"] == false && $0["auto"] == false })
    let tripFolder = f.first { $0.s("title") == "Lisbon Trip" } ?? .null
    let trip = tripFolder.list("children").map { $0.s("url") }
    #expect(Set(trip) == ["https://www.visitlisboa.com/", "https://en.wikipedia.org/wiki/Lisbon"])
    // Rendered as Today groups; the rest stay loose.
    #expect(h.tree("sidebar.today", 0)["children"].array?.filter { $0["type"] == "folder" }.allSatisfy { $0["style"] == "group" } == true)
    #expect(h.ids("today").count == before.count - 4 + 2)
    #expect(toast(h)?.id == "tabs.tidy" && toast(h)?.text == "Tidied 4 tabs into 2 groups. Use ⌃Z to undo.")
    #expect(divider(h)["secondary"]["title"] == "Tidy")
    // The toast's Undo puts everything back in one step.
    h.action("tabs.tidy", "toast")
    #expect(folders(h).isEmpty && h.ids("today") == before)
    // So does ⌃Z, after tidying from the keyboard.
    h.key("ctrl+shift+t")
    #expect(await until { folders(h).count == 2 })
    h.key("ctrl+z")
    #expect(folders(h).isEmpty && h.ids("today") == before)
  }

  @Test func unavailableModelIsExplainedInPlainWords() {
    let ai = TidyAI()
    ai.available = false
    ai.reason = "appleIntelligenceNotEnabled"
    let (h, _) = setUp(ai)
    h.rt.call("settings", "set", ["id": "tabs", "key": "tidy", "value": true])
    #expect(h.rt.settings.control("tabs", "tidy")?.str("subtitle").hasPrefix("Turn on Apple Intelligence in System Settings first.") == true)
    h.key("ctrl+shift+t")
    #expect(toast(h)?.text == "Turn on Apple Intelligence in System Settings first.")
    #expect(ai.prompts.isEmpty && folders(h).isEmpty)
  }

  @Test func tooFewTabsAndNothingToGroup() async {
    let ai = TidyAI()
    let (h, _) = setUp(ai, tabs: ["https://example.com/"])
    h.rt.call("settings", "set", ["id": "tabs", "key": "tidy", "value": true])
    h.key("ctrl+shift+t")
    #expect(toast(h)?.text.hasPrefix("Nothing to tidy") == true && ai.prompts.isEmpty)
    let (h2, _) = setUp(ai, tabs: ["https://example.com/", "https://example.org/", "https://example.net/"])
    h2.rt.call("settings", "set", ["id": "tabs", "key": "tidy", "value": true])
    h2.key("ctrl+shift+t")
    #expect(await until { toast(h2)?.text == "Your tabs already look tidy." })
    #expect(folders(h2).isEmpty)
    // The plan only keeps groups of 2+ loose tabs, each tab once.
    let plan = TabsCore.tidyPlan([["name": "A", "items": ["x", "y", "gone"]], ["name": "B", "items": ["y", "z"]], ["name": "C", "items": ["z", "w"]]],
                                 loose: ["w", "x", "y", "z"])
    #expect(plan.map(\.0) == ["A", "C"] && plan.map(\.1) == [["x", "y"], ["w", "z"]])
  }

  @Test func automaticTidyOnlyWhenBothSettingsAreOn() async {
    let ai = TidyAI()
    let many = (0..<4).map { "https://www.swift.org/page\($0)" } + (0..<4).map { "https://www.visitlisboa.com/page\($0)" }
    let (h, core) = setUp(ai, tabs: many)
    core.setActive(true)
    core.tick()
    #expect(ai.prompts.isEmpty)  // Tidy off
    h.rt.call("settings", "set", ["id": "tabs", "key": "tidy", "value": true])
    core.tick()
    #expect(ai.prompts.isEmpty)  // on, but not automatic
    h.rt.call("settings", "set", ["id": "tabs", "key": "tidyAuto", "value": true])
    core.tick()
    #expect(await until { folders(h).count == 2 })
    // Not again right away.
    core.tick()
    #expect(ai.prompts.count == 1)
  }
}
