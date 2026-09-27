import AppKit
import CordisValue

/// Wires the host services together around one Arc-style window.
/// When cordis `PluginHost` lands, each service's `handle` is registered with
/// `PluginHost.provide(name, handle)` and `ServiceHost` goes away.
@MainActor
public final class DenRuntime {
  public let host = ServiceHost()
  public let window = DenWindowController()
  public let windowService: WindowService
  public let webviews: WebViewsService
  public let content: ContentService
  public let ui: UIService
  public let keys: KeysService
  public let storage: StorageService
  public let app: AppService

  public init(storageRoot: URL = StorageService.defaultRoot) {
    windowService = WindowService(window: window)
    webviews = WebViewsService(host: host)
    content = ContentService(host: host, webviews: webviews, window: window)
    ui = UIService(host: host, window: window, content: content)
    keys = KeysService(host: host)
    storage = StorageService(root: storageRoot)
    app = AppService(host: host, window: window)
    windowService.ui = ui
    for s: HostService in [windowService, webviews, content, ui, keys, storage, app] { host.provide(s) }
    window.emit = { [weak host] e, v in host?.emit(e, v) }
    window.onCloseRequest = { [weak app] in app?.shouldClose() ?? true }
  }

  /// Convenience used by the demo driver and tests: `call("webviews", "create", [...])`.
  @discardableResult
  public func call(_ service: String, _ method: String, _ args: Value = .null) -> Value { host.call(service, method, args) }
}
