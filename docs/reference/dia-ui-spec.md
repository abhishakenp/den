# Dia UI Spec: hover cards, GitHub PR peek, and tab chrome

> **Reference only. Do not copy.** den must not ship any Dia or Arc assets, icons, sounds, fonts, videos or artwork. This file records **measurements, structure and behavior** so den can rebuild the *feel* with its own assets and copy. Screenshots and recordings stay in the scratchpad and never enter this repo. Nothing from the observer's own accounts (tab titles, repo names, people, messages) is recorded here.

- **Observed:** 2026-09-27/28, Dia **1.50.1** (`company.thebrowser.dia`), macOS 26 (Darwin 25.5), 2x Retina display at 1470x956 pt, **dark** appearance, vertical-tabs (sidebar) layout, window 1470x923 pt at (0, 33).
- The profile was freshly signed in with few tabs. **GitHub is not connected:** Settings → Apps shows Advanced Chat off and no connected apps (§7), so there is **no GitHub Live Group** and the live PR-data hover couldn't be exercised (see §3.5). The PR-peek spec in §3 comes from Dia's own release-note video, frame-stepped, plus the binary's strings and data model.
- Session 2 (2026-09-28) ran after Dia relaunched (same build) and covered the light theme (§2.6), ⌘-click tab groups (§6), Settings → Apps (§7) and PiP (§8).
- Companion docs: [`arc-ui-spec.md`](arc-ui-spec.md) (Arc measurements, plus a static Dia section in §13), [`../research/dia.md`](../research/dia.md), [`../research/dia-changelog-inventory.md`](../research/dia-changelog-inventory.md).

## Provenance tags

| Tag | Meaning |
|---|---|
| **AX** | Frame or label read from the Accessibility API while Dia ran (a custom Swift `AXUIElement` dumper). Points, screen coordinates, window at (0,33) |
| **PX** | Pixel measurement on a Retina capture (2 px = 1 pt) |
| **WIN** | `CGWindowListCopyWindowInfo` polled every 5 ms, which gives the moment the card's own window appears or disappears |
| **REC** | ScreenCaptureKit stream filtered to Dia's windows only, at 60 fps, with frames wall-clock stamped against the synthetic mouse-move timestamp. SCK delivers frames only when something changes, so onsets are ±17 ms plus SCK latency |
| **VID** | Dia's release-note video "Stop opening PRs blind" (v1.31.0, 2026-05-14): Mux asset, 1834x1080 at 24 fps, 7.0 s. Frame-stepped with ffmpeg. The video is zoomed and composited, so **point sizes are derived** from a scale of 2.08 video px per pt. That scale was calibrated by matching the title glyph height and the 13 pt text inset against the live dark card measured in AX/PX. Expect about ±1 pt |
| **STR** | `strings` on `Dia.app/Contents/MacOS/Dia`, which gives UI copy, Swift type names and the protobuf/JSON field names |
| **LIVE** | Observed on screen while exercising the feature |
| **UNVERIFIED** | Not measured. These are never filled with a guess |

All timings below are **measured** medians or ranges over N trials, with N stated.

---

## 1. Window and sidebar geometry (vertical tabs, dark)

| Element | Value | Prov. |
|---|---|---|
| Sidebar width | **190** (scroll area x 0–190). The web content card starts at x = 190 | AX |
| Traffic lights | 16x16 at x = 17 / 40 / 63, y = 19 from the window top (23 pt pitch) | AX |
| Nav bar (single pane) | Height 42 (y 6–48, window-relative) over the content card. Back / Forward / Reload are 32x32 at x = 230 / 265 / 300 (35 pt pitch). The URL/assistant pill starts at x = 335, height 32. The right-side "Chat" button is 74x30 | AX |
| Web area | x 190 to 1464, meaning the content card leaves a **6 pt** gutter on the right and bottom (y to 950 of 956) | AX |
| Pinned area (empty state) | A dashed rounded rect with a pin-plus glyph, 180x43 at (5, 53 window-rel). The empty-state education copy is "Pin your favorite sites" / "Drag a tab into this area or use the pin icon." | AX, STR |
| Pinned tile (one pinned tab) | Fills the pinned area as a 176x39 tile. When selected it has a black fill with a light 1.5 pt ring | PX |
| Tab row | Frame 192x39 at x = −1. **Row pitch 37** (rows overlap by 2). Favicon 18x18 at x = 14; title at x = 37, 18 tall; close "x" appears at the trailing edge on hover/selected | AX |
| Tab in a group | Indented to x = 15 with width 173 (16 pt indent, 3 pt narrower trailing edge). The group container is a rounded, lighter panel around its header and children. Header: group favicon, name, disclosure chevron, and close "x" on hover | AX, PX |
| Split tab in sidebar | One row, two halves: favicon + title for each pane (titles at x = 37 and x = 126, 47 wide each) | AX |
| "+ New Tab" row | Last row of the list, dimmed | AX |
| Sidebar footer | Chevron button 44x43 at bottom-right (x 144, y 881 window-rel) | AX |
| Split view panes | Two panes of **628** each, x 196–824 and 836–1464: a 6 pt outer gutter and a **12 pt gap** between. **Each pane has its own nav bar** (back / forward / reload / URL) and a close "x". The focused pane has a light outline. The right pane shows a "Chat with Tabs" pill | AX, PX |

