import AppKit
import CordisValue
import UniformTypeIdentifiers
import WebKit

/// What den's menu bar host items do (`MainMenu.handler`). Page actions act on the focused pane's
/// web view and go through the `webviews` service, so plugins and the menu share one path.
// thin-host: feature-specific, migrate to plugin (help links, the page-action mapping)
@MainActor
enum MenuActions {
  static let repo = "https://github.com/abhishakenp/den"

  static func install(_ rt: DenRuntime) {
    MainMenu.handler = { [weak rt] a in if let rt { perform(a, rt) } }
    MainMenu.canPerform = { [weak rt] a in
      guard let rt else { return false }
      // Reopen Closed Window: only when the tabs plugin has one to bring back.
      if a == "window.reopen" { return rt.call("tabs", "closedWindows")["count"].int ?? 0 > 0 }
      return a.hasPrefix("page.") ? focusedWebView(rt) != nil : true
    }
    MainMenu.runCommand = { [weak rt] id in _ = rt?.call("commands", "run", ["id": .string(id)]) }
    MainMenu.commandAvailable = { [weak rt] id in
      (rt?.call("commands", "list").array ?? []).contains { $0.str("id") == id }
    }
    MainMenu.itemState = { [weak rt] a in
      guard let rt else { return nil }
      switch a {
      case "page.inspector":
        let open = focusedWebView(rt).flatMap { rt.webviews.record($0)?.webView }.map(DevTools.isOpen) ?? false
        return (open ? "Close Web Inspector" : "Show Web Inspector", false)
      case "develop.disableCaches": return (nil, rt.webviews.cachesDisabled)
      default: return nil
      }
    }
    MainMenu.fillSubmenu = { [weak rt] id, menu in if let rt { DevelopMenu.fill(id, menu, rt) } }
  }

  /// The web view whose page the menu acts on: the focused pane of what's shown.
  static func focusedWebView(_ rt: DenRuntime) -> String? {
    let c = rt.call("content", "get")
    if let peek = c["peek"].string, !peek.isEmpty { return peek }
    if let f = c["focus"].string, !f.isEmpty { return f }
    return c.list("panes").first?.string
  }

  static func perform(_ a: String, _ rt: DenRuntime) {
    let id: Value = focusedWebView(rt).map { .string($0) } ?? .null
    switch a {
    case "app.about": AboutPanel.shared.show(nil)  // the app service keeps its credits (`app.about`)
    case "app.settings": rt.settings.open()
    case "app.defaultBrowser": rt.call("app", "setDefaultBrowser")
    // Windows are host capabilities; what they show is up to the tabs plugin (window.opened).
    case "window.new": rt.call("window", "new")
    case "window.newPrivate": rt.call("window", "new", ["private": true])
    case "window.reopen": rt.host.emit("window.reopen")
    case "page.zoomIn": rt.call("webviews", "zoom", ["id": id, "action": "in"])
    case "page.zoomOut": rt.call("webviews", "zoom", ["id": id, "action": "out"])
    case "page.zoomReset": rt.call("webviews", "zoom", ["id": id, "action": "reset"])
    case "page.find": rt.call("webviews", "find", ["id": id, "action": "show"])
    case "page.findNext": rt.call("webviews", "find", ["id": id, "action": "next"])
    case "page.findPrevious": rt.call("webviews", "find", ["id": id, "action": "previous"])
    case "page.findSelection": rt.call("webviews", "find", ["id": id, "action": "selection"])
    case "page.print": rt.call("webviews", "print", ["id": id])
    case "page.reloadFromOrigin": rt.call("webviews", "reload", ["id": id, "fromOrigin": true])
    case "page.viewSource": rt.call("webviews", "viewSource", ["id": id])
    case "page.inspector": rt.call("webviews", "inspect", ["id": id, "action": "toggle"])
    case "page.inspectElement": rt.call("webviews", "inspect", ["id": id, "action": "element"])
    case "page.console": rt.call("webviews", "inspect", ["id": id, "action": "console"])
    case "develop.emptyCaches": rt.call("webviews", "caches", ["action": "empty"])
    case "develop.disableCaches": rt.call("webviews", "caches", ["action": rt.webviews.cachesDisabled ? "enable" : "disable"])
    case "page.save": savePage(rt, id.string)
    case "help.site": open(repo)
    case "help.shortcuts": open(repo + "/blob/main/docs/shortcuts.md")
    case "help.issue": open(repo + "/issues/new")
    default: break
    }
  }

