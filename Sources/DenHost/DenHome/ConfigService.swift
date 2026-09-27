import CordisValue
import Foundation

/// `config` service: `~/.den/config.toml` and `~/.den/themes`, live.
///
/// Methods:
///   get {key?}   -> the whole config object, or the value at a dotted key ("plugins.disabled"), or null
///   themes       -> [{name, colors, intensity?, grain?, appearance?, file}] from ~/.den/themes, sorted by name
///   paths        -> {root, plugins, themes, config, logs}
///   errors       -> [string]: problems found in config.toml and theme files, last read
/// Events: config.changed {config}, config.themesChanged {themes}
///
/// The service reads nothing until `start()` (after the first window), so plugins that call it
/// during launch get the empty config and pick up the real one from the events.
///
/// It applies two sections itself, through public APIs:
///   [shortcuts]        "<chord>" = "<command id>"  -> keys.bind, running commands.run {id}
///   [search.keywords]  kw = {name, url}             -> merged into commands.engines
@MainActor
public final class ConfigService: HostService {
  public let name = "config"
  let host: ServiceHost
  public let home: DenHome
  /// Calls any service, host or plugin (`DenRuntime.call`).
  public var call: (String, String, Value) -> Value
  public private(set) var config: Value = .object([])
  public private(set) var themes: [Value] = []
  public private(set) var errors: [String] = []
  public private(set) var started = false
  var boundChords: [String] = []
  var appliedKeywords: [String] = []

  public init(host: ServiceHost, home: DenHome, call: @escaping (String, String, Value) -> Value) {
    self.host = host
    self.home = home
    self.call = call
    host.on("config.shortcut") { [weak self] v in
      let id = v["payload"].str("id")
      if !id.isEmpty { _ = self?.call("commands", "run", ["id": .string(id)]) }
    }
  }

  /// A plugin was applied (loaded or hot-reloaded): the command bar may have come back after
  /// the keywords were merged.
  public func pluginApplied() {
    if started, !(Self.lookup(config, "search.keywords").object ?? []).isEmpty { applyKeywords() }
  }

  public func handle(method: String, args: Value) -> Value {
    switch method {
    case "get":
      let key = args.str("key")
      return key.isEmpty ? config : Self.lookup(config, key)
    case "themes": return .array(themes)
    case "paths":
      return ["root": .string(home.root.path), "plugins": .string(home.plugins.path), "themes": .string(home.themes.path),
              "config": .string(home.config.path), "logs": .string(home.logs.path)]
    case "errors": return .array(errors.map { .string($0) })
    default: return .error("config: unknown method '\(method)'")
    }
  }

  /// Reads everything and applies it. Called once, after the first window.
  public func start() {
    started = true
    reloadConfig()
    reloadThemes()
  }

  /// Plugin ids listed in `[plugins] disabled`. Reads the file directly: the loader asks before
  /// `start()`, and it's one small read only when the file exists.
  public static func disabledPlugins(_ home: DenHome) -> Set<String> {
    guard let text = try? String(contentsOf: home.config, encoding: .utf8), let v = try? TOML.parse(text) else { return [] }
    return Set(lookup(v, "plugins.disabled").array?.compactMap(\.string) ?? [])
  }

  public var disabled: Set<String> { Set(Self.lookup(config, "plugins.disabled").array?.compactMap(\.string) ?? []) }

  public func reloadConfig() {
    errors.removeAll { $0.hasPrefix("config.toml") }
    if let text = try? String(contentsOf: home.config, encoding: .utf8) {
      do { config = try TOML.parse(text) } catch { errors.append("config.toml \(error)") }  // keep the last good config
    } else {
      config = .object([])
    }
    apply()
    host.emit("config.changed", ["config": config])
  }

  public func reloadThemes() {
    errors.removeAll { $0.hasPrefix("themes/") }
    var list: [Value] = []
    let names = (try? FileManager.default.contentsOfDirectory(atPath: home.themes.path)) ?? []
    for file in names.sorted() where file.hasSuffix(".json") || file.hasSuffix(".toml") {
      let url = home.themes.appendingPathComponent(file)
      guard let data = try? Data(contentsOf: url) else { continue }
      switch Self.parseTheme(file: file, data: data) {
      case let .success(t): list.append(t)
      case let .failure(e): errors.append("themes/\(file): \(e.message)")
      }
    }
    themes = list.sorted { $0.str("name").localizedCaseInsensitiveCompare($1.str("name")) == .orderedAscending }
    host.emit("config.themesChanged", ["themes": .array(themes)])
  }

  // MARK: Applying

