import AppKit
import CordisValue
import DenHost
import os

// Flags:
//   --demo                         run the temporary DemoDriver (stand-in for plugins)
//   --appearance light|dark        demo appearance
//   --scenario <name>              demo state before snapshot: main, hidden, split, command, dialog, toast, peek, reveal
//   --snapshot <path.png>          render the window to PNG after load, then quit
//   --snapshot-delay <seconds>     wait before snapshot (default 4)
//   --measure-launch               print ms from process start to first window on screen, then quit
//   --storage <dir>                storage root (default ~/Library/Application Support/den/storage)

setvbuf(stdout, nil, _IOLBF, 0)
let traceOn = ProcessInfo.processInfo.environment["DEN_TRACE"] != nil
@MainActor func trace(_ s: String) {
  if traceOn { print(String(format: "trace %@ %.1f", s, Date().timeIntervalSince(processStartDate()) * 1000)) }
}
let signposter = OSSignposter(subsystem: "io.github.abhishakenp.den", category: "launch")
let launchInterval = signposter.beginInterval("launch")

/// Process start time (kernel), so launch time includes dyld + runtime init.
func processStartDate() -> Date {
  var info = kinfo_proc()
  var size = MemoryLayout<kinfo_proc>.stride
  var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
  guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
  let tv = info.kp_proc.p_starttime
  return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let args = CommandLine.arguments
  var runtime: DenRuntime!
  var demo: DemoDriver?
  var pendingURLs: [URL] = []
  var visibleObserver: NSObjectProtocol?

  func arg(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
  }

  func applicationWillFinishLaunching(_ notification: Notification) {
    trace("willFinishLaunching")
    MainMenu.install()
  }

  func applicationDidBecomeActive(_ notification: Notification) { trace("didBecomeActive") }
  func applicationDidFinishLaunching(_ notification: Notification) {
    defer { trace("didFinishLaunching.end") }
    if let out = ProcessInfo.processInfo.environment["DEN_SAMPLE"] {
      let p = Process()
      p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
      p.arguments = ["\(getpid())", "1", "1", "-file", out]
      try? p.run()
      usleep(150_000)
    }
    let root = arg("--storage").map { URL(fileURLWithPath: $0) } ?? StorageService.defaultRoot
    trace("didFinishLaunching")
    runtime = DenRuntime(storageRoot: root)
    trace("runtime")
    runtime.app.open(pendingURLs)
    pendingURLs = []

    if args.contains("--demo") {
      let d = DemoDriver(runtime: runtime)
      demo = d
      d.start(appearance: arg("--appearance") ?? "light")
    } else {
      runtime.call("window", "setTheme", ["colors": ["#c3b1ff", "#ffb3d1"], "intensity": 0.6, "grain": 0.3])
    }

    trace("setup")
    let w = runtime.window.window
    w.makeKeyAndOrderFront(nil)
    trace("orderFront")
    NSApp.activate()
    trace("activate")
    w.displayIfNeeded()
    trace("display")
    DispatchQueue.main.async { trace("nextRunloop") }
    // The window server reports the window visible -> first frame is on screen.
    if w.occlusionState.contains(.visible) {
      firstFrame()
    } else {
      visibleObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, w.occlusionState.contains(.visible), let o = self.visibleObserver else { return }
          NotificationCenter.default.removeObserver(o)
          self.visibleObserver = nil
          self.firstFrame()
        }
      }
    }
  }

  func firstFrame() {
    let ms = Date().timeIntervalSince(processStartDate()) * 1000
    signposter.endInterval("launch", launchInterval)
    runtime.app.launchMs = ms
    if args.contains("--measure-launch") {
      print(String(format: "launch.firstWindowMs %.1f", ms))
      if arg("--snapshot") == nil && !args.contains("--stay") { exit(0) }
    }
    if let scenario = arg("--scenario") { applyScenario(scenario) }
    if let path = arg("--snapshot") {
      let delay = Double(arg("--snapshot-delay") ?? "4") ?? 4
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        Task { @MainActor in
          let ok = await Snapshotter.write(self.runtime.window.window, to: path)
          print(ok ? "snapshot: \(path)" : "snapshot: FAILED")
          exit(ok ? 0 : 1)
        }
      }
    }
  }

  func applyScenario(_ s: String) {
    guard let d = demo else { return }
    switch s {
    case "hidden": runtime.call("window", "setSidebar", ["hidden": true, "animated": false])
    case "reveal":
      runtime.call("window", "setSidebar", ["hidden": true, "animated": false])
      runtime.window.revealSidebarForTesting()
    case "split": d.addSplit()
    case "command":
      d.openCommandBar()
      d.query = "swi"
      d.renderCommandBar(replace: true)
    case "dialog": d.showQuitDialog()
    case "toast": DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) { d.clearToday() }
    case "peek": DispatchQueue.main.asyncAfter(deadline: .now() + 1) { d.peek("https://www.swift.org") }
    case "space2": d.switchSpace(1, animated: false)
    case "swipe", "swipeCommit":
      // In-process synthetic two-finger swipe over the sidebar (no other app is touched).
      let w = runtime.window.window
      let p = NSPoint(x: w.frame.minX + 110, y: w.frame.maxY - 500)
      func scroll(_ phase: UInt32, _ dx: Int32) {
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase))
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
        e.location = CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.height ?? 0) - p.y)
        if let ne = NSEvent(cgEvent: e) { runtime.ui.sidebarView.deliverScrollForTesting(ne) }
      }
      scroll(1, 0)
      for _ in 0..<3 { scroll(2, -32) }
      if s == "swipeCommit" { scroll(4, 0) }
    case "load10", "load10discard":
      // Memory measurement: show 10 tabs one after another (each gets a live WKWebView),
      // then go back to the first; with "discard", fully discard the other 9.
      let ids = d.allTabIds().prefix(10)
      for (i, id) in ids.enumerated() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 2.5) { d.select(id) }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + Double(ids.count) * 2.5 + 3) {
        d.select(ids.first!)
        if s == "load10discard" { for id in ids.dropFirst() { self.runtime.call("webviews", "suspend", ["id": .string(id)]) } }
        let live = ids.filter { self.runtime.call("webviews", "get", ["id": .string($0)]).flag("live") }.count
        print("scenario.ready live=\(live)")
      }
    default: break
    }
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    if let runtime { runtime.app.open(urls) } else { pendingURLs += urls }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    runtime?.app.shouldTerminate() ?? .terminateNow
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag { runtime.window.window.makeKeyAndOrderFront(nil) }
    return true
  }
}

MainActor.assumeIsolated { trace("main") }
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
