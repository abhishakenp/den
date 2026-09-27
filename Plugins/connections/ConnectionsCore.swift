#if !hasFeature(Embedded)
  import CordisValue
#endif

/// Dia-style connections: the user signs in to a site inside den, and den reuses that session.
///
/// Providers (the `slack` and `github` plugins) `register` themselves. "Connect X" first asks the
/// provider whether the profile is already signed in (`connections.probe`); if not, it opens the
/// sign-in page in a tab and probes again every few seconds (and whenever that tab's URL changes)
/// until the provider `report`s a session, then shows "X connected". Nothing polls while no
/// connect is pending. Accounts (names, team ids, the profile) persist in storage ns
/// `connections`, key `accounts`; tokens never do, providers keep them in memory.
final class ConnectionsCore {
  static let ns = "connections"
  static let sheetSlot = "overlay.connections"
  static let sheetId = "connections"
  static let probeEveryMs: UInt64 = 3000
  static let connectTimeoutMs: Int64 = 15 * 60 * 1000

  struct Provider {
    var id: String
    var title: String
    var icon: String
    var domain: String
    var signIn: String
  }

  struct Pending {
    var profile: String
    var tab: String?
    var url: String
    var started: Int64
  }

  let env: PluginEnv
  var providers: [Provider] = []
  var accounts: [Value] = []
  var pending: [String: Pending] = [:]
  var sheetOpen = false
  var registered: [String] = []
  var registerAttempts = 0
  var retrying = false

  init(env: PluginEnv) { self.env = env }

  func start() {
    accounts = env.call("storage", "get", ["ns": .string(Self.ns), "key": "accounts"]).array ?? []
    env.on("ui.action") { [self] v in action(v) }
    env.on("commands.run") { [self] v in command(v.s("id")) }
    env.on("webviews.url") { [self] v in
      for (id, p) in pending where p.tab == v.s("id") { probe(id) }
    }
    // A finished load in the sign-in tab is when the site has set its session.
    env.on("webviews.progress") { [self] v in
      guard !v.b("loading") else { return }
      for (id, p) in pending where p.tab == v.s("id") { probe(id) }
    }
    env.on("tabs.closed") { [self] v in
      for (id, p) in pending where p.tab == v.s("id") {
        pending[id] = nil
        render()
      }
    }
    registerCommands()
  }

  // MARK: Service

  func handle(_ method: String, _ args: Value) -> Value {
    switch method {
    case "register":
      let id = args.s("id")
      guard !id.isEmpty else { return .err("connections: id required") }
      providers.removeAll { $0.id == id }
      providers.append(Provider(id: id, title: args.sOpt("title") ?? id, icon: args.s("icon"), domain: args.s("domain"), signIn: args.s("signIn")))
      registerCommands()
      changed()
      return .okay
    case "list": return list()
    case "get": return list().array?.first { $0.s("id") == args.s("id") } ?? .null
    case "connect": return connect(args.s("id"), url: args.sOpt("url"), profile: args.sOpt("profile"))
    case "report": report(args); return .okay
    case "disconnect": return disconnect(args.s("id"))
    case "setTeam":
      setTeam(args.s("id"), team: args.s("team"), enabled: args.b("enabled", true))
      return .okay
    case "open":
      sheetOpen = true
      render()
      return .okay
    case "close":
      closeSheet()
      return .okay
    default: return .err("connections: unknown method " + method)
    }
  }

  func provider(_ id: String) -> Provider? { providers.first { $0.id == id } }
  func account(_ id: String) -> Value? { accounts.first { $0.s("id") == id } }

  func list() -> Value {
    .array(providers.map { p in
      var v: Value = ["id": .string(p.id), "title": .string(p.title), "icon": .string(p.icon), "domain": .string(p.domain)]
      if let a = account(p.id) {
        v.put("connected", true)
        v.put("account", a["account"])
        v.put("profile", a["profile"])
        v.put("teams", a["teams"])
        v.put("since", a["since"])
      } else {
        v.put("connected", false)
        v.put("pending", .bool(pending[p.id] != nil))
      }
      return v
    })
  }

  func profileOfCurrentSpace() -> String {
    let cur = env.call("spaces", "current").s("id")
    for s in env.call("spaces", "list").array ?? [] where s.s("id") == cur { return s.sOpt("profile") ?? "default" }
    return "default"
  }

  // MARK: Connect flow

