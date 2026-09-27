// International domain names for display: Punycode (RFC 3492) decoding and a script check, so
// the URL pill shows "bücher.de" but keeps "xn--pple-43d.com" for a Cyrillic "аpple.com".
// Plain Swift over Unicode scalar values (no Foundation, no Character tables: Embedded Swift).

enum IDN {
  // MARK: UTF-8

  static func scalars(_ s: String) -> [UInt32] {
    var out: [UInt32] = []
    let b = Array(s.utf8)
    var i = 0
    while i < b.count {
      let c = UInt32(b[i])
      if c < 0x80 {
        out.append(c); i += 1
      } else if c >> 5 == 0x6, i + 1 < b.count {
        out.append((c & 0x1F) << 6 | UInt32(b[i + 1] & 0x3F)); i += 2
      } else if c >> 4 == 0xE, i + 2 < b.count {
        out.append((c & 0x0F) << 12 | UInt32(b[i + 1] & 0x3F) << 6 | UInt32(b[i + 2] & 0x3F)); i += 3
      } else if c >> 3 == 0x1E, i + 3 < b.count {
        out.append((c & 0x07) << 18 | UInt32(b[i + 1] & 0x3F) << 12 | UInt32(b[i + 2] & 0x3F) << 6 | UInt32(b[i + 3] & 0x3F)); i += 4
      } else {
        out.append(0xFFFD); i += 1
      }
    }
    return out
  }

  static func string(_ scalars: [UInt32]) -> String {
    var b: [UInt8] = []
    for c in scalars {
      if c < 0x80 {
        b.append(UInt8(c))
      } else if c < 0x800 {
        b.append(UInt8(0xC0 | c >> 6)); b.append(UInt8(0x80 | c & 0x3F))
      } else if c < 0x10000 {
        b.append(UInt8(0xE0 | c >> 12)); b.append(UInt8(0x80 | (c >> 6) & 0x3F)); b.append(UInt8(0x80 | c & 0x3F))
      } else if c < 0x110000 {
        b.append(UInt8(0xF0 | c >> 18)); b.append(UInt8(0x80 | (c >> 12) & 0x3F)); b.append(UInt8(0x80 | (c >> 6) & 0x3F)); b.append(UInt8(0x80 | c & 0x3F))
      }
    }
    return String(decoding: b, as: UTF8.self)
  }

  static func labels(_ host: String) -> [String] {
    var out: [String] = []
    var cur: [UInt8] = []
    for c in host.utf8 {
      if c == 46 { out.append(String(decoding: cur, as: UTF8.self)); cur = [] } else { cur.append(c) }
    }
    out.append(String(decoding: cur, as: UTF8.self))
    return out
  }

  // MARK: Punycode (RFC 3492)

  /// Decodes one label's Punycode part (without "xn--"). nil when it isn't valid Punycode.
  static func punycode(_ label: String) -> [UInt32]? {
    let base: UInt32 = 36, tmin: UInt32 = 1, tmax: UInt32 = 26
    let input = Array(label.utf8)
    var output: [UInt32] = []
    var start = 0
    if let dash = input.lastIndex(of: 45) {
      for c in input[..<dash] {
        guard c < 0x80 else { return nil }
        output.append(UInt32(c))
      }
      start = dash + 1
    }
    var n: UInt32 = 128, i: UInt32 = 0, bias: UInt32 = 72
    var pos = start
    while pos < input.count {
      let oldi = i
      var w: UInt32 = 1
      var k = base
      while true {
        guard pos < input.count else { return nil }
        let c = input[pos]
        pos += 1
        let digit: UInt32
        switch c {
        case 97...122: digit = UInt32(c - 97)
        case 65...90: digit = UInt32(c - 65)
        case 48...57: digit = UInt32(c - 48) + 26
        default: return nil
        }
        let (m, o1) = digit.multipliedReportingOverflow(by: w)
        let (s, o2) = i.addingReportingOverflow(m)
        guard !o1, !o2 else { return nil }
        i = s
        let t = k <= bias ? tmin : (k >= bias + tmax ? tmax : k - bias)
        if digit < t { break }
        let (nw, o3) = w.multipliedReportingOverflow(by: base - t)
        guard !o3 else { return nil }
        w = nw
        k += base
      }
      let count = UInt32(output.count + 1)
      bias = adapt(i - oldi, count, oldi == 0)
      let (nn, o4) = n.addingReportingOverflow(i / count)
      guard !o4, nn < 0x110000 else { return nil }
      n = nn
      i %= count
      output.insert(n, at: Int(i))
      i += 1
    }
    return output
  }

  static func adapt(_ delta: UInt32, _ numPoints: UInt32, _ first: Bool) -> UInt32 {
    var d = first ? delta / 700 : delta / 2
    d += d / numPoints
    var k: UInt32 = 0
    while d > ((36 - 1) * 26) / 2 {
      d /= 36 - 1
      k += 36
    }
    return k + (36 - 1 + 1) * d / (d + 38)
  }

  /// Each label as Unicode scalars ("xn--" labels decoded). nil when a label isn't valid.
  static func unicodeLabels(_ host: String) -> [[UInt32]]? {
    var out: [[UInt32]] = []
    for l in labels(Text.lower(host)) {
      if Text.hasPrefix(l, "xn--") {
        guard let d = punycode(Text.dropPrefix(l, "xn--")), !d.isEmpty else { return nil }
        out.append(d)
      } else {
        out.append(scalars(l))
      }
    }
    return out
  }

  static func hasPunycode(_ host: String) -> Bool { Text.contains(host, "xn--") }

  // MARK: Scripts

