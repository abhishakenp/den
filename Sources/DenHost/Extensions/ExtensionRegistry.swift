import Foundation

/// One installed extension, as persisted in `<extensions root>/extensions.json`.
public struct InstalledExtension: Codable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var version: String
  public var source: String  // ExtensionSource raw value
  public var storeId: String?
  /// Absolute path of the unpacked folder: `<root>/<id>/` for installs, the folder itself for ~/.den/extensions.
  public var dir: String
  public var enabled = true
  public var pinned = true
  /// Host access: `all` (every site it asks for), `click` (only the tab you click it on) or `sites`.
  public var siteAccess = "all"
  public var sites: [String] = []
  /// API permissions and match patterns the user granted (restored on every load).
  public var granted: [String] = []
  public var grantedPatterns: [String] = []
  public var installedAt: Double = 0
  public var updatedAt: Double?
  public var checkedAt: Double?
  /// A newer store version that asks for more than was granted; installing it needs approval.
  public var availableVersion: String?

  public var sourceKind: ExtensionSource { ExtensionSource(rawValue: source) ?? .local }
}

/// `extensions.json` plus the unpacked folders and icons next to it:
///
///     <root>/extensions.json
///     <root>/<id>/            unpacked extension (store and file installs)
///     <root>/icons/<id>.png   64 pt icon for den's UI
///
/// Reading is lazy and cheap: with no file there is nothing to load (and no extension controller).
public struct ExtensionRegistry {
  public let root: URL
  public private(set) var items: [InstalledExtension] = []

  public init(root: URL) {
    self.root = root
    if let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([InstalledExtension].self, from: data) { items = list }
  }

  var file: URL { root.appendingPathComponent("extensions.json") }
  public func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
  public func iconPath(_ id: String) -> String { root.appendingPathComponent("icons/\(id).png").path }
  /// Where an extension's files are: `<root>/<id>/` for installs (so the whole folder can be
  /// moved or copied), the recorded folder for ~/.den/extensions ones.
  public func path(_ e: InstalledExtension) -> String { e.sourceKind == .home ? e.dir : folder(e.id).path }

  public func item(_ id: String) -> InstalledExtension? { items.first { $0.id == id } }
  public var isEmpty: Bool { items.isEmpty }

  public mutating func upsert(_ e: InstalledExtension) {
    if let i = items.firstIndex(where: { $0.id == e.id }) { items[i] = e } else { items.append(e) }
  }

  public mutating func update(_ id: String, _ f: (inout InstalledExtension) -> Void) {
    guard let i = items.firstIndex(where: { $0.id == id }) else { return }
    f(&items[i])
  }

  public mutating func remove(_ id: String) { items.removeAll { $0.id == id } }

  /// Atomic write (temp file + rename).
  public func save() {
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? enc.encode(items) else { return }
    try? data.write(to: file, options: .atomic)
  }
}
