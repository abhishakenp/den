import AppKit
import CordisValue
import DenTestSupport
import Foundation
import Testing
import WebKit

@testable import DenHost

/// Pop-ups like Safari (Popups.swift), against a local fixture: an opener page on 127.0.0.1 and a
/// "sign-in" page on localhost (another origin, as an OAuth provider is), which posts a message to
/// its opener. `evaluateJavaScript` runs as a user gesture (WebKit), so it stands in for a click;
/// a page's own timer after load is not one.
@MainActor
@Suite(.serialized, .watchdog)
struct PopupTests {
  static func fixture() throws -> MockServices {
    let mock = MockServices()
    try mock.start()
    let popup = "http://localhost:\(mock.port)/signin"
    mock.page("/opener", """
      <!doctype html><title>Opener</title><script>
      window.got = [];
      addEventListener('message', e => window.got.push(e.origin + ' ' + e.data));
      function openPopup(features, name) { window.pop = window.open('\(popup)', name || '', features); return window.pop ? 'opened' : 'blocked'; }
      </script><p>opener</p>
      """)
    mock.page("/auto", """
      <!doctype html><title>Auto</title><script>
      window.r = 'pending';
      setTimeout(() => { window.r = window.open('\(popup)', '', 'width=400,height=500') ? 'opened' : 'blocked'; }, 30);
      </script>
      """)
    mock.page("/signin", """
      <!doctype html><title>Sign in</title><script>
      window.hasOpener = !!window.opener;
      if (window.opener) window.opener.postMessage('signed-in', '*');
      </script><p>provider</p>
      """)
    return mock
  }

  /// A shown opener page at `/<path>` in `profile`.
  static func opener(_ rt: DenRuntime, _ mock: MockServices, path: String = "/opener", profile: String = "default") async throws -> (String, WKWebView) {
    let id = rt.call("webviews", "create", ["url": .string(mock.base + path), "profile": .string(profile)])["id"].string!
    _ = rt.call("content", "show", ["panes": [.string(id)]])
    let w = try #require(rt.webviews.record(id)?.webView)
    try await until { !w.isLoading && w.url?.path == path }
    return (id, w)
  }

  static func until(_ seconds: Double = 60, line: UInt = #line, _ cond: () -> Bool) async throws {
    if await !Wait.until("a condition", seconds: seconds, line: line, { cond() }) { Issue.record("timed out waiting at line \(line)") }
  }

  static func popups(_ rt: DenRuntime, of opener: String) -> [WebRecord] { rt.webviews.records.values.filter { $0.opener == opener } }

  /// The OAuth shape (Google Identity Services, Sign in with Apple, GitHub): a click opens a sized
  /// pop-up window that keeps `window.opener`, posts back, and closes itself. Shields' default
  /// rule (`popups: block`) used to make WebKit refuse even this.
  @Test func clickedPopupWithFeaturesOpensARelatedWindowThatPostsBackAndCloses() async throws {
    let mock = try Self.fixture()
    defer { mock.stop() }
    let rt = ServiceTests.runtime()
    _ = rt.call("sitepolicy", "rules", ["default": ["popups": "block"]])
    var events: [Value] = []
    rt.host.on("webviews.popup") { events.append($0) }
    let (id, w) = try await Self.opener(rt, mock)
    #expect(await Wait.js(w, "openPopup('width=480,height=640,left=100,top=100')") as? String == "opened")
    try await Self.until { Self.popups(rt, of: id).count == 1 }
    let p = try #require(Self.popups(rt, of: id).first)
    #expect(p.id.hasPrefix("popup-") && p.popupWindow != nil && p.profile == "default")
    #expect(events.first?["id"].string == p.id && events.first?["opener"].string == id)
    let pw = try #require(p.webView)
    try await Self.until { pw.url?.host == "localhost" && !pw.isLoading }
    // The opener relationship: window.opener, postMessage across origins.
    #expect(await Wait.js(pw, "window.hasOpener") as? Bool == true)
    var got: [String] = []
    _ = await Wait.until("the pop-up's message to its opener", seconds: 60, every: .milliseconds(100)) {
      got = await Wait.js(w, "window.got") as? [String] ?? []
      return !got.isEmpty
    }
    #expect(got == ["http://localhost:\(mock.port) signed-in"])
    // A pop-up window of its own, sized as asked (content 480 wide), showing the provider's domain.
    let win = try #require(pw.window)
    #expect(win !== w.window)
    #expect(abs(win.frame.width - 480) < 1)
    #expect(rt.call("window", "listMini").array?.count == 1)
    // Same web process and data store as the opener.
    #expect(pw.configuration.websiteDataStore === w.configuration.websiteDataStore)
    #expect(WebViewsService.webProcessId(pw) == WebViewsService.webProcessId(w))
    // window.close() from the pop-up: the window and its page go.
    _ = await Wait.js(pw, "window.close(); 1")
    try await Self.until { rt.webviews.record(p.id) == nil }
    #expect(rt.call("window", "listMini").array?.isEmpty == true)
    #expect(rt.webviews.record(id)?.webView != nil)  // the opener stays
  }

