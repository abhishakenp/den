# den — Apple integration: Shortcuts, Spotlight, Handoff, iCloud, permissions, signing

> Research and implementation notes, 2026-10-05, macOS 26.5 (SDK 26.5, Xcode 26.5 17F42). Decisions are in [ROADMAP.md](../../ROADMAP.md).

**Method.** "Observed" means it was run on this Mac or on the CI runner, with the command or test named. Apple facts come from Apple's documentation JSON (`developer.apple.com/tutorials/data/documentation/<path>.json`), Apple's developer forums and the Handoff programming guide, each linked. Anything else is marked **UNVERIFIED**.

## TL;DR: what needs what

| Feature | Works with den's local signature? | Needs |
|---|---|---|
| Spotlight finds den's tabs and spaces (Core Spotlight) | ✅ Observed: indexing, an in-app query and a pick all work ad hoc | — |
| Handoff, den → iPhone/iPad | Built. **UNVERIFIED** across devices (no second device here) | Same iCloud account, Handoff on. A Team ID may be needed (below) |
| Handoff, iPhone Safari → den | Built (`NSUserActivityTypes`, `application(_:continue:)`). **UNVERIFIED** across devices | den set as the Mac's default browser (Apple's rule) |
| Shortcuts / Siri / Spotlight actions (App Intents) | ❌ Built, and the metadata is in the bundle, but the system ignores den | A **Team ID** signature (Apple Developer Program) |
| iCloud sync (CloudKit) | ❌ An ad hoc app touching CloudKit crashes; with the entitlements but no profile, it is killed at launch (observed) | Developer ID certificate + provisioning profile with iCloud (CloudKit) and Push; a container |
| Browser passkeys | ❌ ([passkeys.md](passkeys.md)) | Managed entitlement; Account Holder of an **organization** account; Developer ID profile |
| 1Password desktop unlock | ❌ ([password-managers.md](password-managers.md)) | Apple-issued signature (Developer ID + notarization in every confirmed case) |
| Location for websites | Needs den's location entitlement + usage string (added); the system asks once | — |
| Website notifications | den's own bridge to Notification Center while the tab is open | — (no web push in `WKWebView`) |

