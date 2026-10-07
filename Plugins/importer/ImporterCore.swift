// The `importer` service: brings spaces, pinned tabs, favorites, bookmarks, open tabs and history
// over from Arc, Safari, Chrome, Dia, Brave, Edge, Firefox and Zen, and passwords from a CSV export.
//
// Zero friction (docs/guide/_in-app-tips.md): never a gate. It's offered by the tips plugin's quiet
// import card (`sources`, `run`), the "Import from…" command and Settings ▸ General ▸ Import….
// Nothing is read until one of those is used: at load it only subscribes and, after
// `startDelayMs`, registers its command and Settings row.
//
// How it reads: the host `files` service (declared paths only, permissions.json): `stat`/`list`
// to find a browser's profiles, `read` (JSON, plist, bytes) and `sqlite` (a copy of a locked
// database) off the main thread. The parsers turn that into an `ImportResult`; `apply` maps it
// onto den: `spaces.create`/`update`, `tabs.importItems` (pinned tabs, folders, favorites, a
// "<Browser> Bookmarks" pinned folder, a "From <Browser>" Today group) and
// `commands.importHistory` (the command bar's history and frecency). Every import is a batch:
// re-importing finds what the last one made (stable keys) and adds only what's new; Undo removes
// the batch. Passwords go straight from the file to the Keychain in the host (`vault.importFile`,
// after Touch ID): this plugin never sees one.

#if !hasFeature(Embedded)
  import CordisValue
#endif

final class ImporterCore {
  static let ns = "importer"
  static let toastId = "importer.toast"
  static let dialogId = "importer.dialog"
  static let openCommand = "importer.open"
  static let passwordsRequest = "importer.passwords"
  static let startDelayMs: UInt64 = 1500
  /// A stuck read can't keep the import open forever.
  static let jobTimeoutMs: UInt64 = 180_000
  static let maxBatches = 10
  static let maxProfiles = 4

  struct Browser {
    let id: String
    let name: String
    let kind: String  // arc | chromium | safari | firefox
    let root: String
    let icon: String
  }

  /// Arc first (den's model is Arc's), then the browsers den's users come from most.
  static let browsers: [Browser] = [
    Browser(id: "arc", name: "Arc", kind: "arc", root: "~/Library/Application Support/Arc", icon: "sf:rainbow"),
    Browser(id: "safari", name: "Safari", kind: "safari", root: "~/Library/Safari", icon: "sf:safari"),
    Browser(id: "chrome", name: "Chrome", kind: "chromium", root: "~/Library/Application Support/Google/Chrome", icon: "sf:globe"),
    Browser(id: "dia", name: "Dia", kind: "chromium", root: "~/Library/Application Support/Dia/User Data", icon: "sf:globe"),
    Browser(id: "brave", name: "Brave", kind: "chromium", root: "~/Library/Application Support/BraveSoftware/Brave-Browser", icon: "sf:globe"),
    Browser(id: "edge", name: "Edge", kind: "chromium", root: "~/Library/Application Support/Microsoft Edge", icon: "sf:globe"),
    Browser(id: "firefox", name: "Firefox", kind: "firefox", root: "~/Library/Application Support/Firefox", icon: "sf:flame"),
    Browser(id: "zen", name: "Zen", kind: "firefox", root: "~/Library/Application Support/zen", icon: "sf:leaf"),
  ]

  /// Header names in password exports: Chrome/Arc/Edge/Brave (name,url,username,password,note),
  /// Safari (Title,URL,Username,Password,Notes,OTPAuth), 1Password (Title,Url,Username,Password,…),
  /// Bitwarden (…,login_uri,login_username,login_password,…), Firefox (url,username,password,…).
  static let passwordColumns: Value = [
    "origin": ["url", "login_uri", "website", "web site", "login url", "uri", "hostname"],
    "username": ["username", "login_username", "login", "user name", "user", "email", "e-mail"],
    "password": ["password", "login_password"],
  ]

  final class Job {
    let browser: Browser
    var result: ImportResult
    var waiting = 0
    let id: Int
    init(_ b: Browser, id: Int) {
      browser = b
      result = ImportResult(source: b.id, name: b.name)
      self.id = id
    }
  }

