import AppKit
import CordisValue

/// Arc's space theme picker (spec §4), shown in the `popover` slot.
///
/// {type:"themePicker", id, anchor?, colors: [hex] (≤3), positions?: [[x,y]] (0–1 pad coords),
///  intensity 0–1, grain 0–1, appearance: auto|light|dark, page? (preset page)}
/// actions (id = picker id):
///   change {colors, positions, intensity, grain, appearance}   live, while dragging or on every click
///   commit {same}                                              when a drag ends / after a click
///   page {page}                                                preset page changed
///   dismiss                                                    Esc or a click outside the popover
final class ThemePickerNode: NodeView {
  // State (kept locally while the user interacts, so re-sent trees don't fight the drag).
  var colors: [RGB] = []
  var positions: [CGPoint] = []
  var intensity: CGFloat = Tokens.defaultIntensity
  var grain: CGFloat = Tokens.defaultGrain
  var mode = "auto"
  var page = 0
  private var interacting = false
  private var lastEmitted: Value = .null

  private enum Drag { case handle(Int), slider, dial(start: CGFloat, value: CGFloat) }
  private var drag: Drag?
  private var lastCell = -1
  private var lastDetent = -1
  private var lastHaptic: CFTimeInterval = 0

  private var modeButtons: [IconButton] = []
  private lazy var removeButton = IconButton(symbol: "minus", size: 32) { [weak self] in self?.removeColor() }
  private lazy var addButton = IconButton(symbol: "plus", size: 32) { [weak self] in self?.addColor() }
  private lazy var prevButton = IconButton(symbol: "chevron.left", size: 32) { [weak self] in self?.turnPage(-1) }
  private lazy var nextButton = IconButton(symbol: "chevron.right", size: 32) { [weak self] in self?.turnPage(1) }
  private let emptyLabel = makeLabel("Tap to pick a color for this space", size: 13, weight: .semibold)  // PX: 204 pt wide = SF 13 semibold
  private var padImage: CGImage?
  private var padImageKey = ""

  static let modes: [(String, String, String)] = [
    ("auto", "sparkles", "Automatic Appearance"), ("light", "sun.max", "Light Appearance"), ("dark", "moon.stars.fill", "Dark Appearance"),
  ]

  required init(renderer: Renderer) {
    super.init(renderer: renderer)
    for (mode, sym, tip) in Self.modes {
      let b = IconButton(symbol: sym, size: Tokens.themePickerModeSize) { [weak self] in self?.setMode(mode) }
      b.toolTip = tip
      modeButtons.append(b)
      addSubview(b)
    }
    removeButton.toolTip = "Remove color"
    addButton.toolTip = "Add color"
    prevButton.toolTip = "Move to previous preset page."
    nextButton.toolTip = "Move to next preset page."
    emptyLabel.alignment = .center
    [removeButton, addButton, prevButton, nextButton, emptyLabel].forEach { addSubview($0) }
  }
  required init?(coder: NSCoder) { fatalError() }

  override var acceptsFirstResponder: Bool { true }
  override func height(for w: CGFloat) -> CGFloat { Tokens.themePickerSize.height }
  override var preferredWidth: CGFloat? { Tokens.themePickerSize.width }

  // MARK: Model

  override func update(_ v: Value) {
    super.update(v)
    guard !interacting else { return }
    let cs = v.list("colors").compactMap { $0.string.flatMap(RGB.init(hex:)) }.prefix(3)
    colors = Array(cs)
    let ps = v.list("positions").compactMap { p -> CGPoint? in
      let a = p.array ?? []
      guard a.count == 2, let x = a[0].double, let y = a[1].double else { return nil }
      return CGPoint(x: x, y: y)
    }
    positions = ps.count == colors.count ? ps : colors.map(ThemePickerMath.position(for:))
    intensity = CGFloat(min(max(v.num("intensity", Double(Tokens.defaultIntensity)), 0), 1))
    grain = CGFloat(min(max(v.num("grain", Double(Tokens.defaultGrain)), 0), 1))
    mode = v.str("appearance", "auto")
    page = min(max(Int(v.num("page", Double(page))), 0), ThemePickerMath.presetPages.count - 1)
    refreshControls()
    needsDisplay = true
  }

