# Writing your first den plugin

A walkthrough from an empty directory to a plugin that is loaded in den, adds a command to the
command bar (⌘T) and owns a section in Settings (⌘,). The code below is complete and
copy-pasteable; it follows the same shape as den's own small plugins (`Plugins/theme`,
`Plugins/tips`, `Plugins/quit`), so you can read those next to each step.

What you'll end up with: a `hello` plugin with a **Say Hello** command that shows a toast with a
counter, a **Settings ▸ General ▸ Hello** toggle that changes the greeting, and a counter that
survives hot reloads.

## How a plugin works

Every den feature is a plugin: an Embedded Swift dylib that implements cordis's `CordisPlugin`
and talks to den only through services. The host is a small AppKit app; it renders plugin UI and
provides the platform services ([host-api.md](host-api.md)). Other plugins provide services too
(`commands`, `tabs`, `spaces`, … — [plugin-services.md](plugin-services.md)), and you call them
exactly the same way.

The contract, from [host-api.md](host-api.md):

- Every service is one handler, `(method: String, args: Value) -> Value`. You call it with
  `ctx.call(service, method, args)` (or `env.call`, below).
- Errors come back as `{"error": "<message>"}` (check with `r.isErr`, `Plugins/Shared/Env.swift`).
  Success without a result returns `{"ok": true}`.
- Events go on the bus as `<service>.<event>`; you subscribe with `on`.
- Asynchronous results always arrive as events. No call blocks.

A plugin is two kinds of file, by convention:

- **`<Name>Plugin.swift`** — the cordis entry point: the manifest, `apply` and `dispose`. Only
  cordis-build ever compiles it. Smallest example: `Plugins/quit/QuitPlugin.swift`.
- **`<Name>Core.swift`** — all the logic, written against `PluginEnv`
  (`Plugins/Shared/Env.swift`), a thin testable wrapper over the cordis `Context`. den compiles
  these core files as ordinary Swift too (the `PluginCores` target), so `Tests/PluginTests` can
  drive them against the real host services.

## Step 1: the entry point

Create `Plugins/hello/HelloPlugin.swift` (or, to iterate without the repo,
`~/.den/plugins/hello/HelloPlugin.swift` — both paths load the same files; see step 5):

```swift
// cordis entry point for the `hello` plugin. The logic lives in HelloCore.swift.

nonisolated(unsafe) var helloCore: HelloCore?

struct Plugin: CordisPlugin {
  // `commands` is optional (commandbar plugin), so it is called but not injected.
  static let manifest = Manifest(name: "Hello", version: "0.1.0", inject: ["ui", "storage", "settings"], provides: [])

  static func apply(_ ctx: Context) throws(PluginError) {
    let core = HelloCore(env: PluginEnv(ctx))
    helloCore = core
    core.start()
  }

  static func dispose() {
    helloCore?.stop()
    helloCore = nil
  }
}
```

This is the same shape as `Plugins/tips/TipsPlugin.swift` — the same `inject` list, with the
names changed (`Plugins/quit/QuitPlugin.swift` is the same pattern with fewer services). What
matters:

- The type must be named `Plugin` and conform to `CordisPlugin` (cordis `Plugin.swift`).
- `inject` lists services that must exist before `apply` runs; the plugin is disposed if one
  goes away. `ui`, `storage` and `settings` are host services, always there.
- `commands` is provided by the `commandbar` *plugin*, which may load after yours, so den's
  plugins never inject it — they call it and retry (step 3). The comment saying so is part of
  the convention.
- State lives in a `nonisolated(unsafe)` global; `dispose` releases it. Everything registered
  through `ctx` (event handlers, timers, provided services) is released automatically on
  dispose (cordis `Plugin.swift`).
- `apply` may throw a `PluginError` to refuse activation; the host disables the plugin and
  reports your message.

## Step 2: the core

