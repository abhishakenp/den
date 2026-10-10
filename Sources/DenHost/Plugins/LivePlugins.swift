import Cordis
import CordisValue
import CoreServices
import CryptoKit
import Foundation

/// Keeps the running app in step with `~/.den`: plugins, source plugins, themes, config.
///
/// - One FSEvents stream over `~/.den` (event-driven: no polling, no cost while nothing changes).
///   Changes are coalesced for 100 ms, then each touched plugin is re-resolved.
/// - Priority for a plugin file name `<id>.dylib`, lowest to highest:
///   bundled `Contents/PlugIns` < `~/Library/Application Support/den/Plugins` (legacy) <
///   `~/.den/updates/plugins/<id>.dylib` (managed: plugin updates) < `~/.den/plugins/<id>.dylib` <
///   `~/.den/plugins/<id>/*.swift` (compiled) < `--dev-plugins`.
///   Adding a higher layer hot-swaps the plugin; removing it falls back to the next one.
/// - Host API safety: a managed plugin carries `<id>.json` with the `hostAPI` generation it was
///   built against, and loads only into a host of exactly that generation (newer: deferred until
///   den restarts on the new host; older: superseded by the new bundle). The bundled layer counts
///   only while the bundle on disk is the one running (an installed update waits for the restart).
///   When nothing compatible is left, the running plugin stays as it is.
/// - A source plugin folder is compiled with cordis-build (bundled in
///   `Contents/Resources/cordis`) on a background queue into `DenHome.buildCache`, keyed by a
///   hash of its sources, so an unchanged folder is never rebuilt.
///
/// `start()` runs after the first window; launch only calls `launchFiles` (one directory read).
@MainActor
public final class LivePlugins {
  public struct Layers {
    public var bundle: URL?
    public var user: URL?
    public var dev: URL?
    @MainActor public init(bundle: URL? = PluginLoader.bundleDirectory, user: URL? = PluginLoader.userDirectory, dev: URL? = nil) {
      self.bundle = bundle
      self.user = user
      self.dev = dev
    }
  }

  public enum Action: Equatable {
    case none
    case load(String)
    case reload(String)
    case swap(from: String, to: String)
    case unload(String)
  }

  let plugins: PluginHost
  public let home: DenHome
  let layers: Layers
  public let log: DenLog
  public var compiler: SourceCompiler?
  /// Plugin ids not to load (config.toml `[plugins] disabled`).
  public var disabled: () -> Set<String> = { [] }
  /// A plugin failed to load or build, or source plugins have no toolchain: `plugins.failed`
  /// {id?, stage: load|build|toolchain, reason, log?}. The updates plugin words it (PluginNotices).
  public var notify: (Value) -> Void = { _ in }
  public var configChanged: () -> Void = {}
  public var themesChanged: () -> Void = {}
  /// The running host's API generation (`DenBuild.running.hostAPI`; nil accepts everything).
  public var hostAPI: Int?
  /// Called after each finished source build (tests).
  public var onBuilt: (String, Bool) -> Void = { _, _ in }

  var watcher: TreeWatcher?
  var rootReal = ""
  var pendingPaths: [String] = []
  var flush: DispatchWorkItem?
  var building: Set<String> = []
  var rebuild: Set<String> = []
  var toldNoToolchain = false

  public init(plugins: PluginHost, home: DenHome = DenHome(), layers: Layers = Layers(), compiler: SourceCompiler? = SourceCompiler.locate()) {
    self.plugins = plugins
    self.home = home
    self.layers = layers
    self.compiler = compiler
    log = DenLog(url: home.logs.appendingPathComponent("plugins.log"))
  }

