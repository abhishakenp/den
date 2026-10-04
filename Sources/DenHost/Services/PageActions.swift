import AppKit
import CordisValue
import WebKit

// thin-host: feature-specific, migrate to plugin: per-site zoom policy, the context-menu items and
// their wording ("Search <engine> for …"), and the link-modifier policy belong to plugins; the
// host keeps zoom/find/print/inspect as generic web view operations.
/// Page actions behind the `webviews` service's `zoom`, `find`, `print`, `inspect`, `viewSource`,
/// `userAgent` and `caches` methods (the View / Edit menu items and their shortcuts). Every method's `id` defaults to the
/// page in front: the peek if one is open, else the focused pane.
///
/// Nothing here exists until first used: the find bar is built on the first ⌘F, the per-site zoom
/// table (storage ns `_zoom`) is read on the first navigation.
@MainActor
public final class PageActions {
  let host: ServiceHost
  unowned let webviews: WebViewsService
  unowned let content: ContentService
  let windows: WindowSet
  var wc: DenWindowController { windows.active }
  let storage: StorageService
  var palette: () -> Palette? = { nil }
  /// The default search engine `(name, url template with %s)`, from the command bar's
  /// `commands.engines` when that plugin is loaded; Google otherwise.
  var searchEngine: () -> (name: String, url: String)? = { nil }

  init(host: ServiceHost, webviews: WebViewsService, content: ContentService, windows: WindowSet, storage: StorageService) {
    self.host = host
    self.webviews = webviews
    self.content = content
    self.windows = windows
    self.storage = storage
  }

  static let methods: Set<String> = ["zoom", "find", "print", "inspect", "viewSource", "userAgent", "caches"]

  /// The page in front: the peek, else the focused pane, else the first pane.
  public var frontId: String? { content.peekId ?? content.focused ?? content.panes.first }

  func handle(_ method: String, _ r: WebRecord, _ args: Value) -> Value {
    switch method {
    case "zoom": return zoom(r, args.str("action", "reset"))
    case "find": return find(r, args.str("action", "show"), query: args["query"].string)
    case "print":
      guard let w = r.webView, let win = w.window else { return .error("webviews: '\(r.id)' is not on screen") }
      let op = w.printOperation(with: NSPrintInfo.shared)
      op.view?.frame = w.bounds
      op.runModal(for: win, delegate: nil, didRun: nil, contextInfo: nil)
      return .ok
    case "inspect": return inspect(r, args)
    case "viewSource": return viewSource(r)
    case "userAgent": return userAgent(r, args)
    case "caches": return caches(args)
    default: return .error("webviews: unknown method '\(method)'")
    }
  }

  // MARK: Zoom

  func siteKey(_ url: URL?) -> String? {
    guard let h = url?.host?.lowercased(), !h.isEmpty else { return nil }
    return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
  }

  func storedZoom(_ site: String) -> Double {
    storage.handle(method: "get", args: ["ns": "_zoom", "key": .string(site)]).double ?? 1
  }

  func zoom(_ r: WebRecord, _ action: String) -> Value {
    guard let w = r.webView else { return .error("webviews: '\(r.id)' is not loaded") }
    let steps = Tokens.zoomSteps
    let cur = Double(w.pageZoom)
    let z: Double
    switch action {
    case "in": z = steps.first { $0 > cur + 0.001 } ?? steps.last!
    case "out": z = steps.last { $0 < cur - 0.001 } ?? steps.first!
    case "reset": z = 1
    default: return .error("webviews: zoom action must be in, out or reset")
    }
    w.pageZoom = CGFloat(z)
    // Private pages zoom for now only: nothing about the site is written down.
    if !r.isPrivate, let site = siteKey(w.url ?? URL(string: r.url)) {
      if abs(z - 1) < 0.001 {
        if storedZoom(site) != 1 { _ = storage.handle(method: "delete", args: ["ns": "_zoom", "key": .string(site)]) }
      } else {
        _ = storage.handle(method: "set", args: ["ns": "_zoom", "key": .string(site), "value": .double(z)])
      }
    }
    host.emit("webviews.zoom", ["id": .string(r.id), "zoom": .double(z)])
    return ["zoom": .double(z)]
  }

