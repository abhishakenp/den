# Keyboard shortcuts

den's shortcuts next to Safari's, Chrome's and Arc's. Arc's come from its live menus and nib (spec §9, `docs/research/arc.md` §15). Where Arc and Safari disagree, Arc wins, and the standard key is kept as a second shortcut when it's free.

Every shortcut is an item in den's menu bar (den, File, Edit, View, History, Spaces, Tabs, Window, Help; the mini player's playback keys are the exception), so it shows its key and goes through AppKit's normal key-equivalent path. A second key for the same action is a hidden alternate of that item. `ShortcutTests.everyShortcutDispatchesThroughTheMainMenu` sends the chords below through the real main menu as keyboard events and checks the command each reaches (not yet covered: Esc for Close Peek, ⌘Z Reopen Peek, ⌥⌘H, Reader ⌃⌘R, Capture ⇧⌘2).

**Remapping.** In `~/.den/config.toml`, `[shortcuts]` maps a chord to a menu item id (the last column), or to a command bar command id:

```toml
[shortcuts]
"cmd+shift+j" = "tabs.next"          # a menu item takes the new key
"cmd+shift+y" = "den.copyMarkdown"   # any command bar command
```

Chords are `cmd`, `shift`, `opt`, `ctrl` plus a key (`a`, `]`, `left`, `tab`, `f5`, `plus`). Changes apply when you save the file.

## Tabs

