import AppKit
import CordisValue

/// `window` service.
///
/// Methods:
///   setTheme {colors: [hex] (≤3), intensity 0–1, grain 0–1, appearance: light|dark|auto, page?}
///   setSidebar {width?, hidden?, animated?}     toggleSidebar {animated?}
///   setTitle {title}                            get -> {width, hidden, page, fullScreen, dark}
///   openMini {webview, space?, width?, height?} -> {id}   Little Arc window (spec §8) hosting one web view
///   updateMini {id, space?}                     closeMini {id}                listMini -> [{id, webview, key}]
/// Events: window.sidebarResized {width}, window.sidebarVisibility {hidden}, window.sidebarReveal {revealed},
///   window.miniAction {id, webview, action: open|copy}, window.miniClosed {id, webview}
@MainActor
public final class WindowService: HostService {
  public let name = "window"
  let wc: DenWindowController
  weak var ui: UIService?
  let mini: MiniWindows

  public init(window: DenWindowController) {
    wc = window
    mini = MiniWindows(window: window)
  }

  /// Gives the Little Arc windows access to web views and the event bus.
  func attach(webviews: WebViewsService, host: ServiceHost) {
    mini.webviews = webviews
    mini.host = host
    host.on("webviews.url") { [weak self] v in self?.mini.noteURL(v) }
    host.on("webviews.favicon") { [weak self] v in self?.mini.noteURL(v) }
  }

  public func handle(method: String, args: Value) -> Value {
    switch method {
    case "setTheme":
      wc.setTheme(Theme(args), page: args["page"].int.map(Int.init))
      ui?.refreshPalette()
      mini.refreshTheme()
    case "setSidebar":
      if let w = args["width"].double { wc.setSidebarWidth(CGFloat(w), animated: args.flag("animated", false)) }
      if let h = args["hidden"].bool { wc.setSidebarHidden(h, animated: args.flag("animated", true)) }
    case "toggleSidebar":
      wc.setSidebarHidden(!wc.sidebarHidden, animated: args.flag("animated", true))
    case "openMini": return mini.open(args)
    case "updateMini": return mini.update(args)
    case "closeMini": return mini.close(args)
    case "listMini":
      return .array(mini.windows.values.sorted { $0.id < $1.id }.map {
        ["id": .string($0.id), "webview": .string($0.webview), "key": .bool($0.panel.isKeyWindow)]
      })
    case "setTitle":
      wc.window.title = args.str("title", "den")
    case "get":
      return ["width": .double(Double(wc.sidebarWidth)), "hidden": .bool(wc.sidebarHidden), "page": .int(Int64(wc.page)),
              "fullScreen": .bool(wc.window.styleMask.contains(.fullScreen)), "dark": .bool(wc.isDark)]
    default:
      return .error("window: unknown method '\(method)'")
    }
    return .ok
  }
}

/// `keys` service: chords bound to events through the main menu (so they work while web
/// content has focus, and standard Edit/Window shortcuts keep working).
///
/// Methods:
///   bind {chord: "cmd+shift+k", event, title?, menu?: File|Edit|View|Tabs|Spaces|Window|<any>, payload?}
///   unbind {chord}          list -> [{chord, event, title, menu}]
/// Emits the bound event with {chord, payload}.
@MainActor
public final class KeysService: NSObject, HostService {
  public let name = "keys"
  let host: ServiceHost
  struct Binding { let chord: String; let event: String; let title: String; let menu: String; let payload: Value; let item: NSMenuItem }
  var bindings: [String: Binding] = [:]

  public init(host: ServiceHost) { self.host = host }

