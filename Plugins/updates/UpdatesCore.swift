#if !hasFeature(Embedded)
  import CordisValue
#endif

/// Update policy: channels, schedule, what to install, when to relaunch, and every string the
/// user sees. The host `updates` service only fetches, verifies, places files and bridges Sparkle.
///
/// Channels (`[updates] channel` in ~/.den/config.toml, also the Updates settings panel):
/// - `stable` / `prerelease`: host updates through Sparkle (appcast on GitHub), plugin updates
///   from `plugins.json` (a conditional GET: 304 when nothing changed). Checked 1 min after launch,
///   then every `check_hours` (6). Unverifiable plugins never load (the host checks sha256 + EdDSA).
///
/// Relaunch (host updates), never while media plays:
/// - den not frontmost for `relaunch_background_s` (60 s): relaunch in the background;
/// - den frontmost but no input for `relaunch_idle_min` (10 min): relaunch;
/// - or the toast's Restart button.
/// A plugin update that fails to apply is rolled back; one whose build crashed den is rolled
/// back at the next launch. Either way that build (sha256) is never installed again.
final class UpdatesCore {
  static let ns = "updates"
  static let commandId = "den.checkForUpdates"
  static let toastId = "updates.toast"
  static let whatsNewId = "updates.whatsNew"
  static let settingsId = "updates"
  static let manifestURL = "https://raw.githubusercontent.com/abhishakenp/den/main/updates/plugins.json"
  /// Every release's notes ride in the appcast's `<description>`: the history list reads them.
  static let appcastURL = "https://raw.githubusercontent.com/abhishakenp/den/main/updates/appcast.xml"

  let env: PluginEnv
  var info: Value = .null
  var channel = "stable"
  var etag = ""
  var lastCheck: Int64 = 0
  var lastResult = ""
  var installed: [(String, String)] = []  // id -> sha256 installed from a manifest
  var bad: [String] = []  // sha256s that failed or crashed
  var pendingRestart = ""  // "sparkle" when a host update waits for a relaunch
  var pendingVersion = ""
  var pendingChangelog: String = ""
  /// Every release, newest first (appcast order), cached in storage so the list works offline.
  var history: [Release] = []
  /// The running version was not the one last seen: show "What's new" once its notes are known.
  var whatsNewPending = false
  var sparklePhase: String = ""  // checking, found, downloading, ready, none, error
  var sparkleError: String = ""
  var backgroundSince: Int64 = 0
  var manual = false
  var commandRegistered = false
  var registerAttempts = 0
  var settingsRegisterAttempts = 0
  var policyTimerOn = false
  var checkTimerOn = false
  var stopped = false
  var settingsRegistered = false

  init(env: PluginEnv) { self.env = env }

  func start() {
    info = env.call("updates", "info")
    let st = env.call("storage", "get", ["ns": .string(Self.ns), "key": "state"])
    etag = st.s("etag")
    lastCheck = st.i("lastCheck")
    lastResult = st.s("lastResult")
    for p in st.a("installed") { installed.append((p.s("id"), p.s("sha256"))) }
    bad = st.a("bad").compactMap { $0.string }
    channel = pickChannel(env.call("config", "get", ["key": "updates"]))
    history = env.call("storage", "get", ["ns": .string(Self.ns), "key": "history"]).a("releases").map {
      Release(version: $0.s("version"), date: $0.s("date"), notes: $0.s("notes"))
    }
    // Nothing cached yet (before the first check, or offline): the history bundled with this build.
    if history.isEmpty { history = Self.parseAppcast(env.call("updates", "bundledAppcast").s("body")) }
    prepareWhatsNew()

    env.on("config.changed") { [self] v in
      let c = pickChannel(v["config"]["updates"])
      if c != channel {
        channel = c
        configureSparkle()
        about()
        if settingsRegistered { registerSettings() }
      }
    }
    startNotices()
    env.on("updates.fetched") { [self] v in
      if v.s("url") == manifestURL() { manifest(v) } else if v.s("url") == Self.appcastURL { appcast(v) }
    }
    env.on("updates.pluginInstalled") { [self] v in pluginInstalled(v) }
    env.on("updates.sparkle") { [self] v in sparkle(v) }
    env.on("commands.run") { [self] v in if v.s("id") == Self.commandId { check(manual: true) } }
    env.on("ui.action") { [self] v in
      if v.s("id") == Self.toastId && v.s("action") == "toast" { restartNow(background: false) }
      if v.s("id") == Self.whatsNewId { env.call("ui", "set", ["slot": "dialog", "tree": nil]) }
    }
    env.on("settings.action") { [self] v in
      if v.s("id") == Self.settingsId { settingsAction(v.s("key")) }
    }
    env.on("settings.changed") { [self] v in
      if v.s("id") == Self.settingsId, v.s("key") == "channel", let c = v["value"].string {
        // Persist to config.toml
        env.call("config", "set", ["key": .string("updates"), "value": ["channel": .string(c)]])
        setChannel(c)
      }
    }
    rollbackCrashed()
    configureSparkle()
    registerCommand()
    tryRegisterSettings()
    about()
    scheduleChecks()
  }

