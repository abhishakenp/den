import AppKit
import CordisValue
import DenTestSupport
import Foundation
import Testing

@testable import DenHost
@testable import PluginCores

/// Library ▸ Downloads (the `tabs` plugin over the host `downloads` service), ⌥⌘L, the download
/// toasts, the auto-archive setting and the sidebar's download indicator (`spaces`).
@MainActor
@Suite(.serialized, .watchdog)
struct DownloadsLibraryTests {
  typealias Item = DownloadsService.Item

  func footerButton(_ h: Harness) -> Value? {
    (h.rt.ui.sidebarView.footer.root?.node["children"].array ?? []).first { $0.s("id") == "spaces.downloads" }
  }

  @Test func sizesAndTimeLeftReadLikeFinder() {
    #expect(TabsCore.bytes(812) == "812 bytes" && TabsCore.bytes(1) == "1 byte")
    #expect(TabsCore.bytes(4_210) == "4.2 KB" && TabsCore.bytes(42_000_000) == "42 MB" && TabsCore.bytes(1_320_000_000) == "1.3 GB")
    #expect(TabsCore.bytes(120_400_000) == "120 MB")
    #expect(TabsCore.progressText(0, 100, rate: 0) == "Starting…")
    #expect(TabsCore.progressText(18_400_000, 42_000_000, rate: 3_100_000) == "18.4 MB of 42 MB · 7 s left")
    #expect(TabsCore.progressText(5_000, -1, rate: 10) == "5 KB")
    #expect(TabsCore.timeLeft(125) == "2 min left" && TabsCore.timeLeft(3_900) == "1 h 5 min left")
  }

