import AppKit
import CordisValue
import WebKit

// thin-host: feature-specific, migrate to plugin (keep a generic floating panel + slider/button/time-label nodes in the host)
/// den's mini player: a frameless, always-on-top panel that shows one tab's live web view with only
/// its video visible (the page script isolates it), and den's own controls on hover.
///
/// - Non-activating: clicking it never brings den forward, but it takes keys once clicked
///   (space, ←/→ seek 5 s, ↑/↓ volume, M mute).
/// - On every Space and over full-screen apps.
/// - Drag anywhere to move; drag a corner to resize (the video's aspect ratio stays locked). On
///   release it snaps to the nearest screen corner, which `onPlaced` persists.
/// - Double-click returns to the tab.
///
/// Arc's mini player (docs/research/arc.md §12) floats bottom-right, resizes from a corner, seeks
/// with the arrow keys and plays/pauses with space; every size here is den's estimate.
@MainActor
public final class MiniPlayerPanel: NSPanel {
  public enum Corner: String { case topLeft, topRight, bottomLeft, bottomRight }
  static let margin: CGFloat = 16
  static let minWidth: CGFloat = 256
  static let defaultWidth: CGFloat = 400

  public let player = MiniPlayerView()
  /// A control was used: `play`, `pause`, `toggle`, `seek`, `skip`, `volume`, `mute`, `rate`,
  /// `pip`, `back`, `close`.
  var onControl: ((String, Double) -> Void)?
  /// The panel came to rest at a corner with a width.
  var onPlaced: ((Corner, CGFloat) -> Void)?
  var aspect: CGFloat = 16 / 9
  /// Tucked off the left or right screen edge (Dia's stash): only `stashPeek` pt stay on screen.
  public enum Side: String { case left, right }
  public private(set) var stashed: Side?
  static let stashPeek: CGFloat = 28
  /// "Keep on top": floats over other apps' windows (the default). Off, it's a normal window.
  public var keepOnTop = true {
    didSet {
      level = keepOnTop ? .floating : .normal
      player.controls.setKeepOnTop(keepOnTop)
    }
  }

