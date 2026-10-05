import AppKit
import CordisValue
import DenTestSupport
import Foundation
import LocalAuthentication
import SQLite3
import Testing

@testable import DenHost

/// The `files` host service (read-only local files for importers, gated by `files:` permissions)
/// and `vault.importFile` (a password CSV into the vault, after Touch ID).
@MainActor
@Suite(.serialized, .watchdog)
struct FilesServiceTests {
  final class FakeAuth: VaultAuth {
    var approve = true
    var asked: [String] = []
    func authenticate(reason: String, _ done: @escaping @MainActor (Bool, LAContext?) -> Void) {
      asked.append(reason)
      let ok = approve
      DispatchQueue.main.async { done(ok, nil) }
    }
  }

  /// A runtime whose `~` is a fresh temp folder, with `Library/Data` granted to plugin `imp`.
  @MainActor final class Env {
    let rt: DenRuntime
    let home: URL
    var results: [Value] = []
    init() {
      _ = NSApplication.shared
      let base = FileManager.default.temporaryDirectory.appendingPathComponent("den-files-\(UUID())")
      home = base.appendingPathComponent("home")
      try? FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Data/sub"), withIntermediateDirectories: true)
      try? FileManager.default.createDirectory(at: home.appendingPathComponent("Secret"), withIntermediateDirectories: true)
      rt = DenRuntime(storageRoot: base.appendingPathComponent("storage"))
      rt.files.home = home
      rt.permissions.grant("imp", ["files:~/Library/Data"])
      _ = rt.host.on("files.result") { [unowned self] v in self.results.append(v) }
    }
    func url(_ rel: String) -> URL { home.appendingPathComponent(rel) }
    func write(_ rel: String, _ data: Data) { try? data.write(to: url(rel)) }
    func call(_ m: String, _ a: Value) -> Value { rt.call("files", m, a) }
    /// Starts an async call and waits for its `files.result`.
    func result(_ m: String, _ a: Value) async -> Value? {
      let r = call(m, a)
      guard let req = r["request"].string else { return r }
      _ = await Wait.until("files.result \(req)", seconds: 10) { self.results.contains { $0["request"].string == req } }
      return results.first { $0["request"].string == req }
    }
  }

  // MARK: - Permissions

  @Test func permissionParsing() {
    #expect(Permissions.parse("files:~/Library/Safari")! == ("files", "~/Library/Safari"))
    #expect(Permissions.parse("files:/Users/X/Lib")! == ("files", "/Users/X/Lib"))  // case kept
    #expect(Permissions.parse("files:relative") == nil)
    #expect(Permissions.parse("files:~/a/../b") == nil)
    let p = Permissions()
    p.grant("x", ["files:~/Library/Data"])
    #expect(!p.allowsNet("x", host: "library"))  // a files grant is no net grant
  }

  @Test func refusesPathsOutsideTheGrants() async {
    let e = Env()
    e.write("Secret/a.txt", Data("no".utf8))
    e.write("Library/Data/a.txt", Data("yes".utf8))
    for path in ["~/Secret/a.txt", "~/Library/Data/../../Secret/a.txt", "~/Library/DataX/a.txt", "/etc/hosts", "Library/Data/a.txt"] {
      #expect(e.call("read", ["plugin": "imp", "path": .string(path), "as": "text"])["error"] == "files: not permitted", "\(path)")
    }
    #expect(e.call("read", ["plugin": "other", "path": "~/Library/Data/a.txt", "as": "text"])["error"] == "files: not permitted")
    // A symlink inside the grant that points outside it is refused too.
    try? FileManager.default.createSymbolicLink(at: e.url("Library/Data/link"), withDestinationURL: e.url("Secret"))
    #expect(e.call("read", ["plugin": "imp", "path": "~/Library/Data/link/a.txt", "as": "text"])["error"] == "files: not permitted")
    #expect(e.call("stat", ["plugin": "imp", "paths": ["~/Secret/a.txt"]])[0]["error"] == "not permitted")
    let ok = await e.result("read", ["plugin": "imp", "path": "~/Library/Data/a.txt", "as": "text"])
    #expect(ok?["value"] == "yes")
  }

  // MARK: - stat, list, read

  @Test func statAndList() {
    let e = Env()
    e.write("Library/Data/f.json", Data("{}".utf8))
    let s = e.call("stat", ["plugin": "imp", "paths": ["~/Library/Data/f.json", "~/Library/Data/sub", "~/Library/Data/missing"]])
    #expect(s[0]["path"] == "~/Library/Data/f.json")
    #expect(s[0]["exists"] == true && s[0]["dir"] == false && s[0]["readable"] == true && s[0]["denied"] == false && s[0]["size"] == 2)
    #expect((s[0]["modified"].int ?? 0) > 1_600_000_000_000)
    #expect(s[1]["dir"] == true && s[1]["readable"] == true)
    #expect(s[2]["exists"] == false && s[2]["readable"] == false)
    let l = e.call("list", ["plugin": "imp", "path": "~/Library/Data"])
    #expect(l.array?.map { $0.str("name") } == ["f.json", "sub"])
    #expect(l[1]["dir"] == true)
    #expect(e.call("list", ["plugin": "imp", "path": "~/Library/Data/missing"]).isError)
  }

