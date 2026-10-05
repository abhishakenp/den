import AppKit
import CordisValue

/// Archive / Library sheet, shown in the `overlay.library` slot over the content area.
///
/// {type:"library", id, title? ("Archive"), icon? ("sf:archivebox"), query?, placeholder?,
///  clearTitle? ("Clear Archive"), empty? (empty-state text),
///  sections?: [{id, title, icon?, keycap?}], section? (the shown one's id),
///  items: [{id, title, url?, subtitle?, icon?, closedAt? (ms since 1970), section? (header, instead
///           of the day), progress? (0–1 bar; negative: waiting), buttons?: [{id, icon, title}],
///           pill? ("Restore"; "" none), file? (a path: drag the row out as that file), dimmed?}]}
/// A `subtitle` may hold `{time}`: the item's `closedAt` as "3:41 PM".
/// Items are grouped by `closedAt` day (Today, Yesterday, weekday, then month + day) unless they
/// name their own `section`, and filtered locally as you type, so search is instant; the typed
/// text is also emitted. With `sections`, the header shows them as tabs with their shortcuts.
/// actions (id = library id): input {text}, restore {item} (a click on the row or its pill),
/// button {item, button}, section {id}, clear, dismiss (Esc, close button, backdrop)
/// Arc's archive view was not measured (spec §12): every value here is an estimate in Tokens.
@MainActor
final class LibraryView: PanelView, NSTextFieldDelegate {
  final class Row: FlippedView, Hoverable, NSDraggingSource {
    var hoverGroup: HoverGroup { .row }
    let icon = IconView()
    let title = makeLabel(size: 13.5, weight: .medium)
    let subtitle = makeLabel(size: 12)
    lazy var restore = PillButton(title: "Restore", style: "secondary") { [weak self] in self?.onRestore?() }
    let bar = FlippedView()
    let barFill = FlippedView()
    var buttons: [IconButton] = []
    var itemId = ""
    var progress: Double?
    var file = ""
    var hasPill = true
    var hovering = false { didSet { restore.isHidden = !hovering || !hasPill; buttons.forEach { $0.isHidden = !hovering }; needsDisplay = true } }
    var hoverFill: NSColor = .clear
    var onRestore: (() -> Void)?
    var onButton: ((String) -> Void)?

    override init(frame: NSRect) {
      super.init(frame: frame)
      [icon, title, subtitle, restore].forEach { addSubview($0) }
      restore.isHidden = true
      bar.wantsLayer = true
      bar.layer?.cornerRadius = 1.5
      barFill.wantsLayer = true
      barFill.layer?.cornerRadius = 1.5
      bar.addSubview(barFill)
      bar.isHidden = true
      addSubview(bar)
    }
    required init?(coder: NSCoder) { fatalError() }

    var buttonSpecs: [Value] = []
    func setButtons(_ specs: [Value]) {
      guard specs != buttonSpecs else { return }
      buttonSpecs = specs
      buttons.forEach { $0.removeFromSuperview() }
      buttons = specs.map { b in
        let id = b.str("id")
        let btn = IconButton(symbol: b.str("icon", "sf:circle"), size: 28) { [weak self] in self?.onButton?(id) }
        btn.round = true
        btn.toolTip = b.str("title")
        btn.isHidden = !hovering
        addSubview(btn)
        return btn
      }
    }