**One account unblocks most of it.** An Apple Developer Program membership gives a Team ID, a Developer ID certificate, provisioning profiles and notarization. That covers App Intents, CloudKit, notarization (which also clears Gatekeeper's first-launch warning) and 1Password. Passkeys additionally need the account to be an organization's and Apple's approval of a request form. The exact steps are in §6.

## 1. Shortcuts, Siri and Spotlight actions (App Intents)

**What den ships** (`Sources/DenHost/Intents/DenIntents.swift`, phrases in `Sources/Den/DenShortcuts.swift`):
- Actions: Open URL in den (space optional), New Tab in den (space and URL optional; without a URL, the command bar), Switch Space, Find Tabs (returns tabs), Open Tab, Get Current Page (returns the tab: title, address, space; never from a private window), Toggle Picture in Picture.
- Entities: Space, and Tab, with a string query (find by title or address).
- App Shortcuts: "New tab in den", "Switch to ‹space› in den", "Find tabs in den", "Get the current page from den", "Toggle picture in picture in den".
- Each action calls the same services as the menu bar (`tabs`, `spaces`, `media`).

**Building it with SwiftPM.** Xcode extracts `Contents/Resources/Metadata.appintents` at build time; SwiftPM doesn't. `scripts/lib/appintents.zsh` repeats Xcode 26.5's step. The invocation was captured from `xcodebuild` on a probe package, and the app-target half was taken from `AppIntentsMetadata.xcspec`:
1. `swift build` runs with `-Xswiftc -emit-const-values -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file -Xswiftc -Xfrontend -Xswiftc <protocols.json>` (Xcode's protocol list). This writes `<Module>.build/<Module>.swiftconstvalues`.
2. `appintentsmetadataprocessor` runs once per module: `DenHost` (intents and entities; `--binary-file` = one of its objects), then `Den` (the phrases; `--binary-file` = the executable, with `--static-metadata-file-list` pointing at DenHost's `extract.actionsdata`).
   - One run over both modules fails ("must have a compile-time static value").
   - The processor exits 255 on an error, and bundle.sh stops.
3. The output goes into `Contents/Resources/` before signing.
   - Observed in `build/den.app` (bundle.sh, 2026-10-05): `extract.actionsdata` holds 7 actions, 2 entities and 5 App Shortcuts.
- **Catch:** llbuild doesn't track the constant-values file, so a missing one isn't rebuilt. bundle.sh touches that module's sources when it's missing.
- **Not done:** `appintentsnltrainingprocessor` (Siri phrase training). On the probe it printed "Could not archive SSU artifacts" and wrote empty corpora, and it was never compared with an Xcode-built app.

**Why the system ignores it.** Observed on a probe app and on a copy of den's build under another bundle id, registered with `lsregister`:
- `linkd`, the App Intents daemon, logs `Failed to generate bundleIdentity … Not a platform binary, checking teamId... Unable to get teamId` and `Rejecting invalid client due to requiresValidatedBundle` (mach service `com.apple.linkd.autoShortcut`). This happens for ad hoc and for self-signed ("den Local Signing"-style) signatures, both of which have `TeamIdentifier=not set`.
- No App Intents index entry appears for the bundle.
- den calls `updateAppShortcutParameters()` only when `Signing.teamIdentifier` is set, so today it doesn't knock on linkd at all.
- **UNVERIFIED:** that a Team ID signature is enough. No Team ID signature was available to test. It is what linkd checks for.

**What can't be checked from the command line.** `shortcuts` only runs shortcuts already in the user's library (`run`, `list`, `view`, `sign`). Importing one needs the Shortcuts UI, and `mdfind` doesn't see App Intents. So each action is tested in-process instead (`IntentsTests`): the action's `perform()` against a real runtime with the spaces and tabs plugins, plus the entity queries.

## 2. Spotlight (Core Spotlight)

- The `spotlight` host service and the `continuity` plugin put every sidebar tab (title, address, "Tab in ‹space›", keywords the site, "den", "tab") and every space into den's `CSSearchableIndex(name: "den")`.
  - Writes are diffed against what the run already sent, and items expire after 7 days.
  - Picking an item reaches den as `CSSearchableItemActionType` (`application(_:continue:)`): a tab is selected in its space, a space is shown.
  - Private windows never show.
  - Settings ▸ General ▸ Continuity turns it off, which removes every item.
- **Observed:**
  - `ContinuityTests.indexedItemsAreFoundBySpotlightQuery`: an indexed title is found by a `CSSearchQuery` (the query Spotlight runs) in under 1 s, in the ad hoc test process, on this Mac and on the CI runner.
  - A probe app (ad hoc, non-sandboxed) found its item the same way at +3, +10 and +30 s, and `deleteAllSearchableItems` emptied it.
  - **`mdfind` never shows Core Spotlight items** (by `kMDItemTitle`, `kMDItemDisplayName` or free text), so the system Spotlight UI itself wasn't checked from the command line.
- Cost: one index write per change burst (2 s debounce), only of what changed; nothing while nothing changes.

## 3. Handoff

- **den → other devices.**
  - The `handoff` service makes the selected tab's page the current `NSUserActivityTypeBrowsingWeb` activity (`webpageURL`, title), with `isEligibleForSearch` off.
  - Only http(s): `NSUserActivity` itself throws on any other scheme (observed: "NSUserActivity.webpageURL scheme "file" is not allowed").
  - A private window in front, a non-web page, or the setting off clears it.
  - On the other device, a `webpageURL` with no matching app opens in that device's default browser ([Handoff guide, "Native App–to–Web Browser Handoff"](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/Handoff/AdoptingHandoff/AdoptingHandoff.html)).
- **Other devices → den.**
  - den lists `NSUserActivityTypeBrowsingWeb` in `NSUserActivityTypes`. "If the user selects that browser as their default browser, it receives the activity object instead of Safari" (same guide).
  - The page opens like a link from another app (`app.openURL {urls, source: "handoff"}`).
  - Firefox shipped the same with a Developer ID build and no iCloud entitlement ([bug 1085391](https://bugzilla.mozilla.org/show_bug.cgi?id=1085391)).
- **UNVERIFIED:**
  - Both directions across devices (no iPhone here). Tests check the activity den advertises and what a received one does (`ContinuityTests`).
  - The guide says activities are shared among apps "signed with the same developer team identifier". Whether a browsing-web activity from an app with no Team ID reaches iPhone Safari is unconfirmed. A third-party page claims the team-identifier entitlement matters ([kaylees.site](https://kaylees.site/troubleshooting-handoff.html), not Apple).

## 4. iCloud sync (CloudKit)

**Requirements (Apple):**
- The "iCloud: CloudKit" and "Push notifications" capabilities are available to Developer ID apps ([supported capabilities, macOS](https://developer.apple.com/help/account/reference/supported-capabilities-macos/)). Developer ID apps can use "advanced capabilities such as CloudKit and push notifications" ([Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)); an individual account works.
- `CKSyncEngine` (macOS 14) "requires the CloudKit and Remote notifications entitlements" ([doc](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5)).
- Entitlements:
  - `com.apple.application-identifier` (`TEAMID.io.github.abhishakenp.den`)
  - `com.apple.developer.team-identifier`
  - `com.apple.developer.icloud-services = [CloudKit]`
  - `com.apple.developer.icloud-container-identifiers = [iCloud.io.github.abhishakenp.den]`
  - `com.apple.developer.icloud-container-environment = Production`
  - `com.apple.developer.aps-environment = production`

  These are restricted, so they are authorized by a provisioning profile at `Contents/embedded.provisionprofile`. Developer ID profiles don't expire ([forum 685723](https://developer.apple.com/forums/thread/685723)). Distribution profiles get `Production` ([forum 707416](https://developer.apple.com/forums/thread/707416)).
- The schema must be deployed to Production in the CloudKit Console before release. Deployment is additive only.

**Observed without them** (ad hoc test app, hardened runtime):
- `CKContainer.default()` crashed with an uncaught `CKException` ("containerIdentifier can not be nil", exit 134). Swift can't catch it.
- `CKContainer(identifier:)` exited 133.
- With the iCloud entitlements but no profile, the app was SIGKILLed at launch (exit 137).
- `SecTaskCopyValueForEntitlement(…, "com.apple.developer.icloud-services")` returns nil when absent, so it is a safe gate. den's is `Signing.has("com.apple.developer.icloud-services", "CloudKit")`.

**den's design (the `sync` plugin; host `cloud` service).**
- The host's `cloud` service is only the gate: it never links or calls CloudKit. `cloud.state` says `{available: false, reason: "signing"}` until the entitlement check passes.
- When available, it wraps one `CKSyncEngine` over the private database, zone `den`. Its methods are `put {type, id, fields}`, `delete {type, id}` and `state`, plus the events `cloud.changed {type, id, fields | deleted}` and `cloud.account {status}`.
- The plugin owns what syncs and how conflicts resolve. It listens to `spaces.changed` / `tabs.changed` / `settings.changed`, writes records, and applies incoming ones through `spaces` / `tabs` / `settings`.
- Data model (one CKRecord type each; ids are den's own):

  | Record | Fields | Conflict rule |
  |---|---|---|
  | `Space` | `name`, `icon`, `theme` (JSON: colors, intensity, grain, appearance), `order`, `profileName` | last writer wins, per field |
  | `PinnedTab` | `spaceId`, `url`, `pinnedUrl`, `title`, `customTitle`, `icon`, `folderPath`, `order` | last writer wins; deletes win over edits older than the delete |
  | `Favorite` | `url`, `title`, `icon`, `order` | as `PinnedTab` |
  | `Folder` | `spaceId`, `title`, `parentId`, `order`, `collapsed` | as `PinnedTab` |
  | `Setting` | `key` (`<id>.<key>`), `value` (JSON) | last writer wins; device-specific keys (window sizes, the default-browser banner) never sync |

  Today tabs, history, the archive, downloads, passwords and site data don't sync: they're per device, or private.
- **Status:** the capability check and the design are written, and the gate ships: `cloud.state` reports `{available: false, reason: "signing"}` (`CloudGateTests`). The sync engine and plugin are not built: they can't be run or tested without the entitlements, since CloudKit crashes or the app is killed. They ship with the signing work (§6).

## 5. Website permissions

**Location** (`Sources/DenHost/Services/SitePermissions.swift`):
- On macOS 26, `WKUIDelegate` has no public geolocation method; the 26.5 SDK headers have none, and the public `requestGeolocationPermissionFor` arrives in macOS 27. den implements WebKit's `_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:` (`WKUIDelegatePrivate`, macOS 12+).
- den asks "Allow ‹site› to use your location?" and remembers the answer for the site until you quit, like the camera and microphone.
- WebKit then reads the position with Core Location in den's process. That needs `com.apple.security.personal-information.location` under the hardened runtime and an `NSLocationUsageDescription`; both are added, and Chrome has the same (observed with `codesign -d --entitlements` on Chrome 154).
- macOS asks once whether den may use location. If den is turned off in System Settings ▸ Privacy & Security ▸ Location Services, the page gets "denied" and den says where to turn it on.

**Notifications:**
- `window.Notification` exists in `WKWebView` on macOS 26.5, but `requestPermission()` resolves "denied" and nothing is shown. `PushManager` is undefined, and no header in the 26.5 SDK has a notification API. Observed in a WKWebView probe.
- den's choice: a page-world script replaces `Notification` (`permission`, `requestPermission`, `new Notification`, `close`, `onclick`/`onshow`/`onclose`, and `navigator.permissions.query({name: "notifications"})`). It bridges to den: den asks "Allow ‹site› to show notifications?", remembers the answer (persisted), and posts each notification to Notification Center (`UNUserNotificationCenter`) with the site as its subtitle.
- Clicking one brings den forward on that tab and fires the page's `click`.
- Only while the tab is open: no service-worker `showNotification`, no push.
- Private windows always get "denied".

**Review UI:** Shields' panel lists the site's remembered answers (camera, microphone, location, notifications) and resets them. Settings ▸ Shields lists every site with an answer, each removable.

## 6. What the maintainer must do (signing)

None of this is needed for den to run. Each step unblocks the features above.

1. **Enroll** in the Apple Developer Program at <https://developer.apple.com/programs/enroll/> (paid, yearly). For passkeys, enroll as an **organization** (a D-U-N-S number is required) and be its Account Holder. An individual account covers everything else.
2. **Certificates, Identifiers & Profiles:**
   - Register an explicit App ID `io.github.abhishakenp.den` with **iCloud (CloudKit)** and **Push Notifications**.
   - Create the container `iCloud.io.github.abhishakenp.den` and assign it to the App ID. A container can't be deleted or renamed later.
   - Create a **Developer ID Application** certificate (Account Holder) and install it in the login keychain.
   - Create a **Developer ID** provisioning profile for the App ID and certificate, and download it.
3. **Passkeys (organization only):** submit <https://developer.apple.com/contact/request/macos-browsers-passkeys/> ([passkeys.md](passkeys.md) has the criteria). When Apple approves it, the managed capability appears on the App ID; regenerate the profile.
4. **In the repo** (den's side, a follow-up change):
   - `Resources/den.release.entitlements` with the entitlements of §4 (plus `com.apple.developer.web-browser.public-key-credential` once approved, and `com.apple.security.personal-information.location`).
   - bundle.sh copies the profile to `Contents/embedded.provisionprofile` before signing, signs with `DEN_SIGN_IDENTITY="Developer ID Application: … (TEAMID)" --timestamp`, then `xcrun notarytool submit … --wait` and `xcrun stapler staple`.
   - Local builds keep `den.entitlements` and the local identity (restricted entitlements kill an app signed without a profile, as observed).
   - Changing the signing identity changes den's designated requirement, so macOS asks once again for the camera, microphone, location and Keychain grants.
5. **CloudKit Console:** run den once (Development) to create the record types, then **Deploy Schema Changes** to Production.
6. **1Password:** with den signed, notarized and in `/Applications`, 1Password ▸ Settings ▸ Browser ▸ **Add Browser** ▸ den.
