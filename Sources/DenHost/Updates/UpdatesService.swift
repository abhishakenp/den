import CordisValue
import CryptoKit
import Foundation

/// `updates` service: the native half of updating. It fetches, verifies and places files, and
/// bridges Sparkle. Every decision (channel, when to check, what to install, when to relaunch,
/// every string the user sees) belongs to the `updates` plugin.
///
/// Methods:
///   info            -> {version, build, commit, hostAPI, builtAt, crashed: [id], sparkle: bool, publicKey: bool}
///   state           -> ~/.den/updates/state.json (the follow-main updater's state) or null
///   fetch {url, etag?, json?} -> {pending}. Conditional GET; emits updates.fetched
///                      {url, status, etag, body (string, only on 200), value (parsed, with json), bytes}
///   plugins         -> [{id, file, layer: bundle|user|managed|home|source|dev, sha256}] for loaded plugins
///   installPlugin {id, url, sha256, signature, version, hostAPI, permissions?} -> {pending}. Downloads, checks the
///                      sha256 and the EdDSA signature (Info.plist SUPublicEDKey), then places
///                      ~/.den/updates/plugins/<id>.dylib (+ <id>.json) atomically, keeping the
///                      previous build as <id>.prev.dylib, and loads it. Emits updates.pluginInstalled
///                      {id, ok, error?, active}. Nothing unverified is ever written there.
///   rollbackPlugin {id} -> {ok, restored: bool}: puts <id>.prev back, or removes the managed copy
///   kickUpdater     -> {ok}: runs the follow-main LaunchAgent now (scripts/updater.sh)
///   sparkleConfigure {channel} / sparkleCheck {userInitiated?} / sparkleReply {choice: install|later|skip}
/// Events: updates.stateChanged {state}, updates.fetched, updates.pluginInstalled,
///         updates.sparkle {phase: checking|none|found|downloading|ready|installing|error, version?, error?}
@MainActor
public final class UpdatesService: HostService {
  public let name = "updates"
  let host: ServiceHost
  public let home: DenHome
  public let build: DenBuild
  /// Base64 Ed25519 public key (SUPublicEDKey) plugin files must be signed with.
  public let publicKey: String?
  /// Plugins cordis refused at launch because their build crashed den.
  public var crashed: [String] = []
  /// Loaded plugins: id -> file path (set by the app from the PluginHost).
  public var loadedFiles: () -> [(String, String)] = { [] }
  /// Re-resolves one plugin file name now (LivePlugins.refresh) and says whether it is active.
  public var activate: (String) -> Bool = { _ in false }
  /// Sparkle, when the app links it.
  public var sparkle: SparkleBridge?
  public var session: URLSession = .shared
  public var updaterLabel = "io.github.abhishakenp.den.updater"

  public init(host: ServiceHost, home: DenHome, build: DenBuild, publicKey: String? = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String) {
    self.host = host
    self.home = home
    self.build = build
    self.publicKey = publicKey
  }

  public func handle(method: String, args: Value) -> Value {
    switch method {
    case "info":
      return ["version": .string(build.version), "build": .int(Int64(build.build)), "commit": .string(build.commit),
              "hostAPI": build.hostAPI.map { .int(Int64($0)) } ?? .null, "builtAt": .string(build.builtAt),
              "crashed": .array(crashed.map { .string($0) }), "sparkle": .bool(sparkle != nil), "publicKey": .bool(publicKey != nil)]
    case "state": return readState()
    case "fetch":
      let url = args.str("url")
      guard let u = URL(string: url), u.scheme == "https" else { return .error("updates: fetch needs an https url") }
      fetch(u, etag: args["etag"].string, json: args.flag("json"))
      return ["pending": true]
    case "plugins": return .array(pluginFiles())
    case "installPlugin":
      let id = args.str("id")
      guard LivePlugins.validID(id), !id.contains("."), let u = URL(string: args.str("url")), u.scheme == "https" else {
        return .error("updates: installPlugin needs an id and an https url")
      }
      install(id: id, url: u, sha256: args.str("sha256").lowercased(), signature: args.str("signature"), meta: args)
      return ["pending": true]
    case "rollbackPlugin": return rollback(args.str("id"))
    case "kickUpdater": return kickUpdater()
    case "sparkleConfigure":
      guard let sparkle else { return .error("updates: Sparkle is not available") }
      sparkle.configure(channel: args.str("channel"))
    case "sparkleCheck":
      guard let sparkle else { return .error("updates: Sparkle is not available") }
      sparkle.check(userInitiated: args.flag("userInitiated"))
    case "sparkleReply":
      guard let sparkle else { return .error("updates: Sparkle is not available") }
      sparkle.reply(args.str("choice"))
    default: return .error("updates: unknown method '\(method)'")
    }
    return .ok
  }

