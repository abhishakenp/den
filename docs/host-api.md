# den host API (v0)

The host is a small AppKit app. Browser features (spaces, tabs, peek, command bar logic, themes) are plugins. The host gives them services and renders their UI.

- Every service is one handler, `(method: String, args: Value) -> Value`. It has the same shape as `cordis_service_fn` in `cordis.h` (sibling `cordis-swift` package), so each one registers with cordis `PluginHost.provide(name, handler)` unchanged.
- Errors come back as `{"error": "<message>"}`. Success without a result returns `{"ok": true}`.
- Events go on the host bus as `<service>.<event>`, and plugins subscribe with `on`.
- Asynchronous results always arrive as events. No call blocks.

The code lives in `Sources/DenHost/Services/`. Until `PluginHost` is wired in, `DenRuntime.call(service, method, args)` and `ServiceHost.on/emit` stand in for `cordis_host.call/on/emit`.

## window

| Method | Args | Returns |
|---|---|---|
| `setTheme` | `colors: [hex]` (≤3), `intensity 0–1`, `grain 0–1`, `appearance: light\|dark\|auto`, `page?` | ok |
| `setSidebar` | `width?`, `hidden?`, `animated?` | ok |
| `toggleSidebar` | `animated?` | ok |
| `setTitle` | `title` | ok |
| `get` | – | `{width, hidden, page, fullScreen, dark}` |

Events: `window.sidebarResized {width}`, `window.sidebarVisibility {hidden}`, `window.sidebarReveal {revealed}`.

- Themes are kept per space page. The background blends between page themes while you swipe.
- The sidebar resizes by dragging its edge; a double-click on the edge resets the width.
- Dragging the edge below 120 pt hides the sidebar. While it's hidden, hovering the left window edge reveals it as an overlay.
- Empty sidebar space drags the window.

## webviews

| Method | Args | Returns |
|---|---|---|
| `create` | `id?`, `url?`, `profile?` (`default`, `private`, or any name, which maps to a stable `WKWebsiteDataStore(forIdentifier:)`) | `{id}` (lazy: no `WKWebView` until shown) |
| `navigate` | `id`, `url` | ok |
| `back`, `forward`, `reload`, `stop`, `close` | `id` | ok |
| `suspend` | `id` | ok. Full discard: saves `interactionState` and a snapshot, then destroys the view. The next show restores it |
| `snapshot` | `id`, `path` | `{pending}`, then the event `webviews.snapshot {id, path, ok}` |
| `get` | `id` | `{id, url, title, favicon, loading, progress, canGoBack, canGoForward, audio, suspended, live, profile}` |
| `list` | – | `[id]` |
| `setLinkPolicy` | `id` (or `"*"` for the default), `rules: [{when: crossSite\|sameSite\|any, hosts?: [suffix], modifiers?: [cmd,shift,opt,ctrl], event}]` | ok |

Events:
- `webviews.title {id,title}`
- `webviews.url {id,url}`
- `webviews.favicon {id,url}`
- `webviews.progress {id,progress,loading}`
- `webviews.state {id,canGoBack,canGoForward}`
- `webviews.audio {id,playing}`
- `webviews.newWindow {id,url}`
- `webviews.crashed {id}`
- `webviews.suspended {id}`
- `webviews.detached {id}`
- `webviews.closed {id}`
- One event per link rule, named by the rule's `event` field: `{id, url, source}`.

The link policy is declarative because `WKNavigationDelegate` decisions are synchronous. A matched rule cancels the navigation and emits the rule's event. Only main-frame link clicks are routed, and a plain rule never catches cmd-clicks.

## content

| Method | Args | Returns |
|---|---|---|
| `show` | `panes: [webviewId]` (1–4), `orientation?: horizontal\|vertical\|grid`, `ratios?`, `focus?` | ok |
| `focus` | `id` | ok |
| `peek` | `webview` to show, or `{}` to hide | ok |
| `get` | – | `{panes, orientation, focus, peek}` |

Events: `content.focus {id}` and `content.peekAction {action: close|expand|split, webview}`.

Web views that aren't shown are detached from the window, which lets WebKit suspend them.

## ui

| Method | Args | Returns |
|---|---|---|
| `set` | `slot`, `tree` (null clears), `page?` | ok |
| `setPages` | `count`, `current?` | ok |
| `showPage` | `page`, `animated?` | ok |
| `get` | – | `{page, pages, overlays}` |

**Slots:**
- `sidebar.header`, `sidebar.favorites`, `sidebar.footer`
- Per space page: `sidebar.spaceHeader`, `sidebar.pinned`, `sidebar.today`
- Overlays: `overlay.commandBar`, `overlay.peek` (`{webview, title}`), `dialog`, `toast`

**Event:** `ui.action {id, action, value}`

