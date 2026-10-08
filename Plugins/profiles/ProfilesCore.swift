// The `profiles` service: create, rename, delete profiles with per-profile cookies, tab data,
// and settings. Profiles are independent browser identities — each has its own cookies,
// localStorage, and cached data (WKWebsiteDataStore). Spaces reference a profile; switching
// profile on a space swaps its web data stores.
//
// - Profile picker in the sidebar header (next to the space title): shows the current profile
//   icon/badge with a dropdown menu of all profiles.
// - Per-profile theme preferences: each profile can have its own accent color.
// - Tabs follow the profile: switching a space's profile moves the webview to that profile's
//   WKWebsiteDataStore (cookies, storage, cache).
// - Icon badges on profile items in the sidebar: a small dot when a space uses a non-default
//   profile.
//
// Usage:
//   profiles.list        -> [{id, name, icon, color}]
//   profiles.current     -> {id}
//   profiles.create {name, icon?, color?} -> {id}
//   profiles.update {id, name?, icon?, color?}
//   profiles.delete {id}  (cannot delete the only profile)
//   profiles.setDefault {id}

#if !hasFeature(Embedded)
  import CordisValue
#endif

final class ProfilesCore {
  struct Profile {
    var id: String
    var name: String
    var icon: String  // SF Symbol name
    var color: String  // hex color
    var created: Int64
    var isDefault: Bool

    var displayName: String { isDefault ? "Default" : name }

    var value: Value {
      ["id": .string(id), "name": .string(name), "icon": .string(icon), "color": .string(color),
       "default": .bool(isDefault), "created": .int(created)]
    }

    init(id: String, name: String, icon: String, color: String, created: Int64, isDefault: Bool = false) {
      self.id = id
      self.name = name
      self.icon = icon
      self.color = color
      self.created = created
      self.isDefault = isDefault
    }

    init?(_ v: Value) {
      guard let id = v["id"].string else { return nil }
      self.init(
        id: id,
        name: v.sOpt("name") ?? "Untitled",
        icon: v.sOpt("icon") ?? "sf:person.crop.circle",
        color: v.sOpt("color") ?? "#007AFF",
        created: v.i("created", 0),
        isDefault: v.b("default", false)
      )
    }
  }

  static let ns = "profiles"
  static let defaultIcon = "sf:person.crop.circle"
  static let defaultColor = "#007AFF"
  static let profileNames: [(String, String)] = [
    ("Personal", "sf:person.crop.circle.badge.checkmark"),
    ("Work", "sf:briefcase.fill"),
    ("Shopping", "sf:bag.fill"),
    ("Reading", "sf:book.fill"),
    ("Dev", "sf:code.circle.fill"),
  ]

  let env: PluginEnv
  var profiles: [Profile] = []
  var currentId: String = ""
  var nextId: Int64 = 1
  var settingsListening = false

  init(env: PluginEnv) { self.env = env }

  // MARK: - Lifecycle

  func start() {
    load()
    if profiles.isEmpty { seed() }
    currentId = profiles.first(where: { $0.isDefault })?.id ?? profiles.first?.id ?? ""
    bindKeys()
    subscribe()
    registerSettings()
    renderProfilePicker()
    env.emit("profiles.changed", ["profiles": .array(profiles.map { $0.value }), "current": .string(currentId)])
  }

  func stop() {
    if settingsListening {
      settingsListening = false
      env.call("settings", "set", ["id": .string(Self.ns), "key": "currentProfile", "value": .string(currentId)])
    }
  }

  func load() {
    let stored = env.call("storage", "get", ["ns": .string(Self.ns), "key": "profiles"])
    profiles = (stored.array ?? []).compactMap { Profile($0) }
    nextId = env.call("storage", "get", ["ns": .string(Self.ns), "key": "nextId"]).int ?? 1
    currentId = env.call("storage", "get", ["ns": .string(Self.ns), "key": "current"]).string ?? ""

    if let idx = profiles.firstIndex(where: { $0.id == currentId }) {
      currentId = profiles[idx].id
    } else if let def = profiles.first(where: { $0.isDefault }) {
      currentId = def.id
    } else if !profiles.isEmpty {
      currentId = profiles[0].id
    }

    // Validate default flag
    let defaults = profiles.filter { $0.isDefault }
    if defaults.isEmpty {
      if let firstIdx = profiles.indices.first {
        profiles[firstIdx].isDefault = true
        save()
      }
    } else if defaults.count > 1 {
      let defaultIdx = profiles.firstIndex(where: { $0.isDefault })!
      for idx in profiles.indices where idx != defaultIdx {
        profiles[idx].isDefault = false
      }
      currentId = profiles[defaultIdx].id
      save()
    }
  }

