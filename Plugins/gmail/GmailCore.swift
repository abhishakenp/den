#if !hasFeature(Embedded)
  import CordisValue
#endif

/// Gmail through the Google session the user signed in to in den (no OAuth app, no Gmail API).
///
/// - **Connected** when the profile has Google's `SID` sign-in cookie and Gmail's Atom feed
///   (`/mail/u/<n>/feed/atom`, the unread mail in the inbox) answers for at least one account.
///   Every signed-in Google account is found by walking `u/0`, `u/1`, … until an index answers with
///   an account already seen (Google sends unknown indexes to the first account) or nothing.
///   Those are the connection's `teams` ("accounts"), each switchable in Settings.
/// - **Data**: one feed request per enabled account and refresh. Each unread thread becomes a feed
///   item: `reply` (from a person: "awaiting your reply", a heuristic: the feed only says unread),
///   `docs` (a Google Docs, Sheets or Drive comment, mention or share notification) or `email`
///   (automated senders: not a todo). Nothing is stored; the feed is re-read on each refresh.
/// - A 401/403, or a feed request that no longer returns a feed, means the session ended:
///   `connections.report {expired}`.
final class GmailCore {
  static let id = "gmail"
  static let icon = "https://www.google.com/s2/favicons?domain=mail.google.com&sz=64"
  static let maxAccounts = 4
  static let maxItems = 12

  struct Account {
    var index: String
    var email: String
  }

  let env: PluginEnv
  let requests: Requests
  var accounts: [Account] = []  // in memory only
  var registerAttempts = 0
  var refreshing = false
  /// The `SID` value the last automatic probe failed with: the same session isn't probed twice
  /// (Google rotates other cookies on most page loads, and every rotation is a cookie change).
  var failedSid = ""

  init(env: PluginEnv) {
    self.env = env
    requests = Requests(env: env, prefix: "gmail")
  }

  /// Endpoints, overridable in storage ns `gmail` key `endpoints` {base, domain, signIn} (tests, mocks).
  var endpoints: Value { env.call("storage", "get", ["ns": "gmail", "key": "endpoints"]) }
  var base: String { endpoints.sOpt("base") ?? "https://mail.google.com" }
  var domain: String { endpoints.sOpt("domain") ?? "google.com" }
  var signIn: String { endpoints.sOpt("signIn") ?? "https://mail.google.com/mail/" }

  func start() {
    env.on("connections.probe") { [self] v in
      if v.s("id") == Self.id { probe(profile: v.sOpt("profile") ?? "default", auto: false) }
    }
    env.on("feed.refresh") { [self] _ in refresh() }
    env.on("session.cookiesChanged") { [self] v in
      if v.s("domain") == domain { autoProbe(v.sOpt("profile") ?? "default") }
    }
    register()
    env.call("session", "watchCookies", ["plugin": .string(Self.id), "domain": .string(domain), "profile": "default"])
    autoProbe("default")
  }

  func register() {
    let r = env.call("connections", "register", ["id": .string(Self.id), "title": "Gmail", "icon": .string(Self.icon), "domain": "mail.google.com",
                                                  "signIn": .string(signIn), "owner": .string(Self.id), "unit": "accounts", "order": 30, "important": true])
    if r.isErr && registerAttempts < 60 {
      registerAttempts += 1
      env.timer(500, false) { [self] in register() }
    }
  }

  func connection() -> Value? {
    let c = env.call("connections", "get", ["id": .string(Self.id)])
    return c.b("connected") ? c : nil
  }

  static func sid(_ cookies: [Value]) -> String {
    for n in ["SID", "__Secure-3PSID", "__Secure-1PSID"] {
      if let c = cookies.first(where: { $0.s("name") == n && !$0.s("value").isEmpty }) { return c.s("value") }
    }
    return ""
  }

