import Foundation
import Testing

@testable import DenHost

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
}
