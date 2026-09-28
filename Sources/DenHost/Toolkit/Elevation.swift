import AppKit
import CoreImage
import QuartzCore
import WebKit
import os

/// Generic elevated-surface style: how high a panel floats above what's behind it.
///
/// - **Layered shadow.** A wide, soft ambient shadow plus a tight key shadow near the edge (one
///   flat shadow reads as a sticker; two read as depth). Both use the spec's PopoverShadow
///   (#151C32 α0.30 light / α0.80 dark, spec §3) scaled per level.
/// - **Rim.** A 1 pt highlight along the top edge that fades out a third of the way down, and a
///   hairline edge all around (theme tokens `rim`, `edge`).
/// - **Motion.** In: scale 0.96 → 1 on a spring (~0.18 s perceived) with a 0.15 s fade. Out: 0.12 s
///   fade to 0.98. Reduce Motion: no animation.
///
/// Levels: `modal` (dialogs, sheets, the Library), `bar` (the command bar), `popover` (theme and
/// icon pickers, the extensions menu, login suggestions), `card` (hover cards). Arc's own shadow
/// values aren't readable (spec §12), so the radii and offsets are estimates tuned on snapshots.
public enum Elevation: Sendable {
  case modal, bar, popover, card

  public struct Spec: Sendable {
    public var ambientRadius: CGFloat, ambientY: CGFloat, ambientAlpha: CGFloat
    public var keyRadius: CGFloat, keyY: CGFloat, keyAlpha: CGFloat
  }

  /// Alphas are multiples of the PopoverShadow alpha (capped at 1), tuned on --snapshot PNGs.
  public var spec: Spec {
    switch self {
    case .modal: Spec(ambientRadius: 30, ambientY: 18, ambientAlpha: 1.6, keyRadius: 3, keyY: 1.5, keyAlpha: 0.8)
    case .bar: Spec(ambientRadius: 30, ambientY: 16, ambientAlpha: 0.85, keyRadius: 2.5, keyY: 1, keyAlpha: 0.5)
    case .popover: Spec(ambientRadius: 22, ambientY: 10, ambientAlpha: 0.7, keyRadius: 2, keyY: 1, keyAlpha: 0.45)
    case .card: Spec(ambientRadius: 14, ambientY: 5, ambientAlpha: 0.5, keyRadius: 1.5, keyY: 0.5, keyAlpha: 0.4)
    }
  }

  static let ambientName = "den.elevation.ambient"
  static let rimName = "den.elevation.rim"