---

## 2. Tab hover card (priority)

### 2.1 What it is

- It is a **separate borderless window**, one per card. Dia reuses and moves it when the hovered tab changes (same window id, new frame). STR: `TabUI.TabPopoverViewController`, `TabPopoverContentView`, `TabPopoverActionsView`, `TabPopoverActionButton`, `TabHoverPreviewActionHandler`, and a separate `Tooltip.TooltipWindow` for the button tooltips.
- The window is the card plus a **22 pt transparent margin on every side** for the shadow. Window 244x153 means card 200x109. (WIN + PX)
- **There is no page snapshot or thumbnail** in the vertical-sidebar card in 1.50.1. It is text plus an action row. (LIVE, 7 tab kinds)

### 2.2 Placement (AX, 6 tab kinds)

| Rule | Measured |
|---|---|
| Horizontal | Card left edge = **hovered row's maxX + 3 pt**. Normal row: maxX 191, card x 194. Grouped row: maxX 188, card x 191 |
| Vertical | Card **vertically centered on the hovered row**. Row 238–277 (center 257.5) gives card 204–313 (center 258.5). Holds for 1-line and 2-line titles |
| Pinned tile | Card x = 178 (it overlaps the sidebar), top = tile bottom − 3. It hangs **below-right** of the tile rather than beside it |
| Near the window bottom | UNVERIFIED. There weren't enough tabs to reach the edge |

### 2.3 Size and layout (dark, AX + PX)

| Part | Value |
|---|---|
| Width | **Content-fitted, clamped to 170–200 pt**. Title text box max 173, so 200 = 13 + 173 + 14. A short title ("Example Domain") gives 170 |
| Height | 109 (2-line title + subtitle + actions), 93 (1-line title), 65 (no actions: the "New Tab" card) |
| Corner radius | **12 pt** (the border meets the straight edge 23–24 px from the corner). Treat it as continuous |
| Background | **Solid `#262626`** (38,38,38), no grain or noise (a 60x20 px patch had exactly one color), no visible vibrancy |
| Border | Hairline: 1 px (0.5 pt) `#3C3C3C` inner with `#2B2B2B` outer anti-alias |
| Shadow | Soft and even on all sides, roughly 8 pt blur, about 0 y-offset, peak darkening about 7% on a near-white page (251→234), fading to the background over about 7 pt |
| Text inset | 13 pt left (text x = card x + 13). Title top padding 15 pt |
| Title | System font, **13 pt semibold**, `#DEDEDE` (222). **Max 2 lines**, tail-truncated with "…". Line pitch 16–17 pt (text frame 173x34 for 2 lines) |
| Subtitle | 13 pt regular, `#9D9D9D` (157), 18 tall, directly under the title (pitch 17) |
| Subtitle content | **Host**, e.g. `github.com`. For GitHub PRs it adds ` • #<number>`, e.g. `github.com • #3752`. GitHub *issues* get the host only, with no number. A New Tab shows "Ask anything…" |
| Action row | 6 pt below the subtitle. Buttons are **34 pt tall**, inset **3 pt** from the card's left, right and bottom edges, with **2 pt gaps**, and **equal widths filling the row**: 4 buttons are 47 wide on a 200 card and 39 wide on 170; 3 buttons are 63 wide on 200 |
| Action icon | About 12–14 pt line glyph, `#9D9D9D`, brightening to `#A4A4A4` on hover |
| Button hover | Rounded-rect fill `#373737` (55), about 8 pt radius, 45x32 visible inside the 47x34 hit area |
| Tooltip | Separate window **below** the button, centered on it: 3 pt gap, 28 pt tall, `#474747` fill, `#E4E4E4` 12 pt text, about 6 pt radius. Tooltip copy is in §2.5 |

