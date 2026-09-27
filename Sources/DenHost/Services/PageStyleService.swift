import AppKit
import CordisValue
import WebKit

/// `pagestyle` service: per-site user stylesheets and appearance for every web view, plus a tiny
/// page-tone detector. The host only applies; which CSS and which sites is the plugin's logic
/// (the `darkmode` plugin).
///
///   define {name, css}                         -> ok. A named user stylesheet (user origin, main frame only)
///   rules {default: {sheets, appearance?}, hosts: {<host>: {sheets, appearance?}}, detect?}
///                                              -> ok. `appearance`: light | dark | null (follow den's window)
///   get {id}                                   -> {host, sheets, appearance, tone, supported}
///
/// Events: `pagestyle.tone {id, host, tone: dark|light, dark}` from the detector (`dark` is the
/// page's `prefers-color-scheme` when it measured).
///
/// - Sheets are WebKit user stylesheets (`_WKUserStyleSheet`, WebKit SPI), not scripts: no
///   `<style>` element, no DOM mutation, applied before the first paint of each document, and
///   added to or removed from a live page without a reload.
/// - A rule is picked on every main-frame navigation decision (before the new document exists) by
///   the target host, its parent domains, then `default`. `www.` is ignored.
/// - The detector is one WKUserScript in the isolated `den-style` world. It sets
///   `data-den-tone` on `<html>` (the sheets key on it) from the background under the viewport
///   center, at the first frame, DOMContentLoaded and load, and reports it.
/// - Nothing is created until a plugin calls `rules`: no scripts, no sheets, no handlers.
@MainActor
public final class PageStyleService: HostService {
  public let name = "pagestyle"
  let host: ServiceHost
  let webviews: WebViewsService

  public struct Rule: Equatable {
    public var sheets: [String] = []
    public var appearance: String?
  }

  private(set) var css: [String: String] = [:]
  private var versions: [String: Int] = [:]
  public private(set) var defaultRule = Rule()
  public private(set) var hostRules: [String: Rule] = [:]
  public private(set) var detect = false
  private var active = false
  /// Per web view: the sheets currently added (name -> (version, _WKUserStyleSheet)) and the tone.
  private var applied: [String: [String: (Int, NSObject)]] = [:]
  private var tones: [String: String] = [:]
  private var appliedAppearance: [String: String?] = [:]
  private lazy var toneHandler = ScriptMessageProxy { [weak self] msg in self?.didReceive(msg) }
  static let world = WKContentWorld.world(name: "den-style")

  /// `_WKUserStyleSheet` (WebKit SPI, present since macOS 10.12). Without it the service does nothing.
  static let sheetClass: NSObject.Type? = NSClassFromString("_WKUserStyleSheet") as? NSObject.Type
  public static var supported: Bool { sheetClass != nil }

  public init(host: ServiceHost, webviews: WebViewsService) {
    self.host = host
    self.webviews = webviews
  }

  public func handle(method: String, args: Value) -> Value {
    switch method {
    case "define":
      let n = args.str("name")
      guard !n.isEmpty else { return .error("pagestyle: define needs a name") }
      guard args.str("css").utf8.count <= 64 * 1024 else { return .error("pagestyle: css over 64 KB") }
      css[n] = args.str("css")
      versions[n, default: 0] += 1
      if active { reapplyAll() }
      return .ok
    case "rules":
      defaultRule = Self.rule(args["default"])
      var hosts: [String: Rule] = [:]
      for (h, v) in args["hosts"].object ?? [] { hosts[Self.key(h)] = Self.rule(v) }
      hostRules = hosts
      let wantDetect = args.flag("detect")
      activate()
      // Turning detection off affects web views created from now on (a script can't be removed alone).
      if wantDetect && !detect { for r in webviews.records.values { if let w = r.webView { installDetector(w.configuration.userContentController) } } }
      detect = wantDetect
      reapplyAll()
      return .ok
    case "get":
      let id = args.str("id")
      guard let r = webviews.record(id) else { return .error("pagestyle: no webview '\(id)'") }
      let h = Self.host(of: r.webView?.url ?? URL(string: r.url))
      return [
        "host": .string(h), "sheets": .array((applied[id] ?? [:]).keys.sorted().map { .string($0) }),
        "appearance": ((appliedAppearance[id] ?? nil).map { Value.string($0) } ?? .null), "tone": tones[id].map { Value.string($0) } ?? .null, "supported": .bool(Self.supported),
      ]
    default:
      return .error("pagestyle: unknown method '\(method)'")
    }
  }

  static func rule(_ v: Value) -> Rule {
    Rule(sheets: v.list("sheets").compactMap(\.string), appearance: v["appearance"].string.flatMap { ["light", "dark"].contains($0) ? $0 : nil })
  }

  /// "WWW.Example.com." -> "example.com"
  nonisolated static func key(_ h: String) -> String {
    var k = h.lowercased()
    if k.hasSuffix(".") { k.removeLast() }
    if k.hasPrefix("www.") { k.removeFirst(4) }
    return k
  }

  nonisolated static func host(of url: URL?) -> String { key(url?.host ?? "") }

  /// The rule for `host`: the host itself, then each parent domain, then the default.
  public func rule(for host: String) -> Rule {
    var h = Self.key(host)
    while !h.isEmpty {
      if let r = hostRules[h] { return r }
      guard let dot = h.firstIndex(of: ".") else { break }
      h = String(h[h.index(after: dot)...])
    }
    return defaultRule
  }

