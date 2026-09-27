import AppKit
import CordisValue
import WebKit
import os

/// `extensions` service: Chrome and Firefox extensions on Apple's `WKWebExtension` engine.
/// Full reference: docs/host-api.md#extensions.
///
/// Cost model: with nothing installed, nothing exists. The registry file is read once, at the first
/// web view; the `WKWebExtensionController` is created on the first install (or at the first web
/// view when something is installed) and then attached to every web view configuration. Background
/// service workers are started and stopped by WebKit on demand (den never calls `loadBackgroundContent`).
@MainActor
public final class ExtensionsService: NSObject, HostService {
  public let name = "webext"
  let host: ServiceHost
  let webviews: WebViewsService
  let window: DenWindowController
  var content: ContentService?
  /// Calls any service, plugins included (`tabs`), and subscribes to plugin events. Set by `DenRuntime`.
  public var call: (String, String, Value) -> Value = { _, _, _ in .error("webext: not wired") }
  public var subscribe: (String, @escaping (Value) -> Void) -> Void = { _, _ in }
  public let root: URL
  /// `~/.den/extensions`: unpacked folders loaded as development extensions. nil = none.
  public var homeFolder: URL?
  let persistent: Bool
  static let log = Logger(subsystem: "io.github.abhishakenp.den", category: "extensions")

  private var _registry: ExtensionRegistry?
  var registry: ExtensionRegistry {
    get {
      if let r = _registry { return r }
      let r = ExtensionRegistry(root: root)
      _registry = r
      return r
    }
    set { _registry = newValue }
  }

  public private(set) var controller: WKWebExtensionController?
  var contexts: [String: WKWebExtensionContext] = [:]
  var loadErrors: [String: String] = [:]
  var ready = false
  var waiters: [() -> Void] = []
  lazy var mainWindow = ExtWindow(svc: self)
  var tabObjects: [String: ExtTab] = [:]
  lazy var delegateObject = ExtensionControllerDelegate(svc: self)
  var selectedTab: String?
  let ui: ExtensionsUI

  public init(host: ServiceHost, webviews: WebViewsService, window: DenWindowController, root: URL, persistent: Bool) {
    self.host = host
    self.webviews = webviews
    self.window = window
    self.root = root
    self.persistent = persistent
    ui = ExtensionsUI(window: window)
    super.init()
    ui.svc = self
    webviews.extensionHooks = self
  }

  /// Called once `call` and `subscribe` are wired. Listens on the plugin bus, which carries both
  /// host events (forwarded) and plugin events.
  public func start() {
    subscribe("ui.action") { [weak self] v in MainActor.assumeIsolated { self?.dialogAction(v) } }
    subscribe("schedule.fire") { [weak self] v in
      MainActor.assumeIsolated { if v.str("id") == Self.updateScheduleId { self?.checkUpdates(force: false) } }
    }
  }

  // MARK: Service