    override func draw(_ dirtyRect: NSRect) {
      guard hovering else { return }
      hoverFill.setFill()
      NSBezierPath(roundedRect: bounds, xRadius: Tokens.libraryRowRadius, yRadius: Tokens.libraryRowRadius).fill()
    }
    override func layout() {
      let h = bounds.height, s = Tokens.tabRowIconSize
      icon.frame = NSRect(x: 12, y: (h - s) / 2, width: s, height: s)
      var right = bounds.width - 8
      for b in buttons.reversed() {
        right -= 28
        b.frame = NSRect(x: right, y: (h - 28) / 2, width: 28, height: 28)
        right -= 2
      }
      if hasPill {
        let rw = restore.preferredWidth
        restore.frame = NSRect(x: right - rw, y: (h - 28) / 2, width: rw, height: 28)
        if !restore.isHidden { right = restore.frame.minX }
      }
      if !hovering || buttons.isEmpty && restore.isHidden { right = max(right, bounds.width - 12) }
      right -= 8
      title.frame = NSRect(x: 42, y: h / 2 - 17, width: max(0, right - 42), height: 17)
      subtitle.frame = NSRect(x: 42, y: h / 2 + 1, width: max(0, right - 42), height: 15)
      bar.isHidden = progress == nil
      if let p = progress {
        bar.frame = NSRect(x: 42, y: h - 5, width: max(0, right - 42), height: 3)
        let f = p < 0 ? 0.08 : min(max(p, 0), 1)
        barFill.frame = NSRect(x: 0, y: 0, width: (bar.bounds.width * f).rounded(), height: 3)
      }
    }
    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      trackingAreas.forEach(removeTrackingArea)
      addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { HoverTracker.refresh(window); needsLayout = true }
    override func mouseExited(with event: NSEvent) { HoverTracker.refresh(window); needsLayout = true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// A row with a `file` drags out as that file (Finder, Mail, a page's upload field), like
    /// Safari's downloads list (FileDrag.swift).
    var onDragMoved: ((NSPoint) -> Void)?
    var onDragEnded: ((NSPoint, NSDragOperation) -> Void)?
    override func mouseDown(with event: NSEvent) {
      guard FileDrag.draggable(file) != nil else { return }
      FileDrag.track(self, event, drag: beginFileDrag) { onRestore?() }
    }
    override func mouseUp(with event: NSEvent) {
      if event.clickCount == 1, bounds.contains(convert(event.locationInWindow, from: nil)) { onRestore?() }
    }

    func beginFileDrag(_ e: NSEvent) {
      guard let item = FileDrag.item(file, at: convert(e.locationInWindow, from: nil)) else { return }
      beginDraggingSession(with: [item], event: e, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
      FileDrag.operations(context)
    }
    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) { onDragMoved?(screenPoint) }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
      onDragEnded?(screenPoint, operation)
    }
  }

  final class SectionTab: FlippedView {
    let label = makeLabel(size: 13.5, weight: .semibold)
    let keycap = Keycap()
    var sectionId = ""
    var selected = false { didSet { needsDisplay = true } }
    var fill: NSColor = .clear
    var onClick: (() -> Void)?
    override init(frame: NSRect) {
      super.init(frame: frame)
      addSubview(label)
      addSubview(keycap)
    }
    required init?(coder: NSCoder) { fatalError() }
    /// The label's text plus the field cell's own inset (without it the title truncates).
    var labelWidth: CGFloat { ceil(label.textWidth) + 6 }
    var preferredWidth: CGFloat { 12 + labelWidth + (keycap.text.isEmpty ? 10 : 4 + keycap.preferredWidth + 8) }
    override func draw(_ dirtyRect: NSRect) {
      guard selected else { return }
      fill.setFill()
      NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
    override func layout() {
      label.frame = NSRect(x: 12, y: (bounds.height - 18) / 2, width: labelWidth, height: 18)
      keycap.isHidden = keycap.text.isEmpty
      keycap.frame = NSRect(x: label.frame.maxX + 4, y: (bounds.height - 18) / 2, width: keycap.preferredWidth, height: 18)
    }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
  }

  let headerIcon = IconView()
  let titleLabel = makeLabel(size: 20, weight: .semibold)
  var tabs: [SectionTab] = []
  lazy var clearButton = PillButton(title: "Clear Archive", style: "destructiveSecondary") { [weak self] in self?.send("clear") }
  lazy var closeButton = IconButton(symbol: "xmark", size: 28) { [weak self] in self?.send("dismiss") }
  let searchField = FlippedView()
  let searchIcon = IconView()
  let input = NSTextField()
  let scroll = NSScrollView()
  let doc = FlippedView()
  let emptyLabel = makeLabel(size: 13)
  var headers: [NSTextField] = []
  var rows: [Row] = []
  var node: Value = .null
  var now: () -> Date = Date.init
  let emit: (String, String, Value) -> Void

