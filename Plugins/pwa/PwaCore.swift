// The `pwa` plugin: web apps (PWA). A page with a web app manifest offers "Install as Web App"
// (the page's context menu and a command); an installed app opens in a standalone window with its
// own website data (profile `pwa:<app id>`). See docs/plugin-services.md#pwa and
// docs/research/gaps-webkit-browsers.md §5 ("Web apps").
//
// Detection: after the page in front loads, one small script in this plugin's isolated world
// reads the page's <link rel="manifest">, fetches it with the page's own session and returns the
// parsed fields with every URL resolved against the manifest's URL. Pages without a manifest cost
// that one probe per load (the empty answer is cached); nothing runs on other pages.
//
// The app's identity is the manifest's `id`, defaulting to its start URL (the W3C rule), so
// reinstalling a site updates its record instead of adding a second one.

#if !hasFeature(Embedded)
  import CordisValue
#endif

final class PwaCore {
  static let ns = "pwa"
  static let id = "pwa"
  static let startDelayMs: UInt64 = 1500

  /// An installed web app (storage ns "pwa", key "apps": {id: record}).
  struct WebApp {
    var id: String  // the manifest's `id`, else its start URL (the W3C default identity)
    var name: String
    var startUrl: String
    var scope: String
    var display: String  // the manifest's display mode ("browser" when absent)
    var icon: String
    var manifestUrl: String
    var installedAt: Int64
  }

  /// What the probe reported for a webview's current page: `manifest` is the parsed manifest
  /// object (or {url, error} when the link could not be read); .null when the page has no
  /// manifest link.
  struct Detection {
    var url: String
    var manifest: Value
  }

  /// An app's standalone window.
  struct OpenApp {
    var window: String
    var webview: String
  }

  let env: PluginEnv

  var apps: [String: WebApp] = [:]
  var detections: [String: Detection] = [:]  // webview -> its current page's answer
  var probing: Set<String> = []
  var pending: [String: String] = [:]  // inject request -> webview
  var pendingInstall: Set<String> = []  // webviews to install once their probe answers
  var open: [String: OpenApp] = [:]  // app id -> window
  var registered: [String] = []  // command ids live in `commands`
  var registerAttempts = 0
  var retrying = false
  var started = false
  var nextRequest: Int64 = 1

  init(env: PluginEnv) { self.env = env }

  // MARK: - Lifecycle

  /// Nothing is needed before the first window: the menu item, commands and the first probe are
  /// set up a moment after launch (`startNow` for tests).
  func start() {
    env.timer(Self.startDelayMs, false) { [self] in startNow() }
  }

  /// The page context menu's offer (`webviews.setMenu`), after View Page Source.
  static let menuItems: [Value] = [
    ["id": "pwa.install", "title": "Install as Web App", "when": "page", "icon": "sf:plus.app"],
  ]

  func startNow() {
    guard !started else { return }
    started = true
    load()
    env.call("webviews", "setMenu", ["plugin": .string(Self.id), "items": .array(Self.menuItems)])
    subscribe()
    registerCommands()
    // The tab restored at launch may have loaded already: check it now, since the events for it
    // came before we listened.
    if let w = focused() { probe(w) }
  }

  func stop() {
    retrying = true  // no more command retries
    env.call("webviews", "setMenu", ["plugin": .string(Self.id), "items": []])
    for id in registered { env.call("commands", "unregister", ["id": .string(id)]) }
    registered = []
    // The plugin owns the standalone windows: an unload (update, reload) closes them with their
    // pages rather than leaving web views nothing listens to.
    for (_, o) in open {
      env.call("window", "closeMini", ["id": .string(o.window)])
      env.call("webviews", "close", ["id": .string(o.webview)])
    }
    open = [:]
  }

  // MARK: - Storage

  func load() {
    guard case let .object(pairs) = env.call("storage", "get", ["ns": .string(Self.ns), "key": "apps"]) else { return }
    for (k, v) in pairs {
      if let a = Self.app(id: k, from: v) { apps[k] = a }
    }
  }

  func save() {
    var pairs: [(String, Value)] = []
    for (k, a) in apps { pairs.append((k, Self.record(a))) }
    env.call("storage", "set", ["ns": .string(Self.ns), "key": "apps", "value": .object(pairs)])
  }

