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
//                                  blank (no web view at all: den's own footprint), discard, pip, pipAway, pipInline,
//                                  pipURL, nowPlaying, webPanel
//                                  (discard and pip print a line per check and exit 0/1)
//                                  (split*, command*, dialog, peek and littleArcLink need those plugins)
//                                  page: opens --url <url> as the selected tab (dark mode, sign-in and vault checks)
//   --dev-plugins <dir>            also load <dir>/*.dylib and hot-reload them when rebuilt
//   --snapshot <path.png>          render the window to PNG after load, then quit
//   --snapshot-delay <seconds>     wait before snapshot (default 4)
//   --measure-launch               print ms from process start to first window on screen, then quit
//   --storage <dir>                storage root (default ~/Library/Application Support/den/storage)
//   --no-den-home                  ignore ~/.den (no user plugins, themes, config; nothing watched)
//   --background                   automation: no Dock icon, never activated, every window off-display
//                                  (Presentation.invisible); --snapshot still renders. Test runs are always so.
//   --exit-after <seconds>         quit that long after the first window (scripts that capture by window id)
//   --relaunched [--background]    started by app.relaunch / an update; here --background only means no focus
//
// ~/.den (DEN_HOME overrides it): plugins, themes and config.toml, watched and hot-reloaded
// after the first window (docs/den-home.md). SIGTERM quits cleanly without the quit dialog.

setvbuf(stdout, nil, _IOLBF, 0)
let traceOn = LaunchTrace.on
@MainActor func trace(_ s: String) { LaunchTrace.mark(s) }
let signposter = OSSignposter(subsystem: "io.github.abhishakenp.den", category: "launch")
let launchInterval = signposter.beginInterval("launch")