  public init() {
    super.init(contentRect: NSRect(x: 0, y: 0, width: Self.defaultWidth, height: Self.defaultWidth * 9 / 16),
               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    isFloatingPanel = true
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    animationBehavior = .utilityWindow
    contentView = player
    player.onControl = { [weak self] a, v in self?.onControl?(a, v) }
    player.onMove = { [weak self] e in self?.drag(e) }
    player.onResize = { [weak self] corner, e in self?.resize(from: corner, e) }
  }

  public override var canBecomeKey: Bool { true }
  public override var canBecomeMain: Bool { false }

  /// Shows `web` in the panel, sized for a video of `videoSize` (pixels), at `corner`.
  func present(_ web: WKWebView, videoSize: CGSize, corner: Corner, width: CGFloat, on screen: NSScreen?) {
    aspect = videoSize.width > 0 && videoSize.height > 0 ? min(3, max(0.5, videoSize.width / videoSize.height)) : 16 / 9
    setStashed(nil)
    player.setWeb(web)
    let vf = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let w = clampWidth(width, in: vf)
    setFrame(Self.frame(corner: corner, size: NSSize(width: w, height: (w / aspect).rounded()), in: vf), display: false)
    orderFrontRegardless()
    invalidateShadow()
  }

  func clampWidth(_ w: CGFloat, in vf: NSRect) -> CGFloat {
    let maxW = min(vf.width * 0.6, vf.height * 0.6 * aspect)
    return max(Self.minWidth, min(w, maxW)).rounded()
  }

  static func frame(corner: Corner, size: NSSize, in vf: NSRect) -> NSRect {
    let m = margin
    let x = corner == .topLeft || corner == .bottomLeft ? vf.minX + m : vf.maxX - m - size.width
    let y = corner == .bottomLeft || corner == .bottomRight ? vf.minY + m : vf.maxY - m - size.height
    return NSRect(x: x, y: y, width: size.width, height: size.height)
  }

  /// The screen corner nearest to `frame`'s center.
  static func nearestCorner(_ frame: NSRect, in vf: NSRect) -> Corner {
    let left = frame.midX < vf.midX, bottom = frame.midY < vf.midY
    return bottom ? (left ? .bottomLeft : .bottomRight) : (left ? .topLeft : .topRight)
  }

  /// Dropped with more than half of it past the left or right screen edge: tuck it there.
  static func stashSide(_ frame: NSRect, in vf: NSRect) -> Side? {
    if frame.midX < vf.minX { return .left }
    if frame.midX > vf.maxX { return .right }
    return nil
  }

  /// The tucked frame: `stashPeek` pt of the player left on screen at that edge, kept on screen
  /// vertically.
  static func stashFrame(_ frame: NSRect, side: Side, in vf: NSRect) -> NSRect {
    let y = min(max(frame.minY, vf.minY + margin), vf.maxY - margin - frame.height)
    let x = side == .left ? vf.minX - frame.width + stashPeek : vf.maxX - stashPeek
    return NSRect(x: x, y: y, width: frame.width, height: frame.height)
  }

  func setStashed(_ side: Side?) {
    stashed = side
    player.setStashed(side)
  }

  // MARK: Move and resize

  private var dragStart: (mouse: NSPoint, frame: NSRect)?
  private var dragged = false

  func drag(_ e: NSEvent) {
    switch e.type {
    case .leftMouseDown:
      dragStart = (NSEvent.mouseLocation, frame)
      dragged = false
    case .leftMouseDragged:
      guard let s = dragStart else { return }
      let p = NSEvent.mouseLocation
      if hypot(p.x - s.mouse.x, p.y - s.mouse.y) > 3 { dragged = true }
      setFrameOrigin(NSPoint(x: s.frame.minX + p.x - s.mouse.x, y: s.frame.minY + p.y - s.mouse.y))
    default:
      guard dragStart != nil else { return }
      dragStart = nil
      // A click on a tucked player brings it back.
      if stashed != nil, !dragged { unstash(); return }
      snap()
    }
  }

  /// Back from the edge, to the nearest corner on that side.
  public func unstash() {
    guard let side = stashed else { return }
    let vf = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
    setStashed(nil)
    let bottom = frame.midY < vf.midY
    let corner: Corner = side == .left ? (bottom ? .bottomLeft : .topLeft) : (bottom ? .bottomRight : .topRight)
    let target = Self.frame(corner: corner, size: frame.size, in: vf)
    glide(to: target)
    onPlaced?(corner, target.width)
  }

  /// Moves to `target` with Dia's easing (at once with Reduce Motion).
  func glide(to target: NSRect) {
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      setFrame(target, display: true)
    } else {
      NSAnimationContext.runAnimationGroup { c in
        c.duration = 0.22
        c.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)  // estimate: Dia's easing (spec §13)
        animator().setFrame(target, display: true)
      }
    }
  }

  func resize(from corner: Corner, _ e: NSEvent) {
    switch e.type {
    case .leftMouseDown: dragStart = (NSEvent.mouseLocation, frame)
    case .leftMouseDragged:
      guard let s = dragStart else { return }
      let p = NSEvent.mouseLocation
      let dx = corner == .topRight || corner == .bottomRight ? p.x - s.mouse.x : s.mouse.x - p.x
      let vf = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
      let w = clampWidth(s.frame.width + dx, in: vf), h = (w / aspect).rounded()
      // The opposite corner stays put.
      let x = corner == .topRight || corner == .bottomRight ? s.frame.minX : s.frame.maxX - w
      let y = corner == .bottomLeft || corner == .bottomRight ? s.frame.maxY - h : s.frame.minY
      setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
      invalidateShadow()
    default:
      if dragStart != nil { dragStart = nil; snap() }
    }
  }

  /// Glides to the nearest screen corner and reports where it rests; dropped more than half past
  /// the left or right screen edge, it tucks there instead (the corner isn't saved).
  func snap() {
    let vf = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
    if let side = Self.stashSide(frame, in: vf) {
      setStashed(side)
      glide(to: Self.stashFrame(frame, side: side, in: vf))
      return
    }
    setStashed(nil)
    let corner = Self.nearestCorner(frame, in: vf)
    let target = Self.frame(corner: corner, size: frame.size, in: vf)
    glide(to: target)
    onPlaced?(corner, target.width)
  }

  // MARK: Keys

  /// The player's keys, and Firefox's picture-in-picture keys: ⌘← / ⌘→ a tenth of the video,
  /// Home / End its start and end, ⌘↓ / ⌘↑ mute and unmute, ⌘W close. Plus C (subtitles) and
  /// T (keep on top).
  public override func keyDown(with e: NSEvent) {
    let v = player.volume
    let cmd = e.modifierFlags.contains(.command)
    switch (e.keyCode, cmd) {
    case (49, false): onControl?("toggle", 0)  // space
    case (123, false): onControl?("skip", -5)  // ←
    case (124, false): onControl?("skip", 5)  // →
    case (123, true): onControl?("seekpct", -0.1)  // ⌘←
    case (124, true): onControl?("seekpct", 0.1)  // ⌘→
    case (115, _): onControl?("start", 0)  // Home
    case (119, _): onControl?("end", 0)  // End
    case (126, false): onControl?("volume", min(1, v + 0.1))  // ↑
    case (125, false): onControl?("volume", max(0, v - 0.1))  // ↓
    case (126, true): onControl?("mute", 0)  // ⌘↑
    case (125, true): onControl?("mute", 1)  // ⌘↓
    case (46, false): onControl?("mute", player.muted ? 0 : 1)  // M
    case (8, false): if player.controls.captionState > 0 { onControl?("cc", 0) }  // C
    case (17, false): onControl?("keepOnTop", keepOnTop ? 0 : 1)  // T
    case (13, true): onControl?("close", 0)  // ⌘W
    case (53, _): onControl?("back", 0)  // Esc: back to the tab
    default: super.keyDown(with: e)
    }
  }

  /// ⌘W and ⌘-arrows reach `keyDown` (not the main menu's Close Tab, Back or Forward) while the
  /// player is key.
  public override func performKeyEquivalent(with e: NSEvent) -> Bool {
    let flags = e.modifierFlags.intersection([.command, .shift, .option, .control])
    if flags == .command, [13, 123, 124, 125, 126].contains(e.keyCode) {
      keyDown(with: e)
      return true
    }
    return super.performKeyEquivalent(with: e)
  }
}

