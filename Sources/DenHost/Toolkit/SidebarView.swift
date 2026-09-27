import AppKit
import CordisValue

/// Holds one rendered tree for a slot, reconciled in place across updates.
@MainActor
final class SlotView: FlippedView {
  var root: NodeView?
  func set(_ tree: Value, renderer: Renderer) {
    if tree.isNull {
      root?.removeFromSuperview()
      root = nil
      return
    }
    root = renderer.reconcile([tree], existing: root.map { [$0] } ?? [], in: self).first
    needsLayout = true
  }
  func height(for w: CGFloat) -> CGFloat { root?.height(for: w) ?? 0 }
  override func layout() {
    super.layout()
    root?.frame = bounds
  }
}

/// One space's scrollable column: spaceHeader, pinned, today.
@MainActor
final class SidebarPage: NSScrollView {
  let doc = FlippedView()
  let spaceHeader = SlotView(), pinned = SlotView(), today = SlotView()
  weak var pager: SidebarPager?

  override init(frame: NSRect) {
    super.init(frame: frame)
    drawsBackground = false
    hasVerticalScroller = true
    scrollerStyle = .overlay
    autohidesScrollers = true
    horizontalScrollElasticity = .none
    verticalScrollElasticity = .allowed
    contentView.drawsBackground = false
    documentView = doc
    [spaceHeader, pinned, today].forEach { doc.addSubview($0) }
  }
  required init?(coder: NSCoder) { fatalError() }

  func slot(_ name: String) -> SlotView? {
    switch name {
    case "sidebar.spaceHeader": return spaceHeader
    case "sidebar.pinned": return pinned
    case "sidebar.today": return today
    default: return nil
    }
  }

  override func scrollWheel(with event: NSEvent) {
    if pager?.handleScroll(event) == true { return }
    super.scrollWheel(with: event)
  }

  override func tile() {
    super.tile()
    relayoutDoc()
  }

  func relayoutDoc() {
    let w = contentView.bounds.width
    var y: CGFloat = 0
    for s in [spaceHeader, pinned, today] {
      let h = s.height(for: w)
      s.frame = NSRect(x: 0, y: y, width: w, height: h)
      s.needsLayout = true
      if h > 0 { y += h + (s === spaceHeader ? 2 : Tokens.sidebarSectionSpacing) }
    }
    doc.frame = NSRect(x: 0, y: 0, width: w, height: max(y + 12, contentView.bounds.height))
  }
}