  func stop() {
    stopped = true
    registerAttempts = Int.max / 2
  }

  // MARK: Channel

  func pickChannel(_ section: Value) -> String {
    let c = section.s("channel")
    return c == "prerelease" || c == "main" ? c : "stable"
  }

  var usesReleases: Bool { true }

  func setting(_ key: String, _ fallback: Int64) -> Int64 {
    let v = env.call("config", "get", ["key": .string("updates." + key)])
    if let i = v.int { return i }
    if let d = v.double { return Int64(d) }
    return fallback
  }

  func manifestURL() -> String {
    let v = env.call("config", "get", ["key": "updates.plugins_url"]).string ?? ""
    return v.isEmpty ? Self.manifestURL : v
  }

  func configureSparkle() {
    guard usesReleases, info.b("sparkle") else { return }
    env.call("updates", "sparkleConfigure", ["channel": .string(channel)])
  }

  // MARK: Checks

  func scheduleChecks() {
    guard !checkTimerOn else { return }
    checkTimerOn = true
    // First check a minute after launch, then every check_hours.
    env.timer(60_000, false) { [self] in
      guard !stopped else { return }
      check(manual: false)
      // main (developers): hourly, whatever check_hours says.
      let hours = channel == "main" ? 1 : setting("check_hours", 6)
      env.timer(UInt64(max(hours, 1)) * 3_600_000, true) { [self] in if !stopped { check(manual: false) } }
    }
  }

  func check(manual m: Bool) {
    manual = m
    if m { toast("Checking for updates…", icon: "sf:arrow.triangle.2.circlepath", action: "", duration: 2500) }
    env.call("updates", "fetch", ["url": .string(manifestURL()), "etag": .string(etag), "json": true])
    env.call("updates", "fetch", ["url": .string(Self.appcastURL)])
    if info.b("sparkle") { env.call("updates", "sparkleCheck", ["userInitiated": false]) }
  }

  /// plugins.json: {channels: {stable|prerelease: {version, tag, hostAPI, plugins: [{id, version, sha256, signature, url, hostAPI}]}}}
  func manifest(_ v: Value) {
    lastCheck = env.now()
    let status = v.i("status")
    if status == 304 {
      lastResult = "Plugins are up to date"
    } else if status == 200 {
      etag = v.s("etag")
      let channels = v["value"]["channels"]
      var entry = channels[channel]
      if entry.isNull, channel == "main" { entry = channels["prerelease"] }
      if entry.isNull { entry = channels["stable"] }
      let n = installUpdates(entry)
      lastResult = n == 0 ? "Plugins are up to date" : "Updating " + String(n) + (n == 1 ? " plugin" : " plugins")
    } else {
      lastResult = "Couldn't check for updates" + (v.s("error").isEmpty ? "" : ": " + v.s("error"))
    }
    save()
    about()
    if settingsRegistered { registerSettings() }
    // Sparkle checks asynchronously; don't show "up to date" before its result arrives.
    if manual && pendingRestart.isEmpty, sparklePhase == "none" || sparklePhase == "" || sparklePhase == "ready" {
      manual = false
      toast(lastResult == "Plugins are up to date" ? "den is up to date" : lastResult, icon: "sf:checkmark.circle", action: "", duration: 2500)
    }
  }

