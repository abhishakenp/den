# den — Passkeys / WebAuthn in WKWebView (macOS 26)

> Research snapshot, 2026-09-27. Decisions made later are in [ROADMAP.md](../../ROADMAP.md) / [FEATURES.md](../FEATURES.md).

Researched 2026-09-27 on macOS 26.5 (SDK 26.5). This expands [apple-platform.md §1.7](apple-platform.md#17-passkeys--webauthn).

**Method.** Apple API facts come from the doc JSON (`developer.apple.com/tutorials/data/documentation/<path>.json`) fetched this session. WebKit behavior comes from `WebKit/WebKit@main` source, read this session. Empirical results come from a probe binary run on this machine (§3). Anything not confirmed that way is marked **UNVERIFIED**.

---

## TL;DR for den

| Question | Answer |
|---|---|
| Does WKWebView do WebAuthn by itself? | Yes. "WebKit automatically handles WebAuthentication challenges" ([Passkey use in web browsers](https://developer.apple.com/documentation/authenticationservices/passkey-use-in-web-browsers)). den needs no delegate code. |
| Do passkeys work on arbitrary sites today (ad-hoc den)? | **No.** Observed: `isUserVerifyingPlatformAuthenticatorAvailable()` → `false`, and a request fails with `NotAllowedError` (§3). |
| Do security keys (USB/NFC) work without the entitlement? | **No** for arbitrary RPs. The entitlement covers "passkeys **and security keys** for any relying party identifier". A forum report shows webauthn.io failing until the entitlement was granted (§2). |
| What unlocks it? | `com.apple.developer.web-browser.public-key-credential`, a **managed/restricted** entitlement. It needs an Account Holder request, Apple approval, a provisioning profile, and a non-ad-hoc signature. |
| Can den claim it with the current ad-hoc signing? | **No.** Observed: an ad-hoc binary claiming it is SIGKILLed by AMFI: "The file is adhoc signed but contains restricted entitlements" (§3). |
| macOS 27 changes | No new browser-passkey API found in Apple docs or the WWDC26 search (**UNVERIFIED absence**). `ASAuthorizationWebBrowserPublicKeyCredentialManager` is unchanged since macOS 13.3. |

---

## 1. The entitlement and the manager API

### 1.1 `com.apple.developer.web-browser.public-key-credential`
Source: [entitlement doc](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential).
- Boolean. macOS **13.3**, Mac Catalyst 16.3.
- Grants: "lets your app make registration and assertion requests for passkeys and security keys for any relying party identifier." "Only add this entitlement if your app can act as a user's web browser."
- How to get it (verbatim steps from the doc):
  1. You must hold the **Account Holder** role "for an organization's Apple Developer account". Whether an individual-account holder qualifies is **UNVERIFIED**; the doc says "organization's".
  2. Fill in the request form: <https://developer.apple.com/contact/request/macos-browsers-passkeys/>.
  3. Apple reviews the app "using predefined criteria".
  4. "Once approved, Apple adds the entitlement to your developer account using **managed capabilities**."
- Criteria:
  - Info.plist declares the `http` and `https` schemes.
  - On launch, the app offers a URL text field, search tools, or curated bookmark lists.
  - The app navigates directly to the requested destination and renders the expected content, with no unexpected redirects or injected content.
  - Allowed: Safe Browsing warnings, parental-control/lockdown restrictions, and a native auth UI for sites that also offer a web sign-in.
- **Paid membership:** implied. Account Holder, App IDs and provisioning profiles all require Apple Developer Program membership. Apple doesn't say this on the entitlement page itself (**UNVERIFIED as an explicit statement**).

### 1.2 Managed capability → provisioning profile → real signature
- [Provisioning with managed capabilities](https://developer.apple.com/help/account/reference/provisioning-with-managed-capabilities/): "Managed capabilities require approval from Apple to use." After approval you enable the capability on the App ID (Certificates, Identifiers & Profiles, or Xcode Signing & Capabilities), and "eligible provisioning profiles automatically include the entitlements."
- Restricted entitlements must be "authorized by a provisioning profile". In an app, that profile is embedded at `Contents/embedded.provisionprofile` ([Signing a daemon with a restricted entitlement](https://developer.apple.com/documentation/xcode/signing-a-daemon-with-a-restricted-entitlement)).
- **Confirmed on this machine:** an ad-hoc signature with this key is killed at launch (§3). Ad-hoc signing and this entitlement can't coexist.
- **Developer ID + this capability:** Apple's [macOS supported-capabilities table](https://developer.apple.com/help/account/reference/supported-capabilities-macos/) has no row for it. One forum post describes a Chromium browser "distributing outside the app store" that got the entitlement and signed "with a developer profile" ([forum 790037](https://developer.apple.com/forums/thread/790037)). That it works with a **Developer ID provisioning profile** is **UNVERIFIED**, though Chrome, Edge and similar ship outside the Mac App Store. No such browser is installed here to inspect with `codesign -d --entitlements`.

### 1.3 `ASAuthorizationWebBrowserPublicKeyCredentialManager` (macOS 13.3)
[Class doc](https://developer.apple.com/documentation/authenticationservices/asauthorizationwebbrowserpublickeycredentialmanager), [browser-app guide](https://developer.apple.com/documentation/authenticationservices/authenticating-people-by-using-passkeys-in-browser-apps):
- `authorizationStateForPlatformCredentials` returns an `AuthorizationState`: `.authorized`, `.denied` or `.notDetermined`. It covers "passkeys stored in the keychain, and managed by third-party credential manager apps".
- `requestAuthorizationForPublicKeyCredentials(_:)`: "Requests a person's permission to use their passkeys." Call it when the state is `.notDetermined`.
- `platformCredentials(forRelyingParty:) async` lists passkeys for an RP. `class var isDeviceConfiguredForPasskeys`.
- For a WKWebView browser this is only a permission/status API. WebKit does the ceremony itself (it builds `ASAuthorizationController` requests in `WebAuthenticatorCoordinatorProxy::constructASController`). Whether WebKit prompts for this authorization on its own the first time, or den must call `requestAuthorizationForPublicKeyCredentials` first, is **UNVERIFIED**. Plan to call it ourselves (for example on first WebAuthn use, or in Settings).

### 1.4 Info.plist / default browser
- The entitlement requires `http`/`https` in `CFBundleURLTypes`. **den already has this** (`Resources/Info.plist`, role Viewer), plus `public.html`/`public.xhtml` document types.
- Being the **default** browser isn't listed as a requirement (it's a separate, unrelated system setting).

---

## 2. What works WITHOUT the entitlement

| Case | Status | Evidence |
|---|---|---|
| Platform passkeys, arbitrary RP | ❌ | §3 probe. [passkeys.dev](https://passkeys.dev/docs/reference/macos/): embedded WebViews "run in the context of the calling app, meaning only passkeys for the linked web domain (RP ID) can be created or used". |
| Passkeys for den's **own** associated domains (`webcredentials:`) | ✅ in principle | Same passkeys.dev line. Irrelevant for a general browser, and `com.apple.developer.associated-domains` also needs a provisioning profile (**UNVERIFIED** for ad-hoc on macOS). |
| Security keys (USB/NFC FIDO2), arbitrary RP | ❌ | Entitlement text ("passkeys and security keys"). [forum 774904](https://developer.apple.com/forums/thread/774904): a WKWebView browser on webauthn.io got `ASAuthorizationError Code=1004` with "Told not to present authorization sheet"; demo pages worked after Apple granted the entitlement. WebKit on modern OSes routes security keys through the same `ASAuthorizationController` path (`requestsForRegistration`, `HAVE(SECURITY_KEY_API)`). |
| Hybrid (phone QR) | ❌ (same AS path) | `getClientCapabilities()` still reports `hybridTransport: true` (§3); the actual ceremony is **UNVERIFIED**. |
| API surface present | ✅ | `typeof PublicKeyCredential === "function"`, `navigator.credentials` exists. Sites see WebAuthn as available and then fail. |

How WebKit gates it (source, `Source/WebKit/UIProcess/WebAuthentication/Cocoa/WebAuthenticatorCoordinatorProxy.mm`):
- `isUserVerifyingPlatformAuthenticatorAvailable` and `isConditionalMediationAvailable` first call the private `ASCWebKitSPISupport getCanCurrentProcessAccessPasskeysForRelyingParty:`. If that returns false, the answer is `false`. The entitlement check lives inside AuthenticationServicesCore, not WebKit. There's no `isWebBrowser` string in WebKit's own code; the specific ASC check is **UNVERIFIED** (closed source).
- `getClientCapabilities` asks ASC per RP and **doesn't** apply the access gate. That's why caps report all `true` even though requests fail.
- `performRequest…` fails with `NotAllowedError` when `configuration().backgroundTextExtractionEnabled()` is true, and for cross-origin ancestors. Don't enable that on tab web views.
- WebCore `Modules/webauthn/AuthenticatorCoordinator.cpp:301`: a non-conditional `get` rejects "The document is not focused." if `!document.hasFocus()`.

---

## 3. Empirical probe (this machine, macOS 26.5)

Script: `scratchpad/webauthn_probe.swift`. Offscreen `WKWebView`, `.nonPersistent()` store, `loadHTMLString(..., baseURL: https://example.com/)`, `NSApplication` run loop, `callAsyncJavaScript`. Built with `swiftc -O`, which gives a **linker ad-hoc signature, no entitlements, no bundle**. The ad-hoc-signed `den.app` should behave the same, since neither has the entitlement, but that is **UNVERIFIED**.

Observed output (verbatim):
```
{"origin":"https://example.com","isSecureContext":true,"typeofPKC":"function","typeofCredentials":"object",
 "uvpaa":false,"cmaa":false,
 "caps":{"conditionalCreate":true,"conditionalGet":true,"hybridTransport":true,"passkeyPlatformAuthenticator":true,
         "relatedOrigins":true,"userVerifyingPlatformAuthenticator":true}}
```
- `navigator.credentials.get({publicKey:{challenge, timeout:3000, userVerification:'discouraged'}})` (modal): `NotAllowedError: The document is not focused.` after 0 ms. The probe couldn't get key-window focus from a headless shell even with `--window`. The modal path past the focus check is **UNTESTED**.
- Same request with `mediation:'conditional'` (skips the focus check): `NotAllowedError: The request is not allowed by the user agent or the platform in the current context, possibly because the user denied permission.` after **15 ms**, well before the 3 s timeout and 4 s abort, with no UI. Consistent with the ASC gate. Whether it would also fail *with* the entitlement (because `cmaa:false`) is **UNVERIFIED**.
- Probe re-signed `codesign -f -s - --entitlements pk.entitlements` (key = true): **exit 137**. amfid log: `AppleMobileFileIntegrityError Code=-424 "The file is adhoc signed but contains restricted entitlements"`.
- `create()` was not tried (it also needs focus, and a sheet would need a real account). **UNTESTED.**

---

## 4. What den does

**Now (no entitlement, ad-hoc or "den Local Signing"):**
- WebKit exposes WebAuthn and handles the ceremony; den adds no AuthenticationServices code.
- **Fallback (2026-09-28, `Sources/DenHost/Services/Passkeys.swift`).** A user reported Google trying a passkey and ending on "Something went wrong — Make sure Bluetooth is on" with no Touch ID prompt: `getClientCapabilities()` claims `hybridTransport` and `passkeyPlatformAuthenticator` (§3) although both fail. den now injects a document-start page-world script that makes `isUserVerifyingPlatformAuthenticatorAvailable()` / `isConditionalMediationAvailable()` resolve false and those capability entries false, so sites go to the password step. `navigator.credentials` is not overwritten. Considered and rejected: WebKit's private `WebAuthenticationEnabled` feature (present in macOS 26.5's `WKPreferences._features`, default on), which removes `PublicKeyCredential` altogether. The setting (General ▸ "Skip passkey sign-in, use the password") turns itself off once the process has the entitlement. Whether Google then skips the passkey step on a real account is **UNVERIFIED** (no test account); the API answers are verified in `PasskeysTests`.
- Keep it that way:
  - Don't turn on `backgroundTextExtractionEnabled` for tab web views.
  - Don't overwrite `navigator.credentials` in injected scripts.
  - Tab web views must be in the key window so `document.hasFocus()` is true.
- Accept that sign-in with passkeys or security keys fails on third-party sites with `NotAllowedError`. Sites fall back to passwords or OTP. Optionally, on a WebAuthn failure, offer "Open this page in the default browser" (`NSWorkspace.open`). That's a den UX choice.
- **Do not** add the entitlement to `Resources/den.entitlements` while `scripts/bundle.sh` signs ad hoc (`codesign … --sign -`, line 40). The app would be killed at launch (observed §3). [Correction 2026-09-28: `scripts/bundle.sh` now signs with `$DEN_SIGN_IDENTITY`, else the self-signed "den Local Signing" identity from `scripts/make-signing-identity.sh` when present, else ad hoc (`codesign … --sign "$SIGN"`, lines 59–70). Neither is a provisioning-profile-backed signature (see scripts/bundle.sh:59).]

**Existing files:**
- `Resources/den.entitlements` contains ~~only `com.apple.security.cs.disable-library-validation` (for plugins)~~ → `com.apple.security.cs.disable-library-validation` (for plugins), `com.apple.security.device.camera` and `com.apple.security.device.audio-input` *(corrected 2026-09-28: Resources/den.entitlements:6–10)*. No passkey key.
- `Resources/Info.plist`: bundle id `io.github.abhishakenp.den`, `http`/`https` in `CFBundleURLTypes` (meets the criterion), HTML document types, `LSMinimumSystemVersion` 26.0.

**Maintainer steps to get passkeys (manual, needs Apple):**
1. Enroll in the Apple Developer Program as an **organization** (99 USD/yr; price per Apple, not re-checked this session). You must be the Account Holder.
2. Submit <https://developer.apple.com/contact/request/macos-browsers-passkeys/> with a build that meets §1.1 (URL field on launch, direct navigation).
3. Register an explicit App ID `io.github.abhishakenp.den`. After approval, enable the managed capability on it (Certificates, Identifiers & Profiles → Identifiers → Capability Requests / Additional Capabilities).
4. Create a **Developer ID Application** certificate and a **Developer ID** provisioning profile for that App ID (it should pick up the entitlement automatically). Developer ID profile support for this capability is **UNVERIFIED** (§1.2).
5. Add `com.apple.developer.web-browser.public-key-credential` = `true` to `Resources/den.entitlements`. Also add `com.apple.application-identifier` / `com.apple.developer.team-identifier` matching the profile if `codesign` requires them (**UNVERIFIED**).
6. In `scripts/bundle.sh`, copy the profile to `build/den.app/Contents/embedded.provisionprofile` **before** signing. Replace `--sign -` with `--sign "Developer ID Application: <Name> (<TEAMID>)"` and keep `--options runtime --timestamp`. [Correction 2026-09-28: bundle.sh now signs with `--sign "$SIGN"`, and `DEN_SIGN_IDENTITY` already overrides the identity; it passes `--options runtime` but not `--timestamp` (see scripts/bundle.sh:62–70).] Note: this changes the designated requirement, so users re-grant TCC permissions once.
7. Notarize: `xcrun notarytool submit den.zip --keychain-profile … --wait`, then `xcrun stapler staple build/den.app`.
8. In den, call `ASAuthorizationWebBrowserPublicKeyCredentialManager().requestAuthorizationForPublicKeyCredentials` when the state is `.notDetermined`. Then re-run the §3 probe logic in-app and expect `uvpaa: true`.
9. Contributors who build locally stay ad hoc and must strip the key. Keep two entitlements files (release vs dev).

---

## Update 2026-10-05: Developer ID confirmed, organization required

- **Developer ID works (observed).** Chrome 154 from Google's dmg (`Developer ID Application: Google LLC (EQHXZ8M8AV)`, notarized) carries `com.apple.developer.web-browser.public-key-credential = true`, authorized by an embedded **Developer ID** provisioning profile (`ProvisionsAllDevices`, platform OSX), whose entitlements also list `com.apple.application-identifier`, `com.apple.developer.team-identifier`, `associated-domains.applinks.read-write` and `keychain-access-groups`. Chrome also declares `NSWebBrowserPublicKeyCredentialUsageDescription` (in `en.lproj/InfoPlist.strings`). So step 4 above is the right route, and step 5 should add `com.apple.application-identifier` and `com.apple.developer.team-identifier` too.
- **Organization only.** The entitlement doc says the requester "must hold the Account Holder role for an organization's Apple Developer account" ([doc JSON](https://developer.apple.com/tutorials/data/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential.json)). An individual membership doesn't qualify; enrolling as an organization needs a D-U-N-S number.
- **Add to Info.plist** once entitled: `NSWebBrowserPublicKeyCredentialUsageDescription` (the text macOS shows when den asks to use your passkeys).
- The full signing checklist, shared with CloudKit, App Intents and 1Password: [apple-integration.md §6](apple-integration.md#6-what-the-maintainer-must-do-signing).

## Open questions
- Exact ASC check behind `getCanCurrentProcessAccessPasskeysForRelyingParty` (entitlement only, or also `.authorized` state?).
- Whether WebKit prompts for passkey authorization itself.
- ~~Developer ID profile + managed capability confirmation~~ Confirmed with Chrome 154 (above).
- Behavior of the modal `get`/`create` path in a focused window without the entitlement (expected `NotAllowedError`, untested).
