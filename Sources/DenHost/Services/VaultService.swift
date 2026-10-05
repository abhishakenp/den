import AppKit
import CordisValue
@preconcurrency import LocalAuthentication
import Security
import WebKit

/// `vault` service: den's own password vault (Keychain, Touch ID). The host holds every secret;
/// plugins (the `passwords` plugin) only see origins and usernames and drive the UI.
///
///   enable                        -> ok. Installs the form listener in web views created from now on
///   status                        -> {enabled, mode, unlocked}
///   accounts {origin?}            -> [{id, origin, username, created}]. Without `origin`, only while unlocked
///   save {capture}                -> ok. Stores a captured login (Keychain), then drops the capture
///   dismiss {capture}             -> ok. Drops it
///   fill {webview, account, request?}  -> {request}. Touch ID, then fills the focused form. `vault.result`
///   generate {webview, request?}  -> {request}. Fills a strong password into the focused sign-up form
///   unlock {reason?, request?}    -> {request}. Touch ID; the full list is readable for 5 min (or `lock`)
///   lock                          -> ok
///   copy {account, request?}      -> {request}. Touch ID, then the password on the pasteboard (cleared after 60 s)
///   delete {account}              -> ok, while unlocked
///   suggest {webview, items: [{id, title, subtitle?, icon?}]}  -> ok. A small list under the focused field; [] hides
///
/// Events (never carrying a password):
///   vault.focus {webview, origin, field: username|password, signup, accounts: [{id, username}]}
///   vault.blur {webview}
///   vault.captured {capture, webview, origin, username, exists}
///   vault.suggestion {webview, item}
///   vault.result {request, method, ok, error?}
///
/// Security rules (all enforced here, not in plugins):
/// - Origins come from `WKFrameInfo.securityOrigin`, never from the page.
/// - Only secure origins (https, or http on loopback for local testing). Plain http is ignored.
/// - A frame whose origin differs from its top page's (a cross-origin iframe) is ignored.
/// - A fill targets the frame that reported the focus, checks inside the page that the frame's
///   origin is still the account's origin, and runs in the isolated `den-vault` world.
/// - Captures live in memory for 5 min at most. Nothing is logged.
@MainActor
public final class VaultService: HostService {
  public let name = "vault"
  let host: ServiceHost
  let webviews: WebViewsService
  public var store: VaultStore
  public var auth: VaultAuth
  public private(set) var enabled = false
  var unlockedUntil: Date = .distantPast
  public var clock: () -> Date = Date.init
  /// Where `copy` puts a password, and how long it stays: cleared after this many seconds unless
  /// something else was copied since (the pasteboard's change count moved). Tests use their own.
  public var pasteboard: NSPasteboard = .general
  public var clipboardClearSeconds: TimeInterval = 60

  // thin-host: feature-specific, migrate to plugin (the save-a-login flow (captures, save/dismiss) belongs in the passwords plugin; the host keeps a generic secret store)
  struct Capture {
    var origin: String
    var username: String
    var password: Data
    var webview: String
    var at: Date
  }
  var captures: [String: Capture] = [:]
  var nextCapture = 1
  var nextRequest = 1
  /// Per web view: the frame and origin of the last focused login field.
  var focused: [String: (frame: WKFrameInfo, origin: String)] = [:]
  var suggestions: [String: VaultSuggestionView] = [:]
  private lazy var handler = ScriptMessageProxy { [weak self] msg in self?.didReceive(msg) }
  static let world = WKContentWorld.world(name: "den-vault")

  public init(host: ServiceHost, webviews: WebViewsService, store: VaultStore? = nil, auth: VaultAuth? = nil) {
    self.host = host
    self.webviews = webviews
    self.store = store ?? SystemKeychain()
    self.auth = auth ?? SystemAuth()
  }

  var unlocked: Bool { clock() < unlockedUntil }

