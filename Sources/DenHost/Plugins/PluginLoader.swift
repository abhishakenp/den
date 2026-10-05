import Cordis
import Foundation

/// Finds and loads den's plugins into the runtime's `PluginHost`.
///
/// Search order (a later directory wins for the same file name):
///   1. `den.app/Contents/PlugIns/*.dylib`       bundled plugins
///   2. `~/Library/Application Support/den/Plugins/*.dylib`   user plugins (legacy, not watched)
///   3. `home`: `~/.den/plugins/*.dylib` and compiled `~/.den/plugins/<id>/` source plugins
///      (`LivePlugins.launchFiles`), hot-reloaded by `LivePlugins`
///   4. `--dev-plugins <dir>`                      dev builds, hot-reloaded on every rebuild
/// Plugin ids in `disabled` (`[plugins] disabled` in `~/.den/config.toml`) are skipped.
///
/// Launch order: with `deferring`, only plugins whose sidecar `<id>.json` says
/// `"launch": "firstFrame"` (the ones that paint the first window: spaces, tabs) and `--dev-plugins`
/// load before the first frame; `loadDeferred()` loads the rest right after it. Until then each
/// deferred plugin's services (as it provided them last launch, `ManifestCache`) are stubs that
/// load it on the first call and forward, so an early caller never sees a missing service.
/// A plugin whose sidecar says `"launch": "lazy"` isn't loaded at all: what its `activation`
/// declares (services, events, commands, keys, settings) is registered for it, and its first use
/// loads it (LazyPlugins.swift). Every load, lazy or not, goes through `load(_:watch:)`.
///
/// A plugin whose build crashed den last time is refused by cordis (`crashedBuild`); the loader
/// records it in `crashed` so the app can tell the user.
@MainActor
public final class PluginLoader {
  public struct Outcome: Equatable {
    public var loaded: [String] = []  // plugin ids
    public var failed: [String: String] = [:]  // path -> reason
    public var crashed: [String] = []  // plugin ids disabled because their build crashed den
    public var permissions: [String: [String]] = [:]  // plugin id -> granted sidecar permissions
  }

  let plugins: PluginHost
  public private(set) var outcome = Outcome()
  /// Lazy plugins (`"launch": "lazy"`) registered but not loaded: LazyPlugins.swift.
  var lazy = LazyRegistry()
  static var loaders: [ObjectIdentifier: WeakLoader] = [:]

  public init(plugins: PluginHost) {
    self.plugins = plugins
    Self.loaders[ObjectIdentifier(plugins)] = WeakLoader(loader: self)
  }

  public static var bundleDirectory: URL? { Bundle.main.builtInPlugInsURL }

