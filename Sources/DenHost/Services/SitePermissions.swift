import AppKit
import CordisValue
import CoreLocation
import UserNotifications
import WebKit

// Website permissions beyond the camera and microphone: location and notifications
// (docs/research/apple-integration.md#5-website-permissions). The answers join the camera and
// microphone ones in `sitepolicy.permissions`, which the Shields panel and Settings ▸ Shields show.

// MARK: Location

/// Whether macOS lets den itself use location (den's own Location Services switch).
public enum LocationStatus: Sendable { case allowed, denied, notDetermined }

@MainActor
public protocol LocationAuthorizing: AnyObject {
  var status: LocationStatus { get }
  /// Asks macOS once (its own dialog), then answers.
  func request(_ done: @escaping @MainActor (LocationStatus) -> Void)
}

/// The real one: Core Location, created on the first site that asks.
@MainActor
final class SystemLocation: NSObject, LocationAuthorizing, CLLocationManagerDelegate {
  private lazy var manager: CLLocationManager = {
    let m = CLLocationManager()
    m.delegate = self
    return m
  }()
  private var waiting: [@MainActor (LocationStatus) -> Void] = []

  nonisolated static func map(_ s: CLAuthorizationStatus) -> LocationStatus {
    switch s {
    case .authorizedAlways: .allowed
    case .notDetermined: .notDetermined
    default: .denied
    }
  }

  var status: LocationStatus { Self.map(manager.authorizationStatus) }

  func request(_ done: @escaping @MainActor (LocationStatus) -> Void) {
    let now = status
    guard now == .notDetermined else { return done(now) }
    waiting.append(done)
    manager.requestWhenInUseAuthorization()
  }

  nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
    let s = Self.map(m.authorizationStatus)
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        guard s != .notDetermined else { return }
        let w = self.waiting
        self.waiting = []
        w.forEach { $0(s) }
      }
    }
  }
}

extension WebPrompts {
  /// A site asks for the location. den asks you first (the answer is kept for the site until you
  /// quit, like the camera and microphone), then macOS has to let den use it.
  func location(_ origin: WKSecurityOrigin, webView: WKWebView, system: LocationAuthorizing, done: @escaping @MainActor (WKPermissionDecision) -> Void) {
    location(origin: Self.originString(origin), host: origin.host, webView: webView, system: system, done: done)
  }

  /// The decision itself, by origin string (`https://example.com`), so it can be tested without
  /// WebKit acting on a grant (which would start Core Location in the test process).
  func location(origin: String, host: String, webView: WKWebView, system: LocationAuthorizing, done: @escaping @MainActor (WKPermissionDecision) -> Void) {
    let key = origin + " location"
    let decided: @MainActor (Bool) -> Void = { [weak self, weak webView] ok in
      guard ok else { return done(.deny) }
      switch system.status {
      case .allowed: done(.grant)
      case .denied:
        done(.deny)
        if let webView { self?.locationOff(webView) }
      case .notDetermined:
        system.request { s in
          done(s == .allowed ? .grant : .deny)
          if s == .denied, let webView { self?.locationOff(webView) }
        }
      }
    }
    // Location is off for den in System Settings: no point asking about the site.
    if system.status == .denied {
      done(.deny)
      return locationOff(webView)
    }
    if let known = mediaDecisions[key] { return decided(known) }
    enqueue(Self.locationTree(host: host), webView,
            answer: { [weak self] b, _ in
              let ok = b == "allow"
              self?.remember(key, ok)
              decided(ok)
            },
            cancel: { done(.deny) })
  }

  static func locationTree(host: String) -> Value {
    ["title": .string("Allow \(host) to use your location?"),
     "message": "den remembers your answer for this site until you quit.",
     "icon": "sf:location.fill", "iconStyle": "accent",
     "buttons": [["id": "deny", "title": "Don’t Allow", "style": "cancel"], ["id": "allow", "title": "Allow", "style": "default"]]]
  }

  /// Location Services are off for den: say where to turn them on (once per session).
  func locationOff(_ webView: WKWebView) {
    guard !toldLocationOff else { return }
    toldLocationOff = true
    enqueue(["title": "Location Services are off for den",
             "message": "Websites can’t use your location until den is turned on in System Settings ▸ Privacy & Security ▸ Location Services.",
             "icon": "sf:location.slash.fill", "iconStyle": "plain",
             "buttons": [["id": "later", "title": "Not Now", "style": "cancel"], ["id": "open", "title": "Open Settings", "style": "default"]]], webView,
            answer: { b, _ in
              if b == "open", let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") { NSWorkspace.shared.open(u) }
            },
            cancel: {})
  }

