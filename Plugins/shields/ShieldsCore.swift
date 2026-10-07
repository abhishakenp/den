#if !hasFeature(Embedded)
  import CordisValue
#endif

/// Shields: clean, private browsing (docs/plugin-services.md#shields, docs/guide/privacy-and-passwords.md).
///
/// - Blocking: EasyList/EasyPrivacy/EasyList Cookie List, shipped pre-compiled as WebKit content
///   rules (ShieldsLists.swift) and attached per site through the host `sitepolicy` service.
/// - Clean navigation: tracking parameters stripped and bounce redirects skipped on every
///   main-frame navigation (CleanLinks.swift), through `sitepolicy`'s navigation guard.
/// - HTTPS-first with den's interstitial, lookalike-domain warnings (Lookalike.swift).
/// - The per-site panel (the shield in the URL pill, ⌥⌘S), Settings > Shields, commands.
/// Global choices live in the `settings` service (id `shields`); per-site ones in storage ns `shields`.
final class ShieldsCore {
  static let ns = "shields"
  static let panelId = "shields.panel"
  static let pillId = "tabs.url"
  static let autoplayOptions: [(String, String)] = [("sound", "Block Sound"), ("allow", "Allow"), ("none", "Block All")]
  static let popupOptions: [(String, String)] = [("block", "Block"), ("allow", "Allow")]
  /// The panel's per-answer camera/microphone rows; `ask` forgets the answer, so the site asks again.
  static let permissionOptions: [(String, String)] = [("allow", "Allow"), ("block", "Block"), ("ask", "Ask First")]
  static let globals: [(String, Bool)] = [("blocker", true), ("cookies", true), ("params", true), ("bounce", true), ("https", true), ("lookalike", true)]

  struct Site: Equatable {
    var blocker: Bool?
    var cookies: Bool?
    var autoplay: String?
    var popups: String?
    var isEmpty: Bool { blocker == nil && cookies == nil && autoplay == nil && popups == nil }
  }

  let env: PluginEnv
  var flags: [String: Bool] = [:]
  var autoplay = "sound"
  var sites: [String: Site] = [:]
  var httpAllowed: [String] = []
  var lookalikeAllowed: [String] = []
  var requested: [String] = []  // lists asked of sitepolicy
  var ready: [String] = []
  var scriptletsRequested = false
  var scriptletsReady = false
  var scriptletsVersion = ""
  var support: Value = .null

  var panelOpen = false
  var panelWebview = ""
  var panelHost = ""
  /// The remembered answers the panel's `shields.permission.<n>` rows were built from (in order).
  var panelPerms: [(origin: String, kind: String)] = []
  var pendingReload = false
  var unsavedRequest = ""
  var unsaved = false
  var forgetting = ""
  var toastReload = ""  // webview a toast's Reload button reloads
  var uboInstalled = false
  var uboOffered = false
  var commandsRegistered = false
  var registerAttempts = 0

  init(env: PluginEnv) {
    self.env = env
    for (k, v) in Self.globals { flags[k] = v }
  }

  func on(_ key: String) -> Bool { flags[key] ?? true }

  // MARK: Lifecycle

  func start() {
    loadState()
    registerSettings()
    support = env.call("sitepolicy", "support")
    env.on("sitepolicy.loaded") { [self] v in listLoaded(v) }
    env.on("sitepolicy.changed") { [self] v in if panelOpen, v.s("id") == panelWebview { renderPanel() } }
    env.on("sitepolicy.unsaved") { [self] v in unsavedResult(v) }
    env.on("sitepolicy.httpsUnavailable") { [self] v in httpsUnavailable(v) }
    env.on("sitepolicy.interstitialAction") { [self] v in interstitialAction(v) }
    env.on("sitepolicy.forgotten") { [self] v in forgotten(v) }
    env.on("webviews.url") { [self] v in
      updatePill(v.s("id"), v.s("url"))
      if panelOpen, v.s("id") == panelWebview { urlChanged() }
    }
    env.on("ui.action") { [self] v in action(v.s("id"), v.s("action"), v["value"]) }
    env.on("commands.run") { [self] v in run(v.s("id")) }
    env.on("shields.key.panel") { [self] _ in togglePanel() }
    env.on("shields.key.blocker") { [self] _ in toggleSiteFromKey("blocker") }
    env.on("webext.changed") { [self] v in extensionsChanged(v["extensions"]) }
    env.call("keys", "bind", ["chord": "cmd+opt+s", "event": "shields.key.panel", "title": "Shields for This Site…", "menu": "View"])
    env.call("keys", "bind", ["chord": "cmd+opt+b", "event": "shields.key.blocker", "title": "Block Trackers on This Site", "menu": "View"])
    apply()
    scheduleRefresh()
    extensionsChanged(env.call("webext", "list"))
    registerCommands()
    refreshPills()
  }

  func stop() {
    registerAttempts = Int.max / 2
    if panelOpen { closePanel() }
    env.call("sitepolicy", "guard", ["service": ""])
    env.call("sitepolicy", "https", ["enabled": false])
    env.call("sitepolicy", "rules", ["default": ["lists": []], "hosts": [:]])
    env.call("schedule", "cancel", ["id": "shields.refresh"])
    env.call("keys", "unbind", ["chord": "cmd+opt+s"])
    env.call("keys", "unbind", ["chord": "cmd+opt+b"])
    refreshPills(clear: true)
  }

  /// Pushes everything to the host: lists (loading any newly needed), rules, HTTPS-first, guard.
  func apply() {
    loadLists()
    pushRules()
    env.call("sitepolicy", "https", ["enabled": .bool(on("https")), "allow": .array(httpAllowed.map { .string($0) })])
    env.call("sitepolicy", "guard", ["service": "shields", "method": "navigate"])
  }

  // MARK: State

  func load(_ key: String) -> Value { env.call("storage", "get", ["ns": .string(Self.ns), "key": .string(key)]) }
  func save(_ key: String, _ v: Value) { env.call("storage", "set", ["ns": .string(Self.ns), "key": .string(key), "value": v]) }

