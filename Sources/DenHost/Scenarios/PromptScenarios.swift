import AppKit
import CordisValue
import WebKit

/// `--scenario` states for web page prompts and error pages (WebPrompts.swift, WebErrorPage.swift),
/// on the host's sample sidebar. No network: the DNS failure uses a `.invalid` host, which never
/// resolves, and "offline" loads den's page for that error directly.
@MainActor
enum PromptScenarios {
  static let names = ["jsAlert", "jsConfirm", "jsPrompt", "fileUpload", "httpAuth", "permissionCamera", "errorHost", "errorOffline", "errorSecure"]

  static func apply(_ name: String, runtime rt: DenRuntime, appearance: String) -> NSWindow? {
    guard names.contains(name) else { return nil }
    HostScenarios.seedSidebar(rt, appearance: appearance)
    let id = HostScenarios.page(rt, id: "t1", title: "Example Domain", host: "example.com",
                                body: "This page is local HTML rendered by den's scenario runner, so snapshots never need the network.")
    rt.call("content", "show", ["panes": [.string(id)]])
    rt.content.releaseWebViews()
    guard let web = rt.webviews.record(id)?.webView, let prompts = rt.webviews.prompts else { return rt.window.window }
    // A page's alert() keeps its WebContent process waiting, so it can't draw a snapshot until the
    // dialog is answered: these scenarios open the same dialogs WebKit would ask for, directly.
    // (WebPromptsTests drives the real alert/confirm/prompt through JavaScript.)
    func later(_ f: @escaping @MainActor () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { MainActor.assumeIsolated(f) } }
    func errorPage(_ code: Int, _ url: String) {
      let u = URL(string: url)!
      if let p = WebErrorPage.page(for: NSError(domain: NSURLErrorDomain, code: code), url: u) { web.loadSimulatedRequest(URLRequest(url: u), responseHTML: WebErrorPage.html(p, url: u, colors: prompts.errorPageColors)) }
    }
    switch name {
    case "jsAlert": later { prompts.alert("Your changes were saved.", frame: nil, webView: web) {} }
    case "jsConfirm": later { prompts.confirm("Leave this page? Changes you made may not be saved.", frame: nil, webView: web) { _ in } }
    case "jsPrompt": later { prompts.prompt("What should we call this board?", defaultText: "Roadmap", frame: nil, webView: web) { _ in } }
    case "httpAuth":
      let space = URLProtectionSpace(host: "intranet.example.com", port: 443, protocol: "https", realm: "Team Wiki", authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
      prompts.signIn(space, previousFailures: 0, proposedUser: nil, webView: web) { _ in }
    case "permissionCamera":
      prompts.enqueue(WebPrompts.mediaTree(host: "meet.example.com", devices: ["camera", "microphone"]), web, answer: { _, _ in }, cancel: {})
    case "fileUpload":
      // Self-check in the real app (prints scenario.fileUpload … ok=true|false, exits): a real click
      // on <input type=file multiple> opens the panel as a sheet; Cancel reaches the page as `cancel`.
      web.loadHTMLString("<style>body{margin:0}input{display:block;width:100vw;height:100vh}</style><input type=file multiple oncancel=\"document.title='cancelled'\">",
                         baseURL: URL(string: "https://upload.example/"))
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        let win = rt.window.window
        let p = web.convert(NSPoint(x: web.bounds.midX, y: web.bounds.midY), to: nil)
        guard let target = web.hitTest(web.superview!.convert(p, from: nil)), target.isDescendant(of: web) else { print("scenario.fileUpload ok=false (no hit)"); exit(1) }
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
          let e = NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber,
                                     context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
          if t == .leftMouseDown { target.mouseDown(with: e) } else { target.mouseUp(with: e) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
          guard let panel = win.attachedSheet as? NSOpenPanel else { print("scenario.fileUpload ok=false (no sheet)"); exit(1) }
          let multiple = panel.allowsMultipleSelection, dirs = panel.canChooseDirectories
          panel.cancel(nil)
          DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let ok = multiple && !dirs && web.title == "cancelled" && win.attachedSheet == nil
            print("scenario.fileUpload sheet=true multiple=\(multiple) directories=\(dirs) title=\(web.title ?? "") ok=\(ok)")
            exit(ok ? 0 : 1)
          }
        }
      }
    case "errorHost": rt.call("webviews", "navigate", ["id": .string(id), "url": "https://den-nonexistent.invalid/"])
    case "errorOffline": later { errorPage(NSURLErrorNotConnectedToInternet, "https://news.ycombinator.com/") }
    case "errorSecure": later { errorPage(NSURLErrorServerCertificateUntrusted, "https://self-signed.example.com/") }
    default: break
    }
    return rt.window.window
  }
}
