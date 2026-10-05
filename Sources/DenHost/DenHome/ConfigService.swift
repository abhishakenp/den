import CordisValue
import Foundation

/// `config` service: `~/.den/config.toml` and `~/.den/themes`, live.
///
/// Methods:
///   get {key?}   -> the whole config object, or the value at a dotted key ("plugins.disabled"), or null
///   themes       -> [{name, colors, intensity?, grain?, appearance?, file}] from ~/.den/themes, sorted by name
///   paths        -> {root, plugins, themes, config, logs}
///   errors       -> [string]: problems found in config.toml and theme files, last read, plus
///                   what plugins reported
///   report {source, errors: [string]} -> ok: a plugin's problems applying its config sections
///                   (replaces that source's earlier report)
/// Events: config.changed {config, edited} (`edited`: the file changed while den ran), config.themesChanged {themes}
///
/// The service reads nothing until `start()` (after the first window), so plugins that call it
/// during launch get the empty config and pick up the real one from the events. It applies no
/// section itself: plugins apply theirs on `config.changed` (the `commandbar` plugin applies
/// [shortcuts] and [search.keywords]).
@MainActor
public final class ConfigService: HostService {
  public let name = "config"
  let host: ServiceHost
  public let home: DenHome
  /// Calls any service, host or plugin (`DenRuntime.call`).
  public var call: (String, String, Value) -> Value
  public private(set) var config: Value = .object([])
  public private(set) var themes: [Value] = []
  /// Problems reading config.toml and the themes.
  private var readErrors: [String] = []
  /// Problems plugins reported applying their sections (`report`), by source.
  private var reported: [(String, [String])] = []
  public var errors: [String] { readErrors + reported.flatMap(\.1) }
  public private(set) var started = false

  public init(host: ServiceHost, home: DenHome, call: @escaping (String, String, Value) -> Value) {
    self.host = host
    self.home = home
    self.call = call
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
    case "report":
      let source = args.str("source")
      guard !source.isEmpty else { return .error("config: report needs a source") }
      let list = args.list("errors").compactMap(\.string)
      reported.removeAll { $0.0 == source }
      if !list.isEmpty { reported.append((source, list)) }
      return .ok
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

  public func reloadConfig(edited: Bool = false) {
    readErrors.removeAll { $0.hasPrefix("config.toml") }
    if let text = try? String(contentsOf: home.config, encoding: .utf8) {
      do { config = try TOML.parse(text) } catch { readErrors.append("config.toml \(error)") }  // keep the last good config
    } else {
      config = .object([])
    }
    host.emit("config.changed", ["config": config, "edited": .bool(edited)])
  }

  public func reloadThemes() {
    readErrors.removeAll { $0.hasPrefix("themes/") }
    var list: [Value] = []
    let names = (try? FileManager.default.contentsOfDirectory(atPath: home.themes.path)) ?? []
    for file in names.sorted() where file.hasSuffix(".json") || file.hasSuffix(".toml") {
      let url = home.themes.appendingPathComponent(file)
      guard let data = try? Data(contentsOf: url) else { continue }
      switch Self.parseTheme(file: file, data: data) {
      case let .success(t): list.append(t)
      case let .failure(e): readErrors.append("themes/\(file): \(e.message)")
      }
    }
    themes = list.sorted { $0.str("name").localizedCaseInsensitiveCompare($1.str("name")) == .orderedAscending }
    host.emit("config.themesChanged", ["themes": .array(themes)])
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
