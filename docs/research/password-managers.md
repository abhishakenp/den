# den — password manager extensions and native messaging (1Password, Bitwarden)

> Research snapshot, 2026-10-05, macOS 26.5. Decisions are in [ROADMAP.md](../../ROADMAP.md).

**Method.** Bitwarden facts come from its source, `bitwarden/clients` at `245879a5` (2026-10-02), cited as `BW/<path>`, and from den's own copy of the Chrome Web Store build 2026.9.3 installed in a test. 1Password facts come from its support pages and community threads; 1Password's helper is closed source. Chrome and Firefox facts come from their native messaging docs. Nothing was run against a real 1Password or Bitwarden account or vault. Neither desktop app is installed on the Mac these notes were written on. Anything not confirmed is marked **UNVERIFIED**.

## TL;DR

| | Bitwarden | 1Password |
|---|---|---|
| Extension in den | ✅ Installs from the Chrome Web Store, its background starts, and the popup shows "Log in" (`ExtensionCompatTests.passwordManagers`). Signing in and filling aren't checked yet (that needs a real account) | ✅ Installs, background starts, popup opens. It works on its own when you sign in inside the extension |
| Desktop app unlock (Touch ID) | Should work once the Bitwarden desktop app (not the Mac App Store build's sandbox limits, see below) has written its Chrome manifest: den finds `com.8bit.bitwarden.json`, which lists the Chrome Web Store id, and starts `desktop_proxy`. **UNVERIFIED end to end** (no desktop app or account here) | ❌ Blocked by signing: the 1Password app checks the browser's code signature, and den's self-signed or ad hoc signature has no Team ID |
| What den does | Starts the host from Chrome's manifest folders, using Chrome's protocol (`NativeMessaging.swift`). Bitwarden's own pages and background are told they run in Chrome (`ExtensionShim`), so the extension uses that protocol | Same bridge. The 1Password helper decides whether to answer |
| What unblocks the rest | A Bitwarden desktop app and account to test with | A Developer ID signature (Apple Developer Program, Team ID) and notarization; den in `/Applications`; then 1Password ▸ Settings ▸ Browser ▸ Add Browser |

## 1. How native messaging works (Chrome, Firefox, WebKit)

- **Chrome** ([native messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)):
  - The desktop app installs a manifest at `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/<name>.json` (or `/Library/Google/Chrome/NativeMessagingHosts/`, or `…/Chromium/…`). It contains `{name, description, path, type: "stdio", allowed_origins: ["chrome-extension://<id>/"]}`. On macOS the path must be absolute, and the origins can't contain wildcards.
  - The host's first argument is the caller's origin.
  - Messages travel over stdin/stdout as JSON in UTF-8, each preceded by a 32-bit length in native byte order. The host can send at most 1 MB per message; the browser can send it at most 64 MiB.
  - `connectNative` keeps one process for as long as the port is open. `sendNativeMessage` starts a new process for each message.
- **Firefox** ([native manifests](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Native_manifests)):
  - Manifests live in `~/Library/Application Support/Mozilla/NativeMessagingHosts/` (or under `/Library/…`) and list `allowed_extensions` (gecko ids).
  - The host's arguments are the manifest's path and the add-on id.
  - On exit, Firefox sends SIGTERM, then SIGKILL.
- **WebKit** (`WKWebExtensionControllerDelegate`, macOS 15.4):
  - `sendMessage:toApplicationWithIdentifier:` and `connectUsingMessagePort:` reach the app.
  - "If not implemented, the default behavior is to pass the messages to the app extension handler within the extension's bundle, if the extension was loaded from an app extension bundle; otherwise, no action is performed." So before this work, `connectNative` from a Chrome Web Store extension did nothing in den.
  - `WKWebExtension.MessagePort.disconnect(throwing:)` disconnects the page's port, but the page's `onDisconnect` never sees the reason: `runtime.lastError` stays unset (observed in `NativeMessagingTests`).

## 2. Bitwarden

- **Host** (`BW/apps/desktop/src/main/native-messaging.main.ts`):
  - The name is `com.8bit.bitwarden` ("Bitwarden desktop <-> browser bridge"). The binary is `/Applications/Bitwarden.app/Contents/MacOS/desktop_proxy`.
  - Chrome `allowed_origins`: `nngceckbapebfimnlniiiahkandclblb` (Chrome Web Store), `hccnnhgbibccigepcmlgppchkpfdophk` (beta), plus Edge's and Opera's ids. Firefox: `{446900e4-71c2-419f-a6a7-df9c091e268b}`.
  - The desktop app writes the manifest only into browser folders that already exist: Chrome (all channels), Chromium, Edge, Vivaldi, Mozilla, Zen, Helium. Brave isn't on the list.
- **Desktop app:**
  - The proxy pipes stdin/stdout to the desktop app's Unix socket (`desktop_native/proxy/src/main.rs`, `core/src/ipc/mod.rs`): 1 MiB frames each way, and it exits on end of input.
  - Neither the proxy nor the IPC server checks the caller's origin or code signature.
  - The desktop app needs `setupEncryption`, with a public key and a `userId` that is signed in to the desktop app. It answers with an RSA-encrypted session key, and later messages must carry a timestamp within a 10 s window (`biometric-message-handler.service.ts`).
  - The fingerprint confirmation was removed in May 2026 (PR #19905).
  - The Mac App Store build's sandbox can only write into the browser folders listed above ([entitlements.mas.plist](https://github.com/bitwarden/clients/blob/main/apps/desktop/resources/entitlements.mas.plist)). den reads those same folders.
- **Safari or Chrome is decided by the user agent at runtime:**
  - `isBrowserSafariApi()` is true when the user agent contains ` Safari/` but neither ` Chrome/` nor ` Chromium/`. `getDevice()` returns `SafariExtension` for any ` Safari/` that isn't Opera. Checked in den's copy of the Chrome Web Store build, `popup/main.js`, functions `Ac()` and `getDevice`.
  - den's user agent is Safari's (Google sign-in needs it), so the Chrome Web Store build took its Safari path. There it marks the desktop connection ready without a handshake, sends unencrypted messages with no `appId` (a Safari app-extension protocol no desktop app answers), and sends clipboard calls to `sendNativeMessage("com.bitwarden.desktop", …)`.
  - **The blank popup was the same thing.** Observed in den on macOS 26.5 with build 2026.9.3:
    - The popup stayed on `<div id="loading">` (a spinner) with an empty body text.
    - Its `chrome.runtime.connect({name: "session"})` port to the background (Bitwarden's `ForegroundMemoryStorageService`) threw on `postMessage`.
    - `chrome.storage.local` stayed empty.
  - **den's fix.** `ExtensionShim` (shim v6) gives Bitwarden's own pages and background a Chrome user agent: `… Chrome/140.0.0.0 Safari/537.36`, vendor "Google Inc.". It applies by the Chrome Web Store ids above, or a manifest name starting "Bitwarden" for a file install. Web pages and content scripts are untouched.
    - Then the background initializes (storage gets `stateVersion`, `global_config_byServer`…) and the popup shows "Security, prioritised … Create account · Log in" within 1 s.
    - The extension's Chrome code path uses `connectNative("com.8bit.bitwarden")` (`nativeMessaging.background.ts`), which den's bridge serves.
    - `nativeMessaging` is in Bitwarden's `optional_permissions`, so turning on "Unlock with biometrics" asks for it with den's permission dialog.
- **Still to verify:** sign in, fill, and unlock with the desktop app, on a real account.

## 3. 1Password

- **Host:**
  - The name is `com.1password.1password`. The binary is `/Applications/1Password.app/Contents/Library/LoginItems/1Password Browser Helper.app/Contents/MacOS/1Password-BrowserSupport`.
  - `allowed_origins` includes the Chrome Web Store id `aeblfdkhhhdcdjpifhhbdiojplfjncoa`. Source: a manifest posted by 1Password staff, [community thread](https://www.1password.community/1password-at-home-31/does-1password-for-ungoogled-chromium-not-support-the-desktop-integration-feature-on-macos-4059).
- **Browser check:**
  - "On Mac, the 1Password app verifies the browser's code signature" ([1Password support](https://support.1password.com/1password-browser-connection-security/)).
  - Browsers not on 1Password's list have to be added under Settings ▸ Browser ▸ **Add Browser**, which takes "a browser that's code signed by Apple in the Applications folder" ([additional browsers](https://support.1password.com/additional-browsers/), [code signature](https://support.1password.com/code-signature/)).
  - Ad hoc and unsigned browsers are refused with "The selected application was signed in an unsupported way or may be missing a required identifier" (LibreWolf, Thorium reports).
  - 1Password staff: "1Password currently only supports properly signed and Apple-notarized browsers" ([community](https://www.1password.community/1password-at-home-31/support-unsigned-custom-browsers-14851)).
  - Orion (WebKit) works after Add Browser ([Kagi](https://help.kagi.com/orion/browser-extensions/1password.html)).
  - A Developer ID-signed, notarized Chromium fork connected after Add Browser ([ego-lite#264](https://github.com/citrolabs/ego-lite/issues/264)). Its helper strings include `CodeSignatureHasMatchingTeamId`, `NotSigned` and `MissingRequirementInfo`.
- **What it means for den:**
  - den is signed with the self-signed "den Local Signing" identity (no Team ID), or ad hoc. Either fails 1Password's check, so the desktop app unlock can't work today. **UNVERIFIED by running it**: no 1Password app here, and the user's vault is off limits.
  - Whether a Team ID alone (an Apple Development certificate) would pass, or Developer ID plus notarization is required, is **UNVERIFIED**. Every confirmed working browser was Developer ID and notarized.
  - **What unblocks it:** Developer ID signing and notarization (see [passkeys.md §4](passkeys.md#4-what-den-does) for the steps; the same account and certificate serve both), den in `/Applications`, then Add Browser in 1Password.
- **Without the desktop app:** the extension signs in to 1password.com on its own with the account password, with no Touch ID or shared unlock (community answers; no official page found).
- **Safari's route:** Safari sends `sendNativeMessage` only to the containing app's own app extension. "Safari ignores the application.id parameter" ([Apple](https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension)). Hosting another app's Safari app extension needs `NSExtension`, which isn't public API on macOS, and 1Password's own check would still refuse den. Not a route for den.

## 4. What den implements

`Sources/DenHost/Extensions/NativeMessaging.swift`, wired in `ExtensionControllerDelegate`; API in [host-api.md](../host-api.md#webext).

- **Lookup:** for `<name>.json`, in order:
  1. `~/.den/NativeMessagingHosts`
  2. `~/Library/Application Support/den/NativeMessagingHosts`
  3. Chrome, Chrome Beta and Canary, Chromium, Brave, Edge, Vivaldi, Arc (user, then system)
  4. Mozilla (user, then system)

  The first manifest that lists the extension is used. A manifest dropped in den's own folder can therefore allow an extension, or a host, for den only.
- **Names:** host names follow Chrome's rule (lowercase letters, digits, `_` and `.`). Anything else is "not found", so a name can't escape the folder.
- **Access:**
  - A Chrome-format manifest admits `chrome-extension://<Chrome id>/`. The Chrome id is the store id for Chrome Web Store installs, or comes from a manifest `key`.
  - A Firefox-format manifest admits the extension's gecko id.
  - Anything else is refused with Chrome's message ("Access to the specified native messaging host is forbidden."), as in Chrome. den asks the user nothing: the manifest the desktop app wrote is the consent, as in Chrome.
- **Process:**
  - Arguments follow the manifest's flavor (Chrome: the origin; Firefox: the manifest path and the gecko id). The working directory is the host's folder.
  - Stderr goes to `~/.den/logs/extensions.log`, as does every start, refusal and exit.
  - Closing a port closes stdin, then sends SIGTERM after 1 s. Unloading an extension (disable, update, uninstall) and den's teardown stop its hosts.
  - `sendNativeMessage` gives up after 120 s.
  - den ignores SIGPIPE, so a host that dies mid-write can't take den down.
- **Limits:** 1 MB per message from a host (Chrome's), 64 MB to it.
- **Verified** (`NativeMessagingTests`, a real `WKWebExtensionController` and a Perl echo host; `NativeMessagingUnitTests`):
  - `sendNativeMessage` round trip, including UTF-8 and the origin argument.
  - Forbidden, missing and invalid names.
  - `connectNative` with ordered messages both ways.
  - The host exiting disconnects the port.
  - `port.disconnect()`, and unloading the extension, end the host process (checked with `kill(pid, 0)`).
  - Framing: partial messages, the 1 MB limit, and bytes that aren't JSON.