  func connect(_ id: String, url: String?, profile: String?) -> Value {
    guard let p = provider(id) else { return .err("connections: no provider " + id) }
    if account(id) != nil {
      toast(p.title + " is already connected", icon: "sf:checkmark.circle.fill")
      return .okay
    }
    pending[id] = Pending(profile: profile ?? profileOfCurrentSpace(), tab: nil, url: url ?? p.signIn, started: env.now())
    env.emit("connections.probe", ["id": .string(id), "profile": .string(pending[id]!.profile), "reason": "connect"])
    render()
    return .okay
  }

  func probe(_ id: String) {
    guard let p = pending[id] else { return }
    env.emit("connections.probe", ["id": .string(id), "profile": .string(p.profile), "reason": "poll"])
  }

  func scheduleProbe(_ id: String) {
    env.timer(Self.probeEveryMs, false) { [self] in
      guard let p = pending[id] else { return }
      if env.now() - p.started > Self.connectTimeoutMs {
        pending[id] = nil
        render()
        return
      }
      probe(id)
    }
  }

  /// A provider's answer to a probe (or a later "session ended" from a refresh).
  func report(_ args: Value) {
    let id = args.s("id")
    guard let p = provider(id) else { return }
    if args.b("connected") {
      let wasPending = pending[id] != nil
      let isNew = account(id) == nil
      let profile = args.sOpt("profile") ?? pending[id]?.profile ?? "default"
      var teams = args.a("teams")
      // Keep the user's workspace choices across re-probes.
      if let old = account(id) {
        teams = teams.map { t in
          var t = t
          if let o = old.a("teams").first(where: { $0.s("id") == t.s("id") }) { t.put("enabled", .bool(o.b("enabled", true))) }
          return t
        }
      }
      let acct: Value = ["id": .string(id), "account": .string(args.s("account")), "profile": .string(profile), "teams": .array(teams),
                         "since": .int(account(id)?.i("since") ?? env.now())]
      accounts.removeAll { $0.s("id") == id }
      accounts.append(acct)
      save()
      pending[id] = nil
      if isNew {
        toast(p.title + " connected", icon: "sf:checkmark.circle.fill")
        if teams.count > 1 { sheetOpen = true }
      }
      if isNew || wasPending { changed() }
      render()
      return
    }
    // Not signed in.
    if var pend = pending[id] {
      if pend.tab == nil {
        let r = env.call("tabs", "open", ["url": .string(pend.url)])
        pend.tab = r.sOpt("id")
        pending[id] = pend
        render()
      }
      scheduleProbe(id)
    } else if account(id) != nil && args.b("expired") {
      // The site session ended (signed out): drop the account and say so.
      accounts.removeAll { $0.s("id") == id }
      save()
      toast("Signed out of " + p.title + ". Connect again to keep it in your briefing", icon: "sf:exclamationmark.triangle.fill")
      changed()
      render()
    }
  }

  func disconnect(_ id: String) -> Value {
    guard let p = provider(id) else { return .err("connections: no provider " + id) }
    pending[id] = nil
    guard account(id) != nil else { return .okay }
    accounts.removeAll { $0.s("id") == id }
    save()
    toast(p.title + " disconnected", icon: "sf:link")
    changed()
    render()
    return .okay
  }

  func setTeam(_ id: String, team: String, enabled: Bool) {
    guard var a = account(id) else { return }
    a.put("teams", .array(a.a("teams").map { t in
      var t = t
      if t.s("id") == team { t.put("enabled", .bool(enabled)) }
      return t
    }))
    accounts = accounts.map { $0.s("id") == id ? a : $0 }
    save()
    changed()
    render()
  }

  func save() { env.call("storage", "set", ["ns": .string(Self.ns), "key": "accounts", "value": .array(accounts)]) }

  func changed() {
    registerCommands()
    env.emit("connections.changed", ["connections": list()])
  }

  func toast(_ text: String, icon: String) {
    env.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": .string(text), "icon": .string(icon)]])
  }

  // MARK: Settings sheet

  func closeSheet() {
    guard sheetOpen else { return }
    sheetOpen = false
    env.call("ui", "set", ["slot": .string(Self.sheetSlot), "tree": nil])
  }

