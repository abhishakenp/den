import AppKit
import CordisValue
import DenTestSupport
import Testing

@testable import DenHost
@testable import PluginCores

/// Emoji icons for tabs and folders (Arc): the context menu, the picker, the rename shortcut,
/// undo and persistence.
@MainActor
@Suite(.serialized, .watchdog)
struct TabIconTests {
  func todayRow(_ h: Harness, _ id: String) -> Value {
    h.tree("sidebar.today", 0)["children"].array?.first { $0["id"].string == id } ?? .null
  }
  func pinnedNode(_ h: Harness, _ id: String) -> Value {
    h.tree("sidebar.pinned", 0)["children"].array?.first { $0["id"].string == id } ?? .null
  }
  var pickerTree: (Harness) -> Value = { $0.rt.ui.popover.content?.node ?? .null }

  @Test func changeIconFromTheTabMenu() {
    let h = Harness()
    h.startTabs()
    let t = h.ids("today")[0]
    let favicon = todayRow(h, t)["icon"]
    let menu = todayRow(h, t)["menu"].array ?? []
    #expect(menu.contains { $0["id"] == "changeIcon" && $0["title"] == "Change Icon…" })
    #expect(!menu.contains { $0["id"] == "removeIcon" })

    h.action(t, "menu", "changeIcon")
    #expect(h.rt.ui.popoverOpen)
    #expect(h.rt.ui.popover.content is IconPickerNode)
    let p = pickerTree(h)
    #expect(p["type"] == "iconPicker" && p["id"] == "tabs.iconPicker" && p["anchor"].string == t && p["title"] == "Tab Icon" && p["selected"] == "")

    h.action(TabsCore.iconPickerId, "pick", ["icon": "🚀"])
    #expect(!h.rt.ui.popoverOpen)
    #expect(todayRow(h, t)["icon"] == "🚀")
    #expect(h.tabs("list")["today"][0]["icon"] == "🚀")
    #expect((todayRow(h, t)["menu"].array ?? []).contains { $0["id"] == "removeIcon" })

    // ⌃Z brings the favicon back; Remove Icon does too.
    h.key("ctrl+z")
    #expect(todayRow(h, t)["icon"] == favicon)
    h.tabs("setIcon", ["id": .string(t), "icon": "⭐️"])
    #expect(todayRow(h, t)["icon"] == "⭐️")
    h.action(t, "menu", "removeIcon")
    #expect(todayRow(h, t)["icon"] == favicon)

    // Esc / a click outside closes the picker without a change.
    h.action(t, "menu", "changeIcon")
    h.action(TabsCore.iconPickerId, "dismiss", ["reason": "escape"])
    #expect(!h.rt.ui.popoverOpen)
    #expect(todayRow(h, t)["icon"] == favicon)
  }

  @Test func favoriteTilesAndHoverCardsShowTheIcon() {
    let h = Harness()
    h.startTabs()
    let f = h.ids("favorites")[0]
    let tile = { h.tree("sidebar.favorites", 0)["children"].array?.first { $0["id"].string == f } ?? .null }
    #expect((tile()["menu"].array ?? []).contains { $0["id"] == "changeIcon" })
    h.tabs("setIcon", ["id": .string(f), "icon": "🎵"])
    #expect(tile()["icon"] == "🎵")
    // The hover card gets the same icon.
    var shown: Value = .null
    h.rt.plugins.provide("previews") { m, a in
      if m == "show" { shown = a }
      return ["ok": true]
    }
    h.action(f, "hover")
    #expect(shown["icon"] == "🎵")
  }

  @Test func folderIcons() {
    let h = Harness()
    h.startTabs()
    let folder = h.tabs("list")["pinned"].array!.first { $0["folder"] == true }!["id"].string!
    #expect(pinnedNode(h, folder)["icon"] == "sf:folder")
    let menu = pinnedNode(h, folder)["menu"].array ?? []
    #expect(menu.contains { $0["id"] == "changeIcon" })
    h.action(folder, "menu", "changeIcon")
    #expect(pickerTree(h)["anchor"].string == folder && pickerTree(h)["title"] == "Folder Icon")
    h.action(TabsCore.iconPickerId, "pick", ["icon": "📚"])
    #expect(pinnedNode(h, folder)["icon"] == "📚")
    #expect(h.tabs("list")["pinned"].array!.first { $0["id"].string == folder }?["icon"] == "📚")
    h.action(folder, "menu", "removeIcon")
    #expect(pinnedNode(h, folder)["icon"] == "sf:folder")
  }

