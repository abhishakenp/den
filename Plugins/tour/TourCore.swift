// Tour Callouts: visual callout panels with arrow pointers that highlight real UI elements.
//
// - **First-run tour.** From the second launch, the tips plugin offers the tour. Each step
//   shows a callout card positioned next to the target UI element (sidebar, command bar, spaces,
//   split view, library). Arrow pointer indicates the element. Animated transitions via the host
//   CardController. Tap "Next" to advance, "Skip Tour" to finish, "×" to dismiss.
// - **Discovery tips.** After the tour, occasional contextual callouts teach lesser-known
//   features when the user is near the relevant UI (e.g., split view callout when a split opens).
// - **Settings help.** When the user opens Settings from the menu, show a callout pointing at
//   the command bar as an alternative way to find settings.
//
// The card system (Card.swift) handles positioning, animation, and keyboard shortcuts.

#if !hasFeature(Embedded)
  import CordisValue
#endif

final class TourCore {
  static let ns = "tour"
  static let calloutId = "tour.callout"
  static let startDelayMs: UInt64 = 2_000
  static let tipIntervalMs: Int64 = 12 * 3_600_000  // at most one discovery tip every 12 hours
  static let maxPerDay: Int64 = 2
  static let dayMs: Int64 = 86_400_000

  static let firstRunCommand = "tour.first"
  static let discoveryCommand = "tour.discovery"

  struct Step {
    let text: String
    let icon: String
    let placement: String  // "trailing" | "below"
    let done: String
    let completeEvent: String?
    let type: String  // "tour" | "discovery" | "settings"
  }

  static let firstRunSteps: [Step] = [
    Step(text: "New tabs land in Today and archive after a day. ⌘D pins one to keep it.", icon: "sf:star", placement: "trailing", done: "Next", completeEvent: "tour.step.pin", type: "tour"),
    Step(text: "⌘T does everything: tabs, the web, commands and settings. Try typing 'dark'.", icon: "sf:command", placement: "trailing", done: "Next", completeEvent: "tour.step.command", type: "tour"),
    Step(text: "Spaces keep work and life apart. Swipe with two fingers in the sidebar to switch.", icon: "sf:rectangle.split.2x2", placement: "trailing", done: "Next", completeEvent: "tour.step.space", type: "tour"),
    Step(text: "⇧-click any link to Peek at it without leaving the page.", icon: "sf:eye.circle", placement: "trailing", done: "Next", completeEvent: "tour.step.peek", type: "tour"),
    Step(text: "Closed something? ⇧⌘T brings it back. Everything else is in the Library, ⇧⌘L.", icon: "sf:archivebox", placement: "trailing", done: "Done", completeEvent: "tour.step.library", type: "tour"),
  ]

  static let discoveryTips: [Step] = [
    Step(text: "Double-click the sidebar edge to reset its width.", icon: "sf:hand.tap", placement: "trailing", done: "Got it", completeEvent: nil, type: "discovery"),
    Step(text: "⌥⇧⌘C copies the link as Markdown for easy sharing.", icon: "sf:doc.badge.plus", placement: "trailing", done: "Got it", completeEvent: nil, type: "discovery"),
    Step(text: "⌃⇧1–4 focus a split pane. ⌃⇧- closes the focused one.", icon: "sf:rectangle.split.2x2", placement: "trailing", done: "Got it", completeEvent: nil, type: "discovery"),
    Step(text: "Hover a PR tab for its checks and reviews without leaving the page.", icon: "sf:circle.lefthalf.filled", placement: "trailing", done: "Got it", completeEvent: nil, type: "discovery"),
    Step(text: "Right-click a space for its icon, theme, and more options.", icon: "sf:circlebadge", placement: "trailing", done: "Got it", completeEvent: nil, type: "discovery"),
    Step(text: "Move to the left edge of the window to bring the sidebar back.", icon: "sf:sidebar.left", placement: "trailing", done: "Got it", completeEvent: nil, type: "discovery"),
  ]

  static let settingsSteps: [Step] = [
    Step(text: "You can also find settings by typing a setting name in the command bar.", icon: "sf:gearshape", placement: "trailing", done: "OK", completeEvent: "tour.step.settings", type: "settings"),
  ]

  let env: PluginEnv
  var enabled = true
  var tourState = "new"  // new | running | done | dismissed
  var step: Int?
  var showing = false
  var tipIndex: Int = 0
  var lastTipAt: Int64 = 0
  var day: Int64 = 0
  var dayCount: Int64 = 0
  var saveScheduled = false
  var started = false
  var stopped = false
  var commandsRegistered = false
  var registerAttempts = 0
  var settingsShown = false

  init(env: PluginEnv) { self.env = env }

