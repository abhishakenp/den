#if !hasFeature(Embedded)
  import CordisValue
#endif

/// Jira Cloud through the Atlassian session the user signed in to in den (no OAuth app, no API token).
///
/// - **Connected** when a `cloud.session.token` cookie (the Atlassian Cloud web-session cookie;
///   the name is observed in browser sessions, not officially documented — UNVERIFIED) covers a
///   Jira site and that site's `GET /rest/api/3/myself` answers. The tenant host comes from the
///   cookie's own domain. Sites are the connection's `teams`, each switchable in Settings.
/// - **Data**: the documented Jira Cloud REST search, as the site's own web app calls it with the
///   session (cookie auth on Cloud REST isn't an official credential — the reuse gap,
///   docs/research/integrations-auth.md §7): `GET /rest/api/3/search?jql=assignee = currentUser()
///   AND resolution = Unresolved ORDER BY updated DESC`, per enabled site and refresh. Each issue
///   becomes an `assigned` feed item.
/// - A 401/403, or the sign-in redirect an unauthenticated call gets instead (302, checked
///   2026-10-06), means the session ended: `connections.report {expired}`.
final class JiraCore {
  static let id = "jira"
  static let icon = "https://www.atlassian.net/favicon.ico"
  static let sessionCookie = "cloud.session.token"
  static let maxIssues = 25

  struct Site {
    var host: String  // "acme.atlassian.net" (the session cookie's host)
    var base: String  // "https://acme.atlassian.net"
    var account: String  // displayName from myself
  }

  let env: PluginEnv
  let requests: Requests
  var sites: [Site] = []  // in memory only
  var registerAttempts = 0
  var refreshing = false
  /// Fingerprint of the cookie set the last automatic probe found no session with: the same
  /// signed-out cookie set isn't probed twice (every page load on the site is a cookie change).
  var failedCookies = ""

  init(env: PluginEnv) {
    self.env = env
    requests = Requests(env: env, prefix: "jira")
  }

  /// Endpoints, overridable in storage ns `jira` key `endpoints` {domain, signIn, origin} (tests,
  /// mocks). `origin` replaces the per-site base URL derivation with one fixed base.
  var endpoints: Value { env.call("storage", "get", ["ns": "jira", "key": "endpoints"]) }
  var domain: String { endpoints.sOpt("domain") ?? "atlassian.net" }
  var signIn: String { endpoints.sOpt("signIn") ?? "https://id.atlassian.com/login" }

  func start() {
    env.on("connections.probe") { [self] v in
      if v.s("id") == Self.id { probe(profile: v.sOpt("profile") ?? "default", auto: false) }
    }
    env.on("feed.refresh") { [self] _ in refresh() }
    // Auto-connect: signing in to Jira in den (now or later) connects it. The host observes the
    // cookie store and tells us when atlassian.net's cookies change; nothing polls.
    env.on("session.cookiesChanged") { [self] v in
      if v.s("domain") == domain { autoProbe(v.sOpt("profile") ?? "default") }
    }
    register()
    env.call("session", "watchCookies", ["plugin": .string(Self.id), "domain": .string(domain), "profile": "default"])
    autoProbe("default")
  }

