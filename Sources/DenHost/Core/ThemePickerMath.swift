import CoreGraphics
import Foundation

// Pure mapping used by the theme picker's 2D color pad (unit-tested, AppKit-free).
//
// The pad is a unit square. Its center is the palest point; the angle around the center
// picks the hue and the distance from it picks the saturation. // estimate: Arc's exact pad
// mapping is UNVERIFIED (spec §4 only measures the pad's frame).

extension RGB {
  /// "#rrggbb" (lowercase).
  public var hex: String {
    func c(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
    return String(format: "#%02x%02x%02x", c(r), c(g), c(b))
  }

  public init(hue h: CGFloat, saturation s: CGFloat, brightness v: CGFloat) {
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
  public var hsb: (h: CGFloat, s: CGFloat, v: CGFloat) {
    let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
    var h: CGFloat = 0
    if d > 0 {
      if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
      h /= 6
      if h < 0 { h += 1 }
    }
    return (h, mx == 0 ? 0 : d / mx, mx)
  }
}

public enum ThemePickerMath {
  public static let minSaturation: CGFloat = 0.12  // estimate: pad center is a pale tint, not white
  public static let maxSaturation: CGFloat = 0.9  // estimate
  public static let edgeDimming: CGFloat = 0.12  // estimate: colors at the rim are slightly deeper

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
  public static func snap(_ p: CGPoint, pitch: CGFloat, size: CGFloat) -> (point: CGPoint, cell: Int) {
    let n = max(1, Int((size / pitch).rounded(.down)))
    let ix = min(max(Int((p.x / pitch).rounded()), 0), n), iy = min(max(Int((p.y / pitch).rounded()), 0), n)
    return (CGPoint(x: CGFloat(ix) * pitch, y: CGFloat(iy) * pitch), iy * (n + 1) + ix)
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
