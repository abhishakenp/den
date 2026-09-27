#if !hasFeature(Embedded)
  import CordisValue
#endif

/// The daily briefing: a summary, a checkable todo list and a ranked feed across connections.
///
/// - **Lazy.** Nothing is fetched or scheduled until a connection exists. Then the morning
///   briefing is scheduled (`schedule.daily`, 8:00 by default) and a gentle refresh runs every
///   15 min and on wake (`schedule.interval`).
/// - **Refresh**: emit `feed.refresh`; each connected provider answers with
///   `feed.items {source, items, error?}` (30 s timeout). Items are ranked into the feed.
/// - **AI**, only when `ai.availability` says so: `ai.brief` (per-source summaries, then one
///   combined brief) and `ai.todos` (guided generation over the actionable items). Otherwise the
///   summary is a plain count and every actionable item becomes a todo.
/// - **Todos** persist (storage ns `briefing`, key `todos`) with their done state; checked ones
///   are dropped a day later. Feed items stay in memory. `affinity` (how often you opened items
///   from a person, channel or repo) personalizes the ranking.
/// - **UI**: the `overlay.briefing` page (node `sheet`, style `page`), ⇧⌘B and the "Daily
///   Briefing" command. Clicking an item opens its exact message, PR or thread in a new tab.
final class BriefingCore {
  static let ns = "briefing"
  static let slot = "overlay.briefing"
  static let sheetId = "briefing"
  static let dailyId = "briefing.morning"
  static let pollId = "briefing.poll"
  static let pollMs: Int64 = 15 * 60 * 1000
  static let timeoutMs: UInt64 = 30_000
  static let maxFeed = 25
  static let maxAIItems = 30

  let env: PluginEnv
  let requests: Requests
  var items: [String: [Value]] = [:]
  var errors: [String: String] = [:]
  var waiting: [String] = []
  var refreshing = false
  var generation = 0
  var summary = ""
  var summaryState = "none"  // none | working | ai | plain
  var aiReason = ""
  var todos: [Value] = []
  var affinity: [String: Int64] = [:]
  var updatedAt: Int64 = 0
  var seenAt: Int64 = 0
  var isOpen = false
  var scheduled = false
  var hour: Int64 = 8
  var minute: Int64 = 0
  var enabled = true
  var registerAttempts = 0
  var retrying = false
  var commandRegistered = false
  /// Channels and repos the user marked important: `[{key, title, source}]` (storage key
  /// `important`). Their items rank above everything else and are never cut from the feed or the
  /// summary. Keys come from feed items' `importantKey` (`slack:<team>:<channel>`, `github:<owner/repo>`).
  var important: [Value] = []
  var importantCommands: [String] = []
  var settingsObserved = false
  static let maxImportantCommands = 30
  static let importantBoost: Int64 = 1000

  init(env: PluginEnv) {
    self.env = env
    requests = Requests(env: env, prefix: "briefing")
  }

  func load(_ key: String) -> Value { env.call("storage", "get", ["ns": .string(Self.ns), "key": .string(key)]) }
  func store(_ key: String, _ v: Value) { env.call("storage", "set", ["ns": .string(Self.ns), "key": .string(key), "value": v]) }

  static let defaultShortcut = "cmd+shift+b"
  var shortcut = ""

  func bindShortcut(_ chord: String) {
    if !shortcut.isEmpty { env.call("keys", "unbind", ["chord": .string(shortcut)]) }
    shortcut = chord
    if !chord.isEmpty { env.call("keys", "bind", ["chord": .string(chord), "event": "briefing.key.open", "title": "Daily Briefing", "menu": "View"]) }
  }

