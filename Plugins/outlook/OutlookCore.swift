#if !hasFeature(Embedded)
  import CordisValue
#endif

/// Outlook (Mail + Calendar) through the Microsoft session the user signed in to in den (no OAuth app,
/// no Outlook API).
///
/// - **Connected** when the profile has Microsoft's `esctx` or `fpc` sign-in cookies and the
///   Microsoft Graph endpoint (`/me/mailFolders/inbox/messages`) answers for at least one account.
///   Every signed-in Microsoft account is found by probing `login.microsoftonline.com` for the
///   `esctx` cookie (the Microsoft 365 web-session cookie) and trying `/me` on Graph.
///   The account's display name and email are the connection's `account`.
/// - **Data**: one Graph request per refresh and enabled feature (mail or calendar), each using the
///   session cookies on `graph.microsoft.com`:
///   `GET /me/messages?$top=15&$filter=isRead eq false&$orderby=receivedDateTime desc` (unread emails),
///   `GET /me/events?$top=10&$filter=start/dateTime ge <now>&$orderby=start/dateTime asc` (upcoming calendar events).
///   Results are re-read on each refresh, nothing is stored.
/// - A 401/403 on Graph means the session ended: `connections.report {expired}`.

final class OutlookCore {
  static let id = "outlook"
  static let icon = "https://www.microsoft.com/favicon.ico"
  static let maxUnread = 15
  static let maxEvents = 10

  struct Account {
    var email: String
    var displayName: String
  }

  let env: PluginEnv
  let requests: Requests
  var account: Account?  // in memory only
  var registerAttempts = 0
  var refreshing = false
  /// The `esctx` value the last automatic probe failed with: the same session isn't probed twice
  /// (Microsoft rotates other cookies on most page loads, and every rotation is a cookie change).
  var failedEsctx = ""
  /// Whether to fetch mail (user toggle, defaults true).
  var fetchMail = true
  /// Whether to fetch calendar (user toggle, defaults true).
  var fetchCalendar = true
  var settingsObserved = false

  init(env: PluginEnv) {
    self.env = env
    requests = Requests(env: env, prefix: "outlook")
  }

  /// Endpoints, overridable in storage ns `outlook` key `endpoints` {graph, mail, domain, signIn} (tests, mocks).
  var endpoints: Value { env.call("storage", "get", ["ns": "outlook", "key": "endpoints"]) }
  var graph: String { endpoints.sOpt("graph") ?? "https://graph.microsoft.com" }
  var mail: String { endpoints.sOpt("mail") ?? "https://outlook.office.com" }
  var domain: String { endpoints.sOpt("domain") ?? "microsoft.com" }
  var signIn: String { endpoints.sOpt("signIn") ?? "https://login.microsoftonline.com" }

  func start() {
    env.on("connections.probe") { [self] v in
      if v.s("id") == Self.id { probe(profile: v.sOpt("profile") ?? "default", auto: v.s("reason") == "register") }
    }
    env.on("feed.refresh") { [self] _ in refresh() }
    env.on("session.cookiesChanged") { [self] v in
      if v.s("domain") == domain { autoProbe(v.sOpt("profile") ?? "default") }
    }
    register()
    registerSettings()
    env.call("session", "watchCookies", ["plugin": .string(Self.id), "domain": .string(domain), "profile": "default"])
    autoProbe("default")
  }

  func register() {
    let r = env.call("connections", "register", ["id": .string(Self.id), "title": "Outlook", "icon": .string(Self.icon),
                                                  "domain": "outlook.office.com", "signIn": .string(signIn + "/common/oauth2/v2.0/authorize"),
                                                  "owner": .string(Self.id), "unit": "accounts", "order": 25, "important": true])
    if r.isErr && registerAttempts < 60 {
      registerAttempts += 1
      env.timer(500, false) { [self] in register() }
    }
  }

  func connection() -> Value? {
    let c = env.call("connections", "get", ["id": .string(Self.id)])
    return c.b("connected") ? c : Optional<Value>.none
  }

  static func esctx(_ cookies: [Value]) -> String {
    for n in ["esctx", "fpc", "brc"] {
      if let c = cookies.first(where: { $0.s("name") == n && !$0.s("value").isEmpty }) { return c.s("value") }
    }
    return ""
  }

  /// A probe nobody asked for (launch, a cookie change). While connected it only checks that the
  /// session cookie is still there (no request to Graph).
  func autoProbe(_ profile: String) {
    let c = env.call("connections", "get", ["id": .string(Self.id)])
    if c.b("declined") { return }
    requests.call("session", "cookies", ["plugin": .string(Self.id), "domain": .string(domain), "profile": .string(profile)]) { [self] r in
      let esctx = Self.esctx(r.a("cookies"))
      if c.b("connected") {
        guard (c.sOpt("profile") ?? "default") == profile, esctx.isEmpty else { return }
        account = nil
        env.call("connections", "report", ["id": .string(Self.id), "connected": false, "profile": .string(profile), "auto": true])
        return
      }
      guard !esctx.isEmpty, esctx != failedEsctx else { return }
      probe(profile: profile, auto: true, esctx: esctx)
    }
  }

