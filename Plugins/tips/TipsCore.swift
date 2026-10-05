#if !hasFeature(Embedded)
  import CordisValue
#endif

/// den's onboarding (docs/guide/_in-app-tips.md): nothing gates starting to browse.
///
/// - **Tour card.** From the second launch, a small card above the sidebar footer ("New to den?
///   Take a 1-minute tour", Start / ×). × ends it for good. The tour is five steps in the same
///   card, each with Next and Skip tour; a step completes early when you do the thing.
/// - **Import card.** Only when a plugin provides the `importer` service (see `importSources`):
///   one quiet card with a one-click import. Hidden otherwise.
/// - **Tips.** One-time toasts that teach a gesture when it's useful. Each shows at most once and
///   never after you did the thing on your own; at most one per 10 minutes and three a day, never
///   in the first minute after launch or while the command bar, a dialog or a sheet is open.
/// - One switch turns all of it off: Settings ▸ General ▸ Show tips, "Don't Show Tips" in the
///   command bar, and the button on every tip.
///
/// Cost: at launch it reads its storage and subscribes to events; the Settings row, commands and
/// cards wait `startDelayMs`. Handlers are a few comparisons, and stop at once for a tip that's done.
final class TipsCore {
  static let ns = "tips"
  static let toastId = "tips.tip"
  static let startDelayMs: UInt64 = 1500
  static let quietStartMs: Int64 = 60_000
  static let minGapMs: Int64 = 600_000
  static let perDay: Int64 = 3
  static let tipDurationMs: Int64 = 6000
  static let dayMs: Int64 = 86_400_000
  static let toggleCommand = "tips.toggle"
  static let tourCommand = "tips.tour"

  struct Tip {
    let key: String
    let text: String
  }

  /// Every tip's text, in one table (reviewed and translated in one place). The triggers and
  /// retiring events are wired in `listen()`.
  static let tips: [Tip] = [
    Tip(key: "reopenClosed", text: "Closed tabs go to the Library. ⇧⌘T brings the last one back."),
    Tip(key: "clearUndo", text: "⇧⌘K clears all of Today. ⌃Z undoes it."),
    Tip(key: "edgeReveal", text: "Move to the left edge of the window to bring the sidebar back."),
    Tip(key: "resetWidth", text: "Double-click the sidebar edge to reset its width."),
    Tip(key: "swipeSpaces", text: "Swipe with two fingers in the sidebar to switch spaces."),
    Tip(key: "spaceMenu", text: "Right-click a space for its icon, theme and more."),
    Tip(key: "renameSpace", text: "Next time, just double-click the space's name."),
    Tip(key: "reorderSpaces", text: "Drag space icons in the footer to reorder them."),
    Tip(key: "peekReopen", text: "Closed it by mistake? ⌘Z brings it back."),
    Tip(key: "splitKeys", text: "⌃⇧1–4 focus a pane. ⌃⇧- closes the focused one."),
    Tip(key: "prPeek", text: "Hover a PR tab any time for its checks and reviews."),
    Tip(key: "editUrl", text: "⌘L edits the address from anywhere."),
    Tip(key: "copyMarkdown", text: "⌥⇧⌘C copies the link as Markdown."),
    Tip(key: "briefingKey", text: "⇧⌘B opens your briefing any time."),
    // `{keyword}` and `{name}`: the site search the command bar matched (`commands.keywordHint`).
    Tip(key: "siteKeyword", text: "Type {keyword}, then Tab, to search {name} directly."),
  ]

  struct Step {
    let text: String
    let done: String  // Next or Done
  }

  static let steps: [Step] = [
    Step(text: "New tabs land in Today and archive themselves after a day. ⌘D pins one to keep it.", done: "Next"),
    Step(text: "⌘T does everything: tabs, the web, commands and settings. Try typing “dark”.", done: "Next"),
    Step(text: "Spaces keep work and life apart. Swipe with two fingers in the sidebar to switch.", done: "Next"),
    Step(text: "⇧-click any link to Peek at it without leaving the page.", done: "Next"),
    Step(text: "Closed something? ⇧⌘T brings it back. Everything else is in the Library, ⇧⌘L.", done: "Done"),
  ]

