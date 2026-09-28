import AppKit
import CordisValue
import DenTestSupport
import Foundation
import Network
import Testing
import UniformTypeIdentifiers
import WebKit

@testable import DenHost

/// Downloads (DownloadsService) through real WKWebViews and WebKit's own download path, the
/// Library's download rows, and the upload picker (UploadPicker) in front of a real file input.
@MainActor
@Suite(.serialized, .watchdog)
struct DownloadsTests {
  func runtime() -> (DenRuntime, URL) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("den-downloads-\(UUID())")
    let rt = DenRuntime(storageRoot: root)
    rt.webviews.configureHooks.append { _, c in c.preferences.inactiveSchedulingPolicy = .none }  // see ServiceTests.runtime
    rt.window.window.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 800), display: false)
    rt.window.window.contentView?.layoutSubtreeIfNeeded()
    let folder = root.appendingPathComponent("Downloads", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    rt.downloads.folder = { folder }
    return (rt, folder)
  }

  func page(_ rt: DenRuntime, url: String = "about:blank") -> (String, WKWebView) {
    let id = rt.call("webviews", "create", ["url": .string(url)])["id"].string!
    _ = rt.call("content", "show", ["panes": [.string(id)]])
    rt.content.releaseWebViews()
    return (id, rt.webviews.record(id)!.webView!)
  }

  func wait(_ what: String, seconds: Double = 20, line: UInt = #line, _ cond: () -> Bool) async -> Bool {
    await Wait.until(what, seconds: seconds, line: line) { cond() }
  }

  // MARK: Model

  @Test func namesPolicyAndStoredState() {
    #expect(DownloadsService.safeName("../etc/passwd") == "-etc-passwd")
    #expect(DownloadsService.safeName("  ") == "download")
    #expect(DownloadsService.safeName(".hidden.zip") == "hidden.zip")
    let dir = URL(fileURLWithPath: "/tmp/x")
    var taken: Set<String> = ["/tmp/x/report.zip", "/tmp/x/report 2.zip", "/tmp/x/README"]
    #expect(DownloadsService.uniqueURL(in: dir, name: "report.zip") { taken.contains($0) }.lastPathComponent == "report 3.zip")
    #expect(DownloadsService.uniqueURL(in: dir, name: "README") { taken.contains($0) }.lastPathComponent == "README 2")
    taken = []
    #expect(DownloadsService.uniqueURL(in: dir, name: "a.tar.gz") { taken.contains($0) }.lastPathComponent == "a.tar.gz")
    // A response WebKit can't show, or an attachment, downloads; a hidden frame's un-showable one doesn't.
    #expect(DownloadsService.shouldDownload(canShow: false, mainFrame: true, disposition: nil))
    #expect(DownloadsService.shouldDownload(canShow: true, mainFrame: true, disposition: "attachment; filename=\"a.pdf\""))
    #expect(DownloadsService.shouldDownload(canShow: true, mainFrame: false, disposition: " Attachment"))
    #expect(!DownloadsService.shouldDownload(canShow: true, mainFrame: true, disposition: "inline"))
    #expect(!DownloadsService.shouldDownload(canShow: false, mainFrame: false, disposition: nil))
    // Running at quit: interrupted. Paused with resume data: still paused.
    let running = DownloadsService.restore(["id": "d1", "url": "https://a.test/x.zip", "name": "x.zip", "path": "/tmp/x.zip", "state": "downloading", "started": 1])!
    #expect(running.state == "failed" && running.error == "Interrupted")
    let paused = DownloadsService.restore(DownloadsService.stored(.init(id: "d2", url: "u", name: "n", path: "/p", state: "paused", received: 5, total: 10, started: 1,
                                                                        resume: Data([1, 2, 3]))))!
    #expect(paused.state == "paused" && paused.resume == Data([1, 2, 3]) && paused.received == 5)
  }

  @Test func nothingIsReadUntilUsed() {
    let (rt, _) = runtime()
    #expect(rt.call("downloads", "summary") == ["active": 0, "unseen": 0, "progress": 1.0, "count": 0])
    // `open` without an id is the command bar's "Downloads" destination.
    var shown = 0
    rt.host.on("downloads.show") { _ in shown += 1 }
    #expect(rt.call("downloads", "open") == .ok && shown == 1)
    #expect(rt.call("downloads", "list")["items"] == [])
  }

  // MARK: Real downloads

  @Test func unshowableResponsesAndDownloadLinksLandInDownloads() async throws {
    let mock = MockServices()
    let zip = Data((0..<50_000).map { UInt8($0 % 251) })
    mock.files["/report.zip"] = ("application/zip", zip)
    mock.page("/links", "<a id=a href='/report.zip' download='renamed.zip'>get</a>")
    try mock.start()
    defer { mock.stop() }
    let (rt, folder) = runtime()
    var started: [Value] = [], finished: [Value] = [], changes = 0
    rt.host.on("downloads.started") { started.append($0) }
    rt.host.on("downloads.finished") { finished.append($0) }
    rt.host.on("downloads.changed") { _ in changes += 1 }
    let (id, web) = page(rt)

    // A navigation to a zip: WebKit can't show it, so it downloads and the page stays.
    rt.call("webviews", "navigate", ["id": .string(id), "url": .string(mock.base + "/report.zip")])
    #expect(await wait("the zip downloaded") { rt.downloads.items.first?.state == "done" })
    let first = try #require(rt.downloads.items.first)
    #expect(first.path == folder.appendingPathComponent("report.zip").path)
    #expect(try Data(contentsOf: URL(fileURLWithPath: first.path)) == zip)
    #expect(first.received == 50_000 && first.url == mock.base + "/report.zip")
    #expect(web.url?.absoluteString != mock.base + "/report.zip")
    #expect(started.first?["name"] == "report.zip" && started.first?["webview"] == .string(id))
    #expect(finished.first?["ok"] == true && changes >= 2)
    // Quarantined like Safari's downloads, so Gatekeeper checks it on first open.
    let q = try URL(fileURLWithPath: first.path).resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
    #expect(q?[kLSQuarantineAgentNameKey as String] as? String == "den")
    // Listed, new (the sidebar dot) until seen, and persisted.
    let list = rt.call("downloads", "list")
    #expect(list["unseen"] == 1 && list["items"][0]["exists"] == true && list["items"][0]["state"] == "done")
    #expect(rt.call("storage", "get", ["ns": "downloads", "key": "items"]).array?.count == 1)
    rt.call("downloads", "seen")
    #expect(rt.call("downloads", "summary")["unseen"] == 0)

    // The same file again gets Finder's " 2" name.
    rt.call("webviews", "navigate", ["id": .string(id), "url": .string(mock.base + "/report.zip")])
    #expect(await wait("the second copy") { rt.downloads.items.count == 2 && rt.downloads.items[0].state == "done" })
    #expect(rt.downloads.items[0].name == "report 2.zip")

    // <a download="renamed.zip">: a download with the page's name for it.
    rt.call("webviews", "navigate", ["id": .string(id), "url": .string(mock.base + "/links")])
    #expect(await wait("the links page") { !web.isLoading && web.url?.path == "/links" })
    _ = await Wait.js(web, "document.getElementById('a').click(); 1")
    #expect(await wait("the download link") { rt.downloads.items.count == 3 && rt.downloads.items[0].state == "done" })
    #expect(rt.downloads.items[0].name == "renamed.zip" && web.url?.path == "/links")

    // Remove takes it off the list; the file stays. Archive marks old finished ones.
    let path = rt.downloads.items[0].path
    rt.call("downloads", "remove", ["id": .string(rt.downloads.items[0].id)])
    #expect(rt.downloads.items.count == 2 && FileManager.default.fileExists(atPath: path))
    #expect(rt.call("downloads", "archive", ["before": .double(Date().timeIntervalSince1970 * 1000 + 1000)])["archived"] == 2)
    #expect(rt.call("downloads", "list")["items"][0]["archived"] == true)
    #expect(rt.call("downloads", "clear")["removed"] == 2 && rt.downloads.items.isEmpty)
    #expect(rt.call("storage", "get", ["ns": "downloads", "key": "items"]) == [])
  }

  @Test func pauseKeepsWhatArrivedAndResumeFinishesTheFile() async throws {
    let body = Data((0..<400_000).map { UInt8($0 % 253) })
    let server = TrickleServer(body: body)
    try server.start()
    defer { server.stop() }
    let (rt, folder) = runtime()
    let (id, _) = page(rt)
    rt.call("webviews", "navigate", ["id": .string(id), "url": .string(server.base + "/big.bin")])
    // The server sends half and holds the connection open: the download is running.
    #expect(await wait("half the bytes") { (rt.downloads.items.first?.received ?? 0) >= Int64(body.count / 2) })
    let d = try #require(rt.downloads.items.first)
    #expect(d.state == "downloading" && d.total == Int64(body.count) && d.path == folder.appendingPathComponent("big.bin").path)
    #expect(rt.call("downloads", "summary")["active"] == 1)
    #expect(rt.call("downloads", "pause", ["id": .string(d.id)]) == .ok)
    #expect(await wait("resume data") { rt.downloads.items.first?.resume != nil })
    #expect(rt.downloads.items.first?.state == "paused" && rt.call("downloads", "summary")["active"] == 0)
    // Resume asks the server for the rest (a Range request) and completes the same file.
    #expect(rt.call("downloads", "resume", ["id": .string(d.id)]) == .ok)
    #expect(await wait("the resumed download") { rt.downloads.items.first?.state == "done" })
    #expect(server.ranges.contains { $0.hasPrefix("bytes=") })
    #expect(try Data(contentsOf: folder.appendingPathComponent("big.bin")) == body)
  }

  @Test func cancelDeletesThePartialFile() async throws {
    let server = TrickleServer(body: Data(repeating: 1, count: 300_000))
    try server.start()
    defer { server.stop() }
    let (rt, folder) = runtime()
    let (id, _) = page(rt)
    rt.call("webviews", "navigate", ["id": .string(id), "url": .string(server.base + "/big.bin")])
    #expect(await wait("bytes arriving") { (rt.downloads.items.first?.received ?? 0) > 0 })
    let d = try #require(rt.downloads.items.first)
    #expect(rt.call("downloads", "cancel", ["id": .string(d.id)]) == .ok)
    #expect(rt.downloads.items.first?.state == "cancelled")
    let file = folder.appendingPathComponent("big.bin").path
    #expect(await wait("the partial file gone") { !FileManager.default.fileExists(atPath: file) })
    #expect(rt.call("downloads", "pause", ["id": .string(d.id)]).isError)
  }

  // MARK: Library rows

  @Test func libraryShowsDownloadRowsWithSectionsButtonsAndProgress() throws {
    let (rt, folder) = runtime()
    var got: [Value] = []
    rt.host.on("ui.action") { got.append($0) }
    let file = folder.appendingPathComponent("notes.pdf")
    FileManager.default.createFile(atPath: file.path, contents: Data("pdf".utf8))
    let t = 1_790_000_000_000.0
    _ = rt.call("ui", "set", ["slot": "overlay.library", "tree": [
      "type": "library", "id": "lib", "title": "Downloads", "icon": "sf:arrow.down.circle", "clearTitle": "",
      "sections": [["id": "archive", "title": "Archive", "keycap": "⌘Y"], ["id": "downloads", "title": "Downloads", "keycap": "⌥⌘L"]], "section": "downloads",
      "items": [
        ["id": "d2", "title": "movie.mov", "section": "In Progress", "subtitle": "3.2 MB of 40 MB · 12 s left", "progress": 0.08, "pill": "",
         "icon": "file:/nowhere/movie.mov", "buttons": [["id": "pause", "icon": "sf:pause.fill", "title": "Pause"], ["id": "cancel", "icon": "sf:xmark", "title": "Cancel"]]],
        ["id": "d1", "title": "notes.pdf", "subtitle": "3 bytes · {time}", "closedAt": .double(t), "pill": "", "file": .string(file.path),
         "icon": .string("file:" + file.path), "buttons": [["id": "reveal", "icon": "sf:magnifyingglass", "title": "Show in Finder"]]],
        ["id": "d0", "title": "gone.zip", "section": "Archived", "subtitle": "Moved or deleted", "dimmed": true, "pill": ""],
      ],
    ]])
    let lib = rt.ui.library
    #expect(lib.tabs.map(\.label.stringValue) == ["Archive", "Downloads"] && lib.tabs.map(\.keycap.text) == ["⌘Y", "⌥⌘L"])
    #expect(lib.tabs[1].selected && !lib.tabs[0].selected && lib.titleLabel.isHidden && lib.clearButton.isHidden)
    #expect(lib.headers.map(\.stringValue) == ["In Progress", LibraryView.section(for: t, now: Date()), "Archived"])
    #expect(lib.rows[1].subtitle.stringValue == "3 bytes · " + LibraryView.time(t))
    #expect(lib.rows[0].progress == 0.08 && lib.rows[0].buttons.count == 2 && !lib.rows[0].hasPill)
    #expect(lib.rows[1].file == file.path && lib.rows[2].alphaValue < 1)
    lib.layoutSubtreeIfNeeded()
    lib.rows[0].layoutSubtreeIfNeeded()
    #expect(!lib.rows[0].bar.isHidden && lib.rows[0].barFill.frame.width > 0)
    lib.rows[0].buttons[0].action()
    #expect(got.last?["action"] == "button" && got.last?["value"] == ["item": "d2", "button": "pause"])
    lib.tabs[0].onClick?()
    #expect(got.last?["action"] == "section" && got.last?["value"]["id"] == "archive")
    lib.rows[1].onRestore?()
    #expect(got.last?["action"] == "restore" && got.last?["value"]["item"] == "d1")
    // A progress update reuses the rows (a hovered Pause button stays the same view).
    let pause = lib.rows[0].buttons[0]
    _ = rt.call("ui", "set", ["slot": "overlay.library", "tree": lib.node.with("items", .array([lib.node["items"][0].with("progress", 0.5)]))])
    #expect(lib.rows.count == 1 && lib.rows[0].buttons[0] === pause && lib.rows[0].progress == 0.5)
    // Finder's icon for the file type, even when the file is gone.
    #expect(IconView.fileIcon("/nowhere/movie.mov").size.width > 0)
  }

  // MARK: Upload picker

  @Test func uploadPickerOffersRecentDownloadsScreenshotsAndTheClipboard() throws {
    let (rt, folder) = runtime()
    let picker = try #require(rt.webviews.uploadPicker)
    let now = Date()
    picker.now = { now }
    // A finished download (a real file) and an old one.
    let pdf = folder.appendingPathComponent("invoice.pdf")
    FileManager.default.createFile(atPath: pdf.path, contents: Data("%PDF".utf8))
    let ms = now.timeIntervalSince1970 * 1000
    rt.call("storage", "set", ["ns": "downloads", "key": "items", "value": [
      ["id": "d2", "url": "https://a.test/invoice.pdf", "name": "invoice.pdf", "path": .string(pdf.path), "state": "done", "started": .double(ms - 60_000), "finished": .double(ms - 60_000)],
      ["id": "d1", "url": "https://a.test/old.pdf", "name": "old.pdf", "path": .string(pdf.path), "state": "done", "started": 1, "finished": 1],
    ]])
    // Screenshots in the screenshot folder: a fresh one, a week-old one, and a file that isn't one.
    let shots = folder.appendingPathComponent("shots", isDirectory: true)
    try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
    let fresh = shots.appendingPathComponent("Screenshot 2026-09-28 at 10.00.00.png")
    let stale = shots.appendingPathComponent("Screenshot 2026-09-01 at 10.00.00.png")
    for u in [fresh, stale, shots.appendingPathComponent("notes.png")] { FileManager.default.createFile(atPath: u.path, contents: Self.png) }
    try FileManager.default.setAttributes([.creationDate: now.addingTimeInterval(-8 * 86_400)], ofItemAtPath: stale.path)
    picker.screenshotFolder = { shots }
    // An image on a private pasteboard.
    let pb = NSPasteboard.withUniqueName()
    pb.clearContents()
    pb.setData(Self.png, forType: .png)
    picker.pasteboard = pb

    let any = UploadPicker.Request()
    let list = picker.candidates(any)
    #expect(list.map(\.kind) == [.download, .screenshot, .clipboard])
    #expect(list[0].title == "invoice.pdf" && list[0].subtitle == "Downloaded 1 min ago" && list[0].icon == "file:" + pdf.path)
    #expect(list[1].url?.lastPathComponent == fresh.lastPathComponent && list[1].icon.hasSuffix(fresh.lastPathComponent) && !list[1].icon.hasPrefix("file:"))
    #expect(list[1].subtitle == "Screenshot · just now")
    #expect(list[2].title == "Copied image")
    // `accept="image/*"`: no PDF. A folder input: straight to the panel.
    let images = picker.candidates(UploadPicker.Request(mimeTypes: ["image/*"]))
    #expect(images.map(\.kind) == [.screenshot, .clipboard])
    #expect(picker.candidates(UploadPicker.Request(directories: true)).isEmpty)
    #expect(picker.candidates(UploadPicker.Request(extensions: ["docx"])).isEmpty)
    #expect(UploadPicker.Request(mimeTypes: ["application/pdf"]).accepts(pdf) && !UploadPicker.Request(mimeTypes: ["application/pdf"]).accepts(fresh))
    #expect(UploadPicker.Request(extensions: ["pdf"]).accepts(pdf))
    // Picking the clipboard image saves it as a PNG then.
    let files = picker.files(for: [list[2]], request: any)
    #expect(files.count == 1 && files[0].pathExtension == "png" && FileManager.default.fileExists(atPath: files[0].path))
    // The dialog's tree: choices, Choose File… (⌘O), Cancel, Upload.
    let tree = UploadPicker.tree(list, request: any, host: "mail.example")
    #expect(tree["title"] == "Upload to mail.example" && tree["choices"].array?.count == 3)
    #expect((tree["buttons"].array ?? []).map { $0.str("id") } == ["choose", "cancel", "upload"] && tree["buttons"][0]["keycap"] == "⌘O")
  }

  @Test func uploadPickerAnswersARealFileInput() async throws {
    let (rt, folder) = runtime()
    let file = folder.appendingPathComponent("notes.txt")
    try Data("hello".utf8).write(to: file)
    let picker = try #require(rt.webviews.uploadPicker)
    picker.fixed = { _ in [UploadPicker.Candidate(id: "download:d1", kind: .download, title: "notes.txt", subtitle: "Downloaded just now", icon: "file:" + file.path, url: file, date: Date())] }
    rt.window.window.orderFront(nil)
    let (_, web) = page(rt)
    web.loadHTMLString("<style>body{margin:0}input{display:block;width:100vw;height:100vh}</style><input type=file onchange=\"document.title='files:'+this.files.length+':'+this.files[0].name\">",
                       baseURL: URL(string: "https://upload.test/"))
    #expect(await wait("the page") { !web.isLoading && web.url?.host == "upload.test" })
    try await Task.sleep(for: .milliseconds(300))
    let win = try #require(web.window)
    let p = web.convert(NSPoint(x: web.bounds.midX, y: web.bounds.midY), to: nil)
    let target = try #require(web.hitTest(web.superview!.convert(p, from: nil)))
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      let e = try #require(NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
      if type == .leftMouseDown { target.mouseDown(with: e) } else { target.mouseUp(with: e) }
    }
    let prompts = try #require(rt.webviews.prompts)
    #expect(await wait("the picker") { prompts.visible })
    #expect(prompts.current?.tree["title"] == "Upload to upload.test" && prompts.current?.tree["choices"][0]["id"] == "download:d1")
    let d = try #require(rt.window.overlays.subviews.compactMap { $0 as? DialogView }.last)
    #expect(d.choices.count == 1 && d.choices[0].selected && d.selectedChoices == ["download:d1"])
    // One click on the row uploads it (a single-file input).
    d.choiceClicked(0)
    #expect(await wait("the page got the file") { web.title == "files:1:notes.txt" })
    #expect(!prompts.visible)
  }

  static let png: Data = {
    let img = NSImage(size: NSSize(width: 4, height: 4))
    img.lockFocus()
    NSColor.systemPink.setFill()
    NSRect(x: 0, y: 0, width: 4, height: 4).fill()
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
  }()
}

