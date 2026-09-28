import AppKit

/// Generic host primitive: keyboard focus for modal surfaces (dialogs, sheets, popovers, the
/// command bar, a page's JavaScript dialogs).
///
/// - `present` makes the surface the first responder and remembers what had focus before
///   (usually a web view with a focused text field). `dismiss` gives focus back to it.
/// - While a surface is up, keys belong to it. A page can call `element.focus()` at any time
///   (Google does right after a sign-in submit), and WebKit then makes its WKWebView the window's
///   first responder again, which used to swallow Esc and Return. So every key-down in a den
///   window (`DenNSWindow` / `DenNSPanel` route `sendEvent` and `performKeyEquivalent` here) first
///   checks that focus is inside the top surface, and takes it back if it isn't; the key then
///   goes through AppKit's normal dispatch to the surface (Esc = its cancel, Return = its default).
/// - Something that took focus on purpose while the surface was up (a new tab's page shown from
///   the command bar) keeps it: focus is only restored when it was still inside the surface.
@MainActor
public enum ModalFocus {
  final class Entry {
    weak var view: NSView?
    weak var window: NSWindow?
    weak var previous: NSResponder?
    let focus: () -> NSView?
    init(view: NSView, window: NSWindow, previous: NSResponder?, focus: @escaping () -> NSView?) {
      self.view = view
      self.window = window
      self.previous = previous
      self.focus = focus
    }
  }

  static var entries: [Entry] = []

  /// Shows `view` as the top modal surface of its window and gives it key focus (`focus()`, e.g.
  /// its first text field; the view itself by default). Presenting it again only re-focuses it.
  public static func present(_ view: NSView, focus: (() -> NSView?)? = nil) {
    prune()
    guard let window = view.window else { return }
    let target = focus ?? { [weak view] in view }
    if let e = entries.first(where: { $0.view === view }) {
      if e.window !== window { e.window = window }
      take(e)
      return
    }
    let fr = window.firstResponder
    // A field editor stands for its text field.
    let previous: NSResponder? = fr === window ? nil : ((fr as? NSText).flatMap { $0.delegate as? NSResponder } ?? fr)
    let e = Entry(view: view, window: window, previous: previous, focus: target)
    entries.append(e)
    take(e)
  }

  /// The surface is gone (or going): focus returns to what had it before, or to the next surface.
  public static func dismiss(_ view: NSView) {
    guard let i = entries.firstIndex(where: { $0.view === view }) else { return }
    let e = entries.remove(at: i)
    prune()
    guard let window = e.window else { return }
    if let next = entries.last(where: { $0.window === window }) {
      take(next)
      return
    }
    let fr = window.firstResponder
    let focusWasInside = fr === window || fr === view || (fr as? NSView)?.isDescendant(of: view) == true
      || ((fr as? NSText)?.delegate as? NSView)?.isDescendant(of: view) == true
    guard focusWasInside else { return }
    // Only a responder still in this window (not one inside a surface that is gone meanwhile).
    if let p = e.previous as? NSView, p.window === window, top(in: window) == nil {
      window.makeFirstResponder(p)
    } else {
      window.makeFirstResponder(nil)
    }
  }

  /// The top surface of `window`, if any.
  public static func top(in window: NSWindow?) -> NSView? {
    prune()
    return entries.last(where: { $0.window === window && $0.view?.window === window })?.view
  }

  public static var isEmpty: Bool { prune(); return entries.isEmpty }

  /// Called for every key-down in a den window before AppKit dispatches it: focus that wandered
  /// out of the top surface (a page's `focus()`) is taken back, so the key reaches the surface.
  public static func route(_ event: NSEvent, in window: NSWindow) {
    guard event.type == .keyDown, let e = entries.last(where: { $0.window === window }), let view = e.view, view.window === window else { return }
    if contains(view, window.firstResponder) { return }
    take(e)
  }

  static func contains(_ view: NSView, _ r: NSResponder?) -> Bool {
    if let v = r as? NSView, v === view || v.isDescendant(of: view) { return true }
    if let t = r as? NSText, let owner = t.delegate as? NSView, owner.isDescendant(of: view) { return true }
    return false
  }

  static func take(_ e: Entry) {
    guard let w = e.window, let v = e.view, v.window === w else { return }
    if contains(v, w.firstResponder) && w.firstResponder !== w { return }
    let t = e.focus() ?? v
    if !w.makeFirstResponder(t) { w.makeFirstResponder(v) }
  }

  /// Drops surfaces that are gone, or were taken out of their window without `dismiss`.
  static func prune() { entries.removeAll { $0.view == nil || $0.window == nil || $0.view?.window == nil } }
}