  /// Settings > Briefing (host `settings` service): the morning briefing, its time and shortcut.
  func registerSettings() {
    var times: [Value] = []
    var m: Int64 = 5 * 60
    while m <= 12 * 60 {
      times.append(["value": .int(m), "title": .string(Self.clock(m))])
      m += 30
    }
    let now = hour * 60 + minute
    if now % 30 != 0 || now < 5 * 60 || now > 12 * 60 { times.append(["value": .int(now), "title": .string(Self.clock(now))]) }
    let r = env.call("settings", "register", [
      "id": .string(Self.ns), "title": "Briefing", "icon": "sf:sun.horizon", "order": 40,
      "controls": [
        ["key": "enabled", "type": "toggle", "title": "Morning briefing",
         "subtitle": "Once a day den gathers what needs you from your connections and lets you know. Only while something is connected.", "default": .bool(enabled)],
        ["key": "time", "type": "choice", "title": "Time", "options": .array(times), "default": .int(now)],
        ["key": "shortcut", "type": "shortcut", "title": "Open the briefing", "default": .string(Self.defaultShortcut)],
        importantControl(),
      ],
    ])
    guard !r.isErr, !settingsObserved else { return }
    settingsObserved = true
    let v = env.call("settings", "get", ["id": .string(Self.ns)])
    for k in ["enabled", "time", "shortcut"] { applySetting(k, v[k]) }
    env.on("settings.changed") { [self] v in if v.s("id") == Self.ns { applySetting(v.s("key"), v["value"]) } }
    env.on("settings.action") { [self] v in
      guard v.s("id") == Self.ns, v.s("key") == Self.importantSettingKey else { return }
      let key = v.s("item")
      switch v.s("button") {
      case "remove": setImportant(key, title: "", source: "", on: false)
      case "mark": setImportant(key, title: "", source: "", on: true)
      default: break
      }
    }
  }

  static let importantSettingKey = "important"

  /// Settings > Briefing > Important channels and repos: the marked ones (Remove), then the
  /// channels and repos seen in the current feed (Mark Important).
  func importantControl() -> Value {
    var items: [Value] = important.map { i in
      ["id": i["key"], "title": i["title"], "subtitle": .string(Self.sourceName(i.s("source")) + " · Important"), "icon": "sf:star.fill",
       "buttons": [["id": "remove", "title": "Remove"]]]
    }
    for c in candidates().prefix(Self.maxImportantCommands) {
      items.append(["id": c["key"], "title": c["title"], "subtitle": .string(Self.sourceName(c.s("source")) + " · in your feed"), "icon": "sf:star",
                    "buttons": [["id": "mark", "title": "Mark Important", "style": "primary"]]])
    }
    return ["key": .string(Self.importantSettingKey), "type": "list", "title": "Important channels and repos",
            "subtitle": "Their messages, reviews and CI come first in the briefing and are never left out of the summary.",
            "items": .array(items), "empty": "Channels and repos from your feed show up here once Slack or GitHub is connected."]
  }

  static func sourceName(_ s: String) -> String { s == "slack" ? "Slack" : s == "github" ? "GitHub" : s }

  func applySetting(_ key: String, _ v: Value) {
    switch key {
    case "enabled":
      guard let b = v.bool, b != enabled else { return }
      _ = handle("settings", ["enabled": .bool(b)])
    case "time":
      guard let t = v.int, t != hour * 60 + minute else { return }
      _ = handle("settings", ["hour": .int(t / 60), "minute": .int(t % 60)])
    case "shortcut":
      guard let c = v.string, c != shortcut else { return }
      bindShortcut(c)
      store("shortcut", .string(c))
    default: break
    }
  }

  /// "8:00 AM" for minutes since midnight.
  static func clock(_ m: Int64) -> String {
    let h = m / 60, mm = m % 60
    let h12 = h % 12 == 0 ? 12 : h % 12
    return String(h12) + ":" + (mm < 10 ? "0" : "") + String(mm) + (h < 12 ? " AM" : " PM")
  }

  func start() {
    todos = load("todos").array ?? []
    important = load("important").array ?? []
    if case let .object(pairs) = load("affinity") { for (k, v) in pairs { affinity[k] = v.int ?? 0 } }
    let s = load("settings")
    hour = s.i("hour", 8)
    minute = s.i("minute", 0)
    enabled = s.b("enabled", true)
    seenAt = load("seenAt").int ?? 0
    bindShortcut(load("shortcut").string ?? Self.defaultShortcut)
    env.on("briefing.key.open") { [self] _ in isOpen ? close() : open() }
    registerSettings()
    env.on("commands.run") { [self] v in command(v.s("id")) }
    env.on("feed.items") { [self] v in received(v) }
    env.on("connections.changed") { [self] _ in
      updateSchedule()
      if connected().isEmpty {
        items = [:]
        errors = [:]
        summary = ""
        summaryState = "none"
      } else if isOpen {
        refresh(reason: "connected")
      }
      render()
    }
    env.on("schedule.fire") { [self] v in fired(v.s("id"), v.s("reason")) }
    env.on("ui.action") { [self] v in action(v) }
    updateSchedule()
    registerCommand()
  }

