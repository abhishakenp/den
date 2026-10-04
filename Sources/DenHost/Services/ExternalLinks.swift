import AppKit
import WebKit

/// Links WebKit can't load itself (`mailto:`, `tel:`, `zoommtg:`, `slack:`, `itms-apps:`…) open
/// in the app that handles them, like Safari: never as an error page in place of the page.
///
/// - `mailto:`, `tel:`, `sms:`, `facetime:` from a click open straight away.
/// - Any other scheme asks first ("Open “Zoom”?"), as Safari does; a hidden frame without a click
///   can't start an app at all.
/// - A scheme nothing on this Mac opens says so (from a click), instead of breaking the page.
enum ExternalLinks {
  /// Schemes WebKit loads in the page, and den's own (`den-action:`, the buttons of sitepolicy's
  /// interstitial pages, handled by its navigation policy).
  static let webSchemes: Set<String> = ["http", "https", "about", "data", "blob", "file", "javascript", "webkit-extension", "ws", "wss", "den-action"]
  /// Opened without asking when the user clicked them.
  static let direct: Set<String> = ["mailto", "tel", "sms", "facetime", "facetime-audio"]

  static func isExternal(_ url: URL) -> Bool {
    guard let s = url.scheme?.lowercased(), !s.isEmpty else { return false }
    return !webSchemes.contains(s)
  }

  /// The handling app's name ("Mail"), or nil when no app opens the link.
  @MainActor static var appName: (URL) -> String? = { url in
    guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
    let name = FileManager.default.displayName(atPath: app.path)
    return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
  }

  /// Opens the link in its app (tests replace this: no app is ever launched by a test).
  @MainActor static var open: (URL) -> Void = { NSWorkspace.shared.open($0) }
}

extension WebViewsService {
  /// A navigation (or `window.open`) to a non-web scheme. The caller has cancelled it.
  func openExternal(_ url: URL, from webView: WKWebView, userInitiated: Bool, mainFrame: Bool) {
    let scheme = url.scheme?.lowercased() ?? ""
    let site = webView.url?.host ?? ""
    guard let app = ExternalLinks.appName(url) else {
      guard userInitiated, let prompts else { return }
      prompts.noApp(scheme: scheme, webView: webView)
      return
    }
    if userInitiated, ExternalLinks.direct.contains(scheme) { return ExternalLinks.open(url) }
    // A hidden frame (an ad, a tracker) never starts an app by itself.
    guard userInitiated || mainFrame, let prompts else { return }
    prompts.openApp(app, site: site, webView: webView) { ok in if ok { ExternalLinks.open(url) } }
  }
}

extension WebPrompts {
  /// Safari's "Do you want to allow this page to open “App”?".
  func openApp(_ app: String, site: String, webView: WKWebView, done: @escaping (Bool) -> Void) {
    enqueue(["title": .string("Open “\(app)”?"), "message": .string("\(site.isEmpty ? "This page" : site) wants to open \(app)."),
             "icon": "sf:arrow.up.forward.app", "iconStyle": "accent",
             "buttons": [["id": "cancel", "title": "Cancel", "style": "cancel"], ["id": "open", "title": "Open", "style": "default"]]], webView,
            answer: { b, _ in done(b == "open") }, cancel: { done(false) })
  }

  /// A link no app on this Mac opens.
  func noApp(scheme: String, webView: WKWebView) {
    enqueue(["title": "den can’t open this link", "message": .string("No app on this Mac opens “\(scheme):” links."),
             "buttons": [["id": "ok", "title": "OK", "style": "default"]]], webView,
            answer: { _, _ in }, cancel: {})
  }
}