**Rebuild recipe (SwiftUI terms):** `NSPanel` (non-activating, borderless, `hasShadow = false`), with the SwiftUI content padded by 22 and drawing its own shadow (`.shadow(radius: 8)`); `RoundedRectangle(cornerRadius: 12, style: .continuous)` filled `#262626` with a 0.5 pt `#3C3C3C` stroke; `VStack(alignment: .leading, spacing: 0)` holding the title (13 semibold, `lineLimit(2)`), the subtitle (13 regular, secondary), `Spacer(6)`, then an `HStack(spacing: 2)` of equal-width 34 pt buttons with a 3 pt inset. Width `min(max(textWidth + 27, 170), 200)`.

### 2.4 Timing (REC + WIN, from real synthetic hover)

| Event | Measured | N |
|---|---|---|
| **Hover → card window created** (list tab) | **685–915 ms**: 685, 720, 721, 749, 753, 759, 763, 784, 785, 789, 800, 814, 815, 835, 863, 885, 900, 915. From a sidebar rest point: 685–789. From the content area: 753–915 | 18 |
| Hover → card window created (**pinned tile**) | **285–416 ms** (285, 319, 336, 416). Pinned tiles show their card about 2x faster | 4 |
| Window created → first visible pixels | +20–70 ms (the card fades in over the next frames) | 3 |
| **Entrance** | **Opacity 0→1 plus scale ~0.93→1.0, anchored at the top-leading corner** (the left and top edges stay fixed while the right and bottom edges grow). About 150–230 ms to settle | 4 |
| **Exit grace** (pointer leaves both row and card) | Fade starts **+202 to +267 ms** after leaving (202, 207, 261, 267) | 4 |
| **Exit animation** | Opacity 1→0 plus scale down to about 0.93, anchored top-leading. About 80–130 ms. The window is ordered out 575–677 ms after leaving (574, 581, 590, 607, 608, 636, 663, 677) | 8 |
| **Row → another row while a card is showing** | The old card **stays** until the new dwell completes (**626 ms and 768 ms** measured, plus one trial at 1127 ms), then **hard-cuts**: the content and frame swap in a single frame with no crossfade and no slide. The same window is reused and repositioned | 3 |
| Row → card (moving onto the card) | The card persists and its buttons are hoverable. The 3 pt gap is bridged by the exit grace | LIVE |

For den: Dia's list-tab dwell is **longer than Arc's feel** (about 0.7–0.8 s). A good den default is 0.7 s for list rows, 0.3 s for pinned/favorite tiles, a 200 ms exit grace, and a 100 ms fade+scale(0.93) exit anchored at the leading edge. Swap on row change should be a hard cut, but den may skip Dia's re-dwell (Arc swaps immediately) and should make that a setting.

### 2.5 Actions on the card (AX order, tooltips from live `Tooltip.TooltipWindow`)

| Tab kind | Buttons, left→right (tooltip) |
|---|---|
| Normal list tab (not active) | **Pin tab** (pin glyph) · **Bookmark this page** (bookmark glyph) · **Open as Split** (split-rectangle glyph) · **Chat with this tab** (speech-bubble glyph) |
| Active tab (pinned or list) | Split tooltip becomes **"Split tabs"** (STR: "Tooltip for the split tabs button"). The others are unchanged |
| **Pinned tab** | **Reset pinned tab** (`arrow.uturn.backward`; **dimmed/disabled** while the tab is still at its pinned URL) · Bookmark this page · Split · Chat with this tab. There is **no Pin button** |
| Split pair (hovering either half of the split row) | One card listing **both** panes (title + host each, stacked), with **3** equal buttons (63 wide). The split button's tooltip is "add another tab to an existing split" (STR). Tooltips weren't captured live because another app's windows kept covering the region |
| Tab inside a group | Same as a normal tab |
| Group header | **No hover card** (2 s dwell, N=1) |
| New Tab (internal page) | Title "New Tab", subtitle "Ask anything…", **no actions** |
| Already-bookmarked page | Bookmark button tooltip becomes **edit bookmark** (STR: "Tooltip for the edit bookmark button"; icon `bookmark.fill`) |

- **There is no Close button on the card.** Close stays on the row's trailing "x".
- Verified effect: **Pin tab** pins immediately. The row leaves the list and becomes the pinned tile; no toast was seen. **Open as Split** immediately splits the hovered tab with the active tab (50/50, hovered tab on the right). Chat, Bookmark and Reset were not pressed.
- Pinned-tile favicon hover has extra subtitles (STR): **"Back to Pinned URL"** when the tab has navigated away, and **"Separate from Pinned Tab"** when **⌘ is held** (detach).
- Other hover previews exist in the binary (STR), which den should consider: `CliaBriefPreview` (the **Morning Brief** tab's hover shows the brief's top to-dos as a **checklist**, with done-state persisted per day); `CalendarBadgeController` / `PinnedTabBadge` (a **calendar badge on pinned tiles**); `LiveItemHoverPreview` (Live Group items for Slack/Gmail/Notion/Confluence); `AudioMiniPlayerPreviewController` (media tab: artwork via `navigator.mediaSession`, title/artist, seek).

