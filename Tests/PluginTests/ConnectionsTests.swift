import AppKit
import CordisValue
import Foundation
import DenTestSupport
import Testing
import WebKit

@testable import DenHost
@testable import PluginCores

/// End to end against the local fake Slack/GitHub (`MockServices`): a real sign-in page sets
/// cookies and localStorage in a WebKit data store, `session` reads them, `net` calls the fake
/// APIs with those cookies, and the briefing turns the result into todos and a feed.
@MainActor
@Suite(.serialized, .watchdog)
struct ConnectionsTests {
  static let profile = "private"

  func mock() throws -> MockServices {
    let m = MockServices()
    try m.start()
    #expect(m.port != 0)
    return m
  }

  func until(_ seconds: Double = 30, line: UInt = #line, _ cond: () -> Bool) async -> Bool {
    await Wait.until("a condition", seconds: seconds, line: line) { cond() }
  }

  /// Loads `url` in a web view of the test profile, like the user signing in inside den.
  func signIn(_ h: Harness, _ url: String) async -> Bool {
    let id = h.rt.call("webviews", "create", ["url": .string(url), "profile": .string(Self.profile)]).s("id")
    guard let w = h.rt.webviews.materialize(id) else { return false }
    // Show it in the (on-screen) window: den's web views use `inactiveSchedulingPolicy = .suspend`,
    // and in a loaded full run an unseen one gets suspended before the page finishes loading.
    h.rt.window.window.orderFrontRegardless()
    h.rt.call("content", "show", ["panes": [.string(id)]])
    // 45 s of wall time: under a loaded full run the mock page can take far longer than alone (3 s).
    // A failed load also ends "loaded": den swaps in its error page (WebErrorPage, same URL), which
    // sets no cookies. Seen on a CI runner under a full parallel run; reload until the real page is in.
    for attempt in 1...3 {
      guard await until(45, { !w.isLoading && w.url != nil && w.estimatedProgress >= 1 }) else { return false }
      let err = (try? await w.evaluateJavaScript("document.body ? (document.body.dataset.denError || '') : ''")) as? String ?? ""
      if err.isEmpty { return true }
      print("signIn: attempt \(attempt) loaded den's error page (\(err)) for \(url); reloading")
      h.rt.call("webviews", "reload", ["id": .string(id)])
      _ = await until(5) { w.isLoading }
    }
    return false
  }

  /// Points the plugins at the mock and grants them its host (the real sidecars say slack.com /
  /// github.com / linear.app / atlassian.net).
  func configure(_ h: Harness, _ m: MockServices) {
    h.rt.call("storage", "set", ["ns": "slack", "key": "endpoints", "value": [
      "api": .string(m.base + "/api/"), "origin": .string(m.base), "domain": "127.0.0.1", "signIn": .string(m.base + "/slack/signin")]])
    h.rt.call("storage", "set", ["ns": "github", "key": "base", "value": .string(m.base)])
    h.rt.call("storage", "set", ["ns": "linear", "key": "endpoints", "value": [
      "api": .string(m.base + "/graphql"), "web": .string(m.base), "domain": "127.0.0.1", "signIn": .string(m.base + "/linear/signin")]])
    h.rt.call("storage", "set", ["ns": "jira", "key": "endpoints", "value": [
      "origin": .string(m.base), "domain": "127.0.0.1", "signIn": .string(m.base + "/jira/signin")]])
    h.rt.permissions.grant("slack", ["session:127.0.0.1"])
    h.rt.permissions.grant("github", ["session:127.0.0.1"])
    h.rt.permissions.grant("linear", ["session:127.0.0.1"])
    h.rt.permissions.grant("jira", ["session:127.0.0.1"])
  }

  func events(_ h: Harness, _ name: String) -> [Value] { h.events.filter { $0.0 == name }.map(\.1) }

  // MARK: Permissions, session, net

  @Test func undeclaredAccessIsDenied() {
    let h = Harness()
    h.rt.permissions.grant("slack", ["session:slack.com"])
    #expect(h.rt.call("session", "cookies", ["plugin": "slack", "domain": "slack.com"])["id"].string != nil)
    #expect(h.rt.call("session", "cookies", ["plugin": "slack", "domain": "app.slack.com"])["id"].string != nil)
    #expect(h.rt.call("session", "cookies", ["plugin": "slack", "domain": "github.com"]).isError)
    #expect(h.rt.call("session", "cookies", ["plugin": "evil", "domain": "slack.com"]).isError)
    #expect(h.rt.call("session", "cookies", ["plugin": "slack", "domain": "notslack.com"]).isError)
    #expect(h.rt.call("session", "eval", ["plugin": "slack", "origin": "https://github.com", "script": "return 1"]).isError)
    #expect(h.rt.call("session", "eval", ["plugin": "slack", "origin": "https://app.slack.com", "script": .string(String(repeating: "x", count: 5000))]).isError)
    #expect(h.rt.call("net", "fetch", ["plugin": "slack", "url": "https://example.com/"]).isError)
    #expect(h.rt.call("net", "fetch", ["plugin": "slack", "url": "file:///etc/passwd"]).isError)
    h.rt.permissions.grant("reader", ["net:example.com"])
    #expect(h.rt.call("net", "fetch", ["plugin": "reader", "url": "https://example.com/", "session": true]).isError)
    #expect(h.rt.net.requestCount == 0)
  }

  @Test func sidecarPermissionsAreRead() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("den-perm-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(#"{"permissions": ["session:slack.com", "bogus", "net:api.example.com"]}"#.utf8).write(to: dir.appendingPathComponent("slack.json"))
    let p = Permissions()
    #expect(p.loadSidecar(plugin: "slack", dylib: dir.appendingPathComponent("slack.dylib")) == ["session:slack.com", "net:api.example.com"])
    #expect(p.allowsSession("slack", host: "acme.slack.com"))
    #expect(!p.allowsSession("slack", host: "api.example.com"))
    #expect(p.allowsNet("slack", host: "api.example.com"))
    // The real sidecars in the repo. slack still ships the old name (`permissions.json`) while its
    // own PR is in flight; `bundle.sh` copies either name to `<id>.json` next to the dylib.
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let q = Permissions()
    #expect(q.loadSidecar(plugin: "slack", dylib: repo.appendingPathComponent("Plugins/slack/permissions.dylib")) == ["session:slack.com"])
    #expect(q.loadSidecar(plugin: "github", dylib: repo.appendingPathComponent("Plugins/github/plugin.dylib")) == ["session:github.com"])
  }

