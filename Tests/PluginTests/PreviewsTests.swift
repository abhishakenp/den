import AppKit
import CordisValue
import Foundation
import Testing

@testable import DenHost
@testable import PluginCores

/// The `previews` plugin: provider matching, caching, providers against mocked sites, and the
/// `tabs` side (hover → previews.show, the Library sheet).
@MainActor
@Suite(.serialized)
struct PreviewsTests {
  /// Stands in for `net`, `session`, `webviews.eval/snapshot`, `tabs.open` and records the cards.
  final class Mock {
    var responses: [(String, Value)] = []  // url substring -> {status, json | text}
    var fetches: [Value] = []
    var cards: [Value] = []
    var evalValue: Value = .null
    var sessionValue: Value = .null
    var snapshots: [Value] = []
    var opened: [Value] = []
    var hold = false
    var realEval = false
    var held: [Value] = []
    var card: Value { cards.last ?? .null }
  }

  func start(_ h: Harness, _ m: Mock) -> PreviewsCore {
    let base = h.env
    var env = base
    let rt = h.rt
    env.invoke = { s, method, a in
      switch (s, method) {
      case ("net", "fetch"):
        m.fetches.append(a)
        let url = a.s("url")
        var r: Value = m.responses.first { Text.contains(url, $0.0) }?.1 ?? ["status": 404, "json": ["message": "Not Found"]]
        r.put("id", a["id"])
        r.put("ok", true)
        if m.hold { m.held.append(r) } else { MainActor.assumeIsolated { rt.plugins.emit("net.result", r) } }
        return ["id": a["id"]]
      case ("session", "eval"):
        let r: Value = ["id": a["id"], "ok": .bool(!m.sessionValue.isNull), "value": m.sessionValue]
        MainActor.assumeIsolated { rt.plugins.emit("session.result", r) }
        return ["id": a["id"]]
      case ("webviews", "eval") where !m.realEval:
        if m.evalValue.isNull { return ["error": "webviews: 'tab-9' is not loaded"] }
        let r: Value = ["request": a["request"], "webview": a["id"], "ok": true, "value": m.evalValue]
        MainActor.assumeIsolated { rt.plugins.emit("webviews.evalResult", r) }
        return ["request": a["request"]]
      case ("webviews", "snapshot"):
        m.snapshots.append(a)
        return ["pending": true]
      case ("webviews", "get") where !m.realEval:
        return ["id": a["id"], "profile": "default", "live": true]
      case ("ui", "set") where a.s("slot") == "hoverCard":
        m.cards.append(a["tree"])
        return ["ok": true]
      case ("tabs", "open"):
        m.opened.append(a)
        return ["id": "tab-new"]
      default:
        return base.invoke(s, method, a)
      }
    }
    let core = PreviewsCore(env: env)
    rt.plugins.provide("previews") { mm, aa in core.handle(mm, aa) }
    core.start()
    return core
  }

  func show(_ h: Harness, _ url: String, anchor: String = "tab-1", title: String = "Tab", webview: String = "tab-1", selected: Bool = false) {
    h.rt.call("previews", "show", ["anchor": .string(anchor), "url": .string(url), "title": .string(title), "icon": "sf:globe",
                                    "webview": .string(webview), "selected": .bool(selected)])
  }

  func texts(_ list: Value) -> [String] { (list.array ?? []).map { $0.s("text") } }

  /// Key order doesn't matter for a tree: sort object keys all the way down.
  func canon(_ v: Value) -> Value {
    if let a = v.array { return .array(a.map(canon)) }
    if case let .object(pairs) = v { return .object(pairs.sorted { $0.0 < $1.0 }.map { ($0.0, canon($0.1)) }) }
    return v
  }

  // MARK: Matching

