# Gaps vs Chrome, Edge, Brave, Vivaldi, Opera

Researched 2026-09-27. This lists the everyday conveniences in the five big Chromium browsers that den does **not** already have or plan. Before writing it I checked [`ROADMAP.md`](../../ROADMAP.md), [`FEATURES.md`](../FEATURES.md), [`plugin-services.md`](../plugin-services.md), [`host-api.md`](../host-api.md) and the wave-5 plan (`~/.plans/2026-09-27_20-25-den-wave-5.md`).

**How to read it**
- **Resource cost** is qualitative only. No numbers were measured for den.
- **Feasibility** cites Apple's documentation. macOS versions come from Apple's doc JSON (`developer.apple.com/tutorials/data/documentation/<path>.json`), fetched this session.
- **Verdicts:**
  - **must**: removes daily friction at almost no idle cost.
  - **nice**: good as an optional, lazy plugin.
  - **skip (bloat)**: not worth building.
- **UNVERIFIED** means no primary source was confirmed, or it hasn't been prototyped on WKWebView.

## TL;DR: the "must" list

1. **Per-site Shields panel.** One popover per site with blocked counts, a blocker toggle, and the site's permissions and data.
2. **Clean navigation.** Skip bounce-tracking redirects and strip tracking query parameters on every navigation.
3. **Cookie-banner hiding.** Compile the EasyList Cookie list into a content rule list.
4. **Battery saver.** When unplugged or in Low Power Mode, discard sooner, pause background media and require a click before videos autoplay.
5. **"Always keep these sites active"** list for tab discard, plus a visual marker on discarded tabs.
6. **Per-site zoom memory.**
7. **HTTPS-first**, falling back to HTTP with an interstitial page.
8. **Copy link to highlight** (text fragments).
9. **Easy Files.** den's own upload picker, showing recent downloads, screenshots and the clipboard first.
10. **Reader view**, injected only when asked, with read aloud.
11. **Share menu:** the macOS share sheet (AirDrop, Messages, Notes) plus a QR code.

---

## 1. Already covered or in flight (not gaps)

| Other browser's feature | den equivalent |
|---|---|
| Chrome tab search (`Cmd+Shift+A`), Opera Search in tabs (`Ctrl+Space`), Vivaldi Quick Commands (`⌘E`) | Command bar: tabs, archive/history, spaces, actions, frecency |
| Edge vertical tabs, Vivaldi tab stacks, Opera Tab Islands | Sidebar tabs, folders; auto tab grouping is next (Wave B) |
| Vivaldi tiling, Edge/Opera split screen | Split view up to 4 panes, grid, drag-to-split |
| Opera/Edge Workspaces | Spaces, with a profile per space |
| Chrome Memory Saver, Edge sleeping tabs, Opera tab snoozing, "tab freeze" | Zero-resource discard (A1) |
| Opera video popout (auto on tab switch) | den mini player (A1). See §7 for details worth copying |
| Chrome/Vivaldi keyboard shortcut editors | Remappable shortcuts (roadmap). See §6 for one small addition |
| Brave "Copy clean link" | "Copy clean URL" (v1) |
| Vivaldi sessions, Chrome "continue where you left off" | Session restore, archive, spaces |
| Tab hover preview (Edge, on by default) | Hover card / `previews` plugin |
| Mute tab | A1 |
| Find bar, error pages, JS dialogs, Settings, standard menus | A2, in progress |
| Downloads | Wave B |
| Ad/tracker blocker, uBO Lite | Roadmap (content rule lists) |
| Password vault | A3 (Keychain + Touch ID) |

---

## 2. Privacy and cleanliness (Brave)

