# Arc (macOS): Feature and Interaction Inventory

> Research snapshot, 2026-09-27. Decisions made later are in [ROADMAP.md](../../ROADMAP.md) / [FEATURES.md](../FEATURES.md).

Research for **den**, a WebKit/AppKit browser whose UX tracks Arc as closely as it can.
Compiled 2026-09-27.

## How this was researched

- **Primary source:** the Arc Help Center (resources.arc.net). The HTML pages return 403 to scripted fetches, so all 118 articles were pulled through the public Zendesk API (`https://resources.arc.net/api/v2/help_center/en-us/articles.json`). That includes the full macOS release notes for 2021, 2022, 2023 and 2024–2026. Unless a statement is tagged otherwise, it comes from these articles.
- **Secondary sources:** the Browser Company's letter to members, Wikipedia, reviews and blog posts. Each section cites its sources.
- **UNVERIFIED** marks a claim that could not be confirmed from a primary source, or that came only from a third party.
- Arc names its unpinned tabs three ways. They were "Explore" in 2021, then "Unpinned", and later "Today Tabs" in the Arc Max copy. All three mean the same thing.

---

## 0. Status (as of Sept 2026)

- **Maintenance mode since May 27, 2025.** No new features have shipped since then. Arc still gets roughly weekly builds that only bump Chromium and apply security fixes.
  - Latest build seen: **macOS V1.166.0, Sept 24, 2026, Chromium 154.0.8037.58**. The release note reads "Nothing else along for the ride this week".
