import AppKit
import CordisValue
import WebKit

// thin-host: feature-specific, migrate to plugin: the dialog copy ("<host> says", permission and
// sign-in wording) and the remember-per-site policy belong to a prompts plugin; the host keeps the
// WKUIDelegate plumbing and the generic dialog node.
/// Dialogs a web page asks for, drawn by the host in den's dialog style (spec §5: 450 wide, keycaps,
/// #3139FB default button) over the window that shows the page: JavaScript alert / confirm /
/// prompt, HTTP sign-in, and camera / microphone permission. Plugins are not involved.
///
/// - Nothing blocks: each request keeps WebKit's completion handler and calls it when a button is
///   pressed (or with the cancel answer when the page's web view goes away).
/// - One dialog at a time; later requests wait in order.
/// - Camera and microphone answers are remembered per origin and device until den quits.
/// - Credentials typed into the sign-in dialog go straight to WebKit (`URLCredential`,
///   `.forSession`); they are never logged or stored by den.
@MainActor
public final class WebPrompts {
  public struct Request {
    public let tree: Value
    weak var webView: WKWebView?
    let answer: (_ button: String, _ fields: [String: String]) -> Void
    let cancel: () -> Void
  }

  /// Where a dialog for `webView` goes: the main window's overlay layer, or a Little Arc panel.
  weak var window: DenWindowController?
  var palette: () -> Palette?
  public private(set) var queue: [Request] = []
  public private(set) var current: Request?
  private var dialog: DialogView?
  private let backdrop = ModalBackdrop(dim: Tokens.dialogBackdropAlpha)
  /// "<origin> <camera|microphone>" -> allowed, for this session.
  public private(set) var mediaDecisions: [String: Bool] = [:]

  init(window: DenWindowController?, palette: @escaping () -> Palette?) {
    self.window = window
    self.palette = palette
  }

  public var visible: Bool { current != nil }

  /// The error page's colors, from the current space's palette (surface, text, accent button).
  var errorPageColors: WebErrorPage.Colors? {
    guard let p = palette() else { return nil }
    return .init(background: WebErrorPage.css(p.popover), text: WebErrorPage.css(p.panelText), secondary: WebErrorPage.css(p.panelSecondaryText),
                 accent: WebErrorPage.css(p.primaryButton), onAccent: "#fff", dark: p.dark)
  }

  // MARK: Requests

  static func says(_ frame: WKFrameInfo?, _ webView: WKWebView) -> String {
    let host = frame?.securityOrigin.host ?? webView.url?.host ?? ""
    return host.isEmpty ? "This page says" : host + " says"
  }

  func alert(_ message: String, frame: WKFrameInfo?, webView: WKWebView, done: @escaping () -> Void) {
    enqueue(["title": .string(Self.says(frame, webView)), "message": .string(message),
             "buttons": [["id": "ok", "title": "OK", "style": "default"]]], webView,
            answer: { _, _ in done() }, cancel: done)
  }

  func confirm(_ message: String, frame: WKFrameInfo?, webView: WKWebView, done: @escaping (Bool) -> Void) {
    enqueue(["title": .string(Self.says(frame, webView)), "message": .string(message),
             "buttons": [["id": "cancel", "title": "Cancel", "style": "cancel"], ["id": "ok", "title": "OK", "style": "default"]]], webView,
            answer: { b, _ in done(b == "ok") }, cancel: { done(false) })
  }

  func prompt(_ message: String, defaultText: String?, frame: WKFrameInfo?, webView: WKWebView, done: @escaping (String?) -> Void) {
    enqueue(["title": .string(Self.says(frame, webView)), "message": .string(message),
             "fields": [["id": "text", "value": .string(defaultText ?? "")]],
             "buttons": [["id": "cancel", "title": "Cancel", "style": "cancel"], ["id": "ok", "title": "OK", "style": "default"]]], webView,
            answer: { b, f in done(b == "ok" ? (f["text"] ?? "") : nil) }, cancel: { done(nil) })
  }

  /// HTTP Basic / Digest / NTLM sign-in. `done(nil)` means Cancel.
  func signIn(_ space: URLProtectionSpace, previousFailures: Int, proposedUser: String?, webView: WKWebView, done: @escaping (URLCredential?) -> Void) {
    let host = space.host
    var message = space.realm.map { "“\($0)” asks for a username and password." } ?? "This site asks for a username and password."
    if previousFailures > 0 { message = "That didn’t work. " + message }
    if !space.receivesCredentialSecurely { message += " Your password will be sent unencrypted." }
    enqueue(["title": .string("Sign in to \(host)"), "message": .string(message), "icon": "sf:lock.fill", "iconStyle": "plain",
             "fields": [["id": "user", "placeholder": "Username", "value": .string(proposedUser ?? "")], ["id": "password", "placeholder": "Password", "secure": true]],
             "buttons": [["id": "cancel", "title": "Cancel", "style": "cancel"], ["id": "signIn", "title": "Sign In", "style": "default"]]], webView,
            answer: { b, f in done(b == "signIn" ? URLCredential(user: f["user"] ?? "", password: f["password"] ?? "", persistence: .forSession) : nil) },
            cancel: { done(nil) })
  }

