import AppKit
import CordisValue
import os

// `ui.card`: the generic popover card (docs/host-api.md "ui.card"). A plugin composes the card from
// generic nodes (CardNodes.swift); the host owns only what is platform- and pointer-bound:
//
// - `HoverIntent` decides *when*: a dwell before the first card (per node: `hoverIntent` ms),
//   a hard-cut swap while a card is up (optionally after a second dwell), a grace period on
//   mouse-out, and nothing while a row is being clicked.
// - `CardController` places cards (next to a node, below-right of a tile, or below a window rect),
//   animates them in and out, keeps a card open while the pointer is on it, and runs the card's
//   button shortcuts while it is showing.
// - `PopoverCard` is the surface: Dia's neutral card from the theme tokens (`ThemeTokens.card`).
//
// Nothing here runs until the pointer rests on a node that asks for it: no timers, no views, no
// key monitor.

extension Tokens {
  // Timings and geometry measured on Dia 1.50.1 (docs/reference/dia-ui-spec.md §2.2–§2.4, §9).
  public static let cardRowDelayMs = 700  // list rows: 685–915 ms measured; den default §2.4
  public static let cardTileDelayMs = 300  // pinned tiles: 285–416 ms measured
  public static let cardGraceMs = 200  // exit grace: fade starts +202–267 ms after leaving
  public static let cardWarmMs = 600  // den: after a card closes, the next row shows at once for 0.6 s
  public static let cardInMs = 180  // entrance: opacity 0→1 + scale 0.93→1, settles in 150–230 ms
  public static let cardOutMs = 100  // exit: opacity 1→0 + scale →0.93, 80–130 ms
  public static let cardScale: CGFloat = 0.93  // anchored at the top-leading corner
  public static let cardRadius: CGFloat = 12
  public static let cardGap: CGFloat = 3  // card x = row maxX + 3; tile: maxX − 3, maxY − 3
  public static let cardBelowGap: CGFloat = 8  // below a link or tab (spec §3.1: ~8 pt)
  public static let cardMinWidth: CGFloat = 170
  public static let cardMaxWidth: CGFloat = 200
  public static let cardMargin: CGFloat = 8  // den: kept inside the window by this much
  public static let cardTooltipDelayMs = 500  // den: Dia's tooltip delay wasn't measured
}

/// Hover intent state machine. Pure logic: time and timers are injected, so tests drive it with a
/// manual clock.
@MainActor
public final class HoverIntent {
  public var delayMs = Tokens.cardRowDelayMs
  public var graceMs = Tokens.cardGraceMs
  public var warmMs = Tokens.cardWarmMs
  /// With a card up, moving to another anchor waits for that anchor's dwell before the (hard-cut)
  /// swap, like Dia (§2.4). Off (default): the swap is immediate, like Arc.
  public var redwell = false
  /// Runs `f` after `ms`; returns a cancel function.
  let schedule: (Int, @escaping @MainActor () -> Void) -> () -> Void
  let now: () -> Double
  /// A card is wanted for this anchor (the previous anchor, if any, is replaced).
  public var onShow: (String) -> Void = { _ in }
  /// The card for this anchor closed.
  public var onHide: (String) -> Void = { _ in }

  public private(set) var anchor: String?
  public private(set) var pendingId: String?
  private var cancelPending: (() -> Void)?
  private var cancelGraceTimer: (() -> Void)?
  private var warmUntil: Double = -1
  private var suppressed: String?
  public private(set) var overCard = false

  public init(schedule: @escaping (Int, @escaping @MainActor () -> Void) -> () -> Void, now: @escaping () -> Double) {
    self.schedule = schedule
    self.now = now
  }

