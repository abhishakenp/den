#if !hasFeature(Embedded)
  import CordisValue
#endif

/// The Extensions page and commands, over the host `extensions` service (docs/plugin-services.md).
///
/// - Page: `overlay.extensions` (style `page`). The list shows every installed extension with an
///   on/off switch; a row opens its details (site access, permissions, pin, options, store page,
///   remove). "Get more" links to the Chrome Web Store and Firefox Add-ons.
/// - Commands: "Extensions", "Install Extension from File…", "Get Extensions".
/// - `extensions.openPage {id?}` (the URL pill menu's "Manage Extensions") opens the page.
/// Nothing here runs until the page or a command is used; the host owns all WebKit state.
final class ExtensionsCore {
  static let sheetId = "extensions"
  static let slot = "overlay.extensions"
  static let chromeStore = "https://chromewebstore.google.com/category/extensions"
  static let firefoxStore = "https://addons.mozilla.org/firefox/extensions/"
  static let commandList: [(String, String, String, [String])] = [
    ("extensions.installFile", "Install Extension from File…", "sf:square.and.arrow.down", ["extension", "crx", "xpi", "unpacked", "load", "install"]),
    ("extensions.get", "Get Extensions", "sf:plus.circle", ["chrome web store", "firefox add-ons", "store", "extensions", "browse"]),
  ]

  let env: PluginEnv
  var open = false
  var selected: String?
  var removing: String?
  var commandsRegistered = false
  var registerAttempts = 0
  var announceUpdates = false

  init(env: PluginEnv) { self.env = env }

  /// The `extensions` service. The command bar's built-in "Extensions" destination calls `open`.
  func handle(_ method: String, _ args: Value) -> Value {
    switch method {
    case "open":
      show(args.sOpt("id"))
      return .okay
    case "close":
      if open { close() }
      return .okay
    case "state": return ["open": .bool(open), "selected": .str(selected)]
    default: return .err("extensions: unknown method " + method)
    }
  }

  func start() {
    env.on("webext.changed") { [self] _ in if open { render() } }
    env.on("webext.openPage") { [self] v in show(v.sOpt("id")) }
    env.on("webext.updates") { [self] v in updatesDone(v) }
    env.on("commands.run") { [self] v in run(v.s("id")) }
    env.on("ui.action") { [self] v in action(v.s("id"), v.s("action"), v["value"]) }
    registerCommands()
  }

  func stop() {
    registerAttempts = Int.max / 2
    if open { close() }
  }

  // MARK: Commands

  func run(_ id: String) {
    switch id {
    case "extensions.open": show(nil)
    case "extensions.installFile": env.call("webext", "pickFile")
    case "extensions.get": openURL(Self.chromeStore)
    default: break
    }
  }

  /// `commands` is optional (plugin `commandbar`) and may load later: retry every 500 ms for 30 s.
  func registerCommands() {
    if tryRegister() { return }
    env.timer(500, false) { [self] in
      registerAttempts += 1
      if !tryRegister(), registerAttempts < 60 { registerCommands() }
    }
  }

  @discardableResult
  func tryRegister() -> Bool {
    if commandsRegistered { return true }
    for (id, title, icon, keywords) in Self.commandList {
      let r = env.call("commands", "register", [
        "id": .string(id), "title": .string(title), "icon": .string(icon), "owner": "extensions",
        "keywords": .array(keywords.map { .string($0) }),
      ])
      if r.isErr { return false }
    }
    commandsRegistered = true
    return true
  }

  func openURL(_ url: String) {
    let r = env.call("tabs", "open", ["url": .string(url)])
    if r.isErr { env.log("extensions: no tabs service to open \(url)") }
    if open { close() }
  }

  // MARK: Page

  func show(_ id: String?) {
    open = true
    selected = id
    render()
  }

  func close() {
    open = false
    selected = nil
    env.call("ui", "set", ["slot": .string(Self.slot), "tree": nil])
  }

  func list() -> [Value] { env.call("webext", "list").array ?? [] }

  func render() {
    let all = list()
    if let id = selected, let e = all.first(where: { $0.s("id") == id }) {
      env.call("ui", "set", ["slot": .string(Self.slot), "tree": details(e)])
    } else {
      selected = nil
      env.call("ui", "set", ["slot": .string(Self.slot), "tree": listPage(all)])
    }
  }

