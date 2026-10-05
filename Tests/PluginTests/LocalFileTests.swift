import AppKit
import CordisValue
import DenTestSupport
import Foundation
import Testing
import WebKit

@testable import DenHost
@testable import PluginCores

/// Local files typed in the command bar (`CommandFiles.swift`, host `LocalFiles`): a path opens
/// the file in a tab, never a web search; a folder shows in Finder; typing a path lists its
/// folder's files.
@MainActor
@Suite(.serialized, .watchdog)
struct LocalFileTests {
  /// A folder with `My Report.html` (styled by `assets/style.css`), `notes.txt`, `sub/`, `.hidden`.
  func folder() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("den-files-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: d.appendingPathComponent("assets"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: d.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try #"<html><head><title>Local report</title><link rel="stylesheet" href="assets/style.css"></head><body><p id="p">hi</p></body></html>"#
      .write(to: d.appendingPathComponent("My Report.html"), atomically: true, encoding: .utf8)
    try "p { color: rgb(1, 2, 3); }".write(to: d.appendingPathComponent("assets/style.css"), atomically: true, encoding: .utf8)
    try "notes".write(to: d.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    try "x".write(to: d.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
    return d
  }

  func todayURLs(_ h: Harness) -> [String] { (h.tabs("list")["today"].array ?? []).map { $0.s("url") } }

  @Test func typedPathsOpenTheFileInATabNeverASearch() async throws {
    let h = Harness()
    h.startCommandBar()
    let d = try folder()
    let file = d.appendingPathComponent("My Report.html")
    let escaped = file.path.replacingOccurrences(of: " ", with: "\\ ")
    for typed in [file.path, "file://" + file.path, file.absoluteString, "'" + file.path + "'", escaped, " " + file.path + " "] {
      h.key("cmd+t")
      h.type(typed)
      let first = h.barRows.first
      #expect(first?.str("id") == "go", "\(typed)")
      #expect(first?.str("subtitle") == "— Open File", "\(typed)")
      #expect(first?.str("icon") == "file:" + file.path, "\(typed)")
      #expect(!h.barRowIds.contains("search"), "\(typed)")
      #expect(h.bar.str("inputMode") == "go", "\(typed)")
      #expect(h.suggestRequests.isEmpty, "a path is never sent to the suggestion service: \(typed)")
      let n = h.ids("today").count
      h.submit()
      #expect(!h.rt.ui.commandBarOpen)
      #expect(h.ids("today").count == n + 1, "\(typed)")
      #expect(todayURLs(h).last == file.absoluteString || todayURLs(h).first == file.absoluteString, "\(typed): \(todayURLs(h))")
    }

    // The tab really shows the file, with its stylesheet from the same folder.
    let id = try #require(h.selected)
    let w = try #require(h.rt.webviews.materialize(id))
    if w.superview == nil {
      w.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
      h.rt.window.window.contentView?.addSubview(w)
    }
    #expect(await Wait.until("the local file to load") { !w.isLoading && w.title == "Local report" })
    #expect(await Wait.js(w, "getComputedStyle(document.getElementById('p')).color").map { "\($0)" } == "rgb(1, 2, 3)")

    // Cmd-L and a path: the current tab goes there.
    let notes = d.appendingPathComponent("notes.txt")
    let count = h.ids("today").count
    h.key("cmd+l")
    h.type(notes.path)
    #expect(h.barRows.first?.str("subtitle") == "— Go to File")
    h.submit()
    #expect(h.ids("today").count == count)
    #expect(h.rt.call("webviews", "get", ["id": .string(id)]).s("url") == notes.absoluteString)

    // A path that doesn't exist stays a search.
    h.key("cmd+t")
    h.type(d.path + "/missing.html")
    #expect(h.barRowIds.first == "search", "\(h.barRows)")
    h.action("commandBar", "dismiss")
  }

  /// A local page reads only its own folder and subfolders: a stylesheet beside its parent folder
  /// (`../other/evil.css`) doesn't load, and neither `fetch` of a sibling folder's file nor of
  /// ~/.ssh/known_hosts gets anything. The same stylesheet does load for a page whose folder holds
  /// it (so the check isn't vacuous), and a subfolder's stylesheet loads.
  @Test func localPagesCantReadOutsideTheirFolder() async throws {
    let h = Harness()
    // In the home folder, not $TMPDIR: WebKit's WebContent sandbox may read the app's temporary
    // folder on its own, which would let `../other` load whatever den granted.
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("den-sandbox-test-\(UUID().uuidString)").resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    for d in ["site/sub", "other"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true) }
    try "#q { color: rgb(9, 9, 9); }".write(to: root.appendingPathComponent("other/evil.css"), atomically: true, encoding: .utf8)
    try "secret".write(to: root.appendingPathComponent("other/secret.txt"), atomically: true, encoding: .utf8)
    try "#p { color: rgb(1, 2, 3); }".write(to: root.appendingPathComponent("site/sub/ok.css"), atomically: true, encoding: .utf8)
    try #"<title>page</title><link rel="stylesheet" href="sub/ok.css"><link rel="stylesheet" href="../other/evil.css"><p id="p">p</p><p id="q">q</p>"#
      .write(to: root.appendingPathComponent("site/page.html"), atomically: true, encoding: .utf8)
    try #"<title>control</title><link rel="stylesheet" href="other/evil.css"><p id="q">q</p>"#
      .write(to: root.appendingPathComponent("control.html"), atomically: true, encoding: .utf8)
    #expect(LocalFiles.readAccess(for: root.appendingPathComponent("site/page.html")).path == root.appendingPathComponent("site").path)

    func open(_ id: String, _ file: URL) async throws -> WKWebView {
      h.rt.call("webviews", "create", ["id": .string(id), "url": .string(file.path)])
      let w = try #require(h.rt.webviews.materialize(id))
      w.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
      h.rt.window.window.contentView?.addSubview(w)
      #expect(await Wait.until("\(file.lastPathComponent) to load") { !w.isLoading && w.url == file })
      return w
    }
    let color = "getComputedStyle(document.getElementById('q')).color"
    let page = try await open("page", root.appendingPathComponent("site/page.html"))
    #expect(await Wait.until("the subfolder's stylesheet") { await Wait.js(page, "getComputedStyle(document.getElementById('p')).color").map { "\($0)" } == "rgb(1, 2, 3)" })
    #expect(await Wait.js(page, color).map { "\($0)" } != "rgb(9, 9, 9)", "../other/evil.css must not load")
    let home = FileManager.default.homeDirectoryForCurrentUser
    for target in [root.appendingPathComponent("other/secret.txt"), home.appendingPathComponent(".ssh/known_hosts")] {
      let got = await Wait.asyncJS(page, "try { const r = await fetch('\(target.absoluteString)'); return 'read:' + (await r.text()).length } catch (e) { return 'blocked' }")
      #expect(got as? String == "blocked", "\(target.path): \(String(describing: got))")
    }

    // Control (after: WebKit's read grants add up in a WebContent process): from a page whose
    // folder holds it, the same stylesheet loads, so the block above isn't vacuous.
    let control = try await open("control", root.appendingPathComponent("control.html"))
    #expect(await Wait.until("the control page's stylesheet") { await Wait.js(control, color).map { "\($0)" } == "rgb(9, 9, 9)" })
    // Does the earlier page now share the wider grant (one WebContent process)? Logged, not asserted.
    page.reload()
    _ = await Wait.until("page reloaded") { !page.isLoading }
    let after = await Wait.js(page, color).map { "\($0)" } ?? "nil"
    print("local-sandbox: page after control loaded: \(after) pid page=\(page.value(forKey: "_webProcessIdentifier") ?? "?") control=\(control.value(forKey: "_webProcessIdentifier") ?? "?")")
  }

  @Test func readAccessIsNeverHomeLibraryOrADotFolder() {
    let home = "/Users/me"
    let access = { (p: String) in LocalFiles.readAccess(for: URL(fileURLWithPath: p), home: home).path }
    #expect(access("/Users/me/proj/site/index.html") == "/Users/me/proj/site")
    #expect(access("/Users/me/Downloads/a.html") == "/Users/me/Downloads")  // a download: its own folder, never more
    #expect(access("/Users/me/a.html") == "/Users/me/a.html")  // in home itself: the file only
    #expect(access("/Users/a.html") == "/Users/a.html" && access("/a.html") == "/a.html" && access("/tmp/a.html") == "/tmp/a.html")
    #expect(access("/Users/me/Library/Caches/x/a.html") == "/Users/me/Library/Caches/x/a.html")
    #expect(access("/Users/me/Library/a.html") == "/Users/me/Library/a.html")
    #expect(access("/Users/me/.ssh/a.html") == "/Users/me/.ssh/a.html" && access("/Users/me/proj/.git/a.html") == "/Users/me/proj/.git/a.html")
    #expect(access("/tmp/x/y.html") == "/tmp/x")
  }

  @Test func typingAPathListsItsFolderLikeFinder() throws {
    let h = Harness()
    h.startCommandBar()
    var revealed: [URL] = []
    let saved = LocalFiles.reveal
    LocalFiles.reveal = { revealed.append($0) }
    defer { LocalFiles.reveal = saved }
    let d = try folder()

    // A folder: Enter shows it in Finder; its entries follow, in Finder's order, no hidden files.
    h.key("cmd+t")
    h.type(d.path + "/")
    #expect(h.barRows.first?.str("id") == "go")
    #expect(h.barRows.first?.str("subtitle") == "— Show in Finder")
    let files = h.bar.list("sections").first { $0.str("title") == "Files" }?.list("rows").map { $0.str("title") }
    #expect(files == ["assets/", "My Report.html", "notes.txt", "sub/"])
    h.submit()
    #expect(revealed.map(\.path) == [d.path])
    #expect(!h.rt.ui.commandBarOpen)

    // A partial name: the first match is the first row, and Enter opens it.
    h.key("cmd+t")
    h.type(d.path + "/NO")
    #expect(h.barRowIds.first == "file:" + d.appendingPathComponent("notes.txt").path)
    #expect(h.bar.list("sections").first?.str("title") == "Files")
    h.submit()
    #expect(todayURLs(h).contains(d.appendingPathComponent("notes.txt").absoluteString))

    // Enter on a folder match goes into it; Tab completes the selected match.
    h.key("cmd+t")
    h.type(d.path + "/su")
    h.submit()
    #expect(h.rt.ui.commandBarOpen)
    #expect(h.bar.str("query") == d.path + "/sub/")
    h.type(d.path + "/as")
    h.action("commandBar", "tab", ["query": .string(d.path + "/as")])
    #expect(h.bar.str("query") == d.path + "/assets/")
    h.type(d.path + "/.h")
    #expect(h.barRows.map { $0.str("title") }.contains(".hidden"))
    h.action("commandBar", "dismiss")

    // An app (a package) shows in Finder rather than loading in a tab, typed or completed.
    h.key("cmd+t")
    h.type("/System/Applications/Calculator.app")
    #expect(h.barRows.first?.str("subtitle") == "— Show in Finder")
    h.submit()
    #expect(revealed.last?.path == "/System/Applications/Calculator.app")
    h.key("cmd+t")
    h.type("/System/Applications/Calcul")
    #expect(h.barRowIds.first == "file:/System/Applications/Calculator.app")
    let n = revealed.count
    h.submit()
    #expect(revealed.count == n + 1 && !todayURLs(h).contains { $0.hasSuffix("Calculator.app/") || $0.hasSuffix("Calculator.app") })

    // Home-relative paths complete in the same form.
    h.key("cmd+t")
    h.type("~/")
    #expect(h.barRows.first?.str("subtitle") == "— Show in Finder")
    #expect(h.barRows.dropFirst().allSatisfy { !$0.str("title").hasPrefix(".") })
    h.action("commandBar", "dismiss")
  }

  @Test func pasteAndGoOpensFiles() throws {
    let h = Harness()
    h.startCommandBar()
    var revealed: [URL] = []
    let saved = LocalFiles.reveal
    LocalFiles.reveal = { revealed.append($0) }
    defer { LocalFiles.reveal = saved }
    let d = try folder()
    let file = d.appendingPathComponent("My Report.html")
    #expect(PasteText.isURL(file.path) && PasteText.isURL("'" + file.path + "'"))
    #expect(!PasteText.isURL(d.path + "/missing.html"))
    #expect(h.rt.call("commands", "paste", ["text": .string(file.path)]) == ["kind": "file", "url": .string(file.absoluteString)])
    #expect(todayURLs(h).contains(file.absoluteString))
    #expect(h.rt.call("commands", "paste", ["text": .string(d.path)])["kind"] == "folder")
    #expect(revealed.map(\.path) == [d.path])
  }

  @Test func hostParsesPathsAndGrantsReadAccess() throws {
    let d = try folder()
    let file = d.appendingPathComponent("My Report.html")
    #expect(LocalFiles.url("/tmp/My\\ File.pdf")?.path == "/tmp/My File.pdf")
    #expect(LocalFiles.url("\"/tmp/a b.html\"")?.path == "/tmp/a b.html")
    #expect(LocalFiles.url("file:///tmp/a b.html")?.path == "/tmp/a b.html")
    #expect(LocalFiles.url("FILE:///tmp/a%20b.html")?.path == "/tmp/a b.html")
    #expect(LocalFiles.url("~/x")?.path == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("x").path)
    #expect(LocalFiles.url("//cdn.example.com/x") == nil && LocalFiles.url("example.com") == nil && LocalFiles.url("hello world") == nil)
    #expect(LocalFiles.existing(file.path)?.folder == false && LocalFiles.existing(d.path)?.folder == true)
    #expect(LocalFiles.existing("/Applications/Safari.app")?.folder != true)  // a package opens as a file
    #expect(LocalFiles.existing(d.path + "/nope") == nil)
    // `webviews` takes the same paths (and a file:// URL with a space) as file URLs.
    #expect(WebViewsService.normalize(file.path) == file)
    #expect(WebViewsService.normalize("file://" + file.path) == file)
    #expect(WebViewsService.normalize("/nope/nothing") == nil)
    // Read access: the file's own folder (see readAccessIsNeverHomeLibraryOrADotFolder).
    let home = FileManager.default.homeDirectoryForCurrentUser
    #expect(LocalFiles.readAccess(for: home.appendingPathComponent("a/b/c.html")).standardizedFileURL.path == home.appendingPathComponent("a/b").standardizedFileURL.path)
    // app.fileInfo / app.completePath
    let h = Harness()
    let info = h.rt.call("app", "fileInfo", ["path": .string(file.path)])
    #expect(info.str("url") == file.absoluteString && info.flag("exists") && !info.flag("folder"))
    #expect(h.rt.call("app", "fileInfo", ["path": "/nope"]) == ["exists": false])
    #expect(h.rt.call("app", "completePath", ["path": .string(d.path + "/n")]).list("items").map { $0.str("name") } == ["notes.txt"])
  }
}
