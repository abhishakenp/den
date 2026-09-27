# den host API (v0)

The host is a small AppKit app. Browser features (spaces, tabs, peek, command bar logic, themes) are plugins. The host gives them services and renders their UI.

- Every service is one handler, `(method: String, args: Value) -> Value`. It has the same shape as `cordis_service_fn` in `cordis.h` (sibling `cordis-swift` package), so each one registers with cordis `PluginHost.provide(name, handler)` unchanged.
- Errors come back as `{"error": "<message>"}`. Success without a result returns `{"ok": true}`.
- Events go on the host bus as `<service>.<event>`, and plugins subscribe with `on`.
- Asynchronous results always arrive as events. No call blocks.

The code lives in `Sources/DenHost/Services/`. `DenRuntime` registers every service with cordis `PluginHost.provide` and re-emits every host event on the `PluginHost` bus, so plugins use `ctx.call/on/emit` and host code uses `DenRuntime.call` / `runtime.plugins.on`.

## Plugins

- Loaded at launch from `den.app/Contents/PlugIns/*.dylib` and `~/Library/Application Support/den/Plugins/*.dylib`. A user plugin replaces a bundled one with the same file name.
- `--dev-plugins <dir>` also loads `<dir>/*.dylib` (these win over both) and hot-reloads each file when it is rebuilt.
- If a plugin crashed den, the same build is refused on the next launch, and a toast names it. A new build of that plugin loads normally.
- `scripts/bundle.sh` builds every `Plugins/<id>/` (plus `Plugins/Shared/`) with `cordis-build` into `Contents/PlugIns/<id>.dylib`.

## window

| Method | Args | Returns |
|---|---|---|
| `setTheme` | `colors: [hex]` (≤3), `intensity 0–1`, `grain 0–1`, `appearance: light\|dark\|auto`, `page?` | ok |
| `setSidebar` | `width?`, `hidden?`, `animated?` | ok |
| `toggleSidebar` | `animated?` | ok |
| `setTitle` | `title` | ok |
| `get` | – | `{width, hidden, page, fullScreen, dark}` |
| `openMini` | `webview`, `space?` (name on the "Open in" button), `width?`, `height?` | `{id}`. Opens a Little Arc window hosting that web view |
| `updateMini` | `id`, `space?` | ok |
| `closeMini` | `id` | ok. The web view is detached, not closed |
| `listMini` | – | `[{id, webview}]` |

Events: `window.sidebarResized {width}`, `window.sidebarVisibility {hidden}`, `window.sidebarReveal {revealed}`, `window.miniAction {id, webview, action: open|copy}`, `window.miniClosed {id, webview}`.

**Little Arc** (spec §8) is a floating panel, 1185x832 by default, placed 20 pt from the screen's right edge and 20 pt below the menu bar. A 47 pt bar holds the traffic lights, a URL field (site icon, centered domain, copy-link button → `action: copy`) and an "Open in <space> ⌘O" button (→ `action: open`). The web view fills the rest, with no inset card. The bar follows the main window's theme. For "Open in space", the plugin calls `closeMini` and then shows the same web view with `content.show`; closing the window emits `miniClosed`, and the plugin decides whether to close the web view. The ⌘O shortcut itself is bound by the plugin through `keys`.

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

Events: `content.focus {id}`, `content.peekAction {action: close|expand|split, webview}` and `content.paneAction {id, action: close|separate}`.

**Peek** (`content.peek {webview, title?}`) floats the web view in a card over the content area: 56 pt from the sides and 40 from the top and bottom, 10 pt radius, a deep shadow and a black α0.25 dim. The `title` shows in a small pill above the card. A column of round 34x33 buttons (the Little Arc side-control size, spec §8) sits right of the card's top edge: close, expand (open as a tab) and split. Each emits `content.peekAction`, and so does a click on the dim (`close`). It opens with a 0.28 s scale-from-94% and fade using Dia's (0.2, 0.8, 0.2, 1) curve, and closes with a 0.16 s fade. Reduce Motion turns both off. Arc's Peek was never measured (spec §12), so these values are estimates.

