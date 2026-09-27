# Dia changelog — full feature inventory

- **Source:** https://www.diabrowser.com/changelog (index) + per-version pages `https://www.diabrowser.com/changelog/mac/<x-y-z>` listed in https://www.diabrowser.com/sitemap.xml
- **Date fetched:** 2026-09-27
- **Versions covered:** macOS v0.43.0 (Aug 21, 2025) .. v1.50.0 (Sep 24, 2026) — **56 version pages**, all read.
- **Entries recorded:** 304 bullets below (one per distinct feature/fix line in the changelog).
- **Fetch notes:**
  - All 56 per-version pages + `/changelog`, `/changelog/mac`, `/changelog/windows` returned HTTP 200.
  - `/changelog/windows`: "No releases yet for Windows."
  - Pagination: `/changelog?page=2` returns the identical page (same MD5) — no pagination exists; the index lists all 56 versions.
  - No pages exist for 1.11.x, 1.12.x, or anything before 0.43.0 (probed `/changelog/mac/1-11-0`, `1-12-0`, `0-42-0` → 404). The version sequence jumps 1.10.1 → 1.13.1.
  - Several patch versions (1.47.1, 1.45.1, 1.43.1, 1.34.1, 1.13.1, 1.10.1, 1.3.1) have intro text referring to the x.y.0 release; only the patch page exists.
  - The "Security" tab on the changelog page links to a separate `/security` page — not part of the changelog, not inventoried.
  - Older pages (0.43–0.49) use loose prose with emoji bullets; some sub-headings ("Plus some small tweaks…") appear with list items out of order in the HTML. Items recorded as text appears; nothing inferred.
- **Release notes (added):** 44 pages under https://www.diabrowser.com/release-notes/ (from sitemap). All returned HTTP 200. `/release-notes/latest` is identical to `1-50-sunglow`, leaving **43 unique pages = Issues No. 001–043** (v1.5.0 → v1.50.0). Each page appears as a **"Release notes:"** block under its matching version section.
  - **Version numbers:** each page renders issue and version as an animated counter, so they were read from the page's embedded `issueNumber`/`appVersion` data. Pages where this differs from the slug or changelog are flagged in their block: 1-9-0 → v1.9.1; 1-10-1 → v1.10.0; granola → v1.40.1; security-team-question → v1.45.0.
  - **Media handling:** images are on Sanity. Videos are Mux HLS; frames were extracted with `ffmpeg -i https://stream.mux.com/<id>.m3u8 -vf fps=1/2`. That is 1 frame every 2s, not the requested 2 fps, to keep the volume readable; a few short clips were re-extracted at 1–2 fps. Processed 80 videos (every video marker had extracted frames) and 92 unique content images, with **no fetch/extract failures**.
  - **What the media showed:** nearly all content images are staff headshots or decorative postcard art. Product UI appears only in videos.
  - **Limits:** fast animations (download fly-in, button motion, pane swap) are not resolvable at this sample rate and are marked as such. Only UX seen in frames or stated in page text is recorded.
  - **Not covered:** `1-31-0-pr-hover` has a one-line entry here; see `docs/reference/dia-ui-spec.md` §3. `1-34-1-pittsburgh` has no product content. No release-note pages exist for v0.43–v1.4, v1.35, or v1.40.0 beyond granola.
- **Tags:** `[AI]` = AI/chat/assistant/model/Memory/Skills/connected-tool features. `[non-AI]` = browser features/fixes. **den-candidate** = non-AI convenience den should consider.

---

## v1.50.0 (September 24, 2026) — "Figma integration and deeper search"
- [AI] Figma tools available in chat.
- [AI] Search previous chats by date window, title, or keywords.
- [AI] Dia (assistant) can search browsing history by date, page title, URL/domain.
- [AI] Search and read previously generated artifacts.
- [AI] Prevent sleep during dictation.
- [AI] Voice dictation continues when switching tabs, with in-progress indicator.
- [AI] Stop and resume AI responses mid-stream.
- [AI] Edit AI messages.
- [AI] Smaller on-device command bar routing model (routes between Chat and Google).
- [non-AI] Cleanup Tabs memory leak fix — tab cleanup closes loaded pages before archiving (memory/CPU). **den-candidate**
- [non-AI] "Move to Profile" respects "Add new tabs to the top" preference. **den-candidate**
- [non-AI] Collapsible PR stacks in GitHub Live Folders; collapse state persisted across relaunches. **den-candidate**
- [AI] Retiring Memory feature; existing memory data deleted.