  static func sourceName(_ s: String) -> String {
    switch s {
    case "chrome": return "Chrome Web Store"
    case "firefox": return "Firefox Add-ons"
    case "home": return "~/.den/extensions"
    default: return "Installed from a file"
    }
  }

  func listPage(_ all: [Value]) -> Value {
    let on = all.filter { $0.b("enabled") }.count
    var children: [Value] = []
    if all.isEmpty {
      children.append(["type": "paragraph", "id": "extensions.empty", "icon": "sf:puzzlepiece.extension",
                       "text": "No extensions yet. Open an extension’s page on the Chrome Web Store or Firefox Add-ons and click “Add to den”, or install one from a file."])
    } else {
      var rows: [Value] = []
      for e in all {
        var sub = "Version " + e.s("version") + " · " + Self.sourceName(e.s("source"))
        if !e.a("errors").isEmpty { sub = (e.b("loaded") || !e.b("enabled") ? "Version " + e.s("version") + " · ⚠︎ " : "Couldn’t load · ") + (e.a("errors").first?.string ?? "") }
        var row: Value = ["type": "extensionRow", "id": .string("extensions.row:" + e.s("id")), "icon": .string(e.s("icon")),
                          "title": .string(e.s("name")), "subtitle": .string(sub), "on": .bool(e.b("enabled"))]
        if let v = e.sOpt("updateAvailable") { row.put("note", .string("Update " + v)) }
        rows.append(row)
      }
      children.append(["type": "section", "id": "webext.installed", "title": "Installed", "accessory": .string(String(all.count)), "children": .array(rows)])
    }
    children.append(["type": "section", "id": "extensions.more", "title": "Get more", "children": [
      ["type": "feedRow", "id": "extensions.get.chrome", "title": "Chrome Web Store", "subtitle": "chromewebstore.google.com · open an extension and click “Add to den”", "icon": "sf:globe"],
      ["type": "feedRow", "id": "extensions.get.firefox", "title": "Firefox Add-ons", "subtitle": "addons.mozilla.org · add-ons that don’t need Firefox-only APIs", "icon": "sf:globe"],
      ["type": "feedRow", "id": "extensions.get.file", "title": "Install from a file…", "subtitle": "An unpacked folder, or a .crx, .xpi or .zip", "icon": "sf:square.and.arrow.down"],
    ]])
    let storeButtons = env.call("webext", "settings")["storeButtons"].bool ?? true
    children.append(["type": "section", "id": "extensions.settings", "title": "Settings", "children": [
      ["type": "toggleRow", "id": "extensions.storeButtons", "title": "“Add to den” on store pages", "subtitle": "Shows an install button on Chrome Web Store and Firefox Add-ons pages", "on": .bool(storeButtons)],
    ]])
    children.append(["type": "paragraph", "id": "extensions.about", "style": "caption",
                     "text": "den runs extensions on Apple’s WebKit engine, the same one Safari uses: Manifest V2 and V3, chrome.* and browser.*. WebKit has no blocking webRequest, identity, downloads, history, bookmarks or side panels, so extensions that need them won’t fully work."])
    return ["type": "sheet", "id": .string(Self.sheetId), "style": "page", "title": "Extensions", "icon": "sf:puzzlepiece.extension",
            "subtitle": .string(all.isEmpty ? "Chrome and Firefox extensions" : "\(all.count) installed · \(on) on"),
            "headerButtons": [
              ["id": "extensions.update", "icon": "sf:arrow.triangle.2.circlepath", "tooltip": "Check for Updates"],
              ["id": "extensions.addFile", "icon": "sf:plus", "tooltip": "Install Extension from File…"],
            ],
            "children": .array(children)]
  }