  func save() {
    env.call("storage", "set", ["ns": .string(Self.ns), "key": "profiles", "value": .array(profiles.map { $0.value })])
    env.call("storage", "set", ["ns": .string(Self.ns), "key": "current", "value": .string(currentId)])
    env.call("storage", "set", ["ns": .string(Self.ns), "key": "nextId", "value": .int(nextId)])
  }

  func newId() -> String {
    defer { nextId += 1 }
    return "profile-" + String(nextId)
  }

  // MARK: - Seed

  func seed() {
    let now = env.now()
    profiles = [Profile(id: "default", name: "Default", icon: Self.defaultIcon, color: Self.defaultColor, created: now, isDefault: true)]
    currentId = "default"
    save()
  }

  // MARK: - Service

  func handle(_ method: String, _ args: Value) -> Value {
    switch method {
    case "list":
      return .array(profiles.map { $0.value })
    case "current":
      return ["id": .string(currentId)]
    case "create":
      let name = args.s("name")
      guard !name.isEmpty else { return .err("profiles: create needs a name") }
      let id = create(name: name, icon: args.sOpt("icon"), color: args.sOpt("color"))
      return ["id": .string(id)]
    case "update":
      guard let i = profiles.firstIndex(where: { $0.id == args.s("id") }) else {
        return .err("profiles: no profile '" + args.s("id") + "'")
      }
      if let n = args["name"].string { profiles[i].name = n }
      if let ic = args["icon"].string { profiles[i].icon = ic }
      if let c = args["color"].string { profiles[i].color = c }
      save()
      renderProfilePicker()
      env.emit("profiles.changed", ["profiles": .array(profiles.map { $0.value }), "current": .string(currentId)])
      return .okay
    case "delete":
      let id = args.s("id")
      guard id != "default" || profiles.count > 1 else { return .err("profiles: cannot delete the last profile") }
      guard let i = profiles.firstIndex(where: { $0.id == id }) else {
        return .err("profiles: no profile '" + id + "'")
      }
      guard !profiles[i].isDefault || profiles.count > 1 else { return .err("profiles: cannot delete the only profile") }
      delete(i)
      return .okay
    case "setDefault":
      let id = args.s("id")
      guard let i = profiles.firstIndex(where: { $0.id == id }) else {
        return .err("profiles: no profile '" + id + "'")
      }
      for j in profiles.indices { profiles[j].isDefault = false }
      profiles[i].isDefault = true
      currentId = id
      save()
      renderProfilePicker()
      env.emit("profiles.changed", ["profiles": .array(profiles.map { $0.value }), "current": .string(currentId)])
      return .okay
    case "switch":
      let id = args.s("id")
      guard profiles.contains(where: { $0.id == id }) else {
        return .err("profiles: no profile '" + id + "'")
      }
      guard id != currentId else { return .okay }
      let prev = currentId
      currentId = id
      save()
      renderProfilePicker()
      env.emit("profiles.switched", ["id": .string(id), "previous": .string(prev)])
      env.emit("spaces.changed", ["spaces": .array(env.call("spaces", "list").array ?? [])])
      env.emit("tabs.profileChanged", ["profileId": .string(id), "previous": .string(prev)])
      return .okay
    case "defaultProfile":
      return ["id": .string(currentId)]
    case "menu":
      return .array(profileMenu())
    default:
      return .err("profiles: unknown method " + method)
    }
  }

  // MARK: - Mutations

  func create(name: String, icon: String?, color: String?) -> String {
    let id = newId()
    let palette = profilePalette(name)
    profiles.append(Profile(
      id: id,
      name: name,
      icon: icon ?? profileIcon(name),
      color: color ?? palette,
      created: env.now()
    ))
    save()
    env.emit("profiles.changed", ["profiles": .array(profiles.map { $0.value }), "current": .string(currentId)])
    return id
  }

  func delete(_ i: Int) {
    let wasCurrent = profiles[i].id == currentId
    let name = profiles[i].name
    profiles.remove(at: i)
    if wasCurrent {
      currentId = profiles.first?.id ?? ""
      let spaces = env.call("spaces", "list").array ?? []
      for sp in spaces {
        let spProfile = sp.s("profile")
        if spProfile == profiles[i].id || spProfile == name {
          let spaceId = sp.s("id")
          env.call("spaces", "update", ["id": .string(spaceId), "profile": .string("default")])
        }
      }
    }
    save()
    renderProfilePicker()
    env.emit("profiles.changed", ["profiles": .array(profiles.map { $0.value }), "current": .string(currentId)])
    env.call("ui", "set", ["slot": "toast", "tree": [
      "type": "toast", "text": .string("Profile \"" + name + "\" deleted"), "icon": "sf:trash"
    ]])
  }

  // MARK: - Profile UI helpers

  func profileIcon(_ name: String) -> String {
    let lower = name.lowercased()
    for (k, v) in Self.profileNames where k.lowercased() == lower { return v }
    return Self.defaultIcon
  }