  public func handle(method: String, args: Value) -> Value {
    switch method {
    case "enable":
      enable()
      return .ok
    case "status":
      return ["enabled": .bool(enabled), "mode": .string(store.mode), "unlocked": .bool(unlocked)]
    case "accounts":
      // `webview`: the logins for the origin that page shows now (den derives it, not the plugin).
      if !args.str("webview").isEmpty {
        let r = webviews.record(args.str("webview"))
        let origin = Self.origin(of: r?.webView?.url ?? r.flatMap { URL(string: $0.url) })
        guard !origin.isEmpty else { return .array([]) }
        return .array(store.accounts().filter { $0.origin == origin }.map { a in ["id": .string(a.id), "origin": .string(a.origin), "username": .string(a.username)] })
      }
      let origin = args.str("origin")
      guard !origin.isEmpty || unlocked else { return .error("vault: locked") }
      return .array(store.accounts().filter { origin.isEmpty || $0.origin == origin }.map(Self.value))
    case "save":
      let id = args.str("capture")
      guard let c = captures.removeValue(forKey: id), clock().timeIntervalSince(c.at) < 300 else { return .error("vault: no capture '\(id)'") }
      let s = store.save(origin: c.origin, username: c.username, password: c.password)
      return s == errSecSuccess ? .ok : .error("vault: keychain error \(s)")
    case "dismiss":
      captures[args.str("capture")] = nil
      return .ok
    case "focusLogin":
      // Focuses the page's sign-in field (password, else username); the listener then reports
      // `vault.focus` and the suggestions open under it, as if the user had clicked the field.
      guard let w = webviews.record(args.str("webview"))?.webView else { return .error("vault: no live web view") }
      w.window?.makeFirstResponder(w)
      w.callAsyncJavaScript(Self.focusScript, arguments: [:], in: nil, in: Self.world) { _ in }
      return .ok
    case "fill": return fill(args)
    case "generate": return generate(args)
    // thin-host: feature-specific, migrate to plugin (unlock window (5 min) and prompt strings are passwords policy)
    case "unlock":
      let request = requestId(args)
      auth.authenticate(reason: args.str("reason", "show your saved passwords")) { [weak self] ok, _ in
        guard let self else { return }
        if ok { self.unlockedUntil = self.clock().addingTimeInterval(300) }
        self.result(request, "unlock", ok, ok ? nil : self.refusal)
      }
      return ["request": .string(request)]
    case "lock":
      unlockedUntil = .distantPast
      return .ok
    case "copy": return copy(args)
    case "delete":
      guard unlocked else { return .error("vault: locked") }
      guard let a = account(args.str("account")) else { return .error("vault: no account") }
      return store.delete(a) ? .ok : .error("vault: delete failed")
    case "suggest":
      suggest(args.str("webview"), args.list("items"))
      return .ok
    default:
      return .error("vault: unknown method '\(method)'")
    }
  }

  static func value(_ a: VaultAccount) -> Value {
    ["id": .string(a.id), "origin": .string(a.origin), "username": .string(a.username), "created": .double(a.created)]
  }

  func account(_ id: String) -> VaultAccount? { store.accounts().first { $0.id == id } }

  func requestId(_ args: Value) -> String {
    let r = args.str("request")
    if !r.isEmpty { return r }
    defer { nextRequest += 1 }
    return "vault-\(nextRequest)"
  }

  /// "cancelled" when the user (or den) cancelled Touch ID; otherwise the LAError, e.g.
  /// "auth biometryNotAvailable (-6)".
  var refusal: String { auth.failure.map { "auth " + $0 } ?? "cancelled" }
  var keychainError: String { "keychain " + String((store as? SystemKeychain)?.lastReadStatus ?? errSecItemNotFound) }

  func result(_ request: String, _ method: String, _ ok: Bool, _ error: String?) {
    var v: Value = ["request": .string(request), "method": .string(method), "ok": .bool(ok)]
    if let error { v = v.with("error", .string(error)) }
    host.emit("vault.result", v)
  }

  // MARK: Web views

  func enable() {
    guard !enabled else { return }
    enabled = true
    webviews.configureHooks.append { [weak self] _, config in
      guard let self else { return }
      config.userContentController.add(self.handler, contentWorld: Self.world, name: "denVault")
      config.userContentController.addUserScript(WKUserScript(source: Self.formScript, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Self.world))
    }
    webviews.navigatingHooks.append { [weak self] r, _, _ in self?.suggest(r.id, []) }
    host.on("webviews.closed") { [weak self] v in
      self?.focused[v.str("id")] = nil
      self?.suggest(v.str("id"), [])
    }
  }