  func loadState() {
    if case let .object(pairs) = load("sites") {
      for (h, v) in pairs {
        let s = Site(blocker: v["blocker"].bool, cookies: v["cookies"].bool, autoplay: v["autoplay"].string, popups: v["popups"].string)
        if !s.isEmpty { sites[h] = s }
      }
    }
    httpAllowed = load("httpAllowed").array?.compactMap { $0.string } ?? []
    lookalikeAllowed = load("lookalikeAllowed").array?.compactMap { $0.string } ?? []
    uboOffered = load("uboOffered").bool ?? false
    // Downloaded lists, unless this den bundles newer ones.
    listsVersion = load("listsVersion").string ?? ""
    if !Self.newer(listsVersion, ShieldsLists.version) { listsVersion = "" }
  }

  func saveSites() {
    var o: Value = .object([])
    for h in sites.keys.sorted() {
      guard let s = sites[h] else { continue }
      var v: Value = .object([])
      if let b = s.blocker { v.put("blocker", .bool(b)) }
      if let b = s.cookies { v.put("cookies", .bool(b)) }
      if let a = s.autoplay { v.put("autoplay", .string(a)) }
      if let p = s.popups { v.put("popups", .string(p)) }
      o.put(h, v)
    }
    save("sites", o)
  }

  /// The site key for a host: the host without `www.` (sitepolicy also tries parent domains).
  func site(_ host: String) -> Site { sites[host] ?? Site() }
  func blocker(_ host: String) -> Bool { site(host).blocker ?? on("blocker") }
  func cookies(_ host: String) -> Bool { site(host).cookies ?? on("cookies") }

  func setSite(_ host: String, _ change: (inout Site) -> Void) {
    guard !host.isEmpty else { return }
    var s = site(host)
    change(&s)
    // A value equal to the global choice isn't an exception.
    if s.blocker == on("blocker") { s.blocker = nil }
    if s.cookies == on("cookies") { s.cookies = nil }
    if s.autoplay == autoplay { s.autoplay = nil }
    if s.popups == "block" { s.popups = nil }
    if s.isEmpty { sites[host] = nil } else { sites[host] = s }
    saveSites()
    apply()
    registerSettings()
    refreshPills()
  }

  // MARK: Lists and rules

  func listNames(blocker: Bool, cookies: Bool) -> [String] {
    var l: [String] = []
    if blocker { l += [ShieldsLists.ads.name, ShieldsLists.trackers.name] }
    if cookies { l.append(ShieldsLists.cookies.name) }
    return l
  }

  /// Asks `sitepolicy` for each list some rule uses (a lookup after the first compile).
  func loadLists() {
    var needed = listNames(blocker: on("blocker"), cookies: on("cookies"))
    for (h, _) in sites { for n in listNames(blocker: blocker(h), cookies: cookies(h)) where !needed.contains(n) { needed.append(n) } }
    if needed.contains(ShieldsLists.ads.name) { loadScriptlets() }
    for l in ShieldsLists.all where needed.contains(l.name) && !requested.contains(l.name) {
      requested.append(l.name)
      loadList(l)
    }
  }

  func loadList(_ l: ShieldsLists.List) {
    let r = env.call("sitepolicy", "load", ["name": .string(l.name), "plugin": "shields", "file": .string(listFile(l)), "version": .string(listVersion())])
    if r.isErr {
      env.log("shields: " + r.s("error"))
      if !listsVersion.isEmpty { fallBackToBundledLists() }
    }
  }

  // MARK: Daily lists (built by .github/workflows/shields-lists.yml)

  /// The downloaded lists in use ("" = the ones in den's bundle). Storage `listsVersion`.
  var listsVersion = ""
  /// A download in progress: its version and the files still missing.
  var pendingVersion = ""
  var pendingFiles: [String] = []
  var listsBase = ShieldsLists.listsBase

  /// "2026.10.04-7f6dd3ec" after "2026.09.27-989747b8": byte order (the date comes first).
  static func newer(_ a: String, _ b: String) -> Bool { Array(b.utf8).lexicographicallyPrecedes(Array(a.utf8)) }

  func listVersion() -> String { listsVersion.isEmpty ? ShieldsLists.version : listsVersion }
  static func short(_ l: ShieldsLists.List) -> String { Text.dropPrefix(l.name, "shields.") }
  /// `<list>-<version>.json.lzfse` in den's update root, or the bundled file.
  func listFile(_ l: ShieldsLists.List) -> String { listsVersion.isEmpty ? l.file : Self.short(l) + "-" + listsVersion + ".json.lzfse" }

  /// lists.json arrived: when it names lists newer than the ones in use, fetch them (checked
  /// against their SHA-256); once all three are in, `sitepolicy` compiles them off the main thread
  /// and swaps them into every page, with no relaunch.
  func listsManifest(_ m: Value) {
    let v = m.s("version")
    guard !v.isEmpty, Self.newer(v, listVersion()), v != pendingVersion else { return }
    var files: [(String, String, String)] = []
    for l in ShieldsLists.all {
      let e = m["lists"][Self.short(l)]
      let file = e.s("file"), sha = e.s("sha256")
      guard file == Self.short(l) + "-" + v + ".json.lzfse", sha.utf8.count == 64 else { return env.log("shields: lists.json " + v + " is incomplete") }
      files.append((file, sha, Self.short(l) + "-"))
    }
    pendingVersion = v
    pendingFiles = files.map { $0.0 }
    for (file, sha, prefix) in files {
      env.call("sitepolicy", "fetch", ["plugin": "shields", "file": .string(file), "url": .string(listsBase + file),
                                       "sha256": .string(sha), "prune": .string(prefix)])
    }
  }

  func listFileFetched(_ v: Value) {
    let file = v.s("file")
    guard !pendingVersion.isEmpty, pendingFiles.contains(file) else { return }
    guard v.b("ok") else {
      env.log("shields: list download failed (" + file + "): " + v.s("error"))
      pendingVersion = ""
      pendingFiles = []
      return
    }
    pendingFiles.removeAll { $0 == file }
    guard pendingFiles.isEmpty else { return }
    listsVersion = pendingVersion
    pendingVersion = ""
    save("listsVersion", .string(listsVersion))
    env.log("shields: lists " + listsVersion + " downloaded, compiling")
    for l in ShieldsLists.all where requested.contains(l.name) { loadList(l) }
    registerSettings()
  }

  /// A downloaded list that won't load: back to the bundled ones.
  func fallBackToBundledLists() {
    env.log("shields: downloaded lists " + listsVersion + " failed; using the bundled lists")
    listsVersion = ""
    save("listsVersion", "")
    for l in ShieldsLists.all where requested.contains(l.name) { loadList(l) }
  }

