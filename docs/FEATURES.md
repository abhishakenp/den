# Feature comparison

What Arc, Dia and Zen do, and what den is going for. Built from the notes in [`research/`](research/); see them for sources.

**Legend**

| Mark | Meaning |
|---|---|
| ✅ | Has it |
| ❌ | Doesn't have it |
| ➖ | Had it, removed or dropped |
| ? | Not confirmed by research |
| **v1** | den: in the first usable release |
| **Later** | den: planned after v1 |
| **Plugin** | den: not built in; left to an optional plugin |
| **Skip** | den: not planned |

## Window and layout

| Feature | Arc | Dia | Zen | den | Notes |
|---|---|---|---|---|---|
| Sidebar-first layout, no top toolbar | ✅ | ✅ optional | ✅ | **v1** | Arc's layout is the base |
| Page as an inset card with rounded corners | ✅ | ? | ? | **v1** | Radius and inset need measuring on real Arc |
| Sidebar on the right | ❌ rejected | ? | ✅ | **v1** | Arc prototyped and declined it |
| Resizable sidebar, double-click edge to reset | ✅ | ? | ? | **v1** | |
| Hide sidebar, reveal on screen-edge hover | ✅ Cmd-S | ✅ | ✅ compact mode | **v1** | |
| Optional classic top toolbar with full URL | ✅ Cmd-Shift-D | ✅ | ✅ | **Later** | |
| Simplified URL (domain only) in sidebar | ✅ | ? | ? | **v1** | |
| Link-hover status pill that moves away from cursor | ✅ | ? | ? | **v1** | |
| Drag window from empty sidebar / top strip of page | ✅ | ? | ? | **v1** | |
| Horizontal tab strip | ❌ | ✅ | ❌ rejected | **Skip** | |
| Developer Mode (full URL, dev tools, colored outline, auto on localhost) | ✅ | ? | ❌ requested | **Later** | |

## Tabs

| Feature | Arc | Dia | Zen | den | Notes |
|---|---|---|---|---|---|
| Vertical tabs | ✅ | ✅ | ✅ | **v1** | |
| Favorites grid shared across spaces | ✅ max 12 | ? | ✅ Essentials | **v1** | |
| Pinned tabs per space | ✅ | ✅ | ✅ | **v1** | |
| Pinned tabs reset to their original URL ("/" marker, click favicon) | ✅ | ✅ | ? | **v1** | |
| Links from pinned tabs to other sites open in a preview | ✅ | ? | ✅ | **v1** | |
| Today tabs that auto-archive | ✅ 12h default, can't disable | ? | ❌ requested | **v1** | den: configurable, can be turned off |
| Searchable archive of closed tabs | ✅ | ? | ❌ | **v1** | |
| Folders, nested | ✅ | tab groups | ✅ | **v1** | |
| Folder hover preview | ✅ | ? | ? | **Later** | |
| Live folders (GitHub PRs, RSS) | ✅ GitHub only | ✅ many services | ✅ GitHub + RSS | **v1** | Fed by den's connections |
| Rename tabs, emoji icons | ✅ | ? | ✅ | **v1** | |
| Duplicate tab with history | ✅ | ? | ? | **v1** | |
| Multi-select tabs | ✅ | ? | ? | **v1** | |
| Undo sidebar actions (Cmd-Z), reopen closed tab | ✅ | ? | ✅ | **v1** | |
| Clear today tabs in one action | ✅ Cmd-Shift-K | ? | ✅ | **v1** | |
| Tab suspension / unloading | ? | ✅ sleeps idle tabs | ✅ memory-pressure only | **v1** | den: time + memory, two levels |
| Recent-tab switcher (Ctrl-Tab) | ✅ | ? | ✅ | **v1** | |
| Bookmarks | ❌ pinned tabs instead | ✅ | ✅ | **Skip** | Pinned tabs and folders replace them |

## Spaces and profiles