  /// Real timers on the main queue.
  public static func live() -> HoverIntent {
    HoverIntent(schedule: { ms, f in
      let item = DispatchWorkItem { MainActor.assumeIsolated { f() } }
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms), execute: item)
      return { item.cancel() }
    }, now: { ProcessInfo.processInfo.systemUptime * 1000 })
  }

  public var graceRunning: Bool { cancelGraceTimer != nil }
  /// True while any timer is armed (tests check that nothing runs at rest).
  public var idle: Bool { cancelGraceTimer == nil && cancelPending == nil }

  /// The pointer entered `id`; `delayMs` is that node's dwell (nil: the default).
  public func enter(_ id: String, delayMs: Int? = nil) {
    if suppressed == id { return }
    suppressed = nil
    stopGrace()
    if anchor == id { stopPending(); return }
    stopPending()
    let wait = delayMs ?? self.delayMs
    // A card is up (or just closed): swap at once, or after this node's dwell with `redwell`.
    if (anchor != nil && !redwell) || (anchor == nil && now() < warmUntil) {
      activate(id)
      return
    }
    pendingId = id
    cancelPending = schedule(wait) { [weak self] in
      guard let self, self.pendingId == id else { return }
      self.pendingId = nil
      self.cancelPending = nil
      self.activate(id)
    }
  }

  public func exit(_ id: String) {
    if pendingId == id { stopPending() }
    if suppressed == id { suppressed = nil }
    if anchor != nil && !overCard && pendingId == nil { startGrace() }
  }

  public func enterCard() {
    overCard = true
    stopGrace()
    stopPending()
  }

  public func exitCard() {
    overCard = false
    if anchor != nil { startGrace() }
  }

  /// A click on a row closes its card and keeps it closed until the pointer leaves that row.
  public func press(_ id: String) {
    stopPending()
    if anchor != nil { hide(warm: false) }
    suppressed = id
  }

  /// Closes the card now (plugin cleared it, an overlay opened, the window lost focus).
  public func hide(warm: Bool = true) {
    stopGrace()
    stopPending()
    overCard = false
    guard let a = anchor else { return }
    anchor = nil
    warmUntil = warm ? now() + Double(warmMs) : -1
    onHide(a)
  }

  private func activate(_ id: String) {
    anchor = id
    onShow(id)
  }

  private func startGrace() {
    stopGrace()
    cancelGraceTimer = schedule(graceMs) { [weak self] in
      guard let self else { return }
      self.cancelGraceTimer = nil
      if !self.overCard { self.hide() }
    }
  }

  private func stopGrace() {
    cancelGraceTimer?()
    cancelGraceTimer = nil
  }

  private func stopPending() {
    cancelPending?()
    cancelPending = nil
    pendingId = nil
  }
}

/// Where a card goes. Frames are in overlay coordinates (flipped, window-sized).
public enum CardPlacement {
  /// Right of `anchor` (x = clearX + gap), vertically centered on it.
  case trailing
  /// Hanging below-right of a tile: x = maxX − gap, y = maxY − gap (spec §2.2, pinned tile).
  case tile
  /// Below `anchor`, left-aligned with it (a link, a horizontal tab); above when there's no room.
  case below

  init(_ s: String) {
    switch s {
    case "tile": self = .tile
    case "below": self = .below
    default: self = .trailing
    }
  }

  /// The card frame for an anchor frame, card size and overlay bounds. `clearX` is the x the
  /// card must start right of for `.trailing` (the sidebar edge for sidebar rows).
  public static func frame(_ p: CardPlacement, anchor a: NSRect, size s: NSSize, bounds b: NSRect, clearX: CGFloat? = nil,
                           gap: CGFloat? = nil, margin: CGFloat = Tokens.cardMargin) -> NSRect {
    var x: CGFloat, y: CGFloat
    switch p {
    case .trailing:
      x = max(a.maxX, clearX ?? a.maxX) + (gap ?? Tokens.cardGap)
      y = a.midY - s.height / 2
    case .tile:
      x = a.maxX - (gap ?? Tokens.cardGap)
      y = a.maxY - (gap ?? Tokens.cardGap)
    case .below:
      x = a.minX
      y = a.maxY + (gap ?? Tokens.cardBelowGap)
      if y + s.height > b.maxY - margin, a.minY - (gap ?? Tokens.cardBelowGap) - s.height >= b.minY + margin {
        y = a.minY - (gap ?? Tokens.cardBelowGap) - s.height
      }
    }
    x = min(max(x, b.minX + margin), max(b.minX + margin, b.maxX - margin - s.width))
    y = min(max(y, b.minY + margin), max(b.minY + margin, b.maxY - margin - s.height))
    return NSRect(x: x.rounded(), y: y.rounded(), width: s.width, height: s.height)
  }
}

