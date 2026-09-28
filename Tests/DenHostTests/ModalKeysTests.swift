import AppKit
import CordisValue
import Foundation
import DenTestSupport
import Testing
import WebKit

@testable import DenHost

/// Esc / Return on den's dialogs while a web page had keyboard focus: real key events through the
/// window's `sendEvent` (AppKit's dispatch), with a WKWebView whose text field is focused as the
/// first responder, for the password, quit, delete-space and JavaScript alert dialogs.
@MainActor
@Suite(.serialized, .watchdog)
struct ModalKeysTests {
  func runtime() -> DenRuntime {
    _ = NSApplication.shared
    let rt = DenRuntime(storageRoot: FileManager.default.temporaryDirectory.appendingPathComponent("den-modalkeys-\(UUID())"))
    rt.webviews.configureHooks.append { _, c in c.preferences.inactiveSchedulingPolicy = .none }
    rt.window.window.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 800), display: false)
    rt.window.window.contentView?.layoutSubtreeIfNeeded()
    return rt
  }

  func wait(_ cond: () -> Bool, ms: Int = 8000) async -> Bool {
    for _ in 0..<(ms / 50) {
      if cond() { return true }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return cond()
  }

  /// A shown page with a focused text field; its WKWebView is the window's first responder.
  func focusedPage(_ rt: DenRuntime) async throws -> WKWebView {
    let id = rt.call("webviews", "create", ["url": "about:blank"])["id"].string!
    _ = rt.call("content", "show", ["panes": [.string(id)]])
    rt.content.releaseWebViews()
    let web = try #require(rt.webviews.record(id)?.webView)
    web.loadHTMLString("<input id=u autofocus><input id=p type=password>", baseURL: URL(string: "https://accounts.test/"))
    #expect(await wait { !web.isLoading && web.url != nil })
    _ = try? await web.callAsyncJavaScript("document.getElementById('u').focus()", contentWorld: .page)
    rt.window.window.makeFirstResponder(web)
    #expect(rt.window.window.firstResponder === web)
    return web
  }

  static func key(_ code: UInt16, _ chars: String, window: NSWindow) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                     windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
  }
  static func esc(_ w: NSWindow) -> NSEvent { key(53, "\u{1b}", window: w) }
  static func ret(_ w: NSWindow) -> NSEvent { key(36, "\r", window: w) }

  /// ui.action button presses for dialog `id`.
  func presses(_ rt: DenRuntime, _ id: String) -> () -> [String] {
    var out: [String] = []
    rt.plugins.on("ui.action") { v in if v.str("id") == id, v.str("action") == "button" { out.append(v["value"].str("button")) } }
    return { out }
  }

  static let dialogs: [(String, Value)] = [
    ("passwords.save", ["type": "dialog", "id": "passwords.save", "icon": "sf:key.fill", "title": "Save password for accounts.test?",
                        "buttons": [["id": "never", "title": "Never for This Site", "style": "secondary"],
                                    ["id": "cancel", "title": "Not Now", "style": "cancel"], ["id": "save", "title": "Save", "style": "default"]]]),
    ("quit", HostScenarios.dialogs["dialogQuit"]!),
    ("deleteSpace", HostScenarios.dialogs["dialogDeleteSpace"]!),
  ]

  /// The page takes focus back the way Google's sign-in does after a submit: `element.focus()`,
  /// which makes WebKit call `makeFirstResponder` on its WKWebView.
  func stealFocus(_ web: WKWebView) async {
    // Alternate the field, so the element focus really changes each time.
    _ = try? await web.callAsyncJavaScript("document.getElementById(document.activeElement.id === 'p' ? 'u' : 'p').focus()", contentWorld: .page)
    for _ in 0..<40 where web.window?.firstResponder !== web { try? await Task.sleep(for: .milliseconds(25)) }
  }

  @Test(arguments: [0, 1, 2])
  func escAndReturnReachThePluginDialog(_ i: Int) async throws {
    let rt = runtime()
    let web = try await focusedPage(rt)
    let (id, tree) = Self.dialogs[i]
    let got = presses(rt, id)
    let w = rt.window.window
    let cancelId = tree.list("buttons").first { $0.str("style") == "cancel" }?.str("id") ?? ""
    let defaultId = tree.list("buttons").first { DialogView.isDefault($0) }?.str("id") ?? ""

    rt.call("ui", "set", ["slot": "dialog", "tree": tree])
    #expect(w.firstResponder === rt.ui.dialog)
    await stealFocus(web)
    #expect(w.firstResponder === web)  // what the user had: the page holds focus under the dialog
    w.sendEvent(Self.esc(w))
    #expect(await wait { got() == [cancelId] }, "Esc -> \(got())")
    rt.call("ui", "set", ["slot": "dialog", "tree": nil])
    // Focus goes back to the page it was taken from.
    #expect(w.firstResponder === web)

    rt.call("ui", "set", ["slot": "dialog", "tree": tree])
    await stealFocus(web)
    w.sendEvent(Self.ret(w))
    #expect(await wait { got() == [cancelId, defaultId] }, "Return -> \(got())")
    rt.call("ui", "set", ["slot": "dialog", "tree": nil])
    #expect(w.firstResponder === web)
    rt.call("webviews", "close", ["id": .string(rt.webviews.recordFor(web)?.id ?? "")])
  }

  /// A page's alert() / confirm(): Esc answers Cancel, Return OK, even with the page's web view
  /// made first responder again while the dialog is up.
  @Test func javaScriptDialogs() async throws {
    let rt = runtime()
    let web = try await focusedPage(rt)
    let w = rt.window.window
    let p = try #require(rt.webviews.prompts)
    web.evaluateJavaScript("setTimeout(function(){document.title=String(confirm('Leave?'))},0)", completionHandler: nil)
    #expect(await wait { p.visible })
    w.makeFirstResponder(web)
    w.sendEvent(Self.esc(w))
    #expect(await wait { web.title == "false" }, "title \(web.title ?? "")")
    #expect(w.firstResponder === web)
    web.evaluateJavaScript("setTimeout(function(){document.title=String(confirm('Leave?'))},0)", completionHandler: nil)
    #expect(await wait { p.visible })
    w.makeFirstResponder(web)
    w.sendEvent(Self.ret(w))
    #expect(await wait { web.title == "true" }, "title \(web.title ?? "")")
    web.evaluateJavaScript("setTimeout(function(){alert('Hi');document.title='after'},0)", completionHandler: nil)
    #expect(await wait { p.visible })
    w.makeFirstResponder(web)
    w.sendEvent(Self.esc(w))
    #expect(await wait { web.title == "after" && !p.visible })
    #expect(w.firstResponder === web)
    rt.call("webviews", "close", ["id": .string(rt.webviews.recordFor(web)?.id ?? "")])
  }

  /// Sheets, popovers, the Library and the command bar dismiss on Esc the same way.
  @Test func sheetsPopoversAndCommandBar() async throws {
    let rt = runtime()
    let web = try await focusedPage(rt)
    let w = rt.window.window
    var actions: [String] = []
    rt.plugins.on("ui.action") { v in actions.append(v.str("id") + ":" + v.str("action") + ":" + v["value"].str("reason")) }
    let cases: [(String, Value, String)] = [
      ("overlay.passwords", ["type": "sheet", "id": "passwords", "style": "sheet", "title": "Passwords", "children": []], "passwords:dismiss:"),
      ("popover", ["type": "themePicker", "id": "theme", "colors": ["#b98cff"], "intensity": 0.5, "grain": 0.2, "appearance": "auto"], "theme:dismiss:escape"),
      ("overlay.commandBar", ["type": "commandBar", "id": "cb", "query": "", "selected": "", "sections": []], "cb:dismiss:"),
      ("overlay.library", ["type": "library", "id": "archive", "items": []], "archive:dismiss:"),
    ]
    for (slot, tree, want) in cases {
      actions.removeAll()
      rt.call("ui", "set", ["slot": .string(slot), "tree": tree])
      await stealFocus(web)
      #expect(w.firstResponder === web, "\(slot)")
      w.sendEvent(Self.esc(w))
      #expect(await wait { actions.contains(want) }, "\(slot): \(actions)")
      rt.call("ui", "set", ["slot": .string(slot), "tree": nil])
      #expect(w.firstResponder === web, "\(slot) restores focus")
    }
    rt.call("webviews", "close", ["id": .string(rt.webviews.recordFor(web)?.id ?? "")])
  }
}
