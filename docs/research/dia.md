# Dia (The Browser Company / Atlassian) — Feature & Architecture Inventory

> Research snapshot, 2026-09-27. Decisions made later are in [ROADMAP.md](../../ROADMAP.md) / [FEATURES.md](../FEATURES.md).

Research for **den** (open-source macOS WebKit browser). Compiled 2026-09-27 from public sources via web search and fetch.

**Method caveat:** pages were read through an automated fetch-and-summarize tool, so quotes are close to the source but not guaranteed character-for-character. Items marked **UNVERIFIED** come from a single third-party source, conflict with another source, or could not be confirmed on a first-party page. No numbers here were measured by us.

---

## 0. TL;DR for den

| Area | What Dia does | Relevance to den |
|---|---|---|
| Engine | Chromium, with a Swift UI shell built on the in-house "ADK" | den uses WebKit, so it avoids the Chromium overhead Dia carries |
| AI chat | Command bar and chat that pull in tabs, history, and connected apps through @-mentions; multi-provider LLMs run in the cloud | Core feature to replicate |
| Connections | Server-side OAuth tokens for Slack, Gmail/GCal/GDrive, Notion, GitHub, Outlook/Teams/SharePoint, Jira/Confluence/Rovo, Linear, Figma, Zoom, Amplitude… | Core feature to replicate. Dia keeps the tokens on its servers |
| Morning Brief | Daily brief built from connected apps: calendar, inbox ("which emails need a reply"), key links. Needs Slack at minimum. Now only on the **$100/mo** tier | Core feature to replicate |
| Memory | Summaries were made server-side and stored locally. **Retired in v1.50.0 (2026-09-24)** in favour of "on-demand tools" | Suggests a simpler design: fetch context on demand instead of keeping a memory store |
| Security | "Assume compromise, design for containment." URL-provenance policy on web fetch, no auto-following of LLM URLs, no irreversible actions | Directly reusable design principles |

---

## 1. AI chat sidebar / command bar

**What it does**
- At launch (beta, 2025-06-11) the URL bar doubled as a chat box. It routed between search and chat automatically, could summarize files, and could answer questions about **all open tabs** and draft content from them. The "History" feature was opt-in and let Dia use **seven days** of browsing history as context. Users could set tone, writing style, and coding preferences by talking to it. — https://techcrunch.com/2025/06/11/the-browser-company-launches-its-ai-first-browser-dia-in-beta
- Context comes in through **@-mentions**: tabs, bookmarks, history, artifacts, `@Tabs` (which can also open or close tabs from chat), `@Gmail`, `@Google Calendar`, `@Slack`, `@Memory Search`, and `@History` (covers chats and sites). "Auto-Memory Search" works without a mention. — https://www.diabrowser.com/changelog/mac
- A user workflow shows `@all open tabs` being used to summarize every open tab before running a custom Skill. — https://blog.planetargon.com/blog/entries/solving-workflow-chaos-with-dia-browser (2025-08-07)
- Content it can read (changelog): PDFs, iframes and Shadow DOM in complex web apps, whole Google Sheets documents, Notion and Drive docs, YouTube summaries, and Slack attachments. It also has reasoning mode with a "Skip >" button, visible tool-call bylines (read, open, close), editing of AI messages, stop and resume of streams, and a faster HTML→markdown conversion (a quadratic-time bug was fixed). — https://www.diabrowser.com/changelog/mac
- v1.50.0 (2026-09-24) added pause/resume of AI replies, search over past chats by date, title, or keyword, and history search by date, title, or URL. A **smaller on-device model** now decides whether command-bar input goes to chat or to Google search. — https://piunikaweb.com/2026/09/25/dia-1-50-update-hand-painted-icons-pause-resume-ai/ , https://www.diabrowser.com/changelog/mac
- When the machine is under load, Dia skips the search-vs-chat routing step to save resources. — https://www.diabrowser.com/release-notes/1-24-0-dia-got-faster
- Other outputs: **Reports**, which are designed documents you can comment on inline and share. You ask for them from a new tab or chat, e.g. "make sense of a long Slack thread". Examples include to-do lists and decision summaries. A **Files** menu holds all Reports and chats. Reports are dated 2026-07-09. **Decks** are generated from context. — https://www.diabrowser.com/release-notes/1-39-1-reports , https://www.diabrowser.com/start , https://www.diabrowser.com/
- "Proactive suggestions" are AI suggestions shared across windows that you accept or decline and that expire. — https://www.diabrowser.com/changelog/mac