  /// The `~/.den` files to load at launch: every `<id>.dylib`, plus the last build of every
  /// source folder `<id>/` (checked and rebuilt if stale after the first window).
  public nonisolated static func launchFiles(_ home: DenHome, hostAPI: Int? = nil) -> [URL] {
    var out: [URL] = []
    // Managed first: user layers after it win for the same file name.
    for f in PluginLoader.dylibs(in: home.managedPlugins) where !f.lastPathComponent.hasSuffix(".prev.dylib") && managedCompatible(f, hostAPI: hostAPI) == .ok {
      out.append(f)
    }
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: home.plugins.path) else { return out }
    for n in names.sorted() where !n.hasPrefix(".") {
      if n.hasSuffix(".dylib") {
        out.append(home.plugins.appendingPathComponent(n))
      } else if !n.contains(".") {
        let cached = home.buildCache.appendingPathComponent("\(n).dylib")
        if FileManager.default.fileExists(atPath: cached.path) { out.append(cached) }
      }
    }
    return out
  }

  /// Creates `~/.den`, starts watching it and brings source plugins up to date.
  public func start() {
    home.ensureLayout()
    rootReal = Self.realPath(home.root.path)
    // The updater's checkout (builds write thousands of files) and den's own logs never wake den.
    let exclude = [rootReal + "/src", rootReal + "/logs", rootReal + "/updates/stage"]
    watcher = TreeWatcher(path: rootReal, exclude: exclude) { [weak self] paths in MainActor.assumeIsolated { self?.changed(paths) } }
    if watcher == nil { log.write("watch: could not watch \(rootReal)") }
    for id in sourceIds() { build(id) }
    log.write("watch: \(rootReal)")
  }

  public func stop() {
    watcher?.cancel()
    watcher = nil
    flush?.cancel()
  }

  // MARK: Events

  func changed(_ paths: [String]) {
    pendingPaths += paths
    flush?.cancel()
    let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.process() } }
    flush = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
  }

  public struct Changes: Equatable {
    public var dylibs: Set<String> = []  // file names "<id>.dylib"
    public var sources: Set<String> = []  // ids with a source folder
    public var config = false
    public var themes = false
  }

  /// Sorts FSEvents paths under `root` (a real path) into what needs refreshing.
  public nonisolated static func classify(_ paths: [String], root: String) -> Changes {
    var c = Changes()
    let prefix = root.hasSuffix("/") ? root : root + "/"
    for p in paths where p.hasPrefix(prefix) {
      let parts = p.dropFirst(prefix.count).split(separator: "/").map(String.init)
      guard let first = parts.first else { continue }
      if parts == ["config.toml"] {
        c.config = true
      } else if first == "themes" {
        c.themes = true
      } else if first == "updates", parts.count == 3, parts[1] == "plugins", parts[2].hasSuffix(".dylib") || parts[2].hasSuffix(".json") {
        let base = parts[2].hasSuffix(".dylib") ? String(parts[2].dropLast(6)) : String(parts[2].dropLast(5))
        if validID(base), !base.hasSuffix(".prev") { c.dylibs.insert(base + ".dylib") }
      } else if first == "plugins", parts.count >= 2 {
        let name = parts[1]
        guard !name.hasPrefix("."), validID(name.hasSuffix(".dylib") ? String(name.dropLast(6)) : name) else { continue }
        if parts.count == 2, name.hasSuffix(".dylib") {
          c.dylibs.insert(name)
        } else if parts.count == 2 && !name.contains(".") || parts.count == 3 && parts[2].hasSuffix(".swift") {
          c.sources.insert(name)
        }
      }
    }
    return c
  }

  nonisolated static func validID(_ id: String) -> Bool {
    !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
  }

  func process() {
    let c = Self.classify(pendingPaths, root: rootReal)
    pendingPaths = []
    if c.config {
      configChanged()
      // `[plugins] disabled` may have changed: re-resolve everything we know of.
      for name in knownNames() { refresh(name) }
    }
    if c.themes { themesChanged() }
    for name in c.dylibs.sorted() { refresh(name) }
    for id in c.sources.sorted() { build(id) }
  }

  // MARK: Resolution

  func sourceDir(_ id: String) -> URL { home.plugins.appendingPathComponent(id, isDirectory: true) }

  func sources(_ id: String) -> [URL] {
    let dir = sourceDir(id)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.filter { $0.hasSuffix(".swift") && !$0.hasPrefix(".") }.sorted().map { dir.appendingPathComponent($0) }
  }

  func sourceIds() -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: home.plugins.path)) ?? []
    return names.filter { !$0.hasPrefix(".") && !$0.contains(".") && !sources($0).isEmpty }.sorted()
  }

  /// Every plugin file name any layer has, or that is loaded.
  func knownNames() -> Set<String> {
    var names = Set(plugins.plugins.map { ($0.path as NSString).lastPathComponent })
    for dir in [layers.bundle, layers.user, home.plugins, home.managedPlugins] {
      for f in PluginLoader.dylibs(in: dir) where !f.lastPathComponent.hasSuffix(".prev.dylib") { names.insert(f.lastPathComponent) }
    }
    for id in sourceIds() { names.insert("\(id).dylib") }
    return names
  }

  /// Existing candidates for `name`, highest priority first (without `--dev-plugins`).
  public func candidates(_ name: String) -> [URL] {
    let id = String(name.dropLast(6))
    var list: [URL] = []
    let cached = home.buildCache.appendingPathComponent(name)
    if !sources(id).isEmpty { list.append(cached) }
    list.append(home.plugins.appendingPathComponent(name))
    list.append(home.managedPlugins.appendingPathComponent(name))
    if let u = layers.user { list.append(u.appendingPathComponent(name)) }
    if let b = layers.bundle { list.append(b.appendingPathComponent(name)) }
    return list.filter { FileManager.default.fileExists(atPath: $0.path) }
  }

  public enum Compatibility: Equatable {
    case ok
    case deferred(needs: Int)  // built for a newer host: waits for the restart
    case superseded(builtFor: Int)  // built for an older host: the bundle has a newer build
  }

  /// A managed plugin's compatibility with host generation `hostAPI`, from its `<id>.json`.
  /// Without a sidecar (or a generation) it's accepted.
  public nonisolated static func managedCompatible(_ dylib: URL, hostAPI: Int?) -> Compatibility {
    guard let hostAPI else { return .ok }
    let meta = dylib.deletingPathExtension().appendingPathExtension("json")
    guard let data = try? Data(contentsOf: meta), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let built = (obj["hostAPI"] as? Int) ?? (obj["hostAPI"] as? String).flatMap({ Int($0) })
    else { return .ok }
    if built > hostAPI { return .deferred(needs: built) }
    if built < hostAPI { return .superseded(builtFor: built) }
    return .ok
  }

  /// Whether `url` can load into this host now.
  public func compatibility(_ url: URL) -> Compatibility {
    guard let hostAPI else { return .ok }
    if url.deletingLastPathComponent().standardizedFileURL == home.managedPlugins.standardizedFileURL {
      return Self.managedCompatible(url, hostAPI: hostAPI)
    }
    if let b = layers.bundle, url.deletingLastPathComponent().standardizedFileURL == b.standardizedFileURL,
      let onDisk = DenBuild.hostAPI(ofContents: b.deletingLastPathComponent()), onDisk != hostAPI
    {
      return onDisk > hostAPI ? .deferred(needs: onDisk) : .superseded(builtFor: onDisk)
    }
    return .ok
  }

  public nonisolated static func plan(current: String?, target: String?) -> Action {
    switch (current, target) {
    case (nil, nil): return .none
    case let (c?, nil): return .unload(c)
    case let (nil, t?): return .load(t)
    case let (c?, t?): return c == t ? .reload(t) : .swap(from: c, to: t)
    }
  }

  /// Makes the loaded plugin for `name` the highest-priority one on disk.
  public func refresh(_ name: String) {
    if let dev = layers.dev, FileManager.default.fileExists(atPath: dev.appendingPathComponent(name).path) { return }  // --dev-plugins owns it
    let id = String(name.dropLast(6))
    let current = plugins.plugins.first { ($0.path as NSString).lastPathComponent == name }
    let all = disabled().contains(id) ? [] : candidates(name)
    let options = all.filter { compatibility($0) == .ok }
    if options.isEmpty, !all.isEmpty {
      // Only files for another host generation: keep whatever runs now.
      let why = all.map { "\(Self.tilde($0.path)): \(compatibility($0))" }.joined(separator: ", ")
      log.write("deferred \(id): \(why)")
      return
    }
    // A lazy plugin waiting for its first trigger: stays waiting, or follows the new file.
    if current == nil, let loader = PluginLoader.of(plugins), loader.armed[id] != nil {
      if loader.refreshArmed(name, target: options.first) {
        log.write("lazy \(id): \(options.first.map { Self.tilde($0.path) } ?? "none")")
        return
      }
      if let t = options.first {
        loader.load(t, watch: false)
        log.write("loaded \(id) from \(Self.tilde(t.path))")
      }
      return
    }
    switch Self.plan(current: current?.path, target: options.first?.path) {
    case .none: return
    case .unload:
      if let current { _ = try? plugins.unload(current.id) }
      log.write("unloaded \(current?.id ?? id)")
    case let .reload(path):
      switch plugins.reload(path: path) {
      case .unchanged: return
      case let .reloaded(info, _):
        grant(info.id, URL(fileURLWithPath: path))
        log.write("reloaded \(info.id) from \(Self.tilde(path)) build \(info.buildHash)")
      case let .failed(reason, _):
        log.write("reload failed \(id): \(reason)")
        notify(["id": .string(id), "stage": "load", "reason": .string(reason)])
        load(Array(options.dropFirst()), id: id)
      }
    case let .load(path):
      _ = path
      load(options, id: id)
    case let .swap(from, _):
      if let current { _ = try? plugins.unload(current.id) }
      log.write("swapping \(id) from \(Self.tilde(from))")
      load(options, id: id)
    }
  }

  /// Grants what the file's `<id>.json` sidecar declares, as the launch loader does.
  func grant(_ id: String, _ dylib: URL) {
    guard let p = DenRuntime.permissions(for: plugins) else { return }
    p.revoke(id)
    _ = p.loadSidecar(plugin: id, dylib: dylib)
  }

  /// Loads the first candidate that works.
  func load(_ options: [URL], id: String) {
    for url in options {
      do {
        let info = try plugins.load(url.path)
        grant(info.id, url)
        log.write("loaded \(info.id) from \(Self.tilde(url.path)) build \(info.buildHash)")
        return
      } catch {
        log.write("load failed \(url.path): \(error.description)")
        notify(["id": .string(id), "stage": "load", "reason": .string(error.description)])
      }
    }
  }

  // MARK: Source plugins

  func build(_ id: String) {
    let name = "\(id).dylib"
    let out = home.buildCache.appendingPathComponent(name)
    let stampFile = home.buildCache.appendingPathComponent("\(id).stamp")
    let files = sources(id)
    guard !files.isEmpty else {
      // Folder gone or emptied: drop its build, fall back to the next layer.
      try? FileManager.default.removeItem(at: out)
      try? FileManager.default.removeItem(at: stampFile)
      refresh(name)
      return
    }
    guard let compiler else {
      noteNoToolchain("noCordisBuild", log: "den can't find cordis-build (its bundled copy is missing)")
      return
    }
    guard compiler.toolchain != nil else {
      noteNoToolchain("noEmbeddedSwift", log: "no Swift toolchain with Embedded Swift (swift.org, or set CORDIS_TOOLCHAIN)")
      return
    }
    if building.contains(id) {
      rebuild.insert(id)
      return
    }
    let stamp = compiler.fingerprint(id: id, sources: files)
    if (try? String(contentsOf: stampFile, encoding: .utf8)) == stamp, FileManager.default.fileExists(atPath: out.path) {
      refresh(name)
      return
    }
    building.insert(id)
    log.write("building \(id) (\(files.count) files)")
    let logFile = home.logs.appendingPathComponent("build-\(id).log")
    let started = Date()
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let (ok, output) = compiler.run(id: id, out: out, sources: files)
      try? FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? Data(output.utf8).write(to: logFile, options: .atomic)
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self else { return }
          self.building.remove(id)
          let ms = Int(Date().timeIntervalSince(started) * 1000)
          if ok {
            try? Data(stamp.utf8).write(to: stampFile, options: .atomic)
            self.log.write("built \(id) in \(ms) ms")
            self.refresh(name)
          } else {
            let first = Self.firstError(output)
            self.log.write("build failed \(id) in \(ms) ms: \(first)")
            self.notify(["id": .string(id), "stage": "build", "reason": .string(first), "log": .string("~/.den/logs/build-\(id).log")])
          }
          self.onBuilt(id, ok)
          if self.rebuild.remove(id) != nil { self.build(id) }
        }
      }
    }
  }

  func noteNoToolchain(_ reason: String, log message: String) {
    log.write("source plugins: \(message)")
    guard !toldNoToolchain else { return }
    toldNoToolchain = true
    notify(["stage": "toolchain", "reason": .string(reason)])
  }

  nonisolated static func firstError(_ output: String) -> String {
    let lines = output.split(separator: "\n").map(String.init)
    let line = lines.first { $0.contains("error:") } ?? lines.last ?? "unknown error"
    let short = line.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    return short.count > 160 ? String(short.prefix(160)) + "…" : short
  }

  nonisolated static func tilde(_ path: String) -> String {
    path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
  }

  nonisolated static func realPath(_ p: String) -> String {
    guard let r = realpath(p, nil) else { return p }
    defer { free(r) }
    return String(cString: r)
  }
}