  /// The scriptlets (engine + data) for sites content rules can't clean (YouTube). Asked once
  /// whenever some rule blocks, and again when newer data arrives.
  func loadScriptlets(force: Bool = false) {
    guard force || !scriptletsRequested else { return }
    scriptletsRequested = true
    let r = env.call("sitepolicy", "script", ["name": .string(ShieldsLists.scriptlets), "plugin": "shields",
                                              "file": .string(ShieldsLists.scriptletsCode), "data": .string(ShieldsLists.scriptletsData)])
    // The other sites' scriptlets: the same engine, data split per site by the host.
    let s = env.call("sitepolicy", "script", ["name": .string(ShieldsLists.sites), "plugin": "shields", "perSite": true,
                                              "file": .string(ShieldsLists.scriptletsCode), "data": .string(ShieldsLists.sitesData)])
    if r.isErr || s.isErr {
      scriptletsRequested = false
      env.log("shields: " + r.s("error") + s.s("error"))
    }
  }

  static let day: Int64 = 24 * 3600 * 1000

  /// Daily refresh of the scriptlet data (YouTube changes often): a minute after launch when the
  /// last check is a day old, then every day. Only data; the engine ships with den.
  func scheduleRefresh() {
    env.on("schedule.fire") { [self] v in if v.s("id") == "shields.refresh" { refreshScriptlets() } }
    env.on("sitepolicy.fetched") { [self] v in fetched(v) }
    env.call("schedule", "interval", ["id": "shields.refresh", "ms": .int(Self.day), "wake": true])
    env.timer(60_000, false) { [self] in refreshScriptlets() }
  }

  func refreshScriptlets() {
    guard on("blocker") || sites.values.contains(where: { $0.blocker == true }) else { return }
    let last = load("scriptletsChecked").int ?? 0
    guard env.now() - last >= Self.day - 3600 * 1000 else { return }
    for (file, url) in ShieldsLists.refreshed {
      env.call("sitepolicy", "fetch", ["plugin": "shields", "file": .string(file), "url": .string(url)])
    }
    env.call("sitepolicy", "fetch", ["plugin": "shields", "file": .string(ShieldsLists.listsManifest), "url": .string(listsBase + ShieldsLists.listsManifest)])
  }

  func fetched(_ v: Value) {
    guard v.s("plugin") == "shields" else { return }
    if v.s("file") == ShieldsLists.listsManifest {
      if v.b("ok") { listsManifest(v["value"]) } else { env.log("shields: lists.json: " + v.s("error")) }
      return
    }
    if Text.hasSuffix(v.s("file"), ".json.lzfse") { return listFileFetched(v) }
    guard ShieldsLists.refreshed.contains(where: { $0.0 == v.s("file") }) else { return }
    if v.b("ok") { save("scriptletsChecked", .int(env.now())) } else { env.log("shields: scriptlet data refresh failed: " + v.s("error")) }
    if v.b("changed"), scriptletsRequested { loadScriptlets(force: true) }
  }

  func listLoaded(_ v: Value) {
    let n = v.s("name")
    if n == ShieldsLists.sites {
      if !v.b("ok") { env.log("shields: site scriptlets failed: " + v.s("error")) }
      return
    }
    if n == ShieldsLists.scriptlets {
      scriptletsReady = v.b("ok")
      if v.b("ok") { scriptletsVersion = v.s("version") } else { scriptletsRequested = false; env.log("shields: scriptlets failed: " + v.s("error")) }
      return
    }
    guard requested.contains(n) else { return }
    if v.b("ok") {
      if !ready.contains(n) { ready.append(n) }
      if !v.s("replaced").isEmpty { env.log("shields: " + n + " swapped to " + listVersion() + " (" + String(v.i("ms")) + " ms)") }
    } else if !listsVersion.isEmpty {
      env.log("shields: list " + n + " failed: " + v.s("error"))
      fallBackToBundledLists()
    } else {
      requested.removeAll { $0 == n }
      env.log("shields: list " + n + " failed: " + v.s("error"))
    }
  }

  /// The page scripts a site gets: the scriptlets wherever the blocker is on (they run only on
  /// the sites their data lists).
  func scriptNames(blocker: Bool) -> Value { blocker ? [.string(ShieldsLists.scriptlets), .string(ShieldsLists.sites)] : [] }

  func rules() -> Value {
    var hosts: Value = .object([])
    for h in sites.keys.sorted() {
      guard let s = sites[h] else { continue }
      var r: Value = ["lists": .array(listNames(blocker: blocker(h), cookies: cookies(h)).map { .string($0) }), "autoplay": .string(s.autoplay ?? autoplay)]
      r.put("scripts", scriptNames(blocker: blocker(h)))
      r.put("popups", .string(s.popups ?? "block"))
      hosts.put(h, r)
    }
    return ["default": ["lists": .array(listNames(blocker: on("blocker"), cookies: on("cookies")).map { .string($0) }),
                        "scripts": scriptNames(blocker: on("blocker")), "autoplay": .string(autoplay), "popups": "block"],
            "hosts": hosts]
  }

  func pushRules() { env.call("sitepolicy", "rules", rules()) }

  // MARK: Navigation guard (called synchronously by sitepolicy for main-frame navigations)

  func navigate(_ a: Value) -> Value {
    let url = a.s("url")
    let host = URLs.host(url)
    if on("lookalike"), IDN.hasPunycode(host) || Text.contains(host, "0") || Text.contains(host, "1") || Text.contains(host, "rn") || Text.contains(host, "vv"),
       !lookalikeAllowed.contains(host), let target = Lookalike.target(host) {
      return ["action": "interstitial", "page": lookalikePage(host, target, url)]
    }
    if on("bounce"), let dest = CleanLinks.unwrap(url), blocker(URLs.host(dest)) {
      let clean = on("params") ? CleanLinks.strip(dest).url : dest
      return ["action": "rewrite", "url": .string(clean), "kind": "bounce"]
    }
    if on("params"), blocker(host) {
      let r = CleanLinks.strip(url)
      if !r.removed.isEmpty { return ["action": "rewrite", "url": .string(r.url), "kind": "params"] }
    }
    return .null
  }

  /// A link as den copies it (the page menu's Copy Link): the address `navigate` would rewrite it
  /// to (bounce skipped, tracking parameters removed, same settings), never an error.
  func clean(_ url: String) -> Value {
    var u = url
    var removed: [Value] = []
    if on("bounce"), let dest = CleanLinks.unwrap(u), blocker(URLs.host(dest)) {
      u = dest
      removed.append("bounce")
    }
    if on("params"), blocker(URLs.host(u)) {
      let r = CleanLinks.strip(u)
      u = r.url
      for k in r.removed { removed.append(.string(k)) }
    }
    return ["url": .string(u), "removed": .array(removed)]
  }

