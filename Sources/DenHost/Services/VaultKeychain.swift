import Foundation
@preconcurrency import LocalAuthentication
import Security

/// A saved login's metadata. The password is never part of it.
public struct VaultAccount: Equatable, Sendable {
  public var origin: String  // "https://example.com" or "http://127.0.0.1:8080"
  public var username: String
  public var created: Double  // ms since 1970
  public var id: String { origin + " " + username }
}

/// Where den keeps passwords. `SystemKeychain` in the app; an in-memory store in tests.
@MainActor
public protocol VaultStore: AnyObject {
  /// "acl": each item requires user presence (Touch ID) in the Keychain itself.
  /// "app": items are in the login keychain and den asks for Touch ID before every read.
  var mode: String { get }
  func accounts() -> [VaultAccount]
  func save(origin: String, username: String, password: Data) -> OSStatus
  /// The password, read with an authenticated `LAContext` (so an ACL item doesn't prompt twice).
  func password(for account: VaultAccount, context: LAContext?) -> Data?
  func delete(_ account: VaultAccount) -> Bool
}

/// Asks the user to confirm with Touch ID (or the login password).
@MainActor
public protocol VaultAuth: AnyObject {
  func authenticate(reason: String, _ done: @escaping @MainActor (Bool, LAContext?) -> Void)
}

public final class SystemAuth: VaultAuth {
  public init() {}
  public func authenticate(reason: String, _ done: @escaping @MainActor (Bool, LAContext?) -> Void) {
    let ctx = LAContext()
    ctx.touchIDAuthenticationAllowableReuseDuration = 10
    nonisolated(unsafe) let c = ctx
    ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
      DispatchQueue.main.async { MainActor.assumeIsolated { done(ok, ok ? c : nil) } }
    }
  }
}

/// den's own Keychain items: `kSecClassInternetPassword`, one per origin + username, marked with
/// `kSecAttrDescription` "den password" so den never lists or touches other apps' items.
///
/// Items are written to the data protection keychain with a `.userPresence` access control, so
/// the Keychain itself demands Touch ID for every read. That needs a real signature with a
/// `keychain-access-groups` entitlement; an ad-hoc signed den gets errSecMissingEntitlement
/// (-34018), and then falls back to the login keychain (no per-item ACL; den gates every read
/// behind `LAContext` itself, and the login keychain's own ACL limits items to den).
public final class SystemKeychain: VaultStore {
  static let marker = "den password"
  public private(set) var mode: String

  public init() {
    mode = UserDefaults.standard.string(forKey: "den.vault.mode") ?? "unknown"
  }

  func dp() -> Bool { mode == "acl" }

  static func parts(_ origin: String) -> (proto: CFString, host: String, port: Int)? {
    guard let u = URL(string: origin), let host = u.host, let scheme = u.scheme else { return nil }
    return (scheme == "http" ? kSecAttrProtocolHTTP : kSecAttrProtocolHTTPS, host, u.port ?? 0)
  }

  func base(dp: Bool) -> [CFString: Any] {
    var q: [CFString: Any] = [kSecClass: kSecClassInternetPassword, kSecAttrDescription: Self.marker]
    if dp { q[kSecUseDataProtectionKeychain] = true }
    return q
  }

  func itemQuery(_ origin: String, _ username: String, dp: Bool) -> [CFString: Any]? {
    guard let p = Self.parts(origin) else { return nil }
    var q = base(dp: dp)
    q[kSecAttrServer] = p.host
    q[kSecAttrProtocol] = p.proto
    q[kSecAttrPort] = p.port
    q[kSecAttrAccount] = username
    return q
  }

  public func accounts() -> [VaultAccount] {
    var out: [VaultAccount] = []
    for dp in dp() ? [true] : [false] {
      var q = base(dp: dp)
      q[kSecMatchLimit] = kSecMatchLimitAll
      q[kSecReturnAttributes] = true
      var res: CFTypeRef?
      guard SecItemCopyMatching(q as CFDictionary, &res) == errSecSuccess, let items = res as? [[CFString: Any]] else { continue }
      for i in items where (i[kSecAttrDescription] as? String) == Self.marker {
        guard let host = i[kSecAttrServer] as? String, let user = i[kSecAttrAccount] as? String else { continue }
        let proto = (i[kSecAttrProtocol] as? String) == (kSecAttrProtocolHTTP as String) ? "http" : "https"
        let port = (i[kSecAttrPort] as? Int) ?? 0
        let created = (i[kSecAttrCreationDate] as? Date)?.timeIntervalSince1970 ?? 0
        out.append(VaultAccount(origin: "\(proto)://\(host)" + (port == 0 ? "" : ":\(port)"), username: user, created: created * 1000))
      }
    }
    return out.sorted { ($0.origin, $0.username) < ($1.origin, $1.username) }
  }

  public func save(origin: String, username: String, password: Data) -> OSStatus {
    // Try the data protection keychain with a Touch ID ACL once; remember which store works.
    if mode != "app" {
      var err: Unmanaged<CFError>?
      if let acl = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &err),
        var q = itemQuery(origin, username, dp: true)
      {
        SecItemDelete(q as CFDictionary)
        q[kSecAttrAccessControl] = acl
        q[kSecValueData] = password
        q[kSecAttrLabel] = "den — " + (Self.parts(origin)?.host ?? origin)
        let s = SecItemAdd(q as CFDictionary, nil)
        if s == errSecSuccess { setMode("acl"); return s }
        if s != errSecMissingEntitlement { return s }
      }
      setMode("app")
    }
    guard var q = itemQuery(origin, username, dp: false) else { return errSecParam }
    let update: [CFString: Any] = [kSecValueData: password]
    let s = SecItemUpdate(q as CFDictionary, update as CFDictionary)
    if s != errSecItemNotFound { return s }
    q[kSecValueData] = password
    q[kSecAttrLabel] = "den — " + (Self.parts(origin)?.host ?? origin)
    return SecItemAdd(q as CFDictionary, nil)
  }

  func setMode(_ m: String) {
    mode = m
    UserDefaults.standard.set(m, forKey: "den.vault.mode")
  }

  public func password(for a: VaultAccount, context: LAContext?) -> Data? {
    guard var q = itemQuery(a.origin, a.username, dp: dp()) else { return nil }
    q[kSecReturnData] = true
    q[kSecMatchLimit] = kSecMatchLimitOne
    if let context { q[kSecUseAuthenticationContext] = context }
    var res: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &res) == errSecSuccess else { return nil }
    return res as? Data
  }

  public func delete(_ a: VaultAccount) -> Bool {
    guard let q = itemQuery(a.origin, a.username, dp: dp()) else { return false }
    return SecItemDelete(q as CFDictionary) == errSecSuccess
  }
}

/// In-memory store (tests, `--demo`). Same interface, no Keychain.
public final class MemoryVaultStore: VaultStore {
  public var mode = "memory"
  public var items: [String: (VaultAccount, Data)] = [:]
  public var reads = 0
  public init() {}
  public func accounts() -> [VaultAccount] { items.values.map(\.0).sorted { $0.id < $1.id } }
  public func save(origin: String, username: String, password: Data) -> OSStatus {
    let a = VaultAccount(origin: origin, username: username, created: Date().timeIntervalSince1970 * 1000)
    items[a.id] = (a, password)
    return errSecSuccess
  }
  public func password(for a: VaultAccount, context: LAContext?) -> Data? {
    reads += 1
    return items[a.id]?.1
  }
  public func delete(_ a: VaultAccount) -> Bool { items.removeValue(forKey: a.id) != nil }
}