/// Compiles a source plugin folder with cordis-build.
public struct SourceCompiler: Sendable {
  /// The cordis-build script (next to its `Sources/` in a cordis-swift layout).
  public let script: URL
  /// Extra sources compiled into every plugin (den's `Plugins/Shared`).
  public let shared: [URL]
  public let toolchain: URL?

  public init(script: URL, shared: [URL], toolchain: URL? = SourceCompiler.findToolchain()) {
    self.script = script
    self.shared = shared
    self.toolchain = toolchain
  }

  /// `den.app/Contents/Resources/cordis`, or `$DEN_CORDIS_BUILD` (a cordis-build path).
  public static func locate() -> SourceCompiler? {
    let env = ProcessInfo.processInfo.environment
    var root: URL?
    if let p = env["DEN_CORDIS_BUILD"], !p.isEmpty {
      root = URL(fileURLWithPath: p).deletingLastPathComponent().deletingLastPathComponent()
    } else if let r = Bundle.main.resourceURL?.appendingPathComponent("cordis") {
      root = r
    }
    guard let root else { return nil }
    let script = root.appendingPathComponent("Scripts/cordis-build")
    guard FileManager.default.isExecutableFile(atPath: script.path) else { return nil }
    let sharedDir = root.appendingPathComponent("den-shared")
    let shared = ((try? FileManager.default.contentsOfDirectory(atPath: sharedDir.path)) ?? [])
      .filter { $0.hasSuffix(".swift") }.sorted().map { sharedDir.appendingPathComponent($0) }
    return SourceCompiler(script: script, shared: shared)
  }

