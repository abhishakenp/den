# Dia shortlist: connections and quality-of-life gaps for den

> Research snapshot, 2026-09-28. Decisions made later are in [ROADMAP.md](../../ROADMAP.md) / [FEATURES.md](../FEATURES.md).

- **Date:** 2026-09-28
- **Input:** [dia-changelog-inventory.md](dia-changelog-inventory.md), covering 56 changelog versions (v0.43.0 → v1.50.0) and 43 release-note pages. `/release-notes/latest` was re-fetched today and is still Issue 043 / v1.50.0 ("Crafted with care…"), so nothing is newer than the inventory.
- **Filtered against:** [ROADMAP.md](../../ROADMAP.md), [FEATURES.md](../FEATURES.md), [gaps-shortlist.md](gaps-shortlist.md) (approved), [plugin-services.md](../plugin-services.md), the wave-5 plan (`~/.plans/2026-09-27_20-25-den-wave-5.md`), and [dia-ui-spec.md](../reference/dia-ui-spec.md). An item that already appears in any of these is listed here only if Dia adds a detail den's plan lacks. When that happens, the row says so.
- **Rules:** den reuses the user's web session, with no OAuth apps, no den servers and no den login. Apple's on-device model is used only for the briefing and feed, and there is no chat. Every feature is a lazy plugin.
- **Method and limits:** the feasibility research was done on 2026-09-28 by reading docs and open-source client code with WebFetch. **No endpoint below was called against a live signed-in account.** Every "feasible" rating means "a documented or open-source precedent exists", not "den verified it". Web search quota ran out during the research, so some claims could not be cross-checked; those are marked UNVERIFIED.
- **Standing caveat:** [integrations-auth.md §9](integrations-auth.md) warns that session reuse against internal web APIs is unsupported and arguably breaches some providers' API terms. That warning applies to every row here. The providers whose terms explicitly bar non-public APIs or reverse engineering are Atlassian, Linear, Figma and LinkedIn (sources in §1).

Verdicts: **must** / **nice** / **skip**.

---

## 1. Connections

