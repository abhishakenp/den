# den host API (v0)

The host is a small AppKit app. Browser features (spaces, tabs, peek, command bar logic, themes) are plugins. The host gives them services and renders their UI.

- Every service is one handler, `(method: String, args: Value) -> Value`. It has the same shape as `cordis_service_fn` in `cordis.h` (sibling `cordis-swift` package), so each one registers with cordis `PluginHost.provide(name, handler)` unchanged.
- Errors come back as `{"error": "<message>"}`. Success without a result returns `{"ok": true}`.
- Events go on the host bus as `<service>.<event>`, and plugins subscribe with `on`.
- Asynchronous results always arrive as events. No call blocks.

The code lives in `Sources/DenHost/Services/`. `DenRuntime` registers every service with cordis `PluginHost.provide` and re-emits every host event on the `PluginHost` bus, so plugins use `ctx.call/on/emit` and host code uses `DenRuntime.call` / `runtime.plugins.on`.

## Plugins

- Loaded at launch from `den.app/Contents/PlugIns/*.dylib`, `~/Library/Application Support/den/Plugins/*.dylib` and `~/.den/plugins` (`<id>.dylib`, or a `<id>/*.swift` source folder den compiles). A later layer replaces an earlier one with the same file name. `~/.den` is watched, so adding, replacing or removing a plugin there hot-swaps it in the running app ([den-home.md](den-home.md)).
- `--dev-plugins <dir>` also loads `<dir>/*.dylib` (these win over all others) and hot-reloads each file when it is rebuilt.
- If a plugin crashed den, the same build is refused on the next launch, and a toast names it. A new build of that plugin loads normally.
- `scripts/bundle.sh` builds every `Plugins/<id>/` (plus `Plugins/Shared/`) with `cordis-build` into `Contents/PlugIns/<id>.dylib`.

## window

