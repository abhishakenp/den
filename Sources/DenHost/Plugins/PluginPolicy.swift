import Cordis
import CordisValue
import Foundation

/// Who may do what (docs/host-api.md#plugin-permissions).
///
/// - **First-party** plugins (bundled in den.app, den's managed updates of them, `--dev-plugins`)
///   run in den's process (`PluginIsolation.inProcess`) and are trusted with every service. Their
///   `session:`/`net:`/`pages:` grants still come from their sidecar, as before.
/// - **Third-party** plugins (`~/.den/plugins`, `~/Library/Application Support/den/Plugins`) run in a
///   sandboxed helper process (`.process(sandbox: true)`): no files, network or other processes of
///   their own. Every call, listen, emit and provide they make goes through `authorize`, which
///   allows the basic capabilities below and, beyond them, only what the plugin declared and the
///   user granted (`PluginConsent`). Async results (`ai.result`, `net.result`, ...) reach a
///   third-party plugin only for its own requests (`deliver`).
///
/// The rule for a third-party plugin's own things: ids it uses (its services, events, commands,
/// settings, schedules, UI nodes, storage namespaces) are its plugin id or start with `<id>.`.
@MainActor
public final class PluginPolicy {
  /// A permission a third-party plugin can declare, with the words the consent sheet shows.
  public struct Kind: Sendable {
    public let name: String
    public let title: String
    public let icon: String
  }

  /// Plain permissions (no domain). `session:`, `net:` and `pages:` take a domain.
  public static let kinds: [Kind] = [
    Kind(name: "tabs", title: "See and manage your tabs: their titles and addresses, open, switch, navigate and close them", icon: "sf:square.on.square"),
    Kind(name: "ai", title: "Use Apple's on-device model (nothing leaves your Mac)", icon: "sf:sparkles"),
    Kind(name: "clipboard", title: "Copy text to the clipboard", icon: "sf:doc.on.clipboard"),
    Kind(name: "files", title: "Save files and open files you pick", icon: "sf:folder"),
  ]

  /// How one permission reads on the consent sheet and in Settings ▸ Plugins.
  public static func describe(_ permission: String) -> (title: String, icon: String) {
    if let k = kinds.first(where: { $0.name == permission }) { return (k.title, k.icon) }
    guard let (kind, domain) = Permissions.parse(permission) else { return (permission, "sf:questionmark.circle") }
    let site = domain == "*" ? "every website" : domain
    switch kind {
    case "session": return ("Use your signed-in session on \(site): its cookies and site data", "sf:person.badge.key")
    case "net": return (domain == "*" ? "Connect to any website (without your cookies)" : "Connect to \(site) (without your cookies)", "sf:network")
    case "pages": return (domain == "*" ? "Read and change every page you visit" : "Read and change pages on \(site)", "sf:doc.text.magnifyingglass")
    default: return (permission, "sf:questionmark.circle")
    }
  }

  let plugins: PluginHost
  let permissions: Permissions
  /// Async request ids -> the third-party plugin that made the request (results are broadcast).
  private var requests: [String: String] = [:]
  private var requestOrder: [String] = []

  init(plugins: PluginHost, permissions: Permissions) {
    self.plugins = plugins
    self.permissions = permissions
  }

  /// Plugins in a helper process are the third-party ones; everything else runs in den and is trusted.
  public func isThirdParty(_ id: String) -> Bool {
    if case .process = plugins.isolation(of: id) { return true }
    return false
  }

  /// `id` itself, or `<id>.<anything>`: the plugin's own name space.
  nonisolated static func owns(_ plugin: String, _ name: String) -> Bool {
    name == plugin || (name.count > plugin.count + 1 && name.hasPrefix(plugin) && name.dropFirst(plugin.count).first == ".")
  }

  // MARK: - Calls

  enum Need: Equatable {
    case basic  // every plugin
    case permission(String)  // a plain permission (`tabs`, `ai`, `clipboard`, `files`)
    case checked  // the service checks the plugin's domain grants itself (`plugin` is forced to the caller)
    case own(String)  // the argument named here must be the plugin's own name (see `owns`)
    case ownWebview  // a web view whose id the plugin owns; anything else needs `tabs`
    case denied
  }

  /// What a third-party plugin needs to call `service.method`.
  static func need(_ service: String, _ method: String) -> Need {
    switch service {
    case "ui", "keys", "plugins": return .basic
    case "storage": return .own("ns")
    case "schedule": return method == "list" || method == "clock" ? .basic : .own("id")
    case "settings":
      switch method {
      case "register", "unregister", "get", "set": return .own("id")
      case "open", "close", "state", "list": return .basic
      default: return .denied
      }
    case "commands":
      switch method {
      case "register", "unregister": return .own("id")
      case "run": return .own("id")
      case "list", "search": return .basic
      default: return .denied
      }
    case "ai": return method == "availability" ? .basic : .permission("ai")
    case "net", "session": return .checked
    case "webviews":
      switch method {
      case "inject", "eval", "setMenu", "setContentRules": return .checked
      case "create", "navigate", "get", "close", "back", "forward", "reload", "stop": return .ownWebview
      case "list": return .permission("tabs")
      default: return .denied
      }
    case "content": return method == "get" || method == "side" ? .permission("tabs") : .denied
    case "tabs", "spaces":
      switch method {
      case "list", "selected", "open", "select", "close", "navigate", "duplicate", "archive", "get":
        return .permission("tabs")
      default: return .denied
      }
    case "window": return method == "get" ? .basic : .denied
    case "app":
      switch method {
      case "info", "state": return .basic
      case "copy": return .permission("clipboard")
      case "chooseFolder", "openPanel", "savePanel", "reveal", "writeFile": return .permission("files")
      default: return .denied
      }
    case "downloads": return .permission("files")
    default: return .denied
    }
  }

