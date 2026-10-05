import Cordis
import CordisValue
import DenTestSupport
import Foundation
import Testing

@testable import DenHost

/// Lazy plugins (`"launch": "lazy"`): registered from their sidecar at launch, loaded on first use.
/// A real Embedded Swift plugin (Tests/Fixtures/plugins/probe) is built with cordis-build.
@MainActor
@Suite(.serialized, .watchdog)
struct LazyPluginsTests {
  nonisolated static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  /// The probe plugin, built once per test run (nil without cordis-build or an Embedded Swift toolchain).
  nonisolated static let probe: URL? = {
    let script = repo.appendingPathComponent(".build/checkouts/cordis-swift/Scripts/cordis-build")
    guard FileManager.default.isExecutableFile(atPath: script.path), SourceCompiler.findToolchain() != nil else { return nil }
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("den-lazy-\(UUID().uuidString)/probe.dylib")
    try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
    let (ok, output) = SourceCompiler(script: script, shared: []).run(
      id: "probe", out: out, sources: [repo.appendingPathComponent("Tests/Fixtures/plugins/probe/Probe.swift")])
    if !ok { print("probe build failed:\n\(output)") }
    return ok ? out : nil
  }()

  nonisolated static let sidecar = """
    {"launch": "lazy", "activation": {
      "services": ["probe"],
      "events": [{"event": "probe.poke", "match": {"id": "probe.*"}}],
      "commands": [{"id": "probe.hello", "title": "Hello Probe", "icon": "sf:star"}],
      "keys": [{"chord": "cmd+shift+9", "event": "probe.key.go", "title": "Probe"}],
      "settings": [{"id": "probe", "title": "Probe", "controls": []}]
    }}
    """

  /// A host with fake `commands`, `keys` and `settings` that record what's registered.
  @MainActor final class Fixture {
    let dir: URL
    let host: PluginHost
    let loader: PluginLoader
    var commands: [String: Value] = [:]
    var binds: [Value] = []
    var settings: [String] = []
    var heard: [String: [Value]] = [:]

    @MainActor init(sidecar: String = LazyPluginsTests.sidecar, dylib: URL?, withCommands: Bool = true) {
      dir = FileManager.default.temporaryDirectory.appendingPathComponent("den-lazy-bundle-\(UUID().uuidString)")
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      if let dylib { try? FileManager.default.copyItem(at: dylib, to: dir.appendingPathComponent("probe.dylib")) } else {
        try? Data("not a dylib".utf8).write(to: dir.appendingPathComponent("probe.dylib"))
      }
      try? Data(sidecar.utf8).write(to: dir.appendingPathComponent("probe.json"))
      host = PluginHost(crashMarkerPath: nil, cacheDirectory: dir.appendingPathComponent("cache").path)
      loader = PluginLoader(plugins: host)
      if withCommands { provideCommands() }
      host.provide("keys") { [unowned self] m, a in
        if m == "bind" { binds.append(a) }
        return .null
      }
      host.provide("settings") { [unowned self] m, a in
        if m == "register" { settings.append(a.str("id")) }
        return .null
      }
      for e in ["probe.ran", "probe.went", "probe.setting", "probe.applied"] { host.on(e) { [unowned self] v in heard[e, default: []].append(v) } }
    }

    @MainActor func provideCommands() {
      host.provide("commands") { [unowned self] m, a in
        if m == "register" { commands[a.str("id")] = a }
        if m == "unregister" { commands[a.str("id")] = nil }
        return .null
      }
    }

    @MainActor func launch() -> PluginLoader.Outcome {
      loader.loadAll(bundle: dir, user: nil, home: [], dev: nil, deferring: true)
      return loader.loadDeferred()
    }

    var loaded: Bool { host.plugin("probe") != nil }
  }