/// The panel's content: the web view, and den's controls over it (shown on hover and while
/// paused). Controls never reach the page: the overlay takes every click.
@MainActor
public final class MiniPlayerView: NSView {
  let webBox = NSView()
  public let controls = MiniControlsView()
  var onControl: ((String, Double) -> Void)? {
    get { controls.onControl }
    set { controls.onControl = newValue }
  }
  var onMove: ((NSEvent) -> Void)? {
    get { controls.onMove }
    set { controls.onMove = newValue }
  }
  var onResize: ((MiniPlayerPanel.Corner, NSEvent) -> Void)? {
    get { controls.onResize }
    set { controls.onResize = newValue }
  }
  var volume: Double { controls.volume }
  var muted: Bool { controls.muted }
  private var hideWork: DispatchWorkItem?
  /// While tucked off an edge: a dark strip with a chevron pointing back on screen.
  let stashTab = StashTabView()
  public private(set) var stashed: MiniPlayerPanel.Side?

  public override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 12  // estimate: Little Arc's window radius
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = true
    layer?.backgroundColor = NSColor.black.cgColor
    webBox.wantsLayer = true
    addSubview(webBox)
    addSubview(controls)
    addSubview(stashTab)
    stashTab.isHidden = true
    controls.alphaValue = 0
  }
  required init?(coder: NSCoder) { fatalError() }

  /// Tucked: the controls fade out, the strip shows, and every click drags or brings it back.
  func setStashed(_ side: MiniPlayerPanel.Side?) {
    stashed = side
    stashTab.side = side
    stashTab.isHidden = side == nil
    showControls(false, animated: false)
    needsLayout = true
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    if stashed != nil { return frame.contains(point) ? controls : nil }
    return super.hitTest(point)
  }

  func setWeb(_ w: WKWebView?) {
    webBox.subviews.forEach { $0.removeFromSuperview() }
    if let w { webBox.addSubview(w); w.frame = webBox.bounds; w.autoresizingMask = [.width, .height] }
  }

  var web: WKWebView? { webBox.subviews.first as? WKWebView }

  public override func layout() {
    super.layout()
    webBox.frame = bounds
    web?.frame = webBox.bounds
    controls.frame = bounds
    // The strip is the part left on screen: the right edge when tucked left, and vice versa.
    let peek = MiniPlayerPanel.stashPeek
    stashTab.frame = stashed == .left ? NSRect(x: bounds.width - peek, y: 0, width: peek, height: bounds.height)
      : NSRect(x: 0, y: 0, width: peek, height: bounds.height)
  }

  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
  }

  public override func mouseEntered(with event: NSEvent) { showControls(true) }
  public override func mouseMoved(with event: NSEvent) { showControls(true) }
  public override func mouseExited(with event: NSEvent) { showControls(false) }

  /// Fades the controls in (or out, unless paused or scrubbing).
  public func showControls(_ on: Bool, animated: Bool = true) {
    hideWork?.cancel()
    let visible = stashed == nil && (on || controls.paused || controls.scrubbing)
    let target: CGFloat = visible ? 1 : 0
    guard controls.alphaValue != target else { return }
    if !animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      controls.alphaValue = target
      return
    }
    NSAnimationContext.runAnimationGroup { c in
      c.duration = visible ? 0.15 : 0.3
      controls.animator().alphaValue = target
    }
  }
}

