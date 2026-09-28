import AppKit
import CordisValue
import WebKit

// thin-host: feature-specific, migrate to plugin (mini player triggers/policy -> a `media` plugin over generic panel + webviews media control)
/// `media` service: den's mini player (docs/host-api.md#media).
///
/// When the video you are watching would leave the screen, its tab's live web view moves into a
/// floating `MiniPlayerPanel` with only the video visible, and moves back when you return. The
/// page is never reloaded and no process is added. Triggers:
///   1. switching away from the tab (`content.show` without it),
///   2. den resigning active, 3. its window losing visibility (covered, minimized, another Space),
///   4. den being hidden. 2–4 settle for `debounce` first, so a quick ⌘-Tab there and back
///   neither opens the player nor flickers; returning to den brings the video back inline.
///
/// Only a video worth following triggers it (`eligible`): playing, audible (not muted by the page,
/// its volume, or the tab's mute; Arc doesn't trigger for a muted tab either), at least
/// `minDuration` long or live, at least 200x100 pt on the page, with a video track, and not
/// closed by the user earlier in this session. One mini player at a time.
///
/// Methods:
///   get                      -> {open, webview?, fromWindow?, stashed?, settings: {autoMiniPlayer, keepOnTop}}
///   settings {autoMiniPlayer?, keepOnTop?} -> {autoMiniPlayer, keepOnTop}   (persisted; both on by default)
///   open {webview}           -> ok, or {error} when it has no playing video
///   control {action, value?} -> ok. Drives the open player like its buttons and keys: play, pause, toggle,
///                               seek (s), skip (±s), seekpct (± fraction of the video), start, end, volume (0–1),
///                               mute (0/1), rate, cc (subtitles on/off), keepOnTop (0/1), unstash, pip, back, close
///   close                    -> ok (pauses the video)
/// Events: media.miniPlayer {webview, open}, media.backToTab {webview} (the tabs plugin selects it),
///   media.playback {webview, t, dur, paused, muted, vol, rate} (only while the player shows)
@MainActor
public final class MediaService: HostService {
  public let name = "media"
  let host: ServiceHost
  let webviews: WebViewsService
  let content: ContentService
  let wc: DenWindowController
  let storage: StorageService

  public private(set) var autoMiniPlayer = true
  /// The player floats over other apps' windows (its pin button, T). Off, it's a normal window.
  public private(set) var keepOnTop = true
  public private(set) var panel: MiniPlayerPanel?
  /// The web view the mini player shows.
  public private(set) var playerId: String?
  /// True when the player opened because den's window isn't visible (it returns when it is).
  public private(set) var fromWindow = false
  /// Videos closed by the user this session ("<webview> <src>"): they don't reopen the player.
  private var dismissed: Set<String> = []
  /// Tabs whose video den sent to system picture in picture (they return inline on show).
  private var systemPip: Set<String> = []
  private var observers: [NSObjectProtocol] = []
  private var pending: DispatchWorkItem?
  /// How long den's window state must settle before the player opens or returns (see
  /// docs/perf/memory.md for the measured notification bursts this has to cover).
  public var debounce: TimeInterval = 0.2
  public var minDuration: Double = 5
  private var corner = MiniPlayerPanel.Corner.bottomRight
  private var width = MiniPlayerPanel.defaultWidth
  static let ns = "media"

  public init(host: ServiceHost, webviews: WebViewsService, content: ContentService, window: DenWindowController, storage: StorageService) {
    self.host = host
    self.webviews = webviews
    self.content = content
    self.wc = window
    self.storage = storage
    let s = storage.handle(method: "get", args: ["ns": .string(Self.ns), "key": "settings"])
    autoMiniPlayer = s.flag("autoMiniPlayer", true)
    keepOnTop = s.flag("keepOnTop", true)
    corner = MiniPlayerPanel.Corner(rawValue: s.str("corner")) ?? .bottomRight
    width = CGFloat(s.num("width", Double(MiniPlayerPanel.defaultWidth)))
    content.adoptLeaving = { [weak self] id in self?.adoptLeaving(id) ?? false }
    content.willAttach = { [weak self] id in self?.willAttach(id) }
    webviews.onPlayback = { [weak self] id, v in self?.playback(id, v) }
    webviews.onMedia = { [weak self] r in self?.mediaChanged(r) }
    webviews.willDestroy = { [weak self] id in if id == self?.playerId { self?.dismiss(pause: false, remember: false) } }
    observeWindow()
  }