**Release notes:** [https://www.diabrowser.com/release-notes/1-50-sunglow](https://www.diabrowser.com/release-notes/1-50-sunglow) ("Crafted with care, because you spend your day here.", Sep 24 2026, Issue No. 043, App v1.50.0; `/release-notes/latest` is the same page). Media: brand film + portrait, no product UI.
- [non-AI] "Sunglow" brand refresh (hand-painted, oil-on-canvas look); app icon keeps its shape in a new "Sunglow Yellow".
- [non-AI] Brushstrokes on the New Tab Page: a custom hand-brushed Dia icon for each Profile color. **den-candidate** (per-profile NTP art)
- [non-AI] Public changelog launched ("every feature, tweak, bug fix").
- Also restates Figma tools, stop/resume, search chats [AI], and collapsible PR stacks [non-AI] from the changelog. No media for these.

## v1.49.0 (September 17, 2026)
- [AI] Read images attached to Slack messages in chat.
- [AI] More efficient model for tab group / tab title renaming.
- [AI] More reliable AI agent sessions (context handling separated from execution).
- [non-AI] Performance: fixes unnecessary UI updates, redundant data scans, hidden-element work. **den-candidate**

**Release notes:** [https://www.diabrowser.com/release-notes/1-49-0-microsoft-tools](https://www.diabrowser.com/release-notes/1-49-0-microsoft-tools) ("Your tool kit, in Dia.", Sep 17 2026, Issue No. 042, App v1.49.0). 2 videos.
- [AI] Outlook, Teams, SharePoint connectors that feed the Morning Brief. Video: brief tab "The Thursday Brief - August 27" with "Start My Day" and "Share" toolbar buttons, a painted hero, serif sections ("Push your work forward", "Top to-dos" with app-tagged circle checkboxes, "New updates", "Your day" timeline), and footer "Made for you by Dia using your Teams, Outlook, and SharePoint."
- [non-AI] UX seen in video: a **pinned calendar tile shows a live "in 5m" countdown badge**. Hovering it opens a card of upcoming events, each with a "Join ↵" button. The sidebar bottom has **page dots (4)** for multiple profiles/spaces, and tabs show a small thumbnail at the row end. **den-candidate**
- [AI] Teams, Outlook, and SharePoint Q&A. Slack voice notes and screenshots.
- [AI] Beta tools: Zoom, Salesforce, Figma, Canva.
- [non-AI] Request an app: Settings → Apps → Request an App, or email.

## v1.48.0 (September 10, 2026)
- [AI] Microsoft tools in chat: Outlook, SharePoint, Teams (feed Morning Brief).
- [AI] Slack voice note transcripts readable in chat.
- [non-AI] Domain-wide tab muting — mute a site so current and future tabs from that domain stay quiet. **den-candidate**
- [non-AI] Faster tab closing — show next tab before running cleanup. **den-candidate**
- [non-AI] Memory-use improvements; catches renderer leaks (runaway memory). **den-candidate**
- [non-AI] Fix drag-tab-to-new-window animation on macOS 27 ("Golden Gate").

**Release notes:** [https://www.diabrowser.com/release-notes/Tools](https://www.diabrowser.com/release-notes/Tools) ("Notes from the roadmap", Sep 10 2026, Issue No. 041, App v1.48.0). Media decorative (stamps/postmarks).
- [AI] Microsoft tools suite: a SharePoint doc update produces a morning-brief heads-up, and you can ask what's happening in Teams. Also mentions Atlassian.

## v1.47.1 (September 3, 2026) — intro describes 1.47.0
- [AI] Outlook Live Calendar — pinned Outlook/Teams URLs integrate with Live Calendar.
- [AI] "Request a Tool" button in Preferences → Apps (top 400 SaaS apps or custom).
- [non-AI] Background tabs (⌘+click) visible while peeking a Tab Group. **den-candidate**
- [non-AI] Bookmark Bar Tab Groups appear in Bookmarks > Bookmarks Bar app menu. **den-candidate**
- [AI] Chat attachment suggestions show which Profile a Group/Tab belongs to.
- [non-AI] Fix PiP activation when switching profiles on Meet/YouTube. **den-candidate**
- [non-AI] ⌃⌘N — new Tab Group from selected tabs (mirrors Finder "New Folder with Selection"). **den-candidate**

**Release notes:** [https://www.diabrowser.com/release-notes/Notion](https://www.diabrowser.com/release-notes/Notion) ("Notes from the roadmap", Sep 3 2026, Issue No. 040, App v1.47.1). Media decorative.
- [AI] Notion write-ups compiled from Slack DMs, email, and Google Docs (e.g. performance-review evidence).

## v1.46.0 (August 27, 2026)
- [non-AI] Release Notes Postcard — full-page postcard on new tab page treatment (replaces newspaper).
- [AI] Improved Slack scraping (faster, more reliable).
- [non-AI] Stack positions in GitHub Live Folder — PRs in a stack show position and group together. **den-candidate**
- [non-AI] PiP window "Keep on Top" toggle via right-click. **den-candidate**
- [non-AI] Clicking domain name in PiP window returns to originating tab. **den-candidate**
- [AI] Agent systems upgrade (chat reliability and security).
- [non-AI] Live Google Calendar selection — choose which calendars appear in Live Calendar. **den-candidate**

**Release notes:** [https://www.diabrowser.com/release-notes/Linear](https://www.diabrowser.com/release-notes/Linear) ("Notes from the roadmap", Aug 27 2026, Issue No. 039, App v1.46.0). Media decorative.
- [AI] Linear integration: example prompt builds a project status/health table sorted by risk.

## v1.45.1 (August 20, 2026) — intro describes 1.45.0
- [non-AI] Cast content (YouTube or any Cast-enabled site) to external devices. **den-candidate**
- [AI] Zoom integration — search meetings, recordings, transcripts, summaries, chats.

**Release notes:** [https://www.diabrowser.com/release-notes/security-team-question](https://www.diabrowser.com/release-notes/security-team-question) ("Notes from the roadmap", Aug 20 2026, Issue No. 038, **App v1.45.0**). Media decorative.
- [AI] Chat history is stored locally (under History). By default, some chat content is sent for product improvement (not linked to your account, deleted after 30 days); a Settings toggle turns this off. AI requests go to the provider under zero data retention. **den-candidate** for the privacy pattern: local-only history plus an opt-out telemetry toggle.

## v1.44.0 (August 13, 2026)
- [non-AI] Stability and performance improvements (no itemized list).

**Release notes:** [https://www.diabrowser.com/release-notes/linkedin-integration](https://www.diabrowser.com/release-notes/linkedin-integration) ("Notes from the roadmap", Aug 13 2026, Issue No. 037, App v1.44.0). Media decorative.
- [AI] LinkedIn integration (recruiter use case).

## v1.43.1 (August 6, 2026) — intro describes 1.43.0
- [non-AI] Swipeable Profiles — swipe between profiles; optional data sharing between Profiles in Settings. **den-candidate**
- [non-AI] macOS bundle size reduction — ArcCore arm64-only, ~265 MB smaller (per changelog). **den-candidate**
- [non-AI] Web content activation fixes — notification clicks, PiP back-to-tab select correct tab/window. **den-candidate**

**Release notes:** [https://www.diabrowser.com/release-notes/context-switching](https://www.diabrowser.com/release-notes/context-switching) ("Notes from the roadmap", Aug 6 2026, Issue No. 036, App v1.43.1). Media decorative.
- [non-AI] Profile switching by swipe: profiles keep logins, tools, AI, and context separate. To try it: right-click the tab bar → create a Profile → swipe between them. **den-candidate**

## v1.42.0 (July 30, 2026)
- [non-AI] Chromium M151 upgrade.
- [AI] Thinking UI redesign — real-time thinking in conversation timeline.

**Release notes:** [https://www.diabrowser.com/release-notes/windows-wednesdays](https://www.diabrowser.com/release-notes/windows-wednesdays) ("Notes from the roadmap", Jul 30 2026, Issue No. 035, App v1.42.0). Media decorative.
- [non-AI] Announces Dia for Windows "this fall", the "Windows Wednesdays" series, and a beta waitlist.

## v1.41.0 (July 23, 2026)
- [non-AI] Custom search engine labels — command bar shows actual matched engine name, not always "Google." **den-candidate**
- [AI] Tool connection suggestions ("all apps" bar) on New Tab Page.

**Release notes:** [https://www.diabrowser.com/release-notes/questions](https://www.diabrowser.com/release-notes/questions) ("Notes from the roadmap", Jul 23 2026, Issue No. 034, App v1.41.0). Media decorative.
- [AI] Dia asks clarifying questions (turned on by the Settings > Apps → "New Chat" toggle).

## v1.40.0 (July 16, 2026)
- [non-AI] Re-enable back/forward cache (instant back/forward). **den-candidate**
- [non-AI] Free up memory from idle tabs — more unused tabs slept in background. **den-candidate**

**Release notes:** [https://www.diabrowser.com/release-notes/granola](https://www.diabrowser.com/release-notes/granola) ("Notes from the roadmap", Jul 16 2026, Issue No. 033, **page data says App v1.40.1**; the changelog has only 1.40.0). Media: postcard showing a "Connect Granola" chip.
- [AI] Granola connected tool. Tools connect via Settings > Apps → "New Chat" on.

## v1.39.0 (July 9, 2026)
- [non-AI] Bookmarks no longer reorder themselves during sync. **den-candidate**
- [AI] "Watch Dia think" — expandable/collapsible thinking in conversation.
- [non-AI] Settings sidebar navigation; redesigned Privacy and Memory panes. **den-candidate** (settings nav/Privacy pane part)

**Release notes:** [https://www.diabrowser.com/release-notes/1-39-1-reports](https://www.diabrowser.com/release-notes/1-39-1-reports) ("Meet Reports", Jul 9 2026, Issue No. 032, **App v1.39.1**). No product media.
- [AI] Reports: designed, shareable documents instead of chat. You highlight text and comment inline, queue several changes, and send them together. A cog at the bottom-right sets the style.
- [AI-adjacent] Files menu: one searchable home for Reports, chats, and site-tied chats, opened from a file icon in the window corner.
- [non-AI] Bookmark order no longer changes during sync. **den-candidate**
- [non-AI] Settings redesign: sidebar navigation plus Privacy and Memory panes. **den-candidate**
- [AI] Visible thinking with expand/collapse.

## v1.38.0 (July 2, 2026)
- [non-AI] Abandoned New Tab Pages auto-clear on app switch / screen lock. **den-candidate**
- [AI] Choose Slack/Notion workspace for tools from App settings.

**Release notes:** [https://www.diabrowser.com/release-notes/1-38-0-closing-the-week](https://www.diabrowser.com/release-notes/1-38-0-closing-the-week) ("Closing out the week with Dia", Jul 2 2026, Issue No. 031, App v1.38.0). 1 video.
- [AI] Staff use cases: a roundup of 👀-flagged Slack messages; "who's waiting on me" across Slack, Gmail, and Notion.
- [AI content / non-AI pattern] **Tab hover card with an interactive checklist.** Hovering the Morning Brief tab ("The Wednesday Brief") opens a card to the right of the sidebar with the title and a checkbox list; checked items are greyed and struck through, and you can tick items directly in the card. The tab row shows a small paper-thumbnail sticker. **den-candidate** (interactive tab hover card)
- [non-AI] New Tab Pages auto-clear when you switch apps or lock the screen. **den-candidate**
- [AI] Per-tool Slack/Notion workspace picker.
- [non-AI] Release notes now styled like a newspaper.

## v1.37.0 (June 25, 2026)
- [non-AI] Paper Release Notes window (folded-newspaper style).
- [AI] Google account switching for Gmail/GCal/GDrive tools.

**Release notes:** [https://www.diabrowser.com/release-notes/1-37-0-morning-brief](https://www.diabrowser.com/release-notes/1-37-0-morning-brief) ("What we're building, unfiltered", Jun 25 2026, Issue No. 030, App v1.37.0). 1 video, mostly live-action.
- [AI] Morning Brief: a daily newspaper-style tab ("The Monday Brief"). It has a painted hero, a vertical date/time in the margins, "Top to-dos" as struck-through checkboxes, a "Your day" meeting list, a "Prep for this →" sticker button, and the footer "Made for you by Dia using your Google Calendar, Slack, Notion, and Github." Turned on via Settings > Apps → "New Chat".

## v1.36.0 (June 18, 2026)
- [non-AI] Stash your PiP — drag PiP off screen edge to tuck it away; one click/drag to bring back. **den-candidate**
- [non-AI] Import bookmarks from Chrome's account file (managed/enterprise users). **den-candidate**
- [non-AI] Fix tab groups deleted unexpectedly with Sync.

**Release notes:** [https://www.diabrowser.com/release-notes/1-36-0-pip-stash](https://www.diabrowser.com/release-notes/1-36-0-pip-stash) ("Stash your PiP out of the way", Jun 18 2026, Issue No. 029, App v1.36). 1 video.
- [non-AI] PiP stash: dragging the PiP toward the screen edge collapses it into a **thin vertical colored sliver hugging the edge**, with the content hidden; click or drag to restore. **den-candidate**
- [non-AI] Recap of shortcuts: ⌘S hides the tab bar; ⌘-click multi-select → right-click → tab group; ⌘⌥T opens a new tab inside the open group. **den-candidate**
- [non-AI] Meeting Tab Groups recap; Chrome account-file bookmark import; tab-group sync deletion fix; faster tab close. **den-candidate**

## v1.35.0 (June 11, 2026)
- [non-AI] Performance improvements to tab closing and bookmarks bar (no itemized list). **den-candidate**

## v1.34.1 (June 8, 2026) — intro describes 1.34.0
- [AI] Out-of-process web page reading (security against malicious content; used by Memory etc.).
- [non-AI] Chromium 149 upgrade (changelog: patches for 429 vulnerabilities).

**Release notes:** [https://www.diabrowser.com/release-notes/1-34-1-pittsburgh](https://www.diabrowser.com/release-notes/1-34-1-pittsburgh) ("The week in Pittsburgh", Jun 8 2026, Issue No. 028, App v1.34.1). This is a company offsite recap with **no product features**.

## v1.33.0 (May 28, 2026)
- [non-AI] Tabs respond faster — reworked open-tab tracking, cleanup moved to background. **den-candidate**
- [non-AI] Retired legacy display pipeline causing crashes on ProMotion displays.

**Release notes:** [https://www.diabrowser.com/release-notes/1-33-0-tab-performance](https://www.diabrowser.com/release-notes/1-33-0-tab-performance) ("Everything in Its Place", May 28 2026, Issue No. 027, App v1.33.00 as written in the page data). No product media.
- [non-AI] Tab Search **⌘⇧A** searches every open tab in the current Profile by title or keyword, plus Recently Closed tabs and groups (including Tidy Tabs cleanups). **den-candidate**
- [non-AI] Tidy Tabs is configured in Settings > Tabs with a staleness window of **12 hours / 24 hours / 3 days / 7 days**. Stale tabs move to a "Cleaned up" group and can be restored in one click. Manual sweep: **⌘⌥K**. **den-candidate**
- [non-AI] Quick Switch: hold **⌃Tab** to flip between the most recent tabs (MRU). **den-candidate**

## v1.32.0 (May 21, 2026)
- [non-AI] Small bug fixes, reliability, code stability (no itemized list).

**Release notes:** [https://www.diabrowser.com/release-notes/1-32-0-outside-work](https://www.diabrowser.com/release-notes/1-32-0-outside-work) ("Outside of work", May 21 2026, Issue No. 026, App v1.32). Staff anecdotes only: named tab groups for research, AI reminders, Ask on Page. Notes that releases moved to Thursdays at 11:30am ET. No new features.

## v1.31.0 (May 14, 2026)
- [non-AI] GitHub Live Group PR hover shows CI status and merge conflicts (rough diff size). **den-candidate**
- [AI] Confluence in Live Groups (Docs Live Group alongside Notion, Gmail).
- [AI] Auto-selected emoji for tab groups based on contents.
- [AI] Notion mentions, comment threads, share invites surface in chat.

**Release notes:** [https://www.diabrowser.com/release-notes/1-31-0-pr-hover](https://www.diabrowser.com/release-notes/1-31-0-pr-hover) ("Stop opening PRs blind", May 14 2026, Issue No. 025, App v1.31). Detailed spec in [`../reference/dia-ui-spec.md` §3](../reference/dia-ui-spec.md#3-github-pr-peek-live-group-pr-hover-stop-opening-prs-blind). Hovering a PR in the GitHub Live Group shows CI status and merge conflicts. [non-AI] **den-candidate**

## v1.30.0 (May 7, 2026)
- [non-AI] Tidy tabs — prompt to clean 10+ untouched tabs into a temporary group before archiving. **den-candidate**
- [non-AI] Overflow menu redesign — open + recently closed tabs/groups, submenus for Chats & Files and synced devices. **den-candidate**
- [AI] Read Slack file attachments (screenshots, images, PDFs).
- [AI] Real contact names instead of email-derived guesses (Morning Brief).
- [AI] Google Drive notifications surfaced.

**Release notes:** [https://www.diabrowser.com/release-notes/1-30-0-keeping-tabs-tidy](https://www.diabrowser.com/release-notes/1-30-0-keeping-tabs-tidy) ("Keeping Tabs Tidy", May 7 2026, Issue No. 024, App v1.30). 1 video.
- [non-AI] Tab Cleanup popover, anchored top-right under the tab bar:
  - Title: "10 tabs haven't been touched in a while", followed by a row of the affected favicons with a ▾ expander.
  - Body: "Dia can tidy up for you. / You can always reopen closed tabs from the overflow menu."
  - Buttons: **"Not Now" (esc)**, **"Clean Up Once"**, and **"Clean Up Daily" (primary, ↵)**.
  - Afterwards a toolbar chip with a broom icon reads "Cleaned up 10 tabs".
  - Settings > Tabs > Tab Cleanup sets the staleness threshold. **den-candidate**
- [non-AI] Overflow menu re-haul (no media). **den-candidate**
- [AI] Slack attachments, real contact names, Drive notifications.

## v1.29.0 (April 30, 2026)
- [non-AI] Sync unpinned tabs (section in Tab Overflow menu). **den-candidate**
- [non-AI] Synced browser extensions, pinned order, enabled state, per-profile. **den-candidate**
- [non-AI] Swipe navigation redesign (also works on native pages). **den-candidate**
- [non-AI] Unread pip badge on closed live groups with new items. **den-candidate**
- [non-AI] Sidebar drag rubber-banding at min/max size. **den-candidate**
- [non-AI] Tab multi-select improvements (selection reset, clearer menu copy). **den-candidate**
- [non-AI] Meet PiP "Back to Tab" foregrounds Dia window.

**Release notes:** [https://www.diabrowser.com/release-notes/1-29-0-sync-unpinned-tabs](https://www.diabrowser.com/release-notes/1-29-0-sync-unpinned-tabs) ("Sync unpinned tabs", Apr 30 2026, Issue No. 023, App v1.29). No product media.
- [non-AI] Unpinned tabs sync automatically. Tabs from other devices appear in a section of the Tab Overflow menu. Turn on in Settings > Account → Sync. **den-candidate**
- [non-AI] Also restates: extension sync, unread badge on collapsed live groups, sidebar rubber-banding, faster switching, PiP Back-to-Tab fix, multi-select tidy-up.

## v1.28.0 (April 23, 2026)
- [non-AI] Sidebar visual refresh — tighter spacing, neutral tab groups by default. **den-candidate**
- [non-AI] Top band color matches sticky headers. **den-candidate**
- [non-AI] Synced settings (Tabs, Privacy, Profiles, Memory, Shortcuts, Advanced). **den-candidate**
- [non-AI] Faster tab switching — removed legacy compositor recycling; enables BFCache.
- [AI] Deferred tool loading (tools loaded only when model searches for them).
- [non-AI] IDN support — punycode decoded in address bar, command bar, hover cards. **den-candidate**
- [non-AI] Arc import preserves custom tab names on pinned tabs/favorites. **den-candidate**
- [non-AI] New Tab Page query restoration on back-navigation. **den-candidate**

**Release notes:** [https://www.diabrowser.com/release-notes/1-28-0-look-closer](https://www.diabrowser.com/release-notes/1-28-0-look-closer) ("A closer look", Apr 23 2026, Issue No. 022, App v1.28.0). 3 videos.
- [non-AI] More scannable sidebar with tighter spacing and a slightly bigger font. **den-candidate** Details seen in video:
  - Profile chip at top-left beside the traffic lights, and an archive icon at top-right.
  - Live-group rows show a subtitle ("… commented 35 mins ago") and a blue unread dot.
  - A **collapsed group shows only its active tab**; hovering the header opens a flyout with all the group's tabs plus "+ New Tab".
  - Dragging a tile into the content area shows a dashed **"Add left split"** drop card.
- [non-AI] **Refreshed Ctrl+Tab switcher.** **den-candidate**
  - A centered floating panel with a thumbnail grid (seen as 5+4 cards). Each card is a page screenshot with favicon and truncated title.
  - Grouped tabs carry a dark group-name chip on the thumbnail.
  - The selection is a grey rounded outline that advances left→right and wraps rows; the background dims or blurs.
  - Tabs not visited in a while are hidden from the switcher.
- [non-AI] Site-colored top band: the tab strip and toolbar recolor to match the page header (seen going white → black, with icons and text inverting), updating after scroll. **den-candidate**
- [non-AI] Settings sync (Tabs, Privacy, Profiles, Memory, Shortcuts). **den-candidate**

## v1.27.0 (April 16, 2026)
- [AI] Live Documents Group (active Notion + Google Drive docs, comments/mentions).
- [non-AI] Fixed quadratic HTML-to-markdown conversion for page scraping (CPU/battery).
- [non-AI] Consolidated sync settings under Account info. **den-candidate**

**Release notes:** [https://www.diabrowser.com/release-notes/1-27-0-your-work-comes-to-you](https://www.diabrowser.com/release-notes/1-27-0-your-work-comes-to-you) ("Your work comes to you", Apr 16 2026, Issue No. 021, App v1.27.0). 1 video.
- [non-AI integration] Live Docs group ("Documents") for Notion and Google Docs. **den-candidate** (the auto-populating live-group pattern) Behavior shown:
  - Docs appear when there is activity (comments, suggestions, mentions, shares) and open scrolled to the change. Handled docs fade out, and an empty group goes quiet.
  - On creation a popover says: "Live Group Created / Comments and mentions from your team will show up here automatically".
  - Each row shows emoji/favicon + title + an activity subtitle ("Sara V. commented yesterday", "Ori S. invited you yesterday").
  - Replying and closing the tab removes the row. Pages also show viewer counts ("5 viewers today").
  - A red badge count sits on the sidebar menu icon.

## v1.26.0 (April 9, 2026)
- [non-AI] Sync across devices — profiles, bookmarks, favorites. **den-candidate**
- [non-AI] Chromium M147 update.
- [non-AI] Bookmarks: bulk-delete crash fix, clipboard URL support, undo for bulk actions. **den-candidate**
- [non-AI] Tab strip visual refresh with subtle selection animations. **den-candidate**

**Release notes:** [https://www.diabrowser.com/release-notes/1-26-0-sync-is-here](https://www.diabrowser.com/release-notes/1-26-0-sync-is-here) ("Pick up where you left off", Apr 9 2026, Issue No. 020, App v1.26.0). 1 video (two machines side by side).
- [non-AI] Sync is encrypted and local-first, with conflicts resolved client-side. **den-candidate** Setup and demo:
  - On machine 1: Settings → Sync → on → accept the privacy policy → **create a recovery kit** (a saved file; losing both the machine and the file means the data is unrecoverable).
  - On machine 2: turn on Sync → click "Connect Another Device" on machine 1 → enter the **6-character code** on machine 2.
  - Video: changing a pinned tile's icon on one machine appears on the other within seconds.
  - The pinned-tile context menu is visible: Unpin / Chat With This Tab / Open as Split / Duplicate / New Group with Tab / Add to Bookmarks… ⌘D / Add Bookmark to Folder ▸ / Copy Link ⇧⌘C / Rename… / Change Icon… / Edit Pinned Page ▸ / Mute / Close ⌘W / Close Other Tabs / Close Tabs Below.

## v1.25.0 (April 2, 2026)
- [non-AI] Persist sidebar vs. top-tabs layout across new windows and relaunches. **den-candidate**
- [non-AI] Improved tab strip / URL bar color matching (Discord, Slack, etc.). **den-candidate**
- [non-AI] Menubar and context menu redesign.

**Release notes:** [https://www.diabrowser.com/release-notes/1-25-0-details-that-delight](https://www.diabrowser.com/release-notes/1-25-0-details-that-delight) ("Details that delight", Apr 2 2026, Issue No. 019, App v1.25.0). 7 videos; in the "In case you missed it" section each video sits one heading off from what it shows.
- [non-AI] Download feedback: the file "zips toward the sidebar with a magnetic tug". **den-candidate**
  - A pill toast appears under the clicked link (filename, source, pause and X).
  - A download icon then appears in the sidebar header.
  - Clicking the icon opens a popover: "RECENT DOWNLOADS" + "Clear"; rows with a middle-truncated filename, type, and a reveal (magnifier) button; footer "View all downloads ↗".
- [non-AI] Emoji/icon tab icons. **den-candidate**
  - Right-click → "Change Icon…" opens a popover anchored to the tab with an **Emoji | Icon** segmented control, a search field, a 9-column grid, a category row at the bottom, and a trash button once an icon is set.
  - Pinned tab menu also includes "Edit Pinned Page ›".
- [non-AI] Drag a tab to the screen edge to open Split View. Each pane gets its own toolbar and close X. **den-candidate**
- [non-AI] Smooth countdown transitions on the pinned calendar tile ("in 8m" → "in 7m"). **den-candidate**
- [AI/non-AI] ICYMI recaps: rainbow shimmer on group names; Spotify notes animation; back/forward/reload press feedback.

## v1.24.0 (March 26, 2026)
- [non-AI] "Share this tab instead" — switch shared tab with one click during screen share. **den-candidate**

**Release notes:** [https://www.diabrowser.com/release-notes/1-24-0-dia-got-faster](https://www.diabrowser.com/release-notes/1-24-0-dia-got-faster) ("Dia got faster", Mar 26 2026, Issue No. 018, App v1.24.0). Media not informative.
- [non-AI] Memory-leak fixes. A platform bug kept views alive after tab switches, in some cases holding gigabytes (per page). **den-candidate**
- [non-AI] Cheaper New Tab Page animations (lower CPU/GPU use when other tabs are busy). **den-candidate**
- [non-AI] Faster command bar: work moved out of the suggestion path, and the favicon and database caches are warmed at startup. **den-candidate**
- [AI] The search-vs-chat routing step is skipped under system load. The idea of shedding optional work under load transfers to den.
- [non-AI] Help → Record a Performance Issue. **den-candidate**

## v1.23.0 (March 19, 2026)
- [non-AI] Completion animation when merging a PR / finishing a review. **den-candidate**
- [non-AI] Completed PRs clear from GitHub Live Group more legibly. **den-candidate**
- [non-AI] Hover to recall recently completed PR. **den-candidate**

**Release notes:** [https://www.diabrowser.com/release-notes/1-23-0-from-review-to-merge-to-whats-next](https://www.diabrowser.com/release-notes/1-23-0-from-review-to-merge-to-whats-next) ("From review to merge to what's next", Mar 19 2026, Issue No. 017, App v1.23.0). 5 videos.
- [non-AI] GitHub Live Group, as seen in the videos. **den-candidate**
  - Created by right-clicking empty sidebar space: New Tab ⌘T / Reopen Closed Tab / New Group / **New Live Group › Pull Requests** / Bookmark All Tabs / ✓ Show Tabs in Sidebar ⇧⌘S / Auto-Hide Tabs ⌘S.
  - PR rows have two lines: title, then "author • state" ("Reviewed ✓", "Approved", "Merged ✓"), with a status-ring favicon.
- [non-AI] Completion flow: reviewing or merging updates the row subtitle, and the row then leaves the group. The group header gains a **"2 ✓" count badge**. Hovering the badge opens a **"Recently Closed" popover**, and clicking an item restores the PR tab. **den-candidate**
- [non-AI] More expressive back/forward/reload press animations (rounded grey pressed background). **den-candidate**

## v1.22.0 (March 12, 2026)
- [non-AI] Fast profile switcher — Ctrl+1–9; color-coded profile menu with shortcut hints; profile windows switch in place. **den-candidate**
- [AI] Command bar shortcuts: ⌃⌘↩ route to Chat. (⇧⌘↩ → Google Search is non-AI: **den-candidate** as "search directly" shortcut.)
- [non-AI] GitHub Live Tab Groups update in real time on merge/review/close. **den-candidate**
- [non-AI] Ad-block reload prompt when page has unsaved changes. **den-candidate**
- [AI] Ask-on-Page reads iframes and shadow DOM.
- [non-AI] Major performance / memory-leak fixes on new tab; Help → "Record Performance Issue". **den-candidate**

**Release notes:** [https://www.diabrowser.com/release-notes/1-22-0-dont-think](https://www.diabrowser.com/release-notes/1-22-0-dont-think) ("Don't think about the next step. Take it.", Mar 11 2026, Issue No. 016, App v1.22.0; the changelog dates it Mar 12). No videos.
- [AI] Proactive Suggestions on New Tab; can be turned off in Personalization.
- [non-AI] Performance and memory-leak fixes; Help → "Record Performance Issue". **den-candidate**
- [non-AI] Ctrl+1/2/3… profile switching. **den-candidate**
- [mixed] Command bar modifiers route straight to Chat [AI] or Google Search [non-AI]. **den-candidate** (search route)

## v1.21.0 (March 5, 2026)
- [non-AI] Sleep fix — resource lock no longer prevents Mac sleep. **den-candidate**
- [non-AI] Tab context menu shows keyboard shortcuts (incl. custom). **den-candidate**
- [non-AI] Setting: new tabs at top of sidebar. **den-candidate**

**Release notes:** [https://www.diabrowser.com/release-notes/1-21-0-before-you-reach-for-it](https://www.diabrowser.com/release-notes/1-21-0-before-you-reach-for-it) ("Before you reach for it…", Mar 5 2026, Issue No. 015, App v1.21.0). 7 videos.
- [non-AI] The tab context menu shows shortcuts, including customized ones. **den-candidate**
  - Full order: Pin / Open as Split / Duplicate / New Group with Tab / Move Tab to Group › / Move Tab to Window › / Add to Bookmarks Bar ⌘D / Add Bookmark to Folder › / Copy Link ⇧⌘C / Mute / Rename… / Change Icon… / Add Tab to Chat / Close ⌘W / Close Other Tabs / Close Tabs Below.
  - Shortcuts are customizable in Settings → Shortcuts.
- [non-AI] Featured shortcuts, each demoed with a large black keycap overlay at bottom-center. **den-candidate**
  - **⌘⇧S** switches between topbar and sidebar layouts.
  - **⌘S** hides or shows the tab strip.
  - **⌘⇧K** closes all tabs.
  - **⌃Tab / ⌃⇧Tab** opens a horizontal thumbnail switcher (MRU order observed).
  - **⌘⇧C** copies the URL.
  - **⌘T** opens a new tab. The command box placeholders rotate ("Search the web…", "Mention a tab…").

## v1.20.0 (February 26, 2026)
- [non-AI] Spotify mini player on hover over pinned Spotify tab (skip/pause/play, album art, volume pulse, mute indicator). **den-candidate**
- [non-AI] Per-split navigation and bookmark bars; independent tint; focused-pane emphasis; per-pane close. **den-candidate**
- [non-AI] Sidebar toggle button in navigation bar. **den-candidate**
- [non-AI] Paste and Go / Paste and Search on right-click. **den-candidate**
- [AI] Automatic group name shimmer animation.
- [non-AI] Command bar onboarding suggestions (first week; import, Google login). **den-candidate**
- [non-AI] Dock right-click per-profile "New Window". **den-candidate**
- [non-AI] Document PiP windows show opener hostname (safety). **den-candidate**

**Release notes:** [https://www.diabrowser.com/release-notes/1-20-0-little-moments-big-feeling](https://www.diabrowser.com/release-notes/1-20-0-little-moments-big-feeling) ("Little moments. Big feeling.", Feb 26 2026, Issue No. 014, App v1.20.0). 5 videos.
- [non-AI] Spotify Mini Player. **den-candidate**
  - Hovering the pinned Spotify tile opens a floating white card beside the sidebar: album art, bold title, grey artist, prev/pause/next, elapsed time, a progress bar, and a negative remaining time.
  - The pinned tile turns Spotify-green while playing, with animated music notes.
- [non-AI] Split View panes each get their own back/forward/reload + URL row and close X. **den-candidate**
  - Typing in a pane opens a command-bar dropdown scoped to that pane.
  - Panes can be swapped (the swap itself was not captured in frames).
- [AI naming / non-AI animation] A rainbow gradient sweeps across the auto-generated group name, then settles into the tint color. **den-candidate** (animation only)
- [non-AI] Focus Mode toggle: a sidebar icon immediately left of Back. When the sidebar collapses, the toolbar shifts to the window's left edge and the traffic lights hide. **den-candidate**

## v1.19.0 (February 19, 2026)
- [AI] Proactive Suggestions synced across windows.
- [AI] Automatic tab group naming.
- [AI] Fix malformed markdown hyperlinks in chat.
- [non-AI] Fix drag from Recent Downloads also opening file in default app. **den-candidate**
- [non-AI] Dock new-window focus fix. **den-candidate**
- [non-AI] Suppress update prompts during video calls / screen or tab recording. **den-candidate**
- [non-AI] ⌥⇧⌘C copy URL as markdown link (from Arc). **den-candidate**
- [non-AI] Calendar badge animations on pinned tabs.

**Release notes:** [https://www.diabrowser.com/release-notes/1-19-0-tab-groups-and-proactive-suggestions](https://www.diabrowser.com/release-notes/1-19-0-tab-groups-and-proactive-suggestions) ("Multiplying tabs? Dia keeps them in check", Feb 19 2026, Issue No. 013, App v1.19.0). 3 videos.
- [AI] Automatic tab group names, generated from group contents. The name re-generates as tabs are added, and added tabs reorder to the top of the group.
- [non-AI UX seen] Multi-select context menu: Pin / Add to Split / Duplicate / New Group with Tabs / Add Tabs to Bookmarks Bar / Add Tabs to Folder › / Copy URLs / Add Tabs to Chat / Close / Close Other Tabs / Close Tabs Below. **den-candidate**
- [non-AI UX seen] **Tab hover card**: title + host, with pin, bookmark, and split icon buttons. **den-candidate**
- [AI] Proactive Suggestions appear as a list inside the New Tab input card. Each row is favicon + action + "— host", with an X on hover to dismiss.

## v1.18.1 (February 12, 2026)
- [non-AI] New Tab Groups auto-pinned. **den-candidate**
- [non-AI] Reopen closed window (all tabs + groups) from File menu. **den-candidate**
- [non-AI] Bookmarks Bar shows only explicitly closed groups not open elsewhere. **den-candidate**
- [non-AI] Tab strip truncation fix with Tab Groups.
- [non-AI] Close Tab Groups from top bar. **den-candidate**
- [non-AI] Sidebar auto-scrolls to reveal ⌘-clicked background tab from a Favorite. **den-candidate**
- [non-AI] Copy multiple tab URLs at once. **den-candidate**
- [non-AI] Import Chrome Tab Groups as bookmarks. **den-candidate**
- [non-AI] Incognito windows dark by default. **den-candidate**
- [non-AI] Favicon cache capped at 1,000 entries for faster startup. **den-candidate**

**Release notes:** [https://www.diabrowser.com/release-notes/1-18-1-your-setup-your-way](https://www.diabrowser.com/release-notes/1-18-1-your-setup-your-way) ("Your setup, your way", Feb 12 2026, Issue No. 012, App v1.18.1). 3 videos.
- [non-AI] Auto-pinned groups. **den-candidate**
  - A new group appears at the top with its header name selected for inline rename.
  - A collapsed group shows only its active tab. Pinned groups sit above a divider.
  - The window chrome is tinted by the profile theme.
- [non-AI] File menu, with shortcuts legible in the video. **den-candidate**
  - New Tab ⌘T / New Tab in Group ⌥⌘T / New Window › (one entry per profile, plus New Incognito Window ⇧⌘N) / Reopen Closed Tab ⇧⌘T / **Reopen Closed Window** / Open Command Bar ⌘L / Chat ⌘E / Focus Chat ⌃⌘E / Close Window ⇧⌘W / Close Tab ⌘W / Close All Tabs ⇧⌘K / Print ⌘P.
  - Menu bar: Dia, File, Edit, View, Tabs, Bookmarks, History, Extensions, Window, Developer, Help.
- [non-AI] Dark incognito window: dark grey chrome, "Incognito" profile pill, and a dark-red radial glow behind the NTP input. **den-candidate**
- [non-AI] Favicon cache capped at 1,000 entries (previously "tens of thousands" per page). **den-candidate**

## v1.17.0 (February 5, 2026)
- [non-AI] GitHub Live Tab Groups — auto-populated with your PRs and review requests; right-click sidebar/tab strip to create. **den-candidate**
- [non-AI] New Tab button pins to sidebar bottom on overflow. **den-candidate**
- [non-AI] Manifest V2 extensions disabled.
- [non-AI] Pinned extension icon fixes (load, drag, flicker).
- [non-AI] Meeting reminders placement on multi-monitor / floating windows.
- [non-AI] Better meeting link detection for meeting tab group.
- [non-AI] Meeting tab group title wiggles at 5- and 2-minute marks. **den-candidate**

**Release notes:** [https://www.diabrowser.com/release-notes/1-17-0-github-live-tab-groups](https://www.diabrowser.com/release-notes/1-17-0-github-live-tab-groups) ("Live Tab Groups are here", Feb 5 2026, Issue No. 011, App v1.17.0). 4 videos.
- [non-AI] GitHub Live Group. **den-candidate**
  - Created automatically the first time you open a PR, with no setup, and pinned by default.
  - Popover: "Live Group Created / Pull requests from you and your team will show up here automatically".
  - Rows are two lines (PR title + grey author).
  - Live updates: new PRs insert at the top; merged or approved PRs get a green check badge on the favicon, then animate out.
- [non-AI] A visual cue prompts GitHub reauth when fetching fails. **den-candidate**
- [non-AI] Right-click menu to refresh the group or configure which repos/PRs show. **den-candidate**
- [non-AI] Pinned Calendar tile shows the day number and an "in 4m" caption. A dashed "pin slot" tile is shown for adding pins. **den-candidate**

## v1.16.0 (January 29, 2026)
- [non-AI] Pin tab groups to sidebar top / tab strip leading edge. **den-candidate**
- [non-AI] ⌘-click link opens into a new tab group with the original. **den-candidate**
- [non-AI] ⌥⌘T new tab inside current group. **den-candidate**
- [non-AI] Tabs pane in Settings (layout, group behaviors). **den-candidate**
- [non-AI] Recently closed groups in Tab Overflow and History menus. **den-candidate**
- [non-AI] Profile indicator in pinned tray / sidebar header; standardized empty-space context menus. **den-candidate**
- [non-AI] Set default profile from Profiles pane. **den-candidate**
- [non-AI] Manifest V2 phase-out notice (built-in ad blocker cited).

**Release notes:** [https://www.diabrowser.com/release-notes/1-16-0-organization-that-grows](https://www.diabrowser.com/release-notes/1-16-0-organization-that-grows) ("Onboarding without tab overload", Jan 29 2026, Issue No. 010, App v1.16.0). 4 videos. Intro: tab organization is opt-in and "grows with you" rather than being forced as in Arc.
- [non-AI] ⌘-clicking links from a doc auto-creates "Group 1" containing the source doc and each opened link. **den-candidate**
  - Group header menu: 8 color swatches / Rename… / Change Icon… / Pin Group / Chat with "…" / Copy URLs in Group / Move Group to › / Ungroup Tabs / New Tab in Group / Duplicate Group / Close and Move to Bookmark Bar / Delete Group.
  - The header is renamable in place.
- [non-AI] Pinned groups sync across all windows in a profile and persist across restarts. They sit under the pinned tiles, above a divider. **den-candidate**
- [AI] The @-picker for chat attachments has TABS, GROUPS, and FILES sections, plus "All open <domain> tabs (n)" entries.
- [non-AI] Closing a group (X on header) turns it into an emoji chip at the left of the bookmarks bar. **den-candidate**
- [non-AI] Tabs panel in Settings. MV2 end-of-support notice.

## v1.15.0 (January 23, 2026)
- [non-AI] Google Meet PiP Share returns to Meet tab.
- [non-AI] Auto-reload after disabling ad block. **den-candidate**
- [AI] Delete chat conversations from Chat history.
- [AI] Slack scraping improvements.
- [non-AI] New Tab Page themed with profile color, gradient animation. **den-candidate**
- [non-AI] macOS Tahoe Liquid Glass visuals, glass-style icon. **den-candidate**
- [non-AI] F12 opens DevTools; F1–F12 bindable as shortcuts. **den-candidate**
- [non-AI] Tab Handoff from iPhone via macOS Handoff. **den-candidate**
- [non-AI] Confirm-dialog loop protection (close stuck tab without locking window). **den-candidate**
- [non-AI] Bookmark Bar menus auto-size up to 600px. **den-candidate**
- [non-AI] Select and copy text in dialogs. **den-candidate**

**Release notes:** [https://www.diabrowser.com/release-notes/1-15-1-polish-galore](https://www.diabrowser.com/release-notes/1-15-1-polish-galore) ("Better organization, better context", Jan 23 2026, Issue No. 009, **App v1.15.1**). 3 videos.
- [non-AI] Customize tab icons: the Change Icon… popover (Emoji | Icon, search, category row, trash) replaces the favicon in the row. **den-candidate**
- [non-AI] Bolder profile colors. **den-candidate**
  - The profile pill menu shows "SWITCH PROFILES ⇧⌘P", a list with a checkmark, and "Edit Profiles".
  - Settings tabs: Account, Tabs, Privacy, Profiles, Memory, Dia Pro, Shortcuts, Advanced.
  - The Profiles pane has a color square per profile (8 swatches), + and … buttons, and a "Create a Profile" sheet.
  - A new profile window is fully tinted in its color.
- [non-AI] Hovering a group shows an X; closing moves it to the bookmarks bar as a chip. **den-candidate**
- [non-AI] Toggling the content blocker auto-reloads the page, confirming first if there are unsaved changes. **den-candidate**
- [non-AI] Tahoe radii and glass icon; F12 DevTools and F1–F12 bindable; Handoff from iPhone (Dia's icon appears in the Dock when it is the default browser). **den-candidate**
- [AI] Slack structured reading, link favicons and tooltips in answers, chat deletion.

## v1.14.0 (January 15, 2026)
- [non-AI] Tab Groups for Meetings — auto meeting group on join, related links, time-left, converts to normal group, auto-cleanup. **den-candidate**
- [AI] @-mention Tab Groups in chat.
- [non-AI] Close tab groups via X in sidebar; right-click copy all URLs in group. **den-candidate**
- [non-AI] ⌘⇧A tab search across all windows in profile. **den-candidate**
- [non-AI] Custom emoji/icon per tab. **den-candidate**
- [non-AI] Change default profile; delete non-default profiles. **den-candidate**
- [AI] Cleaner assistant links (favicons, titles, tooltips).
- [AI] Assistant Google search scraping rate-limited to avoid reCAPTCHA.
- [AI] YouTube summaries in chat.
- [non-AI] Status page status.diabrowser.com.
- [non-AI] Extension-provided search engines fixed. **den-candidate**
- [non-AI] Duplicating a pinned tab opens a normal tab. **den-candidate**
- [non-AI] Popups support printing, Find in Page, ⌘⇧C copy. **den-candidate**
- [non-AI] Chromium 144 bump.

**Release notes:** [https://www.diabrowser.com/release-notes/1-14-0-meeting-tab-groups](https://www.diabrowser.com/release-notes/1-14-0-meeting-tab-groups) ("Join the call. We'll handle the tabs.", Jan 15 2026, Issue No. 008, App v1.14.0). 6 videos.
- [non-AI] Meeting Tab Groups (requires Google Calendar pinned and authenticated). **den-candidate**
  - Joining from the calendar-tile hover ("Join ↩") creates a group anchored at the top.
  - The meeting tab shows a Meet icon with a red dot. Links from the event description or meeting chat are added to the group.
  - After the call the group becomes a normal group, with cleanup.
- [non-AI] **Tab hover card** to the right of the sidebar row: title + host plus pin, bookmark, split, and chat icons. **den-candidate**
- [non-AI] Tab context menu (horizontal mode): Pin / Open as Split / Duplicate / New Group with Tab / Move Tab to Window…. A pinned tab becomes an icon-only tile. **den-candidate**
- [AI] Chat with a Tab Group (group menu → "Chat with …"; attachment chip "All Tabs in group").

## v1.13.1 (January 8, 2026) — intro describes 1.13.0
- [non-AI] Tab groups: closed groups overflow into button; group menus with icons/colors; new groups enter rename; single-tab ⌘-click groups auto-ungroup. **den-candidate**
- [non-AI] Side panel refined, no flicker between tabs. **den-candidate**
- [non-AI] Ad blocker blocklists updated. **den-candidate**
- [non-AI] Favicon cache pre-warmed on launch; Notion favicon fix. **den-candidate**
- [non-AI] Bookmark save interstitial shows full folder tree inline. **den-candidate**
- [AI] Chat list rendering fixes.
- [AI] Notion attachment scraping improvements.
- [non-AI] Meeting reminders with platform-specific branding.

**Release notes:** [https://www.diabrowser.com/release-notes/1-13-1-new-year-new-polish](https://www.diabrowser.com/release-notes/1-13-1-new-year-new-polish) ("Carrying it forward in 2026", Jan 8 2026, Issue No. 007, App v1.13.1). 1 video.
- [non-AI] Closed groups live as tinted chips (name + favicon stack) in the bookmarks bar, newest first. When the bar fills, extras overflow behind a **⊞ button** whose menu lists them plus "Create New Group"; picking one restores it to the sidebar top. **den-candidate**
  - Group menu: Change Icon / Chat with / Copy URLs in Group / Move Group to › / Ungroup Tabs / New Tab in Group / Duplicate Group / Close Group / Close and Delete Group.
- [non-AI] Favicon, ad-block, side panel, and bookmark folder-tree items as in the changelog (no media). **den-candidate**
- [AI] If a page-load selector never appears, attachments fall back to a best-effort scrape instead of timing out.

## v1.10.1 (December 18, 2025) — intro describes 1.10.0
- [non-AI] Chromium Side Panel API support for extensions. **den-candidate**
- [non-AI] Tab group color derived from favicon / theme color; rename on create. **den-candidate**
- [AI] Google Sheets full reading in chat.
- [AI] Retry query without failed attachment.
- [AI] Ask on Page links open in new foreground tab.
- [non-AI] Non-US keyboard layout shortcuts fixed (AZERTY, Dvorak). **den-candidate**
- [non-AI] Fewer dark-mode white flashes (Notion/Slack) on tab switch. **den-candidate**
- [non-AI] Duplicated traffic-lights fix (speculative).
- [non-AI] ⌘/middle-click back/forward/reload history entries to open in new tab. **den-candidate**
- [non-AI] Fullscreen API can target another display. **den-candidate**

**Release notes:** [https://www.diabrowser.com/release-notes/1-10-1-year-end-release](https://www.diabrowser.com/release-notes/1-10-1-year-end-release) ("No loose ends", Dec 18 2025, Issue No. 006, **page data says App v1.10.0**). 1 video.
- [non-AI] Group color is auto-derived from the favicon or URL-bar color. Video: a group from Hacker News is tinted orange, one from cash.app green, and the grouped area takes a light matching tint. **den-candidate**
  - Tab menu seen: Pin / Open as Split / Duplicate / Move Tab to Group › / Move Tab to Window › / Add to Bookmarks Bar / Add Bookmark to Folder › / Copy Link / Mute / Rename… / Add Tab to Chat / Close / Close Other Tabs.
- [non-AI] The Calendar tab shows time to the next meeting in both sidebar and top bar ("Arc favorite"). **den-candidate**
- [non-AI] ⌘/middle-click on back/forward/reload history entries opens a background tab; add Shift for foreground. **den-candidate**
- [non-AI] Notion and Slack get an enforced dark background (fixes white flash). Non-US layout shortcuts; traffic-lights fix. **den-candidate**
- [AI] Sheets, retry without attachment, Ask on Page links open inside the active group.

## v1.9.0 (December 11, 2025)
- [non-AI] Tab Groups — color-coded, customizable, persistent. **den-candidate**
- [non-AI] Meetings: Active Meeting tab group on join, relevant links, live Calendar icon badge (time to next meeting), logged-out preview sign-in prompt. **den-candidate**
- [AI] Automatic tool calling (Gmail, GCal, Slack, Tabs).
- [non-AI] Command bar "new wiki/jira/form/meeting/gist/Figma…" creation shortcuts. **den-candidate**
- [AI] Fewer accidental voice triggers.
- [non-AI] Resy loading fix.

**Release notes:** [https://www.diabrowser.com/release-notes/1-9-0-tab-groups](https://www.diabrowser.com/release-notes/1-9-0-tab-groups) ("Organize your Tabs", Dec 11 2025, Issue No. 005, **page data says App v1.9.1**). 4 videos.
- [non-AI] Tab Groups. **den-candidate**
  - Top bar: groups are tinted pills with a favicon stack. Hovering a pill opens a list card of its tabs + "+ New Tab"; clicking expands it inline.
  - Sidebar: a tinted header row with indented tabs; drag a tab onto a header to add it.
  - Right-click menu: inline name field / 8 color dots / Change Icon › (emoji search) / Move Group to › / Ungroup Tabs / New Tab in Group / Close Group / Delete Group.
  - A closed group becomes a chip in the bookmarks bar; ⌘-click reopens it in a new window.
- [non-AI] More "new …" commands (blog, wiki, jira). Resy fix.

## v1.8.0 (December 4, 2025)
- [non-AI] Double-click tab to rename. **den-candidate**
- [AI] Voice input UI refresh + keyboard shortcuts.
- [AI] Slack activity search (mentions, unreads).
- [non-AI] Command bar "new …" to create doc/sheet/slides/ticket. **den-candidate**
- [non-AI] No background flash on tab close; last 10 recently used tabs protected from discard. **den-candidate**
- [non-AI] Cancel paused downloads. **den-candidate**
- [non-AI] Google Meet PiP reliability. **den-candidate**
- [non-AI] Chrome import keeps pinned tabs pinned. **den-candidate**

**Release notes:** [https://www.diabrowser.com/release-notes/1-8-0-direct-from-the-team](https://www.diabrowser.com/release-notes/1-8-0-direct-from-the-team) ("Direct from Team Dia", Dec 4 2025, Issue No. 004, App v1.8.0). 4 videos.
- [non-AI] Double-click a tab to rename it in place: the title is fully selected in an inline field. Works in sidebar and strip. **den-candidate**
- [non-AI] Command bar "new notion" suggests "New Notion page — notion.new" as the top row, and the input's leading icon switches to the service logo. **den-candidate**
- [AI] Voice input: hold ⌘T for about 1s to open a Voice tab. Esc cancels, Return stops, ⌘Return sends. It shows a waveform, a timer, and a stop button.
- [AI] Slack mentions/unreads in chat.

## v1.7.0 (December 1, 2025)
- [non-AI] AppleScript support (query/focus windows & tabs) + Raycast integration. **den-candidate**
- [AI] Memory Search from Tab Overflow menu.
- [non-AI] Bookmarks in command bar results alongside history, relevance-ranked. **den-candidate**
- [non-AI] Tab hover actions: Pin, Bookmark, Split with Tab (+ Open Chat [AI]). **den-candidate**
- [non-AI] Reduced high-contrast flashes on tab switch/navigate. **den-candidate**
- [non-AI] Presented-tab favicon indicator while screen sharing. **den-candidate**
- [non-AI] Meeting reminder in PiP. **den-candidate**

**Release notes:** [https://www.diabrowser.com/release-notes/1-7-0-flow-state](https://www.diabrowser.com/release-notes/1-7-0-flow-state) ("Find Yourself in Flow State", Dec 1 2025, Issue No. 003, App v1.7.0). 3 videos.
- [non-AI] AppleScript support. The first consumer is a **Raycast extension** that opens or focuses tabs, searches history, and switches profiles. Its footer shows "Search Tabs", "Focus Tab ↵", and "Actions ⌘K". **den-candidate**
- [non-AI] The Tab Overflow menu (down arrow, top-right) searches open and recently closed tabs; memory search is [AI]. **den-candidate**
- [non-AI] Bookmarks ranked in command bar results like history. Reduced white flashing. **den-candidate**
- [non-AI] Meeting reminder moved into a real PiP window. **den-candidate**
  - Drag with two fingers; it snaps to corners and avoids screen edges.
  - Card content: title + "3 min ago", organizer, and "Ignore" / "Related Docs ⌄" / "Join Meet".

## v1.6.0 (November 20, 2025)
- [AI] Search Slack tool.
- [AI] Streaming transcription for voice mode.
- [non-AI] Meeting reminder redesign (attached to calendar tab, movable). **den-candidate**
- [AI] Tool call bylines for tab read/open/close.
- [AI] Smarter tab attachment suggestion ranking.
- [AI] Fewer false safety errors (injection detection, LaTeX, tool handling).
- [non-AI] Toast shown for actions in fullscreen mode. **den-candidate**

**Release notes:** [https://www.diabrowser.com/release-notes/1-6-0-conversations-context-chat](https://www.diabrowser.com/release-notes/1-6-0-conversations-context-chat) ("Conversations, Context, and Chat", Nov 20 2025, Issue No. 002, App v1.6.0). 3 videos.
- [AI] Slack search tool. The @-picker has TABS / FILES / TOOLS sections, and the chosen tool shows as a chip.
- [AI] Streaming voice transcription UI: waveform, timer, and a check button.
- [AI] Tab tool-call bylines; truly automatic memory search.

## v1.5.0 (November 13, 2025)
- [non-AI] Live Calendar Preview on Calendar tab hover + just-in-time corner meeting reminder with join link. **den-candidate**
- [non-AI] Smart reload of recent background tabs on launch; discarding considers app active time. **den-candidate**
- [non-AI] Split view larger drop targets. **den-candidate**
- [non-AI] Focus Mode by fully collapsing sidebar. **den-candidate**
- [non-AI] Find in Page restyled. **den-candidate**
- [AI] Chat attachment-failure clarity; Memory Search triggers more often.
- [AI] Core chat behavior (Read Links progress, image reasoning, inline code, icon contrast, "Recreate" fix).
- [AI] Deep reasoning "Skip" falls back to minimal reasoning.

**Release notes:** [https://www.diabrowser.com/release-notes/1-5-0-meet-me-in-dia](https://www.diabrowser.com/release-notes/1-5-0-meet-me-in-dia) ("Meet Me in Dia", **Nov 10 2025** on page vs Nov 13 in changelog; Issue No. 001, App v1.5.0). 4 videos.
- [non-AI] Live Calendar Preview: hovering the Calendar tab drops a white card under it. **den-candidate**
  - Header "Calendar" + X.
  - Event rows ("Apps Standup / In 1 min — 1:15-1:45PM") with a "Join Meeting ↵" button.
  - Footer buttons "Chat" and "New Event".
- [non-AI] Just-in-time reminder: a bottom-right toast with title + "now", participant avatars and names, and "View Event" / "Join Meet" buttons. **den-candidate**
- [non-AI] Dragging the sidebar edge to fully collapse it enters Focus Mode (traffic lights hide); dragging back restores it. **den-candidate**
- [non-AI] Refreshed Find in Page (⌘F); keep-alive for recent tabs. **den-candidate**
- [AI] Calmer chat answers.

## v1.4.0 (November 6, 2025)
- [AI] @Tabs — open/close tabs from chat.
- [non-AI] Pinned tabs refresh; ⌘↩ returns pinned tab to base URL. **den-candidate**
- [AI] Automatic Memory Search (profile-specific).
- [non-AI] Split view: nav-bar split button, "Open as Split". **den-candidate**
- [non-AI] Haptic feedback when dragging tabs. **den-candidate**
- [non-AI] iCloud Passkeys support. **den-candidate**
- [non-AI] HTTP/3 to reduce network-change errors.

## v1.3.1 (October 30, 2025) — intro describes 1.3.0
- [non-AI] PiP on Google Meet when switching tabs. **den-candidate**
- [non-AI] Focus Mode ⌘S hides tabs (horizontal and vertical). **den-candidate**
- [non-AI] Remap keyboard shortcuts in Settings. **den-candidate**
- [AI] Automatic memory search.
- [non-AI] Fix pasting bulleted/numbered lists with formatting.

## v1.2.0 (October 24, 2025)
- [AI] Natural Language Skill Builder (New Tab → Skills → New Skill).

## v1.1.0 (October 16, 2025)
- [AI] Gmail tool.
- [AI] Google Calendar tool.
- [AI] Autofill tool (@Autofill in chat).
- [non-AI] Multi-select tabs (⌘ / Shift) → "Add tabs to bookmarks bar". **den-candidate**
- [non-AI] New bookmark folder prompts immediate rename. **den-candidate**
- [non-AI] Bookmark right-click context actions. **den-candidate**
- [non-AI] ⌥/⌘-click bookmark folder opens all tabs. **den-candidate**
- [non-AI] ⌘-click bookmark → background tab; ⌥-click → split. **den-candidate**

## v1.0.1 (October 9, 2025) — general availability on macOS
- [non-AI] GA on macOS, no waitlist.
- [AI] Skill builder revamp (popup editor, distinct steps).
- [AI] Command Bar / Skill builder toolbar for @actions and @formats.
- [AI] Shimmer animation when @-mentioning in Command Bar.
- [AI] @Search Memory replaces @History.
- [non-AI] Chromium 141.0.7390.66.

## v0.49.0 (October 2, 2025)
- [non-AI] Payment processing fix on some websites.
- [AI] Chat tables/charts no longer flicker while loading.
- [non-AI] Chromium M141 upgrade + bug fixes.

## v0.48.0 (September 25, 2025)
- [non-AI] Cancel page load with X next to address bar. **den-candidate**
- [non-AI] More link-safety stopgaps against bad actors. **den-candidate**
- [AI] Skills without slash commands.
- [AI] GPT-5 for all queries.

## v0.47.0 (September 18, 2025)
- [AI] Citations render as working hyperlinks.
- [AI] Replies with less heavy formatting; Personalization pane control.
- [AI] Skip "Thinking deeply…" for a quicker answer.
- [non-AI] Command Bar dropdown shows chosen default search engine. **den-candidate**
- [non-AI] ⌥-click New Tab (+) opens New Tab Page in a split. **den-candidate**
- [AI] Chat images right-click save/copy up front.

## v0.46.0 (September 11, 2025)
- [AI] GPT-5 for /research and Skills; readability, writing-help logic, answer-first, fewer clarifying questions.
- [non-AI] Images load more consistently; simplified image right-click menu.
- [non-AI] Low-disk warning below 300 MB free. **den-candidate**
- [non-AI] Increased beta invites (Dia > Invite to Dia…).

## v0.45.0 (September 8, 2025)
- [AI] Memory excludes sensitive sites and incognito; per-site opt-out deletes prior memories.
- [AI] Location detail nuance in Memory; AI responses excluded from Memory; activity summary formatting.
- [AI] Historic Skills + Browsing History Skills Pack (future-self, daily-wrap, weekly).
- [AI] ChatGPT history import as Memories.
- [AI] Safety checks toned down (fewer false alarms).
- [non-AI] Sad-tab crash landing page. **den-candidate**
- [non-AI] Middle-click / ⌘-click bookmarks open in background tab. **den-candidate**

## v0.44.0 (August 28, 2025)
- [non-AI] Split view: ⇧⌥-click opens link in right-hand split. **den-candidate**
- [AI] Safety alerts more accurate.
- [non-AI] Download notifications no longer show source site address (anti-spoofing). **den-candidate**
- [non-AI] Downloads menu pops up correctly and lists all previous downloads. **den-candidate**
- [non-AI] Unused profiles auto-unload to free memory. **den-candidate**
- [non-AI] Bluetooth dialogs show full web address of requester. **den-candidate**
- [AI] @history includes Chats.
- [AI] Smarter PDF reader (for chat).
- [AI] Write and Code polish.
- [AI] Try Skills from Skills Gallery without install.
- [AI] @-mention tab dropdown hides already-mentioned tabs.
- [AI] Backup AI models on failure.
- [AI] Memory prompt updates; per-Profile Memory toggle; delete individual Memories; per-chat Personalization toggle.

## v0.43.0 (August 21, 2025)
- [AI] Memory refreshes more frequently.
- [AI] Reasoning follows links from attached pages.
- [non-AI] Fix double traffic lights in fullscreen.
- [non-AI] Improved Chinese/Korean input in Command Bar. **den-candidate**
- [AI] Built-in Skills from Team Dia (New Tab > Skills).
- [AI] Student Skills pack.
- [AI] Richer Google Calendar reading (attendees, descriptions, call links).
- [AI] Visible thinking steps with source dropdown.

---

## Non-AI conveniences for den — shortlist

### Tab management & organization
- Tab Groups: color-coded, persistent (v1.9.0); color from favicon/theme + rename-on-create (v1.10.1); auto-pinned (v1.18.1); pin groups to sidebar/tab strip (v1.16.0)
- ⌘-click link → new group with original; ⌥⌘T new tab in group (v1.16.0); single-tab groups auto-ungroup (v1.13.1)
- ⌃⌘N new group from selected tabs (v1.47.1)
- Recently closed groups restore (v1.16.0); reopen closed window from File menu (v1.18.1)
- Double-click tab to rename (v1.8.0); custom emoji per tab (v1.14.0)
- Copy multiple tab URLs / copy all URLs in group (v1.18.1, v1.14.0)
- Tidy tabs: prompt to archive 10+ stale tabs (v1.30.0); stale New Tab Pages auto-clear (v1.38.0)
- Overflow menu: open + recently closed + synced devices (v1.30.0)
- Profile-wide tab search ⌘⇧A (v1.14.0)
- New tabs at top setting (v1.21.0); New Tab button pinned on overflow (v1.17.0)
- Domain-wide tab muting (v1.48.0)
- Pinned tab ⌘↩ back to base URL (v1.4.0); duplicate-pinned → normal tab (v1.14.0)
- Background-tab visibility in peeked groups (v1.47.1); sidebar scrolls to new background tab (v1.18.1)
- Haptic feedback on tab drag (v1.4.0)
- (RN) Tab Cleanup popover with "Not Now" (esc), "Clean Up Once", and "Clean Up Daily" (↵), plus a "Cleaned up N tabs" broom chip (v1.30.0). Staleness windows 12h/24h/3d/7d; ⌘⌥K manual sweep (v1.33.0)
- (RN) Closed groups become bookmarks-bar chips, overflowing behind a ⊞ button menu (v1.13.1); ⌘-click a chip to reopen it in a new window (v1.9.0)
- (RN) Group header menu: 8 color swatches, Rename, Change Icon, Pin, Copy URLs, Move, Ungroup, New Tab in Group, Duplicate, Close→Bookmark Bar, Delete (v1.16.0). Group color auto-derived from favicon (v1.10.1). A collapsed group shows only its active tab, with a hover flyout of all tabs (v1.28.0)
- (RN) Change Icon popover (Emoji | Icon, search, categories, trash) for tabs and pinned tiles (v1.15.0, v1.25.0)
- (RN) Context menus: full orders documented for tab (v1.21.0), multi-select (v1.19.0), pinned tile (v1.26.0), and empty sidebar space (v1.23.0)

### Hover cards & previews
- Tab hover actions: pin, bookmark, split (v1.7.0)
- Calendar tab hover live preview (v1.5.0)
- Spotify mini-player on hover (v1.20.0)
- PR hover: CI status + merge conflicts (v1.31.0); hover to recall completed PR (v1.23.0)
- (RN) Tab hover card: title + host plus pin, bookmark, split, and chat buttons (v1.14.0, v1.19.0)
- (RN) Calendar tile hover card: event rows with "Join ↵" and "New Event" (v1.5.0, v1.49.0). Interactive checklist hover card on a tab (v1.38.0)
- (RN) Top-bar group pill hover lists the group's tabs (v1.9.0)

### GitHub / PR integration (non-AI)
- GitHub Live Tab Groups: auto-populated PRs + review requests (v1.17.0); real-time updates (v1.22.0)
- Completion animation + legible cleanup (v1.23.0); PR stacks positions (v1.46.0), collapsible with persisted state (v1.50.0)
- Unread pip badge on closed live groups (v1.29.0)
- (RN) Two-line PR rows ("author • state") with a status-ring favicon; merged rows get a check badge and animate out (v1.17.0, v1.23.0)
- (RN) Header "2 ✓" badge whose hover opens a Recently Closed popover to restore PRs (v1.23.0). Reauth cue; refresh/configure menu (v1.17.0). "New Live Group › Pull Requests" from the empty-sidebar menu (v1.23.0)
- (RN) Live Docs group pattern: activity subtitle, auto-fade when handled (v1.27.0)

### Split view
- ⇧⌥-click link into right split (v0.44.0); ⌥-click + opens NTP in split (v0.47.0)
- Nav-bar split button, "Open as Split" (v1.4.0); larger drop targets (v1.5.0)
- Per-split nav + bookmark bars, independent tint, per-pane close (v1.20.0)
- ⌥-click bookmark → split (v1.1.0)
- (RN) Drag a tab to the screen edge to split; dashed "Add left split" drop card (v1.25.0, v1.28.0). Per-pane command dropdown and pane swap (v1.20.0)

### Picture-in-Picture & media
- Meet PiP on tab switch (v1.3.1); reliability (v1.8.0, v1.15.0, v1.29.0)
- Document PiP shows opener hostname (v1.20.0)
- Stash PiP off screen edge (v1.36.0)
- PiP "Keep on Top" toggle; domain click returns to tab (v1.46.0)
- Casting to external devices (v1.45.1)
- (RN) Stashed PiP collapses to a thin colored sliver on the screen edge (v1.36.0). Reminder PiP snaps to corners and avoids edges (v1.7.0)
- (RN) Spotify card layout: album art, title/artist, prev/pause/next, elapsed/progress/remaining (v1.20.0)

### Command bar / address bar
- Default search engine shown in dropdown (v0.47.0); actual engine label (v1.41.0)
- Bookmarks ranked with history in results (v1.7.0)
- "new …" doc/ticket creation shortcuts (v1.8.0, v1.9.0)
- Paste and Go / Paste and Search (v1.20.0)
- ⇧⌘↩ direct search (v1.22.0)
- NTP query restoration on back (v1.28.0)
- IDN/punycode decoding (v1.28.0); CJK input fix (v0.43.0)
- Cancel page load via X (v0.48.0)
- (RN) "new <service>" row swaps the input's leading icon to the service logo (v1.8.0). Caches warmed at startup for a faster command bar (v1.24.0)

### Keyboard shortcuts
- Remappable shortcuts (v1.3.1); F12 DevTools, F-keys bindable (v1.15.0)
- Shortcuts shown in tab context menu (v1.21.0)
- ⌥⇧⌘C copy URL as markdown (v1.19.0)
- Non-US layout fixes (v1.10.1)
- Ctrl+1–9 profile switch (v1.22.0)
- (RN) ⌘⇧S topbar↔sidebar; ⌘S hide tab strip; ⌘⇧K close all; ⌃Tab thumbnail MRU switcher (v1.21.0, refreshed grid v1.28.0); ⌘⇧A tab search incl. recently closed (v1.33.0)
- (RN) File menu: ⌥⌘T new tab in group, ⌘L command bar, ⇧⌘T reopen tab, Reopen Closed Window, ⇧⌘N incognito, per-profile New Window (v1.18.1). Profile menu ⇧⌘P (v1.15.0)

### Profiles
- Unused profiles auto-unload (v0.44.0)
- Default profile management, delete profiles (v1.14.0, v1.16.0)
- Dock per-profile New Window (v1.20.0)
- Swipeable profiles + optional data sharing (v1.43.1)
- Move to Profile respects tab-position pref (v1.50.0)
- (RN) 8-swatch profile colors that tint the whole window; "Create a Profile" sheet (v1.15.0). Page-dots indicator at the sidebar bottom (v1.49.0). Swipe between profiles via the tab bar (v1.43.1)

### Bookmarks, import & sync
- Multi-tab → bookmarks bar; folder open-all; rename on create; ⌘/⌥-click modifiers (v1.1.0)
- Middle-click background open (v0.45.0); folder tree in save interstitial (v1.13.1); menus auto-size (v1.15.0)
- Bulk undo, clipboard URLs (v1.26.0); no reorder during sync (v1.39.0)
- Import: Chrome pinned tabs (v1.8.0), Chrome tab groups (v1.18.1), Chrome account-file bookmarks (v1.36.0), Arc custom tab names (v1.28.0)
- Sync: profiles/bookmarks/favorites (v1.26.0), settings (v1.28.0), unpinned tabs + extensions (v1.29.0)
- Tab Handoff from iPhone (v1.15.0)
- (RN) Sync pairing: a recovery-kit file plus a 6-character code via "Connect Another Device". Encrypted, local-first, client-side conflict resolution (v1.26.0)

### Meetings / calendar (non-AI)
- Live Calendar Preview + just-in-time reminder (v1.5.0); reminder redesign (v1.6.0), in PiP (v1.7.0)
- Meeting tab groups with countdown (v1.9.0, v1.14.0, v1.17.0)
- Presented-tab indicator (v1.7.0); "Share this tab instead" (v1.24.0)
- Suppress update prompts during calls/recording (v1.19.0)
- Calendar selection (v1.46.0)

### Settings & UI polish
- Tabs pane (v1.16.0); settings sidebar nav, Privacy pane redesign (v1.39.0); sync settings under Account (v1.27.0)
- Focus Mode ⌘S / collapse sidebar (v1.3.1, v1.5.0); sidebar toggle button (v1.20.0)
- Persist sidebar/top-tabs layout (v1.25.0)
- Color matching toolbar to page/sticky headers (v1.25.0, v1.28.0)
- NTP profile-color theming (v1.15.0); Liquid Glass (v1.15.0)
- Sidebar rubber-banding (v1.29.0); swipe nav redesign (v1.29.0)
- Fewer white flashes (v1.7.0, v1.10.1)
- (RN) Settings tabs: Account, Tabs, Privacy, Profiles, Memory, Dia Pro, Shortcuts, Advanced (v1.15.0). Download popover ("RECENT DOWNLOADS", Clear, reveal, "View all downloads") with a toast under the link (v1.25.0)
- (RN) Keycap-overlay shortcut demos; back/forward/reload press animations (v1.21.0, v1.23.0). Dark incognito with a red NTP glow (v1.18.1)

### Privacy & safety
- Download notifications hide source domain (v0.44.0); Bluetooth dialogs show full URL (v0.44.0)
- Link-safety stopgaps (v0.48.0)
- iCloud Passkeys (v1.4.0)
- Dark incognito by default (v1.18.1)
- Ad blocker: updated lists (v1.13.1), auto-reload on disable (v1.15.0), unsaved-changes prompt (v1.22.0)
- Confirm-dialog loop protection (v1.15.0); selectable dialog text (v1.15.0)
- (RN) Local-only history plus an opt-out telemetry toggle pattern (v1.45.0 page). Content-blocker toggle auto-reloads and confirms if there are unsaved changes (v1.15.0)

### Performance & reliability
- Protect last 10 used tabs from discard (v1.8.0); smart relaunch reload, discard uses app active time (v1.5.0)
- Favicon pre-warm (v1.13.1), cache cap 1,000 (v1.18.1)
- Sleep-lock fix (v1.21.0)
- Faster tab switching/closing (v1.28.0, v1.33.0, v1.35.0, v1.48.0)
- BFCache re-enabled; idle-tab sleeping (v1.40.0)
- Renderer leak fixes (v1.48.0); cleanup-tabs leak fix (v1.50.0)
- Low-disk warning (v0.46.0); sad-tab page (v0.45.0)
- Help → Record Performance Issue (v1.22.0)
- (RN) Views kept alive after tab switch = leak class; cheaper NTP animations; shed optional work under load (v1.24.0)

### Platform integrations
- AppleScript + Raycast (v1.7.0)
- Chromium Side Panel extensions (v1.10.1)
- Fullscreen API on another display (v1.10.1); history-entry ⌘/middle-click (v1.10.1)
- Popups: print, find, copy URL (v1.14.0)
- Cancel paused downloads (v1.8.0); Recent Downloads drag fix (v1.19.0)
- (RN) AppleScript surface used by a Raycast extension (search/focus tabs, history, profile switch) (v1.7.0). Handoff: Dia icon appears in the Dock for iPhone tabs (v1.15.0)
