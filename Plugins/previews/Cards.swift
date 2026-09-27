#if !hasFeature(Embedded)
  import CordisValue
#endif

/// Builds `hoverCard` trees (docs/host-api.md) from a hover request and a provider's data.
///
/// Provider data is a card fragment: any of `title`, `subtitle`, `accessory`, `badges`, `sections`,
/// `actions`, `footer`, `empty`, `image`, `imageVersion`, `imagePending`, plus `summary {text, style}`
/// (a one-badge digest shown next to the tab in folder cards), or `{error}`.
enum Cards {
  static let fields = ["title", "subtitle", "accessory", "badges", "sections", "actions", "footer", "empty", "image", "imageVersion", "imagePending"]

  static func card(_ req: PreviewsCore.Request, _ data: Value, loading: Bool) -> Value {
    var t: Value = [
      "type": "hoverCard", "id": .string(PreviewsCore.cardId), "anchor": .string(req.anchor),
      "icon": .string(req.icon.isEmpty ? "sf:globe" : req.icon),
      "title": .string(req.title.isEmpty ? URLs.display(req.url) : req.title),
      "subtitle": .string(URLs.display(req.url)),
    ]
    for k in fields where !data[k].isNull { t.put(k, data[k]) }
    if data.isErr {
      t.put("empty", .string(friendly(data.s("error"))))
    } else if loading {
      t.put("loading", true)
    }
    return t
  }

  static func friendly(_ error: String) -> String {
    if Text.contains(error, "permission") { return "den can't read this site yet." }
    if Text.contains(error, "no service") || Text.contains(error, "unknown service") { return "Previews for this site need a newer den." }
    return "Couldn't load a preview right now."
  }

  /// A folder: its tabs, each with the cached digest from its provider when there is one
  /// (never a request: hovering a folder costs nothing).
  static func folder(_ req: PreviewsCore.Request, cached: (String) -> Value?) -> Value {
    var rows: [Value] = []
    for item in req.items.prefix(6) {
      let url = item.s("url")
      var row: Value = ["id": item["id"], "title": .string(item.sOpt("title") ?? URLs.display(url)), "subtitle": .string(URLs.display(url)),
                        "icon": .string(item.sOpt("icon") ?? "sf:globe")]
      if let d = cached(url), !d["summary"].isNull {
        row.put("accessory", d["summary"]["text"])
        row.put("status", d["summary"]["style"])
      }
      rows.append(row)
    }
    let n = req.items.count
    var data: Value = [
      "subtitle": .string(n == 1 ? "1 tab" : String(n) + " tabs"),
      "sections": .array(rows.isEmpty ? [] : [["rows": .array(rows)]]),
    ]
    if n > 6 { data.put("footer", .string("and " + String(n - 6) + " more")) }
    if n == 0 { data.put("empty", "This folder is empty.") }
    return card(PreviewsCore.Request(anchor: req.anchor, url: "", title: req.title, icon: req.icon.isEmpty ? "sf:folder.fill" : req.icon,
                                     webview: "", profile: req.profile, selected: false, kind: "folder", items: []), data, loading: false)
  }

  static func badge(_ text: String, _ style: String, _ icon: String = "") -> Value {
    var b: Value = ["text": .string(text), "style": .string(style)]
    if !icon.isEmpty { b.put("icon", .string(icon)) }
    return b
  }

  static func row(_ title: String, subtitle: String = "", icon: String = "", status: String = "", accessory: String = "", url: String = "", id: String = "") -> Value {
    var r: Value = ["title": .string(title)]
    if !subtitle.isEmpty { r.put("subtitle", .string(subtitle)) }
    if !icon.isEmpty { r.put("icon", .string(icon)) }
    if !status.isEmpty { r.put("status", .string(status)) }
    if !accessory.isEmpty { r.put("accessory", .string(accessory)) }
    if !url.isEmpty { r.put("url", .string(url)) }
    r.put("id", .string(id.isEmpty ? title : id))
    return r
  }

  static func section(_ title: String, _ rows: [Value]) -> Value {
    var s: Value = ["rows": .array(rows)]
    if !title.isEmpty { s.put("title", .string(title)) }
    return s
  }
}

/// Plain-string helpers (no Foundation in plugins).
enum PV {
  static func plural(_ n: Int, _ one: String, _ many: String) -> String { String(n) + " " + (n == 1 ? one : many) }

  /// "2026-09-27T10:04:05Z" (or with a ±hh:mm offset) -> ms since 1970; 0 if unparsable.
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
    if i < b.count, b[i] == 46 { i += 1; while i < b.count, b[i] >= 48 && b[i] <= 57 { i += 1 } }
    var offset: Int64 = 0
    if i < b.count, b[i] == 43 || b[i] == 45, let oh = num(i + 1, 2) {
      let om = num(i + 4, 2) ?? 0
      offset = (oh * 60 + om) * 60_000 * (b[i] == 45 ? -1 : 1)
    }
    let yy = mo <= 2 ? y - 1 : y
    let era = (yy >= 0 ? yy : yy - 399) / 400
    let yoe = yy - era * 400
    let doy = (153 * (mo > 2 ? mo - 3 : mo + 9) + 2) / 5 + d - 1
    let days = era * 146_097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719_468
    return (days * 86_400 + h * 3600 + mi * 60 + se) * 1000 - offset
  }

  static func ago(_ ms: Int64, now: Int64) -> String {
    guard ms > 0 else { return "" }
    let s = max(0, (now - ms) / 1000)
    if s < 60 { return "now" }
    if s < 3600 { return String(s / 60) + "m" }
    if s < 86_400 { return String(s / 3600) + "h" }
    return String(s / 86_400) + "d"
  }

  static func encode(_ s: String) -> String {
    let hex: [UInt8] = Array("0123456789ABCDEF".utf8)
    var out: [UInt8] = []
    for c in s.utf8 {
      if (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 45 || c == 46 || c == 95 || c == 126 {
        out.append(c)
      } else {
        out.append(37)
        out.append(hex[Int(c >> 4)])
        out.append(hex[Int(c & 15)])
      }
    }
    return String(decoding: out, as: UTF8.self)
  }

  /// True when `s` is safe to splice into a script as a path segment.
  static func safeSegment(_ s: String) -> Bool {
    guard !s.isEmpty else { return false }
    for c in s.utf8 {
      let ok = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 45 || c == 46 || c == 95
      if !ok { return false }
    }
    return true
  }

  // MARK: Tiny XML reader (Gmail's Atom feed)

  static func between(_ s: [UInt8], _ open: String, _ close: String, from: Int = 0) -> (String, Int)? {
    let o = Array(open.utf8), c = Array(close.utf8)
    guard let a = find(s, o, from: from) else { return nil }
    let start = a + o.count
    guard let b = find(s, c, from: start) else { return nil }
    return (String(decoding: s[start..<b], as: UTF8.self), b + c.count)
  }

  static func find(_ hay: [UInt8], _ needle: [UInt8], from: Int = 0) -> Int? {
    guard !needle.isEmpty, hay.count >= needle.count, from <= hay.count - needle.count else { return nil }
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

  static func unescape(_ s: String) -> String {
    var out = s
    for (e, r) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
      out = replace(out, e, r)
    }
    return out
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
}