  /// Styles `host` (a layer-backed view whose own layer carries the key shadow) with `surface` (the
  /// rounded, clipped body inside it; often the same view's child). Call again on every layout and
  /// palette change: it only updates layers.
  @MainActor
  public static func apply(_ level: Elevation, host: NSView, surface: NSView, radius: CGFloat, palette p: Palette, rim showsRim: Bool = true, edge showsEdge: Bool = true) {
    host.wantsLayer = true
    surface.wantsLayer = true
    guard let hl = host.layer, let sl = surface.layer else { return }
    let s = level.spec, t = p.tokens
    let color = t.elevationShadow.rgb.ns.cgColor, a = Float(t.elevationShadow.a)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    hl.masksToBounds = false
    let rect = surface === host ? host.bounds : surface.frame
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    // Key shadow: the host layer's own.
    hl.shadowColor = color
    hl.shadowOpacity = min(1, a * Float(s.keyAlpha))
    hl.shadowRadius = s.keyRadius
    hl.shadowOffset = CGSize(width: 0, height: s.keyY)  // down: these layers are geometry-flipped (checked on snapshots)
    hl.shadowPath = path
    // Ambient shadow: a view behind the surface, the surface's shape and color (hidden under it),
    // whose layer casts the wide shadow. A filled view, not a bare sublayer with only a
    // shadowPath: `cacheDisplay` snapshots skipped that one.
    let ambView = host.subviews.first { $0.identifier?.rawValue == ambientName } ?? {
      let v = ShadowOnlyView()
      v.identifier = NSUserInterfaceItemIdentifier(ambientName)
      v.wantsLayer = true
      host.addSubview(v, positioned: .below, relativeTo: nil)
      return v
    }()
    ambView.frame = rect
    guard let amb = ambView.layer else { CATransaction.commit(); return }
    amb.masksToBounds = false
    amb.backgroundColor = t.surface.ns.cgColor
    amb.cornerRadius = radius
    amb.cornerCurve = .continuous
    amb.shadowColor = color
    amb.shadowOpacity = min(1, a * Float(s.ambientAlpha))
    amb.shadowRadius = s.ambientRadius
    amb.shadowOffset = CGSize(width: 0, height: s.ambientY)
    amb.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: rect.size), cornerWidth: radius, cornerHeight: radius, transform: nil)
    // Edge and rim.
    sl.cornerRadius = radius
    sl.cornerCurve = .continuous
    sl.borderWidth = showsEdge ? 0.5 : 0
    sl.borderColor = t.edge.ns.cgColor
    let rim = (sl.sublayers?.first { $0.name == rimName } as? CAShapeLayer) ?? {
      let l = CAShapeLayer()
      l.name = rimName
      l.fillColor = nil
      l.lineWidth = 1
      let m = CAGradientLayer()
      l.mask = m
      sl.addSublayer(l)
      return l
    }()
    rim.zPosition = 10  // over the surface's content, like the border
    rim.isHidden = !showsRim
    rim.frame = sl.bounds
    rim.path = CGPath(roundedRect: sl.bounds.insetBy(dx: 1, dy: 1), cornerWidth: max(0, radius - 1), cornerHeight: max(0, radius - 1), transform: nil)
    rim.strokeColor = t.rim.ns.cgColor
    if let m = rim.mask as? CAGradientLayer {
      m.frame = rim.bounds
      m.colors = [NSColor.black.cgColor, NSColor.black.withAlphaComponent(0).cgColor]
      // The top edge in the layer's own coordinates (flipped views have y = 0 at the top).
      let top: CGFloat = surface.isFlipped ? 0 : 1
      m.startPoint = CGPoint(x: 0.5, y: top)
      m.endPoint = CGPoint(x: 0.5, y: surface.isFlipped ? 0.35 : 0.65)
    }
    CATransaction.commit()
  }

  // MARK: Motion

  static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

  /// Scale 0.96 → 1 on a spring and fade in; `backdrop` fades in alongside.
  @MainActor
  public static func animateIn(_ view: NSView, backdrop: NSView? = nil) {
    guard !reduceMotion, let l = view.layer, view.window?.isVisible == true else { return }
    view.layoutSubtreeIfNeeded()
    l.removeAnimation(forKey: "den.out.scale")
    l.removeAnimation(forKey: "den.out.fade")
    l.opacity = 1
    let spring = CASpringAnimation(perceptualDuration: 0.18, bounce: 0.12)
    spring.keyPath = "transform"
    spring.fromValue = NSValue(caTransform3D: scaled(0.96, l.bounds))
    spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
    spring.duration = spring.settlingDuration
    l.add(spring, forKey: "den.in.scale")
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0
    fade.toValue = 1
    fade.duration = 0.15
    fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
    l.add(fade, forKey: "den.in.fade")
    if let b = backdrop?.layer {
      b.removeAnimation(forKey: "den.out.fade")
      b.opacity = 1
      b.add(fade, forKey: "den.in.fade")
    }
  }

  /// Fades out to 0.98 in 0.12 s, then `done` (remove the views there). Without motion: at once.
  @MainActor
  public static func animateOut(_ view: NSView, backdrop: NSView? = nil, done: @escaping @MainActor () -> Void) {
    // A window that isn't on screen (tests) renders no frames: finish at once.
    guard !reduceMotion, let l = view.layer, view.window?.isVisible == true else { return done() }
    CATransaction.begin()
    CATransaction.setCompletionBlock { MainActor.assumeIsolated { done() } }
    let scale = CABasicAnimation(keyPath: "transform")
    scale.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
    scale.toValue = NSValue(caTransform3D: scaled(0.98, l.bounds))
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 1
    fade.toValue = 0
    for a in [scale, fade] as [CABasicAnimation] {
      a.duration = 0.12
      a.timingFunction = CAMediaTimingFunction(name: .easeIn)
      a.fillMode = .forwards
      a.isRemovedOnCompletion = false
    }
    l.add(scale, forKey: "den.out.scale")
    l.add(fade, forKey: "den.out.fade")
    if let b = backdrop?.layer { b.add(fade.copy() as! CABasicAnimation, forKey: "den.out.fade") }
    CATransaction.commit()
  }

  /// Clears a finished exit so the view can be shown again.
  @MainActor
  public static func reset(_ views: NSView?...) {
    for v in views {
      v?.layer?.removeAnimation(forKey: "den.out.scale")
      v?.layer?.removeAnimation(forKey: "den.out.fade")
    }
  }

  /// A scale about the center (AppKit layers anchor at their origin).
  static func scaled(_ s: CGFloat, _ b: CGRect) -> CATransform3D {
    var t = CATransform3DMakeTranslation(b.midX, b.midY, 0)
    t = CATransform3DScale(t, s, s, 1)
    return CATransform3DTranslate(t, -b.midX, -b.midY, 0)
  }
}

/// Draws nothing but its layer's shadow; never takes clicks.
final class ShadowOnlyView: NSView {
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Modal backdrop

/// The dim behind a modal dialog (spec §3/§5: black α0.55) over a blurred picture of what's behind
/// it. The blur is one snapshot, taken right after the dialog opens: the visible web views
/// (`takeSnapshot` at a quarter of their size) and den's chrome (`cacheDisplay` with the overlay
/// layer hidden), rendered at 1/4 scale and blurred with Core Image. It costs a few milliseconds
/// once and nothing while the dialog is up (a live vibrancy view would re-blur on every frame of a
/// playing video behind it, and doesn't show in `--snapshot` PNGs). The dim shows at once; the
/// blur fades in when ready. Timings: `os_log` category `elevation`, `lastBlurMs`.
@MainActor
public final class ModalBackdrop: NSView {
  public var onClick: (() -> Void)?
  let blur = CALayer()
  let dim = CALayer()
  var generation = 0
  /// Main-thread cost and total latency of the last blur (ms), for measurements.
  public private(set) static var lastBlurMs: (main: Double, total: Double) = (0, 0)
  static let log = Logger(subsystem: "io.github.abhishakenp.den", category: "elevation")
  nonisolated(unsafe) static let ci = CIContext(options: [.cacheIntermediates: false])
  public static var blurEnabled = true