  /// `target=_blank` / `window.open(url)` from a click: a tab (whoever listens to newWindow adopts
  /// the host's web view), still related to its opener; `window.close()` asks for the tab to close.
  @Test func clickedPlainOpenBecomesAnAdoptableTabRelatedToItsOpener() async throws {
    let mock = try Self.fixture()
    defer { mock.stop() }
    let rt = ServiceTests.runtime()
    var opened: Value = .null, closeAsked: Value = .null
    rt.host.on("webviews.newWindow") { opened = $0 }
    rt.host.on("webviews.closeRequested") { closeAsked = $0 }
    let (id, w) = try await Self.opener(rt, mock)
    #expect(await Wait.js(w, "openPopup('')") as? String == "opened")
    try await Self.until { !opened.isNull }
    let pid = try #require(opened["webview"].string)
    #expect(opened["id"].string == id && opened.str("url").hasSuffix("/signin"))
    let p = try #require(rt.webviews.record(pid))
    #expect(p.opener == id && p.popupWindow == nil)
    // The owner shows it (as the tabs plugin does): the existing view, not a new one.
    let pw = try #require(p.webView)
    _ = rt.call("content", "show", ["panes": [.string(pid)]])
    #expect(rt.webviews.record(pid)?.webView === pw)
    try await Self.until { pw.url?.host == "localhost" && !pw.isLoading }
    #expect(await Wait.js(pw, "window.hasOpener") as? Bool == true)
    _ = await Wait.js(pw, "window.close(); 1")
    try await Self.until { !closeAsked.isNull }
    #expect(closeAsked["id"].string == pid && closeAsked["opener"].string == id)
  }

  /// No click: blocked, with a notice (never silently), and `openBlocked` opens it; a site whose
  /// pop-ups are allowed opens them straight away.
  @Test func popupWithoutAClickIsBlockedWithANoticeAndCanBeOpened() async throws {
    let mock = try Self.fixture()
    defer { mock.stop() }
    let rt = ServiceTests.runtime()
    _ = rt.call("sitepolicy", "rules", ["default": ["popups": "block"]])
    var blocked: [Value] = []
    rt.host.on("webviews.popupBlocked") { blocked.append($0) }
    let (id, w) = try await Self.opener(rt, mock, path: "/auto")
    var r = ""
    try await Self.until {
      r = (rt.webviews.record(id)?.blockedPopups.count ?? 0) > 0 ? "notified" : r
      return r == "notified"
    }
    #expect(await Wait.js(w, "window.r") as? String == "blocked")
    #expect(blocked.last?["id"].string == id && blocked.last?["count"] == 1 && blocked.last?.str("url").hasSuffix("/signin") == true)
    #expect(rt.call("webviews", "get", ["id": .string(id)])["blockedPopups"].array?.count == 1)
    #expect(Self.popups(rt, of: id).isEmpty)
    // "Open": it asked for a size, so it opens in a pop-up window (no opener: the script moved on).
    #expect(rt.call("webviews", "openBlocked", ["id": .string(id)])["opened"] == 1)
    #expect(blocked.last?["count"] == 0)
    #expect(rt.webviews.records.values.contains { $0.popupWindow != nil && $0.url.hasSuffix("/signin") })
    // Allowed on this site: the same page opens it.
    _ = rt.call("sitepolicy", "rules", ["default": ["popups": "block"], "hosts": ["127.0.0.1": ["popups": "allow"]]])
    w.reload()
    try await Self.until { Self.popups(rt, of: id).count == 1 }
    #expect(await Wait.js(w, "window.r") as? String == "opened")
  }

