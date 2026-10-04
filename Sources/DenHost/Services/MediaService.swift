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
/// - den's window is minimized, hidden or covered by other windows (occluded), or a page's
///   full-screen video stops being visible (its Space was switched away from);
/// and comes back when you return (only a PiP den started; one you started stays, like Safari).
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
  /// Pages whose full-screen video window was out of sight (its Space switched away).
  private var fullScreenAway: Set<String> = []
  private var observers: [NSObjectProtocol] = []
  private var pending: DispatchWorkItem?
  public var debounce: TimeInterval = 0.2
  public var minDuration: Double = 5
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
  public func eligibleVideo(_ id: String) -> Value? {
    guard autoPip, let r = webviews.record(id), r.webView != nil, !r.discarding, !r.muted, let v = r.videoFrame?.media.video else { return nil }
    guard !v.flag("paused"), !v.flag("muted"), v.num("vol") > 0, v.num("vw") > 0, !v.flag("noPip") else { return nil }
    let dur = v.num("dur")
    guard dur < 0 || dur >= minDuration else { return nil }
    guard v.num("cw") >= 200, v.num("ch") >= 100 else { return nil }
    return v
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
    let fallback: @MainActor () -> Void = { [weak self, weak w] in
      guard let self, let w, self.entering.contains(id) else { return }
      if NativePiP.isActive(w) || !NativePiP.toggle(w) { self.failed(id) }
    }
    if r.videoFrame != nil || r.frames["main"] != nil {
      webviews.runPageScript(id, "return await window.__denMedia.pip()", frame: r.videoFrame?.frame) { res in
        if case let .success(ok) = res, (ok as? Bool) == true { return }
        fallback()
      }
    } else {
      fallback()
    }
    // WebKit says when it's in; a request it silently dropped mustn't block the next one.
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in MainActor.assumeIsolated { if self?.active.contains(id) == false { self?.failed(id) } } }
    return true
  }

  func failed(_ id: String) {
    guard entering.remove(id) != nil else { return }
    auto.remove(id)
  }

  /// Takes the page's video out of PiP, back into the page.
  func exit(_ id: String) {
    entering.remove(id)
    guard active.contains(id), let r = webviews.record(id), let w = r.webView else {
      auto.remove(id)
      return
    }
    exiting.insert(id)
    let frame = r.frames.values.first { $0.media.pip }?.frame
    webviews.runPageScript(id, "return await window.__denMedia.exitPip()", frame: frame) { [weak self, weak w] _ in
      guard let self, let w, self.active.contains(id) else { return }
      // The page's API found no PiP element (a frame den hasn't heard from): WebKit's toggle.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated {
        if self.active.contains(id), NativePiP.isActive(w) { NativePiP.toggle(w) }
      } }
    }
  }

  // MARK: WebKit's callbacks

  func pipChanged(_ id: String, _ on: Bool) {
    if on {
      entering.remove(id)
      guard active.insert(id).inserted else { return }
    } else {
      entering.remove(id)
      exiting.remove(id)
      auto.remove(id)
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
    guard !active.contains(id), eligibleVideo(id) != nil else { return }
    enter(id, auto: true)
  }

  /// A page going (back) on screen: a PiP den started comes back into it.
  func returned(_ id: String) {
    if auto.contains(id) { exit(id) }
  }

  func observeWindows() {
    let nc = NotificationCenter.default
    let names: [(Notification.Name, AnyObject?)] = [
      (NSApplication.didHideNotification, nil), (NSApplication.didUnhideNotification, nil),
      (NSWindow.didChangeOcclusionStateNotification, nil), (NSWindow.didMiniaturizeNotification, nil),
      (NSWindow.didDeminiaturizeNotification, nil),
    ]
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
    if seen?.visible != visible { seen = (visible, now) }
    schedule(after: debounce)
  }

  func schedule(after delay: TimeInterval) {
    pending?.cancel()
    let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.evaluateWindow() } }
    pending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private var seen: (visible: Bool, since: TimeInterval)?

  /// den's window can be seen: not hidden, minimized, ordered out or covered. (Another app in
  /// front with den's window still showing isn't leaving, as in Safari.)
  public var windowVisible: Bool {
    let w = wc.window
    return !NSApp.isHidden && w.isVisible && !w.isMiniaturized && w.occlusionState.contains(.visible)
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
    let shown = content.panes
    if visible {
      for id in shown where auto.contains(id) { exit(id) }
      return
    }
    guard let id = content.focused ?? shown.first, !active.contains(id), eligibleVideo(id) != nil else { return }
    enter(id, auto: true)
  }

  /// A page's full-screen window became visible or not (its Space switched to or away from).
  func fullScreenChanged(_ id: String, _ win: NSWindow) {
    let visible = win.isVisible && win.occlusionState.contains(.visible)
    if visible {
      if fullScreenAway.remove(id) != nil, auto.contains(id) { exit(id) }
      return
    }
    fullScreenAway.insert(id)
    guard !active.contains(id), eligibleVideo(id) != nil else { return }
    enter(id, auto: true)
  }
}
