import AppIntents
import CordisValue
import DenTestSupport
import Foundation
import Testing

@testable import DenHost
@testable import PluginCores

/// den's App Intents (Shortcuts, Siri, Spotlight actions) run in-process against a real runtime
/// with the spaces and tabs plugins: what each action does to den, and what it returns.
/// (Whether Shortcuts lists them needs a Team ID signature; see DenIntents.swift.)
@MainActor
@Suite(.serialized, .watchdog)
struct IntentsTests {
  func harness() -> Harness {
    let h = Harness()
    h.startTabs()
    DenIntents.runtime = h.rt
    return h
  }

  @Test func spacesAndTabsAsEntities() async throws {
    let h = harness()
    let spaces = try await SpaceQuery().suggestedEntities()
    #expect(spaces.map(\.id) == h.spaceIds)
    let work = try #require(spaces.first { $0.name == "Work" })
    #expect(try await SpaceQuery().entities(matching: "wor").map(\.id) == [work.id])
    #expect(try await SpaceQuery().entities(for: [work.id]).first?.name == "Work")
    let tabs = try await TabQuery().suggestedEntities()
    #expect(!tabs.isEmpty)
    #expect(Set(tabs.map(\.id)).count == tabs.count, "a tab listed twice")
    let t = try #require(tabs.first { $0.url?.host() != nil })
    #expect(try await TabQuery().entities(for: [t.id]).first?.title == t.title)
  }

  @Test func openPageNewTabSwitchSpaceAndOpenTab() async throws {
    let h = harness()
    let spaces = try await SpaceQuery().suggestedEntities()
    let other = try #require(spaces.last)
    _ = try await OpenPageIntent(url: URL(string: "https://example.com/from-shortcuts")!, space: other).perform()
    #expect(h.rt.call("spaces", "current").s("id") == other.id)
    let sel = h.tabs("selected").s("id")
    #expect(h.rt.webviews.record(sel)?.url == "https://example.com/from-shortcuts")
    #expect(h.ids("today", other.id).contains(sel))

    _ = try await SwitchSpaceIntent(space: spaces[0]).perform()
    #expect(h.rt.call("spaces", "current").s("id") == spaces[0].id)

    // New Tab without a URL and without the command bar loaded: a blank tab, selected.
    let before = h.ids("today", other.id)
    _ = try await NewTabIntent(space: other).perform()
    #expect(h.rt.call("spaces", "current").s("id") == other.id)
    let blank = h.tabs("selected").s("id")
    #expect(!before.contains(blank) && h.rt.webviews.record(blank)?.url == "about:blank")
    _ = try await NewTabIntent(space: nil, url: URL(string: "https://example.org/new")!).perform()
    #expect(h.rt.webviews.record(h.tabs("selected").s("id"))?.url == "https://example.org/new")

    // Find Tabs, then Open Tab with what it found.
    let found = try await SearchTabsIntent(query: "from-shortcuts").perform()
    let hits = try #require(found.value)
    #expect(hits.map(\.id) == [sel])
    _ = try await SwitchSpaceIntent(space: spaces[0]).perform()
    _ = try await OpenTabIntent(tab: hits[0]).perform()
    #expect(h.tabs("selected").s("id") == sel)
    #expect(h.rt.call("spaces", "current").s("id") == other.id)
  }

  @Test func currentPageAndPictureInPicture() async throws {
    let h = harness()
    let tab = h.tabs("open", ["url": "https://example.com/current"]).s("id")
    h.tabs("select", ["id": .string(tab)])
    let page = try #require(try await GetCurrentPageIntent().perform().value)
    #expect(page.id == tab && page.url?.absoluteString == "https://example.com/current")
    // Nothing playing: Picture in Picture says so instead of doing nothing.
    await #expect(throws: (any Error).self) { _ = try await TogglePictureInPictureIntent().perform() }
    // Without a runtime (den not ready): an error, never a crash.
    DenIntents.runtime = nil
    await #expect(throws: (any Error).self) { _ = try await GetCurrentPageIntent().perform() }
    #expect(try await SpaceQuery().suggestedEntities().isEmpty)
  }
}
