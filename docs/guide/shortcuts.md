# Keyboard shortcuts

Every shortcut is in den's menu bar (except the mini player's playback keys below), so you can always look one up there. In den, type **Keyboard Shortcuts** in the command bar (⌘T) for a searchable list you can run from.

Where Arc and Safari disagree, den follows Arc, and keeps Safari's key as a second shortcut when it's free. The side-by-side comparison with Safari, Chrome and Arc is in [docs/shortcuts.md](../shortcuts.md).

## Tabs

| Action | Keys |
|---|---|
| New tab (command bar) | ⌘T |
| Edit the address (command bar) | ⌘L |
| Close tab (Today tabs go to the Library) | ⌘W |
| Close other Today tabs | ⌥⌘W |
| New tab in the current group | ⌥⌘T |
| New folder with the selected tabs | ⌃⌘N |
| Reopen closed tab | ⇧⌘T |
| Next / previous tab | ⌥⌘↓ / ⌥⌘↑, or ⇧⌘] / ⇧⌘[ |
| Last-used tab / least-recent tab | ⌃Tab / ⌃⇧Tab |
| Tab 1…8, last tab | ⌘1…⌘8, ⌘9 (favorites first) |
| Pin / unpin | ⌘D |
| Clear Today tabs | ⇧⌘K |
| Undo sidebar action | ⌃Z |
| Library (closed tabs) | ⌘Y or ⇧⌘L |
| Downloads | ⌥⌘L |

## Navigation

| Action | Keys |
|---|---|
| Back / forward | ⌘[ / ⌘], or ⌘← / ⌘→ (when not typing in a field) |
| Reload | ⌘R |
| Reload from origin | ⇧⌘R |
| Stop | ⌘. |

Mouse back/forward buttons and two-finger swipes on the page work too.

## Page

| Action | Keys |
|---|---|
| Zoom in / out / actual size | ⌘+ (or ⌘=) / ⌘- / ⌘0 |
| Find, next, previous | ⌘F, ⌘G, ⇧⌘G |
| Find the selected text | ⌘E |
| Print | ⌘P |
| Save page (Web Archive) | ⇧⌘S |
| View source | ⌥⌘U |
| Web Inspector | ⌥⌘I |
| Inspect element | ⌥⌘C |
| JavaScript console | ⌥⌘J |
| Full screen | ⌃⌘F |
| Reader | ⌃⌘R |
| Capture a region, element, visible area or full page | ⇧⌘2 |

## Sidebar, split view, Peek, briefing

| Action | Keys |
|---|---|
| Show / hide sidebar | ⌘S |
| Add split pane | ⌃⇧= |
| Close split pane | ⌃⇧- |
| Focus split pane 1…4 | ⌃⇧1…⌃⇧4 |
| Close Peek | Esc (while a Peek is open) |
| Reopen the Peek you just closed | ⌘Z (for 15 s after closing it) |
| Move a Peek or Little Arc window into the space | ⌘O |
| Daily briefing | ⇧⌘B (change it in Settings ▸ Briefing) |
| Show / hide the web panel | ⌃⌘S |

## Media

| Action | Keys |
|---|---|
| Play / pause what's playing | ⌃⌘P, or the play/pause key |
| Next / previous track | ⌃⌘→ / ⌃⌘←, or the keyboard's media keys |

## Mini player

While the mini player is the active window:

| Action | Keys |
|---|---|
| Play / pause | Space |
| Back / forward 5 s | ← / → |
| Back / forward a tenth of the video | ⌘← / ⌘→ |
| Start / end | Home / End |
| Volume up / down | ↑ / ↓ |
| Mute / unmute | M, or ⌘↓ / ⌘↑ |
| Subtitles on / off | C |
| Keep on top on / off | T |
| Back to the tab | Esc |
| Close the player | ⌘W |

## Copying

| Action | Keys |
|---|---|
| Copy the page's URL | ⇧⌘C |
| Copy the page's URL as Markdown `[title](url)` | ⌥⇧⌘C |
| Share the page (AirDrop, Messages…) | File ▸ Share…, no key |
| QR code for the page | File ▸ QR Code for This Page, no key |
| Paste and Go / Paste and Search | right-click the URL pill or the command bar field |

## Spaces

| Action | Keys |
|---|---|
| Space 1…9 | ⌃1…⌃9 |
| Next / previous space | ⌥⌘→ / ⌥⌘← |
| Switch spaces | two-finger swipe in the sidebar |

## App

| Action | Keys |
|---|---|
| Settings | ⌘, |
| Minimize | ⌘M |
| Close window | ⇧⌘W |
| Hide den | ⌘H |
| Hide other apps | ⌥⌘H |
| Quit | ⌘Q (asks first; turn that off in Settings ▸ General) |

Plus the standard text shortcuts: ⌘Z, ⇧⌘Z, ⌘X, ⌘C, ⌘V, ⌥⇧⌘V, ⌘A.

## Other keyboard layouts

Shortcuts go by the character a key types, so on Dvorak ⌘W is the key labelled W on your layout, and on QWERTZ ⌘Z is the Z key. When your layout can't type a shortcut's character without extra keys (AZERTY's number row, where ⌃1 is ⌃&; brackets behind a dead key; every letter on Cyrillic, Greek or Hebrew layouts), den uses that key's position on a US keyboard instead, like Chrome and Firefox. Your layout's own shortcut always wins.

## Change any shortcut

In `~/.den/config.toml`, map a chord to a menu item id or a command id. It applies when you save.

```toml
[shortcuts]
"cmd+shift+j" = "tabs.next"          # a menu item gets this key instead of its default
"cmd+shift+y" = "den.copyMarkdown"   # any command bar command
```

Chords use `cmd`, `shift`, `opt`, `ctrl` plus a key (`a`, `]`, `left`, `tab`, `f5`, `plus`). A remapped menu item loses its default key. A command bound this way shows up in a **Shortcuts** menu. Menu item ids are in the last column of [docs/shortcuts.md](../shortcuts.md); command ids are in [docs/plugin-services.md](../plugin-services.md).

## Not there yet

New window (⌘N) and private window (⇧⌘N) have no shortcut because den doesn't have those features yet. See [Coming soon](coming-soon.md).