  static func originString(_ o: WKSecurityOrigin) -> String { "\(o.protocol)://\(o.host)\(o.port > 0 ? ":\(o.port)" : "")" }
}

extension WebViewsService {
  /// Location for a page. macOS 26 has no public WKUIDelegate method for it (macOS 27 adds
  /// `requestGeolocationPermissionFor`); this is WebKit's `WKUIDelegatePrivate` one (macOS 12+),
  /// which WebKit calls when the delegate responds to it.
  @objc(_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
  func denRequestGeolocation(_ webView: WKWebView, origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
    guard let prompts else { return decisionHandler(.deny) }
    prompts.location(origin, webView: webView, system: locationAccess) { decisionHandler($0) }
  }

  /// The older variant (frame, yes/no), for a WebKit that only asks this one.
  @objc(_webView:requestGeolocationPermissionForFrame:decisionHandler:)
  func denRequestGeolocationForFrame(_ webView: WKWebView, frame: WKFrameInfo, decisionHandler: @escaping (Bool) -> Void) {
    guard let prompts else { return decisionHandler(false) }
    prompts.location(frame.securityOrigin, webView: webView, system: locationAccess) { decisionHandler($0 == .grant) }
  }
}

// MARK: Notifications

/// Posts notifications to the system (Notification Center).
@MainActor
public protocol Notifying: AnyObject {
  /// Asks macOS once whether den may show notifications.
  func authorize(_ done: @escaping @MainActor (Bool) -> Void)
  func post(id: String, title: String, subtitle: String, body: String, info: [String: String])
  func remove(id: String)
  /// A click on one of den's notifications, with its `info`.
  var onClick: (@MainActor ([String: String]) -> Void)? { get set }
}

/// The real one: `UNUserNotificationCenter`, created on first use (it needs an app bundle).
@MainActor
final class SystemNotifier: NSObject, Notifying, UNUserNotificationCenterDelegate {
  var onClick: (@MainActor ([String: String]) -> Void)?
  private var asked = false
  private lazy var center: UNUserNotificationCenter = {
    let c = UNUserNotificationCenter.current()
    c.delegate = self
    return c
  }()

  func authorize(_ done: @escaping @MainActor (Bool) -> Void) {
    center.requestAuthorization(options: [.alert, .sound]) { ok, _ in DispatchQueue.main.async { MainActor.assumeIsolated { done(ok) } } }
  }

  func post(id: String, title: String, subtitle: String, body: String, info: [String: String]) {
    if !asked {
      asked = true
      authorize { _ in }
    }
    let c = UNMutableNotificationContent()
    c.title = title
    c.subtitle = subtitle
    c.body = body
    c.userInfo = info
    c.sound = .default
    center.add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
  }

  func remove(id: String) {
    center.removeDeliveredNotifications(withIdentifiers: [id])
    center.removePendingNotificationRequests(withIdentifiers: [id])
  }

  // Shown while den is in front too (as Chrome and Safari do).
  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                          withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    completionHandler([.banner, .list, .sound])
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                          withCompletionHandler completionHandler: @escaping () -> Void) {
    var info: [String: String] = [:]
    for (k, v) in response.notification.request.content.userInfo { if let k = k as? String, let v = v as? String { info[k] = v } }
    DispatchQueue.main.async { MainActor.assumeIsolated { self.onClick?(info) } }
    completionHandler()
  }
}

/// `notifications` service: the web's Notification API for open tabs. `WKWebView` has none that
/// works (on macOS 26.5 `Notification.requestPermission()` resolves "denied"; no web push), so a
/// page-world script replaces `Notification` and talks to den, which asks you once per site
/// (remembered), shows each notification in Notification Center, and brings the tab forward when
/// you click one. Only while the tab is open; private windows always get "denied".
///
/// | Method | Args | Returns |
/// |---|---|---|
/// | `permissions` | – | `[{origin, allowed}]` |
/// | `set` | `origin`, `allowed` (`null` forgets) | ok |
/// | `state` | – | `{posted}` |
///
/// Events: `notifications.clicked {webview}` (the `tabs` plugin selects that tab),
/// `notifications.changed`.
@MainActor
public final class PageNotifications: NSObject, HostService, WKScriptMessageHandlerWithReply {
  public let name = "notifications"
  let host: ServiceHost
  let storage: StorageService
  weak var webviews: WebViewsService?
  public var notifier: Notifying {
    didSet { wire() }
  }
  /// origin -> allowed (persisted, storage ns `_notifications`).
  public private(set) var decisions: [String: Bool] = [:]
  private var loaded = false
  public private(set) var posted = 0
  private var nextId = 1
  /// The page-world function that delivers show/click/close to the page's Notification objects.
  let token = "__denNotify" + String(UInt32.random(in: 0...UInt32.max), radix: 36)
  static let handlerName = "denNotify"