  var state: Value {
    [
      "colors": .array(colors.map { .string($0.hex) }),
      "positions": .array(positions.map { [.double(Double($0.x)), .double(Double($0.y))] }),
      "intensity": .double(Double(intensity)), "grain": .double(Double(grain)), "appearance": .string(mode),
    ]
  }

  func emitChange() {
    let s = state
    guard s != lastEmitted else { return }
    lastEmitted = s
    emit("change", s)
  }
  func emitCommit() { emit("commit", state) }

  func setMode(_ m: String) {
    mode = m
    refreshControls()
    emitChange()
    emitCommit()
  }

  func addColor() {
    guard colors.count < 3 else { return }
    let p = ThemePickerMath.added(to: positions)
    positions.append(p)
    colors.append(ThemePickerMath.color(at: p))
    tick(.generic)
    changed(commit: true)
  }

  func removeColor() {
    guard !colors.isEmpty else { return }
    colors.removeLast()
    positions.removeLast()
    tick(.generic)
    changed(commit: true)
  }

  func turnPage(_ d: Int) {
    let n = ThemePickerMath.presetPages.count
    page = ((page + d) % n + n) % n
    emit("page", ["page": .int(Int64(page))])
    needsDisplay = true
  }

  func pickSwatch(_ hex: String) {
    guard let c = RGB(hex: hex) else { return }
    let p = ThemePickerMath.position(for: c)
    if colors.isEmpty { colors = [c]; positions = [p] } else { colors[0] = c; positions[0] = p }
    tick(.generic)
    changed(commit: true)
  }

  private func changed(commit: Bool) {
    refreshControls()
    needsDisplay = true
    emitChange()
    if commit { emitCommit() }
  }

  /// Haptic feedback, throttled so fast drags don't buzz continuously.
  private func tick(_ p: NSHapticFeedbackManager.FeedbackPattern) {
    let now = CACurrentMediaTime()
    guard now - lastHaptic > 0.035 else { return }  // estimate
    lastHaptic = now
    NSHapticFeedbackManager.defaultPerformer.perform(p, performanceTime: .now)
  }

  // MARK: Geometry

  var padRect: NSRect {
    let i = Tokens.themePickerPadInset, s = Tokens.themePickerPadSize
    return NSRect(x: i, y: i, width: s, height: s)
  }
  func padPoint(_ n: CGPoint) -> NSPoint { NSPoint(x: padRect.minX + n.x * padRect.width, y: padRect.minY + n.y * padRect.height) }
  func handleSize(_ i: Int) -> CGFloat { i == 0 ? Tokens.themePickerHandleSize : Tokens.themePickerSecondaryHandleSize }
  func swatchCenter(_ i: Int) -> NSPoint {
    NSPoint(x: Tokens.themePickerSwatchFirstX + CGFloat(i) * Tokens.themePickerSwatchPitch, y: Tokens.themePickerSwatchCenterY)
  }
  var sliderRect: NSRect { Tokens.themePickerSliderFrame }
  var trackRect: NSRect {
    let h = Tokens.themePickerTrackHeight
    return NSRect(x: sliderRect.minX, y: sliderRect.midY - h / 2, width: sliderRect.width, height: h)
  }