  @Test func downloadsSectionShortcutsActionsAndIndicator() throws {
    let h = Harness()
    h.startTabs()
    let now = Double(h.clock)
    let dir = h.root.appendingPathComponent("dl", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let photo = dir.appendingPathComponent("photo.jpg")
    FileManager.default.createFile(atPath: photo.path, contents: Data(repeating: 1, count: 2_300))
    var running = Item(id: "d4", url: "https://a.test/big.dmg", name: "big.dmg", path: dir.appendingPathComponent("big.dmg").path, state: "downloading",
                       received: 18_400_000, total: 42_000_000, started: now - 5000)
    running.rate = 3_100_000
    var done = Item(id: "d3", url: "https://a.test/photo.jpg", name: "photo.jpg", path: photo.path, state: "done", received: 2_300, total: 2_300,
                    started: now - 60_000, finished: now - 60_000)
    done.unseen = true
    let failed = Item(id: "d2", url: "https://a.test/x.zip", name: "x.zip", path: "", state: "failed", started: now - 70_000, finished: now - 70_000,
                      error: "Network connection lost")
    let old = Item(id: "d1", url: "https://a.test/old.txt", name: "old.txt", path: dir.appendingPathComponent("gone.txt").path, state: "done",
                   received: 10, total: 10, started: now - 3 * 86_400_000, finished: now - 3 * 86_400_000)
    h.rt.downloads.seed([running, done, failed, old])

    // The footer shows a ring while something downloads (2% steps), with its shortcut in the tooltip.
    let ring = try #require(footerButton(h))
    #expect(ring["progress"] == 0.42 && ring["tooltip"] == "Downloads (⌥⌘L)")

    // ⌥⌘L opens Library ▸ Downloads; the old finished one moves under Archived (24 h default).
    h.key("cmd+opt+l")
    let lib = h.rt.ui.library
    #expect(h.rt.call("ui", "get")["overlays"] == ["overlay.library"])
    #expect(lib.node["section"] == "downloads" && lib.node["title"] == "Downloads" && lib.tabs.map(\.label.stringValue) == ["Archive", "Downloads"])
    #expect(lib.rows.map(\.itemId) == ["d4", "d3", "d2", "d1"])
    #expect(lib.headers.first?.stringValue == "In Progress" && lib.headers.last?.stringValue == "Archived")
    #expect(lib.rows[0].subtitle.stringValue == "18.4 MB of 42 MB · 7 s left" && lib.rows[0].progress == Double(18_400_000) / 42_000_000)
    #expect(lib.rows[0].buttonSpecs.map { $0.s("id") } == ["pause", "cancel"])
    #expect(lib.rows[1].file == photo.path && lib.rows[1].subtitle.stringValue.hasPrefix("2.3 KB · "))
    #expect(lib.rows[2].subtitle.stringValue.hasPrefix("Failed: Network connection lost") && lib.rows[2].buttonSpecs.first?.s("id") == "retry")
    #expect(lib.rows[3].subtitle.stringValue.hasPrefix("Moved or deleted") && lib.rows[3].alphaValue < 1)
    #expect(h.rt.downloads.items.first { $0.id == "d1" }?.archived == true)
    // Looking at the list clears "new".
    #expect(h.rt.call("downloads", "summary")["unseen"] == 0)

    // Row buttons call the service; Remove takes the row away (the file stays).
    h.action(TabsCore.libraryId, "button", ["item": "d3", "button": "remove"])
    #expect(lib.rows.map(\.itemId) == ["d4", "d2", "d1"] && FileManager.default.fileExists(atPath: photo.path))
    // Clear List keeps the running download.
    h.action(TabsCore.libraryId, "clear")
    #expect(lib.rows.map(\.itemId) == ["d4"])

    // The Archive tab, ⌘Y from Downloads switches (doesn't close), ⌥⌘L again closes.
    h.action(TabsCore.libraryId, "section", ["id": "archive"])
    #expect(lib.node["section"] == "archive" && lib.node["title"] == "Archive")
    h.key("cmd+opt+l")
    #expect(lib.node["section"] == "downloads")
    h.key("cmd+y")
    #expect(lib.node["section"] == "archive" && h.rt.call("ui", "get")["overlays"] == ["overlay.library"])
    h.key("cmd+opt+l")
    h.key("cmd+opt+l")
    #expect(h.rt.call("ui", "get")["overlays"] == [])
    // The command bar's Downloads destination (`downloads.open`) and the footer button open it too.
    h.rt.call("downloads", "open")
    #expect(lib.node["section"] == "downloads" && h.rt.call("ui", "get")["overlays"] == ["overlay.library"])
    h.action(TabsCore.libraryId, "dismiss")
    h.action("spaces.downloads", "click")
    #expect(h.rt.call("ui", "get")["overlays"] == ["overlay.library"])
    h.action(TabsCore.libraryId, "dismiss")

    // Nothing running and nothing new: no indicator. A finished, unseen one: a dot.
    h.rt.downloads.seed([])
    #expect(footerButton(h) == nil)
    var fresh = done
    fresh.unseen = true
    h.rt.downloads.seed([fresh])
    #expect(footerButton(h)?["dot"] == true && footerButton(h)?["progress"].isNull == true)

    // Toasts say what's happening, with a way to it.
    h.rt.host.emit("downloads.started", ["id": "d3", "name": "photo.jpg", "webview": ""])
    #expect(h.rt.ui.toasts.last?.label.stringValue == "Downloading “photo.jpg”" && h.rt.ui.toasts.last?.actionLabel.stringValue == "Show")
    h.rt.host.emit("downloads.finished", ["id": "d3", "name": "photo.jpg", "ok": true])
    #expect(h.rt.ui.toasts.last?.label.stringValue == "Downloaded “photo.jpg”" && h.rt.ui.toasts.last?.actionLabel.stringValue == "Show in Finder")

    // Settings ▸ Tabs ▸ Downloads: Never stops the archiving.
    #expect(h.rt.call("settings", "get", ["id": "tabs.downloads", "key": "archiveAfterMs"]) == .int(24 * 3_600_000))
    h.rt.call("settings", "set", ["id": "tabs.downloads", "key": "archiveAfterMs", "value": 0])
    var older = old
    older.state = "done"
    h.rt.downloads.seed([older])
    h.rt.call("downloads", "open")
    #expect(h.rt.downloads.items.first?.archived == false && lib.headers.first?.stringValue != "Archived")
  }
}
