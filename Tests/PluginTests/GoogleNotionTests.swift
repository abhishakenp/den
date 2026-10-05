import AppKit
import CordisValue
import DenTestSupport
import Foundation
import Testing
import WebKit

@testable import DenHost
@testable import PluginCores

/// Gmail, Google Calendar and Notion end to end against the local fakes in `MockServices`
/// (MockGoogleNotion.swift): a real sign-in page sets the cookies in a WebKit data store, the
/// plugins read the session, fetch the fake endpoints with it, and the briefing gets their items.
/// None of this has touched a real Google or Notion account.
@MainActor
@Suite(.serialized, .watchdog)
struct GoogleNotionTests {
  static let profile = ConnectionsTests.profile
  let ct = ConnectionsTests()

  /// Records what plugins ask of `tabs`, `ui.card` and toasts.
  final class Recorder {
    var opened: [String] = []
    var badges: [String] = []
    var cards: [Value] = []
    var toasts: [Value] = []
  }

  func env(_ h: Harness, _ rec: Recorder) -> PluginEnv {
    var e = h.env
    let base = e.invoke
    e.invoke = { s, m, a in
      if s == "ui", m == "card", a.s("id") == CalendarCore.cardId { rec.cards.append(a["tree"]) }
      if s == "ui", m == "set", a.s("slot") == "toast" { rec.toasts.append(a["tree"]) }
      return base(s, m, a)
    }
    return e
  }

  /// connections (+ a fake tabs/spaces), pointed at the mock, with the private profile.
  func startConnections(_ h: Harness, _ rec: Recorder) -> ConnectionsCore {
    h.rt.plugins.provide("tabs") { method, a in
      if method == "open" { rec.opened.append(a.s("url")); return ["id": .string("tab-\(rec.opened.count)")] }
      if method == "badge" { rec.badges.append(a.s("text")) }
      return ["ok": true]
    }
    h.rt.plugins.provide("spaces") { method, _ in
      method == "current" ? ["id": "s1"] : [["id": "s1", "name": "Personal", "profile": .string(Self.profile)]]
    }
    let c = ConnectionsCore(env: env(h, rec))
    h.rt.plugins.provide("connections") { a, b in c.handle(a, b) }
    c.start()
    return c
  }

  func configure(_ h: Harness, _ m: MockServices) {
    h.rt.call("storage", "set", ["ns": "gmail", "key": "endpoints", "value": [
      "base": .string(m.base), "domain": "127.0.0.1", "signIn": .string(m.base + "/google/signin")]])
    h.rt.call("storage", "set", ["ns": "calendar", "key": "endpoints", "value": [
      "domain": "127.0.0.1", "host": "127.0.0.1", "web": .string(m.base + "/calendar/r")]])
    h.rt.call("storage", "set", ["ns": "notion", "key": "endpoints", "value": [
      "api": .string(m.base + "/api/v3/"), "web": .string(m.base), "domain": "127.0.0.1", "signIn": .string(m.base + "/notion/signin")]])
    for p in ["gmail", "calendar", "notion"] { h.rt.permissions.grant(p, ["session:127.0.0.1"]) }
  }

  func feedItems(_ h: Harness, _ source: String) -> [Value]? {
    h.events.last { $0.0 == "feed.items" && $0.1.s("source") == source }?.1.a("items")
  }

