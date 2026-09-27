import AppKit
import Cordis
import CordisValue
import DenHost
import os

// Flags:
//   --demo                         use a fresh temporary storage root, so the plugins' first-run seed shows
//   --appearance light|dark|auto   set every space's appearance through the spaces plugin
//   --scenario <name>              state before snapshot: main, hidden, reveal, space2, toast, swipe, swipeCommit,
//                                  load10, load10discard, split, split3, command, commandEdit, commandActions, dialog, peek,
//                                  littleArcLink, rename
//                                  (split*, command*, dialog, peek and littleArcLink need those plugins)
//   --dev-plugins <dir>            also load <dir>/*.dylib and hot-reload them when rebuilt
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
  var loader: PluginLoader!
  var pendingURLs: [URL] = []
  var visibleObserver: NSObjectProtocol?
  var snapMini = false

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
    // --demo without --storage runs on a fresh store, so the plugins' first-run seed shows.
    let root = arg("--storage").map { URL(fileURLWithPath: $0) }
      ?? (args.contains("--demo") ? FileManager.default.temporaryDirectory.appendingPathComponent("den-demo-\(UUID().uuidString)") : StorageService.defaultRoot)
    trace("didFinishLaunching")
    runtime = DenRuntime(storageRoot: root, crashMarkerPath: PluginHost.defaultCrashMarkerPath)
    trace("runtime")
    runtime.plugins.onEvent = { e in
      switch e {
      case let .log(id, level, message): if level != .debug { print("[\(id)] \(message)") }
      case let .applyFailed(id, reason): print("plugin \(id) failed to apply: \(reason)")
      case let .applied(id): trace("applied \(id)")
      case let .reloaded(id, hash): print("plugin \(id) reloaded (build \(hash))")
      case let .reloadFailed(path, reason): print("plugin reload failed \(path): \(reason)")
      default: break
      }
    }
    // The selected tab's WKWebView (and its WebContent process) is created after the first
    // frame is on screen, not before: the window shows its sidebar and an empty card first.
    runtime.content.holdWebViews = true
    runtime.app.open(pendingURLs)
    pendingURLs = []
    trace("plugins.start")
    loader = PluginLoader(plugins: runtime.plugins)
    let outcome = loader.loadAll(dev: arg("--dev-plugins").map { URL(fileURLWithPath: $0) })
    trace("plugins")
    if traceOn || !outcome.failed.isEmpty { print("plugins loaded=\(outcome.loaded) failed=\(outcome.failed) crashed=\(outcome.crashed)") }
    if let text = PluginLoader.crashToast(outcome.crashed) {
      runtime.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": .string(text), "icon": "sf:exclamationmark.triangle.fill", "duration": 6000]])
    }
    if !runtime.plugins.serviceNames.contains("spaces") {
      runtime.call("window", "setTheme", ["colors": ["#c3b1ff", "#ffb3d1"], "intensity": 0.6, "grain": 0.3])
    }
    if let a = arg("--appearance") {
      for s in runtime.call("spaces", "list").array ?? [] {
        runtime.call("spaces", "update", ["id": s["id"], "theme": ["appearance": .string(a)]])
      }
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
    // Never keep pages waiting if the window server is slow to report the window visible.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.runtime.content.releaseWebViews() }
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
    runtime.content.releaseWebViews()
    trace("webviews")
    if args.contains("--measure-launch") {
      print(String(format: "launch.firstWindowMs %.1f", ms))
      if arg("--snapshot") == nil && !args.contains("--stay") { exit(0) }
    }
    var snapWindow = runtime.window.window
    if let scenario = arg("--scenario") {
      // Host component scenarios (DenHost/Scenarios) first; the rest need --demo.
      if let w = HostScenarios.apply(scenario, runtime: runtime, appearance: arg("--appearance") ?? "light") { snapWindow = w } else { applyScenario(scenario) }
    }
    if let path = arg("--snapshot") {
      let delay = Double(arg("--snapshot-delay") ?? "4") ?? 4
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        Task { @MainActor in
          // Scenarios that open a Little Arc snapshot that panel instead of the main window.
          if self.snapMini, let p = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible }) { snapWindow = p }
          let ok = await Snapshotter.write(snapWindow, to: path)
          print(ok ? "snapshot: \(path)" : "snapshot: FAILED")
          exit(ok ? 0 : 1)
        }
      }
    }
  }

  func applyScenario(_ s: String) {
    let rt = runtime!
    func allTabIds() -> [String] {
      var ids: [String] = []
      for sp in rt.call("spaces", "list").array ?? [] {
        let l = rt.call("tabs", "list", ["spaceId": sp["id"]])
        func walk(_ items: [Value]) { for i in items { if i.flag("folder") { walk(i.list("children")) } else { ids.append(i.str("id")) } } }
        walk(l.list("pinned"))
        walk(l.list("today"))
        if ids.isEmpty || sp == rt.call("spaces", "list")[0] { ids += l.list("favorites").map { $0.str("id") } }
      }
      var seen = Set<String>()
      return ids.filter { seen.insert($0).inserted }
    }
    switch s {
    case "hidden": rt.call("window", "setSidebar", ["hidden": true, "animated": false])
    case "reveal":
      rt.call("window", "setSidebar", ["hidden": true, "animated": false])
      rt.window.revealSidebarForTesting()
    case "split":
      let today = rt.call("tabs", "list").list("today").map { $0["id"] }
      if today.count > 1 { rt.call("peek", "split", ["ids": .array(Array(today.prefix(2))), "layout": "horizontal"]) }
    case "split3":
      let today = rt.call("tabs", "list").list("today").map { $0["id"] }
      if today.count > 2 { rt.call("peek", "split", ["ids": .array(Array(today.prefix(3))), "layout": "grid"]) }
    case "littleArcLink":
      // A link from another app, as macOS delivers it: the peek plugin opens it in Little Arc.
      snapMini = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { rt.app.open([URL(string: "https://www.swift.org/blog/")!]) }
    case "rename":
      // Double-click the first today tab: the inline title editor.
      if let id = rt.call("tabs", "list").list("today").first?["id"] { rt.plugins.emit("ui.action", ["id": id, "action": "doubleClick"]) }
    case "command": rt.call("commands", "open", ["mode": "new", "query": "swi"])
    case "commandEdit": rt.plugins.emit("commands.key.edit")  // Cmd-L
    case "commandActions":
      rt.call("commands", "open", ["mode": "new"])
      rt.plugins.emit("ui.action", ["id": "commandBar", "action": "tab", "value": ["query": ""]])
    case "dialog": rt.plugins.emit("app.quitRequested")
    case "toast": DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) { rt.call("tabs", "clearToday") }
    case "peek": DispatchQueue.main.asyncAfter(deadline: .now() + 1) { rt.call("peek", "open", ["url": "https://www.swift.org"]) }
    case "space2":
      if let id = rt.call("spaces", "list")[1]["id"].string { rt.call("spaces", "switch", ["id": .string(id), "animated": false]) }
    case "swipe", "swipeCommit":
      // In-process synthetic two-finger swipe over the sidebar (no other app is touched).
      let w = rt.window.window
      let p = NSPoint(x: w.frame.minX + 110, y: w.frame.maxY - 500)
      func scroll(_ phase: UInt32, _ dx: Int32) {
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase))
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
        e.location = CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.height ?? 0) - p.y)
        if let ne = NSEvent(cgEvent: e) { rt.ui.sidebarView.deliverScrollForTesting(ne) }
      }
      scroll(1, 0)
      for _ in 0..<3 { scroll(2, -32) }
      if s == "swipeCommit" { scroll(4, 0) }
    case "load10", "load10discard":
      let ids = Array(allTabIds().prefix(10))
      for (i, id) in ids.enumerated() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 2.5) { rt.call("tabs", "select", ["id": .string(id)]) }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + Double(ids.count) * 2.5 + 3) {
        rt.call("tabs", "select", ["id": .string(ids.first!)])
        if s == "load10discard" { for id in ids.dropFirst() { rt.call("webviews", "suspend", ["id": .string(id)]) } }
        let live = ids.filter { rt.call("webviews", "get", ["id": .string($0)]).flag("live") }.count
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
