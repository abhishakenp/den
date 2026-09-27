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
///
/// cordis doesn't tell a host service which plugin called it, so callers pass their own id as
/// `plugin` (the same convention as `commands.register {owner}`). Plugins are native code in den's
/// process, so this is a declared-intent gate that keeps each plugin to its own sites, not a
/// sandbox.
@MainActor
public final class Permissions {
  private var grants: [String: [String]] = [:]

  public init() {}

  public func grant(_ plugin: String, _ permissions: [String]) {
    grants[plugin, default: []] += permissions.filter { !(grants[plugin] ?? []).contains($0) }
  }

  public func revoke(_ plugin: String) { grants[plugin] = nil }

  public func list(_ plugin: String) -> [String] { grants[plugin] ?? [] }

  /// Reads `<dylib without extension>.json` and grants its `permissions`. Returns what was granted.
  @discardableResult
  public func loadSidecar(plugin: String, dylib: URL) -> [String] {
    let url = dylib.deletingPathExtension().appendingPathExtension("json")
    guard let data = try? Data(contentsOf: url),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let perms = obj["permissions"] as? [String]
    else { return [] }
    let valid = perms.filter { Self.parse($0) != nil }
    grant(plugin, valid)
    return valid
  }

  /// "session:slack.com" -> ("session", "slack.com").
  nonisolated static func parse(_ p: String) -> (kind: String, domain: String)? {
    let parts = p.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2, ["session", "net"].contains(parts[0]), !parts[1].isEmpty else { return nil }
    return (parts[0], parts[1].lowercased())
  }

  /// True when `host` is `domain` or one of its subdomains.
  nonisolated static func covers(domain: String, host: String) -> Bool {
    let h = host.lowercased(), d = domain.lowercased()
    return h == d || h.hasSuffix("." + d)
  }

  /// `session` access to `host` (cookies, site storage, cookie-carrying fetches).
  public func allowsSession(_ plugin: String, host: String) -> Bool {
    list(plugin).contains { p in
      guard let (k, d) = Self.parse(p) else { return false }
      return k == "session" && Self.covers(domain: d, host: host)
    }
  }

  /// Plain `net.fetch` to `host`.
  public func allowsNet(_ plugin: String, host: String) -> Bool {
    list(plugin).contains { p in
      guard let (_, d) = Self.parse(p) else { return false }
      return Self.covers(domain: d, host: host)
    }
  }
}