  static func record(_ a: WebApp) -> Value {
    ["name": .string(a.name), "startUrl": .string(a.startUrl), "scope": .string(a.scope), "display": .string(a.display),
     "icon": .string(a.icon), "manifestUrl": .string(a.manifestUrl), "installedAt": .int(a.installedAt)]
  }

  static func app(id: String, from v: Value) -> WebApp? {
    let name = v.s("name"), start = v.s("startUrl")
    guard !name.isEmpty, URLs.isWeb(start) else { return nil }
    return WebApp(id: id, name: name, startUrl: start, scope: v.s("scope"), display: v.sOpt("display") ?? "browser",
                  icon: v.s("icon"), manifestUrl: v.s("manifestUrl"), installedAt: v.i("installedAt"))
  }

  /// The app a detected manifest becomes, or nil when the page offers no installable app: it
  /// needs a name (or short name) and a web start URL. The id is the manifest's `id`, defaulting
  /// to the start URL (the W3C identity rule).
  static func app(from m: Value, pageUrl: String, at now: Int64) -> WebApp? {
    guard !m.isNull, m["error"].isNull else { return nil }
    guard let name = m.sOpt("name") ?? m.sOpt("shortName") else { return nil }
    var start = m.s("startUrl")
    if start.isEmpty { start = pageUrl }
    guard URLs.isWeb(start) else { return nil }
    return WebApp(id: m.sOpt("id") ?? start, name: name, startUrl: start, scope: m.s("scope"),
                  display: m.sOpt("display") ?? "browser", icon: bestIcon(m.a("icons"), fallback: URLs.favicon(start)),
                  manifestUrl: m.s("url"), installedAt: now)
  }

  /// The icon to show for an app: the largest its manifest advertises ("any" is scalable, so it
  /// beats every raster size), never a monochrome-only one; the site's favicon when none applies.
  static func bestIcon(_ icons: [Value], fallback: String) -> String {
    var best = "", bestSize = -1
    for i in icons {
      let src = i.s("src")
      guard !src.isEmpty, !Text.contains(i.s("purpose"), "monochrome") else { continue }
      let size = iconSize(i.s("sizes"))
      if size > bestSize {
        best = src
        bestSize = size
      }
    }
    return best.isEmpty ? fallback : best
  }

  /// The largest dimension a `sizes` member advertises ("192x192 512x512" -> 512, "any" -> big).
  static func iconSize(_ sizes: String) -> Int {
    if sizes == "any" { return 100_000 }
    var best = 0
    for part in split(sizes, 32) {  // space
      let dims = split(part, 120)  // "x"
      if let w = Text.int(dims.first ?? "") { best = max(best, w) }
    }
    return best
  }

  static func split(_ s: String, _ sep: UInt8) -> [String] {
    var out: [String] = [], cur: [UInt8] = []
    for c in s.utf8 {
      if c == sep { out.append(String(decoding: cur, as: UTF8.self)); cur = [] } else { cur.append(c) }
    }
    out.append(String(decoding: cur, as: UTF8.self))
    return out
  }

  // MARK: - Detection

  /// The page in front (the open peek, else the focused pane), as pagetools sees it.
  func focused() -> String? {
    let f = env.call("content", "get")["focus"].string ?? ""
    return f.isEmpty ? nil : f
  }

  func currentURL(_ w: String) -> String {
    env.call("webviews", "get", ["id": .string(w)]).s("url")
  }

  /// Probes the page in front, but never mid-load: a script answered by the outgoing document
  /// would cache the new page as having no manifest. The load-finished event probes those.
  func probeFocused() {
    guard let w = focused() else { return }
    if env.call("webviews", "get", ["id": .string(w)])["loading"] != true { probe(w) }
  }

  /// Runs the detect script in the page, unless this page's answer is already known (or in
  /// flight). `force` re-checks (the `pwa.detect` service).
  func probe(_ w: String, force: Bool = false) {
    guard !probing.contains(w) else { return }
    let url = currentURL(w)
    guard URLs.isWeb(url) else { return }
    if !force, let d = detections[w], d.url == url { return }
    probing.insert(w)
    let request = "pwa-" + String(nextRequest)
    nextRequest += 1
    pending[request] = w
    let r = env.call("webviews", "inject", ["id": .string(w), "plugin": .string(Self.id), "request": .string(request), "script": .string(Self.detectScript)])
    if r.isErr {
      probing.remove(w)
      pending.removeValue(forKey: request)
      pendingInstall.remove(w)
    }
  }

