import CordisValue
import Foundation

/// `storage` service: per-plugin persistent `Value` storage.
/// One file per namespace: `<root>/<ns>.cvalue`, an encoded object, written atomically.
///
/// Methods (all take `ns`, the plugin id):
///   get {ns, key}            -> value or null
///   set {ns, key, value}     -> {ok}
///   delete {ns, key}         -> {ok}
///   keys {ns}                -> [string]
///   clear {ns}               -> {ok}
@MainActor
public final class StorageService: HostService {
  public let name = "storage"
  public let root: URL
  /// Per namespace, each key's value in its encoded form (`Codec`), decoded on `get`. A decoded
  /// tree costs ~2.5x its encoding (the tabs state of 200 tabs: 89 KB of arrays and strings in
  /// the heap vs a 35 KB encoding), and every value is read once or twice per launch.
  private var cache: [String: [(String, [UInt8])]] = [:]

  public static var defaultRoot: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("den/storage", isDirectory: true)
  }

  public init(root: URL = StorageService.defaultRoot) { self.root = root }

  public func handle(method: String, args: Value) -> Value {
    let ns = args.str("ns")
    guard Self.validNamespace(ns) else { return .error("storage: invalid ns '\(ns)'") }
    switch method {
    case "get":
      guard let bytes = load(ns).first(where: { $0.0 == args.str("key") })?.1 else { return .null }
      return Codec.decode(bytes) ?? .null
    case "set":
      var pairs = load(ns)
      let key = args.str("key"), value = Codec.encode(args["value"])
      if let i = pairs.firstIndex(where: { $0.0 == key }) { pairs[i].1 = value } else { pairs.append((key, value)) }
      return save(ns, pairs)
    case "delete":
      var pairs = load(ns)
      pairs.removeAll { $0.0 == args.str("key") }
      return save(ns, pairs)
    case "keys":
      return .array(load(ns).map { .string($0.0) })
    case "clear":
      return save(ns, [])
    default:
      return .error("storage: unknown method '\(method)'")
    }
  }

  static func validNamespace(_ ns: String) -> Bool {
    !ns.isEmpty && ns.count <= 128 && ns.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) } && ns != "." && ns != ".."
  }

  private func file(_ ns: String) -> URL { root.appendingPathComponent("\(ns).cvalue") }

  private func load(_ ns: String) -> [(String, [UInt8])] {
    if let c = cache[ns] { return c }
    var pairs: [(String, [UInt8])] = []
    if let data = try? Data(contentsOf: file(ns)), let v = Codec.decode([UInt8](data)), let p = v.object {
      pairs = p.map { ($0.0, Codec.encode($0.1)) }
    }
    cache[ns] = pairs
    return pairs
  }

  /// The file: the namespace as one encoded object, `Codec.encode(.object(pairs))` byte for byte,
  /// put together from the values' encodings.
  static func encodeObject(_ pairs: [(String, [UInt8])]) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(5 + pairs.reduce(0) { $0 + 4 + $1.0.utf8.count + $1.1.count })
    func u32(_ n: Int) { for k in 0..<4 { out.append(UInt8(truncatingIfNeeded: n >> (8 * k))) } }
    out.append(8)
    u32(pairs.count)
    for (k, v) in pairs {
      u32(k.utf8.count)
      out += k.utf8
      out += v
    }
    return out
  }

  private func save(_ ns: String, _ pairs: [(String, [UInt8])]) -> Value {
    cache[ns] = pairs
    do {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      try Data(Self.encodeObject(pairs)).write(to: file(ns), options: .atomic)
      return .ok
    } catch {
      return .error("storage: \(error.localizedDescription)")
    }
  }
}