**Memory / personalization (now retired)**
- How it worked: "Memory allows you to ask Dia about your previous activity. This is powered by summaries, created on our servers and stored locally on your device." — https://www.diabrowser.com/security
- Controls: sensitive sites such as banks were excluded, all incognito tabs were excluded, you could opt a site out (which deleted its past data), toggle Memory per profile, and delete individual items. AI responses were not stored in Memory. — https://www.diabrowser.com/changelog/mac
- **Retired in v1.50.0 (2026-09-24):** "We're phasing out Dia's memory feature and deleting existing memory data, since newer models no longer need it". Dia now pulls "context from richer on-demand tools instead." — https://www.diabrowser.com/changelog/mac , https://piunikaweb.com/2026/09/25/dia-1-50-update-hand-painted-icons-pause-resume-ai/
- Personalization settings also include written instructions and a per-chat toggle. — https://www.diabrowser.com/changelog/mac

## 2. Skills and the Skills Gallery

- Skills are saved prompts, i.e. shortcuts for prompts you use often. You run one with a slash command (e.g. `/research`) or by typing its name and pressing Return, from Chat or the Command Bar. — https://techcrunch.com/2025/07/21/dia-launches-a-skill-gallery-perplexity-to-add-tasks-to-comet/ , https://www.diabrowser.com/changelog/mac
- At launch, Skills could also produce code snippets, e.g. a reading-optimized page layout. — https://techcrunch.com/2025/06/11/the-browser-company-launches-its-ai-first-browser-dia-in-beta
- **Skills Gallery v0.1** launched in July 2025. Skills are grouped by category, and you add one by copying its prompt into your library. — https://techcrunch.com/2025/07/21/dia-launches-a-skill-gallery-perplexity-to-add-tasks-to-comet/ . Individual skill pages exist, e.g. https://www.diabrowser.com/skills/weekly (it redirected to the homepage when fetched, so its content was not verified).
- **Natural-language Skill Builder:** you describe the skill in one sentence ("help me prioritize my day", "copyedit my Slack post", "set up a weekly check-in"). Dia then picks the name and icon, attaches tools only when needed (Gmail for drafts, GCal for scheduling), and asks a couple of follow-up questions. Skills are now "prompts + tools + follow-ups". You can edit them, install them from packs, and test them before installing. — https://www.diabrowser.com/changelog/mac . The v1.2.0 / 2025-10-23 date comes only from a search snippet and is **UNVERIFIED**.
- Skills that use connected apps: `/Reply`, `/PR Description`, `/Recap` — https://computingforgeeks.com/install-dia-browser-macos/ (third-party, **UNVERIFIED**)
- Model: "Dia now uses GPT‑5 for all queries", including `/research` and Skills (v0.46.0, 2025-09-11) — https://www.diabrowser.com/changelog/mac . Whether that is still the default model is **UNVERIFIED**, since the security page lists several providers.

## 3. Connections / integrations ("Apps", "Tools")

