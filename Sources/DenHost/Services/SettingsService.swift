import AppKit
import CordisValue

/// `settings` service: plugins contribute sections to den's Settings window (⌘,) as typed controls;
/// the host persists the values per plugin and tells the plugin about every change.
///
/// Methods:
///   register {id, title, icon?, section?, order?, controls: [control]}  -> ok. Replaces an earlier registration.
///       `id` owns the values (storage ns `id`, key `prefs`). With `section`, the controls join that
///       section as a group titled `title`; otherwise `id` is a section of its own in the sidebar.
///   unregister {id}              -> ok
///   list                         -> [{id, title, icon, order}]: the sidebar sections
///   get {id, key?}               -> {key: value} (stored values over the controls' defaults), or one value
///   set {id, key, value}         -> ok. Stores and emits settings.changed (the window uses it too)
///   open {section?}              -> ok. Shows the window (built on first open), at `section`
///   close                        -> ok
///   state                        -> {open, section}
/// Events: settings.changed {id, key, value}, settings.action {id, key, item?, button?} (list and
/// button controls), settings.opened {section}.
///
/// Controls: {key, type, title, subtitle?, default?} with type
///   toggle                        a switch (Bool)
///   choice  options: [{value, title}]            a pop-up menu (any Value)
///   text    placeholder?, submit?  a field. `submit: true` fires on Return only and clears (an "add" field)
///   shortcut                      a chord recorder ("cmd+shift+b"; Delete clears to "")
///   number  min, max, step?, unit?, labels?: [{value, title}]   a slider with its value
///   list    items: [{id, title, subtitle?, icon?, buttons?: [{id, title, style?}]}], empty?   plugin-provided rows
///   button  button: {title, style?}  a row with one button (settings.action)
///   info    value, buttons?: [{id, title}]  read-only text (a path) with buttons (settings.action)
/// Nothing here runs at launch beyond storing the registrations: the window and its panes are built
/// the first time Settings opens.
@MainActor
public final class SettingsService: HostService {
  public let name = "settings"
  let host: ServiceHost
  let storage: StorageService
  struct Entry { var id: String; var section: String; var title: String; var icon: String; var order: Double; var controls: [Value] }
  private(set) var entries: [String: Entry] = [:]
  private var registration = 0
  private var seq: [String: Int] = [:]
  /// Host-built sections (General), computed when shown.
  var builtins: [String: () -> Entry] = [:]
  public private(set) var window: SettingsWindowController?
  var dark: () -> Bool = { false }
  /// The main window's current palette (theme tokens), so Settings follows the space.
  var palette: () -> Palette = { Palette(theme: Theme(), dark: false) }

  public init(host: ServiceHost, storage: StorageService) {
    self.host = host
    self.storage = storage
  }

  public func handle(method: String, args: Value) -> Value {
    switch method {
    case "register":
      let id = args.str("id")
      guard !id.isEmpty else { return .error("settings: missing id") }
      if seq[id] == nil { registration += 1; seq[id] = registration }
      entries[id] = Entry(id: id, section: args.str("section", id), title: args.str("title", id), icon: args.str("icon", "sf:gearshape"),
                          order: args.num("order", 100 + Double(seq[id]!)), controls: args.list("controls"))
      window?.reload()
    case "unregister":
      entries.removeValue(forKey: args.str("id"))
      window?.reload()
    case "list":
      // With each section's `schema` (every control of its groups, keyed "<id>.<key>" with its
      // current value), so the command bar can search settings and flip them in place.
      return .array(sections.map { sec in
        var schema: [Value] = []
        for e in groups(of: sec.id) {
          for c in e.controls where !c.str("key").isEmpty && !c.str("title").isEmpty {
            var v: Value = ["key": .string(e.id + "." + c.str("key")), "title": .string(c.str("title")), "type": .string(c.str("type")),
                            "value": value(e.id, c.str("key"))]
            if !c["options"].isNull { v = v.with("options", c["options"]) }
            if !c["keywords"].isNull { v = v.with("keywords", c["keywords"]) }
            schema.append(v)
          }
        }
        return ["id": .string(sec.id), "title": .string(sec.title), "icon": .string(sec.icon), "order": .double(sec.order), "schema": .array(schema)]
      })
    case "get":
      let id = args.str("id")
      if let k = args["key"].string { return value(id, k) }
      return values(id)
    case "set":
      // `{id, key}`, or one dotted key `"<id>.<key>"` as `list` gives it.
      var id = args.str("id"), key = args.str("key")
      if id.isEmpty, let dot = key.firstIndex(of: ".") { id = String(key[..<dot]); key = String(key[key.index(after: dot)...]) }
      return set(id, key, args["value"])
    case "open":
      // `section`, or `id` (as the command bar sends it; a dotted setting key opens its section).
      var sec = args["section"].string ?? args["id"].string
      if let s0 = sec, entries[s0] == nil, builtins[s0] == nil, let k = args["key"].string, let dot = k.firstIndex(of: ".") {
        sec = entries[String(k[..<dot])]?.section ?? s0
      } else if let s0 = sec, let e = entries[s0] { sec = e.section }
      open(section: sec)
    case "close":
      window?.window.close()
    case "state":
      return ["open": .bool(window?.window.isVisible ?? false), "section": .string(window?.section ?? "")]
    default:
      return .error("settings: unknown method '\(method)'")
    }
    return .ok
  }

