import AppKit
import CordisValue
import os

// Dia-style hover previews for sidebar items (docs/host-api.md "Hover card").
//
// - `HoverIntent` decides *when*: a short dwell before the first card, instant swaps while a card
//   is up (or just closed), a grace period on mouse-out, and nothing while a row is being clicked.
// - `HoverCardController` wires it to the sidebar rows, emits `ui.action {id, action: "hover"}` for
//   the owning plugin, and shows the `hoverCard` slot tree the preview plugin sends back.
// - `HoverCardView` renders that tree: header, status badges, list sections, an image, actions.
//
// Nothing here runs until the pointer rests on a row: no timers, no views, no events.

extension Tokens {
  // Dia's hover-card timing and geometry are not in its app resources (checked: no strings, plists
  // or asset values for them), so every value below is an estimate tuned by eye.
  public static let hoverCardDelayMs = 450  // estimate: dwell before the first card
  public static let hoverCardGraceMs = 200  // estimate: pointer can cross the gap to the card
  public static let hoverCardWarmMs = 600  // estimate: after a close, the next row shows at once
  public static let hoverCardWidth: CGFloat = 320  // estimate
  public static let hoverCardGap: CGFloat = 8  // estimate: from the sidebar's right edge
  public static let hoverCardRadius: CGFloat = 14  // estimate
  public static let hoverCardPadding: CGFloat = 14  // estimate
  public static let hoverCardImageAspect: CGFloat = 0.625  // estimate: 16:10 page snapshot
}

/// Hover intent state machine. Pure logic: time and timers are injected, so tests drive it with a
/// manual clock.
@MainActor
public final class HoverIntent {
  public var delayMs = Tokens.hoverCardDelayMs
  public var graceMs = Tokens.hoverCardGraceMs
  public var warmMs = Tokens.hoverCardWarmMs
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

  public func enter(_ id: String) {
    if suppressed == id { return }
    suppressed = nil
    stopGrace()
    if anchor == id { return }
    stopPending()
    // A card is up (or just closed): swap at once, no second dwell.
    if anchor != nil || now() < warmUntil {
      activate(id)
      return
    }
    pendingId = id
    cancelPending = schedule(delayMs) { [weak self] in
      guard let self, self.pendingId == id else { return }
      self.pendingId = nil
      self.cancelPending = nil
      self.activate(id)
    }
  }

  public func exit(_ id: String) {
    if pendingId == id { stopPending() }
    if suppressed == id { suppressed = nil }
    if anchor == id && !overCard { startGrace() }
  }

