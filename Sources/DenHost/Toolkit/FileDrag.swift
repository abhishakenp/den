import AppKit

/// Dragging a downloaded file out of den (Library ▸ Downloads rows, the sidebar's download button),
/// like Safari's downloads list: the drag carries the file's URL (`public.file-url`), which Finder,
/// Mail, Slack and a web page's file input or drop zone all read. Only a file that exists drags;
/// a moved or deleted download stays put (its click still works).
@MainActor
enum FileDrag {
  /// The file a `file` / `dragFile` path names, when it is there to drag.
  static func draggable(_ path: String) -> URL? {
    guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else { return nil }
    return URL(fileURLWithPath: path)
  }

  /// What the drag writes: the file URL itself (NSURL writes `public.file-url` plus the legacy
  /// filename type AppKit apps read).
  static func writer(_ path: String) -> NSPasteboardWriting? { draggable(path).map { $0 as NSURL } }

  /// Writes the dragged file to a pasteboard: the same writer a drag uses (tests, a page drop).
  @discardableResult
  static func write(_ path: String, to pb: NSPasteboard) -> Bool {
    guard let w = writer(path) else { return false }
    pb.clearContents()
    return pb.writeObjects([w])
  }

  /// Safari's: other apps may copy, link or move the file (Finder's own rule picks copy across
  /// volumes, move within one only with ⌘); inside den only a copy (a page's upload, a new tab).
  static func operations(_ context: NSDraggingContext) -> NSDragOperation {
    context == .outsideApplication ? [.copy, .link, .generic] : .copy
  }

  /// A dragging item for the file with Finder's icon, 32 pt, centred under the pointer.
  static func item(_ path: String, at p: NSPoint) -> NSDraggingItem? {
    guard let w = writer(path) else { return nil }
    let item = NSDraggingItem(pasteboardWriter: w)
    item.setDraggingFrame(NSRect(x: p.x - 16, y: p.y - 16, width: 32, height: 32), contents: NSWorkspace.shared.icon(forFile: path))
    return item
  }

  /// Tracks a press on `view`: a move past 4 pt calls `drag` with that event, a release inside the
  /// view calls `click`. Returns at once (and calls neither) when the view has no window.
  static func track(_ view: NSView, _ down: NSEvent, drag: (NSEvent) -> Void, click: () -> Void) {
    guard let window = view.window else { return }
    let start = down.locationInWindow
    while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
      if e.type == .leftMouseUp {
        if view.bounds.contains(view.convert(e.locationInWindow, from: nil)) { click() }
        return
      }
      if hypot(e.locationInWindow.x - start.x, e.locationInWindow.y - start.y) > 4 { return drag(e) }
    }
  }
}