  public static var userDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("den/Plugins", isDirectory: true)
  }

  nonisolated static func dylibs(in dir: URL?) -> [URL] {
    guard let dir, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
    return names.filter { $0.hasSuffix(".dylib") }.sorted().map { dir.appendingPathComponent($0) }
  }

  /// Plugins chosen at launch but not loaded yet (`deferring`), in load order.
  public private(set) var deferred: [URL] = []
  /// Service stubs standing in for deferred plugins: service name -> (stub handle, plugin file).
  var stubs: [String: (CordisHandle, URL)] = [:]
  var manifests: ManifestCache?

  /// Loads every plugin (with `deferring`, only the first-frame ones; see the type comment).
  /// Files in `dev` are watched and hot-reloaded.
  @discardableResult
  public func loadAll(bundle: URL? = PluginLoader.bundleDirectory, user: URL? = PluginLoader.userDirectory, home: [URL] = [], dev: URL? = nil,
                      disabled: Set<String> = [], deferring: Bool = false) -> Outcome {
    var chosen: [String: (URL, Bool)] = [:]  // file name -> (path, watch)
    for (files, watch) in [(Self.dylibs(in: bundle), false), (Self.dylibs(in: user), false), (home, false), (Self.dylibs(in: dev), true)] {
      for f in files where !disabled.contains(f.deletingPathExtension().lastPathComponent) { chosen[f.lastPathComponent] = (f, watch) }
    }
    if deferring { manifests = ManifestCache(directory: plugins.cacheDirectory) }
    for name in chosen.keys.sorted() {
      let (url, watch) = chosen[name]!
      // Lazy: registered from its sidecar, loaded on the first trigger (LazyPlugins.swift).
      if !watch, arm(url) { continue }
      if deferring, !watch, !Self.paintsFirstFrame(url) {
        deferred.append(url)
        continue
      }
      load(url, watch: watch)
    }
    for url in deferred { stub(url) }
    return outcome
  }

  /// Loads every deferred plugin (after the first frame). Plugins a stub already loaded are skipped.
  @discardableResult
  public func loadDeferred() -> Outcome {
    let files = deferred
    deferred = []
    for url in files where !plugins.plugins.contains(where: { $0.path == url.path }) {
      unstub(url)
      load(url, watch: false)
    }
    manifests?.save(plugins.plugins)
    manifests = nil
    return outcome
  }

  func load(_ url: URL, watch: Bool) {
    let lazyID = lazyWillLoad(url)
    defer { if let lazyID { lazyDidLoad(lazyID) } }
    if watch {
      plugins.watch(url.path)
      guard let info = plugins.plugins.first(where: { $0.path == url.path }) else {
        outcome.failed[url.path] = "not loaded"
        return
      }
      if case let .disabled(reason) = info.state {
        if plugins.lastCrash?.pluginID == info.id { outcome.crashed.append(info.id) } else { outcome.failed[url.path] = reason }
      } else {
        outcome.loaded.append(info.id)
        grantPermissions(info.id, url)
      }
      return
    }
    do {
      let id = try plugins.load(url.path).id
      outcome.loaded.append(id)
      grantPermissions(id, url)
    } catch let PluginHostError.crashedBuild(id, _) {
      outcome.crashed.append(id)
    } catch {
      outcome.failed[url.path] = error.description
    }
  }

  /// The sidecar `<id>.json` declares `"launch": "firstFrame"`.
  nonisolated static func paintsFirstFrame(_ dylib: URL) -> Bool {
    let meta = dylib.deletingPathExtension().appendingPathExtension("json")
    guard let data = try? Data(contentsOf: meta), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
    return obj["launch"] as? String == "firstFrame"
  }

  /// Registers a stub for each service the deferred plugin at `url` provided last time.
  func stub(_ url: URL) {
    for name in manifests?.provides(url) ?? [] where stubs[name] == nil && !plugins.serviceNames.contains(name) {
      let h = plugins.provide(name) { [weak self] method, args in
        guard let self else { return ["error": "plugins: loader is gone"] }
        LaunchTrace.mark("stub \(name).\(method) loads \(url.lastPathComponent)")
        self.unstub(url)
        self.load(url, watch: false)
        return self.plugins.call(name, method, args)
      }
      if h != 0 { stubs[name] = (h, url) }
    }
  }

  func unstub(_ url: URL) {
    for (name, (h, u)) in stubs where u == url {
      stubs[name] = nil
      plugins.dispose(h)
    }
  }

  /// What each plugin file provided when it last loaded, keyed by path + size + modification
  /// date (a rebuilt file is simply unknown until it loads again). One small JSON file next to
  /// cordis' image cache; read once at launch, written after the deferred loads.
  struct ManifestCache {
    let file: URL
    var entries: [String: [String: Any]]

    init(directory: String) {
      file = URL(fileURLWithPath: directory).deletingLastPathComponent().appendingPathComponent("den-manifests.json")
      entries = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: [String: Any]] } ?? [:]
    }

    static func stamp(_ path: String) -> String? {
      guard let a = try? FileManager.default.attributesOfItem(atPath: path), let size = a[.size] as? Int, let date = a[.modificationDate] as? Date else { return nil }
      return "\(size)-\(Int(date.timeIntervalSince1970 * 1000))"
    }

    func provides(_ url: URL) -> [String] {
      guard let e = entries[url.path], let stamp = Self.stamp(url.path), e["stamp"] as? String == stamp else { return [] }
      return e["provides"] as? [String] ?? []
    }

    func save(_ loaded: [PluginInfo]) {
      var out: [String: [String: Any]] = [:]
      for p in loaded where p.state == .active {
        guard let stamp = Self.stamp(p.path) else { continue }
        out[p.path] = ["stamp": stamp, "id": p.id, "provides": p.provides]
      }
      guard !out.isEmpty, NSDictionary(dictionary: out).isEqual(to: entries) == false,
        let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
      else { return }
      try? data.write(to: file, options: .atomic)
    }
  }

  /// Grants what the plugin's `<id>.json` sidecar declares (see `Permissions`).
  func grantPermissions(_ id: String, _ dylib: URL) {
    guard let p = DenRuntime.permissions(for: plugins) else { return }
    p.revoke(id)
    let granted = p.loadSidecar(plugin: id, dylib: dylib)
    if !granted.isEmpty { outcome.permissions[id] = granted }
  }

  /// Toast text naming the plugins that were turned off because they crashed den.
  public static func crashToast(_ ids: [String]) -> String? {
    guard !ids.isEmpty else { return nil }
    let names = ids.map { "“\($0)”" }.joined(separator: ", ")
    return ids.count == 1 ? "The \(names) plugin crashed den and was turned off" : "Plugins \(names) crashed den and were turned off"
  }
}