/// Horizontal pager of space pages that follows two-finger trackpad swipes.
@MainActor
final class SidebarPager: FlippedView {
  var pages: [SidebarPage] = []
  private(set) var current = 0
  private var offset: CGFloat = 0
  private var tracking: Bool?  // nil = undecided, true = horizontal swipe, false = vertical scroll
  private var animating = false
  private var animTimer: Timer?
  /// (from page, to page, progress 0...1) while swiping; used to blend the window theme.
  var onProgress: ((Int, Int, CGFloat) -> Void)?
  var onCommit: ((Int) -> Void)?

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = true
  }
  required init?(coder: NSCoder) { fatalError() }

  func ensurePages(_ n: Int) {
    while pages.count < n {
      let p = SidebarPage()
      p.pager = self
      pages.append(p)
      addSubview(p)
    }
    while pages.count > max(n, 1) { pages.removeLast().removeFromSuperview() }
    current = min(current, pages.count - 1)
    needsLayout = true
  }

  func show(_ i: Int, animated: Bool) {
    let target = min(max(i, 0), pages.count - 1)
    let from = current
    guard animated, target != from, window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
      current = target
      offset = 0
      layoutPages()
      onProgress?(target, target, 0)
      return
    }
    // Start from the equivalent offset so the slide continues smoothly.
    offset += CGFloat(target - from) * bounds.width
    current = target
    animateOffset(to: 0, from: from)
  }

  private func animateOffset(to end: CGFloat, from origin: Int) {
    animating = true
    let start = offset, w = max(bounds.width, 1)
    let startTime = CACurrentMediaTime(), dur = Tokens.spaceSwitchDuration
    let target = current
    animTimer?.invalidate()
    animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        let x = min(1, (CACurrentMediaTime() - startTime) / dur)
        let e = 1 - pow(1 - x, 3)  // ease-out cubic
        self.offset = start + (end - start) * CGFloat(e)
        self.layoutPages()
        // Blend from the page we came from toward the target.
        let remaining = abs(self.offset) / w
        self.onProgress?(origin == target ? target : origin, target, origin == target ? 0 : 1 - min(1, remaining))
        if x >= 1 {
          self.animTimer?.invalidate()
          self.animTimer = nil
          self.animating = false
          self.onProgress?(target, target, 0)
        }
      }
    }
  }

  /// Returns true if the event was consumed as a horizontal space swipe.
  func handleScroll(_ e: NSEvent) -> Bool {
    guard pages.count > 1, e.hasPreciseScrollingDeltas else { return false }
    if e.momentumPhase != [] { return tracking == true }
    switch e.phase {
    case .began, .mayBegin:
      tracking = nil
      return false
    case .changed:
      if tracking == nil {
        if abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) * 1.2, abs(e.scrollingDeltaX) > 1 { tracking = !animating } else if abs(e.scrollingDeltaY) > 1 { tracking = false }
      }
      guard tracking == true else { return false }
      let w = max(bounds.width, 1)
      offset += e.scrollingDeltaX
      // Rubber-band at the ends.
      if (current == 0 && offset > 0) || (current == pages.count - 1 && offset < 0) { offset -= e.scrollingDeltaX * 0.7 }
      offset = min(max(offset, -w), w)
      layoutPages()
      let neighbor = offset < 0 ? current + 1 : current - 1
      if neighbor >= 0 && neighbor < pages.count { onProgress?(current, neighbor, abs(offset) / w) }
      return true
    case .ended, .cancelled:
      defer { tracking = nil }
      guard tracking == true else { return false }
      let w = max(bounds.width, 1)
      let from = current
      var target = current
      if abs(offset) > w * Tokens.swipeCommitFraction { target = offset < 0 ? current + 1 : current - 1 }
      target = min(max(target, 0), pages.count - 1)
      offset += CGFloat(target - current) * w
      current = target
      if target != from {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        onCommit?(target)
      }
      animateOffset(to: 0, from: from)
      return true
    default:
      return tracking == true
    }
  }

  override func scrollWheel(with event: NSEvent) {
    if !handleScroll(event) { super.scrollWheel(with: event) }
  }

  override func layout() {
    super.layout()
    layoutPages()
  }

  func layoutPages() {
    let w = bounds.width
    for (i, p) in pages.enumerated() {
      let x = CGFloat(i - current) * w + offset
      let visible = x > -w && x < w
      p.isHidden = !visible
      let f = NSRect(x: x.rounded(), y: 0, width: w, height: bounds.height)
      if p.frame != f { p.frame = f }
    }
  }
}

/// The whole sidebar: fixed header + favorites, the swipeable space pager, and the footer.
@MainActor
public final class SidebarView: FlippedView {
  let header = SlotView(), favorites = SlotView(), footer = SlotView()
  let pager = SidebarPager()

  override init(frame: NSRect) {
    super.init(frame: frame)
    [header, favorites, pager, footer].forEach { addSubview($0) }
  }
  required init?(coder: NSCoder) { fatalError() }

  public override var mouseDownCanMoveWindow: Bool { true }

  func slot(_ name: String, page: Int) -> SlotView? {
    switch name {
    case "sidebar.header": return header
    case "sidebar.favorites": return favorites
    case "sidebar.footer": return footer
    default:
      pager.ensurePages(max(pager.pages.count, page + 1))
      return pager.pages[page].slot(name)
    }
  }

  public override func layout() {
    super.layout()
    let pad = Tokens.sidebarPadding
    let w = bounds.width - pad * 2
    var y: CGFloat = 0
    let hh = header.height(for: w)
    header.frame = NSRect(x: pad, y: y, width: w, height: hh)
    y += hh + (hh > 0 ? Tokens.sidebarSectionSpacing : 0)
    let fh = favorites.height(for: w)
    favorites.frame = NSRect(x: pad, y: y, width: w, height: fh)
    y += fh + (fh > 0 ? Tokens.sidebarSectionSpacing : 0)
    let footH = footer.root == nil ? 0 : Tokens.footerHeight
    footer.frame = NSRect(x: pad, y: bounds.height - footH, width: w, height: footH)
    pager.frame = NSRect(x: pad, y: y, width: w, height: max(0, bounds.height - footH - y))
    for s in [header, favorites, footer] { s.needsLayout = true }
    pager.pages.forEach { $0.relayoutDoc() }
  }