  public func enterCard() {
    overCard = true
    stopGrace()
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

  /// Closes the card now (plugin cleared the slot, an overlay opened, the window lost focus).
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

/// Glue between the sidebar rows, the intent machine, the `hoverCard` slot and `ui.action`.
@MainActor
public final class HoverCardController {
  /// Node types that get a card.
  public static let types: Set<String> = ["tabRow", "favoriteTile", "folder", "splitRow"]
  static let log = Logger(subsystem: "io.github.abhishakenp.den", category: "hoverCard")

  public let intent: HoverIntent
  let emit: (String, String, Value) -> Void
  weak var overlays: NSView?
  /// The anchor node's frame in overlay coordinates, and the x where the card starts.
  var anchorFrame: (String) -> NSRect? = { _ in nil }
  var cardLeft: () -> CGFloat = { 0 }
  var palette: () -> Palette?
  private(set) var card: HoverCardView?
  private var intentAt: Double = 0
  /// Milliseconds from hover intent to the card on screen, for the last shown card.
  public private(set) var lastShownMs: Double?
  public var onShown: ((Double) -> Void)?

  init(intent: HoverIntent = .live(), emit: @escaping (String, String, Value) -> Void, palette: @escaping () -> Palette?) {
    self.intent = intent
    self.emit = emit
    self.palette = palette
    intent.onShow = { [weak self] id in self?.wanted(id) }
    intent.onHide = { [weak self] id in self?.closed(id) }
  }

  public var visible: Bool { card?.superview != nil }
  public var shownAnchor: String? { visible ? card?.anchor : nil }

  // MARK: Rows

  func entered(_ n: NodeView) {
    guard Self.types.contains(n.node.str("type")), !n.nodeId.isEmpty, n.node["hover"].bool != false else { return }
    intent.enter(n.nodeId)
  }

  func exited(_ n: NodeView) {
    guard Self.types.contains(n.node.str("type")), !n.nodeId.isEmpty else { return }
    intent.exit(n.nodeId)
  }

  func pressed(_ n: NodeView) {
    guard Self.types.contains(n.node.str("type")), !n.nodeId.isEmpty else { return }
    intent.press(n.nodeId)
  }

  private func wanted(_ id: String) {
    intentAt = ProcessInfo.processInfo.systemUptime * 1000
    emit(id, "hover", .null)
    // The old card stays until the new anchor's content arrives (usually the same turn), but it
    // follows the pointer right away.
    if let c = card, c.superview != nil, c.anchor != id { position(c, anchor: id, animated: true) }
  }

  private func closed(_ id: String) {
    removeCard()
    emit("hoverCard", "close", ["anchor": .string(id)])
  }

  // MARK: Slot

  /// `ui.set {slot: "hoverCard", tree}`. A tree for an anchor that isn't hovered is dropped.
  func set(_ tree: Value) {
    if tree.isNull {
      intent.hide()
      removeCard()
      return
    }
    let anchor = tree.str("anchor")
    guard !anchor.isEmpty, anchor == intent.anchor, let overlays else { return }
    let c = card ?? HoverCardView(emit: { [weak self] id, action, value in self?.cardAction(id, action, value) })
    c.onHover = { [weak self] inside in inside ? self?.intent.enterCard() : self?.intent.exitCard() }
    card = c
    let fresh = c.superview == nil
    let moved = c.anchor != anchor
    c.update(tree, palette: palette() ?? c.palette)
    if fresh {
      overlays.addSubview(c)
      position(c, anchor: anchor, animated: false)
      c.appear()
      let ms = ProcessInfo.processInfo.systemUptime * 1000 - intentAt
      lastShownMs = ms
      onShown?(ms)
      Self.log.debug("hover card shown \(ms, format: .fixed(precision: 1)) ms after intent")
    } else {
      position(c, anchor: anchor, animated: moved)
    }
  }

  private func cardAction(_ id: String, _ action: String, _ value: Value) {
    emit(id, action, value)
    // Acting on the card (open, join, a button) closes it, like a menu.
    intent.hide(warm: false)
  }

  func removeCard() {
    guard let c = card, c.superview != nil else { return }
    c.disappear()
  }

  func applyPalette(_ p: Palette) { card?.apply(p) }

  /// Re-anchors after a window/sidebar layout pass.
  func layout() {
    guard let c = card, c.superview != nil else { return }
    position(c, anchor: c.anchor, animated: false)
  }

  func position(_ c: HoverCardView, anchor: String, animated: Bool) {
    guard let overlays else { return }
    let b = overlays.bounds
    let h = c.contentHeight
    let w = Tokens.hoverCardWidth
    let a = anchorFrame(anchor) ?? NSRect(x: 0, y: 80, width: 0, height: Tokens.tabRowHeight)
    let x = cardLeft() + Tokens.hoverCardGap
    // Top aligned with the row, nudged up so the header sits level with the row's title.
    let y = min(max(a.minY - 6, 10), max(10, b.height - h - 10))
    let f = NSRect(x: x.rounded(), y: y.rounded(), width: w, height: h)
    if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.14  // estimate
        ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        c.animator().frame = f
      }
    } else {
      c.frame = f
    }
  }
}

// MARK: - View