  /// "https://example.com", "http://127.0.0.1:8080"; "" for anything den won't save or fill.
  nonisolated static func origin(_ o: WKSecurityOrigin) -> String {
    origin(scheme: o.protocol, host: o.host, port: o.port)
  }

  nonisolated static func origin(scheme: String, host: String, port: Int) -> String {
    let s = scheme.lowercased(), h = host.lowercased()
    guard !h.isEmpty else { return "" }
    let loopback = h == "127.0.0.1" || h == "localhost" || h == "::1"
    guard s == "https" || (s == "http" && loopback) else { return "" }
    let defaultPort = s == "https" ? 443 : 80
    return "\(s)://\(h)" + (port == 0 || port == defaultPort ? "" : ":\(port)")
  }

  nonisolated static func origin(of url: URL?) -> String {
    guard let url, let s = url.scheme, let h = url.host else { return "" }
    return origin(scheme: s, host: h, port: url.port ?? 0)
  }

  func didReceive(_ msg: WKScriptMessage) {
    guard let w = msg.webView, let r = webviews.recordFor(w), let body = msg.body as? [String: Any], let type = body["type"] as? String else { return }
    let origin = Self.origin(msg.frameInfo.securityOrigin)
    // Secure origins only, and never a frame from another origin than its top page.
    guard !origin.isEmpty, msg.frameInfo.isMainFrame || origin == Self.origin(of: w.url) else { return }
    switch type {
    case "focus":
      focused[r.id] = (msg.frameInfo, origin)
      var rect = (body["rect"] as? [Double]) ?? []
      if !msg.frameInfo.isMainFrame { rect = [] }  // frame-relative; the list then sits at the top
      anchors[r.id] = rect.count == 4 ? NSRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]) : nil
      let accounts = store.accounts().filter { $0.origin == origin }.map { a -> Value in ["id": .string(a.id), "username": .string(a.username)] }
      host.emit("vault.focus", [
        "webview": .string(r.id), "origin": .string(origin), "field": .string(body["field"] as? String ?? "password"),
        "signup": .bool(body["signup"] as? Bool ?? false), "accounts": .array(accounts),
      ])
    case "blur":
      host.emit("vault.blur", ["webview": .string(r.id)])
    case "submit":
      guard let pw = body["password"] as? String, !pw.isEmpty, pw.utf8.count <= 1024 else { return }
      let user = String((body["username"] as? String ?? "").prefix(256))
      let id = "capture-\(nextCapture)"
      nextCapture += 1
      captures = captures.filter { clock().timeIntervalSince($0.value.at) < 300 }
      // One pending capture per web view: a second submit replaces the first.
      captures = captures.filter { $0.value.webview != r.id }
      captures[id] = Capture(origin: origin, username: user, password: Data(pw.utf8), webview: r.id, at: clock())
      let exists = store.accounts().contains { $0.origin == origin && $0.username == user }
      host.emit("vault.captured", ["capture": .string(id), "webview": .string(r.id), "origin": .string(origin), "username": .string(user), "exists": .bool(exists)])
    default: break
    }
  }

  var anchors: [String: NSRect?] = [:]

  // MARK: Fill and generate

  func fill(_ args: Value) -> Value {
    let id = args.str("webview"), request = requestId(args)
    guard let a = account(args.str("account")) else { return .error("vault: no account") }
    guard let f = focused[id], f.origin == a.origin, let w = webviews.record(id)?.webView else { return .error("vault: no login field for \(a.origin) is focused") }
    auth.authenticate(reason: "fill your password for \(URL(string: a.origin)?.host ?? a.origin)") { [weak self] ok, ctx in
      guard let self else { return }
      guard ok else { return self.result(request, "fill", false, self.refusal) }
      guard let data = self.store.password(for: a, context: ctx) else { return self.result(request, "fill", false, self.keychainError) }
      self.inject(w, f.frame, origin: a.origin, username: a.username, password: String(decoding: data, as: UTF8.self), all: false, request: request, method: "fill")
    }
    return ["request": .string(request)]
  }

  func generate(_ args: Value) -> Value {
    let id = args.str("webview"), request = requestId(args)
    guard let f = focused[id], let w = webviews.record(id)?.webView else { return .error("vault: no field is focused") }
    inject(w, f.frame, origin: f.origin, username: "", password: Self.strongPassword(), all: true, request: request, method: "generate")
    return ["request": .string(request)]
  }

  func inject(_ w: WKWebView, _ frame: WKFrameInfo, origin: String, username: String, password: String, all: Bool, request: String, method: String) {
    w.callAsyncJavaScript(Self.fillScript, arguments: ["o": origin, "u": username, "p": password, "all": all], in: frame, in: Self.world) { [weak self] r in
      MainActor.assumeIsolated {
        let v = (try? r.get()) as? String
        self?.result(request, method, v == "ok", v == "ok" ? nil : (v ?? "failed"))
      }
    }
    suggest(webviews.recordFor(w)?.id ?? "", [])
  }

  /// Safari-style: three groups of six from an unambiguous alphabet, with an uppercase letter and
  /// a digit, e.g. "hwkcaq-9dMsbu-tebqyx" (~71 bits). SecRandomCopyBytes.
  // thin-host: feature-specific, migrate to plugin (password generation format is passwords policy)
  nonisolated static func strongPassword() -> String {
    let lower = Array("abcdefghijkmnopqrstuvwxyz"), upper = Array("ABCDEFGHJKLMNPQRSTUVWXYZ"), digits = Array("23456789")
    func rnd(_ n: Int) -> Int {
      var x: UInt32 = 0
      _ = SecRandomCopyBytes(kSecRandomDefault, 4, &x)
      return Int(x % UInt32(n))
    }
    var chars = (0..<18).map { _ in lower[rnd(lower.count)] }
    let u = rnd(18)
    var d = rnd(18)
    while d == u { d = rnd(18) }
    chars[u] = upper[rnd(upper.count)]
    chars[d] = digits[rnd(digits.count)]
    return String(chars[0..<6]) + "-" + String(chars[6..<12]) + "-" + String(chars[12..<18])
  }

  // thin-host: feature-specific, migrate to plugin (60 s pasteboard clearing is passwords policy)
  func copy(_ args: Value) -> Value {
    let request = requestId(args)
    guard let a = account(args.str("account")) else { return .error("vault: no account") }
    auth.authenticate(reason: "copy your password for \(URL(string: a.origin)?.host ?? a.origin)") { [weak self] ok, ctx in
      guard let self else { return }
      guard ok, let data = self.store.password(for: a, context: ctx) else { return self.result(request, "copy", false, ok ? self.keychainError : self.refusal) }
      Self.copyConcealed(String(decoding: data, as: UTF8.self), to: self.pasteboard, clearAfter: self.clipboardClearSeconds)
      self.result(request, "copy", true, nil)
    }
    return ["request": .string(request)]
  }

  /// Puts a secret on `pb`, marked concealed (clipboard managers that honor
  /// `org.nspasteboard.ConcealedType` don't record it), and clears it after `seconds`, but only if
  /// the pasteboard still holds it: anything copied since is left alone.
  static func copyConcealed(_ secret: String, to pb: NSPasteboard, clearAfter seconds: TimeInterval) {
    pb.clearContents()
    pb.setString(secret, forType: .string)
    pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    let count = pb.changeCount
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(seconds))
      if pb.changeCount == count { pb.clearContents() }
    }
  }

  // MARK: Suggestions

  // thin-host: feature-specific, migrate to plugin (should be a generic anchored-popup ui node)
  func suggest(_ id: String, _ items: [Value]) {
    guard !items.isEmpty, let w = webviews.record(id)?.webView, let parent = w.superview else {
      suggestions.removeValue(forKey: id)?.removeFromSuperview()
      return
    }
    let v = suggestions[id] ?? VaultSuggestionView { [weak self] item in
      self?.host.emit("vault.suggestion", ["webview": .string(id), "item": .string(item)])
    }
    suggestions[id] = v
    v.update(items)
    // A sibling above the web view (not inside WKWebView's own view tree).
    if v.superview !== parent { parent.addSubview(v, positioned: .above, relativeTo: nil) }
    let size = v.fittingSize
    let anchor = (anchors[id] ?? nil) ?? NSRect(x: 16, y: 8, width: 280, height: 0)
    let width = max(260, min(360, anchor.width))
    var y = anchor.maxY + 4  // page coordinates: top-left origin
    if y + size.height > w.bounds.height { y = max(0, anchor.minY - 4 - size.height) }
    let x = min(max(4, anchor.minX), max(4, w.bounds.width - width - 4))
    let inWeb = NSRect(x: x, y: w.isFlipped ? y : w.bounds.height - y - size.height, width: width, height: size.height)
    v.frame = w.convert(inWeb, to: parent)
  }

  /// Listens in the isolated `den-vault` world, in every frame: focus on a login field, blur, and
  /// submits (form submit, a click on a submit-like button, Enter in a field) with a filled password.
  // thin-host: feature-specific, migrate to plugin (login/sign-up field heuristics are passwords logic; the generic part is observe/fill with origin checks)
  static let formScript = """
    (()=>{const H=webkit.messageHandlers.denVault;const post=m=>{try{H.postMessage(m)}catch(e){}};
    const I=HTMLInputElement;const isPw=e=>e instanceof I&&e.type==='password';
    const textish=e=>e instanceof I&&/^(text|email|tel|)$/.test(e.type);
    const scope=e=>(e&&e.form)||document;const pwds=s=>[...s.querySelectorAll('input[type=password]')];
    const userIn=(s,pw)=>{const all=[...s.querySelectorAll('input')];let i=all.indexOf(pw);if(i<0)i=all.length;
    for(let j=i-1;j>=0;j--){if(textish(all[j])&&all[j].value)return all[j].value}
    const u=s.querySelector('input[autocomplete=username],input[type=email]');return u?u.value:''};
    const signup=s=>{const p=pwds(s);return p.some(x=>x.autocomplete==='new-password')||p.length>=2};
    let last='';const capture=s=>{const p=pwds(s).filter(x=>x.value);if(!p.length)return;
    const pw=(p.find(x=>x.autocomplete==='new-password')||p[0]).value;if(pw===last)return;last=pw;
    post({type:'submit',username:userIn(s,p[0]),password:pw})};
    addEventListener('submit',e=>capture(e.target),true);
    addEventListener('click',e=>{const b=e.target.closest&&e.target.closest('button,input[type=submit],input[type=button],[role=button]');
    if(b){const s=scope(b);if(pwds(s).some(x=>x.value))capture(s)}},true);
    addEventListener('keydown',e=>{if(e.key==='Enter'&&e.target instanceof I){const s=scope(e.target);if(pwds(s).some(x=>x.value))capture(s)}},true);
    addEventListener('focusin',e=>{const t=e.target;if(window.__denVaultFilling)return;if(!(isPw(t)||textish(t)))return;const s=scope(t);
    if(!pwds(s).length&&!(t.type==='email'||/username/.test(t.autocomplete||'')))return;
    if(!isPw(t)&&!/user|mail|login|account|name|phone/i.test((t.autocomplete||'')+' '+t.name+' '+t.id+' '+t.type))return;
    const r=t.getBoundingClientRect();
    post({type:'focus',field:isPw(t)?'password':'username',signup:isPw(t)&&(t.autocomplete==='new-password'||(signup(s)&&t.autocomplete!=='current-password')),rect:[r.left,r.top,r.width,r.height]})},true);
    addEventListener('focusout',e=>{if(isPw(e.target)||textish(e.target))post({type:'blur'})},true);})();
    """

  /// The first visible sign-in field: an empty password field, else a username / email field.
  static let focusScript = """
    const vis = e => !e.disabled && e.offsetParent !== null;
    const f = [...document.querySelectorAll('input[type=password]')].find(vis)
      || [...document.querySelectorAll('input[autocomplete~=username],input[type=email],input[name*=user i],input[name*=login i]')].find(vis);
    if (!f) return 'none';
    if (document.activeElement === f) f.blur();
    f.focus();
    return 'ok';
    """

  /// Arguments o (expected origin), u, p, all (fill every password field: generated passwords).
  static let fillScript = """
    if (location.origin !== o) return 'origin';
    // Filling focuses each field: the focus listener above ignores those (no list popping back up).
    window.__denVaultFilling = true;
    try { return fill(); } finally { window.__denVaultFilling = false; }
    function fill() {
    const d = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
    const set = (el, v) => { el.focus(); d.set.call(el, v); el.dispatchEvent(new Event('input', {bubbles: true})); el.dispatchEvent(new Event('change', {bubbles: true})); };
    const a = document.activeElement;
    const s = (a && a.form) || document;
    const pw = [...s.querySelectorAll('input[type=password]')];
    if (!pw.length) {
      // A username-first sign-in step (Google, Microsoft): only the username field is on the page.
      const f = (a instanceof HTMLInputElement && a.type !== 'password') ? a : s.querySelector('input[autocomplete~=username],input[type=email]');
      if (all || !u || !f) return 'no password field';
      set(f, u);
      return 'ok';
    }
    if (all) { pw.forEach(x => set(x, p)); return 'ok'; }
    if (u) {
      const inputs = [...s.querySelectorAll('input')];
      const before = inputs.slice(0, inputs.indexOf(pw[0])).filter(x => /^(text|email|tel|)$/.test(x.type) && !x.disabled && x.offsetParent !== null);
      const user = before[before.length - 1] || s.querySelector('input[autocomplete=username],input[type=email]');
      if (user) set(user, u);
    }
    set(pw[0], p);
    return 'ok';
    }
    """
}

