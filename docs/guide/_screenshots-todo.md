# Screenshots the guide still needs

Every guide page uses existing shots from `docs/screenshots/`. These are the ones that are missing, or that exist but show the wrong thing. Regenerate them on a quiet machine, never while other builds run.

All commands run from the repo root after `scripts/bundle.sh`, with the same flags `scripts/snapshots.sh` uses:

```sh
DEN=build/den.app/Contents/MacOS/den
# window snapshot (renders den's own window to PNG, then quits)
$DEN --no-den-home --storage "$(mktemp -d)" --appearance light --scenario <name> --snapshot docs/screenshots/<file>.png --snapshot-delay 4
```

Native menus and the Settings window draw blank through `--snapshot`. Capture those with `--stay` and `screencapture -l<window id>`, as the `menu()` and `win()` helpers in `scripts/snapshots.sh` do. Store at 1x afterwards: `sips -Z 1280 <file>`.

## Existing scenario, just not captured

| File | For | Command |
|---|---|---|
| `vault-save.png` (+ `-dark`) | [Passwords](privacy-and-passwords.md#passwords-the-touch-id-vault): "Save password for …?" | `--scenario vaultSave --snapshot docs/screenshots/vault-save.png` |
| `vault-fill.png` (+ `-dark`) | Passwords: the login list under a field | `--scenario vaultFill --snapshot docs/screenshots/vault-fill.png` |
| `vault-suggest.png` | Passwords: "Use Strong Password" | `--scenario vaultSuggest --snapshot docs/screenshots/vault-suggest.png` |
| `vault-generate.png` | Passwords: the generated password filled in | `--scenario vaultGenerate --snapshot docs/screenshots/vault-generate.png` |
| `vault-sheet.png` (+ `-dark`) | Passwords: the "Passwords…" list | `--scenario vaultSheet --snapshot docs/screenshots/vault-sheet.png` |
| `dark-mode-site.png` | [Dark mode for websites](privacy-and-passwords.md#dark-mode-for-every-website): a normally light page darkened | `--appearance dark --scenario page --url https://example.com --snapshot docs/screenshots/dark-mode-site.png --snapshot-delay 6` |
| `quit-dialog.png` (+ `-dark`) | the real quit dialog ("Always quit", Cancel, Quit). The current file is overwritten by the `dialogQuit` stand-in, whose button reads "Quit, and don't ask again", which den doesn't have | `--scenario dialog --snapshot docs/screenshots/quit-dialog-dark.png`, and drop the later `host quit-dialog dialogQuit` lines from `scripts/snapshots.sh` |
| `file-upload.png` | page prompts | `--scenario fileUpload --snapshot docs/screenshots/file-upload.png` (host scenario: reuse one `--storage` dir like `host()` does) |
| `js-confirm.png` | page prompts | `--scenario jsConfirm --snapshot docs/screenshots/js-confirm.png` (host scenario) |
| `command-bar-settings.png` (+ `-dark`) | [Settings from the bar](command-bar.md#settings-from-the-bar) with den's **real** settings. The `launcher-*` shots use a stand-in settings list (General, Appearance, Privacy) with rows den doesn't have, so the guide doesn't show them | `--scenario "commandBar:search suggestions" --snapshot docs/screenshots/command-bar-settings.png --snapshot-delay 3` (check that `commandBar:` uses the real `settings` service; if not, it needs the fix below) |
| `command-bar-keyword.png` | site keywords: "Search YouTube — Press Tab" | `--scenario "commandBar:yt" --snapshot docs/screenshots/command-bar-keyword.png --snapshot-delay 3` |
| `command-bar-shortcuts.png` | "Keyboard Shortcuts" row | `--scenario "commandBar:keyboard shortcuts" --snapshot docs/screenshots/command-bar-shortcuts.png --snapshot-delay 3` |
| `little-arc-cmd-o.png` | Little Arc ▸ ⌘O into the space | `--scenario littleArcCmdO --snapshot docs/screenshots/little-arc-cmd-o.png --snapshot-delay 6` |

## Needs a new or fixed scenario

| File | For | What the scenario has to do |
|---|---|---|
| `dialog-delete-space.png` (+ `-dark`) | [Space menu](spaces-and-themes.md#the-space-menu) ▸ Delete Space… | `dialogDeleteSpace` shows made-up copy ("You can undo this with ⌘Z", a "Delete Space" button). Real copy: "Delete your \<Name\> Space?", "This will archive all the tabs and folders inside it.", Cancel / Delete. Point the scenario at the spaces plugin's dialog, then `--scenario dialogDeleteSpace` |
| `launcher-*.png` | [Command bar](command-bar.md#settings-from-the-bar) | `CommandBarScenarios.launcher` registers stand-in settings and fake `downloads` services. Switch it to the real plugins' settings and drop the fake Downloads, then rerun the `launcher:` loop in `scripts/snapshots.sh` |
| `pinned-drifted.png` | the **/** marker on a pinned tab that browsed away | a pinned tab navigated to another URL on the same site, pointer on its favicon |
| `drop-on-space.png` | dropping a tab on a footer space icon | a sidebar drag held over a footer icon (highlighted), like `spaceReorder` holds a drag mid-way |
| `drop-on-page.png` | the tinted split drop zone over the page | a sidebar tab drag held over the left third of the page |
| `split-pane-hover.png` | a split pane's × and "Separate" buttons | `split` plus a hover on the second pane |
| `peek-open.png` | a Peek from ⇧-click with its Open as Tab / Open in Split View buttons | exists as `peek-card.png` from a host scenario; a real ⇧-click in the `peek` app scenario would show the full window |
| `preview-gmail.png`, `preview-slack.png`, `preview-github-issue.png` | [Hover previews](hover-previews.md#what-the-cards-show) | `prFailing`-style scenarios for the Gmail, Slack and issue providers, fed by `MockServices` |
| `try-for-a-week.png` | [Default browser](getting-started.md#make-den-your-default-browser): the 7-day "Keep den as your default browser?" dialog | a scenario that fakes the week having passed |
| `settings-general.png` | Settings ▸ General with `~/.den` on (the current `settings.png` says "~/.den is off for this run") | the `settings` scenario with a throwaway `DEN_HOME` instead of `--no-den-home` |

Screenshots of features that aren't merged (⇧-hover link previews) wait for those features. Mute, the mini player and page tools are merged and have shots (`tab-audio`, `mini-player`, `pagetools-*`).

## Dark variants needed

The docs and README use dark screenshots only. These are still light-only; render each with `--appearance dark` (preferably on the CI snapshot job) and swap the reference:

- `briefing-feed-dark.png`
- `command-bar-edit-dark.png`
- `command-bar-keyword-dark.png`
- `command-bar-settings-dark.png`
- `command-bar-shortcuts-dark.png`
- `connect-toast-dark.png`
- `dark-mode-site-dark.png`
- `extensions-add-to-den-dark.png`
- `extensions-add-to-den-amo-dark.png`
- `extensions-permission-prompt-dark.png`
- `extensions-popup-dark.png`
- `file-upload-dark.png`
- `js-confirm-dark.png`
- `little-arc-cmd-o-dark.png`
- `little-arc-link-dark.png`
- `pagetools-highlight-link-dark.png`
- `pagetools-reader-dark.png`
- `pagetools-translated-dark.png`
- `pagetools-zap-dark.png`
- `sidebar-hidden-dark.png`
- `sidebar-hover-reveal-dark.png`
- `space-2-dark.png`
- `space-swipe-dark.png`
- `split-grid-dark.png`
- `split-view-dark.png`
- `theming-grid-dark.png`
- `vault-fill-dark.png`
- `vault-generate-dark.png`
- `vault-save-dark.png`
- `vault-sheet-dark.png`
- `vault-suggest-dark.png`
