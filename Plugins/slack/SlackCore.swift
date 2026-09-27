#if !hasFeature(Embedded)
  import CordisValue
#endif

/// Slack through the web session the user signed in to in den (no Slack app, nothing to register).
///
/// - **Connected** when the profile has slack.com's `d` cookie and app.slack.com's localStorage has
///   `localConfig_v2` with at least one team. That config holds each workspace's web-client token
///   (`xoxc-…`); den reads it with `session.eval` and keeps it **in memory only**.
/// - **Data**: plain Web API calls, as the Slack web client makes them (form POST with `token`,
///   plus the `d` cookie via `net.fetch {session: true}`), per enabled workspace:
///   `client.counts` (which DMs are unread) → `conversations.history` for up to 6 unread DMs;
///   `search.messages` for `<@you>` over the last 2 days (mentions); `conversations.replies` for
///   up to 4 mentions inside threads, to find the ones you haven't answered; `users.info` for names
///   (cached in memory). At most about 20 requests per workspace per refresh, only when asked.
/// - `xoxc` tokens are not an official Slack API credential: see docs/research/integrations-auth.md.
/// - `invalid_auth` / `not_authed` means the session ended: `connections.report {expired}`.
final class SlackCore {
  static let id = "slack"
  static let icon = "https://slack.com/favicon.ico"
  static let maxDMs = 6
  static let maxThreads = 4
  static let maxNames = 12

  /// Reads the signed-in workspaces from Slack's own web-client config.
  static let configScript = """
    const raw = localStorage.getItem('localConfig_v2');
    if (!raw) return [];
    let c; try { c = JSON.parse(raw); } catch (e) { return []; }
    const out = [];
    for (const k in (c.teams || {})) {
      const t = c.teams[k] || {};
      if (!t.token) continue;
      out.push({id: t.id || k, name: t.name || '', url: t.url || '', token: t.token, user: t.user_id || '',
                icon: (t.icon && (t.icon.image_68 || t.icon.image_44 || t.icon.image_34)) || ''});
    }
    const last = c.lastActiveTeamId;
    out.sort((a, b) => (b.id === last) - (a.id === last) || a.name.localeCompare(b.name));
    return out;
    """

  struct Team {
    var id: String
    var name: String
    var url: String
    var token: String
    var user: String
    var icon: String
  }

  let env: PluginEnv
  let requests: Requests
  var teams: [Team] = []  // in memory only (tokens)
  var names: [String: String] = [:]  // "<team>:<user>" -> display name
  var registerAttempts = 0
  var refreshing = false

  init(env: PluginEnv) {
    self.env = env
    requests = Requests(env: env, prefix: "slack")
  }

  /// Endpoints, overridable in storage ns `slack` key `endpoints` {api, origin, domain} (tests, mocks).
  var endpoints: Value { env.call("storage", "get", ["ns": "slack", "key": "endpoints"]) }
  var apiBase: String { endpoints.sOpt("api") ?? "https://slack.com/api/" }
  var origin: String { endpoints.sOpt("origin") ?? "https://app.slack.com" }
  var domain: String { endpoints.sOpt("domain") ?? "slack.com" }
  var signIn: String { endpoints.sOpt("signIn") ?? "https://slack.com/signin" }

  func start() {
    env.on("connections.probe") { [self] v in
      if v.s("id") == Self.id { probe(profile: v.sOpt("profile") ?? "default") { _ in } }
    }
    env.on("feed.refresh") { [self] _ in refresh() }
    register()
  }

  func register() {
    let r = env.call("connections", "register", ["id": .string(Self.id), "title": "Slack", "icon": .string(Self.icon),
                                                  "domain": "slack.com", "signIn": .string(signIn), "owner": .string(Self.id)])
    if r.isErr && registerAttempts < 60 {
      registerAttempts += 1
      env.timer(500, false) { [self] in register() }
    }
  }

  func connection() -> Value? {
    let c = env.call("connections", "get", ["id": .string(Self.id)])
    return c.b("connected") ? c : nil
  }

  // MARK: Probe