/// Renders a `hoverCard` tree:
/// `{type: "hoverCard", anchor, id?, icon?, title, subtitle?, accessory?, badges?: [{text, style, icon?}],
///   image?: path, imageVersion?, sections?: [{title?, rows: [{id, title, subtitle?, icon?, status?, accessory?, url?}]}],
///   actions?: [{id, title, icon?, style: primary|secondary}], footer?, loading?, empty?}`
@MainActor
public final class HoverCardView: FlippedView, Themable {
  let surface = FlippedView()
  let icon = IconView()
  let title = makeLabel(size: 13, weight: .semibold)
  let subtitle = makeLabel(size: 11.5)
  let accessory = makeLabel(size: 11.5, weight: .medium)
  let footer = makeLabel(size: 11)
  let empty = makeLabel(size: 12)
  let imageView = SnapshotView()
  var badges: [CardBadgeView] = []
  var sections: [SectionBlock] = []
  var buttons: [CardButton] = []
  var skeleton: [NSView] = []
  var node: Value = .null
  var palette = Palette(theme: Theme(), dark: false)
  let emit: (String, String, Value) -> Void
  var onHover: (Bool) -> Void = { _ in }
  var anchor: String { node.str("anchor") }
  var cardId: String { node.str("id", "hoverCard") }

  init(emit: @escaping (String, String, Value) -> Void) {
    self.emit = emit
    super.init(frame: .zero)
    wantsLayer = true
    layer?.shadowColor = NSColor(srgbRed: 0x15 / 255, green: 0x1C / 255, blue: 0x32 / 255, alpha: 1).cgColor  // spec §3 PopoverShadow #151C32
    layer?.shadowRadius = 18  // estimate
    layer?.shadowOffset = CGSize(width: 0, height: -6)
    surface.wantsLayer = true
    surface.layer?.cornerRadius = Tokens.hoverCardRadius
    surface.layer?.cornerCurve = .continuous
    surface.layer?.masksToBounds = true
    surface.layer?.borderWidth = 0.5
    addSubview(surface)
    title.maximumNumberOfLines = 2
    title.lineBreakMode = .byTruncatingTail
    title.cell?.wraps = true
    empty.maximumNumberOfLines = 3
    empty.cell?.wraps = true
    [icon, title, subtitle, accessory, imageView, footer, empty].forEach { surface.addSubview($0) }
  }
  required init?(coder: NSCoder) { fatalError() }

  public override var mouseDownCanMoveWindow: Bool { false }

  func update(_ v: Value, palette p: Palette) {
    let oldImage = node.str("image") + "#" + node.str("imageVersion")
    node = v
    icon.spec = v.str("icon", "sf:globe")
    icon.fallbackLetter = v.str("title")
    title.stringValue = v.str("title")
    subtitle.stringValue = v.str("subtitle")
    subtitle.isHidden = subtitle.stringValue.isEmpty
    accessory.stringValue = v.str("accessory")
    accessory.isHidden = accessory.stringValue.isEmpty
    footer.stringValue = v.str("footer")
    footer.isHidden = footer.stringValue.isEmpty
    empty.stringValue = v.str("empty")
    empty.isHidden = empty.stringValue.isEmpty

    let bs = v.list("badges")
    while badges.count > bs.count { badges.removeLast().removeFromSuperview() }
    while badges.count < bs.count { let b = CardBadgeView(); surface.addSubview(b); badges.append(b) }
    for (b, spec) in zip(badges, bs) { b.update(spec) }

    let ss = v.list("sections")
    while sections.count > ss.count { sections.removeLast().removeAll() }
    while sections.count < ss.count { sections.append(SectionBlock(in: surface, card: self)) }
    for (s, spec) in zip(sections, ss) { s.update(spec) }

    let acts = v.list("actions")
    buttons.forEach { $0.removeFromSuperview() }
    buttons = acts.map { a in
      let b = CardButton(title: a.str("title"), icon: a.str("icon"), primary: a.str("style") == "primary") { [weak self] in
        guard let self else { return }
        self.emit(self.cardId, "action", ["action": a["id"], "anchor": .string(self.anchor), "url": a["url"]])
      }
      surface.addSubview(b)
      return b
    }

    let img = v.str("image")
    imageView.isHidden = img.isEmpty && !v.flag("imagePending")
    if img + "#" + v.str("imageVersion") != oldImage { imageView.load(img) }
    imageView.pending = img.isEmpty

    let wantSkeleton = v.flag("loading") && ss.isEmpty
    if wantSkeleton && skeleton.isEmpty {
      skeleton = [0.92, 0.7, 0.5].map { _ in
        let s = NSView()
        s.wantsLayer = true
        s.layer?.cornerRadius = 4
        surface.addSubview(s)
        return s
      }
    } else if !wantSkeleton {
      skeleton.forEach { $0.removeFromSuperview() }
      skeleton = []
    }
    apply(p)
    needsLayout = true
  }

