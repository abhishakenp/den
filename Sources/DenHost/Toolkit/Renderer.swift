import AppKit
import CordisValue

/// Base class of every rendered node. Nodes are plain flipped NSViews that lay themselves out
/// manually (no Auto Layout, no SwiftUI) and are reused across `ui.set` calls by key.
@MainActor
public class NodeView: FlippedView, Themable {
  public internal(set) var node: Value = .null
  unowned(unsafe) var r: Renderer!
  var palette: Palette { r.palette }
  var nodeId: String { node.str("id") }

  required init(renderer: Renderer) {
    self.r = renderer
    super.init(frame: .zero)
  }
  required init?(coder: NSCoder) { fatalError() }

  /// Called with each new node value; views update in place.
  func update(_ v: Value) { node = v }
  func height(for width: CGFloat) -> CGFloat { 0 }
  /// The height of every node of this type, known without a view (lets `StackNode` virtualize).
  class func fixedHeight(_ v: Value) -> CGFloat? { nil }
  /// In use (hovered, focused, being edited): a virtualized list keeps its view.
  var busy: Bool { false }
  /// Width when placed in a `row`; nil = flexible.
  var preferredWidth: CGFloat? { nil }
  /// Natural (untruncated) width, for content-fitted containers such as cards; nil = no opinion.
  var fitWidth: CGFloat? { nil }
  public func apply(_ p: Palette) { needsDisplay = true }

  func emit(_ action: String, _ value: Value = .null) { r.emit(nodeId, action, value) }

  public override var mouseDownCanMoveWindow: Bool { false }

  /// Nodes lay out manually from their bounds, so a new size always means a new layout pass.
  public override func setFrameSize(_ newSize: NSSize) {
    let changed = newSize != frame.size
    super.setFrameSize(newSize)
    if changed { needsLayout = true }
  }

  /// Optional native context menu (see `ContextMenu` for the item shapes): separators, section
  /// headers, submenus, SF Symbol icons, destructive items and key-equivalent hints.
  public override func menu(for event: NSEvent) -> NSMenu? {
    let items = node.list("menu")
    guard !items.isEmpty else { return nil }
    return ContextMenu.build(items, target: self, action: #selector(menuPicked(_:)))
  }
  @objc func menuPicked(_ sender: NSMenuItem) { emit("menu", .string(sender.representedObject as? String ?? "")) }
}

/// Builds and reconciles node views from `Value` trees and routes user actions to `ui.action`.
@MainActor
public final class Renderer {
  public var palette: Palette
  /// (node id, action, value) -> emitted as `ui.action` {id, action, value}.
  let emitFn: (String, String, Value) -> Void
  var drag: DragController?
  /// Cards and hover intent (set by `UIService`): nodes with `hoverIntent` report to it.
  var hover: CardController?
  static var registry: [String: NodeView.Type] = [
    "list": StackNode.self, "row": RowNode.self, "spacer": SpacerNode.self, "text": TextNode.self,
    "button": ButtonNode.self, "navBar": NavBarNode.self, "urlPill": URLPillNode.self,
    "grid": GridNode.self, "favoriteTile": FavoriteTileNode.self, "spaceTitle": SpaceTitleNode.self,
    "tabRow": TabRowNode.self, "folder": FolderNode.self, "divider": DividerNode.self,
    "newTabRow": NewTabRowNode.self, "spaceIcon": SpaceIconNode.self, "splitRow": SplitRowNode.self,
    "themePicker": ThemePickerNode.self, "iconPicker": IconPickerNode.self,
    "heading": HeadingNode.self, "paragraph": ParagraphNode.self, "section": SectionNode.self,
    "todoRow": TodoRowNode.self, "feedRow": FeedRowNode.self, "actionButton": ActionButtonNode.self,
    "buttonRow": ButtonRowNode.self, "connectionRow": ConnectionRowNode.self, "toggleRow": ToggleRowNode.self,
    "choiceRow": ChoiceRowNode.self, "extensionRow": ExtensionRowNode.self,
    // Generic composition nodes (CardNodes.swift): cards, popovers, any plugin surface.
    "stack": CardStackNode.self, "label": LabelNode.self, "icon": IconNode.self, "image": ImageNode.self,
    "badge": BadgeNode.self, "meter": MeterNode.self, "note": NoteNode.self, "item": ItemNode.self, "action": ActionNode.self,
    "panel": PopoverCardNode.self, "valueRow": ValueRowNode.self,
  ]

