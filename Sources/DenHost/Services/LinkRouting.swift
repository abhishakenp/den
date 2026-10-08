// The `routing` service: per-site link routing rules (Air Traffic Control).
// Match URL patterns and open in new tabs, panels, or profiles.
//
// Methods:
//   list                             -> [{id, priority, enabled, hosts, urlPattern, modifiers, action, when, profile?}]
//   add {hosts?, urlPattern, modifiers?, action, when?, profile?} -> {id}
//   remove {id}                      -> ok
//   update {id, ...fields?}          -> ok
//   reorder {id, delta}              -> ok. Moves the rule up or down by delta positions.
//   toggle {id}                      -> ok. Toggles enabled/disabled.
//   test {url, source?, modifiers?}  -> {matched: bool, rule?, action, matches: [{host, pattern}]}
// Events: routing.changed {action: add|remove|update|reorder|toggle}
//
// Storage ns `routing`: rules list persisted as [{id, priority, enabled, hosts, urlPattern, modifiers, action, when, profile}].

import AppKit
import CordisValue

@MainActor
public final class LinkRoutingService: HostService {
  public let name = "routing"

  private let host: ServiceHost
  private let storage: StorageService
  private var nextPriority: Int = 0

  // MARK: - Rule Model

  public struct Rule: Sendable {
    public var id: String
    public var enabled: Bool
    public var priority: Int
    public var hosts: [String]
    public var urlPattern: String
    public var modifiers: [String]
    public var action: String
    public var when: String
    public var profile: String?

    init(id: String, enabled: Bool, priority: Int, hosts: [String], urlPattern: String, modifiers: [String], action: String, when: String, profile: String?) {
      self.id = id
      self.enabled = enabled
      self.priority = priority
      self.hosts = hosts
      self.urlPattern = urlPattern
      self.modifiers = modifiers
      self.action = action
      self.when = when
      self.profile = profile
    }

    var value: Value {
      var pairs: [(String, Value)] = [
        ("id", .string(id)),
        ("enabled", .bool(enabled)),
        ("priority", .int(Int64(priority))),
        ("hosts", .array(hosts.map { .string($0) })),
        ("urlPattern", .string(urlPattern)),
        ("modifiers", .array(modifiers.map { .string($0) })),
        ("action", .string(action)),
        ("when", .string(when)),
      ]
      if let profile { pairs.append(("profile", .string(profile))) }
      return .object(pairs)
    }

    init?(_ v: Value) {
      guard let id = v["id"].string else { return nil }
      self.init(
        id: id,
        enabled: v.flag("enabled", true),
        priority: Int(v.num("priority", 0)),
        hosts: v.list("hosts").compactMap(\.string),
        urlPattern: v.str("urlPattern"),
        modifiers: v.list("modifiers").compactMap(\.string),
        action: v.str("action", "newTab"),
        when: v.str("when", "any"),
        profile: v["profile"].string
      )
    }
  }

  private var rules: [String: Rule] = [:]

  // MARK: - Init

  public init(host: ServiceHost, storage: StorageService) {
    self.host = host
    self.storage = storage
  }

  // MARK: - Persistence

  public func load() {
    let data = storage.handle(method: "get", args: ["ns": .string(name), "key": "rules"])
    let stored = data.object ?? []
    rules = [:]
    nextPriority = 0
    for item in stored {
      guard let rule = Rule(item.1) else { continue }
      rules[rule.id] = rule
      if rule.priority >= nextPriority { nextPriority = rule.priority + 1 }
    }
  }

  private func save() {
    let sorted = rules.values.sorted { $0.priority < $1.priority }
    let list: [(String, Value)] = sorted.map { ($0.id, $0.value) }
    storage.handle(method: "set", args: ["ns": .string(name), "key": "rules", "value": .object(list)])
  }

  // MARK: - Service