/// The small list under a focused login field (Arc-style), a sibling above the web view: rounded, menu material, one row per
/// item. Clicking a row reports its id.
@MainActor
// thin-host: feature-specific, migrate to plugin (see suggest())
final class VaultSuggestionView: NSView {
  let onPick: (String) -> Void
  let stack = NSStackView()

  init(onPick: @escaping (String) -> Void) {
    self.onPick = onPick
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 10
    layer?.cornerCurve = .continuous
    layer?.borderWidth = 0.5
    layer?.shadowOpacity = 0.22
    layer?.shadowRadius = 12
    layer?.shadowOffset = CGSize(width: 0, height: -4)
    layer?.masksToBounds = false
    updateColors()
    stack.orientation = .vertical
    stack.spacing = 0
    stack.edgeInsets = NSEdgeInsets(top: 5, left: 5, bottom: 5, right: 5)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }

  /// Opaque: a menu material lets the page's buttons show through.
  func updateColors() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
      layer?.borderColor = NSColor.separatorColor.cgColor
    }
  }

  override func viewDidChangeEffectiveAppearance() { updateColors() }

  func update(_ items: [Value]) {
    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    for item in items {
      let b = SuggestionRow(item) { [weak self] in self?.onPick(item.str("id")) }
      stack.addArrangedSubview(b)
      b.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -10).isActive = true
    }
    layoutSubtreeIfNeeded()
  }
}

