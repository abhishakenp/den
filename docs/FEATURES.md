# Feature comparison

What Arc, Dia and Zen do, and where den stands on each. The Arc, Dia and Zen columns come from the notes in [`research/`](research/); see them for sources. The den column is checked against the code and tests on `main` and uses the same marks as [ROADMAP.md](../ROADMAP.md). Where a feature has a user-guide page, its name links there.

<p align="center"><img src="screenshots/main-dark.png" alt="den with a few spaces and tabs" width="720"></p>

**Legend**

| Mark | Arc / Dia / Zen columns |
|---|---|
| ✅ | Has it |
| ❌ | Doesn't have it |
| ➖ | Had it, removed or dropped |
| ? | Not confirmed by research |

| Mark | den column |
|---|---|
| ✅ | Shipped: on `main`, covered by `swift test` or a `--scenario` run |
| 🟡 | In progress, or partly shipped (the note says which part) |
| ⏳ | Queued: approved, not started |
| **Plugin** | Not built in; left to an optional plugin |
| **Skip** | Not planned |
| — | Not on the ROADMAP: no decision yet |

## Window and layout

| Feature | Arc | Dia | Zen | den | Notes |
|---|---|---|---|---|---|
| [Sidebar-first layout, no top toolbar](guide/sidebar-and-tabs.md) | ✅ | ✅ optional | ✅ | ✅ | Arc's layout is the base |
| Page as an inset card with rounded corners | ✅ | ? | ? | ✅ | Sizes from [arc-ui-spec](reference/arc-ui-spec.md); some are still estimates (`Tokens.swift`) |
| Sidebar on the right | ❌ rejected | ? | ✅ | ⏳ | Arc prototyped and declined it |
| [Resizable sidebar, double-click edge to reset](guide/sidebar-and-tabs.md) | ✅ | ? | ? | ✅ | |
| [Hide sidebar, reveal on screen-edge hover](guide/sidebar-and-tabs.md) | ✅ Cmd-S | ✅ | ✅ compact mode | ✅ | ⌘S |
| Optional classic top toolbar with full URL | ✅ Cmd-Shift-D | ✅ | ✅ | — | |
| Simplified URL (domain only) in sidebar | ✅ | ? | ? | ✅ | The URL pill |
| Link-hover status pill that moves away from cursor | ✅ | ? | ? | — | |
| Drag window from empty sidebar | ✅ | ? | ? | ✅ | Dragging from the top strip of the page: (unverified) |
| Horizontal tab strip | ❌ | ✅ | ❌ rejected | **Skip** | |
| Developer Mode (full URL, dev tools, colored outline, auto on localhost) | ✅ | ? | ❌ requested | — | Web Inspector, console and view source ship in the View ▸ Developer menu |
| Multiple windows (⌘N) | ✅ | ? | ? | ⏳ | den has one main window today, plus Little Arc windows |
| Private window (⇧⌘N) | ✅ | ✅ | ✅ | ⏳ | |
| Reopen a closed window with all its tabs | ? | ✅ | ? | ⏳ | [gaps-shortlist](research/gaps-shortlist.md) F |

## Tabs

