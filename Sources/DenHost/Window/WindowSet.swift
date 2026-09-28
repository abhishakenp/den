import AppKit
import CordisValue

/// den's browser windows (docs/host-api.md#window). One window exists from launch (`w1`); ⌘N adds
/// normal windows on the same spaces, ⇧⌘N private ones. Host services act on the **active** window:
/// the one most recently key. The content and ui services keep per-window state (panes, the
/// sidebar), set up through `each`. With one window nothing here costs anything.
@MainActor
public final class WindowSet {
  public private(set) var all: [DenWindowController]
  public private(set) var active: DenWindowController
  /// Per-window setup, run for every window now and every window created later.
  private var setups: [(DenWindowController) -> Void] = []
  /// Runs after `active` changed (old, new), before `window.activated` is emitted.
  public var onActivate: [(DenWindowController, DenWindowController) -> Void] = []
  /// Runs when a window goes away for good (after `window.closed` is built, before it's emitted).
  public var onRemove: [(DenWindowController) -> Void] = []
  /// What a closing window showed, for the `window.closed` event (the content service fills it in).
  public var describe: ((DenWindowController) -> Value)?
  /// `app.shouldClose`: the close interception for every window.
  public var onCloseRequest: (() -> Bool)?
  public var emit: (String, Value) -> Void = { _, _ in }
  private var keyObserver: NSObjectProtocol?
  private var nextPrivate = 1

  public init() {
    let main = DenWindowController(id: "w1")
    all = [main]
    active = main
    wire(main)
    keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] n in
      nonisolated(unsafe) let sender = n.object
      MainActor.assumeIsolated {
        guard let self, let w = sender as? NSWindow, let wc = self.all.first(where: { $0.window === w }) else { return }
        self.activate(wc)
      }
    }
  }

  /// The first normal window (never closed for good while it is the last one).
  public var main: DenWindowController { all.first { !$0.isPrivate } ?? all[0] }
  public var normal: [DenWindowController] { all.filter { !$0.isPrivate } }
  public func find(_ id: String) -> DenWindowController? { all.first { $0.id == id } }
  public func containing(_ w: NSWindow?) -> DenWindowController? { all.first { $0.window === w } }

  /// Runs `setup` for every window, now and later (per-window views, layout hooks).
  public func each(_ setup: @escaping (DenWindowController) -> Void) {
    setups.append(setup)
    for w in all { setup(w) }
  }

  private func wire(_ w: DenWindowController) {
    w.emit = { [weak self] e, v in self?.emit(e, v) }
    w.onCloseRequest = { [weak self] in self?.onCloseRequest?() ?? true }
    w.onClosed = { [weak self, weak w] in if let self, let w { self.closed(w) } }
  }

  /// A new window. Normal windows reuse the lowest free `w<n>` unless `id` names one (restore);
  /// private ones count up (`p<n>`) and are never reused in a session.
  public func create(id requested: String? = nil, isPrivate: Bool = false) -> DenWindowController {
    let id: String
    if isPrivate {
      id = "p" + String(nextPrivate)
      nextPrivate += 1
    } else if let r = requested, !r.isEmpty, find(r) == nil {
      id = r
    } else {
      var n = 2
      while find("w" + String(n)) != nil { n += 1 }
      id = "w" + String(n)
    }
    let w = DenWindowController(id: id, isPrivate: isPrivate, cascadeFrom: active.window.isVisible ? active.window : nil)
    // The new window starts where the active one is: same sidebar, same space page.
    if !isPrivate {
      for (p, t) in active.themes { w.setTheme(t, page: p) }
      w.showTheme(for: active.page)
    }
    if active.sidebarWidth != w.sidebarWidth { w.setSidebarWidth(active.sidebarWidth, animated: false) }
    all.append(w)
    wire(w)
    for s in setups { s(w) }
    return w
  }

  /// Makes `w` the window host services act on, and tells plugins (`window.activated`).
  public func activate(_ w: DenWindowController) {
    guard w !== active, all.contains(where: { $0 === w }) else { return }
    let old = active
    active = w
    for f in onActivate { f(old, w) }
    emit("window.activated", describe?(w).with("previous", .string(old.id)) ?? ["id": .string(w.id)])
  }

  /// `window.close` and the window's own close button. The last normal window only hides, as
  /// it always has (the Dock icon brings it back); every other window goes away with its views.
  private func closed(_ w: DenWindowController) {
    guard all.contains(where: { $0 === w }) else { return }
    if !w.isPrivate, normal.count == 1 { return }
    let info = describe?(w) ?? ["id": .string(w.id)]
    all.removeAll { $0 === w }
    // The next den window in front order (else the main one) is active before anything hears
    // about the close, so nothing ever acts on a window that is gone.
    let wasActive = active === w
    if wasActive {
      let front = NSApp.orderedWindows.compactMap { containing($0) }
      active = front.first ?? main
    }
    for f in onRemove { f(w) }
    w.window.delegate = nil
    emit("window.closed", info.with("frame", Self.frame(w.window.frame)))
    if wasActive {
      for f in onActivate { f(w, active) }
      emit("window.activated", describe?(active).with("previous", .string(w.id)) ?? ["id": .string(active.id)])
    }
  }

  static func frame(_ r: NSRect) -> Value {
    ["x": .double(Double(r.minX)), "y": .double(Double(r.minY)), "width": .double(Double(r.width)), "height": .double(Double(r.height))]
  }
}