  /// Reads the page's <link rel="manifest">, fetches it with the page's own session and returns
  /// the parsed fields, every URL resolved against the manifest's. null: no manifest link;
  /// {url, error}: a link that could not be read (the install offer says why).
  static let detectScript = """
    const link = document.querySelector('link[rel~="manifest"]');
    if (!link || !link.href) return null;
    const base = link.href;
    const abs = (u) => { try { return u ? new URL(u, base).href : null; } catch (e) { return null; } };
    const str = (v) => (typeof v === "string" && v.length > 0 ? v : null);
    let m = null;
    try {
      const r = await fetch(base, { credentials: "include" });
      if (!r.ok) return { url: base, error: "the manifest answered HTTP " + r.status };
      m = await r.json();
    } catch (e) {
      return { url: base, error: "the manifest could not be read: " + (e && e.message ? e.message : String(e)) };
    }
    if (!m || typeof m !== "object" || Array.isArray(m)) return { url: base, error: "the manifest is not a JSON object" };
    const startUrl = abs(m.start_url) || document.location.href;
    return {
      url: base,
      id: abs(m.id),
      name: str(m.name),
      shortName: str(m.short_name),
      startUrl: startUrl,
      scope: abs(m.scope) || new URL(".", startUrl).href,
      display: str(m.display),
      themeColor: str(m.theme_color),
      icons: (Array.isArray(m.icons) ? m.icons : [])
        .filter((i) => i && typeof i.src === "string")
        .map((i) => ({ src: abs(i.src), sizes: str(i.sizes) || "", purpose: str(i.purpose) || "" })),
    };
    """

  /// A probe's answer (`webviews.injectResult`): cached, reported, and an install waiting on it.
  func probed(_ request: String, _ v: Value) {
    guard let w = pending.removeValue(forKey: request) else { return }
    probing.remove(w)
    // A navigation can cancel the script: no answer to cache; the load-finished probe re-answers
    // (and completes an install waiting on it).
    guard v["ok"] == true else { return }
    let url = currentURL(w)
    guard URLs.isWeb(url) else { pendingInstall.remove(w); return }
    let manifest = v["value"]
    detections[w] = Detection(url: url, manifest: manifest)
    if !manifest.isNull, manifest["error"].isNull {
      env.emit("pwa.detected", ["webview": .string(w), "url": .string(url), "manifest": manifest])
    }
    if pendingInstall.remove(w) != nil { installReply(install(w)) }
  }

  func forget(_ w: String) {
    detections[w] = nil
    probing.remove(w)
    pendingInstall.remove(w)
    if let e = open.first(where: { $0.value.webview == w }) { open.removeValue(forKey: e.key) }
  }

  // MARK: - Install

  /// Installs the app a webview's current page offers. The same app again updates its record.
  func install(_ w: String) -> Value {
    let url = currentURL(w)
    guard let d = detections[w], d.url == url, !d.manifest.isNull else {
      return .err("pwa: no web app manifest detected on this page")
    }
    if let e = d.manifest.sOpt("error") { return .err("pwa: " + e) }
    guard let app = Self.app(from: d.manifest, pageUrl: url, at: env.now()) else {
      return .err("pwa: the manifest has no name or start URL")
    }
    let updated = apps[app.id] != nil
    apps[app.id] = app
    save()
    registerCommands()
    // Register the PWA with the dock service so it appears in the macOS Dock.
    if app.icon.hasPrefix("http") {
      _ = env.call("pwa_dock", "register", ["appId": .string(app.id), "name": .string(app.name), "icon": .string(app.icon)])
    }
    env.emit("pwa.installed", ["id": .string(app.id), "name": .string(app.name), "updated": .bool(updated)])
    toast((updated ? "Updated " : "Installed ") + app.name)
    var v = Self.record(app)
    v.put("id", .string(app.id))
    return ["app": v, "updated": .bool(updated)]
  }

  /// Uninstalls: the record goes, an open window of the app closes with it. The app's website
  /// data stays (the host has no per-profile wipe; Develop > Empty Caches clears every profile).
  func uninstall(_ id: String) -> Value {
    guard let app = apps.removeValue(forKey: id) else { return .err("pwa: no app '" + id + "'") }
    if let o = open.removeValue(forKey: id) {
      env.call("window", "closeMini", ["id": .string(o.window)])
      env.call("webviews", "close", ["id": .string(o.webview)])
    }
    // Unregister from the dock service.
    _ = env.call("pwa_dock", "unregister", ["appId": .string(id)])
    save()
    registerCommands()
    env.emit("pwa.uninstalled", ["id": .string(app.id), "name": .string(app.name)])
    return .okay
  }

