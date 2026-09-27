import AppKit
import CordisValue

/// Archive / Library sheet, shown in the `overlay.library` slot over the content area.
///
/// {type:"library", id, title? ("Archive"), query?, placeholder?, clearTitle? ("Clear Archive"),
///  empty? (empty-state text), items: [{id, title, url?, subtitle?, icon?, closedAt? (ms since 1970)}]}
/// Items are grouped by `closedAt` day (Today, Yesterday, weekday, then month + day) and filtered
/// locally as you type, so search is instant; the typed text is also emitted.
/// actions (id = library id): input {text}, restore {item}, clear, dismiss (Esc, close button, backdrop)
/// Arc's archive view was not measured (spec §12): every value here is an estimate in Tokens.
@MainActor
final class LibraryView: PanelView, NSTextFieldDelegate {
  final class Row: FlippedView, Hoverable {
    var hoverGroup: HoverGroup { .row }
    let icon = IconView()
    let title = makeLabel(size: 13.5, weight: .medium)
    let subtitle = makeLabel(size: 12)
    lazy var restore = PillButton(title: "Restore", style: "secondary") { [weak self] in self?.onRestore?() }
    var itemId = ""
    var hovering = false { didSet { restore.isHidden = !hovering; needsDisplay = true } }
    var hoverFill: NSColor = .clear
    var onRestore: (() -> Void)?

    override init(frame: NSRect) {
      super.init(frame: frame)
      [icon, title, subtitle, restore].forEach { addSubview($0) }
      restore.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
      guard hovering else { return }
      hoverFill.setFill()
      NSBezierPath(roundedRect: bounds, xRadius: Tokens.libraryRowRadius, yRadius: Tokens.libraryRowRadius).fill()
    }
    override func layout() {
      let h = bounds.height, s = Tokens.tabRowIconSize
      icon.frame = NSRect(x: 12, y: (h - s) / 2, width: s, height: s)
      let rw = restore.preferredWidth
      restore.frame = NSRect(x: bounds.width - 8 - rw, y: (h - 28) / 2, width: rw, height: 28)
      let right = (restore.isHidden ? bounds.width - 12 : restore.frame.minX - 8)
      title.frame = NSRect(x: 42, y: h / 2 - 17, width: max(0, right - 42), height: 17)
      subtitle.frame = NSRect(x: 42, y: h / 2 + 1, width: max(0, right - 42), height: 15)
    }
    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      trackingAreas.forEach(removeTrackingArea)
      addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { HoverTracker.refresh(window); needsLayout = true }
    override func mouseExited(with event: NSEvent) { HoverTracker.refresh(window); needsLayout = true }
    override func mouseUp(with event: NSEvent) {
      if event.clickCount == 1, bounds.contains(convert(event.locationInWindow, from: nil)) { onRestore?() }
    }
  }

  let headerIcon = IconView()
  let titleLabel = makeLabel(size: 20, weight: .semibold)
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
  var palette: Palette?
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

  func update(_ v: Value, palette p: Palette) {
    let old = node
    node = v
    titleLabel.stringValue = v.str("title", "Archive")
    clearButton.label.stringValue = v.str("clearTitle", "Clear Archive")
    clearButton.isHidden = v.list("items").isEmpty
    input.placeholderString = v.str("placeholder", "Search the Archive")
    if input.currentEditor() == nil || old.isNull { input.stringValue = v.str("query") }
    rebuild()
    apply(p)
    needsLayout = true
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

  static func host(_ url: String) -> String {
    guard let h = URL(string: url)?.host else { return url }
    return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
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
    rows.forEach { $0.removeFromSuperview() }
    headers = []
    rows = []
    var current = ""
    for it in filtered {
      let sec = Self.section(for: it["closedAt"].double, now: now())
      if sec != current {
        current = sec
        let h = makeLabel(sec, size: 11, weight: .semibold)
        headers.append(h)
        doc.addSubview(h)
      }
      let r = Row()
      r.itemId = it.str("id")
      r.icon.spec = it.str("icon", "sf:globe")
      r.icon.fallbackLetter = it.str("title")
      r.title.stringValue = it.str("title", "Untitled")
      let sub = it["subtitle"].string ?? [Self.host(it.str("url")), Self.time(it["closedAt"].double)].filter { !$0.isEmpty }.joined(separator: " · ")
      r.subtitle.stringValue = sub
      let iid = r.itemId
      r.onRestore = { [weak self] in self?.send("restore", ["item": .string(iid)]) }
      rows.append(r)
      doc.addSubview(r)
      r.identifier = NSUserInterfaceItemIdentifier(sec)
    }
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
    for r in rows {
      r.title.textColor = p.textPrimary
      r.subtitle.textColor = p.textSecondary
      r.icon.tint = p.textPrimary
      r.hoverFill = p.rowHover.withAlphaComponent(p.dark ? 0.08 : 0.05)
      r.restore.apply(p)
    }
  }

  override func layout() {
    super.layout()
    let pad = Tokens.libraryPadding, w = bounds.width
    headerIcon.frame = NSRect(x: pad, y: pad + 3, width: 22, height: 22)
    titleLabel.frame = NSRect(x: pad + 32, y: pad + 1, width: 300, height: 26)
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
