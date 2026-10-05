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
    // Read access: the home folder for a file inside it (relative `../` assets load), else its folder.
    let home = FileManager.default.homeDirectoryForCurrentUser
    #expect(LocalFiles.readAccess(for: home.appendingPathComponent("a/b/c.html")).standardizedFileURL.path == home.standardizedFileURL.path)
    #expect(LocalFiles.readAccess(for: URL(fileURLWithPath: "/tmp/x/y.html")).path == "/tmp/x")
    // app.fileInfo / app.completePath
    let h = Harness()
    let info = h.rt.call("app", "fileInfo", ["path": .string(file.path)])
    #expect(info.str("url") == file.absoluteString && info.flag("exists") && !info.flag("folder"))
    #expect(h.rt.call("app", "fileInfo", ["path": "/nope"]) == ["exists": false])
    #expect(h.rt.call("app", "completePath", ["path": .string(d.path + "/n")]).list("items").map { $0.str("name") } == ["notes.txt"])
  }
}