| Feature | Arc | Dia | Zen | den | Notes |
|---|---|---|---|---|---|
| Spaces | ✅ | ➖ became profiles | ✅ | **v1** | |
| Theme per space: gradient up to 3 colors, grain | ✅ | colors only | ✅ | **v1** | |
| Swipe between spaces with animation | ✅ | ✅ | ✅ | **v1** | |
| Profile per space (separate logins, cookies) | ✅ | ✅ | ❌ most-requested | **v1** | |
| Containers inside one profile | ❌ | ❌ | ✅ | **Skip** | Profile per space covers it |
| Link routing rules (URL → space) | ✅ Air Traffic Control | ? | ✅ Space Routing | **v1** | |
| Tabs shared across windows (one tab, many windows) | ✅ | ? | ✅ Window Sync | **Later** | Zen's rollout lost tabs; ship opt-in |
| Incognito / private window | ✅ | ✅ | ✅ | **v1** | |

## Navigation and command bar

| Feature | Arc | Dia | Zen | den | Notes |
|---|---|---|---|---|---|
| Command bar (tabs, history, search, actions) | ✅ Cmd-T | ➖ Arc's version dropped; has AI command bar | ✅ | **v1** | Every action is a registered command |
| Edit URL in command bar (Cmd-L) | ✅ | ? | ✅ | **v1** | |
| Site search keywords (`yt query`) | ✅ | ? | ✅ | **v1** | |
| Remappable shortcuts | ✅ | ✅ | ✅ | **v1** | One registry; docs generated from it |
| Copy clean URL (tracking stripped) | ✅ Cmd-Shift-C | ? | ? | **v1** | |
| Copy URL as Markdown | ✅ | ? | ✅ | **v1** | |
| Paste clipboard as new tab | ✅ | ? | ? | **v1** | |
| Long-press back/forward for history | ✅ | ? | ✅ | **v1** | |

## Split view and previews

| Feature | Arc | Dia | Zen | den | Notes |
|---|---|---|---|---|---|
| Split view up to 4 panes | ✅ | ✅ | ✅ | **v1** | |
| Grid layout | ❌ | ? | ✅ | **v1** | |
| Drag tab into page to split | ✅ | ? | ✅ | **v1** | |
| Split saved as its own sidebar item | ✅ | ? | ✅ | **v1** | |
| Link preview overlay (Peek / Glance) | ✅ | ? | ✅ | **v1** | |
| Quick floating window for links from other apps (Little Arc) | ✅ | ? | ❌ | **v1** | |
| Hover previews of Gmail/Calendar/Notion tabs | ✅ | ? | ❌ | **Later** | Fed by connections |
| Web panels in sidebar | ❌ | ❌ | ➖ removed | **Later** | Zen users miss them |

## Customization

| Feature | Arc | Dia | Zen | den | Notes |
|---|---|---|---|---|---|
| Boosts: per-site colors, fonts, zap elements | ✅ | ➖ dropped | ✅ | **Later** | Arc had a security hole here; sandbox it |
| Boosts with custom CSS/JS | ✅ | ➖ | ? | **Later** | |
| UI mods / themes store | ❌ | ❌ | ✅ Zen Mods | **Later** | Typed options on theme tokens, not raw CSS |
| Plugins that add features | ❌ | ❌ | ❌ | **v1** | den's core idea |
| Hot-swap plugins without restart | ❌ | ❌ | ❌ | **v1** | |

## Media

| Feature | Arc | Dia | Zen | den | Notes |
|---|---|---|---|---|---|
| Auto picture-in-picture when leaving a video tab | ✅ | ✅ | ? | **v1** | |
| Audio controls in sidebar | ✅ | ? | ✅ | **v1** | |
| Calendar countdown and Join button in sidebar | ✅ | ✅ meeting groups | ❌ | **Later** | Fed by calendar connection |

## Connections, briefing, AI