  /// Reads the `d` cookie and the workspaces; reports to `connections` and calls `done(found)`.
  func probe(profile: String, _ done: @escaping (Bool) -> Void) {
    requests.call("session", "cookies", ["plugin": .string(Self.id), "domain": .string(domain), "profile": .string(profile)]) { [self] r in
      guard r.a("cookies").contains(where: { $0.s("name") == "d" && !$0.s("value").isEmpty }) else {
        env.call("connections", "report", ["id": .string(Self.id), "connected": false, "profile": .string(profile)])
        return done(false)
      }
      requests.call("session", "eval", ["plugin": .string(Self.id), "origin": .string(origin), "script": .string(Self.configScript),
                                         "profile": .string(profile)]) { [self] r in
        teams = r["value"].array.map { list in
          list.map { Team(id: $0.s("id"), name: $0.s("name"), url: $0.s("url"), token: $0.s("token"), user: $0.s("user"), icon: $0.s("icon")) }
        } ?? []
        guard !teams.isEmpty else {
          env.call("connections", "report", ["id": .string(Self.id), "connected": false, "profile": .string(profile)])
          return done(false)
        }
        let account = teams[0].name  // connections adds "· N workspaces"
        let list: [Value] = teams.map { t in ["id": .string(t.id), "name": .string(t.name), "url": .string(t.url), "icon": .string(t.icon), "enabled": true] }
        env.call("connections", "report", ["id": .string(Self.id), "connected": true, "profile": .string(profile),
                                            "account": .string(account), "teams": .array(list)])
        done(true)
      }
    }
  }

  // MARK: Refresh

  func refresh() {
    guard let c = connection(), !refreshing else { return }
    refreshing = true
    let profile = c.sOpt("profile") ?? "default"
    let enabled = c.a("teams").filter { $0.b("enabled", true) }.map { $0.s("id") }
    let run = { [self] in
      var items: [Value] = []
      var errors: [String] = []
      var expired = false
      let steps: [(@escaping () -> Void) -> Void] = teams.filter { enabled.contains($0.id) }.map { t in
        { [self] next in
          fetchTeam(t, profile: profile) { found, error, gone in
            items += found
            if let error { errors.append(t.name + ": " + error) }
            if gone { expired = true }
            next()
          }
        }
      }
      sequence(steps) { [self] in
        refreshing = false
        if expired {
          teams = []
          env.call("connections", "report", ["id": .string(Self.id), "connected": false, "expired": true])
          env.emit("feed.items", ["source": .string(Self.id), "items": [], "error": "signed out"])
          return
        }
        var payload: Value = ["source": .string(Self.id), "items": .array(items), "account": c["account"]]
        if !errors.isEmpty { payload.put("error", .string(errors[0])) }
        env.emit("feed.items", payload)
      }
    }
    // Tokens live in memory only: after a relaunch, read them again from the session.
    if teams.isEmpty {
      probe(profile: profile) { [self] ok in
        if ok { run() } else {
          refreshing = false
          env.emit("feed.items", ["source": .string(Self.id), "items": [], "error": "signed out"])
        }
      }
    } else {
      run()
    }
  }

  func api(_ t: Team, _ method: String, _ params: [(String, String)], profile: String, _ done: @escaping (Value) -> Void) {
    let base = t.url.isEmpty ? apiBase : t.url + "api/"
    requests.call("net", "fetch", ["plugin": .string(Self.id), "url": .string(base + method), "method": "POST", "session": true,
                                    "profile": .string(profile), "as": "json",
                                    "headers": ["Content-Type": "application/x-www-form-urlencoded"],
                                    "body": .string(Web.form([("token", t.token)] + params))]) { r in
      if !r.b("ok") { return done(["ok": false, "error": .string(r.sOpt("error") ?? "network error")]) }
      if r.i("status") >= 400 && r["json"].isNull { return done(["ok": false, "error": .string("HTTP " + String(r.i("status")))]) }
      done(r["json"])
    }
  }

  static func authGone(_ v: Value) -> Bool {
    let e = v.s("error")
    return e == "invalid_auth" || e == "not_authed" || e == "account_inactive" || e == "token_revoked"
  }