  @Test func sidecarSchemaParses() throws {
    let s = try #require(ValueJSON.parse(Self.sidecar).map(PluginSidecar.parse))
    #expect(s.launch == .lazy)
    #expect(s.services == ["probe"])
    #expect(s.commands.map { $0.str("id") } == ["probe.hello"])
    let t = s.triggers
    #expect(t.contains(PluginSidecar.Trigger(event: "commands.run", match: ["id": "probe.hello"])))
    #expect(t.contains(PluginSidecar.Trigger(event: "probe.key.go")))
    #expect(t.contains(PluginSidecar.Trigger(event: "settings.opened", match: ["section": "probe"])))
    #expect(t[0].matches(["id": "probe.anything"]) && !t[0].matches(["id": "other"]) && !t[0].matches(.null))
    #expect(PluginSidecar.parse(["launch": "firstFrame"]).launch == .firstFrame)
    #expect(PluginSidecar.parse(["launch": "bogus"]).launch == .deferred)
    #expect(PluginSidecar.parse(["launch": "lazy"]).isUnreachable)
    // The bundled lazy plugins declare what they register at apply.
    let ext = try #require(PluginSidecar.read(Self.repo.appendingPathComponent("Plugins/extensions/plugin.dylib")))
    #expect(ext.launch == .lazy && ext.services == ["extensions"] && ext.commands.count == 2)
    let theme = try #require(PluginSidecar.read(Self.repo.appendingPathComponent("Plugins/theme/plugin.dylib")))
    #expect(theme.launch == .lazy && theme.triggers.contains { $0.event == "spaces.editTheme" })
    #expect(PluginSidecar.read(Self.repo.appendingPathComponent("Plugins/tabs/plugin.dylib"))?.launch == .firstFrame)
  }

  @Test(.enabled(if: probe != nil, "needs cordis-build and an Embedded Swift toolchain"))
  func notLoadedAtLaunchButListedAndRunsOnItsCommand() throws {
    let f = Fixture(dylib: Self.probe)
    let out = f.launch()
    #expect(!out.loaded.contains("probe"))
    #expect(!f.loaded)
    #expect(f.loader.armed.keys.sorted() == ["probe"])
    // Registered for it without loading it.
    #expect(f.commands["probe.hello"]?.str("owner") == "probe")
    #expect(f.binds.map { $0.str("chord") } == ["cmd+shift+9"])
    #expect(f.settings == ["probe"])
    #expect(f.host.serviceNames.contains("probe"))
    let listed = DenRuntime.pluginsService(f.host, "get", .null).list("plugins")
    #expect(listed.contains { $0.str("id") == "probe" && $0.flag("active") && $0.flag("lazy") })
    #expect(f.host.hasListeners("probe.key.go"))

    // Other commands and other sections don't wake it.
    f.host.emit("commands.run", ["id": "den.newTab"])
    f.host.emit("settings.changed", ["id": "tabs", "key": "x", "value": true])
    #expect(!f.loaded)

    // Running its command loads it, and the command runs once.
    f.host.emit("commands.run", ["id": "probe.hello"])
    #expect(f.host.plugin("probe")?.state == .active)
    #expect(f.heard["probe.ran"] == [1])
    #expect(f.loader.armed.isEmpty)
    #expect(f.loader.lazyLog.contains { $0.contains("probe: loaded on commands.run") })
    // From now on it's the plugin's own registrations.
    f.host.emit("commands.run", ["id": "probe.hello"])
    #expect(f.heard["probe.ran"] == [1, 2])
    #expect(f.heard["probe.applied"]?.count == 1)
    #expect(DenRuntime.pluginsService(f.host, "get", .null).list("plugins").filter { $0.str("id") == "probe" }.count == 1)
  }