  /// Re-applies the site's remembered zoom when a page's host changes (every web view starts at 100%).
  func urlChanged(_ r: WebRecord, _ w: WKWebView) {
    guard let site = siteKey(w.url) else { return }
    let z = storedZoom(site)
    if abs(Double(w.pageZoom) - z) > 0.001 {
      w.pageZoom = CGFloat(z)
      host.emit("webviews.zoom", ["id": .string(r.id), "zoom": .double(z)])
    }
  }

  // MARK: Find

  private(set) var bar: FindBarView?
  private(set) var findTarget: String?
  public private(set) var query = ""
  public private(set) var matchIndex = 0
  public private(set) var matchCount = 0

  public var findBarVisible: Bool { bar?.superview != nil }

  func find(_ r: WebRecord, _ action: String, query q: String?) -> Value {
    switch action {
    case "show":
      showBar(for: r.id)
      if let q { setQuery(q, in: r) }
      bar?.focus()
    case "next", "previous":
      if let q, q != query { setQuery(q, in: r) }
      if query.isEmpty { showBar(for: r.id); bar?.focus(); return state }
      if !findBarVisible { showBar(for: r.id) }
      step(r, forward: action == "next")
    case "selection":
      guard let w = r.webView else { return .error("webviews: '\(r.id)' is not loaded") }
      w.evaluateJavaScript("String(window.getSelection()||'')") { [weak self] v, _ in
        MainActor.assumeIsolated {
          guard let self, let s = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return }
          self.showBar(for: r.id)
          self.bar?.field.stringValue = s
          self.setQuery(s, in: r)
        }
      }
    case "hide": hideBar()
    default: return .error("webviews: find action must be show, next, previous, selection or hide")
    }
    return state
  }

  var state: Value {
    ["visible": .bool(findBarVisible), "query": .string(query), "index": .int(Int64(matchIndex)), "count": .int(Int64(matchCount))]
  }

  func showBar(for id: String) {
    if findTarget != id, findTarget != nil { clearHighlight() }
    findTarget = id
    let b = bar ?? makeBar()
    if b.superview == nil { wc.overlays.addSubview(b) }
    if let p = palette() { b.apply(p) }
    b.field.stringValue = query
    b.setCount(current: matchIndex, total: matchCount, query: query)
    layoutBar()
  }

  private func makeBar() -> FindBarView {
    let b = FindBarView()
    b.onQuery = { [weak self] q in
      guard let self, let id = self.findTarget, let r = self.webviews.record(id) else { return }
      self.setQuery(q, in: r)
    }
    b.onStep = { [weak self] fwd in
      guard let self, let id = self.findTarget, let r = self.webviews.record(id) else { return }
      self.step(r, forward: fwd)
    }
    b.onClose = { [weak self] in self?.hideBar() }
    bar = b
    windows.each { [weak self] w in
      let prev = w.onLayout
      w.onLayout = { [weak self, weak w] in prev?(); if let self, w === self.windows.active { self.layoutBar() } }
    }
    return b
  }

  func hideBar() {
    guard let b = bar, b.superview != nil else { return }
    b.removeFromSuperview()
    clearHighlight()  // the query stays for ⌘G
    if let id = findTarget, let w = webviews.record(id)?.webView { wc.window.makeFirstResponder(w) }
  }

  func layoutBar() {
    guard let b = bar, b.superview != nil else { return }
    var area = wc.overlays.convert(wc.contentArea.frame, from: wc.contentArea.superview)
    if let id = findTarget, id != content.peekId, let card = content.card(id), card.superview != nil {
      area = wc.overlays.convert(card.frame, from: card.superview)
    }
    let w = min(Tokens.findBarWidth, area.width - 2 * Tokens.findBarInset)
    b.frame = NSRect(x: (area.maxX - Tokens.findBarInset - w).rounded(), y: (area.minY + Tokens.findBarInset).rounded(), width: w, height: Tokens.findBarHeight)
  }

  /// Find in the page with the CSS Custom Highlight API, in den's own content world: every match
  /// is tinted and the current one is orange, like Safari's find overlay (WKWebView.find only
  /// selects, which is invisible while the find field has focus). Text node by text node,
  /// case-insensitive, skipping hidden elements, at most 1000 matches. `dir`: 0 new search,
  /// 1 next, -1 previous, 2 clear.
  static let findScript = """
    var S=window.__denFind||(window.__denFind={q:'',r:[],i:-1});
    if(!(window.CSS&&CSS.highlights&&window.Highlight))return {count:0,index:0};
    if(!document.getElementById('den-find-style')){var st=document.createElement('style');st.id='den-find-style';
    st.textContent='::highlight(den-find){background-color:rgba(255,214,10,.45);color:inherit}::highlight(den-find-current){background-color:#ff9f0a;color:#000}';
    (document.head||document.documentElement).appendChild(st);}
    function clear(){CSS.highlights.delete('den-find');CSS.highlights.delete('den-find-current');}
    if(dir===2){clear();S.q='';S.r=[];S.i=-1;return {count:0,index:0};}
    if(dir===0||q!==S.q){S.q=q;S.r=[];S.i=-1;if(dir===0)dir=1;
    if(q){var lq=q.toLowerCase(),root=document.body||document.documentElement,
    w=document.createTreeWalker(root,NodeFilter.SHOW_TEXT,{acceptNode:function(n){var p=n.parentElement;if(!p)return 2;var t=p.tagName;return (t==='SCRIPT'||t==='STYLE'||t==='NOSCRIPT'||t==='TEMPLATE')?2:1}}),n;
    while((n=w.nextNode())&&S.r.length<1000){var s=n.data.toLowerCase(),k=s.indexOf(lq);if(k===-1)continue;
    var p=n.parentElement;if(p.checkVisibility&&!p.checkVisibility({visibilityProperty:true}))continue;
    while(k!==-1&&S.r.length<1000){var r=new Range();r.setStart(n,k);r.setEnd(n,k+lq.length);S.r.push(r);k=s.indexOf(lq,k+lq.length);}}}}
    var c=S.r.length;if(!c){clear();return {count:0,index:0};}
    S.i=S.i<0?(dir<0?c-1:0):((S.i+dir+c)%c);
    CSS.highlights.set('den-find',new Highlight(...S.r));CSS.highlights.set('den-find-current',new Highlight(S.r[S.i]));
    var b=S.r[S.i].getBoundingClientRect();
    if(b.top<0||b.bottom>innerHeight||b.left<0||b.right>innerWidth){var e=S.r[S.i].startContainer.parentElement;if(e)e.scrollIntoView({block:'center',inline:'nearest'});}
    return {count:c,index:S.i+1};
    """

  private var findRequest = 0

  /// Runs `findScript` and publishes the answer (older answers are dropped).
  func runFind(_ r: WebRecord, _ q: String, _ dir: Int) {
    guard let w = r.webView else { return }
    findRequest += 1
    let req = findRequest, id = r.id
    w.callAsyncJavaScript(Self.findScript, arguments: ["q": q, "dir": dir], in: nil, in: .defaultClient) { [weak self] res in
      MainActor.assumeIsolated {
        guard let self, req == self.findRequest else { return }
        let v = (try? res.get()) as? [String: Any]
        self.matchCount = (v?["count"] as? NSNumber)?.intValue ?? 0
        self.matchIndex = (v?["index"] as? NSNumber)?.intValue ?? 0
        self.refreshCount()
        if dir != 2 { self.host.emit("webviews.find", self.state.with("id", .string(id))) }
      }
    }
  }

  func clearHighlight() {
    guard let id = findTarget, let r = webviews.record(id) else { return }
    runFind(r, "", 2)
  }

  /// A new query: count the matches and highlight the first.
  func setQuery(_ q: String, in r: WebRecord) {
    query = q
    if bar?.field.stringValue != q { bar?.field.stringValue = q }
    if q.isEmpty { matchIndex = 0; matchCount = 0; refreshCount(); runFind(r, "", 2); return }
    runFind(r, q, 0)
  }

  func step(_ r: WebRecord, forward: Bool) {
    guard !query.isEmpty else { refreshCount(); return }
    runFind(r, query, forward ? 1 : -1)
  }

  func refreshCount() { bar?.setCount(current: matchIndex, total: matchCount, query: query) }

  // MARK: Web Inspector, view source

  /// The Web Inspector for a page (`DevTools`: WebKit's private `_inspector`, checked first, so a
  /// WebKit without it returns an error instead of crashing). `action`: `show` (default),
  /// `toggle` (⌥⌘I), `close`, `console` (⌥⌘J) or `element` (⌥⌘C, the element picker); the
  /// `console: true` / `element: true` flags still work. Returns `{open}`.
  func inspect(_ r: WebRecord, _ args: Value) -> Value {
    guard let w = r.webView else { return .error("webviews: '\(r.id)' is not loaded") }
    let action = args.flag("console") ? "console" : args.flag("element") ? "element" : args.str("action", "show")
    let ok: Bool
    switch action {
    case "show": ok = DevTools.show(w)
    case "console": ok = DevTools.show(w, console: true)
    case "element": ok = DevTools.selectElement(w)
    case "toggle": ok = DevTools.toggle(w) != nil
    case "close": ok = DevTools.close(w)
    default: return .error("webviews: inspect action must be show, toggle, close, console or element")
    }
    guard ok else { return .error("webviews: this WebKit has no Web Inspector entry point; use Safari > Develop") }
    return ["open": .bool(DevTools.isOpen(w))]
  }

  /// Develop ▸ User Agent: `ua` is a preset id (`DevTools.agents`, or `mobile`), a full string,
  /// or `default` / "" for den's own; the page reloads with it. Without `ua`: reads it.
  /// Returns `{ua, preset}` (`preset`: an id, `default` or `other`).
  func userAgent(_ r: WebRecord, _ args: Value) -> Value {
    if let p = args["ua"].string {
      r.userAgent = DevTools.userAgent(for: p)
      if let w = r.webView {
        w.customUserAgent = r.userAgent
        if w.url != nil { w.reload() }
      }
    }
    let preset = r.userAgent.map { ua in DevTools.agents.first { $0.ua == ua }?.id ?? "other" } ?? "default"
    return ["ua": r.userAgent.map { .string($0) } ?? .null, "preset": .string(preset)]
  }

  /// Develop ▸ Empty Caches / Disable Caches. `action`: `empty` (the memory, disk and fetch caches
  /// of every profile in use; emits `webviews.cachesEmptied`), `disable` / `enable` (while
  /// disabled, each page load first empties its profile's caches), or none to read. Returns
  /// `{disabled}` (plus `pending` for `empty`).
  func caches(_ args: Value) -> Value {
    switch args.str("action") {
    case "empty":
      DevTools.emptyCaches(webviews.liveStores) { [weak self] in self?.host.emit("webviews.cachesEmptied") }
      return ["pending": true, "disabled": .bool(webviews.cachesDisabled)]
    case "disable": webviews.cachesDisabled = true
    case "enable": webviews.cachesDisabled = false
    case "": break
    default: return .error("webviews: caches action must be empty, disable or enable")
    }
    return ["disabled": .bool(webviews.cachesDisabled)]
  }

  /// View Source: the page's current DOM (`document.documentElement.outerHTML`), escaped into a
  /// read-only `data:` page opened as a new tab next to it (WKWebView has no `view-source:`).
  /// Capped at 2 MB of source.
  func viewSource(_ r: WebRecord) -> Value {
    guard let w = r.webView else { return .error("webviews: '\(r.id)' is not loaded") }
    let id = r.id, page = w.url?.absoluteString ?? r.url
    w.evaluateJavaScript("'<!DOCTYPE '+(document.doctype?document.doctype.name:'html')+'>\\n'+document.documentElement.outerHTML") { [weak self] v, _ in
      MainActor.assumeIsolated {
        guard let self, let src = v as? String else { return }
        let url = Self.sourcePage(src, of: page)
        self.host.emit("webviews.newWindow", ["id": .string(id), "url": .string(url), "background": false])
      }
    }
    return ["pending": true]
  }

  nonisolated static func sourcePage(_ src: String, of page: String) -> String {
    let capped = src.utf8.count > 2_000_000 ? String(src.prefix(2_000_000)) + "\n…" : src
    func esc(_ s: String) -> String {
      s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
    let html = """
      <!DOCTYPE html><html><head><meta charset="utf-8"><title>Source of \(esc(page))</title>
      <meta name="color-scheme" content="light dark"><style>body{margin:0;font:12px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace}
      pre{margin:0;padding:16px 20px;white-space:pre-wrap;word-break:break-all}</style></head><body><pre>\(esc(capped))</pre></body></html>
      """
    return "data:text/html;charset=utf-8;base64," + Data(html.utf8).base64EncodedString()
  }

  // MARK: Context menu

  var searchEngineName: String { searchEngine()?.name ?? "Google" }

  func searchURL(_ text: String) -> String {
    let q = text.trimmingCharacters(in: .whitespacesAndNewlines).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=#?"))) ?? ""
    let t = searchEngine()?.url ?? "https://www.google.com/search?q=%s"
    return t.replacingOccurrences(of: "%s", with: q)
  }
}
