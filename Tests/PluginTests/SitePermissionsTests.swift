import AppKit
import CordisValue
import DenTestSupport
import Testing
import WebKit

@testable import DenHost
@testable import PluginCores

/// Location and notifications for websites, through real web views: WebKit's geolocation request
/// reaching den's prompt, den's Notification bridge in the page, the remembered answers in
/// `sitepolicy` and Shields. macOS itself is stood in for (Location Services, Notification
/// Center), so no system dialog ever shows and nothing is posted.
@MainActor
@Suite(.serialized, .watchdog)
struct SitePermissionsTests {
  final class FakeLocation: LocationAuthorizing {
    var status: LocationStatus
    var answer: LocationStatus
    var asked = 0
    init(_ status: LocationStatus, answer: LocationStatus = .denied) { (self.status, self.answer) = (status, answer) }
    func request(_ done: @escaping @MainActor (LocationStatus) -> Void) {
      asked += 1
      status = answer
      done(answer)
    }
  }

  final class FakeNotifier: Notifying {
    var onClick: (@MainActor ([String: String]) -> Void)?
    var posts: [(id: String, title: String, subtitle: String, body: String, info: [String: String])] = []
    var removed: [String] = []
    var authorized = 0
    func authorize(_ done: @escaping @MainActor (Bool) -> Void) { authorized += 1; done(true) }
    func post(id: String, title: String, subtitle: String, body: String, info: [String: String]) { posts.append((id, title, subtitle, body, info)) }
    func remove(id: String) { removed.append(id) }
  }

  func wait(_ seconds: Double = 20, file: StaticString = #fileID, line: UInt = #line, _ cond: () -> Bool) async -> Bool {
    await Wait.until("a condition", seconds: seconds, file: file, line: line) { cond() }
  }

  /// A selected tab showing `html` as https://example.com/ (a secure origin, no network).
  func page(_ h: Harness, _ html: String, base: String = "https://example.com/") async throws -> (String, WKWebView) {
    let id = h.tabs("open", ["url": "about:blank"]).s("id")
    h.tabs("select", ["id": .string(id)])
    h.rt.content.releaseWebViews()
    let w = try #require(h.rt.webviews.record(id)?.webView)
    w.loadHTMLString(html, baseURL: URL(string: base))
    #expect(await wait { !w.isLoading && w.url?.host() == URL(string: base)?.host() })
    return (id, w)
  }

  func js(_ w: WKWebView, _ s: String) async -> String { (await Wait.asyncJS(w, s) as? String) ?? "nil" }

  static let geoPage = """
    <!doctype html><title>geo</title><script>
    window.ask = () => new Promise((r) => navigator.geolocation.getCurrentPosition(() => r('position'), (e) => r('error ' + e.code), {timeout: 15000}));
    </script>
    """

  @Test func locationAsksTheUserThenMacOS() async throws {
    let h = Harness()
    h.startTabs()
    // A page asks for the location only while it's visible: the (invisible) window in front.
    h.rt.window.window.orderFront(nil)
    defer { h.rt.window.window.orderOut(nil) }
    let p = try #require(h.rt.webviews.prompts)
    let system = FakeLocation(.notDetermined, answer: .denied)
    h.rt.webviews.locationAccess = system
    let (_, w) = try await page(h, Self.geoPage)
    // WebKit asks den (WKUIDelegatePrivate), den asks you.
    w.evaluateJavaScript("ask().then((v) => { window.result = v; })", completionHandler: nil)
    #expect(await wait { p.current?.tree["title"] == "Allow example.com to use your location?" })
    p.press("allow")
    // Then macOS is asked once; it says no, so the page is denied and den says where to fix it.
    #expect(await wait { p.current?.tree["title"] == "Location Services are off for den" })
    #expect(system.asked == 1)
    p.press("later")
    #expect(await wait { (h.rt.call("sitepolicy", "permissions", ["host": "example.com"]).array ?? []).contains { $0.s("kind") == "location" } })
    #expect(await js(w, "return await new Promise((r) => { const t = setInterval(() => { if (window.result) { clearInterval(t); r(window.result); } }, 50); })") == "error 1")
    // Location off for den: the page is denied at once, no prompt, the notice not repeated.
    #expect(await js(w, "return await ask()") == "error 1")
    #expect(!p.visible)
    let perms = h.rt.call("sitepolicy", "permissions", ["host": "example.com"]).array ?? []
    #expect(perms.map { "\($0.s("origin")) \($0.s("kind")) \($0.b("allowed"))" } == ["https://example.com location true"])
    #expect(ShieldsCore.describePermissions(perms) == "Location allowed")
  }

