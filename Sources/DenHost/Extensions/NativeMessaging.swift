import Foundation
import WebKit

/// `runtime.connectNative` / `runtime.sendNativeMessage` for den's extensions, the way Chrome and
/// Firefox do it: a desktop app (a password manager, typically) installs a JSON manifest naming
/// a native host program and the extensions allowed to start it; den finds that manifest, checks
/// the extension against it, starts the program and talks to it over stdin/stdout, each message a
/// 32-bit native-endian length followed by that many bytes of UTF-8 JSON
/// (https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging).
///
/// WebKit hands both calls to the controller delegate (`ExtensionControllerDelegate`); without it
/// they did nothing for any extension that didn't come from a Safari app extension bundle.
///
/// What den reads, in order (the first manifest with the name wins):
/// - `~/.den/NativeMessagingHosts` and `~/Library/Application Support/den/NativeMessagingHosts`
///   (den's own: copy or link a manifest here to allow it for den only),
/// - the Chrome-family folders desktop apps already write to (Chrome, Chromium, Brave, Edge,
///   Vivaldi, Arc; user then system), for extensions from the Chrome Web Store,
/// - Firefox's (`Mozilla/NativeMessagingHosts`), for extensions from Firefox Add-ons.
///
/// A Chrome-format manifest lists `allowed_origins` (`chrome-extension://<id>/`); a Firefox one
/// `allowed_extensions` (gecko ids). An extension that isn't listed is refused, as in Chrome.
/// The program gets Chrome's argument (the caller's origin) or Firefox's (manifest path and
/// extension id), matching the manifest's flavor. Nothing runs until an extension asks; every host
/// started is stopped when its port closes, its extension unloads, or den quits.
@MainActor
final class NativeMessaging {
  /// Chrome's error strings, so extensions that match on them behave as they do in Chrome.
  enum Failure: String, Error {
    case notFound = "Specified native messaging host not found."
    case forbidden = "Access to the specified native messaging host is forbidden."
    case exited = "Native host has exited."
    case failedToStart = "Failed to start native messaging host."
    case invalid = "Error when communicating with the native messaging host."
  }

  /// A manifest found on disk.
  struct Host: Equatable {
    var name: String
    var path: String
    var manifest: String
    /// `chrome` (allowed_origins) or `firefox` (allowed_extensions).
    var flavor: String
    var allowed: [String]
  }

  /// Who is asking: den's id for the extension, its Chrome id when it has one (store id or manifest
  /// `key`), and its gecko id (Firefox builds).
  struct Caller: Equatable {
    var id: String
    var chromeId: String?
    var geckoId: String?
    var origin: String? { chromeId.map { "chrome-extension://\($0)/" } }
  }

  /// Folders searched for `<name>.json`, den's own first.
  var directories: [URL]
  /// Lines for `~/.den/logs/extensions.log`.
  var log: (String) -> Void = { _ in }
  /// Running hosts by connection number.
  private(set) var running: [Int: Connection] = [:]
  private var next = 1

  init(directories: [URL] = NativeMessaging.defaultDirectories()) { self.directories = directories }

  static func defaultDirectories(home: URL = FileManager.default.homeDirectoryForCurrentUser, denHome: URL? = nil) -> [URL] {
    let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
    let sys = URL(fileURLWithPath: "/Library/Application Support", isDirectory: true)
    var out: [URL] = []
    if let d = denHome { out.append(d.appendingPathComponent("NativeMessagingHosts", isDirectory: true)) }
    out.append(support.appendingPathComponent("den/NativeMessagingHosts", isDirectory: true))
    let chromeFamily = ["Google/Chrome", "Google/Chrome Beta", "Google/Chrome Canary", "Chromium", "BraveSoftware/Brave-Browser",
                        "Microsoft Edge", "Vivaldi", "Arc/User Data"]
    out += chromeFamily.map { support.appendingPathComponent("\($0)/NativeMessagingHosts", isDirectory: true) }
    out.append(URL(fileURLWithPath: "/Library/Google/Chrome/NativeMessagingHosts", isDirectory: true))
    out += ["Chromium", "Microsoft Edge", "BraveSoftware/Brave-Browser"].map { sys.appendingPathComponent("\($0)/NativeMessagingHosts", isDirectory: true) }
    out.append(support.appendingPathComponent("Mozilla/NativeMessagingHosts", isDirectory: true))
    out.append(sys.appendingPathComponent("Mozilla/NativeMessagingHosts", isDirectory: true))
    return out
  }

