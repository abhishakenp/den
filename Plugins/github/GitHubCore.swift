#if !hasFeature(Embedded)
  import CordisValue
#endif

/// GitHub through the github.com session the user signed in to in den (no OAuth app, no token).
///
/// - **Connected** when the profile has github.com's `logged_in=yes` cookie; the account is the
///   `dotcom_user` cookie.
/// - **Data** comes from github.com's own search page, which returns JSON to
///   `Accept: application/json` (the shape its React UI uses: `payload.blackbirdSearchRoute.results`,
///   with `logged_in`). One endpoint and GitHub's documented search qualifiers cover everything:
///   review requests (`review-requested:@me`), failing CI on your PRs (`author:@me status:failure`),
///   assigned issues (`assignee:@me`) and mentions (`mentions:@me`). That's 4 requests a refresh.
///   Why not the notifications page: it is HTML only, and parsing it is far more brittle than a
///   JSON payload whose search syntax is documented. `api.github.com` doesn't accept the web
///   session at all.
/// - If a response says `logged_in: false`, the session ended: `connections.report {expired}`.
final class GitHubCore {
  static let id = "github"
  static let icon = "https://github.com/favicon.ico"

  struct Query {
    var kind: String
    var type: String  // pullrequests | issues
    var q: String
  }

  static let queries: [Query] = [
    Query(kind: "review", type: "pullrequests", q: "is:open is:pr review-requested:@me archived:false"),
    Query(kind: "ci", type: "pullrequests", q: "is:open is:pr author:@me status:failure archived:false"),
    Query(kind: "assigned", type: "issues", q: "is:open is:issue assignee:@me archived:false"),
    Query(kind: "mention", type: "issues", q: "is:open mentions:@me archived:false sort:updated-desc"),
  ]
  /// Higher wins when one issue or PR matches several queries.
  static func rank(_ kind: String) -> Int {
    switch kind {
    case "review": return 4
    case "ci": return 3
    case "mention": return 2
    default: return 1
    }
  }

  let env: PluginEnv
  let requests: Requests
  var registerAttempts = 0
  var registered = false
  var refreshing = false

  init(env: PluginEnv) {
    self.env = env
    requests = Requests(env: env, prefix: "github")
  }

  /// `https://github.com` unless storage ns `github` key `base` says otherwise (tests, mocks).
  var base: String { env.call("storage", "get", ["ns": "github", "key": "base"]).string ?? "https://github.com" }
  var cookieDomain: String { URLs.host(base) }

  func start() {
    env.on("connections.probe") { [self] v in
      if v.s("id") == Self.id { probe(profile: v.sOpt("profile") ?? "default") }
    }
    env.on("feed.refresh") { [self] _ in refresh() }
    register()
  }

  /// `connections` is optional and may load later: retried every 500 ms for 30 s.
  func register() {
    let r = env.call("connections", "register", ["id": .string(Self.id), "title": "GitHub", "icon": .string(Self.icon),
                                                  "domain": "github.com", "signIn": .string(base + "/login"), "owner": .string(Self.id)])
    registered = !r.isErr
    if !registered && registerAttempts < 60 {
      registerAttempts += 1
      env.timer(500, false) { [self] in register() }
    }
  }

  func connection() -> Value? {
    let c = env.call("connections", "get", ["id": .string(Self.id)])
    return c.b("connected") ? c : nil
  }

  // MARK: Probe

  func probe(profile: String) {
    requests.call("session", "cookies", ["plugin": .string(Self.id), "domain": .string(cookieDomain), "profile": .string(profile)]) { [self] r in
      let cookies = r.a("cookies")
      let loggedIn = cookies.contains { $0.s("name") == "logged_in" && $0.s("value") == "yes" }
      let user = cookies.first { $0.s("name") == "dotcom_user" }?.s("value") ?? ""
      if loggedIn {
        env.call("connections", "report", ["id": .string(Self.id), "connected": true, "profile": .string(profile),
                                            "account": .string(user.isEmpty ? "" : "@" + user)])
      } else {
        env.call("connections", "report", ["id": .string(Self.id), "connected": false, "profile": .string(profile)])
      }
    }
  }