@MainActor
final class SuggestionRow: NSView {
  let action: () -> Void
  var hover = false { didSet { layer?.backgroundColor = hover ? NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor : nil; tint() } }
  let title = NSTextField(labelWithString: "")
  let subtitle = NSTextField(labelWithString: "")
  let icon = NSImageView()

  init(_ item: Value, action: @escaping () -> Void) {
    self.action = action
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 6
    title.stringValue = item.str("title")
    title.font = .systemFont(ofSize: 13, weight: .medium)
    subtitle.stringValue = item.str("subtitle")
    subtitle.font = .systemFont(ofSize: 11)
    let symbol = item.str("icon", "sf:key.fill")
    icon.image = NSImage(systemSymbolName: symbol.hasPrefix("sf:") ? String(symbol.dropFirst(3)) : "key.fill", accessibilityDescription: nil)
    let text = NSStackView(views: subtitle.stringValue.isEmpty ? [title] : [title, subtitle])
    text.orientation = .vertical
    text.alignment = .leading
    text.spacing = 1
    let row = NSStackView(views: [icon, text])
    row.spacing = 9
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9), row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -9),
      row.centerYAnchor.constraint(equalTo: centerYAnchor), heightAnchor.constraint(equalToConstant: subtitle.stringValue.isEmpty ? 30 : 40),
      icon.widthAnchor.constraint(equalToConstant: 16),
    ])
    tint()
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
  }

  required init?(coder: NSCoder) { fatalError() }

  func tint() {
    title.textColor = hover ? .white : .labelColor
    subtitle.textColor = hover ? .white.withAlphaComponent(0.85) : .secondaryLabelColor
    icon.contentTintColor = hover ? .white : .secondaryLabelColor
  }

  override func mouseEntered(with event: NSEvent) { hover = true }
  override func mouseExited(with event: NSEvent) { hover = false }
  override func mouseDown(with event: NSEvent) {}
  override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { action() } }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
