# Gaps vs WebKit browsers: Safari, Orion, DuckDuckGo

Researched 2026-09-27. We compared den with the three shipping WebKit browsers on macOS (Safari 26/27, Kagi Orion, DuckDuckGo for Mac) and list only what den lacks. A feature is not listed if [ROADMAP](../../ROADMAP.md), [FEATURES](../FEATURES.md), the wave 5 plan (`~/.plans/2026-09-27_20-25-den-wave-5.md`) or [apple-platform notes](apple-platform.md) already covers it. Examples: find bar, native dark mode, mini player and PiP, tab mute, downloads, auto grouping, Copy Clean URL (as a clipboard action), content blocker, GPC, HTTPS-first, profiles, Handoff, the vault, passkeys, `WKWebExtension`, Web Inspector, printing and PDF.

This is a doc read, not a test. "Feasible" means a public API exists according to Apple's docs; nothing has been built or run yet. **UNVERIFIED** marks anything no source confirmed.

**Verdicts**
- **must**: removes daily friction at no idle cost.
- **nice**: worth doing later, or only as an optional plugin.
- **skip (bloat)**: not worth doing, or not possible.

**Cost** describes when a feature uses resources. There are no numbers here: nothing was measured.

---

## 1. Reading, listening, translating

| Feature | Who has it | Friction removed | Cost | WKWebView feasibility | Verdict |
|---|---|---|---|---|---|
| **Reader mode**: text size, font, width, background; remembered per site, optional auto-open ([Orion](https://help.kagi.com/orion/features/reader-mode.html)) | Safari, Orion | Cluttered article pages become readable in one keypress | Zero until invoked; one script runs on the current page only | ✅ No Safari Reader API (UNVERIFIED absence). Inject Mozilla Readability.js ([Apache-2.0](https://github.com/mozilla/readability/blob/main/LICENSE.md)) into an isolated `WKContentWorld` | **must**: most-used "calm" feature, no idle cost |
| **Listen to page** (text to speech) | Safari (Listen to Page) | Hear an article while doing something else | Zero until invoked; the system speech engine runs only while playing | ✅ [`AVSpeechSynthesizer`](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer) on the Reader text. Its marker callback can highlight the current word | **nice**: builds on Reader. Put it in the mini player |
| **Page translation**, on device | Safari; Orion (Kagi Translate, with an on-device offline mode on macOS 26+ per [orionbrowser.com](https://orionbrowser.com/platforms/macos)) | Read foreign-language pages without a cloud service | Zero until invoked; a language model loads only while translating | ✅ Apple Translation framework: [`TranslationSession(installedSource:target:)`](https://developer.apple.com/documentation/translation/translationsession/init(installedsource:target:)) (macOS 26, no view needed) and [`translate(batch:)`](https://developer.apple.com/documentation/translation/translationsession/translate(batch:)). [`LanguageAvailability`](https://developer.apple.com/documentation/translation/languageavailability) checks which languages are supported and installed. The download prompt needs the SwiftUI `translationTask` modifier (host it in `NSHostingView`). Language detection via `NLLanguageRecognizer` (UNVERIFIED this session). Flow: collect DOM text nodes via JS, batch-translate, write them back | **must**: on device, private, used daily by non-English readers. Offer it via a URL-bar pill when the page language ≠ the system language |
| Page summaries / Highlights | Safari (Apple Intelligence), Orion (tab summaries) | TL;DR for long pages | Model loads per request | ❌ No Safari API. ✅ Possible with Foundation Models (den already has the `ai` service), but its context is small, so long pages must be chunked | **skip (bloat)** in core. "Nothing beyond the briefing" is den's AI policy; leave it to a plugin |
| Reading List (read later, offline) | Safari, Orion | Save a page for later | Disk only | ✅ Own storage plus `createWebArchiveData` ([WKWebView](https://developer.apple.com/documentation/webkit/wkwebview)) | **skip (bloat)**: Arc's archive and pinned tabs cover it; den skips bookmarks |

## 2. Privacy

| Feature | Who has it | Friction removed | Cost | WKWebView feasibility | Verdict |
|---|---|---|---|---|---|
| **Cookie-banner auto-handling**: pick the most private choice, else hide the banner ([DDG](https://duckduckgo.com/duckduckgo-help-pages/privacy/web-tracking-protections), [how it works](https://insideduckduckgo.substack.com/p/duck-tales-how-duckduckgo-makes-the)) | DDG (Orion: UNVERIFIED) | No more consent-wall clicks on every EU site | One content script per page load; hiding rules can compile into the existing content rule list | ✅ [autoconsent](https://github.com/duckduckgo/autoconsent) (**MPL-2.0**, compatible with MIT: only changes to its own files must stay open). Rules as JSON per consent platform, run as an injected script. Must be skipped on Apple Pay pages (see apple-platform §1.9) | **must**: the largest daily friction on the web, and nobody else in den's comparison set does it |
| **Automatic tracking-parameter stripping on navigation** (not just on copy) | DDG ([params list](https://github.com/duckduckgo/privacy-configuration)); Safari only in Private Browsing / Mail (UNVERIFIED scope in 26) | Links stay clean when you open, share or bookmark them | Zero: a string check in `decidePolicyFor` | ✅ No WebKit API (UNVERIFIED absence). Rewrite the URL in `WKNavigationDelegate.decidePolicyFor navigationAction`. **DDG's list is CC BY-NC-SA 4.0**, so write den's own list (the parameter names are facts: utm_*, gclid, fbclid, mc_eid, …) | **must**: zero cost; den already plans the list for Copy Clean URL |
| **Privacy report / per-site dashboard**: trackers blocked, connection security, permissions ([DDG privacy-dashboard](https://github.com/duckduckgo/privacy-dashboard), Apache-2.0) | Safari, Orion, DDG | Answers "why is this site broken / what was blocked" and gives a one-click "disable blocking here" | A counter per page; the UI loads only when opened | ✅ No Privacy Report API. Count hits from the content blocker; `WKContentRuleList` has no match callback, so exact counts need a `console`/`report` workaround (UNVERIFIED) | **must**, in reduced form: a site panel with blocking on/off per site, permissions and HTTPS status. The report page with charts is **nice** |
| Fingerprinting protection | Safari 26 (Advanced Fingerprinting Protection, [WebKit](https://webkit.org/blog/17333/webkit-features-in-safari-26-0/)); DDG API overrides ([content-scope-scripts](https://github.com/duckduckgo/content-scope-scripts), Apache-2.0); Orion blocks the scripts instead ([Orion](https://help.kagi.com/orion/privacy-and-security/preventing-fingerprinting.html)) | Harder to track you across sites | Blocklist: zero. JS overrides: a script on every page | ❌ No WKWebView toggle; whether WKWebView gets Safari's protection by default is UNVERIFIED. ✅ The Orion approach (block known fingerprinting scripts in the rule list) is free | **must** (the Orion way: blocklist only). DDG-style JS overrides: **skip**, since they cost something on every page and can break sites |
| Referrer trimming, AMP-to-canonical redirect | DDG | Less cross-site leakage; AMP pages open as the real site | Zero | ✅ `overrideReferrerForAllRequests` (macOS 27, apple-platform §1.4) or `Referrer-Policy`; AMP via the navigation delegate | **nice** |
| **Fire button / burn data**: clears this tab, window or everything, but **Fireproofed** sites keep their logins ([DDG](https://duckduckgo.com/duckduckgo-help-pages/privacy/fire-tabs)) | DDG | Wipe everything except the few sites you stay logged in to | Zero until pressed | ✅ `WKWebsiteDataStore.removeData(ofTypes:for:)` filtered by domain; tabs through the `tabs` service | **nice**: den's Today tabs auto-archive already cover the tab side. A "Clear site data" command (per site plus a keep-list) is the cheap part worth shipping |
| Email alias (Duck Address) autofill | DDG | Private throwaway address at signup | Zero | ✅ via autofill; depends on DDG's service | **skip (bloat)**: a service, not browser work; the extension handles it |
| Scam/phishing blocker ([DDG Netcraft feed, hashed prefixes](https://duckduckgo.com/duckduckgo-help-pages/threat-protection/scam-blocker)) | DDG, Safari (Safe Browsing) | Warns before phishing pages | A periodic list download plus lookups | ✅ Build your own (apple-platform §4: no WKWebView Safe Browsing API, UNVERIFIED) | **nice**: needs a data source whose licence allows reuse |
| iCloud Private Relay | Safari | IP hiding | — | ❌ Covers Safari web traffic plus DNS only ([Apple](https://support.apple.com/en-us/102602)) | **skip**: not available to den |
| Privacy test suite | — | Tests that protections actually work | Tests only | ✅ [privacy-reference-tests](https://github.com/duckduckgo/privacy-reference-tests) (Apache-2.0): URL params, referrer, GPC, AMP, storage clearing | **must** (dev tooling): tests only, costs users nothing |

Licence warning: DDG's *data* (tracker lists, tracking-parameter list, HTTPS upgrade list, Tracker Radar) is **CC BY-NC-SA 4.0**, which can't be used in an MIT app that someone may sell. The *code* (autoconsent MPL-2.0; content-scope-scripts, privacy-dashboard, TrackerRadarKit and autofill Apache-2.0) can be reused.

## 3. Per-site settings

Orion's per-site panel on macOS ([docs](https://help.kagi.com/orion/features/website-settings.html)) covers: content blockers, ITP, web fonts, JavaScript, cookies, Reader, extension permissions, zoom 50–300%, autoplay, PiP, user agent, camera/mic/screen sharing, location, notifications, downloads. The ROADMAP has "Per-site permissions UI" but not the rest.

| Feature | Friction removed | Cost | WKWebView API | Verdict |
|---|---|---|---|---|
| **Per-site zoom, remembered** (Safari, Orion) | Stops re-zooming the same small-text site on every visit | A dictionary lookup on navigation | `pageZoom` | **must** |
| **Per-site autoplay** (default: block media with sound, as Orion does; [blog](https://blog.kagi.com/orion-features)) | No surprise audio; also saves energy | Zero | `mediaTypesRequiringUserActionForPlayback` (set per configuration, so it applies when the tab's web view is created) | **must** |
| Per-site pop-up policy (Safari: block / notify / allow) | Allow OAuth pop-ups, block spam | Zero | `javaScriptCanOpenWindowsAutomatically` plus `createWebViewWith` | **must** (the "notify" variant is a small pill) |
| Per-site content-blocker off switch | Fixes broken sites in one click | Zero | Remove the `WKContentRuleList` for that host (or an `ignore-previous-rules` rule) | **must** (same panel as the dashboard) |
| Camera/mic live mute plus indicator in the sidebar | Know and control what's listening | Zero | `setCameraCaptureState` / `setMicrophoneCaptureState` ([WKWebView](https://developer.apple.com/documentation/webkit/wkwebview)) | **must**: small; pairs with the tab mute already in progress |
| Per-site user agent / compatibility mode | Fixes sites that refuse Safari's user agent | Zero | `customUserAgent` | **nice** |
| Per-site JavaScript off | Power users, paywalls | Zero | `WKWebpagePreferences.allowsContentJavaScript` | **nice** |
| Per-site "Reader by default" | Covered by Reader mode above | — | — | (with Reader) |

## 4. Page tweaks and tools

| Feature | Who | Friction removed | Cost | Feasibility | Verdict |
|---|---|---|---|---|---|
| **Remove sticky headers / zap element** ([Orion Page Tweaks](https://help.kagi.com/orion/features/page-tweaks.html); Safari 18+ Distraction Control, UNVERIFIED on 26) | Orion, Safari | Removes cookie bars, "subscribe" boxes and fixed headers that eat vertical space | Zero until used; the saved rule is per-site CSS | ✅ Injected CSS; save rules per host. This is the non-programmer core of Arc's Boosts (already Later) | **must**: pull "zap" forward from Boosts as a standalone command |
| **Screenshot: visible area / full page** (Orion, Arc) | Orion, Arc | Capture a whole page without extensions | Zero until used | ✅ `takeSnapshot` / `createPDF`. Full page needs stitching or `WKSnapshotConfiguration.rect` with the page height (UNVERIFIED for very long pages). Element capture: UNVERIFIED in Orion | **nice**: Arc's research already lists "Capture Full Page"; make it a command |
| Unlock copy & paste on sites that block it | Orion | Selecting and copying text works again | Zero until used | ✅ Injected script that stops `copy`/`selectstart` handlers | **nice** (a command-bar action) |
| Web Archive lookup on dead pages | Orion | A 404 or dead link becomes one click to the Wayback Machine | Zero | ✅ A link on den's error page (error pages already in progress) | **must**: one link on the error page |
| Console error counter in the URL bar | Orion | Quick "is this site broken" signal for developers | Needs a console hook on every page | ✅ Script message handler | **skip**: den's Developer Mode (Later) covers it |
| Page-change alert ("Notify Me", price drop) | Safari 27 ([9to5Mac](https://9to5mac.com/2026/06/09/heres-everything-new-coming-to-safari-on-macos-27-golden-gate/)) | Stops you refreshing a page to check for a change | Periodic background fetches: **not** zero | ✅ `schedule` plus `net` services with a diff | **nice**, as an opt-in plugin; conflicts with "nothing runs until used" |

## 5. Tabs, windows, apps

| Feature | Who | Friction removed | Cost | Feasibility | Verdict |
|---|---|---|---|---|---|
| **Web apps (install a site as an app)**: own Dock icon, float on top, hide title bar ([Orion](https://help.kagi.com/orion/features/web-apps.html), stored in `~/Applications/Orion/WebApps/`) | Safari (Add to Dock), Orion | Gmail, Figma and Linear as separate Cmd-Tab apps | One web view per open app; zero when closed | ⚠️ Safari's Add to Dock is Safari-only. Third parties can generate a small `.app` shim (Orion and Chrome do). Needs stable signing; generated apps and Gatekeeper: UNVERIFIED | **nice** (already "Later" as PWA). Orion proves it works on WebKit |
| Float any window on top | Orion | Keeps a reference page visible | Zero | ✅ `NSWindow.level` | **nice**: small; Little Arc windows could use it |
| Close tabs above / below | Orion ([1.0.7 notes](https://orionbrowser.com/updates/orion-release-notes.html)) | Bulk tab cleanup | Zero | ✅ | **must** (a context menu item; den has multi-select, but this is faster) |
| Hover previews of tabs | Safari, DDG (partial), Orion (switcher only) | Seeing a tab without switching to it | Snapshot already kept for discarded tabs | ✅ `takeSnapshot` (den already saves snapshots for discard) | **nice**: reuse the discard snapshot, no new cost |
| Profiles as separate apps with their own Dock icon | Orion ([profiles](https://help.kagi.com/orion/features/profiles.html)) | Work/personal kept apart in Cmd-Tab | A whole app instance each | ✅ | **skip**: den's profile per space is the Arc model |
| Containers | Orion | — | — | ✅ | **skip**: already Skip in FEATURES |
| Focus mode: hide all chrome, reveal on hover (Orion ⇧⌘F) | Orion | — | — | — | **skip**: den has compact mode (done) |
| Tab-group sync / iCloud Tabs | Safari | — | — | ❌ No API | **skip**: den plans CloudKit sync |

## 6. Apple integration

| Feature | Who | Friction removed | Cost | Feasibility | Verdict |
|---|---|---|---|---|---|
| **Share menu (AirDrop, Messages, Notes, Reminders)** in the page and the context menu | Safari, Orion | Send a page to a phone or person natively | Zero | ✅ `NSSharingServicePicker` (standard AppKit; not re-checked this session) | **must**: absent from the ROADMAP; Arc's "Share" command should call the system picker |
| Shared with You (links from Messages shown in the browser) | Safari | Finding the link a friend sent | — | ❌ [`SWHighlightCenter`](https://developer.apple.com/documentation/sharedwithyou/swhighlightcenter) only returns the app's own associated domains | **skip**: not possible for a general browser |
| Continuity Camera ("insert photo from iPhone" into file inputs) | Safari | Uploading a phone photo to a site | Zero | ⚠️ AppKit services menu; whether it works in WKWebView file inputs is UNVERIFIED | **nice**: check whether it already works for free |
| Screen Time per site | Safari 26 ([WebKit](https://webkit.org/blog/17333/webkit-features-in-safari-26-0/)) | Parental and self limits apply in den too | Zero | Listed as a Safari 26 WebKit feature; the WKWebView opt-in API name is UNVERIFIED | **nice**: check before claiming |
| Website notifications | Safari (full Web Push) | Slack and Gmail alerts from the browser | — | ❌ No Web Push in WKWebView ([forum](https://developer.apple.com/forums/thread/760767)). ⚠️ Only in-page `Notification` bridged to `UNUserNotificationCenter` while the tab is alive, which conflicts with zero-resource tabs | **skip**: already an open ROADMAP question; den's connections cover Slack and GitHub |

## 7. Energy (documented techniques)

| Technique | Who | Friction removed | Cost | Feasibility | Verdict |
|---|---|---|---|---|---|
| **Low Power Mode**: suspend tabs unused for 5 min ([Orion](https://help.kagi.com/orion/features/low-power-mode.html)); Orion claims "up to 90%" less power, a vendor claim not reproduced here | Orion | Longer battery on the go | Saves resources | ✅ den already discards tabs. Missing: a mode tied to **battery / system Low Power Mode** (`ProcessInfo.isLowPowerModeEnabled`) that shortens discard timers, pauses background media prefetch and briefing refreshes, and stops non-visible animations. Anything beyond tab suspension in Orion is UNVERIFIED | **must**: a small policy switch on top of existing discard |
| `inactiveSchedulingPolicy`: `.suspend` / `.throttle` / `.none`, media and capture exempt ([Apple](https://developer.apple.com/documentation/webkit/wkpreferences/inactiveschedulingpolicy-swift.property)) | Safari (WebKit default) | — | — | ✅ Already in apple-platform §3.1 | (covered) |
| Never suspend a tab while you type in a form (DDG content-scope-scripts helper, details UNVERIFIED) | DDG | Discard never loses a half-written comment | Zero | ✅ Check form dirtiness before discarding, via JS or `fetchData` | **must**: a data-loss guard for den's aggressive discard |
| Keep pinned tabs unloaded at launch (Orion 0.99.137 notes) | Orion | Fast launch | Saves resources | ✅ | (covered by den's lazy tabs; check at launch) |
| Orion "120 fps page rendering" ([doc](https://help.kagi.com/orion/features/120-fps-page-rendering.html)) | Orion | Smoother scrolling | More GPU/energy | UNVERIFIED how it's done | **skip**: goes against den's energy goal |

## 8. Small details worth copying

| Detail | Who | Verdict |
|---|---|---|
| "Copy Clean Link" in the **link** context menu, shown only when the link has trackers ([Orion](https://help.kagi.com/orion/features/remove-trackers-from-copied-links.html)) | Orion | **must**: extends den's planned Copy Clean URL to links |
| Clear a copied password from the clipboard after 60 s | DDG | **must** for den's vault: zero cost |
| Ads leave no blank gaps (collapse removed elements) | DDG | **must**: `css-display-none` rules in the blocker |
| "Report broken site" item that also turns blocking off for the site | DDG, Safari 26 (Report Website Issue) | **nice** (the local part is the per-site blocker switch) |
| Screenshot shutter sound, flash and fly-to-Downloads animation | Orion | **nice**: fits Arc's attention to motion |
| Pull down to refresh | Safari 27 | **skip** on Mac; the API mentioned for it (`refreshController`) is UNVERIFIED on macOS |
| Duck Player (YouTube via youtube-nocookie) | DDG | **skip**: a plugin at most |
| Built-in AI chat (Duck.ai), Safari 27 "Describe an Extension", automatic tab groups by AI | DDG, Safari | **skip**: den's AI policy; auto grouping is already in wave B |

---

## Top "must" list (in priority order)

1. Cookie-banner auto-handling (autoconsent, MPL-2.0)
2. On-device page translation (Apple Translation framework)
3. Reader mode (Readability.js), per-site remembered
4. Per-site settings panel: zoom, autoplay (default: block sound), pop-ups, blocker on/off, plus a small privacy summary
5. Automatic tracking-parameter stripping on navigation (den's own list; DDG's is NC-licensed)
6. Zap element / remove sticky headers, saved per site
7. Low Power Mode policy tied to battery / system Low Power Mode
8. Discard guard: never discard a tab with unsaved form input
9. Native Share menu (AirDrop, Messages) via `NSSharingServicePicker`
10. Camera/mic live mute plus indicator; Web Archive link on error pages; Copy Clean Link on links; ads collapse with no gaps; clipboard password clear. All tiny and zero cost.

Also for development: adopt DDG's [privacy-reference-tests](https://github.com/duckduckgo/privacy-reference-tests) (Apache-2.0) to test the protections above.

## Sources not re-checked this session

- `NSSharingServicePicker`, `NLLanguageRecognizer`, Continuity Camera in WKWebView, Screen Time WKWebView API, Safari Distraction Control on 26, full-page snapshot limits, element screenshots in Orion, Orion cookie-banner handling, and anything Orion's Low Power Mode does beyond tab suspension. All are marked UNVERIFIED above.