  /// A probe nobody asked for (launch, a cookie change). While connected it only checks that the
  /// sign-in cookie is still there (no request to Gmail).
  func autoProbe(_ profile: String) {
    let c = env.call("connections", "get", ["id": .string(Self.id)])
    if c.b("declined") { return }
    requests.call("session", "cookies", ["plugin": .string(Self.id), "domain": .string(domain), "profile": .string(profile)]) { [self] r in
      let sid = Self.sid(r.a("cookies"))
      if c.b("connected") {
        guard (c.sOpt("profile") ?? "default") == profile, sid.isEmpty else { return }
        accounts = []
        env.call("connections", "report", ["id": .string(Self.id), "connected": false, "profile": .string(profile), "auto": true])
        return
      }
      guard !sid.isEmpty, sid != failedSid else { return }
      probe(profile: profile, auto: true, sid: sid)
    }
  }

  // MARK: Probe

  func probe(profile: String, auto: Bool, sid known: String? = nil) {
    let check: (@escaping (String) -> Void) -> Void = { [self] next in
      if let known { return next(known) }
      requests.call("session", "cookies", ["plugin": .string(Self.id), "domain": .string(domain), "profile": .string(profile)]) { r in
        next(Self.sid(r.a("cookies")))
      }
    }
    check { [self] sid in
      guard !sid.isEmpty else { return report(false, profile: profile, auto: auto) }
      findAccounts(profile: profile) { [self] found in
        accounts = found
        if found.isEmpty {
          if auto { failedSid = sid }
          return report(false, profile: profile, auto: auto)
        }
        failedSid = ""
        let list: [Value] = found.map { a in
          ["id": .string(a.index), "name": .string(a.email), "url": .string(base + "/mail/u/" + a.index + "/"), "icon": .string(Self.icon), "enabled": true]
        }
        env.call("connections", "report", ["id": .string(Self.id), "connected": true, "profile": .string(profile),
                                            "account": .string(found[0].email), "teams": .array(list), "auto": .bool(auto)])
      }
    }
  }

  func report(_ connected: Bool, profile: String, auto: Bool) {
    env.call("connections", "report", ["id": .string(Self.id), "connected": .bool(connected), "profile": .string(profile), "auto": .bool(auto)])
  }

  func feedURL(_ index: String) -> String { base + "/mail/u/" + index + "/feed/atom" }

  /// Walks `u/0`, `u/1`, … (at most `maxAccounts`) and returns the accounts whose feed answers.
  func findAccounts(profile: String, _ done: @escaping ([Account]) -> Void) {
    var found: [Account] = []
    func step(_ n: Int) {
      guard n < Self.maxAccounts else { return done(found) }
      fetchFeed(String(n), profile: profile) { r in
        guard let feed = r, !feed.email.isEmpty, !found.contains(where: { $0.email == feed.email }) else { return done(found) }
        found.append(Account(index: String(n), email: feed.email))
        step(n + 1)
      }
    }
    step(0)
  }

  struct Feed {
    var email: String
    var count: Int
    var entries: [Value]
  }

  /// One account's Atom feed, or nil (signed out, no Gmail, an error). `status` is 0 for a network error.
  func fetchFeed(_ index: String, profile: String, status: ((Int64) -> Void)? = nil, _ done: @escaping (Feed?) -> Void) {
    requests.call("net", "fetch", ["plugin": .string(Self.id), "url": .string(feedURL(index)), "session": true, "profile": .string(profile),
                                    "as": "text", "maxBytes": 2_000_000]) { r in
      status?(r.b("ok") ? r.i("status") : 0)
      guard r.b("ok"), r.i("status") < 400, Text.contains(r.s("text"), "<feed") else { return done(nil) }
      done(Self.parse(r.s("text")))
    }
  }

  // MARK: Atom

