#if !hasFeature(Embedded)
  import CordisValue
#endif

/// Confluence Cloud through the Atlassian session the user signed in to in den (no API token, no OAuth).
///
/// - **Connected** when the `cloud.session.token` cookie (the same cookie Jira reuses; the name is
///   observed in browser sessions, not officially documented — UNVERIFIED) covers a Confluence site
///   and that site's `GET /rest/api/space` answers. The tenant host comes from the cookie's own
///   domain. Sites are the connection's `teams`, each switchable in Settings.
/// - **Data**: the documented Confluence Cloud REST API as the site's own web app calls it with the
///   session (cookie auth on Cloud REST isn't an official credential — the reuse gap,
///   docs/research/integrations-auth.md §7), per enabled site and refresh:
///   `GET /rest/api/space` (space overview with icons) and
///   `GET /rest/api/search?cql=updated>=<2d+ago>+ORDER+BY+updated+DESC&limit=25` (recently updated
///   pages, den's CQL endpoint mirrors the "Recently Updated" page).
/// - Each page becomes a `update` feed item. The `mention.me()` CQL fragment is not reliable via
///   REST, so mentions are inferred: pages where the current user's `accountId` matches the `author.key`
///   or where the content contains `@<accountId>` mentions.
/// - A 401/403, or a REST request that no longer returns JSON, means the session ended:
///   `connections.report {expired}`.

final class ConfluenceCore {
  static let id = "confluence"
  static let icon = "https://www.atlassian.com/favicon.ico"
  static let sessionCookie = "cloud.session.token"
  static let maxPages = 25
  static let maxSpaces = 30

  struct Site {
    var host: String  // "acme.atlassian.net" (the session cookie's host)
    var base: String  // "https://acme.atlassian.net"
    var account: String  // displayName from the cookie or space list
  }

  let env: PluginEnv
  let requests: Requests
  var sites: [Site] = []  // in memory only
  var registerAttempts = 0
  var refreshing = false
  var failedCookies = ""

  init(env: PluginEnv) {
    self.env = env
    requests = Requests(env: env, prefix: "confluence")
  }

  /// Endpoints, overridable in storage ns `confluence` key `endpoints` {domain, signIn, origin} (tests,
  /// mocks). `origin` replaces the per-site base URL derivation with one fixed base.
  var endpoints: Value { env.call("storage", "get", ["ns": "confluence", "key": "endpoints"]) }
  var domain: String { endpoints.sOpt("domain") ?? "atlassian.net" }
  var signIn: String { endpoints.sOpt("signIn") ?? "https://id.atlassian.com/login" }