- **Arc Max "Ask On Page" was removed in V1.110.0 (Aug 28, 2025).** The same note points users to Dia ("For advanced AI browsing, try Dia at diabrowser.com").
- **Atlassian acquisition:** announced Sept 4, 2025 at $610M and closed Oct 21, 2025. These dates come from SupaSidebar and Wikipedia, not a primary source.
- **Why Arc was frozen** (Josh Miller's 2025 letter):
  - Arc was "too different, with too many new things to learn, for too little reward".
  - Only **5.52%** of DAU regularly used multiple Spaces, **4.17%** used Live Folders and **0.4%** used Calendar Preview on Hover.
  - Arc will not be open-sourced in a meaningful way, because it depends on the proprietary "ADK" (Arc Development Kit).
- **Platforms:**
  - macOS public release: July 25, 2023. Earlier builds were invite-only; the 2021 release notes exist.
  - Windows GA: April 30 / May 2, 2024.
  - Arc Search (iOS, then Android). Browse for Me exists **only in Arc Search on mobile**, not on desktop.
- **No sunset date has been announced**, and there is no open-source plan.

Sources:
- https://resources.arc.net/hc/en-us/articles/20498293324823-Arc-for-macOS-2024-2026-Release-Notes
- https://browsercompany.substack.com/p/letter-to-arc-members-2025
- https://en.wikipedia.org/wiki/Arc_(web_browser)
- https://supasidebar.com/blog/arc-browser-status-tracker
- https://resources.arc.net/hc/en-us/articles/20887042551831

---

## 1. Window model and chrome

**No top chrome by default.** All browser UI lives in a left sidebar: URL, back/forward/reload, extensions, tabs and Spaces. The web page sits in the remaining area as an inset card with rounded corners.
- **UNVERIFIED:** exact corner radius and inset padding. No primary source gives numbers, so measure from screenshots.

### Sidebar layout, top to bottom

1. **Traffic lights and nav buttons** (back, forward, reload) in the sidebar header.
2. **URL / "address bar" pill.**
   - Shows a simplified URL (domain), not the full URL.
   - Holds the Site Control Center icon, which covers extensions, Boosts, site settings, PiP toggle, Developer Mode, Share Quote and Copy Link.
   - Pinned extensions appear on hover over the URL bar. They were moved there in V1.19.1, Nov 30, 2023.
   - The loading indicator lives in the address bar at the top of the sidebar (2021 notes).
3. **Favorites grid:** icon tiles, up to 12 (raised from 8 in Jan 2023). They show in every Space.
4. **Space title**, with hover actions: edit (theme, icon, profile, rename) and share. A caret collapses the pinned section.
5. **Pinned tabs and folders.**
6. **Divider line**, with a "Clear" action beside it. It replaced the "Explore" header in May 2022.
7. **"+ New Tab" row**, then the **unpinned (Today) tabs**. The Tidy Tabs broom icon sits here when Arc Max is on.
8. **Bottom bar:**
   - Library icon (bottom-left)
   - Space switcher icons/dots
   - "+" button: new Space, Folder, Easel, Boost, etc. The New Tab button moved to the bottom in Sept 2021.
   - The audio / media controller appears above this bar.

### Sidebar behavior

- **Resizable:** drag the edge; double-click the edge to reset to the default width (2021–2022 notes).
- **Hide/show:** Cmd-S. Dragging the width all the way left also collapses it (2024 notes).
- **When hidden:** hovering the left screen edge slides the sidebar in as an overlay. This comes from third-party writeups; the exact hover-zone width is **UNVERIFIED**.
- **Window dragging:**
  - Drag the window from empty sidebar space (2022).
  - Drag it from the top strip of web pages. This can be toggled in Preferences (V0.102, May 2023).
  - Double-clicking empty sidebar space opens a new tab.

### Optional Toolbar

- View > Show Toolbar, or Cmd-Shift-D. It gives a classic top URL bar and room for more pinned extensions.
- Separated from web content by a subtle divider (V1.36, Mar 2024).
- With the toolbar on, a setting shows the full URL.

### Sidebar on the right

**Not supported.** Josh Miller (Nov 2023) said they prototyped it but found it ergonomically inefficient "bc gravity of URLs is always top-left". No release note mentions a right-sidebar option.
- For den this is an opportunity: a user request Arc declined.

### Windows and tabs

- **Shared tab identity:** Cmd-N opens another window on the same Spaces and tabs.
  - A tab exists once across windows ("Tab Handoff", V1.19.1): only one instance of each tab loads, and each window keeps its place.
  - Unpinned tabs briefly became per-window in May 2023, then went back to syncing across windows and devices in V1.5.0 (Aug 2023).
- **Blank Window:** Ctrl-Cmd-N, or Cmd-T then "new blank window". It is a separate, independent window. Dragging a tab out of the sidebar also creates a new window that keeps the tab in place.
- **Incognito:** Cmd-Shift-N.
- **Developer Mode:**
  - Shows the full URL bar across the top, plus dev shortcuts.
  - Auto-installs a JSON Formatter extension.
  - Draws a **yellow-and-black outline** when focused.
  - Turns on automatically for localhost and its subdomains.
- **Status pill:** hovering a link shows a bottom status pill. After 1.5 s it shows the full URL. It moves away if the cursor approaches.
- **ESC and fullscreen:** ESC prefers websites (the "Prefer Websites" default). Hold or double-tap ESC to exit fullscreen.

Sources:
- https://resources.arc.net/hc/en-us/articles/25619487530519
- https://resources.arc.net/hc/en-us/articles/25625458052247
- https://resources.arc.net/hc/en-us/articles/25590417429783
- https://resources.arc.net/hc/en-us/articles/20468488031511-Developer-Mode-Instant-Dev-Tools
- https://resources.arc.net/hc/en-us/articles/19434259167767
- https://x.com/joshm/status/1724508113208754356
- The four release-notes articles (20498293324823, 20498377604887, 20498417809815, 20498463803799)

---

## 2. Tabs: Pinned vs Today (Unpinned) vs Favorites

| Type | Scope | Archives? | Notes |
|---|---|---|---|
| **Favorites** | All Spaces (per Profile) | Never | Icon grid at the top. Max 12. Pinned tabs that span every Space. Reset to their original URL. |
| **Pinned** | One Space | Never | Above the divider. "Cross between an App and a Bookmark". Folders allowed. Collapsible (macOS). |
| **Unpinned / Today** | One Space | Yes, auto-archive | Below the divider and "+ New Tab". Cleared with Cmd-Shift-K ("Clear"). |

### Pinned and Favorite tab behavior

- **"App-like" containment:** clicking a link to *another site* from a pinned or favorite tab opens it in **Peek** instead of replacing the tab (see §6).
- **Reset:**
  - Pinned and favorite tabs remember their original URL.
  - Once you navigate away, a **slash "/"** appears next to the tab name.
  - Clicking the favicon resets the tab to the pinned URL.
  - Cmd-T "Reset Tab" does the same.
- **Edit the pinned URL:** right-click > Edit Pinned Page > "Replace Pinned URL with Current" or "Edit…".
- **Pin/unpin:**
  - Cmd-D.
  - Drag across the divider line.
  - Drag above the Space title to make it a Favorite.
  - Right-click > Move To > Favorites or a section.
- **Duplicate:** right-click > Duplicate, or Option-drag. Duplicating also copies the tab's history.
- **Rename:** double-click or right-click a tab. Custom emoji icons are supported, including skin tones and an emoji search picker. Folders have icons too.
- **Arc does not have bookmarks.** Pinned tabs and folders take their place. Imported bookmarks become pinned tabs, and pinned tabs cannot be exported (only "Copy All Links" on a folder).

### Other tab behaviors

- **Live Calendar:** a Google Calendar Favorite shows a countdown timer and a "Join" button in the sidebar.
- **Animated icons:** music-site Favorites animate their icon while audible (2022).
- **Google Meet:** Favorites that are being shared in a video call get a badge. A "Share This Tab Instead" button appears on sidebar tabs while screen-sharing.
- **Multi-select:** Shift-click, then right-click for "Share Items", new nested folder, and so on. Cmd-W closes every selected tab.

Sources:
- https://resources.arc.net/hc/en-us/articles/19231060187159-Pinned-Tabs-Tabs-you-want-to-stick-around
- https://resources.arc.net/hc/en-us/articles/19230755904151-Favorites-Top-Tabs-Across-Every-Space
- https://resources.arc.net/hc/en-us/articles/25625148480279
- https://resources.arc.net/hc/en-us/articles/25541939922199
- https://resources.arc.net/hc/en-us/articles/19400407903767
- https://resources.arc.net/hc/en-us/articles/25583851606039
- https://resources.arc.net/hc/en-us/articles/24158102740631-Live-Calendars

---

## 3. Auto Archive and the Archive

- **What gets archived:** idle unpinned tabs, **after 12 hours by default**. Viewing or clicking a tab resets its timer.
  - Auto Archive shipped Dec 1, 2021.
  - Pinned tabs, Favorites and tabs inside folders never archive.
- **Timing:**
  - Set per Profile (Jan 2024) under Settings > Profiles > "Archive tabs after".
  - The exact option list (e.g. 12h / 24h / 7 days / 30 days) is **UNVERIFIED**; none of the fetched articles lists it.
  - The timer can be lengthened but **cannot be disabled**.
- **Little Arc windows** have their own archive cadence, **6 hours by default**.
- **Downloads** auto-archive the same way (2022).
- **The Archive itself:**
  - Open it with Cmd-T "View Archive", or from the Library.
  - Each entry has a restore button, and the list can be searched and filtered (e.g. by Little Arc).
  - Clear everything with "Clear Archive", which asks for confirmation.
  - Restored tabs follow Air Traffic Control routes.
- **Cmd-Shift-T** reopens the last closed tab. Cmd-Z undoes sidebar actions such as moves and clears; it was introduced in 2021.
- New members see a one-time banner explaining Auto Archive (2024).

Sources:
- https://resources.arc.net/hc/en-us/articles/19228855311127-Auto-Archive-Clean-as-you-go
- https://resources.arc.net/hc/en-us/articles/19235387524503
- The release notes

---

## 4. Folders

- **Create:** "+" at the bottom of the sidebar, or Cmd-T "New Folder". Nested folders are supported (Shift-select tabs, then right-click to create one).
- **Rename, move, delete, duplicate or change the icon** from the right-click menu.
- **Folder Preview (macOS):**
  - Hover a folder title to search it or scroll its tab list without expanding it.
  - A tab picked from the preview "peeks out" under the closed folder, so the rest stays collapsed.
- **Copy All Links:** right-click a folder. It includes nested folders.
- **Share Folder:** creates a permalink (see §13).
- **Live Folders:**
  - GitHub creates a "Pull Requests" folder automatically, filtered to Created by Me, Drafts, specific repos, or team review requests.
  - It does not work with GitHub Enterprise on custom domains.
  - Only 4.17% of DAU used Live Folders.

Sources:
- https://resources.arc.net/hc/en-us/articles/19228419623447-Folders-Stash-Similar-Tabs-Together
- https://resources.arc.net/hc/en-us/articles/22731612065815-Automatic-GitHub-Live-Folders

---

## 5. Spaces, themes and Profiles

### Spaces

- **Each Space has** its own Pinned section, Unpinned section, Theme (color or gradient) and Icon (emoji or glyph), and it can be linked to a Profile.
- **Create** with "+" at the bottom of the sidebar.
- **Switch by:**
  - Clicking the Space icons at the bottom of the sidebar.
  - **Two-finger horizontal swipe in the sidebar.** The swipe animation also transitions the icons (2023).
  - **Ctrl-1…N** to jump to Space N.
  - Cmd-Opt-← / → to go to the previous or next Space.
  - Cmd-T and typing the Space name.
  - Mouse buttons 3 and 4 (2022).
- **Move a tab to another Space:** drag it left or right onto that Space (2022), or use the "Move" action.
- **Manage Spaces:** Cmd-T "Manage Spaces". The Library also has a Spaces view where you can move tabs across Spaces.

### Theme Picker

Open it from the Space title's "…"/Edit menu > Theme, from a right-click on empty sidebar space, or with Cmd-T "Theme".

- **Colors:**
  - A 2D color grid: drag a dot (a third-party description gives x = hue, y = saturation, **UNVERIFIED**).
  - Suggested presets across the top.
  - Up to **3 colors**, drawn as a **gradient**. The picker keeps the colors complementary, which makes bad themes hard to create.
- **Intensity slider and grain/noise control** (added May 2022: "increase Intensity or Graininess").
- **Appearance:** Light / Dark / Automatic (stars / sun / moon icons). This setting is **global**, not per Space.
- **Reset:** the (–) button deselects all colors and restores the default.
- **Feel:** haptic feedback on the trackpad and better dark-mode contrast (2022).
- **Themes V2** (Sept 2022) brought more presets and dark mode.
- Theme colors are exposed to pages as CSS custom properties that Boosts can use (https://arc.net/colors.html).

### Profiles

- A Profile scopes, per Space: logins, passwords and autofill, cookies and cache, history, archive timing, default browser, **Favorites**, extensions and arc://settings.
- New Profiles start empty.
- Assign one via the Space title "…" > Profile. A Profile cannot be deleted until no Space uses it.
- **Profiles do not sync** across devices.
- Little Arc remembers the Profile chosen for each domain.

Sources:
- https://resources.arc.net/hc/en-us/articles/19228064149143-Spaces-Distinct-Browsing-Areas
- https://resources.arc.net/hc/en-us/articles/19227964556183-Profiles-Separate-Work-Personal-Browsing
- https://resources.arc.net/hc/en-us/articles/25625261733143
- https://thesweetsetup.com/first-look-arc-browser/
- https://chriscoyier.net/2022/12/08/whats-good-about-the-arc-browser/
- https://github.com/notnaki/vane/pull/59 (third-party re-implementation description: UNVERIFIED)

---

## 6. Peek

- **Trigger:** clicking a link to another site from a **Pinned or Favorite** tab opens a floating Peek overlay above the current tab, instead of a new tab.
- **Actions:**
  - Expand into a full tab: button or Cmd-O.
  - Turn it into a Split View: the Split button.
  - Close it: click outside, the X button, Cmd-W or ESC.
  - Cmd-Z or Cmd-Shift-T reopens a closed Peek.
- **Links to Easels and Notes** open in Peek by default.
- **Toggle:** Settings > Links > "Open a Peek window when clicking on links to other sites".
- **Routing:** Peek follows Air Traffic Control routes (2023). The Toolbar can render inside Peek.
- **History:** introduced Feb 16, 2023.

Source: https://resources.arc.net/hc/en-us/articles/19335302900887-Peek-Preview-Sites-From-Pinned-Tabs, plus the release notes.

---

## 7. Split View

- **Up to 4 panes,** side-by-side or top-bottom. Vertical splits arrived in Feb 2023, and the orientation can be flipped from the Split Controls button (Dec 2023).
- **A split is its own tab in the sidebar.** It can be pinned, favorited (with a custom icon), shared and reopened later.
- **Create a split by:**
  - Ctrl-Shift-= (the help center lists "Command-Shift-Plus" in one article and "Control-Shift-Plus" in the shortcuts table, so the exact modifier is **UNVERIFIED**; the shortcuts table is more likely correct).
  - Cmd-T "Add Right / Left / Top / Bottom Split".
  - **Dragging a sidebar tab into the content area.** Drop left or right of the target to set the order. The drop indicator is tinted to the theme.
  - **Dragging one sidebar tab onto another** (Jan 2024).
  - Option-click a link (Chris Coyier, 2022). **UNVERIFIED** whether this is still current.
- **Close a split:**
  - Ctrl-Shift-– closes one.
  - Right-click > "Separate All Tabs".
  - The X above a pane.
  - The X next to a split tab in the sidebar.
  - Option-click a split tab to separate it.
- **Focus a pane:** Ctrl-Shift-1…N. Cmd-L changes the URL of the focused pane.
- **"New Note (in Split)"** was an action before Notes was phased out.

Source: https://resources.arc.net/hc/en-us/articles/19335393146775-Split-View-View-Multiple-Tabs-at-Once, plus the release notes.

---

## 8. Little Arc

- **What it is:** a small, minimal floating window. Links clicked in **other apps** (Slack, iMessage…) open here by default, instead of in the main window.
- **Shortcuts:**
  - **Cmd-Opt-N** from anywhere opens a Little Arc for a quick search.
  - Cmd-Opt-click a sidebar tab opens it in Little Arc.
  - Cmd-Opt-click a link opens it in Little Arc (2022).
- **Moving it into the sidebar:**
  - The "Open In" button at the top.
  - **Cmd-O** moves it to the most recent Space.
  - **Cmd-Opt-O** moves it to a chosen Space.
  - Arrow keys pick the destination Space.
- **Housekeeping:**
  - Little Arc windows auto-archive after **6 h by default**, and this is configurable.
  - Dock right-click > "Show/Hide All Little Arc Windows".
  - Opening the same link again brings back the existing window.
- **Disable:** Settings > Little Arc. **Air Traffic Control's default route** can send external links to a Space instead.

Source: https://resources.arc.net/hc/en-us/articles/19235387524503-Little-Arc-Quick-Lookups-Instant-Triaging

---

## 9. Command Bar (Cmd-T / Cmd-L)

- **Cmd-T** opens a centered floating command bar. New windows also open with it centered.
- **One input** that:
  - Searches open tabs (switches to them rather than duplicating), history, the web, Spaces and extensions.
  - Runs ~100 **Arc actions**, per The Sweet Setup. Examples: Pin, Split, New Easel, Capture, View Archive, Theme, Share, Copy URL as Markdown, Turn on Developer Mode, Clear Archive, Open Library, Open Link Preferences.
- **Tab** inside the bar switches into "actions" mode. With a site-search shortcut typed (e.g. `yt`), Tab scopes the search to that site.
- **Cmd-L** opens the same bar pre-filled with the current URL, to edit it. Cmd-L then Enter reloads. Pressing Cmd-T or Cmd-L again dismisses the bar.
- **Site Search:** custom `%s` engines with short keywords (arc://settings/searchEngines).
- **Arc Max extras:**
  - **ChatGPT suggestion.** "gpt" is an alias, and **Cmd-Opt-G** asks directly. Requires a ChatGPT login.
  - **Instant Links:** Shift-Enter opens the top result directly. "Folder of …" creates a folder of results.
- **Paste URL as New Tab** action. "Paste & Go" was added and later "unshipped".
- **Ranking:** frequency-based, and tuned repeatedly across releases.

Sources:
- https://resources.arc.net/hc/en-us/articles/20855018192791-Site-Search-Directly-Search-any-Website
- https://resources.arc.net/hc/en-us/articles/19335160678679
- https://thesweetsetup.com/first-look-arc-browser/
- https://chriscoyier.net/2022/12/08/whats-good-about-the-arc-browser/
- The release notes

---

## 10. Library, Easels and Notes

- **Library:**
  - Opened from the bottom-left sidebar icon or Cmd-T "Open Library".
  - Sections: **Media** (images, videos, captures), **Downloads** (including in-progress), **Easels & Notes**, **Spaces** (view and move tabs across all Spaces), **Archived Tabs**. Boosts are also managed here.
  - **Hovering the Library icon** shows recent files you can drag out, and right-click picks which file types appear.
- **Easels** (macOS only):
  - Whiteboards that hold drawings, text, images and **Captures**. Capture with Cmd-T "Capture" or Cmd-Shift-2, then drag a rectangle.
  - **Live Captures** are interactive and refreshed with Cmd-R.
  - Objects snap to guides. Presence cursors appear when sharing.
  - Export to PNG, or share with a link that is viewable in any browser.
  - New Easels open as a pinned tab.
- **Full-page capture:** Cmd-T "Capture Full Page" saves a PNG. Developer Mode adds "Portrait Mode" for pretty screenshots.
- **Arc Notes** were **phased out in 2024**:
  - Mar 14: export encouraged.
  - Apr 4: no new notes.
  - Apr 18: export required.
  - "New Note" can now open another app (Notion, Google Docs, Confluence…) set under Settings > Profiles > New documents.

Sources:
- https://resources.arc.net/hc/en-us/articles/19230634389911
- https://resources.arc.net/hc/en-us/articles/19231142050071-Easels-Capture-Create
- https://resources.arc.net/hc/en-us/articles/19233788518039-Phasing-Out-Arc-Notes
- https://resources.arc.net/hc/en-us/articles/25481392111895

---

## 11. Boosts (per-site customization)

- **Create:**
  - "+" > New Boost.
  - Cmd-T "New Boost".
  - The paintbrush in the Site Control Center.
  - Boost Shuffle (dice) randomizes a Boost for inspiration (2023).
- **The editor has:**
  - A **color wheel** with draggable dots to recolor the page.
  - **Invert lightness**, i.e. a dark mode.
  - Contrast, brightness and saturation sliders.
  - A font preset picker.
  - Page size from 90% to 150%.
  - A text-case toggle.
  - **Zap:** click elements to remove them. A "\" icon at the bottom restores them.
  - A **Code** mode with a CSS and JS editor.
- **Scope:** one domain per Boost. Boosts apply across all Profiles.
- **Manage:**
  - Toggle a Boost from the Site Control Center; a disabled Boost shows a greyed paintbrush.
  - Delete from Library > Boosts.
  - A global kill switch sits in Settings > Advanced.
- **Changes after the Sept 2024 security issue:**
  - Boost sharing was removed.
  - JS Boosts no longer auto-enable across devices; "View Boosts" re-enables them per device.
  - The legacy builder was deprecated in Oct 2024.
  - Wikipedia notes the Sept 2024 flaw let an attacker "execute arbitrary code into any other users' browsing session with just a user ID". It was patched.

Sources:
- https://resources.arc.net/hc/en-us/articles/19212718608151-Boosts-Customize-Any-Website
- https://resources.arc.net/hc/en-us/articles/26681118599191
- https://en.wikipedia.org/wiki/Arc_(web_browser)

---

## 12. Media: Mini Player and audio

- **Mini Player (PiP):**
  - Switching away from a tab playing video auto-opens a floating player at the **bottom-right**. It does not trigger if the tab is muted.
  - Resize by dragging a corner. Two-finger drag moves it; pinch resizes Meet PiP.
  - Arrow keys seek and space plays/pauses.
  - Double-clicking returns to the source tab.
  - Disable per site in the Site Control Center, or globally.
- **Audio Player:** switching away from an audio tab puts a small controller at the **bottom of the sidebar**, closable with X.
- **Google Meet in PiP:** chat inside PiP, and a "share this tab instead" button.
- **Ctrl-Tab tab switcher:** shows recording indicators when the camera is on.

Source: https://resources.arc.net/hc/en-us/articles/19234766331799-Mini-Player-Watch-or-Listen-as-you-Browse, plus the release notes.

---

## 13. Link routing, sharing and copying

- **Air Traffic Control** (macOS, May 2023):
  - Rules take the form "URL **contains** X" or "URL **is equal to** X" → Space.
  - A **Default** route decides where external links go: Little Arc, **Most Recent Space**, or a named Space.
  - Settings > Links, or Cmd-T "Open Link Preferences".
  - Routes are deleted along with their Space. They apply to Peek and to restored archive tabs.
  - ATC settings do not sync.
- **Copy URL:**
  - **Cmd-Shift-C** ("Supercopy", 2021) copies the URL with tracking parameters stripped, and shows a toast.
    - Some marketers dislike the stripped UTMs (per comments on Coyier's post).
  - **Cmd-Shift-Opt-C** copies it as Markdown.
  - A Copy Link button sits in the URL bar.
- **Share Quote:** select text and a "Share Quote" button appears in the URL bar and context menu. It creates a link with a generated image of the quote.
- **Share a Space, Folder, Split or selected tabs:**
  - The permalink is a **frozen snapshot**, not live, and it cannot be deleted.
  - Arc users can add the shared item to their sidebar.
  - Other browsers get an Arc-styled web view.

Sources:
- https://resources.arc.net/hc/en-us/articles/22932014625431-Air-Traffic-Control-Automate-Your-Link-Routing
- https://resources.arc.net/hc/en-us/articles/19228534606743
- https://chriscoyier.net/2022/12/08/whats-good-about-the-arc-browser/

---

## 14. Arc Max (AI), and what remains

Arc Max launched in V1.11.0 (Oct 5, 2023). It is free and each feature is toggled separately under Settings > Max.

- **5-second Previews** (macOS):
  - Shift-hover any link to get an AI summary card.
  - Runs automatically on Google, DDG and Bing results, X, Threads and HN links.
  - Preview images use the OpenGraph aspect ratio.
- **Tidy Tab Titles:** renames a tab to a short title when it is pinned. Double-click to rename by hand.
- **Tidy Downloads:** renames downloaded files. Click the name to undo.
- **Tidy Tabs:**
  - A broom icon above the Today tabs.
  - Appears when there are more than 6 Today tabs, and sorts them into folders.
  - Its button was redesigned in May 2024 to stand apart from "Clear".
- **ChatGPT in the Command Bar:** Cmd-Opt-G.
- **Instant Links:** Shift-Enter.
- **Ask On Page** (Cmd-F chat): **removed Aug 2025**.
- **Browse for Me:** **mobile Arc Search only**, not desktop.
- **Other AI details:**
  - Enterprises can disable Arc Max through the `arcMaxDisabledByOrgPolicy` policy.
  - The model was upgraded in Oct 2024. The vendor is not named on the pages fetched: **UNVERIFIED**.
- **Previews (non-AI):** hovering a pinned or favorite Gmail, Outlook, GCal, Notion, Confluence, Figma or Linear tab shows recent items and quick actions.
  - GitHub Previews were retired in favor of Live Folders.
  - Calendar hover preview was used by only 0.4% of DAU.

Sources:
- https://resources.arc.net/hc/en-us/articles/19335160678679-Arc-Max-Boost-Your-Browsing-with-AI
- https://resources.arc.net/hc/en-us/articles/19335284431639-Previews-Glance-Top-Sites
- https://resources.arc.net/hc/en-us/articles/20887042551831
- The 2024–2026 release notes

---

## 15. Keyboard shortcuts (macOS)

All of these can be remapped under Settings > Shortcuts. Windows does not support remapping.

| Action | Shortcut |
|---|---|
| New tab / Command Bar | Cmd-T |
| Edit URL (Command Bar pre-filled) | Cmd-L |
| New window | Cmd-N |
| New Blank Window | Ctrl-Cmd-N |
| New incognito window | Cmd-Shift-N |
| Little Arc | Cmd-Opt-N |
| Close tab / window / Peek | Cmd-W |
| Reopen closed tab | Cmd-Shift-T (Cmd-Z also undoes sidebar actions) |
| Pin / unpin | Cmd-D |
| Copy clean URL | Cmd-Shift-C |
| Copy URL as Markdown | Cmd-Shift-Opt-C |
| Show / hide sidebar | Cmd-S |
| Show / hide toolbar | Cmd-Shift-D |
| Clear unpinned tabs | Cmd-Shift-K |
| Go to tab N (Favorites first) | Cmd-1…9 (Cmd-9 can be set to "last tab") |
| Go to Space N | Ctrl-1…9 |
| Recent-tab switcher (MRU, last 5) | Ctrl-Tab (Ctrl-` goes backwards) |
| Previous / next tab in sidebar order | Cmd-Opt-↑ / ↓ |
| Previous / next Space | Cmd-Opt-← / → |
| Back / forward | Cmd-← / → or Cmd-[ / ] |
| Add / close split | Ctrl-Shift-= / Ctrl-Shift-– |
| Focus split pane N | Ctrl-Shift-1…N |
| Open Peek or Little Arc as a full tab | Cmd-O (Cmd-Opt-O picks the Space) |
| Cycle pinned extensions | Hold Cmd, tap E |
| Capture | Cmd-Shift-2 |
| New Easel | Ctrl-Shift-E |
| ChatGPT | Cmd-Opt-G |
| History | Cmd-Y |
| Settings | Cmd-, |
| Paste clipboard as new tab (2023) | Cmd-Opt-V (**UNVERIFIED** whether still current) |

Gestures:
- Two-finger swipe in the sidebar switches Spaces.
- Long-press back/forward shows history.
- Cmd-click or middle-click back/forward opens the result in a new tab.
- Pinch zooms in Easels.

Sources:
- https://resources.arc.net/hc/en-us/articles/20595231349911-Keyboard-Shortcuts
- https://resources.arc.net/hc/en-us/articles/25619402657303
- https://resources.arc.net/hc/en-us/articles/25622899860631
- The release notes

---

## 16. Sync, import, passwords, extensions (Chromium)

- **Arc Sync:**
  - End-to-end encrypted: Argon2 KDF plus libsodium sealed boxes. Recovery Card file: `ArcRecoveryPhrase.png`.
  - Replaced iCloud sync; iCloud sync was deprecated in V1.48.0 (Jun 20, 2024).
  - **Syncs:** Spaces, folders, pinned tabs and Today tabs.
  - **Does NOT sync:** history, passwords, extensions, **Favorites**, Profiles, custom shortcuts, Air Traffic Control settings.
- **Import:**
  - From Chrome, Safari, Firefox, Brave, Edge, Opera, Opera GX and Vivaldi. Imports bookmarks (which become pinned tabs), passwords, history and extensions.
  - Extensions can only be imported from Chrome, Brave and Edge.
  - New users get Favorites and Pinned tabs suggested from their imported history.
- **Passwords:**
  - Built-in Chromium password manager, per Profile, with autofill for passwords and cards.
  - iCloud Passwords and passkeys come through Apple's Chrome extension.
- **Extensions:**
  - Chrome Web Store extensions work.
  - They live under the Site Control Center. Pinned extensions appear on hover over the URL bar.
- **Not supported:** PWAs.
- **Other:** Arc requires an account. Arc has a group-policy / enterprise policy API. The Task Manager is under Help > Troubleshooting.
- **For den (WebKit):** Chromium extensions, the Chromium password manager and Chromium import paths cannot carry over directly. Safari Web Extensions, Keychain/AutoFill and WKWebsiteDataStore per profile are the equivalents. This is an inference and has not been tested.

Sources:
- https://resources.arc.net/hc/en-us/articles/20272860828823-Arc-Sync
- https://resources.arc.net/hc/en-us/articles/22370005382167
- https://resources.arc.net/hc/en-us/articles/19335089616791
- https://resources.arc.net/hc/en-us/articles/19434259167767
- https://resources.arc.net/hc/en-us/articles/25619249733783
- https://resources.arc.net/hc/en-us/articles/25541719713431
- https://resources.arc.net/hc/en-us/articles/25678978728983
- https://resources.arc.net/hc/en-us/articles/19434846038935

---

## 17. What users love, and what they complain about

### Loved

- The sidebar-first, chrome-less layout, which gives content more vertical room.
- **Spaces** with distinct themes. Even so, only 5.52% of DAU used more than one.
- The **Command Bar**. The Verge's David Pierce wrote "Arc wants to be the web's operating system".
- Auto-archive's "fresh start".
- Pinned tabs acting as apps and bookmarks, with reset.
- **Cmd-Shift-C clean copy.**
- Little Arc for links from other apps.
- Split View, Peek and Boosts.
- Theming that is hard to make ugly.
- Tidy Downloads.

Sources: Coyier, The Sweet Setup, Wikipedia, the Trustpilot and Product Hunt summaries below.

### Complaints

- **Learning curve.** Josh Miller's own diagnosis was "too different… too little reward".
- **Performance:** Chromium RAM use. One reviewer reports 4–6 GB, and battery and heat problems. This is a single reviewer's figure, so treat it as **UNVERIFIED** in general. The help center itself has troubleshooting articles on crashes and performance.
- **Crashes and bugs,** plus extension and website compatibility gaps.
- **Sync gaps:** Profiles, Favorites, extensions and passwords do not sync.
- **No bookmarks and no export** of pinned tabs.
- **Cannot disable auto-archive.**
- **No PWAs.**
- **Weak Windows port.**
- **The Sept 2024 Boosts security vulnerability.**
- **Broken muscle memory:** Cmd-1… goes to Favorites, not tab N in a tab strip.
- The ~200 px sidebar truncates titles, and the layout fits portrait monitors badly.
- **Stagnation since May 2025** and distrust after the pivot to Dia and the Atlassian acquisition. Users fear losing the sidebar workflow more than losing bookmarks.

Sources:
- https://browsercompany.substack.com/p/letter-to-arc-members-2025
- https://chriscoyier.net/2022/12/08/whats-good-about-the-arc-browser/
- https://www.trustpilot.com/review/arc.net
- https://www.producthunt.com/products/arc-browser/reviews
- https://dev.to/pickuma/arc-browser-review-18-months-with-a-browser-that-thinks-differently-26o1
- https://supasidebar.com/blog/arc-browser-status-tracker
- https://resources.arc.net/hc/en-us/articles/25626856007959

---

## 18. UX details that make Arc feel great (observable)

Each item comes from Arc's own release notes unless tagged otherwise.

### Chrome and layout

- The content area is an inset rounded card sitting on a themed, gradient, slightly grainy sidebar background. The whole window "wears" the Space's color. Exact values are **UNVERIFIED**; measure them.
- The URL is simplified to the domain in a sidebar pill. The full URL appears only via the Toolbar, Developer Mode or the 1.5 s link-hover status pill.
- The status pill **moves away** when the cursor approaches it.
- Any empty sidebar area drags the window, and so does the top strip of the web page. Double-clicking empty sidebar space makes a new tab.
- Toast notifications (e.g. after copying a URL) use **theme-matched colors** and their own animations (Jan 2024).
- Update and What's New banners start collapsed and expand on hover (V1.42). They carry a gradient button and blend into the sidebar.

### Motion and feedback

- **Space switch:** a horizontal slide of the whole sidebar that follows the two-finger swipe. The Space icons animate along with it.
- **Haptic feedback:**
  - On the trackpad while dragging and reordering tabs ("light haptics"), and in the Theme Picker.
  - Can be turned off: "Haptic feedback when reordering tabs".
- **Arc-generated sounds,** with a global toggle in Advanced. Which events play sounds is **UNVERIFIED**.
- **Dedicated animations** for:
  - Clearing tabs: the "Clear" / Cmd-Shift-K sweep.
  - Dropping tabs.
  - The plus and close-tab buttons.
  - Entering and exiting fullscreen.
  - The Mini Player.
- **Drop indicators** for Split View are tinted to match the theme.
- A tab overflow indicator appears while scrolling a long sidebar.

### Theming

- The Theme Picker is constrained so most choices look good: a gradient of up to 3 colors, intensity, grain, and global light/dark/auto.
- The Ctrl-Tab switcher shows each Space's theme, and removed its page dimmer so switching feels lighter.

### Small touches that stay out of the way

- Favorites animate while playing music. The GCal Favorite counts down to your next meeting and shows a Join button.
- The pinned-tab "/" drift marker, plus favicon-click to reset.
- Folder hover-preview lets you open one tab without unfurling the folder.
- Media follows you: the video PiP floats bottom-right and the audio controller docks at the bottom of the sidebar.
- The Command Bar always opens centered, and pressing the shortcut again dismisses it. Keyboard toggles are symmetric: Cmd-S, Cmd-Shift-D, Cmd-T/L.
- Onboarding: a one-time Auto Archive banner, and Favorites and Pinned tabs suggested from imported history.

### Pixel values: all UNVERIFIED

These come from a third-party reconstruction (blakecrosley.com):
- Sidebar ~240 px expanded, 48 px collapsed.
- 0.2 s ease-out transitions.
- Little Arc chrome ~36 px.

Chris Coyier's commenters mention a "200-pixel sidebar". None of these numbers comes from Arc; measure a real Arc build before using them.

### Sources

- The macOS release notes for 2021–2026 (four articles, IDs 20498463803799, 20498417809815, 20498377604887, 20498293324823).
- https://blakecrosley.com/guides/design/arc (third party, UNVERIFIED)
- https://chriscoyier.net/2022/12/08/whats-good-about-the-arc-browser/

---

## 19. Open questions and UNVERIFIED items to measure on a real Arc install

1. Exact sidebar default, min and max widths; content-card corner radius and inset; the sidebar-hover reveal zone and its animation timing.
2. The option list for "Archive tabs after".
3. The Split View add shortcut: Ctrl-Shift-= or Cmd-Shift-=.
4. Whether Option-click still opens a link in a split, and whether Cmd-Opt-V still pastes the clipboard as a new tab.
5. Which Arc sounds exist, and what triggers them.
6. The theme picker's axis mapping (hue/saturation) and the grain implementation.
7. The Arc Max model vendor. Moot for den.
