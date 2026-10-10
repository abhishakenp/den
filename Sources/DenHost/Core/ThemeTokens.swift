import CoreGraphics
import Foundation
import PluginCores

// den's theme-token layer: every chrome surface (dialogs, command bar, popovers, toasts, hover
// cards, sheets, Settings, Little Arc) takes its colors from these, derived from the current space
// theme and the effective appearance, so nothing is a fixed white card or a fixed brand blue.
// Pure and AppKit-free (unit-tested in DenHostTests/ThemeTokenTests); `Palette` wraps it for AppKit.

public enum AccentSource: String, Sendable { case theme, system }

/// The tokens. Text colors are opaque and already contrast-checked against the surface they sit on.
public struct ThemeTokens: Equatable, Sendable {
  public var dark: Bool
  /// The window background as drawn (the average of the gradient stops); sidebar text sits on it.
  public var background: RGB
  /// Dialogs, the command bar, popovers, sheets, Settings.
  public var surface: RGB
  /// A layer above the surface: cards in sheets, the command bar banner, secondary buttons.
  public var elevated: RGB
  public var textPrimary: RGB, textSecondary: RGB, textTertiary: RGB
  /// Text on the window background (the sidebar).
  public var sidebarText: RGB, sidebarSecondary: RGB
  /// Primary buttons, selection, focus ring, caret, toggles; `onAccent` is the label on it.
  public var accent: RGB, onAccent: RGB
  public var destructive: RGB, onDestructive: RGB
  /// Toasts: a deep, theme-blended chip with light text (spec §6: theme-tinted toasts).
  public var toast: RGB, onToast: RGB
  public var hairline: RGBA, hover: RGBA, pressed: RGBA, shadow: RGBA
  /// Elevated surfaces (Elevation.swift): the spec's PopoverShadow (#151C32 α0.30 light / α0.80
  /// dark, spec §3) for the layered shadow, the hairline edge around the surface, and the light
  /// rim along its top edge (brightest at the top, gone by a third of the way down).
  public var elevationShadow: RGBA, edge: RGBA, rim: RGBA
  /// Black dim behind modal dialogs (spec §3: α 0.55) and sheets (0.35).
  public var dialogDim: CGFloat, sheetDim: CGFloat
  /// Grain drawn on surfaces (a fraction of the window's grain, never louder).
  public var grain: CGFloat
  /// Cards and popovers (`ui.card`): Dia's neutral hover-card surface, a step off the sidebar.
  public var card = CardTokens()

  /// Card colors (docs/reference/dia-ui-spec.md §2.3, §2.6, §3.2). With no space colors they are
  /// Dia's measured values; a themed space tints them slightly. Text is contrast-checked like
  /// every other surface, so Dia's light secondary (#7B7B7B, 3.9:1) is darkened to 4.5:1.
  public struct CardTokens: Equatable, Sendable {
    public var fill = RGB(Double(0xF4) / 255, Double(0xF4) / 255, Double(0xF4) / 255)
    public var text = RGB(Double(0x25) / 255, Double(0x25) / 255, Double(0x25) / 255), secondary = RGB(0.45, 0.45, 0.45), glyph = RGB(0.45, 0.45, 0.45)
    /// Hairline (dark: one #3C3C3C stroke; light: #DCDCDC outside a 1 pt white highlight).
    public var border = RGB(Double(0xDC) / 255, Double(0xDC) / 255, Double(0xDC) / 255), highlight: RGB? = RGB(1, 1, 1)
    /// Icon-button hover fill (dark #373737).
    public var hover = RGB(0.9, 0.9, 0.9)
    public var tooltip = RGB(Double(0x47) / 255, Double(0x47) / 255, Double(0x47) / 255), onTooltip = RGB(Double(0xE4) / 255, Double(0xE4) / 255, Double(0xE4) / 255)
    /// Status tones (PR peek, spec §3.2): passed, pending, failed, and the CI bar's empty track.
    public var success = RGB(Double(0x1C) / 255, Double(0x86) / 255, Double(0x37) / 255), warning = RGB(Double(0xCB) / 255, Double(0x9F) / 255, Double(0x16) / 255)
    public var danger = RGB(Double(0xA2) / 255, Double(0x31) / 255, Double(0x27) / 255), track = RGB(Double(0xDA) / 255, Double(0xDD) / 255, Double(0xDF) / 255)
    /// Diff counts (+adds / −dels) as text on the card.
    public var addText = RGB(Double(0x1E) / 255, Double(0x8A) / 255, Double(0x3C) / 255), delText = RGB(Double(0xA2) / 255, Double(0x3A) / 255, Double(0x36) / 255)
    /// A failing-check row: soft fill, accent bar (= danger), text.
    public var dangerSoft = RGB(Double(0xF0) / 255, Double(0xDD) / 255, Double(0xDD) / 255), onDangerSoft = RGB(Double(0x7C) / 255, Double(0x31) / 255, Double(0x37) / 255)
    /// "Show comments": the strong (black in light) button; "Show N failures": destructive.
    public var strong = RGB(0.07, 0.07, 0.07), onStrong = RGB(1.0, 1.0, 1.0)
    public var destructive = RGB(Double(0xA6) / 255, Double(0x30) / 255, Double(0x27) / 255), onDestructive = RGB(1.0, 1.0, 1.0)
    public init() {}
  }

