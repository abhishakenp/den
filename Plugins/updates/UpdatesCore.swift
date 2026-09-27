#if !hasFeature(Embedded)
  import CordisValue
#endif

/// Update policy: channels, schedule, what to install, when to relaunch, and every string the
/// user sees. The host `updates` service only fetches, verifies, places files and bridges Sparkle.
///
/// Channels (`[updates] channel` in ~/.den/config.toml):
/// - `stable` / `prerelease`: host updates through Sparkle (appcast on GitHub), plugin updates
///   from `plugins.json` (a conditional GET: 304 when nothing changed). Checked 1 min after launch,
///   then every `check_hours` (6). Unverifiable plugins never load (the host checks sha256 + EdDSA).
/// - `follow-main` (developers): scripts/updater.sh builds pushed commits of main. Plugins land
///   live; a host install shows "den updated — restart to apply". Default when the updater's
///   state file exists and no channel is set.
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
  static let manifestURL = "https://raw.githubusercontent.com/abhishakenp/den/main/updates/plugins.json"

  let env: PluginEnv
  var info: Value = .null
  var channel = "stable"
  var etag = ""
  var lastCheck: Int64 = 0
  var lastResult = ""
  var installed: [(String, String)] = []  // id -> sha256 installed from a manifest
  var bad: [String] = []  // sha256s that failed or crashed
  var pendingRestart = ""  // "follow-main" or "sparkle" when a host update waits for a relaunch
  var pendingVersion = ""
  var backgroundSince: Int64 = 0
  var manual = false
  var followState: Value = .null
  var commandRegistered = false
  var registerAttempts = 0
  var policyTimerOn = false
  var checkTimerOn = false
  var stopped = false

  init(env: PluginEnv) { self.env = env }

  func start() {
    info = env.call("updates", "info")
    let st = env.call("storage", "get", ["ns": .string(Self.ns), "key": "state"])
    etag = st.s("etag")
    lastCheck = st.i("lastCheck")
    lastResult = st.s("lastResult")
    for p in st.a("installed") { installed.append((p.s("id"), p.s("sha256"))) }
    bad = st.a("bad").compactMap { $0.string }
    followState = env.call("updates", "state")
    channel = pickChannel(env.call("config", "get", ["key": "updates"]))

    env.on("config.changed") { [self] v in
      let c = pickChannel(v["config"]["updates"])
      if c != channel {
        channel = c
        configureSparkle()
        about()
      }
    }
    env.on("updates.stateChanged") { [self] v in followMainState(v["state"]) }
    env.on("updates.fetched") { [self] v in if v.s("url") == manifestURL() { manifest(v) } }
    env.on("updates.pluginInstalled") { [self] v in pluginInstalled(v) }
    env.on("updates.sparkle") { [self] v in sparkle(v) }
    env.on("commands.run") { [self] v in if v.s("id") == Self.commandId { check(manual: true) } }
    env.on("ui.action") { [self] v in
      if v.s("id") == Self.toastId && v.s("action") == "toast" { restartNow(background: false) }
    }
    rollbackCrashed()
    configureSparkle()
    registerCommand()
    followMainState(followState)
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
    if c == "stable" || c == "prerelease" || c == "follow-main" { return c }
    return followState.isNull ? "stable" : "follow-main"
  }

  var usesReleases: Bool { channel != "follow-main" }

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
      let hours = setting("check_hours", 6)
      env.timer(UInt64(max(hours, 1)) * 3_600_000, true) { [self] in if !stopped { check(manual: false) } }
    }
  }

  func check(manual m: Bool) {
    manual = m
    if !usesReleases {
      if m { toast("Checking for updates…", icon: "sf:arrow.triangle.2.circlepath", action: "", duration: 2500) }
      env.call("updates", "kickUpdater")
      return
    }
    if m { toast("Checking for updates…", icon: "sf:arrow.triangle.2.circlepath", action: "", duration: 2500) }
    env.call("updates", "fetch", ["url": .string(manifestURL()), "etag": .string(etag), "json": true])
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
      if entry.isNull { entry = channels["stable"] }
      let n = installUpdates(entry)
      lastResult = n == 0 ? "Plugins are up to date" : "Updating " + String(n) + (n == 1 ? " plugin" : " plugins")
    } else {
      lastResult = "Couldn't check for updates" + (v.s("error").isEmpty ? "" : ": " + v.s("error"))
    }
    save()
    about()
    if manual && pendingRestart.isEmpty {
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

  func followMainState(_ state: Value) {
    let prevCheck = followState.s("lastCheck")
    followState = state
    guard !state.isNull else { return }
    channel = pickChannel(env.call("config", "get", ["key": "updates"]))
    // The app on disk is a different build than the one running: an update was installed.
    // (Asked of the host, not state.json: a build installed by hand is not an update.)
    let running = info.s("commit"), onDisk = env.call("updates", "info").s("onDiskCommit")
    if !onDisk.isEmpty, !running.isEmpty, onDisk != running {
      hostUpdateReady(kind: "follow-main", version: onDisk)
    } else if pendingRestart == "follow-main" {
      pendingRestart = ""
      env.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "id": .string(Self.toastId), "dismiss": true]])
    } else if manual && state.s("lastCheck") != prevCheck {
      manual = false
      toast(state.s("lastResult").isEmpty ? "den is up to date" : state.s("lastResult"), icon: "sf:checkmark.circle", action: "", duration: 3000)
    }
    about()
  }

  func sparkle(_ v: Value) {
    switch v.s("phase") {
    case "found":
      pendingVersion = v.s("version")
      env.call("updates", "sparkleReply", ["choice": "install"])  // download in the background
    case "ready": hostUpdateReady(kind: "sparkle", version: v.sOpt("version") ?? pendingVersion)
    case "none":
      if manual && lastResult == "Plugins are up to date" { manual = false }
    case "error": env.log("host update check failed: " + v.s("error"))
    default: break
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
    if channel == "follow-main" && !followState.isNull {
      text += "Deployed: " + Self.short(followState.s("deployed")) + " at " + followState.s("deployedAt") + "\n"
      text += "Last check: " + followState.s("lastCheck")
      if !followState.s("lastResult").isEmpty { text += " — " + followState.s("lastResult") }
    } else {
      text += "Last check: " + (lastCheck == 0 ? "never" : Self.utc(lastCheck))
      if !lastResult.isEmpty { text += " — " + lastResult }
    }
    env.call("app", "setAbout", ["credits": .string(text)])
  }

  func save() {
    env.call("storage", "set", ["ns": .string(Self.ns), "key": "state", "value": [
      "etag": .string(etag), "lastCheck": .int(lastCheck), "lastResult": .string(lastResult),
      "installed": .array(installed.map { ["id": .string($0.0), "sha256": .string($0.1)] }),
      "bad": .array(bad.suffix(50).map { .string($0) }),
    ]])
  }

  static func short(_ sha: String) -> String {
    var out = ""
    for c in sha.unicodeScalars.prefix(7) { out.unicodeScalars.append(c) }
    return out
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
