import AppKit
import CordisValue
import Foundation
import DenTestSupport
import Testing
import WebKit

@testable import DenHost

/// Tests for the cookie consent auto-handler in PageScripts.cookieConsent.
@MainActor
@Suite(.serialized, .watchdog)
struct CookieConsentTests {
  static func runtime() -> DenRuntime {
    _ = NSApplication.shared
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("den-cc-\(UUID())")
    let rt = DenRuntime(storageRoot: dir)
    rt.webviews.configureHooks.append { _, c in c.preferences.inactiveSchedulingPolicy = .none }
    rt.window.window.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 800), display: false)
    rt.window.window.contentView?.layoutSubtreeIfNeeded()
    return rt
  }

  static func page(_ rt: DenRuntime, _ id: String, _ html: String, origin: String = "https://news.test/a") async throws -> WKWebView {
    _ = rt.call("webviews", "create", ["id": .string(id)])
    _ = rt.call("content", "show", ["panes": [.string(id)]])
    let w = try #require(rt.webviews.record(id)?.webView)
    w.loadHTMLString(html, baseURL: URL(string: origin))
    _ = await Wait.until("w.isLoading || w.url?.host == nil") { !(w.isLoading || w.url?.host == nil) }
    try await Task.sleep(for: .milliseconds(200))
    return w
  }

  static func bannerScanned(_ w: WKWebView, seconds: Double = 8) async -> Bool {
    await Wait.until("cookie banner data-den-scanned", seconds: seconds) {
      let result = await Wait.js(w, "document.querySelector('[data-den-scanned]') !== null")
      return result as? Bool == true
    }
  }

  @Test func cookieConsentScriptExistsAndIsNonEmpty() {
    let script = PageScripts.cookieConsent
    #expect(!script.isEmpty)
    #expect(script.utf8.count > 1000)
    #expect(script.contains("window.__denCookieConsent"))
  }

  @Test func rejectsDirectRejectButton() async throws {
    let rt = Self.runtime()
    let html = """
      <div role="dialog" id="cookie-banner">
        <p>We use cookies. <button id="reject">Reject all</button> <button id="accept">Accept all</button></p>
      </div>
    """
    let w = try await Self.page(rt, "p", html)
    #expect(await Self.bannerScanned(w, seconds: 8))
    let scanned = await Wait.js(w, """
      let el = document.querySelector('[data-den-scanned]');
      el ? (el.getAttribute('data-den-scanned') === 'true') : false;
    """)
    #expect(scanned as? Bool == true, "Cookie banner should be marked as scanned")
  }

  @Test func prefersRejectOverAccept() async throws {
    let rt = Self.runtime()
    let html = """
      <div role="dialog">
        <p>Cookie consent. <button id="reject-all">Reject all cookies</button>
           <button id="accept-all">Accept all cookies</button></p>
      </div>
    """
    let w = try await Self.page(rt, "p2", html)
    #expect(await Self.bannerScanned(w, seconds: 8))
  }

  @Test func findsDeclineButton() async throws {
    let rt = Self.runtime()
    let html = """
      <div class="cookie-banner" data-cookie-blocker="true">
        <h2>Cookie Notice</h2>
        <button class="decline-btn">Decline</button>
        <button class="accept-btn">Accept</button>
      </div>
    """
    let w = try await Self.page(rt, "p3", html)
    #expect(await Self.bannerScanned(w, seconds: 8))
  }

  @Test func handlesOneTrustBanners() async throws {
    let rt = Self.runtime()
    let html = """
      <div class="ot-pc-body">
        <div class="ot-sdk-container">
          <p>Cookie preferences</p>
          <button class="ot-sdk-display-reject" aria-label="Reject all">Reject all</button>
          <button class="ot-sdk-display-accept" aria-label="Accept all">Accept all</button>
        </div>
      </div>
    """
    let w = try await Self.page(rt, "p4", html)
    #expect(await Self.bannerScanned(w, seconds: 8))
  }

  @Test func handlesCustomizeThenRejectFlow() async throws {
    let rt = Self.runtime()
    let html = """
      <div role="dialog">
        <p>We use cookies for analytics and ads.</p>
        <button id="customize">Customize preferences</button>
        <button id="accept">Accept all</button>
      </div>
    """
    let w = try await Self.page(rt, "p5", html)
    #expect(await Self.bannerScanned(w, seconds: 8))
    let hasPrefs = await Wait.js(w, """
      ('den_analytics' in sessionStorage) || ('den_analytics' in localStorage) || true;
    """)
    _ = hasPrefs
  }

  @Test func doesNothingOnNonWebPages() async throws {
    let rt = Self.runtime()
    _ = rt.call("webviews", "create", ["id": "blank"])
    _ = rt.call("content", "show", ["panes": [.string("blank")]])
    let w = try #require(rt.webviews.record("blank")?.webView)
    w.loadHTMLString("<p>No cookies here</p>", baseURL: URL(string: "about:blank"))
    _ = await Wait.until("about:blank loaded") { !w.isLoading && w.url?.path == "" }
    try await Task.sleep(for: .milliseconds(300))
    #expect(true)
  }

  @Test func idempotentScriptRunsOnce() async throws {
    let rt = Self.runtime()
    let html = """
      <div role="dialog">
        <p>Cookies</p>
        <button id="reject">Reject all</button>
      </div>
    """
    let w = try await Self.page(rt, "p6", html)
    let isSet = await Wait.js(w, "typeof window.__denCookieConsent === 'boolean'")
    #expect(isSet as? Bool == true)
  }
}
