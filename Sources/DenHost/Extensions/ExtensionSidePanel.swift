// thin-host: feature-specific, migrate to plugin (whole file)
import CordisValue
import Foundation
import WebKit

/// `chrome.sidePanel` and Firefox's `sidebarAction` in den's web panel column (the `panels`
/// plugin): the extension's page (`side_panel.default_path` / `sidebar_action.default_panel`, or
/// what it set) opens as a panel with the extension's icon in the panel switcher, beside every
/// tab, like Chrome's side panel. `setPanelBehavior {openPanelOnActionClick}` makes the
/// extension's toolbar button open it. Options are kept per extension in `apis.json` (an
/// extension sets them once, often at install); per-tab options live while den runs.
@MainActor
final class ExtensionSidePanel {
  struct Options: Equatable {
    var path: String?
    var enabled = true
    var openOnAction = false
    var title: String?
  }

  let call: (String, String, Value) -> Value
  /// Persisted options by extension id (`ExtensionAPIs` stores them).
  var options: [String: Options] = [:]
  var tabOptions: [String: [Int64: Options]] = [:]
  var save: () -> Void = {}
  /// `panels.shown` / `panels.hidden` → `onOpened` / `onClosed` (set by `ExtensionAPIs`).
  var emit: (String, [Value], String) -> Void = { _, _, _ in }

  init(call: @escaping (String, String, Value) -> Value) { self.call = call }

  static func defaultPath(_ ext: WKWebExtension) -> String? {
    if let p = (ext.manifest["side_panel"] as? [String: Any])?["default_path"] as? String { return p }
    if let p = (ext.manifest["sidebar_action"] as? [String: Any])?["default_panel"] as? String { return p }
    return nil
  }

  func current(_ ctx: WKWebExtensionContext, tab: Int64? = nil) -> Options {
    var o = options[ctx.uniqueIdentifier] ?? Options()
    if o.path == nil { o.path = Self.defaultPath(ctx.webExtension) }
    if let tab, let t = tabOptions[ctx.uniqueIdentifier]?[tab] {
      if let p = t.path { o.path = p }
      o.enabled = t.enabled
    }
    return o
  }

  func url(_ ctx: WKWebExtensionContext, _ path: String) -> String {
    if path.hasPrefix("webkit-extension://") { return path }
    let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
    return ctx.baseURL.absoluteString + clean
  }

  /// Whether a click on the extension's toolbar button opens its panel instead of the action.
  func opensOnAction(_ ctx: WKWebExtensionContext) -> Bool {
    let o = current(ctx)
    return o.openOnAction && o.enabled && o.path != nil
  }

  func open(_ ctx: WKWebExtensionContext, icon: String, tab: Int64? = nil) -> Value {
    let o = current(ctx, tab: tab)
    guard let path = o.path, o.enabled else { return .error("No active side panel for the extension.") }
    let name = o.title ?? ctx.webExtension.displayName ?? "Extension"
    let r = call("panels", "showPage", ["owner": .string(ctx.uniqueIdentifier), "url": .string(url(ctx, path)), "title": .string(name), "icon": .string(icon)])
    return r.isError ? .error("den’s web panels are turned off") : .null
  }

  func isOpen(_ ctx: WKWebExtensionContext) -> Bool { call("panels", "state", .null)["owner"].string == ctx.uniqueIdentifier }

  func close(_ ctx: WKWebExtensionContext) -> Value {
    _ = call("panels", "hidePage", ["owner": .string(ctx.uniqueIdentifier)])
    return .null
  }

  // MARK: chrome.sidePanel

  func handle(_ method: String, _ args: [Value], ctx: WKWebExtensionContext, icon: String) -> Value {
    let a = args.first ?? .null
    let id = ctx.uniqueIdentifier
    switch method {
    case "setOptions":
      if let tab = a["tabId"].int {
        var t = tabOptions[id]?[tab] ?? current(ctx)
        if let p = a["path"].string { t.path = p }
        if let e = a["enabled"].bool { t.enabled = e }
        tabOptions[id, default: [:]][tab] = t
      } else {
        var o = options[id] ?? Options()
        if let p = a["path"].string { o.path = p }
        if let e = a["enabled"].bool { o.enabled = e }
        options[id] = o
        save()
      }
      // A panel on screen follows a new page, and goes when disabled.
      if isOpen(ctx) {
        let now = current(ctx, tab: a["tabId"].int)
        if !now.enabled { return close(ctx) }
        if a["path"].string != nil { return open(ctx, icon: icon, tab: a["tabId"].int) }
      }
      return .null
    case "getOptions":
      let o = current(ctx, tab: a["tabId"].int)
      var v: Value = ["enabled": .bool(o.enabled)]
      if let p = o.path { v = v.with("path", .string(p)) }
      if let t = a["tabId"].int { v = v.with("tabId", .int(t)) }
      return v
    case "setPanelBehavior":
      var o = options[id] ?? Options()
      if let b = a["openPanelOnActionClick"].bool { o.openOnAction = b }
      options[id] = o
      save()
      return .null
    case "getPanelBehavior": return ["openPanelOnActionClick": .bool(current(ctx).openOnAction)]
    case "open": return open(ctx, icon: icon, tab: a["tabId"].int)
    case "close": return close(ctx)
    case "getLayout": return ["side": "left"]
    default: return .error("sidePanel.\(method) isn’t available in den")
    }
  }

  // MARK: browser.sidebarAction (Firefox)

  func sidebarAction(_ method: String, _ args: [Value], ctx: WKWebExtensionContext, icon: String) -> Value {
    let a = args.first ?? .null
    let id = ctx.uniqueIdentifier
    switch method {
    case "open": return open(ctx, icon: icon)
    case "close": return close(ctx)
    case "toggle": return isOpen(ctx) ? close(ctx) : open(ctx, icon: icon)
    case "isOpen": return .bool(isOpen(ctx))
    case "setPanel":
      var o = options[id] ?? Options()
      o.path = a["panel"].string
      options[id] = o
      save()
      return isOpen(ctx) ? open(ctx, icon: icon) : .null
    case "getPanel": return current(ctx).path.map { .string(url(ctx, $0)) } ?? .null
    case "setTitle":
      var o = options[id] ?? Options()
      o.title = a["title"].string
      options[id] = o
      save()
      return .null
    case "getTitle":
      let def = (ctx.webExtension.manifest["sidebar_action"] as? [String: Any])?["default_title"] as? String
      return .string(current(ctx).title ?? def ?? ctx.webExtension.displayName ?? "")
    case "setIcon": return .null
    default: return .error("sidebarAction.\(method) isn’t available in den")
    }
  }

  // MARK: Persistence (inside apis.json)

  func value() -> Value {
    .object(options.keys.sorted().map { k in
      let o = options[k]!
      return (k, ["path": .maybe(o.path), "enabled": .bool(o.enabled), "openOnAction": .bool(o.openOnAction), "title": .maybe(o.title)])
    })
  }

  func restore(_ v: Value) {
    for (k, o) in v.object ?? [] {
      options[k] = Options(path: o["path"].string, enabled: o.flag("enabled", true), openOnAction: o.flag("openOnAction"), title: o["title"].string)
    }
  }
}

extension Value {
  static func maybe(_ s: String?) -> Value { s.map { .string($0) } ?? .null }
}
