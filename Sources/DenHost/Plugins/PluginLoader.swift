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
/// A plugin whose build crashed den last time is refused by cordis (`crashedBuild`); the loader
/// records it in `crashed` so the app can tell the user.
@MainActor
public final class PluginLoader {
  public struct Outcome: Equatable {
    public var loaded: [String] = []  // plugin ids
    public var failed: [String: String] = [:]  // path -> reason
    public var crashed: [String] = []  // plugin ids disabled because their build crashed den
  }

  let plugins: PluginHost
  public private(set) var outcome = Outcome()

  public init(plugins: PluginHost) { self.plugins = plugins }

  public static var bundleDirectory: URL? { Bundle.main.builtInPlugInsURL }

  public static var userDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("den/Plugins", isDirectory: true)
  }

  static func dylibs(in dir: URL?) -> [URL] {
    guard let dir, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
    return names.filter { $0.hasSuffix(".dylib") }.sorted().map { dir.appendingPathComponent($0) }
  }

  /// Loads every plugin. Files in `dev` are watched and hot-reloaded.
  @discardableResult
  public func loadAll(bundle: URL? = PluginLoader.bundleDirectory, user: URL? = PluginLoader.userDirectory, home: [URL] = [], dev: URL? = nil,
                      disabled: Set<String> = []) -> Outcome {
    var chosen: [String: (URL, Bool)] = [:]  // file name -> (path, watch)
    for (files, watch) in [(Self.dylibs(in: bundle), false), (Self.dylibs(in: user), false), (home, false), (Self.dylibs(in: dev), true)] {
      for f in files where !disabled.contains(f.deletingPathExtension().lastPathComponent) { chosen[f.lastPathComponent] = (f, watch) }
    }
    let crash = plugins.lastCrash
    for name in chosen.keys.sorted() {
      let (url, watch) = chosen[name]!
      if watch {
        plugins.watch(url.path)
        guard let info = plugins.plugins.first(where: { $0.path == url.path }) else {
          outcome.failed[url.path] = "not loaded"
          continue
        }
        if case let .disabled(reason) = info.state {
          if crash?.pluginID == info.id { outcome.crashed.append(info.id) } else { outcome.failed[url.path] = reason }
        } else {
          outcome.loaded.append(info.id)
        }
        continue
      }
      do {
        outcome.loaded.append(try plugins.load(url.path).id)
      } catch let PluginHostError.crashedBuild(id, _) {
        outcome.crashed.append(id)
      } catch {
        outcome.failed[url.path] = error.description
      }
    }
    return outcome
  }

  /// Toast text naming the plugins that were turned off because they crashed den.
  public static func crashToast(_ ids: [String]) -> String? {
    guard !ids.isEmpty else { return nil }
    let names = ids.map { "“\($0)”" }.joined(separator: ", ")
    return ids.count == 1 ? "The \(names) plugin crashed den and was turned off" : "Plugins \(names) crashed den and were turned off"
  }
}
