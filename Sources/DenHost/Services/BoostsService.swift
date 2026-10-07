import AppKit
import CordisValue
import WebKit

@MainActor
public final class BoostsService: HostService {
  public let name = "boosts"
  let serviceHost: ServiceHost
  let webviews: WebViewsService

  public struct Boost: Equatable {
    public var css: String = ""
    public var js: String = ""
    public var name: String = ""
    public var description: String = ""
    public var version: String = ""
    public var hosts: [String] = []
  }

  public struct HostRule: Equatable {
    public var boosts: [String] = []
  }

  private var boosts: [String: Boost] = [:]
  private var defaultRule = HostRule()
  private var hostRules: [String: HostRule] = [:]
  private var active = false
  private var applied: [String: [String]] = [:]
  private var cssSheets: [String: [String: NSObject]] = [:]
  private var jsScripts: [String: [String: WKUserScript]] = [:]

  private static let sheetClass: NSObject.Type? = NSClassFromString("_WKUserStyleSheet") as? NSObject.Type
  private static let userScriptInitPatterns = NSSelectorFromString(
    "_initWithSource:injectionTime:forMainFrameOnly:includeMatchPatternStrings:excludeMatchPatternStrings:associatedURL:contentWorld:"
  )
  private static let hasPerFrameFilter = WKUserScript.instancesRespond(to: userScriptInitPatterns)

  public init(host: ServiceHost, webviews: WebViewsService) {
    self.serviceHost = host
    self.webviews = webviews
  }

  public func handle(method: String, args: Value) -> Value {
    switch method {
    case "define":    return defineBoost(args)
    case "rules":     return setRules(args)
    case "get":       return getBoost(args)
    case "uninstall": return uninstallBoost(args)
    case "list":      return listBoosts()
    case "apply":     return applyBoost(args)
    default:          return .error("boosts: unknown method '\(method)'")
    }
  }

  func defineBoost(_ args: Value) -> Value {
    let id = args.str("id")
    guard !id.isEmpty, Self.validId(id) else {
      return .error("boosts: define needs a valid id")
    }
    guard !args.str("css").isEmpty || !args.str("js").isEmpty else {
      return .error("boosts: define needs css or js")
    }
    let css = args.str("css")
    let js = args.str("js")
    guard css.utf8.count <= 64 * 1024, js.utf8.count <= 64 * 1024 else {
      return .error("boosts: css/js over 64 KB")
    }
    let wasInRules = isBoostInRules(id)
    let boost = Boost(
      css: css, js: js,
      name: args.str("name", ""),
      description: args.str("description", ""),
      version: args.str("version", ""),
      hosts: args.list("hosts").compactMap(\.string)
    )
    boosts[id] = boost
    if !wasInRules { activate() }
    reapplyAll()
    return .ok
  }

  func isBoostInRules(_ id: String) -> Bool {
    defaultRule.boosts.contains(id) || hostRules.values.contains { $0.boosts.contains(id) }
  }

  func setRules(_ args: Value) -> Value {
    defaultRule = Self.hostRule(args["default"])
    var hosts: [String: HostRule] = [:]
    for (h, v) in args["hosts"].object ?? [] {
      hosts[PageStyleService.key(h)] = Self.hostRule(v)
    }
    hostRules = hosts
    activate()
    reapplyAll()
    return .ok
  }

  static func hostRule(_ v: Value) -> HostRule {
    HostRule(boosts: v.list("boosts").compactMap(\.string))
  }

  func getBoost(_ args: Value) -> Value {
    let id = args.str("id")
    guard let r = webviews.record(id) else {
      return .error("boosts: no webview '\(id)'")
    }
    let h = PageStyleService.host(of: r.webView?.url ?? URL(string: r.url))
    let rule = rule(for: h)
    return [
      "host": .string(h),
      "boosts": .array(rule.boosts.filter { boosts[$0] != nil }.sorted().map { .string($0) }),
      "supported": .bool(true),
    ]
  }

  func uninstallBoost(_ args: Value) -> Value {
    let id = args.str("id")
    guard boosts[id] != nil else {
      return .error("boosts: no boost '\(id)'")
    }
    boosts[id] = nil
    if !defaultRule.boosts.isEmpty {
      defaultRule.boosts.removeAll { $0 == id }
    }
    for (h, rule) in hostRules where rule.boosts.contains(id) {
      var r = rule
      r.boosts.removeAll { $0 == id }
      hostRules[h] = r
    }
    reapplyAll()
    return .ok
  }

  func listBoosts() -> Value {
    .array(boosts.sorted { $0.key < $1.key }.map { id, b in
      var v: Value = [
        "id": .string(id), "name": .string(b.name),
        "description": .string(b.description), "version": .string(b.version),
        "hosts": .array(b.hosts.map { .string($0) }),
      ]
      if !b.css.isEmpty { v["css"] = .string(b.css) }
      if !b.js.isEmpty  { v["js"]  = .string(b.js) }
      return v
    })
  }

