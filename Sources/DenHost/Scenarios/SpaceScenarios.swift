// Dev fixture: compiled only with the `Scenarios` package trait (on by default; release bundles leave it out).
#if Scenarios
import AppKit
import CordisValue

/// `--scenario` states for the space context menu, icon picker, inline rename and the footer's
/// live drag-reorder. They drive the real `spaces` plugin (run with the bundled plugins).
@MainActor
public enum SpaceScenarios {
  public static let names = ["spaceMenu", "spaceIconPicker", "spaceRename", "spaceReorder", "tabEmojiIcons", "tabIconPicker"]

  /// Settings window sections (with the bundled plugins): `settings` (General), `settingsTabs`, …
  public static let settingsNames = ["settings": "general", "settingsTabs": "tabs", "settingsSearch": "commandbar",
                                     "settingsConnections": "connections", "settingsBriefing": "briefing"]

  /// Theme samples for the theming grid: `themeSample:<theme>:<surface>`.
  public static let sampleThemes: [String: [String: Value]] = [
    "sandy": ["colors": ["#E8D5B0", "#D9BF8C"], "intensity": 0.75, "grain": 0.8],
    "purple": ["colors": ["#4B2A7B", "#2D1B4E"], "intensity": 0.85, "grain": 0.2],
    "nearBlack": ["colors": ["#141414", "#0A0A0A"], "intensity": 1.0, "grain": 0.1],
    "pastel": ["colors": ["#FBEAF3", "#E0F2FB"], "intensity": 0.6, "grain": 0.3],
  ]

