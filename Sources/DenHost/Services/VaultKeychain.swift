import Foundation
@preconcurrency import LocalAuthentication
import os
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
  /// Why the last refusal happened, when it wasn't the user cancelling ("biometryNotAvailable (-6)").
  var failure: String? { get }
}

extension VaultAuth {
  public var failure: String? { nil }
}

/// Touch ID (or the login password) through `LAContext.evaluatePolicy(.deviceOwnerAuthentication)`,
/// for every fill, copy and unlock, whatever keychain the item is in. No reuse window: each request
/// prompts. Every outcome is logged (`os_log` subsystem `io.github.abhishakenp.den`, category
/// `vault`) with the exact `LAError` code, and kept in `last` for tests and diagnostics.
public final class SystemAuth: VaultAuth {
  public struct Outcome: Sendable, Equatable {
    public var ok: Bool
    public var code: Int  // LAError.Code raw value; 0 when ok
    public var name: String  // "ok", "userCancel", "appCancel", "biometryNotAvailable", …
    public var ms: Int  // from the call to the answer
  }
  public private(set) var last: Outcome?
  public var failure: String? {
    guard let l = last, !l.ok, !Self.isCancel(l.code) else { return nil }
    return "\(l.name) (\(l.code))"
  }
  /// Called with each context before it is evaluated (tests cancel it with `invalidate()`).
  public var willEvaluate: ((LAContext) -> Void)?
  static let log = Logger(subsystem: "io.github.abhishakenp.den", category: "vault")

  public init() {}

  public func authenticate(reason: String, _ done: @escaping @MainActor (Bool, LAContext?) -> Void) {
    let ctx = LAContext()
    ctx.touchIDAuthenticationAllowableReuseDuration = 0  // every fill / copy asks
    var pre: NSError?
    let can = ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &pre)
    var bioErr: NSError?
    let bio = LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &bioErr)
    Self.log.info("auth start: canEvaluate=\(can, privacy: .public) \(pre?.code ?? 0, privacy: .public) biometrics=\(bio, privacy: .public) \(bioErr?.code ?? 0, privacy: .public) type=\(ctx.biometryType.rawValue, privacy: .public)")
    willEvaluate?(ctx)
    nonisolated(unsafe) let c = ctx
    let start = Date()
    ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, error in
      let code = (error as NSError?)?.code ?? 0
      let ms = Int(Date().timeIntervalSince(start) * 1000)
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          let o = Outcome(ok: ok, code: ok ? 0 : code, name: ok ? "ok" : Self.name(code), ms: ms)
          self.last = o
          Self.log.info("auth end: \(o.name, privacy: .public) (\(o.code, privacy: .public)) after \(o.ms, privacy: .public) ms")
          done(ok, ok ? c : nil)
        }
      }
    }
  }

  /// `LAError.Code` names (LAError.h).
  public nonisolated static func name(_ code: Int) -> String {
    switch code {
    case LAError.authenticationFailed.rawValue: return "authenticationFailed"
    case LAError.userCancel.rawValue: return "userCancel"
    case LAError.userFallback.rawValue: return "userFallback"
    case LAError.systemCancel.rawValue: return "systemCancel"
    case LAError.passcodeNotSet.rawValue: return "passcodeNotSet"
    case LAError.appCancel.rawValue: return "appCancel"
    case LAError.invalidContext.rawValue: return "invalidContext"
    case LAError.notInteractive.rawValue: return "notInteractive"
    case LAError.biometryNotAvailable.rawValue: return "biometryNotAvailable"
    case LAError.biometryNotEnrolled.rawValue: return "biometryNotEnrolled"
    case LAError.biometryLockout.rawValue: return "biometryLockout"
    case LAError.biometryDisconnected.rawValue: return "biometryDisconnected"
    case LAError.biometryNotPaired.rawValue: return "biometryNotPaired"
    case LAError.companionNotAvailable.rawValue: return "companionNotAvailable"
    default: return "error"
    }
  }

  /// A refusal the user chose (or that den caused), as opposed to a failure worth reporting.
  public nonisolated static func isCancel(_ code: Int) -> Bool {
    [LAError.userCancel.rawValue, LAError.systemCancel.rawValue, LAError.appCancel.rawValue, LAError.userFallback.rawValue].contains(code)
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

  /// Stores to read: the data protection keychain once den has written there (`acl`), and the
  /// login keychain always (items saved while den was ad-hoc signed stay readable after it gets a
  /// real signature).
  var stores: [Bool] { dp() ? [true, false] : [false] }

  public func accounts() -> [VaultAccount] {
    var out: [VaultAccount] = []
    for dp in stores {
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
    var seen = Set<String>()
    return out.filter { seen.insert($0.id).inserted }.sorted { ($0.origin, $0.username) < ($1.origin, $1.username) }
  }

  /// The data protection keychain is tried once per launch while den is in `app` mode, so a den
  /// that gained a real signature (with `keychain-access-groups`) moves to per-item ACLs.
  nonisolated(unsafe) static var probedDataProtection = false

  public func save(origin: String, username: String, password: Data) -> OSStatus {
    // Try the data protection keychain with a Touch ID (user presence) ACL; remember which store works.
    if mode != "app" || !Self.probedDataProtection {
      Self.probedDataProtection = true
      var err: Unmanaged<CFError>?
      if let acl = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &err),
        var q = itemQuery(origin, username, dp: true)
      {
        SecItemDelete(q as CFDictionary)
        q[kSecAttrAccessControl] = acl
        q[kSecValueData] = password
        q[kSecAttrLabel] = "den — " + (Self.parts(origin)?.host ?? origin)
        let s = SecItemAdd(q as CFDictionary, nil)
        SystemAuth.log.info("vault save: data protection keychain status \(s, privacy: .public)")
        if s == errSecSuccess {
          setMode("acl")
          // One copy only: drop a login-keychain item for the same login.
          if let old = itemQuery(origin, username, dp: false) { SecItemDelete(old as CFDictionary) }
          return s
        }
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

  /// The last read's Keychain status (logged; `vault.result` reports a failed read as "keychain <status>").
  public private(set) var lastReadStatus: OSStatus = errSecSuccess

  public func password(for a: VaultAccount, context: LAContext?) -> Data? {
    for dp in stores {
      guard var q = itemQuery(a.origin, a.username, dp: dp) else { return nil }
      q[kSecReturnData] = true
      q[kSecMatchLimit] = kSecMatchLimitOne
      // The context den just evaluated: an ACL item doesn't ask a second time.
      if let context { q[kSecUseAuthenticationContext] = context }
      var res: CFTypeRef?
      let s = SecItemCopyMatching(q as CFDictionary, &res)
      lastReadStatus = s
      SystemAuth.log.info("vault read: \(dp ? "data protection" : "login", privacy: .public) keychain status \(s, privacy: .public)")
      if s == errSecSuccess { return res as? Data }
      if s != errSecItemNotFound { return nil }
    }
    return nil
  }

  public func delete(_ a: VaultAccount) -> Bool {
    var deleted = false
    for dp in stores {
      guard let q = itemQuery(a.origin, a.username, dp: dp) else { return false }
      if SecItemDelete(q as CFDictionary) == errSecSuccess { deleted = true }
    }
    return deleted
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