Create `HelloCore.swift` next to it. This is the whole plugin — command, Settings section,
counter — modeled on `Plugins/tips/TipsCore.swift` and `Plugins/quit/QuitCore.swift`:

```swift
#if !hasFeature(Embedded)
  import CordisValue
#endif

/// den's smallest feature plugin: a "Say Hello" command that toasts a counter, with one
/// Settings toggle. The counter persists in storage, so it survives hot reloads.
final class HelloCore {
  static let ns = "hello"
  static let toastId = "hello.toast"
  static let commandId = "hello.say"

  let env: PluginEnv
  var greetings: Int64 = 0
  var exclaim = false
  var commandsRegistered = false
  var registerAttempts = 0

  init(env: PluginEnv) { self.env = env }

  func start() {
    greetings = env.call("storage", "get", ["ns": .string(Self.ns), "key": "greetings"]).int ?? 0
    registerSettings()
    registerCommands()
    env.on("commands.run") { [self] v in
      if v.s("id") == Self.commandId { say() }
    }
  }

  /// Called from dispose() on unload or hot reload.
  func stop() {
    registerAttempts = Int.max / 2  // breaks the retry timer in registerCommands()
  }

  func say() {
    greetings += 1
    env.call("storage", "set", ["ns": .string(Self.ns), "key": "greetings", "value": .int(greetings)])
    var text = "Hello from den · greeting " + String(Int(greetings))
    if exclaim { text += "!" }
    env.call("ui", "set", ["slot": "toast", "tree": [
      "type": "toast", "id": .string(Self.toastId), "text": .string(text),
      "icon": "sf:hand.wave", "duration": 3000,
    ]])
  }

  // MARK: Settings

  /// Settings ▸ General ▸ "Hello" (the host `settings` service; it persists the value itself,
  /// in storage ns `hello`, key `prefs`).
  func registerSettings() {
    let r = env.call("settings", "register", [
      "id": .string(Self.ns), "section": "general", "title": "Hello", "order": 70,
      "controls": [["key": "exclaim", "type": "toggle", "title": "Exclaim greetings",
                    "subtitle": "End every greeting with an exclamation mark.", "default": .bool(exclaim)]],
    ])
    guard !r.isErr else { return }
    if let v = env.call("settings", "get", ["id": .string(Self.ns), "key": "exclaim"]).bool, v != exclaim { exclaim = v }
    env.on("settings.changed") { [self] v in
      if v.s("id") == Self.ns, v.s("key") == "exclaim", let on = v["value"].bool { exclaim = on }
    }
  }

  // MARK: Command

  /// `commands` is optional (plugin `commandbar`) and may load later: retry every 500 ms for 30 s.
  func registerCommands() {
    if tryRegister() { return }
    env.timer(500, false) { [self] in
      registerAttempts += 1
      if !tryRegister(), registerAttempts < 60 { registerCommands() }
    }
  }

  @discardableResult
  func tryRegister() -> Bool {
    if commandsRegistered { return true }
    let r = env.call("commands", "register", [
      "id": .string(Self.commandId), "title": "Say Hello", "icon": "sf:hand.wave",
      "keywords": ["hello", "greet", "wave"], "owner": .string(Self.ns),
    ])
    commandsRegistered = !r.isErr
    return commandsRegistered
  }
}
```

Read it alongside the models:

- The `#if !hasFeature(Embedded) import CordisValue #endif` guard is how every den core file
  starts (`Plugins/theme/ThemeCore.swift:1-3`): cordis-build compiles the file as Embedded
  Swift, where `Value` is always visible; the `PluginCores` test target compiles it as ordinary
  Swift, where it must be imported.