  func applyBoost(_ args: Value) -> Value {
    let boostId = args.str("boostId")
    let wid = args.str("webviewId")
    guard let r = webviews.record(wid) else {
      return .error("boosts: no webview '\(wid)'")
    }
    guard let w = r.webView else {
      return .error("boosts: webview '\(wid)' not loaded")
    }
    guard let b = boosts[boostId] else {
      return .error("boosts: no boost '\(boostId)'")
    }
    if !b.css.isEmpty {
      let c = w.configuration.userContentController
      let sheets = cssSheets[r.id] ?? [:]
      if sheets[boostId] == nil, let sheet = Self.makeSheet(b.css) {
        c.perform(NSSelectorFromString("_addUserStyleSheet:"), with: sheet)
        cssSheets[r.id, default: [:]][boostId] = sheet
      }
    }
    if !b.js.isEmpty {
      let c = w.configuration.userContentController
      let scripts = jsScripts[r.id] ?? [:]
      if scripts[boostId] == nil {
        let wrapped = Self.wrapScript(js: b.js)
        let (user, _) = Self.userScript(wrapped, hosts: b.hosts)
        c.addUserScript(user)
        jsScripts[r.id, default: [:]][boostId] = user
      }
    }
    applied[r.id, default: []].append(boostId)
    serviceHost.emit("boosts.changed", [
      "id": .string(r.id),
      "boosts": .array(applied[r.id, default: []].sorted().map { .string($0) }),
    ])
    return .ok
  }

  public func rule(for host: String) -> HostRule {
    var h = PageStyleService.key(host)
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
    webviews.navigatingHooks.append { [weak self] r, w, url in
      if let self, let h = PageStyleService.host(of: url) {
        self.apply(r, w, host: h)
      }
    }
    serviceHost.on("webviews.closed") { [weak self] v in
      let id = v.str("id")
      self?.applied[id] = nil
      self?.cssSheets[id] = nil
      self?.jsScripts[id] = nil
    }
  }

  func configure(_ r: WebRecord, _ config: WKWebViewConfiguration) {
    applied[r.id] = []
    cssSheets[r.id] = [:]
    jsScripts[r.id] = [:]
  }

  func apply(_ r: WebRecord, _ w: WKWebView, host h: String) {
    applyBoosts(r, w, host: h, rule: rule(for: h))
  }

  func applyBoosts(_ r: WebRecord, _ w: WKWebView, host h: String, rule: HostRule) {
    let wantIds = rule.boosts.filter { boosts[$0] != nil }.sorted()
    let haveIds = applied[r.id] ?? []
    guard wantIds != haveIds else { return }
    applied[r.id] = wantIds

    let c = w.configuration.userContentController
    var haveSheets = cssSheets[r.id] ?? [:]
    var haveScripts = jsScripts[r.id] ?? [:]

    for (id, sheet) in haveSheets where !wantIds.contains(id) {
      c.perform(NSSelectorFromString("_removeUserStyleSheet:"), with: sheet)
      haveSheets[id] = nil
    }
    for id in wantIds where haveSheets[id] == nil {
      guard let b = boosts[id], !b.css.isEmpty else { continue }
      if let sheet = Self.makeSheet(b.css) {
        c.perform(NSSelectorFromString("_addUserStyleSheet:"), with: sheet)
        haveSheets[id] = sheet
      }
    }
    cssSheets[r.id] = haveSheets

    for (id, script) in haveScripts where !wantIds.contains(id) {
      let remove = NSSelectorFromString("_removeUserScript:")
      if c.responds(to: remove) {
        c.perform(remove, with: script)
      } else {
        let mine = Set(haveScripts.values.map(ObjectIdentifier.init))
        let others = c.userScripts.filter { !mine.contains(ObjectIdentifier($0)) }
        c.removeAllUserScripts()
        others.forEach { c.addUserScript($0) }
      }
      haveScripts[id] = nil
    }
    for id in wantIds where haveScripts[id] == nil {
      guard let b = boosts[id], !b.js.isEmpty else { continue }
      let wrapped = Self.wrapScript(js: b.js)
      let (user, _) = Self.userScript(wrapped, hosts: b.hosts)
      c.addUserScript(user)
      haveScripts[id] = user
    }
    jsScripts[r.id] = haveScripts

    serviceHost.emit("boosts.changed", [
      "id": .string(r.id),
      "boosts": .array(wantIds.map { .string($0) }),
    ])
  }

  func reapplyAll() {
    for r in webviews.records.values {
      guard let w = r.webView else { continue }
      let h = PageStyleService.host(of: w.url ?? URL(string: r.url))
      apply(r, w, host: h)
    }
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

  static func wrapScript(js: String) -> String {
    "(function (denBoost, denToken) {\n" + js + "\n})(null, \"boost-" + UUID().uuidString + "\");\n"
  }

  static func matchPatterns(_ hosts: [String]) -> [String] {
    hosts.map { h in
      h.allSatisfy { $0.isNumber || $0 == "." || $0 == ":" } ? "*://\(h)/*" : "*://*.\(h)/*"
    }
  }

  static func userScript(_ source: String, hosts: [String]) -> (WKUserScript, filtered: Bool) {
    if !hosts.isEmpty, hasPerFrameFilter,
       let alloc = (WKUserScript.self as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject {
      typealias Init = @convention(c) (AnyObject, Selector, NSString, Int, Bool, NSArray, NSArray, NSURL?, WKContentWorld) -> WKUserScript?
      let imp = alloc.method(for: userScriptInitPatterns)
      let f = unsafeBitCast(imp, to: Init.self)
      if let s = f(alloc, userScriptInitPatterns, source as NSString,
                   WKUserScriptInjectionTime.atDocumentStart.rawValue, false,
                   matchPatterns(hosts) as NSArray, [] as NSArray, nil, .page) {
        return (s, true)
      }
    }
    return (WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page), false)
  }

  static func validId(_ id: String) -> Bool {
    !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
  }
}