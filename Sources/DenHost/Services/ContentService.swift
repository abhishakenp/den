import AppKit
import CordisValue
import WebKit

/// `content` service: which web views are on screen, and the peek overlay.
///
/// Methods:
///   show {panes: [webviewId], orientation?: horizontal|vertical|grid, ratios?: [number], focus?: id, window?}
///        1 pane = single card; 2–4 = split with gaps. Web views not listed are detached from the
///        window (WebKit then suspends them); they are created on first show.
///   focus {id}                          -> highlight + first responder
///   peek {webview, title?}  / peek {}   -> show / hide the peek overlay card
///   side {webview, width?} / side {}    -> show / hide a web view in the side column: a narrow card at the
///                                          content's left edge, beside whatever the panes show, sliding out
///                                          from the sidebar edge. Its header is the `side.header` ui slot.
///                                          Hidden, the web view leaves the window (the caller may discard it)
///   get {window?}                       -> {panes, orientation, focus, peek, side, sideWidth, window}
/// Every method acts on the active window unless `window` names another (docs/host-api.md#window).
/// A page is live in one window at a time: showing it in a second window moves it there, and the
/// first shows "Open in another window" until it takes the page back (it becomes active again,
/// or its "Show Here" is clicked).
/// Events: content.focus {id}   content.peekAction {action: close|expand|split, webview}
///         content.paneAction {id, action: close|separate}   (split pane hover controls)
@MainActor
public final class ContentService: HostService {
  public let name = "content"
  let host: ServiceHost
  let webviews: WebViewsService
  let windows: WindowSet
  /// Per-window panes, cards and peek, by window id.
  private(set) var byWindow: [String: WindowContent] = [:]
  private var clickMonitor: Any?
  /// While true, `show` lays out cards but doesn't create WKWebViews yet. The app holds them
  /// until the first window frame is on screen (launch time), then calls `releaseWebViews()`.
  public var holdWebViews = false
  /// Space accent for the focused-pane ring (set by the ui service on palette changes).
  public var accent: NSColor? { didSet { current.accent = accent } }
  /// Told about each live page leaving the screen (a tab switch), its web view still in the
  /// window (the `media` service may put its video in picture in picture).
  public var leaving: ((String) -> Void)?
  /// Called before a live page's web view goes (back) into its card (a PiP den started ends).
  public var willAttach: ((String) -> Void)?
  /// Longest a restore placeholder stays up.
  public var coverTimeout: TimeInterval = 1.5
  /// Longest the previous page is held.
  public var holdTimeout: TimeInterval = Tokens.paintHoldTimeout
  /// The active window's side column (`side`): one web view docked left of the panes (the
  /// `panels` plugin's web panels). Nothing is created until the first `side`.
  public var sideIfLoaded: SideColumnView? { current.sideView }
  public var side: SideColumnView { current.side }
  public var sideId: String? { current.sideId }
  public var sideWidth: CGFloat { current.sideWidth }
  static let sideWidths: ClosedRange<CGFloat> = 280...520

