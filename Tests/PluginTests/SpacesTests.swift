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
