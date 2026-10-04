import AppKit
import CordisValue
import WebKit

// thin-host: feature-specific, migrate to plugin (the auto picture-in-picture policy -> the `media`
// plugin over webviews primitives; the host keeps only the calls into WebKit's native PiP)
/// `media` service: picture in picture, WebKit's own (docs/host-api.md#media). The video goes to
/// the system PiP window Safari uses (`NativePiP`): above every app, on every Space, over
/// full-screen apps, with the system's own controls. den never draws a player window.
///
/// Automatic, like Safari's video Viewer (on by default, `autoPip`): a video playing with sound
/// (not muted, at least `minDuration` s or live, shown at least 200×100 pt, PiP not disabled by
/// the page) enters PiP when you leave it:
/// - its tab leaves the screen (a tab or space switch),
/// - you switch to another app (den resigns active, as in Arc: at once, while the page is still
///   on screen, even with den's window partly showing behind the other app),
/// - den's window is minimized, hidden, covered by other windows (occluded) or its Space is
///   switched away from, or a page's full-screen video stops being visible (its Space switched
///   away from);
/// and comes back when you return (only a PiP den started; one you started stays, like Safari).
/// Every automatic decision is one line through `log` (den.log: `pip ...`).
/// The PiP window's return button (WebKit's `_webViewFullscreenMayReturnToInline:`) goes back to
/// the tab, in its space and window, and brings den forward. Its close button pauses the video.
///
/// Methods:
///   get                      -> {pip: [webview], auto: [webview], settings: {autoPip}}
///   settings {autoPip?}      -> {autoPip}   (persisted; on by default)
///   toggle {webview?, fallback?} -> {webview, pip}  (Picture in Picture, ⌥⌘P: leaves PiP when a page
///                               is in it; otherwise enters with `webview`, the focused pane, `fallback`
///                               (the media plugin's newest playing tab), or any page playing video)
///   enter {webview}  exit {webview?}
/// Events: media.pip {webview, open, auto}, media.backToTab {webview} (the tabs plugin selects it).
@MainActor
public final class MediaService: HostService {
  public let name = "media"
  let host: ServiceHost
  let webviews: WebViewsService
  let content: ContentService
  let windows: WindowSet
  var wc: DenWindowController { windows.active }
  let storage: StorageService

  public private(set) var autoPip = true
  /// Pages with a video in PiP (WebKit's delegate call).
  public private(set) var active: Set<String> = []
  /// Pages den put in PiP on its own: they leave it when you come back.
  public private(set) var auto: Set<String> = []
  /// Asked to enter, not in PiP yet.
  private var entering: Set<String> = []
  /// den is taking these out of PiP (not the PiP window's buttons).
  private var exiting: Set<String> = []
  /// Asked to enter, then to leave before WebKit was in (a quick switch away and back).
  private var cancelled: Set<String> = []
  /// Pages whose full-screen video window was out of sight (its Space switched away).
  private var fullScreenAway: Set<String> = []
  private var observers: [NSObjectProtocol] = []
  private var pending: DispatchWorkItem?
  public var debounce: TimeInterval = 0.2
  public var minDuration: Double = 5
  /// Auto PiPs den started because den stopped being the active app: they stay while another
  /// app is in front (den's window may still show behind it) and end when den is active again.
  private var appAway: Set<String> = []
  /// Each page's latest request to enter (its timers check they're still the latest).
  private var attempts: [String: Int] = [:]
  /// Tests: what `windowVisible` says (their windows are never really on screen).
  var windowVisibleForTests: Bool?
  /// One line per automatic PiP decision (main.swift: den.log; the `pip` scenario: stdout).
  public var log: ((String) -> Void)?
  func note(_ line: String) { log?(line) }
  static let ns = "media"

  public init(host: ServiceHost, webviews: WebViewsService, content: ContentService, windows: WindowSet, storage: StorageService) {
    self.host = host
    self.webviews = webviews
    self.content = content
    self.windows = windows
    self.storage = storage
    let s = storage.handle(method: "get", args: ["ns": .string(Self.ns), "key": "settings"])
    // `autoMiniPlayer`: the same setting before den used native PiP.
    autoPip = s["autoPip"].bool ?? s.flag("autoMiniPlayer", true)
    content.leaving = { [weak self] id in self?.leaving(id) }
    content.willAttach = { [weak self] id in self?.returned(id) }
    webviews.onPip = { [weak self] id, on in self?.pipChanged(id, on) }
    webviews.onReturnToInline = { [weak self] id in self?.returnButton(id) }
    webviews.willDestroy = { [weak self] id in self?.forget(id) }
    observeWindows()
  }