  init(host: ServiceHost, storage: StorageService, notifier: Notifying = SystemNotifier()) {
    self.host = host
    self.storage = storage
    self.notifier = notifier
    super.init()
    wire()
  }

  private func wire() {
    notifier.onClick = { [weak self] info in self?.clicked(info) }
  }

  public func handle(method: String, args: Value) -> Value {
    load()
    switch method {
    case "permissions":
      return .array(decisions.keys.sorted().map { ["origin": .string($0), "allowed": .bool(decisions[$0] ?? false)] })
    case "set":
      let o = args.str("origin")
      guard !o.isEmpty else { return .error("notifications: no origin") }
      set(o, args["allowed"].bool)
      return .ok
    case "state": return ["posted": .int(Int64(posted))]
    default: return .error("notifications: unknown method '\(method)'")
    }
  }

  func load() {
    guard !loaded else { return }
    loaded = true
    if case let .object(pairs) = storage.handle(method: "get", args: ["ns": "_notifications", "key": "sites"]) {
      for (k, v) in pairs { if let b = v.bool { decisions[k] = b } }
    }
  }

  func set(_ origin: String, _ allowed: Bool?) {
    load()
    decisions[origin] = allowed
    storage.handle(method: "set", args: ["ns": "_notifications", "key": "sites",
                                         "value": .object(decisions.keys.sorted().map { ($0, .bool(decisions[$0] ?? false)) })])
    host.emit("notifications.changed")
  }

  /// Forgets every answer of a site (Shields' reset, "Forget This Site").
  func forget(host h: String) {
    load()
    for o in decisions.keys where Self.hostOf(o) == h || Self.hostOf(o).hasSuffix("." + h) { set(o, nil) }
  }

  static func hostOf(_ origin: String) -> String { PageStyleService.pageHost(of: URL(string: origin)) }

