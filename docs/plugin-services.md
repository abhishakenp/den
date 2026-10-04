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
| `duplicate` | `id` | `{id}`. A new space right after it, with its icon, theme and profile, named "<name> Copy" |

Events:
- `spaces.changed {spaces}` fires when the list or any space's fields change.
- `spaces.current {id, previous, direction}` fires on every switch. `direction` is `next`, `prev` or `jump`.
- `spaces.editTheme {id}` fires from the space title's "…" button or its "Edit Theme…" menu item. The `theme` plugin opens its picker.
- `spaces.library` fires when the footer's Library button is clicked.

**Download indicator.** While something downloads, a download arrow (`spaces.downloads`) sits next to the Library button with a progress ring in the accent (all running downloads together, redrawn in 2% steps); when a download finished and you haven't looked at Downloads yet, a dot instead. Otherwise it isn't there. Its tooltip is "Downloads (⌥⌘L)"; a click calls `downloads.open`. It follows the host's `downloads.changed` event only: nothing is read at launch.

`switch` also takes `animated` (default true). `update` merges a partial `theme` into the space's theme.

**Space menu** (Arc's SpaceMenu, den's wording). Right-clicking a footer space icon or the space title shows the same menu: Rename Space, Change Space Icon…, Edit Theme Color…, Profile ▸ (Default, each profile a space uses, New Profile), Duplicate Space, Move Left, Move Right, New Space, Delete Space…. Everything goes through this service.
- **Rename** edits the title in place (`editing` on the `spaceTitle` node); double-clicking the title does the same. Return commits, Esc cancels, an empty name keeps the old one. From another space's icon, den switches to that space first.
- **Change Space Icon…** opens the host `iconPicker` in the `popover` slot (node id `spaces.iconPicker`), anchored to the icon or title it came from: a field for any emoji, 32 symbols, 32 emoji, and Remove (the footer then shows a dot).
- **Profile ▸ New Profile** names the profile after the space ("Work", "Work 2" if taken). A toast confirms the change. Pages opened after the change use the new profile's cookies and site data.
- **Delete Space…** confirms with the Delete Space dialog. It's disabled for the last space.
- **Drag to reorder.** Footer icons carry `reorderable: true`. Dragging one sideways lifts it (a 1.15× scale), the others slide into their new slots as it passes their midpoints (0.2 s on Dia's (0.2, 0.8, 0.2, 1) curve; Reduce Motion snaps), with a haptic tick per slot and one on drop. The drop emits `move {index}`, and the plugin calls `spaces.move`, which persists the order. A click without a drag still switches.

UI node ids: `spaces.title:<spaceId>`, `spaces.icon:<spaceId>`, `spaces.new`, `spaces.library`, `spaces.downloads`, `spaces.iconPicker`, dialog `spaces.delete:<spaceId>`. First run seeds three spaces (Personal, Work, Side Project) with Arc-like gradients. Storage keys (ns `spaces`): `spaces`, `current`, `nextId`.

Owns: the sidebar `spaceHeader` and `footer` slots, the window theme per space page, the space-switch shortcuts (Ctrl-1…9, Cmd-Opt-←/→) and swipe handling.

## `tabs` (plugin `tabs`)

Injects: `spaces`, `webviews`, `content`, `ui`, `storage`, `keys`, `window`, `app`.

Tab object: `{id, spaceId, kind: favorite|pinned|today, folderId?, title, customTitle?, url, pinnedUrl?, favicon?, webviewId, lastActive, audio, muted}`.
- Favorites are shared across all spaces, so their `spaceId` is `null`.
- A pinned or favorite tab whose `url` differs from its `pinnedUrl` shows the "/" drift marker.

| Method | Args | Returns |
|---|---|---|
| `list` | `spaceId?` (default: current) | `{favorites: [item], pinned: [item], today: [item]}`. An item is a tab, a folder `{id, folder: true, title, open, icon?, children: [item]}` (pinned only) or a split `{id, split: true, layout, children: [tab]}` |
| `selected` | – | `{id}` (`{id, private: true}` in a private window) or `null` |
| `open` | `url`, `spaceId?`, `kind?` (default `today`), `background?`, `index?`, `webview?` | `{id}`. `webview` adopts an existing web view (a peek or Little Arc page, which keeps its history and state); its id becomes the tab id. In a private window (and no `spaceId`), a private tab |
| `closedWindows` | – | `{count}`: normal windows closed this session that `window.reopen` can bring back |
| `select` | `id` | ok |
| `close` | `id` | ok. Closing a today tab archives it; closing a pinned tab only unloads it |
| `pin`, `unpin`, `favorite` | `id` | ok |
| `move` | `id`, `spaceId?`, `kind?`, `folderId?`, `index?` | ok |
| `reset` | `id` | ok. Navigates back to `pinnedUrl` |
| `duplicate` | `id` | `{id}` |
| `act` | `id`, `action`, `value?` | ok. A hover-card verb on tab `id`: `pin`, `unpin`, `reset`, `duplicate`, `copy` (link + toast), `mute`, `unmute`, `move {spaceId}`, `close` (archives a Today tab), `split` (the active tab + this one, this one on the right; on the active tab or inside a split it adds a pane like ⌃⇧=) |
| `rename` | `id`, `title` (empty string clears it) | ok |
| `setIcon` | `id` (tab or folder), `icon` (an emoji or `sf:<symbol>`; `""` removes it) | ok. Replaces the favicon (tabs) or folder symbol on the row, favorites tile and hover card; undoable |
| `navigate` | `id?` (default: selected), `url` | ok |
| `clearToday` | `spaceId?` | ok. Shows the "Cleared tabs" toast with undo |
| `unloadSpace` | `spaceId?` | `{unloaded}`. Discards every live tab of the space except the one on screen (⌃⌘U, the space's menu); the host still refuses tabs with media, capture or unsaved input. Shows a toast |
| `keepActive` | `id?` | `[host]`. With `id`, toggles that tab's site on the "Always keep active" list (never idle-unloaded, media never paused) |
| `energy` | – | `{batterySaver, saving, battery, lowPower, suspendAfterMs, keepActive}`: what the energy policy sees now (`suspendAfterMs` is the effective one) |
| `undo` | – | ok. Undoes the last sidebar action |
| `archive` | – | `[{id, title, url, favicon, closedAt, spaceId}]` |
| `restore` | `id` | `{id}` |
| `addToArchive` | `url`, `title?`, `favicon?`, `spaceId?` (default: current) | `{id}` of the new archive entry (for pages that were never tabs, like an auto-closed Little Arc) |
| `createFolder` | `spaceId?`, `title?`, `tabIds?` | `{id}`. At the first tab's place: a Today tab makes a Today folder (a group), named after the tabs' sites |
| `newTab` | `folderId?` (default: the selected tab's folder) | ok. A blank tab at the end of the folder, selected, then `commands.open {mode: edit}` (⌥⌘T; the folder card's "New Tab"). Without a folder it's ⌘T |
| `deleteFolder` | `id` | ok. Archives the tabs inside it (the menu confirms first) |
| `split` | `ids` (tab ids), `layout: horizontal\|vertical\|grid` (default horizontal), `focus?` | `{id}` of the split. If one of the tabs is already in a split, the others join it, next to their neighbour in `ids`; otherwise a new split takes the first tab's place. At most 4 tabs. Selects `focus` (default: the last id) |
| `unsplit` | `id`: a split id ("Separate All Tabs"), or a tab id (only that tab leaves, placed after the split) | ok |
| `library` | `open?` (default true), `section?` (`archive` default, or `downloads`) | ok. Opens (or closes) the Library sheet |
| `settings` | `archiveAfterMs?` (0 = never, default 24 h), `suspendAfterMs?` (0 = never, default 5 min of den-frontmost time: then the page is discarded, see below), `groupLinks?` (default true), `batterySaver?` (default true) | `{archiveAfterMs, suspendAfterMs, groupLinks, batterySaver}`. The host Settings section (id `tabs`) also has `sameTabInWindows` (default off, see Windows) |
| `pillButtons` | `webview`, `owner` (the calling plugin), `buttons: [{id, icon, tooltip?, active?}]` (`[]` removes) | ok. Another plugin's page actions in the URL pill while that web view's tab is selected (the `pagetools` Reader and Translate buttons). A click emits `ui.action {id: <button id>, action: click, value: {webview}}` |
| `badge` | `host`, `text` (`""` removes), `owner?` | ok. A short chip at the bottom of every favorite tile on that host (`favoriteTile.badge`): the `calendar` plugin's "in 8m" countdown |
| `newLiveFolder` | `source` (`github`), `spaceId?` | `{id}`. A live folder at the top of the space's pinned tabs (below) |

`rename` also renames folders. Dropping a tab row or folder on another space's footer icon moves it to that space, keeping its section (Arc; a favorite lands in that space's today tabs). In the sidebar, double-clicking a tab row or picking "Rename…" (tabs) / "Rename Folder…" (folders) from the context menu edits the title in place (Arc §2): Return commits, Esc cancels, an empty tab title resets to the page's. A name typed with an emoji first ("🚀 Launch") makes that emoji the icon and the rest the title (just an emoji changes only the icon). "Change Icon…" in the tab and folder menus, or clicking the row's icon while renaming, opens the host `iconPicker` in the popover slot (id `tabs.iconPicker`, anchored at the row); "Remove Icon" appears once one is set. Tab items carry `icon` (the chosen one, or null). Tab and webview ids are the same (`tab-<n>`); folder ids are `folder-<n>`, split ids `split-<n>`. Other UI node ids: `tabs.nav`, `tabs.url`, `tabs.divider:<spaceId>`, `tabs.newtab:<spaceId>`, dialog `tabs.deleteFolder:<id>`.

**Splits** (Arc §7) are sidebar items like tabs: they sit in favorites, pinned, a folder or today, and their tabs take that kind. Selecting any tab of a split shows the whole split (`content.show` with every pane, the split's layout and that tab focused); focusing another pane (click or Ctrl-Shift-N) makes its tab the selected one. The sidebar item is a `splitRow` node (id = the split id): a segment per pane, the focused one in a chip while the split is shown. Clicking a segment selects that tab, its hover X separates the split, a tab row dropped into its middle joins the split, and its menu offers the other layouts and "Separate All Tabs". Splits can be dragged like tabs and dropped on a footer space icon. A split left with one tab (archive, close, move) dissolves into that tab. Splits persist in `state.splits`. The New Tab row and the URL pill call `commands.open` (`new` / `edit`). The URL pill's context menu: **Paste and Go** / **Paste and Search** (a `paste` item: `app.pasteboard`, then `commands.paste {mode: edit}`; without the command bar an address still opens), and for a web page **Copy Link** ⇧⌘C (⌥: as Markdown) and **Share…** (`app.share`, anchored at the pill). A tab's menu has **Share…** too, anchored at its row. Copy toasts name what was copied ("Copied link · example.com/path…"). Dropping a tab on the content calls `peek.split`. Cmd-W first closes an open command bar (`commands.close`) or peek (`peek.close`); Cmd-Shift-T first asks `peek.reopen {after}` (with the newest archive entry's `closedAt`) and restores a tab only if that fails. Links from other apps (`app.openURL` and `app.pendingURLs`, read one timer turn after start) go to `peek.openExternal` first, and open as today tabs only when it returns `claimed: false` or fails. State lives in storage ns `tabs`, keys `state` and `settings`. First run seeds sample favorites, pinned tabs, a folder and today tabs.

**Windows** (`TabsWindows.swift`, host [window](host-api.md#window)). Every normal window shows the same spaces and tabs and keeps its own place (a space and a tab): `currentSpace` and `selected` describe the normal window used last, `places` every other one. When another window becomes active (`window.activated`) its place becomes current (`spaces.switch` without animation; the window already shows its page, so `spaces.current` then only records the space). With more than one normal window the header, favorites and space pages render once per window with `ui.set {window}`, each marking its own tab; `spaces` does the same for the footer's current space. With one window renders address no window and the state has no `windows` key, exactly as before.
- **⌘N** (`window.opened` without `restored`): the space of the window in front, nothing shown, and the command bar opens (`commands.open {mode: new}`) once it's in front.
- **One tab, one window.** Selecting a tab another window shows focuses that window instead (`window.focus`). Setting **Let a tab open in two windows** (`sameTabInWindows`, Settings ▸ Tabs, default off) selects it here; the host moves the live page and the other window shows "Open in another window" until it's active again. Closing a tab that a background window shows leaves that window empty.
- **Private windows** (`window.opened {private}`): tabs `ptab-<n>` with web view profile `private:<window>`, kept in `privates`/`ptabs` only, never in `tabs`, the state, the archive, the MRU or the undo stack. The window's sidebar is rendered for it alone: its URL pill, "Private window", a "New Private Tab" row, its tabs (Copy Link, Close Tab), and "Nothing here is saved". `open` (the command bar), links from its pages (`webviews.newWindow`), dropped links, ⌘W, ⌘1…9, next/previous tab, back/forward/reload, ⇧⌘C and ⌘L act on it while it's in front. ⌘W closes a private tab for good; closing the window closes all of them. The command bar doesn't count anything opened there (its `bump` checks `window.get {private}`).
- **Reopen.** A closed normal window is remembered (newest first, up to 10, this session): `{id, spaceId, tab, closedAt}`. ⇧⌘T right after a window close, or `window.reopen` (File ▸ Reopen Closed Window, enabled when `closedWindows.count` > 0), opens it again with its old id (so its frame), space and tab (or split). The tabs themselves never left.
- **Restore.** With several windows the state keeps `windows: [{id, spaceId, tab}]`, the window in use first. At launch the first is the window den opens with (its space and selection were already saved); each other opens again in the background (`window.new {id, page, focus: false, restored: true}`) showing its tab. Private windows are never saved.

**Links from pages.** `webviews.newWindow` opens a today tab in the page's space: selected for `target=_blank`, in the background when it says `background: true` (⌘-click, middle-click, "Open Link in New Tab"). With `webview` (a pop-up the host made from a click, related to its opener; host-api "Pop-ups") it adopts that web view as a selected tab right after the opener (in a private window, a private tab after it); `webviews.closeRequested` (the page called `window.close()`) closes the tab and selects the opener again. `webviews.popupBlocked` puts a "Pop-up blocked" button (`tabs.popups`) in that page's URL pill; its click calls `webviews.openBlocked` and, outside private windows, `shields.site {host, popups: allow}` so the site's pop-ups open from then on.

**Groups** (Dia's ⌘-click groups, as Today folders; dia-ui-spec §6). A link click (`newWindow` with `background`, true or false) from a Today tab that isn't in a split, with `settings.groupLinks` on:
- From a plain tab: the new tab goes right after the source, then both are wrapped into an `auto` folder at the source's place (a checkpoint sits between the two, so ⌃Z ungroups and keeps both tabs). The title is the sites' names ("Wikipedia", "WebKit & Apple").
- From a tab in a Today folder: the new tab joins it after the source and every tab the source already opened (`opener`, runtime only).
- Naming: if `ai.availability` says available, the folder is `pending` (the header shimmers) until the new tab's first title (or 4 s), then `ai.summarize {id: "tabs.name:<folder>", items: titles, instructions}`; the reply is cleaned (first line, no quotes or punctuation, ≤ 4 words, ≤ 32 characters) and sent once with `reveal: true`. A user rename cancels it and makes the folder manual.
- `auto` folders dissolve into their last tab at one child; manual Today folders are removed when empty; pinned folders persist. A folder moved to the pinned section stops being `auto`.
- Rows: ⌘-click / ⇧-click in the sidebar pick tabs into a multi-selection (`highlighted` rows); ⌃⌘N (`tabs.key.newFolder`) makes a folder of the selected tab and those, name open for editing. A collapsed folder sends its selected tab as `closedChildren`; selecting a tab inside never opens it.
- Keys: ⌥⌘T `tabs.key.newTabInFolder`, ⌃⌘N `tabs.key.newFolder`, ⌥⌘W `tabs.key.closeOthers` (archives every other Today tab, undoable). Tab menus carry each item's chord as `key` and ⌥ `alternate`s: Copy Link as Markdown, Close Other Tabs, Close Tabs Above (after Close Tabs Below). `window.dropURLs` (links, URLs or files dropped on the sidebar or a page) opens each as a today tab, the last one selected.

**Library** (Arc's Archive). The footer's Library button (`spaces.library`) opens the archive in the host's `overlay.library` sheet (node id `tabs.library`), newest first, grouped by day. Search filters in the sheet. Clicking an entry (or Return on the first match) restores it as a selected today tab in its space and closes the sheet. "Clear Archive" asks first (dialog `tabs.clearArchive`), then empties the archive and closes the archived pages' web views. Esc, the close button or the dim closes it. ⌘Y / ⇧⌘L open it (and switch to Archive from Downloads).

**Downloads** (Library ▸ Downloads, ⌥⌘L, `TabsDownloads.swift`), when the host has a `downloads` service ([host-api.md](host-api.md#downloads)). The Library header then shows two tabs with their shortcuts, "Archive ⌘Y" and "Downloads ⌥⌘L". Rows, newest first: **In Progress** ("18.4 MB of 42 MB · 7 s left" with a progress bar; Pause and Cancel on hover; "Paused · …" with Resume), then finished ones by day ("2.3 KB · 3:41 PM", Show in Finder and Remove from List on hover; click opens the file, drag it out as the file), failed or cancelled ones faded with Try Again, and moved or deleted files faded with Download Again. **Archived** at the end: finished downloads older than Settings ▸ Tabs ▸ Downloads ▸ "Archive finished downloads" (Never, 1 day by default, 7 or 30 days; id `tabs.downloads`), checked when a download finishes and when the section opens (no timer). "Clear List" removes everything that isn't running; the files stay. Opening the section marks finished downloads as seen (the sidebar dot goes). Sizes are Finder's (1000-based). Toasts: "Downloading “file”" (Show) when one starts and "Downloaded “file”" (Show in Finder) or "Couldn’t download “file”" (Show) when it ends (toast id `tabs.downloadToast`). `downloads.show` (the command bar's Downloads destination, the sidebar indicator) opens the section. Key: ⌥⌘L `tabs.key.downloads` (History menu, "Downloads"), which closes it again when it's showing.

**Live folders** (Zen's live folders, Dia's live groups; `Plugins/tabs/LiveFolders.swift`). A pinned folder with `live: "github"` holds no tabs: its rows are the source's latest `feed.items` (review requests, failing CI, assigned issues, mentions and your own open PRs). Command "New GitHub Live Folder" (registered while GitHub is connected) or `tabs.newLiveFolder`.
- Rows are `tabRow`s with id `live:<folderId>:<itemId>`, not draggable. Click opens the item's URL as a today tab (or selects the tab that already has it) and marks it seen; the × ("Mark as Done") and the menu's Mark as Done move it to the folder's done list; hover asks `previews.show {kind: "live"}` (the PR peek, without tab verbs).
- **Unread:** rows not opened yet carry `unread` (a dot); a collapsed folder carries `unread` on its header. What's in the feed when the folder is made starts as read.
- **Done:** an item that leaves the feed (not on a failed refresh) or is marked done shows in the header's `badge` "N ✓" (7 days, at most 20). Clicking the chip (`badge` action) opens a Recently Closed `panel` in the `popover` slot (`tabs.liveDone:<folderId>`): each row (`live.done:<folderId>:<itemId>`) reopens its item, and Clear empties it.
- **PR stacks:** items with `head`/`base` in the same repository chain into a nested folder `livestack:<folderId>:<rootItemId>` ("den · 3 PRs"), bottom PR first; collapsing it persists.
- **Reauth cue:** while the source isn't connected, the folder shows one row, "Sign in to GitHub to fill this folder", which calls `connections.connect`.
- **Cost:** no polling of its own. It listens to the `feed.items` the briefing's refresh already produces; creating a folder, launch (3 s after, when a live folder exists) and the folder menu's Refresh emit one `feed.refresh {reason: "live", sources}`.
- State: the folder in `state.folders` (`live`), and per folder `{primed, seen, done, dismissed, closed}` in storage ns `tabs` key `live`.

**Hover previews.** A `hover` action on a tab row or favorite calls `previews.show {anchor, url, title, icon, webview, selected, kind}`; on a folder, `previews.show {anchor, kind: "folder", title, items: [{id, title, url, icon}]}` with every tab inside it; on a split, the focused pane's tab stands for it. Without the `previews` plugin nothing happens.

Events:
- `tabs.changed {spaceId}` fires on any change to the lists.
- `tabs.selected {id, previous}`.
- `tabs.opened {id}`, `tabs.closed {id}`.

Owns:
- the sidebar `header` (URL pill and nav buttons), `favorites`, `pinned` and `today` slots, and the `overlay.library` sheet
- the content layout for the selected tab
- tab shortcuts: Cmd-W, Cmd-Shift-T, Cmd-D, Cmd-Shift-K, Cmd-1…9, Ctrl-Tab, Cmd-Opt-↑/↓, Cmd-[ and Cmd-], plus Ctrl-Z (undo sidebar action, as in Arc's "Use ⌃Z to undo" toast), Cmd-R, Cmd-. (stop), Cmd-S (sidebar) and Cmd-Shift-C (copy URL)
- auto-archive of idle today tabs (24 h by default, configurable, and it can be turned off)
- discarding of idle tabs through `webviews.suspend`: a tab that has been off screen for `suspendAfterMs` of den-frontmost time (5 min by default, checked every minute; the clock follows `app.active`) and isn't one of the 5 most recently used tabs is discarded; the host keeps only its URL, history and scroll (~1 KB) and a snapshot on disk, and its WebContent process exits. The host refuses tabs that play media, are in picture in picture, use the camera or microphone, or hold unsaved form input; they're asked again on the next check
- tab mute: the speaker on a tab row or favorite tile (and "Mute Tab" / "Unmute Tab" in its menu) calls `webviews.setMuted`; the state lasts while the tab lives. Arc's mute shortcut isn't documented anywhere den's research found, so there is none yet
- the tab row's hover playback buttons: `webviews.nowPlaying` puts `media {paused, next, previous}` on the row; its `media {action}` action calls `webviews.mediaControl`
- the picture-in-picture window's return button (`media.backToTab` selects the tab, private tabs too). The automatic PiP setting is `media.settings {autoPip}`; the command bar lists it under Settings › Tabs ("Picture in Picture when you leave a playing video") only in its fallback for when no `settings` service is loaded, and nothing registers it with the host `settings` service, so the app has no switch for it yet
- **drop onto a tab** (Arc, Jan 2024): dropping a tab on the middle half of another tab row or favorite tile makes a split of the two where the target lives, the dragged tab as the right, focused pane; a dragged split takes the tab in. Rows carry `dropInto` and the split hint icon; Ctrl-Z undoes it

## `commands` (plugin `commandbar`)

Injects: `tabs`, `spaces`, `ui`, `keys`, `content`, `storage`. It also calls `peek`, `window`, `webviews`, `app` and the host `plugins` service when they exist.

| Method | Args | Returns |
|---|---|---|
| `register` | `id`, `title`, `icon?`, `keywords?`, `aliases?` (other names that match like the title, e.g. `prefs`), `shortcut?` (display text, e.g. `⌘⌥N`, drawn as keycaps), `owner?` (the calling plugin's id) | ok. With `owner`, the command is dropped once that plugin is no longer active (cordis doesn't tell a service who called it, so plugins pass their own id) |
| `unregister` | `id` | ok |
| `list` | – | `[{id, title, icon, shortcut, owner, aliases}]`: the commands that can run right now |
| `search` | `q`, `limit?` (20) | `[{id, title, strength}]`: the launcher's den matches (commands, settings panes, settings; row ids `cmd:`, `pane:`, `set:`), best first |
| `run` | `id` | ok |
| `open` | `mode: new\|edit` (Cmd-T / Cmd-L), `query?` | ok. `edit` defaults the query to the selected tab's URL, text selected |
| `close` | – | ok |
| `paste` | `text`, `mode?: new\|edit` | `{kind: url\|search, url}`. Paste and Go / Paste and Search without opening the bar: the text opens as an address when it is one (the bar's own rule), else as a search with the default engine; `edit` in the selected tab, `new` in a new tab. Counts toward frecency like a typed entry. The bar's own field has the same item in its context menu (host `CommandBarView`), which submits the `go` or `search` row |
| `engines` | `engines?: [{keyword, name, url}]` (`url` holds `%s`) | the engine list. The first engine is the default web search. Stored in storage |
| `state` | – | `{open, mode, scope, query, selected, rows}` (for tests and scenarios) |

Events:
- `commands.run {id}` fires when a command is picked. Each owning plugin subscribes and acts on its own ids.

Owns: the `overlay.commandBar` slot, and Cmd-T and Cmd-L (pressing the same one again closes the bar; Esc and a click outside close it too).

**One input** (ids `commandBar` for the node and its actions):
- The first rows: `Reload` (Cmd-L with the URL unchanged), `<url> — Open URL` when the text looks like a URL, `<query> — Search Google` (the default engine), and `Search <site> — Press Tab` when the text is a site-search keyword.
- **Top hit.** A den command, destination or setting whose title or alias starts with the query (2+ characters, not a URL) goes above `Search Google`: "extensions" → Extensions, "prefs" → Settings, "dl" → Downloads, "dark" → Dark mode for websites. Otherwise `Search Google` stays first.
- Then sections with headers, in tiers so rows keep their place while typing: strong local matches (prefix, word prefix, alias, initials, keyword or host) from **den** (commands and destinations), **Settings** (panes and settings), **Tabs** (open tabs in every space, "Switch to Tab"; picking one selects it, never duplicates), **History** (pages opened from the bar, then archived tabs), **Spaces** and **Windows** (Little Arc windows; picking one calls `window.focusMini`); then up to 4 **Suggestions** (the host `suggest` service; room for two is always kept, so their arrival never pushes a local match out); then weak (substring, fuzzy) local matches, in their section. Rows (50 pt) and headers (28 pt) share the height of 8 rows. Suggestions already on screen keep their order while the next answer is pending; a suggestion that looks like a domain opens it (`— Open URL`).
- Nothing typed (Cmd-T): the 5 most recent tabs, then suggested actions.
- **Default-browser banner** (Arc's, at the bottom of the bar in the main scope): shown while `app.defaultBrowser` says den isn't the default, read lazily when the bar opens and cached until `app.defaultBrowser` fires. "Set den as default" calls `app.setDefaultBrowser`. "Try for a week" stores the current default's bundle id (`browserTrial {previous, name, start}`) and sets den; 7 days later (checked at start and hourly while a trial runs) a dialog asks "Keep den as your default browser?" with Keep / Switch back (`app.setDefaultBrowser {bundleId: previous}`). "×" hides the banner for good (`bannerDismissed`; Settings > Search > "Offer to make den your default browser" brings it back; see defaults.md).
- **Tab** on a setting or settings pane drills into it (below); otherwise it scopes to a site-search keyword (`g`, `yt`, `gh`, `w`, `maps`, `x` by default), or toggles actions-only mode.
- **Enter** runs the selected row. **Shift-Enter** opens URLs, searches and history in Peek (`peek.open`) when the peek plugin is loaded. Arrow keys and hover move the selection.
- With Cmd-L, a picked URL or search navigates the current tab instead of opening a new one.
- **Ranking:** a match score (title prefix or exact alias 100 > alias prefix 95 > phrase inside the title 90 > word prefix 70 > initials 65 ("dm" → Dark Mode) > keyword 60 > settings section 50 > substring 40 > letters in order 25; every word must match) plus frecency (uses weighted 100/80/60/40/20/10 by age < 1/4/14/31/90 days/older; commands `cmd:<id>`, settings `set:<key>`, panes `pane:<id>`). Storage ns `commandbar`, keys `usage`, `engines`, `browserTrial` and `bannerDismissed`; Settings values in `prefs`.

**Built-in commands** (ids `den.*`), hidden when what they need isn't there: New Space, Rename Tab (edits the title in the bar), Pin/Unpin Tab, Duplicate Tab, Copy URL, Copy URL as Markdown, Clear Today Tabs, View Archive (lists the archive in the bar; picking restores), Toggle Sidebar, Edit Theme (emits `spaces.editTheme`; shown only while something listens), Reload Page, Split Right (needs `peek`; pick the tab or URL for the right pane) and Quit den (`app.quit`).

**Destinations** (also `den.*` commands, each hidden until its service is loaded; picking one calls `<service>.<method>`): Settings (`settings.open`; aliases preferences, prefs, options, config), Extensions (`extensions.open`; addons, add-ons, plugins), Downloads (`downloads.open`; dl), History (`history.open`), Library (`tabs.library`; archive), Passwords (`passwords.open`; logins, credentials, keychain), Keyboard Shortcuts (every `keys.list` binding in the bar, chords as keycaps; picking one emits its event) and About den (`app.showAbout`). Connections… and Daily Briefing are registered by their plugins. The host provides `downloads` (Downloads opens Library ▸ Downloads). Nothing provides `history` or `passwords` services today, so those two destinations stay hidden; the `passwords` plugin registers its own "Passwords…" command (`passwords.open`) instead.

**Launcher index.** Commands, destinations, settings panes and settings are indexed when the bar opens (and again after `register`, `unregister` or `settings.changed`), never per keystroke. Each entry keeps its title, aliases, keywords and section in lowercase UTF-8 plus a 37-bit character mask, so a keystroke splits the query once, rejects most entries with one AND, and scores the rest with byte compares; the best rows are kept by insertion (no full sort). With 500 entries (91 registered commands, 30 panes × 12 settings), measured by `LauncherTests.perKeystrokeLatencyWith500Entries` in an optimized build: index build 2.0 ms per open; den + Settings matching 0.09 ms mean, 0.25 ms p95 per keystroke.

**Settings in the bar.**
- A setting row shows its icon, title, `— Settings › <pane>` and its state: a switch for a toggle, the current option for a choice.
- **Enter** on a toggle flips it (`settings.set`) and toasts "<title>: On"; on a choice it lists the options in the bar; on anything else, and on a pane row, it opens that pane (`settings.open {id, key?}`).
- **Tab** or **→** (caret at the end) on a setting lists its options (On / Off for a toggle; the current one is checked), on a pane its settings. **Backspace** in the empty field goes back.

### The `settings` service (shipped, host)

The Settings window and its `settings` service are in the host ([host-api.md](host-api.md#settings)). The command bar uses this part of it:

| Method | Args | Returns |
|---|---|---|
| `list` | – | `[{id, title, icon, order, schema: [{key: "<id>.<key>", title, type: toggle\|choice\|…, value, options?: [{value, title}], keywords?}]}]`: every section with current values (a pane's `keywords` and a setting's `icon` are read when present, but the host sends neither) |
| `set` | `key` (dotted, `<id>.<key>`), `value` | ok, then `settings.changed {id, key, value}` |
| `open` | `id?` (pane), `key?` (setting to reveal) | ok. Shows the Settings window |

Event: `settings.changed {id, key, value}` (the bar re-indexes).

Without a `settings` service (the host always provides one, so only in stripped-down setups), the bar falls back to each plugin's own `settings` method (thin adapter, `CommandBarCore.pluginSettings`): Links (Peek for links to other sites, Little Arc for links from other apps), Tabs (archive today tabs after, unload inactive tabs after, and `media`'s automatic picture in picture) and Briefing (morning briefing). Their panes drill in the bar instead of opening a window. When the service is loaded, its registry is the only source.

## `peek` (plugin `peek`)

Injects: `tabs`, `spaces`, `webviews`, `content`, `ui`, `keys`, `window`, `storage`, `app`.

| Method | Args | Returns |
|---|---|---|
| `open` | `url`, `sourceId?` (the tab it came from; the peek uses its profile) | `{id}` of the peek webview (`peek-<n>`). Replaces an open peek |
| `close` | – | ok |
| `expand` | – | `{id}`. The peek's web view becomes a today tab in the current space (`tabs.open {webview}`), selected |
| `split` | `ids`, `layout: horizontal\|vertical\|grid`, `focus?` | `{id}`. Forwards to `tabs.split` |
| `unsplit` | `id` | ok. Forwards to `tabs.unsplit` |
| `addSplit` | – | ok. A blank tab joins the selected tab in a split, then the command bar picks its page (⌃⇧=, ⌥-click on New Tab) |
| `reopen` | `after?` (ms timestamp) | `{id}`, or an error if no peek was closed at or after `after` |
| `openExternal` | `urls` | `{claimed}`. Opens each URL in Little Arc; `claimed: false` when Little Arc is off or the host has no mini windows |
| `settings` | `peekLinks?` (default true), `littleArc?` (default false: links from other apps open as a normal tab), `littleArcArchiveMs?` (default 6 h, 0 = never) | the settings |
| `get` | – | `{peek, sourceId, littleArcs: [{window, webview, url}]}` |

Events: `peek.opened {id, url}`, `peek.closed {id}`. `peek.link {id, url, source}` is the link-rule event the plugin listens on.

**Link policy.** Every pinned and favorite tab's webview gets `[{when: crossSite, event: peek.link}]` plus the modifier rules; the `*` default is the modifier rules only: shift-click and option-click (`when: any`) peek from any tab, shift-option-click (`peek.splitLink`) opens the link in a new tab split to the right of its tab (a peek from a page that isn't a tab), cmd-click still opens a background tab. The rules are re-sent on every `tabs.changed` and `spaces.changed` (undo can recreate a webview without them), and cleared from tabs that stop being pinned. Settings > "Open a Peek window when clicking on links to other sites" is `settings.peekLinks`.

**Peek actions** (Arc §6): expand with the button or Cmd-O; Split button (the page joins the current tab in a split, focused); close with a click outside, the X, Cmd-W (through `tabs`) or Esc. Esc is bound only while a peek is open. Cmd-Z reopens a just-closed peek for 15 s (den's choice; it is bound in the Edit menu only for that time, so Edit > Undo keeps working otherwise), and Cmd-Shift-T reopens it through `tabs` as long as no tab was archived since.

**Split view shortcuts** (Arc §7): Ctrl-Shift-= adds a pane (a new tab next to the selected one, then `commands.open {mode: edit}` to pick its page; at most 4); Ctrl-Shift-- takes the focused pane out (a today tab is archived, a pinned one is only separated); Ctrl-Shift-1…4 focus a pane. The pane's hover pill (`content.paneAction`) does the same close, or `separate`s the pane into its own selected tab.

**Little Arc** (Arc §8) uses the host's `window.openMini`. Links from other apps reach it through `tabs` (`peek.openExternal`). Each URL gets a `mini-<n>` web view in its own Little Arc window; the same URL again brings its window back (closed and reopened in front) instead of a second one. The bar's "Open in <space>" (`window.miniAction open`) and Cmd-O (on the key Little Arc window, from `window.listMini`'s `key`) move the web view into a today tab of the current space. The copy button copies the page URL. Closing the window closes the page. A window unused for `littleArcArchiveMs` (6 h) is closed and its page (current URL, title, favicon) goes into the tabs archive through `tabs.addToArchive`, like Arc's auto-archive; Cmd-Shift-T or the command bar's View Archive restores it as a today tab. Settings > "Links from other apps open in Little Arc" is `settings.littleArc`.

Storage (ns `peek`): `settings`.

Owns: the `overlay.peek` slot (through `content.peek`), the link policy, the Little Arc windows, Cmd-O, Esc while peeking, Ctrl-Shift-=, Ctrl-Shift--, Ctrl-Shift-1…4.

## `connections` (plugin `connections`)

Injects: `ui`, `storage`, `tabs`, `spaces`. Calls `commands` when it exists. Dia-style: you sign in to a site in den, and den reuses that session (no OAuth app). Host side: [session, net](host-api.md#connections-ai-and-scheduling).

| Method | Args | Returns |
|---|---|---|
| `register` | `id`, `title`, `icon`, `domain`, `signIn` (URL), `unit?` (what its `teams` are: `workspaces` (default), `accounts`, `calendars`), `order?` (place in lists; Slack 10, GitHub 20, Gmail 30, Calendar 40, Notion 50), `important?` (its items can be marked important: Settings shows "Important…"), `owner?` (not read) | ok. Called by provider plugins; registering the same `id` again replaces it |
| `list` | – | `[{id, title, icon, domain, unit, connected, pending?, account?, profile?, teams?, since?, note?, declined?}]`, in `order` |
| `get` | `id` | one entry of `list` |
| `connect` | `id`, `url?`, `profile?` (default: current space's) | ok. Probes first; if not signed in, opens `signIn` in a tab and probes every 3 s and when that tab finishes loading (15 min limit), then toasts "X connected". Several Slack workspaces open the sheet with the picker |
| `report` | `id`, `connected`, `profile`, `account?`, `teams?`, `note?` (a short status: "reads your Calendar tab"), `auto?`, `expired?` | ok. A provider's answer to a probe; `expired` from a refresh means the site session ended (toast, account dropped). Auto-connects within 8 s of each other share one toast ("Gmail and Google Calendar connected", Undo undoes both: `connections.undo:<id>,<id>`) |
| `disconnect` | `id` | ok. Forgets the account (you stay signed in to the site) and turns auto-connect off for it until a manual Connect (`declined`), so the next cookie change doesn't bring it back |
| `setTeam` | `id`, `team`, `enabled` | ok. Workspace picker |
| `open`, `close` | – | The Connections sheet (`overlay.connections`) |

Events: `connections.probe {id, profile, reason}` (the provider checks the session and calls `report`), `connections.changed {connections}`. Commands: "Connect X" / "Disconnect X" per provider, "Connections…". Storage ns `connections`, key `accounts`: `[{id, account, profile, teams: [{id, name, url, icon, enabled}], since, note?}]`, never tokens.

Settings ▸ Connections lists every provider plugin with its status ("Connected as you@acme.test · 2 accounts"), and buttons: Connect / Cancel, Workspaces… / Accounts… (the picker sheet) when there are several, Important… (opens Settings ▸ Briefing's important list) and Disconnect. The `calendar` plugin adds its own group there (reminder lead time, calendar address).

## Connection plugins: `slack`, `github`, `gmail`, `calendar`, `notion`

Each is its own plugin: it injects `session`, `net`, `storage` (the calendar also `ui`, `schedule`), registers with `connections`, provides no service, and costs nothing until connected (a cookie watch, which is event-driven). Permissions: `session:slack.com`, `session:github.com`, `session:google.com` (gmail; calendar also `net:*` for a pasted calendar address), `session:notion.so`. They answer `connections.probe`, and `feed.refresh` with `feed.items {source, items, account?, error?}` (only while connected). Auto-connect: `session.watchCookies` on their cookie domain; a change triggers a probe (no request while connected, only a cookie read).

**Feed item:** `{id, source, kind, title, detail, url, ts (ms), icon, badge, actor, where, actionable, summary, importantKey?, importantTitle?}`. Kinds: `dm`, `thread`, `mention` (Slack, GitHub, Notion), `review`, `ci`, `assigned`, `authored` (GitHub), `reply`, `docs`, `email` (Gmail), `comment`, `invite`, `update` (Notion), `event` (Calendar). `url` is the exact message, PR, email, page or event; `summary` is a one-line sentence for the model. `briefing: false` keeps an item out of the briefing (GitHub's `authored`, for live folders); `agenda: true` marks calendar events (the briefing's Today section, never todos). GitHub PR items may carry `head`/`base` (stacks).

- **Slack.** Connected when the profile has the `d` cookie and app.slack.com's `localConfig_v2` lists workspaces; their `xoxc-` tokens are read with `session.eval` and kept in memory only (re-read after launch). Per enabled workspace and refresh: `client.counts`, `conversations.history` for up to 6 unread DMs, `search.messages` for `<@you>` over 2 days, `conversations.replies` for up to 4 mentions in threads (a thread you haven't answered since the mention becomes `thread`), `users.info` for unknown names (cached). 8–10 requests per workspace in the mock run. `invalid_auth`/`not_authed` reports `expired`. `xoxc` tokens are not an official API credential (see the auth research).
- **GitHub.** Connected when github.com's `logged_in=yes` cookie is present; the account is `dotcom_user`. Data comes from github.com's search page, which returns JSON to `Accept: application/json` (`payload.blackbirdSearchRoute.results`, checked against a real response). Four documented qualifier queries per refresh: `review-requested:@me`, `author:@me status:failure` (failing CI), `assignee:@me` (issues), `mentions:@me`. A PR matching several keeps the most urgent kind. Why not the notifications page: it is HTML only, far more brittle to parse; api.github.com doesn't accept the web session. `logged_in: false` reports `expired`.

- **GitHub, your PRs and stacks.** A fifth query, `is:open is:pr author:@me`, lists your open PRs (`authored`, `briefing: false`). For a repository with two or more of them, each PR's head and base branch are read once from its github.com page (`"headBranch"`/`"baseBranch"` in the page's JSON, `Accept: application/json`), at most 8 new pages a refresh, then kept in memory.
- **Gmail.** Connected when Google's `SID` cookie is present and Gmail's Atom feed (`/mail/u/<n>/feed/atom`: unread mail in the inbox) answers. Accounts are found by walking `u/0`, `u/1`, … until an index repeats an account (Google sends unknown indexes to the first) or fails, at most 4; they're the connection's `teams` ("accounts"). Per enabled account and refresh: one feed request, newest 12 threads. A sender that's a person gives `reply` ("waiting for your reply": a heuristic, since the feed only says unread), Google's collaboration notifications (`comments-noreply@docs.google.com`, `drive-shares-…@google.com`) give `docs`, automated senders (`noreply`, `notifications`, `billing`, `newsletter`…) give `email` (listed, never a todo). Senders can be marked important (`gmail:<address>`). 401/403 reports `expired`. While connected, a Google cookie change only re-reads the cookie; a session that failed once isn't probed again until its `SID` changes.
- **Google Calendar** (`calendar`). Connected on the same `SID` cookie. Today's events come from the Calendar page itself: when a calendar.google.com/calendar tab finishes loading, and on each refresh while one is live, `webviews.eval` reads the `data-eventid` chips Google rendered (title, time range, all-day, Meet/Zoom/Teams link) in the page's time zone; nothing is fetched. Kept in memory for the day. Fallback: the calendar's secret iCal address in Settings ▸ Connections ▸ Google Calendar, fetched on each refresh and read by `ICS` (RRULE DAILY/WEEKLY/MONTHLY/YEARLY with INTERVAL, UNTIL, COUNT, BYDAY, BYMONTHDAY; EXDATE; moved and cancelled instances; `TZID=` times are read in the Mac's zone). Items are `event`s with `agenda: true`, `join` (the call link), `time`, `allDay`. Reminder: `ui.card {id: "calendar.reminder", rect}` in the window's top-right corner, `reminder` minutes before a timed event (setting: off, 1, 2 (default), 5, 10), with Join (opens the link in a tab), View and Dismiss (`calendar.reminder.join|view|dismiss`). Countdown: `tabs.badge {host: calendar.google.com, text: "in 8m" | "now" | ""}` within the hour before a meeting. One timer to the next moment that matters; a minute tick only while the card or the countdown shows; `schedule.fire {reason: wake}` re-checks.
- **Notion.** Connected when notion.so's `token_v2` cookie is present and `POST /api/v3/getSpaces {}` lists workspaces (`teams`, "workspaces"; the account is the user's email). Per enabled workspace and refresh: `POST /api/v3/getNotificationLogV2 {spaceId, size: 20, type: "unread_and_read", variant: "no_grouping"}` with `x-notion-active-user-header`; unread notifications (at most 10 a workspace) become `mention` (`user-mentioned`, `reminder`), `comment` (`commented`, with the comment's text), `invite` (`user-invited`: a page shared with you) or `update`. Records are unwrapped from both nestings Notion has used (`value` and `value.value`). URLs: `https://www.notion.so/<page id>` plus `?d=<discussion>` for comments. Pages can be marked important (`notion:<page id>`). 401 reports `expired`; 429 is reported as "Notion asked den to slow down". This API is internal and undocumented (see the auth research).

Storage overrides (tests, mocks): ns `slack` key `endpoints {api, origin, domain, signIn}`, ns `github` key `base`, ns `gmail` key `endpoints {base, domain, signIn}`, ns `calendar` key `endpoints {domain, host, web}`, ns `notion` key `endpoints {api, web, domain, signIn}`.

## `briefing` (plugin `briefing`)

Injects `ui`, `storage`, `keys`, `schedule`, `ai`; calls `connections`, `tabs` and `commands` when they exist.

| Method | Args | Returns |
|---|---|---|
| `open`, `close` | – | The briefing page (`overlay.briefing`, style `page`); opening refreshes when older than 5 min |
| `refresh` | `reason?` | ok. `feed.refresh`, waits for every connected source (30 s), ranks, then `ai.brief` + `ai.todos` (or plain lists) |
| `toggle` | `id`, `done` | ok |
| `settings` | `hour?`, `minute?`, `enabled?` | `{hour, minute, enabled}` (morning briefing, default 8:00, on) |
| `state` | – | `{open, refreshing, summary, summaryState: none\|working\|ai\|plain, todos, feed, errors, updatedAt, scheduled}` |

- Lazy: `schedule.daily` (`briefing.morning`) and a 15 min / on-wake `schedule.interval` (`briefing.poll`) exist only while a connection does. The morning run refreshes and toasts "Your morning briefing is ready ⇧⌘B".
- Ranking: kind (review 50, dm 46, thread 44, reply 42, ci 40, comment 36, mention 34, docs 30, invite 26, assigned 22, email 12, others 10) + recency (up to +24 in the last day; a future time counts as now) + affinity (+3 per earlier open of the same person or place, max +15).
- Calendar events (`agenda: true`) are the page's **Today** section (all-day first, then by time) and the summary's input, never feed rows or todos. Items with `briefing: false` are left out.
- Todos persist (ns `briefing`, key `todos`) with done state; checked ones go after a day. Feed items stay in memory. Opening a todo or feed item opens its URL in a tab.
- ⇧⌘B and the "Daily Briefing" command. UI ids: sheet `briefing`, `briefing.refresh`, `briefing.connections`, `briefing.connect:<id>`, `briefing.todo:<itemId>`, `briefing.feed:<itemId>`, `briefing.enabled`, `briefing.time`.

## `previews` (plugin `previews`)

Injects: `ui`, `webviews`, `storage`. It also calls `net`, `session`, `tabs`, `peek`, `connections` and `settings` when they exist. Permissions (`permissions.json`): `net:api.github.com`, `net:*` (link heads, never with cookies), and `session:` for `github.com`, `calendar.google.com`, `mail.google.com` and `slack.com`.

Dia-style hover cards for sidebar tabs, the GitHub PR peek, and ⇧-hover link cards on any page, all composed from the host's generic nodes and shown with `ui.card` (cards `previews.tab` and `previews.link`). It's a plugin of its own rather than part of `tabs`: `tabs` only says what is hovered, and everything site-specific (providers, permissions, caches) lives here, so it can be left out or replaced, and other plugins can add providers without touching `tabs`.

| Method | Args | Returns |
|---|---|---|
| `show` | `anchor` (row id), `url`, `title?`, `icon?`, `webview?`, `selected?`, `kind?` (`today`, `pinned`, `favorite`, `folder`), `items?` (folders), `drift?`, `audio?`, `muted?`, `inSplit?`, `spaces?: [{id, name}]`, `panes?` (a split row), `place?` | ok. Shows the card at once and fills it in when the provider answers. `tabs` sends everything the card's buttons need |
| `hide` | – | ok. Closes the tab card |
| `register` | `pattern`, `provider`, `owner?`, `ttlMs?` (60000) | ok. An external provider for URLs matching `pattern` |
| `unregister` | `provider` | ok |
| `answer` | `request`, `card` | ok. An external provider's answer: a card fragment (below) |
| `providers` | – | `[{provider, pattern, builtin}]` |
| `match` | `url` | `{provider}` |
| `get` | `url` | `{provider, data, at}` from the cache, or null |
| `clear` | – | ok. Drops the caches |
| `stats` | – | `{fetches, cached, inflight, links}` |

Events: `previews.request {provider, request, url, anchor, webview, profile}` asks an external provider for a card.

- **Patterns** are `host/path` globs (`*` matches anything, including `/`) against the URL without scheme, `www.`, query or fragment; a leading `*.` also matches the bare domain. The pattern with the most literal characters wins, so a plugin can override a built-in for a narrower pattern (`github.com/apple/*/pull/*`).
- **Card fragments** (provider answers): any of `title`, `subtitle`, `accessory`, `badges`, `sections`, `actions`, `footer`, `empty`, `image`, plus `summary {text, style}` (a digest shown next to the tab in folder cards) and `noCache` (show it, but ask again on the next hover: sign-in hints, a page that isn't loaded). `{error}` keeps the last good card.
- **Cost.** Nothing runs until a hover: no timers, no polling, no requests at launch. The card shows at once with the tab's favicon, title and domain (and cached data, if any), with skeleton lines while the first answer loads. Answers are cached per URL for the provider's TTL; a stale card shows at once while it refreshes, and hovers of the same URL share one request.
- **Actions.** The tab card's buttons call `tabs.act` on the hovered tab and close the card (Mute keeps it open, now offering Unmute); Move to Space opens a menu of spaces. A row or button with a `url` opens it in a new tab. PR peek buttons open the checks tab, the conversation or the conflict editor in the hovered tab itself; failing-check rows open the check. The link card's buttons: `peek.open`, a split with the active tab, and copy.
- **PR peek data** (`GitHub.prData`): GitHub's public REST API, no sign-in: `pulls/<n>`, then `commits/<head>/check-runs` and `commits/<head>/status` (3 requests, cached 60 s). Checks count as passed (success, skipped, neutral), running, queued or failed. A 404 (private) or 403/429 (rate limit) falls back to the github.com page with the user's den session; with no session the card offers **Connect GitHub** (`connections.connect {id: "github"}`), and `connections.changed` refills it live.
- **Link cards.** `webviews.watchLinks {modifier: shift}` at start (setting: `shift`, `none` with a 700 ms wait, or `off`), with `yieldTo` selectors for sites that have their own previews (Wikipedia's `.mwe-popups`, GitHub's hovercards, X's). On `webviews.linkHover`, a URL a provider matches gets that provider's card; anything else gets an OpenGraph card from `net.fetch {as: text, stopAfter: "</head>", headers: {Range: bytes=0-262143}}` parsed by `OpenGraph.parse`, cached 10 minutes (100 URLs). `webviews.linkHoverEnd` closes it after the host's grace.
- **Settings** (section `previews`): `links` (`shift`, `hover`, `off`) and `redwell` (a second dwell before switching tab cards).

Built-in providers:

| Provider | Pattern | Card | Source |
|---|---|---|---|
| `github.pr` | `github.com/*/*/pull/*` | Open / Draft / Merged / Closed; CI (`N failing`, `N pending`, `Checks passing`) with the failing and running checks first; `Conflicts` (mergeable_state `dirty`); review state (Changes requested, Approved, Review requested) and reviewers; head → base branch; +/− lines and files. TTL 60 s | api.github.com: `pulls/<n>`, then the head commit's `check-runs` and `status` and the PR's `reviews`, in parallel (public repositories, no sign-in). For a private repository (or a rate limit), the PR page read with the user's github.com session (`session.eval`), which gives state and branches |
| `github.issue` | `github.com/*/*/issues/*` | Open / Closed / Not planned, labels, assignees, comments. TTL 2 min | api.github.com `issues/<n>` |
| `calendar` | `calendar.google.com/*` | "Rest of today": what's on now, the next event and when, all-day events, and **Join** for the first current or upcoming event with a Meet, Zoom or Teams link. TTL 60 s | The Calendar tab itself (`webviews.eval`): the script reads its event chips' labels in the page's locale and time zone. Only a loaded tab; otherwise a hint |
| `gmail` | `mail.google.com/*` | Unread count, the newest 4 unread threads (sender, subject, time), Compose. TTL 60 s | Gmail's Atom feed `/mail/u/<n>/feed/atom` with the Google session |
| `slack` | `app.slack.com/*`, `*.slack.com/*` | Mentions, unread DMs and channels, threads. TTL 30 s | `client.counts` with the Slack session and the workspace's web-client token (read once from app.slack.com's localStorage, kept in memory, as the `slack` plugin does) |
| `page` | `*` | Title, domain and a snapshot of the tab (320 pt JPEG, kept 30 s per tab and URL). Not for the selected tab, which is already on screen | `webviews.snapshot {width, format: jpeg}` |

Folders get a card listing their tabs, each with its provider's cached `summary` (never a request). Endpoints can be redirected for tests through storage ns `previews`, key `endpoints` (`githubApi`, `githubWeb`, `gmail`, `slackApi`, `slackOrigin`). The Calendar chip format, Gmail's feed and Slack's web API are undocumented or private surfaces: they are tested against mock pages and payloads, not against signed-in accounts.

## `darkmode` (plugin `darkmode`)

Injects `pagestyle`, `webviews`, `ui`, `storage`; calls `commands`, `content` and `tabs` when they exist. Dark mode for every website, tied to den's appearance. Host side: [pagestyle](host-api.md#pagestyle).

| Method | Args | Returns |
|---|---|---|
| `get` | `host?` | `{enabled, mode, sites, dark}` (`dark`: the host is known to be natively dark) |
| `site` | `host` (or a URL), `mode: auto\|dark\|light\|off` | ok |
| `settings` | `enabled?` | `{enabled}` |

- **Native first.** Web views follow den's appearance, so `prefers-color-scheme` is den's and sites with a dark mode use it.
- **`den.dark` sheet** for sites that stay light: `filter: invert(1) hue-rotate(180deg)` on `<html>`, with `img, video, canvas, embed, object, iframe, svg image` and inline `background-image` elements inverted back. It sits in `@media (prefers-color-scheme: dark)` (switching den's appearance applies at once, with no round trip) and on `html:not([data-den-tone=dark])` (a page already dark is never inverted).
- **Cache.** Hosts measured dark under a dark scheme are remembered (`tones`, 400 at most) and get no sheet at all on the next visit: no flash, no filter cost.
- **Per site.** `dark`: dark appearance plus `den.dark`. `light`: light appearance plus `den.light` (inverts pages that stay dark in a light scheme). `off`: nothing. Commands: "Dark Mode: Follow den / Always Dark / Always Light / Off for This Site" act on the focused pane's site; "Dark Mode for Websites: On/Off" switches the default.
- Storage ns `darkmode`: `settings {enabled}`, `sites {host: mode}`, `tones [host]`. TODO(settings): register these with the `settings` host service (it has shipped; `darkmode` doesn't register yet).
- Known gaps: CSS-class background images are inverted with the page; a natively dark site flashes inverted on its very first visit, until the detector runs (then it's cached). Measurements: [research/dark-mode.md](research/dark-mode.md).

## `passwords` (plugin `passwords`)

Injects `vault`, `ui`, `storage`; calls `commands`. Owns the `overlay.passwords` sheet and the save dialog (`passwords.save`). Host side: [vault](host-api.md#vault).

- **Save.** `vault.captured` shows "Save password for <site>?" (or "Update …" when that username is saved) with Never for This Site / Not Now / Save. `never` origins persist (storage ns `passwords`, key `never`).
- **Autofill.** `vault.focus` on a site with saved logins puts one row per login under the field ("<user> · Touch ID"); picking one calls `vault.fill` (Touch ID, then fill). Sign-up fields also get "Use Strong Password" (`vault.generate`); the generated password is then offered for saving on submit. `vault.blur` hides the list.
- **Passwords…** (command `passwords.open`): Touch ID (`vault.unlock`), then the list with Copy (Touch ID again) and Delete per login. Closing the sheet locks.
- TODO(settings): expose the list and `never` in the `settings` host service (it has shipped; `passwords` doesn't register yet).

## `extensions` plugin (`extensions`)

Injects `webext`, `ui`; calls `commands` and `tabs` when they exist. The host `webext` service does the WebKit work ([host-api.md](host-api.md#webext)); this plugin is the Extensions page and the commands, and provides `extensions`: `open {id?}` (the page, or one extension's details), `close`, `state` (`{open, selected}`). The command bar's built-in "Extensions" destination calls `extensions.open`.

- **Commands** (owner `extensions`): "Install Extension from File…" (`extensions.installFile`, the host's open panel), "Get Extensions" (`extensions.get`, the Chrome Web Store in a new tab). Registered with the same 500 ms / 30 s retry as `quit` and `theme`.
- **Page** (`overlay.extensions`, sheet id `extensions`, style `page`): opened by `extensions.open` and by `webext.openPage` (the URL pill menu's "Manage Extensions").
  - List: an `extensionRow` per extension (`extensions.row:<id>`: the switch turns it on or off, the row opens its details), "Get more" rows for the Chrome Web Store, Firefox Add-ons and a file (`extensions.get.chrome|firefox|file`), a Settings toggle for the store buttons (`extensions.storeButtons`), and a note on what WebKit can't run. Header buttons: Check for Updates (`extensions.update`, toasts the result) and Install from File (`extensions.addFile`).
  - Details: description; **Access** (`extensions.access`: On all sites / When you click it / On specific sites, one toggle per allowed site `extensions.site:<host>`, and "Allow on <current site>"); **Permissions** (plain-language lines, and what WebKit doesn't support); **Details** (pin to the URL bar, on/off, manifest version, background kind, source, id, load errors); buttons Options, Update to … (when an update needs approval), View in Store, Remove (confirms with dialog `extensions.remove.dialog`). Back: `extensions.back`.
- Re-renders on `webext.changed` while open; Esc, the close button or `extensions` `dismiss` closes it.

## `pagetools` (plugin `pagetools`)

Injects: `webviews`, `content`, `ui`, `keys`, `storage`, `app`, `speech`, `translate`, `schedule`, `settings`; calls `tabs` and `commands` when they exist. Permission: `pages:*`. Provides no service. Reading and capture tools from the [gap shortlist](research/gaps-shortlist.md) §C, built only from generic host blocks ([Plugins in pages](host-api.md#plugins-in-pages), [Capture](host-api.md#capture), `speech`, `translate`, `ui.tokens`). Its page scripts are in `Plugins/pagetools/resources/`: den's own (`reader.js`, `translate.js`, `capture.js`, `zap.js`, `highlight.js`, MIT) and, in `vendor/`, Mozilla Readability (Apache-2.0) and Google's text-fragments generator (Apache-2.0), with their licences and a `NOTICE`.

**Cost.** Nothing before the first window: 1.5 s after it loads, it binds two keys, adds one context-menu item, registers its commands and its Settings section (stored until Settings opens) and, only if some site has zapped elements, sets the content rules. No script runs in any page until a feature is used, except one small check: after each load of the page you're looking at, Readability's `isProbablyReaderable` (4 KB) and a text sample for `translate.detect`.

- **Reader** (⌃⌘R: Safari's ⇧⌘R is den's Reload from Origin; the pill's Reader button, "Toggle Reader"). The button appears only when the check says the page is an article. Opening injects `Readability.js` and `reader.js` into the page: the article is drawn over it in a closed shadow root, in den's colors (`ui.tokens`), with a floating toolbar: close, Serif/Sans, smaller/larger text (14–30 px), Listen, speed, and "Always" (use Reader on this site; also a command). Font, size and speed persist; sites with "Always" open in Reader after each load. Esc or ⌃⌘R closes it and the page is untouched.
- **Read aloud** (the toolbar's Listen, or "Read Aloud"). The reader's sentences (split with `Intl.Segmenter`) go to `speech.speak` in the article's language; each `speech.progress` highlights that sentence (CSS Custom Highlight API) and scrolls it into view. Pause/resume from the same button; the speed button cycles 0.8×, 1×, 1.25×, 1.5×, 2× (`speech.setRate`). Closing the reader or leaving the page stops it.
- **Translate** (the pill's Translate button, "Translate Page"). The button appears when the detected language isn't the user's. `translate.js` collects the page's text nodes (up to 4,000; not code, inputs, `translate="no"` or `.notranslate`), the plugin sends them to `translate.run` on-screen text first, longest first (a first batch of 30, then 120 at a time; the title rides with the first batch) and writes each batch back as it arrives, keeping each node's surrounding spaces. The button then shows the original (`restore` puts every node back). All on device; a model that isn't downloaded yet gets macOS's own prompt.
- **Capture** (⇧⌘2 = region, or the commands for region, element, visible area and full page). Region and element show `capture.js`'s picker (dim, crosshair or hover outline, a bar to switch mode, Esc cancels); it removes itself before the shot. The result is copied to the clipboard (default) or saved as "den Capture 2026-09-27 at 21.40.05.png" in Downloads or a chosen folder ("Save Captures to Folder…" / "Copy Captures to Clipboard"), with a toast.
- **Zap** ("Zap Elements"): hover outlines an element, a click hides it; a panel lists what's hidden on this site with Undo per item, "Remove Sticky Headers" and Done. **"Remove Sticky Headers"** is also a one-click command: every visible fixed or sticky box (outermost only, not one holding the page's `main`/`article`). Selectors are stable ids/classes plus `:nth-of-type` where needed, saved per site and applied as `css-display-none` content rules, so WebKit hides them at document start on every later visit with no script. Undoing an element reloads the page; "Show Zapped Elements on This Site" clears the site.
- **Copy Link to Highlight** (context menu on selected text, or the command): `highlight.js` with the vendored generator builds a `#:~:text=` URL (prefix/suffix only when needed to be unique), copied with a toast. WebKit opens such links, scrolling to and marking the text (checked in the `highlightLink` scenario).
- **Share…** ("Share…", File ▸ Share…): `app.share` for the focused page's URL, anchored at the URL pill (`tabs.url`). Pages without a web address get a toast instead.
- **QR Code for This Page** (the command, File ▸ QR Code for This Page): `app.qrCode` for the URL, shown in the `popover` slot beside the URL pill (panel `pagetools.qr`: the image, **Copy Image** → `app.copyImage` with a "Copied QR code · …" toast, **Save…** → `app.saveFile`, name "QR code \<host\>.png"). Esc or a click outside closes it.
- **Copy toasts** name what was copied: "Copied image · 1280 × 800 px" for a capture, "Copied link to highlight · “the words…”".
- **Zoom per site** is not in this plugin: the host's page actions do it (`webviews.zoom`, ⌘+ / ⌘- / ⌘0 in the View menu, remembered per site).

Commands (ids `pagetools.*`): Toggle Reader, Always Use Reader on This Site, Read Aloud, Translate Page, Show Original Page, Capture Region / Element / Visible Area / Full Page, Copy Captures to Clipboard, Save Captures to Folder…, Zap Elements, Remove Sticky Headers, Show Zapped Elements on This Site, Copy Link to Highlight, Share…, QR Code for This Page. Storage (ns `pagetools`): `reader {font, size, rate}`, `readerSites`, `zaps {host: [selector]}`, `capture {dest, folder}`, and Settings' `prefs`. UI ids: pill buttons `pagetools.pill.reader`, `pagetools.pill.translate`; menu item `pagetools.highlight`; QR popover `pagetools.qr`, `pagetools.qr.copy`, `pagetools.qr.save`. **Settings > Reading** (`settings.register`, id `pagetools`): reader font, text size and read-aloud speed, the sites that always open in Reader (Remove), captures to the clipboard or a file and the folder (Choose… / Use Downloads), and the zapped sites (Show All). Changes apply live either way. Scenarios: `--scenario readerButton|reader|readAloud|translate|translateJa|captureRegion|captureFull|zap|unstick|highlightLink|qrCode|copyToast` (real pages, network needed).

## `shields` plugin (`shields`)

Injects `sitepolicy`, `webviews`, `ui`, `storage`; calls `settings`, `commands`, `keys`, `content`, `tabs` and `webext` when they exist. Clean, private browsing. Host side: [sitepolicy](host-api.md#sitepolicy). Its shield sits in the URL pill through `tabs.pillButtons` (button id `shields.pill`), set per web view on every URL change.

| Method | Args | Returns |
|---|---|---|
| `navigate` | `{id, url, source, link}` | the `sitepolicy` guard's answer (below) |
| `open` / `close` | `id?` (a web view; default the focused one) | ok. The panel |
| `site` | `host`, `blocker?`, `cookies?`, `autoplay?: allow\|sound\|none`, `popups?: allow\|block` | ok |
| `get` | `host` | `{blocker, cookies, autoplay, popups, httpAllowed, lists, ubo, global.*}` |
| `state` | – | `{panelOpen, webview, pendingReload, unsaved, forgetting}` |

- **Blocking.** Three lists ship pre-compiled (`Plugins/shields/resources/*.json.lzfse`, [build](../scripts/shields/build-lists.sh)): `shields.ads` (EasyList: 67,819 rules, generic cosmetic filters left out), `shields.trackers` (EasyPrivacy network rules: 56,105) and `shields.cookies` (EasyList Cookie List: 25,239, of them 23,125 hiding rules). Each is loaded only when a rule uses it. Blocker off for a site drops `ads` and `trackers` there; cookie banners off drops `cookies`.
- **Guard** (`navigate`, called synchronously for main-frame navigations): a lookalike host (Lookalike.swift) → `interstitial` "Did you mean apple.com?" with Go to apple.com (↩) / Continue; a bounce tracker (CleanLinks.swift: Rakuten, Awin, Skimlinks, CJ, impact.com, Reddit, Slack, Tumblr) → `rewrite` to its destination; tracking parameters (utm_*, fbclid, gclid, msclkid, srsltid, mc_eid, _hsenc and 25 more, plus `si`/`s`/`t` only on YouTube, Spotify and X) → `rewrite`. Security redirectors (Google `/url`, `l.facebook.com`) are never skipped. A site with the blocker off keeps its parameters.
- **Scriptlets** (YouTube ads). YouTube serves ads from its own origin, as fields of the player's JSON (`adPlacements`, `playerAds`, `adSlots`), so no URL rule can block them. `scriptlets.js` (an engine of fixed scriptlets: `set`, `json-prune`, `json-prune-fetch-response`, `json-prune-xhr-response`, `replace-fetch-response`, `replace-xhr-response`, `edit-outbound-json`, `neutralize-callback`, `youtube-recover`, `prevent-dom-bypass`, `remove-node-text`, `adjust-setTimeout`, `hide`) runs the rules of `scriptlets.json` (data only: names, strings and plain JSON objects) at document start in the page's world, in every frame on the hosts the data lists (youtube.com, youtube-nocookie.com, youtubekids.com) — embeds on any other site included — through `sitepolicy.script`, named `shields.scriptlets` in every rule whose blocker is on. The rules are translated from uBlock Origin's current YouTube filters: the player response is pruned at `ytInitialPlayerResponse`, `JSON.parse`, and `/youtubei/v1/player`, `/player/ad_break` (mid-rolls), `/playlist`, `/get_watch`, `/reel_watch_sequence` responses (fetch and XHR); the anti-adblock dialog's data (`enforcementMessageViewModel`) is pruned too, and ad slots, promoted items and the dialog with its backdrop are hidden. Logged in, YouTube can answer a pruned player with "This content isn't available" or stitch ads into the stream (SSAI): `youtube-recover` is uBlock Origin's quick fix for that as engine code (it tags the client and reloads the video, the `edit-outbound-json` rules change the reload's player request, and a stitched ad that still plays — "SSAP, AD" in the player's stats — is skipped to its end), and `neutralize-callback` disarms the page's `onAbnormalityDetected`. Every removal counts toward the panel's blocked count (`sitepolicy` `scripted`).
- **Site scriptlets** (anti-adblock walls, pop-unders, ad-script traps on ~21,000 sites). `sites.json` is uBlock Origin's `##+js(…)` rules for named hosts whose scriptlets the engine implements (`set`, `aopr`, `aopw`, `acs`, `nostif`, `nosiif`, `aeld`, `nowoif`, `no-fetch-if`, `no-xhr-if`, `nowebrtc`, `nofab`, `noeval(-if)`, `ra`, `rc`, `nano-stb`, `nano-sib`, `json-prune`, `rmnt`, `prevent-dom-bypass`), built by `scripts/shields/build-scriptlets.swift` from uBO's filters and quick fixes (`!#if` blocks evaluated with every environment false; exceptions applied; generic rules, `name.*` entities and YouTube left out; code-carrying scriptlets such as `rpnt` and `trusted-*` never converted). It is a second page script, `shields.sites`, with the same engine, loaded `perSite` (`sitepolicy`): a page gets only its site's rules. Refreshed daily with `scriptlets.json`. YouTube changes often, so the data is refreshed daily (a minute after launch when the last check is a day old, then `schedule.interval`): `sitepolicy.fetch` of `scriptletsURL` (this repository's `main`), then a reload of the script when it changed (storage `scriptletsChecked`). New data reaches the next page load; the engine itself only changes with den. Blocker off for a site (⌥⌘B, the panel) turns the scriptlets off there too.
- **HTTPS-first** on by default; `sitepolicy.httpsUnavailable` shows "<host> doesn’t offer a secure connection" with Go Back (↩) / Continue to Insecure Site. Continuing remembers the host (storage `httpAllowed`, listed in Settings with Remove).
- **Panel** (`popover` slot, panel id `shields.panel`, anchored to `tabs.url`): opened by the shield in the URL pill, ⌥⌘S (menu View ▸ Shields for This Site…) or the command. "This site": Block trackers and ads (⌥⌘B), Hide cookie banners, Autoplay (Block Sound / Allow / Block All), Pop-ups (Block / Allow), Zoom (−/+/reset, ⌘− ⌘+ ⌘0). A change asks `sitepolicy.unsaved`, then shows "Reload the page to apply the change." with Reload (⌘R), or, when the page has input you haven't sent, a warning and Reload Anyway. "On this page": trackers and ads blocked (WebKit's real count), bounce redirect skipped, tracking parameters removed, connection (Secure / Upgraded to HTTPS / Not secure), camera and microphone (with reset). Footer: Forget This Site… (confirms, then `sitepolicy.forget`, clears den's own choices and zoom for it, reloads its pages), Settings.
- **uBlock Origin Lite.** When it's installed and enabled (`webext.list`/`webext.changed`) and den's blocker is on, a toast offers once to turn den's blocker off ("Turn Off"); the panel and Settings keep a note.
- **Commands** (owner `shields`): Shields for This Site (⌥⌘S), Block Trackers and Ads on This Site: On/Off (⌥⌘B), Hide Cookie Banners on This Site: On/Off, Forget This Site…, Shields Settings.
- **Settings > Shields** (`settings` id `shields`): Block trackers and ads, Hide cookie banners, Remove tracking parameters, Skip bounce-tracking redirects, HTTPS-first, Warn about lookalike sites (all on), Autoplay (Block Sound), the sites with their own settings (Reset), the hosts allowed without HTTPS (Remove), and the lists' sources and licences.
- Storage ns `shields`: `sites {host: {blocker?, cookies?, autoplay?, popups?}}` (only values that differ from the global choice), `httpAllowed`, `lookalikeAllowed`, `uboOffered`, `scriptletsChecked` (ms).
- **Licences.** EasyList and EasyPrivacy are dual GPL-3.0+/CC BY-SA 3.0+; den ships them under CC BY-SA 3.0. The EasyList Cookie List's header says CC BY 3.0. The compiled files stay under those licences (with "© The EasyList authors"; `resources/NOTICE.md`), separate from den's MIT code. adblock-rust (MPL-2.0) only runs at build time. DuckDuckGo's lists (CC BY-NC-SA) are not used; Brave's `query-filter.json`/`debounce.json` (MPL-2.0) could ship unmodified with their notice, but den's parameter and redirect lists are its own, written from the public sources cited in CleanLinks.swift. DuckDuckGo's `autoconsent` (MPL-2.0) is not used: see the guide's [cookie banners](guide/privacy-and-passwords.md#cookie-banners) section for the measured cost.
- **Updating the lists.** `scripts/shields/build-lists.sh` rebuilds them (download, adblock-rust on a Linux box or locally, validation against this Mac's WebKit, split over 150,000 rules, LZFSE) and rewrites `ShieldsLists.swift`. A new list version reaches users with a den release. Over the air, without a release, is possible but not built: `sitepolicy.load` already looks in `~/.den/updates/lists/<plugin>/` before the app bundle, so the updater would only need to place signed list files there and ship a `shields` plugin update carrying the new version string.

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
- **`updates`:** update policy (channels, schedule, what to install, relaunch, every string) over the host `updates` service; injects `updates`, `app`, `ui`, `storage`; command `den.checkForUpdates`. See [updates.md](updates.md).
- **`media`:** the now-playing dock and den's Control Center entry. Injects `webviews`, `ui`, `keys`, `nowplaying`; calls `tabs.select` (optional).
  - Follows `webviews.nowPlaying {id, now, muted}` (the host's page script: the last media element that played with sound, and the page's Media Session title, artist, album, artwork and action handlers). Most recent first: a new entry, or one that starts playing again, goes to the front. Gone on `now: null` (stopped, navigated, discarded) or `webviews.closed`.
  - Owns the `sidebar.dock` slot: one card per listed tab (generic `stack` / `image` / `label` / `action` nodes): artwork (else the site icon), title, artist; buttons previous, play/pause, next (dimmed without a `nexttrack` handler), mute, picture in picture (video entries: `media.enter` / `media.exit`, its icon following `media.pip`), stop. Node ids `media.<command>:<webview>`, `media.jump:<webview>` (artwork + title, a clickable stack: `tabs.select`), `media.more` (expand / collapse when more than one plays). The selected tab (`tabs.selected`) isn't listed; a tab in picture in picture is (den's controls around the system window). ⌥⌘P (`keys.bind cmd+opt+p` → `media.key.pip`, View ▸ Picture in Picture; the command bar's `den.pip` emits the same event) calls `media.toggle {fallback: <newest playing tab>}`. Nothing listed: the slot is cleared.
  - The newest entry (listed or not) is published with `nowplaying.set` (title, artist, album, artwork, duration, playing, commands); `nowplaying.command` and the keys ⌃⌘P / ⌃⌘→ / ⌃⌘← (View menu, events `media.key.toggle|next|previous`) act on it through `webviews.mediaControl` / `setMuted`. `nowplaying.clear` when nothing is left.
- **`panels`:** web panels (optional: `[plugins] disabled = ["panels"]`). Injects `webviews`, `content`, `ui`, `keys`, `storage`; calls `tabs`, `commands`, `settings` when present.
  - Each panel is a web view `panel-<n>` (created on first show; `userAgent: "mobile"` with its "Phone Layout" option) shown with `content.side {webview, width}` (390 pt); the `side.header` slot has a button per panel (`panels.switch:<id>`), `panels.add` (menu: Add This Tab, suggested sites, Other Address…), `panels.more` (menu: Open as Tab, Reload Panel, Phone Layout, Remove Panel) and `panels.hide` (⌃⌘S).
  - ⌃⌘S (`panels.key.toggle`, View ▸ Toggle Web Panel) shows the last panel or hides it; with no panels it opens Settings ▸ Web Panels. Commands `panels.toggle`, `panels.addTab` ("Add This Tab as a Web Panel"), `panels.add` (opens Settings).
  - Sleep: 30 s after a panel leaves the screen, `webviews.suspend` (refused while it plays sound; tried again at the next hide). Showing it again restores it like a discarded tab.
  - Settings ▸ Web Panels (`settings.register`, id `panels`): an add field (`claude.ai` → `https://claude.ai`) and the list with Remove. Storage ns `panels`: `list [{id, url, title, mobile}]`, `state {open, last, width}`; the panel open at quit comes back 1.5 s after launch.
- **`tips`:** onboarding ([spec and status](guide/_in-app-tips.md)): the tour card and the import card in the `sidebar.notice` slot (node ids `tips.card`, `tips.tour.*`, `tips.import.*`), one-time tips as toasts (id `tips.tip`, `hold: true`, button "Don't show tips").
  - Injects `ui`, `storage`, `settings`; calls `commands`, `spaces`, `content` and `importer` when they exist. Listens only: `tabs.key.*`, `window.sidebar*`, `spaces.*`, `peek.*`, `previews.request`, `commands.run`, `ui.action`. Settings row, commands and cards wait 1.5 s after load.
  - Commands `tips.toggle` ("Don't Show Tips" / "Show Tips") and `tips.tour` ("Take the den Tour"). Settings ▸ General ▸ Tips (id `tips`, key `enabled`).
  - Storage ns `tips`: `enabled`, `tour` (`new|dismissed|done`), `import`, `launches`, `shown.<key>`, `retired.<key>`, `counts`, `last`, `day`, `dayCount`.
  - `importer` (provided by no plugin yet): `sources` → `[{id, name}]`, `run {source}`.
  - `tips.preview {key}` (snapshot scenarios only) shows a card or tip without limits or records.
- `theme` and `quit` call `commands.register` without injecting `commands` (the command bar is optional), retrying every 500 ms for 30 s until it exists.

## Ownership rules

- A slot has exactly one owner, as listed above. Other plugins ask the owner through its service instead of writing to the slot.
- Every shortcut is bound by exactly one plugin, and every other action goes through `commands.register`.
- State persists through `storage`, in the owning plugin's namespace.
