import AppKit
import CordisValue
import Foundation
import SQLite3

/// `files` service: read-only access to local files a plugin declared (`files:<path>` in its
/// permissions.json), for importers reading other browsers' data. Generic: JSON, property lists,
/// text, bytes and SQLite queries; what the data means belongs to the plugin.
///
///   stat {plugin, paths}                              -> [{path, exists, dir, readable, denied, size, modified}]
///   list {plugin, path}                               -> [{name, dir, size, modified}]
///   read {plugin, path, as: json|plist|text|bytes, maxBytes?, request?}  -> {request}, then files.result
///   sqlite {plugin, path, sql, maxRows?, request?}    -> {request}, then files.result {columns, rows, truncated}
///   openFullDiskAccess                                -> ok. System Settings ▸ Privacy & Security ▸ Full Disk Access
///   home                                              -> {home}
///
/// Paths are `~/…` (against `home`: the real home, or a fixture home in tests and scenarios) or
/// absolute. Nothing is written, moved or deleted except den's own temporary copy of a database.
/// Cost: nothing runs until a call; reads and queries run off the main thread.
@MainActor
public final class FilesService: HostService {
  public let name = "files"
  let host: ServiceHost
  let permissions: Permissions
  /// What `~` means. Tests and scenarios point it at a fixture home.
  public var home: URL = FileManager.default.homeDirectoryForCurrentUser
  /// Opens System Settings (`openFullDiskAccess`); tests and scenarios record the URL instead.
  public var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
  var nextRequest = 1
  static let queue = DispatchQueue(label: "den.files", qos: .userInitiated)
  static let defaultMaxBytes = 64 << 20
  static let defaultMaxRows = 100_000

  public init(host: ServiceHost, permissions: Permissions) {
    self.host = host
    self.permissions = permissions
  }

  public func handle(method: String, args: Value) -> Value {
    let plugin = args.str("plugin")
    switch method {
    case "home":
      return ["home": .string(home.path)]
    case "openFullDiskAccess":
      if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { openURL(u) }
      return .ok
    case "stat":
      return .array(args.list("paths").map { p -> Value in
        let path = p.string ?? ""
        guard let url = resolve(plugin, path) else { return ["path": .string(path), "error": "not permitted"] }
        return Self.stat(url).with("path", .string(path))
      })
    case "list":
      let path = args.str("path")
      guard let url = resolve(plugin, path) else { return .error("files: not permitted") }
      return Self.list(url)
    case "read":
      let path = args.str("path"), kind = args.str("as", "bytes")
      guard ["json", "plist", "text", "bytes"].contains(kind) else { return .error("files: bad as '\(kind)'") }
      guard let url = resolve(plugin, path) else { return .error("files: not permitted") }
      let request = requestId(args)
      let max = Int(args["maxBytes"].int ?? Int64(Self.defaultMaxBytes))
      Self.queue.async {
        let v = Self.read(url, as: kind, maxBytes: max).with("request", .string(request))
        DispatchQueue.main.async { MainActor.assumeIsolated { self.host.emit("files.result", v) } }
      }
      return ["request": .string(request)]
    case "sqlite":
      let path = args.str("path"), sql = args.str("sql")
      guard !sql.isEmpty else { return .error("files: sqlite needs sql") }
      guard let url = resolve(plugin, path) else { return .error("files: not permitted") }
      let request = requestId(args)
      let maxRows = Int(args["maxRows"].int ?? Int64(Self.defaultMaxRows))
      Self.queue.async {
        let v = Self.query(url, sql: sql, maxRows: maxRows).with("request", .string(request))
        DispatchQueue.main.async { MainActor.assumeIsolated { self.host.emit("files.result", v) } }
      }
      return ["request": .string(request)]
    default:
      return .error("files: unknown method '\(method)'")
    }
  }

  func requestId(_ args: Value) -> String {
    let r = args.str("request")
    if !r.isEmpty { return r }
    defer { nextRequest += 1 }
    return "files-\(nextRequest)"
  }

  /// The file URL for `path` when `plugin` may read it.
  func resolve(_ plugin: String, _ path: String) -> URL? {
    guard permissions.allowsFile(plugin, path: path, home: home), let p = Permissions.resolve(path, home: home) else { return nil }
    return URL(fileURLWithPath: p)
  }

  // MARK: - Work (any thread)

  nonisolated static func ms(_ d: Date?) -> Value { d.map { .int(Int64($0.timeIntervalSince1970 * 1000)) } ?? .null }