  /// A click's gesture carries over to a short timer and to an awaited fetch (WebKit's gesture
  /// token, the one Safari uses), so a sign-in button that fetches first still opens its pop-up.
  @Test func clickGestureCarriesThroughATimerAndAFetch() async throws {
    let mock = try Self.fixture()
    defer { mock.stop() }
    let rt = ServiceTests.runtime()
    _ = rt.call("sitepolicy", "rules", ["default": ["popups": "block"]])
    var blocked = 0
    rt.host.on("webviews.popupBlocked") { if $0["count"].int ?? 0 > 0 { blocked += 1 } }
    let (id, w) = try await Self.opener(rt, mock)
    _ = await Wait.js(w, "setTimeout(() => openPopup('width=300,height=300'), 300); 1")
    try await Self.until { Self.popups(rt, of: id).count == 1 }
    _ = await Wait.js(w, "fetch('/signin').then(r => r.text()).then(() => openPopup('width=300,height=300', 'second')); 1")
    try await Self.until { Self.popups(rt, of: id).count == 2 || blocked > 0 }
    #expect(Self.popups(rt, of: id).count == 2 && blocked == 0)
  }

  /// A private page's pop-up uses the private window's own ephemeral store, never the normal one.
  @Test func privatePopupInheritsTheOpenersEphemeralStore() async throws {
    let mock = try Self.fixture()
    defer { mock.stop() }
    let rt = ServiceTests.runtime()
    let (id, w) = try await Self.opener(rt, mock, profile: "private:w9")
    #expect(await Wait.js(w, "openPopup('width=400,height=400')") as? String == "opened")
    try await Self.until { Self.popups(rt, of: id).count == 1 }
    let p = try #require(Self.popups(rt, of: id).first)
    #expect(p.profile == "private:w9" && p.isPrivate)
    let store = try #require(p.webView?.configuration.websiteDataStore)
    #expect(store === rt.webviews.store(for: "private:w9"))
    #expect(!store.isPersistent && store !== WKWebsiteDataStore.default())
    // Closing the private window lets its store go, and its pop-up windows with it.
    rt.webviews.releaseStore("private:w9")
    try await Self.until { rt.webviews.record(p.id) == nil }
  }

  /// mailto: and app links open their app (Safari's way), never an error page over the page.
  /// The app lookup and launch are stubbed: no test opens an app.
  @Test func appLinksOpenTheirAppInsteadOfAnErrorPage() async throws {
    let mock = try Self.fixture()
    defer { mock.stop() }
    let (appName, open) = (ExternalLinks.appName, ExternalLinks.open)
    defer { ExternalLinks.appName = appName; ExternalLinks.open = open }
    var launched: [String] = []
    ExternalLinks.appName = { $0.scheme == "nope" ? nil : ($0.scheme == "mailto" ? "Mail" : "Zoom") }
    ExternalLinks.open = { launched.append($0.absoluteString) }
    let rt = ServiceTests.runtime()
    let (id, w) = try await Self.opener(rt, mock)
    let prompts = try #require(rt.webviews.prompts)
    // A clicked mailto: link: straight to Mail.
    _ = await Wait.js(w, "var a = document.createElement('a'); a.href = 'mailto:someone@example.test'; document.body.appendChild(a); a.click(); 1")
    try await Self.until { launched == ["mailto:someone@example.test"] }
    // Another app's link: asked first, opened on "Open".
    _ = await Wait.js(w, "location.href = 'zoommtg://zoom.us/join?confno=1'; 1")
    try await Self.until { prompts.current != nil }
    #expect(prompts.current?.tree.str("title") == "Open “Zoom”?")
    prompts.press("open")
    try await Self.until { launched.count == 2 }
    #expect(launched.last == "zoommtg://zoom.us/join?confno=1")
    // window.open of an app link from a click: the app, no empty pop-up.
    _ = await Wait.js(w, "window.open('mailto:x@example.test'); 1")
    try await Self.until { launched.count == 3 }
    #expect(Self.popups(rt, of: id).isEmpty)
    // A link nothing opens: said so, the page stays.
    _ = await Wait.js(w, "location.href = 'nope:thing'; 1")
    try await Self.until { prompts.current != nil }
    #expect(prompts.current?.tree.str("title") == "den can’t open this link")
    prompts.press("ok")
    // The page itself never left.
    #expect(w.url?.path == "/opener")
    #expect(await Wait.js(w, "document.title") as? String == "Opener")
  }

