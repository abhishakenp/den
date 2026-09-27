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
///   focusMini {id}                              brings that Little Arc window to the front
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
    case "focusMini": return mini.focus(args)
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
///   bind {chord: "cmd+shift+k", event, title?, menu?: File|Edit|View|History|Tabs|Spaces|Window|<any>, payload?}
///   unbind {chord}          list -> [{chord, event, title, menu}]
///   remap {chord, item}     gives a menu item (MainMenu ids, docs/shortcuts.md) a new shortcut
///   resetRemaps             restores every remapped item's own shortcut
/// Emits the bound event with {chord, payload}.
///
/// A binding whose event has a slot in den's menu bar (`MainMenu.layout`) fills that item, so it
/// shows in the right place with den's wording; a second chord for the same event is a hidden
/// alternate; bindings with a payload (⌘1…9, ⌃1…9) are listed one item each under the slot.
/// Other bindings are appended to the menu they name.
@MainActor
public final class KeysService: NSObject, HostService, NSMenuItemValidation {
  public let name = "keys"
  let host: ServiceHost
  struct Binding { let chord: String; let event: String; let title: String; let menu: String; let payload: Value; let item: NSMenuItem; let owned: Bool }
  var bindings: [String: Binding] = [:]
  /// item id -> its original key equivalent and mask, while remapped.
  var remapped: [String: (key: String, mask: NSEvent.ModifierFlags, chord: String)] = [:]

  public init(host: ServiceHost) { self.host = host }

  public func handle(method: String, args: Value) -> Value {
    switch method {
    case "bind":
      let chordStr = args.str("chord").lowercased()
      guard Chord.parse(chordStr) != nil else { return .error("keys: bad chord '\(chordStr)'") }
      let event = args.str("event")
      guard !event.isEmpty else { return .error("keys: missing event") }
      let title = args.str("title", event)
      let menuName = args.str("menu", "Tabs")
      let payload = args["payload"]
      // Rebinding the same chord to the same event (spaces does on every change) keeps its item:
      // only a listed item's title can change (a renamed space).
      if let b = bindings[chordStr], b.event == event, b.item.menu != nil {
        if b.owned, !payload.isNull { b.item.title = title }
        bindings[chordStr] = Binding(chord: chordStr, event: event, title: title, menu: menuName, payload: payload, item: b.item, owned: b.owned)
        return .ok
      }
      unbind(chordStr)
      let (item, owned) = place(event: event, title: title, menu: menuName, payload: payload)
      MainMenu.setKey(item, chordStr)
      // A [shortcuts] remap of this slot survives the plugin rebinding it.
      if let id = item.identifier?.rawValue, let r = remapped[id] { MainMenu.setKey(item, r.chord) }
      item.target = self
      item.action = #selector(fire(_:))
      item.representedObject = chordStr
      bindings[chordStr] = Binding(chord: chordStr, event: event, title: title, menu: menuName, payload: payload, item: item, owned: owned)
    case "unbind":
      unbind(args.str("chord").lowercased())
    case "list":
      return .array(bindings.values.sorted { $0.chord < $1.chord }.map {
        ["chord": .string($0.chord), "event": .string($0.event), "title": .string($0.title), "menu": .string($0.menu), "payload": $0.payload]
      })
    case "remap":
      let chord = args.str("chord").lowercased()
      guard Chord.parse(chord) != nil else { return .error("keys: bad chord '\(chord)'") }
      guard let mi = MainMenu.item(args.str("item")) else { return .error("keys: no menu item '\(args.str("item"))'") }
      let id = args.str("item")
      remapped[id] = (remapped[id]?.key ?? mi.keyEquivalent, remapped[id]?.mask ?? mi.keyEquivalentModifierMask, chord)
      MainMenu.setKey(mi, chord)
    case "resetRemaps":
      for (id, r) in remapped {
        guard let mi = MainMenu.item(id) else { continue }
        mi.keyEquivalent = r.key
        mi.keyEquivalentModifierMask = r.mask
      }
      remapped = [:]
    default:
      return .error("keys: unknown method '\(method)'")
    }
    return .ok
  }

  /// Where a binding lives: its slot in the menu bar (or a hidden alternate / a payload item next
  /// to it), else a new item at the end of the named menu. `owned` items are removed on unbind.
  func place(event: String, title: String, menu: String, payload: Value) -> (NSMenuItem, Bool) {
    guard let slot = MainMenu.slot(for: event), let parent = slot.menu else {
      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      MainMenu.menu(named: menu).addItem(item)
      return (item, true)
    }
    let taken = bindings.values.filter { $0.event == event && $0.item.menu != nil }
    if taken.isEmpty && payload.isNull {
      slot.isHidden = false
      return (slot, false)
    }
    // Payload lists (⌘1…9 / ⌃1…9): the slot stays hidden and each binding is its own item after it.
    let item = NSMenuItem(title: payload.isNull ? slot.title : title, action: nil, keyEquivalent: "")
    if payload.isNull {
      item.isHidden = true
      item.allowsKeyEquivalentWhenHidden = true
    }
    let after = taken.map(\.item).compactMap { parent.index(of: $0) }.max() ?? parent.index(of: slot)
    parent.insertItem(item, at: after + 1)
    return (item, true)
  }