  public func handle(method: String, args: Value) -> Value {
    switch method {
    case "list": return .array(registry.items.map(describe))
    case "get":
      guard let e = registry.item(args.str("id")) else { return .error("webext: no extension '\(args.str("id"))'") }
      return describe(e)
    case "install":
      let path = (args.str("path") as NSString).expandingTildeInPath
      guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return .error("webext: no file at '\(path)'") }
      let req = request(args)
      Task { await self.installFile(URL(fileURLWithPath: path), request: req) }
      return ["request": .string(req), "pending": true]
    case "installFromStore":
      let ref: StoreRef?
      if let u = URL(string: args.str("url")), args["id"].isNull { ref = ExtensionPackage.storeRef(for: u) } else {
        ref = StoreRef(source: ExtensionSource(rawValue: args.str("source", "chrome")) ?? .chrome, id: args.str("id"))
      }
      guard let ref, !ref.id.isEmpty else { return .error("webext: not a Chrome Web Store or Firefox Add-ons item") }
      let req = request(args)
      Task { await self.installFromStore(ref, request: req) }
      return ["request": .string(req), "pending": true]
    case "pickFile": pickFile(); return .ok
    case "uninstall": return uninstall(args.str("id"))
    case "setEnabled": return setEnabled(args.str("id"), args.flag("enabled", true))
    case "setPinned": return setPinned(args.str("id"), args.flag("pinned", true))
    case "setSiteAccess": return setSiteAccess(args.str("id"), mode: args.str("mode"), sites: args["sites"].array?.compactMap(\.string))
    case "allowSite": return allowSite(args.str("id"), site: args.str("site"), allowed: args.flag("allowed", true))
    case "checkUpdates":
      checkUpdates(force: args.flag("force", true))
      return ["pending": true]
    case "action": return performAction(args.str("id"), anchor: nil)
    case "menu":
      if args.flag("open", true) { ui.showMenu() } else { ui.close() }
      return .ok
    case "closePopup": ui.close(); return .ok
    case "openOptions":
      guard let ctx = contexts[args.str("id")], let u = ctx.optionsPageURL else { return .error("webext: no options page") }
      return openTab(u, active: true, pinned: false).1.map { .error($0.localizedDescription) } ?? .ok
    case "settings":
      if let b = args["storeButtons"].bool { setStoreButtons(b) }
      return ["storeButtons": .bool(storeButtons)]
    case "state":
      return ["controller": .bool(controller != nil), "ready": .bool(ready), "loaded": .array(contexts.keys.sorted().map { .string($0) }),
              "popup": ui.popupFor.map { .string($0) } ?? .null, "menu": .bool(ui.menuOpen), "prompts": .int(Int64(prompts.count))]
    default: return .error("webext: unknown method '\(method)'")
    }
  }

  private var nextRequest = 1
  func request(_ args: Value) -> String {
    if let r = args["request"].string, !r.isEmpty { return r }
    defer { nextRequest += 1 }
    return "install-\(nextRequest)"
  }

  /// The extension as `list` / `get` return it.
  func describe(_ e: InstalledExtension) -> Value {
    let ctx = contexts[e.id]
    let ext = ctx?.webExtension
    var perms: [Value] = []
    var unsupported: [Value] = []
    if let ext {
      perms = ExtensionText.describe(permissions: ext.requestedPermissions.map(\.rawValue), patterns: ext.allRequestedMatchPatterns.map(\.string)).map { .string($0) }
      let manifestPerms = ((ext.manifest["permissions"] as? [Any]) ?? []).compactMap { $0 as? String }.filter { !$0.contains("://") && $0 != "<all_urls>" }
      let known = Set((ext.requestedPermissions.union(ext.optionalPermissions)).map(\.rawValue))
      unsupported = manifestPerms.filter { !known.contains($0) }.map { .string($0) }
    }
    let action = ctx?.action(for: selectedTabId().map { tab($0) })
    var v: Value = [
      "id": .string(e.id), "name": .string(ext?.displayName ?? e.name), "version": .string(e.version), "source": .string(e.source),
      "description": .string(ext?.displayDescription ?? ""), "enabled": .bool(e.enabled), "pinned": .bool(e.pinned),
      "icon": .string(FileManager.default.fileExists(atPath: registry.iconPath(e.id)) ? registry.iconPath(e.id) : "sf:puzzlepiece.extension"),
      "siteAccess": .string(e.siteAccess), "sites": .array(e.sites.map { .string($0) }),
      "permissions": .array(perms), "unsupported": .array(unsupported),
      "loaded": .bool(ctx?.isLoaded ?? false), "hasPopup": .bool(action?.presentsPopup ?? false),
      "hasAction": .bool(action != nil), "hasOptions": .bool(ext?.hasOptionsPage ?? false),
      "badge": .string(action?.badgeText ?? ""), "manifestVersion": .int(Int64(ext?.manifestVersion ?? 0)),
      "background": .string(ext == nil ? "unknown" : (ext!.hasPersistentBackgroundContent ? "persistent" : (ext!.hasBackgroundContent ? "on demand" : "none"))),
      "errors": .array(((ctx?.errors ?? []).map(\.localizedDescription) + (loadErrors[e.id].map { [$0] } ?? [])).map { .string($0) }),
    ]
    if let s = e.storeId { v = v.with("storeId", .string(s)) }
    if let u = storeURL(e) { v = v.with("storeURL", .string(u)) }
    if let a = e.availableVersion { v = v.with("updateAvailable", .string(a)) }
    return v
  }

  func storeURL(_ e: InstalledExtension) -> String? {
    guard let s = e.storeId else { return nil }
    switch e.sourceKind {
    case .chrome: return "https://chromewebstore.google.com/detail/\(s)"
    case .firefox: return "https://addons.mozilla.org/firefox/addon/\(s)/"
    default: return nil
    }
  }

  func changed() {
    host.emit("webext.changed", ["extensions": .array(registry.items.map(describe))])
    ui.refresh()
  }

  static func failure(_ s: String) -> NSError { NSError(domain: "den.extensions", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }
  func result(_ v: Value) -> Error? { v.isError ? Self.failure(v.str("error")) : nil }

  // thin-host: feature-specific, migrate to plugin
  func toast(_ text: String, icon: String = "sf:puzzlepiece.extension.fill") {
    _ = host.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": .string(text), "icon": .string(icon), "duration": 4000]])
  }

  // MARK: Tabs (the `tabs` plugin through the host)

  /// The current space's tabs, favorites first, as a flat list of ids (folders and splits opened up).
  func tabIds() -> [String] { tabList().map(\.0) }

  /// (tab id, kind) in sidebar order: favorites, pinned, today; folders and splits opened up.
  func tabList() -> [(String, String)] {
    let l = call("tabs", "list", .null)
    guard !l.isError else { return [] }
    var out: [(String, String)] = []
    for (section, kind) in [("favorites", "favorite"), ("pinned", "pinned"), ("today", "today")] {
      var stack: [Value] = l.list(section).reversed()
      while let i = stack.popLast() {
        if i.flag("folder") || i.flag("split") {
          stack.append(contentsOf: i.list("children").reversed())
        } else if let id = i["id"].string {
          out.append((id, kind))
        }
      }
    }
    return out
  }

  func tabKind(_ id: String) -> String { tabList().first { $0.0 == id }?.1 ?? "" }

  func selectedTabId() -> String? { call("tabs", "selected", .null)["id"].string }

  func tab(_ id: String) -> ExtTab {
    if let t = tabObjects[id] { return t }
    let t = ExtTab(id: id, svc: self)
    tabObjects[id] = t
    return t
  }

  /// Opens a tab through the `tabs` plugin (or a bare web view in the content area without it).
  func openTab(_ url: URL?, active: Bool, pinned: Bool) -> (ExtTab?, Error?) {
    let u = url?.absoluteString ?? "about:blank"
    let r = call("tabs", "open", ["url": .string(u), "background": .bool(!active), "kind": pinned ? "pinned" : "today"])
    guard let id = r["id"].string else { return (nil, result(r) ?? Self.failure("could not open a tab")) }
    return (tab(id), nil)
  }

  func subscribeTabs() {
    subscribe("tabs.opened") { [weak self] v in
      MainActor.assumeIsolated {
        guard let self, let c = self.controller, let id = v["id"].string else { return }
        c.didOpenTab(self.tab(id))
      }
    }
    subscribe("tabs.closed") { [weak self] v in
      MainActor.assumeIsolated {
        guard let self, let c = self.controller, let id = v["id"].string, let t = self.tabObjects.removeValue(forKey: id) else { return }
        c.didCloseTab(t, windowIsClosing: false)
      }
    }
    subscribe("tabs.selected") { [weak self] v in
      MainActor.assumeIsolated {
        guard let self, let c = self.controller, let id = v["id"].string else { return }
        let prev = v["previous"].string.map { self.tab($0) }
        self.selectedTab = id
        c.didActivateTab(self.tab(id), previousActiveTab: prev)
        c.didSelectTabs([self.tab(id)])
        self.ui.refresh()
      }
    }
    for (event, prop) in [("webviews.url", WKWebExtension.TabChangedProperties.URL), ("webviews.title", .title), ("webviews.audio", .playingAudio)] {
      host.on(event) { [weak self] v in
        guard let self, let c = self.controller, let id = v["id"].string, self.tabObjects[id] != nil || self.webviews.record(id) != nil else { return }
        c.didChangeTabProperties(prop, for: self.tab(id))
        if prop == .URL { self.ui.refresh() }
      }
    }
    host.on("webviews.progress") { [weak self] v in
      guard let self, let c = self.controller, let id = v["id"].string, v["loading"] == false || v["progress"].double == 0.1 else { return }
      c.didChangeTabProperties(.loading, for: self.tab(id))
    }
  }

  // MARK: Controller

  /// True when something is installed (or waits in ~/.den/extensions). Reads the registry once.
  var hasAnything: Bool {
    if registry.items.contains(where: \.enabled) { return true }
    return !homeFolders().isEmpty
  }

  func homeFolders() -> [URL] {
    guard let h = homeFolder, let list = try? FileManager.default.contentsOfDirectory(at: h, includingPropertiesForKeys: nil) else { return [] }
    return list.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }.sorted { $0.path < $1.path }
  }

  /// Creates the controller (once) and starts loading every enabled extension.
  @discardableResult
  func ensureController() -> WKWebExtensionController {
    if let c = controller { return c }
    let t0 = Date()
    let cfg: WKWebExtensionController.Configuration
    if persistent {
      cfg = .init(identifier: WebViewsService.profileUUID("extensions"))
    } else {
      cfg = .nonPersistent()
      cfg.defaultWebsiteDataStore = .nonPersistent()
    }
    let c = WKWebExtensionController(configuration: cfg)
    c.delegate = delegateObject
    controller = c
    subscribeTabs()
    selectedTab = selectedTabId()
    c.didOpenWindow(mainWindow)
    c.didFocusWindow(mainWindow)
    Self.log.info("controller created in \(Date().timeIntervalSince(t0) * 1000, format: .fixed(precision: 1)) ms")
    Task { await loadAll() }
    scheduleUpdateChecks()
    return c
  }

  func loadAll() async {
    let t0 = Date()
    for e in registry.items where e.enabled { await load(e) }
    for dir in homeFolders() { await adoptHome(dir) }
    ready = true
    let w = waiters
    waiters = []
    w.forEach { $0() }
    Self.log.info("loaded \(self.contexts.count) extension(s) in \(Date().timeIntervalSince(t0) * 1000, format: .fixed(precision: 1)) ms")
    if ProcessInfo.processInfo.environment["DEN_TRACE"] != nil {
      print(String(format: "extensions.loaded n=%d ms=%.1f", contexts.count, Date().timeIntervalSince(t0) * 1000))
    }
    if !contexts.isEmpty { changed() }
  }

  /// Loads one installed extension into the controller, restoring its grants.
  func load(_ e: InstalledExtension) async {
    guard let c = controller else { return }
    if let old = contexts.removeValue(forKey: e.id) { try? c.unload(old) }
    do {
      let ext = try await WKWebExtension(resourceBaseURL: URL(fileURLWithPath: registry.path(e), isDirectory: true))
      let ctx = WKWebExtensionContext(for: ext)
      ctx.uniqueIdentifier = e.id
      // A stable origin, so the extension's own storage survives relaunches.
      ctx.baseURL = URL(string: "webkit-extension://\(e.id)/")!
      ctx.isInspectable = true
      applyGrants(ctx, e)
      try c.load(ctx)
      contexts[e.id] = ctx
      loadErrors[e.id] = nil
    } catch {
      loadErrors[e.id] = error.localizedDescription
      Self.log.error("load \(e.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Grants what the user approved: API permissions, and host access by the site access mode.
  func applyGrants(_ ctx: WKWebExtensionContext, _ e: InstalledExtension) {
    var perms: [WKWebExtension.Permission: Date] = [:]
    for p in e.granted { perms[WKWebExtension.Permission(rawValue: p)] = .distantFuture }
    ctx.grantedPermissions = perms
    var patterns: [WKWebExtension.MatchPattern: Date] = [:]
    switch e.siteAccess {
    case "all":
      for s in e.grantedPatterns { if let p = try? WKWebExtension.MatchPattern(string: s) { patterns[p] = .distantFuture } }
    case "sites":
      for site in e.sites {
        for s in ["*://\(site)/*", "*://*.\(site)/*"] { if let p = try? WKWebExtension.MatchPattern(string: s) { patterns[p] = .distantFuture } }
      }
    default: break  // "click": activeTab grants the clicked tab only
    }
    ctx.grantedPermissionMatchPatterns = patterns
  }

  /// A folder in ~/.den/extensions: loaded in place and trusted (the user put it there).
  func adoptHome(_ dir: URL) async {
    guard let m = try? ExtensionPackage.readManifest(dir) else { return }
    let id = ExtensionPackage.extensionId(source: .home, storeId: nil, manifest: m, path: dir.path)
    if registry.item(id) == nil {
      guard let ext = try? await WKWebExtension(resourceBaseURL: dir) else { return }
      var e = InstalledExtension(id: id, name: ext.displayName ?? m.name, version: m.version, source: ExtensionSource.home.rawValue, dir: dir.path)
      e.granted = ext.requestedPermissions.map(\.rawValue)
      e.grantedPatterns = ext.requestedPermissionMatchPatterns.map(\.string)
      e.installedAt = Date().timeIntervalSince1970 * 1000
      writeIcon(ext, id: id)
      registry.upsert(e)
      registry.save()
    }
    if let e = registry.item(id), e.enabled, contexts[id] == nil { await load(e) }
  }

  // MARK: Web view hooks (called by WebViewsService)

  /// Every new web view configuration: attach the controller when there is anything to run.
  func prepare(_ config: WKWebViewConfiguration) {
    guard controller != nil || hasAnything else { return }
    config.webExtensionController = ensureController()
  }

  /// `webkit-extension://` pages (options, popups opened as tabs) need their extension's configuration.
  func configuration(for url: String) -> WKWebViewConfiguration? {
    guard url.hasPrefix("webkit-extension://") else { return nil }
    if controller == nil, hasAnything { ensureController() }
    guard let u = URL(string: url), let ctx = controller?.extensionContext(for: u) else { return nil }
    return ctx.webViewConfiguration
  }

  /// Holds a web view's first load until the extensions are loaded (at most 2 s), so content
  /// blockers and document-start scripts apply to the first page too.
  func whenReady(_ go: @escaping () -> Void) {
    guard controller != nil, !ready else { return go() }
    var done = false
    let once = { if !done { done = true; go() } }
    waiters.append(once)
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { once() }
  }

  // MARK: Install

  var staging: URL { root.appendingPathComponent(".staging", isDirectory: true) }

  func installFile(_ file: URL, request: String) async {
    host.emit("webext.installing", ["request": .string(request), "name": .string(file.lastPathComponent)])
    do {
      let dir = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
      var isDir: ObjCBool = false
      FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir)
      if isDir.boolValue {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: file, to: dir)
      } else {
        try await unpack(try Data(contentsOf: file), to: dir)
      }
      try await finishInstall(dir: dir, source: .local, storeId: nil, request: request, approved: false)
    } catch {
      failed(request, error)
    }
  }

  // thin-host: feature-specific, migrate to plugin
  func installFromStore(_ ref: StoreRef, request: String) async {
    host.emit("webext.installing", ["request": .string(request), "source": .string(ref.source.rawValue), "storeId": .string(ref.id)])
    ui.storeState(pending: ref.id)
    do {
      let (data, storeId) = try await download(ref)
      let dir = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
      try await unpack(data, to: dir)
      try await finishInstall(dir: dir, source: ref.source, storeId: storeId, request: request, approved: false)
    } catch {
      failed(request, error)
    }
    ui.storeState(pending: nil)
  }

  // thin-host: feature-specific, migrate to plugin
  func failed(_ request: String, _ error: Error) {
    let msg = (error as? ExtensionPackageError)?.description ?? error.localizedDescription
    Self.log.error("install failed: \(msg, privacy: .public)")
    host.emit("webext.failed", ["request": .string(request), "error": .string(msg)])
    if msg != "cancelled" { toast("Couldn’t add extension: \(msg)", icon: "sf:exclamationmark.triangle.fill") }
  }

  /// CRX or XPI bytes → an unpacked folder (off the main thread).
  func unpack(_ data: Data, to dir: URL) async throws {
    let staging = self.staging
    try await Task.detached {
      try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
      let zip = staging.appendingPathComponent(UUID().uuidString + ".zip")
      defer { try? FileManager.default.removeItem(at: zip) }
      try ExtensionPackage.stripCRX(data).write(to: zip)
      try ExtensionPackage.unzip(zip, to: dir)
    }.value
  }

  /// Validates a staged folder, asks the user, then moves it into place and loads it.
  func finishInstall(dir: URL, source: ExtensionSource, storeId: String?, request: String, approved: Bool) async throws {
    defer { try? FileManager.default.removeItem(at: dir) }
    let manifest = try ExtensionPackage.readManifest(dir)
    let id = ExtensionPackage.extensionId(source: source, storeId: storeId, manifest: manifest, path: dir.path)
    let staged = try await WKWebExtension(resourceBaseURL: dir)
    let name = staged.displayName ?? manifest.name
    let perms = staged.requestedPermissions.map(\.rawValue).sorted()
    let patterns = staged.requestedPermissionMatchPatterns.map(\.string).sorted()
    let existing = registry.item(id)
    if !approved {
      let iconPath = writeIcon(staged, id: "staged-\(id)")
      let ok = await withCheckedContinuation { cont in
        prompt(title: existing == nil ? "Add “\(name)” to den?" : "Update “\(name)”?", icon: iconPath, lines: ExtensionText.describe(permissions: perms, patterns: patterns),
               unsupported: unsupportedPermissions(staged), confirm: existing == nil ? "Add Extension" : "Update") { cont.resume(returning: $0) }
      }
      try? FileManager.default.removeItem(atPath: iconPath)
      guard ok else { throw ExtensionPackageError("cancelled") }
    }
    // Move into place (replacing an older version of the same id).
    let dest = registry.folder(id)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
    try FileManager.default.moveItem(at: dir, to: dest)
    let now = Date().timeIntervalSince1970 * 1000
    var e = existing ?? InstalledExtension(id: id, name: name, version: manifest.version, source: source.rawValue, dir: dest.path)
    e.name = name
    e.version = manifest.version
    e.storeId = storeId ?? e.storeId
    e.dir = dest.path
    e.availableVersion = nil
    e.granted = Array(Set(e.granted + perms)).sorted()
    e.grantedPatterns = Array(Set(e.grantedPatterns + patterns)).sorted()
    if existing == nil { e.installedAt = now } else { e.updatedAt = now }
    e.checkedAt = now
    registry.upsert(e)
    registry.save()
    if let ext = try? await WKWebExtension(resourceBaseURL: dest) { writeIcon(ext, id: id) }
    let hadController = controller != nil
    ensureController()
    if !hadController {
      // Web views made before the first install have no controller: rebuild the live ones.
      rebuildLiveWebViews()
      await waitReady()
    }
    if e.enabled { await load(e) }
    Self.log.info("installed \(id, privacy: .public) \(e.version, privacy: .public)")
    host.emit("webext.installed", ["request": .string(request), "id": .string(id), "name": .string(name), "update": .bool(existing != nil)])
    if !approved { toast(existing == nil ? "Added \(name)" : "Updated \(name)") }
    changed()
    ui.storeState(pending: nil)
  }

  func waitReady() async {
    if ready { return }
    await withCheckedContinuation { cont in waiters.append { cont.resume() } }
  }

  func unsupportedPermissions(_ ext: WKWebExtension) -> [String] {
    let manifestPerms = ((ext.manifest["permissions"] as? [Any]) ?? []).compactMap { $0 as? String }.filter { !$0.contains("://") && $0 != "<all_urls>" }
    let known = Set(ext.requestedPermissions.union(ext.optionalPermissions).map(\.rawValue))
    return manifestPerms.filter { !known.contains($0) }
  }

  /// Web views created before the controller existed can't get it: re-create the live ones with
  /// their back/forward state, and re-attach the ones on screen.
  func rebuildLiveWebViews() {
    for r in webviews.records.values where r.webView != nil { webviews.rebuild(r) }
    content?.reattach()
  }

  @discardableResult
  func writeIcon(_ ext: WKWebExtension, id: String) -> String {
    let path = registry.iconPath(id)
    guard let img = ext.icon(for: CGSize(width: 64, height: 64)) ?? ext.actionIcon(for: CGSize(width: 64, height: 64)),
          let data = WebViewsService.encode(img, width: 64, jpeg: false) else { return "sf:puzzlepiece.extension" }
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? data.write(to: URL(fileURLWithPath: path))
    ImageCache.shared.forget(path)
    return path
  }

  // thin-host: feature-specific, migrate to plugin
  // MARK: Downloads

  lazy var session: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.httpAdditionalHeaders = ["User-Agent": "den/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0") (Macintosh; +https://github.com/abhishakenp/den)"]
    c.timeoutIntervalForRequest = 60
    return URLSession(configuration: c)
  }()
  var chromeVersion: String?

  /// The current stable Chrome version (the store filters items by `minimum_chrome_version`).
  func currentChromeVersion() async -> String {
    if let v = chromeVersion { return v }
    let u = URL(string: "https://versionhistory.googleapis.com/v1/chrome/platforms/mac/channels/stable/versions?pageSize=1")!
    if let (data, _) = try? await session.data(from: u),
       let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let v = (o["versions"] as? [[String: Any]])?.first?["version"] as? String {
      chromeVersion = v
      return v
    }
    return ExtensionPackage.fallbackChromeVersion
  }

  func fetch(_ url: URL) async throws -> Data {
    let (data, resp) = try await session.data(from: url)
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200, !data.isEmpty else { throw ExtensionPackageError("the store answered \(status)") }
    return data
  }

  /// Downloads a store item: the CRX from Chrome's update service, or the XPI named by the AMO API
  /// (checked against the API's SHA-256). Returns the bytes and the id to store.
  func download(_ ref: StoreRef) async throws -> (Data, String) {
    switch ref.source {
    case .chrome:
      guard ExtensionPackage.isChromeId(ref.id) else { throw ExtensionPackageError("not a Chrome Web Store id") }
      return (try await fetch(ExtensionPackage.crxDownloadURL(id: ref.id, chromeVersion: await currentChromeVersion())), ref.id)
    case .firefox:
      let info = try await amoInfo(ref.id)
      let data = try await fetch(info.fileURL)
      if let h = info.sha256, ExtensionPackage.sha256Hex(data) != h.lowercased() { throw ExtensionPackageError("download doesn’t match the store’s checksum") }
      return (data, info.slug.isEmpty ? ref.id : info.slug)
    default: throw ExtensionPackageError("not a store")
    }
  }

  func amoInfo(_ slug: String) async throws -> ExtensionPackage.AMOVersion {
    guard let info = ExtensionPackage.parseAMO(try await fetch(ExtensionPackage.amoAPIURL(slug))) else { throw ExtensionPackageError("unexpected answer from addons.mozilla.org") }
    return info
  }

  // thin-host: feature-specific, migrate to plugin
  // MARK: Updates

  static let updateScheduleId = "webext.updateCheck"
  /// Once a day, as the store terms research suggests (docs/research/extensions-on-webkit.md).
  static let updateIntervalMs: Int64 = 86_400_000
  var updating = false

  /// Registers the daily check only when a store extension is installed; the first check runs a
  /// minute after launch if the last one is older than a day.
  func scheduleUpdateChecks() {
    guard registry.items.contains(where: { $0.sourceKind == .chrome || $0.sourceKind == .firefox }) else { return }
    _ = host.call("schedule", "interval", ["id": .string(Self.updateScheduleId), "ms": .int(Self.updateIntervalMs), "wake": true])
    let now = Date().timeIntervalSince1970 * 1000
    if registry.items.contains(where: { now - ($0.checkedAt ?? 0) > Double(Self.updateIntervalMs) }) {
      DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.checkUpdates(force: false) }
    }
  }

  func checkUpdates(force: Bool) {
    guard !updating else { return }
    let now = Date().timeIntervalSince1970 * 1000
    let due = registry.items.filter { ($0.sourceKind == .chrome || $0.sourceKind == .firefox) && (force || now - ($0.checkedAt ?? 0) > Double(Self.updateIntervalMs) - 60_000) }
    guard !due.isEmpty else { return host.emit("webext.updates", ["checked": 0, "updated": [], "available": []]) }
    updating = true
    Task {
      var updated: [Value] = [], available: [Value] = []
      var newer: [(InstalledExtension, StoreRef, String)] = []
      let chrome = due.filter { $0.sourceKind == .chrome }
      if !chrome.isEmpty, let data = try? await fetch(ExtensionPackage.updateCheckURL(chrome.map { ($0.id, $0.version) }, chromeVersion: await currentChromeVersion())) {
        let r = ExtensionPackage.parseUpdateCheck(String(decoding: data, as: UTF8.self))
        for e in chrome { if let u = r[e.id], ExtensionPackage.compareVersions(u.version, e.version) > 0 { newer.append((e, StoreRef(source: .chrome, id: e.id), u.version)) } }
      }
      for e in due where e.sourceKind == .firefox {
        if let info = try? await amoInfo(e.storeId ?? ""), ExtensionPackage.compareVersions(info.version, e.version) > 0 { newer.append((e, StoreRef(source: .firefox, id: e.storeId ?? ""), info.version)) }
      }
      for (e, ref, v) in newer {
        do {
          let (data, storeId) = try await download(ref)
          let dir = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
          try await unpack(data, to: dir)
          // Updates install silently only when they ask for nothing new.
          let ext = try await WKWebExtension(resourceBaseURL: dir)
          let more = Set(ext.requestedPermissions.map(\.rawValue)).subtracting(e.granted).union(Set(ext.requestedPermissionMatchPatterns.map(\.string)).subtracting(e.grantedPatterns))
          if more.isEmpty {
            try await finishInstall(dir: dir, source: ref.source, storeId: storeId, request: "update-\(e.id)", approved: true)
            updated.append(.string(e.id))
          } else {
            try? FileManager.default.removeItem(at: dir)
            registry.update(e.id) { $0.availableVersion = v }
            available.append(.string(e.id))
          }
        } catch {
          Self.log.error("update \(e.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
      }
      for e in due { registry.update(e.id) { $0.checkedAt = now } }
      registry.save()
      updating = false
      host.emit("webext.updates", ["checked": .int(Int64(due.count)), "updated": .array(updated), "available": .array(available)])
      changed()
    }
  }

  // MARK: Manage

  func uninstall(_ id: String) -> Value {
    guard let e = registry.item(id) else { return .error("webext: no extension '\(id)'") }
    if ui.popupFor == id { ui.close() }
    if let ctx = contexts.removeValue(forKey: id), let c = controller {
      try? c.unload(ctx)
      c.fetchDataRecord(ofTypes: WKWebExtensionController.allExtensionDataTypes, for: ctx) { rec in
        if let rec { c.removeData(ofTypes: WKWebExtensionController.allExtensionDataTypes, from: [rec]) {} }
      }
    }
    if e.sourceKind != .home { try? FileManager.default.removeItem(at: registry.folder(id)) }
    try? FileManager.default.removeItem(atPath: registry.iconPath(id))
    registry.remove(id)
    registry.save()
    host.emit("webext.uninstalled", ["id": .string(id), "name": .string(e.name)])
    changed()
    return .ok
  }

  func setEnabled(_ id: String, _ on: Bool) -> Value {
    guard let e = registry.item(id) else { return .error("webext: no extension '\(id)'") }
    registry.update(id) { $0.enabled = on }
    registry.save()
    if on {
      ensureController()
      Task { await load(registry.item(id) ?? e); changed() }
    } else if let ctx = contexts.removeValue(forKey: id) {
      if ui.popupFor == id { ui.close() }
      try? controller?.unload(ctx)
    }
    changed()
    return .ok
  }

  func setPinned(_ id: String, _ on: Bool) -> Value {
    guard registry.item(id) != nil else { return .error("webext: no extension '\(id)'") }
    registry.update(id) { $0.pinned = on }
    registry.save()
    changed()
    return .ok
  }

  func setSiteAccess(_ id: String, mode: String, sites: [String]?) -> Value {
    guard ["all", "click", "sites"].contains(mode) else { return .error("webext: mode must be all, click or sites") }
    guard registry.item(id) != nil else { return .error("webext: no extension '\(id)'") }
    registry.update(id) {
      $0.siteAccess = mode
      if let sites { $0.sites = sites.map { $0.lowercased() } }
    }
    registry.save()
    if let ctx = contexts[id], let e = registry.item(id) { applyGrants(ctx, e) }
    changed()
    return .ok
  }

  func allowSite(_ id: String, site: String, allowed: Bool) -> Value {
    guard let e = registry.item(id) else { return .error("webext: no extension '\(id)'") }
    let host = Self.siteHost(site)
    guard !host.isEmpty else { return .error("webext: no site") }
    var sites = e.sites.filter { $0 != host }
    if allowed { sites.append(host) }
    return setSiteAccess(id, mode: e.siteAccess == "all" && allowed ? "all" : (sites.isEmpty && e.siteAccess != "sites" ? e.siteAccess : "sites"), sites: sites)
  }

  // MARK: Actions and popups

  func performAction(_ id: String, anchor: NSRect?) -> Value {
    guard let ctx = contexts[id] else { return .error("webext: '\(id)' is not loaded") }
    let t = selectedTabId().map { tab($0) }
    ui.pendingAnchor = anchor
    ui.pendingPopup = id
    if let t { ctx.userGesturePerformed(in: t) }
    ctx.performAction(for: t)
    return .ok
  }

  func presentPopup(_ action: WKWebExtension.Action, context: WKWebExtensionContext) -> Error? {
    guard let web = action.popupWebView else { return Self.failure("no popup") }
    ui.showPopup(web, action: action, id: context.uniqueIdentifier)
    return nil
  }

  func actionChanged(_ context: WKWebExtensionContext) { ui.refresh() }

  /// Pinned (and all) extensions for the URL pill and the menu.
  // thin-host: feature-specific, migrate to plugin
  func menuItems() -> [ExtensionsUI.Item] {
    let sel: ExtTab? = selectedTabId().map { tab($0) }
    var out: [ExtensionsUI.Item] = []
    for e in registry.items where e.enabled {
      let ctx: WKWebExtensionContext? = contexts[e.id]
      let action: WKWebExtension.Action? = ctx?.action(for: sel)
      var image: NSImage? = action?.icon(for: CGSize(width: 18, height: 18))
      if image == nil { image = ImageCache.shared.file(registry.iconPath(e.id)) }
      var title = e.name
      if let l = action?.label, !l.isEmpty { title = l }
      let enabled = action?.isEnabled ?? (ctx != nil)
      out.append(ExtensionsUI.Item(id: e.id, title: title, image: image, badge: action?.badgeText ?? "", pinned: e.pinned, enabled: enabled, loaded: ctx != nil))
    }
    return out
  }

  // thin-host: feature-specific, migrate to plugin
  // MARK: Permission prompts (Arc dialog)

  struct Prompt {
    let id: String
    let tree: Value
    let done: (Bool) -> Void
  }
  var prompts: [Prompt] = []
  var nextPrompt = 1

  func prompt(_ ctx: WKWebExtensionContext, permissions: [String], patterns: [String], done: @escaping (Bool) -> Void) {
    let lines = ExtensionText.describe(permissions: permissions, patterns: patterns)
    let name = ctx.webExtension.displayName ?? ctx.uniqueIdentifier
    guard !lines.isEmpty else { return done(true) }
    prompt(title: "“\(name)” wants more access", icon: registry.iconPath(ctx.uniqueIdentifier), lines: lines, unsupported: [], confirm: "Allow") { [weak self] ok in
      if ok, let self {
        self.registry.update(ctx.uniqueIdentifier) {
          $0.granted = Array(Set($0.granted + permissions)).sorted()
          $0.grantedPatterns = Array(Set($0.grantedPatterns + patterns.filter { $0.contains("://") || $0 == "<all_urls>" })).sorted()
        }
        self.registry.save()
      }
      done(ok)
    }
  }

  func prompt(title: String, icon: String, lines: [String], unsupported: [String], confirm: String, done: @escaping (Bool) -> Void) {
    var message = lines.isEmpty ? "It needs no special access." : "It can:\n" + lines.map { "•  " + $0 }.joined(separator: "\n")
    if !unsupported.isEmpty { message += "\n\nNot available in WebKit: " + unsupported.joined(separator: ", ") + "." }
    let id = "extensions.prompt:\(nextPrompt)"
    nextPrompt += 1
    let tree: Value = [
      "type": "dialog", "id": .string(id), "icon": .string(FileManager.default.fileExists(atPath: icon) ? icon : "sf:puzzlepiece.extension.fill"),
      "title": .string(title), "message": .string(message),
      "buttons": [["id": "cancel", "title": "Cancel", "style": "cancel"], ["id": "ok", "title": .string(confirm), "style": "default"]],
    ]
    prompts.append(Prompt(id: id, tree: tree, done: done))
    if prompts.count == 1 { _ = host.call("ui", "set", ["slot": "dialog", "tree": tree]) }
  }

  func dialogAction(_ v: Value) {
    guard v.str("action") == "button", let first = prompts.first, v.str("id") == first.id else { return }
    prompts.removeFirst()
    _ = host.call("ui", "set", ["slot": "dialog", "tree": prompts.first?.tree ?? .null])
    first.done(v["value"].str("button") == "ok")
  }

  // thin-host: feature-specific, migrate to plugin
  // MARK: Store pages ("Add to den")

  static let storeWorld = WKContentWorld.world(name: "den-store")
  var storeButtonsLoaded = false
  var _storeButtons = true
  var storeButtons: Bool {
    if !storeButtonsLoaded {
      storeButtonsLoaded = true
      _storeButtons = host.call("storage", "get", ["ns": "_extensions", "key": "storeButtons"]).bool ?? true
    }
    return _storeButtons
  }
  lazy var storeHandler = ScriptMessageProxy { [weak self] msg in self?.storeMessage(msg) }

  func setStoreButtons(_ on: Bool) {
    _storeButtons = on
    storeButtonsLoaded = true
    _ = host.call("storage", "set", ["ns": "_extensions", "key": "storeButtons", "value": .bool(on)])
    for r in webviews.records.values { if let w = r.webView { pageChanged(w) } }
  }

  /// After every load and URL change: on a store page, (re)place the "Add to den" button.
  /// Any other page costs one host comparison.
  func pageChanged(_ w: WKWebView) {
    guard let h = w.url?.host, ExtensionPackage.isStoreHost(h) else { return }
    let ucc = w.configuration.userContentController
    ucc.removeScriptMessageHandler(forName: "denStore", contentWorld: Self.storeWorld)
    guard storeButtons else {
      w.evaluateJavaScript("window.__denStoreRemove && window.__denStoreRemove()", in: nil, in: Self.storeWorld)
      return
    }
    ucc.add(storeHandler, contentWorld: Self.storeWorld, name: "denStore")
    let installed: [Any] = registry.items.compactMap(\.storeId)
    w.callAsyncJavaScript(StoreButton.script, arguments: ["installed": installed, "pending": ui.storePending ?? ""], in: nil, in: Self.storeWorld) { r in
      if case let .failure(e) = r { Self.log.error("store button: \(e.localizedDescription, privacy: .public)") }
    }
  }

  func storeMessage(_ msg: WKScriptMessage) {
    guard let body = msg.body as? [String: Any], let source = body["source"] as? String, let id = body["id"] as? String else { return }
    // Trust only what the page URL says, not the message.
    guard let u = msg.webView?.url, let ref = ExtensionPackage.storeRef(for: u), ref.id == id, ref.source.rawValue == source else { return }
    _ = handle(method: "installFromStore", args: ["source": .string(source), "id": .string(id)])
  }

  // MARK: Pick a file

  // thin-host: feature-specific, migrate to plugin
  func pickFile() {
    let panel = NSOpenPanel()
    panel.title = "Install Extension"
    panel.message = "Choose an unpacked extension folder, or a .crx, .xpi or .zip file."
    panel.prompt = "Install"
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.beginSheetModal(for: window.window) { [weak self] r in
      MainActor.assumeIsolated {
        guard r == .OK, let u = panel.url, let self else { return }
        _ = self.handle(method: "install", args: ["path": .string(u.path)])
      }
    }
  }
}

extension ExtensionsService {
  /// "https://www.example.com/x" or "example.com" -> "example.com".
  nonisolated static func siteHost(_ s: String) -> String {
    let t = s.trimmingCharacters(in: .whitespaces).lowercased()
    let h = URL(string: t.contains("://") ? t : "https://" + t)?.host ?? ""
    return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
  }
}
