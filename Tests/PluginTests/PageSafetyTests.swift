import AppKit
import Carbon
import CordisValue
import Foundation
import Testing
import WebKit

@testable import DenHost
@testable import PluginCores

/// Crashed pages, dialog loops, CJK input in the command bar and shortcuts on non-US keyboards
/// (docs/research/dia-shortlist.md §2.4, §2.7).
@MainActor
@Suite(.serialized, .watchdog)
struct PageSafetyTests {
  func until(_ seconds: Double = 15, _ cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
      if cond() { return true }
      try? await Task.sleep(for: .milliseconds(40))
    }
    return cond()
  }

  func js(_ w: WKWebView, _ script: String) async -> Any? {
    await withCheckedContinuation { c in w.evaluateJavaScript(script) { r, _ in c.resume(returning: r) } }
  }

  /// Ends a page's real WebContent process with SIGKILL, like a crash (a termination asked of
  /// WebKit itself, `_killWebContentProcess`, isn't reported to the client).
  static func crash(_ w: WKWebView) -> Bool {
    guard w.responds(to: NSSelectorFromString("_webProcessIdentifier")), let pid = (w.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0 else { return false }
    return Darwin.kill(pid, SIGKILL) == 0
  }

  func served(_ pages: [String: String]) throws -> MockServices {
    let m = MockServices()
    try m.start()
    for (path, body) in pages { m.page(path, body) }
    return m
  }

  @Test(.timeLimit(.minutes(3))) func aDeadWebProcessShowsTheCrashPageAndReloadRecovers() async throws {
    let h = Harness()
    let mock = try served(["/p": "<title>Plain page</title><p>hello</p>", "/q": "<title>Other page</title><p>other</p>"])
    defer { mock.stop() }
    h.record(["webviews.crashed"])
    let a = h.rt.call("webviews", "create", ["id": "crash-a", "url": .string(mock.base + "/p")])["id"].string!
    _ = h.rt.call("content", "show", ["panes": [.string(a)]])
    let w = try #require(h.rt.webviews.record(a)?.webView)
    #expect(await until { w.title == "Plain page" })
    // Kill the page's real WebContent process (WebKit's own test hook).
    #expect(PageSafetyTests.crash(w))
    #expect(await until { h.events.contains { $0.0 == "webviews.crashed" } })
    #expect(await until { w.title == "This page crashed" })
    #expect(await js(w, "document.body.dataset.denError") as? String == "crashed")
    #expect(await js(w, "document.getElementById('retry').textContent") as? String == "Reload")
    #expect(w.url?.absoluteString == mock.base + "/p")  // the tab keeps its page
    // It never reloads by itself; Reload brings the page back.
    try? await Task.sleep(for: .milliseconds(600))
    #expect(w.title == "This page crashed")
    _ = h.rt.call("webviews", "reload", ["id": .string(a)])
    #expect(await until { w.title == "Plain page" })
    // A page that crashes off screen shows the page when it's next on screen.
    let b = h.rt.call("webviews", "create", ["id": "crash-b", "url": .string(mock.base + "/q")])["id"].string!
    _ = h.rt.call("content", "show", ["panes": [.string(b)]])
    let wb = try #require(h.rt.webviews.record(b)?.webView)
    #expect(await until { wb.title == "Other page" })
    _ = h.rt.call("content", "show", ["panes": [.string(a)]])
    #expect(await until { wb.window == nil })
    #expect(Self.crash(wb))
    #expect(await until { h.rt.webviews.record(b)?.crashed == true })
    _ = h.rt.call("content", "show", ["panes": [.string(b)]])
    #expect(await until { wb.title == "This page crashed" })
  }

  @Test(.timeLimit(.minutes(3))) func aDialogLoopCanBeStoppedAfterThree() async throws {
    let h = Harness()
    let mock = try served(["/d": "<title>Dialogs</title><p>dialogs</p>"])
    defer { mock.stop() }
    let a = h.rt.call("webviews", "create", ["id": "dialogs", "url": .string(mock.base + "/d")])["id"].string!
    _ = h.rt.call("content", "show", ["panes": [.string(a)]])
    let w = try #require(h.rt.webviews.record(a)?.webView)
    #expect(await until { w.title == "Dialogs" })
    let prompts = try #require(h.rt.webviews.prompts)
    // A page that alerts in a loop (it waits for each answer).
    w.evaluateJavaScript("for (let i = 0; i < 8; i++) alert('again ' + i); document.title = 'done'; 1") { _, _ in }
    var shown: [Bool] = []
    while shown.count < 8, await until(10, { prompts.current != nil }) {
      let offered = prompts.current?.tree["checkbox"]["title"].string == "Stop this page from showing dialogs"
      shown.append(offered)
      // The fourth dialog offers to stop them; ticking it answers this one and silences the rest.
      prompts.press("ok", fields: offered ? [WebPrompts.checkedKey: "1"] : [:])
      if offered { break }
    }
    #expect(shown == [false, false, false, true])
    #expect(await until { w.title == "done" })
    #expect(prompts.current == nil)
    // A new page may show dialogs again.
    _ = h.rt.call("webviews", "reload", ["id": .string(a)])
    #expect(await until { w.title == "Dialogs" })
    w.evaluateJavaScript("alert('hello'); 1") { _, _ in }
    #expect(await until { prompts.current != nil })
    #expect(prompts.current?.tree["checkbox"].isNull == true)
    prompts.press("ok")
  }

  @Test func commandBarWaitsForInputMethodComposition() throws {
    let h = Harness()
    var inputs: [String] = [], submits = 0
    h.rt.plugins.on("ui.action") { v in
      if v.str("action") == "input" { inputs.append(v["value"].str("text")) }
      if v.str("action") == "submit" { submits += 1 }
    }
    h.rt.call("ui", "set", ["slot": "overlay.commandBar", "tree": ["type": "commandBar", "id": "commandBar", "query": "", "selected": "r1",
                                                                      "sections": [["rows": [["id": "r1", "icon": "sf:globe", "title": "Row"]]]]]])
    func bar(_ v: NSView) -> CommandBarView? { (v as? CommandBarView) ?? v.subviews.lazy.compactMap(bar).first }
    let view = try #require(bar(h.rt.window.window.contentView!.superview!))
    h.rt.window.window.makeFirstResponder(view.input)
    let editor = try #require(view.input.currentEditor() as? NSTextView)
    // Japanese: "nihon" composes as marked text; nothing is searched or submitted meanwhile.
    editor.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(editor.hasMarkedText())
    #expect(inputs.isEmpty)
    #expect(view.control(view.input, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))) == false)
    #expect(submits == 0)
    // Committing the candidate is one search for the committed text; Return then submits.
    editor.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(!editor.hasMarkedText())
    #expect(inputs == ["日本"])
    #expect(view.control(view.input, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))) == true)
    #expect(submits == 1)
    h.rt.call("ui", "set", ["slot": "overlay.commandBar", "tree": nil])
  }

  /// What a key types on a real macOS keyboard layout (no modifiers), via UCKeyTranslate.
  static func typed(_ layout: String, _ keyCode: UInt16) -> String? {
    let filter = [kTISPropertyInputSourceID as String: layout] as CFDictionary
    guard let src = (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource])?.first,
          let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
    let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
    var dead: UInt32 = 0, len = 0
    var buf = [UniChar](repeating: 0, count: 4)
    let status = data.withUnsafeBytes { raw -> OSStatus in
      guard let l = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
      return UCKeyTranslate(l, keyCode, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, 4, &len, &buf)
    }
    return status == noErr ? String(utf16CodeUnits: buf, count: len) : nil
  }

  static func key(_ layout: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent? {
    guard let c = typed(layout, keyCode) else { return nil }
    return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                            characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: keyCode)
  }

  @Test func shortcutsWorkOnAzertyRussianAndStayByCharacterOnDvorak() throws {
    let h = Harness()
    NSApp.mainMenu = NSMenu()
    MainMenu.install()
    h.startTabs()
    h.record(["spaces.key.jump", "tabs.key.close", "tabs.key.back", "tabs.key.nextTab"])
    let menu = try #require(NSApp.mainMenu)
    // AZERTY: ⌃ + the "1" key types ⌃&. AppKit alone finds nothing; den runs Space 1 by position.
    let ctrl1 = try #require(Self.key("com.apple.keylayout.French", 18, .control))
    #expect(ctrl1.charactersIgnoringModifiers == "&")
    #expect(!menu.performKeyEquivalent(with: ctrl1))
    #expect(KeyLayoutFallback.perform(ctrl1, in: menu))
    #expect(h.events.last?.0 == "spaces.key.jump" && h.events.last?.1["chord"] == "ctrl+1")
    // AZERTY ⌘[ (the ^ dead key) goes Back; ⌘⇧ + the "]" key ($) is Next Tab.
    let back = try #require(Self.key("com.apple.keylayout.French", 33, .command))
    #expect(back.charactersIgnoringModifiers == "^")
    #expect(KeyLayoutFallback.perform(back, in: menu))
    #expect(h.events.last?.0 == "tabs.key.back")
    let next = try #require(Self.key("com.apple.keylayout.French", 30, [.command, .shift]))
    #expect(KeyLayoutFallback.perform(next, in: menu))
    #expect(h.events.last?.0 == "tabs.key.nextTab")
    // Russian: ⌘ + the W key types ⌘ц: Close Tab.
    let close = try #require(Self.key("com.apple.keylayout.Russian", 13, .command))
    #expect(close.charactersIgnoringModifiers == "ц")
    #expect(KeyLayoutFallback.perform(close, in: menu))
    #expect(h.events.last?.0 == "tabs.key.close")
    // Dvorak and QWERTZ letters keep their own characters: no fallback.
    let dvorak = try #require(Self.key("com.apple.keylayout.Dvorak", 13, .command))  // types ","
    #expect(KeyLayoutFallback.item(for: dvorak, in: menu) == nil)
    let qwertz = try #require(Self.key("com.apple.keylayout.German", 6, .command))  // types "y"
    #expect(KeyLayoutFallback.item(for: qwertz, in: menu) == nil)
    // And a US keyboard never needs it.
    let us = try #require(Self.key("com.apple.keylayout.US", 13, .command))
    #expect(KeyLayoutFallback.item(for: us, in: menu) == nil)
  }
}
