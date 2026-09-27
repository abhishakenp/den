import AppKit

/// Anything in the toolkit that shows a hover state (sidebar rows, favorites tiles, space icons,
/// command bar and library rows, Settings rows, hover-card rows and buttons, icon buttons).
@MainActor
protocol Hoverable: NSView {
  var hovering: Bool { get set }
  /// At most one view per group is hovered in a window: rows are one group, the small buttons
  /// inside them (a row's ×) another, so a row and its button can both be hot.
  var hoverGroup: HoverGroup { get }
}

enum HoverGroup: Int { case row, control }

/// One source of truth for hover: which view is under the pointer, derived from the pointer's
/// current location, not from a pile of per-row enter/exit flags.
///
/// Tracking areas only say "something may have changed". AppKit can miss an exit when a row is
/// re-rendered, reused or reordered under a still pointer, or when a list scrolls under it, which
/// left several rows showing their hover fill and × at once. So every enter/exit, every re-render,
/// every scroll and every key-window change asks the window where the pointer really is
/// (`mouseLocationOutsideOfEventStream`), hit-tests it, sets `hovering` on the deepest hoverable of
/// each group under it and clears it on every other hoverable in the window. Resigning key clears all.
@MainActor
enum HoverTracker {
  /// Where the pointer is, in window coordinates. Tests put a fake pointer here (the real one is
  /// never moved).
  static var pointer: (NSWindow) -> NSPoint = { $0.mouseLocationOutsideOfEventStream }
  private static var observed: Set<ObjectIdentifier> = []
  private static var pending: Set<ObjectIdentifier> = []

  /// The hoverables under a window point, one per group (the deepest).
  static func hot(in window: NSWindow, at p: NSPoint) -> [HoverGroup: ObjectIdentifier] {
    var hot: [HoverGroup: ObjectIdentifier] = [:]
    guard window.isVisible, let content = window.contentView else { return hot }
    // The frame view (the window's top view) hit-tests in window coordinates, overlays included.
    let top = content.superview ?? content
    guard top.frame.contains(p) else { return hot }
    var v: NSView? = top.superview == nil ? top.hitTest(p) : top.hitTest(top.superview!.convert(p, from: nil))
    while let x = v {
      if let h = x as? any Hoverable, hot[h.hoverGroup] == nil { hot[h.hoverGroup] = ObjectIdentifier(x) }
      v = x.superview
    }
    return hot
  }

  /// Recomputes hover for `window` now, from where the pointer is.
  static func refresh(_ window: NSWindow?) {
    guard let window else { return }
    observe(window)
    apply(hot(in: window, at: pointer(window)), in: window)
  }

  static func apply(_ hot: [HoverGroup: ObjectIdentifier], in window: NSWindow) {
    guard let top = window.contentView?.superview ?? window.contentView else { return }
    func walk(_ v: NSView) {
      if let h = v as? any Hoverable {
        let want = hot[h.hoverGroup] == ObjectIdentifier(v)
        if h.hovering != want { h.hovering = want }
      }
      for s in v.subviews where !(s is NSScroller) { walk(s) }
    }
    walk(top)
  }

  /// Coalesces refreshes (a re-render touches many rows at once) into one, on the next turn.
  static func setNeedsRefresh(_ window: NSWindow?) {
    guard let window, pending.insert(ObjectIdentifier(window)).inserted else { return }
    DispatchQueue.main.async { [weak window] in
      MainActor.assumeIsolated {
        guard let window else { return }
        pending.remove(ObjectIdentifier(window))
        refresh(window)
      }
    }
  }

  static func clear(_ window: NSWindow) { apply([:], in: window) }

  /// Hovered views in `window` (tests).
  static func hovered(in window: NSWindow?, _ group: HoverGroup = .row) -> [NSView] {
    guard let top = window?.contentView?.superview ?? window?.contentView else { return [] }
    var out: [NSView] = []
    func walk(_ v: NSView) {
      if let h = v as? any Hoverable, h.hovering, h.hoverGroup == group { out.append(v) }
      v.subviews.forEach(walk)
    }
    walk(top)
    return out
  }

  private static func observe(_ w: NSWindow) {
    guard observed.insert(ObjectIdentifier(w)).inserted else { return }
    let nc = NotificationCenter.default
    nc.addObserver(forName: NSWindow.didResignKeyNotification, object: w, queue: .main) { [weak w] _ in
      MainActor.assumeIsolated { if let w { clear(w) } }
    }
    nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { [weak w] _ in
      MainActor.assumeIsolated { setNeedsRefresh(w) }
    }
  }

  /// Makes a scroll view refresh hover when it scrolls under a still pointer.
  static func watchScrolling(_ scroll: NSScrollView) {
    scroll.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak scroll] _ in
      MainActor.assumeIsolated { setNeedsRefresh(scroll?.window) }
    }
  }
}
