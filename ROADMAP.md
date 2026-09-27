# Roadmap

Everything we want in den, as checklists. Items marked _(research)_ are still waiting on notes in [`docs/research/`](docs/research/).

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

- [ ] Tab model on `WKWebView`
- [ ] Profiles with isolated data stores _(research: OS version)_
- [ ] Tab suspension: unload idle tabs, keep snapshot, restore on focus
- [ ] Session restore and crash recovery
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

- [ ] Chrome extension support _(research: extensions-on-webkit)_
- [ ] Firefox extension support
- [ ] Install from Chrome Web Store / addons.mozilla.org
- [ ] Content blocking / ad blocking

## Connections and daily briefing (Dia-style)

Details and sources: [Dia notes](docs/research/dia.md).

- [ ] Connection plugins: Slack, GitHub
- [ ] More connections as plugins (Gmail, Calendar, Linear, Notion, Jira, …)
- [ ] Tokens stored in the macOS Keychain; connections run locally (Dia keeps them on its servers)
- [ ] Daily briefing built without AI, straight from the services: Slack mentions and unread DMs, PRs waiting for your review, today's calendar, emails awaiting a reply
- [ ] Briefing todos can be checked off and link back to their source
- [ ] Connections load and sync only when used

## AI

No built-in AI: no chat, no agent, no model loaded. AI features come from plugins people choose to install.

- [ ] Plugin API is rich enough for an AI plugin to be built by someone else (tab content, connections, sidebar panel), gated by user-granted permissions

## Apple integration

- [ ] Passkeys and password AutoFill _(research: what third-party browsers can access)_
- [ ] Native look: vibrancy, SF Symbols, system accent colors
- [ ] Shortcuts / App Intents / Spotlight
- [ ] Handoff
- [ ] Sync via iCloud (no den server)

## Privacy and security

- [ ] Tracker blocking
- [ ] Per-site permissions UI
- [ ] Sandboxed plugins

## Performance

- [ ] Memory and energy budgets per feature
- [ ] Benchmarks against Safari, Arc, Dia, Zen (measured, published)
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
