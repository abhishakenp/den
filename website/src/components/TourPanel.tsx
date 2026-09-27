import type { Feature } from "@/lib/content";
import { Shot } from "@/components/ui/Shot";
import { ArrowIcon } from "@/components/ui/Icons";

type Props = { feature: Feature; hidden: boolean };

export const TourPanel = ({ feature: f, hidden }: Props) => (
  <div
    role="tabpanel"
    id={`panel-${f.id}`}
    aria-labelledby={`tab-${f.id}`}
    hidden={hidden}
    className="grid items-center gap-8 lg:grid-cols-[1fr_1.9fr] lg:gap-12"
  >
    <div className="animate-rise">
      <h3 className="text-balance text-2xl font-semibold tracking-tight sm:text-3xl">{f.title}</h3>
      <p className="mt-4 leading-relaxed text-ink-soft">{f.body}</p>
      <ul className="mt-6 space-y-2.5">
        {f.points.map((p) => (
          <li key={p} className="flex gap-3 text-sm text-ink-soft">
            <span aria-hidden className="mt-[7px] size-1.5 shrink-0 rounded-full bg-ember" />
            {p}
          </li>
        ))}
      </ul>
      <a
        href={f.href}
        className="mt-7 inline-flex items-center gap-1.5 text-sm font-medium text-ink transition hover:text-ember-hi"
      >
        Read the guide <ArrowIcon className="size-3.5" />
      </a>
    </div>
    <Shot src={f.shot} alt={f.alt} sizes="(min-width: 1024px) 740px, 100vw" className="animate-rise" />
  </div>
);