  // MARK: Probe

  func probe(profile: String, auto: Bool, esctx known: String? = nil) {
    let check: (@escaping (String) -> Void) -> Void = { [self] next in
      if let known { return next(known) }
      requests.call("session", "cookies", ["plugin": .string(Self.id), "domain": .string(domain), "profile": .string(profile)]) { r in
        next(Self.esctx(r.a("cookies")))
      }
    }
    check { [self] esctx in
      guard !esctx.isEmpty else { return report(false, profile: profile, auto: auto) }
      verifyMe(profile: profile) { [self] found in
        account = found
        if found == nil {
          if auto { failedEsctx = esctx }
          return report(false, profile: profile, auto: auto)
        }
        failedEsctx = ""
        env.call("connections", "report", ["id": .string(Self.id), "connected": true, "profile": .string(profile),
                                            "account": .string(found!.displayName + " (" + found!.email + ")"), "auto": .bool(auto)])
      }
    }
  }

  func report(_ connected: Bool, profile: String, auto: Bool) {
    env.call("connections", "report", ["id": .string(Self.id), "connected": .bool(connected), "profile": .string(profile), "auto": .bool(auto)])
  }

  /// `GET /me` on Graph to verify the session and get the account details.
  func verifyMe(profile: String, _ done: @escaping (Account?) -> Void) {
    requests.call("net", "fetch", ["plugin": .string(Self.id), "url": .string(graph + "/v1.0/me?select=displayName,mail,userPrincipalName"),
                                    "session": true, "profile": .string(profile), "as": "json"]) { r in
      if !r.b("ok"), r.i("status") < 400 { return done(nil) }
      let json = r["json"]
      guard !json["error"].isNull else { return }
      let email = json.sOpt("mail") ?? json.sOpt("userPrincipalName") ?? ""
      let name = json.sOpt("displayName") ?? email
      done(Account(email: email, displayName: name))
    }
  }

  /// The session ended: 401/403 on Graph.
  static func authGone(_ status: Int64) -> Bool { status == 401 || status == 403 }

  // MARK: Settings

  func registerSettings() {
    let r = env.call("settings", "register", [
      "id": .string(Self.id), "section": "connections", "title": "Outlook", "icon": .string(Self.icon), "order": 26,
      "controls": [
        ["key": "mail", "type": "toggle", "title": "Mail", "subtitle": "Show unread email in the briefing", "default": true],
        ["key": "calendar", "type": "toggle", "title": "Calendar", "subtitle": "Show upcoming events in the briefing", "default": true],
      ],
    ])
    guard !r.isErr, !settingsObserved else { return }
    settingsObserved = true
    fetchMail = env.call("settings", "get", ["id": .string(Self.id), "key": "mail"]).b("value", true)
    fetchCalendar = env.call("settings", "get", ["id": .string(Self.id), "key": "calendar"]).b("value", true)
    env.on("settings.changed") { [self] v in
      guard v.s("id") == Self.id else { return }
      if v.s("key") == "mail" { fetchMail = v["value"].b("value", true); refresh() }
      else if v.s("key") == "calendar" { fetchCalendar = v["value"].b("value", true); refresh() }
    }
  }

  // MARK: Refresh

  func refresh() {
    guard connection() != nil, !refreshing else { return }
    refreshing = true
    let profile = (connection()?.sOpt("profile") ?? "default")
    var items: [Value] = []
    var error: String?
    var expired = false

    let mailDone: (@escaping () -> Void) -> Void = { [self] next in
      guard fetchMail else { return next() }
      requests.call("net", "fetch", ["plugin": .string(Self.id), "url": .string(graph + "/v1.0/me/messages?" +
        Web.encode("$top") + "=" + String(Self.maxUnread) + "&" +
        Web.encode("$filter") + "=" + Web.encode("isRead+eq+false") + "&" +
        Web.encode("$orderby") + "=" + Web.encode("receivedDateTime+desc") + "&" +
        Web.encode("$select") + "=" + Web.encode("subject,from,receivedDateTime,body,internetMessageId") +
        "&" + Web.encode("$expand") + "=" + Web.encode("attachments($select=id,contentType,contentBytes,name)") +
        ""),
                                      "session": true, "profile": .string(profile), "as": "json"]) { r in
        let json = r["json"]
        if Self.authGone(r.i("status")) {
          expired = true
        } else if !r.b("ok"), r.i("status") >= 400 {
          error = error ?? "Outlook returned " + String(r.i("status"))
        } else {
          let msgs = json.a("value")
          items += msgs.prefix(Self.maxUnread).map { Self.mailItem($0, icon: Self.icon) }
        }
        next()
      }
    }

    let calDone: (@escaping () -> Void) -> Void = { [self] next in
      guard fetchCalendar else { return next() }
      let now = Web.date(env.now())
      let tomorrow = Web.date(env.now() + 7 * 86_400_000)
      requests.call("net", "fetch", ["plugin": .string(Self.id), "url": .string(graph + "/v1.0/me/events?" +
        Web.encode("$top") + "=" + String(Self.maxEvents) + "&" +
        Web.encode("$filter") + "=" + Web.encode("start/dateTime+ge+" + Web.encode(now) + "+and+start/dateTime+le+" + Web.encode(tomorrow)) +
        "&" + Web.encode("$orderby") + "=" + Web.encode("start/dateTime+asc") + "&" +
        Web.encode("$select") + "=" + Web.encode("subject,organizer,start,end,location,body,attendees,isOnlineMeeting,onlineMeetingUrl") +
        ""),
                                      "session": true, "profile": .string(profile), "as": "json"]) { r in
        let json = r["json"]
        if Self.authGone(r.i("status")) {
          expired = true
        } else if !r.b("ok"), r.i("status") >= 400 {
          error = error ?? "Outlook Calendar returned " + String(r.i("status"))
        } else {
          let evts = json.a("value")
          items += evts.prefix(Self.maxEvents).map { self.calEvent($0, icon: Self.icon) }
        }
        next()
      }
    }

    sequence([mailDone, calDone]) { [self] in
      refreshing = false
      if expired {
        account = nil
        env.call("connections", "report", ["id": .string(Self.id), "connected": false, "expired": true])
        env.emit("feed.items", ["source": .string(Self.id), "items": [], "error": "signed out"])
        return
      }
      var payload: Value = ["source": .string(Self.id), "items": .array(items)]
      if let error { payload.put("error", .string(error)) }
      env.emit("feed.items", payload)
    }
  }

