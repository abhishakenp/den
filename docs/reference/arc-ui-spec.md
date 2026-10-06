# Arc UI Spec: den's visual-fidelity reference

> Research snapshot, 2026-09-27. Decisions made later are in [ROADMAP.md](../../ROADMAP.md) / [FEATURES.md](../FEATURES.md).

> **Reference only. Do not copy.** den must not include any Arc or Dia assets, icons, sounds, fonts, videos, Lottie files or proprietary artwork, and must not copy asset-catalog entries wholesale. This file records **measurements**, meaning numbers, colors, timings and structure, so den can reproduce the *feel* with its own assets. The UI copy quoted here may inspire den's wording, but den should write its own text. Screenshots and recordings stay in the scratchpad and never go into this repo.

- **Measured:** 2026-09-27, macOS 26 (Darwin 25.5), 2x Retina display (1470x956 pt), dark appearance.
- **Arc** 1.166.0 (87668), `company.thebrowser.Browser`, LSMinimumSystemVersion 13.0.0. Downloaded from `https://releases.arc.net/release/Arc-latest.dmg`, which redirects to `Arc-1.166.0-87668.dmg`.
- **Dia** 1.50.1 (87750), `company.thebrowser.dia`, LSMinimumSystemVersion 14.0. Downloaded from `https://releases.diabrowser.com/release/Dia-latest.dmg`.
- Both were installed to the scratchpad `refapps/` folder. `/Applications` was not modified.

## Provenance tags

| Tag | Meaning |
|---|---|
| **AX** | Frame read from the Accessibility API while Arc was running: a custom Swift `AXUIElement` dumper, window at 1280x800 pt |
| **PX** | Pixel measurement on a `screencapture -o -l <windowID>` PNG (2 px = 1 pt). Corner radii were fit against reference profiles rendered with SwiftUI `Path(roundedRect:style:)` in both `.continuous` and `.circular` styles; the residual is noted |
| **REC** | `screencapture -v` screen recording, frames timestamped with `ffprobe` (about 60 fps, variable) |
| **VID** | Arc's own onboarding video in `ARC_WelcomeToArcFeature.bundle` (60 fps), frame-stepped |
| **CAR** | `xcrun assetutil --info` on the bundle's `Assets.car` |
| **STR** | `strings` on the binary. Value and translator comment are adjacent, so the pairing is reliable |
| **NIB** | Decoded from `MainMenu.nib` |
| **MENU** | Live menu read over AX (`AXMenuItemCmdChar`/`Modifiers`) |
| **AFINFO** | `afinfo` output |
| **LOTTIE** | Lottie JSON: `(op-ip)/fr` |
| **LIVE** | Observed on screen and read over AX while exercising the feature |
| **UNVERIFIED** | Not measured. Never fill these with a guess |

All coordinates are in **points, relative to the window's top-left**, unless noted.

---

## 1. Geometry: main browser window (Arc)

The window was 1280x800 pt, the sidebar was visible, and the theme was the default one from onboarding.

| Element | Value | Prov. |
|---|---|---|
| Traffic lights | Three 16x16 buttons at x = 12 / 35 / 58, y = 16 (23 pt pitch) | AX |
| Sidebar-toggle button | 32x32 at (77, 7) | AX |
| Back / Forward / Reload | 32x32 at x = 122 / 156 / 190, y = 7 (34 pt pitch) | AX |
| **Sidebar width (default)** | **228** (sidebar scroll area 228 wide; the content card starts at x = 228) | AX + PX |
| Sidebar min / max / reset width | UNVERIFIED (resize drag was blocked, see §12) | - |
| **URL pill** | **x 8–220 (212 wide), y 46–82 (36 tall)** | PX |
| URL pill corner radius | **12 pt** (fit residual 1 px) | PX |
| URL pill fill (dark) | Pixel (58,58,76) over sidebar (36,36,56). Equals `#FAFBFF` α0.10 composited, i.e. `SidebarItemBackground` dark | PX + CAR |
| URL pill search icon / text | Icon button 24x24 at (14, 52). Placeholder text starts at x = 41 (18 tall), and at x = 20 once a URL is shown | AX |
| Favorites empty-state card | 228x105 at y = 82, with a dashed border | AX, PX |
| Space title row | Icon 26x26 at (13, 200); name at x = 41 (18 tall); "More" button at x = 213 | AX |
| Pinned/Today divider | One 1 px line at @2x (0.5 pt) at y = 242. Color (71,69,86) equals white α0.15 (`SidebarSeparator`) | PX + CAR |
| **Tab row pitch** | **41 pt** (AXOutlineRow height 41; button 228x40) | AX |
| Tab favicon | 18x18 at x = 17, vertically centered | AX |
| Tab title | Starts at x = 43, text frame 19 tall | AX |
| **Selected-tab highlight** | **x 8–220 (212 wide), 36 tall, radius 12 pt** (`.continuous` fit, residual 0) | PX |
| Selected-tab fill (dark) | Pixel (81,80,96) over (39,37,55). Equals `#FAFBFF` α0.20 (`TabCellBackgroundCurrent` dark) | PX + CAR |
| "+ New Tab" row | 41 tall; icon 18x18 at x = 17; label at x = 43 | AX |
| Bottom bar | Library/Home button 32x32 at (8, 759); "+" (`sidebarPlusButton`) 32x32 at (188, 759); Space-switcher strip 144x50 at (42, 750) | AX |
| **Content card inset** | **Top 10, right 10, bottom 10. Left is flush against the 228 sidebar** (card spans x 228–1270, y 10–790) | PX |
| **Content card corner radius** | **6 pt** (fit residual 0; the 6.0 continuous and circular profiles are identical at this size) | PX |
| Card inset with sidebar hidden (Cmd-S) | 10 on every side (card left edge settles at x = 10) | REC |
| Window corner | macOS 26 system window. A bright 1 px rim runs along the top edge: (85,81,96), then (65,59,76), over (43,37,56) | PX |
| Favorites grid tile size | UNVERIFIED (no favorites existed) | - |
| Hover reveal zone when the sidebar is hidden | UNVERIFIED | - |
| Split View gap and pane radius | UNVERIFIED (see §12) | - |
| Peek window size | UNVERIFIED (see §12) | - |