  @Test func sessionReadsCookiesAndSiteStorageAfterSignIn() async throws {
    let m = try mock()
    defer { m.stop() }
    let h = Harness()
    h.record(["session.result"])
    h.rt.permissions.grant("slack", ["session:127.0.0.1"])
    #expect(await signIn(h, m.base + "/slack/signin"))
    let c = h.rt.call("session", "cookies", ["plugin": "slack", "domain": "127.0.0.1", "profile": .string(Self.profile), "id": "c1"])
    #expect(c["id"] == "c1")
    #expect(await until { events(h, "session.result").contains { $0.s("id") == "c1" } })
    let cookies = events(h, "session.result").first { $0.s("id") == "c1" }!.a("cookies")
    let d = cookies.first { $0.s("name") == "d" }
    #expect(d?.s("value") == MockServices.dCookie)
    #expect(d?.b("httpOnly") == true)  // HttpOnly cookies are visible to den, never to page scripts

    _ = h.rt.call("session", "eval", ["plugin": "slack", "origin": .string(m.base), "profile": .string(Self.profile), "id": "e1",
                                      "script": .string(SlackCore.configScript)])
    #expect(await until { events(h, "session.result").contains { $0.s("id") == "e1" } })
    let r = events(h, "session.result").first { $0.s("id") == "e1" }!
    #expect(r.b("ok"))
    let teams = r["value"].array ?? []
    #expect(teams.map { $0.s("name") } == ["Acme Inc", "den OSS"])
    #expect(teams.first?.s("token") == "xoxc-mock-acme")
    #expect(h.rt.session.inFlight == 0)  // the hidden view is gone
    // Reading needs no request to the site: only the sign-in page hit the server.
    // (A set: signIn may have reloaded the sign-in page after a failed load.)
    #expect(Set(m.log.filter { $0 != "GET /favicon.ico" }) == ["GET /slack/signin"])
  }

  @Test func netAttachesSessionCookiesOnlyWhenAsked() async throws {
    let m = try mock()
    defer { m.stop() }
    let h = Harness()
    h.record(["net.result"])
    h.rt.permissions.grant("slack", ["session:127.0.0.1"])
    #expect(await signIn(h, m.base + "/slack/signin"))
    let body = Web.form([("token", "xoxc-mock-acme")])
    for (id, session) in [("with", true), ("without", false)] {
      _ = h.rt.call("net", "fetch", ["plugin": "slack", "id": .string(id), "url": .string(m.base + "/api/client.counts"), "method": "POST",
                                     "session": .bool(session), "profile": .string(Self.profile), "as": "json", "body": .string(body),
                                     "headers": ["Content-Type": "application/x-www-form-urlencoded"]])
    }
    #expect(await until { events(h, "net.result").count == 2 })
    let with = events(h, "net.result").first { $0.s("id") == "with" }!
    let without = events(h, "net.result").first { $0.s("id") == "without" }!
    #expect(with.b("ok") && with.i("status") == 200 && with["json"].b("ok"))
    #expect(with["json"].a("ims").count == 2)
    #expect(with["headers"]["content-type"].string?.hasPrefix("application/json") == true)
    #expect(without["json"].s("error") == "invalid_auth")

    // Size cap and redirects off the permitted host.
    _ = h.rt.call("net", "fetch", ["plugin": "slack", "id": "big", "url": .string(m.base + "/big"), "maxBytes": 100_000])
    _ = h.rt.call("net", "fetch", ["plugin": "slack", "id": "redir", "url": .string(m.base + "/redirect-out")])
    #expect(await until { events(h, "net.result").count == 4 })
    #expect(events(h, "net.result").first { $0.s("id") == "big" }!.s("error") == "too large")
    let redir = events(h, "net.result").first { $0.s("id") == "redir" }!
    #expect(redir.i("status") == 302)  // not followed to example.invalid
    #expect(h.rt.net.inFlight == 0)
  }

  // MARK: Connect flow

  /// Starts connections + slack + github (+ briefing) cores with a fake `tabs` that records opens.
  final class Tabs {
    var opened: [String] = []
    var toasts: [String] = []
    var toastTrees: [Value] = []
  }

  /// The harness env, with toasts recorded (they auto-dismiss after 2.2 s on screen).
  func env(_ h: Harness, _ tabs: Tabs) -> PluginEnv {
    var e = h.env
    let base = e.invoke
    e.invoke = { s, m, a in
      if s == "ui", m == "set", a.s("slot") == "toast" {
        tabs.toasts.append(a["tree"].s("text"))
        tabs.toastTrees.append(a["tree"])
      }
      return base(s, m, a)
    }
    return e
  }

  func startAll(_ h: Harness, _ m: MockServices, tabs: Tabs, briefing: Bool = true) -> (ConnectionsCore, SlackCore, GitHubCore, BriefingCore?) {
    configure(h, m)
    h.clock = Int64(m.now.timeIntervalSince1970 * 1000)  // the mock's data is relative to its clock
    h.rt.plugins.provide("tabs") { method, a in
      if method == "open" { tabs.opened.append(a.s("url")); return ["id": .string("tab-\(tabs.opened.count)")] }
      return ["ok": true]
    }
    h.rt.plugins.provide("spaces") { method, _ in
      method == "current" ? ["id": "s1"] : [["id": "s1", "name": "Personal", "profile": .string(Self.profile)]]
    }
    let c = ConnectionsCore(env: env(h, tabs))
    h.rt.plugins.provide("connections") { a, b in c.handle(a, b) }
    c.start()
    let s = SlackCore(env: h.env)
    s.start()
    let g = GitHubCore(env: h.env)
    g.start()
    var b: BriefingCore?
    if briefing {
      let core = BriefingCore(env: env(h, tabs))
      h.rt.plugins.provide("briefing") { a, v in core.handle(a, v) }
      core.start()
      b = core
    }
    return (c, s, g, b)
  }

  @Test func connectOpensSignInThenDetectsTheSession() async throws {
    let m = try mock()
    defer { m.stop() }
    let h = Harness()
    let tabs = Tabs()
    let (c, _, _, _) = startAll(h, m, tabs: tabs, briefing: false)
    h.record(["connections.changed"])
    #expect(c.providers.map(\.id).sorted() == ["github", "slack"])
    #expect((h.rt.call("connections", "list").array ?? []).allSatisfy { !$0.b("connected") })

    // Not signed in yet: the sign-in page opens in a tab.
    h.rt.call("connections", "connect", ["id": "slack"])
    #expect(await until { tabs.opened == [m.base + "/slack/signin"] })
    #expect(h.rt.call("connections", "get", ["id": "slack"]).b("pending"))
    #expect(tabs.toasts.isEmpty)

    // The user signs in; the next probe (every 3 s, or on the tab's URL change) sees it.
    #expect(await signIn(h, m.base + "/slack/signin"))
    h.fireTimers()
    #expect(await until(45) { h.rt.call("connections", "get", ["id": "slack"]).b("connected") })
    let slack = h.rt.call("connections", "get", ["id": "slack"])
    #expect(slack.s("account") == "Acme Inc")
    #expect(slack.a("teams").map { $0.s("name") } == ["Acme Inc", "den OSS"])
    #expect(tabs.toasts == ["Slack connected"])
    // Two workspaces: the settings sheet opens with the picker.
    #expect(h.rt.ui.sheets["overlay.connections"] != nil)
    #expect(!events(h, "connections.changed").isEmpty)
    // No token is ever stored.
    let stored = ValueJSON.string(h.storage("connections", "accounts"))
    #expect(stored.contains("T01ACME") && !stored.contains("xoxc"))

    // GitHub, already signed in: connects without opening a tab.
    #expect(await signIn(h, m.base + "/login"))
    h.rt.call("connections", "connect", ["id": "github"])
    #expect(await until { h.rt.call("connections", "get", ["id": "github"]).b("connected") })
    #expect(h.rt.call("connections", "get", ["id": "github"]).s("account") == "@octo-den")
    #expect(tabs.opened.count == 1)
    #expect(tabs.toasts.last == "GitHub connected")

    // Workspace picker and disconnect.
    h.action("connections.team:slack:T02DEN", "toggle", ["on": false])
    #expect(h.rt.call("connections", "get", ["id": "slack"]).a("teams").map { $0.b("enabled", true) } == [true, false])
    h.action("connections.row:github", "click")
    #expect(!h.rt.call("connections", "get", ["id": "github"]).b("connected"))
    #expect(tabs.toasts.last == "GitHub disconnected")
  }

