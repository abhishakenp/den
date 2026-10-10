import AppKit
import CordisValue
import DenTestSupport
import Testing

@testable import DenHost
@testable import PluginCores

@MainActor
@Suite(.serialized, .watchdog)
struct UpdatesTests {
  /// A fake host `updates` service that records calls.
  final class FakeUpdates {
    var info: Value = ["version": "0.1.0", "build": 10, "commit": "aaaaaaa1", "hostAPI": 5, "crashed": [], "sparkle": false, "onDiskCommit": "aaaaaaa1"]
    var state: Value = .null
    var plugins: Value = [["id": "tabs", "layer": "bundle", "sha256": "old"], ["id": "theme", "layer": "bundle", "sha256": "same"]]
    var calls: [(String, Value)] = []
    func handle(_ m: String, _ a: Value) -> Value {
      calls.append((m, a))
      switch m {
      case "info": return info
      case "state": return state
      case "plugins": return plugins
      default: return ["ok": true]
      }
    }
    func called(_ m: String) -> [Value] { calls.filter { $0.0 == m }.map(\.1) }
  }

  func setup(_ fake: FakeUpdates) -> (Harness, UpdatesCore, [String]) {
    let h = Harness()
    h.rt.plugins.provide("updates") { m, a in fake.handle(m, a) }
    var registered: [String] = []
    h.rt.plugins.provide("commands") { m, a in
      if m == "register" { registered.append(a.s("id")) }
      return ["ok": true]
    }
    let core = UpdatesCore(env: h.env)
    core.start()
    return (h, core, registered)
  }

  func toastTexts(_ h: Harness) -> [String] { h.rt.ui.toasts.map { $0.label.stringValue + "|" + $0.actionLabel.stringValue } }

