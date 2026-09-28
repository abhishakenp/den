import AppKit
import CordisValue
import WebKit

// thin-host: feature-specific, migrate to plugin: the error copy and page HTML belong to a plugin;
// the host keeps "a navigation failed" as an event and a way to show a page for it.
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
    var button = "Try Again"
  }

  /// The page for a tab whose web process died (Dia 0.45): calm, one button, no auto-reload
  /// (a page that keeps crashing must not loop).
  static let crashed = Page(kind: "crashed", title: "This page crashed", message: "Its web content stopped unexpectedly. Reload to try again.",
                            symbol: "crash", button: "Reload")

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

  /// Kinds that get a "View on the Web Archive" link: the site itself is missing, down or silent,
  /// so an archived copy is the next best thing. Not `offline` (the archive is unreachable too),
  /// not `secure` (a certificate error may be someone on the network; den doesn't route around
  /// it), not `crashed` or `other`.
  static let archiveKinds: Set<String> = ["host", "timeout", "refused"]

  /// The Wayback Machine's latest capture of `url` (`/web/2/` redirects to the newest snapshot),
  /// for http(s) pages whose error kind is in `archiveKinds`; nil otherwise.
  static func archiveURL(_ p: Page, url: URL?) -> String? {
    guard archiveKinds.contains(p.kind), let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
    return "https://web.archive.org/web/2/" + url.absoluteString
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
    "shield": "<path d='M12 3.5l7 2.8v5.2c0 4.4-3 7.9-7 9-4-1.1-7-4.6-7-9V6.3z'/><path d='M12 8.5v4.5'/><circle cx='12' cy='16' r='.8' fill='currentColor' stroke='none'/>",
    "crash": "<rect x='3.5' y='4.5' width='17' height='15' rx='2.5'/><path d='M3.5 8.5h17'/><path d='M9.5 12.5l5 4.5M14.5 12.5l-5 4.5'/>",
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

  /// A plugin-worded interstitial (`sitepolicy.interstitial`): the error page's look with up to
  /// three buttons. `page`: `{kind, icon: lock|warn|search|clock|wifi|shield, title, message,
  /// detail?, url?, buttons: [{id, title, style: primary|secondary, key?: "return"|"escape"}]}`.
  /// A button is a link to `den-action:<id>`, which `sitepolicy` turns into
  /// `sitepolicy.interstitialAction`; its key (↩ or esc) is shown on it as a keycap.
  static func interstitial(_ page: Value, colors: Colors? = nil) -> String {
    let icon = icons[page.str("icon")] ?? icons["warn"]!
    var buttons = ""
    for b in page.list("buttons").prefix(3) {
      let id = b.str("id").filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
      let key = b.str("key")
      let cap = key == "return" ? "<kbd>↩</kbd>" : key == "escape" ? "<kbd>esc</kbd>" : ""
      let cls = b.str("style") == "primary" ? "primary" : "secondary"
      buttons += "<a class=\"btn \(cls)\" href=\"den-action:\(id)\" data-key=\"\(escape(key))\">\(escape(b.str("title")))\(cap)</a>"
    }
    let detail = page.str("detail").isEmpty ? "" : "<p class=\"detail\">\(escape(page.str("detail")))</p>"
    let shown = page.str("url").isEmpty ? "" : "<p class=\"url\">\(escape(page.str("url")))</p>"
    return """
      <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
      <title>\(escape(page.str("title")))</title>
      <style>
      \(vars(colors))
      html,body{height:100%;margin:0}
      body{background:var(--bg);color:var(--fg);font:13px -apple-system,system-ui,sans-serif;display:flex;align-items:center;justify-content:center;-webkit-user-select:none}
      main{max-width:440px;padding:32px;text-align:center}
      svg{width:44px;height:44px;color:var(--icon);fill:none;stroke:currentColor;stroke-width:1.6;stroke-linecap:round;stroke-linejoin:round}
      h1{font-size:20px;font-weight:600;margin:18px 0 8px;letter-spacing:-.01em}
      p{margin:0;color:var(--sub);line-height:1.45}
      .detail{margin-top:8px}
      .url{margin-top:6px;font-size:12px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;-webkit-user-select:text}
      .buttons{margin-top:22px;display:flex;gap:8px;justify-content:center;flex-wrap:wrap}
      .btn{display:inline-flex;align-items:center;gap:8px;border-radius:6px;font:13px -apple-system,system-ui;padding:8px 14px;text-decoration:none;cursor:default}
      .primary{background:var(--pill);color:var(--on)}
      .secondary{color:var(--fg);box-shadow:inset 0 0 0 1px var(--line)}
      .btn:active{filter:brightness(.9)}
      kbd{font:11px -apple-system,system-ui;padding:1px 5px;border-radius:4px;background:var(--line)}
      .primary kbd{background:rgba(255,255,255,.22)}
      </style></head><body data-den-interstitial="\(escape(page.str("kind")))"><main>
      <svg viewBox="0 0 24 24" aria-hidden="true">\(icon)</svg>
      <h1>\(escape(page.str("title")))</h1><p>\(escape(page.str("message")))</p>\(detail)\(shown)
      <div class="buttons">\(buttons)</div>
      </main><script>
      addEventListener('keydown',e=>{const k=e.key==='Enter'?'return':e.key==='Escape'?'escape':'';if(!k)return;
      const b=document.querySelector('.btn[data-key="'+k+'"]');if(b){e.preventDefault();b.click()}});
      </script></body></html>
      """
  }

  /// CSS variables: the space's palette, else neutral light/dark via `prefers-color-scheme`.
  static func vars(_ colors: Colors?) -> String {
    if let c = colors {
      return ":root{color-scheme:\(c.dark ? "dark" : "light");--bg:\(c.background);--fg:\(c.text);--sub:\(c.secondary);--pill:\(c.accent);--on:\(c.onAccent);--icon:\(c.secondary);--line:\(c.dark ? "rgba(255,255,255,.18)" : "rgba(0,0,0,.14)")}"
    }
    return """
      :root{--bg:#f7f7f9;--fg:rgba(14,15,16,.9);--sub:rgba(0,0,0,.5);--pill:#3139fb;--on:#fff;--icon:rgba(0,0,0,.35);--line:rgba(0,0,0,.14)}
      @media (prefers-color-scheme:dark){:root{--bg:#1c1b22;--fg:rgba(255,255,255,.85);--sub:rgba(255,255,255,.5);--icon:rgba(255,255,255,.35);--line:rgba(255,255,255,.18)}}
      """
  }

  static func html(_ p: Page, url: URL?, colors: Colors? = nil) -> String {
    let icon = icons[p.symbol] ?? icons["warn"]!
    let shown = url.map { escape($0.absoluteString) } ?? ""
    let archive = archiveURL(p, url: url).map { "<p class=\"archive\"><a id=\"archive\" href=\"\(escape($0))\">View on the Web Archive</a></p>" } ?? ""
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
      .archive{margin-top:14px;font-size:12px}
      .archive a{color:var(--sub);text-decoration:underline;text-underline-offset:2px;cursor:default}
      .archive a:hover{color:var(--fg)}
      </style></head><body data-den-error="\(p.kind)"><main>
      <svg viewBox="0 0 24 24" aria-hidden="true">\(icon)</svg>
      <h1>\(escape(p.title))</h1><p>\(escape(p.message))</p><p class="url">\(shown)</p>
      <button id="retry" onclick="location.reload()">\(escape(p.button))</button>\(archive)
      </main></body></html>
      """
  }
}
