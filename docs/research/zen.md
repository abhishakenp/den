# Zen Browser — Research for den

> Research snapshot, 2026-09-27. Decisions made later are in [ROADMAP.md](../../ROADMAP.md) / [FEATURES.md](../FEATURES.md).

Researched 2026-09-27. Sources are cited per section. Numbers marked "observed" come from the GitHub API or pages fetched on that date. Anything I could not confirm directly is marked **UNVERIFIED**.

---

## 1. Snapshot (observed)

| Fact | Value | Source |
|---|---|---|
| Repo | github.com/zen-browser/desktop (created 2024-03-28) | GitHub API `repos/zen-browser/desktop` |
| License | MPL-2.0 | GitHub API; docs.zen-browser.app/contribute |
| Stars / forks | 44,613 / 1,775 | GitHub API |
| Open issues + PRs | 713 | GitHub API `open_issues_count` |
| Contributors | 236 (non-anonymous, from API pagination) | `repos/zen-browser/desktop/contributors?per_page=1` → last page 236 |
| Default branch | `dev` | GitHub API |
| Latest release | 1.22.3b (2026-09-23), based on Firefox 156.0.1; "Twilight" nightly channel on Firefox 157.0 RC | GitHub releases; `surfer.json` |
| Discussions | 3,542 total; categories: Announcements, General, Ideas, Polls, Q&A, Show and tell | GitHub GraphQL |
| Mods in the official store | 77 mod directories in `zen-browser/theme-store/themes` | GitHub API |
| Initial public release | 2024-07-11 | en.wikipedia.org/wiki/Zen_Browser |

Every release tag still ends in `b` (beta), more than two years after launch.

---

## 2. Feature inventory

### 2.1 Workspaces ("Spaces")
- Group tabs by project and switch between the groups. Each Space has its own name and icon, and the Space icons sit at the bottom of the sidebar.
- **Container binding:** a Firefox container can be set as a Space's default. An optional setting moves container tabs into their matching Space automatically.
- Containers keep cookies and sessions apart, but *not* history or extensions (the docs say this explicitly).
- There are 4 default containers (Personal, Work, Banking, Shopping), with 9 colors and 13 icons to choose from.
- **Per-Space themes:** each Space has its own background gradient, made with a gradient generator. Supported options:
  - up to three-color gradients (rendering improved in 1.18b)
  - background grain/texture (macOS gives haptic feedback when you change it, 1.12.4b, pref `zen.haptic-feedback.enabled`)
  - monochrome themes and a custom color algorithm (1.17.13b)
  - animated transitions between Space gradients (1.12.7b)
- **Space Routing** (1.21b): sends links for chosen domains to a specific Space. It is Zen's version of Arc's "Air Traffic Control", and was requested in discussion #5002 (81 upvotes, closed). A context-menu item "Add Route for Domain" exists.
- Space context-menu actions include "Unload space" and "Unload all spaces except current".
- Swiping on the trackpad switches Spaces. Open issues #15525 and #15557 are about swipe bugs.
- **Share** (1.22.1b): Spaces, folders and split views can be shared by link, including with people who don't use Zen.
- Sources: https://docs.zen-browser.app/user-manual/workspaces ; release notes at https://github.com/zen-browser/desktop/releases