  /// Clicking the row's icon while renaming opens the picker (the host sends `pickIcon`).
  @Test func iconClickWhileRenaming() async throws {
    let h = Harness()
    h.startTabs()
    let t = h.ids("today")[0]
    h.action(t, "doubleClick")
    let row = try #require(HostScenarios.find(t, in: h.rt.ui.sidebarView) as? TabRowNode)
    _ = await Wait.until("the rename editor") { row.rename.active }
    #expect(row.rename.active)
    let c = NSPoint(x: row.icon.frame.midX, y: row.icon.frame.midY)
    #expect(row.rename.iconDown(row.icon, at: c))
    #expect(row.rename.iconUp())
    #expect(h.rt.ui.popoverOpen && pickerTree(h)["anchor"].string == t)
  }

  /// Typing an emoji first while renaming makes it the icon.
  @Test func emojiTypedFirstBecomesTheIcon() {
    let h = Harness()
    let core = h.startTabs()
    let t = h.ids("today")[0]
    core.beginRename(t)
    h.action(t, "rename", ["title": "🔥 Hot deals"])
    #expect(todayRow(h, t)["icon"] == "🔥" && todayRow(h, t)["title"] == "Hot deals")
    let title = todayRow(h, t)["title"]
    core.beginRename(t)
    h.action(t, "rename", ["title": "🧪"])
    #expect(todayRow(h, t)["icon"] == "🧪" && todayRow(h, t)["title"] == title)
    // One undo step each.
    h.key("ctrl+z")
    #expect(todayRow(h, t)["icon"] == "🔥")
    // Folders too.
    let folder = h.tabs("list")["pinned"].array!.first { $0["folder"] == true }!["id"].string!
    core.beginRename(folder)
    h.action(folder, "rename", ["title": "📖 Books"])
    #expect(pinnedNode(h, folder)["icon"] == "📖" && pinnedNode(h, folder)["title"] == "Books")
  }

  @Test func iconsSurviveRestart() {
    let h = Harness()
    let core = h.startTabs()
    let t = h.ids("today")[0]
    let folder = h.tabs("list")["pinned"].array!.first { $0["folder"] == true }!["id"].string!
    h.tabs("setIcon", ["id": .string(t), "icon": "🚀"])
    h.tabs("setIcon", ["id": .string(folder), "icon": "sf:star.fill"])
    core.stop()
    let h2 = Harness(root: h.root)
    h2.startTabs()
    #expect(h2.tabs("list")["today"][0]["icon"] == "🚀")
    #expect(pinnedNode(h2, folder)["icon"] == "sf:star.fill")
  }

  @Test func leadingEmoji() {
    func split(_ s: String) -> [String]? { TabsCore.leadingEmoji(s).map { [$0.0, $0.1] } }
    #expect(split("🚀 Launch") == ["🚀", "Launch"])
    #expect(split("🚀Launch") == ["🚀", "Launch"])
    #expect(split("⭐️  Stars ") == ["⭐️", "Stars"])
    #expect(split("☕") == ["☕", ""])
    #expect(split("👩🏽‍💻 Code") == ["👩🏽‍💻", "Code"])
    #expect(split("👨‍👩‍👧‍👦 Family") == ["👨‍👩‍👧‍👦", "Family"])
    #expect(split("🇯🇵🇫🇷 Trips") == ["🇯🇵", "🇫🇷 Trips"])
    #expect(split("1️⃣ First") == ["1️⃣", "First"])
    #expect(split("❤️") == ["❤️", ""])
    #expect(split("Launch 🚀") == nil)
    #expect(split("1 Password") == nil)
    #expect(split("© 2026") == nil)
    #expect(split("Éclair") == nil)
    #expect(split("") == nil)
  }
}