  public func apply(_ p: Palette) {
    palette = p
    let dark = p.dark
    // PopoverBackground #FAFBFF / #151C30 (spec §3), tinted by the space (theme tokens).
    surface.layer?.backgroundColor = p.surface.cgColor
    // Card elevation (Elevation.swift): PopoverShadow #151C32 α0.30 / α0.80 (spec §3), layered.
    Elevation.apply(.card, host: self, surface: surface, radius: Tokens.hoverCardRadius, palette: p)
    surface.layer?.borderColor = (dark ? p.textPrimary.withAlphaComponent(0.2) : p.hairline).cgColor  // PopoverBorder (dark); light hairline estimate
    SurfaceGrain.apply(to: surface, palette: p)
    title.textColor = p.textPrimary
    subtitle.textColor = p.textSecondary
    accessory.textColor = p.textSecondary
    footer.textColor = p.textTertiary
    empty.textColor = p.textSecondary
    icon.tint = p.textPrimary
    badges.forEach { $0.apply(dark: dark) }
    sections.forEach { $0.apply(p) }
    buttons.forEach { $0.apply(p) }
    imageView.apply(dark: dark)
    skeleton.forEach { $0.layer?.backgroundColor = p.textPrimary.withAlphaComponent(0.07).cgColor }
  }

  // MARK: Layout

  static let pad = Tokens.hoverCardPadding
  var innerWidth: CGFloat { Tokens.hoverCardWidth - 2 * Self.pad }

