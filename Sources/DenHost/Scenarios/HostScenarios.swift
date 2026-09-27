import AppKit
import CordisValue
import WebKit

/// Self-contained `--scenario` states for host components (no plugins, no network).
/// Each one renders a small sample sidebar, then shows one component, so `--snapshot` can
/// render it for docs/screenshots and visual checks against docs/reference/arc-ui-spec.md.
@MainActor
public enum HostScenarios {
  /// Names handled here; anything else falls through to the app's own scenarios.
  public static let names: [String] = ["themePicker", "themePickerEmpty", "contextMenu", "dialogQuit", "dialogDeleteSpace", "dialogDeleteFolder", "dialogClearArchive", "littleArc", "library", "libraryClear", "splitView", "dropIndicator", "peekCard", "briefingSheet", "connectionsSheet", "findBar", "dropOnTab", "tabAudio", "iconFallbacks"]

  /// Applies scenario `name`. Returns the window to snapshot, or nil if the name is unknown.
  public static func apply(_ name: String, runtime rt: DenRuntime, appearance: String) -> NSWindow? {
    if let w = commandBar(name, runtime: rt) { return w }
    if let w = launcher(name, runtime: rt) { return w }
    if ExtensionScenarios.names.contains(name) {
      ExtensionScenarios.apply(name, runtime: rt)
      return rt.window.window
    }
    if ConnectionScenarios.names.contains(name) {
      ConnectionScenarios.apply(name, runtime: rt)
      return rt.window.window
    }
    if VaultScenarios.names.contains(name) {
      VaultScenarios.apply(name, runtime: rt)
      return rt.window.window
    }
    if let w = PreviewScenarios.apply(name, runtime: rt, appearance: appearance) { return w }
    if let w = SpaceScenarios.apply(name, runtime: rt) { return w }
    if let w = PromptScenarios.apply(name, runtime: rt, appearance: appearance) { return w }
    guard names.contains(name) else { return nil }
    switch name {
    case "themePicker", "themePickerEmpty":
      let empty = name == "themePickerEmpty"
      seedSidebar(rt, appearance: appearance, colors: empty ? [] : accent)
      showContent(rt)
      themePicker(rt, colors: empty ? [] : ["#b98cff", "#ff9fc8"], appearance: appearance)
    case "dialogQuit", "dialogDeleteSpace", "dialogDeleteFolder", "dialogClearArchive":
      seedSidebar(rt, appearance: appearance)
      showContent(rt)
      rt.call("ui", "set", ["slot": "dialog", "tree": dialogs[name]!])
    case "peekCard":
      seedSidebar(rt, appearance: appearance)
      showContent(rt)
      let id = page(rt, id: "peeked", title: "Swift.org", host: "swift.org", body: "A cross-site link from a pinned tab opens in Peek. Expand it into a tab, open it in a split, or press Esc.", tint: "#fff7f2")
      rt.call("content", "peek", ["webview": .string(id), "title": "swift.org"])
    case "splitView":
      seedSidebar(rt, appearance: appearance)
      let a = page(rt, id: "t1", title: "Example Domain", body: "Left pane.")
      let b = page(rt, id: "t2", title: "Release notes", body: "Right pane, focused: the ring follows the space color.", tint: "#fff6f0")
      rt.call("content", "show", ["panes": [.string(a), .string(b)], "orientation": "horizontal", "focus": .string(b)])
      rt.window.contentArea.layoutSubtreeIfNeeded()
      rt.content.card(b)?.setControlsVisible(true)
    case "dropOnTab":
      // Drag "Design review" onto the middle of "Example Domain": the row rings, with the split hint.
      seedSidebar(rt, appearance: appearance)
      showContent(rt)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        let w = rt.window.window
        rt.window.root.layoutSubtreeIfNeeded()
        guard let src = find("t3", in: rt.ui.sidebarView) as? HoverNode, let dst = find("t1", in: rt.ui.sidebarView) as? HoverNode else { return }
        func ev(_ t: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
          NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let start = src.convert(NSPoint(x: src.bounds.midX, y: src.bounds.midY), to: nil)
        let end = dst.convert(NSPoint(x: dst.bounds.midX - 30, y: dst.bounds.midY), to: nil)
        rt.ui.drag.begin(src, event: ev(.leftMouseDown, start))
        rt.ui.drag.move(ev(.leftMouseDragged, end))
      }
    case "tabAudio":
      // Speaker controls: a row playing audio (hovered), a muted row, and favorite tiles with badges.
      seedSidebar(rt, appearance: appearance)
      showContent(rt)
      rt.call("ui", "set", ["slot": "sidebar.favorites", "tree": ["type": "grid", "id": "favs", "children": [
        ["type": "favoriteTile", "id": "f1", "icon": "sf:play.rectangle.fill", "title": "YouTube", "audio": true],
        ["type": "favoriteTile", "id": "f2", "icon": "sf:music.note", "title": "Music", "audio": true, "muted": true],
        ["type": "favoriteTile", "id": "f3", "icon": "sf:envelope.fill", "title": "Mail"],
        ["type": "favoriteTile", "id": "f4", "icon": "sf:calendar", "title": "Calendar"],
      ]]])
      rt.call("ui", "set", ["slot": "sidebar.today", "tree": ["type": "list", "id": "today", "children": [
        ["type": "divider", "id": "div", "action": "Clear"], ["type": "newTabRow", "id": "newtab"],
        ["type": "tabRow", "id": "t1", "title": "YouTube", "icon": "sf:play.rectangle.fill", "selected": true, "audio": true],
        ["type": "tabRow", "id": "t2", "title": "Podcast episode 42", "icon": "sf:mic.fill", "audio": true, "muted": true],
        ["type": "tabRow", "id": "t3", "title": "Design review", "icon": "sf:paintbrush.pointed.fill"],
      ]]])
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        rt.window.root.layoutSubtreeIfNeeded()
        guard let row = find("t2", in: rt.ui.sidebarView) as? TabRowNode else { return }
        row.hovering = true
        row.hoverChanged()
        row.layoutSubtreeIfNeeded()
        row.audio.hovering = true
      }
    case "dropIndicator":
      seedSidebar(rt, appearance: appearance)
      showContent(rt)
      // Drag "Release notes" from the sidebar over the right third of the content.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        let w = rt.window.window
        rt.window.root.layoutSubtreeIfNeeded()
        guard let row = find("t2", in: rt.ui.sidebarView) as? HoverNode else { return }
        let start = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        let cf = rt.window.contentArea.convert(rt.window.contentArea.bounds, to: nil)
        let end = NSPoint(x: cf.minX + cf.width * 0.85, y: cf.midY)
        func ev(_ t: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
          NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        rt.ui.drag.begin(row, event: ev(.leftMouseDown, start))
        rt.ui.drag.move(ev(.leftMouseDragged, end))
      }
    case "library", "libraryClear":
      seedSidebar(rt, appearance: appearance)
      showContent(rt)
      rt.call("ui", "set", ["slot": "overlay.library", "tree": ["type": "library", "id": "archive", "items": archiveItems()]])
      if name == "libraryClear" { rt.call("ui", "set", ["slot": "dialog", "tree": dialogs["dialogClearArchive"]!]) }
    case "findBar":
      // ⌘F on a page: the find bar at the card's top right, second of three matches selected.
      seedSidebar(rt, appearance: appearance)
      let id = page(rt, id: "t1", title: "Example Domain", body: "This domain is for use in documentation examples. You may use this domain in examples without asking. Every domain here is local HTML.")
      rt.call("content", "show", ["panes": [.string(id)]])
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        rt.call("webviews", "find", ["action": "show", "query": "domain"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { rt.call("webviews", "find", ["action": "next"]) }
      }
    case "briefingSheet", "connectionsSheet":
      seedSidebar(rt, appearance: appearance)
      showContent(rt)
      rt.call("ui", "set", ["slot": "overlay.briefing", "tree": briefingTree()])
      if name == "connectionsSheet" { rt.call("ui", "set", ["slot": "overlay.connections", "tree": connectionsTree]) }
    case "littleArc":
      seedSidebar(rt, appearance: appearance)
      showContent(rt)
      let id = page(rt, id: "mini", title: "Example Domain", host: "example.com",
                    body: "Links from other apps open here, in a small floating window. Open it in a space with ⌘O.")
      let r = rt.call("window", "openMini", ["webview": .string(id), "space": "Personal"])
      return rt.windowService.mini.windows[r.str("id")]?.panel
    case "iconFallbacks":
      // Pages without a usable favicon or title: `site:` letter tiles and globe tiles, with the
      // titles `URLs.title` gives (what the tabs plugin sends for these URLs).
      seedSidebar(rt, appearance: appearance)
      showContent(rt)
      iconFallbacks(rt)
      // The built-in tabs plugin renders its own sidebar once loaded: draw ours again after it.
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { iconFallbacks(rt) }
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

  /// Sidebar rows for pages without a usable favicon or title (`iconFallbacks`).
  static func iconFallbacks(_ rt: DenRuntime) {
    let tile: (String, String) -> Value = { id, icon in ["type": "favoriteTile", "id": .string(id), "icon": .string(icon), "title": .string(id)] }
    rt.call("ui", "set", ["slot": "sidebar.favorites", "tree": ["type": "grid", "id": "favs", "children": [
      tile("linear.app", "site:linear.app"), tile("figma.com", "site:figma.com"), tile("notion.so", "site:notion.so"), tile("Untitled", "site:"),
    ]]])
    rt.call("ui", "set", ["slot": "sidebar.header", "tree": ["type": "list", "spacing": 0, "children": [
      ["type": "navBar", "id": "nav", "canGoBack": false, "canGoForward": false, "loading": false],
      ["type": "urlPill", "id": "url", "text": "data:text/html"],
    ]]])
    let row: (String, String, String, Bool) -> Value = { id, title, icon, sel in
      ["type": "tabRow", "id": .string(id), "title": .string(title), "icon": .string(icon), "selected": .bool(sel)]
    }
    rt.call("ui", "set", ["slot": "sidebar.today", "tree": ["type": "list", "id": "today", "children": [
      ["type": "divider", "id": "div", "action": "Clear"], ["type": "newTabRow", "id": "newtab"],
      row("t1", "Untitled", "site:", true),
      row("t2", "news.ycombinator.com", "site:news.ycombinator.com", false),
      row("t3", "My Notes.html", "site:", false),
      row("t4", "localhost", "site:localhost", false),
      row("t5", "Image", "site:", false),
      ["type": "splitRow", "id": "s1", "layout": "horizontal", "panes": [
        ["id": "s1a", "title": "example.com", "icon": "site:example.com"], ["id": "s1b", "title": "swift.org", "icon": "site:swift.org"],
      ]],
      row("t6", "Stripe Dashboard", "site:dashboard.stripe.com", false),
      row("t7", "github.com", "site:github.com", false),
    ]]])
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

  /// The dialog variants plugins show (den's own wording; layout per spec §5).
  static let dialogs: [String: Value] = [
    "dialogQuit": ["type": "dialog", "id": "quit", "icon": "app:icon", "title": "Quit den?", "buttons": [
      ["id": "always", "title": "Quit, and don’t ask again", "style": "secondary"],
      ["id": "cancel", "title": "Cancel", "style": "cancel"], ["id": "quit", "title": "Quit", "style": "default"],
    ]],
    "dialogDeleteSpace": ["type": "dialog", "id": "deleteSpace", "icon": "sf:trash", "iconStyle": "destructive",
      "title": "Delete the “Personal” space?", "message": "Its tabs and folders move to the Archive. You can undo this with ⌘Z.",
      "buttons": [["id": "cancel", "title": "Cancel", "style": "cancel"], ["id": "delete", "title": "Delete Space", "style": "destructive", "default": true]]],
    "dialogDeleteFolder": ["type": "dialog", "id": "deleteFolder", "icon": "sf:folder.badge.minus", "iconStyle": "destructive",
      "title": "Delete the “Reading” folder?", "message": "The tabs inside it move to the Archive.",
      "buttons": [["id": "cancel", "title": "Cancel", "style": "cancel"], ["id": "delete", "title": "Delete Folder", "style": "destructive", "default": true]]],
    "dialogClearArchive": ["type": "dialog", "id": "clearArchive", "icon": "sf:archivebox", "iconStyle": "destructive",
      "title": "Clear the Archive?", "message": "Every archived tab is removed for good. This can’t be undone.",
      "buttons": [["id": "cancel", "title": "Cancel", "style": "cancel"], ["id": "clear", "title": "Clear Archive", "style": "destructive", "default": true]]],
  ]

  /// Sample archive entries in the `tabs.archive` shape, closed over the last few days.
  static func archiveItems(now: Date = Date()) -> Value {
    let h = 3_600_000.0, t = now.timeIntervalSince1970 * 1000
    let entries: [(String, String, String, Double)] = [
      ("Release notes", "https://www.swift.org/blog/", "sf:swift", 0.4), ("Hacker News", "https://news.ycombinator.com", "sf:newspaper", 1.5),
      ("WebKit Features in Safari", "https://webkit.org/blog/", "sf:safari", 3), ("Design review notes", "https://linear.app/team/issue", "sf:doc.text", 26),
      ("Swift Forums", "https://forums.swift.org", "sf:bubble.left.and.bubble.right", 28), ("MDN Web Docs", "https://developer.mozilla.org", "sf:book", 75),
      ("The Verge", "https://www.theverge.com", "sf:globe", 200),
    ]
    return .array(entries.enumerated().map { i, e in
      ["id": .string("arch-\(i)"), "title": .string(e.0), "url": .string(e.1), "icon": .string(e.2), "closedAt": .double(t - e.3 * h)]
    })
  }

  static let slackIcon = "sf:number", githubIcon = "sf:chevron.left.forwardslash.chevron.right"

  /// A sample briefing page, the shape the `briefing` plugin sends (static text, no network).
  static func briefingTree(now: Date = Date()) -> Value {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "EEEE, MMMM d"
    let ai = NSImage(systemSymbolName: "apple.intelligence", accessibilityDescription: nil) != nil ? "sf:apple.intelligence" : "sf:sparkles"
    let todo: (String, String, String, String, Bool) -> Value = { id, title, sub, icon, done in
      ["type": "todoRow", "id": .string(id), "title": .string(title), "subtitle": .string(sub), "icon": .string(icon), "done": .bool(done)]
    }
    let feed: (String, String, String, String, String, String, Bool) -> Value = { id, title, sub, icon, time, badge, unread in
      ["type": "feedRow", "id": .string(id), "title": .string(title), "subtitle": .string(sub), "icon": .string(icon),
       "time": .string(time), "badge": .string(badge), "unread": .bool(unread)]
    }
    return ["type": "sheet", "id": "briefing", "style": "page", "title": "Briefing", "icon": "sf:sun.horizon",
      "headerButtons": [["id": "briefing.refresh", "icon": "sf:arrow.clockwise", "tooltip": "Refresh"],
                        ["id": "briefing.settings", "icon": "sf:gearshape", "tooltip": "Connections"]],
      "children": [
        ["type": "heading", "id": "hello", "text": "Good morning", "subtitle": .string(f.string(from: now))],
        ["type": "paragraph", "id": "summary", "icon": .string(ai),
         "text": "Two pull requests are waiting on your review, and CI is red on “Fix login redirect”. In Slack, Maya asked about the launch checklist in a DM and Jon mentioned you in #design about the new icons."],
        ["type": "section", "id": "todos", "title": "To do", "accessory": "3 open", "children": [
          todo("td1", "Review “Add offline cache” (#482)", "acme/web · requested by maya", githubIcon, false),
          todo("td2", "Reply to Maya about the launch checklist", "Slack · DM · 9:12", slackIcon, false),
          todo("td3", "Fix failing CI on “Fix login redirect”", "acme/api #311 · 2 checks failed", githubIcon, false),
          todo("td4", "Answer Jon in #design", "Slack · Acme Inc", slackIcon, true),
        ]],
        ["type": "section", "id": "feed", "title": "Feed", "accessory": "Slack · GitHub", "children": [
          feed("f1", "Maya Chen", "Can you look at the launch checklist before standup?", slackIcon, "9:12", "DM", true),
          feed("f2", "Add offline cache", "acme/web #482 · maya", githubIcon, "8:40", "Review", true),
          feed("f3", "Fix login redirect", "acme/api #311 · 2 checks failed", githubIcon, "8:05", "CI failed", false),
          feed("f4", "Jon Park in #design", "@you what do you think of the new icon set?", slackIcon, "Yesterday", "Mention", false),
          feed("f5", "Crash on launch with empty profile", "acme/app #97 · assigned to you", githubIcon, "Mon", "Assigned", false),
        ]],
      ]]
  }

  /// A sample connections sheet, the shape the `connections` plugin sends.
  static let connectionsTree: Value = ["type": "sheet", "id": "connections", "style": "sheet", "title": "Connections",
    "subtitle": "Sign in on the site; den reads your session on this Mac.", "icon": "sf:link",
    "children": [
      ["type": "section", "id": "accounts", "title": "Accounts", "children": [
        ["type": "connectionRow", "id": "conn.slack", "title": "Slack", "icon": .string(slackIcon), "connected": true,
         "status": "Acme Inc · 2 workspaces", "button": ["title": "Disconnect", "style": "secondary"]],
        ["type": "connectionRow", "id": "conn.github", "title": "GitHub", "icon": .string(githubIcon), "connected": false,
         "status": "Not connected", "button": ["title": "Connect", "style": "primary"]],
      ]],
      ["type": "section", "id": "teams", "title": "Slack workspaces", "children": [
        ["type": "toggleRow", "id": "team.T1", "title": "Acme Inc", "subtitle": "acme.slack.com", "on": true],
        ["type": "toggleRow", "id": "team.T2", "title": "Side Project", "subtitle": "sideproject.slack.com", "on": false],
      ]],
      ["type": "section", "id": "daily", "title": "Daily briefing", "children": [
        ["type": "choiceRow", "id": "briefing.time", "title": "Morning briefing at", "selected": "8",
         "options": .array((6...11).map { ["id": .string("\($0)"), "title": .string("\($0):00")] })],
        ["type": "toggleRow", "id": "briefing.enabled", "title": "Prepare the briefing every morning", "subtitle": "Uses Apple Intelligence on this Mac when it’s available", "on": true],
      ]],
    ]]

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
      ["type": "tabRow", "id": .string(id), "title": .string(title), "icon": .string(icon), "selected": .bool(sel),
       "dropInto": true, "dropIntoIcon": "sf:rectangle.split.2x1"]
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
  static func page(_ rt: DenRuntime, id: String, title: String, host: String? = nil, body: String, tint: String = "#f4f1ff") -> String {
    rt.call("webviews", "create", ["id": .string(id)])
    let html = """
      <html><head><title>\(title)</title><style>body{font:16px -apple-system;margin:0;padding:64px 72px;background:\(tint);color:#222}
      h1{font-size:30px;margin:0 0 16px}p{line-height:1.5;max-width:560px;color:#444}</style></head>
      <body><h1>\(title)</h1><p>\(body)</p></body></html>
      """
    rt.webviews.materialize(id)?.loadHTMLString(html, baseURL: URL(string: "https://\(host ?? id + ".example")/"))
    return id
  }
}