  public init(host: ServiceHost, webviews: WebViewsService, windows: WindowSet) {
    self.host = host
    self.webviews = webviews
    self.windows = windows
    windows.each { [unowned self] wc in self.byWindow[wc.id] = WindowContent(svc: self, wc: wc) }
    windows.onRemove.append { [weak self] wc in self?.byWindow.removeValue(forKey: wc.id)?.tearDown() }
    // A window that becomes active takes back a page another window borrowed.
    windows.onActivate.append { [weak self] _, wc in self?.byWindow[wc.id]?.reclaim() }
    windows.describe = { [weak self] wc in
      let c = self?.byWindow[wc.id]
      return ["id": .string(wc.id), "private": .bool(wc.isPrivate), "page": .int(Int64(wc.page)),
              "panes": .array((c?.panes ?? []).map { .string($0) }), "focus": c?.focused.map { .string($0) } ?? .null]
    }
    host.on("webviews.closed") { [weak self] v in self?.byWindow.values.forEach { $0.forget(v.str("id")) } }
    host.on("webviews.detached") { [weak self] v in self?.byWindow.values.forEach { $0.detached(v.str("id")) } }
    let prevFinish = webviews.onFinish
    webviews.onFinish = { [weak self] id in prevFinish?(id); self?.byWindow.values.forEach { $0.uncover(id) } }
    let prevPainted = webviews.onPainted
    webviews.onPainted = { [weak self] id in prevPainted?(id); self?.byWindow.values.forEach { $0.painted(id) } }
    clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
      MainActor.assumeIsolated { self?.byWindow.values.first { $0.wc.window === e.window }?.noteClick(e) }
      return e
    }
  }

  /// The active window's content.
  var current: WindowContent { byWindow[windows.active.id]! }
  /// A window's content (tests, the window service).
  func content(of window: String) -> WindowContent? { byWindow[window] }

  public var panes: [String] { current.panes }
  public var orientation: SplitOrientation { current.orientation }
  public var focused: String? { current.focused }
  public var peekId: String? { current.peekId }
  public var peek: PeekOverlayView { current.peek }
  public var held: String? { current.held }

  public func handle(method: String, args: Value) -> Value {
    var target = current
    if let w = args["window"].string {
      guard let c = byWindow[w] else { return .error("content: no window '\(w)'") }
      target = c
    }
    switch method {
    case "show":
      let ids = args.list("panes").compactMap(\.string).filter { webviews.record($0) != nil }
      target.show(Array(ids.prefix(4)), orientation: SplitOrientation(rawValue: args.str("orientation", "horizontal")) ?? .horizontal,
                  ratios: args.list("ratios").compactMap { $0.double.map { CGFloat($0) } }, focus: args["focus"].string)
    case "focus":
      target.setFocus(args.str("id"), makeFirstResponder: true)
    case "peek":
      let id = args.str("webview")
      if id.isEmpty { target.hidePeek() } else { target.showPeek(id, title: args.str("title")) }
    case "side":
      let id = args.str("webview")
      guard id.isEmpty || webviews.record(id) != nil else { return .error("content: no webview '\(id)'") }
      target.setSide(id.isEmpty ? nil : id, width: args["width"].double.map { CGFloat($0) })
    case "get":
      return ["panes": .array(target.panes.map { .string($0) }), "orientation": .string(target.orientation.rawValue),
              "focus": target.focused.map { .string($0) } ?? .null, "peek": target.peekId.map { .string($0) } ?? .null,
              "side": target.sideId.map { .string($0) } ?? .null, "sideWidth": .double(Double(target.sideWidth)),
              "window": .string(target.wc.id)]
    default:
      return .error("content: unknown method '\(method)'")
    }
    return .ok
  }

  /// The window content whose card, peek, parking or holding view has `w` (at most one).
  func owner(of w: WKWebView) -> WindowContent? {
    guard let win = w.window else { return nil }
    return byWindow.values.first { $0.wc.window === win }
  }

  /// Whether a restore placeholder is up (tests, scenarios).
  public func isCovered(_ id: String) -> Bool { byWindow.values.contains { $0.isCovered(id) } }

  /// Ends `holdWebViews`: creates and attaches the web views of the panes on screen, in every
  /// window (restored windows included), the active one last so it wins a shared page.
  public func releaseWebViews() {
    guard holdWebViews else { return }
    holdWebViews = false
    let active = current
    for c in byWindow.values where c !== active { c.reshow() }
    active.reshow()
  }

  /// Re-attaches the panes' web views (after `webviews` rebuilt them, e.g. for extensions).
  public func reattach() {
    guard !holdWebViews else { return }
    current.reshow()
  }

  /// The card showing a pane (snapshots, tests): the active window's first.
  public func card(_ id: String) -> CardView? { current.cards[id] ?? byWindow.values.lazy.compactMap { $0.cards[id] }.first }
}