**Services (first-party changelog and pricing page):**
- Google: Gmail (search, draft, summarize), Google Calendar (scheduling, creating invites), Google Drive, Docs, and Sheets
- Slack (search, attachments, voice transcripts, choice of workspace)
- Notion (mentions, comments, choice of workspace)
- GitHub (PR tracking, CI status, merge conflicts, stacked-PR positions)
- Microsoft: Outlook, Teams, SharePoint (added v1.48.0, 2026-09-10)
- Atlassian: Confluence (v1.31.0, 2026-05-14), Jira ("create shortcuts")
- Zoom (search meetings, recordings, transcripts; v1.45.1, 2026-08-20)
- Figma (v1.50.0)
- "Request a Tool": users can request any of the "top 400 SaaS apps" (v1.47.1, 2026-09-03)
- Sources: https://www.diabrowser.com/changelog/mac , https://www.diabrowser.com/pricing (paid tiers list Slack, Gmail, Notion, Outlook, GitHub, Google Calendar, Figma)
- Third-party catalog list, **UNVERIFIED** on a first-party page: Amplitude, Atlassian Rovo, Linear — https://computingforgeeks.com/install-dia-browser-macos/ . Wikipedia (via search snippet) says Amplitude was added in March 2026.

**Auth model**
- A third-party guide (updated 2026-05-28) says each integration uses **OAuth** with scopes shown before you grant access (GitHub "read access to your repos", Gmail "read and compose"). It also says "The token is stored encrypted in your Dia account and Dia's servers use it only when you trigger a Skill that needs it", and that you can revoke from the Apps page. — https://computingforgeeks.com/install-dia-browser-macos/ . This is **UNVERIFIED** first-party, but it matches the security page, which says the Morning Brief runs through Dia's servers (https://www.diabrowser.com/security).
- The first-party changelog shows settings under **Settings → Apps**. You can pick the Slack or Notion workspace, and pin Gmail/GCal/GDrive to a Google account from the ellipsis menu ("Google Account Switching for Tools", v1.46.0). — https://www.diabrowser.com/changelog/mac
- Summary: connections are **server-side OAuth**, not scraping of your logged-in browser session. A separate path does exist: chat can read whatever is open in your tabs, including logged-in web apps, through @-tabs. A user reported the tab path fails when the page has not loaded lazily (Atlassian), unless you click into the tab first. — https://blog.planetargon.com/blog/entries/solving-workflow-chaos-with-dia-browser

**"Live" tab groups / Live Folders**
- GitHub Live Group/Folder: PRs update in real time, CI status shows on hover, merge conflicts are visible, and stacks can be collapsed.
- Live Documents group: shows active Notion and Drive docs, with comments and mentions.
- Live Folders exist for Gmail, Calendar, Drive, Notion, Slack, and Zoom, with activity indicators. Confluence was added to Live Groups in v1.31.0.
- Meeting groups are created automatically when you join a call and show time remaining.
- Source: https://www.diabrowser.com/changelog/mac . The homepage describes this as "Dia pulls together the places where work is actually happening (like GitHub and Notion)" and "Every call starts with the right meeting page, agenda, notes, and related docs open" — https://www.diabrowser.com/

## 4. Morning Brief (daily briefing / to-dos)

- **Introduced:** release note "Morning Brief", dated 2026-06-25, labelled experimental ("Things may not be perfect, they may break…"). — https://www.diabrowser.com/release-notes/1-37-0-morning-brief
- **Purpose (verbatim-ish):** it "remembers what slipped through the cracks, what deserves your focus, and quiets the storm long enough for you to start the day on your terms."
- **Setup:** Settings → Apps, enable "New Chat", then connect tools. It needs "**Slack at a minimum**, but connect more for a richer brief". "You'll receive your first one tomorrow", so the trigger is a daily schedule. — same release note
- **Trigger timing:** the exact time of day and where the brief appears (new tab, chat, or notification) are **UNVERIFIED**. No source states either.
- **Content:**
  - Homepage: "Dia's Morning Brief lays it all out (calendar, inbox, key links)" — https://www.diabrowser.com/
  - v1.48.0: "Start the day knowing which emails need a reply and ask any time what's moving across your threads". Also "a heads-up in your morning brief when a doc updates in SharePoint". — https://www.diabrowser.com/changelog/mac , https://www.diabrowser.com/release-notes/Tools
  - Sources are all connected Apps (Slack, Gmail, GCal, Notion, Drive, Outlook, Teams, SharePoint…)
