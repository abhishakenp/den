import AppKit
import CordisValue
import WebKit

/// Self-contained `--scenario` states for host components (no plugins, no network).
/// Each one renders a small sample sidebar, then shows one component, so `--snapshot` can
/// render it for docs/screenshots and visual checks against docs/reference/arc-ui-spec.md.
@MainActor
public enum HostScenarios {
  /// Names handled here; anything else falls through to the app's own scenarios.
  public static let names: [String] = ["themePicker", "themePickerEmpty", "contextMenu"]

  /// Applies scenario `name`. Returns the window to snapshot, or nil if the name is unknown.
  public static func apply(_ name: String, runtime rt: DenRuntime, appearance: String) -> NSWindow? {
    guard names.contains(name) else { return nil }
    switch name {
    case "themePicker", "themePickerEmpty":
      let empty = name == "themePickerEmpty"
      seedSidebar(rt, appearance: appearance, colors: empty ? [] : accent)
      showContent(rt)
      themePicker(rt, colors: empty ? [] : ["#b98cff", "#ff9fc8"], appearance: appearance)
    case "contextMenu":
      seedSidebar(rt, appearance: appearance)
      showContent(rt)
      rt.call("ui", "set", ["slot": "sidebar.today", "tree": ["type": "list", "id": "today", "children": [
        ["type": "divider", "id": "div", "action": "Clear"], ["type": "newTabRow", "id": "newtab"],
        ["type": "tabRow", "id": "t1", "title": "Example Domain", "icon": "sf:globe", "selected": true, "menu": tabMenu],
        ["type": "tabRow", "id": "t2", "title": "Release notes", "icon": "sf:doc.text"],
      ]]])
      // A native menu is its own window: it can't be rendered with cacheDisplay, so this scenario
      // only opens it (scripts capture den's own windows with `screencapture -l`).
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        guard let row = find("t1", in: rt.ui.sidebarView), let m = row.menu(for: NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!) else { return }
        m.popUp(positioning: nil, at: NSPoint(x: 120, y: 30), in: row)
      }
    default: break
    }
    return rt.window.window
  }

  /// What the `theme` plugin does: open the picker next to the space title and apply every
  /// `change` to the window live.
  static func themePicker(_ rt: DenRuntime, colors: [String], appearance: String) {
    rt.call("ui", "set", ["slot": "popover", "tree": [
      "type": "themePicker", "id": "theme", "anchor": "space-0", "colors": .array(colors.map { .string($0) }),
      "intensity": 0.6, "grain": 0.3, "appearance": .string(appearance == "dark" ? "dark" : "auto"),
    ]])
    rt.host.on("ui.action") { v in
      guard v.str("id") == "theme" else { return }
      switch v.str("action") {
      case "change": rt.call("window", "setTheme", v["value"])
      case "dismiss": rt.call("ui", "set", ["slot": "popover", "tree": nil])
      default: break
      }
    }
  }

  static func showContent(_ rt: DenRuntime) {
    let id = page(rt, id: "t1", title: "Example Domain", body: "This page is local HTML rendered by den's scenario runner, so snapshots never need the network.")
    rt.call("content", "show", ["panes": [.string(id)]])
  }

  static let tabMenu: Value = [
    ["id": "copy", "title": "Copy Link", "icon": "sf:link", "key": "cmd+shift+c"],
    ["id": "duplicate", "title": "Duplicate", "icon": "sf:plus.square.on.square"],
    ["id": "rename", "title": "Rename…", "icon": "sf:pencil"],
    ["separator": true],
    ["id": "pin", "title": "Pin Tab", "icon": "sf:pin", "key": "cmd+d"],
    ["id": "move", "title": "Move to Space", "icon": "sf:arrow.right.square", "items": [
      ["id": "move:personal", "title": "Personal", "icon": "sf:house.fill", "checked": true],
      ["id": "move:work", "title": "Work", "icon": "sf:briefcase.fill"],
      ["separator": true], ["id": "move:new", "title": "New Space…", "icon": "sf:plus"],
    ]],
    ["separator": true],
    ["id": "archive", "title": "Archive Tab", "icon": "sf:archivebox", "key": "cmd+w", "destructive": true],
  ]

  static func find(_ id: String, in v: NSView) -> NodeView? {
    if let n = v as? NodeView, n.nodeId == id { return n }
    for s in v.subviews { if let f = find(id, in: s) { return f } }
    return nil
  }

  // MARK: Sample content

  static let accent = ["#c3b1ff", "#ffb3d1"]

  /// A small sidebar: nav row + URL pill, a space title, a few pinned and today rows.
  static func seedSidebar(_ rt: DenRuntime, appearance: String, colors: [String] = accent) {
    rt.call("window", "setTheme", ["colors": .array(colors.map { .string($0) }), "intensity": 0.6, "grain": 0.3, "appearance": .string(appearance)])
    rt.call("ui", "set", ["slot": "sidebar.header", "tree": ["type": "list", "spacing": 0, "children": [
      ["type": "navBar", "id": "nav", "canGoBack": true, "canGoForward": false, "loading": false],
      ["type": "urlPill", "id": "url", "text": "example.com"],
    ]]])
    rt.call("ui", "set", ["slot": "sidebar.spaceHeader", "tree": ["type": "spaceTitle", "id": "space-0", "title": "Personal", "icon": "sf:house.fill"]])
    let row: (String, String, String, Bool) -> Value = { id, title, icon, sel in
      ["type": "tabRow", "id": .string(id), "title": .string(title), "icon": .string(icon), "selected": .bool(sel)]
    }
    rt.call("ui", "set", ["slot": "sidebar.pinned", "tree": ["type": "list", "id": "pinned", "children": [
      row("p1", "Documentation", "sf:book.closed.fill", false),
      ["type": "folder", "id": "f1", "title": "Reading", "open": true, "children": [row("p2", "The Swift Book", "sf:swift", false)]],
    ]]])
    rt.call("ui", "set", ["slot": "sidebar.today", "tree": ["type": "list", "id": "today", "children": [
      ["type": "divider", "id": "div", "action": "Clear"], ["type": "newTabRow", "id": "newtab"],
      row("t1", "Example Domain", "sf:globe", true), row("t2", "Release notes", "sf:doc.text", false),
      row("t3", "Design review", "sf:paintbrush.pointed.fill", false),
    ]]])
    rt.call("ui", "set", ["slot": "sidebar.footer", "tree": ["type": "row", "id": "footer", "height": 50, "spacing": 2, "children": [
      ["type": "button", "id": "library", "icon": "sf:tray.full", "size": 32], ["type": "spacer"],
      ["type": "spaceIcon", "id": "s0", "icon": "sf:house.fill", "selected": true], ["type": "spaceIcon", "id": "s1", "icon": "sf:briefcase.fill"],
      ["type": "spacer"], ["type": "button", "id": "newSpace", "icon": "sf:plus", "size": 32],
    ]]])
  }

  /// Creates a web view showing local HTML (no network), for content/peek/mini scenarios.
  @discardableResult
  static func page(_ rt: DenRuntime, id: String, title: String, body: String, tint: String = "#f4f1ff") -> String {
    rt.call("webviews", "create", ["id": .string(id)])
    let html = """
      <html><head><title>\(title)</title><style>body{font:16px -apple-system;margin:0;padding:64px 72px;background:\(tint);color:#222}
      h1{font-size:30px;margin:0 0 16px}p{line-height:1.5;max-width:560px;color:#444}</style></head>
      <body><h1>\(title)</h1><p>\(body)</p></body></html>
      """
    rt.webviews.materialize(id)?.loadHTMLString(html, baseURL: URL(string: "https://\(id).example/"))
    return id
  }
}