/// Glue between hover-intent nodes, the intent machine, `ui.card` and `ui.action`.
@MainActor
public final class CardController {
  static let log = Logger(subsystem: "io.github.abhishakenp.den", category: "card")

  public let intent: HoverIntent
  let emit: (String, String, Value) -> Void
  let renderer: Renderer
  weak var overlays: NSView?
  /// A node's frame (by id) in overlay coordinates; the x cards next to it must clear.
  var anchorFrame: (String) -> NSRect? = { _ in nil }
  var clearX: (String) -> CGFloat? = { _ in nil }
  /// Window content coordinates (top-left origin) → overlay coordinates.
  var windowRect: (NSRect) -> NSRect = { $0 }
  public private(set) var cards: [String: PopoverCard] = [:]
  private var intentAt: Double = 0
  /// Milliseconds from hover intent to the card on screen, for the last shown card.
  public private(set) var lastShownMs: Double?
  public var onShown: ((Double) -> Void)?
  private var keyMonitor: Any?
  /// Pending closes of free (rect-anchored) cards, by card id.
  private var closing: [String: DispatchWorkItem] = [:]
  let tooltips: TooltipPresenter

  init(intent: HoverIntent = .live(), renderer: Renderer, emit: @escaping (String, String, Value) -> Void) {
    self.intent = intent
    self.renderer = renderer
    self.emit = emit
    tooltips = TooltipPresenter()
    intent.onShow = { [weak self] id in self?.wanted(id) }
    intent.onHide = { [weak self] id in self?.closed(id) }
  }

  public var visible: Bool { cards.values.contains { $0.superview != nil && !$0.leaving } }
  public var shownAnchor: String? { cards.values.first { $0.superview != nil && !$0.leaving && $0.bound }?.anchor }
  public func card(_ id: String) -> PopoverCard? { cards[id].flatMap { $0.superview != nil ? $0 : nil } }

  // MARK: Nodes with `hoverIntent`

  func entered(_ n: NodeView) {
    guard let ms = n.node["hoverIntent"].double, !n.nodeId.isEmpty else { return }
    intent.enter(n.nodeId, delayMs: Int(ms))
  }

  func exited(_ n: NodeView) {
    guard !n.node["hoverIntent"].isNull, !n.nodeId.isEmpty else { return }
    intent.exit(n.nodeId)
  }

  func pressed(_ n: NodeView) {
    guard !n.node["hoverIntent"].isNull, !n.nodeId.isEmpty else { return }
    intent.press(n.nodeId)
  }

  private func wanted(_ id: String) {
    intentAt = ProcessInfo.processInfo.systemUptime * 1000
    // The old card stays where it is until the new anchor's card arrives (usually the same
    // turn), then the content and frame swap in one frame (spec §2.4: a hard cut).
    emit(id, "hover", .null)
  }

  private func closed(_ id: String) {
    for (cid, c) in cards where c.bound && c.anchor == id && c.superview != nil && !c.leaving {
      remove(c)
      emit(cid, "close", ["anchor": .string(id)])
    }
    tooltips.hide()
    updateKeys()
  }

  // MARK: ui.card

