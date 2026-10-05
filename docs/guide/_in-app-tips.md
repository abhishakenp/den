# In-app discovery tips (spec)

The spec for the `tips` plugin (`Plugins/tips`): small, one-time hints that teach den's hidden gestures at the moment they're useful. Tips that point at features not yet on `main` are marked *(later)* and must stay off until those features ship.

## Status (what `Plugins/tips` does today)

- **Tour card**: from the second launch, in the sidebar's `sidebar.notice` slot above the footer ([host API](../host-api.md#ui)). The five steps show in that same card ("Tour · 2 of 5", Skip Tour / Next); each completes early on its event (`tabs.key.pin` or the tab menu's Pin, any `commands.run`, `spaces.current`, `peek.opened`). *Not yet:* callouts that point at the real UI, and step 2 opening the bar itself. The **Take the den Tour** command starts it again.
- **Import card**: shown only when some plugin provides the `importer` service; hidden otherwise. Nothing provides it yet. The contract an importer implements:
  - `importer.sources` → `[{id, name}]`, the browsers it found data for (`[]` or an error hides the card).
  - `importer.run {source}` → ok; it imports in the background and shows its own progress and result (a toast). The card goes away for good after one click (`tips.import = "done"`) or ×.
- **Tips**: 14 wired (the table below marks each one ✅). The toast has one **Don't show tips** button instead of a `…` menu, and stays up while the pointer is on it (`toast.hold`). Not yet enforced: "never during a drag or a text-field edit" (no event says so); the command bar, dialogs, sheets and popovers are checked (`ui.get` overlays).
- **Switch**: Settings ▸ General ▸ Tips ▸ **Show tips** (settings id `tips`, key `enabled`), the **Don't Show Tips** / **Show Tips** command, the toast button. Off also hides the tour and import cards.
- **Snapshots**: `--scenario tourCard|tourStep|tipToast` (`docs/screenshots/tour-card-dark.png`, `tour-step-dark.png`, `tip-toast-dark.png`). Tests: `Tests/PluginTests/TipsTests.swift`.

## Principles

### 1. Zero-friction start

Arc and Dia are the bar for onboarding, with one caveat: **nothing may slow down or gate starting to use den.**