**Sidebar-level actions** (`id: "sidebar"`):
- `page` (value = the new page, after a swipe)
- `doubleClick` (on empty sidebar space)

**Node types** (the `type` field) and the actions they emit:

| Node | Fields | Actions |
|---|---|---|
| `list` | `children`, `spacing?`, `padding?` | – |
| `row` | `children`, `spacing?`, `height?` | – |
| `spacer` | `width?`, `height?` | – |
| `text` | `text`, `style: title\|body\|caption\|secondary` | – |
| `button` | `id`, `icon`, `title?`, `size?`, `tooltip?`, `enabled?`, `action?` | `click` (or `action`) |
| `navBar` | `id`, `canGoBack`, `canGoForward`, `loading` | `toggleSidebar`, `back`, `forward`, `reload`, `stop` |
| `urlPill` | `id`, `text`, `progress?`, `loading?`, `placeholder?` | `click`, `copy` |
| `grid` | `columns?`, `children` | – |
| `favoriteTile` | `id`, `icon`, `title`, `selected`, `audio` | `click`, `doubleClick`, `reorder` |
| `spaceTitle` | `id`, `title`, `icon?` | `click`, `more` |
| `spaceIcon` | `id`, `icon?` (empty = dot), `title`, `selected` | `click` |
| `tabRow` | `id`, `title`, `icon`, `selected`, `audio`, `muted?`, `drift` (the "/" marker), `closable=true`, `indent?`, `draggable=true` | `click {modifiers?}`, `doubleClick`, `close` (also middle-click), `reset` (favicon click while drifted), `mute`, `reorder`, `dropOnContent` |
| `folder` | `id`, `title`, `icon?`, `open`, `children` | `toggle`, `reorder` (as target: `position: "into"`) |
| `divider` | `id`, `action?` (label, e.g. "Clear") | `clear` |
| `newTabRow` | `id`, `title?` | `click` |
| `commandBar` | `id`, `query`, `replaceQuery?`, `placeholder?`, `selected`, `sections: [{title?, rows: [{id, icon, title, subtitle?, accessory?, keycap?}]}]` | `input {text}`, `select {row}`, `submit {row, query, modifiers}`, `tab {query}`, `dismiss` |
| `dialog` | `id`, `title`, `message?`, `icon?` (`app:icon` for the app icon), `buttons: [{id, title, style: default\|cancel\|destructive\|secondary}]`, `checkbox?` | `button {button, checked}` (Return/Esc press the default/cancel button) |
| `toast` | `text`, `icon?`, `duration?` (ms) | – |

**Details that apply to several nodes:**
- **Icons.** A node icon can be `sf:<symbol>`, an http(s) image URL (cached), `app:icon`, or text/emoji.
- **Context menus.** Any node can carry `menu: [{id, title, icon?} | {separator: true}]`. The host shows it as a native context menu and emits `menu` with the picked item's id.
- **Drag reorder.** Dragging emits `reorder {source, target, position: before|after|into}` with a haptic tick. Dropping on the web content emits `dropOnContent {source, side: left|center|right}`.
- **View reuse.** Views are reused by `type` + `id`, so it's cheap to resend a whole tree on every change.

## keys

| Method | Args | Returns |
|---|---|---|
| `bind` | `chord` (e.g. `cmd+shift+k`, `ctrl+1`, `cmd+opt+left`), `event`, `title?`, `menu?` (File/Edit/View/Tabs/Spaces/Window/any), `payload?` | ok. Emits `event {chord, payload}` |
| `unbind` | `chord` | ok |
| `list` | – | `[{chord, event, title, menu}]` |

Chords are bound as main-menu items. That way they work while a web page has focus, and the standard Edit and Window shortcuts keep working.

## storage

| Method | Args | Returns |
|---|---|---|
| `get` | `ns`, `key` | value or null |
| `set` | `ns`, `key`, `value` | ok |
| `delete` | `ns`, `key` | ok |
| `keys` | `ns` | `[string]` |
| `clear` | `ns` | ok |

- Each namespace (plugin id) is one `Codec`-encoded file at `~/Library/Application Support/den/storage/<ns>.cvalue`.
- Writes are atomic.

## app

| Method | Args | Returns |
|---|---|---|
| `interceptQuit` | `enabled` | ok. Cmd-Q then emits `app.quitRequested`, and quitting waits for `quit` |
| `quit` | `confirm=true` | ok |
| `interceptClose` | `enabled` | ok. Closing the window then emits `app.closeRequested` |
| `closeWindow` | – | ok |
| `pendingURLs` | – | `[url]` opened before any listener existed |
| `setDefaultBrowser` | – | ok. Emits `app.defaultBrowser {scheme, error}` |
| `info` | – | `{bundleId, version, launchMs}` |

Events: `app.quitRequested`, `app.closeRequested`, `app.openURL {urls}`, `app.defaultBrowser`.