  /// `ui.card {id, tree|null, anchor?, rect?, place?, width?, gap?, swap?, graceMs?, force?}`.
  /// `force` (with a null tree) closes at once even under the pointer: a card button was used.
  func set(_ args: Value) -> Value {
    let id = args.str("id")
    guard !id.isEmpty else { return .error("ui.card: id required") }
    let tree = args["tree"]
    if tree.isNull {
      if args.flag("force"), let c = cards[id], c.superview != nil, !c.leaving, !c.bound {
        closing.removeValue(forKey: id)?.cancel()
        remove(c)
        emit(id, "close", ["anchor": .string(c.anchor)])
        return .ok
      }
      close(id, graceMs: args["graceMs"].int.map(Int.init))
      return .ok
    }
    guard let overlays else { return .error("ui.card: no window") }
    let anchor = args.str("anchor")
    let rect = args["rect"]
    let bound = !anchor.isEmpty && rect.isNull
    // A tree for a node that isn't the hovered one is stale: drop it.
    if bound && anchor != intent.anchor { return ["shown": false] }
    closing.removeValue(forKey: id)?.cancel()
    if bound { intent.redwell = args.str("swap") == "dwell" }
    let c = cards[id] ?? PopoverCard(renderer: renderer)
    cards[id] = c
    c.cardId = id
    c.onHover = { [weak self, weak c] inside in
      guard let self, let c else { return }
      if c.bound {
        if inside { self.intent.enterCard() } else { self.intent.exitCard() }
      } else if !inside, c.closeRequested {
        self.close(c.cardId, graceMs: nil)
      } else if inside {
        self.closing.removeValue(forKey: c.cardId)?.cancel()
      }
      if !inside { self.tooltips.hide() }
    }
    let fresh = c.superview == nil || c.leaving
    c.bound = bound
    c.closeRequested = false
    c.anchor = anchor
    c.spec = args
    c.update(tree, palette: renderer.palette)
    let frame = place(c)
    if fresh {
      c.layer?.removeAllAnimations()
      if c.superview == nil { overlays.addSubview(c) }
      c.leaving = false
      c.frame = frame
      c.layoutSubtreeIfNeeded()
      c.appear()
      let ms = ProcessInfo.processInfo.systemUptime * 1000 - intentAt
      if bound {
        lastShownMs = ms
        onShown?(ms)
        Self.log.debug("card shown \(ms, format: .fixed(precision: 1)) ms after intent")
      }
    } else {
      // Hard cut: new content and frame in the same frame, no slide, no crossfade.
      c.frame = frame
      c.layoutSubtreeIfNeeded()
    }
    updateKeys()
    return ["shown": true]
  }

