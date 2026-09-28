# Coming soon

What's being built or planned, from [ROADMAP.md](../../ROADMAP.md) and the current work plan. **No promises and no dates.** Plans change, and anything here may ship differently or not at all. None of it is in den today; everything in the rest of this guide is.

## Tabs

- **⌘-click grouping** like Dia: a ⌘-clicked link opens under its source tab and the two are grouped, later ⌘-clicks from either join the group, and ⌥⌘T opens a new tab in it.
- Folder shortcuts: a folder from the selection, drag a tab onto a folder to file it, rename on create.
- A collapsed folder showing its active tab; hovering it lists its tabs.
- **Live folders** fed by GitHub or RSS.
- Unloaded tabs that cost close to nothing (today about 80 KB each; the goal is 8 KB), recently used tabs kept loaded, and idle time counted only while den is in front.
- No white flash on tab switch or load; faster tab close.
- Tab menus that show shortcuts and ⌥ alternates.
- Auto tab grouping and tidying with Apple's on-device model.
- Copy a clean URL with tracking parameters stripped.

## Media

- **Automatic system picture in picture** like Safari's, when you leave a tab playing video (today den's own mini player follows you instead).

## Connections & briefing

- **Auto-connect** like Dia: if you're already signed in to GitHub or Slack in den, or sign in later, it connects without a click, with a "GitHub connected · Undo" toast.
- **Important** Slack channels and GitHub repos, ranked higher and never dropped from the summary.
- More connections as plugins: Gmail and Google Calendar first; Notion, Linear, Jira and others later.
- A meeting reminder card with a Join button and countdown.
- An official OAuth option for people who'd rather not reuse their session.
- The model loaded only while writing a briefing, then released.

## Browsing

- Profile management, and private windows.
- A built-in ad and tracker blocker.
- Link routing rules (URL → space), like Arc's Air Traffic Control.
- Boosts: per-site colors, fonts and CSS.
- Crash recovery; a "Page crashed · Reload" view and protection against endless alerts.
- Web apps (PWA).
- Non-US keyboard layouts for shortcuts, and CJK input in the command bar.
- Resizing split panes by dragging.

## Import, sync, passwords

- Import from Arc (spaces, pinned tabs), then Chrome, Safari, Firefox, Zen and Dia. Offered as a quiet card, never a gate.
- Passkeys on every site, once Apple grants den the browser passkey entitlement.
- A native-messaging bridge for password manager extensions.
- Sync of spaces and tabs through iCloud, with no den server.

## Getting around

- A short, skippable **tour** and one-time **tips** that teach den's hidden gestures when they're relevant ([spec](_in-app-tips.md)).
- Shortcuts shown next to every action in every menu, card and tooltip.

## Release

- A signed and notarized `.dmg` on GitHub Releases, with automatic updates through the `stable` channel.
- Energy budgets and benchmarks against Safari, Arc, Dia and Zen on a quiet machine.
