import AppKit
import CordisValue
import Testing

@testable import DenHost
@testable import PluginCores

@MainActor
@Suite(.serialized)
struct SpacesTests {
  @Test func firstRunSeedsThreeThemedSpacesAndPersists() {
    let h = Harness()
    h.startSpaces()
    let list = h.rt.call("spaces", "list").array ?? []
    #expect(list.map { $0.s("name") } == ["Personal", "Work", "Side Project"])
    #expect(list.allSatisfy { ($0["theme"]["colors"].array?.count ?? 0) >= 2 })
    #expect(h.rt.call("spaces", "current")["id"] == list[0]["id"])
    #expect(h.rt.call("ui", "get")["pages"] == 3)
    #expect(h.storage("spaces", "spaces").array?.count == 3)
    // The window theme of the shown page is the current space's gradient.
    #expect(h.rt.window.currentTheme.colors.count == 2)
    let chords = Set((h.rt.call("keys", "list").array ?? []).map { $0.s("chord") })
    for c in ["ctrl+1", "ctrl+9", "cmd+opt+left", "cmd+opt+right"] { #expect(chords.contains(c)) }

    // A second core on the same storage (a restart) sees the same spaces and current space.
    h.rt.call("spaces", "switch", ["id": list[2]["id"], "animated": false])
    let h2 = Harness(root: h.root)
    h2.startSpaces()
    #expect(h2.rt.call("spaces", "list") == h.rt.call("spaces", "list"))
    #expect(h2.rt.call("spaces", "current")["id"] == list[2]["id"])
    #expect(h2.rt.call("ui", "get")["page"] == 2)
  }

  @Test func shortcutsSwipesAndIconsSwitchSpaces() {
    let h = Harness()
    h.startSpaces()
    h.record(["spaces.current"])
    let ids = (h.rt.call("spaces", "list").array ?? []).map { $0.s("id") }

    h.key("cmd+opt+right")
    #expect(h.rt.call("spaces", "current")["id"].string == ids[1])
    #expect(h.rt.call("ui", "get")["page"] == 1)
    h.key("ctrl+3")
    #expect(h.rt.call("spaces", "current")["id"].string == ids[2])
    h.key("cmd+opt+right")  // no wrap past the last space
    #expect(h.rt.call("spaces", "current")["id"].string == ids[2])
    h.key("ctrl+9")  // no ninth space: ignored
    h.action("sidebar", "page", 0)  // a two-finger swipe landed on page 0
    #expect(h.rt.call("spaces", "current")["id"].string == ids[0])
    h.action("spaces.icon:" + ids[1], "click")
    #expect(h.rt.call("spaces", "current")["id"].string == ids[1])

    let dirs = h.events.map { $0.1.s("direction") }
    #expect(dirs == ["next", "jump", "prev", "jump"])
    #expect(h.events.last?.1.s("previous") == ids[0])
  }

  @Test func createUpdateMoveDelete() {
    let h = Harness()
    h.startSpaces()
    h.record(["spaces.changed"])
    let id = h.rt.call("spaces", "create", ["name": "Reading", "icon": "📚"])["id"].string!
    #expect(h.rt.call("ui", "get")["pages"] == 4)
    #expect(h.rt.call("spaces", "update", ["id": .string(id), "theme": ["colors": ["#112233"], "appearance": "dark"]]) == ["ok": true])
    let s = (h.rt.call("spaces", "list").array ?? []).first { $0.s("id") == id }!
    #expect(s["theme"]["colors"] == ["#112233"])
    #expect(s["theme"]["intensity"] == 0.6)  // untouched fields keep their value
    #expect(h.rt.call("spaces", "move", ["id": .string(id), "index": 0]) == ["ok": true])
    #expect(h.rt.call("spaces", "list")[0]["id"].string == id)
    h.rt.call("spaces", "switch", ["id": .string(id)])
    #expect(h.rt.call("spaces", "delete", ["id": .string(id)]) == ["ok": true])
    #expect(h.rt.call("spaces", "list").array?.count == 3)
    #expect(h.rt.call("ui", "get")["pages"] == 3)
    #expect(h.rt.call("spaces", "current")["id"].string != id)
    #expect(h.events.count == 4)
    #expect(h.rt.call("spaces", "delete", ["id": "nope"]).isError)
    #expect(h.rt.call("spaces", "switch", ["direction": "sideways"]).isError)
  }

  @Test func deleteFromTheMenuAsksFirst() {
    let h = Harness()
    h.startSpaces()
    let id = h.rt.call("spaces", "list")[1]["id"].string!
    h.action("spaces.title:" + id, "menu", "delete")
    #expect(h.rt.ui.dialogOpen)
    h.action("spaces.delete:" + id, "button", ["button": "cancel"])
    #expect(!h.rt.ui.dialogOpen)
    #expect(h.rt.call("spaces", "list").array?.count == 3)
    h.action("spaces.title:" + id, "menu", "delete")
    h.action("spaces.delete:" + id, "button", ["button": "delete"])
    #expect(h.rt.call("spaces", "list").array?.count == 2)
  }
}

@MainActor
@Suite(.serialized)
struct SpaceMenuTests {
  func menuIds(_ tree: Value) -> [String] { (tree["menu"].array ?? []).map { $0.s("id") } }

