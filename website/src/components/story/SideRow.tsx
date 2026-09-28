import type { CSSProperties } from "react";
import type { Row } from "@/lib/story";
import { ROW } from "@/lib/stage";

type Props = { row: Row; y: number; className?: string; style?: CSSProperties };

const FolderGlyph = () => (
  <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.3" className="st-glyph">
    <path d="M1.5 4.5v8h13v-7H7.5L6 4H1.5z" strokeLinejoin="round" />
  </svg>
);

export const Favicon = ({ icon }: { icon: number }) => (
  <span aria-hidden className="st-fav" style={{ "--i": icon } as CSSProperties} />
);

export const SideRow = ({ row, y, className = "", style }: Props) => (
  <div
    className={`st-row ${row.indent ? "st-row-indent" : ""} ${className}`}
    style={{ top: `calc(${y - ROW.height / 2} * var(--u))`, ...style }}
  >
    {row.folder ? <FolderGlyph /> : <Favicon icon={row.icon} />}
    <span className="st-row-label">{row.label}</span>
    {row.folder ? <span className="st-chev">⌄</span> : null}
  </div>
);