  /// "аpple.com" as it would render (for the warning; the pill keeps Punycode).
  static func unicode(_ host: String) -> String {
    guard let ls = IDN.unicodeLabels(host) else { return host }
    return IDN.string(Lookalike.join(ls))
  }

  func lookalikePage(_ host: String, _ target: String, _ url: String) -> Value {
    let shown = Self.unicode(host)
    let name = shown == host ? host : "“" + shown + "” (" + host + ")"
    return ["kind": "lookalike", "icon": "shield", "title": .string("Did you mean " + target + "?"),
            "message": .string(name + " looks like " + target + ", but it’s a different site. Lookalike sites often try to steal passwords or payment details."),
            "url": .string(url),
            "buttons": [["id": "lookalike.go", "title": .string("Go to " + target), "style": "primary", "key": "return"],
                        ["id": "lookalike.continue", "title": .string("Continue to " + host), "style": "secondary"]]]
  }

  func httpsPage(_ host: String, _ url: String) -> Value {
    ["kind": "https", "icon": "lock", "title": .string(host + " doesn’t offer a secure connection"),
     "message": "den tried HTTPS first, but the site didn’t answer over it. On the insecure version, anyone on your network can see and change what you send and receive.",
     "url": .string(url),
     "buttons": [["id": "https.back", "title": "Go Back", "style": "primary", "key": "return"],
                 ["id": "https.continue", "title": "Continue to Insecure Site", "style": "secondary"]]]
  }

  func httpsUnavailable(_ v: Value) {
    let url = v.s("url")
    env.call("sitepolicy", "interstitial", ["id": v["id"], "url": .string(url), "page": httpsPage(URLs.host(url), url)])
  }

  func interstitialAction(_ v: Value) {
    let id = v.s("id"), url = v.s("url"), host = URLs.host(url)
    switch v.s("action") {
    case "lookalike.go":
      if let t = Lookalike.target(host) { env.call("webviews", "navigate", ["id": .string(id), "url": .string("https://" + t)]) }
    case "lookalike.continue":
      if !lookalikeAllowed.contains(host) { lookalikeAllowed.append(host) }
      save("lookalikeAllowed", .array(lookalikeAllowed.map { .string($0) }))
      env.call("webviews", "navigate", ["id": .string(id), "url": .string(url)])
      refreshPills()
    case "https.continue":
      if !httpAllowed.contains(host) { httpAllowed.append(host) }
      save("httpAllowed", .array(httpAllowed.map { .string($0) }))
      apply()
      registerSettings()
      env.call("webviews", "navigate", ["id": .string(id), "url": .string(url)])
    case "https.back":
      if env.call("webviews", "get", ["id": .string(id)]).b("canGoBack") { env.call("webviews", "back", ["id": .string(id)]) } else {
        env.call("webviews", "navigate", ["id": .string(id), "url": "about:blank"])
      }
    default: break
    }
  }

  // MARK: Service

  func handle(_ method: String, _ a: Value) -> Value {
    switch method {
    case "navigate": return navigate(a)
    case "clean": return clean(a.s("url"))
    case "pill": return pill(a.s("url"))
    case "open":
      openPanel(a.sOpt("id"))
      return .okay
    case "close":
      if panelOpen { closePanel() }
      return .okay
    case "site":
      let h = URLs.host(a.s("host"))
      guard !h.isEmpty else { return .err("shields: site needs host") }
      setSite(h) { s in
        if let b = a["blocker"].bool { s.blocker = b }
        if let b = a["cookies"].bool { s.cookies = b }
        if let x = a["autoplay"].string { s.autoplay = x }
        if let x = a["popups"].string { s.popups = x }
      }
      return .okay
    case "get":
      let h = URLs.host(a.s("host"))
      var v: Value = ["blocker": .bool(blocker(h)), "cookies": .bool(cookies(h)), "autoplay": .string(site(h).autoplay ?? autoplay),
                      "popups": .string(site(h).popups ?? "block"), "httpAllowed": .bool(httpAllowed.contains(h)),
                      "lists": .array(ready.map { .string($0) }), "ubo": .bool(uboInstalled),
                      "scriptlets": .bool(scriptletsReady), "scriptletsVersion": .string(scriptletsVersion)]
      for (k, _) in Self.globals { v.put("global." + k, .bool(on(k))) }
      return v
    case "state":
      return ["panelOpen": .bool(panelOpen), "webview": .string(panelWebview), "pendingReload": .bool(pendingReload), "unsaved": .bool(unsaved),
              "forgetting": .string(forgetting)]
    default:
      return .err("shields: unknown method " + method)
    }
  }

  /// The shield in the URL pill of each web view (through `tabs.pillButtons`), on web pages only.
  func updatePill(_ id: String, _ url: String, clear: Bool = false) {
    guard !id.isEmpty else { return }
    let p = clear ? Value.null : pill(url)
    var buttons: [Value] = []
    if let icon = p["icon"].string { buttons.append(["id": "shields.pill", "icon": .string(icon), "active": .bool(p.s("tone") == "warning")]) }
    env.call("tabs", "pillButtons", ["webview": .string(id), "owner": "shields", "buttons": .array(buttons)])
  }

  func refreshPills(clear: Bool = false) {
    for id in env.call("webviews", "list").array ?? [] {
      guard let i = id.string else { continue }
      updatePill(i, env.call("webviews", "get", ["id": id]).s("url"), clear: clear)
    }
  }

  /// The URL pill's shield: `{id, icon, tone?}`, or null on non-web pages.
  func pill(_ url: String) -> Value {
    guard Text.hasPrefix(url, "http://") || Text.hasPrefix(url, "https://") else { return .null }
    let h = URLs.host(url)
    if lookalikeAllowed.contains(h) { return ["id": "shields", "icon": "sf:exclamationmark.shield.fill", "tone": "warning", "always": true] }
    if !blocker(h) { return ["id": "shields", "icon": "sf:shield.slash", "tone": "muted", "always": true] }
    return ["id": "shields", "icon": "sf:shield.lefthalf.filled"]
  }

  // MARK: Panel

