# ~/.den: plugins, themes and settings

den creates `~/.den` the first time it runs (after the first window is on screen) and watches it for as long as it runs. Anything you save there takes effect within about 100 ms, without a relaunch.

```
~/.den/
  plugins/      <id>.dylib, or a source folder <id>/*.swift
  themes/       <name>.json or <name>.toml theme presets
  extensions/   unpacked extension folders (each with a manifest.json), loaded as development extensions
  config.toml   settings, shortcuts, site-search keywords
  logs/         plugins.log (loads, reloads, builds), build-<id>.log, den.log (launches and quits), updater.log
  updates/      managed plugin updates (plugins/<id>.dylib + <id>.json) and the developer updater's state
  src/          the developer updater's clean checkout of main (not watched)
```

Updates, channels and `scripts/updater.sh` / `scripts/release.sh` are covered in [updates.md](updates.md).

Set `DEN_HOME` to use another folder. `--no-den-home` ignores it entirely (`scripts/snapshots.sh` and `scripts/measure-memory.sh` pass it, so your plugins don't change their results).

## Plugins

A plugin is an Embedded Swift dylib built with `cordis-build` (see [host-api.md](host-api.md)). For one plugin id, den loads the highest layer that has it:

| Priority | Where | Reloaded live |
|---|---|---|
| 5 (wins) | `--dev-plugins <dir>/<id>.dylib` | yes |
| 4 | `~/.den/plugins/<id>/*.swift`, compiled by den | yes |
| 3 | `~/.den/plugins/<id>.dylib` | yes |
| 2.5 | `~/.den/updates/plugins/<id>.dylib` (managed: plugin updates, gated by host API) | yes |
| 2 | `~/Library/Application Support/den/Plugins/<id>.dylib` (older location, still read) | no, only at launch |
| 1 | `den.app/Contents/PlugIns/<id>.dylib` (bundled) | no |

- Adding a file to a higher layer swaps the running plugin for it, and deleting it swaps back to the next layer down. Replacing a file reloads that plugin. The plugin's state lives in plugin storage, so tabs and spaces stay as they are.
- Write files atomically (build to a temporary name, then rename). `cordis-build` already does.
- If a plugin fails to load, a toast says why, and den falls back to the next layer.
- `~/Library/Application Support/den/Plugins` is still read at launch for compatibility. New plugins should go in `~/.den/plugins`.

### Source plugins

Put `.swift` files in `~/.den/plugins/<id>/`. den compiles the folder on a background queue with its bundled copy of `cordis-build` (`den.app/Contents/Resources/cordis`). It compiles `Plugins/Shared` in as well, so `PluginEnv` and the `Text` helpers are available. The result goes to `~/Library/Caches/io.github.abhishakenp.den/source-plugins/<id>.dylib` and loads straight away. Saving a file rebuilds it. A folder whose sources haven't changed since the last build is never rebuilt, so at launch the last build loads immediately.

```swift
// ~/.den/plugins/hello/Plugin.swift
struct Plugin: CordisPlugin {
  static let manifest = Manifest(name: "Hello", version: "0.1.0", inject: ["ui"])
  static func apply(_ ctx: Context) throws(PluginError) {
    _ = ctx.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": "Hello from ~/.den", "icon": "sf:hand.wave", "duration": 3000]])
  }
}
```

- The plugin id is the folder name (`[A-Za-z0-9_-]`, no dots).
- You need a Swift toolchain with the Embedded Swift stdlib, which Xcode's toolchain lacks. Get one from swift.org, or use `swiftly`. den looks in the same places as `cordis-build`: `$CORDIS_TOOLCHAIN`, then `~/.swiftly/toolchains`, then `~/Library/Developer/Toolchains` (newest first), then `/Library/Developer/Toolchains/swift-latest.xctoolchain`. Without one, den shows a single message and skips source folders.
- A failed build shows a toast with the first error. The full output is in `~/.den/logs/build-<id>.log`. The previous build keeps running.

## Themes

Each file in `~/.den/themes` is one preset. The theme plugin offers every preset in the command bar as **Theme: \<name\>**, and picking one applies it to the current space.

```json
{ "name": "Dusk", "colors": ["#3139fb", "#ff3c19"], "intensity": 0.8, "grain": 0.3, "appearance": "dark" }
```

```toml
# ~/.den/themes/aurora.toml
colors = ["#73e59c", "#7eb8d6"]
intensity = 0.6
```

| Key | Type | |
|---|---|---|
| `name` | string | Optional. Defaults to the file name |
| `colors` | 1–3 hex strings | Required |
| `intensity`, `grain` | 0–1 | Optional |
| `appearance` | `auto`, `light` or `dark` | Optional. Appearance is global, so it applies to every space |

## Extensions

Each folder in `~/.den/extensions` that holds a `manifest.json` is an unpacked Chrome or Firefox extension. den loads it in place, the first time a web view is created, with the permissions it asks for (you put it there, so there's no prompt). It shows on the Extensions page as "~/.den/extensions"; turning it off there keeps it off, and to uninstall it you delete the folder (Remove never deletes your files). Edit the files and turn it off and on to reload it. The folder is read at launch; it isn't watched.

Extensions installed from the Chrome Web Store, Firefox Add-ons or a file live in `~/Library/Application Support/den/Extensions`, not here ([host-api.md](host-api.md#webext)).

## config.toml

den writes a commented `config.toml` on first launch. Invalid TOML keeps the last good config and shows the error in a toast.

```toml
[plugins]
disabled = ["peek"]                     # plugin ids den doesn't load (live: removing one loads it again)

[shortcuts]
"cmd+shift+s" = "den.toggleSidebar"     # chord = command id (any command in the command bar)

[search.keywords]
sf = { name = "Swift Forums", url = "https://forums.swift.org/search?q=%s" }   # type sf, then Tab
```

- **`[plugins] disabled`**: plugin ids that aren't loaded. The list is read at launch, and an edit loads or unloads plugins straight away.
- **`[shortcuts]`**: chords are `cmd`, `shift`, `opt` and `ctrl` joined with `+` to a key. A menu item id ([shortcuts.md](shortcuts.md), such as `tabs.next`) moves that item's shortcut to the chord. Any other id is bound through the `keys` service (and shows up in a *Shortcuts* menu), and runs `commands.run {id}`. Built-in command ids are listed in [plugin-services.md](plugin-services.md) (`den.*`). Plugin commands work too, such as `theme.edit`.
- **`[search.keywords]`**: site-search keywords, merged into the command bar's engines (`commands.engines`). An entry here overrides an engine with the same keyword. Removing it removes that keyword again.

The TOML subset den reads covers tables, dotted and quoted keys, strings, numbers, booleans, arrays and inline tables. It doesn't cover `[[arrays of tables]]`, multi-line strings or dates.

Plugins read the whole config through the host `config` service ([host-api.md](host-api.md#config)).

## Live updates for an installed den

- `scripts/install.sh` builds `build/den.app` and runs `swift test` (through `scripts/test.sh`; `--no-test` skips it). Only if both pass does it copy the app to `/Applications/den.app` (next to the old one), quit the running den with SIGTERM (a clean quit that skips the quit dialog), swap in the new app and relaunch it. It then prints the relaunch gap and checks that the session came back.
- `scripts/dev-sync.sh` watches the repo. A change under `Plugins/<id>/` rebuilds only that plugin into `~/.den/plugins/<id>.dylib`, and the running den hot-swaps it. A change under `Plugins/Shared` rebuilds every plugin. A host change (`Sources/`, `Resources/`, `Package.*`) runs the same verified install. Changes are debounced, and a failing build is never installed. The script uses `fswatch` if it's installed and otherwise polls mtimes once a second. After a host install, the `~/.den/plugins` dylibs that dev-sync wrote are removed, because the new bundle has those builds.
