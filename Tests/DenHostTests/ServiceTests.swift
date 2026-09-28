import AppKit
import CordisValue
import Foundation
import DenTestSupport
import Testing
import WebKit

@testable import DenHost

/// Exercises the host services through their `(method, args) -> Value` handlers, exactly as a
/// plugin would through the C ABI.
@MainActor
@Suite(.serialized, .watchdog)
struct ServiceTests {
  static func runtime() -> DenRuntime {
    _ = NSApplication.shared
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("den-svc-\(UUID())")
    let rt = DenRuntime(storageRoot: dir)
    // Test windows are never on screen: keep pages running (den uses `.suspend` for unseen pages,
    // which in a loaded full run suspends a test page before its load or click completes).
    rt.webviews.configureHooks.append { _, c in c.preferences.inactiveSchedulingPolicy = .none }
    rt.window.window.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 800), display: false)
    rt.window.window.contentView?.layoutSubtreeIfNeeded()
    return rt
  }

  /// The sidebar resize handle's drag loop ends when the button is up, even when no mouse-up
  /// event ever arrives (a synthesized click): this was a whole-suite hang. The loop is driven
  /// with fake events: calling AppKit's `nextEvent` in the test process stops its run loop.
  @Test func resizeHandleDoesNotWaitForeverForAMouseUp() throws {
    let rt = Self.runtime()
    let handle = rt.window.resizeHandle
    var drags: [CGFloat] = [], ended = 0
    handle.onDrag = { drags.append($0) }
    handle.onDragEnd = { ended += 1 }
    let drag = try #require(NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 300, y: 300), modifierFlags: [], timestamp: 0,
                                               windowNumber: rt.window.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    // One drag event, then silence with the button up: the drag ends at once.
    var queue: [NSEvent] = [drag]
    handle.track(next: { _ in queue.isEmpty ? nil : queue.removeFirst() }, buttonDown: { false })
    #expect(drags.count == 1 && ended == 1)
    // Silence while the button is held keeps tracking; releasing it ends the drag.
    var held = 3
    handle.track(next: { _ in nil }, buttonDown: { held -= 1; return held > 0 })
    #expect(ended == 2 && held == 0)
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

  /// Launch: the first frame shows the card; the WKWebView is created right after it.
  @Test func heldWebViewsMaterializeOnRelease() {
    let rt = Self.runtime()
    let id = rt.call("webviews", "create", ["url": "https://example.com"])["id"].string!
    rt.content.holdWebViews = true
    #expect(rt.call("content", "show", ["panes": [.string(id)]]) == .ok)
    #expect(rt.call("content", "get")["panes"] == [.string(id)])
    #expect(rt.webviews.record(id)?.webView == nil)
    #expect(rt.content.card(id)?.superview != nil)
    rt.content.releaseWebViews()
    #expect(rt.webviews.record(id)?.webView?.superview === rt.content.card(id)?.clip)
    #expect(rt.window.window.firstResponder === rt.webviews.record(id)?.webView)
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

  /// A long Today list only has views for the rows near the screen; scrolling makes the rest and
  /// drops the ones far away (a discarded tab costs its record, not a row of views).
  @Test func longListsAreVirtualized() throws {
    let rt = Self.runtime()
    let rows: [Value] = (0..<200).map { ["type": "tabRow", "id": .string("t\($0)"), "title": .string("Tab \($0)"), "icon": "sf:globe"] }
    _ = rt.call("ui", "set", ["slot": "sidebar.today", "tree": ["type": "list", "children": .array([["type": "divider", "id": "d"]] + rows)]])
    rt.window.window.contentView?.layoutSubtreeIfNeeded()
    rt.ui.sidebarView.layoutSubtreeIfNeeded()
    let list = try #require(rt.ui.sidebarView.slot("sidebar.today", page: 0)?.root as? StackNode)
    list.layoutSubtreeIfNeeded()
    let made = { list.kids.compactMap { $0 as? TabRowNode }.map(\.nodeId) }
    print("virtualized rows made: \(made().count) of 200")
    #expect(made().count > 10 && made().count < 80)
    #expect(made().contains("t0") && !made().contains("t199"))
    #expect(list.height(for: list.bounds.width) >= 200 * Tokens.tabRowHeight)
    // Scroll to the end: the last rows exist, the first ones are gone.
    let scroll = try #require(list.enclosingScrollView)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, scroll.documentView!.frame.height - scroll.contentView.bounds.height)))
    scroll.reflectScrolledClipView(scroll.contentView)
    #expect(made().contains("t199") && !made().contains("t0"))
    // Updates reach rows with views; rows without one get theirs from the new value later.
    let r1: [Value] = (0..<200).map { ["type": "tabRow", "id": .string("t\($0)"), "title": .string($0 == 199 ? "Last" : "Tab \($0)"), "icon": "sf:globe"] }
    _ = rt.call("ui", "set", ["slot": "sidebar.today", "tree": ["type": "list", "children": .array([["type": "divider", "id": "d"]] + r1)]])
    #expect((list.kids.first { $0.nodeId == "t199" } as? TabRowNode)?.label.stringValue == "Last")
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
    // A real key event resolves through the main menu's key equivalents.
    _ = rt.call("keys", "bind", ["chord": "ctrl+2", "event": "tabs.new", "menu": "Spaces"])
    let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0, windowNumber: 0, context: nil,
                               characters: "2", charactersIgnoringModifiers: "2", isARepeat: false, keyCode: 19)!
    #expect(NSApp.mainMenu!.performKeyEquivalent(with: key))
    #expect(fired.count == 2 && fired[1]["chord"] == "ctrl+2")
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
    _ = await Wait.until("routed.isEmpty") { !(routed.isEmpty) }
    #expect(routed.first?["url"] == "https://other.test/page")
    #expect(routed.first?["id"] == "pinned")
    // Same-site click is allowed to navigate (not routed).
    _ = await Wait.js(web, "document.getElementById('y').click()")
    // Not routed: WebKit starts navigating in place (the host doesn't resolve, so don't require it).
    _ = await Wait.until("the same-site click to start navigating", seconds: 2) { web.url?.host == "docs.a.test" }
    #expect(routed.count == 1)
  }

  @Test func suspendDiscardsAndRestores() async throws {
    let rt = Self.runtime()
    let id = rt.call("webviews", "create", ["id": "t"])["id"].string!
    let other = rt.call("webviews", "create", ["id": "o"])["id"].string!
    _ = rt.call("content", "show", ["panes": [.string(id)]])
    let web = try #require(rt.webviews.record(id)?.webView)
    web.loadHTMLString("<title>Local</title><body style='background:#fdd'><h1>Hello</h1></body>", baseURL: URL(string: "https://local.test/page"))
    _ = await Wait.until("the page to load") { !web.isLoading && web.title?.isEmpty == false }
    // On screen: an idle discard is refused; an explicit one isn't needed here.
    #expect(rt.call("webviews", "suspend", ["id": .string(id)]) == ["suspended": false, "reason": "visible"])
    // Leaving the screen saves a small snapshot to disk.
    _ = rt.call("content", "show", ["panes": [.string(other)]])
    _ = await Wait.until("the snapshot") { rt.webviews.record(id)?.snapshotPath != nil }
    let path = try #require(rt.webviews.record(id)?.snapshotPath)
    #expect(path.hasSuffix(".jpg") && FileManager.default.fileExists(atPath: path))
    #expect(web.superview == nil)
    var suspended = false
    rt.host.on("webviews.suspended") { _ in suspended = true }
    #expect(rt.call("webviews", "suspend", ["id": .string(id)]) == ["suspended": true])
    #expect(suspended)  // off screen: discarded at once
    let st = rt.call("webviews", "get", ["id": .string(id)])
    #expect(st["live"] == false && st["suspended"] == true && st["snapshot"] == .string(path))
    // Showing it again recreates the web view from the saved state, under its snapshot.
    _ = rt.call("content", "show", ["panes": [.string(id)]])
    let again = try #require(rt.webviews.record(id)?.webView)
    #expect(again !== web)
    #expect(rt.content.isCovered(id))
    _ = await Wait.until("the snapshot cover to lift") { !rt.content.isCovered(id) }
    #expect(!rt.content.isCovered(id))
    // Closing forgets the snapshot file.
    _ = rt.call("webviews", "close", ["id": .string(id)])
    #expect(!FileManager.default.fileExists(atPath: path))
  }

  @Test func muteUsesThePageMute() async throws {
    let rt = Self.runtime()
    let id = rt.call("webviews", "create", ["id": "m"])["id"].string!
    var events: [Value] = []
    rt.host.on("webviews.muted") { events.append($0) }
    _ = rt.call("webviews", "setMuted", ["id": .string(id), "muted": true])  // before it's live: kept
    #expect(rt.call("webviews", "get", ["id": .string(id)])["muted"] == true)
    _ = rt.call("content", "show", ["panes": [.string(id)]])
    #expect(rt.webviews.pageMuted(id) == true)
    _ = rt.call("webviews", "setMuted", ["id": .string(id), "muted": false])
    #expect(rt.webviews.pageMuted(id) == false)
    #expect(events.map { $0["muted"] } == [true, false])
  }

  @Test func dragReorderEmitsTargetAndPosition() throws {
    let rt = Self.runtime()
    rt.window.window.orderFront(nil)
    var got: [Value] = []
    rt.host.on("ui.action") { if $0["action"] == "reorder" { got.append($0) } }
    _ = rt.call("ui", "set", ["slot": "sidebar.today", "tree": ["type": "list", "children": [
      ["type": "tabRow", "id": "a", "title": "A"], ["type": "tabRow", "id": "b", "title": "B"], ["type": "tabRow", "id": "c", "title": "C"],
    ]]])
    rt.window.window.contentView?.layoutSubtreeIfNeeded()
    rt.ui.sidebarView.layoutSubtreeIfNeeded()
    let list = try #require(rt.ui.sidebarView.slot("sidebar.today", page: 0)?.root as? StackNode)
    list.layoutSubtreeIfNeeded()
    let a = list.kids[0] as! TabRowNode, c = list.kids[2] as! TabRowNode
    func ev(_ type: NSEvent.EventType, _ v: NSView, _ fy: CGFloat) -> NSEvent {
      let p = v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.height * fy), to: nil)
      return NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: rt.window.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    rt.ui.drag.begin(a, event: ev(.leftMouseDown, a, 0.5))
    rt.ui.drag.move(ev(.leftMouseDragged, c, 0.8))  // lower half of C (flipped view: y grows down)
    rt.ui.drag.end(ev(.leftMouseUp, c, 0.8))
    #expect(got.count == 1)
    #expect(got.first?["value"]["source"] == "a" && got.first?["value"]["target"] == "c" && got.first?["value"]["position"] == "after")
  }

  @Test func sidebarResizeClampsAndResets() {
    let rt = Self.runtime()
    rt.window.dragResize(to: 300)
    #expect(rt.window.sidebarWidth == 300)
    rt.window.dragResize(to: 5000)
    #expect(rt.window.sidebarWidth == Tokens.sidebarMaxWidth)
    rt.window.dragResize(to: 40)  // below the collapse threshold hides it
    #expect(rt.window.sidebarHidden)
    rt.window.setSidebarHidden(false, animated: false)
    rt.window.setSidebarWidth(Tokens.sidebarDefaultWidth, animated: false)  // what double-click does
    #expect(rt.window.sidebarWidth == 228)
  }
}
