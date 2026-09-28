import AppKit
import CordisValue
import UniformTypeIdentifiers
import WebKit

/// `downloads` service: files a page hands over (`WKDownload`), saved in Downloads.
///
/// The host keeps only the native half: the WKDownloads, their files, progress, and a small list
/// persisted in storage (ns `downloads`, key `items`). What the list looks like, the Library screen,
/// the sidebar indicator and when old downloads move to the archive belong to plugins (`tabs`,
/// `spaces`). Nothing is read, observed or written until the first download or `list` call.
///
/// Methods:
///   list                        -> {items: [item], active, unseen, progress, count}  (newest first)
///   summary                     -> {active, unseen, progress, count}. Never reads the stored list
///   get {id}                    -> item
///   pause {id}                  -> ok. Stops the transfer and keeps what arrived (resume data)
///   resume {id}                 -> ok. Carries on from where it stopped (else starts again)
///   retry {id}                  -> ok. A failed or cancelled download, from the start
///   cancel {id}                 -> ok. Stops it and deletes the partial file
///   open {id}                   -> ok. Opens the file with its app. Without `id`: emits
///                                  `downloads.show` (the command bar's "Downloads" destination)
///   reveal {id}                 -> ok. Shows the file in Finder
///   remove {id}                 -> ok. Takes it off the list (the file stays)
///   clear                       -> {removed}. Every download that isn't running leaves the list
///   archive {before}            -> {archived}. Finished downloads that ended before `before` (ms
///                                  since 1970) are marked `archived`
///   seen                        -> ok. Nothing finished is new any more (the sidebar indicator)
///   start {url, webview?, ask?} -> {id}. Downloads a URL with that page's session; `ask` shows a
///                                  save panel for the destination ("Save Link As…")
/// item: {id, url, name, path, state: downloading|paused|done|failed|cancelled, received, total
///   (-1 unknown), rate (bytes/s while downloading), started, finished?, error?, archived, exists}
/// Events: downloads.changed {active, unseen, progress, count} (at most 4 a second while bytes
/// arrive), downloads.started {id, name, webview}, downloads.finished {id, name, ok, error?},
/// downloads.show.
@MainActor
public final class DownloadsService: NSObject, HostService, WKDownloadDelegate {
  public let name = "downloads"
  let host: ServiceHost
  let storage: StorageService
  /// Where files go (tests point it elsewhere).
  public var folder: () -> URL = { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }
  /// A live web view to start or resume a download from (its page's session), if any.
  var webView: (_ preferred: String) -> WKWebView? = { _ in nil }
  var schedule: HostSchedule = HostTimers.main
  var now: () -> Double = { Date().timeIntervalSince1970 * 1000 }

  public struct Item: Equatable {
    public var id: String
    public var url: String
    public var name: String
    public var path: String
    public var state: String
    public var received: Int64 = 0
    public var total: Int64 = -1
    public var started: Double
    public var finished: Double = 0
    public var error = ""
    public var archived = false
    public var resume: Data?
    public var webview = ""
    public var rate: Double = 0
    public var unseen = false

    public var active: Bool { state == "downloading" }
  }

  /// Whether a web view belongs to a private window (set by `DenRuntime`): its downloads aren't saved.
  public var isPrivateWebview: (String) -> Bool = { _ in false }
  private var loaded = false
  public private(set) var items: [Item] = []
  private var live: [String: WKDownload] = [:]
  private var ids: [ObjectIdentifier: String] = [:]
  private var asks: Set<ObjectIdentifier> = []
  private var progress: [String: NSKeyValueObservation] = [:]
  private var samples: [String: (bytes: Int64, at: Double)] = [:]
  private var changePending: (() -> Void)?
  private var nextId = 1
  static let ns = "downloads"
  static let limit = 300
  /// A web view only for downloads when no page is open (resume after relaunch, retry).
  private var helper: WKWebView?

  public init(host: ServiceHost, storage: StorageService) {
    self.host = host
    self.storage = storage
  }

