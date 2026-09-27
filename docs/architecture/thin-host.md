# Thin host: moving feature code out of DenHost

Status: design proposal. The audit is done (feature-specific host code is marked `thin-host:` in the source, see [Markers](#markers-and-the-updates-feature)); migration steps 0–9 (§6) have not started ([ROADMAP.md](../../ROADMAP.md), Thin host).

Baseline: `origin/main` at `4519b77`, read from a `git archive` snapshot. In-flight work that is not on main was read from its branches and worktrees and is listed separately in §2.3. Other agents are changing that work, so it may already differ.

den's rule is that everything is a plugin: hot-swappable, lazy, and cheap on resources. Two verified facts limit how far that rule can go:

1. On macOS, normal Swift/ObjC dylibs never unload. Only Embedded Swift plugins loaded by cordis-swift `PluginHost` fully unload.
2. Embedded Swift can't use AppKit, WebKit, Foundation, Keychain, FoundationModels, URLSession or AVFoundation.

The host therefore has to hold every platform capability, and it should hold nothing else. This document lists what is in the host today, sorts each piece into a category, names the generic primitive that replaces each feature-specific piece, and gives a migration order that proves parity and performance at every step.

Categories used throughout:

- **a: generic bridge.** Feature-agnostic. Keep it in the host.
- **b: feature-specific but platform-bound.** Replace it with a generic primitive. The feature's policy, strings and layout move to a plugin.
- **c: pure feature logic in the host.** Move it to a plugin, or out of the shipped binary.

---

## 1. Measurements behind this document

Every number here was measured this session. The command is listed next to each value. Anything this document does not list is **unmeasured**.

| Fact | Value | How |
|---|---|---|
| Host Swift sources on main | 44 files, 11,270 lines | `find Sources -name '*.swift' \| xargs wc -l` |
| Plugin + test Swift on main | 11,561 lines (Plugins + Tests) | same, over `Plugins Tests` |
| Types declared in the host | 151 class/struct/enum/protocol declarations | `grep` over `Sources` |
| Visual constants | 171 `static let` in `Core/Tokens.swift` | `grep -c` |
| UI node types on main | 33: 27 in `Renderer.registry`, plus the roots `commandBar`, `dialog`, `toast`, `library`, `sheet`, `hoverCard` | `Renderer.swift` L49-60, `UIService.swift` |
| Named overlay slots | 9: `overlay.commandBar`, `overlay.peek`, `dialog`, `toast`, `popover`, `overlay.library`, `overlay.briefing`, `overlay.connections`, `hoverCard` | `UIService.set` |
| Host services on main | 14: `window`, `webviews`, `content`, `ui`, `keys`, `storage`, `app`, `suggest`, `session`, `net`, `ai`, `schedule`, `config`, `plugins` | `DenRuntime.init`, `main.swift` |
| Tests | 53 in `DenHostTests`, 88 in `PluginTests` | `grep -E '@Test\|func test'` |
| Frameworks linked by the shipped binary | AppKit, WebKit, Foundation, **FoundationModels**, **Network**, **CryptoKit**, CFNetwork, CoreGraphics, QuartzCore, CoreServices, plus the Swift overlays | `otool -L build/den.app/Contents/MacOS/den` (a build from 2026-09-27 21:51; it may not be exactly `4519b77`) |
| Binary size | `den` 2,936,480 B; plugins 164,464 B (quit) to 432,128 B (tabs) | `ls -la build/den.app/Contents/{MacOS,PlugIns}` |

Two items in the table matter for §5:

- **FoundationModels and Network are loaded before `main` today.** Only `AIService` uses FoundationModels. Network is used by `MockServices` (`NWConnection`), which is a dev fixture compiled into the shipped app.

---

## 2. Inventory and classification

### 2.1 Host files on `origin/main`

One row per type, or per group of types that share a verdict. "→" names the replacement and the plugin that takes over the policy. §3 and §4 define the primitives.

#### Core, runtime, loading

| File (lines) | Type(s) | Cat | Notes → replacement |
|---|---|---|---|
| `Core/Host.swift` (82) | `HostService`, `ServiceHost`, `Value` helpers | **a** | The bus. |
| `Core/Logic.swift` (213) | `RGB`, `Theme`, `Appearance` | **a** | Window background math. |
| | `Chord` | **a** | Key parsing. |
| | `LinkRule`, `LinkPolicy` | **a** | Declarative, because `WKNavigationDelegate` decides synchronously. The model to copy. |
| | `SplitLayout` | **a** | Content-area pane frames. |
| `Core/ThemePickerMath.swift` (89) | `ThemePickerMath` | **c** | Pure pad↔color mapping → `theme` plugin (rewritten without CoreGraphics types). |
| `Core/Tokens.swift` (205) | `Tokens`, window/sidebar/card/traffic-light sections | **a** | These are the chrome the host draws itself. |
| | `commandBar*`, `library*`, `sheet*`, `mini*`, `themePicker*`, `dialog*`, `toast*`, `hoverCard*` sections | **b** | → plugin style sheets (`ui.styles`, §4.3). The `// spec §n` provenance comments move with them. |
| `Core/ValueJSON.swift` (53) | `ValueJSON` | **a** | |
| `DenRuntime.swift` (80) | `DenRuntime` | **a** | Wiring. It will shrink as services go generic. |
| `DenHome/ConfigService.swift` (206) | `ConfigService` get/themes/paths/errors, file watch | **a** | |
| | `apply()` (`[shortcuts]` → `keys.bind` running `commands.run`) and `applyKeywords()` (→ `commands.engines`) | **c** | The host knows the command bar's API. → `commandbar` plugin, on `config.changed`. |
| `DenHome/DenHome.swift` (105) | `DenHome` layout, `DenLog` | **a** | |
| | `defaultConfig` starter TOML (includes a "Swift Forums" keyword example) | **c** | → shipped as a resource that the owning plugin writes with `app.writeFile {ifMissing}`. |
| `DenHome/TOML.swift` (278) | `TOML` | **a** | Generic parser. Candidate for a native module (§5). |
| `Plugins/LivePlugins.swift` (474) | `LivePlugins`, `SourceCompiler`, `TreeWatcher` | **a** | |
| `Plugins/PluginLoader.swift` (94) | `PluginLoader` | **a** | |
| | `crashToast()` text; `main.swift` also posts it | **c** (small) | → event `plugins.crashed {ids}`. A `notices` plugin, or `quit`, owns the toast. |
| `Den/main.swift` (365) | `AppDelegate` launch, first frame, SIGTERM, snapshot | **a** | |
| | `applyScenario`, `sessionSummary` (walks `spaces`/`tabs`), `--appearance` loop over `spaces`, fallback theme colors | **c** | The host knows the tabs and spaces data model. → `tabs.summary` (the tabs plugin), a scenario runner in `DenDev` (§5), and the default theme in the `theme` plugin. |

#### Scenarios and dev fixtures (compiled into the shipped binary today)

| File (lines) | Cat | Notes → replacement |
|---|---|---|
| `Scenarios/HostScenarios.swift` (273): `briefingTree`, `archiveItems`, dialog texts, sample sidebar | **c** | Feature trees duplicated in the host. → `DenDev` module (§5), with fixture trees generated by the plugins' own code in `PluginTests`. |
| `Scenarios/PreviewScenarios.swift` (254) | **c** | Same. |
| `Scenarios/ConnectionScenarios.swift` (98) | **c** | Same. |
| `Scenarios/CommandBarScenarios.swift` (16) | **c** | Same. |
| `Scenarios/MockServices.swift` (255): fake Slack/GitHub on 127.0.0.1 | **c** | → `DenDev`. This also removes Network.framework from the launch path (§1). |
| `Window/Snapshotter.swift` (45) | **a** | Generic. Only used for `--snapshot`, so it can live in `DenDev` too. |

#### Services

| File (lines) | Type / part | Cat | Notes → replacement |
|---|---|---|---|
| `Services/WebViewsService.swift` (408) | `WebRecord`, lifecycle, KVO events, suspend, snapshot, eval, data stores, link policy | **a** | Gains the generic web primitives in §3.4. |
| `Services/ContentService.swift` (314) | `ContentService` panes, focus, detach | **a** | |
| | `PeekOverlayView` button column, tooltips ("Open as Tab", "Open in Split View"), geometry, animation | **b** | → a `ui.layer` over `content` holding a `webview` node plus plugin-built buttons (the `peek` plugin). |
| `Services/UIService.swift` (393) | `set` for `sidebar.*` regions, `setPages`/`showPage`, palette refresh | **a** | |
| | Hard-coded overlay slots, their stacking rules ("connections above briefing", "library below dialog"), per-slot layout | **b** | → one generic `ui.layer` API (§4.2). |
| `Services/WindowKeysApp.swift` (300) | `WindowService` theme/sidebar/title/get | **a** | |
| | `WindowService` `openMini`/`updateMini`/`closeMini`/`listMini` | **b** | → generic `window.open` (§3.2). |
| | `KeysService` | **a** | Merges into `menu` (§3.1). |
| | `MainMenu` (hard-coded About/Hide/Edit/Window items) | **b** | → `menu.set` with standard `role`s; the menu contents come from plugins. |
| | `AppService`, `BrowserDefaults` | **a** | |
| `Services/StorageService.swift` (74) | `StorageService` | **a** | |
| `Services/NetService.swift` (162) | `NetService`, `RedirectTaskGuard` | **a** | |
| `Services/SessionService.swift` (150) | `SessionService` | **a** | |
| `Services/Permissions.swift` (74) | `Permissions` | **a** | |
| `Services/ScheduleService.swift` (164) | `ScheduleService` | **a** | Renamed `time`. Adds `after {ms}` and `format` (§3.1). |
| `Services/SuggestService.swift` (134) | `SuggestService`: Google endpoint `client=firefox`, 50 ms debounce, 256-entry cache | **c** | → `commandbar` plugin: `net.fetch` with `net:google.com`, `time.after` for the debounce, cache in plugin memory. |
| `Services/AIService.swift` (249) | `FoundationModelsGenerator`, availability, queue | **a** | |
| | `brief`, `todos`, `summary/brief/todoInstructions` prompt text, map-reduce chunking policy | **c** | → `briefing` plugin. The host keeps `ai.respond`/`ai.generate {schema}` (§3.1). |

#### Toolkit (renderer and views)

| File (lines) | Type | Cat | Notes → replacement |
|---|---|---|---|
| `Toolkit/Renderer.swift` (212) | `NodeView`, `Renderer` (reuse by type+id), `StackNode`, `RowNode`, `SpacerNode`, `TextNode`, `ButtonNode` | **a** | The core of the generic renderer. |
| `Toolkit/Primitives.swift` (249) | `Palette`, `Themable`, `ImageCache`, `IconView`, `IconButton`, `makeLabel` | **a** | |
| `Toolkit/ContextMenu.swift` (60) | `ContextMenu` | **a** | |
| `Toolkit/Overlays.swift` (348) | `PanelView`, `Keycap`, `BackdropView`, `PillButton` | **a** | These become the `panel`, `keycap` and `button` nodes. |
| | `DialogView` (Arc quit-sheet layout, Return/Esc button logic) | **b** | → `panel` + nodes in a modal `ui.layer` with `keys: {return, escape}` (`quit`, `spaces`, `tabs` plugins). |
| | `ToastView` (top-right stack, auto-dismiss) | **b** | → `ui.layer {place: window topRight, stack: "toasts", ttlMs}`. |
| `Toolkit/Rows.swift` (735) | `HoverNode`, `InlineTitleEditor`, `RenameSupport`, `GridNode` | **a** | Behaviors: hover fill, click, drag, rename. |
| | `NavBarNode` (fixed back/forward/reload set) | **b** | → `stack` of `button`s (`tabs` plugin). |
| | `URLPillNode` ("Search or Enter URL…" default) | **b** | → `item {style: "urlPill"}` + `progress` (`tabs`/`commandbar`). |
| | `FavoriteTileNode` | **b** | → `item {layout: tile}` (`tabs`). |
| | `SpaceTitleNode`, `SpaceIconNode` | **b** | → `item` / `item {layout: tile}` with a `drop` target (`spaces`). |
| | `TabRowNode` (drift "/", audio, close, reset, mute hit-zones) | **b** | → `item` with `leading`/`trailing` accessories and per-accessory actions (`tabs`). |
| | `SplitRowNode` (segments, chip) | **b** | → `stack {axis: h, selection: {chip}}` of `item`s inside an `item` (`tabs`/`peek`). |
| | `FolderNode` | **b** | → `disclosure` (`tabs`). |
| | `DividerNode` ("Clear" action) | **b** | → `divider {trailing: [button]}` (`tabs`). |
| | `NewTabRowNode` ("New Tab" default) | **b** | → `item` (`tabs`). |
| `Toolkit/SidebarView.swift` (448) | `SlotView`, `SidebarPage`, `SidebarPager`, `SidebarView` | **a** | Window chrome regions plus a generic pager. |
| | `DragController`: hard-coded draggable node types, `dropOnContent`/`dropOnSpace` semantics | **b** | → generic `drag {kind, payload}` / `drop {accepts, zones}` behaviors (§4.4). |
| `Toolkit/CommandBarView.swift` (513) | `CommandBarView`, `Row`, `Field`, `Banner`, `CloseButton`, `Border`, `M` metrics, `Colors.selectionFill` | **b** | → `panel` + `field` + `scroll`/`stack` with a selection model + `item`s + a banner composed of nodes (`commandbar`). Arc metrics → the plugin's style sheet. |
| `Toolkit/Library.swift` (252) | `LibraryView` rows, search field, layout | **b** | → `panel` + `field` + `stack` with `filter` + `item`s (`tabs`). |
| | `section(for:)` day grouping (Today/Yesterday/weekday), `host()`, `time()`, "Archive"/"Clear Archive"/"Search the Archive"/"Nothing in the Archive yet" defaults, filter rule | **c** | → `tabs` plugin, using `time.format` and `Text.host` (already in `Plugins/Shared/Env.swift`). |
| `Toolkit/Sheet.swift` (162) | `SheetView` page/sheet styles | **b** | → `ui.layer {place: content}` + `panel` + `scroll` (`briefing`, `connections`). |
| `Toolkit/SheetNodes.swift` (544) | `SectionNode`, `BadgeView`, `ActionButtonNode`, `ButtonRowNode`, `makeWrappingLabel` | **a** | These become `group`-style `stack`, `badge`, `button`, `stack`. |
| | `HeadingNode`, `ParagraphNode` | **b** | → `text` with styles. |
| | `TodoRowNode`, `FeedRowNode`, `ConnectionRowNode`, `SettingRowNode`, `ToggleRowNode`, `ChoiceRowNode`, `SheetRowNode` | **b** | → `item` + `toggle {style: checkbox\|switch}` / `choice` / `button` accessories (`briefing`, `connections`). |
| `Toolkit/HoverCard.swift` (843) | `HoverIntent` (dwell/grace/warm state machine) | **a** | Generic pointer intent. Parameterize the timings per node. |
| | `HoverCardController`: `types` set `tabRow/favoriteTile/folder/splitRow`, sidebar-edge anchoring | **b** | → a `hoverIntent` behavior on any node + an anchored `ui.layer` (`previews`). |
| | `HoverCardView`, `CardBadgeView`, `SectionBlock`, `CardRow`, `CardButton`; status palette incl. `"merged"` (a GitHub term) | **b** | → `panel` + `stack` + `item` + `badge {tone}` + `image` + `button` (`previews`). Status tones become neutral names; `previews` maps "merged" onto one of them. |
| | `SnapshotView` | **a** | → the `image` node (aspect-fill, placeholder, version). |
| `Toolkit/ThemePicker.swift` (500) | `ThemePickerNode`: state, dot-grid pad, swatches, wavy slider, grain dial, haptics, strings | **b** | → `pad2d` + `slider {style: wave\|dial}` + `grid` of swatch `button`s + `button`s (`theme`). Pad↔color math and presets → `theme`. |

#### Window

| File (lines) | Type | Cat | Notes → replacement |
|---|---|---|---|
| `Window/DenWindowController.swift` (336) | `RootView`, `FlippedView`, `PassthroughView`, `DenWindowController`, `SidebarResizeHandle`, `EdgeHoverZone`, `SidebarContainerView` | **a** | Window chrome. |
| `Window/ThemeBackgroundView.swift` (195) | `ThemeBackgroundView`, `CardView` | **a** | |
| | `PaneControlsView` (close / "Separate Page from Split View") | **b** | → `content.setPaneAccessory {tree}` rendered on pane hover (`peek`). |
| `Window/MiniWindow.swift` (266) | `MiniWindowController`, `MiniBarView`, `OpenInButton` ("Open in"), `MiniWindows` placement | **b** | → `window.open {kind: panel, titlebar tree, webview}` (`peek`). |

#### Counts (origin/main, one row per type or type group above)

| Category | Rows | Main contents |
|---|---|---|
| **a** keep | 38 | bus, runtime, loaders, storage/net/session/permissions/time/app/keys, webviews/content core, renderer base, primitives, sidebar regions and pager, window chrome, hover intent, TOML/config reading, snapshotter |
| **b** make generic | 27 | the overlay-slot machinery plus 12 bespoke views (command bar, dialog, toast, library, sheet, hover card controller and view, theme picker, peek card, pane controls, Little Arc, mini-window methods), 11 rows of feature-named sidebar/sheet nodes (19 node classes), drag semantics, main menu, feature token sections |
| **c** move out | 13 | 5 scenario/mock files, suggest service, AI prompts and briefing logic, theme-picker math, library grouping and strings, config→commands wiring, starter config, crash toast text, `main.swift` session/scenario/appearance knowledge |

Counted with `awk`/`grep` over the tables above. By lines, **b** is most of the host: `HoverCard.swift` 843, `Rows.swift` 735, `SheetNodes.swift` 544, `CommandBarView.swift` 513, `ThemePicker.swift` 500 and `UIService.swift` 393 are mostly **b**. Whole-file **c** is 1,119 lines (Scenarios + Mock 896, `SuggestService` 134, `ThemePickerMath` 89), plus parts of mixed files. All line counts are from `wc -l`. How a mixed file splits between categories was judged by reading it, not measured.

### 2.2 Top offenders on main

1. **`HoverCard.swift` (843).** A whole bespoke card layout, a GitHub-flavored status palette, and a hard-coded list of which node types get previews.
2. **`Rows.swift` + `SheetNodes.swift` (1,279).** Fifteen feature-named row types (`tabRow`, `todoRow`, `connectionRow`, …) that are variations of one row.
3. **`CommandBarView.swift` (513).** Arc's metrics, selection-color math, the default-browser banner and the placeholder string, all in the host.
4. **`ThemePicker.swift` + `ThemePickerMath.swift` (589).** A single feature's widget, math and strings.
5. **`UIService.swift` (393).** Nine named slots and hand-written stacking rules. Every new feature adds a slot (in-flight branches add `overlay.passwords` and `overlay.extensions`).
6. **`Library.swift` (252).** Archive semantics: day grouping, English strings and filtering rules.
7. **`AIService.swift`.** Briefing prompts and a `brief` method in a platform service.
8. **Scenarios + `MockServices` (896).** Feature fixtures and a fake Slack/GitHub server compiled into the release binary. They also pull Network.framework into launch.

### 2.3 In-flight host code (not on main)

These were read from branches and worktrees by three parallel read-only passes. Line counts come from `wc -l` on `git show` or the worktree file. Every file in this table has since landed on main; the Appendix and Addendum below track them as landed.

| Where | File (lines) | Cat | What's feature policy in the host | → generic primitive / plugin |
|---|---|---|---|---|
| `c89bb62` mini player | `MediaService.swift` (313) | **b/c** | Eligibility (`minDuration=5`, ≥200×100, not muted), four triggers, 0.2 s debounce, dismissed set, open/release state machine, settings `autoMiniPlayer/corner/width` | `app.visibility` event, `content.detach/adopt`, `window.open {kind: panel}`, `webviews.media*` → `media` plugin |
| | `MiniPlayerPanel.swift` (536) | **b** | Control layout, key map (space, ←/→ 5 s, M, Esc), tooltips, "LIVE", playback rates, corner snap and margins | `window.open {aspectLock, snap: corners, margin, minWidth, maxFraction}` + overlay tree (`slider`, `button`, `text`, `showOn: hover`) → `media` plugin |
| | `PageScripts.swift` (161) | **b** | JS payloads: largest-video pick, dirty-form heuristic, isolation CSS, 250 ms tick | `webviews.addScript/removeScript`, `webviews.handle {name}` → `webviews.message`, `webviews.call {frame}` |
| | `ContentService`/`WebViewsService` diffs | **b** | Discard vetoes ("visible", "pip", "media", "capture", "form"), JPEG 0.5 / JPEG 0.6 snapshot policy | Plain `suspend {force}` plus `get` exposing `media/capture/inWindow`; snapshot `format/quality/width` as args → `tabs` plugin decides |
| `1b08c4b` dark mode | `PageStyleService.swift` (214) | **a/b** | Tone-detector JS and thresholds (`<0.18`), `www.`/parent-domain matching | `webviews.styles {rules}`, `webviews.setAppearance`, detector via `addScript` + `message` → `darkmode` plugin (already owns the CSS: the target pattern) |
| `b247ef9` | `Primitives.swift` favicon inversion | **b** | Glyph-detection thresholds applied to every favicon | `icon.darkTreatment: none\|invert\|invertGlyph` node field |
| `ad65e8b` prompts | `WebPrompts.swift` (185), `WebErrorPage.swift` (105) | **b/c** | All dialog copy ("This page says", "Sign in to"…), permission memory, error-code→message mapping, inline HTML/CSS/SVG | `webviews.request {kind: alert\|confirm\|prompt\|auth\|media\|file}` + `webviews.respond`; `webviews.loadFailed` + `webviews.loadHTML` → `prompts` plugin |
| worktree `a4332ee` passwords | `VaultService.swift` (455), `VaultKeychain.swift` (166) | **b/c** | Form-field regexes, username guess, 6-6-6 generator, 300 s unlock, 60 s clipboard clear, prompt text, custom suggestion view, `overlay.passwords` slot | `secrets.*` with host-held sinks, `auth.presence`, `crypto.randomBytes`, `webviews.addScript` + trusted-origin `message` + `webviews.fill` → `passwords` plugin |
| worktree `a0d1f05` extensions | `Extensions/*` (1,981 total; `ExtensionsService` 864, `ExtensionsUI` 509) | **b/c** | Store URLs, Chrome-version lookup, update schedule, site-access modes, permission wording (`ExtensionText`), prompt queue, toolbar menu UI, "Add to den" store button JS, `overlay.extensions` slot, `URLPillNode` reaching into `ExtensionsUI` | `webext.*` bridge (§3.1) + `urlPill`→`item.trailing` accessories + `webview` node in an anchored layer → `extensions` plugin |
| `617f100` settings | `SettingsWindow` (367), `SettingsControls` (397), `SettingsService` (162), `GeneralSettings` (90), `IconPicker` (213), `ThemeTokens` (180) | **b/c** | Window title and metrics, section registry and order, "General" section content, symbol/emoji lists, token derivation | `window.open {kind: window}` + `item`/`toggle`/`choice`/`field {mode: chord\|glyph}`/`slider`/`grid` → `settings` plugin; `ThemeTokens` math → `theme` plugin pushing `ui.palette` |
| worktree `a1b7c99` | `PageActions` (305), `FindBar` (105), `DenWebView` (157) | **b/c** | Per-site zoom steps, find JS and highlight colors, view-source page, Google fallback, context-menu titles | `webviews.zoom/print/inspect/source/find via eval`, `webviews.setContextMenu {items, when}` + `contextAction` → `pagetools` plugin |
| worktree `a1ee299` (landed) | `PageScripting` (inject/message/setMenu/setContentRules), `WebCapture` (snapshot rect/full/clipboard/folder), `SpeechService`, `TranslateService`, `ui.tokens`, `app.paths/chooseFolder`, `urlPill.buttons`, `TestMode` | **a** | None: reader, read aloud, translation batching, capture UX, Zap, text-fragment links, zoom steps and every string live in `Plugins/pagetools` (JS in its `resources/`). `Scenarios/PageToolsScenarios.swift` is **c** (marked) | Already the generic shape; `speech`/`translate` could merge into `lang.*`, and `setMenu` matches §3.4's `setContextMenu`. Zoom stayed with the host's page actions |
| worktree `a2b5873` | `MainMenu.swift` (302), `MenuActions.swift` (75) | **b/c** | The whole menu bar with titles and command bindings, help URLs, `.webarchive` naming | `menu.set {menus}` with `role`s, `menu.action`; `webviews.save {format}` → `menu` plugin |

The pattern is the same in every row: the platform call is a few lines, and the host code around it (strings, heuristics, timers, layout) is the feature. The new host files listed above add up to 6,469 lines (sum of their `wc -l`; the diffs to existing files are not counted). Most of that is **b/c**.

---

## 3. Generic host services (target: 16)

Rules for every service:

- No English strings. A string that reaches the screen is always an argument.
- No knowledge of another plugin's service. The host never calls `tabs`, `spaces` or `commands`.
- Policy (thresholds, timers, heuristics) is an argument or lives in a plugin.
- Security-sensitive values (passwords, cookies) have **host-held sinks**, so they never need to reach plugin memory when they don't have to. This is a declared-intent guard, not isolation: plugins are in-process native code (see `Permissions.swift`).
- Synchronous platform decisions are declarative rules (like `setLinkPolicy`). The host never blocks on a plugin round trip inside a delegate callback.

### 3.1 The list

| # | Service | Platform it wraps | Keeps from today | Adds / replaces |
|---|---|---|---|---|
| 1 | `ui` | AppKit renderer | `set` for sidebar regions, `setPages`, `showPage`, `get` | `layer`, `styles`, `palette` (§4); removes the 9 named overlay slots |
| 2 | `window` | NSWindow/NSPanel | `setTheme`, `setSidebar`, `toggleSidebar`, `setTitle`, `get` | `open {id, kind: window\|panel, frame\|corner, size, minSize, aspectLock?, snap?, level?, allSpaces?, nonActivating?, titlebar: {height, trafficLights: {x, y}}, background: theme\|material\|none, tree?, webview?, autosave?}`, `update`, `close`, `list`; events `window.moved/closed/key/focus`. Replaces `openMini*`, the mini player panel and the settings window |
| 3 | `content` | card/pane views | `show`, `focus`, `get` | `detach/adopt {id, into}`, `cover {id, image, until}`, `setPaneAccessory {tree}`; `peek` becomes a layer |
| 4 | `webviews` | WKWebView | lifecycle, nav, `snapshot`, `eval`, `setLinkPolicy`, `get` | See §3.4 |
| 5 | `menu` (absorbs `keys`) | NSMenu | `bind`/`unbind`/`list` | `set {menus: [{title, role?, items: [{id, title, key?, role?, enabled?, hidden?, items?}]}]}`, `update {id, patch}`; events `menu.action {id}`, `menu.willOpen {menu}` |
| 6 | `storage` | files | unchanged | – |
| 7 | `secrets` | Security, LocalAuthentication | – | `set {ns, account, attrs?, data, auth: presence\|none}`, `list {ns}` (no data), `delete`, `use {ns, account, reason, sink: {fill: {webview, frame, fields}} \| {pasteboard: {concealed, clearAfterMs}}}` → `secrets.result`; `presence {reason}` → `secrets.presence`; `random {bytes}` |
| 8 | `net` | URLSession | `fetch`, `cancel` | `download {url, to}` for extension packages. Absorbs `suggest` (removed) |
| 9 | `session` | WKWebsiteDataStore | unchanged | – |
| 10 | `ai` | FoundationModels | `availability` | `respond {instructions, prompt}`, `generate {instructions, prompt, schema}` (guided generation from a runtime schema; that FoundationModels' dynamic schema API covers the current `@Generable` todo is **unverified**), `contextSize`. `summarize/brief/todos` move to `briefing` |
| 11 | `time` (was `schedule`) | Dispatch, NSWorkspace wake, DateFormatter | `daily`, `interval`, `cancel`, `list`, `clock` | `after {id, ms}` (one-shot, for debounces), `format {ms, style: day\|weekday\|time\|monthDay\|relativeDay, locale?}` |
| 12 | `app` | NSApplication, NSWorkspace, NSPasteboard | quit/close interception, `pendingURLs`, default browser, `info`, `copy` | `visibility` event, `open {url\|path}`, `reveal {path}`, `writeFile {path, data, ifMissing}` (den home only), `openPanel/savePanel {…}` → result event |
| 13 | `config` | den home files, FSEvents | `get`, `themes`, `paths`, `errors` | Drops the `[shortcuts]`/`[search.keywords]` application (moves to `commandbar`) |
| 14 | `plugins` | cordis `PluginHost` | `get`, `listening` | events `plugins.available {service}` (stops the 500 ms × 60 `commands.register` retry loops), `plugins.crashed {ids}` |
| 15 | `media` | WebKit media SPI, MediaPlayer | – | `webviews`-scoped: `state {id}`, `control {id, cmd: play\|pause\|seek\|rate\|volume\|pip}`, `setMuted {id}`; Now Playing / media keys → `media.remote {cmd}` event |
| 16 | `webext` | WKWebExtensionController | – | `install {path}` → `webext.staged {…permissions, patterns, unsupported}` → `commit {grants}` / `discard`; `list`, `get`, `uninstall`, `setEnabled`, `setGrants`, `action {id, anchor}`, `actionState`, `openOptions`; events `webext.permissionRequest` (answered with `respond`), `webext.actionChanged`, `webext.popup {id, webview}` (the popup is a web view the plugin places in a layer) |

`lang` (AVSpeechSynthesizer + the Translation framework: `speak`, `stop`, `voices`, `translate`, `languages`) is a 17th, optional service. It could live inside `ai` if the service count matters more than framework isolation. §5 gives it its own module because its frameworks are large and rarely used.

### 3.2 `window.open`: one primitive for Little Arc, mini player and settings

- **Little Arc.** `{kind: panel, corner: topRight, margin: 20, size: [1185, 832], titlebar: {height: 47, tree: <URL field + "Open in Space ⌘O">}, webview}`. The bar tree and every string come from `peek`. The ⌘O binding already lives in the plugin.
- **Mini player.** `{kind: panel, level: floating, allSpaces, nonActivating, aspectLock, snap: corners, margin: 16, minWidth: 256, webview, tree: <controls with showOn: hover>}`. Eligibility, keys and rates live in the `media` plugin.
- **Settings.** `{kind: window, title, size: [740, 540], autosave: "den.settings", tree: <split: list | scroll of groups>}`. Sections are a `settings` plugin service that other plugins register with.

### 3.3 Services removed or shrunk

- `suggest`: removed. It becomes `commandbar` code on top of `net` + `time`.
- `keys`: merged into `menu`.
- `vault`, `pagestyle`, `settings`: landed as host services after this survey. Their platform parts are the rows above; their feature parts are marked `thin-host:` to migrate. Extensions landed as `webext`, page actions inside `webviews`, and page tools as `speech`/`translate` plus generic `webviews` scripting (Addendum).

### 3.4 `webviews` additions (all generic)

- **Scripts:** `addScript {name, js, world, allFrames, at: start|end, hosts?}`, `removeScript`, `handle {name, world}` → `webviews.message {id, name, frame, origin (host-derived, trusted), body}`, `call {id, world, js, args, frame: main|best|<token>}`.
- **Styles:** `styles {rules: {default, hosts}}`, `setAppearance {id|*, light|dark|null}`, `setContentRules {name, json}`.
- **Requests** (JS dialogs, HTTP auth, camera/mic, file input): event `webviews.request {request, id, kind, origin, …}`, answered by `respond {request, answer, text?, user?, password?}`. If no plugin listens (`plugins.listening`), the host falls back to cancel or deny.
- **Errors:** event `webviews.loadFailed {id, url, domain, code}` (the host still hides cancelled loads), `loadHTML {id, html, url}`.
- **Page actions:** `setContextMenu {id|*, items: [{id, title, when: link|image|selection|page, replaces?}]}` → `contextAction`; `zoom`, `print`, `inspect`, `source`, `save {format: webarchive|pdf}`, `capture {rect?, fullPage?}`, `download {url, saveAs}`.
- **Password fill:** `fill {id, frame, fields: [{ref, value: "$secret" | literal}]}`, only through the `secrets.use` sink when a secret is involved.
- `suspend {force}` loses its veto list. `get` reports `media`, `capture`, `inWindow` and `dirtyForm` so the `tabs` plugin decides.

---

## 4. Generic UI: 22 node types, one layer API, one style registry

### 4.1 Node vocabulary

Everything below is native AppKit: layer-backed flipped `NSView`s with manual layout, reused by `type`+`id`, as `Renderer.reconcile` does today.

| Group | Node | Fields (beyond `id`, `style`, `menu`, `tooltip`, behaviors §4.4) | Actions |
|---|---|---|---|
| Layout | `stack` | `axis: v\|h`, `spacing`, `padding`, `align`, `selection?`, `filter?` | `select` |
| | `grid` | `columns\|cellSize`, `spacing` | – |
| | `scroll` | `axis`, `scrollTo?`, `keepPosition` | – |
| | `pager` | `pages`, `current` (swipe, progress callbacks) | `page` |
| | `spacer` | `width?`, `height?`, `flex?` | – |
| | `divider` | `trailing?: [node]` | – |
| Surface | `panel` | `radius`, `fill: token\|hex`, `border: [{color, width, inset}]`, `shadow`, `material?`, `grain?` | – |
| Display | `text` | `text`, `lines`, `truncate`, `selectable`, `font: {size, weight, design}` or style | – |
| | `icon` | `spec` (`sf:`/url/`app:icon`/emoji/path), `size`, `tint`, `fallbackLetter`, `darkTreatment` | – |
| | `image` | `src`, `aspect`, `fit`, `placeholder`, `version` | – |
| | `badge` | `text`, `tone: neutral\|accent\|success\|warning\|danger\|info\|special`, `icon?` | – |
| | `keycap` | `text` | – |
| | `progress` | `kind: bar\|spinner\|skeleton`, `value?`, `lines?` | – |
| Controls | `button` | `title?`, `icon?`, `variant: icon\|pill\|link`, `tone: default\|primary\|destructive\|secondary`, `keycap?`, `enabled` | `click` |
| | `field` | `mode: text\|search\|secure\|chord\|glyph`, `value`, `placeholder`, `autofocus`, `caretColor?`, `replace?` | `change`, `submit {mods}`, `cancel`, `tab`, `move {±1}` |
| | `toggle` | `style: switch\|checkbox`, `on` | `change {on}` |
| | `choice` | `style: popup\|segmented`, `options`, `selected` | `change {option}` |
| | `slider` | `style: linear\|wave\|dial`, `min`, `max`, `step`, `value`, `detents?` (haptics) | `change {value, final}` |
| | `pad2d` | `points: [[x, y]]`, `primary`, `grid: {pitch, image?}`, `snap`, `addOnEmptyClick` | `change {points, final}`, `add {point}` |
| Composite | `item` | `layout: row\|tile`, `leading: [node]`, `title`, `subtitle?`, `trailing: [node]`, `trailingOnHover: [node]`, `selected`, `dimmed`, `indent`, `height`, `editing?`/`editText?`, `segments?` | `click {mods, part}`, `doubleClick`, `middleClick`, `rename`, `renameCancel` |
| | `disclosure` | `header: item`, `open`, `children` | `toggle` |
| Embed | `webview` | `webview` id, `radius`, `autosize?: {min, max}` | – |

`part` in `item.click` names the accessory that was hit (`leading.0`, `trailing.close`). It replaces the hard-coded favicon-reset and mute hit zones in `TabRowNode.clicked`.

How today's screens compose from these nodes (all Arc-exact metrics move to plugin styles):

- **Command bar.** `layer(center, modal, dim)` › `panel(border: 2 strokes)` › `stack` [`icon` + `field(mode: search, caretColor)`, `divider`, `stack(selection: {selected, keyboard: field, hoverSelects: true})` of `text` headers + `item`s with a `keycap` trailing, banner `stack`].
- **Hover card.** `layer(anchor: <row id>, edge: sidebarRight, gap: 8)` › `panel` › `stack` [`item` header, `stack` of `badge`s (wrap), `image`, `stack` of `item`s, `stack` of `button`s, `text` footer].
- **Theme picker.** `layer(anchor, edge: sidebarRight)` › `panel` › `stack` [`choice(segmented, icons)`, `pad2d`, `stack` [`button −`, `button +`], `grid` of swatch `button`s + chevrons, `slider(wave)`, `slider(dial)`].
- **Library / Briefing / Connections.** `layer(content)` › `panel` › `stack` [header `item`, `field(search)`, `scroll` › `stack(filter: {field, keys: [title, url]})` of `text` section headers + `item`s].
- **Dialogs.** `layer(center, modal, dim 0.55, keys: {return: <id>, escape: <id>})` › `panel(radius 26.5)` › `stack` [`icon`, `text`, `stack(h)` of `button`s with keycaps].

### 4.2 `ui.layer`: replaces every named overlay slot

```
ui.layer {id, tree | null,
  place: {in: window|content|sidebar|pane:<id>|window:<id>,
          anchor?: <node id>, edge?: center|top|topRight|sidebarRight|below|…,
          offset?, gap?, size?|maxSize?, clamp: 10},
  modal?: {dim: alpha, dismissOn: [escape, outside], trapFocus: true},
  keys?: {return: <node id>, escape: <node id>},
  z?: number, group?: "toasts" (stacks with its siblings), ttlMs?,
  transition?: {in: fade|scale|slide, out, ms, curve}, focus?: <node id>}
```

Events: `ui.action {id: <layer id>, action: dismiss, value: {reason}}`. Rules the host still owns, because they are generic: opening a modal layer hides any hover layer. `z` sets the order, which replaces "connections above briefing" and "library below dialog". Reduce Motion turns transitions off.

### 4.3 Styles and palette (Arc-exact without host views)

- `ui.styles {styles: {"commandbar.row": {height: 50, radius: 8, padding: [0, 16], font: {size: 13.5}, fill: "selection", …}}}` is sent once per plugin load and merged by name under the plugin's prefix. Nodes reference `style: "commandbar.row"`. Keeping the metrics out of every `ui.set` keeps payloads small. The `// spec §2` comments move into the plugin next to the numbers.
- `ui.palette {tokens}`: the `theme` plugin pushes palette tokens (`text`, `secondaryText`, `accent`, `popover`, `selection`, …) computed from the space theme. Contrast and luminance math is pure and fits in Embedded Swift. The host keeps a default palette for the first frame and uses it until a push arrives. Colors in styles are token names or hex.

### 4.4 Behaviors: native, attachable to any node

These are the reason the renderer stays fast. They run entirely in AppKit, and a plugin hears only the discrete outcome.

- `hover` fill with `hoverFill` / `selectedFill` tokens.
- `hoverIntent: {delayMs, graceMs, warmMs}` → `hover` / `hoverEnd` (the existing `HoverIntent`, parameterized; no timers until a dwell starts).
- `drag: {kind, payload}` and `drop: {accepts: [kind], zones: row|before-after-into|halves}` → `drop {source, target, position|side}`, with haptics and a theme-tinted indicator. This replaces `DragController`'s node-type list and the named `dropOnContent`/`dropOnSpace`. The content area and pane edges are drop targets declared with `content.setDropZones`.
- `reorderable: true` on a `stack`/`grid` → `move {from, to}`. Replaces `SpaceIconReorder` in flight.
- `selection` on a container: keyboard ↑/↓ from a linked `field`, hover-selects after real mouse movement, local selected-state repaint → `select {row}`.
- `filter` on a container: `{field, keys}` does local substring filtering on each keystroke, so search stays instant without a plugin round trip, then emits the query. It is optional; a plugin can filter itself.
- `menu` (existing), `editing` (existing inline rename).

### 4.5 Performance rules for the renderer

- Reuse by `type`+`id` (existing). Rows reuse by position when ids are stable (as `CommandBarView` does now).
- Skip unchanged subtrees. Today this is `v.node != c`, a deep `Value` equality. Add an optional `rev` field so a subtree can be skipped in O(1). The cost of the deep comparison on large trees is **unmeasured**; measure a 500-row sidebar before deciding whether `rev` is needed.
- No Auto Layout and no SwiftUI. Layers stay layer-backed, and text is measured once per content change.
- No per-frame plugin calls. Drags, hover, scroll, pager swipes and slider/pad tracking are handled in the host. Plugins get discrete events (a detent, a drop, `final`). The theme picker's live `change` is the one exception; it stays as it is today, and its cost is to be measured (§6).
- Styles are resolved once per (style, palette) and cached in the host.

---

## 5. Separately loadable native modules

These are full-Swift dylibs `dlopen`ed by the core at launch, or lazily on first use, and never unloaded. Replacing one means an OTA download plus a relaunch. The relaunch time of about 1 s is the user's figure and has not been measured here; measure it with `scripts/dev-sync.sh`'s relaunch path.

### 5.1 ABI constraint (why this is not free)

Modules and core must share one copy of `CordisValue.Value`, `HostService` and the renderer base classes. Two options:

- **A (recommended first).** A `DenKit.dylib` holding those types, built with library evolution. The core and each module link it. A module carries the `DenKit` ABI version it was built against, and the core refuses a mismatch and falls back to the bundled module.
- **B.** Core and all modules are built and replaced as one set. Each module can still be swapped, but only within the same build ID.

A module that crashes at load uses the same crash-marker approach cordis uses for plugins: refuse that build on the next launch and load the bundled one.

### 5.2 What goes where

| Module | Contents | Loaded | Why it can / can't be a module |
|---|---|---|---|
| **core executable** | `main`, `AppDelegate`, module loader + crash rollback, cordis `PluginHost` + `PluginLoader` + `LivePlugins` loop, `ServiceHost`, `storage`, `app`, `menu`, `plugins`, window shell (`DenWindowController`, `ThemeBackgroundView`, `CardView`, sidebar container) | always | Must boot, show a window and recover when a module is bad. `storage` is read by plugins before the first frame. The main menu must exist in `applicationWillFinishLaunching`. |
| `DenUI` | renderer, 22 nodes, layers, styles, behaviors | launch, before first frame | Can be a module: it is Swift + AppKit, and the core calls it through a narrow protocol. It sits on the first-frame path, so it adds one `dlopen` there (cost **unmeasured**). The benefit is renderer fixes by OTA. Keep it in core until measured. |
| `DenWeb` | `webviews`, `content`, `session`, link policy, scripts/styles/requests | launch, before first frame | On the first-frame path, because the selected tab is created right after the first frame. It owns the process-lifetime `WKWebsiteDataStore`s. |
| `DenWebExt` | `webext` | launch **only if** extensions are installed | A `WKWebExtensionController` must be attached to a configuration before a web view exists (in-flight code comment). So it loads before `DenWeb` creates any view, but only when needed. Whether a controller can be replaced at runtime is **unverified**. |
| `DenNet` | `net`, `ValueJSON` | after first frame | URLSession only. |
| `DenAI` | `ai` | lazily, on the first `ai.*` call | Removes FoundationModels from the pre-`main` framework list (§1). |
| `DenSecrets` | `secrets` | lazily | Security + LocalAuthentication. |
| `DenMedia` | `media`, the media-panel window kind | lazily | MediaPlayer, AVKit. |
| `DenLang` | `lang` | lazily | AVFoundation speech, Translation. |
| `DenHome` | `config`, `TOML`, `SourceCompiler`, `TreeWatcher` | after first window (as `startDenHome` does now) | `Process`, FSEvents. |
| `DenDev` | Scenarios, `MockServices`, `Snapshotter` | only with `--scenario`/`--snapshot`/tests | Removes Network.framework and 896 lines of fixtures from release launch. It can be left out of release OTA entirely. |

Lazy loading needs a small **service stub** in the core. `plugins.provide("ai")` registers a stub that `dlopen`s `DenAI` on the first call and then forwards. This keeps `plugins.get().services` truthful, so plugins can hide features whose provider is missing.

### 5.3 Launch-time impact (reasoned; every number here is to be measured)

- **Likely win.** Frameworks that only lazy modules link (FoundationModels, Network via `DenDev`, LocalAuthentication, MediaPlayer, Speech, Translation) are no longer mapped and bound before `main`. The size of that saving is **unmeasured**. Measure `--measure-launch` (`launch.firstWindowMs`), median of 20 cold and warm runs, before and after, plus Instruments' App Launch template for the dyld phase.
- **Likely cost.** Every module loaded before the first frame (`DenUI`, `DenWeb`, `DenWebExt` when present) adds a `dlopen`: mapping, fixups, and Swift/ObjC metadata registration. Measure each with an `os_signpost` around `dlopen` (the host already has a `launch` signposter in `main.swift`).
- **Decision rule.** A module stays out of core only if its pre-first-frame cost is at or below the measurement noise (**to be measured**), or if it loads after the first frame.
- **Memory.** Lazy modules never loaded cost nothing. Check with `scripts/measure-memory.sh main` and `load10`.

---

## 6. Migration plan

Every step can be merged and verified on its own and leaves the app shippable. "Parity" means the named snapshot scenarios are pixel-identical (light and dark) to the step-0 goldens, and the named tests pass. "Perf" is the check that must not regress beyond noise (the noise band itself is measured in step 0).

| # | Step | Risk | Parity proof | Perf check |
|---|---|---|---|---|
| 0 | **Baseline.** Record goldens from `scripts/snapshots.sh` (all scenarios); run `swift test` (141 tests); measure `--measure-launch` ×20, `measure-memory.sh main\|load10\|load10discard`; add `os_signpost` around `ui.set`/`ui.layer` (tree size, ms) and `HoverCardController.lastShownMs`. Add a pixel-diff script. | none | – | Establishes the noise bands. |
| 1 | **Guardrails.** A `DenHostTests` check that fails on new English string literals in `Sources/DenHost` outside `Scenarios`, on new `overlay.*` slot names, and on host calls to plugin services (`"tabs"`, `"spaces"`, `"commands"`). An allowlist holds today's violations, and each later step shrinks it. | low | Test passes with the allowlist. | – |
| 2 | **Move c-logic that has no UI.** `SuggestService` → `commandbar` (on `net`+`time.after`); `ConfigService.apply*` → `commandbar`; AI prompts/`brief`/`todos` → `briefing` (on `ai.respond/generate`); `ThemePickerMath` → `theme`; `sessionSummary` → `tabs.summary`; crash toast → `plugins.crashed`. Add `time.after`, `time.format`, `ai.respond`, `ai.generate`, `plugins.available`. | low–med | `SuggestServiceTests` ported to `PluginTests`; `AIScheduleTests`, `DenHomeTests`, `CommandBarTests`, `ThemeTests`, `ConnectionsTests` pass; `briefing*`, `command*`, `themeLive` snapshots equal. | Command bar keystroke→suggestions latency (new signpost); briefing end-to-end time from `ai.result.ms`. |
| 3 | **`DenDev` split.** Move Scenarios, `MockServices` and `Snapshotter` into a target the app links only in dev builds (a dylib later). | low | All `--scenario` snapshots equal in the dev build; release has no `MockServices` symbols (`nm`). | `--measure-launch`; `otool -L` shows Network gone from release. |
| 4 | **`ui.layer` + `ui.styles` + `ui.palette`**, alongside the old slots. Re-implement the 9 slots as adapters over layers inside the host. No plugin changes. | med | `dialog*`, `library*`, `briefing*`, `connections*`, `command*`, `themePicker*`, `preview*`, `peekCard`, `toast` snapshots equal; `ComponentTests`, `HoverCardTests` pass. | `ui.set` signpost; `lastShownMs`. |
| 5 | **New nodes + behaviors** (§4.1, §4.4), with a golden test per old node: a plugin-style composed tree must render pixel-identical to the old node at the same width, light and dark. | med | New per-node golden tests; all old snapshots unchanged, because nothing uses the new nodes yet. | Render 500 `item`s vs 500 `tabRow`s (signpost); must be ≤ baseline + noise. |
| 6 | **Migrate screens, one PR each**, lowest risk first: toast → dialogs → library (grouping moves to `tabs`) → briefing/connections → hover card → theme picker → sidebar rows (`tabRow`, `folder`, `splitRow`, favorites, spaces) → command bar → peek chrome and pane controls → Little Arc (`window.open`). Each PR deletes the old host view and its tokens. | med–high (sidebar and command bar) | That screen's snapshots equal; its plugin tests (`TabsTests`, `PeekTests`, `PreviewsTests`, `CommandBarTests`, `SpacesTests`, `QuitTests`) pass; plugin hot-swap of that plugin still works (`--dev-plugins` rebuild while the screen is open). | Per screen: sidebar 100-tab re-render ms; command bar keystroke→frame; hover card `lastShownMs`; theme-picker drag (`change` events/s and main-thread ms per event); memory `load10`. |
| 7 | **Remove the old slots and nodes.** Keep a one-release `ui.set {slot: overlay.*}` shim only if third-party plugins exist (none are known). Remove the allowlist entries. | low | Guardrail test with an empty allowlist. | – |
| 8 | **Land in-flight features thin.** Rebase each branch onto the primitives: mini player → `window.open` + `media`; dark mode → `webviews.styles` (already mostly plugin-owned); prompts → `webviews.request`; passwords → `secrets` + `passwords`; extensions → `webext` + `extensions`; settings → `window.open` + `settings`; menus → `menu.set`; page tools → `webviews.*` + `lang`. | med–high (secrets, webext) | Each branch's own scenarios and tests. For secrets, add a test that no password string crosses `ui.action`/`webviews.message` into plugin memory when the fill sink is used. | Mini player open latency; `measure-memory` with 1 panel. |
| 9 | **Native modules** in this order: `DenDev` → `DenAI` (lazy stub) → `DenHome` → `DenSecrets`/`DenMedia`/`DenLang` → `DenNet` → `DenWebExt` → (only if measured cheap) `DenUI`, `DenWeb`. One PR per module, with the ABI check and crash rollback in the first. | med | Full `swift test`; all snapshots; a scripted relaunch that swaps a module and confirms the version via `app.info`. | `--measure-launch` ×20 per module; App Launch dyld phase; `measure-memory`. |

**Rollback.** Every step is a separate commit or PR. Steps 4–6 keep the old path until the new one matches the goldens, so a revert never loses a screen.

---

## 7. What cannot be a live-swappable plugin, and why

These points follow from facts verified earlier or read in the code:

1. **Anything that uses AppKit, WebKit, Foundation, Security/Keychain, LocalAuthentication, FoundationModels, URLSession or AVFoundation.** Embedded Swift can't import them, so an Embedded Swift plugin can't contain these calls. That covers every `NSView` subclass (all 22 node types, panels, windows), every `WKWebView` and delegate, Keychain items, Touch ID prompts, network I/O, on-device models, speech and media.
2. **The host bridges themselves can't be hot-swapped, only relaunch-swapped.** Normal Swift/ObjC dylibs never unload on macOS: ObjC classes and Swift metadata and conformances stay registered, so `dlclose` doesn't release the image. A native module (§5) is therefore replaced by relaunching, never live. This is why the host must be small and stable: a host change costs a relaunch, while a plugin change is a live swap.
3. **Synchronous platform decisions.** `WKNavigationDelegate` policy, key equivalents, hit testing, drag tracking and layout run synchronously on the main thread. A plugin can't be consulted per event without blocking, and for per-frame work it isn't allowed to be. So these stay as declarative rules (link policy, drop zones, `keys` on a layer) and native behaviors (§4.4). The plugin supplies the rules; it can't be the callback.
4. **Process-lifetime platform objects.** These objects live for the whole process and are held by the host no matter which plugin is loaded:
   - The `NSApplication` delegate.
   - Main-menu roles.
   - `WKWebsiteDataStore`s and their identifiers.
   - The web extension controller. It must be attached before any web view exists; whether it can be replaced at runtime is unverified.
   - Pending WebKit completion handlers for dialogs and auth. They can't outlive or cross a plugin unload.
5. **Security boundaries.**
   - Plugins are native code in den's process, so `permissions.json` is declared intent, not a sandbox (`Permissions.swift`).
   - Secrets therefore get host-held sinks (fill, pasteboard) so they don't pass through plugin memory unnecessarily.
   - The host derives trusted page origins itself (`WKFrameInfo.securityOrigin`) and never accepts them from a plugin.
   - Keychain access and TCC grants are tied to the host's stable signing identity and bundle ID (`scripts/bundle.sh`), not to a plugin.
6. **Crash recovery.** The plugin loader, the crash marker, and whatever shows the "plugin X crashed" state must survive any plugin being broken, so they live in the core executable. This also applies to module rollback (§5.1).
7. **The first frame.** The window shell, a default palette and enough of the renderer to draw the sidebar must exist before any plugin has applied. Plugins fill the regions afterwards.

Everything else is feature policy and belongs in a plugin, whatever its current location. That includes every string, threshold, timer duration, heuristic, prompt, URL, menu item, layout composition and Arc measurement.

---

## Markers and the updates feature

Feature-specific host code is marked with one line, so `git grep "thin-host:"` lists what's left to migrate:

```swift
// thin-host: feature-specific, migrate to plugin
```

Marked so far: `ConfigService.apply()` (shortcuts and keywords), `LivePlugins.toast` (load and build failure strings), and `main.swift` `sessionSummary()`, `CommandBarView` (row, banner and framing; the launcher's index, ranking, aliases, settings and strings are already in the `commandbar` plugin) and `LauncherSettingsStub` in `CommandBarScenarios.swift` (a snapshot-only settings registry). Also marked: the extensions code (Appendix), the Addendum's **marked** rows, the mini player (`MediaService`, `MiniPlayerPanel`, the isolation CSS in `PageScripts`), passwords (`VaultService`, the `overlay.passwords` slot in `UIService`, the suggestion-view case in `CardView.layout`), dark mode's page-tone heuristic (`PageStyleService`), and the dev scenarios `PageToolsScenarios`, `VaultScenarios` and the password pages in `MockServices`. `git grep "thin-host:"` is the complete list. The launcher added only generic blocks to the host: row `shortcut` keycaps and a `toggle` switch, the bar's `right`/`back` actions, `window.focusMini`, `app.showAbout` and `payload` in `keys.list`.

Updates ([updates.md](../updates.md)) follow the rule from the start:

- **The `updates` plugin** holds the policy and UI: channel, schedule, what to install, rollbacks, when to relaunch, every string (toast, About text) and the Check for Updates… command.
- **The host `updates` service** does only native work: ETag fetch, sha256 + EdDSA verification, atomic file placement, the Sparkle bridge, `launchctl`.
- **Generic blocks** that any plugin can use: `app.state`, `app.relaunch`, `app.setAbout` and a toast action button.

---

## Appendix: extensions as landed

The host service landed as `webext` (the name in §3) and the page as the `extensions` plugin, which provides `extensions.open`. Host code the rule still applies to is marked `// thin-host: feature-specific, migrate to plugin`.

Stays in the host (platform-bound, generic): the `WKWebExtensionController` bridge — install/load/unload primitives, CRX/ZIP unpacking and manifest checks (`ExtensionPackage`), the registry, `WKWebExtensionTab` / `WKWebExtensionWindow` adapters (`ExtensionBridge`), permission grants, the web view hooks, and hosting an extension's popup web view in a popover.

To migrate to the `extensions` plugin (marked in the code):

| Host code | Why it's feature-specific | Target |
|---|---|---|
| `StoreButton.swift` + `ExtensionsService` "Store pages" (`pageChanged`, `storeMessage`, `storeButtons` setting) | Store detection and the "Add to den" flow | Plugin: a generic host "inject script into pages matching X in an isolated world, relay messages" primitive; the plugin owns the script, hosts and policy |
| `ExtensionsService.installFromStore`, "Downloads", "Updates" | Chrome Web Store / AMO endpoints, update schedule (24 h) | Plugin, over `net.fetch` (needs a binary download-to-file variant) and a host `install {path}` primitive |
| `ExtensionText.swift`, "Permission prompts", `toast`, `failed`, `pickFile` strings | User-facing strings and dialog composition | Plugin: host emits `extensions.permissionRequest {request, permissions, patterns}` and waits for `extensions.answer {request, allow}` |
| `ExtensionsUI.showMenu`, `ExtensionsMenuView`, `menuItems` (pinning policy) | Menu layout, labels ("Manage Extensions", "Get Extensions") and which extensions show | Plugin: a generic host popover that renders a node tree, plus `extensions.actions` data (icon, badge) |
| URL pill extension buttons (`Rows.swift` `syncExtensions`, `PillExtensionButton` in `ExtensionsUI.swift`) | The pill knows about extensions | Generic pill `accessories: [{id, icon, badge}]` node field filled by the plugin through the tabs header |

Already in the plugin: the Extensions page, its strings and layout, the commands ("Extensions", "Install Extension from File…", "Get Extensions"), removal confirmation, update toasts.

---

## Addendum: the Settings window, menu bar, theme tokens and web page prompts

These landed after the survey above, with the marker `// thin-host: feature-specific, migrate to plugin` on each feature-specific piece in code. Status: **marked** (marker in code) or **listed**.

### Generic building blocks (keep in the host)


| Piece | Why it's generic |
|---|---|
| `settings` service + Settings window | Renders schema-driven controls (toggle, choice, text, shortcut, number, list, button, info). Plugins own every section and all copy |
| Theme tokens (`ThemeTokens`, `Palette`, `SurfaceGrain`) | Colors derived from any theme; no feature knowledge |
| `HoverTracker` | Pointer-derived hover for any hoverable view |
| `keys` service, `MainMenu.install` mechanics, `menuEquivalent` | Binding chords to events through AppKit's key path |
| `ui` slots, `Renderer`, generic nodes (`list`, `row`, `text`, `button`, `dialog`, `toast`, `sheet`, `section`, `toggleRow`, `choiceRow`, `actionButton`) | Composition primitives |
| `webviews`, `content`, `window`, `storage`, `net`, `session`, `schedule`, `app`, `config` | Platform services |
| `webviews` page operations: `zoom`, `find`, `print`, `inspect`, `viewSource`, `reload {fromOrigin}` | Operations on a web view; the find bar UI is the exception below |

### Feature-specific, in the host (migrate)

| Piece | File | What's feature-specific | Where it should go |
|---|---|---|---|
| General section | `Services/GeneralSettings.swift` (marked) | Default-browser copy, `~/.den` rows, accent choice | A `general` plugin registering the section; the accent choice can stay a host setting that plugins read |
| Menu bar layout | `Services/MainMenu.swift` `layout` (marked) | Plugin event names, command ids and titles hard-coded per menu | Plugins place their own items: `keys.bind {menu, order}` for chords and `commands.register {menu, order}` for commands; the host keeps the menus and the standard AppKit items (Edit, Window, app) |
| Menu host actions | `Services/MenuActions.swift` (marked) | Help links, the page-action mapping | Help links in a plugin; page actions become commands a plugin registers |
| Icon picker | `Toolkit/IconPicker.swift` (marked) | The curated symbols and emoji, "Space Icon" copy | A generic grid-picker node; `spaces` sends the items and title |
| Web page prompts | `Services/WebPrompts.swift` (marked) | Dialog copy, permission and sign-in wording, per-site memory | A prompts plugin answering `webviews.prompt` events; the host keeps the WKUIDelegate plumbing |
| Error pages | `Services/WebErrorPage.swift` (marked) | Error copy and HTML | A plugin answering a `webviews.loadFailed` event with the page to show |
| Page actions policy | `Services/PageActions.swift` (marked) | Per-site zoom memory, context-menu items and their wording, link-modifier policy | Plugins (zoom memory in `tabs` or a `zoom` plugin; context menu items registered by plugins) |
| Find bar | `Toolkit/FindBar.swift` (marked) | A dedicated view | A generic floating-bar node composed by a `find` plugin |
| Space footer reorder | `Toolkit/Rows.swift` `SpaceIconReorder` | Tied to the `spaceIcon` node | A generic `reorderable` behavior for any node in a `row` |
| Theme picker | `Toolkit/ThemePicker.swift` (listed) | Arc's picker as one node | Generic pad/slider/dial nodes composed by `theme` |
| Command bar view | `Toolkit/CommandBarView.swift` (marked) | Banner copy, row semantics | Already driven by the `commandbar` plugin's tree; the banner node could be a generic `banner` |
| Library sheet | `Toolkit/Library.swift` (listed) | "Clear Archive", day grouping | A generic `sheet` + `list` composed by `tabs` |
| Hover card | `Toolkit/HoverCard.swift` (listed) | Card layout specific to previews | Generic card node; `previews` composes it |
| Briefing and connection rows | `Toolkit/SheetNodes.swift` `todoRow`, `feedRow`, `connectionRow` (listed) | Feature rows | Compose from generic row parts |
| Little Arc chrome | `Window/MiniWindow.swift` (listed) | "Open in <space>" button | A generic mini-window with a toolbar tree from `peek` |
| Search suggestions | `Services/SuggestService.swift` (listed) | Google's endpoint | A plugin fetching through `net` |
| AI prompts | `Services/AIService.swift` (listed) | Summary and todo instructions | Plugins pass their own instructions (they mostly do) |
| `[shortcuts]` and `[search.keywords]` | `DenHome/ConfigService.swift` (marked) | Applies keywords to the command bar | The `commandbar` plugin reads `config` itself |
| Dev scenarios | `Scenarios/*` | Demo states | Fine: dev tooling, not shipped behavior |

### How to migrate one piece

1. Add the generic primitive the feature needs to the host (a node type, an event, a service method), with no feature strings.
2. Move the copy, policy and composition into the owning plugin (`Plugins/<id>/`), tested with `Harness`.
3. Delete the host code and its marker; update this table.
