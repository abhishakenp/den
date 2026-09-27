import AppKit
import CordisValue
import Foundation
import Testing

@testable import DenHost
@testable import PluginCores

/// The command bar launcher searches den's real Settings (`settings.list` with each section's
/// schema) and flips a toggle through `settings.set` with a dotted key.
@MainActor
@Suite(.serialized)
struct SettingsLauncherTests {
  @Test func listCarriesSchemaAndDottedKeysSetValues() {
    let h = Harness()
    h.startPeek()
    let quit = QuitCore(env: h.env)
    quit.start()
    let list = h.rt.call("settings", "list").array ?? []
    let tabs = list.first { $0.s("id") == "tabs" }
    let keys = (tabs?["schema"].array ?? []).map { $0.s("key") }
    #expect(keys.contains("tabs.archiveAfterMs") && keys.contains("peek.littleArc"))
    #expect(tabs?["schema"].array?.first { $0.s("key") == "peek.littleArc" }?["value"] == false)
    // A dotted key sets it, and the plugin applies it live.
    #expect(h.rt.call("settings", "set", ["key": "peek.littleArc", "value": true]) == .ok)
    #expect(h.peek("settings")["littleArc"] == true)
    #expect(h.rt.call("settings", "set", ["key": "quit.warn", "value": false]) == .ok)
    #expect(!quit.warn)
    // The launcher's `open {id}` for a group lands on its section.
    h.rt.call("settings", "open", ["id": "peek"])
    #expect(h.rt.settings.window?.section == "tabs")
    h.rt.settings.window?.window.close()
  }
}