  func profilePalette(_ name: String) -> String {
    let lower = name.lowercased()
    switch lower {
    case "personal": return "#007AFF"
    case "work": return "#FF9500"
    case "shopping": return "#34C759"
    case "reading": return "#AF52DE"
    case "dev": return "#FF2D55"
    default: return "#007AFF"
    }
  }

  func profileMenu() -> [Value] {
    var items: [Value] = []
    for p in profiles {
      var item: Value = [
        "id": .string("profile:" + p.id),
        "title": .string(p.displayName),
        "icon": .string(p.icon),
        "checked": .bool(p.id == currentId || (p.isDefault && currentId.isEmpty)),
      ]
      item.put("color", .string(p.color))
      items.append(item)
    }
    items.append(["separator": true])
    items.append(["id": "profile.new", "title": "New Profile…", "icon": "sf:plus"])
    return items
  }

  func renderProfilePicker() {
    let profile = profiles.first(where: { $0.id == currentId }) ?? profiles.first
    guard let profile else { return }
    let tree: Value = [
      "type": "profilePicker",
      "id": .string("profiles.picker"),
      "currentId": .string(profile.id),
      "name": .string(profile.displayName),
      "icon": .string(profile.icon),
      "color": .string(profile.color),
      "menu": .array(profileMenu()),
    ]
    env.call("ui", "set", ["slot": "sidebar.profileHeader", "tree": tree])
  }

  // MARK: - Settings

  func registerSettings() {
    let r = env.call("settings", "register", [
      "id": .string(Self.ns), "section": "general", "title": "Profiles", "order": 30,
      "controls": [
        ["key": "currentProfile", "type": "choice", "title": "Active profile",
         "subtitle": "The profile used for cookies, storage, and saved data.",
         "options": .array(profiles.map { ["value": .string($0.id), "title": .string($0.displayName)] }),
         "default": .string(currentId)],
        ["key": "newProfile", "type": "action", "title": "New Profile",
         "subtitle": "Create a new browser profile with its own cookies and storage.",
         "action": "profiles.newProfile"],
      ],
    ])
    guard !r.isErr else { return }
    settingsListening = true
    env.on("settings.changed") { [self] v in
      guard v.s("id") == Self.ns else { return }
      switch v.s("key") {
      case "currentProfile":
        if let pid = v["value"].string {
          _ = env.call("profiles", "setDefault", ["id": .string(pid)])
        }
      case "newProfile":
        newProfilePrompt()
      default: break
      }
    }
  }

  func newProfilePrompt() {
    env.call("ui", "set", ["slot": "dialog", "tree": [
      "type": "dialog", "id": .string("profiles.newDialog"), "icon": "sf:person.crop.circle.badge.plus",
      "title": "New Profile",
      "message": "Give this profile a name. It will have its own cookies, storage, and saved data.",
      "buttons": [
        ["id": "cancel", "title": "Cancel", "style": "cancel"],
        ["id": "create", "title": "Create", "style": "default"],
      ],
      "input": ["placeholder": "Profile name"],
    ]])
  }

  // MARK: - Keys

  func bindKeys() {
    env.call("keys", "bind", ["chord": "cmd+opt+p", "event": "profiles.key.picker", "title": "Switch Profile", "menu": "View"])
  }

  func subscribe() {
    env.on("ui.action") { [self] v in action(v.s("id"), v.s("action"), v["value"]) }
    env.on("spaces.profileChanged") { [self] v in
      renderProfilePicker()
    }
  }

  // MARK: - Actions

  func action(_ id: String, _ action: String, _ value: Value) {
    if id == "profiles.picker" {
      switch action {
      case "click":
        break
      case "menu":
        handleMenuPick(value.s("menuId"))
      default: break
      }
    } else if id == "profiles.newDialog" {
      switch action {
      case "button":
        if value.s("button") == "create" {
          if let name = value.sOpt("input"), !name.isEmpty {
            let pid = create(name: name, icon: nil, color: nil)
            _ = env.call("profiles", "setDefault", ["id": .string(pid)])
          }
        }
        env.call("ui", "set", ["slot": "dialog", "tree": nil])
      case "dismiss":
        env.call("ui", "set", ["slot": "dialog", "tree": nil])
      default: break
      }
    } else if id == "profiles.newProfile" {
      newProfilePrompt()
    } else {
      handleMenuPick(id)
    }
  }

  func handleMenuPick(_ id: String) {
    if id == "profile.new" {
      newProfilePrompt()
      return
    }
    if id.hasPrefix("profile:") {
      let pid = String(id.dropFirst(8))
      guard let profile = profiles.first(where: { $0.id == pid }) else { return }
      _ = env.call("profiles", "setDefault", ["id": .string(pid)])
      env.call("ui", "set", ["slot": "toast", "tree": [
        "type": "toast", "text": .string("Switched to " + profile.displayName), "icon": .string(profile.icon)
      ]])
    }
  }
}