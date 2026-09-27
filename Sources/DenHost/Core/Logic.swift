import CordisValue
import CoreGraphics
import Foundation

// Pure, AppKit-free logic used by the services. Unit-tested in DenHostTests.

// MARK: - Theme

public struct RGB: Equatable, Sendable {
  public var r, g, b: CGFloat
  public init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) { (self.r, self.g, self.b) = (r, g, b) }

  public init?(hex: String) {
    var s = hex.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s.removeFirst() }
    if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
    guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
    self.init(CGFloat((v >> 16) & 0xFF) / 255, CGFloat((v >> 8) & 0xFF) / 255, CGFloat(v & 0xFF) / 255)
  }

  public func mix(_ o: RGB, _ t: CGFloat) -> RGB {
    RGB(r + (o.r - r) * t, g + (o.g - g) * t, b + (o.b - b) * t)
  }

  public var luminance: CGFloat { 0.2126 * r + 0.7152 * g + 0.0722 * b }
}

public enum Appearance: String, Sendable { case light, dark, auto }

/// A space theme: gradient of up to 3 colors, intensity and grain; appearance is global in Arc
/// but carried here so a single `setTheme` call can set it.
public struct Theme: Equatable, Sendable {
  public var colors: [RGB]
  public var intensity: CGFloat
  public var grain: CGFloat
  public var appearance: Appearance

  public init(colors: [RGB] = [], intensity: CGFloat = Tokens.defaultIntensity, grain: CGFloat = Tokens.defaultGrain, appearance: Appearance = .auto) {
    self.colors = Array(colors.prefix(3))
    self.intensity = intensity
    self.grain = grain
    self.appearance = appearance
  }

  public init(_ v: Value) {
    self.init(
      colors: v.list("colors").compactMap { $0.string.flatMap(RGB.init(hex:)) },
      intensity: CGFloat(min(max(v.num("intensity", Double(Tokens.defaultIntensity)), 0), 1)),
      grain: CGFloat(min(max(v.num("grain", Double(Tokens.defaultGrain)), 0), 1)),
      appearance: Appearance(rawValue: v.str("appearance", "auto")) ?? .auto)
  }

  /// Gradient stops actually drawn, for a resolved (light/dark) appearance.
  public func stops(dark: Bool) -> [RGB] {
    let b = dark ? Tokens.darkBase : Tokens.lightBase
    let base = RGB(b.r, b.g, b.b)
    guard !colors.isEmpty else { return [base, base] }
    // Dark mode keeps colors deeper; light mode washes them toward the base.
    let t = dark ? intensity * 0.55 : intensity * 0.85
    let s = colors.map { base.mix(dark ? $0.mix(RGB(0, 0, 0), 0.35) : $0, t) }
    return s.count == 1 ? [s[0], s[0].mix(base, 0.25)] : s
  }

  /// Accent tint for toasts, selection, drop indicators.
  public var accent: RGB? { colors.first }

  public func interpolated(to o: Theme, _ t: CGFloat) -> Theme {
    let n = max(colors.count, o.colors.count, 1)
    func at(_ c: [RGB], _ i: Int) -> RGB { c.isEmpty ? RGB(0.5, 0.5, 0.5) : c[min(i, c.count - 1)] }
    var out = self
    out.colors = (0..<n).map { at(colors, $0).mix(at(o.colors, $0), t) }
    if colors.isEmpty && o.colors.isEmpty { out.colors = [] }
    out.intensity = intensity + (o.intensity - intensity) * t
    out.grain = grain + (o.grain - grain) * t
    return out
  }
}

// MARK: - Key chords

public struct Chord: Equatable, Sendable {
  public enum Mod: String, Sendable { case cmd, shift, opt, ctrl }
  public var mods: Set<Mod>
  /// NSMenuItem.keyEquivalent string (lowercase letters, or a function-key character).
  public var key: String

  public static func parse(_ s: String) -> Chord? {
    let parts = s.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
    guard var last = parts.last, !last.isEmpty || s.hasSuffix("++") else { return nil }
    if last.isEmpty { last = "+" }
    var mods = Set<Mod>()
    for p in parts.dropLast() where !p.isEmpty {
      switch p {
      case "cmd", "command", "⌘": mods.insert(.cmd)
      case "shift", "⇧": mods.insert(.shift)
      case "opt", "option", "alt", "⌥": mods.insert(.opt)
      case "ctrl", "control", "⌃": mods.insert(.ctrl)
      default: return nil
      }
    }
    let named: [String: Int] = [
      "left": 0xF702, "right": 0xF703, "up": 0xF700, "down": 0xF701,
      "tab": 0x09, "enter": 0x0D, "return": 0x0D, "esc": 0x1B, "escape": 0x1B,
      "space": 0x20, "delete": 0x08, "backspace": 0x08, "plus": 0x2B, "minus": 0x2D,
    ]
    if let code = named[last], let u = Unicode.Scalar(code) { return Chord(mods: mods, key: String(Character(u))) }
    if last.count == 1 { return Chord(mods: mods, key: last) }
    if last.hasPrefix("f"), let n = Int(last.dropFirst()), (1...20).contains(n), let u = Unicode.Scalar(0xF704 + n - 1) {
      return Chord(mods: mods, key: String(Character(u)))
    }
    return nil
  }
}

// MARK: - Link policy

/// Declarative link routing, decided synchronously inside WKNavigationDelegate.
/// Rule: {"when": "crossSite"|"sameSite"|"any", "hosts": [suffix], "modifiers": ["cmd"], "event": "peek.open"}
public struct LinkRule: Equatable, Sendable {
  public enum When: String, Sendable { case crossSite, sameSite, any }
  public var when: When
  public var hosts: [String]
  public var modifiers: Set<Chord.Mod>
  public var event: String

