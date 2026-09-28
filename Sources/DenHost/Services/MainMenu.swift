import AppKit
import CordisValue

/// den's menu bar: den, File, Edit, View, History, Spaces, Tabs, Window, Help (Arc's structure,
/// spec §9 and its menu data; den's wording). Every shortcut den has lives here, so it's
/// discoverable and goes through AppKit's normal key-equivalent path (docs/shortcuts.md).
///
/// Items are one of:
/// - `sel`: a standard AppKit action sent down the responder chain (Copy, Minimize, Full Screen…).
/// - `host`: a host action (`MainMenu.perform`), e.g. zoom, find, print, Settings.
/// - `event`: a slot a plugin fills with `keys.bind {event}`: the item appears with the plugin's
///   chord once bound, and hides again when unbound. A second chord for the same event becomes a
///   hidden alternate (`allowsKeyEquivalentWhenHidden`), e.g. ⌘⇧] next to ⌥⌘↓ for Next Tab.
///   Payload bindings (⌘1…9, ⌃1…9) are listed one item each under their slot.
/// - `command`: runs `commands.run {id}` (the command bar's commands); shown when that command
///   can run right now (checked when the menu opens, never at launch).
@MainActor
public enum MainMenu {
  public enum Kind { case sel(Selector), host(String), event(String), command(String), submenu([Entry]), separator }
  public struct Entry {
    public let id: String
    public let title: String
    public let key: String  // default chord ("" = none)
    public let kind: Kind
    init(_ id: String, _ title: String, _ key: String = "", _ kind: Kind) { (self.id, self.title, self.key, self.kind) = (id, title, key, kind) }
    static var sep: Entry { Entry("", "", "", .separator) }
  }

  /// Host actions (`host` items and remapped shortcuts). Set by `DenRuntime`.
  public static var handler: ((String) -> Void)?
  /// Whether a host action can run now (e.g. page actions need a page). Default: yes.
  public static var canPerform: ((String) -> Bool)?
  /// Runs a command bar command; set by `DenRuntime`. Returns false when it can't run.
  public static var runCommand: ((String) -> Void)?
  public static var commandAvailable: ((String) -> Bool)?
  static let target = MenuTarget()

