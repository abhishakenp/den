import AppKit
import CordisValue
import Foundation
import Testing
import WebKit

@testable import DenHost

/// `webviews.watchLinks` (link under the pointer), `webviews.setMuted`, and `net.fetch {stopAfter}`.
@MainActor
@Suite(.serialized)
struct LinkHoverTests {
  func runtime() -> DenRuntime {
    _ = NSApplication.shared
    let rt = DenRuntime(storageRoot: FileManager.default.temporaryDirectory.appendingPathComponent("den-links-\(UUID())"))
    rt.webviews.configureHooks.append { _, c in c.preferences.inactiveSchedulingPolicy = .none }  // see ServiceTests.runtime
    rt.window.window.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 800), display: false)
    rt.window.window.contentView?.layoutSubtreeIfNeeded()
    return rt
  }

  func page(_ rt: DenRuntime) -> (String, WKWebView) {
    let id = rt.call("webviews", "create", ["url": "about:blank"])["id"].string!
    _ = rt.call("content", "show", ["panes": [.string(id)]])
    rt.content.releaseWebViews()
    return (id, rt.webviews.record(id)!.webView!)
  }

  func wait(_ cond: () -> Bool, ms: Int = 8000) async -> Bool {
    for _ in 0..<(ms / 50) {
      if cond() { return true }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return cond()
  }

  func hasLinkScript(_ w: WKWebView) -> Bool {
    w.configuration.userContentController.userScripts.contains { $0.source.contains("__denLinks") }
  }

  @Test func nothingIsInstalledUntilWatchLinksAndOffRemovesIt() {
    let rt = runtime()
    let (_, w) = page(rt)
    #expect(!hasLinkScript(w))  // zero cost at rest
    #expect(!rt.webviews.links.isInstalled(w))
    #expect(rt.call("webviews", "watchLinks", ["modifier": "shift", "yieldTo": [".mwe-popups"]]) == .ok)
    #expect(hasLinkScript(w))
    #expect(rt.webviews.links.isInstalled(w))
    #expect(rt.webviews.links.script.contains(".mwe-popups"))
    // A view created later gets it too.
    let (_, w2) = page(rt)
    #expect(hasLinkScript(w2))
    #expect(rt.call("webviews", "watchLinks", ["modifier": "off"]) == .ok)
    #expect(!hasLinkScript(w) && !hasLinkScript(w2))
    #expect(!rt.webviews.links.isInstalled(w))
    #expect(rt.call("webviews", "watchLinks", ["modifier": "bogus"]).isError)
  }

  @Test func messagesMapToEventsWithHostIdsAndHttpOnly() {
    let ident: (CGRect) -> CGRect = { $0.offsetBy(dx: 100, dy: 10) }
    let body: [String: Any] = ["t": "hover", "url": "https://github.com/a/b/pull/1", "text": "PR", "x": 5, "y": 6, "w": 50, "h": 18, "yield": true, "id": "evil"]
    let e = LinkHover.event(id: "tab-3", body: body, toWindow: ident)
    #expect(e?.0 == "webviews.linkHover")
    let v = e?.1 ?? .null
    #expect(v["id"] == "tab-3")  // never the page's
    #expect(v["url"] == "https://github.com/a/b/pull/1" && v["text"] == "PR" && v["yield"] == true)
    #expect(v["rect"]["x"].double == 105 && v["rect"]["y"].double == 16 && v["rect"]["w"].double == 50 && v["rect"]["h"].double == 18)
    for bad in ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,x", "not a url"] {
      #expect(LinkHover.event(id: "t", body: ["t": "hover", "url": bad], toWindow: ident) == nil)
    }
    #expect(LinkHover.event(id: "t", body: "nope", toWindow: ident) == nil)
    #expect(LinkHover.event(id: "t", body: ["t": "end"], toWindow: ident)?.0 == "webviews.linkHoverEnd")
  }

  @Test func rectMath() {
    let css = CGRect(x: 10, y: 20, width: 100, height: 16)
    #expect(LinkHover.viewRect(css, zoom: 1, magnification: 1) == css)
    #expect(LinkHover.viewRect(css, zoom: 1.25, magnification: 2) == CGRect(x: 25, y: 50, width: 250, height: 40))
    // Window base coords (bottom-left) -> top-left origin.
    #expect(LinkHover.flip(CGRect(x: 300, y: 700, width: 80, height: 20), contentHeight: 800) == CGRect(x: 300, y: 80, width: 80, height: 20))
  }

  @Test func shiftHoverOverARealLinkEmitsAndReleaseEnds() async {
    let rt = runtime()
    let (id, w) = page(rt)
    var got: [(String, Value)] = []
    rt.host.on("webviews.linkHover") { got.append(("hover", $0)) }
    rt.host.on("webviews.linkHoverEnd") { got.append(("end", $0)) }
    #expect(rt.call("webviews", "watchLinks", ["modifier": "shift"]) == .ok)
    var loaded = false
    w.loadHTMLString("<style>body{margin:0}a{position:absolute;left:40px;top:30px;font-size:20px}</style><a id=l href='https://example.org/x'>Example</a><a id=f href='#top'>top</a>",
                     baseURL: URL(string: "https://page.test/"))
    // The script is added at document end in the isolated world (of the loaded page, not the
    // about:blank it replaced).
    for _ in 0..<160 where !loaded {
      try? await Task.sleep(for: .milliseconds(50))
      let r = try? await w.evaluateJavaScript("!!window.__denLinks && !!document.getElementById('l')", in: nil, contentWorld: LinkHover.world)
      loaded = (r as? Bool) == true
    }
    #expect(loaded)
    func js(_ s: String) async { _ = try? await w.evaluateJavaScript(s, in: nil, contentWorld: .page) }
    // Plain hover: nothing in shift mode.
    await js("document.getElementById('l').dispatchEvent(new MouseEvent('mouseover',{bubbles:true}))")
    try? await Task.sleep(for: .milliseconds(300))
    #expect(got.isEmpty)
    // Shift goes down over the link: reported once.
    await js("window.dispatchEvent(new KeyboardEvent('keydown',{key:'Shift',shiftKey:true}))")
    #expect(await wait { got.count == 1 })
    #expect(got.first?.0 == "hover")
    let v = got.first?.1 ?? .null
    #expect(v["id"] == .string(id))
    #expect(v["url"] == "https://example.org/x" && v["text"] == "Example" && v["yield"] == false)
    #expect((v["rect"]["w"].double ?? 0) > 10 && (v["rect"]["h"].double ?? 0) > 5)
    await js("document.getElementById('l').dispatchEvent(new MouseEvent('mouseover',{bubbles:true,shiftKey:true}))")
    try? await Task.sleep(for: .milliseconds(200))
    #expect(got.count == 1)  // same link: no re-emit
    await js("window.dispatchEvent(new KeyboardEvent('keyup',{key:'Shift'}))")
    #expect(await wait { got.count == 2 })
    #expect(got.last?.0 == "end" && got.last?.1["id"] == .string(id))
    // Same-page fragment links never report.
    await js("document.getElementById('f').dispatchEvent(new MouseEvent('mouseover',{bubbles:true,shiftKey:true}))")
    try? await Task.sleep(for: .milliseconds(300))
    #expect(got.count == 2)
    #expect(rt.call("webviews", "watchLinks", ["modifier": "off"]) == .ok)
    let gone = try? await w.evaluateJavaScript("!!window.__denLinks", in: nil, contentWorld: LinkHover.world)
    #expect((gone as? Bool) == false)
  }

  @Test func setMutedMutesTheMediaAndGetReportsIt() async {
    let rt = runtime()
    let (id, w) = page(rt)
    w.loadHTMLString("<audio id=a src='data:audio/wav;base64,UklGRiQAAABXQVZFZm10IBAAAAABAAEAQB8AAIA+AAACABAAZGF0YQAAAAA='></audio>", baseURL: URL(string: "https://media.test/"))
    _ = await wait { !w.isLoading && w.url != nil }
    #expect(rt.call("webviews", "get", ["id": .string(id)])["muted"] == false)
    #expect(rt.call("webviews", "setMuted", ["id": .string(id), "muted": true]) == .ok)
    #expect(rt.call("webviews", "get", ["id": .string(id)])["muted"] == true)
    var muted = false
    for _ in 0..<60 where !muted {
      muted = (try? await w.evaluateJavaScript("document.getElementById('a').muted", in: nil, contentWorld: .page)) as? Bool == true
      if !muted { try? await Task.sleep(for: .milliseconds(50)) }
    }
    #expect(muted)
    #expect(rt.call("webviews", "setMuted", ["id": .string(id), "muted": false]) == .ok)
    #expect(rt.call("webviews", "get", ["id": .string(id)])["muted"] == false)
    #expect(rt.call("webviews", "setMuted", ["id": "nope", "muted": true]).isError)
  }

  // MARK: net.fetch {stopAfter}

  final class Stub: URLProtocol {
    nonisolated(unsafe) static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
      let r = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"])!
      client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
      // In chunks, like a real stream.
      var i = 0
      while i < Self.body.count {
        client?.urlProtocol(self, didLoad: Self.body.subdata(in: i..<min(Self.body.count, i + 512)))
        i += 512
      }
      client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
  }

  func session() -> URLSession {
    let c = URLSessionConfiguration.ephemeral
    c.protocolClasses = [Stub.self]
    return URLSession(configuration: c)
  }

  @Test func stopAfterReadsOnlyTheHead() async {
    let head = "<html><HEAD><title>Hi</title><meta property=\"og:title\" content=\"Hi\"></Head>"
    Stub.body = Data((head + "<body>" + String(repeating: "x", count: 100_000) + "</body></html>").utf8)
    let req = URLRequest(url: URL(string: "https://og.test/page")!)
    let r = await NetService.run(session(), req, maxBytes: 5 << 20, asJSON: false, stopAfter: "</head>", allowed: { _ in true })
    #expect(r["ok"] == true && r["status"] == 200 && r["truncated"] == true)
    #expect(r.str("text") == head)
    // Cut at maxBytes when there's no marker: still ok, truncated.
    Stub.body = Data(String(repeating: "y", count: 10_000).utf8)
    let r2 = await NetService.run(session(), req, maxBytes: 2048, asJSON: false, stopAfter: "</head>", allowed: { _ in true })
    #expect(r2["ok"] == true && r2["truncated"] == true && r2.str("text").utf8.count == 2048)
    // A short body without the marker: whole, not truncated.
    Stub.body = Data("<title>short</title>".utf8)
    let r3 = await NetService.run(session(), req, maxBytes: 2048, asJSON: false, stopAfter: "</head>", allowed: { _ in true })
    #expect(r3["truncated"] == false && r3.str("text") == "<title>short</title>")
    // Without stopAfter, unchanged: too large is an error and there's no `truncated`.
    Stub.body = Data(String(repeating: "z", count: 4000).utf8)
    let r4 = await NetService.run(session(), req, maxBytes: 2048, asJSON: false, allowed: { _ in true })
    #expect(r4["ok"] == false && r4["error"] == "too large")
    Stub.body = Data("small".utf8)
    let r5 = await NetService.run(session(), req, maxBytes: 2048, asJSON: false, allowed: { _ in true })
    #expect(r5["ok"] == true && r5["truncated"].isNull && r5.str("text") == "small")
  }

  @Test func endsWithIsCaseInsensitive() {
    #expect(NetService.endsWith(Data("abc</HeAd>".utf8), Array("</head>".utf8)))
    #expect(!NetService.endsWith(Data("abc</head> ".utf8), Array("</head>".utf8)))
    #expect(!NetService.endsWith(Data("d>".utf8), Array("</head>".utf8)))
  }
}