  let env: PluginEnv
  var enabled = true
  var tour = "new"  // new | dismissed | done
  var importState = ""  // "" | dismissed | done
  var launches: Int64 = 0
  var startedAt: Int64 = 0
  var lastTipAt: Int64 = 0
  var day: Int64 = 0
  var dayCount: Int64 = 0
  var shown = Set<String>()
  var retired = Set<String>()
  var counts: [String: Int64] = [:]
  var saveScheduled = false
  var started = false
  var stopped = false
  var commandsRegistered = false
  var registerAttempts = 0

  /// What the notice card shows: nil, "tour", "import" or "step".
  var card: String?
  var step: Int?
  var showing: String?  // the tip on screen
  var importSources: [Value] = []
  var spaceCount = -1
  var peekOpenedAt: Int64 = 0
  var rowCloses: [Int64] = []

  init(env: PluginEnv) { self.env = env }

  // MARK: - Lifecycle

  func start() {
    startedAt = env.now()
    load()
    launches += 1
    env.call("storage", "set", ["ns": .string(Self.ns), "key": "launches", "value": .int(launches)])
    listen()
    env.timer(Self.startDelayMs, false) { [self] in startNow() }
  }

  func startNow() {
    guard !started, !stopped else { return }
    started = true
    registerSettings()
    registerCommands()
    if let n = env.call("spaces", "list").array?.count { spaceCount = n }
    refreshCard()
  }

  func stop() {
    stopped = true
    registerAttempts = Int.max / 2
    if card != nil { env.call("ui", "set", ["slot": "sidebar.notice", "tree": nil]) }
    if showing != nil { dismissToast() }
    save()
  }

  func load() {
    func get(_ k: String) -> Value { env.call("storage", "get", ["ns": .string(Self.ns), "key": .string(k)]) }
    enabled = get("enabled").bool ?? true
    tour = get("tour").string ?? "new"
    importState = get("import").string ?? ""
    launches = get("launches").int ?? 0
    lastTipAt = get("last").int ?? 0
    day = get("day").int ?? 0
    dayCount = get("dayCount").int ?? 0
    if case let .object(pairs) = get("counts") { for (k, v) in pairs { counts[k] = v.int ?? 0 } }
    for k in env.call("storage", "keys", ["ns": .string(Self.ns)]).array ?? [] {
      guard let key = k.string, get(key).bool == true else { continue }
      if Text.hasPrefix(key, "shown.") { shown.insert(Text.dropPrefix(key, "shown.")) }
      if Text.hasPrefix(key, "retired.") { retired.insert(Text.dropPrefix(key, "retired.")) }
    }
  }

  func put(_ key: String, _ value: Value) { env.call("storage", "set", ["ns": .string(Self.ns), "key": .string(key), "value": value]) }

  func save() {
    saveScheduled = false
    var c: Value = .object([])
    for (k, v) in counts { c.put(k, .int(v)) }
    put("counts", c)
  }

  func saveSoon() {
    guard !saveScheduled else { return }
    saveScheduled = true
    env.timer(2000, false) { [self] in if saveScheduled { save() } }
  }

  // MARK: - Settings and commands

  func registerSettings() {
    let r = env.call("settings", "register", [
      "id": .string(Self.ns), "section": "general", "title": "Tips", "order": 60,
      "controls": [["key": "enabled", "type": "toggle", "title": "Show tips",
                    "subtitle": "One-time hints about shortcuts and gestures, and the tour card.", "default": .bool(enabled)]],
    ])
    guard !r.isErr else { return }
    if let v = env.call("settings", "get", ["id": .string(Self.ns), "key": "enabled"]).bool, v != enabled { setEnabled(v, fromSettings: true) }
    env.on("settings.changed") { [self] v in
      if v.s("id") == Self.ns, v.s("key") == "enabled", let on = v["value"].bool, on != enabled { setEnabled(on, fromSettings: true) }
    }
  }

  /// `commands` is optional (plugin `commandbar`) and may load later: retry every 500 ms for 30 s.
  func registerCommands() {
    if tryRegister() { return }
    env.timer(500, false) { [self] in
      registerAttempts += 1
      if !tryRegister(), registerAttempts < 60 { registerCommands() }
    }
  }

