import Cordis
import Foundation

/// `~/.den`: where users extend den. Created after the first window of the first launch.
///
///     ~/.den/
///       plugins/      <id>.dylib (prebuilt) or <id>/*.swift (compiled by den); hot-reloaded
///       themes/       <name>.json / <name>.toml theme presets (the theme plugin offers them)
///       config.toml   settings, shortcuts, site-search keywords (see `DenHome.defaultConfig`)
///       logs/         plugins.log (loads, reloads, builds), build-<id>.log
///
/// `DEN_HOME` overrides the location (tests, a second profile).
public struct DenHome: Sendable, Equatable {
  public let root: URL

  public init(root: URL = DenHome.defaultRoot) { self.root = root.standardizedFileURL }

  public static var defaultRoot: URL {
    if let p = ProcessInfo.processInfo.environment["DEN_HOME"], !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true) }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".den", isDirectory: true)
  }

  public var plugins: URL { root.appendingPathComponent("plugins", isDirectory: true) }
  public var themes: URL { root.appendingPathComponent("themes", isDirectory: true) }
  public var config: URL { root.appendingPathComponent("config.toml") }
  public var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
  /// Plugin updates (release OTA or the follow-main updater): `<id>.dylib` + `<id>.json`.
  public var updates: URL { root.appendingPathComponent("updates", isDirectory: true) }
  public var managedPlugins: URL { updates.appendingPathComponent("plugins", isDirectory: true) }
  /// Written by scripts/updater.sh (follow-main): deployed commit, host install pending, …
  public var updaterState: URL { updates.appendingPathComponent("state.json") }
  /// The follow-main updater's clean checkout. Not watched.
  public var source: URL { root.appendingPathComponent("src", isDirectory: true) }
  /// Unpacked extension folders loaded as development extensions (docs/den-home.md).
  public var extensions: URL { root.appendingPathComponent("extensions", isDirectory: true) }

  /// Compiled source plugins. Outside `~/.den` so builds never trigger the `~/.den` watcher.
  public var buildCache: URL {
    if root == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".den", isDirectory: true).standardizedFileURL {
      return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("io.github.abhishakenp.den/source-plugins", isDirectory: true)
    }
    return root.deletingLastPathComponent().appendingPathComponent(".\(root.lastPathComponent)-cache/source-plugins", isDirectory: true)
  }

  /// Creates the folders, and a commented config.toml if there is none. Idempotent.
  public func ensureLayout() {
    let fm = FileManager.default
    for d in [plugins, themes, logs, managedPlugins] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
    if !fm.fileExists(atPath: config.path) { try? Data(Self.defaultConfig.utf8).write(to: config, options: .atomic) }
  }

  /// The config.toml written on first launch. It documents the whole schema.
  public static let defaultConfig = """
    # den settings. den reloads this file as soon as you save it.
    # Schema: docs/den-home.md (https://github.com/abhishakenp/den/blob/main/docs/den-home.md)

    [plugins]
    # Plugin ids den should not load, bundled or yours. Example: disabled = ["peek"]
    disabled = []

    [shortcuts]
    # "<chord>" = "<command id>". Chords: cmd, shift, opt, ctrl + a key, e.g. "cmd+shift+y".
    # Command ids are the ones in the command bar (docs/plugin-services.md), e.g.
    # "cmd+shift+s" = "den.toggleSidebar"

    [search.keywords]
    # Site-search keywords for the command bar: type the keyword, then Tab. %s is the query.
    # sf = { name = "Swift Forums", url = "https://forums.swift.org/search?q=%s" }

    """
}

/// Appends timestamped lines to a file in `~/.den/logs`, off the main thread.
public final class DenLog: @unchecked Sendable {
  public let url: URL
  private let queue = DispatchQueue(label: "den.log", qos: .utility)

  public init(url: URL) { self.url = url }

  public func write(_ line: String) {
    let stamp = Date()
    queue.async { [url] in
      let text = "\(DenLog.format(stamp)) \(line)\n"
      let fm = FileManager.default
      if !fm.fileExists(atPath: url.path) {
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: url.path, contents: nil)
      }
      guard let h = try? FileHandle(forWritingTo: url) else { return }
      defer { try? h.close() }
      _ = try? h.seekToEnd()
      try? h.write(contentsOf: Data(text.utf8))
    }
  }

  /// Waits for pending writes (tests).
  public func flush() { queue.sync {} }

  static func format(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f.string(from: d)
  }
}

extension DenRuntime {
  /// Registers a host service created outside the runtime (e.g. `ConfigService`) on both buses.
  public func provide(_ s: HostService) {
    host.provide(s)
    plugins.provide(s.name) { [unowned s] method, args in s.handle(method: method, args: args) }
  }
}