### Typography (chrome uses the system font)

| Text | Measured | Prov. |
|---|---|---|
| Chrome font family | System font. `systemFontOfSize:weight:` appears in strings; the 85 bundled fonts serve only Boosts, Easels and Notes | STR |
| Tab title | Cap height 19–20 px @2x ≈ 9.5–10 pt, so **about 13.5 pt** (SF cap height 0.705 em); regular weight | PX (derived) |
| URL pill text | x-height 14 px @2x = 7 pt, so **about 13 pt** (SF x-height 0.526 em) | PX (derived) |
| Space title | Cap height 19 px, **about 13.5 pt**, semibold/bold (visual) | PX (derived) |
| Command bar input, dialog title, row text | UNVERIFIED (the rendered sizes were not cleanly isolated) | - |

## 2. Command Bar (Cmd-T / Cmd-L)

| Element | Value | Prov. |
|---|---|---|
| Presentation | A floating panel over the whole window, **horizontally centered on the window** (not the content card): outer x 257–1023 in a 1280 window, so center = 640 | PX |
| Outer size (5 rows + default-browser banner) | **766 x 328** pt, including a 1 pt border | PX |
| Top | y = 231 in an 800 pt window | PX |
| Border | 1 pt, two-pixel ramp (61,61,61) → (78,78,82) in dark | PX |
| Corner radius | **about 15 pt** (best fit 15.0; residual 7 px because of the border) | PX |
| Background (dark) | (28,27,34) | PX |
| Input row | Search icon 18x18 at x = 280 (window coords, abs 375−95); text field 656x23 starting at x = 310; trailing 26x26 info button | AX |
| **Suggestion row** | **50 pt tall, 750 wide**, inset 7 from the panel (AX). Favicon 16x16 at +16; title at +43; trailing "Switch to Tab" label (86 wide) plus a 21x21 arrow keycap | AX |
| Selected-row highlight | Inset 10 horizontally and 2 vertically inside the row (46 tall). **Radius 6 pt** (residual 0). Fill (65,72,216) in this theme; it looks tinted by the theme or accent, UNVERIFIED rule | PX |
| Banner (default-browser upsell) | 764x60 at the bottom. Buttons "Try for a week" (secondary, 110x38) and "Set Arc as default" (primary blue, 131x38), plus a close "x" (24x24) | AX, LIVE |
| Open/close animation | **None observed.** The panel appears fully formed in one frame (≤17 ms) and disappears in one frame on Esc | REC |
| Little Arc variant | Same component in a 490x329 window: text field 380x23, rows 474x50 | AX |

Colors (CAR, `ARC_CommandBar`):

| Token | Light | Dark |
|---|---|---|
| RowHoverBackground | #000000 α0.05 | #FFFFFF α0.05 |
| HairlineDivider | #000000 α0.10 | #FFFFFF α0.10 |
| TextPrimary | #000000 α0.80 | #FFFFFF α0.80 |
| TextSecondary | #000000 α0.33 | #FFFFFF α0.33 |
| AccessoryBackground | #000000 α0.05 | #FFFFFF α0.05 |
| BannerBackground | #FDFDFE | #161616 |

## 3. Colors and materials (Arc asset catalogs)