  // MARK: Service

  func handle(_ method: String, _ args: Value) -> Value {
    switch method {
    case "open": open(); return .okay
    case "close": close(); return .okay
    case "refresh": refresh(reason: args.sOpt("reason") ?? "manual"); return .okay
    case "toggle": toggle(args.s("id"), done: args.b("done", true)); return .okay
    case "important":
      let key = args.s("key")
      guard !key.isEmpty else { return .err("briefing: important needs key") }
      setImportant(key, title: args.s("title"), source: args.s("source"), on: args.b("on", true))
      return .okay
    case "importantList": return .array(important)
    case "settings":
      if !args["hour"].isNull { hour = max(0, min(23, args.i("hour"))) }
      if !args["minute"].isNull { minute = max(0, min(59, args.i("minute"))) }
      if !args["enabled"].isNull { enabled = args.b("enabled", true) }
      store("settings", ["hour": .int(hour), "minute": .int(minute), "enabled": .bool(enabled)])
      scheduled = false
      updateSchedule()
      render()
      env.call("settings", "set", ["id": .string(Self.ns), "key": "enabled", "value": .bool(enabled)])
      env.call("settings", "set", ["id": .string(Self.ns), "key": "time", "value": .int(hour * 60 + minute)])
      return ["hour": .int(hour), "minute": .int(minute), "enabled": .bool(enabled)]
    case "state":
      return ["open": .bool(isOpen), "refreshing": .bool(refreshing), "summary": .string(summary), "summaryState": .string(summaryState),
              "todos": .array(todos), "feed": .array(feed()), "errors": .object(errors.keys.sorted().map { ($0, .string(errors[$0]!)) }),
              "updatedAt": .int(updatedAt), "scheduled": .bool(scheduled)]
    default: return .err("briefing: unknown method " + method)
    }
  }

  func connected() -> [Value] { (env.call("connections", "list").array ?? []).filter { $0.b("connected") } }

  // MARK: Schedule

  func updateSchedule() {
    let any = !connected().isEmpty
    if any && !scheduled {
      scheduled = true
      if enabled {
        env.call("schedule", "daily", ["id": .string(Self.dailyId), "hour": .int(hour), "minute": .int(minute)])
      } else {
        env.call("schedule", "cancel", ["id": .string(Self.dailyId)])
      }
      env.call("schedule", "interval", ["id": .string(Self.pollId), "ms": .int(Self.pollMs), "wake": true])
    } else if !any && scheduled {
      scheduled = false
      env.call("schedule", "cancel", ["id": .string(Self.dailyId)])
      env.call("schedule", "cancel", ["id": .string(Self.pollId)])
    }
  }

  func fired(_ id: String, _ reason: String) {
    guard !connected().isEmpty else { return }
    if id == Self.dailyId {
      refresh(reason: "morning") { [self] in
        env.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": "Your morning briefing is ready  ⇧⌘B", "icon": "sf:sun.max.fill", "duration": 6000]])
      }
    } else if id == Self.pollId {
      refresh(reason: reason)
    }
  }

  // MARK: Refresh

  var onRefreshed: [() -> Void] = []
  var rerun = false

  func refresh(reason: String, _ done: (() -> Void)? = nil) {
    let sources = connected().map { $0.s("id") }
    if let done { onRefreshed.append(done) }
    guard !sources.isEmpty else {
      finishCallbacks()
      render()
      return
    }
    guard !refreshing else {
      rerun = true  // e.g. a second connection arrived mid-refresh
      return
    }
    refreshing = true
    generation += 1
    let gen = generation
    waiting = sources
    render()
    env.emit("feed.refresh", ["reason": .string(reason), "sources": .array(sources.map { .string($0) })])
    env.timer(Self.timeoutMs, false) { [self] in
      guard refreshing, generation == gen else { return }
      for s in waiting { errors[s] = "timed out" }
      waiting = []
      compose()
    }
  }

  func received(_ v: Value) {
    let s = v.s("source")
    guard !s.isEmpty else { return }
    items[s] = v.a("items")
    if let e = v.sOpt("error") { errors[s] = e } else { errors[s] = nil }
    waiting.removeAll { $0 == s }
    if refreshing && waiting.isEmpty { compose() } else if !refreshing { render() }
    importantChanged(persist: false)
  }