  // MARK: Model

  /// Sidebar sections: every entry that isn't a group of another, plus the host's, by order.
  var sections: [Entry] {
    var out = builtins.values.map { $0() }
    for e in entries.values where e.section == e.id && !out.contains(where: { $0.id == e.id }) { out.append(e) }
    return out.sorted { ($0.order, $0.title) < ($1.order, $1.title) }
  }

  /// The groups of a section: its own entry first, then entries that joined it, by order.
  func groups(of section: String) -> [Entry] {
    var own: [Entry] = []
    if let b = builtins[section] { own.append(b()) }
    if let e = entries[section], e.section == section { own.append(e) }
    let joined = entries.values.filter { $0.section == section && $0.id != section }.sorted { ($0.order, $0.title) < ($1.order, $1.title) }
    return own + joined
  }

  func control(_ id: String, _ key: String) -> Value? {
    (entries[id]?.controls ?? builtins[id]?().controls ?? []).first { $0.str("key") == key }
  }

  func stored(_ id: String) -> [(String, Value)] {
    guard StorageService.validNamespace(id) else { return [] }
    return storage.handle(method: "get", args: ["ns": .string(id), "key": "prefs"]).object ?? []
  }

  func values(_ id: String) -> Value {
    var out: [(String, Value)] = []
    for c in entries[id]?.controls ?? [] where !c.str("key").isEmpty && !c["default"].isNull { out.append((c.str("key"), c["default"])) }
    for (k, v) in stored(id) {
      if let i = out.firstIndex(where: { $0.0 == k }) { out[i].1 = v } else { out.append((k, v)) }
    }
    return .object(out)
  }

  func value(_ id: String, _ key: String) -> Value {
    if let v = stored(id).first(where: { $0.0 == key })?.1 { return v }
    return control(id, key)?["default"] ?? .null
  }

  @discardableResult
  func set(_ id: String, _ key: String, _ v: Value) -> Value {
    guard StorageService.validNamespace(id), !key.isEmpty else { return .error("settings: bad id or key") }
    var pairs = stored(id)
    if let i = pairs.firstIndex(where: { $0.0 == key }) {
      if pairs[i].1 == v { return .ok }
      pairs[i].1 = v
    } else {
      pairs.append((key, v))
    }
    let r = storage.handle(method: "set", args: ["ns": .string(id), "key": "prefs", "value": .object(pairs)])
    if r.isError { return r }
    host.emit("settings.changed", ["id": .string(id), "key": .string(key), "value": v])
    window?.valueChanged(id, key)
    return .ok
  }

  /// Host-built sections handle their own buttons; everything else goes to the owning plugin.
  var builtinActions: [String: (String, String?, String?) -> Void] = [:]

  func action(_ id: String, _ key: String, item: String? = nil, button: String? = nil, value: String? = nil) {
    if let h = builtinActions[id] { h(key, item, button); return }
    var v: Value = ["id": .string(id), "key": .string(key)]
    if let item { v = v.with("item", .string(item)) }
    if let button { v = v.with("button", .string(button)) }
    if let value { v = v.with("value", .string(value)) }
    host.emit("settings.action", v)
  }

  // MARK: Window

  /// `via`: what opened it ("menu": Settings… / ⌘,; "" from a service call). In `settings.opened`.
  public func open(section: String? = nil, via: String = "") {
    if window == nil { window = SettingsWindowController(service: self) }
    window!.show(section: section)
    host.emit("settings.opened", ["section": .string(window!.section), "via": .string(via)])
  }
}