- **To-do list:** a search snippet attributed to https://www.diabrowser.com/start says "Dia pulls action items from across your tools and turns them into an interactive to-do list". When fetched, that page centred on **Reports**, with to-do lists given as one example of a Report. Whether the Morning Brief itself shows a checkable to-do list is **UNVERIFIED**. The sure part is that to-dos can be generated as a Report or Skill output.
- **Processing:** runs on Dia's servers, per the security page: the Morning Brief sends data through its servers to prepare the brief. — https://www.diabrowser.com/security
- **Paywall:** the current pricing page puts "Get the daily Morning Brief" only in **Better Days, $100/mo**. — https://www.diabrowser.com/pricing
- A DIY version from before the feature existed: a `/start-day` Skill plus a bash script that opens calendar, Atlassian notifications, Asana, a standup Slack channel, and email tabs, then runs `@all open tabs`. — https://blog.planetargon.com/blog/entries/solving-workflow-chaos-with-dia-browser

## 5. Privacy model and models

- Stored locally by default: "your conversations, history, bookmarks, and files are encrypted and stored locally on your device." Sync is "end-to-end encrypted, and our servers cannot read the data." — https://www.diabrowser.com/security
- Sent to the cloud: "your question and relevant context" goes to AI providers. Morning Brief data passes through Dia's servers. Memory summaries were generated server-side. — https://www.diabrowser.com/security
- **Providers:** "GPT (OpenAI Azure), Claude (Anthropic, Vertex, AWS), Gemini (Vertex)". Providers are "contractually restricted from retaining and using your data to train their own models." — https://www.diabrowser.com/security
- By default, "some content data" is used to improve Dia. It is not tied to your account, is kept 30 days, and can be turned off in Settings. — https://www.diabrowser.com/security
- Local processing is limited to the small on-device model that routes command-bar input between chat and search. No source claims local LLM inference for chat. — https://www.diabrowser.com/changelog/mac
- Chromium features disabled: GAIA (Google account integration), UMA metrics, the Reporting API. Sign-in uses **Atlassian identity**, with SAML SSO for Google, Okta, and Entra ID. — https://www.diabrowser.com/security
- LayerX points out that the earlier seven-day history/Memory store created an aggregation risk. — https://layerxsecurity.com/generative-ai/dia-browser-risks-and-vulnerabilities/

## 6. Arc features: kept vs dropped

| Feature | Status | Source |
|---|---|---|
| Sidebar / vertical tabs | Kept. Added as "Sidebar mode for Arc fans" in Nov 2025; vertical layout is an option next to top tabs | https://techcrunch.com/2025/11/03/dias-ai-browser-starts-adding-arcs-greatest-hits-to-its-feature-set , changelog |
| Pinned tabs (reset to base URL) | Kept | changelog |
| Split view | Kept ("Open as Split", ⌥-click; each pane has its own nav bar) | changelog, https://www.diabrowser.com/pricing (free tier) |
| Auto PiP for Meet/YouTube | Kept | TechCrunch Nov 2025, changelog |
| Focus mode, custom shortcuts | Kept | TechCrunch Nov 2025, changelog |
| Spaces | Replaced by **Profiles**, which can be swiped between, switched with Ctrl+1–9, and have their own colors. In Nov 2025 TBC was "exploring how to transition Arc's Spaces"; a review in Jul 2026 says Spaces were dropped in favour of "profiles in separate windows" | TechCrunch Nov 2025, changelog, https://supasidebar.com/blog/dia-browser-mac-review-2026 |
| Tab groups (auto-named, emoji) | New to Dia, Chrome-style | changelog |
| Boosts, Easels, Arc's Cmd+T command bar, Arc sidebar import | Dropped | https://supasidebar.com/blog/dia-browser-mac-review-2026 (third-party) |
| Little Arc, Peek, auto-archive | **UNVERIFIED** (no source found). The "Tidy tabs" cleanup for 10+ inactive tabs is related | changelog |
| Built-in ad blocker | Yes (free tier) | https://www.diabrowser.com/pricing |

