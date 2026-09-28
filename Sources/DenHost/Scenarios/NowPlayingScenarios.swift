// Dev fixture: compiled only with the `Scenarios` package trait (on by default; release bundles leave it out).
#if Scenarios
import AppKit
import CordisValue

/// `--scenario` runs for the `media` plugin's now-playing dock and the `panels` plugin, in the
/// real app with the demo tabs and the real plugins.
///
/// - `nowPlaying`: two background tabs report now-playing media (the host event the page script
///   sends, with local artwork), the dock expands to show both, and the first tab's row shows its
///   hover playback buttons. Prints `scenario.ready dock=…`.
/// - `webPanel`: a local chat page (MockServices) added as a web panel through Settings' add
///   field, beside the selected tab. Prints `scenario.ready panel=…`.
@MainActor
public enum NowPlayingScenarios {
  public static let names = ["nowPlaying", "webPanel"]

  public static func apply(_ name: String, runtime rt: DenRuntime) {
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(800))
      if name == "webPanel" { webPanel(rt) } else { nowPlaying(rt) }
    }
  }

  /// A 96x96 square artwork PNG (a diagonal gradient) in the temporary folder.
  static func artwork(_ name: String, _ a: NSColor, _ b: NSColor) -> String {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("den-art-\(name).png").path
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 96, pixelsHigh: 96, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return path }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGradient(starting: a, ending: b)?.draw(in: NSRect(x: 0, y: 0, width: 96, height: 96), angle: -45)
    NSGraphicsContext.restoreGraphicsState()
    if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
    return path
  }

  static func tabIds(_ rt: DenRuntime) -> [String] {
    let l = rt.call("tabs", "list")
    var ids: [String] = []
    func walk(_ items: [Value]) { for i in items { if i.flag("folder") { walk(i.list("children")) } else if !i.flag("split") { ids.append(i.str("id")) } } }
    walk(l.list("pinned"))
    walk(l.list("today"))
    return ids
  }

  static func nowPlaying(_ rt: DenRuntime) {
    let selected = rt.call("tabs", "selected")["id"].string ?? ""
    let ids = tabIds(rt).filter { $0 != selected }
    guard ids.count >= 2 else { print("scenario.nowPlaying needs two tabs"); exit(1) }
    let a = artwork("a", NSColor(red: 0.98, green: 0.55, blue: 0.35, alpha: 1), NSColor(red: 0.55, green: 0.2, blue: 0.75, alpha: 1))
    let b = artwork("b", NSColor(red: 0.2, green: 0.7, blue: 0.9, alpha: 1), NSColor(red: 0.1, green: 0.25, blue: 0.5, alpha: 1))
    // What den's page script reports for a page playing music with Media Session metadata.
    rt.host.emit("webviews.nowPlaying", ["id": .string(ids[1]), "muted": false, "now": [
      "title": "Color in Practice", "artist": "Design Notes, episode 12", "album": "", "art": .string(b), "paused": true, "dur": 1840,
      "video": true, "acts": [],
    ]])
    rt.host.emit("webviews.nowPlaying", ["id": .string(ids[0]), "muted": false, "now": [
      "title": "Slow Morning", "artist": "Tidal Rooms", "album": "Low Tide", "art": .string(a), "paused": false, "dur": 214,
      "video": false, "acts": ["previoustrack", "nexttrack"],
    ]])
    rt.plugins.emit("ui.action", ["id": "media.more", "action": "click", "value": .null])
    // The first tab's row as if hovered: its playback buttons.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      func find(_ v: NSView) -> TabRowNode? {
        if let r = v as? TabRowNode, r.nodeId == ids[0] { return r }
        for s in v.subviews { if let r = find(s) { return r } }
        return nil
      }
      find(rt.ui.sidebarView)?.forceMedia = true
      let dock = rt.ui.sidebarView.dock
      print("scenario.ready dock=\(Int(dock.frame.height)) rows=\(dock.root?.node.list("children").count ?? 0) nowplaying=\(rt.nowPlaying.info.str("title"))")
    }
  }

  static let chat = """
    <!doctype html><html><head><meta name=viewport content="width=device-width,initial-scale=1"><title>Team Chat</title><style>
    :root{color-scheme:dark}body{margin:0;font:14px -apple-system;background:#1b1d22;color:#e8e8ea}
    header{padding:14px 16px;font-weight:600;border-bottom:1px solid #2c2f36}
    .m{display:flex;gap:10px;padding:10px 16px}.a{width:32px;height:32px;border-radius:8px;flex:none}
    .n{font-weight:600;font-size:13px}.t{color:#b9bcc4;line-height:1.4;margin-top:2px}
    footer{position:fixed;bottom:0;left:0;right:0;padding:12px 16px;background:#1b1d22}
    footer div{border:1px solid #3a3d45;border-radius:10px;padding:10px 12px;color:#80848d}</style></head>
    <body><header># design</header>
    <div class=m><div class=a style="background:#e9855a"></div><div><div class=n>Maya</div><div class=t>Pushed the new sidebar spacing. Can someone check it in dark mode?</div></div></div>
    <div class=m><div class=a style="background:#5a8de9"></div><div><div class=n>Theo</div><div class=t>Looks good here. The dock sits right above the space icons.</div></div></div>
    <div class=m><div class=a style="background:#6fbf73"></div><div><div class=n>Ines</div><div class=t>Shipping it after lunch.</div></div></div>
    <footer><div>Message #design</div></footer></body></html>
    """

  /// The local server stays up for the whole run.
  static var server: MockServices?

  static func webPanel(_ rt: DenRuntime) {
    let mock = MockServices()
    try? mock.start()
    server = mock
    mock.files = ["/chat.html": ("text/html; charset=utf-8", Data(chat.utf8))]
    rt.plugins.emit("settings.action", ["id": "panels", "key": "add", "value": .string(mock.base + "/chat.html")])
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      print("scenario.ready panel=\(rt.content.sideId ?? "-") width=\(Int(rt.content.sideIfLoaded?.frame.width ?? 0))")
    }
  }
}
#endif
