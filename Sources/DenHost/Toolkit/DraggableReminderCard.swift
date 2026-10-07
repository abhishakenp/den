import AppKit
import CordisValue
import os

/// Draggable reminder card overlay: a floating panel that can be dragged anywhere on screen,
/// snaps to the nearest corner on release, and displays TODO items.
///
/// Usage: `ui.setReminder {items: [{id, text, done}], visible: true, position?: {x, y}, dismiss?}`
/// Events: `ui.action {id: "reminder", action: "dismiss"}`,
///         `ui.action {id: "reminder", action: "toggle", value: {id}}`,
///         `ui.action {id: "reminder", action: "add", value: {text}}`,
///         `ui.action {id: "reminder", action: "remove", value: {id}}`

@MainActor
final class DraggableReminderCard: FlippedView, Themable {
  unowned let renderer: Renderer
  let emit: (String, String, Value) -> Void

  // MARK: - Layout

  private let dragHandle = ReminderDragHandle()
  private let headerView = FlippedView()
  private let titleLabel = NSTextField(wrappingLabelWithString: "")
  private let itemCountLabel = NSTextField(wrappingLabelWithString: "")
  private var closeBtn = IconButton(symbol: "xmark", size: Tokens.reminderCloseButtonSize, action: {})
  private let scrollView = NSScrollView()
  private let docView = FlippedView()
  private var todoItems: [TodoRowView] = []

  var visible = false { didSet { needsDisplay = true } }
  private var currentItems: [ReminderItem] = []
  var onDismiss: (() -> Void)?

  // MARK: - Drag state

  private var lastDragLocation: NSPoint?
  private var hasDragged = false
  private let dragThreshold: CGFloat = Tokens.reminderDragThreshold

  private var windowBounds: NSRect {
    window?.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
  }

  // MARK: - Init

  init(renderer: Renderer, emit: @escaping (String, String, Value) -> Void) {
    self.renderer = renderer
    self.emit = emit
    super.init(frame: .zero)
    setup()
  }

  required init?(coder: NSCoder) { fatalError() }

  private func setup() {
    wantsLayer = true
    layer?.cornerRadius = Tokens.reminderCornerRadius
    layer?.cornerCurve = .continuous
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowOpacity = Tokens.reminderShadowOpacity
    layer?.shadowRadius = Tokens.reminderShadowRadius
    layer?.shadowOffset = .zero

    [dragHandle, headerView, scrollView].forEach { addSubview($0) }
    [titleLabel, itemCountLabel, closeBtn].forEach { headerView.addSubview($0) }
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.scrollerStyle = .overlay
    scrollView.autohidesScrollers = true
    scrollView.documentView = docView
  }

  // MARK: - Data

  struct ReminderItem {
    let id: String
    var text: String
    var done: Bool
  }

  func update(_ args: Value, palette p: Palette) {
    // Parse items
    currentItems = args.list("items").map { item in
      ReminderItem(
        id: item.str("id"),
        text: item.str("text"),
        done: item.flag("done", false)
      )
    }

    // Parse position if provided
    let pos = args["position"]
    if !pos.isNull, visible {
      frame.origin = NSPoint(x: pos.num("x"), y: pos.num("y"))
    }

    // Build todo rows
    buildTodoRows()

    // Update title/item count
    let active = currentItems.filter { !$0.done }.count
    let total = currentItems.count
    titleLabel.stringValue = "Reminders"
    itemCountLabel.stringValue = total > 0 ? "\(active) of \(total)" : ""
    itemCountLabel.isHidden = total == 0
    needsLayout = true
    apply(p)
  }

  private func buildTodoRows() {
    todoItems.forEach { $0.removeFromSuperview() }
    todoItems.removeAll()

    let cw = bounds.width - 32
    var y: CGFloat = 0
    for item in currentItems {
      let row = TodoRowView(item: item, emit: emit)
      row.frame = NSRect(x: 16, y: y, width: cw, height: 32)
      row.onDone = { [weak self] itemId in
        self?.emit("reminder", "toggle", ["id": .string(itemId)])
      }
      row.onRemove = { [weak self] itemId in
        self?.emit("reminder", "remove", ["id": .string(itemId)])
      }
      docView.addSubview(row)
      todoItems.append(row)
      y += 32 + 4
    }

    docView.frame = NSRect(x: 0, y: 0, width: cw, height: y + 8)
  }

