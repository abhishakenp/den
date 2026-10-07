import AppKit
import CordisValue
import DenTestSupport
import Testing

@testable import DenHost
@testable import PluginCores

/// `tabs.importItems` / `tabs.removeImported` (Plugins/tabs/TabsImport.swift): what the importer
/// puts in the sidebar. Real host services, the real tabs and spaces cores.
@MainActor
@Suite(.serialized, .watchdog)
struct TabsImportTests {
  /// Chrome-like bookmarks: a tab, a folder with a tab and a nested folder, and a chrome:// page.
  static let tree: [Value] = [
    ["key": "c:1", "url": "https://swift.org/", "title": "Swift"],
    ["key": "c:dev", "title": "Dev", "folder": true, "children": [
      ["key": "c:2", "url": "https://github.com/apple/swift", "title": "apple/swift"],
      ["key": "c:deep", "title": "Deep", "folder": true, "children": [
        ["key": "c:3", "url": "https://webkit.org/", "title": "WebKit"],
      ]],
    ]],
    ["key": "c:4", "url": "chrome://settings", "title": "Settings"],
  ]

  func importPinned(_ h: Harness, batch: String, items: [Value]? = nil) -> Value {
    h.tabs("importItems", ["batch": .string(batch), "section": "pinned", "folder": ["key": "c:root", "title": "Imported from Chrome"], "items": .array(items ?? Self.tree)])
  }

  func pinnedItems(_ h: Harness) -> [Value] { h.tabs("list")["pinned"].array ?? [] }

  @Test func nestedFoldersLandInOnePinnedFolder() {
    let h = Harness()
    h.startTabs()
    let before = h.ids("pinned")
    let r = importPinned(h, batch: "b1")
    #expect(r["tabs"] == 3 && r["folders"] == 3 && r["skipped"] == 1 && r["existing"] == 0)
    let items = pinnedItems(h)
    #expect(items.count == before.count + 1)
    let top = items.last!
    #expect(top.b("folder") && top.s("title") == "Imported from Chrome" && top["open"] == false)
    let kids = top.a("children")
    #expect(kids.map { $0.s("title") } == ["Swift", "Dev"])
    #expect(kids[0].s("kind") == "pinned" && kids[0].s("pinnedUrl") == "https://swift.org/")
    let dev = kids[1].a("children")
    #expect(dev.map { $0.s("title") } == ["apple/swift", "Deep"])
    #expect(dev[1].a("children").first?.s("url") == "https://webkit.org/")
    // A lazy record per tab: nothing loads.
    let w = h.rt.call("webviews", "get", ["id": .string(kids[0].s("id"))])
    #expect(!w.isErr && w["live"] == false)
    // Persisted with the state (and the key map in its own storage key).
    #expect(!h.storage("tabs", "imported").isNull)
  }

  @Test func todayGroupGoesOnTopAndHoldsTodayTabs() {
    let h = Harness()
    h.startTabs()
    let r = h.tabs("importItems", ["batch": "t1", "section": "today", "folder": ["key": "s:tabs", "title": "From Chrome", "open": true],
                                   "items": [["key": "s:1", "url": "https://example.com/a"], ["key": "s:2", "url": "https://example.com/b"]]])
    #expect(r["tabs"] == 2 && r["folders"] == 1)
    let first = h.tabs("list")["today"][0]
    #expect(first.b("folder") && first.s("title") == "From Chrome")
    #expect(first.a("children").allSatisfy { $0.s("kind") == "today" && $0["pinnedUrl"].isNull })
  }

  @Test func favoritesStopAtTheLimit() {
    let h = Harness()
    h.startTabs()
    let have = h.ids("favorites").count
    var items: [Value] = []
    for n in 0..<10 { items.append(["key": .string("f:\(n)"), "url": .string("https://site\(n).example/")]) }
    let r = h.tabs("importItems", ["batch": "f1", "section": "favorites", "items": .array(items)])
    #expect(Int(r.i("tabs")) == TabsCore.maxFavorites - have)
    #expect(Int(r.i("skipped")) == 10 - (TabsCore.maxFavorites - have))
    #expect(h.ids("favorites").count == TabsCore.maxFavorites)
  }