  @Test func titleAndFooterIconShareArcsSpaceMenu() {
    let h = Harness()
    h.startSpaces()
    let expected = ["rename", "icon", "theme", "profile", "", "duplicate", "moveLeft", "moveRight", "", "new", "", "delete"]
    let title = h.tree("sidebar.spaceHeader", 0)
    #expect(menuIds(title) == expected)
    let footer = h.rt.ui.sidebarView.footer.root?.node ?? .null
    let icons = (footer["children"].array ?? []).filter { $0.s("type") == "spaceIcon" }
    #expect(icons.count == 3)
    #expect(icons.allSatisfy { menuIds($0) == expected && $0["reorderable"] == true })
    // First space: can't move left; the last one can't move right.
    let m0 = title["menu"].array ?? []
    #expect(m0[6]["enabled"] == false && m0[7]["enabled"] == true)
    #expect(icons[2]["menu"][7]["enabled"] == false)
    // Profile submenu: Default (checked), then New Profile.
    #expect(m0[3]["items"][0]["id"] == "profile:default" && m0[3]["items"][0]["checked"] == true)
    #expect(m0[3]["items"].array?.last?["id"] == "profile.new")
    #expect(m0[11]["destructive"] == true)
  }

  @Test func renameInPlaceFromMenuAndDoubleClick() {
    let h = Harness()
    h.startSpaces()
    let id = h.spaceIds[0]
    h.action("spaces.title:" + id, "menu", "rename")
    #expect(h.tree("sidebar.spaceHeader", 0)["editing"] == true)
    h.action("spaces.title:" + id, "rename", ["title": "  Home  "])
    #expect(h.rt.call("spaces", "list")[0]["name"] == "Home")
    #expect(h.tree("sidebar.spaceHeader", 0)["editing"].isNull)
    // An empty name keeps the old one; Esc cancels.
    h.action("spaces.title:" + id, "doubleClick")
    h.action("spaces.title:" + id, "rename", ["title": ""])
    #expect(h.rt.call("spaces", "list")[0]["name"] == "Home")
    h.action("spaces.title:" + id, "doubleClick")
    h.action("spaces.title:" + id, "renameCancel")
    #expect(h.tree("sidebar.spaceHeader", 0)["editing"].isNull)
    // Renaming another space from its footer icon switches to it first.
    let other = h.spaceIds[2]
    h.action("spaces.icon:" + other, "menu", "rename")
    #expect(h.rt.call("spaces", "current")["id"].string == other)
    #expect(h.tree("sidebar.spaceHeader", 2)["editing"] == true)
  }