/// Process start time (kernel), so launch time includes dyld + runtime init.
func processStartDate() -> Date { LaunchTrace.processStart }

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let args = CommandLine.arguments
  var runtime: DenRuntime!
  var loader: PluginLoader!
  var pendingURLs: [URL] = []
  var visibleObserver: NSObjectProtocol?
  var snapMini = false
  var snapActive = false
  let home: DenHome? = CommandLine.arguments.contains("--no-den-home") ? nil : DenHome()
  var config: ConfigService?
  var live: LivePlugins?
  var updates: UpdatesService?
  var sparkle: DenSparkle?
  /// Set when an update quits den: skip the quit dialog.
  var quittingForUpdate = false
  var loadedDeferred = false
  /// Relaunched by an update: show the window without taking focus.
  var background: Bool { args.contains("--relaunched") && args.contains("--background") }
  /// `--background` (automation): no Dock icon, never activated, windows off every display.
  var invisible: Bool { Presentation.invisible }
  var sigterm: DispatchSourceSignal?
  lazy var sessionLog: DenLog? = home.map { DenLog(url: $0.logs.appendingPathComponent("den.log")) }

  func arg(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
  }

  /// Everything up to showing the window happens here, not in didFinishLaunching: between the two,
  /// AppKit sits idle until LaunchServices' open-application Apple event arrives (tens of ms), and
  /// building the runtime and the first-frame plugins overlaps that wait.
  func applicationWillFinishLaunching(_ notification: Notification) {
    trace("willFinishLaunching")
    MainMenu.install()
    trace("menu")
    setUp()
  }

  func applicationDidBecomeActive(_ notification: Notification) { trace("didBecomeActive") }

  func setUp() {
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
    trace("setUp")
    runtime = DenRuntime(storageRoot: root, crashMarkerPath: PluginHost.defaultCrashMarkerPath)
    // Shortcuts, Siri and Spotlight actions act on this runtime (DenHost/Intents).
    DenIntents.runtime = runtime
    // Unpacked development extensions (docs/den-home.md). Only a path: nothing is read until the first web view.
    runtime.extensions.homeFolder = home?.extensions
    runtime.extensions.logFile = home.map { DenLog(url: $0.logs.appendingPathComponent("extensions.log")) }
    // Automatic picture in picture: every decision, one line (why a video did or didn't go).
    if let log = sessionLog { runtime.media.log = { log.write($0) } }
    trace("runtime")
    if let log = sessionLog { runtime.app.logLine = { log.write($0) } }
    // Demo runs never touch the real Keychain.
    if args.contains("--demo") { runtime.vault.store = MemoryVaultStore() }
    runtime.plugins.onEvent = { e in
      switch e {
      case let .log(id, level, message): if level != .debug { print("[\(id)] \(message)") }
      case let .applyFailed(id, reason): print("plugin \(id) failed to apply: \(reason)")
      case let .applied(id):
        trace("applied \(id)")
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
                                 disabled: home.map(ConfigService.disabledPlugins) ?? [], deferring: true)
    trace("plugins")
    if traceOn { print("plugins firstFrame=\(outcome.loaded) deferred=\(loader.deferred.map { $0.deletingPathExtension().lastPathComponent })") }
    if !runtime.plugins.serviceNames.contains("spaces") {
      runtime.call("window", "setTheme", ["colors": ["#c3b1ff", "#ffb3d1"], "intensity": 0.6, "grain": 0.3])
    }
    if let a = arg("--appearance") {
      for s in runtime.call("spaces", "list").array ?? [] {
        runtime.call("spaces", "update", ["id": s["id"], "theme": ["appearance": .string(a)]])
      }
    }

    trace("setup")
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    trace("didFinishLaunching")
    defer { trace("didFinishLaunching.end") }
    let w = runtime.window.window
    if invisible {
      Presentation.show(w)
    } else if background {
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
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
      self?.loadDeferredPlugins()
      self?.runtime.content.releaseWebViews()
    }
    // App Shortcut phrases with a space in them ("Switch to Work in den"). The system only talks
    // to apps signed with a Team ID; with den's local signature it would refuse (and log it).
    if Signing.teamIdentifier != nil, !invisible {
      DispatchQueue.main.asyncAfter(deadline: .now() + 5) { DenShortcuts.updateAppShortcutParameters() }
    }
    // The window server reports the window visible -> first frame is on screen. (In the
    // background it may stay covered, so don't wait for that.)
    //
    // firstFrame() is never called inline here: it loads every deferred plugin and creates the
    // restored session's web views, all on the main thread, so running it in this turn meant the
    // window could not composite until all of it was done. A background relaunch (what an idle den
    // does when an update lands, which is how this path is reached in normal use) took 15-22 s to
    // its first window that way, against well under a second once the window is up first. One
    // main-queue turn is enough for AppKit to present the window; the 1 s fallback above still
    // bounds the wait if the window server is slow to report occlusion.
    if w.occlusionState.contains(.visible) || background || invisible {
      DispatchQueue.main.async { [weak self] in self?.firstFrame() }
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
    // Plugins that don't paint the first frame, before any page loads (dark mode styles them).
    loadDeferredPlugins()
    runtime.content.releaseWebViews()
    // Snapshot folders of den processes that crashed (never this one's).
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.runtime.webviews.removeStaleSnapshots() }
    trace("webviews")
    if args.contains("--measure-launch") {
      print(String(format: "launch.firstWindowMs %.1f", ms))
      if arg("--snapshot") == nil && !args.contains("--stay") { exit(0) }
    }
    DispatchQueue.main.async { [weak self] in self?.startDenHome(firstWindowMs: ms) }
    if let s = arg("--exit-after").flatMap(Double.init) {
      // Close every page first (WebKit's page close, not just the view), so no WebContent process
      // or audio session outlives an automated run; DEN_TRACE prints the pids for scripts to check.
      DispatchQueue.main.asyncAfter(deadline: .now() + s) { [weak self] in
        let pids = self?.runtime.tearDown() ?? []
        if traceOn { print("exit.webcontent \(pids.map(String.init).joined(separator: ","))") }
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
      }
    }
    var snapWindow = runtime.window.window
    if let scenario = arg("--scenario") {
      // Host component scenarios (DenHost/Scenarios) first; the rest need --demo.
      #if Scenarios
      if let w = HostScenarios.apply(scenario, runtime: runtime, appearance: arg("--appearance") ?? "light") { snapWindow = w } else { applyScenario(scenario) }
      #else
      applyScenario(scenario)
      #endif
    }
    if let path = arg("--snapshot") {
      let delay = Double(arg("--snapshot-delay") ?? "4") ?? 4
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        MainActor.assumeIsolated { SnapshotGate.wait {
        Task { @MainActor in
          // Scenarios that open a Little Arc snapshot that panel instead of the main window.
          if self.snapMini, let p = self.runtime.windowService.miniPanels.first ?? NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible }) { snapWindow = p }
          // Window scenarios snapshot the window in front (a new or private window).
          if self.snapActive { snapWindow = self.runtime.window.window }
          let ok = await Snapshotter.write(snapWindow, to: path)
          print(ok ? "snapshot: \(path)" : "snapshot: FAILED")
          exit(ok ? 0 : 1)
        }
        } }
      }
    }
  }

  /// The plugins `PluginLoader` held back until the first frame (once), and what came of the whole launch load.
  func loadDeferredPlugins() {
    guard !loadedDeferred else { return }
    loadedDeferred = true
    let outcome = loader.loadDeferred()
    trace("plugins.deferred")
    if traceOn || !outcome.failed.isEmpty { print("plugins loaded=\(outcome.loaded) failed=\(outcome.failed) crashed=\(outcome.crashed)") }
    updates?.crashed = outcome.crashed
    // The updates plugin says so (PluginNotices.swift).
    if !outcome.crashed.isEmpty { runtime.host.emit("plugins.crashed", ["ids": .array(outcome.crashed.map { .string($0) })]) }
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
    // `plugins.failed`: the updates plugin tells the user (PluginNotices.swift).
    live.notify = { [weak self] v in self?.runtime.host.emit("plugins.failed", v) }
    live.configChanged = { [weak config] in config?.reloadConfig(edited: true) }
    live.themesChanged = { [weak config] in config?.reloadThemes() }
    live.hostAPI = DenBuild.running.hostAPI
    live.updaterStateChanged = { [weak self] in self?.updates?.stateChanged() }
    self.live = live
    home.ensureLayout()
    config.start()
    live.start()
    let firstWindowEpochMs = processStartDate().timeIntervalSince1970 * 1000 + firstWindowMs
    sessionLog?.write(String(format: "launch pid=%d firstWindowEpochMs=%.0f firstWindowMs=%.1f", getpid(), firstWindowEpochMs, firstWindowMs))
    // The tabs plugin logs the restorable session (`session launch spaces=… sig=…`).
    runtime.host.emit("app.session", ["phase": "launch", "pid": .int(Int64(getpid()))])
  }

  func applicationWillTerminate(_ notification: Notification) {
    guard runtime != nil else { return }
    runtime.webviews.removeSnapshots()
    guard let sessionLog else { return }
    sessionLog.write(String(format: "quit pid=%d epochMs=%.0f", getpid(), Date().timeIntervalSince1970 * 1000))
    runtime.host.emit("app.session", ["phase": "quit", "pid": .int(Int64(getpid()))])
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
      // Little Arc for links from other apps is opt-in (Settings ▸ Peek): turn it on.
      rt.call("peek", "settings", ["littleArc": true])
      snapMini = true
      // Snapshot once the panel is up and its page has loaded (a slow runner takes seconds).
      SnapshotGate.settle = 1.5
      SnapshotGate.ready = {
        guard let m = rt.call("window", "listMini").array?.first, let w = rt.webviews.record(m.str("webview"))?.webView else { return false }
        return !w.isLoading && w.url != nil
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { rt.app.open([URL(string: "https://www.swift.org/blog/")!]) }
    case "littleArcCmdO":
      // A link from another app opens Little Arc; with its panel the key window, a real Cmd-O key
      // event goes through AppKit's dispatch (NSApp.sendEvent) and moves the page into a today tab.
      rt.call("peek", "settings", ["littleArc": true])
      // Snapshot: the page in its today tab, the panel gone.
      var moved = false
      SnapshotGate.settle = 1
      SnapshotGate.ready = { moved }
      rt.app.open([URL(string: "https://www.swift.org/")!])
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        guard let panel = rt.windowService.miniPanels.first ?? NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible }) else { print("scenario.cmdO no panel"); exit(1) }
        let web = rt.call("window", "listMini")[0]["webview"].string ?? ""
        Presentation.activate()
        Presentation.show(panel)
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
            moved = first == web && rt.call("window", "listMini").array?.isEmpty == true
            // With --snapshot, the snapshot ends the run (once the page is in its tab).
            if self.arg("--snapshot") == nil { exit(ok ? 0 : 1) }
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
    case "shieldsPanel", "shieldsHTTPS", "shieldsLookalike":
      // The shields plugin: its per-site panel over a real page (after the lists are compiled, so
      // the counts are real), and den's two interstitials, reached by real navigations.
      let url = s == "shieldsHTTPS" ? "http://httpforever.com/" : s == "shieldsLookalike" ? "https://xn--pple-43d.com/" : (arg("--url") ?? "https://www.theverge.com/")
      func go(_ tries: Int) {
        let ready = (rt.call("sitepolicy", "list").array ?? []).filter { $0.flag("ready") }.count
        guard ready >= 3 || tries > 240 || s != "shieldsPanel" else {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { go(tries + 1) }
          return
        }
        let id = rt.call("tabs", "open", ["url": .string(url)])["id"]
        rt.call("tabs", "select", ["id": id])
        guard s == "shieldsPanel" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
          rt.call("shields", "open", ["id": id])
          print("scenario.ready shields=\(rt.call("sitepolicy", "get", ["id": id]))")
        }
      }
      go(0)
    case "page":
      guard let u = arg("--url") else { print("scenario.page needs --url"); exit(1) }
      let id = rt.call("tabs", "open", ["url": .string(u)])["id"]
      rt.call("tabs", "select", ["id": id])
    case "adCheck":
      // Shields against real ads: opens each --url (space separated) in turn once the lists and
      // scriptlets are ready. YouTube watch pages: plays muted (like a click on play) and samples
      // the player for 30 s. Other pages: WebKit's blocked count. One `scenario.ad` line per URL,
      // then `scenario.adDone ok=…`, and den exits.
      AdCheck(rt: rt, urls: (arg("--url") ?? "").split(separator: " ").map(String.init)).start()
    case "command": rt.call("commands", "open", ["mode": "new", "query": "swi"])
    case "commandEdit": rt.plugins.emit("commands.key.edit")  // Cmd-L
    case "commandActions":
      rt.call("commands", "open", ["mode": "new"])
      rt.plugins.emit("ui.action", ["id": "commandBar", "action": "tab", "value": ["query": ""]])
    case "pip", "pipAway", "pipInline", "pipURL":
      #if Scenarios

      MediaScenarios.apply(s, runtime: rt)
      #endif
    case "nowPlaying", "webPanel":
      #if Scenarios
      NowPlayingScenarios.apply(s, runtime: rt)
      #endif
    case "discard":
      #if Scenarios
      DiscardScenarios.apply(s, runtime: rt)
      #endif
    case "popupWindow", "popupBlocked":
      snapMini = s == "popupWindow"
      #if Scenarios
      PopupScenarios.apply(s, url: nil, runtime: rt)
      #endif
    case "popupClick":
      #if Scenarios
      PopupScenarios.apply(s, url: arg("--url"), runtime: rt)
      #endif
    case "pageMenuLink", "pageMenuImage", "pageMenuText", "pageMenuPage", "inspectorDocked":
      #if Scenarios
      DevToolsScenarios.apply(s, runtime: rt)
      #endif
    case "newWindow":
      // ⌘N: a second window on the same space, its command bar asking what to open.
      snapActive = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { rt.call("window", "new") }
    case "privateWindow":
      // ⇧⌘N with two private tabs (network: swift.org, apple.com).
      snapActive = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        rt.call("window", "new", ["private": true])
        rt.call("commands", "close")
        rt.call("tabs", "open", ["url": "https://www.swift.org/"])
        rt.call("tabs", "open", ["url": "https://developer.apple.com/", "background": true])
      }
    case "windowHandoff":
      // "Let a tab open in two windows" on: the first window's tab, picked in a second
      // window, moves there; the first window (snapshotted) says where it went.
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        rt.call("settings", "set", ["id": "tabs", "key": "sameTabInWindows", "value": true])
        let sel = rt.call("tabs", "selected")["id"]
        rt.call("window", "new")
        rt.call("commands", "close")
        rt.call("tabs", "select", ["id": sel])
        print("scenario.handoff w1=\(rt.call("content", "get", ["window": "w1"])) w2=\(rt.call("content", "get"))")
      }
    case "tourCard", "tourStep", "tipToast":
      // The tips plugin's tour card, its second step, and a tip (limits ignored, nothing recorded).
      let preview: Value = s == "tourCard" ? ["key": "tour"] : s == "tourStep" ? ["key": "step", "step": 1] : ["key": "reopenClosed"]
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { rt.plugins.emit("tips.preview", preview) }
    case "dialog": rt.plugins.emit("app.quitRequested")
    case "toast": DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) { rt.call("tabs", "clearToday") }
    case "peek": DispatchQueue.main.asyncAfter(deadline: .now() + 1) { rt.call("peek", "open", ["url": "https://www.swift.org"]) }
    case "space2":
      if let id = rt.call("spaces", "list")[1]["id"].string { rt.call("spaces", "switch", ["id": .string(id), "animated": false]) }
    case "emptySpace":
      // A new space with no tabs: the content card shows "Open a tab." with the ⌘T keycap.
      if let id = rt.call("spaces", "create", ["name": "Reading", "icon": "📚"])["id"].string {
        rt.call("spaces", "switch", ["id": .string(id), "animated": false])
      }
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

  /// A den item picked in Spotlight, or a page handed over from another device (Handoff).
  func application(_ application: NSApplication, willContinueUserActivityWithType userActivityType: String) -> Bool { true }

  func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                   restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
    guard let runtime else { return false }
    return runtime.spotlight.continueActivity(userActivity) || runtime.handoff.continueActivity(userActivity)
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
    if !flag { Presentation.show(runtime.windows.main.window) }
    return true
  }
}