  // MARK: Important channels and repos

  var importantKeys: Set<String> { Set(important.map { $0.s("key") }) }

  /// Channels and repos seen in the current feed that aren't marked yet, newest first.
  func candidates() -> [Value] {
    let marked = importantKeys
    var latest: [String: Value] = [:]
    for it in allItems() {
      let k = it.s("importantKey")
      guard !k.isEmpty, !marked.contains(k) else { continue }
      if let old = latest[k], old.i("ts") >= it.i("ts") { continue }
      latest[k] = ["key": .string(k), "title": .string(it.sOpt("importantTitle") ?? it.s("where")), "source": .string(it.s("source")), "ts": .int(it.i("ts"))]
    }
    return latest.values.sorted { a, b in a.i("ts") != b.i("ts") ? a.i("ts") > b.i("ts") : a.s("key") < b.s("key") }
  }

  func setImportant(_ key: String, title: String, source: String, on: Bool) {
    let was = importantKeys.contains(key)
    if on && !was {
      var t = title, src = source
      if t.isEmpty || src.isEmpty, let c = candidates().first(where: { $0.s("key") == key }) {
        if t.isEmpty { t = c.s("title") }
        if src.isEmpty { src = c.s("source") }
      }
      important.append(["key": .string(key), "title": .string(t.isEmpty ? key : t), "source": .string(src)])
    } else if !on && was {
      important.removeAll { $0.s("key") == key }
    } else {
      return
    }
    importantChanged(persist: true)
    render()
  }

  func importantChanged(persist: Bool) {
    if persist { store("important", .array(important)) }
    registerSettings()
    registerImportantCommands()
  }

  /// "Mark #eng as Important" for recent channels and repos in the feed, "Unmark …" for marked
  /// ones, bounded; re-registered when the feed or the set changes.
  func registerImportantCommands() {
    guard commandRegistered else { return }  // the commands plugin isn't there (yet)
    var want: [(String, String, String)] = []
    for i in important.prefix(Self.maxImportantCommands) {
      want.append(("briefing.unmark:" + i.s("key"), "Unmark " + i.s("title") + " as Important", "sf:star.slash"))
    }
    for c in candidates().prefix(Self.maxImportantCommands) {
      want.append(("briefing.mark:" + c.s("key"), "Mark " + c.s("title") + " as Important", "sf:star"))
    }
    for id in importantCommands where !want.contains(where: { $0.0 == id }) { env.call("commands", "unregister", ["id": .string(id)]) }
    importantCommands.removeAll { id in !want.contains { $0.0 == id } }
    for w in want where !importantCommands.contains(w.0) {
      let r = env.call("commands", "register", ["id": .string(w.0), "title": .string(w.1), "icon": .string(w.2), "owner": "briefing",
                                                  "keywords": ["important", "priority", "star", "channel", "repo", "briefing"]])
      if r.isErr { return }
      importantCommands.append(w.0)
    }
  }

  func command(_ id: String) {
    if id == "briefing.open" { open(); return }
    if id == "briefing.important" { env.call("settings", "open", ["section": .string(Self.ns)]); return }
    if Text.hasPrefix(id, "briefing.mark:") { setImportant(Text.dropPrefix(id, "briefing.mark:"), title: "", source: "", on: true); return }
    if Text.hasPrefix(id, "briefing.unmark:") { setImportant(Text.dropPrefix(id, "briefing.unmark:"), title: "", source: "", on: false) }
  }

  func finishCallbacks() {
    if rerun {
      rerun = false
      refresh(reason: "rerun")
      return
    }
    let cbs = onRefreshed
    onRefreshed = []
    for cb in cbs { cb() }
  }

  func allItems() -> [Value] {
    let live = connected().map { $0.s("id") }
    var out: [Value] = []
    for k in items.keys.sorted() where live.contains(k) { out += items[k]! }
    return out
  }

