# Defaults

Every default den ships with, and why. The rule: pick what a discerning user would pick, never make someone undo an annoyance, and prefer "recoverable and quiet" over "asks first". Settings (⌘,) changes all of these unless marked otherwise.

Rows marked **changed** were annoying defaults and have been fixed.

## Tabs

| Setting | Default | Why |
|---|---|---|
| Archive Today tabs after | **24 hours** (changed, was 12 h) | Arc uses 12 h, and losing tabs is the most common complaint about Arc. At 12 h, a tab you open at 6 pm is gone by 6 am, before you're back at your desk. 24 h keeps yesterday's tabs through today and still clears the pile daily. Archived tabs stay in the Library, and ⇧⌘T brings the last one back. Pinned tabs, favorites, the selected tab and tabs playing audio are never archived |
| Unload idle tabs after | 5 min of den-frontmost time | Background tabs are den's biggest memory cost. A suspended tab keeps its history and scroll position (`interactionState`) and a snapshot, and reloads when you come back. Time in other apps doesn't count (Dia 1.8), so tabs you left before lunch don't reload after it. Tabs on screen (including every pane of a split), playing media or in picture in picture, using the camera or mic, or holding unsaved form input never unload. 0 turns it off |
| Never unload the most recently used tabs | the last 5 (not a setting) | Dia 1.5. Switching back to a tab you used a minute ago should never reload it. Five is den's choice: it covers a working set of a few tabs plus a split; it was not tuned by measurement |
| ⌘W on a Today tab | archives it (Arc) | Nothing is lost: it's in the Library, and ⇧⌘T reopens it |
| Clear Today tabs (⇧⌘K) | instant, with an "Undo ⌃Z" toast | Arc does the same. An undo toast beats a confirmation dialog |
| New tab (⌘T) | the command bar | Arc |
| ⌘-click / middle-click a link | background tab; ⌘⇧-click opens it in front | What every browser does |
| Mini player when you leave a playing video | on | Arc's "Picture in Picture when you leave a video tab". Only an audible video that's playing triggers it; the page is never reloaded. Toggle it from the command bar ("Mini player when you leave a playing video") |
| Group ⌘-clicked links | on | Dia. A ⌘-clicked link from a Today tab joins that tab in a group, so research stays together, and a group of one dissolves by itself. ⌃Z right after takes the group away; off gives Arc's plain background tab |
| Name groups with the on-device model | when Apple Intelligence is available | The site-based name ("WebKit & Apple") shows at once; the model's name replaces it a moment later unless you renamed the group. Nothing waits for it and nothing leaves the Mac |

## Links

| Setting | Default | Why |
|---|---|---|
| Peek at links from pinned tabs and favorites | on | Arc. A link to another site from a pinned "app" (Gmail, Linear) opens over it instead of navigating the app away. Links within the same site navigate normally |
| Shift-click or ⌥-click any link | Peek | Arc. It never triggers by accident |
| Open links from other apps in a mini window | **off** (changed) | Arc forces Little Arc windows for links from other apps; many people dislike a floating window they didn't ask for. Links open as a normal tab in the current space. The mini window is one toggle away |
| Archive unused mini windows | after 6 h | Arc. Only matters with the toggle above on; the page goes to the Library |
| Reopen a closed Peek with ⌘Z | for 15 s | Long enough to fix a mis-click, short enough that ⌘Z goes back to meaning Undo |

## Quitting

| Setting | Default | Why |
|---|---|---|
| Ask before quitting | on | ⌘Q sits next to ⌘W; quitting by accident kills playing video, form input and page state. The dialog has "Always quit" on first sight, so anyone who hates it turns it off in one click. Tabs come back after a quit either way |
| Close window (⇧⌘W) | never asks | Arc. Tabs are kept, nothing is lost |

## Search and the command bar

| Setting | Default | Why |
|---|---|---|
| Search engine | Google | The most common choice and what the suggestions come from. DuckDuckGo, Kagi, etc. are one site-search keyword away (Settings > Search > Add) |
| Site-search keywords | `g`, `yt`, `gh`, `w`, `maps`, `x` | Type the keyword and Tab |
| Search suggestions | on | Suggestions are most of what makes a command bar fast. The Settings row says plainly that typing is sent to Google; turn it off and nothing leaves den until Return |
| Default-browser banner | shown until you act on it; **× hides it for good** (changed, was 14 days) | A dismissed nag coming back every two weeks is exactly the kind of thing people hate. Settings > General has "Make den Default", and Settings > Search can bring the banner back |
| "Try for a week" | asks after 7 days whether to keep den | You opted in; den asks once and can switch back |

## Look and feel

| Setting | Default | Why |
|---|---|---|
| Appearance | Automatic (follows macOS) | Arc's global appearance; light at noon, dark at night if macOS does |
| Accent color | the space's colors | Arc. Settings > General can use the macOS accent instead |
| Theme for new spaces | a soft two-color gradient, intensity 0.6, grain 0.3 | Visible but calm; first run seeds Personal, Work and Side Project with different gradients so spaces are told apart at a glance |
| Surface colors and contrast | derived from the space, WCAG AA or better | Every dialog, bar, card and toast follows the theme, and text is pushed to 7:1 (primary) and 4.5:1 (secondary) so very light or dark themes stay readable (host-api.md, Theming) |
| Sidebar | shown, 228 pt | Arc's width. ⌘S hides it; the left edge reveals it |
| Haptics | on (drag-reorder, drop targets, the theme picker, space reorder) | Subtle trackpad ticks, as in Arc ("Haptic feedback when reordering tabs"). Only Force Touch trackpads feel them. No setting yet |
| Sounds | none | den plays no sound effects. Arc has a few and a switch to turn them off; den doesn't need the switch |
| Dark mode for websites | on, following den's appearance | Sites with their own dark mode use it; light-only sites are inverted (images and video kept) only while den is dark. Per site: follow den, always dark, always light or off, from the command bar |
| Motion | short, eased; none with Reduce Motion | Space switch, peek open, hover cards and reorder all respect Reduce Motion |

## Reading (page tools)

| Setting | Default | Why |
|---|---|---|
| Reader font / text size | serif, 19 px | Settings > Reading |
| Read-aloud speed | 1× | Settings > Reading |
| Capture (⇧⌘2) goes to | the clipboard | Paste it anywhere; "Save as a PNG file" is the other choice |

## Hover previews

| Setting | Default | Why |
|---|---|---|
| Show a card when hovering a tab | after 450 ms | Long enough that sweeping over the sidebar shows nothing; once a card is up the next row's shows at once. No network, timers or snapshots until you actually hover |
| Page snapshots | only when hovered, kept 30 s | Costs nothing at rest |

## Connections and briefing

| Setting | Default | Why |
|---|---|---|
| Connections | none | Nothing is read until you connect an account, and only through the session you signed in to inside den |
| Morning briefing | on, 8:00 AM | Only exists while something is connected; no connection means no schedule, no timers and no toast. The toast is the only interruption, once a day |
| Refresh while connected | every 15 min and on wake | Keeps the briefing current without polling when nothing's connected |
| Open the briefing | ⇧⌘B | Changeable in Settings > Briefing |

## Things that are fixed (no setting)

| Behavior | Why |
|---|---|
| No launch work for optional features | Settings, connections, previews and the briefing build nothing until used; plugins load lazily. Launch time is measured on every change |
| Toasts last 2.2 s, top right | Arc's placement; long enough to read, short enough not to linger |
| Downloads list, profiles UI | Not built yet (README). Extensions have shipped (command bar: Extensions) |
