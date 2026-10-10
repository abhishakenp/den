// Pure theme rules for the `theme` plugin: hex/HSB conversion and the constraints that keep
// space themes harmonious (Arc: "the picker keeps the colors complementary, which makes bad
// themes hard to create", research §5). No Foundation; compiled as Embedded Swift too.

#if !hasFeature(Embedded)
  import CordisValue
#endif

import CoreGraphics
import Foundation

// MARK: - Color type (moved from DenHost/Core/Logic.swift + DenHost/Core/ThemeTokens.swift + DenHost/Core/ThemePickerMath.swift)

/// RGB color used throughout the theme system. Double-based so it works in Embedded Swift.
public struct RGB: Equatable, Sendable {
  public var r, g, b: Double
  public init(_ r: Double, _ g: Double, _ b: Double) { (self.r, self.g, self.b) = (r, g, b) }

  public init?(hex: String) {
    var s = hex.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s.removeFirst() }
    if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
    guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
    self.init(Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
  }

  public func mix(_ o: RGB, _ t: Double) -> RGB {
    RGB(r + (o.r - r) * t, g + (o.g - g) * t, b + (o.b - b) * t)
  }

  public var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
}

extension RGB {
  /// WCAG 2.x relative luminance (linearized sRGB).
  public var relativeLuminance: Double {
    func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
  }

  /// WCAG contrast ratio (1…21) between two opaque colors.
  public func contrast(_ o: RGB) -> Double {
    let a = relativeLuminance, b = o.relativeLuminance
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
  }

  public var clamped: RGB { RGB(min(max(r, 0), 1), min(max(g, 0), 1), min(max(b, 0), 1)) }
}

/// A color with alpha, for overlays drawn on a surface (hairlines, hover, pressed, shadow).
public struct RGBA: Equatable, Sendable {
  public var rgb: RGB
  public var a: Double
  public init(_ rgb: RGB, _ a: Double) { (self.rgb, self.a) = (rgb, a) }
}

extension RGB {
  /// "#rrggbb" (lowercase).
  public var hex: String {
    func c(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
    return String(format: "#%02x%02x%02x", c(r), c(g), c(b))
  }

  public init(hue h: Double, saturation s: Double, brightness v: Double) {
    let h6 = (h - floor(h)) * 6, i = Int(h6) % 6, f = h6 - floor(h6)
    let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
    switch i {
    case 0: self.init(v, t, p)
    case 1: self.init(q, v, p)
    case 2: self.init(p, v, t)
    case 3: self.init(p, q, v)
    case 4: self.init(t, p, v)
    default: self.init(v, p, q)
    }
  }

  /// (hue 0..<1, saturation, brightness)
  public var hsb: (h: Double, s: Double, v: Double) {
    let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
    var h: Double = 0
    if d > 0 {
      if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
      h /= 6
      if h < 0 { h += 1 }
    }
    return (h, mx == 0 ? 0 : d / mx, mx)
  }
}

// MARK: - Theme picker math (moved from DenHost/Core/ThemePickerMath.swift)

public enum ThemePickerMath {
  public static let minSaturation: Double = 0.12  // estimate: pad center is a pale tint, not white
  public static let maxSaturation: Double = 0.9  // estimate
  public static let edgeDimming: Double = 0.12  // estimate: colors at the rim are slightly deeper

  /// Color at a normalized pad point (0...1 on both axes, y down).
  public static func color(at p: CGPoint) -> RGB {
    let dx = p.x - 0.5, dy = p.y - 0.5
    let r = min(1, hypot(dx, dy) / 0.5)
    var hue = atan2(-dy, dx) / (2 * .pi)
    if hue < 0 { hue += 1 }
    let s = minSaturation + (maxSaturation - minSaturation) * r
    return RGB(hue: hue, saturation: s, brightness: 1 - edgeDimming * r)
  }

  /// Inverse of `color(at:)`: where a color sits on the pad (greys land in the center).
  public static func position(for c: RGB) -> CGPoint {
    let (h, s, _) = c.hsb
    let r = min(1, max(0, (s - minSaturation) / (maxSaturation - minSaturation)))
    let a = h * 2 * .pi
    return CGPoint(x: 0.5 + cos(a) * r * 0.5, y: 0.5 - sin(a) * r * 0.5)
  }

  /// Snaps a point (pad points) to the dot grid. Returns the grid cell index too, so callers
  /// can fire one haptic tick per cell change while dragging.
  public static func snap(_ p: CGPoint, pitch: Double, size: Double) -> (point: CGPoint, cell: Int) {
    let n = max(1, Int((size / pitch).rounded(.down)))
    let ix = min(max(Int((p.x / pitch).rounded()), 0), n), iy = min(max(Int((p.y / pitch).rounded()), 0), n)
    return (CGPoint(x: Double(ix) * pitch, y: Double(iy) * pitch), iy * (n + 1) + ix)
  }

