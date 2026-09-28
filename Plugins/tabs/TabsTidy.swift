#if !hasFeature(Embedded)
  import CordisValue
#endif

/// Tidy Tabs (Arc Max's "Tidy"): Apple's on-device model sorts a space's loose Today tabs into
/// named groups. Off by default (Settings ▸ Tabs ▸ "Tidy tabs using Apple Intelligence"); then a
/// "Tidy" button shows on the Today divider while it's hovered, in the divider's menu, as the
/// "Tidy Tabs" command and on ⌃⇧T. It never runs by itself unless "Tidy automatically" is on too.
/// One ⌃Z (or the toast's Undo) puts every tab back. Nothing here runs while the setting is off:
/// no model call, no timer (the automatic check rides on the existing minute tick).
extension TabsCore {
  static let tidyCommandId = "tabs.tidy"
  static let tidyToastId = "tabs.tidy"
  static let tidyOffToastId = "tabs.tidy.off"
  static let tidyRequestPrefix = "tabs.tidy:"
  /// Fewer loose tabs than this: nothing worth sorting.
  static let tidyMinTabs = 3
  /// "Tidy automatically" kicks in at this many loose Today tabs, at most every 30 minutes per space.
  static let tidyAutoAt = 8
  static let tidyAutoGapMs: Int64 = 30 * 60_000
  static let tidyWaitMs: UInt64 = 60_000
  static let tidyMaxGroups = 6

  static let tidyInstructions =
    "These are open browser tabs, one per line: the page title, then its address. Sort them into folders by topic or task, the way a tidy person would. Make 2 to 6 folders with at least 2 tabs each. Name each folder in one to three specific words in Title Case, like Trip to Lisbon, Swift Concurrency or Pull Requests. Leave out tabs that fit no folder."

  // MARK: Settings

  func tidyControls() -> [Value] {
    [
      ["key": "tidy", "type": "toggle", "title": "Tidy tabs using Apple Intelligence",
       "subtitle": .string(tidySubtitle), "default": false,
       "keywords": ["tidy", "organize", "sort", "group", "folders", "ai", "apple intelligence"]],
      ["key": "tidyAuto", "type": "toggle", "title": "Tidy automatically",
       "subtitle": "When Today has 8 or more loose tabs, tidy them without asking. Control-Z still puts them back.", "default": false],
    ]
  }

  var tidySubtitle: String {
    let base = "Adds Tidy to the Today divider and Control-Shift-T: sorts loose Today tabs into named groups. It runs on this Mac with Apple's on-device model; nothing is sent anywhere."
    if let why = tidyUnavailable { return why + " " + base }
    return base
  }

  /// Settings ▸ Tabs opened, or Tidy switched on: say why it can't run, if it can't. Asked only
  /// then, so the model's availability is never read at launch.
  func tidyRefreshAvailability() {
    let a = env.call("ai", "availability")
    let why: String? = a.isErr ? "Apple Intelligence isn't available in this build." : a.b("available") ? nil : Self.tidyReason(a.s("reason"))
    aiAvailable = why == nil
    guard why != tidyUnavailable else { return }
    tidyUnavailable = why
    registerSettings()
  }

  static func tidyReason(_ reason: String) -> String {
    switch reason {
    case "deviceNotEligible": return "This Mac can't run Apple Intelligence."
    case "appleIntelligenceNotEnabled": return "Turn on Apple Intelligence in System Settings first."
    case "modelNotReady": return "Apple Intelligence is still getting ready. Try again in a little while."
    default: return "Apple Intelligence isn't available right now."
    }
  }

  func applyTidySetting(_ key: String, _ v: Value) {
    guard let b = v.bool else { return }
    let was = tidyEnabled
    if key == "tidy" { tidyEnabled = b } else { tidyAuto = b }
    if key == "tidy", b, !was, tidyReady { tidyRefreshAvailability() }
    if tidyEnabled != was { renderAll() }
  }

  func tidyStart() {
    env.on("settings.opened") { [self] v in if v.s("section") == Self.ns, tidyEnabled { tidyRefreshAvailability() } }
    env.on("tabs.key.tidy") { [self] _ in tidy(currentSpace, auto: false) }
    env.on("commands.run") { [self] v in if v.s("id") == Self.tidyCommandId { tidy(currentSpace, auto: false) } }
    registerTidyCommand()
  }

  func registerTidyCommand() {
    if tryRegisterTidyCommand() { return }
    env.timer(500, false) { [self] in
      tidyRegisterAttempts += 1
      if !tryRegisterTidyCommand(), tidyRegisterAttempts < 60 { registerTidyCommand() }
    }
  }

