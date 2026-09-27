# Plugin services (v0)

Services that den's feature plugins provide to each other. They sit on top of the host services in [host-api.md](host-api.md), and follow the same rules: `(method, args) -> Value` handlers, errors as `{"error": ...}`, and events named `<service>.<event>`.

Each plugin lives in `Plugins/<id>/`, is built with `cordis-build`, and owns only the services listed for it here. If a plugin needs something another plugin owns, it calls that service; it never reaches into another plugin's storage.

## `spaces` (plugin `spaces`)

Injects: `window`, `ui`, `storage`, `keys`.

| Method | Args | Returns |
|---|---|---|
| `list` | – | `[{id, name, icon, theme, profile}]`. `theme` is `{colors: [hex], intensity, grain, appearance}` |
| `current` | – | `{id}` |
| `switch` | `id`, or `direction: next\|prev` | ok |
| `create` | `name?`, `icon?`, `theme?`, `profile?` | `{id}` |
| `update` | `id`, plus any of `name`, `icon`, `theme`, `profile` | ok |
| `delete` | `id` | ok. The deleting plugin or UI confirms first |
| `move` | `id`, `index` | ok |

Events:
- `spaces.changed {spaces}` fires when the list or any space's fields change.
- `spaces.current {id, previous, direction}` fires on every switch. `direction` is `next`, `prev` or `jump`.
- `spaces.editTheme {id}` fires from the space title's "…" button or its "Edit Theme…" menu item. The `theme` plugin opens its picker.
- `spaces.library` fires when the footer's Library button is clicked.

`switch` also takes `animated` (default true). `update` merges a partial `theme` into the space's theme.

UI node ids: `spaces.title:<spaceId>`, `spaces.icon:<spaceId>`, `spaces.new`, `spaces.library`, dialog `spaces.delete:<spaceId>`. First run seeds three spaces (Personal, Work, Side Project) with Arc-like gradients. Storage keys (ns `spaces`): `spaces`, `current`, `nextId`.

Owns: the sidebar `spaceHeader` and `footer` slots, the window theme per space page, the space-switch shortcuts (Ctrl-1…9, Cmd-Opt-←/→) and swipe handling.

## `tabs` (plugin `tabs`)

Injects: `spaces`, `webviews`, `content`, `ui`, `storage`, `keys`, `window`, `app`.

Tab object: `{id, spaceId, kind: favorite|pinned|today, folderId?, title, customTitle?, url, pinnedUrl?, favicon?, webviewId, lastActive, audio}`.
- Favorites are shared across all spaces, so their `spaceId` is `null`.
- A pinned or favorite tab whose `url` differs from its `pinnedUrl` shows the "/" drift marker.

| Method | Args | Returns |
|---|---|---|
| `list` | `spaceId?` (default: current) | `{favorites: [item], pinned: [item], today: [item]}`. An item is a tab, a folder `{id, folder: true, title, open, children: [item]}` (pinned only) or a split `{id, split: true, layout, children: [tab]}` |
| `selected` | – | `{id}` or `null` |
| `open` | `url`, `spaceId?`, `kind?` (default `today`), `background?`, `index?` | `{id}` |
| `select` | `id` | ok |
| `close` | `id` | ok. Closing a today tab archives it; closing a pinned tab only unloads it |
| `pin`, `unpin`, `favorite` | `id` | ok |
| `move` | `id`, `spaceId?`, `kind?`, `folderId?`, `index?` | ok |
| `reset` | `id` | ok. Navigates back to `pinnedUrl` |
| `duplicate` | `id` | `{id}` |
| `rename` | `id`, `title` (empty string clears it) | ok |
| `navigate` | `id?` (default: selected), `url` | ok |
| `clearToday` | `spaceId?` | ok. Shows the "Cleared tabs" toast with undo |
| `undo` | – | ok. Undoes the last sidebar action |
| `archive` | – | `[{id, title, url, favicon, closedAt, spaceId}]` |
| `restore` | `id` | `{id}` |
| `createFolder` | `spaceId?`, `title?`, `tabIds?` | `{id}` |
| `deleteFolder` | `id` | ok. Archives the tabs inside it (the menu confirms first) |
| `split` | `ids` (tab ids), `layout: horizontal\|vertical\|grid` (default horizontal), `focus?` | `{id}` of the split. If one of the tabs is already in a split, the others join it, next to their neighbour in `ids`; otherwise a new split takes the first tab's place. At most 4 tabs. Selects `focus` (default: the last id) |
| `unsplit` | `id`: a split id ("Separate All Tabs"), or a tab id (only that tab leaves, placed after the split) | ok |
| `settings` | `archiveAfterMs?` (0 = never, default 12 h), `suspendAfterMs?` (0 = never, default 30 min) | `{archiveAfterMs, suspendAfterMs}` |

`rename` also renames folders. Tab and webview ids are the same (`tab-<n>`); folder ids are `folder-<n>`, split ids `split-<n>`. Other UI node ids: `tabs.nav`, `tabs.url`, `tabs.divider:<spaceId>`, `tabs.newtab:<spaceId>`, `tabs.split:<splitId>`, dialog `tabs.deleteFolder:<id>`.

