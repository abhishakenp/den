import { RAW, TREE } from "@/lib/site";

export const SKILL_URL = `${TREE}/skills/den`;
const SKILL_RAW = `${RAW}/skills/den/SKILL.md`;

export type InstallMethod = { id: string; label: string; hint: string; command: string };

export const INSTALL: InstallMethod[] = [
  {
    id: "skills",
    label: "Any agent",
    hint: "The skills CLI finds skills/den in the repo and asks which agents to install it for.",
    command: "bunx skills add abhishakenp/den --skill den -g",
  },
  {
    id: "claude",
    label: "Claude Code",
    hint: "A personal skill, available in every project.",
    command: `mkdir -p ~/.claude/skills/den && curl -fsSL ${SKILL_RAW} -o ~/.claude/skills/den/SKILL.md`,
  },
  {
    id: "codex",
    label: "Codex",
    hint: "Codex reads user skills from ~/.agents/skills.",
    command: `mkdir -p ~/.agents/skills/den && curl -fsSL ${SKILL_RAW} -o ~/.agents/skills/den/SKILL.md`,
  },
];

export type Example = { ask: string; touches: string };

export const EXAMPLES: Example[] = [
  { ask: "Add an mdn search keyword.", touches: "~/.den/config.toml  [search.keywords]" },
  { ask: "Put next tab on ⌘⇧J.", touches: "~/.den/config.toml  [shortcuts]" },
  { ask: "Make me a warm amber theme.", touches: "~/.den/themes/ember.toml" },
  { ask: "Write a plugin that copies my Today tabs as Markdown.", touches: "~/.den/plugins/copytabs/*.swift  → hot-reloads" },
  { ask: "Why didn't my plugin load?", touches: "~/.den/logs/plugins.log, build-<id>.log" },
];

export const TEACHES = [
  { title: "Configure", body: "config.toml keys, shortcuts, site-search keywords, update channels and theme presets, all applied live." },
  { title: "Extend", body: "Embedded Swift plugins on CordisKit, built with cordis-build or dropped in as source den compiles for you." },
  { title: "Debug", body: "Where den logs, how plugin layers override each other, and how to rule out your customizations." },
];
