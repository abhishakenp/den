import { CONDITIONS, FACTS, METRICS } from "@/lib/content";
import { doc } from "@/lib/site";
import { SectionHeader } from "@/components/ui/SectionHeader";
import { MetricChart } from "@/components/MetricChart";

export const Numbers = () => (
  <section id="numbers" className="relative px-4 py-24 sm:px-6 sm:py-32">
    <div aria-hidden className="hairline absolute inset-x-0 top-0" />
    <div className="mx-auto max-w-6xl">
      <SectionHeader
        eyebrow="Measured, not claimed"
        title={
          <>
            Numbers, with the <span className="font-serif font-normal italic ember-text">conditions</span> attached.
          </>
        }
        lead="den, Dia and Arc, launched in turn by the same probe on the same Mac. Shorter bars are better."
      />

      <div className="mt-14 grid gap-5 lg:grid-cols-3">
        {METRICS.map((m) => (
          <MetricChart key={m.title} metric={m} />
        ))}
      </div>

      <dl className="mt-5 grid grid-cols-2 gap-px overflow-hidden rounded-2xl border border-line bg-line lg:grid-cols-4">
        {FACTS.map((f) => (
          <div key={f.label} className="bg-ground-2 p-5 sm:p-6">
            <dt className="text-sm text-ink-soft">{f.label}</dt>
            <dd className="mt-2 font-mono text-2xl tracking-tight text-ink sm:text-3xl">{f.value}</dd>
            <dd className="mt-1 font-mono text-[11px] text-ink-mute">{f.note}</dd>
          </div>
        ))}
      </dl>

      <div className="mt-6 flex flex-col gap-3 rounded-2xl border border-ember/20 bg-ember/[0.04] p-5 text-sm leading-relaxed text-ink-soft sm:flex-row sm:items-start sm:gap-5">
        <span className="shrink-0 font-mono text-xs uppercase tracking-[0.15em] text-ember">Conditions</span>
        <p>
          {CONDITIONS} Cold launch and energy are not measured yet.{" "}
          <a className="text-ink underline decoration-ember/40 underline-offset-4 hover:decoration-ember" href={doc("docs/perf/baseline.md")}>
            Every run, raw value and command
          </a>
          .
        </p>
      </div>
    </div>
  </section>
);