  public func handle(method: String, args: Value) -> Value {
    switch method {
    case "bind":
      let chordStr = args.str("chord").lowercased()
      guard let chord = Chord.parse(chordStr) else { return .error("keys: bad chord '\(chordStr)'") }
      let event = args.str("event")
      guard !event.isEmpty else { return .error("keys: missing event") }
      unbind(chordStr)
      let title = args.str("title", event)
      let menuName = args.str("menu", "Tabs")
      let item = NSMenuItem(title: title, action: #selector(fire(_:)), keyEquivalent: chord.key)
      item.target = self
      item.representedObject = chordStr
      var m: NSEvent.ModifierFlags = []
      if chord.mods.contains(.cmd) { m.insert(.command) }
      if chord.mods.contains(.shift) { m.insert(.shift) }
      if chord.mods.contains(.opt) { m.insert(.option) }
      if chord.mods.contains(.ctrl) { m.insert(.control) }
      item.keyEquivalentModifierMask = m
      MainMenu.menu(named: menuName).addItem(item)
      bindings[chordStr] = Binding(chord: chordStr, event: event, title: title, menu: menuName, payload: args["payload"], item: item)
    case "unbind":
      unbind(args.str("chord").lowercased())
    case "list":
      return .array(bindings.values.sorted { $0.chord < $1.chord }.map {
        ["chord": .string($0.chord), "event": .string($0.event), "title": .string($0.title), "menu": .string($0.menu)]
      })
    default:
      return .error("keys: unknown method '\(method)'")
    }
    return .ok
  }

  func unbind(_ chord: String) {
    guard let b = bindings.removeValue(forKey: chord) else { return }
    b.item.menu?.removeItem(b.item)
  }

  @objc func fire(_ sender: NSMenuItem) {
    guard let c = sender.representedObject as? String, let b = bindings[c] else { return }
    host.emit(b.event, ["chord": .string(c), "payload": b.payload])
  }
}

/// Builds the standard main menu; plugin menus are created on demand.
@MainActor
public enum MainMenu {
  public static func install() {
    let main = NSMenu()
    let appItem = NSMenuItem()
    main.addItem(appItem)
    let app = NSMenu(title: "den")
    app.addItem(withTitle: "About den", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    app.addItem(.separator())
    let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
    services.submenu = NSMenu()
    NSApp.servicesMenu = services.submenu
    app.addItem(services)
    app.addItem(.separator())
    app.addItem(withTitle: "Hide den", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    let other = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
    other.keyEquivalentModifierMask = [.command, .option]
    app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
    app.addItem(.separator())
    app.addItem(withTitle: "Quit den", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = app

    _ = menu(named: "File", in: main)
    let edit = menu(named: "Edit", in: main)
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    _ = menu(named: "View", in: main)
    _ = menu(named: "Tabs", in: main)
    _ = menu(named: "Spaces", in: main)
    let window = menu(named: "Window", in: main)
    window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    let fs = window.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
    fs.keyEquivalentModifierMask = [.command, .control]
    NSApp.windowsMenu = window
    NSApp.mainMenu = main
  }

  public static func menu(named name: String, in main: NSMenu? = NSApp.mainMenu) -> NSMenu {
    let main = main ?? NSMenu()
    if let it = main.items.first(where: { $0.submenu?.title == name }), let m = it.submenu { return m }
    let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
    let m = NSMenu(title: name)
    item.submenu = m
    // Keep Window last.
    if let wi = main.items.firstIndex(where: { $0.submenu?.title == "Window" }) { main.insertItem(item, at: wi) } else { main.addItem(item) }
    return m
  }
}

/// `app` service.
///
/// Methods:
///   interceptQuit {enabled}      -> when on, Cmd-Q emits app.quitRequested and waits for `quit`
///   quit {confirm=true}          -> answers a pending quit request (false cancels), or quits now
///   interceptClose {enabled}     -> when on, closing the window emits app.closeRequested
///   closeWindow                  -> closes the main window (bypassing interception)
///   pendingURLs                  -> [url] opened before a listener existed (clears the buffer)
///   setDefaultBrowser            -> asks macOS to make den the default for http/https
///   info                         -> {bundleId, version, launchMs}
///   copy {text}                  -> puts text on the general pasteboard
/// Events: app.quitRequested, app.closeRequested, app.openURL {urls: [string]}, app.activate
@MainActor
public final class AppService: HostService {
  public let name = "app"
  let host: ServiceHost
  weak var wc: DenWindowController?
  var interceptQuit = false
  var interceptClose = false
  var quitPending = false
  var forceQuit = false
  var forceClose = false
  var buffered: [String] = []
  public var launchMs: Double?

  public init(host: ServiceHost, window: DenWindowController?) {
    self.host = host
    self.wc = window
  }

  public func handle(method: String, args: Value) -> Value {
    switch method {
    case "interceptQuit": interceptQuit = args.flag("enabled", true)
    case "interceptClose": interceptClose = args.flag("enabled", true)
    case "quit":
      let confirm = args.flag("confirm", true)
      if quitPending {
        quitPending = false
        NSApp.reply(toApplicationShouldTerminate: confirm)
      } else if confirm {
        forceQuit = true
        NSApp.terminate(nil)
      }
    case "closeWindow":
      forceClose = true
      wc?.window.performClose(nil)
      forceClose = false
    case "pendingURLs":
      defer { buffered = [] }
      return .array(buffered.map { .string($0) })
    case "setDefaultBrowser":
      let url = Bundle.main.bundleURL
      for scheme in ["http", "https"] {
        NSWorkspace.shared.setDefaultApplication(at: url, toOpenURLsWithScheme: scheme) { [weak self] err in
          let msg = err?.localizedDescription ?? ""
          DispatchQueue.main.async { MainActor.assumeIsolated { self?.host.emit("app.defaultBrowser", ["scheme": .string(scheme), "error": .string(msg)]) } }
        }
      }
    case "copy":
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(args.str("text"), forType: .string)
    case "info":
      return ["bundleId": .string(Bundle.main.bundleIdentifier ?? ""), "version": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"),
              "launchMs": launchMs.map { .double($0) } ?? .null]
    default:
      return .error("app: unknown method '\(method)'")
    }
    return .ok
  }

  /// From NSApplicationDelegate.applicationShouldTerminate.
  public func shouldTerminate() -> NSApplication.TerminateReply {
    if forceQuit || !interceptQuit || !host.hasListeners("app.quitRequested") { return .terminateNow }
    quitPending = true
    host.emit("app.quitRequested")
    return .terminateLater
  }

  /// From NSWindowDelegate.windowShouldClose.
  public func shouldClose() -> Bool {
    if forceClose || !interceptClose || !host.hasListeners("app.closeRequested") { return true }
    host.emit("app.closeRequested")
    return false
  }

  public func open(_ urls: [URL]) {
    let list = urls.map(\.absoluteString)
    if host.hasListeners("app.openURL") {
      host.emit("app.openURL", ["urls": .array(list.map { .string($0) })])
    } else {
      buffered += list
    }
  }
}