  func currentWebview() -> String? {
    let id = env.call("content", "get")["focus"].string ?? env.call("tabs", "selected")["id"].string
    guard let id, !id.isEmpty else { return nil }
    return id
  }

  func togglePanel() { if panelOpen { closePanel() } else { openPanel(nil) } }

  func openPanel(_ id: String?) {
    guard let w = id ?? currentWebview() else { return }
    let url = env.call("webviews", "get", ["id": .string(w)]).s("url")
    guard Text.hasPrefix(url, "http://") || Text.hasPrefix(url, "https://") else {
      toast("Shields work on websites", icon: "sf:shield.lefthalf.filled")
      return
    }
    panelOpen = true
    panelWebview = w
    panelHost = URLs.host(url)
    pendingReload = false
    unsaved = false
    renderPanel()
  }

  func closePanel() {
    panelOpen = false
    env.call("ui", "set", ["slot": "popover", "tree": .null])
  }

  func urlChanged() {
    let url = env.call("webviews", "get", ["id": .string(panelWebview)]).s("url")
    let h = URLs.host(url)
    guard Text.hasPrefix(url, "http") else { return closePanel() }
    if h != panelHost {
      panelHost = h
      pendingReload = false
    }
    renderPanel()
  }

  static func percent(_ zoom: Double) -> String { String(Int((zoom * 100) + 0.5)) + "%" }

  func renderPanel() {
    guard panelOpen else { return }
    env.call("ui", "set", ["slot": "popover", "tree": panelTree()])
  }

  func panelTree() -> Value {
    let h = panelHost
    let st = env.call("sitepolicy", "get", ["id": .string(panelWebview)])
    let web = env.call("webviews", "get", ["id": .string(panelWebview)])
    let blockOn = blocker(h), cookieOn = cookies(h)
    let blockedCount = st.i("blocked")
    let counts = st.b("blockedCounts")
    let flagged = lookalikeAllowed.contains(h)

    var subtitle = blockOn ? "Shields are on" : "Shields are off for this site"
    if blockOn && counts && blockedCount > 0 { subtitle += " · " + String(blockedCount) + " blocked" }
    if flagged, let t = Lookalike.target(h) { subtitle = "Looks like " + t + ": not that site" }

    var siteRows: [Value] = [
      ["type": "toggleRow", "id": "shields.blocker", "title": "Block trackers and ads", "on": .bool(blockOn), "shortcut": "⌥⌘B"],
      ["type": "toggleRow", "id": "shields.cookies", "title": "Hide cookie banners", "on": .bool(cookieOn)],
    ]
    if support.b("autoplay") {
      siteRows.append(["type": "choiceRow", "id": "shields.autoplay", "title": "Autoplay", "selected": .string(site(h).autoplay ?? autoplay),
                       "options": .array(Self.autoplayOptions.map { ["id": .string($0.0), "title": .string($0.1)] })])
    }
    if support.b("popups") {
      siteRows.append(["type": "choiceRow", "id": "shields.popups", "title": "Pop-ups", "selected": .string(site(h).popups ?? "block"),
                       "options": .array(Self.popupOptions.map { ["id": .string($0.0), "title": .string($0.1)] })])
    }
    let zoom = web["zoom"].double ?? 1
    let zoomed = zoom < 0.999 || zoom > 1.001
    var zoomButtons: [Value] = [["id": "out", "icon": "sf:minus"], ["id": "in", "icon": "sf:plus"]]
    if zoomed { zoomButtons.append(["id": "reset", "icon": "sf:arrow.counterclockwise"]) }
    siteRows.append(["type": "valueRow", "id": "shields.zoom", "title": "Zoom", "value": .string(Self.percent(zoom)),
                     "shortcut": .string(zoomed ? "⌘− ⌘+ ⌘0" : "⌘− ⌘+"), "buttons": .array(zoomButtons)])

    var children: [Value] = [["type": "section", "id": "shields.site", "title": "This site", "children": .array(siteRows)]]

    if pendingReload {
      let text = unsaved ? "Reload to apply. This page has input you haven’t sent; reloading clears it." : "Reload the page to apply the change."
      children.append(["type": "paragraph", "id": "shields.reloadNote", "text": .string(text), "style": "secondary",
                       "icon": .string(unsaved ? "sf:exclamationmark.triangle" : "sf:arrow.clockwise")])
      children.append(["type": "buttonRow", "id": "shields.reloadRow", "children": [
        ["type": "actionButton", "id": "shields.reload", "title": .string(unsaved ? "Reload Anyway" : "Reload"),
         "style": .string(unsaved ? "secondary" : "primary"), "keycap": "⌘R"],
      ]])
    }

    var privacy: [Value] = []
    if counts {
      privacy.append(["type": "valueRow", "id": "shields.blocked", "title": "Trackers and ads blocked",
                      "value": .string(blockOn ? String(blockedCount) : "Off")])
    }
    var params = 0
    var bounce = ""
    for r in st.a("rewrites") {
      if r.s("kind") == "bounce" { bounce = URLs.host(r.s("from")) }
      params += CleanLinks.strip(r.s("from")).removed.count
    }
    if !bounce.isEmpty { privacy.append(["type": "valueRow", "id": "shields.bounce", "title": "Bounce redirect skipped", "value": .string(bounce)]) }
    if params > 0 { privacy.append(["type": "valueRow", "id": "shields.params", "title": "Tracking parameters removed", "value": .string(String(params))]) }
    let conn: (String, String)
    switch st.s("connection") {
    case "secure": conn = (st.b("upgraded") ? "Upgraded to HTTPS" : "Secure", "success")
    case "mixed": conn = ("Partly secure", "warning")
    case "insecure": conn = (httpAllowed.contains(h) ? "Not secure (allowed)" : "Not secure", "warning")
    default: conn = ("Local", "secondary")
    }
    privacy.append(["type": "valueRow", "id": "shields.connection", "title": "Connection", "value": .string(conn.0), "tone": .string(conn.1)])
    let perms = env.call("sitepolicy", "permissions", ["host": .string(h)]).array ?? []
    var permText = "Asks first"
    if !perms.isEmpty {
      let allowed = perms.filter { $0.b("allowed") }.count
      permText = allowed == perms.count ? "Allowed" : (allowed == 0 ? "Blocked" : Self.describePermissions(perms))
    }
    var permRow: Value = ["type": "valueRow", "id": "shields.permissions", "title": "Permissions", "value": .string(permText)]
    if !perms.isEmpty { permRow.put("buttons", [["id": "reset", "icon": "sf:arrow.counterclockwise"]]) }
    privacy.append(permRow)
    // One row per remembered answer: Allow / Block it, or Ask First (forgets it, the site asks
    // again). A change is instant; the next request from the page follows it.
    panelPerms = []
    for p in perms {
      let origin = p.s("origin"), kind = p.s("kind")
      guard !origin.isEmpty, kind == "camera" || kind == "microphone" else { continue }
      privacy.append(["type": "choiceRow", "id": .string("shields.permission.\(panelPerms.count)"),
                      "title": .string((kind == "microphone" ? "Microphone" : "Camera") + " · " + origin),
                      "selected": .string(p.b("allowed") ? "allow" : "block"),
                      "options": .array(Self.permissionOptions.map { ["id": .string($0.0), "title": .string($0.1)] })])
      panelPerms.append((origin, kind))
    }
    children.append(["type": "section", "id": "shields.privacy", "title": "On this page", "children": .array(privacy)])

    if uboInstalled && on("blocker") {
      children.append(["type": "paragraph", "id": "shields.uboNote", "style": "secondary", "icon": "sf:puzzlepiece.extension",
                       "text": "uBlock Origin Lite is blocking too. One blocker is enough; den’s can step aside."])
      children.append(["type": "buttonRow", "id": "shields.uboRow", "children": [["type": "actionButton", "id": "shields.ubo", "title": "Use Only uBlock Origin Lite", "style": "secondary"]]])
    }
    children.append(["type": "buttonRow", "id": "shields.footer", "children": [
      ["type": "actionButton", "id": "shields.forget", "title": "Forget This Site…", "style": "destructive"],
      ["type": "actionButton", "id": "shields.settings", "title": "Settings", "style": "secondary"],
    ]])

    return ["type": "panel", "id": .string(Self.panelId), "anchor": .string(Self.pillId), "width": 340,
            "icon": .string(flagged ? "sf:exclamationmark.shield.fill" : (blockOn ? "sf:shield.lefthalf.filled" : "sf:shield.slash")),
            "tone": .string(flagged ? "warning" : (blockOn ? "accent" : "secondary")),
            "title": .string(IDN.display(h)), "subtitle": .string(subtitle), "children": .array(children)]
  }

