import AppKit
import Cordis
import CordisValue

@MainActor
public final class DenRuntime {
  public let host = ServiceHost()
  /// The cordis plugin host. Every host service is provided here, and every host event is
  /// re-emitted on its bus, so plugins reach the host exactly like they reach each other.
  public let plugins: PluginHost
  /// Every browser window (⌘N, ⇧⌘N); `window` is the active one.
  public let windows = WindowSet()
  public var window: DenWindowController { windows.active }
  public let windowService: WindowService
  public let webviews: WebViewsService
  public let content: ContentService
  public let ui: UIService
  public let keys: KeysService
  public let storage: StorageService
  public let app: AppService
  public let media: MediaService
  /// Control Center's Now Playing and the media keys (the `media` plugin drives it).
  public let nowPlaying: NowPlayingService
  // Connections, briefing and feed (docs/host-api.md: permissions, session, net, ai, schedule).
  public let permissions = Permissions()
  public let session: SessionService
  public let net: NetService
  public let ai: AIService
  public let schedule: ScheduleService
  /// Per-site user stylesheets and appearance (the `darkmode` plugin), and den's password vault.
  public let pageStyle: PageStyleService
  /// Per-site content rule lists, page preferences, HTTPS-first and the navigation guard (`shields`).
  public let sitePolicy: SitePolicyService
  public let vault: VaultService
  /// Files pages hand over (WKDownload), and the upload picker's recent files.
  public let downloads: DownloadsService
  /// Chrome/Firefox extensions (docs/host-api.md#extensions). Nothing WebKit-side exists until
  /// something is installed.
  public let extensions: ExtensionsService
  /// den's Settings window (⌘,) and the sections plugins contribute to it.
  public let settings: SettingsService
  /// The cordis registration of each host service (tests can withdraw one to stand in a fake).
  public private(set) var serviceHandles: [String: CordisHandle] = [:]
  // On-device text to speech and translation (the `pagetools` plugin's reader and translation).
  public let speech: SpeechService
  public let translate: TranslateService
  /// den's items in the system's Spotlight, and Handoff of the page in front (the `continuity`
  /// plugin decides what goes there).
  public let spotlight: SpotlightService
  public let handoff: HandoffService
  /// Websites' notifications, bridged to Notification Center while their tab is open.
  public let notifications: PageNotifications
  /// Lets `PluginLoader` (built by the app from `plugins` alone) grant sidecar permissions.
  static var permissionsByHost: [ObjectIdentifier: Permissions] = [:]
  static func permissions(for plugins: PluginHost) -> Permissions? { permissionsByHost[ObjectIdentifier(plugins)] }

