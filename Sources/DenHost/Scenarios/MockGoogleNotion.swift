// Dev fixture: compiled only with the `Scenarios` package trait (on by default; release bundles leave it out).
#if Scenarios
import Foundation

/// The fake Google (Gmail's Atom feed, a Calendar page, an iCal address) and Notion (its internal
/// `/api/v3` endpoints) that `MockServices` serves next to the fake Slack and GitHub. Shapes follow
/// the real ones (Atom 0.3 as Gmail writes it; Google Calendar's `data-eventid` chips with their
/// aria-label; RFC 5545; Notion's `recordMap` with both value nestings). Nothing here has been
/// compared with a signed-in account: see docs/research/integrations-auth.md.
///
/// - `GET /google/signin`: Google's `SID` sign-in cookie.
/// - `GET /mail/u/<n>/feed/atom`: two accounts (`u/0`, `u/1`); a higher index answers like `u/0`,
///   as Google does. 401 without `SID`.
/// - `GET /calendar/r`: a Calendar page whose event chips are built for today in the page's own
///   time zone (two meetings about an hour from now, an all-day event, one on another day).
/// - `GET /calendar/ical/basic.ics`: an iCal feed relative to `now` (see `calendarICS`).
/// - `GET /notion/signin`: `token_v2` and `notion_user_id`.
/// - `POST /api/v3/getSpaces`, `POST /api/v3/getNotificationLogV2`: 401 without `token_v2`.
extension MockServices {
  static let googleSid = "mock-google-sid"
  static let gmailAccounts = ["you@acme.test", "you.personal@gmail.test"]
  static let notionToken = "mock-notion-token"