/// One window's content area: its panes and their cards, the peek overlay, and the views that
/// keep tab switches flash-free (parking, holding, snapshot covers).
@MainActor
final class WindowContent {
  unowned let svc: ContentService
  let wc: DenWindowController
  var host: ServiceHost { svc.host }
  var webviews: WebViewsService { svc.webviews }
  /// This window's side column (web panels); built on first use.
  private(set) var sideView: SideColumnView?
  var side: SideColumnView {
    if let s = sideView { return s }
    let s = SideColumnView()
    s.isHidden = true
    sideView = s
    return s
  }
  private(set) var sideId: String?
  private(set) var sideWidth: CGFloat = 360
  static var sideWidths: ClosedRange<CGFloat> { ContentService.sideWidths }

  private(set) var panes: [String] = []
  private(set) var orientation: SplitOrientation = .horizontal
  var ratios: [CGFloat] = []
  private(set) var focused: String?
  fileprivate(set) var cards: [String: CardView] = [:]
  private let emptyCard = CardView()
  /// What an empty space shows in its card (Arc: "Open your first tab." over a ⌘T keycap).
  let emptyState = EmptyStateView()
  /// Where a page that just left the screen waits (invisible, still in the window) while its
  /// snapshot is taken: WebKit only snapshots a view that is in a window.
  private let parking = NSView()
  let peek = PeekOverlayView()
  private(set) var peekId: String?
  var accent: NSColor? { didSet { cards.values.forEach { $0.focusColor = accent } } }
  /// Restore placeholders: a discarded page's snapshot, shown until the page has loaded.
  private var covers: [String: NSView] = [:]
  /// The previous page, kept on screen over a new one until the new one first paints (no white
  /// flash on a tab switch). It takes no clicks.
  private let holding = HoldView()
  private(set) var held: String?
  /// Panes whose page another window has on screen right now ("Open in another window").
  private var elsewhere: [String: ElsewhereView] = [:]

  init(svc: ContentService, wc: DenWindowController) {
    self.svc = svc
    self.wc = wc
    accent = svc.accent
    wc.contentArea.addSubview(emptyCard)
    emptyCard.clip.addSubview(emptyState)
    parking.alphaValue = 0
    wc.contentArea.addSubview(parking, positioned: .below, relativeTo: nil)
    peek.isHidden = true
    wc.overlays.addSubview(peek, positioned: .below, relativeTo: nil)
    peek.onAction = { [weak self] action in self?.peekAction(action) }
    let prev = wc.onLayout
    wc.onLayout = { [weak self] in prev?(); self?.layout() }
    holding.isHidden = true
    wc.contentArea.addSubview(holding)
  }

  /// The window closed for good: its pages leave it (they stay alive for the other windows).
  func tearDown() {
    releaseHold()
    for id in panes { if let w = webviews.record(id)?.webView, w.window === wc.window { w.removeFromSuperview() } }
    if let id = peekId, let w = webviews.record(id)?.webView, w.window === wc.window { w.removeFromSuperview() }
    if let id = sideId, let w = webviews.record(id)?.webView, w.window === wc.window { w.removeFromSuperview() }
    for w in parking.subviews { w.removeFromSuperview() }
    panes = []
    cards = [:]
    peekId = nil
  }

