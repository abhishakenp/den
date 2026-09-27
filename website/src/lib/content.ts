import { doc } from "@/lib/site";

export type Principle = { title: string; body: string; glyph: "plug" | "swap" | "lazy" | "feather" };

export const PRINCIPLES: Principle[] = [
  {
    title: "Plugins, all the way down",
    body: "The core is a small host. Tabs, the sidebar, split view, the command bar and connections are Embedded Swift plugins, each a few hundred KB.",
    glyph: "plug",
  },
  {
    title: "Hot-swappable",
    body: "Load, unload, update or replace any plugin while den runs. Your tabs stay put. Plugin updates swap in live; only the host needs a relaunch.",
    glyph: "swap",
  },
  {
    title: "Lazy by default",
    body: "Nothing loads until you need it: plugins, connections, web pages. Settings, previews and the briefing build nothing until you open them.",
    glyph: "lazy",
  },
  {
    title: "Minimal footprint",
    body: "Idle tabs are discarded and cost kilobytes, not a process. Memory and energy regressions are treated as bugs, with budgets checked by a script.",
    glyph: "feather",
  },
];

export type Bar = { app: string; value: number; label: string; note?: string; den?: boolean };
export type Metric = { title: string; unit: string; caption: string; bars: Bar[] };

export const METRICS: Metric[] = [
  {
    title: "Memory, idle",
    unit: "MB",
    caption: "phys_footprint summed over the app and every helper it owns, 10 s after the first window.",
    bars: [
      { app: "den", value: 20.0, label: "20.0 MB", note: "no tabs, no WebKit process running", den: true },
      { app: "Arc 1.166", value: 189.0, label: "189 MB", note: "empty space" },
      { app: "Dia 1.50", value: 614.7, label: "615 MB", note: "fresh launch" },
    ],
  },
  {
    title: "Memory, one page",
    unit: "MB",
    caption: "example.com open.",
    bars: [
      { app: "den", value: 79.8, label: "79.8 MB", den: true },
      { app: "Arc 1.166", value: 366.8, label: "367 MB", note: "in a Little Arc window" },
    ],
  },
  {
    title: "Launch to first window",
    unit: "ms",
    caption: "Warm launch, median of the 6 least-loaded interleaved rounds.",
    bars: [
      { app: "den", value: 209, label: "209 ms", den: true },
      { app: "Dia 1.50", value: 653, label: "653 ms" },
      { app: "Arc 1.166", value: 2147, label: "2,147 ms" },
    ],
  },
];

export const FACTS = [
  { value: "0", label: "web processes per sleeping tab", note: "its WebKit process exits; the page returns on click" },
  { value: "0.2%", label: "idle CPU, no tabs", note: "median, 0.1 wakeups/s" },
  { value: "31×", label: "Dia idle, vs den idle", note: "Dia on a fresh launch" },
  { value: "9.5×", label: "Arc idle, vs den idle", note: "Arc with an empty space" },
];

export const CONDITIONS =
  "Measured 2026-09-27 on a MacBook Air (M3, 16 GB), macOS 26.5, on AC power. Other builds were running the whole time (1-minute load never below 4), so absolute launch times are inflated; all three browsers were launched in turn under the same load. Memory depends much less on load.";

export type Feature = {
  id: string;
  tab: string;
  title: string;
  body: string;
  points: string[];
  shot: string;
  alt: string;
  href: string;
};