| Action | Safari | Chrome | Arc | den | Item id |
|---|---|---|---|---|---|
| New tab (command bar) | ⌘T | ⌘T | ⌘T | ⌘T | `file.newTab` |
| Close tab | ⌘W | ⌘W | ⌘W (Archive Tab) | ⌘W (a Today tab goes to the Library) | `file.closeTab` |
| Close other tabs | ⌥⌘W | – | – | ⌥⌘W (Today tabs; ⌃Z brings them back) | `file.closeOthers` |
| New tab in group | – | – | – (Dia: ⌥⌘T) | ⌥⌘T | `file.newTabInGroup` |
| New folder with selected tabs | – | – | – (Dia: ⌃⌘N) | ⌃⌘N | `tabs.newFolder` |
| Reopen closed tab | ⇧⌘T | ⇧⌘T | ⇧⌘T | ⇧⌘T | `file.reopenTab` |
| Next tab | ⇧⌘], ⌃Tab | ⌥⌘→, ⌃Tab | ⌥⌘↓ | ⌥⌘↓, ⇧⌘] | `tabs.next` |
| Previous tab | ⇧⌘[, ⌃⇧Tab | ⌥⌘←, ⌃⇧Tab | ⌥⌘↑ | ⌥⌘↑, ⇧⌘[ | `tabs.prev` |
| Recent tab (switcher) | – | – | ⌃Tab / ⌃⇧Tab | ⌃Tab (last used), ⌃⇧Tab (least recent) | `tabs.recent`, `tabs.recentBack` |
| Tab 1…8, last tab | ⌘1…9 | ⌘1…9 | ⌘1…9 | ⌘1…9 (favorites first) | Tabs ▸ Go to Tab |
| Pin / unpin | – | – | ⌘D | ⌘D | `tabs.pin` |
| Clear Today tabs | – | – | ⇧⌘K | ⇧⌘K (undo with ⌃Z) | `tabs.clear` |
| Tidy Today tabs into groups | – | – | – (Arc Max: Tidy button) | ⌃⇧T (on-device model, off until turned on in Settings ▸ Tabs; undo with ⌃Z) | `tabs.tidy` |
| Undo sidebar action | – | – | ⌃Z (toast) | ⌃Z | `tabs.undo` |
| Open Peek / mini window in space | – | – | ⌘O | ⌘O | `file.openInSpace` |
| New window | ⌘N | ⌘N | ⌘N | – | den has one window with every space in it (Arc's windows share spaces too). Not planned yet |
| New private window | ⇧⌘N | ⇧⌘N | ⇧⌘N | – | Needs private tabs; the `private` web profile exists, the UI doesn't yet |

**Non-US keyboards.** Shortcuts match the character a key types (Dvorak and QWERTZ letters keep their own keys). A key whose layout can't type the shortcut's character (AZERTY's ⌃& for ⌃1, the ⌘^ dead key for ⌘[, any Cyrillic, Greek or Hebrew letter) runs the shortcut at that key's US position, as Chrome and Firefox do, unless the typed character is itself a shortcut (`KeyLayoutFallback`, tested with the French, Russian, Dvorak and German layouts in `PageSafetyTests`).

`⌃Tab` in Safari and Chrome is next tab; Arc wins, so in den it's the recent-tab switch (Arc's tab switcher), and next/previous tab keep Safari's ⇧⌘] / ⇧⌘[.

## Navigation

| Action | Safari | Chrome | Arc | den | Item id |
|---|---|---|---|---|---|
| Back | ⌘[, ⌘← | ⌘[, ⌘← | ⌘[, ⌘← | ⌘[, ⌘← | `history.back` |
| Forward | ⌘], ⌘→ | ⌘], ⌘→ | ⌘], ⌘→ | ⌘], ⌘→ | `history.forward` |
| Reload | ⌘R | ⌘R | ⌘R | ⌘R | `view.reload` |
| Reload from origin | ⌥⌘R | ⇧⌘R | ⇧⌘R | ⇧⌘R | `view.reloadHard` |
| Stop | ⌘. | Esc | ⌘. | ⌘. | `view.stop` |
| Home | ⇧⌘H | ⇧⌘H | – | – | den has no home page (Arc neither). ⇧⌘H is left free |
| Mouse back / forward buttons | ✓ | ✓ | ✓ | ✓ | web view |
| Two-finger swipe back / forward | ✓ | ✓ | ✓ | ✓ (`allowsBackForwardNavigationGestures`) | web view |

⌘← and ⌘→ go back and forward only when you aren't editing text: a web page's text field gets them first (WKWebView offers keys to the page before the menu), and while a native field (the command bar, a Settings field) is editing, the menu items stand aside.

## Page

| Action | Safari | Chrome | Arc | den | Item id |
|---|---|---|---|---|---|
| Zoom in | ⌘+ | ⌘+ | ⌘+ | ⌘+, ⌘= | `view.zoomIn` |
| Zoom out | ⌘- | ⌘- | ⌘- | ⌘- | `view.zoomOut` |
| Actual size | ⌘0 | ⌘0 | ⌘0 | ⌘0 | `view.zoomReset` |
| Pinch zoom, smart zoom | ✓ | ✓ | ✓ | ✓ | web view |
| Find | ⌘F | ⌘F | ⌘F | ⌘F | `edit.find.show` |
| Find next / previous | ⌘G / ⇧⌘G | ⌘G / ⇧⌘G | ⌘G / ⇧⌘G | ⌘G / ⇧⌘G | `edit.find.next`, `edit.find.previous` |
| Use selection for find | ⌘E | ⌘E | – | ⌘E | `edit.find.selection` |
| Print | ⌘P | ⌘P | ⌘P | ⌘P | `file.print` |
| Save page | ⌘S | ⌘S | ⇧⌘S (⌘S is the sidebar) | ⇧⌘S (Web Archive) | `file.savePage` |
| View source | ⌥⌘U | ⌥⌘U | ⌥⌘U | ⌥⌘U | `view.viewSource` |
| Web Inspector | ⌥⌘I | ⌥⌘I | ⌥⌘I | ⌥⌘I | `view.inspector` |
| Inspect element | ⇧⌘C | ⇧⌘C | ⌥⌘C | ⌥⌘C | `view.inspectElement` |
| JavaScript console | ⌥⌘C | ⌥⌘J | ⌥⌘J | ⌥⌘J | `view.console` |
| Full screen | ⌃⌘F | ⌃⌘F | ⌃⌘F | ⌃⌘F | `view.fullScreen` |
| Reader | ⇧⌘R | – | – | ⌃⌘R (View ▸ Reader) | `pagetools.reader` (command) |
| Capture (region; the bar switches to element, visible area, full page) | – | – | ⇧⌘2 | ⇧⌘2 (View ▸ Capture…) | `pagetools.capture.region` (command) |

Reader: Safari's ⇧⌘R is Arc's (and den's) Reload from Origin, so Reader is ⌃⌘R. ⌘S: Arc wins (Show/Hide Sidebar), so saving is Arc's ⇧⌘S. ⌥⌘C: Arc's Inspect Element wins over Safari's console; the console is ⌥⌘J like Chrome and Arc.

## Sidebar, split view, briefing

| Action | Arc | den | Item id |
|---|---|---|---|
| Show / hide sidebar | ⌘S | ⌘S | `view.sidebar` |
| Add split view | ⌃⇧= | ⌃⇧= | `view.addSplit` |
| Close split pane | ⌃⇧- | ⌃⇧- | `view.closePane` |
| Focus split pane 1…4 | ⌃⇧1…4 | ⌃⇧1…4 | View ▸ Focus Split Pane |
| Close Peek | Esc | Esc (only while a Peek is open) | `view.closePeek` |
| Reopen the Peek you just closed | – | ⌘Z (for 15 s after closing it; then ⌘Z is Undo again) | Edit ▸ Reopen Peek |
| Daily briefing | – | ⇧⌘B (changeable in Settings > Briefing) | `view.briefing` |

## Address and sharing

| Action | Safari | Chrome | Arc | den | Item id |
|---|---|---|---|---|---|
| Open location (command bar, edit URL) | ⌘L | ⌘L | ⌘L | ⌘L | `file.openLocation` |
| Copy URL | – | – | ⇧⌘C | ⇧⌘C | `edit.copyURL` |
| Copy URL as Markdown | – | – | ⌥⇧⌘C | ⌥⇧⌘C | `edit.copyMarkdown` |

## App

| Action | Safari | Chrome | Arc | den | Item id |
|---|---|---|---|---|---|
| History | ⌘Y | ⌘Y | ⌘Y | ⌘Y (the Library: den's archive of closed tabs) | `history.library` |
| Library | – | – | ⇧⌘L | ⇧⌘L | `history.library` |
| Downloads | ⌥⌘L | ⇧⌘J | ⇧⌘J | – | den has no downloads list yet (a link's or image's context menu has Save Link As… / Save Image As…) |
| Settings | ⌘, | ⌘, | ⌘, | ⌘, | `app.settings` |
| Minimize | ⌘M | ⌘M | ⌘M | ⌘M | `window.minimize` |
| Close window | ⇧⌘W | ⇧⌘W | ⇧⌘W | ⇧⌘W | `file.closeWindow` |
| Hide | ⌘H | ⌘H | ⌘H | ⌘H | `app.hide` |
| Quit | ⌘Q | ⌘Q | ⌘Q | ⌘Q (asks first; Settings > General) | `app.quit` |

den ▸ Hide Others is ⌥⌘H (`app.hideOthers`).

## Spaces

| Action | Arc | den | Item id |
|---|---|---|---|
| Space 1…9 | ⌃1…9 | ⌃1…9 (listed by name) | Spaces menu |
| Next / previous space | ⌥⌘→ / ⌥⌘← | ⌥⌘→ / ⌥⌘← | `spaces.next`, `spaces.prev` |
| Two-finger swipe in the sidebar | ✓ | ✓ | – |

## Mini player

While the mini player window is key (a playing video you left, see [guide/media.md](guide/media.md)). These are the panel's own keys, not menu items, so they can't be remapped.

| Action | den |
|---|---|
| Play / pause | Space |
| Back / forward 5 s | ← / → |
| Volume up / down | ↑ / ↓ |
| Mute / unmute | M |
| Back to the tab | Esc |

## Edit

The standard text shortcuts: Undo ⌘Z, Redo ⇧⌘Z, Cut ⌘X, Copy ⌘C, Paste ⌘V, Paste and Match Style ⌥⇧⌘V, Select All ⌘A (`edit.*`). macOS adds Start Dictation and Emoji & Symbols to the Edit menu.