  init(emit: @escaping (String, String, Value) -> Void) {
    self.emit = emit
    super.init(radius: Tokens.libraryCornerRadius)
    headerIcon.spec = "sf:archivebox"
    searchField.wantsLayer = true
    searchField.layer?.cornerRadius = Tokens.urlPillCornerRadius
    searchField.layer?.cornerCurve = .continuous
    searchIcon.spec = "sf:magnifyingglass"
    input.isBordered = false
    input.drawsBackground = false
    input.focusRingType = .none
    input.font = .systemFont(ofSize: 14)
    input.delegate = self
    input.cell?.isScrollable = true
    input.cell?.wraps = false
    searchField.addSubview(searchIcon)
    searchField.addSubview(input)
    scroll.drawsBackground = false
    HoverTracker.watchScrolling(scroll)
    scroll.hasVerticalScroller = true
    scroll.scrollerStyle = .overlay
    scroll.autohidesScrollers = true
    scroll.contentView.drawsBackground = false
    scroll.documentView = doc
    emptyLabel.alignment = .center
    [headerIcon, titleLabel, clearButton, closeButton, searchField, scroll, emptyLabel].forEach { surface.addSubview($0) }
  }
  required init?(coder: NSCoder) { fatalError() }

  var libId: String { node.str("id", "library") }
  func send(_ action: String, _ value: Value = .null) { emit(libId, action, value) }

  // MARK: Dragging a file onto den's own page

  /// The dim behind the sheet (UIService), hidden with the sheet while a file is dragged to the page.
  weak var backdrop: NSView?
  /// True while a row's file is being dragged over den's window outside the sheet: the sheet and
  /// its dim step aside so the page underneath (a Gmail compose, a GitHub comment, an upload
  /// field) takes the drop. A drag to Finder or another app leaves the sheet where it is.
  private(set) var steppedAside = false

  /// A dragged row's file is at `screenPoint`.
  func fileDragMoved(_ screenPoint: NSPoint) {
    guard !steppedAside, let w = window, let content = w.contentView, let sup = superview else { return }
    let p = w.convertPoint(fromScreen: screenPoint)  // window coordinates
    guard content.frame.contains(p), !frame.contains(sup.convert(p, from: nil)) else { return }
    steppedAside = true
    isHidden = true
    backdrop?.isHidden = true
  }

  /// The drag ended. Dropped on den's page with the sheet aside: the sheet closes (`dismiss`), as
  /// the file went where it was meant to; otherwise it comes back.
  func fileDragEnded(_ screenPoint: NSPoint, _ operation: NSDragOperation) {
    guard steppedAside else { return }
    steppedAside = false
    isHidden = false
    backdrop?.isHidden = false
    if !operation.isEmpty, let w = window, w.frame.contains(screenPoint) { send("dismiss") }
  }

  func update(_ v: Value, palette p: Palette) {
    let old = node
    node = v
    titleLabel.stringValue = v.str("title", "Archive")
    headerIcon.spec = v.str("icon", "sf:archivebox")
    clearButton.label.stringValue = v.str("clearTitle", "Clear Archive")
    clearButton.isHidden = v.list("items").isEmpty || v["clearTitle"].string == ""
    input.placeholderString = v.str("placeholder", "Search the Archive")
    // A new section starts with its own query.
    if input.currentEditor() == nil || old.isNull || old.str("section") != v.str("section") { input.stringValue = v.str("query") }
    if old["sections"] != v["sections"] || old.str("section") != v.str("section") { rebuildTabs() }
    rebuild()
    apply(p)
    needsLayout = true
  }

  func rebuildTabs() {
    tabs.forEach { $0.removeFromSuperview() }
    let current = node.str("section")
    tabs = node.list("sections").map { s in
      let t = SectionTab()
      t.sectionId = s.str("id")
      t.label.stringValue = s.str("title")
      t.keycap.text = s.str("keycap")
      t.selected = t.sectionId == current
      let id = t.sectionId
      t.onClick = { [weak self] in self?.send("section", ["id": .string(id)]) }
      surface.addSubview(t)
      return t
    }
    titleLabel.isHidden = !tabs.isEmpty
  }

