// Helpers for plugins that read web data (connections, slack, github, briefing). No Foundation.

#if !hasFeature(Embedded)
  import CordisValue
#endif

enum Web {
  /// application/x-www-form-urlencoded (RFC 3986 unreserved characters pass through).
  static func form(_ pairs: [(String, String)]) -> String {
    var out = ""
    for (i, p) in pairs.enumerated() {
      if i > 0 { out += "&" }
      out += encode(p.0) + "=" + encode(p.1)
    }
    return out
  }

  static func encode(_ s: String) -> String {
    let hex: [UInt8] = Array("0123456789ABCDEF".utf8)
    var out: [UInt8] = []
    for c in s.utf8 {
      let unreserved = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 45 || c == 46 || c == 95 || c == 126
      if unreserved {
        out.append(c)
      } else {
        out.append(37)
        out.append(hex[Int(c >> 4)])
        out.append(hex[Int(c & 15)])
      }
    }
    return String(decoding: out, as: UTF8.self)
  }

  /// Drops HTML tags and decodes the common entities (GitHub search highlights titles).
  static func plain(_ html: String) -> String {
    var out: [UInt8] = []
    var inTag = false
    for c in html.utf8 {
      if c == 60 { inTag = true; continue }  // <
      if c == 62 && inTag { inTag = false; continue }  // >
      if !inTag { out.append(c) }
    }
    var s = String(decoding: out, as: UTF8.self)
    for (e, r) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
      s = replace(s, e, r)
    }
    return s
  }

  static func replace(_ s: String, _ a: String, _ b: String) -> String {
    let hay = Array(s.utf8), needle = Array(a.utf8)
    guard !needle.isEmpty, hay.count >= needle.count else { return s }
    var out: [UInt8] = []
    var i = 0
    while i < hay.count {
      if i + needle.count <= hay.count {
        var match = true
        for j in 0..<needle.count where hay[i + j] != needle[j] {
          match = false
          break
        }
        if match {
          out += Array(b.utf8)
          i += needle.count
          continue
        }
      }
      out.append(hay[i])
      i += 1
    }
    return String(decoding: out, as: UTF8.self)
  }

  /// Collapses whitespace runs (newlines included) to single spaces and trims.
  static func oneLine(_ s: String, max: Int = 240) -> String {
    var out: [UInt8] = []
    var space = false
    for c in s.utf8 {
      if c == 32 || c == 10 || c == 13 || c == 9 {
        space = !out.isEmpty
        continue
      }
      if space { out.append(32); space = false }
      out.append(c)
    }
    var r = String(decoding: out, as: UTF8.self)
    if r.count > max { r = String(r.prefix(max)) + "…" }
    return r
  }

  /// The value of query parameter `name` in `url`, or "".
  static func query(_ url: String, _ name: String) -> String {
    let b = Array(url.utf8)
    guard let q = b.firstIndex(of: 63) else { return "" }  // ?
    var parts: [[UInt8]] = [[]]
    for c in b[(q + 1)...] {
      if c == 35 { break }  // #
      if c == 38 { parts.append([]) } else { parts[parts.count - 1].append(c) }
    }
    let key = Array((name + "=").utf8)
    for p in parts where p.count >= key.count && Array(p[0..<key.count]) == key {
      return String(decoding: p[key.count...], as: UTF8.self)
    }
    return ""
  }

  /// "1700000000.123456" (Slack message ts) -> ms since 1970.
  static func slackMs(_ ts: String) -> Int64 {
    var sec: Int64 = 0, frac: Int64 = 0, digits = 0, dot = false
    for c in ts.utf8 {
      if c == 46 { dot = true; continue }
      guard c >= 48 && c <= 57 else { break }
      if dot {
        if digits < 3 { frac = frac * 10 + Int64(c - 48); digits += 1 }
      } else {
        sec = sec * 10 + Int64(c - 48)
      }
    }
    while digits < 3 { frac *= 10; digits += 1 }
    return sec * 1000 + frac
  }

  /// ISO 8601 ("2026-09-27T04:41:12.000+01:00", "...Z") -> ms since 1970. 0 if unparseable.
  static func isoMs(_ s: String) -> Int64 {
    let b = Array(s.utf8)
    func num(_ from: Int, _ len: Int) -> Int64? {
      guard from + len <= b.count else { return nil }
      var n: Int64 = 0
      for i in from..<(from + len) {
        guard b[i] >= 48 && b[i] <= 57 else { return nil }
        n = n * 10 + Int64(b[i] - 48)
      }
      return n
    }
    guard let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2), let h = num(11, 2), let mi = num(14, 2), let se = num(17, 2) else { return 0 }
    var i = 19
    var ms: Int64 = 0
    if i < b.count, b[i] == 46 {
      i += 1
      var digits = 0
      while i < b.count, b[i] >= 48 && b[i] <= 57 {
        if digits < 3 { ms = ms * 10 + Int64(b[i] - 48); digits += 1 }
        i += 1
      }
      while digits < 3 { ms *= 10; digits += 1 }
    }
    var offset: Int64 = 0
    if i < b.count, b[i] == 43 || b[i] == 45, let oh = num(i + 1, 2) {
      let om = num(i + 4, 2) ?? num(i + 3, 2) ?? 0
      offset = (oh * 60 + om) * 60_000 * (b[i] == 45 ? -1 : 1)
    }
    return (days(y, mo, d) * 86_400 + h * 3600 + mi * 60 + se) * 1000 + ms - offset
  }

  /// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
  static func days(_ y0: Int64, _ m: Int64, _ d: Int64) -> Int64 {
    let y = m <= 2 ? y0 - 1 : y0
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146_097 + doe - 719_468
  }

  /// "YYYY-MM-DD" for ms since 1970 (UTC).
  static func date(_ ms: Int64) -> String {
    let z = ms / 86_400_000 + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp < 10 ? mp + 3 : mp - 9
    let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
    return String(y) + "-" + pad(m) + "-" + pad(d)
  }

  static func pad(_ n: Int64) -> String { n < 10 ? "0" + String(n) : String(n) }

  // MARK: JSON (request bodies)

  /// `v` as compact JSON. Doubles are written as integers (request bodies never need fractions).
  static func json(_ v: Value) -> String {
    var out: [UInt8] = []
    writeJSON(v, &out)
    return String(decoding: out, as: UTF8.self)
  }

  static func writeJSON(_ v: Value, _ out: inout [UInt8]) {
    switch v {
    case .null, .bytes: out += Array("null".utf8)
    case let .bool(b): out += Array((b ? "true" : "false").utf8)
    case let .int(n): out += Array(String(n).utf8)
    case let .double(d): out += Array(String(Int64(d)).utf8)
    case let .string(s): writeString(s, &out)
    case let .array(items):
      out.append(91)
      for (k, it) in items.enumerated() {
        if k > 0 { out.append(44) }
        writeJSON(it, &out)
      }
      out.append(93)
    case let .object(pairs):
      out.append(123)
      for (k, p) in pairs.enumerated() {
        if k > 0 { out.append(44) }
        writeString(p.0, &out)
        out.append(58)
        writeJSON(p.1, &out)
      }
      out.append(125)
    }
  }

  static func writeString(_ s: String, _ out: inout [UInt8]) {
    let hex: [UInt8] = Array("0123456789abcdef".utf8)
    out.append(34)
    for c in s.utf8 {
      switch c {
      case 34: out += [92, 34]
      case 92: out += [92, 92]
      case 10: out += [92, 110]
      case 13: out += [92, 114]
      case 9: out += [92, 116]
      case 0..<32: out += [92, 117, 48, 48, hex[Int(c >> 4)], hex[Int(c & 15)]]
      default: out.append(c)
      }
    }
    out.append(34)
  }

  // MARK: Tiny XML reader (Gmail's Atom feed)

  /// The text between the first `open` at or after `from` and the next `close`, and the index
  /// just past `close`.
  static func between(_ s: [UInt8], _ open: String, _ close: String, from: Int = 0) -> (String, Int)? {
    let o = Array(open.utf8), c = Array(close.utf8)
    guard let a = find(s, o, from: from) else { return nil }
    let start = a + o.count
    guard let b = find(s, c, from: start) else { return nil }
    return (String(decoding: s[start..<b], as: UTF8.self), b + c.count)
  }

  static func find(_ hay: [UInt8], _ needle: [UInt8], from: Int = 0) -> Int? {
    guard !needle.isEmpty, hay.count >= needle.count, from >= 0, from <= hay.count - needle.count else { return nil }
    var i = from
    while i <= hay.count - needle.count {
      if hay[i] == needle[0] {
        var ok = true
        for j in 1..<needle.count where hay[i + j] != needle[j] {
          ok = false
          break
        }
        if ok { return i }
      }
      i += 1
    }
    return nil
  }

  /// The UTF-8 bytes of one Unicode scalar value.
  static func utf8(_ n: UInt32) -> [UInt8] {
    if n < 0x80 { return [UInt8(n)] }
    if n < 0x800 { return [UInt8(0xC0 | (n >> 6)), UInt8(0x80 | (n & 0x3F))] }
    if n < 0x10000 { return [UInt8(0xE0 | (n >> 12)), UInt8(0x80 | ((n >> 6) & 0x3F)), UInt8(0x80 | (n & 0x3F))] }
    return [UInt8(0xF0 | (n >> 18)), UInt8(0x80 | ((n >> 12) & 0x3F)), UInt8(0x80 | ((n >> 6) & 0x3F)), UInt8(0x80 | (n & 0x3F))]
  }

  /// XML/HTML text: named entities (`&amp;` …) and decimal/hex character references.
  static func entities(_ s: String) -> String {
    let b = Array(s.utf8)
    guard b.contains(38) else { return s }  // &
    var out: [UInt8] = []
    var i = 0
    while i < b.count {
      if b[i] == 38, let semi = b[i...].prefix(12).firstIndex(of: 59) {  // & … ;
        let name = String(decoding: b[(i + 1)..<semi], as: UTF8.self)
        var rep: [UInt8]?
        switch name {
        case "amp": rep = [38]
        case "lt": rep = [60]
        case "gt": rep = [62]
        case "quot": rep = [34]
        case "apos": rep = [39]
        case "nbsp": rep = [32]
        default:
          let nb = Array(name.utf8)
          if nb.first == 35 {  // #
            var n: UInt32 = 0
            var ok = nb.count > 1
            let hex = nb.count > 1 && (nb[1] == 120 || nb[1] == 88)
            for c in nb.dropFirst(hex ? 2 : 1) {
              var d: UInt32
              switch c {
              case 48...57: d = UInt32(c - 48)
              case 97...102 where hex: d = UInt32(c - 87)
              case 65...70 where hex: d = UInt32(c - 55)
              default: ok = false; d = 0
              }
              n = n &* (hex ? 16 : 10) &+ d
            }
            if ok, n > 0, n < 0x110000, !(0xD800...0xDFFF).contains(n) { rep = utf8(n) }
          }
        }
        if let rep {
          out += rep
          i = semi + 1
          continue
        }
      }
      out.append(b[i])
      i += 1
    }
    return String(decoding: out, as: UTF8.self)
  }

  /// "now", "5m", "3h", "2d" (for feed rows).
  static func ago(_ ms: Int64, now: Int64) -> String {
    let s = (now - ms) / 1000
    if ms <= 0 { return "" }
    if s < 60 { return "now" }
    if s < 3600 { return String(s / 60) + "m" }
    if s < 86_400 { return String(s / 3600) + "h" }
    return String(s / 86_400) + "d"
  }
}