  public init(palette: Palette, emit: @escaping (String, String, Value) -> Void) {
    self.palette = palette
    self.emitFn = emit
  }

  func emit(_ id: String, _ action: String, _ value: Value) { emitFn(id, action, value) }

  func make(_ v: Value) -> NodeView {
    let type = Self.registry[v.str("type")] ?? TextNode.self
    let n = type.init(renderer: self)
    n.update(v)
    n.apply(palette)
    return n
  }

  static func fixedHeight(_ v: Value) -> CGFloat? { registry[v.str("type")]?.fixedHeight(v) }

  static func key(_ v: Value, _ index: Int) -> String {
    let id = v.str("id")
    return v.str("type") + ":" + (id.isEmpty ? "#\(index)" : id)
  }

  /// Reuses existing views with matching keys (type + id), creates new ones, drops the rest.
  func reconcile(_ children: [Value], existing: [NodeView], in parent: NSView) -> [NodeView] {
    var pool: [String: NodeView] = [:]
    for (i, v) in existing.enumerated() { pool[Self.key(v.node, i)] = v }
    var out: [NodeView] = []
    for (i, c) in children.enumerated() {
      let k = Self.key(c, i)
      if let v = pool.removeValue(forKey: k) {
        if v.node != c { v.update(c) }
        out.append(v)
      } else {
        let v = make(c)
        parent.addSubview(v)
        out.append(v)
      }
    }
    pool.values.forEach { $0.removeFromSuperview() }
    return out
  }
}

// MARK: - Containers

/// Vertical stack. {type:"list", children, spacing?, padding?}
///
/// Virtualized for rows of a known height (tab and split rows, `NodeView.fixedHeight`): inside a
/// scroll view, such a child gets a view only while it is within `Self.margin` of the visible
/// area, and gives it up again beyond `Self.dropMargin`. A sidebar of hundreds of tabs holds views
/// (and their layers, labels and tracking areas) for the few dozen rows near the screen only.
final class StackNode: NodeView {
  /// One per child; nil while a virtual child is off screen.
  var slots: [NodeView?] = []
  var specs: [Value] = []
  var kids: [NodeView] { slots.compactMap { $0 } }
  static let margin: CGFloat = 200
  static let dropMargin: CGFloat = 1000
  private var scrollObserver: NSObjectProtocol?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let o = scrollObserver { NotificationCenter.default.removeObserver(o); scrollObserver = nil }
    guard window != nil, let clip = enclosingScrollView?.contentView else { return }
    clip.postsBoundsChangedNotifications = true
    scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { [weak self] _ in
      MainActor.assumeIsolated { self?.materialize() }
    }
  }

