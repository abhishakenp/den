import Foundation
import Security
import WebKit

/// Passkeys without Apple's browser entitlement (docs/research/passkeys.md): WebKit exposes
/// WebAuthn, but every platform-passkey or hybrid (phone / Bluetooth) request fails with
/// `NotAllowedError`, while `PublicKeyCredential.getClientCapabilities()` still claims support.
/// Sites such as Google then start a passkey sign-in and end on "Something went wrong — Make
/// sure Bluetooth is on" instead of asking for the password.
///
/// Until den holds `com.apple.developer.web-browser.public-key-credential`, a tiny document-start
/// script in the page world (every frame) reports what den can really do: no platform
/// authenticator (`isUserVerifyingPlatformAuthenticatorAvailable()` → false), no conditional
/// mediation (`isConditionalMediationAvailable()` → false), and `getClientCapabilities()` with the
/// platform, hybrid and conditional entries false. Sites skip their passkey step and show the
/// password form. `navigator.credentials` itself is untouched, so security-key flows a site
/// starts on its own still reach WebKit.
///
/// The alternative, WebKit's private `WebAuthenticationEnabled` feature flag
/// (`WKPreferences._setEnabled:forFeature:`, present in macOS 26.5's WebKit), removes
/// `PublicKeyCredential` altogether: SPI, and sites then treat den as a browser without WebAuthn.
/// The page-world script uses public API only and answers exactly the questions sites ask.
///
/// Setting: General > "Skip passkey sign-in, use the password" (`general` / `passkeyFallback`,
/// on by default). It does nothing once den is signed with the entitlement (`entitled`): then
/// WebKit's real answers stand.
// thin-host: generic (a platform-capability report for every web view), not a feature
@MainActor
public enum Passkeys {
  public static let entitlement = "com.apple.developer.web-browser.public-key-credential"

  /// Whether this process is signed with the browser-passkey entitlement.
  public static let entitled: Bool = {
    guard let task = SecTaskCreateFromSelf(nil) else { return false }
    return (SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil) as? Bool) == true
  }()

  /// The user setting (default on). Read from `settings` by `DenRuntime`.
  public static var fallbackSetting = true

  /// Whether new web views get the script.
  public static var active: Bool { fallbackSetting && !entitled }

  static let script = """
    (()=>{const P=window.PublicKeyCredential;if(typeof P!=='function')return;
    const def=(k,f)=>{try{Object.defineProperty(P,k,{value:f,configurable:true,writable:true})}catch(e){}};
    def('isUserVerifyingPlatformAuthenticatorAvailable',function isUserVerifyingPlatformAuthenticatorAvailable(){return Promise.resolve(false)});
    def('isConditionalMediationAvailable',function isConditionalMediationAvailable(){return Promise.resolve(false)});
    const g=P.getClientCapabilities;if(typeof g==='function')def('getClientCapabilities',function getClientCapabilities(){
    return g.call(P).then(c=>Object.assign({},c,{passkeyPlatformAuthenticator:false,userVerifyingPlatformAuthenticator:false,hybridTransport:false,conditionalGet:false,conditionalCreate:false}))});})();
    """

  /// Adds the script to a new web view's configuration when active.
  static func configure(_ config: WKWebViewConfiguration) {
    guard active else { return }
    config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
  }
}
