# Roadmap

Everything we want in den, as checklists. Research behind each section is in [`docs/research/`](docs/research/).

## Principles

Every item below has to respect these. If a feature can't, it gets redesigned or dropped.

- **Plugin-based.** The core is a small host. Features — including built-in ones like the sidebar, split view, and connections — are plugins.
- **Hot-swappable.** Any plugin can be loaded, unloaded, updated, or replaced at runtime without restarting the browser or losing tabs.
- **Lazy by default.** Nothing loads until it's needed: plugins, connections, web content, even tab processes.
- **Minimal resources.** Idle tabs cost as close to nothing as possible. Memory and energy use are tracked like bugs.

## Core

- [ ] Plugin host modeled on [cordis](https://github.com/cordiverse/cordis): shared context, services with `inject`, automatic cleanup of everything a plugin registers ([notes](docs/research/cordis-and-agent-harness.md))
- [ ] Core features as swappable services: tabs, history, sidebar, connections
- [ ] Typed UI slots plugins can fill: sidebar panels, toolbar items, command bar actions
- [ ] Plugin API versioning and permissions
- [ ] Lazy loading for plugins and services
- [ ] Settings system, per plugin, editable at runtime
- [ ] Command registry (every action is a command; shortcuts and command bar call into it)
- [ ] Event bus between plugins
- [ ] Crash isolation: a plugin failing doesn't take the browser down

## Web engine (WebKit)

Details and sources: [Apple platform notes](docs/research/apple-platform.md).

- [ ] Tab model on `WKWebView`
- [ ] Profiles with isolated data stores (`WKWebsiteDataStore(forIdentifier:)`, macOS 14+)
- [ ] Tab suspension, two levels: WebKit's built-in suspend when a tab leaves the window, then full discard (save state + snapshot, destroy the web view, recreate on focus)
- [ ] Session restore and crash recovery, using WebKit's page state save/restore
- [ ] Apple Pay exception: skip den's injected scripts on checkout pages, since any injection disables Apple Pay
- [ ] Web push notifications: not supported in `WKWebView`; decide on a workaround or skip
- [ ] Downloads
- [ ] Find in page
- [ ] Printing and PDF viewing
- [ ] Permissions: camera, mic, location, notifications
- [ ] Picture-in-picture and media controls
- [ ] Web Inspector
- [ ] Default browser handling

## UI (Arc-style)

Details and sources: [Arc notes](docs/research/arc.md), [Zen notes](docs/research/zen.md).

- [ ] Vertical sidebar tabs, with a right-side option (Arc never shipped one)
- [ ] Favorites grid, shared across spaces
- [ ] Pinned tabs per space, which reset to their original URL
- [ ] Today tabs with auto-archive (Arc default: 12h; configurable)
- [ ] Archive of closed tabs, searchable
- [ ] Folders, including live folders fed by GitHub or RSS (from Zen)
- [ ] Spaces with their own colors/themes, swipe to switch
- [ ] A profile per space (Zen's most-requested missing feature)
- [ ] Split view, including drag-to-split
- [ ] Command bar
- [ ] Peek / link preview
- [ ] Little Arc-style quick window
- [ ] Link routing rules (Arc's Air Traffic Control)
- [ ] Boosts: per-site CSS/JS customization
- [ ] Compact mode / hide sidebar, chrome-less content area
- [ ] Theme and UI mods (Zen Mods style: CSS plus declared options)
- [ ] Web apps (PWA) support
- [ ] Keyboard shortcuts, fully remappable, Arc defaults

## Extensions

Details and sources: [extension notes](docs/research/extensions-on-webkit.md).

- [ ] Chrome and Firefox extensions via Apple's `WKWebExtension` API (Manifest v2 and v3, `chrome.*` and `browser.*`)
- [ ] One-click install from Chrome Web Store / addons.mozilla.org, with update checks (Chrome Web Store terms: needs a legal read)
- [ ] Fill in APIs Apple leaves out where feasible: `bookmarks`, `sidePanel`, `downloads`, `history`, `identity`
- [ ] Native messaging bridge (password managers)
- [ ] Built-in ad/tracker blocker: filter lists compiled to content rule lists (e.g. `adblock-rust` or AdGuard's `SafariConverterLib`), plus CSS hiding and scriptlets
- [ ] uBlock Origin Lite works (full uBlock Origin can't, since WebKit has no blocking `webRequest`)
- [x] Minimum macOS: 26 Tahoe. No support for older versions; newer-OS APIs (macOS 27) used when available

## Connections and daily briefing (Dia-style)

Details and sources: [Dia notes](docs/research/dia.md).

- [ ] Connection plugins: Slack, GitHub
- [ ] More connections as plugins (Gmail, Calendar, Linear, Notion, Jira, …)
- [ ] Tokens stored in the macOS Keychain; connections run locally (Dia keeps them on its servers)
- [ ] Daily briefing from all connections: Slack mentions and unread DMs, PRs waiting for your review, today's calendar, emails awaiting a reply, summarized into a todo list
- [ ] Briefing todos can be checked off and link back to their source
- [ ] Personalized feed: one stream across all connections, ranked by what matters to you
- [ ] Connections load and sync only when used

## AI

AI in den is Apple's on-device model, used only for the daily briefing and the personalized feed. No chat, no agent, nothing sent to a cloud model. Anything else is left to plugins.

- [ ] Summarize and prioritize connection data with Apple's Foundation Models framework, on device
- [ ] Fit the model's small context (4,096 tokens on macOS 26): summarize each source separately, then combine the summaries
- [ ] Model loads only while generating a briefing or ranking the feed, then is released
- [ ] Model output is text and todos only: no tools, cannot click, send or open anything
- [ ] Every summary item links to its source message, PR or event
- [ ] Works without the model (plain lists) on Macs without Apple Intelligence
- [ ] Plugin API is rich enough for someone else to build a chat/AI plugin, gated by user-granted permissions

## Apple integration

- [ ] Passkeys for all sites: apply early for Apple's browser passkey entitlement (reviewed by Apple)
- [ ] Passwords: no API reads iCloud Keychain / the Passwords app, so rely on password manager extensions (1Password, Bitwarden) and decide whether den ships its own vault
- [ ] "Save password?" prompt via the form-submit callback (macOS 27)
- [ ] Native look: vibrancy, SF Symbols, system accent colors
- [ ] Shortcuts / App Intents / Spotlight
- [ ] Handoff
- [ ] Sync via iCloud / CloudKit (no den server; Talos browser does this)

## Privacy and security

- [ ] Tracker blocking
- [ ] Per-site permissions UI
- [ ] Sandboxed plugins

## Performance

- [ ] Memory and energy budgets per feature
- [ ] Benchmarks against Safari, Arc, Dia, Zen (measured, published). WebKit alone isn't proof of efficiency: the one careful independent test found Chrome used less battery than Safari
- [ ] Startup time budget

## Import

- [ ] Import from Arc (spaces, pinned tabs)
- [ ] Import from Chrome, Safari, Firefox, Zen, Dia

## Release and project

- [x] Public repo, MIT license
- [ ] App skeleton that builds
- [ ] Signed and notarized `.dmg` on GitHub Releases
- [ ] Auto-update
- [ ] CI builds on every PR
- [ ] Contributing guide
- [ ] Plugin author docs
