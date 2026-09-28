#if !hasFeature(Embedded)
  import CordisValue
#endif

/// den's password manager UI on top of the host `vault` service (docs/plugin-services.md
/// `passwords`). The host keeps every secret; this plugin only sees origins and usernames.
///
/// - "Save password?" when a login form is submitted: Save / Not Now / Never for This Site
///   (`never` origins in storage ns `passwords`).
/// - A focused login field on a site with saved logins gets a small list under it; picking a
///   login asks for Touch ID (host) and fills. Sign-up fields also offer a strong password.
/// - "Passwords…" (command, `passwords.open`): Touch ID, then the list in `overlay.passwords`,
///   with Copy (Touch ID again) and Delete per login.
final class PasswordsCore {
  static let ns = "passwords"
  static let saveDialog = "passwords.save"
  static let sheetId = "passwords"
  static let rowPrefix = "passwords.row:"

  let env: PluginEnv
  var never: [String] = []
  /// The capture the save dialog is about.
  var pending: Value?
  var sheetOpen = false
  var unlockRequest = ""
  /// "password for ada on login.test": the copy toast's words for the account being copied.
  var copyWhat = "password"
  var commandsRegistered = false
  var registerAttempts = 0

  init(env: PluginEnv) { self.env = env }

  func start() {
    never = env.call("storage", "get", ["ns": .string(Self.ns), "key": "never"]).array?.compactMap { $0.string } ?? []
    env.call("vault", "enable")
    env.on("vault.focus") { [self] v in focus(v) }
    env.on("vault.blur") { [self] v in env.call("vault", "suggest", ["webview": v["webview"], "items": []]) }
    env.on("vault.suggestion") { [self] v in picked(v.s("webview"), v.s("item")) }
    env.on("vault.captured") { [self] v in captured(v) }
    env.on("vault.result") { [self] v in result(v) }
    env.on("ui.action") { [self] v in action(v.s("id"), v.s("action"), v["value"]) }
    env.on("commands.run") { [self] v in if v.s("id") == "passwords.open" { open() } }
    env.on("content.focus") { [self] v in page = v.s("id"); refreshKey() }
    env.on("webviews.url") { [self] v in if v.s("id") == page { refreshKey() } }
    page = env.call("content", "get").s("focus")
    refreshKey()
    registerCommands()
  }

  func stop() {
    registerAttempts = Int.max / 2
    closeSheet()
    if !keyOn.isEmpty { env.call("tabs", "pillButtons", ["webview": .string(keyOn), "owner": "passwords", "buttons": []]) }
  }

  // MARK: Key button

  static let keyButton = "passwords.key"
  /// The web view in front (content focus).
  var page = ""
  /// The web view whose URL pill shows the key ("" = none).
  var keyOn = ""

  /// A key in the URL pill (the tabs plugin's `pillButtons`) while the page in front has saved
  /// logins: clicking it focuses the page's sign-in field, which opens the suggestions under it.
  func refreshKey() {
    let logins = page.isEmpty ? [] : (env.call("vault", "accounts", ["webview": .string(page)]).array ?? [])
    if !keyOn.isEmpty, keyOn != page || logins.isEmpty {
      env.call("tabs", "pillButtons", ["webview": .string(keyOn), "owner": "passwords", "buttons": []])
      keyOn = ""
    }
    guard !logins.isEmpty else { return }
    let host = URLs.host(logins.first?.s("origin") ?? "")
    env.call("tabs", "pillButtons", ["webview": .string(page), "owner": "passwords", "buttons": [[
      "id": .string(Self.keyButton), "icon": "sf:key.fill",
      "tooltip": .string(logins.count == 1 ? "Fill your saved password for " + host : "Fill a saved password for " + host)]]])
    keyOn = page
  }

  // MARK: Autofill

  func focus(_ v: Value) {
    var items: [Value] = []
    for a in v.a("accounts") {
      let user = a.s("username")
      items.append(["id": .string("fill:" + a.s("id")), "title": .string(user.isEmpty ? "(no username)" : user),
                    "subtitle": .string(URLs.host(v.s("origin")) + " · Touch ID"), "icon": "sf:key.fill"])
    }
    if v.b("signup") {
      items.append(["id": "generate", "title": "Use Strong Password", "subtitle": "den creates it and offers to save it", "icon": "sf:wand.and.stars"])
    }
    env.call("vault", "suggest", ["webview": v["webview"], "items": .array(items)])
  }

  func picked(_ webview: String, _ item: String) {
    if item == "generate" {
      env.call("vault", "generate", ["webview": .string(webview)])
    } else if Text.hasPrefix(item, "fill:") {
      env.call("vault", "fill", ["webview": .string(webview), "account": .string(Text.dropPrefix(item, "fill:"))])
    }
  }

  // MARK: Save

  func captured(_ v: Value) {
    let origin = v.s("origin")
    if never.contains(origin) {
      env.call("vault", "dismiss", ["capture": v["capture"]])
      return
    }
    if let p = pending { env.call("vault", "dismiss", ["capture": p["capture"]]) }
    pending = v
    let host = URLs.host(origin)
    let user = v.s("username")
    env.call("ui", "set", ["slot": "dialog", "tree": [
      "type": "dialog", "id": .string(Self.saveDialog), "icon": "sf:key.fill", "iconStyle": "accent",
      "title": .string((v.b("exists") ? "Update password for " : "Save password for ") + host + "?"),
      "message": .string((user.isEmpty ? "" : user + " · ") + "Stored in your Keychain, filled only after Touch ID."),
      "buttons": [
        ["id": "never", "title": "Never for This Site", "style": "secondary"],
        ["id": "cancel", "title": "Not Now", "style": "cancel"],
        ["id": "save", "title": .string(v.b("exists") ? "Update" : "Save"), "style": "default"],
      ],
    ]])
  }

