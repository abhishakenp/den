import Foundation

/// A per-plugin sandbox profile that restricts what the sandboxed plugin process can do.
///
/// Profiles are generated from a plugin's declared permissions (the sidecar
/// `permissions.json` / sidecar `"permissions"` array) and the host's global policy.
/// The generator produces a macOS sandbox profile (`.sb`) that the helper process
/// is launched with via `SECURITY_SESSION_PREFERENCES` or an `entitlements` plist.
///
/// Permission kinds:
/// - `session:<domain>`  — allow network access to `<domain>` + its subdomains,
///                         and read/write a per-site keybag under the plugin's
///                         container (`keychain-access-groups` + sandbox storage).
/// - `net:<domain>`      — outbound network to `<domain>` only.
/// - `pages:*`           — allow file access to the plugin's resource folder so
///                         `webviews.inject` can read its scripts.
/// - `files:<path>`      — allow read access under `<path>` inside the sandboxed
///                         home directory (the sandbox translates `~/` to the
///                         plugin's temporary container).
///
/// The profile also denies:
/// - Raw socket access (all TCP/UDP via `allow*` rules instead).
/// - File write outside the plugin's own sandbox directory.
/// - System-protected paths (`/System`, `/usr/sbin`, `/private/etc/hosts`, …).
/// - Launch services / process inspection / debug ports.
///
/// A plugin opts into sandboxing by declaring `"sandbox": true` in its sidecar,
/// or globally via `~/.den/config.toml` `[sandbox] enabled = true`.  First-frame
/// plugins (spaces, tabs) run unsandboxed because their cold-start latency would
/// block the first window.
public struct PluginSandboxProfile: Sendable {
  /// Unique plugin identifier.
  public var pluginID: String
  /// Network domains the plugin may reach (from `session:` / `net:` permissions).
  public var allowedNetworkDomains: [String] = []
  /// File-system prefixes the plugin may read (from `files:` permissions).
  public var allowedFilePrefixes: [String] = []
  /// Whether the plugin may access the keychain.
  public var allowKeychain: Bool = false
  /// The plugin's resource folder path (for `pages:` injection scripts).
  public var resourceFolder: String?
  /// Whether the plugin may read/write the sandbox container (session cookies, storage).
  public var allowSandboxStorage: Bool = false
  /// The sandbox container path for file access rules (resolved from NSHomeDirectory).
  public var sandboxContainerPath: String = ""
  /// The entitlements file path, if any (for keychain sharing).
  public var entitlementsFile: String?

  /// True when the profile is effectively empty (no restrictions beyond the default deny).
  public var isEmpty: Bool {
    allowedNetworkDomains.isEmpty
      && allowedFilePrefixes.isEmpty
      && !allowKeychain
      && resourceFolder == nil
      && !allowSandboxStorage
  }

  /// The human-readable name of the sandbox rule set.
  public var label: String {
    "den-plugin-sandbox.\(pluginID)"
  }
}