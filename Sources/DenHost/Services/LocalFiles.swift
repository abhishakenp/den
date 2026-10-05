import AppKit
import CordisValue

/// Local files typed or pasted where an address goes (the command bar, Paste and Go, `webviews`):
/// `/Users/me/report.html`, `~/Downloads/a.pdf`, `file:///…` (spaces allowed), a Terminal-escaped
/// path (`My\ File.pdf`) or a quoted one (`'/tmp/a b.html'`). Only a path that exists counts:
/// anything else stays a search.
enum LocalFiles {
  /// Whether `s` is shaped like a local path (it may not exist).
  nonisolated static func looksLikePath(_ s: String) -> Bool {
    let t = unquote(s.trimmingCharacters(in: .whitespacesAndNewlines))
    return t.hasPrefix("/") && !t.hasPrefix("//") || t.hasPrefix("~") || t.lowercased().hasPrefix("file://")
  }

  /// The file URL `s` names, whether or not it exists; nil when it isn't path-shaped.
  nonisolated static func url(_ s: String) -> URL? {
    var t = unquote(s.trimmingCharacters(in: .whitespacesAndNewlines))
    if t.lowercased().hasPrefix("file://") {
      t = "file://" + t.dropFirst(7)
      let u = URL(string: t) ?? t.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap { URL(string: $0) }
      guard let u, u.isFileURL, !u.path.isEmpty else { return nil }
      return URL(fileURLWithPath: u.path)
    }
    guard looksLikePath(t) else { return nil }
    let path = (t as NSString).expandingTildeInPath
    guard path.hasPrefix("/") else { return nil }  // "~nobody/x": no such user
    // A Terminal-escaped path (`My\ File.pdf`), unless the file name really has backslashes.
    if path.contains("\\"), !FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: unescape(path)) }
    return URL(fileURLWithPath: path)
  }

  /// The existing file or folder `s` names: its URL and whether it opens as a folder (a package
  /// such as an `.app` is a file here).
  nonisolated static func existing(_ s: String) -> (url: URL, folder: Bool)? {
    guard let u = url(s) else { return nil }
    var dir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: u.path, isDirectory: &dir) else { return nil }
    return (u, dir.boolValue && !isPackage(u))
  }

  /// What a web view may read for a local page: the home folder for a file inside it (so
  /// `../assets/app.css` loads, as in Safari), else the file's folder.
  nonisolated static func readAccess(for u: URL) -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    let path = u.standardizedFileURL.path
    if path.hasPrefix(home + "/") { return URL(fileURLWithPath: home, isDirectory: true) }
    return u.deletingLastPathComponent()
  }

  /// Finder-style completion: entries of the typed path's folder whose name starts with its last
  /// component (case-insensitive), folders and files in Finder's order; hidden ones only when the
  /// typed name starts with a dot. The typed path itself is left out (the bar's first row opens it).
  nonisolated static func complete(_ s: String, limit: Int = 6) -> [(url: URL, folder: Bool)] {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard limit > 0, let u = url(t) else { return [] }
    let typedFolder = t.hasSuffix("/") || t.hasSuffix("/'") || t.hasSuffix("/\"")
    let dir = typedFolder ? u : u.deletingLastPathComponent()
    let prefix = typedFolder ? "" : u.lastPathComponent.lowercased()
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
    let typed = u.standardizedFileURL.path
    let matches = names.filter { n in
      (prefix.hasPrefix(".") || !n.hasPrefix(".")) && n.lowercased().hasPrefix(prefix) && dir.appendingPathComponent(n).standardizedFileURL.path != typed
    }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    return matches.prefix(limit).compactMap { existing(dir.appendingPathComponent($0).path) }
  }

  /// Shows a folder in Finder (a package is selected in its folder instead of opened). Tests
  /// replace it, so they never open Finder.
  @MainActor static var reveal: (URL) -> Void = { u in
    if isPackage(u) { NSWorkspace.shared.activateFileViewerSelecting([u]) } else { NSWorkspace.shared.open(u) }
  }

  nonisolated static func isPackage(_ u: URL) -> Bool { (try? u.resolvingSymlinksInPath().resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false }

  /// `~/x` for a path in the home folder.
  nonisolated static func display(_ u: URL) -> String { (u.path as NSString).abbreviatingWithTildeInPath }

  nonisolated static func unquote(_ s: String) -> String {
    for q in ["'", "\""] where s.count >= 2 && s.hasPrefix(q) && s.hasSuffix(q) { return String(s.dropFirst().dropLast()) }
    return s
  }

  nonisolated static func unescape(_ s: String) -> String {
    var out = ""
    var escaped = false
    for c in s {
      if c == "\\" && !escaped {
        escaped = true
        continue
      }
      escaped = false
      out.append(c)
    }
    return out
  }

  /// `app.fileInfo`, `app.completePath`, `app.openPath` (docs/host-api.md#app).
  @MainActor static func handle(_ method: String, _ args: Value) -> Value {
    let p = args.str("path")
    switch method {
    case "fileInfo":
      guard let f = existing(p) else { return ["exists": false] }
      return ["exists": true, "folder": .bool(f.folder), "path": .string(f.url.path), "url": .string(f.url.absoluteString), "display": .string(display(f.url))]
    case "completePath":
      let limit = Int(args.num("limit", 6))
      return ["items": .array(complete(p, limit: limit).map { f in
        ["path": .string(f.url.path), "url": .string(f.url.absoluteString), "name": .string(f.url.lastPathComponent), "folder": .bool(f.folder),
         "display": .string(display(f.url))]
      })]
    case "openPath":
      guard let f = existing(p) else { return .error("app: no file at '\(p)'") }
      reveal(f.url)  // a folder or package; a file opens in a tab, not here
      return .ok
    default:
      return .error("app: unknown method '\(method)'")
    }
  }
}
