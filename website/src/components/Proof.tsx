import { HeroStats } from "@/components/HeroStats";

export const Proof = () => (
  <section aria-label="den at a glance" className="reveal px-4 pb-20 sm:px-6 sm:pb-28">
    <p className="mx-auto max-w-2xl text-balance text-center text-2xl font-semibold tracking-tight text-ink sm:text-3xl">
      All of that, in a browser that idles at <span className="ember-text">20&nbsp;MB</span>.
    </p>
    <HeroStats />
    <p className="mt-3 text-center font-mono text-[11px] text-ink-mute">
      Measured on a busy M3 MacBook Air, macOS 26.5.{" "}
      <a href="#numbers" className="underline decoration-line-2 underline-offset-4 hover:text-ink-soft">
        Conditions and comparisons
      </a>
    </p>
  </section>
);
