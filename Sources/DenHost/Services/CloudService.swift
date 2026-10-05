import CordisValue
import Foundation

/// `cloud` service: iCloud sync's capability gate (docs/research/apple-integration.md#4-icloud-sync-cloudkit).
/// CloudKit needs den signed with a Developer ID profile carrying the iCloud entitlements; without
/// them, touching CloudKit crashes the app (observed), so nothing CloudKit is called until
/// `Signing` says the entitlements are there. The sync engine (`CKSyncEngine` over the private
/// database) lands with the signing work; until then `state` says why sync is off.
///
/// | Method | Args | Returns |
/// |---|---|---|
/// | `state` | – | `{available, reason?: "signing", container?, teamId?}` |
@MainActor
public final class CloudService: HostService {
  public let name = "cloud"
  public static let container = "iCloud.io.github.abhishakenp.den"

  /// Whether this process may use CloudKit: the CloudKit service and den's container in its
  /// entitlements (a provisioning profile authorized them, or the app wouldn't have launched).
  public static var entitled: Bool {
    Signing.has("com.apple.developer.icloud-services", "CloudKit") && Signing.has("com.apple.developer.icloud-container-identifiers", container)
  }

  public init() {}

  public func handle(method: String, args: Value) -> Value {
    switch method {
    case "state":
      var v: Value = ["available": .bool(Self.entitled), "container": .string(Self.container)]
      if !Self.entitled { v = v.with("reason", "signing") }
      if let t = Signing.teamIdentifier { v = v.with("teamId", .string(t)) }
      return v
    default: return .error("cloud: unknown method '\(method)'")
    }
  }
}