  /// Gmail's Atom feed: `<title>Gmail - Inbox for you@example.com</title>`, `<fullcount>`, and an
  /// `<entry>` per unread thread (title, summary, link href, issued/modified, id, author name and email).
  static func parse(_ xml: String) -> Feed {
    let b = Array(xml.utf8)
    let count = Text.int(Web.between(b, "<fullcount>", "</fullcount>")?.0 ?? "") ?? 0
    var email = ""
    if let t = Web.between(b, "<title>", "</title>")?.0, let r = Web.find(Array(t.utf8), Array(" for ".utf8)) {
      email = Web.oneLine(String(decoding: Array(t.utf8)[(r + 5)...], as: UTF8.self))
    }
    var entries: [Value] = []
    var pos = 0
    while entries.count < 40, let (entry, next) = Web.between(b, "<entry>", "</entry>", from: pos) {
      pos = next
      let e = Array(entry.utf8)
      func field(_ tag: String) -> String { Web.oneLine(Web.entities(Web.between(e, "<" + tag + ">", "</" + tag + ">")?.0 ?? "")) }
      var link = ""
      if let l = Web.between(e, "<link", ">")?.0, let h = Web.between(Array(l.utf8), "href=\"", "\"")?.0 { link = Web.entities(h) }
      var author: Value = ["name": "", "email": ""]
      if let a = Web.between(e, "<author>", "</author>")?.0 {
        let ab = Array(a.utf8)
        author = ["name": .string(Web.oneLine(Web.entities(Web.between(ab, "<name>", "</name>")?.0 ?? ""))),
                  "email": .string(Text.lower(Web.oneLine(Web.between(ab, "<email>", "</email>")?.0 ?? "")))]
      }
      let issued = field("issued")
      entries.append(["title": .string(field("title")), "summary": .string(field("summary")), "link": .string(link),
                      "ts": .int(Web.isoMs(issued.isEmpty ? field("modified") : issued)), "entryId": .string(field("id")),
                      "name": author["name"], "email": author["email"]])
    }
    return Feed(email: email, count: count, entries: entries)
  }

  /// Senders that are Google's collaboration notifications (comments, mentions, shares).
  static let docsSenders = ["comments-noreply@docs.google.com", "drive-shares-dm-noreply@google.com", "drive-shares-noreply@google.com",
                            "drive-noreply@google.com", "calendar-notification@google.com"]
  /// Local parts of automated senders: their mail is listed, never a todo.
  static let robots = ["noreply", "no-reply", "no_reply", "donotreply", "do-not-reply", "do_not_reply", "notification", "notifications",
                       "notify", "mailer-daemon", "postmaster", "newsletter", "newsletters", "news", "digest", "alert", "alerts", "updates",
                       "update", "info", "hello", "marketing", "billing", "receipt", "receipts", "invoice", "invoices", "security",
                       "account", "accounts", "support", "team", "bounce", "bounces", "automated", "system"]

  /// `reply` (a person wrote: probably awaiting your reply), `docs` or `email` (automated).
  static func classify(email: String) -> String {
    let e = Text.lower(email)
    if docsSenders.contains(e) || Text.hasPrefix(afterAt(e), "docs.google.") { return e == "calendar-notification@google.com" ? "email" : "docs" }
    let local = beforeAt(e)
    if local.isEmpty { return "email" }
    for r in robots where local == r || Text.hasPrefix(local, r + "-") || Text.hasPrefix(local, r + ".") || Text.hasPrefix(local, r + "+") || Text.hasPrefix(local, r + "_") {
      return "email"
    }
    if Text.contains(local, "noreply") || Text.contains(local, "no-reply") || Text.contains(local, "notification") { return "email" }
    return "reply"
  }

  static func beforeAt(_ e: String) -> String {
    let b = Array(e.utf8)
    guard let at = b.lastIndex(of: 64) else { return "" }
    return String(decoding: b[..<at], as: UTF8.self)
  }

  static func afterAt(_ e: String) -> String {
    let b = Array(e.utf8)
    guard let at = b.lastIndex(of: 64) else { return "" }
    return String(decoding: b[(at + 1)...], as: UTF8.self)
  }

  /// The message id Gmail's feed links carry (`message_id=…`), else the entry's id.
  static func messageId(_ entry: Value) -> String {
    let m = Web.query(entry.s("link"), "message_id")
    if !m.isEmpty { return m }
    let id = Array(entry.s("entryId").utf8)
    if let colon = id.lastIndex(of: 58) { return String(decoding: id[(colon + 1)...], as: UTF8.self) }
    return entry.s("entryId")
  }