  /// Local noon today: every fixture time (±5 h) stays within the day.
  static var localNoon: Date { Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())! }
  static var offsetMinutes: Int64 { Int64(TimeZone.current.secondsFromGMT(for: localNoon) / 60) }
  static var todayNumber: Int64 { ICS.floorDay(Int64(localNoon.timeIntervalSince1970 * 1000) + offsetMinutes * 60_000) }

  // MARK: Gmail

  @Test func gmailFeedParsingAndClassification() {
    let xml = MockServices(now: Self.localNoon).gmailFeed(0)
    let feed = GmailCore.parse(xml)
    #expect(feed.email == "you@acme.test")
    #expect(feed.count == 4)
    #expect(feed.entries.map { $0.s("email") } == ["maya@acme.test", "comments-noreply@docs.google.com", "billing@acme-cloud.test", "omar@acme.test"])
    #expect(feed.entries[3].s("title") == "Re: Offsite dinner & venue")
    #expect(feed.entries[3].s("summary") == "Works for me — want me to book it?")
    #expect(GmailCore.messageId(feed.entries[0]) == "18f0001")
    #expect(GmailCore.classify(email: "maya@acme.test") == "reply")
    #expect(GmailCore.classify(email: "comments-noreply@docs.google.com") == "docs")
    #expect(GmailCore.classify(email: "drive-shares-dm-noreply@google.com") == "docs")
    for robot in ["noreply@github.com", "no-reply@accounts.google.com", "notifications@slack.test", "billing@acme-cloud.test",
                  "newsletter@weekly.test", "calendar-notification@google.com", "hello@startup.test", "team+digest@x.test"] {
      #expect(GmailCore.classify(email: robot) == "email", "\(robot)")
    }
    let a = GmailCore.Account(index: "0", email: "you@acme.test")
    let reply = GmailCore.item(feed.entries[0], account: a, multi: true, base: "https://mail.google.com")
    #expect(reply.s("kind") == "reply" && reply.b("actionable"))
    #expect(reply.s("detail") == "Maya Chen · waiting for your reply · you@acme.test")
    #expect(reply.s("importantKey") == "gmail:maya@acme.test")
    #expect(reply.s("url").contains("message_id=18f0001") && !reply.s("url").contains("&amp;"))
    let receipt = GmailCore.item(feed.entries[2], account: a, multi: false, base: "https://mail.google.com")
    #expect(receipt.s("kind") == "email" && !receipt.b("actionable"))
    #expect(Web.entities("a &amp; b &#8212; &#x27;c&#39; &lt;d&gt; &bogus;") == "a & b — 'c' <d> &bogus;")
  }

  @Test func gmailConnectsEveryAccountAndReadsUnreadMail() async throws {
    let m = try ct.mock()
    defer { m.stop() }
    let h = Harness()
    let rec = Recorder()
    configure(h, m)
    h.clock = Int64(m.now.timeIntervalSince1970 * 1000)
    _ = startConnections(h, rec)
    let g = GmailCore(env: h.env)
    g.start()
    h.record(["feed.items"])
    #expect(!h.rt.call("connections", "get", ["id": "gmail"]).b("connected"))
    #expect(!m.log.contains { $0.contains("/feed/atom") })  // nothing is fetched without a Google session

    #expect(await ct.signIn(h, m.base + "/google/signin"))
    h.rt.call("connections", "connect", ["id": "gmail"])
    #expect(await ct.until { h.rt.call("connections", "get", ["id": "gmail"]).b("connected") })
    let c = h.rt.call("connections", "get", ["id": "gmail"])
    #expect(c.s("account") == "you@acme.test")
    #expect(c.a("teams").map { $0.s("name") } == MockServices.gmailAccounts)
    #expect(c.s("unit") == "accounts")
    // u/0, u/1, then u/2 answers as u/0: two accounts, three requests.
    #expect(m.log.filter { $0.hasSuffix("/feed/atom") } == ["GET /mail/u/0/feed/atom", "GET /mail/u/1/feed/atom", "GET /mail/u/2/feed/atom"])
    #expect(rec.toasts.last?.s("text") == "Gmail connected")
    #expect(!ValueJSON.string(h.storage("connections", "accounts")).contains(MockServices.googleSid))

    // A refresh: one feed request per account.
    let before = m.log.count
    h.rt.plugins.emit("feed.refresh", ["reason": "manual"])
    #expect(await ct.until { feedItems(h, "gmail") != nil })
    let items = feedItems(h, "gmail")!
    #expect(Array(m.log[before...]).filter { $0.hasSuffix("/feed/atom") }.count == 2)
    #expect(items.count == 6)
    #expect(items.filter { $0.s("kind") == "reply" }.map { $0.s("actor") }.sorted() == ["Lee Park", "Maya Chen", "Omar Haddad"])
    #expect(items.filter { $0.s("kind") == "docs" }.count == 1)
    #expect(items.filter { $0.s("kind") == "email" }.count == 2)
    #expect(items.first { $0.s("actor") == "Lee Park" }!.s("detail").hasSuffix("· you.personal@gmail.test"))

    // Account picker: turn the personal account off.
    h.action("connections.team:gmail:1", "toggle", ["on": false])
    h.events = []
    h.rt.plugins.emit("feed.refresh", ["reason": "manual"])
    #expect(await ct.until { feedItems(h, "gmail") != nil })
    #expect(feedItems(h, "gmail")!.count == 4)

    // Signed out of Google: the next refresh gets a 401 and reports it.
    let store = h.rt.webviews.store(for: Self.profile)
    for ck in await store.httpCookieStore.allCookies() where ck.name == "SID" { await store.httpCookieStore.deleteCookie(ck) }
    h.rt.plugins.emit("feed.refresh", ["reason": "manual"])
    #expect(await ct.until { !h.rt.call("connections", "get", ["id": "gmail"]).b("connected") })
    #expect(rec.toasts.last?.s("text").hasPrefix("Signed out of Gmail") == true)
  }

  // MARK: Calendar

  @Test func icsReadsTodaysOccurrences() {
    let m = MockServices(now: Self.localNoon)
    let events = ICS.parse(m.calendarICS)
    #expect(events.count == 9)
    let today = ICS.eventsOn(events, day: Self.todayNumber, offsetMinutes: Self.offsetMinutes)
    #expect(Set(today.map { $0.s("title") }) == ["Company offsite", "Standup", "Design review", "1:1 with Maya", "Focus time (moved)"])
    #expect(today.first?.s("title") == "Company offsite")  // all day starts at midnight
    let design = today.first { $0.s("title") == "Design review" }!
    #expect(design.s("link") == "https://meet.google.com/abc-defg-hij")
    #expect(design.i("start") == Int64(Self.localNoon.timeIntervalSince1970 * 1000) + 10 * 60_000)
    #expect(today.first { $0.s("title") == "1:1 with Maya" }!.s("link") == "https://acme.zoom.us/j/123456789")
    // Yesterday's standup was excluded (EXDATE); tomorrow has one again.
    #expect(!ICS.eventsOn(events, day: Self.todayNumber - 1, offsetMinutes: Self.offsetMinutes).contains { $0.s("title") == "Standup" })
    #expect(ICS.eventsOn(events, day: Self.todayNumber + 1, offsetMinutes: Self.offsetMinutes).map { $0.s("title") }.contains("Tomorrow planning"))
    #expect(ICS.text("a\\nb\\, c\\;d\\\\") == "a\nb, c;d\\")
    let folded = ICS.lines("SUMMARY:Long\r\n  title\r\nUID:x\r\n")
    #expect(folded.map { String(decoding: $0, as: UTF8.self) } == ["SUMMARY:Long title", "UID:x"])

    // Rules on fixed dates (2026-09-28 is a Monday).
    let friJan30 = Web.days(2026, 1, 30), fri25 = Web.days(2026, 9, 25), fri18 = Web.days(2026, 9, 18)
    let lastFriday = ICS.rule("FREQ=MONTHLY;BYDAY=-1FR")
    #expect(ICS.matches(lastFriday, first: friJan30, day: fri25))
    #expect(!ICS.matches(lastFriday, first: friJan30, day: fri18))
    let biweekly = ICS.rule("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE")
    let mon14 = Web.days(2026, 9, 14)
    #expect(ICS.matches(biweekly, first: mon14, day: Web.days(2026, 9, 28)))
    #expect(ICS.matches(biweekly, first: mon14, day: Web.days(2026, 9, 30)))
    #expect(!ICS.matches(biweekly, first: mon14, day: Web.days(2026, 9, 21)))
    #expect(ICS.matches(ICS.rule("FREQ=MONTHLY;BYMONTHDAY=-1"), first: Web.days(2026, 1, 31), day: Web.days(2026, 2, 28)))
    #expect(ICS.matches(ICS.rule("FREQ=YEARLY"), first: Web.days(2020, 9, 28), day: Web.days(2026, 9, 28)))
    #expect(ICS.weekday(Web.days(2026, 9, 28)) == 1)
  }

  @Test func calendarAddressFeedsTheBriefingAndTheReminder() async throws {
    let m = MockServices(now: Self.localNoon)
    try m.start()
    defer { m.stop() }
    let h = Harness()
    let rec = Recorder()
    configure(h, m)
    h.clock = Int64(m.now.timeIntervalSince1970 * 1000)
    _ = startConnections(h, rec)
    let cal = CalendarCore(env: env(h, rec))
    cal.start()
    h.record(["feed.items"])
    #expect(!h.rt.call("connections", "get", ["id": "calendar"]).b("connected"))
    #expect(cal.lead == 2)

    // The documented fallback: the calendar's secret iCal address, pasted in Settings.
    h.rt.call("settings", "set", ["id": "calendar", "key": "address", "value": .string(m.base + "/calendar/ical/basic.ics")])
    #expect(await ct.until { h.rt.call("connections", "get", ["id": "calendar"]).b("connected") })
    #expect(h.rt.call("connections", "get", ["id": "calendar"]).s("note") == "calendar address")
    #expect(await ct.until { feedItems(h, "calendar") != nil })
    let items = feedItems(h, "calendar")!
    // The standup ended hours ago; four remain, the all-day one first.
    #expect(items.map { $0.s("title") } == ["Company offsite", "Design review", "1:1 with Maya", "Focus time (moved)"])
    #expect(items.allSatisfy { $0.b("agenda") && !$0.b("actionable") && $0.s("kind") == "event" })
    let design = items[1]
    #expect(design.s("detail").hasSuffix("· Google Meet"))
    #expect(design.s("badge") == "in 10m")
    #expect(design.s("join") == "https://meet.google.com/abc-defg-hij")
    #expect(items[2].s("detail").hasSuffix("· Zoom"))
    #expect(m.log.filter { $0.contains("basic.ics") }.count == 1)

    // The favorite's countdown: within the hour before the meeting.
    #expect(rec.badges.last == "in 10m")
    #expect(rec.cards.isEmpty)
    // Two minutes before: the reminder card, with Join.
    h.clock += 8 * 60_000
    cal.tick()
    #expect(rec.badges.last == "in 2m")
    let card = try #require(rec.cards.last)
    let text = ValueJSON.string(card)
    #expect(text.contains("Design review") && text.contains("In 2m") && text.contains("calendar.reminder.join") && text.contains("Google Meet"))
    // Join opens the call and dismisses the card for good.
    h.action("calendar.reminder.join", "click")
    #expect(rec.opened.last == "https://meet.google.com/abc-defg-hij")
    #expect(rec.cards.last == .null)
    h.clock += 60_000
    cal.tick()
    #expect(rec.cards.last == .null)
    // Once it started: "now" on the favorite.
    h.clock += 2 * 60_000
    cal.tick()
    #expect(rec.badges.last == "now")

    // Reminders off: no card for the next meeting either.
    h.rt.call("settings", "set", ["id": "calendar", "key": "reminder", "value": 0])
    #expect(cal.lead == 0)
    h.clock = Int64(m.now.timeIntervalSince1970 * 1000) + 119 * 60_000
    cal.tick()
    #expect(rec.cards.last == .null)
    // Disconnect: countdown and card go away.
    // (Nothing signed it out earlier: the launch-time probe's late cookie read sees the address.)
    #expect(!rec.toasts.contains { $0.s("text").hasPrefix("Signed out") })
    h.rt.call("connections", "disconnect", ["id": "calendar"])
    #expect(cal.connection() == nil)
    #expect(await ct.until { rec.badges.last == "" })
    #expect(cal.events.isEmpty)
    // A disconnect sticks: the next Google cookie change doesn't connect it again.
    #expect(h.rt.call("connections", "get", ["id": "calendar"]).b("declined"))
    h.rt.plugins.emit("session.cookiesChanged", ["domain": "127.0.0.1", "profile": "default"])
    try? await Task.sleep(for: .milliseconds(300))
    #expect(!h.rt.call("connections", "get", ["id": "calendar"]).b("connected"))
  }

  /// The tab's timed chips are built an hour ahead of the real clock (the page uses the real
  /// clock); in the day's last hour that lands tomorrow and they read as past, so `remaining`
  /// drops below 2 and this doesn't run then (seen on CI, UTC).
  @Test(.enabled(if: Calendar.current.component(.hour, from: Date()) < 23,
                 "chips an hour ahead are in the past during the last hour of the day"))
  func calendarReadsTodayFromTheCalendarTab() async throws {
    let m = try ct.mock()
    defer { m.stop() }
    let h = Harness()
    let rec = Recorder()
    configure(h, m)
    h.clock = Int64(Date().timeIntervalSince1970 * 1000)  // the page uses the real clock
    _ = startConnections(h, rec)
    let cal = CalendarCore(env: env(h, rec))
    cal.start()
    h.record(["feed.items"])
    #expect(await ct.signIn(h, m.base + "/google/signin"))
    h.rt.call("connections", "connect", ["id": "calendar"])
    #expect(await ct.until { h.rt.call("connections", "get", ["id": "calendar"]).b("connected") })
    #expect(h.rt.call("connections", "get", ["id": "calendar"]).s("note") == "reads your Calendar tab")
    // No Calendar tab yet: the briefing says what to do.
    h.rt.plugins.emit("feed.refresh", ["reason": "manual"])
    #expect(await ct.until { h.events.contains { $0.0 == "feed.items" && $0.1.s("source") == "calendar" } })
    #expect(h.events.last { $0.0 == "feed.items" }!.1.s("error").hasPrefix("open Google Calendar in a tab"))

    // The user opens Calendar: its loaded page is read (no request beyond the page itself).
    h.events = []
    #expect(await ct.signIn(h, m.base + "/calendar/r"))
    #expect(await ct.until(20) { cal.source == "tab" && !cal.events.isEmpty })
    #expect(cal.events.map { $0.s("title") } == ["Company offsite", "Design review", "Hiring sync"])
    #expect(cal.events.first { $0.s("title") == "Design review" }!.s("link") == "https://meet.google.com/abc-defg-hij")
    #expect(cal.events.first!.b("allDay"))
    let before = m.log.count
    h.rt.plugins.emit("feed.refresh", ["reason": "manual"])
    #expect(await ct.until { feedItems(h, "calendar") != nil })
    // Remaining events (all three, unless the run is in the last hour of the day).
    let remaining = cal.events.filter { $0.b("allDay") || $0.i("end") > h.clock }.count
    #expect(feedItems(h, "calendar")!.count == remaining && remaining >= 2)
    #expect(m.log.count == before)
  }

  // MARK: Notion

  @Test func notionParsesBothRecordNestings() {
    let m = MockServices(now: Self.localNoon)
    let (spaces, account) = NotionCore.parseSpaces(ValueJSON.parse(String(decoding: try! JSONSerialization.data(withJSONObject: m.notionSpaces), as: UTF8.self))!)
    #expect(account == "octo@acme.test")
    #expect(spaces.map(\.name) == ["Acme", "Side project"])
    #expect(spaces.allSatisfy { $0.user == "U1OCTO" })
    #expect(NotionCore.spaceIcon("🌱") == "🌱" && NotionCore.spaceIcon("/images/x.png") == NotionCore.icon)
    #expect(NotionCore.stripDashes("b0000000-0000-4000-8000-00000000000a") == "b000000000004000800000000000000a")
  }

  @Test func notionConnectsAndReadsMentionsCommentsAndInvites() async throws {
    let m = try ct.mock()
    defer { m.stop() }
    let h = Harness()
    let rec = Recorder()
    configure(h, m)
    h.clock = Int64(m.now.timeIntervalSince1970 * 1000)
    _ = startConnections(h, rec)
    let n = NotionCore(env: h.env)
    n.start()
    h.record(["feed.items"])
    #expect(await ct.signIn(h, m.base + "/notion/signin"))
    h.rt.call("connections", "connect", ["id": "notion"])
    #expect(await ct.until { h.rt.call("connections", "get", ["id": "notion"]).b("connected") })
    let c = h.rt.call("connections", "get", ["id": "notion"])
    #expect(c.s("account") == "octo@acme.test")
    #expect(c.a("teams").map { $0.s("name") } == ["Acme", "Side project"])
    #expect(m.log.filter { $0.hasPrefix("POST /api/v3/") } == ["POST /api/v3/getSpaces"])

    let before = m.log.count
    h.rt.plugins.emit("feed.refresh", ["reason": "manual"])
    #expect(await ct.until { feedItems(h, "notion") != nil })
    #expect(Array(m.log[before...]) == ["POST /api/v3/getNotificationLogV2", "POST /api/v3/getNotificationLogV2"])
    let items = feedItems(h, "notion")!
    #expect(items.map { $0.s("kind") } == ["mention", "comment", "invite"])  // the read one is left out
    #expect(items[0].s("title") == "@Octo Den owns the release notes")
    #expect(items[0].s("detail") == "Maya Chen mentioned you in Q3 launch plan · Acme")
    #expect(items[0].s("url") == m.base + "/b000000000004000800000000000000a")
    #expect(items[1].s("title") == "Can you double-check the @Octo Den numbers in section 3?")
    #expect(items[1].s("url") == m.base + "/b000000000004000800000000000000a?d=d000000000004000800000000000000d")
    #expect(items[1].s("actor") == "Ana Lopez")
    #expect(items[2].s("detail") == "Maya Chen shared Hiring plan 2027 with you · Acme")
    #expect(items[2].s("importantKey") == "notion:b000000000004000800000000000000c")
    #expect(items[0].i("ts") == Int64((m.now.timeIntervalSince1970 - 20 * 60) * 1000))
  }

  // MARK: Connections and briefing

  @Test func oneGoogleSignInConnectsGmailAndCalendarWithOneUndo() async throws {
    let m = try ct.mock()
    defer { m.stop() }
    let h = Harness()
    let rec = Recorder()
    configure(h, m)
    _ = startConnections(h, rec)
    GmailCore(env: h.env).start()
    CalendarCore(env: env(h, rec)).start()
    #expect(await ct.signIn(h, m.base + "/google/signin"))
    h.rt.plugins.emit("session.cookiesChanged", ["domain": "127.0.0.1", "profile": .string(Self.profile)])
    #expect(await ct.until { ["gmail", "calendar"].allSatisfy { h.rt.call("connections", "get", ["id": .string($0)]).b("connected") } })
    let toast = try #require(rec.toasts.last)
    #expect(["Google Calendar and Gmail connected", "Gmail and Google Calendar connected"].contains(toast.s("text")))
    #expect(toast.s("action") == "Undo")
    // Undo undoes both, and both stay off until a manual Connect.
    h.action(toast.s("id"), "toast")
    #expect(["gmail", "calendar"].allSatisfy { !h.rt.call("connections", "get", ["id": .string($0)]).b("connected") })
    #expect(h.storage("connections", "declined") == ["calendar": true, "gmail": true])
  }

  @Test func briefingShowsTodayAndNewKinds() {
    let h = Harness()
    h.rt.plugins.provide("connections") { m, _ in
      m == "list" ? [["id": "calendar", "title": "Google Calendar", "connected": true], ["id": "gmail", "title": "Gmail", "connected": true],
                     ["id": "notion", "title": "Notion", "connected": true]] : .null
    }
    let b = BriefingCore(env: h.env)
    h.rt.plugins.provide("briefing") { m, a in b.handle(m, a) }
    b.start()
    let now = h.clock
    h.rt.plugins.emit("feed.items", ["source": "calendar", "items": [
      ["id": "calendar:e1", "source": "calendar", "kind": "event", "agenda": true, "title": "Design review", "detail": "2:00 PM – 2:30 PM · Google Meet",
       "ts": .int(now + 600_000), "time": "2:00 PM", "badge": "in 10m", "summary": "At 2:00 PM: Design review", "url": "https://calendar.google.com/calendar/r/day"],
      ["id": "calendar:e0", "source": "calendar", "kind": "event", "agenda": true, "allDay": true, "title": "Offsite", "ts": .int(now - 3_600_000),
       "time": "All day", "summary": "All day today: Offsite"],
    ]])
    h.rt.plugins.emit("feed.items", ["source": "gmail", "items": [
      ["id": "gmail:0:1", "source": "gmail", "kind": "reply", "title": "Q3 numbers", "ts": .int(now - 60_000), "actionable": true, "summary": "Maya emailed you"],
      ["id": "gmail:0:2", "source": "gmail", "kind": "email", "title": "Receipt", "ts": .int(now - 120_000), "summary": "Unread email"],
    ]])
    h.rt.plugins.emit("feed.items", ["source": "notion", "items": [
      ["id": "notion:n1", "source": "notion", "kind": "comment", "title": "Check section 3", "ts": .int(now - 300_000), "actionable": true, "summary": "Ana commented"],
    ]])
    // Events are the Today section, not feed rows; the feed ranks the rest.
    #expect(b.agenda().map { $0.s("id") } == ["calendar:e0", "calendar:e1"])
    #expect(b.feed().map { $0.s("id") } == ["gmail:0:1", "notion:n1", "gmail:0:2"])
    #expect(BriefingCore.plainSummary(b.agenda() + b.feed()) == "2 events today, 1 email awaiting your reply, 1 comment and 1 other unread email.")
    // Many kinds: five, then the rest as a count.
    let many: [Value] = ["event", "review", "dm", "reply", "thread", "ci", "ci", "mention"].map { ["kind": .string($0)] }
    #expect(BriefingCore.plainSummary(many) == "1 event today, 1 review request, 1 unread DM, 1 email awaiting your reply, 1 thread waiting for you and 3 more.")
    // A future event doesn't outrank everything through recency.
    #expect(BriefingCore.score(["kind": "event", "ts": .int(now + 5 * 3_600_000)], now: now, affinity: [:]) == 10 + 24)
    b.open()
    let page = ValueJSON.string(h.rt.ui.sheets["overlay.briefing"]!.node)
    #expect(page.contains("briefing.today") && page.contains("2 events") && page.contains("Design review"))
  }
}
