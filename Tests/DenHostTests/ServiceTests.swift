import AppKit
import CordisValue
import Foundation
import Testing
import WebKit

@testable import DenHost

/// Exercises the host services through their `(method, args) -> Value` handlers, exactly as a
/// plugin would through the C ABI.
@MainActor
@Suite(.serialized)
struct ServiceTests {
  static func runtime() -> DenRuntime {
    _ = NSApplication.shared
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("den-svc-\(UUID())")
    let rt = DenRuntime(storageRoot: dir)
    rt.window.window.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 800), display: false)
    rt.window.window.contentView?.layoutSubtreeIfNeeded()
    return rt
  }

  @Test func webviewsAreLazyUntilShown() {
    let rt = Self.runtime()
    let id = rt.call("webviews", "create", ["url": "https://example.com"])["id"].string!
    #expect(rt.call("webviews", "get", ["id": .string(id)])["live"] == false)
    #expect(rt.webviews.record(id)?.webView == nil)
    #expect(rt.call("content", "show", ["panes": [.string(id)]]) == .ok)
    #expect(rt.call("webviews", "get", ["id": .string(id)])["live"] == true)
    #expect(rt.webviews.record(id)?.webView?.superview != nil)
    #expect(rt.call("webviews", "create", ["id": .string(id)]).isError)
    #expect(rt.call("webviews", "navigate", ["id": "nope", "url": "https://a.b"]).isError)
    #expect(rt.call("webviews", "list") == [.string(id)])
    #expect(rt.call("webviews", "close", ["id": .string(id)]) == .ok)
    #expect(rt.call("webviews", "list") == [])
    #expect(rt.call("content", "get")["panes"] == [])
  }

  @Test func splitLayoutPlacesCardsInsideContentArea() {
    let rt = Self.runtime()
    let ids = (0..<3).map { _ in rt.call("webviews", "create")["id"] }
    _ = rt.call("content", "show", ["panes": .array(ids), "orientation": "grid"])
    #expect(rt.call("content", "get")["orientation"] == "grid")
    let area = rt.window.contentArea.bounds
    let frames = ids.compactMap { rt.webviews.record($0.string!)?.webView?.superview?.superview?.frame }
    #expect(frames.count == 3)
    for f in frames { #expect(area.contains(f)) }
    #expect(frames[0].height == area.height)  // grid of 3: tall left pane
    // Content card spec: flush to the sidebar, 10 pt inset top/right/bottom.
    let cf = rt.window.contentFrame
    #expect(cf.minX == Tokens.sidebarDefaultWidth && cf.minY == 10)
    #expect(rt.window.root.bounds.width - cf.maxX == 10)
  }

  @Test func windowServiceThemeAndSidebar() {
    let rt = Self.runtime()
    #expect(rt.call("window", "setTheme", ["colors": ["#ff0000", "#00ff00"], "grain": 0.5, "appearance": "dark"]) == .ok)
    #expect(rt.window.currentTheme.colors.count == 2)
    #expect(rt.window.window.appearance?.name == .darkAqua)
    _ = rt.call("window", "setSidebar", ["hidden": true, "animated": false])
    #expect(rt.call("window", "get")["hidden"] == true)
    #expect(rt.window.contentFrame.minX == 10)
    _ = rt.call("window", "toggleSidebar", ["animated": false])
    _ = rt.call("window", "setSidebar", ["width": 9999])
    #expect(rt.call("window", "get")["width"] == .double(Double(Tokens.sidebarMaxWidth)))
  }

  @Test func uiRendersTreesAndReusesViews() {
    let rt = Self.runtime()
    var actions: [Value] = []
    rt.host.on("ui.action") { actions.append($0) }
    let tree: (String) -> Value = { title in
      ["type": "list", "children": [
        ["type": "tabRow", "id": "a", "title": .string(title), "icon": "sf:globe", "selected": true],
        ["type": "tabRow", "id": "b", "title": "B"],
        ["type": "divider", "id": "d", "action": "Clear"],
        ["type": "folder", "id": "f", "title": "F", "open": true, "children": [["type": "tabRow", "id": "c", "title": "C"]]],
      ]]
    }
    #expect(rt.call("ui", "set", ["slot": "sidebar.today", "tree": tree("A")]) == .ok)
    let slot = rt.ui.sidebarView.slot("sidebar.today", page: 0)!
    let list = slot.root as! StackNode
    #expect(list.kids.count == 4)
    let firstRow = list.kids[0]
    _ = rt.call("ui", "set", ["slot": "sidebar.today", "tree": tree("A2")])
    #expect((slot.root as! StackNode).kids[0] === firstRow)  // reused by key
    #expect((firstRow as! TabRowNode).label.stringValue == "A2")
    #expect(list.height(for: 212) == 4 * Tokens.tabRowHeight + Tokens.dividerHeight)  // folder = header + 1 child
    (firstRow as! TabRowNode).emit("close")
    #expect(actions.last?["id"] == "a" && actions.last?["action"] == "close")
    #expect(rt.call("ui", "set", ["slot": "nope", "tree": nil]).isError)
    // Pages
    _ = rt.call("ui", "setPages", ["count": 3])
    _ = rt.call("ui", "set", ["slot": "sidebar.spaceHeader", "page": 2, "tree": ["type": "spaceTitle", "id": "s", "title": "Work"]])
    #expect(rt.call("ui", "get")["pages"] == 3)
    _ = rt.call("ui", "showPage", ["page": 2, "animated": false])
    #expect(rt.call("ui", "get")["page"] == 2)
  }

  @Test func overlaysOpenAndClose() {
    let rt = Self.runtime()
    _ = rt.call("ui", "set", ["slot": "overlay.commandBar", "tree": ["type": "commandBar", "id": "cb", "query": "x", "sections": [["rows": [["id": "r1", "title": "One"], ["id": "r2", "title": "Two"]]]]]])
    #expect(rt.call("ui", "get")["overlays"] == ["overlay.commandBar"])
    // Spec §2: centered on the window, 766 wide.
    let f = rt.ui.commandBar.frame
    #expect(f.width == 766 && abs(f.midX - rt.window.root.bounds.midX) <= 1)
    var got: [Value] = []
    rt.host.on("ui.action") { got.append($0) }
    rt.ui.commandBar.move(1)
    #expect(got.last?["value"]["row"] == "r2")
    _ = rt.call("ui", "set", ["slot": "overlay.commandBar", "tree": nil])
    #expect(rt.call("ui", "get")["overlays"] == [])
    _ = rt.call("ui", "set", ["slot": "dialog", "tree": ["type": "dialog", "id": "q", "title": "Quit?", "buttons": [["id": "c", "title": "Cancel", "style": "cancel"], ["id": "ok", "title": "Quit", "style": "default"]]]])
    rt.ui.dialog.cancelOperation(nil)
    #expect(got.last?["id"] == "q" && got.last?["value"]["button"] == "c")
    _ = rt.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": "Hi"]])
    #expect(rt.ui.toasts.count == 1)
    // Spec §6: anchored to the window's top-right.
    #expect(rt.ui.toasts[0].frame.maxX > rt.window.root.bounds.width - 40 && rt.ui.toasts[0].frame.minY < 40)
  }

  @Test func keysBindThroughTheMainMenu() {
    let rt = Self.runtime()
    NSApp.mainMenu = NSMenu()
    MainMenu.install()
    var fired: [Value] = []
    rt.host.on("tabs.new") { fired.append($0) }
    #expect(rt.call("keys", "bind", ["chord": "cmd+t", "event": "tabs.new", "title": "New Tab", "menu": "File"]) == .ok)
    #expect(rt.call("keys", "bind", ["chord": "hyper+t", "event": "x"]).isError)
    let item = MainMenu.menu(named: "File").items.first { $0.title == "New Tab" }!
    #expect(item.keyEquivalent == "t" && item.keyEquivalentModifierMask == .command)
    rt.keys.fire(item)
    #expect(fired.count == 1 && fired[0]["chord"] == "cmd+t")
    _ = rt.call("keys", "unbind", ["chord": "cmd+t"])
    #expect(!MainMenu.menu(named: "File").items.contains { $0.title == "New Tab" })
  }

  @Test func appInterceptsQuitAndBuffersURLs() {
    let rt = Self.runtime()
    #expect(rt.app.shouldTerminate() == .terminateNow)  // not intercepting
    _ = rt.call("app", "interceptQuit", ["enabled": true])
    #expect(rt.app.shouldTerminate() == .terminateNow)  // no listener yet
    var asked = 0
    rt.host.on("app.quitRequested") { _ in asked += 1 }
    #expect(rt.app.shouldTerminate() == .terminateLater)
    #expect(asked == 1)
    rt.app.open([URL(string: "https://example.com")!])
    #expect(rt.call("app", "pendingURLs") == ["https://example.com"])
    #expect(rt.call("app", "pendingURLs") == [])
    var opened: [Value] = []
    rt.host.on("app.openURL") { opened.append($0) }
    rt.app.open([URL(string: "https://a.dev")!])
    #expect(opened.first?["urls"] == ["https://a.dev"])
    _ = rt.call("app", "interceptClose", ["enabled": true])
    rt.host.on("app.closeRequested") { _ in }
    #expect(rt.app.shouldClose() == false)
  }

  @Test func profilesMapToStableDataStores() {
    let a = WebViewsService.profileUUID("work"), b = WebViewsService.profileUUID("work")
    #expect(a == b && a != WebViewsService.profileUUID("home"))
    let rt = Self.runtime()
    #expect(rt.webviews.store(for: "default") === WKWebsiteDataStore.default())
    #expect(!rt.webviews.store(for: "private").isPersistent)
    #expect(rt.webviews.store(for: "work") === rt.webviews.store(for: "work"))
    #expect(WebViewsService.normalize("example.com")?.absoluteString == "https://example.com")
    #expect(WebViewsService.normalize("two words") == nil)
  }

  @Test func linkPolicyRoutesRealClicksInWebKit() async throws {
    let rt = Self.runtime()
    let id = rt.call("webviews", "create", ["id": "pinned"])["id"].string!
    _ = rt.call("webviews", "setLinkPolicy", ["id": .string(id), "rules": [["when": "crossSite", "event": "peek.open"]]])
    var routed: [Value] = []
    rt.host.on("peek.open") { routed.append($0) }
    _ = rt.call("content", "show", ["panes": [.string(id)]])
    let web = try #require(rt.webviews.record(id)?.webView)
    let html = "<a id=x href='https://other.test/page'>x</a><a id=y href='https://docs.a.test/same'>y</a><script>document.getElementById('x').click()</script>"
    web.loadHTMLString(html, baseURL: URL(string: "https://www.a.test/"))
    for _ in 0..<100 where routed.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
    #expect(routed.first?["url"] == "https://other.test/page")
    #expect(routed.first?["id"] == "pinned")
    // Same-site click is allowed to navigate (not routed).
    _ = try? await web.evaluateJavaScript("document.getElementById('y').click()")
    try await Task.sleep(for: .milliseconds(300))
    #expect(routed.count == 1)
  }

  @Test func suspendDiscardsAndRestores() async throws {
    let rt = Self.runtime()
    let id = rt.call("webviews", "create", ["id": "t"])["id"].string!
    _ = rt.call("content", "show", ["panes": [.string(id)]])
    let web = try #require(rt.webviews.record(id)?.webView)
    _ = rt.call("webviews", "navigate", ["id": .string(id), "url": "https://example.com/"])
    for _ in 0..<100 where web.isLoading || web.title?.isEmpty != false { try await Task.sleep(for: .milliseconds(50)) }
    var suspended = false
    rt.host.on("webviews.suspended") { _ in suspended = true }
    _ = rt.call("webviews", "suspend", ["id": .string(id)])
    for _ in 0..<60 where !suspended { try await Task.sleep(for: .milliseconds(50)) }
    let st = rt.call("webviews", "get", ["id": .string(id)])
    #expect(st["live"] == false && st["suspended"] == true)
    #expect(rt.webviews.record(id)?.snapshot != nil)
    // Showing it again recreates the web view from the saved interaction state.
    _ = rt.call("content", "show", ["panes": [.string(id)]])
    let again = try #require(rt.webviews.record(id)?.webView)
    #expect(again !== web)
    for _ in 0..<100 where again.url == nil { try await Task.sleep(for: .milliseconds(50)) }
    #expect(again.url?.absoluteString == "https://example.com/")
  }
}