  /// cordis-build's toolchain resolution: a toolchain with an Embedded Swift stdlib.
  public static func findToolchain(env: [String: String] = ProcessInfo.processInfo.environment, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
    let fm = FileManager.default
    func ok(_ u: URL) -> Bool {
      fm.isExecutableFile(atPath: u.appendingPathComponent("usr/bin/swiftc").path) && fm.fileExists(atPath: u.appendingPathComponent("usr/lib/swift/embedded").path)
    }
    if let p = env["CORDIS_TOOLCHAIN"], !p.isEmpty {
      let u = URL(fileURLWithPath: p)
      return ok(u) ? u : nil
    }
    for dir in [home.appendingPathComponent(".swiftly/toolchains"), home.appendingPathComponent("Library/Developer/Toolchains")] {
      let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted { $0.compare($1, options: .numeric) == .orderedDescending }
      for n in names where ok(dir.appendingPathComponent(n)) { return dir.appendingPathComponent(n) }
    }
    let latest = URL(fileURLWithPath: "/Library/Developer/Toolchains/swift-latest.xctoolchain")
    return ok(latest) ? latest : nil
  }

  /// Hash of everything that goes into the build.
  public func fingerprint(id: String, sources: [URL]) -> String {
    var h = SHA256()
    h.update(data: Data("\(id)\n\(toolchain?.path ?? "")\n".utf8))
    for f in [script] + sources + shared {
      h.update(data: Data(f.lastPathComponent.utf8))
      h.update(data: (try? Data(contentsOf: f)) ?? Data())
    }
    return h.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// Runs cordis-build (blocking). cordis-build writes `out` atomically.
  /// The sources are compiled from prefixed copies (`<id>--<name>.swift`): swiftc refuses two
  /// files with the same name, and cordis-build already brings a `Plugin.swift` (CordisKit), the
  /// name most plugins use. Diagnostics are mapped back to the original paths.
  public func run(id: String, out: URL, sources: [URL]) -> (Bool, String) {
    let fm = FileManager.default
    let stage = out.deletingLastPathComponent().appendingPathComponent(".stage-\(id)", isDirectory: true)
    try? fm.removeItem(at: stage)
    try? fm.createDirectory(at: stage, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: stage) }
    var staged: [URL] = []
    for s in sources {
      let copy = stage.appendingPathComponent("\(id)--\(s.lastPathComponent)")
      do { try fm.copyItem(at: s, to: copy) } catch { return (false, "cannot stage \(s.path): \(error.localizedDescription)") }
      staged.append(copy)
    }
    let (ok, output) = runScript(id: id, out: out, files: staged + shared)
    let sourceDir = sources.first?.deletingLastPathComponent().path ?? ""
    return (ok, output.replacingOccurrences(of: stage.path + "/\(id)--", with: sourceDir + "/"))
  }