  let env: PluginEnv
  var job: Job?
  var nextJob = 1
  var nextRequest = 1
  var pending: [String: (Value) -> Void] = [:]
  var started = false
  var stopped = false
  var commandRegistered = false
  var registerAttempts = 0
  var dialogOpen = false
  var lastBatch: String?
  /// Counts of the last finished import (tests, `state`).
  var last: Value = .null

  init(env: PluginEnv) { self.env = env }

  // MARK: - Lifecycle

  func start() {
    env.on("files.result") { [self] v in
      if let h = pending.removeValue(forKey: v.s("request")) { h(v) }
    }
    env.on("vault.result") { [self] v in if v.s("request") == Self.passwordsRequest { passwordsDone(v) } }
    env.on("ui.action") { [self] v in action(v.s("id"), v.s("action"), v["value"]) }
    env.on("commands.run") { [self] v in if v.s("id") == Self.openCommand { openDialog() } }
    env.on("settings.action") { [self] v in
      if v.s("id") == Self.ns, v.s("key") == "import" {
        env.call("settings", "close")
        openDialog()
      }
    }
    env.timer(Self.startDelayMs, false) { [self] in startNow() }
  }

  func startNow() {
    guard !started, !stopped else { return }
    started = true
    env.call("settings", "register", [
      "id": .string(Self.ns), "section": "general", "title": "Import", "order": 55,
      "controls": [["key": "import", "type": "button", "title": "Import from another browser",
                    "subtitle": "Arc, Safari, Chrome, Firefox and more; passwords from a CSV export.", "button": ["title": "Import…"]]],
    ])
    registerCommand()
  }

  func stop() {
    stopped = true
    registerAttempts = Int.max / 2
    if dialogOpen { env.call("ui", "set", ["slot": "dialog", "tree": nil]) }
  }

  /// `commands` is optional (plugin `commandbar`) and may load later: retry every 500 ms for 30 s.
  func registerCommand() {
    if tryRegister() { return }
    env.timer(500, false) { [self] in
      registerAttempts += 1
      if !tryRegister(), registerAttempts < 60 { registerCommand() }
    }
  }

  @discardableResult
  func tryRegister() -> Bool {
    if commandRegistered { return true }
    let r = env.call("commands", "register", [
      "id": .string(Self.openCommand), "title": "Import from…", "icon": "sf:square.and.arrow.down",
      "keywords": ["import", "arc", "chrome", "safari", "firefox", "zen", "dia", "brave", "edge", "bookmarks", "history", "passwords", "switch browser"],
      "owner": .string(Self.ns),
    ])
    guard !r.isErr else { return false }
    commandRegistered = true
    return true
  }

  // MARK: - Service

  func handle(_ method: String, _ args: Value) -> Value {
    switch method {
    case "sources":
      return .array(sources().map { s in
        var v: Value = ["id": .string(s.0.id), "name": .string(s.0.name)]
        if s.1 { v.put("denied", true) }
        return v
      })
    case "run":
      return run(args.s("source"))
    case "open":
      openDialog()
      return .okay
    case "undo":
      guard let b = args.sOpt("batch") ?? lastBatch else { return .err("importer: nothing to undo") }
      return undo(b)
    case "state":
      // `imported`: some import ran (the tips plugin then stops offering one).
      let imported = !(storageGet("batches").array ?? []).isEmpty || !last.isNull
      return ["running": .bool(job != nil), "source": .str(job?.browser.id), "lastBatch": .str(lastBatch), "last": last, "imported": .bool(imported)]
    default:
      return .err("importer: unknown method " + method)
    }
  }

  // MARK: - Finding browsers

  func browser(_ id: String) -> Browser? { Self.browsers.first { $0.id == id } }

  /// What `sources` stats to see whether a browser has data here.
  static func probe(_ b: Browser) -> String {
    switch b.kind {
    case "arc": return b.root + "/StorableSidebar.json"
    case "firefox": return b.root + "/Profiles"
    default: return b.root
    }
  }

  static func chromiumRoot(_ b: Browser) -> String { b.kind == "arc" ? b.root + "/User Data" : b.root }