  public func handle(method: String, args: Value) -> Value {
    if method == "open", args["id"].string == nil {
      host.emit("downloads.show", .null)
      return .ok
    }
    // What the sidebar indicator needs, without reading the stored list.
    if method == "summary" { return summary() }
    load()
    switch method {
    case "list":
      return summary().with("items", .array(items.map { value($0) }))
    case "get":
      guard let i = index(args.str("id")) else { return .error("downloads: no download \(args.str("id"))") }
      return value(items[i])
    case "start":
      guard let u = URL(string: args.str("url")), u.scheme != nil else { return .error("downloads: bad url") }
      guard let w = webView(args.str("webview")) ?? helperWebView() else { return .error("downloads: no web view") }
      let ask = args.flag("ask")
      let pending = placeholder(url: u.absoluteString, webview: args.str("webview"))
      w.startDownload(using: URLRequest(url: u)) { [weak self] d in
        MainActor.assumeIsolated { self?.adopt(d, id: pending, ask: ask) }
      }
      return ["id": .string(pending)]
    case "pause": return pause(args.str("id"))
    case "resume": return resume(args.str("id"))
    case "retry": return retry(args.str("id"))
    case "cancel": return cancel(args.str("id"))
    case "open", "reveal":
      guard let i = index(args.str("id")) else { return .error("downloads: no download \(args.str("id"))") }
      let url = URL(fileURLWithPath: items[i].path)
      guard FileManager.default.fileExists(atPath: url.path) else { return .error("downloads: the file was moved or deleted") }
      if method == "open" { NSWorkspace.shared.open(url) } else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
      return .ok
    case "remove":
      let id = args.str("id")
      if live[id] != nil { _ = cancel(id) }
      items.removeAll { $0.id == id }
      save()
      changed()
      return .ok
    case "clear":
      let before = items.count
      items.removeAll { !$0.active }
      save()
      changed()
      return ["removed": .int(Int64(before - items.count))]
    case "archive":
      let before = args.num("before")
      var n = 0
      for i in items.indices where !items[i].archived && items[i].state != "downloading" && items[i].state != "paused" {
        let end = items[i].finished > 0 ? items[i].finished : items[i].started
        if end < before { items[i].archived = true; n += 1 }
      }
      if n > 0 { save(); changed() }
      return ["archived": .int(Int64(n))]
    case "seen":
      guard items.contains(where: \.unseen) else { return .ok }
      for i in items.indices { items[i].unseen = false }
      changed()
      return .ok
    default:
      return .error("downloads: unknown method '\(method)'")
    }
  }

  // MARK: Model

  func index(_ id: String) -> Int? { items.firstIndex { $0.id == id } }

  func summary() -> Value {
    let active = items.filter(\.active)
    let known = active.filter { $0.total > 0 }
    let total = known.reduce(Int64(0)) { $0 + $1.total }, got = known.reduce(Int64(0)) { $0 + $1.received }
    let p: Double = total > 0 ? Double(got) / Double(total) : (active.isEmpty ? 1 : -1)
    return ["active": .int(Int64(active.count)), "unseen": .int(Int64(items.filter(\.unseen).count)), "progress": .double(p),
            "count": .int(Int64(items.count))]
  }

  func value(_ it: Item) -> Value {
    var v: Value = ["id": .string(it.id), "url": .string(it.url), "name": .string(it.name), "path": .string(it.path), "state": .string(it.state),
                    "received": .int(it.received), "total": .int(it.total), "started": .double(it.started), "archived": .bool(it.archived),
                    "exists": .bool(!it.path.isEmpty && FileManager.default.fileExists(atPath: it.path))]
    if it.finished > 0 { v = v.with("finished", .double(it.finished)) }
    if !it.error.isEmpty { v = v.with("error", .string(it.error)) }
    if it.active { v = v.with("rate", .double(it.rate)) }
    if it.unseen { v = v.with("unseen", true) }
    return v
  }

  static func stored(_ it: Item) -> Value {
    var v: Value = ["id": .string(it.id), "url": .string(it.url), "name": .string(it.name), "path": .string(it.path), "state": .string(it.state),
                    "received": .int(it.received), "total": .int(it.total), "started": .double(it.started), "finished": .double(it.finished),
                    "error": .string(it.error), "archived": .bool(it.archived)]
    if let r = it.resume { v = v.with("resume", .string(r.base64EncodedString())) }
    return v
  }