  /// Unread email from Graph API -> feed item.
  static func mailItem(_ msg: Value, icon: String) -> Value {
    let subject = msg.sOpt("subject") ?? "(no subject)"
    let from = msg["from"].sOpt("emailAddress") ?? msg["from"]["emailAddress"].s("name") ?? "Someone"
    let received = msg.i("receivedDateTime")
    let bodyPlain = msg["body"].sOpt("content") ?? ""
    let snippet = Web.oneLine(bodyPlain, max: 160)
    let preview = snippet.isEmpty ? subject : subject + (snippet.isEmpty ? "" : " — " + snippet)

    let messageId = msg.sOpt("internetMessageId") ?? String(received)
    let isRead = msg.b("isRead")
    let kind = isRead ? "email" : "reply"
    let badge: String
    let detail: String
    let summary: String

    if isRead {
      badge = "Mail"
      detail = "From " + from
      summary = "Unread email from " + from + ": " + subject
    } else {
      badge = "Unread"
      detail = "From " + from + " · unread"
      summary = "Unread email from " + from + ": " + subject
    }

    let url = "https://outlook.office.com/owa/"

    return [
      "id": .string("outlook:mail:" + messageId),
      "source": .string(Self.id), "kind": .string(kind), "title": .string(subject),
      "detail": .string(detail), "url": .string(url), "ts": .int(received), "icon": .string(Self.icon),
      "badge": .string(badge), "actor": .string(from), "where": .string("Outlook"),
      "actionable": true, "summary": .string(summary),
    ]
  }

  /// Calendar event from Graph API -> feed item.
  func calEvent(_ evt: Value, icon: String) -> Value {
    let subject = evt.sOpt("subject") ?? "(Untitled)"
    let startMs = evt.i("start")
    let endMs = evt.i("end")
    let organizer = evt["organizer"].sOpt("emailAddress") ?? evt["organizer"]["emailAddress"].s("name") ?? ""
    let location = evt.sOpt("location") ?? ""
    let isOnline = evt.b("isOnlineMeeting")
    let onlineUrl = evt.sOpt("onlineMeetingUrl") ?? ""

    let startTime = env.call("schedule", "clock", ["ms": .int(startMs)]).s("time")
    let endTime = env.call("schedule", "clock", ["ms": .int(endMs)]).s("time")
    let timeStr = startTime + " – " + endTime

    var detail: String
    var badge: String
    var summary: String

    if isOnline {
      badge = "Event"
      detail = timeStr + (location.isEmpty ? "" : " · " + location) + " · online"
      summary = "Upcoming meeting: " + subject + " at " + timeStr + " (online)"
    } else {
      badge = "Event"
      detail = timeStr + (location.isEmpty ? "" : " · " + location)
      summary = "Upcoming event: " + subject + " at " + timeStr + (location.isEmpty ? "" : " in " + location)
    }

    if !organizer.isEmpty { detail += " · " + organizer }

    return [
      "id": .string("outlook:cal:" + String(startMs)),
      "source": .string(Self.id), "kind": "event", "title": .string(subject),
      "detail": .string(detail), "url": .string("https://outlook.office.com/owa/?path=/calendar/action/compose"),
      "ts": .int(startMs), "end": .int(endMs), "icon": .string(icon),
      "badge": .string(badge), "actor": .string(organizer), "where": .string("Outlook Calendar"),
      "actionable": .bool(isOnline), "summary": .string(summary),
      "join": .string(onlineUrl),
    ]
  }
}