  public func handle(method: String, args: Value) -> Value {
    switch method {
    case "list":
      let sorted = rules.values.sorted { $0.priority < $1.priority }
      return .array(sorted.map { $0.value })

    case "add":
      let urlPattern = args.str("urlPattern")
      guard !urlPattern.isEmpty else { return .error("routing: add needs urlPattern") }
      // Validate regex
      do {
        _ = try NSRegularExpression(pattern: urlPattern, options: [])
      } catch {
        return .error("routing: invalid regex: \(error.localizedDescription)")
      }
      let action = args.str("action", "newTab")
      let when = args.str("when", "any")
      let validActions = ["newTab", "newTabForeground", "newPanel", "newWindow", "privateWindow", "download", "pass"]
      guard validActions.contains(action) else {
        return .error("routing: invalid action '\(action)'. Must be one of: \(validActions.joined(separator: ", "))")
      }
      let validWhen = ["any", "crossSite", "sameSite"]
      guard validWhen.contains(when) else {
        return .error("routing: invalid when '\(when)'. Must be one of: \(validWhen.joined(separator: ", "))")
      }
      var rule = Rule(id: "rule-\(nextPriority)", enabled: true, priority: nextPriority,
                      hosts: [], urlPattern: urlPattern, modifiers: [], action: action, when: when, profile: nil)
      rule.enabled = args.flag("enabled", true)
      rule.hosts = args.list("hosts").compactMap(\.string)
      rule.modifiers = args.list("modifiers").compactMap(\.string)
      rule.profile = args["profile"].string
      rules[rule.id] = rule
      nextPriority += 1
      save()
      host.emit("routing.changed", ["action": .string("add")])
      return ["id": .string(rule.id)]

    case "remove":
      let id = args.str("id")
      guard rules.removeValue(forKey: id) != nil else {
        return .error("routing: no rule '\(id)'")
      }
      save()
      host.emit("routing.changed", ["action": .string("remove")])
      return .ok

    case "update":
      let id = args.str("id")
      guard var rule = rules[id] else {
        return .error("routing: no rule '\(id)'")
      }
      if let urlPattern = args["urlPattern"].string, !urlPattern.isEmpty {
        do {
          _ = try NSRegularExpression(pattern: urlPattern, options: [])
        } catch {
          return .error("routing: invalid regex: \(error.localizedDescription)")
        }
        rule.urlPattern = urlPattern
      }
      if let hosts = args["hosts"].array {
        rule.hosts = hosts.compactMap(\.string)
      }
      if let modifiers = args["modifiers"].array {
        rule.modifiers = modifiers.compactMap(\.string)
      }
      if let action = args["action"].string {
        let validActions = ["newTab", "newTabForeground", "newPanel", "newWindow", "privateWindow", "download", "pass"]
        guard validActions.contains(action) else {
          return .error("routing: invalid action '\(action)'")
        }
        rule.action = action
      }
      if let when = args["when"].string {
        let validWhen = ["any", "crossSite", "sameSite"]
        guard validWhen.contains(when) else {
          return .error("routing: invalid when '\(when)'")
        }
        rule.when = when
      }
      if let profile = args["profile"].string {
        rule.profile = profile.isEmpty ? nil : profile
      }
      if let enabled = args["enabled"].bool {
        rule.enabled = enabled
      }
      rules[id] = rule
      save()
      host.emit("routing.changed", ["action": .string("update")])
      return .ok

    case "reorder":
      let id = args.str("id")
      guard var rule = rules[id] else {
        return .error("routing: no rule '\(id)'")
      }
      let delta = Int(args.num("delta", 1))
      let oldPriority = rule.priority
      let newPriority = oldPriority + Int(delta)
      guard newPriority >= 0 else { return .error("routing: cannot move rule up further") }
      // Swap priorities
      if var other = rules.values.first(where: { $0.priority == newPriority && $0.id != id }) {
        rule.priority = newPriority
        other.priority = oldPriority
        rules[id] = rule
        rules[other.id] = other
      } else {
        rule.priority = newPriority
        rules[id] = rule
      }
      save()
      host.emit("routing.changed", ["action": .string("reorder")])
      return .ok

    case "toggle":
      let id = args.str("id")
      guard var rule = rules[id] else {
        return .error("routing: no rule '\(id)'")
      }
      rule.enabled.toggle()
      rules[id] = rule
      save()
      host.emit("routing.changed", ["action": .string("toggle"), "id": .string(id), "enabled": .bool(rule.enabled)])
      return .ok

    case "test":
      let url = args.str("url")
      guard let target = URL(string: url) else {
        return .error("routing: invalid url")
      }
      let sourceUrl = args["source"].string
      let source = sourceUrl.flatMap { URL(string: $0) }
      let modifierStrs = args.list("modifiers").compactMap(\.string)
      // Build a Set<Chord.Mod> for the test
      var testModifiers: Set<Chord.Mod> = []
      for m in modifierStrs {
        if m == "cmd" { testModifiers.insert(.cmd) }
        if m == "shift" { testModifiers.insert(.shift) }
        if m == "opt" { testModifiers.insert(.opt) }
        if m == "ctrl" { testModifiers.insert(.ctrl) }
      }
      return testRule(url: target, source: source, modifiers: testModifiers)

    case "testRule":
      // Test a single rule against a URL without requiring a rule id from storage
      let urlPattern = args.str("urlPattern")
      let url = args.str("url")
      guard let target = URL(string: url) else {
        return .error("routing: invalid url")
      }
      let sourceUrl = args["source"].string
      let source = sourceUrl.flatMap { URL(string: $0) }
      var testModifiers: Set<Chord.Mod> = []
      for m in args.list("modifiers").compactMap(\.string) {
        if m == "cmd" { testModifiers.insert(.cmd) }
        if m == "shift" { testModifiers.insert(.shift) }
        if m == "opt" { testModifiers.insert(.opt) }
        if m == "ctrl" { testModifiers.insert(.ctrl) }
      }
      let when = ATCWhen(rawValue: args.str("when", "any")) ?? .any
      let hosts = args.list("hosts").compactMap(\.string)
      let matched = checkMatch(rule: ATCRule(hosts: hosts, urlPattern: urlPattern, modifiers: [], action: .newTab, when: when), source: source, target: target, modifiers: testModifiers)
      return [
        "matched": .bool(matched),
        "matches": .array(hosts.map { ["host": .string($0), "pattern": .string(urlPattern)] }),
        "action": .string("newTab"),
      ]

    default:
      return .error("routing: unknown method '\(method)'")
    }
  }

