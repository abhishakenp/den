import AppKit
import WebKit

/// den's page for a load that failed before anything arrived (offline, unknown host, bad
/// certificate, timeout), instead of WebKit's blank view. It is loaded with
/// `loadSimulatedRequest` for the failed URL, so the tab keeps that URL: Reload, the "Try Again"
/// button and Back/Forward retry the real page. Calm and small, like Arc's: an icon, a title, one
/// line of explanation and a button, light or dark with the system (`prefers-color-scheme`).
enum WebErrorPage {
  struct Page: Equatable {
    let kind: String  // offline | host | secure | timeout | refused | other
    let title: String
    let message: String
    let symbol: String  // an emoji-free inline SVG name below
  }

  /// nil for failures that aren't the user's problem to see: a navigation that was cancelled or
  /// replaced (NSURLErrorCancelled, WebKit's "frame load interrupted" 102 and "plug-in handled
  /// load" 204), or one a link rule cancelled.
  static func page(for error: Error, url: URL?) -> Page? {
    let e = error as NSError
    if e.domain == NSURLErrorDomain, e.code == NSURLErrorCancelled { return nil }
    if e.domain == "WebKitErrorDomain", e.code == 102 || e.code == 204 { return nil }
    let host = url?.host ?? "this site"
    guard e.domain == NSURLErrorDomain else {
      return Page(kind: "other", title: "This page couldn’t load", message: e.localizedDescription, symbol: "warn")
    }
    switch e.code {
    case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff:
      return Page(kind: "offline", title: "You’re offline", message: "Check your Wi‑Fi or network connection, then try again.", symbol: "wifi")
    case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
      return Page(kind: "host", title: "Can’t find \(host)", message: "Check the address for typos. The site may also be down, or not exist.", symbol: "search")
    case NSURLErrorTimedOut:
      return Page(kind: "timeout", title: "\(host) is taking too long", message: "The site didn’t answer in time. It may be busy or down.", symbol: "clock")
    case NSURLErrorCannotConnectToHost:
      return Page(kind: "refused", title: "Can’t connect to \(host)", message: "The site refused the connection. It may be down.", symbol: "warn")
    case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
         NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
         NSURLErrorClientCertificateRequired, NSURLErrorAppTransportSecurityRequiresSecureConnection:
      return Page(kind: "secure", title: "This connection isn’t private", message: "\(host) couldn’t prove it’s the real site, so den stopped before sending anything.", symbol: "lock")
    default:
      return Page(kind: "other", title: "Can’t open \(host)", message: e.localizedDescription, symbol: "warn")
    }
  }

  static func escape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
  }

  static let icons: [String: String] = [
    "wifi": "<path d='M5 12.5a10 10 0 0 1 14 0M8.5 16a5 5 0 0 1 7 0'/><circle cx='12' cy='19.5' r='1' fill='currentColor' stroke='none'/><path d='M3 3l18 18'/>",
    "search": "<circle cx='11' cy='11' r='6.5'/><path d='M16 16l4.5 4.5'/>",
    "clock": "<circle cx='12' cy='12' r='8.5'/><path d='M12 7.5V12l3 2'/>",
    "lock": "<rect x='5.5' y='10.5' width='13' height='9.5' rx='2.5'/><path d='M8.5 10.5V8a3.5 3.5 0 0 1 7 0v2.5'/>",
    "warn": "<path d='M12 4l9 15.5H3z'/><path d='M12 10v4.5'/><circle cx='12' cy='17.3' r='.8' fill='currentColor' stroke='none'/>",
  ]

  /// The current space's colors as CSS values (from den's `Palette`), so the page matches the
  /// window. Without them the page falls back to neutral light/dark via `prefers-color-scheme`.
  struct Colors: Equatable {
    var background, text, secondary, accent, onAccent: String
    var dark: Bool
  }

  /// `rgba(r,g,b,a)` for CSS.
  static func css(_ c: NSColor) -> String {
    let s = c.usingColorSpace(.sRGB) ?? c
    return String(format: "rgba(%d,%d,%d,%.3f)", Int((s.redComponent * 255).rounded()), Int((s.greenComponent * 255).rounded()), Int((s.blueComponent * 255).rounded()), s.alphaComponent)
  }

  static func html(_ p: Page, url: URL?, colors: Colors? = nil) -> String {
    let icon = icons[p.symbol] ?? icons["warn"]!
    let shown = url.map { escape($0.absoluteString) } ?? ""
    let vars: String
    if let c = colors {
      vars = ":root{color-scheme:\(c.dark ? "dark" : "light");--bg:\(c.background);--fg:\(c.text);--sub:\(c.secondary);--pill:\(c.accent);--on:\(c.onAccent);--icon:\(c.secondary)}"
    } else {
      vars = """
        :root{--bg:#f7f7f9;--fg:rgba(14,15,16,.9);--sub:rgba(0,0,0,.5);--pill:#3139fb;--on:#fff;--icon:rgba(0,0,0,.35)}
        @media (prefers-color-scheme:dark){:root{--bg:#1c1b22;--fg:rgba(255,255,255,.85);--sub:rgba(255,255,255,.5);--icon:rgba(255,255,255,.35)}}
        """
    }
    return """
      <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
      <title>\(escape(p.title))</title>
      <style>
      \(vars)
      html,body{height:100%;margin:0}
      body{background:var(--bg);color:var(--fg);font:13px -apple-system,system-ui,sans-serif;display:flex;align-items:center;justify-content:center;-webkit-user-select:none}
      main{max-width:420px;padding:32px;text-align:center}
      svg{width:44px;height:44px;color:var(--icon);fill:none;stroke:currentColor;stroke-width:1.6;stroke-linecap:round;stroke-linejoin:round}
      h1{font-size:20px;font-weight:600;margin:18px 0 8px;letter-spacing:-.01em}
      p{margin:0;color:var(--sub);line-height:1.45}
      .url{margin-top:6px;font-size:12px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;-webkit-user-select:text}
      button{margin-top:22px;border:0;border-radius:6px;background:var(--pill);color:var(--on);font:13px -apple-system,system-ui;padding:9px 16px;cursor:default}
      button:active{filter:brightness(.9)}
      </style></head><body data-den-error="\(p.kind)"><main>
      <svg viewBox="0 0 24 24" aria-hidden="true">\(icon)</svg>
      <h1>\(escape(p.title))</h1><p>\(escape(p.message))</p><p class="url">\(shown)</p>
      <button id="retry" onclick="location.reload()">Try Again</button>
      </main></body></html>
      """
  }
}