/// Play/pause, ±10 s, the seek bar with elapsed and remaining time, mute and volume, playback
/// speed, native picture in picture, back to the tab, and close. Every size is den's estimate.
@MainActor
public final class MiniControlsView: NSView {
  var onControl: ((String, Double) -> Void)?
  var onMove: ((NSEvent) -> Void)?
  var onResize: ((MiniPlayerPanel.Corner, NSEvent) -> Void)?
  lazy var back = button("arrow.up.left.and.arrow.down.right", "Back to Tab (Esc, or double-click)") { [weak self] in self?.onControl?("back", 0) }
  lazy var pip = button("pip.enter", "Picture in Picture") { [weak self] in self?.onControl?("pip", 0) }
  lazy var close = button("xmark", "Close (pauses the video)") { [weak self] in self?.onControl?("close", 0) }
  lazy var rewind = button("gobackward.10", "Back 10 Seconds (←: 5 s)") { [weak self] in self?.onControl?("skip", -10) }
  lazy var play = button("pause.fill", "Pause (Space)") { [weak self] in self?.onControl?("toggle", 0) }
  lazy var forward = button("goforward.10", "Forward 10 Seconds (→: 5 s)") { [weak self] in self?.onControl?("skip", 10) }
  lazy var mute = button("speaker.wave.2.fill", "Mute (M)") { [weak self] in
    guard let self else { return }
    self.onControl?("mute", self.muted ? 0 : 1)
  }
  lazy var speed = TextButton(title: "1×", tooltip: "Playback Speed") { [weak self] in self?.cycleSpeed() }
  lazy var keepOnTop = button("pin.fill", "Keep on Top: On (T)") { [weak self] in
    guard let self else { return }
    self.onControl?("keepOnTop", self.onTop ? 0 : 1)
  }
  /// The page's host ("youtube.com") in a chip at the top: back to the tab.
  lazy var host = TextButton(title: "", tooltip: "Back to Tab (Esc)") { [weak self] in self?.onControl?("back", 0) }
  /// Shown when the video has subtitle or caption tracks; filled while they show.
  lazy var captions = TextButton(title: "CC", tooltip: "Show Subtitles (C)") { [weak self] in self?.onControl?("cc", 0) }
  let seek = MiniSlider()
  let volumeSlider = MiniSlider()
  let elapsed = MiniControlsView.timeLabel(.left)
  let remaining = MiniControlsView.timeLabel(.right)

