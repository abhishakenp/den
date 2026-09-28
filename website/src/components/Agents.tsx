import { EXAMPLES, INSTALL, SKILL_URL, TEACHES } from "@/lib/agent";
import { SectionHeader } from "@/components/ui/SectionHeader";
import { InstallTabs } from "@/components/InstallTabs";
import { ArrowIcon } from "@/components/ui/Icons";

export const Agents = () => (
  <section id="agents" className="relative overflow-clip px-4 py-24 sm:px-6 sm:py-32">
    <div aria-hidden className="hairline absolute inset-x-0 top-0" />
    <div aria-hidden className="ember-glow pointer-events-none absolute -right-40 top-24 -z-10 h-[640px] w-[760px]" />
    <div className="mx-auto max-w-6xl">
      <SectionHeader
        eyebrow="For your agent"
        title={
          <>
            Your browser is plain files. <span className="font-serif font-normal italic ember-text">Let your agent</span> change it.
          </>
        }
        lead="den is configured in ~/.den and extended with small Swift plugins it reloads on save. The den skill teaches Claude Code, Codex and other agents exactly how, checked against den's source."
      />

      <div className="mt-14 grid gap-6 lg:grid-cols-[1.05fr_1fr]">
        <div className="flex flex-col gap-6">
          <InstallTabs methods={INSTALL} />
          <ul className="grid gap-px overflow-clip rounded-2xl border border-line bg-line sm:grid-cols-3 lg:grid-cols-1 xl:grid-cols-3">
            {TEACHES.map((t) => (
              <li key={t.title} className="bg-ground-2 p-5">
                <p className="font-medium">{t.title}</p>
                <p className="mt-2 text-sm leading-relaxed text-ink-soft">{t.body}</p>
              </li>
            ))}
          </ul>
          <a href={SKILL_URL} className="inline-flex items-center gap-1.5 text-sm font-medium text-ink transition hover:text-ember-hi">
            Read skills/den/SKILL.md <ArrowIcon className="size-3.5" />
          </a>
        </div>

        <figure className="overflow-clip rounded-2xl border border-line bg-ground-2">
          <figcaption className="flex items-center gap-2 border-b border-line px-4 py-3">
            <span className="flex gap-1.5" aria-hidden>
              <span className="size-2.5 rounded-full bg-line-2" />
              <span className="size-2.5 rounded-full bg-line-2" />
              <span className="size-2.5 rounded-full bg-line-2" />
            </span>
            <span className="ml-2 font-mono text-xs text-ink-mute">things to ask for</span>
          </figcaption>
          <ol className="divide-y divide-line">
            {EXAMPLES.map((e) => (
              <li key={e.ask} className="px-5 py-4">
                <p className="flex gap-3 text-[15px] text-ink">
                  <span aria-hidden className="font-mono text-ember">›</span>
                  {e.ask}
                </p>
                <p className="mt-1.5 pl-6 font-mono text-xs text-ink-mute">{e.touches}</p>
              </li>
            ))}
          </ol>
        </figure>
      </div>
    </div>
  </section>
);