- `env.call("storage", "get"/"set", …)` is the `storage` host service: one file per namespace
  (use your plugin id), values are `Value`s
  ([host-api.md](host-api.md#storage)). Anything you keep there survives a hot swap.
- `env.on("commands.run")` is how a command fires: the command bar emits `commands.run {id}`
  and each owning plugin acts on its own ids
  ([plugin-services.md](plugin-services.md#commands-plugin-commandbar)).
- `env.timer(500, false)` schedules one shot on the main thread; `env.now()` gives wall-clock
  milliseconds. Both come from `PluginEnv` (`Plugins/Shared/Env.swift`).

## Step 3: what each part does

**The command-bar action.** `commands.register` takes `id`, `title`, `icon?`, `keywords?`,
`aliases?`, `shortcut?` and `owner?` ([plugin-services.md](plugin-services.md)). Two conventions
matter:

- **Retry.** The `commandbar` plugin may load after yours, so a failed register is retried
  every 500 ms for up to 30 s — the same loop as `ThemeCore.registerCommands`,
  `TipsCore.registerCommands` and `QuitCore.registerCommands`. `stop()` sets
  `registerAttempts = Int.max / 2` so a reload mid-retry doesn't leave a timer loop running.
- **`owner`.** cordis doesn't tell a service which plugin called it, so you pass your own id.
  With `owner`, the command bar drops your commands when your plugin unloads
  ([plugin-services.md](plugin-services.md)); without it they'd linger until relaunch.

**The Settings section.** The Settings window and its `settings` service are in the host
([host-api.md](host-api.md#settings)): plugins contribute sections as typed controls, and the
host persists the values and emits changes. `register` with a `section` adds your controls to
that section as a group titled `title` (`tips` puts "Tips" in General; `quit` puts "Quitting"
there). The control shapes are `{key, type, title, subtitle?, default?}` with types `toggle`,
`choice`, `text`, `shortcut`, `number`, `list`, `button` and `info`. After registering, read the
stored value with `settings.get` (a user may have changed it while your plugin was unloaded) and
react to `settings.changed {id, key, value}`. Without a `section`, your `id` becomes its own
sidebar section (what `pagetools`' Reading pane does).

**The toast.** One `ui.set` into the `toast` slot with a `toast` node: `text`, `icon?`
(`sf:<symbol>`), `duration?` in ms, `id?` so a new toast replaces the old one
([host-api.md](host-api.md#ui)). The `ui` service's other slots (sidebar regions, `dialog`,
sheets) work the same way: you send a node tree, the host renders it, and actions come back as
`ui.action {id, action, value}`.

## Step 4: Embedded Swift rules

Plugins are Embedded Swift because only Embedded Swift dylibs fully unload on macOS — that's
what makes hot-swapping possible ([architecture/thin-host.md](architecture/thin-host.md) §7).
The price: **no Foundation, AppKit, WebKit, Keychain, FoundationModels, URLSession or
AVFoundation.** Anything that needs one of those goes through a host service instead:

| You'd reach for | Use instead |
|---|---|
| `Date()` | `env.now()` (ms since 1970), or `schedule.clock` for wall-clock text |
| `URLSession` | `net.fetch` (needs a `net:` permission, step 6) |
| `FileManager` | `storage` for state; `app.paths` / `app.openPath` / `app.fileInfo` for files |
| `print` | `ctx.log` / `env.log` (den's stdout as `[<id>] message`) |
| `String(format:)`, `URL` | string concatenation and the `Text` / `URLs` helpers in `Plugins/Shared/Env.swift` |

`Plugins/Shared` is compiled into every plugin by cordis-build (`scripts/bundle.sh`), so
`PluginEnv`, the `Value` helpers (`s`, `i`, `b`, `a`, `isErr`, `put`) and `Text`/`URLs`/`Copied`
are always available — they exist precisely because Foundation doesn't.

Practical consequences you'll notice in the code above:

- Everything crosses the service boundary as a `Value`: objects, arrays, strings, ints, doubles,
  bools, null. Dictionary and array literals are `Value`s, so `["slot": "toast", "tree": …]`
  just works; read results back with `v.s("id")`, `v.int ?? 0`, `v["value"].bool`.
- Build strings with `+` and `String(...)` (as `ThemeCore` does), not interpolation-heavy code.
- In the repo, core files also compile in Swift 5 language mode for the `PluginCores` test
  target (`Package.swift`), so match the style of the existing cores.

## Step 5: load it

Three ways, from fastest to most permanent. All of them hot-swap: den watches the files and
reloads within about 100 ms, and plugin state kept in `storage` survives the swap
([den-home.md](den-home.md)).

**A. A source folder in `~/.den` (best for iterating).** Copy the two files to
`~/.den/plugins/hello/`. den compiles the folder on a background queue with its bundled copy of
cordis-build, compiling `Plugins/Shared` in as well, and loads the result straight away; saving
a file rebuilds it ([den-home.md](den-home.md#source-plugins)). Notes:

- The plugin id is the folder name: `[A-Za-z0-9_-]`, no dots.
- You need a Swift toolchain with the Embedded Swift stdlib, which Xcode's toolchain lacks —
  get one from swift.org or via `swiftly`. den looks in `$CORDIS_TOOLCHAIN`, then
  `~/.swiftly/toolchains`, then `~/Library/Developer/Toolchains`, then
  `/Library/Developer/Toolchains/swift-latest.xctoolchain`. Without one, den says so once and
  skips source folders.
- A failed build shows a toast with the first error and keeps the previous build running; the
  full output is in `~/.den/logs/build-hello.log`. Loads and rebuilds are logged in
  `~/.den/logs/plugins.log`.
- The compiled dylib lands in `~/Library/Caches/io.github.abhishakenp.den/source-plugins/`.
  Nothing but the folder's `.swift` files is read
  (`Sources/DenHost/Plugins/LivePlugins.swift`), so a `permissions.json` in a source folder has
  no effect — permissions need a dylib (step 6).

**B. A prebuilt dylib in `~/.den`.** Build it with the cordis-build bundled inside the app.
The shared helpers are not automatic here — you must pass `Plugins/Shared/*.swift` yourself,
because your core uses `PluginEnv` from there:

```sh
cd <repo>
/Applications/den.app/Contents/Resources/cordis/Scripts/cordis-build \
  --id hello --out ~/.den/plugins/hello.dylib \
  Plugins/hello/HelloPlugin.swift Plugins/hello/HelloCore.swift Plugins/Shared/*.swift
```

cordis-build writes the output atomically, so the watcher never sees a half-written dylib
([den-home.md](den-home.md)). Don't name a source file `Plugin.swift` here — CordisKit already
has one and swiftc fails with "filename used twice" (source folders don't have this problem: den
renames the files before compiling). To declare permissions, put a `hello.json` sidecar next to
the dylib (step 6).

**C. Bundled with den.** Move the folder to `Plugins/hello/` in the repo. `scripts/bundle.sh`
builds every `Plugins/<id>/` into `Contents/PlugIns/<id>.dylib` ([host-api.md](host-api.md));
no build-file registration is needed. While you work on it, `scripts/dev-sync.sh` watches the
repo and rebuilds a changed `Plugins/<id>/` into `~/.den/plugins/<id>.dylib`, which hot-swaps
over the bundled one ([den-home.md](den-home.md)). `--dev-plugins <dir>` is the same idea by
hand: it loads `<dir>/*.dylib` ahead of every other layer and hot-reloads them when rebuilt
([host-api.md](host-api.md)).

For one id, the highest layer wins:

| Priority | Where | Reloaded live |
|---|---|---|
| 5 (wins) | `--dev-plugins <dir>/<id>.dylib` | yes |
| 4 | `~/.den/plugins/<id>/*.swift` (den compiles) | yes |
| 3 | `~/.den/plugins/<id>.dylib` | yes |
| 2.5 | `~/.den/updates/plugins/<id>.dylib` (managed updates) | yes |
| 2 | `~/Library/Application Support/den/Plugins/<id>.dylib` | launch only |
| 1 | `den.app/Contents/PlugIns/<id>.dylib` (bundled) | no |

Dropping `hello.dylib` into `~/.den/plugins` therefore replaces a bundled plugin of the same id
live; deleting it swaps back. If a plugin fails to load, a toast says why and den falls back to
the next layer. If a plugin *crashed* den, that same build is refused on the next launch and a
toast names it; a new build loads normally.

**Try it.** With den running: open the command bar (⌘T), type `hello`, pick **Say Hello** — a
toast counts your greetings. Open Settings (⌘,) ▸ General, scroll to **Hello**, flip the toggle,
and say hello again. Save one of the source files (even a comment) and watch it reload; the
counter keeps going because it lives in storage.

## Step 6: permissions.json (only if you reach the network or pages)

Most plugins need nothing here — the example above declares no permissions. You need them only
for the services that can reach a logged-in website (`session`, `net`) or run your code inside
pages (`webviews.inject`). Declare them in `Plugins/<id>/permissions.json`
(`scripts/bundle.sh` ships it next to the dylib as `<id>.json`; a dylib you install yourself
uses the same sidecar next to it):

```json
{ "permissions": ["session:example.com", "net:api.example.com"] }
```

- `session:<domain>`: read cookies and site storage of `<domain>` and its subdomains, and
  `net.fetch` there with the profile's cookies attached.
- `net:<domain>`: `net.fetch` to `<domain>` and its subdomains, without cookies. `net:*` covers
  every host, still without cookies.
- `pages:<domain>` or `pages:*`: run your scripts in pages of that domain (every page with `*`)
  through `webviews.inject`, in your plugin's isolated content world.

Rules, from `Sources/DenHost/Services/Permissions.swift` and
[host-api.md](host-api.md#permissions):

- Anything undeclared is denied.
- `session:*` is refused: cookies are never granted for every site. A `session:<domain>` grant
  also covers `webviews.inject` into that site.
- cordis doesn't tell a host service which plugin called it, so `session` and `net` calls pass
  `plugin: "<your id>"` themselves (the same convention as `commands.register {owner}`).
- Plugins are native code in den's process: permissions are a declared-intent gate that keeps
  each plugin to its own sites, **not a sandbox**.
- The same sidecar can say when the plugin loads: `"launch": "firstFrame"` loads it before the
  first window (only for plugins that paint that window, like `spaces` and `tabs`); every other
  plugin loads right after the first frame.
- A plugin's other sidecar is its resource folder — `Plugins/<id>/resources/`, bundled as
  `Contents/Resources/plugin-resources/<id>/` — the files `webviews.inject` reads by name.

## Shipping it in the repo

When the plugin works from `~/.den` and you want it bundled:

1. Move the folder to `Plugins/hello/`. `scripts/bundle.sh` picks it up automatically; add
   `permissions.json` there if you declared any.
2. Add `HelloCore.swift` (not `HelloPlugin.swift` — the entry point is plugin-only glue) to the
   `PluginCores` target's `sources` in `Package.swift`, so the core type-checks and tests as
   ordinary Swift.
3. Add a suite in `Tests/PluginTests/` using the `Harness` there — a real `DenRuntime` wired to
   a `PluginEnv` (`QuitTests.swift` is the small model). Run it with `scripts/test.sh`.
4. The mechanics — remote CI, commit style, the PR flow — are in
   [CONTRIBUTING.md](../CONTRIBUTING.md).

## Where to read more

- [host-api.md](host-api.md) — every host service, its methods, args and events
- [plugin-services.md](plugin-services.md) — the services den's plugins provide to each other
- [den-home.md](den-home.md) — `~/.den` layers, themes, `config.toml`
- [architecture/thin-host.md](architecture/thin-host.md) §7 — what can never be a live-swappable
  plugin, and why the host holds the platform services
- `Plugins/theme`, `Plugins/tips`, `Plugins/quit` — the small plugins this guide mirrors
