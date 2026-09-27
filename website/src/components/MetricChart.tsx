import type { Metric } from "@/lib/content";

type Props = { metric: Metric };

export const MetricChart = ({ metric }: Props) => {
  const max = Math.max(...metric.bars.map((b) => b.value));
  return (
    <figure className="flex flex-col rounded-2xl border border-line bg-ground-2 p-6">
      <figcaption className="flex items-baseline justify-between gap-3">
        <span className="font-medium">{metric.title}</span>
        <span className="font-mono text-[11px] text-ink-mute">lower is better</span>
      </figcaption>
      <ul className="mt-6 space-y-5">
        {metric.bars.map((b) => (
          <li key={b.app}>
            <div className="flex items-baseline justify-between gap-3 text-sm">
              <span className={b.den ? "font-semibold text-ink" : "text-ink-soft"}>{b.app}</span>
              <span className={`font-mono ${b.den ? "text-ember-hi" : "text-ink-soft"}`}>{b.label}</span>
            </div>
            <div className="mt-2 h-2.5 overflow-hidden rounded-full bg-panel-2">
              <div
                className={`bar-fill h-full rounded-full ${b.den ? "bg-gradient-to-r from-ember-deep to-ember-hi" : "bg-ink-mute/50"}`}
                style={{ width: `${Math.max((b.value / max) * 100, 1.5)}%` }}
              />
            </div>
            {b.note ? <p className="mt-1.5 font-mono text-[11px] text-ink-mute">{b.note}</p> : null}
          </li>
        ))}
      </ul>
      <p className="mt-auto pt-6 text-xs leading-relaxed text-ink-mute">{metric.caption}</p>
    </figure>
  );
};