  public func handle(method: String, args: Value) -> Value {
    switch method {
    case "get":
      return ["pip": .array(active.sorted().map { .string($0) }), "auto": .array(auto.sorted().map { .string($0) }),
              "settings": ["autoPip": .bool(autoPip)]]
    case "settings":
      if let on = args["autoPip"].bool {
        autoPip = on
        _ = storage.handle(method: "set", args: ["ns": .string(Self.ns), "key": "settings", "value": ["autoPip": .bool(autoPip)]])
      }
      return ["autoPip": .bool(autoPip)]
    case "toggle":
      if !active.isEmpty || !entering.isEmpty {
        let ids = active.union(entering).sorted()
        for id in ids { exit(id) }
        return ["webview": .string(ids[0]), "pip": false]
      }
      guard let id = toggleTarget(args) else { return .error("media: no video to show in picture in picture") }
      guard enter(id, auto: false) else { return .error("media: '\(id)' can't enter picture in picture") }
      return ["webview": .string(id), "pip": true]
    case "enter":
      let id = args.str("webview")
      guard webviews.record(id)?.webView != nil else { return .error("media: '\(id)' isn't live") }
      guard enter(id, auto: false) else { return .error("media: '\(id)' can't enter picture in picture") }
    case "exit":
      if let id = args["webview"].string { exit(id) } else { for id in active.union(entering) { exit(id) } }
    default:
      return .error("media: unknown method '\(method)'")
    }
    return .ok
  }

  // MARK: Which video

  /// The video den would put in PiP on its own when you leave tab `id`, if any (see the type doc).
  public func eligibleVideo(_ id: String) -> Value? { eligibility(id).video }

  /// `eligibleVideo` with the reason when there's none (the log's words). "no video": the page
  /// reported no playing video and plays nothing (not worth a log line).
  public func eligibility(_ id: String) -> (video: Value?, why: String) {
    guard autoPip else { return (nil, "autoPip off") }
    guard let r = webviews.record(id) else { return (nil, "no page") }
    guard r.webView != nil else { return (nil, "not live") }
    if r.discarding { return (nil, "discarding") }
    if r.muted { return (nil, "tab muted") }
    guard let v = r.videoFrame?.media.video else {
      return (nil, r.media.playing ? "media playing, no video reported (frames=\(r.frames.count))" : "no video")
    }
    let size = "\(Int(v.num("cw")))x\(Int(v.num("ch")))"
    if v.flag("paused") { return (nil, "paused") }
    if v.flag("muted") { return (nil, "video muted") }
    if !(v.num("vol") > 0) { return (nil, "volume 0") }
    if !(v.num("vw") > 0) { return (nil, "no video track yet") }
    if v.flag("noPip") { return (nil, "page disabled PiP") }
    let dur = v.num("dur")
    if !(dur < 0 || dur >= minDuration) { return (nil, "short (\(dur) s)") }
    if !(v.num("cw") >= 200 && v.num("ch") >= 100) { return (nil, "small \(size)") }
    return (v, "\(size) dur=\(dur < 0 ? "live" : String(Int(dur)))")
  }

  /// Automatic entry for `trigger`: `id`'s video if it qualifies (a log line either way, unless
  /// the page has no video at all). True when den asked WebKit.
  @discardableResult
  func autoEnter(_ id: String, _ trigger: String) -> Bool {
    if active.contains(id) || entering.contains(id) { return false }
    let e = eligibility(id)
    guard e.video != nil else {
      if e.why != "no video" { note("pip \(trigger) \(id): skip, \(e.why)") }
      return false
    }
    note("pip \(trigger) \(id): enter, \(e.why)")
    return enter(id, auto: true)
  }

  /// The page to auto-PiP when den's window or app is left: the focused pane's video, else
  /// another shown pane's (a split).
  func awayTarget() -> String? {
    let order = (content.focused.map { [$0] } ?? []) + content.panes.filter { $0 != content.focused }
    // None qualifies: the one with a video, so the log says why it didn't go.
    return order.first { eligibleVideo($0) != nil } ?? order.first { eligibility($0).why != "no video" } ?? order.first
  }

  func hasVideo(_ id: String) -> Bool {
    guard let r = webviews.record(id), let w = r.webView else { return false }
    return r.videoFrame != nil || NativePiP.canToggle(w) || r.media.now?.flag("video") == true
  }

  func toggleTarget(_ args: Value) -> String? {
    if let id = args["webview"].string { return webviews.record(id)?.webView != nil ? id : nil }
    for id in [content.focused ?? content.panes.first, args["fallback"].string].compactMap({ $0 }) where hasVideo(id) { return id }
    return webviews.records.values.filter { $0.webView != nil && $0.videoFrame != nil }.map(\.id).sorted().first
  }

