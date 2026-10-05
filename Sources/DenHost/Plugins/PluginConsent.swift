import Cordis
import CordisValue
import Foundation

/// The user's say over third-party plugins (`~/.den/plugins`, `~/Library/Application Support/den/Plugins`):
///
/// - Before one loads for the first time (or after it declares something new), den shows what it
///   asks for in an Allow / Don't Allow sheet; each permission can be unticked. Nothing loads until
///   the user answers. A plugin that declares nothing sensitive loads without asking.
/// - The answer is remembered (storage ns `_plugins`, key `grants`) and can be changed in
///   Settings ▸ Plugins: revoke (it unloads and asks again next time), disable, reload.
/// - A third-party plugin runs in a sandboxed helper process and gets only basic capabilities plus
///   what was allowed (`PluginPolicy`). First-party plugins (den.app, den's updates, `--dev-plugins`)
///   are den's own and never ask.
@MainActor
public final class PluginConsent {
  public struct Grant: Equatable {
    public var declared: [String]
    public var granted: [String]
    public var denied: Bool
  }

  public enum Admission: Equatable {
    case load(PluginIsolation)
    /// The sheet is up (or queued); `retry` runs after Allow.
    case wait
    case refuse(String)
  }

  let runtime: DenRuntime
  /// Folders whose plugins are third-party (set by the app from `DenHome`; tests set their own).
  public var thirdPartyDirectories: [URL] = [PluginLoader.userDirectory]
  /// Plugin ids the user turned off in Settings ▸ Plugins or a crash toast (on top of
  /// `[plugins] disabled` in config.toml).
  public var disabled: Set<String> {
    load()
    return _disabled
  }
  private var _disabled: Set<String> = []
  /// Called when a decision means a plugin should be (re)loaded or unloaded now: id, its file.
  public var reload: (String, URL) -> Void = { _, _ in }
  /// Where decisions are logged (the app: `~/.den/logs/plugins.log`).
  public var log: (String) -> Void = { print($0) }

  private var grants: [String: Grant] = [:]
  private var loaded = false
  private struct Ask {
    let id: String
    let dylib: URL
    let declared: [String]
    let retry: () -> Void
  }
  private var queue: [Ask] = []
  private var asking: String?
  private var nextSheet = 1
  /// Third-party plugin files seen this run: id -> file (Settings lists them).
  public private(set) var files: [String: URL] = [:]

  static let dialogPrefix = "_plugins.consent:"

  init(runtime: DenRuntime) {
    self.runtime = runtime
  }

  /// Hooks the sheet's buttons. Called once by `DenRuntime`.
  func start() {
    runtime.plugins.on("ui.action") { [weak self] v in
      MainActor.assumeIsolated {
        // Only den's own UI answers (a plugin emitting a fake click has a caller).
        guard let self, self.runtime.plugins.caller == nil else { return }
        self.action(v)
      }
    }
  }

  // MARK: - Where a plugin comes from

  public func isThirdParty(_ dylib: URL) -> Bool {
    let dir = dylib.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
    return thirdPartyDirectories.contains { $0.standardizedFileURL.resolvingSymlinksInPath().path == dir }
  }

  nonisolated static func id(of dylib: URL) -> String { dylib.deletingPathExtension().lastPathComponent }

  // MARK: - Admission

  /// Decides whether `dylib` may load now and how. Third-party plugins without a decision for
  /// what they declare get the sheet (`.wait`); `retry` runs after Allow.
  public func admit(_ dylib: URL, retry: @escaping () -> Void) -> Admission {
    load()
    let id = Self.id(of: dylib)
    if disabled.contains(id) { return .refuse("turned off in Settings ▸ Plugins") }
    guard isThirdParty(dylib) else { return .load(.inProcess) }
    files[id] = dylib
    let declared = Permissions.declared(dylib)
    let sandboxed = PluginIsolation.process(sandbox: true)
    if declared.isEmpty { return .load(sandboxed) }
    if let g = grants[id], Set(declared).isSubset(of: Set(g.declared)) {
      return g.denied ? .refuse("you didn't allow it") : .load(sandboxed)
    }
    ask(Ask(id: id, dylib: dylib, declared: declared, retry: retry))
    return .wait
  }

  /// What `id` may use: the declared permissions the user allowed (third-party only).
  public func granted(_ id: String, dylib: URL) -> [String] {
    load()
    let declared = Permissions.declared(dylib)
    guard let g = grants[id], !g.denied else { return [] }
    return declared.filter { g.granted.contains($0) }
  }

  public func grant(_ id: String) -> Grant? {
    load()
    return grants[id]
  }

  // MARK: - The sheet