  // MARK: - Theming

  func apply(_ p: Palette) {
    layer?.backgroundColor = p.surface.cgColor
    dragHandle.apply(p)
    titleLabel.textColor = p.textPrimary
    itemCountLabel.textColor = p.textSecondary
    closeBtn.apply(p)
    todoItems.forEach { $0.apply(p) }
    needsLayout = true
  }

  // MARK: - Layout

  override func layout() {
    super.layout()
    // Drag handle: top bar
    let handleH = Tokens.reminderDragHandleHeight
    dragHandle.frame = NSRect(x: 0, y: bounds.height - handleH, width: bounds.width, height: handleH)

    // Header: below drag handle
    let headerY = dragHandle.frame.minY
    let headerH: CGFloat = 40
    headerView.frame = NSRect(x: 0, y: headerY - headerH, width: bounds.width, height: headerH)

    let titleW: CGFloat = 90
    titleLabel.frame = NSRect(x: 12, y: headerY - headerH + (headerH - 18) / 2, width: titleW, height: 18)

    if !itemCountLabel.isHidden {
      let countW = ceil(itemCountLabel.attributedStringValue.size().width) + 8
      itemCountLabel.frame = NSRect(x: 12 + titleW + 6, y: headerY - headerH + (headerH - 14) / 2, width: countW, height: 14)
    }

    closeBtn.frame = NSRect(x: bounds.width - 12 - Tokens.reminderCloseButtonSize,
                               y: headerY - headerH + (headerH - Tokens.reminderCloseButtonSize) / 2,
                               width: Tokens.reminderCloseButtonSize,
                               height: Tokens.reminderCloseButtonSize)

    // ScrollView: rest of the card
    let scrollY = headerView.frame.minY
    let scrollH = max(40, bounds.height - headerView.frame.minY)
    scrollView.frame = NSRect(x: 0, y: scrollY - scrollH, width: bounds.width, height: scrollH)
  }

  // MARK: - Drag

  override func mouseDown(with event: NSEvent) {
    let loc = convert(event.locationInWindow, from: nil)
    // Check if we hit the drag handle
    if dragHandle.frame.contains(loc) {
      lastDragLocation = loc
      hasDragged = false
    } else if !visible {
      // Tap to show if hidden
      show()
    }
  }

  override func mouseDragged(with event: NSEvent) {
    guard let last = lastDragLocation else { return }
    let current = convert(event.locationInWindow, from: nil)
    let delta = NSPoint(x: current.x - last.x, y: current.y - last.y)

    if !hasDragged, hypot(delta.x, delta.y) < dragThreshold { return }
    hasDragged = true

    let newOrigin = NSPoint(x: frame.origin.x + delta.x, y: frame.origin.y + delta.y)
    frame.origin = newOrigin
    lastDragLocation = current
  }

  override func mouseUp(with event: NSEvent) {
    defer {
      lastDragLocation = nil
      hasDragged = false
    }

    guard hasDragged else { return }
    hasDragged = false

    // Snap to nearest corner
    snapToNearestCorner()
  }

