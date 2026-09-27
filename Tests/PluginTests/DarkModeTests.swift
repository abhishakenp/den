import AppKit
import CordisValue
import Foundation
import Testing
import WebKit

@testable import DenHost
@testable import PluginCores

/// The `darkmode` plugin on the real `pagestyle` host service: rules, per-site modes, and real
/// WebKit pages (user stylesheet applied or not, tone detection, the natively-dark cache).
@MainActor
@Suite(.serialized)
struct DarkModeTests {
  func start(_ h: Harness) -> DarkModeCore {
    let core = DarkModeCore(env: h.env)
    h.rt.plugins.provide("darkmode") { m, a in core.handle(m, a) }
    core.start()
    return core
  }

  /// A web view in den's window (so it inherits the window's appearance) showing `html` at `base`.
  func page(_ h: Harness, _ id: String, _ html: String, _ base: String) async throws -> WKWebView {
    if h.rt.webviews.record(id) == nil { h.rt.call("webviews", "create", ["id": .string(id)]) }
    let w = h.rt.webviews.materialize(id)!
    w.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    if w.superview == nil { h.rt.window.window.contentView?.addSubview(w) }
    w.loadHTMLString(html, baseURL: URL(string: base))
    try await Task.sleep(for: .milliseconds(100))
    for _ in 0..<100 where w.isLoading { try await Task.sleep(for: .milliseconds(50)) }
    return w
  }

  func js(_ w: WKWebView, _ s: String) async -> String {
    (try? await w.evaluateJavaScript(s)).map { "\($0)" } ?? "error"
  }

  func waitTone(_ w: WKWebView, _ tone: String) async throws -> Bool {
    for _ in 0..<60 {
      if await js(w, "document.documentElement.getAttribute('data-den-tone')") == tone { return true }
      try await Task.sleep(for: .milliseconds(50))
    }
    return false
  }

  static let white = "<html><body style='margin:0'><p>white page</p><img src='data:image/gif;base64,R0lGODlhAQABAAAAACw='></body></html>"
  static let dark = "<html><body style='background:#111;color:#eee'><p>dark page</p></body></html>"
  static let filter = "getComputedStyle(document.documentElement).filter"

  @Test func rulesFollowSettingsAndSites() {
    let h = Harness()
    let core = start(h)
    let ps = h.rt.pageStyle
    #expect(ps.defaultRule.sheets == ["den.dark"] && ps.defaultRule.appearance == nil && ps.detect)
    #expect(h.rt.call("darkmode", "site", ["host": "https://www.News.ycombinator.com/x", "mode": "light"]) == ["ok": true])
    #expect(ps.rule(for: "news.ycombinator.com") == .init(sheets: ["den.light"], appearance: "light"))
    #expect(ps.rule(for: "sub.news.ycombinator.com").appearance == "light")  // parent domains match
    h.rt.call("darkmode", "site", ["host": "example.com", "mode": "dark"])
    #expect(ps.rule(for: "example.com") == .init(sheets: ["den.dark"], appearance: "dark"))
    h.rt.call("darkmode", "site", ["host": "example.com", "mode": "off"])
    #expect(ps.rule(for: "example.com") == .init(sheets: [], appearance: nil))
    h.rt.call("darkmode", "site", ["host": "example.com", "mode": "auto"])
    #expect(ps.rule(for: "example.com") == ps.defaultRule)
    #expect(h.storage("darkmode", "sites") == ["news.ycombinator.com": "light"])
    // Off for every site: no sheet by default, per-site choices still apply.
    #expect(h.rt.call("darkmode", "settings", ["enabled": false]) == ["enabled": false])
    #expect(ps.defaultRule.sheets.isEmpty && ps.rule(for: "news.ycombinator.com").sheets == ["den.light"])
    // Persisted: a new runtime starts with the same choices.
    let h2 = Harness(root: h.root)
    _ = start(h2)
    #expect(h2.rt.pageStyle.defaultRule.sheets.isEmpty && h2.rt.call("darkmode", "get", ["host": "news.ycombinator.com"])["mode"] == "light")
    core.stop()
    #expect(ps.defaultRule.sheets.isEmpty && !ps.detect)
  }

