import CryptoKit
import Foundation

/// Where an installed extension came from.
public enum ExtensionSource: String, Sendable {
  case local  // a folder, .crx, .xpi or .zip picked by the user
  case chrome  // Chrome Web Store
  case firefox  // addons.mozilla.org
  case home  // an unpacked folder in ~/.den/extensions (development)
}

/// A store listing: a Chrome Web Store item id, or an AMO slug / guid.
public struct StoreRef: Equatable, Sendable {
  public var source: ExtensionSource
  public var id: String
}

/// The parts of manifest.json den needs before handing the folder to WebKit.
public struct ManifestInfo: Equatable, Sendable {
  public var name: String
  public var version: String
  public var manifestVersion: Int
  public var geckoId: String?
  public var key: String?
  public var hasAction: Bool
}

public struct ExtensionPackageError: Error, CustomStringConvertible, Equatable {
  public let description: String
  init(_ s: String) { description = s }
}

/// Package handling for extensions: store URLs, CRX/XPI downloads, unpacking and manifest checks.
/// Pure functions, no WebKit, so they're unit-tested on their own.
public enum ExtensionPackage {
  public static let chromeStoreHosts = ["chromewebstore.google.com", "chrome.google.com"]
  public static let firefoxStoreHosts = ["addons.mozilla.org"]
  /// Sent as `prodversion` when the current Chrome version can't be fetched. The store filters
  /// items by `minimum_chrome_version` against it.
  public static let fallbackChromeVersion = "140.0.0.0"

  public static func isStoreHost(_ host: String) -> Bool {
    let h = host.lowercased()
    return chromeStoreHosts.contains(h) || firefoxStoreHosts.contains(h)
  }

  /// A store item page: `chromewebstore.google.com/detail/<slug>/<id>` (or `/detail/<id>`),
  /// the old `chrome.google.com/webstore/detail/...`, and `addons.mozilla.org/<locale>/firefox/addon/<slug>/`.
  public static func storeRef(for url: URL) -> StoreRef? {
    guard let host = url.host?.lowercased() else { return nil }
    let parts = url.path.split(separator: "/").map(String.init)
    if chromeStoreHosts.contains(host), let d = parts.firstIndex(of: "detail") {
      // The id is the last 32-letter a-p component after "detail".
      if let id = parts[(d + 1)...].last(where: isChromeId) { return StoreRef(source: .chrome, id: id) }
      return nil
    }
    if firefoxStoreHosts.contains(host), let a = parts.firstIndex(of: "addon"), a + 1 < parts.count {
      let slug = parts[a + 1].removingPercentEncoding ?? parts[a + 1]
      return slug.isEmpty ? nil : StoreRef(source: .firefox, id: slug)
    }
    return nil
  }

  /// Chrome extension ids are 32 letters a–p (hex of a SHA-256 prefix, 0-f mapped to a-p).
  public static func isChromeId(_ s: String) -> Bool {
    s.utf8.count == 32 && s.utf8.allSatisfy { $0 >= 97 && $0 <= 112 }
  }

  /// The Chrome id for a public key (DER SubjectPublicKeyInfo): first 128 bits of SHA-256, a–p encoded.
  public static func chromeId(publicKey: Data) -> String {
    let digest = SHA256.hash(data: publicKey)
    var out = ""
    for b in digest.prefix(16) {
      out.unicodeScalars.append(UnicodeScalar(97 + (b >> 4)))
      out.unicodeScalars.append(UnicodeScalar(97 + (b & 0x0F)))
    }
    return out
  }

  /// A stable a–p id for anything else (a gecko id, a folder path), shaped like a Chrome id so it
  /// works as the host of the extension's `webkit-extension://` base URL.
  public static func derivedId(_ seed: String) -> String { chromeId(publicKey: Data(("den.extension." + seed).utf8)) }

  // MARK: Store endpoints

  /// Chrome's update service, which redirects to the item's CRX.
  public static func crxDownloadURL(id: String, chromeVersion: String) -> URL {
    URL(string: "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=\(chromeVersion)&acceptformat=crx2,crx3&x=id%3D\(id)%26installsource%3Dondemand%26uc")!
  }

  /// One Omaha update check for several items: `x=id=<id>&v=<version>&uc` per item.
  public static func updateCheckURL(_ items: [(id: String, version: String)], chromeVersion: String) -> URL {
    var s = "https://clients2.google.com/service/update2/crx?response=updatecheck&prodversion=\(chromeVersion)&acceptformat=crx2,crx3"
    for i in items { s += "&x=id%3D\(i.id)%26v%3D\(i.version)%26uc" }
    return URL(string: s)!
  }

  /// `<app appid="…"><updatecheck status="ok" codebase="…" version="…"/></app>` → id: (version, codebase).
  /// Items with `status="noupdate"` (or no version) are left out.
  public static func parseUpdateCheck(_ xml: String) -> [String: (version: String, codebase: String)] {
    var out: [String: (String, String)] = [:]
    for chunk in xml.components(separatedBy: "<app ").dropFirst() {
      guard let id = attribute("appid", in: chunk), let uc = chunk.range(of: "<updatecheck") else { continue }
      let tag = String(chunk[uc.lowerBound...].prefix { $0 != ">" })
      guard attribute("status", in: tag) == "ok", let v = attribute("version", in: tag) else { continue }
      out[id] = (v, attribute("codebase", in: tag) ?? "")
    }
    return out
  }

