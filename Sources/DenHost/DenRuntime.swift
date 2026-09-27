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
  // Connections, briefing and feed (docs/host-api.md: permissions, session, net, ai, schedule).
  public let permissions = Permissions()
  public let session: SessionService
  public let net: NetService
  public let ai: AIService
  public let schedule: ScheduleService
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
    session = SessionService(host: host, webviews: webviews, permissions: permissions)
    net = NetService(host: host, webviews: webviews, permissions: permissions)
    ai = AIService(host: host)
    schedule = ScheduleService(host: host, storage: storage)
    Self.permissionsByHost[ObjectIdentifier(plugins)] = permissions
    windowService.ui = ui
    windowService.attach(webviews: webviews, host: host)
    for s: HostService in [windowService, webviews, content, ui, keys, storage, app, SuggestService(host: host), session, net, ai, schedule] {
      host.provide(s)
      plugins.provide(s.name) { [unowned s] method, args in s.handle(method: method, args: args) }
    }
    plugins.provide("plugins") { [weak plugins] method, args in
      guard let plugins else { return ["error": "plugins: host is gone"] }
      return Self.pluginsService(plugins, method, args)
    }
    host.forward = { [weak plugins] e, v in plugins?.emit(e, v) }
    host.externalListeners = { [weak plugins] e in plugins?.hasListeners(e) ?? false }
    window.emit = { [weak host] e, v in host?.emit(e, v) }
    window.onCloseRequest = { [weak app] in app?.shouldClose() ?? true }
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