  static func open(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }

  /// Save Page As… (⇧⌘S): the page as a Web Archive, through a save sheet on den's window.
  static func savePage(_ rt: DenRuntime, _ id: String?) {
    guard let id, let web = rt.webviews.record(id)?.webView else { NSSound.beep(); return }
    savePage(web)
  }

  /// Save Page As… for one page (the menu bar's, or the page's context menu).
  static func savePage(_ web: WKWebView) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType.webArchive]
    let title = (web.title ?? "").trimmingCharacters(in: .whitespaces)
    panel.nameFieldStringValue = (title.isEmpty ? (web.url?.host() ?? "Page") : title).replacingOccurrences(of: "/", with: "-") + ".webarchive"
    let done: (NSApplication.ModalResponse) -> Void = { r in
      guard r == .OK, let url = panel.url else { return }
      web.createWebArchiveData { result in
        if case let .success(data) = result { try? data.write(to: url, options: .atomic) }
      }
    }
    if let w = web.window ?? NSApp.keyWindow { panel.beginSheetModal(for: w, completionHandler: done) } else { done(panel.runModal()) }
  }
}

/// Develop ▸ User Agent and ▸ Web Extension Background Content, built each time they open.
@MainActor
final class DevelopMenu: NSObject {
  static let shared = DevelopMenu()
  weak var rt: DenRuntime?

  static func fill(_ id: String, _ menu: NSMenu, _ rt: DenRuntime) {
    shared.rt = rt
    switch id {
    case "develop.userAgent":
      let page = MenuActions.focusedWebView(rt)
      let current = page.map { rt.call("webviews", "userAgent", ["id": .string($0)]).str("preset") } ?? "default"
      func add(_ title: String, _ preset: String) {
        let mi = NSMenuItem(title: title, action: page == nil ? nil : #selector(DevelopMenu.pickAgent(_:)), keyEquivalent: "")
        mi.target = shared
        mi.representedObject = preset
        mi.state = current == preset ? .on : .off
        menu.addItem(mi)
      }
      add("Default (Automatically Chosen)", "default")
      menu.addItem(.separator())
      for a in DevTools.agents { add(a.title, a.id) }
      if current == "other" {
        menu.addItem(.separator())
        add("Other", "other")
      }
    case "develop.extensions":
      let list = rt.extensions.inspectables()
      if list.isEmpty {
        let mi = NSMenuItem(title: "No Extensions Loaded", action: nil, keyEquivalent: "")
        mi.isEnabled = false
        menu.addItem(mi)
      }
      for e in list {
        let mi = NSMenuItem(title: e.name, action: e.live ? #selector(DevelopMenu.inspectExtension(_:)) : nil, keyEquivalent: "")
        mi.target = shared
        mi.representedObject = e.id
        if !e.live { mi.toolTip = "No background page running (a service worker background is inspectable from Safari's Develop menu)" }
        menu.addItem(mi)
      }
    default: break
    }
  }

  @objc func pickAgent(_ sender: NSMenuItem) {
    guard let rt, let preset = sender.representedObject as? String, preset != "other", let page = MenuActions.focusedWebView(rt) else { return }
    rt.call("webviews", "userAgent", ["id": .string(page), "ua": .string(preset)])
  }

  @objc func inspectExtension(_ sender: NSMenuItem) {
    guard let rt, let id = sender.representedObject as? String else { return }
    rt.call("webext", "inspect", ["id": .string(id)])
  }
}
