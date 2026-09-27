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

Owns: the sidebar `spaceHeader` and `footer` slots, the window theme per space page, the space-switch shortcuts (Ctrl-1…9, Cmd-Opt-←/→) and swipe handling.

## `tabs` (plugin `tabs`)

Injects: `spaces`, `webviews`, `content`, `ui`, `storage`, `keys`.

Tab object: `{id, spaceId, kind: favorite|pinned|today, folderId?, title, customTitle?, url, pinnedUrl?, favicon?, webviewId, lastActive, audio}`.
- Favorites are shared across all spaces, so their `spaceId` is `null`.
- A pinned or favorite tab whose `url` differs from its `pinnedUrl` shows the "/" drift marker.

| Method | Args | Returns |
|---|---|---|
| `list` | `spaceId?` (default: current) | `{favorites: [tab], pinned: [tab or folder], today: [tab]}`. Folder: `{id, folder: true, title, open, children: [tab]}` |
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

Events:
- `tabs.changed {spaceId}` fires on any change to the lists.
- `tabs.selected {id, previous}`.
- `tabs.opened {id}`, `tabs.closed {id}`.

Owns:
- the sidebar `header` (URL pill and nav buttons), `favorites`, `pinned` and `today` slots
- the content layout for the selected tab
- tab shortcuts: Cmd-W, Cmd-Shift-T, Cmd-D, Cmd-Shift-K, Cmd-1…9, Ctrl-Tab, Cmd-Opt-↑/↓, Cmd-[ and Cmd-]
- auto-archive of idle today tabs (12 h by default, configurable, and it can be turned off)
- tab suspension of idle tabs through `webviews.suspend`

## `commands` (plugin `commandbar`)

Injects: `tabs`, `spaces`, `ui`, `keys`, `content`.

| Method | Args | Returns |
|---|---|---|
| `register` | `id`, `title`, `icon?`, `keywords?`, `shortcut?` | ok. The command belongs to the calling plugin and is removed when that plugin unloads |
| `run` | `id` | ok |
| `open` | `mode: new\|edit` (Cmd-T / Cmd-L), `query?` | ok |
| `close` | – | ok |

Events:
- `commands.run {id}` fires when a command is picked. Each owning plugin subscribes and acts on its own ids.

Owns: the `overlay.commandBar` slot, and Cmd-T and Cmd-L.

## `peek` (plugin `peek`)

Injects: `tabs`, `webviews`, `content`, `ui`.

- Sets the link policy so that cross-site links from pinned and favorite tabs open in Peek.
- Provides split view: create splits, add panes, separate panes.
- Provides the Little Arc-style quick window for links from other apps, using `app.pendingURLs` and its events.

| Method | Args | Returns |
|---|---|---|
| `open` | `url`, `sourceId?` | ok |
| `close` | – | ok |
| `expand` | – | `{id}`. Turns the peek into a normal tab |
| `split` | `ids`, `layout: horizontal\|vertical\|grid` | `{id}` |
| `unsplit` | `id` | ok |

## Other plugins

These plugins provide no service; they only use the ones above.

- **`theme`:** the theme picker (color grid, up to 3 colors, intensity, grain, light/dark/auto). It writes the result through `spaces.update`.
- **`quit`:** the quit confirmation dialog, through `app.interceptQuit`, with a "don't ask again" setting.

## Ownership rules

- A slot has exactly one owner, as listed above. Other plugins ask the owner through its service instead of writing to the slot.
- Every shortcut is bound by exactly one plugin, and every other action goes through `commands.register`.
- State persists through `storage`, in the owning plugin's namespace.