| Method | Args | Returns |
|---|---|---|
| `setTheme` | `colors: [hex]` (≤3), `intensity 0–1`, `grain 0–1`, `appearance: light\|dark\|auto`, `page?` | ok |
| `setSidebar` | `width?`, `hidden?`, `animated?` | ok |
| `toggleSidebar` | `animated?` | ok |
| `setTitle` | `title`, `window?` | ok |
| `get` | – | `{width, hidden, page, fullScreen, dark, id, private, count}` (the active window; `count` = browser windows) |
| `new` | `private?`, `id?` (a normal window's old id: its saved frame comes back; a taken id gets the next free one), `page?`, `focus?` (true), `restored?`, `sidebarHidden?` | `{id}`. A browser window on the same spaces (⌘N), or a private one (⇧⌘N). Emits `window.opened`, then (with `focus`) `window.activated` |
| `list` | – | `[{id, private, page, panes, focus, key, visible, frame}]`, first window first |
| `focus` | `id` | ok. Brings that window forward and makes it active |
| `close` | `id?` (the active one) | ok. See "Closing" below |
| `openMini` | `webview`, `space?` (name on the "Open in" button), `width?`, `height?` | `{id}`. Opens a Little Arc window hosting that web view |
| `updateMini` | `id`, `space?` | ok |
| `closeMini` | `id` | ok. The web view is detached, not closed |
| `listMini` | – | `[{id, webview, key}]`. `key` is true for the key window (the peek plugin's ⌘O acts on it) |
| `focusMini` | `id` | ok. Brings that Little Arc window to the front (the command bar's Windows rows) |

Events: `window.sidebarResized {width, by: drag|reset|set}` (a drag when it ends, a double-click reset on the edge, or a plugin's `setSidebar`), `window.sidebarVisibility {hidden}`, `window.sidebarReveal {revealed}`, `window.miniAction {id, webview, action: open|copy}`, `window.miniClosed {id, webview}`, `window.opened {id, private, page, panes, focus, restored}`, `window.activated {id, previous, private, page, panes, focus}`, `window.closed {id, private, page, panes, focus, frame}`, `window.reopen` (File ▸ Reopen Closed Window).

**Several windows** (`WindowSet.swift`). `w1` exists from launch; ⌘N (`window.new`) adds `w2`, `w3`… (the lowest free number, so saved frames stay few), ⇧⌘N adds private `p1`, `p2`…. Host services act on the **active** window, the one most recently key: `content`, `ui` overlays, the find bar, page prompts (a page's dialog goes over the window that shows it), the mini player. Per window, the host keeps the content area (panes, cards, peek) and the sidebar; `content.show/get` and `ui.set/showPage/setPages` take an optional `window` to address another one. What a window shows is the plugins' business: the host never picks tabs.

- **Sidebar trees.** A `ui.set` of a sidebar slot without `window` goes to every normal window; with `window`, to that one only. A new normal window starts with a copy of what the active one shows, on the same page, and each window paints its trees with its own space's palette. Space themes (`setTheme`) apply to every normal window; each shows its own page.
- **One live page.** A web view is in one window at a time. `content.show` of a page another window has on screen moves the live view (no reload, no second process), and the window it left shows "Open in another window · Show Here" in that pane. When that window becomes active again it takes the page back (Arc's Tab Handoff).
- **Private windows** wear `Tokens.privateTheme` (always dark; space themes don't reach them), take only sidebar trees addressed to them, and have one sidebar page. Web views with profile `private:<window>` share one `WKWebsiteDataStore.nonPersistent()` per window, released when it closes (`releaseStore`). A private page never writes a snapshot to disk (no switch snapshot, `snapshot` to a path is refused; a capture you ask for still works) and its zoom isn't remembered.
- **Closing.** Closing any window but the last normal one removes it and its views (its pages stay alive, just off screen) and emits `window.closed` with what it showed and its frame; the next window in front becomes active. The last normal window only hides, as before (the Dock brings it back).
- **Frames.** `w1` keeps the `den.main` autosave name; `w2`… use `den.window.<id>`; private windows remember nothing. A new window cascades from the one in front.

**Little Arc** (spec §8) is a floating panel, 1185x832 by default, placed 20 pt from the screen's right edge and 20 pt below the menu bar. A 47 pt bar holds the traffic lights, a URL field (site icon, centered domain, copy-link button → `action: copy`) and an "Open in <space> ⌘O" button (→ `action: open`). The web view fills the rest, with no inset card. The bar follows the main window's theme. For "Open in space", the plugin calls `closeMini` and then shows the same web view with `content.show`; closing the window emits `miniClosed`, and the plugin decides whether to close the web view. The ⌘O shortcut itself is bound by the plugin through `keys`.

- Themes are kept per space page. The background blends between page themes while you swipe.
- The sidebar resizes by dragging its edge; a double-click on the edge resets the width.
- Dragging the edge below 120 pt hides the sidebar. While it's hidden, hovering the left window edge reveals it as an overlay.
- Empty sidebar space drags the window.
- Full screen (⌃⌘F) hides the sidebar, as in Arc: the page fills the screen and hovering the left edge reveals the sidebar. Leaving full screen shows it again, unless it was hidden before or you already brought it back with ⌘S.
- Links, URLs and files dropped on the sidebar emit `window.dropURLs {urls, target: "sidebar"}`.

## webviews

| Method | Args | Returns |
|---|---|---|
| `create` | `id?`, `url?`, `profile?` (`default`, `private`, or any name, which maps to a stable `WKWebsiteDataStore(forIdentifier:)`), `userAgent?` (`mobile`: Safari on an iPhone, for web panels; or any string) | `{id}` (lazy: no `WKWebView` until shown) |
| `mediaControl` | `id`, `action: play\|pause\|toggle\|next\|previous\|seek\|skip\|stop`, `value?` (s) | ok, or an error when the page plays nothing (or has no next track). Acts on the page's now-playing media, in the frame that reported it. `next` / `previous` run the page's own Media Session handlers (`previous` without one restarts the track); `stop` pauses and drops it from now playing until it plays again |
| `navigate` | `id`, `url` | ok |
| `back`, `forward`, `reload`, `stop`, `close` | `id` (optional except for `close`), `fromOrigin?` (`reload`: ⇧⌘R, skips the cache) | ok |
| `zoom` | `id?`, `action: in\|out\|reset` | `{zoom}`. Safari's steps, 50–300% (`Tokens.zoomSteps`). Remembered per site (host without `www.`, storage ns `_zoom`; 100% is not stored) and re-applied whenever a page's host changes. Emits `webviews.zoom {id, zoom}` |
| `find` | `id?`, `action: show\|next\|previous\|selection\|hide`, `query?` | `{visible, query, index, count}`. The find bar (below). `selection` (⌘E) searches for the page's selected text |
| `print` | `id?` | ok. The print panel, as a sheet on the window |
| `inspect` | `id?`, `console?` | ok, or an error if WebKit has no entry point. Opens the Web Inspector (or its console) |
| `viewSource` | `id?` | `{pending}`. Opens the page's current DOM as a new tab (see below) |
| `suspend` | `id`, `force?` | `{suspended: true}`, or `{suspended: false, reason}`. Full discard: keeps `interactionState` (back/forward list and scroll, ~1 KB), destroys the WKWebView, and its WebContent process exits. The page's snapshot is already on disk (below). Without `force` it refuses a page that plays media (`media`), is in picture in picture (`pip`), uses the camera or microphone (`capture`), holds unsaved form input (`form`), or is on screen (`visible`: a pane, peek, Little Arc, the mini player) |
| `pauseMedia` | `id` | `{paused: true}`, or `{paused: false, reason: notLive\|pip\|visible\|notPlaying}`. `pauseAllMediaPlayback` for a page that is not on screen (no window: not a pane, peek, Little Arc or the mini player) and not in picture in picture (battery saver) |
| `setAutoplay` | `allowed` | ok. For every web view created from now on: `false` sets `mediaTypesRequiringUserActionForPlayback = .all` (media waits for a click). WebKit fixes it per configuration, so live pages keep theirs |
| `setMuted` | `id`, `muted` | ok. WebKit's page mute (`_setPageMuted:`, Safari's tab mute): every frame, `<audio>`/`<video>` and WebAudio, without changing the page's own `muted`. Kept across discards while the tab lives. Emits `webviews.muted` |
| `snapshot` | `id`, `path`, `width?` (pt; a small copy at 2x, for previews), `format?: png\|jpeg` | `{pending}`, then the event `webviews.snapshot {id, path, ok}`. A view that can't draw (not in the window) writes its last snapshot, if any |
| `snapshot` (capture) | `id`, and any of `rect?: {x, y, width, height}` (CSS px of the document, scroll included), `full?`, `clipboard?`, `folder?` + `name?` | `{pending}`, then `webviews.snapshot {id, ok, path?, clipboard, width, height, bytes, error?}` (pixels). See [Capture](#capture) |
| `eval` | `id`, `plugin`, `script` (a function body that `return`s JSON data, ≤ 4 KB), `request?`, `timeoutMs?` (5000) | `{request}`, then `webviews.evalResult {request, webview, ok, value \| error}`. Only for a live page (it never loads or wakes one), in an isolated content world, and only when `plugin` has `session:<the page's host>` |
| `inject` | `id`, `plugin`, `files?: [name]` (from the plugin's resource folder), `global?`, `script?` (function body, ≤ 64 KB), `args?` (named arguments of `script`), `request?` | `{request}`, then `webviews.injectResult {request, webview, plugin, ok, value \| error}`. See [Plugins in pages](#plugins-in-pages) |
| `setMenu` | `plugin`, `items: [{id, title, when?: selection\|any}]` (`[]` removes) | ok. Picking one emits `webviews.menu {id, webview, plugin}` |
| `setContentRules` | `plugin`, `rules: [WebKit content rule]` (`[]` removes) | `{pending}`, then `webviews.contentRules {plugin, ok, count, error?}` |
| `get` | `id` | `{id, url, title, favicon, loading, progress, canGoBack, canGoForward, audio, muted, media: {playing, audible, pip, dirty, video?}, suspended, live, profile, snapshot, zoom}` |
| `list` | – | `[id]` |
| `setLinkPolicy` | `id` (or `"*"` for the default), `rules: [{when: crossSite\|sameSite\|any, hosts?: [suffix], modifiers?: [cmd,shift,opt,ctrl], event}]` | ok |
| `watchLinks` | `modifier: shift\|none\|off`, `yieldTo?: [css selector]` | ok. For every web view, now and later: reports the link under the pointer (`webviews.linkHover` / `webviews.linkHoverEnd`). `shift` reports only while Shift is held, `none` on plain hover, `off` removes the script and handler. Nothing is installed until a plugin calls it |
| `watchStatus` | `enabled` | ok. The link *status* report, independent of `watchLinks` (one shared script): `webviews.linkStatus {id, url}` for the link under the pointer on plain hover, or under keyboard focus. Any scheme except `javascript:` (`mailto:` counts). `url: ""` when there is none. Used by the status pill |

Events:
- `webviews.title {id,title}`
- `webviews.url {id,url}`
- `webviews.favicon {id,url}`
- `webviews.progress {id,progress,loading}`
- `webviews.state {id,canGoBack,canGoForward}`
- `webviews.audio {id,playing}` (audible media)
- `webviews.muted {id,muted}`
- `webviews.media {id,playing,pip,dirty}`: den's page script (its own content world, every frame) reports media and unsaved input when they change; no polling
- `webviews.nowPlaying {id, now: {title, artist, album, art, paused, dur, video, acts} | null, muted}`: the page's "now playing", when it changes. It is the last `<audio>`/`<video>` that played with sound (a muted autoplaying video never counts), with the page's Media Session metadata (title, falling back to the page title; the largest artwork as an absolute http(s) URL; `acts` = the Media Session actions the page handles, e.g. `nexttrack`). null once it's stopped, its element is gone, the page navigates, or the view is discarded. Also in `get`: `media.now`. The only page-world script (`PageScripts.sessionHook`) keeps the page's `setActionHandler` handlers so `mediaControl` can call them, and notes metadata changes; the two worlds exchange strings only
- `webviews.newWindow {id,url}`
- `webviews.crashed {id}`: the page's web process died. The host shows den's "This page crashed" page with **Reload** in its place (at once when on screen, else the next time it's shown), keeping the URL; it never reloads by itself
- `webviews.suspended {id}`
- `webviews.detached {id}`
- `webviews.closed {id}`
- `webviews.evalResult {request, webview, ok, value | error}`
- `webviews.zoom {id, zoom}`, `webviews.find {id, visible, query, index, count}`
- `webviews.injectResult {request, webview, plugin, ok, value | error}`, `webviews.message {webview, plugin, value}`, `webviews.menu {id, webview, plugin}`, `webviews.contentRules {plugin, ok, count, error?}`
- One event per link rule, named by the rule's `event` field: `{id, url, source}`.
- `webviews.linkHover {id, url, text, rect: {x, y, w, h}, yield}` and `webviews.linkHoverEnd {id}` (after `watchLinks`). `rect` is the link's box in window points with a top-left origin (page zoom and magnification applied). `yield` is true when an element matching one of `yieldTo` is visible, i.e. the site is showing its own preview (Wikipedia's `.mwe-popups`). The end event fires when the pointer leaves the link, Shift is released (shift mode), the page scrolls or the mouse goes down. The same link doesn't report twice in a row.
- `webviews.linkStatus {id, url}` (after `watchStatus`): the link under the pointer changed. Moving straight from one link to the next sends only the new one (no `""` in between, so a pill doesn't flicker); `""` when the pointer leaves the links, the page loses focus or unloads.

**Link hover.** A few passive listeners in an isolated content world (`den-links`), main frame only: no timers and no network. Only http(s) links count; `javascript:` links and same-page `#fragment` links are ignored. The host fills in `id` from its own record of the sending web view and never takes one from the page. What to show, and when to defer to a site's own previews, is up to the plugin (`LinkHover.swift`).

**Passkeys** (`Passkeys.swift`). Without Apple's browser entitlement (`com.apple.developer.web-browser.public-key-credential`, [research/passkeys.md](research/passkeys.md)) every platform-passkey and hybrid (phone / Bluetooth) request fails, yet WebKit's `getClientCapabilities()` claims both, so Google starts a passkey sign-in and ends on "Make sure Bluetooth is on". A document-start script in the page world (every frame) therefore reports what den can do: `isUserVerifyingPlatformAuthenticatorAvailable()` and `isConditionalMediationAvailable()` resolve false, and `getClientCapabilities()` answers false for `passkeyPlatformAuthenticator`, `userVerifyingPlatformAuthenticator`, `hybridTransport`, `conditionalGet` and `conditionalCreate` (everything else, and `navigator.credentials`, untouched). The alternative, WebKit's private `WebAuthenticationEnabled` feature flag (`WKPreferences._setEnabled:forFeature:`), removes `PublicKeyCredential` entirely: SPI, and sites then see a browser without WebAuthn. Setting: General ▸ "Skip passkey sign-in, use the password" (`settings` id `general`, key `passkeyFallback`, default on; web views created afterwards). It switches itself off when den runs with the entitlement (`SecTaskCopyValueForEntitlement`). `PasskeysTests` checks both states in a live web view.

Every web view sends Safari's user agent for this macOS (`applicationNameForUserAgent` = `Version/<Safari's version> Safari/605.1.15`, read once from Safari's Info.plist). WKWebView's default leaves that suffix out, and Google's sign-in then blocks the browser as an embedded web view.
`webviews.newWindow {id, url, background?}` asks for a new tab: from `target=_blank` / `window.open` (selected), from the browser link clicks below, and from View Source.

The link policy is declarative because `WKNavigationDelegate` decisions are synchronous. A matched rule cancels the navigation and emits the rule's event. Only main-frame link clicks are routed, and a plain rule never catches cmd-clicks.

**Browser link clicks** (after the rules): ⌘-click or a middle-click on a link opens a new background tab, ⌘⇧-click a new selected tab (`webviews.newWindow` with `background`). Shift- and option-click stay with the rules (Peek).

**Page actions.** `zoom`, `find`, `print`, `inspect`, `viewSource` and `back`/`forward`/`reload`/`stop`/`get` default `id` to the page in front: the open peek, else the focused pane. The menu bar calls them. Nothing is built until first use (`PageActions.swift`).

- **Find bar** (den's own design; Arc's was never measured): a 320x36 pill 12 pt from the card's top right (`Tokens.findBar*`), PopoverBackground colors, with a magnifier, the query, "3 of 12", previous / next and close. Return = next, Shift-Return = previous, Esc closes and gives focus back to the page. Matching runs in den's own content world with the CSS Custom Highlight API: every match is tinted yellow and the current one orange, like Safari's find overlay (`WKWebView.find` only selects, which doesn't show while the find field has focus). Case-insensitive, text node by text node (a match can't span elements), hidden elements skipped, at most 1000 matches, wrapping, scrolling the current match into view. Closing clears the highlights and keeps the query for ⌘G. Snapshot: `--scenario findBar` (`docs/screenshots/find-bar*.png`).
- **Web Inspector.** WebKit has no public call that opens it (`isInspectable` only lets Safari's Develop menu attach), so `inspect` uses WKWebView's private `_inspector` (`show` / `showConsole`), checked with `responds(to:)` first; if a WebKit update removes it, the call returns an error instead of crashing.
- **View Source.** WKWebView has no `view-source:`. `viewSource` reads `document.documentElement.outerHTML` (the current DOM, not the bytes the server sent), escapes it into a monospaced `data:` page titled "Source of <url>" (capped at 2 MB), and opens it with `webviews.newWindow`.

**Den's web view** (`DenWebView`):
- **Context menu:** WebKit's items reworded for tabs: "Open Link in New Tab" (background), "Open Link in Peek" (when something listens to `peek.link`), "Save Link As…" and "Save Image As…" (a download into a save panel sheet, with the page's own session), "Open Image in New Tab", and for selected text "Search <engine> for “…”" with the command bar's default engine (`commands.engines`, Google without it). The right-clicked link, image and selection come from a `contextmenu` listener in the page (`denContext` message), which arrives before WebKit asks for the menu.
- **Mouse buttons 4/5** go back and forward. Two-finger swipes navigate back/forward (`allowsBackForwardNavigationGestures`), and pinch and smart zoom work (`allowsMagnification`).
- **Dropped files** from Finder open as new tabs instead of replacing the page. File URLs load with read access to their folder.

**Dropping links** on the sidebar (a dragged link, a URL string, files) emits `window.dropURLs {urls, target: sidebar|content}`; the `tabs` plugin opens them as today tabs, the last one selected.

### Plugins in pages

Generic blocks for plugins that work inside web pages (`PageScripting.swift`). The `pagetools` plugin's reader, translation, capture, Zap and text-fragment links are built only from these.

- **`inject`** runs the plugin's own code in a live page (never loads or wakes one), in the plugin's own isolated content world `den.plugin.<id>`: the page's scripts can't see it, and plugins can't see each other's. `files` are read from the plugin's resource folder (`Plugins/<id>/resources/`, bundled as `Contents/Resources/plugin-resources/<id>/`) the first time they're used, then cached; `..` and absolute names are refused. With `global`, the files are skipped when `window[global]` already exists in that world (a library loaded once per page). Then `script` runs as an async function body with `args` as named arguments; its return value (JSON data) comes back in `webviews.injectResult`. A thrown error comes back as `error` with the exception's message.
- **Permission** `pages:<domain>` (or `pages:*`) in the plugin's `permissions.json`; a `session:<domain>` grant also covers its site. Anything else is refused.
- **Messages.** Code in the plugin's world calls `webkit.messageHandlers.den.postMessage(value)`; den emits `webviews.message {webview, plugin, value}`. A web view gets this handler on the first `inject` into it, and loses it when it is discarded.
- **Context menu.** `setMenu` items appear in every page's context menu; `when: selection` items only in the menu for selected text (right after Copy).
- **Content rules.** `setContentRules` compiles the plugin's [WebKit content rules](https://developer.apple.com/documentation/safariservices/creating-a-content-blocker) (`block`, `css-display-none`, …) into one list per plugin, added to every live and future web view. WebKit applies them at document start, with no script.
- **Cost.** Nothing runs until a plugin calls one of these: no scripts, handlers or rule lists at launch.

### Capture

`snapshot` with `rect`, `full`, `clipboard` or `folder` is a capture, drawn by WebKit with no scrolling or stitching: a rect on screen is a `takeSnapshot` of it; anything reaching past the visible area (a `full` page, a tall element) comes from WebKit's whole-document PDF (`createPDF`), rasterised at the screen's scale and cropped (up to 16,000 pt tall). `takeSnapshot` alone leaves everything off screen blank, which `PageBlocksTests` checks. No `rect` and no `full` means the visible area. The PNG goes to `path`, or to `folder`/`name` (made unique with " 2", " 3" …), and/or to the general pasteboard as PNG and TIFF. The picking UI (region, element) belongs to the plugin.

## content

| Method | Args | Returns |
|---|---|---|
| `show` | `panes: [webviewId]` (1–4), `orientation?: horizontal\|vertical\|grid`, `ratios?`, `focus?` | ok |
| `focus` | `id` | ok |
| `peek` | `webview` to show, or `{}` to hide | ok |
| `side` | `webview`, `width?` (280–520, default 360) / `{}` to hide | ok. The side column: one web view in a card at the content's left edge, beside whatever the panes show and across tab and space switches; the panes make room. It slides out from the sidebar edge (0.25 s, Dia's curve; none with Reduce Motion) with the card at full width, clipped, so it doesn't squeeze. Its header is the `side.header` ui slot. Hidden, the web view leaves the window, so `webviews.suspend` can discard it |
| `get` | – | `{panes, orientation, focus, peek, side, sideWidth}` |

Events: `content.focus {id}`, `content.peekAction {action: close|expand|split, webview}` and `content.paneAction {id, action: close|separate}`.

**Peek** (`content.peek {webview, title?}`) floats the web view in a card over the content area: 56 pt from the sides and 40 from the top and bottom, 10 pt radius, a deep shadow and a black α0.25 dim. The `title` shows in a small pill above the card. A column of round 34x33 buttons (the Little Arc side-control size, spec §8) sits right of the card's top edge: close, expand (open as a tab) and split. Each emits `content.peekAction`, and so does a click on the dim (`close`). It opens with a 0.28 s scale-from-94% and fade using Dia's (0.2, 0.8, 0.2, 1) curve, and closes with a 0.16 s fade. Reduce Motion turns both off. Arc's Peek was never measured (spec §12), so these values are estimates.

**Split view chrome** (Arc's split geometry is UNVERIFIED, spec §12, so these are estimates):
- Panes sit 8 pt apart, each in its own 6 pt-radius card.
- The focused pane gets a 2 pt ring in the space accent, drawn in the gap just outside the card.
- Hovering a pane shows a small dark pill at its top center with **close** and **separate** buttons. They emit `content.paneAction`; the owning plugin closes the pane or moves the page back into its own tab.
- Dragging a tab (`tabRow`/`favoriteTile`) over the content shows a theme-tinted drop zone: the left or right half, or the whole card for the middle third. Dropping emits `dropOnContent {source, side}`, and a haptic tick marks each side change.

**No white flash.** A new web view draws no background of its own until its first visually non-empty paint (WebKit's `_drawsBackground` and rendering-progress events, checked with `responds(to:)`; a finished load counts too), so the card behind it shows: the page's own colour, sampled from its last snapshot (or its host's), else den's card colour for the appearance. When one page replaces another (a tab switch), the old page stays on screen above the new one until it paints, at most `Tokens.paintHoldTimeout` (1 s); it takes no clicks. Snapshot placeholders use the snapshot's own colour behind the image, never white.

Web views that aren't shown are detached from the window, which lets WebKit suspend them. On the way out a page waits invisibly in the window for a moment while a snapshot is taken (WebKit only snapshots a view in a window): 1280 px wide, JPEG at quality 0.55, written off the main thread to a per-process temporary folder that is removed at quit. It is never kept in memory. When a discarded page is shown again, that snapshot covers the new web view at once and fades out when the page has loaded (at most 1.5 s).

A leaving page whose video is playing goes to the mini player instead (see [media](#media)).

## media

den's mini player (`// thin-host` marker: to move into a plugin over generic primitives). When the video you watch would leave the screen, the tab's live web view moves into a frameless, always-on-top panel (on every Space and over full-screen apps) showing only the video, and moves back when you return: no reload, no second process.

- **Triggers:** switching away from the tab (`content.show` without it); den resigning active, being hidden, or its window losing visibility (covered, minimized, another Space). The last three wait for the window state to hold for 200 ms, so a quick ⌘-Tab away and back does nothing. Coming back returns the video inline where it is, still playing.
- **Which video:** playing, audible (not muted by the page, its volume or the tab), at least 5 s long or live, at least 200x100 on the page, with a video track, and not closed by the user earlier in the session. One player at a time.
- **Isolation:** den's page script marks the video (or, from the parent frames, the iframe holding it) and a style makes it fill the viewport on black with everything else invisible. Layout is untouched, so undoing it is exact.
- **Controls** (on hover, and while paused): back to the tab (also double-click and Esc), system picture in picture, close (pauses; remembered), ±10 s, play/pause, mute and volume, playback speed, a seek bar with elapsed and remaining time. Keys: space, ←/→ (5 s), ↑/↓ volume, M. Drag to move, drag a corner to resize (aspect locked); it snaps to the nearest screen corner, which is remembered with the width. The page reports playback only while the player shows it, on `timeupdate` (at most 4 a second).
- **Extras** (Dia, Firefox): the page's host in a chip at the top (click: back to the tab); **keep on top** (pin button, T; `settings.keepOnTop`, persisted, default on: `.floating`, off: `.normal` level); **CC** (C) when the video has `subtitles`/`captions` text tracks (`cc` in the video info and playback: 0 none, 1 available, 2 showing; the toggle shows the track matching the system language, else the first); **stash**: dropped with its centre past the left or right screen edge, it tucks there with a 28 pt strip and a chevron left on screen, controls off; a click on it (or `control unstash`) glides it back to the nearest corner on that side. Firefox's picture-in-picture keys: ⌘←/⌘→ a tenth of the video (`seekpct`), Home/End (`start`/`end`), ⌘↓/⌘↑ mute/unmute, ⌘W close (the panel takes ⌘-keys before the main menu while it is key).

| Method | Args | Returns |
|---|---|---|
| `get` | – | `{open, webview?, fromWindow?, frame?, stashed?, settings: {autoMiniPlayer, keepOnTop}}` |
| `settings` | `autoMiniPlayer?`, `keepOnTop?` | `{autoMiniPlayer, keepOnTop}` (persisted, both on by default) |
| `open` | `webview` | ok, or an error when it plays no video |
| `control` | `action`, `value?` | ok (an error when no player is open). What the panel's controls and keys do: `play`, `pause`, `toggle`, `seek` (s), `skip` (±s), `seekpct` (± fraction), `start`, `end`, `volume` (0–1), `mute` (0/1), `rate`, `cc`, `keepOnTop` (0/1), `unstash`, `pip`, `back`, `close` |
| `close` | – | ok (pauses the video), or an error when no player is open |

Events: `media.miniPlayer {webview, open}`, `media.backToTab {webview}` (the tabs plugin selects that tab), `media.playback {webview, t, dur, paused, muted, vol, rate}`.

## nowplaying

den's entry in Control Center's Now Playing and the keyboard's (and headphones') media keys: `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`, as a generic bridge. What is "now playing" and what a command does belong to the `media` plugin. Nothing is registered until the first `set`; `clear` removes the entry and every command handler.

| Method | Args | Returns |
|---|---|---|
| `set` | `title`, `artist?`, `album?`, `artwork?` (http(s) URL, loaded through the icon cache), `duration?`, `elapsed?`, `playing`, `commands?: [play, pause, toggle, next, previous, stop]` (default: all but next and previous) | ok. Only the listed commands are enabled |
| `clear` | – | ok |
| `get` | – | `{active, title, playing, commands}` |

Event: `nowplaying.command {command}` when Control Center or a media key asks for an enabled command.

WebKit may publish its own Now Playing entry for a playing web view as well; how the system picks between the two on a real Mac with media keys is not verified yet (CI runners have no media keys).

Picture in picture needs WKPreferences' private `allowsPictureInPictureMediaPlayback` on macOS (set through KVC when WebKit has it); `callAsyncJavaScript` counts as a user gesture for `requestPictureInPicture()`.

### Web page prompts and error pages

The host answers what a page asks for itself (`WebPrompts.swift`, `WebErrorPage.swift`); plugins aren't involved and nothing blocks the app (WebKit's completion handler is kept and called when you answer). Dialogs use the `dialog` look (spec §5) with the current space's palette, over the window that shows the page (a Little Arc panel too), one at a time. Closing a page answers its pending dialogs with Cancel. Snapshots: `--scenario jsAlert|jsConfirm|jsPrompt|httpAuth|permissionCamera|errorHost|errorOffline|errorSecure` (`docs/screenshots/js-*.png`, `http-auth*.png`, `permission-camera*.png`, `error-*.png`).

| Page asks for | den shows |
|---|---|
| `alert()` / `confirm()` / `prompt()` | "<host> says", the message, OK (↩) / Cancel (esc); `prompt()` adds a text field holding the default text. From the fourth in one page load, a checkbox "Stop this page from showing dialogs": ticked, the page's later dialogs get the cancel answer at once until it navigates (Dia 1.15) |
| HTTP Basic, Digest or NTLM sign-in | "Sign in to <host>", the realm, Username and Password fields, Cancel / Sign In. A wrong password asks again ("That didn’t work."); plain http says the password is sent unencrypted. The credential goes to WebKit for the session only; den never logs or stores it. Cancel shows the server's own 401 page |
| Camera / microphone (`getUserMedia`) | "Allow <host> to use your camera (and microphone)?", Don’t Allow / Allow. The answer is kept per origin and device until den quits. The app declares `NSCameraUsageDescription`, `NSMicrophoneUsageDescription` and the hardened-runtime camera / audio-input entitlements, so macOS asks once for den itself |
| `<input type=file>` | The **upload picker** first (`UploadPicker.swift`, Opera's idea): "Upload to <host>" with up to 3 recent downloads (last 7 days), the 3 newest screenshots (in the Screenshot app's folder, else the Desktop; last 7 days) and the clipboard (a copied file or image), filtered by the input's `accept` (WebKit's private `_acceptedMIMETypes` / `_acceptedFileExtensions`, checked with `responds(to:)`). A click on a row uploads it (with `multiple`, rows tick and Upload sends them); **Choose File… ⌘O** opens the open panel as a sheet, with the input's multiple / directory options. With nothing to offer, or a folder input, the panel opens at once. The clipboard's types are checked when the page asks; its contents are read only when you pick it (an image is saved as a PNG in a temporary folder). Nothing runs until a page asks. Snapshot: `--scenario uploadPicker` |
| Geolocation, notifications | Not available: WKWebView on macOS has no public API to ask the user. WebKit denies them (`Notification.requestPermission()` resolves `"denied"`, verified in a live web view) |

**Error pages.** When a page fails before anything arrives (offline, unknown host, refused connection, timeout, certificate problems), den loads its own small page for that error with `loadSimulatedRequest` for the failed URL: an icon, a title ("You’re offline", "Can’t find <host>", "This connection isn’t private", …), one line of explanation, the URL, and **Try Again**. The tab keeps the real URL, so Reload, Try Again and Back/Forward retry it. The page takes the space's palette colors (with a `prefers-color-scheme` fallback). Cancelled or replaced navigations (NSURLErrorCancelled, WebKit's 102 and 204) show nothing. There's no "proceed anyway" for certificate errors. For an http(s) page that failed because the site is missing, refused the connection or timed out, the page also links **View on the Web Archive** (`https://web.archive.org/web/2/<url>`, the Wayback Machine's newest capture; `WebErrorPage.archiveKinds`). Not when offline (the archive is unreachable too) and not for certificate errors (possibly someone on the network; den doesn't route around it).

## ui

| Method | Args | Returns |
|---|---|---|
| `set` | `slot`, `tree` (null clears), `page?` | ok |
| `setPages` | `count`, `current?` | ok |
| `showPage` | `page`, `animated?` | ok |
| `get` | – | `{page, pages, overlays}` |
| `tokens` | – | den's theme tokens (`ThemeTokens`: space theme + appearance, contrast-checked) as CSS colors for UI drawn inside web pages: `{dark, bg, panel, text, secondary, border, hover, accent, onAccent, mark, shadow}` |
| `menu` | `id` (a node on screen), `items` (the `menu` item shapes) | `{shown}`. A context menu built on demand: a row or tile that sends no `menu` emits `contextMenu` on right-click, and the plugin answers with this; it opens at the pointer, and a pick emits the node's `menu` action. `tabs` works this way, so hundreds of rows hold no menus |

**Long lists are virtualized.** In a `list` inside a scroll view (the sidebar), `tabRow` and `splitRow` children (fixed height) get views only within 200 pt of the visible area and give them up beyond 1000 pt (unless hovered, pressed, focused or being renamed). Heights and order are unaffected; a row without a view is made from its latest value when it scrolls near.

**Slots:**
- `sidebar.header`, `sidebar.favorites`, `sidebar.dock` (right above the footer, as tall as its tree, at most 60% of the space below the favorites; the `media` plugin's now-playing cards), `sidebar.footer`
- `side.header`: over the side column's web view (`content.side`; the `panels` plugin's header)
- `sidebar.notice`: a small card pinned above the dock (or the footer when nothing plays), drawn by the host from the theme tokens (`ThemeTokens.card` fill, a 0.5 pt hairline, 10 pt continuous radius, 8 pt from the footer and the tabs above; a 0.2 s fade in, none with Reduce Motion). The tree is [generic nodes](#generic-nodes) (`stack`, `label`, `action`…); `null` removes it and gives the space back to the tabs. The `tips` plugin puts its tour and import cards there
- Per space page: `sidebar.spaceHeader`, `sidebar.pinned`, `sidebar.today`
- Overlays: `overlay.commandBar`, `overlay.peek` (`{webview, title}`), `dialog`, `toast`, `popover` (see [Theme picker](#theme-picker-popover)), `overlay.library` (see [Archive / Library](#archive--library-sheet)), `overlay.briefing`, `overlay.connections`, `overlay.passwords`, `overlay.extensions` (see [Briefing page](#briefing-page-and-connections-sheet)). Cards: [`ui.card`](#uicard-popover-cards-and-hover-intent)
- `status`: the link status pill (Arc). `{webview?, lead, text}`: a small pill at the bottom-left of that web view's page (a split pane, the Peek; else the content area), `lead` in the primary text colour (the host) followed by `text` in the secondary colour, middle-truncated to the page's width. When the pointer comes within 16 pt it slides to the bottom-right, and back when the pointer nears that corner. Card tokens (light and dark, themed), a 0.1 s fade (none with Reduce Motion), no clicks. `null` hides it; it never shows over the command bar, a dialog, a sheet, the Library or a popover, and hides when its web view leaves the window. While hidden: no mouse monitor, nothing running (`StatusPill.swift`)

**Event:** `ui.action {id, action, value}`

**Sidebar-level actions** (`id: "sidebar"`):
- `page` (value = the new page, after a swipe)
- `doubleClick` (on empty sidebar space)

**Node types** (the `type` field) and the actions they emit:

| Node | Fields | Actions |
|---|---|---|
| `list` | `children`, `spacing?`, `padding?` | – |
| `row` | `children`, `spacing?`, `height?` | – |
| `spacer` | `width?`, `height?` | – |
| `text` | `text`, `style: title\|body\|caption\|secondary` | – |
| `button` | `id`, `icon`, `title?`, `size?`, `tooltip?`, `enabled?`, `action?`, `progress?` (0–1: an accent ring around the icon; negative: a short arc, size unknown), `dot?` (a small accent dot: something new) | `click` (or `action`) |
| `navBar` | `id`, `canGoBack`, `canGoForward`, `loading` | `toggleSidebar`, `back`, `forward`, `reload`, `stop` |
| `urlPill` | `id`, `text`, `progress?`, `loading?`, `placeholder?`, `buttons?: [{id, icon, tooltip?, active?}]`, `webview?` | `click`, `copy`. A `buttons` item (always visible, left of copy; `active` tints it with the accent) emits `{id: <its id>, action: click, value: {webview}}` |
| `grid` | `columns?`, `children` | – |
| `favoriteTile` | `id`, `icon`, `title`, `selected`, `audio`, `muted?`, `dropInto?`, `badge?` (a short text chip at the tile's bottom, accent-filled: "in 8m"; the icon moves up 5 pt to make room) | `click`, `doubleClick`, `reorder`, `mute` (the speaker badge) |
| `spaceTitle` | `id`, `title`, `icon?`, `editing?`, `editText?` | `click`, `doubleClick`, `more`, `rename {title}`, `renameCancel` |
| `spaceIcon` | `id`, `icon?` (empty = dot), `title`, `selected`, `spaceId?` (makes it a drop target for dragged rows), `reorderable?` | `click`, `move {index}` (after a drag-reorder, see [Space icon reorder](#space-icon-reorder)) |
| `iconPicker` | `id`, `anchor?`, `title?`, `selected?` (popover slot) | `pick {icon}` (`sf:<name>`, an emoji, or "" to remove), `dismiss {reason?}` |
| `tabRow` | `id`, `title`, `icon`, `selected`, `highlighted?` (picked into a multi-selection; drawn like selected), `audio`, `muted?`, `media?: {paused, next, previous}` (while hovered: previous / play-pause / next buttons, left of the speaker; they emit `media {action: previous\|toggle\|next}`), `drift` (the "/" marker), `closable=true`, `closeTitle?` (the X's tooltip), `indent?`, `draggable=true`, `editing?`, `editText?`, `hoverIntent?`, `dropInto?`, `dropIntoIcon?`, `unread?` (a 6 pt accent dot at the right end) | `click {modifiers?}`, `doubleClick`, `close` (also middle-click), `reset` (favicon click while drifted), `mute`, `reorder`, `dropOnContent`, `rename {title}`, `renameCancel`, `pickIcon` (the icon clicked while `editing`), `hover` (see [ui.card](#uicard-popover-cards-and-hover-intent)) |
| `splitRow` | `id`, `selected` (the split is shown), `layout?`, `panes: [{id, title, icon, selected}]` (`selected` = focused pane), `closable=true`, `indent?` | `click {pane}`, `close` (hover X), `reorder` (as target, a tab row can drop `into` it), `dropOnSpace` |
| `folder` | `id`, `title`, `icon?`, `open`, `children`, `closedChildren?` (rows still shown while closed: its active tab), `style?: "group"` (a lighter rounded panel behind the header and rows, bold name: Dia's groups), `pending?` (a shimmer runs across the title; Reduce Motion dims it), `reveal?` (a one-time colour sweep across a title that just changed, 0.4 s), `editing?`, `unread?` (a 7 pt accent dot on the folder's icon), `badge?` (a quiet chip before the chevron, "3 ✓"; a button) | `toggle`, `reorder` (as target: `position: "into"`), `rename {title}`, `renameCancel`, `pickIcon` (the icon clicked while `editing`), `badge` (the chip) |
| `divider` | `id`, `action?` (label, e.g. "Clear"), `secondary?: {id, title, icon?, always?}` (a second button left of the action, shown while the divider is hovered or with `always`: Tidy), `menu?` | `clear`, the secondary's `id`, `menu` |
| `newTabRow` | `id`, `title?` | `click` |
| `commandBar` | `id`, `query`, `replaceQuery?`, `placeholder?`, `selected`, `headers?` (default true; false draws one flat list), `inputMode?: search\|go` (caret color), `banner?: {text, secondary, primary}` (the default-browser banner), `sections: [{title?, rows: [{id, icon, title, subtitle?, accessory?, keycap?, shortcut?, toggle?}]}]`. `shortcut` ("⇧⌘C") is drawn one keycap per key; `toggle` (bool) draws a switch | `input {text}`, `select {row}` (arrow keys, or hovering a row after the mouse moves), `submit {row, query, modifiers}`, `tab {query}`, `right {row, query}` (→ with the caret at the end), `back` (Backspace in an empty field), `dismiss`, `banner {button: try\|set\|close}` |
| `dialog` | `id`, `title`, `message?`, `icon?`, `iconStyle?: accent\|destructive\|plain`, `buttons: [{id, title, style: default\|cancel\|destructive\|secondary, default?, keycap?}]`, `checkbox?`, `choices?: [{id, title, subtitle?, icon?}]`, `multiple?` | `button {button, checked, choices?}`. Return presses the `default` button (or the one with `default: true`), Esc the `cancel` one, and a button whose keycap is a ⌘ chord (`⌘O`) takes that key. `choices` are rows under the message (the upload picker): one is selected (the first at the start, ↑/↓ move it) and a click presses the default button with it; with `multiple` a click ticks it. `choices` in the action lists the selected ids |
| `toast` | `text`, `icon?`, `duration?` (ms; 0 = until dismissed), `id?` (a new toast with the same id replaces it), `action?` (button label), `dismiss?` (removes the toast with that id), `hold?` (stays while the pointer is on it, then leaves 1 s after) | `ui.action {id, action: "toast"}` when the button is clicked |
| `library` | `id`, `title?`, `icon?`, `query?`, `placeholder?`, `clearTitle?` (`""` hides it), `empty?`, `sections?: [{id, title, keycap?}]`, `section?`, `items: [{id, title, url?, subtitle?, icon?, closedAt?, section?, progress?, buttons?, pill?, file?, dimmed?}]` | `input {text}`, `restore {item}`, `button {item, button}`, `section {id}`, `clear`, `dismiss` |
| `themePicker` | `id`, `anchor?`, `colors: [hex]` (≤3), `positions?: [[x, y]]`, `intensity`, `grain`, `appearance: auto\|light\|dark`, `page?` | `change {colors, positions, intensity, grain, appearance}` (live), `commit {…}`, `page {page}`, `dismiss {reason?}` |

**Details that apply to several nodes:**
- **Icons.** A node icon can be `sf:<symbol>`, an http(s) or `data:` image URL (cached), an absolute image file path (extension icons, thumbnails), `file:<path>` (Finder's icon for that file, or for its type once the file is gone: download rows), `app:icon`, `site:<domain>`, or text/emoji. In a `dialog`, an image icon draws at 62 pt like `app:icon`; only `sf:` symbols get the hero disc. `site:<domain>` draws an Arc-style letter tile: the domain's first letter ("www." skipped), white on a color derived from the domain (hash → hue), or a globe when the domain is empty (`site:`, for data:, file: and about: pages). A remote image that fails, answers non-2xx, or is Google s2's 16 px placeholder globe falls back to the `site:` tile for the domain it names (s2's `domain=`, else the image's host).
- **Context menus.** Any node can carry `menu: [item]`, shown as a native context menu. Picking an item emits `menu` with its id (submenu items included). Item shapes:
  - `{id, title, icon?, key?, alternate?, destructive?, enabled=true, checked?, items?}`. `icon` is an `sf:` symbol. `key` is a chord hint drawn on the right (`cmd+w`), display only; the real binding lives in `keys`. `alternate: true` shows the item instead of the one above it while ⌥ is held (`NSMenuItem.isAlternate`; same key, ⌥ added). `destructive` draws the title and icon in DestructiveButtonFace red (#F53714). `items` makes it a submenu ("Move to Space ▸"). `paste: true` (with `titleURL?`) is a clipboard item such as Paste and Go: it appears only while the clipboard holds one line of text, titled `titleURL` when that text is an address and `title` otherwise; the plugin reads the text with `app.pasteboard` when it's picked.
  - `{separator: true}` and `{header: "Title"}` (section header).
- **Inline rename.** `editing: true` on a `tabRow` or `folder` swaps its title for a text field holding `editText` (default: `title`), all selected and focused. Return or a click elsewhere emits `rename {title}` (trimmed; may be empty), Esc emits `renameCancel`. The plugin then sends the node without `editing`. While editing, the row's icon gets a soft rounded fill and a click on it emits `pickIcon` (the tabs plugin opens the `iconPicker` there).
- **Speaker.** A `tabRow` or `favoriteTile` with `audio` or `muted` shows a speaker (a round badge on tiles): a button with a hover fill, a tooltip ("Mute Tab" / "Unmute Tab") and a cross-fade when it flips. A click emits `mute`; the owner calls `webviews.setMuted`.
- **Drag reorder.** Dragging emits `reorder {source, target, position: before|after|into}` with a haptic tick at every change of target or zone. The middle half of a row that takes drops into it (folders, split rows for a dragged tab, and any row or tile with `dropInto: true`) means `into`, shown as a theme-tinted ring around the row with its `dropIntoIcon`; the top and bottom quarters show the insertion line. Dropping on the web content emits `dropOnContent {source, side: left|center|right}`. Dragging a tab row or folder over a footer `spaceIcon` that has a `spaceId` highlights the icon; dropping there emits `dropOnSpace {source, target, spaceId}` (from the dragged row).
- **View reuse.** Views are reused by `type` + `id`, so it's cheap to resend a whole tree on every change.

### Theme picker popover

Arc's space theme editor (spec §4), rendered in the `popover` slot:

```
ui.set {slot: "popover", tree: {type: "themePicker", id: "theme", anchor: "space-0",
        colors: ["#b98cff", "#ff9fc8"], intensity: 0.6, grain: 0.3, appearance: "auto"}}
```

- **Placement.** A 356x508 body with a 20 pt continuous radius, 13 pt right of the sidebar. Its top follows the node whose `id` is `anchor` (clamped to the window with a 10 pt margin).
- **Color pad** (340x340, dot grid at 4.25 pt). Up to 3 draggable color dots; the first is the larger primary one. Dots snap to the grid. The angle around the center picks the hue and the distance from it the saturation. Clicking an empty pad adds the first color ("Tap to pick a color for this space"). `−` / `+` remove and add colors.
- **Presets.** 9 swatches per page, 4 pages (Brand, Pastel, Drab, Greyscale, from the spec's palette). A swatch replaces the primary color. The chevrons page through them.
- **Intensity** is the wavy slider; **grain** is the dial of dots. The three buttons at the top pick automatic, light or dark appearance.
- **Live preview.** Every drag step emits `change`, whose value has the same shape as `window.setTheme` args, so the plugin can pass it straight through. `commit` follows when a drag ends or after a click.
- **Haptics.** A tick when a dot is grabbed, when it crosses each 4-dot cell, at each 10% of intensity and at each grain step.
- **Dismiss.** Esc emits `dismiss {reason: "escape"}` (the `theme` plugin reverts); a click outside emits `dismiss` with no value (it saves). The plugin clears the slot (`tree: null`).

### Panel popover

`ui.set {slot: "popover", tree: {type: "panel", id, anchor, width? (320), icon?, tone?: accent|warning|secondary, title, subtitle?, children}}`: a popover body made of ordinary nodes (the Shields panel). A header (icon, title, subtitle) over the children, 10 pt apart with 14 pt padding; children are usually `section`s of `toggleRow` / `choiceRow` / `valueRow`, plus `paragraph` and `buttonRow`. It is placed like the theme picker, next to the node `anchor`. Esc and a click outside emit `dismiss`. Theme tokens throughout (surface, text, accent, destructive for `warning`). Snapshots: `docs/screenshots/shields-panel*.png`.

### Space icon reorder

A `spaceIcon` with `reorderable: true` can be dragged along the footer strip (`SpaceIconReorder` in Rows.swift). Picking it up lifts it (scale 1.15, a haptic), it follows the pointer clamped to the strip, and the other reorderable icons glide into their new slots as it passes their midpoints (0.2 s, Dia's (0.2, 0.8, 0.2, 1) curve; Reduce Motion snaps), with a haptic tick per slot. On drop it settles into its slot and, if the slot changed, emits `move {index}` (the index among the row's reorderable icons). Nothing is emitted while dragging; the owner re-sends the tree in the new order. Arc's reorder timing was never measured, so the values are estimates (`Tokens.spaceIconLift*`, `spaceIconReorderDuration`).

### Icon picker

`iconPicker` in the `popover` slot: a 300 pt panel (20 pt continuous radius, like the theme picker) placed like it (13 pt right of the sidebar, top level with `anchor`, clamped to the window). A field takes any emoji (typed, pasted or from the Character Viewer) and picks it at once, then grids of 32 SF Symbols and 32 emoji (32 pt cells, 8 columns). "Remove" (shown when `selected` isn't empty) picks "". Esc emits `dismiss {reason: "escape"}`, a click outside `dismiss`. This is den's own design (Arc's icon editor was never measured).

### Archive / Library sheet

`ui.set {slot: "overlay.library", tree: {type: "library", id: "archive", items: tabs.archive()}}` shows the archive as a sheet over the content area (640 wide, 40 pt from the content edges, 20 pt radius, over a black α0.35 dim). Arc's archive view was never measured (spec §12), so its geometry is estimated.

- **Items** take the `tabs.archive` shape directly. Rows are grouped by the day of `closedAt` (ms since 1970): Today, Yesterday, a weekday within the last week, then "Month day". The subtitle defaults to "host · time".
- **Search** filters the items locally by title or URL on every keystroke, so it stays instant. The typed text is also emitted as `input`. Return restores the first match.
- **Restore.** Clicking a row, or its hover "Restore" button, emits `restore {item}`.
- **Sections.** With `sections`, the header shows them as tabs, each with its shortcut as a keycap ("Archive ⌘Y", "Downloads ⌥⌘L"), the `section` one selected; clicking one emits `section {id}`. The `tabs` plugin uses it for Archive and Downloads.
- **Other rows** (Downloads): an item's `section` replaces its day header ("In Progress", "Archived"); a `subtitle` may contain `{time}` (its `closedAt` as "3:41 PM"); `progress` (0–1, negative = waiting) draws a thin accent bar under the text; `buttons: [{id, icon, title}]` are round icon buttons shown on hover (their tooltips are their titles) that emit `button {item, button}`; `pill` renames the hover pill ("" hides it); `file` (a path) lets you drag the row out as that file (Finder, Mail, a page's upload field); `dimmed` fades the row (a deleted file). Rows are reused by id, so progress updates don't disturb a hovered button.
- **Clear Archive** emits `clear`. The plugin then confirms with the Clear Archive dialog below, which opens above the sheet.
- **Dismiss.** Esc, the close button or a click on the dim emits `dismiss`; the plugin clears the slot.

### Briefing page and connections sheet

`ui.set {slot: "overlay.briefing" | "overlay.connections" | "overlay.passwords" | "overlay.extensions", tree}` renders a `sheet` tree (null clears); they stack in that order. All show in `ui.get` overlays. This is den's own UI, not Arc's, so every size is an estimate in `Tokens`. Snapshots: `--scenario briefingSheet|connectionsSheet` (`docs/screenshots/briefing-sheet*.png`, `connections-sheet*.png`).

- **Root:** `{type: "sheet", id, style: page|sheet, title, subtitle?, icon?, headerButtons?: [{id, icon, tooltip?}], children}`.
  - `page` covers the content area like a new-tab page: card radius, no dim, and a centered column at most 680 wide with 40 pt top padding.
  - `sheet` is a 560-wide centered panel (20 pt radius) over a black α0.35 dim. It is as tall as its content, up to the content area minus 2×40.
- **Header:** icon, title and subtitle on the left; `headerButtons` then a close button on the right.
- **Children** stack 14 pt apart in a scroll view. Views are reused by type + id, so re-sending the tree keeps the scroll position.
- **Stacking:** connections sits above briefing, and a dialog sits above both.
- **Actions:** `{id: <sheet id>, action: dismiss}` from the close button, Esc or a click on the dim. `{id: <header button id>, action: click}`.

| Node | Fields | Actions |
|---|---|---|
| `heading` | `text`, `subtitle?` (shown above, 13 pt secondary) | – |
| `paragraph` | `text`, `style?: body\|secondary\|caption`, `icon?` (accent-tinted) | – |
| `section` | `id?`, `title`, `accessory?`, `children` | – (caption header over a rounded card, hairlines between rows) |
| `todoRow` | `id`, `title`, `subtitle?`, `icon`, `done`, `url?` | `toggle {done}` (checkbox; flips locally at once), `open` |
| `feedRow` | `id`, `title`, `subtitle?`, `icon`, `time?`, `badge?`, `unread?` | `open` |
| `actionButton` | `id`, `title`, `style: primary\|secondary\|destructive`, `keycap?` (e.g. "⌘R") | `click` |
| `buttonRow` | `children` (actionButtons), `align?: leading\|center` | – |
| `connectionRow` | `id`, `title`, `icon`, `status`, `connected`, `button: {title, style}`, `secondaryButton?: {id, title, style}` | `click`, `secondary` |
| `toggleRow` | `id`, `title`, `subtitle?`, `icon?`, `on`, `shortcut?` ("⌥⌘B", drawn one keycap per key; space-separated for several) | `toggle {on}` |
| `choiceRow` | `id`, `title`, `subtitle?`, `options: [{id, title}]`, `selected`, `shortcut?` | `select {option}` |
| `valueRow` | `id`, `title`, `subtitle?`, `icon?`, `value?`, `tone?: success\|warning\|secondary`, `shortcut?`, `buttons?: [{id, icon}]` | `click {button}` |
| `extensionRow` | `id`, `icon`, `title`, `subtitle?`, `on`, `note?` (accent caption, e.g. "Update 2.0") | `toggle {on}` (switch), `open` (row) |

### ui.card (popover cards and hover intent)

A generic floating card, placed next to a node or below a window rectangle, with Dia's measured motion (docs/reference/dia-ui-spec.md §2). The host owns only the pointer- and platform-bound parts; what a card shows, its strings and its sizes come from the plugin as a tree of [generic nodes](#generic-nodes). The `previews` plugin composes the tab card, the PR peek and link cards with it.

**Hover intent on any node.** A node with `hoverIntent: <ms>` (any node type) starts a dwell when the pointer enters it; when the dwell ends the host emits `ui.action {id: <node id>, action: "hover"}`. `tabs` puts 700 on rows and 300 on favorite tiles (Dia: 685–915 ms and 285–416 ms). Passing over quickly shows nothing and leaves no timer. While a card is up (or for 600 ms after one closed), entering another intent node swaps at once; with `swap: "dwell"` on the card (or `ui.hoverIntent {redwell: true}`) the old card stays until the new node's own dwell completes (Dia). Leaving closes the card after a 200 ms grace (Dia: 202–267 ms), so the pointer can cross onto it; the card stays while the pointer is on it. Clicking the node closes its card until the pointer leaves it.

`ui.card {id, tree | null, anchor?, rect?, place?, width?, gap?, swap?, graceMs?}` → `{shown}`

| Arg | Meaning |
|---|---|
| `id` | the card's id (a plugin can show several: `previews.tab`, `previews.link`) |
| `tree` | a generic node tree; `null` closes the card |
| `anchor` | the hovered node's id. The card belongs to that node's hover intent: a tree for a node that isn't the hovered one is dropped (`shown: false`) |
| `rect` | `{x, y, w, h}` in window points, top-left origin (e.g. from `webviews.linkHover`). A free card: it closes when the plugin sets `null`, after `graceMs` (200) and never while the pointer is on it |
| `place` | `trailing` (default for `anchor`): x = max(node maxX, sidebar edge) + `gap` (3), vertically centred on the node. `tile`: below-right of a tile, x = maxX − 3, y = maxY − 3. `below` (default for `rect`): left-aligned, `gap` (8) below, flipped above when there's no room. Always kept 8 pt inside the window |
| `width` | a number, or `{min, max}` around the tree's natural width (default 170–200, Dia's clamp) |
| `swap` | `instant` (default) or `dwell` |

- **Motion.** In: opacity 0→1 and scale 0.93→1 from the top-leading corner over 180 ms. Out: opacity →0 and scale →0.93 toward the same corner over 100 ms. A new tree for a card that is showing is a hard cut: content and frame change in one frame. Reduce Motion turns the animations off.
- **Look.** Dia's neutral card from the theme tokens (`ThemeTokens.card`, below): 12 pt continuous radius, a 0.5 pt hairline (light: plus a 1 pt white inner highlight), a soft even shadow (8 pt blur, no offset).
- **Tooltips.** An `action` node's `tooltip` shows as Dia's chip 3 pt below the button (28 pt tall, 12 pt text) after 0.5 s, then instantly while moving between buttons. With a `shortcut`, the chip shows it ("Pin Tab  ⌘D").
- **Card shortcuts.** While a card with `shortcut` buttons shows, a local key monitor runs those chords on the card (the hovered tab, the hovered link) before the menu bar sees them. The monitor exists only while such a card is up.
- **Closing.** Mouse-out after the grace, anything modal (`overlay.*`, `dialog`, `popover`), `null`, or the plugin after an action. Each close emits `ui.action {id: <card id>, action: "close", value: {anchor}}`.
- **Cost.** Nothing runs until a dwell starts: no timers, views, events or key monitor. The host logs intent-to-visible time (`os_log` category `card`, `CardController.lastShownMs`); the `--scenario` preview snapshots print it.

`ThemeTokens.card`: `fill` (dark #262626, light #F4F4F4, tinted at most 6% toward the space's colors), `text`, `secondary`, `glyph` (contrast-checked: 7:1, 4.5:1, 3:1), `border`, `highlight` (light only), `hover` (dark #373737), `tooltip`/`onTooltip` (#474747 / #E4E4E4), `success`/`warning`/`danger`/`track` (the CI bar), `addText`/`delText`, `dangerSoft`/`onDangerSoft` (failing-check rows), `strong`/`onStrong` and `destructive`/`onDestructive` (pill buttons).

### Generic nodes

Feature-free nodes any plugin can compose (Toolkit/CardNodes.swift). Colors are tones resolved from the theme tokens, never hex in the tree: `primary`, `secondary`, `glyph`, `success`, `warning`, `danger`, `add`, `del`, `accent`.

| Node | Fields | Actions |
|---|---|---|
| `stack` | `axis: v\|h`, `spacing`, `padding` (n or [top, right, bottom, left]), `distribute: fill\|equal`, `align: start\|center\|end`, `height?` (h), `fill?: panel\|card\|hover` (a surface behind it: the selected-tab fill, the card fill, the card hover fill) with `radius?` (8), `clickable?` (with an `id`: a hover tint and `click {value}` for clicks no child button takes), `children` | `click {value}` when `clickable` |
| `label` | `text` or `runs: [{text, tone?, weight?}]`, `size` (13), `weight`, `tone`, `lines` (1; more wrap and end in "…"), `lineHeight?`, `align` | – |
| `icon` | `spec` (sf:/URL/path/emoji), `size`, `tone`, `letter?` | – |
| `image` | `src` (URL or path), `width?`, `height?`, `aspect?`, `radius?`, `placeholder?`, `version?` | – |
| `badge` | `text`, `tone`, `icon?` | – |
| `meter` | `segments: [{value, tone}]`, `total?`, `height` (6): a capsule, segments left to right over the track | – |
| `note` | `text`, `tone` (danger), `id?`, `value?`: a tinted 22 pt row with a 3 pt leading bar | `click {value}` |
| `item` | `id`, `title`, `subtitle?`, `icon?`, `accessory?`, `tone?`, `value?` | `click {value}` |
| `action` | `id`, `icon?`, `title?`, `variant: icon\|pill`, `tone: default\|primary\|strong\|destructive`, `tooltip?`, `shortcut?`, `enabled?`, `menu?` (opens on click), `width?`, `value?` | `click {value}`, `menu {item id}` |

Actions arrive as `ui.action {id: <tree id>, action, value}`. Snapshots: `--scenario previewGitHub|previewCalendar|previewPage|previewFolder` (`docs/screenshots/preview-*.png`).

### Dialogs

Every variant uses Arc's quit-sheet layout (spec §5): 450 wide, 26.5 pt continuous radius, #151C30 / #FAFBFF body over a black α0.55 dim, icon at (38, 38), title in SF 18 medium. The buttons sit 27.5 pt from the sides and bottom, 38 tall. `cancel` and `default` buttons pack to the right 7 pt apart, and a leading `secondary` button sits on the left. Each button shows its key as a keycap (`ESC`, `↩`).

- **Keys** (`ModalFocus`, Toolkit/ModalFocus.swift, a generic primitive). Every dialog, sheet, popover, the Library, the command bar and a page's own dialogs take key focus when shown and give it back to what had it (usually the page's text field) when they close. A page can call `element.focus()` at any time (Google's sign-in does right after a submit), which makes WebKit re-take first responder for its WKWebView; so every key-down in a den window (`DenNSWindow`, `DenNSPanel`: `sendEvent` and `performKeyEquivalent`) first moves focus back into the top surface. Esc presses the `cancel` button, or the only button of a one-button dialog (a page's `alert()`); Return the default. `ModalKeysTests` sends real key events through the window's `sendEvent` with a focused page field as first responder.
- **Elevation** (`Elevation`, Toolkit/Elevation.swift, a generic style every `PanelView` has). A layered shadow in PopoverShadow #151C32 (α0.30 light, α0.80 dark; spec §3): a wide ambient one (30 pt radius, 18 pt down, 1.6× α capped at 1: 0.48 light, 1.0 dark) and a tight key one near the edge (3 pt, 1.5 pt down, 0.8× α); a 1 pt light rim along the top edge fading out a third of the way down (token `rim`), and a 0.5 pt edge (token `edge`). Lower levels: `bar` (command bar), `popover` (theme / icon pickers, extensions menu), `card` (hover cards, `page` sheets). Radii and offsets are estimates tuned on snapshots (Arc's aren't readable, spec §12).
- **Backdrop** (`ModalBackdrop`). The α0.55 dim sits over a blurred picture of what's behind: one snapshot when the dialog opens (the visible web views via `takeSnapshot` at ¼ size, den's chrome via `cacheDisplay` with the overlays hidden, all at ¼ scale, Core Image Gaussian blur of 2 px ≈ 8 pt, off the main thread). The dim shows at once; the blur fades in when ready (the spring runs in the render server, so the capture doesn't stall it). Measured 2026-09-28 with `DEN_TRACE=1` (`elevation.blur` lines; `os_log` category `elevation`), debug build, 1280×820 window, one loaded page, load average ≈ 70 from other builds: 25–38 ms on the main thread (`cacheDisplay` at ¼ scale), 72–114 ms from open to blur shown; the image is 320×205 px (≈ 262 KB). It costs nothing while the dialog is up; a live vibrancy view would re-blur on every frame of a video behind it and doesn't show in `--snapshot` PNGs.
- **Motion.** In: scale 0.96 → 1 on a spring (`CASpringAnimation`, perceptual duration 0.18 s, bounce 0.12) with a 0.15 s fade; the backdrop fades with it. Out: 0.12 s ease-in fade to 0.98. Reduce Motion: none. Arc's dialog entrance was never captured (spec §7), so this is den's choice.
- Snapshots (before / after): `docs/screenshots/elevation-*.png`; `--scenario dialogQuitSandy` (a sandy, grainy space) and `dialogPassword` (the save-password dialog) join the variants below.

- **Icons.** `app:icon` draws the app icon at 62 pt. Any other icon (`sf:trash`) becomes a 76 pt hero icon: the symbol on a disc tinted by `iconStyle`.
- **Button styles.** `default` is BrandBlue #3139FB. `destructive` is #F53714 (hover #DD3112, pressed #D02F11). `secondary` and `cancel` are (48,47,99) with a (99,98,174) border in dark mode.
- **Variants** (see `--scenario dialogQuit|dialogDeleteSpace|dialogDeleteFolder|dialogClearArchive`, text in `HostScenarios.dialogs`):

| Variant | Tree |
|---|---|
| Quit | `icon: "app:icon"`, buttons secondary "Quit, and don’t ask again", cancel, default "Quit" |
| Delete space | `icon: "sf:trash"`, `iconStyle: "destructive"`, message, buttons cancel + `{style: "destructive", default: true}` |
| Delete folder | same, `icon: "sf:folder.badge.minus"` |
| Clear Archive | same, `icon: "sf:archivebox"` |

Arc has no close-window confirmation (spec §5: Shift-Cmd-W closes a window with tabs silently), so den has none either.

## Theming

Every den surface takes its colors from one token layer, derived from the current space's theme (colors, intensity, grain), the effective appearance (light, dark, or auto following macOS) and, optionally, the macOS accent color. No surface hardcodes a white card or a fixed brand blue. The code: `ThemeTokens` (Sources/DenHost/Core/ThemeTokens.swift, AppKit-free) wrapped by `Palette` (Toolkit/Primitives.swift).

| Token (`Palette`) | Use | Derivation |
|---|---|---|
| `surface` (= `popover`, `panel`) | dialogs, command bar, popovers, sheets, hover cards, Settings pane | Arc's PopoverBackground (#FAFBFF / #151C30, spec §3) pulled toward the space's colors by intensity. Light surfaces stay at relative luminance ≥ 0.72, dark ones ≤ 0.035 |
| `elevatedSurface` | a layer on a surface: sheet cards, the command bar banner | light: surface → white 55%; dark: surface → white 7% |
| `textPrimary` / `textSecondary` / `textTertiary` (= `panelText`, `panelSecondaryText`) | text on a surface | ForegroundPrimary/Secondary/Tertiary composited on the surface, then pushed to ≥ 7:1 / 4.5:1 / 3:1 |
| `text` / `secondaryText` | text on the sidebar (the window gradient) | checked against every gradient stop: ≥ 4.5:1 / 3:1 |
| `primaryButton` (= `accentStrong`), `onAccent` | primary buttons, selection, focus, toggles, drop zones | the space's first color at saturation ≥ 0.55 (or the system accent), adjusted so its label is ≥ 4.5:1, then moved toward 3:1 against the surface as far as the label allows (a white-labelled accent can’t reach 3:1 on a near-black surface; Arc’s own #3139FB on #151C30 is 2.5:1) |
| `destructive`, `onDestructive` | destructive buttons | DestructiveButtonFace #F53714, darkened just enough for a white label (4.5:1) |
| `toast`, `onToast` | toasts | a deep blend of the theme (Arc's theme-tinted toasts, spec §6), white text ≥ 4.5:1 |
| `hairline`, `rowHover`, `pressed` | dividers, hover and pressed fills | ink/white at α .08/.05/.09 (light) or .10/.07/.12 (dark) |
| `shadowColor`, `shadowOpacity` | small shadows (toasts, find bar) | PopoverShadow #151C32 α0.30 (light), black α0.60 (dark) |
| `tokens.elevationShadow`, `edge`, `rim` | elevated surfaces (`Elevation`) | PopoverShadow #151C32 α0.30 / α0.80 exactly (spec §3); edge #151C32 α0.10 / white α0.12; rim white α0.85 / α0.16 |
| `dialogDim`, `sheetDim` | backdrops | black α0.55 (spec §3) / α0.35 |
| `tokens.grain` | grain on surfaces (`SurfaceGrain`) | half the window's grain, the same noise tile |

- **Contrast.** WCAG 2.x relative luminance; targets are AAA (7:1) for primary text, AA (4.5:1) for secondary text and button labels, 3:1 for tertiary text and UI components. `ThemeTokens.ensure(color, on:, target)` moves a color toward black or white until it meets the target, so very light (white, pastel, yellow) and very dark (near-black) themes stay legible. `ThemeTokenTests` checks every token pair for sandy, deep purple, near-black, pastel, white, yellow and no theme, in light and dark.
- **Accent.** Settings > General > Accent color: "Space colors" (default, Arc) or "System accent" (`Palette.accentSource`, stored as `settings` id `general`, key `accent`). A change of the macOS accent re-themes live while it's in use.
- **Live and cheap.** Tokens are computed once per (theme, appearance, accent) and cached. `UIService.refreshPalette()` rebuilds the palette on a theme change or space switch and re-applies it (`Themable.apply`, recursively over the sidebar and `wc.overlays`, plus the hover card and the Settings window) only when the tokens changed; identical themes redraw nothing.
- **Adopting it.** A surface view conforms to `Themable` and reads colors in `apply(_ p: Palette)`: backgrounds from `p.surface` / `p.elevatedSurface`, text from `p.textPrimary`/`textSecondary`/`textTertiary`, primary actions `p.primaryButton` + `p.onAccent`, destructive `p.destructive` + `p.onDestructive`, dividers `p.hairline`, shadows `p.shadowColor`. Views added under `wc.overlays` (or `PanelView` subclasses) are re-themed automatically. For a colored fill with custom text, call `ThemeTokens.ensure(text, on: fill, ThemeTokens.bodyContrast)`. For an HTML surface (error pages), inject `p.tokens.surface.hex`, `textPrimary.hex` and `accent.hex` as CSS variables.
- Native menus follow the window's appearance (light/dark); AppKit doesn't let them take theme colors.
- Snapshot: `docs/screenshots/theming-grid-dark.png` (scenario `themeSample`, see scripts/snapshots.sh).

## downloads

Files pages hand over, with WebKit's `WKDownload` (`DownloadsService.swift`). The host keeps only the native half: the downloads, their files, progress and a small persisted list (storage ns `downloads`, key `items`, at most 300). The Library screen, the sidebar indicator, the toasts and when old downloads are archived belong to the `tabs` and `spaces` plugins ([plugin-services.md](plugin-services.md#tabs-plugin-tabs)). Nothing is read or observed until the first download or a `list` call.

- **What downloads.** A main-frame response WebKit can't show (`canShowMIMEType` false: a zip, a dmg), any response with `Content-Disposition: attachment`, and `<a download>` links. A hidden frame's un-showable response doesn't. The page stays where it was. "Save Link As…" / "Save Image As…" in the page menu go through the same list, with a save panel for the destination.
- **Where.** `~/Downloads`, under the server's name made safe (no `/` or `:`, no leading dot), and Finder's "name 2.ext" when taken. The file is written in place while it downloads, and marked as downloaded from the internet (quarantine, like Safari's), so Gatekeeper checks it on first open.
- **Pause and resume.** Pause cancels the transfer with WebKit's resume data (kept, and persisted, so a paused download survives a relaunch); Resume carries on with `resumeDownload(fromResumeData:)`, which asks the server for the rest (a `Range` request). Without resume data it starts again. A download that was running when den quit comes back as "failed · Interrupted" with Retry. Cancel stops it and deletes the partial file.
- **Cost.** A `downloads.changed` event at most 4 times a second while bytes arrive; nothing otherwise. A private web view is created only to resume or retry when no page is open, and released when nothing is running.

| Method | Args | Returns |
|---|---|---|
| `list` | – | `{items: [item], active, unseen, progress, count}`, newest first |
| `summary` | – | `{active, unseen, progress, count}`. Never reads the stored list |
| `get` | `id` | item |
| `pause`, `resume`, `retry`, `cancel` | `id` | ok, or an error ("isn't running", "no web view") |
| `open` | `id?` | ok. Opens the file with its app; without `id`, emits `downloads.show` (the command bar's Downloads destination) |
| `reveal` | `id` | ok. Shows the file in Finder (an error when it was moved or deleted) |
| `remove` | `id` | ok. Off the list; the file stays |
| `clear` | – | `{removed}`. Everything not running leaves the list |
| `archive` | `before` (ms since 1970) | `{archived}`. Finished downloads that ended before it are marked `archived` |
| `seen` | – | ok. Nothing finished counts as new any more |
| `start` | `url`, `webview?`, `ask?` | `{id}`. Downloads a URL with that page's session; `ask` shows a save panel |

item: `{id, url, name, path, state: downloading|paused|done|failed|cancelled, received, total (-1 unknown), rate (bytes/s, while downloading), started, finished?, error?, archived, exists, unseen?}`.

Events: `downloads.changed {active, unseen, progress, count}`, `downloads.started {id, name, webview}`, `downloads.finished {id, name, ok, error?}`, `downloads.show`.

Tests: `DownloadsTests` (real downloads from a local server: a zip, `<a download>`, pause and resume through a server that holds the connection, cancel, the quarantine flag). Scenario: `--scenario downloads` (`docs/screenshots/downloads*.png`).

## settings

The Settings window (⌘,, "Settings…" in the den menu). Plugins contribute sections as typed controls; the host persists values per plugin and emits changes, so plugins react live. The window and its panes are built the first time Settings opens; until then, registering a section only stores it.

| Method | Args | Returns |
|---|---|---|
| `register` | `id`, `title`, `icon?`, `section?`, `order?`, `controls: [control]` | ok. Replaces an earlier registration. With `section`, the controls join that section as a group titled `title`; otherwise `id` is a sidebar section |
| `unregister` | `id` | ok |
| `list` | – | `[{id, title, icon, order, schema: [{key: "<id>.<key>", title, type, value, options?, keywords?}]}]`: the sidebar, each section with every titled control of its groups and its current value (the command bar searches and flips these) |
| `get` | `id`, `key?` | the stored values over the controls' defaults (`{key: value}`), or one value |
| `set` | `id`, `key`, `value` (or no `id` and a dotted `key: "<id>.<key>"`, as `list` gives it) | ok. Stores (storage ns `id`, key `prefs`) and emits `settings.changed` when the value changed |
| `open` | `section?` (or `id`, and `key?` a dotted setting key whose section opens) | ok. Shows the window at that section |
| `close`, `state` | – | ok / `{open, section}` |

Events: `settings.changed {id, key, value}`; `settings.action {id, key, item?, button?, value?}` (list and button rows, and `submit` text fields); `settings.opened {section}`.

Controls are `{key, type, title, subtitle?, default?}`:

| `type` | Extra fields | Control |
|---|---|---|
| `toggle` | – | a switch (Bool) |
| `choice` | `options: [{value, title}]` | a pop-up menu (any value) |
| `text` | `placeholder?`, `submit?` | a text field. Normally the value is set when editing ends; with `submit: true` Return emits `settings.action {value}` and clears the field (an "add" field) |
| `shortcut` | – | a shortcut recorder: click, press a chord (Esc cancels, Delete clears). The value is a `keys` chord (`cmd+shift+b`) |
| `number` | `min`, `max`, `step?`, `unit?`, `labels?: [{value, title}]` | a slider with its value ("30 min", or a label such as "Never" for 0). Set when the drag ends |
| `list` | `items: [{id, title, subtitle?, icon?, buttons?: [{id, title, style?}]}]`, `empty?` | plugin-provided rows, e.g. connections. Buttons emit `settings.action {item, button}`; re-`register` to update the rows |
| `button` | `button: {title, style?}` | a row with one button (`settings.action`) |
| `info` | `value`, `buttons?: [{id, title}]` | read-only text, e.g. a path, with buttons |

`style` is `primary`, `destructive` or plain. The window: a 196 pt sidebar of sections (icon + title; the selected one like a selected tab) on a tint of the space's background, and a pane of rounded cards with hairlines between rows, native controls on the right. It follows the theme tokens and re-themes live. It's den's own design (Arc's Settings window was never measured; spec §11 has its copy).

Sections today:
- **General** (host): accent color, default browser (status + "Make den Default"), `config.toml` and `~/.den` with Open / Show in Finder (a missing `config.toml` is created with commented examples on Open), and problems found in them; plus **Quitting** from `quit` ("Ask before quitting").
- **Tabs** (`tabs`): archive Today tabs after (Never … 30 days), unload idle tabs (0–240 min slider); plus **Links** from `peek` (peek at links from pinned tabs, "Open links from other apps in a mini window", archive unused mini windows).
- **Search** (`commandbar`): search engine, site-search keywords (remove), add a keyword (`kw [Name] url-with-%s`), the default-browser banner.
- **Connections** (`connections`): each provider with Connect / Cancel / Workspaces… / Disconnect.
- **Reading** (`pagetools`): reader font, text size and read-aloud speed, sites that always open in Reader, where captures go, and zapped sites (see [plugin-services.md](plugin-services.md#pagetools-plugin-pagetools)).
- **Briefing** (`briefing`): morning briefing on/off, its time, the shortcut that opens it.

Snapshots: `--scenario settings` / `settingsTabs` / `settingsSearch` / `settingsConnections` / `settingsBriefing` (`docs/screenshots/settings-*.png`). Every default and why: [defaults.md](defaults.md).

## keys

| Method | Args | Returns |
|---|---|---|
| `bind` | `chord` (e.g. `cmd+shift+k`, `ctrl+1`, `cmd+opt+left`), `event`, `title?`, `menu?` (File/Edit/View/History/Tabs/Spaces/Window/any; default Tabs), `payload?` | ok. Emits `event {chord, payload}` |
| `unbind` | `chord` | ok |
| `list` | – | `[{chord, event, title, menu, payload}]` |
| `remap` | `chord`, `item` (a `MainMenu` item id, [shortcuts.md](shortcuts.md)) | ok. Gives that menu item a new shortcut; it survives a plugin rebinding the slot |
| `resetRemaps` | – | ok. Restores every remapped item's own shortcut |

Chords are bound as main-menu items. That way they work while a web page has focus, and the standard Edit and Window shortcuts keep working.

## storage

| Method | Args | Returns |
|---|---|---|
| `get` | `ns`, `key` | value or null |
| `set` | `ns`, `key`, `value` | ok |
| `delete` | `ns`, `key` | ok |
| `keys` | `ns` | `[string]` |
| `clear` | `ns` | ok |

- Each namespace (plugin id) is one `Codec`-encoded file at `~/Library/Application Support/den/storage/<ns>.cvalue`.
- Writes are atomic.

## updates

The native half of updating. All policy lives in the `updates` plugin ([updates.md](updates.md)).

| Method | Args | Returns |
|---|---|---|
| `info` | – | `{version, build, commit, hostAPI, builtAt, crashed: [id], sparkle, publicKey, onDiskCommit}` (`onDiskCommit`: the build on disk, which may be an installed update not yet running) |
| `state` | – | the follow-main updater's `~/.den/updates/state.json`, or null |
| `fetch` | `url` (https), `etag?`, `json?` | `{pending}`. Emits `updates.fetched {url, status, etag, body, value?, bytes, error}` (304 when the ETag matches) |
| `plugins` | – | `[{id, file, layer, sha256}]` for the loaded plugins |
| `installPlugin` | `id, url, sha256, signature, version, hostAPI, permissions?` | `{pending}`. Verifies sha256 + EdDSA (`SUPublicEDKey`), places the file in `~/.den/updates/plugins` (keeping `.prev`) and loads it. Emits `updates.pluginInstalled {id, ok, active, error?}` |
| `rollbackPlugin` | `id` | `{ok, restored}` |
| `kickUpdater` | – | ok. Runs the follow-main LaunchAgent now |
| `sparkleConfigure` / `sparkleCheck` / `sparkleReply` | `channel` / `userInitiated?` / `choice: install\|later\|skip` | ok |

Events: `updates.stateChanged {state}`, `updates.fetched`, `updates.pluginInstalled`, `updates.sparkle {phase: checking|none|found|downloading|ready|installing|error, version?, error?}`.

## config

`~/.den/config.toml` and `~/.den/themes` ([den-home.md](den-home.md)). Nothing is read until after the first window, so a call during launch gets the empty config, and the real one arrives with the events.

| Method | Args | Returns |
|---|---|---|
| `get` | `key?` (dotted, e.g. `plugins.disabled`) | the whole config object, or the value at `key`, or null |
| `themes` | – | `[{name, colors, intensity?, grain?, appearance?, file}]`, sorted by name |
| `paths` | – | `{root, plugins, themes, config, logs}` |
| `errors` | – | `[string]`: problems in config.toml and the theme files, as of the last read |

Events: `config.changed {config}`, `config.themesChanged {themes}`.

## plugins

Lets a plugin hide features whose provider isn't loaded.

| Method | Args | Returns |
|---|---|---|
| `get` | – | `{services: [name], plugins: [{id, active}]}` |
| `listening` | `event` | `{listening}`: true when the host or any plugin listens to `event` |

## app

| Method | Args | Returns |
|---|---|---|
| `interceptQuit` | `enabled` | ok. Cmd-Q then emits `app.quitRequested`, and quitting waits for `quit` |
| `quit` | `confirm=true` | ok |
| `interceptClose` | `enabled` | ok. Closing the window then emits `app.closeRequested` |
| `closeWindow` | – | ok |
| `pendingURLs` | – | `[url]` opened before any listener existed |
| `setDefaultBrowser` | `bundleId?` | ok. Asks macOS to make den (or the app `bundleId`) the default for http and https; macOS shows its own confirmation. Emits `app.defaultBrowser {scheme, error}` |
| `defaultBrowser` | – | `{bundleId, name, isDefault}`: the app that opens https links now |
| `info` | – | `{bundleId, version, launchMs}` |
| `copy` | `text` | ok. Puts the text on the general pasteboard. The plugin's toast says what was copied (`Copied` in `Plugins/Shared/Env.swift`: "Copied link · example.com/path…") |
| `state` | – | `{active, idleSeconds, keyIdleSeconds, battery, lowPower}`: whether den is frontmost, the time since any input or a key press, whether the Mac runs on battery, and Low Power Mode |
| `relaunch` | `background?` | ok. Quits cleanly (no quit dialog) and starts den again. With `background`, it doesn't take focus |
| `setAbout` | `credits` | ok. Text for the About panel |
| `showAbout` | – | ok. Shows the About panel (the command bar's "About den") |
| `paths` | – | `{home, downloads, pictures, desktop}` |
| `chooseFolder` | `request?`, `message?`, `prompt?` | `{pending}`. An open panel (a sheet on den's window); emits `app.folder {request, path}` (`""` when cancelled) |
| `pasteboard` | – | `{text, url}` when the clipboard holds one line of text (≤ 2,048 characters, trimmed); `url` is whether it opens as an address (the command bar's rule). `{}` otherwise. Read only when called |
| `share` | `url`, `title?`, `anchor?` (a node id) | ok. macOS's share picker (`NSSharingServicePicker`: AirDrop, Messages, Mail, Notes…) for the URL, beside that node (e.g. the URL pill `tabs.url`, a tab row), else at the top of the page |
| `qrCode` | `text` | `{path, modules}`. A QR code PNG (CoreImage `CIQRCodeGenerator`, correction M): black modules on white, a 4-module quiet zone, at least 8 px a module and about 512 px in all, drawn without interpolation so edges stay sharp. Written to a per-process temporary folder, one file per text |
| `copyImage` | `path` | ok. The image on the clipboard (PNG and TIFF) |
| `saveFile` | `path`, `name?`, `request?` | `{pending}`. A save panel (a sheet on den's window), then a copy of the file; emits `app.saved {request, path}` (`""` when cancelled) |

Events: `app.quitRequested`, `app.closeRequested`, `app.openURL {urls}`, `app.defaultBrowser`, `app.folder`, `app.saved`, `app.active {active}` (den became or stopped being the frontmost app), `app.power {battery, lowPower}` (the power source or Low Power Mode changed; IOKit's power-source notification and `NSProcessInfoPowerStateDidChange`, no polling).

**Clipboard and sharing cost nothing until used** (`AppShare.swift`): no pasteboard reads at launch or while idle (a `paste` menu item reads it when its menu opens), and the share picker, QR image and save panel are made on demand.

**Non-US keyboards** (`KeyLayoutFallback`). Key equivalents match the character a key types. A ⌘/⌃ key whose character matches no menu item, and that is either not ASCII (Cyrillic, Greek, é) or ASCII punctuation where a US keyboard has a digit or symbol (AZERTY's number row, a dead key), runs the menu item at that key's US position instead: ⌃& on AZERTY is ⌃1, ⌘ц on a Russian layout is ⌘W. A Latin letter or digit typed as itself never falls back (Dvorak, QWERTZ). One dictionary lookup per ⌘/⌃ key press.

## speech

Text to speech with the system voices (`AVSpeechSynthesizer`), on device. One queue at a time. The synthesizer exists only while something is being read.

| Method | Args | Returns |
|---|---|---|
| `speak` | `utterances: [string]`, `lang?` (BCP 47; picks the system voice), `rate?` (1 = normal, 0.5–2.5), `volume?` (0–1), `from?` (index), `request?` | `{request}`. Replaces the current queue |
| `pause`, `resume`, `stop` | – | ok |
| `setRate` | `rate` | ok. Restarts at the current utterance |
| `state` | – | `{request, state, index, count, rate}` |

Events: `speech.progress {request, index, count}` as each utterance starts (a reader highlights that sentence), `speech.state {request, state: playing|paused|stopped|done, index, count, rate}`.

## translate

Language detection (NaturalLanguage) and translation (Apple's Translation framework), both on device: text in, text out, no network.

| Method | Args | Returns |
|---|---|---|
| `detect` | `text`, `hint?` (e.g. the page's `lang`) | `{lang, confidence, name}`: a base code (`fr`) and its name in the user's language (`French`); `lang: ""` when unsure. Falls back to `hint` for short text |
| `userLanguage` | – | `{lang}`, from the first preferred language |
| `availability` | `from`, `to?`, `request?` | `{request}`, then `translate.availability {request, from, to, status: installed\|supported\|unsupported}` |
| `run` | `texts: [string]`, `from`, `to?` (default: the user's), `request?` | `{request}`, then `translate.result {request, ok, texts, from, to, ms}` or `{…, ok: false, error, needsDownload}`. Empty strings stay empty; order is kept |

A session per language pair is kept while den runs. `supported` means the model isn't downloaded: `run` then shows macOS's own download prompt (a hidden SwiftUI `translationTask` view in den's window) and continues once it's installed; declining ends with `error: "notInstalled"`. `unsupported` pairs end with `error: "unsupported"`. On this Mac (macOS 26.5, en-GB), French, Japanese, German and Spanish to English all report `installed`, and translate with no network.

## suggest

Web search autocomplete (Google's public suggest endpoint, `client=firefox`) for the command bar.

| Method | Args | Returns |
|---|---|---|
| `query` | `q` | `{q, items}` at once when cached (no network, no event); otherwise `{q, pending: true}`, then `suggest.results {q, items}` |
| `cancel` | – | ok. Drops the pending query |

A pending query is debounced (50 ms) and cancels the one before it, so only the latest query emits; late answers for older queries are still cached. `q` is normalized (trimmed, lowercased, spaces collapsed). The cache is in memory (256 queries). A failed fetch emits `items: []` and isn't cached.

Events: `suggest.results {q, items}`.

## pagestyle

Per-site user stylesheets and appearance for every web view (the `darkmode` plugin's host half). The host applies; the plugin owns the CSS and the choices. Nothing is installed until the first `rules`.

| Method | Args | Returns |
|---|---|---|
| `define` | `name`, `css` (≤ 64 KB) | ok. A named user stylesheet: user origin, main frame only. Redefining updates live pages |
| `rules` | `default: {sheets: [name], appearance?}`, `hosts: {<host>: {sheets, appearance?}}`, `detect?` | ok. `appearance`: `light`, `dark`, or absent (follow den's window). Applied to live pages at once |
| `get` | `id` | `{host, sheets, appearance, tone, supported}` |

Events: `pagestyle.tone {id, host, tone: dark|light, dark}` (`dark`: the page's `prefers-color-scheme` when it measured).

- Sheets are WebKit user stylesheets (`_WKUserStyleSheet`, WebKit SPI present since macOS 10.12): no script, no `<style>` element. They are added and removed on a live page without a reload.
- A rule is picked on each main-frame navigation decision, before the new document exists, so a sheet applies from the first paint (no white flash). The lookup tries the host, then each parent domain, then `default`, ignoring `www.`.
- Web views inherit den's window appearance, so `prefers-color-scheme` matches den unless a rule sets `appearance` for that site.
- `detect` adds one WKUserScript in the isolated `den-style` world. It sets `data-den-tone` on `<html>` from the first opaque background under the viewport center (then the body, then the text color), at the first frame, DOMContentLoaded, load and 1 s later.
- Apple Pay: WebKit removed the "no Apple Pay with injected scripts" rule in 2022 (WebKit commit `aa041a623c`, bug 236254), so neither the sheet nor the detector disables it. Details: [research/dark-mode.md](research/dark-mode.md).

## sitepolicy

Per-site web policy for every web view (the `shields` plugin's host half, [plugin-services.md](plugin-services.md#shields-plugin-shields)). Generic like `pagestyle`: the host applies, the plugin owns the lists, the strings and the choices. Nothing exists until the first call.

| Method | Args | Returns |
|---|---|---|
| `load` | `name`, `file` (absolute, or relative to a plugin's resources with `plugin`), `version` | `{pending}` or `{ready}`. A WebKit content rule list (JSON, or `.lzfse`-compressed JSON) under the identifier `name@version` |
| `define` | `name`, `json` (≤ 256 KB) | the same, for a small inline list (the version is a hash of the JSON) |
| `list` | – | `[{name, id, ready, cached, ms, error?}]` |
| `rules` | `default: {lists, autoplay?, popups?}`, `hosts: {<host>: {…}}` | ok. `autoplay`: `allow`, `sound` (only muted autoplay) or `none`; `popups`: `allow` or `block`. Looked up like `pagestyle` (host, parent domains, `default`; no `www.`) |
| `https` | `enabled`, `allow: [host]` | ok. HTTPS-first for main-frame http navigations, except `allow` and local hosts (loopback, private addresses, `.local`, `.test`, single-label names) |
| `guard` | `service`, `method` (`""` turns it off) | ok. See below |
| `get` | `id` | `{host, url, lists, active, blocked, blockedByList, blockedCounts, rewrites: [{kind, from, to}], upgraded, connection: secure\|mixed\|insecure\|local, httpAllowed, autoplay, popups, interstitial}` for the page now in that web view |
| `interstitial` | `id`, `url`, `page: {kind, icon: lock\|warn\|shield\|…, title, message, detail?, url?, buttons: [{id, title, style: primary\|secondary, key?: return\|escape}]}` | ok. A full-page warning in den's error-page look (the space's palette), loaded for `url` |
| `forget` | `host`, `profile?` | `{pending}`, then `sitepolicy.forgotten {host, removed}`. Removes every website data record (cookies, storage, caches, service workers…) of the host's registrable domain, and its camera/microphone answers |
| `permissions` / `resetPermissions` | `host` | `[{origin, kind: camera\|microphone, allowed}]` / ok |
| `unsaved` | `id`, `request?` | `{request}`, then `sitepolicy.unsaved {request, id, unsaved}`: edited form fields, or text in a focused editor, in the main frame |
| `support` | – | `{autoplay, popups, blockedCounts}`: which WebKit SPI is present |

Events: `sitepolicy.loaded {name, ok, cached, ms, error?}`, `sitepolicy.changed {id}` (blocked counts moved; at most every 250 ms per page, only while someone listens), `sitepolicy.rewritten {id, kind, from, to}`, `sitepolicy.httpsUnavailable {id, url, error, code}`, `sitepolicy.interstitialAction {id, action, url}`, `sitepolicy.forgotten`, `sitepolicy.unsaved`.

- **Rule lists.** Compiled once into den's own store (`~/Library/Application Support/den/ContentRules`; `<storage>/contentrules` for any other `--storage`), looked up by identifier on later launches (a lookup, not a compile), older versions of the same name deleted. The rules file is read and decompressed off the main thread, and only when this version was never compiled. A web view gets the lists of its site's rule when it is created and at every main-frame navigation decision, so the first load is already filtered. WebKit caps a list at 150,000 rules and applies `ignore-previous-rules` only inside its own list.
- **Blocked counts** come from WebKit's `_webView:contentRuleListWithIdentifier:performedAction:forURL:` navigation-delegate SPI, which reports each load a list blocked. They are real counts per page, reset when a new page commits. If WebKit ever stops calling it, `blockedCounts` stays true but the numbers stay 0; `support.blockedCounts` reports whether the SPI class exists.
- **Autoplay and pop-ups** are set per navigation with `WKWebpagePreferences`' `_autoplayPolicy` / `_popUpPolicy` SPI (checked with `responds(to:)`; `support` says whether they exist). Without them WebKit's defaults apply (pop-ups only from a click).
- **HTTPS-first** uses the public `preferredHTTPSNavigationPolicy = .errorOnFailure` (macOS 15.2+): WebKit tries `https://`, and when that fails for a reason other than being offline, den emits `httpsUnavailable` so the plugin can show its interstitial (WebKit's own `userMediatedFallbackToHTTP` never completes in a third-party `WKWebView`; checked with a probe). Checked on the real web (ShieldsLiveTests): `http://example.com/` commits as `https://example.com/`; `http://httpforever.com/` (its server refuses TLS) gets the interstitial, and Continue loads it over http. neverssl.com is no test for this: it answers over HTTPS on some of its random subdomains.
- **The guard.** For every main-frame http(s) GET that isn't back/forward or a reload, the host calls `<service>.<method> {id, url, source, link}` synchronously (the plugin answers from memory). The answer `{action: "rewrite", url, kind}` cancels the navigation and loads `url` instead (at most 4 rewrites in 2 s per page); `{action: "interstitial", page}` cancels it and shows the page; `{action: "block"}` cancels it; anything else allows it. WebKit asks again for server redirects, so a redirect that adds tracking parameters goes through the guard too.
- **Interstitial buttons** are links to `den-action:<id>`; the host turns a click into `interstitialAction` only while that page is the one showing in that web view. Return and Esc press the buttons whose `key` says so, and show as keycaps on them. The interstitial's own load (and den's error pages) skip the guard and HTTPS-first.

## vault

den's password vault. The host keeps every secret (Keychain + Touch ID); plugins see only origins and usernames.

| Method | Args | Returns |
|---|---|---|
| `enable` | – | ok. Installs the form listener (isolated `den-vault` world, every frame) in web views created from now on |
| `status` | – | `{enabled, mode: acl\|app\|memory, unlocked}` |
| `accounts` | `origin?` or `webview?` | `[{id, origin, username, created}]`. `webview`: the logins for the origin that page shows now (den derives it). Without either, only while unlocked |
| `focusLogin` | `webview` | ok. Focuses the page's sign-in field (an empty password field, else a username / email field), so `vault.focus` fires and the suggestions open (the key the passwords plugin puts in the URL pill with `tabs.pillButtons`) |
| `save` / `dismiss` | `capture` | ok. Store (Keychain) or drop a captured login |
| `fill` | `webview`, `account`, `request?` | `{request}`. Touch ID, then fills the focused form; `vault.result` |
| `generate` | `webview`, `request?` | `{request}`. A strong password (`abcdef-ghijk2-mNopqr`, ~71 bits, `SecRandomCopyBytes`) into every password field of the focused sign-up form |
| `unlock` | `reason?`, `request?` | `{request}`. Touch ID; the full list stays readable for 5 min or until `lock` |
| `lock` | – | ok |
| `copy` | `account`, `request?` | `{request}`. Touch ID, then the password on the pasteboard (marked concealed, cleared after 60 s unless something else was copied since: the pasteboard's change count must still be the one den set) |
| `delete` | `account` | ok, while unlocked |
| `suggest` | `webview`, `items: [{id, title, subtitle?, icon?}]` | ok. A small list under the focused field (`[]` hides) |

Events (never with a password): `vault.focus {webview, origin, field, signup, accounts: [{id, username}]}`, `vault.blur {webview}`, `vault.captured {capture, webview, origin, username, exists}`, `vault.suggestion {webview, item}`, `vault.result {request, method, ok, error?}`.

- **Capture.** macOS 26 has no form-submit callback (`willSubmitForm` is macOS 27), so a listener catches form submits, clicks on submit-like buttons and Enter in a field with a filled password. A capture lives in host memory for at most 5 minutes.
- **Origins** come from `WKFrameInfo.securityOrigin`, never from the page. Only https counts, plus http on loopback for local testing. A frame whose origin differs from its top page's (a cross-origin iframe) is ignored.
- **Fill** targets the frame that reported the focus, re-checks inside the page that the frame's origin is still the account's, and only then writes the fields.
- **Touch ID, always.** Every `fill`, `copy` and `unlock` calls `LAContext.evaluatePolicy(.deviceOwnerAuthentication)` first, with the reason "fill your password for \<host\>" / "copy your password for \<host\>", whatever keychain holds the item, and with no reuse window (`touchIDAuthenticationAllowableReuseDuration = 0`). The authenticated context is passed to the Keychain read (`kSecUseAuthenticationContext`), so an item with its own ACL doesn't ask twice. Each outcome is logged (`os_log` subsystem `io.github.abhishakenp.den`, category `vault`: `canEvaluate`, biometry type, the `LAError` code and ms), and `vault.result.error` is `cancelled` for a user/app/system cancel, `auth <LAError name> (<code>)` for anything else (e.g. `auth biometryNotAvailable (-6)`), or `keychain <OSStatus>`.
- **Storage.** `kSecClassInternetPassword` items marked "den password". den tries the data protection keychain with a `.userPresence` access control (`mode: acl`, where the Keychain itself also demands Touch ID) once per launch until it works. That needs a signature whose entitlements include `keychain-access-groups` (a provisioning profile); the ad-hoc and "den Local Signing" builds get `errSecMissingEntitlement` (-34018) and use the login keychain (`mode: app`), whose items can't carry a biometric ACL, so the explicit `LAContext` gate above is what asks. With the stable local signing identity the login keychain's own ACL keeps trusting den across rebuilds (an ad-hoc den changes its code hash every build, and macOS then asks for the login-keychain password instead). Reads and deletes look in both stores, so items saved before a signing change stay usable. `--demo` and the `vault*` scenarios use an in-memory store.
- **Username-first sign-ins** (Google, Microsoft): an email / `autocomplete=username` field reports focus even without a password field, and `fill` then fills just the username.

**Thin-host status.** The generic parts are: per-web-view user styles and appearance (`pagestyle`), a Keychain secret store with a user-presence requirement, and form-field observe/fill restricted to matching secure origins. Code marked `// thin-host: feature-specific, migrate to plugin` should move into the plugins:
- the page-tone heuristic
- the login and sign-up field heuristics
- the capture/save flow
- unlock and pasteboard timings, and the prompt strings
- the password format
- the suggestion popup (a generic anchored-popup `ui` node)
- the `overlay.passwords` slot name

## webext

The `webext` service: Chrome and Firefox extensions on Apple's `WKWebExtension` engine (the one Safari uses): Manifest V2 and V3, `chrome.*` and `browser.*`. Background and limits: [research notes](research/extensions-on-webkit.md). It is the platform bridge; the `extensions` plugin draws the Extensions page on top of this ([plugin-services.md](plugin-services.md#extensions-plugin-extensions)).

| Method | Args | Returns |
|---|---|---|
| `list` | – | `[ext]` (below) |
| `get` | `id` | `ext` |
| `install` | `path` (unpacked folder, `.crx`, `.xpi` or `.zip`), `request?` | `{request, pending}`. Copies/unpacks, validates, asks, loads |
| `installFromStore` | `url` (a Chrome Web Store or Firefox Add-ons item page), or `source: chrome\|firefox` + `id` (CWS id / AMO slug), `request?` | `{request, pending}` |
| `pickFile` | – | ok. An open panel; the pick goes to `install` |
| `uninstall` | `id` | ok. Unloads it, deletes its WebKit data, folder and icon |
| `setEnabled` | `id`, `enabled` | ok. Loads or unloads it |
| `setPinned` | `id`, `pinned` | ok. Pinned ones show in the URL pill on hover |
| `setSiteAccess` | `id`, `mode: all\|click\|sites`, `sites?` | ok. `all` grants every host it asked for, `click` only the tab you click it on (`activeTab`), `sites` the listed hosts |
| `allowSite` | `id`, `site`, `allowed` | ok. Adds or removes one host (switches `click` to `sites`) |
| `checkUpdates` | `force?` (true) | `{pending}`, then `webext.updates` |
| `action` | `id` | ok. Runs its toolbar action on the selected tab (a popup, or `action.onClicked`) |
| `menu` | `open?` (true) | ok. The extensions menu under the URL pill |
| `closePopup` | – | ok |
| `openOptions` | `id` | ok. Its options page in a new tab |
| `settings` | `storeButtons?` | `{storeButtons}`: "Add to den" on store pages (default on) |
| `state` | – | `{controller, ready, loaded: [id], popup, menu, prompts}` (tests) |

`ext`: `{id, name, version, description, source: chrome|firefox|local|home, storeId?, storeURL?, enabled, pinned, icon (PNG path), siteAccess, sites, permissions: [line], unsupported: [permission], loaded, hasAction, hasPopup, hasOptions, badge, manifestVersion, background: none|on demand|persistent, errors, updateAvailable?}`. `permissions` are plain-language lines worded like Chrome's install warnings ("Read and change all your data on all websites", "Block content on any page"). `unsupported` lists manifest permissions WebKit doesn't know (e.g. `userScripts`, `offscreen`).

Events: `webext.changed {extensions}` (the list), `webext.installing {request, …}`, `webext.installed {request, id, name, update}`, `webext.failed {request, error}` (`error: "cancelled"` when the user said no), `webext.uninstalled {id, name}`, `webext.updates {checked, updated: [id], available: [id]}`, `webext.openPage` (the menu's "Manage Extensions").

**Cost.** Nothing exists while nothing is installed: the registry file is read once, at the first web view (one failed file read), and no `WKWebExtensionController` is made. The first install creates it, rebuilds the live web views with it (they keep their back/forward state), and every later configuration gets it. At launch with extensions installed, a web view's first load waits (at most 2 s) until they are loaded, so blockers and document-start scripts apply to the first page. Service workers and non-persistent background pages are started and stopped by WebKit; den never calls `loadBackgroundContent`. Measured with uBlock Origin Lite: den's process grew from 29–30 MB to 105–107 MB (M3); on the CI runner it was 25.7 → 99.1 MB, almost all of it malloc's cache of blocks WebKit's rule conversion freed, and since den turned that cache off (`MallocLargeCache=0` in Info.plist) it is 23.3 → 36.1 MB ([baseline](perf/baseline.md#energy-lane-2026-09-28)); no extra WebContent process at rest, and ad blocking starts 14–31 s after loading (five runs) while WebKit compiles its rulesets ([research notes](research/extensions-on-webkit.md#dens-implementation-measured-2026-09-27-macos-265-builddenapp)).

**Storage.** `~/Library/Application Support/den/Extensions/` (next to `storage/`): `extensions.json` (the registry: id, version, source, store id, enabled, pinned, site access, granted permissions and patterns), `<id>/` (the unpacked extension) and `icons/<id>.png`. Grants are re-applied on every load. The controller is persistent (`WKWebExtensionController.Configuration(identifier:)`), and each context's base URL is `webkit-extension://<id>/`, so the extension's own storage survives relaunches. Any other `--storage` root uses `<root>/extensions` and a non-persistent controller. Unpacked folders in `~/.den/extensions/` load in place as development extensions ([den-home.md](den-home.md)).

**Ids.** A Chrome Web Store install keeps its store id (so `runtime.id` matches Chrome's); otherwise the manifest `key` gives the Chrome id, then the gecko id or the path gives a stable a–p id.

**Installing.** Store items: Chrome's update service (`clients2.google.com/service/update2/crx?response=redirect&prodversion=<current stable Chrome>&x=id%3D<id>…`) returns the CRX; den strips the CRX2/CRX3 header, unpacks the ZIP with `ditto` and checks `manifest.json` (valid JSON, `manifest_version` 2 or 3, `name`, `version`). AMO items come from the v5 API's `current_version.file.url` and are checked against its SHA-256. Every install shows an Arc dialog with the extension's icon, "Add “Name” to den?", what it can do, and what WebKit can't provide; nothing is written until the user clicks **Add Extension**. Runtime requests (`permissions.request`) show the same dialog ("“Name” wants more access").

**Store pages.** On `chromewebstore.google.com` and `addons.mozilla.org` item pages, a small script in an isolated content world (`den-store`, invisible to the store's scripts) hides the store's own install button and puts an Arc-style "＋ Add to den" pill in its place ("✓ Added to den" once installed). A click posts `{source, id}`; den re-derives both from the page URL before downloading. Other pages cost one host-name comparison per load. The button can be turned off (`settings {storeButtons: false}`).

**Updates.** Only with a store extension installed: a daily `schedule.interval` (`webext.updateCheck`), plus one check a minute after launch if the last is older than a day. Chrome items are checked in one Omaha request (`response=updatecheck`, `x=id=<id>&v=<version>` each); AMO items through the API. An update that asks for nothing new installs silently; one that asks for more waits for approval (`updateAvailable`, "Update to …" on its details).

**UI** (host-drawn; Arc's extension UI was never measured, so sizes are `Tokens.extension*` estimates):
- **URL pill.** While anything is installed, hovering the pill shows the pinned extensions' toolbar icons (with badges) and a puzzle button, left of the copy button. Clicking an icon runs its action; the puzzle opens the menu.
- **Menu.** 300 wide, PopoverBackground, below the pill: every enabled extension (click runs it, the pin toggles it in the pill), then "Manage Extensions" (`webext.openPage`) and "Get Extensions" (Chrome Web Store in a tab).
- **Popups** render the extension's popup web view in the same popover, sized like Chrome: its fit-content width and scroll height, between 25x25 and 800x600, re-measured while open. A click outside or Esc closes it.

What WebKit leaves out (no blocking `webRequest`, `identity`, `downloads`, `history`, `bookmarks`, side panels…) stays out: `unsupported` and the dialog say so. Keyboard `commands` and extension context-menu items aren't wired into den's menus yet.

## Connections, AI and scheduling

Host services behind the `connections`, `slack`, `github` and `briefing` plugins. Plugins have no Foundation, sockets or ML, so the host does the I/O. Asynchronous results arrive as `<service>.result {id, ...}`; every async method takes an optional `id` and returns `{id}`.

### Permissions

A plugin declares what it may reach in `Plugins/<id>/permissions.json`, e.g. `{"permissions": ["session:slack.com"]}`. `bundle.sh` copies it to `Contents/PlugIns/<id>.json`, and `PluginLoader` grants it when the plugin loads (user and dev plugins use the same sidecar next to their dylib). Anything undeclared is denied. The same sidecar says when a plugin loads: `"launch": "firstFrame"` (spaces, tabs) loads it before the first window, because it paints that window; every other plugin loads right after the first frame, and until then the services it provided last launch are stubs that load it on the first call (`PluginLoader`).

- `session:<domain>`: cookies and site storage of `<domain>` and its subdomains, and `net.fetch` there with cookies.
- `net:<domain>`: `net.fetch` there without cookies.
- `pages:<domain>` or `pages:*`: `webviews.inject` into pages there (every page with `*`), in the plugin's own isolated world ([Plugins in pages](#plugins-in-pages)).

A plugin's resource folder is its other sidecar: `Plugins/<id>/resources/` becomes `Contents/Resources/plugin-resources/<id>/` (a dylib elsewhere uses `<id>.resources/` next to it). From a checkout (`swift test`), den reads `Plugins/<id>/resources/` directly.

cordis doesn't tell a host service who called it, so `session` and `net` calls pass `plugin: "<own id>"` (as `commands.register` passes `owner`). Plugins are native code in den's process: this keeps each plugin to the sites it declared; it is not a sandbox.

### session

Reads what a signed-in site exposes, from den's own `WKWebsiteDataStore` for a profile. Nothing leaves the process or is persisted; plugins keep what they read in memory.

| Method | Args | Result |
|---|---|---|
| `cookies` | `plugin`, `domain`, `profile?` | `session.result {id, ok, cookies: [{name, value, domain, path, secure, httpOnly, expires?}]}` (HttpOnly included) |
| `eval` | `plugin`, `origin`, `script` (≤ 4 KB function body that `return`s JSON), `profile?`, `timeoutMs?` (10 s) | `session.result {id, ok, value}` or `{id, ok: false, error}` |
| `watchCookies` | `plugin`, `domain`, `profile?` (`default`) | ok (idempotent). Then `session.cookiesChanged {domain, profile}` whenever the cookies covering `domain` change: a sign-in or sign-out in den. Never carries values; the plugin reads them with `cookies` |
| `unwatchCookies` | `plugin`, `domain`, `profile?` | ok |

`watchCookies` is how connection plugins auto-connect, and it is event-driven: nothing polls. While at least one watch exists on a profile, a `WKHTTPCookieStoreObserver` sits on that profile's cookie store, and KVO on `isLoading` watches that profile's web views, because on macOS 26 the observer stops firing for good once anything reads the store after it was added (measured: every `Set-Cookie` notifies without reads, nothing after the first `getAllCookies`, and re-adding doesn't revive it), while a sign-in always ends with a page load on the site. Either signal schedules one coalesced read (300 ms, a one-shot work item) that compares each watched domain's cookies with a fingerprint taken at watch time (sorted `name=value`, in memory only) and emits only for domains that really changed. With no watches there's no observer, no KVO and no timer (`CookieWatchTests`).

`eval` runs in a hidden, never-shown `WKWebView` in that profile's data store, on an empty local document whose origin is `origin` (loaded with `loadHTMLString(baseURL:)`, so no request is made), in an isolated content world. That document sees the origin's localStorage (verified in `ConnectionsTests`). Any navigation is refused; the view is destroyed after the result.

### net

| Method | Args | Result |
|---|---|---|
| `fetch` | `plugin`, `url`, `method?` (GET), `headers?`, `body?` (string), `as?: json\|text`, `session?` (false), `profile?`, `timeoutMs?` (20 s, max 60), `maxBytes?` (5 MB, max 20), `stopAfter?` (a marker such as `</head>`) | `net.result {id, ok, status, headers, json\|text, truncated?, error?}` |
| `cancel` | `id` | ok |

- `session: true` copies the profile's cookies for that URL (domain, path, secure, expiry rules) into the request. A `Cookie` header from the plugin is ignored.
- Ephemeral `URLSession`: no cookie jar, no disk cache; responses never write cookies back. `set-cookie` is dropped from `headers` (names lowercased).
- Redirects are followed only to hosts the plugin may fetch, with the cookie header dropped; otherwise the 3xx comes back.
- `ok` is true for any HTTP response (check `status`). Over `maxBytes`: `error: "too large"`.
- `stopAfter: "</head>"` streams the body and stops reading once the marker (case-insensitive) has arrived or `maxBytes` is reached: `ok: true` with the text so far and `truncated: true` (`false` when the whole body arrived first). Add `headers: {Range: "bytes=0-65535"}` for servers that honor ranges. Link previews read only a page's `<head>` this way.

### ai

Apple's on-device Foundation Models, for summaries, todos and grouping only. The context window is read at runtime (4,096 tokens here); inputs are chunked at 3 characters per token with 1,200 tokens kept free, summarized per chunk (map) and merged (reduce). A chunk that still overflows is split in half and retried. Requests run one at a time.

| Method | Args | Result (`ai.result`) |
|---|---|---|
| `availability` | – | returns `{available, reason?, contextSize}` directly. `reason`: `deviceNotEligible`, `appleIntelligenceNotEnabled`, `modelNotReady` |
| `summarize` | `items: [string]`, `instructions?` | `{id, ok, text, ms}` |
| `brief` | `sources: [{name, items: [string]}]`, `instructions?` | `{id, ok, text, sources: [{name, text}], ms}`: one summary per source, then one combined brief |
| `todos` | `items: [{id, text}]`, `max?` (8), `instructions?` | `{id, ok, todos: [{item, title}], ms}`: guided generation (`@Generable {actionable, title}`), one request per item so a todo can't be attached to another item; non-actionable items are dropped |
| `group` | `items: [{id, text}]`, `maxGroups?` (6), `instructions?` | `{id, ok, groups: [{name, items: [id]}], skipped, ms}`: guided generation (`@Generable {groups: [{name, items: [Int]}]}`) over a numbered list (each line cut to 120 characters). Out-of-range numbers, repeats across groups and empty or unnamed groups are dropped here, so groups are disjoint. Items past the context budget are left out and counted in `skipped`. Used by Tidy Tabs; the prompt policy is the caller's |

When the model can't run: `{id, ok: false, error: "unavailable", reason}`; callers fall back to plain lists.

### schedule

| Method | Args | Returns |
|---|---|---|
| `daily` | `id`, `hour`, `minute` | ok. Fires `schedule.fire {id, reason: "time"}` daily. If den wasn't running or the Mac slept through that time, fires once with `reason: "catchup"` at registration or wake. The last fire time persists (storage ns `_schedule`); a first-ever registration doesn't catch up |
| `interval` | `id`, `ms` (min 60 s), `wake?` | ok. `{id, reason: "interval"}`, and `{id, reason: "wake"}` after wake when `wake` |
| `cancel` | `id` | ok |
| `list` | – | `[{id, kind, hour?, minute?, ms?, next}]` |
| `clock` | `ms?` | `{ms, hour, minute, weekday, date ("Sunday, September 27"), time ("8:02 AM"), offsetMinutes}`: local time for plugins |

Registrations live in memory (plugins re-register at launch). The clock is checked every 30 s and on wake.

### Development mock

`MockServices` (`Sources/DenHost/Scenarios/`) is a local fake Slack + GitHub + Gmail + Google Calendar + Notion on 127.0.0.1: a sign-in page that sets Slack's HttpOnly `d` cookie and `localConfig_v2` (two workspaces with `xoxc-` tokens), github.com's signed-in cookies, the Slack Web API methods den uses (token + cookie required, else `invalid_auth`), github.com search JSON shaped like a real response and PR pages with head/base branches; Google's `SID` sign-in cookie, Gmail's Atom feed for two accounts (401 without `SID`), a Calendar page whose event chips are built for today in the page's time zone, and an iCal feed around the mock's clock (recurrence, exceptions, a moved and a cancelled instance); Notion's `token_v2` cookie and `/api/v3/getSpaces` / `getNotificationLogV2` in both record nestings (`MockGoogleNotion.swift`). Tests and the `briefing*`, `connectToast`, `connectionsSettings`, `meetingReminder` and `liveFolder` scenarios point the plugins at it (storage `slack.endpoints`, `github.base`, `gmail.endpoints`, `calendar.endpoints`, `notion.endpoints`) and use the in-memory `private` profile.
