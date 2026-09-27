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
  /// Width when placed in a `row`; nil = flexible.
  var preferredWidth: CGFloat? { nil }
  public func apply(_ p: Palette) { needsDisplay = true }

  func emit(_ action: String, _ value: Value = .null) { r.emit(nodeId, action, value) }

  public override var mouseDownCanMoveWindow: Bool { false }

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
  static var registry: [String: NodeView.Type] = [
    "list": StackNode.self, "row": RowNode.self, "spacer": SpacerNode.self, "text": TextNode.self,
    "button": ButtonNode.self, "navBar": NavBarNode.self, "urlPill": URLPillNode.self,
    "grid": GridNode.self, "favoriteTile": FavoriteTileNode.self, "spaceTitle": SpaceTitleNode.self,
    "tabRow": TabRowNode.self, "folder": FolderNode.self, "divider": DividerNode.self,
    "newTabRow": NewTabRowNode.self, "spaceIcon": SpaceIconNode.self, "splitRow": SplitRowNode.self,
    "themePicker": ThemePickerNode.self,
    "heading": HeadingNode.self, "paragraph": ParagraphNode.self, "section": SectionNode.self,
    "todoRow": TodoRowNode.self, "feedRow": FeedRowNode.self, "actionButton": ActionButtonNode.self,
    "buttonRow": ButtonRowNode.self, "connectionRow": ConnectionRowNode.self, "toggleRow": ToggleRowNode.self,
    "choiceRow": ChoiceRowNode.self,
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
final class StackNode: NodeView {
  var kids: [NodeView] = []
  override func update(_ v: Value) {
    super.update(v)
    kids = r.reconcile(v.list("children"), existing: kids, in: self)
    needsLayout = true
  }
  var spacing: CGFloat { CGFloat(node.num("spacing", Double(Tokens.tabRowSpacing))) }
  var padding: CGFloat { CGFloat(node.num("padding", 0)) }
  override func height(for w: CGFloat) -> CGFloat {
    let hs = kids.map { $0.height(for: w) }.filter { $0 > 0 }
    return hs.reduce(0, +) + spacing * CGFloat(max(0, hs.count - 1)) + padding * 2
  }
  override func layout() {
    super.layout()
    var y = padding
    for k in kids {
      let h = k.height(for: bounds.width)
      k.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
      k.isHidden = h == 0
      if h > 0 { y += h + spacing }
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
  override var preferredWidth: CGFloat? { ceil(label.textWidth) + 4 }
  override func layout() { label.frame = bounds.insetBy(dx: 2, dy: 2) }
}

/// {type:"button", id, icon, title?, size?} -> ui.action {id, action: "click"}
final class ButtonNode: NodeView {
  lazy var button = IconButton(symbol: "sf:circle", size: 28) { [weak self] in self?.emit(self?.node.str("action", "click") ?? "click") }
  let label = makeLabel(size: 12, weight: .medium)
  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    addSubview(button)
    addSubview(label)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func update(_ v: Value) {
    super.update(v)
    button.icon.spec = v.str("icon", "sf:circle")
    button.enabled = v.flag("enabled", true)
    button.toolTip = v.str("tooltip")
    label.stringValue = v.str("title")
    label.isHidden = label.stringValue.isEmpty
    needsLayout = true
  }
  var size: CGFloat { CGFloat(node.num("size", 28)) }
  override func apply(_ p: Palette) { button.apply(p); label.textColor = p.text }
  override func height(for w: CGFloat) -> CGFloat { size }
  override var preferredWidth: CGFloat? { size + (label.isHidden ? 0 : ceil(label.textWidth) + 6) }
  override func layout() {
    button.frame = NSRect(x: 0, y: (bounds.height - size) / 2, width: size, height: size)
    label.frame = NSRect(x: size + 2, y: (bounds.height - 16) / 2, width: max(0, bounds.width - size - 2), height: 16)
  }
}
