import AppKit
import CordisValue
import WebKit

/// Generic "link under the pointer" primitive for `webviews.watchLinks` (docs/host-api.md).
///
/// A tiny listener runs in an isolated content world ("den-links"), main frame only. It reports the
/// `a[href]` under the pointer (http(s) only, not same-page `#fragment` links): with modifier `shift`
/// only while Shift is held, with `none` on plain hover. No timers, no network: at rest it is a few
/// event listeners, and nothing at all until a plugin calls `watchLinks`.
/// Policy (which links get a card, when to yield to a site's own previews) stays in the plugin.
///
/// Independently of `modifier`, `webviews.watchStatus` turns on the link *status* report: the link
/// under the pointer (or keyboard focus) on plain hover, any scheme but `javascript:`, for a status
/// pill (`webviews.linkStatus {id, url}`, `url: ""` when there is none). Both share one script.
@MainActor
public final class LinkHover {
  public static let world = WKContentWorld.world(name: "den-links")
  public static let handlerName = "denLinks"

  /// "off" (default: nothing installed), "shift" or "none".
  public private(set) var modifier = "off"
  public private(set) var yieldTo: [String] = []
  /// `webviews.watchStatus`: report the link under the pointer for a status pill.
  public private(set) var status = false
  public var enabled: Bool { modifier != "off" || status }

  /// Views that currently carry the script + handler.
  private var installed = Set<ObjectIdentifier>()

  public init() {}

  /// Updates the config. Returns false for an unknown modifier.
  func configure(modifier m: String, yieldTo y: [String]) -> Bool {
    guard ["off", "shift", "none"].contains(m) else { return false }
    modifier = m
    yieldTo = y
    return true
  }

  func configureStatus(_ on: Bool) { status = on }

  /// The injected source for the current config (a function of the config only; re-running it
  /// in a page that already has it just swaps the config).
  public var script: String {
    let cfg = ValueJSON.string(["m": .string(modifier), "y": .array(yieldTo.map { .string($0) }), "s": .bool(status)])
    return Self.template.replacingOccurrences(of: "__CFG__", with: cfg)
  }

  static let template = """
    (function(){var C=__CFG__;var S=window.__denLinks;if(S){S.c=C;return;}S=window.__denLinks={c:C};
    var cur=null,over=null,shift=false,st=null;
    function post(m){try{webkit.messageHandlers.denLinks.postMessage(m)}catch(e){}}
    function anchor(t){return t&&t.closest?t.closest('a[href]'):null}
    function link(t){var a=anchor(t);if(!a)return null;var h=a.href;if(!/^https?:/i.test(h))return null;
    try{var u=new URL(h),l=location;if(u.hash&&u.origin===l.origin&&u.pathname===l.pathname&&u.search===l.search)return null}catch(e){return null}return a}
    function any(t){var a=anchor(t);if(!a||!a.href||/^javascript:/i.test(a.href))return null;return a}
    function status(a){if(!S.c.s)a=null;if(a===st)return;st=a;post({t:'status',url:a?a.href:''})}
    function vis(){var y=S.c.y||[];for(var i=0;i<y.length;i++){var es;try{es=document.querySelectorAll(y[i])}catch(e){continue}
    for(var j=0;j<es.length;j++){var r=es[j].getBoundingClientRect();if(r.width>0&&r.height>0&&getComputedStyle(es[j]).visibility!=='hidden')return true}}return false}
    function show(a){if(a===cur)return;cur=a;var r=a.getBoundingClientRect();
    post({t:'hover',url:a.href,text:(a.innerText||a.title||'').replace(/\\s+/g,' ').trim().slice(0,200),x:r.left,y:r.top,w:r.width,h:r.height,yield:vis()})}
    function end(){if(!cur)return;cur=null;post({t:'end'})}
    function want(e){return S.c.m==='none'||(S.c.m==='shift'&&(shift||!!(e&&e.shiftKey)))}
    var L={
    keydown:function(e){if(e.key!=='Shift')return;shift=true;if(S.c.m==='shift'&&over)show(over)},
    keyup:function(e){if(e.key!=='Shift')return;shift=false;if(S.c.m==='shift')end()},
    mouseover:function(e){status(any(e.target));over=link(e.target);if(over&&want(e))show(over);else if(cur&&over!==cur)end()},
    mouseout:function(e){var r=e.relatedTarget;if(!any(r))status(null);var to=r?link(r):null;if(!to){over=null;end()}},
    focusin:function(e){var a=any(e.target);if(a)status(a)},
    focusout:function(e){if(st&&any(e.target)===st)status(null)},
    scroll:end,mousedown:end,blur:function(){shift=false;end();status(null)},pagehide:function(){end();status(null)}};
    for(var k in L)window.addEventListener(k,L[k],{capture:true,passive:true});
    S.off=function(){for(var k in L)window.removeEventListener(k,L[k],{capture:true,passive:true});end();status(null);delete window.__denLinks}})();
    """