  func start() {
    env.on("connections.probe") { [self] v in
      if v.s("id") == Self.id { probe(profile: v.sOpt("profile") ?? "default", auto: v.s("reason") == "register") }
    }
    env.on("feed.refresh") { [self] _ in refresh() }
    // Auto-connect: signing in to Confluence in den (now or later) connects it. The host observes the
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
    let r = env.call("connections", "register", ["id": .string(Self.id), "title": "Confluence", "icon": .string(Self.icon),
                                                  "domain": "atlassian.net", "signIn": .string(signIn), "owner": .string(Self.id),
                                                  "unit": "sites", "order": 75, "important": true])
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
  /// cookie set on ".atlassian.net" itself yields "atlassian.net".
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
  /// so it's a cookie read, no request to Confluence.
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
      spaces(hosts, profile: profile) { [self] found, _ in
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

  /// `space` per candidate host: the sites with live Confluence spaces. `expired` when every
  /// candidate said the session is gone.
  func spaces(_ hosts: [String], profile: String, _ done: @escaping ([Site], Bool) -> Void) {
    var found: [Site] = []
    var expired = true
    let steps: [(@escaping () -> Void) -> Void] = hosts.map { h in
      { [self] next in
        get(base(h) + "/rest/api/space?limit=1", profile: profile) { [self] r, status in
          if !Self.authGone(status) { expired = false }
          if status == 200, !r.a("results").isEmpty {
            let account = r.a("results").first?.sOpt("name") ?? r.a("results").first?.s("key") ?? Self.siteName(h)
            found.append(Site(host: h, base: base(h), account: account))
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
      spaces(hosts, profile: profile, done)
    }
  }

  /// GET a Confluence REST endpoint with the session's cookies. `done(json, status)`; status 0 means
  /// a network error. Redirects off the site aren't followed (the host's `net` never follows them),
  /// so a signed-out call comes back 302.
  func get(_ url: String, profile: String, _ done: @escaping (Value, Int64) -> Void) {
    requests.call("net", "fetch", ["plugin": .string(Self.id), "url": .string(url), "session": true, "profile": .string(profile),
                                    "as": "json", "headers": ["Accept": "application/json"]]) { r in
      done(r.b("ok") ? r["json"] : .null, r.b("ok") ? r.i("status") : 0)
    }
  }

  /// The session ended: 401/403, or the redirect to the identity sign-in (302).
  static func authGone(_ status: Int64) -> Bool { status == 401 || status == 403 || status == 302 }

  /// CQL-encoded date string for 2 days ago.
  static func cqlDate(_ ms: Int64) -> String {
    Web.date(ms)
  }

  /// Recently updated pages: the `search` endpoint with `cql=updated>=<2d> ORDER BY updated DESC`.
  static func pagesURL(_ base: String, sinceMs: Int64) -> String {
    let since = cqlDate(sinceMs)
    return base + "/rest/api/search?cql=" + Web.encode("updated >= \"" + since + "\"") +
      "+ORDER+BY+updated+DESC&limit=" + String(Self.maxPages)
  }

  /// Space overview: all spaces the user can see.
  static func spacesURL(_ base: String) -> String {
    base + "/rest/api/space?expand=space.icon&limit=" + String(Self.maxSpaces)
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
      let sinceMs = env.now() - 2 * 86_400_000  // last 2 days
      let steps: [(@escaping () -> Void) -> Void] = sites.filter { enabled.contains($0.host) }.map { s in
        { [self] next in
          // Fetch pages
          get(Self.pagesURL(s.base, sinceMs: sinceMs), profile: profile) { [self] r, status in
            if Self.authGone(status) {
              expired = true
            } else if status == 0 || status >= 400 || r["results"].isNull {
              error = error ?? (status == 0 ? "network error" : "Confluence returned " + String(status))
            } else {
              items += r.a("results").map { Self.pageItem($0, site: s, multi: multi) }
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
    // Sites live in memory only: after a relaunch, read them again.
    if sites.isEmpty {
      findSites(profile: profile) { [self] found, expired in
        sites = found
        if found.isEmpty {
          refreshing = false
          if expired { env.call("connections", "report", ["id": .string(Self.id), "connected": false, "expired": true]) }
          env.emit("feed.items", ["source": .string(Self.id), "items": [], "error": .string(expired ? "signed out" : "couldn't reach Confluence")])
        } else {
          run()
        }
      }
    } else {
      run()
    }
  }

  /// One search-result page -> a `update` feed item (see docs/plugin-services.md for the shape).
  static func pageItem(_ page: Value, site: Site, multi: Bool) -> Value {
    let pageId = page.s("id")
    let title = page.sOpt("title") ?? "(Untitled)"
    let space = page["space"].sOpt("name") ?? page["space"].sOpt("key") ?? ""
    let updatedAt = page["version"].i("when", 0)
    let author = page["version"].sOpt("by")
    let authorKey = page["version"]["by"].sOpt("displayName") ?? page["version"]["by"].sOpt("username") ?? ""

    var fullUrl = ""
    if let webui = page.sOpt("webui") {
      fullUrl = webui
    } else if let expand = page.sOpt("expand") {
      // Try to extract webui URL from the expand string
      let webui = Web.query(expand, "webui")
      if !webui.isEmpty { fullUrl = site.base + webui }
    }
    if fullUrl.isEmpty { fullUrl = site.base }

    var detail = title
    if !space.isEmpty { detail += " · " + space }
    if multi { detail += " · " + site.host }
    if !authorKey.isEmpty { detail += " · by " + authorKey }

    let badge = "Updated"
    let summary = "Confluence page updated: " + title + (space.isEmpty ? "" : " in " + space)

    return [
      "id": .string("confluence:" + site.host + ":" + String(pageId)), "source": .string(Self.id), "kind": "update",
      "title": .string(title.isEmpty ? "(Untitled)" : title), "detail": .string(detail),
      "url": .string(fullUrl.isEmpty ? site.base : fullUrl), "ts": .int(updatedAt), "icon": .string(Self.icon),
      "badge": .string(badge), "actor": .string(authorKey.isEmpty ? author ?? "" : authorKey), "where": .string(space.isEmpty ? "Confluence" : space),
      "actionable": true, "summary": .string(summary),
      "importantKey": .string("confluence:" + site.host + ":" + String(pageId)),
      "importantTitle": .string(space.isEmpty ? title : title + " · " + space),
    ]
  }

  /// Get a string by first trying key, then "expand" query param prefixed with key.
  static func expandValue(_ v: Value, key: String) -> String {
    let direct = v.s(key)
    if !direct.isEmpty { return direct }
    let exp = v.sOpt("expand") ?? ""
    return Web.query(exp, key)
  }
}