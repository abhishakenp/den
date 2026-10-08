import AppKit
import CordisValue
import WebKit
import UniformTypeIdentifiers

/// `pdf` service: detects PDFs loaded in WKWebView, provides a toolbar overlay for page
/// navigation, zoom, search, and print, and handles PDF file drag-drop/upload.
///
/// Methods:
///   isPdf {url}                -> {isPdf: bool}          check if a URL points to a PDF
///   showToolbar {id}           -> {visible: bool}         show the PDF toolbar for a web view
///   hideToolbar {id}           -> {visible: bool}         hide the PDF toolbar
///   navigate {id, page}        -> {page: int}             go to a specific page
///   zoomIn {id}  / zoomOut {id} / zoomReset {id}         zoom controls
///   print {id}                                          trigger print for the PDF
///   search {id, query}         -> {matches: int, index: int}  find text in PDF pages
///   close {id}                                          close the PDF toolbar
/// Events: pdf.pageChange {id, page, totalPages}
///         pdf.zoom {id, zoom}
///         pdf.search {id, matches, index, query}
@MainActor
public final class PDFService: HostService {
  public let name = "pdf"
  private let host: ServiceHost
  private let windows: WindowSet
  private weak var webviews: WebViewsService?
  private var pageActions: PageActions?
  /// The visible toolbar overlay per web view id.
  private var toolbars: [String: PDFToolbarView] = [:]

  init(host: ServiceHost, windows: WindowSet) {
    self.host = host
    self.windows = windows
  }

  public func handle(method: String, args: Value) -> Value {
    let id = args.str("id")
    guard !id.isEmpty else {
      switch method {
      case "isPdf": return isPdfCheck(args)
      default: return .error("pdf: missing id")
      }
    }
    switch method {
    case "isPdf": return isPdfCheck(args)
    case "showToolbar": return showToolbar(id)
    case "hideToolbar": return hideToolbar(id)
    case "navigate": return navigate(id, args["page"].double.map { Int64($0) })
    case "zoomIn": return zoomIn(id)
    case "zoomOut": return zoomOut(id)
    case "zoomReset": return zoomReset(id)
    case "print": return pdfPrint(id)
    case "search": return search(id, args.str("query"))
    case "close": return hideToolbar(id)
    default: return .error("pdf: unknown method '\(method)'")
    }
  }

  // MARK: PDF Detection

  /// Check if the given URL points to a PDF.
  private func isPdfCheck(_ args: Value) -> Value {
    let urlString = args.str("url")
    let isPdf = Self.isPdfUrl(urlString)
    return ["isPdf": .bool(isPdf)]
  }

  /// Determine if a URL points to a PDF by extension, path pattern, or query hint.
  public static func isPdfUrl(_ url: String) -> Bool {
    let lower = url.lowercased()
    // Direct extension check
    if lower.hasSuffix(".pdf") || lower.hasSuffix(".pdf?") { return true }
    // Query parameter hint (e.g. ?download&format=pdf)
    if lower.contains("format=pdf") || lower.contains("content-type=application/pdf") { return true }
    return false
  }

  /// Check if a MIME type indicates a PDF.
  public static func isPdfMime(_ mime: String?) -> Bool {
    guard let mime else { return false }
    return mime.lowercased() == "application/pdf"
  }

  /// Configure a WKWebViewConfiguration for optimal PDF rendering.
  /// WKWebView has built-in PDF viewing; we tune the configuration for best results.
  public static func configureForPdf(_ config: WKWebViewConfiguration) {
    // Allow element fullscreen for PDF annotations.
    config.preferences.isElementFullscreenEnabled = true
    // JavaScript is enabled by default in WKWebView; WKWebView's PDF viewer uses it
    // for page navigation and annotation support.
    config.preferences.javaScriptCanOpenWindowsAutomatically = true
  }

  // MARK: Toolbar Overlay