  func show(_ ids: [String], orientation o: SplitOrientation, ratios r: [CGFloat], focus f: String?) {
    let old = Set(panes)
    releaseHold()
    // One page replacing another (a tab switch): the old one may be held until the new paints.
    let switching = old.count == 1 && ids.count == 1 && !old.contains(ids[0]) && peekId == nil
    var leaving: (id: String, view: WKWebView, frame: NSRect)?
    panes = ids
    orientation = o
    ratios = r
    for id in old.subtracting(ids) where id != peekId {
      cards[id]?.removeFromSuperview()
      elsewhere.removeValue(forKey: id)?.removeFromSuperview()
      uncover(id, animated: false)
      guard let r = webviews.record(id), let w = r.webView, w.superview != nil, w.superview === cards[id]?.clip else { continue }
      svc.leaving?(id)
      // Keep a picture of the page on disk (for a later restore and for previews), then let it go.
      parking.frame = cards[id]?.frame ?? w.frame
      parking.addSubview(w)
      webviews.captureSnapshot(r) { [weak self, weak w] in
        guard let self, let w, w.superview === self.parking else { return }
        w.removeFromSuperview()
      }
      // Still waiting in the window for its snapshot: it can be held on screen instead.
      if switching, w.superview === parking { leaving = (id, w, parking.frame) }
    }
    for id in ids {
      let card = cards[id] ?? CardView()
      if cards[id] == nil {
        card.focusColor = accent
        card.onPaneAction = { [weak self] a in self?.host.emit("content.paneAction", ["id": .string(id), "action": .string(a)]) }
      }
      cards[id] = card
      card.showsPaneControls = ids.count > 1
      if card.superview !== wc.contentArea { wc.contentArea.addSubview(card) }
      if !svc.holdWebViews {
        let wasLive = webviews.record(id)?.webView != nil
        if wasLive { svc.willAttach?(id) }
        if let w = webviews.materialize(id), w.superview !== card.clip {
          // The page is on screen in another window: it moves here, and that window says so.
          if let other = svc.owner(of: w), other !== self { other.lost(id) }
          card.clip.subviews.forEach { $0.removeFromSuperview() }
          elsewhere[id] = nil
          card.clip.addSubview(w)
          if !wasLive { cover(id, in: card) }
        }
        webviews.showCrashPageIfNeeded(id)
        // Behind a page that hasn't painted: its own colour, never a white card.
        card.pageColor = webviews.record(id)?.painted == true ? nil : webviews.expectedBackground(id)
      }
    }
    // Hold the previous page over a new one that hasn't painted (and has no snapshot cover).
    // (A blank page has nothing to paint and nothing to flash: it isn't waited for.)
    if let l = leaving, let new = ids.first, let nr = webviews.record(new), !nr.painted, nr.url != "about:blank", covers[new] == nil, !svc.holdWebViews {
      hold(l.id, l.view, frame: l.frame)
    }
    emptyCard.isHidden = !ids.isEmpty
    if ids.isEmpty { emptyState.refresh() }
    layout()
    setFocus(f ?? (ids.contains(focused ?? "") ? focused : ids.first), makeFirstResponder: true)
  }

  /// Shows the same panes again (attaching web views that aren't in their cards).
  func reshow() {
    guard !panes.isEmpty else { return }
    show(panes, orientation: orientation, ratios: ratios, focus: focused)
  }

  /// Another window took `id`'s page: its card shows where it went until this window takes it back.
  func lost(_ id: String) {
    if held == id { releaseHold() }
    if peekId == id { hidePeek() }
    guard let card = cards[id], elsewhere[id] == nil else { return }
    uncover(id, animated: false)
    let v = ElsewhereView(url: webviews.record(id)?.url ?? "", palette: Palette(theme: wc.currentTheme, dark: wc.isDark)) { [weak self] in
      guard let self else { return }
      self.svc.windows.activate(self.wc)
      self.reclaim()
    }
    card.clip.addSubview(v)
    v.frame = card.clip.bounds
    elsewhere[id] = v
  }

  /// This window became active: take back any of its pages another window has on screen.
  func reclaim() {
    guard !svc.holdWebViews, !elsewhere.isEmpty else { return }
    reshow()
  }

  /// A restored (previously discarded) page shows its last snapshot at once, over the new web
  /// view, until the page has loaded (or `coverTimeout`), then fades to the live page.
  func cover(_ id: String, in card: CardView) {
    guard covers[id] == nil, let img = webviews.storedSnapshot(id) else { return }
    let v = SnapshotCover(image: img)
    card.clip.addSubview(v)
    v.frame = card.clip.bounds
    covers[id] = v
    DispatchQueue.main.asyncAfter(deadline: .now() + svc.coverTimeout) { [weak self, weak v] in
      MainActor.assumeIsolated { if let v, self?.covers[id] === v { self?.uncover(id) } }
    }
  }

  func uncover(_ id: String, animated: Bool = true) {
    guard let v = covers.removeValue(forKey: id) else { return }
    guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { v.removeFromSuperview(); return }
    NSAnimationContext.runAnimationGroup({ c in
      c.duration = 0.15
      v.animator().alphaValue = 0
    }, completionHandler: { MainActor.assumeIsolated { v.removeFromSuperview() } })
  }