  private(set) var paused = false
  private(set) var muted = false
  private(set) var volume: Double = 1
  private(set) var rate: Double = 1
  private(set) var time: Double = 0
  private(set) var duration: Double = 0
  /// The video's text tracks: 0 none, 1 available, 2 showing.
  private(set) var captionState = 0
  private(set) var onTop = true
  var scrubbing: Bool { seek.tracking || volumeSlider.tracking }
  static let rates: [Double] = [1, 1.25, 1.5, 2, 0.5, 0.75]

  public override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    addSubview(scrims)
    for b in [back, pip, close, rewind, play, forward, mute] { addSubview(b) }
    // The transport buttons sit on soft dark discs so they read over any frame.
    for b in [rewind, play, forward] {
      b.wantsLayer = true
      b.layer?.backgroundColor = NSColor(white: 0, alpha: 0.32).cgColor
      b.hoverFill = NSColor(white: 1, alpha: 0.18)
      b.round = true
    }
    addSubview(speed)
    addSubview(keepOnTop)
    addSubview(host)
    addSubview(captions)
    host.isHidden = true
    captions.isHidden = true
    for v in [seek, volumeSlider] { addSubview(v) }
    addSubview(elapsed)
    addSubview(remaining)
    seek.toolTip = "Seek"
    volumeSlider.toolTip = "Volume"
    seek.onChange = { [weak self] f, done in
      guard let self, self.duration > 0 else { return }
      self.time = f * self.duration
      self.updateTimes()
      self.onControl?("seek", self.time)
      if done { self.superviewShowControls() }
    }
    volumeSlider.onChange = { [weak self] f, _ in
      self?.volume = f
      self?.onControl?("volume", f)
    }
    volumeSlider.value = 1
  }
  required init?(coder: NSCoder) { fatalError() }

  func superviewShowControls() { (superview as? MiniPlayerView)?.showControls(true) }

  func setKeepOnTop(_ on: Bool) {
    onTop = on
    keepOnTop.icon.spec = on ? "sf:pin.fill" : "sf:pin.slash"
    keepOnTop.toolTip = on ? "Keep on Top: On (T)" : "Keep on Top: Off (T)"
  }

  /// The page's host on the chip; empty hides it.
  func setHost(_ h: String) {
    host.title = h
    host.isHidden = h.isEmpty
    needsLayout = true
  }

  func button(_ symbol: String, _ tip: String, _ action: @escaping () -> Void) -> IconButton {
    let b = IconButton(symbol: symbol, size: 28, action: action)
    b.fixedTint = .white
    b.firstMouse = true
    b.toolTip = tip
    return b
  }

  static func timeLabel(_ align: NSTextAlignment) -> NSTextField {
    let l = NSTextField(labelWithString: "0:00")
    l.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
    l.textColor = NSColor(white: 1, alpha: 0.85)
    l.alignment = align
    return l
  }

  func cycleSpeed() {
    let i = Self.rates.firstIndex(of: rate) ?? 0
    onControl?("rate", Self.rates[(i + 1) % Self.rates.count])
  }

  /// Playback state from the page (`{t, dur, paused, muted, vol, rate}`); `dur` -1 is a live stream.
  func update(_ v: Value) {
    if v["t"].double != nil, !seek.tracking { time = v.num("t") }
    if v["dur"].double != nil { duration = v.num("dur") }
    paused = v.flag("paused", paused)
    muted = v.flag("muted", muted)
    if let vol = v["vol"].double, !volumeSlider.tracking { volume = vol }
    if let r = v["rate"].double { rate = r }
    if let c = v["cc"].double {
      captionState = Int(c)
      captions.isHidden = captionState == 0
      captions.selected = captionState == 2
      captions.toolTip = captionState == 2 ? "Hide Subtitles (C)" : "Show Subtitles (C)"
      needsLayout = true
    }
    play.icon.spec = paused ? "sf:play.fill" : "sf:pause.fill"
    play.toolTip = paused ? "Play (Space)" : "Pause (Space)"
    mute.icon.spec = muted || volume == 0 ? "sf:speaker.slash.fill" : volume < 0.5 ? "sf:speaker.wave.1.fill" : "sf:speaker.wave.2.fill"
    mute.toolTip = muted ? "Unmute (M)" : "Mute (M)"
    if !volumeSlider.tracking { volumeSlider.value = muted ? 0 : volume }
    speed.title = Self.rateText(rate)
    let live = duration < 0
    seek.isHidden = live
    rewind.enabled = !live
    forward.enabled = !live
    updateTimes()
    if paused { superviewShowControls() }
  }

  static func rateText(_ r: Double) -> String {
    r == r.rounded() ? "\(Int(r))×" : String(format: "%g×", r)
  }

  func updateTimes() {
    if duration < 0 {
      elapsed.stringValue = "LIVE"
      remaining.stringValue = ""
      return
    }
    elapsed.stringValue = Self.clock(time)
    remaining.stringValue = "-" + Self.clock(max(0, duration - time))
    if !seek.tracking { seek.value = duration > 0 ? min(1, time / duration) : 0 }
  }

  /// "1:05", "12:40", "1:02:03".
  static func clock(_ s: Double) -> String {
    guard s.isFinite, s >= 0 else { return "0:00" }
    let t = Int(s), h = t / 3600, m = (t % 3600) / 60, sec = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
  }

  let scrims = ScrimView()

  public override func layout() {
    super.layout()
    let w = bounds.width, h = bounds.height
    scrims.frame = bounds
    for b in [rewind, play, forward] { b.layer?.cornerRadius = b.frame.height / 2 }
    back.frame = NSRect(x: 8, y: 8, width: 28, height: 28)
    pip.frame = NSRect(x: 38, y: 8, width: 28, height: 28)
    close.frame = NSRect(x: w - 36, y: 8, width: 28, height: 28)
    keepOnTop.frame = NSRect(x: w - 66, y: 8, width: 28, height: 28)
    // The host chip, centred between the two button groups, as wide as the name.
    let hw = min(max(0, w - 2 * 76), naturalWidth(host.label) + 20)
    host.frame = NSRect(x: ((w - hw) / 2).rounded(), y: 12, width: hw, height: 20)
    let big: CGFloat = 44
    play.frame = NSRect(x: (w - big) / 2, y: (h - big) / 2, width: big, height: big)
    rewind.frame = NSRect(x: play.frame.minX - 50, y: (h - 34) / 2, width: 34, height: 34)
    forward.frame = NSRect(x: play.frame.maxX + 16, y: (h - 34) / 2, width: 34, height: 34)
    for b in [rewind, play, forward] { b.layer?.cornerRadius = b.frame.height / 2 }
    let row1 = h - 44
    mute.frame = NSRect(x: 8, y: row1, width: 24, height: 24)
    volumeSlider.frame = NSRect(x: 34, y: row1 + 4, width: 60, height: 16)
    speed.frame = NSRect(x: w - 44, y: row1 + 2, width: 36, height: 20)
    captions.frame = NSRect(x: w - 84, y: row1 + 2, width: 36, height: 20)
    let row2 = h - 20
    elapsed.frame = NSRect(x: 10, y: row2 - 1, width: 44, height: 14)
    remaining.frame = NSRect(x: w - 54, y: row2 - 1, width: 44, height: 14)
    seek.frame = NSRect(x: 56, y: row2 - 2, width: max(10, w - 112), height: 16)
  }

  // MARK: Mouse: move, resize from the corners, double-click back to the tab

  static let cornerSize: CGFloat = 18
  private var resizing: MiniPlayerPanel.Corner?

  func corner(at p: NSPoint) -> MiniPlayerPanel.Corner? {
    let c = Self.cornerSize, w = bounds.width, h = bounds.height
    let left = p.x < c, right = p.x > w - c, top = p.y < c, bottom = p.y > h - c
    if top && left { return .topLeft }
    if top && right { return .topRight }
    if bottom && left { return .bottomLeft }
    if bottom && right { return .bottomRight }
    return nil
  }

  public override func resetCursorRects() {
    let c = Self.cornerSize, w = bounds.width, h = bounds.height
    let rects: [(NSRect, NSCursor.FrameResizePosition)] = [
      (NSRect(x: 0, y: 0, width: c, height: c), .topLeft), (NSRect(x: w - c, y: 0, width: c, height: c), .topRight),
      (NSRect(x: 0, y: h - c, width: c, height: c), .bottomLeft), (NSRect(x: w - c, y: h - c, width: c, height: c), .bottomRight),
    ]
    for (r, pos) in rects { addCursorRect(r, cursor: NSCursor.frameResize(position: pos, directions: .all)) }
  }

  public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  public override var mouseDownCanMoveWindow: Bool { false }

  public override func mouseDown(with e: NSEvent) {
    window?.makeKey()
    if e.clickCount == 2 { onControl?("back", 0); return }
    // Tucked off an edge, a press only moves it (or brings it back): no resizing.
    let tucked = (superview as? MiniPlayerView)?.stashed != nil
    resizing = tucked ? nil : corner(at: convert(e.locationInWindow, from: nil))
    if let c = resizing { onResize?(c, e) } else { onMove?(e) }
  }
  public override func mouseDragged(with e: NSEvent) {
    if let c = resizing { onResize?(c, e) } else { onMove?(e) }
  }
  public override func mouseUp(with e: NSEvent) {
    if let c = resizing { onResize?(c, e) } else { onMove?(e) }
    resizing = nil
  }
}