  private func snapToNearestCorner() {
    let screenFrame = NSScreen.main?.visibleFrame ?? windowBounds
    let inset = Tokens.reminderCornerInset
    let cardW = frame.width
    let cardH = frame.height

    // Find nearest corner coordinates
    let corners: [(x: CGFloat, y: CGFloat, label: String)] = [
      (screenFrame.maxX - cardW - inset, screenFrame.maxY - cardH - inset, "top-right"),
      (screenFrame.minX + inset, screenFrame.maxY - cardH - inset, "top-left"),
      (screenFrame.maxX - cardW - inset, screenFrame.minY + inset, "bottom-right"),
      (screenFrame.minX + inset, screenFrame.minY + inset, "bottom-left"),
    ]

    let currentCenter = NSPoint(x: frame.midX, y: frame.midY)
    var nearestCorner = corners[0]
    var nearestDist = hypot(currentCenter.x - (corners[0].x + cardW / 2), currentCenter.y - (corners[0].y + cardH / 2))

    for corner in corners[1...] {
      let dist = hypot(currentCenter.x - (corner.x + cardW / 2), currentCenter.y - (corner.y + cardH / 2))
      if dist < nearestDist {
        nearestCorner = corner
        nearestDist = dist
      }
    }

    // Animate snap
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    if !reduceMotion, let layer = layer, window?.isVisible == true {
      let targetFrame = NSRect(x: nearestCorner.x, y: nearestCorner.y, width: cardW, height: cardH)
      CATransaction.begin()
      CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
      CATransaction.setAnimationDuration(Tokens.reminderSnapDuration)
      layer.removeAllAnimations()
      layer.opacity = 0.85
      layer.transform = CATransform3DMakeScale(0.95, 0.95, 1)
      CATransaction.commit()

      // Animate to final state
      NSAnimationContext.runAnimationGroup { context in
        context.duration = Tokens.reminderSnapDuration
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animator().alphaValue = 1
        animator().frame = targetFrame
      }
    } else {
      frame.origin = NSPoint(x: nearestCorner.x, y: nearestCorner.y)
    }
  }

  // MARK: - Show / Hide

  func show() {
    visible = true
    alphaValue = 0
    if superview != nil {
      // Ensure position is valid within screen
      let screenFrame = NSScreen.main?.visibleFrame ?? windowBounds
      var origin = frame.origin
      origin.x = max(screenFrame.minX, min(origin.x, screenFrame.maxX - frame.width))
      origin.y = max(screenFrame.minY, min(origin.y, screenFrame.maxY - frame.height))
      frame.origin = origin
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.2
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      animator().alphaValue = 1
    }
  }

  func hide() {
    visible = false
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.15
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      animator().alphaValue = 0
    }
  }

  // MARK: - Hit testing

  override func hitTest(_ point: NSPoint) -> NSView? {
    return visible ? super.hitTest(point) : nil
  }
}

// MARK: - Drag Handle

@MainActor
final class ReminderDragHandle: FlippedView {
  var hoverFill: NSColor = NSColor(white: 0, alpha: 0.04)
  var hovering = false { didSet { needsDisplay = true } }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
  }

  required init?(coder: NSCoder) { fatalError() }

  func apply(_ p: Palette) {
    layer?.backgroundColor = p.pillFill.cgColor
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    guard hovering else { return }
    hoverFill.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 0, yRadius: 0).fill()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }
  override func mouseEntered(with event: NSEvent) { hovering = true }
  override func mouseExited(with event: NSEvent) { hovering = false }
  override var mouseDownCanMoveWindow: Bool { false }
}

// MARK: - TODO Row

@MainActor
final class TodoRowView: FlippedView, Themable {
  let checkmark = ReminderCheckmark()
  let titleLabel = NSTextField(wrappingLabelWithString: "")
  let removeButton = ReminderRemoveButton()

  var item: DraggableReminderCard.ReminderItem
  var onDone: ((String) -> Void)?
  var onRemove: ((String) -> Void)?

  init(item: DraggableReminderCard.ReminderItem, emit: @escaping (String, String, Value) -> Void) {
    self.item = item
    super.init(frame: .zero)
    wantsLayer = true
    [checkmark, titleLabel, removeButton].forEach { addSubview($0) }
    titleLabel.stringValue = item.text
    titleLabel.font = .systemFont(ofSize: 13)
    titleLabel.textColor = item.done ? .secondaryLabelColor : .labelColor
    titleLabel.alphaValue = item.done ? 0.5 : 1
    titleLabel.isEditable = false
    titleLabel.isSelectable = false

    checkmark.checked = item.done
    checkmark.onTap = { [weak self] in self?.toggle() }
    removeButton.onTap = { [weak self] in self?.remove() }
  }