### 2.6 Theme behavior

- **Dark (measured):** card `#262626`, title `#DEDEDE`, secondary `#9D9D9D`, button hover `#373737`, tooltip `#474747`. The card does **not** pick up the page, and it does **not** tint to the sidebar gradient. It's a neutral surface one step lighter than the sidebar.
- **Light (VID, horizontal-tab card):** card about `#F2F2F2`, with a white 1 px top highlight/border and the same soft shadow; primary text near-black; secondary about `#B7B7B7` status text.
- **Light (LIVE, session 2, same list-tab card, PX on the card window):** card fill **`#F4F4F4`**. Border is two layers: a **1 pt white (`#FFFFFF`) inner highlight** and a **0.5 pt `#DCDCDC` outer hairline**. The dark card has a single `#3C3C3C` hairline instead. Title **`#252525`**, subtitle **`#7B7B7B`**, action glyphs `#7A7A7A`. Size, placement and layout are identical to dark (200 pt wide, 4 × 47 pt buttons). Light sidebar: fill about `#F2F2F2`, selected row about `#F7F7F7` (near white).
- The card **follows Dia's in-app appearance override**: switching View → Appearance → Light re-themed it with the system still dark. The menu offers **Automatic / Light / Dark**. The user's setting (Automatic) was restored afterwards and re-read over AX (✓ Automatic).

---

## 3. GitHub PR peek (Live Group PR hover): "Stop opening PRs blind"

### 3.1 Where it appears

- **Shipped in v1.31.0 (2026-05-14)** per the release notes. It appears when hovering a PR **inside the GitHub Live Group** (the auto-populated group, "Pull requests from you and your team will show up here automatically", STR).
- Dia's own demo shows it in the **horizontal (top) tab layout**. The Live Group is a tab-bar group pill titled "PRs" with a checklist glyph, and each PR tab is **two lines**: title, then "author • Comments" subtitle. The card drops **below** the hovered tab, **left-aligned to the tab's left edge**, with about an 8 pt gap. (VID)
- **Vertical-layout difference:** this section will be completed from the user's live demonstration (§3.6). In vertical layout the regular card anchors to the **right** of the row (§2.2).
- PRs opened as ordinary tabs (outside the Live Group) get only the **plain card** (§2.3). Its subtitle is `github.com • #N`, with **no CI, diff or conflict data**. (LIVE, public PR, N=2)
- **Tab favicon status dot:** the PR tab's GitHub favicon carries a small colored dot at its bottom-right (yellow = checks pending, seen in the demo). This is at-a-glance CI state without hovering. (VID)

### 3.2 Card anatomy, top→bottom (VID, light theme; pt derived at 2.08 px/pt)

| # | Row | Details |
|---|---|---|
| 1 | **Title** | PR title, 13 pt semibold, near-black, single line in the demo. Top padding about 13 pt |
| 2 | **Author line** | 16 pt round **avatar** + `author · #number` in secondary gray (13 pt). About 7 pt below the title |
| 3 | **Diff size** | **`+1521`** in green (about `#1E8A3C`), **`-36`** in red (about `#A23A36`), then `· 22 files` in secondary. Semibold numbers, 13 pt. This is the "three lines or three hundred?" answer: plain +/− counts plus a file count. **No proportional diff bar** |
| 4 | **CI progress bar** | Full-width capsule (inset 12 pt each side), **about 6 pt tall**, fully rounded. Segments in order **green (passed) → yellow (pending) → red (failed) → gray track (not started/remaining)**, each proportional to its check count. Green about `#1C8637`, yellow about `#CB9F16`, red about `#A23127`, track about `#DADDDF` (VID). STR: `GitHubPRHoverPreview.CIProgressBarView` |
| 5a | **Status line** (no failures) | Secondary gray, 12–13 pt. Exact strings (STR): **"All checks have passed"**, **"Checks are queued"**, **"Some checks haven't completed yet"** |
| 5b | **Failing-check rows** (when failures exist) | Replaces the status line. **Up to 3 rows** shown, each a full-width (inset 12) rounded rect about 22 pt tall on a 30 pt pitch (about 7 pt gap), with a light-red fill (about `#F0DDDD`), a **3 pt solid red leading accent bar**, and red-brown text (about `#7C3137`) holding the check's full name, e.g. `PR / <workflow> (<variant>) / <job>…`, tail-truncated. Status copy (STR): "1 check is failing" / "%d checks are failing". Clicking a row opens that check (analytics action `pullRequestViewCheck`) |
| 6 | **Action buttons** | Full-width row, inset 12, 6 pt gap, **about 32–34 pt tall**, pill-ish radius about 8. With no failures there is a single **black** button with **white "Show comments"** and a speech-bubble glyph (`pullRequestShowComments`). With failures there are two: **red "Show N failures"** (`pullRequestShowAllFailures`, about `#A63027`, white semibold) at about 45% width, then **black "Show comments"** filling the rest. With a merge conflict: **"Resolve Conflicts"** (`pullRequestResolveConflicts`, STR); its visual wasn't captured (UNVERIFIED) |
| — | Card | **About 288 pt wide**. Height about 156 (no failures) or about 223 (3 failing rows). Corner radius about 12, light fill about `#F2F2F2` with a white hairline, soft shadow. Bottom padding about 9–12 |

