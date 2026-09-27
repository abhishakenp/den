import Image from "next/image";
import { REPO_URL, TREE, doc } from "@/lib/site";

const COLUMNS = [
  {
    title: "Product",
    links: [
      { label: "Download", href: "#download" },
      { label: "Releases", href: `${REPO_URL}/releases` },
      { label: "Performance", href: doc("docs/perf/baseline.md") },
      { label: "Coming soon", href: doc("docs/guide/coming-soon.md") },
    ],
  },
  {
    title: "Docs",
    links: [
      { label: "User guide", href: `${TREE}/docs/guide` },
      { label: "~/.den", href: doc("docs/guide/den-home.md") },
      { label: "Host API", href: doc("docs/host-api.md") },
      { label: "Agent skill", href: `${TREE}/skills/den` },
    ],
  },
  {
    title: "Community",
    links: [
      { label: "GitHub", href: REPO_URL },
      { label: "Issues", href: `${REPO_URL}/issues` },
      { label: "Roadmap", href: doc("ROADMAP.md") },
      { label: "License (MIT)", href: doc("LICENSE") },
    ],
  },
];

export const Footer = () => (
  <footer className="border-t border-line px-4 py-14 sm:px-6">
    <div className="mx-auto grid max-w-6xl gap-10 sm:grid-cols-[1.4fr_repeat(3,1fr)]">
      <div>
        <a href="#top" className="flex items-center gap-2.5 font-semibold">
          <Image src="/den-icon.png" alt="" width={28} height={28} className="rounded-[7px] shadow-[0_0_0_1px_rgb(255_255_255/0.08)]" />
          den
        </a>
        <p className="mt-4 max-w-xs text-sm leading-relaxed text-ink-mute">
          An open-source browser for macOS 26, built on WebKit, made of plugins. This site has no cookies and no analytics.
        </p>
      </div>
      {COLUMNS.map((c) => (
        <div key={c.title}>
          <p className="font-mono text-xs uppercase tracking-[0.18em] text-ink-mute">{c.title}</p>
          <ul className="mt-4 space-y-2.5 text-sm">
            {c.links.map((l) => (
              <li key={l.label}>
                <a href={l.href} className="text-ink-soft transition hover:text-ink">
                  {l.label}
                </a>
              </li>
            ))}
          </ul>
        </div>
      ))}
    </div>
  </footer>
);