  func compose() {
    refreshing = false
    updatedAt = env.now()
    let keys = importantKeys
    let ranked = Self.rank(allItems(), now: env.now(), affinity: affinity, important: keys)
    let actionable = ranked.filter { $0.b("actionable") }
    pruneTodos()
    let ai = env.call("ai", "availability")
    if ai.b("available") {
      summaryState = "working"
      render()
      let sources: [Value] = connected().compactMap { c in
        let lines = Self.aiLines(items[c.s("id")] ?? [], important: keys, max: Self.maxAIItems)
        return lines.isEmpty ? nil : ["name": .string(c.s("title")), "items": .array(lines.map { .string($0) })]
      }
      let todoInput: [Value] = Self.keep(actionable, max: 12, important: keys).map { ["id": .string($0.s("id")), "text": .string($0.s("summary"))] }
      let gen = generation
      let briefStep: (@escaping () -> Void) -> Void = { [self] next in
        guard !sources.isEmpty else {
          summary = "You're all caught up."
          summaryState = "ai"
          return next()
        }
        requests.call("ai", "brief", ["sources": .array(sources)]) { [self] r in
          guard gen == generation else { return next() }
          if r.b("ok") && !r.s("text").isEmpty {
            summary = r.s("text")
            summaryState = "ai"
          } else {
            summary = Self.plainSummary(ranked)
            summaryState = "plain"
            aiReason = r.sOpt("reason") ?? r.s("error")
          }
          render()
          next()
        }
      }
      let todoStep: (@escaping () -> Void) -> Void = { [self] next in
        guard !todoInput.isEmpty else { return next() }
        requests.call("ai", "todos", ["items": .array(todoInput), "max": 8]) { [self] r in
          guard gen == generation else { return next() }
          if r.b("ok") {
            var titles: [String: String] = [:]
            for t in r.a("todos") { titles[t.s("item")] = t.s("title") }
            let picked = actionable.filter { titles[$0.s("id")] != nil }
            addTodos(picked.map { ($0, titles[$0.s("id")]!) })
          } else {
            addTodos(actionable.map { ($0, $0.s("title")) })
          }
          next()
        }
      }
      sequence([todoStep, briefStep]) { [self] in
        finishCallbacks()
        render()
      }
    } else {
      aiReason = ai.s("reason")
      summary = Self.plainSummary(ranked)
      summaryState = "plain"
      addTodos(actionable.map { ($0, $0.s("title")) })
      finishCallbacks()
      render()
    }
  }

  /// "2 review requests, 1 failing PR and 3 unread DMs." (no Apple Intelligence).
  static func plainSummary(_ items: [Value]) -> String {
    var counts: [(String, Int, String, String)] = [
      ("review", 0, "review request", "review requests"), ("dm", 0, "unread DM", "unread DMs"),
      ("thread", 0, "thread waiting for you", "threads waiting for you"), ("ci", 0, "PR with failing CI", "PRs with failing CI"),
      ("mention", 0, "mention", "mentions"), ("assigned", 0, "assigned issue", "assigned issues"),
    ]
    for it in items {
      for j in 0..<counts.count where counts[j].0 == it.s("kind") { counts[j].1 += 1 }
    }
    let parts = counts.filter { $0.1 > 0 }.map { String($0.1) + " " + ($0.1 == 1 ? $0.2 : $0.3) }
    if parts.isEmpty { return "You're all caught up." }
    if parts.count == 1 { return parts[0] + "." }
    var s = ""
    for (i, p) in parts.enumerated() {
      if i > 0 { s += i == parts.count - 1 ? " and " : ", " }
      s += p
    }
    return s + "."
  }

  // MARK: Ranking

  static func base(_ kind: String) -> Int64 {
    switch kind {
    case "review": return 50
    case "dm": return 46
    case "thread": return 44
    case "ci": return 40
    case "mention": return 34
    case "assigned": return 22
    default: return 10
    }
  }

  /// Kind first (what needs you), then recency (up to +24 within the last day), then affinity
  /// (+3 per earlier open of the same person or place, at most +15).
  static func score(_ item: Value, now: Int64, affinity: [String: Int64], important: Set<String> = []) -> Int64 {
    var s = base(item.s("kind"))
    if isImportant(item, important) { s += importantBoost }
    let ts = item.i("ts")
    if ts > 0 { s += max(0, 24 - (now - ts) / 3_600_000) }
    let a = (affinity["actor:" + item.s("actor")] ?? 0) + (affinity["where:" + item.s("where")] ?? 0)
    s += min(15, 3 * a)
    return s
  }

  static func isImportant(_ item: Value, _ important: Set<String>) -> Bool {
    let k = item.s("importantKey")
    return !k.isEmpty && important.contains(k)
  }