  /// Installs every plugin from `entry` built for this host whose file differs from the loaded
  /// one. Returns how many were requested.
  func installUpdates(_ entry: Value) -> Int {
    let hostAPI = info["hostAPI"].int
    var loaded: [(String, String)] = []
    for p in env.call("updates", "plugins").array ?? [] { loaded.append((p.s("id"), p.s("sha256"))) }
    var n = 0
    for p in entry.a("plugins") {
      let id = p.s("id"), sha = p.s("sha256")
      guard !id.isEmpty, !sha.isEmpty, !bad.contains(sha) else { continue }
      // Built for another host: the host update (Sparkle) brings it.
      if let h = hostAPI, let need = p["hostAPI"].int, need != h { continue }
      if loaded.contains(where: { $0.0 == id && $0.1 == sha }) { continue }
      env.call("updates", "installPlugin", [
        "id": .string(id), "url": p["url"], "sha256": .string(sha), "signature": p["signature"], "version": p["version"],
        "hostAPI": p["hostAPI"], "permissions": p["permissions"], "source": "release",
      ])
      n += 1
    }
    return n
  }

  func pluginInstalled(_ v: Value) {
    let id = v.s("id")
    if !v.b("ok") {
      env.log("update of " + id + " rejected: " + v.s("error"))
      return
    }
    let sha = shaOfManaged(id)
    if !v.b("active") {
      // Didn't apply: back to the previous build, and never this one again.
      env.call("updates", "rollbackPlugin", ["id": .string(id)])
      if !sha.isEmpty { bad.append(sha) }
      env.log("update of " + id + " failed to apply; rolled back")
    } else {
      installed.removeAll { $0.0 == id }
      installed.append((id, sha))
      env.log("updated " + id)
    }
    save()
  }

  func shaOfManaged(_ id: String) -> String {
    for p in env.call("updates", "plugins").array ?? [] where p.s("id") == id && p.s("layer") == "managed" { return p.s("sha256") }
    for (i, s) in installed where i == id { return s }
    return ""
  }

  /// A managed plugin cordis refused at launch (its build crashed den): restore the previous one.
  func rollbackCrashed() {
    for c in info.a("crashed") {
      guard let id = c.string else { continue }
      for (i, sha) in installed where i == id { bad.append(sha) }
      env.call("updates", "rollbackPlugin", ["id": .string(id)])
      env.log("rolled back " + id + " after a crash")
    }
    if !info.a("crashed").isEmpty { save() }
  }

  // MARK: Host updates

  func sparkle(_ v: Value) {
    sparklePhase = v.s("phase")
    switch sparklePhase {
    case "found":
      pendingVersion = v.s("version")
      pendingChangelog = v.s("changelog")
      env.call("updates", "sparkleReply", ["choice": "install"])  // download in the background
    case "ready":
      hostUpdateReady(kind: "sparkle", version: v.sOpt("version") ?? pendingVersion)
    case "none":
      pendingVersion = ""
      if manual {
        manual = false
        if settingsRegistered { registerSettings() }
        let msg = lastResult == "Plugins are up to date" ? "den is up to date" : lastResult
        toast(msg, icon: "sf:checkmark.circle", action: "", duration: 2500)
      }
    case "error":
      sparkleError = v.s("error") ?? "Update check failed"
    case "downloading":
      pendingVersion = v.s("version") ?? pendingVersion
    case "checking":
      break
    default:
      break
    }
  }

  func hostUpdateReady(kind: String, version: String) {
    let first = pendingRestart.isEmpty
    pendingRestart = kind
    pendingVersion = version
    if first {
      toast("den updated — restart to apply", icon: "sf:arrow.clockwise", action: "Restart", duration: 0)
      backgroundSince = 0
      startPolicy()
    }
  }

  func startPolicy() {
    guard !policyTimerOn else { return }
    policyTimerOn = true
    env.timer(15_000, true) { [self] in if !stopped { policyTick() } }
  }

