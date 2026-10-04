import AppKit
import Security
import WebKit

/// Universal links, like Safari but never silently: an https link a native app on this Mac claims
/// (its `com.apple.developer.associated-domains` lists `applinks:<host>`) asks first,
/// "Open in “App”?", with Stay in den / Open App and "Always for this site" (remembered until den
/// quits). Only for a link the user clicked, in the main frame, to another site (Safari never
/// leaves for an app on a same-site link). "Open" goes through `NSWorkspace` with
/// `requiresUniversalLinks`, so macOS itself confirms the claim (the site's
/// apple-app-site-association); when it refuses, the link opens in den.
///
/// LaunchServices lists only browsers for https (measured on macOS 26: every https URL, Spotify and
/// Slack links included, maps to the browsers), so the claims come from the apps' signatures:
/// /Applications, ~/Applications and /System/Applications are read once, in the background, a few
/// seconds after launch (0.6–0.9 s for ~60 apps, measured).
@MainActor
enum UniversalLinks {
  /// Host pattern (`example.com`, `*.example.com`) -> app name.
  static var claims: [String: String]?
  /// "<host>" -> true (open the app) / false (stay), for this session ("Always for this site").
  static var decisions: [String: Bool] = [:]
  private static var scanning = false

  /// Opens `url` in the app that claims it; `done(false)` when macOS doesn't (tests replace this).
  static var open: (URL, @escaping @MainActor (Bool) -> Void) -> Void = { url, done in
    let c = NSWorkspace.OpenConfiguration()
    c.requiresUniversalLinks = true
    NSWorkspace.shared.open(url, configuration: c) { app, error in
      let ok = app != nil && error == nil
      DispatchQueue.main.async { done(ok) }
    }
  }

  /// Reads the installed apps' claims once, off the main thread.
  static func scanSoon(after seconds: Double = 5) {
    guard claims == nil, !scanning else { return }
    scanning = true
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
      let found = scan()
      DispatchQueue.main.async { MainActor.assumeIsolated { claims = found; scanning = false } }
    }
  }

  nonisolated static func scan() -> [String: String] {
    var out: [String: String] = [:]
    let fm = FileManager.default
    let dirs = ["/Applications", fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path, "/System/Applications"]
    let me = Bundle.main.bundleURL.standardizedFileURL
    for dir in dirs {
      for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".app") {
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
        guard url.standardizedFileURL != me else { continue }
        for host in appLinks(url) where out[host] == nil { out[host] = String(name.dropLast(4)) }
      }
    }
    return out
  }

  /// `applinks:` hosts in an app's signed entitlements (`?mode=…` dropped).
  nonisolated static func appLinks(_ app: URL) -> [String] {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return [] }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation), &info) == errSecSuccess,
          let d = info as? [String: Any], let ent = d[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
          let domains = ent["com.apple.developer.associated-domains"] as? [String] else { return [] }
    return domains.compactMap { e in
      guard e.hasPrefix("applinks:") else { return nil }
      let h = e.dropFirst("applinks:".count).split(separator: "?").first.map(String.init) ?? ""
      return h.isEmpty ? nil : h.lowercased()
    }
  }

  /// The app claiming `host`: an exact pattern, or `*.<parent>` for a subdomain (Apple's rule: the
  /// wildcard doesn't cover the parent itself).
  static func app(for host: String) -> String? {
    guard let claims, !host.isEmpty else { return nil }
    let h = host.lowercased()
    if let a = claims[h] { return a }
    var rest = h
    while let dot = rest.firstIndex(of: ".") {
      rest = String(rest[rest.index(after: dot)...])
      if let a = claims["*." + rest] { return a }
    }
    return nil
  }

  /// Same site for Safari's purposes: the hosts match once `www.` is dropped.
  static func sameSite(_ a: String?, _ b: String?) -> Bool {
    func k(_ s: String?) -> String { let s = (s ?? "").lowercased(); return s.hasPrefix("www.") ? String(s.dropFirst(4)) : s }
    return k(a) == k(b)
  }
}

extension WebViewsService {
  /// A clicked link to another site that an app claims: asks, and returns true when it took the
  /// navigation (the caller cancels it). Links the user let through (`r.passUniversal`) go on.
  func universalLink(_ r: WebRecord, _ webView: WKWebView, _ action: WKNavigationAction, target: URL, mainFrame: Bool) -> Bool {
    if r.passUniversal == target { r.passUniversal = nil; return false }
    guard mainFrame, action.navigationType == .linkActivated, target.scheme?.lowercased() == "https", Self.isUserInitiated(action),
          let host = target.host, !UniversalLinks.sameSite(host, webView.url?.host), let app = UniversalLinks.app(for: host) else { return false }
    let newTab = action.targetFrame == nil
    let stay = { [weak self, weak webView] in
      guard let self else { return }
      if newTab {
        self.host.emit("webviews.newWindow", ["id": .string(r.id), "url": .string(target.absoluteString)])
      } else {
        r.passUniversal = target
        webView?.load(URLRequest(url: target))
      }
    }
    let go = { UniversalLinks.open(target) { ok in if !ok { stay() } } }
    if let d = UniversalLinks.decisions[host] {
      DispatchQueue.main.async { if d { go() } else { stay() } }
      return true
    }
    guard let prompts else { return false }
    prompts.openUniversal(app, host: host, webView: webView) { open, always in
      if always { UniversalLinks.decisions[host] = open }
      if open { go() } else { stay() }
    }
    return true
  }
}

extension WebPrompts {
  /// "Open in “App”?" for a universal link: Stay in den (Esc) or Open App, and "Always for this site".
  func openUniversal(_ app: String, host: String, webView: WKWebView, done: @escaping (Bool, Bool) -> Void) {
    enqueue(["title": .string("Open in “\(app)”?"), "message": .string("\(app) can open links to \(host)."),
             "icon": "sf:arrow.up.forward.app", "iconStyle": "accent",
             "checkbox": ["id": "always", "title": "Always for this site", "checked": false],
             "buttons": [["id": "stay", "title": "Stay in den", "style": "cancel"], ["id": "open", "title": .string("Open \(app)"), "style": "default"]]], webView,
            answer: { b, f in done(b == "open", f[Self.checkedKey] == "1") }, cancel: { done(false, false) })
  }
}