  /// A stored item. A download that was running when den quit can't carry on: it becomes
  /// "failed · Interrupted" (Retry starts it again). A paused one keeps its resume data.
  static func restore(_ v: Value) -> Item? {
    guard let id = v["id"].string else { return nil }
    var it = Item(id: id, url: v.str("url"), name: v.str("name"), path: v.str("path"), state: v.str("state", "done"),
                  received: v["received"].int ?? 0, total: v["total"].int ?? -1, started: v.num("started"), finished: v.num("finished"),
                  error: v.str("error"), archived: v.flag("archived"))
    it.resume = v["resume"].string.flatMap { Data(base64Encoded: $0) }
    if it.state == "downloading" || (it.state == "paused" && it.resume == nil) {
      it.state = "failed"
      it.error = "Interrupted"
    }
    return it
  }

  func load() {
    guard !loaded else { return }
    loaded = true
    let v = storage.handle(method: "get", args: ["ns": .string(Self.ns), "key": "items"])
    items = (v.array ?? []).compactMap(Self.restore)
    for it in items { if let n = Int(it.id.dropFirst(1)), n >= nextId { nextId = n + 1 } }
  }

  func save() {
    if items.count > Self.limit {
      // Oldest finished ones go first; running downloads always stay.
      var drop = items.count - Self.limit
      let kept: [Item] = items.reversed().filter { it in
        if drop > 0, !it.active, it.state != "paused" { drop -= 1; return false }
        return true
      }
      items = Array(kept.reversed())
    }
    // A private window's downloads are listed this session only; the file stays where you saved it.
    let kept = items.filter { !isPrivateWebview($0.webview) }
    _ = storage.handle(method: "set", args: ["ns": .string(Self.ns), "key": "items", "value": .array(kept.map(Self.stored))])
  }

  /// Emits `downloads.changed` now, or (while bytes arrive) at most every 250 ms.
  func changed(throttled: Bool = false) {
    if throttled {
      guard changePending == nil else { return }
      changePending = schedule(250) { [weak self] in
        guard let self else { return }
        self.changePending = nil
        self.host.emit("downloads.changed", self.summary())
      }
      return
    }
    changePending?()
    changePending = nil
    host.emit("downloads.changed", summary())
  }

  /// Replaces the list (`--scenario downloads` shows running and paused rows without a server).
  func seed(_ list: [Item]) {
    loaded = true
    items = list
    changed()
  }

  // MARK: File names

  /// A file name that is safe on disk: no path separators or leading dots, never empty.
  public nonisolated static func safeName(_ name: String) -> String {
    var s = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    s = s.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
    while s.hasPrefix(".") { s.removeFirst() }
    if s.count > 200 { s = String(s.prefix(200)) }
    return s.isEmpty ? "download" : s
  }