  func unbind(_ chord: String) {
    guard let b = bindings.removeValue(forKey: chord) else { return }
    if b.owned {
      b.item.menu?.removeItem(b.item)
    } else {
      // A slot: hide it, unless another chord for the same event can take its place.
      b.item.keyEquivalent = ""
      b.item.isHidden = true
      if let alt = bindings.values.first(where: { $0.event == b.event && $0.payload.isNull }) {
        b.item.isHidden = false
        MainMenu.setKey(b.item, alt.chord)
        b.item.representedObject = alt.chord
        alt.item.menu?.removeItem(alt.item)
        bindings[alt.chord] = Binding(chord: alt.chord, event: alt.event, title: alt.title, menu: alt.menu, payload: alt.payload, item: b.item, owned: false)
      }
    }
  }

  @objc func fire(_ sender: NSMenuItem) {
    guard let c = sender.representedObject as? String, let b = bindings[c] else { return }
    host.emit(b.event, ["chord": .string(c), "payload": b.payload])
  }

  /// ⌘←/⌘→ and friends are text-editing keys too: while a native text field (the command bar,
  /// a Settings field) is being edited, plain ⌘-arrow bindings stand aside so the field gets them.
  /// Web page fields handle them before the menu sees them (WKWebView offers keys to the page first).
  public func validateMenuItem(_ mi: NSMenuItem) -> Bool {
    let arrows: Set<String> = ["\u{F702}", "\u{F703}", "\u{F700}", "\u{F701}"]
    if arrows.contains(mi.keyEquivalent), mi.keyEquivalentModifierMask == .command,
       NSApp.keyWindow?.firstResponder is NSText {
      return false
    }
    return true
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
///   setDefaultBrowser {bundleId?} -> asks macOS to make den (or the app `bundleId`) the default for http/https
///   defaultBrowser               -> {bundleId, name, isDefault}: the app that opens https links now
///   info                         -> {bundleId, version, launchMs}
///   copy {text}                  -> puts text on the general pasteboard
///   state                        -> {active, idleSeconds, keyIdleSeconds}: frontmost, and time since any input / a key press
///   relaunch {background?}       -> quits cleanly (no quit dialog) and relaunches; `background` doesn't take focus
///   setAbout {credits}           -> text shown in the About panel
///   showAbout                    -> shows the About panel
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
  /// Set by the app (main.swift): quits and relaunches the bundle. `true` = in the background.
  public var relaunchHandler: ((Bool) -> Void)?
  /// Reads and sets the system default browser. Tests swap in a fake so they never touch macOS.
  public var browserDefaults = BrowserDefaults.system

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
      var url = Bundle.main.bundleURL
      if let id = args["bundleId"].string, !id.isEmpty {
        guard let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return .error("app: no application '\(id)'") }
        url = u
      }
      for scheme in ["http", "https"] {
        browserDefaults.set(url, scheme) { [weak self] err in
          let msg = err ?? ""
          DispatchQueue.main.async { MainActor.assumeIsolated { self?.host.emit("app.defaultBrowser", ["scheme": .string(scheme), "error": .string(msg)]) } }
        }
      }
    case "defaultBrowser":
      let current = browserDefaults.current()
      let id = current.flatMap { Bundle(url: $0)?.bundleIdentifier } ?? ""
      let name = current.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? ""
      let mine = Bundle.main.bundleIdentifier ?? ""
      let isMe = current?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL || (!mine.isEmpty && id == mine)
      return ["bundleId": .string(id), "name": .string(name), "isDefault": .bool(isMe)]
    case "copy":
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(args.str("text"), forType: .string)
    case "info":
      return ["bundleId": .string(Bundle.main.bundleIdentifier ?? ""), "version": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"),
              "launchMs": launchMs.map { .double($0) } ?? .null]
    case "state":
      // Generic signals for plugins that schedule work around the user (e.g. updates).
      let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
      let keyIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
      return ["active": .bool(NSApp.isActive), "idleSeconds": .double(idle), "keyIdleSeconds": .double(keyIdle)]
    case "relaunch":
      // Quits cleanly (no quit dialog) and starts this app bundle again; `background` keeps the
      // new instance from taking focus.
      guard relaunchHandler != nil else { return .error("app: relaunch is not available") }
      relaunchHandler?(args.flag("background"))
    case "setAbout":
      AboutPanel.shared.credits = args.str("credits")
    case "showAbout":
      AboutPanel.shared.show(nil)
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

/// The About panel: the standard one, plus credits text a plugin sets (`app.setAbout`).
@MainActor
public final class AboutPanel: NSObject {
  public static let shared = AboutPanel()
  public var credits = ""
  @objc public func show(_ sender: Any?) {
    var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
    if !credits.isEmpty {
      options[.credits] = NSAttributedString(string: credits, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
    }
    NSApp.activate()
    NSApp.orderFrontStandardAboutPanel(options: options)
  }
}

/// Where `app` reads and writes the system default browser (NSWorkspace; a fake in tests).
public struct BrowserDefaults: Sendable {
  public var current: @Sendable () -> URL?
  public var set: @Sendable (URL, String, @escaping @Sendable (String?) -> Void) -> Void
  public init(current: @escaping @Sendable () -> URL?, set: @escaping @Sendable (URL, String, @escaping @Sendable (String?) -> Void) -> Void) {
    self.current = current
    self.set = set
  }
  public static let system = BrowserDefaults(
    current: { NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) },
    set: { url, scheme, done in NSWorkspace.shared.setDefaultApplication(at: url, toOpenURLsWithScheme: scheme) { done($0?.localizedDescription) } })
}