  public init(dim alpha: CGFloat) {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.addSublayer(blur)
    layer?.addSublayer(dim)
    blur.contentsGravity = .resize
    blur.opacity = 0
    dim.backgroundColor = NSColor(white: 0, alpha: alpha).cgColor
  }
  required init?(coder: NSCoder) { fatalError() }
  public override var isFlipped: Bool { true }
  public override func mouseDown(with event: NSEvent) { onClick?() }
  public override var mouseDownCanMoveWindow: Bool { false }
  public override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    needsLayout = true
  }
  public override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    blur.frame = bounds
    dim.frame = bounds
    CATransaction.commit()
  }

  public var dimAlpha: CGFloat {
    get { NSColor(cgColor: dim.backgroundColor!)?.alphaComponent ?? 0 }
    set { dim.backgroundColor = NSColor(white: 0, alpha: newValue).cgColor }
  }

  /// Snapshots and blurs `root` (the window's content) with `overlays` hidden.
  public func captureBlur(root: NSView, hiding overlays: [NSView]) {
    generation += 1
    let gen = generation
    blur.contents = nil
    blur.opacity = 0
    guard Self.blurEnabled, root.bounds.width > 1 else { return }
    let start = CACurrentMediaTime()
    Task { @MainActor [weak self] in
      let webs = Snapshotter.allWebViews(in: root).filter { w in
        !w.isHiddenOrHasHiddenAncestor && w.bounds.width > 1 && !overlays.contains { w.isDescendant(of: $0) }
      }
      var shots: [(WKWebView, NSImage)] = []
      for w in webs {
        let c = WKSnapshotConfiguration()
        c.snapshotWidth = NSNumber(value: Double(max(64, w.bounds.width / 4)))
        c.afterScreenUpdates = true
        if let img = try? await w.takeSnapshot(configuration: c) { shots.append((w, img)) }
      }
      guard let self, self.generation == gen, self.window != nil else { return }
      let mainStart = CACurrentMediaTime()
      guard let small = Self.capture(root: root, hiding: overlays, shots: shots) else { return }
      let mainMs = (CACurrentMediaTime() - mainStart) * 1000
      // The blur itself runs off the main thread.
      let image = await Task.detached(priority: .userInitiated) { Self.blurred(small) }.value
      guard self.generation == gen, let image else { return }
      let total = (CACurrentMediaTime() - start) * 1000
      Self.lastBlurMs = (mainMs, total)
      Self.log.info("blur: \(String(format: "%.1f", mainMs), privacy: .public) ms on main, \(String(format: "%.1f", total), privacy: .public) ms total, \(shots.count, privacy: .public) web views")
      if ProcessInfo.processInfo.environment["DEN_TRACE"] != nil {
        print(String(format: "elevation.blur main=%.1fms total=%.1fms webviews=%d", mainMs, total, shots.count))
      }
      self.blur.contents = image
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = 0
      fade.toValue = 1
      fade.duration = Elevation.reduceMotion ? 0 : 0.12
      self.blur.opacity = 1
      self.blur.add(fade, forKey: "fade")
    }
  }

  /// Quarter-scale picture of `root` (web views as their snapshots, overlays hidden). Main thread.
  static func capture(root: NSView, hiding overlays: [NSView], shots: [(WKWebView, NSImage)]) -> CGImage? {
    let scale: CGFloat = 0.25
    let size = root.bounds.size
    let pw = max(1, Int(size.width * scale)), ph = max(1, Int(size.height * scale))
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = size
    var temps: [NSView] = []
    for (w, img) in shots {
      guard let parent = w.superview else { continue }
      let iv = NSImageView(frame: w.frame)
      iv.image = img
      iv.imageScaling = .scaleAxesIndependently
      parent.addSubview(iv, positioned: .above, relativeTo: w)
      temps.append(iv)
    }
    let wasHidden = overlays.map(\.isHidden)
    overlays.forEach { $0.isHidden = true }
    root.cacheDisplay(in: root.bounds, to: rep)
    for (o, h) in zip(overlays, wasHidden) { o.isHidden = h }
    temps.forEach { $0.removeFromSuperview() }
    return rep.cgImage
  }

  /// Gaussian blur, 2 px at 1/4 scale (about 8 pt): shapes and colors stay, text does not.
  nonisolated static func blurred(_ cg: CGImage) -> CGImage? {
    let input = CIImage(cgImage: cg)
    guard let f = CIFilter(name: "CIGaussianBlur") else { return nil }
    f.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
    f.setValue(2.0, forKey: kCIInputRadiusKey)
    guard let out = f.outputImage?.cropped(to: input.extent) else { return nil }
    return ci.createCGImage(out, from: input.extent)
  }
}