  public func handle(method: String, args: Value) -> Value {
    switch method {
    case "get":
      var v: Value = ["open": .bool(playerId != nil), "settings": ["autoMiniPlayer": .bool(autoMiniPlayer), "keepOnTop": .bool(keepOnTop)]]
      if let id = playerId { v = v.with("webview", .string(id)).with("fromWindow", .bool(fromWindow)) }
      if let side = panel?.stashed { v = v.with("stashed", .string(side.rawValue)) }
      if let p = panel, p.isVisible { v = v.with("frame", [.double(p.frame.minX), .double(p.frame.minY), .double(p.frame.width), .double(p.frame.height)]) }
      return v
    case "settings":
      if let on = args["autoMiniPlayer"].bool {
        autoMiniPlayer = on
        save()
      }
      if let on = args["keepOnTop"].bool { setKeepOnTop(on) }
      return ["autoMiniPlayer": .bool(autoMiniPlayer), "keepOnTop": .bool(keepOnTop)]
    case "open":
      let id = args.str("webview")
      guard let r = webviews.record(id), r.webView != nil, r.videoFrame != nil else { return .error("media: '\(id)' has no playing video") }
      if content.panes.contains(id), let w = content.detachForMini(id) { open(id, w, fromWindow: false) } else if let w = r.webView { open(id, w, fromWindow: false) }
    case "control":
      guard playerId != nil else { return .error("media: no mini player") }
      control(args.str("action"), args.num("value"))
    case "close":
      guard playerId != nil else { return .error("media: no mini player") }
      control("close", 0)
    default:
      return .error("media: unknown method '\(method)'")
    }
    return .ok
  }

  func save() {
    _ = storage.handle(method: "set", args: ["ns": .string(Self.ns), "key": "settings", "value": [
      "autoMiniPlayer": .bool(autoMiniPlayer), "keepOnTop": .bool(keepOnTop), "corner": .string(corner.rawValue), "width": .double(Double(width)),
    ]])
  }

  func setKeepOnTop(_ on: Bool) {
    keepOnTop = on
    panel?.keepOnTop = on
    save()
  }

  /// The chip's text: the page's host without "www." ("youtube.com").
  static func hostLabel(_ url: String) -> String {
    guard let h = URL(string: url)?.host, !h.isEmpty else { return "" }
    return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
  }

  // MARK: Eligibility

  /// The video den would follow for tab `id`, if it's worth a mini player (see the type doc).
  public func eligibleVideo(_ id: String) -> Value? {
    guard autoMiniPlayer, let r = webviews.record(id), r.webView != nil, !r.discarding, !r.muted, let v = r.videoFrame?.media.video else { return nil }
    guard !v.flag("paused"), !v.flag("muted"), v.num("vol") > 0, v.num("vw") > 0 else { return nil }
    let dur = v.num("dur")
    guard dur < 0 || dur >= minDuration else { return nil }
    guard v.num("cw") >= 200, v.num("ch") >= 100 else { return nil }
    guard !dismissed.contains(key(id, v)) else { return nil }
    return v
  }

  func key(_ id: String, _ v: Value) -> String { id + " " + v.str("src") }

  // MARK: Triggers

  /// Trigger 1: a tab leaving the screen (`content.show` without it).
  func adoptLeaving(_ id: String) -> Bool {
    guard eligibleVideo(id) != nil, let w = webviews.record(id)?.webView else { return false }
    open(id, w, fromWindow: false)
    return true
  }

  /// A page's web view is going back into its card: the player lets go of it.
  func willAttach(_ id: String) {
    if id == playerId { release() }
    if systemPip.remove(id) != nil {
      webviews.runPageScript(id, "return await window.__denMedia.exitPip()")
    }
  }