  @Test func readsJSONPlistTextAndBytes() async throws {
    let e = Env()
    e.write("Library/Data/a.json", Data(#"{"roots": {"bar": [1, "x", true]}}"#.utf8))
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let plist: [String: Any] = ["Title": "Bar", "Data": Data([1, 2, 3]), "When": date, "Children": [["URLString": "https://a.test/"]]]
    e.write("Library/Data/x.plist", try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
    e.write("Library/Data/b.plist", try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0))
    e.write("Library/Data/t.txt", Data("héllo".utf8))
    e.write("Library/Data/b.bin", Data([0, 255, 7]))

    let j = await e.result("read", ["plugin": "imp", "path": "~/Library/Data/a.json", "as": "json"])
    #expect(j?["ok"] == true && j?["value"]["roots"]["bar"] == [1, "x", true])
    for name in ["x.plist", "b.plist"] {
      let p = await e.result("read", ["plugin": "imp", "path": .string("~/Library/Data/" + name), "as": "plist"])
      #expect(p?["value"]["Title"] == "Bar", "\(name)")
      #expect(p?["value"]["Data"] == .bytes([1, 2, 3]), "\(name)")
      #expect(p?["value"]["When"].double == 1_700_000_000_000, "\(name)")
      #expect(p?["value"]["Children"][0]["URLString"] == "https://a.test/", "\(name)")
    }
    let t = await e.result("read", ["plugin": "imp", "path": "~/Library/Data/t.txt", "as": "text"])
    #expect(t?["value"] == "héllo")
    let b = await e.result("read", ["plugin": "imp", "path": "~/Library/Data/b.bin", "as": "bytes"])
    #expect(b?["value"] == .bytes([0, 255, 7]) && b?["bytes"] == 3)
    let big = await e.result("read", ["plugin": "imp", "path": "~/Library/Data/b.bin", "as": "bytes", "maxBytes": 2])
    #expect(big?["ok"] == false && big?["error"] == "too large")
    let bad = await e.result("read", ["plugin": "imp", "path": "~/Library/Data/t.txt", "as": "json"])
    #expect(bad?["ok"] == false)
  }

  // MARK: - sqlite

  static func exec(_ db: OpaquePointer?, _ sql: String) {
    #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "\(sql)")
  }

  @Test func sqliteReadsACopyIncludingTheWAL() async {
    let e = Env()
    let path = e.url("Library/Data/History").path
    var db: OpaquePointer?
    #expect(sqlite3_open(path, &db) == SQLITE_OK)
    Self.exec(db, "PRAGMA journal_mode=WAL")
    Self.exec(db, "PRAGMA wal_autocheckpoint=0")
    Self.exec(db, "CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, score REAL, icon BLOB)")
    Self.exec(db, "INSERT INTO urls (url, title, visit_count, score, icon) VALUES ('https://a.test/', 'A', 3, 1.5, x'0102'), ('https://b.test/', NULL, 1, 0.5, NULL)")
    // The connection stays open (like a running browser): the rows are only in History-wal.
    #expect(FileManager.default.fileExists(atPath: path + "-wal"))
    defer { sqlite3_close(db) }

    let r = await e.result("sqlite", ["plugin": "imp", "path": "~/Library/Data/History", "sql": "SELECT url, title, visit_count, score, icon FROM urls ORDER BY id"])
    #expect(r?["ok"] == true)
    #expect(r?["columns"] == ["url", "title", "visit_count", "score", "icon"])
    #expect(r?["rows"][0] == ["https://a.test/", "A", 3, 1.5, .bytes([1, 2])])
    #expect(r?["rows"][1][1] == .null)
    #expect(r?["truncated"] == false)

    let one = await e.result("sqlite", ["plugin": "imp", "path": "~/Library/Data/History", "sql": "SELECT url FROM urls", "maxRows": 1])
    #expect(one?["rows"].array?.count == 1 && one?["truncated"] == true)
    let write = await e.result("sqlite", ["plugin": "imp", "path": "~/Library/Data/History", "sql": "DELETE FROM urls"])
    #expect(write?["ok"] == false && write?["error"] == "files: only read-only statements")
    // The original is untouched, and den left no copy behind in it.
    var stmt: OpaquePointer?
    sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM urls", -1, &stmt, nil)
    sqlite3_step(stmt)
    #expect(sqlite3_column_int(stmt, 0) == 2)
    sqlite3_finalize(stmt)
    let bad = await e.result("sqlite", ["plugin": "imp", "path": "~/Library/Data/History", "sql": "SELECT nope FROM urls"])
    #expect(bad?["ok"] == false)
  }

  // MARK: - vault.importFile

  static let columns: Value = [
    "origin": ["url", "login_uri", "website"], "username": ["username", "login_username", "login"], "password": ["password", "login_password"],
  ]

  func importCSV(_ csv: String, store: MemoryVaultStore = MemoryVaultStore(), approve: Bool = true, cancel: Bool = false) async -> (Value?, MemoryVaultStore, FakeAuth) {
    _ = NSApplication.shared
    let rt = DenRuntime(storageRoot: FileManager.default.temporaryDirectory.appendingPathComponent("den-vimp-\(UUID())"))
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("den-pw-\(UUID()).csv")
    try? Data(csv.utf8).write(to: file)
    let auth = FakeAuth()
    auth.approve = approve
    rt.vault.store = store
    rt.vault.auth = auth
    rt.vault.pickFile = { done in DispatchQueue.main.async { done(cancel ? nil : file) } }
    final class Box { var results: [Value] = [] }
    let box = Box()
    _ = rt.host.on("vault.result") { box.results.append($0) }
    let req = rt.call("vault", "importFile", ["columns": Self.columns])["request"].string ?? ""
    _ = await Wait.until("vault.result", seconds: 10) { box.results.contains { $0["request"].string == req } }
    let r = box.results.first { $0["request"].string == req }
    // Never a password in what plugins see.
    if let r { #expect(!ValueJSON.string(r).contains("hunter2") && !ValueJSON.string(r).contains("s3cret")) }
    #expect(FileManager.default.fileExists(atPath: file.path))  // only read, never deleted
    return (r, store, auth)
  }

  func password(_ store: MemoryVaultStore, _ origin: String, _ user: String) -> String? {
    store.accounts().first { $0.origin == origin && $0.username == user }.flatMap { store.password(for: $0, context: nil) }.map { String(decoding: $0, as: UTF8.self) }
  }

  @Test func importsChromeCSV() async {
    let (r, store, auth) = await importCSV("name,url,username,password,note\r\nGitHub,https://github.com/login,me@x.test,hunter2,\r\nExample,https://example.com,bob,\"s3cret,with \"\"quotes\"\"\",\"multi\nline note\"\r\nNoPass,https://nopass.test,u,,\r\nApp,android://abc@com.app/,u,hunter2,\r\n")
    #expect(r?["ok"] == true && r?["added"] == 2 && r?["existing"] == 0 && r?["skipped"] == 2)
    #expect(auth.asked == ["import passwords"])
    #expect(password(store, "https://github.com", "me@x.test") == "hunter2")
    #expect(password(store, "https://example.com", "bob") == "s3cret,with \"quotes\"")
  }

  @Test func importsBitwardenAndSafariHeadersWithABOM() async {
    let (bw, s1, _) = await importCSV("\u{FEFF}folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\nWork,,login,Site,,,0,https://bw.test/x,amy,hunter2,\n")
    #expect(bw?["added"] == 1 && password(s1, "https://bw.test", "amy") == "hunter2")
    let (sf, s2, _) = await importCSV("Title,URL,Username,Password,Notes,OTPAuth\nSite,sf.test,zoe,s3cret,,\n")
    #expect(sf?["added"] == 1 && password(s2, "https://sf.test", "zoe") == "s3cret")
  }

  @Test func existingLoginsAreKeptAndCancelIsReported() async {
    let store = MemoryVaultStore()
    _ = store.save(origin: "https://github.com", username: "me", password: Data("old".utf8))
    let (r, _, _) = await importCSV("url,username,password\nhttps://github.com,me,hunter2\nhttps://github.com,me,hunter2\n", store: store)
    #expect(r?["added"] == 0 && r?["existing"] == 2)
    #expect(password(store, "https://github.com", "me") == "old")
    let (c, s2, auth) = await importCSV("url,username,password\nhttps://a.test,u,hunter2\n", cancel: true)
    #expect(c?["ok"] == false && c?["error"] == "cancelled" && s2.accounts().isEmpty && auth.asked.isEmpty)
    let (d, s3, _) = await importCSV("url,username,password\nhttps://a.test,u,hunter2\n", approve: false)
    #expect(d?["ok"] == false && d?["error"] == "cancelled" && s3.accounts().isEmpty)
    let (n, _, _) = await importCSV("a,b\n1,2\n")
    #expect(n?["error"] == "no columns")
  }

  @Test func csvParser() {
    #expect(CSV.parse("a,b\r\n\"x,y\",\"he said \"\"hi\"\"\"\n\n\"l1\nl2\",z") == [["a", "b"], ["x,y", "he said \"hi\""], ["l1\nl2", "z"]])
    #expect(CSV.parse("\u{FEFF}h\n1") == [["h"], ["1"]])
    #expect(CSV.parse("a,,c\n") == [["a", "", "c"]])
  }
}