  /// Browsers with data on this Mac, and whether macOS denies den reading it (Safari without Full
  /// Disk Access). One `files.stat` call: cheap enough for the import card.
  func sources() -> [(Browser, Bool)] {
    let r = env.call("files", "stat", ["plugin": .string(Self.ns), "paths": .array(Self.browsers.map { .string(Self.probe($0)) })])
    guard let stats = r.array else { return [] }
    var out: [(Browser, Bool)] = []
    for (j, b) in Self.browsers.enumerated() where j < stats.count {
      let s = stats[j]
      guard s.b("exists") else { continue }
      out.append((b, s.b("denied") || !s.b("readable")))
    }
    return out
  }

  // MARK: - Dialog ("Import from…")

  static func subtitle(_ b: Browser, denied: Bool) -> String {
    if denied { return "Needs Full Disk Access: Import opens that setting" }
    switch b.id {
    case "arc": return "Spaces, pinned tabs, folders, favorites and history"
    case "zen": return "Workspaces, pinned tabs, bookmarks and history"
    case "safari", "firefox": return "Bookmarks and history"
    default: return "Bookmarks, open tabs and history"
    }
  }

  func openDialog() {
    let found = sources()
    var choices: [Value] = found.map { ["id": .string($0.0.id), "title": .string($0.0.name), "subtitle": .string(Self.subtitle($0.0, denied: $0.1)), "icon": .string($0.0.icon)] }
    choices.append(["id": "passwords", "title": "Passwords from a CSV File…", "subtitle": "Exported from Chrome, Safari, Arc, 1Password or Bitwarden", "icon": "sf:key"])
    dialogOpen = true
    env.call("ui", "set", ["slot": "dialog", "tree": [
      "type": "dialog", "id": .string(Self.dialogId), "icon": "sf:square.and.arrow.down", "iconStyle": "accent",
      "title": "Import from Another Browser",
      "message": .string(found.isEmpty ? "No other browser's data was found on this Mac. Passwords exported as a CSV file can still come over."
        : "Pick one. Nothing in it is changed or deleted, and importing again only adds what's new."),
      "choices": .array(choices),
      "buttons": [["id": "cancel", "title": "Cancel", "style": "cancel"], ["id": "import", "title": "Import", "style": "default"]],
    ]])
  }

  func closeDialog() {
    guard dialogOpen else { return }
    dialogOpen = false
    env.call("ui", "set", ["slot": "dialog", "tree": nil])
  }

  func action(_ id: String, _ action: String, _ value: Value) {
    if id == Self.dialogId && action == "button" {
      closeDialog()
      if value.s("button") == "import", let pick = value.a("choices").first?.string { _ = run(pick) }
    } else if id == Self.dialogId && action == "dismiss" {
      closeDialog()
    } else if id == Self.toastId && action == "toast", let b = lastBatch {
      _ = undo(b)
    }
  }

  // MARK: - Running an import

  func toast(_ text: String, icon: String = "sf:square.and.arrow.down", duration: Int64 = 4000, action: String? = nil) {
    var t: Value = ["type": "toast", "id": .string(Self.toastId), "text": .string(text), "icon": .string(icon), "duration": .int(duration)]
    if let action { t.put("action", .string(action)) }
    env.call("ui", "set", ["slot": "toast", "tree": t])
  }

