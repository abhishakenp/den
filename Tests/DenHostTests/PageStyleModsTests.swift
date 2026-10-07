import AppKit
import CordisValue
import Foundation
import DenTestSupport
import Testing
import WebKit

@testable import DenHost

@MainActor
@Suite(.serialized, .watchdog)
struct PageStyleModsTests {
  static func runtime() -> DenRuntime {
    _ = NSApplication.shared
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("den-psm-\(UUID())")
    let rt = DenRuntime(storageRoot: dir)
    rt.window.window.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 800), display: false)
    return rt
  }

  @Test func modStructBasic() {
    let m = PageStyleService.Mod(name: "test", css: "body{color:red}", js: "alert(1)", hosts: ["test.com"])
    #expect(m.name == "test")
    #expect(m.css == "body{color:red}")
    #expect(m.js == "alert(1)")
    #expect(m.hosts == ["test.com"])
  }

  @Test func modStructDefaults() {
    let m = PageStyleService.Mod(name: "x", css: ".a{b}")
    #expect(m.js == "")
    #expect(m.hosts == [])
  }

  @Test func modStructEquatable() {
    let a = PageStyleService.Mod(name: "t", css: "x", js: "y", hosts: ["z"])
    let b = PageStyleService.Mod(name: "t", css: "x", js: "y", hosts: ["z"])
    #expect(a == b)
    #expect(a != PageStyleService.Mod(name: "t", css: "other", js: "y", hosts: ["z"]))
  }

  @Test func hostKeyNormalization() {
    #expect(PageStyleService.key("WWW.Example.com.") == "example.com")
    #expect(PageStyleService.key("example.com") == "example.com")
    #expect(PageStyleService.key("") == "")
  }

  @Test func pageHostExtraction() {
    #expect(PageStyleService.pageHost(of: URL(string: "https://www.example.com/path")?) == "example.com")
    #expect(PageStyleService.pageHost(of: URL(string: "https://sub.example.com")?) == "sub.example.com")
    #expect(PageStyleService.pageHost(of: nil) == "")
  }

  @Test func modsDefineAddsMod() {
    let rt = Self.runtime()
    let result = rt.call("mods.define", ["name": "darkify", "css": "body{background:#000}"])
    #expect(result.isError == false)
    let list = rt.call("mods.list").array!
    #expect(list.count == 1)
    #expect(list[0]["name"].string == "darkify")
    #expect(list[0]["css"].string == "body{background:#000}")
  }

  @Test func modsDefineWithJsAndHosts() {
    let rt = Self.runtime()
    _ = rt.call("mods.define", ["name": "custom", "css": ".x{}", "js": "document.body.style.opacity=0.5", "hosts": ["github.com"]])
    let list = rt.call("mods.list").array!
    #expect(list[0]["js"].string == "document.body.style.opacity=0.5")
    #expect(list[0]["hosts"].array!.map(\.s) == ["github.com"])
  }

  @Test func modsDefineEmptyNameFails() {
    let rt = Self.runtime()
    #expect(rt.call("mods.define", ["name": "", "css": "body{}"]).isError)
  }

  @Test func modsListEmpty() {
    let rt = Self.runtime()
    #expect(rt.call("mods.list").array!.isEmpty)
  }

  @Test func modsListSorted() {
    let rt = Self.runtime()
    _ = rt.call("mods.define", ["name": "zebra", "css": ".z{}"])
    _ = rt.call("mods.define", ["name": "alpha", "css": ".a{}"])
    let list = rt.call("mods.list").array!
    #expect(list[0]["name"].string == "alpha")
    #expect(list[1]["name"].string == "zebra")
  }

  @Test func modsRemoveDeletesMod() {
    let rt = Self.runtime()
    _ = rt.call("mods.define", ["name": "todelete", "css": "x{}"])
    #expect(rt.call("mods.list").array!.count == 1)
    _ = rt.call("mods.remove", ["name": "todelete"])
    #expect(rt.call("mods.list").array!.isEmpty)
  }

  @Test func loadModsFromDiskScansDirectories() throws {
    let rt = Self.runtime()
    let root = PageStyleService.modsRoot
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let testDir = root.appendingPathComponent("test-scan-mod", isDirectory: true)
    try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
    try "body{background:black}".write(to: testDir.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
    let result = rt.call("mods.scan")
    #expect(result["count"].int == 1)
    let list = rt.call("mods.list").array!
    #expect(list.contains { $0["name"].string == "test-scan-mod" })
    try? FileManager.default.removeItem(at: testDir)
  }

  @Test func loadModsFromDiskSkipsInvalidDirs() throws {
    let rt = Self.runtime()
    let root = PageStyleService.modsRoot
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let badDir = root.appendingPathComponent("no-css-dir", isDirectory: true)
    try FileManager.default.createDirectory(at: badDir, withIntermediateDirectories: true)
    let result = rt.call("mods.scan")
    #expect(result["count"].int == 0)
    try? FileManager.default.removeItem(at: badDir)
  }

  @Test func loadModsFromDiskReadsJsAndHosts() throws {
    let rt = Self.runtime()
    let root = PageStyleService.modsRoot
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let modDir = root.appendingPathComponent("full-mod", isDirectory: true)
    try FileManager.default.createDirectory(at: modDir, withIntermediateDirectories: true)
    try "body{color:red}".write(to: modDir.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
    try "alert('loaded')".write(to: modDir.appendingPathComponent("script.js"), atomically: true, encoding: .utf8)
    let hostsData = "[\"example.com\"]"
    try hostsData.write(to: modDir.appendingPathComponent("hosts.json"), atomically: true, encoding: .utf8)
    let result = rt.call("mods.scan")
    #expect(result["count"].int == 1)
    let list = rt.call("mods.list").array!
    let mod = list.first { $0["name"].string == "full-mod" }
    #expect(mod?["js"].string == "alert('loaded')")
    #expect(mod?["hosts"].array!.map(\.s) == ["example.com"])
    try? FileManager.default.removeItem(at: modDir)
  }

  @Test func modsApplyWithHostsScopesToMatchingPage() throws {
    let rt = Self.runtime()
    _ = rt.call("pagestyle", "rules", ["default": ["sheets": []], "hosts": [:]])
    _ = rt.call("mods.define", ["name": "scoped", "css": "body{color:purple!important}", "hosts": ["mod.test"]])
    let id = rt.call("webviews", "create", ["url": "https://mod.test/"])["id"].string!
    let w = try #require(rt.webviews.record(id)?.webView)
    w.loadHTMLString("<p>test</p>", baseURL: URL(string: "https://mod.test/"))
    try await Wait.until("page loads", seconds: 20) { !w.isLoading && w.url?.host == "mod.test" }
  }

  @Test func modsRootPointsToApplicationSupport() {
    let url = PageStyleService.modsRoot
    #expect(url.path.hasSuffix("den/mods"))
    #expect(url.path.contains("Application Support"))
  }
}
