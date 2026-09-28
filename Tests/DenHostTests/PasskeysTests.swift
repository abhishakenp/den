import AppKit
import CordisValue
import Foundation
import DenTestSupport
import Testing
import WebKit

@testable import DenHost

/// Passkeys.swift: without Apple's browser entitlement, pages learn that den has no platform
/// authenticator, so sign-ins (Google) go to the password step instead of a hybrid/Bluetooth dead end.
@MainActor
@Suite(.serialized, .watchdog)
struct PasskeysTests {
  func caps(fallback: Bool) async throws -> [String: Any] {
    _ = NSApplication.shared
    let rt = DenRuntime(storageRoot: FileManager.default.temporaryDirectory.appendingPathComponent("den-passkeys-\(UUID())"))
    // The setting, as Settings ▸ General would change it (the runtime read the stored default).
    rt.call("settings", "set", ["id": "general", "key": "passkeyFallback", "value": .bool(fallback)])
    #expect(Passkeys.fallbackSetting == fallback)
    defer { Passkeys.fallbackSetting = true }
    rt.webviews.configureHooks.append { _, c in c.preferences.inactiveSchedulingPolicy = .none }
    let id = rt.call("webviews", "create", ["url": "about:blank"])["id"].string!
    let w = try #require(rt.webviews.materialize(id))
    defer { rt.call("webviews", "close", ["id": .string(id)]) }
    w.loadHTMLString("<p>sign in</p>", baseURL: URL(string: "https://accounts.example.com/"))
    for _ in 0..<100 where w.isLoading || w.url == nil { try await Task.sleep(for: .milliseconds(50)) }
    let js = """
      const P = window.PublicKeyCredential;
      const caps = P.getClientCapabilities ? await P.getClientCapabilities() : {};
      return {uvpaa: await P.isUserVerifyingPlatformAuthenticatorAvailable(), cmaa: await P.isConditionalMediationAvailable(),
              hybrid: !!caps.hybridTransport, platform: !!caps.passkeyPlatformAuthenticator, uvpa: !!caps.userVerifyingPlatformAuthenticator,
              cget: !!caps.conditionalGet, relatedOrigins: !!caps.relatedOrigins, credentials: typeof navigator.credentials.get};
      """
    let v = try await w.callAsyncJavaScript(js, contentWorld: .page)
    return try #require(v as? [String: Any])
  }

  @Test func pagesSeeNoPlatformAuthenticator() async throws {
    #expect(!Passkeys.entitled)  // test runner: ad-hoc, no entitlement
    let on = try await caps(fallback: true)
    print("passkeys.fallback on:", on)
    #expect(on["uvpaa"] as? Bool == false && on["cmaa"] as? Bool == false)
    #expect(on["hybrid"] as? Bool == false && on["platform"] as? Bool == false && on["uvpa"] as? Bool == false && on["cget"] as? Bool == false)
    // Everything else WebKit reports is left alone, and navigator.credentials is untouched.
    #expect(on["relatedOrigins"] as? Bool == true && on["credentials"] as? String == "function")
    // Off: WebKit's own answers, which claim hybrid and platform passkeys it can't deliver.
    let off = try await caps(fallback: false)
    print("passkeys.fallback off:", off)
    #expect(off["hybrid"] as? Bool == true && off["platform"] as? Bool == true)
  }
}