  func run(_ source: String) -> Value {
    if source == "passwords" {
      importPasswords()
      return .okay
    }
    guard let b = browser(source) else { return .err("importer: unknown source '" + source + "'") }
    if let j = job {
      toast("Still importing from " + j.browser.name + "…")
      return .err("importer: busy")
    }
    let s = env.call("files", "stat", ["plugin": .string(Self.ns), "paths": [.string(Self.probe(b))]])[0]
    guard s.b("exists") else {
      toast("No " + b.name + " data on this Mac.", icon: "sf:exclamationmark.triangle")
      return .err("importer: no data for " + source)
    }
    if s.b("denied") || !s.b("readable") {
      // macOS keeps Safari's files behind Full Disk Access. Say it once, open the right pane.
      env.call("files", "openFullDiskAccess")
      toast("Turn on den in Full Disk Access, then import from " + b.name + " again.", icon: "sf:lock.shield", duration: 8000)
      return ["needsAccess": true]
    }
    let j = Job(b, id: nextJob)
    nextJob += 1
    job = j
    toast("Importing from " + b.name + "…", duration: 0)
    j.waiting += 1  // held until every first-level read is on its way
    switch b.kind {
    case "arc":
      read(b.root + "/StorableSidebar.json", as: "json") { [self] v in
        guard ok(v, "sidebar") else { return }
        ImportArc.parse(v["value"], into: &j.result)
      }
      chromium(Self.chromiumRoot(b), j, bookmarks: false, sessions: false)
    case "chromium": chromium(b.root, j, bookmarks: true, sessions: true)
    case "safari": safari(b.root, j)
    case "firefox": firefox(b, j)
    default: break
    }
    env.timer(Self.jobTimeoutMs, false) { [self] in
      if let cur = job, cur.id == j.id {
        env.log("importer: timed out waiting for " + String(cur.waiting) + " reads")
        pending.removeAll()
        finish(cur)
      }
    }
    settle(j)
    return .okay
  }

  /// One asynchronous `files` call; `done` runs with its `files.result`.
  func request(_ method: String, _ args: Value, _ done: @escaping (Value) -> Void) {
    guard let j = job else { return }
    let id = "importer-" + String(nextRequest)
    nextRequest += 1
    var a = args
    a.put("plugin", .string(Self.ns))
    a.put("request", .string(id))
    j.waiting += 1
    pending[id] = { [self] v in
      done(v)
      settle(j)
    }
    let r = env.call("files", method, a)
    if r.isErr, let h = pending.removeValue(forKey: id) { h(["request": .string(id), "ok": false, "error": r["error"]]) }
  }

  func read(_ path: String, as kind: String, _ done: @escaping (Value) -> Void) {
    request("read", ["path": .string(path), "as": .string(kind)], done)
  }

  func sqlite(_ path: String, _ sql: String, _ done: @escaping (Value) -> Void) {
    request("sqlite", ["path": .string(path), "sql": .string(sql), "maxRows": 20000], done)
  }

  /// Notes a failed read (den.log) and says whether `v` is usable.
  func ok(_ v: Value, _ what: String) -> Bool {
    guard v.b("ok") else {
      job?.result.problems.append(what + ": " + v.s("error"))
      return false
    }
    job?.result.readSomething = true
    return true
  }

  func settle(_ j: Job) {
    j.waiting -= 1
    if j.waiting == 0, job?.id == j.id { finish(j) }
  }

  func list(_ path: String) -> [Value] {
    env.call("files", "list", ["plugin": .string(Self.ns), "path": .string(path)]).array ?? []
  }

  func chromium(_ root: String, _ j: Job, bookmarks: Bool, sessions: Bool) {
    let profiles = Array(ImportChromium.profiles(list(root)).prefix(Self.maxProfiles))
    if profiles.isEmpty { j.result.problems.append("no profiles in " + root) }
    for p in profiles {
      let dir = root + "/" + p
      let prefix = j.browser.id + ":" + (p == "Default" ? "" : p + ":")
      if bookmarks {
        read(dir + "/Bookmarks", as: "json") { [self] v in
          guard ok(v, p + "/Bookmarks") else { return }
          let nodes = ImportChromium.bookmarks(v["value"], keyPrefix: prefix + "bm:")
          if p == "Default" || profiles.count == 1 { j.result.bookmarks = nodes + j.result.bookmarks } else if !nodes.isEmpty {
            j.result.bookmarks.append(.folder(prefix + "profile", p, nodes))
          }
        }
      }
      sqlite(dir + "/History", ImportChromium.historySQL) { [self] v in
        guard ok(v, p + "/History") else { return }
        j.result.history += ImportChromium.history(v.a("rows"))
      }
      if sessions, let s = ImportChromium.newestSession(list(dir + "/Sessions")) {
        read(dir + "/Sessions/" + s, as: "bytes") { [self] v in
          guard ok(v, p + "/Sessions"), case let .bytes(b) = v["value"] else { return }
          j.result.openTabs += ImportChromium.sessionTabs(b, keyPrefix: j.browser.id + ":tab:")
        }
      }
    }
  }

