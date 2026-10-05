import Cordis
import CordisValue
import Foundation

/// A plugin's sidecar, `<id>.json` next to its dylib (bundled: from `Plugins/<id>/plugin.json`;
/// `~/.den` source plugins: `~/.den/plugins/<id>/plugin.json`, copied next to their build).
///
/// ```json
/// {
///   "permissions": ["net:example.com"],
///   "launch": "lazy",
///   "activation": {
///     "services": ["extensions"],
///     "events": ["webext.openPage", {"event": "schedule.fire", "match": {"id": "briefing.*"}}],
///     "commands": [{"id": "extensions.get", "title": "Get Extensions", "icon": "sf:plus.circle", "keywords": ["store"]}],
///     "keys": [{"chord": "cmd+shift+b", "event": "briefing.key.open", "title": "Daily Briefing", "menu": "View"}],
///     "settings": [{"id": "briefing", "title": "Briefing", "icon": "sf:sun.horizon", "controls": []}]
///   }
/// }
/// ```
///
/// `launch`: `firstFrame` (loads before the first window: spaces, tabs), `deferred` (the default:
/// loads right after it), `lazy` (loads on the first trigger below, maybe never).
///
/// `activation` is what den registers for a lazy plugin without loading it. Each entry is also a
/// trigger: the plugin loads, then the trigger is passed on, so the user sees no difference.
/// - `services`: a stub provides each name; the first call loads the plugin and is forwarded.
/// - `events`: a name, or `{event, match}` where every `match` key must equal the payload's
///   (a trailing `*` matches a prefix). The event is emitted again once the plugin is loaded
///   (other listeners hear it twice, so wake on events whose listeners filter by id).
/// - `commands`: `commands.register` arguments (`owner` is set to the plugin id). They're listed in
///   the command bar while the plugin isn't loaded; `commands.run` with one of their ids wakes it.
/// - `keys`: `keys.bind` arguments: the chord and its menu item exist from launch; the bound event
///   wakes it.
/// - `settings`: `settings.register` arguments: the section shows in Settings (values are stored
///   by the host); opening the section, changing a value or pressing one of its buttons wakes it.
/// Once loaded, the plugin registers the same things itself (same ids, so they're replaced).
public struct PluginSidecar: Equatable {
  public enum Launch: String { case firstFrame, deferred, lazy }

  public struct Trigger: Equatable {
    public var event: String
    public var match: [String: String] = [:]

    public func matches(_ payload: Value) -> Bool {
      match.allSatisfy { k, want in
        let have = payload[k].string ?? ""
        return want.hasSuffix("*") ? have.hasPrefix(String(want.dropLast())) : have == want
      }
    }
  }

  public var launch: Launch = .deferred
  public var services: [String] = []
  public var events: [Trigger] = []
  public var commands: [Value] = []
  public var keys: [Value] = []
  public var settings: [Value] = []

  public init(launch: Launch = .deferred) { self.launch = launch }

  /// The sidecar of `dylib` (`<dylib without extension>.json`); nil when there is none or it isn't JSON.
  public static func read(_ dylib: URL) -> PluginSidecar? {
    let url = dylib.deletingPathExtension().appendingPathExtension("json")
    guard let data = try? Data(contentsOf: url), let v = ValueJSON.parse(data), v.object != nil else { return nil }
    return parse(v)
  }

  public static func parse(_ v: Value) -> PluginSidecar {
    var s = PluginSidecar(launch: Launch(rawValue: v.str("launch")) ?? .deferred)
    let a = v["activation"]
    s.services = a.list("services").compactMap(\.string).filter { !$0.isEmpty }
    s.events = a.list("events").compactMap { e in
      if let name = e.string { return name.isEmpty ? nil : Trigger(event: name) }
      let name = e.str("event")
      guard !name.isEmpty else { return nil }
      var match: [String: String] = [:]
      for (k, m) in e["match"].object ?? [] { if let s = m.string { match[k] = s } }
      return Trigger(event: name, match: match)
    }
    s.commands = a.list("commands").filter { !$0.str("id").isEmpty && !$0.str("title").isEmpty }
    s.keys = a.list("keys").filter { !$0.str("chord").isEmpty && !$0.str("event").isEmpty }
    s.settings = a.list("settings").filter { !$0.str("id").isEmpty }
    return s
  }

  /// Every event that wakes the plugin: its own `events`, `commands.run` for each command, each
  /// key's event, and the Settings events of each section.
  public var triggers: [Trigger] {
    var out = events
    for c in commands { out.append(Trigger(event: "commands.run", match: ["id": c.str("id")])) }
    for k in keys { out.append(Trigger(event: k.str("event"))) }
    for s in settings {
      let id = s.str("id")
      out.append(Trigger(event: "settings.opened", match: ["section": s.str("section", id)]))
      out.append(Trigger(event: "settings.changed", match: ["id": id]))
      out.append(Trigger(event: "settings.action", match: ["id": id]))
    }
    return out
  }

