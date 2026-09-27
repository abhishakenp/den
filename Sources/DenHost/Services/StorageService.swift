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
  private var cache: [String: [(String, Value)]] = [:]

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
      return load(ns).first { $0.0 == args.str("key") }?.1 ?? .null
    case "set":
      var pairs = load(ns)
      let key = args.str("key")
      if let i = pairs.firstIndex(where: { $0.0 == key }) { pairs[i].1 = args["value"] } else { pairs.append((key, args["value"])) }
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

  private func load(_ ns: String) -> [(String, Value)] {
    if let c = cache[ns] { return c }
    var pairs: [(String, Value)] = []
    if let data = try? Data(contentsOf: file(ns)), let v = Codec.decode([UInt8](data)), let p = v.object { pairs = p }
    cache[ns] = pairs
    return pairs
  }

  private func save(_ ns: String, _ pairs: [(String, Value)]) -> Value {
    cache[ns] = pairs
    do {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      try Data(Codec.encode(.object(pairs))).write(to: file(ns), options: .atomic)
      return .ok
    } catch {
      return .error("storage: \(error.localizedDescription)")
    }
  }
}