  func mediaPlaying() -> Bool {
    for id in env.call("webviews", "list").array ?? [] where env.call("webviews", "get", ["id": id]).b("audio") { return true }
    return false
  }

  /// Every 15 s while a host update waits (timers only; nothing runs otherwise).
  func policyTick() {
    guard !pendingRestart.isEmpty else { return }
    let st = env.call("app", "state")
    let now = env.now()
    let active = st.b("active")
    if active {
      backgroundSince = 0
    } else if backgroundSince == 0 {
      backgroundSince = now
    }
    if mediaPlaying() { return }
    let bgMs = setting("relaunch_background_s", 60) * 1000
    let idleS = Double(setting("relaunch_idle_min", 10) * 60)
    if !active && now - backgroundSince >= bgMs {
      restartNow(background: true)
    } else if active, let idle = st["idleSeconds"].double, idle >= idleS {
      restartNow(background: false)
    }
  }

  func restartNow(background: Bool) {
    guard !pendingRestart.isEmpty else { return }
    env.log("relaunching for the " + pendingRestart + " update (background: " + (background ? "yes" : "no") + ")")
    if pendingRestart == "sparkle" {
      env.call("updates", "sparkleReply", ["choice": "install"])
    } else {
      env.call("app", "relaunch", ["background": .bool(background)])
    }
  }

  // MARK: UI

  func toast(_ text: String, icon: String, action: String, duration: Int64) {
    var t: Value = ["type": "toast", "id": .string(Self.toastId), "text": .string(text), "icon": .string(icon), "duration": .int(duration)]
    if !action.isEmpty { t.put("action", .string(action)) }
    env.call("ui", "set", ["slot": "toast", "tree": t])
  }

  func registerCommand() {
    if tryRegister() { return }
    env.timer(500, false) { [self] in
      registerAttempts += 1
      if !tryRegister(), registerAttempts < 60 { registerCommand() }
    }
  }

  func tryRegister() -> Bool {
    if commandRegistered { return true }
    let r = env.call("commands", "register", [
      "id": .string(Self.commandId), "title": "Check for Updates…", "icon": "sf:arrow.triangle.2.circlepath",
      "keywords": ["update", "upgrade", "version", "release"], "owner": "updates",
    ])
    guard !r.isErr else { return false }
    commandRegistered = true
    return true
  }

  /// The About panel: version, channel, and when den last looked for updates.
  func about() {
    let short = Self.short(info.s("commit"))
    var text = "Version " + info.s("version") + " (" + String(info.i("build")) + (short.isEmpty ? "" : ", " + short) + ")\n"
    text += "Update channel: " + channel + "\n"
    text += "Last check: " + (lastCheck == 0 ? "never" : localTime(lastCheck))
    if !lastResult.isEmpty { text += " — " + lastResult }
    if !installed.isEmpty { text += "\nPlugins updated since this release: " + String(installed.count) }
    env.call("app", "setAbout", ["credits": .string(text)])
  }

  // MARK: Settings panel

  /// Register the Updates section in Settings.
  /// Like `registerCommand()`, retries up to 60 times if the service isn't ready.
  func tryRegisterSettings() -> Bool {
    if settingsRegistered { return true }
    let r = doRegisterSettings()
    guard !r.isErr else {
      settingsRegisterAttempts += 1
      if settingsRegisterAttempts < 60 {
        env.timer(500, false) { [self] in tryRegisterSettings() }
      }
      return false
    }
    settingsRegistered = true
    return true
  }

  /// Public entry: the first time through the retry wrapper; once registered, registers again so
  /// the panel shows the new state. (It used to return early once registered, so nothing after
  /// launch reached the panel: not the version history the first check fetched, not "Last check".)
  func registerSettings() {
    if settingsRegistered { _ = doRegisterSettings() } else { _ = tryRegisterSettings() }
  }