| Feature (who) | Friction it removes | Resource cost | Feasibility on WKWebView | Verdict |
|---|---|---|---|---|
| **Per-site Shields panel** (Brave). One lion-icon popover per site: ads/trackers Standard/Aggressive, fingerprinting, script blocking, blocked counts, "Forget me". [Brave help](https://support.brave.app/hc/en-us/articles/360022806212-How-do-I-use-Shields-while-browsing), [brave.com/shields](https://brave.com/shields/) | "Why is this site broken?" becomes one click to fix it for this site only | ~0 idle: a popover built on demand. Per-site allow-lists use `ignore-previous-rules` entries or a separate rule list, so toggling means recompiling or swapping lists | Content rule lists are public API (see [extension notes §5](extensions-on-webkit.md)). Counting blocked requests: WebKit has no public per-request "blocked" callback for content rule lists, so **counts are UNVERIFIED** (possible sources: `_WKContentRuleListAction` (private) or a JS `PerformanceObserver` estimate). Toggle, permissions and data parts: feasible | **must**. The blocker is already planned; without a per-site escape hatch, users disable it globally |
| **Debouncing** (Brave). Turns `tracker.com/?url=dest` bounce redirects into a direct navigation to `dest`. Rule types: `redirect`, `base64,redirect`, `regex-path`, `regex-path-template`. Security redirectors (Google/Facebook link checkers) are deliberately excluded. [wiki](https://github.com/brave/brave-browser/wiki/Debouncing), list: [`brave-lists/debounce.json`](https://github.com/brave/adblock-lists/tree/master/brave-lists) | Faster clicks from email and newsletters; no tracking hop | ~0: string and regex checks in `decidePolicyFor navigationAction`, then cancel and load the destination. Rules are one small JSON file, loaded lazily | Feasible for top-level navigations via `WKNavigationDelegate` policy decisions. The list is MPL-2.0 (checked via GitHub API). Shipping it as a data file next to MIT code: MPL is file-level copyleft; **legal read UNVERIFIED** | **must** |
| **Query-parameter filtering** (Brave). Strips user-level IDs (e.g. `fbclid`, `gclid`, `mkt_tok`) from cross-site navigations. Rule types: simple, conditional, scoped. [wiki](https://github.com/brave/brave-browser/wiki/Query-String-Filter), [list in source](https://github.com/brave/brave-core/blob/master/components/query_filter/browser/utils.cc), [`query-filter.json`](https://github.com/brave/adblock-lists/tree/master/brave-lists) | Clean URLs in history, shares and the command bar, with no separate copy step | ~0 (same hook as debouncing) | Top-level navigations: feasible (rewrite in the navigation policy). Brave also strips subresources. Content rule lists can't strip params (no `removeparam`, per [extension notes](extensions-on-webkit.md)), so **subresource stripping is not feasible**. Safari has its own link-tracking protection; **whether WKWebView exposes it is UNVERIFIED** | **must** (share the engine with Copy clean URL) |
| **Cookie-notice blocking** (Brave, on by default since 2023-06-09; uses EasyList Cookie). [Brave post](https://brave.com/privacy-updates/21-blocking-cookie-notices/), [BleepingComputer](https://www.bleepingcomputer.com/news/security/brave-browser-to-start-blocking-annoying-cookie-consent-banners/) | The most common daily annoyance on the web | Compiled rules, no JS on the hot path | `css-display-none` + `block` actions in `WKContentRuleList` (feasible). Some banners need scriptlets. Coverage vs Brave: **UNVERIFIED** | **must** |
| **De-AMP** (Brave). Rewrites AMP links on Google results, or loads the page's `rel=canonical` when AMP markup is detected. [Brave help](https://support.brave.app/hc/en-us/articles/8611298579981-What-is-Brave-s-De-AMP-feature), [issue](https://github.com/brave/brave-browser/issues/20458) | Real publisher pages instead of Google-hosted AMP | Small user script, only on pages with AMP markup | Feasible: a user script reads `html[amp]` / `link[rel=canonical]` and navigates. It injects scripts, so apply the Apple Pay exception. How much desktop search still serves AMP: **UNVERIFIED** | **nice**. Mostly a mobile problem |
| **Forgetful browsing** (Brave). Per-site "Forget me when I close this site" clears cookies, storage, cache and DNS a few seconds after that site's last tab closes. [Brave post](https://brave.com/privacy-updates/25-forgetful-browsing/), [BleepingComputer](https://www.bleepingcomputer.com/news/security/brave-unveils-new-forgetful-browsing-anti-tracking-feature/) | Stay logged out of nosy sites without using a private window | ~0: one data-store call when the tab closes | `WKWebsiteDataStore.removeData(ofTypes:for:)` (macOS 10.11). Fits as a Shields-panel toggle | **nice** |
| **Global Privacy Control** (Brave on by default) | Opt-out signal with no user effort | ~0 | `WKWebpagePreferences.globalPrivacyControlEnabled`: **macOS 27.0** only. On 26 it would have to be injected (header plus `navigator.globalPrivacyControl`, **UNVERIFIED**) | **nice** (turn on when running on 27) |
| **HTTPS by default** (Brave, Chrome "Always use secure connections") | No silent HTTP pages | ~0 | `WKWebpagePreferences.preferredHTTPSNavigationPolicy` / `UpgradeToHTTPSPolicy` (macOS 15.2) and `WKWebViewConfiguration.upgradeKnownHostsToHTTPS` (11.3). The fallback-interstitial behavior of the policy is **UNVERIFIED**; prototype it | **must** |
| **Private window with Tor** (Brave) | — | Bundles a Tor daemon, which is heavy | Would need a SOCKS proxy per data store (`WKWebsiteDataStore.proxyConfigurations`, macOS 14; **UNVERIFIED** for Tor) | **skip (bloat)**. Not trivial |
| Playlist, Speedreader (Brave) | — | — | Reader view (§5) covers Speedreader | **skip (bloat)** |

## 3. Tabs and memory (Chrome, Edge, Opera)

| Feature (who) | Friction it removes | Resource cost | Feasibility | Verdict |
|---|---|---|---|---|
| **"Always keep these sites active"** exclusions (Chrome Memory Saver, Edge sleeping tabs). Edge also never sleeps tabs using audio, media capture or WebUSB. [Chrome help](https://support.google.com/chrome/answer/12929150?hl=en), [Edge performance](https://support.microsoft.com/en-us/topic/learn-about-performance-features-in-microsoft-edge-7b36f363-2119-448a-8de6-375cfd88ab25) | Slack, Figma or a running form don't reload and lose state after a short discard | Keeps those tabs resident, by the user's choice | A domain list checked before discarding. Also exempt tabs capturing camera or mic: `WKWebView.cameraCaptureState` / `microphoneCaptureState` (macOS 12). A1 already exempts audio/video/PiP | **must**. den's default discard is aggressive, so users need an escape hatch |
| **Discarded-tab indicator** (Chrome inactive-tab indicator; Edge "Fade inactive tabs", whose removal is **UNVERIFIED**) | Know which click will reload the page | ~0 | Sidebar styling only | **must** (tiny; part of the same work) |
| **Tab memory on hover card** (Chrome 119+, toggle in Appearance). [9to5Google](https://9to5google.com/2023/11/07/chrome-tab-memory-usage/) | Find the tab that's eating RAM | ~0 when shown, but needs a PID per tab | WKWebView has no **public** WebContent PID (`_webProcessIdentifier` is private SPI). Tabs can share a process. **Feasibility UNVERIFIED** | **nice** (only if a public path exists; otherwise a den-wide memory readout in the Library) |
| **Performance detection / "Fix now"** (Chrome, Edge Performance Detector). [Google blog](https://blog.google/products-and-platforms/products/chrome/google-chrome-performance-controls-october-2024/) | One click to tame runaway tabs | Needs per-tab CPU sampling, which costs something | Same PID limit as above: **UNVERIFIED** | **skip**. den's discard is already aggressive; a watchdog adds constant work |
| **Battery / energy saver** (Chrome: ≤20% battery or unplugged, limits background activity, smooth scroll and video frame rate; Edge on macOS at 20%; Opera battery saver pauses animations and background tabs). [Google blog](https://blog.google/products/chrome/new-chrome-features-to-save-battery-and-make-browsing-smoother/), [Opera help](https://help.opera.com/en/latest/features/) | Longer battery life with no thought | Negative (it saves) | `ProcessInfo.isLowPowerModeEnabled` (macOS 12) plus power-source notifications (IOKit). Levers: shorter discard timer, `setAllMediaPlaybackSuspended` (macOS 12) on background views, `mediaTypesRequiringUserActionForPlayback` (10.12) for new tabs. Frame-rate capping: no public API (**UNVERIFIED**) | **must**. Matches den's core promise |
| **Close duplicate tabs** (Opera duplicate highlighter; Chrome tab declutter, Stable status **UNVERIFIED**) | Clean up after a research session | ~0 | Sidebar and command-bar action | **nice** |
| **Tab opened from a link grouped with its parent** (Opera Tab Islands auto-grouping, Vivaldi "stack with related tab"). [Opera blog](https://blogs.opera.com/desktop/2023/06/opera-tab-islands/), [Vivaldi help](https://help.vivaldi.com/desktop/tabs/tab-stacks/) | Tab lists stay grouped by task without AI | ~0 | Opener is known (`createWebViewWith` / navigation action) | **nice**. A rule-based input to the Wave B auto grouping |
| Edge startup boost (Windows only). [MS support](https://support.microsoft.com/en-us/edge/get-help-with-startup-boost) | — | Resident background processes | — | **skip (bloat)**. Goes against idle-cost-zero |

## 4. Navigation and sharing (Chrome, Opera, Vivaldi)

| Feature (who) | Friction it removes | Resource cost | Feasibility | Verdict |
|---|---|---|---|---|
| **Copy link to highlight** (Chrome 90+, select text → right-click). [Chrome help](https://support.google.com/chrome/answer/10256233) | Share the exact sentence, not "scroll down to…" | ~0: generation script injected only when used | WebKit **opens** text fragments since Safari 16.1 ([WebKit blog](https://webkit.org/blog/13399/webkit-features-in-safari-16-1/)). **Creating** one: [GoogleChromeLabs/text-fragments-polyfill](https://github.com/GoogleChromeLabs/text-fragments-polyfill) `fragment-generation-utils.js` (Apache-2.0), evaluated in an isolated `WKContentWorld` on demand | **must** |
| **Per-site zoom memory** (Chrome, Edge, Vivaldi) | Zoom a small-text site once and keep it | ~0: a small table in storage | `WKWebView.pageZoom` (macOS 11), applied on commit | **must** |
| **Share menu + QR code** (Chrome "Cast, save and share" → QR, Send to your devices). [Chrome help](https://support.google.com/chrome/answer/10051760) | Get a page onto your phone or to a person | ~0 | `NSSharingServicePicker` (10.8) gives AirDrop/Messages/Notes; Core Image `CIQRCodeGenerator` for the QR. "Send tab to self" is Handoff/iCloud territory (roadmap: Handoff, CloudKit sync) | **must** (share sheet), **nice** (QR) |
| **Selection popup with unit/time-zone/currency conversion** (Opera). Currency uses ECB/NBU reference rates. [Opera help](https://help.opera.com/en/latest/search/), [feature page](https://www.opera.com/features/units-converter) | "18:30 KST → my time", "5 ft → m" without a new tab | Units and time zones: local, ~0. Currency: a daily rate fetch | A selection listener in an isolated world, or den's context menu (`willOpenMenu`) | **nice** as a context-menu and command-bar answer. **Skip** the always-on popup, which is noisy |
| **Calculator and filter prefixes in the launcher** (Vivaldi Quick Commands: `tab:`, `history:`, `command:`, `action:`; the calculator copies the result on Enter). [Vivaldi help](https://help.vivaldi.com/desktop/tools/quick-commands/) | Quick math and precise search from the same bar | ~0 | `NSExpression` or a small parser inside the `commandbar` plugin | **nice** |
| **Command chains** (Vivaldi: a sequence of commands with ms delays, bound to a key, gesture or toolbar button). [Vivaldi help](https://help.vivaldi.com/desktop/tools/command-chains/) | Power-user macros | ~0 | den's command registry makes this a small plugin | **nice** (plugin) |
| **Reverse image search** from the image context menu (Chrome Lens is AI-backed; non-AI variant: open the image in a search engine) | "Where is this image from?" | ~0 | Context-menu item that opens a URL | **nice** (plugin; no Lens) |
| **Typo-squatting warning** (Edge). [MS security](https://support.microsoft.com/en-us/topic/learn-about-security-features-in-microsoft-edge-f450ebd7-a394-42ce-bbb9-74c1ed332813) | Typing `gooogle.com` | Needs a popular-domain list | Command-bar check. Good lists: **UNVERIFIED** | **nice** |

## 5. Reading and documents (Edge, Chrome, Vivaldi)

| Feature (who) | Friction it removes | Resource cost | Feasibility | Verdict |
|---|---|---|---|---|
| **Reader view** (Edge Immersive Reader `F9`; Chrome Reading mode with font, size, theme and spacing). [Edge](https://support.microsoft.com/en-US/edge/use-immersive-reader-in-microsoft-edge), [Chrome](https://support.google.com/chrome/answer/14218344) | Articles buried under popups, ads and banners | 0 until invoked, then one parse | No public Safari Reader API in WKWebView. `WKWebExtensionTab` has reader-mode hooks for extensions ([extension notes](extensions-on-webkit.md)), but den still has to provide the reader. [mozilla/readability](https://github.com/mozilla/readability) (Apache-2.0) in an isolated world, rendered with den theme tokens | **must** |
| **Read aloud** (Edge `Ctrl+Shift+U`, with paragraph skip, voice and speed). [MS](https://www.microsoft.com/en-us/edge/learning-center/customize-read-aloud-settings) | Listen to an article while doing something else | 0 until used | `AVSpeechSynthesizer` (macOS 10.14) over the reader text. macOS "Speak selection" already exists system-wide | **nice** (a button in reader view) |
| **PDF annotation** (Edge: ink, highlight, text comments, basic form fill, no XFA). [MS Learn](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-pdf) | Sign or fill a form without opening Preview | Only when a PDF is open | Open PDFs in a native `PDFView`; `PDFAnnotation` (macOS 10.4) covers highlight, ink, notes and widgets. Whether WKWebView's built-in PDF viewer allows form filling: **UNVERIFIED** | **nice**. Folds into the roadmap's "Printing and PDF viewing" |
| **Full-page / area capture** (Edge Screenshot `Ctrl+Shift+S`; Opera Snapshot `⇧⌘2` with markup; Vivaldi Capture). [Opera help](https://help.opera.com/en/latest/features/), [MS](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/webcaptureenabled) | Capture a whole long page (macOS `⌘⇧4` can't scroll) | 0 until used | `takeSnapshot(with:)` (10.13) for an area. Full page via `createPDF` (11.0) or tiled snapshots; single-image full-page support: **UNVERIFIED** | **nice** (full page to clipboard/file; skip the markup tools) |
| **Reading list** (Chrome side panel, Vivaldi with read/unread). [Chrome](https://support.google.com/chrome/answer/7343019), [Vivaldi](https://help.vivaldi.com/desktop/tools/reading-list/) | Read later | ~0 | Trivial | **skip**. Today tabs + archive + pinned already cover this; a list would duplicate them |
| Edge Collections (being retired), Opera Pinboards (still beta), Vivaldi Notes | — | — | — | **skip (bloat)**. den already skips notes; Edge itself is retiring Collections ([Windows Central](https://www.windowscentral.com/software-apps/microsoft-edge-is-killing-off-its-collections-feature)) |

## 6. Input and forms (Opera, Chrome, Vivaldi)

| Feature (who) | Friction it removes | Resource cost | Feasibility | Verdict |
|---|---|---|---|---|
| **Easy Files** (Opera). The upload dialog first shows recent downloads, screenshots and the clipboard, with thumbnails; since Opera 118 it appears as a bottom module; can be switched off. [Opera page](https://www.opera.com/features/easy-files), [Opera blog](https://blogs.opera.com/desktop/2020/09/attach-files-with-wild-abandon-presenting-easy-files/), [AskVG](https://www.askvg.com/how-to-enable-or-disable-new-easy-files-ui-in-opera-browser/) | Attach the file you just downloaded or screenshotted without digging through Finder | 0 until an upload is triggered | The host fully owns the file picker: `WKUIDelegate.webView(_:runOpenPanelWith:initiatedByFrame:completionHandler:)` (macOS 10.12). Sources: den downloads (Wave B), screenshot folder, pasteboard. "Browse…" falls back to `NSOpenPanel` | **must**. Pairs with the Downloads work |
| **Address and card autofill** (Chrome, Edge) | Checkout forms | JS injection per page. Must skip checkout pages that use Apple Pay | No public WebKit autofill API. [duckduckgo/duckduckgo-autofill](https://github.com/duckduckgo/duckduckgo-autofill) (Apache-2.0) is a shipping WKWebView reference. A "Me" card via Contacts is possible. `WKContentWorldConfiguration` autofill scripting is macOS 27 ([apple-platform notes](apple-platform.md)) | **nice**. After the password vault; reuse its fill engine |
| **Password Checkup** (Chrome: compromised, reused and weak). [Chrome help](https://support.google.com/chrome/answer/9457609) | Know which saved passwords to change | ~0: an on-demand or weekly check | HIBP k-anonymity range API (`api.pwnedpasswords.com/range/<5 hex>` returned HTTP 200 this session; only a hash prefix leaves the Mac). Reused and weak checks are local | **nice**. Cheap add-on to the A3 vault |
| **Browser-priority shortcuts** (Vivaldi: chosen shortcuts win even when the page binds the same key). [Vivaldi help](https://help.vivaldi.com/desktop/shortcuts/keyboard-shortcuts/) | ⌘K, ⌘T and ⌘L stop being hijacked by web apps (or the reverse) | ~0 | Host key handling runs before `WKWebView` (`performKeyEquivalent`) | **nice**. A flag on the planned shortcut registry |
| **Mouse gestures, rocker gestures, gesture editor** (Vivaldi; ALT+drag for trackpads). [Vivaldi help](https://help.vivaldi.com/desktop/shortcuts/mouse-gestures/) | Back and close-tab without the keyboard | ~0 (an event monitor) | `NSEvent` local monitor on right-drag. Conflicts with the right-click context menu | **nice** (plugin). Trackpad swipes already exist |
| Form history autocomplete (Chrome) | — | Stores every typed field | No public API; would need JS on every page | **skip**. Privacy cost and injection cost |
| Single-key shortcuts (Vivaldi) | — | — | — | **skip**. Conflicts with typing; plugins can add them |

## 7. Media and sidebars (Opera, Vivaldi)

| Feature (who) | Friction it removes | Resource cost | Feasibility | Verdict |
|---|---|---|---|---|
| **Opera video popout vs den's mini player.** Opera: auto popout on tab switch, returns inline when you go back to the tab, play/pause, volume, close, resizable, and a **transparent/opacity mode** for reading behind it; per-workspace auto popout is a forum request. [Opera](https://www.opera.com/features/video-popout), [gHacks](https://www.ghacks.net/2022/01/24/opera-browser-automatic-video-pop-out/) | — | Same as A1 | A1 already covers auto, controls, back-to-tab and resize/snap | **nice** to copy: an opacity/click-through toggle, and popout on **space switch** (not just tab switch) |
| **Web panels** (Vivaldi: sidebar sites, mobile/desktop UA toggle, periodic reload 1–30 min, separate width, per-panel mute, zoom). [Vivaldi help](https://help.vivaldi.com/desktop/panels/web-panels/). **Opera messengers sidebar** (WhatsApp, Messenger, Telegram, Instagram, …) is the same idea | Glance at chat without switching tabs | **High while open**: each panel is a live WebContent process. Background panels must go through the same discard | A `WKWebView` in the sidebar slot with `customUserAgent` (10.11) for mobile layouts | **nice**, already "Later" in FEATURES. Rule: lazy, discardable, **no periodic reload by default**. Edge is retiring its sidebar apps ([Windows Central](https://www.windowscentral.com/software-apps/microsoft-edge-is-removing-its-sidebar-to-cut-clutter-while-leaving-the-ever-controversial-copilot-untouched)), a hint that usage is low |
| **Page actions** (Vivaldi: grayscale, invert, sepia, monospace, transitions off, page minimap, CSS debugger, …; per tab). [Vivaldi help](https://help.vivaldi.com/desktop/tools/page-actions/) | — | Small CSS injections | Trivial CSS user styles | **skip (bloat)**. Boosts (roadmap) cover per-site CSS; at most expose "Grayscale" and "Transitions off" as Boost presets |
| Tab reload every N minutes (Vivaldi) | — | Keeps a tab alive, which defeats discard | — | **skip** |

## 8. Explicitly skipped as bloat

- AI-backed features: Lens, Opera Aria tab commands, Edge Copilot.
- Edge Drop (OneDrive-backed).
- Edge smart copy.
- Vivaldi Mail, Calendar and Feeds.
- Opera "My Flow".
- Opera Lucid mode.
- Brave Playlist.
- Pinboards and Collections.
- Edge "Super Duper Secure Mode" as a separate UI. WebKit's `isLockdownModeEnabled` (macOS 13) exists if a hardened site mode is wanted later.

## Open items to verify with a prototype

- Getting blocked-request counts out of `WKContentRuleList` without private SPI.
- Behavior of `preferredHTTPSNavigationPolicy` when HTTPS fails.
- A public way to attribute memory to a tab.
- Rendering a full-page snapshot as a single image.
- Form filling in WKWebView's built-in PDF viewer.
- Whether shipping the MPL-2.0 Brave list files with den needs anything beyond the license notice.
