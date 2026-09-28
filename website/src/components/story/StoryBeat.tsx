import type { Beat } from "@/lib/story";
import { Keycaps } from "@/components/ui/Keycaps";
import { ArrowIcon } from "@/components/ui/Icons";

type Props = { beat: Beat; index: number; total: number };

export const StoryBeat = ({ beat, index, total }: Props) => (
  <div className="st-beat" data-beat={index + 1}>
    <div className="st-beat-text">
      <p className="font-mono text-xs tracking-[0.2em] text-ember">
        {String(index + 1).padStart(2, "0")}
        <span className="text-ink-mute"> / {String(total).padStart(2, "0")}</span>
      </p>
      <h3 className="mt-3 text-balance text-2xl font-semibold tracking-tight text-ink sm:text-[2rem] sm:leading-tight">{beat.title}</h3>
      <p className="mt-3 text-pretty leading-relaxed text-ink-soft sm:text-lg">{beat.body}</p>
      <div className="mt-5 flex flex-wrap items-center gap-x-5 gap-y-3">
        {beat.keys ? <Keycaps keys={beat.keys} /> : null}
        {beat.href ? (
          <a href={beat.href} className="inline-flex items-center gap-1.5 text-sm font-medium text-ink-soft transition hover:text-ember-hi">
            Read the guide <ArrowIcon className="size-3.5" />
          </a>
        ) : null}
      </div>
    </div>
  </div>
);
