# Roadmap

Everything we want in den, as checklists. Research behind each section is in [`docs/research/`](docs/research/). How to use what has shipped is in the [user guide](docs/guide/); what's in progress, in plain words, is in [Coming soon](docs/guide/coming-soon.md).

## Principles

Every item below has to respect these. If a feature can't, it gets redesigned or dropped.

- **Plugin-based.** The core is a small host. Features — including built-in ones like the sidebar, split view, and connections — are plugins.
- **Hot-swappable.** Any plugin can be loaded, unloaded, updated, or replaced at runtime without restarting the browser or losing tabs.
- **Lazy by default.** Nothing loads until it's needed: plugins, connections, web content, even tab processes.
- **Minimal resources.** Idle tabs cost as close to nothing as possible. Memory and energy use are tracked like bugs.

### UX principles

- **Zero-friction start.** den opens instantly into a usable browser. No blocking welcome, sign-up or setup wizard. A tour, import or tip is always optional, small, skippable, shown once, and never modal ([spec](docs/guide/_in-app-tips.md#principles)).
- **Shortcuts wherever an action appears.** If an action has a shortcut, it's shown next to the action on every surface: menu bar, context menus, command bar rows, tooltips on icon and hover-card buttons, Settings rows ([audit checklist](docs/guide/_in-app-tips.md#2-shortcuts-everywhere-an-action-appears)).
- **No row tooltips.** Sidebar rows, tiles and list rows don't get tooltips: hover cards already show that information, and a tooltip on top of a card is noise.

## Status

| Mark | Meaning |
|---|---|
| ✅ | Shipped: on `main`, covered by `swift test` or a `--scenario` run of the real app |
| 🟡 | In progress: being built on a branch now, or partly shipped (the sub-items say which part) |
| ⏳ | Queued: approved, not started |

Only tick an item after checking it against the code and tests on `origin/main`. When an item is partly done, split it into what shipped and what remains.

## Core

- ✅ Plugin host modeled on [cordis](https://github.com/cordiverse/cordis): shared context, services with `inject`, automatic cleanup of everything a plugin registers ([notes](docs/research/cordis-and-agent-harness.md)); [cordis-swift](https://github.com/abhishakenp/cordis-swift) with hot reload
- ✅ Typed UI slots plugins can fill: sidebar panels, toolbar items, command bar actions (host `ui` service: sidebar slots, command bar, dialogs, toasts, peek; [API](docs/host-api.md))
- ✅ Event bus between plugins
- 🟡 Core features as swappable services
  - ✅ tabs, spaces, command bar, peek, previews, theme, connections, briefing, passwords, dark mode, extensions, quit, updates are plugins
  - ⏳ history, and the sidebar rendering itself (see Thin host)
- 🟡 Plugin API versioning and permissions
  - ✅ versioning: cordis ABI check per plugin, `DenHostAPI` generation stamped by `scripts/bundle.sh`; managed plugins load only into a matching host
  - ✅ declared permissions: `session:<domain>` / `net:<domain>` per plugin (`permissions.json`), anything undeclared is denied
  - ⏳ user-granted permissions for third-party plugins
- 🟡 Lazy loading for plugins and services
  - ✅ optional features do no work until used: Settings, connections, previews, the briefing build nothing at launch; nothing polls until a connection exists
  - ✅ only the plugins that paint the first window load before it (`"launch": "firstFrame"` in their sidecar: spaces, tabs); the rest load right after it, and until then their services are stubs that load the plugin on the first call
  - ⏳ load plugin dylibs on first use of a command or event (needs manifest-declared keys, menus and commands)
- ✅ Settings system, per plugin, editable at runtime (`settings` service; Settings window ⌘, with plugin-contributed sections; settings also editable from the command bar)
- ✅ Command registry: every command bar action is a command; `[shortcuts]` in `config.toml` binds any command id or menu item
- 🟡 Crash isolation
  - ✅ a plugin that crashed den is refused at the next launch, and a managed update that crashed is rolled back
  - ⏳ a plugin failing doesn't take the browser down at all
- ✅ `~/.den`: plugins (prebuilt dylibs, or `.swift` folders den compiles), themes, unpacked extensions and `config.toml`, applied live ([docs](docs/den-home.md))
- ✅ Menu bar: complete standard macOS menus; every shortcut is a menu item ([docs/shortcuts.md](docs/shortcuts.md))

### Thin host

Moving feature code out of `DenHost` so the host holds only platform capabilities ([plan](docs/architecture/thin-host.md)).

- ✅ Audit: every host file classified, feature-specific code marked `thin-host:` in the source
- ⏳ 0. Baseline: snapshot goldens, pixel-diff script, launch/memory noise bands, signposts
- ⏳ 1. Guardrail test against new host strings, overlay slots and host → plugin calls
- ⏳ 2. Move logic with no UI to plugins (suggestions, config appliers, AI prompts, theme picker math)
- ✅ 3. `DenDev` split: scenarios and mock services are behind the `Scenarios` package trait; release bundles leave them out and no longer link Network.framework (the snapshotter stays: `--snapshot` works in release)
- ⏳ 4. `ui.layer`, `ui.styles`, `ui.palette` alongside the old slots
- ⏳ 5. New generic nodes and behaviors, each with a golden test
- 🟡 6. Migrate screens one by one (toast → dialogs → library → briefing/connections → hover card → theme picker → sidebar rows → command bar → peek → Little Arc)
  - ✅ hover card: `HoverCard.swift` is gone; generic `ui.card` + hover intent on any node + generic nodes (`stack`, `label`, `icon`, `image`, `badge`, `meter`, `note`, `item`, `action`); `previews` composes every card
- ⏳ 7. Remove the old slots and nodes
- ⏳ 8. Land in-flight features on the generic primitives
- ⏳ 9. Separately loadable native modules

## Web engine (WebKit)

Details and sources: [Apple platform notes](docs/research/apple-platform.md).

- ✅ Tab model on `WKWebView`
- ✅ Profiles with isolated data stores (`WKWebsiteDataStore(forIdentifier:)`), chosen per space
- ✅ Tab suspension, two levels: WebKit's built-in suspend when a tab leaves the window, then full discard after 5 min (state kept, snapshot on disk, web view and WebContent process gone; the snapshot shows at once on restore). Media, PiP, camera/mic and unsaved input are never discarded
- 🟡 Session restore and crash recovery
  - ✅ spaces, tabs and selection come back after quit, relaunch and updates (plugin storage); discarded tabs keep `interactionState`
  - ✅ every open window comes back after a relaunch, on its own space and tab (private windows don't)
  - ✅ a "This page crashed · Reload" view when a page's web process dies (never reloads by itself)
  - ⏳ crash recovery of den itself
- ⏳ Apple Pay exception: skip den's injected scripts on checkout pages, since any injection disables Apple Pay
- ⏳ Web push notifications: not supported in `WKWebView`; decide on a workaround or skip
- ✅ Downloads: `WKDownload` into ~/Downloads (quarantined, Finder-style names), Library ▸ Downloads (⌥⌘L) with pause/resume (kept across relaunch), cancel, retry, open, reveal and drag out, a sidebar progress ring, auto-archive after 1 day (Settings ▸ Tabs) ([guide](docs/guide/downloads.md))
- ✅ Find in page (find bar, ⌘F/⌘G/⇧⌘G/⌘E)
- 🟡 Printing and PDF viewing
  - ✅ print (⌘P), save as Web Archive (⇧⌘S)
  - ⏳ PDF viewing verified
- 🟡 Permissions
  - ✅ camera and microphone prompts, HTTP sign-in, file panels, JS alert/confirm/prompt
  - ⏳ location, notifications
- 🟡 Picture-in-picture and media controls (see Media)
  - ✅ picture in picture: WebKit's own (the system PiP window Safari uses); automatic when you leave a playing video's tab or den, ⌥⌘P by hand
  - ✅ tab mute from the sidebar speaker (WebKit page mute)
- ✅ Web Inspector (docked, ⌥⌘I toggles), Inspect Element in every context menu, element picker, console, view source; Develop menu (user agent, empty / disable caches, extension background pages)
- ✅ Default browser handling: Settings, menu bar, command bar banner, "Try for a week"
- ✅ Error pages (offline, host not found, timeout, can't connect, not private) with Try Again
- ✅ Google sign-in: Safari's user agent
- ✅ Link clicks: ⌘-click / middle-click background tab, ⌘⇧-click front tab
- ✅ No white flash on tab switch or load: the previous page is held until the new one paints (≤ 1 s), and an unpainted page shows its own last colour
- ✅ JS dialog loop protection: from the fourth alert/confirm/prompt in a page load, "Stop this page from showing dialogs"
- ⏳ Protection against pages opening endless alerts

## UI (Arc-style)

Details and sources: [Arc notes](docs/research/arc.md), [Zen notes](docs/research/zen.md), [Dia UI spec](docs/reference/dia-ui-spec.md).

### Sidebar and tabs

- 🟡 Vertical sidebar tabs, with a right-side option (Arc never shipped one)
  - ✅ vertical sidebar, resizable (double-click the edge resets), hide with ⌘S and reveal from the edge
  - ⏳ right-side option
- ✅ Favorites grid, shared across spaces
- ✅ Pinned tabs per space, which reset to their original URL
- ✅ Today tabs with auto-archive (24 h by default; configurable, can be turned off)
- ✅ Archive of closed tabs, searchable (Library ⌘Y / ⇧⌘L; command bar "View Archive"; Little Arc windows auto-archive into it)
- ✅ Undo sidebar actions (⌃Z), reopen closed tab (⇧⌘T)
- ✅ Drag and drop: reorder, into folders, onto a space icon, onto the page to split, onto a split row
- 🟡 Folders, including live folders fed by GitHub or RSS (from Zen)
  - ✅ nested folders: create, rename, delete (archives the tabs), collapse, hover card listing their tabs
  - ✅ GitHub live folders ("New GitHub Live Folder"): rows from the GitHub connection's feed, unread dots (and a dot on a collapsed folder), done items into an "N ✓" chip with a Recently Closed popover, PR stacks from head/base branches, a sign-in row when signed out; no polling of their own
  - ⏳ RSS live folders; two-line rows ("author • state") and the PR peek's actions on live rows
  - ✅ folders in Today (groups), with Dia's panel look
  - ✅ a collapsed folder keeps its active tab visible; its hover card switches to a tab and has "New Tab"
  - ✅ folder shortcuts: ⌃⌘N folder from selection (⌘/⇧-click to pick), ⌥⌘T new tab in folder, drag onto folder, rename on create, undo
- ✅ ⌘-click grouping (Dia): background tab grouped with its source in Today, named after the sites (a better name from the on-device model when available); later ⌘-clicks join in opener order; dissolves at one tab; ⌃Z ungroups; a setting turns it off
- 🟡 Icon and title fallbacks: never "data:" or blank
  - ✅ sharp letter/globe fallback favicons
  - 🟡 title fallbacks and the rest of the sweep
- 🟡 Tab mute: click the speaker icon, badge on favorites, "Mute Tab" in the menu
  - ✅ speaker icon on tabs and favorites playing audio
  - 🟡 muting
- ✅ Faster tab close: the next tab goes on screen first, one render, one snapshot
- ✅ Tab menu shows shortcuts and ⌥ alternates (Copy Link as Markdown, Close Other Tabs, Close Tabs Above), Close Tabs Below
- ✅ Split modifiers: ⇧⌥-click a link → right split; ⌥-click New Tab → new tab in a split
- ⏳ Resize split panes by dragging

### Spaces and themes

- ✅ Spaces with their own colors/themes, swipe to switch
- ✅ Space right-click menu (rename, icon, theme, profile, duplicate, move, delete), double-click to rename, emoji icons
- ✅ Rearrange spaces by dragging in the footer
- ✅ Theme picker: up to 3 colors, intensity, grain, presets, live preview, Esc reverts; recent themes and `~/.den/themes` presets as commands
- ✅ Every surface (dialogs, bars, cards, toasts) follows the space's theme with WCAG-legible contrast
- 🟡 A profile per space (Zen's most-requested missing feature)
  - ✅ separate data store per profile, chosen in the space menu
  - ⏳ profile management UI; open tabs switch store when a space's profile changes
- ⏳ Theme and UI mods (Zen Mods style: CSS plus declared options)

### Command bar, Peek, split, windows

- ✅ Command bar (`commandbar` plugin: tabs, archive/history, spaces, actions, URLs, web and site search, frecency; [contract](docs/plugin-services.md#commands-plugin-commandbar))
- ✅ Command bar as a launcher: den's commands, destinations and individual settings, ranked above web search
- ⏳ "new doc / notion / linear…" creation commands in the command bar
- ⏳ Command bar names the real search engine, and suggests site-search keywords with a toast
- ✅ Peek / link preview (⇧/⌥-click any link, links from pinned tabs; Open as Tab, Open in Split View; ⌘Z reopen)
- ✅ "Open Link in Peek" and "Open Link in Split View" in the link context menu
- ✅ Split view, including drag-to-split, 2–4 panes, side by side, top and bottom, grid
- ✅ Little Arc-style quick window (opt-in for links from other apps; ⌘O into the space)
- ✅ Compact mode / hide sidebar, chrome-less content area
- ✅ Multiple windows (⌘N) on the same spaces and tabs, each keeping its own place (space and tab); a tab shows in one window at a time ([guide](docs/guide/windows.md))
- ✅ Private windows (⇧⌘N): an ephemeral data store per window, always-dark chrome, nothing persisted (tabs, archive, command bar history, snapshots, zoom)
- ✅ Reopen a closed window with its space and tab (⇧⌘T right after the close, File ▸ Reopen Closed Window)
- ⏳ Link routing rules (Arc's Air Traffic Control)
- ⏳ Boosts: per-site CSS/JS customization
- ⏳ Web apps (PWA) support, and web apps in the Dock
- ✅ Keyboard shortcuts, fully remappable, Arc defaults (`[shortcuts]` in `config.toml`)
- ✅ Non-US keyboard layouts for shortcuts (US-position fallback for keys a layout can't type); Chinese/Japanese/Korean input in the command bar

### Hover previews

- ✅ Hover cards for sidebar tabs, favorites, folders and splits, rebuilt to Dia's measured spec: 0.7 s on rows, 0.3 s on tiles, 0.2 s grace, fade + scale from the top-left, hard-cut swaps (optional re-dwell); theme-token surface (light and dark); nothing fetched until hovered
- ✅ Actions on the card: pin/unpin, back to pinned URL, open as split, duplicate, copy link, mute, move to space ▸, archive/close; tooltips show shortcuts, and the shortcuts act on the hovered tab while its card is open
- ✅ PR peek per Dia's layout: title, avatar · author · #N, +adds −dels · files, a CI bar, a status line or up to 3 failing checks, Show N failures / Show Comments / Resolve Conflicts; public repos through GitHub's public API with no sign-in
- ✅ Cards for GitHub issues, Google Calendar (Join button), Gmail, Slack, and a page snapshot for anything else
- ✅ Inline "Connect GitHub" button on cards that need a connection (private repos), filling in live
- ✅ ⇧-hover link previews on any page: an OpenGraph card from the target's `<head>`, cached, zero cost until a deliberate hover; rich providers reused; Open in Peek / Split / Copy Link; stays out of the way where a site has its own previews; plain hover as an option
- ⏳ Hover play/pause/skip for any tab playing audio

### Getting around

- 🟡 Onboarding under the zero-friction principles (`tips` plugin)
  - ✅ tour card from the second launch (5 skippable steps in the sidebar card, each completes early when you do the thing; never back once dismissed), "Take the den Tour" command
  - ✅ quiet one-click import card, shown only when a plugin provides the `importer` service
  - ⏳ tour callouts pointing at the real UI (the steps show in the sidebar card for now); an importer
- 🟡 One-time discovery tips, one at a time, with a global off switch ([spec](docs/guide/_in-app-tips.md))
  - ✅ 14 tips wired to existing events, limits (1 per 10 min, 3 a day, none in the first minute or over a modal), Settings ▸ General ▸ Show tips, "Don't Show Tips" in the bar and on every tip
  - ⏳ tips that need events den doesn't emit yet (link linger, ⌘F, tab drags, context-menu opens, keyword searches)
- ✅ Shortcuts shown on every surface where the action appears, remaps included (read from the menu bar item: `keyFor` / `shortcutFor`)
  - ✅ menu bar, command bar rows (menu glyph order ⌃⌥⇧⌘; Copy URL as Markdown ⌥⇧⌘C)
  - ✅ hover-card button tooltips (and the shortcuts act on the hovered tab while its card is open, a remapped chord too)
  - ✅ tab, folder and space context menus (with ⌥ alternates); page context menu (Back, Forward, Reload, Save Page As…, Print…, View Page Source, Cut, Copy, Paste, Paste and Match Style, PiP, Inspect Element)
  - ✅ icon-button tooltips: sidebar toggle, Back, Forward, Reload/Stop, Copy Link, Library, New Space, space icons (⌃1…⌃9), split pane ×, Peek, find bar; Settings rows and toasts in glyphs
- ✅ No row tooltips: tab rows, tiles, split rows and list rows show hover cards instead
- ✅ User guide ([docs/guide](docs/guide/)), with Tips & hidden gems
- 🟡 Detail audit: every interaction compared with Arc/Dia (hover states, click targets, tooltips, context menus, animations, empty states, error pages, keyboard coverage) and fixed, plus Dia's micro-interactions
  - ✅ first pass (2026-09-28): tooltips and VoiceOver names on every icon button, an empty space shows Arc's "Open a tab." card with a ⌘T keycap, the Little Arc "Open in" button drops its duplicate tooltip, command bar glyph order, consistent "Title  ⌘X" tooltips
  - ⏳ Favorites empty-state card ("Drag to add Favorites"), toast hover-to-keep, Dia's micro-interactions

## Media

- ✅ Picture in picture is the system's (WebKit's native PiP, the window Safari uses: on top of every app, every Space and full-screen apps, stash, resize, the system's play/pause, skip, close and return-to-tab). den's custom mini player is gone. ⌥⌘P / View ▸ Picture in Picture / the command bar toggle it; the now-playing dock, the tab speaker, ⌃⌘P, media keys and Control Center control the video while it floats ([guide](docs/guide/media.md#picture-in-picture))
- ⏳ Around the native window: per-tab volume and playback speed from den (the system window has neither)
- ✅ Now-playing dock at the bottom of the sidebar, Control Center and media keys ([guide](docs/guide/media.md#now-playing-at-the-bottom-of-the-sidebar)). ⏳ Verify on a real Mac how macOS picks between den's Now Playing entry and WebKit's own (CI has no media keys)
- ✅ Hover play/pause/skip on the row of any tab playing (or paused) media
- ✅ Web panels (optional `panels` plugin, ⌃⌘S; [guide](docs/guide/media.md#web-panels)). ⏳ Drag to resize a panel
- ✅ AutoPiP like Safari's video viewer, on by default: leaving a playing video's tab or space, or minimizing, hiding or covering den (or a full-screen video's Space switched away) puts it in native picture in picture; coming back takes it out
- ✅ Tabs playing audio are never archived or unloaded, and updates never relaunch during playback
- ⏳ Camera, mic and screen-share badges on tabs, click to turn off
- ✅ Meeting reminder card with Join, View and Dismiss (window's top-right corner, 2 minutes before by default), plus an "in 8m" countdown on the Calendar favorite
- ⏳ Reminder card you can drag and that snaps to corners; Meeting Tab Groups on join

## Extensions

Details and sources: [extension notes](docs/research/extensions-on-webkit.md).

- ✅ Chrome and Firefox extensions via Apple's `WKWebExtension` API (Manifest v2 and v3, `chrome.*` and `browser.*`): popups, pinning in the URL pill, the Extensions page, per-site access ([host API](docs/host-api.md#webext))
- ✅ One-click install from Chrome Web Store / addons.mozilla.org ("Add to den"), with daily update checks. Terms researched (CWS ToS says "for use in connection with Google Chrome"); get counsel before a commercial release
- ✅ Unpacked extensions from `~/.den/extensions`, and installs from `.crx` / `.xpi` / `.zip`
- ⏳ Fill in APIs Apple leaves out where feasible: `bookmarks`, `sidePanel`, `downloads`, `history`, `identity`
- ⏳ Extension keyboard `commands` and context-menu items in den's menus
- ⏳ Native messaging bridge (password managers)
- ✅ Built-in ad/tracker blocker: EasyList, EasyPrivacy and the EasyList Cookie List compiled to WebKit content rules at release time with `adblock-rust`, including element hiding ([Shields](docs/plugin-services.md#shields-plugin-shields)); offers to step aside when uBlock Origin Lite is installed
- ✅ Scriptlets for YouTube ads (pre-roll, mid-roll, feed and search promotions, the anti-adblock dialog): uBlock Origin's YouTube rules as data, run by den's own engine in the page's world; the data refreshes daily without a release ([Shields](docs/plugin-services.md#shields-plugin-shields))
- ✅ Scriptlets for ~21,000 other sites (anti-adblock walls, pop-unders): uBlock Origin's site rules, converted to data for den's engine and delivered per site ([Shields](docs/plugin-services.md#shields-plugin-shields))
- ⏳ Procedural cosmetic filters, and uBO scriptlets that carry code (`rpnt`, `trusted-*`) or need entities (`name.*`)
- ❌ Twitch pre-rolls: not served to den from the test network (logged out, 5 channels, playlists without ad markers), so a Twitch blocker could not be verified and isn't shipped
- ✅ Filter lists refresh daily without a release: a scheduled workflow converts EasyList, EasyPrivacy and the Cookie List and publishes them; den downloads, compiles off the main thread and swaps them into open pages, no relaunch ([Shields](docs/plugin-services.md#shields-plugin-shields))
- ✅ uBlock Origin Lite works (full uBlock Origin can't, since WebKit has no blocking `webRequest`)
- ✅ Minimum macOS: 26 Tahoe. No support for older versions; newer-OS APIs (macOS 27) used when available

## Connections and daily briefing (Dia-style)

Details and sources: [Dia notes](docs/research/dia.md), [Dia shortlist](docs/research/dia-shortlist.md).

How it connects (user decision, see [auth research](docs/research/integrations-auth.md)): no OAuth apps. You sign in to slack.com, github.com, Google or Notion inside den like any site, and den reuses that session from its own WebKit data store (`session` + `net` host services, gated per plugin by declared `session:<domain>` permissions). Shipped items are verified end to end against local fakes of all five services (`MockServices`); a first real sign-in has not been verified.

- ✅ Connection plugins: Slack (unread DMs, mentions, threads awaiting your reply; workspace picker) and GitHub (review requests, mentions, assigned issues, failing CI on your PRs)
- ✅ Multiple Slack workspaces at once, each switchable in Settings ▸ Connections
- ✅ "Connect X": opens the sign-in page in a tab, detects the session, toasts "X connected"; disconnect; sign-out detected
- ✅ Auto-connect like Dia: already signed in to github.com/Slack in den, or signing in later, connects automatically (a `WKHTTPCookieStore` observer, event-driven, zero polling) with a "GitHub connected · Undo" toast; the same for every connection plugin
- ✅ Important Slack channels (across workspaces) and important GitHub repos: ranked higher in the briefing and feed, never dropped from the summary; picker in Settings and via the command bar
- ✅ Gmail (every signed-in account, switchable; unread mail, "waiting for your reply" from people, Google Docs activity from its notification mail) and Google Calendar (today's events read from the open Calendar page, no requests; the secret iCal address as a documented fallback), each its own lazy plugin with auto-connect. Risks: [auth research §11](docs/research/integrations-auth.md#11-session-reuse-for-gmail-google-calendar-and-notion-2026-09-28)
- ✅ Notion (mentions, comments, pages shared with you, per workspace) through its internal web API. Its terms forbid automated access: decide before a release whether it stays, becomes connect-only, or waits for an official API
- ⏳ Choose which calendars show; Calendar data without an open tab or pasted address (no verified session route yet)
- ⏳ More connections as plugins: Linear and Jira/Confluence, then Outlook's calendar from a loaded tab. Skipped: Teams, SharePoint, Zoom, Figma, YouTube, LinkedIn, Sheets
- ✅ No tokens stored: session tokens are read on demand and kept in memory only; connections run locally
- ⏳ Official OAuth option (Slack PKCE / GitHub device flow) for users who don't want session reuse
- ✅ Daily briefing (Slack + GitHub) summarized with a todo list, prepared at a set time (8:00 by default, catches up after sleep or launch)
- ✅ Briefing sources beyond Slack and GitHub: today's calendar (a Today section), emails awaiting a reply, Notion mentions and comments
- ✅ Settings ▸ Connections: every connection with its status, account and workspace pickers, Important…, Disconnect
- ✅ Briefing todos can be checked off (persisted) and link back to the exact message, PR or thread
- ✅ Personalized feed: one stream across connections, ranked by kind, recency and what you open
- ✅ Connections load and sync only when used: nothing polls until a connection exists, then a 15-minute refresh and on wake

## AI

AI in den is Apple's on-device model, used only for the daily briefing and the personalized feed. No chat, no agent, nothing sent to a cloud model. Anything else is left to plugins.

- ✅ Summarize connection data with Apple's Foundation Models framework, on device (`ai` host service; todos through guided generation, one item per request so a todo can't attach to the wrong source)
- ✅ Fit the model's small context (4,096 tokens on macOS 26, read at runtime): summarize each source separately in chunks, then combine; overflowing chunks are split and retried
- ⏳ Model loads only while generating a briefing or ranking the feed, then is released (measure it)
- ✅ Model output is text and todos only: no tools, cannot click, send or open anything
- ✅ Every todo and feed item links to its source message, PR or thread (the summary paragraph itself has no links)
- ✅ Works without the model (plain counts and lists) on Macs without Apple Intelligence
- ⏳ Auto tab grouping and tidy tabs (on-device, lazy)
- ⏳ Plugin API is rich enough for someone else to build a chat/AI plugin, gated by user-granted permissions

## Apple integration

- 🟡 Passkeys for all sites
  - ✅ researched: WebKit does WebAuthn itself, but only with Apple's browser passkey entitlement, which ad-hoc signing can't carry ([notes](docs/research/passkeys.md))
  - ⏳ apply for the entitlement; sign with a real identity
- ✅ Passwords: den ships its own vault in the Keychain, filled after Touch ID; save, fill, strong-password suggestions, "Passwords…" list with copy (clipboard cleared after 60 s) and delete. No API reads iCloud Keychain / the Passwords app
- ✅ "Save password?" prompt on form submit
- 🟡 Native look: vibrancy, SF Symbols, system accent colors
  - ✅ SF Symbols throughout; accent from the space or the macOS accent (Settings ▸ General)
  - ⏳ vibrancy
- ⏳ Shortcuts / App Intents / Spotlight
- ⏳ Handoff
- ⏳ Sync via iCloud / CloudKit (no den server; Talos browser does this)

## Privacy and security

- ✅ Dark mode for every website: follows den's appearance, native dark sites left alone, no script, no flash; per-site Follow / Always Dark / Always Light / Off
- ✅ Shields: one per-site panel from the URL pill (⌥⌘S): blocker and cookie banners on/off, autoplay, pop-ups, zoom, camera/mic, real blocked counts, "Forget This Site"; offers a reload after a change and warns about unsaved input
- ✅ Tracker blocking
- ✅ Strip tracking parameters on every navigation (den's own list), so copied tab URLs are clean too
- ⏳ Clean "Copy Link" from a page's context menu
- ✅ Skip bounce-tracking redirects (den's own list of click trackers; security redirectors left alone)
- ✅ Hide cookie banners (EasyList Cookie List)
- ⏳ Answer consent dialogs with the most private choice (DuckDuckGo's autoconsent measured; not shipped)
- ✅ HTTPS-first, with den's page when a site has no HTTPS
- ✅ Readable international domain names (spoofable ones stay in Punycode), with lookalike-domain warnings
- 🟡 Per-site permissions UI
  - ✅ camera/mic answers remembered per site until quit
  - ⏳ a UI to review and change them
- 🟡 Sandboxed plugins
  - ✅ plugins can reach only the sites they declare (`session:` / `net:`)
  - ⏳ process-level sandboxing

## Page tools

- ✅ Per-site zoom, remembered
- ✅ Copy URL (⇧⌘C) and Copy URL as Markdown (⌥⇧⌘C)
- ✅ Reader mode, remembered per site, with read-aloud (⌃⌘R)
- ✅ On-device page translation (Apple Translation framework)
- ✅ Capture: region, element, visible or full page, then copy or save (⇧⌘2)
- ✅ Zap an element or remove sticky headers, remembered per site
- ✅ Copy link to highlight (text fragments)

## Share and clipboard

- ✅ Native share menu (AirDrop, Messages) and a QR code for the page (File menu, command bar, URL pill and tab menus; the QR code in a popover with Copy Image / Save…)
- ✅ Paste and Go / Paste and Search (URL pill and command bar field menus, named for what's on the clipboard)
- ✅ Copy toast says exactly what was copied ("Copied link · example.com/path…", Markdown link, image size, highlight, password)
- ✅ Clear a copied password from the clipboard after a short time (60 s), only if it's still what's on the clipboard
- ✅ Upload picker shows recent downloads, screenshots and the clipboard first (filtered by `accept`; Choose File… ⌘O for the usual panel)
- ✅ Error pages link to the Web Archive copy (site not found, refused or timed out; not offline or certificate errors)

## Energy

- 🟡 Zero-resource inactive tabs: aggressive discard, snapshot on disk, instant restore; never discard audio/video/PiP tabs
  - ✅ idle tabs discarded after 5 min of den-frontmost time (configurable), tabs playing audio and on-screen tabs never discarded
  - 🟡 near-zero per-tab cost: 85 → 17.5 KB per discarded tab on the CI runner (virtualized sidebar rows, menus built on right-click; [baseline](docs/perf/baseline.md#energy-lane-2026-09-28)), against an 8 KB budget
- ✅ Protect recently used tabs from discard (the last 5); idle time counts only while den is frontmost
- ✅ Battery saver: on battery or in Low Power Mode, idle tabs unload after 1 minute, background video pauses, new pages don't autoplay (Settings ▸ Tabs, on by default)
- ✅ Never discard tabs with unsaved input, camera/mic in use, or on an "always keep active" list ("Keep Site Active" in the tab menu)
- ⏳ Dimmed icon on discarded tabs
- 🟡 Unload a whole space or profile, by hand or automatically
  - ✅ Unload Space (⌃⌘U, the space's menu)
  - ⏳ a profile; automatically
- ⏳ Per-tab memory view
- ✅ Never keep the Mac awake while idle: den holds no power assertion (`pmset -g assertions` with a page open, idle); media you can't see or hear pauses after 5 min without input
- ✅ Blank new tabs close when you switch apps
- 🟡 Dark mode memory: on the CI runner (1x) the sheet costs +3.9 MB 2.5 s after load and +17 MB at the scroll peak on a 300-image page, nothing once settled; the root filter itself costs nothing, the media re-invert does. No cheaper variant found yet (near-viewport re-invert, compositing layers: same or worse); the +136 MB was measured at 2x on a loaded Mac
- ✅ Content rule list compiles no longer leave memory behind: a launch that compiles the Shields lists 74.3 → 18.6 MB, a page with uBlock Origin Lite 99.1 → 36.1 MB in den's process (`MallocLargeCache=0`)

## Performance

- 🟡 Memory and energy budgets
  - ✅ den-wide budgets in [`docs/perf/budgets.json`](docs/perf/budgets.json) (launch, idle memory, one page, idle CPU and wakeups, per-discarded-tab), checked by `scripts/perf.sh`
  - ⏳ per-feature budgets; energy (needs `powermetrics`)
  - ⏳ enforce the budgets on every change; meet the aspirational ones (idle CPU, 8 KB per discarded tab)
  - ✅ perf lab on the CI runner: repeated memory medians per scenario, heap/vmmap of the live app, A/B across refs ([docs/dev.md](docs/dev.md#perf-lab-memory-ab-and-bisection))
- 🟡 Benchmarks against Safari, Arc, Dia, Zen (measured, published). WebKit alone isn't proof of efficiency: the one careful independent test found Chrome used less battery than Safari
  - ✅ launch, memory and idle CPU against Arc and Dia ([baseline](docs/perf/baseline.md)), measured on a loaded machine
  - ⏳ re-run on a quiet machine; add Safari and Zen
- ✅ Startup time budget (launch median/p90 in `budgets.json`)

## Import

- ⏳ Import from Arc (spaces, pinned tabs), offered as a quiet one-click card, never a gate
- ⏳ Import from Chrome, Safari, Firefox, Zen, Dia

## Release and project

- ✅ Public repo, MIT license
- ✅ App skeleton that builds (`scripts/bundle.sh`)
- 🟡 Signed and notarized `.dmg` on GitHub Releases
  - ✅ `scripts/release.sh`: zip + dmg, per-plugin assets, `plugins.json`, EdDSA signatures; pre-release 0.1.0-alpha.1 published
  - ⏳ Developer ID signing and notarization
- ✅ Auto-update (OTA): Sparkle for the app, signed hot-swapped plugins, `stable` / `prerelease` / `follow-main` channels, relaunch only when you won't notice ([docs](docs/updates.md))
- ✅ Stable signing identity: `scripts/make-signing-identity.sh` creates "den Local Signing" in the login keychain once; `scripts/bundle.sh` signs with it (designated requirement = certificate, not cdhash), ad-hoc when absent
- ✅ CI builds on every PR: build, full test suite, report-only perf on the macos-26 runner; `scripts/ci-check.sh` for remote builds (docs/dev.md)
- ⏳ Contributing guide
- 🟡 Plugin author docs
  - ✅ [host API](docs/host-api.md), [plugin services](docs/plugin-services.md), [`~/.den` plugins](docs/den-home.md#plugins)
  - ⏳ a step-by-step guide for plugin authors
- ✅ Performance tooling: `scripts/perf.sh`, `scripts/perf/compare.sh`, `perfprobe`, `scripts/measure-memory.sh`

### Test reliability

- ✅ Bounded waits in WebKit tests (10 s budgets), web views closed after each test, timing-sensitive tests retried once by the updater and `release.sh`
- ✅ No unbounded waits: every suite carries a per-test watchdog (`Tests/DenTestSupport`) that fails a test past its limit with what it was waiting on, and stops the run with a stack sample when the main thread is stuck; waits are deadline-based and event-driven (`Wait.until`, bounded JS/callback awaits), host deadlines (session/webviews eval, suggest debounce) take an injected clock, and `scripts/test.sh` runs suites serially with a cap on the whole run
- ✅ Test windows are invisible (alpha 0 in the window server, still "on screen" for AppKit and WebKit); the test process never activates or shows a Dock icon
- ✅ A `--background` automation mode for app launches: no Dock icon, never activated, windows off every display, `--snapshot` still renders; automated launches quit by themselves and scripts SIGKILL any that don't (`scripts/lib/launch.zsh`)
- ✅ `--snapshot` never hangs on a web view that doesn't paint (10 s bound per view)
- ✅ Nothing outlives a test: each test's runtimes are torn down (WebKit pages closed, speech stopped, extension contexts unloaded); test pages are page-muted and speech is synthesized to buffers, never to a device; `scripts/test.sh` fails (exit 3) and kills any WebContent process a run leaves behind, naming its test; `--exit-after` closes every page before exiting

## Decided 2026-09-28

- ✅ Link status pill: a bottom pill with the hovered link's URL, moving away from the cursor (Arc); the full address after 1.5 s, keyboard focus too, Settings ▸ Previews ▸ Show link addresses
- ✅ Emoji tab and folder icons, from rename and the right-click menu (Arc): "Change Icon…" / "Remove Icon", click the icon while renaming, or type an emoji first; on rows, favorites tiles and hover cards; undoable, saved
- ✅ Same tab in multiple windows: opt-in (Settings ▸ Tabs), Arc's model: the tab loads once and moves to the window you pick it in; the other window shows "Open in another window · Show Here" and takes it back when it's in front
- ✅ AI tab tidying: Apple on-device model, off by default, enable in Settings, never automatic unless enabled (Tidy on the Today divider, ⌃⇧T, "Tidy Tabs" command; one ⌃Z; optional "Tidy automatically" at 8+ loose tabs; host `ai.group`)
- ✅ Web panels: optional plugin, normal priority (chat, AI chat sites like claude.ai/Gemini, reference, dashboards beside any tab; slides out from the sidebar edge; sleeps when hidden). Zen removed theirs for a Firefox-specific sandbox issue (Mozilla bug 1935985, per Zen discussion #7314) that doesn't apply to WebKit, where a panel is an ordinary sandboxed web view
- ✅ Now-playing dock at the bottom of the sidebar (Arc): every playing tab with artwork, title and artist (from the page's media info), play/pause, previous/next, mute, jump to tab and stop. Handles several playing at once, most recent first. Media keys and Control Center's Now Playing control den. Zero cost when nothing plays; event-driven
