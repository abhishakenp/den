# Contributing to den

den is a native macOS browser whose features are all plugins; the small AppKit host only renders
their UI and gives them services ([docs/host-api.md](docs/host-api.md)). This file covers the
mechanics: build, test, bundle, remote CI, commit style, adding a plugin, and opening a PR.

Requirements: macOS 26, Xcode 26 (Swift 6.2+), and a Swift toolchain with the Embedded Swift
stdlib for the plugins (from swift.org or `swiftly`). SwiftPM fetches the `cordis-swift`
dependency itself.

## Build

```sh
swift build
```

Debug builds include the `Scenarios` package trait by default (the `--scenario` fixtures and
MockServices, `Package.swift`). To run the app you need the bundle, because the plugins are
compiled into it:

```sh
scripts/run.sh --demo   # bundle, then launch with demo spaces and tabs
```

## Test

```sh
scripts/test.sh         # any extra args are passed to swift test
```

`scripts/test.sh` builds the tests (`swift build --build-tests`), then runs `swift test
--skip-build --no-parallel` while holding a **machine-wide lock** (`/tmp/den-swift-test.lock`):
parallel agents may build freely, but only one test run executes at a time, because concurrent
runs starve each other's timing-sensitive tests. Others wait and print who holds the lock.
`DEN_TEST_PARALLEL=1` opts out of `--no-parallel`.

A run can fail but not hang: every test has a watchdog (`DEN_TEST_LIMIT` seconds, default 120;
`Tests/DenTestSupport/Watchdog.swift`), the whole run is killed after `DEN_TEST_RUN_LIMIT`
seconds (default 1800), and any WebContent process a test leaked is named, killed and fails the
run. The suites are `Tests/DenHostTests` (host services) and `Tests/PluginTests` (plugin cores
against a real `DenRuntime`, see `Tests/PluginTests/Harness.swift`).

## Bundle

```sh
scripts/bundle.sh       # builds build/den.app
```

A release build plus everything the app needs: the plugins compiled as Embedded Swift dylibs,
Info.plist, entitlements, and a signature. Signing uses `$DEN_SIGN_IDENTITY` if set (`-` for ad
hoc), else the stable `den Local Signing` identity from `scripts/make-signing-identity.sh` (run
it once so Keychain/TCC grants survive rebuilds), else ad hoc. The release app is built without
the `Scenarios` trait; `DEN_SCENARIOS=1 scripts/bundle.sh` keeps it (needed by
`scripts/snapshots.sh`).

## Remote build mode

Compiling den and running its suite loads a laptop for minutes (the suite opens real windows and
WebKit processes), so that work can run on GitHub Actions instead:

```sh
scripts/ci-check.sh     # add --snapshots to also render the UI snapshot scenarios
```

It force-pushes `HEAD` to the scratch branch `ci/<branch-or-worktree-name>`, waits for the CI
run on that exact commit, prints each job's result and any failed tests, downloads every
artifact to `.ci-artifacts/<run-id>/`, and exits non-zero unless the run is green. Only
committed changes are tested. What CI runs, runner limits, the perf lab and dev builds from CI
are documented in [docs/dev.md](docs/dev.md) — read it before relying on this path.

## Commit messages

From `git log`: `<area>: <what changed, as behavior>`, one line, sentence case, no trailing
period. Long is fine when it carries the "why"; extra clauses go after a semicolon or in
parentheses. Examples:

- `Split view: drag the gap between panes to resize them (double-click: equal); the split keeps its sizes`
- `Context menu: Copy Link copies the link without tracking parameters (shields.clean)`
- `Tests: PiP tests wait for the PiP window to finish opening and for the page's log line; each closes its PiP`
- `Docs: native messaging, password managers (Bitwarden, 1Password and what signing unblocks)`

Area prefixes match the touched feature (`tabs:`, `Extensions:`, `Tests:`, `Docs:`, `Launch:`);
write what the change does, not which file it edits.

## Add a plugin

Every feature is a plugin: an Embedded Swift dylib implementing cordis `CordisPlugin`, talking
to den only through `ctx.call` / `ctx.on` / `ctx.emit` / `ctx.provide`. The services a plugin
can call are in [docs/host-api.md](docs/host-api.md); the services other plugins provide
(`tabs`, `spaces`, `commands`, …) are in [docs/plugin-services.md](docs/plugin-services.md).

A bundled plugin lives in `Plugins/<id>/`:

1. **Entry point** — `<Id>Plugin.swift` with `struct Plugin: CordisPlugin`: a `Manifest(name:,
   version:, inject:, provides:)` and `apply(_:)` / `dispose()`. Smallest example:
   `Plugins/quit/QuitPlugin.swift`.
2. **Logic** — keep it in a `<Id>Core.swift` that takes a `PluginEnv` (`Plugins/Shared/`), and
   add that file to the `PluginCores` target's `sources` in `Package.swift`. `PluginCores`
   compiles plugin logic as ordinary Swift so `Tests/PluginTests` can drive it against the real
   host services; `scripts/bundle.sh` compiles the same files as Embedded Swift into
   `Contents/PlugIns/<id>.dylib`. (`Plugins/Shared/` is compiled into every plugin.)
3. **Permissions** — if the plugin needs a site session or network access, declare it in
   `Plugins/<id>/permissions.json` (e.g. `{"permissions": ["session:slack.com"]}`); the bundle
   ships it next to the dylib as `<id>.json`.
4. **Tests** — add a suite in `Tests/PluginTests/` using the `Harness` there (a real
   `DenRuntime` wired to a `PluginEnv`).

`scripts/bundle.sh` picks up every `Plugins/<id>/` automatically; no build-file registration is
needed beyond the `PluginCores` sources entry. To prototype without touching the repo, a plugin
can also live in `~/.den/plugins/` (den compiles and hot-swaps it) — see
[docs/den-home.md](docs/den-home.md) and `skills/den/SKILL.md`.

## Open a pull request

den is early; design feedback is the most useful contribution. Open an issue to discuss an idea
or challenge a decision before a large PR (see the README's Contributing section).

1. Fork, branch from `main`, and commit in the style above.
2. Push and open the PR against `main` (`gh pr create --base main`). CI (`.github/workflows/ci.yml`:
   `swift build`, `scripts/bundle.sh`, the full `scripts/test.sh` suite including UI tests) runs
   on every pull request to `main`, on a macOS runner with a logged-in GUI session.
3. If you don't want to wait for the PR run, `scripts/ci-check.sh` gives you the same CI on a
   scratch branch first (see [Remote build mode](#remote-build-mode)).
4. Keep the PR green and it can be merged.
