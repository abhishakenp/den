import { ICON, PERSONAL, WORK } from "@/lib/story";
import { ROW, rowY } from "@/lib/stage";
import { Favicon } from "@/components/story/SideRow";
import { SpaceList } from "@/components/story/SpaceList";

const FAVORITES = [ICON.githubTile, ICON.gmail, ICON.calendar, ICON.youtube];

const Toolbar = () => (
  <div className="st-toolbar">
    <span className="st-lights">
      <i />
      <i />
      <i />
    </span>
    <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.3" className="st-tool" style={{ left: "calc(73 * var(--u))" }}>
      <rect x="1.5" y="3" width="13" height="10" rx="2" />
      <path d="M6 3v10" />
    </svg>
    <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.4" className="st-tool" style={{ left: "calc(112 * var(--u))" }}>
      <path d="M13 8H3m4-4L3 8l4 4" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
    <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.4" className="st-tool st-tool-dim" style={{ left: "calc(141 * var(--u))" }}>
      <path d="M3 8h10M9 4l4 4-4 4" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
    <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.4" className="st-tool" style={{ left: "calc(171 * var(--u))" }}>
      <path d="M13 8a5 5 0 1 1-1.5-3.6M13 2.5v2.5h-2.5" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  </div>
);

export const Sidebar = () => (
  <div className="st-sidebar">
    <Toolbar />
    <div className="st-url">apple.com</div>
    <div className="st-favs">
      {FAVORITES.map((i) => (
        <span key={i} className="st-tile">
          <Favicon icon={i} />
        </span>
      ))}
    </div>

    <div className="st-lists">
      <SpaceList
        name={PERSONAL.name}
        glyph="home"
        pinned={PERSONAL.pinned}
        today={PERSONAL.today}
        selected={0}
        className="st-list-a"
        todayClass={(i) => (i > 0 ? "st-tabx" : "")}
      />
      <SpaceList
        name={WORK.name}
        glyph="work"
        pinned={WORK.pinned}
        today={WORK.today}
        selected={1}
        className="st-list-b"
      >
        <div aria-hidden className="st-hover" style={{ top: `calc(${rowY(0, ROW.today) - ROW.height / 2} * var(--u))` }} />
      </SpaceList>
    </div>

    <div className="st-bottom">
      <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.3" className="st-tool" style={{ left: "calc(15 * var(--u))" }}>
        <path d="M2 9.5 4 3.5h8l2 6V13H2zM2 9.5h3.5l1 1.5h3l1-1.5H14" strokeLinejoin="round" />
      </svg>
      <span className="st-dot st-dot-home" style={{ left: "calc(64 * var(--u))" }} />
      <span className="st-dot st-dot-work" style={{ left: "calc(92 * var(--u))" }} />
      <span className="st-plus st-bottom-plus">+</span>
    </div>
  </div>
);
