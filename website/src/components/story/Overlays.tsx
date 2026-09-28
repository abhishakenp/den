import Image from "next/image";
import { WORK } from "@/lib/story";
import { ROW, box, rowY } from "@/lib/stage";
import { SideRow } from "@/components/story/SideRow";
import { Deferred } from "@/components/story/Deferred";

const HN = WORK.today[2];

const Cursor = () => (
  <div className="st-track st-cursor">
    <span className="st-ring" />
    <svg viewBox="0 0 20 24" className="st-arrow">
      <path d="M2 1.5v18.2l4.6-4.4 3 6.9 3.1-1.3-3-6.8h6.4z" fill="#fff" stroke="#111" strokeWidth="1.3" strokeLinejoin="round" />
    </svg>
  </div>
);

export const Overlays = () => (
  <Deferred>
    <div className="st-track st-ghost">
      <SideRow row={HN} y={rowY(2, ROW.today)} className="st-ghost-row" />
    </div>

    <div className="st-pr" style={box(205, 366, 280, 405)}>
      <Image src="/story/pr-card.png" alt="" fill sizes="(min-width: 1024px) 190px, 26vw" />
    </div>

    <div className="st-mini" style={box(235, 120, 1000, 562)}>
      <Image src="/story/video.png" alt="" fill sizes="(min-width: 1024px) 560px, 80vw" />
    </div>

    <Cursor />
  </Deferred>
);