  @discardableResult
  func tryRegister() -> Bool {
    if commandsRegistered { return true }
    let r = env.call("commands", "register", [
      "id": .string(Self.toggleCommand), "title": .string(enabled ? "Don't Show Tips" : "Show Tips"), "icon": "sf:lightbulb",
      "keywords": ["tips", "hints", "onboarding", "tour", "help"], "owner": .string(Self.ns),
    ])
    guard !r.isErr else { return false }
    env.call("commands", "register", [
      "id": .string(Self.tourCommand), "title": "Take the den Tour", "icon": "sf:sparkles",
      "keywords": ["tour", "welcome", "onboarding", "help", "tips"], "owner": .string(Self.ns),
    ])
    commandsRegistered = true
    return true
  }

  func setEnabled(_ on: Bool, fromSettings: Bool = false) {
    enabled = on
    put("enabled", .bool(on))
    if !fromSettings { env.call("settings", "set", ["id": .string(Self.ns), "key": "enabled", "value": .bool(on)]) }
    if commandsRegistered {
      commandsRegistered = false
      tryRegister()  // the title flips between "Don't Show Tips" and "Show Tips"
    }
    if !on {
      if showing != nil { dismissToast() }
      step = nil
    }
    refreshCard()
  }

  // MARK: - Notice card (tour, import)

  func importAvailable() -> Bool {
    let r = env.call("importer", "sources")
    importSources = r.isErr ? [] : (r.array ?? [])
    return !importSources.isEmpty
  }

  /// Which card should show now: a running tour step, the tour offer (second launch on), else
  /// the import offer when an importer exists.
  func wantedCard() -> String? {
    guard enabled else { return nil }
    if step != nil { return "step" }
    if tour == "new" && launches >= 2 { return "tour" }
    if importState.isEmpty && importAvailable() { return "import" }
    return nil
  }

  func refreshCard() {
    guard started else { return }
    let want = wantedCard()
    card = want
    var tree: Value = .null
    switch want ?? "" {
    case "tour": tree = tourTree()
    case "step": tree = stepTree(step ?? 0)
    case "import": tree = importTree()
    default: break
    }
    env.call("ui", "set", ["slot": "sidebar.notice", "tree": tree])
  }

  static func closeButton(_ id: String, _ tooltip: String) -> Value {
    ["type": "action", "id": .string(id), "icon": "sf:xmark", "tooltip": .string(tooltip), "width": 24, "height": 24, "iconSize": 11]
  }

  static func header(_ icon: String, _ title: String, close: String, tooltip: String) -> Value {
    ["type": "stack", "axis": "h", "spacing": 8, "align": "center", "children": [
      ["type": "icon", "spec": .string(icon), "size": 15, "tone": "accent"],
      ["type": "label", "text": .string(title), "size": 13, "weight": "semibold"],
      closeButton(close, tooltip),
    ]]
  }

  func tourTree() -> Value {
    ["type": "stack", "id": "tips.card", "spacing": 8, "padding": [10, 10, 12, 12], "children": [
      Self.header("sf:sparkles", "New to den?", close: "tips.tour.close", tooltip: "Not now"),
      ["type": "label", "text": "Take a 1-minute tour of the basics.", "size": 12, "tone": "secondary", "lines": 2],
      ["type": "action", "id": "tips.tour.start", "variant": "pill", "tone": "primary", "title": "Start Tour", "height": 28],
    ]]
  }

  func stepTree(_ i: Int) -> Value {
    let s = Self.steps[i]
    let count = String(i + 1) + " of " + String(Self.steps.count)
    var buttons: [Value] = []
    if i < Self.steps.count - 1 { buttons.append(["type": "action", "id": "tips.tour.skip", "variant": "pill", "title": "Skip Tour", "height": 28]) }
    buttons.append(["type": "action", "id": "tips.tour.next", "variant": "pill", "tone": "primary", "title": .string(s.done), "height": 28])
    return ["type": "stack", "id": "tips.card", "spacing": 8, "padding": [10, 10, 12, 12], "children": [
      Self.header("sf:sparkles", "Tour  ·  " + count, close: "tips.tour.skip", tooltip: "Skip tour"),
      ["type": "label", "text": .string(s.text), "size": 12, "lines": 4],
      ["type": "stack", "axis": "h", "spacing": 6, "distribute": "equal", "children": .array(buttons)],
    ]]
  }