| Feature | Arc | Dia | Zen | den | Notes |
|---|---|---|---|---|---|
| [Vertical tabs](guide/sidebar-and-tabs.md) | ✅ | ✅ | ✅ | ✅ | |
| [Favorites grid shared across spaces](guide/sidebar-and-tabs.md) | ✅ max 12 | ? | ✅ Essentials | ✅ | Max 12, as in Arc |
| [Pinned tabs per space](guide/sidebar-and-tabs.md) | ✅ | ✅ | ✅ | ✅ | |
| Pinned tabs reset to their original URL ("/" marker, click favicon) | ✅ | ✅ | ? | ✅ | |
| [Links from pinned tabs to other sites open in a preview](guide/peek-split-little-arc.md) | ✅ | ? | ✅ | ✅ | Opens in Peek |
| [Today tabs that auto-archive](guide/sidebar-and-tabs.md) | ✅ 12h default, can't disable | ? | ❌ requested | ✅ | den: 24 h by default, configurable, can be turned off |
| [Searchable archive of closed tabs](guide/sidebar-and-tabs.md) | ✅ | ? | ❌ | ✅ | The Library (⌘Y / ⇧⌘L) |
| [Folders, nested](guide/sidebar-and-tabs.md) | ✅ | tab groups | ✅ | ✅ | |
| [Folder hover preview](guide/hover-previews.md) | ✅ | ✅ group flyout | ? | 🟡 | ✅ hover card listing the folder's tabs. Being built: a collapsed folder keeps its active tab visible, and a hover flyout with "+ New Tab" |
| Live folders (GitHub PRs, RSS) | ✅ GitHub only | ✅ many services | ✅ GitHub + RSS | ⏳ | Fed by den's connections: unread pip, "N ✓" popover, PR stacks |
| ⌘-click a link groups it with its source tab | ? | ✅ | ? | ⏳ | Dia-style: both go into a Today folder named after the site; dissolves at one tab |
| Folder shortcuts: ⌃⌘N folder from selection, ⌥⌘T new tab in folder | ? | ✅ | ? | ⏳ | |
| [Rename tabs](guide/sidebar-and-tabs.md) | ✅ | ? | ✅ | ✅ | Tabs ▸ Rename Tab |
| Emoji tab icons | ✅ | ? | ✅ | — | Spaces take emoji icons; tabs don't |
| [Duplicate tab](guide/sidebar-and-tabs.md) | ✅ | ? | ? | ✅ | Whether back/forward history is copied: (unverified) |
| Multi-select tabs | ✅ | ? | ? | ⏳ | Needed for "folder from selection" |
| [Undo sidebar actions, reopen closed tab](guide/sidebar-and-tabs.md) | ✅ | ? | ✅ | ✅ | ⌃Z undo, ⇧⌘T reopen |
| [Clear today tabs in one action](guide/sidebar-and-tabs.md) | ✅ Cmd-Shift-K | ? | ✅ | ✅ | ⇧⌘K |
| [Tab suspension / unloading](guide/performance.md) | ? | ✅ sleeps idle tabs | ✅ memory-pressure only | 🟡 | ✅ two levels: WebKit's suspend when a tab is hidden, then a full discard after 5 min idle (configurable). Tabs playing audio, on screen, or holding unsaved input are kept. No memory-pressure trigger. ⏳ near-zero cost per discarded tab (80 KB measured, 8 KB budget) |
| [Recent-tab switcher (Ctrl-Tab)](guide/shortcuts.md) | ✅ | ✅ | ✅ | ✅ | |
| [Tab mute from the sidebar speaker](guide/media.md) | ✅ | ✅ | ? | ✅ | Speaker on tabs and favorites; Mute Tab in the tab menu |
| Icon and title fallbacks, never "data:" or blank | ? | ? | ? | 🟡 | ✅ letter/globe favicons; 🟡 title fallbacks |
| Faster tab close (show the next tab first) | ? | ✅ | ? | ⏳ | |
| Tab menu shows shortcuts and ⌥ alternates | ? | ✅ | ? | ⏳ | |
| Bookmarks | ❌ pinned tabs instead | ✅ | ✅ | **Skip** | Pinned tabs and folders replace them |

## Spaces and profiles

| Feature | Arc | Dia | Zen | den | Notes |
|---|---|---|---|---|---|
| [Spaces](guide/spaces-and-themes.md) | ✅ | ➖ became profiles | ✅ | ✅ | |
| [Space menu: rename, icon, theme, profile, duplicate, move, delete](guide/spaces-and-themes.md) | ✅ | ? | ✅ | ✅ | Double-click to rename; emoji icons; drag to reorder in the footer |
| [Theme per space: gradient up to 3 colors, grain](guide/spaces-and-themes.md) | ✅ | colors only | ✅ | ✅ | |
| [Swipe between spaces with animation](guide/spaces-and-themes.md) | ✅ | ✅ | ✅ | ✅ | |
| [Profile per space (separate logins, cookies)](guide/spaces-and-themes.md) | ✅ | ✅ | ❌ most-requested | 🟡 | ✅ separate data store per profile, chosen in the space menu. ⏳ profile management UI |
| Containers inside one profile | ❌ | ❌ | ✅ | **Skip** | Profile per space covers it |
| Link routing rules (URL → space) | ✅ Air Traffic Control | ? | ✅ Space Routing | ⏳ | |
| Tabs shared across windows (one tab, many windows) | ✅ | ? | ✅ Window Sync | — | Zen's rollout lost tabs |

