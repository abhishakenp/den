import AppKit
import CordisValue
import WebKit

// thin-host: feature-specific, migrate to plugin: the context menu's wording and den-only items
// (Peek, split, Markdown, image search) belong to plugins; the host keeps WebKit's menu, the hit
// report and generic page actions.

/// A page's right-click menu, built on WebKit's own (`willOpenMenu`): WebKit's items are kept and
/// reworded by their `WKMenuItemIdentifier…` (so Look Up, Translate, Speech, Services, spelling,
/// Writing Tools and Share work as in Safari), den adds its own next to them, and every item with
/// a menu bar twin shows its chord (remaps included). Per context:
///
/// - **Link:** Open Link in New Tab / New Window / Private Window / Peek / Split View, Download
///   Linked File, Save Link As…, Copy Link, Copy Link as Markdown, Share.
/// - **Image:** Open Image in New Tab, Save Image As…, Copy Image, Copy Image Address, Copy
///   Subject, Look Up, Search Image with Google Lens, Share.
/// - **Selection:** Look Up, Translate, Search <engine> for “…”, Copy, Copy Link to Highlight
///   (pagetools; WebKit's "Copy Link with Highlight" twin is dropped then), Share, Writing Tools,
///   Speech.
/// - **Editable:** Cut, Copy, Paste, Paste and Match Style, Spelling and Grammar, Substitutions,
///   Transformations, Font, Speech, writing direction.
/// - **Video / audio:** Play/Pause, Mute, Show/Hide Controls, Loop, Enter Full Screen, Picture in
///   Picture (den's `media` service, WebKit's native PiP), Viewer, Open Video in New Tab, Save
///   Video As…, Copy Video Address.
/// - **Page:** Back, Forward, Reload, Save Page As…, Print…, View Page Source, then plugins'
///   page items (Translate Page, Zap Elements).
///
/// Then plugins' and extensions' items, and Inspect Element last.
extension DenWebView {
  /// What the right-click hit, from the page's `contextmenu` event (`contextScript`).
  struct ContextHit: Equatable {
    var link = ""
    var linkText = ""
    var image = ""
    /// The video or audio element's http(s) source ("" for blob:/MediaSource streams).
    var media = ""
    var mediaKind = ""  // "video", "audio" or ""
    var selection = ""
  }

  /// What den can offer beyond WebKit's items (who listens, the default search engine).
  struct MenuEnv {
    var peek = false
    var split = false
    var engine = "Google"
  }

  var menuEnv: MenuEnv {
    MenuEnv(peek: service?.host.hasListeners("peek.link") == true, split: service?.host.hasListeners("peek.splitLink") == true,
            engine: service?.pageActions?.searchEngineName ?? "Google")
  }

  /// Reports the right-clicked link (and its text), image, media and selection. Runs in every
  /// frame; the message is posted from the DOM `contextmenu` event, which WebContent handles
  /// before it asks the UI process to show the menu, so it arrives first.
  static let contextScript = """
    document.addEventListener('contextmenu',function(e){var t=e.target;if(t&&t.nodeType!==1)t=t.parentElement;function c(s){return t&&t.closest?t.closest(s):null}
    var a=c('a[href]'),i=c('img'),m=c('video,audio'),ms=m?(m.currentSrc||m.src||''):'';if(!/^https?:/i.test(ms))ms='';
    try{webkit.messageHandlers.denContext.postMessage({link:a?a.href:'',linkText:a?String(a.innerText||a.textContent||'').trim().slice(0,500):'',image:i?(i.currentSrc||i.src||''):'',
    media:ms,mediaKind:m?m.tagName.toLowerCase():'',selection:String(window.getSelection()||'')})}catch(x){}},true);
    """

  /// WebKit's items -> the menu bar item that does the same (docs/shortcuts.md ids).
  static let menuShortcuts: [String: String] = [
    "WKMenuItemIdentifierGoBack": "history.back", "WKMenuItemIdentifierGoForward": "history.forward",
    "WKMenuItemIdentifierReload": "view.reload", "WKMenuItemIdentifierStop": "view.stop",
    "WKMenuItemIdentifierCut": "edit.cut", "WKMenuItemIdentifierCopy": "edit.copy", "WKMenuItemIdentifierPaste": "edit.paste",
    "WKMenuItemIdentifierInspectElement": "view.inspectElement",
  ]

