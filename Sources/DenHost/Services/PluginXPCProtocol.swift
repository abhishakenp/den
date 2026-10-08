import CordisValue
import Foundation

/// XPC-based protocol for communication between the Den host and a sandboxed plugin process.
///
/// The host spawns a sandboxed helper for each plugin, and the helper exposes this
/// protocol over XPC.  The host calls `invoke(service:method:args:)` which maps
/// directly to the Cordis service-call pattern `plugins.call(service, method, args)`.
///
/// The plugin process:
///   1. Loads its dylib via `dlopen` (same path the host would use).
///   2. Finds the `CordisPlugin` implementation and calls `apply(context)`.
///   3. Registers its services with its internal `PluginHost` (a minimal in-process stub).
///   4. Exposes the `PluginSandboxProtocol` over an XPC listener so the host can call through.
///
/// The host:
///   1. Spawns the helper with `sandbox-exec -f <profile>`.
///   2. Connects via XPC to `PluginSandboxProtocol`.
///   3. Routes all `plugins.call()` through the XPC connection.
public protocol PluginSandboxProtocol: Sendable {
  /// Invoke a service method on the sandboxed plugin.
  /// Returns `Value` (JSON-compatible) the same way Cordis does.
  func invoke(service: String, method: String, args: Value) async -> Value

  /// Signal the sandboxed plugin to unload and shut down.
  func shutdown() async

  /// Returns metadata about the running plugin.
  func metadata() async -> Value
}

/// A minimal Value type for XPC communication that bridges to CordisValue.
/// XPC only supports property-list types, so we convert to/from dictionaries.
enum PluginXPCValue: Sendable {
  case null
  case bool(Bool)
  case int(Int64)
  case double(Double)
  case string(String)
  case array([PluginXPCValue])
  case object([String: PluginXPCValue])

  /// Convert from a CordisValue.Value.
  nonisolated(unsafe) static func from(_ v: Value) -> PluginXPCValue {
    switch v {
    case .null: return .null
    case .bool(let b): return .bool(b)
    case .int(let i): return .int(i)
    case .double(let d): return .double(d)
    case .string(let s): return .string(s)
    case .bytes: return .null
    case .array(let a): return .array(a.map { from($0) })
    case .object(let o):
      var dict: [String: PluginXPCValue] = [:]
      for (k, val) in o { dict[k] = from(val) }
      return .object(dict)
    }
  }

  /// Convert to a CordisValue.Value.
  nonisolated(unsafe) func toValue() -> Value {
    switch self {
    case .null: return .null
    case .bool(let b): return .bool(b)
    case .int(let i): return .int(i)
    case .double(let d): return .double(d)
    case .string(let s): return .string(s)
    case .array(let a): return .array(a.map { $0.toValue() })
    case .object(let o):
      var pairs: [(String, Value)] = []
      for (k, v) in o { pairs.append((k, v.toValue())) }
      return .object(pairs)
    }
  }

  /// Convert to a property-list-safe Any (for XPC).
  nonisolated(unsafe) func toXPC() -> Any {
    switch self {
    case .null: return NSNull()
    case .bool(let b): return b
    case .int(let i): return i
    case .double(let d): return d
    case .string(let s): return s
    case .array(let a): return a.map { $0.toXPC() }
    case .object(let o):
      var dict: [String: Any] = [:]
      for (k, v) in o { dict[k] = v.toXPC() }
      return dict
    }
  }

  /// Convert from a property-list-safe Any (from XPC).
  nonisolated(unsafe) static func fromXPC(_ any: Any?) -> PluginXPCValue {
    guard let any else { return .null }
    if any is NSNull { return .null }
    if let b = any as? Bool { return .bool(b) }
    if let i = any as? Int64 { return .int(i) }
    if let i = any as? Int { return .int(Int64(i)) }
    if let d = any as? Double { return .double(d) }
    if let s = any as? String { return .string(s) }
    if let a = any as? [Any] {
      return .array(a.map { fromXPC($0) })
    }
    if let d = any as? [String: Any] {
      var dict: [String: PluginXPCValue] = [:]
      for (k, v) in d { dict[k] = fromXPC(v) }
      return .object(dict)
    }
    return .null
  }

  /// Convert to a standard dictionary for serialization.
  nonisolated(unsafe) func toDictionary() -> Any? {
    switch self {
    case .null: return NSNull()
    case .bool(let b): return b
    case .int(let i): return i
    case .double(let d): return d
    case .string(let s): return s
    case .array(let a): return a.map { $0.toDictionary() }
    case .object(let o):
      var dict: [String: Any] = [:]
      for (k, v) in o { dict[k] = v.toDictionary() }
      return dict
    }
  }
}