## Navigation and command bar

| Feature | Arc | Dia | Zen | den | Notes |
|---|---|---|---|---|---|
| [Command bar (tabs, history, search, actions)](guide/command-bar.md) | ✅ Cmd-T | ➖ Arc's version dropped; has AI command bar | ✅ | ✅ | Every action is a registered command |
| [Command bar as a launcher: commands, destinations, single settings](guide/command-bar.md) | ? | ? | ? | ✅ | Ranked above web search |
| [Edit URL in command bar (Cmd-L)](guide/command-bar.md) | ✅ | ? | ✅ | ✅ | |
| [Site search keywords (`yt query`)](guide/command-bar.md) | ✅ | ? | ✅ | ✅ | Keyword, then Tab; add your own in `[search.keywords]` in `config.toml` |
| "new doc / notion / linear…" creation commands | ? | ✅ | ? | ⏳ | |
| [Remappable shortcuts](guide/shortcuts.md) | ✅ | ✅ | ✅ | ✅ | `[shortcuts]` in `config.toml`; one key registry, checked by `ShortcutTests` against [shortcuts.md](shortcuts.md) |
| Shortcuts shown wherever an action appears | ? | ✅ | ? | 🟡 | ✅ menu bar, command bar rows. ⏳ context menus, button tooltips, Settings rows |
| [Copy URL (Cmd-Shift-C)](guide/page-tools.md) | ✅ | ? | ? | 🟡 | ✅ copies the URL. ⏳ tracking parameters stripped |
| [Copy URL as Markdown](guide/page-tools.md) | ✅ | ? | ✅ | ✅ | ⌥⇧⌘C |
| Paste clipboard as new tab (Paste and Go) | ✅ | ✅ | ? | ⏳ | |
| Long-press back/forward for history | ✅ | ? | ✅ | — | |

## Split view and previews

| Feature | Arc | Dia | Zen | den | Notes |
|---|---|---|---|---|---|
| [Split view up to 4 panes](guide/peek-split-little-arc.md) | ✅ | ✅ | ✅ | ✅ | |
| [Grid layout](guide/peek-split-little-arc.md) | ❌ | ? | ✅ | ✅ | |
| [Drag tab into page to split](guide/peek-split-little-arc.md) | ✅ | ? | ✅ | ✅ | Also onto a tab row or a split row |
| [Split saved as its own sidebar item](guide/peek-split-little-arc.md) | ✅ | ? | ✅ | ✅ | |
| Split modifiers: ⇧⌥-click a link → right split; ⌥-click + → split | ? | ✅ | ? | ⏳ | |
| Resize split panes by dragging | ? | ? | ? | ⏳ | |
| [Link preview overlay (Peek / Glance)](guide/peek-split-little-arc.md) | ✅ | ? | ✅ | ✅ | ⇧- or ⌥-click a link; Open as Tab, Open in Split View |
| "Open Link in Peek" in the link menu | ✅ | ? | ✅ | ⏳ | |
| [Quick floating window for links from other apps (Little Arc)](guide/peek-split-little-arc.md) | ✅ | ? | ❌ | ✅ | **Off by default**: links from other apps open as a normal tab. Turn it on in Settings |
| [Hover cards for sidebar tabs, favorites, folders, splits](guide/hover-previews.md) | ✅ | ✅ | ? | ✅ | 450 ms, then instant; nothing fetched until hovered |
| [Hover previews of Gmail/Calendar/Slack/GitHub tabs](guide/hover-previews.md) | ✅ | ✅ | ❌ | 🟡 | ✅ GitHub, Google Calendar (Join), Gmail, Slack, a page snapshot for anything else. ⏳ Notion and more, with their connections |
| [PR peek: state, checks, conflicts, reviews, +/− lines, files](guide/hover-previews.md) | ➖ retired for Live Folders | ✅ on hover in Live Folders | ❌ | ✅ | Public repos with no sign-in; private repos through your github.com session |
| [Actions on hover cards](guide/hover-previews.md) | ✅ | ✅ | ? | 🟡 | ✅ card buttons (e.g. Join on a calendar card). ⏳ the card rebuilt to the [Dia spec](reference/dia-ui-spec.md), and an inline "Connect GitHub" button that fills the card in live |
| ⇧-hover link previews on any page | ✅ AI summary | ? | ? | ⏳ | den: an OpenGraph card from the target's `<head>`, no AI, cached, zero cost until a deliberate ⇧-hover. Open in Peek / Split / Copy Link. Plain hover as an option |
| Web panels in sidebar | ❌ | ❌ | ➖ removed | — | Research rated it "nice" if lazy and discardable ([gaps-chromium-browsers](research/gaps-chromium-browsers.md)); not on the ROADMAP |