  /// Items matching the typed text (title or URL, case-insensitive).
  var filtered: [Value] {
    let q = input.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
    let items = node.list("items")
    guard !q.isEmpty else { return items }
    return items.filter { $0.str("title").lowercased().contains(q) || $0.str("url").lowercased().contains(q) }
  }

  /// Day buckets for `closedAt` (estimate: Arc's grouping is UNVERIFIED).
  static func section(for closedAt: Double?, now: Date, calendar: Calendar = .current) -> String {
    guard let ms = closedAt else { return "Earlier" }
    let d = Date(timeIntervalSince1970: ms / 1000)
    if calendar.isDate(d, inSameDayAs: now) { return "Today" }
    if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(d, inSameDayAs: y) { return "Yesterday" }
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: d), to: calendar.startOfDay(for: now)).day ?? 99
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = days < 7 ? "EEEE" : "MMMM d"
    return f.string(from: d)
  }

  /// The subtitle's location: the domain or file name, never a raw data:/about: URL.
  static func host(_ url: String) -> String { Sites.label(url) }

  /// Row tooltip: the URL, but not a data: URL's (possibly huge) payload.
  static func tooltip(_ url: String) -> String? {
    if url.isEmpty || url == "about:blank" { return nil }
    return url.hasPrefix("data:") ? String(url.prefix(while: { $0 != "," && $0 != ";" })) : url
  }

  static func time(_ closedAt: Double?) -> String {
    guard let ms = closedAt else { return "" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "h:mm a"
    return f.string(from: Date(timeIntervalSince1970: ms / 1000))
  }

  func rebuild() {
    headers.forEach { $0.removeFromSuperview() }
    // Rows are reused by item id, so a download's row keeps its hover (and a half-done click on its
    // Pause button) while progress updates arrive.
    var pool: [String: Row] = [:]
    for r in rows { pool[r.itemId] = r }
    headers = []
    rows = []
    var current = ""
    for it in filtered {
      let sec = it["section"].string ?? Self.section(for: it["closedAt"].double, now: now())
      if sec != current {
        current = sec
        let h = makeLabel(sec, size: 11, weight: .semibold)
        headers.append(h)
        doc.addSubview(h)
      }
      let r = pool.removeValue(forKey: it.str("id")) ?? Row()
      r.itemId = it.str("id")
      r.icon.spec = it.str("icon", "sf:globe")
      r.icon.fallbackLetter = it.str("title")
      r.title.stringValue = it.str("title", "Untitled")
      let sub = it["subtitle"].string.map { $0.replacingOccurrences(of: "{time}", with: Self.time(it["closedAt"].double)) }
        ?? [Self.host(it.str("url")), Self.time(it["closedAt"].double)].filter { !$0.isEmpty }.joined(separator: " · ")
      r.subtitle.stringValue = sub
      r.icon.fallbackDomain = Sites.domain(it.str("url"))
      r.progress = it["progress"].double
      r.file = it.str("file")
      let pill = it["pill"].string ?? "Restore"
      r.hasPill = !pill.isEmpty
      r.restore.label.stringValue = pill
      r.setButtons(it.list("buttons"))
      r.alphaValue = it.flag("dimmed") ? 0.55 : 1
      let iid = r.itemId
      r.onRestore = { [weak self] in self?.send("restore", ["item": .string(iid)]) }
      r.onButton = { [weak self] b in self?.send("button", ["item": .string(iid), "button": .string(b)]) }
      r.onDragMoved = { [weak self] p in self?.fileDragMoved(p) }
      r.onDragEnded = { [weak self] p, op in self?.fileDragEnded(p, op) }
      rows.append(r)
      if r.superview !== doc { doc.addSubview(r) }
      r.identifier = NSUserInterfaceItemIdentifier(sec)
      r.needsLayout = true
    }
    pool.values.forEach { $0.removeFromSuperview() }
    emptyLabel.stringValue = node.list("items").isEmpty ? node.str("empty", "Nothing in the Archive yet") : "No matches"
    emptyLabel.isHidden = !rows.isEmpty
  }

  override func apply(_ p: Palette) {
    super.apply(p)
    palette = p
    surface.layer?.backgroundColor = p.surface.cgColor
    titleLabel.textColor = p.textPrimary
    headerIcon.tint = p.textPrimary
    clearButton.apply(p)
    closeButton.apply(p)
    searchField.layer?.backgroundColor = p.pillFill.cgColor
    searchIcon.tint = p.textSecondary
    input.textColor = p.textPrimary
    emptyLabel.textColor = p.textSecondary
    headers.forEach { $0.textColor = p.textSecondary }
    for t in tabs {
      t.label.textColor = t.selected ? p.textPrimary : p.textSecondary
      t.fill = p.pillFill
      t.keycap.apply(p, onAccent: false)
      t.needsDisplay = true
    }
    for r in rows {
      r.title.textColor = p.textPrimary
      r.subtitle.textColor = p.textSecondary
      r.icon.tint = p.textPrimary
      r.hoverFill = p.rowHover.withAlphaComponent(p.dark ? 0.08 : 0.05)
      r.restore.apply(p)
      r.buttons.forEach { $0.apply(p) }
      r.bar.layer?.backgroundColor = p.textPrimary.withAlphaComponent(0.12).cgColor
      r.barFill.layer?.backgroundColor = p.accentStrong.cgColor
    }
  }

  override func layout() {
    super.layout()
    let pad = Tokens.libraryPadding, w = bounds.width
    headerIcon.frame = NSRect(x: pad, y: pad + 3, width: 22, height: 22)
    titleLabel.frame = NSRect(x: pad + 32, y: pad + 1, width: 300, height: 26)
    var tx = pad + 28
    for t in tabs {
      let tw = t.preferredWidth
      t.frame = NSRect(x: tx, y: pad, width: tw, height: 28)
      t.needsLayout = true
      tx += tw + 4
    }
    closeButton.frame = NSRect(x: w - pad - 28, y: pad, width: 28, height: 28)
    let cw = clearButton.preferredWidth
    clearButton.frame = NSRect(x: closeButton.frame.minX - 10 - cw, y: pad - 1, width: cw, height: 30)
    let sy = pad + 28 + 16
    searchField.frame = NSRect(x: pad, y: sy, width: w - 2 * pad, height: Tokens.urlPillHeight)
    searchIcon.frame = NSRect(x: 12, y: (Tokens.urlPillHeight - 16) / 2, width: 16, height: 16)
    input.frame = NSRect(x: 38, y: (Tokens.urlPillHeight - 20) / 2, width: searchField.bounds.width - 50, height: 20)
    let ly = sy + Tokens.urlPillHeight + 10
    scroll.frame = NSRect(x: pad - 8, y: ly, width: w - 2 * pad + 16, height: max(0, bounds.height - ly - 12))
    emptyLabel.frame = NSRect(x: pad, y: ly + 60, width: w - 2 * pad, height: 18)
    var y: CGFloat = 4
    var hi = 0
    var last = ""
    let dw = scroll.contentSize.width
    for r in rows {
      let sec = r.identifier?.rawValue ?? ""
      if sec != last, hi < headers.count {
        last = sec
        headers[hi].frame = NSRect(x: 12, y: y + 10, width: dw - 24, height: 15)
        hi += 1
        y += 32
      }
      r.frame = NSRect(x: 0, y: y, width: dw, height: Tokens.libraryRowHeight)
      r.needsLayout = true
      y += Tokens.libraryRowHeight
    }
    doc.frame = NSRect(x: 0, y: 0, width: dw, height: max(y + 8, scroll.contentSize.height))
  }

  func controlTextDidChange(_ obj: Notification) {
    rebuild()
    if let p = palette { apply(p) }
    needsLayout = true
    send("input", ["text": .string(input.stringValue)])
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
    if sel == #selector(NSResponder.cancelOperation(_:)) { send("dismiss"); return true }
    if sel == #selector(NSResponder.insertNewline(_:)), let first = rows.first { send("restore", ["item": .string(first.itemId)]); return true }
    return false
  }
}