  @Test func reimportDuplicatesNothingEvenAfterARestart() {
    let h = Harness()
    h.startTabs()
    _ = importPinned(h, batch: "b1")
    let count = pinnedItems(h).count
    let again = importPinned(h, batch: "b2")
    #expect(again["tabs"] == 0 && again["folders"] == 0 && again["existing"] == 3)
    #expect(pinnedItems(h).count == count)

    let h2 = Harness(root: h.root)
    h2.startTabs()
    var more = TabsImportTests.tree
    more.append(["key": "c:5", "url": "https://developer.apple.com/", "title": "Apple Developer"])
    let r = importPinned(h2, batch: "b3", items: more)
    #expect(r["tabs"] == 1 && r["folders"] == 0 && r["existing"] == 3)
    let top = pinnedItems(h2).last!
    #expect(pinnedItems(h2).count == count)
    #expect(top.a("children").map { $0.s("title") } == ["Swift", "Dev", "Apple Developer"])
  }

  @Test func removeImportedTakesOnlyThatBatch() {
    let h = Harness()
    h.startTabs()
    let before = h.ids("pinned")
    let todayBefore = h.ids("today")
    _ = importPinned(h, batch: "b1")
    var more = TabsImportTests.tree
    more.append(["key": "c:5", "url": "https://developer.apple.com/"])
    _ = importPinned(h, batch: "b2", items: more)
    // A tab of the user's own, dropped into the imported folder.
    let mine = todayBefore[0]
    let fid = pinnedItems(h).last!.s("id")
    #expect(!h.tabs("move", ["id": .string(mine), "folderId": .string(fid)]).isErr)

    #expect(h.tabs("removeImported", ["batch": "b2"])["removed"] == 1)
    let top = pinnedItems(h).last!
    #expect(top.s("id") == fid && top.a("children").count == 3)  // Swift, Dev, and the user's tab

    #expect(h.tabs("removeImported", ["batch": "b1"])["removed"] == 6)
    // The user's tab stays, where the folder was; everything else is as before.
    #expect(h.ids("pinned") == before + [mine])
    #expect(h.storage("tabs", "importBatches").object?.isEmpty == true)
    #expect(h.tabs("removeImported", ["batch": "b1"])["removed"] == 0)
  }

  @Test func undoTakesTheImportBackAndKeysFollow() {
    let h = Harness()
    h.startTabs()
    let before = h.ids("pinned")
    _ = importPinned(h, batch: "b1")
    #expect(!h.tabs("undo").isErr)
    #expect(h.ids("pinned") == before)
    // The keys of undone items no longer count: importing again adds them again.
    let r = importPinned(h, batch: "b2")
    #expect(r["tabs"] == 3 && r["existing"] == 0)
  }

  @Test func aThousandBookmarksImportQuickly() {
    let h = Harness()
    h.startTabs()
    var folders: [Value] = []
    for f in 0..<50 {
      var kids: [Value] = []
      for n in 0..<20 { kids.append(["key": .string("p:\(f):\(n)"), "url": .string("https://site\(f).example/page/\(n)"), "title": .string("Page \(f).\(n)")]) }
      folders.append(["key": .string("p:f\(f)"), "title": .string("Folder \(f)"), "folder": true, "children": .array(kids)])
    }
    let clock = ContinuousClock()
    var r: Value = .null
    let d = clock.measure {
      r = h.tabs("importItems", ["batch": "big", "section": "pinned", "folder": ["key": "p:root", "title": "Bookmarks"], "items": .array(folders)])
    }
    let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    print(String(format: "tabs.importItems 1000 tabs / 51 folders: %.1fms", ms))
    #expect(r["tabs"] == 1000 && r["folders"] == 51)
    #expect(ms < 2000)
    let removal = clock.measure { _ = h.tabs("removeImported", ["batch": "big"]) }
    print("tabs.removeImported 1000 tabs:", removal)
    #expect(removal < .seconds(2))
  }
}