  required init?(coder: NSCoder) { fatalError() }

  func toggle() {
    item.done.toggle()
    checkmark.checked = item.done
    titleLabel.alphaValue = item.done ? 0.5 : 1
    titleLabel.textColor = item.done ? .secondaryLabelColor : .labelColor
    onDone?(item.id)
  }

  func remove() {
    onRemove?(item.id)
  }

  func apply(_ p: Palette) {
    checkmark.apply(p)
    needsDisplay = true
  }

  override func layout() {
    super.layout()
    let h = bounds.height
    checkmark.frame = NSRect(x: 0, y: (h - 16) / 2, width: 16, height: 16)
    titleLabel.frame = NSRect(x: 24, y: (h - 17) / 2, width: max(0, bounds.width - 56), height: 17)
    removeButton.frame = NSRect(x: bounds.width - 20, y: (h - 16) / 2, width: 16, height: 16)
  }
}

// MARK: - Checkmark

@MainActor
final class ReminderCheckmark: FlippedView {
  var checked = false { didSet { needsDisplay = true } }
  var onTap: (() -> Void)?

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
  }
  required init?(coder: NSCoder) { fatalError() }

  override func mouseDown(with event: NSEvent) { onTap?() }
  override var mouseDownCanMoveWindow: Bool { false }

  func apply(_ p: Palette) { needsDisplay = true }

  override func draw(_ dirtyRect: NSRect) {
    let b = bounds
    if checked {
      // Filled circle
      let r: CGFloat = 8
      NSBezierPath(ovalIn: NSRect(x: (b.width - r * 2) / 2, y: (b.height - r * 2) / 2, width: r * 2, height: r * 2)).fill()
      // Checkmark
      let path = NSBezierPath()
      path.move(to: NSPoint(x: b.width * 0.25, y: b.height * 0.52))
      path.line(to: NSPoint(x: b.width * 0.42, y: b.height * 0.7))
      path.line(to: NSPoint(x: b.width * 0.75, y: b.height * 0.3))
      path.lineCapStyle = .round
      path.lineJoinStyle = .round
      path.lineWidth = 1.5
      NSColor.white.setStroke()
      path.stroke()
    } else {
      // Empty circle
      let r: CGFloat = 7.5
      let path = NSBezierPath(ovalIn: NSRect(x: (b.width - r * 2) / 2 + 0.5, y: (b.height - r * 2) / 2 + 0.5, width: r * 2 - 1, height: r * 2 - 1))
      path.lineWidth = 1
      NSColor.secondaryLabelColor.setStroke()
      path.stroke()
    }
  }
}

// MARK: - Remove Button

@MainActor
final class ReminderRemoveButton: FlippedView {
  var onTap: (() -> Void)?
  var hovering = false { didSet { needsDisplay = true } }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
  }
  required init?(coder: NSCoder) { fatalError() }

  override func mouseDown(with event: NSEvent) { onTap?() }
  override var mouseDownCanMoveWindow: Bool { false }

  func apply(_ p: Palette) { needsDisplay = true }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }
  override func mouseEntered(with event: NSEvent) { hovering = true }
  override func mouseExited(with event: NSEvent) { hovering = false }

  override func draw(_ dirtyRect: NSRect) {
    let b = bounds
    let c = hovering ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.clear
    c.setFill()
    NSBezierPath(roundedRect: b.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()

    // X symbol
    let s: CGFloat = 4
    NSColor.tertiaryLabelColor.setStroke()
    let path1 = NSBezierPath()
    path1.move(to: NSPoint(x: b.width / 2 - s, y: b.height / 2 - s))
    path1.line(to: NSPoint(x: b.width / 2 + s, y: b.height / 2 + s))
    path1.lineWidth = 1.2
    let path2 = NSBezierPath()
    path2.move(to: NSPoint(x: b.width / 2 + s, y: b.height / 2 - s))
    path2.line(to: NSPoint(x: b.width / 2 - s, y: b.height / 2 + s))
    path2.lineWidth = 1.2
    path1.stroke()
    path2.stroke()
  }
}