  @Test func patternsPickTheMostSpecificProvider() {
    let h = Harness()
    let core = start(h, Mock())
    #expect(core.match("https://github.com/apple/swift/pull/123")?.id == "github.pr")
    #expect(core.match("https://github.com/apple/swift/pull/123/files?w=1#diff")?.id == "github.pr")
    #expect(core.match("https://www.github.com/apple/swift/issues/9")?.id == "github.issue")
    #expect(core.match("https://github.com/apple/swift")?.id == "page")
    #expect(core.match("https://calendar.google.com/calendar/u/0/r")?.id == "calendar")
    #expect(core.match("https://mail.google.com/mail/u/1/#inbox")?.id == "gmail")
    #expect(core.match("https://app.slack.com/client/T01/C02")?.id == "slack")
    #expect(core.match("https://acme.slack.com/archives/C1")?.id == "slack")
    #expect(core.match("https://example.com")?.id == "page")
    // A plugin's more specific pattern beats a built-in one.
    h.rt.call("previews", "register", ["pattern": "github.com/apple/*/pull/*", "provider": "apple.pr"])
    #expect(core.match("https://github.com/apple/swift/pull/1")?.id == "apple.pr")
    #expect(core.match("https://github.com/other/x/pull/1")?.id == "github.pr")
    #expect(Pattern.glob(Array("github.com/*/*/pull/*".utf8), Array("github.com/a/b/pull/7".utf8)))
    #expect(!Pattern.glob(Array("github.com/*/*/pull/*".utf8), Array("github.com/a/b/issues/7".utf8)))
  }

  // MARK: GitHub

  static let prURL = "https://github.com/denhq/den/pull/482"

  /// A PR with failing CI, a merge conflict and changes requested (the scenario data).
  static func mockGitHub(_ m: Mock) {
    for (k, v) in PreviewScenarios.githubFixtures { m.responses.append((k, v)) }
  }