  /// Lays everything out top to bottom; `apply == false` only measures.
  @discardableResult
  func place(apply: Bool) -> CGFloat {
    let pad = Self.pad, w = innerWidth
    var y = pad
    // Header: 20 pt favicon, title (up to 2 lines), domain; accessory right-aligned.
    let aw = accessory.isHidden ? 0 : min(fitWidth(accessory), 90)
    let tw = w - 30 - (aw > 0 ? aw + 8 : 0)
    let titleH = min(ceil(title.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: tw, height: 100)).height ?? 17), 34)
    let headH = max(20, titleH + (subtitle.isHidden ? 0 : 16))
    if apply {
      icon.frame = NSRect(x: pad, y: y + 1, width: 20, height: 20)
      title.frame = NSRect(x: pad + 30, y: y, width: tw, height: titleH)
      subtitle.frame = NSRect(x: pad + 30, y: y + titleH + 1, width: w - 30, height: 15)
      accessory.frame = NSRect(x: pad + w - aw, y: y + 1, width: aw, height: 16)
    }
    y += headH
    if !badges.isEmpty {
      y += 10
      var x: CGFloat = 0
      for b in badges {
        let bw = min(b.width, w)
        if x > 0 && x + bw > w { x = 0; y += CardBadgeView.height + 6 }
        if apply { b.frame = NSRect(x: pad + x, y: y, width: bw, height: CardBadgeView.height) }
        x += bw + 6
      }
      y += CardBadgeView.height
    }
    if !skeleton.isEmpty {
      y += 12
      for (i, s) in skeleton.enumerated() {
        let fr: [CGFloat] = [0.92, 0.7, 0.5]
        if apply { s.frame = NSRect(x: pad, y: y, width: (w * fr[i]).rounded(), height: 9) }
        y += 17
      }
      y -= 8
    }
    for s in sections {
      y += 12
      y = s.place(x: pad, y: y, width: w, apply: apply)
    }
    if !empty.isHidden {
      y += 10
      let eh = ceil(empty.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: w, height: 60)).height ?? 16)
      if apply { empty.frame = NSRect(x: pad, y: y, width: w, height: eh) }
      y += eh
    }
    if !imageView.isHidden {
      y += 12
      let ih = (w * Tokens.hoverCardImageAspect).rounded()
      if apply { imageView.frame = NSRect(x: pad, y: y, width: w, height: ih) }
      y += ih
    }
    if !buttons.isEmpty {
      y += 12
      var x: CGFloat = 0
      let bw = buttons.count == 1 ? w : (w - CGFloat(buttons.count - 1) * 8) / CGFloat(buttons.count)
      for b in buttons {
        if apply { b.frame = NSRect(x: pad + x, y: y, width: bw.rounded(.down), height: CardButton.height) }
        x += bw + 8
      }
      y += CardButton.height
    }
    if !footer.isHidden {
      y += 10
      if apply { footer.frame = NSRect(x: pad, y: y, width: w, height: 14) }
      y += 14
    }
    return y + pad
  }

  var contentHeight: CGFloat { place(apply: false) }

  public override func layout() {
    super.layout()
    surface.frame = bounds
    place(apply: true)
    Elevation.apply(.card, host: self, surface: surface, radius: Tokens.hoverCardRadius, palette: palette)
    surface.layer?.borderColor = (palette.dark ? palette.textPrimary.withAlphaComponent(0.2) : palette.hairline).cgColor
  }

  // MARK: Hover + animation

  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }
  public override func mouseEntered(with event: NSEvent) { onHover(true) }
  public override func mouseExited(with event: NSEvent) { onHover(false) }
  public override func mouseDown(with event: NSEvent) {}

  func appear() {
    alphaValue = 1
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let l = layer else { return }
    // A quick fade and 4 pt slide from the sidebar (estimate; Dia's curve from the peek card).
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0
    fade.toValue = 1
    let slide = CABasicAnimation(keyPath: "transform.translation.x")
    slide.fromValue = -4
    slide.toValue = 0
    let g = CAAnimationGroup()
    g.animations = [fade, slide]
    g.duration = 0.16
    g.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
    l.add(g, forKey: "appear")
  }

  func disappear() {
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { removeFromSuperview(); return }
    NSAnimationContext.runAnimationGroup({ c in
      c.duration = 0.1
      self.animator().alphaValue = 0
    }, completionHandler: {
      MainActor.assumeIsolated {
        // Re-shown during the fade: keep it.
        if self.alphaValue == 0 { self.removeFromSuperview() }
      }
    })
  }
}

/// Width a label's cell needs to draw its text untruncated.
@MainActor
func fitWidth(_ l: NSTextField) -> CGFloat {
  ceil(l.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000, height: 100)).width ?? l.textWidth) + 1
}

