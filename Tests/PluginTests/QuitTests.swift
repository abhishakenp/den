import AppKit
import CordisValue
import DenTestSupport
import Testing

@testable import DenHost
@testable import PluginCores

@MainActor
@Suite(.serialized, .watchdog)
struct QuitTests {
  /// Starts the quit core with `app.quit` captured instead of forwarded: the real one would
  /// terminate the test process.
  final class Quits { var calls: [Value] = [] }

  func start(_ h: Harness, _ quits: Quits) -> QuitCore {
    let base = h.env
    var env = base
    env.invoke = { s, m, a in
      if s == "app" && m == "quit" {
        quits.calls.append(a)
        return ["ok": true]
      }
      return base.invoke(s, m, a)
    }
    let core = QuitCore(env: env)
    core.start()
    return core
  }

  func key(_ code: UInt16, _ chars: String) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                     characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
  }

  var dialogNode: (Harness) -> Value = { $0.rt.ui.dialog.node }

  @Test func cmdQShowsTheDialogAndEnterQuits() {
    let h = Harness()
    let q = Quits()
    let core = start(h, q)
    #expect(h.rt.app.interceptQuit)
    // Cmd-Q: the app delegate asks the app service, which defers and emits app.quitRequested.
    #expect(h.rt.app.shouldTerminate() == .terminateLater)
    #expect(h.rt.ui.dialogOpen && core.dialogOpen)
    let d = dialogNode(h)
    #expect(d["title"] == "Quit den?" && d["icon"] == "app:icon" && d["message"].isNull)
    #expect((d["buttons"].array ?? []).map { $0.s("title") } == ["Always quit", "Cancel", "Quit"])
    #expect((d["buttons"].array ?? []).map { $0.s("style") } == ["secondary", "cancel", "default"])
    // Spec §5: a 450x248 sheet.
    h.rt.window.window.contentView?.layoutSubtreeIfNeeded()
    #expect(h.rt.ui.dialog.frame.size == CGSize(width: 450, height: 248))
    h.rt.ui.dialog.keyDown(with: key(36, "\r"))  // Return presses "Quit"
    #expect(q.calls == [["confirm": true]])
    #expect(!h.rt.ui.dialogOpen)
    #expect(h.storage("quit", "warn").isNull)  // still asks next time
  }

  @Test func escCancels() {
    let h = Harness()
    let q = Quits()
    start(h, q)
    h.rt.plugins.emit("app.quitRequested")
    h.rt.ui.dialog.keyDown(with: key(53, "\u{1b}"))  // Esc presses "Cancel"
    #expect(q.calls == [["confirm": false]])
    #expect(!h.rt.ui.dialogOpen)
    #expect(h.rt.app.interceptQuit)
  }

  @Test func alwaysQuitPersistsAndTheCommandReenables() {
    let h = Harness()
    var registered: [String] = []
    h.rt.plugins.provide("commands") { m, a in
      if m == "register" { registered.append(a.s("id")) }
      return ["ok": true]
    }
    let q = Quits()
    start(h, q)
    #expect(registered == ["quit.warn"])
    h.rt.plugins.emit("app.quitRequested")
    h.action("quit", "button", ["button": "always"])
    #expect(q.calls == [["confirm": true]])
    #expect(h.storage("quit", "warn") == false)
    #expect(!h.rt.app.interceptQuit)

    // Next launch: no interception, and a quit request (if any) quits without a dialog.
    let h2 = Harness(root: h.root)
    let q2 = Quits()
    let core2 = start(h2, q2)
    #expect(!h2.rt.app.interceptQuit)
    #expect(h2.rt.app.shouldTerminate() == .terminateNow)
    h2.rt.plugins.emit("app.quitRequested")
    #expect(!h2.rt.ui.dialogOpen)
    #expect(q2.calls == [["confirm": true]])

    // "Ask Before Quitting" turns it back on, persistently, with a toast.
    h2.rt.plugins.emit("commands.run", ["id": "quit.warn"])
    #expect(core2.warn && h2.rt.app.interceptQuit)
    #expect(h2.storage("quit", "warn") == true)
    #expect(h2.rt.ui.toasts.count == 1)
  }

  @Test func unloadStopsIntercepting() {
    let h = Harness()
    let q = Quits()
    let core = start(h, q)
    h.rt.plugins.emit("app.quitRequested")
    core.stop()
    #expect(q.calls == [["confirm": false]])  // a pending request is answered
    #expect(!h.rt.ui.dialogOpen)
    #expect(!h.rt.app.interceptQuit)
  }

  @Test func commandRegistersWhenTheCommandBarLoadsLater() {
    let h = Harness()
    let core = start(h, Quits())
    #expect(!core.commandsRegistered)
    h.rt.plugins.provide("commands") { _, _ in ["ok": true] }
    h.fireTimers()
    #expect(core.commandsRegistered)
  }
}