  /// The first `max` of a ranked list, plus every important item past it (they're never cut).
  static func keep(_ ranked: [Value], max: Int, important: Set<String>) -> [Value] {
    var out: [Value] = []
    for (i, it) in ranked.enumerated() where i < max || isImportant(it, important) { out.append(it) }
    return out
  }

  /// One source's lines for the AI brief: every important one first (marked as such), then the
  /// rest up to `max` in total.
  static func aiLines(_ items: [Value], important: Set<String>, max: Int) -> [String] {
    let imp = items.filter { isImportant($0, important) && !$0.s("summary").isEmpty }.map { "Important: " + $0.s("summary") }
    let rest = items.filter { !isImportant($0, important) && !$0.s("summary").isEmpty }.map { $0.s("summary") }
    return imp + Array(rest.prefix(Swift.max(0, max - imp.count)))
  }

  static func rank(_ items: [Value], now: Int64, affinity: [String: Int64], important: Set<String> = []) -> [Value] {
    let scored = items.map { ($0, score($0, now: now, affinity: affinity, important: important)) }
    let order = Array(0..<scored.count).sorted {
      let a = scored[$0], b = scored[$1]
      if a.1 != b.1 { return a.1 > b.1 }
      if a.0.i("ts") != b.0.i("ts") { return a.0.i("ts") > b.0.i("ts") }
      return $0 < $1
    }
    return order.map { scored[$0].0 }
  }

  func feed() -> [Value] {
    let keys = importantKeys
    return Self.keep(Self.rank(allItems(), now: env.now(), affinity: affinity, important: keys), max: Self.maxFeed, important: keys)
  }

  // MARK: Todos

  func addTodos(_ picked: [(Value, String)]) {
    var changed = false
    for (it, title) in picked {
      let id = it.s("id")
      if todos.contains(where: { $0.s("id") == id }) { continue }
      todos.append(["id": .string(id), "title": .string(title), "detail": .string(it.s("detail")), "url": .string(it.s("url")),
                    "source": .string(it.s("source")), "icon": .string(it.s("icon")), "done": false, "added": .int(env.now())])
      changed = true
    }
    if changed { store("todos", .array(todos)) }
  }

  /// Checked todos are kept for a day, so today's progress stays visible.
  func pruneTodos() {
    let now = env.now()
    let before = todos.count
    todos.removeAll { $0.b("done") && now - $0.i("doneAt") > 86_400_000 }
    if todos.count != before { store("todos", .array(todos)) }
  }

  func toggle(_ id: String, done: Bool) {
    todos = todos.map { t in
      guard t.s("id") == id else { return t }
      var t = t
      t.put("done", .bool(done))
      t.put("doneAt", done ? .int(env.now()) : .null)
      return t
    }
    store("todos", .array(todos))
    render()
  }

  func openItem(url: String, actor: String, where_: String) {
    guard !url.isEmpty else { return }
    for k in ["actor:" + actor, "where:" + where_] where k.count > 6 { affinity[k] = min(20, (affinity[k] ?? 0) + 1) }
    store("affinity", .object(affinity.keys.sorted().map { ($0, .int(affinity[$0]!)) }))
    env.call("tabs", "open", ["url": .string(url)])
    close()
  }

  // MARK: UI

  func open() {
    isOpen = true
    render()
    // Stale or never loaded: refresh on open.
    if !connected().isEmpty && (updatedAt == 0 || env.now() - updatedAt > 5 * 60 * 1000) { refresh(reason: "open") }
  }

  func close() {
    guard isOpen else { return }
    isOpen = false
    seenAt = env.now()
    store("seenAt", .int(seenAt))
    env.call("ui", "set", ["slot": .string(Self.slot), "tree": nil])
  }

  func greeting(_ hour: Int64) -> String {
    if hour < 5 { return "Good evening" }
    if hour < 12 { return "Good morning" }
    if hour < 18 { return "Good afternoon" }
    return "Good evening"
  }

  static let timeOptions: [Value] = [6, 7, 8, 9, 10, 11].map { h in ["id": .string(String(h) + ":00"), "title": .string(String(h) + ":00 AM")] }

