// thin-host: feature-specific, migrate to plugin (whole file)
import AppKit
import CordisValue
import UniformTypeIdentifiers

/// `chrome.downloads` over den's downloads (the host `downloads` service: `WKDownload` into
/// ~/Downloads, the Library's Downloads list). den's ids are `d<n>`; an extension sees `<n>`.
/// `download` starts one with the selected tab's session (`filename` is a path under Downloads,
/// `conflictAction: overwrite` replaces, `saveAs` asks); `pause`, `resume`, `cancel`, `open`,
/// `show`, `showDefaultFolder`, `erase` (off the list), `removeFile`, `getFileIcon` and `search`
/// work on the same list the Library shows. `onCreated`, `onChanged` and `onErased` come from
/// diffing that list on the service's events, only while an extension listens.
/// `onDeterminingFilename` never fires: den names files itself.
@MainActor
final class ExtensionDownloads {
  let call: (String, String, Value) -> Value
  init(call: @escaping (String, String, Value) -> Value) { self.call = call }

  /// Which extension started which download (`byExtensionId`, `byExtensionName`).
  var startedBy: [String: (id: String, name: String)] = [:]

  static func number(_ id: String) -> Int64? { id.hasPrefix("d") ? Int64(id.dropFirst()) : nil }
  static func denId(_ n: Value) -> String? { n.int.map { "d\($0)" } ?? n.double.map { "d\(Int64($0))" } }

  func items() -> [Value] { call("downloads", "list", .null).list("items") }

  static let iso: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
  static func date(_ ms: Double) -> String { iso.string(from: Date(timeIntervalSince1970: ms / 1000)) }

  /// den's download item as Chrome's `DownloadItem`.
  func item(_ d: Value) -> Value {
    let state = d.str("state")
    let chromeState = state == "done" ? "complete" : (state == "downloading" || state == "paused") ? "in_progress" : "interrupted"
    let received = d["received"].int ?? 0, total = d["total"].int ?? -1
    let path = d.str("path")
    var v: Value = [
      "id": .int(Self.number(d.str("id")) ?? 0), "url": .string(d.str("url")), "finalUrl": .string(d.str("url")), "referrer": "",
      "filename": .string(path), "incognito": false, "danger": "safe", "mime": .string(Self.mime(path)),
      "startTime": .string(Self.date(d.num("started"))), "state": .string(chromeState), "paused": .bool(state == "paused"),
      "canResume": .bool(state == "paused" || state == "failed"), "bytesReceived": .int(received), "totalBytes": .int(total),
      "fileSize": .int(state == "done" ? max(received, total) : total), "exists": .bool(d.flag("exists")),
    ]
    if let f = d["finished"].double, f > 0 { v = v.with("endTime", .string(Self.date(f))) }
    if state == "downloading", let rate = d["rate"].double, rate > 0, total > 0 {
      v = v.with("estimatedEndTime", .string(Self.date(Date().timeIntervalSince1970 * 1000 + Double(total - received) / rate * 1000)))
    }
    if state == "cancelled" { v = v.with("error", "USER_CANCELED") } else if state == "failed" { v = v.with("error", "NETWORK_FAILED") }
    if let by = startedBy[d.str("id")] { v = v.with("byExtensionId", .string(by.id)).with("byExtensionName", .string(by.name)) }
    return v
  }

  static func mime(_ path: String) -> String {
    let ext = (path as NSString).pathExtension
    guard !ext.isEmpty, let t = UTType(filenameExtension: ext) else { return "" }
    return t.preferredMIMEType ?? ""
  }

  // MARK: The API

  /// `ext`: (den id, name) of the calling extension; `tab`: the web view to download with.
  func handle(_ method: String, _ args: [Value], ext: (id: String, name: String), tab: String?, done: @escaping (Value) -> Void) {
    let a = args.first ?? .null
    func withItem(_ f: (String, Value) -> Value) -> Value {
      guard let id = Self.denId(a), let d = items().first(where: { $0.str("id") == id }) else { return .error("Invalid download id \(a)") }
      return f(id, d)
    }
    switch method {
    case "download":
      let url = a.str("url")
      guard let u = URL(string: url), u.scheme != nil else { return done(.error("Invalid URL.")) }
      var args: Value = ["url": .string(u.absoluteString), "ask": .bool(a.flag("saveAs")), "conflict": .string(a.str("conflictAction", "uniquify"))]
      if let tab { args = args.with("webview", .string(tab)) }
      if let f = a["filename"].string, !f.isEmpty { args = args.with("name", .string(f)) }
      if let m = a["method"].string { args = args.with("method", .string(m)) }
      if let h = a["headers"].array { args = args.with("headers", .array(h)) }
      if let b = a["body"].string { args = args.with("body", .string(b)) }
      let r = call("downloads", "start", args)
      guard let id = r["id"].string, let n = Self.number(id) else { return done(.error(r.str("error", "Couldn’t start the download"))) }
      startedBy[id] = ext
      done(.int(n))
    case "search": done(.array(search(a)))
    case "pause", "resume", "cancel":
      done(withItem { id, d in
        if method == "cancel", !["downloading", "paused"].contains(d.str("state")) { return .null }  // Chrome: no error
        if method == "pause", d.str("state") == "paused" { return .null }
        let r = call("downloads", method, ["id": .string(id)])
        return r.isError ? .error("Download must be in progress") : .null
      })
    case "open", "show":
      done(withItem { id, _ in
        let r = call("downloads", method == "open" ? "open" : "reveal", ["id": .string(id)])
        return r.isError ? .error("Download file doesn’t exist") : .null
      })
    case "showDefaultFolder":
      _ = call("downloads", "showFolder", .null)
      done(.null)
    case "erase":
      let ids = search(a).compactMap { $0["id"].int }
      for n in ids { _ = call("downloads", "remove", ["id": .string("d\(n)")]) }
      done(.array(ids.map { .int($0) }))
    case "removeFile":
      done(withItem { _, d in
        guard d.str("state") == "done" else { return .error("Download must be complete") }
        let p = d.str("path")
        guard !p.isEmpty, FileManager.default.fileExists(atPath: p) else { return .error("Download file doesn’t exist") }
        do { try FileManager.default.removeItem(atPath: p) } catch { return .error(error.localizedDescription) }
        return .null
      })
    case "getFileIcon":
      done(withItem { _, d in
        let size = (args.count > 1 ? args[1]["size"].int : nil) ?? 32
        let img = NSWorkspace.shared.icon(forFile: d.str("path"))
        guard let png = WebViewsService.encode(img, width: CGFloat(size), jpeg: false) else { return .error("No icon") }
        return .string("data:image/png;base64," + png.base64EncodedString())
      })
    case "acceptDanger", "setShelfEnabled", "setUiOptions", "drag": done(.null)
    default: done(.error("downloads.\(method) isn’t available in den"))
    }
  }

