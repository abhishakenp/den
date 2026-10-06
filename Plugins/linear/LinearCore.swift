#if !hasFeature(Embedded)
  import CordisValue
#endif

/// Linear through the linear.app session the user signed in to in den (no OAuth app, no API key).
///
/// - **Connected** when the profile has any linear.app cookie and the GraphQL endpoint answers
///   `viewer`. A signed-out linear.app sets no cookies at all (no Set-Cookie on GET / or /login,
///   checked 2026-10-06), so a cookie is worth probing; the viewer query is the verdict.
/// - **Data**: one GraphQL POST per refresh to https://api.linear.app/graphql, the endpoint the
///   web app itself uses with the session: the viewer's open assigned issues (state not completed
///   or canceled, newest update first). Each becomes an `assigned` feed item. Linear's official
///   credentials are API keys and OAuth (docs/research/integrations-auth.md §6); the web session
///   answering the same endpoint is the reuse gap — UNVERIFIED, exercised only against
///   MockServices.
/// - Unauthenticated answers 401 with `errors[].extensions.code == "AUTHENTICATION_ERROR"`
///   (checked 2026-10-06): the session ended — `connections.report {expired}`.
final class LinearCore {
  static let id = "linear"
  static let icon = "https://linear.app/favicon.ico"
  static let maxIssues = 25
  /// The probe and the refresh query (kept apart so the probe stays small).
  static let viewerQuery = "{ viewer { id name displayName email } }"
  static let issuesQuery = "{ viewer { assignedIssues(filter: { state: { type: { nin: [\"completed\", \"canceled\"] } } }, first: 25, orderBy: updatedAt) { nodes { id identifier title url updatedAt state { name } creator { displayName } team { key name } } } } }"

  let env: PluginEnv
  let requests: Requests
  var registerAttempts = 0
  var refreshing = false
  /// Fingerprint of the cookie set the last automatic probe found no session with: the same
  /// signed-out cookie set isn't probed twice (every page load on the site is a cookie change).
  var failedCookies = ""

  init(env: PluginEnv) {
    self.env = env
    requests = Requests(env: env, prefix: "linear")
  }

  /// Endpoints, overridable in storage ns `linear` key `endpoints` {api, web, domain, signIn} (tests, mocks).
  var endpoints: Value { env.call("storage", "get", ["ns": "linear", "key": "endpoints"]) }
  var api: String { endpoints.sOpt("api") ?? "https://api.linear.app/graphql" }
  var web: String { endpoints.sOpt("web") ?? "https://linear.app" }
  var domain: String { endpoints.sOpt("domain") ?? "linear.app" }
  var signIn: String { endpoints.sOpt("signIn") ?? "https://linear.app/login" }

  func start() {
    env.on("connections.probe") { [self] v in
      if v.s("id") == Self.id { probe(profile: v.sOpt("profile") ?? "default", auto: false) }
    }
    env.on("feed.refresh") { [self] _ in refresh() }
    // Auto-connect: signing in to Linear in den (now or later) connects it. The host observes the
    // cookie store and tells us when linear.app's cookies change; nothing polls.
    env.on("session.cookiesChanged") { [self] v in
      if v.s("domain") == domain { autoProbe(v.sOpt("profile") ?? "default") }
    }
    register()
    env.call("session", "watchCookies", ["plugin": .string(Self.id), "domain": .string(domain), "profile": "default"])
    autoProbe("default")
  }

  /// `connections` is optional and may load later: retried every 500 ms for 30 s.
  func register() {
    let r = env.call("connections", "register", ["id": .string(Self.id), "title": "Linear", "icon": .string(Self.icon),
                                                  "domain": "linear.app", "signIn": .string(signIn), "owner": .string(Self.id),
                                                  "order": 60, "important": true])
    if r.isErr && registerAttempts < 60 {
      registerAttempts += 1
      env.timer(500, false) { [self] in register() }
    }
  }

  func connection() -> Value? {
    let c = env.call("connections", "get", ["id": .string(Self.id)])
    // Not a bare `nil`: Value is ExpressibleByNilLiteral, so it became Optional(.null) and a
    // disconnected provider still looked connected to `guard let c = connection()`.
    return c.b("connected") ? c : Optional<Value>.none
  }

  /// Sorted `name=value` per cookie (the same fingerprint the host's session service computes).
  static func fingerprint(_ cookies: [Value]) -> String {
    cookies.map { $0.s("name") + "=" + $0.s("value") }.sorted().joined(separator: "\n")
  }

  /// A probe nobody asked for (launch, a cookie change). While connected only sign-out matters,
  /// so it's a cookie read, no request to Linear.
  func autoProbe(_ profile: String) {
    let c = env.call("connections", "get", ["id": .string(Self.id)])
    if c.b("declined") { return }
    requests.call("session", "cookies", ["plugin": .string(Self.id), "domain": .string(domain), "profile": .string(profile)]) { [self] r in
      let cookies = r.a("cookies")
      if c.b("connected") {
        guard (c.sOpt("profile") ?? "default") == profile, cookies.isEmpty else { return }
        env.call("connections", "report", ["id": .string(Self.id), "connected": false, "profile": .string(profile), "auto": true])
        return
      }
      guard !cookies.isEmpty, Self.fingerprint(cookies) != failedCookies else { return }
      probe(profile: profile, auto: true, cookies: cookies)
    }
  }