  func safari(_ root: String, _ j: Job) {
    read(root + "/Bookmarks.plist", as: "plist") { [self] v in
      guard ok(v, "Bookmarks.plist") else { return }
      j.result.bookmarks = ImportSafari.bookmarks(v["value"])
    }
    sqlite(root + "/History.db", ImportSafari.historySQL) { [self] v in
      guard ok(v, "History.db") else { return }
      j.result.history = ImportSafari.history(v.a("rows"))
    }
  }

  func firefox(_ b: Browser, _ j: Job) {
    let dir = b.root + "/Profiles"
    let candidates = list(dir).filter { $0.b("dir") }.map { dir + "/" + $0.s("name") + "/places.sqlite" }
    let stats = env.call("files", "stat", ["plugin": .string(Self.ns), "paths": .array(candidates.map { .string($0) })]).array ?? []
    guard let db = ImportFirefox.currentProfile(stats) else {
      j.result.problems.append("no places.sqlite in " + dir)
      return
    }
    let prefix = b.id + ":"
    sqlite(db, ImportFirefox.bookmarksSQL) { [self] v in
      guard ok(v, "bookmarks") else { return }
      j.result.bookmarks = ImportFirefox.bookmarks(v.a("rows"), keyPrefix: prefix)
    }
    sqlite(db, ImportFirefox.historySQL) { [self] v in
      guard ok(v, "history") else { return }
      j.result.history = ImportFirefox.history(v.a("rows"))
    }
    guard b.id == "zen" else { return }
    sqlite(db, ImportFirefox.zenTablesSQL) { [self] v in
      let tables = v.a("rows").compactMap { $0[0].string }
      guard tables.contains("zen_workspaces") else { return }
      sqlite(db, ImportFirefox.zenWorkspacesSQL) { [self] w in
        guard ok(w, "zen_workspaces") else { return }
        let workspaces = ImportFirefox.objects(w)
        guard tables.contains("zen_pins") else {
          ImportFirefox.zen(workspaces: workspaces, pins: [], into: &j.result)
          return
        }
        sqlite(db, ImportFirefox.zenPinsSQL) { [self] p in
          _ = ok(p, "zen_pins")
          ImportFirefox.zen(workspaces: workspaces, pins: ImportFirefox.objects(p), into: &j.result)
        }
      }
    }
  }

  // MARK: - Applying

  struct Counts {
    var spaces = 0
    var pinned = 0
    var today = 0
    var favorites = 0
    var bookmarks = 0
    var openTabs = 0
    var history = 0

    var total: Int { spaces + pinned + today + favorites + bookmarks + openTabs + history }

    var value: Value {
      ["spaces": .int(Int64(spaces)), "pinned": .int(Int64(pinned)), "today": .int(Int64(today)), "favorites": .int(Int64(favorites)),
       "bookmarks": .int(Int64(bookmarks)), "openTabs": .int(Int64(openTabs)), "history": .int(Int64(history))]
    }

    /// "4 spaces, 37 pinned tabs and 12,840 history entries".
    var summary: String {
      var p: [String] = []
      if spaces > 0 { p.append(ImportFormat.noun(spaces, "space", "spaces")) }
      if pinned > 0 { p.append(ImportFormat.noun(pinned, "pinned tab", "pinned tabs")) }
      if favorites > 0 { p.append(ImportFormat.noun(favorites, "favorite", "favorites")) }
      if bookmarks > 0 { p.append(ImportFormat.noun(bookmarks, "bookmark", "bookmarks")) }
      if today + openTabs > 0 { p.append(ImportFormat.noun(today + openTabs, "open tab", "open tabs")) }
      if history > 0 { p.append(ImportFormat.noun(history, "history entry", "history entries")) }
      return ImportFormat.list(p)
    }
  }