  // MARK: Refresh

  func refresh() {
    guard let c = connection() else { return }
    guard !refreshing else { return }
    refreshing = true
    let profile = c.sOpt("profile") ?? "default"
    var byKey: [String: Value] = [:]
    var order: [String] = []
    var error: String?
    var expired = false
    let steps: [(@escaping () -> Void) -> Void] = Self.queries.map { q in
      { [self] next in
        let url = base + "/search?q=" + Web.encode(q.q) + "&type=" + q.type
        requests.call("net", "fetch", ["plugin": .string(Self.id), "url": .string(url), "session": true, "profile": .string(profile), "as": "json",
                                        "headers": ["Accept": "application/json", "X-Requested-With": "XMLHttpRequest"]]) { [self] r in
          let route = r["json"]["payload"]["blackbirdSearchRoute"]
          if !r.b("ok") || r.i("status") >= 400 || route.isNull {
            error = r.sOpt("error") ?? ("GitHub search returned " + String(r.i("status")))
          } else if route["logged_in"].bool == false {
            expired = true
          } else {
            for item in Self.parse(route, kind: q.kind, base: base) {
              let key = item.s("key")
              if let old = byKey[key] {
                if Self.rank(q.kind) > Self.rank(old.s("kind")) { byKey[key] = item }
              } else {
                byKey[key] = item
                order.append(key)
              }
            }
          }
          next()
        }
      }
    }
    sequence(steps) { [self] in
      refreshing = false
      if expired {
        env.call("connections", "report", ["id": .string(Self.id), "connected": false, "expired": true])
        env.emit("feed.items", ["source": .string(Self.id), "items": [], "error": "signed out"])
        return
      }
      var payload: Value = ["source": .string(Self.id), "items": .array(order.compactMap { byKey[$0] }), "account": c["account"]]
      if let error { payload.put("error", .string(error)) }
      env.emit("feed.items", payload)
    }
  }

  /// Search results -> feed items (see docs/plugin-services.md for the item shape).
  static func parse(_ route: Value, kind: String, base: String) -> [Value] {
    var out: [Value] = []
    for r in route.a("results") {
      let repo = r["repo"]["repository"]
      let owner = repo.s("owner_login"), name = repo.s("name")
      let number = r.i("number")
      guard !owner.isEmpty, !name.isEmpty, number > 0 else { continue }
      let isPR = !r["issue"]["issue"]["pull_request_id"].isNull
      let full = owner + "/" + name
      let url = base + "/" + full + (isPR ? "/pull/" : "/issues/") + String(number)
      let title = Web.oneLine(Web.plain(r.s("hl_title")), max: 160)
      let author = r.s("author_name")
      var detail = full + " #" + String(number)
      if !author.isEmpty { detail += " · " + author }
      let badge: String
      switch kind {
      case "review": badge = "Review"
      case "ci": badge = "CI failed"
      case "assigned": badge = "Assigned"
      default: badge = "Mention"
      }
      let summary: String
      switch kind {
      case "review": summary = author + " requested your review on " + full + " #" + String(number) + ": " + title
      case "ci": summary = "CI is failing on your PR " + full + " #" + String(number) + ": " + title
      case "assigned": summary = "Issue assigned to you in " + full + " #" + String(number) + ": " + title
      default: summary = author + " mentioned you in " + full + " #" + String(number) + ": " + title
      }
      out.append([
        "id": .string("github:" + full + "#" + String(number)), "key": .string(full + "#" + String(number)),
        "source": .string(id), "kind": .string(kind), "title": .string(title.isEmpty ? full + " #" + String(number) : title),
        "detail": .string(detail), "url": .string(url), "ts": .int(Web.isoMs(r.s("created"))), "icon": .string(icon),
        "badge": .string(badge), "actor": .string(author), "where": .string(full), "actionable": true, "summary": .string(summary),
      ])
    }
    return out
  }
}
