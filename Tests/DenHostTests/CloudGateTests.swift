import CordisValue
import DenTestSupport
import Testing

@testable import DenHost

/// iCloud sync's gate: a test process (ad hoc, no iCloud entitlements) says sync is off because of
/// signing, and never touches CloudKit (which would crash it).
@MainActor
@Suite(.watchdog)
struct CloudGateTests {
  @Test func syncIsOffWithoutTheEntitlements() {
    let rt = ServiceTests.runtime()
    let s = rt.call("cloud", "state")
    #expect(s["available"] == false && s.str("reason") == "signing" && s.str("container") == "iCloud.io.github.abhishakenp.den")
    #expect(!CloudService.entitled)
    #expect(Signing.teamIdentifier == nil)
    #expect(Signing.entitlement("com.apple.developer.icloud-services") == nil)
    rt.tearDown()
  }
}