  func details(_ e: Value) -> Value {
    let id = e.s("id")
    var children: [Value] = []
    if let d = e.sOpt("description") { children.append(["type": "paragraph", "id": "extensions.desc", "text": .string(d)]) }
    var access: [Value] = [[
      "type": "choiceRow", "id": "extensions.access", "title": "Site access", "subtitle": "When it can read and change pages",
      "options": [["id": "all", "title": "On all sites"], ["id": "click", "title": "When you click it"], ["id": "sites", "title": "On specific sites"]],
      "selected": .string(e.s("siteAccess")),
    ]]
    if e.s("siteAccess") == "sites" {
      for s in e.a("sites") {
        access.append(["type": "toggleRow", "id": .string("extensions.site:" + (s.string ?? "")), "title": s, "icon": "sf:globe", "on": true])
      }
      if let h = currentHost(), !e.a("sites").contains(.string(h)) {
        access.append(["type": "buttonRow", "id": "extensions.allowRow", "children": [["type": "actionButton", "id": "extensions.allowCurrent", "title": .string("Allow on " + h), "style": "secondary"]]])
      }
    }
    children.append(["type": "section", "id": "extensions.accessSection", "title": "Access", "children": .array(access)])
    var perms: [Value] = e.a("permissions").map { p in ["type": "paragraph", "id": .string("extensions.perm:" + (p.string ?? "")), "text": p, "icon": "sf:checkmark.shield"] }
    if perms.isEmpty { perms.append(["type": "paragraph", "id": "extensions.perm.none", "text": "No special access", "style": "secondary"]) }
    let unsupported = e.a("unsupported").compactMap { $0.string }
    if !unsupported.isEmpty {
      perms.append(["type": "paragraph", "id": "extensions.unsupported", "style": "secondary", "icon": "sf:exclamationmark.triangle",
                    "text": .string("Not available in WebKit: " + join(unsupported))])
    }
    children.append(["type": "section", "id": "extensions.perms", "title": "Permissions", "children": .array(perms)])
    var info: [Value] = [
      ["type": "toggleRow", "id": "extensions.pin", "title": "Pin to the URL bar", "subtitle": "Shows its button when you hover the URL", "icon": "sf:pin", "on": .bool(e.b("pinned"))],
      ["type": "toggleRow", "id": "extensions.enabled", "title": "On", "icon": "sf:power", "on": .bool(e.b("enabled"))],
    ]
    children.append(["type": "section", "id": "extensions.info", "title": "Details", "children": .array(info)])
    children.append(["type": "paragraph", "id": "extensions.meta", "style": "caption",
                     "text": .string("Manifest V" + String(e.i("manifestVersion")) + " · background " + e.s("background") + " · " + Self.sourceName(e.s("source")) + " · ID " + id)])
    for (i, err) in e.a("errors").enumerated() {
      children.append(["type": "paragraph", "id": .string("extensions.err:" + String(i)), "style": "caption", "icon": "sf:exclamationmark.triangle", "text": err])
    }
    var buttons: [Value] = []
    if e.b("hasOptions") { buttons.append(["type": "actionButton", "id": "extensions.options", "title": "Options", "style": "secondary"]) }
    if let u = e.sOpt("updateAvailable") { buttons.append(["type": "actionButton", "id": "extensions.applyUpdate", "title": .string("Update to " + u), "style": "primary"]) }
    if e.sOpt("storeURL") != nil { buttons.append(["type": "actionButton", "id": "extensions.store", "title": "View in Store", "style": "secondary"]) }
    buttons.append(["type": "actionButton", "id": "extensions.remove", "title": "Remove", "style": "destructive"])
    children.append(["type": "buttonRow", "id": "extensions.buttons", "children": .array(buttons)])
    return ["type": "sheet", "id": .string(Self.sheetId), "style": "page", "title": .string(e.s("name")), "icon": .string(e.s("icon")),
            "subtitle": .string("Version " + e.s("version") + " · " + Self.sourceName(e.s("source"))),
            "headerButtons": [["id": "extensions.back", "icon": "sf:chevron.left", "tooltip": "All Extensions"]],
            "children": .array(children)]
  }

  func join(_ a: [String]) -> String {
    var s = ""
    for (i, x) in a.enumerated() { s += (i == 0 ? "" : ", ") + x }
    return s
  }

  /// The selected tab's host (for "Allow on <site>").
  func currentHost() -> String? {
    guard let tab = env.call("tabs", "selected")["id"].string else { return nil }
    let u = env.call("webviews", "get", ["id": .string(tab)]).s("url")
    guard Text.hasPrefix(u, "http") else { return nil }
    let h = URLs.host(u)
    return h.isEmpty || h == u ? nil : h
  }

  // MARK: Actions