  /// Triggers 2–4: den resigns active, is hidden, or its window stops being visible; and the way
  /// back. Notifications only (no polling); each burst settles for `debounce`.
  func observeWindow() {
    let nc = NotificationCenter.default
    let names: [(Notification.Name, AnyObject?)] = [
      (NSApplication.didResignActiveNotification, nil), (NSApplication.didBecomeActiveNotification, nil),
      (NSApplication.didHideNotification, nil), (NSApplication.didUnhideNotification, nil),
      (NSWindow.didChangeOcclusionStateNotification, wc.window), (NSWindow.didMiniaturizeNotification, wc.window),
      (NSWindow.didDeminiaturizeNotification, wc.window),
    ]
    for (n, obj) in names {
      let raw = n.rawValue
      observers.append(nc.addObserver(forName: n, object: obj, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.windowStateChanged(raw) }
      })
    }
  }

  /// Times of the last window-state notifications (docs/perf: the debounce is measured against them).
  public private(set) var lastNotifications: [(String, TimeInterval)] = []

  /// den resigned active and hasn't come back (trigger 2). Tracked from the notifications rather
  /// than `NSApp.isActive`, so a den that was never frontmost (launched in the background) still
  /// counts as present while its window is on screen.
  private var resignedActive = false

  func windowStateChanged(_ name: String) {
    if name == NSApplication.didResignActiveNotification.rawValue { resignedActive = true }
    if name == NSApplication.didBecomeActiveNotification.rawValue { resignedActive = false }
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

  /// The window state last seen, and since when: den acts only on a state that held for `debounce`.
  private var seen: (visible: Bool, since: TimeInterval)?

  /// Is den's main window on screen, and den not switched away from?
  public var windowVisible: Bool {
    let w = wc.window
    return !resignedActive && !NSApp.isHidden && w.isVisible && !w.isMiniaturized && w.occlusionState.contains(.visible)
  }

  public func evaluateWindow() {
    pending = nil
    let visible = windowVisible, now = ProcessInfo.processInfo.systemUptime
    if seen?.visible != visible { seen = (visible, now) }
    if let s = seen, now - s.since < debounce {
      schedule(after: debounce - (now - s.since))
      return
    }
    if visible {
      if let id = playerId, fromWindow { content.reattach(id) }  // reattach -> willAttach -> release
      return
    }
    guard playerId == nil || !fromWindow, let id = content.focused ?? content.panes.first, id != playerId,
          eligibleVideo(id) != nil, let w = content.detachForMini(id) else { return }
    open(id, w, fromWindow: true)
  }

  // MARK: Player

  func open(_ id: String, _ w: WKWebView, fromWindow: Bool) {
    if let old = playerId, old != id { dismiss(pause: true, remember: false) }
    let r = webviews.record(id)
    let frame = r?.videoFrame?.frame
    let v = r?.videoFrame?.media.video ?? .null
    let p = panel ?? makePanel()
    playerId = id
    self.fromWindow = fromWindow
    p.player.controls.update(v)
    p.player.controls.setHost(Self.hostLabel(r?.url ?? ""))
    p.keepOnTop = keepOnTop
    p.present(w, videoSize: CGSize(width: v.num("vw", 16), height: v.num("vh", 9)), corner: corner, width: width, on: wc.window.screen)
    p.player.showControls(false, animated: false)
    webviews.runPageScript(id, "return window.__denMedia.isolate(true) && window.__denMedia.live(true)", frame: frame) { [weak self] res in
      guard let self, self.playerId == id else { return }
      // No video to isolate (it just ended or moved): system picture in picture, or give up.
      if case let .success(ok) = res, (ok as? Bool) == true { return }
      self.control("pip", 0)
    }
    host.emit("media.miniPlayer", ["webview": .string(id), "open": true])
  }

  func makePanel() -> MiniPlayerPanel {
    let p = MiniPlayerPanel()
    p.onControl = { [weak self] a, v in self?.control(a, v) }
    p.onPlaced = { [weak self] c, w in
      self?.corner = c
      self?.width = w
      self?.save()
    }
    panel = p
    return p
  }

  /// A control from the panel (or `media.control`).
  func control(_ action: String, _ value: Double) {
    guard let id = playerId else { return }
    let frame = webviews.record(id)?.videoFrame?.frame
    switch action {
    case "back":
      host.emit("media.backToTab", ["webview": .string(id)])
      NSApp.unhide(nil)
      if wc.window.isMiniaturized { wc.window.deminiaturize(nil) }
      NSApp.activate()
      wc.window.makeKeyAndOrderFront(nil)
      // Already the tab on screen (the player opened because den was away): bring it back now.
      if content.panes.contains(id) { content.reattach(id) }
    case "close":
      dismiss(pause: true, remember: true)
    case "keepOnTop":
      setKeepOnTop(value != 0)
    case "unstash":
      panel?.unstash()
    case "pip":
      webviews.runPageScript(id, "return await window.__denMedia.pip()", frame: frame) { [weak self] res in
        guard let self, self.playerId == id else { return }
        if case let .success(ok) = res, (ok as? Bool) == true { self.systemPip.insert(id) }
        self.dismiss(pause: false, remember: false)
      }
    default:
      webviews.runPageScript(id, "return window.__denMedia.cmd(a, x)", arguments: ["a": action, "x": value], frame: frame)
    }
  }

  func playback(_ id: String, _ v: Value) {
    guard id == playerId else { return }
    panel?.player.controls.update(v)
    host.emit("media.playback", v.with("webview", .string(id)))
  }

  func mediaChanged(_ r: WebRecord) {
    // The page navigated away or the video went: nothing left to show.
    if r.id == playerId, r.videoFrame == nil { dismiss(pause: false, remember: false) }
  }

  /// The video returns to its tab: undo the isolation and hand the web view back to the caller.
  func release() {
    guard let id = playerId else { return }
    let frame = webviews.record(id)?.videoFrame?.frame
    playerId = nil
    webviews.runPageScript(id, "window.__denMedia.live(false); return window.__denMedia.isolate(false)", frame: frame)
    closePanel()
    host.emit("media.miniPlayer", ["webview": .string(id), "open": false])
  }

  /// Closes the player without returning to the tab: the page stays live but off screen.
  func dismiss(pause: Bool, remember: Bool) {
    guard let id = playerId else { return }
    let r = webviews.record(id)
    if remember, let v = r?.videoFrame?.media.video { dismissed.insert(key(id, v)) }
    if pause { webviews.runPageScript(id, "window.__denMedia.cmd('pause')", frame: r?.videoFrame?.frame) }
    let wasFromWindow = fromWindow
    release()
    // Still the tab in den's (hidden) window: put it back in its card for when den returns.
    if wasFromWindow, content.panes.contains(id) { content.reattach(id) }
  }

  func closePanel() {
    guard let p = panel else { return }
    p.player.setWeb(nil)
    p.orderOut(nil)
    // Nothing stays around while no video plays.
    panel = nil
  }
}
