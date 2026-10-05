import Cordis
import CordisValue
import Foundation

/// What happens when a plugin crashes while den runs (cordis recovers: the plugin is unloaded, den
/// keeps running, pages and tabs stay as they are). The user is told once per crash, with a toast
/// that offers Reload (load the same file again) and Disable (keep it off: Settings ▸ Plugins turns
/// it back on). den never reloads a crashed plugin by itself.
///
/// A plugin that took den down anyway (a fault cordis can't recover, e.g. heap corruption) is still
/// refused on the next launch by cordis' crash marker (`PluginLoader.crashToast`).
@MainActor
public final class PluginCrashes {
  let runtime: DenRuntime
  /// Crashes this run: id -> report (the last one).
  public private(set) var crashes: [String: CrashReport] = [:]
  /// Loads `file` again (the app routes it through `PluginLoader.load`).
  public var reload: (String, URL) -> Void = { _, _ in }
  /// Keeps plugin `id` off (the app: `PluginConsent.setDisabled`).
  public var disable: (String) -> Void = { _ in }
  public var log: (String) -> Void = { print($0) }

  static let toastPrefix = "_plugins.crash:"

  init(runtime: DenRuntime) {
    self.runtime = runtime
  }

  func start() {
    runtime.plugins.onCrash = { [weak self] r in MainActor.assumeIsolated { self?.crashed(r) } }
    runtime.plugins.on("ui.action") { [weak self] v in
      MainActor.assumeIsolated {
        guard let self, self.runtime.plugins.caller == nil else { return }  // den's own UI only
        self.action(v)
      }
    }
  }

  func crashed(_ r: CrashReport) {
    crashes[r.id] = r
    let name = runtime.plugins.plugin(r.id)?.name ?? r.id
    log("plugins: \(r.id) crashed (\(signalName(r.signal))) and was unloaded; build \(r.buildHash), \(r.path)\(r.cascaded.isEmpty ? "" : "; also stopped: " + r.cascaded.joined(separator: ", "))")
    _ = runtime.call("ui", "set", [
      "slot": "toast",
      "tree": [
        "type": "toast", "id": .string(Self.toastPrefix + r.id), "icon": "sf:exclamationmark.triangle.fill",
        "text": .string("The “\(name)” plugin stopped working"), "duration": 15000, "hold": true,
        "actions": [["id": "reload", "title": "Reload"], ["id": "disable", "title": "Disable"]],
      ],
    ])
  }

  func action(_ v: Value) {
    let id = v.str("id")
    guard v.str("action") == "toast", id.hasPrefix(Self.toastPrefix) else { return }
    let plugin = String(id.dropFirst(Self.toastPrefix.count))
    guard let r = crashes[plugin] else { return }
    switch v["value"].str("button") {
    case "reload":
      log("plugins: reloading \(plugin) after its crash")
      reload(plugin, URL(fileURLWithPath: r.path))
    case "disable":
      log("plugins: \(plugin) disabled after its crash")
      disable(plugin)
    default: break
    }
  }
}