  @Test func pullRequestCardShowsStateChecksConflictsAndReviews() {
    let h = Harness()
    let m = Mock()
    Self.mockGitHub(m)
    _ = start(h, m)
    show(h, Self.prURL, title: "Fix the parser · Pull Request #482")
    #expect(m.cards.count == 2)  // header at once (loading), then the data
    #expect(m.cards[0]["loading"] == true)
    let c = m.card
    #expect(c.s("type") == "hoverCard" && c.s("anchor") == "tab-1")
    #expect(c.s("title") == "Parser: accept trailing commas in tuple patterns")
    #expect(c.s("accessory") == "#482" && c.s("subtitle") == "denhq/den")
    #expect(texts(c["badges"]) == ["Open", "2 failing", "Conflicts", "Changes requested"])
    let sections = c.a("sections")
    #expect(sections[0].a("rows").map { $0.s("title") } == ["fix/tuple-trailing-comma", "Merge conflicts"])
    #expect(sections[0].a("rows")[0].s("accessory") == "into main")
    #expect(sections[1].s("title") == "Checks · 2 failing, 1 pending, 2 passing")
    #expect(sections[1].a("rows").map { $0.s("title") } == ["build (macOS)", "test (linux)", "test (macOS)", "2 more checks"])
    #expect(sections[1].a("rows")[0].s("status") == "failure")
    #expect(sections[2].s("title") == "Reviews")
    #expect(sections[2].a("rows").map { $0.s("title") + ":" + $0.s("accessory") } == ["mira:Changes requested", "jonas:Requested"])
    #expect(Text.hasPrefix(c.s("footer"), "+214 −37 · 6 files · abhi"))
    // Four API calls: the PR, then check runs, statuses and reviews for its head commit.
    #expect(m.fetches.count == 4)
    #expect(m.fetches.allSatisfy { Text.hasPrefix($0.s("url"), "https://api.github.com/repos/denhq/den/") && $0.s("plugin") == "previews" })
    // Matches the tree the snapshot scenario renders.
    var expected = PreviewScenarios.prCard
    for k in ["anchor", "icon", "type", "id"] { expected.put(k, c[k]) }
    for k in ["badges", "sections", "title", "subtitle", "accessory"] { #expect(canon(c[k]) == canon(expected[k]), "field \(k)") }
  }

  @Test func cachedWithinTTLAndSharedWhileInFlight() {
    let h = Harness()
    let m = Mock()
    Self.mockGitHub(m)
    let core = start(h, m)
    m.hold = true
    show(h, Self.prURL)
    show(h, Self.prURL, anchor: "tab-2")  // a second hover before the answer: no second request
    #expect(m.fetches.count == 1)
    #expect(core.fetches == 1)
    m.hold = false
    for r in m.held { h.rt.plugins.emit("net.result", r) }
    m.held = []
    #expect(m.fetches.count == 4)
    #expect(m.card.s("anchor") == "tab-2" && m.card["loading"].isNull)
    // Within the TTL: the cached card, no network.
    let before = m.cards.count
    show(h, Self.prURL, anchor: "tab-1")
    #expect(m.fetches.count == 4)
    #expect(m.cards.count == before + 1)
    #expect(m.card["loading"].isNull && texts(m.card["badges"]).contains("2 failing"))
    // After it: the stale card shows at once (not a loading one) and refreshes behind it.
    h.clock += 61_000
    show(h, Self.prURL)
    #expect(m.cards[before + 1]["loading"].isNull)
    #expect(m.fetches.count == 8)
  }

  @Test func nothingRunsUntilAHover() {
    let h = Harness()
    let m = Mock()
    let core = start(h, m)
    h.fireTimers()
    #expect(h.timers.isEmpty)
    #expect(m.fetches.isEmpty && m.cards.isEmpty && m.snapshots.isEmpty)
    #expect(core.requests.inFlight == 0)
  }

  @Test func privateRepositoryFallsBackToTheSignedInPage() {
    let h = Harness()
    let m = Mock()
    m.sessionValue = ["status": 200, "state": "OPEN", "title": "Secret thing", "head": "wip", "base": "main", "author": "abhi", "merged": false]
    _ = start(h, m)
    show(h, "https://github.com/acme/private/pull/7")
    #expect(m.card.s("title") == "Secret thing")
    #expect(texts(m.card["badges"]) == ["Open"])
    #expect(m.card.a("sections")[0].a("rows")[0].s("title") == "wip")
  }

  @Test func issueCard() {
    let h = Harness()
    let m = Mock()
    m.responses = [("/issues/12", ["status": 200, "json": [
      "title": "Crash on launch", "state": "closed", "state_reason": "completed", "comments": 5, "user": ["login": "sam"],
      "labels": [["name": "bug"], ["name": "p1"]], "assignees": [["login": "abhi"]], "updated_at": "2026-09-27T10:00:00Z",
    ]])]
    _ = start(h, m)
    show(h, "https://github.com/denhq/den/issues/12")
    #expect(texts(m.card["badges"]) == ["Closed", "bug", "p1"])
    #expect(m.card.s("footer").hasPrefix("5 comments · opened by sam"))
  }

  // MARK: Calendar, Gmail, Slack

  @Test func calendarShowsTheRestOfTheDayWithJoin() {
    let h = Harness()
    let m = Mock()
    m.evalValue = PreviewScenarios.calendarEval
    _ = start(h, m)
    show(h, "https://calendar.google.com/calendar/u/0/r", webview: "tab-cal")
    let c = m.card
    #expect(c.s("title") == "Rest of today" && c.s("subtitle") == "Sunday, September 27")
    // The 9:00 standup is over; design review is on now; 1:1 is next.
    #expect(c.a("sections")[0].a("rows").map { $0.s("title") } == ["Company offsite", "Design review", "1:1 with Mira", "Ship den 0.2", "Dinner"])
    #expect(texts(c["badges"]) == ["Now · Design review"])
    #expect(c.a("actions")[0].s("title") == "Join Design review")
    #expect(c.a("actions")[0].s("url") == "https://meet.google.com/abc-defg-hij")
    for k in ["badges", "sections", "actions", "title", "subtitle"] { #expect(canon(c[k]) == canon(PreviewScenarios.calendarCard[k]), "field \(k)") }
    // A tab that isn't loaded: a hint, and it's asked again next time.
    m.evalValue = .null
    _ = h.rt.call("previews", "clear")
    show(h, "https://calendar.google.com/calendar/u/0/r", webview: "tab-cal")
    #expect(Text.contains(m.card.s("empty"), "Open Calendar"))
  }

  /// The real page script, run by `webviews.eval` in a live page shaped like Google Calendar's
  /// (event chips with `data-eventid` and a "time, title, …, date" label).
  @Test func calendarScriptReadsEventChipsInALivePage() async throws {
    let h = Harness()
    let m = Mock()
    m.realEval = true
    h.rt.webviews.allowScript = { plugin, host in plugin == "previews" && host == "calendar.google.com" }
    _ = start(h, m)
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US")
    f.dateFormat = "MMMM d, yyyy"
    let today = f.string(from: Date()), yesterday = f.string(from: Date().addingTimeInterval(-86_400))
    let html = """
      <html><body>
      <div data-eventid="a" role="button"><div>All day, Company offsite, \(today)</div></div>
      <div data-eventid="b" role="button" aria-label="11:50pm to 11:58pm, Late sync, Abhi, Accepted, Location: https://meet.google.com/abc-defg-hij, \(today)">x</div>
      <div data-eventid="b" role="button">duplicate chip of the same event</div>
      <div data-eventid="c" role="button"><span>11:59pm, Last call, \(today)</span></div>
      <div data-eventid="d" role="button"><span>3pm to 4pm, Yesterday's thing, \(yesterday)</span></div>
      </body></html>
      """
    h.rt.call("webviews", "create", ["id": "cal"])
    h.rt.webviews.materialize("cal")?.loadHTMLString(html, baseURL: URL(string: "https://calendar.google.com/"))
    for _ in 0..<60 where h.rt.call("webviews", "get", ["id": "cal"])["loading"] != false { try await Task.sleep(for: .milliseconds(50)) }
    try await Task.sleep(for: .milliseconds(200))
    // Another plugin (no session:calendar.google.com) may not read the page.
    #expect(h.rt.call("webviews", "eval", ["id": "cal", "plugin": "tabs", "script": "return 1"]).isErr)
    show(h, "https://calendar.google.com/calendar/u/0/r", webview: "cal")
    for _ in 0..<60 where m.card["sections"].isNull && m.card["empty"].isNull { try await Task.sleep(for: .milliseconds(50)) }
    let rows = m.card.a("sections").first?.a("rows") ?? []
    #expect(rows.map { $0.s("title") } == ["Company offsite", "Late sync", "Last call"])
    #expect(rows.count == 3 && rows[1].s("subtitle") == "11:50pm to 11:58pm" && rows[1].s("url") == "https://meet.google.com/abc-defg-hij")
    #expect(m.card.a("actions").first?.s("title") == "Join Late sync")
  }

  /// The session scripts (GitHub private PRs, Slack workspaces) run on sites den can't sign in to
  /// in tests; at least make sure WebKit parses them.
  @Test func sessionScriptsParse() async throws {
    let h = Harness()
    h.rt.webviews.allowScript = { _, _ in true }
    h.rt.call("webviews", "create", ["id": "js"])
    h.rt.webviews.materialize("js")?.loadHTMLString("<html></html>", baseURL: URL(string: "https://js.example/"))
    for _ in 0..<60 where h.rt.call("webviews", "get", ["id": "js"])["loading"] != false { try await Task.sleep(for: .milliseconds(50)) }
    var captured = ""
    let m = Mock()
    let core = start(h, m)
    _ = core
    m.sessionValue = ["state": ""]
    // Capture the GitHub fallback script as the plugin builds it.
    var env = h.env
    let base = env.invoke
    env.invoke = { s, method, a in
      if s == "session" { captured = a.s("script"); return ["error": "stop"] }
      if s == "net" { let r: Value = ["id": a["id"], "ok": true, "status": 404]; MainActor.assumeIsolated { h.rt.plugins.emit("net.result", r) }; return ["id": a["id"]] }
      return base(s, method, a)
    }
    let probe = PreviewsCore(env: env)
    GitHub.sessionPR(probe, PreviewsCore.Request(anchor: "a", url: "", title: "", icon: "", webview: "", profile: "default", selected: false, kind: "", items: []),
                     repo: "denhq/den", n: 482) { _ in }
    #expect(Text.contains(captured, "fetch('/denhq/den/pull/482'"))
    for src in [captured, Slack.configScript, Calendar.script] {
      let lit = String(data: try JSONSerialization.data(withJSONObject: [src]), encoding: .utf8)!
      let check = "const src = " + lit + "[0]; try { new (Object.getPrototypeOf(async function(){}).constructor)(src); return 'ok'; } catch (e) { return String(e); }"
      let r = h.rt.call("webviews", "eval", ["id": "js", "plugin": "previews", "script": .string(check), "request": "syntax"])
      #expect(!r.isErr)
      var result: Value = .null
      let token = h.rt.plugins.on("webviews.evalResult") { v in if v.s("request") == "syntax" { result = v } }
      for _ in 0..<40 where result.isNull { try await Task.sleep(for: .milliseconds(25)) }
      _ = token
      #expect(result["value"] == "ok", "\(result)")
    }
  }

  @Test func gmailUnreadFromTheAtomFeed() {
    let h = Harness()
    let m = Mock()
    m.responses = [("feed/atom", ["status": 200, "text": .string(PreviewScenarios.gmailAtom)])]
    _ = start(h, m)
    show(h, "https://mail.google.com/mail/u/1/#inbox")
    #expect(m.fetches[0].s("url") == "https://mail.google.com/mail/u/1/feed/atom")
    #expect(m.fetches[0]["session"] == true)
    let c = m.card
    #expect(texts(c["badges"]) == ["3 unread"])
    #expect(c.s("subtitle") == "abhi@example.com")
    let rows = c.a("sections")[0].a("rows")
    #expect(rows.map { $0.s("title") } == ["Mira Chen", "GitHub", "Jonas & Co"])
    #expect(rows[0].s("subtitle") == "Offsite agenda & travel")
    #expect(rows[0].s("url") == "https://mail.google.com/mail/u/1?account_id=abhi@example.com&message_id=1&view=conv")
    // Signed out: Gmail answers with its sign-in page instead of a feed.
    m.responses = [("feed/atom", ["status": 200, "text": "<html>Sign in</html>"])]
    _ = h.rt.call("previews", "clear")
    show(h, "https://mail.google.com/mail/u/0/")
    #expect(Text.contains(m.card.s("empty"), "Sign in to Gmail"))
  }

  @Test func slackUnreadCounts() {
    let h = Harness()
    let m = Mock()
    m.sessionValue = [["id": "T01", "name": "Acme", "url": "https://acme.slack.com/", "token": "xoxc-1"]]
    m.responses = [("client.counts", ["status": 200, "json": [
      "ok": true,
      "channels": [["id": "C1", "has_unreads": true, "mention_count": 2], ["id": "C2", "has_unreads": true, "mention_count": 0], ["id": "C3", "has_unreads": false, "mention_count": 0]],
      "ims": [["id": "D1", "has_unreads": true, "mention_count": 1]], "mpims": [],
      "threads": ["has_unreads": true, "mention_count": 0],
    ]])]
    let core = start(h, m)
    show(h, "https://app.slack.com/client/T01/C1")
    #expect(m.fetches[0].s("method") == "POST" && m.fetches[0].s("body") == "token=xoxc-1" && m.fetches[0]["session"] == true)
    #expect(texts(m.card["badges"]) == ["3 mentions", "1 DM", "2 channels"])
    #expect(m.card.s("title") == "Acme")
    #expect(core.slackTeams?.count == 1)  // token kept in memory for the next hover
  }

  // MARK: Generic page

  @Test func otherPagesGetACachedSmallSnapshot() {
    let h = Harness()
    let m = Mock()
    let core = start(h, m)
    show(h, "https://example.com/post", title: "A post", webview: "tab-3")
    #expect(m.card["imagePending"] == true && m.card.s("title") == "A post" && m.card.s("subtitle") == "example.com")
    #expect(m.snapshots.count == 1)
    #expect(m.snapshots[0]["width"] == 320 && m.snapshots[0].s("format") == "jpeg")
    let path = m.snapshots[0].s("path")
    h.rt.plugins.emit("webviews.snapshot", ["id": "tab-3", "path": .string(path), "ok": true])
    #expect(m.card.s("image") == path)
    // Cached: the next hover shows the image at once, no new snapshot.
    show(h, "https://example.com/post", title: "A post", webview: "tab-3")
    #expect(m.card.s("image") == path && m.snapshots.count == 1)
    // The selected tab is on screen already: no generic card for it.
    let n = m.cards.count
    show(h, "https://example.com/post", webview: "tab-3", selected: true)
    #expect(m.cards.count == n)
    #expect(core.fetches == 0)
  }

  @Test func cardActionsOpenTheirLinks() {
    let h = Harness()
    let m = Mock()
    _ = start(h, m)
    h.action("hoverCard", "action", ["action": "join", "anchor": "tab-1", "url": "https://meet.google.com/x"])
    h.action("hoverCard", "open", ["row": "c1", "anchor": "tab-1", "url": "https://github.com/a/b/runs/1"])
    #expect(m.opened.map { $0.s("url") } == ["https://meet.google.com/x", "https://github.com/a/b/runs/1"])
  }

  // MARK: tabs

  @Test func tabsAsksForAPreviewOnHoverAndLibraryOpensFromTheFooter() throws {
    let h = Harness()
    let m = Mock()
    _ = start(h, m)
    let tabs = h.startTabs()
    let space = h.spaceIds[0]
    let id = h.tabs("open", ["url": "https://example.org/a", "spaceId": .string(space)]).s("id")
    h.tabs("select", ["id": .string(h.ids("today")[1])])
    h.action(id, "hover")
    #expect(m.card.s("anchor") == id)
    #expect(m.card.s("subtitle") == "example.org")
    // Folders list their tabs (from cache only).
    let fid = h.tabs("createFolder", ["spaceId": .string(space), "title": "Reading", "tabIds": [.string(id)]]).s("id")
    h.action(fid, "hover")
    #expect(m.card.s("anchor") == fid && m.card.s("subtitle") == "1 tab")
    #expect(m.card.a("sections")[0].a("rows")[0].s("subtitle") == "example.org")

    // Library: the footer button (spaces.library) opens the archive sheet.
    h.tabs("close", ["id": .string(h.ids("today")[0])])
    #expect(!tabs.archive.isEmpty)
    h.rt.plugins.emit("spaces.library", .null)
    #expect(h.rt.call("ui", "get")["overlays"].array?.contains("overlay.library") == true)
    let lib = h.rt.ui.library.node
    #expect(lib.s("id") == "tabs.library" && lib.a("items").count == tabs.archive.count)
    let first = tabs.archive[0].s("id")
    h.action("tabs.library", "restore", ["item": .string(first)])
    #expect(h.rt.call("ui", "get")["overlays"].array?.contains("overlay.library") == false)
    #expect(h.selected == first)
    // Clear Archive asks first.
    h.tabs("close", ["id": .string(first)])
    h.rt.plugins.emit("spaces.library", .null)
    h.action("tabs.library", "clear")
    #expect(h.rt.ui.dialog.node.s("id") == "tabs.clearArchive")
    h.action("tabs.clearArchive", "button", ["button": "clear"])
    #expect(tabs.archive.isEmpty)
    #expect(h.rt.ui.library.node.a("items").isEmpty)
    h.action("tabs.library", "dismiss")
    #expect(h.rt.call("ui", "get")["overlays"].array?.contains("overlay.library") == false)
  }
}