  enum Script: Equatable { case common, latin, greek, cyrillic, armenian, hebrew, arabic, devanagari, thai, georgian, hangul, hiragana, katakana, bopomofo, han, other }

  static func script(_ c: UInt32) -> Script {
    switch c {
    case 0x30...0x39, 0x2D, 0x5F, 0xB7, 0x300...0x36F: return .common  // digits, hyphen, underscore, middle dot, combining marks
    case 0x41...0x5A, 0x61...0x7A, 0xC0...0xD6, 0xD8...0xF6, 0xF8...0x24F, 0x1E00...0x1EFF, 0x2C60...0x2C7F, 0xA720...0xA7FF, 0xAB30...0xAB6F: return .latin
    case 0x370...0x3FF, 0x1F00...0x1FFF: return .greek
    case 0x400...0x52F, 0x1C80...0x1C8F, 0x2DE0...0x2DFF, 0xA640...0xA69F: return .cyrillic
    case 0x530...0x58F: return .armenian
    case 0x590...0x5FF: return .hebrew
    case 0x600...0x6FF, 0x750...0x77F, 0x8A0...0x8FF: return .arabic
    case 0x900...0x97F: return .devanagari
    case 0xE00...0xE7F: return .thai
    case 0x10A0...0x10FF: return .georgian
    case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: return .hangul
    case 0x3040...0x309F: return .hiragana
    case 0x30A0...0x30FF, 0x31F0...0x31FF: return .katakana
    case 0x3100...0x312F, 0x31A0...0x31BF: return .bopomofo
    case 0x3005, 0x3007, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FFFF: return .han
    default: return .other
    }
  }

  /// Cyrillic and Greek letters that look like Latin ones (lowercase). A label made only of these
  /// is a whole-script confusable ("раура1" in Cyrillic reads as "paypal").
  static func latinLookalike(_ c: UInt32) -> UInt32? {
    switch c {
    case 0x430: return 0x61  // а a
    case 0x435, 0x451: return 0x65  // е ё e
    case 0x43E: return 0x6F  // о o
    case 0x440: return 0x70  // р p
    case 0x441: return 0x63  // с c
    case 0x443, 0x4AF: return 0x79  // у ү y
    case 0x445, 0x4B3: return 0x78  // х x
    case 0x456, 0x457: return 0x69  // і ї i
    case 0x458: return 0x6A  // ј j
    case 0x455: return 0x73  // ѕ s
    case 0x4BB: return 0x68  // һ h
    case 0x4CF: return 0x6C  // ӏ l
    case 0x501: return 0x64  // ԁ d
    case 0x51B: return 0x71  // ԛ q
    case 0x51D: return 0x77  // ԝ w
    case 0x43A: return 0x6B  // к k
    case 0x3B1: return 0x61  // α a
    case 0x3BF, 0x3CC: return 0x6F  // ο ό o
    case 0x3C1: return 0x70  // ρ p
    case 0x3BD: return 0x76  // ν v
    case 0x3B9, 0x3AF: return 0x69  // ι ί i
    case 0x3BA: return 0x6B  // κ k
    case 0x3C4: return 0x74  // τ t
    case 0x3C5: return 0x75  // υ u
    case 0x3C7: return 0x78  // χ x
    case 0x261: return 0x67  // ɡ g (Latin script, but the IPA g)
    case 0x131: return 0x69  // ı dotless i
    default: return nil
    }
  }

  /// Characters that never display as Unicode: invisible ones, fullwidth forms and look-alikes of
  /// "/", "." and ":" that could fake a URL's structure.
  static func forbidden(_ c: UInt32) -> Bool {
    switch c {
    case 0x200B...0x200F, 0x2028...0x202E, 0x2060...0x206F, 0xFE00...0xFE0F, 0xFEFF, 0xFF00...0xFFEF,
         0x2024, 0x2044, 0x2215, 0x29F8, 0x2236, 0x0589, 0x05C3, 0x0701, 0x0702, 0x3002, 0x02D0, 0x2E2E:
      return true
    default: return false
    }
  }

  /// Whether one label may show in Unicode: one script (digits and hyphens aside), or Latin mixed
  /// only with the scripts that are written together with it (Japanese: Han + kana; Chinese: Han +
  /// Bopomofo; Korean: Han + Hangul). A label made only of Latin look-alikes from Cyrillic or Greek
  /// stays in Punycode. Modeled on Chrome's IDN display policy (a subset).
  static func safe(_ label: [UInt32]) -> Bool {
    var scripts: [Script] = []
    var letters = 0, lookalikes = 0
    for c in label {
      if forbidden(c) { return false }
      let s = script(c)
      if s == .other { return false }
      if s == .common { continue }
      letters += 1
      if (s == .cyrillic || s == .greek), latinLookalike(c) != nil { lookalikes += 1 }
      if !scripts.contains(s) { scripts.append(s) }
    }
    if letters > 0, lookalikes == letters { return false }
    if scripts.count <= 1 { return true }
    let allowed: [[Script]] = [[.latin, .han, .hiragana, .katakana], [.latin, .han, .bopomofo], [.latin, .han, .hangul]]
    return allowed.contains { set in scripts.allSatisfy { set.contains($0) } }
  }

  /// The host as people should read it: Unicode when every label is safe, otherwise the ASCII
  /// (Punycode) form it arrived in.
  static func display(_ host: String) -> String {
    guard hasPunycode(host), let ls = unicodeLabels(host) else { return host }
    for l in ls where !safe(l) { return host }
    var out: [UInt32] = []
    for (i, l) in ls.enumerated() {
      if i > 0 { out.append(46) }
      out.append(contentsOf: l)
    }
    return string(out)
  }
}