  /// Chrome's rule for host names: lowercase letters, digits, underscores and dots, not starting
  /// or ending with a dot, no "..". It also keeps a name from walking out of the folder.
  static func isValidName(_ name: String) -> Bool {
    guard !name.isEmpty, name.utf8.count <= 255, !name.hasPrefix("."), !name.hasSuffix("."), !name.contains("..") else { return false }
    return name.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 95 || $0 == 46 }
  }

  /// Every manifest with this name, in search order (only the first is used; the rest explain
  /// what was skipped).
  func manifests(named name: String) -> [Host] {
    guard Self.isValidName(name) else { return [] }
    return directories.compactMap { Self.read($0.appendingPathComponent("\(name).json"), name: name) }
  }

  static func read(_ url: URL, name: String) -> Host? {
    guard let data = try? Data(contentsOf: url), let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    guard (o["name"] as? String) == name, (o["type"] as? String ?? "stdio") == "stdio", let p = o["path"] as? String, !p.isEmpty else { return nil }
    // macOS manifests must name an absolute path (Chrome resolves relative ones only on Windows).
    let path = p.hasPrefix("/") ? p : url.deletingLastPathComponent().appendingPathComponent(p).path
    if let origins = o["allowed_origins"] as? [String] {
      return Host(name: name, path: path, manifest: url.path, flavor: "chrome", allowed: origins)
    }
    if let ids = o["allowed_extensions"] as? [String] {
      return Host(name: name, path: path, manifest: url.path, flavor: "firefox", allowed: ids)
    }
    return nil
  }

  /// The host this extension may start under `name`, or why not.
  func resolve(_ name: String?, for caller: Caller) -> Result<Host, Failure> {
    guard let name, Self.isValidName(name) else { return .failure(.notFound) }
    let found = manifests(named: name)
    guard !found.isEmpty else { return .failure(.notFound) }
    // The first manifest that lets this extension in (a den-only manifest can add an extension
    // that the app's own Chrome manifest doesn't list).
    for h in found where Self.allows(h, caller) {
      guard FileManager.default.isExecutableFile(atPath: h.path) else { return .failure(.failedToStart) }
      return .success(h)
    }
    return .failure(.forbidden)
  }

  static func allows(_ h: Host, _ c: Caller) -> Bool {
    switch h.flavor {
    case "chrome": return c.origin.map { o in h.allowed.contains { $0 == o || $0 == String(o.dropLast()) } } ?? false
    default: return c.geckoId.map { h.allowed.contains($0) } ?? false
    }
  }

  /// Chrome passes the caller's origin; Firefox the manifest's path and the extension's id.
  static func arguments(_ h: Host, _ c: Caller) -> [String] {
    h.flavor == "chrome" ? [c.origin ?? ""] : [h.manifest, c.geckoId ?? ""]
  }

  // MARK: Framing

  /// Chrome refuses messages from a host above 1 MB; den does the same.
  nonisolated static let maxIncoming = 1024 * 1024
  /// To a host: Chrome allows up to 4 GB; den caps at 64 MB.
  nonisolated static let maxOutgoing = 64 * 1024 * 1024

  nonisolated static func frame(_ message: Any?) throws -> Data {
    let body = try JSONSerialization.data(withJSONObject: message ?? NSNull(), options: [.fragmentsAllowed])
    guard body.count <= maxOutgoing else { throw Failure.invalid }
    var n = UInt32(body.count)
    var out = Data(bytes: &n, count: 4)  // native byte order, as the protocol says
    out.append(body)
    return out
  }

  /// Splits whole messages off the front of `buffer`. Throws on a message over the limit or bytes
  /// that aren't JSON.
  nonisolated static func unframe(_ buffer: inout Data) throws -> [Any] {
    var out: [Any] = []
    while buffer.count >= 4 {
      let n = buffer.prefix(4).withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self)) }
      guard n <= maxIncoming else { throw Failure.invalid }
      guard buffer.count >= 4 + n else { break }
      let body = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + n)
      buffer = Data(buffer.dropFirst(4 + n))
      guard let v = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else { throw Failure.invalid }
      out.append(v)
    }
    return out
  }

  // MARK: Running hosts

  /// One running host process.
  @MainActor
  final class Connection {
    let number: Int
    let host: Host
    let extensionId: String
    let process = Process()
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    var buffer = Data()
    var errorText = ""
    var closed = false
    var onMessage: (Any) -> Void = { _ in }
    var onEnd: (Failure?) -> Void = { _ in }

    init(number: Int, host: Host, extensionId: String) { (self.number, self.host, self.extensionId) = (number, host, extensionId) }

    func send(_ message: Any?) throws {
      guard !closed else { throw Failure.exited }
      let data = try NativeMessaging.frame(message)
      // A write to a host that has exited raises SIGPIPE; den ignores it process-wide (below).
      do { try stdin.fileHandleForWriting.write(contentsOf: data) } catch { throw Failure.exited }
    }
  }

  /// Starts the host for `caller`, or says why it can't.
  func start(_ name: String?, for caller: Caller) -> Result<Connection, Failure> {
    let h: Host
    switch resolve(name, for: caller) {
    case let .failure(f):
      log("native host \(name ?? "(none)") for \(caller.id): \(f.rawValue) (searched \(manifests(named: name ?? "").map(\.manifest)))")
      return .failure(f)
    case let .success(found): h = found
    }
    _ = Self.ignoreSigpipe
    let c = Connection(number: next, host: h, extensionId: caller.id)
    next += 1
    c.process.executableURL = URL(fileURLWithPath: h.path)
    c.process.arguments = Self.arguments(h, caller)
    c.process.currentDirectoryURL = URL(fileURLWithPath: h.path).deletingLastPathComponent()
    c.process.standardInput = c.stdin
    c.process.standardOutput = c.stdout
    c.process.standardError = c.stderr
    let n = c.number
    c.stdout.fileHandleForReading.readabilityHandler = { [weak self] fh in
      let chunk = fh.availableData
      DispatchQueue.main.async { MainActor.assumeIsolated { if let self, let c = self.running[n] { self.received(chunk, on: c) } } }
    }
    c.stderr.fileHandleForReading.readabilityHandler = { [weak self] fh in
      let chunk = fh.availableData
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          if let c = self?.running[n], c.errorText.utf8.count < 2048 { c.errorText += String(decoding: chunk, as: UTF8.self) }
        }
      }
    }
    c.process.terminationHandler = { [weak self] p in
      let status = p.terminationStatus
      DispatchQueue.main.async { MainActor.assumeIsolated { if let self, let c = self.running[n] { self.ended(c, status: status) } } }
    }
    running[n] = c
    do {
      try c.process.run()
    } catch {
      running[n] = nil
      log("native host \(h.name) for \(caller.id): couldn't start \(h.path): \(error.localizedDescription)")
      return .failure(.failedToStart)
    }
    log("native host \(h.name) for \(caller.id): started \(h.path) pid \(c.process.processIdentifier) (\(h.manifest))")
    return .success(c)
  }

  private func received(_ chunk: Data, on c: Connection) {
    guard !c.closed else { return }
    if chunk.isEmpty { return }  // end of file: the termination handler reports it
    c.buffer.append(chunk)
    do {
      for m in try Self.unframe(&c.buffer) { c.onMessage(m) }
    } catch {
      log("native host \(c.host.name) for \(c.extensionId): sent a message den can't read (over 1 MB or not JSON); disconnected")
      stop(c, reason: .invalid)
    }
  }

  private func ended(_ c: Connection, status: Int32) {
    // A host that answers and exits at once: its last bytes may still be in the pipe, behind
    // this notice. Read what's there (without blocking: a child of the host may hold the pipe).
    c.stdout.fileHandleForReading.readabilityHandler = nil
    let rest = Self.drain(c.stdout.fileHandleForReading.fileDescriptor)
    if !rest.isEmpty { received(rest, on: c) }
    guard !c.closed else { return }
    let err = c.errorText.trimmingCharacters(in: .whitespacesAndNewlines)
    log("native host \(c.host.name) for \(c.extensionId): exited with status \(status)" + (err.isEmpty ? "" : "; stderr: \(err.prefix(500))"))
    stop(c, reason: .exited)
  }

  nonisolated static func drain(_ fd: Int32) -> Data {
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    var out = Data()
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
      let n = Darwin.read(fd, &buf, buf.count)
      if n <= 0 { break }
      out.append(buf, count: n)
    }
    return out
  }

  /// Closes the connection: stdin first (a host reads EOF and quits), then SIGTERM after 1 s, as
  /// Chrome does. `reason` is what the extension hears (nil: it closed the port itself).
  func stop(_ c: Connection, reason: Failure?) {
    guard !c.closed else { return }
    c.closed = true
    running[c.number] = nil
    c.stdout.fileHandleForReading.readabilityHandler = nil
    c.stderr.fileHandleForReading.readabilityHandler = nil
    try? c.stdin.fileHandleForWriting.close()
    if c.process.isRunning {
      let p = c.process
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if p.isRunning { p.terminate() } }
    }
    c.onEnd(reason)
  }

  /// Every host an extension started (its context unloaded), or all of them (den quits).
  func stopAll(extensionId: String? = nil) {
    for c in running.values where extensionId == nil || c.extensionId == extensionId { stop(c, reason: .exited) }
  }

  // MARK: The two WebExtension calls

  /// `runtime.sendNativeMessage`: a fresh host per message; the first reply answers and the host
  /// is closed (Chrome's behavior). Gives up after `oneShotTimeout`.
  var oneShotTimeout: TimeInterval = 120

  func sendMessage(_ message: Any, to name: String?, caller: Caller, reply: @escaping (Any?, Error?) -> Void) {
    switch start(name, for: caller) {
    case let .failure(f): reply(nil, Self.error(f))
    case let .success(c):
      var answered = false
      let answer: (Any?, Failure?) -> Void = { [weak self, weak c] value, f in
        guard !answered else { return }
        answered = true
        reply(value, f.map(Self.error))
        if let self, let c { self.stop(c, reason: nil) }
      }
      c.onMessage = { answer($0, nil) }
      c.onEnd = { f in answer(nil, f ?? .exited) }
      do { try c.send(message) } catch { answer(nil, (error as? Failure) ?? .invalid) }
      DispatchQueue.main.asyncAfter(deadline: .now() + oneShotTimeout) { answer(nil, .exited) }
    }
  }

  /// `runtime.connectNative`: one host for the life of the port.
  func connect(_ port: WKWebExtension.MessagePort, caller: Caller) -> Error? {
    switch start(port.applicationIdentifier, for: caller) {
    case let .failure(f): return Self.error(f)
    case let .success(c):
      c.onMessage = { [weak port] m in port?.sendMessage(m, completionHandler: nil) }
      c.onEnd = { [weak port] f in
        guard let port, !port.isDisconnected else { return }
        if let f { port.disconnect(throwing: Self.error(f)) } else { port.disconnect() }
      }
      port.messageHandler = { [weak self, weak c] m, _ in
        guard let self, let c else { return }
        do { try c.send(m) } catch {
          self.log("native host \(c.host.name) for \(c.extensionId): write failed")
          self.stop(c, reason: .exited)
        }
      }
      port.disconnectHandler = { [weak self, weak c] _ in
        guard let self, let c else { return }
        self.stop(c, reason: nil)
      }
      return nil
    }
  }

  static func error(_ f: Failure) -> NSError {
    NSError(domain: "den.nativeMessaging", code: 1, userInfo: [NSLocalizedDescriptionKey: f.rawValue])
  }

  /// A host that exits while den writes to it must not take den down with SIGPIPE.
  static let ignoreSigpipe: Void = { signal(SIGPIPE, SIG_IGN) }()
}