  func action(_ id: String, _ action: String, _ value: Value) {
    if id == "shields.pill", action == "click" {
      if panelOpen { closePanel() } else { openPanel(value.sOpt("webview")) }
      return
    }
    if id == "shields.forgetDialog" { return forgetAnswer(value.s("button")) }
    if id == "shields.ubo", action == "toast" { return useUBO() }
    if id == "shields.reloadToast", action == "toast" {
      if !toastReload.isEmpty { env.call("webviews", "reload", ["id": .string(toastReload)]) }
      return
    }
    guard panelOpen, Text.hasPrefix(id, "shields.") else { return }
    let h = panelHost
    switch id {
    case Self.panelId: if action == "dismiss" { closePanel() }
    case "shields.blocker": if action == "toggle" { changed { setSite(h) { $0.blocker = value.b("on") } } }
    case "shields.cookies": if action == "toggle" { changed { setSite(h) { $0.cookies = value.b("on") } } }
    case "shields.autoplay": if action == "select" { changed { setSite(h) { $0.autoplay = value.s("option") } } }
    case "shields.popups": if action == "select" { changed { setSite(h) { $0.popups = value.s("option") } } }
    case "shields.zoom":
      if action == "click" { env.call("webviews", "zoom", ["id": .string(panelWebview), "action": .string(value.s("button"))]) }
      renderPanel()
    case "shields.permissions":
      if action == "click" { env.call("sitepolicy", "resetPermissions", ["host": .string(h)]) }
      renderPanel()
    case "shields.reload":
      env.call("webviews", "reload", ["id": .string(panelWebview)])
      pendingReload = false
      unsaved = false
      renderPanel()
    case "shields.forget": confirmForget(h)
    case "shields.settings":
      closePanel()
      env.call("settings", "open", ["section": .string(Self.ns)])
    case "shields.ubo": useUBO()
    default:
      if Text.hasPrefix(id, "shields.permission."), action == "select" {
        guard let n = Int(id.dropFirst("shields.permission.".count)), n >= 0, n < panelPerms.count else { return }
        var args: Value = ["host": .string(h), "origin": .string(panelPerms[n].origin), "kind": .string(panelPerms[n].kind)]
        if value.s("option") != "ask" { args.put("allowed", .bool(value.s("option") == "allow")) }
        env.call("sitepolicy", "setPermission", args)
        renderPanel()
      }
    }
  }

  /// A change that needs a reload: note it, then ask the page whether it has unsaved input.
  func changed(_ f: () -> Void) {
    f()
    pendingReload = true
    unsaved = false
    unsavedRequest = env.call("sitepolicy", "unsaved", ["id": .string(panelWebview)]).s("request")
    renderPanel()
  }

  func unsavedResult(_ v: Value) {
    guard v.s("request") == unsavedRequest else { return }
    unsavedRequest = ""
    unsaved = v.b("unsaved")
    if panelOpen { renderPanel() }
    if !toastReload.isEmpty, v.s("id") == toastReload { reloadToast(v.s("id"), unsaved: unsaved) }
  }

  // MARK: Forget this site

  func confirmForget(_ host: String) {
    closePanel()
    forgetting = host
    env.call("ui", "set", ["slot": "dialog", "tree": [
      "type": "dialog", "id": "shields.forgetDialog", "icon": "sf:trash", "iconStyle": "destructive",
      "title": .string("Forget " + IDN.display(host) + "?"),
      "message": "den removes its cookies, site data and cache, and your Shields, zoom and permission choices for it. You’ll be signed out.",
      "buttons": [["id": "cancel", "title": "Cancel", "style": "cancel"], ["id": "forget", "title": "Forget", "style": "destructive", "default": true]],
    ]])
  }

  func forgetAnswer(_ button: String) {
    env.call("ui", "set", ["slot": "dialog", "tree": .null])
    let h = forgetting
    forgetting = ""
    guard button == "forget", !h.isEmpty else { return }
    sites[h] = nil
    saveSites()
    httpAllowed.removeAll { $0 == h }
    save("httpAllowed", .array(httpAllowed.map { .string($0) }))
    lookalikeAllowed.removeAll { $0 == h }
    save("lookalikeAllowed", .array(lookalikeAllowed.map { .string($0) }))
    env.call("storage", "delete", ["ns": "_zoom", "key": .string(h)])
    env.call("sitepolicy", "forget", ["host": .string(h)])
    apply()
    registerSettings()
    refreshPills()
  }