  // MARK: Into and out of PiP (WebKit's)

  /// Asks WebKit to show the page's main video in PiP. The page's standard API first (idempotent,
  /// the playing video in the frame that reported it); WebKit's main-content toggle when the page
  /// has nothing playing there (a paused video, a frame den hasn't heard from).
  @discardableResult
  func enter(_ id: String, auto isAuto: Bool) -> Bool {
    guard let r = webviews.record(id), let w = r.webView else { return false }
    if active.contains(id) || entering.contains(id) { return true }
    entering.insert(id)
    if isAuto { auto.insert(id) }
    // This request's number: a timer left from an earlier one must not act on this one.
    let gen = (attempts[id] ?? 0) + 1
    attempts[id] = gen
    let current: @MainActor () -> Bool = { [weak self] in self?.entering.contains(id) == true && self?.attempts[id] == gen }
    // WebKit's main-content toggle, when the page's API didn't do it. `pageAsked`: the page's
    // request was taken (WebKit may still get there; no toggle isn't a failure).
    let fallback: @MainActor (String, Bool) -> Void = { [weak self, weak w] why, pageAsked in
      guard let self, let w, current() else { return }
      if NativePiP.isActive(w) {
        self.note("pip enter \(id): toggle skipped (\(why)), WebKit already in")
        return
      }
      let ok = NativePiP.toggle(w)
      self.note("pip enter \(id): toggle (\(why)) -> \(ok ? "asked" : "unavailable")")
      if !ok, !pageAsked { self.failed(id) }
    }
    let state = "\(isAuto ? "auto" : "byHand") \(windowState) inWindow=\(w.window != nil)"
    if r.videoFrame != nil || r.frames["main"] != nil {
      let frame = r.videoFrame?.frame
      webviews.runPageScript(id, "return await window.__denMedia.pip()", frame: frame) { [weak self, weak w] res in
        guard let self else { return }
        switch res {
        case let .success(ok):
          self.note("pip enter \(id): js(\(frame.map { $0.isMainFrame ? "main" : "subframe" } ?? "main")) -> \((ok as? Bool).map { "\($0)" } ?? "\(ok)") \(state)")
          guard (ok as? Bool) == true else { return fallback("js false", false) }
          // The page's request taken (the promise settles once WebKit is in, or close to it),
          // WebKit not there yet: its own toggle after a while.
          DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            MainActor.assumeIsolated {
              guard current(), !self.active.contains(id), let w, !NativePiP.isActive(w) else { return }
              fallback("no WebKit call 2.5 s after js", true)
            }
          }
        case let .failure(e):
          self.note("pip enter \(id): js error \(e.localizedDescription) \(state)")
          fallback("js error", false)
        }
      }
    } else {
      fallback("no frame reported", false)
    }
    // WebKit says when it's in; a request it silently dropped mustn't block the next one.
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
      MainActor.assumeIsolated {
        guard let self, !self.active.contains(id), current() else { return }
        self.note("pip enter \(id): no WebKit call in 4 s, given up")
        self.failed(id)
      }
    }
    return true
  }

  func failed(_ id: String) {
    cancelled.remove(id)
    guard entering.remove(id) != nil else { return }
    auto.remove(id)
    appAway.remove(id)
  }

  /// Takes the page's video out of PiP, back into the page.
  func exit(_ id: String) {
    if entering.remove(id) != nil, !active.contains(id) { cancelled.insert(id) }
    guard active.contains(id), let r = webviews.record(id), let w = r.webView else {
      auto.remove(id)
      return
    }
    exiting.insert(id)
    leave(id, w, tries: 8)
  }

  /// One try at leaving: the page's API in the frame that reported PiP (WebKit may report PiP
  /// before the page's own event has), else WebKit's toggle; again a little later while WebKit
  /// still says it's in.
  private func leave(_ id: String, _ w: WKWebView, tries: Int) {
    guard active.contains(id), tries > 0, let r = webviews.record(id), r.webView === w else { return }
    let frame = r.frames.values.first { $0.media.pip }?.frame
    webviews.runPageScript(id, "return await window.__denMedia.exitPip()", frame: frame) { [weak self, weak w] res in
      guard let self, let w, self.active.contains(id) else { return }
      if case let .success(ok) = res, (ok as? Bool) == true { return }
      if NativePiP.isActive(w) { NativePiP.toggle(w); return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { MainActor.assumeIsolated { self.leave(id, w, tries: tries - 1) } }
    }
  }


  // MARK: WebKit's callbacks

  func pipChanged(_ id: String, _ on: Bool) {
    note("pip webkit \(id): \(on ? "in" : "out")\(auto.contains(id) ? " (auto)" : "")\(NativePiP.systemWindows().isEmpty ? "" : " systemWindow")")
    if on {
      entering.remove(id)
      guard active.insert(id).inserted else { return }
      // You were back before WebKit got there: straight out again.
      if cancelled.remove(id) != nil {
        host.emit("media.pip", ["webview": .string(id), "open": true, "auto": true])
        exit(id)
        return
      }
    } else {
      cancelled.remove(id)

      entering.remove(id)
      exiting.remove(id)
      auto.remove(id)
      appAway.remove(id)
      guard active.remove(id) != nil else { return }
    }
    host.emit("media.pip", ["webview": .string(id), "open": .bool(on), "auto": .bool(auto.contains(id))])
  }

  /// The PiP window's return button: back to the tab (its space and window), den in front.
  func returnButton(_ id: String) {
    guard active.contains(id) || entering.contains(id) else { return }
    exiting.insert(id)  // WebKit is taking it back into the page.
    host.emit("media.backToTab", ["webview": .string(id)])
    NSApp.unhide(nil)
    let win = windows.containing(webviews.record(id)?.webView?.window)?.window ?? wc.window
    if win.isMiniaturized { win.deminiaturize(nil) }
    NSApp.activate()
    win.makeKeyAndOrderFront(nil)
    // WebKit finishes the return once the page is back in a window; a tab nobody brought back
    // (no tabs plugin) mustn't leave the video stuck in PiP.
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
      MainActor.assumeIsolated { if self?.active.contains(id) == true { self?.exit(id) } }
    }
  }


  func forget(_ id: String) {
    guard active.contains(id) || entering.contains(id), let w = webviews.record(id)?.webView else { return }
    w.closeAllMediaPresentations {}
    pipChanged(id, false)
  }

  // MARK: When to enter and leave

  /// A tab leaving the screen (its web view still in the window).
  func leaving(_ id: String) {
    autoEnter(id, "tabLeave")
  }

  /// A page going (back) on screen: a PiP den started comes back into it.
  func returned(_ id: String) {
    guard auto.contains(id) else { return }
    note("pip back \(id): tab on screen, exit")
    appAway.remove(id)
    exit(id)
  }

  func observeWindows() {
    let nc = NotificationCenter.default
    let names: [(Notification.Name, AnyObject?)] = [
      (NSApplication.didHideNotification, nil), (NSApplication.didUnhideNotification, nil),
      (NSWindow.didChangeOcclusionStateNotification, nil), (NSWindow.didMiniaturizeNotification, nil),
      (NSWindow.didDeminiaturizeNotification, nil),
    ]
    // You switching to another app: caught before the window is covered or its Space left,
    // while the page is still on screen (and with den's window still showing behind the app).
    for (n, isActive) in [(NSApplication.didResignActiveNotification, false), (NSApplication.didBecomeActiveNotification, true)] {
      observers.append(nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.appActiveChanged(isActive) }
      })
    }
    // A Space switch (a desktop or a full-screen app's): occlusion should say so too.
    observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.spaceChanged() }
    })
    for (n, obj) in names {
      let raw = n.rawValue
      observers.append(nc.addObserver(forName: n, object: obj, queue: .main) { [weak self] note in
        nonisolated(unsafe) let sender = note.object
        MainActor.assumeIsolated {
          guard let self else { return }
          if let win = sender as? NSWindow {
            if self.windows.containing(win) == nil {
              // A page's full-screen video has a window of its own (WebKit moves the web view in).
              if let r = self.webviews.records.values.first(where: { $0.webView?.window === win }) { self.fullScreenChanged(r.id, win) }
              return
            }
          }
          self.windowStateChanged(raw)
        }
      })
    }
  }

  public private(set) var lastNotifications: [(String, TimeInterval)] = []

  func windowStateChanged(_ name: String) {
    // Automation's off-display windows (`--background`, tests) are never on screen: not "away".
    if Presentation.invisible { return }
    let now = ProcessInfo.processInfo.systemUptime

    lastNotifications.append((name, now))
    if lastNotifications.count > 16 { lastNotifications.removeFirst() }
    let visible = windowVisible
    if seen?.visible != visible {
      seen = (visible, now)
      let why = name.replacingOccurrences(of: "Notification", with: "").replacingOccurrences(of: "NSWindowDid", with: "").replacingOccurrences(of: "NSApplicationDid", with: "")
      note("pip window \(visible ? "visible" : "away") (\(why)) \(windowState)")
    }
    schedule(after: debounce)
  }

  /// den became (true) or stopped being (false) the active app.
  func appActiveChanged(_ isActive: Bool) {
    // Automation's off-display windows (`--background`, tests) never take part.
    if Presentation.invisible { return }
    if isActive {
      let back = content.panes.filter { auto.contains($0) }
      appAway.removeAll()
      // Not in sight yet (still minimized, its Space not shown): the window's own change does it.
      let visible = windowVisible
      note("pip app active \(windowState)\(back.isEmpty ? "" : visible ? ", exit \(back.joined(separator: ","))" : ", window not back yet")")
      guard visible else { return }
      for id in back { exit(id) }
      return
    }
    guard let id = awayTarget() else {
      note("pip appSwitch: no pane \(windowState)")
      return
    }
    if autoEnter(id, "appSwitch") { appAway.insert(id) }
  }

  /// den's window, as the log says it.
  var windowState: String {
    let w = wc.window
    return "appActive=\(NSApp.isActive) hidden=\(NSApp.isHidden) mini=\(w.isMiniaturized) onScreen=\(w.isVisible) occlusionVisible=\(w.occlusionState.contains(.visible)) activeSpace=\(w.isOnActiveSpace)"
  }

  func schedule(after delay: TimeInterval) {
    pending?.cancel()
    let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.evaluateWindow() } }
    pending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private var seen: (visible: Bool, since: TimeInterval)?

  /// den's window can be seen: not hidden, minimized, ordered out, covered, or on a Space that
  /// isn't shown. (Another app in front with den's window still showing: `appActiveChanged`.)
  public var windowVisible: Bool {
    if let v = windowVisibleForTests { return v }
    let w = wc.window
    return !NSApp.isHidden && w.isVisible && !w.isMiniaturized && w.occlusionState.contains(.visible) && w.isOnActiveSpace
  }

  /// Settled window state (after `debounce`): away -> the focused page's video into PiP; back ->
  /// out of it.
  public func evaluateWindow() {
    pending = nil
    let visible = windowVisible, now = ProcessInfo.processInfo.systemUptime
    if seen?.visible != visible { seen = (visible, now) }
    if let s = seen, now - s.since < debounce {
      schedule(after: debounce - (now - s.since))
      return
    }
    // A page whose video is full screen is in a window of its own (`fullScreenChanged`): den's
    // window on another Space then is no reason to go to PiP or back.
    let panes = content.panes.filter { fullScreenWindow($0) == nil }
    if visible {
      // Back in sight. A PiP from switching apps stays while the other app is in front.
      let back = panes.filter { auto.contains($0) && (NSApp.isActive || !appAway.contains($0)) }
      if !back.isEmpty { note("pip window back: exit \(back.joined(separator: ","))") }
      for id in back { exit(id) }
      return
    }
    guard let id = awayTarget(), panes.contains(id) else { return }
    autoEnter(id, "windowAway")
  }

  /// The window of `id`'s web view when it isn't one of den's (WebKit's full-screen window).
  func fullScreenWindow(_ id: String) -> NSWindow? {
    guard let win = webviews.record(id)?.webView?.window, windows.containing(win) == nil else { return nil }
    return win
  }

  /// A Space switch: full-screen video windows checked too (their occlusion may not change).
  func spaceChanged() {
    if Presentation.invisible { return }
    for id in webviews.records.keys.sorted() { if let win = fullScreenWindow(id) { fullScreenChanged(id, win) } }
    windowStateChanged("activeSpace")
  }

  /// A page's full-screen window became visible or not (its Space switched to or away from).
  func fullScreenChanged(_ id: String, _ win: NSWindow) {
    let visible = win.isVisible && win.occlusionState.contains(.visible) && win.isOnActiveSpace
    if visible {
      if fullScreenAway.remove(id) != nil, auto.contains(id) {
        note("pip fullScreen back \(id): exit")
        exit(id)
      }
      return
    }
    // Settled first: going full screen moves the window to a new Space, and on the way it is
    // briefly on none that's shown (CI run 37221053469: an enter, then an exit, as it went).
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak win] in
      MainActor.assumeIsolated {
        guard let self, let win, self.fullScreenWindow(id) === win,
              !(win.isVisible && win.occlusionState.contains(.visible) && win.isOnActiveSpace) else { return }
        if self.fullScreenAway.insert(id).inserted { self.note("pip fullScreen away \(id) activeSpace=\(win.isOnActiveSpace) occlusionVisible=\(win.occlusionState.contains(.visible))") }
        self.autoEnter(id, "fullScreenAway")
      }
    }
  }
}