  public static func apply(_ name: String, runtime rt: DenRuntime) -> NSWindow? {
    if let section = settingsNames[name] {
      // Let the plugins register, then open Settings at that section and snapshot its window.
      rt.call("settings", "open", ["section": .string(section)])
      // `cacheDisplay` draws this window's content blank, so scripts/snapshots.sh captures it
      // on screen by window id (like native menus); `--snapshot` still works for the main window.
      return rt.settings.window?.window
    }
    if name.hasPrefix("themeSample:") { return themeSample(name, rt) }
    if name.hasPrefix("favorites:"), let n = Int(name.dropFirst(10)) { return favorites(n, rt) }
    guard names.contains(name) else { return nil }
    let w = rt.window.window
    guard let sid = rt.call("spaces", "current")["id"].string else { return w }
    let icon = "spaces.icon:" + sid
    switch name {
    case "spaceMenu":
      // A native menu is its own window (scripts/snapshots.sh captures it with screencapture -l).
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        guard let v = HostScenarios.find(icon, in: rt.ui.sidebarView),
              let m = v.menu(for: NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!) else { return }
        m.popUp(positioning: nil, at: NSPoint(x: v.bounds.midX, y: 0), in: v)
      }
    case "spaceIconPicker":
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { rt.plugins.emit("ui.action", ["id": .string(icon), "action": "menu", "value": "icon"]) }
    case "tabEmojiIcons", "tabIconPicker":
      // Emoji icons on a Today tab, a pinned tab and the pinned folder (the `tabs` plugin's
      // setIcon, the same path as the picker); `tabIconPicker` then opens the picker on a Today tab.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        let l = rt.call("tabs", "list")
        let today = (l["today"].array ?? []).filter { $0["folder"].isNull && $0["split"].isNull }
        let pinned = l["pinned"].array ?? []
        if let t = today.first { rt.call("tabs", "setIcon", ["id": t["id"], "icon": "🚀"]) }
        if let f = pinned.first(where: { $0["folder"] == true }) { rt.call("tabs", "setIcon", ["id": f["id"], "icon": "📚"]) }
        if let p = pinned.first(where: { $0["folder"].isNull && $0["split"].isNull }) { rt.call("tabs", "setIcon", ["id": p["id"], "icon": "🎧"]) }
        if name == "tabIconPicker", today.count > 1 {
          rt.plugins.emit("ui.action", ["id": today[1]["id"], "action": "menu", "value": "changeIcon"])
        }
      }
    case "spaceRename":
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { rt.plugins.emit("ui.action", ["id": .string("spaces.title:" + sid), "action": "menu", "value": "rename"]) }
    case "spaceReorder":
      // Mid-drag: the first icon lifted and carried over the second, which has slid aside.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        let icons = (HostScenarios.find("spaces.footer", in: rt.ui.sidebarView)?.subviews ?? []).compactMap { $0 as? SpaceIconNode }.sorted { $0.frame.minX < $1.frame.minX }
        guard icons.count > 1 else { return }
        let a = icons[0], pitch = icons[1].frame.minX - icons[0].frame.minX
        func ev(_ t: NSEvent.EventType, _ dx: CGFloat) -> NSEvent {
          NSEvent.mouseEvent(with: t, location: a.convert(NSPoint(x: a.bounds.midX + dx, y: a.bounds.midY), to: nil), modifierFlags: [], timestamp: 0,
                             windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        a.mouseDown(with: ev(.leftMouseDown, 0))
        a.mouseDragged(with: ev(.leftMouseDragged, 6))
        a.mouseDragged(with: ev(.leftMouseDragged, pitch * 0.8))
      }
    default: break
    }
    return w
  }

  /// `favorites:<n>`: exactly n favorites (1–12) through the tabs plugin's own calls, to show how
  /// the grid fills the sidebar width (1 full width, 2 halves, … 5 = 4 + 1).
  static func favorites(_ n: Int, _ rt: DenRuntime) -> NSWindow? {
    let sites = ["github.com", "mail.google.com", "calendar.google.com", "youtube.com", "news.ycombinator.com", "webkit.org",
                 "swift.org", "developer.apple.com", "linear.app", "figma.com", "wikipedia.org", "notion.so"]
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      let have = (rt.call("tabs", "list")["favorites"].array ?? []).compactMap { $0["id"].string }
      // Closing a favorite only unloads it: move it to Today first, then close (archive) it.
      for id in have.dropFirst(max(0, n)) {
        rt.call("tabs", "unpin", ["id": .string(id)])
        rt.call("tabs", "close", ["id": .string(id)])
      }
      if have.count < n {
        for s in sites.prefix(n).dropFirst(have.count) {
          rt.call("tabs", "open", ["url": .string("https://" + s + "/"), "kind": "favorite", "background": true])
        }
      }
    }
    return rt.window.window
  }

  /// `themeSample:<theme>:<surface>`: every space gets the theme (appearance from --appearance), then
  /// one surface opens through its real path: `alert`, `confirm` (a page's JS dialogs), `quit` (the
  /// quit plugin), `command` (the command bar), `toast` and `hover` (a hover card).
  static func themeSample(_ name: String, _ rt: DenRuntime) -> NSWindow? {
    let parts = name.split(separator: ":").map(String.init)
    guard parts.count == 3, let theme = sampleThemes[parts[1]] else { return nil }
    for s in rt.call("spaces", "list").array ?? [] {
      rt.call("spaces", "update", ["id": s["id"], "theme": .object(theme.map { ($0.key, $0.value) })])
    }
    let w = rt.window.window
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
      switch parts[2] {
      case "alert", "confirm":
        // The page's own dialog path (WebPrompts) on the selected tab, in the sample theme.
        let id = rt.call("content", "get")["focus"].string ?? rt.call("content", "get").list("panes").first?.string ?? ""
        guard let web = rt.webviews.record(id)?.webView, let prompts = rt.webviews.prompts else { return }
        if parts[2] == "alert" {
          prompts.alert("Your changes were saved.", frame: nil, webView: web) {}
        } else {
          prompts.confirm("Leave this page? Changes you made may not be saved.", frame: nil, webView: web) { _ in }
        }
      case "quit": rt.plugins.emit("app.quitRequested")
      case "command": rt.call("commands", "open", ["mode": "new", "query": "swi"])
      case "toast":
        rt.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": "Cleared Tabs! Use ⌃Z to undo.", "icon": "sf:arrow.uturn.backward", "duration": 60000]])
      case "hover": _ = PreviewScenarios.apply("prFailing", runtime: rt, appearance: "")
      default: break
      }
    }
    return w
  }
}
#endif