**Split view chrome** (Arc's split geometry is UNVERIFIED, spec §12, so these are estimates):
- Panes sit 8 pt apart, each in its own 6 pt-radius card.
- The focused pane gets a 2 pt ring in the space accent, drawn in the gap just outside the card.
- Hovering a pane shows a small dark pill at its top center with **close** and **separate** buttons. They emit `content.paneAction`; the owning plugin closes the pane or moves the page back into its own tab.
- Dragging a tab (`tabRow`/`favoriteTile`) over the content shows a theme-tinted drop zone: the left or right half, or the whole card for the middle third. Dropping emits `dropOnContent {source, side}`, and a haptic tick marks each side change.

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
- Overlays: `overlay.commandBar`, `overlay.peek` (`{webview, title}`), `dialog`, `toast`, `popover` (see [Theme picker](#theme-picker-popover)), `overlay.library` (see [Archive / Library](#archive--library-sheet))

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
| `commandBar` | `id`, `query`, `replaceQuery?`, `placeholder?`, `selected`, `sections: [{title?, rows: [{id, icon, title, subtitle?, accessory?, keycap?}]}]` | `input {text}`, `select {row}` (arrow keys, or hovering a row after the mouse moves), `submit {row, query, modifiers}`, `tab {query}`, `dismiss` |
| `dialog` | `id`, `title`, `message?`, `icon?`, `iconStyle?: accent\|destructive\|plain`, `buttons: [{id, title, style: default\|cancel\|destructive\|secondary, default?, keycap?}]`, `checkbox?` | `button {button, checked}`. Return presses the `default` button (or the one with `default: true`), Esc the `cancel` one |
| `toast` | `text`, `icon?`, `duration?` (ms) | – |
| `library` | `id`, `title?`, `query?`, `placeholder?`, `clearTitle?`, `empty?`, `items: [{id, title, url?, subtitle?, icon?, closedAt?}]` | `input {text}`, `restore {item}`, `clear`, `dismiss` |
| `themePicker` | `id`, `anchor?`, `colors: [hex]` (≤3), `positions?: [[x, y]]`, `intensity`, `grain`, `appearance: auto\|light\|dark`, `page?` | `change {colors, positions, intensity, grain, appearance}` (live), `commit {…}`, `page {page}`, `dismiss {reason?}` |

**Details that apply to several nodes:**
- **Icons.** A node icon can be `sf:<symbol>`, an http(s) image URL (cached), `app:icon`, or text/emoji.
- **Context menus.** Any node can carry `menu: [item]`, shown as a native context menu. Picking an item emits `menu` with its id (submenu items included). Item shapes:
  - `{id, title, icon?, key?, destructive?, enabled=true, checked?, items?}`. `icon` is an `sf:` symbol. `key` is a chord hint drawn on the right (`cmd+w`), display only; the real binding lives in `keys`. `destructive` draws the title and icon in DestructiveButtonFace red (#F53714). `items` makes it a submenu ("Move to Space ▸").
  - `{separator: true}` and `{header: "Title"}` (section header).
- **Drag reorder.** Dragging emits `reorder {source, target, position: before|after|into}` with a haptic tick. Dropping on the web content emits `dropOnContent {source, side: left|center|right}`.
- **View reuse.** Views are reused by `type` + `id`, so it's cheap to resend a whole tree on every change.

### Theme picker popover

Arc's space theme editor (spec §4), rendered in the `popover` slot:

```
ui.set {slot: "popover", tree: {type: "themePicker", id: "theme", anchor: "space-0",
        colors: ["#b98cff", "#ff9fc8"], intensity: 0.6, grain: 0.3, appearance: "auto"}}
```

- **Placement.** A 356x508 body with a 20 pt continuous radius, 13 pt right of the sidebar. Its top follows the node whose `id` is `anchor` (clamped to the window with a 10 pt margin).
- **Color pad** (340x340, dot grid at 4.25 pt). Up to 3 draggable color dots; the first is the larger primary one. Dots snap to the grid. The angle around the center picks the hue and the distance from it the saturation. Clicking an empty pad adds the first color ("Tap to pick a color for this space"). `−` / `+` remove and add colors.
- **Presets.** 9 swatches per page, 4 pages (Brand, Pastel, Drab, Greyscale, from the spec's palette). A swatch replaces the primary color. The chevrons page through them.
- **Intensity** is the wavy slider; **grain** is the dial of dots. The three buttons at the top pick automatic, light or dark appearance.
- **Live preview.** Every drag step emits `change`, whose value has the same shape as `window.setTheme` args, so the plugin can pass it straight through. `commit` follows when a drag ends or after a click.
- **Haptics.** A tick when a dot is grabbed, when it crosses each 4-dot cell, at each 10% of intensity and at each grain step.
- **Dismiss.** Esc emits `dismiss {reason: "escape"}` (the `theme` plugin reverts); a click outside emits `dismiss` with no value (it saves). The plugin clears the slot (`tree: null`).

### Archive / Library sheet

`ui.set {slot: "overlay.library", tree: {type: "library", id: "archive", items: tabs.archive()}}` shows the archive as a sheet over the content area (640 wide, 40 pt from the content edges, 20 pt radius, over a black α0.35 dim). Arc's archive view was never measured (spec §12), so its geometry is estimated.

- **Items** take the `tabs.archive` shape directly. Rows are grouped by the day of `closedAt` (ms since 1970): Today, Yesterday, a weekday within the last week, then "Month day". The subtitle defaults to "host · time".
- **Search** filters the items locally by title or URL on every keystroke, so it stays instant. The typed text is also emitted as `input`. Return restores the first match.
- **Restore.** Clicking a row, or its hover "Restore" button, emits `restore {item}`.
- **Clear Archive** emits `clear`. The plugin then confirms with the Clear Archive dialog below, which opens above the sheet.
- **Dismiss.** Esc, the close button or a click on the dim emits `dismiss`; the plugin clears the slot.

### Dialogs

Every variant uses Arc's quit-sheet layout (spec §5): 450 wide, 26.5 pt continuous radius, #151C30 / #FAFBFF body over a black α0.55 dim, icon at (38, 38), title in SF 18 medium. The buttons sit 27.5 pt from the sides and bottom, 38 tall. `cancel` and `default` buttons pack to the right 7 pt apart, and a leading `secondary` button sits on the left. Each button shows its key as a keycap (`ESC`, `↩`).

- **Icons.** `app:icon` draws the app icon at 62 pt. Any other icon (`sf:trash`) becomes a 76 pt hero icon: the symbol on a disc tinted by `iconStyle`.
- **Button styles.** `default` is BrandBlue #3139FB. `destructive` is #F53714 (hover #DD3112, pressed #D02F11). `secondary` and `cancel` are (48,47,99) with a (99,98,174) border in dark mode.
- **Variants** (see `--scenario dialogQuit|dialogDeleteSpace|dialogDeleteFolder|dialogClearArchive`, text in `HostScenarios.dialogs`):

| Variant | Tree |
|---|---|
| Quit | `icon: "app:icon"`, buttons secondary "Quit, and don’t ask again", cancel, default "Quit" |
| Delete space | `icon: "sf:trash"`, `iconStyle: "destructive"`, message, buttons cancel + `{style: "destructive", default: true}` |
| Delete folder | same, `icon: "sf:folder.badge.minus"` |
| Clear Archive | same, `icon: "sf:archivebox"` |

Arc has no close-window confirmation (spec §5: Shift-Cmd-W closes a window with tabs silently), so den has none either.

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

## plugins

Lets a plugin hide features whose provider isn't loaded.

| Method | Args | Returns |
|---|---|---|
| `get` | – | `{services: [name], plugins: [{id, active}]}` |
| `listening` | `event` | `{listening}`: true when the host or any plugin listens to `event` |

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
| `copy` | `text` | ok. Puts the text on the general pasteboard |

Events: `app.quitRequested`, `app.closeRequested`, `app.openURL {urls}`, `app.defaultBrowser`.