  /// `connections` is optional and may load later: retried every 500 ms for 30 s.
  func register() {
    let r = env.call("connections", "register", ["id": .string(Self.id), "title": "Jira", "icon": .string(Self.icon),
                                                  "domain": "atlassian.net", "signIn": .string(signIn), "owner": .string(Self.id),
                                                  "unit": "sites", "order": 70, "important": true])
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

  /// The tenant hosts with a session cookie (each cookie's own domain, minus a leading dot). A
  /// cookie set on ".atlassian.net" itself yields "atlassian.net": its `myself` doesn't answer,
  /// so the probe drops it.
  static func siteHosts(_ cookies: [Value]) -> [String] {
    var hosts: [String] = []
    for c in cookies where c.s("name") == Self.sessionCookie && !c.s("value").isEmpty {
      var h = c.s("domain")
      if Text.hasPrefix(h, ".") { h = Text.dropPrefix(h, ".") }
      if !h.isEmpty && !hosts.contains(h) { hosts.append(h) }
    }
    return hosts.sorted()
  }

  /// "acme" for "acme.atlassian.net", else the host itself.
  static func siteName(_ host: String) -> String {
    let suffix = ".atlassian.net"
    if Text.hasSuffix(host, suffix) { return String(host.prefix(host.count - suffix.count)) }
    return host
  }

  /// "https://<host>", or the `origin` override for every site (tests, mocks, one self-hosted site).
  func base(_ host: String) -> String { endpoints.sOpt("origin") ?? "https://" + host }

  /// A probe nobody asked for (launch, a cookie change). While connected only sign-out matters,
  /// so it's a cookie read, no request to Jira.
  func autoProbe(_ profile: String) {
    let c = env.call("connections", "get", ["id": .string(Self.id)])
    if c.b("declined") { return }
    requests.call("session", "cookies", ["plugin": .string(Self.id), "domain": .string(domain), "profile": .string(profile)]) { [self] r in
      let cookies = r.a("cookies")
      if c.b("connected") {
        guard (c.sOpt("profile") ?? "default") == profile, Self.siteHosts(cookies).isEmpty else { return }
        sites = []
        env.call("connections", "report", ["id": .string(Self.id), "connected": false, "profile": .string(profile), "auto": true])
        return
      }
      guard !Self.siteHosts(cookies).isEmpty, Self.fingerprint(cookies) != failedCookies else { return }
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
      let hosts = Self.siteHosts(cookies)
      guard !hosts.isEmpty else { return report(false, profile: profile, auto: auto) }
      myselves(hosts, profile: profile) { [self] found, _ in
        sites = found
        guard !found.isEmpty else {
          if auto { failedCookies = Self.fingerprint(cookies) }
          return report(false, profile: profile, auto: auto)
        }
        failedCookies = ""
        let teams: [Value] = found.map { s in
          ["id": .string(s.host), "name": .string(Self.siteName(s.host)), "url": .string(s.base), "icon": .string(Self.icon), "enabled": true]
        }
        env.call("connections", "report", ["id": .string(Self.id), "connected": true, "profile": .string(profile),
                                            "account": .string(found[0].account), "teams": .array(teams), "auto": .bool(auto)])
      }
    }
  }

  func report(_ connected: Bool, profile: String, auto: Bool) {
    env.call("connections", "report", ["id": .string(Self.id), "connected": .bool(connected), "profile": .string(profile), "auto": .bool(auto)])
  }

  /// `myself` per candidate host: the sites with a live session. `expired` when every candidate
  /// said the session is gone.
  func myselves(_ hosts: [String], profile: String, _ done: @escaping ([Site], Bool) -> Void) {
    var found: [Site] = []
    var expired = true
    let steps: [(@escaping () -> Void) -> Void] = hosts.map { h in
      { [self] next in
        get(base(h) + "/rest/api/3/myself", profile: profile) { [self] r, status in
          if !Self.authGone(status) { expired = false }
          if status == 200, !r.s("accountId").isEmpty {
            found.append(Site(host: h, base: base(h), account: r.sOpt("displayName") ?? r.s("emailAddress")))
          }
          next()
        }
      }
    }
    sequence(steps) { done(found, expired) }
  }

  /// The sites with a live session (after a relaunch `sites` is empty: read them again).
  func findSites(profile: String, _ done: @escaping ([Site], Bool) -> Void) {
    requests.call("session", "cookies", ["plugin": .string(Self.id), "domain": .string(domain), "profile": .string(profile)]) { [self] r in
      let hosts = Self.siteHosts(r.a("cookies"))
      guard !hosts.isEmpty else { return done([], true) }
      myselves(hosts, profile: profile, done)
    }
  }

  /// GET a Jira REST endpoint with the session's cookies. `done(json, status)`; status 0 means a
  /// network error. Redirects off the site aren't followed (the host's `net` never follows them),
  /// so a signed-out call comes back 302.
  func get(_ url: String, profile: String, _ done: @escaping (Value, Int64) -> Void) {
    requests.call("net", "fetch", ["plugin": .string(Self.id), "url": .string(url), "session": true, "profile": .string(profile),
                                    "as": "json", "headers": ["Accept": "application/json"]]) { r in
      done(r.b("ok") ? r["json"] : .null, r.b("ok") ? r.i("status") : 0)
    }
  }

  /// The session ended: 401/403, or the redirect to the identity sign-in (302).
  static func authGone(_ status: Int64) -> Bool { status == 401 || status == 403 || status == 302 }

  /// The documented Jira Cloud search the site's web app uses: your unresolved assigned issues.
  static func searchURL(_ base: String) -> String {
    base + "/rest/api/3/search?jql=" + Web.encode("assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC") +
      "&maxResults=" + String(Self.maxIssues) + "&fields=summary,status,issuetype,priority,updated,reporter,project"
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
      let multi = sites.count > 1
      let steps: [(@escaping () -> Void) -> Void] = sites.filter { enabled.contains($0.host) }.map { s in
        { [self] next in
          get(Self.searchURL(s.base), profile: profile) { r, status in
            if Self.authGone(status) {
              expired = true
            } else if status == 0 || status >= 400 || r["issues"].isNull {
              error = error ?? (status == 0 ? "network error" : "Jira returned " + String(status))
            } else {
              items += r.a("issues").map { Self.item($0, site: s, multi: multi) }
            }
            next()
          }
        }
      }
      sequence(steps) { [self] in
        refreshing = false
        if expired {
          sites = []
          env.call("connections", "report", ["id": .string(Self.id), "connected": false, "expired": true])
          env.emit("feed.items", ["source": .string(Self.id), "items": [], "error": "signed out"])
          return
        }
        var payload: Value = ["source": .string(Self.id), "items": .array(items), "account": c["account"]]
        if let error { payload.put("error", .string(error)) }
        env.emit("feed.items", payload)
      }
    }
    if sites.isEmpty {
      findSites(profile: profile) { [self] found, expired in
        sites = found
        if found.isEmpty {
          refreshing = false
          if expired { env.call("connections", "report", ["id": .string(Self.id), "connected": false, "expired": true]) }
          env.emit("feed.items", ["source": .string(Self.id), "items": [], "error": .string(expired ? "signed out" : "couldn't reach Jira")])
        } else {
          run()
        }
      }
    } else {
      run()
    }
  }

