import { PRINCIPLES, type Principle } from "@/lib/content";
import { SectionHeader } from "@/components/ui/SectionHeader";
import { FeatherIcon, MoonIcon, PlugIcon, SwapIcon } from "@/components/ui/Icons";

const GLYPHS: Record<Principle["glyph"], typeof PlugIcon> = {
  plug: PlugIcon,
  swap: SwapIcon,
  lazy: MoonIcon,
  feather: FeatherIcon,
};

const PLUGINS = ["spaces", "tabs", "commandbar", "peek", "previews", "theme", "quit", "darkmode", "passwords", "extensions", "pagetools", "connections", "slack", "github", "briefing", "updates"];

export const Principles = () => (
  <section id="why" className="px-4 py-24 sm:px-6 sm:py-32">
    <div className="mx-auto max-w-6xl">
      <SectionHeader
        eyebrow="Why den"
        title="The best browser interfaces got heavy, closed, or stopped moving."
        lead="den keeps the interface people loved in Arc and builds it on four rules."
      />

      <div className="mt-14 grid gap-px overflow-hidden rounded-2xl border border-line bg-line sm:grid-cols-2">
        {PRINCIPLES.map((p) => {
          const Glyph = GLYPHS[p.glyph];
          return (
            <article key={p.title} className="group bg-ground-2 p-7 transition hover:bg-panel sm:p-9">
              <div className="grid size-10 place-items-center rounded-xl border border-line-2 bg-panel text-ember transition group-hover:border-ember/40">
                <Glyph className="size-5" />
              </div>
              <h3 className="mt-6 text-xl font-semibold tracking-tight">{p.title}</h3>
              <p className="mt-3 leading-relaxed text-ink-soft">{p.body}</p>
            </article>
          );
        })}
      </div>

      <div className="mt-10">
        <p className="font-mono text-xs text-ink-mute">den.app/Contents/PlugIns · the features are these plugins</p>
        <ul className="mt-4 flex flex-wrap gap-2">
          {PLUGINS.map((id) => (
            <li
              key={id}
              className="rounded-lg border border-line bg-panel/50 px-2.5 py-1 font-mono text-xs text-ink-soft transition hover:border-ember/40 hover:text-ember-hi"
            >
              {id}.dylib
            </li>
          ))}
        </ul>
      </div>
    </div>
  </section>
);