  func apply() {
    // Shortcuts: rebind from scratch.
    for c in boundChords { _ = call("keys", "unbind", ["chord": .string(c)]) }
    boundChords = []
    for (chord, v) in Self.lookup(config, "shortcuts").object ?? [] {
      guard let id = v.string, !id.isEmpty else {
        errors.append("config.toml [shortcuts] \"\(chord)\" needs a command id string")
        continue
      }
      let r = call("keys", "bind", ["chord": .string(chord), "event": "config.shortcut", "title": .string(id), "menu": "Shortcuts", "payload": ["id": .string(id)]])
      if r.isError { errors.append("config.toml [shortcuts] \(r.str("error"))") } else { boundChords.append(chord.lowercased()) }
    }
    applyKeywords()
  }

  /// Merges `[search.keywords]` into the command bar's engines (config wins per keyword).
  /// Keywords this service added before and that are gone from the file are removed again.
  func applyKeywords() {
    let wanted = Self.lookup(config, "search.keywords").object ?? []
    guard !wanted.isEmpty || !appliedKeywords.isEmpty else { return }
    let current = call("commands", "engines", .null)
    guard let engines = current.array else { return }  // no command bar (yet)
    var out = engines.filter { e in
      let k = e.str("keyword")
      return !appliedKeywords.contains(k) && !wanted.contains { $0.0 == k }
    }
    var added: [String] = []
    for (kw, v) in wanted {
      let url = v.str("url"), name = v.str("name", kw)
      guard url.contains("%s") else {
        errors.append("config.toml [search.keywords] \(kw) needs a url with %s")
        continue
      }
      out.append(["keyword": .string(kw), "name": .string(name), "url": .string(url)])
      added.append(kw)
    }
    if out != engines { _ = call("commands", "engines", ["engines": .array(out)]) }
    appliedKeywords = added
  }

  // MARK: Parsing

  public struct ThemeError: Error, Equatable { public let message: String }

  /// A theme file: `name?` (default: file name), `colors` (1–3 hex strings), `intensity?`,
  /// `grain?` (0–1), `appearance?` (auto|light|dark). JSON or TOML.
  public static func parseTheme(file: String, data: Data) -> Result<Value, ThemeError> {
    let v: Value
    if file.hasSuffix(".toml") {
      guard let text = String(data: data, encoding: .utf8) else { return .failure(ThemeError(message: "not UTF-8")) }
      do { v = try TOML.parse(text) } catch { return .failure(ThemeError(message: error.description)) }
    } else {
      guard let any = try? JSONSerialization.jsonObject(with: data), let j = jsonValue(any) else { return .failure(ThemeError(message: "invalid JSON")) }
      v = j
    }
    guard v.object != nil else { return .failure(ThemeError(message: "expected an object")) }
    let colors = v.list("colors").compactMap(\.string)
    guard (1...3).contains(colors.count), colors.allSatisfy(isHex) else {
      return .failure(ThemeError(message: "colors must be 1 to 3 hex strings like \"#3139fb\""))
    }
    let base = (file as NSString).deletingPathExtension
    let name = v.str("name")
    var t: Value = ["name": .string(name.isEmpty ? base : name), "colors": .array(colors.map { .string($0) })]
    for k in ["intensity", "grain"] {
      if let d = v[k].double ?? v[k].int.map(Double.init) { t = t.with(k, .double(min(max(d, 0), 1))) }
    }
    if let a = v["appearance"].string {
      guard ["auto", "light", "dark"].contains(a) else { return .failure(ThemeError(message: "appearance must be auto, light or dark")) }
      t = t.with("appearance", .string(a))
    }
    return .success(t.with("file", .string(file)))
  }

  static func isHex(_ s: String) -> Bool {
    let h = s.hasPrefix("#") ? String(s.dropFirst()) : s
    return (h.count == 3 || h.count == 6) && h.allSatisfy(\.isHexDigit)
  }

  /// Value at a dotted path, or null.
  public static func lookup(_ v: Value, _ key: String) -> Value {
    var cur = v
    for part in key.split(separator: ".") { cur = cur[String(part)] }
    return cur
  }

  static func jsonValue(_ any: Any) -> Value? {
    switch any {
    case let s as String: return .string(s)
    case let n as NSNumber:
      if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
      if CFNumberIsFloatType(n) { return .double(n.doubleValue) }
      return .int(n.int64Value)
    case let a as [Any]: return .array(a.compactMap(jsonValue))
    case let d as [String: Any]: return .object(d.keys.sorted().compactMap { k in jsonValue(d[k]!).map { (k, $0) } })
    case is NSNull: return .null
    default: return nil
    }
  }
}