  @Test func locationDecisionRememberedForTheSite() async throws {
    let h = Harness()
    h.startTabs()
    let p = try #require(h.rt.webviews.prompts)
    let (_, w) = try await page(h, "<title>x</title>")
    // macOS lets den use location; the user allows the site: granted, and remembered.
    let system = FakeLocation(.allowed)
    var got: [WKPermissionDecision] = []
    p.location(origin: "https://maps.example", host: "maps.example", webView: w, system: system) { got.append($0) }
    #expect(await wait { p.current?.tree["title"] == "Allow maps.example to use your location?" })
    p.press("allow")
    #expect(got == [.grant])
    p.location(origin: "https://maps.example", host: "maps.example", webView: w, system: system) { got.append($0) }
    #expect(got == [.grant, .grant] && !p.visible)
    // Don't Allow, remembered too; a reset forgets both.
    p.location(origin: "https://other.example", host: "other.example", webView: w, system: system) { got.append($0) }
    #expect(await wait { p.visible })
    p.press("deny")
    #expect(got.last == .deny)
    #expect(h.rt.call("sitepolicy", "allPermissions").array?.count == 2)
    #expect(h.rt.call("sitepolicy", "resetPermissions", ["host": "maps.example"]) == .ok)
    #expect(h.rt.call("sitepolicy", "allPermissions").array?.map { $0.s("origin") } == ["https://other.example"])
    // macOS not decided yet: asked after the site is allowed.
    let fresh = FakeLocation(.notDetermined, answer: .allowed)
    p.location(origin: "https://maps.example", host: "maps.example", webView: w, system: fresh) { got.append($0) }
    #expect(await wait { p.visible })
    p.press("allow")
    #expect(got.last == .grant && fresh.asked == 1)
  }

  static let notifyPage = """
    <!doctype html><title>n</title><script>
    window.events = [];
    window.make = (title) => { const n = new Notification(title, {body: 'Body of ' + title, tag: 't1'});
      n.onshow = () => events.push('show ' + title); n.onerror = () => events.push('error ' + title);
      n.onclick = () => events.push('click ' + title); window.last = n; return 'made'; };
    </script>
    """

