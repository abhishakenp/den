// `~/.den/config.toml` sections that belong to the command bar (docs/den-home.md), applied here on
// every `config.changed` (the host's `config` service only reads the file; docs/architecture/
// thin-host.md §6 step 2):
//   [shortcuts]        "<chord>" = "<id>"  -> a menu item id takes the chord in place (keys.remap);
//                                             anything else is a command, bound to run it
//   [search.keywords]  kw = {name, url}      -> merged into the engines (config wins per keyword)
// Problems are reported back with `config.report`, so Settings and the config toast show them.
// State: `configChords` (bound for commands) and `configKeywords` (stored, so a keyword removed
// from the file is removed from the engines even across a plugin reload) live in CommandBarCore.

#if !hasFeature(Embedded)
  import CordisValue
#endif

extension CommandBarCore {
  static let shortcutEvent = "commands.shortcut"
  static let configKeywordsKey = "configKeywords"

  func startConfig() {
    if let list = env.call("storage", "get", ["ns": .string(Self.ns), "key": .string(Self.configKeywordsKey)]).array {
      configKeywords = list.compactMap { $0.string }
    }
    env.on(Self.shortcutEvent) { [self] v in
      let id = v["payload"].s("id")
      if !id.isEmpty { _ = handle("run", ["id": .string(id)]) }
    }
    env.on("config.changed") { [self] v in applyConfig(v["config"]) }
    // A (re)loaded command bar applies what den already read; before den reads ~/.den this is
    // the empty config, and `config.changed` follows.
    let c = env.call("config", "get")
    if case .object = c, !c.isErr { applyConfig(c) }
  }

  func applyConfig(_ config: Value) {
    var errors: [String] = []
    for c in configChords { env.call("keys", "unbind", ["chord": .string(c)]) }
    configChords = []
    env.call("keys", "resetRemaps")
    if case let .object(pairs) = config["shortcuts"] {
      for (chord, v) in pairs {
        guard let id = v.string, !id.isEmpty else {
          errors.append("config.toml [shortcuts] \"" + chord + "\" needs a command id string")
          continue
        }
        // A menu item id ("tabs.next", "view.zoomIn", … docs/shortcuts.md) takes the chord in place.
        let r = env.call("keys", "remap", ["chord": .string(chord), "item": .string(id)])
        if !r.isErr { continue }
        if !r["noItem"].b() {
          errors.append("config.toml [shortcuts] " + r.s("error"))
          continue
        }
        let b = env.call("keys", "bind", ["chord": .string(chord), "event": .string(Self.shortcutEvent), "title": .string(id), "menu": "Shortcuts",
                                          "payload": ["id": .string(id)]])
        if b.isErr { errors.append("config.toml [shortcuts] " + b.s("error")) } else { configChords.append(Text.lower(chord)) }
      }
    }
    errors += applyKeywords(config["search"]["keywords"])
    env.call("config", "report", ["source": "commandbar", "errors": .array(errors.map { .string($0) })])
  }

  /// Merges `[search.keywords]` into the engines. Returns problems found.
  func applyKeywords(_ wanted: Value) -> [String] {
    var pairs: [(String, Value)] = []
    if case let .object(p) = wanted { pairs = p }
    guard !pairs.isEmpty || !configKeywords.isEmpty else { return [] }
    var errors: [String] = []
    let current = engines.map { $0.value }
    var out = current.filter { e in
      let k = e.s("keyword")
      return !configKeywords.contains(k) && !pairs.contains { $0.0 == k }
    }
    var added: [String] = []
    for (kw, v) in pairs {
      let url = v.s("url")
      guard Text.contains(url, "%s") else {
        errors.append("config.toml [search.keywords] " + kw + " needs a url with %s")
        continue
      }
      out.append(["keyword": .string(kw), "name": .string(v.sOpt("name") ?? kw), "url": .string(url)])
      added.append(kw)
    }
    if out != current { _ = handle("engines", ["engines": .array(out)]) }
    if added != configKeywords {
      configKeywords = added
      env.call("storage", "set", ["ns": .string(Self.ns), "key": .string(Self.configKeywordsKey), "value": .array(added.map { .string($0) })])
    }
    return errors
  }
}