  /// Toasts the error of a failed install (context menu, command, pending install).
  func installReply(_ r: Value) {
    if r.isErr { toast(r.s("error"), icon: "sf:exclamationmark.triangle") }
  }

  // MARK: - Standalone window

  /// Opens the app in its standalone window (its own profile, so its own website data), or
  /// brings the open window back to the front.
  func openApp(_ id: String) -> Value {
    guard let app = apps[id] else { return .err("pwa: no app '" + id + "'") }
    if let o = open[id] {
      env.call("window", "focusMini", ["id": .string(o.window)])
      return ["window": .string(o.window), "webview": .string(o.webview), "existing": .bool(true)]
    }
    guard let web = newWebview("app-", url: app.startUrl, profile: "pwa:" + app.id) else { return .err("pwa: cannot create a web view") }
    guard let win = env.call("window", "openMini", ["webview": .string(web), "space": .string(spaceName())])["id"].string else {
      env.call("webviews", "close", ["id": .string(web)])
      return .err("pwa: cannot open a window")
    }
    open[id] = OpenApp(window: win, webview: web)
    env.emit("pwa.opened", ["id": .string(id), "window": .string(win), "webview": .string(web)])
    return ["window": .string(win), "webview": .string(web)]
  }

  /// Creates a web view with a fresh id, skipping taken ones (peek's rule).
  func newWebview(_ prefix: String, url: String, profile: String) -> String? {
    for _ in 0..<1000 {
      let id = prefix + String(nextRequest)
      nextRequest += 1
      if !env.call("webviews", "create", ["id": .string(id), "url": .string(url), "profile": .string(profile)]).isErr { return id }
    }
    return nil
  }

  /// The user closed the window: the app's page goes with it (peek's Little Arc rule).
  func windowClosed(_ window: String) {
    guard let e = open.first(where: { $0.value.window == window }) else { return }
    open.removeValue(forKey: e.key)
    env.call("webviews", "close", ["id": .string(e.value.webview)])
    env.emit("pwa.windowClosed", ["id": .string(e.key), "webview": .string(e.value.webview)])
  }

  /// The window's "Open in <space>": the app's page becomes a today tab, keeping its state.
  func appToSpace(_ window: String) {
    guard let e = open.first(where: { $0.value.window == window }) else { return }
    let (appId, o) = (e.key, e.value)
    open.removeValue(forKey: appId)
    var url = currentURL(o.webview)
    if url.isEmpty || url == "about:blank" { url = apps[appId]?.startUrl ?? "" }
    env.call("window", "closeMini", ["id": .string(o.window)])
    if env.call("tabs", "open", ["url": .string(url), "webview": .string(o.webview)]).isErr {
      env.call("webviews", "close", ["id": .string(o.webview)])
      env.call("tabs", "open", ["url": .string(url)])
    }
  }

  func copyURL(_ window: String) {
    guard let e = open.first(where: { $0.value.window == window }) else { return }
    var url = currentURL(e.value.webview)
    if url.isEmpty || url == "about:blank" { url = apps[e.key]?.startUrl ?? "" }
    guard !url.isEmpty else { return }
    env.call("app", "copy", ["text": .string(url)])
    toast(Copied.link(url), icon: "sf:link")
  }

  func spaceName() -> String {
    let cur = env.call("spaces", "current").s("id")
    return (env.call("spaces", "list").array ?? []).first { $0.s("id") == cur }?.s("name") ?? "Space"
  }

  func toast(_ text: String, icon: String = "sf:app.badge") {
    env.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": .string(text), "icon": .string(icon)]])
  }

  // MARK: - Commands

  /// "Install This Page as a Web App" plus one "Open <name>" per installed app. `commands` is
  /// optional (plugin `commandbar`) and may load later: retry every 500 ms for 30 s.
  func registerCommands() {
    var want: [(String, String, String)] = [("pwa.install", "Install This Page as a Web App", "sf:plus.app")]
    for a in apps.values.sorted(by: { $0.name < $1.name }) {
      want.append(("pwa.open:" + a.id, "Open " + a.name, URLs.usable(a.icon) ? a.icon : "sf:app.badge"))
    }
    for id in registered where !want.contains(where: { $0.0 == id }) { env.call("commands", "unregister", ["id": .string(id)]) }
    registered.removeAll { id in !want.contains { $0.0 == id } }
    for w in want where !registered.contains(w.0) {
      let r = env.call("commands", "register", ["id": .string(w.0), "title": .string(w.1), "icon": .string(w.2), "owner": .string(Self.id),
                                                "keywords": ["install", "web app", "pwa", "app"]])
      if r.isErr {
        guard !retrying, registerAttempts < 60 else { return }
        retrying = true
        env.timer(500, false) { [self] in
          retrying = false
          registerAttempts += 1
          registerCommands()
        }
        return
      }
      registered.append(w.0)
    }
  }

