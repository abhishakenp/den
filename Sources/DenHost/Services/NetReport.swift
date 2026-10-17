import Foundation
import WebKit

/// Network report for an on-device assistant (opt-in, off by default): what pages on every site
/// (private tabs excepted) fetched (fetch / XHR, with the response text) and where the tab went (history
/// navigation), appended as JSON lines to a local folder. No proxy, no certificate, nothing leaves
/// the machine.
///
/// Folder: `~/Library/Application Support/den/netreport/` (mode 700).
/// - `net-YYYY-MM-DD.jsonl`: one line per exchange (`k: "x"`) or navigation (`k: "n"`). Files
///   older than `retentionDays` are deleted.
/// - `inbox/<id>.json` → `outbox/<id>.json`: commands from the assistant:
///   `{"op": "navigate", "url": …}` loads a URL in the page in front (same tab);
///   `{"op": "preload", "url": …}` loads it in one hidden page of the user's session (setting on; records nothing);
///   `{"op": "fetch", "url": …, "method": …, "body": …, "contentType": …}` runs the request from
///   inside a page already open on that host (its cookies, never exported), from any host with an open page.
///
/// Request header VALUES are never recorded; `authz: true` only says the page sent an
/// Authorization header (such a request cannot be replayed outside the page).
///
/// The page script is installed on every http(s) page, in the page world
/// (where the page's own `fetch` lives); it wraps fetch / XHR / history and posts to `denNet`.
/// Messages are attributed by the frame's real security origin, not by what the page says.
///
/// Setting: General > "Report page network to local assistant" (`general` / `netReport`, off).
// thin-host: generic (a local report channel for every web view), not a feature
@MainActor
public final class NetReport: NSObject, WKScriptMessageHandler {
  public static let shared = NetReport()

  public static var enabledSetting = false {
    didSet { if enabledSetting != oldValue { shared.refresh(force: true) } }
  }