  static func attribute(_ name: String, in s: String) -> String? {
    guard let r = s.range(of: name + "=\"") else { return nil }
    let rest = s[r.upperBound...]
    guard let end = rest.firstIndex(of: "\"") else { return nil }
    return String(rest[..<end]).replacingOccurrences(of: "&amp;", with: "&")
  }

  public static func amoAPIURL(_ slugOrGuid: String) -> URL {
    let s = slugOrGuid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? slugOrGuid
    return URL(string: "https://addons.mozilla.org/api/v5/addons/addon/\(s)/")!
  }

  public struct AMOVersion: Equatable, Sendable {
    public var guid: String
    public var slug: String
    public var version: String
    public var fileURL: URL
    public var sha256: String?
    public var size: Int?
  }

  /// The AMO v5 add-on detail: `guid`, `slug`, `current_version.{version, file.{url, hash, size}}`.
  public static func parseAMO(_ data: Data) -> AMOVersion? {
    guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let cv = o["current_version"] as? [String: Any], let file = cv["file"] as? [String: Any],
          let v = cv["version"] as? String, let u = (file["url"] as? String).flatMap(URL.init(string:)) else { return nil }
    var hash = file["hash"] as? String
    if let h = hash, h.hasPrefix("sha256:") { hash = String(h.dropFirst(7)) } else { hash = nil }
    return AMOVersion(guid: o["guid"] as? String ?? "", slug: o["slug"] as? String ?? "", version: v, fileURL: u, sha256: hash, size: file["size"] as? Int)
  }

  // MARK: Packages

  /// CRX2/CRX3 → the ZIP inside. A plain ZIP (XPI, zip) passes through unchanged.
  /// CRX3: "Cr24", uint32 version 3, uint32 header length, protobuf header, ZIP.
  /// CRX2: "Cr24", uint32 version 2, uint32 key length, uint32 signature length, key, signature, ZIP.
  public static func stripCRX(_ data: Data) throws -> Data {
    let b = [UInt8](data.prefix(16))
    if b.count >= 4, b[0] == 0x50, b[1] == 0x4B { return data }  // "PK"
    guard b.count >= 12, b[0...3] == [0x43, 0x72, 0x32, 0x34] else { throw ExtensionPackageError("not a CRX or ZIP file") }
    func u32(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 }
    let offset: Int
    switch u32(4) {
    case 3: offset = 12 + u32(8)
    case 2:
      guard b.count >= 16 else { throw ExtensionPackageError("truncated CRX2 header") }
      offset = 16 + u32(8) + u32(12)
    default: throw ExtensionPackageError("unsupported CRX version \(u32(4))")
    }
    guard offset + 4 <= data.count else { throw ExtensionPackageError("truncated CRX") }
    let zip = data.subdata(in: data.startIndex + offset..<data.endIndex)
    guard zip.prefix(2) == Data([0x50, 0x4B]) else { throw ExtensionPackageError("CRX payload is not a ZIP") }
    return zip
  }

  /// Unpacks a ZIP with the system's `ditto` (no third-party code).
  public static func unzip(_ zip: URL, to dir: URL) throws {
    try? FileManager.default.removeItem(at: dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    p.arguments = ["-x", "-k", zip.path, dir.path]
    let err = Pipe()
    p.standardError = err
    p.standardOutput = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
      let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      throw ExtensionPackageError("could not unpack: \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
  }

  /// Checks `manifest.json` in an unpacked folder: JSON, manifest_version 2 or 3, name, version.
  public static func readManifest(_ dir: URL) throws -> ManifestInfo {
    guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")) else { throw ExtensionPackageError("no manifest.json") }
    // Some manifests start with a UTF-8 BOM, which JSONSerialization rejects.
    let clean = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
    guard let o = try? JSONSerialization.jsonObject(with: Data(clean)) as? [String: Any] else { throw ExtensionPackageError("manifest.json is not valid JSON") }
    guard let mv = o["manifest_version"] as? Int, mv == 2 || mv == 3 else { throw ExtensionPackageError("manifest_version must be 2 or 3") }
    guard let name = o["name"] as? String, !name.isEmpty else { throw ExtensionPackageError("manifest has no name") }
    guard let version = o["version"] as? String, !version.isEmpty else { throw ExtensionPackageError("manifest has no version") }
    let gecko = ((o["browser_specific_settings"] ?? o["applications"]) as? [String: Any])?["gecko"] as? [String: Any]
    let hasAction = o["action"] != nil || o["browser_action"] != nil || o["page_action"] != nil
    return ManifestInfo(name: name, version: version, manifestVersion: mv, geckoId: gecko?["id"] as? String, key: o["key"] as? String, hasAction: hasAction)
  }

  /// den's id for an extension: the Chrome id when known (store id, or derived from the manifest
  /// `key`), otherwise a stable id derived from the gecko id or the source path.
  public static func extensionId(source: ExtensionSource, storeId: String?, manifest: ManifestInfo, path: String) -> String {
    if source == .chrome, let s = storeId, isChromeId(s) { return s }
    if let k = manifest.key, let der = Data(base64Encoded: k) { return chromeId(publicKey: der) }
    if let g = manifest.geckoId, !g.isEmpty { return derivedId("gecko:" + g) }
    if source == .firefox, let s = storeId { return derivedId("amo:" + s) }
    return derivedId("path:" + path)
  }

  /// Dotted numeric version compare ("1.10" > "1.9"); non-numeric parts compare as 0.
  public static func compareVersions(_ a: String, _ b: String) -> Int {
    let x = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    let y = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    for i in 0..<max(x.count, y.count) {
      let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
      if p != q { return p < q ? -1 : 1 }
    }
    return 0
  }

  public static func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