  /// True when nothing would ever load the plugin: a lazy sidecar must declare at least one trigger.
  public var isUnreachable: Bool { services.isEmpty && triggers.isEmpty }
}

/// What `PluginLoader` holds for lazy plugins that aren't loaded (yet).
struct LazyRegistry {
  struct Armed {
    let url: URL
    let id: String
    let sidecar: PluginSidecar
    var listeners: [CordisHandle] = []
    var stubs: [String: CordisHandle] = [:]
    var keysBound = false
    var settingsRegistered = false
  }

  var armed: [String: Armed] = [:]
  /// Plugin ids whose commands are in the current `commands` registry.
  var commandsRegistered: Set<String> = []
  /// What happened to lazy plugins, one line each (also printed): loads, failures, sidecar mismatches.
  var log: [String] = []
}

extension PluginLoader {
  /// The loader serving `plugins` (for the `plugins` service and `LivePlugins`).
  static func of(_ plugins: PluginHost) -> PluginLoader? { loaders[ObjectIdentifier(plugins)]?.loader }

  /// Ids of lazy plugins that are registered but not loaded: the `plugins` service lists them as
  /// available, so the command bar keeps their commands.
  static func lazyIDs(_ plugins: PluginHost) -> [String] { of(plugins)?.lazy.armed.keys.sorted() ?? [] }

  /// The plugins waiting for a trigger: plugin id -> file.
  public var armed: [String: URL] { lazy.armed.mapValues(\.url) }

  /// Lines describing lazy loads, failures and sidecar mismatches.
  public var lazyLog: [String] { lazy.log }

  func note(_ line: String) {
    lazy.log.append(line)
    print("plugins: " + line)
  }

  nonisolated static func sidecarLaunch(_ dylib: URL) -> PluginSidecar.Launch {
    PluginSidecar.read(dylib)?.launch ?? .deferred
  }

  // MARK: Arming

  /// Registers everything the sidecar of `url` declares, without loading it. False when the
  /// sidecar isn't lazy or can't wake the plugin (then the caller loads it normally).
  @discardableResult
  func arm(_ url: URL) -> Bool {
    guard let sc = PluginSidecar.read(url), sc.launch == .lazy else { return false }
    let id = url.deletingPathExtension().lastPathComponent
    guard !sc.isUnreachable else {
      note("\(id): lazy, but its sidecar declares no trigger; loading it")
      return false
    }
    if lazy.armed[id] != nil { disarm(id, unregister: true) }
    var a = LazyRegistry.Armed(url: url, id: id, sidecar: sc)
    for t in sc.triggers {
      let h = plugins.on(t.event) { [weak self] payload in
        guard let self, t.matches(payload), self.lazy.armed[id] != nil else { return }
        LaunchTrace.mark("lazy \(id) wakes on \(t.event)")
        guard self.wake(id, reason: t.event) else { return }
        // Its own listeners exist now: pass the event on.
        self.plugins.emit(t.event, payload)
      }
      a.listeners.append(h)
    }
    lazy.armed[id] = a
    stubServices(id)
    syncLazy()
    return true
  }

  /// A stub for each declared service: the first call loads the plugin and is forwarded.
  func stubServices(_ id: String) {
    guard var a = lazy.armed[id] else { return }
    for name in a.sidecar.services where a.stubs[name] == nil && !plugins.serviceNames.contains(name) {
      let h = plugins.provide(name) { [weak self] method, args in
        guard let self else { return ["error": "plugins: loader is gone"] }
        LaunchTrace.mark("lazy \(id) wakes on \(name).\(method)")
        guard self.wake(id, reason: "\(name).\(method)") else { return .error("plugin \(id) is not loaded") }
        return self.plugins.call(name, method, args)
      }
      if h != 0 { a.stubs[name] = h }
    }
    lazy.armed[id] = a
  }

  func unstubServices(_ id: String) {
    guard var a = lazy.armed[id] else { return }
    for h in a.stubs.values { plugins.dispose(h) }
    a.stubs = [:]
    lazy.armed[id] = a
  }