  public static var root: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("den/netreport", isDirectory: true)
  }

  static let handlerName = "denNet"
  static let marker = "window.__denNet"
  nonisolated static let maxResponse = 512 * 1024
  nonisolated static let maxFileBytes: UInt64 = 64 << 20
  nonisolated static let retentionDays = 2.0

  /// Web view hooks (new web views get the handler and the current script).
  weak var webviews: WebViewsService?
  private var controllers = NSHashTable<WKUserContentController>.weakObjects()
  private var wired = Set<ObjectIdentifier>()
  private var refreshed = false
  private var inboxSource: DispatchSourceFileSystemObject?
  private var preloaded: WKWebView?
  private let writer = DispatchQueue(label: "den.netreport.writer", qos: .utility)

  static let script = """
    (()=>{if(window.__denNet)return;window.__denNet=1;
    const H=window.webkit&&webkit.messageHandlers&&webkit.messageHandlers.denNet;if(!H)return;
    const MAX=\(maxResponse),MAXB=65536;const post=o=>{try{H.postMessage(o)}catch(e){}};
    const tt=t=>/json|text|javascript|xml/i.test(t||'');
    const bs=b=>typeof b==='string'?b.slice(0,MAXB):(b instanceof URLSearchParams?String(b).slice(0,MAXB):undefined);
    const F=window.fetch;
    if(F)window.fetch=function(i,n){const p=F.apply(this,arguments);try{const q=i instanceof Request?i:null;
    const url=new URL(q?q.url:String(i),location.href).href;const method=((n&&n.method)||(q&&q.method)||'GET').toUpperCase();
    const body=bs(n&&n.body);const cred=(n&&n.credentials)||(q&&q.credentials)||'same-origin';
    let hn=[];try{hn=[...new Headers((n&&n.headers)||(q&&q.headers)||{}).keys()]}catch(e){}const authz=hn.includes('authorization');
    p.then(r=>{const t=r.headers.get('content-type')||'';if(!tt(t)){post({k:'x',url,method,body,status:r.status,type:t,cred,authz});return}
    r.clone().text().then(x=>post({k:'x',url,method,body,status:r.status,type:t,cred,authz,response:x.slice(0,MAX)})).catch(()=>{})}).catch(()=>{})}catch(e){}return p};
    const X=XMLHttpRequest.prototype,O=X.open,S=X.send;
    X.open=function(m,u){try{this.__dn={method:String(m).toUpperCase(),url:new URL(u,location.href).href}}catch(e){}return O.apply(this,arguments)};
    const SH=X.setRequestHeader;X.setRequestHeader=function(k){try{if(this.__dn&&String(k).toLowerCase()==='authorization')this.__dn.authz=true}catch(e){}return SH.apply(this,arguments)};
    X.send=function(b){const d=this.__dn;if(d){d.body=bs(b);this.addEventListener('loadend',()=>{try{const t=this.getResponseHeader('content-type')||'';
    let x;if(tt(t)&&(this.responseType===''||this.responseType==='text'))x=this.responseText.slice(0,MAX);
    post({k:'x',url:d.url,method:d.method,body:d.body,authz:!!d.authz,status:this.status,type:t,cred:this.withCredentials?'include':'same-origin',response:x})}catch(e){}})}
    return S.apply(this,arguments)};
    const nav=()=>post({k:'n',url:location.href});nav();
    const P=history.pushState,R=history.replaceState;
    history.pushState=function(){const r=P.apply(this,arguments);nav();return r};
    history.replaceState=function(){const r=R.apply(this,arguments);nav();return r};
    addEventListener('popstate',nav);})();
    """

  /// Host `h` is `base` or a subdomain of it.
  static func matches(_ h: String, _ base: String) -> Bool {
    let h = h.lowercased(), base = base.lowercased()
    return h == base || h.hasSuffix("." + base)
  }

  /// Re-installs the script on every known web view and starts or stops the inbox.
  func refresh(force: Bool = false) {
    for c in controllers.allObjects { install(c) }
    if Self.enabledSetting { startInbox() } else { stopInbox() }
  }

  private func install(_ c: WKUserContentController) {
    let others = c.userScripts.filter { !$0.source.contains(Self.marker) }
    if others.count != c.userScripts.count {
      c.removeAllUserScripts()
      others.forEach(c.addUserScript)
    }
    guard Self.enabledSetting else { return }
    c.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
  }

  /// `configureHooks` entry: every new web view.
  func configure(_ config: WKWebViewConfiguration) {
    let c = config.userContentController
    if wired.insert(ObjectIdentifier(c)).inserted {
      c.add(self, contentWorld: .page, name: Self.handlerName)
      controllers.add(c)
    }
    if !refreshed { refreshed = true; refresh(force: true) } else { install(c) }
  }

  // MARK: report

  public func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
    let origin = m.frameInfo.securityOrigin
    guard Self.enabledSetting, ["http", "https"].contains(origin.protocol),
          let body = m.body as? [String: Any], let kind = body["k"] as? String,
          let url = body["url"] as? String, let u = URL(string: url), ["http", "https"].contains(u.scheme ?? "") else { return }
    if let view = m.webView, webviews?.records.values.first(where: { $0.webView === view })?.isPrivate == true { return }
    var line: [String: Any] = ["at": Int(Date().timeIntervalSince1970 * 1000), "url": url, "page": m.frameInfo.request.url?.absoluteString ?? ""]
    if kind == "n" {
      line["k"] = "n"
    } else {
      line["k"] = "x"
      for k in ["method", "body", "status", "type", "cred", "authz", "response"] { if let v = body[k], !(v is NSNull) { line[k] = v } }
    }
    append(line)
  }

  private func append(_ line: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: line), data.count < Self.maxResponse * 2 else { return }
    let dir = Self.root
    writer.async {
      let fm = FileManager.default
      try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let f = DateFormatter()
      f.dateFormat = "yyyy-MM-dd"
      f.locale = Locale(identifier: "en_US_POSIX")
      let file = dir.appendingPathComponent("net-\(f.string(from: Date())).jsonl")
      if !fm.fileExists(atPath: file.path) {
        fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        Self.prune(dir)
      }
      guard let h = try? FileHandle(forWritingTo: file) else { return }
      defer { try? h.close() }
      guard let end = try? h.seekToEnd(), end < Self.maxFileBytes else { return }
      h.write(data)
      h.write(Data([0x0a]))
    }
  }

  nonisolated static func prune(_ dir: URL) {
    let fm = FileManager.default
    let cutoff = Date().addingTimeInterval(-retentionDays * 86_400)
    for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    where f.lastPathComponent.hasPrefix("net-") {
      if let d = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d < cutoff { try? fm.removeItem(at: f) }
    }
  }

  // MARK: inbox

  private func startInbox() {
    guard inboxSource == nil else { return }
    let inbox = Self.root.appendingPathComponent("inbox", isDirectory: true)
    try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try? FileManager.default.createDirectory(at: Self.root.appendingPathComponent("outbox", isDirectory: true), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let fd = open(inbox.path, O_EVTONLY)
    guard fd >= 0 else { return }
    let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
    s.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.drainInbox() } }
    s.setCancelHandler { close(fd) }
    s.resume()
    inboxSource = s
    drainInbox()
  }

  private func stopInbox() {
    inboxSource?.cancel()
    inboxSource = nil
  }

  func drainInbox() {
    let fm = FileManager.default
    let inbox = Self.root.appendingPathComponent("inbox", isDirectory: true)
    for f in (try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "json" {
      let data = try? Data(contentsOf: f)
      try? fm.removeItem(at: f)
      guard let data, let cmd = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
      let id = f.deletingPathExtension().lastPathComponent
      run(cmd) { [weak self] reply in self?.reply(id, reply) }
    }
  }

  private func reply(_ id: String, _ value: [String: Any]) {
    guard BoostsService.validId(id), let data = try? JSONSerialization.data(withJSONObject: value) else { return }
    let out = Self.root.appendingPathComponent("outbox", isDirectory: true)
    let tmp = out.appendingPathComponent(".\(id).tmp"), dest = out.appendingPathComponent("\(id).json")
    try? data.write(to: tmp, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
    _ = try? FileManager.default.replaceItemAt(dest, withItemAt: tmp)
    if !FileManager.default.fileExists(atPath: dest.path) { try? FileManager.default.moveItem(at: tmp, to: dest) }
  }

  /// Calls back with ms since `t0` once `w` stops loading (polled every 20 ms, 15 s cap).
  private func whenLoaded(_ w: WKWebView, _ t0: Date, _ cb: @escaping @MainActor (Int) -> Void) {
    Task { @MainActor in
      var started = false
      while true {
        if w.isLoading { started = true }
        let elapsed = Date().timeIntervalSince(t0)
        if (started && !w.isLoading) || elapsed > 15 || (!started && elapsed > 2) {
          cb(Int(elapsed * 1000))
          return
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
      }
    }
  }

  func run(_ cmd: [String: Any], _ done: @escaping @MainActor ([String: Any]) -> Void) {
    let t0 = Date()
    let ms = { Int(Date().timeIntervalSince(t0) * 1000) }
    guard let web = webviews else { return done(["ok": false, "error": "no web views"]) }
    let urlStr = cmd["url"] as? String ?? ""
    guard let url = URL(string: urlStr), ["http", "https"].contains(url.scheme ?? ""), let host = url.host else { return done(["ok": false, "error": "bad url"]) }
    switch cmd["op"] as? String {
    case "navigate":
      guard let front = web.pageActions?.frontId else { return done(["ok": false, "error": "no page in front"]) }
      guard let r = web.records[front], !r.isPrivate else { return done(["ok": false, "error": "private or missing page in front"]) }
      let v = web.handle(method: "navigate", args: ["id": .string(front), "url": .string(urlStr)])
      guard v.str("error").isEmpty else { return done(["ok": false, "error": v.str("error")]) }
      // `wait`: reply once the page finished loading (for timing), else at once.
      if cmd["wait"] as? Bool == true, let w = r.webView { whenLoaded(w, t0) { done(["ok": true, "tab": front, "ms": ms(), "loadedMs": $0]) } }
      else { done(["ok": true, "tab": front, "ms": ms()]) }
    case "preload":
      // A hidden page in the user's own (non-private) web session, so the reveal that follows
      // finds DNS, TLS and the page's resources warm. Never shown; replaced by the next preload.
      // Records nothing: only warms the page the assistant is about to show. The assistant decides
      // which hosts it may name; den only requires the setting.
      guard Self.enabledSetting else { return done(["ok": false, "error": "network report is off"]) }
      _ = host
      guard let shared = web.records.values.first(where: { !$0.isPrivate && $0.webView != nil })?.webView else { return done(["ok": false, "error": "no page open"]) }
      let cfg = WKWebViewConfiguration()
      cfg.websiteDataStore = shared.configuration.websiteDataStore
      cfg.mediaTypesRequiringUserActionForPlayback = .all
      preloaded?.stopLoading()
      let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: cfg)
      w.customUserAgent = shared.customUserAgent
      preloaded = w
      w.load(URLRequest(url: url))
      whenLoaded(w, t0) { done(["ok": true, "loadedMs": $0, "ms": ms()]) }
    case "fetch":
      guard let w = web.records.values.first(where: { !$0.isPrivate && $0.webView?.url?.host.map { Self.matches($0, host) || Self.matches(host, $0) } == true })?.webView
      else { return done(["ok": false, "error": "no open page on \(host)"]) }
      let js = """
        const r = await fetch(u, {method: m, body: b || undefined, headers: t ? {'content-type': t} : {}, credentials: 'include'});
        const x = await r.text();
        return {status: r.status, type: r.headers.get('content-type') || '', body: x.slice(0, \(Self.maxResponse * 2))};
        """
      let args: [String: Any] = ["u": urlStr, "m": (cmd["method"] as? String) ?? "GET", "b": (cmd["body"] as? String) ?? "", "t": (cmd["contentType"] as? String) ?? ""]
      w.callAsyncJavaScript(js, arguments: args, in: nil, in: .defaultClient) { result in
        MainActor.assumeIsolated {
          switch result {
          case .success(let v): done((v as? [String: Any] ?? [:]).merging(["ok": true, "ms": ms()]) { a, _ in a })
          case .failure(let e): done(["ok": false, "error": e.localizedDescription, "ms": ms()])
          }
        }
      }
    default:
      done(["ok": false, "error": "unknown op"])
    }
  }
}