  func importTree() -> Value {
    var names: [String] = []
    for s in importSources { let n = s.s("name"); if !n.isEmpty { names.append(n) } }
    var from = names.first ?? "another browser"
    if names.count == 2 { from = names[0] + " or " + names[1] } else if names.count > 2 {
      from = ""
      for (j, n) in names.enumerated() { from += (j == 0 ? "" : j == names.count - 1 ? " or " : ", ") + n }
    }
    var button: Value = ["type": "action", "id": "tips.import.run", "variant": "pill", "tone": "primary", "height": 28,
                         "title": .string(names.count == 1 ? "Import from " + names[0] : "Import…")]
    if names.count > 1 {
      var menu: [Value] = []
      for s in importSources { menu.append(["id": .string(s.s("id")), "title": .string(s.s("name"))]) }
      button.put("menu", .array(menu))
    } else {
      button.put("value", .string(importSources.first?.s("id") ?? ""))
    }
    return ["type": "stack", "id": "tips.card", "spacing": 8, "padding": [10, 10, 12, 12], "children": [
      Self.header("sf:square.and.arrow.down", "Switching browsers?", close: "tips.import.close", tooltip: "Not now"),
      ["type": "label", "text": .string("Bring your tabs and bookmarks from " + from + " in one click."), "size": 12, "tone": "secondary", "lines": 3],
      button,
    ]]
  }

  func setTour(_ state: String) {
    tour = state
    put("tour", .string(state))
  }

  func startTour() {
    guard enabled else { return }
    if showing != nil { dismissToast() }
    step = 0
    refreshCard()
  }

  /// Next (or the step's action done): the next step, or the end of the tour.
  func advance(from i: Int) {
    guard step == i else { return }
    if i + 1 < Self.steps.count {
      step = i + 1
    } else {
      step = nil
      setTour("done")
    }
    refreshCard()
  }

  func endTour() {
    step = nil
    setTour("done")
    refreshCard()
  }

  func runImport(_ source: String) {
    importState = "done"
    put("import", "done")
    env.call("importer", "run", ["source": .string(source)])
    refreshCard()
  }

  // MARK: - Tips

  func tip(_ key: String) -> Tip? { Self.tips.first { $0.key == key } }
  func done(_ key: String) -> Bool { shown.contains(key) || retired.contains(key) }

  /// Counts an occurrence; offers the tip from the `at`-th on (a blocked offer comes back next time).
  /// `fill`: values for the tip's `{placeholders}`.
  func bump(_ key: String, at: Int64 = 1, fill: [(String, String)] = []) {
    guard enabled, !done(key) else { return }
    let n = (counts[key] ?? 0) + 1
    counts[key] = n
    saveSoon()
    if n >= at { offer(key, fill: fill) }
  }

  /// Why a tip can't show now (nil: it can).
  func blocked(_ key: String) -> String? {
    if !enabled { return "disabled" }
    if done(key) { return "done" }
    if step != nil { return "tour" }
    if showing != nil { return "showing" }
    let now = env.now()
    if now - startedAt < Self.quietStartMs { return "launch" }
    if lastTipAt > 0 && now - lastTipAt < Self.minGapMs { return "gap" }
    if now / Self.dayMs == day && dayCount >= Self.perDay { return "day" }
    if !(env.call("ui", "get")["overlays"].array ?? []).isEmpty { return "modal" }
    return nil
  }

  @discardableResult
  func offer(_ key: String, fill: [(String, String)] = []) -> Bool {
    guard blocked(key) == nil, var t = tip(key) else { return false }
    t = Tip(key: t.key, text: Self.filled(t.text, fill))
    let now = env.now()
    shown.insert(key)
    put("shown." + key, true)
    lastTipAt = now
    put("last", .int(now))
    if now / Self.dayMs != day {
      day = now / Self.dayMs
      dayCount = 0
      put("day", .int(day))
    }
    dayCount += 1
    put("dayCount", .int(dayCount))
    display(t)
    return true
  }