  func saveButton(_ button: String) {
    guard let p = pending else { return }
    pending = nil
    env.call("ui", "set", ["slot": "dialog", "tree": nil])
    switch button {
    case "save":
      let r = env.call("vault", "save", ["capture": p["capture"]])
      toast(r.isErr ? "Couldn't save the password" : "Password saved for " + URLs.host(p.s("origin")), r.isErr ? "sf:exclamationmark.triangle.fill" : "sf:key.fill")
      if sheetOpen { render() }
      refreshKey()
    case "never":
      never.append(p.s("origin"))
      env.call("storage", "set", ["ns": .string(Self.ns), "key": "never", "value": .array(never.map { .string($0) })])
      env.call("vault", "dismiss", ["capture": p["capture"]])
    default:
      env.call("vault", "dismiss", ["capture": p["capture"]])
    }
  }

  // MARK: Passwords sheet

  func open() {
    let r = env.call("vault", "unlock", ["reason": "show your saved passwords"])
    unlockRequest = r.s("request")
  }

  func result(_ v: Value) {
    switch v.s("method") {
    case "unlock":
      guard v.s("request") == unlockRequest else { return }
      unlockRequest = ""
      if v.b("ok") { sheetOpen = true; render() }
    case "copy":
      // What went on the clipboard, and that it won't stay there (VaultService clears it after 60 s).
      toast(v.b("ok") ? Copied.text(copyWhat, "clears in 60 s") : "Password not copied", "sf:doc.on.doc")
    case "fill":
      if !v.b("ok") && v.s("error") != "cancelled" { toast("Couldn't fill the password", "sf:exclamationmark.triangle.fill") }
    default: break
    }
  }

  func render() {
    let accounts = env.call("vault", "accounts").array ?? []
    var rows: [Value] = []
    for a in accounts {
      rows.append(["type": "connectionRow", "id": .string(Self.rowPrefix + a.s("id")), "title": .string(URLs.host(a.s("origin"))),
                    "icon": .string(URLs.favicon(a.s("origin"))), "status": .string(a.s("username").isEmpty ? "(no username)" : a.s("username")),
                    "connected": false, "button": ["title": "Copy", "style": "secondary"],
                    "secondaryButton": ["id": "delete", "title": "Delete", "style": "destructive"]])
    }
    var children: [Value] = []
    if rows.isEmpty {
      children.append(["type": "paragraph", "text": "No saved passwords yet. When you sign in to a site, den offers to save the password here.", "style": "secondary", "icon": "sf:key"])
    } else {
      children.append(["type": "section", "title": .string(rows.count == 1 ? "1 login" : String(rows.count) + " logins"), "children": .array(rows)])
    }
    let status = env.call("vault", "status")
    children.append(["type": "paragraph", "style": "caption", "text": .string(status.s("mode") == "acl"
      ? "Stored in your Keychain. Each password needs Touch ID."
      : "Stored in your login Keychain. den asks for Touch ID before filling or copying any password.")])
    env.call("ui", "set", ["slot": "overlay.passwords", "tree": [
      "type": "sheet", "id": .string(Self.sheetId), "style": "sheet", "title": "Passwords", "subtitle": "Saved by den",
      "icon": "sf:key.fill", "children": .array(children),
    ]])
  }

  func closeSheet() {
    guard sheetOpen else { return }
    sheetOpen = false
    env.call("ui", "set", ["slot": "overlay.passwords", "tree": nil])
    env.call("vault", "lock")
  }

  func action(_ id: String, _ action: String, _ value: Value) {
    if id == Self.saveDialog, action == "button" { return saveButton(value.s("button")) }
    if id == Self.keyButton, action == "click" {
      let w = value.s("webview")
      env.call("vault", "focusLogin", ["webview": .string(w.isEmpty ? page : w)])
      return
    }
    if id == Self.sheetId, action == "dismiss" { return closeSheet() }
    guard sheetOpen, Text.hasPrefix(id, Self.rowPrefix) else { return }
    let account = Text.dropPrefix(id, Self.rowPrefix)
    if action == "click" {
      let a = (env.call("vault", "accounts").array ?? []).first { $0.s("id") == account }
      let user = a?.s("username") ?? ""
      let site = URLs.host(a?.s("origin") ?? "")
      copyWhat = (user.isEmpty ? "password" : "password for " + user) + (site.isEmpty ? "" : " on " + site)
      env.call("vault", "copy", ["account": .string(account)])
    } else if action == "secondary" {
      env.call("vault", "delete", ["account": .string(account)])
      render()
    }
  }

  func toast(_ text: String, _ icon: String) {
    env.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": .string(text), "icon": .string(icon)]])
  }

  // MARK: Commands

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
    let r = env.call("commands", "register", [
      "id": "passwords.open", "title": "Passwords…", "icon": "sf:key.fill", "owner": "passwords",
      "keywords": ["password", "passwords", "login", "keychain", "vault", "credentials"],
    ])
    commandsRegistered = !r.isErr
    return commandsRegistered
  }
}