**Live counting:** within the same hover the demo's red button went **"Show 5 failures" → "Show 7 failures"** as checks completed. The card re-renders in place with no flicker. (VID, frames 76→90)

### 3.3 Motion in the demo (VID, 24 fps)

- **Tab-to-tab swap while a card is open is instant.** It is a hard cut between two consecutive frames (≤42 ms), and the card jumps to the new tab's left edge. This is the horizontal layout, where Dia appears to skip the re-dwell described in §2.4. The video is edited, so treat it as indicative.
- There's no visible entrance animation on the cut. The first appearance in the video is hidden by a camera zoom.

### 3.4 Data model behind it (STR, field names)

- PR: `owner`, `repository`, `number`, `title`, `author_login`, `state` (OPEN/CLOSED/MERGED), `is_draft`, `created_at`, `updated_at`, `closed_at`, `merged_at`, `review_summary`, `diff_stats{additions, deletions, changed_files}`, **`mergeable` (MERGEABLE / CONFLICTING / UNKNOWN)**, **`unresolved_review_threads`**, `status_check_rollup`, `decision` (APPROVED / CHANGES_REQUESTED), `viewer_latest_review_state`, **`viewer_is_requested_reviewer`**, and a stack (`pull_request_stack`, `stack_list_hint`, stacked/unstacked, position, size: **PR stacks**).
- Filters (group membership): `createdByMe`, `requestingMyReview`, `approved`, `changesRequested`, `involved`, `reviewRequested`, `reviewedByMe`, `authoredMerged`, `authoredOpen`, `authoredCompleted`.
- Thread events: comment / review / review comment, with review states commented / pending / dismissed.
- **Transport:** Dia reads GitHub through the **user's signed-in github.com web session** (it fetches and parses page HTML), not via OAuth. The error strings show this: "Not signed in to GitHub", "GitHub SSO required", "Unable to fetch HTML from GitHub", "Unexpected GitHub page structure", "GitHub requested too soon", "GitHub rate limit exceeded", "Missing web content for PR".
- Tab chrome strings: **"Unresolved comments"**, **"Pull request stack"** (TabUI accessibility and badge strings).

### 3.5 What could not be observed live, and why

- There was **no GitHub Live Group** in the profile. Creating one needs a GitHub connection or sign-in flow, which the task rules forbid (connect nothing new). So the live timing, dark-theme colors and exact point sizes of the **PR** card are unmeasured. The numbers in §3.2 are VID-derived (±1 pt, colors are video-compressed).
- The merge-conflict visual and the review-state/reviewers display (if any) aren't shown in the demo video. UNVERIFIED.

### 3.6 Vertical tabs vs horizontal (user demonstration)

This demo was skipped. The user reviewed **den's vertical-sidebar PR peek** directly and **confirmed it matches the intended behavior**, so den's implementation is the reference for vertical layout. Dia's own PR peek was only observed in the horizontal layout (release video, §3.1). Its vertical-layout placement in Dia itself is not recorded here: it can't be observed without a GitHub Live Group.

### 3.7 den recommendations for the PR peek