/// Status colors for badges and row icons. den's own values (GitHub-like semantics), tuned for
/// both appearances; not measured from Dia (its resources carry no status colors).
enum CardColors {
  static func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
  }
  static func status(_ s: String, dark: Bool) -> NSColor {
    switch s {
    case "success": return dark ? rgb(0x4ADE80) : rgb(0x17924A)
    case "failure": return dark ? rgb(0xFF6B6B) : rgb(0xD92D20)
    case "pending": return dark ? rgb(0xF5C04A) : rgb(0xB7791F)
    case "merged": return dark ? rgb(0xB794F6) : rgb(0x7C3AED)
    case "accent": return dark ? rgb(0x8EA2FF) : rgb(0x3139FB)  // primary button #3139FB
    case "attention": return dark ? rgb(0xFF9F5A) : rgb(0xC2410C)
    default: return NSColor(white: dark ? 1 : 0, alpha: dark ? 0.6 : 0.55)
    }
  }
  static func tertiary(_ dark: Bool) -> NSColor { NSColor(white: dark ? 1 : 0, alpha: dark ? 0.38 : 0.4) }
}

/// Pill: `{text, style: success|failure|pending|merged|accent|attention|neutral, icon?}`.
@MainActor
final class CardBadgeView: FlippedView {
  static let height: CGFloat = 20
  let icon = IconView()
  let label = makeLabel(size: 11, weight: .semibold)
  var style = "neutral"
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = Self.height / 2
    layer?.cornerCurve = .continuous
    addSubview(icon)
    addSubview(label)
  }
  required init?(coder: NSCoder) { fatalError() }
  func update(_ v: Value) {
    style = v.str("style", "neutral")
    label.stringValue = v.str("text")
    icon.spec = v.str("icon")
    icon.isHidden = icon.spec.isEmpty
    needsLayout = true
  }
  var width: CGFloat { fitWidth(label) + (icon.isHidden ? 18 : 32) }
  func apply(dark: Bool) {
    let c = CardColors.status(style, dark: dark)
    layer?.backgroundColor = c.withAlphaComponent(dark ? 0.2 : 0.12).cgColor
    label.textColor = c
    icon.tint = c
  }
  override func layout() {
    super.layout()
    var x: CGFloat = 9
    if !icon.isHidden { icon.frame = NSRect(x: 8, y: (bounds.height - 12) / 2, width: 12, height: 12); x = 24 }
    label.frame = NSRect(x: x, y: (bounds.height - 15) / 2, width: bounds.width - x - 7, height: 15)
  }
}

/// A titled list of rows inside the card.
@MainActor
final class SectionBlock {
  let header = makeLabel(size: 11, weight: .semibold)
  var rows: [CardRow] = []
  weak var surface: NSView?
  unowned let card: HoverCardView
  init(in surface: NSView, card: HoverCardView) {
    self.surface = surface
    self.card = card
    surface.addSubview(header)
  }
  func update(_ v: Value) {
    header.stringValue = v.str("title")
    header.isHidden = header.stringValue.isEmpty
    let rs = v.list("rows")
    while rows.count > rs.count { rows.removeLast().removeFromSuperview() }
    while rows.count < rs.count {
      let r = CardRow { [weak card] row in
        guard let card else { return }
        card.emit(card.cardId, "open", ["row": row["id"], "url": row["url"], "anchor": .string(card.anchor)])
      }
      surface?.addSubview(r)
      rows.append(r)
    }
    for (r, spec) in zip(rows, rs) { r.update(spec) }
  }
  func removeAll() {
    header.removeFromSuperview()
    rows.forEach { $0.removeFromSuperview() }
  }
  func apply(_ p: Palette) {
    header.textColor = p.secondaryText
    rows.forEach { $0.apply(p) }
  }
  func place(x: CGFloat, y y0: CGFloat, width: CGFloat, apply: Bool) -> CGFloat {
    var y = y0
    if !header.isHidden {
      if apply { header.frame = NSRect(x: x, y: y, width: width, height: 14) }
      y += 18
    }
    for r in rows {
      let h = r.rowHeight
      // Rows bleed 6 pt into the padding so their hover fill lines up with the text inset.
      if apply { r.frame = NSRect(x: x - 6, y: y, width: width + 12, height: h) }
      y += h
    }
    return y
  }
}