  // MARK: Briefing pipeline

  /// Deterministic stand-in for Foundation Models (the real one is tested in AIServiceTests).
  @MainActor
  final class FakeModel: AIGenerator {
    var prompts: [String] = []
    func availability() -> (available: Bool, reason: String?) { (true, nil) }
    var contextSize: Int { 4096 }
    func respond(instructions: String, prompt: String) async throws -> String {
      prompts.append(prompt)
      return "Maya needs your numbers for the Q3 deck, and two PRs wait for your review."
    }
    /// Picks review requests and DMs, like the real model is asked to.
    func todo(instructions: String, text: String) async throws -> (actionable: Bool, title: String) {
      if text.contains("requested your review") { return (true, "Review " + (text.split(separator: ":").last.map(String.init) ?? "")) }
      if text.contains("direct message") { return (true, "Reply to " + String(text.split(separator: " ")[0])) }
      return (false, "")
    }
  }

  @Test func briefingEndToEndWithMocks() async throws {
    let m = try mock()
    defer { m.stop() }
    let h = Harness()
    let model = FakeModel()
    h.rt.ai.generator = model
    let tabs = Tabs()
    let (_, _, _, b) = startAll(h, m, tabs: tabs)
    let briefing = b!
    h.record(["feed.items", "schedule.fire"])
    #expect(!briefing.scheduled)  // nothing is scheduled or polled before a connection exists
    #expect(h.rt.call("schedule", "list") == [])

    // Opening with no connection shows the connect buttons.
    h.rt.call("briefing", "open")
    let empty = ValueJSON.string(h.rt.ui.sheets["overlay.briefing"]!.node)
    #expect(empty.contains("briefing.connect:slack") && empty.contains("briefing.connect:github"))
    #expect(m.log.isEmpty)

    #expect(await signIn(h, m.base + "/slack/signin"))
    #expect(await signIn(h, m.base + "/login"))
    h.rt.call("connections", "connect", ["id": "slack"])
    h.rt.call("connections", "connect", ["id": "github"])
    #expect(await until { briefing.connected().count == 2 })
    #expect(briefing.scheduled)
    #expect((h.rt.call("schedule", "list").array ?? []).map { $0.s("id") } == ["briefing.morning", "briefing.poll"])
    #expect(h.rt.call("schedule", "list")[0].i("hour") == 8)

    // Connecting refreshes the open page (again when the second connection lands mid-refresh).
    #expect(await until(20) { !briefing.refreshing && briefing.summaryState == "ai" })
    // One explicit refresh, measured on its own.
    let before = m.log.count, gen = briefing.generation
    h.rt.call("briefing", "refresh")
    #expect(await until(20) { briefing.generation == gen + 1 && !briefing.refreshing && briefing.summaryState == "ai" })
    let calls = Array(m.log[before...])
    let state = h.rt.call("briefing", "state")
    #expect(state.s("summary").hasPrefix("Maya needs your numbers"))
    #expect(state["errors"] == .object([]))

    let feed = state.a("feed")
    let kinds = feed.map { $0.s("kind") }
    // Slack: 2 unread DMs (Acme + den OSS), 1 thread awaiting a reply, 1 mention; the answered
    // thread is a plain mention. GitHub: review x2, ci, assigned, mention (the review PR that also
    // mentions you counts once, as a review).
    #expect(kinds.filter { $0 == "dm" }.count == 2)
    #expect(kinds.filter { $0 == "thread" }.count == 1)
    #expect(kinds.filter { $0 == "mention" }.count == 3)
    #expect(kinds.filter { $0 == "review" }.count == 2)
    #expect(kinds.filter { $0 == "ci" }.count == 1)
    #expect(kinds.filter { $0 == "assigned" }.count == 1)
    #expect(feed.count == 10)
    #expect(feed.first?.s("kind") == "review")  // most recent review request ranks first
    let dm = feed.first { $0.s("kind") == "dm" && $0.s("detail").contains("Maya") }!
    #expect(dm.s("title").hasPrefix("Can you look at the Q3 launch deck"))
    #expect(dm.s("detail").hasPrefix("DM from Maya Chen · 2 unread"))
    #expect(dm.s("url").contains("/archives/D01MAYA/p"))
    let thread = feed.first { $0.s("kind") == "thread" }!
    #expect(thread.s("title") == "@you the checkout fix is on staging, can you confirm it works on Safari?")
    #expect(thread.s("detail").hasPrefix("jon in #eng-web · waiting for your reply"))
    let ana = feed.first { $0.s("actor") == "ana" }!
    #expect(ana.s("title").contains("Launch doc") && !ana.s("title").contains("<https"))
    let review = feed.first { $0.s("url").hasSuffix("/acme/web/pull/1482") }!
    #expect(review.s("kind") == "review" && review.s("title") == "Checkout: retry card <iframe> load on Safari")
    #expect(feed.contains { $0.s("url").hasSuffix("/acme/api/issues/77") && $0.s("kind") == "assigned" })

    // AI todos map back to the exact items (the fake model picks reviews and DMs).
    let todos = state.a("todos")
    #expect(todos.count == 4)
    #expect(Set(todos.map { $0.s("title") }).isSuperset(of: ["Reply to Maya", "Reply to Lee"]))
    #expect(todos.contains { $0.s("title").hasPrefix("Review") && $0.s("url").hasSuffix("/acme/web/pull/1482") })
    #expect(todos.allSatisfy { t in feed.contains { $0.s("id") == t.s("id") && $0.s("url") == t.s("url") } })

    // Request volume stays modest: per refresh, Slack ≤ ~20 per workspace and GitHub 5 (PR branches for
    // stacks were read once, by the first refresh, and are cached).
    let slackCalls = calls.filter { $0.hasPrefix("POST /api/") }.count
    let githubCalls = calls.filter { $0 == "GET /search" }.count
    #expect(githubCalls == 5)
    // Acme 5 (counts, search, history, 2 replies), den OSS 3; names are cached from the first refresh.
    #expect(slackCalls == 8)
    #expect(calls.count == 13)

    // The page renders the todo rows and feed rows; a checked todo persists.
    let page = ValueJSON.string(h.rt.ui.sheets["overlay.briefing"]!.node)
    #expect(page.contains("todoRow") && page.contains("feedRow") && page.contains("0 of 4 done"))
    let first = todos[0].s("id")
    h.action("briefing.todo:" + first, "toggle", ["done": true])
    #expect(h.storage("briefing", "todos").array?.first { $0.s("id") == first }?.b("done") == true)
    #expect(ValueJSON.string(h.rt.ui.sheets["overlay.briefing"]!.node).contains("1 of 4 done"))

    // Opening a feed item opens its exact URL in a tab and closes the page.
    h.action("briefing.feed:" + review.s("id"), "open")
    #expect(tabs.opened.last == review.s("url"))
    #expect(h.rt.ui.sheets["overlay.briefing"] == nil)

    // Next launch: todos (and their state) come back; tokens don't (re-read from the session).
    let h2 = Harness(root: h.root)
    h2.rt.ai.generator = FakeModel()
    let (_, s2, _, b2) = startAll(h2, m, tabs: Tabs())
    #expect(b2!.todos.count == 4 && b2!.todos.first { $0.s("id") == first }?.b("done") == true)
    #expect(s2.teams.isEmpty)
    _ = h2
  }

