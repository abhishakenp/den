"use client";

import type { Feature } from "@/lib/content";
import { useTabs } from "@/hooks/useTabs";
import { TourPanel } from "@/components/TourPanel";

type Props = { features: Feature[] };

export const TourTabs = ({ features }: Props) => {
  const ids = features.map((f) => f.id);
  const { active, setActive, onKeyDown, register } = useTabs(ids);

  return (
    <div className="mt-12">
      <div
        role="tablist"
        aria-label="den features"
        onKeyDown={onKeyDown}
        className="-mx-4 flex gap-1.5 overflow-x-auto px-4 pb-2 [scrollbar-width:none] sm:mx-0 sm:flex-wrap sm:px-0"
      >
        {features.map((f) => {
          const selected = f.id === active;
          return (
            <button
              key={f.id}
              ref={register(f.id)}
              role="tab"
              id={`tab-${f.id}`}
              aria-selected={selected}
              aria-controls={`panel-${f.id}`}
              tabIndex={selected ? 0 : -1}
              onClick={() => setActive(f.id)}
              className={`shrink-0 rounded-full border px-4 py-2 text-sm transition ${
                selected
                  ? "border-ember/50 bg-ember/10 text-ember-hi"
                  : "border-line bg-panel/40 text-ink-soft hover:border-line-2 hover:text-ink"
              }`}
            >
              {f.tab}
            </button>
          );
        })}
      </div>

      <div className="mt-8">
        {features.map((f) => (
          <TourPanel key={f.id} feature={f} hidden={f.id !== active} />
        ))}
      </div>
    </div>
  );
};
