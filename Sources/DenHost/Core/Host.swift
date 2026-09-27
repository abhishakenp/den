import CordisValue
import Foundation

/// A host service: one handler `(method, args) -> Value`, plus events emitted on the host bus.
/// This is exactly the shape `cordis_service_fn` has, so each service can be registered with
/// the cordis `PluginHost` unchanged once it lands.
@MainActor
public protocol HostService: AnyObject {
  /// Service name, e.g. "webviews". Events are namespaced "<name>.<event>".
  var name: String { get }
  func handle(method: String, args: Value) -> Value
}

public typealias EventHandler = @MainActor (Value) -> Void

/// Service registry and event bus. Stand-in for cordis `PluginHost` until it lands:
/// `call` == `cordis_host.call`, `on` == `cordis_host.on`, `emit` == `cordis_host.emit`.
@MainActor
public final class ServiceHost {
  public private(set) var services: [String: HostService] = [:]
  private var handlers: [String: [(UInt64, EventHandler)]] = [:]
  private var nextHandle: UInt64 = 1

  public init() {}

  public func provide(_ service: HostService) {
    services[service.name] = service
  }

  public func call(_ service: String, _ method: String, _ args: Value = .null) -> Value {
    guard let s = services[service] else { return .error("no service '\(service)'") }
    return s.handle(method: method, args: args)
  }

  @discardableResult
  public func on(_ event: String, _ handler: @escaping EventHandler) -> UInt64 {
    let h = nextHandle
    nextHandle += 1
    handlers[event, default: []].append((h, handler))
    return h
  }

  public func off(_ handle: UInt64) {
    for key in handlers.keys { handlers[key]?.removeAll { $0.0 == handle } }
  }

  public func hasListeners(_ event: String) -> Bool { !(handlers[event]?.isEmpty ?? true) }

  public func emit(_ event: String, _ payload: Value = .null) {
    guard let list = handlers[event] else { return }
    for (_, h) in list { h(payload) }
  }
}

extension Value {
  /// Error convention from cordis.h: `{"error": "<message>"}`.
  public static func error(_ message: String) -> Value { ["error": .string(message)] }
  public static var ok: Value { ["ok": true] }

  public var isError: Bool { !self["error"].isNull }

  public var object: [(String, Value)]? { if case let .object(p) = self { return p } else { return nil } }

  public func str(_ key: String, _ fallback: String = "") -> String { self[key].string ?? fallback }
  public func num(_ key: String, _ fallback: Double = 0) -> Double { self[key].double ?? fallback }
  public func flag(_ key: String, _ fallback: Bool = false) -> Bool { self[key].bool ?? fallback }
  public func list(_ key: String) -> [Value] { self[key].array ?? [] }

  /// Returns a copy with `key` set (appended if missing).
  public func with(_ key: String, _ value: Value) -> Value {
    var pairs = object ?? []
    if let i = pairs.firstIndex(where: { $0.0 == key }) { pairs[i].1 = value } else { pairs.append((key, value)) }
    return .object(pairs)
  }
}