  /// Plugin crash and failure notices: the host emits what happened, this plugin words the toast
  /// (thin-host step 2; the strings moved here unchanged from the host).
  @Test func pluginCrashAndFailureNotices() {
    let fake = FakeUpdates()
    let (h, _, _) = setup(fake)
    let before = h.rt.ui.toasts.count
    h.rt.host.emit("plugins.crashed", ["ids": ["peek"]])
    h.rt.host.emit("plugins.crashed", ["ids": ["peek", "tabs"]])
    h.rt.host.emit("plugins.failed", ["id": "x", "stage": "load", "reason": "bad image"])
    h.rt.host.emit("plugins.failed", ["id": "y", "stage": "build", "reason": "error: oops", "log": "~/.den/logs/build-y.log"])
    h.rt.host.emit("plugins.failed", ["stage": "toolchain", "reason": "noEmbeddedSwift"])
    h.rt.host.emit("plugins.failed", ["stage": "toolchain", "reason": "noCordisBuild"])
    let texts = h.rt.ui.toasts.dropFirst(before).map { $0.label.stringValue }
    #expect(texts == [
      "The “peek” plugin crashed den and was turned off",
      "Plugins “peek”, “tabs” crashed den and were turned off",
      "Plugin “x” didn't load: bad image",
      "Plugin “y” didn't build: error: oops (~/.den/logs/build-y.log)",
      "Source plugins need a Swift toolchain with Embedded Swift (swift.org, or set CORDIS_TOOLCHAIN)",
      "den can't find cordis-build (its bundled copy is missing)",
    ])
    #expect(h.rt.ui.toasts.last?.icon.spec == "sf:puzzlepiece.extension")
  }

  @Test func sparkleUpdateDownloadsThenWaitsForTheRestart() {
    let fake = FakeUpdates()
    fake.info = fake.info.with("sparkle", true)
    let (h, core, registered) = setup(fake)
    #expect(registered.contains("den.checkForUpdates"))
    #expect(fake.called("sparkleConfigure").first?["channel"] == "stable")
    h.rt.plugins.emit("updates.sparkle", ["phase": "found", "version": "0.1.1"])
    #expect(fake.called("sparkleReply").map { $0.s("choice") } == ["install"])  // download
    h.rt.plugins.emit("updates.sparkle", ["phase": "ready"])
    #expect(core.pendingRestart == "sparkle" && toastTexts(h) == ["den updated — restart to apply|Restart"])

    // A Sparkle update relaunches by answering Sparkle, not the app-relaunch path.
    var relaunched: [Bool] = []
    h.rt.app.relaunchHandler = { relaunched.append($0) }
    // Tests run inactive = "not frontmost". The first tick notes it, the next one 60 s later relaunches.
    core.policyTick()
    #expect(fake.called("sparkleReply").count == 1)
    h.clock += 61_000
    core.policyTick()
    #expect(relaunched.isEmpty && fake.called("sparkleReply").count == 2)

    // The toast's Restart button answers Sparkle again (its installer does the relaunch).
    h.action("updates.toast", "toast")
    #expect(fake.called("sparkleReply").map { $0.s("choice") } == ["install", "install", "install"])
  }

  @Test func manualCheckFetchesManifestAndSparkleWithoutKickingAnyUpdater() {
    let fake = FakeUpdates()
    fake.info = fake.info.with("sparkle", true)
    let (h, core, _) = setup(fake)
    #expect(core.pendingRestart.isEmpty && h.rt.ui.toasts.isEmpty)
    h.rt.plugins.emit("commands.run", ["id": "den.checkForUpdates"])
    #expect(fake.called("fetch").count == 1)
    #expect(fake.called("sparkleCheck").count == 1)
    // Sparkle says nothing new: the manual check toast reports the plugin manifest's verdict.
    h.rt.plugins.emit("updates.fetched", ["url": .string(UpdatesCore.manifestURL), "status": 304, "bytes": 0])
    h.rt.plugins.emit("updates.sparkle", ["phase": "none"])
    #expect(toastTexts(h).last == "den is up to date|")
    _ = core
  }

  @Test func releaseManifestInstallsOnlyChangedCompatibleVerifiedPlugins() {
    let fake = FakeUpdates()
    let (h, core, _) = setup(fake)
    #expect(core.channel == "stable")
    core.check(manual: false)
    let fetch = fake.called("fetch").first
    #expect(fetch?["url"] == .string(UpdatesCore.manifestURL) && fetch?["json"] == true && fetch?["etag"] == "")
    let manifest: Value = ["channels": ["stable": ["version": "0.1.1", "plugins": [
      ["id": "tabs", "sha256": "new", "signature": "sig", "url": "https://x/tabs.dylib", "hostAPI": 5, "version": "0.1.1"],
      ["id": "theme", "sha256": "same", "signature": "sig", "url": "https://x/theme.dylib", "hostAPI": 5],
      ["id": "peek", "sha256": "p2", "signature": "sig", "url": "https://x/peek.dylib", "hostAPI": 6],  // needs a newer host
    ]]]]
    h.rt.plugins.emit("updates.fetched", ["url": .string(UpdatesCore.manifestURL), "status": 200, "etag": "\"e1\"", "value": manifest, "bytes": 900])
    #expect(fake.called("installPlugin").map { $0.s("id") } == ["tabs"])
    #expect(core.etag == "\"e1\"" && core.lastResult == "Updating 1 plugin")

    // 304: nothing installed, the ETag is sent next time.
    core.check(manual: false)
    #expect(fake.called("fetch").last?["etag"] == "\"e1\"")
    h.rt.plugins.emit("updates.fetched", ["url": .string(UpdatesCore.manifestURL), "status": 304, "bytes": 0])
    #expect(fake.called("installPlugin").count == 1 && core.lastResult == "Plugins are up to date")

    // Installed but it didn't apply: rolled back, and that build is never offered again.
    fake.plugins = [["id": "tabs", "layer": "managed", "sha256": "new"]]
    h.rt.plugins.emit("updates.pluginInstalled", ["id": "tabs", "ok": true, "active": false])
    #expect(fake.called("rollbackPlugin").map { $0.s("id") } == ["tabs"])
    #expect(core.bad == ["new"])
    fake.plugins = [["id": "tabs", "layer": "bundle", "sha256": "old"], ["id": "theme", "layer": "bundle", "sha256": "same"]]
    h.rt.plugins.emit("updates.fetched", ["url": .string(UpdatesCore.manifestURL), "status": 200, "etag": "\"e2\"", "value": manifest])
    #expect(fake.called("installPlugin").map { $0.s("id") } == ["tabs"])
  }

  @Test func crashedManagedPluginIsRolledBackAtLaunch() {
    let fake = FakeUpdates()
    fake.info = fake.info.with("crashed", ["tabs"])
    let (_, core, _) = setup(fake)
    #expect(fake.called("rollbackPlugin").map { $0.s("id") } == ["tabs"])
    _ = core
  }

  @Test func utcFormatting() {
    #expect(UpdatesCore.utc(0) == "1970-01-01 00:00 UTC")
    #expect(UpdatesCore.utc(1_790_517_282_872) == "2026-09-27 13:54 UTC")
  }
}