  func finish(_ j: Job) {
    guard job?.id == j.id else { return }
    job = nil
    for p in j.result.problems { env.log("importer: " + j.browser.id + ": " + p) }
    guard j.result.readSomething else {
      toast("Couldn't read " + j.browser.name + "'s data.", icon: "sf:exclamationmark.triangle", duration: 6000)
      last = ["source": .string(j.browser.id), "error": "unreadable"]
      env.emit("importer.done", last)
      return
    }
    apply(j.result)
  }

  func storageGet(_ key: String) -> Value { env.call("storage", "get", ["ns": .string(Self.ns), "key": .string(key)]) }
  func storageSet(_ key: String, _ v: Value) { env.call("storage", "set", ["ns": .string(Self.ns), "key": .string(key), "value": v]) }

  func importItems(_ batch: String, _ spaceId: String?, _ section: String, _ items: [ImportNode], folder: Value? = nil) -> Int {
    guard !items.isEmpty else { return 0 }
    var a: Value = ["batch": .string(batch), "section": .string(section), "items": .array(items.map { $0.value })]
    if let s = spaceId { a.put("spaceId", .string(s)) }
    if let f = folder { a.put("folder", f) }
    let r = env.call("tabs", "importItems", a)
    if r.isErr { env.log("importer: tabs.importItems " + section + ": " + r.s("error")) }
    return Int(r.i("tabs"))
  }

  func apply(_ r: ImportResult) {
    let batch = "import-" + String(env.now())
    var counts = Counts()
    var created: [Value] = []
    var restored: [Value] = []
    var map: Value = storageGet("spaces")
    if map.isNull { map = .object([]) }
    let current = env.call("spaces", "current").s("id")
    var list = env.call("spaces", "list").array ?? []
    for s in r.spaces {
      var sid = map.s(s.key)
      let known = !sid.isEmpty && list.contains { $0.s("id") == sid }
      if !known {
        sid = ""
        if let same = list.first(where: { Text.lower($0.s("name")) == Text.lower(s.name) }), !Self.mapped(map, same.s("id")) {
          // den's own space of the same name ("Work"): the import fills it and takes on Arc's look.
          sid = same.s("id")
          restored.append(["id": .string(sid), "icon": same["icon"], "theme": same["theme"], "profile": same["profile"]])
          var u: Value = ["id": .string(sid)]
          if !s.icon.isEmpty { u.put("icon", .string(s.icon)) }
          if let t = s.theme { u.put("theme", t) }
          if let p = s.profile { u.put("profile", .string(p)) }
          env.call("spaces", "update", u)
        } else {
          var c: Value = ["name": .string(s.name)]
          if !s.icon.isEmpty { c.put("icon", .string(s.icon)) }
          if let t = s.theme { c.put("theme", t) }
          if let p = s.profile { c.put("profile", .string(p)) }
          sid = env.call("spaces", "create", c).s("id")
          guard !sid.isEmpty else { continue }
          created.append(.string(sid))
          list = env.call("spaces", "list").array ?? list
        }
        counts.spaces += 1
        map.put(s.key, .string(sid))
      }
      counts.pinned += importItems(batch, sid, "pinned", s.pinned)
      counts.today += importItems(batch, sid, "today", s.today)
    }
    storageSet("spaces", map)
    // A favorite den already has (the same site) isn't added twice.
    var hosts: [String] = []
    for f in env.call("tabs", "list")["favorites"].array ?? [] {
      for t in f["split"] == true ? f.a("children") : [f] { hosts.append(URLs.host(t.s("url"))) }
    }
    counts.favorites = importItems(batch, nil, "favorites", r.favorites.filter { !hosts.contains(URLs.host($0.url)) })
    let home = current.isEmpty ? nil : current
    counts.bookmarks = importItems(batch, home, "pinned", r.bookmarks,
                                   folder: ["key": .string(r.source + ":bookmarks"), "title": .string(r.name + " Bookmarks"), "open": false])
    counts.openTabs = importItems(batch, home, "today", r.openTabs,
                                  folder: ["key": .string(r.source + ":tabs"), "title": .string("From " + r.name), "open": true])
    if !r.history.isEmpty {
      let h = env.call("commands", "importHistory", ["batch": .string(batch), "source": .string(r.source), "items": .array(r.history.map { $0.value })])
      if h.isErr { env.log("importer: commands.importHistory: " + h.s("error")) }
      counts.history = Int(h.i("added"))
    }
    // The space in front stays in front (creating spaces doesn't switch, but be sure).
    if !current.isEmpty, env.call("spaces", "current").s("id") != current { env.call("spaces", "switch", ["id": .string(current), "animated": false]) }
    var record: Value = ["batch": .string(batch), "source": .string(r.source), "at": .int(env.now()), "created": .array(created), "restored": .array(restored)]
    record.put("counts", counts.value)
    var batches = storageGet("batches").array ?? []
    batches.append(record)
    if batches.count > Self.maxBatches { batches.removeFirst(batches.count - Self.maxBatches) }
    storageSet("batches", .array(batches))
    last = counts.value
    last.put("source", .string(r.source))
    last.put("batch", .string(batch))
    if counts.total > 0 {
      lastBatch = batch
      toast("Imported " + counts.summary, duration: 10000, action: "Undo")
    } else {
      toast("Nothing new to import from " + r.name + ".", duration: 4000)
    }
    env.emit("importer.done", last)
  }

