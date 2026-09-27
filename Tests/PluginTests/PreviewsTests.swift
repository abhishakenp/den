import AppKit
import CordisValue
import Foundation
import DenTestSupport
import Testing

@testable import DenHost
@testable import PluginCores

/// The `previews` plugin: provider matching, caching, the tab card and PR peek composed from the
/// host's generic nodes, ⇧-hover link cards, and the `tabs` side (hover → previews.show → tabs.act).
@MainActor
@Suite(.serialized, .watchdog)
struct PreviewsTests {
  /// Stands in for `net`, `session`, `webviews.eval/snapshot`, `tabs.*` and records the cards.
  final class Mock {
    var responses: [(String, Value)] = []  // url substring -> {status, json | text}
    var fetches: [Value] = []
    var cardArgs: [Value] = []
    var evalValue: Value = .null
    var sessionValue: Value = .null
    var snapshots: [Value] = []
    var opened: [Value] = []
    var acts: [Value] = []
    var calls: [(String, String, Value)] = []
    var hold = false
    var realEval = false
    var realCard = false
    var held: [Value] = []
    /// Trees shown (nulls excluded) and the last one.
    var cards: [Value] { cardArgs.filter { !$0["tree"].isNull }.map { $0["tree"] } }
    var card: Value { cards.last ?? .null }
    var last: Value { cardArgs.last ?? .null }
  }