  func tryRegisterTidyCommand() -> Bool {
    if tidyCommandRegistered { return true }
    let r = env.call("commands", "register", [
      "id": .string(Self.tidyCommandId), "title": "Tidy Tabs", "icon": "sf:sparkles", "shortcut": "⌃⇧T", "owner": "tabs",
      "keywords": ["tidy", "organize", "sort", "group", "folders", "clean up", "ai", "apple intelligence"],
    ])
    tidyCommandRegistered = !r.isErr
    return tidyCommandRegistered
  }

  // MARK: The Today divider

  /// The divider above Today: "Clear", plus "Tidy" on hover while tidying is on (Arc), and a
  /// right-click menu naming both shortcuts.
  func todayDivider(_ sid: String, empty: Bool) -> Value {
    var v: Value = ["type": "divider", "id": .string("tabs.divider:" + sid)]
    guard !empty else { return v }
    v.put("action", "Clear")
    var menu: [Value] = []
    if tidyEnabled {
      let busy = tidying == sid
      v.put("secondary", ["id": "tidy", "title": .string(busy ? "Tidying…" : "Tidy"), "icon": "sf:sparkles", "always": .bool(busy)])
      menu.append(["id": "tidy", "title": "Tidy Tabs", "icon": "sf:sparkles", "key": .string(Self.chord("tabs.key.tidy")), "keyFor": "tabs.key.tidy"])
    }
    menu.append(["id": "clear", "title": "Clear Today", "icon": "sf:arrow.down", "key": .string(Self.chord("tabs.key.clear")), "keyFor": "tabs.key.clear"])
    v.put("menu", .array(menu))
    return v
  }

  /// ui.action on the divider or the tidy toasts; true when handled.
  func tidyAction(_ id: String, _ action: String, _ value: Value) -> Bool {
    if Text.hasPrefix(id, "tabs.divider:") {
      let sid = Text.dropPrefix(id, "tabs.divider:")
      if action == "tidy" || (action == "menu" && value.string == "tidy") { tidy(sid, auto: false); return true }
      if action == "menu" && value.string == "clear" { clearToday(sid); return true }
      return false
    }
    if id == Self.tidyToastId, action == "toast" {
      if tidyUndoDepth > 0, undoStack.count == tidyUndoDepth { _ = undo() }
      tidyUndoDepth = -1
      return true
    }
    if id == Self.tidyOffToastId, action == "toast" {
      env.call("settings", "open", ["section": .string(Self.ns)])
      return true
    }
    return false
  }

  // MARK: Tidying

  /// "https://www.example.com/a/b?q" -> "example.com/a/b?q" (no trailing "/").
  static func tidyAddress(_ url: String) -> String {
    var s = url
    for p in ["https://", "http://"] where Text.hasPrefix(Text.lower(s), p) { s = Text.dropPrefix(s, p) }
    if Text.hasPrefix(s, "www.") { s = Text.dropPrefix(s, "www.") }
    var b = Array(s.utf8)
    while b.last == 47 { b.removeLast() }  // "/"
    return String(decoding: b, as: UTF8.self)
  }

  /// Tabs sitting directly in Today (not in a group or a split).
  func looseToday(_ sid: String) -> [String] { (today[sid] ?? []).filter { tabs[$0] != nil } }

  func tidyToast(_ text: String, id: String = TabsCore.tidyToastId, icon: String = "sf:sparkles", action: String? = nil, duration: Int64? = nil) {
    var t: Value = ["type": "toast", "id": .string(id), "text": .string(text), "icon": .string(icon)]
    if let action { t.put("action", .string(action)) }
    if let duration { t.put("duration", .int(duration)) }
    env.call("ui", "set", ["slot": "toast", "tree": t])
  }

