import AppKit
import CordisValue
import WebKit

/// Generic building blocks that let a plugin work inside web pages (docs/host-api.md#webviews):
///
/// - `webviews.inject`: run the plugin's scripts (files from its resource folder, and/or a
///   function body) in a live page, in the plugin's own isolated content world. The page's
///   scripts can't see that world, and each plugin gets its own.
/// - Messages: a script in that world calls `webkit.messageHandlers.den.postMessage(value)`;
///   den emits `webviews.message {webview, plugin, value}`.
/// - `webviews.setMenu`: items a plugin adds to a page's context menu.
/// - `webviews.setContentRules`: a plugin's WebKit content rules (block, hide with CSS), applied
///   by WebKit at document start on every web view. No script runs.
///
/// Nothing here runs or is read until a plugin calls it: script files are read on first use
/// (then cached), and a web view gets the message handler on the first inject into it.
@MainActor
final class PageScripting {
  unowned let web: WebViewsService
  private var sources: [URL: String] = [:]
  private var wired: [String: NSHashTable<WKWebView>] = [:]
  private var menus: [String: [Value]] = [:]
  private var rules: [String: WKContentRuleList] = [:]
  private var nextRequest = 1
  private lazy var proxy = ScriptMessageProxy { [weak self] m in self?.received(m) }
  static let maxScriptBytes = 64 * 1024

  init(web: WebViewsService) { self.web = web }

  static func world(_ plugin: String) -> WKContentWorld { .world(name: "den.plugin." + plugin) }

  // MARK: inject

  func inject(_ r: WebRecord, _ args: Value) -> Value {
    let plugin = args.str("plugin")
    guard !plugin.isEmpty else { return .error("webviews: inject needs 'plugin'") }
    guard let w = r.webView else { return .error("webviews: '\(r.id)' is not loaded") }
    let host = w.url?.host?.lowercased() ?? ""
    guard !host.isEmpty, web.allowPages?(plugin, host) == true else { return .error("webviews: '\(plugin)' may not script \(host.isEmpty ? "this page" : host)") }
    let script = args.str("script")
    guard script.utf8.count <= Self.maxScriptBytes else { return .error("webviews: script over \(Self.maxScriptBytes) bytes") }
    var files: [URL] = []
    for f in args.list("files") {
      guard let name = f.string, let url = web.resource?(plugin, name) else { return .error("webviews: no resource '\(f.string ?? "")' for '\(plugin)'") }
      files.append(url)
    }
    var request = args.str("request")
    if request.isEmpty { request = "inject-\(nextRequest)"; nextRequest += 1 }
    let world = Self.world(plugin), global = args.str("global"), id = r.id
    let scriptArgs = (ValueJSON.any(args["args"]) as? [String: Any]) ?? [:]
    wire(w, plugin)
    Task {
      var result: Value = .null
      var error: String?
      if !files.isEmpty {
        let present = global.isEmpty ? false : (await Self.call(w, "return typeof window[g] !== 'undefined'", ["g": global], world)).bool == true
        if !present {
          for f in files {
            guard let src = source(f) else { error = "webviews: can't read \(f.lastPathComponent)"; break }
            if let e = await Self.evaluate(w, src + "\n;true", world) { error = "webviews: \(f.lastPathComponent): \(e)"; break }
          }
        }
      }
      if error == nil, !script.isEmpty {
        result = await Self.call(w, script, scriptArgs, world)
        if result.isError { error = result.str("error") }
      }
      let base: Value = ["request": .string(request), "webview": .string(id), "plugin": .string(plugin), "ok": .bool(error == nil)]
      if let error { web.host.emit("webviews.injectResult", base.with("error", .string(error))) } else { web.host.emit("webviews.injectResult", base.with("value", result)) }
    }
    return ["request": .string(request)]
  }

  private func source(_ url: URL) -> String? {
    if let s = sources[url] { return s }
    guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    sources[url] = s
    return s
  }

  /// Script files read so far (tests: nothing before a plugin asks).
  var loadedFiles: [String] { sources.keys.map { $0.lastPathComponent }.sorted() }

  /// A function body, run with `args` as named arguments. Errors come back as `{error}`.
  static func call(_ w: WKWebView, _ body: String, _ args: [String: Any], _ world: WKContentWorld, timeout: Double = 30) async -> Value {
    await awaitCallback(timeout, Value.error("webviews: script timed out")) { done in
      w.callAsyncJavaScript(body, arguments: args, in: nil, in: world) { result in
        switch result {
        case let .success(v): done(WebViewsService.jsValue(v))
        case let .failure(e): done(.error("webviews: " + Self.message(e)))
        }
      }
    }
  }

  /// A classic script (a library file). Returns an error message, or nil.
  static func evaluate(_ w: WKWebView, _ source: String, _ world: WKContentWorld) async -> String? {
    await awaitCallback(30, Optional("timed out")) { done in
      w.evaluateJavaScript(source, in: nil, in: world) { result in
        if case let .failure(e) = result { done(Self.message(e)) } else { done(nil) }
      }
    }
  }

  /// WebKit's JS error, with the exception's own message when there is one.
  nonisolated static func message(_ e: Error) -> String {
    let n = e as NSError
    if let m = n.userInfo["WKJavaScriptExceptionMessage"] as? String { return m }
    return n.localizedDescription
  }

