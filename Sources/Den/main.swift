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
//                                  littleArcLink, littleArcCmdO (prints scenario.cmdO … ok=true|false, exits), rename, themeLive,
//                                  blank (no web view at all: den's own footprint), discard, mini, miniPlayer, miniURL
//                                  (discard and miniPlayer print a line per check and exit 0/1)
//                                  (split*, command*, dialog, peek and littleArcLink need those plugins)
//                                  page: opens --url <url> as the selected tab (dark mode, sign-in and vault checks)
//   --dev-plugins <dir>            also load <dir>/*.dylib and hot-reload them when rebuilt
//   --snapshot <path.png>          render the window to PNG after load, then quit
//   --snapshot-delay <seconds>     wait before snapshot (default 4)
//   --measure-launch               print ms from process start to first window on screen, then quit
//   --storage <dir>                storage root (default ~/Library/Application Support/den/storage)
//   --no-den-home                  ignore ~/.den (no user plugins, themes, config; nothing watched)
//   --relaunched [--background]    started by app.relaunch / an update; --background doesn't take focus
//   --background                   alone (test and measurement runs): doesn't take focus either
//
// ~/.den (DEN_HOME overrides it): plugins, themes and config.toml, watched and hot-reloaded
// after the first window (docs/den-home.md). SIGTERM quits cleanly without the quit dialog.

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
  let home: DenHome? = CommandLine.arguments.contains("--no-den-home") ? nil : DenHome()
  var config: ConfigService?
  var live: LivePlugins?
  var updates: UpdatesService?
  var sparkle: DenSparkle?
  /// Set when an update quits den: skip the quit dialog.
  var quittingForUpdate = false
  var background: Bool { args.contains("--background") }
  var sigterm: DispatchSourceSignal?
  lazy var sessionLog: DenLog? = home.map { DenLog(url: $0.logs.appendingPathComponent("den.log")) }

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
    // Unpacked development extensions (docs/den-home.md). Only a path: nothing is read until the first web view.
    runtime.extensions.homeFolder = home?.extensions
    trace("runtime")
    // Demo runs never touch the real Keychain.
    if args.contains("--demo") { runtime.vault.store = MemoryVaultStore() }
    runtime.plugins.onEvent = { e in
      switch e {
      case let .log(id, level, message): if level != .debug { print("[\(id)] \(message)") }
      case let .applyFailed(id, reason): print("plugin \(id) failed to apply: \(reason)")
      case let .applied(id):
        trace("applied \(id)")
        self.config?.pluginApplied()
      case let .reloaded(id, hash): print("plugin \(id) reloaded (build \(hash))")
      case let .reloadFailed(path, reason):
        print("plugin reload failed \(path): \(reason)")
        self.live?.log.write("reload failed \(path): \(reason)")
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
    // ~/.den on the launch path: one directory read (which plugins override bundled ones) and,
    // only if config.toml exists, one small read for [plugins] disabled. Everything else waits
    // for the first window (startDenHome).
    if let home {
      let c = ConfigService(host: runtime.host, home: home) { [unowned runtime] s, m, a in runtime!.call(s, m, a) }
      runtime.provide(c)
      config = c
      // Native half of updates (nothing is read until a plugin asks). Policy: the updates plugin.
      let u = UpdatesService(host: runtime.host, home: home, build: DenBuild.running)
      u.loadedFiles = { [unowned runtime] in runtime!.plugins.plugins.map { ($0.id, $0.path) } }
      u.activate = { [weak self] name in
        guard let self, let live = self.live else { return false }
        live.refresh(name)
        let id = String(name.dropLast(6))
        return self.runtime.plugins.plugin(id)?.state == .active
      }
      if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
        let sp = DenSparkle(service: u)
        sp.willInstall = { [weak self] in self?.quittingForUpdate = true }
        u.sparkle = sp
        sparkle = sp
      }
      runtime.provide(u)
      updates = u
    }
    runtime.app.relaunchHandler = { [weak self] background in self?.relaunch(background: background) }
    let hostAPI = DenBuild.running.hostAPI
    let outcome = loader.loadAll(home: home.map { LivePlugins.launchFiles($0, hostAPI: hostAPI) } ?? [], dev: arg("--dev-plugins").map { URL(fileURLWithPath: $0) },
                                 disabled: home.map(ConfigService.disabledPlugins) ?? [])
    trace("plugins")
    if traceOn || !outcome.failed.isEmpty { print("plugins loaded=\(outcome.loaded) failed=\(outcome.failed) crashed=\(outcome.crashed)") }
    updates?.crashed = outcome.crashed
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
    if background {
      // Relaunched by an update while the user works elsewhere: come back without taking focus.
      w.orderFront(nil)
    } else {
      w.makeKeyAndOrderFront(nil)
      trace("orderFront")
      NSApp.activate()
      trace("activate")
    }
    w.displayIfNeeded()
    trace("display")
    DispatchQueue.main.async { trace("nextRunloop") }
    // Never keep pages waiting if the window server is slow to report the window visible.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.runtime.content.releaseWebViews() }
    // The window server reports the window visible -> first frame is on screen. (In the
    // background it may stay covered, so don't wait for that.)
    if w.occlusionState.contains(.visible) || background {
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
    // `blank`: nothing on screen, so no WKWebView or WebKit process is ever created.
    if arg("--scenario") == "blank" { runtime.call("content", "show", ["panes": []]) }
    runtime.content.releaseWebViews()
    // Snapshot folders of den processes that crashed (never this one's).
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.runtime.webviews.removeStaleSnapshots() }
    trace("webviews")
    if args.contains("--measure-launch") {
      print(String(format: "launch.firstWindowMs %.1f", ms))
      if arg("--snapshot") == nil && !args.contains("--stay") { exit(0) }
    }
    DispatchQueue.main.async { [weak self] in self?.startDenHome(firstWindowMs: ms) }
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

  /// After the first window: ~/.den layout, config, themes, the watcher, source plugin builds,
  /// and a clean quit on SIGTERM (scripts/dev-sync.sh and scripts/install.sh relaunch with it).
  func startDenHome(firstWindowMs: Double) {
    signal(SIGTERM, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    src.setEventHandler { [weak self] in MainActor.assumeIsolated { _ = self?.runtime.call("app", "quit", ["confirm": true]) } }
    src.resume()
    sigterm = src
    guard let home, let config else { return }
    let live = LivePlugins(plugins: runtime.plugins, home: home, layers: .init(dev: arg("--dev-plugins").map { URL(fileURLWithPath: $0) }))
    live.disabled = { [weak config] in config?.disabled ?? [] }
    live.toast = { [weak self] text in
      self?.runtime.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": .string(text), "icon": "sf:puzzlepiece.extension", "duration": 6000]])
    }
    live.configChanged = { [weak self, weak config] in
      config?.reloadConfig()
      if let e = config?.errors.first(where: { $0.hasPrefix("config.toml") }) { self?.live?.toast(e) }
    }
    live.themesChanged = { [weak config] in config?.reloadThemes() }
    live.hostAPI = DenBuild.running.hostAPI
    live.updaterStateChanged = { [weak self] in self?.updates?.stateChanged() }
    self.live = live
    home.ensureLayout()
    config.start()
    live.start()
    let firstWindowEpochMs = processStartDate().timeIntervalSince1970 * 1000 + firstWindowMs
    sessionLog?.write(String(format: "launch pid=%d firstWindowEpochMs=%.0f firstWindowMs=%.1f %@", getpid(), firstWindowEpochMs, firstWindowMs, sessionSummary()))
  }

  // thin-host: feature-specific, migrate to plugin (reads tabs/spaces to log the session)
  /// One line describing the restorable session: spaces, tabs, selection, and a signature of
  /// every tab's id and URL (equal before a quit and after the relaunch when state survived).
  func sessionSummary() -> String {
    let rt = runtime!
    var ids: [String] = []
    var sig = ""
    var stack: [Value] = []
    let spaces = rt.call("spaces", "list").array ?? []
    for (j, sp) in spaces.enumerated() {
      let l = rt.call("tabs", "list", ["spaceId": sp["id"]])
      stack = (j == 0 ? l.list("favorites") : []) + l.list("pinned") + l.list("today")
      stack.reverse()
      while let i = stack.popLast() {
        if i.flag("folder") || i.flag("split") {
          stack += i.list("children").reversed()
        } else {
          ids.append(i.str("id"))
          sig += i.str("id") + " " + i.str("url") + "\n"
        }
      }
    }
    var h: UInt64 = 0xcbf2_9ce4_8422_2325  // FNV-1a
    for b in sig.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
    let selected = rt.call("tabs", "selected")["id"].string ?? "-"
    let current = rt.call("spaces", "current")["id"].string ?? "-"
    return "spaces=\(spaces.count) current=\(current) tabs=\(ids.count) selected=\(selected) sig=\(String(h, radix: 16))"
  }

  func applicationWillTerminate(_ notification: Notification) {
    guard runtime != nil else { return }
    runtime.webviews.removeSnapshots()
    guard let sessionLog else { return }
    sessionLog.write(String(format: "quit pid=%d epochMs=%.0f %@", getpid(), Date().timeIntervalSince1970 * 1000, sessionSummary()))
    sessionLog.flush()
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
    case "littleArcCmdO":
      // A link from another app opens Little Arc; with its panel the key window, a real Cmd-O key
      // event goes through AppKit's dispatch (NSApp.sendEvent) and moves the page into a today tab.
      rt.app.open([URL(string: "https://www.swift.org/")!])
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        guard let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible }) else { print("scenario.cmdO no panel"); exit(1) }
        let web = rt.call("window", "listMini")[0]["webview"].string ?? ""
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
          let wasKey = rt.call("window", "listMini")[0]["key"] == true
          let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: panel.windowNumber, context: nil, characters: "o", charactersIgnoringModifiers: "o", isARepeat: false, keyCode: 31)!
          NSApp.sendEvent(e)
          // WKWebView first offers the key to the page (a WebContent round trip), then AppKit
          // re-dispatches it to the main menu, so the move lands a moment later.
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let first = rt.call("tabs", "list").list("today").first?["id"].string ?? ""
            let ok = wasKey && first == web && rt.call("tabs", "selected")["id"].string == web && rt.call("window", "listMini").array?.isEmpty == true
            print("scenario.cmdO key=\(wasKey) web=\(web) today0=\(first) minis=\(rt.call("window", "listMini").array?.count ?? -1) ok=\(ok)")
            exit(ok ? 0 : 1)
          }
        }
      }
    case "themeLive":
      // The theme plugin's picker over the demo window (the space's "Edit Theme…").
      let id = rt.call("spaces", "current")["id"]
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { rt.plugins.emit("spaces.editTheme", ["id": id]) }
    case "rename":
      // Double-click the first today tab: the inline title editor.
      if let id = rt.call("tabs", "list").list("today").first?["id"] { rt.plugins.emit("ui.action", ["id": id, "action": "doubleClick"]) }
    case "page":
      guard let u = arg("--url") else { print("scenario.page needs --url"); exit(1) }
      let id = rt.call("tabs", "open", ["url": .string(u)])["id"]
      rt.call("tabs", "select", ["id": id])
    case "command": rt.call("commands", "open", ["mode": "new", "query": "swi"])
    case "commandEdit": rt.plugins.emit("commands.key.edit")  // Cmd-L
    case "commandActions":
      rt.call("commands", "open", ["mode": "new"])
      rt.plugins.emit("ui.action", ["id": "commandBar", "action": "tab", "value": ["query": ""]])
    case "mini", "miniOff", "miniInline", "miniPlayer", "miniURL":
      snapMini = s == "mini" || s == "miniURL"
      MediaScenarios.apply(s, runtime: rt)
    case "discard": DiscardScenarios.apply(s, runtime: rt)
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
        if s == "load10discard" {
          // An idle discard first (it keeps what must stay, and says why), then forced, so the
          // measurement always has 9 discarded tabs.
          var kept: [String] = []
          for id in ids.dropFirst() {
            let r = rt.call("webviews", "suspend", ["id": .string(id)])
            if r["suspended"] == false { kept.append("\(id):\(r.str("reason"))"); rt.call("webviews", "suspend", ["id": .string(id), "force": true]) }
          }
          print("scenario.kept \(kept.joined(separator: " "))")
        }
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
    if quittingForUpdate { return .terminateNow }
    return runtime?.app.shouldTerminate() ?? .terminateNow
  }

  /// `app.relaunch`: a detached shell waits for this process to exit, then opens the bundle
  /// again (`-g`: without taking focus). The quit is clean (session saved, no quit dialog).
  func relaunch(background: Bool) {
    let bundle = Bundle.main.bundlePath
    let flags = background ? "--relaunched --background" : "--relaunched"
    let script = "while /bin/kill -0 \(getpid()) 2>/dev/null; do /bin/sleep 0.05; done; /usr/bin/open \(background ? "-g " : "")\"$0\" --args \(flags)"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", script, bundle]
    do { try p.run() } catch { return }
    sessionLog?.write("relaunch requested background=\(background)")
    quittingForUpdate = true
    NSApp.terminate(nil)
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