These are the tokens den should mirror *in spirit*. All come from CAR in `ARCClients_BaseAssets` unless noted. ✅ marks values also matched by PX on a live screenshot.

| Token | Light | Dark |
|---|---|---|
| TabCellBackgroundCurrent (selected tab) ✅ | #FFFFFF α0.85 | #FAFBFF α0.20 (P3) |
| TabCellBackgroundContentVisible | #FFFFFF α0.70 | #FAFBFF α0.15 |
| TabCellBackgroundPrevious | #FFFFFF α0.32 | #FAFBFF α0.08 |
| TabCellBackgroundPreviousHovered | #FFFFFF α0.50 | #FAFBFF α0.12 |
| TabCellBackgroundPressed | #0E0F10 α0.06 | #FAFBFF α0.06 |
| TabCellShadowSelected | #000000 α0.20 | clear |
| SidebarItemBackground (URL pill) ✅ | #0E0F10 α0.05 | #FAFBFF α0.10 |
| SidebarItemHoveredBackground | #0E0F10 α0.10 | #FAFBFF α0.15 |
| SidebarSeparator ✅ | #000000 α0.15 | #FFFFFF α0.15 |
| SidebarForeground | #000000 α0.30 | #FFFFFF α0.45 |
| SidebarBorderColor (Assets.car) | #FFFFFF α0.30 | #FFFFFF α0.30 |
| TabCellSlash ("/" drift marker) | #000000 α0.30 | #FFFFFF α0.30 |
| PopoverBackground ✅ (the quit dialog body measured (21,28,48) = #151C30) | #FAFBFF | #151C30 |
| PopoverShadow | #151C32 α0.30 | #151C32 α0.80 |
| BrandBlue / primary button ✅ (Quit button measured (49,57,251)) | #3139FB | same |
| DestructiveButtonFace | #F53714 (hover #DD3112, pressed #D02F11) | - |
| FocusRing | #458AFF | same |
| LoadingPageBorder | #0C50FF | #2AB6F6 |
| ForegroundPrimary / Secondary / Tertiary | #0E0F10 α0.90 / #000 α0.50 / #000 α0.30 | #FFF α0.80 / α0.50 / α0.30 |
| CommandBarPlaceholderText / PlaceholderPlaceholderText (Assets.car) | #000 α0.60 / α0.30 | #FFF α0.60 / α0.30 |
| LittleBrowserCommandBarPlaceholderBackground | #0E0F10 α0.06 | #FAFBFF α0.10 |

Other color facts:
- **Appearance variants:** only light ("any") and DarkAqua exist; no high-contrast variants (CAR).
- **Material:** Arc uses **no system vibrancy** for the sidebar. It draws a themed gradient, rendered by `WindowThemeBackgroundViewMetal`, with a grain overlay. The grain textures `grain-1`…`grain-4` are 2100x1500 (CAR `ARCUI`); the noise styles are denim, sand, tweed and grain (CAR `ARC_WindowThemeUI`).
- **Default-theme sidebar pixels (dark):** (41,36,56) near the top, (44,37,56) lower down. It is a gradient (PX).
- **Modal dim:** under the quit dialog, the content card's (238,238,238) became (107,107,107), which is **black α ≈ 0.55**. The sidebar's (44,37,56) became (30,26,34), a different factor, so the sidebar is dimmed separately (PX).
- **Page CSS variables Arc injects:** `--arc-palette-{background,cutout,focus,foreground,hover,max,min,subtitle,title}` and `--arc-background-gradient-color` (STR).

### Theme picker palette (CAR; 9 swatches per page, 5 pages)

- **Brand:** #F2EAE4, #F29BBB, #A6729D, #F25E6B, #FF3C19, #F2D66D, #73E59C, #7EB8D6, #666786
- **Pastel:** #FDFBFA, #FBEAF3, #ECD2EA, #F7CDD2, #FAE1D5, #FEF9E7, #E4FCEC, #E0F2FB, #C5C6E2
- **Drab:** #4B3B58, #623856, #854444, #A77048, #D1B46A, #CDCCA8, #84A885, #34604B, #2D4468
- **Greyscale:** #FFFFFF, #E5E5E5, #CCCCCC, #B2B2B2, #808080, #666666, #333333, #1A1A1A, #000000

The AX order observed live was Brand, Brand again, Pastel, Drab, Greyscale.

## 4. Theme picker (Spaces > Edit Theme…)

| Element | Value | Prov. |
|---|---|---|
| Source | PX rows below were measured on `arc_theme_picker.png` (empty state, dark), in body coordinates | - |
| Container | AXPopover window 382x534 (13 pt shadow margin); visible body **356x508**, anchored just right of the sidebar (body x = 241) | AX, PX |
| Corner radius | **20 pt, continuous** (residual 0) | PX |
| Mode buttons (Automatic / Light / Dark) | Three 32x32 buttons, 40 pt pitch, centered at the top. They animate with Lottie: sun 1.0 s, moon 1.5 s, automatic 1.5 s (60 fps) | AX, LOTTIE |
| Color pad | "DotGrid" 340x340, inset 8. Empty state reads "Tap to pick a color for this space" | AX, LIVE |
| Add / Remove color | Two 32x32 buttons at the bottom of the pad | AX |
| Swatches | 24x24, 29.5 pt pitch, 9 visible; previous/next page buttons 32x32 | AX |
| Noise button ("Cycle noise texture") | 84x36 | AX |
| Intensity slider | 224x44 (a wavy track) | AX, PX |
| Knobs | DenimKnob / GrainKnob / SandKnob / TweedKnob, 56x56 | CAR |
| Haptics | The release notes say the Theme Picker gives haptic feedback. Not observable here: UNVERIFIED | - |
| Body fill (dark, no color picked) | (86,86,87); the pad is about 6 levels lighter | PX |
| Pad | Corner radius about 7 pt (rough fit). Dot grid: 1 pt dots at a 4.25 pt (8.5 px) pitch, white α≈0.27 (134 over 90) | PX |
| Mode buttons | Selected button at (122, 32), fill white α≈0.12 (113 over 94) | PX |
| Empty-state label | Centered at y = 178, 204 pt wide, which matches SF 13 pt semibold exactly | PX |
| Remove / add color | Centers (158, 316.5) and (198, 316.5); dimmed to white α≈0.21 while disabled | PX |
| Swatch row | Centers at y = 380.5, first x = 60; a 1.5 pt rim darker than the swatch; page buttons centered at x = 23.5 / 332.5 | PX |
| Intensity slider | Track x 18–242, 20 pt tall pill, white α≈0.08; wave stroke about 5 pt, white α≈0.21, period about 32.5 pt, amplitude about 12 pt | PX |
| Grain dial | Center (298, 452); inner circle r = 20.5 (1 pt, white α≈0.15); ring of dots at r ≈ 32.5 | PX |

## 5. Dialogs and alerts

**Style (Arc):** Arc does **not** use a stock NSAlert look. The quit dialog is an AXSheet hosted in SwiftUI, centered on the window, over a dim. Each button shows its keyboard shortcut as a keycap ("ESC", "↩").

### Quit (Cmd-Q) ✅ LIVE

A single press of Cmd-Q shows this dialog. It is **not** hold-to-quit.

| Part | Value |
|---|---|
| Container | Sheet 450x248, centered in a 1280x800 window (x 415–865, y 276–524), radius **26.5 pt continuous** (PX), background #151C30 (PX) |
| Icon | App icon 62x62 at (38, 38) inside the dialog (AX) |
| Title | **"Quit Arc?"** at (38, 117). No message text (LIVE) |
| Buttons, left to right | **"Quit, and don’t ask again"** (176x37, secondary: fill (48,47,99) with a border); **"Cancel"** with an ESC keycap (110x40, the cancel button); **"Quit"** with a ↩ keycap (86x38, primary #3139FB, the default button). Cancel and Quit sit 7 pt apart (AX/PX) |
| Button styling (PX, dark) | Secondary and Cancel: fill (48,47,99) with a 1 pt (99,98,174) border. Keycaps are white α≈0.12 over their button: (78,76,122) on Cancel, (70,77,251) on Quit. Corner radius about 6 pt. Labels are SF 13 regular ("Quit, and don’t ask again" is 150 pt of ink); "ESC" is about 10 pt bold. Side padding 12.5 pt, 8 pt from label to keycap. The row sits 27.5 pt from the sides and bottom; the secondary button is left-aligned |
| Title (PX) | "Quit Arc?" has a 13 pt cap height, so about SF 18 medium |
| Suppression | Offered as a **button**, not a checkbox. It is controlled by the "Warn before quitting" setting (STR) |
| Dim | Card behind it darkened to black α≈0.55 (PX) |
| Downloads variant | Title "Downloads in progress"; message "There are downloads in progress. Closing the application will cancel them."; buttons cancel + confirm (STR) |

### Close window (Shift-Cmd-W)

- **No confirmation.** During testing, a browser window with tabs closed with no dialog. Tabs are shared across windows, so nothing is lost (LIVE; no string exists either, STR).
- **Cmd-W archives the current tab** (menu "Archive Tab ⌘W"). The window's title went from "Example Domain" to "Space 1" with no prompt (LIVE, MENU).

### Move tab to another Space

- **No dialog.** Moving is a Command Bar action: "Move to Today in <space>", "Move to Pinned in <space>", "Move to Top Apps" (STR).
- Toasts: "Pinned Tab to %@", "Un-Pinned Tab from %@", "New Space Created" (STR).

### Delete Space (STR; not exercised live)

- Title: "Delete your %@ Space?"
- Message: "This will archive all the tabs and folders inside it."
- Buttons: destructive (the Delete label is stored inline, so its text is UNVERIFIED) + Cancel.
- The deletion is undoable with Cmd-Z.

### Delete folder (STR)

- Title: "Delete your %@ folder?"
- Message: "Deleting this folder will archive the tabs inside it."

### Delete Live Folder (STR)

- Title: "Delete your %@ Live Folder?"
- Message: "You can restore this folder at any time by right-clicking the sidebar."

### Clear unpinned tabs (Cmd-Shift-K) ✅ LIVE

- **No dialog.** The tabs clear instantly and a toast offers undo (§6).
- Cmd-Z restored all the tabs (LIVE).
- The active tab stays in place.

### Clear Archive (STR)

- Title: "Are you sure you'd like to Clear Archive?"
- Message: "This action is permanent."

### Auto-archive scope change (STR)

- Title: "Arc will now archive your tabs after %@", or "Arc will never auto-archive your tabs."
- Message: "Would you like to apply this change to all of your Profiles, or only your %@ Profile?"
- Buttons: all profiles / "Only this Profile".

### Change a Space's Profile (STR)

- Body: "Each Profile has different browser data, so you might get logged out of some websites, see different Favorites up top, or need to re-install extensions."
- It has a "Don’t ask again" option.

### Delete Profile (STR)

- Title: "Delete this Profile".
- Uses a **type-the-name confirmation**: "To continue, please type the name of this Profile:".
- Rules shown: "The Default Profile cannot be deleted." and "Only Profiles not assigned to any Spaces can be deleted."

### Other alerts (STR)

- **Update:** "Arc is ready to update!" / "Restart required."
- **Sync conflict:** "Syncing Conflict!" with buttons "Merge data (recommended)", "Use what’s on my computer" and "Revert to what’s in iCloud".
- **Boost delete:** "Delete this Boost?" / "This can’t be undone."
- **Sad tab:** "Tab crashed. Maybe [reload] the page?"
- **Permission prompts:** "Allow %@ to access your %@?" and similar, with the footer "Click the lock to change this any time".

### Dialog hero icons

- Size 76x76 (CAR `icon-archie-*`, `icon-dialog-*`).

Full copy for every dialog is in the scratchpad notes: `notes_arc_copy.md`.

## 6. Toasts and banners

| Item | Value | Prov. |
|---|---|---|
| Toast host | A separate transparent 600x600 window **anchored to the browser window's top-right corner**: its right edge is aligned with the window's right edge and its top with the window's top | LIVE (CGWindowList) |
| Clear-tabs toast copy | **"Cleared Tabs! Use [⌃Z key] to undo."** The ⌃Z is drawn as a keycap view (`ToastBigKeyView`). Text starts at (1039, 19) window-relative | LIVE, AX, STR |
| Toast lifetime | Gone within about 2–3 s (it had disappeared by the next AX poll). Exact duration UNVERIFIED | LIVE |
| Toast styling | Theme-tinted: `ShinyToastBackgroundBasedPalette` blends the Space gradient's average color. Components: `ToastAnimator`, `UndoableToastContentView`, `ToastConfirmButton` | STR |
| Other toast copy | "Copied Current URL" / "Copied a clean link without trackers"; "Auto archived %d tabs"; "Tab restored to %@"; "Cannot Add New Pane"; "To exit full screen, press %@"; "Screenshot Copied to Clipboard"; "Download renamed!" | STR |
| Sidebar update banner | "An update is ready!" / "Click to restart" / "Restart and Update"; afterwards "Update Complete!" with "See What’s New". Heart Lottie 2.0 s | STR, LOTTIE |
| Favorites empty state (sidebar) | Star icon 16x16; title "Drag to add Favorites"; body "Favorites keep your most used sites and apps close"; dismiss "x" 14x14; dashed rounded border | LIVE, AX |
| Empty Space content | Keycap art "⌘T" 62x46; title "Open your first tab."; body "Click New Tab or press ⌘T to open the Command Bar and create your very first tab in Arc." | LIVE, AX |
| Command-bar banner | "Arc works best as your default browser" with "Try for a week" / "Set Arc as default" | LIVE |

## 7. Motion and animation

| Motion | Measured | Prov. |
|---|---|---|
| Command Bar open / close | **Instant**: 1 frame, no fade or scale seen at about 60 fps | REC |
| **Sidebar hide (Cmd-S)** | **About 67 ms (4 frames), strong ease-out.** Card left edge per frame: 228 → 57 → 27 → 14 → 10 | REC |
| **Sidebar show (Cmd-S)** | **About 83 ms (5 frames), ease-out.** Card left edge: 10 → 119 → 177 → 209 → 225 → 228 | REC |
| Clear tabs sweep | Titles vanish in 1 frame; favicons drop and fade over about 3–4 frames (50–67 ms) | REC |
| **Space switch (click on a Space icon)** | **Web content swaps in 1 frame (no crossfade). The sidebar slides and settles over about 280–300 ms** with decaying per-frame motion (spring-like). Two separate switches measured: 2.333→~2.62 s and 4.833→~5.10 s | VID `space_swiping.mp4` |
| Dialog appear | UNVERIFIED (the first capture came 300 ms after the keypress and showed the dialog already settled) | - |
| Library icons | Lottie at 60 fps: archive 2.0 s; spaces, screenshots, easels, downloads and boosts 1.0 s | LOTTIE |
| Named constants in the binary (values not readable) | `clearAnimationDuration`, `springResponse`, `horizontalInsetAnimation`, `contentCornerRadius`, `cardCornerRadius`, `sidebarWidth`, `windowTrafficLightZoneRect` | STR |
| Toast in/out, Peek open, split add, hover-reveal sidebar | UNVERIFIED | - |

Timings were measured from a local screen recording of Cmd-T, Esc, Cmd-S ×2 and Cmd-Shift-K. The recording was deleted afterwards because it had captured another app's video.

## 8. Little Arc (Cmd-Opt-N) ✅ LIVE

| Element | Value | Prov. |
|---|---|---|
| Initial state | Command-bar-only window, **490x329**, placed **20 pt from the screen's right edge and 20 pt below the menu bar** (x = 960, y = 53 on a 1470-wide screen) | CGWindowList, AX |
| After loading a URL | Window grows to **1185x832** at (265, 53); the right edge stays 20 pt from the screen edge | AX |
| Chrome | **47 pt top bar**; traffic lights at (9, 15); site icon 16x16 at (91, 15); **centered domain text**; link/copy button 16x16; button **"Open in Space 1 ⌘O"** (133x17) | AX, PX |
| Content | **Full-bleed web view below the bar (no inset card)**: 1185x785 | AX |
| Side controls | "Close" and "Enter Full Screen" buttons, 34x33, at the right | AX |
| Window role | AXSystemDialog (a floating panel), not a standard window | AX |

## 9. Keyboard shortcuts

These are the defaults, read from the live menus (MENU) and the nib (NIB); the two agree. All can be remapped in Settings > Shortcuts.

| Action | Keys |
|---|---|
| New Tab / Command Bar | ⌘T |
| Open Command Bar (edit URL) | ⌘L |
| New Window / Blank Window / Incognito | ⌘N / ⌃⌘N / ⇧⌘N |
| New Little Arc Window | ⌥⌘N |
| Restore Last Closed Tab | ⇧⌘T |
| **Archive Tab** | **⌘W** |
| **Close Window** | **⇧⌘W** |
| New Note / New Easel | ⌃⇧N / ⌃⇧E |
| Capture… | ⇧⌘2 |
| Save Page As / Print | ⇧⌘S / ⌘P |
| Undo / Redo | ⌘Z / ⇧⌘Z |
| Copy URL / as Markdown / as Quote | ⇧⌘C / ⌥⇧⌘C / ⌃⇧⌘C |
| Paste and Match Style | ⇧⌘V |
| Find / Find and Replace / Next / Previous / Jump to Selection | ⌘F / ⌥⌘F / ⌘G / ⇧⌘G / ⌘J |
| Show/Hide Sidebar | ⌘S |
| Show/Hide Toolbar | ⇧⌘D (NIB) |
| Stop / Refresh / Force Refresh | ⌘. / ⌘R / ⇧⌘R |
| **Add Split View / Close Split Pane** | **⌃⇧= / ⌃⇧-** |
| Reveal Current Tab | ⌃Space (NIB) |
| Zoom Actual / In / Out | ⌘0 / ⌘+ (⌘=) / ⌘- |
| View Source / DevTools / Inspect / JS Console | ⌥⌘U / ⌥⌘I / ⌥⌘C / ⌥⌘J |
| Toggle Developer Mode | ⌃D |
| Enter/Exit Full Screen | ⌃⌘F |
| Exit (Peek, fullscreen…) | ⎋ |
| Next / Previous Space | ⌥⌘→ / ⌥⌘← |
| Space N | ⌃1…⌃9 (MENU showed "Space 1 ⌃1") |
| Next / Previous Tab | ⌥⌘↓ / ⌥⌘↑ |
| Cycle Tab fwd/back | ⌃⌘→ / ⌃⌘← (NIB) |
| Tab switcher | ⌃Tab / ⌃⇧Tab (NIB) |
| Pin/Unpin Tab | ⌘D |
| Open Little Arc or Peek in… | ⌘O |
| Clear Unpinned Tabs | ⇧⌘K |
| Peek Email… / Join Meeting / New ChatGPT Message | ⇧⌘E / ⌃⌘J / ⌥⌘G (NIB) |
| Back / Forward | ⌘[ / ⌘] (also ⌘← / ⌘→) |
| View History | ⌘Y |
| View Library / Downloads | ⇧⌘L / ⇧⌘J |
| Settings | ⌘, |
| Quit | ⌘Q (shows the dialog in §5 while "Warn before quitting" is on) |

- **⌘1…9 (tab N, Favorites first)** is bound in code, not in the menus. Its key set is UNVERIFIED from resources; see `docs/research/arc.md` §15.
- The Window menu's Fill (⌃F), Centre (⌃C) and Move & Resize (⌃arrows) items are **macOS 26 system items**, not Arc's.

## 10. Sounds and haptics

| Item | Value | Prov. |
|---|---|---|
| Sound files (Arc) | `ARC_SoundEffects.bundle` holds only 2 files: `capture.wav` (LPCM 24-bit, 48 kHz, 0.634 s; name suggests Capture) and `event.m4a` (AAC, 3.522 s; event UNVERIFIED) | AFINFO |
| Onboarding music | `intro-music.mp3` (21.336 s) | AFINFO |
| Toggle | "Play Arc sound effects" (Settings > Advanced) | STR |
| Haptics | "Haptic feedback when reordering tabs". API names: `isDragDropHapticFeedbackEnabled`, `dropHapticSubject`, `performsPageDetentHaptics` (via NSHapticFeedbackPerformer) | STR |
| Event → sound mapping | UNVERIFIED (audio was not captured) | - |

## 11. Settings copy worth mirroring (STR)

- **Archive tabs after:** never / 30 days / 7 days / 24 hours / 12 hours (default) / 6 hours / 1 hour. The exact label casing is UNVERIFIED. The onboarding/EDU banner reads: "Arc archives tabs that you haven’t used in the past 12 hours. You can adjust this in Settings."
- **Links:** "Open a Peek window when clicking on links to other sites" (applies to Favorites and Pinned tabs only); "Links from other apps open in Little Arc"; "Archive Little Arcs after:".
- **Advanced:**
  - "Allow window dragging from the top of webpages"
  - "Show full URL when Toolbar is enabled"
  - "Enable Picture in Picture when you leave a video tab"
  - "When opening Arc, restore windows from previous session"
- **Shortcut conflict policy:**
  - "When shortcuts conflict, Arc wins."
  - "Press this shortcut once to use the website’s shortcut. Press it twice to use Arc’s shortcut."
  - "When shortcuts conflict, the website wins."
- **Onboarding titles (LIVE + STR):**
  - "Create an account"
  - "Add some flair with a theme." / "Pick a color, any color—add your favorite shade to your new home on the internet." (buttons "Next", "Skip for now", "← Back")
  - "Choose the apps you use most."
  - "No more ads or trackers."
  - "Go steady with Arc?"
  - "Welcome to Arc, %@"

## 12. What could not be measured, and why

1. **Focus contention.** During the session another app (Slack) kept taking focus, so the user was probably active.
   - A keystroke-driven step sent Cmd-L, typed "example.com" and pressed Return, and those keys went to Slack instead of Arc. A screenshot afterwards showed Slack's message composer empty, and no stray message was visible in the open channel.
   - After that, all input was sent only through a guard that checks the frontmost app. Interactive testing then stopped.
   - That blocked Peek, Split View (gap and radius), sidebar resize min/max, the hover-reveal zone, favorites tile size, Space creation and deletion (and the delete-Space dialog render), the archive view, toast timing and dialog-appear timing. All of these remain **UNVERIFIED**.
2. **Arc sign-up.** Arc opened on "Create an account". Onboarding then advanced **without our input**: the form was already filled with a name and email (abhi / abhi@gmail.com) and moved on to the theme step and the main window. We never typed credentials.
3. **Dia requires an account.** It stops at "Welcome to Dia" asking for a "Work email", so no live Dia measurements were possible beyond the onboarding window (928x544). The Dia data below is static.
4. **Audio.** Not captured.
5. **Leftover state.** `~/Library/Application Support/Arc` and `.../Dia` now hold profile data from these runs. Both apps were stopped at the end of the session.

## 13. Dia: where its polish beats Arc's (shorter)

**Method.** Static only (see §12), in Dia 1.50.1. Tags: STR, CAR, AFINFO, LOTTIE, plus literal CSS tokens from Dia's bundled web surfaces (**CSS**).

| Area | What Dia does | Prov. |
|---|---|---|
| Dialogs | Its own dialog panel window (`Dialog/DialogPanelWindowController.swift`), not NSAlert. Peek is built on the same module | STR |
| Dialog copy pattern | Each destructive dialog states its scope and reassures about what is **not** affected. Examples: "This will delete all your stored assistant conversations. This cannot be undone." + "Your browser history will not be affected by this."; "You may be logged out or lose progress in this tab." Whole-profile deletion requires typing the name | STR |
| Quit | Message: "You may lose unsaved work in your tabs." Button: "Always quit and don't present dialog again". Settings: "Warn before quitting" and "Warn before closing last tab in a Profile" | STR |
| Quit with downloads | Count-aware: "You have 1 download in progress. If you quit now, this download will be cancelled." / "…%d downloads…" | STR |
| Toasts | Separate windows with a `ScaleInEffect` entrance and theme-blended gradient colors (`ToastColorPalette`, `blend(withFraction:of:)`). Undo suffix "⌃Z to Undo." | STR |
| Command bar | Three modes tint the input: Go (URL), Search, Assistant. The **cursor and selection color change by mode**: Search cursor (0.388,0.584,0.988) light / (0.290,0.467,0.831) dark; Assistant cursor amber (0.988,0.749,0.286). Assistant mode has its own hover tint (amber α0.08 / 0.12) | CAR |
| Tabs | Debossed selected/unselected treatment (`DebossedView`, `InnerShadowLayer`). Selected tab: white 1.0 (light) / black 1.0 (dark); hovered: white 0.55 / white 0.16; unselected: black 0.06 / white 0.06; selected shadow: black 0.12 / white 0.15 | CAR, STR |
| Window tint | Layered: base tint white 0.80 / black 0.40, plus a gradient overlay (1,1,0.843)→(1,0.851,0.984) at α0.30 (light) or (0.318,0.424,0.828)→(1,0.851,0.984) at α0.18 (dark) | CAR |
| Opacity ramp | A single ramp `Primary0…1300`: 1, .95, .90, .85, .80, .75, .60, .53, .46, .30, .22, .18, .12, .09, .05 (black in light, white in dark) | CAR |
| Web-surface tokens | Radii: dialog 20, bubble 17, code 12, card 10, pill 999. Shadow `0 8px 28px` #0000001A (light) / #00000061 (dark). Springs 0.695641 s (fast) / 1.11303 s (slow). Curves cubic-bezier(.2,0,0,1), (.2,.8,.2,1), overshoot (.34,1.56,.64,1). Height transitions .18 s ease | CSS |
| Sounds | 14 files: click1–4 (0.133–0.210 s), pop 0.070 s, chime 0.803 s, response_done 4.083 s, response_question 2.022 s, ticket 3.283 s, shimmer 1.631 s, welcome 1.815 s, presents 5.063 s. Event mapping is inferred from names only (UNVERIFIED). Separate toggles for chat sounds and report sounds | AFINFO, STR |
| Onboarding window (live) | 928x544. Serif display title "Welcome to Dia"; a single email field plus a "Let’s go ↩" button (keycap-in-button, like Arc's dialog buttons); three feature rows with 33x26 icons | AX, LIVE |

**Takeaways for den** (inferences, not measurements):
- Custom dialog panels with keycap hints.
- Mode-colored caret and selection in the command bar.
- Scope and reassurance lines in destructive dialogs.
- Count-aware quit copy.
- Undo toasts instead of confirmations for reversible actions. Arc and Dia both do this.

## 14. Screenshots and raw data (scratchpad, never commit)

- `…/scratchpad/shots/`:
  - `arc_main_1.png`, `arc_main_page.png`
  - `arc_commandbar_empty.png`, `arc_commandbar_typed.png`
  - `arc_quit_dialog.png`
  - `arc_theme_picker*.png`
  - `arc_littlearc_empty.png`, `arc_littlearc_page.png`
  - `arc_clear_*.png`
  - `arc_signin1.png`, `arc_signin2.png`
  - `dia_82107.png` (Dia onboarding)
- The animation recording was deleted (it had captured another app's video).
- `…/scratchpad/arc_ax_*.txt` (AX dumps), `arc_menus.tsv` (live menu shortcuts)
- `…/scratchpad/notes_arc_copy.md`, `notes_arc_assets.md`, `notes_dia.md`, `arcassets/*.json`, `dia_cars.txt`

The scratchpad root is `/private/tmp/claude-501/-Users-abhi/d1bd7a53-a037-498e-9865-1f87affccae9/scratchpad`.