  /// Closes card `id`: at once for hover-bound cards (the intent machine already applied its
  /// grace), after `graceMs` for free cards, and never while the pointer is on the card.
  func close(_ id: String, graceMs: Int?) {
    guard let c = cards[id], c.superview != nil, !c.leaving else { return }
    if c.bound {
      if intent.anchor == c.anchor { intent.hide() } else { remove(c) }
      return
    }
    c.closeRequested = true
    if c.pointerInside { return }
    closing.removeValue(forKey: id)?.cancel()
    let work = DispatchWorkItem { [weak self, weak c] in
      MainActor.assumeIsolated {
        guard let self, let c, c.closeRequested, !c.pointerInside else { return }
        self.closing[id] = nil
        self.remove(c)
        self.emit(id, "close", ["anchor": .string(c.anchor)])
      }
    }
    closing[id] = work
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(max(0, graceMs ?? Tokens.cardGraceMs)), execute: work)
  }

  /// Everything off now (a modal overlay opened, the window resigned key).
  func hideAll() {
    intent.hide(warm: false)
    for (id, c) in cards where c.superview != nil && !c.leaving && !c.bound {
      closing.removeValue(forKey: id)?.cancel()
      remove(c)
      emit(id, "close", ["anchor": .string(c.anchor)])
    }
  }

  private func remove(_ c: PopoverCard) {
    tooltips.hide()
    c.disappear { [weak self] in self?.updateKeys() }
    updateKeys()
  }

  func applyPalette(_ p: Palette) {
    cards.values.forEach { $0.apply(p) }
    tooltips.apply(p)
  }

  /// Re-anchors after a window/sidebar layout pass.
  func layout() {
    for c in cards.values where c.superview != nil && !c.leaving { c.frame = place(c) }
  }

  func place(_ c: PopoverCard) -> NSRect {
    guard let overlays else { return .zero }
    let s = c.spec
    let size = c.fittedSize(width: s["width"])
    let a: NSRect
    let r = s["rect"]
    if !r.isNull {
      a = windowRect(NSRect(x: r.num("x"), y: r.num("y"), width: r.num("w"), height: r.num("h")))
    } else {
      a = anchorFrame(c.anchor) ?? NSRect(x: 0, y: 80, width: 0, height: Tokens.tabRowHeight)
    }
    let placement = CardPlacement(s.str("place", r.isNull ? "trailing" : "below"))
    return CardPlacement.frame(placement, anchor: a, size: size, bounds: overlays.bounds, clearX: r.isNull ? clearX(c.anchor) : nil,
                               gap: s["gap"].double.map { CGFloat($0) })
  }

  // MARK: Card shortcuts

  /// While a card with shortcut buttons shows, its chords act on the card (the hovered tab, the
  /// hovered link) instead of the menu bar. The monitor exists only while such a card is up.
  func updateKeys() {
    let live = cards.values.filter { $0.superview != nil && !$0.leaving }
    let wants = live.contains { !$0.shortcuts().isEmpty }
    if wants, keyMonitor == nil {
      keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
        nonisolated(unsafe) let ev = e  // local monitors run on the main thread
        let handled = MainActor.assumeIsolated { self?.key(ev) ?? false }
        return handled ? nil : e
      }
    } else if !wants, let m = keyMonitor {
      NSEvent.removeMonitor(m)
      keyMonitor = nil
    }
  }

  public var keysActive: Bool { keyMonitor != nil }

  /// Runs the card button whose shortcut matches `e`. True when handled.
  func key(_ e: NSEvent) -> Bool {
    guard let chord = ShortcutRecorder.chord(from: e) else { return false }
    return press(chord: chord)
  }

  @discardableResult
  public func press(chord: String) -> Bool {
    guard let want = Self.normalized(chord) else { return false }
    for c in cards.values where c.superview != nil && !c.leaving {
      for b in c.shortcuts() where Self.normalized(b.shortcut) == want && b.enabled {
        b.activate()
        return true
      }
    }
    return false
  }

  /// "shift+cmd+c", "cmd+shift+C" → one comparable form ("⌃⇧=" is recorded as ⌃⇧+).
  static func normalized(_ chord: String) -> String? {
    guard let c = Chord.parse(chord) else { return nil }
    var key = c.key
    if key == "+" && c.mods.contains(.shift) { key = "=" }
    return c.mods.map(\.rawValue).sorted().joined(separator: "+") + "+" + key
  }
}

// MARK: - Surface

/// The card: Dia's neutral surface (spec §2.3), a generic node tree inside.
@MainActor
public final class PopoverCard: FlippedView, Themable {
  let surface = FlippedView()
  let highlight = CALayer()
  var content: NodeView?
  unowned let renderer: Renderer
  var cardId = ""
  var anchor = ""
  /// Driven by hover intent (anchored to a node) rather than by the plugin alone.
  var bound = false
  var closeRequested = false
  var leaving = false
  var pointerInside = false
  var spec: Value = .null
  var palette = Palette(theme: Theme(), dark: false)
  var onHover: (Bool) -> Void = { _ in }

  init(renderer: Renderer) {
    self.renderer = renderer
    super.init(frame: .zero)
    wantsLayer = true
    layer?.masksToBounds = false
    layer?.shadowOffset = .zero  // spec §2.3: even on all sides
    layer?.shadowRadius = 8
    surface.wantsLayer = true
    surface.layer?.cornerRadius = Tokens.cardRadius
    surface.layer?.cornerCurve = .continuous
    surface.layer?.masksToBounds = true
    addSubview(surface)
    highlight.cornerCurve = .continuous
    highlight.borderWidth = 1
    highlight.zPosition = 10
    surface.layer?.addSublayer(highlight)
  }
  required init?(coder: NSCoder) { fatalError() }

  public override var mouseDownCanMoveWindow: Bool { false }