  @Test func notificationsBridgeToNotificationCenter() async throws {
    let h = Harness()
    h.startTabs()
    h.record(["notifications.clicked", "sitepolicy.permissionsChanged"])
    let fake = FakeNotifier()
    h.rt.notifications.notifier = fake
    let p = try #require(h.rt.webviews.prompts)
    let (tab, w) = try await page(h, Self.notifyPage)
    #expect(await js(w, "return Notification.permission") == "default")
    #expect(await js(w, "return (await navigator.permissions.query({name: 'notifications'})).state") == "prompt")
    // requestPermission: den asks, remembers, and asks macOS once.
    w.evaluateJavaScript("Notification.requestPermission().then((v) => { window.answer = v; })", completionHandler: nil)
    #expect(await wait { p.current?.tree["title"] == "Allow example.com to show notifications?" })
    p.press("allow")
    #expect(await js(w, "return await new Promise((r) => { const t = setInterval(() => { if (window.answer) { clearInterval(t); r(window.answer); } }, 50); })") == "granted")
    #expect(await js(w, "return Notification.permission") == "granted")
    #expect(h.rt.notifications.decisions["https://example.com"] == true)
    #expect(fake.authorized == 1)
    // A notification goes to Notification Center with the site as its subtitle; onshow fires.
    #expect(await js(w, "return make('Hello')") == "made")
    #expect(await wait { fake.posts.count == 1 })
    let post = try #require(fake.posts.first)
    #expect(post.title == "Hello" && post.subtitle == "example.com" && post.body == "Body of Hello" && post.info["webview"] == tab)
    #expect(await js(w, "return await new Promise((r) => setTimeout(() => r(events.join(',')), 300))") == "show Hello")
    // A click brings the tab forward and the page hears it.
    let other = h.tabs("open", ["url": "about:blank"]).s("id")
    h.tabs("select", ["id": .string(other)])
    fake.onClick?(post.info)
    #expect(h.events.contains { $0.0 == "notifications.clicked" && $0.1.s("webview") == tab })
    #expect(h.tabs("selected").s("id") == tab)
    #expect(await js(w, "return await new Promise((r) => setTimeout(() => r(events.join(',')), 300))") == "show Hello,click Hello")
    // close() takes it out of Notification Center.
    _ = await js(w, "last.close(); return 'ok'")
    #expect(await wait { fake.removed == [post.id] })
    // A new page on the site knows at once (asked at document start), and so do permissions.query.
    w.loadHTMLString(Self.notifyPage, baseURL: URL(string: "https://example.com/again"))
    #expect(await wait { !w.isLoading })
    #expect(await js(w, "return await new Promise((r) => setTimeout(() => r(Notification.permission), 200))") == "granted")
    #expect(await js(w, "return (await navigator.permissions.query({name: 'notifications'})).state") == "granted")
    // Kept across launches (storage), listed with every site's answers, removable.
    #expect(h.rt.call("sitepolicy", "permissions", ["host": "example.com"]).array?.map { "\($0.s("kind")) \($0.b("allowed")) \($0.b("kept"))" } == ["notifications true true"])
    let again = PageNotifications(host: h.rt.host, storage: h.rt.storage, notifier: FakeNotifier())
    again.load()
    #expect(again.decisions["https://example.com"] == true)
    #expect(h.rt.call("sitepolicy", "setPermission", ["origin": "https://example.com", "kind": "notifications", "allowed": .null]) == .ok)
    #expect(h.rt.notifications.decisions.isEmpty)
  }

  @Test func deniedSitesAndPrivateWindowsPostNothing() async throws {
    let h = Harness()
    h.startTabs()
    let fake = FakeNotifier()
    h.rt.notifications.notifier = fake
    let p = try #require(h.rt.webviews.prompts)
    let (_, w) = try await page(h, Self.notifyPage, base: "https://nope.example/")
    w.evaluateJavaScript("Notification.requestPermission().then((v) => { window.answer = v; })", completionHandler: nil)
    #expect(await wait { p.visible })
    p.press("deny")
    #expect(await js(w, "return await new Promise((r) => { const t = setInterval(() => { if (window.answer) { clearInterval(t); r(window.answer); } }, 50); })") == "denied")
    _ = await js(w, "return make('Spam')")
    #expect(await js(w, "return await new Promise((r) => setTimeout(() => r(events.join(',')), 400))") == "error Spam")
    #expect(fake.posts.isEmpty)
    // A private window's page: always denied, never asked.
    let priv = h.rt.call("webviews", "create", ["url": "about:blank", "profile": "private:p9"]).s("id")
    _ = h.rt.call("content", "show", ["panes": [.string(priv)]])
    h.rt.content.releaseWebViews()
    let pw = try #require(h.rt.webviews.record(priv)?.webView)
    pw.loadHTMLString(Self.notifyPage, baseURL: URL(string: "https://example.org/"))
    #expect(await wait { !pw.isLoading })
    #expect(await js(pw, "return await Notification.requestPermission()") == "denied")
    #expect(!p.visible && fake.posts.isEmpty)
  }
}