## 7. Engine, resource usage, platforms, pricing

**Architecture**
- Dia is built on Chromium. It was on Chromium M141 → M144 → M147 → M149 → M151 over time (changelog). One review says "Chromium 144 as of v1.14.0 (January 2026)". — https://www.diabrowser.com/changelog/mac , https://supasidebar.com/blog/dia-browser-mac-review-2026
- **ADK (Arc Development Kit)** is "an internal SDK for building browsers". It lets ex-iOS engineers "prototype native browser UI quickly, without touching C++". Dia is **"sunsetting our use of TCA and SwiftUI to make Dia lightweight, snappy, and responsive"**. "Arc was bloated." Arc will not be open-sourced because that would mean open-sourcing ADK. — https://browsercompany.substack.com/p/letter-to-arc-members-2025
- The security engineering team grew "from one to five", with red teaming, bug bounties, and audits. — same letter
- The macOS bundle is arm64-only; the ArcCore framework is described as reducing size by about 265 MB. On-device router model. "Agent context handling separated from execution." "Out-of-process web page reading". — https://www.diabrowser.com/changelog/mac

**Resource usage**
- First-party (v1.24.0, 2026-03-26): Dia fixed memory leaks and "a platform bug that kept some views around after switching tabs", which "in some cases added up to gigabytes of extra memory". It also reduced CPU/GPU use from new-tab animations. — https://www.diabrowser.com/release-notes/1-24-0-dia-got-faster
- Later changelog items: leak fixes (tab cleanup, renderer, idle windows), sleeping idle tabs, favicon cache capped at 1,000 entries, and the bfcache turned back on. — https://www.diabrowser.com/changelog/mac
- A third-party review reports "slightly higher RAM per tab than Safari" and battery life "between Chrome and Brave". It says 8 GB M1 Macs slow down at 30+ tabs when Memory is on. **No measurement method is given, so treat these as UNVERIFIED and anecdotal.** — https://supasidebar.com/blog/dia-browser-mac-review-2026
- No Reddit or benchmark data with real numbers was found. The user's "too heavy" complaint is consistent with Dia being Chromium-based plus running a leak-fix cadence, but we have **no measured numbers**.

**Platforms**
- macOS on Apple Silicon: beta 2025-06-11, public (waitlist removed) around Oct 2025 per a search snippet.
- Windows: beta, officially "fall 2026", with "Windows Wednesdays" updates. — https://piunikaweb.com/2026/07/30/dia-windows-slated-officially-launch-fall-2026/ , https://www.diabrowser.com/release-notes/windows-wednesdays

**Pricing (current page, fetched 2026-09-27)** — https://www.diabrowser.com/pricing
| Tier | Price | Includes |
|---|---|---|
| Better Browser | Free | Profiles, tab groups, split view, PiP, ad/tracker blocker, sync. **No AI** |
| Better Answers | $20/mo | Chat on any page, chat with context from your tools, "models that won't store your data". Usage metered in "Tasks" |
| Better Days | $100/mo | 6× more tasks, **daily Morning Brief**, reports, decks, recaps, meeting prep and follow-up |
- Overage is sold in $20 credit blocks that roll over up to 3 months. 14-day trial.
- History: "Dia Pro" at $20/mo launched Aug 2025. Back then the free tier included limited AI. — https://9to5mac.com/2025/08/07/the-dia-browser-now-offers-a-20-month-subscription-plan/ . A guide that mentions "Dia Plus" (https://computingforgeeks.com/install-dia-browser-macos/) conflicts with this and is ignored.