  func action(_ id: String, _ act: String, _ value: Value) {
    if id == "extensions.remove.dialog" { return removeAnswer(value.s("button")) }
    guard open || id == Self.sheetId else { return }
    let sel = selected ?? ""
    switch (id, act) {
    case (Self.sheetId, "dismiss"): close()
    case ("extensions.back", _): show(nil)
    case ("extensions.addFile", _), ("extensions.get.file", _): env.call("webext", "pickFile")
    case ("extensions.update", _):
      announceUpdates = true
      env.call("webext", "checkUpdates", ["force": true])
      toast("Checking for updates…", "sf:arrow.triangle.2.circlepath")
    case ("extensions.get.chrome", _): openURL(Self.chromeStore)
    case ("extensions.get.firefox", _): openURL(Self.firefoxStore)
    case ("extensions.storeButtons", "toggle"):
      env.call("webext", "settings", ["storeButtons": .bool(value.b("on"))])
      render()
    case ("extensions.access", "select"): env.call("webext", "setSiteAccess", ["id": .string(sel), "mode": .string(value.s("option"))])
    case ("extensions.allowCurrent", _):
      if let h = currentHost() { env.call("webext", "allowSite", ["id": .string(sel), "site": .string(h), "allowed": true]) }
    case ("extensions.pin", "toggle"): env.call("webext", "setPinned", ["id": .string(sel), "pinned": .bool(value.b("on"))])
    case ("extensions.enabled", "toggle"): env.call("webext", "setEnabled", ["id": .string(sel), "enabled": .bool(value.b("on"))])
    case ("extensions.options", _):
      env.call("webext", "openOptions", ["id": .string(sel)])
      close()
    case ("extensions.store", _):
      if let e = list().first(where: { $0.s("id") == sel }), let u = e.sOpt("storeURL") { openURL(u) }
    case ("extensions.applyUpdate", _):
      if let e = list().first(where: { $0.s("id") == sel }) {
        env.call("webext", "installFromStore", ["source": .string(e.s("source")), "id": .string(e.s("storeId"))])
      }
    case ("extensions.remove", _): confirmRemove(sel)
    default:
      if Text.hasPrefix(id, "extensions.row:") {
        let ext = Text.dropPrefix(id, "extensions.row:")
        if act == "toggle" { env.call("webext", "setEnabled", ["id": .string(ext), "enabled": .bool(value.b("on"))]) } else if act == "open" { show(ext) }
      } else if Text.hasPrefix(id, "extensions.site:"), act == "toggle" {
        env.call("webext", "allowSite", ["id": .string(sel), "site": .string(Text.dropPrefix(id, "extensions.site:")), "allowed": .bool(value.b("on"))])
      }
    }
  }

  func confirmRemove(_ id: String) {
    guard let e = list().first(where: { $0.s("id") == id }) else { return }
    removing = id
    env.call("ui", "set", ["slot": "dialog", "tree": [
      "type": "dialog", "id": "extensions.remove.dialog", "icon": .string(e.s("icon")), "title": .string("Remove “" + e.s("name") + "”?"),
      "message": "Its settings and data in den are deleted.",
      "buttons": [["id": "cancel", "title": "Cancel", "style": "cancel"], ["id": "remove", "title": "Remove", "style": "destructive", "default": true]],
    ]])
  }

  func removeAnswer(_ button: String) {
    env.call("ui", "set", ["slot": "dialog", "tree": nil])
    guard let id = removing else { return }
    removing = nil
    guard button == "remove" else { return }
    env.call("webext", "uninstall", ["id": .string(id)])
    if selected == id { selected = nil }
    if open { render() }
  }

  func updatesDone(_ v: Value) {
    guard announceUpdates else { return }
    announceUpdates = false
    let n = v.a("updated").count, a = v.a("available").count
    if n > 0 {
      toast("Updated " + String(n) + (n == 1 ? " extension" : " extensions"), "sf:checkmark.circle.fill")
    } else if a > 0 {
      toast(String(a) + (a == 1 ? " update needs" : " updates need") + " your approval", "sf:exclamationmark.circle.fill")
    } else {
      toast("Extensions are up to date", "sf:checkmark.circle.fill")
    }
  }

  func toast(_ text: String, _ icon: String) {
    env.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": .string(text), "icon": .string(icon)]])
  }
}
