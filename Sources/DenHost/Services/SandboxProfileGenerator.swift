import Foundation

/// Generates a macOS sandbox profile (`.sb` text) from a `PluginSandboxProfile`.
///
/// The profile follows the macOS sandbox(5) format and is designed to restrict
/// a plugin helper process to only the resources its sidecar declares.
///
/// Rules are ordered: default-deny first, then allow rules for what the plugin
/// needs.  The generated profile can be passed to `sandbox-exec -f <profile>`.
public final class SandboxProfileGenerator: Sendable {

  /// The minimum macOS version required for the profile features used.
  public static let minSupportedVersion = "26.0"

  /// Generates a sandbox profile string for the given plugin profile.
  /// The profile's paths should already be resolved (e.g., `~/` expanded).
  public nonisolated func generate(_ profile: PluginSandboxProfile) -> String {
    var rules: [String] = []

    // ── Header ──────────────────────────────────────────────────────────────
    rules.append("(version 1)")
    rules.append("")

    // ── Default deny everything ─────────────────────────────────────────────
    rules.append(";; Deny everything by default")
    rules.append("(deny default)")
    rules.append("")

    // ── Basic system access needed by every process ─────────────────────────
    rules.append(";; Basic system access required for any process")
    rules.append("(allow process-exec)")
    rules.append("(allow file-read-metadata)")
    rules.append("(allow file-read*")
    rules.append("  (literal \"/usr/lib/libswiftCore.dylib\")")
    rules.append("  (literal \"/usr/lib/swift/libswiftCore.dylib\")")
    rules.append(")")
    rules.append("")

    // ── Network rules ───────────────────────────────────────────────────────
    if !profile.allowedNetworkDomains.isEmpty {
      rules.append(";; Network access for declared domains")
      rules.append("(allow network*")
      for domain in profile.allowedNetworkDomains.sorted() {
        rules.append("  (regex #\"^\\.?\(regexpEscape(domain))($|\\.)\" )")
      }
      rules.append(")")
      rules.append("")
    }

    // ── File access — sandbox container (cookies, session storage) ──────────
    if profile.allowSandboxStorage {
      rules.append(";; Sandbox container access (session data, cookies)")
      rules.append("(allow file-read* file-write*")
      rules.append("  (subpath \"\(profile.sandboxContainerPath)\")")
      rules.append(")")
      rules.append("")
    }

    // ── File access — allowed prefixes ──────────────────────────────────────
    if !profile.allowedFilePrefixes.isEmpty {
      rules.append(";; File read access for declared paths")
      rules.append("(allow file-read*")
      for prefix in profile.allowedFilePrefixes.sorted() {
        let escaped = regexpEscape(prefix)
        rules.append("  (regex #\"^\(escaped)(/.*|$)\" )")
      }
      rules.append(")")
      rules.append("")
    }

    // ── Resource folder access ──────────────────────────────────────────────
    if let resourceFolder = profile.resourceFolder {
      rules.append(";; Plugin resource folder access (for pages: injection)")
      rules.append("(allow file-read*")
      rules.append("  (subpath \"\(resourceFolder)\")")
      rules.append(")")
      rules.append("")
    }

    // ── Keychain access ─────────────────────────────────────────────────────
    if profile.allowKeychain {
      rules.append(";; Keychain access for session credentials")
      rules.append("(allow apple-event")
      rules.append("  (server-name \"com.apple.security.cloudkit\")")
      rules.append(")")
      rules.append("")
    }

    // ── Deny dangerous operations ───────────────────────────────────────────
    rules.append(";; Explicitly deny dangerous operations")
    rules.append("(deny system-socket)")
    rules.append("(deny network-outbound")
    rules.append("  (remote \"/var/run/mDNSResponder\")")
    rules.append(")")
    rules.append("(deny file-write*")
    rules.append("  (literal \"/dev/null\")")
    rules.append(")")
    rules.append("(deny with-error ENOSYS debug*")
    rules.append("  (debug-request *")
    rules.append("    (arg 0 (string \"task_for_pid\"))")
    rules.append("  )")
    rules.append(")")
    rules.append("")

    // ── Process & Mach deny ─────────────────────────────────────────────────
    rules.append(";; Deny process introspection and launch services")
    rules.append("(deny process-dyld-info process-info)")
    rules.append("(deny mach-lookup")
    rules.append("  (global-name-regexp #\"^com\\.apple\\.xpcd$\")")
    rules.append(")")
    rules.append("")

    // ── System path deny ────────────────────────────────────────────────────
    rules.append(";; Deny access to system-protected paths")
    rules.append("(deny file-read* file-write*")
    rules.append("  (regex #\"^/System(/|$)\")")
    rules.append("  (regex #\"^/usr/sbin(/|$)\")")
    rules.append("  (regex #\"^/private/etc/hosts$\")")
    rules.append(")")
    rules.append("")

    return rules.joined(separator: "\n") + "\n"
  }

  /// Writes the profile to disk and returns the file URL.
  public nonisolated func writeProfile(_ profile: PluginSandboxProfile, to directory: URL) throws -> URL {
    let content = generate(profile)
    let file = directory.appendingPathComponent("\(profile.pluginID).sb")
    try content.write(to: file, atomically: true, encoding: .utf8)
    return file
  }

  /// Escape a string for use in a regex within a sandbox profile.
  nonisolated private func regexpEscape(_ s: String) -> String {
    let special: [Character] = [".", "^", "$", "*", "+", "?", "(", ")", "[", "]", "{", "}", "|", "\\"]
    var result = s
    for ch in special {
      let escaped = "\\\\(ch)"
      result = result.replacingOccurrences(of: String(ch), with: escaped)
    }
    return result
  }
}