  /// One search-result issue -> an `assigned` feed item (see docs/plugin-services.md for the shape).
  static func item(_ issue: Value, site: Site, multi: Bool) -> Value {
    let key = issue.s("key")  // "ENG-101"
    let f = issue["fields"]
    let title = f.s("summary")
    let project = f["project"].s("key"), projectName = f["project"].s("name")
    let status = f["status"].s("name")
    let reporter = f["reporter"].s("displayName")
    var detail = key
    if !projectName.isEmpty { detail += " · " + projectName }
    if !status.isEmpty { detail += " · " + status }
    if !reporter.isEmpty { detail += " · from " + reporter }
    if multi { detail += " · " + site.host }
    return [
      "id": .string("jira:" + site.host + ":" + key), "source": .string(id), "kind": "assigned",
      "title": .string(title.isEmpty ? key : title), "detail": .string(detail),
      "url": .string(site.base + "/browse/" + key), "ts": .int(Web.isoMs(f.s("updated"))), "icon": .string(icon),
      "badge": "Assigned", "actor": .string(reporter), "where": .string(projectName.isEmpty ? "Jira" : projectName),
      "actionable": true,
      "summary": .string("Jira issue assigned to you, " + key + (title.isEmpty ? "" : ": " + title)),
      // A project the user can mark important (briefing): keyed by site, so ENG in two sites stays two choices.
      "importantKey": .string("jira:" + site.host + ":" + (project.isEmpty ? key : project)),
      "importantTitle": .string((projectName.isEmpty ? project : projectName) + (multi ? " · " + site.host : "")),
    ]
  }
}