  public override func scrollWheel(with event: NSEvent) {
    if !pager.handleScroll(event) { super.scrollWheel(with: event) }
  }

  public override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 { onDoubleClickEmpty?(); return }
    window?.performDrag(with: event)
  }
  var onDoubleClickEmpty: (() -> Void)?

  /// Delivers a scroll event as if it hit the visible space page (snapshots / tests).
  public func deliverScrollForTesting(_ e: NSEvent) {
    if let page = pager.pages.first(where: { !$0.isHidden }) { page.scrollWheel(with: e) } else { scrollWheel(with: e) }
  }
}

/// Drag-to-reorder for tab rows, folders and favorite tiles, with haptics and a theme-tinted
/// insertion indicator. Emits ui.action {id: source, action: "reorder", value: {source, target, position}},
/// {action: "dropOnContent", value: {source, side}} when dropped on the web content, or
/// {action: "dropOnSpace", value: {source, target, spaceId}} when a row is dropped on a footer space icon.
@MainActor
final class DragController {
  weak var root: NSView?  // sidebar view
  var contentFrame: () -> NSRect = { .zero }  // in root's window coordinates
  var accent: () -> NSColor = { .controlAccentColor }
  /// Where the content drop indicator is drawn (the window's overlay layer).
  var overlay: () -> NSView? = { nil }
  /// Theme-tinted zone shown while a tab is dragged over the web content (left / center / right).
  let dropZone = NSView()
  private(set) var dropSide: String?
  let emit: (String, String, Value) -> Void
  private var source: HoverNode?
  private var ghost: NSImageView?
  private let indicator = NSView()
  private var target: (String, String)?
  private(set) weak var spaceTarget: SpaceIconNode?
  private var grabOffset = NSPoint.zero

  init(emit: @escaping (String, String, Value) -> Void) {
    self.emit = emit
    indicator.wantsLayer = true
    indicator.layer?.cornerRadius = 1
    dropZone.wantsLayer = true
    dropZone.layer?.cornerRadius = Tokens.cardCornerRadius
    dropZone.layer?.cornerCurve = .continuous
    dropZone.layer?.borderWidth = Tokens.dropZoneBorderWidth
  }

  static func side(at pWin: NSPoint, in cf: NSRect) -> String {
    let rx = (pWin.x - cf.minX) / cf.width
    return rx < 0.33 ? "left" : (rx > 0.66 ? "right" : "center")
  }

  /// Shows (or hides, with nil) the content drop zone for a window point.
  func updateDropZone(_ pWin: NSPoint?) {
    guard let pWin, let ov = overlay() else {
      dropZone.removeFromSuperview()
      dropSide = nil
      return
    }
    let cf = contentFrame()
    let side = Self.side(at: pWin, in: cf)
    let area = ov.convert(cf, from: nil)
    let g = Tokens.splitGap / 2
    let f: NSRect
    switch side {
    case "left": f = NSRect(x: area.minX, y: area.minY, width: area.width / 2 - g, height: area.height)
    case "right": f = NSRect(x: area.midX + g, y: area.minY, width: area.width / 2 - g, height: area.height)
    default: f = area
    }
    let c = accent()
    dropZone.layer?.backgroundColor = c.withAlphaComponent(Tokens.dropZoneFillAlpha).cgColor
    dropZone.layer?.borderColor = c.withAlphaComponent(0.9).cgColor
    if dropZone.superview !== ov { ov.addSubview(dropZone) }
    if dropSide != side {
      if dropSide != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
      dropSide = side
    }
    dropZone.frame = f.integral
  }

