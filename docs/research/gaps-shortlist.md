# Gap shortlist

> Research snapshot, 2026-09-27. Decisions made later are in [ROADMAP.md](../../ROADMAP.md) / [FEATURES.md](../FEATURES.md).

This merges three reports into one shortlist of frictionless features from other browsers that den doesn't have yet:
- [WebKit browsers](gaps-webkit-browsers.md): Safari, Orion, DuckDuckGo
- [Chromium browsers](gaps-chromium-browsers.md): Chrome, Edge, Brave, Vivaldi, Opera
- [Arc, Dia, Zen, Firefox, SigmaOS](gaps-arc-dia-zen-firefox.md)

Each group is one lazy plugin: it costs nothing until used. Items rated "skip (bloat)" in the reports are left out here.

## A. Shields: clean, private browsing
One per-site panel from the URL pill.

| Feature | From | Notes |
|---|---|---|
| Per-site panel: blocker on/off, permissions, zoom, autoplay, pop-ups, "forget this site" | Brave, Safari, Firefox | Asks before reloading a page with unsaved input |
| Strip tracking parameters on every navigation, not only on copy | Brave, DDG, Arc | den needs its own list. DDG's list is non-commercial; Brave's `query-filter.json` is MPL-2.0 and needs a legal read |
| Skip bounce-tracking redirects | Brave | Brave's `debounce.json` (same legal read) |
| Auto-handle cookie banners | DDG, Brave | DDG `autoconsent` (MPL-2.0) or the EasyList Cookie list compiled to content rules |
| HTTPS-first | Chrome, Safari | `preferredHTTPSNavigationPolicy` |
| Readable international domain names, with lookalike-domain warnings | Dia, Chrome | |

## B. Energy: resources and battery

| Feature | From | Notes |
|---|---|---|
| Battery saver: sooner discards, pause background media and autoplay when unplugged or in Low Power Mode | Edge, Opera, Orion | |
| Never discard tabs with unsaved input, camera/mic in use, or on an "always keep active" list | Edge, Chrome, Safari | |
| Dimmed icon on discarded tabs | Chrome, Zen | |
| Unload a whole space or profile, by hand or automatically | Zen, Dia | |
| Per-tab memory view | Chrome, Edge | Mapping a tab to its WebKit process may need a private API (UNVERIFIED) |
| Never keep the Mac awake while idle | Dia | |
| Blank new tabs close when you switch apps | Arc | |

## C. Page tools: reading and capture
Built: the `pagetools` plugin ([plugin-services.md](../plugin-services.md#pagetools-plugin-pagetools)); zoom per site is the host's page actions (`webviews.zoom`).

| Feature | From | Notes |
|---|---|---|
| Reader mode, remembered per site, with read-aloud | Safari, Firefox, Edge | Readability.js (Apache-2.0), loaded only when used, plus macOS speech |
| On-device page translation | Safari, Firefox | Apple's Translation framework |
| Capture: region, element, visible or full page, then copy or save | Arc, Firefox, Vivaldi | |
| Zap an element or remove sticky headers, remembered per site | Arc Boosts, Orion | |
| Copy link to highlight (text fragments) | Chrome | WebKit already opens these links |
| Remember zoom per site | Chrome, Safari | Uses `pageZoom` |

## D. Share and clipboard

| Feature | From |
|---|---|
| Native share menu (AirDrop, Messages) and a QR code for the page | Safari, Chrome |
| Paste and Go / Paste and Search | Dia, Chrome |
| Copy toast says exactly what was copied | Arc |
| Clear a copied password from the clipboard after a short time | DDG |
| Upload picker shows recent downloads, screenshots and the clipboard first | Opera |

## E. Media and meetings

| Feature | From |
|---|---|
| Camera, mic and screen-share badges on tabs, click to turn off | Arc, Dia, Safari |
| Mini player: "Keep on top" toggle, tuck it off the screen edge, hostname chip back to the tab, Firefox's PiP keys, subtitles | Dia, Firefox |

## F. Sessions and navigation

| Feature | From |
|---|---|
| Reopen a closed window with all its tabs | Dia, Chrome |
| Error pages link to the Web Archive copy | Safari/DDG |
| Web apps in the Dock (a small generated app, Orion-style) | Orion (nice-to-have) |
| Command bar names the real search engine, and suggests site-search keywords with a toast | Dia |
| Peek gets a Split button and an "Open Link in Peek" menu item | Arc, Zen |

## Not possible for den
Safari-only, with no API for third-party browsers:
- iCloud Tabs
- Private Relay
- Shared with You
- Web Push in `WKWebView`
- Safari's own "Add to Dock"

## Licence watch
DDG's tracker, parameter and HTTPS lists are CC BY-NC-SA, so they can't ship in an MIT app. DDG's code, `autoconsent` (MPL-2.0) and its privacy reference tests (Apache-2.0) are usable.