1. Build it as a **variant of the tab card** (same window, shadow, radius and placement engine), with a wider fixed width of about 288 pt and a vertical stack: title → avatar+author·#n → `+a −d · n files` → 6 pt segmented CI capsule → status line *or* up to 3 failing-check rows → action buttons.
2. Put a **status dot on the favicon** (pending yellow / failed red / passed green / conflict) so CI state is visible without hovering.
3. **Update counts in place** while the card is open (5 → 7 failures) without re-animating.
4. Data: prefer the GitHub GraphQL API with the user's token (den's integrations model) over HTML scraping. Fields: `additions`, `deletions`, `changedFiles`, `mergeable`, `reviewDecision`, `statusCheckRollup.contexts`, `reviewThreads(isResolved:false)`.
5. Offer buttons **"Show N failures"** (opens the checks tab filtered to failures), **"Show comments"** (jumps to the conversation), and **"Resolve conflicts"** when `mergeable == CONFLICTING`.

---

## 4. Right-click tab menu (LIVE + AX; native `NSMenu`, 261 pt wide, 24 pt rows, 11 pt separators, SF Symbol-style glyphs)

**List tab:**
1. Pin
2. —
3. Chat With This Tab `⌘E` · Open as Split · Duplicate
4. —
5. New Group with Tab `⌃⌘N` · Move to Profile › · Move to Window ›
6. —
7. Add to Bookmarks… `⌘D` · Add Bookmark to Folder ›
8. —
9. Copy Link `⇧⌘C` (⌥ alternate: **Copy Link as Markdown**)
10. —
11. Rename… · Change Icon… · Mute Site
12. —
13. Close `⌘W` · Close Other Tabs · Close Tabs Below (⌥ alternate: **Close Tabs Above**)

**Pinned tab:** the same menu, except that Pin becomes **Unpin**; "Move to Window" becomes **Open in New Window**; the Rename section gains **Edit Pinned Page ›** (→ "Replace Pinned URL with Current"); and the closing section is **Close** only.

Menu shortcuts, read over AX (`AXMenuItemCmdChar`/`Modifiers`): New Tab `⌘T`, **New Tab in Group `⌥⌘T`**, New Window `⌘N`, New Incognito Window `⇧⌘N`, Reopen Closed Tab `⇧⌘T`, Chat… `⌘E`, Focus Chat `⌃⌘E`, Open Command Bar `⌘L`, Close Window `⇧⌘W`, Close Tab `⌘W`, Close All Tabs `⇧⌘K`, **Clean Up Tabs `⌥⌘K`**, Next/Previous Tab `⇧⌘]`/`⇧⌘[`, **Search Tabs… `⇧⌘A`**, New Group with Tab `⌃⌘N`. The Tabs menu gains **Remove from Group** when the active tab is grouped.

Menu-bar **Tabs** menu: Go Back, Go Forward, Next Tab, Previous Tab, **Search Tabs…**, Pin, **Separate Tabs** (unsplit), Duplicate, New Group with Tab, Move to Group, Move to Profile, Move to Window, then the open-tab list. **File:** New Tab, **New Tab in Group**, New Window, New Incognito Window, Reopen Closed Tab, Chat…, Focus Chat, Open Command Bar, Close Window, Close Tab, Close All Tabs, **Clean Up Tabs**, Share…, Print…. **View:** Appearance, Refresh, Force Refresh, **Show Tabs in Sidebar** (toggles the vertical/horizontal layout), **Auto-Hide Tabs**, Open Split Pane, Focus Next/Previous Split Pane, Show Bookmarks Bar, **Show Full URL**, zoom, Full Screen, Developer. **Edit** adds **Copy URL** and **Copy URL as Markdown**. **Help:** Chat with Support, Video Tour, Status, Copy Diagnostics, **Record Performance Issue…**. (AX)

Split-view menu strings (STR): "close the focused pane", **"Separate All Tabs"**, "move the current split pane to the right/left", "splitting with an existing tab" (section title). Drag-to-split drop targets are "add a left/right split view" with half-filled rectangle glyphs.

## 5. Command bar (LIVE screenshot + AX)

- AX: `commandBar`, 1125x107 docked over the toolbar while editing the current URL. It contains a `commandBarTextField` with a leading magnifier, a bottom row with **"+ Add tabs or files"** (a pill), a "More" (…) button, and trailing toolbar buttons (34x34), including a 102x34 primary.
- The new-tab/⌘T form is centered over the page: about 650 pt wide, rounded, dark (`#2E2E2E`-ish). The input row has a globe glyph. Results are single-line rows on about a 40 pt pitch, and the top row is highlighted with a lighter rounded fill. Ranking seen for the query "github": **1. navigational URL match** ("GitHub — github.com"), **2–5. search suggestions** (bold completion suffix), **6. an already-open tab** matching the query, with a trailing hint **"Hold ⌘ to switch →"**. Footer: "+ Add tabs or files", "…", mic, and a **"Go ↩"** button with a keycap. (PX from a downscaled capture; values approximate, ±5 pt)
- The mode-tinted caret and selection colors are in arc-ui-spec §13 (CAR).
- **New Tab page** (LIVE, session 2): there are no results at rest. It shows a centered composer, about 490 pt wide at a 1274 pt content width, with an "Ask anything…" placeholder, a magnifier, "+ Add tabs or files", "…", mic and a send button. A round avatar sits above it. Below: the headline "Prep for meetings. Draft replies. Catch up on threads. Generate reports.", the line "Connect Slack and Google to get started.", two app cards (Slack / Google) each with a white **Connect** pill, then "Use other apps? Connect others or dismiss." At the bottom is a fanned stack of sample-artifact cards (status report, weekly brief, analytics review). None of it was clicked.