  /// Positions for extra colors added with "+": hue-rotated copies of the first handle.
  public static func added(to positions: [CGPoint]) -> CGPoint {
    guard let first = positions.first else { return CGPoint(x: 0.5, y: 0.2) }
    let dx = first.x - 0.5, dy = first.y - 0.5
    let r = max(0.35, hypot(dx, dy)), a = atan2(dy, dx) + (positions.count == 1 ? 2.1 : -2.1)  // estimate: ±120°
    return CGPoint(x: 0.5 + cos(a) * r, y: 0.5 + sin(a) * r)
  }

  /// Preset swatch pages (spec §3, CAR `ColorPicker*`): Brand, Pastel, Drab, Greyscale.
  public static let presetPages: [[String]] = [
    ["#F2EAE4", "#F29BBB", "#A6729D", "#F25E6B", "#FF3C19", "#F2D66D", "#73E59C", "#7EB8D6", "#666786"],
    ["#FDFBFA", "#FBEAF3", "#ECD2EA", "#F7CDD2", "#FAE1D5", "#FEF9E7", "#E4FCEC", "#E0F2FB", "#C5C6E2"],
    ["#4B3B58", "#623856", "#854444", "#A77048", "#D1B46A", "#CDCCA8", "#84A885", "#34604B", "#2D4468"],
    ["#FFFFFF", "#E5E5E5", "#CCCCCC", "#B2B2B2", "#808080", "#666666", "#333333", "#1A1A1A", "#000000"],
  ]
}

struct HSB: Equatable {
  var h: Double  // 0..<1
  var s: Double
  var v: Double
}

enum ThemeRules {
  static let maxColors = 3
  /// den's own rule (not measured from Arc): a secondary color's saturation and brightness stay
  /// within this distance of the primary's, so a neon color can't sit next to a muddy one.
  static let band = 0.35
  /// Below this saturation a color is treated as grey: it has no meaningful hue to follow.
  static let greyCutoff = 0.05
  static let appearances = ["auto", "light", "dark"]
  // Must match ThemePickerMath min/maxSaturation so recomputed dots land right.
  static let padMinSaturation = 0.12
  static let padMaxSaturation = 0.9

  // MARK: Hex

  /// "#rrggbb" / "rrggbb" / "#rgb" -> (r, g, b) 0...1. Nil when malformed.
  static func rgb(_ hex: String) -> (Double, Double, Double)? {
    var digits: [Int] = []
    for c in hex.utf8 {
      if c == 35 && digits.isEmpty { continue }  // leading '#'
      guard let d = nibble(c) else { return nil }
      digits.append(d)
    }
    if digits.count == 3 { digits = [digits[0], digits[0], digits[1], digits[1], digits[2], digits[2]] }
    guard digits.count == 6 else { return nil }
    func byte(_ i: Int) -> Double { Double(digits[i] * 16 + digits[i + 1]) / 255 }
    return (byte(0), byte(2), byte(4))
  }

  static func nibble(_ c: UInt8) -> Int? {
    switch c {
    case 48...57: return Int(c - 48)
    case 97...102: return Int(c - 87)
    case 65...70: return Int(c - 55)
    default: return nil
    }
  }

  static func hex(_ r: Double, _ g: Double, _ b: Double) -> String {
    let digits: [UInt8] = Array("0123456789abcdef".utf8)
    var out: [UInt8] = [35]
    for x in [r, g, b] {
      let n = Int((min(max(x, 0), 1) * 255).rounded())
      out.append(digits[n / 16])
      out.append(digits[n % 16])
    }
    return String(decoding: out, as: UTF8.self)
  }

  /// Canonical lowercase "#rrggbb", or nil.
  static func normalizeHex(_ s: String) -> String? {
    guard let (r, g, b) = rgb(s) else { return nil }
    return hex(r, g, b)
  }

  // MARK: HSB

  static func hsb(_ hex: String) -> HSB? {
    guard let (r, g, b) = rgb(hex) else { return nil }
    let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
    var h = 0.0
    if d > 0 {
      if mx == r {
        h = (g - b) / d
        if h < 0 { h += 6 }
      } else if mx == g {
        h = (b - r) / d + 2
      } else {
        h = (r - g) / d + 4
      }
      h /= 6
    }
    return HSB(h: h, s: mx == 0 ? 0 : d / mx, v: mx)
  }

  static func hex(_ c: HSB) -> String {
    var h = c.h - Double(Int(c.h))
    if h < 0 { h += 1 }
    let s = min(max(c.s, 0), 1), v = min(max(c.v, 0), 1)
    let h6 = h * 6
    let i = Int(h6) % 6
    let f = h6 - Double(Int(h6))
    let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
    switch i {
    case 0: return hex(v, t, p)
    case 1: return hex(q, v, p)
    case 2: return hex(p, v, t)
    case 3: return hex(p, q, v)
    case 4: return hex(t, p, v)
    default: return hex(v, p, q)
    }
  }

  // MARK: Rules