**Corporate**
- Atlassian bought The Browser Company for about $610M in cash. Announced Sep 2025, closed Oct 2025. — https://www.computerworld.com/article/4053130/atlassian-exec-details-the-610m-browser-company-acquisition.html , https://www.avaratak.com/blog/out-of-the-tab-forest-atlassian-dia-browser
- Enterprise ("Dia for Work"): SSO and admin controls. A closed beta at Team '26 included a planned **Atlassian Guard** integration and Teamwork Graph context. — https://www.avaratak.com/blog/out-of-the-tab-forest-atlassian-dia-browser (third-party, **partially UNVERIFIED**)

## 8. Security: prompt injection and mitigations

- **Stated principles** (https://www.diabrowser.com/security):
  - "Dia won't automatically open or follow LLM‑generated URLs"
  - "Dia won't insert data into third-party sites without your approval"
  - "Dia won't take irreversible actions on behalf of the user"
  - "Dia won't expose sensitive elements to the agent"
- **fetch_web_content case study** (https://www.diabrowser.com/security/bulletins, Feb 2026):
  - The tool could be abused through prompt injection to exfiltrate data by encoding it in URLs.
  - TBC tried detection first, then concluded: "Detection-based security is not sufficient when the attacker controls the input to your detector."
  - They **removed the tool before the June 2025 beta**. They rebuilt it about two months later around a **URL provenance policy**: only URLs that appear in the user's context (tabs, messages) can be fetched, and URLs the model makes up are rejected, which makes exfiltration "structurally infeasible".
  - Stated philosophy: "assume compromise, design for containment."
- Other hardening: out-of-process page reading (v1.34.1, 2026-06-08), "malicious injection detection improvements", safety alerts tuned to cut false positives, and a HackerOne bug bounty. CVEs: CVE-2025-13132 (fullscreen spoofing, <1.6) and CVE-2025-15032 (about:blank spoofing, <1.9.0). — https://www.diabrowser.com/changelog/mac , https://www.diabrowser.com/security/bulletins
- Third-party criticism (LayerX, 2025-11-19):
  - Hidden-text indirect injection
  - "Dia effectively bypasses SSO protection by allowing AI systems to observe authenticated sessions"
  - Memory poisoning
  - Phishing blocking at 46%, the same as Chrome (LayerX's own test, method not reviewed)
  - Source: https://layerxsecurity.com/generative-ai/dia-browser-risks-and-vulnerabilities/
- Brave's research on agentic browsers (Comet, Fellou, Opera Neon) describes the whole class of attacks. We found **no Brave write-up about Dia specifically**. — https://brave.com/blog/unseeable-prompt-injections/ , https://brave.com/blog/indirect-prompt-injection/

## 9. Takeaways for den (our inference, not facts about Dia)

1. **Connections:** Dia's OAuth tokens live on its servers. den can keep tokens in the macOS Keychain and call APIs locally or through MCP servers, which gives local-first privacy.
2. **Morning Brief:** a scheduled job that pulls Slack, mail, and calendar; ranks "needs reply" and "what's moving"; and writes a to-do list the user can act on. Dia charges $100/mo for it, which is a strong reason for an open-source version.
3. **Retiring Memory:** Dia dropped its stored memory in favour of on-demand retrieval from history and tools. den can skip building a memory store at first.
4. **Security:** copy the provenance rule (only fetch URLs that came from user context), never auto-follow URLs the model generates, require approval before writing to third-party sites, and read pages out-of-process.
5. **Resource usage:** Dia's leak fixes (views kept after tab switches, idle windows) point to real risks in multi-view browser shells. Using WebKit (WKWebView) plus sleeping idle tabs addresses the same problem.

## Open / UNVERIFIED items
- Morning Brief delivery time, where it appears, and whether its to-dos can be checked off
- Whether the full app catalog includes Linear, Amplitude, and Rovo (first-party confirmation missing)
- The exact OAuth scopes and where tokens are stored (third-party source only)
- The default chat model today (GPT-5 was announced Sep 2025; the security page lists OpenAI, Anthropic, and Gemini)
- Measured RAM or CPU numbers (none found)
- Whether Arc's Peek, Little Arc, and Boosts still exist in any form