  /// A clicked link to a site an app claims asks first; Open hands it to the app (stubbed), Stay
  /// loads it in den, "Always" stops asking; a script's navigation is never taken.
  @Test func universalLinksAskBeforeOpeningTheirApp() async throws {
    let mock = try Self.fixture()
    defer { mock.stop() }
    let (claims, open, decisions) = (UniversalLinks.claims, UniversalLinks.open, UniversalLinks.decisions)
    defer { UniversalLinks.claims = claims; UniversalLinks.open = open; UniversalLinks.decisions = decisions }
    var handed: [String] = []
    UniversalLinks.claims = ["*.example.test": "Other", "localhost": "Music"]
    UniversalLinks.decisions = [:]
    UniversalLinks.open = { u, done in handed.append(u.absoluteString); done(true) }
    #expect(UniversalLinks.app(for: "a.example.test") == "Other" && UniversalLinks.app(for: "example.test") == nil)
    let rt = ServiceTests.runtime()
    let (_, w) = try await Self.opener(rt, mock)
    let prompts = try #require(rt.webviews.prompts)
    let link = "http://localhost:\(mock.port)/signin".replacingOccurrences(of: "http:", with: "https:")
    func click() async { _ = await Wait.js(w, "var a = document.createElement('a'); a.href = '\(link)'; document.body.appendChild(a); a.click(); 1") }
    // A script's navigation (no click): never asked, never handed over.
    #expect(UniversalLinks.app(for: "localhost") == "Music")
    // Click → asked; Open → the app, the page stays.
    await click()
    try await Self.until { prompts.current != nil }
    #expect(prompts.current?.tree.str("title") == "Open in “Music”?")
    prompts.press("open")
    try await Self.until { handed == [link] }
    #expect(w.url?.path == "/opener")
    // Click → Stay in den with "Always": den loads it itself (the plain-http fixture can't answer
    // https, which doesn't matter: the navigation was let through), and the next click isn't asked.
    await click()
    try await Self.until { prompts.current != nil }
    prompts.press("stay", fields: [WebPrompts.checkedKey: "1"])
    #expect(UniversalLinks.decisions["localhost"] == false)
    let rec = try #require(rt.webviews.records.values.first { $0.webView === w })
    // Set by Stay, consumed when den's own load of the link passes the policy check.
    try await Self.until { rec.passUniversal == nil }
    #expect(handed.count == 1)
    // Remembered: the next click isn't asked and isn't handed to the app.
    await click()
    try await Task.sleep(for: .seconds(1))
    #expect(prompts.current == nil && handed.count == 1)
  }

  @Test func popupFramesFollowTheRequestedSizeOnScreen() {
    let parent = NSRect(x: 100, y: 100, width: 1200, height: 800), screen = NSRect(x: 0, y: 0, width: 1470, height: 920)
    let bar = Tokens.miniBarHeight
    let f = MiniWindows.popupFrame(over: parent, screen: screen, size: CGSize(width: 480, height: 640))
    #expect(f.width == 480 && f.height == 640 + bar && abs(f.midX - parent.midX) < 1)
    let d = MiniWindows.popupFrame(over: parent, screen: screen, size: nil)
    #expect(d.width == 500 && d.height == 600 + bar)
    let tiny = MiniWindows.popupFrame(over: parent, screen: screen, size: CGSize(width: 5, height: 5))
    #expect(tiny.width == 100 && tiny.height == 100 + bar)
    let huge = MiniWindows.popupFrame(over: parent, screen: screen, size: CGSize(width: 5000, height: 5000))
    #expect(screen.contains(huge))
  }
}