  /// Cleans a theme value (from the picker or storage): at most 3 valid colors, intensity and
  /// grain in 0...1, appearance one of auto/light/dark. Positions survive only when they match
  /// the colors one to one.
  static func sanitize(_ t: Value) -> Value {
    var colors: [String] = []
    for c in t["colors"].array ?? [] {
      if let h = c.string.flatMap(normalizeHex), colors.count < maxColors { colors.append(h) }
    }
    var out: Value = ["colors": .array(colors.map { .string($0) })]
    out.put("intensity", .double(clamp01(t["intensity"].double ?? 0.6)))
    out.put("grain", .double(clamp01(t["grain"].double ?? 0.3)))
    let a = t["appearance"].string ?? "auto"
    out.put("appearance", .string(appearances.contains(a) ? a : "auto"))
    let ps = t["positions"].array ?? []
    if ps.count == colors.count, !colors.isEmpty { out.put("positions", .array(ps)) }
    return out
  }

  /// Applies the harmony rules to `next` (what the picker just reported), given `prev` (the
  /// colors before this edit):
  /// 1. A newly added color becomes a suggestion: the primary's complement, or a triadic partner
  ///    whose hue no existing color already uses.
  /// 2. When only the primary moved, the other colors rotate their hue by the same amount, so
  ///    their relationship (complementary, triadic, analogous) is kept.
  /// 3. Every secondary color's saturation and brightness stay within `band` of the primary's.
  static func harmonize(prev: [String], next: [String]) -> [String] {
    var out = Array(next.prefix(maxColors))
    guard out.count >= 2, let p0 = hsb(out[0]) else { return out }
    if out.count == prev.count + 1, Array(out[..<prev.count]) == prev {
      let used = prev.compactMap { hsb($0) }.filter { $0.s >= greyCutoff }.map { $0.h }
      if let pick = suggestions(for: out[0]).first(where: { s in
        guard let h = hsb(s)?.h else { return false }
        return used.allSatisfy { hueDistance($0, h) >= 0.1 }
      }) {
        out[out.count - 1] = pick
      }
    } else if prev.count == out.count, prev[0] != out[0], Array(prev[1...]) == Array(out[1...]),
      let old0 = hsb(prev[0]), old0.s >= greyCutoff, p0.s >= greyCutoff
    {
      let dh = p0.h - old0.h
      for j in 1..<out.count {
        guard var c = hsb(out[j]), c.s >= greyCutoff else { continue }
        c.h += dh
        out[j] = hex(c)
      }
    }
    for j in 1..<out.count {
      guard var c = hsb(out[j]) else { continue }
      let s = clamp(c.s, p0.s - band, p0.s + band), v = clamp(c.v, p0.v - band, p0.v + band)
      if s != c.s || v != c.v {
        c.s = s
        c.v = v
        out[j] = hex(c)
      }
    }
    return out
  }

  /// Suggested companions for a primary color: its complement and its two triadic partners at
  /// the same saturation and brightness. Used when a theme has a single color and the user asks
  /// for a suggestion.
  static func suggestions(for primary: String) -> [String] {
    guard let c = hsb(primary) else { return [] }
    if c.s < greyCutoff {
      // Greys: suggest a lighter and a darker grey instead of hues.
      return [hex(HSB(h: 0, s: 0, v: clamp(c.v + 0.2, 0, 1))), hex(HSB(h: 0, s: 0, v: clamp(c.v - 0.2, 0, 1)))]
    }
    return [0.5, 1.0 / 3, 2.0 / 3].map { hex(HSB(h: c.h + $0, s: c.s, v: c.v)) }
  }

  /// Where a color sits on the picker's pad (0...1, y down); the inverse of the host mapping.
  static func position(for hex: String) -> [Double] {
    guard let c = hsb(hex) else { return [0.5, 0.5] }
    let r = clamp01((c.s - padMinSaturation) / (padMaxSaturation - padMinSaturation))
    let a = c.h * 2 * Double.pi
    let (c0, s0) = cosSin(a)
    return [0.5 + c0 * r * 0.5, 0.5 - s0 * r * 0.5]
  }

  /// cos and sin by Taylor series after reducing to [-π, π] (no libm in Embedded plugins).
  /// Error < 1e-9 over the range, far below a pad dot (1/80 of the pad).
  static func cosSin(_ x: Double) -> (Double, Double) {
    let twoPi = 2 * Double.pi
    var a = x - twoPi * Double(Int(x / twoPi))
    if a > Double.pi { a -= twoPi }
    if a < -Double.pi { a += twoPi }
    var c = 0.0, s = 0.0, term = 1.0
    for n in 0..<24 {
      // term = a^n / n!
      switch n % 4 {
      case 0: c += term
      case 1: s += term
      case 2: c -= term
      default: s -= term
      }
      term *= a / Double(n + 1)
    }
    return (c, s)
  }

  /// Shortest distance between two hues on the 0..<1 circle.
  static func hueDistance(_ a: Double, _ b: Double) -> Double {
    var d = a - b
    d -= Double(Int(d))
    if d < 0 { d += 1 }
    return min(d, 1 - d)
  }

  static func clamp01(_ x: Double) -> Double { clamp(x, 0, 1) }
  static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(max(x, lo), hi) }

  static func colors(_ t: Value) -> [String] { (t["colors"].array ?? []).compactMap { $0.string } }
}