export const FEATURES: Feature[] = [
  {
    id: "sidebar",
    tab: "Sidebar & spaces",
    title: "Tabs on the side. Spaces for everything else.",
    body: "Favorites, pinned tabs that remember their page, and Today tabs that archive themselves after a day. Every space gets its own theme and, if you want, its own profile.",
    points: ["Two-finger swipe between spaces", "Nested folders, drag and drop, ⌃Z undo", "A searchable Library of everything you closed"],
    shot: "/shots/space-menu-dark.png",
    alt: "den's sidebar with the space menu open",
    href: doc("docs/guide/sidebar-and-tabs.md"),
  },
  {
    id: "command",
    tab: "Command bar",
    title: "One box for everything.",
    body: "⌘T finds a tab in any space, a page you closed, a site, a search, a command, or a setting you can flip without opening Settings.",
    points: ["Site keywords: gh, yt, w, then Tab", "Every command, with its shortcut", "⇧Return opens the result in a Peek"],
    shot: "/shots/command-bar-dark.png",
    alt: "The den command bar with search results",
    href: doc("docs/guide/command-bar.md"),
  },
  {
    id: "peek",
    tab: "Peek & split",
    title: "Look at a second page without losing the first.",
    body: "⇧-click any link to Peek at it in a floating card. Drag a tab onto the page for a split, up to four panes. Links from other apps can open in a mini window.",
    points: ["Open as Tab keeps history and scroll", "Side by side, top and bottom, or grid", "⌘Z brings back a Peek you just closed"],
    shot: "/shots/peek-card-dark.png",
    alt: "A Peek card floating over the current page",
    href: doc("docs/guide/peek-split-little-arc.md"),
  },
  {
    id: "previews",
    tab: "Hover previews",
    title: "Rest on a tab, see what's in it.",
    body: "A pull request's checks and reviews, your next meeting with a Join button, unread mail, or a snapshot of the page. Nothing is fetched until you hover.",
    points: ["Public PRs need no sign-in", "Cards swap instantly once one is up", "Works on folders and splits too"],
    shot: "/shots/preview-pr-dark.png",
    alt: "A hover card showing a GitHub pull request's checks and reviews",
    href: doc("docs/guide/hover-previews.md"),
  },
  {
    id: "briefing",
    tab: "Connections & briefing",
    title: "A morning briefing, written on your Mac.",
    body: "Connect Slack and GitHub through the session you signed in to inside den. ⇧⌘B turns what's waiting into a summary and a todo list, written by Apple's on-device model.",
    points: ["No den accounts, no OAuth apps, no servers", "Refreshes every 15 minutes while connected", "Summaries are written on your Mac, never on a server"],
    shot: "/shots/briefing-dark.png",
    alt: "The daily briefing with a summary and todos",
    href: doc("docs/guide/connections-and-briefing.md"),
  },
  {
    id: "extensions",
    tab: "Extensions",
    title: "Chrome and Firefox extensions, on WebKit.",
    body: "Open an extension on the Chrome Web Store or Firefox Add-ons and click ＋ Add to den. Manifest v2 and v3, popups, badges and per-site access.",
    points: ["uBlock Origin Lite and Dark Reader verified", "den shows what WebKit can't give an extension, up front", "Unpacked folders in ~/.den/extensions for development"],
    shot: "/shots/extensions-page-dark.png",
    alt: "The Extensions page listing uBlock Origin Lite, ColorPick and Dark Reader",
    href: doc("docs/guide/extensions.md"),
  },
  {
    id: "privacy",
    tab: "Privacy",
    title: "No servers, no accounts, no analytics.",
    body: "Dark mode for every website with a user stylesheet: no script, no white flash. Passwords live in your Keychain and fill after Touch ID.",
    points: ["Per-site dark mode from the command bar", "Strong passwords on sign-up forms", "Clipboard cleared 60 s after copying a password"],
    shot: "/shots/launcher-dark-mode-dark.png",
    alt: "Flipping dark mode for websites from the command bar",
    href: doc("docs/guide/privacy-and-passwords.md"),
  },
  {
    id: "pagetools",
    tab: "Page tools",
    title: "The everyday things, done well.",
    body: "Reader that reads aloud and highlights each sentence. Translation on your Mac with Apple's models. Capture with ⇧⌘2. Zap the elements you never want to see again.",
    points: ["Remove Sticky Headers, remembered per site", "Copy Link to Highlight", "Zoom remembered per site"],
    shot: "/shots/pagetools-read-aloud-dark.png",
    alt: "Reader reading an article aloud in dark mode",
    href: doc("docs/guide/page-tools.md"),
  },
];

export type DocLink = { title: string; body: string; href: string };

export const DOCS: DocLink[] = [
  { title: "Getting started", body: "Install, first run, default browser", href: doc("docs/guide/getting-started.md") },
  { title: "Tips & hidden gems", body: "Every gesture, modifier-click and drag", href: doc("docs/guide/tips.md") },
  { title: "Keyboard shortcuts", body: "Arc's, all remappable", href: doc("docs/guide/shortcuts.md") },
  { title: "~/.den", body: "Your plugins, themes and config.toml", href: doc("docs/guide/den-home.md") },
  { title: "Host API", body: "What plugins code against", href: doc("docs/host-api.md") },
  { title: "Performance", body: "Every number, and how it was measured", href: doc("docs/perf/baseline.md") },
  { title: "Updates", body: "Channels and hot-swapped plugins", href: doc("docs/guide/updates.md") },
  { title: "Coming soon", body: "In progress or planned, no promises", href: doc("docs/guide/coming-soon.md") },
];