  // MARK: - Lifecycle

  func start() {
    let startedAt = env.now()
    _ = startedAt
    load()
    env.timer(Self.startDelayMs, false) { [self] in startNow() }
  }

  func startNow() {
    guard !started, !stopped else { return }
    started = true
    registerSettings()
    registerCommands()
    refreshCallout()
  }

  func stop() {
    stopped = true
    registerAttempts = Int.max / 2
    if showing { hideCallout() }
    save()
  }

  func load() {
    func get(_ k: String) -> Value { env.call("storage", "get", ["ns": .string(Self.ns), "key": .string(k)]) }
    enabled = get("enabled").bool ?? true
    tourState = get("tourState").string ?? "new"
    step = get("step").int.map { Int($0) }
    lastTipAt = get("lastTip").int ?? 0
    day = get("day").int ?? 0
    dayCount = get("dayCount").int ?? 0
    tipIndex = Int(get("tipIndex").int ?? 0)
    settingsShown = get("settingsShown").bool ?? false
  }

  func put(_ key: String, _ value: Value) {
    env.call("storage", "set", ["ns": .string(Self.ns), "key": .string(key), "value": value])
  }

  func save() {
    saveScheduled = false
    put("tourState", .string(tourState))
    put("step", .int(Int64(step ?? 0)))
    put("lastTip", .int(lastTipAt))
    put("day", .int(day))
    put("dayCount", .int(dayCount))
    put("tipIndex", .int(Int64(tipIndex)))
    put("settingsShown", .bool(settingsShown))
  }

  func saveSoon() {
    guard !saveScheduled else { return }
    saveScheduled = true
    env.timer(2000, false) { [self] in if saveScheduled { save() } }
  }

  // MARK: - Settings

  func registerSettings() {
    let r = env.call("settings", "register", [
      "id": .string(Self.ns), "section": "general", "title": "Tour Callouts", "order": 55,
      "controls": [
        ["key": "enabled", "type": "toggle", "title": "Tour Callouts",
         "subtitle": "Visual callouts pointing at real UI elements for first-run tours and discovery.",
         "default": .bool(enabled)],
      ],
    ])
    guard !r.isErr else { return }
    if let v = env.call("settings", "get", ["id": .string(Self.ns), "key": "enabled"]).bool, v != enabled {
      setEnabled(v, fromSettings: true)
    }
    env.on("settings.changed") { [self] v in
      if v.s("id") == Self.ns, v.s("key") == "enabled", let on = v["value"].bool, on != enabled {
        setEnabled(on, fromSettings: true)
      }
    }
  }

  func setEnabled(_ on: Bool, fromSettings: Bool = false) {
    enabled = on
    put("enabled", .bool(on))
    if !fromSettings {
      env.call("settings", "set", ["id": .string(Self.ns), "key": "enabled", "value": .bool(on)])
    }
    if commandsRegistered {
      commandsRegistered = false
      tryRegister()
    }
    if !on {
      if showing { hideCallout() }
      step = nil
    }
    refreshCallout()
  }

  // MARK: - Commands

  func registerCommands() {
    if tryRegister() { return }
    env.timer(500, false) { [self] in
      registerAttempts += 1
      if !tryRegister(), registerAttempts < 60 { registerCommands() }
    }
  }

  @discardableResult
  func tryRegister() -> Bool {
    guard !commandsRegistered else { return true }
    let r = env.call("commands", "register", [
      "id": .string(Self.firstRunCommand), "title": "Take the den Tour", "icon": "sf:sparkles",
      "keywords": ["tour", "welcome", "onboarding", "help", "callout", "first run", "new user"], "owner": .string(Self.ns),
    ])
    guard !r.isErr else { return false }
    env.call("commands", "register", [
      "id": .string(Self.discoveryCommand), "title": "Show Discovery Tips", "icon": "sf:lightbulb",
      "keywords": ["discovery", "tips", "features", "help", "callout"], "owner": .string(Self.ns),
    ])
    commandsRegistered = true
    return true
  }

  // MARK: - Callout rendering

