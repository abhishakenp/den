# den — Apple platform research (WebKit, Apple Intelligence, efficiency, fundamentals)

Researched 2026-09-27. Current shipping OS: macOS 27 + Safari 27 (released 2026-09-14 — [9to5Mac](https://9to5mac.com/2026/09/09/apple-confirms-macos-27-golden-gate-launch-date-september-14/), [WebKit blog: Safari 27.0](https://webkit.org/blog/18325/webkit-features-for-safari-27-0/)).

**Method.** API names and "introduced" versions below come from Apple's documentation JSON (`developer.apple.com/tutorials/data/documentation/<path>.json`, `metadata.platforms[].introducedAt`), fetched this session. Anything not confirmed that way is marked **UNVERIFIED**.

---

## TL;DR for den

| Decision | Recommendation | Why |
|---|---|---|
| Min OS | **macOS 15.4** (or 26 if we want SwiftUI `WebView`/`WebPage` + storage restore) | `WKWebExtensionController` is 15.4+. Profiles (`WKWebsiteDataStore(forIdentifier:)`) are 14.0+. Foundation Models are 26.0+ and should stay optional at runtime. |
| Web view layer | AppKit `WKWebView` as the core. SwiftUI `WebView`/`WebPage` (macOS 26) only for side panels | Full browser APIs (downloads, printing, `interactionState`, extensions) are on `WKWebView`. Whether `WebPage` covers all of them is UNVERIFIED. |
| Profiles | One `WKWebsiteDataStore(forIdentifier:)` per profile | Isolates cookies and storage. Web views that share a store also share network and content processes. |
| Background tabs | Rely on `WKPreferences.inactiveSchedulingPolicy` (default `.suspend`). For deep sleep, save `interactionState` + `fetchData(of:)`, then destroy the `WKWebView` | Built-in suspension exists for off-window web views (macOS 14+). |
| On-device AI | Foundation Models (`SystemLanguageModel`), gated on availability. Design for a small context window | 4,096 tokens on earlier builds; `contextSize` reports it at runtime. |
| Sync | CloudKit `CKSyncEngine` (macOS 14+) | We don't have to run a server. |
| Updates | Sparkle 2 (EdDSA-signed appcast) | Standard for non–App Store Mac apps. |
| Passkeys | WebKit handles WebAuthn in `WKWebView`. Apply for `com.apple.developer.web-browser.public-key-credential` | Without it, passkeys work only for associated domains. Details and the maintainer steps: [passkeys.md](passkeys.md) |

---

## 1. WKWebView capabilities and limits for a full browser (macOS)

### 1.1 Process model
- WebKit renders in separate WebContent processes, plus shared Networking and GPU processes. Apple's docs: "WebKit renders the content of web views in separate processes, rather than in your app's process space" ([WKProcessPool](https://developer.apple.com/documentation/webkit/wkprocesspool)).
- **`WKProcessPool` is deprecated** (macOS 12.0 / iOS 15.0): "Creating and using multiple instances of WKProcessPool no longer has any effect." Don't design around it. The data store is the isolation boundary.
- Process sharing follows the data store. Web views sharing a `WKWebsiteDataStore` share WebKit's network and content processes; web views with different stores don't ([dev.to summary](https://dev.to/kylmora/six-things-about-wkwebview-the-docs-dont-tell-you-3c08)). Apple doesn't document this directly: **UNVERIFIED against Apple docs**.
- **Site Isolation** in WebKit is under active development, not a finished shipping guarantee. See the WebKit PR "[Site Isolation] Enable shared process mode by default" ([#71657](https://github.com/WebKit/WebKit/pull/71657)) and the iOS 26 inspector changes to a Frame-target model ([inspectdev issue](https://github.com/inspectdev/inspect-issues/issues/241)). Whether cross-site iframes run out of process by default in the macOS 27 WKWebView is **UNVERIFIED**. Don't claim Chromium-equivalent site isolation.

### 1.2 Profiles / website data stores
| API | macOS | iOS |
|---|---|---|
| `WKWebsiteDataStore.init(forIdentifier:)` | 14.0 | 17.0 |
| `WKWebsiteDataStore.fetchAllDataStoreIdentifiers(_:)` / `allDataStoreIdentifiers` | 14.0 | 17.0 |
| `WKWebsiteDataStore.remove(forIdentifier:completionHandler:)` | 14.0 | 17.0 |

- Source: [WebKit blog — Building Profiles with new WebKit API](https://webkit.org/blog/14423/building-profiles-with-new-webkit-api/). Before macOS 14 there was "only one persistent data store."
- `remove` fails while any `WKWebView` still uses the store. Close all of that profile's tabs first.
- Default and non-persistent stores have no identifier. Private windows use `.nonPersistent()`.
- WebKit stores only web data. Bookmarks, history and settings per profile are ours to persist.
- Per-profile proxy: `WKWebsiteDataStore.proxyConfigurations` (macOS 14) is **UNVERIFIED**; the doc path lookup failed.

### 1.3 Core browser APIs (all verified in Apple docs)
| Feature | API | macOS |
|---|---|---|
| Downloads | `WKDownload`, `WKWebView.startDownload(using:completionHandler:)`, `WKNavigationDelegate.webView(_:navigationAction:didBecome:)` | 11.3 |
| Find in page | `WKWebView.find(_:configuration:completionHandler:)` (`isFindInteractionEnabled` is iOS-only; build our own find bar) | 11.0 |
| Printing | `WKWebView.printOperation(with:)` | 11.0 |
| PDF export | `WKWebView.createPDF(configuration:completionHandler:)` | 11.0 |
| Snapshots (tab previews) | `WKWebView.takeSnapshot(with:completionHandler:)` | 10.13 |
| Session restore (back/forward + scroll) | `WKWebView.interactionState` | 12.0 |
| Local/session storage save/restore | `WKWebView.fetchData(of:completionHandler:)`, `restoreData(_:completionHandler:)` ("Local storage and session storage restoration APIs" — [WWDC25 WebKit news](https://webkit.org/blog/16993/news-from-wwdc25-web-technology-coming-this-fall-in-safari-26-beta/)) | 26.0 |
| Zoom | `pageZoom` | 11.0 |
| Theme color (Arc-style tinted chrome) | `themeColor`, `underPageBackgroundColor` | 12.0 |
| Media control | `pauseAllMediaPlayback`, `setAllMediaPlaybackSuspended`, `requestMediaPlaybackState`, `closeAllMediaPresentations` | 12.0 |
| Element fullscreen | `WKPreferences.isElementFullscreenEnabled` (default false), `WKWebView.fullscreenState` | 12.3 / 13.0 |
| AirPlay | `WKWebViewConfiguration.allowsAirPlayForMediaPlayback` | 10.11 |
| Web Inspector | `WKWebView.isInspectable` (must set true; off by default since 13.3) | 13.3 |
| File upload | `WKUIDelegate.webView(_:runOpenPanelWith:initiatedByFrame:completionHandler:)` | 10.12 |
| Camera/mic prompt | `WKUIDelegate.webView(_:requestMediaCapturePermissionFor:initiatedByFrame:type:decisionHandler:)`; state via `cameraCaptureState` / `microphoneCaptureState` | 12.0 |
| Geolocation prompt | `WKUIDelegate.webView(_:requestGeolocationPermissionFor:initiatedByFrame:decisionHandler:)` | **27.0** (new). Before 27, geolocation depends on the app's CoreLocation authorization; exact pre-27 behavior **UNVERIFIED** |
| Content blocking | `WKContentRuleListStore` (Safari content-blocker JSON, compiled) | 10.13 |
| Web Extensions | `WKWebExtension`, `WKWebExtensionController` (via `WKWebViewConfiguration.webExtensionController`) | **15.4** |
| HTTPS-first | `WKWebpagePreferences.preferredHTTPSNavigationPolicy` | 15.2 |
| Lockdown Mode per page | `WKWebpagePreferences.isLockdownModeEnabled` | 13.0 |
| Security restriction mode | `WKWebpagePreferences.securityRestrictionMode` | 26.4 (semantics UNVERIFIED) |
| Global Privacy Control | `WKWebpagePreferences.globalPrivacyControlEnabled` (default NO; sends `Sec-GPC: 1`) | **27.0** |
| Writing Tools | `WKWebViewConfiguration.writingToolsBehavior` (`NSWritingToolsBehavior`), `WKWebView.isWritingToolsActive` | 15.0 |
| Inline predictions | `WKWebViewConfiguration.allowsInlinePredictions` | 14.0 |
| Background-tab throttling | `WKPreferences.inactiveSchedulingPolicy` (default `.suspend`) | 14.0 |

Picture-in-Picture: HTML5 video PiP works in WKWebView through the standard web API (Chord ships PiP on WKWebView — see §5). No dedicated public WKWebView PiP API was found, so a "native PiP button" would need JS (`requestPictureInPicture()`). Treat details as UNVERIFIED.

### 1.4 New in macOS 27 / Safari 27 for embedders
From [WebKit Features for Safari 27.0](https://webkit.org/blog/18325/webkit-features-for-safari-27-0/) and [WWDC26 WebKit news](https://webkit.org/blog/17967/news-from-wwdc26-webkit-in-safari-27-beta/):
- `WKJSHandle`: native references to JS objects.
- `WKContentWorldConfiguration`: configures autofill scripting, shadow-root access and inspectability per content world. Useful for our own autofill and AI page-reading scripts.
- `WKNavigationDelegate` `willSubmitForm` with `WKFormInfo`. **This is the hook for "save password?" prompts.**
- `mainFrameNavigation` on `WKNavigationAction`/`WKNavigationResponse`.
- `WKWebpagePreferences.alternateRequest`, `overrideReferrerForAllRequests`.
- `WKWebView.load(_ url:)` convenience.
- `WKDOMNodeSnapshot` / `WKSerializedNode` (the name differs between the two posts, so the exact name is UNVERIFIED): clone DOM between web views.
- `WKHTTPCookieStore.cookies(for:)`.

### 1.5 SwiftUI `WebView` / `WebPage` (WWDC25)
- `WebView` (SwiftUI view) and `WebPage` (`@Observable` model): **macOS 26.0 / iOS 26.0** (Apple docs). Related: `URLSchemeHandler`, `WebPage.NavigationDeciding`, `WebPage.DialogPresenting`, modifiers `webViewScrollPosition`, `webViewMagnificationGestures`, `findNavigator` ([WWDC25 session 231](https://developer.apple.com/videos/play/wwdc2025/231/), [WebKit blog](https://webkit.org/blog/16993/news-from-wwdc25-web-technology-coming-this-fall-in-safari-26-beta/)).
- `WebPage` works headless, with no view on screen ([folding-sky](https://folding-sky.com/blog/ios-26-macos-26-swiftui-headless-browser-webpage-webview)). That makes it useful for AI "read this page in the background" tasks.
- Whether it covers downloads, printing, extensions and `interactionState` is **UNVERIFIED**. Keep `WKWebView` (NSViewRepresentable) for tabs.

### 1.6 Push notifications for web apps
- Apple's guide covers web push for "Webpages in Safari 16 for macOS 13 or later" and Home Screen web apps ([Apple](https://developer.apple.com/documentation/usernotifications/sending-web-push-notifications-in-web-apps-and-browsers)). It names no WKWebView API.
- Apple forum answers say Web Push doesn't work in apps using WKWebView ([forum 760767](https://developer.apple.com/forums/thread/760767), [728537](https://developer.apple.com/forums/thread/728537)). No public WKWebView Web Push API was found as of macOS 27 (**UNVERIFIED absence**). Chord's "notifications" are probably the in-page Notifications API bridged to `UNUserNotificationCenter` while the tab is alive, not server push.
- Safari "Add to Dock" web apps (macOS 14) are Safari-only.

### 1.7 Passkeys / WebAuthn
- "If your browser app uses WKWebView … WebKit automatically handles `WebAuthentication` challenges" ([Passkey use in web browsers](https://developer.apple.com/documentation/authenticationservices/passkey-use-in-web-browsers)). `ASAuthorizationWebBrowserPublicKeyCredentialManager` (macOS 13.3) checks and requests the user's permission for the browser to use their passkeys.
- Entitlement `com.apple.developer.web-browser.public-key-credential` (macOS 13.3) allows passkeys "for any relying party identifier." It needs an **Account Holder request plus Apple review**. Criteria: declare http/https in Info.plist, offer a URL field/search/bookmarks on launch, navigate directly to destinations ([entitlement doc](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential)).
- Without it, embedded WebViews can use only passkeys for the app's linked domain ([passkeys.dev](https://passkeys.dev/docs/reference/macos/)). **Action: apply early.**

### 1.8 Passwords / iCloud Keychain
- There is no public API for a third-party app to read the user's iCloud Keychain / Passwords-app web passwords. Apple's supported path for other browsers is the **Passwords browser extension** for Chrome/Edge/Chromium-family browsers ([Apple Support](https://support.apple.com/guide/passwords/get-extensions-mchlf7ac261e/mac)). Whether that extension could run in den through `WKWebExtension` is **UNVERIFIED** and unlikely: it pairs with a native helper and ships per store.
- System AutoFill of passwords inside WKWebView forms on macOS, with credentials from Passwords/iCloud Keychain, is **UNVERIFIED**. `WKContentWorldConfiguration` "autofill scripting" (macOS 27) points at WebKit-level autofill hooks, but it isn't system Keychain access.
- Practical plan: build our own vault (Keychain `kSecClassInternetPassword`, as Chord does). Capture credentials with `willSubmitForm` (27). Consider an `ASCredentialProviderExtension`-based integration later (UNVERIFIED feasibility on macOS).
- **Done (2026-09-27):** the `vault` host service and the `passwords` plugin ([host-api.md](../host-api.md#vault)). On macOS 26 a listener in an isolated content world captures submits. `willSubmitForm` is a macOS 27 API and isn't in the 26.5 SDK.

### 1.9 Apple Pay
- WebKit supports Apple Pay in WKWebView, with a restriction. It "cannot be used alongside script injection APIs such as WKUserScript or evaluateJavaScript". Injecting before the page uses Apple Pay disables it for that page, and the restriction resets on each top-frame navigation ([WebKit bug 197751](https://bugs.webkit.org/show_bug.cgi?id=197751), [Safari 13 features](https://webkit.org/blog/9674/new-webkit-features-in-safari-13/), [forum 696572](https://developer.apple.com/forums/thread/696572)).
- One claim says iOS 16 relaxed this ([MetaMask PR](https://github.com/MetaMask/metamask-mobile/pull/36393)). The current macOS behavior is **UNVERIFIED**.
- **Update (2026-09-27, [dark-mode.md](dark-mode.md#apple-pay)):** WebKit removed this rule in 2022 (commit `aa041a623c`, bug 236254, "Permit simultaneous Apple Pay and script injection"). Current `PaymentSession::canCreateSession` doesn't look at injected scripts or user stylesheets, so den doesn't need to skip checkout pages. There was no end-to-end test: `ApplePaySession` isn't exposed in a plain WKWebView here.

### 1.10 Handoff
- `NSUserActivity.webpageURL` (macOS 10.10) lets den advertise the current page for Handoff. Continuing activities from Safari on iPhone into den requires den to be the default browser; the exact behavior is **UNVERIFIED**.

### 1.11 Safari-only (not available to third parties)
- iCloud Tabs / Safari sync, Safari Reading List, Safari Profiles sync, "Add to Dock" web apps, Safari's server-side Web Push integration, Safari's built-in Passwords autofill, Private Relay integration (**UNVERIFIED** for WKWebView), Safari Highlights / Summaries (Apple Intelligence in Safari), Safari MCP server (Safari 27 feature, [9to5Mac](https://9to5mac.com/2026/09/17/webkit-blog-breaks-down-whats-new-with-safari-27-for-developers-including-mcp-support/)).

---

## 2. Apple Intelligence / Foundation Models

### 2.1 Framework basics
| Symbol | macOS | Notes |
|---|---|---|
| `FoundationModels` framework, `SystemLanguageModel`, `LanguageModelSession` | 26.0 | On-device model, Apple silicon, Apple Intelligence must be enabled |
| `Tool` protocol (tool calling) | 26.0 | Tool definitions count against the context ([infoq](https://infoq.com/news/2026/03/apple-foundation-models-context)) |
| `@Generable` / `@Guide` (guided generation, constrained decoding) | 26.0 | `Generable(description:)` verified |
| `SystemLanguageModel.contextSize` | Docs list 26.0 (back-deployed; announced in 26.4) | "Total number of tokens … in a single session, including both input prompts and generated responses." Throws if Apple Intelligence is off or unavailable |
| `tokenCount(for:)` | 26.4 (per [WWDC26 session 241](https://developer.apple.com/videos/play/wwdc2026/241/)) | Overloads for prompts, `Instructions`, tools, schemas, transcripts |
| `LanguageModel` protocol (pluggable backends) | **27.0** | Anthropic/Google ship Swift packages; `CoreAILanguageModel`, `MLXLanguageModel` open source |
| `PrivateCloudComputeLanguageModel` | **27.0** | Server model, 32K-token context per WWDC26 session 241 |

**Context size:** 4,096 tokens on 26.x (Apple dev forum / [infoq](https://infoq.com/news/2026/03/apple-foundation-models-context)). WWDC26 session 241 prints `8192` from `contextSize`, which suggests the rebuilt model in 27 has 8K. Which OS/hardware gives which value is **UNVERIFIED**. **Always read `contextSize` at runtime.** WWDC26 also added image `Attachment` input to the on-device model ([Ivan Magda](https://ivanmagda.dev/posts/wwdc26-foundation-models-year-two/)), so the exact API is UNVERIFIED.

**Browser uses that fit the small context:** tab titling and grouping, rename, "tidy tabs", command-bar intent parsing (via `@Generable` enums), short page summaries (chunked map-reduce over extracted text), form-fill suggestions, local history search re-ranking. Chat over whole long pages needs chunking or PCC.

### 2.2 Private Cloud Compute for third parties
- Yes, as of 27, with gating. Eligibility: App Store Small Business Program, <2M first-time App Store downloads, and the PCC managed entitlement. Apps "distributed on the App Store", tested via TestFlight/ad hoc ([developer.apple.com/private-cloud-compute](https://developer.apple.com/private-cloud-compute/)). There's also a per-user daily quota ([Ivan Magda](https://ivanmagda.dev/posts/wwdc26-foundation-models-year-two/)).
- **Implication for den:** a Sparkle/direct-download build likely **cannot** use PCC, because the docs speak of App Store distribution. Mac App Store browsers are possible (sandboxed), but it's a big product decision. Treat PCC as **UNVERIFIED for non-App-Store distribution**.

### 2.3 Writing Tools in web content
- Writing Tools work in WKWebView editable content. Control them with `WKWebViewConfiguration.writingToolsBehavior` (macOS 15.0) and observe with `WKWebView.isWritingToolsActive`. We get this without extra work; just don't disable it.

### 2.4 App Intents / Shortcuts / Spotlight
- `AppIntents` (macOS 13.0) exposes actions like "Open URL in den profile", "Search tabs" and "Summarize current page" to Shortcuts, Spotlight and Siri. `AssistantSchema` (macOS 15.0) plugs into Apple Intelligence Siri schemas; whether a "browser" domain exists is **UNVERIFIED**.
- `CSSearchableIndex` / `CSSearchableItem` (Core Spotlight, macOS 10.11) can index bookmarks and pinned tabs for system Spotlight. Make it opt-in, since indexing history is a privacy choice.

---

## 3. Efficiency

### 3.1 Techniques available with WKWebView
1. **Built-in background suspension.** `WKPreferences.inactiveSchedulingPolicy` (macOS 14): "how a web view that's not in a window handles tasks; for example … a background tab … default value is `suspend`. … exempted … if it is playing media, performing media capture…" This means **detaching background tabs from the window hierarchy** (not just hiding them) triggers suspension. Arc-style tab switching must remove inactive `WKWebView`s from the view tree.
2. **Discard (true unload).** After N minutes or under memory pressure, capture `interactionState` (12.0) and a `takeSnapshot` image, plus `fetchData(of:)` (26.0) for session storage. Then release the `WKWebView`. On reactivation, create a new view and apply `interactionState` / `restoreData`. This frees the WebContent process when no other view uses it.
3. **Memory pressure.** Listen to `DispatchSource.makeMemoryPressureSource` and discard least-recently-used tabs first. The API is standard; thresholds need measuring, and none are provided here.
4. **Media.** `setAllMediaPlaybackSuspended` / `pauseAllMediaPlayback` (12.0) for "pause all" and discarding.
5. **Fewer processes.** One data store per profile, not per space. Every extra store adds its own network/process set (see §1.1).
6. **Content blocking** via compiled `WKContentRuleList` (declarative, native), not JS blockers. Fewer requests means less CPU/network.
7. **UI side.** Avoid SwiftUI redraw storms from `@Observable` properties like `estimatedProgress`/`title` across all tabs. Observe only the visible tab, throttle favicon/title updates, and use `CALayer`-backed snapshots in the sidebar rather than live views.

### 3.2 Measurement tools
- Xcode debug navigator Energy Impact gauge and Instruments ([Energy Efficiency Guide for Mac Apps](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/MonitoringEnergyUsage.html)).
- Power Profiler ([Apple docs](https://developer.apple.com/documentation/Xcode/measuring-your-app-s-power-use-with-power-profiler), [WWDC25 226](https://developer.apple.com/videos/play/wwdc2025/226/)). The WWDC session focuses on iPhone; **Mac support UNVERIFIED**.
- `powermetrics` (macOS CLI, needs sudo) for CPU/GPU power and per-process energy. Activity Monitor "Energy" tab. WebKit's helper processes (`com.apple.WebKit.WebContent`, `.Networking`, `.GPU`) must be **summed with den's process** when measuring. They show as separate processes, attributed to den in Activity Monitor's grouped view (grouping is **UNVERIFIED**).
- Build a repeatable benchmark: a scripted tab set, fixed brightness, N loops, averaged over runs (the Birchler method below).

### 3.3 Documented Safari/WebKit vs Chromium data (no guesses)
| Source | Claim / result | Caveat |
|---|---|---|
| Apple marketing (apple.com/safari, as reported by [The Register](https://www.theregister.com/2023/02/28/google_chrome_mac_battery/)) | Safari gives "up to" 2 more hours of streaming video than Chrome/Edge/Firefox (M2 13" MBP test) | Vendor claim. Current apple.com figures **UNVERIFIED** (not fetched) |
| [Matt Birchler, 36-hour test](https://birchtree.me/blog/everyone-says-chrome-devastates-mac-battery-life-but-does-it-i-tested-for-36-hours-to-find-out/) | M2 Pro 14", Safari 17.6 vs Chrome 128, 20-min scripted loop × 9 × 6 runs, 30% brightness. Chrome **17.33%** drain per 3h vs Safari **18.67%** | Single machine, older versions, variance noted by author |
| [Chris Coyier, 2026-04](https://chriscoyier.net/2026/04/24/its-an-assumed-truth-that-safari-is-better-for-battery-life-without-data-to-support-it/) | Argues the "Safari = better battery" belief lacks data | Opinion piece (not fetched in full) |

**Conclusion:** WebKit doesn't make den efficient automatically. The wins must come from den's own architecture: suspension and discarding, native blocking, and a lean UI. Dia's heaviness is a Chromium + app-architecture issue, but we must **measure** den against Safari/Arc/Dia with the same harness before making claims.

---

## 4. Great-browser fundamentals checklist

### Privacy
- [ ] ITP: WebKit's tracking prevention applies to WKWebView browsers by default since iOS 14 era ([Full Third-Party Cookie Blocking](https://webkit.org/blog/10218/full-third-party-cookie-blocking-and-more/), [Tracking Prevention in WebKit](https://webkit.org/tracking-prevention/)). The macOS WKWebView default is **UNVERIFIED**; test with a known cross-site cookie page.
- [ ] Tracker/ad blocking: EasyList/EasyPrivacy → Safari content-blocker JSON → `WKContentRuleListStore`, with scheduled updates (Chord's approach). Note the per-list rule cap exists but the number is **UNVERIFIED**, so check the Apple docs before splitting lists.
- [ ] Fingerprinting: Safari 26 blocks known fingerprinting scripts from reading screen, hardware concurrency and similar values ([WebKit WWDC25](https://webkit.org/blog/16993/news-from-wwdc25-web-technology-coming-this-fall-in-safari-26-beta/)). Whether WKWebView clients get "Advanced Fingerprinting Protection" or a toggle is **UNVERIFIED**.
- [ ] GPC toggle (`globalPrivacyControlEnabled`, macOS 27). HTTPS-first (`preferredHTTPSNavigationPolicy`, 15.2).
- [ ] Private windows: `WKWebsiteDataStore.nonPersistent()`, no history, no snapshots on disk.
- [ ] Zero telemetry by default (Orion's stance).

### Security
- [ ] Hardened Runtime + App Sandbox (sandbox is required for the Mac App Store and optional for Developer ID). WebContent processes are sandboxed by WebKit itself.
- [ ] Site isolation: rely on WebKit, but don't advertise it (§1.1).
- [ ] Per-page Lockdown Mode (`isLockdownModeEnabled`).
- [ ] Safe Browsing warnings (allowed by the passkey entitlement criteria). A WKWebView Safe Browsing API is **UNVERIFIED**; we may need our own.
- [ ] Auto-update: Sparkle 2. EdDSA (ed25519) signatures, `SUPublicEDKey`, optional `SURequireSignedFeed`, delta updates via `generate_appcast`, needs Developer ID signing ([Sparkle docs](https://sparkle-project.org/documentation/)). WebKit itself updates with the OS, so engine security patches come through macOS updates and not ours.

### Session restore and crash recovery
- [ ] Persist window/space/tab tree + per-tab `interactionState` often (debounced) and atomically.
- [ ] `WKNavigationDelegate.webViewWebContentProcessDidTerminate(_:)` → show a "tab crashed, reload" state. Use it for jetsam/OOM kills too (API is long-standing; version not rechecked this session).
- [ ] Restore lazily: create `WKWebView`s only for visible tabs and show snapshots for the rest.

### Sync without owning a server
- [ ] `CKSyncEngine` (macOS 14.0 / iOS 17.0, verified) over the user's private CloudKit database for spaces, pinned tabs, bookmarks and settings. Candoa/Talos does iCloud/CloudKit workspace sync (§5). Requires iCloud entitlement + container, and works outside the App Store with Developer ID + provisioning profile (**UNVERIFIED specifics**).

### Import
- [ ] Chrome/Chromium/Arc/Dia: profile dirs under `~/Library/Application Support/<vendor>/` (`Bookmarks` JSON, `History` SQLite). Chromium passwords are encrypted with a key in the login keychain ("Chrome Safe Storage"), which triggers a Keychain prompt (**UNVERIFIED** current scheme).
- [ ] Arc sidebar/spaces: `StorableSidebar.json` ([export-arc-bookmarks](https://github.com/xiaogliu/export-arc-bookmarks)). Arc's own importer is documented in [Arc Help](https://resources.arc.net/hc/en-us/articles/19335089616791-Import-Bookmarks-Logins-History-Extensions-from-Your-Previous-Browser).
- [ ] Safari: `~/Library/Safari/Bookmarks.plist` and `History.db` are TCC-protected, so Full Disk Access is required (**UNVERIFIED** exact behavior). Fallback: the user exports from Safari (File > Export) or we accept an HTML bookmarks file.
- [ ] Firefox: `places.sqlite` in the profile dir.
- [ ] Netscape bookmarks HTML import/export as the universal fallback.

### Accessibility
- [ ] WKWebView exposes web content to VoiceOver. The native chrome (sidebar, command bar) needs proper `NSAccessibility` labels and roles, full keyboard navigation, Reduce Motion / Increase Contrast support, and Dynamic Type-like scaling.

### Default browser
- [ ] Declare `http`/`https` URL schemes and HTML document types in Info.plist. `NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:completion:)` (macOS 12.0) triggers the system consent prompt.

### Profiles
- [ ] §1.2. Map "Space → Profile" (Arc model): multiple spaces can share one profile store to keep the process count down.

### Extensions
- [ ] `WKWebExtensionController` (15.4) runs Safari-style Web Extensions (MV2/MV3). Chrome Web Store `.crx` loading means unpacking + converting (Chord, Talos, Orion do this). Orion reports ~70% WebExtensions API coverage on its own engine work ([Kagi](https://help.kagi.com/orion/misc/technical.html)); that isn't a measure of `WKWebExtension`.

---

## 5. Open-source Swift/WebKit browsers worth studying

| Project | URL | License | Min macOS | Learn from |
|---|---|---|---|---|
| **Ora** | https://github.com/the-ora/browser | GPL-3.0 (copyleft; can't copy code into a permissive den) | 15 | SwiftUI + AppKit structure, spaces as isolated profiles, vertical sidebar, content blocking, XcodeGen setup, Sparkle. "Not ready for daily use." ~2.2k stars at fetch time |
| **Talos** (repo `aamancio/candoa-browser`, formerly Candoa) | https://github.com/aamancio/candoa-browser | MPL-2.0 (file-level copyleft; name/icon trademarked) | 14 | Clean service split (BrowserStore, WebViewCoordinator, PersistenceService, NavigationService, FaviconService), **CloudKit workspace sync**, split view, Chrome Web Store extensions, Sparkle, "cheap background tabs" |
| **Chord** | https://github.com/Drzaln/chord-browser | **Source-available, all rights reserved.** Read for ideas only, never copy | 15.4 | Arc interaction model; WebKit isolated behind a `ChordEngine` layer; EasyList/EasyPrivacy → `WKContentRuleList` weekly; `WKWebExtension` host with `.crx`/`.xpi` unpacking + signature check; Keychain password vault; per-site per-Space permissions; ADRs (e.g., ADR 013: YouTube ads need JS, not rules); 681 tests |
| **DuckDuckGo apple-browsers** | https://github.com/duckduckgo/apple-browsers | Apache-2.0 (except Duck Sans font) | UNVERIFIED | Production-grade WebKit macOS browser: tracker blocking, autofill, import, sync, crash handling. Best reference for "how a shipping WKWebView browser handles the hard parts" |
| **MacPin** | https://github.com/kfix/MacPin | UNVERIFIED | UNVERIFIED | Site-specific-browser container on WebKit/JavaScriptCore. Useful for "web app" windows |
| Orion (closed source, reference only) | https://orionbrowser.com / [tech docs](https://help.kagi.com/orion/misc/technical.html) | Proprietary | — | Proves WebKit + Chrome/Firefox extensions + zero telemetry works as a product |

More candidates: [GitHub topic: browser (Swift)](https://github.com/topics/browser?l=swift).

**Licensing note:** den's own license choice decides what we can reuse. Apache-2.0 (DDG) is the most reusable. GPL-3.0 (Ora) and MPL-2.0 (Talos) have copyleft obligations. Chord is not reusable.

---

## Open questions / to verify with a prototype
1. Does `inactiveSchedulingPolicy = .suspend` apply to web views that are removed from the window but kept alive? Measure CPU of background tabs with `powermetrics`.
2. Process count per profile / per N tabs on macOS 27. Measure with Activity Monitor or `ps` once the prototype exists.
3. Does ITP/fingerprinting protection apply to den's WKWebView by default on macOS 27?
4. Pre-27 geolocation behavior. Apple Pay plus our content-blocker/user-script setup on real checkouts.
5. Is PCC eligible for a non-App-Store (Sparkle) build?
6. Does SwiftUI `WebPage` expose enough (downloads, extensions, `interactionState`) to replace `WKWebView`?