  // MARK: Web view hooks (installed on the first `rules`)

  func activate() {
    guard !active else { return }
    active = true
    webviews.configureHooks.append { [weak self] r, config in self?.configure(r, config) }
    webviews.navigatingHooks.append { [weak self] r, w, url in self?.apply(r, w, host: Self.host(of: url)) }
    host.on("webviews.closed") { [weak self] v in
      let id = v.str("id")
      self?.applied[id] = nil
      self?.tones[id] = nil
      self?.appliedAppearance[id] = nil
    }
  }

  func configure(_ r: WebRecord, _ config: WKWebViewConfiguration) {
    // A new WKWebView (first show, or after a discard) starts with a fresh controller.
    applied[r.id] = [:]
    appliedAppearance[r.id] = nil
    config.userContentController.add(toneHandler, contentWorld: Self.world, name: "denTone")
    // A new controller may reuse a freed one's address: forget it before installing.
    withDetector.remove(ObjectIdentifier(config.userContentController))
    if detect { installDetector(config.userContentController) }
  }

  private var withDetector = Set<ObjectIdentifier>()
  func installDetector(_ c: WKUserContentController) {
    guard withDetector.insert(ObjectIdentifier(c)).inserted else { return }
    c.addUserScript(WKUserScript(source: Self.detector, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.world))
  }

  func reapplyAll() {
    for r in webviews.records.values {
      guard let w = r.webView else { continue }
      apply(r, w, host: Self.host(of: w.url ?? URL(string: r.url)))
    }
  }

  func apply(_ r: WebRecord, _ w: WKWebView, host h: String) {
    let rule = rule(for: h)
    let c = w.configuration.userContentController
    var have = applied[r.id] ?? [:]
    for (n, (ver, sheet)) in have where !rule.sheets.contains(n) || versions[n] != ver {
      c.perform(NSSelectorFromString("_removeUserStyleSheet:"), with: sheet)
      have[n] = nil
    }
    for n in rule.sheets where have[n] == nil {
      guard let source = css[n], let sheet = Self.makeSheet(source) else { continue }
      c.perform(NSSelectorFromString("_addUserStyleSheet:"), with: sheet)
      have[n] = (versions[n] ?? 0, sheet)
    }
    applied[r.id] = have
    if appliedAppearance[r.id] != .some(rule.appearance) {
      appliedAppearance[r.id] = .some(rule.appearance)
      w.appearance = rule.appearance.map { NSAppearance(named: $0 == "dark" ? .darkAqua : .aqua) } ?? nil
    }
  }

  /// `[[_WKUserStyleSheet alloc] initWithSource:css forMainFrameOnly:YES]` (user level, page world).
  static func makeSheet(_ source: String) -> NSObject? {
    guard let cls = sheetClass else { return nil }
    typealias Init = @convention(c) (AnyObject, Selector, NSString, Bool) -> Unmanaged<NSObject>?
    let sel = NSSelectorFromString("initWithSource:forMainFrameOnly:")
    guard let imp = class_getMethodImplementation(cls, sel),
      let alloc = cls.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
    else { return nil }
    return unsafeBitCast(imp, to: Init.self)(alloc, sel, source as NSString, true)?.takeRetainedValue()
  }

  func didReceive(_ msg: WKScriptMessage) {
    guard msg.frameInfo.isMainFrame, let w = msg.webView, let r = webviews.recordFor(w), let body = msg.body as? [String: Any],
      let tone = body["tone"] as? String, ["dark", "light"].contains(tone)
    else { return }
    tones[r.id] = tone
    let h = Self.host(of: w.url)
    host.emit("pagestyle.tone", ["id": .string(r.id), "host": .string(h), "tone": .string(tone), "dark": .bool(body["dark"] as? Bool ?? false)])
  }

  /// Page tone from the first opaque background under the viewport center (then body, then the
  /// text color / color-scheme). Relative luminance < 0.18 is dark. Runs 3–4 times per page.
  static let detector = """
    (()=>{const de=document.documentElement;
    const lum=c=>{const m=c&&c.match(/[\\d.]+/g);if(!m||m.length<3||(m.length>3&&+m[3]<0.5))return -1;
    const [r,g,b]=m.slice(0,3).map(x=>{x/=255;return x<=0.03928?x/12.92:Math.pow((x+0.055)/1.055,2.4)});return 0.2126*r+0.7152*g+0.0722*b};
    const bgOf=e=>{for(;e&&e.nodeType===1;e=e.parentElement){const l=lum(getComputedStyle(e).backgroundColor);if(l>=0)return l}return -1};
    const dark=()=>matchMedia('(prefers-color-scheme: dark)').matches;
    const tone=()=>{const b=document.body;if(!b)return null;
    let l=bgOf(document.elementFromPoint(innerWidth/2,Math.min(innerHeight/2,300)));if(l<0)l=bgOf(b);
    if(l<0){const t=lum(getComputedStyle(b).color);l=t>0.5||(/dark/.test(getComputedStyle(de).colorScheme)&&dark())?0:1}
    return l<0.18?'dark':'light'};
    let last=null;const check=()=>{const t=tone();if(!t||t===last)return;last=t;de.setAttribute('data-den-tone',t);
    try{webkit.messageHandlers.denTone.postMessage({tone:t,dark:dark()})}catch(e){}};
    requestAnimationFrame(check);document.addEventListener('DOMContentLoaded',check);
    addEventListener('load',()=>{check();setTimeout(check,1000)});})();
    """
}