  @Test func commandsSetTheCurrentSite() {
    let h = Harness()
    var registered: [String] = []
    h.rt.plugins.provide("commands") { m, a in
      if m == "register" { registered.append(a.s("id")) }
      return ["ok": true]
    }
    h.rt.plugins.provide("tabs") { m, _ in m == "selected" ? ["id": "t1"] : .null }
    h.rt.call("webviews", "create", ["id": "t1", "url": "https://www.example.org/page"])
    _ = start(h)
    #expect(registered.count == 5 && registered.contains("darkmode.site.light"))
    h.rt.plugins.emit("commands.run", ["id": "darkmode.site.light"])
    #expect(h.rt.call("darkmode", "get", ["host": "example.org"])["mode"] == "light")
    #expect(h.rt.ui.toasts.count == 1)
    h.rt.plugins.emit("commands.run", ["id": "darkmode.toggle"])
    #expect(h.rt.call("darkmode", "get")["enabled"] == false)
  }

  @Test func darkDenInvertsLightPagesOnly() async throws {
    let h = Harness()
    h.rt.window.window.appearance = NSAppearance(named: .darkAqua)
    _ = start(h)
    var tones: [Value] = []
    h.rt.plugins.on("pagestyle.tone") { tones.append($0) }
    let w = try await page(h, "p1", Self.white, "https://white.test/")
    #expect(await js(w, "matchMedia('(prefers-color-scheme: dark)').matches") == "1")
    #expect(try await waitTone(w, "light"))
    #expect(await js(w, Self.filter).contains("invert(1)"))
    #expect(await js(w, "getComputedStyle(document.querySelector('img')).filter").contains("invert(1)"))  // images back
    #expect(h.rt.call("pagestyle", "get", ["id": "p1"])["sheets"] == ["den.dark"])
    // A natively dark page: detected, not inverted, remembered.
    let d = try await page(h, "p2", Self.dark, "https://dark.test/")
    #expect(try await waitTone(d, "dark"))
    #expect(await js(d, Self.filter) == "none")
    #expect(tones.contains { $0.s("host") == "dark.test" && $0.s("tone") == "dark" && $0.b("dark") })
    #expect(h.storage("darkmode", "tones") == ["dark.test"])
    #expect(h.rt.pageStyle.rule(for: "dark.test").sheets.isEmpty)
    // Next visit: no sheet at all for that site.
    _ = try await page(h, "p2", Self.dark, "https://dark.test/again")
    #expect(h.rt.call("pagestyle", "get", ["id": "p2"])["sheets"] == [])
    // Light den: the same white page is left alone (the sheet is inside a dark media query).
    h.rt.window.window.appearance = NSAppearance(named: .aqua)
    try await Task.sleep(for: .milliseconds(100))
    #expect(await js(w, Self.filter) == "none")
  }

  @Test func alwaysLightInvertsADarkOnlySite() async throws {
    let h = Harness()
    h.rt.window.window.appearance = NSAppearance(named: .darkAqua)
    _ = start(h)
    h.rt.call("darkmode", "site", ["host": "dark.test", "mode": "light"])
    let d = try await page(h, "p3", Self.dark, "https://dark.test/")
    #expect(d.appearance?.name == .aqua)
    #expect(await js(d, "matchMedia('(prefers-color-scheme: dark)').matches") == "0")
    #expect(try await waitTone(d, "dark"))
    #expect(await js(d, Self.filter).contains("invert(1)"))
    // Off: nothing applied, appearance follows den again; applied live, no reload.
    h.rt.call("darkmode", "site", ["host": "dark.test", "mode": "off"])
    #expect(d.appearance == nil)
    #expect(await js(d, Self.filter) == "none")
  }

  /// Google refuses sign-in from WKWebView's default user agent (no `Version/… Safari/…`); den
  /// sends exactly Safari's.
  @Test func userAgentIsSafaris() async throws {
    let h = Harness()
    let w = try await page(h, "ua", "<html></html>", "https://ua.test/")
    let ua = await js(w, "navigator.userAgent")
    let safari = (NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist")?["CFBundleShortVersionString"] as? String) ?? "?"
    #expect(ua == "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safari) Safari/605.1.15")
  }
}