  func sheetTree() -> Value {
    var children: [Value] = [
      ["type": "paragraph", "id": "connections.about", "style": "secondary", "icon": "sf:lock.fill",
       "text": "den reads your accounts through the sessions you sign in to inside den. Requests go only to the service itself, nothing is stored outside den, and summaries run on this Mac."],
    ]
    var rows: [Value] = []
    for p in providers {
      var row: Value = ["type": "connectionRow", "id": .string("connections.row:" + p.id), "title": .string(p.title), "icon": .string(p.icon)]
      if let a = account(p.id) {
        let teams = a.a("teams")
        var status = "Connected"
        let name = a.s("account")
        if !name.isEmpty { status += " · " + name }
        if teams.count > 1 { status += " · " + String(teams.count) + " workspaces" }
        row.put("connected", true)
        row.put("status", .string(status))
        row.put("button", ["title": "Disconnect", "style": "secondary"])
      } else if pending[p.id] != nil {
        row.put("connected", false)
        row.put("status", .string("Waiting for you to sign in to " + p.domain + "…"))
        row.put("button", ["title": "Cancel", "style": "secondary"])
      } else {
        row.put("connected", false)
        row.put("status", .string("Sign in to " + p.domain + " in den to connect"))
        row.put("button", ["title": "Connect", "style": "primary"])
      }
      rows.append(row)
    }
    children.append(["type": "section", "id": "connections.accounts", "title": "Accounts", "children": .array(rows)])
    for p in providers {
      guard let a = account(p.id), a.a("teams").count > 1 else { continue }
      let toggles: [Value] = a.a("teams").map { t in
        ["type": "toggleRow", "id": .string("connections.team:" + p.id + ":" + t.s("id")), "title": .string(t.s("name")),
         "subtitle": .string(URLs.host(t.s("url"))), "icon": .string(t.sOpt("icon") ?? p.icon), "on": .bool(t.b("enabled", true))]
      }
      children.append(["type": "section", "id": .string("connections.teams:" + p.id), "title": .string(p.title + " workspaces"),
                       "accessory": "Shown in your briefing", "children": .array(toggles)])
    }
    return ["type": "sheet", "id": .string(Self.sheetId), "style": "sheet", "title": "Connections", "icon": "sf:link",
            "subtitle": "Slack and GitHub, through your own sign-in", "children": .array(children)]
  }

  func render() {
    guard sheetOpen else { return }
    env.call("ui", "set", ["slot": .string(Self.sheetSlot), "tree": sheetTree()])
  }

  func action(_ v: Value) {
    let id = v.s("id"), act = v.s("action")
    if id == Self.sheetId && act == "dismiss" { closeSheet(); return }
    if Text.hasPrefix(id, "connections.row:") {
      let pid = Text.dropPrefix(id, "connections.row:")
      if account(pid) != nil { _ = disconnect(pid) } else if pending[pid] != nil {
        pending[pid] = nil
        render()
      } else { _ = connect(pid, url: nil, profile: nil) }
      return
    }
    if Text.hasPrefix(id, "connections.team:"), act == "toggle" {
      let rest = Array(Text.dropPrefix(id, "connections.team:").utf8)
      guard let colon = rest.firstIndex(of: 58) else { return }
      setTeam(String(decoding: rest[..<colon], as: UTF8.self), team: String(decoding: rest[(colon + 1)...], as: UTF8.self), enabled: v["value"].b("on", true))
    }
  }

  // MARK: Commands

  func command(_ id: String) {
    if id == "connections.open" { _ = handle("open", .null); return }
    if Text.hasPrefix(id, "connections.connect:") { _ = connect(Text.dropPrefix(id, "connections.connect:"), url: nil, profile: nil) }
    if Text.hasPrefix(id, "connections.disconnect:") { _ = disconnect(Text.dropPrefix(id, "connections.disconnect:")) }
  }

  /// "Connect X" for each provider without an account, "Disconnect X" for each with one, and
  /// "Connections…". `commands` is optional and may load later: retried every 500 ms for 30 s.
  func registerCommands() {
    if tryRegister() { return }
    guard !retrying, registerAttempts < 60 else { return }
    retrying = true
    env.timer(500, false) { [self] in
      retrying = false
      registerAttempts += 1
      registerCommands()
    }
  }

  @discardableResult
  func tryRegister() -> Bool {
    var want: [(String, String, String)] = [("connections.open", "Connections…", "sf:link")]
    for p in providers {
      if account(p.id) != nil {
        want.append(("connections.disconnect:" + p.id, "Disconnect " + p.title, "sf:minus.circle"))
      } else {
        want.append(("connections.connect:" + p.id, "Connect " + p.title, p.icon.isEmpty ? "sf:link" : p.icon))
      }
    }
    for id in registered where !want.contains(where: { $0.0 == id }) {
      env.call("commands", "unregister", ["id": .string(id)])
    }
    registered.removeAll { id in !want.contains { $0.0 == id } }
    for w in want where !registered.contains(w.0) {
      let r = env.call("commands", "register", ["id": .string(w.0), "title": .string(w.1), "icon": .string(w.2), "owner": "connections",
                                                  "keywords": ["connect", "account", "sign in", "integration", "slack", "github"]])
      if r.isErr { return false }
      registered.append(w.0)
    }
    return true
  }
}
