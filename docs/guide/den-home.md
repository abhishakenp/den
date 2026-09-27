# `~/.den`: plugins, themes and config

`~/.den` is yours. den creates it on first launch and watches it the whole time it runs: save a file and the change applies within about 100 ms, no relaunch.

```
~/.den/
  plugins/      your plugins: <id>.dylib, or a folder of .swift files den compiles
  themes/       theme presets, <name>.json or <name>.toml
  extensions/   unpacked Chrome/Firefox extensions (read at launch)
  config.toml   settings, shortcuts, site-search keywords
  logs/         plugins.log, build-<id>.log, den.log, updater.log
```

Settings ▸ General has **Open** and **Show in Finder** buttons for `config.toml` and the den folder. To use another folder, set `DEN_HOME`.

## config.toml

den writes a commented `config.toml` on first launch. Broken TOML never breaks den: it keeps the last good config and shows the error in a toast.

```toml
[plugins]
disabled = ["peek"]        # plugins den shouldn't load. Remove one and it loads again, live

[shortcuts]
"cmd+shift+j" = "tabs.next"          # give a menu item a new key
"cmd+shift+y" = "den.copyMarkdown"   # or bind any command bar command

[search.keywords]
sf = { name = "Swift Forums", url = "https://forums.swift.org/search?q=%s" }   # type sf, then Tab

[updates]
channel = "stable"         # see Updates
```

- **`[plugins] disabled`**: turn any plugin off, bundled ones included. It's how you'd drop Peek if you don't like it.
- **`[shortcuts]`**: chords are `cmd`, `shift`, `opt`, `ctrl` joined with `+` to a key (`a`, `]`, `left`, `tab`, `f5`, `plus`). The value is a menu item id from [Keyboard shortcuts](shortcuts.md) or a command id.
- **`[search.keywords]`**: adds site searches to the command bar. `%s` is where your query goes. A keyword here overrides a built-in one.
- **`[updates]`**: see [Updates](updates.md).

The TOML den reads covers tables, dotted and quoted keys, strings, numbers, booleans, arrays and inline tables. Not `[[arrays of tables]]`, multi-line strings or dates.

## Themes

Each file in `~/.den/themes` is one preset. It shows up in the command bar as **Theme: \<name\>**, and picking it applies it to the current space.

```json
{ "name": "Dusk", "colors": ["#3139fb", "#ff3c19"], "intensity": 0.8, "grain": 0.3, "appearance": "dark" }
```

```toml
# ~/.den/themes/aurora.toml
colors = ["#73e59c", "#7eb8d6"]
intensity = 0.6
```

| Key | | |
|---|---|---|
| `colors` | 1–3 hex colors | required |
| `name` | string | defaults to the file name |
| `intensity`, `grain` | 0–1 | optional |
| `appearance` | `auto`, `light`, `dark` | optional. Appearance is global, so it applies to every space |

## Plugins

Every feature in den is a plugin, and yours load the same way. Drop a plugin in `~/.den/plugins` and it replaces the built-in one with the same id while den runs, keeping your tabs. Delete it and den swaps the built-in one back.

**Prebuilt:** put `<id>.dylib` (built with `cordis-build`) in `~/.den/plugins/`.

**From source:** put `.swift` files in `~/.den/plugins/<id>/`, and den compiles them in the background:

```swift
// ~/.den/plugins/hello/Plugin.swift
struct Plugin: CordisPlugin {
  static let manifest = Manifest(name: "Hello", version: "0.1.0", inject: ["ui"])
  static func apply(_ ctx: Context) throws(PluginError) {
    _ = ctx.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": "Hello from ~/.den", "icon": "sf:hand.wave", "duration": 3000]])
  }
}
```

Save the file and the toast appears. Save again and it rebuilds.

- The folder name is the plugin id (letters, digits, `-`, `_`).
- You need a Swift toolchain with the Embedded Swift stdlib (from swift.org or `swiftly`; Xcode's doesn't have it). Without one, den tells you once and skips source folders.
- A failed build shows a toast with the first error. The full log is in `~/.den/logs/build-<id>.log`, and the previous build keeps running.
- A plugin that fails to load gets a toast saying why, and den falls back to the built-in one.

The API plugins code against is in [docs/host-api.md](../host-api.md), and the services the built-in plugins offer each other are in [docs/plugin-services.md](../plugin-services.md).

## Extensions

A folder in `~/.den/extensions` with a `manifest.json` is loaded as an unpacked extension, with the permissions it asks for (you put it there, so den doesn't ask). See [Extensions](extensions.md).

---

Layer order, the source-plugin cache and the dev scripts are in the reference: [docs/den-home.md](../den-home.md).