  static let wk = "WKMenuItemIdentifier"
  static let pageItems: Set<String> = ["GoBack", "GoForward", "Reload", "Stop"]
  static let mediaItems: Set<String> = ["ShowHideMediaControls", "ToggleFullScreen", "ToggleEnhancedFullScreen", "ToggleVideoViewer", "OpenMediaInNewWindow", "DownloadMedia", "CopyMediaLink"]

  /// The menu for the page itself (no link, image, media, selection or text field under the
  /// pointer): WebKit's offers only Back / Forward / Reload / Stop then.
  static func isPageMenu(_ menu: NSMenu, hit: ContextHit) -> Bool {
    guard hit.link.isEmpty, hit.image.isEmpty, hit.mediaKind.isEmpty,
          hit.selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    return menu.items.contains { pageItems.contains(id($0) ?? "") }
  }

  /// WebKit's identifier without its prefix ("Copy"), nil for den's items.
  static func id(_ mi: NSMenuItem) -> String? {
    guard let s = mi.identifier?.rawValue, s.hasPrefix(wk) else { return nil }
    return String(s.dropFirst(wk.count))
  }

  /// Rewrites WebKit's default items and adds den's (see the type doc).
  static func customize(_ menu: NSMenu, hit: ContextHit, env: MenuEnv, target: DenWebView?) {
    func item(_ title: String, _ sel: Selector, _ value: String = "", key: String? = nil) -> NSMenuItem {
      let m = NSMenuItem(title: title, action: sel, keyEquivalent: "")
      m.target = target
      m.representedObject = value
      if let key { _ = Shortcuts.apply(key, to: m) }
      return m
    }
    let media = hit.mediaKind == "audio" ? "Audio" : "Video"
    let has = Set(menu.items.compactMap(id))
    var imageSearch: NSMenuItem? = hit.image.lowercased().hasPrefix("http") ? item("Search Image with Google Lens", #selector(searchImage(_:)), hit.image) : nil
    var i = 0
    // Replaces the item at `i` with `new` and moves past them.
    func replace(_ new: [NSMenuItem]) {
      menu.removeItem(at: i)
      for (k, n) in new.enumerated() { menu.insertItem(n, at: i + k) }
      i += new.count
    }
    func after(_ new: [NSMenuItem]) {
      for (k, n) in new.enumerated() { menu.insertItem(n, at: i + 1 + k) }
      i += new.count + 1
    }
    while i < menu.items.count {
      let it = menu.items[i]
      let wid = id(it) ?? ""
      if let key = menuShortcuts[wk + wid] { _ = Shortcuts.apply(key, to: it) }
      switch wid {
      // Link
      case "OpenLink":
        // "Open Link" (here) is what a click does; browsers' menus start with New Tab.
        if hit.link.isEmpty { i += 1 } else { menu.removeItem(at: i) }
      case "OpenLinkInNewWindow":
        guard !hit.link.isEmpty else { it.title = "Open Link in New Tab"; i += 1; continue }
        var links = [item("Open Link in New Tab", #selector(openLinkInTab(_:)), hit.link),
                     item("Open Link in New Window", #selector(openLinkInWindow(_:)), hit.link),
                     item("Open Link in Private Window", #selector(openLinkInPrivateWindow(_:)), hit.link)]
        if env.peek { links.append(item("Open Link in Peek", #selector(openLinkInPeek(_:)), hit.link)) }
        if env.split { links.append(item("Open Link in Split View", #selector(openLinkInSplit(_:)), hit.link)) }
        replace(links)
      case "DownloadLinkedFile":
        guard !hit.link.isEmpty else { menu.removeItem(at: i); continue }
        replace([.separator(), item("Download Linked File", #selector(downloadLink(_:)), hit.link),
                 item("Save Link As…", #selector(saveAs(_:)), hit.link), .separator()])
      case "CopyLink":
        guard !hit.link.isEmpty else { i += 1; continue }
        after([item("Copy Link as Markdown", #selector(copyText(_:)), markdownLink(hit))])
      // Image
      case "OpenImageInNewWindow":
        guard !hit.image.isEmpty else { it.title = "Open Image in New Tab"; i += 1; continue }
        replace([item("Open Image in New Tab", #selector(openLinkInTab(_:)), hit.image), .separator()])
      case "DownloadImage":
        guard !hit.image.isEmpty else { menu.removeItem(at: i); continue }
        replace([item("Save Image As…", #selector(saveAs(_:)), hit.image)])
      case "CopyImage":
        guard !hit.image.isEmpty, !hit.image.hasPrefix("data:") else { i += 1; continue }
        after([item("Copy Image Address", #selector(copyText(_:)), hit.image)])
      case "RevealImage":
        if let s = imageSearch { after([s]); imageSearch = nil } else { i += 1 }
      // Media
      case "ToggleEnhancedFullScreen":
        // Picture in picture goes through den's `media` service (WebKit's native PiP window),
        // which also knows to bring it back when you return to the tab.
        replace([item(it.title.isEmpty ? "Picture in Picture" : it.title, #selector(togglePictureInPicture(_:)), key: "media.key.pip")])
      case "OpenMediaInNewWindow":
        if hit.media.isEmpty { it.title = "Open \(media) in New Tab"; i += 1 } else {
          replace([item("Open \(media) in New Tab", #selector(openLinkInTab(_:)), hit.media)])
        }
      case "DownloadMedia":
        if hit.media.isEmpty { i += 1 } else { replace([item("Save \(media) As…", #selector(saveAs(_:)), hit.media)]) }
      case "CopyMediaLink":
        it.title = "Copy \(media) Address"
        i += 1
      // Selection
      case "SearchWeb":
        let s = hit.selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { i += 1; continue }
        let short = s.count > 30 ? String(s.prefix(30)).trimmingCharacters(in: .whitespaces) + "…" : s
        replace([item("Search \(env.engine) for “\(short)”", #selector(searchSelection(_:)), s)])
      // Text field
      case "Paste":
        after([item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), key: "edit.pastePlain")])
      case "OpenFrameInNewWindow":
        it.title = "Open Frame in New Tab"
        i += 1
      default:
        // WebKit's Cut has no identifier.
        if wid.isEmpty, it.title == "Cut", it.keyEquivalent.isEmpty { _ = Shortcuts.apply("edit.cut", to: it) }
        i += 1
      }
    }
    // An image with no Look Up item: the search goes after its copy items.
    if let s = imageSearch, let at = menu.items.lastIndex(where: { ["CopyImage", "CopySubject"].contains(id($0) ?? "") || $0.title == "Copy Image Address" }) {
      menu.insertItem(s, at: at + 1)
    }
    // A video or audio source WebKit offers nothing for (it does only for some files).
    if !hit.media.isEmpty, !has.contains("CopyMediaLink"), let last = menu.items.lastIndex(where: { mediaItems.contains(id($0) ?? "") || $0.action == #selector(togglePictureInPicture(_:)) }) {
      var add = [NSMenuItem.separator()]
      if !has.contains("OpenMediaInNewWindow") { add.append(item("Open \(media) in New Tab", #selector(openLinkInTab(_:)), hit.media)) }
      if !has.contains("DownloadMedia") { add.append(item("Save \(media) As…", #selector(saveAs(_:)), hit.media)) }
      add.append(item("Copy \(media) Address", #selector(copyText(_:)), hit.media))
      for (k, n) in add.enumerated() { menu.insertItem(n, at: last + 1 + k) }
    }
    // The page itself: Save Page As…, Print…, View Page Source after Back / Forward / Reload.
    if isPageMenu(menu, hit: hit), let last = menu.items.lastIndex(where: { pageItems.contains(id($0) ?? "") }) {
      let add = [NSMenuItem.separator(), item("Save Page As…", #selector(savePageAs(_:)), key: "file.savePage"),
                 item("Print…", #selector(printPage(_:)), key: "file.print"), .separator(),
                 item("View Page Source", #selector(viewPageSource(_:)), key: "view.viewSource")]
      for (k, n) in add.enumerated() { menu.insertItem(n, at: last + 1 + k) }
    }
  }

  /// After plugins and extensions added theirs: WebKit's "Copy Link with Highlight" goes when den's
  /// own "Copy Link to Highlight" is there, Inspect Element moves to the end, and separators are
  /// tidied (none first, last or twice in a row).
  static func finish(_ menu: NSMenu) {
    if menu.items.contains(where: { $0.title == "Copy Link to Highlight" && id($0) == nil }),
       let i = menu.items.firstIndex(where: { id($0) == "CopyLinkWithHighlight" }) {
      menu.removeItem(at: i)
    }
    if let i = menu.items.firstIndex(where: { id($0) == "InspectElement" }), i != menu.items.count - 1 {
      let it = menu.items[i]
      menu.removeItem(at: i)
      menu.addItem(.separator())
      menu.addItem(it)
    }
    var i = 0
    while i < menu.items.count {
      let sep = menu.items[i].isSeparatorItem
      if sep, i == 0 || i == menu.items.count - 1 || menu.items[i - 1].isSeparatorItem { menu.removeItem(at: i); continue }
      i += 1
    }
    if let l = menu.items.last, l.isSeparatorItem { menu.removeItem(l) }
  }

  /// `[text](url)`: the link's text (else its address), with brackets escaped.
  static func markdownLink(_ hit: ContextHit) -> String {
    let t = hit.linkText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    let text = (t.isEmpty ? hit.link : t).replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    let url = hit.link.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
    return "[\(text)](\(url))"
  }

  /// Google Lens for an image's address.
  static func imageSearchURL(_ image: String) -> String {
    "https://lens.google.com/uploadbyurl?url=" + (image.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
  }

  // MARK: Actions

  private func value(_ sender: NSMenuItem) -> String? { sender.representedObject as? String }

  @objc func openLinkInTab(_ sender: NSMenuItem) {
    guard let url = value(sender) else { return }
    service?.host.emit("webviews.newWindow", ["id": .string(recordId), "url": .string(url), "background": true])
  }
  @objc func openLinkInWindow(_ sender: NSMenuItem) {
    guard let url = value(sender) else { return }
    _ = service?.host.call("window", "new", ["url": .string(url)])
  }
  @objc func openLinkInPrivateWindow(_ sender: NSMenuItem) {
    guard let url = value(sender) else { return }
    _ = service?.host.call("window", "new", ["url": .string(url), "private": true])
  }
  @objc func openLinkInPeek(_ sender: NSMenuItem) {
    guard let url = value(sender) else { return }
    service?.host.emit("peek.link", ["id": .string(recordId), "url": .string(url), "source": .string(self.url?.absoluteString ?? "")])
  }
  @objc func openLinkInSplit(_ sender: NSMenuItem) {
    guard let url = value(sender) else { return }
    service?.host.emit("peek.splitLink", ["id": .string(recordId), "url": .string(url)])
  }
  @objc func searchSelection(_ sender: NSMenuItem) {
    guard let s = value(sender), let pa = service?.pageActions else { return }
    service?.host.emit("webviews.newWindow", ["id": .string(recordId), "url": .string(pa.searchURL(s)), "background": false])
  }
  @objc func searchImage(_ sender: NSMenuItem) {
    guard let s = value(sender) else { return }
    service?.host.emit("webviews.newWindow", ["id": .string(recordId), "url": .string(Self.imageSearchURL(s)), "background": false])
  }
  @objc func copyText(_ sender: NSMenuItem) {
    guard let s = value(sender) else { return }
    Self.pasteboard.clearContents()
    Self.pasteboard.setString(s, forType: .string)
    // A URL (an image's or video's address) also goes on as one.
    if !s.hasPrefix("["), let u = URL(string: s), u.scheme != nil { Self.pasteboard.setString(u.absoluteString, forType: .URL) }
  }
  /// Save … As…: through the downloads list, with a save panel for the destination.
  @objc func saveAs(_ sender: NSMenuItem) { if let s = value(sender) { download(s, ask: true) } }
  /// Download Linked File: straight into Downloads, like Safari.
  @objc func downloadLink(_ sender: NSMenuItem) { if let s = value(sender) { download(s, ask: false) } }

  func download(_ s: String, ask: Bool) {
    guard let u = URL(string: s) else { return }
    let downloads = service?.downloads
    startDownload(using: URLRequest(url: u)) { [weak self] d in
      MainActor.assumeIsolated {
        if let downloads { downloads.adopt(d, webview: self?.recordId ?? "", ask: ask) } else { SaveAsDownloads.shared.track(d) }
      }
    }
  }

  @objc func togglePictureInPicture(_ sender: NSMenuItem) {
    _ = service?.host.call("media", "toggle", ["webview": .string(recordId)])
  }
  @objc func savePageAs(_ sender: NSMenuItem) { MenuActions.savePage(self) }
  @objc func printPage(_ sender: NSMenuItem) { _ = service?.host.call("webviews", "print", ["id": .string(recordId)]) }
  @objc func viewPageSource(_ sender: NSMenuItem) { _ = service?.host.call("webviews", "viewSource", ["id": .string(recordId)]) }
}

extension DenWebView.ContextHit {
  /// From the `denContext` message body.
  init(_ b: [String: Any]) {
    func s(_ k: String) -> String { b[k] as? String ?? "" }
    self.init(link: s("link"), linkText: s("linkText"), image: s("image"), media: s("media"), mediaKind: s("mediaKind"), selection: s("selection"))
  }
}