  // MARK: - Service

  func handle(_ method: String, _ args: Value) -> Value {
    switch method {
    case "detect":
      let w = args.sOpt("webview") ?? focused()
      guard let w else { return .err("pwa: no page to check") }
      let url = currentURL(w)
      if !args.b("refresh"), let d = detections[w], d.url == url {
        return ["url": .string(url), "manifest": d.manifest]
      }
      probe(w, force: true)
      return ["url": .string(url), "pending": .bool(true)]
    case "install":
      guard let w = args.sOpt("webview") ?? focused() else { return .err("pwa: no page to install") }
      let url = currentURL(w)
      if let d = detections[w], d.url == url { return install(w) }
      // The probe may still be in flight (or the page loaded before we listened): install when
      // it answers. The context menu takes the same path through installReply's toast.
      pendingInstall.insert(w)
      probe(w, force: true)
      if !probing.contains(w) {  // inject refused (or not a web page): answer now, never hang
        pendingInstall.remove(w)
        return install(w)
      }
      return ["pending": .bool(true)]
    case "uninstall":
      let id = args.s("id")
      guard !id.isEmpty else { return .err("pwa: uninstall needs an id") }
      return uninstall(id)
    case "open":
      let id = args.s("id")
      guard !id.isEmpty else { return .err("pwa: open needs an id") }
      return openApp(id)
    case "list":
      return ["apps": .array(apps.values.sorted(by: { $0.name < $1.name }).map { a in
        var v = Self.record(a)
        v.put("id", .string(a.id))
        v.put("open", .bool(open[a.id] != nil))
        return v
      })]
    case "get":
      var det: [(String, Value)] = []
      for (w, d) in detections { det.append((w, ["url": .string(d.url), "manifest": d.manifest])) }
      var wins: [(String, Value)] = []
      for (k, o) in open { wins.append((k, ["window": .string(o.window), "webview": .string(o.webview)])) }
      return ["apps": .int(Int64(apps.count)), "detected": .object(det), "open": .object(wins)]
    default:
      return .err("pwa: unknown method " + method)
    }
  }

  // MARK: - Input

  func subscribe() {
    // A finished load of the page in front probes it (once per page; the answer is cached).
    env.on("webviews.progress") { [self] v in
      if v["loading"] == false, v.s("id") == focused() { probe(v.s("id")) }
    }
    env.on("tabs.selected") { [self] _ in probeFocused() }
    env.on("content.focus") { [self] _ in probeFocused() }
    // A navigation drops the page's answer; the next finished load probes again.
    env.on("webviews.url") { [self] v in detections[v.s("id")] = nil }
    env.on("webviews.closed") { [self] v in forget(v.s("id")) }
    env.on("webviews.detached") { [self] v in forget(v.s("id")) }
    env.on("webviews.injectResult") { [self] v in
      guard v.s("plugin") == Self.id else { return }
      probed(v.s("request"), v)
    }
    env.on("webviews.menu") { [self] v in
      guard v.s("plugin") == Self.id, v.s("id") == "pwa.install" else { return }
      _ = handle("install", ["webview": .string(v.s("webview"))])
    }
    env.on("commands.run") { [self] v in
      let id = v.s("id")
      if id == "pwa.install" {
        installReply(handle("install", [:]))
      } else if Text.hasPrefix(id, "pwa.open:") {
        let r = openApp(Text.dropPrefix(id, "pwa.open:"))
        if r.isErr { toast(r.s("error"), icon: "sf:exclamationmark.triangle") }
      }
    }
    env.on("window.miniClosed") { [self] v in windowClosed(v.s("id")) }
    env.on("window.miniAction") { [self] v in
      switch v.s("action") {
      case "open": appToSpace(v.s("id"))
      case "copy": copyURL(v.s("id"))
      default: break
      }
    }
  }
}