  private func ask(_ a: Ask) {
    if asking == a.id || queue.contains(where: { $0.id == a.id }) { return }
    queue.append(a)
    if asking == nil { showNext() }
  }

  private func showNext() {
    guard let a = queue.first else {
      asking = nil
      return
    }
    asking = a.id
    let name = a.id
    let choices: [Value] = a.declared.map { p in
      let d = PluginPolicy.describe(p)
      return ["id": .string(p), "title": .string(d.title), "subtitle": .string(p), "icon": .string(d.icon), "selected": true]
    }
    let tree: Value = [
      "type": "dialog", "id": .string(Self.dialogPrefix + String(nextSheet)), "icon": "sf:puzzlepiece.extension.fill",
      "title": .string("Allow the “\(name)” plugin?"),
      "message": .string("It isn't part of den: it comes from \(Self.tilde(a.dylib.path)). It runs in its own sandbox and can only use what you allow here. You can change this in Settings ▸ Plugins."),
      "choices": .array(choices), "multiple": true,
      "buttons": [["id": "deny", "title": "Don't Allow", "style": "cancel"], ["id": "allow", "title": "Allow", "style": "default"]],
    ]
    nextSheet += 1
    _ = runtime.call("ui", "set", ["slot": "dialog", "tree": tree])
  }

  private func action(_ v: Value) {
    guard v.str("action") == "button", v.str("id").hasPrefix(Self.dialogPrefix), let a = queue.first else { return }
    queue.removeFirst()
    _ = runtime.call("ui", "set", ["slot": "dialog", "tree": .null])
    let allow = v["value"].str("button") == "allow"
    // Rows the user unticked are left out; without a `choices` answer, everything declared.
    let ticked = v["value"]["choices"].array?.compactMap(\.string)
    let granted = allow ? a.declared.filter { ticked?.contains($0) ?? true } : []
    decide(a.id, Grant(declared: a.declared, granted: granted, denied: !allow))
    log("plugins: \(a.id) \(allow ? "allowed" : "not allowed"): \(granted.joined(separator: ", "))")
    if allow { a.retry() }
    showNext()
  }

  // MARK: - Decisions

  /// Records a decision (the sheet, Settings ▸ Plugins, tests) and saves it.
  public func decide(_ id: String, _ g: Grant) {
    load()
    grants[id] = g
    save()
    // A loaded plugin gets the new grants at once.
    if !g.denied, let file = files[id], runtime.plugins.plugin(id)?.state == .active {
      runtime.permissions.revoke(id)
      runtime.permissions.loadSidecar(plugin: id, dylib: file, only: g.granted)
    }
  }

  /// Settings ▸ Plugins: forget the decision and unload it; it asks again the next time it loads.
  public func revoke(_ id: String) {
    load()
    grants[id] = nil
    save()
    runtime.permissions.revoke(id)
    if runtime.plugins.plugin(id) != nil { _ = try? runtime.plugins.unload(id) }
  }

  public func setDisabled(_ id: String, _ off: Bool) {
    load()
    if off { _disabled.insert(id) } else { _disabled.remove(id) }
    save()
    if off {
      if runtime.plugins.plugin(id) != nil { _ = try? runtime.plugins.unload(id) }
    } else if let f = files[id] ?? runtime.crashes.crashes[id].map({ URL(fileURLWithPath: $0.path) }) {
      reload(id, f)
    }
  }

  private func load() {
    guard !loaded else { return }
    loaded = true
    let v = runtime.storage.handle(method: "get", args: ["ns": "_plugins", "key": "grants"])
    for (id, g) in v.object ?? [] {
      grants[id] = Grant(
        declared: g["declared"].array?.compactMap(\.string) ?? [], granted: g["granted"].array?.compactMap(\.string) ?? [],
        denied: g["denied"].bool ?? false)
    }
    _disabled = Set(runtime.storage.handle(method: "get", args: ["ns": "_plugins", "key": "disabled"]).array?.compactMap(\.string) ?? [])
  }

  private func save() {
    let obj: Value = .object(grants.keys.sorted().map { id in
      let g = grants[id]!
      return (id, ["declared": .array(g.declared.map { .string($0) }), "granted": .array(g.granted.map { .string($0) }), "denied": .bool(g.denied)])
    })
    _ = runtime.storage.handle(method: "set", args: ["ns": "_plugins", "key": "grants", "value": obj])
    _ = runtime.storage.handle(method: "set", args: ["ns": "_plugins", "key": "disabled", "value": .array(_disabled.sorted().map { .string($0) })])
  }

  nonisolated static func tilde(_ p: String) -> String {
    let home = NSHomeDirectory()
    return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
  }
}
