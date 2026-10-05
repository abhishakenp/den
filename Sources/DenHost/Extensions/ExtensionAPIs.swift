// thin-host: feature-specific, migrate to plugin (whole file)
import AppKit
import CordisValue
import WebKit

/// Extension APIs WebKit leaves out, answered by den: `bookmarks`, `history`, `sessions`,
/// `search`, `downloads`, `sidePanel`, `sidebarAction` and `identity` (ExtensionBookmarks,
/// ExtensionHistory, ExtensionDownloads, ExtensionSidePanel, ExtensionIdentity).
///
/// **Bridge.** `ExtensionShim` defines the JavaScript side in den's copy of an extension. A call is
/// `runtime.sendNativeMessage("io.github.abhishakenp.den", {__den: api, method, args})`, answered
/// here through `WKWebExtensionControllerDelegate`'s native messaging (`{ok}` or `{error}`); the
/// shim gives the extension `nativeMessaging` only for this. Events come down a
/// `runtime.connectNative` port: a page or background subscribes to the events it has listeners
/// for (`{subscribe: [name], background}`), and den sends `{event, args}`.
///
/// **Sleeping backgrounds.** WebKit stops an idle service worker, and its port with it. den
/// remembers which events each background listens to (`apis.json`); an event for one whose port
/// is gone starts it (`loadBackgroundContent`) and is delivered once it subscribes again.
///
/// **Cost.** Nothing until an extension that asks for one of these permissions loads. Event
/// sources (diffing the tab tree, the downloads list) run only while someone listens; den records
/// visits only while an extension with `history` is loaded.
@MainActor
final class ExtensionAPIs {
  static let appId = "io.github.abhishakenp.den"
  /// Manifest permissions den provides (WebKit doesn't know them).
  nonisolated static let provided: Set<String> = [
    "bookmarks", "history", "sessions", "search", "downloads", "downloads.open", "downloads.shelf", "downloads.ui", "sidePanel", "identity", "identity.email",
  ]
  /// The APIs reached through the bridge, by the permission that unlocks each.
  static func permission(_ api: String) -> String {
    switch api {
    case "sidebarAction": return "sidebar_action"  // a manifest key, not a permission
    default: return api
    }
  }

  unowned let svc: ExtensionsService
  let file: URL
  init(svc: ExtensionsService, root: URL) {
    self.svc = svc
    file = root.appendingPathComponent("apis.json")
  }

  lazy var bookmarks = ExtensionBookmarks(call: { [unowned self] s, m, a in svc.call(s, m, a) })
  lazy var history: ExtensionHistory = {
    let h = ExtensionHistory(call: { [unowned self] s, m, a in svc.call(s, m, a) }, file: svc.root.appendingPathComponent("history.json"))
    h.onVisited = { [unowned self] v in emit("history.onVisited", [v]) }
    h.onVisitRemoved = { [unowned self] v in emit("history.onVisitRemoved", [v]) }
    return h
  }()
  lazy var downloads = ExtensionDownloads(call: { [unowned self] s, m, a in svc.call(s, m, a) })
  lazy var sidePanel: ExtensionSidePanel = {
    let p = ExtensionSidePanel(call: { [unowned self] s, m, a in svc.call(s, m, a) })
    p.restore(stored()["sidePanel"])
    p.save = { [unowned self] in store() }
    return p
  }()
  lazy var identity = ExtensionIdentity()

  // MARK: Who may call what

  static func manifestPermissions(_ ext: WKWebExtension) -> Set<String> {
    let all = ((ext.manifest["permissions"] as? [Any]) ?? []) + ((ext.manifest["optional_permissions"] as? [Any]) ?? [])
    return Set(all.compactMap { $0 as? String })
  }

  /// Whether the extension uses any API den provides through the bridge (then it gets
  /// `nativeMessaging` for den alone).
  nonisolated static func usesBridge(_ manifest: [String: Any]) -> Bool {
    let perms = Set((((manifest["permissions"] as? [Any]) ?? []) + ((manifest["optional_permissions"] as? [Any]) ?? [])).compactMap { $0 as? String })
    return !perms.isDisjoint(with: provided) || manifest["sidebar_action"] != nil || manifest["side_panel"] != nil
  }

  func allowed(_ api: String, _ ctx: WKWebExtensionContext) -> Bool {
    if api == "sidebarAction" { return ctx.webExtension.manifest["sidebar_action"] != nil }
    if api == "sidePanel" { return Self.manifestPermissions(ctx.webExtension).contains("sidePanel") || ctx.webExtension.manifest["side_panel"] != nil }
    return Self.manifestPermissions(ctx.webExtension).contains(Self.permission(api))
  }

  // MARK: Calls

