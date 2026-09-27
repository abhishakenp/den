# den

A fast, native macOS browser built on WebKit, where everything is a plugin.

<p>
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue"></a>
  <img alt="Status: design phase" src="https://img.shields.io/badge/status-design%20phase-orange">
  <img alt="Platform: macOS" src="https://img.shields.io/badge/platform-macOS-lightgrey">
</p>

<p>
  <a href="#principles">Principles</a> ·
  <a href="ROADMAP.md">Roadmap</a> ·
  <a href="docs/">Design docs</a> ·
  <a href="#contributing">Contributing</a>
</p>

> [!IMPORTANT]
> den is in the design phase. There is no code or build yet.

## What is den?

den is an open-source browser for macOS, built on the WebKit engine that ships with the system. It takes the interface people love from Arc, the connected workflow from Dia, and the openness of Zen, and puts them in a browser that stays light and starts instantly.

It exists because the browsers with the best interfaces are heavy, closed, or no longer actively developed, and the lightweight ones don't feel good to use.

## Principles

- **Plugin-based.** The core is a small host. Tabs, the sidebar, split view and connections are all plugins.
- **Hot-swappable.** Any plugin can be loaded, unloaded, updated or replaced while the browser runs, without losing your tabs.
- **Lazy by default.** Nothing loads until you need it: plugins, connections, web pages.
- **Minimal footprint.** Idle tabs should cost close to nothing. Memory and energy regressions are treated as bugs.

## Planned features

- Arc-style interface: vertical sidebar tabs, spaces, split view, command bar, link previews
- Connections to Slack, GitHub and more, with a daily briefing that turns them into a todo list, and a personalized feed
- On-device AI via Apple Intelligence, used only for the briefing and feed. No chat, nothing sent to the cloud
- Chrome and Firefox extension support
- Native macOS integration: passkeys, Keychain, Shortcuts, iCloud sync

## Roadmap and status

| # | Step | Status |
|---|------|--------|
| 1 | Research Arc, Dia, Zen, WebKit, extension support, plugin design | 🟡 In progress |
| 2 | Feature and architecture design | ❌ |
| 3 | Plugin host and app skeleton | ❌ |
| 4 | Core browsing: tabs, sidebar, spaces, profiles | ❌ |
| 5 | Extensions and content blocking | ❌ |
| 6 | Connections, daily briefing, personalized feed | ❌ |
| 7 | First public release | ❌ |

The full checklist is in [ROADMAP.md](ROADMAP.md).

## Design docs

Research notes and design documents live in [`docs/`](docs/).

## Contributing

den is early, and design feedback is the most useful contribution right now. Open an issue to discuss an idea or challenge a decision.

## License

[MIT](LICENSE)
