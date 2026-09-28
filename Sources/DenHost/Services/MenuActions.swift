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
    case "page.inspector": rt.call("webviews", "inspect", ["id": id])
    case "page.inspectElement": rt.call("webviews", "inspect", ["id": id, "element": true])
    case "page.console": rt.call("webviews", "inspect", ["id": id, "console": true])
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