### 2.2 Essentials and pinned tabs
- **Essentials:** tabs shown as a favicon grid at the top of the sidebar, available in every Space. The cap is set by `zen.tabs.essentials.max` (added 1.16.4b). A "drag here" promo card appears when there are none (1.18b).
- **Pinned tabs** belong to one Space. The pinned list can be collapsed by clicking the Space name (1.18b).
- **Glance auto-trigger:** in Essentials and pinned tabs, clicking a link to another site opens it in Glance automatically, with no modifier key. This keeps the pinned tab on its home site, like Arc's behavior.
- The option "Pinned tabs appear in single Space or all Spaces" (discussion #875) is closed.
- An option limits Ctrl+Tab cycling to Essentials only or regular tabs only.
- **UNVERIFIED:** whether pinned tabs "reset to their pinned URL" like Arc. I found no docs page covering this.
- Sources: https://docs.zen-browser.app/user-manual/glance ; releases 1.16.4b, 1.18b

### 2.3 Folders and Live Folders
- **Folders** arrived in 1.15b (2025-08-27). They are nestable (sub-folders), have icons, can be renamed, and are handled by a new drag-and-drop system (1.18b). There is a "Move to folder…" menu item.
- Discussion #3152 "Zen folders like in arc" had 412 upvotes, the third highest in Ideas.
- **Live Folders** (1.19b): folders that fill themselves from GitHub issues, GitHub PRs (with a filter for drafts) or RSS feeds, and refresh after the machine wakes.
- Sources: releases 1.15b, 1.19b; https://alternativeto.net/news/2025/8/zen-web-browser-finally-gets-folders-simplifying-tab-grouping-in-the-sidebar/

### 2.4 Split view
- Shows up to **4 tabs** at once.
- Three layouts, each with a shortcut:
  - Horizontal (Alt+Ctrl+H)
  - Vertical (Alt+Ctrl+V)
  - Grid (Alt+Ctrl+G)
  - Unsplit all: Alt+Ctrl+U
- **Ways to open a split:**
  - drag a tab onto the left or right side of another tab
  - use the link context menu
  - use the "Join tabs" menu item
  - press the split button in Glance
- Each pane gets an overlay with a drag handle (`:::`) to move it and a `‒` button to remove it from the split.
- Splits are saved and can be shared (1.22.1b).
- "Enhance Split View" (discussion #813) is still open with 138 upvotes.
- Source: https://docs.zen-browser.app/user-manual/split-view

### 2.5 Glance (link preview)
- Opens a link as an overlay card on top of the current tab.
- The default trigger is **Alt+click**. Ctrl+click or Shift+click can be chosen in Settings › Look and Feel › Glance.
- The card has three controls: close (clicking outside also closes it), expand to a full tab, and move into a split.
- Pref: `zen.glance.enabled`.
- Sources: https://docs.zen-browser.app/user-manual/glance ; https://docs.zen-browser.app/contribute/desktop/code-structure-and-prefs

### 2.6 Compact mode
- Hides the sidebar, the top toolbar, or both. They come back when the pointer touches the matching window edge.
- Keyboard shortcuts can keep the floating sidebar or toolbar visible.
- In 1.20-era releases on macOS and Windows, compact mode keeps tracking the mouse after it leaves the window. The notes say Linux is unchanged.
- `zen.view.borderless-fullscreen` stops compact mode from hiding borders in fullscreen.
- **Shortcut inconsistency (observed):**
  - The compact-mode docs say Ctrl+S.
  - The shortcuts docs say Alt+Ctrl+C.
  - The 1.15b notes say new profiles get Ctrl+S.
  - Next/previous Space has the same problem: the docs say Alt+Ctrl+Q/E, while the 1.15b notes say Ctrl+Alt+←/→.
  - Lesson: keep one registry of shortcuts and generate the docs from it.
- Sources: https://docs.zen-browser.app/user-manual/compact-mode ; https://docs.zen-browser.app/user-manual/shortcuts

### 2.7 Tab layout: vertical only (plus toolbar modes)
- The FAQ says Zen **will not support horizontal tabs**. Discussion #889 "Horizontal tabs" (253 upvotes) is closed. A maintainer replied "Please use any other browser then" and argued that pinned tabs, folders, Essentials and Spaces don't work in a horizontal strip.
- **Toolbar modes:**
  - "single toolbar", where the URL bar lives in the sidebar
  - "multiple/double toolbar"
  - "collapsed" (icon-only sidebar)
- The sidebar can sit on the right.
- Sources: https://docs.zen-browser.app/faq ; https://github.com/zen-browser/desktop/discussions/889 ; release notes

### 2.8 Sidebar web panels: removed
- Zen used to have Vivaldi-style web panels. They were **removed in 1.11b** to follow Mozilla's newer security guidelines against rendering web content inside browser-chrome UI.
- Users objected: see discussion #7314 "Grieving over web panel" and issue #7335.
- The sidebar now also holds media controls (several at once), a PiP collapse target, and a PDF-merge drop target.
- Sources: https://github.com/zen-browser/desktop/discussions/7314 ; https://github.com/zen-browser/desktop/issues/7335 ; the 1.11b explanation comes via web search summary, **release note itself not fetched (UNVERIFIED wording)**

### 2.9 Zen Mods (the mod store)
How they work, taken from the source and the store repo:
- **Store repo:** `zen-browser/theme-store`. Each mod lives in `themes/<uuid>/` with these files:
  - `chrome.css`
  - `theme.json` (holds id, name, description, homepage, author, version, tags, dates, and raw URLs for style, readme, image and preferences)
  - `preferences.json`
  - `readme.md`
  - `image.png`
- The catalog is `themes.json`.
- **Submitting a mod:**
  1. Open a GitHub issue from a template.
  2. A bot analyzes it and opens a PR.
  3. The team reviews the PR.
- **Submission rules:**
  - name under 25 characters and unique
  - description under 100 characters
  - PNG screenshot at 600×400
  - must be open source
- The team can remove any mod "at the dev team's discretion".
- **Runtime** (`src/zen/mods/ZenMods.mjs`, with native `nsZenModsBackend.cpp` and `ZenStyleSheetCache.cpp`):
  - It joins the `chrome.css` of every enabled mod into one generated file, `<profile>/chrome/zen-themes.css`, headed "DO NOT EDIT".
  - It loads that file through the stylesheet service.
- **Mod options:** each option is declared in `preferences.json` with `property`, `label`, `type` and `defaultValue`. Every option is a real Firefox pref. There are three types:
  - `checkbox` → a bool pref. The mod's CSS tests it with `@media (-moz-bool-pref: "x.y.z")`.
  - `string` → set as a CSS variable `--x-y-z` on the root element.
  - `dropdown` → set as an attribute on a hidden `<div id="<sanitized-mod-name>">`, so CSS can match on it.
- **Kill switch:** `zen.themes.disable-all`.
- **Local userChrome** is also supported:
  - create `<profile>/chrome/userChrome.css`
  - set `toolkit.legacyUserProfileCustomizations.stylesheets=true`
  - for live editing, also set `devtools.chrome.enabled` and `devtools.debugger.remote-enabled`, then use the Browser Toolbox Style Editor
- Mods only restyle the UI. **Boosts** are the per-website counterpart (below).
- Sources: https://docs.zen-browser.app/themes-store/themes-marketplace ; https://docs.zen-browser.app/themes-store/themes-marketplace-submission-guidelines ; https://docs.zen-browser.app/guides/live-editing ; https://github.com/zen-browser/theme-store ; https://github.com/zen-browser/desktop/tree/dev/src/zen/mods

### 2.10 Boosts (per-site customization, like Arc Boosts)
- Added in 1.20b. Features:
  - tint colors
  - change fonts and styles
  - "zap" elements off the page
  - automatic dark mode for any site
- Open it from the site-controls icon in the URL bar, or by typing `New Boost` in the URL bar.
- Size overrides were added, and fixed in later patches.
- Source: releases 1.20b and later

### 2.11 Keyboard shortcuts
- Can be changed in Settings › Keyboard Shortcuts. Click a field, press the keys, and press Esc to save. A green outline means it worked; a red outline means it conflicts with another shortcut.
- The docs admit that "not all features are available… especially alternative shortcuts derived from Firefox".
- Shortcuts for "Switch to Space 1–10" have no default binding, except on new macOS profiles, which get Ctrl+number (1.18b).
- Copy URL is Shift+Ctrl+C. Copy URL as Markdown is Alt+Shift+Ctrl+C.
- A **command bar** (a URL-bar command palette) came with 1.16b and gained tab and folder search in 1.22.3b. "Command Palette" (discussion #820, 203 upvotes) is closed.
- Source: https://docs.zen-browser.app/user-manual/shortcuts ; https://alternativeto.net/news/2025/9/zen-browser-1-16b-brings-enhanced-url-bar-command-bar-actions-and-updated-firefox-143-base

### 2.12 Tab unloading
- Tabs can be unloaded by hand: a single tab, a whole Space, or all Spaces except the current one.
- The automatic unloader changed in **1.12.9b**. The release note says it "now uses Firefox's default tab discarding feature, which is based on time and memory usage, instead of the previous time-only method".
- In practice users say tabs no longer unload after a fixed time. The Dosubot reply in discussion #9074 says unloading now happens only under memory pressure and that `zen.tab-unloader.timeout-minutes` no longer has any effect. **UNVERIFIED:** that reply came from a bot, not a maintainer.
- Issue #8822 "Tab auto unload not working with recent changes" (83 comments, closed) records the regression.
- A third-party "Zen Auto Tab Unloader" extension fills the gap.
- Sources: https://github.com/zen-browser/desktop/discussions/9074 ; https://addons.mozilla.org/en-US/firefox/addon/zen-auto-tab-unloader/

### 2.13 Window sync, session and device sync
- **Window Sync** arrived in 1.18b (2026-01-23): every open window mirrors the same tabs and Spaces. A "blank window" shortcut opens a temporary window outside the sync.
- That release also broke things. Issue #11994 "All tabs are gone (also pinned) when updating to 1.18b" drew 116 comments, and the META issue #7079 drew 180.
- Pushback followed. Discussion #12025 "Disable window/tab sync by default" had 155 upvotes, and poll #12090 asked "Are you for or against removing sync option?"
- **Cross-device sync of Spaces, folders and tabs** arrived in 1.22b through a Mozilla account. It answers the top-voted idea, #2400 (478 upvotes).
- Local profile backups work on Windows and Linux, and on macOS since 1.21.15b.
- Sources: https://docs.zen-browser.app/user-manual/window-sync ; releases 1.18b, 1.21.15b, 1.22b

### 2.14 Other
- URL bar that remembers what you typed
- Picture-in-Picture
- Translations (from Firefox)
- Tab renaming for any tab (1.18b)
- "Clear Tabs" button
- Firefox extensions (AMO) and uBlock Origin
- **DRM:** the FAQ says Widevine is missing, so Netflix, Spotify and similar services fail, and that a license is pending with Google. **UNVERIFIED:** whether this is still true in 1.22.x. The FAQ page was current when fetched, but I found no release note about it.
- Source: https://docs.zen-browser.app/faq ; https://docs.zen-browser.app/user-manual

---

## 3. How Zen tracks upstream Firefox (maintenance lesson)

- **Tooling:** `@zen-browser/surfer` (^1.14.9), Zen's fork of the gluon/surfer Firefox-fork build tool. `surfer.json` pins the Firefox version (156.0.1 now, candidate 157.0) along with branding and the update channels (release and twilight).
- **Workflow** (from `package.json` scripts):
  - `npm run init` runs `surfer download`, then `import`, then `bootstrap`. The full Firefox source is downloaded into `engine/`.
  - Zen's changes live in `src/`, which mirrors the Firefox tree (`browser/`, `toolkit/`, `dom/`, `gfx/`, `widget/`, `layout/` …).
  - `src/` holds **259 `.patch` files** against Firefox sources (observed via the git tree API). New Zen-only code lives in `src/zen/`.
  - `surfer import` applies the changes into `engine/`. `surfer export <path>` pulls an edit made in `engine/` back out into a patch.
  - Preferences are YAML files in `prefs/` (`zen`, `firefox`, `fastfox`, `privatefox`). A Rust tool (`tools/ffprefs`) compiles them.
  - Upstream bumps: `npm run sync` (`scripts/update_ff.py`), `sync:rc` for release candidates, `sync:l10n` for localization.
  - Build: `surfer build`, or `build:ui` for fast rebuilds that only touch the UI.
- **Build requirements:** ~30 GB of disk, plus Python 3, Node 21+, Rust and sccache.
- **`src/zen/` modules:**
  - boosts, compact-mode, downloads, drag-and-drop, folders, glance
  - kbs (keyboard shortcuts), library, live-folders, mods, sessionstore, share
  - space-routing, spaces, split-view, sync, tabs, urlbar, welcome, window-drag
- **Release pace (observed):**
  - 30 releases between 2026-04-09 and 2026-09-23 (1.19.8b → 1.22.3b), usually several patch releases a month.
  - Minor versions: 1.20b on 2026-05-24, 1.21b on 2026-06-11, 1.22b on 2026-09-05.
  - Upstream Firefox point releases are followed closely (release on Firefox 156.0.1, twilight on the 157 RC).
- **Maintenance burden:**
  - 259 patches must be rebased onto every Firefox release, about every 4 weeks.
  - Mozilla's own security rules forced features out: web panels were removed in 1.11b.
  - Upstream changes caused regressions, for example auto-unload after switching to Firefox's discarding.
- **Lessons for den** (WKWebView is a system framework, not a fork):
  - den has no patch-rebase treadmill, but it depends on Apple's API surface and the WebKit version that ships with macOS.
  - Zen's pattern still carries over: keep product code in one clearly separated tree (`src/zen/`), and keep engine-coupled glue small.
  - Keep prefs declarative (YAML → generated), and keep a UI-only fast build path.
- Sources: https://docs.zen-browser.app/contribute/desktop/building ; https://docs.zen-browser.app/contribute/desktop/code-structure-and-prefs ; https://github.com/zen-browser/desktop (`surfer.json`, `package.json`, `src/`)

---

## 4. Community and governance

- **License:** MPL-2.0. By contributing you agree your work falls under MPL-2.0. **UNVERIFIED:** whether there is a CLA; none was found.
- **Contributors:** 236 non-anonymous (API).
- **Maintainers:** a `CODEOWNERS` file exists. The branding vendor is "Zen OSS Team". **UNVERIFIED:** who the individual maintainers are and how decisions are made. Wikipedia credits only "Zen Browser Team", and I did not fetch a governance doc.
- **Contribution channels:**
  - bugs → GitHub Issues
  - feature requests → GitHub Discussions "Ideas" or r/zen_browser
  - translations → Crowdin (`crowdin.yml`; Crowdin is also a sponsor)
  - a Code of Conduct is in place
  - the `dev` branch is the integration branch
- **Triage:** Dosubot, an AI bot, answers many discussions. Its answers are not maintainer statements, as seen in #9074.
- **Tone:** maintainers hold firm on scope. The horizontal-tabs reply was "Please use any other browser then". Mods can be removed "at the dev team's discretion". A strong product vision, but it causes friction.
- **Funding:**
  - Patreon (monthly) and Ko-fi (one-off), from zen-browser.app/donate
  - GitHub Sponsors is linked from the repo
  - sponsors/partners listed: Blacksmith (CI), Crowdin, Tuta
  - **UNVERIFIED:** any income figures (none are published on the pages fetched)
- **Other repos:** `theme-store` (mods), plus docs and homepage repos.
- Sources: https://github.com/zen-browser/desktop ; https://zen-browser.app/donate ; https://zen-browser.app/ ; https://docs.zen-browser.app/contribute

---

## 5. Top complaints (observed from GitHub)

Most-commented issues, all time:

| Issue | Comments | State |
|---|---|---|
| #7079 [META] Window Sync & session restore | 180 | closed |
| #8932 [META] Performance, consumption and memory leaks | 160 | **open** |
| #37 Windows antivirus flags zen.exe | 153 | closed |
| #11994 All tabs (incl. pinned) gone after update to 1.18b | 116 | closed |
| #1629 macOS system shortcuts (Cmd+Q, Cmd+,) broken | 91 | closed |
| #8822 Tab auto-unload broken | 83 | closed |
| #504 Too much RAM | 82 | closed |
| #7000 Unwanted connections / default search engine | 80 | closed |
| #7212 Keeps logging out of accounts | 66 | **open** |
| #9229 Dark mode lost after update | 64 | closed |

Themes that recur:
1. Memory and performance leaks. Many release notes fix leaks in glance, split view, folders and mods.
2. Updates lose sessions or tabs.
3. Window-sync behavior was forced on users.
4. Regressions after updates, such as dark mode and web panels.
5. No DRM.
6. Vertical-only tabs.
7. Losing web panels.
8. macOS-specific bugs.

Recent open examples: #15542 memory use and hangs on Mac, #15569 find bar flickers on macOS, #15555 AirPods get claimed on page load.

**UNVERIFIED:** Reddit sentiment. I could not fetch r/zen_browser directly, and third-party summaries only mention YouTube performance and bugs when using Sidebery.

Source: GitHub search API (`sort=comments`), https://github.com/zen-browser/desktop/issues

## 6. Most-requested features (Discussions "Ideas", by upvotes)

| Upvotes | # | Idea | State |
|---|---|---|---|
| 478 | 2400 | Instant tab sync between computers | open (addressed in 1.22b) |
| 416 | 924 | Sync workspace tabs across windows | open (Window Sync in 1.18b) |
| 412 | 3152 | Folders like Arc | closed (shipped 1.15b) |
| 319 | 869 | Rename tabs | closed (1.18b) |
| 281 | 891 | Sidebery features / integration | open |
| 253 | 889 | Horizontal tabs | closed (rejected) |
| 231 | 2326 | Auto-close tabs after time | open |
| 216 | 2337 | **Per-workspace profiles like Arc** | open |
| 203 | 820 | Command palette | closed (command bar) |
| 170 | 800 | Native PWA support | open |
| 138 | 813 | Enhance split view | open |
| 87 | 8182 | Export/import workspace config | closed |
| 85 | 830 | Disable animations | open |
| 81 | 5002 | Tie domains to workspace (Air Traffic Control) | closed (Space Routing 1.21b) |
| 73 | 4629 | Android version | open (FAQ says no mobile) |
| 34 | 11016 | Arc Developer Mode | open |

"Closed" here is the GitHub discussion state. Shipped or rejected status is inferred from release notes and FAQ.

Source: GitHub GraphQL search `repo:zen-browser/desktop is:discussion sort:reactions-+1`

---

## 7. Where Zen beats Arc

- **Actively developed and open source.** Arc went into maintenance mode (security fixes only) in May 2025 after The Browser Company moved to Dia and was acquired by Atlassian, according to third-party comparisons. Zen ships several releases a month under MPL-2.0.
- **Customization depth:** Zen Mods (a community CSS store with typed options), userChrome.css with live editing, and about:config.
- **Firefox base:** full uBlock Origin (MV2), Firefox extensions, containers per Space (cookie isolation inside one profile), and Firefox Sync.
- **Cross-platform:** Windows, macOS and Linux (Flatpak, AppImage, tarball), on x86_64 and ARM64. Arc's Linux support **UNVERIFIED/none as far as I know**.
- **Features Arc lacks or never finished:**
  - Live Folders (GitHub and RSS)
  - 4-pane split with a grid layout
  - per-Space gradient themes with grain
  - sharing Spaces, folders and splits as links
  - Glance modifier choice
- Third-party reviews also say Zen runs cooler and lighter than Arc on MacBooks. **UNVERIFIED:** anecdotal, not measured.
- **Arc still leads (per the same sources):** polish, and per-workspace profiles (Zen's #2337 is still open).
- Sources: https://supasidebar.com/blog/zen-vs-arc ; https://efficient.app/compare/arc-browser-vs-zen ; https://dev.to/koshirok096/from-arc-to-zen-what-i-noticed-after-a-few-weeks-of-use-bite-size-article-3pcd ; https://en.wikipedia.org/wiki/Zen_Browser

---

## 8. Takeaways for den

1. **Must-have parity list:**
   - Spaces with a bound profile or data store (WKWebsiteDataStore per Space gives Arc-style per-Space profiles, which Zen users still want in #2337)
   - Essentials
   - per-Space pinned tabs
   - nested folders
   - Glance
   - split view up to 4 panes with H/V/grid layouts
   - compact mode
   - Space Routing
   - Boosts
   - command bar
   - rebindable shortcuts
2. **Avoid Zen's pain points:**
   - Session-loss regressions: make session storage transactional and back it up.
   - Silent behavior changes: window sync forced on everyone, the unloader switch. Put such changes behind opt-in flags.
   - Docs that drift from shortcut defaults.
   - Unbounded memory use: den should have its own time- and memory-based unloader that it controls.
3. **Mod system design to copy:** a declarative manifest plus typed prefs (checkbox, dropdown, string), mapped onto CSS through media queries, variables and attributes. Submission happens by issue, a bot opens the PR, and the store is a git repo. On WebKit, the UI is native Swift, so "mods" would have to target a themable token layer rather than raw chrome CSS. That is a design decision still to be made.
4. **Differentiators still open:** web panels (Zen removed them), PWAs, auto-closing stale tabs, horizontal tabs as an option, per-Space profiles.