/// Scrims behind the top and bottom rows, so white controls read over bright video.
@MainActor
final class ScrimView: NSView {
  static let scrim = NSGradient(starting: NSColor(white: 0, alpha: 0.5), ending: NSColor(white: 0, alpha: 0))!
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func draw(_ dirtyRect: NSRect) {
    let h = bounds.height
    Self.scrim.draw(from: NSPoint(x: 0, y: 0), to: NSPoint(x: 0, y: 60), options: [.drawsBeforeStartingLocation])
    Self.scrim.draw(from: NSPoint(x: 0, y: h), to: NSPoint(x: 0, y: h - 84), options: [.drawsBeforeStartingLocation])
  }
}

/// A thin white slider: track, fill, and a knob while hovered or dragged. Reports 0…1.
@MainActor
final class MiniSlider: NSView {
  var value: Double = 0 { didSet { needsDisplay = true } }
  var onChange: ((Double, Bool) -> Void)?
  private(set) var tracking = false
  private var hovering = false { didSet { needsDisplay = true } }
  private var lastSent = 0.0

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }
  override func mouseEntered(with event: NSEvent) { hovering = true }
  override func mouseExited(with event: NSEvent) { hovering = false }

  override func draw(_ dirtyRect: NSRect) {
    let big = hovering || tracking
    let th: CGFloat = big ? 5 : 3, r = th / 2
    let track = NSRect(x: 0, y: (bounds.height - th) / 2, width: bounds.width, height: th)
    NSColor(white: 1, alpha: 0.3).setFill()
    NSBezierPath(roundedRect: track, xRadius: r, yRadius: r).fill()
    var fill = track
    fill.size.width = track.width * CGFloat(min(1, max(0, value)))
    NSColor.white.setFill()
    NSBezierPath(roundedRect: fill, xRadius: r, yRadius: r).fill()
    guard big else { return }
    let k: CGFloat = 11
    let knob = NSRect(x: min(max(0, fill.maxX - k / 2), bounds.width - k), y: (bounds.height - k) / 2, width: k, height: k)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow()
    sh.shadowColor = NSColor(white: 0, alpha: 0.35)
    sh.shadowBlurRadius = 2
    sh.set()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: knob).fill()
    NSGraphicsContext.restoreGraphicsState()
  }

  func set(_ e: NSEvent, done: Bool) {
    let x = convert(e.locationInWindow, from: nil).x
    value = Double(min(1, max(0, x / max(1, bounds.width))))
    // Scrubbing sends at most ~12 updates a second; the release always sends.
    let now = ProcessInfo.processInfo.systemUptime
    if done || now - lastSent > 0.08 {
      lastSent = now
      onChange?(value, done)
    }
  }
  override func mouseDown(with e: NSEvent) { window?.makeKey(); tracking = true; set(e, done: false) }
  override func mouseDragged(with e: NSEvent) { set(e, done: false) }
  override func mouseUp(with e: NSEvent) {
    tracking = false
    set(e, done: true)
    needsDisplay = true
  }
}

