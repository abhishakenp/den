import AppKit
import WebKit

/// WebKit's Web Inspector and the Develop menu's page tools, for any WKWebView.
///
/// WebKit has no public call that *opens* the inspector (`isInspectable` only lets Safari's
/// Develop menu attach), so this uses WKWebView's private `_inspector` (a `_WKInspector`:
/// `show`, `close`, `showConsole`, `toggleElementSelection`, `isVisible`,
/// `isElementSelectionActive`, `inspectorWebView`), every selector checked with `responds(to:)`
/// first: a WebKit without one makes the call fail, never crash. The inspector opens docked at the
/// bottom of the page's card (WebKit's default "starts attached"); its view is the page's sibling
/// in the card (`CardView` leaves it to WebKit's layout, `ContentService` moves it with the page).
///
/// "Inspect Element" in a page's context menu, and the inspector itself, need WebKit's
/// `developerExtrasEnabled` preference (private `_setDeveloperExtrasEnabled:`), set on every den
/// web view (`enableDeveloperExtras`).
@MainActor
enum DevTools {
  static func inspector(_ w: WKWebView) -> NSObject? {
    let getter = NSSelectorFromString("_inspector")
    guard w.responds(to: getter) else { return nil }
    return w.perform(getter)?.takeUnretainedValue() as? NSObject
  }

  private static func flag(_ o: NSObject, _ name: String) -> Bool {
    guard o.responds(to: NSSelectorFromString(name)) else { return false }
    return (o.value(forKey: name) as? NSNumber)?.boolValue ?? false
  }

  @discardableResult
  private static func send(_ o: NSObject, _ name: String) -> Bool {
    let sel = NSSelectorFromString(name)
    guard o.responds(to: sel) else { return false }
    o.perform(sel)
    return true
  }

  /// The inspector is open for `w` (docked or in its own window).
  static func isOpen(_ w: WKWebView) -> Bool { inspector(w).map { flag($0, "isVisible") } ?? false }

  static func isSelectingElement(_ w: WKWebView) -> Bool { inspector(w).map { flag($0, "isElementSelectionActive") } ?? false }

  /// Opens the inspector (`console`: on its Console tab). False when WebKit has no entry point.
  @discardableResult
  static func show(_ w: WKWebView, console: Bool = false) -> Bool {
    w.isInspectable = true
    guard let i = inspector(w) else { return false }
    return send(i, console ? "showConsole" : "show")
  }

  @discardableResult
  static func close(_ w: WKWebView) -> Bool {
    guard let i = inspector(w) else { return false }
    return send(i, "close")
  }

  /// ⌥⌘I: opens the inspector, or closes it when it is open. Returns whether it is open now.
  @discardableResult
  static func toggle(_ w: WKWebView) -> Bool? {
    if isOpen(w) { return close(w) ? false : nil }
    return show(w) ? true : nil
  }

  /// ⌥⌘C: opens the inspector with its element picker on (a second press turns the picker off).
  @discardableResult
  static func selectElement(_ w: WKWebView) -> Bool {
    guard show(w), let i = inspector(w) else { return false }
    return send(i, "toggleElementSelection")
  }

  /// The inspector's own web view while it is docked in a card (WebKit puts it next to the page,
  /// in the page's superview): nil while closed, or undocked in a window of its own.
  static func dockedView(_ w: WKWebView) -> NSView? {
    guard let i = inspector(w), flag(i, "isVisible"), i.responds(to: NSSelectorFromString("inspectorWebView")),
          let v = i.value(forKey: "inspectorWebView") as? NSView else { return nil }
    return v.superview?.superview is CardView ? v : nil
  }

  /// Whether `v` is a docked inspector's web view (WebKit's `WKInspectorWKWebView`), which WebKit
  /// lays out next to the page itself.
  static func isInspectorView(_ v: NSView) -> Bool { NSStringFromClass(type(of: v)).hasPrefix("WKInspector") }

  /// WebKit's `developerExtrasEnabled`: the context menu's Inspect Element and the inspector.
  static func enableDeveloperExtras(_ p: WKPreferences) {
    if p.responds(to: NSSelectorFromString("_setDeveloperExtrasEnabled:")) { p.setValue(true, forKey: "developerExtrasEnabled") }
  }

  // MARK: Caches

  /// Develop ▸ Empty Caches: the memory, disk and fetch caches of `stores` (cookies, storage and
  /// history stay).
  static let cacheTypes: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache]

  static func emptyCaches(_ stores: [WKWebsiteDataStore], then: @escaping @MainActor () -> Void) {
    Task { @MainActor in
      for s in stores { await s.removeData(ofTypes: cacheTypes, modifiedSince: .distantPast) }
      then()
    }
  }

  // MARK: User agent

  /// Develop ▸ User Agent presets (Safari's list, plus Chrome, Firefox and Edge).
  struct Agent { let id: String; let title: String; let ua: String }

  nonisolated static let agents: [Agent] = {
    let chrome = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"
    return [
      Agent(id: "safari-mac", title: "Safari — macOS", ua: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"),
      Agent(id: "safari-iphone", title: "Safari — iPhone", ua: WebViewsService.mobileUserAgent),
      Agent(id: "safari-ipad", title: "Safari — iPad", ua: "Mozilla/5.0 (iPad; CPU OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"),
      Agent(id: "chrome-mac", title: "Google Chrome — macOS", ua: chrome),
      Agent(id: "chrome-android", title: "Google Chrome — Android", ua: "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36"),
      Agent(id: "edge-mac", title: "Microsoft Edge — macOS", ua: chrome + " Edg/141.0.0.0"),
      Agent(id: "firefox-mac", title: "Firefox — macOS", ua: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:143.0) Gecko/20100101 Firefox/143.0"),
    ]
  }()

  /// `preset` id, `""`/"default" (den's own), or a full user agent string.
  nonisolated static func userAgent(for preset: String) -> String? {
    if preset.isEmpty || preset == "default" { return nil }
    if preset == "mobile" { return WebViewsService.mobileUserAgent }
    return agents.first { $0.id == preset }?.ua ?? preset
  }
}