  public init(when: When = .crossSite, hosts: [String] = [], modifiers: Set<Chord.Mod> = [], event: String) {
    (self.when, self.hosts, self.modifiers, self.event) = (when, hosts, modifiers, event)
  }

  public init?(_ v: Value) {
    let event = v.str("event")
    guard !event.isEmpty else { return nil }
    self.init(
      when: When(rawValue: v.str("when", "crossSite")) ?? .crossSite,
      hosts: v.list("hosts").compactMap(\.string),
      modifiers: Set(v.list("modifiers").compactMap { $0.string.flatMap(Chord.Mod.init(rawValue:)) }),
      event: event)
  }
}

public enum LinkPolicy {
  /// Approximate registrable domain (eTLD+1). Handles common two-level public suffixes;
  /// a full Public Suffix List is future work.
  public static func site(_ host: String) -> String {
    let labels = host.lowercased().split(separator: ".").map(String.init)
    guard labels.count > 2 else { return labels.joined(separator: ".") }
    let twoLevel: Set<String> = ["co.uk", "org.uk", "ac.uk", "gov.uk", "com.au", "net.au", "org.au", "co.jp", "co.nz", "com.br", "co.in", "github.io", "vercel.app", "netlify.app", "pages.dev"]
    let lastTwo = labels.suffix(2).joined(separator: ".")
    return twoLevel.contains(lastTwo) ? labels.suffix(3).joined(separator: ".") : lastTwo
  }

  /// Returns the event to route to, or nil to let the navigation proceed.
  /// Only user link clicks in the main frame are routed.
  public static func route(rules: [LinkRule], source: URL?, target: URL, isLinkClick: Bool, isMainFrame: Bool, modifiers: Set<Chord.Mod>) -> String? {
    guard isLinkClick, isMainFrame, let scheme = target.scheme, scheme == "http" || scheme == "https" else { return nil }
    let targetHost = target.host ?? ""
    let cross = site(source?.host ?? "") != site(targetHost)
    for r in rules {
      if !r.modifiers.isSubset(of: modifiers) { continue }
      if !r.modifiers.isEmpty && r.modifiers != modifiers { continue }
      if r.modifiers.isEmpty && !modifiers.isEmpty { continue }  // plain rules don't eat cmd-click etc.
      switch r.when {
      case .crossSite where !cross: continue
      case .sameSite where cross: continue
      default: break
      }
      if !r.hosts.isEmpty && !r.hosts.contains(where: { targetHost == $0 || targetHost.hasSuffix("." + $0) }) { continue }
      return r.event
    }
    return nil
  }

  /// Browser link-click conventions, applied after the link rules: ⌘-click or a middle-click on a
  /// link opens it in a new background tab; ⌘⇧-click (or ⇧-middle-click) in a new selected tab.
  /// Returns `background`, or nil to navigate normally. `buttonNumber` is WKNavigationAction's
  /// (a button mask: 1 left, 2 right, 4 middle).
  public static func newTab(isLinkClick: Bool, target: URL, modifiers: Set<Chord.Mod>, buttonNumber: Int) -> Bool? {
    guard isLinkClick, let scheme = target.scheme?.lowercased(), ["http", "https", "file", "data"].contains(scheme) else { return nil }
    let middle = buttonNumber & 4 != 0
    guard middle || modifiers.contains(.cmd) else { return nil }
    return !modifiers.contains(.shift)
  }
}

// MARK: - Split layout

public enum SplitOrientation: String, Sendable { case horizontal, vertical, grid }

public enum SplitLayout {
  /// Frames for `count` panes inside `bounds` (y-up is irrelevant: rows are laid out top-first
  /// assuming a flipped coordinate space). `ratios` are optional relative sizes along the split axis.
  public static func frames(count: Int, orientation: SplitOrientation, in bounds: CGRect, gap: CGFloat, ratios: [CGFloat] = []) -> [CGRect] {
    let n = max(1, min(count, 4))
    if n == 1 { return [bounds] }
    func split(_ r: CGRect, _ k: Int, horizontal: Bool, _ rs: [CGFloat]) -> [CGRect] {
      let weights = rs.count == k ? rs.map { max($0, 0.05) } : Array(repeating: 1, count: k)
      let total = weights.reduce(0, +)
      let avail = (horizontal ? r.width : r.height) - gap * CGFloat(k - 1)
      var out: [CGRect] = []
      var pos = horizontal ? r.minX : r.minY
      for w in weights {
        let len = (avail * w / total).rounded()
        out.append(horizontal ? CGRect(x: pos, y: r.minY, width: len, height: r.height) : CGRect(x: r.minX, y: pos, width: r.width, height: len))
        pos += len + gap
      }
      // Absorb rounding into the last pane.
      if var last = out.popLast() {
        if horizontal { last.size.width = r.maxX - last.minX } else { last.size.height = r.maxY - last.minY }
        out.append(last)
      }
      return out
    }
    switch orientation {
    case .horizontal: return split(bounds, n, horizontal: true, ratios)
    case .vertical: return split(bounds, n, horizontal: false, ratios)
    case .grid:
      if n == 2 { return split(bounds, 2, horizontal: true, ratios) }
      let cols = split(bounds, 2, horizontal: true, [])
      let left = n == 4 ? split(cols[0], 2, horizontal: false, []) : [cols[0]]
      let right = split(cols[1], 2, horizontal: false, [])
      return left + right
    }
  }
}
