# Gaps: small conveniences from Arc, Dia, Zen, Firefox and SigmaOS

Research date: 2026-09-27. This goes deeper than [arc.md](arc.md), [dia.md](dia.md) and [zen.md](zen.md): it looks at **small daily conveniences**, not headline features.

It lists only **real gaps**: things that are not already in [ROADMAP.md](../../ROADMAP.md), [FEATURES.md](../FEATURES.md), the wave-5 plan, or the work in progress. Work in progress means:
- zero-resource tabs, the mini player, tab mute
- the spaces menu, Settings, menus and shortcuts, the find bar, error pages, JS dialogs, theme tokens
- dark mode, the Touch ID vault
- the command bar, WKWebExtension
- downloads, auto tab grouping

Where a planned item is missing an important detail, that detail is listed under [§7 Details for planned items](#7-details-for-planned-items), not as a gap.

## How to read this

- **Resource cost** is qualitative only; no numbers were measured. It uses these levels:
  - **idle-zero**: nothing loads until the user triggers it.
  - **per-use**: costs CPU or memory only while in use.
  - **resident**: something stays loaded or polls.
- **Feasibility** cites Apple or WebKit docs where possible. Many API rows point to the verified table in [apple-platform.md §1.3](apple-platform.md#13-core-browser-apis-all-verified-in-apple-docs).
- **Verdicts:**
  - **must**: removes daily friction at little or no idle cost.
  - **nice**: worth doing as an optional plugin.
  - **skip (bloat)**: not worth it for den.
- **UNVERIFIED** marks anything not confirmed from a primary source.
  - The Arc help center (resources.arc.net) returned HTTP 403 to fetches, so Arc details come from search excerpts of those pages and third-party write-ups.
  - Dia details come from its changelog, read with WebFetch, which paraphrases: quotes are near-verbatim, not exact.

## 1. Summary

**Must**, in priority order:

| # | Gap | From | Why it's a must |
|---|---|---|---|
| 1 | Capture: region, element, visible area, full page → copy or save | Arc, Firefox | Daily need; costs nothing idle; `takeSnapshot` covers most of it |
| 2 | Reader View with Narrate | Firefox | Removes clutter from long pages; runs only on demand |
| 3 | Unload a whole space or profile, by hand and automatically | Zen, Dia, Firefox | den's resource promise, applied at space scale |
| 4 | Per-tab resource view ("what is using memory?") | Arc, Firefox `about:unloads` | Makes den's main promise visible and checkable |
| 5 | Site-controls panel for the blocker: per-site switch, and a reload that asks first if the page has unsaved changes | Firefox, Dia | Without it, a page broken by the blocker is a dead end |
| 6 | IDN display: Unicode hostnames, with homograph protection | Dia | Correctness and anti-phishing |
| 7 | Camera, mic and screen-share indicators on the tab, click to turn off | Arc, Dia | Privacy you can see; the API exists |
| 8 | Power hygiene: den never keeps the Mac awake while idle | Dia | Energy is a bug in den's principles |
| 9 | Reopen a closed window with all its tabs, splits and folders | Dia | Recovers the most painful mistake |
| 10 | Paste and Go / Paste and Search when right-clicking the URL pill or command bar | Dia, Arc (removed) | Saves 2 steps many times a day |

**Nice (optional plugins):**
- on-device page translation
- AirPlay
- PDF annotate and sign
- mute a whole domain
- hover media controls on audio tabs
- "copy link to highlight"
- JSON viewer
- receiving Handoff from iPhone
- just-in-time meeting reminders

**Skip:**
- Firefox View
- containers
- Share Quote cards
- meeting tab groups
- the Tidy Tabs prompt
- SigmaOS "Done" tabs
- Zen Share Spaces
- Arc Instant Links
- Library Media

---

## 2. Arc

Arc sources are the help-center article URLs, reached through search excerpts (HTTP 403 on fetch), plus the release notes:
- https://resources.arc.net/hc/en-us/articles/20498293324823 (2024–2026)
- https://resources.arc.net/hc/en-us/articles/20498377604887-Arc-for-macOS-2023-Release-Notes

**Already planned in den, so not gaps:**
- Cmd-Shift-C clean copy, Markdown copy, Paste URL as New Tab
- the pinned "/" drift reset, the Clear sweep, Boosts
- site search, Developer Mode, the hover pill
- Air Traffic Control, Peek, Little Arc, split view
- the Live Calendar Join button, auto-PiP, the mini player
- haptics, themed toasts, archive search, import

| Gap | Friction removed | Resource cost | WKWebView feasibility | Verdict |
|---|---|---|---|---|
| **Capture** (Cmd-Shift-2: drag a region or click an element, then Save / Copy / Markup). A full-page capture is a separate command. Sources: https://allthings.how/how-to-take-a-screenshot-in-arc-browser/ , https://resources.arc.net/hc/en-us/articles/25481392111895 | No round trip through the macOS screenshot tool, and full-page captures work | idle-zero | `takeSnapshot(with:)` with `WKSnapshotConfiguration.rect` (10.13). Full page: `createPDF` (11.0) or tiled snapshots; setting `rect` to the full content size is **UNVERIFIED**. Element: get the bounding rect via JS, then snapshot that rect ([apple-platform §1.3](apple-platform.md#13-core-browser-apis-all-verified-in-apple-docs)) | **must**: common daily task, zero idle cost |
| **Resource check** ("How to Check if Tabs Are Using Too Many Resources"), plus freezing CPU-heavy background tabs (release notes). Source: https://resources.arc.net/hc/en-us/articles/25627710905751 | Answers "why is my fan on?" without opening Activity Monitor | per-use (sampled only while the view is open) | No public WKWebView API maps a tab to its WebContent process; `_webProcessIdentifier` is private SPI (**UNVERIFIED**). App-wide numbers are possible; per-tab attribution may be approximate | **must**: den's promise needs to be visible, but check feasibility first |
| **Instant Links** (Shift-Enter in Cmd-T opens the top result directly). Source: https://tidbits.com/2024/02/15/arc-gains-instant-links-tab-grouping-and-arc-search-iphone-app/ | Skips the results page | needs a search API or AI | No engine-neutral way to get the "top result" without scraping or an API | **skip (bloat)**: AI or scraping dependency |
| **Share Quote** (select text → a link with a quote image card). Sources: https://allthings.how/how-to-share-quotes-in-arc-browser/ , 2023 release notes | Share an excerpt with context | needs a server | Needs a hosted card | **skip (bloat)**: needs a server. See the text-fragment link under Firefox/den for a local alternative |
| **Library → Media** (captures and images). Source: https://resources.arc.net/hc/en-us/articles/19230634389911 | One place for captures | idle-zero | Easy once Capture exists | **skip**: Finder and Downloads cover it |
| **Tidy Downloads** (AI renames files) | – | model | – | **skip (bloat)**: AI |
| **Sleeping-tab indicator**: none found in Arc (**UNVERIFIED**). Arc does freeze heavy tabs | You can see which tabs are discarded | idle-zero | Pure den UI | → micro-detail (§8) |
| **Notification tint on the sidebar**: no source found (**UNVERIFIED**) | – | – | – | not listed |

---

## 3. Dia

Source for every row: https://www.diabrowser.com/changelog , v0.43.0 (2025-08-21) to v1.50.0 (2026-09-24). Only non-AI items are included.

**Already planned in den:** focus mode (compact mode), Live Calendar hover preview (the `previews` plugin), auto-PiP, custom shortcuts, split view, haptics, sidebar swipe, Markdown copy.

| Gap | Friction removed | Resource cost | WKWebView feasibility | Verdict |
|---|---|---|---|---|
| **Paste and Go / Paste and Search**: right-click the nav bar or command bar; a URL gives Go, text gives Search (v1.20.0) | Skips "open, paste, Enter" | idle-zero | Pure den UI (`NSPasteboard` + URL detection) | **must**: tiny cost, used many times a day |
| **Profile auto-unload**: unused profiles unload to free memory (v0.44.0) | Idle spaces or profiles stop costing memory | saves resources | Discard every web view in the space. Whether a `WKWebsiteDataStore(forIdentifier:)` store releases its network/storage processes once it has no views is **UNVERIFIED**, so measure it | **must** (merged with Zen's "Unload space", §4) |
| **Doesn't stop the Mac from sleeping** (v1.21.0 fix) | The laptop sleeps when you walk away | saves energy | Audit den's own `ProcessInfo.beginActivity` / IOKit assertions. Verify with `pmset -g assertions` while idle, and with a paused video | **must**: energy is tracked like a bug |
| **Reopen a closed window** with all its tabs and groups (File menu, v1.18.1) | Undoes an accidental Cmd-Shift-W | idle-zero (store a window record on close) | Pure den state; restore lazily as discarded tabs | **must** |
| **Custom search engine label**: the command bar shows the real engine name (v1.41.0) | You know where Enter goes | idle-zero | Pure den UI | micro-detail (§8) |
| **IDN / punycode decoded** in the address bar, command bar and hover cards (v1.28.0) | International URLs are readable | idle-zero | Decode RFC 3492 in den's own code. Needs a spoof policy like Chrome's (mixed scripts, confusables → show punycode). Chrome's policy: https://chromium.googlesource.com/chromium/src/+/main/docs/idn.md (fetch returned 503; policy details **UNVERIFIED** here) | **must**: correctness and anti-phishing |
| **Ad-block reload prompt**: asks before reloading a page with unsaved changes (v1.22.0); reloads automatically when the blocker is switched off (v1.15.0) | No lost form input | idle-zero | Content rule lists apply on the next load, so a reload is needed. Detect unsaved changes with a `beforeunload` check through JS (**UNVERIFIED** approach) | **must**, as part of the site-controls panel |
| **Mute a domain**: current and future tabs (v1.48.0) | Silences an autoplaying site for good | idle-zero | Per-tab mute (in progress) + a domain rule | **nice** |
| **Spotify hover mini player**: hover a pinned audio tab for play, pause and skip (v1.20.0) | Control music without switching tabs | per-use | Play/pause via `pauseAllMediaPlayback` / `setAllMediaPlaybackSuspended` (12.0). Skip needs the page's MediaSession handlers, called through injected JS; whether a WKWebView reaches macOS Now Playing on its own is **UNVERIFIED** | **nice**: extends the planned hover card |
| **Cast** to external devices (v1.45.1; which protocol is **UNVERIFIED**) | Send a video to the TV | idle-zero | AirPlay: `allowsAirPlayForMediaPlayback` (10.11). No Chromecast in WebKit (**UNVERIFIED**) | **nice**: AirPlay is a single config flag |
| **Tab Handoff from iPhone** (v1.15.0) | Continue reading on the Mac | idle-zero | `NSUserActivity` `NSUserActivityTypeBrowsingWeb` + `webpageURL` (10.10). Receiving needs den to be the default browser (**UNVERIFIED**, [apple-platform §1.10](apple-platform.md#110-handoff)). ROADMAP lists "Handoff" but not which direction | **nice**: make sure both directions are specified |
| **Just-in-time meeting reminder**: a movable corner card with attendees and Join; shown in PiP (v1.5–1.7) | You don't miss meetings while deep in a tab | resident only while a calendar connection exists | Pure den UI, fed by a calendar connection (planned) | **nice**: after the Calendar connection |
| **Meeting tab groups**: joining creates a group; the title wiggles at 5 and 2 minutes (v1.14/1.17) | – | – | – | **skip (bloat)**: niche |
| **Tidy tabs prompt** for 10+ stale tabs (v1.30.0) | – | – | – | **skip**: auto-archive already does this without asking |
| **Cmd-click opens into a new tab group** (v1.16.0) | – | – | – | **skip**: den has no Chrome-style groups; the Arc model (background Today tab) stays |
| **Copy several tab URLs at once** (v1.18.1) | Share a set of links | idle-zero | Pure den | micro-detail (§8) |
| **New Tab pages clear when you switch apps or lock** (v1.38.0) | No stray blank tabs | idle-zero | Pure den | micro-detail (§8) |

---

## 4. Zen

Sources:
- https://docs.zen-browser.app/user-manual/glance
- https://docs.zen-browser.app/user-manual/compact-mode
- https://docs.zen-browser.app/user-manual/split-view
- https://docs.zen-browser.app/user-manual/workspaces
- https://zen-browser.app/release-notes/

**Already planned in den:** Glance (Peek), compact mode, workspaces, Live Folders, Zen Mods (theme tokens), essentials, a 4-pane split with grid.

| Gap | Friction removed | Resource cost | WKWebView feasibility | Verdict |
|---|---|---|---|---|
| **Unload space**: a context-menu item unloads every tab in a space without closing it (v1.16.4b) | Frees a whole project's memory in one click | saves resources | Discard (already built) applied to each tab in the space. Belongs in the space right-click menu (in progress) | **must** (with Dia's profile auto-unload) |
| **Share Spaces** as a link (v1.21.1b) | – | server | – | **skip**: needs a server (already Skip in FEATURES) |
| **Glance buttons**: Close / Expand / **Split** at top-left, plus an "Open Link in Glance" context item (v1.17.7b) | Promote a preview straight into a split | idle-zero | Pure den UI on the `peek` overlay | micro-detail (§8) |
| **Reset pinned tab, with a modifier to duplicate in the background** (v1.21.2b) | Keep where you drifted to and still reset | idle-zero | Pure den | micro-detail (§8) |
| **Keep compact-mode panels shown** (Alt-Ctrl-S / Alt-Ctrl-W) | Pin the revealed sidebar temporarily | idle-zero | Pure den | micro-detail (§8) |
| **Several media players in the sidebar**, each with controls (v1.21.11b) | Two audio sources, both controllable | per-use | Per-tab media state (12.0) | **nice**: extends the in-progress mini player |

---

## 5. Firefox

| Gap | Friction removed | Resource cost | WKWebView feasibility | Verdict |
|---|---|---|---|---|
| **Reader View + Narrate** (Cmd-Opt-R: font, size, width, theme; read aloud with voice and speed). Sources: https://techdows.com/2016/08/firefox-reader-view-keyboard-shortcut.html , https://www.ghacks.net/2016/03/08/narrate-text-to-speech-firefox/ | Long, cluttered articles become readable, or listenable | idle-zero; per-use while open | No native reader in WKWebView. [Readability.js](https://github.com/mozilla/readability) (Apache-2.0, runs in a plain page) injected on demand into an isolated `WKContentWorld`, rendered in a den-owned view. Narrate with `AVSpeechSynthesizer` | **must** |
| **Screenshots** (Cmd-Shift-S: full page, visible area, region, hover an element; save or copy). Source: https://support.mozilla.org/en-US/kb/take-screenshots-firefox | Same as Arc Capture | idle-zero | See Arc Capture | **must** (merged with Arc Capture) |
| **Tracking Protection shield**: blocked count, per-site on/off at the top, and switching off reloads. Source: https://support.mozilla.org/en-US/kb/enhanced-tracking-protection-firefox-desktop | Fix a broken site in one click | idle-zero | Per-site exception: rebuild the list with `if-domain`/`unless-domain`, or add an `ignore-previous-rules` rule ([content blocker docs](https://developer.apple.com/documentation/safariservices/creating-a-content-blocker)). A **blocked count** has no public callback from `WKContentRuleList` (**UNVERIFIED**), so drop the count | **must** (switch and reload), with the count skipped |
| **Copy clean link / query stripping** (Strict mode list: `mc_eid, oly_anon_id, oly_enc_id, __s, vero_id, _hsenc, mkt_tok, fbclid`). Sources: https://firefox-source-docs.mozilla.org/toolkit/components/antitracking/anti-tracking/query-stripping/index.html , https://bugzilla.mozilla.org/show_bug.cgi?id=1924493 | – | – | Content rule lists **cannot rewrite URLs** (no redirect action). Strip in den's copy code; optionally strip on navigation in `decidePolicyFor` (inference). Safari's Link Tracking Protection is documented for Safari only ([WebKit blog](https://webkit.org/blog/14205/); WKWebView availability **UNVERIFIED**) | Planned (Cmd-Shift-C). See §7 for the list |
| **On-device Translations** (Bergamot, offline, offers itself automatically). Source: https://support.mozilla.org/en-US/kb/website-translation | Read pages in other languages without a cloud service | idle-zero; language models only when used | Apple `TranslationSession` (macOS 15.0; `init(installedSource:target:)` 26.0 lets den create one directly). Text nodes gathered and replaced through injected JS. Page-scale quality and speed are **UNVERIFIED**, so prototype it | **nice**: a plugin, on demand, not "AI everywhere" |
| **PiP details**: space, ←/→ 5 s, Ctrl-←/→ 10%, Home/End, Ctrl-↑/↓ mute, **Shift-Esc closes without pausing**, captions in PiP. Sources: https://support.mozilla.org/en-US/kb/about-picture-picture-firefox , https://allthings.how/how-to-enable-automatic-picture-in-picture-in-firefox/ | – | – | den's own mini player (in progress). WebKit's `allowsPictureInPictureMediaPlayback` is **iOS-only** (Apple docs); the web `requestPictureInPicture()` fallback inside WKWebView on macOS is **UNVERIFIED** | Detail for a planned item, §7 |
| **PDF editing**: add text, highlight, images, reusable signatures. Source: https://support.mozilla.org/en-US/kb/view-pdf-files-firefox-or-choose-another-viewer | Sign a form without Preview | idle-zero | Open PDFs in a PDFKit `PDFView`, which supports annotations, instead of WebKit's inline viewer. How WKWebView shows PDFs on macOS is **UNVERIFIED** | **nice**: Preview.app is one click away |
| **Unload Tab** in the tab context menu, plus multi-select "Unload n Tabs" (Firefox 140), and `about:unloads` (memory and last access per tab). Sources: https://support.mozilla.org/en-US/kb/unload-tabs-reduce-memory-usage-firefox , https://firefox-source-docs.mozilla.org/browser/tabunloader/ | Free memory on purpose, now | saves resources | Discard exists; this is a menu item plus the resource view (Arc row) | **must** (the menu item); the view is gap #4 |
| **Total Cookie Protection** (a cookie jar per site). Source: https://support.mozilla.org/en-US/kb/introducing-total-cookie-protection-standard-mode | – | – | WebKit has its own third-party cookie policy (ITP). Whether a WKWebView app gets Safari's defaults is **UNVERIFIED**; check it rather than build it | **skip** (engine-level), after verifying |
| **Firefox View** (open, closed and synced tabs, history) | – | – | – | **skip**: the command bar and Archive cover it |
| **Multi-Account Containers** | – | – | – | **skip**: profile per space (already decided) |
| **JSON viewer** (Firefox's built-in; Arc's is **UNVERIFIED**) | Read API responses | idle-zero | Detect `application/json` in `decidePolicyFor navigationResponse`, render in a den page | **nice**: part of Developer Mode (Later) |
| **Copy link to highlight** (text fragments `#:~:text=`). A local alternative to Arc's Share Quote; den idea, not in Firefox as a menu item (**UNVERIFIED**) | Share an exact passage | idle-zero | WebKit supports text fragments (Safari version **UNVERIFIED**); build the fragment from the selection with JS | **nice** |

---

## 6. SigmaOS

Sources: https://sigmaos.com/ , https://toolradar.com/tools/sigmaos

| Gap | Verdict |
|---|---|
| Tabs as a to-do list: **Done** (D) and **lock** | **skip**: auto-archive + pinning cover it |
| **Lazy search**: Space searches tabs, web, commands and bookmarks | **skip**: this is the command bar |
| Single-key shortcuts (W, D, F) when no field has focus | **skip**: clashes with page shortcuts and typing |
| Command-hover link preview | **skip**: Peek covers it |
| Magic Rename, Magic Theme, Airis | **skip (bloat)**: AI |

---

## 7. Details for planned items

These are not gaps, but the planned version should include them.

- **Mini player** (in progress):
  - Firefox key map (above), and Shift-Esc closes without pausing.
  - Captions shown in the player.
  - A "Keep on Top" toggle in its context menu (Dia v1.46.0).
  - **Stash**: drag it past the screen edge to tuck it away; one click brings it back (Dia v1.36.0).
  - A hostname chip that returns to the tab (Dia v1.20/v1.46).
  - Hidden when the tab is muted (Arc).
  - Turn off per site (Arc).
- **Copy clean link** (Cmd-Shift-C): the toast names what happened ("Copied clean link" or "Copied as Markdown").
  - Start from Firefox's strip list and let users add to it.
  - Some marketers dislike stripped UTMs (per [arc.md §13](arc.md#13-link-routing-sharing-and-copying)), so offer Copy Original in the pill menu.
- **Downloads** (next):
  - Progress, size, time left and cancel at the bottom of the sidebar (Arc 2023).
  - Paused downloads can be cancelled (Dia v1.8.0).
  - Never open a file by accident from Recent Downloads (Dia v1.19.0 fix).
  - Hovering the Library icon shows recent files you can drag out (Arc).
- **Handoff:** specify both sending and receiving (Dia v1.15.0).
- **Blocker:** a per-site switch that reloads, asking first if there are unsaved changes.
- **Pinned reset:** Zen's modifier-reset duplicates the tab in the background.
- **Space context menu** (in progress): add **Unload Space**.
- **Tab context menu:** add **Unload Tab**, and "Unload n Tabs" for a multi-selection.
- **Import** (planned):
  - Arc import keeps custom tab names (Dia v1.28.0).
  - Chrome pinned tabs (Dia v1.8.0).
  - Suggest Favorites and pinned tabs from imported history (Arc onboarding, [arc.md §18](arc.md#18-ux-details-that-make-arc-feel-great-observable)).
- **Find bar** (in progress): a clear "no matches" state (Arc 2024–2026 notes), without Arc's AI fallback.
- **Split view:** Option-click and Shift-Option-click to open a split to the right (Dia v0.44.0); Option + New Tab opens a split (Dia v0.47.0).

## 8. Micro-details

Tiny polish items. Each one costs nothing while idle.

**Toasts and feedback**
- The copy toast says exactly what was copied (clean, Markdown, several URLs), tinted to the theme (Arc Jan 2024).
- Site-search suggestion toast: when you search a site through the engine, den offers "Press Tab to search example.com next time" (Arc, via [help article](https://resources.arc.net/hc/en-us/articles/20855018192791-Site-Search-Directly-Search-any-Website)).
- Haptic tick on reorder, and in the theme picker (planned); add rubber-band resistance at the sidebar's ends while dragging (Dia v1.29.0).

**Indicators**
- A dimmed favicon or small moon on **discarded** tabs, so you know the first click reloads. This is den's own idea; Arc's equivalent is **UNVERIFIED**.
- Camera, mic and **presenting** badges on the favicon and in the Ctrl-Tab switcher (Arc Ctrl-Tab, Dia v1.7.0). `cameraCaptureState` / `microphoneCaptureState` can be read and set (12.0), so clicking the badge turns the device off.
- The command bar shows the real search engine name (Dia v1.41.0).
- Unicode hostnames everywhere a URL appears, falling back to punycode on spoof risk (Dia v1.28.0).
- Document PiP windows show the opener's hostname (Dia v1.20.0).

**Hover states and click targets**
- Peek/Glance header buttons: Close / Expand / **Split**, plus an "Open Link in Peek" context item (Zen v1.17.7b).
- A modifier on the pinned-tab reset duplicates the tab in the background (Zen v1.21.2b).
- In compact mode, a shortcut keeps the revealed sidebar shown (Zen Alt-Ctrl-S).
- Right-clicking a folder offers "Paste URL here" (Arc).
- Right-clicking the URL pill offers Paste and Go or Paste and Search, depending on the clipboard (Dia v1.20.0).

**Empty and cleanup states**
- An unused blank New Tab closes itself when you switch apps or lock the screen (Dia v1.38.0).
- Library, Archive and Downloads each get a one-line empty state that says what will appear there. den's own idea, as part of the wave-B detail audit.

**Onboarding and banners**
- A one-time banner explains auto-archive (Arc; planned).
- Update and What's New banners start collapsed and expand on hover (Arc V1.42).
- Clicking the version number copies it (Arc on Windows) for bug reports.

**Multi-select**
- Copy the URLs of several selected tabs at once (Dia v1.18.1).
- A new folder asks for its name right away (Dia v1.1.0).

**Privacy windows**
- Incognito windows use a dark appearance, so they can't be mistaken for normal ones (Dia v1.18.1).

## 9. Open items to verify with a prototype

- Whether a tab can be mapped to its WebContent process without private SPI (needed for gap #4).
- Whether web `requestPictureInPicture()` works in a macOS WKWebView (the native mini player is the primary path anyway).
- Whether a WKWebView reaches macOS Now Playing / MediaSession on its own.
- Full-page `takeSnapshot` with `rect` set to the full content height, compared with `createPDF` → image.
- Whether an idle `WKWebsiteDataStore(forIdentifier:)` frees its processes once all its views are gone (unloading a profile).
- Third-party cookie defaults (ITP) in a WKWebView app.
- Whether Safari's Link Tracking Protection applies outside Safari.
- Translation framework quality and latency on a real page.