  static func mapped(_ map: Value, _ id: String) -> Bool {
    guard case let .object(pairs) = map else { return false }
    return pairs.contains { $0.1.string == id }
  }

  // MARK: - Undo

  func undo(_ batch: String) -> Value {
    var batches = storageGet("batches").array ?? []
    guard let i = batches.firstIndex(where: { $0.s("batch") == batch }) else { return .err("importer: no batch '" + batch + "'") }
    let rec = batches[i]
    env.call("tabs", "removeImported", ["batch": .string(batch)])
    env.call("commands", "forgetHistory", ["batch": .string(batch)])
    for s in rec.a("restored") {
      var u: Value = ["id": s["id"], "icon": .string(s.s("icon"))]
      if !s["theme"].isNull { u.put("theme", s["theme"]) }
      u.put("profile", .string(s.sOpt("profile") ?? "default"))
      env.call("spaces", "update", u)
    }
    var map = storageGet("spaces")
    for idv in rec.a("created") {
      guard let id = idv.string else { continue }
      env.call("spaces", "delete", ["id": .string(id)])
      if case let .object(pairs) = map { map = .object(pairs.filter { $0.1.string != id }) }
    }
    // Spaces it merged into keep den's own tabs; forget the mapping so a new import merges again.
    for s in rec.a("restored") { if case let .object(pairs) = map { map = .object(pairs.filter { $0.1.string != s.s("id") }) } }
    storageSet("spaces", map)
    batches.remove(at: i)
    storageSet("batches", .array(batches))
    if lastBatch == batch { lastBatch = nil }
    toast("Import undone", icon: "sf:arrow.uturn.backward", duration: 2500)
    env.emit("importer.undone", ["batch": .string(batch)])
    return .okay
  }

  // MARK: - Passwords

  func importPasswords() {
    // The panel's copy comes from here, the plugin: the host's open panel stays generic.
    let r = env.call("vault", "importFile", ["columns": Self.passwordColumns, "request": .string(Self.passwordsRequest),
                                             "message": .string("Choose a passwords export (.csv) from your browser or password manager."),
                                             "prompt": .string("Import")])
    if r.isErr { toast("Passwords can't be imported here.", icon: "sf:exclamationmark.triangle") }
  }

  func passwordsDone(_ v: Value) {
    if v.s("error") == "cancelled" { return }
    guard v.b("ok") else {
      toast(v.s("error") == "no columns" ? "That file isn't a password export (no URL and password columns)." : "Couldn't import passwords.",
            icon: "sf:exclamationmark.triangle", duration: 6000)
      return
    }
    let added = Int(v.i("added")), existing = Int(v.i("existing"))
    var text = added > 0 ? "Imported " + ImportFormat.noun(added, "password", "passwords") : "No new passwords in that file"
    if existing > 0 { text += " · " + ImportFormat.count(existing) + " already saved" }
    toast(text, icon: "sf:key.fill", duration: 6000)
    env.emit("importer.passwords", v)
  }
}