  func message(_ message: Any, ctx: WKWebExtensionContext, reply: @escaping (Any?, (any Error)?) -> Void) {
    let m = ValueJSON.value(message)
    let api = m.str("__den"), method = m.str("method")
    guard !api.isEmpty else { return reply(nil, ExtensionsService.failure("den: not a den API call")) }
    guard allowed(api, ctx) else {
      return reply(ValueJSON.any(["error": .string("\(api) needs the “\(Self.permission(api))” permission")]), nil)
    }
    perform(api, method, m.list("args"), ctx) { r in
      reply(ValueJSON.any(r.isError && r.object?.count == 1 ? r : ["ok": r]), nil)
    }
  }

  func perform(_ api: String, _ method: String, _ args: [Value], _ ctx: WKWebExtensionContext, _ done: @escaping (Value) -> Void) {
    let id = ctx.uniqueIdentifier
    let name = ctx.webExtension.displayName ?? id
    let icon = svc.registry.iconPath(id)
    switch api {
    case "bookmarks":
      startBookmarkEvents()
      done(bookmarks.handle(method, args))
    case "history": done(history.handle(method, args))
    case "sessions": done(history.sessions(method, args))
    case "search": done(search(args.first ?? .null))
    case "downloads": downloads.handle(method, args, ext: (id, name), tab: svc.selectedTabId(), done: done)
    case "sidePanel": done(sidePanel.handle(method, args, ctx: ctx, icon: icon))
    case "sidebarAction": done(sidePanel.sidebarAction(method, args, ctx: ctx, icon: icon))
    case "identity":
      guard method == "launchWebAuthFlow" else { return done(.error("identity.\(method) isn’t available in den")) }
      let store = svc.selectedTabId().flatMap { svc.webviews.record($0) }.map { svc.webviews.store(for: $0.profile) } ?? svc.webviews.store(for: "default")
      identity.launch(args.first ?? .null, id: id, geckoId: geckoId(id), store: store, parent: svc.window.window, done: done)
    default: done(.error("\(api) isn’t available in den"))
    }
  }

  /// A Firefox Add-ons install's add-on id (its redirect URL is derived from it).
  func geckoId(_ id: String) -> String? {
    guard let e = svc.registry.item(id), e.sourceKind == .firefox, let ctx = svc.contexts[id] else { return nil }
    let m = ctx.webExtension.manifest
    let gecko = ((m["browser_specific_settings"] ?? m["applications"]) as? [String: Any])?["gecko"] as? [String: Any]
    return gecko?["id"] as? String
  }

  /// `search.query {text, disposition?, tabId?}`: den's default search engine (the command bar's
  /// first engine), else Google.
  func search(_ o: Value) -> Value {
    let engine = svc.call("commands", "engines", .null).array?.first?.str("url") ?? ""
    let template = engine.contains("%s") ? engine : "https://www.google.com/search?q=%s"
    let q = o.str("text").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? ""
    let url = template.replacingOccurrences(of: "%s", with: q)
    return ["url": .string(url)]  // the shim opens it where the extension asked (it knows its tab ids)
  }

  // MARK: Events

  struct Port {
    let ctx: String
    let port: WKWebExtension.MessagePort
    var events: Set<String> = []
    var background = false
  }
  var ports: [ObjectIdentifier: Port] = [:]
  /// Events each extension's background listens to, kept across launches.
  var interest: [String: Set<String>] = [:]
  var interestLoaded = false
  var queued: [String: [(String, [Value])]] = [:]
  /// What each wake-up of a sleeping background came to (tests, extensions.log).
  var wakes: [String] = []

  func connect(_ port: WKWebExtension.MessagePort, ctx: WKWebExtensionContext) -> (any Error)? {
    let key = ObjectIdentifier(port)
    ports[key] = Port(ctx: ctx.uniqueIdentifier, port: port)
    port.messageHandler = { [weak self] msg, _ in MainActor.assumeIsolated { self?.portMessage(key, ValueJSON.value(msg)) } }
    port.disconnectHandler = { [weak self] _ in MainActor.assumeIsolated { _ = self?.ports.removeValue(forKey: key) } }
    return nil
  }

  func portMessage(_ key: ObjectIdentifier, _ m: Value) {
    guard var p = ports[key] else { return }
    let names = Set(m.list("subscribe").compactMap(\.string))
    guard !names.isEmpty else { return }
    p.events.formUnion(names)
    if m.flag("background") { p.background = true }
    ports[key] = p
    if p.background {
      loadInterest()
      let before = interest[p.ctx] ?? []
      interest[p.ctx] = before.union(names)
      if interest[p.ctx] != before { store() }
      // Events that woke this background.
      let waiting = queued.removeValue(forKey: p.ctx) ?? []
      for (e, args) in waiting where p.events.contains(e) { send(p.port, e, args) }
      if !waiting.isEmpty { queued[p.ctx] = waiting.filter { !p.events.contains($0.0) } }
    }
    startSources(names)
  }