/// A local HTTP server that sends the first half of a file and then holds the connection open
/// (a download that's running), and answers `Range: bytes=N-` with the rest (206), so pause and
/// resume go through WebKit's real resume path.
final class TrickleServer: @unchecked Sendable {
  let body: Data
  private var listener: NWListener?
  private let queue = DispatchQueue(label: "den.trickle")
  private let lock = NSLock()
  private var _ranges: [String] = []
  private var open: [NWConnection] = []
  var ranges: [String] { lock.withLock { _ranges } }
  private(set) var port: UInt16 = 0
  var base: String { "http://127.0.0.1:\(port)" }

  init(body: Data) { self.body = body }

  func start() throws {
    let params = NWParameters.tcp
    params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
    let l = try NWListener(using: params)
    let ready = DispatchSemaphore(value: 0)
    l.stateUpdateHandler = { s in if case .ready = s { ready.signal() }; if case .failed = s { ready.signal() } }
    l.newConnectionHandler = { [weak self] c in self?.serve(c) }
    l.start(queue: queue)
    _ = ready.wait(timeout: .now() + 5)
    port = l.port?.rawValue ?? 0
    listener = l
  }

  func stop() {
    listener?.cancel()
    lock.withLock { open.forEach { $0.cancel() } }
  }

  func serve(_ c: NWConnection) {
    c.start(queue: queue)
    lock.withLock { open.append(c) }
    var buffer = Data()
    func read() {
      c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
        guard let self else { return c.cancel() }
        if let data { buffer.append(data) }
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
          if done || error != nil { c.cancel() } else { read() }
          return
        }
        let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let range = head.first { $0.lowercased().hasPrefix("range:") }.map { $0.dropFirst(6).trimmingCharacters(in: .whitespaces) }
        let common = "Content-Type: application/octet-stream\r\nAccept-Ranges: bytes\r\nETag: \"den-v1\"\r\nLast-Modified: Mon, 28 Sep 2026 10:00:00 GMT\r\n"
        if let range, range.hasPrefix("bytes="), let from = Int(range.dropFirst(6).split(separator: "-").first ?? "") {
          self.lock.withLock { self._ranges.append(range) }
          let rest = self.body.subdata(in: from..<self.body.count)
          let h = "HTTP/1.1 206 Partial Content\r\n\(common)Content-Range: bytes \(from)-\(self.body.count - 1)/\(self.body.count)\r\nContent-Length: \(rest.count)\r\nConnection: close\r\n\r\n"
          c.send(content: Data(h.utf8) + rest, completion: .contentProcessed { _ in c.cancel() })
        } else {
          let h = "HTTP/1.1 200 OK\r\n\(common)Content-Length: \(self.body.count)\r\nConnection: keep-alive\r\n\r\n"
          c.send(content: Data(h.utf8) + self.body.prefix(self.body.count / 2), completion: .contentProcessed { _ in })
        }
      }
    }
    read()
  }
}
