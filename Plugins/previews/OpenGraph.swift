#if !hasFeature(Embedded)
  import CordisValue
#endif

/// OpenGraph / Twitter-card metadata from a page's `<head>`, for link previews. Byte-level and
/// Foundation-free (Embedded Swift). Tolerant of real-world markup: any attribute order, single or
/// double or no quotes, any tag/attribute case, entities, relative and protocol-relative URLs.
enum OpenGraph {
  static let maxDescription = 300

  /// `{title?, description?, image?, site?, icon?, url?}`: missing fields are absent.
  static func parse(_ html: String, url: String) -> Value {
    let b = Array(headOnly(html).utf8)
    var meta: [String: String] = [:]  // first value per lowercased property/name
    var title = ""
    var icon = ""
    var appleIcon = ""
    var canonical = ""
    var i = 0
    while let lt = index(of: 60, in: b, from: i) {  // <
      i = lt + 1
      if i + 2 < b.count, b[i] == 33, b[i + 1] == 45, b[i + 2] == 45 {  // <!-- … -->
        i = find(b, Array("-->".utf8), from: i).map { $0 + 3 } ?? b.count
        continue
      }
      var j = i
      while j < b.count, isNameByte(b[j]) { j += 1 }
      let name = lowerASCII(Array(b[i..<j]))
      guard !name.isEmpty else { continue }
      let (attrs, end) = attributes(b, from: j)
      i = end
      switch name {
      case "meta":
        let key = lowerASCII(Array((attrs["property"] ?? attrs["name"] ?? attrs["itemprop"] ?? "").utf8))
        if let c = attrs["content"], !key.isEmpty, meta[key] == nil { meta[key] = clean(c) }
      case "link":
        let rel = " " + lowerASCII(Array((attrs["rel"] ?? "").utf8)) + " "
        let href = attrs["href"] ?? ""
        if href.isEmpty { break }
        if contains(rel, " apple-touch-icon") { if appleIcon.isEmpty { appleIcon = href } } else if contains(rel, " icon ") || contains(rel, "shortcut icon") {
          if icon.isEmpty { icon = href }
        } else if contains(rel, " canonical ") && canonical.isEmpty {
          canonical = href
        }
      case "title":
        if title.isEmpty, let close = findCI(b, Array("</title".utf8), from: i) {
          title = clean(String(decoding: b[i..<close], as: UTF8.self))
          i = close
        }
      case "script", "style":
        // Skip their bodies: a "<meta" inside a script is not metadata.
        if let close = findCI(b, Array(("</" + name).utf8), from: i) { i = close }
      default: break
      }
    }
    func first(_ keys: [String]) -> String? {
      for k in keys { if let v = meta[k], !v.isEmpty { return v } }
      return nil
    }
    var out: Value = [:]
    if let t = first(["og:title", "twitter:title"]) ?? (title.isEmpty ? nil : title) { out.put("title", .string(t)) }
    if let d = first(["og:description", "twitter:description", "description"]) { out.put("description", .string(cap(d, maxDescription))) }
    if let img = first(["og:image:secure_url", "og:image", "og:image:url", "twitter:image", "twitter:image:src"]) {
      out.put("image", .string(resolve(img, against: url)))
    }
    let host = hostOf(url)
    if let s = first(["og:site_name", "application-name"]) ?? (host.isEmpty ? nil : dropWWW(host)) { out.put("site", .string(s)) }
    let ic = !icon.isEmpty ? icon : appleIcon
    if !ic.isEmpty {
      out.put("icon", .string(resolve(clean(ic), against: url)))
    } else if let o = origin(url) {
      out.put("icon", .string(o + "/favicon.ico"))
    }
    if let u = first(["og:url"]) ?? (canonical.isEmpty ? nil : clean(canonical)) {
      out.put("url", .string(resolve(u, against: url)))
    } else if !url.isEmpty {
      out.put("url", .string(url))
    }
    return out
  }

  /// The document up to and including `</head>` (case-insensitive), or all of it.
  static func headOnly(_ html: String) -> String {
    let b = Array(html.utf8)
    guard let e = findCI(b, Array("</head>".utf8), from: 0) else { return html }
    return String(decoding: b[..<(e + 7)], as: UTF8.self)
  }

  // MARK: Tags