  /// `search(query)`: Chrome's DownloadQuery (id, url/urlRegex, filename/filenameRegex, query
  /// terms, state, paused, exists, mime, times, sizes, orderBy, limit).
  func search(_ q: Value) -> [Value] {
    var out = items().map(item)
    func str(_ v: Value, _ k: String) -> String { v[k].string ?? "" }
    if let id = q["id"].int { out = out.filter { $0["id"].int == id } }
    for (k, field) in [("url", "url"), ("finalUrl", "finalUrl"), ("filename", "filename"), ("state", "state"), ("mime", "mime"), ("danger", "danger"), ("error", "error")] {
      if let want = q[k].string { out = out.filter { str($0, field) == want } }
    }
    for (k, field) in [("urlRegex", "url"), ("finalUrlRegex", "finalUrl"), ("filenameRegex", "filename")] {
      if let p = q[k].string, let re = try? NSRegularExpression(pattern: p) {
        out = out.filter { let s = str($0, field); return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
      }
    }
    for k in ["paused", "exists", "canResume"] { if let b = q[k].bool { out = out.filter { $0[k].bool == b } } }
    if let terms = q["query"].array?.compactMap(\.string), !terms.isEmpty {
      out = out.filter { d in
        let hay = (str(d, "url") + " " + str(d, "filename")).lowercased()
        return terms.allSatisfy { t in t.hasPrefix("-") ? !hay.contains(t.dropFirst().lowercased()) : hay.contains(t.lowercased()) }
      }
    }
    for (k, field, before) in [("startedBefore", "startTime", true), ("startedAfter", "startTime", false), ("endedBefore", "endTime", true), ("endedAfter", "endTime", false)] {
      guard let limit = q[k].string ?? q[k].double.map({ Self.date($0) }) else { continue }
      out = out.filter { d in guard let t = d[field].string else { return false }; return before ? t < limit : t > limit }
    }
    if let g = q["totalBytesGreater"].int { out = out.filter { ($0["totalBytes"].int ?? 0) > g } }
    if let l = q["totalBytesLess"].int { out = out.filter { ($0["totalBytes"].int ?? 0) < l } }
    if let b = q["bytesReceived"].int { out = out.filter { $0["bytesReceived"].int == b } }
    let order = q["orderBy"].array?.compactMap(\.string) ?? ["-startTime"]
    out.sort { x, y in
      for o in order {
        let desc = o.hasPrefix("-"), k = desc ? String(o.dropFirst()) : o
        let a = ValueJSON.string(x[k]), b = ValueJSON.string(y[k])
        if let ai = x[k].int, let bi = y[k].int, ai != bi { return desc ? ai > bi : ai < bi }
        if a != b { return desc ? a > b : a < b }
      }
      return false
    }
    let limit = Int(q["limit"].int ?? 1000)
    return limit > 0 ? Array(out.prefix(limit)) : out
  }

  // MARK: Events

  /// Item snapshots for diffing.
  func snapshot() -> [Int64: Value] {
    var out: [Int64: Value] = [:]
    for d in items() { let i = item(d); if let n = i["id"].int { out[n] = i } }
    return out
  }

  /// `onCreated`, `onChanged` (Chrome's delta: only fields that changed, never bytesReceived) and
  /// `onErased` for the change from `old` to `new`.
  static func diff(_ old: [Int64: Value], _ new: [Int64: Value]) -> [(String, [Value])] {
    var out: [(String, [Value])] = []
    for n in new.keys.sorted() {
      let d = new[n]!
      guard let o = old[n] else { out.append(("downloads.onCreated", [d])); continue }
      var delta: Value = ["id": .int(n)]
      for k in ["state", "paused", "error", "filename", "exists", "endTime", "totalBytes", "fileSize", "canResume", "url", "finalUrl", "mime", "danger"] where o[k] != d[k] {
        delta = delta.with(k, ["previous": o[k], "current": d[k]])
      }
      if (delta.object?.count ?? 0) > 1 { out.append(("downloads.onChanged", [delta])) }
    }
    for n in old.keys.sorted() where new[n] == nil { out.append(("downloads.onErased", [.int(n)])) }
    return out
  }
}
