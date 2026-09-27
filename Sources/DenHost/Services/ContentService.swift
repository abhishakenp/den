import AppKit
import CordisValue
import WebKit

/// `content` service: which web views are on screen, and the peek overlay.
///
/// Methods:
///   show {panes: [webviewId], orientation?: horizontal|vertical|grid, ratios?: [number], focus?: id}
///        1 pane = single card; 2–4 = split with gaps. Web views not listed are detached from the
///        window (WebKit then suspends them); they are created on first show.
///   focus {id}                          -> highlight + first responder
///   peek {webview, title?}  / peek {}   -> show / hide the peek overlay card
///   get                                 -> {panes, orientation, focus, peek}
/// Events: content.focus {id}   content.peekAction {action: close|expand|split, webview}
///         content.paneAction {id, action: close|separate}   (split pane hover controls)
@MainActor
public final class ContentService: HostService {
  public let name = "content"
  let host: ServiceHost
  let webviews: WebViewsService
  let wc: DenWindowController

  public private(set) var panes: [String] = []
  public private(set) var orientation: SplitOrientation = .horizontal
  var ratios: [CGFloat] = []
  public private(set) var focused: String?
  private var cards: [String: CardView] = [:]
  private let emptyCard = CardView()
  public let peek = PeekOverlayView()
  public private(set) var peekId: String?
  private var clickMonitor: Any?
  /// While true, `show` lays out cards but doesn't create WKWebViews yet. The app holds them
  /// until the first window frame is on screen (launch time), then calls `releaseWebViews()`.
  public var holdWebViews = false
  /// Space accent for the focused-pane ring (set by the ui service on palette changes).
  public var accent: NSColor? { didSet { cards.values.forEach { $0.focusColor = accent } } }

  public init(host: ServiceHost, webviews: WebViewsService, window: DenWindowController) {
    self.host = host
    self.webviews = webviews
    self.wc = window
    wc.contentArea.addSubview(emptyCard)
    peek.isHidden = true
    wc.overlays.addSubview(peek, positioned: .below, relativeTo: nil)
    peek.onAction = { [weak self] action in self?.peekAction(action) }
    let prev = wc.onLayout
    wc.onLayout = { [weak self] in prev?(); self?.layout() }
    host.on("webviews.closed") { [weak self] v in self?.forget(v.str("id")) }
    host.on("webviews.detached") { [weak self] v in self?.cards[v.str("id")]?.clip.subviews.forEach { $0.removeFromSuperview() } }
    clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
      MainActor.assumeIsolated { self?.noteClick(e) }
      return e
    }
  }

  public func handle(method: String, args: Value) -> Value {
    switch method {
    case "show":
      let ids = args.list("panes").compactMap(\.string).filter { webviews.record($0) != nil }
      show(Array(ids.prefix(4)), orientation: SplitOrientation(rawValue: args.str("orientation", "horizontal")) ?? .horizontal,
           ratios: args.list("ratios").compactMap { $0.double.map { CGFloat($0) } }, focus: args["focus"].string)
    case "focus":
      setFocus(args.str("id"), makeFirstResponder: true)
    case "peek":
      let id = args.str("webview")
      if id.isEmpty { hidePeek() } else { showPeek(id, title: args.str("title")) }
    case "get":
      return ["panes": .array(panes.map { .string($0) }), "orientation": .string(orientation.rawValue),
              "focus": focused.map { .string($0) } ?? .null, "peek": peekId.map { .string($0) } ?? .null]
    default:
      return .error("content: unknown method '\(method)'")
    }
    return .ok
  }

  func show(_ ids: [String], orientation o: SplitOrientation, ratios r: [CGFloat], focus f: String?) {
    let old = Set(panes)
    panes = ids
    orientation = o
    ratios = r
    for id in old.subtracting(ids) where id != peekId {
      cards[id]?.removeFromSuperview()
      webviews.record(id)?.webView?.removeFromSuperview()
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
      if !holdWebViews, let w = webviews.materialize(id), w.superview !== card.clip {
        card.clip.subviews.forEach { $0.removeFromSuperview() }
        card.clip.addSubview(w)
      }
    }
    emptyCard.isHidden = !ids.isEmpty
    layout()
    setFocus(f ?? (ids.contains(focused ?? "") ? focused : ids.first), makeFirstResponder: true)
  }

  /// Ends `holdWebViews`: creates and attaches the web views of the panes on screen.
  public func releaseWebViews() {
    guard holdWebViews else { return }
    holdWebViews = false
    guard !panes.isEmpty else { return }
    show(panes, orientation: orientation, ratios: ratios, focus: focused)
  }

  /// Re-attaches the panes' web views (after `webviews` rebuilt them, e.g. for extensions).
  public func reattach() {
    guard !holdWebViews, !panes.isEmpty else { return }
    show(panes, orientation: orientation, ratios: ratios, focus: focused)
  }

  /// The card showing a pane (snapshots, tests).
  public func card(_ id: String) -> CardView? { cards[id] }

  func layout() {
    let b = wc.contentArea.bounds
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
    if makeFirstResponder, let w = webviews.record(id)?.webView { wc.window.makeFirstResponder(w) }
    if changed { host.emit("content.focus", ["id": .string(id)]) }
  }

  func noteClick(_ e: NSEvent) {
    guard e.window === wc.window, panes.count > 1 else { return }
    let p = wc.contentArea.convert(e.locationInWindow, from: nil)
    if let id = panes.first(where: { cards[$0]?.frame.contains(p) == true }) { setFocus(id, makeFirstResponder: false) }
  }

  func forget(_ id: String) {
    cards[id]?.removeFromSuperview()
    cards[id] = nil
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
  static let actions: [(String, String, String)] = [
    ("xmark", "close", "Close (Esc)"), ("arrow.up.left.and.arrow.down.right", "expand", "Open as Tab"), ("rectangle.split.2x1", "split", "Open in Split View"),
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
    for (sym, action, tip) in Self.actions {
      let b = IconButton(symbol: sym, size: Tokens.peekButtonSize.height) { [weak self] in self?.onAction?(action) }
      b.fixedTint = .white
      b.toolTip = tip
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
