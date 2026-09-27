---
name: den
description: Use when the user wants to customize, theme, extend or debug their installed den browser (the macOS 26 browser built from hot-swappable Embedded Swift plugins) - editing ~/.den/config.toml (plugins, keyboard shortcuts, site-search keywords, update channel), adding theme presets, writing or hot-reloading a den plugin with CordisKit and cordis-build, or reading den's logs to find out why a plugin, build or config change didn't work.
---

# den

den keeps everything user-editable in `~/.den` (or `$DEN_HOME`). It creates the folder on first launch, watches it, and applies changes within about 100 ms. No relaunch needed.

```
~/.den/
  plugins/      <id>.dylib, or a source folder <id>/*.swift that den compiles
  themes/       <name>.json or <name>.toml theme presets
  extensions/   unpacked Chrome/Firefox extensions (folder with manifest.json; read at launch, not watched)
  config.toml   plugins, shortcuts, site-search keywords, updates
  logs/         plugins.log, build-<id>.log, den.log, updater.log
  updates/      managed plugin updates (don't hand-edit)
```

`den --no-den-home` ignores `~/.den` entirely. Use it to check whether a problem comes from the user's customizations.

## 1. Customize: `~/.den/config.toml`

If the TOML is invalid, den keeps the last good config and shows the error in a toast. The config is also listed under Settings (⌘,) › General. den reads a subset of TOML: tables, dotted and quoted keys, strings, numbers, booleans, arrays and inline tables. It does **not** read `[[arrays of tables]]`, multi-line strings or dates.

```toml
[plugins]
disabled = ["peek"]                  # plugin ids not to load (bundled or yours); live

[shortcuts]
"cmd+shift+j" = "tabs.next"          # menu item id: that item takes this key instead of its default
"cmd+shift+y" = "den.copyMarkdown"   # command id: runs commands.run {id}, listed in a "Shortcuts" menu
"cmd+shift+h" = "hello.say"          # plugin commands work too

[search.keywords]
sf = { name = "Swift Forums", url = "https://forums.swift.org/search?q=%s" }   # type sf, then Tab

[updates]
channel = "stable"                   # stable | prerelease | follow-main
```

- **Chords:** `cmd`, `shift`, `opt`, `ctrl` joined with `+` to a key. A key is a single character, or one of `left right up down tab enter return esc space delete backspace plus minus`, or `f1` to `f20`.
- **Shortcut targets:**
  - Menu item ids are in the last column of `docs/shortcuts.md`, for example `file.newTab`, `tabs.next`, `tabs.prev`, `tabs.pin` and `tabs.clear`.
  - Built-in command ids are `den.*`, for example `den.toggleSidebar` and `den.copyMarkdown`.
  - Plugin commands work too, for example `theme.edit`.
  - When an id isn't a menu item, it's run as a command. An error for any shortcut shows up in Settings › General.
- **Search keywords:** `url` must contain `%s`. If a keyword here matches a built-in one, yours replaces it. The built-in keywords are `g`, `yt`, `gh`, `w`, `maps` and `x`. Deleting an entry removes the keyword again. Users can also add keywords in Settings › Search.
- **`[updates]`:** the channel is `stable`, `prerelease` or `follow-main`. Optional integer keys are `check_hours` (default 6), `relaunch_background_s` (default 60) and `relaunch_idle_min` (default 10).

### Themes: `~/.den/themes/<name>.json|toml`

Each file is one preset. It appears in the command bar as **Theme: <name>**, and picking it applies it to the current space.

```toml
# ~/.den/themes/aurora.toml
name = "Aurora"                  # optional, defaults to the file name
colors = ["#73e59c", "#7eb8d6"]  # required: 1-3 hex colors (#rgb or #rrggbb)
intensity = 0.6                  # optional, 0-1
grain = 0.2                      # optional, 0-1
appearance = "dark"              # optional: auto | light | dark (global, applies to every space)
```

JSON takes the same keys: `{ "name": "Dusk", "colors": ["#3139fb", "#ff3c19"], "intensity": 0.8 }`. A bad file is skipped, and its error is listed with the config errors.

## 2. Write a plugin

Every den feature is a plugin: an **Embedded Swift** dylib that implements CordisKit's `CordisPlugin` and is built by **`cordis-build`**. There's no Foundation. A plugin talks to den only through `ctx.call(service, method, args)`, `ctx.on(event)`, `ctx.emit`, `ctx.provide`, `ctx.timer` and `ctx.log`. Values are `Value` literals (dictionaries, arrays, strings, numbers), and a failed call returns `{"error": ...}`. The full API is in `docs/host-api.md`, and the services that other plugins provide (`commands`, `tabs`, `spaces`, `peek`, ...) are in `docs/plugin-services.md`.

**Toolchain:** you need a Swift toolchain that includes the Embedded Swift stdlib. Xcode's toolchain doesn't have it, so get one from swift.org or with `swiftly`. den and cordis-build look for it in this order:
1. `$CORDIS_TOOLCHAIN`
2. `~/.swiftly/toolchains`
3. `~/Library/Developer/Toolchains`
4. `/Library/Developer/Toolchains/swift-latest.xctoolchain`

Example: a command-bar command that shows a toast.