  @Test func briefingFallsBackToPlainListsWithoutAppleIntelligence() async throws {
    @MainActor final class Off: AIGenerator {
      func availability() -> (available: Bool, reason: String?) { (false, "appleIntelligenceNotEnabled") }
      var contextSize: Int { 4096 }
      func respond(instructions: String, prompt: String) async throws -> String { Issue.record("model called"); return "" }
      func todo(instructions: String, text: String) async throws -> (actionable: Bool, title: String) { Issue.record("model called"); return (false, "") }
    }
    let m = try mock()
    defer { m.stop() }
    let h = Harness()
    h.rt.ai.generator = Off()
    let (_, _, _, b) = startAll(h, m, tabs: Tabs())
    #expect(await signIn(h, m.base + "/login"))
    h.rt.call("connections", "connect", ["id": "github"])
    #expect(await until { b!.connected().count == 1 })
    h.rt.call("briefing", "open")
    #expect(await until(20) { !b!.refreshing && b!.summaryState == "plain" })
    #expect(b!.summary == "2 review requests, 1 PR with failing CI, 1 mention and 1 assigned issue.")
    #expect(b!.todos.count == 5)  // every actionable item, titled as-is
    let page = ValueJSON.string(h.rt.ui.sheets["overlay.briefing"]!.node)
    #expect(page.contains("Summaries need Apple Intelligence"))
  }

  @Test func signedOutSessionIsReported() async throws {
    let m = try mock()
    defer { m.stop() }
    let h = Harness()
    let tabs = Tabs()
    let (_, _, _, b) = startAll(h, m, tabs: tabs)
    h.rt.ai.generator = FakeModel()
    #expect(await signIn(h, m.base + "/login"))
    h.rt.call("connections", "connect", ["id": "github"])
    #expect(await until { b!.connected().count == 1 })
    // The user signs out of github.com in den: its cookies go away.
    let store = h.rt.webviews.store(for: Self.profile)
    let cookies: [HTTPCookie]? = await Wait.callback("cookies") { done in store.httpCookieStore.getAllCookies { done($0) } }
    for c in cookies ?? [] where c.name == "user_session" {
      _ = await Wait.callback("delete cookie") { (done: @escaping @Sendable (Bool) -> Void) in store.httpCookieStore.delete(c) { done(true) } }
    }
    h.rt.call("briefing", "refresh")
    #expect(await until(20) { !h.rt.call("connections", "get", ["id": "github"]).b("connected") })
    #expect(tabs.toasts.last?.hasPrefix("Signed out of GitHub") == true)
  }

  // MARK: Auto-connect

  func githubCookie(_ name: String, _ value: String) -> HTTPCookie {
    HTTPCookie(properties: [.domain: ".gh.example", .path: "/", .name: name, .value: value, .secure: "TRUE", .expires: Date().addingTimeInterval(3600)])!
  }

  /// Signing in to github.com in den connects GitHub by itself (the host's cookie observer emits
  /// `session.cookiesChanged`), with "GitHub connected · Undo"; Undo sticks until a manual Connect.
  @Test func autoConnectToastsWithUndoAndRemembersTheDecline() async {
    let h = Harness()
    let tabs = Tabs()
    h.rt.plugins.provide("tabs") { method, a in
      if method == "open" { tabs.opened.append(a.s("url")); return ["id": .string("tab-\(tabs.opened.count)")] }
      return ["ok": true]
    }
    h.rt.plugins.provide("spaces") { method, _ in method == "current" ? ["id": "s1"] : [["id": "s1", "name": "Personal", "profile": .string(Self.profile)]] }
    h.rt.call("storage", "set", ["ns": "github", "key": "base", "value": "https://gh.example"])
    h.rt.permissions.grant("github", ["session:gh.example"])
    let c = ConnectionsCore(env: env(h, tabs))
    h.rt.plugins.provide("connections") { a, b in c.handle(a, b) }
    c.start()
    let g = GitHubCore(env: h.env)
    g.start()
    // It watches its own cookie domain from the start; nothing is connected yet.
    #expect(await until { h.rt.session.observedProfiles == ["default"] })
    #expect(!h.rt.call("connections", "get", ["id": "github"]).b("connected"))
    #expect(tabs.toasts.isEmpty && tabs.opened.isEmpty)

    // The user signs in to github.com in a tab: the cookies change.
    let store = h.rt.webviews.store(for: Self.profile).httpCookieStore
    await store.setCookie(githubCookie("logged_in", "yes"))
    await store.setCookie(githubCookie("dotcom_user", "octo-den"))
    h.rt.plugins.emit("session.cookiesChanged", ["domain": "gh.example", "profile": .string(Self.profile)])
    #expect(await until { h.rt.call("connections", "get", ["id": "github"]).b("connected") })
    #expect(h.rt.call("connections", "get", ["id": "github"]).s("account") == "@octo-den")
    #expect(tabs.toasts == ["GitHub connected"])
    #expect(tabs.toastTrees.last?.s("action") == "Undo")
    #expect(tabs.toastTrees.last?.s("id") == "connections.undo:github")
    #expect(tabs.opened.isEmpty)  // no sign-in tab, no sheet
    #expect(h.rt.ui.sheets["overlay.connections"] == nil)

    // Undo: disconnected quietly, and later sign-ins don't reconnect it.
    h.action("connections.undo:github", "toast")
    #expect(!h.rt.call("connections", "get", ["id": "github"]).b("connected"))
    #expect(h.rt.call("connections", "get", ["id": "github"]).b("declined"))
    #expect(h.storage("connections", "declined") == ["github": true])
    #expect(tabs.toasts == ["GitHub connected"])
    h.rt.plugins.emit("session.cookiesChanged", ["domain": "gh.example", "profile": .string(Self.profile)])
    try? await Task.sleep(for: .milliseconds(600))
    #expect(!h.rt.call("connections", "get", ["id": "github"]).b("connected"))

    // A fresh start (relaunch) keeps the decline.
    let c2 = ConnectionsCore(env: h.env)
    c2.start()
    #expect(c2.declined["github"] == true)

    // A manual Connect clears it and connects (the ordinary toast, no Undo).
    h.rt.call("connections", "connect", ["id": "github", "profile": .string(Self.profile)])
    #expect(await until { h.rt.call("connections", "get", ["id": "github"]).b("connected") })
    #expect(!h.rt.call("connections", "get", ["id": "github"]).b("declined"))
    #expect(h.storage("connections", "declined") == [:])
    #expect(tabs.toasts.last == "GitHub connected")
    #expect(tabs.toastTrees.last?["action"].isNull == true)

    // Signing out (cookie gone) is noticed the same way: the expired path.
    for ck in await store.allCookies() where ck.name == "logged_in" { await store.deleteCookie(ck) }
    h.rt.plugins.emit("session.cookiesChanged", ["domain": "gh.example", "profile": .string(Self.profile)])
    #expect(await until { !h.rt.call("connections", "get", ["id": "github"]).b("connected") })
    #expect(tabs.toasts.last?.hasPrefix("Signed out of GitHub") == true)
  }

