"use client";

import type { InstallMethod } from "@/lib/agent";
import { useTabs } from "@/hooks/useTabs";
import { CopyCommand } from "@/components/ui/CopyCommand";

type Props = { methods: InstallMethod[] };

export const InstallTabs = ({ methods }: Props) => {
  const { active, setActive, onKeyDown, register } = useTabs(methods.map((m) => m.id));

  return (
    <div className="rounded-2xl border border-line bg-panel/60 p-2">
      <div role="tablist" aria-label="Install the den skill" onKeyDown={onKeyDown} className="flex gap-1">
        {methods.map((m) => {
          const selected = m.id === active;
          return (
            <button
              key={m.id}
              ref={register(m.id)}
              role="tab"
              id={`itab-${m.id}`}
              aria-selected={selected}
              aria-controls={`ipanel-${m.id}`}
              tabIndex={selected ? 0 : -1}
              onClick={() => setActive(m.id)}
              className={`flex-1 rounded-xl px-3 py-2 text-sm transition sm:flex-none ${
                selected ? "bg-panel-2 text-ink shadow-[inset_0_0_0_1px_var(--color-line-2)]" : "text-ink-soft hover:text-ink"
              }`}
            >
              {m.label}
            </button>
          );
        })}
      </div>
      {methods.map((m) => (
        <div key={m.id} role="tabpanel" id={`ipanel-${m.id}`} aria-labelledby={`itab-${m.id}`} hidden={m.id !== active} className="p-2 pt-3">
          <CopyCommand command={m.command} label={`${m.label} install command`} />
          <p className="mt-3 px-1 text-sm text-ink-mute">{m.hint}</p>
        </div>
      ))}
    </div>
  );
};