  static func isNameByte(_ c: UInt8) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 45 || c == 58 || c == 95 || c == 47 }

  static func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 || c == 12 }

  /// Attributes from just after the tag name to the closing `>`: (lowercased name -> raw value, index after `>`).
  static func attributes(_ b: [UInt8], from start: Int) -> ([String: String], Int) {
    var attrs: [String: String] = [:]
    var i = start
    while i < b.count {
      while i < b.count, isSpace(b[i]) || b[i] == 47 { i += 1 }  // spaces, "/"
      guard i < b.count else { break }
      if b[i] == 62 { return (attrs, i + 1) }  // >
      var j = i
      while j < b.count, !isSpace(b[j]), b[j] != 61, b[j] != 62, b[j] != 47 { j += 1 }
      if j == i {  // a stray "=" or quote: skip it
        i += 1
        continue
      }
      let name = lowerASCII(Array(b[i..<j]))
      i = j
      while i < b.count, isSpace(b[i]) { i += 1 }
      var value = ""
      if i < b.count, b[i] == 61 {  // =
        i += 1
        while i < b.count, isSpace(b[i]) { i += 1 }
        if i < b.count, b[i] == 34 || b[i] == 39 {
          let q = b[i]
          let close = index(of: q, in: b, from: i + 1) ?? b.count
          value = String(decoding: b[(i + 1)..<close], as: UTF8.self)
          i = min(b.count, close + 1)
        } else {
          var k = i
          while k < b.count, !isSpace(b[k]), b[k] != 62 { k += 1 }
          value = String(decoding: b[i..<k], as: UTF8.self)
          i = k
        }
      }
      if attrs[name] == nil { attrs[name] = value }
    }
    return (attrs, b.count)
  }

  // MARK: Text

  /// Entities decoded, whitespace collapsed and trimmed.
  static func clean(_ s: String) -> String {
    let b = Array(decodeEntities(s).utf8)
    var out: [UInt8] = []
    var space = false
    for c in b {
      if isSpace(c) {
        space = !out.isEmpty
      } else {
        if space { out.append(32) }
        space = false
        out.append(c)
      }
    }
    return String(decoding: out, as: UTF8.self)
  }

  static func decodeEntities(_ s: String) -> String {
    let b = Array(s.utf8)
    guard b.contains(38) else { return s }
    let named: [(String, UInt32)] = [("amp", 38), ("lt", 60), ("gt", 62), ("quot", 34), ("apos", 39), ("nbsp", 160), ("mdash", 0x2014),
                                     ("ndash", 0x2013), ("hellip", 0x2026), ("rsquo", 0x2019), ("lsquo", 0x2018), ("ldquo", 0x201C),
                                     ("rdquo", 0x201D), ("middot", 0xB7), ("copy", 0xA9), ("reg", 0xAE), ("trade", 0x2122)]
    var out: [UInt8] = []
    var i = 0
    while i < b.count {
      if b[i] == 38, let semi = index(of: 59, in: b, from: i + 1), semi - i <= 10 {
        let body = Array(b[(i + 1)..<semi])
        var cp: UInt32?
        if body.first == 35 {  // #
          var n: UInt32 = 0
          var ok = body.count > 1
          if body.count > 1, body[1] == 120 || body[1] == 88 {  // x
            ok = body.count > 2
            for c in body[2...] {
              let d: UInt32
              if c >= 48 && c <= 57 { d = UInt32(c - 48) } else if c >= 97 && c <= 102 { d = UInt32(c - 87) } else if c >= 65 && c <= 70 { d = UInt32(c - 55) } else { ok = false; break }
              n = n &* 16 &+ d
            }
          } else {
            for c in body[1...] {
              guard c >= 48 && c <= 57 else { ok = false; break }
              n = n &* 10 &+ UInt32(c - 48)
            }
          }
          if ok { cp = n }
        } else {
          let name = String(decoding: body, as: UTF8.self)
          for (k, v) in named where k == name { cp = v }
        }
        if let cp, cp > 0, cp <= 0x10FFFF, !(cp >= 0xD800 && cp <= 0xDFFF) {
          utf8(cp == 160 ? 32 : cp, into: &out)
          i = semi + 1
          continue
        }
      }
      out.append(b[i])
      i += 1
    }
    return String(decoding: out, as: UTF8.self)
  }

  static func utf8(_ cp: UInt32, into out: inout [UInt8]) {
    if cp < 0x80 {
      out.append(UInt8(cp))
    } else if cp < 0x800 {
      out.append(UInt8(0xC0 | (cp >> 6)))
      out.append(UInt8(0x80 | (cp & 0x3F)))
    } else if cp < 0x10000 {
      out.append(UInt8(0xE0 | (cp >> 12)))
      out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
      out.append(UInt8(0x80 | (cp & 0x3F)))
    } else {
      out.append(UInt8(0xF0 | (cp >> 18)))
      out.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
      out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
      out.append(UInt8(0x80 | (cp & 0x3F)))
    }
  }

  /// At most `max` bytes, cut at a UTF-8 boundary (and a word when one is near), with "…".
  static func cap(_ s: String, _ max: Int) -> String {
    let b = Array(s.utf8)
    guard b.count > max else { return s }
    var end = max
    while end > 0, b[end] & 0xC0 == 0x80 { end -= 1 }
    var cut = end
    while cut > max - 40, cut > 0, b[cut - 1] != 32 { cut -= 1 }
    if cut <= max - 40 || cut == 0 { cut = end }
    var out = Array(b[..<cut])
    while out.last == 32 || out.last == 44 || out.last == 46 { out.removeLast() }
    return String(decoding: out, as: UTF8.self) + "…"
  }

  // MARK: URLs

  static func schemeEnd(_ b: [UInt8]) -> Int? {
    guard let r = find(b, Array("://".utf8), from: 0) else { return nil }
    for c in b[..<r] where !((c >= 97 && c <= 122) || (c >= 65 && c <= 90)) { return nil }
    return r
  }

  /// "https://host:port" of an absolute URL.
  static func origin(_ url: String) -> String? {
    let b = Array(url.utf8)
    guard let r = schemeEnd(b) else { return nil }
    var e = r + 3
    while e < b.count, b[e] != 47, b[e] != 63, b[e] != 35 { e += 1 }
    return e > r + 3 ? String(decoding: b[..<e], as: UTF8.self) : nil
  }

  static func hostOf(_ url: String) -> String {
    guard let o = origin(url) else { return "" }
    let b = Array(o.utf8)
    var h = Array(b[(schemeEnd(b)! + 3)...])
    if let at = h.lastIndex(of: 64) { h = Array(h[(at + 1)...]) }
    if let colon = h.firstIndex(of: 58) { h = Array(h[..<colon]) }
    return lowerASCII(h)
  }

  static func dropWWW(_ h: String) -> String {
    let b = Array(h.utf8)
    return b.count > 4 && b[0] == 119 && b[1] == 119 && b[2] == 119 && b[3] == 46 ? String(decoding: b[4...], as: UTF8.self) : h
  }

  /// `ref` resolved against the page URL: absolute, protocol-relative, root-relative or relative.
  static func resolve(_ ref: String, against base: String) -> String {
    let r = Array(ref.utf8)
    guard !r.isEmpty else { return ref }
    if schemeEnd(r) != nil || Text.hasPrefix(Text.lower(ref), "data:") { return ref }
    let bb = Array(base.utf8)
    guard let se = schemeEnd(bb), let o = origin(base) else { return ref }
    if r.count > 1, r[0] == 47, r[1] == 47 { return String(decoding: bb[..<se], as: UTF8.self) + ":" + ref }
    if r[0] == 47 { return o + ref }
    // Directory of the base path (without query/fragment).
    var end = bb.count
    if let q = bb.firstIndex(where: { $0 == 63 || $0 == 35 }) { end = q }
    let path = Array(bb[o.utf8.count..<max(o.utf8.count, end)])
    var dir = path
    if let slash = dir.lastIndex(of: 47) { dir = Array(dir[...slash]) } else { dir = [47] }
    var rel = r
    // Resolve leading "./" and "../" segments.
    while true {
      if rel.count >= 2, rel[0] == 46, rel[1] == 47 { rel.removeFirst(2); continue }
      if rel.count >= 3, rel[0] == 46, rel[1] == 46, rel[2] == 47 {
        rel.removeFirst(3)
        if dir.count > 1 {
          dir.removeLast()
          if let s = dir.lastIndex(of: 47) { dir = Array(dir[...s]) }
        }
        continue
      }
      break
    }
    return o + String(decoding: dir + rel, as: UTF8.self)
  }

  // MARK: Bytes

  static func lowerASCII(_ b: [UInt8]) -> String { String(decoding: b.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }, as: UTF8.self) }

  static func contains(_ s: String, _ needle: String) -> Bool { find(Array(s.utf8), Array(needle.utf8), from: 0) != nil }

  static func index(of c: UInt8, in b: [UInt8], from: Int) -> Int? {
    var i = from
    while i < b.count {
      if b[i] == c { return i }
      i += 1
    }
    return nil
  }

  static func find(_ hay: [UInt8], _ needle: [UInt8], from: Int) -> Int? {
    guard !needle.isEmpty, hay.count >= needle.count, from <= hay.count - needle.count else { return nil }
    var i = from
    while i <= hay.count - needle.count {
      var ok = true
      for j in 0..<needle.count where hay[i + j] != needle[j] {
        ok = false
        break
      }
      if ok { return i }
      i += 1
    }
    return nil
  }

  /// Case-insensitive `find` for a lowercase ASCII needle.
  static func findCI(_ hay: [UInt8], _ needle: [UInt8], from: Int) -> Int? {
    guard !needle.isEmpty, hay.count >= needle.count, from <= hay.count - needle.count else { return nil }
    var i = from
    while i <= hay.count - needle.count {
      var ok = true
      for j in 0..<needle.count {
        var c = hay[i + j]
        if c >= 65 && c <= 90 { c += 32 }
        if c != needle[j] {
          ok = false
          break
        }
      }
      if ok { return i }
      i += 1
    }
    return nil
  }
}