  /// Registers declared commands, keys and settings with whichever of `commands`, `keys` and
  /// `settings` exist. Called when a lazy plugin is armed, after every load, and when a plugin
  /// applies (`pluginApplied`), so a provider that comes later (the command bar) or comes back
  /// (hot swap) gets them too.
  public func syncLazy() {
    let services = Set(plugins.serviceNames)
    for (id, var a) in lazy.armed {
      if !a.keysBound, services.contains("keys") {
        for k in a.sidecar.keys { _ = plugins.call("keys", "bind", k) }
        a.keysBound = true
      }
      if !a.settingsRegistered, services.contains("settings") {
        for s in a.sidecar.settings { _ = plugins.call("settings", "register", s) }
        a.settingsRegistered = true
      }
      if !lazy.commandsRegistered.contains(id), services.contains("commands"), !a.sidecar.commands.isEmpty {
        var ok = true
        for c in a.sidecar.commands {
          let r = plugins.call("commands", "register", c.with("owner", .string(id)))
          if r["error"].string != nil { ok = false }
        }
        if ok { lazy.commandsRegistered.insert(id) }
      }
      lazy.armed[id] = a
    }
  }

  /// A plugin applied. When it provides `commands`, its registry is new: register again.
  public func pluginApplied(_ id: String) {
    if plugins.plugin(id)?.provides.contains("commands") == true { lazy.commandsRegistered = [] }
    syncLazy()
  }

  // MARK: Waking

  /// Loads the lazy plugin `id` for a trigger. True when it is loaded now (its stubs and listeners
  /// are gone). False when it didn't load (a failure, or a load still waiting, e.g. for the user
  /// to allow its permissions): its registrations stay, so a later trigger tries again.
  @discardableResult
  func wake(_ id: String, reason: String) -> Bool {
    guard let a = lazy.armed[id] else { return plugins.plugin(id) != nil }
    load(a.url, watch: false)
    if lazy.armed[id] == nil {
      note("\(id): loaded on \(reason)")
      return true
    }
    note("\(id): \(reason) fired but the plugin didn't load" + (outcome.failed[a.url.path].map { ": " + String($0.prefix(160)) } ?? ""))
    return false
  }

  /// Every load goes through `load(_:watch:)`: before it, an armed plugin's stubs step aside (so
  /// the plugin can provide those services itself).
  func lazyWillLoad(_ url: URL) -> String? {
    guard let id = lazy.armed.first(where: { $0.value.url.standardizedFileURL == url.standardizedFileURL })?.key
      ?? lazy.armed[url.deletingPathExtension().lastPathComponent].map(\.id)
    else { return nil }
    unstubServices(id)
    return id
  }

  /// After the load: loaded -> the lazy registrations go (the plugin made its own); not loaded ->
  /// the stubs come back.
  func lazyDidLoad(_ id: String) {
    guard let a = lazy.armed[id] else { return }
    let loaded = plugins.plugins.contains { p in
      guard p.id == id || p.path == a.url.path else { return false }
      if case .disabled = p.state { return false }
      return true
    }
    guard loaded else { return stubServices(id) }
    disarm(id, unregister: false)
    // A sidecar that promises a service the plugin doesn't provide would make every call fail.
    if plugins.plugin(id)?.state == .active {
      for s in a.sidecar.services where !plugins.serviceNames.contains(s) {
        note("\(id): sidecar declares service '\(s)' but the plugin didn't provide it")
      }
    }
    syncLazy()
  }

  /// Drops the lazy registrations of `id`. `unregister`: also take its commands, keys and settings
  /// out (the plugin is gone, not loaded).
  func disarm(_ id: String, unregister: Bool) {
    guard let a = lazy.armed.removeValue(forKey: id) else { return }
    for h in a.listeners { plugins.dispose(h) }
    for h in a.stubs.values { plugins.dispose(h) }
    if unregister {
      if lazy.commandsRegistered.contains(id) {
        for c in a.sidecar.commands { _ = plugins.call("commands", "unregister", ["id": c["id"]]) }
      }
      if a.keysBound { for k in a.sidecar.keys { _ = plugins.call("keys", "unbind", ["chord": k["chord"]]) } }
      if a.settingsRegistered { for s in a.sidecar.settings { _ = plugins.call("settings", "unregister", ["id": s["id"]]) } }
    }
    lazy.commandsRegistered.remove(id)
  }

  /// `LivePlugins`: the file for `name` changed while its plugin is armed and not loaded.
  /// Returns true when it handled it: the same file stays armed; another file is armed instead if
  /// its sidecar is lazy (else the caller loads it); no file (disabled, deleted) disarms it.
  func refreshArmed(_ name: String, target: URL?) -> Bool {
    let id = String(name.dropLast(6))
    guard let a = lazy.armed[id] else { return false }
    guard let target else {
      disarm(id, unregister: true)
      note("\(id): no longer available; unregistered")
      return true
    }
    if target.standardizedFileURL == a.url.standardizedFileURL, PluginSidecar.read(target) == a.sidecar { return true }
    disarm(id, unregister: true)
    return arm(target)
  }
}

/// Weak reference for `PluginLoader.loaders`.
struct WeakLoader {
  weak var loader: PluginLoader?
}
