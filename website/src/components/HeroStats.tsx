import { Count } from "@/components/ui/Count";

const STATS = [
  { value: "20 MB", label: "idle, no tabs" },
  { value: "209 ms", label: "to first window" },
  { value: "80 KB", label: "per unloaded tab" },
  { value: "16", label: "plugins, swappable live" },
];

export const HeroStats = () => (
  <a
    href="#numbers"
    data-glow
    className="mx-auto mt-10 grid max-w-4xl grid-cols-2 gap-px overflow-clip rounded-2xl border border-line bg-line transition hover:border-line-2 sm:grid-cols-4"
  >
    {STATS.map((s) => (
      <span key={s.label} className="flex flex-col items-center bg-ground-2/90 px-3 py-4 text-center">
        <span className="font-mono text-xl tracking-tight text-ink sm:text-2xl">
          <Count label={s.value} />
        </span>
        <span className="mt-1 text-xs text-ink-mute">{s.label}</span>
      </span>
    ))}
  </a>
);