  func isCovered(_ id: String) -> Bool { covers[id] != nil }

  private func hold(_ id: String, _ w: WKWebView, frame: NSRect) {
    held = id
    holding.frame = frame
    holding.isHidden = false
    wc.contentArea.addSubview(holding, positioned: .above, relativeTo: nil)
    holding.addSubview(w)
    w.frame = holding.bounds
    DispatchQueue.main.asyncAfter(deadline: .now() + svc.holdTimeout) { [weak self] in
      MainActor.assumeIsolated { if self?.held == id { self?.releaseHold() } }
    }
  }

  /// Lets go of the held page: back to parking while its snapshot is still being taken (the
  /// snapshot's completion takes it out of the window), else out of the window now.
  func releaseHold() {
    guard let id = held else { return }
    held = nil
    holding.isHidden = true
    let capturing = webviews.record(id)?.isCapturingSnapshot ?? false
    for w in holding.subviews {
      if capturing { parking.addSubview(w) } else { w.removeFromSuperview() }
    }
  }

  /// A page drew its first frame: it no longer needs the held page or its placeholder colour.
  func painted(_ id: String) {
    cards[id]?.pageColor = nil
    if panes.contains(id), held != nil { releaseHold() }
  }

  func detached(_ id: String) {
    if id == sideId { sideView?.card.clip.subviews.forEach { $0.removeFromSuperview() } }
    guard let card = cards[id] else { return }
    for v in card.clip.subviews where !(v is ElsewhereView) { v.removeFromSuperview() }
  }