## Customization

| Feature | Arc | Dia | Zen | den | Notes |
|---|---|---|---|---|---|
| Boosts: per-site colors, fonts, zap elements | ✅ | ➖ dropped | ✅ | 🟡 | ✅ [Zap and Remove Sticky Headers](guide/page-tools.md), remembered per site. ⏳ per-site colors and fonts |
| Boosts with custom CSS/JS | ✅ | ➖ | ? | ⏳ | Arc had a security hole here; sandbox it |
| UI mods / themes store | ❌ | ❌ | ✅ Zen Mods | ⏳ | CSS plus declared options |
| [Plugins that add features](guide/den-home.md) | ❌ | ❌ | ❌ | ✅ | den's core idea: features are plugins over a thin host |
| [Hot-swap plugins without restart](guide/den-home.md) | ❌ | ❌ | ❌ | ✅ | |
| [`~/.den`: plugins, themes, extensions, `config.toml`, applied live](guide/den-home.md) | ❌ | ❌ | ? | ✅ | |
| [Settings window (⌘,) with plugin sections](guide/command-bar.md) | ✅ | ✅ | ✅ | ✅ | Every setting is also reachable from the command bar |

## Media

| Feature | Arc | Dia | Zen | den | Notes |
|---|---|---|---|---|---|
| [Mini player when leaving a video tab](guide/media.md) | ✅ | ✅ | ? | ✅ | den's own player, on by default: frameless, on top, seek, volume/mute, ±10 s, speed, back to tab, resize/snap. Native PiP as the fallback |
| Mini player extras: keep-on-top toggle, tuck off-screen, hostname chip, Firefox's PiP keys, subtitles | ? | ✅ | ? | ⏳ | |
| [Audio controls in sidebar](guide/media.md) | ✅ | ✅ | ✅ | 🟡 | ✅ speaker and mute. ⏳ hover play/pause/skip for any tab playing audio |
| Calendar countdown, Join button, meeting reminder | ✅ | ✅ meeting groups | ❌ | 🟡 | ✅ Join on the calendar hover card. ⏳ reminder card and pinned-calendar countdown |
| Camera, mic and screen-share badges on tabs | ✅ | ✅ | ? | ⏳ | |

## Page tools

| Feature | Arc | Dia | Zen | den | Notes |
|---|---|---|---|---|---|
| [Reader mode with read-aloud, remembered per site](guide/page-tools.md) | ? | ? | ? | ✅ | ⌃⌘R. Readability.js loaded only when used, macOS speech |
| [On-device page translation](guide/page-tools.md) | ? | ? | ✅ from Firefox | ✅ | Apple's Translation framework |
| [Capture: region, element, visible or full page](guide/page-tools.md) | ✅ | ? | ? | ✅ | ⇧⌘2; copy or save |
| [Copy link to highlight (text fragments)](guide/page-tools.md) | ? | ? | ? | ✅ | |
| [Per-site zoom, remembered](guide/page-tools.md) | ? | ? | ? | ✅ | ⌘+ / ⌘- / ⌘0 |
| [Find in page, print, save as Web Archive](guide/page-tools.md) | ✅ | ✅ | ✅ | ✅ | ⌘F, ⌘P, ⇧⌘S |
| Native share menu and a QR code for the page | ✅ | ? | ? | ⏳ | |

## Connections, briefing, AI