/// A small text pill button (the playback speed, subtitles, the host chip).
@MainActor
final class TextButton: NSView {
  let label = NSTextField(labelWithString: "")
  let action: () -> Void
  private var hovering = false { didSet { needsDisplay = true } }
  /// A toggle that's on (subtitles showing): filled white with dark text.
  var selected = false {
    didSet {
      label.textColor = selected ? .black : .white
      needsDisplay = true
    }
  }
  var title: String {
    get { label.stringValue }
    set { label.stringValue = newValue }
  }

  init(title: String, tooltip: String, action: @escaping () -> Void) {
    self.action = action
    super.init(frame: .zero)
    label.stringValue = title
    label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    label.textColor = .white
    label.alignment = .center
    addSubview(label)
    toolTip = tooltip
  }
  required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func layout() {
    super.layout()
    label.frame = NSRect(x: 0, y: (bounds.height - 15) / 2, width: bounds.width, height: 15)
  }
  override func draw(_ dirtyRect: NSRect) {
    NSColor(white: 1, alpha: selected ? (hovering ? 1 : 0.9) : (hovering ? 0.28 : 0.16)).setFill()
    NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }
  override func mouseEntered(with event: NSEvent) { hovering = true }
  override func mouseExited(with event: NSEvent) { hovering = false }
  override func mouseDown(with event: NSEvent) {}
  override func mouseUp(with e: NSEvent) { if bounds.contains(convert(e.locationInWindow, from: nil)) { action() } }
}

/// The strip left on screen while the mini player is tucked off an edge: dark, with a chevron
/// pointing back. A click on the player (its drag handler) brings it back.
@MainActor
final class StashTabView: NSView {
  var side: MiniPlayerPanel.Side? { didSet { chevron.spec = side == .left ? "sf:chevron.right" : "sf:chevron.left" } }
  let chevron = IconView()
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = NSColor(white: 0, alpha: 0.55).cgColor
    chevron.tint = .white
    addSubview(chevron)
  }
  required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func layout() {
    super.layout()
    chevron.frame = NSRect(x: (bounds.width - 14) / 2, y: (bounds.height - 14) / 2, width: 14, height: 14)
  }
}
