import Foundation
import JavaScriptCore
import DenTestSupport
import Testing

@testable import DenHost

@Suite(.watchdog)
struct ExtensionPackageTests {
  static func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("den-ext-\(UUID())")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
  }

  /// A folder with `manifest`, zipped with ditto, as ZIP bytes.
  static func zipped(_ manifest: String, extra: [String: String] = [:]) throws -> Data {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(at: d) }
    let src = d.appendingPathComponent("src")
    try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    try manifest.write(to: src.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    for (k, v) in extra { try v.write(to: src.appendingPathComponent(k), atomically: true, encoding: .utf8) }
    let zip = d.appendingPathComponent("x.zip")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    p.arguments = ["-c", "-k", src.path, zip.path]
    try p.run()
    p.waitUntilExit()
    return try Data(contentsOf: zip)
  }

  static func le32(_ n: Int) -> Data { Data([UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 24 & 0xFF)]) }

  @Test func storeURLs() {
    let cws = URL(string: "https://chromewebstore.google.com/detail/ublock-origin-lite/ddkjiahejlhfcafbddmgiahcphecmpfh?hl=en")!
    #expect(ExtensionPackage.storeRef(for: cws) == StoreRef(source: .chrome, id: "ddkjiahejlhfcafbddmgiahcphecmpfh"))
    #expect(ExtensionPackage.storeRef(for: URL(string: "https://chromewebstore.google.com/detail/ddkjiahejlhfcafbddmgiahcphecmpfh")!)?.id == "ddkjiahejlhfcafbddmgiahcphecmpfh")
    #expect(ExtensionPackage.storeRef(for: URL(string: "https://chrome.google.com/webstore/detail/x/bhlhnicpbhignbdhedgjhgdocnmhomnp")!)?.id == "bhlhnicpbhignbdhedgjhgdocnmhomnp")
    #expect(ExtensionPackage.storeRef(for: URL(string: "https://chromewebstore.google.com/category/extensions")!) == nil)
    #expect(ExtensionPackage.storeRef(for: URL(string: "https://addons.mozilla.org/en-US/firefox/addon/darkreader/")!) == StoreRef(source: .firefox, id: "darkreader"))
    #expect(ExtensionPackage.storeRef(for: URL(string: "https://addons.mozilla.org/en-US/firefox/")!) == nil)
    #expect(ExtensionPackage.storeRef(for: URL(string: "https://example.com/detail/ddkjiahejlhfcafbddmgiahcphecmpfh")!) == nil)
    #expect(ExtensionPackage.crxDownloadURL(id: "abc", chromeVersion: "1.2").absoluteString.contains("x=id%3Dabc%26installsource%3Dondemand%26uc"))
  }

  @Test func chromeIds() {
    #expect(ExtensionPackage.isChromeId("ddkjiahejlhfcafbddmgiahcphecmpfh"))
    #expect(!ExtensionPackage.isChromeId("ddkjiahejlhfcafbddmgiahcphecmpfz"))
    // Chrome's documented example: the id is the a–p encoding of the key's SHA-256 prefix.
    let id = ExtensionPackage.chromeId(publicKey: Data("key".utf8))
    #expect(ExtensionPackage.isChromeId(id))
    #expect(ExtensionPackage.derivedId("a") == ExtensionPackage.derivedId("a"))
    #expect(ExtensionPackage.derivedId("a") != ExtensionPackage.derivedId("b"))
  }

  @Test func stripsCRX3AndCRX2() throws {
    let zip = try Self.zipped(#"{"manifest_version":3,"name":"T","version":"1.0"}"#)
    let header = Data(repeating: 7, count: 40)
    let crx3 = Data("Cr24".utf8) + Self.le32(3) + Self.le32(header.count) + header + zip
    #expect(try ExtensionPackage.stripCRX(crx3) == zip)
    let key = Data(repeating: 1, count: 10), sig = Data(repeating: 2, count: 6)
    let crx2 = Data("Cr24".utf8) + Self.le32(2) + Self.le32(key.count) + Self.le32(sig.count) + key + sig + zip
    #expect(try ExtensionPackage.stripCRX(crx2) == zip)
    #expect(try ExtensionPackage.stripCRX(zip) == zip)
    #expect(throws: ExtensionPackageError.self) { try ExtensionPackage.stripCRX(Data("hello world, not a crx".utf8)) }
    #expect(throws: ExtensionPackageError.self) { try ExtensionPackage.stripCRX(Data("Cr24".utf8) + Self.le32(3) + Self.le32(9999) + zip) }
  }

  @Test func unpacksAndValidates() throws {
    let d = Self.tempDir()
    defer { try? FileManager.default.removeItem(at: d) }
    let zipURL = d.appendingPathComponent("a.zip")
    try Self.zipped(#"{"manifest_version":2,"name":"Fox","version":"2.1","browser_action":{},"browser_specific_settings":{"gecko":{"id":"fox@example.org"}}}"#).write(to: zipURL)
    let out = d.appendingPathComponent("out")
    try ExtensionPackage.unzip(zipURL, to: out)
    let m = try ExtensionPackage.readManifest(out)
    #expect(m == ManifestInfo(name: "Fox", version: "2.1", manifestVersion: 2, geckoId: "fox@example.org", key: nil, hasAction: true))
    #expect(ExtensionPackage.extensionId(source: .firefox, storeId: "fox", manifest: m, path: "") == ExtensionPackage.derivedId("gecko:fox@example.org"))
    // Bad manifests are rejected before WebKit sees them.
    for bad in [#"{"manifest_version":4,"name":"x","version":"1"}"#, #"{"manifest_version":3,"version":"1"}"#, "not json"] {
      try bad.write(to: out.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
      #expect(throws: ExtensionPackageError.self) { try ExtensionPackage.readManifest(out) }
    }
    try FileManager.default.removeItem(at: out.appendingPathComponent("manifest.json"))
    #expect(throws: ExtensionPackageError.self) { try ExtensionPackage.readManifest(out) }
    let junk = d.appendingPathComponent("junk.zip")
    try Data("nope".utf8).write(to: junk)
    #expect(throws: ExtensionPackageError.self) { try ExtensionPackage.unzip(junk, to: d.appendingPathComponent("j")) }
  }

  @Test func updateChecksAndVersions() {
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?><gupdate xmlns="http://www.google.com/update2/response" protocol="2.0" server="prod">
      <app appid="aaaa" cohort="1::" status="ok"><updatecheck _esbAllowlist="true" codebase="https://clients2.googleusercontent.com/crx/blobs/x/A.crx" fp="1.x" hash_sha256="00" size="9" status="ok" version="2.0.1"/></app>
      <app appid="bbbb" status="ok"><updatecheck status="noupdate"/></app></gupdate>
      """
    let r = ExtensionPackage.parseUpdateCheck(xml)
    #expect(r.count == 1)
    #expect(r["aaaa"]?.version == "2.0.1")
    #expect(r["aaaa"]?.codebase == "https://clients2.googleusercontent.com/crx/blobs/x/A.crx")
    let u = ExtensionPackage.updateCheckURL([("aaaa", "1.0"), ("bbbb", "3")], chromeVersion: "140").absoluteString
    #expect(u.contains("response=updatecheck") && u.contains("x=id%3Daaaa%26v%3D1.0%26uc") && u.contains("x=id%3Dbbbb%26v%3D3%26uc"))
    #expect(ExtensionPackage.compareVersions("1.10", "1.9") == 1)
    #expect(ExtensionPackage.compareVersions("2026.926.2202", "2026.926.2202") == 0)
    #expect(ExtensionPackage.compareVersions("1.0", "1.0.1") == -1)
    let amo = #"{"guid":"addon@darkreader.org","slug":"darkreader","current_version":{"version":"4.9.133","file":{"url":"https://addons.mozilla.org/f/d.xpi","hash":"sha256:abc","size":12}}}"#
    let a = ExtensionPackage.parseAMO(Data(amo.utf8))
    #expect(a == ExtensionPackage.AMOVersion(guid: "addon@darkreader.org", slug: "darkreader", version: "4.9.133", fileURL: URL(string: "https://addons.mozilla.org/f/d.xpi")!, sha256: "abc", size: 12))
    #expect(ExtensionPackage.parseAMO(Data("{}".utf8)) == nil)
  }

  static func manifest(_ d: URL) throws -> [String: Any] {
    (try JSONSerialization.jsonObject(with: Data(contentsOf: d.appendingPathComponent("manifest.json"))) as? [String: Any]) ?? [:]
  }

  @Test func fullUBlockOriginPointsToLite() {
    for id in ["cjpalhdlnbpafiamejdnhcphjbkeiagm", "ublock-origin"] {
      let n = ExtensionText.storeNotice(id)
      #expect(n?.text.hasPrefix("uBlock Origin can’t block ads in den") == true)
      #expect(n?.actionTitle == "Get uBlock Origin Lite")
      #expect(n?.alternative == StoreRef(source: .chrome, id: "ddkjiahejlhfcafbddmgiahcphecmpfh"))
    }
    #expect(ExtensionText.storeNotice("ddkjiahejlhfcafbddmgiahcphecmpfh") == nil)
  }

  @Test func failureReasonsArePlain() {
    #expect(ExtensionText.failureReason("the store answered 204") == "the store didn’t hand over a download")
    #expect(ExtensionText.failureReason("The Internet connection appears to be offline.").hasPrefix("den couldn’t reach the store"))
    #expect(ExtensionText.failureReason("not a CRX or ZIP file") == "the file isn’t a working extension")
    #expect(ExtensionText.failureReason("Unable to parse the background service worker") == "it needs features Safari’s engine doesn’t have yet")
  }

  @Test func shimModuleWorkerContentScriptsAndPages() throws {
    let d = Self.tempDir()
    defer { try? FileManager.default.removeItem(at: d) }
    let m = #"{"manifest_version": 3, "name": "V", "version": "1", "permissions": ["bookmarks", "history", "tabs"], "background": {"service_worker": "bg/main.js", "type": "module"}, "content_scripts": [{"matches": ["<all_urls>"], "js": ["a.js", "b.js"]}, {"matches": ["file:///*"], "css": ["x.css"]}], "action": {"default_popup": "p.html"}}"#
    try m.write(to: d.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: d.appendingPathComponent("pages"), withIntermediateDirectories: true)
    try "<html><head><script src='x.js'></script></head></html>".write(to: d.appendingPathComponent("pages/p.html"), atomically: true, encoding: .utf8)
    try "<html><body>no scripts</body></html>".write(to: d.appendingPathComponent("plain.html"), atomically: true, encoding: .utf8)
    // WebKit rejects some patterns Chrome takes: that entry goes, the others stay.
    #expect(try ExtensionShim.apply(to: d, validPattern: { $0 != "file:///*" }))
    let out = try Self.manifest(d)
    // A module service worker becomes module background scripts, shim first.
    let bg = out["background"] as? [String: Any]
    #expect(bg?["service_worker"] == nil)
    #expect(bg?["scripts"] as? [String] == ["__den/background.js", "__den/shim.js", "bg/main.js"])
    #expect(bg?["type"] as? String == "module")
    let cs = out["content_scripts"] as? [[String: Any]]
    #expect(cs?[0]["js"] as? [String] == ["__den/shim.js", "a.js", "b.js"])
    #expect(cs?.count == 1)
    #expect(try String(contentsOf: d.appendingPathComponent("pages/p.html"), encoding: .utf8).contains("<head><script src=\"/__den/shim.js\"></script><script src='x.js'>"))
    #expect(try String(contentsOf: d.appendingPathComponent("plain.html"), encoding: .utf8) == "<html><body>no scripts</body></html>")
    #expect(try String(contentsOf: d.appendingPathComponent("__den/shim.js"), encoding: .utf8).hasPrefix("// den-shim v"))
    #expect(try ExtensionPackage.readManifest(d).name == "V")
    // A second load changes nothing.
    #expect(try !ExtensionShim.apply(to: d))
  }

  /// The shim itself, in JavaScriptCore against a WebKit-like `chrome`: a namespace that won't
  /// take new keys and lacks two webNavigation events (what stopped Vimium's background).
  @Test func shimFillsMissingEventsAndAPIs() throws {
    let js = try #require(JSContext())
    var errors: [String] = []
    js.exceptionHandler = { _, e in errors.append(e?.toString() ?? "?") }
    js.evaluateScript("""
      var console = {log() {}, warn() {}, error() {}};
      var fired = [], updated = [];
      const ev = () => ({addListener: (f) => updated.push(f), removeListener() {}, hasListener() { return false; }});
      var chrome = {
        runtime: {getManifest: () => ({permissions: ['tabs', 'history', 'bookmarks', 'sessions', 'search', 'webNavigation']}), onMessage: ev()},
        webNavigation: Object.preventExtensions({onCommitted: {addListener() {}}, getAllFrames() { return this === chrome.__nav ? 'bound' : 'unbound'; }}),
        tabs: {onUpdated: ev(), onRemoved: {addListener() {}}, create: async (o) => ({id: 9, url: o.url}), query: async () => [{id: 1}], update: async () => ({})},
        storage: {local: {get: async () => ({}), set: () => {}}, session: {}},
      };
      chrome.__nav = chrome.webNavigation;
      var browser = chrome;
      globalThis.__denBackground = true;
      """)
    js.evaluateScript(ExtensionShim.source)
    #expect(errors.isEmpty, "\(errors)")
    func eval(_ s: String) -> String { js.evaluateScript(s)?.toString() ?? "nil" }
    // The two events exist (the namespace was wrapped), the real API still works on its own object.
    #expect(eval("typeof chrome.webNavigation.onHistoryStateUpdated.addListener") == "function")
    #expect(eval("typeof chrome.webNavigation.onReferenceFragmentUpdated.addListener") == "function")
    #expect(eval("chrome.webNavigation.getAllFrames()") == "bound")
    #expect(eval("JSON.stringify(__denShimReport.wrapped)") == #"["webNavigation"]"#)
    // A pushState-style URL change (no load) fires onHistoryStateUpdated; a #fragment change the other one.
    js.evaluateScript("""
      chrome.webNavigation.onHistoryStateUpdated.addListener((d) => fired.push('history ' + d.url));
      chrome.webNavigation.onReferenceFragmentUpdated.addListener((d) => fired.push('fragment ' + d.url));
      const u = updated[updated.length - 1];
      u(1, {url: 'https://a.test/x', status: 'loading'}, {status: 'loading'});
      u(1, {url: 'https://a.test/y'}, {status: 'complete'});
      u(1, {url: 'https://a.test/y#z'}, {status: 'complete'});
      """)
    #expect(eval("fired.join(',')") == "history https://a.test/y,fragment https://a.test/y#z")
    // Stand-ins for missing APIs, and setAccessLevel.
    #expect(eval("typeof chrome.bookmarks.getTree + typeof chrome.history.search + typeof chrome.sessions.restore + typeof chrome.search.query") == "functionfunctionfunctionfunction")
    #expect(eval("typeof chrome.storage.session.setAccessLevel") == "function")
    #expect(errors.isEmpty, "\(errors)")
  }

  @Test func shimClassicWorkerAndBackgroundScripts() throws {
    let d = Self.tempDir()
    defer { try? FileManager.default.removeItem(at: d) }
    try #"{"manifest_version": 3, "name": "C", "version": "1", "background": {"service_worker": "sw.js"}}"#.write(to: d.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    #expect(try ExtensionShim.apply(to: d))
    #expect(try String(contentsOf: d.appendingPathComponent("__den_worker.js"), encoding: .utf8) == "importScripts(\"/__den/background.js\", \"/__den/shim.js\", \"/sw.js\");\n")
    #expect((try Self.manifest(d)["background"] as? [String: Any])?["service_worker"] as? String == "__den_worker.js")
    #expect(try !ExtensionShim.apply(to: d))
    // A worker in a folder gets its wrapper in that folder (bundles load chunks next to it); a
    // copy shimmed by an older den (wrapper in __den/) is moved there too.
    let g = Self.tempDir()
    defer { try? FileManager.default.removeItem(at: g) }
    try FileManager.default.createDirectory(at: g.appendingPathComponent("__den"), withIntermediateDirectories: true)
    try #"{"manifest_version": 3, "name": "G", "version": "1", "background": {"service_worker": "__den/worker.js"}}"#.write(to: g.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    try "importScripts(\"/__den/background.js\", \"/__den/shim.js\", \"/src/js/bg.js\");\n".write(to: g.appendingPathComponent("__den/worker.js"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: g.appendingPathComponent("src/js"), withIntermediateDirectories: true)
    #expect(try ExtensionShim.apply(to: g))
    #expect((try Self.manifest(g)["background"] as? [String: Any])?["service_worker"] as? String == "src/js/__den_worker.js")
    #expect(try String(contentsOf: g.appendingPathComponent("src/js/__den_worker.js"), encoding: .utf8).contains("\"/src/js/bg.js\""))
    let f = Self.tempDir()
    defer { try? FileManager.default.removeItem(at: f) }
    try #"{"manifest_version": 3, "name": "F", "version": "1", "background": {"scripts": ["main.js"], "type": "module"}}"#.write(to: f.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    #expect(try ExtensionShim.apply(to: f))
    #expect((try Self.manifest(f)["background"] as? [String: Any])?["scripts"] as? [String] == ["__den/background.js", "__den/shim.js", "main.js"])
    #expect(try !ExtensionShim.apply(to: f))
  }
}
