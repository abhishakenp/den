// What an import brings over, independent of the browser it came from. The parsers
// (ImportArc/Chromium/Safari/Firefox.swift) fill an `ImportResult`; ImporterCore maps it onto
// den's spaces, tabs and command bar history. No Foundation (Embedded Swift).

#if !hasFeature(Embedded)
  import CordisValue
#endif

/// A tab or a folder of them. `key` is stable across imports of the same data (the browser's own
/// id where it has one), so a second import finds what the first one made.
struct ImportNode {
  var key: String
  var title: String
  var url: String = ""
  var folder = false
  var open = false
  var children: [ImportNode] = []

  static func tab(_ key: String, _ title: String, _ url: String) -> ImportNode { ImportNode(key: key, title: title, url: url) }
  static func folder(_ key: String, _ title: String, _ children: [ImportNode], open: Bool = false) -> ImportNode {
    ImportNode(key: key, title: title, folder: true, open: open, children: children)
  }

  /// The `tabs.importItems` node shape.
  var value: Value {
    if folder {
      return ["key": .string(key), "title": .string(title), "folder": true, "open": .bool(open), "children": .array(children.map { $0.value })]
    }
    var v: Value = ["key": .string(key), "url": .string(url)]
    if !title.isEmpty { v.put("title", .string(title)) }
    return v
  }

  var tabCount: Int { folder ? children.reduce(0) { $0 + $1.tabCount } : 1 }

  /// Drops what den can't open (javascript:, chrome://, place:, file:, empty) and folders left empty.
  static func clean(_ nodes: [ImportNode]) -> [ImportNode] {
    var out: [ImportNode] = []
    for var n in nodes {
      if n.folder {
        n.children = clean(n.children)
        if !n.children.isEmpty { out.append(n) }
      } else if URLs.isWeb(n.url) {
        out.append(n)
      }
    }
    return out
  }
}

/// A space (Arc, Zen workspaces) with its look and its tabs.
struct ImportSpace {
  var key: String
  var name: String
  var icon = ""
  /// Up to three "#rrggbb" colors, primary first (den's theme model).
  var colors: [String] = []
  var grain: Double?
  var appearance: String?
  /// den profile name ("default" or a name); nil keeps den's default.
  var profile: String?
  var pinned: [ImportNode] = []
  var today: [ImportNode] = []

  var theme: Value? {
    guard !colors.isEmpty else { return nil }
    var t: Value = ["colors": .array(colors.map { .string($0) }), "intensity": 0.6]
    if let g = grain { t.put("grain", .double(g)) }
    if let a = appearance { t.put("appearance", .string(a)) }
    return t
  }
}

struct ImportVisit {
  var url: String
  var title: String
  var visits: Int64
  /// Last visit, ms since 1970.
  var last: Int64

  var value: Value { ["url": .string(url), "title": .string(title), "visits": .int(visits), "last": .int(last)] }
}

struct ImportResult {
  var source: String
  var name: String
  var spaces: [ImportSpace] = []
  var favorites: [ImportNode] = []
  /// Bookmarks become one collapsed pinned folder, "<Browser> Bookmarks", in the current space:
  /// Arc's model has no bookmarks, only pinned tabs and folders (docs/guide/import.md).
  var bookmarks: [ImportNode] = []
  /// Tabs open in the other browser: one Today group, "From <Browser>".
  var openTabs: [ImportNode] = []
  var history: [ImportVisit] = []
  /// What couldn't be read, for den.log (never shown as an error unless nothing was read).
  var problems: [String] = []
  var readSomething = false
}

enum ImportFormat {
  /// 12840 -> "12,840".
  static func count(_ n: Int) -> String {
    let digits = Array(String(n < 0 ? -n : n).utf8)
    var out: [UInt8] = n < 0 ? [45] : []
    for (i, c) in digits.enumerated() {
      if i > 0 && (digits.count - i) % 3 == 0 { out.append(44) }  // ,
      out.append(c)
    }
    return String(decoding: out, as: UTF8.self)
  }

  /// "1 space" / "4 spaces".
  static func noun(_ n: Int, _ one: String, _ many: String) -> String { count(n) + " " + (n == 1 ? one : many) }