  func begin(_ v: HoverNode, event: NSEvent) {
    guard let root else { return }
    source = v
    let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)
    if let rep { v.cacheDisplay(in: v.bounds, to: rep) }
    let img = NSImage(size: v.bounds.size)
    if let rep { img.addRepresentation(rep) }
    let g = NSImageView(frame: root.convert(v.bounds, from: v))
    g.image = img
    g.alphaValue = 0.85
    g.wantsLayer = true
    g.layer?.shadowOpacity = 0.2
    g.layer?.shadowRadius = 6
    root.addSubview(g)
    ghost = g
    let p = root.convert(event.locationInWindow, from: nil)
    grabOffset = NSPoint(x: p.x - g.frame.minX, y: p.y - g.frame.minY)
    v.alphaValue = 0.35
    indicator.layer?.backgroundColor = accent().cgColor
    root.addSubview(indicator)
    indicator.isHidden = true
  }

  func candidates(in v: NSView) -> [HoverNode] {
    var out: [HoverNode] = []
    for s in v.subviews where !s.isHidden {
      if let h = s as? HoverNode, h.draggable, h !== source { out.append(h) }
      if let sc = s as? NSScrollView { out += candidates(in: sc.documentView ?? sc) } else { out += candidates(in: s) }
    }
    return out
  }

  func spaceIcons(in v: NSView) -> [SpaceIconNode] {
    v.subviews.flatMap { s -> [SpaceIconNode] in
      guard !s.isHidden else { return [] }
      return (s as? SpaceIconNode).map { [$0] } ?? spaceIcons(in: s)
    }
  }

  /// Highlights the footer space icon under the dragged row (Arc: drop a tab on a space to move it).
  func setSpaceTarget(_ t: SpaceIconNode?) {
    guard t !== spaceTarget else { return }
    spaceTarget?.dropTarget = false
    spaceTarget = t
    t?.dropTarget = true
    if t != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
  }

  func move(_ event: NSEvent) {
    guard let root, let ghost, let source else { return }
    let p = root.convert(event.locationInWindow, from: nil)
    ghost.setFrameOrigin(NSPoint(x: source is FavoriteTileNode ? p.x - grabOffset.x : ghost.frame.minX, y: p.y - grabOffset.y))
    var newTarget: (String, String)?
    let isTile = source is FavoriteTileNode
    let icon = isTile ? nil : spaceIcons(in: root).first { !$0.node.str("spaceId").isEmpty && root.convert($0.bounds, from: $0).insetBy(dx: -2, dy: -4).contains(p) }
    setSpaceTarget(icon)
    if icon != nil {
      indicator.isHidden = true
      updateDropZone(nil)
    } else if p.x > root.bounds.maxX + 6 {
      indicator.isHidden = true
      updateDropZone(contentFrame().contains(event.locationInWindow) ? event.locationInWindow : nil)
    } else if let hit = candidates(in: root).first(where: { root.convert($0.bounds, from: $0).contains(p) && ($0 is FavoriteTileNode) == isTile }) {
      let f = root.convert(hit.bounds, from: hit)
      let pos: String
      if isTile {
        pos = p.x < f.midX ? "before" : "after"
        indicator.frame = NSRect(x: (pos == "before" ? f.minX - 4 : f.maxX + 2), y: f.minY + 4, width: 2, height: f.height - 8)
      } else {
        let rel = (p.y - f.minY) / f.height
        // Folders take rows "into" them; so do splits (a tab joins the split), but not other splits.
        let into = hit is FolderNode.Header || (hit is SplitRowNode && source is TabRowNode)
        pos = into && rel > 0.3 && rel < 0.7 ? "into" : (rel < 0.5 ? "before" : "after")
        indicator.frame = pos == "into" ? f.insetBy(dx: 0, dy: f.height / 2 - 1) : NSRect(x: f.minX + 6, y: (pos == "before" ? f.minY - 2 : f.maxY) , width: f.width - 12, height: 2)
      }
      newTarget = (hit.nodeId, pos)
      indicator.isHidden = false
    }
    if p.x <= root.bounds.maxX + 6 && icon == nil { updateDropZone(nil) }
    if newTarget?.0 != target?.0 || newTarget?.1 != target?.1 {
      target = newTarget
      if newTarget != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    }
  }

  func end(_ event: NSEvent) {
    guard let root, let source else { return }
    let pWin = event.locationInWindow
    let cf = contentFrame()
    let p = root.convert(pWin, from: nil)
    if let icon = spaceTarget {
      emit(source.nodeId, "dropOnSpace", ["source": .string(source.nodeId), "target": .string(icon.nodeId), "spaceId": .string(icon.node.str("spaceId"))])
      NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    } else if p.x > root.bounds.maxX + 6, cf.contains(pWin) {
      let side = Self.side(at: pWin, in: cf)
      emit(source.nodeId, "dropOnContent", ["source": .string(source.nodeId), "side": .string(side)])
    } else if let (t, pos) = target {
      emit(source.nodeId, "reorder", ["source": .string(source.nodeId), "target": .string(t), "position": .string(pos)])
      NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }
    setSpaceTarget(nil)
    source.alphaValue = 1
    ghost?.removeFromSuperview()
    indicator.removeFromSuperview()
    updateDropZone(nil)
    ghost = nil
    self.source = nil
    target = nil
  }
}
