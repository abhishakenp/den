// thin-host: feature-specific, migrate to plugin (whole file)
import Foundation

/// Plain-language permission lines for prompts and the Extensions page, worded like Chrome's
/// install warnings. Permissions with no user-visible risk (storage, alarms…) get no line.
public enum ExtensionText {
  static let permissionLines: [String: String] = [
    "tabs": "Read your browsing history",
    "webNavigation": "Read your browsing history",
    "history": "Read and change your browsing history",
    "bookmarks": "Read and change your bookmarks",
    "declarativeNetRequest": "Block content on any page",
    "declarativeNetRequestWithHostAccess": "Block content on pages you allow",
    "declarativeNetRequestFeedback": "See which requests it blocked",
    "webRequest": "Observe your network requests",
    "cookies": "Read and change cookies on sites it can access",
    "nativeMessaging": "Communicate with cooperating native apps",
    "notifications": "Display notifications",
    "clipboardWrite": "Change what you copy and paste",
    "clipboardRead": "Read what you copy and paste",
    "downloads": "Manage your downloads",
    "management": "Manage your apps, extensions and themes",
    "privacy": "Change your privacy-related settings",
    "proxy": "Change your proxy settings",
    "geolocation": "Detect your physical location",
    "userScripts": "Run scripts you add on sites",
  ]

  /// Lines for a set of API permissions and host match patterns, de-duplicated, hosts first.
  public static func describe(permissions: [String], patterns: [String]) -> [String] {
    var out: [String] = []
    let hosts = patterns.filter { !$0.hasPrefix("webkit-extension:") }
    if hosts.contains(where: { $0 == "<all_urls>" || $0.hasPrefix("*://*/") || $0.hasPrefix("http://*/") || $0.hasPrefix("https://*/") }) {
      out.append("Read and change all your data on all websites")
    } else if !hosts.isEmpty {
      let names = Array(Set(hosts.map(siteName))).sorted()
      if names.count <= 3 {
        out.append("Read and change your data on " + names.joined(separator: ", "))
      } else {
        out.append("Read and change your data on \(names.count) sites")
      }
    }
    for p in permissions.sorted() { if let l = permissionLines[p], !out.contains(l) { out.append(l) } }
    return out
  }

  /// "*://*.example.com/*" -> "example.com"; a bare host passes through.
  static func siteName(_ pattern: String) -> String {
    var s = pattern
    if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
    s = String(s.prefix { $0 != "/" })
    if s.hasPrefix("*.") { s.removeFirst(2) }
    return s
  }
}
