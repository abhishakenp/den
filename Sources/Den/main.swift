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

  func arg(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
  }

  func applicationWillFinishLaunching(_ notification: Notification) {
    MainMenu.install()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let root = arg("--storage").map { URL(fileURLWithPath: $0) } ?? StorageService.defaultRoot
    runtime = DenRuntime(storageRoot: root)
    runtime.app.open(pendingURLs)
    pendingURLs = []

    if args.contains("--demo") {
      let d = DemoDriver(runtime: runtime)
      demo = d
      d.start(appearance: arg("--appearance") ?? "light")
    } else {
      runtime.call("window", "setTheme", ["colors": ["#c3b1ff", "#ffb3d1"], "intensity": 0.6, "grain": 0.3])
    }

    let w = runtime.window.window
    w.makeKeyAndOrderFront(nil)
    NSApp.activate()
    w.displayIfNeeded()
    // First frame committed -> window is on screen.
    CATransaction.setCompletionBlock { [weak self] in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.firstFrame() } }
    }
    CATransaction.commit()
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
    case "toast": DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) { d.copyURL() }
    case "peek": DispatchQueue.main.asyncAfter(deadline: .now() + 1) { d.peek("https://www.swift.org") }
    case "space2": d.switchSpace(1, animated: false)
    case "suspend":
      // Measure: show 10 tabs one after another, then report.
      break
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

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