  func tree() -> Value {
    let clock = env.call("schedule", "clock")
    let conns = connected()
    let providers = env.call("connections", "list").array ?? []
    var children: [Value] = []
    var sub = clock.s("date")
    if refreshing {
      sub += " · Refreshing…"
    } else if updatedAt > 0 {
      sub += " · Updated " + env.call("schedule", "clock", ["ms": .int(updatedAt)]).s("time")
    }
    children.append(["type": "heading", "id": "briefing.greeting", "text": .string(greeting(clock.i("hour", 9))), "subtitle": .string(sub)])

    if conns.isEmpty {
      children.append(["type": "paragraph", "id": "briefing.empty", "icon": "sf:link",
                       "text": "Connect Slack or GitHub to get a morning briefing: unread DMs, mentions, threads waiting for you, review requests and failing CI, with a todo list you can check off. Sign in to the site in den once, and den picks it up. Nothing leaves this Mac except requests to Slack and GitHub themselves."])
      let buttons: [Value] = providers.map { p in
        ["type": "actionButton", "id": .string("briefing.connect:" + p.s("id")), "title": .string("Connect " + p.s("title")),
         "icon": .string(p.s("icon")), "style": .string(p.b("pending") ? "secondary" : "primary")]
      }
      if !buttons.isEmpty { children.append(["type": "buttonRow", "id": "briefing.connectRow", "children": .array(buttons)]) }
      let pending = providers.filter { $0.b("pending") }.map { $0.s("title") }
      if !pending.isEmpty {
        children.append(["type": "paragraph", "id": "briefing.pending", "style": "secondary", "icon": "sf:hourglass",
                         "text": .string("Waiting for you to sign in to " + pending[0] + " in the tab that just opened…")])
      }
      return sheet(children)
    }

    // Summary.
    var text = summary
    var icon = "sf:sparkles"
    var style = "body"
    switch summaryState {
    case "working":
      text = summary.isEmpty ? "Summarizing on this Mac…" : summary
    case "plain":
      icon = "sf:list.bullet"
      text = summary + (aiReason.isEmpty ? "" : "  Summaries need Apple Intelligence, which isn't available (" + aiReason + ").")
    case "none":
      text = refreshing ? "Checking " + conns.map { $0.s("title") }.joined(separator: " and ") + "…" : "Press refresh to build your briefing."
      style = "secondary"
    default: break
    }
    children.append(["type": "paragraph", "id": "briefing.summary", "icon": .string(icon), "style": .string(style), "text": .string(text)])
    for k in errors.keys.sorted() {
      let name = providers.first { $0.s("id") == k }?.s("title") ?? k
      children.append(["type": "paragraph", "id": .string("briefing.error:" + k), "style": "caption", "icon": "sf:exclamationmark.triangle",
                       "text": .string(name + ": " + errors[k]!)])
    }

    // Todos: open first, then done.
    let open = todos.filter { !$0.b("done") }, done = todos.filter { $0.b("done") }
    let rows: [Value] = (open + done).map { t in
      ["type": "todoRow", "id": .string("briefing.todo:" + t.s("id")), "title": .string(t.s("title")), "subtitle": .string(t.s("detail")),
       "icon": .string(t.s("icon")), "done": .bool(t.b("done")), "url": .string(t.s("url"))]
    }
    let accessory = todos.isEmpty ? "" : String(done.count) + " of " + String(todos.count) + " done"
    var todoSection: Value = ["type": "section", "id": "briefing.todos", "title": "To do", "accessory": .string(accessory), "children": .array(rows)]
    if rows.isEmpty { todoSection.put("children", [["type": "paragraph", "id": "briefing.todos.empty", "style": "secondary", "text": "Nothing to do right now."]]) }
    children.append(todoSection)

    // Feed.
    let now = env.now()
    let feedRows: [Value] = feed().map { it in
      ["type": "feedRow", "id": .string("briefing.feed:" + it.s("id")), "title": .string(it.s("title")), "subtitle": .string(it.s("detail")),
       "icon": .string(it.s("icon")), "time": .string(Web.ago(it.i("ts"), now: now)), "badge": .string(it.s("badge")),
       "unread": .bool(it.i("ts") > seenAt)]
    }
    var feedSection: Value = ["type": "section", "id": "briefing.feed", "title": "For you", "accessory": .string(conns.map { $0.s("title") }.joined(separator: " · ")),
                              "children": .array(feedRows)]
    if feedRows.isEmpty { feedSection.put("children", [["type": "paragraph", "id": "briefing.feed.empty", "style": "secondary", "text": .string(refreshing ? "Loading…" : "Nothing new.")]]) }
    children.append(feedSection)

    // Settings.
    let time = String(hour) + ":" + (minute < 10 ? "0" : "") + String(minute)
    children.append(["type": "section", "id": "briefing.settings", "title": "Morning briefing", "children": [
      ["type": "toggleRow", "id": "briefing.enabled", "title": "Prepare a briefing every morning", "subtitle": "Refreshes at this time and tells you when it's ready", "on": .bool(enabled)],
      ["type": "choiceRow", "id": "briefing.time", "title": "Time", "options": .array(Self.timeOptions), "selected": .string(time)],
    ]])
    return sheet(children)
  }