  func forgotten(_ v: Value) {
    let h = v.s("host")
    toast("Forgot " + IDN.display(h) + ": cookies and site data removed", icon: "sf:trash")
    // Reload pages of that site so they start clean (and show signed out).
    for id in env.call("webviews", "list").array ?? [] {
      let st = env.call("webviews", "get", ["id": id])
      let host = URLs.host(st.s("url"))
      guard st.b("live"), host == h || Text.hasSuffix(host, "." + h) else { continue }
      env.call("webviews", "zoom", ["id": id, "action": "reset"])
      env.call("webviews", "reload", ["id": id])
    }
  }

  // MARK: Keys, commands, toasts

  func toast(_ text: String, icon: String, id: String = "", action: String = "", duration: Int64 = 3000) {
    var t: Value = ["type": "toast", "text": .string(text), "icon": .string(icon), "duration": .int(duration)]
    if !id.isEmpty { t.put("id", .string(id)) }
    if !action.isEmpty { t.put("action", .string(action)) }
    env.call("ui", "set", ["slot": "toast", "tree": t])
  }

  /// ⌥⌘B (and the command): flips this site's blocker, then offers a reload in a toast.
  func toggleSiteFromKey(_ key: String) {
    guard let w = currentWebview() else { return }
    let url = env.call("webviews", "get", ["id": .string(w)]).s("url")
    let h = URLs.host(url)
    guard Text.hasPrefix(url, "http") else { return }
    if key == "blocker" { setSite(h) { $0.blocker = !blocker(h) } } else { setSite(h) { $0.cookies = !cookies(h) } }
    if panelOpen { renderPanel() }
    toastReload = w
    unsavedRequest = env.call("sitepolicy", "unsaved", ["id": .string(w)]).s("request")
  }

  func reloadToast(_ id: String, unsaved: Bool) {
    let h = URLs.host(env.call("webviews", "get", ["id": .string(id)]).s("url"))
    let on = blocker(h)
    var text = (on ? "Blocking trackers on " : "Not blocking on ") + IDN.display(h)
    if unsaved { text += ". The page has unsaved input" }
    toast(text, icon: on ? "sf:shield.lefthalf.filled" : "sf:shield.slash", id: "shields.reloadToast", action: unsaved ? "Reload Anyway" : "Reload", duration: 6000)
  }

  static let commands: [(String, String, String, String)] = [
    ("shields.panel", "Shields for This Site", "sf:shield.lefthalf.filled", "⌥⌘S"),
    ("shields.blocker", "Block Trackers and Ads on This Site: On/Off", "sf:shield.slash", "⌥⌘B"),
    ("shields.cookies", "Hide Cookie Banners on This Site: On/Off", "sf:checkmark.shield", ""),
    ("shields.forget", "Forget This Site…", "sf:trash", ""),
    ("shields.settings", "Shields Settings", "sf:gearshape", ""),
  ]

