import AppKit
import CordisValue
import DenTestSupport
import Testing

@testable import DenHost
@testable import PluginCores

/// The `tips` plugin (docs/guide/_in-app-tips.md): the tour card from the second launch, the
/// import card only with an importer, one-time tips with their limits, and the global switch.
@MainActor
@Suite(.serialized, .watchdog)
struct TipsTests {
  /// A fake `commands` service recording what was registered.
  final class Commands { var ids: [String] = []; var titles: [String: String] = [:] }

  func start(_ h: Harness, _ cmds: Commands = Commands()) -> TipsCore {
    h.rt.plugins.provide("commands") { m, a in
      if m == "register" { cmds.ids.append(a.s("id")); cmds.titles[a.s("id")] = a.s("title") }
      return ["ok": true]
    }
    let core = TipsCore(env: h.env)
    core.start()
    h.fireTimers()  // the delayed start (Settings row, commands, cards)
    return core
  }

  func notice(_ h: Harness) -> Value { h.rt.ui.sidebarView.notice.root?.node ?? .null }
  func toastTexts(_ h: Harness) -> [String] { h.rt.ui.toasts.filter { $0.toastId == TipsCore.toastId }.map { $0.label.stringValue } }
  /// Moves the fake clock past the quiet first minute.
  func settle(_ h: Harness) { h.clock += TipsCore.quietStartMs + 1000 }

  @Test func firstLaunchIsQuiet() {
    let h = Harness()
    let cmds = Commands()
    let core = start(h, cmds)
    #expect(core.launches == 1)
    #expect(notice(h).isNull)  // no tour on the first launch, no importer: no card
    #expect(h.rt.ui.sidebarView.notice.isHidden)
    #expect(cmds.ids.contains(TipsCore.toggleCommand) && cmds.ids.contains(TipsCore.tourCommand))
    #expect(cmds.titles[TipsCore.toggleCommand] == "Don't Show Tips")
    #expect(h.rt.settings.entries["tips"]?.section == "general")
  }