```swift
// Hello.swift
nonisolated(unsafe) var greetings = 0  // plugin state lives in globals; reset it in dispose()

struct Plugin: CordisPlugin {
  // apply() runs once every injected service exists (`commands` comes from the commandbar plugin).
  static let manifest = Manifest(name: "Hello", version: "0.1.0", inject: ["ui", "commands"])

  static func apply(_ ctx: Context) throws(PluginError) {
    _ = ctx.call("commands", "register", [
      "id": "hello.say", "title": "Say Hello", "icon": "sf:hand.wave",
      "keywords": ["hello", "greet"], "owner": .string(ctx.pluginID),
    ])
    ctx.on("commands.run") { v in
      guard v["id"].string == "hello.say" else { return }
      greetings += 1
      _ = ctx.call("ui", "set", ["slot": "toast", "tree": [
        "type": "toast", "id": "hello.toast", "text": "Hello from ~/.den", "icon": "sf:hand.wave", "duration": 3000,
      ]])
      ctx.log("said hello")
    }
  }

  static func dispose() { greetings = 0 }
}
```

Everything registered through `ctx` is released on dispose. Passing `owner` drops the command when the plugin unloads. To persist state, use the `storage` service (`get`/`set` with `ns` = plugin id and `key`). It survives hot reloads.

**Option A: source folder (den compiles it).** Put the file in `~/.den/plugins/hello/`.
- The folder name is the plugin id. Allowed characters: `A-Z a-z 0-9 _ -`. No dots.
- den builds the folder with its bundled cordis-build on every save and loads the result. `Plugins/Shared` (`PluginEnv` and the `Text` helpers) is compiled in as well.
- Output goes to `~/Library/Caches/io.github.abhishakenp.den/source-plugins/hello.dylib`.
- If the build fails, den shows a toast with the first error, writes the full log to `~/.den/logs/build-hello.log`, and keeps the previous build running.

**Option B: prebuilt dylib.** Build it yourself and drop it in `~/.den/plugins/<id>.dylib`:

```sh
/Applications/den.app/Contents/Resources/cordis/Scripts/cordis-build \
  --id hello --out ~/.den/plugins/hello.dylib Hello.swift
```

- **Don't name a source file `Plugin.swift` here.** CordisKit already has a `Plugin.swift`, and swiftc fails with `filename "Plugin.swift" used twice`. Source folders don't have this problem, because den renames the files before compiling.
- cordis-build writes the output atomically, so the watcher never sees a half-written dylib.
- To compile den's shared helpers in, add `/Applications/den.app/Contents/Resources/cordis/den-shared/*.swift` to the sources.
- To declare site permissions (`session:<domain>`, `net:<domain>`, `pages:<domain>`), put an `<id>.json` sidecar next to the dylib: `{"permissions": [...]}`.

**Hot reload and precedence.** The layer with the highest number wins for a given id:

| Layer | Location |
|---|---|
| 5 | `--dev-plugins <dir>` |
| 4 | `~/.den/plugins/<id>/*.swift` |
| 3 | `~/.den/plugins/<id>.dylib` |
| 2.5 | `~/.den/updates/plugins/<id>.dylib` |
| 2 | `~/Library/Application Support/den/Plugins` (read at launch only) |
| 1 | bundled |

- A file with the same id as a bundled plugin **replaces** it live. Delete the file and den swaps back to the next layer down.
- Tabs and spaces survive the swap, because plugin state is kept in storage.
- If a plugin fails to load, den shows a toast and falls back to the next layer.
- If a plugin crashed den, that exact build is refused on the next launch. A new build of the plugin loads normally.

**In the den repo**, `scripts/dev-sync.sh` rebuilds a changed `Plugins/<id>/` into `~/.den/plugins/<id>.dylib`, and the running den hot-swaps it in.

## 3. Logs and debugging

| What | Where |
|---|---|
| Plugin loads, reloads, swaps, build start/finish/failure, "no toolchain" | `~/.den/logs/plugins.log` (timestamped lines) |
| Full compiler output for a source plugin | `~/.den/logs/build-<id>.log` |
| Launches, quits and relaunches (pid, first-window time, tab counts) | `~/.den/logs/den.log` |
| follow-main updater | `~/.den/logs/updater.log` |
| Config and theme problems | Settings › General; or `ctx.call("config", "errors")` |
| `ctx.log(...)` from plugins (info and above) | den's stdout as `[<id>] message`. To see it, run `/Applications/den.app/Contents/MacOS/den` from a terminal |
| Host os_log messages (categories `extensions`, `hoverCard`, `launch`) | `log stream --level debug --predicate 'subsystem == "io.github.abhishakenp.den"'` |

To follow plugin activity live, run `tail -f ~/.den/logs/plugins.log`. A plugin can call `config.paths` to get `{root, plugins, themes, config, logs}`.

## Docs

The docs are in the den repo. Fetch the raw Markdown when you need details: `https://raw.githubusercontent.com/abhishakenp/den/main/<path>`.

- `docs/den-home.md`: `~/.den` reference (layers, source plugins, config schema)
- `docs/host-api.md`: host services (`ui`, `webviews`, `keys`, `storage`, `config`, `settings`, ...)
- `docs/plugin-services.md`: services provided by plugins, and the `den.*` command ids
- `docs/shortcuts.md`: every shortcut with its menu item id
- `docs/guide/`: the user guide (`den-home.md`, `shortcuts.md`, `spaces-and-themes.md`, ...). Browse it at https://github.com/abhishakenp/den/tree/main/docs/guide
- `Plugins/<id>/`: den's own plugins, the best examples of real plugin code