| Feature | Arc | Dia | Zen | den | Notes |
|---|---|---|---|---|---|
| Connections: Slack, GitHub | ❌ | ✅ | ❌ | **v1** | |
| More connections: Gmail, Calendar, Notion, Linear, Jira, … | ❌ | ✅ | ❌ | **Later** | Each one a plugin |
| Tokens kept on your Mac (Keychain) | — | ❌ on Dia's servers | — | **v1** | |
| Daily briefing / todo list | ❌ | ✅ $100/mo | ❌ | **v1** | |
| Personalized feed across connections | ❌ | ? | ❌ | **v1** | |
| AI summaries on device | ❌ | ❌ cloud | ❌ | **v1** | Apple Foundation Models |
| AI chat about pages | ➖ removed | ✅ | ❌ | **Plugin** | |
| Skills / saved prompts | ❌ | ✅ | ❌ | **Plugin** | |
| AI tab tidying, renaming, link previews | ✅ | ✅ | ❌ | **Skip** | |
| Notes, whiteboards (Easels) | ➖ / ✅ | ➖ | ❌ | **Skip** | |

## Extensions and blocking

| Feature | Arc | Dia | Zen | den | Notes |
|---|---|---|---|---|---|
| Chrome extensions | ✅ | ? | ❌ | **v1** | Via Apple's `WKWebExtension` |
| Firefox extensions | ❌ | ❌ | ✅ | **v1** | Via Apple's `WKWebExtension` |
| Install from Chrome Web Store / Firefox add-ons | ✅ Chrome | ? | ✅ AMO | **v1** | Chrome store terms need a legal read |
| Full uBlock Origin | ? | ? | ✅ | **Skip** | Not possible on WebKit |
| uBlock Origin Lite | ? | ? | ? | **v1** | |
| Built-in ad and tracker blocker | ? | ✅ | ? | **v1** | |

## Passwords, sync, import

| Feature | Arc | Dia | Zen | den | Notes |
|---|---|---|---|---|---|
| Password manager extensions (1Password, Bitwarden) | ✅ | ? | ✅ | **v1** | |
| Built-in password vault | ✅ Chromium | ? | ✅ Firefox | **Later** | No API reads iCloud Keychain |
| Passkeys for all sites | ✅ | ? | ? | **v1** | Needs Apple's browser entitlement; apply early |
| Sync spaces and tabs across Macs | ✅ | ✅ | ✅ | **Later** | Via iCloud/CloudKit, no den server |
| Import from Arc (spaces, pinned tabs) | — | ➖ dropped | ? | **v1** | |
| Import from Chrome, Safari, Firefox, Zen, Dia | ✅ | ? | ? | **Later** | |
| Share a space/folder/split as a link | ✅ | ? | ✅ | **Skip** | Needs a server |
| Web apps (PWA) | ❌ | ? | ❌ requested | **Later** | |

## Platform

| Feature | Arc | Dia | Zen | den | Notes |
|---|---|---|---|---|---|
| Engine | Chromium | Chromium | Firefox (Gecko) | WebKit (system) | |
| macOS | ✅ | ✅ | ✅ | ✅ only | den: macOS 26 Tahoe or later |
| Windows / Linux | Windows | Windows beta | ✅ both | **Skip** | |
| Open source | ❌ | ❌ | ✅ MPL-2.0 | ✅ MIT | |
| Actively developed | ❌ maintenance since May 2025 | ✅ | ✅ | ✅ | |
| Web push notifications | ? | ? | ? | ? | Not supported in `WKWebView` |

## Look and feel (Arc details to copy)

| Detail | den |
|---|---|
| Whole window wears the space's theme; grainy gradient sidebar | **v1** |
| Space switch slides the whole sidebar, following the trackpad | **v1** |
| Haptic feedback when reordering tabs and in the theme picker | **v1** |
| Theme picker that makes ugly themes hard (limited colors, intensity, grain) | **v1** |
| Toasts tinted to the theme | **v1** |
| Split drop indicators tinted to the theme | **v1** |
| Animations for clearing tabs, dropping tabs, fullscreen, PiP | **v1** |
| Command bar always centered; shortcut again dismisses it | **v1** |
| Media follows you: video PiP bottom-right, audio in sidebar | **v1** |
| Optional UI sounds | **Later** |
| Exact sizes (sidebar width, corner radius, timings) | Measure on real Arc before building |