  // MARK: Linear and Jira

  /// Starts connections + linear + jira against the mock, with the same fake tabs/spaces as startAll.
  func startTrackers(_ h: Harness, _ m: MockServices, tabs: Tabs) -> (ConnectionsCore, LinearCore, JiraCore) {
    configure(h, m)
    h.clock = Int64(m.now.timeIntervalSince1970 * 1000)
    h.rt.plugins.provide("tabs") { method, a in
      if method == "open" { tabs.opened.append(a.s("url")); return ["id": .string("tab-\(tabs.opened.count)")] }
      return ["ok": true]
    }
    h.rt.plugins.provide("spaces") { method, _ in
      method == "current" ? ["id": "s1"] : [["id": "s1", "name": "Personal", "profile": .string(Self.profile)]]
    }
    let c = ConnectionsCore(env: env(h, tabs))
    h.rt.plugins.provide("connections") { a, b in c.handle(a, b) }
    c.start()
    let l = LinearCore(env: h.env)
    l.start()
    let j = JiraCore(env: h.env)
    j.start()
    return (c, l, j)
  }

  @Test func linearConnectsAndFeedsAssignedIssues() async throws {
    let m = try mock()
    defer { m.stop() }
    let h = Harness()
    let tabs = Tabs()
    let (c, l, _) = startTrackers(h, m, tabs: tabs)
    h.record(["feed.items"])
    #expect(c.providers.map(\.id).sorted() == ["jira", "linear"])
    #expect(!h.rt.call("connections", "get", ["id": "linear"]).b("connected"))

    // Not signed in yet: the sign-in page opens in a tab.
    h.rt.call("connections", "connect", ["id": "linear"])
    #expect(await until { tabs.opened == [m.base + "/linear/signin"] })

    // The user signs in; the next probe sees a cookie and confirms the session with the viewer query.
    #expect(await signIn(h, m.base + "/linear/signin"))
    h.fireTimers()
    #expect(await until(45) { h.rt.call("connections", "get", ["id": "linear"]).b("connected") })
    #expect(h.rt.call("connections", "get", ["id": "linear"]).s("account") == "Riley")
    #expect(tabs.toasts == ["Linear connected"])
    // No session token is ever stored.
    let stored = ValueJSON.string(h.storage("connections", "accounts"))
    #expect(stored.contains("linear") && !stored.contains(MockServices.linearCookie))

    // A refresh emits the open assigned issues as feed items.
    h.rt.plugins.emit("feed.refresh")
    #expect(await until { events(h, "feed.items").contains { $0.s("source") == "linear" } })
    let items = events(h, "feed.items").first { $0.s("source") == "linear" }!.a("items")
    #expect(items.map { $0.s("title") } == ["Checkout: retry card load on Safari", "Icon set v3: which glyph for Archive?"])
    let first = items[0]
    #expect(first.s("kind") == "assigned" && first.s("badge") == "Assigned")
    #expect(first.s("detail") == "ENG-123 · Engineering · In Progress · from Maya Chen")
    #expect(first.s("url") == m.base + "/acme/issue/ENG-123/checkout-retry-card-load-on-safari")
    #expect(first.s("importantKey") == "linear:ENG" && first.s("importantTitle") == "Engineering (ENG)")
    #expect(first.i("ts") > 0)
    #expect(!l.refreshing)
  }

  @Test func jiraConnectsAndFeedsAssignedIssues() async throws {
    let m = try mock()
    defer { m.stop() }
    let h = Harness()
    let tabs = Tabs()
    let (_, j, _) = startTrackers(h, m, tabs: tabs)
    _ = j
    h.record(["feed.items"])

    // Already signed in: Connect finds the session (cookie + myself) without opening a tab.
    #expect(await signIn(h, m.base + "/jira/signin"))
    h.rt.call("connections", "connect", ["id": "jira"])
    #expect(await until(45) { h.rt.call("connections", "get", ["id": "jira"]).b("connected") })
    #expect(tabs.opened.isEmpty)
    let jira = h.rt.call("connections", "get", ["id": "jira"])
    #expect(jira.s("account") == "Riley Chen")
    // The signed-in site is the connection's single team ("sites"); its id is the cookie's host.
    #expect(jira.a("teams").map { $0.s("id") } == ["127.0.0.1"])
    #expect(tabs.toasts == ["Jira connected"])
    // No session token is ever stored.
    let stored = ValueJSON.string(h.storage("connections", "accounts"))
    #expect(stored.contains("jira") && !stored.contains(MockServices.jiraCookie))

    // A refresh emits the open assigned issues as feed items.
    h.rt.plugins.emit("feed.refresh")
    #expect(await until { events(h, "feed.items").contains { $0.s("source") == "jira" } })
    let items = events(h, "feed.items").first { $0.s("source") == "jira" }!.a("items")
    #expect(items.map { $0.s("title") } == ["Offline mode drops queued replies", "Icon set v3: archive glyph states"])
    let first = items[0]
    #expect(first.s("kind") == "assigned" && first.s("badge") == "Assigned")
    #expect(first.s("detail") == "ENG-101 · Engineering · In Progress · from Maya Chen")
    #expect(first.s("url") == m.base + "/browse/ENG-101")
    #expect(first.s("importantKey") == "jira:127.0.0.1:ENG" && first.s("importantTitle") == "Engineering")
    // Jira's "+0000" offset parses to the mock's clock (30 minutes ago, a millisecond of rounding).
    let expected = Int64((m.now.addingTimeInterval(-30 * 60).timeIntervalSince1970 * 1000).rounded())
    #expect(abs(first.i("ts") - expected) < 1000)
  }

