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
    windowService.ui = ui
    for s: HostService in [windowService, webviews, content, ui, keys, storage, app] {
      host.provide(s)
      plugins.provide(s.name) { [unowned s] method, args in s.handle(method: method, args: args) }
    }
    host.forward = { [unowned plugins] e, v in plugins.emit(e, v) }
    host.externalListeners = { [unowned plugins] e in plugins.hasListeners(e) }
    window.emit = { [weak host] e, v in host?.emit(e, v) }
    window.onCloseRequest = { [weak app] in app?.shouldClose() ?? true }
  }

  /// Calls a host or plugin service.
  @discardableResult
  public func call(_ service: String, _ method: String, _ args: Value = .null) -> Value { plugins.call(service, method, args) }
}