  @Test func changeIconThroughTheIconPicker() {
    let h = Harness()
    h.startSpaces()
    let id = h.spaceIds[1]
    h.action("spaces.icon:" + id, "menu", "icon")
    #expect(h.rt.ui.popoverOpen)
    let tree = h.rt.ui.popover.content?.node ?? .null
    #expect(tree["type"] == "iconPicker" && tree["anchor"].string == "spaces.icon:" + id && tree["selected"] == "sf:briefcase.fill")
    #expect(h.rt.ui.popover.content is IconPickerNode)
    h.action(SpacesCore.iconPickerId, "pick", ["icon": "🚀"])
    #expect(h.rt.call("spaces", "list")[1]["icon"] == "🚀")
    #expect(!h.rt.ui.popoverOpen)
    // Remove: the footer shows a dot. Esc/outside click closes without a change.
    h.action("spaces.title:" + h.spaceIds[0], "menu", "icon")
    h.action(SpacesCore.iconPickerId, "pick", ["icon": ""])
    #expect(h.rt.call("spaces", "list")[0]["icon"] == "")
    h.action("spaces.title:" + h.spaceIds[0], "menu", "icon")
    h.action(SpacesCore.iconPickerId, "dismiss", ["reason": "escape"])
    #expect(!h.rt.ui.popoverOpen)
  }

  @Test func duplicateMoveProfileNewAndThemeFromMenu() {
    let h = Harness()
    h.startSpaces()
    h.record(["spaces.editTheme"])
    let ids = h.spaceIds
    h.action("spaces.title:" + ids[0], "menu", "duplicate")
    let list = h.rt.call("spaces", "list").array ?? []
    #expect(list.count == 4 && list[1]["name"] == "Personal Copy" && list[1]["icon"] == list[0]["icon"] && list[1]["theme"] == list[0]["theme"])
    #expect(h.rt.call("spaces", "current")["id"] == list[1]["id"])
    // Move right, then left, from the menu.
    h.action("spaces.icon:" + ids[0], "menu", "moveRight")
    #expect(h.spaceIds[1] == ids[0])
    h.action("spaces.icon:" + ids[0], "menu", "moveLeft")
    #expect(h.spaceIds[0] == ids[0])
    // Profile: a new one named after the space, then back to Default.
    h.action("spaces.icon:" + ids[1], "menu", "profile.new")
    #expect((h.rt.call("spaces", "list").array ?? []).first { $0.s("id") == ids[1] }?["profile"] == "Work")
    let m = h.tree("sidebar.spaceHeader", 0)["menu"][3]["items"].array ?? []
    #expect(m.map { $0.s("id") }.prefix(2) == ["profile:default", "profile:Work"])
    h.action("spaces.icon:" + ids[1], "menu", "profile:default")
    #expect((h.rt.call("spaces", "list").array ?? []).first { $0.s("id") == ids[1] }?["profile"] == "default")
    // New Space from the menu switches to it; Edit Theme Color asks the theme plugin.
    h.action("spaces.title:" + ids[0], "menu", "new")
    #expect(h.rt.call("spaces", "list").array?.count == 5)
    #expect(h.rt.call("spaces", "current")["id"] == h.rt.call("spaces", "list")[4]["id"])
    h.action("spaces.icon:" + ids[2], "menu", "theme")
    #expect(h.events.last?.1.s("id") == ids[2])
    #expect(h.rt.call("spaces", "current")["id"].string == ids[2])
  }

  @Test func footerDragReorderPersistsThroughSpacesMove() {
    let h = Harness()
    h.startSpaces()
    let ids = h.spaceIds
    h.record(["spaces.changed"])
    h.action("spaces.icon:" + ids[0], "move", ["index": 2])
    #expect(h.spaceIds == [ids[1], ids[2], ids[0]])
    #expect((h.storage("spaces", "spaces").array ?? []).map { $0.s("id") } == [ids[1], ids[2], ids[0]])
    #expect(h.events.count == 1)
    // The current space stays current and its page is shown.
    #expect(h.rt.call("spaces", "current")["id"].string == ids[0])
    #expect(h.rt.call("ui", "get")["page"] == 2)
    // Dropping in the same slot changes nothing.
    h.action("spaces.icon:" + ids[1], "move", ["index": 0])
    #expect(h.events.count == 1)
  }
}