  @Test func linearAndJiraReportSignedOutSessions() async throws {
    let m = try mock()
    defer { m.stop() }
    let h = Harness()
    let tabs = Tabs()
    let _ = startTrackers(h, m, tabs: tabs)
    h.record(["feed.items"])
    #expect(await signIn(h, m.base + "/linear/signin"))
    #expect(await signIn(h, m.base + "/jira/signin"))
    h.rt.call("connections", "connect", ["id": "linear"])
    h.rt.call("connections", "connect", ["id": "jira"])
    #expect(await until(45) {
      h.rt.call("connections", "get", ["id": "linear"]).b("connected") && h.rt.call("connections", "get", ["id": "jira"]).b("connected")
    })

    // The sessions end (signed out of both sites): the cookies go away.
    let store = h.rt.webviews.store(for: Self.profile)
    let cookies: [HTTPCookie]? = await Wait.callback("cookies") { done in store.httpCookieStore.getAllCookies { done($0) } }
    for c in cookies ?? [] where c.name == MockServices.linearCookieName || c.name == MockServices.jiraCookieName {
      _ = await Wait.callback("delete cookie") { (done: @escaping @Sendable (Bool) -> Void) in store.httpCookieStore.delete(c) { done(true) } }
    }
    h.rt.plugins.emit("feed.refresh")
    #expect(await until(20) {
      !h.rt.call("connections", "get", ["id": "linear"]).b("connected") && !h.rt.call("connections", "get", ["id": "jira"]).b("connected")
    })
    #expect(events(h, "feed.items").contains { $0.s("source") == "linear" && $0.s("error") == "signed out" })
    #expect(events(h, "feed.items").contains { $0.s("source") == "jira" && $0.s("error") == "signed out" })
    #expect(tabs.toasts.contains { $0.hasPrefix("Signed out of Linear") })
    #expect(tabs.toasts.contains { $0.hasPrefix("Signed out of Jira") })
  }

  /// An unknown cookie set is worth one automatic probe; when it says "no session", the same set
  /// isn't probed again (every page load on the site is a cookie change). A new set probes again.
  @Test func linearProbesAnUnknownCookieSetOnce() async throws {
    let m = try mock()
    defer { m.stop() }
    let h = Harness()
    let tabs = Tabs()
    configure(h, m)
    h.rt.plugins.provide("tabs") { method, a in
      if method == "open" { tabs.opened.append(a.s("url")); return ["id": .string("tab-\(tabs.opened.count)")] }
      return ["ok": true]
    }
    h.rt.plugins.provide("spaces") { method, _ in
      method == "current" ? ["id": "s1"] : [["id": "s1", "name": "Personal", "profile": .string(Self.profile)]]
    }
    let c = ConnectionsCore(env: env(h, tabs))
    h.rt.plugins.provide("connections") { a, b in c.handle(a, b) }
    c.start()
    LinearCore(env: h.env).start()
    let store = h.rt.webviews.store(for: Self.profile).httpCookieStore
    func setCookie(_ name: String, _ value: String) async {
      await store.setCookie(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: name, .value: value, .expires: Date().addingTimeInterval(3600)])!)
    }

    // An anonymous cookie probes once: no session, and the same cookie set doesn't probe again.
    await setCookie("anon", "1")
    h.rt.plugins.emit("session.cookiesChanged", ["domain": "127.0.0.1", "profile": .string(Self.profile)])
    #expect(await until { m.log.contains("POST /graphql") })
    #expect(!h.rt.call("connections", "get", ["id": "linear"]).b("connected"))
    h.rt.plugins.emit("session.cookiesChanged", ["domain": "127.0.0.1", "profile": .string(Self.profile)])
    try? await Task.sleep(for: .milliseconds(600))
    #expect(m.log.filter { $0 == "POST /graphql" }.count == 1)

    // The sign-in changes the cookie set: probed again, and Linear connects by itself, with Undo.
    await setCookie(MockServices.linearCookieName, MockServices.linearCookie)
    h.rt.plugins.emit("session.cookiesChanged", ["domain": "127.0.0.1", "profile": .string(Self.profile)])
    #expect(await until { h.rt.call("connections", "get", ["id": "linear"]).b("connected") })
    #expect(h.rt.call("connections", "get", ["id": "linear"]).s("account") == "Riley")
    #expect(tabs.toasts == ["Linear connected"])
    #expect(tabs.toastTrees.last?.s("action") == "Undo")
    #expect(tabs.toastTrees.last?.s("id") == "connections.undo:linear")
    #expect(tabs.opened.isEmpty)
  }

  @Test func linearParsesTheGraphQLShapes() {
    let viewer = ValueJSON.parse(#"{"data":{"viewer":{"id":"u1","name":"Riley Chen","displayName":"Riley","email":"r@x.test"}}}"#)!
    #expect(LinearCore.account(viewer["data"]["viewer"]) == "Riley")
    #expect(LinearCore.account(ValueJSON.parse(#"{"id":"u1","name":"","displayName":"","email":"r@x.test"}"#)!) == "r@x.test")
    // The real unauthenticated answer (checked 2026-10-06), and 401/403, mean the session ended.
    let denied = ValueJSON.parse(#"{"errors":[{"message":"Authentication required, not authenticated","extensions":{"code":"AUTHENTICATION_ERROR"}}]}"#)!
    #expect(LinearCore.authGone(denied, 200))
    #expect(LinearCore.authGone(.null, 401) && LinearCore.authGone(.null, 403))
    #expect(!LinearCore.authGone(viewer, 200))
    let node = ValueJSON.parse(#"{"id":"lin-1","identifier":"ENG-123","title":"Checkout: retry card load","url":"https://linear.app/acme/issue/ENG-123/x","updatedAt":"2026-10-06T04:41:12.000Z","state":{"name":"In Progress"},"creator":{"displayName":"Maya Chen"},"team":{"key":"ENG","name":"Engineering"}}"#)!
    let it = LinearCore.item(node)
    #expect(it.s("id") == "linear:lin-1" && it.s("kind") == "assigned")
    #expect(it.s("detail") == "ENG-123 · Engineering · In Progress · from Maya Chen")
    #expect(it.i("ts") == Web.isoMs("2026-10-06T04:41:12.000Z"))
    #expect(it.s("importantKey") == "linear:ENG" && it.s("importantTitle") == "Engineering (ENG)")
    #expect(LinearCore.fingerprint([["name": "b", "value": "2"], ["name": "a", "value": "1"]]) == "a=1\nb=2")
  }

  @Test func jiraDerivesSitesFromCookiesAndParsesIssues() {
    let cookies: [Value] = [
      ["name": "cloud.session.token", "value": "t1", "domain": ".acme.atlassian.net"],
      ["name": "cloud.session.token", "value": "t2", "domain": "other.atlassian.net"],
      ["name": "cloud.session.token", "value": "", "domain": "empty.atlassian.net"],
      ["name": "atlassian.xsrf.token", "value": "x", "domain": "acme.atlassian.net"],
    ]
    #expect(JiraCore.siteHosts(cookies) == ["acme.atlassian.net", "other.atlassian.net"])
    #expect(JiraCore.siteName("acme.atlassian.net") == "acme")
    #expect(JiraCore.siteName("127.0.0.1") == "127.0.0.1")
    let site = JiraCore.Site(host: "acme.atlassian.net", base: "https://acme.atlassian.net", account: "Riley")
    let issue = ValueJSON.parse(#"{"key":"ENG-101","fields":{"summary":"Offline mode drops queued replies","status":{"name":"In Progress"},"updated":"2026-10-06T04:41:12.250+0000","reporter":{"displayName":"Maya Chen"},"project":{"key":"ENG","name":"Engineering"}}}"#)!
    let it = JiraCore.item(issue, site: site, multi: false)
    #expect(it.s("id") == "jira:acme.atlassian.net:ENG-101")
    #expect(it.s("kind") == "assigned" && it.s("title") == "Offline mode drops queued replies")
    #expect(it.s("detail") == "ENG-101 · Engineering · In Progress · from Maya Chen")
    #expect(it.s("url") == "https://acme.atlassian.net/browse/ENG-101")
    // Jira's "+0000" offset reads the same instant as "Z".
    #expect(it.i("ts") == Web.isoMs("2026-10-06T04:41:12.250Z"))
    #expect(it.s("importantKey") == "jira:acme.atlassian.net:ENG" && it.s("importantTitle") == "Engineering")
    // With several sites, the detail and the important title name the site.
    let multi = JiraCore.item(issue, site: site, multi: true)
    #expect(multi.s("detail").hasSuffix(" · acme.atlassian.net"))
    #expect(multi.s("importantTitle") == "Engineering · acme.atlassian.net")
    #expect(JiraCore.authGone(401) && JiraCore.authGone(403) && JiraCore.authGone(302) && !JiraCore.authGone(200))
  }

  // MARK: Important channels and repos

  @Test func importantItemsRankFirstAndAreNeverDropped() {
    let now: Int64 = 1_800_000_000_000
    var items: [Value] = (0..<30).map { i in
      ["id": .string("r\(i)"), "kind": "review", "ts": .int(now - Int64(i) * 60_000), "importantKey": .string("github:x/r\(i)"), "summary": .string("review \(i)")]
    }
    items.append(["id": "old", "kind": "mention", "ts": .int(now - 3_600_000 * 48), "importantKey": "slack:T1:C9", "summary": "old mention"])
    items.append(["id": "dm", "kind": "dm", "ts": .int(now - 3_600_000 * 72), "summary": "a dm"])
    let imp: Set<String> = ["slack:T1:C9"]
    let ranked = BriefingCore.rank(items, now: now, affinity: [:], important: imp)
    #expect(ranked.first?.s("id") == "old")  // an old mention in an important channel beats fresh reviews
    // Cut to 25: the important item survives even when it would rank past the cut.
    let plain = BriefingCore.rank(items, now: now, affinity: [:])
    #expect(!plain.prefix(25).contains { $0.s("id") == "old" })
    let kept = BriefingCore.keep(plain, max: 25, important: imp)
    #expect(kept.count == 26 && kept.contains { $0.s("id") == "old" })
    // The AI brief's input: all important lines, marked, then the rest up to the cap.
    let lines = BriefingCore.aiLines(items, important: imp, max: 5)
    #expect(lines.count == 5)
    #expect(lines.first == "Important: old mention")
    #expect(BriefingCore.aiLines(items, important: ["github:x/r1", "github:x/r2", "slack:T1:C9"], max: 2).count == 3)
    #expect(BriefingCore.plainSummary(ranked).contains("30 review requests"))
  }

  @Test func importantPickerInSettingsAndCommands() {
    let h = Harness()
    var registered: [String: String] = [:]
    var unregistered: [String] = []
    h.rt.plugins.provide("commands") { m, a in
      if m == "register" { registered[a.s("id")] = a.s("title") }
      if m == "unregister" { unregistered.append(a.s("id")); registered[a.s("id")] = nil }
      return ["ok": true]
    }
    h.rt.plugins.provide("connections") { m, _ in
      m == "list" ? [["id": "github", "title": "GitHub", "connected": true], ["id": "slack", "title": "Slack", "connected": true]] : .null
    }
    var settings: Value = .null
    var e = h.env
    let base = e.invoke
    e.invoke = { s, m, a in
      if s == "settings", m == "register" { settings = a }
      return base(s, m, a)
    }
    let b = BriefingCore(env: e)
    h.rt.plugins.provide("briefing") { m, a in b.handle(m, a) }
    b.start()
    #expect(registered["briefing.important"] == "Important Channels and Repos…")
    let now = h.clock
    h.rt.plugins.emit("feed.items", ["source": "github", "items": [
      ["id": "g1", "source": "github", "kind": "review", "ts": .int(now - 60_000), "importantKey": "github:denhq/den", "importantTitle": "denhq/den", "summary": "review"],
      ["id": "g2", "source": "github", "kind": "ci", "ts": .int(now - 120_000), "importantKey": "github:denhq/site", "importantTitle": "denhq/site", "summary": "ci"],
    ]])
    h.rt.plugins.emit("feed.items", ["source": "slack", "items": [
      ["id": "s1", "source": "slack", "kind": "mention", "ts": .int(now - 3_600_000), "importantKey": "slack:T1:C1", "importantTitle": "#eng · Acme", "summary": "m"],
      ["id": "s2", "source": "slack", "kind": "dm", "ts": .int(now), "summary": "dm"],  // DMs aren't channels
    ]])
    #expect(registered["briefing.mark:github:denhq/den"] == "Mark denhq/den as Important")
    #expect(registered["briefing.mark:slack:T1:C1"] == "Mark #eng · Acme as Important")
    func control() -> Value { settings["controls"].array?.first { $0.s("key") == "important" } ?? .null }
    #expect(control()["items"].array?.map { $0.s("id") } == ["github:denhq/den", "github:denhq/site", "slack:T1:C1"])
    #expect(control()["items"].array?.allSatisfy { $0["buttons"][0].s("id") == "mark" } == true)

    // From the command bar.
    h.rt.plugins.emit("commands.run", ["id": "briefing.mark:slack:T1:C1"])
    #expect(h.rt.call("briefing", "importantList") == [["key": "slack:T1:C1", "title": "#eng · Acme", "source": "slack"]])
    #expect(h.storage("briefing", "important") == [["key": "slack:T1:C1", "title": "#eng · Acme", "source": "slack"]])
    #expect(registered["briefing.unmark:slack:T1:C1"] == "Unmark #eng · Acme as Important")
    #expect(registered["briefing.mark:slack:T1:C1"] == nil && unregistered.contains("briefing.mark:slack:T1:C1"))
    #expect(control()["items"].array?.first?.s("id") == "slack:T1:C1")
    #expect(control()["items"].array?.first?["buttons"][0].s("id") == "remove")
    // The older Slack mention now leads the feed.
    #expect(h.rt.call("briefing", "state")["feed"].array?.first?.s("id") == "s1")

    // From Settings: mark a repo, remove the channel.
    h.rt.plugins.emit("settings.action", ["id": "briefing", "key": "important", "item": "github:denhq/site", "button": "mark"])
    h.rt.plugins.emit("settings.action", ["id": "briefing", "key": "important", "item": "slack:T1:C1", "button": "remove"])
    #expect(h.rt.call("briefing", "importantList").array?.map { $0.s("key") } == ["github:denhq/site"])
    #expect(h.rt.call("briefing", "state")["feed"].array?.first?.s("id") == "g2")
    // The service method.
    #expect(h.rt.call("briefing", "important", ["key": "github:denhq/site", "on": false]) == ["ok": true])
    #expect(h.rt.call("briefing", "importantList") == [])
  }

  @Test func feedItemsCarryImportantKeys() {
    let route = ValueJSON.parse(#"{"results":[{"author_name":"a","issue":{"issue":{"pull_request_id":1}},"repo":{"repository":{"name":"den","owner_login":"denhq"}},"number":7,"hl_title":"t","created":"2026-09-27T00:00:00Z"}],"logged_in":true}"#)!
    let g = GitHubCore.parse(route, kind: "review", base: "https://github.com")
    #expect(g[0].s("importantKey") == "github:denhq/den")
    #expect(g[0].s("importantTitle") == "denhq/den")
  }

  // MARK: Pure logic

  @Test func webHelpers() {
    func ms(_ s: String) -> Int64 {
      let f = ISO8601DateFormatter()
      f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      return Int64((f.date(from: s)!.timeIntervalSince1970 * 1000).rounded())
    }
    #expect(Web.isoMs("1970-01-01T00:00:00Z") == 0)
    #expect(Web.isoMs("2026-09-27T04:41:12.000+01:00") == ms("2026-09-27T03:41:12.000Z"))
    #expect(Web.isoMs("2026-09-27T03:41:12.250Z") == ms("2026-09-27T03:41:12.250Z"))
    #expect(Web.isoMs("2026-02-28T23:59:59.000-05:30") == ms("2026-03-01T05:29:59.000Z"))
    #expect(Web.slackMs("1700000000.123456") == 1_700_000_000_123)
    #expect(Web.slackMs("1700000000") == 1_700_000_000_000)
    #expect(Web.date(ms("2026-09-27T12:00:00.000Z")) == "2026-09-27")
    #expect(Web.date(ms("2024-02-29T00:00:00.000Z")) == "2024-02-29")
    #expect(Web.form([("token", "xoxc-1"), ("query", "<@U1> after:2026-09-25")]) == "token=xoxc-1&query=%3C%40U1%3E%20after%3A2026-09-25")
    #expect(Web.plain("Fix <em>session</em> &amp; &quot;cookies&quot; &lt;tag&gt;") == "Fix session & \"cookies\" <tag>")
    #expect(Web.query("https://a.slack.com/archives/C1/p1?thread_ts=17.5&cid=C1", "thread_ts") == "17.5")
    #expect(Web.ago(1000, now: 1000 + 3 * 3_600_000) == "3h")
  }

  @Test func rankingIsKindThenRecencyThenAffinity() {
    let now: Int64 = 1_800_000_000_000
    let items: [Value] = [
      ["id": "a", "kind": "mention", "ts": .int(now - 60_000), "actor": "jon", "where": "#eng"],
      ["id": "b", "kind": "review", "ts": .int(now - 3_600_000 * 30), "actor": "lee", "where": "den"],
      ["id": "c", "kind": "mention", "ts": .int(now - 3_600_000 * 5), "actor": "ana", "where": "#launch"],
      ["id": "d", "kind": "assigned", "ts": .int(now), "actor": "x", "where": "api"],
    ]
    // a: 34 + 24 = 58, c: 34 + 19 = 53, b: 50 + 0 (30 h old) = 50, d: 22 + 24 = 46.
    #expect(BriefingCore.rank(items, now: now, affinity: [:]).map { $0.s("id") } == ["a", "c", "b", "d"])
    // You keep opening Ana's messages: she moves up (+15, the cap).
    #expect(BriefingCore.rank(items, now: now, affinity: ["actor:ana": 3, "where:#launch": 2]).map { $0.s("id") } == ["c", "a", "b", "d"])
    #expect(BriefingCore.plainSummary([["kind": "dm"]]) == "1 unread DM.")
    #expect(BriefingCore.plainSummary([]) == "You're all caught up.")
  }

  @Test func githubParsesTheRealSearchShape() {
    // Trimmed from a real github.com/search JSON response (2026-09-27).
    let route = ValueJSON.parse(#"""
      {"results":[{"author_name":"AnthonyLatsis","id":"4651428145","issue":{"issue":{"pull_request_id":4651428145}},
        "repo":{"repository":{"id":44838949,"name":"swift","owner_id":42816656,"owner_login":"swiftlang"}},
        "labels":[],"num_comments":0,"number":92677,"state":"open","hl_title":"minimalstdlib: Archive with the just-built LLVM tools",
        "created":"2026-09-27T04:41:12.000+01:00","reviewable_state":"ready","merged":false},
       {"author_name":"FranzBusch","id":"5602428918","issue":{"issue":{"pull_request_id":null}},
        "repo":{"repository":{"name":"swift","owner_login":"swiftlang"}},"number":92681,"hl_title":"`withDeadline` timer &amp; <em>cancel</em>",
        "created":"2026-09-27T13:56:30.000+02:00"}],
       "logged_in":true}
      """#)!
    let items = GitHubCore.parse(route, kind: "review", base: "https://github.com")
    #expect(items.map { $0.s("url") } == ["https://github.com/swiftlang/swift/pull/92677", "https://github.com/swiftlang/swift/issues/92681"])
    #expect(items[1].s("title") == "`withDeadline` timer & cancel")
    #expect(items[0].s("detail") == "swiftlang/swift #92677 · AnthonyLatsis")
    #expect(items[0].i("ts") == Web.isoMs("2026-09-27T03:41:12.000Z"))
  }
}