  func update(_ tree: Value, palette p: Palette) {
    content = renderer.reconcile([tree], existing: content.map { [$0] } ?? [], in: surface).first
    apply(p)
    needsLayout = true
  }

  /// Width from `width` (a number, or {min, max} around the content's natural width) and the
  /// content's height at that width.
  func fittedSize(width w: Value) -> NSSize {
    var width: CGFloat
    if let n = w.double {
      width = CGFloat(n)
    } else {
      let lo = CGFloat(w.num("min", Double(Tokens.cardMinWidth))), hi = CGFloat(w.num("max", Double(Tokens.cardMaxWidth)))
      width = min(max(content?.fitWidth ?? hi, lo), hi)
    }
    width = width.rounded(.up)
    let h = content?.height(for: width) ?? 0
    return NSSize(width: width, height: ceil(h))
  }

  public func apply(_ p: Palette) {
    palette = p
    let c = p.tokens.card
    surface.layer?.backgroundColor = c.fill.ns.cgColor
    surface.layer?.borderColor = c.border.ns.cgColor
    surface.layer?.borderWidth = p.dark ? 0.5 : 0.5
    if let h = c.highlight {
      highlight.isHidden = false
      highlight.borderColor = h.ns.cgColor
    } else {
      highlight.isHidden = true
    }
    // Soft and even (spec §2.3: ~8 pt blur, ~7% darkening at the edge on a near-white page).
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowOpacity = p.dark ? 0.45 : 0.16
    content?.applyPaletteRecursively(p)
  }

  public override func layout() {
    super.layout()
    surface.frame = bounds
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    highlight.frame = bounds.insetBy(dx: 0.5, dy: 0.5)
    highlight.cornerRadius = Tokens.cardRadius - 0.5
    CATransaction.commit()
    content?.frame = bounds
    layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Tokens.cardRadius, cornerHeight: Tokens.cardRadius, transform: nil)
  }

  /// Buttons with a `shortcut` in this card.
  func shortcuts() -> [ActionNode] {
    var out: [ActionNode] = []
    func walk(_ v: NSView) {
      if let a = v as? ActionNode, !a.shortcut.isEmpty, !a.isHiddenOrHasHiddenAncestor { out.append(a) }
      v.subviews.forEach(walk)
    }
    walk(surface)
    return out
  }

  // MARK: Hover

  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }
  public override func mouseEntered(with event: NSEvent) {
    pointerInside = true
    onHover(true)
  }
  public override func mouseExited(with event: NSEvent) {
    pointerInside = false
    onHover(false)
  }
  public override func mouseDown(with event: NSEvent) {}

  // MARK: Motion

  static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

  /// A transform that scales by `s` about the view's top-leading corner.
  func topLeadingScale(_ s: CGFloat) -> CATransform3D {
    guard let l = layer else { return CATransform3DIdentity }
    let flipped = l.superlayer?.contentsAreFlipped() ?? true
    let q = CGPoint(x: 0, y: flipped ? 0 : l.bounds.height)
    let a = CGPoint(x: l.anchorPoint.x * l.bounds.width, y: l.anchorPoint.y * l.bounds.height)
    let t = CATransform3DMakeTranslation((1 - s) * (q.x - a.x), (1 - s) * (q.y - a.y), 0)
    return CATransform3DConcat(CATransform3DMakeScale(s, s, 1), t)
  }

  /// Opacity 0→1 and scale 0.93→1 from the top-leading corner (spec §2.4).
  func appear() {
    alphaValue = 1
    layer?.opacity = 1
    layer?.transform = CATransform3DIdentity
    guard !Self.reduceMotion, let l = layer else { return }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0
    fade.toValue = 1
    let scale = CABasicAnimation(keyPath: "transform")
    scale.fromValue = NSValue(caTransform3D: topLeadingScale(Tokens.cardScale))
    scale.toValue = NSValue(caTransform3D: CATransform3DIdentity)
    let g = CAAnimationGroup()
    g.animations = [fade, scale]
    g.duration = Double(Tokens.cardInMs) / 1000
    g.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
    l.add(g, forKey: "cardIn")
  }

  /// Opacity 1→0 and scale →0.93 toward the top-leading corner, then out of the view tree.
  func disappear(_ done: @escaping () -> Void = {}) {
    leaving = true
    pointerInside = false
    guard !Self.reduceMotion, let l = layer else {
      removeFromSuperview()
      leaving = false
      done()
      return
    }
    CATransaction.begin()
    CATransaction.setCompletionBlock { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.leaving else { return }  // re-shown during the fade: keep it
        self.removeFromSuperview()
        self.leaving = false
        self.layer?.removeAllAnimations()
        self.layer?.opacity = 1
        self.layer?.transform = CATransform3DIdentity
        done()
      }
    }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = l.presentation()?.opacity ?? 1
    fade.toValue = 0
    let scale = CABasicAnimation(keyPath: "transform")
    scale.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
    scale.toValue = NSValue(caTransform3D: topLeadingScale(Tokens.cardScale))
    let g = CAAnimationGroup()
    g.animations = [fade, scale]
    g.duration = Double(Tokens.cardOutMs) / 1000
    g.timingFunction = CAMediaTimingFunction(name: .easeIn)
    g.fillMode = .forwards
    g.isRemovedOnCompletion = false
    l.add(g, forKey: "cardOut")
    CATransaction.commit()
  }
}