| Feature | Arc | Dia | Zen | den | Notes |
|---|---|---|---|---|---|
| [Connections: Slack, GitHub](guide/connections-and-briefing.md) | ❌ | ✅ | ❌ | ✅ | Session-based: you sign in to the site inside den, and den reuses that session. No den account, no OAuth app, no den server. Multiple Slack workspaces |
| Auto-connect when you're already signed in | ❌ | ✅ | ❌ | ⏳ | A cookie-store observer, no polling, with a "GitHub connected · Undo" toast |
| Important Slack channels and GitHub repos | ❌ | ? | ❌ | ⏳ | Ranked higher in the briefing and feed |
| More connections: Gmail, Calendar, Notion, Linear, Jira, … | ❌ | ✅ | ❌ | ⏳ | Each one a plugin, in that order |
| [No tokens stored](guide/connections-and-briefing.md) | — | ❌ on Dia's servers | — | ✅ | Session tokens are read on demand and kept in memory only; nothing is written to disk or the Keychain |
| Official OAuth sign-in option | — | ? | — | ⏳ | Optional, for people who don't want session reuse |
| [Daily briefing / todo list](guide/connections-and-briefing.md) | ❌ | ✅ $100/mo | ❌ | ✅ | 8:00 by default; todos link to their source and can be checked off |
| [Personalized feed across connections](guide/connections-and-briefing.md) | ❌ | ? | ❌ | ✅ | |
| [AI summaries on device](guide/connections-and-briefing.md) | ❌ | ❌ cloud | ❌ | ✅ | Apple Foundation Models, for the briefing and feed only. Works without it (plain counts and lists) |
| AI chat about pages | ➖ removed | ✅ | ❌ | **Plugin** | No built-in chat or agent. ⏳ a plugin API rich enough for someone to build one |
| Skills / saved prompts | ❌ | ✅ | ❌ | **Plugin** | |
| AI tab tidying and renaming | ✅ | ✅ | ❌ | ⏳ (unverified) | On the ROADMAP (on-device, lazy), but the AI principle limits the model to the briefing and feed: decision needed |
| Notes, whiteboards (Easels) | ➖ / ✅ | ➖ | ❌ | **Skip** | |

## Extensions and blocking

| Feature | Arc | Dia | Zen | den | Notes |
|---|---|---|---|---|---|
| [Chrome extensions](guide/extensions.md) | ✅ | ? | ❌ | ✅ | Via Apple's `WKWebExtension` (MV2 and MV3) |
| [Firefox extensions](guide/extensions.md) | ❌ | ❌ | ✅ | ✅ | Via Apple's `WKWebExtension` |
| [Install from Chrome Web Store / Firefox add-ons](guide/extensions.md) | ✅ Chrome | ? | ✅ AMO | ✅ | "Add to den"; daily update checks. Chrome store terms need a legal read |
| Full uBlock Origin | ? | ? | ✅ | **Skip** | Not possible on WebKit (no blocking `webRequest`) |
| [uBlock Origin Lite](guide/extensions.md) | ? | ? | ? | ✅ | |
| Built-in ad and tracker blocker | ? | ✅ | ? | ⏳ | Filter lists compiled to content rules |

## Privacy and security

| Feature | Arc | Dia | Zen | den | Notes |
|---|---|---|---|---|---|
| [Dark mode for every website](guide/privacy-and-passwords.md) | ? | ? | ? | ✅ | Native dark sites left alone; per-site Follow / Always Dark / Always Light / Off |
| Shields: one per-site panel from the URL pill | ? | ? | ? | ⏳ | Blocker, permissions, zoom, autoplay, pop-ups, "forget this site" ([gaps-shortlist](research/gaps-shortlist.md) A) |
| Strip tracking parameters, skip bounce redirects, cookie banners, HTTPS-first | ? | ? | ? | ⏳ | Needs lists with usable licences |
| Per-site permissions | ✅ | ✅ | ✅ | 🟡 | ✅ camera/mic answers remembered per site until quit. ⏳ a UI to review them |
| [Google sign-in](guide/privacy-and-passwords.md) | ✅ | ✅ | ✅ | ✅ | Uses Safari's user agent |

## Passwords, sync, import

