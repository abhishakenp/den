import AppKit
import CordisValue
import Foundation
import DenTestSupport
import Testing
import WebKit

@testable import DenHost

/// Page prompts (alert/confirm/prompt, HTTP sign-in, camera/mic), the file panel and error pages,
/// through real WKWebViews and WebKit's own delegate calls.
@MainActor
@Suite(.serialized, .watchdog)
struct WebPromptsTests {
  func runtime() -> DenRuntime {
    _ = NSApplication.shared
    let rt = DenRuntime(storageRoot: FileManager.default.temporaryDirectory.appendingPathComponent("den-prompts-\(UUID())"))
    rt.webviews.configureHooks.append { _, c in c.preferences.inactiveSchedulingPolicy = .none }  // see ServiceTests.runtime
    rt.window.window.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 800), display: false)
    rt.window.window.contentView?.layoutSubtreeIfNeeded()
    return rt
  }

  /// A shown, live web view.
  func page(_ rt: DenRuntime, url: String = "about:blank", profile: String = "default") -> (String, WKWebView) {
    let id = rt.call("webviews", "create", ["url": .string(url), "profile": .string(profile)])["id"].string!
    _ = rt.call("content", "show", ["panes": [.string(id)]])
    rt.content.releaseWebViews()
    return (id, rt.webviews.record(id)!.webView!)
  }

  func wait(_ cond: () -> Bool, ms: Int = 20_000, line: UInt = #line) async -> Bool {
    await Wait.until("a condition", seconds: Double(ms) / 1000, line: line) { cond() }
  }

  @Test func alertConfirmPromptAreHostDialogsAndAnswerThePage() async throws {
    let rt = runtime()
    let (_, web) = page(rt)
    let p = try #require(rt.webviews.prompts)
    web.loadHTMLString("<script>setTimeout(function(){alert('Hi there');var c=confirm('Sure?');var t=prompt('Name?','den');document.title=[c,t].join('|')},0)</script>", baseURL: URL(string: "https://example.com/"))
    #expect(await wait { p.visible })
    #expect(p.current?.tree["title"] == "example.com says" && p.current?.tree["message"] == "Hi there")
    // The dialog is drawn in den's style in the overlay layer, the app keeps running.
    #expect(rt.window.overlays.subviews.contains { $0 is DialogView })
    p.press("ok")
    #expect(await wait { p.current?.tree["message"] == "Sure?" })
    #expect((p.current?.tree["buttons"].array ?? []).map { $0.str("id") } == ["cancel", "ok"])
    p.press("ok")
    #expect(await wait { p.current?.tree["message"] == "Name?" })
    #expect(p.current?.tree["fields"][0]["value"] == "den")
    let d = try #require(rt.window.overlays.subviews.compactMap { $0 as? DialogView }.first)
    #expect(d.fields.count == 1 && d.window?.firstResponder === d.fields[0].currentEditor())
    // Typing and pressing the default button through the dialog's own path.
    d.fields[0].stringValue = "Ada"
    d.pressed(1)
    #expect(await wait { web.title == "true|Ada" })
    #expect(!p.visible && !rt.window.overlays.subviews.contains { $0 is DialogView })

    // Cancel answers false / null.
    web.evaluateJavaScript("setTimeout(function(){document.title=String(confirm('x'))+'|'+String(prompt('y'))},0)", completionHandler: nil)
    #expect(await wait { p.visible })
    p.press("cancel")
    #expect(await wait { p.current?.tree["message"] == "y" })
    p.press("cancel")
    #expect(await wait { web.title == "false|null" })
  }

  @Test func closingThePageAnswersItsPendingDialog() async throws {
    let rt = runtime()
    let (id, web) = page(rt)
    let p = try #require(rt.webviews.prompts)
    web.loadHTMLString("<script>setTimeout(function(){alert('a')},0)</script>", baseURL: URL(string: "https://a.test/"))
    #expect(await wait { p.visible })
    rt.call("webviews", "close", ["id": .string(id)])
    #expect(!p.visible && p.queue.isEmpty)
  }

  @Test func httpBasicSignIn() async throws {
    let mock = MockServices()
    try mock.start()
    defer { mock.stop() }
    let rt = runtime()
    let (_, web) = page(rt, profile: "private")
    let p = try #require(rt.webviews.prompts)
    web.load(URLRequest(url: URL(string: mock.base + "/basic-auth")!))
    #expect(await wait { p.visible })
    #expect(p.current?.tree["title"] == "Sign in to 127.0.0.1")
    #expect(p.current?.tree["message"].string?.contains("“den test”") == true)
    #expect(p.current?.tree["message"].string?.contains("unencrypted") == true)  // plain http
    #expect((p.current?.tree["fields"].array ?? []).map { $0.str("id") } == ["user", "password"])
    #expect(p.current?.tree["fields"][1]["secure"] == true)
    // A wrong password asks again, saying so; the right one signs in.
    p.press("signIn", fields: ["user": "den", "password": "nope"])
    #expect(await wait { p.current?.tree["message"].string?.hasPrefix("That didn’t work.") == true })
    p.press("signIn", fields: ["user": "den", "password": "secret"])
    #expect(await wait { web.title == "Signed in" })

    // Cancel shows the server's own 401 page.
    let rt2 = runtime()
    let (_, web2) = page(rt2, profile: "private")
    web2.load(URLRequest(url: URL(string: mock.base + "/basic-auth?again")!))
    #expect(await wait { rt2.webviews.prompts!.visible })
    rt2.webviews.prompts!.press("cancel")
    #expect(await wait { web2.title == "Unauthorized" })
  }

  @Test func cameraPermissionIsAskedOncePerOriginForTheSession() async throws {
    let rt = runtime()
    let (_, web) = page(rt)
    let p = try #require(rt.webviews.prompts)
    // What WebKit calls when a page asks for getUserMedia (WKSecurityOrigin can't be built directly,
    // so the frame's origin comes from a real page).
    web.loadHTMLString("<p>cam</p>", baseURL: URL(string: "https://meet.example/"))
    #expect(await wait { !web.isLoading && web.url?.host == "meet.example" })
    let origin = try #require(await frameOrigin(web))
    var answers: [WKPermissionDecision] = []
    p.media(origin, type: .camera, webView: web) { answers.append($0) }
    #expect(p.current?.tree["title"] == "Allow meet.example to use your camera?")
    #expect((p.current?.tree["buttons"].array ?? []).map { $0.str("id") } == ["deny", "allow"])
    p.press("allow")
    #expect(answers == [.grant])
    // Remembered: no second dialog for the camera; the microphone is asked separately.
    p.media(origin, type: .camera, webView: web) { answers.append($0) }
    #expect(answers == [.grant, .grant] && !p.visible)
    p.media(origin, type: .cameraAndMicrophone, webView: web) { answers.append($0) }
    #expect(p.current?.tree["title"] == "Allow meet.example to use your camera and microphone?")
    p.press("deny")
    #expect(answers.last == .deny)
    p.media(origin, type: .microphone, webView: web) { answers.append($0) }
    #expect(answers.last == .deny && !p.visible)
  }

  /// The main frame's security origin, captured from a real script message.
  func frameOrigin(_ web: WKWebView) async -> WKSecurityOrigin? {
    final class Catch: NSObject, WKScriptMessageHandler {
      var origin: WKSecurityOrigin?
      func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { origin = m.frameInfo.securityOrigin }
    }
    let c = Catch()
    web.configuration.userContentController.add(c, name: "denOrigin")
    defer { web.configuration.userContentController.removeScriptMessageHandler(forName: "denOrigin") }
    _ = await Wait.js(web, "webkit.messageHandlers.denOrigin.postMessage(1); 1")
    _ = await wait({ c.origin != nil }, ms: 3000)
    return c.origin
  }

  @Test func filePanelFollowsTheInputAndCancelAnswersNil() async throws {
    let one = WebViewsService.openPanel(multiple: false, directories: false)
    #expect(one.canChooseFiles && !one.canChooseDirectories && !one.allowsMultipleSelection)
    let many = WebViewsService.openPanel(multiple: true, directories: true)
    #expect(many.allowsMultipleSelection && many.canChooseDirectories)

    // A real click on <input type=file multiple>: WebKit asks for the panel, den shows it as a sheet.
    let rt = runtime()
    // Nothing to offer in the upload picker (DownloadsTests covers it): straight to the panel.
    rt.webviews.uploadPicker?.fixed = { _ in [] }
    rt.window.window.orderFront(nil)
    let (_, web) = page(rt)
    web.loadHTMLString("<style>body{margin:0}input{display:block;width:100vw;height:100vh}</style><input id=f type=file multiple onchange=\"document.title='files:'+this.files.length\" oncancel=\"document.title='cancelled'\">", baseURL: URL(string: "https://upload.test/"))
    #expect(await wait { !web.isLoading && web.url?.host == "upload.test" })
    try await Task.sleep(for: .milliseconds(300))
    let win = try #require(web.window)
    let p = web.convert(NSPoint(x: web.bounds.midX, y: web.bounds.midY), to: nil)
    let target = try #require(web.hitTest(web.superview!.convert(p, from: nil)))
    #expect(target.isDescendant(of: web))
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      let e = try #require(NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
      if type == .leftMouseDown { target.mouseDown(with: e) } else { target.mouseUp(with: e) }
    }
    #expect(await wait { win.attachedSheet is NSOpenPanel })
    let panel = try #require(win.attachedSheet as? NSOpenPanel)
    #expect(panel.allowsMultipleSelection && !panel.canChooseDirectories)
    // The panel is left open: ending an open panel stops the main run loop, which ends swift-testing's
    // process (not NSApp.run's). Cancel → page is checked in the real app: `--scenario fileUpload`.
  }

  @Test func errorPagesForUnreachableSitesKeepTheURLAndRetry() async throws {
    let rt = runtime()
    let (id, web) = page(rt)
    // DNS failure (.invalid never resolves).
    rt.call("webviews", "navigate", ["id": .string(id), "url": "http://den-nonexistent.invalid/path"])
    #expect(await wait { web.title == "Can’t find den-nonexistent.invalid" })
    #expect(web.url?.absoluteString == "http://den-nonexistent.invalid/path")
    #expect(rt.webviews.record(id)?.url == "http://den-nonexistent.invalid/path")
    let kind = await Wait.js(web, "document.body.dataset.denError")
    #expect(kind as? String == "host")
    // Try Again reloads the real URL (and fails the same way, back to the error page).
    let before = web.backForwardList.backList.count
    _ = await Wait.js(web, "document.getElementById('retry').click(); 1")
    try await Task.sleep(for: .milliseconds(300))
    #expect(await wait { !web.isLoading && web.title == "Can’t find den-nonexistent.invalid" })
    #expect(web.backForwardList.backList.count == before)
    // Connection refused (a closed local port).
    let closed = MockServices()
    try closed.start()
    closed.stop()
    try await Task.sleep(for: .milliseconds(200))
    rt.call("webviews", "navigate", ["id": .string(id), "url": .string(closed.base + "/")])
    #expect(await wait { web.title == "Can’t connect to 127.0.0.1" })
  }

  @Test func errorPageKinds() {
    func kind(_ code: Int) -> String? { WebErrorPage.page(for: NSError(domain: NSURLErrorDomain, code: code), url: URL(string: "https://x.test/"))?.kind }
    #expect(kind(NSURLErrorNotConnectedToInternet) == "offline")
    #expect(kind(NSURLErrorCannotFindHost) == "host")
    #expect(kind(NSURLErrorServerCertificateUntrusted) == "secure")
    #expect(kind(NSURLErrorServerCertificateHasBadDate) == "secure")
    #expect(kind(NSURLErrorTimedOut) == "timeout")
    #expect(kind(NSURLErrorCancelled) == nil)
    #expect(WebErrorPage.page(for: NSError(domain: "WebKitErrorDomain", code: 102), url: nil) == nil)
    #expect(WebErrorPage.escape("<b>&\"") == "&lt;b&gt;&amp;&quot;")
    let html = WebErrorPage.html(WebErrorPage.page(for: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost), url: URL(string: "https://x.test/")!)!, url: URL(string: "https://x.test/"))
    #expect(!html.contains("<script") && html.contains("prefers-color-scheme:dark") && html.contains("Can’t find x.test"))
    // With the space's palette, the page uses its colors instead of the neutral fallback.
    let c = WebErrorPage.Colors(background: WebErrorPage.css(NSColor(srgbRed: 0x15 / 255, green: 0x1C / 255, blue: 0x30 / 255, alpha: 1)), text: "rgba(255,255,255,0.800)",
                                secondary: "rgba(255,255,255,0.330)", accent: "rgba(49,57,251,1.000)", onAccent: "#fff", dark: true)
    #expect(c.background == "rgba(21,28,48,1.000)")
    let themed = WebErrorPage.html(WebErrorPage.page(for: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut), url: nil)!, url: nil, colors: c)
    #expect(themed.contains("--bg:rgba(21,28,48,1.000)") && themed.contains("color-scheme:dark") && !themed.contains("prefers-color-scheme:dark"))
  }

  /// "View on the Web Archive": only where the site is missing, down or silent, and only for web URLs.
  @Test func errorPageArchiveLink() {
    func html(_ code: Int, _ url: String) -> String {
      let u = URL(string: url)!
      return WebErrorPage.html(WebErrorPage.page(for: NSError(domain: NSURLErrorDomain, code: code), url: u)!, url: u)
    }
    let link = "href=\"https://web.archive.org/web/2/https://x.test/a?b=1&amp;c=2\""
    #expect(html(NSURLErrorCannotFindHost, "https://x.test/a?b=1&c=2").contains(link))
    #expect(html(NSURLErrorTimedOut, "https://x.test/a?b=1&c=2").contains(link))
    #expect(html(NSURLErrorCannotConnectToHost, "https://x.test/a?b=1&c=2").contains(link))
    #expect(html(NSURLErrorCannotFindHost, "http://x.test/").contains("https://web.archive.org/web/2/http://x.test/"))
    for code in [NSURLErrorNotConnectedToInternet, NSURLErrorServerCertificateUntrusted] {
      #expect(!html(code, "https://x.test/").contains("web.archive.org"))
    }
    #expect(!html(NSURLErrorCannotFindHost, "file:///tmp/x.html").contains("web.archive.org"))
    #expect(!WebErrorPage.html(WebErrorPage.crashed, url: URL(string: "https://x.test/")).contains("web.archive.org"))
  }

  /// A real failed navigation (a `.invalid` host never resolves) shows the link to the archive's copy.
  @Test func errorPageArchiveLinkInARealPage() async {
    let rt = runtime()
    let (id, web) = page(rt)
    rt.call("webviews", "navigate", ["id": .string(id), "url": "https://den-nonexistent.invalid/page"])
    #expect(await wait { web.title == "Can’t find den-nonexistent.invalid" })
    let href = try? await web.evaluateJavaScript("document.getElementById('archive').href") as? String
    #expect(href == "https://web.archive.org/web/2/https://den-nonexistent.invalid/page")
    _ = rt.call("webviews", "close", ["id": .string(id)])
  }
}