  /// "a, b and c".
  static func list(_ parts: [String]) -> String {
    guard parts.count > 1 else { return parts.first ?? "" }
    var s = ""
    for (j, p) in parts.enumerated() { s += (j == 0 ? "" : j == parts.count - 1 ? " and " : ", ") + p }
    return s
  }

  /// A 0–1 (or 0–255) color component to two hex digits.
  static func hex(_ components: [Double]) -> String {
    let digits = Array("0123456789abcdef".utf8)
    let scale: Double = components.contains { $0 > 1.0001 } ? 1 : 255
    var out: [UInt8] = [35]  // #
    for c in components.prefix(3) {
      var v = Int(c * scale + 0.5)
      v = max(0, min(255, v))
      out.append(digits[v / 16])
      out.append(digits[v % 16])
    }
    return String(decoding: out, as: UTF8.self)
  }

  /// The last path component of "~/a/b/c" ("c").
  static func lastComponent(_ path: String) -> String {
    var bytes = Array(path.utf8)
    while bytes.last == 47 { bytes.removeLast() }
    guard let i = bytes.lastIndex(of: 47) else { return path }
    return String(decoding: bytes[(i + 1)...], as: UTF8.self)
  }
}

/// Little-endian reader over bytes (Chromium's session files).
struct ByteReader {
  let b: [UInt8]
  var i = 0

  init(_ bytes: [UInt8], at start: Int = 0) {
    b = bytes
    i = start
  }

  var remaining: Int { b.count - i }

  mutating func u8() -> UInt8? {
    guard i < b.count else { return nil }
    defer { i += 1 }
    return b[i]
  }

  mutating func u16() -> Int? {
    guard i + 2 <= b.count else { return nil }
    defer { i += 2 }
    return Int(b[i]) | Int(b[i + 1]) << 8
  }

  mutating func i32() -> Int? {
    guard i + 4 <= b.count else { return nil }
    defer { i += 4 }
    let u = UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    return Int(Int32(bitPattern: u))
  }

  mutating func bytes(_ n: Int) -> [UInt8]? {
    guard n >= 0, i + n <= b.count else { return nil }
    defer { i += n }
    return Array(b[i..<(i + n)])
  }

  mutating func align4() { i = (i + 3) & ~3 }
}

enum UTF16Text {
  /// Little-endian UTF-16 code units to a String (surrogate pairs joined, bad ones dropped).
  static func decode(_ bytes: [UInt8]) -> String {
    var units: [UInt16] = []
    var j = 0
    while j + 1 < bytes.count {
      units.append(UInt16(bytes[j]) | UInt16(bytes[j + 1]) << 8)
      j += 2
    }
    var out: [UInt8] = []
    var k = 0
    while k < units.count {
      var scalar = UInt32(units[k])
      if scalar >= 0xD800 && scalar < 0xDC00, k + 1 < units.count, units[k + 1] >= 0xDC00, units[k + 1] < 0xE000 {
        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (UInt32(units[k + 1]) - 0xDC00)
        k += 1
      } else if scalar >= 0xD800 && scalar < 0xE000 {
        k += 1
        continue
      }
      k += 1
      utf8(scalar, &out)
    }
    return String(decoding: out, as: UTF8.self)
  }

  static func utf8(_ s: UInt32, _ out: inout [UInt8]) {
    if s < 0x80 {
      out.append(UInt8(s))
    } else if s < 0x800 {
      out.append(UInt8(0xC0 | (s >> 6)))
      out.append(UInt8(0x80 | (s & 0x3F)))
    } else if s < 0x10000 {
      out.append(UInt8(0xE0 | (s >> 12)))
      out.append(UInt8(0x80 | ((s >> 6) & 0x3F)))
      out.append(UInt8(0x80 | (s & 0x3F)))
    } else {
      out.append(UInt8(0xF0 | (s >> 18)))
      out.append(UInt8(0x80 | ((s >> 12) & 0x3F)))
      out.append(UInt8(0x80 | ((s >> 6) & 0x3F)))
      out.append(UInt8(0x80 | (s & 0x3F)))
    }
  }

  /// A Unicode scalar (Arc's numeric emoji) as a String.
  static func scalar(_ v: Int64) -> String {
    guard v > 0, v < 0x110000, !(v >= 0xD800 && v < 0xE000) else { return "" }
    var out: [UInt8] = []
    utf8(UInt32(v), &out)
    return String(decoding: out, as: UTF8.self)
  }
}
