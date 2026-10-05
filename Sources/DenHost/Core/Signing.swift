import Foundation
import Security

/// What den's own code signature carries. Several system features answer only apps signed by an
/// Apple developer account (a Team ID) or holding a managed entitlement: App Intents (Shortcuts,
/// Siri, Spotlight actions), CloudKit, browser passkeys, 1Password's browser check. den is signed
/// with a self-signed local identity or ad hoc today; these let features turn themselves on once
/// it isn't (docs/research/apple-integration.md).
public enum Signing {
  /// The Team ID of den's signature, or nil (ad hoc, self-signed, unsigned).
  public static let teamIdentifier: String? = {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let dict = info as? [String: Any] else { return nil }
    let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
    return team?.isEmpty == false ? team : nil
  }()

  /// The value of one of den's entitlements, or nil when it doesn't have it. Safe to call before
  /// touching the framework the entitlement unlocks (CloudKit traps without its entitlements).
  public static func entitlement(_ key: String) -> Any? {
    guard let task = SecTaskCreateFromSelf(nil) else { return nil }
    return SecTaskCopyValueForEntitlement(task, key as CFString, nil)
  }

  /// Whether `key` holds `value` (a Bool true, or an array containing the string).
  public static func has(_ key: String, _ value: String? = nil) -> Bool {
    switch entitlement(key) {
    case let b as Bool: return b && value == nil
    case let s as String: return value == nil || s == value
    case let a as [String]: return value.map(a.contains) ?? !a.isEmpty
    default: return false
    }
  }
}
