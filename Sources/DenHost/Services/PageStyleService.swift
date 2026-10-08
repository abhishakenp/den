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

  /// A named package of user stylesheets and page scripts, applied per domain (Zen Mods style).
  public struct Mod: Equatable {
    public var name: String
    public var css: String
    public var js: String
    public var hosts: [String]
    public init(name: String, css: String, js: String = "", hosts: [String] = []) {
      self.name = name
      self.css = css
      self.js = js
      self.hosts = hosts
    }
    public static func == (a: Mod, b: Mod) -> Bool {
      a.name == b.name && a.css == b.css && a.js == b.js && a.hosts == b.hosts
    }
  }

  private(set) var css: [String: String] = [:]
  private var versions: [String: Int] = [:]
  /// Named mods (CSS/JS packages) loaded from disk or defined at runtime.
  private var mods: [String: Mod] = [:]
  /// Per web view: applied mods with their CSS _WKUserStyleSheet for cleanup.
  private var appliedMods: [String: [String: NSObject]] = [:]
  /// Directory for per-site mods stored on disk (Zen Mods style).
  static let modsRoot: URL = {
    let p = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return p.appendingPathComponent("den/mods", isDirectory: true)
  }()

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
      if wantDetect && !detect { for r in webviews.records.values { if let w = r.webView { installDetector(w.configuration.userContentController) } } }
      detect = wantDetect
      reapplyAll()
      return .ok
    case "mods.define":
      guard let n = args["name"].string, !n.isEmpty else { return .error("mods: define needs a name") }
      let css = args.str("css")
      let js = args.str("js")
      let hosts = args.list("hosts").compactMap(\.string)
      mods[n] = Mod(name: n, css: css, js: js, hosts: hosts)
      if active { reapplyAll() }
      return .ok
    case "mods.list":
      return .array(mods.values.sorted { $0.name < $1.name }.map { m in
        ["name": .string(m.name), "css": .string(m.css), "js": .string(m.js), "hosts": .array(m.hosts.map { .string($0) })]
      })
    case "mods.remove":
      guard let n = args["name"].string else { return .error("mods: remove needs a name") }
      mods[n] = nil
      if active { reapplyAll() }
      return .ok
    case "mods.scan":
      return loadModsFromDisk()
    case "get":
      let id = args.str("id")
      guard let r = webviews.record(id) else { return .error("pagestyle: no webview '\(id)'") }
      let h = Self.pageHost(of: r.webView?.url ?? URL(string: r.url))
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

  nonisolated static func key(_ h: String) -> String {
    var k = h.lowercased()
    if k.hasSuffix(".") { k.removeLast() }
    if k.hasPrefix("www.") { k.removeFirst(4) }
    return k
  }

  nonisolated static func pageHost(of url: URL?) -> String { key(url?.host ?? "") }

  public func rule(for host: String) -> Rule {
    var h = Self.key(host)
    while !h.isEmpty {
      if let r = hostRules[h] { return r }
      guard let dot = h.firstIndex(of: ".") else { break }
      h = String(h[h.index(after: dot)...])
    }
    return defaultRule
  }

  func activate() {
    guard !active else { return }
    active = true
    webviews.configureHooks.append { [weak self] r, config in self?.configure(r, config) }
    webviews.navigatingHooks.append { [weak self] r, w, url in self?.apply(r, w, host: Self.pageHost(of: url)) }
    host.on("webviews.closed") { [weak self] v in
      let id = v.str("id")
      self?.applied[id] = nil
      self?.appliedMods[id] = nil
      self?.tones[id] = nil
      self?.appliedAppearance[id] = nil
    }
  }

  func configure(_ r: WebRecord, _ config: WKWebViewConfiguration) {
    applied[r.id] = [:]
    appliedMods[r.id] = [:]
    appliedAppearance[r.id] = nil
    config.userContentController.add(toneHandler, contentWorld: Self.world, name: "denTone")
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
      apply(r, w, host: Self.pageHost(of: w.url ?? URL(string: r.url)))
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
    applyMods(r, w, host: h)
    if appliedAppearance[r.id] != .some(rule.appearance) {
      appliedAppearance[r.id] = .some(rule.appearance)
      w.appearance = rule.appearance.map { NSAppearance(named: $0 == "dark" ? .darkAqua : .aqua) } ?? nil
    }
  }

  func applyMods(_ r: WebRecord, _ w: WKWebView, host h: String) {
    let c = w.configuration.userContentController
    let hKey = Self.key(h)
    var matched: [(String, Mod)] = []
    for (_, m) in mods where m.hosts.contains(hKey) { matched.append((m.name, m)) }
    var parent = hKey
    while !parent.isEmpty && matched.isEmpty {
      guard let dot = parent.firstIndex(of: ".") else { break }
      parent = String(parent[parent.index(after: dot)...])
      for (_, m) in mods where m.hosts.contains(parent) { matched.append((m.name, m)) }
    }
    if matched.isEmpty {
      for (_, m) in mods where m.hosts.isEmpty { matched.append((m.name, m)) }
    }
    var current = appliedMods[r.id] ?? [:]
    let matchedNames = Set(matched.map(\.0))
    for (name, oldSheet) in current where !matchedNames.contains(name) {
      c.perform(NSSelectorFromString("_removeUserStyleSheet:"), with: oldSheet)
      current[name] = nil
    }
    for (name, m) in matched where current[name] == nil {
      guard let sheet = Self.makeSheet(m.css) else { continue }
      c.perform(NSSelectorFromString("_addUserStyleSheet:"), with: sheet)
      current[name] = sheet
      if !m.js.isEmpty {
        let script = WKUserScript(source: m.js, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        c.addUserScript(script)
      }
    }
    appliedMods[r.id] = current
  }

  func loadModsFromDisk() -> Value {
    let root = Self.modsRoot
    guard let contents = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return ["count": .int(0)] }
    var count = 0
    for name in contents {
      let dir = root.appendingPathComponent(name)
      guard dir.hasDirectoryPath,
            let css = try? String(contentsOf: dir.appendingPathComponent("style.css"), encoding: .utf8)
      else { continue }
      let js: String
      let jsUrl = dir.appendingPathComponent("script.js")
      if FileManager.default.fileExists(atPath: jsUrl.path) {
        js = (try? String(contentsOf: jsUrl, encoding: .utf8)) ?? ""
      } else {
        js = ""
      }
      let hostsUrl = dir.appendingPathComponent("hosts.json")
      let hosts: [String]
      if FileManager.default.fileExists(atPath: hostsUrl.path),
         let data = try? Data(contentsOf: hostsUrl),
         let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
        hosts = arr
      } else {
        hosts = []
      }
      let mod = Mod(name: name, css: css, js: js, hosts: hosts)
      mods[name] = mod
      count += 1
    }
    return ["count": .int(Int64(count))]
  }

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
    let h = Self.pageHost(of: w.url)
    host.emit("pagestyle.tone", ["id": .string(r.id), "host": .string(h), "tone": .string(tone), "dark": .bool(body["dark"] as? Bool ?? false)])
  }

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
