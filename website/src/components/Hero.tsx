import type { Release } from "@/lib/release";
import { REPO_URL } from "@/lib/site";
import { ArrowIcon, DownloadIcon } from "@/components/ui/Icons";

type Props = { release: Release };

export const Hero = ({ release }: Props) => (
  <section id="top" className="relative overflow-clip px-4 pb-10 pt-16 sm:px-6 sm:pb-14 sm:pt-24">
    <div aria-hidden className="hero-parallax pointer-events-none absolute inset-x-0 top-0 -z-10 h-[900px]">
      <div className="hearth absolute left-1/2 top-[260px] h-[620px] w-[1100px] -translate-x-1/2 animate-glow" />
      <div className="arch-ring absolute left-1/2 top-[120px] h-[760px] w-[760px] -translate-x-1/2" />
      <div className="arch-ring absolute left-1/2 top-[200px] h-[680px] w-[560px] -translate-x-1/2 opacity-70" />
    </div>

    <div className="mx-auto max-w-4xl text-center">
      <a
        href={release.pageUrl}
        className="animate-rise relative z-20 inline-flex items-center gap-2 rounded-full border border-line-2 bg-panel/70 py-1 pl-1.5 pr-3 text-xs text-ink-soft transition hover:border-ember/50 hover:text-ink"
      >
        <span className="rounded-full bg-ember/15 px-2 py-0.5 font-mono text-[11px] text-ember-hi">alpha</span>
        {release.tag ? `${release.tag} is out` : "Pre-release is out"} · macOS 26
        <ArrowIcon className="size-3.5" />
      </a>

      <h1 className="mt-7 text-balance text-5xl font-semibold leading-[0.98] tracking-[-0.035em] sm:text-7xl">
        {/* Fixed line breaks on phones, so the web fonts swapping in can't reflow the hero. */}
        <span className="text-gradient">Arc&rsquo;s feel.</span>
        <br className="sm:hidden" />{" "}
        <span className="whitespace-nowrap">
          <span className="font-serif font-normal italic tracking-[-0.01em] ember-text">A fraction</span>{" "}
          <span className="text-gradient">of</span>
        </span>
        <br />
        <span className="text-gradient">the weight.</span>
      </h1>

      <p className="mx-auto mt-6 max-w-2xl text-pretty text-lg leading-relaxed text-ink-soft sm:text-xl">
        den is an open-source macOS browser built on WebKit, the engine behind Safari, and made of plugins you can
        swap while it runs. It idles at <span className="text-ink">20&nbsp;MB</span>.
      </p>

      <div className="animate-rise relative z-20 mt-9 flex flex-col items-center justify-center gap-3 [animation-delay:240ms] sm:flex-row">
        <a
          href={release.dmgUrl}
          className="group inline-flex h-12 items-center gap-2.5 rounded-xl bg-gradient-to-b from-ember-hi to-ember px-6 font-medium text-ground shadow-[0_10px_40px_-10px_rgb(244_162_76/0.7)] transition hover:brightness-110"
        >
          <DownloadIcon className="size-[18px]" />
          Download for macOS
          {release.dmgSizeMB ? <span className="font-mono text-xs opacity-70">{release.dmgSizeMB} MB</span> : null}
        </a>
        <a
          href={REPO_URL}
          className="inline-flex h-12 items-center gap-2 rounded-xl border border-line-2 bg-panel/60 px-6 font-medium text-ink transition hover:border-ink-mute"
        >
          Read the source
        </a>
      </div>
      <p className="animate-rise mt-4 font-mono text-xs text-ink-mute [animation-delay:300ms]">
        Alpha · macOS 26 Tahoe or later · MIT licensed
      </p>
    </div>

  </section>
);