  func routeGoogleNotion(_ r: Request) -> (Int, [(String, String)], Data)? {
    switch (r.method, r.path) {
    case ("GET", "/google/signin"):
      return (200, [("Content-Type", "text/html; charset=utf-8"), ("Set-Cookie", "SID=\(Self.googleSid); Path=/"),
                    ("Set-Cookie", "SIDCC=rotating-\(UUID().uuidString.prefix(6)); Path=/")],
              Data("<!doctype html><title>Google Account</title><body style='font:15px -apple-system;padding:40px'><h2>Signed in to Google</h2></body>".utf8))
    case ("GET", "/notion/signin"):
      return (200, [("Content-Type", "text/html; charset=utf-8"), ("Set-Cookie", "token_v2=\(Self.notionToken); Path=/; HttpOnly"),
                    ("Set-Cookie", "notion_user_id=U1OCTO; Path=/")],
              Data("<!doctype html><title>Notion</title><body style='font:15px -apple-system;padding:40px'><h2>Signed in to Notion</h2></body>".utf8))
    case ("GET", "/calendar/r"), ("GET", "/calendar/r/day"):
      return (200, [("Content-Type", "text/html; charset=utf-8")], Data(calendarPage.utf8))
    case ("GET", "/calendar/ical/basic.ics"):
      return (200, [("Content-Type", "text/calendar; charset=utf-8")], Data(calendarICS.utf8))
    default: break
    }
    if r.method == "GET", r.path.hasPrefix("/mail/u/"), r.path.hasSuffix("/feed/atom") {
      guard r.cookies["SID"] == Self.googleSid else {
        return (401, [("Content-Type", "text/html; charset=utf-8")], Data("<html><head><title>Unauthorized</title></head><body>Error 401</body></html>".utf8))
      }
      let n = Int(r.path.split(separator: "/").dropFirst(2).first ?? "0") ?? 0
      return (200, [("Content-Type", "text/xml; charset=utf-8")], Data(gmailFeed(n < Self.gmailAccounts.count ? n : 0).utf8))
    }
    if r.method == "POST", r.path.hasPrefix("/api/v3/") {
      guard r.cookies["token_v2"] == Self.notionToken else {
        return (401, [("Content-Type", "application/json")], Data(#"{"errorId":"x","name":"UnauthorizedError","message":"Token was invalid or expired."}"#.utf8))
      }
      let body = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:]
      switch String(r.path.dropFirst(8)) {
      case "getSpaces": return json(notionSpaces)
      case "getNotificationLogV2": return json(notionLog(body["spaceId"] as? String ?? ""))
      default: return (400, [("Content-Type", "application/json")], Data(#"{"name":"ValidationError"}"#.utf8))
      }
    }
    return nil
  }

  // MARK: Gmail

  func atomDate(_ minutesAgo: Double) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: now.addingTimeInterval(-minutesAgo * 60))
  }

  func gmailFeed(_ n: Int) -> String {
    let me = Self.gmailAccounts[n]
    func entry(_ subject: String, _ summary: String, _ name: String, _ email: String, _ minutes: Double, _ id: String) -> String {
      """
      <entry><title>\(subject)</title><summary>\(summary)</summary><link rel="alternate" href="\(base)/mail/u/\(n)?account_id=\(me)&amp;message_id=\(id)&amp;view=conv&amp;extsrc=atom" type="text/html" /><modified>\(atomDate(minutes))</modified><issued>\(atomDate(minutes))</issued><id>tag:gmail.google.com,2004:\(id)</id><author><name>\(name)</name><email>\(email)</email></author></entry>
      """
    }
    let entries = n == 0 ? [
      entry("Q3 numbers for the board deck", "Hi! Could you send me the final Q3 numbers before Thursday? The board deck goes out Friday.", "Maya Chen", "maya@acme.test", 35, "18f0001"),
      entry("Q3 launch plan - Ana Lopez mentioned you", "Ana Lopez mentioned you in a comment: &quot;@you can you confirm the dates?&quot;", "Ana Lopez (Google Docs)", "comments-noreply@docs.google.com", 80, "18f0002"),
      entry("Your receipt from Acme Cloud #4821", "Thanks for your payment of $42.00.", "Acme Cloud", "billing@acme-cloud.test", 200, "18f0003"),
      entry("Re: Offsite dinner &amp; venue", "Works for me &#8212; want me to book it?", "Omar Haddad", "omar@acme.test", 420, "18f0004"),
    ] : [
      entry("Weekend plans?", "Are we still on for Saturday?", "Lee Park", "lee@personal.test", 60, "18f1001"),
      entry("Your weekly digest", "Top stories this week", "The Weekly", "newsletter@weekly.test", 900, "18f1002"),
    ]
    return """
      <?xml version="1.0" encoding="UTF-8"?><feed version="0.3" xmlns="http://purl.org/atom/ns#"><title>Gmail - Inbox for \(me)</title><tagline>New messages in your Gmail Inbox</tagline><fullcount>\(entries.count)</fullcount><link rel="alternate" href="\(base)/mail/u/\(n)" type="text/html" /><modified>\(atomDate(0))</modified>\(entries.joined())</feed>
      """
  }

  // MARK: Calendar

  /// Today's chips, built in the page's own time zone the way Google labels them
  /// ("2:30pm to 3pm, Title, …, September 28, 2026").
  var calendarPage: String {
    """
    <!doctype html><title>Google Calendar - Today</title><body style="font:14px -apple-system;padding:24px"><h2>Today</h2><div id=grid></div>
    <script>
    const now = new Date();
    const label = d => d.toLocaleDateString('en-US', {month: 'long', day: 'numeric', year: 'numeric'});
    const t = d => d.toLocaleTimeString('en-US', {hour: 'numeric', minute: '2-digit'}).replace(':00', '').replace(/\\s/g, '').toLowerCase();
    let a = new Date(now.getTime() + 60 * 60000); a.setSeconds(0, 0);
    if (a.getDate() !== now.getDate()) a = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 0, 30);
    const ae = new Date(a.getTime() + 30 * 60000), b = new Date(a.getTime() + 45 * 60000), be = new Date(b.getTime() + 15 * 60000);
    const tomorrow = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1, 10);
    const chips = [
      ['ev-design', t(a) + ' to ' + t(ae) + ', Design review, Maya Chen, Accepted, https://meet.google.com/abc-defg-hij, ' + label(now)],
      ['ev-sync', t(b) + ' to ' + t(be) + ', Hiring sync, No location, ' + label(now)],
      ['ev-offsite', 'All day, Company offsite, ' + label(now)],
      ['ev-tomorrow', '10am to 11am, Tomorrow planning, ' + label(tomorrow)],
    ];
    for (const [id, aria] of chips) {
      const el = document.createElement('div');
      el.setAttribute('data-eventid', id);
      el.setAttribute('aria-label', aria);
      el.textContent = aria.split(', ')[1];
      el.style.cssText = 'margin:6px 0;padding:8px 10px;border-radius:6px;background:#e8f0fe';
      document.getElementById('grid').appendChild(el);
    }
    </script>
    """
  }

  /// An iCal feed around `now`: a meeting in 10 minutes (Meet), one in 2 hours (Zoom in the
  /// location), an all-day event, a daily series with yesterday excluded, a series whose instance
  /// today moved, a cancelled event, one tomorrow, and a weekly series that ended (COUNT=2).
  var calendarICS: String {
    let utc = DateFormatter()
    utc.locale = Locale(identifier: "en_US_POSIX")
    utc.timeZone = TimeZone(identifier: "UTC")
    utc.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    let local = DateFormatter()
    local.locale = Locale(identifier: "en_US_POSIX")
    local.timeZone = .current
    local.dateFormat = "yyyyMMdd'T'HHmmss"
    let day = DateFormatter()
    day.locale = Locale(identifier: "en_US_POSIX")
    day.timeZone = .current
    day.dateFormat = "yyyyMMdd"
    let cal = Calendar.current
    func z(_ minutes: Double) -> String { utc.string(from: now.addingTimeInterval(minutes * 60)) }
    let startOfDay = cal.startOfDay(for: now)
    func wall(daysAgo: Int, hour: Int, minute: Int) -> String {
      local.string(from: cal.date(byAdding: .day, value: -daysAgo, to: startOfDay)!.addingTimeInterval(Double(hour * 3600 + minute * 60)))
    }
    let today = day.string(from: now), tomorrow = day.string(from: cal.date(byAdding: .day, value: 1, to: startOfDay)!)
    let weekday = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"][cal.component(.weekday, from: now) - 1]
    func ev(_ lines: [String]) -> String { (["BEGIN:VEVENT"] + lines + ["END:VEVENT"]).joined(separator: "\r\n") }
    let events = [
      ev(["UID:design@mock", "SUMMARY:Design review", "DTSTART:\(z(10))", "DTEND:\(z(40))",
          "X-GOOGLE-CONFERENCE:https://meet.google.com/abc-defg-hij", "DESCRIPTION:Agenda:\\n- slides 4–7\\, numbers",
          "BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:Reminder", "TRIGGER:-P0DT0H10M0S", "END:VALARM"]),
      ev(["UID:maya@mock", "SUMMARY:1:1 with Maya", "DTSTART:\(z(120))", "DTEND:\(z(150))", "LOCATION:https://acme.zoom.us/j/123456789"]),
      ev(["UID:offsite@mock", "SUMMARY:Company offsite", "DTSTART;VALUE=DATE:\(today)", "DTEND;VALUE=DATE:\(tomorrow)"]),
      ev(["UID:standup@mock", "SUMMARY:Standup", "DTSTART;TZID=Europe/Somewhere:\(wall(daysAgo: 7, hour: 0, minute: 5))",
          "DTEND;TZID=Europe/Somewhere:\(wall(daysAgo: 7, hour: 0, minute: 20))", "RRULE:FREQ=DAILY",
          "EXDATE;TZID=Europe/Somewhere:\(wall(daysAgo: 1, hour: 0, minute: 5))"]),
      ev(["UID:focus@mock", "SUMMARY:Focus time", "DTSTART;TZID=Europe/Somewhere:\(wall(daysAgo: 3, hour: 0, minute: 30))",
          "DTEND;TZID=Europe/Somewhere:\(wall(daysAgo: 3, hour: 0, minute: 45))", "RRULE:FREQ=DAILY;INTERVAL=1"]),
      ev(["UID:focus@mock", "SUMMARY:Focus time (moved)", "RECURRENCE-ID;TZID=Europe/Somewhere:\(wall(daysAgo: 0, hour: 0, minute: 30))",
          "DTSTART:\(z(180))", "DTEND:\(z(210))"]),
      ev(["UID:cancelled@mock", "SUMMARY:Cancelled lunch", "DTSTART:\(z(60))", "DTEND:\(z(90))", "STATUS:CANCELLED"]),
      ev(["UID:tomorrow@mock", "SUMMARY:Tomorrow planning", "DTSTART:\(z(24 * 60 + 5))", "DTEND:\(z(24 * 60 + 35))"]),
      ev(["UID:ended@mock", "SUMMARY:Old weekly", "DTSTART;TZID=Europe/Somewhere:\(wall(daysAgo: 21, hour: 0, minute: 10))",
          "DTEND;TZID=Europe/Somewhere:\(wall(daysAgo: 21, hour: 0, minute: 40))", "RRULE:FREQ=WEEKLY;BYDAY=\(weekday);COUNT=2"]),
    ]
    return (["BEGIN:VCALENDAR", "PRODID:-//Google Inc//Google Calendar 70.9054//EN", "VERSION:2.0", "X-WR-CALNAME:you@acme.test"]
      + events + ["END:VCALENDAR"]).joined(separator: "\r\n") + "\r\n"
  }

  // MARK: Notion

  var notionSpaces: [String: Any] {
    [
      "U1OCTO": [
        "notion_user": ["U1OCTO": ["role": "reader", "value": ["id": "U1OCTO", "name": "Octo Den", "email": "octo@acme.test"]]],
        // One record in the newer nesting (`value.value`), one in the older.
        "space": [
          "a1b2c3d4-0000-4000-8000-000000000001": ["spaceId": "a1b2c3d4-0000-4000-8000-000000000001",
                                                    "value": ["value": ["id": "a1b2c3d4-0000-4000-8000-000000000001", "name": "Acme"], "role": "editor"]],
          "a1b2c3d4-0000-4000-8000-000000000002": ["role": "editor", "value": ["id": "a1b2c3d4-0000-4000-8000-000000000002", "name": "Side project", "icon": "🌱"]],
        ],
        "space_view": [:],
      ],
    ]
  }

  func notionLog(_ space: String) -> [String: Any] {
    guard space == "a1b2c3d4-0000-4000-8000-000000000001" else { return ["notificationIds": [], "recordMap": [:]] }
    let ms = { (minutes: Double) in String(Int64((now.timeIntervalSince1970 - minutes * 60) * 1000)) }
    func rec(_ v: [String: Any]) -> [String: Any] { ["role": "reader", "value": v] }
    return [
      "notificationIds": ["n-mention", "n-comment", "n-invite", "n-read"],
      "recordMap": [
        "notification": [
          "n-mention": rec(["id": "n-mention", "activity_id": "a-mention", "read": false, "type": "user-mentioned", "end_time": ms(20)]),
          "n-comment": rec(["id": "n-comment", "activity_id": "a-comment", "read": false, "type": "commented", "end_time": ms(50)]),
          "n-invite": rec(["id": "n-invite", "activity_id": "a-invite", "read": false, "type": "user-invited", "end_time": ms(300)]),
          "n-read": rec(["id": "n-read", "activity_id": "a-read", "read": true, "type": "user-mentioned", "end_time": ms(600)]),
        ],
        "activity": [
          "a-mention": rec(["id": "a-mention", "type": "user-mentioned", "navigable_block_id": "b0000000-0000-4000-8000-00000000000a",
                            "mentioned_block_id": "b0000000-0000-4000-8000-00000000000b", "end_time": ms(20),
                            "edits": [["type": "block-changed", "authors": [["id": "U2MAYA", "table": "notion_user"]]]]]),
          "a-comment": rec(["id": "a-comment", "type": "commented", "parent_id": "b0000000-0000-4000-8000-00000000000a",
                            "discussion_id": "d0000000-0000-4000-8000-00000000000d", "end_time": ms(50),
                            "edits": [["type": "comment-created", "authors": [["id": "U3ANA"]], "discussion_id": "d0000000-0000-4000-8000-00000000000d",
                                       "comment_data": ["text": [["Can you double-check the "], ["‣", [["u", "U1OCTO"]]], [" numbers in section 3?"]]]]]]),
          "a-invite": rec(["id": "a-invite", "type": "user-invited", "navigable_block_id": "b0000000-0000-4000-8000-00000000000c", "end_time": ms(300),
                           "edits": [["type": "permission-changed", "authors": [["id": "U2MAYA"]]]]]),
          "a-read": rec(["id": "a-read", "type": "user-mentioned", "navigable_block_id": "b0000000-0000-4000-8000-00000000000a", "end_time": ms(600)]),
        ],
        "block": [
          "b0000000-0000-4000-8000-00000000000a": rec(["id": "b0000000-0000-4000-8000-00000000000a", "type": "page",
                                                        "properties": ["title": [["Q3 launch plan"]]]]),
          "b0000000-0000-4000-8000-00000000000b": rec(["id": "b0000000-0000-4000-8000-00000000000b", "type": "text",
                                                        "properties": ["title": [["‣", [["u", "U1OCTO"]]], [" owns the release notes"]]]]),
          "b0000000-0000-4000-8000-00000000000c": rec(["id": "b0000000-0000-4000-8000-00000000000c", "type": "page",
                                                        "properties": ["title": [["Hiring plan 2027"]]]]),
        ],
        "notion_user": [
          "U1OCTO": rec(["id": "U1OCTO", "name": "Octo Den"]),
          "U2MAYA": rec(["id": "U2MAYA", "name": "Maya Chen"]),
          "U3ANA": rec(["id": "U3ANA", "name": "Ana Lopez"]),
        ],
      ],
    ]
  }
}
#endif
