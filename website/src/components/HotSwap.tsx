const ROWS = ["Swift.org", "The Swift Programming Language", "switzerland"];

const Tile = ({ className, state }: { className: string; state: string }) => (
  <div className={`swap-tile ${className} flex items-center gap-3 rounded-xl border border-line-2 bg-panel px-4 py-3`}>
    <span className="grid size-8 place-items-center rounded-lg bg-ground-2 font-mono text-sm text-ember">⌘</span>
    <span className="flex flex-col">
      <span className="text-sm font-medium text-ink">Command bar</span>
      <span className="font-mono text-[11px] text-ink-mute">{state}</span>
    </span>
  </div>
);

const MiniBar = () => (
  <div className="relative overflow-clip rounded-xl border border-line-2 bg-[#1c1b22] p-2 text-[13px] text-ink shadow-[0_20px_60px_-20px_rgb(0_0_0/0.8)]">
    <p className="px-2 pb-2 pt-1 text-ink-soft">
      swi<span className="ml-px inline-block h-4 w-px translate-y-0.5 bg-ink" />
    </p>
    <div className="relative rounded-lg px-3 py-2">
      <span className="swap-ui-old absolute inset-0 rounded-lg bg-[#5b46c6]" />
      <span className="swap-ui-new absolute inset-0 rounded-lg bg-gradient-to-r from-ember-deep to-ember" />
      <span className="relative">
        swi <span className="opacity-70">— Search</span>
      </span>
    </div>
    {ROWS.map((r) => (
      <p key={r} className="truncate px-3 py-2 text-ink-soft">
        {r}
      </p>
    ))}
  </div>
);

export const HotSwap = () => (
  <div data-glow className="swap reveal mt-5 grid items-center gap-8 rounded-2xl border border-line bg-ground-2 p-6 sm:p-9 lg:grid-cols-[1fr_1.1fr]">
    <div>
      <p className="font-mono text-xs uppercase tracking-[0.2em] text-ember">Hot swap</p>
      <h3 className="mt-3 text-balance text-2xl font-semibold tracking-tight">Change a plugin. den keeps running.</h3>
      <p className="mt-3 max-w-md leading-relaxed text-ink-soft">
        Save a change to a plugin and den reloads just that piece, live. Your tabs stay put.
      </p>
      <div className="relative mt-6 h-[62px] max-w-xs [perspective:600px]">
        <Tile className="swap-old absolute inset-0" state="running" />
        <Tile className="swap-new absolute inset-0" state="new build · running" />
      </div>
    </div>
    <div className="relative">
      <MiniBar />
      <span aria-hidden className="swap-pulse pointer-events-none absolute left-1/2 top-1/2 -ml-24 -mt-24 size-48 rounded-full border-2 border-ember/60" />
      <span className="swap-chip absolute -top-3 right-4 inline-flex items-center gap-1.5 rounded-full border border-good/30 bg-ground px-2.5 py-1 font-mono text-[11px] text-good">
        <span className="size-1.5 rounded-full bg-good" /> reloaded · tabs kept
      </span>
    </div>
  </div>
);