**Splits** (Arc §7) are sidebar items like tabs: they sit in favorites, pinned, a folder or today, and their tabs take that kind. Selecting any tab of a split shows the whole split (`content.show` with every pane, the split's layout and that tab focused); focusing another pane (click or Ctrl-Shift-N) makes its tab the selected one. The sidebar row is a `row` node of the split's `tabRow`s, whose menu offers the other layouts and "Separate All Tabs". A split left with one tab (archive, close, move) dissolves into that tab. Splits persist in `state.splits`. The New Tab row and the URL pill call `commands.open` (`new` / `edit`). Dropping a tab on the content calls `peek.split`. Cmd-W first closes an open command bar (`commands.close`) or peek (`peek.close`); Cmd-Shift-T first asks `peek.reopen {after}` (with the newest archive entry's `closedAt`) and restores a tab only if that fails. Links from other apps (`app.openURL` and `app.pendingURLs`, read one timer turn after start) go to `peek.openExternal` first, and open as today tabs only when it returns `claimed: false` or fails. State lives in storage ns `tabs`, keys `state` and `settings`. First run seeds sample favorites, pinned tabs, a folder and today tabs.

Events:
- `tabs.changed {spaceId}` fires on any change to the lists.
- `tabs.selected {id, previous}`.
- `tabs.opened {id}`, `tabs.closed {id}`.

Owns:
- the sidebar `header` (URL pill and nav buttons), `favorites`, `pinned` and `today` slots
- the content layout for the selected tab
- tab shortcuts: Cmd-W, Cmd-Shift-T, Cmd-D, Cmd-Shift-K, Cmd-1…9, Ctrl-Tab, Cmd-Opt-↑/↓, Cmd-[ and Cmd-], plus Ctrl-Z (undo sidebar action, as in Arc's "Use ⌃Z to undo" toast), Cmd-R, Cmd-. (stop), Cmd-S (sidebar) and Cmd-Shift-C (copy URL)
- auto-archive of idle today tabs (12 h by default, configurable, and it can be turned off)
- tab suspension of idle tabs through `webviews.suspend`

## `commands` (plugin `commandbar`)

Injects: `tabs`, `spaces`, `ui`, `keys`, `content`, `storage`. It also calls `peek`, `window`, `webviews`, `app` and the host `plugins` service when they exist.

| Method | Args | Returns |
|---|---|---|
| `register` | `id`, `title`, `icon?`, `keywords?`, `shortcut?` (display text, e.g. `⌘⌥N`), `owner?` (the calling plugin's id) | ok. With `owner`, the command is dropped once that plugin is no longer active (cordis doesn't tell a service who called it, so plugins pass their own id) |
| `unregister` | `id` | ok |
| `list` | – | `[{id, title, icon, shortcut, owner}]`: the commands that can run right now |
| `run` | `id` | ok |
| `open` | `mode: new\|edit` (Cmd-T / Cmd-L), `query?` | ok. `edit` defaults the query to the selected tab's URL, text selected |
| `close` | – | ok |
| `engines` | `engines?: [{keyword, name, url}]` (`url` holds `%s`) | the engine list. The first engine is the default web search. Stored in storage |
| `state` | – | `{open, mode, scope, query, selected, rows}` (for tests and scenarios) |

Events:
- `commands.run {id}` fires when a command is picked. Each owning plugin subscribes and acts on its own ids.

Owns: the `overlay.commandBar` slot, and Cmd-T and Cmd-L (pressing the same one again closes the bar; Esc and a click outside close it too).

**One input** (ids `commandBar` for the node and its actions):
- The first rows: `Reload` (Cmd-L with the URL unchanged), `<url> — Open URL` when the text looks like a URL, `<query> — Search Google` (the default engine), and `Search <site> — Press Tab` when the text is a site-search keyword.
- Then sections ordered by their best match: **Tabs** (open tabs in every space, "Switch to Tab"; picking one selects it, never duplicates), **Actions**, **Spaces**, **History** (pages opened from the bar, then archived tabs).
- **Tab** scopes to a site-search keyword (`g`, `yt`, `gh`, `w`, `maps`, `x` by default), otherwise toggles actions-only mode.
- **Enter** runs the selected row. **Shift-Enter** opens URLs, searches and history in Peek (`peek.open`) when the peek plugin is loaded. Arrow keys and hover move the selection.
- With Cmd-L, a picked URL or search navigates the current tab instead of opening a new one.
- **Ranking:** a match score (title prefix > word prefix > keyword > host > substring; every word must match) plus frecency (uses weighted 100/80/60/40/20/10 by age < 1/4/14/31/90 days/older). Storage ns `commandbar`, keys `usage` and `engines`.

**Built-in commands** (ids `den.*`), hidden when what they need isn't there: New Space, Rename Tab (edits the title in the bar), Pin/Unpin Tab, Duplicate Tab, Copy URL, Copy URL as Markdown, Clear Today Tabs, View Archive (lists the archive in the bar; picking restores), Toggle Sidebar, Edit Theme (emits `spaces.editTheme`; shown only while something listens), Reload Page, Split Right (needs `peek`; pick the tab or URL for the right pane) and Quit den (`app.quit`).

## `peek` (plugin `peek`)

Injects: `tabs`, `spaces`, `webviews`, `content`, `ui`, `keys`, `window`, `storage`.

| Method | Args | Returns |
|---|---|---|
| `open` | `url`, `sourceId?` (the tab it came from; the peek uses its profile) | `{id}` of the peek webview (`peek-<n>`). Replaces an open peek |
| `close` | – | ok |
| `expand` | – | `{id}`. Opens the peek's current URL as a today tab in the current space (selected) and closes the peek |
| `split` | `ids`, `layout: horizontal\|vertical\|grid`, `focus?` | `{id}`. Forwards to `tabs.split` |
| `unsplit` | `id` | ok. Forwards to `tabs.unsplit` |
| `reopen` | `after?` (ms timestamp) | `{id}`, or an error if no peek was closed at or after `after` |
| `openExternal` | `urls` | `{claimed}`. Opens each URL in Little Arc; `claimed: false` when Little Arc is off or the host has no mini windows |
| `settings` | `peekLinks?` (default true), `littleArc?` (default true), `littleArcArchiveMs?` (default 6 h, 0 = never) | the settings |
| `get` | – | `{peek, sourceId, littleArcs: [{window, webview, url}]}` |

Events: `peek.opened {id, url}`, `peek.closed {id}`. `peek.link {id, url, source}` is the link-rule event the plugin listens on.

**Link policy.** Every pinned and favorite tab's webview gets `[{when: crossSite, event: peek.link}]` plus the modifier rules; the `*` default is the modifier rules only: shift-click and option-click (`when: any`) peek from any tab, cmd-click still opens a background tab. The rules are re-sent on every `tabs.changed` and `spaces.changed` (undo can recreate a webview without them), and cleared from tabs that stop being pinned. Settings > "Open a Peek window when clicking on links to other sites" is `settings.peekLinks`.

**Peek actions** (Arc §6): expand with the button or Cmd-O; Split button (the page joins the current tab in a split, focused); close with a click outside, the X, Cmd-W (through `tabs`) or Esc. Esc is bound only while a peek is open. Cmd-Z reopens a just-closed peek for 15 s (den's choice; it is bound in the Edit menu only for that time, so Edit > Undo keeps working otherwise), and Cmd-Shift-T reopens it through `tabs` as long as no tab was archived since.

**Split view shortcuts** (Arc §7): Ctrl-Shift-= adds a pane (a new tab next to the selected one, then `commands.open {mode: edit}` to pick its page; at most 4); Ctrl-Shift-- takes the focused pane out (a today tab is archived, a pinned one is only separated); Ctrl-Shift-1…4 focus a pane.

Storage (ns `peek`): `settings`.

Owns: the `overlay.peek` slot (through `content.peek`), the link policy, Cmd-O, Esc while peeking, Ctrl-Shift-=, Ctrl-Shift--, Ctrl-Shift-1…4.

## Other plugins

These plugins provide no service; they only use the ones above.

- **`theme`:** the theme picker (color grid, up to 3 colors, intensity, grain, light/dark/auto).
  - Opens on `spaces.editTheme {id}` and on the "Theme…" command (`theme.edit`), in the `popover` slot (node id `theme`) anchored to `spaces.title:<id>`.
  - Every picker `change` is previewed with `window.setTheme` on that space's page. A click outside (or switching space) saves through `spaces.update`; Esc (`dismiss {reason: "escape"}`) reverts.
  - Harmony rules: an added color becomes the primary's complement (or a free triadic partner), dragging the primary rotates the others by the same hue step, and secondaries keep their saturation and brightness within 0.35 of the primary's.
  - Appearance is global, as in Arc: a saved appearance is written to every space.
  - Storage ns `theme`: `recent` (the last 8 saved themes; the newest 3 are offered as "Use Recent Theme" commands, `theme.recent:<n>`) and `presetPage`.
- **`quit`:** the quit dialog, through `app.interceptQuit`: app icon, "Quit den?", buttons "Always quit" / "Cancel" (esc) / "Quit" (↩); dialog id `quit`.
  - "Always quit" stores `warn = false` (storage ns `quit`) and turns interception off. The "Ask Before Quitting" command (`quit.warn`) turns it back on.
  - Closing the window never asks (spec §5).
- Both call `commands.register` without injecting `commands` (the command bar is optional), retrying every 500 ms for 30 s until it exists.

## Ownership rules

- A slot has exactly one owner, as listed above. Other plugins ask the owner through its service instead of writing to the slot.
- Every shortcut is bound by exactly one plugin, and every other action goes through `commands.register`.
- State persists through `storage`, in the owning plugin's namespace.