  /// `text` with each `{name}` replaced by its value.
  static func filled(_ text: String, _ fill: [(String, String)]) -> String {
    var out = Array(text.utf8)
    for (k, v) in fill {
      let needle = Array(("{" + k + "}").utf8)
      var from = 0
      while from < out.count, let r = URLs.find(Array(out[from...]), needle) {
        out.replaceSubrange((from + r)..<(from + r + needle.count), with: Array(v.utf8))
        from += r + v.utf8.count
      }
    }
    return String(decoding: out, as: UTF8.self)
  }

  func display(_ t: Tip) {
    showing = t.key
    env.call("ui", "set", ["slot": "toast", "tree": [
      "type": "toast", "id": .string(Self.toastId), "text": .string(t.text), "icon": "sf:lightbulb",
      "duration": .int(Self.tipDurationMs), "action": "Don't show tips", "hold": true,
    ]])
    // Forget it once it's gone (a later tip may replace it).
    env.timer(UInt64(Self.tipDurationMs), false) { [self] in if showing == t.key { showing = nil } }
  }

  func dismissToast() {
    showing = nil
    env.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "id": .string(Self.toastId), "dismiss": true]])
  }

  /// You did the thing: the tip never shows (and leaves the screen if it's up).
  func retire(_ key: String) {
    guard !retired.contains(key) else { return }
    retired.insert(key)
    put("retired." + key, true)
    if showing == key { dismissToast() }
  }

  // MARK: - Events

  func listen() {
    env.on("ui.action") { [self] v in action(v.s("id"), v.s("action"), v["value"]) }
    env.on("commands.run") { [self] v in commandRun(v.s("id")) }
    env.on("tips.preview") { [self] v in preview(v.s("key"), v) }
    // Tabs and the Library.
    env.on("tabs.key.close") { [self] _ in bump("reopenClosed") }
    env.on("tabs.key.reopen") { [self] _ in retire("reopenClosed"); if step == 4 { advance(from: 4) } }
    env.on("tabs.key.library") { [self] _ in retire("reopenClosed") }
    env.on("tabs.key.clear") { [self] _ in retire("clearUndo") }
    env.on("tabs.key.pin") { [self] _ in if step == 0 { advance(from: 0) } }
    env.on("tabs.key.copy") { [self] _ in bump("copyMarkdown", at: 3) }
    // Sidebar.
    env.on("window.sidebarVisibility") { [self] v in if v.b("hidden") { bump("edgeReveal") } }
    env.on("window.sidebarReveal") { [self] v in if v.b("revealed") { retire("edgeReveal") } }
    env.on("window.sidebarResized") { [self] v in
      if v.s("by") == "drag" { bump("resetWidth") } else if v.s("by") == "reset" { retire("resetWidth") }
    }
    // Spaces.
    env.on("spaces.changed") { [self] v in spacesChanged(v.a("spaces").count) }
    env.on("spaces.current") { [self] _ in if step == 2 { advance(from: 2) } }
    // Peek and split.
    env.on("peek.opened") { [self] _ in
      peekOpenedAt = env.now()
      if step == 3 { advance(from: 3) }
    }
    env.on("peek.key.close") { [self] _ in
      if peekOpenedAt > 0 && env.now() - peekOpenedAt < 2000 { bump("peekReopen") }
      peekOpenedAt = 0
    }
    env.on("peek.key.reopen") { [self] _ in retire("peekReopen") }
    env.on("peek.key.focusPane") { [self] _ in retire("splitKeys") }
    env.on("tabs.selected") { [self] _ in checkSplit() }
    env.on("tabs.changed") { [self] _ in checkSplit() }
    // Previews, the address, the briefing.
    env.on("previews.request") { [self] v in
      let u = v.s("url")
      if URLs.host(u) == "github.com" && Text.contains(u, "/pull/") { bump("prPeek") }
    }
    env.on("commands.key.edit") { [self] _ in retire("editUrl") }
    env.on("briefing.key.open") { [self] _ in retire("briefingKey") }
    env.on("commands.keywordHint") { [self] v in
      bump("siteKeyword", fill: [("keyword", v.s("keyword")), ("name", v.s("name"))])
    }
    env.on("commands.keywordSearch") { [self] _ in retire("siteKeyword") }
  }

  func action(_ id: String, _ action: String, _ value: Value) {
    switch id {
    case "tips.tour.start": startTour()
    case "tips.tour.close": setTour("dismissed"); refreshCard()
    case "tips.tour.skip": endTour()
    case "tips.tour.next": if let s = step { advance(from: s) }
    case "tips.import.close":
      importState = "dismissed"
      put("import", "dismissed")
      refreshCard()
    case "tips.import.run": runImport(value.string ?? "")  // click: the button's value; menu: the picked source
    case Self.toastId: if action == "toast" { showing = nil; setEnabled(false) }
    case "tabs.url": if action == "click" { bump("editUrl") }
    case "sidebar": if action == "page" { retire("swipeSpaces") }
    default:
      if Text.hasPrefix(id, "spaces.icon:") {
        switch action {
        case "click": bump("swipeSpaces", at: 3)
        case "move": retire("reorderSpaces")
        case "menu": spaceMenuPicked(value.string ?? "")
        default: break
        }
      } else if Text.hasPrefix(id, "spaces.title:") {
        switch action {
        case "doubleClick": retire("renameSpace")
        case "menu": spaceMenuPicked(value.string ?? "")
        case "more": retire("spaceMenu")
        default: break
        }
      } else if Text.hasPrefix(id, "tab-") && action == "close" {
        rowClose()
      } else if Text.hasPrefix(id, "tab-") && action == "menu" && (value.string == "pin") {
        if step == 0 { advance(from: 0) }
      }
    }
  }

  func spaceMenuPicked(_ item: String) {
    retire("spaceMenu")
    if item == "rename" { bump("renameSpace") }
  }

  func commandRun(_ id: String) {
    if id == Self.toggleCommand { setEnabled(!enabled); return }
    if id == Self.tourCommand { startTour(); return }
    if id == "den.copyMarkdown" { retire("copyMarkdown") }
    if id == "briefing.open" { bump("briefingKey") }
    if step == 1 { advance(from: 1) }
  }

  func spacesChanged(_ n: Int) {
    defer { spaceCount = n }
    guard spaceCount >= 0 else { return }
    if spaceCount < 2 && n >= 2 { bump("spaceMenu") }
    if spaceCount < 4 && n >= 4 { bump("reorderSpaces") }
  }

  /// Three tabs closed with their × (or a middle-click) within a minute.
  func rowClose() {
    guard enabled, !done("clearUndo") else { return }
    let now = env.now()
    rowCloses = rowCloses.filter { now - $0 < 60_000 } + [now]
    if rowCloses.count >= 3 { bump("clearUndo") }
  }

  func checkSplit() {
    guard enabled, !done("splitKeys") else { return }
    if (env.call("content", "get")["panes"].array?.count ?? 0) >= 2 { bump("splitKeys") }
  }

  /// `tips.preview {key}` (snapshot scenarios): shows the tour card ("tour"), a tour step
  /// ("step", `step`), the import card ("import", `sources`) or a tip, ignoring the limits and
  /// recording nothing.
  func preview(_ key: String, _ v: Value) {
    started = true
    switch key {
    case "tour":
      card = "tour"
      env.call("ui", "set", ["slot": "sidebar.notice", "tree": tourTree()])
    case "step":
      step = Int(v.i("step"))
      card = "step"
      env.call("ui", "set", ["slot": "sidebar.notice", "tree": stepTree(max(0, min(Self.steps.count - 1, step ?? 0)))])
    case "import":
      importSources = v.a("sources")
      card = "import"
      env.call("ui", "set", ["slot": "sidebar.notice", "tree": importTree()])
    default:
      if let t = tip(key) { display(Tip(key: t.key, text: Self.filled(t.text, [("keyword", v.sOpt("keyword") ?? "yt"), ("name", v.sOpt("name") ?? "YouTube")]))) }
    }
  }
}