  /// One workspace: unread DMs, mentions, threads awaiting a reply.
  func fetchTeam(_ t: Team, profile: String, _ done: @escaping ([Value], String?, Bool) -> Void) {
    var dms: [Value] = []  // {channel, last_read}
    var mentions: [Value] = []
    var items: [Value] = []
    var error: String?
    var gone = false
    let since = Web.date(env.now() - 2 * 86_400_000)
    let steps: [(@escaping () -> Void) -> Void] = [
      { [self] next in
        api(t, "client.counts", [], profile: profile) { r in
          if Self.authGone(r) { gone = true } else if !r.b("ok") { error = r.sOpt("error") }
          for im in r.a("ims") + r.a("mpims") where im.b("has_unreads") || im.i("mention_count") > 0 {
            if dms.count < Self.maxDMs { dms.append(im) }
          }
          next()
        }
      },
      { [self] next in
        guard !gone else { return next() }
        api(t, "search.messages", [("query", "<@" + t.user + "> after:" + since), ("sort", "timestamp"), ("sort_dir", "desc"), ("count", "20")], profile: profile) { r in
          if Self.authGone(r) { gone = true } else if !r.b("ok") { error = error ?? r.sOpt("error") }
          mentions = r["messages"].a("matches").filter { !$0["channel"].b("is_im") && $0.s("user") != t.user }
          next()
        }
      },
    ]
    sequence(steps) { [self] in
      guard !gone else { return done([], nil, true) }
      // Unread DMs: the newest messages from the other side, after what you last read.
      let dmSteps: [(@escaping () -> Void) -> Void] = dms.map { im in
        { [self] next in
          api(t, "conversations.history", [("channel", im.s("id")), ("limit", "5")], profile: profile) { r in
            let lastRead = Web.slackMs(im.s("last_read"))
            let fromThem = r.a("messages").filter { $0.s("user") != t.user && !$0.s("user").isEmpty && $0["subtype"].isNull }
            let unread = fromThem.filter { lastRead == 0 || Web.slackMs($0.s("ts")) > lastRead }
            if let m = (unread.isEmpty ? fromThem : unread).first {
              items.append(["pending": "dm", "team": .string(t.id), "channel": .string(im.s("id")), "message": m,
                            "count": .int(Int64(max(1, unread.count)))])
            }
            next()
          }
        }
      }
      // Mentions inside threads: awaiting a reply unless you answered after the mention.
      var threadChecks = 0
      let threadSteps: [(@escaping () -> Void) -> Void] = mentions.map { m in
        { [self] next in
          let threadTs = Web.query(m.s("permalink"), "thread_ts")
          guard !threadTs.isEmpty, threadChecks < Self.maxThreads else {
            items.append(["pending": "mention", "team": .string(t.id), "message": m])
            return next()
          }
          threadChecks += 1
          api(t, "conversations.replies", [("channel", m["channel"].s("id")), ("ts", threadTs), ("oldest", m.s("ts")), ("limit", "50")], profile: profile) { r in
            let answered = r.a("messages").contains { $0.s("user") == t.user && Web.slackMs($0.s("ts")) > Web.slackMs(m.s("ts")) }
            items.append(["pending": .string(answered ? "mention" : "thread"), "team": .string(t.id), "message": m])
            next()
          }
        }
      }
      sequence(dmSteps + threadSteps) { [self] in
        resolveNames(t, items, profile: profile) { [self] in
          done(items.map { build($0, t) }, error, false)
        }
      }
    }
  }

  /// `users.info` for authors not seen yet (cached in memory, capped per refresh).
  func resolveNames(_ t: Team, _ raw: [Value], profile: String, _ done: @escaping () -> Void) {
    var want: [String] = []
    for r in raw {
      let u = r["message"].s("user")
      let key = t.id + ":" + u
      if !u.isEmpty, names[key] == nil, !want.contains(u), r["message"]["username"].isNull || r.s("pending") == "dm" { want.append(u) }
      // Search results carry `username`; use it directly.
      if let n = r["message"].sOpt("username"), names[key] == nil { names[key] = n }
    }
    let steps: [(@escaping () -> Void) -> Void] = want.prefix(Self.maxNames).filter { names[t.id + ":" + $0] == nil }.map { u in
      { [self] next in
        api(t, "users.info", [("user", u)], profile: profile) { [self] r in
          let p = r["user"]["profile"]
          let n = p.sOpt("display_name") ?? p.sOpt("real_name") ?? r["user"].sOpt("real_name") ?? r["user"].sOpt("name")
          if let n { names[t.id + ":" + u] = n }
          next()
        }
      }
    }
    sequence(steps, done)
  }

