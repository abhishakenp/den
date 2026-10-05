import AppKit
import WebKit

/// den's WKWebView: a browser-style context menu (PageContextMenu.swift: new *tab* instead of new
/// window, Peek, split, private window, Save As…, copy as Markdown, search, PiP, Inspect
/// Element…), mouse back/forward buttons, and files dropped on the page opening as tabs instead
/// of replacing it.
@MainActor
final class DenWebView: WKWebView {
  weak var service: WebViewsService?
  var recordId = ""
  /// What the last right-click hit, reported by `contextScript` just before WebKit asks for the menu.
  var context = ContextHit()

  /// Off-display (invisible) windows: a page shown in an ordered-in window paints (`Presentation`).
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    Presentation.webViewMoved(self)
  }

  // MARK: Context menu

  override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
    super.willOpenMenu(menu, with: event)
    Self.customize(menu, hit: context, env: menuEnv, target: self)
    // Plugins' items (`webviews.setMenu`, e.g. "Copy Link to Highlight", "Translate Page").
    service?.contextMenu?(self, menu)
    // Extensions' items (`contextMenus` / `menus`) are already in: WebKit adds them for what was
    // clicked (ExtensionsService.tabMenu has the tab's own).
    // Inspect Element last; no stray separators.
    Self.finish(menu)
    Self.menuOpened?(self, menu)
  }

  /// Tests and snapshots: the finished menu, just before AppKit shows it.
  static var menuOpened: ((DenWebView, NSMenu) -> Void)?
  /// Where the context menu's Copy … items write (tests use a private pasteboard).
  static var pasteboard: NSPasteboard = .general

  // MARK: Mouse buttons

  /// Mouse buttons 4 and 5 (buttonNumber 3 / 4) go back and forward, as in Safari and Chrome.
  override func otherMouseUp(with event: NSEvent) {
    switch event.buttonNumber {
    case 3: if canGoBack { goBack(); return }
    case 4: if canGoForward { goForward(); return }
    default: break
    }
    super.otherMouseUp(with: event)
  }

  // MARK: Dropped files

  /// Files dragged in from Finder open as new tabs (WebKit would replace this page with them).
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    if sender.draggingSource == nil, let urls = Self.fileURLs(sender.draggingPasteboard), !urls.isEmpty {
      service?.host.emit("window.dropURLs", ["urls": .array(urls.map { .string($0.absoluteString) }), "target": "content"])
      return true
    }
    return super.performDragOperation(sender)
  }

  static func fileURLs(_ pb: NSPasteboard) -> [URL]? {
    (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])
  }
}

extension WKWebView {
  /// Loads a web URL, or a local file (dropped files, typed paths, file:// tabs) with read access to
  /// the home folder when it's inside it, else its own folder, so relative assets load.
  func open(_ u: URL) {
    if u.isFileURL { loadFileURL(u, allowingReadAccessTo: LocalFiles.readAccess(for: u)) } else { load(URLRequest(url: u)) }
  }
}

/// "Save Link As…" / "Save Image As…": a WKDownload whose destination comes from a save panel
/// (as a sheet on the page's window). Uses the page's own session, so signed-in images work.
@MainActor
final class SaveAsDownloads: NSObject, WKDownloadDelegate {
  static let shared = SaveAsDownloads()
  private var active: [WKDownload] = []

  func track(_ d: WKDownload) {
    d.delegate = self
    active.append(d)
  }

  func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = suggestedFilename
    panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    let done: (NSApplication.ModalResponse) -> Void = { r in
      guard r == .OK, let u = panel.url else { return completionHandler(nil) }
      try? FileManager.default.removeItem(at: u)  // the panel already confirmed replacing it
      completionHandler(u)
    }
    if let w = download.webView?.window { panel.beginSheetModal(for: w, completionHandler: done) } else { done(panel.runModal()) }
  }

  func downloadDidFinish(_ download: WKDownload) { active.removeAll { $0 === download } }
  func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) { active.removeAll { $0 === download } }
}