/// Matches the asynchronous host results (`net.result`, `session.result`, `ai.result`) to
/// callbacks. Request ids are `<prefix>-<n>`, so each plugin only sees its own answers.
final class Requests {
  let env: PluginEnv
  let prefix: String
  var next = 1
  var waiting: [String: (Value) -> Void] = [:]

  init(env: PluginEnv, prefix: String) {
    self.env = env
    self.prefix = prefix
    for e in ["net.result", "session.result", "ai.result"] {
      env.on(e) { [self] v in
        guard let done = waiting.removeValue(forKey: v.s("id")) else { return }
        done(v)
      }
    }
  }

  /// Calls `service.method(args + {id})`; `done` gets the result event (or `{ok: false, error}`).
  func call(_ service: String, _ method: String, _ args: Value, _ done: @escaping (Value) -> Void) {
    let id = prefix + "-" + String(next)
    next += 1
    var a = args
    a.put("id", .string(id))
    waiting[id] = done
    let r = env.call(service, method, a)
    if r.isErr {
      waiting[id] = nil
      done(["id": .string(id), "ok": false, "error": r["error"]])
    }
  }

  var inFlight: Int { waiting.count }
}

/// Runs `n` steps one after another: each step gets a `next` to call when it is done, then `done`.
func sequence(_ steps: [(@escaping () -> Void) -> Void], _ done: @escaping () -> Void) {
  guard let first = steps.first else { return done() }
  let rest = Array(steps.dropFirst())
  first { sequence(rest, done) }
}
