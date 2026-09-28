import type { CSSProperties, ReactNode } from "react";
import type { Row } from "@/lib/story";
import { ROW, rowY } from "@/lib/stage";
import { SideRow } from "@/components/story/SideRow";

type Props = {
  name: string;
  glyph: "home" | "work";
  pinned: Row[];
  today: Row[];
  selected: number;
  className: string;
  // Extra classes per Today row, by index (used to animate rows in).
  todayClass?: (i: number) => string;
  children?: ReactNode;
};

const Glyph = ({ glyph }: { glyph: Props["glyph"] }) =>
  glyph === "home" ? (
    <svg viewBox="0 0 16 16" fill="currentColor" className="st-glyph">
      <path d="M8 1.8 1.2 7.4l.8 1L3 7.6V14h4v-4h2v4h4V7.6l1 .8.8-1z" />
    </svg>
  ) : (
    <svg viewBox="0 0 16 16" fill="currentColor" className="st-glyph">
      <path d="M6 2h4a1 1 0 0 1 1 1v1h3a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1H2a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1h3V3a1 1 0 0 1 1-1zm0 2h4V3H6z" />
    </svg>
  );

export const SpaceList = ({ name, glyph, pinned, today, selected, className, todayClass, children }: Props) => (
  <div className={`st-list ${className}`}>
    <div className="st-space" style={{ top: `calc(${144 - 12} * var(--u))` }}>
      <Glyph glyph={glyph} />
      <span>{name}</span>
    </div>
    {pinned.map((r, i) => (
      <SideRow key={r.label + i} row={r} y={rowY(i, ROW.first)} />
    ))}
    <div className="st-divider" style={{ top: `calc(325 * var(--u))` }}>
      <span className="st-divider-line" />
      <span className="st-clear">↓ Clear</span>
    </div>
    <div className="st-newtab" style={{ top: `calc(${352 - 16} * var(--u))` }}>
      <span className="st-plus">+</span> New Tab
    </div>
    <div
      aria-hidden
      className={`st-sel ${className}-sel`}
      style={{ top: `calc(${rowY(selected, ROW.today) - ROW.height / 2} * var(--u))` } as CSSProperties}
    />
    {children}
    {today.map((r, i) => (
      <SideRow key={r.label + i} row={r} y={rowY(i, ROW.today)} className={todayClass?.(i) ?? ""} style={{ "--n": i - 1 } as CSSProperties} />
    ))}
  </div>
);