  /// `crashMarkerPath: nil` skips cordis' crash signal handlers (tests); the app passes
  /// `PluginHost.defaultCrashMarkerPath`.
  public init(storageRoot: URL = StorageService.defaultRoot, crashMarkerPath: String? = nil, pluginCache: String? = nil) {
    plugins = PluginHost(crashMarkerPath: crashMarkerPath, cacheDirectory: pluginCache)
    windowService = WindowService(windows: windows)
    webviews = WebViewsService(host: host)
    content = ContentService(host: host, webviews: webviews, windows: windows)
    ui = UIService(host: host, windows: windows, content: content)
    keys = KeysService(host: host)
    storage = StorageService(root: storageRoot)
    app = AppService(host: host, windows: windows)
    media = MediaService(host: host, webviews: webviews, content: content, windows: windows, storage: storage)
    nowPlaying = NowPlayingService(host: host)
    session = SessionService(host: host, webviews: webviews, permissions: permissions)
    net = NetService(host: host, webviews: webviews, permissions: permissions)
    ai = AIService(host: host)
    schedule = ScheduleService(host: host, storage: storage)
    pageStyle = PageStyleService(host: host, webviews: webviews)
    // Compiled rule lists live next to storage for the real profile, inside any other root.
    sitePolicy = SitePolicyService(host: host, webviews: webviews,
                                   storeRoot: storageRoot.standardizedFileURL == StorageService.defaultRoot.standardizedFileURL
                                     ? storageRoot.deletingLastPathComponent().appendingPathComponent("ContentRules", isDirectory: true)
                                     : storageRoot.appendingPathComponent("contentrules", isDirectory: true))
    // Downloaded filter data goes next to any storage root but the real one (tests, --storage).
    if storageRoot.standardizedFileURL != StorageService.defaultRoot.standardizedFileURL {
      sitePolicy.resourceRoots = [storageRoot.appendingPathComponent("updates/lists", isDirectory: true)]
    }
    vault = VaultService(host: host, webviews: webviews)
    downloads = DownloadsService(host: host, storage: storage)
    webviews.downloads = downloads
    downloads.webView = { [weak webviews] preferred in
      guard let webviews else { return nil }
      // The fallback is never a private page's view: its ephemeral session must not carry a
      // download that isn't its own.
      return webviews.record(preferred)?.webView ?? webviews.records.values.lazy.filter { !$0.isPrivate }.compactMap(\.webView).first
    }
    downloads.isPrivateWebview = { [weak webviews] id in webviews?.record(id)?.isPrivate ?? id.hasPrefix("ptab-") }
    webviews.uploadPicker = UploadPicker(downloads: downloads)
    // No platform passkeys without Apple's entitlement: pages are told so (Passkeys.swift).
    webviews.configureHooks.append { _, c in Passkeys.configure(c) }
    // The real profile keeps extensions next to its storage and a persistent controller; any other
    // storage root (tests, --demo, --storage) gets its own folder and a non-persistent controller.
    let isDefault = storageRoot.standardizedFileURL == StorageService.defaultRoot.standardizedFileURL
    extensions = ExtensionsService(host: host, webviews: webviews, window: windows.main,
                                   root: isDefault ? storageRoot.deletingLastPathComponent().appendingPathComponent("Extensions", isDirectory: true)
                                     : storageRoot.appendingPathComponent("extensions", isDirectory: true),
                                   persistent: isDefault)
    extensions.content = content
    extensions.attach(windows: windows)
    settings = SettingsService(host: host, storage: storage)
    speech = SpeechService(host: host)
    translate = TranslateService(host: host)
    // The real profile's Spotlight items live in den's index; any other storage root (tests,
    // --demo) gets one of its own, so it never touches them.
    spotlight = SpotlightService(host: host, indexName: isDefault ? "den" : "den-" + String(UInt(bitPattern: storageRoot.standardizedFileURL.path.hashValue), radix: 36))
    handoff = HandoffService(host: host)
    notifications = PageNotifications(host: host, storage: storage)
    notifications.webviews = webviews
    webviews.configureHooks.append { [weak notifications] r, c in
      guard !r.url.hasPrefix("webkit-extension:") else { return }
      notifications?.configure(r, c)
    }
    handoff.open = { [weak app] urls in app?.open(urls, source: "handoff") }
    translate.window = { [weak windows] in windows?.active.window }
    Self.permissionsByHost[ObjectIdentifier(plugins)] = permissions
    // `webviews.eval` reads a live page only for a plugin with `session:<that page's host>`.
    webviews.allowScript = { [permissions] plugin, host in MainActor.assumeIsolated { permissions.allowsSession(plugin, host: host) } }
    // `webviews.inject`: a plugin's own scripts (from its resource folder) with `pages:` permission.
    webviews.allowPages = { [permissions] plugin, host in MainActor.assumeIsolated { permissions.allowsPages(plugin, host: host) } }
    webviews.resource = { [permissions] plugin, name in MainActor.assumeIsolated { permissions.resource(plugin, name) } }
    windowService.ui = ui
    webviews.prompts = WebPrompts(windows: windows) { [weak ui] in ui?.renderer.palette }
    windowService.attach(webviews: webviews, host: host)
    // Page actions (zoom, find, print, inspector, view source): state only, UI built on first use.
    let pa = PageActions(host: host, webviews: webviews, content: content, windows: windows, storage: storage)
    pa.palette = { [weak ui] in ui?.renderer.palette }
    pa.searchEngine = { [weak plugins] in
      guard let e = plugins?.call("commands", "engines", .null).array?.first, let u = e["url"].string else { return nil }
      return (e.str("name", "Google"), u)
    }
    webviews.pageActions = pa
    webviews.cleanLink = { [weak plugins] url in plugins?.call("shields", "clean", ["url": .string(url)])["url"].string ?? url }
    sitePolicy.prompts = webviews.prompts
    sitePolicy.notifications = notifications
    // Shields' permission lists follow every remembered answer.
    webviews.prompts?.onDecision = { [weak host] in host?.emit("sitepolicy.permissionsChanged") }
    sitePolicy.colors = { [weak webviews] in webviews?.prompts?.errorPageColors }
    sitePolicy.call = { [weak plugins] s, m, a in plugins?.call(s, m, a) ?? .error("no plugin host") }
    sitePolicy.resource = { [permissions] p, f in permissions.resource(p, f) }
    for s: HostService in [windowService, webviews, content, ui, keys, storage, app, SuggestService(host: host), session, net, ai, schedule, pageStyle, sitePolicy, vault, downloads, extensions, settings, media, nowPlaying, speech, translate, spotlight, handoff, notifications] {
      host.provide(s)
      serviceHandles[s.name] = plugins.provide(s.name) { [unowned s] method, args in s.handle(method: method, args: args) }
    }
    plugins.provide("plugins") { [weak plugins] method, args in
      guard let plugins else { return ["error": "plugins: host is gone"] }
      return Self.pluginsService(plugins, method, args)
    }
    extensions.call = { [weak plugins] s, m, a in plugins?.call(s, m, a) ?? .error("no plugin host") }
    extensions.subscribe = { [weak plugins] e, h in _ = plugins?.on(e, h) }
    extensions.start()
    host.forward = { [weak plugins] e, v in plugins?.emit(e, v) }
    host.externalListeners = { [weak plugins] e in plugins?.hasListeners(e) ?? false }
    windows.emit = { [weak host] e, v in host?.emit(e, v) }
    windows.onCloseRequest = { [weak app] in app?.shouldClose() ?? true }
    // A closed private window's ephemeral data store goes with it.
    windows.onRemove.append { [weak webviews] w in if w.isPrivate { webviews?.releaseStore("private:" + w.id) } }
    windowService.content = content
    app.anchorView = { [weak ui] id in ui?.nodeView(id) }
    settings.dark = { [unowned windows] in windows.active.isDark }
    settings.palette = { [unowned ui] in ui.renderer.palette }
    ui.onPalette = { [weak settings] _ in settings?.window?.applyAppearance() }
    GeneralSettings.install(self)
    MenuActions.install(self)
    Self.onCreate?(self)
  }

  /// The `plugins` service: lets a plugin see which services, plugins and listeners exist, so it
  /// can hide features whose provider isn't loaded (see docs/host-api.md).
  static func pluginsService(_ plugins: PluginHost, _ method: String, _ args: Value) -> Value {
    switch method {
    case "get":
      let list = plugins.plugins.map { p -> Value in ["id": .string(p.id), "active": .bool(p.state == .active)] }
      return ["services": .array(plugins.serviceNames.map { .string($0) }), "plugins": .array(list)]
    case "listening":
      return ["listening": .bool(plugins.hasListeners(args.str("event")))]
    default:
      return ["error": .string("plugins: unknown method \(method)")]
    }
  }

  /// Calls a host or plugin service.
  @discardableResult
  public func call(_ service: String, _ method: String, _ args: Value = .null) -> Value { plugins.call(service, method, args) }
}
