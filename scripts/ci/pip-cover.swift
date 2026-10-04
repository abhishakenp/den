// Another app for the `pip` scenario (CI only): built into PipCover.app by ci.yml and opened by
// MediaScenarios with LaunchServices (`open -n PipCover.app --args <mode>`), so it comes to the
// front like an app you switch to. Modes:
//   partial     a window over the left half of the main screen (den still shows on the right)
//   full        a window over the whole screen (den's window covered)
//   fullscreen  a window in native full screen: a Space of its own, so the display switches Space
// It quits on SIGTERM.
import AppKit

let mode = CommandLine.arguments.dropFirst().first ?? "partial"
let app = NSApplication.shared
app.setActivationPolicy(.regular)

final class Delegate: NSObject, NSApplicationDelegate {
  var window: NSWindow!
  func applicationDidFinishLaunching(_ n: Notification) {
    let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    var frame = screen
    if mode == "partial" { frame.size.width = screen.width / 2 }
    if mode == "fullscreen" { frame = NSRect(x: 100, y: 100, width: 800, height: 600) }
    let style: NSWindow.StyleMask = mode == "fullscreen" ? [.titled, .resizable, .closable] : [.borderless]
    window = NSWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
    window.title = "PipCover \(mode)"
    window.backgroundColor = .systemTeal
    window.collectionBehavior.insert(.fullScreenPrimary)
    window.setFrame(frame, display: true)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()
    if mode == "fullscreen" {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.window.toggleFullScreen(nil) }
    }
    print("pip-cover \(mode) frame=\(NSStringFromRect(frame)) active=\(NSApp.isActive)")
  }
}

let delegate = Delegate()
app.delegate = delegate
signal(SIGTERM) { _ in exit(0) }
app.run()