  /// Show a callout card at the current step's position. Uses the host's card system:
  /// `ui.card {id, tree, anchor?, rect?, place?, width?, gap?}`.
  /// The card animates in with the CardController's standard appear transition.
  func showCallout() {
    guard let s = step, !stopped else { return }
    let allSteps = activeSteps
    guard s < allSteps.count else { endTour(); return }
    let step = allSteps[s]

    showing = true

    // Build the callout card tree: a themed panel with icon, text, and navigation buttons.
    let countText = "\(s + 1) of \(allSteps.count)"
    let isLast = s == allSteps.count - 1

    var buttons: [Value] = []
    if !isLast && step.type == "tour" {
      buttons.append([
        "type": "action", "id": "tour.skip", "variant": "pill", "title": "Skip Tour", "height": 28,
      ])
    }
    buttons.append([
      "type": "action", "id": "tour.next", "variant": "pill", "tone": "primary",
      "title": .string(step.done), "height": 28,
    ])

    let cardTree: Value = [
      "type": "stack", "id": .string(Self.calloutId), "spacing": 8,
      "padding": [10, 10, 12, 12],
      "children": [
        // Header with icon and step counter
        ["type": "stack", "axis": "h", "spacing": 8, "align": "center", "children": [
          ["type": "icon", "spec": .string(step.icon), "size": 15, "tone": "accent"],
          ["type": "label", "text": .string(countText), "size": 12, "weight": "semibold"],
          Self.closeButton("tour.close", "Dismiss"),
        ]],
        // Description text
        ["type": "label", "text": .string(step.text), "size": 12, "lines": isLast ? 4 : 3],
        // Buttons
        ["type": "stack", "axis": "h", "spacing": 6, "distribute": "equal", "children": .array(buttons)],
      ],
    ]

    // Position the card using the card system's placement.
    env.call("ui", "card", [
      "id": .string(Self.calloutId), "tree": cardTree,
      "place": .string(step.placement),
      "width": .double(280),
      "gap": .double(8),
    ])
  }

  func hideCallout() {
    showing = false
    env.call("ui", "card", ["id": .string(Self.calloutId), "tree": nil])
  }

  static func closeButton(_ id: String, _ tooltip: String) -> Value {
    ["type": "action", "id": .string(id), "icon": "sf:xmark", "tooltip": .string(tooltip), "width": 24, "height": 24, "iconSize": 11]
  }

  // MARK: - Tour flow

  var activeSteps: [Step] {
    guard tourState == "running" else { return Self.firstRunSteps }
    return Self.firstRunSteps
  }

  func startTour() {
    guard enabled, tourState != "running" else { return }
    tourState = "running"
    step = 0
    settingsShown = false
    save()
    // Tell tips to hide its tour card (tour takes over)
    env.call("ui", "set", ["slot": "sidebar.notice", "tree": nil])
    showCallout()
  }

  func advance() {
    guard let s = step, !stopped else { return }
    let allSteps = activeSteps
    guard s < allSteps.count else { return }
    let currentStep = allSteps[s]

    // Emit the completion event for this step (so other plugins can react)
    if let event = currentStep.completeEvent {
      env.emit(event, ["step": .int(Int64(s))])
    }

    if s + 1 < allSteps.count {
      step = s + 1
      showCallout()
    } else {
      endTour()
    }
  }

  func endTour() {
    step = nil
    tourState = "done"
    showing = false
    hideCallout()
    save()
  }

  func dismissCallout() {
    showing = false
    hideCallout()
    if tourState == "running" {
      step = nil
      tourState = "dismissed"
    }
    save()
  }

  func skipTour() {
    step = nil
    tourState = "dismissed"
    showing = false
    hideCallout()
    save()
  }

  // MARK: - Discovery tips

  /// Offer a discovery tip if enough time has passed and rate limits allow.
  func offerDiscoveryTip() {
    guard enabled else { return }
    let now = env.now()

    // Rate limiting
    if lastTipAt > 0 && now - lastTipAt < Self.tipIntervalMs { return }
    if now / Self.dayMs == day && dayCount >= Self.maxPerDay { return }
    if showing { return }

    // Pick next tip (round-robin)
    let tip = Self.discoveryTips[tipIndex % Self.discoveryTips.count]
    tipIndex = (tipIndex + 1) % Self.discoveryTips.count

    showing = true
    dayCount += 1
    lastTipAt = now
    day = now / Self.dayMs
    saveSoon()

    // Show a discovery tip card
    let cardTree: Value = [
      "type": "stack", "id": .string(Self.calloutId), "spacing": 8,
      "padding": [10, 10, 12, 12],
      "children": [
        ["type": "stack", "axis": "h", "spacing": 8, "align": "center", "children": [
          ["type": "icon", "spec": .string(tip.icon), "size": 15, "tone": "accent"],
          ["type": "label", "text": "Did you know?", "size": 12, "weight": "semibold"],
          Self.closeButton("tour.close", "Dismiss"),
        ]],
        ["type": "label", "text": .string(tip.text), "size": 12, "lines": 3],
        ["type": "action", "id": "tour.next", "variant": "pill", "tone": "primary",
         "title": .string(tip.done), "height": 28],
      ],
    ]

    env.call("ui", "card", [
      "id": .string(Self.calloutId), "tree": cardTree,
      "place": .string("trailing"),
      "width": .double(280),
      "gap": .double(8),
    ])

    // Auto-dismiss after 10 seconds
    env.timer(10000, false) { [self] in
      if showing { dismissCallout() }
    }
  }