  /// WCAG targets: primary text AAA (7:1), secondary text AA (4.5:1), tertiary (hints, disabled
  /// and large text) 3:1; button labels AA; the accent against the surface 3:1 (a UI component).
  public static let primaryContrast: CGFloat = 7
  public static let bodyContrast: CGFloat = 4.5
  public static let uiContrast: CGFloat = 3

  // MARK: Derivation

  nonisolated(unsafe) private static var cache: [Key: ThemeTokens] = [:]
  private struct Key: Hashable {
    var colors: [UInt32], intensity: Int, grain: Int, dark: Bool, accent: UInt32?
  }

  /// Cached per (theme, appearance, accent): computing is cheap, but palettes are rebuilt on every
  /// theme blend step during a swipe.
  public static func make(theme: Theme, dark: Bool, systemAccent: RGB? = nil) -> ThemeTokens {
    func pack(_ c: RGB) -> UInt32 { UInt32((c.clamped.r * 255).rounded()) << 16 | UInt32((c.clamped.g * 255).rounded()) << 8 | UInt32((c.clamped.b * 255).rounded()) }
    let key = Key(colors: theme.colors.map(pack), intensity: Int(theme.intensity * 1000), grain: Int(theme.grain * 1000), dark: dark, accent: systemAccent.map(pack))
    if let t = cache[key] { return t }
    let t = derive(theme: theme, dark: dark, systemAccent: systemAccent)
    if cache.count > 256 { cache.removeAll() }
    cache[key] = t
    return t
  }

  static func average(_ cs: [RGB]) -> RGB {
    guard !cs.isEmpty else { return RGB(0.5, 0.5, 0.5) }
    let n = CGFloat(cs.count)
    return RGB(cs.map(\.r).reduce(0, +) / n, cs.map(\.g).reduce(0, +) / n, cs.map(\.b).reduce(0, +) / n)
  }

  static let ink = RGB(Double(0x0E) / 255, Double(0x0F) / 255, Double(0x10) / 255)
  static let snow = RGB(Double(0xFA) / 255, Double(0xFB) / 255, 1.0)
  static let white = RGB(1.0, 1.0, 1.0)

  /// Moves `c` toward black or white (whichever is farther from `bg`) until it reaches `target`.
  public static func ensure(_ c: RGB, on bg: RGB, _ target: CGFloat) -> RGB {
    if c.contrast(bg) >= target { return c }
    let toward = bg.relativeLuminance > 0.18 ? RGB(0.0, 0.0, 0.0) : white
    var lo: CGFloat = 0, hi: CGFloat = 1
    guard c.mix(toward, 1).contrast(bg) >= target else { return c.mix(toward, 1) }
    for _ in 0..<18 {
      let m = (lo + hi) / 2
      if c.mix(toward, m).contrast(bg) >= target { hi = m } else { lo = m }
    }
    return c.mix(toward, hi)
  }