  /// Actual settings registration logic.
  private func doRegisterSettings() -> Value {
    let currentVersion = info.s("version")
    let buildNum = String(info.i("build"))
    let shortCommit = Self.short(info.s("commit"))

    // Determine what state we're in and what buttons/info to show
    var controls: [Value] = []

    // Current version info
    let versionInfo = shortCommit.isEmpty
      ? "Version \(currentVersion) (\(buildNum))"
      : "Version \(currentVersion) (\(buildNum), \(shortCommit))"
    controls.append(["key": .string("currentVersion"), "type": .string("info"), "title": .string("Current version"), "value": .string(versionInfo)])

    // Check for updates button
    controls.append(["key": .string("checkForUpdates"), "type": .string("button"), "title": .string("Check for Updates…"), "icon": .string("sf:arrow.triangle.2.circlepath")])

    // Channel selector
    controls.append(["key": .string("channel"), "type": .string("choice"), "title": .string("Update channel"), "default": .string(channel),
      "options": .array([["value": .string("stable"), "title": .string("Stable")],
                         ["value": .string("prerelease"), "title": .string("Prerelease (alpha/beta)")],
                         ["value": .string("main"), "title": .string("Main (developers, checks hourly)")]])])

    // Pending restart info/button
    if !pendingRestart.isEmpty, !pendingVersion.isEmpty {
      controls.append(["key": .string("restartUpdate"), "type": .string("button"), "title": .string("Restart to Apply Update (\(pendingVersion))"), "icon": .string("sf:arrow.clockwise")])
      controls.append(["key": .string("updateReady"), "type": .string("info"), "title": .string("Update ready"), "value": .string("A new version (\(pendingVersion)) is ready. Restart den to apply it.")])
    } else if sparklePhase == "ready", !pendingVersion.isEmpty {
      controls.append(["key": .string("sparkleReady"), "type": .string("info"), "title": .string("Update ready"), "value": .string("den \(pendingVersion) is downloaded and ready.")])
    } else if sparklePhase == "downloading" {
      controls.append(["key": .string("downloading"), "type": .string("info"), "title": .string("Downloading update…"), "value": .string("Please wait while den downloads the update.")])
    } else if sparklePhase == "checking" {
      controls.append(["key": .string("checking"), "type": .string("info"), "title": .string("Checking…"), "value": .string("Checking for updates. Please wait.")])
    } else if sparkleError.count > 10 {
      controls.append(["key": .string("error"), "type": .string("info"), "title": .string("Update check failed"), "value": .string(sparkleError)])
    } else if lastCheck > 0 {
      // Local time, and the result on its own row: one line of both was cut off ("2026-10-18 12:51 U…").
      controls.append(["key": .string("lastCheck"), "type": .string("info"), "title": .string("Last check"), "value": .string(localTime(lastCheck))])
      controls.append(["key": .string("lastResult"), "type": .string("info"), "title": .string("Result"), "value": .string(lastResult.isEmpty ? "No issues" : lastResult)])
    }

    // What's new: the update's changelog (from the appcast), when one is found or ready.
    if !pendingVersion.isEmpty {
      var notes = Self.trimmed(pendingChangelog)
      if notes.count > 600 { notes = String(notes.prefix(600)) + "…" }
      controls.append(["key": .string("whatsNew"), "type": .string("info"),
                       "title": .string("What's new in \(pendingVersion)"),
                       "value": .string(notes.isEmpty ? "See the release notes on GitHub for \(pendingVersion)." : notes)])
    }

    // Every version, newest first, the installed one marked; the new one shows at the top once
    // the appcast lists it. The settings window scrolls it.
    controls.append(["key": .string("history"), "type": .string("list"), "title": .string("Version history"),
                     "items": .array(historyItems(current: currentVersion)), "empty": .string("No release notes in this build.")])

    let r = env.call("settings", "register", [
      "id": .string(Self.settingsId), "title": .string("Updates"), "icon": .string("sf:arrow.triangle.2.circlepath"),
      "order": .int(90), "controls": .array(controls),
    ])
    settingsRegistered = !r.isErr
    return r
  }

  /// Handle button clicks in the settings panel.
  func settingsAction(_ key: String) {
    switch key {
    case "checkForUpdates":
      check(manual: true)
    case "restartUpdate":
      if !pendingRestart.isEmpty {
        restartNow(background: false)
      }
    case "channel":
      break  // handled by settings.changed
    default:
      break
    }
  }