  func name(_ t: Team, _ user: String) -> String { names[t.id + ":" + user] ?? "Someone" }

  /// Slack mrkdwn -> plain text: <@U1> -> @name, <#C1|general> -> #general, <url|label> -> label.
  func plain(_ text: String, _ t: Team) -> String {
    var out: [UInt8] = []
    let b = Array(text.utf8)
    var i = 0
    while i < b.count {
      if b[i] == 60, let end = b[i...].firstIndex(of: 62) {  // < … >
        let inner = String(decoding: b[(i + 1)..<end], as: UTF8.self)
        let parts = Array(inner.utf8)
        let bar = parts.firstIndex(of: 124)  // |
        let label = bar.map { String(decoding: parts[($0 + 1)...], as: UTF8.self) }
        let target = String(decoding: parts[..<(bar ?? parts.count)], as: UTF8.self)
        var rendered: String
        if target == "@" + t.user {
          rendered = "@you"
        } else if Text.hasPrefix(target, "@") {
          rendered = "@" + (label ?? name(t, Text.dropPrefix(target, "@")))
        } else if Text.hasPrefix(target, "#") {
          rendered = "#" + (label ?? "channel")
        } else if Text.hasPrefix(target, "!") {
          rendered = "@" + (label ?? Text.dropPrefix(target, "!"))
        } else {
          rendered = label ?? target
        }
        out += Array(rendered.utf8)
        i = end + 1
        continue
      }
      out.append(b[i])
      i += 1
    }
    return Web.oneLine(Web.plain(String(decoding: out, as: UTF8.self)), max: 200)
  }

  /// `https://acme.slack.com/archives/C1/p1700000000123456` for a message without a permalink.
  static func permalink(_ team: Team, channel: String, ts: String) -> String {
    var digits: [UInt8] = []
    for c in ts.utf8 where c != 46 { digits.append(c) }
    let base = team.url.isEmpty ? "https://app.slack.com/" : team.url
    return base + "archives/" + channel + "/p" + String(decoding: digits, as: UTF8.self)
  }

  func build(_ r: Value, _ t: Team) -> Value {
    let m = r["message"]
    let kind = r.s("pending")
    let who = m.sOpt("username").flatMap { $0.isEmpty ? nil : $0 } ?? name(t, m.s("user"))
    let text = plain(m.s("text"), t)
    let channelName = m["channel"].sOpt("name") ?? ""
    let where_ = kind == "dm" ? "DM" : "#" + channelName
    let url = m.sOpt("permalink") ?? Self.permalink(t, channel: r.sOpt("channel") ?? m["channel"].s("id"), ts: m.s("ts"))
    var detail: String
    let badge: String
    let summary: String
    switch kind {
    case "dm":
      let n = r.i("count", 1)
      detail = "DM from " + who + (n > 1 ? " · " + String(n) + " unread" : "")
      badge = "DM"
      summary = who + " sent you a direct message: " + text
    case "thread":
      detail = who + " in " + where_ + " · waiting for your reply"
      badge = "Reply"
      summary = who + " is waiting for your reply in a thread in " + where_ + ": " + text
    default:
      detail = who + " in " + where_
      badge = "Mention"
      summary = who + " mentioned you in " + where_ + ": " + text
    }
    if teams.count > 1 { detail += " · " + t.name }
    return [
      "id": .string("slack:" + t.id + ":" + (r.sOpt("channel") ?? m["channel"].s("id")) + ":" + m.s("ts")),
      "source": .string(Self.id), "kind": .string(kind), "title": .string(text.isEmpty ? "(no text)" : text),
      "detail": .string(detail), "url": .string(url), "ts": .int(Web.slackMs(m.s("ts"))), "icon": .string(Self.icon),
      "badge": .string(badge), "actor": .string(who), "where": .string(t.name + " " + where_),
      "actionable": true, "summary": .string(summary),
    ]
  }
}