  public func showToolbar(_ id: String) -> Value {
    guard let wv = webviews?.record(id)?.webView else {
      return ["visible": false]
    }
    if toolbars[id] != nil { return ["visible": true] }
    let toolbar = PDFToolbarView()
    toolbar.onSearch = { [weak self] query in
      guard let self, let pa = self.pageActions, let r = self.webviews?.record(id) else { return }
      self.searchPage(pa, r, query)
    }
    toolbar.onClose = { [weak self] in self?.hideToolbar(id) }
    if let palette = pageActions?.palette() { toolbar.apply(palette) }
    toolbars[id] = toolbar
    // Find the overlays view from the active window
    let wc = windows.active
    wc.overlays.addSubview(toolbar)
    layoutToolbar(toolbar)
    // Inject PDF page detection script
    injectPdfScripts(wv, id: id)
    return ["visible": true]
  }

  private func hideToolbar(_ id: String) -> Value {
    guard let tb = toolbars[id] else { return ["visible": false] }
    tb.removeFromSuperview()
    toolbars[id] = nil
    return ["visible": false]
  }

  private func layoutToolbar(_ toolbar: PDFToolbarView) {
    let w = toolbar.superview!
    let width: CGFloat = 380
    let height: CGFloat = 36
    let inset: CGFloat = 12
    toolbar.frame = NSRect(x: w.bounds.width - width - inset,
                           y: w.bounds.height - height - inset,
                           width: width, height: height)
    toolbar.alphaValue = 0
    toolbar.animator().alphaValue = 1
  }

  private func navigate(_ id: String, _ page: Int64?) -> Value {
    guard let r = webviews?.record(id) else { return .error("pdf: no webview '\(id)'") }
    guard let page else { return .error("pdf: page number required") }
    guard let w = r.webView else { return .error("pdf: webview not loaded") }
    let fragment = "page=\(page)"
    w.evaluateJavaScript("window.location.hash='\(fragment)'") { _, _ in }
    return ["page": .int(page)]
  }

  // MARK: Zoom

  private func zoomIn(_ id: String) -> Value {
    guard let r = webviews?.record(id) else { return .error("pdf: no webview '\(id)'") }
    guard let w = r.webView else { return .error("pdf: webview not loaded") }
    let steps = Tokens.zoomSteps
    let cur = Double(w.pageZoom)
    let z = steps.first { $0 > cur + 0.001 } ?? steps.last!
    w.pageZoom = CGFloat(z)
    host.emit("pdf.zoom", ["id": .string(id), "zoom": .double(z)])
    return ["zoom": .double(z)]
  }

  private func zoomOut(_ id: String) -> Value {
    guard let r = webviews?.record(id) else { return .error("pdf: no webview '\(id)'") }
    guard let w = r.webView else { return .error("pdf: webview not loaded") }
    let steps = Tokens.zoomSteps
    let cur = Double(w.pageZoom)
    let z = steps.last { $0 < cur - 0.001 } ?? steps.first!
    w.pageZoom = CGFloat(z)
    host.emit("pdf.zoom", ["id": .string(id), "zoom": .double(z)])
    return ["zoom": .double(z)]
  }

  private func zoomReset(_ id: String) -> Value {
    guard let r = webviews?.record(id) else { return .error("pdf: no webview '\(id)'") }
    guard let w = r.webView else { return .error("pdf: webview not loaded") }
    w.pageZoom = 1.0
    host.emit("pdf.zoom", ["id": .string(id), "zoom": .double(1.0)])
    return ["zoom": .double(1.0)]
  }

  // MARK: Print

  private func pdfPrint(_ id: String) -> Value {
    guard let r = webviews?.record(id) else { return .error("pdf: no webview '\(id)'") }
    guard let w = r.webView, let win = w.window else { return .error("pdf: webview not on screen") }
    let op = w.printOperation(with: NSPrintInfo.shared)
    op.view?.frame = w.bounds
    op.runModal(for: win, delegate: nil, didRun: nil, contextInfo: nil)
    return .ok
  }