  /// Set the update channel.
  func setChannel(_ newChannel: String) {
    let allowed = ["stable", "prerelease", "main"]
    guard allowed.contains(newChannel) else { return }
    channel = newChannel
    configureSparkle()
    about()
    registerSettings()  // refresh the UI
  }

  func save() {
    env.call("storage", "set", ["ns": .string(Self.ns), "key": "state", "value": [
      "etag": .string(etag), "lastCheck": .int(lastCheck), "lastResult": .string(lastResult),
      "installed": .array(installed.map { ["id": .string($0.0), "sha256": .string($0.1)] }),
      "bad": .array(bad.suffix(50).map { .string($0) }),
    ]])
  }

  /// Whitespace-trimmed copy (no Foundation in plugins).
  static func trimmed(_ s: String) -> String {
    var b = Array(s.unicodeScalars)
    while let f = b.first, f == " " || f == "\n" || f == "\t" || f == "\r" { b.removeFirst() }
    while let l = b.last, l == " " || l == "\n" || l == "\t" || l == "\r" { b.removeLast() }
    return String(String.UnicodeScalarView(b))
  }

  static func short(_ sha: String) -> String {
    var out = ""
    for c in sha.unicodeScalars.prefix(7) { out.unicodeScalars.append(c) }
    return out
  }

  /// When `ms` was, in the Mac's time zone (the host's clock; plugins have no time zones):
  /// "Today, 2:51 PM", or "Sunday, October 18, 2:51 PM".
  func localTime(_ ms: Int64) -> String {
    let c = env.call("schedule", "clock", ["ms": .int(ms)])
    guard !c.s("time").isEmpty else { return Self.utc(ms) }
    let today = env.call("schedule", "clock", ["ms": .int(env.now())]).s("date")
    return (c.s("date") == today ? "Today" : c.s("date")) + ", " + c.s("time")
  }

  /// "2026-09-27 19:40 UTC" from epoch milliseconds (no Foundation in plugins).
  static func utc(_ ms: Int64) -> String {
    let secs = ms / 1000
    let days = secs / 86400
    let rem = secs % 86400
    // Civil date from days since 1970-01-01 (Howard Hinnant's algorithm).
    let z = days + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp < 10 ? mp + 3 : mp - 9
    let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
    return String(y) + "-" + pad(m) + "-" + pad(d) + " " + pad(rem / 3600) + ":" + pad(rem % 3600 / 60) + " UTC"
  }

  static func pad(_ n: Int64) -> String { n < 10 ? "0" + String(n) : String(n) }
}


// MARK: - Release history (appcast) and "What's new"

struct Release {
  var version: String
  var date: String
  var notes: String
}

extension UpdatesCore {
  /// The Updates panel's version list: every release, the installed one marked.
  func historyItems(current: String) -> [Value] {
    history.map { rel in
      let mine = rel.version == current
      return ["id": .string(rel.version), "icon": .string(mine ? "sf:checkmark.circle.fill" : "sf:clock.arrow.circlepath"),
              "title": .string("den " + rel.version + (mine ? " (installed)" : "") + (rel.date.isEmpty ? "" : " — " + rel.date)),
              "subtitle": .string(rel.notes.isEmpty ? "No notes." : rel.notes)]
    }
  }

  /// A fetched appcast: parse, cache, refresh the list, and show "What's new" if it waits.
  func appcast(_ v: Value) {
    guard v.i("status") == 200 else { return }
    let parsed = Self.parseAppcast(v.s("body"))
    guard !parsed.isEmpty else { return }
    history = parsed
    env.call("storage", "set", ["ns": .string(Self.ns), "key": "history", "value": [
      "releases": .array(parsed.prefix(60).map { ["version": .string($0.version), "date": .string($0.date), "notes": .string($0.notes)] }),
    ]])
    if settingsRegistered { registerSettings() }
    showWhatsNew()
  }

