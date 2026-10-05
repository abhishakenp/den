import AppKit
import CordisValue
import CoreSpotlight
import DenTestSupport
import Testing

@testable import DenHost
@testable import PluginCores

/// The `continuity` plugin with the real `spotlight` and `handoff` host services: open tabs and
/// spaces indexed in Core Spotlight (a per-test index, removed afterwards), a Spotlight pick
/// selecting the tab, Handoff of the selected page (never a private one), pages handed to den.
@MainActor
@Suite(.serialized, .watchdog)
struct ContinuityTests {
  func start(_ h: Harness) -> ContinuityCore {
    h.startTabs()
    let c = ContinuityCore(env: h.env)
    c.start()
    return c
  }

  func wait(_ seconds: Double = 20, file: StaticString = #fileID, line: UInt = #line, _ cond: () -> Bool) async -> Bool {
    await Wait.until("a condition", seconds: seconds, file: file, line: line) { cond() }
  }

  @Test func tabsAndSpacesGoToSpotlightAndAPickSelectsThem() async throws {
    let h = Harness()
    defer { h.rt.spotlight.handle(method: "remove", args: .null) }
    let c = start(h)
    // Nothing is indexed until the refresh timer fires (one refresh for a burst of changes).
    #expect(h.rt.spotlight.sent.isEmpty)
    #expect(c.pending)
    h.fireTimers()
    #expect(!c.pending)
    let spaces = h.spaceIds
    #expect(c.lastSpaces.count == spaces.count)
    #expect(!c.lastTabs.isEmpty)
    // Every web tab of every space (favorites once), with its title, address and space.
    var webIds = Set<String>()
    for (i, s) in spaces.enumerated() {
      let l = h.tabs("list", ["spaceId": .string(s)])
      var stack = (i == 0 ? l.a("favorites") : []) + l.a("pinned") + l.a("today")
      while let item = stack.popLast() {
        if item.b("folder") || item.b("split") { stack += item.a("children"); continue }
        if URLs.isWeb(item.s("url")) { webIds.insert(item.s("id")) }
      }
    }
    #expect(!webIds.isEmpty)
    #expect(Set(c.lastTabs.map { $0.s("id") }) == webIds)
    let first = try #require(c.lastTabs.first)
    #expect(!first.s("title").isEmpty && URLs.isWeb(first.s("url")))
    #expect(first.a("keywords").contains(.string(URLs.host(first.s("url")))))
    #expect(h.rt.spotlight.sent["tabs"]?.count == c.lastTabs.count)
    #expect(h.rt.spotlight.sent["spaces"]?.count == spaces.count)

    // An unchanged list sends nothing again; a closed tab is removed.
    let again = h.rt.call("spotlight", "index", ["domain": "tabs", "items": .array(c.lastTabs), "replace": true])
    #expect(again["indexed"] == 0 && again["removed"] == 0)
    let gone = try #require(h.ids("today").first)
    h.tabs("close", ["id": .string(gone)])
    c.refresh()
    #expect(h.rt.spotlight.sent["tabs"]?[gone] == nil)

    // A pick in Spotlight (the app gets CSSearchableItemActionType) selects the tab, in its space.
    let other = try #require(spaces.last)
    let target = try #require(h.ids("pinned", other).first ?? h.ids("today", other).first)
    let pick = NSUserActivity(activityType: CSSearchableItemActionType)
    pick.userInfo = [CSSearchableItemActivityIdentifier: SpotlightService.uniqueId("tabs", target)]
    #expect(h.rt.spotlight.continueActivity(pick))
    #expect(h.tabs("selected").s("id") == target)
    #expect(h.rt.call("spaces", "current").s("id") == other)
    let space = NSUserActivity(activityType: CSSearchableItemActionType)
    space.userInfo = [CSSearchableItemActivityIdentifier: SpotlightService.uniqueId("spaces", spaces[0])]
    #expect(h.rt.spotlight.continueActivity(space))
    #expect(h.rt.call("spaces", "current").s("id") == spaces[0])
    #expect(!h.rt.spotlight.continueActivity(NSUserActivity(activityType: "something.else")))

    // Settings ▸ General ▸ Continuity: Spotlight off removes every item.
    h.rt.call("settings", "set", ["id": "continuity", "key": "spotlight", "value": false])
    #expect(h.rt.spotlight.sent.isEmpty)
    #expect(!c.spotlightOn)
  }

