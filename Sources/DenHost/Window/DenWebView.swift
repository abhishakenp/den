import AppKit
import WebKit

/// den's WKWebView: a browser-style context menu (new *tab* instead of new window, Peek, Save
/// Link/Image As…, "Search <engine> for “…”"), mouse back/forward buttons, and files dropped on
/// the page opening as tabs instead of replacing it.
@MainActor
final class DenWebView: WKWebView {
  weak var service: WebViewsService?
  var recordId = ""
  /// What the last right-click hit, reported by `contextScript` just before WebKit asks for the menu.
  var context = ContextHit()

  struct ContextHit: Equatable { var link = ""; var image = ""; var selection = "" }

  /// Reports the right-clicked link, image and selection. Runs in every frame; the message is
  /// posted from the DOM `contextmenu` event, which WebContent handles before it asks the UI
  /// process to show the menu, so it arrives first.
  static let contextScript = """
    document.addEventListener('contextmenu',function(e){var t=e.target;if(t&&t.nodeType!==1)t=t.parentElement;var a=t&&t.closest?t.closest('a[href]'):null,i=t&&t.closest?t.closest('img'):null;
    try{webkit.messageHandlers.denContext.postMessage({link:a?a.href:'',image:i?(i.currentSrc||i.src||''):'',selection:String(window.getSelection()||'')})}catch(x){}},true);
    """

  /// Off-display (invisible) windows: a page shown in an ordered-in window paints (`Presentation`).
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    Presentation.webViewMoved(self)
  }

  // MARK: Context menu

  override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
    super.willOpenMenu(menu, with: event)
    Self.customize(menu, hit: context, peek: service?.host.hasListeners("peek.link") == true, engine: service?.pageActions?.searchEngineName ?? "Google", target: self)
    // Plugins' items (`webviews.setMenu`, e.g. "Copy Link to Highlight").
    service?.contextMenu?(self, menu)
  }

  /// Rewrites WebKit's default items (identifiers are WebKit's `WKMenuItemIdentifier…` strings).
  static func customize(_ menu: NSMenu, hit: ContextHit, peek: Bool, engine: String, target: DenWebView?) {
    func item(_ title: String, _ sel: Selector, _ value: String) -> NSMenuItem {
      let m = NSMenuItem(title: title, action: sel, keyEquivalent: "")
      m.target = target
      m.representedObject = value
      return m
    }
    var i = 0
    while i < menu.items.count {
      let it = menu.items[i]
      switch it.identifier?.rawValue ?? "" {
      case "WKMenuItemIdentifierOpenLinkInNewWindow":
        if hit.link.isEmpty { it.title = "Open Link in New Tab" } else {
          menu.removeItem(at: i)
          menu.insertItem(item("Open Link in New Tab", #selector(openLinkInTab(_:)), hit.link), at: i)
          if peek {
            i += 1
            menu.insertItem(item("Open Link in Peek", #selector(openLinkInPeek(_:)), hit.link), at: i)
          }
        }
      case "WKMenuItemIdentifierDownloadLinkedFile":
        if hit.link.isEmpty { menu.removeItem(at: i); continue }
        menu.removeItem(at: i)
        menu.insertItem(item("Save Link As…", #selector(saveAs(_:)), hit.link), at: i)
      case "WKMenuItemIdentifierOpenImageInNewWindow":
        if hit.image.isEmpty { it.title = "Open Image in New Tab" } else {
          menu.removeItem(at: i)
          menu.insertItem(item("Open Image in New Tab", #selector(openLinkInTab(_:)), hit.image), at: i)
        }
      case "WKMenuItemIdentifierDownloadImage":
        if hit.image.isEmpty { menu.removeItem(at: i); continue }
        menu.removeItem(at: i)
        menu.insertItem(item("Save Image As…", #selector(saveAs(_:)), hit.image), at: i)
      case "WKMenuItemIdentifierOpenFrameInNewWindow": it.title = "Open Frame in New Tab"
      case "WKMenuItemIdentifierOpenMediaInNewWindow": it.title = "Open Video in New Tab"
      case "WKMenuItemIdentifierSearchWeb":
        let s = hit.selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { break }
        let short = s.count > 30 ? String(s.prefix(30)).trimmingCharacters(in: .whitespaces) + "…" : s
        menu.removeItem(at: i)
        menu.insertItem(item("Search \(engine) for “\(short)”", #selector(searchSelection(_:)), s), at: i)
      default: break
      }
      i += 1
    }
  }

  @objc func openLinkInTab(_ sender: NSMenuItem) {
    guard let url = sender.representedObject as? String else { return }
    service?.host.emit("webviews.newWindow", ["id": .string(recordId), "url": .string(url), "background": true])
  }
  @objc func openLinkInPeek(_ sender: NSMenuItem) {
    guard let url = sender.representedObject as? String else { return }
    service?.host.emit("peek.link", ["id": .string(recordId), "url": .string(url), "source": .string(self.url?.absoluteString ?? "")])
  }
  @objc func searchSelection(_ sender: NSMenuItem) {
    guard let s = sender.representedObject as? String, let pa = service?.pageActions else { return }
    service?.host.emit("webviews.newWindow", ["id": .string(recordId), "url": .string(pa.searchURL(s)), "background": false])
  }
  @objc func saveAs(_ sender: NSMenuItem) {
    guard let s = sender.representedObject as? String, let u = URL(string: s) else { return }
    // Through the downloads list, with a save panel for the destination.
    let ask = service?.downloads
    startDownload(using: URLRequest(url: u)) { [weak self] d in
      MainActor.assumeIsolated {
        if let ask { ask.adopt(d, webview: self?.recordId ?? "", ask: true) } else { SaveAsDownloads.shared.track(d) }
      }
    }
  }

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
  /// Loads a web URL, or a local file with read access to its folder (dropped files, file:// tabs).
  func open(_ u: URL) {
    if u.isFileURL { loadFileURL(u, allowingReadAccessTo: u.deletingLastPathComponent()) } else { load(URLRequest(url: u)) }
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