| Feature | Arc | Dia | Zen | den | Notes |
|---|---|---|---|---|---|
| Password manager extensions (1Password, Bitwarden) | ✅ | ? | ✅ | ⏳ | Needs the native messaging bridge |
| [Built-in password vault](guide/privacy-and-passwords.md) | ✅ Chromium | ? | ✅ Firefox | ✅ | den's own vault in the Keychain, filled after Touch ID. No API reads iCloud Keychain |
| [Passkeys for all sites](guide/privacy-and-passwords.md) | ✅ | ? | ? | 🟡 | ✅ researched ([notes](research/passkeys.md)). ⏳ Apple's browser entitlement and a real signing identity |
| Sync spaces and tabs across Macs | ✅ | ✅ | ✅ | ⏳ | Via iCloud/CloudKit, no den server |
| Import from Arc (spaces, pinned tabs) | — | ➖ dropped | ? | ⏳ | Offered as a quiet card, never a gate |
| Import from Chrome, Safari, Firefox, Zen, Dia | ✅ | ? | ? | ⏳ | |
| Share a space/folder/split as a link | ✅ | ? | ✅ | **Skip** | Needs a server |
| Web apps (PWA), and web apps in the Dock | ❌ | ? | ❌ requested | ⏳ | |

## Browser basics

| Feature | den | Notes |
|---|---|---|
| [Complete macOS menu bar; every shortcut is a menu item](guide/shortcuts.md) | ✅ | |
| [Session restore](guide/sidebar-and-tabs.md) | 🟡 | ✅ spaces, tabs and selection survive quit and updates. ⏳ crash recovery, a "Page crashed · Reload" view |
| [Error pages with Try Again](guide/page-tools.md) | ✅ | Offline, host not found, timeout, can't connect, not private |
| [Page prompts](guide/privacy-and-passwords.md) | ✅ | Camera/mic, HTTP sign-in, file panels, JS alert/confirm/prompt. ⏳ location, notifications |
| [Default browser handling](guide/getting-started.md) | ✅ | Settings, menu bar, command bar banner, "Try for a week" |
| [Web Inspector, inspect element, console, view source](guide/shortcuts.md) | ✅ | |
| Downloads in the sidebar and Library | ⏳ | |
| No white flash on tab switch or load | ⏳ | |
| Protection against pages opening endless alerts | ⏳ | |
| Web push notifications | ⏳ | Not supported in `WKWebView`; a workaround or Skip is still to be decided |
| [Auto-update (OTA)](guide/updates.md) | ✅ | Sparkle for the app, signed hot-swapped plugins; `stable` / `prerelease` / `follow-main` channels; relaunches only when you won't notice |
| Onboarding: optional tour card, one-time tips | ⏳ | Zero-friction: never a blocking welcome or wizard ([spec](guide/_in-app-tips.md)) |
| No row tooltips | ✅ | Hover cards show that information instead |

## Platform

| Feature | Arc | Dia | Zen | den | Notes |
|---|---|---|---|---|---|
| Engine | Chromium | Chromium | Firefox (Gecko) | WebKit (system) | |
| macOS | ✅ | ✅ | ✅ | ✅ only | den: macOS 26 Tahoe or later |
| Windows / Linux | Windows | Windows beta | ✅ both | **Skip** | |
| Open source | ❌ | ❌ | ✅ MPL-2.0 | ✅ MIT | |
| Actively developed | ❌ maintenance since May 2025 | ✅ | ✅ | ✅ | |

## Look and feel (Arc details to copy)

| Detail | den | Notes |
|---|---|---|
| [Whole window wears the space's theme; grainy gradient sidebar](guide/spaces-and-themes.md) | ✅ | Every surface follows the theme with legible contrast |
| [Space switch slides the whole sidebar, following the trackpad](guide/spaces-and-themes.md) | ✅ | |
| Haptic feedback when reordering tabs and in the theme picker | ✅ | |
| [Theme picker that makes ugly themes hard (limited colors, intensity, grain)](guide/spaces-and-themes.md) | ✅ | |
| Toasts tinted to the theme | ✅ | |
| Split drop indicators tinted to the theme | ✅ | |
| Animations for clearing tabs, dropping tabs, fullscreen, PiP | (unverified) | |
| [Command bar always centered; shortcut again dismisses it](guide/command-bar.md) | ✅ | |
| [Media follows you: video in the mini player bottom-right, audio in sidebar](guide/media.md) | ✅ | |
| Optional UI sounds | — | |
| Exact sizes (sidebar width, corner radius, timings) | 🟡 | From [arc-ui-spec](reference/arc-ui-spec.md); values still marked "estimate" in `Tokens.swift` need measuring on real Arc |
