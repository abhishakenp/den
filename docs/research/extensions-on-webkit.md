# Chrome/Firefox extensions on WebKit — what den can actually do

> Research snapshot, 2026-09-27. Decisions made later are in [ROADMAP.md](../../ROADMAP.md) / [FEATURES.md](../FEATURES.md).

Research date: 2026-09-27. Legend: **[DOC]** = Apple/WebKit doc confirmed, **[SRC]** = read in WebKit/GitHub source, **[3P]** = third-party claim, **UNVERIFIED** = not confirmed.

## TL;DR

- Apple ships a real, public WebExtensions engine for third-party browsers: `WKWebExtension`, `WKWebExtensionContext`, `WKWebExtensionController` (+ `WKWebExtensionControllerDelegate`, `WKWebExtensionTab`, `WKWebExtensionWindow`). Minimum: **macOS 15.4** / iOS 18.4 / visionOS 2.4. **[DOC]**
- It is the same engine Safari uses. Supports MV2 + MV3, `chrome.*` and `browser.*` namespaces, service-worker and non-persistent backgrounds, content scripts, action popups, `declarativeNetRequest`, native messaging (via delegate). **No blocking `webRequest`** — so classic uBlock Origin (MV2) cannot run at full strength; uBO Lite (MV3/DNR) can.
- Orion does **not** appear to use it: Kagi says it wrote "its own implementation of the entire web extensions API" (~70% coverage). That is a multi-year effort den should not replicate.
- Several open-source Swift browsers (Nook, Crest, Refrax, DuckDuckGo's macOS app) already use `WKWebExtensionController` and install directly from Chrome Web Store / AMO by downloading the CRX/XPI and stripping the CRX header. Good reference code exists.
- **Recommendation:** build on `WKWebExtension*`, min target macOS 15.4 (or 26 to reduce bug surface), add CWS/AMO install + update polling, and ship a native content blocker (`WKContentRuleList` compiled from EasyList/uBO lists via `adblock-rust` or AdGuard `SafariConverterLib`) plus cosmetic/scriptlet injection. Accept that some extensions won't work; publish a compat list.

---

## 1. Apple's WKWebExtension API

### Availability [DOC]
From Apple doc JSON (`developer.apple.com/tutorials/data/documentation/webkit/<symbol>.json`), every one of these symbols reports: iOS 18.4, iPadOS 18.4, Mac Catalyst 18.4, **macOS 15.4**, visionOS 2.4.

- https://developer.apple.com/documentation/webkit/wkwebextension
- https://developer.apple.com/documentation/webkit/wkwebextensioncontext
- https://developer.apple.com/documentation/webkit/wkwebextensioncontroller
- https://developer.apple.com/documentation/webkit/wkwebextensioncontrollerdelegate
- https://developer.apple.com/documentation/webkit/wkwebextensiontab
- https://developer.apple.com/documentation/webkit/wkwebextensionwindow
- Announcement: https://webkit.org/blog/16574/webkit-features-in-safari-18-4/#web-extensions — "WebKit on iOS 18.4, iPadOS 18.4, visionOS 2.4, and macOS Sequoia 15.4 adds support for integrating web extensions into WebKit-based browsers…"

No dedicated WWDC session on these classes found (WWDC25 WebKit news only covered the Safari Web Extension Packager and menubar commands: https://webkit.org/blog/16993/news-from-wwdc25-web-technology-coming-this-fall-in-safari-26-beta/). UNVERIFIED whether a WWDC video exists.

### Object model [DOC]
| Class / protocol | Role | Key members |
|---|---|---|
| `WKWebExtension` | Parsed extension (manifest + resources) | `init(resourceBaseURL:)` — **directory or ZIP archive**; `init(appExtensionBundle:)`; `manifest`, `manifestVersion`, `supportsManifestVersion(_:)`, `requestedPermissions`, `optionalPermissions`, `allRequestedMatchPatterns`, `hasBackgroundContent`, `hasPersistentBackgroundContent`, `hasInjectedContent`, `hasOptionsPage`, `hasOverrideNewTabPage`, `hasContentModificationRules`, `hasCommands`, `errors`, `icon(for:)`, `actionIcon(for:)` |
| `WKWebExtensionContext` | Runtime for one extension | `init(for:)`, `baseURL`, `uniqueIdentifier`, permission APIs (`setPermissionStatus(_:for:expirationDate:)`, `permissionStatus(for:)`, `hasAccess(to:)`, `currentPermissions`…), `action(for:)`, `performAction(for:)`, `commands`, `performCommand(_:)`, `menuItems(for:)`, `optionsPageURL`, `overrideNewTabPageURL`, `loadBackgroundContent(completionHandler:)`, `isInspectable`, **`unsupportedAPIs`** (host can hide APIs so extensions feature-detect), `userGesturePerformed(in:)`, tab/window event methods (`didOpenTab`, `didActivateTab(_:previousActiveTab:)`, `didCloseTab(_:windowIsClosing:)`, `didMoveTab(_:from:in:)`, `didChangeTabProperties(_:for:)`, `didOpenWindow`, `didFocusWindow`…) |
| `WKWebExtensionController` | Manages loaded contexts; attach via `WKWebViewConfiguration.webExtensionController` | `init(configuration:)`, `load(_:)`, `unload(_:)`, `extensionContexts`, same tab/window event methods (broadcast to all), `fetchDataRecords(ofTypes:)`, `removeData(ofTypes:from:)` |
| `WKWebExtensionController.Configuration` | Persistence | `default()`, `nonPersistent()`, `init(identifier:)`, `defaultWebsiteDataStore`, `webViewConfiguration` |
| `WKWebExtensionControllerDelegate` | Host UI hooks | `openWindowsFor`, `focusedWindowFor`, `openNewTabUsing`, `openNewWindowUsing`, `openOptionsPageFor`, `promptForPermissions`, `promptForPermissionToAccess`, `promptForPermissionMatchPatterns`, `presentActionPopup`, `didUpdate` (action), `sendMessage:toApplicationWithIdentifier:` + `connectUsing:` (**native messaging**) |
| `WKWebExtensionTab` (protocol, host implements) | Tab as seen by extensions | `webView(for:)`, `url`, `title`, `window`, `indexInWindow`, `isSelected`, `isPinned`, `isMuted`, `isPlayingAudio`, `isLoadingComplete`, `loadURL`, `reload`, `goBack/Forward`, `activate`, `close`, `duplicate`, `setZoomFactor`, `takeSnapshot`, `detectWebpageLocale`, reader-mode hooks, `shouldBypassPermissions`, `shouldGrantPermissionsOnUserGesture` |
| `WKWebExtensionWindow` (protocol, host implements) | Window as seen by extensions | `tabs(for:)`, `activeTab`, `windowType`, `windowState`, `isPrivate`, `frame`, `screenFrame`, `setFrame`, `focus`, `close` |

Native messaging note [DOC]: if `connectUsing` is not implemented, "the default behavior is to pass the messages to the app extension handler within the extension's bundle, if the extension was loaded from an app extension bundle; otherwise, no action is performed." → For CWS/AMO extensions, Chrome-style native hosts (e.g., 1Password/Bitwarden desktop bridges) need den to implement the delegate and bridge to the host manifest/stdio protocol itself. Whether that is enough for any specific password manager: UNVERIFIED.

### Host responsibilities (what den must build)
- Model every tab/window as objects conforming to `WKWebExtensionTab` / `WKWebExtensionWindow`.
- Call controller `did*` methods on every tab/window lifecycle event (otherwise `tabs.onUpdated` etc. never fire).
- Present action popups (`presentActionPopup` gives a `WKWebExtension.Action`; den renders its popup web view in an `NSPopover`), toolbar icons/badges (`didUpdate`), context menu items (`menuItems(for:)`), keyboard commands.
- Permission prompts UI; persistence of granted permissions (context exposes state; storing across launches is on the host — UNVERIFIED whether controller persists grants automatically).
- Assign `webExtensionController` on the `WKWebViewConfiguration` **before** creating each `WKWebView` (noted in https://github.com/Lukas-Bohez/ConvertTheSpireFlutter/issues/10 and the Apple doc for `WKWebExtensionController`).

### Manifest & background [SRC]
Read in `Source/WebKit/UIProcess/Extensions/WebExtension.cpp` (WebKit main, https://github.com/WebKit/WebKit):
- Parses `background.service_worker`, `scripts`, `page`, `type: "module"`, `persistent`.
- MV3 must be non-persistent; `service_worker` must be non-persistent; iOS requires non-persistent. MV2 persistent background pages are allowed on macOS.
- Apple Safari docs: "Safari 15.4 and later supports manifest versions 2 and 3", "support both the chrome.* and browser.* namespaces", callbacks and Promises, "Blocking requests not supported", "BlockingResponse not supported", "opt_extraInfoSpec not supported" (https://developer.apple.com/documentation/safariservices/assessing-your-safari-web-extension-s-browser-compatibility). Applying Safari's statements to `WKWebExtension` rests on WebKit's stated goal that all WebKit browsers share one implementation — minor divergence UNVERIFIED.

### Which APIs exist [SRC]
IDL files in `Source/WebKit/WebProcess/Extensions/Interfaces/` on WebKit main: `action`/`browserAction`/`pageAction`, `alarms`, `commands`, `cookies`, `contextMenus`/`menus`, `declarativeNetRequest`, `devtools` (behind `INSPECTOR_EXTENSIONS`), `dom`, `extension`, `i18n`, `notifications`, `offscreen`, `permissions`, `runtime`, `scripting`, `storage`, `tabs`, `webNavigation`, `webRequest` (observe only), `windows`, `test`.
- Compiled **off** on Cocoa in `PlatformEnableCocoa.h`: `bookmarks` (`ENABLE_WK_WEB_EXTENSIONS_BOOKMARKS 0`), `sidebarAction`/`sidePanel` (`ENABLE_WK_WEB_EXTENSIONS_SIDEBAR 0`).
- On for trunk: `notifications`, `offscreen`. Which OS release first shipped them: UNVERIFIED.
- **Absent entirely** (no IDL): `identity`, `history`, `downloads`, `proxy`, `privacy`, `sessions`, `tabGroups`, `topSites`, `search`, `management`, `userScripts`, `tts`, `idle`, `gcm`, `enterprise.*`. Extensions that hard-depend on these will break unless den polyfills them (not possible through public API for main-world `browser.*`; `unsupportedAPIs` only removes APIs, cannot add them).

`declarativeNetRequest` limits [SRC] (`Source/WebKit/Shared/Extensions/WebExtensionConstants.h`): max **100** static rulesets, **50** enabled rulesets, **30,000** dynamic+session rules. DNR rules are converted to WebKit content rule lists; WebKit's parser caps one list at **150,000** rules (`maxRuleCount = 150000` in `Source/WebCore/contentextensions/ContentExtensionParser.cpp`).

Recent changes: Safari 26.0 added `dom.openOrClosedShadowRoot()`, DNR fixes (priority ordering, redirects to extension resources) (https://webkit.org/blog/17333/webkit-features-in-safari-26-0/). Safari 27.0 notes user-gesture propagation through `sendMessage/connect/postMessage/executeScript` and `tabId` in `windows.create()` (https://webkit.org/blog/18325/webkit-features-for-safari-27-0/). Safari 18.4 added `documentId`, `storage.getKeys()`, `match_origin_as_fallback` (https://webkit.org/blog/16574/). Implication: bug fixes arrive with OS updates; den's compat depends on user's macOS version.

## 2. Orion (Kagi)

- FAQ: "Orion has its own implementation of the entire web extensions API and different 'manifests' are just numbers"; "ported hundreds of APIs, one by one"; supports "about 70% of Web Extensions APIs" (https://browser.kagi.com/faq.html, https://help.kagi.com/orion/browser-extensions/macos-extensions.html). Kagi keeps a public API-support spreadsheet (https://help.kagi.com/orion/misc/technical.html).
- Orion predates `WKWebExtension` (iOS prototype years earlier). Whether it now uses `WKWebExtension` anywhere: **UNVERIFIED** — no Kagi statement found either way; its "own implementation" wording implies not. Whether it uses private WebKit SPI or a WebKit fork: UNVERIFIED (Kagi says only that it "shares … the WebKit rendering engine").
- Install sources: one-click from Chrome Web Store and AMO, manual file install, Safari extensions from disk; "Automatic Extension Updates"; still labelled beta (macOS extensions doc above).
- MV2 + MV3 both claimed ("Orion will support both").
- Kagi: "It is enough that one API is not supported for the extension to not work." Third-party review reports uBO, Bitwarden, Dark Reader, Vimium, Stylus working; 1Password flows problematic [3P] (https://supasidebar.com/blog/orion-browser-mac-review-2026).
- Built-in blocker "about 90% as efficient as uBlock Origin on default settings but faster"; recommends disabling it when running uBO (FAQ).
- Orion is closed source.

## 3. Installing from Chrome Web Store / AMO

### Chrome Web Store (CRX3)
- Download: `https://clients2.google.com/service/update2/crx?response=redirect&prodversion=<chrome ver>&acceptformat=crx2,crx3&x=id%3D<ID>%26installsource%3Dondemand%26uc` (widely documented; e.g. https://gist.github.com/noromanba/5776183). Same host is the official enterprise update URL (https://support.google.com/chrome/a/answer/7532015). The server filters by `prodversion`, so send a current Chrome version — Nook fetches it from `versionhistory.googleapis.com` [SRC].
- Format [SRC] (https://github.com/chromium/chromium/blob/main/components/crx_file/crx3.proto): `"Cr24"` magic, uint32 version (3), uint32 LE header length N, N-byte protobuf `CrxFileHeader` (RSA/ECDSA proofs, `signed_header_data` with crx_id), then ZIP. Strip header → ZIP → `WKWebExtension(resourceBaseURL:)` (accepts ZIP). Whether `WKWebExtension` accepts a raw CRX without stripping: UNVERIFIED — strip it.
- Verify signature (Crest has `CRX3Verifier.swift`; Nook skips verification and relies on HTTPS — comment in its `WebStoreDownloader.swift`).
- Extension ID = first 128 bits of SHA-256 of public key, a–p encoded. Preserve manifest `key` so IDs stay stable (some extensions hard-code their own ID). Whether `WKWebExtensionContext.uniqueIdentifier` can be set to the Chrome ID: UNVERIFIED — check; affects `runtime.id` and `externally_connectable`.
- Updates: poll the same update2 endpoint with `x=id=<ID>&v=<version>` (Omaha protocol) — Crest implements `ChromeWebStoreUpdateRequest.swift` [SRC].
- Install UX: inject an "Add to den" button on `chromewebstore.google.com/detail/*` (Crest/Nook pattern). Orion does the same.

### AMO (XPI)
- API: `GET https://addons.mozilla.org/api/v5/addons/addon/<id|slug|guid>/` → `current_version.file.url` (https://mozilla.github.io/addons-server/topics/api/addons.html). Response also has hash/size — Crest checks "checksum, size, and identity" [SRC: Crest help doc].
- XPI is a ZIP signed by Mozilla (signatures in `META-INF/` — standard, not confirmed on the fetched page). Load as ZIP directly.
- Updates: re-query the API and compare `version`; listed add-ons update through AMO (https://extensionworkshop.com/documentation/publish/signing-and-distribution-overview/).
- Firefox extensions often expect `browser.*` + Promises + persistent MV2 background — which WebKit supports on macOS.

### Legal / ToS
- Brave, Vivaldi, Edge, Orion and several open-source WebKit browsers install from CWS; no enforcement action found. (The earlier draft of this section couldn't retrieve the CWS terms; they were found and read on 2026-09-27, below.)
- Safer posture: fetch on the user's explicit action, from the official store, never mirror/redistribute packages (each extension has its own license), don't spoof beyond `prodversion`, and don't use Google/Mozilla branding.
- AMO public API is documented for third-party use; AMO add-on licenses vary per add-on.

### Terms of use (researched 2026-09-27)

*This is not legal advice. It records what the published terms say.* **VERIFIED** means the text was fetched from the URL on that date. The fetch tool passes pages through a summarizer, so check each quote against the page before it becomes load-bearing. **UNVERIFIED** means the claim comes from search results or common knowledge.

**1. Chrome Web Store user ToS** (updated Jan 27 2025). `chrome.google.com/webstore/terms` and `chromewebstore.google.com/tos` returned 404; the text was read at https://ssl.gstatic.com/chrome/webstore/intl/en-US/gallery_tos.html. VERIFIED:
- §1.1 incorporates the Google ToS (https://policies.google.com/terms).
- §1.2: "You may use the Web Store to browse, locate, and download Products … **for use in connection with Google Chrome**."
- §3.3: "You agree not to access (or attempt to access) the Web Store by any means other than through the interface that is provided by Google, unless you have been specifically allowed to do so in a separate agreement with Google."
- §3.4: no "activity that interferes with or disrupts the Web Store (or the servers …)".
- The Google ToS bars "using automated means to access content … in violation of the machine-readable instructions on our web pages", and says "Don't remove, obscure, or alter any of our branding, logos, or legal notices." VERIFIED
- `robots.txt` (checked with curl, VERIFIED): chromewebstore.google.com disallows `/search` and some `/detail/*` subpaths; clients2.google.com has no rule for `/service/update2/crx`.

**2. CWS Developer Agreement §5.2** (updated May 4 2021, https://developer.chrome.com/webstore/terms): the developer grants users a license to use Products "in connection with Google Chrome", and may override it with their own EULA. VERIFIED. Many extensions ship under open-source licences, which grant rights independently of this clause.

**3. Mozilla / AMO**
- The Websites & Communications Terms (https://www.mozilla.org/en-US/about/legal/terms/mozilla/) cover "AMO"; the Acceptable Use Policy forbids activity that "interferes with or disrupts Mozilla's services". Neither has a scraping or API clause. VERIFIED
- The API docs (https://mozilla.github.io/addons-server/topics/api/overview.html) call v5 "considered stable" but "not frozen and can change at any time without warning", with no terms and no documented rate limit. VERIFIED. The server throttles with HTTP 429 (GitHub issues, Discourse). UNVERIFIED
- The add-on policies say "All add-ons are subject to these policies, regardless of how they are distributed" (https://extensionworkshop.com/documentation/publish/add-on-policies/); nothing forbids installing an add-on in another browser. VERIFIED
- Each add-on has its own licence (the v5 API reports uBlock Origin as "GNU General Public License v3.0 only"). VERIFIED via curl.
- AMO's `robots.txt` disallows `/firefox/downloads/`, where `file.url` points. That targets crawlers, not a download a user clicked. VERIFIED

**4. Other browsers.** Orion installs from both stores "with one click", behind opt-in settings "Allow installation of 3rd party Chrome/Firefox extensions" (https://help.kagi.com/orion/browser-extensions/macos-extensions.html). VERIFIED. Edge asks the user to "Allow extensions from other stores" before installing from CWS (support.microsoft.com). VERIFIED. Brave, Vivaldi, Opera and Arc install from CWS. UNVERIFIED. No legal action against a third-party browser for installing from CWS or AMO was found.

**5. Trademarks.** Mozilla allows its word marks in text to "truthfully refer to and/or link to" its products, and "works with" / "is compatible" claims in words only, not logos (https://www.mozilla.org/en-US/foundation/trademarks/policy/). VERIFIED. Google: exact spelling, no implied endorsement, logos only as official artwork; the CWS branding page (https://developer.chrome.com/docs/webstore/branding) forbids Google marks as names or icons without permission. VERIFIED

**Bottom line.** AMO: low risk — a user-initiated download from a public API of licensed files. CWS: technically at odds with ToS §1.2 ("for use in connection with Google Chrome") and §3.3 (access "only through the interface … provided by Google"); that is the same position Brave, Vivaldi, Edge and Orion are in, and no enforcement was found. The practical risk is contractual or technical (the endpoint changes or gets blocked), not copyright; each extension's own licence governs its code. Injecting a button into Google's page arguably touches the ban on altering Google's branding; den's button doesn't remove store branding, but it does hide the store's (non-working) install button.

**What den does** (implemented in `ExtensionsService`, docs/host-api.md#webext):
1. Downloads only when the user clicks, one item at a time, and only after the permission dialog. No crawling, no mirroring, no `/search`.
2. Update checks once a day (plus one catch-up a minute after launch when the last check is over a day old), batched into one Omaha request for all CWS items, with an honest `User-Agent: den/<version> (Macintosh; +https://github.com/abhishakenp/den)`.
3. "Add to den" on store pages has an off-switch (Extensions page → Settings). Orion makes store installs opt-in; den keeps them on by default — revisit before a release.
4. The injected button says it's den's ("＋ Add to den") and leaves the store's logos and branding alone.
5. Stores are named in plain text only ("Chrome Web Store", "Firefox Add-ons"), with no Google or Mozilla logos and no endorsement claim; each extension links to its store page ("View in Store").
6. Still to do: back-off on 429/5xx for update checks, show each extension's licence. Get counsel before any commercial distribution.

### den's implementation: measured (2026-09-27, macOS 26.5, build/den.app)

`--scenario extensionsVerify` (`Sources/DenHost/Scenarios/ExtensionScenarios.swift`) installs through the real path: store page → injected "Add to den" button → download → permission dialog → WebKit load. Result `ok=true`:

| Extension | Source | Result |
|---|---|---|
| uBlock Origin Lite 2026.926.2202 (MV3, DNR, 6 default rulesets, 18,664 rules with `requestDomains` lists up to 50,775 domains) | Chrome Web Store | A 127.0.0.1 test page loading `pagead2.googlesyndication.com/…/adsbygoogle.js`, `securepubads.g.doubleclick.net/tag/js/gpt.js` and `www.google-analytics.com/analytics.js`: all three **loaded** before install, all three **blocked** after. Blocking started **14–31 s** after the install (five runs) (WebKit converts the rulesets to content rule lists in the background; the controller in these runs is non-persistent, so it recompiles every launch). `offscreen` and `userScripts` are unsupported by WebKit |
| ColorPick Eyedropper 0.0.3.3 (MV3, popup) | Chrome Web Store | Popup renders in den's popover (sized 158x330 from its page). WebKit reports "Invalid `web_accessible_resources` manifest entry" and "The background content failed to load", so its picker features don't work |
| Dark Reader 4.9.133 (MV2, persistent background) | Firefox Add-ons (XPI, SHA-256 checked) | Content script runs: the test page's body turns `rgb(24, 26, 27)`. `theme` permission unsupported |

Memory (`scripts/measure-memory.sh main 40`, phys_footprint, den launched through LaunchServices so only its own WebKit processes count, 3 runs each): **0 extensions 267–268 MB** total (den 29–30 MB, one WebContent 206 MB, GPU 21–22 MB, Networking 11 MB); **uBOL installed 344–345 MB** (den **105–107 MB**, WebContent 206–207 MB, same GPU/Networking). uBOL's service worker wasn't running after 40 s (no extra WebContent process). The +76 MB is in den's own process and was still there after 120 s (104 MB); likely WebKit's DNR → content rule list conversion, which runs in the UI process — not verified.

Launch (`--measure-launch`, process start → first window, 10 launches per row, two interleaved rounds, load average 142–418 from other jobs on the machine, so noisy): pre-extensions build median 569 / 544 ms; this build with 0 extensions 686 / 521 ms; with uBOL installed 638 / 700 ms. The spread between rounds is larger than any difference, and by design nothing extension-related runs before the first window (the registry is read at the first web view).

### Why Vimium "did nothing", and den's compatibility layer (2026-09-28, macOS 26.6, CI)

`Tests/PluginTests/ExtensionCompatTests.swift` installs Vimium 2.4.2 (Chrome Web Store and Firefox Add-ons builds), Bitwarden, JSON Formatter and Dark Reader through den's real store path, then drives Vimium with real key events on a 127.0.0.1 page. Vimium installed fine; three WebKit differences stopped it at runtime, each silently:

1. **A content script entry WebKit can't read loses all of them.** Vimium's second `content_scripts` entry matches `file:///` and `file:///*/`. WebKit's content script parser rejects file: patterns (`WKWebExtension.MatchPattern(string:)` accepts them), records "Manifest `content_scripts` entry has no specified `matches` entry", and injected none of Vimium's scripts. den drops patterns WebKit rejects, and entries left with none.
2. **A module service worker never finishes starting.** Chrome's build declares `"service_worker": …, "type": "module"`: `loadBackgroundContent` hung, then "The background content failed to load due to an error". The same code as Firefox's `"scripts": […], "type": "module"` loads. den runs module service workers as module background scripts (a background page; classic workers stay workers).
3. **Missing events end the background at its first `addListener`.** WebKit has `webNavigation` but no `onHistoryStateUpdated` / `onReferenceFragmentUpdated`. Vimium's `main.js` line 87 threw `TypeError`, before it registered its `runtime.onMessage` listener, so every content script's `initializeFrame` message resolved `undefined` and Vimium never entered normal mode: keys reached the page untouched. The page's own `chrome.runtime.sendMessage` round trip, `sender.tab`, async `sendResponse` and `storage.session` all worked.

den's answer is `ExtensionShim` (`Sources/DenHost/Extensions/ExtensionShim.swift`), applied to den's own copy of a store or file install at load (never to `~/.den/extensions`): `__den/shim.js` runs first in the background, content scripts and extension pages. It adds any event WebKit leaves out of a namespace it has (the two above are driven by tab URL changes WebKit reports without a load), stand-ins for `idle`, `offscreen` and `storage.session.setAccessLevel` so start-up code carries on, and (2026-10-05) den's real `bookmarks`, `history`, `sessions`, `search`, `downloads`, `sidePanel`, `sidebarAction` and `identity`. Those are JavaScript calling den over native messaging to den itself (`runtime.sendNativeMessage` / `connectNative` to `io.github.abhishakenp.den`, answered by `WKWebExtensionControllerDelegate`; measured working from an MV3 service worker and extension pages, macOS 26.5), which is how a public-API host adds whole namespaces WebKit compiled out: `unsupportedAPIs` can only remove. What backs each: [host API](../host-api.md#webext). JavaScriptCore unit test: `ExtensionPackageTests.shimFillsMissingEventsAndAPIs`; the bridge end to end: `ExtensionAPIsTests`.

Store pages: the Chrome Web Store serves WebKit a "Switch to Chrome" banner and a disabled "Add to Chrome" (measured user agent `…Version/26.6.2 Safari/605.1.15`). den's install doesn't depend on that page: the URL pill shows **Add to den** for any store item URL. A Chrome user agent on `chromewebstore.google.com` was considered and not done: the store's own button would then call `chrome.webstorePrivate`, which no WebKit browser has, so it would fail after looking like it works.

## 4. Open-source WebKit browsers using WKWebExtension

| Repo | Notes (as of 2026-09-27) |
|---|---|
| https://github.com/duckduckgo/apple-browsers | Apache-2.0, 257★. `SharedPackages/WebExtensions` (loader, manager, native messaging, window/tab provider, tests). Highest-quality reference. |
| https://github.com/nook-browser/Nook | GPL-3.0, 1,948★. `ExtensionManager` (WKWebExtension), `WebStoreDownloader.swift` (CWS + Edge store, CRX2/3 → ZIP), `NookBlocker` (adblock-rust conversion + cosmetic engine). README says macOS 26+, Apple silicon. |
| https://github.com/pauljoda/Crest | MPL-2.0, 62★. CWS + AMO + Safari extension install, CRX3 verification, update checks, per-Space isolation. macOS 26.1+. Claims side panels / Firefox sidebars — how, given WebKit's sidebar flag is off: UNVERIFIED. |
| https://github.com/kageroumado/refrax-browser | GPL-3.0, 42★. `ExtensionManager`, `ExtensionGalleryService`, `ExtensionUpdateChecker`. |
| https://github.com/griffinwork40/agent-browser (PR #37) | Minimal example: load unpacked dir/ZIP, `#available(macOS 15.4, *)` gating. |

Found via GitHub code search for `WKWebExtensionController` in Swift. License caution: GPL code (Nook, Refrax) can't be copied into den unless den is GPL-compatible; DDG (Apache-2.0) and Crest (MPL-2.0, file-level copyleft) are easier to learn from.

## 5. Content blocking on WebKit

### Mechanisms
- `WKContentRuleListStore` / `WKContentRuleList` (macOS 10.13+) [DOC]: compiled JSON rules (block, block-cookies, css-display-none, ignore-previous-rules, make-https, redirect…), applied via `WKUserContentController.add(_:)`. Compiled into bytecode in the network/web process — no JS on the hot path.
- Limit: **150,000 rules per list** [SRC]. Apps can add multiple lists (AdGuard for Safari splits across 6 lists = 900k, https://adguard.com/kb/archive/adguard-for-safari/solving-problems/rule-limit/). Whether WebKit imposes any aggregate cap for an app using many lists: UNVERIFIED (none found in parser).
- Safari 26 added `unless-frame-url`, `request-method` triggers (https://webkit.org/blog/17333/).
- No public API to intercept arbitrary http(s) subresource requests: `setURLSchemeHandler` raises for schemes WebKit handles "such as https" [DOC]. So a uBO-style dynamic network filter (JS deciding per request) is **impossible** in WKWebView; everything must be declarative.

### Gaps vs uBlock Origin
- No blocking `webRequest` → full uBO MV2 won't filter network requests under `WKWebExtension`. uBO Lite (MV3, DNR-only) is on the Safari App Store (https://apps.apple.com/us/app/ublock-origin-lite/id6745342698; https://mjtsai.com/blog/2025/08/06/ublock-origin-lite-for-safari/) and should be the recommended extension-based blocker; DNR was reported "semi-broken until iOS 18.6" [3P] (https://news.ycombinator.com/item?id=44795825).
- Content rule lists lack: uBO procedural cosmetic filters (`:has-text`, `:upward`, …), scriptlet injection (`+js(...)`), response-header/HTML filtering, `$removeparam` nuance, dynamic per-site toggles without recompiling. Regex is a restricted subset.
- Rule-list compile time for ~100k rules is non-trivial: UNMEASURED — benchmark before shipping.

### Making it excellent (den-native blocker)
1. **Network:** compile EasyList + EasyPrivacy + uBO filters + Peter Lowe + annoyances into several `WKContentRuleList`s (≤150k each) using `adblock-rust` `content-blocking` feature (https://github.com/brave/adblock-rust — "conversion of standard ABP-style rules into Apple's content-blocking format") or AdGuard `SafariConverterLib` (https://github.com/AdguardTeam/SafariConverterLib, Swift, also emits "advanced" rules for scriptlets). Compile off-main-thread, cache in a store, diff-update daily.
2. **Cosmetic:** inject per-site generic/specific hide CSS via `WKUserScript`/`WKUserStyleSheet` in an isolated `WKContentWorld`; procedural filters via a small JS engine (adblock-rust's cosmetic cache supplies selectors).
3. **Scriptlets:** inject uBO/AdGuard scriptlets at document-start in the **page** world (required to defeat YouTube-style ad logic). Keep scriptlet resources updatable.
4. **Per-site allowlist:** use `ignore-previous-rules` with `if-domain`/`unless-domain` in a small separate list so toggling a site doesn't recompile the big lists.
5. **Coexist with extensions:** if the user installs uBO Lite, offer to disable den's blocker (Orion's advice).
6. **Measure:** track blocked-count via DNR feedback/web inspector; compare against uBO on Chromium with a fixed site corpus.

## 6. Recommended approach for den

**Phase 1 — WKWebExtension foundation**
- Deployment target macOS 15.4 minimum; consider **macOS 26** (Nook, Crest chose 26.x) to get DNR/extension fixes and avoid supporting early-bug versions. Decide by user base.
- One `WKWebExtensionController` (persistent `Configuration(identifier:)`, separate non-persistent one for private windows).
- Tab/Window model conforms to `WKWebExtensionTab`/`WKWebExtensionWindow`; central event bus that calls `did*` on the controller.
- Toolbar actions + popovers, context menus, commands, options pages, permission prompts, new-tab override.
- Load unpacked dir/ZIP (dev mode) first; verify with a test corpus (uBO Lite, Dark Reader, Bitwarden, Vimium, Stylus, SponsorBlock, Return YouTube Dislike, Refined GitHub, 1Password, Grammarly).

**Phase 2 — store installs + updates**
- CWS: CRX3 download, signature verify, strip header, preserve `key`; "Add to den" button injected on CWS/AMO pages; background update polling (Omaha for CWS, AMO v5 API).
- Show WebKit-compat warnings pre-install by diffing manifest `permissions` and static analysis for missing namespaces (`identity`, `downloads`, `history`, …) — Crest does "WebKit Compatibility Warnings".

**Phase 3 — native gaps**
- Native messaging bridge via `connectUsing`/`sendMessage` delegate → launch Chrome-style native hosts from `~/Library/Application Support/Google/Chrome/NativeMessagingHosts` (feasibility per host: UNVERIFIED).
- Built-in content blocker (section 5).
- Upstream: file WebKit bugs for missing APIs (`identity`, `downloads`, `sidePanel`) rather than hacks.

**Tradeoffs**
| Option | Pros | Cons |
|---|---|---|
| **WKWebExtension (recommended)** | Apple-maintained, same engine as Safari, fixes ship with OS; weeks not years; many OSS references | Coverage fixed by Apple; no blocking webRequest; missing `identity`/`downloads`/`history`/`sidePanel`; behaviour varies by macOS version; macOS 15.4+ only |
| Own JS shim (Orion-style) | Full control, can add missing APIs, MV2 blocking semantics possible only with engine hooks | Orion took years for ~70%; needs private SPI or fork for real request blocking; huge maintenance |
| WebKit fork | Could add blocking webRequest | Lose system WebKit security updates; massive build/infra cost; App Store/notarization issues |
| Hybrid: WKWebExtension + native blocker + targeted polyfills in content world | Best practical coverage | Polyfills can't reach `browser.*` in extension background contexts through public API (UNVERIFIED whether any workaround exists) |

**Expected outcome:** Safari-level extension compatibility (i.e., whatever Safari runs, den runs), plus direct CWS/AMO install. Realistic compat vs Chrome: UNMEASURED — build the test corpus and publish a compat table rather than a number.