- den opens instantly into a usable browser. No blocking welcome screen, sign-up or setup wizard, ever.
- **"Take a tour"** is an optional, small, skippable card. It has 5 steps or fewer, each step can be skipped, and once dismissed it never comes back.
- **Import** from Arc, Chrome or Safari is offered as a quiet one-click card, never a gate. *(Import isn't built yet.)*
- **Discovery tips** appear only when they're relevant to what you're doing right now: one at a time, each at most once, never modal, never interrupting typing or a drag.
- One global switch turns all of it off: **Settings ▸ General ▸ Show tips** (on by default), also reachable as "Don't show tips" in the command bar and on every tip's `…` menu.

### 2. Shortcuts everywhere an action appears

**Rule:** if an action has a keyboard shortcut, the shortcut is shown wherever the action is shown, right-aligned, in the same glyph style as the menu bar (⌃⌥⇧⌘ order). A remapped shortcut (`[shortcuts]` in `config.toml`) shows the new chord everywhere: surfaces name the action (`keyFor` on menu items, `shortcutFor` on buttons and card actions) and `Shortcuts` reads its chord from the menu bar item. Only icon-only buttons get native tooltips; rows never do (they have hover cards).

Audit checklist (tick when every item on that surface complies):

- [x] Menu bar
- [x] Command bar rows
- [x] Tab context menu (e.g. Pin Tab ⌘D, Archive Tab ⌘W, Rename…)
- [x] Space context menu (e.g. New Space, Move Left/Right)
- [x] Link context menu (web page)
- [x] Page context menu (web page: Back ⌘[, Reload ⌘R, …)
- [x] Folder and split context menus
- [x] Tooltips on hover-card buttons
- [x] Tooltips on every icon button (sidebar toggle ⌘S, back/forward, reload, Library ⇧⌘L, new space, …)
- [x] Settings rows that describe an action (e.g. Briefing ▸ shortcut, Clear Today ⇧⌘K)
- [x] Toasts that name an action ("Use ⌃Z to undo" already does)

## How a tip looks

- A **toast** in den's usual spot (top right, themed to the space). Text is one short sentence with the keystroke in it, plus a `…` menu with "Don't show tips".
- It stays up **6 s** (longer than the 2.2 s action toasts, since there's something to read), or until the tip's action is performed, whichever comes first. Hovering it keeps it up.
- Never while the command bar, a dialog, a sheet or a drag is active; never during a text-field edit; never in the first 60 s after launch.
- **At most one tip per 10 minutes** and three per day. If several trigger, the queue keeps the most recent and drops the rest (they can trigger again later).
- A tip whose action you already did on your own is **never shown** (each tip lists the event that retires it).

## Storage

- Keys live in plugin storage under `tips.shown.<key>` (bool) and `tips.retired.<key>` (bool). "Shown once" means: after one display, never again, whether or not it was acted on.
- `tips.enabled` (bool, default `true`) is the global switch.
- `tips.tour` is `"new" | "dismissed" | "done"`.

## The tour

A small card at the bottom of the sidebar on the **second** launch (never the first: the first launch is for browsing), reading **"New to den? Take a 1-minute tour"** with **Start** and ×. × sets `tips.tour = "dismissed"` for good. Each step is a small callout pointing at the real UI, with **Next** and **Skip tour**; the step completes early if you do the thing.

| # | Points at | Text | Completes when |
|---|---|---|---|
| 1 | the sidebar's Today section | "New tabs land in Today and archive themselves after a day. ⌘D pins one to keep it." | a tab is pinned, or Next |
| 2 | the command bar (opens it) | "⌘T does everything: tabs, the web, commands and settings. Try typing 'dark'." | a command bar result is chosen, or Next |
| 3 | the footer space icons | "Spaces keep work and life apart. Swipe with two fingers in the sidebar to switch." | a space switch, or Next |
| 4 | a link in the current page (or the page) | "⇧-click any link to Peek at it without leaving the page." | a Peek opens, or Next |
| 5 | the Library button | "Closed something? ⇧⌘T brings it back. Everything else is in the Library, ⇧⌘L." | Done |

Finishing or skipping sets `tips.tour = "done"`.

## Discovery tips

Each entry: **key** · trigger · text · retired by (the event that means you already know it).

### Sidebar & tabs

| Key | Trigger | Text | Retired by |
|---|---|---|---|
| `pinnedFavicon` | first time a pinned tab drifts from its pinned URL (the "/" appears) | "Click the favicon to go back to this tab's pinned page." | a pinned tab reset by its favicon or the menu |
| `renameTab` | 3rd time the user opens the tab context menu | "Double-click a tab to rename it." | an inline tab rename |
| `dropOnSpace` | first drag of a tab in the sidebar while more than one space exists | "Drop a tab on a space icon below to move it there." | a tab moved to another space by drop |
| `dropOnPage` | 2nd sidebar tab drag (and `dropOnSpace` shown) | "Drop a tab on the page to open it side by side." | a split created by a drop |
| ✅ `clearUndo` | 3 tabs closed with their × (or middle-click) within a minute | "⇧⌘K clears all of Today. ⌃Z undoes it." | `tabs.clear` used |
| ✅ `reopenClosed` | first ⌘W | "Closed tabs go to the Library. ⇧⌘T brings the last one back." | ⇧⌘T used, or the Library opened |
| `recentTab` | 5th click-switch between the same two tabs within 10 minutes | "⌃Tab jumps back to the tab you used last." | `tabs.recent` used |
| `middleClickClose` | 10th tab closed with the row's × button | "Middle-click a tab to close it." | a middle-click close |
| ✅ `edgeReveal` | first time the sidebar is hidden with ⌘S or the button | "Move to the left edge of the window to bring the sidebar back." | an edge reveal |
| ✅ `resetWidth` | first sidebar resize by dragging | "Double-click the sidebar edge to reset its width." | a double-click reset |

### Spaces & themes

| Key | Trigger | Text | Retired by |
|---|---|---|---|
| ✅ `swipeSpaces` | 3rd space switch by clicking a footer icon | "Swipe with two fingers in the sidebar to switch spaces." | a swipe switch |
| ✅ `spaceMenu` | first time a second space is created | "Right-click a space for its icon, theme and more." | the space menu opened |
| ✅ `renameSpace` | first rename via the space menu | "Next time, just double-click the space's name." | a double-click rename |
| ✅ `reorderSpaces` | 4th space created | "Drag space icons in the footer to reorder them." | a footer reorder |

### Links, Peek, split, previews

| Key | Trigger | Text | Retired by |
|---|---|---|---|
| `linkPreview` *(later)* | first time the pointer rests on a link for 1.5 s | "Hold ⇧ while hovering a link to preview it." | a ⇧-hover preview shown |
| `peekClick` | 5th link opened in a new tab and closed again within 30 s | "⇧-click or ⌥-click a link to Peek at it instead." | a Peek opened by click |
| ✅ `peekReopen` | first Peek closed with Esc less than 2 s after opening | "Closed it by mistake? ⌘Z brings it back." | ⌘Z reopen |
| ✅ `splitKeys` | first split view created | "⌃⇧1–4 focus a pane. ⌃⇧- closes the focused one." | a pane focused by keyboard |
| ✅ `prPeek` | first hover card for a GitHub pull request | "Hover a PR tab any time for its checks and reviews." | shown once, no retire event |

### Command bar & shortcuts

| Key | Trigger | Text | Retired by |
|---|---|---|---|
| ✅ `siteKeyword` | first time the command bar opens a site that has a keyword ("youtube.com") or runs a web search starting with a site's keyword or name ("yt cats", "wikipedia otters") | "Type yt, then Tab, to search YouTube directly." (that site's keyword and name) | a keyword search via Tab |
| `settingsInBar` | first time Settings is opened with ⌘, | "You can also type a setting's name in the command bar." | a Settings result chosen in the bar |
| ✅ `editUrl` | first click on the URL pill | "⌘L edits the address from anywhere." | ⌘L used |
| ✅ `copyMarkdown` | 3rd ⇧⌘C | "⌥⇧⌘C copies the link as Markdown." | ⌥⇧⌘C used |

### Connections & briefing

| Key | Trigger | Text | Retired by |
|---|---|---|---|
| ✅ `briefingKey` | first briefing opened from the command bar (its toast has no button) | "⇧⌘B opens your briefing any time." | ⇧⌘B used |
| `connectFromSite` *(later, auto-connect)* | first sign-in detected on github.com or slack.com with no connection | "You're signed in to GitHub. Connect it for your daily briefing?" with **Connect** | a connection added |

### Pages

| Key | Trigger | Text | Retired by |
|---|---|---|---|
| `siteDarkMode` | first time a very bright page is shown while den is in dark appearance | "Type 'dark' in the command bar to choose dark mode for this site." | a per-site dark mode choice |
| `findSelection` | 3rd ⌘F | "⌘E finds the selected text." | ⌘E used |

## Implementation notes

- Triggers come from events plugins already emit (tabs actions, `commands.run`, space switches, `ui` hover events); the tips plugin only listens, keeps counters in its own storage, and posts toasts through `ui`. It adds no work to the paths it observes, and loads lazily after the first window.
- Counters reset never; they're tiny.
- Every tip's text lives in one table in the plugin so it can be reviewed and translated in one place.
- Test each trigger with a scenario and a fresh store; test "shown once" and "retired by" with a second run on the same store.
