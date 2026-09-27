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
      cards[id] = card
      if card.superview !== wc.contentArea { wc.contentArea.addSubview(card) }
      if let w = webviews.materialize(id), w.superview !== card.clip {
        card.clip.subviews.forEach { $0.removeFromSuperview() }
        card.clip.addSubview(w)
      }
    }
    emptyCard.isHidden = !ids.isEmpty
    layout()
    setFocus(f ?? (ids.contains(focused ?? "") ? focused : ids.first), makeFirstResponder: true)
  }

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

/// Floating peek card over the content area: dimmed backdrop, rounded card, buttons on top.
public final class PeekOverlayView: FlippedView {
  let backdrop = NSView()
  let card = CardView()
  let bar = FlippedView()
  let titleLabel = NSTextField(labelWithString: "")
  var onAction: ((String) -> Void)?
  var title: String {
    get { titleLabel.stringValue }
    set { titleLabel.stringValue = newValue }
  }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    backdrop.wantsLayer = true
    backdrop.layer?.backgroundColor = NSColor(white: 0, alpha: Tokens.peekBackdropAlpha).cgColor
    backdrop.layer?.cornerRadius = Tokens.cardCornerRadius
    addSubview(backdrop)
    card.cornerRadius = Tokens.peekCornerRadius
    card.layer?.shadowRadius = 18
    card.layer?.shadowOpacity = 0.3
    addSubview(card)
    titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
    titleLabel.textColor = .white
    titleLabel.lineBreakMode = .byTruncatingMiddle
    bar.addSubview(titleLabel)
    for (i, (sym, action)) in [("xmark", "close"), ("rectangle.split.2x1", "split"), ("arrow.up.left.and.arrow.down.right", "expand")].enumerated() {
      let b = IconButton(symbol: sym, size: 24) { [weak self] in self?.onAction?(action) }
      b.fixedTint = .white
      b.tag = i
      bar.addSubview(b)
    }
    bar.wantsLayer = true
    bar.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.72).cgColor  // estimate
    bar.layer?.cornerRadius = 8
    bar.layer?.cornerCurve = .continuous
    addSubview(bar)
  }
  required init?(coder: NSCoder) { fatalError() }

  func setWeb(_ w: WKWebView?) {
    card.clip.subviews.forEach { $0.removeFromSuperview() }
    if let w { card.clip.addSubview(w); card.needsLayout = true }
  }

  public override func mouseDown(with event: NSEvent) {
    // Click outside the card closes the peek.
    if !card.frame.contains(convert(event.locationInWindow, from: nil)) { onAction?("close") }
  }

  public override func layout() {
    super.layout()
    backdrop.frame = bounds
    let i = Tokens.peekInset
    card.frame = bounds.insetBy(dx: i, dy: i).offsetBy(dx: 0, dy: 10)
    let bw = min(card.frame.width, max(200, ceil(titleLabel.intrinsicContentSize.width) + 110))
    bar.frame = NSRect(x: card.frame.maxX - bw, y: card.frame.minY - 34, width: bw, height: 28)
    var x = bar.bounds.width
    for v in bar.subviews.compactMap({ $0 as? IconButton }).sorted(by: { $0.tag < $1.tag }) {
      x -= 28
      v.frame = NSRect(x: x, y: 2, width: 24, height: 24)
    }
    titleLabel.frame = NSRect(x: 10, y: 5, width: max(0, x - 12), height: 18)
  }

  func animateIn() {
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { alphaValue = 1; return }
    alphaValue = 0
    NSAnimationContext.runAnimationGroup { c in
      c.duration = Tokens.animationDuration
      animator().alphaValue = 1
    }
  }

  func animateOut(_ done: @escaping @MainActor () -> Void) {
    NSAnimationContext.runAnimationGroup({ c in
      c.duration = Tokens.animationDuration * 0.8
      animator().alphaValue = 0
    }, completionHandler: { MainActor.assumeIsolated { done() } })
  }
}