  override func layout() {
    super.layout()
    let s = Tokens.themePickerModeSize, cx = bounds.width / 2
    for (i, b) in modeButtons.enumerated() {
      b.frame = NSRect(x: cx - s / 2 + CGFloat(i - 1) * Tokens.themePickerModePitch, y: Tokens.themePickerModeTop, width: s, height: s)
    }
    let ay = Tokens.themePickerAddRemoveCenterY - 16
    removeButton.frame = NSRect(x: cx - 20 - 16, y: ay, width: 32, height: 32)
    addButton.frame = NSRect(x: cx + 20 - 16, y: ay, width: 32, height: 32)
    let sy = Tokens.themePickerSwatchCenterY - 16, px = Tokens.themePickerPagerCenterX
    prevButton.frame = NSRect(x: px - 16, y: sy, width: 32, height: 32)
    nextButton.frame = NSRect(x: bounds.width - px - 16, y: sy, width: 32, height: 32)
    emptyLabel.frame = NSRect(x: padRect.minX, y: padRect.midY - 9, width: padRect.width, height: 18)
  }

  // MARK: Drawing

  var ink: NSColor { palette.dark ? .white : .black }

  override func apply(_ p: Palette) {
    for (i, b) in modeButtons.enumerated() {
      b.fixedTint = nil
      b.apply(p)
      b.tint = ink.withAlphaComponent(Self.modes[i].0 == mode ? 0.9 : 0.6)
      b.hoverFill = ink.withAlphaComponent(0.06)
    }
    for b in [removeButton, addButton, prevButton, nextButton] { b.apply(p); b.hoverFill = ink.withAlphaComponent(0.06) }
    refreshControls()
    emptyLabel.textColor = ink.withAlphaComponent(0.9)
    padImage = nil
    needsDisplay = true
  }

  func refreshControls() {
    guard r != nil else { return }
    for (i, b) in modeButtons.enumerated() { b.tint = ink.withAlphaComponent(Self.modes[i].0 == mode ? 0.9 : 0.6) }
    // PX: disabled +/- draw at white α≈0.21 (122 over 86); enabled buttons use the regular tint.
    removeButton.enabled = !colors.isEmpty
    addButton.enabled = colors.count < 3 && !colors.isEmpty
    for b in [removeButton, addButton] { b.alphaValue = 1; b.tint = ink.withAlphaComponent(b.enabled ? 0.7 : 0.21) }
    prevButton.tint = ink.withAlphaComponent(0.45)
    nextButton.tint = ink.withAlphaComponent(0.7)
    emptyLabel.isHidden = !colors.isEmpty
  }

  /// Body color: measured neutral grey (dark), blended toward the first color once picked.
  var bodyColor: NSColor {
    let b = palette.dark ? Tokens.themePickerBodyDark : Tokens.themePickerBodyLight
    var c = RGB(b.r, b.g, b.b)
    if let f = colors.first { c = c.mix(f, Tokens.themePickerBodyTint) }
    return c.ns
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    bodyColor.setFill()
    bounds.fill()
    let pad = padRect
    let padPath = NSBezierPath(roundedRect: pad, xRadius: Tokens.themePickerPadRadius, yRadius: Tokens.themePickerPadRadius)
    ink.withAlphaComponent(palette.dark ? 0.035 : 0.03).setFill()  // PX: pad ≈ 6 levels above the body
    padPath.fill()
    // Dot grid (cached). With colors picked, each dot shows the pad color under it.
    let key = "\(palette.dark)-\(colors.isEmpty)"
    if padImage == nil || padImageKey != key { padImage = makeDotGrid(size: pad.size, colored: !colors.isEmpty); padImageKey = key }
    if let img = padImage {
      ctx.saveGState()
      padPath.addClip()
      ctx.translateBy(x: pad.minX, y: pad.maxY)
      ctx.scaleBy(x: 1, y: -1)
      ctx.draw(img, in: CGRect(origin: .zero, size: pad.size))
      ctx.restoreGState()
    }
    // Selected mode button background.
    if let i = Self.modes.firstIndex(where: { $0.0 == mode }), i < modeButtons.count {
      ink.withAlphaComponent(Tokens.themePickerSelectedModeAlpha).setFill()
      NSBezierPath(roundedRect: modeButtons[i].frame, xRadius: Tokens.themePickerModeRadius, yRadius: Tokens.themePickerModeRadius).fill()
    }
    // Links between handles, then the handles (primary last so it sits on top).
    if positions.count > 1 {
      let path = NSBezierPath()
      path.move(to: padPoint(positions[0]))
      for p in positions.dropFirst() { path.line(to: padPoint(p)) }
      path.lineWidth = 2
      NSColor(white: 1, alpha: 0.55).setStroke()  // estimate
      path.stroke()
    }
    for i in positions.indices.reversed() { drawHandle(i) }
    drawSwatches()
    drawSlider(ctx)
    drawDial()
  }