  /// `name` in `folder`, or Finder's "name 2.ext", "name 3.ext" … when that's taken.
  public nonisolated static func uniqueURL(in folder: URL, name: String, taken: (String) -> Bool) -> URL {
    let safe = safeName(name)
    let ext = (safe as NSString).pathExtension
    let base = ext.isEmpty ? safe : String(safe.dropLast(ext.count + 1))
    var n = 1
    while true {
      let candidate = n == 1 ? safe : (ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
      let u = folder.appendingPathComponent(candidate)
      if !taken(u.path) { return u }
      n += 1
    }
  }

  // MARK: WKDownload

  func placeholder(url: String, webview: String) -> String {
    load()
    let id = "d\(nextId)"
    nextId += 1
    items.insert(Item(id: id, url: url, name: URL(string: url)?.lastPathComponent ?? "download", path: "", state: "downloading",
                      started: now(), webview: webview), at: 0)
    return id
  }

  /// A download WebKit started from a page (a response it can't show, `<a download>`, a
  /// `Content-Disposition: attachment`) or that `start` asked for.
  public func adopt(_ d: WKDownload, webview: String = "", ask: Bool = false) {
    let id = placeholder(url: d.originalRequest?.url?.absoluteString ?? "", webview: webview)
    adopt(d, id: id, ask: ask)
  }

  func adopt(_ d: WKDownload, id: String, ask: Bool) {
    d.delegate = self
    live[id] = d
    ids[ObjectIdentifier(d)] = id
    if ask { asks.insert(ObjectIdentifier(d)) }
    samples[id] = (0, now())
    progress[id] = d.progress.observe(\.completedUnitCount, options: []) { [weak self] p, _ in
      let got = p.completedUnitCount, total = p.totalUnitCount
      let s = self
      Task { @MainActor in s?.progressed(id, got, total) }
    }
    if let i = index(id) {
      items[i].state = "downloading"
      items[i].error = ""
      if let u = d.originalRequest?.url?.absoluteString, !u.isEmpty { items[i].url = u }
    }
    changed()
  }

  func progressed(_ id: String, _ got: Int64, _ total: Int64) {
    guard let i = index(id), items[i].active else { return }
    items[i].received = max(0, got)
    items[i].total = total > 0 ? total : -1
    let t = now()
    if let s = samples[id], t - s.at >= 500 {
      let r = Double(got - s.bytes) / ((t - s.at) / 1000)
      items[i].rate = items[i].rate == 0 ? r : items[i].rate * 0.6 + r * 0.4
      samples[id] = (got, t)
    }
    changed(throttled: true)
  }

  public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                       completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
    let key = ObjectIdentifier(download)
    guard let id = ids[key] else { return completionHandler(nil) }
    let finish: @MainActor @Sendable (URL?) -> Void = { [weak self] u in
      guard let self, let i = self.index(id) else { return completionHandler(nil) }
      guard let u else {
        self.forget(key: key)
        self.items.remove(at: i)
        self.changed()
        return completionHandler(nil)
      }
      self.items[i].path = u.path
      self.items[i].name = u.lastPathComponent
      if response.expectedContentLength > 0 { self.items[i].total = response.expectedContentLength }
      self.save()
      self.host.emit("downloads.started", ["id": .string(id), "name": .string(u.lastPathComponent), "webview": .string(self.items[i].webview)])
      self.changed()
      completionHandler(u)
    }
    if asks.contains(ObjectIdentifier(download)) {
      let panel = NSSavePanel()
      panel.nameFieldStringValue = Self.safeName(suggestedFilename)
      panel.directoryURL = folder()
      let done: (NSApplication.ModalResponse) -> Void = { r in
        MainActor.assumeIsolated {
          guard r == .OK, let u = panel.url else { return finish(nil) }
          try? FileManager.default.removeItem(at: u)  // the panel already confirmed replacing it
          finish(u)
        }
      }
      if let w = download.webView?.window { panel.beginSheetModal(for: w, completionHandler: done) } else { done(panel.runModal()) }
      return
    }
    let dir = folder()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let reserved = Set(items.filter { $0.active || $0.state == "paused" }.map(\.path))
    finish(Self.uniqueURL(in: dir, name: suggestedFilename) { reserved.contains($0) || FileManager.default.fileExists(atPath: $0) })
  }

  public func downloadDidFinish(_ download: WKDownload) {
    guard let id = forget(download), let i = index(id) else { return }
    items[i].state = "done"
    items[i].finished = now()
    if items[i].total > 0 { items[i].received = items[i].total }
    items[i].resume = nil
    items[i].unseen = true
    Self.quarantine(URL(fileURLWithPath: items[i].path), from: items[i].url)
    save()
    host.emit("downloads.finished", ["id": .string(id), "name": .string(items[i].name), "ok": true])
    changed()
    releaseHelper()
  }

