import AppKit
import CordisValue

/// The `status` slot: Arc's link status pill. A small pill at the bottom-left of the page that
/// shows the hovered link's address, and slides to the bottom-right when the pointer comes near it.
/// The plugin decides what it says (`ui.set {slot: "status", tree: {webview?, lead, text}}`: `lead`
/// in the primary text colour, usually the host, then `text` in the secondary colour); `null` hides it.
/// It takes no clicks. While it is hidden there's no mouse monitor and nothing else running.
@MainActor
final class StatusPillView: FlippedView, Themable {
  let label = makeLabel(size: Tokens.statusPillFontSize)
  let edge = CALayer()
  private(set) var lead = ""
  private(set) var text = ""
  /// The web view the address belongs to (the pill sits on its page); "" = the content area.
  private(set) var webview = ""
  /// On the right-hand corner (the pointer came near the left one).
  private(set) var onRight = false
  private(set) var showing = false
  private var monitor: Any?
  /// The page the pill sits on, in the superview's coordinates (set by the ui service).
  var area: () -> NSRect? = { nil }
  /// Pointer in the superview's coordinates (tests replace it).
  var pointer: () -> NSPoint? = { nil }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = Tokens.statusPillCornerRadius
    layer?.cornerCurve = .continuous
    layer?.borderWidth = 1
    layer?.shadowOpacity = 0.16
    layer?.shadowRadius = 5
    layer?.shadowOffset = CGSize(width: 0, height: -1)
    label.lineBreakMode = .byTruncatingMiddle
    addSubview(label)
    alphaValue = 0
    isHidden = true
    setAccessibilityElement(false)
  }
  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

  func update(_ tree: Value, palette p: Palette) {
    if tree.isNull { hide(); return }
    lead = tree.str("lead")
    text = tree.str("text")
    webview = tree.str("webview")
    if lead.isEmpty && text.isEmpty { hide(); return }
    apply(p)
    let appearing = !showing
    showing = true
    isHidden = false
    if appearing {
      // A fresh pill starts in the corner away from the pointer, without sliding there.
      onRight = false
      if let a = area(), let pt = pointer() { onRight = Self.onRight(pointer: pt, area: a, size: size(in: a), current: false) }
      startMonitor()
    }
    layoutPill(animated: false)
    if alphaValue < 1 {
      if reduceMotion {
        alphaValue = 1
      } else {
        NSAnimationContext.runAnimationGroup { c in
          c.duration = Tokens.statusPillFadeIn
          animator().alphaValue = 1
        }
      }
    }
  }

  func hide() {
    guard showing else { return }
    showing = false
    stopMonitor()
    if reduceMotion {
      alphaValue = 0
      isHidden = true
      return
    }
    NSAnimationContext.runAnimationGroup({ c in
      c.duration = Tokens.statusPillFadeOut
      animator().alphaValue = 0
    }, completionHandler: { [weak self] in
      MainActor.assumeIsolated { if let self, !self.showing { self.isHidden = true } }
    })
  }

  private func startMonitor() {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] e in
      MainActor.assumeIsolated { self?.pointerMoved(e) }
      return e
    }
  }

  private func stopMonitor() {
    if let m = monitor { NSEvent.removeMonitor(m) }
    monitor = nil
  }

  private func pointerMoved(_ e: NSEvent) {
    guard showing, let sv = superview, e.window === window else { return }
    let pt = sv.convert(e.locationInWindow, from: nil)
    guard let a = area() else { return }
    let right = Self.onRight(pointer: pt, area: a, size: size(in: a), current: onRight)
    if right != onRight {
      onRight = right
      layoutPill(animated: true)
    }
  }

  /// Checked by tests: re-evaluates the corner for a pointer position (superview coordinates).
  func pointerAt(_ pt: NSPoint) {
    guard showing, let a = area() else { return }
    let right = Self.onRight(pointer: pt, area: a, size: size(in: a), current: onRight)
    if right != onRight { onRight = right; layoutPill(animated: false) }
  }

  // MARK: Layout

  /// Width for the current text, capped to the page.
  func size(in a: NSRect) -> CGSize {
    let maxW = max(60, a.width - 2 * Tokens.statusPillInset)
    let w = min(maxW, ceil(label.attributedStringValue.size().width) + 2 * Tokens.statusPillPadding + 2)
    return CGSize(width: w, height: Tokens.statusPillHeight)
  }

  /// The pill's frame in a corner of `a` (flipped coordinates: bottom = maxY).
  nonisolated static func frame(area a: NSRect, size s: CGSize, right: Bool) -> NSRect {
    let x = right ? a.maxX - Tokens.statusPillInset - s.width : a.minX + Tokens.statusPillInset
    return NSRect(x: x.rounded(), y: (a.maxY - Tokens.statusPillInset - s.height).rounded(), width: s.width, height: s.height)
  }

  /// Arc: the pill gets out of the pointer's way. Near the left corner's pill -> right; back left
  /// once the pointer comes near the right one. Elsewhere it stays put (no flapping).
  nonisolated static func onRight(pointer p: NSPoint, area a: NSRect, size s: CGSize, current: Bool) -> Bool {
    let d = Tokens.statusPillAvoid
    let left = frame(area: a, size: s, right: false).insetBy(dx: -d, dy: -d)
    let right = frame(area: a, size: s, right: true).insetBy(dx: -d, dy: -d)
    if current { return !(right.contains(p) && !left.contains(p)) }
    return left.contains(p) && !right.contains(p)
  }

  func layoutPill(animated: Bool) {
    guard showing, let a = area() else { return }
    let f = Self.frame(area: a, size: size(in: a), right: onRight)
    if animated && !reduceMotion && !isHidden {
      NSAnimationContext.runAnimationGroup { c in
        c.duration = Tokens.statusPillMove
        c.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animator().frame = f
      }
    } else {
      frame = f
    }
  }

  override func layout() {
    super.layout()
    label.frame = NSRect(x: Tokens.statusPillPadding, y: (bounds.height - 15) / 2, width: max(0, bounds.width - 2 * Tokens.statusPillPadding), height: 15)
    layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Tokens.statusPillCornerRadius, cornerHeight: Tokens.statusPillCornerRadius, transform: nil)
  }

  func apply(_ p: Palette) {
    let c = p.tokens.card
    layer?.backgroundColor = c.fill.ns.cgColor
    layer?.borderColor = c.border.ns.cgColor
    layer?.shadowColor = p.shadowColor.cgColor
    let font = NSFont.systemFont(ofSize: Tokens.statusPillFontSize)
    let s = NSMutableAttributedString(string: lead, attributes: [.font: NSFont.systemFont(ofSize: Tokens.statusPillFontSize, weight: .medium), .foregroundColor: c.text.ns])
    s.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: c.secondary.ns]))
    let para = NSMutableParagraphStyle()
    para.lineBreakMode = .byTruncatingMiddle
    s.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: s.length))
    label.attributedStringValue = s
    needsLayout = true
  }

  /// The address as shown (tests).
  var shownText: String { label.stringValue }
}