  func tidy(_ sid: String, auto: Bool) {
    guard tidying == nil else { return }
    guard tidyEnabled else {
      tidyToast("Tidy Tabs is off. Turn it on in Settings ▸ Tabs.", id: Self.tidyOffToastId, icon: "sf:sparkles", action: "Open Settings")
      return
    }
    let loose = looseToday(sid)
    guard loose.count >= Self.tidyMinTabs else {
      if !auto { tidyToast("Nothing to tidy: Today needs 3 or more tabs outside groups.") }
      return
    }
    let a = env.call("ai", "availability")
    guard !a.isErr, a.b("available") else {
      if !auto { tidyToast(a.isErr ? "Apple Intelligence isn't available in this build." : Self.tidyReason(a.s("reason")), icon: "sf:exclamationmark.triangle") }
      return
    }
    let items: [Value] = loose.compactMap { id in
      guard let t = tabs[id] else { return nil }
      // The address without its scheme: a background tab that never loaded has only its URL,
      // and the path often says what it's about (/wiki/Lisbon).
      return ["id": .string(id), "text": .string(t.displayTitle + " — " + Self.tidyAddress(t.url))]
    }
    let r = env.call("ai", "group", ["id": .string(Self.tidyRequestPrefix + sid), "items": .array(items),
                                     "instructions": .string(Self.tidyInstructions), "maxGroups": .int(Int64(Self.tidyMaxGroups))])
    guard !r.isErr else {
      if !auto { tidyToast("Couldn't tidy your tabs this time.", icon: "sf:exclamationmark.triangle") }
      return
    }
    tidying = sid
    tidyStartedAt = env.now()
    if auto { tidyLastAuto[sid] = env.now() }
    tidyToast("Tidying tabs…", duration: 0)
    renderPage(sid)
    let stamp = tidyStartedAt
    // A model that never answers doesn't leave the divider busy.
    env.timer(Self.tidyWaitMs, false) { [self] in
      guard tidying == sid, tidyStartedAt == stamp else { return }
      tidying = nil
      tidyToast("Couldn't tidy your tabs this time.", icon: "sf:exclamationmark.triangle")
      renderPage(sid)
    }
  }

  /// `ai.result` for a tidy request: groups of still-loose tabs become collapsed, named groups at
  /// the place of their first tab, in one undo step.
  func tidyArrived(_ v: Value) {
    let rid = v.s("id")
    guard Text.hasPrefix(rid, Self.tidyRequestPrefix) else { return }
    let sid = Text.dropPrefix(rid, Self.tidyRequestPrefix)
    guard tidying == sid else { return }
    tidying = nil
    guard v.b("ok") else {
      let text = v.s("error") == "unavailable" ? Self.tidyReason(v.s("reason")) : "Couldn't tidy your tabs this time."
      tidyToast(text, icon: "sf:exclamationmark.triangle")
      renderPage(sid)
      return
    }
    let plan = Self.tidyPlan(v.a("groups"), loose: looseToday(sid))
    guard !plan.isEmpty else {
      tidyToast("Your tabs already look tidy.")
      renderPage(sid)
      return
    }
    checkpoint()
    tidyUndoDepth = undoStack.count
    var list = today[sid] ?? []
    var moved = 0
    for (name, members) in plan {
      guard let at = list.firstIndex(where: { members.contains($0) }) else { continue }
      let fid = newId("folder-")
      folders[fid] = Folder(id: fid, spaceId: sid, title: Self.cleanName(name) ?? groupName(members), open: false, children: members)
      list[at] = fid
      list.removeAll { members.contains($0) }
      for m in members { opener[m] = nil }
      moved += members.count
    }
    setIds(.today(sid), list)
    changed(sid)
    let folderCount = plan.count
    tidyToast("Tidied " + String(moved) + " tabs into " + String(folderCount) + (folderCount == 1 ? " group" : " groups") + ". Use ⌃Z to undo.",
              action: "Undo")
  }

  /// The model's groups -> (name, tabs) to apply: only tabs still loose in Today, each once,
  /// groups of at least 2, at most `tidyMaxGroups`.
  static func tidyPlan(_ groups: [Value], loose: [String]) -> [(String, [String])] {
    var used: [String] = []
    var out: [(String, [String])] = []
    for g in groups where out.count < tidyMaxGroups {
      var members: [String] = []
      for m in g.a("items") {
        guard let id = m.string, loose.contains(id), !used.contains(id), !members.contains(id) else { continue }
        members.append(id)
      }
      guard members.count >= 2 else { continue }
      // Today's order inside each group.
      members = loose.filter { members.contains($0) }
      used += members
      out.append((g.s("name"), members))
    }
    return out
  }

  /// Called from the minute tick: tidies the current space when "Tidy automatically" is on and
  /// Today has piled up. Costs one flag check otherwise.
  func autoTidy() {
    guard tidyEnabled, tidyAuto, tidying == nil, editing == nil, activeSince != nil else { return }
    let sid = currentSpace
    guard looseToday(sid).count >= Self.tidyAutoAt, env.now() - (tidyLastAuto[sid] ?? 0) >= Self.tidyAutoGapMs else { return }
    tidy(sid, auto: true)
  }
}