  /// Shows `id` in the side column (nil hides it), sliding it out from (or back into) the sidebar
  /// edge while the panes make room. The previous side web view leaves the window.
  func setSide(_ id: String?, width: CGFloat?) {
    if let width { sideWidth = min(max(width, Self.sideWidths.lowerBound), Self.sideWidths.upperBound) }
    let old = sideId
    if old == id, id == nil { return }
    if side.superview !== wc.contentArea { wc.contentArea.addSubview(side) }
    if let old, old != id, let w = webviews.record(old)?.webView, w.superview === side.card.clip { w.removeFromSuperview() }
    sideId = id
    if let id, let w = webviews.materialize(id), w.superview !== side.card.clip {
      side.card.clip.subviews.forEach { $0.removeFromSuperview() }
      side.card.clip.addSubview(w)
      side.card.needsLayout = true
    }
    let appearing = old == nil && id != nil
    if appearing {
      // Start closed at the sidebar edge, then open.
      side.isHidden = false
      side.frame = NSRect(x: 0, y: 0, width: 0, height: wc.contentArea.bounds.height)
      side.layoutSubtreeIfNeeded()
    }
    let animate = old == nil || id == nil
    if animate, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, wc.window.isVisible {
      NSAnimationContext.runAnimationGroup({ c in
        c.duration = 0.25  // estimate: a slide, slower than the sidebar's 83 ms show
        c.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)  // estimate: Dia's easing (spec §13)
        c.allowsImplicitAnimation = true
        self.layout()
        self.wc.contentArea.layoutSubtreeIfNeeded()
      }, completionHandler: { MainActor.assumeIsolated { if self.sideId == nil { self.side.isHidden = true } } })
    } else {
      layout()
      if sideId == nil { side.isHidden = true }
    }
    if let id, let w = webviews.record(id)?.webView, appearing { wc.window.makeFirstResponder(w) }
  }

  /// The side column's frame (width 0 while closed) and the area left for the panes.
  func sideSplit(_ b: NSRect) -> (side: NSRect, panes: NSRect) {
    guard sideId != nil else { return (NSRect(x: b.minX, y: b.minY, width: 0, height: b.height), b) }
    let w = min(sideWidth, max(0, b.width - 320))
    sideView?.openWidth = w
    let gap = Tokens.splitGap
    return (NSRect(x: b.minX, y: b.minY, width: w, height: b.height), NSRect(x: b.minX + w + gap, y: b.minY, width: max(0, b.width - w - gap), height: b.height))
  }

  func layout() {
    let (sf, b) = sideSplit(wc.contentArea.bounds)
    if let s = sideView, s.superview != nil { s.frame = sf }
    emptyCard.frame = b
    let frames = SplitLayout.frames(count: panes.count, orientation: orientation, in: b, gap: Tokens.splitGap, ratios: ratios)
    for (id, f) in zip(panes, frames) {
      cards[id]?.frame = f
      cards[id]?.needsLayout = true
    }
    layoutPeek()
  }

  func setFocus(_ id: String?, makeFirstResponder: Bool) {
    guard let id, panes.contains(id) else { return }
    let changed = id != focused
    focused = id
    for (cid, card) in cards { card.focused = panes.count > 1 && cid == id }
    if makeFirstResponder, let w = webviews.record(id)?.webView, w.window === wc.window { wc.window.makeFirstResponder(w) }
    if changed { host.emit("content.focus", ["id": .string(id)]) }
  }

  func noteClick(_ e: NSEvent) {
    guard e.window === wc.window, panes.count > 1 else { return }
    let p = wc.contentArea.convert(e.locationInWindow, from: nil)
    if let id = panes.first(where: { cards[$0]?.frame.contains(p) == true }) { setFocus(id, makeFirstResponder: false) }
  }

  func forget(_ id: String) {
    if id == sideId { setSide(nil, width: nil) }
    if held == id { releaseHold() }
    cards[id]?.removeFromSuperview()
    cards[id] = nil
    elsewhere[id] = nil
    if panes.contains(id) {
      panes.removeAll { $0 == id }
      emptyCard.isHidden = !panes.isEmpty
      layout()
    }
    if peekId == id { hidePeek() }
  }

  // MARK: Peek

  func showPeek(_ id: String, title: String) {
    guard let w = webviews.materialize(id) else { return }
    if let other = svc.owner(of: w), other !== self { other.lost(id) }
    peekId = id
    peek.title = title.isEmpty ? (webviews.record(id)?.url ?? "") : title
    peek.setWeb(w)
    peek.isHidden = false
    layoutPeek()
    peek.animateIn()
    wc.window.makeFirstResponder(w)
  }

  func hidePeek() {
    guard peekId != nil else { return }
    peekId = nil
    peek.animateOut { [weak self] in
      guard let self, self.peekId == nil else { return }
      self.peek.isHidden = true
      self.peek.setWeb(nil)
    }
  }

  func layoutPeek() {
    // The overlay covers the content area; the card is inset within it.
    peek.frame = wc.overlays.convert(wc.contentArea.frame, from: wc.contentArea.superview)
  }

  func peekAction(_ action: String) {
    guard let id = peekId else { return }
    host.emit("content.peekAction", ["action": .string(action), "webview": .string(id)])
  }
}

/// A pane whose page another window has on screen (a tab shows in one window at a time, Arc's
/// "Tab Handoff"): a quiet note and "Show Here", which brings the page back to this window.
final class ElsewhereView: FlippedView {
  let label = makeLabel("Open in another window", size: 15, weight: .semibold)
  let detail = makeLabel("", size: 12)
  let button: PillButton

  init(url: String, palette: Palette, onShow: @escaping () -> Void) {
    button = PillButton(title: "Show Here", style: "default", action: onShow)
    super.init(frame: .zero)
    wantsLayer = true
    detail.stringValue = URL(string: url)?.host() ?? url
    detail.lineBreakMode = .byTruncatingMiddle
    label.alignment = .center
    detail.alignment = .center
    for v in [label, detail, button] as [NSView] { addSubview(v) }
    apply(palette)
  }
  required init?(coder: NSCoder) { fatalError() }

  func apply(_ p: Palette) {
    layer?.backgroundColor = p.surface.cgColor
    label.textColor = p.textPrimary
    detail.textColor = p.textSecondary
    button.apply(p)
  }

