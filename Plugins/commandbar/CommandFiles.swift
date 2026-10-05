// Local files in the command bar: a typed or pasted path (`/Users/me/report.html`, `~/Downloads/a.pdf`,
// `file:///…`, Terminal-escaped or quoted, or a path dropped from Finder) opens the file in a tab
// instead of searching the web for it; a folder shows in Finder. While a path is typed, the bar lists
// the matching files and folders of its folder (Finder-style completion; Tab or Enter on a folder
// goes into it). The host checks the file system (`app.fileInfo`, `app.completePath`, `app.openPath`);
// a path that doesn't exist stays a search. Paths are never sent to the web suggestion service.

#if !hasFeature(Embedded)
  import CordisValue
#endif

extension CommandBarCore {
  /// Shaped like a local path (it may not exist): `/…` (not `//`), `~…`, `file://…`, possibly quoted.
  static func pathLike(_ q: String) -> Bool {
    var b = Array(q.utf8)
    if b.count >= 2, (b[0] == 39 || b[0] == 34), b[b.count - 1] == b[0] { b = Array(b[1..<(b.count - 1)]) }
    guard let first = b.first else { return false }
    if first == 126 { return true }  // ~
    if first == 47 { return b.count < 2 || b[1] != 47 }  // "/", not "//"
    return Text.hasPrefix(Text.lower(String(decoding: b, as: UTF8.self)), "file://")
  }

  /// The existing file or folder `q` names (`app.fileInfo`), or nil. Asked once per distinct query.
  func localFile(_ q: String) -> Value? {
    guard Self.pathLike(q) else { return nil }
    if let c = fileCache, c.0 == q { return c.1 }
    let r = env.call("app", "fileInfo", ["path": .string(q)])
    // Not `exists ? r : nil`: Value is nil-literal expressible, so that would be `.some(.null)`.
    var v: Value? = Optional.none
    if r.b("exists") { v = r }
    fileCache = (q, v)
    return v
  }

  /// The first row for an existing path: open the file, or show the folder in Finder.
  func fileRow(_ q: String, _ f: Value) -> Row {
    let path = f.s("path")
    if f.b("folder") {
      return Row(id: "go", icon: "file:" + path, title: q, subtitle: "— Show in Finder", act: .folder(path))
    }
    let u = f.s("url")
    return Row(id: "go", icon: "file:" + path, title: q, subtitle: mode == "edit" ? "— Go to File" : "— Open File", act: .url(u), key: "url:" + URLs.normalize(u))
  }

  /// Files and folders in the typed path's folder whose names start with what's typed
  /// (`app.completePath`). Enter on a file opens it; on a folder, or Tab on either, it goes into
  /// the field.
  func fileRows(_ q: String, limit: Int) -> [Row] {
    guard Self.pathLike(q), limit > 0 else { return [] }
    let r = env.call("app", "completePath", ["path": .string(q), "limit": .int(Int64(limit))])
    return r.a("items").map { it in
      let path = it.s("path"), folder = it.b("folder")
      // Completion keeps the typed form: `~/…` stays `~/…`.
      let text = (Text.hasPrefix(q, "~") || Text.hasPrefix(q, "'~") || Text.hasPrefix(q, "\"~") ? it.s("display") : path) + (folder ? "/" : "")
      var row = Row(id: "file:" + path, icon: "file:" + path, title: it.s("name") + (folder ? "/" : ""), subtitle: "— " + it.s("display"),
                    act: folder ? .complete(text) : .url(it.s("url")), key: folder ? "" : "url:" + URLs.normalize(it.s("url")))
      row.completion = text
      return row
    }
  }

  /// Tab on a file row: its path goes into the field (a folder's with a trailing slash).
  func completeSelected() -> Bool {
    guard let r = rows.first(where: { $0.id == selected }), !r.completion.isEmpty else { return false }
    setScope(scope, query: r.completion)
    return true
  }
}