  private func makeDotGrid(size: CGSize, colored: Bool) -> CGImage? {
    let scale: CGFloat = 2
    let w = Int(size.width * scale), h = Int(size.height * scale)
    guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    c.scaleBy(x: scale, y: scale)
    let pitch = Tokens.themePickerDotPitch, d = Tokens.themePickerDotSize
    let base = palette.dark ? NSColor.white : NSColor.black
    var y = pitch / 2
    while y < size.height {
      var x = pitch / 2
      while x < size.width {
        let col: NSColor
        if colored {
          col = ThemePickerMath.color(at: CGPoint(x: x / size.width, y: y / size.height)).ns.withAlphaComponent(palette.dark ? 0.7 : 0.9)  // estimate
        } else {
          col = base.withAlphaComponent(palette.dark ? Tokens.themePickerDotAlpha : 0.2)
        }
        c.setFillColor(col.cgColor)
        c.fillEllipse(in: CGRect(x: x - d / 2, y: size.height - y - d / 2, width: d, height: d))
        x += pitch
      }
      y += pitch
    }
    return c.makeImage()
  }

  private func drawHandle(_ i: Int) {
    let s = handleSize(i), p = padPoint(positions[i])
    let r = NSRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow()
    sh.shadowColor = NSColor(white: 0, alpha: 0.3)  // estimate
    sh.shadowBlurRadius = 6
    sh.shadowOffset = NSSize(width: 0, height: -2)
    sh.set()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: r).fill()
    NSGraphicsContext.restoreGraphicsState()
    colors[i].ns.setFill()
    NSBezierPath(ovalIn: r.insetBy(dx: 3, dy: 3)).fill()  // estimate: 3 pt white rim
  }

  private func drawSwatches() {
    let page = ThemePickerMath.presetPages[self.page]
    let s = Tokens.themePickerSwatchSize
    for (i, hex) in page.enumerated() {
      guard let c = RGB(hex: hex) else { continue }
      let ctr = swatchCenter(i)
      let rect = NSRect(x: ctr.x - s / 2, y: ctr.y - s / 2, width: s, height: s)
      c.mix(RGB(0, 0, 0), 0.12).ns.setFill()  // PX: a 1.5 pt rim ~12% darker than the swatch
      NSBezierPath(ovalIn: rect).fill()
      c.ns.setFill()
      NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
      if let f = colors.first, f.hex == c.hex {
        ink.withAlphaComponent(0.8).setStroke()
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: -3, dy: -3))
        ring.lineWidth = 1.5
        ring.stroke()
      }
    }
  }

  /// Arc's wavy intensity slider: a pill track with a sine stroke up to the value.
  private func drawSlider(_ ctx: CGContext) {
    let t = trackRect
    ink.withAlphaComponent(palette.dark ? 0.08 : 0.06).setFill()  // PX: 100 over 86
    NSBezierPath(roundedRect: t, xRadius: t.height / 2, yRadius: t.height / 2).fill()
    let x0 = t.minX + 10, x1 = t.maxX - 10
    let end = x0 + (x1 - x0) * intensity
    let amp = Tokens.themePickerWaveAmplitude * (0.35 + 0.65 * intensity)  // estimate: calmer wave at low intensity
    let path = NSBezierPath()
    var x = x0
    path.move(to: NSPoint(x: x, y: t.midY))
    while x < end {
      x = min(end, x + 1)
      path.line(to: NSPoint(x: x, y: t.midY - amp * sin((x - x0) / Tokens.themePickerWavePeriod * 2 * .pi)))
    }
    path.lineWidth = Tokens.themePickerWaveWidth
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    let waveColor = colors.first.map { $0.ns.withAlphaComponent(0.9) } ?? ink.withAlphaComponent(0.21)  // PX: 122 over 86 when empty
    waveColor.setStroke()
    path.stroke()
    // Flat remainder of the track after the value.
    if end < x1 {
      let rest = NSBezierPath()
      rest.move(to: NSPoint(x: end, y: t.midY))
      rest.line(to: NSPoint(x: x1, y: t.midY))
      rest.lineWidth = 2
      rest.lineCapStyle = .round
      ink.withAlphaComponent(0.15).setStroke()
      rest.stroke()
    }
    // Thumb.
    let yEnd = t.midY - amp * sin((end - x0) / Tokens.themePickerWavePeriod * 2 * .pi)
    let k: CGFloat = 14  // estimate
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: end - k / 2, y: yEnd - k / 2, width: k, height: k)).fill()
  }

  /// Grain dial (SpaceStyleDialView): inner circle, ring of dots lit up to the grain value.
  private func drawDial() {
    let c = Tokens.themePickerDialCenter, ri = Tokens.themePickerDialInnerRadius, rd = Tokens.themePickerDialDotRadius
    let n = Tokens.themePickerDialDots
    let lit = Int((grain * CGFloat(n)).rounded())
    for i in 0..<n {
      let a = -CGFloat.pi / 2 + CGFloat(i) / CGFloat(n) * 2 * .pi
      let p = NSPoint(x: c.x + cos(a) * rd, y: c.y + sin(a) * rd)
      let d: CGFloat = i < lit ? 4.5 : 3.5  // estimate
      ink.withAlphaComponent(i < lit ? 0.85 : 0.2).setFill()
      NSBezierPath(ovalIn: NSRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)).fill()
    }
    let circle = NSBezierPath(ovalIn: NSRect(x: c.x - ri, y: c.y - ri, width: ri * 2, height: ri * 2))
    ink.withAlphaComponent(0.04 + 0.12 * grain).setFill()
    circle.fill()
    circle.lineWidth = 1
    ink.withAlphaComponent(0.15).setStroke()  // PX: 114 over 89
    circle.stroke()
    // Pointer at the current value.
    let a = -CGFloat.pi / 2 + grain * 2 * .pi
    let tip = NSPoint(x: c.x + cos(a) * (ri - 6), y: c.y + sin(a) * (ri - 6))
    ink.withAlphaComponent(0.8).setFill()
    NSBezierPath(ovalIn: NSRect(x: tip.x - 3, y: tip.y - 3, width: 6, height: 6)).fill()
  }

  // MARK: Input

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    let p = convert(event.locationInWindow, from: nil)
    interacting = true
    lastCell = -1
    lastDetent = -1
    if padRect.insetBy(dx: -Tokens.themePickerHandleSize / 2, dy: -Tokens.themePickerHandleSize / 2).contains(p), p.y < Tokens.themePickerSwatchCenterY - 16 {
      if let i = positions.indices.reversed().first(where: { hypot(padPoint(positions[$0]).x - p.x, padPoint(positions[$0]).y - p.y) <= handleSize($0) / 2 + 2 }) {
        drag = .handle(i)
      } else {
        if colors.isEmpty { colors = [.init(1, 1, 1)]; positions = [.zero] }
        drag = .handle(0)
      }
      tick(.generic)
      moveHandle(to: p)
    } else if sliderRect.insetBy(dx: -4, dy: 0).contains(p) {
      drag = .slider
      moveSlider(to: p)
    } else if hypot(p.x - Tokens.themePickerDialCenter.x, p.y - Tokens.themePickerDialCenter.y) <= Tokens.themePickerDialDotRadius + 6 {
      drag = .dial(start: p.y, value: grain)
      setGrain(angleValue(p))
    } else if let i = (0..<9).first(where: { hypot(swatchCenter($0).x - p.x, swatchCenter($0).y - p.y) <= Tokens.themePickerSwatchSize / 2 + 2 }) {
      interacting = false
      pickSwatch(ThemePickerMath.presetPages[page][i])
    } else {
      interacting = false
    }
  }

  override func mouseDragged(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    switch drag {
    case .handle: moveHandle(to: p)
    case .slider: moveSlider(to: p)
    case .dial: setGrain(angleValue(p))
    case nil: break
    }
  }

  override func mouseUp(with event: NSEvent) {
    guard drag != nil else { return }
    drag = nil
    interacting = false
    emitCommit()
  }

  func moveHandle(to p: NSPoint) {
    guard case .handle(let i) = drag, i < positions.count else { return }
    let pad = padRect
    let local = CGPoint(x: min(max(p.x - pad.minX, 0), pad.width), y: min(max(p.y - pad.minY, 0), pad.height))
    // Handles snap to the dot grid; one haptic tick per 4 dots crossed.
    let s = ThemePickerMath.snap(local, pitch: Tokens.themePickerDotPitch, size: pad.width)
    let n = CGPoint(x: s.point.x / pad.width, y: s.point.y / pad.height)
    let coarse = ThemePickerMath.snap(local, pitch: Tokens.themePickerDotPitch * 4, size: pad.width).cell  // estimate: tick spacing
    if coarse != lastCell { if lastCell >= 0 { tick(.alignment) }; lastCell = coarse }
    positions[i] = n
    colors[i] = ThemePickerMath.color(at: n)
    changed(commit: false)
  }

  func moveSlider(to p: NSPoint) {
    let t = trackRect
    intensity = min(max((p.x - t.minX - 10) / (t.width - 20), 0), 1)
    let detent = Int((intensity * 10).rounded(.down))  // estimate: tick every 10%
    if detent != lastDetent { if lastDetent >= 0 { tick(.alignment) }; lastDetent = detent }
    changed(commit: false)
  }

  func angleValue(_ p: NSPoint) -> CGFloat {
    let c = Tokens.themePickerDialCenter
    var a = atan2(p.y - c.y, p.x - c.x) + .pi / 2
    if a < 0 { a += 2 * .pi }
    return min(max(a / (2 * .pi), 0), 1)
  }

  func setGrain(_ v: CGFloat) {
    let step = Int((v * CGFloat(Tokens.themePickerDialDots)).rounded())
    if step != lastDetent { if lastDetent >= 0 { tick(.alignment) }; lastDetent = step }
    grain = v
    changed(commit: false)
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 { emit("dismiss") } else { super.keyDown(with: event) }
  }
  override func cancelOperation(_ sender: Any?) { emit("dismiss") }
}

/// Floating popover surface for the `popover` slot: rounded, shadowed, anchored to a node.
@MainActor
final class PopoverPanel: PanelView {
  var content: NodeView?
  var anchor = ""
  init() { super.init(radius: Tokens.themePickerCornerRadius) }
  required init?(coder: NSCoder) { fatalError() }
  override func apply(_ p: Palette) {
    super.apply(p)
    surface.layer?.borderColor = NSColor(white: 1, alpha: p.dark ? 0.08 : 0.5).cgColor  // estimate
  }
  var contentSize: CGSize {
    guard let c = content else { return .zero }
    return CGSize(width: c.preferredWidth ?? 320, height: c.height(for: c.preferredWidth ?? 320))
  }
  override func layout() {
    super.layout()
    content?.frame = surface.bounds
  }
}