  /// Camera / microphone. Answered at once when this origin already decided this session.
  func media(_ origin: WKSecurityOrigin, type: WKMediaCaptureType, webView: WKWebView, done: @escaping (WKPermissionDecision) -> Void) {
    let base = "\(origin.protocol)://\(origin.host)\(origin.port > 0 ? ":\(origin.port)" : "")"
    let devices: [String]
    switch type {
    case .camera: devices = ["camera"]
    case .microphone: devices = ["microphone"]
    default: devices = ["camera", "microphone"]
    }
    let known = devices.map { mediaDecisions[base + " " + $0] }
    if known.allSatisfy({ $0 == true }) { return done(.grant) }
    if known.contains(false) { return done(.deny) }
    enqueue(Self.mediaTree(host: origin.host, devices: devices), webView,
            answer: { [weak self] b, _ in
              let ok = b == "allow"
              for d in devices { self?.mediaDecisions[base + " " + d] = ok }
              done(ok ? .grant : .deny)
            },
            cancel: { done(.deny) })
  }

  static func mediaTree(host: String, devices: [String]) -> Value {
    let what = devices.count == 2 ? "camera and microphone" : devices.first ?? "camera"
    return ["title": .string("Allow \(host) to use your \(what)?"),
            "message": "den remembers your answer for this site until you quit.",
            "icon": .string(devices == ["microphone"] ? "sf:mic.fill" : "sf:video.fill"), "iconStyle": "accent",
            "buttons": [["id": "deny", "title": "Don’t Allow", "style": "cancel"], ["id": "allow", "title": "Allow", "style": "default"]]]
  }

  // MARK: Presentation

  func enqueue(_ tree: Value, _ webView: WKWebView, answer: @escaping (String, [String: String]) -> Void, cancel: @escaping () -> Void) {
    queue.append(Request(tree: tree.with("id", "webPrompt"), webView: webView, answer: answer, cancel: cancel))
    showNext()
  }

  /// Presses a button of the open dialog (the dialog's own buttons and keys, and tests).
  public func press(_ button: String, fields: [String: String] = [:]) {
    guard let r = current else { return }
    current = nil
    hide()
    r.answer(button, fields)
    showNext()
  }

  /// A web view is going away: its pending dialogs get their cancel answers.
  func cancel(for webView: WKWebView) {
    let gone = queue.filter { $0.webView === webView || $0.webView == nil }
    queue.removeAll { $0.webView === webView || $0.webView == nil }
    gone.forEach { $0.cancel() }
    if let c = current, c.webView === webView || c.webView == nil {
      current = nil
      hide()
      c.cancel()
      showNext()
    }
  }

  private func showNext() {
    guard current == nil, !queue.isEmpty else { return }
    let r = queue.removeFirst()
    current = r
    guard let p = palette() else { return }
    let d = DialogView { [weak self] _, action, value in
      guard action == "button" else { return }
      var f: [String: String] = [:]
      if case let .object(pairs) = value["fields"] { for (k, v) in pairs { f[k] = v.string ?? "" } }
      self?.press(value.str("button"), fields: f)
    }
    d.update(r.tree, palette: p)
    dialog = d
    let container: NSView?
    if let w = r.webView?.window, w !== window?.window { container = w.contentView } else { container = window?.overlays }
    guard let container else { return }
    backdrop.frame = container.bounds
    backdrop.autoresizingMask = [.width, .height]
    Elevation.reset(backdrop)
    container.addSubview(backdrop)
    container.addSubview(d)
    layout(in: container)
    ModalFocus.present(d) { [weak d] in d?.focusTarget }
    // Elevation.swift: the blurred page under the dim, and the spring in.
    if let root = container.window?.contentView { backdrop.captureBlur(root: root, hiding: container === window?.overlays ? [container] : [backdrop, d]) }
    Elevation.animateIn(d, backdrop: backdrop)
  }

  private func layout(in container: NSView) {
    guard let d = dialog else { return }
    let b = container.bounds, w = min(Tokens.dialogWidth, b.width - 40), h = d.contentHeight
    // Overlays are flipped; a Little Arc content view may not be.
    let y = container.isFlipped ? ((b.height - h) / 2 - 20) : ((b.height - h) / 2 + 20)
    d.frame = NSRect(x: ((b.width - w) / 2).rounded(), y: y.rounded(), width: w, height: h)
    d.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
  }

  private func hide() {
    guard let d = dialog else { return backdrop.removeFromSuperview() }
    dialog = nil
    ModalFocus.dismiss(d)
    // The next queued dialog reuses the backdrop at once; otherwise both fade out.
    Elevation.animateOut(d, backdrop: queue.isEmpty ? backdrop : nil) { [weak self] in
      d.removeFromSuperview()
      guard let self, self.dialog == nil else { return }
      self.backdrop.removeFromSuperview()
      Elevation.reset(self.backdrop)
    }
  }
}