  // MARK: Search

  private func search(_ id: String, _ query: String) -> Value {
    guard let pa = pageActions, let r = webviews?.record(id) else {
      return ["matches": .int(0), "index": .int(0)]
    }
    searchPage(pa, r, query)
    return pa.state
  }

  private func searchPage(_ pa: PageActions, _ r: WebRecord, _ query: String) {
    pa.find(r, "show", query: query.isEmpty ? nil : query)
    if !query.isEmpty { pa.setQuery(query, in: r) }
  }

  // MARK: PDF Scripts

  /// Inject JavaScript to detect PDF page information and enable page navigation.
  private func injectPdfScripts(_ webView: WKWebView, id: String) {
    let script = """
      (function() {
        var __denPdf = window.__denPdf || {pages: 0, currentPage: 0, loaded: false};
        if (__denPdf.loaded) return;

        // Check if this is a PDF (WKWebView shows PDFs in an iframe)
        var isPdf = false;
        if (document.querySelector('embed[type="application/pdf"]') ||
            document.querySelector('object[type="application/pdf"]') ||
            document.title.toLowerCase().endsWith('.pdf') ||
            location.href.toLowerCase().endsWith('.pdf')) {
          isPdf = true;
        }

        if (isPdf) {
          __denPdf.loaded = true;
          __denPdf.isPdf = true;

          // For WKWebView built-in PDF viewer, try to detect page count
          try {
            var embed = document.querySelector('embed');
            if (embed && embed.getPDFPageCount) {
              __denPdf.pages = embed.getPDFPageCount();
            }
            if (embed && typeof embed.currentPageNumber === 'number') {
              __denPdf.currentPage = embed.currentPageNumber;
            }
          } catch(e) {}

          // For PDF.js: read window.pdfViewer or window.PDFViewerApplication
          try {
            if (window.PDFViewerApplication) {
              __denPdf.pages = window.pdfViewer.pagesCount;
              __denPdf.currentPage = window.pdfViewer.currentPageNumber;
            }
          } catch(e) {}

          // Report page info back to host
          window.webkit.messageHandlers.den.postMessage({
            k: 's',
            pdf: {pages: __denPdf.pages, current: __denPdf.currentPage}
          });
        }
        window.__denPdf = __denPdf;
      })();
      """
    webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { _ in }
  }

  // MARK: PDF Loading

  /// Load a PDF URL in a web view, configuring it properly first.
  func loadPdf(_ url: URL, in webView: DenWebView, record: WebRecord) {
    PDFService.configureForPdf(webView.configuration)
    webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
  }

  /// Configure `hooks`: called by `DenRuntime` to wire up dependencies.
  public func configure(webviews: WebViewsService, pageActions: PageActions) {
    self.webviews = webviews
    self.pageActions = pageActions
  }
}

// MARK: - Page number parsing for URL fragments

extension String? {
  /// Extract page number from a URL fragment like "page=5" or "pages=5".
  var pageValue: Int64 {
    guard let self else { return 1 }
    let comps = URLComponents(string: self)
    return comps?.queryItems?.first(where: { $0.name == "page" || $0.name == "pages" })?.value.flatMap { Int64($0) } ?? 1
  }
}

// MARK: - PDF Toolbar View

/// A floating toolbar for PDF viewing: zoom, print, search, close.
@MainActor
final class PDFToolbarView: FlippedView, Themable {
  var onSearch: ((String) -> Void)?
  var onClose: (() -> Void)?

  private let radius: CGFloat = 10
  private let surface = FlippedView()
  private let searchField = NSTextField()
  private let pageField = NSTextField()
  private let prevButton = IconButton(symbol: "chevron.left", size: 22) {}
  private let nextButton = IconButton(symbol: "chevron.right", size: 22) {}
  private let zoomOutButton = IconButton(symbol: "minus", size: 22) {}
  private let zoomInButton = IconButton(symbol: "plus", size: 22) {}
  private let zoomResetButton = IconButton(symbol: "arrow.uturn.forward", size: 20) {}
  private let printButton = IconButton(symbol: "printer", size: 22) {}
  private lazy var closeButton = IconButton(symbol: "xmark", size: 22) { [weak self] in self?.onClose?() }