  static func derive(theme: Theme, dark: Bool, systemAccent: RGB?) -> ThemeTokens {
    let stops = theme.stops(dark: dark)
    let bg = average(stops)
    let hasTheme = !theme.colors.isEmpty
    let tint = hasTheme ? average(theme.colors) : bg
    // Surfaces: Arc's PopoverBackground (#FAFBFF / #151C30), pulled toward the space's colors so a
    // sandy theme gets a papery dialog and a purple one a violet-black one. Light surfaces stay
    // light (luminance ≥ 0.72) and dark ones dark (≤ 0.035), whatever the theme.
    let popLight = snow, popDark = RGB(0x15 / 255, 0x1C / 255, 0x30 / 255)
    var surface: RGB
    if dark {
      let deep = tint.mix(RGB(0, 0, 0), 0.72)
      surface = hasTheme ? popDark.mix(deep, 0.35 + 0.35 * theme.intensity) : popDark
      while surface.relativeLuminance > 0.035 { surface = surface.mix(RGB(0, 0, 0), 0.15) }
    } else {
      surface = hasTheme ? popLight.mix(tint, 0.10 + 0.22 * theme.intensity) : popLight
      while surface.relativeLuminance < 0.72 { surface = surface.mix(white, 0.2) }
    }
    let elevated = dark ? surface.mix(white, 0.07) : surface.mix(white, 0.55)
    // Text: Arc's ForegroundPrimary/Secondary/Tertiary (ink α.9/.5/.3, white α.8/.5/.3), composited
    // on the surface, then pushed until each meets its contrast target.
    let fg = dark ? white : ink
    let textPrimary = ensure(surface.mix(fg, dark ? 0.9 : 0.92), on: surface, primaryContrast)
    let textSecondary = ensure(surface.mix(fg, 0.6), on: surface, bodyContrast)
    let textTertiary = ensure(surface.mix(fg, 0.38), on: surface, uiContrast)
    // The sidebar: text straight on the gradient (checked against every stop, not just the mean).
    func onStops(_ c: RGB, _ target: CGFloat) -> RGB { stops.reduce(c) { ensure($0, on: $1, target) } }
    let sidebarText = onStops(bg.mix(fg, dark ? 0.85 : 0.9), bodyContrast)
    let sidebarSecondary = onStops(bg.mix(fg, 0.55), uiContrast)
    // Accent: the system accent if chosen, else the space's first color made saturated enough for
    // white text (spec §2 measured (65,72,216) as the selection fill of the default theme).
    var accent: RGB
    if let s = systemAccent {
      accent = s
    } else if theme.accent != nil, (theme.colors.map { $0.hsb.s }.max() ?? 0) < 0.04 {
      // A greyscale space (near-black, white, grey) gets a neutral accent, not the red that hue 0
      // would turn into at full saturation.
      accent = dark ? RGB(0.40, 0.40, 0.43) : RGB(0.25, 0.25, 0.27)
    } else if let a = theme.accent {
      let h = a.hsb
      accent = RGB(hue: h.h, saturation: max(h.s, 0.55), brightness: dark ? 0.72 : 0.78)
    } else {
      accent = RGB(65 / 255, 72 / 255, 216 / 255)
    }
    // Readable label on it (white preferred), and visible against the surface.
    var onAccent = white
    if accent.contrast(white) < bodyContrast {
      if accent.contrast(ink) >= bodyContrast && systemAccent != nil { onAccent = ink } else {
        accent = ensure(accent, on: white, bodyContrast)
      }
    }
    // Stand off the surface (3:1 for a UI component) as far as the label allows: the label's 4.5:1
    // wins. (A white-labelled accent can't reach 3:1 on a near-black surface; Arc's own #3139FB
    // on #151C30 is 2.5:1.)
    if accent.contrast(surface) < uiContrast {
      let toward = surface.relativeLuminance > 0.18 ? RGB(0, 0, 0) : white
      var t: CGFloat = 0
      while t < 1, accent.mix(toward, t + 0.02).contrast(onAccent) >= bodyContrast, accent.mix(toward, t).contrast(surface) < uiContrast { t += 0.02 }
      accent = accent.mix(toward, t)
    }
    // Destructive: DestructiveButtonFace #F53714, darkened just enough for a white label.
    let destructive = ensure(RGB(0xF5 / 255, 0x37 / 255, 0x14 / 255), on: white, bodyContrast)
    // Toast: deep and theme-blended (Arc's ShinyToastBackgroundBasedPalette), always white-legible.
    let base = dark ? RGB(0.2, 0.2, 0.21) : RGB(0.12, 0.12, 0.13)
    let toast = ensure(hasTheme ? base.mix(tint, 0.45) : base, on: white, bodyContrast)
    let hairFg = dark ? white : RGB(0, 0, 0)
    let card = cardTokens(dark: dark, tint: hasTheme ? tint : nil, intensity: theme.intensity)
    var t = ThemeTokens(
      dark: dark, background: bg, surface: surface, elevated: elevated,
      textPrimary: textPrimary, textSecondary: textSecondary, textTertiary: textTertiary,
      sidebarText: sidebarText, sidebarSecondary: sidebarSecondary,
      accent: accent, onAccent: onAccent, destructive: destructive, onDestructive: white,
      toast: toast, onToast: white,
      hairline: RGBA(hairFg, dark ? 0.1 : 0.08), hover: RGBA(hairFg, dark ? 0.07 : 0.05), pressed: RGBA(hairFg, dark ? 0.12 : 0.09),
      shadow: RGBA(dark ? RGB(0, 0, 0) : RGB(0x15 / 255, 0x1C / 255, 0x32 / 255), dark ? 0.6 : 0.3),  // PopoverShadow (spec §3)
      elevationShadow: RGBA(RGB(0x15 / 255, 0x1C / 255, 0x32 / 255), dark ? 0.8 : 0.3),  // PopoverShadow (spec §3), exact
      // estimates, tuned on snapshots: a crisp edge that separates the surface from a dimmed page
      edge: RGBA(dark ? white : RGB(0x15 / 255, 0x1C / 255, 0x32 / 255), dark ? 0.12 : 0.10),
      rim: RGBA(white, dark ? 0.16 : 0.85),
      dialogDim: 0.55, sheetDim: 0.35,
      grain: theme.grain * 0.5)
    t.card = card
    return t
  }

