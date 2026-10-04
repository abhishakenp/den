// Dev fixture: compiled only with the `Scenarios` package trait (on by default; release bundles leave it out).
#if Scenarios
import AppKit
import CordisValue
import WebKit

/// The page context menu and the Web Inspector, for screenshots (scripts/snapshots.sh, MENUS=1:
/// they need a window on screen). A local page (MockServices, no network) opens as a tab, then:
/// - `pageMenuLink` / `pageMenuImage` / `pageMenuText` / `pageMenuPage`: a real right-click on its
///   link, image, selected text or empty space; the menu stays open (its own window, layer 101).
/// - `inspectorDocked`: the Web Inspector docked in the page's card (⌥⌘I), on the Elements tab.
@MainActor
public enum DevToolsScenarios {
  public static let names = ["pageMenuLink", "pageMenuImage", "pageMenuText", "pageMenuPage", "inspectorDocked"]

  static var mock: MockServices?

  static let page = """
    <!doctype html><title>Field Notes</title><meta name="color-scheme" content="light dark">
    <body style="font:17px/1.55 -apple-system;margin:0;padding:48px 64px;max-width:760px">
    <h1 style="font-size:32px;margin:0 0 12px">Field Notes</h1>
    <p id=t>Notes from a week of walking the coast, with maps and photos. Read the <a href="/guide">trail guide</a> before you go.</p>
    <img src="/photo.png" width=360 height=200 style="border-radius:12px;display:block;margin:24px 0">
    <p>Low tide is the best time to cross the rocks at the north end of the beach.</p>
    """

  static let photo: Data = {
    let img = NSImage(size: NSSize(width: 360, height: 200))
    img.lockFocus()
    NSGradient(colors: [NSColor(red: 0.35, green: 0.62, blue: 0.86, alpha: 1), NSColor(red: 0.93, green: 0.78, blue: 0.55, alpha: 1)])?
      .draw(in: NSRect(x: 0, y: 0, width: 360, height: 200), angle: 90)
    img.unlockFocus()
    return NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
  }()

  public static func apply(_ name: String, runtime rt: DenRuntime) {
    Task { @MainActor in await run(name, rt) }
  }

  static func run(_ name: String, _ rt: DenRuntime) async {
    let m = MockServices()
    try? m.start()
    mock = m
    m.page("/notes", page)
    m.files = ["/photo.png": ("image/png", photo)]
    let id = rt.call("tabs", "open", ["url": .string(m.base + "/notes")])["id"]
    rt.call("tabs", "select", ["id": id])
    guard let rec = rt.webviews.record(id.string ?? ""), await PopupScenarios.wait(20, { rec.webView?.isLoading == false && rec.webView?.url?.path == "/notes" }),
          let w = rec.webView as? DenWebView else { print("scenario.\(name) page never loaded"); return }
    rt.window.window.makeFirstResponder(w)
    try? await Task.sleep(for: .milliseconds(800))
    if name == "inspectorDocked" {
      DevTools.show(w)
      _ = await PopupScenarios.wait(15) { DevTools.dockedView(w) != nil }
      print("scenario.inspectorDocked open=\(DevTools.isOpen(w)) docked=\(DevTools.dockedView(w) != nil)")
      return
    }
    // Where to right-click, in the page's coordinates (CSS px from the top left).
    let js: String
    switch name {
    case "pageMenuLink": js = "var r=document.querySelector('a').getBoundingClientRect();[r.x+r.width/2,r.y+r.height/2]"
    case "pageMenuImage": js = "var r=document.querySelector('img').getBoundingClientRect();[r.x+r.width/2,r.y+r.height/2]"
    case "pageMenuText":
      js = "var p=document.getElementById('t'),r=document.createRange();r.setStart(p.firstChild,0);r.setEnd(p.firstChild,40);getSelection().removeAllRanges();getSelection().addRange(r);var b=r.getBoundingClientRect();[b.x+20,b.y+b.height/2]"
    default: js = "[700,560]"
    }
    guard let xy = (try? await w.evaluateJavaScript(js)) as? [NSNumber], xy.count == 2 else { print("scenario.\(name) no target"); return }
    let z = w.pageZoom
    rightClick(w, at: NSPoint(x: CGFloat(xy[0].doubleValue) * z, y: CGFloat(xy[1].doubleValue) * z))
    print("scenario.\(name) right-clicked")
  }

  /// A right-click WebKit handles as a real one (it asks the page, then shows its menu).
  static func rightClick(_ w: WKWebView, at p: NSPoint) {
    guard let win = w.window else { return }
    let wp = w.convert(p, to: nil)
    let target = w.hitTest(w.superview!.convert(wp, from: nil)) ?? w
    for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
      guard let e = NSEvent.mouseEvent(with: type, location: wp, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: type == .rightMouseDown ? 1 : 0) else { continue }
      if type == .rightMouseDown { target.rightMouseDown(with: e) } else { target.rightMouseUp(with: e) }
    }
  }
}
#endif