// MARK: - Tooltips

/// Dia's button tooltip (spec §2.3): a separate chip 3 pt below the button, centered on it, 28 pt
/// tall, 12 pt text, ~6 pt radius. Shown after a short rest on the button; the text carries the
/// action's shortcut ("Pin Tab  ⌘D").
@MainActor
final class TooltipPresenter {
  let chip = TooltipChip()
  private var pending: DispatchWorkItem?
  weak var owner: NSView?

  func show(_ text: String, below view: NSView, in overlays: NSView, palette: Palette) {
    pending?.cancel()
    owner = view
    let work = DispatchWorkItem { [weak self, weak view, weak overlays] in
      MainActor.assumeIsolated {
        guard let self, let view, let overlays, view.window != nil, self.owner === view else { return }
        self.chip.set(text, palette: palette)
        let r = overlays.convert(view.bounds, from: view)
        let s = self.chip.size
        var x = (r.midX - s.width / 2).rounded()
        x = min(max(x, 6), max(6, overlays.bounds.width - s.width - 6))
        var y = r.maxY + 3
        if y + s.height > overlays.bounds.height - 6 { y = r.minY - 3 - s.height }
        self.chip.frame = NSRect(x: x, y: y.rounded(), width: s.width, height: s.height)
        overlays.addSubview(self.chip)
      }
    }
    pending = work
    // Once one tooltip is up, moving to the next button shows its tooltip at once.
    let now = chip.superview != nil
    if now { work.perform() } else { DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Tokens.cardTooltipDelayMs), execute: work) }
  }

  func hide(for view: NSView? = nil) {
    if let view, owner !== view { return }
    pending?.cancel()
    pending = nil
    owner = nil
    chip.removeFromSuperview()
  }

  func apply(_ p: Palette) { chip.apply(p) }
}

@MainActor
final class TooltipChip: FlippedView, Themable {
  let label = makeLabel(size: 12)
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 6
    layer?.cornerCurve = .continuous
    addSubview(label)
  }
  required init?(coder: NSCoder) { fatalError() }
  public override func hitTest(_ point: NSPoint) -> NSView? { nil }
  func set(_ text: String, palette p: Palette) {
    label.stringValue = text
    apply(p)
    needsLayout = true
  }
  var size: NSSize { NSSize(width: ceil(label.textWidth) + 16, height: 28) }
  func apply(_ p: Palette) {
    layer?.backgroundColor = p.tokens.card.tooltip.ns.cgColor
    label.textColor = p.tokens.card.onTooltip.ns
  }
  override func layout() {
    super.layout()
    label.frame = NSRect(x: 8, y: (bounds.height - 16) / 2, width: bounds.width - 16, height: 16)
  }
}
