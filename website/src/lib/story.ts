import { doc } from "@/lib/site";

export type Beat = {
  id: string;
  title: string;
  body: string;
  keys?: string[];
  href?: string;
};

// Each beat drives one scene of the pinned den window (see app/story.css).
export const BEATS: Beat[] = [
  {
    id: "tabs",
    title: "Tabs live on the side.",
    body: "Pinned tabs remember their page. Today tabs tidy themselves away after a day.",
    href: doc("docs/guide/sidebar-and-tabs.md"),
  },
  {
    id: "spaces",
    title: "Swipe to another space.",
    body: "Two fingers, and you're in Work. Every space has its own theme and, if you want, its own profile.",
    keys: ["⌃", "2"],
    href: doc("docs/guide/spaces-and-themes.md"),
  },
  {
    id: "command",
    title: "One box for everything.",
    body: "Find a tab in any space, a page you closed, a site, a search, a command or a setting.",
    keys: ["⌘", "T"],
    href: doc("docs/guide/command-bar.md"),
  },
  {
    id: "peek",
    title: "Peek without leaving.",
    body: "⇧-click a link and it floats in a card. Expand it into a tab, split it, or press Esc.",
    keys: ["⇧", "click"],
    href: doc("docs/guide/peek-split-little-arc.md"),
  },
  {
    id: "split",
    title: "Drag a tab to split.",
    body: "Drop a tab on the page for side by side. Up to four panes.",
    keys: ["⌃", "⇧", "="],
    href: doc("docs/guide/peek-split-little-arc.md#split-view"),
  },
  {
    id: "previews",
    title: "Hover to look inside.",
    body: "Rest on a pull request: checks, reviews and conflicts. Nothing is fetched until you hover.",
    href: doc("docs/guide/hover-previews.md"),
  },
  {
    id: "media",
    title: "The video comes with you.",
    body: "Switch tabs while a video plays and it floats off into the Mac's own picture in picture, on top of everything. Come back and it slides home, still playing.",
    href: doc("docs/guide/media.md"),
  },
  {
    id: "briefing",
    title: "Your morning, briefed.",
    body: "Slack and GitHub, turned into a summary and a todo list by Apple's on-device model. Written on your Mac.",
    keys: ["⇧", "⌘", "B"],
    href: doc("docs/guide/connections-and-briefing.md"),
  },
];

export type Row = { label: string; icon: number; indent?: boolean; folder?: boolean };

// Favicon sprite indices (public/story/favicons.png, 20px cells).
export const ICON = {
  appleDev: 0,
  linear: 1,
  apple: 2,
  hn: 3,
  webkitBlog: 4,
  webkitDev: 5,
  github: 6,
  globe: 7,
  figma: 8,
  swift: 9,
  githubTile: 10,
  gmail: 11,
  calendar: 12,
  youtube: 13,
} as const;

export const PERSONAL = {
  name: "Personal",
  pinned: [
    { label: "Apple Developer Docum…", icon: ICON.appleDev },
    { label: "Linear", icon: ICON.linear },
    { label: "Reading", icon: -1, folder: true },
    { label: "The Swift Programmin…", icon: ICON.globe, indent: true },
  ] as Row[],
  today: [
    { label: "OS - macOS 27 Golden…", icon: ICON.apple },
    { label: "Hacker News", icon: ICON.hn },
    { label: "WebKit Blog", icon: ICON.webkitBlog },
    { label: "WebKit | Apple Develope…", icon: ICON.webkitDev },
  ] as Row[],
};

export const WORK = {
  name: "Work",
  pinned: [
    { label: "Figma", icon: ICON.figma },
    { label: "Swift.org", icon: ICON.swift },
    { label: "Linear", icon: ICON.linear },
  ] as Row[],
  today: [
    { label: "Parser: accept trailin…", icon: ICON.github },
    { label: "OS - macOS 27 Golden…", icon: ICON.apple },
    { label: "Hacker News", icon: ICON.hn },
    { label: "YouTube", icon: 13 },
  ] as Row[],
};
