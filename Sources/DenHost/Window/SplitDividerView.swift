import AppKit

/// The gap between two split panes, as a drag handle: drag to resize the panes beside it,
/// double-click to make them equal again. A small grip fades in while the pointer is over it.
final class SplitDividerView: NSView {
  /// The divider moves left and right (panes side by side); false: up and down.
  var alongX = true { didSet { if alongX != oldValue { window?.invalidateCursorRects(for: self); needsLayout = true } } }
  /// Called with the pointer in the superview's coordinates while dragging.
  var onDrag: ((CGPoint) -> Void)?
  var onDragEnd: (() -> Void)?
  var onDoubleClick: (() -> Void)?
  private let grip = CALayer()
  private var hovering = false
  private(set) var dragging = false

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    grip.opacity = 0
    grip.cornerCurve = .continuous
    layer?.addSublayer(grip)
    setAccessibilityRole(.splitter)
    setAccessibilityLabel("Resize Split View")
  }
  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    let t = Tokens.splitHandleThickness, l = min(Tokens.splitHandleLength, alongX ? bounds.height : bounds.width)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    grip.frame = alongX ? CGRect(x: (bounds.width - t) / 2, y: (bounds.height - l) / 2, width: t, height: l)
                        : CGRect(x: (bounds.width - l) / 2, y: (bounds.height - t) / 2, width: l, height: t)
    grip.cornerRadius = t / 2
    CATransaction.commit()
    updateGrip(animated: false)
  }

  override func viewDidChangeEffectiveAppearance() { updateGrip(animated: false) }

  override func resetCursorRects() { addCursorRect(bounds, cursor: alongX ? .resizeLeftRight : .resizeUpDown) }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
  }
  override func mouseEntered(with event: NSEvent) { setHovering(true) }
  override func mouseExited(with event: NSEvent) { setHovering(false) }
  /// Shows or hides the grip as for a pointer over the gap (also scenarios).
  func setHovering(_ on: Bool, animated: Bool = true) {
    hovering = on
    updateGrip(animated: animated)
  }

  /// The grip: hidden at rest, a quiet capsule on hover, brighter while dragging.
  func updateGrip(animated: Bool) {
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let alpha: CGFloat = dragging ? 0.55 : 0.32  // estimate
    CATransaction.begin()
    CATransaction.setAnimationDuration(animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.12 : 0)
    CATransaction.setDisableActions(!animated)
    grip.backgroundColor = NSColor(white: dark ? 1 : 0, alpha: alpha).cgColor
    grip.opacity = hovering || dragging ? 1 : 0
    CATransaction.commit()
  }

  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 { onDoubleClick?(); return }
    guard let window else { return }
    dragging = true
    updateGrip(animated: true)
    track(next: { window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: $0, inMode: .eventTracking, dequeue: true) },
          buttonDown: { NSEvent.pressedMouseButtons & 1 != 0 })
  }

  /// The drag loop, bounded like the sidebar's resize handle: it polls with a deadline and ends
  /// when the left button is no longer down (a synthesized click never hangs it).
  func track(next: (Date) -> NSEvent?, buttonDown: () -> Bool) {
    defer {
      dragging = false
      updateGrip(animated: true)
      onDragEnd?()
    }
    while true {
      guard let e = next(Date(timeIntervalSinceNow: 0.25)) else {
        if !buttonDown() { return }
        continue
      }
      if e.type == .leftMouseUp { return }
      guard let sv = superview else { return }
      onDrag?(sv.convert(e.locationInWindow, from: nil))
    }
  }
}