  func runScript(id: String, out: URL, files: [URL]) -> (Bool, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [script.path, "--id", id, "--out", out.path] + files.map(\.path)
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin" + (env["PATH"].map { ":" + $0 } ?? "")
    if let t = toolchain { env["CORDIS_TOOLCHAIN"] = t.path }
    p.environment = env
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (false, "cannot run cordis-build: \(error.localizedDescription)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus == 0, String(decoding: data, as: UTF8.self))
  }
}

/// An FSEvents stream over one directory tree, delivering changed paths on the main queue.
public final class TreeWatcher {
  final class Box {
    let handler: ([String]) -> Void
    init(_ h: @escaping ([String]) -> Void) { handler = h }
  }

  private var stream: FSEventStreamRef?
  private let box: Box

  /// `exclude`: subtrees whose changes are never delivered (up to 8; e.g. build trees, logs).
  public init?(path: String, exclude: [String] = [], latency: CFTimeInterval = 0.05, handler: @escaping ([String]) -> Void) {
    box = Box(handler)
    var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(), retain: nil, release: nil, copyDescription: nil)
    let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
      guard let info else { return }
      let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
      let array = unsafeBitCast(paths, to: NSArray.self)
      box.handler((0..<count).compactMap { array[$0] as? String })
    }
    let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
    guard let s = FSEventStreamCreate(nil, callback, &ctx, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return nil }
    stream = s
    if !exclude.isEmpty { FSEventStreamSetExclusionPaths(s, Array(exclude.prefix(8)) as CFArray) }
    FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
    guard FSEventStreamStart(s) else {
      FSEventStreamInvalidate(s)
      FSEventStreamRelease(s)
      stream = nil
      return nil
    }
  }

  public func cancel() {
    guard let s = stream else { return }
    FSEventStreamStop(s)
    FSEventStreamInvalidate(s)
    FSEventStreamRelease(s)
    stream = nil
  }

  deinit { cancel() }
}