## 6. Tab groups / ⌘-click (LIVE)

**Manual group:** "New Group with Tab" (`⌃⌘N`) creates a group named **"Group 1"** and **drops straight into inline rename** (the name is selected). Esc keeps the default name. With one tab, no auto-name or emoji appeared within 6 s. A manual one-tab group **persists** (it survived a relaunch collapsed) and disappears when its last tab closes.

**⌘-click a link: the auto group** (Wikipedia pages, ⌘ plus synthetic left click; recording and AX; N=1 for creation):

| Question | Observed |
|---|---|
| Where the new tab goes | The source tab and the new tab are **wrapped into a new group at the source tab's position**. The group header takes the source row's slot, and the source becomes the group's first child with the new tab second. Children are indented 16 pt (x = 15, width 173 vs the top-level x = −1, width 192) |
| Background? | **Yes.** The source stays active (AX web area and window title unchanged), and the new tab loads in the background |
| Row timing | The group and new row animate in **~120–250 ms after mouse-up**, with a ~90 ms settle (about 6 frames of decreasing change: rows slide down, children indent). The new row first shows the **URL as its title with a placeholder favicon** and switches to the page title about **0.8–1.0 s** later |
| Naming | The header first shows a **grey shimmer skeleton** bar (no text) for about 3 s, then an **AI-style name built from the tabs' titles**: "WebKit" + "Apple Inc." gave **"WebKit & Apple"**, about 3.8–4.2 s after the click. The name **reveals with a multicolor gradient sweep across the text** (about 0.4 s, 4.2→4.6 s) and settles to plain white bold. It was **not renamed** when more tabs were added (4 tabs, still "WebKit & Apple") |
| Emoji | During the reveal the header icon **morphs from a blue blob to an emoji** (🍎 for Apple/WebKit). The emoji shows **transiently** (after creation, and again for about 1 s whenever a tab is added or the group changes), then the icon falls back to the **first child's favicon**. At rest (window key or not, pointer anywhere) it was the favicon in every capture (N=4 idle captures, 2 transient emoji sightings) |
| 2nd ⌘-click from the **source** tab | Joins the **same group**, inserted **after the source's previously opened child** (WebKit → Apple Inc. → **Igalia** appended last). It opens in the background, with no new group |
| ⌘-click from the **new** (child) tab | Joins the same group, **inserted directly after that tab** (Apple Inc. → **Steve Jobs**, placed before Igalia). This is Chrome-style opener-relative insertion and is not nested |
| `⌥⌘T` inside a group | Opens **"New Tab" as the last child of the active tab's group** (not next to the active tab), selects it, and focuses the "Ask anything…" composer |
| Closing a grouped tab | Closing the ⌥⌘T New Tab went back to the **previously active tab** (Apple Inc.), not a neighbor. Closing Apple Inc. selected the **next tab below** (Steve Jobs), and closing Steve Jobs selected the next one (Igalia). No animation beyond the row collapse |
| Last tabs | When an **auto group drops to one tab, the group dissolves**: the remaining tab (WebKit) returns to top level at x = −1 with no header |
| Sidebar treatment | The group is a **rounded, lighter container panel** (dark about 8% white over the sidebar) spanning the header and children. The header shows the icon (18 pt), a **bold** name and a disclosure chevron `⌄`; clicking it collapses to `›`. The active child gets the usual selected pill. There's no colored group tint in vertical tabs |

**den takeaways:** ⌘-click-to-group is a strong default. Build the header from the source and new titles ("A & B"), with emoji/icon selection async and a skeleton placeholder until it's ready. Insert opener-relative, dissolve at one tab (auto groups only), and make ⌥⌘T add to the end of the current group.

## 7. Settings (AX, window `preferencesWindow`, 778x509)