  static func item(_ e: Value, account: Account, multi: Bool, base: String) -> Value {
    let kind = classify(email: e.s("email"))
    let sender = e.s("name").isEmpty ? e.s("email") : e.s("name")
    let subject = e.s("title").isEmpty ? "(no subject)" : e.s("title")
    let snippet = Web.oneLine(e.s("summary"), max: 160)
    var detail: String
    let badge: String
    let summary: String
    switch kind {
    case "reply":
      detail = sender + " · waiting for your reply"
      badge = "Reply"
      summary = sender + " emailed you and may be waiting for a reply: " + subject + (snippet.isEmpty ? "" : " (" + snippet + ")")
    case "docs":
      detail = sender + " · Google Docs"
      badge = "Docs"
      summary = sender + " in Google Docs: " + subject
    default:
      detail = "From " + sender
      badge = "Email"
      summary = "Unread email from " + sender + ": " + subject
    }
    if multi { detail += " · " + account.email }
    let url = e.sOpt("link") ?? (base + "/mail/u/" + account.index + "/#inbox")
    var v: Value = [
      "id": .string("gmail:" + account.index + ":" + messageId(e)), "source": .string(id), "kind": .string(kind),
      "title": .string(subject), "detail": .string(detail), "url": .string(url), "ts": .int(e.i("ts")), "icon": .string(icon),
      "badge": .string(badge), "actor": .string(sender), "where": .string(kind == "docs" ? "Google Docs" : e.s("email")),
      "actionable": .bool(kind != "email"), "summary": .string(summary),
    ]
    if kind != "docs" && !e.s("email").isEmpty {
      // A sender the user can mark important (briefing).
      v.put("importantKey", .string("gmail:" + e.s("email")))
      v.put("importantTitle", .string(e.s("name").isEmpty ? e.s("email") : e.s("name") + " (" + e.s("email") + ")"))
    }
    return v
  }

  // MARK: Refresh

  func refresh() {
    guard let c = connection(), !refreshing else { return }
    refreshing = true
    let profile = c.sOpt("profile") ?? "default"
    let enabled = c.a("teams").filter { $0.b("enabled", true) }.map { $0.s("id") }
    let run = { [self] in
      var items: [Value] = []
      var error: String?
      var expired = false
      let multi = accounts.count > 1
      let steps: [(@escaping () -> Void) -> Void] = accounts.filter { enabled.contains($0.index) }.map { a in
        { [self] next in
          var status: Int64 = 0
          fetchFeed(a.index, profile: profile, status: { status = $0 }) { [self] feed in
            if let feed {
              let sorted = feed.entries.sorted { $0.i("ts") > $1.i("ts") }
              items += sorted.prefix(Self.maxItems).map { Self.item($0, account: a, multi: multi, base: base) }
            } else if status == 401 || status == 403 {
              expired = true
            } else {
              error = error ?? (status == 0 ? "network error" : "Gmail returned " + String(status))
            }
            next()
          }
        }
      }
      sequence(steps) { [self] in
        refreshing = false
        if expired {
          accounts = []
          env.call("connections", "report", ["id": .string(Self.id), "connected": false, "expired": true])
          env.emit("feed.items", ["source": .string(Self.id), "items": [], "error": "signed out"])
          return
        }
        var payload: Value = ["source": .string(Self.id), "items": .array(items), "account": c["account"]]
        if let error { payload.put("error", .string(error)) }
        env.emit("feed.items", payload)
      }
    }
    // Accounts live in memory only: after a relaunch, find them again.
    if accounts.isEmpty {
      findAccounts(profile: profile) { [self] found in
        accounts = found
        if found.isEmpty {
          refreshing = false
          env.call("connections", "report", ["id": .string(Self.id), "connected": false, "expired": true])
          env.emit("feed.items", ["source": .string(Self.id), "items": [], "error": "signed out"])
        } else {
          run()
        }
      }
    } else {
      run()
    }
  }
}
