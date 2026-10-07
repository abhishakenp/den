#if !hasFeature(Embedded)
  import CordisValue
#endif

/// Notion through the notion.so session the user signed in to in den (no integration token, no OAuth).
///
/// - **Connected** when the profile has notion.so's `token_v2` cookie and `getSpaces` lists at
///   least one workspace. Workspaces are the connection's `teams`, each switchable in Settings.
/// - **Data**: the internal web API the Notion app itself calls (`POST /api/v3/…`, JSON, cookie
///   auth; undocumented, shapes from open-source clients, see docs/research/integrations-auth.md):
///   `getSpaces` once per probe, then `getNotificationLogV2 {spaceId, size: 20, type:
///   "unread_and_read"}` per enabled workspace and refresh. Unread notifications become feed
///   items: `mention`, `comment` and `invite` (a page shared with you). Record values are
///   unwrapped from both known nestings (`value` and `value.value`).
/// - A 401 means the session ended: `connections.report {expired}`.
final class NotionCore {
  static let id = "notion"
  static let icon = "https://www.notion.so/images/favicon.ico"
  static let maxPerSpace = 10

  struct Space {
    var id: String
    var name: String
    var user: String
    var icon: String
  }

  let env: PluginEnv
  let requests: Requests
  var spaces: [Space] = []  // in memory only
  var users: [String: String] = [:]  // id -> name, from the last responses
  var registerAttempts = 0
  var refreshing = false
  var failedToken = ""

  init(env: PluginEnv) {
    self.env = env
    requests = Requests(env: env, prefix: "notion")
  }

  /// Overridable in storage ns `notion` key `endpoints` {api, web, domain, signIn} (tests, mocks).
  var endpoints: Value { env.call("storage", "get", ["ns": "notion", "key": "endpoints"]) }
  var api: String { endpoints.sOpt("api") ?? "https://www.notion.so/api/v3/" }
  var web: String { endpoints.sOpt("web") ?? "https://www.notion.so" }
  var domain: String { endpoints.sOpt("domain") ?? "notion.so" }
  var signIn: String { endpoints.sOpt("signIn") ?? "https://www.notion.so/login" }