  func start(_ h: Harness, _ m: Mock) -> PreviewsCore {
    let base = h.env
    var env = base
    let rt = h.rt
    env.invoke = { s, method, a in
      m.calls.append((s, method, a))
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
      case ("webviews", "watchLinks"):
        return ["ok": true]
      case ("ui", "card") where !m.realCard:
        m.cardArgs.append(a)
        return ["ok": true, "shown": true]
      case ("tabs", "open"):
        m.opened.append(a)
        return ["id": "tab-new"]
      case ("tabs", "act"):
        m.acts.append(a)
        return ["ok": true]
      default:
        return base.invoke(s, method, a)
      }
    }
    let core = PreviewsCore(env: env)
    rt.plugins.provide("previews") { mm, aa in core.handle(mm, aa) }
    core.start()
    return core
  }

  func show(_ h: Harness, _ url: String, anchor: String = "tab-1", title: String = "Tab", webview: String = "tab-1", selected: Bool = false,
            kind: String = "today", extra: Value = [:]) {
    var a: Value = ["anchor": .string(anchor), "url": .string(url), "title": .string(title), "icon": "sf:globe",
                    "webview": .string(webview), "selected": .bool(selected), "kind": .string(kind)]
    if case let .object(pairs) = extra { for (k, v) in pairs { a.put(k, v) } }
    h.rt.call("previews", "show", a)
  }

  // MARK: Tree helpers

  /// Every node of a tree, depth first.
  static func nodes(_ v: Value) -> [Value] {
    var out: [Value] = [v]
    for c in v.a("children") { out += nodes(c) }
    return out
  }

  /// The visible words of a tree: labels (and runs), items, badges, notes, button titles.
  static func words(_ v: Value) -> [String] {
    nodes(v).flatMap { n -> [String] in
      switch n.s("type") {
      case "label": return n.a("runs").isEmpty ? [n.s("text")] : [n.a("runs").map { $0.s("text") }.joined()]
      case "item": return [n.s("title"), n.s("subtitle"), n.s("accessory")].filter { !$0.isEmpty }
      case "badge", "note": return [n.s("text")]
      case "action": return n.s("title").isEmpty ? [] : [n.s("title")]
      default: return []
      }
    }.filter { !$0.isEmpty }
  }

  static func actions(_ v: Value) -> [Value] { nodes(v).filter { $0.s("type") == "action" } }
  static func tips(_ v: Value) -> [String] { actions(v).map { $0.s("tooltip") } }
  static func of(_ v: Value, _ type: String) -> [Value] { nodes(v).filter { $0.s("type") == type } }

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
    h.rt.call("previews", "register", ["pattern": "github.com/apple/*/pull/*", "provider": "apple.pr"])
    #expect(core.match("https://github.com/apple/swift/pull/1")?.id == "apple.pr")
    #expect(core.match("https://github.com/other/x/pull/1")?.id == "github.pr")
    #expect(Pattern.glob(Array("github.com/*/*/pull/*".utf8), Array("github.com/a/b/pull/7".utf8)))
    #expect(!Pattern.glob(Array("github.com/*/*/pull/*".utf8), Array("github.com/a/b/issues/7".utf8)))
  }

  // MARK: The tab card (spec §2.3, §2.5)

  @Test func tabCardHasDiasLayoutAndDensVerbsInOrder() {
    let h = Harness()
    let m = Mock()
    _ = start(h, m)
    show(h, "https://example.com/post", title: "Example Domain", selected: true)
    let a = m.last
    #expect(a.s("id") == "previews.tab" && a.s("anchor") == "tab-1" && a.s("place") == "trailing" && a.s("swap") == "instant")
    #expect(a["width"] == ["min": 170, "max": 200])
    let t = m.card
    #expect(Self.words(t) == ["Example Domain", "example.com"])
    let title = Self.of(t, "label")[0]
    #expect(title["size"] == 13 && title.s("weight") == "semibold" && title["lines"] == 2)
    // A selected tab gets no snapshot (it's on screen), and "Add Split View".
    #expect(Self.of(t, "image").isEmpty)
    #expect(Self.tips(t) == ["Pin Tab", "Add Split View", "Duplicate Tab", "Copy Link", "Archive Tab"])
    #expect(Self.actions(t).map { $0.s("shortcut") } == ["cmd+d", "ctrl+shift+=", "", "cmd+shift+c", "cmd+w"])
    let row = Self.nodes(t).first { $0["distribute"] == "equal" }!
    #expect(row["height"] == 34 && row["spacing"] == 2 && row["padding"] == [0, 3, 0, 3])
    // Pinned, drifted, audible, with another space to move to: Reset · Unpin · … · Mute · Move ▸ · Close.
    show(h, "https://example.com/elsewhere", title: "Docs", selected: true, kind: "pinned",
         extra: ["drift": true, "audio": true, "spaces": [["id": "s2", "name": "Work"]]])
    let p = m.card
    #expect(Self.tips(p) == ["Back to Pinned URL", "Unpin Tab", "Add Split View", "Duplicate Tab", "Copy Link", "Mute Tab", "Move to Space", "Close Tab"])
    #expect(Self.actions(p)[6].a("menu").map { $0.s("title") } == ["Work"])
    // 8 buttons keep ≥ 30 pt each: the card widens past Dia's 200.
    #expect(m.last["width"] == ["min": 170, "max": 260])
    // At its pinned URL, Reset is shown but disabled.
    show(h, "https://example.com", title: "Docs", selected: true, kind: "pinned")
    #expect(Self.actions(m.card)[0]["enabled"] == false)
    // Favorites hang below-right of the tile.
    show(h, "https://example.com", title: "Docs", selected: true, kind: "favorite")
    #expect(m.last.s("place") == "tile")
    // A split row lists both panes with its three verbs.
    show(h, "https://a.example/", anchor: "split-1", title: "A", extra: ["panes": [
      ["id": "t1", "title": "Left page", "url": "https://left.example/"], ["id": "t2", "title": "Right page", "url": "https://right.example/"],
    ]])
    #expect(Self.words(m.card) == ["Left page", "left.example", "Right page", "right.example"])
    #expect(Self.tips(m.card) == ["Add to Split", "Copy Link", "Separate Tabs"])
  }

  @Test func cardButtonsRunTabActionsAndClose() {
    let h = Harness()
    let m = Mock()
    _ = start(h, m)
    show(h, "https://example.com", title: "Example", webview: "tab-7", extra: ["audio": true, "spaces": [["id": "s2", "name": "Work"]]])
    h.action("previews.tab.act:pin", "click")
    #expect(m.acts.last?.s("id") == "tab-7" && m.acts.last?.s("action") == "pin")
    #expect(m.last["tree"].isNull)  // acting closes the card, like a menu
    show(h, "https://example.com", title: "Example", webview: "tab-7", extra: ["audio": true, "spaces": [["id": "s2", "name": "Work"]]])
    h.action("previews.tab.act:move", "menu", "s2")
    #expect(m.acts.last?.s("action") == "move" && m.acts.last?["value"].s("spaceId") == "s2")
    // Mute keeps the card open and offers Unmute.
    show(h, "https://example.com", title: "Example", webview: "tab-7", extra: ["audio": true])
    h.action("previews.tab.act:mute", "click")
    #expect(m.acts.last?.s("action") == "mute")
    #expect(Self.tips(m.card).contains("Unmute Tab") && !m.last["tree"].isNull)
    // Rows inside provider cards open their links.
    h.action("previews.open:0", "click", ["url": "https://github.com/a/b/runs/1"])
    #expect(m.opened.last?.s("url") == "https://github.com/a/b/runs/1")
  }

  // MARK: The PR peek (spec §3.2)

  static let prURL = "https://github.com/denhq/den/pull/482"

  static func mockGitHub(_ m: Mock) {
    for (k, v) in PreviewScenarios.githubFixtures { m.responses.append((k, v)) }
  }

  @Test func prPeekFromTheSpecWithFailuresAndConflicts() throws {
    let h = Harness()
    let m = Mock()
    Self.mockGitHub(m)
    _ = start(h, m)
    show(h, Self.prURL, title: "Fix the parser · Pull Request #482")
    #expect(m.cards.count == 2)  // at once (loading), then the data
    #expect(Self.words(m.cards[0]).contains("Loading…"))
    let c = m.card
    #expect(m.last["width"]["min"] == 288)
    #expect(Self.words(c) == ["Parser: accept trailing commas in tuple patterns", "abhi · #482", "+214 −37 · 6 files",
                              "build (macOS)", "test (linux)", "Conflicts with main", "Show 2 failures", "Show Comments"])
    // avatar 16 pt round
    let avatar = try #require(Self.of(c, "image").first)
    #expect(avatar["width"] == 16 && avatar["radius"] == 8 && avatar.s("src") == "https://avatars.githubusercontent.com/u/1?v=4&s=32")
    // The CI bar: passed → pending → failed over the checks' total (docs skipped counts as passed).
    let meter = try #require(Self.of(c, "meter").first)
    #expect(meter["total"] == 5 && meter.a("segments").map { $0.i("value") } == [2, 1, 2])
    #expect(meter.a("segments").map { $0.s("tone") } == ["success", "warning", "danger"])
    // Failing checks open their run; "Show 2 failures" the checks tab.
    #expect(Self.of(c, "note")[0]["value"].s("url") == "https://github.com/denhq/den/runs/1")
    #expect(Self.actions(c).first { $0.s("id") == "previews.pr:failures" }?.s("tone") == "destructive")
    #expect(Self.actions(c).first { $0.s("id") == "previews.pr:comments" }?.s("tone") == "strong")
    // The tab's own verbs are still on the card.
    #expect(Self.tips(c).contains("Pin Tab"))
    // Three public API calls, no sign-in: the PR, then its head commit's check runs and statuses.
    #expect(m.fetches.count == 3)
    #expect(m.fetches.allSatisfy { Text.hasPrefix($0.s("url"), "https://api.github.com/repos/denhq/den/") && $0["session"].isNull })
    h.action("previews.pr:failures", "click")
    #expect(m.calls.contains { $0.0 == "tabs" && $0.1 == "navigate" && $0.2.s("url") == Self.prURL + "/checks" })
  }

  @Test func prPeekStatusLines() {
    func data(_ runs: [Value], merged: Bool = false) -> Value {
      GitHub.prData(["title": "T", "state": merged ? "closed" : "open", "merged": .bool(merged), "user": ["login": "a"], "mergeable": true,
                     "additions": 1, "deletions": 0, "changed_files": 1, "base": ["ref": "main"]],
                    checks: ["check_runs": .array(runs)], statuses: .null, repo: "o/r", n: 1)
    }
    func run(_ status: String, _ c: Value = .null) -> Value { ["name": .string(status + String(Int.random(in: 0...1_000_000))), "status": .string(status), "conclusion": c] }
    #expect(Cards.status(data([run("completed", "success"), run("completed", "skipped")])) == "All checks passed")
    #expect(Cards.status(data([run("queued"), run("queued")])) == "Checks are queued")
    #expect(Cards.status(data([run("in_progress"), run("completed", "success"), run("queued")])) == "2 of 3 checks still running")
    #expect(Cards.status(data([])) == "No checks")
    let passing = Cards.pr(data([run("completed", "success")]), title: "", loading: false, actions: [])
    #expect(Self.words(passing).contains("All checks passed") && Self.of(passing, "note").isEmpty)
    #expect(Self.actions(passing).map { $0.s("title") } == ["Show Comments"])
    let merged = Cards.pr(data([run("completed", "success")], merged: true), title: "", loading: false, actions: [])
    #expect(Self.words(merged).contains("Merged") && Self.of(merged, "meter").isEmpty)
    // More than 3 failures: 3 rows, and the button counts them all.
    let four = Cards.pr(data((0..<4).map { _ in run("completed", "failure") }), title: "", loading: false, actions: [])
    #expect(Self.of(four, "note").count == 3 && Self.words(four).contains("Show 4 failures"))
  }

  @Test func cachedWithinTTLAndSharedWhileInFlight() {
    let h = Harness()
    let m = Mock()
    Self.mockGitHub(m)
    let core = start(h, m)
    m.hold = true
    show(h, Self.prURL)
    show(h, Self.prURL, anchor: "tab-2")  // a second hover before the answer: no second request
    #expect(m.fetches.count == 1 && core.fetches == 1)
    m.hold = false
    while !m.held.isEmpty {
      let r = m.held.removeFirst()
      h.rt.plugins.emit("net.result", r)
    }
    #expect(m.fetches.count == 3)
    #expect(m.last.s("anchor") == "tab-2" && !Self.words(m.card).contains("Loading…"))
    let before = m.cards.count
    show(h, Self.prURL, anchor: "tab-1")
    #expect(m.fetches.count == 3 && m.cards.count == before + 1)
    h.clock += 61_000
    show(h, Self.prURL)
    #expect(!Self.words(m.cards[before + 1]).contains("Loading…"))  // stale shows at once, refreshes behind
    #expect(m.fetches.count == 6)
  }

  @Test func nothingRunsUntilAHover() {
    let h = Harness()
    let m = Mock()
    let core = start(h, m)
    h.fireTimers()
    #expect(h.timers.isEmpty)
    #expect(m.fetches.isEmpty && m.cards.isEmpty && m.snapshots.isEmpty)
    #expect(core.requests.inFlight == 0)
    // The link listener is installed (a few passive listeners), nothing else.
    #expect(m.calls.filter { $0.0 == "webviews" }.map { $0.1 } == ["watchLinks"])
    #expect(m.calls.first { $0.1 == "watchLinks" }?.2.s("modifier") == "shift")
  }

  @Test func privateRepositoryOffersConnectAndFillsInWhenConnected() {
    let h = Harness()
    let m = Mock()
    _ = start(h, m)
    // Not signed in to GitHub in den: say what's missing, offer Connect.
    show(h, "https://github.com/acme/private/pull/7", title: "Secret thing · Pull Request #7")
    #expect(Self.words(m.card).contains("Private repository"))
    #expect(Self.words(m.card).contains("Connect GitHub"))
    #expect(!Self.words(m.card).joined().contains("den account") && !Self.words(m.card).joined().lowercased().contains("log in"))
    h.action("previews.pr:connect", "click")
    #expect(m.calls.contains { $0.0 == "connections" && $0.1 == "connect" && $0.2.s("id") == "github" })
    // Signed in now: the connection changes and the open card fills in live.
    m.sessionValue = ["status": 200, "state": "OPEN", "title": "Secret thing", "head": "wip", "base": "main", "author": "abhi", "merged": false]
    let n = m.cards.count
    h.rt.plugins.emit("connections.changed", ["connections": []])
    #expect(m.cards.count > n)
    #expect(Self.words(m.card).first == "Secret thing" && Self.words(m.card).contains("abhi · #7"))
    #expect(!Self.words(m.card).contains("Connect GitHub"))
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
    let w = Self.words(m.card)
    #expect(w.prefix(5) == ["Crash on launch", "denhq/den · #12", "Closed", "bug", "p1"])
    #expect(w.contains { $0.hasPrefix("5 comments · opened by sam") })
  }

  // MARK: Calendar, Gmail, Slack

  @Test func calendarShowsTheRestOfTheDayWithJoin() {
    let h = Harness()
    let m = Mock()
    m.evalValue = PreviewScenarios.calendarEval
    _ = start(h, m)
    show(h, "https://calendar.google.com/calendar/u/0/r", webview: "tab-cal")
    let c = m.card
    let items = Self.of(c, "item").map { $0.s("title") }
    #expect(Self.words(c).prefix(3) == ["Rest of today", "Sunday, September 27", "Now · Design review"])
    #expect(items == ["Company offsite", "Design review", "1:1 with Mira", "Ship den 0.2", "Dinner"])
    let join = Self.actions(c).first { $0.s("title") == "Join Design review" }
    #expect(join?["value"].s("url") == "https://meet.google.com/abc-defg-hij" && join?.s("tone") == "primary")
    m.evalValue = .null
    _ = h.rt.call("previews", "clear")
    show(h, "https://calendar.google.com/calendar/u/0/r", webview: "tab-cal")
    #expect(Self.words(m.card).contains { $0.contains("Open Calendar") })
  }

  /// The real page script, run by `webviews.eval` in a live page shaped like Google Calendar's.
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
    _ = await Wait.until("the calendar page to load") { h.rt.call("webviews", "get", ["id": "cal"])["loading"] == false }
    try await Task.sleep(for: .milliseconds(200))
    #expect(h.rt.call("webviews", "eval", ["id": "cal", "plugin": "tabs", "script": "return 1"]).isErr)
    show(h, "https://calendar.google.com/calendar/u/0/r", webview: "cal")
    _ = await Wait.until("the calendar card's events") { !Self.of(m.card, "item").isEmpty || Self.words(m.card).contains(where: { $0.contains("Nothing") }) }
    let rows = Self.of(m.card, "item")
    #expect(rows.map { $0.s("title") } == ["Company offsite", "Late sync", "Last call"])
    #expect(rows.count == 3 && rows[1].s("subtitle") == "11:50pm to 11:58pm" && rows[1]["value"].s("url") == "https://meet.google.com/abc-defg-hij")
    #expect(Self.words(m.card).contains("Join Late sync"))
  }

  /// The session scripts (GitHub private PRs, Slack workspaces) run on sites den can't sign in to
  /// in tests; at least make sure WebKit parses them.
  @Test func sessionScriptsParse() async throws {
    let h = Harness()
    h.rt.webviews.allowScript = { _, _ in true }
    h.rt.call("webviews", "create", ["id": "js"])
    h.rt.webviews.materialize("js")?.loadHTMLString("<html></html>", baseURL: URL(string: "https://js.example/"))
    _ = await Wait.until("the script page to load") { h.rt.call("webviews", "get", ["id": "js"])["loading"] == false }
    var captured = ""
    var env = h.env
    let base = env.invoke
    env.invoke = { s, method, a in
      if s == "session" { captured = a.s("script"); return ["error": "stop"] }
      return base(s, method, a)
    }
    let probe = PreviewsCore(env: env)
    GitHub.sessionPR(probe, PreviewsCore.Request(anchor: "a", url: "", title: "", icon: "", webview: "", profile: "default", selected: false, kind: "", items: []),
                     repo: "denhq/den", n: 482, limited: false) { _ in }
    #expect(Text.contains(captured, "fetch('/denhq/den/pull/482'"))
    for src in [captured, Slack.configScript, Calendar.script] {
      let lit = String(data: try JSONSerialization.data(withJSONObject: [src]), encoding: .utf8)!
      let check = "const src = " + lit + "[0]; try { new (Object.getPrototypeOf(async function(){}).constructor)(src); return 'ok'; } catch (e) { return String(e); }"
      let r = h.rt.call("webviews", "eval", ["id": "js", "plugin": "previews", "script": .string(check), "request": "syntax"])
      #expect(!r.isErr)
      var result: Value = .null
      let token = h.rt.plugins.on("webviews.evalResult") { v in if v.s("request") == "syntax" { result = v } }
      _ = await Wait.until("the syntax check result") { !result.isNull }
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
    #expect(Self.of(c, "badge").map { $0.s("text") } == ["3 unread"])
    #expect(Self.words(c)[1] == "abhi@example.com")
    let rows = Self.of(c, "item")
    #expect(rows.map { $0.s("title") } == ["Mira Chen", "GitHub", "Jonas & Co"])
    #expect(rows[0].s("subtitle") == "Offsite agenda & travel")
    #expect(rows[0]["value"].s("url") == "https://mail.google.com/mail/u/1?account_id=abhi@example.com&message_id=1&view=conv")
    m.responses = [("feed/atom", ["status": 200, "text": "<html>Sign in</html>"])]
    _ = h.rt.call("previews", "clear")
    show(h, "https://mail.google.com/mail/u/0/")
    #expect(Self.words(m.card).contains { $0.contains("Sign in to Gmail") })
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
    #expect(Self.of(m.card, "badge").map { $0.s("text") } == ["3 mentions", "1 DM", "2 channels"])
    #expect(Self.words(m.card).first == "Acme")
    #expect(core.slackTeams?.count == 1)
  }

  // MARK: Generic page

  @Test func otherPagesGetACompactCachedSnapshot() {
    let h = Harness()
    let m = Mock()
    let core = start(h, m)
    show(h, "https://example.com/post", title: "A post", webview: "tab-3")
    let img = Self.of(m.card, "image")
    #expect(img.count == 1 && img[0]["placeholder"] == true && img[0]["src"].isNull && img[0]["aspect"] == 0.5)
    #expect(Self.words(m.card) == ["A post", "example.com"])
    #expect(m.snapshots.count == 1 && m.snapshots[0]["width"] == 400 && m.snapshots[0].s("format") == "jpeg")
    let path = m.snapshots[0].s("path")
    h.rt.plugins.emit("webviews.snapshot", ["id": "tab-3", "path": .string(path), "ok": true])
    #expect(Self.of(m.card, "image").first?.s("src") == path)
    show(h, "https://example.com/post", title: "A post", webview: "tab-3")
    #expect(Self.of(m.card, "image").first?.s("src") == path && m.snapshots.count == 1)
    #expect(core.fetches == 0)
  }

  // MARK: ⇧-hover link cards

  @Test func shiftHoverShowsALinkCardFromTheHeadOnly() {
    let h = Harness()
    let m = Mock()
    let head = """
      <html><head><title>Fallback</title>
      <meta property="og:title" content="The WebKit blog">
      <meta property="og:description" content="News from the WebKit team.">
      <meta property="og:image" content="/img/card.png">
      <meta property="og:site_name" content="WebKit">
      </head><body>
      """
    m.responses = [("webkit.org/blog/1", ["status": 206, "text": .string(head)])]
    let core = start(h, m)
    let rect: Value = ["x": 500, "y": 300, "w": 120, "h": 18]
    h.rt.plugins.emit("webviews.linkHover", ["id": "tab-1", "url": "https://webkit.org/blog/1", "text": "WebKit blog", "rect": rect, "yield": false])
    // One head-only request: a Range, and the host stops at </head>.
    #expect(m.fetches.count == 1)
    let f = m.fetches[0]
    #expect(f["stopAfter"] == "</head>" && f["headers"].s("Range") == "bytes=0-262143" && f["session"].isNull)
    #expect(m.last.s("id") == "previews.link" && m.last["rect"] == rect && m.last.s("place") == "below" && m.last["width"] == 300)
    let c = m.card
    #expect(Self.words(c).prefix(3) == ["WebKit", "The WebKit blog", "News from the WebKit team."])
    #expect(Self.of(c, "image").first?.s("src") == "https://webkit.org/img/card.png")
    #expect(Self.tips(c) == ["Open in Peek  ⇧-click", "Open as Split", "Copy Link"])
    // Cached: hovering again costs nothing.
    h.rt.plugins.emit("webviews.linkHoverEnd", ["id": "tab-1"])
    #expect(m.last["tree"].isNull)
    h.rt.plugins.emit("webviews.linkHover", ["id": "tab-1", "url": "https://webkit.org/blog/1", "text": "WebKit blog", "rect": rect, "yield": false])
    #expect(m.fetches.count == 1 && core.og.count == 1)
    // Copy Link.
    h.action("previews.link.act:copy", "click")
    #expect(m.calls.contains { $0.0 == "app" && $0.1 == "copy" && $0.2.s("text") == "https://webkit.org/blog/1" })
    // Where the site has its own previews (Wikipedia), den stays out of the way.
    let n = m.cards.count
    h.rt.plugins.emit("webviews.linkHover", ["id": "tab-1", "url": "https://en.wikipedia.org/wiki/WebKit", "rect": rect, "yield": true])
    #expect(m.cards.count == n && m.fetches.count == 1)
  }

  @Test func linkToAPullRequestGetsThePRPeek() {
    let h = Harness()
    let m = Mock()
    Self.mockGitHub(m)
    _ = start(h, m)
    h.rt.plugins.emit("webviews.linkHover", ["id": "tab-1", "url": .string(Self.prURL), "rect": ["x": 1, "y": 2, "w": 3, "h": 4], "yield": false])
    #expect(m.last.s("id") == "previews.link")
    #expect(Self.words(m.card).contains("Show 2 failures"))
    #expect(Self.tips(m.card).contains("Open in Peek  ⇧-click") && !Self.tips(m.card).contains("Pin Tab"))
    #expect(!m.fetches.contains { $0["stopAfter"] == "</head>" })
  }

  @Test func linkPreviewSettings() {
    let h = Harness()
    let m = Mock()
    let core = start(h, m)
    let section = h.rt.call("settings", "list").array?.first { $0.s("id") == "previews" }
    #expect(section?.s("title") == "Previews")
    h.rt.call("settings", "set", ["id": "previews", "key": "links", "value": "hover"])
    #expect(m.calls.last { $0.1 == "watchLinks" }?.2.s("modifier") == "none")
    // Plain hover waits like a row does before anything is fetched.
    h.rt.plugins.emit("webviews.linkHover", ["id": "tab-1", "url": "https://example.org/", "rect": ["x": 1, "y": 2, "w": 3, "h": 4], "yield": false])
    #expect(m.fetches.isEmpty && h.timers.count == 1 && h.timers[0].0 == 700)
    h.fireTimers()
    #expect(m.fetches.count == 1)
    h.rt.call("settings", "set", ["id": "previews", "key": "links", "value": "off"])
    #expect(m.calls.last { $0.1 == "watchLinks" }?.2.s("modifier") == "off")
    h.rt.call("settings", "set", ["id": "previews", "key": "redwell", "value": true])
    #expect(core.redwell)
    show(h, "https://example.com", selected: true)
    #expect(m.last.s("swap") == "dwell")
  }

  // MARK: tabs

  @Test func tabsAsksForACardAndRunsItsActions() throws {
    let h = Harness()
    let m = Mock()
    _ = start(h, m)
    let tabs = h.startTabs()
    let space = h.spaceIds[0]
    let id = h.tabs("open", ["url": "https://example.org/a", "spaceId": .string(space)]).s("id")
    h.tabs("select", ["id": .string(h.ids("today")[1])])
    h.action(id, "hover")
    #expect(m.last.s("anchor") == id)
    #expect(Self.words(m.card).last == "example.org")
    // Rows carry their dwell for the host's hover intent.
    let row = tabs.row(id, space, box: .today(space))
    #expect(row["hoverIntent"] == 700)
    // tabs.act: pin, copy, duplicate, move.
    #expect(!h.tabs("act", ["id": .string(id), "action": "pin"]).isErr)
    #expect(h.ids("pinned").contains(id))
    #expect(!h.tabs("act", ["id": .string(id), "action": "copy"]).isErr)
    let before = tabs.tabs.count
    #expect(!h.tabs("act", ["id": .string(id), "action": "duplicate"]).isErr)
    #expect(tabs.tabs.count == before + 1)
    #expect(h.tabs("act", ["id": .string(id), "action": "nope"]).isErr)
    // Folders list their tabs (from cache only).
    let fid = h.tabs("createFolder", ["spaceId": .string(space), "title": "Reading", "tabIds": [.string(id)]]).s("id")
    h.action(fid, "hover")
    #expect(m.last.s("anchor") == fid && Self.words(m.card).prefix(2) == ["Reading", "1 tab"])
  }

  /// The real host renders the composed cards at Dia's sizes (spec §2.3).
  @Test func composedTabCardRendersAtDiasSize() async throws {
    let h = Harness()
    let m = Mock()
    m.realCard = true
    _ = start(h, m)
    h.rt.call("ui", "set", ["slot": "sidebar.today", "tree": ["type": "list", "id": "today", "children": [
      ["type": "tabRow", "id": "tab-1", "title": "Example Domain", "icon": "sf:globe", "hoverIntent": 1],
    ]]])
    h.rt.window.window.contentView?.layoutSubtreeIfNeeded()
    let rowView = try #require(h.rt.ui.findNode("tab-1", in: h.rt.ui.sidebarView))
    h.rt.ui.cards.entered(rowView)
    _ = await Wait.until("the hover intent for tab-1") { h.rt.ui.cards.intent.anchor == "tab-1" }
    // Dia's four-verb card: short title → 170 × 93 with 39 pt buttons.
    let req = PreviewsCore.Request(anchor: "tab-1", url: "https://example.com", title: "Example Domain", icon: "", webview: "tab-1", profile: "default",
                                   selected: true, kind: "today", items: [])
    var four = Cards.tab(req)
    four = Self.keepActions(four, 4)
    h.rt.call("ui", "card", ["id": "previews.tab", "anchor": "tab-1", "tree": four, "width": Cards.width(actions: 4)])
    let card = try #require(h.rt.ui.cards.card("previews.tab"))
    #expect(card.frame.width == 170 && card.frame.height == 93)
    // den's five verbs on the same card: still 170 wide (5 × 30 + gaps fits), same height.
    h.rt.call("ui", "card", ["id": "previews.tab", "anchor": "tab-1", "tree": Cards.tab(req), "width": Cards.width(actions: 5)])
    #expect(card.frame.width == 170 && card.frame.height == 93)
    // The PR peek is ~288 wide.
    h.rt.call("ui", "card", ["id": "previews.tab", "anchor": "tab-1", "tree": Cards.pr(GitHub.prData(PreviewScenarios.prJSON, checks: .null, statuses: .null, repo: "denhq/den", n: 482),
                                                                                           title: "", loading: false, actions: Cards.tabActions(req)),
                              "width": ["min": 288, "max": 288]])
    #expect(card.frame.width == 288)
  }

  static func keepActions(_ tree: Value, _ n: Int) -> Value {
    var t = tree
    let kids = t.a("children").map { c -> Value in
      guard c["distribute"] == "equal" else { return c }
      var c = c
      c.put("children", .array(Array(c.a("children").prefix(n))))
      return c
    }
    t.put("children", .array(kids))
    return t
  }
}