/// `{id, title, subtitle?, icon?, status?, accessory?, url?}`. Clickable when it has a `url` or `id`.
@MainActor
final class CardRow: FlippedView, Hoverable {
  var hoverGroup: HoverGroup { .row }
  let icon = IconView()
  let title = makeLabel(size: 12.5, weight: .medium)
  let subtitle = makeLabel(size: 11)
  let accessory = makeLabel(size: 11, weight: .medium)
  var spec: Value = .null
  var dark = false
  var p: Palette?
  let onClick: (Value) -> Void
  var hovering = false { didSet { needsDisplay = true } }
  init(onClick: @escaping (Value) -> Void) {
    self.onClick = onClick
    super.init(frame: .zero)
    [icon, title, subtitle, accessory].forEach { addSubview($0) }
  }
  required init?(coder: NSCoder) { fatalError() }
  var clickable: Bool { !spec.str("url").isEmpty }
  var rowHeight: CGFloat { subtitle.isHidden ? 28 : 40 }
  func update(_ v: Value) {
    spec = v
    title.stringValue = v.str("title")
    subtitle.stringValue = v.str("subtitle")
    subtitle.isHidden = subtitle.stringValue.isEmpty
    accessory.stringValue = v.str("accessory")
    accessory.isHidden = accessory.stringValue.isEmpty
    icon.spec = v.str("icon")
    icon.isHidden = icon.spec.isEmpty
    icon.fallbackLetter = v.str("title")
    if let p { apply(p) }
    needsLayout = true
  }
  func apply(_ p: Palette) {
    self.p = p
    dark = p.dark
    title.textColor = p.panelText
    subtitle.textColor = p.secondaryText
    let status = spec.str("status")
    accessory.textColor = status.isEmpty ? p.secondaryText : CardColors.status(status, dark: p.dark)
    icon.tint = status.isEmpty ? p.secondaryText : CardColors.status(status, dark: p.dark)
    needsDisplay = true
  }
  override func layout() {
    super.layout()
    let h = bounds.height
    var x: CGFloat = 6
    if !icon.isHidden {
      icon.frame = NSRect(x: x, y: subtitle.isHidden ? (h - 14) / 2 : 6, width: 14, height: 14)
      x += 22
    }
    let aw = accessory.isHidden ? 0 : min(fitWidth(accessory), 150)
    let tw = bounds.width - x - 6 - (aw > 0 ? aw + 8 : 0)
    if subtitle.isHidden {
      title.frame = NSRect(x: x, y: (h - 16) / 2, width: tw, height: 16)
    } else {
      title.frame = NSRect(x: x, y: 4, width: tw, height: 16)
      subtitle.frame = NSRect(x: x, y: 21, width: bounds.width - x - 6, height: 14)
    }
    accessory.frame = NSRect(x: bounds.width - 6 - aw, y: subtitle.isHidden ? (h - 15) / 2 : 5, width: aw, height: 15)
  }
  override func draw(_ dirtyRect: NSRect) {
    guard hovering && clickable else { return }
    NSColor(white: dark ? 1 : 0, alpha: dark ? 0.08 : 0.05).setFill()  // command bar RowHoverBackground-like
    NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }
  override func mouseEntered(with event: NSEvent) { HoverTracker.refresh(window) }
  override func mouseExited(with event: NSEvent) { HoverTracker.refresh(window) }
  override func mouseDown(with event: NSEvent) {}
  override func mouseUp(with event: NSEvent) {
    if clickable, bounds.contains(convert(event.locationInWindow, from: nil)) { onClick(spec) }
  }
}