  func send(_ port: WKWebExtension.MessagePort, _ event: String, _ args: [Value]) {
    port.sendMessage(ValueJSON.any(["event": .string(event), "args": .array(args)])) { _ in }
  }

  /// Whether anyone (a live page or a background that listened before) wants events of `api`.
  func listening(_ prefix: String) -> Bool {
    loadInterest()
    return ports.values.contains { $0.events.contains { $0.hasPrefix(prefix) } } || interest.values.contains { $0.contains { $0.hasPrefix(prefix) } }
  }

  /// Delivers an event to every loaded extension that listens and may see it.
  func emit(_ event: String, _ args: [Value]) {
    loadInterest()
    let api = String(event.split(separator: ".").first ?? "")
    for (id, ctx) in svc.contexts where allowed(api, ctx) {
      let live = ports.values.filter { $0.ctx == id && $0.events.contains(event) }
      live.forEach { send($0.port, event, args) }
      // A background that listens but sleeps: wake it, deliver when it subscribes again.
      if interest[id]?.contains(event) == true, !ports.values.contains(where: { $0.ctx == id && $0.background }) {
        var q = queued[id] ?? []
        q.append((event, args))
        if q.count > 200 { q.removeFirst(q.count - 200) }
        queued[id] = q
        if q.count == 1 { wake(ctx, for: event) }
      }
    }
  }