  override func update(_ v: Value) {
    super.update(v)
    let children = v.list("children")
    var pool: [String: NodeView] = [:]
    for (i, s) in slots.enumerated() { if let s { pool[Renderer.key(specs[i], i)] = s } }
    specs = children
    slots = children.enumerated().map { i, c in
      if let s = pool.removeValue(forKey: Renderer.key(c, i)) {
        if s.node != c { s.update(c) }
        return s
      }
      if Renderer.fixedHeight(c) != nil { return nil }  // made by `materialize` when near the screen
      let s = r.make(c)
      addSubview(s)
      return s
    }
    pool.values.forEach { $0.removeFromSuperview() }
    materialize()
    needsLayout = true
  }
  var spacing: CGFloat { CGFloat(node.num("spacing", Double(Tokens.tabRowSpacing))) }
  var padding: CGFloat { CGFloat(node.num("padding", 0)) }
  func childHeight(_ i: Int, _ w: CGFloat) -> CGFloat { slots[i]?.height(for: w) ?? Renderer.fixedHeight(specs[i]) ?? 0 }
  override func height(for w: CGFloat) -> CGFloat {
    let hs = specs.indices.map { childHeight($0, w) }.filter { $0 > 0 }
    return hs.reduce(0, +) + spacing * CGFloat(max(0, hs.count - 1)) + padding * 2
  }
  /// Each child's frame, views or not.
  func frames() -> [NSRect] {
    var y = padding, out: [NSRect] = []
    for i in specs.indices {
      let h = childHeight(i, bounds.width)
      out.append(NSRect(x: 0, y: y, width: bounds.width, height: h))
      if h > 0 { y += h + spacing }
    }
    return out
  }
  override func layout() {
    super.layout()
    let fs = frames()
    for (i, s) in slots.enumerated() {
      guard let s else { continue }
      s.frame = fs[i]
      s.isHidden = fs[i].height == 0
    }
    materialize(fs)
  }
  /// Makes the views of virtual rows near the visible area and drops those far from it. Called on
  /// layout and when the enclosing scroll view scrolls (`SidebarPage`). A row that is hovered,
  /// being renamed or dragged keeps its view.
  func materialize(_ given: [NSRect]? = nil) {
    guard specs.contains(where: { Renderer.fixedHeight($0) != nil }) else { return }
    let fs = given ?? frames()
    // Outside a scroll view (or before one exists) every row is near the screen.
    let vis = enclosingScrollView == nil ? bounds : visibleRect
    // Not on screen (another space's page, no window or size yet): the first rows only, so the
    // page shows at once when it slides in; nothing is dropped.
    let hidden = vis.width < 1 || vis.height < 1
    let near = vis.insetBy(dx: 0, dy: -Self.margin), keep = vis.insetBy(dx: 0, dy: -Self.dropMargin)
    for i in specs.indices where Renderer.fixedHeight(specs[i]) != nil {
      if let s = slots[i] {
        guard !hidden, !fs[i].intersects(keep), !s.busy else { continue }
        s.removeFromSuperview()
        slots[i] = nil
      } else if fs[i].height > 0, hidden ? i < 40 : fs[i].intersects(near) {
        let s = r.make(specs[i])
        s.frame = fs[i]
        addSubview(s)
        slots[i] = s
      }
    }
  }
}

/// Horizontal stack. {type:"row", children, spacing?, height?}
final class RowNode: NodeView {
  var kids: [NodeView] = []
  override func update(_ v: Value) {
    super.update(v)
    kids = r.reconcile(v.list("children"), existing: kids, in: self)
    needsLayout = true
  }
  override func height(for w: CGFloat) -> CGFloat { CGFloat(node.num("height", 32)) }
  override func layout() {
    super.layout()
    if let r = SpaceIconReorder.active, r.icon.superview === self { return }  // mid-drag: keep the live slots
    let sp = CGFloat(node.num("spacing", 4))
    let fixed = kids.compactMap(\.preferredWidth).reduce(0, +) + sp * CGFloat(max(0, kids.count - 1))
    let flex = kids.filter { $0.preferredWidth == nil }.count
    let fw = flex > 0 ? max(0, (bounds.width - fixed) / CGFloat(flex)) : 0
    var x: CGFloat = 0
    for k in kids {
      let w = k.preferredWidth ?? fw
      let h = min(bounds.height, max(k.height(for: w), 1))
      k.frame = NSRect(x: x, y: (bounds.height - h) / 2, width: w, height: h)
      x += w + sp
    }
  }
}

final class SpacerNode: NodeView {
  override func height(for w: CGFloat) -> CGFloat { CGFloat(node.num("height", 0)) }
  override var preferredWidth: CGFloat? { node["width"].double.map { CGFloat($0) } }
}

