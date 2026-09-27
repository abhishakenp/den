# den docs

Which docs describe den as it is, and which are background reading.

## Authoritative

These are kept in step with the code on `main`. If one disagrees with the code, the doc is wrong: please [open an issue](https://github.com/abhishakenp/den/issues).

| Doc | What it answers |
|---|---|
| [User guide](guide/) | How to use what has shipped, one page per area |
| [ROADMAP.md](../ROADMAP.md) | What's shipped (✅), in progress (🟡) and queued (⏳), plus the principles every feature follows |
| [FEATURES.md](FEATURES.md) | den next to Arc, Dia and Zen, feature by feature, with den's status |
| [host-api.md](host-api.md) | The host services a plugin can call |
| [plugin-services.md](plugin-services.md) | The services den's own plugins provide |
| [shortcuts.md](shortcuts.md) | Every keyboard shortcut and menu item (checked by `ShortcutTests`) |
| [defaults.md](defaults.md) | Default settings and why they were chosen |
| [den-home.md](den-home.md) | `~/.den`: plugins, themes, extensions and `config.toml` |
| [updates.md](updates.md) | Update channels, signing and when den relaunches |
| [architecture/thin-host.md](architecture/thin-host.md) | The plan to move feature code out of the host |
| [perf/](perf/) | Budgets (`budgets.json`), measured baselines and memory notes. Numbers are observations from a stated date and machine |

## Historical research

[`research/`](research/) and [`reference/`](reference/) are dated snapshots written before most decisions were made. They record what other browsers do and what was found at the time; they are not specs. Each file starts with its date. Where the code has since proved a finding wrong, the correction is marked inline. For what den actually decided, read ROADMAP.md and FEATURES.md.

- `research/`: Arc, Dia, Zen and other browsers, Apple platform notes, extensions, passkeys, integrations, and the gap shortlists that fed the ROADMAP
- `reference/`: Arc and Dia UI specs, used as measurements for den's own UI

## Other

- [`guide/_in-app-tips.md`](guide/_in-app-tips.md): spec for in-app tips and the shortcuts-everywhere audit
- [`guide/_screenshots-todo.md`](guide/_screenshots-todo.md): screenshots still to capture (dark variants)
- [`screenshots/`](screenshots/): images used by the guide and README; use the `-dark` variants