  // MARK: State (follow-main)

  public func readState() -> Value {
    guard let data = try? Data(contentsOf: home.updaterState), let any = try? JSONSerialization.jsonObject(with: data) else { return .null }
    return ConfigService.jsonValue(any) ?? .null
  }

  public func stateChanged() { host.emit("updates.stateChanged", ["state": readState()]) }

  // MARK: Fetch

  func fetch(_ url: URL, etag: String?, json: Bool) {
    var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    if let etag, !etag.isEmpty { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
    req.setValue("den/\(build.version)", forHTTPHeaderField: "User-Agent")
    session.dataTask(with: req) { data, resp, err in
      let http = resp as? HTTPURLResponse
      let status = http?.statusCode ?? 0
      let tag = http?.value(forHTTPHeaderField: "ETag") ?? ""
      let body = status == 200 ? String(data: data ?? Data(), encoding: .utf8) ?? "" : ""
      let payload = data ?? Data()
      let bytes = data?.count ?? 0
      let error = err?.localizedDescription ?? ""
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          var ev: Value = ["url": .string(url.absoluteString), "status": .int(Int64(status)), "etag": .string(tag),
                           "body": .string(json ? "" : body), "bytes": .int(Int64(bytes)), "error": .string(error)]
          if json, status == 200, let any = try? JSONSerialization.jsonObject(with: payload) { ev = ev.with("value", ConfigService.jsonValue(any) ?? .null) }
          self.host.emit("updates.fetched", ev)
        }
      }
    }.resume()
  }

  // MARK: Plugins

  func layer(_ path: String) -> String {
    let dir = (path as NSString).deletingLastPathComponent
    if dir == home.managedPlugins.path || dir == Self.real(home.managedPlugins.path) { return "managed" }
    if dir == home.plugins.path || dir == Self.real(home.plugins.path) { return "home" }
    if dir == home.buildCache.path { return "source" }
    if let b = PluginLoader.bundleDirectory?.path, dir == b { return "bundle" }
    if dir == PluginLoader.userDirectory.path { return "user" }
    return "dev"
  }

  func pluginFiles() -> [Value] {
    loadedFiles().map { id, path in
      let data = (try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)) ?? Data()
      return ["id": .string(id), "file": .string(path), "layer": .string(layer(path)), "sha256": .string(Self.hex(SHA256.hash(data: data)))]
    }
  }

  /// Checks a downloaded plugin: size > 0, sha256, and the EdDSA signature over the file.
  public nonisolated static func verify(_ data: Data, sha256: String, signature: String, publicKey: String?) -> String? {
    guard !data.isEmpty else { return "empty download" }
    guard hex(SHA256.hash(data: data)) == sha256 else { return "sha256 mismatch" }
    guard let publicKey, let keyData = Data(base64Encoded: publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
      return "no public key to verify against"
    }
    guard let sig = Data(base64Encoded: signature), key.isValidSignature(sig, for: data) else { return "bad signature" }
    return nil
  }

  func install(id: String, url: URL, sha256: String, signature: String, meta: Value) {
    let dir = home.managedPlugins
    let key = publicKey
    session.dataTask(with: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)) { data, resp, err in
      let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
      var problem: String? = err?.localizedDescription ?? (status == 200 ? nil : "HTTP \(status)")
      let body = data ?? Data()
      if problem == nil { problem = Self.verify(body, sha256: sha256, signature: signature, publicKey: key) }
      if problem == nil { problem = Self.place(body, id: id, in: dir, meta: meta) }
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          var active = false
          if problem == nil { active = self.activate("\(id).dylib") }
          var ev: Value = ["id": .string(id), "ok": .bool(problem == nil), "active": .bool(active)]
          if let problem { ev = ev.with("error", .string(problem)) }
          self.host.emit("updates.pluginInstalled", ev)
        }
      }
    }.resume()
  }

  /// Writes `<id>.json` then `<id>.dylib` (temp + rename), keeping the old pair as `.prev`.
  nonisolated static func place(_ data: Data, id: String, in dir: URL, meta: Value) -> String? {
    let fm = FileManager.default
    do {
      try fm.createDirectory(at: dir, withIntermediateDirectories: true)
      let dylib = dir.appendingPathComponent("\(id).dylib"), json = dir.appendingPathComponent("\(id).json")
      let prev = dir.appendingPathComponent("\(id).prev.dylib"), prevJSON = dir.appendingPathComponent("\(id).prev.json")
      if fm.fileExists(atPath: dylib.path) {
        try? fm.removeItem(at: prev)
        try? fm.removeItem(at: prevJSON)
        try fm.copyItem(at: dylib, to: prev)
        if fm.fileExists(atPath: json.path) { try fm.copyItem(at: json, to: prevJSON) }
      }
      let m: [String: Any] = ["id": id, "version": meta.str("version"), "hostAPI": meta["hostAPI"].int.map { Int($0) } ?? 0,
                              "sha256": meta.str("sha256"), "source": meta.str("source", "release"), "installedAt": ISO8601DateFormatter().string(from: Date()),
                              // Same sidecar the loader reads plugin permissions from.
                              "permissions": meta.list("permissions").compactMap(\.string)]
      try JSONSerialization.data(withJSONObject: m, options: [.sortedKeys]).write(to: json, options: .atomic)
      let tmp = dir.appendingPathComponent(".\(id).dylib.tmp")
      try data.write(to: tmp)
      guard rename(tmp.path, dylib.path) == 0 else { return "rename failed" }
      return nil
    } catch { return error.localizedDescription }
  }

  func rollback(_ id: String) -> Value {
    guard LivePlugins.validID(id) else { return .error("updates: bad id") }
    let fm = FileManager.default, dir = home.managedPlugins
    let dylib = dir.appendingPathComponent("\(id).dylib"), json = dir.appendingPathComponent("\(id).json")
    let prev = dir.appendingPathComponent("\(id).prev.dylib"), prevJSON = dir.appendingPathComponent("\(id).prev.json")
    var restored = false
    if fm.fileExists(atPath: prev.path) {
      try? fm.removeItem(at: json)
      if fm.fileExists(atPath: prevJSON.path) { try? fm.moveItem(at: prevJSON, to: json) }
      restored = rename(prev.path, dylib.path) == 0
    } else {
      try? fm.removeItem(at: dylib)
      try? fm.removeItem(at: json)
    }
    _ = activate("\(id).dylib")
    return ["ok": true, "restored": .bool(restored)]
  }

  func kickUpdater() -> Value {
    // The marker makes the updater report back (state.json) even when nothing changed.
    try? FileManager.default.createDirectory(at: home.updates, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: home.updates.appendingPathComponent("check-requested").path, contents: nil)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = ["kickstart", "gui/\(getuid())/\(updaterLabel)"]
    do { try p.run() } catch { return .error("updates: \(error.localizedDescription)") }
    return .ok
  }

  public func sparkleEvent(_ phase: String, version: String? = nil, error: String? = nil) {
    var v: Value = ["phase": .string(phase)]
    if let version { v = v.with("version", .string(version)) }
    if let error { v = v.with("error", .string(error)) }
    host.emit("updates.sparkle", v)
  }

  nonisolated static func hex<D: Sequence>(_ d: D) -> String where D.Element == UInt8 { d.map { String(format: "%02x", $0) }.joined() }
  nonisolated static func real(_ p: String) -> String { LivePlugins.realPath(p) }
}

/// Sparkle, seen from the host (implemented in the app target, which links Sparkle).
@MainActor
public protocol SparkleBridge: AnyObject {
  func configure(channel: String)
  func check(userInitiated: Bool)
  /// Answers the pending question (update found / ready to install): install, later, skip.
  func reply(_ choice: String)
}