  static let offScript = "if(window.__denLinks&&window.__denLinks.off)window.__denLinks.off();"

  /// Adds the script and handler to a view (future documents) and runs it in the current one.
  /// WKUserContentController can only remove all user scripts: keep everyone else's.
  static func removeOurScript(_ ucc: WKUserContentController) {
    let others = ucc.userScripts.filter { !$0.source.contains("window.__denLinks") }
    guard others.count != ucc.userScripts.count else { return }
    ucc.removeAllUserScripts()
    others.forEach(ucc.addUserScript)
  }

  func install(_ w: WKWebView, handler: WKScriptMessageHandler) {
    let ucc = w.configuration.userContentController
    Self.removeOurScript(ucc)
    if installed.insert(ObjectIdentifier(w)).inserted {
      ucc.add(handler, contentWorld: Self.world, name: Self.handlerName)
    }
    let src = script
    ucc.addUserScript(WKUserScript(source: src, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.world))
    w.evaluateJavaScript(src, in: nil, in: Self.world) { _ in }
  }

  /// Removes the script and handler and stops the listeners in the current document.
  func uninstall(_ w: WKWebView) {
    guard installed.remove(ObjectIdentifier(w)) != nil else { return }
    let ucc = w.configuration.userContentController
    Self.removeOurScript(ucc)
    ucc.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: Self.world)
    w.evaluateJavaScript(Self.offScript, in: nil, in: Self.world) { _ in }
  }

  func forget(_ w: WKWebView) { installed.remove(ObjectIdentifier(w)) }

  public func isInstalled(_ w: WKWebView) -> Bool { installed.contains(ObjectIdentifier(w)) }

  // MARK: Pure mapping (tested)

  /// A message body -> (event name, payload), or nil to drop it. `id` comes from the host's own
  /// record for the sending web view, never from the page. `toWindow` maps a rect in the page's
  /// viewport (CSS px) to window coordinates (top-left origin, points).
  public static func event(id: String, body: Any, toWindow: (CGRect) -> CGRect) -> (String, Value)? {
    guard let b = body as? [String: Any], let t = b["t"] as? String else { return nil }
    if t == "end" { return ("webviews.linkHoverEnd", ["id": .string(id)]) }
    if t == "status" { return ("webviews.linkStatus", ["id": .string(id), "url": .string(statusURL(b["url"] as? String ?? ""))]) }
    guard t == "hover", let url = b["url"] as? String, let u = URL(string: url),
          let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme), u.host != nil else { return nil }
    func num(_ k: String) -> CGFloat { CGFloat((b[k] as? NSNumber)?.doubleValue ?? 0) }
    let r = toWindow(CGRect(x: num("x"), y: num("y"), width: num("w"), height: num("h")))
    let rect: Value = ["x": .double(Double(r.minX)), "y": .double(Double(r.minY)), "w": .double(Double(r.width)), "h": .double(Double(r.height))]
    return ("webviews.linkHover", ["id": .string(id), "url": .string(url), "text": .string(b["text"] as? String ?? ""),
                                   "rect": rect, "yield": .bool((b["yield"] as? Bool) ?? false)])
  }

  /// A status link as reported, or "" when it isn't a URL worth showing (no scheme, `javascript:`,
  /// or longer than 8 KB: a `data:` blob).
  public static func statusURL(_ url: String) -> String {
    guard !url.isEmpty, url.utf8.count <= 8192, let u = URL(string: url), let scheme = u.scheme?.lowercased(), scheme != "javascript" else { return "" }
    return url
  }

  /// Viewport rect (CSS px) -> the web view's own coordinates (points, top-left origin).
  public static func viewRect(_ css: CGRect, zoom: CGFloat, magnification: CGFloat) -> CGRect {
    let s = zoom * magnification
    return CGRect(x: css.minX * s, y: css.minY * s, width: css.width * s, height: css.height * s)
  }

  /// A rect in window base coordinates (bottom-left origin) -> top-left origin, given the
  /// window's content view height.
  public static func flip(_ r: CGRect, contentHeight: CGFloat) -> CGRect {
    CGRect(x: r.minX, y: contentHeight - r.maxY, width: r.width, height: r.height)
  }

  /// Full mapping for a live view.
  static func toWindow(_ css: CGRect, in w: WKWebView) -> CGRect {
    var local = viewRect(css, zoom: w.pageZoom, magnification: w.magnification)
    if !w.isFlipped { local.origin.y = w.bounds.height - local.maxY }
    let base = w.convert(local, to: nil)
    return flip(base, contentHeight: w.window?.contentView?.bounds.height ?? base.maxY)
  }
}