  /// Dia's card surface (dark #262626, light #F4F4F4), tinted a little toward the space's colors
  /// (at most 6%), with text pushed to the usual contrast targets on it.
  static func cardTokens(dark: Bool, tint: RGB?, intensity: CGFloat) -> CardTokens {
    func hex(_ v: UInt32) -> RGB { RGB(CGFloat((v >> 16) & 0xFF) / 255, CGFloat((v >> 8) & 0xFF) / 255, CGFloat(v & 0xFF) / 255) }
    var c = CardTokens()
    let base = dark ? hex(0x262626) : hex(0xF4F4F4)
    var fill = base
    if let tint {
      let deep = dark ? tint.mix(RGB(0, 0, 0), 0.7) : tint
      fill = base.mix(deep, 0.02 + 0.04 * min(max(intensity, 0), 1))
    }
    c.fill = fill
    c.text = ensure(dark ? hex(0xDEDEDE) : hex(0x252525), on: fill, primaryContrast)
    c.secondary = ensure(dark ? hex(0x9D9D9D) : hex(0x7B7B7B), on: fill, bodyContrast)
    c.glyph = ensure(dark ? hex(0x9D9D9D) : hex(0x7A7A7A), on: fill, uiContrast)
    c.border = dark ? hex(0x3C3C3C) : hex(0xDCDCDC)
    c.highlight = dark ? nil : white
    c.hover = dark ? hex(0x373737) : fill.mix(RGB(0, 0, 0), 0.06)
    // Tooltip: Dia's dark tooltip (#474747 / #E4E4E4). Its light tooltip wasn't measured; den uses
    // the same chip so a tooltip always reads as one.
    c.tooltip = hex(0x474747)
    c.onTooltip = hex(0xE4E4E4)
    if dark {
      // Dia's dark PR card wasn't measured (spec §3.5): GitHub's dark-mode status colors.
      c.success = hex(0x3FB950)
      c.warning = hex(0xD29922)
      c.danger = hex(0xF85149)
      c.track = hex(0x3A3A3A)
      c.addText = ensure(hex(0x3FB950), on: fill, bodyContrast)
      c.delText = ensure(hex(0xF85149), on: fill, bodyContrast)
      c.dangerSoft = fill.mix(hex(0xF85149), 0.16)
      c.onDangerSoft = ensure(hex(0xFFA198), on: c.dangerSoft, bodyContrast)
      c.strong = hex(0xEDEDED)
      c.onStrong = hex(0x161616)
      c.destructive = hex(0xC93C31)
    } else {
      c.addText = ensure(c.addText, on: fill, bodyContrast)
      c.delText = ensure(c.delText, on: fill, bodyContrast)
      c.onDangerSoft = ensure(c.onDangerSoft, on: c.dangerSoft, bodyContrast)
    }
    c.onDestructive = ensure(white, on: c.destructive, bodyContrast)
    return c
  }
}