  /// `PluginHost.authorize`. In-process plugins are trusted; third-party ones get `need`.
  public func authorize(_ plugin: String, _ access: PluginAccess, _ args: () -> Value) -> Bool {
    guard isThirdParty(plugin) else { return true }
    switch access {
    case let .call(service, method):
      // Its own service, or another third-party plugin's: allowed (they're all gated alike).
      if Self.owns(plugin, service) || isThirdParty(String(service.split(separator: ".").first ?? "")) { return true }
      switch Self.need(service, method) {
      case .basic, .checked: return true
      case let .own(key):
        // Host services check this again with the real arguments (`check`); plugin services
        // (`commands`) only here.
        return Self.owns(plugin, args()[key].string ?? "")
      case .ownWebview:
        return Self.owns(plugin, args()["id"].string ?? "") || permissions.list(plugin).contains("tabs")
      case let .permission(p): return permissions.list(plugin).contains(p)
      case .denied: return false
      }
    case let .listen(event):
      return Self.mayListen(plugin, event, granted: permissions.list(plugin))
    case let .emit(event):
      return Self.owns(plugin, event)
    case let .provide(service):
      return Self.owns(plugin, service)
    }
  }

  /// Checks a third-party call's arguments against its need, and forces `plugin`/`owner` to the
  /// caller. Returns the arguments to use, or an error. First-party calls pass through untouched.
  enum Checked {
    case ok(Value)
    case denied(String)
  }

  func check(caller: String?, service: String, method: String, args: Value) -> Checked {
    guard let caller, isThirdParty(caller) else { return .ok(args) }
    var args = args
    switch Self.need(service, method) {
    case let .own(key):
      let name = args[key].string ?? ""
      guard Self.owns(caller, name) else { return .denied("\(key) '\(name)' isn't \(caller)'s (use \(caller) or \(caller).<name>)") }
    case .ownWebview:
      let id = args["id"].string ?? ""
      if !Self.owns(caller, id) && !permissions.list(caller).contains("tabs") {
        return .denied("web view '\(id)' isn't \(caller)'s (needs the tabs permission)")
      }
    default: break
    }
    if case .object = args {
      args = args.with("plugin", .string(caller))
      if service == "commands" { args = args.with("owner", .string(caller)) }
    }
    return .ok(args)
  }

  // MARK: - Events

  /// Events that carry one plugin's async results: delivered to a third-party plugin only for its own.
  nonisolated static let results: Set<String> = ["ai.result", "net.result", "session.result", "webviews.evalResult", "webviews.injectResult"]
  /// Events that name the plugin they're for in `plugin`.
  nonisolated static let addressed: Set<String> = ["webviews.message", "webviews.menu", "webviews.contentRules"]
  /// Events that name the thing they're about in `id` (a node, command, setting section, schedule).
  nonisolated static let byID: Set<String> = ["ui.action", "commands.run", "settings.changed", "settings.action", "schedule.fire"]

  nonisolated static func mayListen(_ plugin: String, _ event: String, granted: [String]) -> Bool {
    if owns(plugin, event) || results.contains(event) || addressed.contains(event) || byID.contains(event) { return true }
    if event == "settings.opened" || event.hasPrefix("plugins.") { return true }
    let ns = event.split(separator: ".", maxSplits: 1).first.map(String.init) ?? event
    switch ns {
    case "tabs", "webviews", "spaces", "content", "window": return granted.contains("tabs")
    default: return false
    }
  }

  /// `PluginHost.deliver`: a third-party listener gets results, addressed events and id'd events only
  /// when they're its own.
  public func deliver(_ listener: String, _ event: String, _ payload: () -> Value) -> Bool {
    if Self.results.contains(event) {
      guard isThirdParty(listener) else { return true }
      let v = payload()
      let id = v["id"].string ?? v["request"].string ?? ""
      return requests[id] == listener
    }
    if Self.addressed.contains(event) {
      guard isThirdParty(listener) else { return true }
      return payload()["plugin"].string == listener
    }
    if Self.byID.contains(event) {
      guard isThirdParty(listener) else { return true }
      return Self.owns(listener, payload()["id"].string ?? "")
    }
    return true
  }

  /// Remembers which third-party plugin made an async request (its result's `id` / `request`).
  func noteResult(caller: String?, _ result: Value) {
    guard let caller, isThirdParty(caller) else { return }
    guard let id = result["id"].string ?? result["request"].string, !id.isEmpty else { return }
    if requests[id] == nil { requestOrder.append(id) }
    requests[id] = caller
    if requestOrder.count > 1024 {
      for old in requestOrder.prefix(256) { requests[old] = nil }
      requestOrder.removeFirst(256)
    }
  }
}