  // MARK: - Settings contextual help

  /// Called when settings page is opened via menu. Show a callout.
  func showSettingsHelp() {
    guard enabled, !settingsShown, tourState != "running" else { return }
    settingsShown = true
    save()

    let step = Self.settingsSteps.first!
    let cardTree: Value = [
      "type": "stack", "id": .string(Self.calloutId), "spacing": 8,
      "padding": [10, 10, 12, 12],
      "children": [
        ["type": "stack", "axis": "h", "spacing": 8, "align": "center", "children": [
          ["type": "icon", "spec": .string(step.icon), "size": 15, "tone": "accent"],
          ["type": "label", "text": "Pro tip", "size": 12, "weight": "semibold"],
          Self.closeButton("tour.close", "Dismiss"),
        ]],
        ["type": "label", "text": .string(step.text), "size": 12, "lines": 3],
        ["type": "action", "id": "tour.next", "variant": "pill", "tone": "primary",
         "title": .string(step.done), "height": 28],
      ],
    ]

    env.call("ui", "card", [
      "id": .string(Self.calloutId), "tree": cardTree,
      "place": .string("below"),
      "width": .double(300),
      "gap": .double(8),
    ])

    showing = true

    // Auto-dismiss after 8 seconds
    env.timer(8000, false) { [self] in
      if showing { dismissCallout() }
    }
  }

  // MARK: - Refresh

  func refreshCallout() {
    guard started, enabled else { return }
    if step != nil {
      showCallout()
      return
    }
  }

  // MARK: - Event handlers

  func listen() {
    env.on("ui.action") { [self] v in action(v.s("id"), v.s("action"), v["value"]) }
    env.on("commands.run") { [self] v in commandRun(v.s("id")) }
    env.on("tips.preview") { [self] v in preview(v.s("key"), v) }
    env.on("settings.opened") { [self] v in
      if v.s("via") == "menu" { showSettingsHelp() }
    }
    // Listen for tour start from tips plugin
    env.on("tour.start") { [self] _ in startTour() }
    // Listen for tour step completion from tips plugin
    env.on("tour.step.pin") { [self] _ in if step == 0 { advance() } }
    env.on("tour.step.command") { [self] _ in if step == 1 { advance() } }
    env.on("tour.step.space") { [self] _ in if step == 2 { advance() } }
    env.on("tour.step.peek") { [self] _ in if step == 3 { advance() } }
    env.on("tour.step.library") { [self] _ in if step == 4 { advance() } }
    env.on("tour.step.settings") { [self] _ in dismissCallout() }
  }

  func action(_ id: String, _ action: String, _ value: Value) {
    switch id {
    case "tour.next":
      advance()
    case "tour.skip":
      skipTour()
    case "tour.close":
      dismissCallout()
    case Self.calloutId:
      if action == "toast" { dismissCallout() }
    default:
      break
    }
  }

  func commandRun(_ id: String) {
    if id == Self.firstRunCommand { startTour(); return }
    if id == Self.discoveryCommand { offerDiscoveryTip(); return }
    if step != nil { advance() }
  }

  /// `tour.preview {key}` (snapshot scenarios): show a callout for testing.
  func preview(_ key: String, _ v: Value) {
    started = true
    switch key {
    case "first":
      tourState = "running"
      step = Int(v.i("step"))
      showCallout()
    case "discovery":
      showDiscoveryStep(Int(v.i("index")))
    default:
      break
    }
  }

  func showDiscoveryStep(_ index: Int) {
    guard index >= 0, index < Self.discoveryTips.count else { return }
    let tip = Self.discoveryTips[index]
    let cardTree: Value = [
      "type": "stack", "id": .string(Self.calloutId), "spacing": 8,
      "padding": [10, 10, 12, 12],
      "children": [
        ["type": "stack", "axis": "h", "spacing": 8, "align": "center", "children": [
          ["type": "icon", "spec": .string(tip.icon), "size": 15, "tone": "accent"],
          ["type": "label", "text": "Did you know?", "size": 12, "weight": "semibold"],
          Self.closeButton("tour.close", "Dismiss"),
        ]],
        ["type": "label", "text": .string(tip.text), "size": 12, "lines": 3],
        ["type": "action", "id": "tour.next", "variant": "pill", "tone": "primary",
         "title": .string(tip.done), "height": 28],
      ],
    ]

    env.call("ui", "card", [
      "id": .string(Self.calloutId), "tree": cardTree,
      "place": .string("trailing"),
      "width": .double(280),
      "gap": .double(8),
    ])
    showing = true
  }
}