  func run(_ id: String) {
    switch id {
    case "shields.panel": openPanel(nil)
    case "shields.blocker": toggleSiteFromKey("blocker")
    case "shields.cookies": toggleSiteFromKey("cookies")
    case "shields.forget":
      if let w = currentWebview() {
        let h = URLs.host(env.call("webviews", "get", ["id": .string(w)]).s("url"))
        if !h.isEmpty { confirmForget(h) }
      }
    case "shields.settings": env.call("settings", "open", ["section": .string(Self.ns)])
    default: break
    }
  }

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
    for (id, title, icon, shortcut) in Self.commands {
      let r = env.call("commands", "register", [
        "id": .string(id), "title": .string(title), "icon": .string(icon), "shortcut": .string(shortcut), "owner": "shields",
        "keywords": ["shields", "block", "blocker", "ads", "adblock", "trackers", "privacy", "cookies", "cookie banner", "site settings", "forget"],
      ])
      if r.isErr { return false }
    }
    commandsRegistered = true
    return true
  }

  // MARK: Extensions (uBlock Origin Lite)

  func extensionsChanged(_ list: Value) {
    var found = false
    for e in list.array ?? [] where e.b("enabled") && Text.contains(e.s("name"), "uBlock Origin") { found = true }
    guard found != uboInstalled else { return }
    uboInstalled = found
    if found && on("blocker") && !uboOffered {
      uboOffered = true
      save("uboOffered", true)
      toast("uBlock Origin Lite is installed. Turn off den’s blocker so pages aren’t filtered twice?", icon: "sf:shield.lefthalf.filled",
            id: "shields.ubo", action: "Turn Off", duration: 12000)
    }
    if panelOpen { renderPanel() }
    registerSettings()
  }

  func useUBO() {
    setGlobal("blocker", false)
    env.call("settings", "set", ["id": .string(Self.ns), "key": "blocker", "value": false])
    toast("den’s blocker is off; uBlock Origin Lite does the blocking", icon: "sf:puzzlepiece.extension")
    if panelOpen { renderPanel() }
  }

  // MARK: Settings

  func setGlobal(_ key: String, _ v: Value) {
    if key == "autoplay" {
      guard let s = v.string, s != autoplay else { return }
      autoplay = s
    } else {
      guard let b = v.bool, flags[key] != nil, flags[key] != b else { return }
      flags[key] = b
    }
    apply()
    refreshPills()
    if panelOpen { renderPanel() }
  }

  static func describe(_ s: Site) -> String {
    var parts: [String] = []
    if let b = s.blocker { parts.append(b ? "Blocker on" : "Blocker off") }
    if let b = s.cookies { parts.append(b ? "Cookie banners hidden" : "Cookie banners shown") }
    if let a = s.autoplay { parts.append("Autoplay: " + (autoplayOptions.first { $0.0 == a }?.1 ?? a)) }
    if s.popups == "allow" { parts.append("Pop-ups allowed") }
    var out = ""
    for (i, p) in parts.enumerated() { out += (i > 0 ? " · " : "") + p }
    return out
  }

  func registerSettings() {
    var siteItems: [Value] = []
    for h in sites.keys.sorted() {
      guard let s = sites[h] else { continue }
      siteItems.append(["id": .string(h), "title": .string(IDN.display(h)), "subtitle": .string(Self.describe(s)), "buttons": [["id": "reset", "title": "Reset"]]])
    }
    let httpItems: [Value] = httpAllowed.map { ["id": .string($0), "title": .string(IDN.display($0)), "buttons": [["id": "remove", "title": "Remove"]]] }
    var lists = ""
    for (i, l) in ShieldsLists.all.enumerated() { lists += (i > 0 ? "\n" : "") + l.source + ". " + l.licence }
    lists += "\n" + ShieldsLists.scriptletsSource + (scriptletsVersion.isEmpty ? "" : " (" + scriptletsVersion + ")")
    lists += "\n" + ShieldsLists.sitesSource
    var controls: [Value] = [
      ["key": "blocker", "type": "toggle", "title": "Block trackers and ads", "default": true,
       "subtitle": "EasyList and EasyPrivacy, built into WebKit. Turn it off for one site with the shield in the address pill (⌥⌘S) or ⌥⌘B."],
      ["key": "cookies", "type": "toggle", "title": "Hide cookie banners", "default": true,
       "subtitle": "The EasyList Cookie List hides consent pop-ups and blocks their scripts. The site gets no answer, so nothing is accepted."],
      ["key": "params", "type": "toggle", "title": "Remove tracking parameters", "default": true,
       "subtitle": "utm_…, fbclid, gclid and 30 more click IDs come off every page you open, not only when you copy a link."],
      ["key": "bounce", "type": "toggle", "title": "Skip bounce-tracking redirects", "default": true,
       "subtitle": "Links through ad and affiliate click trackers go straight to where they point."],
      ["key": "https", "type": "toggle", "title": "HTTPS-first", "default": true,
       "subtitle": "Every http:// page is tried over HTTPS first; den asks before opening an insecure one."],
      ["key": "lookalike", "type": "toggle", "title": "Warn about lookalike sites", "default": true,
       "subtitle": "Names made to look like a well-known site, such as аpple.com spelled with a Cyrillic “а”."],
      ["key": "autoplay", "type": "choice", "title": "Autoplay", "default": "sound", "subtitle": "Videos may start on their own only when muted.",
       "options": .array(Self.autoplayOptions.map { ["value": .string($0.0), "title": .string($0.1)] })],
      ["key": "sites", "type": "list", "title": "Sites with their own settings", "items": .array(siteItems), "empty": "None yet. Set them from the shield in the address pill."],
      ["key": "permissions", "type": "list", "title": "Site permissions", "items": .array(permissionItems()),
       "empty": "No site has asked yet. Camera, microphone, location and notifications are asked for per site."],
    ]
    if !httpItems.isEmpty { controls.append(["key": "http", "type": "list", "title": "Allowed without HTTPS", "items": .array(httpItems)]) }
    if uboInstalled {
      controls.append(["key": "ubo", "type": "info", "title": "uBlock Origin Lite is installed", "value": "Turning off den’s blocker avoids filtering every page twice."])
    }
    controls.append(["key": "lists", "type": "info", "title": .string("Filter lists (" + listVersion() + ")"), "value": .string(lists)])
    let r = env.call("settings", "register", ["id": .string(Self.ns), "title": "Shields", "icon": "sf:shield.lefthalf.filled", "order": 25, "controls": .array(controls)])
    guard !r.isErr else { return }
    if !settingsListening {
      settingsListening = true
      let v = env.call("settings", "get", ["id": .string(Self.ns)])
      for (k, _) in Self.globals { if let b = v[k].bool { flags[k] = b } }
      if let a = v["autoplay"].string { autoplay = a }
      env.on("settings.changed") { [self] v in if v.s("id") == Self.ns { setGlobal(v.s("key"), v["value"]) } }
      env.on("settings.action") { [self] v in if v.s("id") == Self.ns { settingsAction(v.s("key"), v.s("item")) } }
      // Answers given to a site's prompt (or reset) show in the list at once.
      env.on("sitepolicy.permissionsChanged") { [self] _ in registerSettings() }
      env.on("notifications.changed") { [self] _ in registerSettings() }
    }
  }

  var settingsListening = false

  static let permissionNames: [(String, String)] = [("camera", "Camera"), ("microphone", "Microphone"), ("location", "Location"), ("notifications", "Notifications")]

  /// "Camera, Location allowed · Notifications blocked", from `sitepolicy.permissions`.
  static func describePermissions(_ perms: [Value]) -> String {
    var allowed: [String] = []
    var blocked: [String] = []
    for (kind, name) in permissionNames {
      for p in perms where p.s("kind") == kind {
        if p.b("allowed") { if !allowed.contains(name) { allowed.append(name) } } else if !blocked.contains(name) { blocked.append(name) }
      }
    }
    var parts: [String] = []
    if !allowed.isEmpty { parts.append(Self.join(allowed) + " allowed") }
    if !blocked.isEmpty { parts.append(Self.join(blocked) + " blocked") }
    return Self.join(parts, " · ")
  }

  static func join(_ l: [String], _ sep: String = ", ") -> String {
    var out = ""
    for (i, s) in l.enumerated() { out += (i > 0 ? sep : "") + s }
    return out
  }

  /// Settings ▸ Shields ▸ Site permissions: every site with a remembered answer, one row each.
  func permissionItems() -> [Value] {
    let all = env.call("sitepolicy", "allPermissions").array ?? []
    var origins: [String] = []
    for p in all where !origins.contains(p.s("origin")) { origins.append(p.s("origin")) }
    var items: [Value] = []
    for o in origins {
      let mine = all.filter { $0.s("origin") == o }
      let session = mine.contains { !$0.b("kept") }
      items.append(["id": .string(o), "title": .string(IDN.display(URLs.host(o))),
                    "subtitle": .string(Self.describePermissions(mine) + (session ? " (camera, microphone and location until you quit)" : "")),
                    "buttons": [["id": "remove", "title": "Remove"]]])
    }
    return items
  }

  func settingsAction(_ key: String, _ item: String) {
    switch key {
    case "sites":
      sites[item] = nil
      saveSites()
    case "http":
      httpAllowed.removeAll { $0 == item }
      save("httpAllowed", .array(httpAllowed.map { .string($0) }))
    case "permissions":
      for (kind, _) in Self.permissionNames { env.call("sitepolicy", "setPermission", ["origin": .string(item), "kind": .string(kind), "allowed": .null]) }
      registerSettings()
      if panelOpen { renderPanel() }
      return
    default: return
    }
    apply()
    registerSettings()
    refreshPills()
  }
}
