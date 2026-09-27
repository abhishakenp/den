// Shared by every den plugin. Compiled into each plugin by cordis-build (Embedded Swift), and
// into the `PluginCores` test target as normal Swift. No Foundation.

#if !hasFeature(Embedded)
  import CordisValue
#endif

/// Everything a plugin core needs from the outside world. In a plugin these closures wrap the
/// cordis `Context`; in tests they wrap a real `PluginHost` with den's host services.
struct PluginEnv {
  var invoke: (String, String, Value) -> Value
  var emit: (String, Value) -> Void
  var on: (String, @escaping (Value) -> Void) -> Void
  var timer: (UInt64, Bool, @escaping () -> Void) -> Void
  /// Wall-clock milliseconds since 1970.
  var now: () -> Int64
  var log: (String) -> Void

  @discardableResult
  func call(_ service: String, _ method: String, _ args: Value = .null) -> Value { invoke(service, method, args) }
}

extension Value {
  func s(_ key: String) -> String { self[key].string ?? "" }
  func sOpt(_ key: String) -> String? {
    if let v = self[key].string, !v.isEmpty { return v }
    return nil
  }
  func i(_ key: String, _ fallback: Int64 = 0) -> Int64 {
    if let v = self[key].int { return v }
    if let d = self[key].double { return Int64(d) }
    return fallback
  }
  func b(_ key: String, _ fallback: Bool = false) -> Bool { self[key].bool ?? fallback }
  func a(_ key: String) -> [Value] { self[key].array ?? [] }
  var isErr: Bool { !self["error"].isNull }

  mutating func put(_ key: String, _ value: Value) {
    guard case var .object(pairs) = self else {
      self = .object([(key, value)])
      return
    }
    for j in 0..<pairs.count where pairs[j].0 == key {
      pairs[j].1 = value
      self = .object(pairs)
      return
    }
    pairs.append((key, value))
    self = .object(pairs)
  }

  static func str(_ s: String?) -> Value { s.map { .string($0) } ?? .null }
  static func err(_ message: String) -> Value { ["error": .string(message)] }
  static var okay: Value { ["ok": true] }
}

enum Text {
  static func lower(_ s: String) -> String {
    var out: [UInt8] = []
    out.reserveCapacity(s.utf8.count)
    for c in s.utf8 { out.append(c >= 65 && c <= 90 ? c + 32 : c) }
    return String(decoding: out, as: UTF8.self)
  }

  static func hasPrefix(_ s: String, _ p: String) -> Bool {
    let a = Array(s.utf8), b = Array(p.utf8)
    guard a.count >= b.count else { return false }
    for j in 0..<b.count where a[j] != b[j] { return false }
    return true
  }

  static func dropPrefix(_ s: String, _ p: String) -> String {
    hasPrefix(s, p) ? String(decoding: Array(s.utf8)[p.utf8.count...], as: UTF8.self) : s
  }

  static func contains(_ s: String, _ needle: String) -> Bool {
    let a = Array(lower(s).utf8), b = Array(lower(needle).utf8)
    if b.isEmpty { return true }
    guard a.count >= b.count else { return false }
    for start in 0...(a.count - b.count) {
      var ok = true
      for j in 0..<b.count where a[start + j] != b[j] {
        ok = false
        break
      }
      if ok { return true }
    }
    return false
  }

  static func int(_ s: String) -> Int? {
    var n = 0
    var any = false
    for c in s.utf8 {
      guard c >= 48 && c <= 57 else { return nil }
      n = n * 10 + Int(c - 48)
      any = true
    }
    return any ? n : nil
  }
}

/// URL helpers on plain strings (no Foundation in plugins).
enum URLs {
  /// "https://www.example.com:8080/a?b#c" -> "example.com". Returns the input for non-URLs.
  static func host(_ url: String) -> String {
    let bytes = Array(url.utf8)
    var start = 0
    if let r = find(bytes, Array("://".utf8)) { start = r + 3 }
    var end = start
    while end < bytes.count, bytes[end] != 47, bytes[end] != 63, bytes[end] != 35 { end += 1 }  // / ? #
    var h = Array(bytes[start..<end])
    if let at = h.lastIndex(of: 64) { h = Array(h[(at + 1)...]) }  // user@
    if let colon = h.lastIndex(of: 58) { h = Array(h[..<colon]) }  // :port
    var s = lower(String(decoding: h, as: UTF8.self))
    s = Text.dropPrefix(s, "www.")
    return s.isEmpty ? url : s
  }

  /// Simplified display for the URL pill: the domain, like Arc.
  static func display(_ url: String) -> String {
    if url.isEmpty || url == "about:blank" { return "" }
    return host(url)
  }

  /// Comparable form for the pinned-URL drift check: no scheme, no "www.", no fragment,
  /// no trailing slash.
  static func normalize(_ url: String) -> String {
    var bytes = Array(url.utf8)
    if let r = find(bytes, Array("://".utf8)) { bytes = Array(bytes[(r + 3)...]) }
    if let hash = bytes.firstIndex(of: 35) { bytes = Array(bytes[..<hash]) }
    while bytes.last == 47 { bytes.removeLast() }
    var s = String(decoding: bytes, as: UTF8.self)
    s = Text.dropPrefix(lower(s), "www.")
    return s
  }

  static func drifted(url: String, pinned: String?) -> Bool {
    guard let p = pinned, !p.isEmpty else { return false }
    return normalize(url) != normalize(p)
  }

  static func favicon(_ url: String) -> String {
    "https://www.google.com/s2/favicons?domain=" + host(url) + "&sz=64"
  }

  static func lower(_ s: String) -> String { Text.lower(s) }

  static func find(_ hay: [UInt8], _ needle: [UInt8]) -> Int? {
    guard hay.count >= needle.count, !needle.isEmpty else { return nil }
    for start in 0...(hay.count - needle.count) {
      var ok = true
      for j in 0..<needle.count where hay[start + j] != needle[j] {
        ok = false
        break
      }
      if ok { return start }
    }
    return nil
  }
}