  nonisolated static func stat(_ url: URL) -> Value {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
      return ["exists": false, "dir": false, "readable": false, "denied": false, "size": 0, "modified": .null]
    }
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    var readable = false, denied = false
    if isDir.boolValue {
      if let d = opendir(url.path) { readable = true; closedir(d) } else { denied = errno == EPERM || errno == EACCES }
    } else {
      let fd = open(url.path, O_RDONLY)
      if fd >= 0 { readable = true; close(fd) } else { denied = errno == EPERM || errno == EACCES }
    }
    return ["exists": true, "dir": .bool(isDir.boolValue), "readable": .bool(readable), "denied": .bool(denied),
            "size": .int((attrs?[.size] as? NSNumber)?.int64Value ?? 0), "modified": ms(attrs?[.modificationDate] as? Date)]
  }

  nonisolated static func list(_ url: URL) -> Value {
    guard let d = opendir(url.path) else {
      return ["error": .string("files: can't read \(url.lastPathComponent)"), "denied": .bool(errno == EPERM || errno == EACCES)]
    }
    closedir(d)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    return .array(names.sorted().map { n -> Value in
      let u = url.appendingPathComponent(n)
      var isDir: ObjCBool = false
      FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
      let attrs = try? FileManager.default.attributesOfItem(atPath: u.path)
      return ["name": .string(n), "dir": .bool(isDir.boolValue), "size": .int((attrs?[.size] as? NSNumber)?.int64Value ?? 0),
              "modified": ms(attrs?[.modificationDate] as? Date)]
    })
  }

  nonisolated static func fail(_ message: String, bytes: Int64 = 0) -> Value { ["ok": false, "error": .string(message), "bytes": .int(bytes)] }

  nonisolated static func read(_ url: URL, as kind: String, maxBytes: Int) -> Value {
    let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? -1
    guard size >= 0 else { return fail("files: no such file") }
    guard size <= Int64(maxBytes) else { return fail("too large", bytes: size) }
    let data: Data
    do { data = try Data(contentsOf: url) } catch {
      let ns = error as NSError
      let denied = (ns.underlyingErrors.first as NSError?).map { $0.code == Int(EPERM) || $0.code == Int(EACCES) } ?? false
      return fail(denied ? "denied" : "files: can't read \(url.lastPathComponent)", bytes: size)
    }
    var value: Value
    switch kind {
    case "json":
      guard let v = ValueJSON.parse(data) else { return fail("files: not JSON", bytes: size) }
      value = v
    case "plist":
      guard let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return fail("files: not a property list", bytes: size) }
      value = plistValue(obj)
    case "text":
      value = .string(String(decoding: data, as: UTF8.self))
    default:
      value = .bytes([UInt8](data))
    }
    return ["ok": true, "value": value, "bytes": .int(size)]
  }

  /// A property list as a Value: dictionaries keep sorted keys, `Data` becomes bytes, dates ms since 1970.
  nonisolated static func plistValue(_ any: Any) -> Value {
    switch any {
    case let d as Data: return .bytes([UInt8](d))
    case let date as Date: return .double(date.timeIntervalSince1970 * 1000)
    case let a as [Any]: return .array(a.map { plistValue($0) })
    case let d as [String: Any]: return .object(d.keys.sorted().map { ($0, plistValue(d[$0]!)) })
    default: return ValueJSON.value(any)
    }
  }

  /// Copies the database (and its -wal/-shm, which hold recent writes) to a temporary folder,
  /// opens the copy read-only and runs one read-only statement.
  nonisolated static func query(_ url: URL, sql: String, maxRows: Int) -> Value {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else { return fail("files: no such file") }
    let tmp = fm.temporaryDirectory.appendingPathComponent("den-files-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: tmp) }
    let copy = tmp.appendingPathComponent(url.lastPathComponent)
    do {
      try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
      try fm.copyItem(at: url, to: copy)
      for suffix in ["-wal", "-shm"] {
        let side = URL(fileURLWithPath: url.path + suffix)
        if fm.fileExists(atPath: side.path) { try fm.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix)) }
      }
    } catch {
      let code = ((error as NSError).underlyingErrors.first as NSError?)?.code ?? 0
      return fail(code == Int(EPERM) || code == Int(EACCES) ? "denied" : "files: can't copy \(url.lastPathComponent)")
    }
    var db: OpaquePointer?
    // Read-write on the copy only so SQLite can replay the copied WAL; the statement must be read-only.
    guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
      sqlite3_close(db)
      return fail("files: not a database")
    }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
      return fail("files: " + String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_stmt_readonly(stmt) != 0 else { return fail("files: only read-only statements") }
    let n = sqlite3_column_count(stmt)
    let columns: [Value] = (0..<n).map { .string(String(cString: sqlite3_column_name(stmt, $0))) }
    var rows: [Value] = []
    var truncated = false
    while true {
      let rc = sqlite3_step(stmt)
      if rc == SQLITE_DONE { break }
      guard rc == SQLITE_ROW else { return fail("files: " + String(cString: sqlite3_errmsg(db))) }
      if rows.count >= maxRows { truncated = true; break }
      var row: [Value] = []
      row.reserveCapacity(Int(n))
      for i in 0..<n {
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_INTEGER: row.append(.int(sqlite3_column_int64(stmt, i)))
        case SQLITE_FLOAT: row.append(.double(sqlite3_column_double(stmt, i)))
        case SQLITE_TEXT: row.append(.string(String(cString: sqlite3_column_text(stmt, i))))
        case SQLITE_BLOB:
          let len = Int(sqlite3_column_bytes(stmt, i))
          if let p = sqlite3_column_blob(stmt, i), len > 0 {
            row.append(.bytes([UInt8](UnsafeRawBufferPointer(start: p, count: len))))
          } else { row.append(.bytes([])) }
        default: row.append(.null)
        }
      }
      rows.append(.array(row))
    }
    return ["ok": true, "columns": .array(columns), "rows": .array(rows), "truncated": .bool(truncated)]
  }
}