  @Test(.enabled(if: probe != nil, "needs cordis-build and an Embedded Swift toolchain"))
  func aKeyAnEventASettingOrAServiceCallWakesIt() throws {
    let key = Fixture(dylib: Self.probe)
    _ = key.launch()
    key.host.emit("probe.key.go")
    #expect(key.heard["probe.went"] == [true])

    let setting = Fixture(dylib: Self.probe)
    _ = setting.launch()
    setting.host.emit("settings.changed", ["id": "probe", "key": "on", "value": true])
    #expect(setting.heard["probe.setting"] == [true])

    let event = Fixture(dylib: Self.probe)
    _ = event.launch()
    event.host.emit("probe.poke", ["id": "nope"])
    #expect(!event.loaded)
    event.host.emit("probe.poke", ["id": "probe.now"])
    #expect(event.loaded)

    let service = Fixture(dylib: Self.probe)
    _ = service.launch()
    #expect(service.host.call("probe", "echo", 5) == 5)
    #expect(service.host.call("probe", "x") == "probe:x")
    #expect(service.loader.armed.isEmpty)
  }

  @Test(.enabled(if: probe != nil, "needs cordis-build and an Embedded Swift toolchain"))
  func commandsReachACommandBarThatComesLater() throws {
    let f = Fixture(dylib: Self.probe, withCommands: false)
    _ = f.launch()
    #expect(f.commands.isEmpty)
    f.provideCommands()
    f.loader.syncLazy()
    #expect(f.commands["probe.hello"] != nil)
    // A command bar that comes back (hot swap) gets them again.
    f.commands = [:]
    f.loader.lazy.commandsRegistered = []
    f.loader.syncLazy()
    #expect(f.commands["probe.hello"] != nil)
  }

  @Test(.enabled(if: probe != nil, "needs cordis-build and an Embedded Swift toolchain"))
  func aSidecarThatPromisesTooMuchIsReported() throws {
    let lying = Self.sidecar.replacingOccurrences(of: #""services": ["probe"]"#, with: #""services": ["probe", "ghost"]"#)
    let f = Fixture(sidecar: lying, dylib: Self.probe)
    _ = f.launch()
    let r = f.host.call("ghost", "x")
    #expect(r["error"].string != nil)  // no stub left answering, no loop
    #expect(f.host.plugin("probe")?.state == .active)
    #expect(f.loader.lazyLog.contains { $0.contains("declares service 'ghost'") })
  }

  @Test func aLazyPluginThatFailsToLoadKeepsItsTriggersAndSaysSo() throws {
    let f = Fixture(dylib: nil)  // not a dylib
    _ = f.launch()
    #expect(f.loader.armed["probe"] != nil)
    #expect(f.host.call("probe", "x")["error"].string == "plugin probe is not loaded")
    #expect(f.loader.lazyLog.contains { $0.contains("didn't load") })
    // Still registered: a later trigger (a fixed file, permissions allowed) tries again.
    #expect(f.host.serviceNames.contains("probe"))
    #expect(f.host.call("probe", "x")["error"].string == "plugin probe is not loaded")
    f.host.emit("commands.run", ["id": "probe.hello"])
    #expect(f.loader.lazyLog.filter { $0.contains("didn't load") }.count == 3)
  }

  @Test(.enabled(if: probe != nil, "needs cordis-build and an Embedded Swift toolchain"))
  func noTriggerMeansLoadedNormallyAndDisablingUnregisters() throws {
    let f = Fixture(sidecar: #"{"launch": "lazy"}"#, dylib: Self.probe)
    let out = f.launch()
    #expect(out.loaded.contains("probe"))
    #expect(f.loader.armed.isEmpty)

    let g = Fixture(dylib: Self.probe)
    _ = g.launch()
    #expect(g.loader.refreshArmed("probe.dylib", target: g.dir.appendingPathComponent("probe.dylib")))
    #expect(g.loader.armed["probe"] != nil && !g.loaded)  // same file: stays waiting
    #expect(g.loader.refreshArmed("probe.dylib", target: nil))
    #expect(g.loader.armed.isEmpty && g.commands["probe.hello"] == nil && !g.host.serviceNames.contains("probe"))
  }
}