  func sheet(_ children: [Value]) -> Value {
    ["type": "sheet", "id": .string(Self.sheetId), "style": "page", "title": "Briefing", "icon": "sf:sun.max",
     "headerButtons": [["id": "briefing.refresh", "icon": "sf:arrow.clockwise", "tooltip": "Refresh"],
                       ["id": "briefing.connections", "icon": "sf:gearshape", "tooltip": "Connections"]],
     "children": .array(children)]
  }

  func render() {
    guard isOpen else { return }
    env.call("ui", "set", ["slot": .string(Self.slot), "tree": tree()])
  }

  func action(_ v: Value) {
    let id = v.s("id"), act = v.s("action")
    if id == Self.sheetId && act == "dismiss" { close(); return }
    if id == "briefing.refresh" { refresh(reason: "manual"); return }
    if id == "briefing.connections" { env.call("connections", "open"); return }
    if Text.hasPrefix(id, "briefing.connect:") {
      env.call("connections", "connect", ["id": .string(Text.dropPrefix(id, "briefing.connect:"))])
      render()
      return
    }
    if Text.hasPrefix(id, "briefing.todo:") {
      let tid = Text.dropPrefix(id, "briefing.todo:")
      if act == "toggle" { toggle(tid, done: v["value"].b("done", true)) }
      if act == "open", let t = todos.first(where: { $0.s("id") == tid }) {
        let it = allItems().first { $0.s("id") == tid }
        openItem(url: t.s("url"), actor: it?.s("actor") ?? "", where_: it?.s("where") ?? "")
      }
      return
    }
    if Text.hasPrefix(id, "briefing.feed:"), act == "open" {
      let fid = Text.dropPrefix(id, "briefing.feed:")
      if let it = allItems().first(where: { $0.s("id") == fid }) { openItem(url: it.s("url"), actor: it.s("actor"), where_: it.s("where")) }
      return
    }
    if id == "briefing.enabled", act == "toggle" { _ = handle("settings", ["enabled": .bool(v["value"].b("on", true))]); return }
    if id == "briefing.time", act == "select" {
      let b = Array(v["value"].s("option").utf8)
      guard let colon = b.firstIndex(of: 58), let h = Text.int(String(decoding: b[..<colon], as: UTF8.self)),
        let m = Text.int(String(decoding: b[(colon + 1)...], as: UTF8.self))
      else { return }
      _ = handle("settings", ["hour": .int(Int64(h)), "minute": .int(Int64(m))])
    }
  }

  // MARK: Commands

  func registerCommand() {
    if tryRegister() { return }
    guard !retrying, registerAttempts < 60 else { return }
    retrying = true
    env.timer(500, false) { [self] in
      retrying = false
      registerAttempts += 1
      registerCommand()
    }
  }

  func tryRegister() -> Bool {
    if commandRegistered { return true }
    let r = env.call("commands", "register", ["id": "briefing.open", "title": "Daily Briefing", "icon": "sf:sun.max", "shortcut": "⇧⌘B",
                                               "owner": "briefing", "keywords": ["briefing", "todo", "feed", "today", "morning", "summary", "slack", "github"]])
    commandRegistered = !r.isErr
    if commandRegistered {
      env.call("commands", "register", ["id": "briefing.important", "title": "Important Channels and Repos…", "icon": "sf:star", "owner": "briefing",
                                         "keywords": ["important", "priority", "slack", "github", "channel", "repo", "briefing", "settings"]])
      registerImportantCommands()
    }
    return commandRegistered
  }
}