  // MARK: Probe

  func probe(profile: String, auto: Bool, cookies known: [Value]? = nil) {
    let check: (@escaping ([Value]) -> Void) -> Void = { [self] next in
      if let known { return next(known) }
      requests.call("session", "cookies", ["plugin": .string(Self.id), "domain": .string(domain), "profile": .string(profile)]) { r in
        next(r.a("cookies"))
      }
    }
    check { [self] cookies in
      guard !cookies.isEmpty else { return report(false, profile: profile, auto: auto) }
      graphql(Self.viewerQuery, profile: profile) { [self] r, _ in
        let v = r["data"]["viewer"]
        guard !v.isNull, !v.s("id").isEmpty else {
          if auto { failedCookies = Self.fingerprint(cookies) }
          return report(false, profile: profile, auto: auto)
        }
        failedCookies = ""
        env.call("connections", "report", ["id": .string(Self.id), "connected": true, "profile": .string(profile),
                                            "account": .string(Self.account(v)), "auto": .bool(auto)])
      }
    }
  }

  func report(_ connected: Bool, profile: String, auto: Bool) {
    env.call("connections", "report", ["id": .string(Self.id), "connected": .bool(connected), "profile": .string(profile), "auto": .bool(auto)])
  }

  /// "Riley" (displayName), else the full name, else the email.
  static func account(_ viewer: Value) -> String {
    for k in ["displayName", "name", "email"] {
      if let s = viewer.sOpt(k), !s.isEmpty { return s }
    }
    return ""
  }

  /// POST `api` with a GraphQL query and the session's cookies. `done(json, status)`; status 0
  /// means a network error. A 401 carries the error JSON (Linear answers it with one).
  func graphql(_ query: String, profile: String, _ done: @escaping (Value, Int64) -> Void) {
    requests.call("net", "fetch", ["plugin": .string(Self.id), "url": .string(api), "method": "POST", "session": true,
                                    "profile": .string(profile), "as": "json",
                                    "headers": ["Content-Type": "application/json", "Accept": "application/json"],
                                    "body": .string(Web.json(["query": .string(query)]))]) { r in
      done(r.b("ok") ? r["json"] : .null, r.b("ok") ? r.i("status") : 0)
    }
  }

  /// The session ended: HTTP 401/403, or the GraphQL authentication error.
  static func authGone(_ r: Value, _ status: Int64) -> Bool {
    if status == 401 || status == 403 { return true }
    return r.a("errors").contains { $0["extensions"].s("code") == "AUTHENTICATION_ERROR" }
  }

  // MARK: Refresh

  func refresh() {
    guard let c = connection(), !refreshing else { return }
    refreshing = true
    let profile = c.sOpt("profile") ?? "default"
    graphql(Self.issuesQuery, profile: profile) { [self] r, status in
      refreshing = false
      if Self.authGone(r, status) {
        env.call("connections", "report", ["id": .string(Self.id), "connected": false, "expired": true])
        env.emit("feed.items", ["source": .string(Self.id), "items": [], "error": "signed out"])
        return
      }
      let list = r["data"]["viewer"]["assignedIssues"]
      if status == 0 || status >= 400 || list.isNull {
        let error = status == 0 ? "network error" : status >= 400 ? "Linear returned " + String(status) : "Linear answered without issues"
        env.emit("feed.items", ["source": .string(Self.id), "items": [], "error": .string(error)])
        return
      }
      env.emit("feed.items", ["source": .string(Self.id), "items": .array(list.a("nodes").map { Self.item($0) }), "account": c["account"]])
    }
  }

  /// One assigned issue -> an `assigned` feed item (see docs/plugin-services.md for the shape).
  static func item(_ n: Value) -> Value {
    let identifier = n.s("identifier")  // "ENG-123"
    let title = n.s("title")
    let state = n["state"].s("name")
    let creator = n["creator"].s("displayName")
    let team = n["team"].s("key"), teamName = n["team"].s("name")
    var detail = identifier
    if !teamName.isEmpty { detail += " · " + teamName }
    if !state.isEmpty { detail += " · " + state }
    if !creator.isEmpty { detail += " · from " + creator }
    return [
      "id": .string("linear:" + (n.s("id").isEmpty ? identifier : n.s("id"))), "source": .string(id), "kind": "assigned",
      "title": .string(title.isEmpty ? identifier : title), "detail": .string(detail), "url": .string(n.s("url")),
      "ts": .int(Web.isoMs(n.s("updatedAt"))), "icon": .string(icon), "badge": "Assigned",
      "actor": .string(creator), "where": .string(teamName.isEmpty ? "Linear" : teamName), "actionable": true,
      "summary": .string("Linear issue assigned to you, " + identifier + (title.isEmpty ? "" : ": " + title)),
      // A team the user can mark important (briefing).
      "importantKey": .string("linear:" + (team.isEmpty ? "issues" : team)),
      "importantTitle": .string(teamName.isEmpty ? "Linear issues" : teamName + (team.isEmpty ? "" : " (" + team + ")")),
    ]
  }
}