  func start() {
    env.on("connections.probe") { [self] v in
      if v.s("id") == Self.id { probe(profile: v.sOpt("profile") ?? "default", auto: v.s("reason") == "register") }
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
    let r = env.call("connections", "register", ["id": .string(Self.id), "title": "Notion", "icon": .string(Self.icon), "domain": "notion.so",
                                                  "signIn": .string(signIn), "owner": .string(Self.id), "unit": "workspaces", "order": 50, "important": true])
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

  static func cookie(_ cookies: [Value], _ name: String) -> String {
    cookies.first { $0.s("name") == name && !$0.s("value").isEmpty }?.s("value") ?? ""
  }

  func autoProbe(_ profile: String) {
    let c = env.call("connections", "get", ["id": .string(Self.id)])
    if c.b("declined") { return }
    requests.call("session", "cookies", ["plugin": .string(Self.id), "domain": .string(domain), "profile": .string(profile)]) { [self] r in
      let token = Self.cookie(r.a("cookies"), "token_v2")
      if c.b("connected") {
        guard (c.sOpt("profile") ?? "default") == profile, token.isEmpty else { return }
        spaces = []
        env.call("connections", "report", ["id": .string(Self.id), "connected": false, "profile": .string(profile), "auto": true])
        return
      }
      guard !token.isEmpty, token != failedToken else { return }
      probe(profile: profile, auto: true, token: token)
    }
  }

  // MARK: Probe

  func probe(profile: String, auto: Bool, token known: String? = nil) {
    let check: (@escaping (String) -> Void) -> Void = { [self] next in
      if let known { return next(known) }
      requests.call("session", "cookies", ["plugin": .string(Self.id), "domain": .string(domain), "profile": .string(profile)]) { r in
        next(Self.cookie(r.a("cookies"), "token_v2"))
      }
    }
    check { [self] token in
      guard !token.isEmpty else { return report(false, profile: profile, auto: auto) }
      post("getSpaces", [:], user: "", profile: profile) { [self] r, _ in
        let (found, account) = Self.parseSpaces(r)
        spaces = found
        guard !found.isEmpty else {
          if auto { failedToken = token }
          return report(false, profile: profile, auto: auto)
        }
        failedToken = ""
        let list: [Value] = found.map { s in
          ["id": .string(s.id), "name": .string(s.name), "url": .string(web), "icon": .string(Self.spaceIcon(s.icon)), "enabled": true]
        }
        env.call("connections", "report", ["id": .string(Self.id), "connected": true, "profile": .string(profile),
                                            "account": .string(account.isEmpty ? found[0].name : account), "teams": .array(list), "auto": .bool(auto)])
      }
    }
  }

  func report(_ connected: Bool, profile: String, auto: Bool) {
    env.call("connections", "report", ["id": .string(Self.id), "connected": .bool(connected), "profile": .string(profile), "auto": .bool(auto)])
  }

  /// POST `api + method` with a JSON body and the session's cookies. `done(json, status)`.
  func post(_ method: String, _ body: Value, user: String, profile: String, _ done: @escaping (Value, Int64) -> Void) {
    var headers: Value = ["Content-Type": "application/json", "Accept": "application/json"]
    if !user.isEmpty { headers.put("x-notion-active-user-header", .string(user)) }
    requests.call("net", "fetch", ["plugin": .string(Self.id), "url": .string(api + method), "method": "POST", "session": true,
                                    "profile": .string(profile), "as": "json", "headers": headers, "body": .string(Web.json(body))]) { r in
      done(r.b("ok") ? r["json"] : .null, r.b("ok") ? r.i("status") : 0)
    }
  }

  // MARK: Parsing

  /// A record's value, whichever nesting Notion used (`{value: {…}}` or `{value: {value: {…}}}`).
  static func unwrap(_ record: Value) -> Value {
    let v = record["value"]
    if !v["value"].isNull && v["id"].isNull { return v["value"] }
    return v
  }

  /// `getSpaces`: `{<userId>: {notion_user: {<id>: rec}, space: {<id>: rec}, space_view: …}}`.
  /// Returns the workspaces (each with the user it belongs to) and the account's name.
  static func parseSpaces(_ r: Value) -> ([Space], String) {
    guard case let .object(users) = r else { return ([], "") }
    var out: [Space] = []
    var account = ""
    for (uid, u) in users {
      let me = unwrap(u["notion_user"][uid])
      if account.isEmpty { account = me.sOpt("email") ?? me.s("name") }
      guard case let .object(spaces) = u["space"] else { continue }
      for (sid, rec) in spaces {
        let v = unwrap(rec)
        guard !out.contains(where: { $0.id == sid }) else { continue }
        out.append(Space(id: sid, name: v.sOpt("name") ?? "Workspace", user: uid, icon: v.s("icon")))
      }
    }
    return (out.sorted { $0.name < $1.name }, account)
  }

  /// Emoji icons show as-is; image icons only when absolute.
  static func spaceIcon(_ icon: String) -> String {
    if icon.isEmpty { return Self.icon }
    if URLs.isWeb(icon) { return icon }
    return Text.hasPrefix(icon, "/") ? Self.icon : icon
  }

  /// Notion rich text (`[["Hello "], ["‣", [["u", "<id>"]]], …]`) as plain text.
  static func richText(_ v: Value, users: [String: String]) -> String {
    var out = ""
    for seg in v.array ?? [] {
      let parts = seg.array ?? []
      guard let text = parts.first?.string else { continue }
      if text == "‣", parts.count > 1, let ann = parts[1].array?.first?.array, ann.count > 1 {
        let kind = ann[0].string ?? "", ref = ann[1].string ?? ""
        out += kind == "u" ? "@" + (users[ref] ?? "someone") : kind == "p" ? "a page" : kind == "d" ? "a date" : ""
      } else {
        out += text
      }
    }
    return out
  }

  static func stripDashes(_ id: String) -> String {
    var b: [UInt8] = []
    for c in id.utf8 where c != 45 { b.append(c) }
    return String(decoding: b, as: UTF8.self)
  }

  static func ms(_ v: Value) -> Int64 {
    if let n = v.int { return n }
    if let d = v.double { return Int64(d) }
    if let s = v.string, let n = Text.int(s) { return Int64(n) }
    return 0
  }

  /// `getNotificationLogV2` -> feed items for the unread notifications of one workspace.
  static func items(_ r: Value, space: Space, multi: Bool, web: String) -> [Value] {
    let rm = r["recordMap"]
    var users: [String: String] = [:]
    if case let .object(us) = rm["notion_user"] { for (k, rec) in us { users[k] = unwrap(rec).s("name") } }
    var out: [Value] = []
    for idv in r.a("notificationIds") {
      guard out.count < maxPerSpace, let nid = idv.string else { continue }
      let n = unwrap(rm["notification"][nid])
      guard !n.isNull, !n.b("read"), !n.b("invalid") else { continue }
      let a = unwrap(rm["activity"][n.s("activity_id")])
      let type = a.sOpt("type") ?? n.s("type")
      let kind: String
      switch type {
      case "user-mentioned": kind = "mention"
      case "commented": kind = "comment"
      case "user-invited", "space-invited", "block-shared", "page-shared": kind = "invite"
      case "reminder": kind = "reminder"
      default: kind = "update"
      }
      let blockId = a.sOpt("navigable_block_id") ?? n.sOpt("navigable_block_id") ?? a.s("parent_id")
      let block = unwrap(rm["block"][blockId])
      var page = richText(block["properties"]["title"], users: users)
      if page.isEmpty, let cid = block.sOpt("collection_id") { page = richText(unwrap(rm["collection"][cid])["name"], users: users) }
      if page.isEmpty { page = "Untitled" }
      let edits = a.a("edits")
      var actorId = edits.first?["authors"].array?.first?.s("id") ?? ""
      if actorId.isEmpty { actorId = a.a("actor_ids").first?.string ?? edits.first?.s("author_id") ?? "" }
      let actor = users[actorId] ?? "Someone"
      var text = ""
      for e in edits where e.s("type") == "comment-created" {
        text = richText(e["comment_data"]["text"], users: users)
        if text.isEmpty { text = richText(unwrap(rm["comment"][e.s("comment_id")])["text"], users: users) }
        if !text.isEmpty { break }
      }
      if kind == "mention", text.isEmpty {
        let mb = unwrap(rm["block"][a.s("mentioned_block_id")])
        text = richText(mb["properties"]["title"], users: users)
      }
      text = Web.oneLine(text, max: 200)
      var url = web + "/" + stripDashes(blockId)
      let discussion = a.sOpt("discussion_id") ?? edits.first?.sOpt("discussion_id") ?? ""
      if !discussion.isEmpty { url += "?d=" + stripDashes(discussion) }
      let ts = ms(a["end_time"]) > 0 ? ms(a["end_time"]) : ms(n["end_time"]) > 0 ? ms(n["end_time"]) : ms(a["start_time"])
      var detail: String
      let badge: String
      let summary: String
      switch kind {
      case "mention":
        detail = actor + " mentioned you in " + page
        badge = "Mention"
        summary = actor + " mentioned you in the Notion page " + page + (text.isEmpty ? "" : ": " + text)
      case "comment":
        detail = actor + " commented on " + page
        badge = "Comment"
        summary = actor + " commented on the Notion page " + page + (text.isEmpty ? "" : ": " + text)
      case "invite":
        detail = actor + " shared " + page + " with you"
        badge = "Shared"
        summary = actor + " shared the Notion page " + page + " with you"
      case "reminder":
        detail = "Reminder in " + page
        badge = "Reminder"
        summary = "Notion reminder in " + page + (text.isEmpty ? "" : ": " + text)
      default:
        detail = actor + " updated " + page
        badge = "Update"
        summary = actor + " updated the Notion page " + page
      }
      if multi { detail += " · " + space.name }
      out.append([
        "id": .string("notion:" + nid), "source": .string(id), "kind": .string(kind == "reminder" ? "mention" : kind == "update" ? "update" : kind),
        "title": .string(text.isEmpty ? page : text), "detail": .string(detail), "url": .string(url), "ts": .int(ts), "icon": .string(icon),
        "badge": .string(badge), "actor": .string(actor), "where": .string(page), "actionable": .bool(kind != "update"), "summary": .string(summary),
        "importantKey": .string("notion:" + stripDashes(blockId)), "importantTitle": .string(page + (multi ? " · " + space.name : "")),
      ])
    }
    return out
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
      let multi = spaces.count > 1
      let steps: [(@escaping () -> Void) -> Void] = spaces.filter { enabled.contains($0.id) }.map { s in
        { [self] next in
          post("getNotificationLogV2", ["spaceId": .string(s.id), "size": 20, "type": "unread_and_read", "variant": "no_grouping"],
               user: s.user, profile: profile) { [self] r, status in
            if status == 401 {
              expired = true
            } else if status == 0 || status >= 400 || r["notificationIds"].isNull {
              error = error ?? (status == 0 ? "network error" : status == 429 ? "Notion asked den to slow down" : "Notion returned " + String(status))
            } else {
              items += Self.items(r, space: s, multi: multi, web: web)
            }
            next()
          }
        }
      }
      sequence(steps) { [self] in
        refreshing = false
        if expired {
          spaces = []
          env.call("connections", "report", ["id": .string(Self.id), "connected": false, "expired": true])
          env.emit("feed.items", ["source": .string(Self.id), "items": [], "error": "signed out"])
          return
        }
        var payload: Value = ["source": .string(Self.id), "items": .array(items), "account": c["account"]]
        if let error { payload.put("error", .string(error)) }
        env.emit("feed.items", payload)
      }
    }
    // Workspaces live in memory only: after a relaunch, read them again.
    if spaces.isEmpty {
      post("getSpaces", [:], user: "", profile: profile) { [self] r, status in
        spaces = Self.parseSpaces(r).0
        if spaces.isEmpty {
          refreshing = false
          if status == 401 { env.call("connections", "report", ["id": .string(Self.id), "connected": false, "expired": true]) }
          env.emit("feed.items", ["source": .string(Self.id), "items": [], "error": .string(status == 401 ? "signed out" : "couldn't reach Notion")])
        } else {
          run()
        }
      }
    } else {
      run()
    }
  }
}
