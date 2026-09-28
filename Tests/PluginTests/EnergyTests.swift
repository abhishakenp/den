import AppKit
import CordisValue
import DenTestSupport
import Foundation
import Testing

@testable import DenHost
@testable import PluginCores

/// The tabs plugin's energy policy (Plugins/tabs/TabsEnergy.swift): battery saver, sites kept
/// active, Unload Space, and blank tabs closing when you switch apps.
@MainActor
@Suite(.serialized, .watchdog)
struct EnergyTests {
  func live(_ h: Harness, _ id: String) -> Bool { h.rt.call("webviews", "get", ["id": .string(id)])["live"] == true }

  /// Seven loaded background tabs, each selected once; the last one is on screen.
  func sevenTabs(_ h: Harness, host: (Int) -> String = { _ in "example.com" }) async -> [String] {
    h.rt.plugins.emit("app.active", ["active": true])
    var ids: [String] = []
    for n in 0..<7 { ids.append(h.tabs("open", ["url": .string("https://\(host(n))/\(n)"), "background": true])["id"].string!) }
    for id in ids { h.tabs("select", ["id": .string(id)]) }
    #expect(ids.allSatisfy { live(h, $0) })
    // Pages that left the screen wait in the window while their snapshot is taken.
    #expect(await Wait.until("snapshots taken", seconds: 15) { ids.dropLast().allSatisfy { h.rt.webviews.record($0)?.webView?.window == nil } })
    return ids
  }

  @Test func batterySaverUnloadsSoonerAndStopsAutoplay() async {
    let h = Harness()
    let core = h.startTabs()
    let ids = await sevenTabs(h)
    let old = Array(ids.prefix(2)), recent = Array(ids[2...5])
    #expect(h.tabs("energy")["saving"] == false && h.tabs("energy")["suspendAfterMs"] == .int(300_000))
    // Two minutes: plugged in, nothing unloads (the default is 5 minutes).
    h.clock += 2 * 60_000
    core.tick()
    #expect(old.allSatisfy { live(h, $0) })
    #expect(h.rt.webviews.autoplayAllowed)
    // Unplugged: one minute is enough, new pages don't autoplay; the 5 most recent stay.
    h.rt.app.powerOverride = PowerState(battery: true, lowPower: false)
    #expect(h.tabs("energy")["saving"] == true && h.tabs("energy")["suspendAfterMs"] == .int(60_000))
    #expect(!h.rt.webviews.autoplayAllowed)
    core.tick()
    for id in old { #expect(await h.waitUnloaded(id)) }
    #expect(recent.allSatisfy { live(h, $0) })
    // Off: plugged-in rules again, even in Low Power Mode.
    h.rt.app.powerOverride = PowerState(battery: false, lowPower: true)
    #expect(h.tabs("energy")["saving"] == true)
    #expect(h.tabs("settings", ["batterySaver": false])["batterySaver"] == false)
    #expect(h.tabs("energy")["saving"] == false && h.rt.webviews.autoplayAllowed)
    #expect(h.storage("tabs", "energy")["batterySaver"] == false)
    #expect(h.rt.call("settings", "get", ["id": "tabs", "key": "batterySaver"]) == false)
    h.rt.app.powerOverride = nil
  }

  @Test func keptActiveSitesNeverUnloadWhenIdle() async {
    let h = Harness()
    let core = h.startTabs()
    let ids = await sevenTabs(h) { $0 == 0 ? "example.org" : "example.com" }
    let kept = ids[0], other = ids[1]
    // The tab menu toggles the site; the menu shows it checked, the setting lists it.
    h.action(kept, "menu", "keepActive")
    #expect(h.tabs("keepActive") == ["example.org"])
    #expect(h.storage("tabs", "energy")["keepActive"] == ["example.org"])
    #expect(h.tabs("menu", ["id": .string(kept)]).array?.first { $0.s("id") == "keepActive" }?["checked"] == true)
    // Rows carry no menu; a right-click builds it (ui.menu).
    #expect(h.tree("sidebar.today", 0)["children"].array?.first { $0.s("id") == kept }?["menu"] == .null)
    h.action(kept, "contextMenu")
    #expect(h.rt.ui.lastMenu?.items.first { $0.title == "Keep Site Active" }?.state == .on)
    h.clock += 6 * 60_000
    core.tick()
    #expect(await h.waitUnloaded(other))
    #expect(live(h, kept))
    // Removing it from Settings lets it unload again.
    h.rt.plugins.emit("settings.action", ["id": "tabs", "key": "keepActive", "button": "remove", "item": "example.org"])
    #expect(h.tabs("keepActive") == [])
    core.tick()
    #expect(await h.waitUnloaded(kept))
  }

  @Test func unloadSpaceKeepsOnlyTheTabOnScreen() async {
    let h = Harness()
    _ = h.startTabs()
    let ids = await sevenTabs(h)
    let shown = ids.last!
    h.key("cmd+ctrl+u")
    for id in ids.dropLast() { #expect(await h.waitUnloaded(id)) }
    #expect(live(h, shown))
    #expect(!h.rt.ui.toasts.isEmpty)
    // Again: nothing left to unload. The space's menu offers it too, with its shortcut.
    #expect(h.tabs("unloadSpace")["unloaded"] == 0)
    let menu = h.tree("sidebar.spaceHeader", 0)["menu"].array ?? []
    #expect(menu.first { $0.s("id") == "unload" }?.s("key") == "cmd+ctrl+u")
  }

  @Test func blankTabsCloseWhenYouSwitchApps() async {
    let h = Harness()
    _ = h.startTabs()
    h.rt.plugins.emit("app.active", ["active": true])
    let blank = h.tabs("open", ["url": "about:blank", "background": true])["id"].string!
    let page = h.tabs("open", ["url": "https://example.com/", "background": false])["id"].string!
    #expect(h.selected == page)
    let archived = h.tabs("archive").array?.count ?? 0
    // You leave den: the blank tab left behind closes, with no Archive entry.
    h.rt.plugins.emit("app.active", ["active": false])
    #expect(!h.ids("today").contains(blank))
    #expect(h.ids("today").contains(page))
    #expect((h.tabs("archive").array?.count ?? 0) == archived)
    #expect(h.rt.call("webviews", "get", ["id": .string(blank)]).isErr)
    // A blank tab on screen stays.
    h.rt.plugins.emit("app.active", ["active": true])
    let front = h.tabs("open", ["url": "about:blank", "background": false])["id"].string!
    h.rt.plugins.emit("app.active", ["active": false])
    #expect(h.ids("today").contains(front))
  }
}