  /// First run records the version. A different one than last time: fetch the notes, show them once.
  func prepareWhatsNew() {
    let running = info.s("version")
    let seen = env.call("storage", "get", ["ns": .string(Self.ns), "key": "seen"]).s("version")
    guard !running.isEmpty, seen != running else { return }
    env.call("storage", "set", ["ns": .string(Self.ns), "key": "seen", "value": ["version": .string(running)]])
    guard !seen.isEmpty else { return }  // first launch ever: nothing was updated
    whatsNewPending = true
    // The cached list may already hold it (an update that fetched before relaunching); the
    // fetch refreshes it, and covers a fallback after a few seconds when the network is down.
    env.call("updates", "fetch", ["url": .string(Self.appcastURL)])
    env.timer(8000, false) { [self] in
      guard whatsNewPending else { return }
      present(history.first { $0.version == running } ?? Release(version: running, date: "", notes: ""))
    }
  }

  /// A dismissable dialog, once, with the running version's notes.
  func showWhatsNew() {
    guard whatsNewPending else { return }
    guard let rel = history.first(where: { $0.version == info.s("version") }) else { return }  // the 8 s fallback shows it without notes
    present(rel)
  }

  func present(_ rel: Release) {
    whatsNewPending = false
    var notes = Self.trimmed(rel.notes)
    if notes.isEmpty { notes = "See the release notes on GitHub." }
    if notes.utf8.count > 900 { notes = String(decoding: Array(notes.utf8)[0..<900], as: UTF8.self) + "…" }
    env.call("ui", "set", ["slot": "dialog", "tree": [
      "type": "dialog", "id": .string(Self.whatsNewId), "icon": "sf:sparkles",
      "title": .string("What's new in den " + rel.version), "message": .string(notes),
      "buttons": [["id": "ok", "title": "OK", "default": true]],
    ]])
  }

  /// <item> blocks of a Sparkle appcast: version, date and description (CDATA). No Foundation here.
  static func parseAppcast(_ xml: String) -> [Release] {
    let b = Array(xml.utf8)
    var out: [Release] = []
    var at = 0
    while let s = find(b, "<item>", from: at), let e = find(b, "</item>", from: s) {
      let item = Array(b[s..<e])
      let v = tag(item, "sparkle:shortVersionString")
      if !v.isEmpty {
        var date = tag(item, "pubDate")
        // "Wed, 14 Oct 2026 17:38:10 +0000" -> "14 Oct 2026"
        date = dayMonthYear(date)
        var d = tag(item, "description")
        if Text.hasPrefix(d, "<![CDATA[") { d = Text.dropPrefix(d, "<![CDATA[") }
        if Text.hasSuffix(d, "]]>") { d = String(decoding: Array(d.utf8).dropLast(3), as: UTF8.self) }
        out.append(Release(version: v, date: date, notes: trimmed(d)))
      }
      at = e + 7
    }
    return out
  }

  /// "Wed, 14 Oct 2026 17:38:10 +0000" -> "14 Oct 2026" (the words 2-4); the input if it isn't that.
  static func dayMonthYear(_ s: String) -> String {
    var words: [[UInt8]] = [[]]
    for c in s.utf8 { if c == 32 { words.append([]) } else { words[words.count - 1].append(c) } }
    guard words.count >= 4 else { return s }
    var out: [UInt8] = words[1]
    out.append(32); out += words[2]; out.append(32); out += words[3]
    return String(decoding: out, as: UTF8.self)
  }

  static func find(_ h: [UInt8], _ needle: String, from: Int) -> Int? {
    let n = Array(needle.utf8)
    guard h.count >= n.count, from <= h.count - n.count else { return nil }
    var i = from
    while i <= h.count - n.count {
      if h[i] == n[0] {
        var ok = true
        for j in 1..<n.count where h[i + j] != n[j] { ok = false; break }
        if ok { return i }
      }
      i += 1
    }
    return nil
  }

  static func tag(_ item: [UInt8], _ name: String) -> String {
    guard let s = find(item, "<" + name + ">", from: 0) else { return "" }
    let from = s + name.utf8.count + 2
    guard let e = find(item, "</" + name + ">", from: from) else { return "" }
    return trimmed(String(decoding: item[from..<e], as: UTF8.self))
  }
}