  /// The menus, in order. Titles are den's own; Arc's structure and keys (spec §9).
  // thin-host: feature-specific, migrate to plugin: the feature items (plugin events,
  // command ids, titles) should come from plugins registering commands with a menu and order;
  // the host keeps only the menus and standard AppKit items (docs/architecture/thin-host.md).
  public static let layout: [(String, [Entry])] = [
    ("den", [
      Entry("app.about", "About den", "", .host("app.about")), .sep,
      Entry("app.settings", "Settings…", "cmd+,", .host("app.settings")),
      Entry("app.defaultBrowser", "Make den Your Default Browser", "", .host("app.defaultBrowser")), .sep,
      Entry("app.services", "Services", "", .submenu([])), .sep,
      Entry("app.hide", "Hide den", "cmd+h", .sel(#selector(NSApplication.hide(_:)))),
      Entry("app.hideOthers", "Hide Others", "cmd+opt+h", .sel(#selector(NSApplication.hideOtherApplications(_:)))),
      Entry("app.showAll", "Show All", "", .sel(#selector(NSApplication.unhideAllApplications(_:)))), .sep,
      Entry("app.quit", "Quit den", "cmd+q", .sel(#selector(NSApplication.terminate(_:)))),
    ]),
    ("File", [
      Entry("file.newTab", "New Tab…", "", .event("commands.key.new")),
      Entry("file.newWindow", "New Window", "cmd+n", .host("window.new")),
      Entry("file.newPrivateWindow", "New Private Window", "cmd+shift+n", .host("window.newPrivate")),
      Entry("file.newTabInGroup", "New Tab in Group", "", .event("tabs.key.newTabInFolder")),
      Entry("file.openLocation", "Open Location…", "", .event("commands.key.edit")),
      Entry("file.reopenTab", "Reopen Closed Tab", "", .event("tabs.key.reopen")),
      Entry("file.reopenWindow", "Reopen Closed Window", "", .host("window.reopen")),
      Entry("file.openInSpace", "Open Peek or Mini Window in Space", "", .event("peek.key.expand")), .sep,
      Entry("file.closeTab", "Close Tab", "", .event("tabs.key.close")),
      Entry("file.closeOthers", "Close Other Tabs", "", .event("tabs.key.closeOthers")),
      Entry("file.closeWindow", "Close Window", "cmd+shift+w", .sel(#selector(NSWindow.performClose(_:)))), .sep,
      Entry("file.savePage", "Save Page As…", "cmd+shift+s", .host("page.save")),
      Entry("file.print", "Print…", "cmd+p", .host("page.print")), .sep,
      Entry("file.share", "Share…", "", .command("pagetools.share")),
      Entry("file.qrCode", "QR Code for This Page", "", .command("pagetools.qrCode")),
    ]),
    ("Edit", [
      Entry("edit.undo", "Undo", "cmd+z", .sel(Selector(("undo:")))),
      Entry("edit.redo", "Redo", "cmd+shift+z", .sel(Selector(("redo:")))), .sep,
      Entry("edit.cut", "Cut", "cmd+x", .sel(#selector(NSText.cut(_:)))),
      Entry("edit.copy", "Copy", "cmd+c", .sel(#selector(NSText.copy(_:)))),
      Entry("edit.paste", "Paste", "cmd+v", .sel(#selector(NSText.paste(_:)))),
      Entry("edit.pastePlain", "Paste and Match Style", "cmd+opt+shift+v", .sel(#selector(NSTextView.pasteAsPlainText(_:)))),
      Entry("edit.delete", "Delete", "", .sel(#selector(NSText.delete(_:)))),
      Entry("edit.selectAll", "Select All", "cmd+a", .sel(#selector(NSText.selectAll(_:)))), .sep,
      Entry("edit.copyURL", "Copy URL", "", .event("tabs.key.copy")),
      Entry("edit.copyMarkdown", "Copy URL as Markdown", "cmd+opt+shift+c", .command("den.copyMarkdown")), .sep,
      Entry("edit.find", "Find", "", .submenu([
        Entry("edit.find.show", "Find…", "cmd+f", .host("page.find")),
        Entry("edit.find.next", "Find Next", "cmd+g", .host("page.findNext")),
        Entry("edit.find.previous", "Find Previous", "cmd+shift+g", .host("page.findPrevious")),
        Entry("edit.find.selection", "Use Selection for Find", "cmd+e", .host("page.findSelection")),
      ])),
    ]),
    ("View", [
      Entry("view.sidebar", "Show/Hide Sidebar", "", .event("tabs.key.sidebar")),
      Entry("view.briefing", "Daily Briefing", "", .event("briefing.key.open")), .sep,
      Entry("view.reload", "Reload Page", "", .event("tabs.key.reload")),
      Entry("view.reloadHard", "Reload Page from Origin", "cmd+shift+r", .host("page.reloadFromOrigin")),
      Entry("view.stop", "Stop Loading", "", .event("tabs.key.stop")), .sep,
      Entry("view.zoomReset", "Actual Size", "cmd+0", .host("page.zoomReset")),
      Entry("view.zoomIn", "Zoom In", "cmd+plus", .host("page.zoomIn")),
      Entry("view.zoomOut", "Zoom Out", "cmd+-", .host("page.zoomOut")), .sep,
      Entry("view.addSplit", "Add Split View", "", .event("peek.key.addSplit")),
      Entry("view.closePane", "Close Split Pane", "", .event("peek.key.closePane")),
      Entry("view.focusPane", "Focus Split Pane", "", .event("peek.key.focusPane")), .sep,
      Entry("view.developer", "Developer", "", .submenu([
        Entry("view.viewSource", "View Source", "cmd+opt+u", .host("page.viewSource")),
        Entry("view.inspector", "Web Inspector", "cmd+opt+i", .host("page.inspector")),
        Entry("view.inspectElement", "Inspect Element", "cmd+opt+c", .host("page.inspectElement")),
        Entry("view.console", "JavaScript Console", "cmd+opt+j", .host("page.console")),
      ])), .sep,
      Entry("view.fullScreen", "Enter Full Screen", "cmd+ctrl+f", .sel(#selector(NSWindow.toggleFullScreen(_:)))),
      Entry("view.closePeek", "Close Peek", "", .event("peek.key.close")),
    ]),
    ("History", [
      Entry("history.back", "Back", "", .event("tabs.key.back")),
      Entry("history.forward", "Forward", "", .event("tabs.key.forward")), .sep,
      Entry("history.library", "Show Library", "", .event("tabs.key.library")),
      Entry("history.downloads", "Downloads", "", .event("tabs.key.downloads")),
      Entry("history.archive", "Search Archive…", "", .command("den.viewArchive")),
    ]),
    ("Spaces", [
      Entry("spaces.new", "New Space", "", .command("den.newSpace")),
      Entry("spaces.theme", "Edit Theme Color…", "", .command("den.theme")), .sep,
      Entry("spaces.next", "Next Space", "", .event("spaces.key.next")),
      Entry("spaces.prev", "Previous Space", "", .event("spaces.key.prev")), .sep,
      Entry("spaces.unload", "Unload Space", "", .event("tabs.key.unloadSpace")), .sep,
      Entry("spaces.jump", "Space", "", .event("spaces.key.jump")),
    ]),
    ("Tabs", [
      Entry("tabs.pin", "Pin/Unpin Tab", "", .event("tabs.key.pin")),
      Entry("tabs.duplicate", "Duplicate Tab", "", .command("den.duplicateTab")),
      Entry("tabs.rename", "Rename Tab", "", .command("den.renameTab")),
      Entry("tabs.splitRight", "Split Right", "", .command("den.splitRight")),
      Entry("tabs.newFolder", "New Folder with Selected Tabs", "", .event("tabs.key.newFolder")), .sep,
      Entry("tabs.next", "Next Tab", "", .event("tabs.key.nextTab")),
      Entry("tabs.prev", "Previous Tab", "", .event("tabs.key.prevTab")),
      Entry("tabs.recent", "Switch to Recent Tab", "", .event("tabs.key.recent")),
      Entry("tabs.recentBack", "Switch to Oldest Recent Tab", "", .event("tabs.key.recentBack")),
      Entry("tabs.goTo", "Go to Tab", "", .submenu([Entry("tabs.nth", "Tab", "", .event("tabs.key.nth"))])), .sep,
      Entry("tabs.clear", "Clear Today Tabs", "", .event("tabs.key.clear")),
      Entry("tabs.tidy", "Tidy Tabs", "", .event("tabs.key.tidy")),
      Entry("tabs.undo", "Undo Sidebar Action", "", .event("tabs.key.undo")),
    ]),
    ("Window", [
      Entry("window.minimize", "Minimize", "cmd+m", .sel(#selector(NSWindow.performMiniaturize(_:)))),
      Entry("window.zoom", "Zoom", "", .sel(#selector(NSWindow.performZoom(_:)))), .sep,
      Entry("window.front", "Bring All to Front", "", .sel(#selector(NSApplication.arrangeInFront(_:)))),
    ]),
    ("Help", [
      Entry("help.site", "den Help", "", .host("help.site")),
      Entry("help.shortcuts", "Keyboard Shortcuts", "", .host("help.shortcuts")),
      Entry("help.issue", "Report an Issue…", "", .host("help.issue")),
    ]),
  ]

  /// Every entry by id (submenus included).
  /// Every entry by id (submenus included), flattened once.
  public static let entries: [Entry] = {
    func flat(_ es: [Entry]) -> [Entry] { es.flatMap { e -> [Entry] in if case let .submenu(s) = e.kind { return [e] + flat(s) } else { return [e] } } }
    return layout.flatMap { flat($0.1) }
  }()
  static let entryById: [String: Entry] = Dictionary(entries.filter { !$0.id.isEmpty }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
  static let slotByEvent: [String: String] = Dictionary(entries.compactMap { e -> (String, String)? in
    if case let .event(ev) = e.kind { return (ev, e.id) }
    return nil
  }, uniquingKeysWith: { a, _ in a })
  /// The installed items by id (weak: the menu owns them). Filled by `install`.
  private static let itemTable = NSMapTable<NSString, NSMenuItem>.strongToWeakObjects()
  private static weak var installedMenu: NSMenu?

  public static func install() {
    let main = NSMenu()
    for (name, items) in layout {
      let top = NSMenuItem(title: name, action: nil, keyEquivalent: "")
      let m = NSMenu(title: name)
      m.autoenablesItems = true
      m.delegate = target
      build(items, into: m)
      top.submenu = m
      main.addItem(top)
      switch name {
      case "Window": NSApp.windowsMenu = m
      case "Help": NSApp.helpMenu = m
      default: break
      }
    }
    if let s = item("app.services", in: main) { s.submenu = NSMenu(title: "Services"); NSApp.servicesMenu = s.submenu }
    // ⌘= zooms in too (Safari and Chrome take both ⌘+ and ⌘=).
    if let zi = item("view.zoomIn", in: main), let m = zi.menu {
      let alt = NSMenuItem(title: zi.title, action: zi.action, keyEquivalent: "")
      alt.identifier = NSUserInterfaceItemIdentifier("view.zoomIn.alt")
      alt.target = zi.target
      setKey(alt, "cmd+=")
      alt.isHidden = true
      alt.allowsKeyEquivalentWhenHidden = true
      m.insertItem(alt, at: m.index(of: zi) + 1)
    }
    NSApp.mainMenu = main
    installedMenu = main
    itemTable.removeAllObjects()
    func index(_ m: NSMenu) { for mi in m.items { if let id = mi.identifier?.rawValue { itemTable.setObject(mi, forKey: id as NSString) }; if let s = mi.submenu { index(s) } } }
    index(main)
  }

  static func build(_ items: [Entry], into m: NSMenu) {
    for e in items {
      if case .separator = e.kind { m.addItem(.separator()); continue }
      let mi = NSMenuItem(title: e.title, action: nil, keyEquivalent: "")
      mi.identifier = NSUserInterfaceItemIdentifier(e.id)
      switch e.kind {
      case let .sel(s): mi.action = s
      case .host, .command:
        mi.action = #selector(MenuTarget.menuAction(_:))
        mi.target = target
      case .event: mi.isHidden = true  // until a plugin binds it
      case let .submenu(sub):
        let sm = NSMenu(title: e.title)
        sm.delegate = target
        build(sub, into: sm)
        mi.submenu = sm
      case .separator: break
      }
      if !e.key.isEmpty { setKey(mi, e.key) }
      m.addItem(mi)
    }
  }

  /// Sets an item's key equivalent from a chord string (see `Chord.menuEquivalent`).
  static func setKey(_ mi: NSMenuItem, _ chord: String) {
    guard let c = Chord.parse(chord) else { mi.keyEquivalent = ""; return }
    let (key, mods) = c.menuEquivalent
    mi.keyEquivalent = key
    var m: NSEvent.ModifierFlags = []
    if mods.contains(.cmd) { m.insert(.command) }
    if mods.contains(.shift) { m.insert(.shift) }
    if mods.contains(.opt) { m.insert(.option) }
    if mods.contains(.ctrl) { m.insert(.control) }
    mi.keyEquivalentModifierMask = m
  }

  public static func item(_ id: String, in menu: NSMenu? = NSApp.mainMenu) -> NSMenuItem? {
    guard let menu else { return nil }
    // The installed bar: a table lookup (keys.bind asks for every binding at launch).
    if menu === installedMenu, let mi = itemTable.object(forKey: id as NSString), mi.menu != nil { return mi }
    for mi in menu.items {
      if mi.identifier?.rawValue == id { return mi }
      if let s = mi.submenu, let f = item(id, in: s) { return f }
    }
    return nil
  }

  /// The item that runs a command bar command (`edit.copyMarkdown` for `den.copyMarkdown`), if any.
  static func commandItem(_ command: String) -> NSMenuItem? {
    guard let id = itemByCommand[command] else { return nil }
    return item(id)
  }
  static let itemByCommand: [String: String] = Dictionary(entries.compactMap { e -> (String, String)? in
    if case let .command(c) = e.kind { return (c, e.id) }
    return nil
  }, uniquingKeysWith: { a, _ in a })

  /// The item slot a plugin event fills, if the layout has one.
  static func slot(for event: String) -> NSMenuItem? {
    guard let id = slotByEvent[event] else { return nil }
    return item(id)
  }

  public static func menu(named name: String, in main: NSMenu? = NSApp.mainMenu) -> NSMenu {
    let main = main ?? NSMenu()
    if let it = main.items.first(where: { $0.submenu?.title == name }), let m = it.submenu { return m }
    let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
    let m = NSMenu(title: name)
    item.submenu = m
    // Keep Window and Help last.
    if let wi = main.items.firstIndex(where: { $0.submenu?.title == "Window" }) { main.insertItem(item, at: wi) } else { main.addItem(item) }
    return m
  }

  /// Runs a host action or command item (also the `[shortcuts]` remap path).
  public static func perform(_ id: String) {
    guard let e = entryById[id == "view.zoomIn.alt" ? "view.zoomIn" : id] else { return }
    switch e.kind {
    case let .host(a): handler?(a)
    case let .command(c): runCommand?(c)
    default: break
    }
  }

  /// Hides separators that have nothing to separate (e.g. when a plugin isn't loaded).
  static func tidy(_ m: NSMenu) {
    var lastVisible: NSMenuItem?
    for mi in m.items {
      if mi.isSeparatorItem {
        mi.isHidden = lastVisible == nil || lastVisible!.isSeparatorItem
        if !mi.isHidden { lastVisible = mi }
      } else if !mi.isHidden {
        lastVisible = mi
      }
    }
    if let l = lastVisible, l.isSeparatorItem { l.isHidden = true }
  }
}

/// Target of host and command items; validates them and tidies menus as they open.
@MainActor
final class MenuTarget: NSObject, NSMenuDelegate, NSMenuItemValidation {
  @objc func menuAction(_ sender: NSMenuItem) {
    guard let id = sender.identifier?.rawValue else { return }
    MainMenu.perform(id)
  }

  func validateMenuItem(_ mi: NSMenuItem) -> Bool {
    guard let id = mi.identifier?.rawValue, let e = MainMenu.entryById[id] else { return true }
    switch e.kind {
    case let .host(a): return MainMenu.canPerform?(a) ?? true
    case let .command(c): return MainMenu.commandAvailable?(c) ?? false
    default: return true
    }
  }

  /// Command items show only while their command exists (checked when the menu opens).
  func menuNeedsUpdate(_ menu: NSMenu) {
    for mi in menu.items {
      guard let id = mi.identifier?.rawValue, let e = MainMenu.entryById[id], case let .command(c) = e.kind else { continue }
      mi.isHidden = !(MainMenu.commandAvailable?(c) ?? false)
    }
    MainMenu.tidy(menu)
  }
}

extension Chord {
  /// The NSMenuItem key equivalent for this chord. Shifted punctuation is written the way AppKit
  /// matches it: ⌘⇧] is "}" with ⌘ (the event's characters), not "]" with ⌘⇧; letters stay
  /// lowercase with ⇧ in the mask. US layout, like every browser's defaults.
  public var menuEquivalent: (String, Set<Mod>) {
    guard mods.contains(.shift), let shifted = Self.shiftedPunctuation[key] else { return (key, mods) }
    var m = mods
    m.remove(.shift)
    return (shifted, m)
  }

  static let shiftedPunctuation: [String: String] = [
    "]": "}", "[": "{", "=": "+", "-": "_", "/": "?", ";": ":", "'": "\"", ",": "<", ".": ">", "`": "~", "\\": "|",
    "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
  ]
}