/// {type:"text", text, style: title|body|caption|secondary}
final class TextNode: NodeView {
  let label = makeLabel()
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    addSubview(label)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func update(_ v: Value) {
    super.update(v)
    label.stringValue = v.str("text")
    switch v.str("style", "body") {
    case "title": label.font = .systemFont(ofSize: 15, weight: .semibold)
    case "caption", "secondary": label.font = .systemFont(ofSize: 11, weight: .medium)
    default: label.font = .systemFont(ofSize: 13)
    }
    apply(r.palette)
  }
  override func apply(_ p: Palette) { label.textColor = ["caption", "secondary"].contains(node.str("style")) ? p.secondaryText : p.text }
  override func height(for w: CGFloat) -> CGFloat { ceil(label.intrinsicContentSize.height) + 4 }
  override var preferredWidth: CGFloat? { ceil(label.textWidth) + 6 }  // the label is inset 2 pt each side, and its cell pads the text 2 pt more
  override func layout() { label.frame = bounds.insetBy(dx: 2, dy: 2) }
}

/// {type:"button", id, icon, title?, size?, tooltip?, progress? (0–1 ring; negative: waiting), dot?}
/// -> ui.action {id, action: "click"}. `progress` draws a ring around the icon in the accent (the
/// sidebar's download indicator), `dot` a small accent dot at its top right (something new).
final class ButtonNode: NodeView {
  lazy var button = IconButton(symbol: "sf:circle", size: 28) { [weak self] in self?.emit(self?.node.str("action", "click") ?? "click") }
  let label = makeLabel(size: 12, weight: .medium)
  let ring = RingView()
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    addSubview(button)
    addSubview(label)
    ring.isHidden = true
    addSubview(ring)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func update(_ v: Value) {
    super.update(v)
    button.icon.spec = v.str("icon", "sf:circle")
    button.enabled = v.flag("enabled", true)
    button.toolTip = v.str("tooltip")
    label.stringValue = v.str("title")
    label.isHidden = label.stringValue.isEmpty
    ring.progress = v["progress"].double
    ring.dot = v.flag("dot")
    ring.isHidden = ring.progress == nil && !ring.dot
    needsLayout = true
  }
  var size: CGFloat { CGFloat(node.num("size", 28)) }
  override func apply(_ p: Palette) {
    button.apply(p)
    label.textColor = p.text
    ring.accent = p.accentStrong
    ring.track = p.text.withAlphaComponent(0.18)
  }
  override func height(for w: CGFloat) -> CGFloat { size }
  override var preferredWidth: CGFloat? { size + (label.isHidden ? 0 : ceil(label.textWidth) + 6) }
  override func layout() {
    button.frame = NSRect(x: 0, y: (bounds.height - size) / 2, width: size, height: size)
    ring.frame = button.frame
    label.frame = NSRect(x: size + 2, y: (bounds.height - 16) / 2, width: max(0, bounds.width - size - 2), height: 16)
  }
}

/// A progress ring and/or a "new" dot drawn over a button (it takes no clicks).
final class RingView: FlippedView {
  var progress: Double? { didSet { if progress != oldValue { needsDisplay = true } } }
  var dot = false { didSet { if dot != oldValue { needsDisplay = true } } }
  var accent: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
  var track: NSColor = NSColor(white: 0.5, alpha: 0.2) { didSet { needsDisplay = true } }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func draw(_ dirtyRect: NSRect) {
    let b = bounds
    if let p = progress {
      let r = min(b.width, b.height) / 2 - 2.5, c = NSPoint(x: b.midX, y: b.midY)
      let t = NSBezierPath()
      t.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
      t.lineWidth = 2
      track.setStroke()
      t.stroke()
      // Unknown size: a short arc, so it still reads as "working".
      let f = p < 0 ? 0.12 : min(max(p, 0.02), 1)
      let a = NSBezierPath()
      // Flipped view: clockwise on screen from 12 o'clock.
      a.appendArc(withCenter: c, radius: r, startAngle: -90, endAngle: -90 + 360 * f, clockwise: false)
      a.lineWidth = 2
      a.lineCapStyle = .round
      accent.setStroke()
      a.stroke()
    }
    if dot {
      accent.setFill()
      NSBezierPath(ovalIn: NSRect(x: b.maxX - 9, y: b.minY + 3, width: 6, height: 6)).fill()
    }
  }
}