/// Rounded button along the card's bottom edge.
@MainActor
final class CardButton: FlippedView, Hoverable {
  var hoverGroup: HoverGroup { .control }
  static let height: CGFloat = 30
  let icon = IconView()
  let label = makeLabel(size: 12.5, weight: .semibold)
  let primary: Bool
  let action: () -> Void
  var fill = NSColor.clear, hoverFill = NSColor.clear
  var hovering = false { didSet { needsDisplay = true } }
  init(title: String, icon spec: String, primary: Bool, action: @escaping () -> Void) {
    self.primary = primary
    self.action = action
    super.init(frame: .zero)
    label.stringValue = title
    label.alignment = .center
    icon.spec = spec
    icon.isHidden = spec.isEmpty
    addSubview(icon)
    addSubview(label)
  }
  required init?(coder: NSCoder) { fatalError() }
  func apply(_ p: Palette) {
    if primary {
      fill = p.primaryButton  // the theme accent (tokens)
      hoverFill = p.primaryButton.blended(withFraction: 0.12, of: .black) ?? p.primaryButton
      label.textColor = p.onAccent
      icon.tint = p.onAccent
    } else {
      fill = NSColor(white: p.dark ? 1 : 0, alpha: p.dark ? 0.1 : 0.06)
      hoverFill = NSColor(white: p.dark ? 1 : 0, alpha: p.dark ? 0.15 : 0.1)
      label.textColor = p.panelText
      icon.tint = p.panelText
    }
    needsDisplay = true
  }
  override func layout() {
    super.layout()
    let lw = min(fitWidth(label), bounds.width - 16)
    let total = lw + (icon.isHidden ? 0 : 20)
    var x = ((bounds.width - total) / 2).rounded()
    if !icon.isHidden {
      icon.frame = NSRect(x: x, y: (bounds.height - 14) / 2, width: 14, height: 14)
      x += 20
    }
    label.frame = NSRect(x: x, y: (bounds.height - 16) / 2, width: lw, height: 16)
  }
  override func draw(_ dirtyRect: NSRect) {
    (hovering ? hoverFill : fill).setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }
  override func mouseEntered(with event: NSEvent) { HoverTracker.refresh(window) }
  override func mouseExited(with event: NSEvent) { HoverTracker.refresh(window) }
  override func mouseDown(with event: NSEvent) {}
  override func mouseUp(with event: NSEvent) {
    if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
  }
}

/// Page snapshot: a local PNG/JPEG path (or http(s) URL), aspect-filled from the top, with a flat
/// placeholder while it loads.
@MainActor
final class SnapshotView: FlippedView {
  var image: NSImage? { didSet { needsDisplay = true } }
  var pending = false { didSet { needsDisplay = true } }
  var dark = false
  private var source = ""
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = true
    layer?.borderWidth = 0.5
  }
  required init?(coder: NSCoder) { fatalError() }
  func load(_ src: String) {
    source = src
    guard !src.isEmpty else { image = nil; return }
    if src.hasPrefix("http") {
      ImageCache.shared.load(src) { [weak self] img in if self?.source == src { self?.image = img } }
    } else {
      let path = src.hasPrefix("file://") ? String(src.dropFirst(7)) : src
      // Decoding a small snapshot is cheap, but keep it off the hover path.
      DispatchQueue.global(qos: .userInitiated).async {
        let data = FileManager.default.contents(atPath: path)
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            guard self.source == src else { return }
            self.image = data.flatMap { NSImage(data: $0) }
          }
        }
      }
    }
  }
  func apply(dark: Bool) {
    self.dark = dark
    layer?.borderColor = NSColor(white: dark ? 1 : 0, alpha: 0.1).cgColor
    needsDisplay = true
  }
  override func draw(_ dirtyRect: NSRect) {
    NSColor(white: dark ? 1 : 0, alpha: 0.05).setFill()
    bounds.fill()
    guard let img = image, img.size.width > 0 else { return }
    // Aspect fill, anchored to the page top.
    let scale = max(bounds.width / img.size.width, bounds.height / img.size.height)
    let w = img.size.width * scale, h = img.size.height * scale
    NSGraphicsContext.current?.imageInterpolation = .high
    img.draw(in: NSRect(x: (bounds.width - w) / 2, y: 0, width: w, height: h), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
  }
}