  override func layout() {
    super.layout()
    let w = max(0, min(bounds.width - 40, Tokens.elsewhereWidth))
    let bw = button.preferredWidth, bh = Tokens.elsewhereButtonHeight
    var y = ((bounds.height - (20 + 6 + 16 + 16 + bh)) / 2).rounded()
    label.frame = NSRect(x: ((bounds.width - w) / 2).rounded(), y: y, width: w, height: 20)
    y += 26
    detail.frame = NSRect(x: ((bounds.width - w) / 2).rounded(), y: y, width: w, height: 16)
    y += 32
    button.frame = NSRect(x: ((bounds.width - bw) / 2).rounded(), y: y, width: bw, height: bh)
  }
}

/// The previous page, held over a new one until it paints. Clicks go through to the new page.
final class HoldView: FlippedView {
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = Tokens.cardCornerRadius
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = true
  }
  required init?(coder: NSCoder) { fatalError() }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A discarded page's last snapshot, standing in for it while the restored page loads. It never
/// takes clicks (they go to the live page underneath).
final class SnapshotCover: NSView {
  init(image: CGImage) {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.contents = image
    layer?.contentsGravity = .resizeAspectFill
    // Where the image doesn't reach: the page's own colour (sampled from it), never white.
    layer?.backgroundColor = WebViewsService.backgroundColor(of: image) ?? NSColor.clear.cgColor
  }
  required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Floating peek card over the content area: dimmed backdrop, rounded card, and a column of round
/// buttons (close, expand to a tab, open in split) just right of the card's top edge, the same
/// side-control placement as Little Arc (spec §8: 34x33 side buttons). Opens with a quick scale-and-
/// fade; every size and timing here is an estimate (Peek is UNVERIFIED, spec §12).
public final class PeekOverlayView: FlippedView {
  let backdrop = NSView()
  let card = CardView()
  let titleLabel = NSTextField(labelWithString: "")
  let titlePill = FlippedView()
  var buttons: [IconButton] = []
  var onAction: ((String) -> Void)?
  var title: String {
    get { titleLabel.stringValue }
    set { titleLabel.stringValue = newValue; needsLayout = true }
  }
  /// (symbol, action, tooltip, the menu bar item whose shortcut the tooltip shows, fallback chord).
  static let actions: [(String, String, String, String, String)] = [
    ("xmark", "close", "Close", "view.closePeek", "esc"), ("arrow.up.left.and.arrow.down.right", "expand", "Open as Tab", "file.openInSpace", "cmd+o"),
    ("rectangle.split.2x1", "split", "Open in Split View", "", ""),
  ]

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    backdrop.wantsLayer = true
    backdrop.layer?.backgroundColor = NSColor(white: 0, alpha: Tokens.peekBackdropAlpha).cgColor
    backdrop.layer?.cornerRadius = Tokens.cardCornerRadius
    addSubview(backdrop)
    card.cornerRadius = Tokens.peekCornerRadius
    card.layer?.shadowRadius = Tokens.peekShadowRadius
    card.layer?.shadowOpacity = Tokens.peekShadowOpacity
    card.layer?.shadowOffset = CGSize(width: 0, height: -10)
    addSubview(card)
    titlePill.wantsLayer = true
    titlePill.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.72).cgColor
    titlePill.layer?.cornerRadius = 11
    titlePill.layer?.cornerCurve = .continuous
    titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
    titleLabel.textColor = NSColor(white: 1, alpha: 0.9)
    titleLabel.lineBreakMode = .byTruncatingMiddle
    titlePill.addSubview(titleLabel)
    addSubview(titlePill)
    for (sym, action, tip, ref, fallback) in Self.actions {
      let b = IconButton(symbol: sym, size: Tokens.peekButtonSize.height) { [weak self] in self?.onAction?(action) }
      b.fixedTint = .white
      b.setTip(tip, shortcut: ref, fallback: fallback)
      b.wantsLayer = true
      b.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.72).cgColor  // estimate
      b.layer?.cornerRadius = Tokens.peekButtonSize.height / 2
      buttons.append(b)
      addSubview(b)
    }
  }
  required init?(coder: NSCoder) { fatalError() }

  func setWeb(_ w: WKWebView?) {
    card.clip.subviews.forEach { $0.removeFromSuperview() }
    if let w { card.clip.addSubview(w); card.needsLayout = true }
  }

  public override func mouseDown(with event: NSEvent) {
    // Click outside the card (and its buttons) closes the peek.
    if !card.frame.contains(convert(event.locationInWindow, from: nil)) { onAction?("close") }
  }

  var cardFrame: NSRect {
    let x = Tokens.peekInsetX, y = Tokens.peekInsetY
    return NSRect(x: x, y: y, width: max(0, bounds.width - 2 * x), height: max(0, bounds.height - 2 * y)).integral
  }

  public override func layout() {
    super.layout()
    backdrop.frame = bounds
    card.frame = cardFrame
    let bs = Tokens.peekButtonSize
    for (i, b) in buttons.enumerated() {
      b.frame = NSRect(x: card.frame.maxX + Tokens.peekButtonGap, y: card.frame.minY + CGFloat(i) * (bs.height + 6), width: bs.width, height: bs.height)
    }
    let tw = min(card.frame.width - 40, ceil(titleLabel.textWidth) + 22)
    titlePill.isHidden = title.isEmpty
    titlePill.frame = NSRect(x: (card.frame.midX - tw / 2).rounded(), y: card.frame.minY - 28, width: tw, height: 22)
    titleLabel.frame = titlePill.bounds.insetBy(dx: 10, dy: 3)
  }

  /// Transform that scales a layer about its center (layers are anchored at their origin here).
  static func scale(_ s: CGFloat, size: CGSize) -> CATransform3D {
    var t = CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0)
    t = CATransform3DScale(t, s, s, 1)
    return CATransform3DTranslate(t, -size.width / 2, -size.height / 2, 0)
  }

  func animateIn() {
    alphaValue = 1
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
    layoutSubtreeIfNeeded()
    let curve = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)  // estimate: Dia's web easing (spec §13)
    for v in [backdrop, titlePill] + buttons {
      let f = CABasicAnimation(keyPath: "opacity")
      f.fromValue = 0
      f.toValue = 1
      f.duration = Tokens.peekOpenDuration
      f.timingFunction = curve
      v.layer?.add(f, forKey: "peekIn")
    }
    if let l = card.layer {
      let g = CAAnimationGroup()
      let sc = CABasicAnimation(keyPath: "transform")
      sc.fromValue = Self.scale(Tokens.peekOpenScale, size: card.bounds.size)
      sc.toValue = CATransform3DIdentity
      let op = CABasicAnimation(keyPath: "opacity")
      op.fromValue = 0
      op.toValue = 1
      g.animations = [sc, op]
      g.duration = Tokens.peekOpenDuration
      g.timingFunction = curve
      l.add(g, forKey: "peekIn")
    }
  }

  func animateOut(_ done: @escaping @MainActor () -> Void) {
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { done(); return }
    NSAnimationContext.runAnimationGroup({ c in
      c.duration = Tokens.peekCloseDuration
      c.timingFunction = CAMediaTimingFunction(name: .easeIn)
      animator().alphaValue = 0
    }, completionHandler: { MainActor.assumeIsolated {
      self.alphaValue = 1
      done()
    } })
  }
}

/// The side column: an optional header (the `side.header` ui slot) over a card holding one web
/// view. The card keeps its full width while the column opens or closes, anchored to the column's
/// right edge, so it slides out from (and back under) the sidebar edge instead of squeezing.
public final class SideColumnView: FlippedView {
  let header = SlotView()
  let card = CardView()
  /// The width the card is laid out at (the column's open width).
  var openWidth: CGFloat = 360

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = true
    addSubview(card)
    addSubview(header)
  }
  required init?(coder: NSCoder) { fatalError() }

  public override func layout() {
    super.layout()
    let w = max(bounds.width, openWidth)
    let hh = header.height(for: w)
    let x = bounds.width - w
    header.frame = NSRect(x: x, y: 0, width: w, height: hh)
    card.frame = NSRect(x: x, y: hh > 0 ? hh + 6 : 0, width: w, height: max(0, bounds.height - (hh > 0 ? hh + 6 : 0)))
  }
}