  private var fill = NSColor.white
  private var border = NSColor.clear
  private var pageText = ""

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    surface.wantsLayer = true
    surface.layer?.cornerRadius = radius
    surface.layer?.cornerCurve = .continuous
    addSubview(surface)

    // Search field
    searchField.isBordered = false
    searchField.drawsBackground = false
    searchField.focusRingType = .none
    searchField.font = .systemFont(ofSize: 12)
    searchField.placeholderString = "Search PDF…"
    searchField.delegate = self
    searchField.wantsLayer = true

    // Page counter
    pageField.isBordered = false
    pageField.drawsBackground = false
    pageField.focusRingType = .none
    pageField.font = .systemFont(ofSize: 12, weight: .medium)
    pageField.textColor = .labelColor

    // Buttons setup
    [prevButton, nextButton, zoomOutButton, zoomInButton, zoomResetButton, printButton, closeButton].forEach {
      $0.setTip("", fallback: "")
      $0.tint = .labelColor.withAlphaComponent(0.7)
      $0.hoverFill = NSColor(white: 0, alpha: 0.06)
    }

    [searchField, pageField, prevButton, nextButton, zoomOutButton, zoomInButton, zoomResetButton, printButton, closeButton].forEach {
      surface.addSubview($0)
    }
  }

  required init?(coder: NSCoder) { fatalError() }
  override var mouseDownCanMoveWindow: Bool { false }

  func apply(_ p: Palette) {
    fill = p.surface
    border = p.hairline
    surface.layer?.backgroundColor = fill.cgColor
    surface.layer?.borderWidth = 0.5
    surface.layer?.borderColor = border.cgColor
    searchField.textColor = p.textPrimary
    searchField.placeholderAttributedString = NSAttributedString(
      string: "Search PDF…",
      attributes: [.foregroundColor: p.textTertiary, .font: NSFont.systemFont(ofSize: 12)]
    )
    pageField.textColor = p.textPrimary
    for b in [prevButton, nextButton, zoomOutButton, zoomInButton, zoomResetButton, printButton, closeButton] {
      b.apply(p)
      b.tint = p.text.withAlphaComponent(0.7)
      b.hoverFill = p.hoverFill
    }
  }

  override func layout() {
    super.layout()
    let h = bounds.height
    let w = bounds.width
    let inset: CGFloat = 6
    let fieldH: CGFloat = 22

    // Search field takes up space on the left
    searchField.frame = NSRect(x: inset, y: (h - fieldH) / 2, width: 140, height: fieldH)

    // Page counter in center
    pageField.frame = NSRect(x: w / 2 - 40, y: (h - 16) / 2, width: 80, height: 16)

    // Right group: prev, next, zoom controls, print, close
    var right = w - inset - 22
    for b in [closeButton, printButton, zoomResetButton, zoomInButton, zoomOutButton, nextButton, prevButton] {
      b.frame = NSRect(x: right - 22, y: (h - 22) / 2, width: 22, height: 22)
      right -= 26
    }
  }

  func updatePageInfo(current: Int64, total: Int64) {
    pageText = total > 0 ? "\(current) / \(total)" : "Page"
    pageField.stringValue = pageText
    needsLayout = true
  }

  func setQuery(_ q: String) {
    searchField.stringValue = q
  }
}

extension PDFToolbarView: NSTextFieldDelegate {
  func controlTextDidChange(_ obj: Notification) {
    onSearch?(searchField.stringValue)
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.cancelOperation(_:)):
      onClose?()
      return true
    default:
      return false
    }
  }
}