  // MARK: messages

  private func wire(_ w: WKWebView, _ plugin: String) {
    let set = wired[plugin] ?? NSHashTable<WKWebView>.weakObjects()
    wired[plugin] = set
    guard !set.contains(w) else { return }
    w.configuration.userContentController.add(proxy, contentWorld: Self.world(plugin), name: "den")
    set.add(w)
  }

  private func received(_ m: WKScriptMessage) {
    guard let w = m.webView, let id = web.id(of: w) else { return }
    let name = m.world.name ?? ""
    guard name.hasPrefix("den.plugin.") else { return }
    web.host.emit("webviews.message", ["webview": .string(id), "plugin": .string(String(name.dropFirst("den.plugin.".count))), "value": WebViewsService.jsValue(m.body)])
  }

  // MARK: context menu

  /// `items: [{id, title, when?: selection|any}]` (null or [] removes the plugin's items).
  func setMenu(_ args: Value) -> Value {
    let plugin = args.str("plugin")
    guard !plugin.isEmpty else { return .error("webviews: setMenu needs 'plugin'") }
    menus[plugin] = args.list("items").isEmpty ? nil : args.list("items")
    web.contextMenu = menus.isEmpty ? nil : { [weak self] w, menu in self?.extend(menu, for: w) }
    return .ok
  }

  func extend(_ menu: NSMenu, for w: WKWebView) {
    guard let id = web.id(of: w) else { return }
    // WebKit's menu for selected text has a Copy item; link and image menus don't.
    let copy = menu.items.firstIndex { $0.identifier?.rawValue == "WKMenuItemIdentifierCopy" }
    var at = copy.map { $0 + 1 } ?? menu.items.count
    for (plugin, items) in menus.sorted(by: { $0.key < $1.key }) {
      for item in items {
        if item.str("when") == "selection", copy == nil { continue }
        let mi = NSMenuItem(title: item.str("title"), action: #selector(PluginMenuTarget.picked(_:)), keyEquivalent: "")
        mi.target = PluginMenuTarget.shared
        mi.representedObject = [item.str("id"), id, plugin]
        menu.insertItem(mi, at: min(at, menu.items.count))
        at += 1
      }
    }
    PluginMenuTarget.shared.emit = { [weak self] item, webview, plugin in
      self?.web.host.emit("webviews.menu", ["id": .string(item), "webview": .string(webview), "plugin": .string(plugin)])
    }
  }

  // MARK: content rules

  /// `rules`: WebKit content rules (`[{trigger, action}]`), compiled into one list per plugin.
  /// `[]` removes them. Emits `webviews.contentRules {plugin, ok, count, error?}`.
  func setContentRules(_ args: Value) -> Value {
    let plugin = args.str("plugin")
    guard !plugin.isEmpty else { return .error("webviews: setContentRules needs 'plugin'") }
    let list = args.list("rules"), ident = "den.plugin." + plugin
    guard !list.isEmpty else {
      rules[plugin] = nil
      web.setRuleLists(Array(rules.values))
      WKContentRuleListStore.default().removeContentRuleList(forIdentifier: ident) { [weak self] _ in
        MainActor.assumeIsolated { self?.web.host.emit("webviews.contentRules", ["plugin": .string(plugin), "ok": true, "count": 0]) }
      }
      return ["pending": true]
    }
    WKContentRuleListStore.default().compileContentRuleList(forIdentifier: ident, encodedContentRuleList: ValueJSON.string(.array(list))) { [weak self] compiled, error in
      MainActor.assumeIsolated {
        guard let self else { return }
        if let compiled {
          self.rules[plugin] = compiled
          self.web.setRuleLists(Array(self.rules.values))
        }
        var p: Value = ["plugin": .string(plugin), "ok": .bool(compiled != nil), "count": .int(Int64(list.count))]
        if let error { p = p.with("error", .string(error.localizedDescription)) }
        self.web.host.emit("webviews.contentRules", p)
      }
    }
    return ["pending": true]
  }
}

/// Waits for a WebKit callback, but never forever: after `seconds` it returns `fallback` (a hung
/// or crashed web content process never answers). Late answers are dropped.
@MainActor
func awaitCallback<T>(_ seconds: Double, _ fallback: T, _ start: (@escaping @MainActor (T) -> Void) -> Void) async -> T {
  let box = await withCheckedContinuation { (c: CheckedContinuation<UncheckedBox<T>, Never>) in
    var done = false
    let finish: @MainActor (T) -> Void = { v in
      guard !done else { return }
      done = true
      c.resume(returning: UncheckedBox(v))
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { finish(fallback) } }
    start(finish)
  }
  return box.value
}

struct UncheckedBox<T>: @unchecked Sendable {
  let value: T
  init(_ v: T) { value = v }
}

/// NSMenuItem target for plugin context-menu items.
@MainActor
final class PluginMenuTarget: NSObject {
  static let shared = PluginMenuTarget()
  var emit: ((String, String, String) -> Void)?
  @objc func picked(_ sender: NSMenuItem) {
    guard let a = sender.representedObject as? [String], a.count == 3 else { return }
    emit?(a[0], a[1], a[2])
  }
}
