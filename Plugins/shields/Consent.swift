// Answering cookie consent dialogs with the most private choice (docs/plugin-services.md#shields-plugin-shields).
//
// Nothing runs on a page without a consent platform: detection is a small WebKit content rule list
// of `notify` rules (no script, no cost per page) matching the six platforms' loader scripts in
// the main frame. When one loads, `sitepolicy.notified` names the platform, and Shields injects
// `consent.js` into that page's main frame, in its own isolated world, to answer that platform.
// Sourcepoint's message and privacy manager, and TrustArc's older preferences, are frames of
// their own: `consent-frame.js` is a page script that WebKit injects only into frames whose URL
// matches `framePatterns` (sitepolicy `script {matches}`), and it returns at once in any other.

enum Consent {
  static let list = "shields.consent"
  static let frames = "shields.consentFrames"
  static let frameScript = "consent-frame.js"
  static let pageScript = "consent.js"
  static let prefix = "consent:"

  /// Platform id (as consent.js knows it) and the name den shows.
  static let platforms: [(String, String)] = [
    ("onetrust", "OneTrust"), ("didomi", "Didomi"), ("quantcast", "Quantcast"),
    ("sourcepoint", "Sourcepoint"), ("trustarc", "TrustArc"), ("cookiebot", "Cookiebot"),
  ]

  static func name(_ id: String) -> String { platforms.first { $0.0 == id }?.1 ?? id }

  /// (url-filter, platform): the platforms' loader scripts, self-hosted copies included
  /// (lequipe.fr serves Didomi from /api/didomi/, sites put OneTrust's stub on their own domain).
  /// WebKit's url-filter has no `|`, so one rule per pattern.
  static let loaders: [(String, String)] = [
    ("^https?://[^/]*cookielaw\\\\.org/", "onetrust"),
    ("/otSDKStub\\\\.js", "onetrust"),
    ("/otBannerSdk\\\\.js", "onetrust"),
    ("privacy-center\\\\.org/.*loader\\\\.js", "didomi"),
    ("/didomi/.*loader\\\\.js", "didomi"),
    ("^https?://cmp\\\\.inmobi\\\\.com/", "quantcast"),
    ("^https?://cmp\\\\.quantcast\\\\.com/", "quantcast"),
    ("^https?://[^/]*quantcast\\\\.mgr\\\\.consensu\\\\.org/", "quantcast"),
    ("/wrapperMessagingWithoutDetection\\\\.js", "sourcepoint"),
    ("^https?://consent\\\\.trust[a-z]*\\\\.com/", "trustarc"),
    ("^https?://consent\\\\.cookiebot\\\\.[a-z]*/uc\\\\.js", "cookiebot"),
  ]

  /// The detection list (JSON for `sitepolicy.define`).
  static func rulesJSON() -> String {
    var out = "["
    for (i, (filter, cmp)) in loaders.enumerated() {
      if i > 0 { out += "," }
      out += "{\"trigger\":{\"url-filter\":\"" + filter + "\",\"resource-type\":[\"script\"],\"load-context\":[\"top-frame\"]},"
      out += "\"action\":{\"type\":\"notify\",\"notification\":\"" + prefix + cmp + "\"}}"
    }
    return out + "]"
  }

  /// Frames consent-frame.js may run in (WebKit match patterns: the path, never the query).
  static let framePatterns = ["*://*/index.html*", "*://*/privacy-manager/index.html*", "*://consent-pref.trustarc.com/*"]

  /// What the panel says for a result.
  static func describe(_ result: String) -> String {
    switch result {
    case "rejected": return "Rejected"
    case "answered": return "Answered before"
    case "open": return "Left open"
    case "failed": return "Not answered"
    default: return ""
    }
  }
}