  // MARK: - Matching logic

  private func testRule(url: URL, source: URL?, modifiers: Set<Chord.Mod>) -> Value {
    let sorted = rules.values.sorted { $0.priority < $1.priority }
    for rule in sorted where rule.enabled {
      let atcRule = ATCRule(
        hosts: rule.hosts,
        urlPattern: rule.urlPattern,
        modifiers: [],
        action: LinkAction(rawValue: rule.action) ?? .newTab,
        when: ATCWhen(rawValue: rule.when) ?? .any
      )
      // Also check stored modifiers
      var testMods: Set<Chord.Mod> = modifiers
      for m in rule.modifiers {
        if m == "cmd" { testMods.insert(.cmd) }
        if m == "shift" { testMods.insert(.shift) }
        if m == "opt" { testMods.insert(.opt) }
        if m == "ctrl" { testMods.insert(.ctrl) }
        if m == "cmdShift" { testMods.insert(.cmd); testMods.insert(.shift) }
        if m == "cmdOpt" { testMods.insert(.cmd); testMods.insert(.opt) }
        if m == "shiftOpt" { testMods.insert(.shift); testMods.insert(.opt) }
      }

      if !testMods.isEmpty, !testMods.allSatisfy(modifiers.contains) { continue }

      if checkMatch(rule: atcRule, source: source, target: url, modifiers: testMods) {
        return [
          "matched": .bool(true),
          "rule": rule.value,
          "action": .string(rule.action),
          "matches": .array(rule.hosts.map { ["host": .string($0), "pattern": .string(rule.urlPattern)] }),
        ]
      }
    }
    return ["matched": .bool(false), "rule": .null, "action": .string("newTab")]
  }

  private func checkMatch(rule: ATCRule, source: URL?, target: URL, modifiers: Set<Chord.Mod>) -> Bool {
    guard let scheme = target.scheme, ["http", "https"].contains(scheme.lowercased()) else { return false }

    let targetHost = target.host ?? ""
    let sourceHost = source?.host ?? ""

    // Check modifiers
    let requiredChords = rule.modifiers.flatMap { $0.chords }
    if !requiredChords.isEmpty, !requiredChords.allSatisfy(modifiers.contains) { return false }

    // Check when
    switch rule.when {
    case .crossSite:
      guard LinkPolicy.site(sourceHost) != LinkPolicy.site(targetHost) else { return false }
    case .sameSite:
      guard LinkPolicy.site(sourceHost) == LinkPolicy.site(targetHost) else { return false }
    case .any:
      break
    }

    // Check hosts
    if !rule.hosts.isEmpty {
      let matched = rule.hosts.contains { host in
        host == targetHost || targetHost.hasSuffix(".\(host)")
      }
      guard matched else { return false }
    }

    // Check URL pattern (regex)
    guard let regex = try? NSRegularExpression(pattern: rule.urlPattern, options: []),
          regex.firstMatch(in: target.absoluteString, range: NSRange(target.absoluteString.startIndex..., in: target.absoluteString)) != nil
    else { return false }

    return true
  }

  // MARK: - Profile support

  /// Get the profile name for a given rule's profile field.
  public func resolveProfile(_ profileName: String?) -> String {
    guard let profileName else { return "default" }
    return profileName
  }

  /// List all available profiles (spaces) for the settings UI.
  public func listProfiles() -> [Value] {
    return []
  }
}

// MARK: - Settings registration helper

extension LinkRoutingService {
  /// Emit an event for the settings system to build the routing panel.
  public func registerSettings(host: ServiceHost) {
    let addRuleSchema = Value.object([
      ("type", .string("text")),
      ("title", .string("Add new rule")),
      ("subtitle", .string("Regex pattern to match URLs. Press Return to add.")),
      ("placeholder", .string("https?://(www\\.)?github\\.com/.*")),
      ("submit", .bool(true)),
    ])

    let itemsOptions = [
      Value.object([
        ("value", .string("pass")),
        ("title", .string("Open normally")),
      ]),
      Value.object([
        ("value", .string("newTab")),
        ("title", .string("Open in new tab")),
      ]),
    ]

    let defaultActionSchema = Value.object([
      ("type", .string("choice")),
      ("title", .string("Default action")),
      ("subtitle", .string("What to do when no rule matches.")),
      ("default", .string("pass")),
      ("options", .array(itemsOptions)),
    ])

    let schema = Value.object([
      ("addRule", addRuleSchema),
      ("rules", Value.object([
        ("type", .string("list")),
        ("title", .string("Link Routing Rules")),
        ("subtitle", .string("Per-site rules that control how links open. Priority determines which rule fires first (lowest number = highest priority).")),
        ("items", .array([])),
        ("empty", .string("No rules yet. Add a regex pattern above to get started.")),
      ])),
      ("defaultAction", defaultActionSchema),
    ])

    host.emit("routing.registerSettings", schema)
  }
}