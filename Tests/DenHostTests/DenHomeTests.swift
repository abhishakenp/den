import Cordis
import CryptoKit
import CordisValue
import Foundation
import DenTestSupport
import Testing

@testable import DenHost

@MainActor
@Suite(.serialized, .watchdog)
struct DenHomeTests {
  func tempHome() -> DenHome {
    DenHome(root: FileManager.default.temporaryDirectory.appendingPathComponent("den-home-\(UUID().uuidString)/.den", isDirectory: true))
  }

  func write(_ text: String, _ url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: url)
  }

  // MARK: TOML

  @Test func tomlParsesTheConfigSubset() throws {
    let v = try TOML.parse("""
      # comment
      title = "den" # trailing comment
      n = 1_000
      neg = -3
      f = 0.5
      on = true
      list = [ "a", 'b\\c',
        "c", # comment inside
      ]
      esc = "q\\"\\u00e9\\n"
      a.b = 2

      [plugins]
      disabled = ["peek"]

      [search.keywords]
      sf = { name = "Swift Forums", url = "https://forums.swift.org/search?q=%s" }
      "quoted key" = {}

      [shortcuts]
      "cmd+shift+y" = "den.toggleSidebar"
      """)
    #expect(v["title"] == "den")
    #expect(v["n"] == .int(1000) && v["neg"] == .int(-3) && v["f"] == .double(0.5) && v["on"] == true)
    #expect(v["list"] == ["a", "b\\c", "c"])
    #expect(v["esc"] == .string("q\"é\n"))
    #expect(v["a"]["b"] == .int(2))
    #expect(ConfigService.lookup(v, "plugins.disabled") == ["peek"])
    #expect(ConfigService.lookup(v, "search.keywords.sf.url") == "https://forums.swift.org/search?q=%s")
    #expect(ConfigService.lookup(v, "search.keywords")["quoted key"] == .object([]))
    #expect(v["shortcuts"]["cmd+shift+y"] == "den.toggleSidebar")
    // Keys keep file order.
    #expect(v.object?.map(\.0) == ["title", "n", "neg", "f", "on", "list", "esc", "a", "plugins", "search", "shortcuts"])
  }

  @Test func tomlReportsErrorsWithLineNumbers() {
    func err(_ s: String) -> TOML.ParseError? {
      do {
        _ = try TOML.parse(s)
        return nil
      } catch { return error }
    }
    #expect(err("a = 1\nb = hello")?.line == 2)
    #expect(err("a = 1\na = 2")?.message == "key 'a' defined twice")
    #expect(err("[t]\n[t]")?.message == "table [t] defined twice")
    #expect(err("a = \"open")?.message == "unterminated string")
    #expect(err("[[x]]") != nil)
    #expect(err("a = [1, 2") != nil)
    #expect(err("a = 1 b = 2") != nil)
    #expect(err("") == nil)
    #expect(err("# only a comment\n\n") == nil)
  }

  // MARK: Layout and config

  @Test func layoutIsCreatedOnceAndDefaultConfigParses() throws {
    let home = tempHome()
    home.ensureLayout()
    for d in [home.plugins, home.themes, home.logs] { #expect(FileManager.default.fileExists(atPath: d.path)) }
    let text = try String(contentsOf: home.config, encoding: .utf8)
    let v = try TOML.parse(text)
    #expect(ConfigService.lookup(v, "plugins.disabled") == [])
    // A user's edits survive: ensureLayout never overwrites.
    write("[plugins]\ndisabled = [\"peek\"]\n", home.config)
    home.ensureLayout()
    #expect(ConfigService.disabledPlugins(home) == ["peek"])
  }

  @Test func configServiceReadsAppliesAndKeepsLastGoodConfig() {
    let home = tempHome()
    home.ensureLayout()
    let host = ServiceHost()
    var calls: [(String, String, Value)] = []
    var engines: Value = [["keyword": "g", "name": "Google", "url": "https://google.com/search?q=%s"]]
    let config = ConfigService(host: host, home: home) { s, m, a in
      calls.append((s, m, a))
      if s == "commands" && m == "engines" {
        if let list = a["engines"].array { engines = .array(list) }
        return engines
      }
      return .ok
    }
    var changed = 0, themeEvents: [Value] = []
    host.on("config.changed") { _ in changed += 1 }
    host.on("config.themesChanged") { themeEvents.append($0) }
    #expect(config.handle(method: "get", args: .null) == .object([]))  // nothing read before start()

    write("""
      [shortcuts]
      "cmd+shift+y" = "den.toggleSidebar"
      [search.keywords]
      sf = { name = "Swift Forums", url = "https://forums.swift.org/search?q=%s" }
      """, home.config)
    write(##"{"name": "Dusk", "colors": ["#3139fb", "#ff3c19"], "intensity": 2, "appearance": "dark"}"##, home.themes.appendingPathComponent("dusk.json"))
    write("colors = [\"#abc\"]\ngrain = 0.2\n", home.themes.appendingPathComponent("aurora.toml"))
    write(#"{"colors": ["red"]}"#, home.themes.appendingPathComponent("bad.json"))
    config.start()

    #expect(changed == 1)
    #expect(config.handle(method: "get", args: ["key": "shortcuts"])["cmd+shift+y"] == "den.toggleSidebar")
    let bind = calls.first { $0.0 == "keys" && $0.1 == "bind" }
    #expect(bind?.2["chord"] == "cmd+shift+y" && bind?.2["event"] == "config.shortcut" && bind?.2["payload"]["id"] == "den.toggleSidebar")
    #expect(engines.array?.map { $0.str("keyword") } == ["g", "sf"])

    // Themes: sorted by name, clamped, errors reported per file.
    let themes = config.handle(method: "themes", args: .null).array ?? []
    #expect(themes.map { $0.str("name") } == ["aurora", "Dusk"])
    #expect(themes[1]["intensity"] == .double(1) && themes[1]["appearance"] == "dark")
    #expect(themeEvents.count == 1)
    #expect(config.errors.contains { $0.hasPrefix("themes/bad.json") })

    // The bound shortcut runs its command.
    host.emit("config.shortcut", ["chord": "cmd+shift+y", "payload": ["id": "den.toggleSidebar"]])
    #expect(calls.last?.0 == "commands" && calls.last?.1 == "run" && calls.last?.2["id"] == "den.toggleSidebar")

    // A broken edit keeps the last good config and reports the error.
    write("[shortcuts\n", home.config)
    config.reloadConfig()
    #expect(config.errors.contains { $0.hasPrefix("config.toml line 1") })
    #expect(config.handle(method: "get", args: ["key": "search.keywords.sf.name"]) == "Swift Forums")

    // Removing the section unbinds the chord and takes the keyword out again.
    write("", home.config)
    calls = []
    config.reloadConfig()
    #expect(calls.contains { $0.0 == "keys" && $0.1 == "unbind" && $0.2["chord"] == "cmd+shift+y" })
    #expect(!calls.contains { $0.0 == "keys" && $0.1 == "bind" })
    #expect(engines.array?.map { $0.str("keyword") } == ["g"])
  }

  // MARK: Plugin priority

  /// Loader: for one file name, ~/.den beats Application Support beats the bundle; `disabled` skips.
  /// The files are not real plugins, so which path failed shows which one was chosen.
  @Test func loaderPrefersDenHomeOverUserOverBundle() {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("den-layers-\(UUID().uuidString)")
    let bundle = base.appendingPathComponent("bundle"), user = base.appendingPathComponent("user")
    let home = DenHome(root: base.appendingPathComponent(".den"))
    for (dir, names) in [(bundle, ["a", "b", "c", "d"]), (user, ["b", "c"]), (home.plugins, ["c"])] {
      for n in names { write("not a dylib", dir.appendingPathComponent("\(n).dylib")) }
    }
    write("// source plugin", home.plugins.appendingPathComponent("e/Plugin.swift"))
    write("stale build", home.buildCache.appendingPathComponent("e.dylib"))
    write("build of a deleted folder", home.buildCache.appendingPathComponent("gone.dylib"))

    let files = LivePlugins.launchFiles(home)
    #expect(files.map(\.lastPathComponent) == ["c.dylib", "e.dylib"])
    let host = PluginHost(crashMarkerPath: nil, cacheDirectory: base.appendingPathComponent("cache").path)
    let loader = PluginLoader(plugins: host)
    let out = loader.loadAll(bundle: bundle, user: user, home: files, dev: nil, disabled: ["d"])
    #expect(Set(out.failed.keys) == [
      bundle.appendingPathComponent("a.dylib").path,
      user.appendingPathComponent("b.dylib").path,
      home.plugins.appendingPathComponent("c.dylib").path,
      home.buildCache.appendingPathComponent("e.dylib").path,
    ])
  }

  @Test func livePluginsCandidatesClassifyAndPlan() {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("den-live-\(UUID().uuidString)")
    let bundle = base.appendingPathComponent("bundle"), user = base.appendingPathComponent("user")
    let home = DenHome(root: base.appendingPathComponent(".den"))
    write("x", bundle.appendingPathComponent("tabs.dylib"))
    let live = LivePlugins(plugins: PluginHost(crashMarkerPath: nil), home: home, layers: .init(bundle: bundle, user: user, dev: nil), compiler: nil)
    #expect(live.candidates("tabs.dylib") == [bundle.appendingPathComponent("tabs.dylib")])
    write("x", user.appendingPathComponent("tabs.dylib"))
    write("x", home.plugins.appendingPathComponent("tabs.dylib"))
    write("x", home.buildCache.appendingPathComponent("tabs.dylib"))
    // A build in the cache only counts while its source folder exists.
    #expect(live.candidates("tabs.dylib").first == home.plugins.appendingPathComponent("tabs.dylib"))
    write("// src", home.plugins.appendingPathComponent("tabs/Tabs.swift"))
    #expect(live.candidates("tabs.dylib") == [
      home.buildCache.appendingPathComponent("tabs.dylib"), home.plugins.appendingPathComponent("tabs.dylib"),
      user.appendingPathComponent("tabs.dylib"), bundle.appendingPathComponent("tabs.dylib"),
    ])

    #expect(LivePlugins.plan(current: nil, target: nil) == .none)
    #expect(LivePlugins.plan(current: "/b/tabs.dylib", target: nil) == .unload("/b/tabs.dylib"))
    #expect(LivePlugins.plan(current: nil, target: "/h/tabs.dylib") == .load("/h/tabs.dylib"))
    #expect(LivePlugins.plan(current: "/h/tabs.dylib", target: "/h/tabs.dylib") == .reload("/h/tabs.dylib"))
    #expect(LivePlugins.plan(current: "/b/tabs.dylib", target: "/h/tabs.dylib") == .swap(from: "/b/tabs.dylib", to: "/h/tabs.dylib"))

    let root = "/Users/me/.den"
    let c = LivePlugins.classify([
      "/Users/me/.den/config.toml", "/Users/me/.den/themes/dusk.json", "/Users/me/.den/plugins/tabs.dylib",
      "/Users/me/.den/plugins/tabs.dylib.tmp.123", "/Users/me/.den/plugins/.DS_Store", "/Users/me/.den/plugins/hello/Plugin.swift",
      "/Users/me/.den/plugins/hello/notes.txt", "/Users/me/.den/plugins/gone", "/Users/me/.den/logs/plugins.log", "/elsewhere/x.dylib",
    ], root: root)
    #expect(c == LivePlugins.Changes(dylibs: ["tabs.dylib"], sources: ["hello", "gone"], config: true, themes: true))
  }

  @Test func toolchainResolutionFollowsCordisBuild() {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("den-tc-\(UUID().uuidString)")
    func make(_ dir: URL) {
      write("#!/bin/sh\n", dir.appendingPathComponent("usr/bin/swiftc"))
      chmod(dir.appendingPathComponent("usr/bin/swiftc").path, 0o755)
      try? FileManager.default.createDirectory(at: dir.appendingPathComponent("usr/lib/swift/embedded"), withIntermediateDirectories: true)
    }
    #expect(SourceCompiler.findToolchain(env: [:], home: base) == nil || FileManager.default.fileExists(atPath: "/Library/Developer/Toolchains/swift-latest.xctoolchain"))
    let tcs = base.appendingPathComponent("Library/Developer/Toolchains")
    make(tcs.appendingPathComponent("swift-6.2.1-RELEASE.xctoolchain"))
    make(tcs.appendingPathComponent("swift-6.10.0-RELEASE.xctoolchain"))
    #expect(SourceCompiler.findToolchain(env: [:], home: base)?.lastPathComponent == "swift-6.10.0-RELEASE.xctoolchain")
    #expect(SourceCompiler.findToolchain(env: ["CORDIS_TOOLCHAIN": base.appendingPathComponent("nope").path], home: base) == nil)
  }

  // MARK: Updates

  @Test func pluginDownloadsAreVerifiedBySha256AndEdDSA() {
    let key = Curve25519.Signing.PrivateKey()
    let pub = key.publicKey.rawRepresentation.base64EncodedString()
    let data = Data("plugin bytes".utf8)
    let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let sig = try! key.signature(for: data).base64EncodedString()
    #expect(UpdatesService.verify(data, sha256: sha, signature: sig, publicKey: pub) == nil)
    #expect(UpdatesService.verify(data + Data([0]), sha256: sha, signature: sig, publicKey: pub) == "sha256 mismatch")
    let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    #expect(UpdatesService.verify(data, sha256: sha, signature: sig, publicKey: other) == "bad signature")
    #expect(UpdatesService.verify(data, sha256: sha, signature: sig, publicKey: nil) == "no public key to verify against")
    #expect(UpdatesService.verify(Data(), sha256: sha, signature: sig, publicKey: pub) == "empty download")
  }

  @Test func managedPluginsArePlacedWithPreviousKeptAndGatedByHostAPI() throws {
    let home = tempHome()
    let dir = home.managedPlugins
    #expect(UpdatesService.place(Data("v1".utf8), id: "tabs", in: dir, meta: ["hostAPI": 7, "version": "1", "sha256": "a"]) == nil)
    #expect(UpdatesService.place(Data("v2".utf8), id: "tabs", in: dir, meta: ["hostAPI": 8, "version": "2", "sha256": "b"]) == nil)
    let dylib = dir.appendingPathComponent("tabs.dylib")
    #expect(try String(contentsOf: dylib, encoding: .utf8) == "v2")
    #expect(try String(contentsOf: dir.appendingPathComponent("tabs.prev.dylib"), encoding: .utf8) == "v1")
    // v2 was built for host API 8.
    #expect(LivePlugins.managedCompatible(dylib, hostAPI: 8) == .ok)
    #expect(LivePlugins.managedCompatible(dylib, hostAPI: 7) == .deferred(needs: 8))
    #expect(LivePlugins.managedCompatible(dylib, hostAPI: 9) == .superseded(builtFor: 8))
    #expect(LivePlugins.managedCompatible(dylib, hostAPI: nil) == .ok)
    #expect(LivePlugins.launchFiles(home, hostAPI: 7).isEmpty)
    #expect(LivePlugins.launchFiles(home, hostAPI: 8).map(\.lastPathComponent) == ["tabs.dylib"])

    let svc = UpdatesService(host: ServiceHost(), home: home, build: DenBuild(hostAPI: 8), publicKey: nil)
    var activated: [String] = []
    svc.activate = { activated.append($0); return true }
    #expect(svc.handle(method: "rollbackPlugin", args: ["id": "tabs"])["restored"] == true)
    #expect(try String(contentsOf: dylib, encoding: .utf8) == "v1")
    #expect(LivePlugins.managedCompatible(dylib, hostAPI: 7) == .ok)
    #expect(activated == ["tabs.dylib"])
    // No previous build left: rollback removes the managed copy (the bundled one takes over).
    #expect(svc.handle(method: "rollbackPlugin", args: ["id": "tabs"])["restored"] == false)
    #expect(!FileManager.default.fileExists(atPath: dylib.path))
    #expect(svc.handle(method: "installPlugin", args: ["id": "tabs", "url": "http://insecure"]).isError)
  }

  @Test func updaterPathsAreClassified() {
    let c = LivePlugins.classify(["/h/.den/updates/state.json", "/h/.den/updates/plugins/tabs.dylib", "/h/.den/updates/plugins/theme.json",
                                  "/h/.den/updates/plugins/tabs.prev.dylib", "/h/.den/updates/plugins/.tabs.dylib.tmp"], root: "/h/.den")
    #expect(c.updaterState && c.dylibs == ["tabs.dylib", "theme.dylib"])
  }
}