MainActor.assumeIsolated { trace("main") }
IconView.prewarmSymbols()
// Automation relies on flags (--background, --exit-after): a den that doesn't know one must fail,
// not run on with a window. (Values never start with "--".)
let knownFlags: Set<String> = [
  "--demo", "--appearance", "--scenario", "--url", "--dev-plugins", "--snapshot", "--snapshot-delay", "--measure-launch",
  "--storage", "--no-den-home", "--relaunched", "--background", "--exit-after", "--stay",
]
if let bad = CommandLine.arguments.dropFirst().first(where: { $0.hasPrefix("--") && !knownFlags.contains($0) }) {
  FileHandle.standardError.write(Data("den: unknown flag \(bad); known: \(knownFlags.sorted().joined(separator: " "))\n".utf8))
  exit(2)
}
// Info.plist declares den a UI element (LSUIElement), so LaunchServices never gives an automation
// launch a Dock tile, not even for the moment before this line. A normal launch becomes a regular
// app here, before NSApplication finishes launching. `--background` (not the relaunch flavour)
// stays an accessory app: no Dock icon, no activation.
let invisibleLaunch = CommandLine.arguments.contains("--background") && !CommandLine.arguments.contains("--relaunched")
let app = NSApplication.shared
MainActor.assumeIsolated { trace("nsapp") }
MainActor.assumeIsolated { if invisibleLaunch { Presentation.invisible = true } }
app.setActivationPolicy(invisibleLaunch ? .accessory : .regular)
let delegate = AppDelegate()
app.delegate = delegate
MainActor.assumeIsolated { trace("run") }
app.run()