  /// The script and its handler, for every web page den shows (not extension pages).
  func configure(_ r: WebRecord, _ c: WKWebViewConfiguration) {
    c.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
    c.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: Self.handlerName)
  }

  // MARK: The page's calls

  public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
    load()
    guard let body = message.body as? [String: Any], let kind = body["kind"] as? String, let web = message.webView else { return replyHandler(nil, "bad message") }
    let origin = WebPrompts.originString(message.frameInfo.securityOrigin)
    let record = webviews?.recordFor(web)
    let isPrivate = record?.isPrivate ?? false
    let permission = { () -> String in
      if isPrivate { return "denied" }
      guard let d = self.decisions[origin] else { return "default" }
      return d ? "granted" : "denied"
    }
    switch kind {
    case "state":
      replyHandler(permission(), nil)
    case "request":
      let now = permission()
      guard now == "default", let prompts = webviews?.prompts else { return replyHandler(now, nil) }
      let h = message.frameInfo.securityOrigin.host
      prompts.enqueue(Self.requestTree(host: h), web,
                      answer: { [weak self] b, _ in
                        let ok = b == "allow"
                        self?.set(origin, ok)
                        if ok { self?.notifier.authorize { _ in } }
                        replyHandler(ok ? "granted" : "denied", nil)
                      },
                      cancel: { replyHandler("default", nil) })
    case "show":
      guard permission() == "granted", let id = record?.id else { return replyHandler(false, nil) }
      let n = body["id"] as? Int ?? 0
      let uid = "\(id):\(nextId)"
      nextId += 1
      let tag = body["tag"] as? String ?? ""
      let nid = tag.isEmpty ? uid : "\(id):tag:\(tag)"
      notifier.post(id: nid, title: (body["title"] as? String) ?? "", subtitle: message.frameInfo.securityOrigin.host,
                    body: (body["body"] as? String) ?? "", info: ["webview": id, "page": String(n), "origin": origin])
      posted += 1
      shown[id + ":" + String(n)] = nid
      replyHandler(true, nil)
    case "close":
      let n = body["id"] as? Int ?? 0
      if let id = record?.id, let nid = shown.removeValue(forKey: id + ":" + String(n)) { notifier.remove(id: nid) }
      replyHandler(true, nil)
    default:
      replyHandler(nil, "unknown")
    }
  }

  /// Posted notifications by "<webview>:<page id>", to close them.
  private var shown: [String: String] = [:]

  static func requestTree(host: String) -> Value {
    ["title": .string("Allow \(host) to show notifications?"),
     "message": "They show while the site is open in a tab. den remembers your answer; change it from the shield in the address pill.",
     "icon": "sf:bell.fill", "iconStyle": "accent",
     "buttons": [["id": "deny", "title": "Don’t Allow", "style": "cancel"], ["id": "allow", "title": "Allow", "style": "default"]]]
  }

  /// A click on a notification: den comes forward on that tab, and the page hears `click`.
  func clicked(_ info: [String: String]) {
    guard let id = info["webview"] else { return }
    NSApp.activate()
    host.emit("notifications.clicked", ["webview": .string(id)])
    guard let n = Int(info["page"] ?? ""), let w = webviews?.record(id)?.webView else { return }
    w.callAsyncJavaScript("if (typeof window[t] === 'function') window[t](n, 'click');", arguments: ["t": token, "n": n], in: nil, in: .page) { _ in }
  }

  /// Replaces `Notification` (and its `navigator.permissions` answer) in every frame's page world.
  var script: String {
    """
    (() => {
      const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(Self.handlerName);
      if (!h) return;
      const post = (m) => h.postMessage(m);
      let permission = 'default';
      const live = new Map();
      let next = 0;
      class Notification extends EventTarget {
        constructor(title, options) {
          super();
          if (arguments.length === 0) throw new TypeError("Failed to construct 'Notification': 1 argument required, but only 0 present.");
          const o = options || {};
          this.title = String(title); this.body = o.body == null ? '' : String(o.body); this.tag = o.tag == null ? '' : String(o.tag);
          this.icon = o.icon == null ? '' : String(o.icon); this.data = o.data === undefined ? null : o.data; this.silent = !!o.silent;
          this.requireInteraction = !!o.requireInteraction; this.dir = o.dir || 'auto'; this.lang = o.lang || '';
          this.onclick = null; this.onshow = null; this.onclose = null; this.onerror = null;
          const id = ++next;
          Object.defineProperty(this, '__denId', {value: id});
          live.set(id, this);
          post({kind: 'show', id, title: this.title, body: this.body, tag: this.tag})
            .then((ok) => this.__fire(ok ? 'show' : 'error'), () => this.__fire('error'));
        }
        close() { post({kind: 'close', id: this.__denId}).catch(() => {}); this.__fire('close'); live.delete(this.__denId); }
        __fire(type) {
          const e = new Event(type);
          const f = this['on' + type];
          if (typeof f === 'function') { try { f.call(this, e); } catch (x) { setTimeout(() => { throw x; }); } }
          this.dispatchEvent(e);
        }
        static get permission() { return permission; }
        static requestPermission(callback) {
          return post({kind: 'request'}).then((v) => { permission = v; if (typeof callback === 'function') callback(v); return v; });
        }
        static get maxActions() { return 0; }
      }
      Object.defineProperty(Notification.prototype, Symbol.toStringTag, {value: 'Notification'});
      Object.defineProperty(window, 'Notification', {value: Notification, writable: true, configurable: true});
      Object.defineProperty(window, '\(token)', {value: (id, type) => {
        const n = live.get(id);
        if (!n) return;
        if (type === 'click') { try { window.focus(); } catch (x) {} }
        n.__fire(type);
      }});
      const perms = navigator.permissions;
      if (perms && typeof perms.query === 'function') {
        const query = perms.query.bind(perms);
        perms.query = function (d) {
          if (d && d.name === 'notifications') return Promise.resolve({name: 'notifications', state: permission === 'default' ? 'prompt' : permission, onchange: null, addEventListener() {}, removeEventListener() {}});
          return query(d);
        };
      }
      post({kind: 'state'}).then((v) => { permission = v; }, () => {});
    })();
    """
  }
}