  public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
    guard let id = forget(download), let i = index(id) else { return }
    // Pausing cancels with resume data; that isn't a failure.
    if items[i].state == "paused" || items[i].state == "cancelled" { return }
    items[i].state = "failed"
    items[i].finished = now()
    items[i].error = Self.describe(error)
    items[i].resume = resumeData
    save()
    host.emit("downloads.finished", ["id": .string(id), "name": .string(items[i].name), "ok": false, "error": .string(items[i].error)])
    changed()
    releaseHelper()
  }

  @discardableResult
  func forget(_ d: WKDownload) -> String? { forget(key: ObjectIdentifier(d)) }

  @discardableResult
  func forget(key: ObjectIdentifier) -> String? {
    asks.remove(key)
    guard let id = ids.removeValue(forKey: key) else { return nil }
    live[id] = nil
    progress.removeValue(forKey: id)?.invalidate()
    samples[id] = nil
    return id
  }

  static func describe(_ error: Error) -> String {
    let e = error as NSError
    switch e.code {
    case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: return "Network connection lost"
    case NSURLErrorTimedOut: return "Timed out"
    case NSURLErrorCannotCreateFile, NSURLErrorCannotWriteToFile: return "Couldn’t save the file"
    case NSURLErrorFileDoesNotExist, NSURLErrorResourceUnavailable, NSURLErrorBadServerResponse: return "File unavailable"
    default: return "Download failed"
    }
  }

  /// Marks a downloaded file as coming from the internet, like Safari: Gatekeeper checks it on
  /// first open.
  static func quarantine(_ file: URL, from source: String) {
    var props: [String: Any] = [kLSQuarantineAgentNameKey as String: "den", kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String]
    if let u = URL(string: source) { props[kLSQuarantineDataURLKey as String] = u }
    var rv = URLResourceValues()
    rv.quarantineProperties = props
    var f = file
    try? f.setResourceValues(rv)
  }

  // MARK: Pause, resume, retry, cancel

  func pause(_ id: String) -> Value {
    guard let d = live[id], let i = index(id) else { return .error("downloads: \(id) isn't running") }
    items[i].state = "paused"
    items[i].rate = 0
    d.cancel { [weak self] data in
      MainActor.assumeIsolated {
        guard let self, let i = self.index(id) else { return }
        self.items[i].resume = data
        self.save()
        self.changed()
      }
    }
    forget(d)
    changed()
    return .ok
  }

  func resume(_ id: String) -> Value {
    guard let i = index(id), items[i].state == "paused" else { return .error("downloads: \(id) isn't paused") }
    guard let data = items[i].resume else { return retry(id) }
    guard let w = webView(items[i].webview) ?? helperWebView() else { return .error("downloads: no web view") }
    items[i].state = "downloading"
    items[i].resume = nil
    let path = items[i].path
    w.resumeDownload(fromResumeData: data) { [weak self] d in
      MainActor.assumeIsolated {
        guard let self else { return }
        // WebKit keeps the destination from the resume data; nothing asks for it again.
        self.adopt(d, id: id, ask: false)
        if let j = self.index(id), self.items[j].path.isEmpty { self.items[j].path = path }
      }
    }
    changed()
    return .ok
  }

  func retry(_ id: String) -> Value {
    guard let i = index(id), !items[i].active, let u = URL(string: items[i].url), u.scheme != nil else { return .error("downloads: can't retry \(id)") }
    guard let w = webView(items[i].webview) ?? helperWebView() else { return .error("downloads: no web view") }
    if !items[i].path.isEmpty, items[i].state != "done" { try? FileManager.default.removeItem(atPath: items[i].path) }
    items[i].state = "downloading"
    items[i].received = 0
    items[i].error = ""
    items[i].finished = 0
    items[i].resume = nil
    items[i].archived = false
    items[i].started = now()
    items.insert(items.remove(at: i), at: 0)
    w.startDownload(using: URLRequest(url: u)) { [weak self] d in MainActor.assumeIsolated { self?.adopt(d, id: id, ask: false) } }
    changed()
    return .ok
  }

  func cancel(_ id: String) -> Value {
    guard let i = index(id) else { return .error("downloads: no download \(id)") }
    let wasPaused = items[i].state == "paused"
    guard items[i].active || wasPaused else { return .error("downloads: \(id) isn't running") }
    items[i].state = "cancelled"
    items[i].finished = now()
    items[i].rate = 0
    items[i].resume = nil
    let path = items[i].path
    if let d = live[id] {
      forget(d)
      d.cancel { _ in MainActor.assumeIsolated { if !path.isEmpty { try? FileManager.default.removeItem(atPath: path) } } }
    } else if !path.isEmpty {
      try? FileManager.default.removeItem(atPath: path)
    }
    save()
    changed()
    releaseHelper()
    return .ok
  }

  func helperWebView() -> WKWebView? {
    if let helper { return helper }
    let w = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    helper = w
    return w
  }

  func releaseHelper() {
    guard helper != nil, live.isEmpty else { return }
    helper = nil
  }

  // MARK: Policy

  /// A response WebKit can't show, or one the server marks as an attachment, becomes a download.
  /// (A subframe's un-showable response stays a subframe error: pages shouldn't start downloads
  /// from hidden frames.)
  public nonisolated static func shouldDownload(canShow: Bool, mainFrame: Bool, disposition: String?) -> Bool {
    let attachment = disposition.map { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment") } ?? false
    return attachment || (mainFrame && !canShow)
  }
}