- Left source list 196 wide with 28 pt rows and 20x20 glyphs, in this order: **Account, Tabs, Privacy, Profiles, Apps, Shortcuts, Advanced**. Content pane 574 wide. Separately, **Personalization** opens as a full *tab* page (not in the window): an avatar, 8 accent swatches, a "Personalize new chats" toggle card, and free-text "Teach Dia about yourself" fields.
- **Apps pane** (AX + window capture; nothing clicked). A top card: a 32 pt round icon, "**Advanced Chat**" / "Connect your apps to let Dia help you with your work", and a **"Turn On Advanced Chat"** button (163x32, light-grey fill). Below is an **APPS** section header (small caps, secondary) and one grouped rounded list: 18 pt icon plus name, **51 pt row pitch**, hairline separators, some rows with a **BETA** chip (28x13, grey fill). The 20 apps: Amplitude, Atlassian, Canva β, Figma, GitHub, Gmail, Google Calendar, Google Chat β, Google Drive, Granola, Linear, LinkedIn, Notion, Outlook, Salesforce β, SharePoint, Slack, Teams, Trello β, Zoom β. With Advanced Chat **off**, rows have **no per-app Connect/status control**: connecting is gated behind the toggle. So the **connected / auto-connected state could not be observed**, because nothing is connected (UNVERIFIED). Toolbar title "Apps" with back/forward chevrons. The pane was put back to Account and the window closed afterwards.

## 8. Other features

- **PiP (LIVE, session 2).** Test page: a local muted, looping `<video>` (Big Buck Bunny 480p, Wikimedia Commons).
  - **No auto-PiP** when switching tabs away from a playing **muted** video, and no sidebar mini-player appeared (N=1). Audible playback wasn't tested (the task rules require muted), so auto-PiP for audible video is UNVERIFIED.
  - Manual PiP comes from the video's context menu (Loop, Show All Controls, Open Video in New Tab, Save Video Frame As…, Save Video As…, Copy Video Frame, Copy Video Address, **Picture in Picture**, Cast…, Inspect).
  - The PiP window is a **Chromium/system PiP panel**: AX role `AXSystemDialog`, window **layer 3 (floating)**, **320x180 pt**, placed **bottom-right with a 10 pt margin** from the screen edges, corner radius about 5 pt. It has **no Dia-branded chrome**: no "Keep on Top" or stash control was visible, and its hover controls aren't part of Dia's window contents (they didn't appear in Dia-only captures). Closing the source tab closes the PiP.
  - "Keep on Top" and stash were not seen for web video; the `isStashed` strings may belong to other floating panels (UNVERIFIED).
- **Morning Brief:** not visible in this profile (no brief tab or badge). The new-tab page only shows a marketing card for it. Not observed.
- Toasts and sounds were not exercised. The strings confirm an **audio mini-player** (Spotify-aware, seek, marquee title, mediaSession artwork), **stashable** floating panels (`isStashed`, `wasLastPresentationStashed`), and a Morning Brief with scheduled daily generation ("Morning Brief preference that generates every day"). For sounds and toasts, see arc-ui-spec §13.

## 9. den recommendations (summary)

1. **Card engine:** one reusable borderless panel with a 22 pt shadow margin; placement = row.maxX + 3, vertically centered (pinned: below-right); width clamp 170–200; radius 12; hairline border; neutral surface (dark `#262626`).
2. **Timing:** 0.7 s list dwell, 0.3 s pinned dwell, 200 ms exit grace, fade+scale(0.93) anchored top-leading (about 180 ms in, about 100 ms out), hard-cut swap.
3. **Actions on the card** replace the right-click for the top four verbs. Pin, Bookmark (becomes Edit), Split (context-aware: "Open as Split" / "Split tabs" / "Add to split"), and Chat, which den should map to its own assistant or drop. For **pinned** tabs, swap Pin for **Reset to pinned URL**, disabled when already at it. For **split** rows, list both panes.
4. **⌘-hover on a pinned tile** previews "Separate from Pinned Tab", and a pinned tab that has navigated away shows "Back to Pinned URL".
5. Add a **Copy Link as Markdown** ⌥-alternate, **Close Tabs Above** ⌥-alternate, and **Edit Pinned Page › Replace Pinned URL with Current**.
6. **PR peek** per §3.7.

## 10. Raw data (scratchpad only, never commit)

Everything is under `a local scratch folder (never committed)`:

- Tools: `dtool.swift` (AX dump, guarded moves), `rec.swift` (Dia-only SCK recorder), `snap.swift` (Dia-only periodic snapshots), `anal.py`, `swapan.py`.
- `ax*.txt`, `dia_strings.txt`, `rc3`–`rc8/` (timing frames), `prhover/` (release-note video, frames and crops), `demo/` (the user-demo snapshots).
- Captures that could have included other apps' windows were deleted.
