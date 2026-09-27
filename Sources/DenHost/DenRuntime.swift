import AppKit
import Cordis
import CordisValue

@MainActor
public final class DenRuntime {
  public let host = ServiceHost()
  /// The cordis plugin host. Every host service is provided here, and every host event is
  /// re-emitted on its bus, so plugins reach the host exactly like they reach each other.
  public let plugins: PluginHost
  public let window = DenWindowController()
  public let windowService: WindowService
  public let webviews: WebViewsService
  public let content: ContentService
  public let ui: UIService
  public let keys: KeysService
  public let storage: StorageService
  public let app: AppService
  public let media: MediaService
  // Connections, briefing and feed (docs/host-api.md: permissions, session, net, ai, schedule).
  public let permissions = Permissions()
  public let session: SessionService
  public let net: NetService
  public let ai: AIService
  public let schedule: ScheduleService
  /// Per-site user stylesheets and appearance (the `darkmode` plugin), and den's password vault.
  public let pageStyle: PageStyleService
  public let vault: VaultService
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
  /// Lets `PluginLoader` (built by the app from `plugins` alone) grant sidecar permissions.
  static var permissionsByHost: [ObjectIdentifier: Permissions] = [:]
  static func permissions(for plugins: PluginHost) -> Permissions? { permissionsByHost[ObjectIdentifier(plugins)] }

  /// `crashMarkerPath: nil` skips cordis' crash signal handlers (tests); the app passes
  /// `PluginHost.defaultCrashMarkerPath`.
  public init(storageRoot: URL = StorageService.defaultRoot, crashMarkerPath: String? = nil, pluginCache: String? = nil) {
    plugins = PluginHost(crashMarkerPath: crashMarkerPath, cacheDirectory: pluginCache)
    windowService = WindowService(window: window)
    webviews = WebViewsService(host: host)
    content = ContentService(host: host, webviews: webviews, window: window)
    ui = UIService(host: host, window: window, content: content)
    keys = KeysService(host: host)
    storage = StorageService(root: storageRoot)
    app = AppService(host: host, window: window)
    media = MediaService(host: host, webviews: webviews, content: content, window: window, storage: storage)
    session = SessionService(host: host, webviews: webviews, permissions: permissions)
    net = NetService(host: host, webviews: webviews, permissions: permissions)
    ai = AIService(host: host)
    schedule = ScheduleService(host: host, storage: storage)
    pageStyle = PageStyleService(host: host, webviews: webviews)
    vault = VaultService(host: host, webviews: webviews)
    // The real profile keeps extensions next to its storage and a persistent controller; any other
    // storage root (tests, --demo, --storage) gets its own folder and a non-persistent controller.
    let isDefault = storageRoot.standardizedFileURL == StorageService.defaultRoot.standardizedFileURL
    extensions = ExtensionsService(host: host, webviews: webviews, window: window,
                                   root: isDefault ? storageRoot.deletingLastPathComponent().appendingPathComponent("Extensions", isDirectory: true)
                                     : storageRoot.appendingPathComponent("extensions", isDirectory: true),
                                   persistent: isDefault)
    extensions.content = content
    settings = SettingsService(host: host, storage: storage)
    speech = SpeechService(host: host)
    translate = TranslateService(host: host)
    translate.window = { [weak window] in window?.window }
    Self.permissionsByHost[ObjectIdentifier(plugins)] = permissions
    // `webviews.eval` reads a live page only for a plugin with `session:<that page's host>`.
    webviews.allowScript = { [permissions] plugin, host in MainActor.assumeIsolated { permissions.allowsSession(plugin, host: host) } }
    // `webviews.inject`: a plugin's own scripts (from its resource folder) with `pages:` permission.
    webviews.allowPages = { [permissions] plugin, host in MainActor.assumeIsolated { permissions.allowsPages(plugin, host: host) } }
    webviews.resource = { [permissions] plugin, name in MainActor.assumeIsolated { permissions.resource(plugin, name) } }
    windowService.ui = ui
    webviews.prompts = WebPrompts(window: window) { [weak ui] in ui?.renderer.palette }
    windowService.attach(webviews: webviews, host: host)
    // Page actions (zoom, find, print, inspector, view source): state only, UI built on first use.
    let pa = PageActions(host: host, webviews: webviews, content: content, window: window, storage: storage)
    pa.palette = { [weak ui] in ui?.renderer.palette }
    pa.searchEngine = { [weak plugins] in
      guard let e = plugins?.call("commands", "engines", .null).array?.first, let u = e["url"].string else { return nil }
      return (e.str("name", "Google"), u)
    }
    webviews.pageActions = pa
    for s: HostService in [windowService, webviews, content, ui, keys, storage, app, SuggestService(host: host), session, net, ai, schedule, pageStyle, vault, extensions, settings, media, speech, translate] {
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
    window.emit = { [weak host] e, v in host?.emit(e, v) }
    window.onCloseRequest = { [weak app] in app?.shouldClose() ?? true }
    settings.dark = { [unowned window] in window.isDark }
    settings.palette = { [unowned ui] in ui.renderer.palette }
    ui.onPalette = { [weak settings] _ in settings?.window?.applyAppearance() }
    GeneralSettings.install(self)
    MenuActions.install(self)
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