  @Test func tourCardFromTheSecondLaunchAndNeverAfterDismissal() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("den-tips-\(UUID())")
    _ = start(Harness(root: root))
    let h2 = Harness(root: root)
    let core = start(h2)
    #expect(core.launches == 2)
    #expect(notice(h2)["id"] == "tips.card")
    h2.rt.ui.sidebarView.layoutSubtreeIfNeeded()
    #expect(!h2.rt.ui.sidebarView.notice.isHidden && h2.rt.ui.sidebarView.notice.frame.height > 40)
    // The pager makes room for the card above the footer.
    #expect(h2.rt.ui.sidebarView.pager.frame.maxY <= h2.rt.ui.sidebarView.notice.frame.minY)
    h2.action("tips.tour.close", "click")
    #expect(notice(h2).isNull)
    #expect(h2.storage("tips", "tour") == "dismissed")
    let h3 = Harness(root: root)
    _ = start(h3)
    #expect(notice(h3).isNull)
  }

  @Test func tourStepsAdvanceOnNextAndOnTheAction() {
    let h = Harness()
    let core = start(h)
    h.action("tips.tour.start", "click")  // what the card's Start does (and the command)
    #expect(core.step == 0)
    h.rt.plugins.emit("tabs.key.pin")  // step 1 completes when a tab is pinned
    #expect(core.step == 1)
    h.action("tips.tour.next", "click")
    #expect(core.step == 2)
    h.rt.plugins.emit("spaces.current", ["id": "b"])
    #expect(core.step == 3)
    h.rt.plugins.emit("peek.opened", ["id": "p"])
    #expect(core.step == 4)
    #expect(TipsCore.steps.count <= 5)
    h.action("tips.tour.next", "click")  // Done
    #expect(core.step == nil && notice(h).isNull)
    #expect(h.storage("tips", "tour") == "done")
    // No tips while a tour runs.
    h.rt.plugins.emit("commands.run", ["id": .string(TipsCore.tourCommand)])
    settle(h)
    h.rt.plugins.emit("tabs.key.close")
    #expect(toastTexts(h).isEmpty)
    h.action("tips.tour.skip", "click")
    #expect(core.step == nil && h.storage("tips", "tour") == "done")
  }

  @Test func aTipShowsOnceAfterTheQuietMinute() {
    let h = Harness()
    _ = start(h)
    h.rt.plugins.emit("tabs.key.close")  // ⌘W in the first minute: nothing
    #expect(toastTexts(h).isEmpty)
    #expect(h.storage("tips", "shown.reopenClosed").isNull)
    settle(h)
    h.rt.plugins.emit("tabs.key.close")
    #expect(toastTexts(h) == ["Closed tabs go to the Library. ⇧⌘T brings the last one back."])
    #expect(h.storage("tips", "shown.reopenClosed") == true)
    // Doing the thing takes it off the screen.
    h.rt.plugins.emit("tabs.key.reopen")
    #expect(toastTexts(h).isEmpty)
    // Never again, on this launch or the next.
    h.clock += TipsCore.minGapMs * 2
    h.rt.plugins.emit("tabs.key.close")
    #expect(toastTexts(h).isEmpty)
  }

  @Test func aRetiredTipNeverShows() {
    let h = Harness()
    _ = start(h)
    settle(h)
    h.rt.plugins.emit("window.sidebarReveal", ["revealed": true])  // already knows the edge reveal
    h.rt.plugins.emit("window.sidebarVisibility", ["hidden": true])
    #expect(toastTexts(h).isEmpty)
    #expect(h.storage("tips", "retired.edgeReveal") == true)
    // A plugin setting the width is neither a drag nor a reset.
    h.rt.plugins.emit("window.sidebarResized", ["width": 240, "by": "set"])
    #expect(toastTexts(h).isEmpty)
    h.rt.plugins.emit("window.sidebarResized", ["width": 260, "by": "drag"])
    #expect(toastTexts(h) == ["Double-click the sidebar edge to reset its width."])
  }

  @Test func rateLimits() {
    let h = Harness()
    let core = start(h)
    settle(h)
    h.rt.plugins.emit("tabs.key.close")
    #expect(core.showing == "reopenClosed")
    h.fireTimers()  // the tip's 6 s are up
    #expect(core.showing == nil)
    // Within 10 minutes: held back, and it can trigger again later.
    h.clock += 60_000
    h.rt.plugins.emit("window.sidebarVisibility", ["hidden": true])
    #expect(core.showing == nil && core.blocked("edgeReveal") == "gap")
    h.clock += TipsCore.minGapMs
    h.rt.plugins.emit("window.sidebarVisibility", ["hidden": true])
    #expect(core.showing == "edgeReveal")
    h.fireTimers()
    h.clock += TipsCore.minGapMs
    h.rt.plugins.emit("window.sidebarResized", ["by": "drag"])
    #expect(core.showing == "resetWidth")
    h.fireTimers()
    // Three today: the fourth waits for tomorrow (unless the day just rolled over).
    h.clock += TipsCore.minGapMs
    if h.clock / TipsCore.dayMs == core.day {
      #expect(core.blocked("copyMarkdown") == "day")
    }
    h.clock += TipsCore.dayMs
    #expect(core.blocked("copyMarkdown") == nil)
    // Counted triggers: ⇧⌘C shows its tip on the third use.
    h.rt.plugins.emit("tabs.key.copy")
    h.rt.plugins.emit("tabs.key.copy")
    #expect(core.showing == nil)
    h.rt.plugins.emit("tabs.key.copy")
    #expect(core.showing == "copyMarkdown")
  }

  @Test func neverOverAModal() {
    let h = Harness()
    let core = start(h)
    settle(h)
    h.rt.call("ui", "set", ["slot": "dialog", "tree": ["type": "dialog", "id": "d", "title": "Hi", "buttons": [["id": "ok", "title": "OK", "style": "default"]]]])
    h.rt.plugins.emit("tabs.key.close")
    #expect(core.showing == nil && core.blocked("reopenClosed") == "modal")
  }

  @Test func dontShowTipsTurnsEverythingOff() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("den-tips-\(UUID())")
    _ = start(Harness(root: root))
    let h = Harness(root: root)
    let cmds = Commands()
    let core = start(h, cmds)
    #expect(!notice(h).isNull)  // the tour card
    settle(h)
    h.rt.plugins.emit("tabs.key.close")
    #expect(toastTexts(h).count == 1)
    h.action(TipsCore.toastId, "toast")  // the toast's "Don't show tips"
    #expect(!core.enabled && notice(h).isNull)
    #expect(h.storage("tips", "enabled") == false)
    #expect(h.rt.call("settings", "get", ["id": "tips", "key": "enabled"]) == false)
    #expect(cmds.titles[TipsCore.toggleCommand] == "Show Tips")
    h.clock += TipsCore.dayMs
    h.rt.plugins.emit("window.sidebarVisibility", ["hidden": true])
    #expect(core.showing == nil)
    // Settings ▸ General ▸ Show tips brings it back.
    h.rt.call("settings", "set", ["id": "tips", "key": "enabled", "value": true])
    #expect(core.enabled && !notice(h).isNull)
    // The command bar's toggle.
    h.rt.plugins.emit("commands.run", ["id": .string(TipsCore.toggleCommand)])
    #expect(!core.enabled)
  }

  @Test func importCardOnlyWithAnImporter() {
    let h = Harness()
    var ran: [Value] = []
    h.rt.plugins.provide("importer") { m, a in
      if m == "sources" { return [["id": "arc", "name": "Arc"]] }
      if m == "run" { ran.append(a) }
      return ["ok": true]
    }
    _ = start(h)
    let card = notice(h)
    #expect(card["id"] == "tips.card")
    let button = card["children"][2]
    #expect(button["title"] == "Import from Arc" && button["value"] == "arc")
    h.action("tips.import.run", "click", "arc")
    #expect(ran == [["source": "arc"]])
    #expect(notice(h).isNull && h.storage("tips", "import") == "done")
  }

  @Test func noticeSlotIsGeneric() {
    let h = Harness()
    let sv = h.rt.ui.sidebarView
    #expect(sv.notice.isHidden)
    let before = sv.pager.frame.height
    h.rt.call("ui", "set", ["slot": "sidebar.notice", "tree": ["type": "stack", "id": "n", "padding": 10, "children": [["type": "label", "text": "Hello"]]]])
    sv.layoutSubtreeIfNeeded()
    #expect(!sv.notice.isHidden && sv.notice.frame.height == 10 + 17 + 10)
    #expect(sv.pager.frame.height < before)
    h.rt.call("ui", "set", ["slot": "sidebar.notice", "tree": nil])
    sv.layoutSubtreeIfNeeded()
    #expect(sv.notice.isHidden && sv.pager.frame.height == before)
  }
}
