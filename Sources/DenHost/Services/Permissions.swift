import CordisValue
import Foundation

/// Per-plugin permissions for the services that can reach a logged-in website (`session`, `net`).
///
/// A plugin declares them in a sidecar next to its dylib, `<id>.json`:
/// `{"permissions": ["session:slack.com", "net:api.example.com"]}` (bundle.sh copies
/// `Plugins/<id>/permissions.json` there). `PluginLoader` grants them when it loads the plugin.
/// Anything undeclared is denied.
///
/// - `session:<domain>`: read cookies and site storage for `<domain>` and its subdomains, and
///   `net.fetch` to them with the profile's cookies attached.
/// - `net:<domain>`: `net.fetch` to `<domain>` and its subdomains, without cookies.
/// - `pages:<domain>` (or `pages:*`): run the plugin's own scripts in pages of `<domain>` (every
///   page with `*`) through `webviews.inject`, in the plugin's isolated content world.
/// - `files:<path>` (`~/…` or absolute): read that file or anything under that folder through the
///   `files` service (importers).
///
/// A plugin's other sidecar is its resource folder, `<id>.resources/` next to the dylib
/// (bundled plugins: `Contents/Resources/plugin-resources/<id>/`, from `Plugins/<id>/resources/`): files `webviews.inject` reads by name.
///
/// cordis doesn't tell a host service which plugin called it, so callers pass their own id as
/// `plugin` (the same convention as `commands.register {owner}`). Plugins are native code in den's
/// process, so this is a declared-intent gate that keeps each plugin to its own sites, not a
/// sandbox.
@MainActor
public final class Permissions {
  private var grants: [String: [String]] = [:]
  /// Plugin id -> its resource folder (`<id>.resources` next to the dylib).
  public private(set) var resources: [String: URL] = [:]

  public init() {}

  public func grant(_ plugin: String, _ permissions: [String]) {
    grants[plugin, default: []] += permissions.filter { !(grants[plugin] ?? []).contains($0) }
  }

  public func revoke(_ plugin: String) { grants[plugin] = nil }

  public func list(_ plugin: String) -> [String] { grants[plugin] ?? [] }

  /// Reads `<dylib without extension>.json` and grants its `permissions`. Returns what was granted.
  @discardableResult
  public func loadSidecar(plugin: String, dylib: URL) -> [String] {
    let res = dylib.deletingPathExtension().appendingPathExtension("resources")
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: res.path, isDirectory: &isDir), isDir.boolValue { resources[plugin] = res }
    let url = dylib.deletingPathExtension().appendingPathExtension("json")
    guard let data = try? Data(contentsOf: url),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let perms = obj["permissions"] as? [String]
    else { return [] }
    let valid = perms.filter { Self.parse($0) != nil }
    grant(plugin, valid)
    return valid
  }

  /// "session:slack.com" -> ("session", "slack.com"); "files:~/Library/Safari" -> ("files", "~/Library/Safari")
  /// (paths keep their case and must start with `~/` or `/`).
  nonisolated static func parse(_ p: String) -> (kind: String, domain: String)? {
    let parts = p.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2, ["session", "net", "pages", "files"].contains(parts[0]), !parts[1].isEmpty else { return nil }
    if parts[0] == "files" {
      let path = parts[1]
      guard path.hasPrefix("~/") || path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
      return ("files", path)
    }
    // Cookies are never granted for every site (`net:*` and `pages:*` are).
    if parts[0] == "session" && parts[1] == "*" { return nil }
    return (parts[0], parts[1].lowercased())
  }

  /// True when `host` is `domain` or one of its subdomains.
  nonisolated static func covers(domain: String, host: String) -> Bool {
    let h = host.lowercased(), d = domain.lowercased()
    if d == "*" { return true }  // `net:*` only (parse refuses `session:*`)
    return h == d || h.hasSuffix("." + d)
  }

  /// `session` access to `host` (cookies, site storage, cookie-carrying fetches).
  public func allowsSession(_ plugin: String, host: String) -> Bool {
    list(plugin).contains { p in
      guard let (k, d) = Self.parse(p) else { return false }
      return k == "session" && Self.covers(domain: d, host: host)
    }
  }

  /// Plain `net.fetch` to `host`. `net:*` allows any host, still without cookies (link previews
  /// read the `<head>` of whatever link the user deliberately hovers). `session:*` isn't a thing.
  public func allowsNet(_ plugin: String, host: String) -> Bool {
    list(plugin).contains { p in
      guard let (k, d) = Self.parse(p), k == "session" || k == "net" else { return false }
      return Self.covers(domain: d, host: host)
    }
  }

  /// `webviews.inject` into a page on `host` (`pages:*` covers every page, `session:` its site).
  public func allowsPages(_ plugin: String, host: String) -> Bool {
    list(plugin).contains { p in
      guard let (k, d) = Self.parse(p), k == "pages" || k == "session" else { return false }
      return d == "*" || Self.covers(domain: d, host: host)
    }
  }

  /// `files` access to `path` (`~/…` or absolute): inside a granted `files:<prefix>`. Both sides are
  /// expanded against `home`, standardized and symlink-resolved, so `..` and links can't escape.
  public func allowsFile(_ plugin: String, path: String, home: URL) -> Bool {
    guard let target = Self.resolve(path, home: home) else { return false }
    return list(plugin).contains { p in
      guard let (k, prefix) = Self.parse(p), k == "files", let root = Self.resolve(prefix, home: home) else { return false }
      return target == root || target.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
  }

  /// `~/x` against `home`, or an absolute path; standardized and with symlinks resolved. nil for
  /// relative paths and any `..` component.
  nonisolated static func resolve(_ path: String, home: URL) -> String? {
    guard !path.split(separator: "/").contains("..") else { return nil }
    let url: URL
    if path == "~" { url = home } else if path.hasPrefix("~/") { url = home.appendingPathComponent(String(path.dropFirst(2))) } else if path.hasPrefix("/") {
      url = URL(fileURLWithPath: path)
    } else { return nil }
    return url.standardizedFileURL.resolvingSymlinksInPath().path
  }

  /// A file in the plugin's resource folder: plain names and subfolders only ("vendor/x.js").
  /// Without a registered folder (tests, `swift run`), the checkout's `Plugins/<id>/resources`.
  public func resource(_ plugin: String, _ name: String) -> URL? {
    guard !name.isEmpty, !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else { return nil }
    let bundled = Bundle.main.resourceURL?.appendingPathComponent("plugin-resources").appendingPathComponent(plugin)
    let dir = resources[plugin]
      ?? bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
      ?? Self.repoPlugins?.appendingPathComponent(plugin).appendingPathComponent("resources")
    guard let url = dir?.appendingPathComponent(name), FileManager.default.fileExists(atPath: url.path) else { return nil }
    return url
  }

  public func setResources(_ plugin: String, _ dir: URL) { resources[plugin] = dir }

  /// `<checkout>/Plugins` when running from the repository (swift test / swift run), else nil.
  nonisolated static let repoPlugins: URL? = {
    let u = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Plugins")
    return FileManager.default.fileExists(atPath: u.path) ? u : nil
  }()
}
