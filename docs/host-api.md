# den host API (v0)

The host is a small AppKit app. Browser features (spaces, tabs, peek, command bar logic, themes) are plugins. The host gives them services and renders their UI.

- Every service is one handler, `(method: String, args: Value) -> Value`. It has the same shape as `cordis_service_fn` in `cordis.h` (sibling `cordis-swift` package), so each one registers with cordis `PluginHost.provide(name, handler)` unchanged.
- Errors come back as `{"error": "<message>"}`. Success without a result returns `{"ok": true}`.
- Events go on the host bus as `<service>.<event>`, and plugins subscribe with `on`.
- Asynchronous results always arrive as events. No call blocks.

The code lives in `Sources/DenHost/Services/`. `DenRuntime` registers every service with cordis `PluginHost.provide` and re-emits every host event on the `PluginHost` bus, so plugins use `ctx.call/on/emit` and host code uses `DenRuntime.call` / `runtime.plugins.on`.

## Plugins

- Loaded at launch from `den.app/Contents/PlugIns/*.dylib`, `~/Library/Application Support/den/Plugins/*.dylib` and `~/.den/plugins` (`<id>.dylib`, or a `<id>/*.swift` source folder den compiles). A later layer replaces an earlier one with the same file name. `~/.den` is watched, so adding, replacing or removing a plugin there hot-swaps it in the running app ([den-home.md](den-home.md)).
- `--dev-plugins <dir>` also loads `<dir>/*.dylib` (these win over all others) and hot-reloads each file when it is rebuilt.
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
| `listMini` | – | `[{id, webview, key}]`. `key` is true for the key window (the peek plugin's ⌘O acts on it) |
| `focusMini` | `id` | ok. Brings that Little Arc window to the front (the command bar's Windows rows) |

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
| `snapshot` | `id`, `path`, `width?` (pt; a small copy at 2x, for previews), `format?: png\|jpeg` | `{pending}`, then the event `webviews.snapshot {id, path, ok}`. A view that can't draw (not in the window) writes its last snapshot, if any |
| `eval` | `id`, `plugin`, `script` (a function body that `return`s JSON data, ≤ 4 KB), `request?`, `timeoutMs?` (5000) | `{request}`, then `webviews.evalResult {request, webview, ok, value \| error}`. Only for a live page (it never loads or wakes one), in an isolated content world, and only when `plugin` has `session:<the page's host>` |
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
- `webviews.evalResult {request, webview, ok, value | error}`
- One event per link rule, named by the rule's `event` field: `{id, url, source}`.

Every web view sends Safari's user agent for this macOS (`applicationNameForUserAgent` = `Version/<Safari's version> Safari/605.1.15`, read once from Safari's Info.plist). WKWebView's default leaves that suffix out, and Google's sign-in then blocks the browser as an embedded web view.

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
- Overlays: `overlay.commandBar`, `overlay.peek` (`{webview, title}`), `dialog`, `toast`, `popover` (see [Theme picker](#theme-picker-popover)), `overlay.library` (see [Archive / Library](#archive--library-sheet)), `overlay.briefing`, `overlay.connections`, `overlay.extensions` (see [Briefing page](#briefing-page-and-connections-sheet)), `hoverCard` (see [Hover card](#hover-card))

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
| `spaceTitle` | `id`, `title`, `icon?`, `editing?`, `editText?` | `click`, `doubleClick`, `more`, `rename {title}`, `renameCancel` |
| `spaceIcon` | `id`, `icon?` (empty = dot), `title`, `selected`, `spaceId?` (makes it a drop target for dragged rows), `reorderable?` | `click`, `move {index}` (after a drag-reorder, see [Space icon reorder](#space-icon-reorder)) |
| `iconPicker` | `id`, `anchor?`, `title?`, `selected?` (popover slot) | `pick {icon}` (`sf:<name>`, an emoji, or "" to remove), `dismiss {reason?}` |
| `tabRow` | `id`, `title`, `icon`, `selected`, `audio`, `muted?`, `drift` (the "/" marker), `closable=true`, `indent?`, `draggable=true`, `editing?`, `editText?`, `hover=true` | `click {modifiers?}`, `doubleClick`, `close` (also middle-click), `reset` (favicon click while drifted), `mute`, `reorder`, `dropOnContent`, `rename {title}`, `renameCancel`, `hover` (see [Hover card](#hover-card)) |
| `splitRow` | `id`, `selected` (the split is shown), `layout?`, `panes: [{id, title, icon, selected}]` (`selected` = focused pane), `closable=true`, `indent?` | `click {pane}`, `close` (hover X), `reorder` (as target, a tab row can drop `into` it), `dropOnSpace` |
| `folder` | `id`, `title`, `icon?`, `open`, `children`, `editing?` | `toggle`, `reorder` (as target: `position: "into"`), `rename {title}`, `renameCancel` |
| `divider` | `id`, `action?` (label, e.g. "Clear") | `clear` |
| `newTabRow` | `id`, `title?` | `click` |
| `commandBar` | `id`, `query`, `replaceQuery?`, `placeholder?`, `selected`, `headers?` (default true; false draws one flat list), `inputMode?: search\|go` (caret color), `banner?: {text, secondary, primary}` (the default-browser banner), `sections: [{title?, rows: [{id, icon, title, subtitle?, accessory?, keycap?, shortcut?, toggle?}]}]`. `shortcut` ("⇧⌘C") is drawn one keycap per key; `toggle` (bool) draws a switch | `input {text}`, `select {row}` (arrow keys, or hovering a row after the mouse moves), `submit {row, query, modifiers}`, `tab {query}`, `right {row, query}` (→ with the caret at the end), `back` (Backspace in an empty field), `dismiss`, `banner {button: try\|set\|close}` |
| `dialog` | `id`, `title`, `message?`, `icon?`, `iconStyle?: accent\|destructive\|plain`, `buttons: [{id, title, style: default\|cancel\|destructive\|secondary, default?, keycap?}]`, `checkbox?` | `button {button, checked}`. Return presses the `default` button (or the one with `default: true`), Esc the `cancel` one |
| `toast` | `text`, `icon?`, `duration?` (ms; 0 = until dismissed), `id?`, `action?` (button label) | `ui.action {id, action: "toast"}` when the button is clicked |
| `library` | `id`, `title?`, `query?`, `placeholder?`, `clearTitle?`, `empty?`, `items: [{id, title, url?, subtitle?, icon?, closedAt?}]` | `input {text}`, `restore {item}`, `clear`, `dismiss` |
| `themePicker` | `id`, `anchor?`, `colors: [hex]` (≤3), `positions?: [[x, y]]`, `intensity`, `grain`, `appearance: auto\|light\|dark`, `page?` | `change {colors, positions, intensity, grain, appearance}` (live), `commit {…}`, `page {page}`, `dismiss {reason?}` |

**Details that apply to several nodes:**
- **Icons.** A node icon can be `sf:<symbol>`, an http(s) image URL (cached), an absolute image file path (extension icons), `app:icon`, or text/emoji. In a `dialog`, an image icon draws at 62 pt like `app:icon`; only `sf:` symbols get the hero disc.
- **Context menus.** Any node can carry `menu: [item]`, shown as a native context menu. Picking an item emits `menu` with its id (submenu items included). Item shapes:
  - `{id, title, icon?, key?, destructive?, enabled=true, checked?, items?}`. `icon` is an `sf:` symbol. `key` is a chord hint drawn on the right (`cmd+w`), display only; the real binding lives in `keys`. `destructive` draws the title and icon in DestructiveButtonFace red (#F53714). `items` makes it a submenu ("Move to Space ▸").
  - `{separator: true}` and `{header: "Title"}` (section header).
- **Inline rename.** `editing: true` on a `tabRow` or `folder` swaps its title for a text field holding `editText` (default: `title`), all selected and focused. Return or a click elsewhere emits `rename {title}` (trimmed; may be empty), Esc emits `renameCancel`. The plugin then sends the node without `editing`.
- **Drag reorder.** Dragging emits `reorder {source, target, position: before|after|into}` with a haptic tick. Dropping on the web content emits `dropOnContent {source, side: left|center|right}`. Dragging a tab row or folder over a footer `spaceIcon` that has a `spaceId` highlights the icon; dropping there emits `dropOnSpace {source, target, spaceId}` (from the dragged row).
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

### Space icon reorder

A `spaceIcon` with `reorderable: true` can be dragged along the footer strip (`SpaceIconReorder` in Rows.swift). Picking it up lifts it (scale 1.15, a haptic), it follows the pointer clamped to the strip, and the other reorderable icons glide into their new slots as it passes their midpoints (0.2 s, Dia's (0.2, 0.8, 0.2, 1) curve; Reduce Motion snaps), with a haptic tick per slot. On drop it settles into its slot and, if the slot changed, emits `move {index}` (the index among the row's reorderable icons). Nothing is emitted while dragging; the owner re-sends the tree in the new order. Arc's reorder timing was never measured, so the values are estimates (`Tokens.spaceIconLift*`, `spaceIconReorderDuration`).

### Icon picker

`iconPicker` in the `popover` slot: a 300 pt panel (20 pt continuous radius, like the theme picker) placed like it (13 pt right of the sidebar, top level with `anchor`, clamped to the window). A field takes any emoji (typed, pasted or from the Character Viewer) and picks it at once, then grids of 32 SF Symbols and 32 emoji (32 pt cells, 8 columns). "Remove" (shown when `selected` isn't empty) picks "". Esc emits `dismiss {reason: "escape"}`, a click outside `dismiss`. This is den's own design (Arc's icon editor was never measured).

### Archive / Library sheet

`ui.set {slot: "overlay.library", tree: {type: "library", id: "archive", items: tabs.archive()}}` shows the archive as a sheet over the content area (640 wide, 40 pt from the content edges, 20 pt radius, over a black α0.35 dim). Arc's archive view was never measured (spec §12), so its geometry is estimated.

- **Items** take the `tabs.archive` shape directly. Rows are grouped by the day of `closedAt` (ms since 1970): Today, Yesterday, a weekday within the last week, then "Month day". The subtitle defaults to "host · time".
- **Search** filters the items locally by title or URL on every keystroke, so it stays instant. The typed text is also emitted as `input`. Return restores the first match.
- **Restore.** Clicking a row, or its hover "Restore" button, emits `restore {item}`.
- **Clear Archive** emits `clear`. The plugin then confirms with the Clear Archive dialog below, which opens above the sheet.
- **Dismiss.** Esc, the close button or a click on the dim emits `dismiss`; the plugin clears the slot.

### Briefing page and connections sheet

`ui.set {slot: "overlay.briefing" | "overlay.connections" | "overlay.extensions", tree}` renders a `sheet` tree (null clears); they stack in that order. Both show in `ui.get` overlays. This is den's own UI, not Arc's, so every size is an estimate in `Tokens`. Snapshots: `--scenario briefingSheet|connectionsSheet` (`docs/screenshots/briefing-sheet*.png`, `connections-sheet*.png`).

- **Root:** `{type: "sheet", id, style: page|sheet, title, subtitle?, icon?, headerButtons?: [{id, icon, tooltip?}], children}`.
  - `page` covers the content area like a new-tab page: card radius, no dim, and a centered column at most 680 wide with 40 pt top padding.
  - `sheet` is a 560-wide centered panel (20 pt radius) over a black α0.35 dim. It is as tall as its content, up to the content area minus 2×40.
- **Header:** icon, title and subtitle on the left; `headerButtons` then a close button on the right.
- **Children** stack 14 pt apart in a scroll view. Views are reused by type + id, so re-sending the tree keeps the scroll position.
- **Stacking:** connections sits above briefing, and a dialog sits above both.
- **Actions:** `{id: <sheet id>, action: dismiss}` from the close button, Esc or a click on the dim. `{id: <header button id>, action: click}`.

| Node | Fields | Actions |
|---|---|---|
| `heading` | `text`, `subtitle?` (shown above, 13 pt secondary) | – |
| `paragraph` | `text`, `style?: body\|secondary\|caption`, `icon?` (accent-tinted) | – |
| `section` | `id?`, `title`, `accessory?`, `children` | – (caption header over a rounded card, hairlines between rows) |
| `todoRow` | `id`, `title`, `subtitle?`, `icon`, `done`, `url?` | `toggle {done}` (checkbox; flips locally at once), `open` |
| `feedRow` | `id`, `title`, `subtitle?`, `icon`, `time?`, `badge?`, `unread?` | `open` |
| `actionButton` | `id`, `title`, `style: primary\|secondary\|destructive` | `click` |
| `buttonRow` | `children` (actionButtons), `align?: leading\|center` | – |
| `connectionRow` | `id`, `title`, `icon`, `status`, `connected`, `button: {title, style}`, `secondaryButton?: {id, title, style}` | `click`, `secondary` |
| `toggleRow` | `id`, `title`, `subtitle?`, `icon?`, `on` | `toggle {on}` |
| `choiceRow` | `id`, `title`, `subtitle?`, `options: [{id, title}]`, `selected` | `select {option}` |
| `extensionRow` | `id`, `icon`, `title`, `subtitle?`, `on`, `note?` (accent caption, e.g. "Update 2.0") | `toggle {on}` (switch), `open` (row) |

### Hover card

Dia-style previews next to the sidebar. Hovering a `tabRow`, `favoriteTile`, `folder` or `splitRow` (unless it has `hover: false`) for a moment emits `ui.action {id: <row id>, action: "hover"}`. The row's owner asks for content, and whoever owns previews (the `previews` plugin) answers with `ui.set {slot: "hoverCard", tree}`. The host owns the timing; the plugins own the content.

- **Intent** (`HoverIntent`). The first card waits for a 450 ms dwell; passing over rows quickly shows nothing. While a card is up, or for 600 ms after one closed, the next row's card shows at once (no second dwell), and the card glides to it. Moving off the row closes the card after a 200 ms grace, so the pointer can cross the 8 pt gap onto it; the card stays while the pointer is on it. Clicking a row closes its card until the pointer leaves that row. Dia's values aren't in its app resources, so all four are estimates (`Tokens.hoverCard*`).
- **Closing.** The card closes on mouse-out, when an action or row on it is clicked, when anything modal opens (`overlay.*`, `dialog`, `popover`), or when the tree is set to null. Each close emits `ui.action {id: "hoverCard", action: "close", value: {anchor}}`.
- **Anchoring.** A tree must carry `anchor` (the hovered row's id); a tree for a row that is no longer hovered is dropped. The card sits 8 pt right of the sidebar (or of the revealed sidebar overlay), its top level with the row, clamped to the window with a 10 pt margin.
- **Look.** 320 wide, 14 pt continuous radius, PopoverBackground #FAFBFF / #151C30 with a 0.5 pt border (PopoverBorder in dark mode) and PopoverShadow (#151C32 α0.30 / α0.80), spec §3. It fades in with a 4 pt slide over 0.16 s on Dia's (0.2, 0.8, 0.2, 1) curve and fades out in 0.1 s; Reduce Motion turns both off. The geometry is an estimate.
- **Cost.** Nothing runs until a dwell starts: no timers, views or events. The host logs intent-to-visible time (`os_log` category `hoverCard`, `lastShownMs`); the `--scenario preview*` snapshots print it.

Tree: `{type: "hoverCard", anchor, id? ("hoverCard"), icon, title, subtitle?, accessory?, badges?, sections?, image?, imageVersion?, imagePending?, actions?, footer?, empty?, loading?}`

| Field | Shape | Notes |
|---|---|---|
| header | `icon`, `title` (up to 2 lines), `subtitle` (domain), `accessory` (right, e.g. `#482`) | `icon` as in any node |
| `badges` | `[{text, style, icon?}]` | Pills that wrap. `style`: `success`, `failure`, `pending`, `merged`, `accent`, `attention`, `neutral` |
| `sections` | `[{title?, rows: [{id, title, subtitle?, icon?, status?, accessory?, url?}]}]` | `status` tints the icon and accessory with the badge colors. A row with a `url` highlights on hover and emits `open {row, url, anchor}` |
| `image` | local path or http(s) URL | A page snapshot, 16:10, aspect-filled from the top. `imagePending` keeps its space with a placeholder; bump `imageVersion` to reload the same path |
| `actions` | `[{id, title, icon?, style: primary\|secondary, url?}]` | Buttons along the bottom; emit `action {action, anchor, url}` |
| `loading` | bool | Skeleton lines while the first answer is on its way |
| `empty`, `footer` | text | A hint (e.g. "Sign in to …") and a small bottom line |

Actions arrive as `ui.action {id: <tree id>, action, value}`. Snapshots: `--scenario previewGitHub|previewCalendar|previewPage|previewFolder` (`docs/screenshots/preview-*.png`).

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

## Theming

Every den surface takes its colors from one token layer, derived from the current space's theme (colors, intensity, grain), the effective appearance (light, dark, or auto following macOS) and, optionally, the macOS accent color. No surface hardcodes a white card or a fixed brand blue. The code: `ThemeTokens` (Sources/DenHost/Core/ThemeTokens.swift, AppKit-free) wrapped by `Palette` (Toolkit/Primitives.swift).

| Token (`Palette`) | Use | Derivation |
|---|---|---|
| `surface` (= `popover`, `panel`) | dialogs, command bar, popovers, sheets, hover cards, Settings pane | Arc's PopoverBackground (#FAFBFF / #151C30, spec §3) pulled toward the space's colors by intensity. Light surfaces stay at relative luminance ≥ 0.72, dark ones ≤ 0.035 |
| `elevatedSurface` | a layer on a surface: sheet cards, the command bar banner | light: surface → white 55%; dark: surface → white 7% |
| `textPrimary` / `textSecondary` / `textTertiary` (= `panelText`, `panelSecondaryText`) | text on a surface | ForegroundPrimary/Secondary/Tertiary composited on the surface, then pushed to ≥ 7:1 / 4.5:1 / 3:1 |
| `text` / `secondaryText` | text on the sidebar (the window gradient) | checked against every gradient stop: ≥ 4.5:1 / 3:1 |
| `primaryButton` (= `accentStrong`), `onAccent` | primary buttons, selection, focus, toggles, drop zones | the space's first color at saturation ≥ 0.55 (or the system accent), adjusted so its label is ≥ 4.5:1, then moved toward 3:1 against the surface as far as the label allows (a white-labelled accent can’t reach 3:1 on a near-black surface; Arc’s own #3139FB on #151C30 is 2.5:1) |
| `destructive`, `onDestructive` | destructive buttons | DestructiveButtonFace #F53714, darkened just enough for a white label (4.5:1) |
| `toast`, `onToast` | toasts | a deep blend of the theme (Arc's theme-tinted toasts, spec §6), white text ≥ 4.5:1 |
| `hairline`, `rowHover`, `pressed` | dividers, hover and pressed fills | ink/white at α .08/.05/.09 (light) or .10/.07/.12 (dark) |
| `shadowColor`, `shadowOpacity` | panel shadows | PopoverShadow #151C32 α0.30 (light), black α0.60 (dark) |
| `dialogDim`, `sheetDim` | backdrops | black α0.55 (spec §3) / α0.35 |
| `tokens.grain` | grain on surfaces (`SurfaceGrain`) | half the window's grain, the same noise tile |

- **Contrast.** WCAG 2.x relative luminance; targets are AAA (7:1) for primary text, AA (4.5:1) for secondary text and button labels, 3:1 for tertiary text and UI components. `ThemeTokens.ensure(color, on:, target)` moves a color toward black or white until it meets the target, so very light (white, pastel, yellow) and very dark (near-black) themes stay legible. `ThemeTokenTests` checks every token pair for sandy, deep purple, near-black, pastel, white, yellow and no theme, in light and dark.
- **Accent.** Settings > General > Accent color: "Space colors" (default, Arc) or "System accent" (`Palette.accentSource`, stored as `settings` id `general`, key `accent`). A change of the macOS accent re-themes live while it's in use.
- **Live and cheap.** Tokens are computed once per (theme, appearance, accent) and cached. `UIService.refreshPalette()` rebuilds the palette on a theme change or space switch and re-applies it (`Themable.apply`, recursively over the sidebar and `wc.overlays`, plus the hover card and the Settings window) only when the tokens changed; identical themes redraw nothing.
- **Adopting it.** A surface view conforms to `Themable` and reads colors in `apply(_ p: Palette)`: backgrounds from `p.surface` / `p.elevatedSurface`, text from `p.textPrimary`/`textSecondary`/`textTertiary`, primary actions `p.primaryButton` + `p.onAccent`, destructive `p.destructive` + `p.onDestructive`, dividers `p.hairline`, shadows `p.shadowColor`. Views added under `wc.overlays` (or `PanelView` subclasses) are re-themed automatically. For a colored fill with custom text, call `ThemeTokens.ensure(text, on: fill, ThemeTokens.bodyContrast)`. For an HTML surface (error pages), inject `p.tokens.surface.hex`, `textPrimary.hex` and `accent.hex` as CSS variables.
- Native menus follow the window's appearance (light/dark); AppKit doesn't let them take theme colors.
- Snapshot: `docs/screenshots/theming-grid.png` (scenario `themeSample`, see scripts/snapshots.sh).

## settings

The Settings window (⌘,, "Settings…" in the den menu). Plugins contribute sections as typed controls; the host persists values per plugin and emits changes, so plugins react live. The window and its panes are built the first time Settings opens; until then, registering a section only stores it.

| Method | Args | Returns |
|---|---|---|
| `register` | `id`, `title`, `icon?`, `section?`, `order?`, `controls: [control]` | ok. Replaces an earlier registration. With `section`, the controls join that section as a group titled `title`; otherwise `id` is a sidebar section |
| `unregister` | `id` | ok |
| `list` | – | `[{id, title, icon, order}]`: the sidebar |
| `get` | `id`, `key?` | the stored values over the controls' defaults (`{key: value}`), or one value |
| `set` | `id`, `key`, `value` | ok. Stores (storage ns `id`, key `prefs`) and emits `settings.changed` when the value changed |
| `open` | `section?` | ok. Shows the window at that section |
| `close`, `state` | – | ok / `{open, section}` |

Events: `settings.changed {id, key, value}`; `settings.action {id, key, item?, button?, value?}` (list and button rows, and `submit` text fields); `settings.opened {section}`.

Controls are `{key, type, title, subtitle?, default?}`:

| `type` | Extra fields | Control |
|---|---|---|
| `toggle` | – | a switch (Bool) |
| `choice` | `options: [{value, title}]` | a pop-up menu (any value) |
| `text` | `placeholder?`, `submit?` | a text field. Normally the value is set when editing ends; with `submit: true` Return emits `settings.action {value}` and clears the field (an "add" field) |
| `shortcut` | – | a shortcut recorder: click, press a chord (Esc cancels, Delete clears). The value is a `keys` chord (`cmd+shift+b`) |
| `number` | `min`, `max`, `step?`, `unit?`, `labels?: [{value, title}]` | a slider with its value ("30 min", or a label such as "Never" for 0). Set when the drag ends |
| `list` | `items: [{id, title, subtitle?, icon?, buttons?: [{id, title, style?}]}]`, `empty?` | plugin-provided rows, e.g. connections. Buttons emit `settings.action {item, button}`; re-`register` to update the rows |
| `button` | `button: {title, style?}` | a row with one button (`settings.action`) |
| `info` | `value`, `buttons?: [{id, title}]` | read-only text, e.g. a path, with buttons |

`style` is `primary`, `destructive` or plain. The window: a 196 pt sidebar of sections (icon + title; the selected one like a selected tab) on a tint of the space's background, and a pane of rounded cards with hairlines between rows, native controls on the right. It follows the theme tokens and re-themes live. It's den's own design (Arc's Settings window was never measured; spec §11 has its copy).

Sections today:
- **General** (host): accent color, default browser (status + "Make den Default"), `config.toml` and `~/.den` with Open / Show in Finder (a missing `config.toml` is created with commented examples on Open), and problems found in them; plus **Quitting** from `quit` ("Ask before quitting").
- **Tabs** (`tabs`): archive Today tabs after (Never … 30 days), unload idle tabs (0–240 min slider); plus **Links** from `peek` (peek at links from pinned tabs, "Open links from other apps in a mini window", archive unused mini windows).
- **Search** (`commandbar`): search engine, site-search keywords (remove), add a keyword (`kw [Name] url-with-%s`), the default-browser banner.
- **Connections** (`connections`): each provider with Connect / Cancel / Workspaces… / Disconnect.
- **Briefing** (`briefing`): morning briefing on/off, its time, the shortcut that opens it.

Snapshots: `--scenario settings` / `settingsTabs` / `settingsSearch` / `settingsConnections` / `settingsBriefing` (`docs/screenshots/settings-*.png`). Every default and why: [defaults.md](defaults.md).

## keys

| Method | Args | Returns |
|---|---|---|
| `bind` | `chord` (e.g. `cmd+shift+k`, `ctrl+1`, `cmd+opt+left`), `event`, `title?`, `menu?` (File/Edit/View/Tabs/Spaces/Window/any), `payload?` | ok. Emits `event {chord, payload}` |
| `unbind` | `chord` | ok |
| `list` | – | `[{chord, event, title, menu, payload}]` |

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

## updates

The native half of updating. All policy lives in the `updates` plugin ([updates.md](updates.md)).

| Method | Args | Returns |
|---|---|---|
| `info` | – | `{version, build, commit, hostAPI, builtAt, crashed: [id], sparkle, publicKey}` |
| `state` | – | the follow-main updater's `~/.den/updates/state.json`, or null |
| `fetch` | `url` (https), `etag?`, `json?` | `{pending}`. Emits `updates.fetched {url, status, etag, body, value?, bytes, error}` (304 when the ETag matches) |
| `plugins` | – | `[{id, file, layer, sha256}]` for the loaded plugins |
| `installPlugin` | `id, url, sha256, signature, version, hostAPI, permissions?` | `{pending}`. Verifies sha256 + EdDSA (`SUPublicEDKey`), places the file in `~/.den/updates/plugins` (keeping `.prev`) and loads it. Emits `updates.pluginInstalled {id, ok, active, error?}` |
| `rollbackPlugin` | `id` | `{ok, restored}` |
| `kickUpdater` | – | ok. Runs the follow-main LaunchAgent now |
| `sparkleConfigure` / `sparkleCheck` / `sparkleReply` | `channel` / `userInitiated?` / `choice: install\|later\|skip` | ok |

Events: `updates.stateChanged {state}`, `updates.fetched`, `updates.pluginInstalled`, `updates.sparkle {phase: checking|none|found|downloading|ready|installing|error, version?, error?}`.

## config

`~/.den/config.toml` and `~/.den/themes` ([den-home.md](den-home.md)). Nothing is read until after the first window, so a call during launch gets the empty config, and the real one arrives with the events.

| Method | Args | Returns |
|---|---|---|
| `get` | `key?` (dotted, e.g. `plugins.disabled`) | the whole config object, or the value at `key`, or null |
| `themes` | – | `[{name, colors, intensity?, grain?, appearance?, file}]`, sorted by name |
| `paths` | – | `{root, plugins, themes, config, logs}` |
| `errors` | – | `[string]`: problems in config.toml and the theme files, as of the last read |

Events: `config.changed {config}`, `config.themesChanged {themes}`.

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
| `setDefaultBrowser` | `bundleId?` | ok. Asks macOS to make den (or the app `bundleId`) the default for http and https; macOS shows its own confirmation. Emits `app.defaultBrowser {scheme, error}` |
| `defaultBrowser` | – | `{bundleId, name, isDefault}`: the app that opens https links now |
| `info` | – | `{bundleId, version, launchMs}` |
| `copy` | `text` | ok. Puts the text on the general pasteboard |
| `state` | – | `{active, idleSeconds, keyIdleSeconds}`: whether den is frontmost, and the time since any input or a key press |
| `relaunch` | `background?` | ok. Quits cleanly (no quit dialog) and starts den again. With `background`, it doesn't take focus |
| `setAbout` | `credits` | ok. Text for the About panel |
| `showAbout` | – | ok. Shows the About panel (the command bar's "About den") |

Events: `app.quitRequested`, `app.closeRequested`, `app.openURL {urls}`, `app.defaultBrowser`.

## suggest

Web search autocomplete (Google's public suggest endpoint, `client=firefox`) for the command bar.

| Method | Args | Returns |
|---|---|---|
| `query` | `q` | `{q, items}` at once when cached (no network, no event); otherwise `{q, pending: true}`, then `suggest.results {q, items}` |
| `cancel` | – | ok. Drops the pending query |

A pending query is debounced (50 ms) and cancels the one before it, so only the latest query emits; late answers for older queries are still cached. `q` is normalized (trimmed, lowercased, spaces collapsed). The cache is in memory (256 queries). A failed fetch emits `items: []` and isn't cached.

Events: `suggest.results {q, items}`.

## pagestyle

Per-site user stylesheets and appearance for every web view (the `darkmode` plugin's host half). The host applies; the plugin owns the CSS and the choices. Nothing is installed until the first `rules`.

| Method | Args | Returns |
|---|---|---|
| `define` | `name`, `css` (≤ 64 KB) | ok. A named user stylesheet: user origin, main frame only. Redefining updates live pages |
| `rules` | `default: {sheets: [name], appearance?}`, `hosts: {<host>: {sheets, appearance?}}`, `detect?` | ok. `appearance`: `light`, `dark`, or absent (follow den's window). Applied to live pages at once |
| `get` | `id` | `{host, sheets, appearance, tone, supported}` |

Events: `pagestyle.tone {id, host, tone: dark|light, dark}` (`dark`: the page's `prefers-color-scheme` when it measured).

- Sheets are WebKit user stylesheets (`_WKUserStyleSheet`, WebKit SPI present since macOS 10.12): no script, no `<style>` element. They are added and removed on a live page without a reload.
- A rule is picked on each main-frame navigation decision, before the new document exists, so a sheet applies from the first paint (no white flash). The lookup tries the host, then each parent domain, then `default`, ignoring `www.`.
- Web views inherit den's window appearance, so `prefers-color-scheme` matches den unless a rule sets `appearance` for that site.
- `detect` adds one WKUserScript in the isolated `den-style` world. It sets `data-den-tone` on `<html>` from the first opaque background under the viewport center (then the body, then the text color), at the first frame, DOMContentLoaded, load and 1 s later.
- Apple Pay: WebKit removed the "no Apple Pay with injected scripts" rule in 2022 (WebKit commit `aa041a623c`, bug 236254), so neither the sheet nor the detector disables it. Details: [research/dark-mode.md](research/dark-mode.md).

## vault

den's password vault. The host keeps every secret (Keychain + Touch ID); plugins see only origins and usernames.

| Method | Args | Returns |
|---|---|---|
| `enable` | – | ok. Installs the form listener (isolated `den-vault` world, every frame) in web views created from now on |
| `status` | – | `{enabled, mode: acl\|app\|memory, unlocked}` |
| `accounts` | `origin?` | `[{id, origin, username, created}]`. Without `origin`, only while unlocked |
| `save` / `dismiss` | `capture` | ok. Store (Keychain) or drop a captured login |
| `fill` | `webview`, `account`, `request?` | `{request}`. Touch ID, then fills the focused form; `vault.result` |
| `generate` | `webview`, `request?` | `{request}`. A strong password (`abcdef-ghijk2-mNopqr`, ~71 bits, `SecRandomCopyBytes`) into every password field of the focused sign-up form |
| `unlock` | `reason?`, `request?` | `{request}`. Touch ID; the full list stays readable for 5 min or until `lock` |
| `lock` | – | ok |
| `copy` | `account`, `request?` | `{request}`. Touch ID, then the password on the pasteboard (marked concealed, cleared after 60 s) |
| `delete` | `account` | ok, while unlocked |
| `suggest` | `webview`, `items: [{id, title, subtitle?, icon?}]` | ok. A small list under the focused field (`[]` hides) |

Events (never with a password): `vault.focus {webview, origin, field, signup, accounts: [{id, username}]}`, `vault.blur {webview}`, `vault.captured {capture, webview, origin, username, exists}`, `vault.suggestion {webview, item}`, `vault.result {request, method, ok, error?}`.

- **Capture.** macOS 26 has no form-submit callback (`willSubmitForm` is macOS 27), so a listener catches form submits, clicks on submit-like buttons and Enter in a field with a filled password. A capture lives in host memory for at most 5 minutes.
- **Origins** come from `WKFrameInfo.securityOrigin`, never from the page. Only https counts, plus http on loopback for local testing. A frame whose origin differs from its top page's (a cross-origin iframe) is ignored.
- **Fill** targets the frame that reported the focus, re-checks inside the page that the frame's origin is still the account's, and only then writes the fields.
- **Storage.** `kSecClassInternetPassword` items marked "den password". den first tries the data protection keychain with a `.userPresence` access control (`mode: acl`, where the Keychain itself demands Touch ID). That needs a real signature with `keychain-access-groups`, so an ad-hoc den gets `errSecMissingEntitlement` and uses the login keychain (`mode: app`), with den asking for Touch ID (`LAContext`, `.deviceOwnerAuthentication`) before every read. `--demo` and the `vault*` scenarios use an in-memory store.

**Thin-host status.** The generic parts are: per-web-view user styles and appearance (`pagestyle`), a Keychain secret store with a user-presence requirement, and form-field observe/fill restricted to matching secure origins. Code marked `// thin-host: feature-specific, migrate to plugin` should move into the plugins:
- the page-tone heuristic
- the login and sign-up field heuristics
- the capture/save flow
- unlock and pasteboard timings, and the prompt strings
- the password format
- the suggestion popup (a generic anchored-popup `ui` node)
- the `overlay.passwords` slot name

## webext

The `webext` service: Chrome and Firefox extensions on Apple's `WKWebExtension` engine (the one Safari uses): Manifest V2 and V3, `chrome.*` and `browser.*`. Background and limits: [research notes](research/extensions-on-webkit.md). It is the platform bridge; the `extensions` plugin draws the Extensions page on top of this ([plugin-services.md](plugin-services.md#extensions-plugin-extensions)).

| Method | Args | Returns |
|---|---|---|
| `list` | – | `[ext]` (below) |
| `get` | `id` | `ext` |
| `install` | `path` (unpacked folder, `.crx`, `.xpi` or `.zip`), `request?` | `{request, pending}`. Copies/unpacks, validates, asks, loads |
| `installFromStore` | `url` (a Chrome Web Store or Firefox Add-ons item page), or `source: chrome\|firefox` + `id` (CWS id / AMO slug), `request?` | `{request, pending}` |
| `pickFile` | – | ok. An open panel; the pick goes to `install` |
| `uninstall` | `id` | ok. Unloads it, deletes its WebKit data, folder and icon |
| `setEnabled` | `id`, `enabled` | ok. Loads or unloads it |
| `setPinned` | `id`, `pinned` | ok. Pinned ones show in the URL pill on hover |
| `setSiteAccess` | `id`, `mode: all\|click\|sites`, `sites?` | ok. `all` grants every host it asked for, `click` only the tab you click it on (`activeTab`), `sites` the listed hosts |
| `allowSite` | `id`, `site`, `allowed` | ok. Adds or removes one host (switches `click` to `sites`) |
| `checkUpdates` | `force?` (true) | `{pending}`, then `webext.updates` |
| `action` | `id` | ok. Runs its toolbar action on the selected tab (a popup, or `action.onClicked`) |
| `menu` | `open?` (true) | ok. The extensions menu under the URL pill |
| `closePopup` | – | ok |
| `openOptions` | `id` | ok. Its options page in a new tab |
| `settings` | `storeButtons?` | `{storeButtons}`: "Add to den" on store pages (default on) |
| `state` | – | `{controller, ready, loaded: [id], popup, menu, prompts}` (tests) |

`ext`: `{id, name, version, description, source: chrome|firefox|local|home, storeId?, storeURL?, enabled, pinned, icon (PNG path), siteAccess, sites, permissions: [line], unsupported: [permission], loaded, hasAction, hasPopup, hasOptions, badge, manifestVersion, background: none|on demand|persistent, errors, updateAvailable?}`. `permissions` are plain-language lines worded like Chrome's install warnings ("Read and change all your data on all websites", "Block content on any page"). `unsupported` lists manifest permissions WebKit doesn't know (e.g. `userScripts`, `offscreen`).

Events: `webext.changed {extensions}` (the list), `webext.installing {request, …}`, `webext.installed {request, id, name, update}`, `webext.failed {request, error}` (`error: "cancelled"` when the user said no), `webext.uninstalled {id, name}`, `webext.updates {checked, updated: [id], available: [id]}`, `webext.openPage` (the menu's "Manage Extensions").

**Cost.** Nothing exists while nothing is installed: the registry file is read once, at the first web view (one failed file read), and no `WKWebExtensionController` is made. The first install creates it, rebuilds the live web views with it (they keep their back/forward state), and every later configuration gets it. At launch with extensions installed, a web view's first load waits (at most 2 s) until they are loaded, so blockers and document-start scripts apply to the first page. Service workers and non-persistent background pages are started and stopped by WebKit; den never calls `loadBackgroundContent`. Measured with uBlock Origin Lite: den's process grows from 29–30 MB to 105–107 MB, no extra WebContent process at rest, and ad blocking starts 14–31 s after loading (five runs) while WebKit compiles its rulesets ([research notes](research/extensions-on-webkit.md#dens-implementation-measured-2026-09-27-macos-265-builddenapp)).

**Storage.** `~/Library/Application Support/den/Extensions/` (next to `storage/`): `extensions.json` (the registry: id, version, source, store id, enabled, pinned, site access, granted permissions and patterns), `<id>/` (the unpacked extension) and `icons/<id>.png`. Grants are re-applied on every load. The controller is persistent (`WKWebExtensionController.Configuration(identifier:)`), and each context's base URL is `webkit-extension://<id>/`, so the extension's own storage survives relaunches. Any other `--storage` root uses `<root>/extensions` and a non-persistent controller. Unpacked folders in `~/.den/extensions/` load in place as development extensions ([den-home.md](den-home.md)).

**Ids.** A Chrome Web Store install keeps its store id (so `runtime.id` matches Chrome's); otherwise the manifest `key` gives the Chrome id, then the gecko id or the path gives a stable a–p id.

**Installing.** Store items: Chrome's update service (`clients2.google.com/service/update2/crx?response=redirect&prodversion=<current stable Chrome>&x=id%3D<id>…`) returns the CRX; den strips the CRX2/CRX3 header, unpacks the ZIP with `ditto` and checks `manifest.json` (valid JSON, `manifest_version` 2 or 3, `name`, `version`). AMO items come from the v5 API's `current_version.file.url` and are checked against its SHA-256. Every install shows an Arc dialog with the extension's icon, "Add “Name” to den?", what it can do, and what WebKit can't provide; nothing is written until the user clicks **Add Extension**. Runtime requests (`permissions.request`) show the same dialog ("“Name” wants more access").

**Store pages.** On `chromewebstore.google.com` and `addons.mozilla.org` item pages, a small script in an isolated content world (`den-store`, invisible to the store's scripts) hides the store's own install button and puts an Arc-style "＋ Add to den" pill in its place ("✓ Added to den" once installed). A click posts `{source, id}`; den re-derives both from the page URL before downloading. Other pages cost one host-name comparison per load. The button can be turned off (`settings {storeButtons: false}`).

**Updates.** Only with a store extension installed: a daily `schedule.interval` (`webext.updateCheck`), plus one check a minute after launch if the last is older than a day. Chrome items are checked in one Omaha request (`response=updatecheck`, `x=id=<id>&v=<version>` each); AMO items through the API. An update that asks for nothing new installs silently; one that asks for more waits for approval (`updateAvailable`, "Update to …" on its details).

**UI** (host-drawn; Arc's extension UI was never measured, so sizes are `Tokens.extension*` estimates):
- **URL pill.** While anything is installed, hovering the pill shows the pinned extensions' toolbar icons (with badges) and a puzzle button, left of the copy button. Clicking an icon runs its action; the puzzle opens the menu.
- **Menu.** 300 wide, PopoverBackground, below the pill: every enabled extension (click runs it, the pin toggles it in the pill), then "Manage Extensions" (`webext.openPage`) and "Get Extensions" (Chrome Web Store in a tab).
- **Popups** render the extension's popup web view in the same popover, sized like Chrome: its fit-content width and scroll height, between 25x25 and 800x600, re-measured while open. A click outside or Esc closes it.

What WebKit leaves out (no blocking `webRequest`, `identity`, `downloads`, `history`, `bookmarks`, side panels…) stays out: `unsupported` and the dialog say so. Keyboard `commands` and extension context-menu items aren't wired into den's menus yet.

## Connections, AI and scheduling

Host services behind the `connections`, `slack`, `github` and `briefing` plugins. Plugins have no Foundation, sockets or ML, so the host does the I/O. Asynchronous results arrive as `<service>.result {id, ...}`; every async method takes an optional `id` and returns `{id}`.

### Permissions

A plugin declares what it may reach in `Plugins/<id>/permissions.json`, e.g. `{"permissions": ["session:slack.com"]}`. `bundle.sh` copies it to `Contents/PlugIns/<id>.json`, and `PluginLoader` grants it when the plugin loads (user and dev plugins use the same sidecar next to their dylib). Anything undeclared is denied.

- `session:<domain>`: cookies and site storage of `<domain>` and its subdomains, and `net.fetch` there with cookies.
- `net:<domain>`: `net.fetch` there without cookies.

cordis doesn't tell a host service who called it, so `session` and `net` calls pass `plugin: "<own id>"` (as `commands.register` passes `owner`). Plugins are native code in den's process: this keeps each plugin to the sites it declared; it is not a sandbox.

### session

Reads what a signed-in site exposes, from den's own `WKWebsiteDataStore` for a profile. Nothing leaves the process or is persisted; plugins keep what they read in memory.

| Method | Args | Result |
|---|---|---|
| `cookies` | `plugin`, `domain`, `profile?` | `session.result {id, ok, cookies: [{name, value, domain, path, secure, httpOnly, expires?}]}` (HttpOnly included) |
| `eval` | `plugin`, `origin`, `script` (≤ 4 KB function body that `return`s JSON), `profile?`, `timeoutMs?` (10 s) | `session.result {id, ok, value}` or `{id, ok: false, error}` |

`eval` runs in a hidden, never-shown `WKWebView` in that profile's data store, on an empty local document whose origin is `origin` (loaded with `loadHTMLString(baseURL:)`, so no request is made), in an isolated content world. That document sees the origin's localStorage (verified in `ConnectionsTests`). Any navigation is refused; the view is destroyed after the result.

### net

| Method | Args | Result |
|---|---|---|
| `fetch` | `plugin`, `url`, `method?` (GET), `headers?`, `body?` (string), `as?: json\|text`, `session?` (false), `profile?`, `timeoutMs?` (20 s, max 60), `maxBytes?` (5 MB, max 20) | `net.result {id, ok, status, headers, json\|text, error?}` |
| `cancel` | `id` | ok |

- `session: true` copies the profile's cookies for that URL (domain, path, secure, expiry rules) into the request. A `Cookie` header from the plugin is ignored.
- Ephemeral `URLSession`: no cookie jar, no disk cache; responses never write cookies back. `set-cookie` is dropped from `headers` (names lowercased).
- Redirects are followed only to hosts the plugin may fetch, with the cookie header dropped; otherwise the 3xx comes back.
- `ok` is true for any HTTP response (check `status`). Over `maxBytes`: `error: "too large"`.

### ai

Apple's on-device Foundation Models, for summaries and todos only. The context window is read at runtime (4,096 tokens here); inputs are chunked at 3 characters per token with 1,200 tokens kept free, summarized per chunk (map) and merged (reduce). A chunk that still overflows is split in half and retried. Requests run one at a time.

| Method | Args | Result (`ai.result`) |
|---|---|---|
| `availability` | – | returns `{available, reason?, contextSize}` directly. `reason`: `deviceNotEligible`, `appleIntelligenceNotEnabled`, `modelNotReady` |
| `summarize` | `items: [string]`, `instructions?` | `{id, ok, text, ms}` |
| `brief` | `sources: [{name, items: [string]}]`, `instructions?` | `{id, ok, text, sources: [{name, text}], ms}`: one summary per source, then one combined brief |
| `todos` | `items: [{id, text}]`, `max?` (8), `instructions?` | `{id, ok, todos: [{item, title}], ms}`: guided generation (`@Generable {actionable, title}`), one request per item so a todo can't be attached to another item; non-actionable items are dropped |

When the model can't run: `{id, ok: false, error: "unavailable", reason}`; callers fall back to plain lists.

### schedule

| Method | Args | Returns |
|---|---|---|
| `daily` | `id`, `hour`, `minute` | ok. Fires `schedule.fire {id, reason: "time"}` daily. If den wasn't running or the Mac slept through that time, fires once with `reason: "catchup"` at registration or wake. The last fire time persists (storage ns `_schedule`); a first-ever registration doesn't catch up |
| `interval` | `id`, `ms` (min 60 s), `wake?` | ok. `{id, reason: "interval"}`, and `{id, reason: "wake"}` after wake when `wake` |
| `cancel` | `id` | ok |
| `list` | – | `[{id, kind, hour?, minute?, ms?, next}]` |
| `clock` | `ms?` | `{ms, hour, minute, weekday, date ("Sunday, September 27"), time ("8:02 AM"), offsetMinutes}`: local time for plugins |

Registrations live in memory (plugins re-register at launch). The clock is checked every 30 s and on wake.

### Development mock

`MockServices` (`Sources/DenHost/Scenarios/`) is a local fake Slack + GitHub on 127.0.0.1: a sign-in page that sets Slack's HttpOnly `d` cookie and `localConfig_v2` (two workspaces with `xoxc-` tokens), github.com's signed-in cookies, the Slack Web API methods den uses (token + cookie required, else `invalid_auth`), and github.com search JSON shaped like a real response. Tests and the `briefing*`, `connectToast` and `connectionsSettings` scenarios point the plugins at it (storage `slack.endpoints`, `github.base`) and use the in-memory `private` profile.