  /// Starts a background so it subscribes again. A background WebKit reports started that
  /// hasn't connected within 3 s is started again (at most 3 times), then its queue is dropped.
  func wake(_ ctx: WKWebExtensionContext, for event: String, attempt: Int = 1) {
    let id = ctx.uniqueIdentifier
    ctx.loadBackgroundContent { [weak self] err in
      MainActor.assumeIsolated {
        guard let self else { return }
        let line = "background of \(id) for \(event) (try \(attempt)): " + (err.map { "failed: \($0.localizedDescription)" } ?? "started")
        self.wakes.append(line)
        if self.wakes.count > 50 { self.wakes.removeFirst() }
        self.svc.record(line)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
          MainActor.assumeIsolated {
            guard let self, self.queued[id]?.isEmpty == false, self.svc.contexts[id] === ctx,
                  !self.ports.values.contains(where: { $0.ctx == id && $0.background }) else { return }
            if attempt < 3 { self.wake(ctx, for: event, attempt: attempt + 1) } else { self.queued[id] = nil }
          }
        }
      }
    }
  }

  var sourcesStarted: Set<String> = []

  func startSources(_ names: Set<String>) {
    if names.contains(where: { $0.hasPrefix("bookmarks.") }) { startBookmarkEvents() }
    if names.contains(where: { $0.hasPrefix("downloads.") }) { startDownloadEvents() }
    if names.contains(where: { $0.hasPrefix("sessions.") }) { startSessionEvents() }
    if names.contains(where: { $0.hasPrefix("sidePanel.") || $0.hasPrefix("sidebarAction.") }) { startPanelEvents() }
  }

  /// At load: an extension with `history` turns visit recording on; one whose background
  /// listened before gets its event sources back.
  func loaded(_ ctx: WKWebExtensionContext) {
    if Self.manifestPermissions(ctx.webExtension).contains("history") { startRecording() }
    loadInterest()
    if let i = interest[ctx.uniqueIdentifier] { startSources(i) }
    // Events waited for an earlier context of this extension (reloaded meanwhile): wake this one.
    if queued[ctx.uniqueIdentifier]?.isEmpty == false { ctx.loadBackgroundContent { _ in } }
  }

  /// The extension was turned off or removed: its panel goes, its ports and queue too.
  func unloaded(_ id: String, removed: Bool) {
    ports = ports.filter { $0.value.ctx != id }
    queued[id] = nil
    identity.flows[id]?.finish(.failure(ExtensionsService.failure("The extension was turned off.")))
    _ = svc.call("panels", "removeOwner", ["owner": .string(id)])
    if removed {
      interest[id] = nil
      sidePanel.options[id] = nil
      store()
      // The last extension that could read history is gone: so are the visits den kept for it.
      if !svc.contexts.contains(where: { $0.key != id && Self.manifestPermissions($0.value.webExtension).contains("history") }) { history.forget() }
    }
  }

  // MARK: Sources

  var bookmarkSnapshot: ExtensionBookmarks.Flat?
  var bookmarkDiffPending = false

  func startBookmarkEvents() {
    guard sourcesStarted.insert("bookmarks").inserted else { return }
    svc.subscribe("tabs.changed") { [weak self] _ in MainActor.assumeIsolated { self?.bookmarksChanged() } }
    if listening("bookmarks.") { bookmarkSnapshot = bookmarks.flat() }
  }

  /// tabs.changed comes in bursts (every title change): diff once, a moment later.
  func bookmarksChanged() {
    guard listening("bookmarks."), !bookmarkDiffPending else { return }
    bookmarkDiffPending = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.bookmarkDiffPending = false
        let new = self.bookmarks.flat()
        defer { self.bookmarkSnapshot = new }
        guard let old = self.bookmarkSnapshot else { return }
        let t = self.bookmarks.tree()
        for (e, args) in ExtensionBookmarks.diff(old, new, node: { ExtensionBookmarks.find($0, in: t)?.value(deep: false) ?? .null }) { self.emit(e, args) }
      }
    }
  }

  var downloadSnapshot: [Int64: Value]?

  func startDownloadEvents() {
    guard sourcesStarted.insert("downloads").inserted else { return }
    for e in ["downloads.changed", "downloads.started", "downloads.finished"] {
      svc.host.on(e) { [weak self] _ in self?.downloadsChanged() }
    }
    downloadSnapshot = downloads.snapshot()
  }

  func downloadsChanged() {
    guard listening("downloads.") else { return }
    let new = downloads.snapshot()
    defer { downloadSnapshot = new }
    guard let old = downloadSnapshot else { return }
    for (e, args) in ExtensionDownloads.diff(old, new) { emit(e, args) }
  }

  var archiveHead: String?

  func startSessionEvents() {
    guard sourcesStarted.insert("sessions").inserted else { return }
    archiveHead = svc.call("tabs", "archive", .null).array?.first?.str("id")
    svc.subscribe("tabs.changed") { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.listening("sessions.") else { return }
        let head = self.svc.call("tabs", "archive", .null).array?.first?.str("id")
        if head != self.archiveHead {
          self.archiveHead = head
          self.emit("sessions.onChanged", [])
        }
      }
    }
  }

  func startPanelEvents() {
    guard sourcesStarted.insert("panels").inserted else { return }
    for (event, open) in [("panels.shown", true), ("panels.hidden", false)] {
      svc.subscribe(event) { [weak self] v in
        MainActor.assumeIsolated {
          guard let self, let owner = v["owner"].string, let ctx = self.svc.contexts[owner] else { return }
          let path = self.sidePanel.current(ctx).path ?? ""
          if open {
            self.emitTo(owner, "sidePanel.onOpened", [["windowId": 1, "path": .string(path)]])
          } else {
            self.emitTo(owner, "sidePanel.onClosed", [["windowId": 1, "path": .string(path)]])
          }
        }
      }
    }
  }

  func emitTo(_ id: String, _ event: String, _ args: [Value]) {
    for p in ports.values where p.ctx == id && p.events.contains(event) { send(p.port, event, args) }
  }

  var recording = false

  /// Visits are recorded from now on (an extension with `history` is loaded).
  func startRecording() {
    guard !recording else { return }
    recording = true
    svc.host.on("webviews.url") { [weak self] v in self?.visited(v) }
    svc.host.on("webviews.title") { [weak self] v in
      guard let self, let id = v["id"].string, let r = self.svc.webviews.record(id), !WebViewsService.isPrivate(r.profile) else { return }
      self.history.title(v.str("title"), for: r.webView?.url?.absoluteString ?? r.url)
    }
  }

  func visited(_ v: Value) {
    guard recording, svc.contexts.values.contains(where: { Self.manifestPermissions($0.webExtension).contains("history") }) else { return }
    guard let id = v["id"].string, let r = svc.webviews.record(id), !WebViewsService.isPrivate(r.profile) else { return }
    // Pages only: tabs, panels and peeks; not an extension's own pages.
    let url = v.str("url")
    history.record(url, title: r.title)
  }

  // MARK: apis.json

  func stored() -> Value {
    guard let d = try? Data(contentsOf: file), let v = ValueJSON.parse(d) else { return .null }
    return v
  }

  func loadInterest() {
    guard !interestLoaded else { return }
    interestLoaded = true
    for (k, list) in stored()["interest"].object ?? [] { interest[k] = Set(list.array?.compactMap(\.string) ?? []) }
  }

  func store() {
    loadInterest()
    let v: Value = [
      "interest": .object(interest.keys.sorted().map { ($0, .array(interest[$0]!.sorted().map { .string($0) })) }),
      "sidePanel": sidePanel.value(),
    ]
    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(ValueJSON.string(v).utf8).write(to: file, options: .atomic)
  }
}
