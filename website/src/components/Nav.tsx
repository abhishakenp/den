import Image from "next/image";
import { NAV, REPO_URL } from "@/lib/site";
import { GitHubIcon } from "@/components/ui/Icons";

export const Nav = () => (
  <nav className="sticky top-0 z-50 border-b border-line/60 bg-ground/70 backdrop-blur-xl">
    <div className="mx-auto flex h-16 max-w-6xl items-center gap-6 px-4 sm:px-6">
      <a href="#top" className="flex items-center gap-2.5 font-semibold tracking-tight">
        <Image src="/den-icon.png" alt="" width={28} height={28} className="rounded-[7px] shadow-[0_0_0_1px_rgb(255_255_255/0.08)]" />
        <span className="text-lg">den</span>
      </a>
      <ul className="hidden items-center gap-1 text-sm text-ink-soft md:flex">
        {NAV.map((n) => (
          <li key={n.href}>
            <a href={n.href} className="rounded-lg px-3 py-2 transition hover:bg-panel hover:text-ink">
              {n.label}
            </a>
          </li>
        ))}
      </ul>
      <div className="ml-auto flex items-center gap-2">
        <a
          href={REPO_URL}
          aria-label="den on GitHub"
          className="flex items-center gap-2 rounded-lg px-3 py-2 text-sm text-ink-soft transition hover:bg-panel hover:text-ink"
        >
          <GitHubIcon />
          <span className="hidden sm:inline">GitHub</span>
        </a>
        <a
          href="#download"
          className="rounded-lg bg-ink px-3.5 py-2 text-sm font-medium text-ground transition hover:bg-ember-hi"
        >
          Download
        </a>
      </div>
    </div>
  </nav>
);
