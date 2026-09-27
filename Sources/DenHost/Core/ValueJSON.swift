import CordisValue
import Foundation

/// JSON <-> `Value`, for services that hand web data to plugins (plugins have no Foundation).
public enum ValueJSON {
  public static func parse(_ data: Data) -> Value? {
    guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
    return value(obj)
  }

  public static func parse(_ text: String) -> Value? { parse(Data(text.utf8)) }

  /// Converts a JSONSerialization / WebKit result (NSNumber, NSString, NSArray, NSDictionary, NSNull).
  public static func value(_ any: Any?) -> Value {
    switch any {
    case nil, is NSNull: return .null
    case let s as String: return .string(s)
    case let n as NSNumber:
      if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
      let t = String(cString: n.objCType)
      if ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(t) { return .int(n.int64Value) }
      let d = n.doubleValue
      if d.rounded() == d, abs(d) < 9e15 { return .int(Int64(d)) }
      return .double(d)
    case let a as [Any]: return .array(a.map { value($0) })
    case let d as [String: Any]: return .object(d.keys.sorted().map { ($0, value(d[$0])) })
    case let date as Date: return .double(date.timeIntervalSince1970 * 1000)
    default: return .string(String(describing: any!))
    }
  }

  /// Foundation object for JSONSerialization (bytes become base64 strings).
  public static func any(_ v: Value) -> Any {
    switch v {
    case .null: return NSNull()
    case let .bool(b): return b
    case let .int(i): return i
    case let .double(d): return d
    case let .string(s): return s
    case let .bytes(b): return Data(b).base64EncodedString()
    case let .array(a): return a.map { any($0) }
    case let .object(p):
      var d: [String: Any] = [:]
      for (k, x) in p { d[k] = any(x) }
      return d
    }
  }

  public static func string(_ v: Value) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: any(v), options: [.fragmentsAllowed, .sortedKeys]) else { return "null" }
    return String(decoding: data, as: UTF8.self)
  }
}