  /// What Spotlight finds: den's index queried in-app (system Spotlight runs the same query).
  @Test func indexedItemsAreFoundBySpotlightQuery() async throws {
    try #require(CSSearchableIndex.isIndexingAvailable(), "Core Spotlight indexing isn't available on this Mac")
    let h = Harness()
    defer { h.rt.spotlight.handle(method: "remove", args: .null) }
    h.record(["spotlight.results"])
    let word = "denprobe\(Int.random(in: 100_000...999_999))"
    h.rt.call("spotlight", "index", ["domain": "tabs", "items": [["id": "t1", "title": .string("A \(word) page"), "url": "https://example.com/a"]]])
    var found: [String] = []
    for _ in 0..<20 where found.isEmpty {
      let before = h.events.count
      h.rt.call("spotlight", "search", ["query": .string(word)])
      _ = await wait { h.events.count > before }
      found = h.events.last?.1.a("ids").compactMap(\.string) ?? []
      if found.isEmpty { try? await Task.sleep(for: .milliseconds(500)) }
    }
    print("continuity spotlight query \(word): \(found) \(h.events.last.map { "\($0.1)" } ?? "")")
    #expect(found == [SpotlightService.uniqueId("tabs", "t1")])
  }

  @Test func handoffOffersTheSelectedPageNeverAPrivateOne() async throws {
    let h = Harness()
    h.record(["app.openURL"])
    let c = start(h)
    let tab = h.tabs("open", ["url": "https://example.com/handoff"]).s("id")
    h.tabs("select", ["id": .string(tab)])
    #expect(await wait { h.rt.handoff.handle(method: "get", args: .null).s("url") == "https://example.com/handoff" })
    #expect(h.rt.handoff.activity?.activityType == NSUserActivityTypeBrowsingWeb)
    #expect(h.rt.handoff.activity?.isEligibleForHandoff == true)
    // A page that isn't on the web: nothing is offered.
    h.tabs("navigate", ["id": .string(tab), "url": "about:blank"])
    #expect(await wait { h.rt.handoff.activity == nil })
    h.tabs("navigate", ["id": .string(tab), "url": "https://example.com/again"])
    #expect(await wait { h.rt.handoff.activity?.webpageURL?.absoluteString == "https://example.com/again" })
    // A private window in front: nothing.
    h.rt.plugins.emit("window.activated", ["id": "p1", "private": true])
    #expect(h.rt.handoff.activity == nil)
    h.rt.plugins.emit("window.activated", ["id": "w1", "private": false])
    #expect(h.rt.handoff.activity != nil)
    // Settings ▸ General ▸ Continuity: off.
    h.rt.call("settings", "set", ["id": "continuity", "key": "handoff", "value": false])
    #expect(h.rt.handoff.activity == nil && !c.handoffOn)

    // A page from another device opens like a link from another app.
    let page = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
    page.webpageURL = URL(string: "https://example.org/from-iphone")
    #expect(h.rt.handoff.continueActivity(page))
    let ev = try #require(h.events.last { $0.0 == "app.openURL" })
    #expect(ev.1.a("urls") == ["https://example.org/from-iphone"] && ev.1.s("source") == "handoff")
    // (NSUserActivity itself refuses a webpageURL that isn't http or https.)
    #expect(!h.rt.handoff.continueActivity(NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)))
    #expect(h.rt.call("handoff", "set", ["url": "javascript:alert(1)"]).isError)
    c.stop()
    #expect(h.rt.handoff.activity == nil)
  }
}