What den already has: Slack and GitHub connections; hover cards for GitHub PRs and issues, Google Calendar (read from a loaded tab's DOM), Gmail (Atom feed) and Slack; and a briefing and feed built from Slack and GitHub ([plugin-services.md](../plugin-services.md)). The wave-5 plan covers auto-connect through a `WKHTTPCookieStore` observer.

### 1.1 What Dia does with each service

| Service | What Dia does (version) |
|---|---|
| Slack | Morning Brief source; live folder with activity; mentions and unreads; per-tool workspace picker (1.38); file attachments and voice-note transcripts read in chat (1.30, 1.48, 1.49) [AI] |
| GitHub | **Live Group** of your PRs and review requests, created on first PR open and pinned (1.17); real-time updates on merge, review and close (1.22); completion animation plus a "2 ✓" Recently Closed popover (1.23); **PR hover** with CI bar, failures and conflicts (1.31); stack positions (1.46); collapsible stacks with persisted state (1.50); unread pip on a collapsed group (1.29); reauth cue and a configure-repos menu (1.17) |
| Gmail | Live folder; "which emails need a reply" in the brief; @Gmail in chat (1.1) [AI]; account switching (1.37) |
| Google Calendar | Pinned tile with day number and "in 4m" countdown (1.17, 1.25); hover preview with Join and New Event (1.5); just-in-time reminder card, later moved into a PiP window (1.5–1.7); Meeting Tab Groups on join (1.9, 1.14, 1.17); choose which calendars show (1.46) |
| Google Drive / Docs | **Live Docs group**: rows appear when there are comments, suggestions, mentions or shares, open scrolled to the change, and fade out once handled (1.27); Drive notifications in the brief (1.30) |
| Google Sheets | Full sheet reading in chat (1.10) [AI] |
| Google Meet | PiP when you leave the Meet tab (1.3); meeting groups; reminder "Join Meet" |
| Notion | Live Docs group (mentions, comments, invites); workspace picker (1.38); write-ups compiled from Slack, email and Docs (1.47) [AI] |
| Linear | AI project-status table (1.46) [AI] |
| Jira / Confluence | Confluence in the Docs live group (1.31); "new jira" creation shortcut (1.9) |
| Zoom | Search meetings, recordings and transcripts in chat (1.45) [AI] |
| Figma | Figma tools in chat, such as identifying frames (1.50) [AI]; "new figma" shortcut (1.9) |
| Outlook / Teams / SharePoint | Pinned Outlook/Teams URLs feed the Live Calendar (1.47); brief sources and Q&A (1.48, 1.49) [AI] |
| Spotify | Hover mini player on a pinned Spotify tile: art, previous/pause/next, progress; the tile turns green with animated notes (1.20) |
| Salesforce, Canva, LinkedIn, Granola, Amplitude | Chat tools only (1.40–1.49) [AI] |

### 1.2 Verdicts

**Session feasibility** says which data a signed-in web session exposes and how. **Detect** names the marker for auto-connect.

| Service | Daily-life value | Session feasibility | Detect | Verdict |
|---|---|---|---|---|
| **Slack** | Unread DMs and threads awaiting you, without opening Slack | Already built (`xoxc` token plus `d` cookie; `client.counts`, `search.messages`). The gap is a **Slack live folder** in the sidebar, fed by the existing feed items | `d` cookie plus `localConfig_v2` (built) | **must** (done). The live folder is part of the Live Folder item in §3 |
| **GitHub** | See PRs to review and CI failures at a glance | Already built (github.com search JSON with the session; api.github.com for public PRs). Missing: the **Live Folder mechanics** (§2.1), plus stack data. Dia itself reads GitHub by parsing HTML with the web session, per its error strings ([dia-ui-spec §3.4](../reference/dia-ui-spec.md)) | `logged_in=yes`, `dotcom_user` (built) | **must** (done). The Live Folder details are a Top 15 item |
| **Gmail** | "Emails awaiting a reply" in the briefing; unread count in the hover card | **High** for unread threads: the Atom feed `/mail/u/<n>/feed/atom` is already used by `previews`. "Needs a reply" cannot be read from Atom, so it would need an internal endpoint (UNVERIFIED) or a heuristic on unread threads | `SID`/`HSID` are documented sign-in cookies ([Google cookie policy](https://policies.google.com/technologies/cookies?hl=en-US)). `SAPISID`/`__Secure-3PAPISID` are what yt-dlp treats as auth ([_base.py](https://raw.githubusercontent.com/yt-dlp/yt-dlp/master/yt_dlp/extractor/youtube/_base.py)). Multiple accounts: `accounts.google.com/ListAccounts?json=standard` ([Chromium gaia_urls.cc](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/google_apis/gaia/gaia_urls.cc)); response shape UNVERIFIED | **must**. Already on the ROADMAP ("Briefing sources beyond Slack and GitHub"). What Dia adds: **per-account switching** (1.37) via `ListAccounts` and `/u/<n>` |
| **Google Calendar** | Never miss a meeting: countdown, Join, just-in-time reminder | **Medium.** The current hover reads event chips from a *loaded* tab; a reminder needs data when no Calendar tab is open. Options: (a) the "Secret address in iCal format" ([support 37648](https://support.google.com/calendar/answer/37648?hl=en); admins can disable it for work accounts), which is the most stable, but reading it from the settings page DOM automatically is UNVERIFIED, and a pasted URL breaks "no setup"; (b) keep one Calendar web view discarded and wake it on a schedule to read the DOM, at a resource cost; (c) internal JSON, UNVERIFIED with no source found. The public Calendar API needs OAuth ([overview](https://developers.google.com/workspace/calendar/api/guides/overview)) | Google cookies as above | **must**. The pinned countdown is in FEATURES ("Later"); the **reminder card is a gap** (Top 15). Include Dia's **choose which calendars** (1.46) |
| **Google Drive / Docs** | Know when someone comments on, mentions you in, or shares a doc | **Low** directly: no cookie-usable feed found; the Drive Activity API is OAuth-only; `WIZ_global_data` scraping is UNVERIFIED. **Medium** through Gmail, since shares, comments and mentions arrive as notification emails in the Atom feed. Sender reliability is UNVERIFIED | Google cookies | **nice**, built as a Gmail-derived "Docs activity" feed kind, not as its own connection |
| **Google Sheets** | – (Dia's use is AI reading) | `gviz/tq` ([docs](https://developers.google.com/chart/interactive/docs/spreadsheets)); whether session cookies unlock private sheets is UNVERIFIED | – | **skip** (AI-only use) |
| **Google Meet** | Join from the reminder; PiP when leaving the call | No feed of its own. Links come from Calendar events. PiP is covered by the planned AutoPiP | – | Folded into Calendar. **skip** as a connection |
| **Notion** | Mentions and comments on your pages, in the feed and a live folder | **High (data), medium (stability).** `POST notion.so/api/v3/getNotificationLogV2 {spaceId, size, type:"unread_and_read"}` ([notification-aggregator](https://github.com/CorgiMan/notification-aggregator/blob/main/integrations/notion.js)); `getSpaces`, `search` ([notion-py](https://github.com/jamalex/notion-py/blob/master/notion/client.py)); header `x-notion-active-user-header` ([opentabs](https://github.com/opentabs-dev/opentabs/tree/main/plugins/notion/src)). Risk: `www.notion.so/terms` redirected to `app.notion.com` during research, so the API host may move (UNVERIFIED). ToS text did not render (UNVERIFIED) | `token_v2` cookie (auth) and `notion_user_id` cookie; space from localStorage `LRU:KeyValueStore2:lastVisitedRouteSpaceId` (opentabs) | **nice**. The first connection to add after Gmail and Calendar (Top 15) |
| **Linear** | Assigned issues and notifications in the feed | **High.** The web app calls `client-api.linear.app/graphql` with credentials from the linear.app origin, using headers read from localStorage `ApplicationStore` ([opentabs](https://github.com/opentabs-dev/opentabs/tree/main/plugins/linear/src)). The schema has `notifications`, `notificationsUnreadCount` and `issueSearch` ([schema](https://github.com/linear/linear/blob/master/packages/sdk/src/schema.graphql)). ToS §2.2 bans discovering non-public APIs ([terms](https://linear.app/terms)) | `loggedIn=1` cookie; org from `ApplicationStore` | **nice** (Top 15, grouped with Atlassian) |
| **Jira / Confluence** | Assigned issues, @-mentions and page comments | **High in a same-origin page.** `/rest/api/3/search/jql` and `/wiki/rest/api/search` with `credentials:'include'` ([opentabs jira](https://github.com/opentabs-dev/opentabs/tree/main/plugins/jira/src)). The notification bell `GET /gateway/api/notification-log/api/2/notifications` **only works with a browser session**, not an API token ([reporto notes](https://github.com/Catofwanders/reporto), [jira-plugin](https://github.com/gioboa/jira-plugin)). Cookie auth for REST clients is deprecated ([Atlassian](https://developer.atlassian.com/cloud/jira/platform/jira-rest-api-cookie-based-authentication/)). Customer Agreement §2.2 bans non-public APIs ([terms](https://www.atlassian.com/legal/cloud-terms-of-service)) | `cloud.session.token` / `tenant.session.token` ([AtlasReaper](https://github.com/werdhaihai/AtlasReaper)); sites via `/gateway/api/available-sites` (serving host UNVERIFIED) | **nice** (Top 15, grouped with Linear) |
| **Outlook (mail and calendar)** | Same as Gmail and Calendar, for Microsoft 365 users | **Medium–high.** The calendar hover can read a loaded Outlook tab's DOM, as with Google (not built). Data without a tab: a published ICS link ([Microsoft support](https://support.microsoft.com/en-us/office/share-your-calendar-in-outlook-on-the-web-7ecef8ae-139c-40d9-bae2-a23977ee58d5)), a manual step; or reuse the MSAL token that OWA keeps in same-origin storage ([MSAL caching](https://learn.microsoft.com/en-us/entra/msal/javascript/browser/caching)). Microsoft notes that script with storage access can request tokens, but lifting a page's bearer token is exactly what tenant Conditional Access may block or flag (UNVERIFIED per tenant) | MSAL entries in `outlook.office.com` storage; `ESTSAUTH*` at login.microsoftonline.com (name UNVERIFIED) | **nice**: calendar hover plus reminder from a loaded tab first; token reuse only after a security review |
| **Teams** | Unread chats in the feed | **Medium.** The internal `authz` endpoint mints a skypetoken, then `/v1/users/ME/conversations` ([purple-teams](https://raw.githubusercontent.com/EionRobb/purple-teams/master/teams_login.c)). Fragile, and subject to Conditional Access | MSAL cache on teams.microsoft.com; skypetoken in storage | **skip** for now (fragile; revisit if users ask) |
| **SharePoint** | Document-update heads-ups | **High mechanically**: same-origin `_api/` with cookies plus `#__REQUESTDIGEST` ([SharePoint REST](https://learn.microsoft.com/en-us/sharepoint/dev/sp-add-ins/complete-basic-operations-using-sharepoint-rest-endpoints)). But the site is per tenant with no global feed, so value per unit of effort is low | `FedAuth`/`rtFa` (UNVERIFIED) | **skip** |
| **Zoom** | Join links (already in calendar events) | **Low–medium.** The REST API needs OAuth ([Zoom API](https://developers.zoom.us/docs/api/)); internal web endpoints are UNVERIFIED. Dia's use is AI search of recordings | `_zm_*` cookies (UNVERIFIED) | **skip** |
| **Figma** | Comments on files | **Medium.** `figma.com/api/*` with `__Host-figma.authn` and `fuid` ([opentabs](https://github.com/opentabs-dev/opentabs/tree/main/plugins/figma/src)); no mentions feed found (UNVERIFIED); ToS §2.2 bans reverse engineering ([tos](https://www.figma.com/legal/tos/)). Dia's use is AI | `__Host-figma.authn-state=1` | **skip** (keep only the static "new figma" shortcut, §2.5) |
| **Spotify / any audio tab** | Play, pause and skip music without switching tabs | Not a connection: it's media control of a tab. Public: `requestMediaPlaybackState` (macOS 12+), `pauseAllMediaPlayback` ([Apple](https://developer.apple.com/tutorials/data/documentation/webkit/wkwebview/requestmediaplaybackstate(completionhandler:).json)). Title and artist: injected JS reading `navigator.mediaSession.metadata` (UNVERIFIED) or the private `_nowPlayingMediaTitleAndArtist:` ([WKWebViewPrivate.h](https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKWebViewPrivate.h)). Next/previous: page DOM buttons (fragile). Whether Spotify's DRM plays in a WKWebView is UNVERIFIED; Safari is supported ([Spotify help](https://support.spotify.com/us/article/web-player-help/)). Its token endpoint broke in 2025 ([librespot #1475](https://github.com/librespot-org/librespot/issues/1475)), so don't use it | – | **nice**, generic for any mediaSession tab (§2.3, Top 15) |
| YouTube | – (Dia: AI summaries) | Channel Atom feed and Innertube exist (yt-dlp) | `LOGIN_INFO` plus SAPISID | **skip** |
| LinkedIn | – | User Agreement §8.2 bans scripts and add-ons that scrape ([LinkedIn](https://www.linkedin.com/legal/user-agreement)) | – | **skip** (ToS) |
| Salesforce, Canva, Granola, Amplitude | – (AI tools only) | UNVERIFIED | – | **skip** |

**Connection order:** Gmail and Calendar (with the reminder), then Notion, then Linear and Atlassian as one "work tracker" pass, then Outlook's calendar from a loaded tab. Each is its own lazy plugin that answers `connections.probe` and `feed.refresh`, as `slack` and `github` do.

---

## 2. Quality-of-life gaps (non-AI)

Each row is either missing from every den plan, or is a Dia detail that a planned item lacks (marked *detail*). Resource cost is qualitative:
- **idle-zero:** costs nothing until used
- **per-use:** costs only while in use
- **resident:** costs something continuously
- **saves:** reduces den's resource use

### 2.1 Tabs, windows and live folders

| Item | Dia version (date) | Friction removed | Cost | WKWebView feasibility | Verdict |
|---|---|---|---|---|---|
| **Live Folder mechanics** (*detail* of ROADMAP "live folders"): unread pip on a collapsed folder (1.29); finished items get a check, animate out and count into a header "N ✓" badge whose hover shows a Recently Closed popover to restore them (1.23); two-line rows with "author • state" (1.17); PR stacks grouped, with collapse state persisted (1.46, 1.50); reauth cue and a configure menu (1.17) | 1.17 (2026-02-05) → 1.50 (2026-09-24) | You see what's new without expanding, and done items clear themselves without being lost | idle-zero beyond the existing 15-min feed refresh | Pure den UI on feed items. Stack data: GitHub's PR page (Dia parses HTML); a source den can use is UNVERIFIED | **must** |
| **Protect recently used tabs from discard**: the last N used tabs are kept, and idle time counts only while den is the active app (1.5, 1.8) | 1.5.0 (2025-11-13), 1.8.0 (2025-12-04) | Tabs you just used don't reload after lunch or after a long session in another app | saves (fewer reload spikes) | Pure den logic in the `tabs` suspension timer; `NSApplication` active/inactive notifications. The best N needs measuring | **must** (*detail* of wave-5 A1 discard) |
| **Faster close**: show the next tab first, then tear down (1.48) | 1.48.0 (2026-09-10) | Cmd-W feels instant | idle-zero | Select the neighbour, then release the `WKWebView` on the next run-loop turn | **must** |
| **Tab menu shows shortcuts**, including remapped ones (1.21), plus ⌥ alternates **Copy Link as Markdown** and **Close Tabs Above**, and **Close Other Tabs / Close Tabs Below** ([dia-ui-spec §4](../reference/dia-ui-spec.md)) | 1.21.0 (2026-03-05) | You learn shortcuts where you act; bulk close in one step | idle-zero | `NSMenuItem.keyEquivalent` read from the `keys` registry; `isAlternate` for ⌥ items | **must** |
| **⌘/middle-click a back/forward history entry** opens it in a background tab, Shift for foreground (1.10.1) | 1.10.1 (2025-12-18) | Branch from history without losing your place | idle-zero | `backForwardList` item → `tabs.open` | **nice** |
| Sidebar auto-scrolls to reveal a ⌘-clicked background tab (1.18.1) | 1.18.1 (2026-02-12) | You can see where the tab went | idle-zero | `NSScrollView` scroll-to-row, animated | **nice** |
| Duplicating a pinned tab makes a normal tab (1.14) | 1.14.0 (2026-01-15) | No accidental second pinned copy | idle-zero | `tabs.duplicate` kind rule | **nice** |
| Ctrl-Tab switcher as a **thumbnail grid** that hides stale tabs (1.28) | 1.28.0 (2026-04-23) | Recognise tabs by sight | per-use (reads the on-disk snapshots den already keeps) | den already stores discard snapshots | **nice** (*detail* of FEATURES Ctrl-Tab) |
| Dock right-click menu: New Window per space or profile (1.20) | 1.20.0 (2026-02-26) | Open straight into Work or Personal | idle-zero | `applicationDockMenu(_:)` | **nice** |
| Popups and Little Arc windows support Find, Print and Copy URL (1.14) | 1.14.0 | Popups aren't dead ends | idle-zero | `WKWebView` `find` / `printOperation` in the mini window | **nice** |
| Chrome-style tab groups as a separate concept, bookmarks-bar chips for closed groups, tidy-tabs prompt, meeting tab groups | 1.9–1.30 | – | – | den follows Arc's model (folders, Today, auto-archive), and FEATURES skips bookmarks and the horizontal strip. **Dia's group *behaviours* (⌘-click grouping, group from selection, and so on) are kept and mapped onto den folders in §3** | **skip** the concept (the tidy prompt and meeting groups were also skipped in [gaps-arc-dia-zen-firefox §3](gaps-arc-dia-zen-firefox.md)) |
| Site-coloured top band / toolbar tint (1.25, 1.28) | 1.25.0 | – | – | den's chrome lives in the sidebar, and the page is an inset card | **skip** |
| Overflow menu with synced devices, NTP query restore, Release-notes postcard NTP | 1.28–1.46 | – | – | Covered by the command bar and archive; no NTP | **skip** |

### 2.2 Meetings

| Item | Dia version (date) | Friction removed | Cost | WKWebView feasibility | Verdict |
|---|---|---|---|---|---|
| **Just-in-time meeting reminder**: a corner card with title, attendees, "Join" and "View Event"; movable, snaps to corners, can be dismissed (1.5–1.7) | 1.5.0 (2025-11-13), 1.7.0 (2025-12-01) | You don't miss calls while deep in a page | resident: one timer to the next event, only while a calendar connection exists | Non-activating `NSPanel` (the same engine as the hover card); data from the Calendar connection (§1.2) | **must** |
| Countdown on the pinned Calendar tile, with smooth "in 8m → 7m" transitions (1.17, 1.25) | 1.17.0 | Glanceable time to the next meeting | resident: a minute timer while connected | Pure den UI | Already in FEATURES ("Later"). Include the smooth transition detail |
| Suppress update prompts during calls or screen recording (1.19) | 1.19.0 (2026-02-19) | No dialog pops up mid-presentation | idle-zero | Check `cameraCaptureState` / `microphoneCaptureState` (public, macOS 12+) before showing | **must** once auto-update exists (ROADMAP) |
| "Share this tab instead" during screen share (1.24) | 1.24.0 | – | – | Chromium tab capture; WebKit's `getDisplayMedia` has no tab surface, and the display-capture state is private SPI (`_displayCaptureState`, [WKWebViewPrivate.h](https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKWebViewPrivate.h)) | **skip** |

### 2.3 Media

| Item | Dia version (date) | Friction removed | Cost | WKWebView feasibility | Verdict |
|---|---|---|---|---|---|
| **Hover media controls** on any tab playing audio (Spotify, YouTube Music…): art, title, play/pause, previous/next, progress (1.20) | 1.20.0 (2026-02-26) | Control music without switching tabs | per-use (only on hover of a playing tab) | See the Spotify row in §1.2. Play/pause is public; metadata and skip go through injected JS (UNVERIFIED) or private SPI | **nice** (extends the `previews` card; rated nice before, not in the approved shortlist) |
| **Mute a site**: current and future tabs from a domain (1.48) | 1.48.0 (2026-09-10) | An autoplaying site stays quiet for good | idle-zero | Per-tab mute (wave-5 A1) plus a domain rule applied on `tabs.opened` | **nice** |
| **AirPlay** a video (Dia: Cast, 1.45) | 1.45.1 (2026-08-20) | Send a video to the TV | idle-zero | `WKWebViewConfiguration.allowsAirPlayForMediaPlayback` ([Apple](https://developer.apple.com/tutorials/data/documentation/webkit/wkwebviewconfiguration.json)). Whether the picker appears in a macOS WKWebView is UNVERIFIED. No Chromecast route (the [Cast Web Sender](https://developers.google.com/cast/docs/web_sender) is Chrome-centric) | **nice** (AirPlay only) |

### 2.4 Keyboard and input

| Item | Dia version (date) | Friction removed | Cost | WKWebView feasibility | Verdict |
|---|---|---|---|---|---|
| **Shortcuts on non-US layouts** (AZERTY, Dvorak) match by character, not key code (1.10.1) | 1.10.1 (2025-12-18) | Shortcuts work for every user | idle-zero | `keys` registry matches on `charactersIgnoringModifiers`, with key-code fallback for symbols | **must** (correctness) |
| **CJK IME in the command bar**: don't search or submit while text is marked (0.43) | 0.43.0 (2025-08-21) | Chinese, Japanese and Korean users can type queries | idle-zero | `NSTextInputClient.hasMarkedText()`; ignore Return while composing | **must** (correctness) |
| F12 opens the Web Inspector; F1–F12 bindable (1.15) | 1.15.0 (2026-01-23) | Familiar developer key | idle-zero | `WKWebView.isInspectable` (macOS 13.3+) | **nice** (*detail* of ROADMAP Web Inspector) |
| **AppleScript** dictionary: list, focus and open tabs, switch space (the base for a Raycast extension) (1.7) | 1.7.0 (2025-12-01) | Launcher users jump to tabs without touching den | idle-zero (`sdef` plus Cocoa scripting) | Standard `NSScriptCommand`. ROADMAP lists Shortcuts / App Intents but not AppleScript, and Raycast's browser extensions use AppleScript (UNVERIFIED for Raycast's current API) | **nice** |

### 2.5 Command bar

| Item | Dia version (date) | Friction removed | Cost | WKWebView feasibility | Verdict |
|---|---|---|---|---|---|
| **"new …" creation shortcuts**: "new doc / sheet / slides / meet / notion / linear / jira / figma / gist" opens the service's `.new` URL; the row and input icon switch to the service's icon (1.8, 1.9) | 1.8.0 (2025-12-04), 1.9.0 (2025-12-11) | Start a doc or ticket in one step | idle-zero (a static table) | Pure `commands.register`. Each `.new` domain must be checked before shipping (`doc.new` etc. are Google's; others UNVERIFIED) | **must** |

### 2.6 Downloads, profiles, import, privacy

| Item | Dia version (date) | Friction removed | Cost | WKWebView feasibility | Verdict |
|---|---|---|---|---|---|
| Download notifications don't show the source site address (anti-spoofing) (0.44) | 0.44.0 (2025-08-28) | A site can't make a download look like it came from someone else | idle-zero | den UI choice | **nice** (*detail* of wave-B Downloads) |
| **Incognito windows dark** by default (1.18.1) | 1.18.1 (2026-02-12) | Can't mistake a private window for a normal one | idle-zero | `NSWindow.appearance = .darkAqua` | **must** (micro; in the gap report's micro list, not in the approved shortlist) |
| Import from Chrome: tab groups as folders (1.18.1), pinned tabs stay pinned (1.8) | 1.8.0, 1.18.1 | Moving from Chrome keeps your setup | idle-zero | Read Chrome's `Preferences` / session files (format UNVERIFIED) | **nice** (*detail* of ROADMAP Import) |
| Sync with a recovery kit plus 6-character pairing code (1.26) | 1.26.0 | – | – | ROADMAP uses CloudKit, which needs no pairing | **skip** |
| Local-only history plus an opt-out telemetry toggle (1.45 page) | 1.45.0 | – | – | den has no telemetry | **skip** (n/a) |

### 2.7 Reliability, performance, small polish

| Item | Dia version (date) | Friction removed | Cost | WKWebView feasibility | Verdict |
|---|---|---|---|---|---|
| **No white flash** on tab switch or load for dark sites (Notion, Slack) (1.7, 1.10.1) | 1.7.0, 1.10.1 (2025-12-18) | No blinding flash at night | idle-zero | Set `underPageBackgroundColor` / `drawsBackground = false` from the tab's last known tone (the `darkmode` plugin already caches dark hosts in `tones`) and den's appearance | **must** |
| **JS dialog loop protection**: "Prevent this page from creating more dialogs", and the tab can close while a dialog is up (1.15); dialog text is selectable (1.15) | 1.15.0 (2026-01-23) | A hostile page can't trap the window | idle-zero | den implements `WKUIDelegate` alert/confirm/prompt; count per page load | **must** |
| **Crashed-page view**: when the web process dies, show "This page crashed · Reload" instead of a blank page (0.45) | 0.45.0 (2025-09-08) | You know what happened and recover in one click | idle-zero | `webViewWebContentProcessDidTerminate(_:)`. Don't auto-reload in a loop | **must** |
| Favicon cache capped and pre-warmed at launch (1.13.1, 1.18.1) | 1.13.1, 1.18.1 | Faster start and command bar | saves | den-owned cache with an LRU cap; the right cap needs measuring | **nice** (perf hygiene; add to the perf budget work) |
| Help → **Record Performance Issue / Copy Diagnostics** (1.22, 1.24) | 1.22.0 (2026-03-12) | Users can file perf bugs with data | idle-zero | Per-tab state, discard counts, den's footprint (the same numbers the wave-5 measurement produces) | **nice** |
| Shed optional work under load, and cheaper idle animations (1.24) | 1.24.0 (2026-03-26) | Busy Mac stays responsive | saves | `ProcessInfo.thermalState` and Low Power Mode; pause decorative animation | **nice** (fits Shields B "Energy") |
| Verify back/forward cache is active for instant back (1.40) | 1.40.0 (2026-07-16) | Back is instant | per-use memory | WebKit's page cache in WKWebView: default capacity UNVERIFIED, so measure it | **nice** (verify, don't build) |
| Toast in full screen (1.6); bundle arm64-only (1.43) | 1.6.0, 1.43.1 | Feedback when chrome is hidden; smaller download | idle-zero | Toast host in the full-screen window; whether macOS 26 still needs Intel slices is a release decision | **nice** |
| **Briefing hover checklist**: hovering the briefing's sidebar entry shows today's todos, checkable in the card (1.38, `CliaBriefPreview`) | 1.38.0 (2026-07-02) | Tick off a todo without opening the briefing | idle-zero (reads persisted todos) | A `previews` provider for the briefing page, using `briefing.toggle` | **nice** |

---

## 3. Micro-interactions

These are Dia's small interaction details: click modifiers, drags, hovers, shortcuts, "just works" automation, toasts and undo. Each row gives Dia's exact behaviour, taken from the changelog text, release-note videos ([inventory](dia-changelog-inventory.md)) or live observation ([dia-ui-spec](../reference/dia-ui-spec.md)).

**Mapping to den.** Dia uses Chrome-style groups; den uses Arc folders. Folders are currently pinned-only (`tabs.createFolder`, [plugin-services](../plugin-services.md)). Several group behaviours therefore need **folders in the Today section** too, plus these three rules:
- a Today folder archives with its tabs
- it dissolves when it holds one tab
- it is auto-named from the source tab's title, with no AI

This is a den design choice, not something Dia specifies.

**Resource cost.** Every item is idle-zero, pure den UI or state.

**What "Already in den" means.** It covers anything in [plugin-services](../plugin-services.md), FEATURES, the approved shortlist or the wave-5 plan. Those items are listed only to show they were checked.

### 3.1 Click modifiers

| Dia behaviour (exact) | Version (date) | den mapping | Verdict |
|---|---|---|---|
| **⌘-click a link → a group of the source tab plus the new tab.** "⌘-clicking links from a doc auto-creates 'Group 1' containing the source doc and each opened link." Further ⌘-clicks from the same source join the group. A new group opens its name in inline rename. A ⌘-click group left with a single tab **auto-ungroups** | 1.16.0 (2026-01-29); rename-on-create and auto-ungroup 1.13.1 (2026-01-08) | ⌘-click from tab A creates a Today folder named after A, holding A and the new background tab. Later ⌘-clicks from A **or from any tab in that folder** join it. The folder dissolves back into a plain tab at one child. Setting: "⌘-click groups links with their source" (default on); off keeps Arc's plain background tab. Differences from Dia: the name is pre-filled from A's title instead of "Group 1", selected for rename but accepted on Esc; the colour/icon is A's favicon, like Dia 1.10.1. **Reverses the earlier "skip" in [gaps-arc-dia-zen-firefox §3](gaps-arc-dia-zen-firefox.md), per the user's explicit request** | **must** |
| **⇧⌥-click a link → opens it in a right-hand split** | 0.44.0 (2025-08-28) | `tabs.split` with the current tab. Listed under "details for planned items" in the gap report but not in the approved shortlist; confirm it's in the split work | **must** |
| **⌥-click the New Tab (+) → a new tab in a split** | 0.47.0 (2025-09-18) | `tabs.split` plus `commands.open {mode: edit}` for the new pane | **must** |
| **⌘ / middle-click a back, forward or reload history entry → background tab; add ⇧ for foreground** | 1.10.1 (2025-12-18) | `backForwardList` item → `tabs.open {background}` | **nice** |
| **"Hold ⌘ to switch →"** on an open-tab row in the command bar: Enter on a matching URL opens it, ⌘-Enter switches to the tab already open | ui-spec §5 (1.50.1) | den's bar always switches to open tabs. Add the reverse: a modifier that **opens a fresh copy** instead of switching, shown as a hint on the row | **nice** |
| **⌘-hover a pinned tile's favicon** shows "Separate from Pinned Tab" (click detaches the current page as a normal tab). A drifted pinned tab's favicon shows "Back to Pinned URL" | ui-spec §2.5 (1.50.1) | den already has the "/" drift marker and reset. The **⌘ = separate** modifier and the explicit hover label are new | **nice** |
| **⌘↩ on a pinned tab → back to its pinned URL** | 1.4.0 (2025-11-06) | `tabs.reset` bound to ⌘↩ while a pinned tab is focused (den has reset, but not this key) | **nice** |
| **⌥ alternates in menus**: ⌥ turns Copy Link into **Copy Link as Markdown**, and Close Tabs Below into **Close Tabs Above** | ui-spec §4 (1.50.1) | `NSMenuItem.isAlternate` | **must** (also in §2.1) |
| ⌘-click a background tab while peeking a group keeps it visible in the peek list | 1.47.1 (2026-09-03) | Applies if den folders get a hover flyout (§3.3) | **nice** |
| ⌘-click / ⌥-click / middle-click **bookmarks** (background, split, open folder) | 1.1.0, 0.45.0 | den has no bookmarks. The same modifiers on **folder rows and favorites** are the equivalent: ⌥-click a folder opens all its tabs in a split (up to 4), and middle-click a favorite opens a background copy | **nice** |

### 3.2 Drag

| Dia behaviour (exact) | Version (date) | den mapping | Verdict |
|---|---|---|---|
| **Drag a tab onto a group header → the tab joins the group** | 1.9.0 (2025-12-11) | Drop a tab on a folder row (den likely has this for pinned folders; confirm it also works for Today folders) | **must** (with the Today folders from §3.1) |
| Drag a tab to the screen edge → split, with a dashed **"Add left split"** drop card; larger drop targets | 1.25.0, 1.28.0, 1.5.0 | Already in den (drag-to-split). Check the drop-card copy and target size | detail |
| **Drag the sidebar edge all the way closed → Focus Mode** (traffic lights hide); drag it back to restore | 1.5.0 (2025-11-13) | Compact mode exists; entering it by *dragging* the edge shut is new | **nice** |
| Sidebar **rubber-bands** at its min and max width while dragging | 1.29.0 (2026-04-30) | Resize handle with resistance past the limits | **nice** |
| Meeting-reminder panel: two-finger drag, **snaps to corners**, avoids screen edges | 1.7.0 (2025-12-01) | Reuse the mini-player's snap logic for the reminder card (§2.2) | **must** (with the reminder) |
| PiP stash past the edge; drag from Recent Downloads never opens the file | 1.36, 1.19 | Already in den (approved shortlist E, wave-B downloads) | covered |

### 3.3 Hover

| Dia behaviour (exact) | Version (date) | den mapping | Verdict |
|---|---|---|---|
| **A collapsed group shows only its active tab**; hovering the header opens a flyout with all its tabs plus "+ New Tab" | 1.28.0 (2026-04-23) | A collapsed folder keeps its selected tab visible under the header, and the `previews` folder card gains clickable rows plus "+ New Tab". Arc's behaviour here is UNVERIFIED | **must** |
| Hovering a group shows an **X**; closing a group from its header in one click | 1.15.0, 1.18.1 | Folder hover X = archive the folder's tabs (asks first, as `deleteFolder` does) | **nice** |
| Hover the "N ✓" badge → **Recently Closed** popover; clicking restores the item | 1.23.0 (2026-03-19) | Live Folder mechanics (§2.1) | **must** (in §2.1) |
| Hover card action buttons (Pin, Bookmark, Split; Reset on pinned); a disabled Reset when already at the pinned URL | 1.7.0, 1.14.0; ui-spec §2.5 | Already in the wave-5 hover-card rebuild | covered |

### 3.4 Keyboard shortcuts added over time

| Shortcut (exact) | Version (date) | den mapping | Verdict |
|---|---|---|---|
| **⌃⌘N: new group from the selected tabs** ("mirrors Finder's New Folder with Selection") | 1.47.1 (2026-09-03) | New folder from the multi-selection, name field in rename | **must** |
| **⌥⌘T: new tab inside the current group** | 1.16.0 (2026-01-29) | New tab inside the selected tab's folder | **must** |
| ⌘⌥K: clean up stale tabs now | 1.33.0 (2026-05-28) | den's ⌘⇧K clears Today; an "archive tabs idle > X now" variant is redundant | **skip** |
| ⌃Tab / ⌃⇧Tab MRU switcher; ⌘⇧A tab search incl. recently closed; ⌘S / ⌘⇧S layout; ⌘⇧K close all; ⌥⇧⌘C copy as Markdown; double-click to rename | 1.8–1.33 | Already in den (tabs shortcuts, command bar, FEATURES) | covered |
| ⇧⌘P profile switcher menu; ⌃1–9 profiles | 1.15, 1.22 | den: ⌃1–9 switch spaces | covered |
| F12 → DevTools; F1–F12 bindable | 1.15.0 | See §2.4 | **nice** |

### 3.5 Automation and "just works" defaults

| Dia behaviour (exact) | Version (date) | den mapping | Verdict |
|---|---|---|---|
| **Group colour derived from the favicon or theme colour** (Hacker News → orange, cash.app → green; the grouped area takes a light matching tint) | 1.10.1 (2025-12-18) | New folders take their icon and tint from the first tab's favicon; manual override wins | **nice** |
| **New group → name field already selected** for inline rename; Esc keeps the default | 1.13.1, 1.18.1; ui-spec §6 | den already does rename-in-place; make it automatic on every folder creation | **must** (micro) |
| GitHub Live Group **auto-created the first time you open a PR**, pinned, with a one-time popover: "Pull requests from you and your team will show up here automatically" | 1.17.0 (2026-02-05) | When GitHub auto-connects, offer the live folder with the same one-line explanation (don't create it silently; den's call) | **nice** |
| Duplicate of a pinned tab opens as a normal tab | 1.14.0 | §2.1 | **nice** |
| Sidebar scrolls to reveal a ⌘-clicked background tab | 1.18.1 | §2.1 | **nice** |
| Blank New Tab pages clear on app switch or lock; blocker toggle auto-reloads | 1.38, 1.15 | Already in the approved shortlist (B, A) | covered |

### 3.6 Toasts and undo

| Dia behaviour (exact) | Version (date) | den mapping | Verdict |
|---|---|---|---|
| **"Cleaned up N tabs"** chip with a broom icon, reopenable from the overflow menu | 1.30.0 (2026-05-07) | den's `clearToday` toast with undo, and auto-archive to the Library, already cover it | covered |
| **"Live Group Created"** popover explaining what will appear | 1.17.0, 1.27.0 | One-time popover when a live folder is first made (§3.5) | **nice** |
| Toasts shown for actions **in full screen** | 1.6.0 | §2.7 | **nice** |
| Bulk-action **undo** (Dia: bookmarks) | 1.26.0 | den: extend `tabs.undo` to multi-select close/move and to folder dissolve | **must** (micro, needed once ⌘-click folders can auto-dissolve) |

---

## 4. Top 15 for den (ordered by daily impact)

1. **⌘-click a link → a folder of the source tab plus the new tab**, dissolving at one tab (§3.1)
2. **Meeting reminder card with Join**, snapping to corners, plus the pinned-calendar countdown, fed by the Calendar connection (§2.2, §3.2)
3. **No white flash** on tab switch and load (§2.7)
4. **Live Folder mechanics**: unread pip, done items animate into an "N ✓" Recently Closed popover, PR stacks, reauth cue (§2.1, §3.3)
5. **Folder shortcuts**: ⌃⌘N folder from selection, ⌥⌘T new tab in folder, drag a tab onto a folder, auto-rename on create, undo (§3.4, §3.2, §3.6)
6. **Protect recently used tabs from discard**, with an app-active idle clock (§2.1)
7. **Split modifiers**: ⇧⌥-click a link → right split; ⌥-click + → new tab in a split (§3.1)
8. **Collapsed folder keeps its active tab visible**, and a hover flyout lists all its tabs plus "+ New Tab" (§3.3)
9. **Faster tab close**: show the next tab first (§2.1)
10. **"new …" creation shortcuts** in the command bar (§2.5)
11. **Tab menu shows shortcuts**, with ⌥ alternates (Copy as Markdown, Close Tabs Above) and Close Other/Below (§2.1, §3.1)
12. **Keyboard correctness**: non-US layouts and CJK IME (§2.4)
13. **Notion connection**: mentions and comments in the feed and a live folder (§1.2)
14. **Hover media controls** for any playing audio tab (§2.3)
15. **Crashed-page view and JS dialog loop protection** (§2.7)

Next in line:
- Linear and Jira/Confluence notifications
- mute a site
- AppleScript
- ⌘/middle-click on history entries
- ⌘-hover "Separate from Pinned Tab" and ⌘↩ pinned reset
- folder colour from favicon
- drag the sidebar shut to enter Focus Mode
- dark incognito windows
- the Ctrl-Tab thumbnail grid
- the briefing hover checklist
- AirPlay
- suppressing update prompts during calls

---

## 5. AI features deliberately skipped

den's AI is on-device and used only for the briefing and feed, with no chat, so all of these are skipped:

- Chat, the chat sidebar, and @-mentions of tabs, groups, files and tools; "Chat with this tab/group" (card button and menu items); editing, stopping and resuming answers; searching past chats; the thinking UI
- Skills, the Skill Builder and the Skills Gallery; Reports, Decks and the Files menu; artifacts
- Memory and Memory Search (Dia itself retired Memory in 1.50); Personalization; ChatGPT history import
- Proactive Suggestions on the New Tab page
- The command-bar search-vs-chat routing model, and the ⌃⌘↩ route to Chat (den has no chat, so no route is needed)
- Automatic tab-group naming, auto-emoji and group-name shimmer
- Voice dictation and voice tabs
- Ask on Page, YouTube summaries, PDF and iframe reading for chat
- Chat tools for Gmail, Calendar and Autofill; Slack attachment, image and voice-note reading; Sheets reading
- Zoom, Figma, Salesforce, Canva, LinkedIn, Granola and Amplitude tools; "Request a Tool/App"
- Notion write-ups compiled from other sources; Linear status tables; Teams/Outlook/SharePoint Q&A
- Clarifying questions; safety-classifier tuning
- The cloud Morning Brief. den's on-device briefing already covers the non-AI half, and the wave-B on-device auto-grouping is the user's own existing plan, not added here

UNVERIFIED items are listed inline. None of the connection endpoints were exercised against a signed-in account in this research.
